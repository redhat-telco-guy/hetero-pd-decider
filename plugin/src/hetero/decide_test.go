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

package hetero

import (
	"math"
	"testing"
)

const (
	classA30    = "nvidia-a30"
	classGaudi3 = "intel-gaudi3"
	promptLong  = 2000
)

// labConfig models one A30 prefill pod feeding Gaudi 3 decode pods over
// 25 GbE with Llama-3.1-8B. Throughputs are placeholders, not measurements.
func labConfig() Config {
	c := DefaultConfig()
	c.TTFTSLOMs = 1000
	c.BandwidthGbps = 25
	c.Profiles = map[string]Profile{
		classA30:    {PrefillTokensPerSec: 5000},
		classGaudi3: {PrefillTokensPerSec: 20000},
	}
	return c
}

func a30(waiting int) Pod {
	return Pod{Name: "a30-0", Class: classA30, Waiting: waiting}
}

func gaudi(running int) Pod {
	return Pod{Name: "gaudi-0", Class: classGaudi3, Running: running}
}

func TestDecideLabScenarios(t *testing.T) {
	tests := []struct {
		name       string
		tokens     int
		decode     Pod
		prefill    []Pod
		wantRemote bool
		wantReason string
	}{
		{"long prompt, busy decode pod offloads", promptLong, gaudi(40), []Pod{a30(0)}, true, ReasonRemoteBetter},
		{"long prompt, idle decode pod prefills locally", promptLong, gaudi(0), []Pod{a30(0)}, false, ReasonLocalBetter},
		{"short prompt stays local", 200, gaudi(40), []Pod{a30(0)}, false, ReasonShortPrompt},
		{"prefill queue breaks the SLO", promptLong, gaudi(40), []Pod{a30(3)}, false, ReasonSLOMiss},
		{"decode KV nearly full", promptLong, Pod{Name: "gaudi-0", Class: classGaudi3, Running: 40, KVUsage: 0.95}, []Pod{a30(0)}, false, ReasonDecodeKVFull},
		{"decode pod opted out", promptLong, Pod{Name: "gaudi-0", Class: classGaudi3, Running: 40, Disabled: true}, []Pod{a30(0)}, false, ReasonDecodeDisabled},
		{"no prefill pods", promptLong, gaudi(40), nil, false, ReasonNoPrefillCandidate},
		{"decode pod is not its own prefill candidate", promptLong, gaudi(40), []Pod{gaudi(0)}, false, ReasonNoPrefillCandidate},
		{"unknown decode class falls back", promptLong, Pod{Name: "x", Class: "unknown", Running: 40}, []Pod{a30(0)}, false, ReasonMissingProfile},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			d := Decide(labConfig(), tt.tokens, tt.decode, tt.prefill)
			if d.Remote != tt.wantRemote || d.Reason != tt.wantReason {
				t.Fatalf("got remote=%v reason=%q, want remote=%v reason=%q (%+v)",
					d.Remote, d.Reason, tt.wantRemote, tt.wantReason, d)
			}
		})
	}
}

func TestDecideEstimates(t *testing.T) {
	d := Decide(labConfig(), promptLong, gaudi(40), []Pod{a30(0)})
	// 2000 tokens / 5000 tok/s + 2000 * 131072 B / 3.125e9 B/s
	wantTransfer := 2000.0 * 131072 / 3.125e9
	assertNear(t, "transfer", d.TransferSeconds, wantTransfer)
	assertNear(t, "remote", d.RemoteSeconds, 0.4+wantTransfer)
	assertNear(t, "local", d.LocalSeconds, 0.1)
	assertNear(t, "stall", d.StallSeconds, 4.0)
	if d.Prefill != "a30-0" {
		t.Fatalf("prefill pod %q, want a30-0", d.Prefill)
	}
}

func TestDecideMissingProfileFallsBack(t *testing.T) {
	d := Decide(labConfig(), promptLong, Pod{Name: "x", Class: "unknown"}, []Pod{a30(0)})
	if !d.Fallback {
		t.Fatalf("want fallback, got %+v", d)
	}
}

func TestDecideBurstSplitsUntilSLO(t *testing.T) {
	// Each request queued on the A30 adds AvgQueuedPromptTokens / 5000 s.
	remote := 0
	for waiting := 0; waiting < 10; waiting++ {
		if Decide(labConfig(), promptLong, gaudi(40), []Pod{a30(waiting)}).Remote {
			remote++
		}
	}
	if remote != 3 {
		t.Fatalf("remote decisions in a burst of 10 = %d, want 3", remote)
	}
}

