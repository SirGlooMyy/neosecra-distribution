#!/usr/bin/env bash
# NeoSecra Distribution - Pre-release CI Gate
# Enforces that all schema, signature, recovery, and promotion tests pass
# before allowing a stable release to be published.

set -Eeuo pipefail

echo "============================================================"
echo "[GATE] NeoSecra Pre-release Gate Verification"
echo "============================================================"

# 1. Dependency Hard-Gate
echo "[GATE] Checking mandatory security and build tools..."
MISSING_TOOLS=0
for tool in python3 pytest minisign cosign docker; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "[GATE-ERROR] Missing mandatory tool: $tool"
    MISSING_TOOLS=1
  fi
done

if [[ $MISSING_TOOLS -eq 1 ]]; then
  echo "[GATE-ERROR] Fail-closed due to missing mandatory tools."
  exit 1
fi
echo "[GATE] All mandatory tools are present."

# 2. Test Execution Hard-Gate
echo "[GATE] Executing critical integration and contract tests..."
export PYTHONPATH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Run pytest. If any test fails, pytest exits > 0, which triggers pipefail/set -e.
if ! pytest "${PYTHONPATH}/tests" -v --disable-warnings; then
  echo "[GATE-ERROR] Security tests failed. Fail-closed."
  exit 1
fi

echo "============================================================"
echo "[GATE] SUCCESS: All checks passed. Stable promotion unlocked."
echo "============================================================"
exit 0
