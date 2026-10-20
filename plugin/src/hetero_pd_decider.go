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
	"errors"
	"fmt"
	"strconv"
	"sync"
	"sync/atomic"

	"sigs.k8s.io/controller-runtime/pkg/log"

	"github.com/llm-d/llm-d-router/pkg/common/observability/logging"
	"github.com/llm-d/llm-d-router/pkg/epp/framework/interface/plugin"
	fwkrc "github.com/llm-d/llm-d-router/pkg/epp/framework/interface/requestcontrol"
	"github.com/llm-d/llm-d-router/pkg/epp/framework/interface/scheduling"
	attrprefix "github.com/llm-d/llm-d-router/pkg/epp/framework/plugins/datalayer/attribute/prefix"
	"github.com/llm-d/llm-d-router/pkg/epp/framework/plugins/datalayer/extractor/metrics"
	tokenproducer "github.com/llm-d/llm-d-router/pkg/epp/framework/plugins/requestcontrol/dataproducer/tokenizer"
	"github.com/llm-d/llm-d-router/pkg/epp/framework/plugins/scheduling/filter/bylabel"
	"github.com/llm-d/llm-d-router/pkg/epp/framework/plugins/scheduling/profilehandler/disagg/hetero"
)

const (
	// HeteroPDDeciderPluginType is the type-name of the heteroPDDecider plugin.
	HeteroPDDeciderPluginType = "hetero-pd-decider"

	defaultAcceleratorLabel = "llm-d.ai/accelerator-class"
	defaultFingerprintLabel = "llm-d.ai/model-fingerprint"
	defaultDisableLabel     = "llm-d.ai/hetero-pd-disabled"
)

// HeteroPDDeciderConfig holds the configuration for the heteroPDDecider plugin.
// The decision parameters are documented on hetero.Config.
type HeteroPDDeciderConfig struct {
	hetero.Config

	// AcceleratorLabel is the pod label holding the accelerator class used to look up profiles.
	AcceleratorLabel string `json:"acceleratorLabel"`
	// FingerprintLabel is the pod label identifying the served model build.
	// Pods whose values differ never exchange KV. Empty disables the check.
	FingerprintLabel string `json:"fingerprintLabel"`
	// DisableLabel excludes a pod from remote prefill, as source or destination, when set to "true".
	DisableLabel string `json:"disableLabel"`
	// FallbackNonCachedTokens is the threshold applied when the decode pod's class has no profile.
	// Zero keeps such requests local.
	FallbackNonCachedTokens int `json:"fallbackNonCachedTokens"`
	// PrefixMatchInfoProducerName selects which prefix-cache producer's
	// PrefixCacheMatchInfo to read on the decode endpoint. Empty defaults to the
	// approximate-prefix producer.
	PrefixMatchInfoProducerName string `json:"prefixMatchInfoProducerName,omitempty"`
}

func defaultHeteroPDDeciderConfig() HeteroPDDeciderConfig {
	return HeteroPDDeciderConfig{
		Config:                  hetero.DefaultConfig(),
		AcceleratorLabel:        defaultAcceleratorLabel,
		FingerprintLabel:        defaultFingerprintLabel,
		DisableLabel:            defaultDisableLabel,
		FallbackNonCachedTokens: 1024,
	}
}

func (c HeteroPDDeciderConfig) validate() error {
	if c.AcceleratorLabel == "" {
		return errors.New("acceleratorLabel cannot be empty")
	}
	if c.FallbackNonCachedTokens < 0 {
		return errors.New("fallbackNonCachedTokens cannot be negative")
	}
	return c.Config.Validate()
}

// compile-time type assertions
var (
	_ deciderPlugin           = &HeteroPDDecider{}
	_ fwkrc.DataProducer      = &HeteroPDDecider{}
	_ plugin.ConsumerPlugin   = &HeteroPDDecider{}
	_ prefixMatchInfoConsumer = &HeteroPDDecider{}
)

