#!/usr/bin/env bash
set -euo pipefail
SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The first argument is an optional repository/fixture root.  Keeping the
# script-directory default preserves the operator-facing `./bin/...` command,
# while allowing isolated contract tests to validate temporary trees.
ROOT="${1:-${SCRIPT_ROOT}}"
WWW_ROOT="${2:-}"
PUBLIC_KEY="${NEOSECRA_CHANNEL_PUBLIC_KEY:-${ROOT}/public-keys/update-neosecra-com.pub}"
python3 - "$ROOT" "$WWW_ROOT" "$PUBLIC_KEY" <<'PY'
import json, pathlib, shutil, subprocess, sys
root = pathlib.Path(sys.argv[1]); channels = root / "channels"
www_root = pathlib.Path(sys.argv[2]) if sys.argv[2] else None
public_key = pathlib.Path(sys.argv[3])
expected = {"assessment-stable": "assessment", "soc-stable": "soc", "pish-stable": "pish", "hotspot-stable": "hotspot"}
aliases = {"neosecra-security-health": "assessment", "neosecra-soc": "soc", "neosecra-pish": "pish", "neosecra-hotspot": "hotspot"}
if shutil.which("minisign") is None:
    raise SystemExit("minisign is required to validate channel signatures")
if not public_key.is_file():
    raise SystemExit(f"missing channel public key: {public_key}")
for channel, product in expected.items():
    path = channels / f"{channel}.json"
    if not path.exists(): raise SystemExit(f"missing channel: {path}")
    signature = path.with_name(path.name + ".minisig")
    if not signature.exists(): raise SystemExit(f"missing channel signature: {signature}")
    verify = subprocess.run(["minisign", "-V", "-p", str(public_key), "-m", str(path), "-x", str(signature), "-q"], capture_output=True)
    if verify.returncode != 0: raise SystemExit(f"invalid channel signature: {path}")
    if www_root:
        www_path = www_root / "channels" / path.name
        www_sig = www_path.with_name(www_path.name + ".minisig")
        if not www_path.is_file() or not www_sig.is_file():
            raise SystemExit(f"missing generated WWW channel copy: {www_path}")
        if path.read_bytes() != www_path.read_bytes() or signature.read_bytes() != www_sig.read_bytes():
            raise SystemExit(f"channel source-of-truth drift: {path} != {www_path}")
    data = json.loads(path.read_text())
    if data.get("channel") != channel: raise SystemExit(f"channel name mismatch: {path}")
    actual = aliases.get(data.get("product"), data.get("product"))
    if actual != product: raise SystemExit(f"product mismatch: {channel}: {actual}")
    releases = data.get("releases") or []
    if data.get("status") == "available" and not releases:
        raise SystemExit(f"{channel} marked available without releases")
    for rel in releases:
        archive = rel.get("archive") or {}
        # Historical image-only entries remain readable for old agents. New
        # entries (the current release) must carry the signed archive contract.
        if not archive:
            continue
        if not rel.get("version") or len(archive.get("sha256", "")) != 64 or not archive.get("signature_url"):
            raise SystemExit(f"invalid release in {channel}: {rel.get('version')}")
print(f"validated {len(expected)} canonical channels")
PY
