#!/usr/bin/env bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1
SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MINISIGN_BIN="${MINISIGN_BIN:-$(command -v minisign || true)}"
[[ -n "$MINISIGN_BIN" ]] || { echo "minisign is required to validate channel signatures" >&2; exit 1; }
export MINISIGN_BIN
ROOT="${1:-${SCRIPT_ROOT}}"
WWW_ROOT="${2:-}"
REGISTRY_ROOT="$SCRIPT_ROOT"
if [[ -d "$ROOT/products" ]]; then REGISTRY_ROOT="$ROOT"; fi
if [[ -n "${NEOSECRA_CHANNEL_PUBLIC_KEY:-}" ]]; then
  PUBLIC_KEYS="$NEOSECRA_CHANNEL_PUBLIC_KEY"
  [[ -e "$PUBLIC_KEYS" ]] || { echo "missing explicitly pinned channel public key" >&2; exit 1; }
else
  PUBLIC_KEYS="$ROOT/public-keys"
  if [[ ! -e "$PUBLIC_KEYS" ]]; then PUBLIC_KEYS="$SCRIPT_ROOT/public-keys"; fi
fi
python3 - "$ROOT" "$WWW_ROOT" "$PUBLIC_KEYS" "$REGISTRY_ROOT" "$SCRIPT_ROOT" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0,sys.argv[5]+'/update-server/lib')
from registry import load_registry,read_json,validate_channel
from verify import signature
root=Path(sys.argv[1]);www=Path(sys.argv[2]) if sys.argv[2] else None
registry_root=Path(sys.argv[4]);count=0
for path in sorted((registry_root/'products').glob('*.json')):
    reg=load_registry(registry_root,path.stem)
    for channel in reg['channels']:
        name=reg['code']+'-'+channel
        source=root/'channels'/(name+'.json')
        signature(source,sys.argv[3])
        validate_channel(read_json(source),reg,name)
        if www:
            copy=www/'channels'/source.name
            if source.read_bytes()!=copy.read_bytes() or Path(str(source)+'.minisig').read_bytes()!=Path(str(copy)+'.minisig').read_bytes():
                raise SystemExit('channel source-of-truth drift')
        count+=1
if not count: raise SystemExit('no registered channels')
print(f'validated {count} registered channels')
PY
