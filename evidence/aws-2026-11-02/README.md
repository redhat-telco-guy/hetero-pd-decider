# Evidence: hetero-pd-decider on AWS (T4 + A10G prefill, L4 decode)

| File | What it shows |
|---|---|
| results-summary.md | Per suite and scenario: failed requests per run, documents completed, median first-token times |
| runs.csv / runs-raw.json | Every recorded run, as recorded by the test dashboard |
| pods-keys-and-speeds.json | Each model server's compatibility key, the settings behind it, and its measured prefill speed |
| kv-compat-approvals.json / kv-compat-results.json | Pair test results (validation job) and approvals |
| decode-l4-handshake-errors-default-backends.log | The same errors captured during the default-backend run (T4 to L4 handoffs rejected) |
| router-configs.yaml | The router configurations compared: stock prefix-based-pd-decider and hetero-pd-decider |
| cluster.txt, images.txt | OpenShift/Kubernetes versions, GPU nodes, container images |
| labeler.log | The labeler's recent decisions (keys, tests, speed measurements) |

Suites: the earlier one ran with each card's default attention backend (T4: TRITON_ATTN, A10G/L4: FLASH_ATTN);
the later one with --attention-backend TRITON_ATTN on all three. Runs from before a dashboard fix, where every
request failed because of a wrong model name, are left out of the summary and CSV but kept in runs-raw.json.