func TestDecideStallCrossover(t *testing.T) {
	// Busy decode pods offload; lightly loaded ones keep prefill local.
	var firstRemote = -1
	for running := 0; running <= 64; running++ {
		if Decide(labConfig(), promptLong, gaudi(running), []Pod{a30(0)}).Remote {
			firstRemote = running
			break
		}
	}
	if firstRemote < 10 || firstRemote > 30 {
		t.Fatalf("first offload at %d running streams, want between 10 and 30", firstRemote)
	}
	for running := firstRemote; running <= 64; running++ {
		if !Decide(labConfig(), promptLong, gaudi(running), []Pod{a30(0)}).Remote {
			t.Fatalf("decision flipped back to local at %d running streams", running)
		}
	}
}

func TestDecidePicksFastestPrefillCandidate(t *testing.T) {
	c := labConfig()
	c.Profiles["nvidia-b200"] = Profile{PrefillTokensPerSec: 50000}
	b200Busy := Pod{Name: "b200-0", Class: "nvidia-b200", Waiting: 40}
	d := Decide(c, promptLong, gaudi(40), []Pod{a30(0), b200Busy})
	if d.Prefill != "a30-0" {
		t.Fatalf("with a queued B200 want a30-0, got %q", d.Prefill)
	}
	b200Idle := Pod{Name: "b200-0", Class: "nvidia-b200"}
	d = Decide(c, promptLong, gaudi(40), []Pod{a30(0), b200Idle})
	if d.Prefill != "b200-0" {
		t.Fatalf("with an idle B200 want b200-0, got %q", d.Prefill)
	}
}

func TestDecideSameClassBandwidth(t *testing.T) {
	c := labConfig()
	c.SameClassBandwidthGbps = 200
	peer := Pod{Name: "gaudi-1", Class: classGaudi3}
	d := Decide(c, promptLong, gaudi(40), []Pod{a30(0), peer})
	if d.Prefill != "gaudi-1" || !d.Remote {
		t.Fatalf("want remote prefill on the idle Gaudi peer, got %+v", d)
	}
	assertNear(t, "transfer", d.TransferSeconds, 2000.0*131072/25e9)
}

func TestDecideFingerprintMismatch(t *testing.T) {
	decode := gaudi(40)
	decode.Fingerprint = "llama-3.1-8b@abc"
	other := a30(0)
	other.Fingerprint = "llama-3.1-8b@def"
	d := Decide(labConfig(), promptLong, decode, []Pod{other})
	if d.Remote || d.Reason != ReasonNoPrefillCandidate {
		t.Fatalf("mismatched fingerprints must not split, got %+v", d)
	}
	other.Fingerprint = decode.Fingerprint
	if !Decide(labConfig(), promptLong, decode, []Pod{other}).Remote {
		t.Fatal("matching fingerprints should split")
	}
}

func TestDecideZeroSLODisablesCheck(t *testing.T) {
	c := labConfig()
	c.TTFTSLOMs = 0
	if !Decide(c, promptLong, gaudi(200), []Pod{a30(20)}).Remote {
		t.Fatal("without an SLO a heavily loaded decode pod should still offload")
	}
}

func TestConfigValidate(t *testing.T) {
	if err := labConfig().Validate(); err != nil {
		t.Fatalf("lab config invalid: %v", err)
	}
	bad := []func(*Config){
		func(c *Config) { c.KVBytesPerToken = 0 },
		func(c *Config) { c.TTFTSLOMs = -1 },
		func(c *Config) { c.StallWeight = -1 },
		func(c *Config) { c.SafetyMargin = 1 },
		func(c *Config) { c.MaxDecodeKVUsage = 0 },
		func(c *Config) { c.MaxDecodeKVUsage = 1.5 },
		func(c *Config) { c.MinUncachedTokens = -1 },
		func(c *Config) { c.BandwidthGbps = 0 },
		func(c *Config) { c.SameClassBandwidthGbps = -1 },
		func(c *Config) { c.AvgQueuedPromptTokens = -1 },
		func(c *Config) { c.Profiles["bad"] = Profile{} },
	}
	for i, mutate := range bad {
		c := labConfig()
		mutate(&c)
		if c.Validate() == nil {
			t.Errorf("case %d: invalid config accepted", i)
		}
	}
}

func assertNear(t *testing.T, name string, got, want float64) {
	t.Helper()
	if math.Abs(got-want) > 1e-9 {
		t.Fatalf("%s = %v, want %v", name, got, want)
	}
}
