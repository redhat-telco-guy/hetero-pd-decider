# NVIDIA mixed-generation lab on AWS (T4 + A10G + L4)

Tests hetero-pd-decider's compatibility rule on three NVIDIA generations while the Gaudi
server is being repaired. Same model and settings on all three; only the card differs.

| Pod | Card | Architecture | Role |
|---|---|---|---|
| `prefill-t4` | Tesla T4, 16 GB | Turing, compute capability 7.5 | reads prompts |
| `prefill-a10g` | A10G, 24 GB | Ampere, 8.6 | reads prompts |
| `decode-l4` | L4, 24 GB | Ada, 8.9 | writes answers, behind the routing sidecar |

Model: Qwen2.5-1.5B-Instruct in fp16 (the T4 has no bf16, and both sides of a handoff need the same KV dtype).

## Before you start: Dual-Key shares these GPUs

Dual-Key runs vLLM servers on the same T4/A10G/L4 nodes. Each `xlarge` node has one GPU, so free one
GPU per type first, for example by scaling Dual-Key's model servers to 0 for the duration:

```
oc get deploy -A -l app.kubernetes.io/managed-by=dualkey      # or: oc get deploy -n dualkey
oc scale deploy/<name> -n <ns> --replicas=0
```

Also keep Dual-Key in `alert` mode, or stop its prober, while this lab runs: in `discover` mode it could
pick up these three servers as a comparison group. The installer checks for a free GPU of each type and
stops if there is none.

## Install

```
oc login ... (the AWS cluster)
bash lab/aws-nvidia/install-all.sh 2>&1 | tee aws-install.txt
```

About 30–40 minutes: the router build (with the plugin tests), three model downloads, the
compatibility labeler, a prefill-speed measurement, the router and the dashboard.

## Watching a test suite and keeping the evidence

| Script | What it does |
|---|---|
| `73-suite-status.sh` | One status snapshot: keys and measured speeds, suite progress, every finished run with its errors, the cards, router decisions, refused handoffs |
| `75-watch-status.sh` | Leave running in its own terminal tab (`caffeinate -i` on a Mac): writes that snapshot to `suite-status.txt` every 2 minutes |
| `74-why-down.sh` | When a model server restarted: last exit reason (for example OOMKilled), its last log lines, warning events |
| `76-export-evidence.sh` | Exports raw runs, a results summary, keys and settings, pair tests and logs to `evidence/aws-<date>/` and a zip |

Results of the Nov 2, 2026 run are in the main [README](../../README.md#results-so-far) and in
[`evidence/aws-2026-11-02/`](../../evidence/aws-2026-11-02).

## Test plan

**1. What keys did each card get?** (`60-compat-install.sh` prints them, with the inputs behind each key.)
Expected with default backends: A10G and L4 both use FlashAttention, so they get the **same key**. The T4 can't
use FlashAttention (it needs compute capability 8.0+), so vLLM picks another backend, and the T4 gets a
**different key**.

**2. Does the plugin keep incompatible pairs apart?** Run traffic from the dashboard. Expected:
- splits only go **A10G → L4**, never T4 → L4 (the prefill filter drops the T4)
- `hetero_pd_decision_total` shows reasons for compatible pairs only, and `no-compatible-prefill`
  if the A10G is scaled down: `oc scale deploy/prefill-a10g -n hetero-pd-aws --replicas=0`

**3. Is the T4 → L4 handoff really incompatible?** You don't have to start this: the labeler sees the new pair of
keys and runs the test by itself. Watch it on the dashboard (The stack → Card compatibility), or with
`NS=hetero-pd-aws bash lab/compat/62-approve-pair.sh list`. Expected: **Failed**, with split requests
refused at the handoff or wrong tokens. That reproduces the maintainer's B300 + GH200 finding. There's
nothing to approve; the pair stays blocked.

**4. Make them compatible with one backend.** Set `BACKEND=TRITON_ATTN` (or another backend all three support)
in `config.env` and re-run `05-aws-model-servers.sh`. Expected:
- within a minute all three servers show the **same key**, so every pair is allowed automatically, with nothing to approve
- optional check: `NS=hetero-pd-aws MODEL=Qwen/Qwen2.5-1.5B-Instruct bash lab/compat/61-validate-pair.sh prefill-t4 decode-l4 20`
  should **PASS**, matching the maintainer's 6/6 with one backend on both sides

**5. The approval flow, and learning from failures.** With default backends, a pair that tests **Passed** but has
different keys waits for you: click **Approve** on the dashboard, and within about 30 s the answering pod carries
`accept.kv-compat.llm-d.ai/<key>=true` and the router starts using the pair, without a restart. **Revoke**
removes it the same way. To see the failure watch, approve a pair and then break it (for example restart the
reading server with a different `--block-size`): after 3 failed handoffs, `hetero_pd_pair_exclusions_total`
goes up and the pair is paused for 10 minutes, while its new key triggers a new test.

**6. Speed-aware choice.** With everything compatible (step 4), the measured speeds differ (the T4 is much
slower at prefill), so the plugin should prefer the A10G, and keep long prompts on the L4 when only the
T4 is free and it's slower than the L4 itself.
