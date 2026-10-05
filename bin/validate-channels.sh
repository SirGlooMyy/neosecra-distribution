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
if command -v python3 >/dev/null 2>&1 && python3 -c 'import sys' >/dev/null 2>&1; then
  PYTHON_BIN=python3
elif command -v python >/dev/null 2>&1 && python -c 'import sys' >/dev/null 2>&1; then
  PYTHON_BIN=python
else
  echo "python3 or python is required to validate channels" >&2; exit 1
fi
# Do not pass an empty positional argument: native Windows Python can drop it.
PYTHON_ARGS=("$ROOT" "$PUBLIC_KEYS" "$REGISTRY_ROOT" "$SCRIPT_ROOT")
if [[ -n "$WWW_ROOT" ]]; then PYTHON_ARGS+=("$WWW_ROOT"); fi
"$PYTHON_BIN" - "${PYTHON_ARGS[@]}" <<'PY'
import sys
from pathlib import Path
root_text,public_keys,registry_text,script_text,*www_args=sys.argv[1:]
sys.path.insert(0,script_text+'/update-server/lib')
from registry import load_registry,read_json,repo_file,validate_channel,validate_empty_channel
from verify import signature
root=Path(root_text);www=Path(www_args[0]) if www_args else None
registry_root=Path(registry_text);count=0;pending=[]
for path in sorted((registry_root/'products').glob('*.json')):
    reg=load_registry(registry_root,path.stem)
    for channel in reg['channels']:
        name=reg['code']+'-'+channel
        planned=root/('channels/'+name+'.json')
        # A channel registered ahead of its first signed publication ("pending_channels")
        # has no file yet; it is tolerated only while neither copy exists.
        if channel in reg.get('pending_channels',[]) and not planned.exists() and not planned.is_symlink():
            if www and (www/'channels'/(name+'.json')).exists():
                raise SystemExit('channel source-of-truth drift')
            pending.append(name)
            continue
        source=repo_file(root,'channels/'+name+'.json')
        source_sig=Path(str(source)+'.minisig')
        unsigned=not source_sig.exists() and not source_sig.is_symlink()
        if unsigned:
            validate_empty_channel(read_json(source),reg,name)
        else:
            signature(source,public_keys)
            validate_channel(read_json(source),reg,name)
        if www:
            copy=repo_file(www,'channels/'+source.name)
            if source.read_bytes()!=copy.read_bytes():
                raise SystemExit('channel source-of-truth drift')
            if unsigned:
                copy_sig=Path(str(copy)+'.minisig')
                if copy_sig.exists() or copy_sig.is_symlink():
                    raise SystemExit('channel signature source-of-truth drift')
            elif source_sig.read_bytes()!=repo_file(www,'channels/'+source.name+'.minisig').read_bytes():
                raise SystemExit('channel signature source-of-truth drift')
        count+=1
if not count: raise SystemExit('no registered channels')
print(f'validated {count} registered channels'+(' (pending first publication: '+', '.join(pending)+')' if pending else ''))
PY
