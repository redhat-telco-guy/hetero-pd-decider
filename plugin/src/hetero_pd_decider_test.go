/*
Copyright 2026 The llm-d Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package disagg

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"github.com/prometheus/client_golang/prometheus/testutil"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	k8stypes "k8s.io/apimachinery/pkg/types"

	fwkdl "github.com/llm-d/llm-d-router/pkg/epp/framework/interface/datalayer"
	"github.com/llm-d/llm-d-router/pkg/epp/framework/interface/scheduling"
	attrprefix "github.com/llm-d/llm-d-router/pkg/epp/framework/plugins/datalayer/attribute/prefix"
	"github.com/llm-d/llm-d-router/pkg/epp/framework/plugins/scheduling/filter/bylabel"
	"github.com/llm-d/llm-d-router/pkg/epp/framework/plugins/scheduling/profilehandler/disagg/hetero"
)

const (
	heteroClassA30   = "nvidia-a30"
	heteroClassGaudi = "intel-gaudi3"
	heteroPrompt     = 2000
)

// heteroLabConfig models one A30 prefill pod feeding Gaudi 3 decode pods over 25 GbE.
// Throughputs are placeholders, not measurements.
func heteroLabConfig() HeteroPDDeciderConfig {
	c := defaultHeteroPDDeciderConfig()
	c.TTFTSLOMs = 1000
	c.BandwidthGbps = 25
	c.Profiles = map[string]hetero.Profile{
		heteroClassA30:   {PrefillTokensPerSec: 5000},
		heteroClassGaudi: {PrefillTokensPerSec: 20000},
	}
	return c
}

func heteroEndpoint(name, role, class string, running, waiting int, kvUsage float64, extra map[string]string) scheduling.Endpoint {
	labels := map[string]string{bylabel.RoleLabel: role, defaultAcceleratorLabel: class}
	for k, v := range extra {
		labels[k] = v
	}
	m := fwkdl.NewMetrics()
	m.RunningRequestsSize = running
	m.WaitingQueueSize = waiting
	m.KVCacheUsagePercent = kvUsage
	return scheduling.NewEndpoint(
		&fwkdl.EndpointMetadata{
			ID:      k8stypes.NamespacedName{Namespace: "default", Name: name},
			Address: testEndpointAddr,
			Port:    testEndpointPort,
			Labels:  labels,
		},
		m,
		fwkdl.NewAttributes(),
	)
}

func newTestHeteroDecider(t *testing.T, c HeteroPDDeciderConfig) *HeteroPDDecider {
	t.Helper()
	d, err := NewHeteroPDDecider(c)
	require.NoError(t, err)
	return d.WithName("hetero")
}

func TestHeteroPDDeciderLabScenarios(t *testing.T) {
	a30Idle := heteroEndpoint("a30-0", bylabel.RolePrefill, heteroClassA30, 0, 0, 0, nil)
	a30Queued := heteroEndpoint("a30-0", bylabel.RolePrefill, heteroClassA30, 0, 3, 0, nil)

	tests := []struct {
		name    string
		tokens  int
		decode  scheduling.Endpoint
		pool    []scheduling.Endpoint
		produce bool
		want    bool
	}{
		{
			name:    "busy decode pod offloads a long prompt",
			tokens:  heteroPrompt,
			decode:  heteroEndpoint("gaudi-0", bylabel.RoleDecode, heteroClassGaudi, 40, 0, 0.3, nil),
			pool:    []scheduling.Endpoint{a30Idle},
			produce: true,
			want:    true,
		},
		{
			name:    "idle decode pod prefills locally",
			tokens:  heteroPrompt,
			decode:  heteroEndpoint("gaudi-0", bylabel.RoleDecode, heteroClassGaudi, 0, 0, 0.1, nil),
			pool:    []scheduling.Endpoint{a30Idle},
			produce: true,
			want:    false,
		},
		{
			name:    "short prompt stays local",
			tokens:  100,
			decode:  heteroEndpoint("gaudi-0", bylabel.RoleDecode, heteroClassGaudi, 40, 0, 0.3, nil),
			pool:    []scheduling.Endpoint{a30Idle},
			produce: true,
			want:    false,
		},
		{
			name:    "queued prefill pod would miss the SLO",
			tokens:  heteroPrompt,
			decode:  heteroEndpoint("gaudi-0", bylabel.RoleDecode, heteroClassGaudi, 40, 0, 0.3, nil),
			pool:    []scheduling.Endpoint{a30Queued},
			produce: true,
			want:    false,
		},
		{
			name:    "decode KV nearly full",
			tokens:  heteroPrompt,
			decode:  heteroEndpoint("gaudi-0", bylabel.RoleDecode, heteroClassGaudi, 40, 0, 0.95, nil),
			pool:    []scheduling.Endpoint{a30Idle},
			produce: true,
			want:    false,
		},
		{
			name:    "decode pods are not prefill candidates",
			tokens:  heteroPrompt,
			decode:  heteroEndpoint("gaudi-0", bylabel.RoleDecode, heteroClassGaudi, 40, 0, 0.3, nil),
			pool:    []scheduling.Endpoint{heteroEndpoint("gaudi-1", bylabel.RoleDecode, heteroClassGaudi, 0, 0, 0, nil)},
			produce: true,
			want:    false,
		},
		{
			name:    "prefill-decode peer is a candidate",
			tokens:  heteroPrompt,
			decode:  heteroEndpoint("gaudi-0", bylabel.RolePrefillDecode, heteroClassGaudi, 40, 0, 0.3, nil),
			pool:    []scheduling.Endpoint{heteroEndpoint("gaudi-1", bylabel.RolePrefillDecode, heteroClassGaudi, 0, 0, 0, nil)},
			produce: true,
			want:    true,
		},
		{
			name:    "fingerprint mismatch blocks the split",
			tokens:  heteroPrompt,
			decode:  heteroEndpoint("gaudi-0", bylabel.RoleDecode, heteroClassGaudi, 40, 0, 0.3, map[string]string{defaultFingerprintLabel: "a"}),
			pool:    []scheduling.Endpoint{heteroEndpoint("a30-0", bylabel.RolePrefill, heteroClassA30, 0, 0, 0, map[string]string{defaultFingerprintLabel: "b"})},
			produce: true,
			want:    false,
		},
		{
			name:    "disabled prefill pod is skipped",
			tokens:  heteroPrompt,
			decode:  heteroEndpoint("gaudi-0", bylabel.RoleDecode, heteroClassGaudi, 40, 0, 0.3, nil),
			pool:    []scheduling.Endpoint{heteroEndpoint("a30-0", bylabel.RolePrefill, heteroClassA30, 0, 0, 0, map[string]string{defaultDisableLabel: "true"})},
			produce: true,
			want:    false,
		},
		{
			name:    "no prefill view stays local",
			tokens:  heteroPrompt,
			decode:  heteroEndpoint("gaudi-0", bylabel.RoleDecode, heteroClassGaudi, 40, 0, 0.3, nil),
			produce: false,
			want:    false,
		},
		{
			name:    "unprofiled decode class uses the fallback threshold",
			tokens:  heteroPrompt,
			decode:  heteroEndpoint("x-0", bylabel.RoleDecode, "unprofiled", 40, 0, 0.3, nil),
			pool:    []scheduling.Endpoint{a30Idle},
			produce: true,
			want:    true,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			d := newTestHeteroDecider(t, heteroLabConfig())
			ctx := context.Background()
			if tt.produce {
				require.NoError(t, d.Produce(ctx, nil, append([]scheduling.Endpoint{tt.decode}, tt.pool...)))
			}
			assert.Equal(t, tt.want, d.disaggregate(ctx, makeRequestWithTokens(tt.tokens), tt.decode))
		})
	}
}

func TestHeteroPDDeciderSubtractsCachedPrefix(t *testing.T) {
	d := newTestHeteroDecider(t, heteroLabConfig())
	ctx := context.Background()
	decode := heteroEndpoint("gaudi-0", bylabel.RoleDecode, heteroClassGaudi, 40, 0, 0.3, nil)
	pool := heteroEndpoint("a30-0", bylabel.RolePrefill, heteroClassA30, 0, 0, 0, nil)
	require.NoError(t, d.Produce(ctx, nil, []scheduling.Endpoint{decode, pool}))
	require.True(t, d.disaggregate(ctx, makeRequestWithTokens(heteroPrompt), decode))

	// 1900 of 2000 tokens cached leaves 100 uncached, under minUncachedTokens.
	decode.Put(attrprefix.PrefixCacheMatchInfoDataKey, attrprefix.NewPrefixCacheMatchInfo(1900, heteroPrompt, 1))
	assert.False(t, d.disaggregate(ctx, makeRequestWithTokens(heteroPrompt), decode))
}

func TestHeteroPDDeciderFailsSoft(t *testing.T) {
	d := newTestHeteroDecider(t, heteroLabConfig())
	ctx := context.Background()
	decode := heteroEndpoint("gaudi-0", bylabel.RoleDecode, heteroClassGaudi, 40, 0, 0.3, nil)
	assert.False(t, d.disaggregate(ctx, makeRequestWithTokens(heteroPrompt), nil))
	assert.False(t, d.disaggregate(ctx, &scheduling.InferenceRequest{}, decode))
	decode.Put(attrprefix.PrefixCacheMatchInfoDataKey, &notPrefixCacheMatchInfo{})
	assert.False(t, d.disaggregate(ctx, makeRequestWithTokens(heteroPrompt), decode))
}

func TestHeteroPDDeciderRecordsReason(t *testing.T) {
	d := newTestHeteroDecider(t, heteroLabConfig())
	ctx := context.Background()
	decode := heteroEndpoint("gaudi-0", bylabel.RoleDecode, heteroClassGaudi, 40, 0, 0.3, nil)
	pool := heteroEndpoint("a30-0", bylabel.RolePrefill, heteroClassA30, 0, 0, 0, nil)
	require.NoError(t, d.Produce(ctx, nil, []scheduling.Endpoint{decode, pool}))

	counter := LlmdHeteroPDDecisionCount.WithLabelValues("hetero", hetero.ReasonRemoteBetter, "true")
	before := testutil.ToFloat64(counter)
	require.True(t, d.disaggregate(ctx, makeRequestWithTokens(heteroPrompt), decode))
	assert.InDelta(t, before+1, testutil.ToFloat64(counter), 1e-9)
}

func TestHeteroPDDeciderFactory(t *testing.T) {
	raw := `{
		"ttftSLOMs": 1000,
		"bandwidthGbps": 25,
		"stallWeight": 0.25,
		"acceleratorLabel": "example.com/accel",
		"profiles": {"nvidia-a30": {"prefillTokensPerSec": 5000}}
	}`
	p, err := HeteroPDDeciderPluginFactory("h", json.NewDecoder(strings.NewReader(raw)), nil)
	require.NoError(t, err)
	d, ok := p.(*HeteroPDDecider)
	require.True(t, ok)
	assert.Equal(t, "h", d.TypedName().Name)
	assert.Equal(t, HeteroPDDeciderPluginType, d.TypedName().Type)
	assert.Equal(t, "example.com/accel", d.config.AcceleratorLabel)
	assert.InDelta(t, 1000.0, d.config.TTFTSLOMs, 1e-9)
	assert.Equal(t, 131072, int(d.config.KVBytesPerToken))
	assert.InDelta(t, 5000.0, d.config.Profiles["nvidia-a30"].PrefillTokensPerSec, 1e-9)

	p, err = HeteroPDDeciderPluginFactory("h", nil, nil)
	require.NoError(t, err)
	assert.Equal(t, defaultAcceleratorLabel, p.(*HeteroPDDecider).config.AcceleratorLabel)

	for _, bad := range []string{
		`{"acceleratorLabel": ""}`,
		`{"bandwidthGbps": 0}`,
		`{"safetyMargin": 1}`,
		`{"fallbackNonCachedTokens": -1}`,
		`{"profiles": {"x": {"prefillTokensPerSec": 0}}}`,
		`{"bandwidthGbps": "fast"}`,
	} {
		_, err := HeteroPDDeciderPluginFactory("h", json.NewDecoder(strings.NewReader(bad)), nil)
		assert.Error(t, err, bad)
	}
}

func TestHeteroPDDeciderConsumes(t *testing.T) {
	d := newTestHeteroDecider(t, heteroLabConfig())
	required := d.Consumes().Required
	assert.Contains(t, required, d.prefixMatchInfoDataKey())
	assert.Len(t, required, 5)
	assert.Empty(t, d.Produces())
}