var prefillCapableRoles = map[string]struct{}{
	bylabel.RolePrefill:             {},
	bylabel.RoleEncodePrefill:       {},
	bylabel.RolePrefillDecode:       {},
	bylabel.RoleEncodePrefillDecode: {},
}

// HeteroPDDecider decides per request whether to prefill on another pod,
// comparing estimated time to first token plus the stall local prefill
// imposes on running decode streams. Accelerator classes are read from a pod
// label and mapped to measured prefill throughput.
//
// It is also a DataProducer: Produce runs before scheduling with every
// candidate endpoint and caches the prefill-capable pods, because the decider
// itself only receives the selected decode endpoint.
type HeteroPDDecider struct {
	typedName         plugin.TypedName
	config            HeteroPDDeciderConfig
	prefixMatchInfoDK plugin.DataKey
	prefillPods       atomic.Pointer[[]hetero.Pod]
	warnNoPrefillView sync.Once
}

// HeteroPDDeciderPluginFactory defines the factory function for creating
// a new instance of the heteroPDDecider.
func HeteroPDDeciderPluginFactory(name string, rawParameters *json.Decoder,
	_ plugin.Handle) (plugin.Plugin, error) {
	config := defaultHeteroPDDeciderConfig()
	if rawParameters != nil {
		if err := rawParameters.Decode(&config); err != nil {
			return nil, fmt.Errorf("failed to parse %s plugin config: %w", HeteroPDDeciderPluginType, err)
		}
	}
	decider, err := NewHeteroPDDecider(config)
	if err != nil {
		return nil, fmt.Errorf("failed to create %s plugin: %w", HeteroPDDeciderPluginType, err)
	}
	return decider.WithName(name), nil
}

// NewHeteroPDDecider validates the configuration and returns the plugin.
func NewHeteroPDDecider(config HeteroPDDeciderConfig) (*HeteroPDDecider, error) {
	if err := config.validate(); err != nil {
		return nil, err
	}
	return &HeteroPDDecider{
		typedName: plugin.TypedName{Type: HeteroPDDeciderPluginType},
		config:    config,
		prefixMatchInfoDK: attrprefix.PrefixCacheMatchInfoDataKey.WithNonEmptyProducerName(
			config.PrefixMatchInfoProducerName,
		),
	}, nil
}

// TypedName returns the typed name of the plugin.
func (d *HeteroPDDecider) TypedName() plugin.TypedName {
	return d.typedName
}

// WithName sets the name of the plugin.
func (d *HeteroPDDecider) WithName(name string) *HeteroPDDecider {
	d.typedName.Name = name
	return d
}

func (d *HeteroPDDecider) prefixMatchInfoDataKey() plugin.DataKey {
	return d.prefixMatchInfoDK
}

// Produces declares no request attributes; the prefill view is plugin state.
func (d *HeteroPDDecider) Produces() map[plugin.DataKey]any {
	return map[plugin.DataKey]any{}
}

// Consumes declares the tokenized prompt, the decode endpoint's prefix match
// info, and the endpoint metrics the estimate reads.
func (d *HeteroPDDecider) Consumes() plugin.DataDependencies {
	return plugin.DataDependencies{
		Required: map[plugin.DataKey]any{
			d.prefixMatchInfoDK:                  attrprefix.PrefixCacheMatchInfo{},
			tokenproducer.TokenizedPromptDataKey: scheduling.TokenizedRequest{},
			plugin.NewDataKey(metrics.KVCacheUsagePercentKey, metrics.MetricsExtractorType): float64(0),
			plugin.NewDataKey(metrics.WaitingQueueSizeKey, metrics.MetricsExtractorType):    int(0),
			plugin.NewDataKey(metrics.RunningRequestsSizeKey, metrics.MetricsExtractorType): int(0),
		},
	}
}

