#!/usr/bin/env bash
# Commit and push the repo under your own name only (no co-author lines, no AI attribution).
#   bash lab/scripts/56-push.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
echo "Committing as: $(git config user.name) <$(git config user.email)>"
git add -A
echo; echo "Files in this commit: $(git diff --cached --name-only | wc -l | tr -d ' ')"
git diff --cached --stat | tail -1
# stop if anything staged names Claude/Anthropic or carries a co-author line
if git diff --cached -- . ":(exclude)lab/scripts/56-push.sh" | grep -iqE "^\+.*(claude|anthropic|co-authored-by)"; then
  echo; echo "STOP: these staged lines mention Claude/Anthropic/co-author:"; git diff --cached -- . ":(exclude)lab/scripts/56-push.sh" | grep -inE "^\+.*(claude|anthropic|co-authored-by)" | head; exit 1
fi
# stop on anything that looks like a secret
if git diff --cached -- . ":(exclude)lab/scripts/56-push.sh" | grep -qE "^\+.*(hf_[A-Za-z0-9]{20,}|sha256~[A-Za-z0-9_-]{20,}|ghp_[A-Za-z0-9]{20,}|github_pat_|PRIVATE KEY)"; then
  echo "STOP: a staged line looks like a token or key. Nothing was committed."; exit 1
fi
git commit -q -F - <<'MSG'
Auto strategy, A30 lab results, mixed-vendor lab tooling

- plugin: auto strategy (stock answer first, overruled only when the other path is >=25% cheaper), tests, regenerated patch
- lab: A30-only rebuild scripts, mixed A30 + Gaudi 3 build/deploy, dashboard v2 (decision walkthrough, test suites, value tab)
- lab/hwmon: live hardware panel (BMC fans/temps/power, card temps, NICs) and a heat test with safety stops
- lab/mixed: in-cluster Gaudi thermal watchdog and thermal test
- results: suite results and run history from the ai154 A30 lab (lab-archive/*/results)
- docs/upstream: draft llm-d feature request
MSG
git log -1 --format='Committed %h by %an <%ae>%n%n%B'
git push origin HEAD
echo; echo "Pushed. Check: https://github.com/redhat-telco-guy/hetero-pd-decider/commits"
