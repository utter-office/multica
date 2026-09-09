#!/usr/bin/env bash
# dsh-subprocess scrubs credential-shaped env vars (names matching
# KEY|PASSWORD|SECRET|TOKEN) before spawning tool subprocesses, which strips
# the task-scoped MULTICA_TOKEN the daemon injects on purpose — every
# `multica` CLI call inside a task bash tool then fails with "agent execution
# context requires MULTICA_TOKEN" (observed on SIT, exe-05/exe-06).
#
# Exempt MULTICA_TOKEN from the scrub. The anchor assertions make a dsh
# upgrade that moves this code fail the image build instead of silently
# re-breaking agent tasks.
set -euo pipefail

patched=0
for f in $(find /usr/local/lib/node_modules/@deepseek-ai -path '*/dsh-subprocess/lib/index.js' 2>/dev/null); do
  if grep -q 'key === "MULTICA_TOKEN" || !SENSITIVE_ENV_PATTERN.test(key)' "$f"; then
    echo "patch-dsh: already patched, skipping $f"
    patched=1
    continue
  fi
  # anchor: the unpatched scrub line must exist exactly as upstream ships it
  grep -q 'value !== void 0 && !SENSITIVE_ENV_PATTERN.test(key)' "$f" \
    || { echo "patch-dsh: scrub anchor missing in $f — dsh layout changed? refusing to patch blindly" >&2; exit 1; }
  sed -i 's/!SENSITIVE_ENV_PATTERN\.test(key)/(key === "MULTICA_TOKEN" || !SENSITIVE_ENV_PATTERN.test(key))/g' "$f"
  grep -q 'key === "MULTICA_TOKEN" || !SENSITIVE_ENV_PATTERN.test(key)' "$f" \
    || { echo "patch-dsh: patch did not land in $f" >&2; exit 1; }
  echo "patch-dsh: MULTICA_TOKEN exemption applied to $f"
  patched=1
done
[ "$patched" -eq 1 ] \
  || { echo "patch-dsh: no dsh-subprocess/lib/index.js found under /usr/local/lib/node_modules/@deepseek-ai" >&2; exit 1; }
echo "patch-dsh: ok"
