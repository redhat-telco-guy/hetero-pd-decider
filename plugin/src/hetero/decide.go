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

// Package hetero holds the P/D split decision for pools of different
// accelerator classes. It depends only on the standard library so the
// decision can be tested and simulated outside the EPP.
package hetero

import (
	"errors"
	"fmt"
	"math"
)

// Reason values explain a Decision. They are used as a metric label.
const (
	ReasonRemoteBetter       = "remote-better"
	ReasonLocalBetter        = "local-better"
	ReasonShortPrompt        = "short-prompt"
	ReasonDecodeKVFull       = "decode-kv-full"
	ReasonDecodeDisabled     = "decode-disabled"
	ReasonNoPrefillCandidate = "no-prefill-candidate"
	ReasonSLOMiss            = "remote-misses-slo"
	ReasonMissingProfile     = "missing-profile"
)

// Profile is the measured prefill throughput of one accelerator class
// for the served model.
type Profile struct {
	PrefillTokensPerSec float64 `json:"prefillTokensPerSec"`
}

// Config holds the decision parameters.
type Config struct {
	// KVBytesPerToken is the KV-cache size of one token across all layers.
	KVBytesPerToken int64 `json:"kvBytesPerToken"`
	// TTFTSLOMs rejects the remote path when its estimate exceeds it. Zero disables the check.
	TTFTSLOMs float64 `json:"ttftSLOMs"`
	// StallWeight is the cost of one second of decode stall, summed over the
	// streams running on the decode pod, relative to one second of the new
	// request's time to first token.
	StallWeight float64 `json:"stallWeight"`
	// SafetyMargin is the fraction by which remote must beat local, in [0, 1).
	SafetyMargin float64 `json:"safetyMargin"`
	// MaxDecodeKVUsage keeps requests local when decode KV usage (0 to 1) is at or above it.
	MaxDecodeKVUsage float64 `json:"maxDecodeKVUsage"`
	// MinUncachedTokens keeps requests with fewer uncached tokens local without estimation.
	MinUncachedTokens int `json:"minUncachedTokens"`
	// BandwidthGbps is the prefill-to-decode KV transfer bandwidth across classes.
	BandwidthGbps float64 `json:"bandwidthGbps"`
	// SameClassBandwidthGbps applies when both pods share a class. Zero means BandwidthGbps.
	SameClassBandwidthGbps float64 `json:"sameClassBandwidthGbps"`
	// AvgQueuedPromptTokens estimates the prefill work behind each waiting request.
	AvgQueuedPromptTokens int `json:"avgQueuedPromptTokens"`
	// Profiles maps accelerator class to its prefill throughput.
	Profiles map[string]Profile `json:"profiles"`
}

// DefaultConfig returns the parameter defaults. Profiles are left empty and must be measured.
func DefaultConfig() Config {
	return Config{
		KVBytesPerToken:       131072,
		TTFTSLOMs:             0,
		StallWeight:           0.25,
		SafetyMargin:          0.1,
		MaxDecodeKVUsage:      0.9,
		MinUncachedTokens:     256,
		BandwidthGbps:         10,
		AvgQueuedPromptTokens: 1024,
		Profiles:              map[string]Profile{},
	}
}

// Validate reports the first invalid parameter.
func (c Config) Validate() error {
	switch {
	case c.KVBytesPerToken <= 0:
		return errors.New("kvBytesPerToken must be positive")
	case c.TTFTSLOMs < 0:
		return errors.New("ttftSLOMs cannot be negative")
	case c.StallWeight < 0:
		return errors.New("stallWeight cannot be negative")
	case c.SafetyMargin < 0 || c.SafetyMargin >= 1:
		return errors.New("safetyMargin must be in [0, 1)")
	case c.MaxDecodeKVUsage <= 0 || c.MaxDecodeKVUsage > 1:
		return errors.New("maxDecodeKVUsage must be in (0, 1]")
	case c.MinUncachedTokens < 0:
		return errors.New("minUncachedTokens cannot be negative")
	case c.BandwidthGbps <= 0:
		return errors.New("bandwidthGbps must be positive")
	case c.SameClassBandwidthGbps < 0:
		return errors.New("sameClassBandwidthGbps cannot be negative")
	case c.AvgQueuedPromptTokens < 0:
		return errors.New("avgQueuedPromptTokens cannot be negative")
	}
	for class, p := range c.Profiles {
		if p.PrefillTokensPerSec <= 0 {
			return fmt.Errorf("profile %q: prefillTokensPerSec must be positive", class)
		}
	}
	return nil
}

