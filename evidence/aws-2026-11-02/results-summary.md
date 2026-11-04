# Results summary

Medians across repeats, generated from runs-raw.json. Only complete test suites are summarised;
'Failed requests' lists each run separately. Doc first token = time until a document's first answer token.

## Test 1: each card's default attention backend (T4 TRITON_ATTN, A10G and L4 FLASH_ATTN)

Started 2026-11-02 20:08 UTC, 30 runs (3 repeats, stock and plugin alternated).

| Scenario | Mode | Runs | Failed requests (each run) | Docs done | Doc first token | Chat first token p95 | Output tok/s |
|---|---|---|---|---|---|---|---|
| Busy chat | llm-d default | 3 | 0, 0, 0 | 0, 0, 0 | - | 154 ms | 1567 |
| Busy chat | with plugin | 3 | 0, 0, 0 | 0, 0, 0 | - | 171 ms | 1558 |
| Busy + 700-token docs | llm-d default | 3 | 0, 0, 0 | 86, 86, 86 | 98 ms | 178 ms | 1541 |
| Busy + 700-token docs | with plugin | 3 | 0, 0, 0 | 86, 86, 86 | 101 ms | 191 ms | 1542 |
| Busy + 2,000-token docs | llm-d default | 3 | 43, 40, 37 | 43, 46, 49 | 233 ms | 201 ms | 1547 |
| Busy + 2,000-token docs | with plugin | 3 | 0, 0, 0 | 86, 86, 86 | 228 ms | 234 ms | 1547 |
| Idle + 2,000-token docs | llm-d default | 3 | 73, 70, 76 | 13, 16, 10 | 81 ms | - | 5 |
| Idle + 2,000-token docs | with plugin | 3 | 0, 0, 0 | 86, 86, 86 | 53 ms | - | 30 |
| Light chat | llm-d default | 3 | 0, 0, 0 | 0, 0, 0 | - | 84 ms | 545 |
| Light chat | with plugin | 3 | 0, 0, 0 | 0, 0, 0 | - | 52 ms | 563 |

## Test 2: --attention-backend TRITON_ATTN on all three cards

Started 2026-11-03 01:59 UTC, 36 runs (3 repeats, stock and plugin alternated).

| Scenario | Mode | Runs | Failed requests (each run) | Docs done | Doc first token | Chat first token p95 | Output tok/s |
|---|---|---|---|---|---|---|---|
| Busy chat | llm-d default | 3 | 0, 0, 0 | 0, 0, 0 | - | 143 ms | 1614 |
| Busy chat | with plugin | 3 | 0, 0, 0 | 0, 0, 0 | - | 171 ms | 1605 |
| Busy + 700-token docs | llm-d default | 3 | 0, 0, 0 | 86, 86, 86 | 99 ms | 174 ms | 1577 |
| Busy + 700-token docs | with plugin | 3 | 0, 0, 0 | 86, 86, 86 | 98 ms | 188 ms | 1579 |
| Busy + 2,000-token docs | llm-d default | 3 | 0, 0, 0 | 86, 86, 86 | 294 ms | 182 ms | 1583 |
| Busy + 2,000-token docs | with plugin | 3 | 0, 0, 0 | 86, 86, 86 | 311 ms | 150 ms | 1582 |
| Idle + 2,000-token docs | llm-d default | 3 | 0, 0, 0 | 86, 86, 86 | 198 ms | - | 30 |
| Idle + 2,000-token docs | with plugin | 3 | 0, 0, 0 | 86, 86, 86 | 35 ms | - | 30 |
| Busy + 6,000-token reports | llm-d default | 3 | 0, 0, 0 | 43, 43, 43 | 849 ms | 168 ms | 1563 |
| Busy + 6,000-token reports | with plugin | 3 | 0, 0, 0 | 43, 43, 43 | 610 ms | 209 ms | 1553 |
| Light chat | llm-d default | 3 | 0, 0, 0 | 0, 0, 0 | - | 78 ms | 550 |
| Light chat | with plugin | 3 | 0, 0, 0 | 0, 0, 0 | - | 47 ms | 568 |

## Not counted

Partial suites, kept in runs.csv: quick check runs, a suite stopped when the decode
server ran out of memory (its limit was raised afterwards), and a restarted suite.

- started 2026-11-02 19:20 UTC: 1 runs
- started 2026-11-02 19:31 UTC: 8 runs
- started 2026-11-03 01:13 UTC: 5 runs
- started 2026-11-03 01:42 UTC: 1 runs