// Produce caches the prefill-capable endpoints and their load for the decision.
func (d *HeteroPDDecider) Produce(_ context.Context, _ *scheduling.InferenceRequest, endpoints []scheduling.Endpoint) error {
	pods := make([]hetero.Pod, 0, len(endpoints))
	for _, ep := range endpoints {
		meta := ep.GetMetadata()
		if meta == nil {
			continue
		}
		if _, ok := prefillCapableRoles[meta.Labels[bylabel.RoleLabel]]; !ok {
			continue
		}
		pods = append(pods, d.toPod(ep))
	}
	d.prefillPods.Store(&pods)
	return nil
}

func (d *HeteroPDDecider) toPod(ep scheduling.Endpoint) hetero.Pod {
	pod := hetero.Pod{}
	if meta := ep.GetMetadata(); meta != nil {
		pod.Name = meta.ID.String()
		pod.Class = meta.Labels[d.config.AcceleratorLabel]
		if d.config.FingerprintLabel != "" {
			pod.Fingerprint = meta.Labels[d.config.FingerprintLabel]
		}
		if d.config.DisableLabel != "" {
			pod.Disabled, _ = strconv.ParseBool(meta.Labels[d.config.DisableLabel])
		}
	}
	if m := ep.GetMetrics(); m != nil {
		pod.Running = m.RunningRequestsSize
		pod.Waiting = m.WaitingQueueSize
		pod.KVUsage = m.KVCacheUsagePercent
	}
	return pod
}

func (d *HeteroPDDecider) uncachedTokens(request *scheduling.InferenceRequest, endpoint scheduling.Endpoint) (int, error) {
	inputTokens, err := getUserInputLenInTokens(request)
	if err != nil {
		return 0, fmt.Errorf("failed to get user input length in tokens: %w", err)
	}
	raw, ok := endpoint.Get(d.prefixMatchInfoDK)
	if !ok || raw == nil {
		return inputTokens, nil
	}
	info, ok := raw.(*attrprefix.PrefixCacheMatchInfo)
	if !ok {
		return 0, fmt.Errorf("prefix cache match info from %s has unexpected type: %T", d.prefixMatchInfoDK, raw)
	}
	return max(inputTokens-info.CachedBlockCount()*info.BlockSizeTokens(), 0), nil
}

// disaggregate reports whether remote prefill should run for this request.
// Any read failure is logged and returns false so scheduling falls back to
// the decode-only path.
func (d *HeteroPDDecider) disaggregate(ctx context.Context, request *scheduling.InferenceRequest, endpoint scheduling.Endpoint) bool {
	logger := log.FromContext(ctx)
	if endpoint == nil {
		logger.Error(errors.New("endpoint is nil"), "hetero-pd-decider: skipping remote prefill")
		return false
	}
	uncached, err := d.uncachedTokens(request, endpoint)
	if err != nil {
		logger.Error(err, "hetero-pd-decider: skipping remote prefill")
		return false
	}

	var prefill []hetero.Pod
	if snapshot := d.prefillPods.Load(); snapshot != nil {
		prefill = *snapshot
	} else {
		d.warnNoPrefillView.Do(func() {
			logger.Info("hetero-pd-decider has no prefill pod view; Produce has not run. " +
				"Confirm the plugin is listed under plugins so the request-control layer calls it.")
		})
	}

	decision := hetero.Decide(d.config.Config, uncached, d.toPod(endpoint), prefill)
	if decision.Fallback {
		decision.Remote = d.config.FallbackNonCachedTokens > 0 && uncached >= d.config.FallbackNonCachedTokens
	}
	recordHeteroPDDecision(d.typedName.Name, decision.Reason, decision.Remote)

	if v := logger.V(logging.DEBUG); v.Enabled() {
		v.Info("hetero-pd-decider decision",
			"remote", decision.Remote, "reason", decision.Reason, "fallback", decision.Fallback,
			"uncachedTokens", uncached, "prefillPod", decision.Prefill,
			"remoteSeconds", decision.RemoteSeconds, "localSeconds", decision.LocalSeconds,
			"stallSeconds", decision.StallSeconds, "transferSeconds", decision.TransferSeconds)
	}
	return decision.Remote
}