// Pod is the state of one candidate pod at decision time.
type Pod struct {
	Name  string
	Class string
	// Fingerprint identifies the served model build. Pods with different
	// non-empty fingerprints never exchange KV.
	Fingerprint string
	Running     int
	Waiting     int
	KVUsage     float64
	Disabled    bool
}

// Decision is the outcome for one request. Seconds fields are zero when not estimated.
type Decision struct {
	Remote bool
	// Fallback is set when the inputs cannot be estimated; the caller applies its default rule.
	Fallback bool
	Reason   string
	// Prefill names the prefill pod the estimate used when Remote is set.
	Prefill         string
	RemoteSeconds   float64
	LocalSeconds    float64
	StallSeconds    float64
	TransferSeconds float64
}

func (c Config) rate(class string) (float64, bool) {
	p, ok := c.Profiles[class]
	return p.PrefillTokensPerSec, ok && p.PrefillTokensPerSec > 0
}

func (c Config) bandwidthBytesPerSec(from, to string) float64 {
	gbps := c.BandwidthGbps
	if from == to && from != "" && c.SameClassBandwidthGbps > 0 {
		gbps = c.SameClassBandwidthGbps
	}
	return gbps * 1e9 / 8
}

func (c Config) queueSeconds(p Pod, rate float64) float64 {
	return float64(p.Waiting*c.AvgQueuedPromptTokens) / rate
}

func compatible(a, b Pod) bool {
	return a.Fingerprint == "" || b.Fingerprint == "" || a.Fingerprint == b.Fingerprint
}

// Decide chooses between prefilling uncached tokens on the decode pod and
// prefilling them on the best prefill candidate followed by a KV transfer.
//
//	remote = U/R_P + Q_P + U*b/BW
//	local  = U/R_D + Q_D
//	stall  = N_D * U/R_D
//	split when remote <= SLO and remote < (1 - margin) * (local + w * stall)
func Decide(c Config, uncachedTokens int, decode Pod, prefill []Pod) Decision {
	if uncachedTokens < c.MinUncachedTokens || uncachedTokens <= 0 {
		return Decision{Reason: ReasonShortPrompt}
	}
	if decode.Disabled {
		return Decision{Reason: ReasonDecodeDisabled}
	}
	if decode.KVUsage >= c.MaxDecodeKVUsage {
		return Decision{Reason: ReasonDecodeKVFull}
	}
	rateD, ok := c.rate(decode.Class)
	if !ok {
		return Decision{Fallback: true, Reason: ReasonMissingProfile}
	}

	u := float64(uncachedTokens)
	local := u/rateD + c.queueSeconds(decode, rateD)
	stall := float64(decode.Running) * u / rateD

	best := Decision{Reason: ReasonNoPrefillCandidate, RemoteSeconds: math.Inf(1)}
	sawCandidate := false
	for _, p := range prefill {
		if p.Name == decode.Name || p.Disabled || !compatible(p, decode) {
			continue
		}
		rateP, ok := c.rate(p.Class)
		if !ok {
			continue
		}
		sawCandidate = true
		transfer := u * float64(c.KVBytesPerToken) / c.bandwidthBytesPerSec(p.Class, decode.Class)
		remote := u/rateP + c.queueSeconds(p, rateP) + transfer
		if remote < best.RemoteSeconds {
			best = Decision{Prefill: p.Name, RemoteSeconds: remote, TransferSeconds: transfer}
		}
	}

	best.LocalSeconds = local
	best.StallSeconds = stall
	if !sawCandidate {
		best.RemoteSeconds = 0
		best.Reason = ReasonNoPrefillCandidate
		best.Prefill = ""
		return best
	}
	if c.TTFTSLOMs > 0 && best.RemoteSeconds*1000 > c.TTFTSLOMs {
		best.Reason = ReasonSLOMiss
		return best
	}
	if best.RemoteSeconds < (1-c.SafetyMargin)*(local+c.StallWeight*stall) {
		best.Remote = true
		best.Reason = ReasonRemoteBetter
		return best
	}
	best.Reason = ReasonLocalBetter
	return best
}
