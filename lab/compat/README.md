# KV compatibility: keys, automatic tests and approvals

Two model servers can only hand KV to each other when they match in everything vLLM checks during the
NIXL handshake: model path string, vLLM build, attention backend, KV layout, block size, KV dtype and
parallelism. Two GPU generations from one vendor can match. Different vendors usually don't, until a
connector bridges the layout and a test proves it.

## How it works

| Step | Who | What happens |
|---|---|---|
| 1. Key | automatic | The labeler gives every model server `llm-d.ai/kv-compat-key`, a hash of those settings, every 30 s. If anything can't be read, the server gets no key. |
| 2. Same key | automatic | Allowed. Nothing to approve. |
| 3. Different keys | automatic | A record appears in ConfigMap `kv-compat-approvals` (`untested`). The labeler runs the validation Job, one pair at a time, and stores `passed` / `failed` / `error`. |
| 4. Approve | **you** | Dashboard: The stack → Card compatibility → **Approve** (only offered on `passed`). Or `bash lab/compat/62-approve-pair.sh approve <pair id>`, or edit the ConfigMap in the OpenShift console. |
| 5. Apply | automatic | Within about 30 s the labeler labels the answering pods `accept.kv-compat.llm-d.ai/<prefillKey>=true`. hetero-pd-decider reads this live, with no router restart. |
| Revoke / re-test | you | Revoke removes the label within about 30 s. Re-test clears the approval and runs the test again. |
| Settings change | automatic | A new key means a new pair: tested again, and blocked until approved again. |
| Failures in use | automatic | 3 failed handoffs in a row pause the pair for 10 minutes (`hetero_pd_pair_exclusions_total`). |
| Speed | automatic | When a server's key changes (new pod or new settings), the labeler measures its prefill speed once and labels it `llm-d.ai/prefill-tokens-per-sec`. hetero-pd-decider uses it live instead of the class profile; no re-measuring until the key changes again. It waits while the server is busy. `MEASURE_SPEED=false` turns it off. |

## Files

| File | Purpose |
|---|---|
| `compat_labeler.py`, `compat.yaml` | The labeler (keys, approval records, automatic tests, accept labels) and its permissions. `AUTO_TEST=false` turns automatic testing off. |
| `validate_pair.py`, `61-validate-pair.sh` | The validation Job; also runnable by hand. The result lands in the same record. |
| `62-approve-pair.sh` | `list`, `approve`, `revoke`, `retest` from the command line. |
| `60-compat-install.sh` | Installs the labeler, updates the dashboard, and shows keys and pairs. |
| `dashboard-patch/` | The dashboard's Card compatibility panel, already applied to `lab/dashboard2`. |

## What the test checks

The handoff is checked end to end, not as raw KV bytes. It passes when:
- every split request succeeds (a rejected handshake fails here)
- the first answer token matches the answering card's own answer in ≥ 95% of prompts
- the answers stay identical at least as long as the reading card's own answers do, minus 10%

A broken layout, the silent-garbage case, disagrees from the first token.

## The rule in hetero-pd-decider (`compatibility: auto`)

| Situation | Result |
|---|---|
| Same key | may split |
| Different keys, approved (live label or `approvedPairs` in the config) | may split, in that direction only |
| Different keys, not approved | never split (`no-compatible-prefill`) |
| A key missing, pool has one accelerator class | may split (behaves as before) |
| A key missing, pool has several classes | never split |

The same rule runs in two places:
- **The decider.**
- **The `hetero-kv-compat-filter` in the `prefill` profile:** it limits which pod the prefill profile can pick.

So a pair that can't exchange KV is never scheduled.

The dashboard has no login. Anyone who can open it can approve, so put it behind OpenShift login before sharing it.
