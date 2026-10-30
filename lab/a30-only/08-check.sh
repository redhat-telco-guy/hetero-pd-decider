#!/usr/bin/env bash
# End-to-end check: requests through the router, a forced handoff between the two A30s, answers compared.
source "$(dirname "$0")/lib.sh"; login
hr "Correctness gate: the same questions answered with and without the handoff"
DECODE=decode-a30 bash $REPO/lab/scripts/12-correctness.sh
