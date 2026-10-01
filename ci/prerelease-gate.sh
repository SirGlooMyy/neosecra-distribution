#!/usr/bin/env bash
# NeoSecra Distribution - Pre-release CI Gate
# Enforces that all schema, signature, recovery, and promotion tests pass
# before allowing a stable release to be published.

set -Eeuo pipefail

umask 077
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ARCHIVE="" VERSION="" TRUST_POLICY="minisign-package-v1" REGISTRY=""
while [[ $# -gt 0 ]]; do
  [[ $# -ge 2 ]] || { echo "Gate option requires a value" >&2; exit 2; }
  case "$1" in
    --archive) ARCHIVE="$2" ;; --version) VERSION="$2" ;; --trust-policy) TRUST_POLICY="$2" ;; --registry) REGISTRY="$2" ;;
    *) echo "Unknown gate option" >&2; exit 2 ;;
  esac
  shift 2
done
[[ "$TRUST_POLICY" == "cosign-spdx-v1" || "$TRUST_POLICY" == "minisign-package-v1" ]] || { echo "Unsupported trust policy" >&2; exit 2; }
if [[ -n "$ARCHIVE" || -n "$VERSION" ]]; then
  [[ -f "$ARCHIVE" && ! -L "$ARCHIVE" && "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid gate artifact/version" >&2; exit 2; }
  python3 - "$ROOT" "$ARCHIVE" "$REGISTRY" "$TRUST_POLICY" <<'PY'
import sys
sys.path.insert(0,sys.argv[1]+'/update-server/lib')
from archive import inspect
from registry import read_json
reg=read_json(sys.argv[3]) if sys.argv[3] else None
if reg is not None and reg['trust_policy'] != sys.argv[4]:
    raise SystemExit('Gate trust policy differs from registry')
allowlist=reg["secret_allowlist"] if reg is not None else []
inspect(sys.argv[2],allowlist)
PY
fi

echo "============================================================"
echo "[GATE] NeoSecra Pre-release Gate Verification"
echo "============================================================"

# 1. Dependency Hard-Gate
echo "[GATE] Checking mandatory security and build tools..."
MISSING_TOOLS=0
GATE_TOOLS=(python3 pytest minisign docker)
if [[ "$TRUST_POLICY" == "cosign-spdx-v1" ]]; then GATE_TOOLS+=(cosign); fi
for tool in "${GATE_TOOLS[@]}"; do
  if [[ "$tool" == minisign && -n "${MINISIGN_BIN:-}" && -x "$MINISIGN_BIN" ]]; then continue; fi
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

# Artifact policy checks authenticate the actual package's immutable images.
if [[ -n "$ARCHIVE" && "$TRUST_POLICY" == "cosign-spdx-v1" ]]; then
  TRUST_ARGS=(--archive "$ARCHIVE" --version "$VERSION")
  [[ -z "$REGISTRY" ]] || TRUST_ARGS+=(--registry "$REGISTRY")
  python3 "$ROOT/update-server/lib/cosign_gate.py" "${TRUST_ARGS[@]}"
fi

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
