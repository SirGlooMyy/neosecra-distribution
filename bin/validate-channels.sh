#!/usr/bin/env bash
set -euo pipefail
SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The first argument is an optional repository/fixture root.  Keeping the
# script-directory default preserves the operator-facing `./bin/...` command,
# while allowing isolated contract tests to validate temporary trees.
ROOT="${1:-${SCRIPT_ROOT}}"
WWW_ROOT="${2:-}"
if [[ -n "${NEOSECRA_CHANNEL_PUBLIC_KEY:-}" ]]; then
    PUBLIC_KEY="${NEOSECRA_CHANNEL_PUBLIC_KEY}"
elif [[ -f "${ROOT}/public-keys/update-neosecra-com.pub" ]]; then
    PUBLIC_KEY="${ROOT}/public-keys/update-neosecra-com.pub"
else
    # ROOT may point at a fixture's channels directory.  The validator itself
    # still owns the repository's pinned verification key in that case.
    PUBLIC_KEY="${SCRIPT_ROOT}/public-keys/update-neosecra-com.pub"
fi
python3 - "$ROOT" "$WWW_ROOT" "$PUBLIC_KEY" <<'PY'
import json, pathlib, re, shutil, subprocess, sys
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
    if data.get("product_code", product) != product:
        raise SystemExit(f"product_code mismatch: {channel}: {data.get('product_code')}")
    if data.get("edition") not in {"standard", "enterprise"}:
        raise SystemExit(f"invalid channel edition: {channel}: {data.get('edition')}")
    releases = data.get("releases") or []
    if data.get("status") == "available" and (not releases or not data.get("current_version")):
        raise SystemExit(f"{channel} marked available without a current release")
    versions = set()
    for rel in releases:
        version = str(rel.get("version") or "")
        if not re.fullmatch(r"\d+\.\d+\.\d+", version):
            raise SystemExit(f"invalid release version in {channel}: {version!r}")
        if version in versions:
            raise SystemExit(f"duplicate release version in {channel}: {version}")
        versions.add(version)
        archive = rel.get("archive") or {}
        # Historical image-only entries remain readable for old agents. New
        # entries (the current release) must carry the signed archive contract.
        if not archive:
            continue
        if not rel.get("version") or len(archive.get("sha256", "")) != 64 or not archive.get("signature_url"):
            raise SystemExit(f"invalid release in {channel}: {rel.get('version')}")
    current = data.get("current_version")
    if current is not None:
        if not re.fullmatch(r"\d+\.\d+\.\d+", str(current)) or str(current) not in versions:
            raise SystemExit(f"current_version is not present in {channel} releases: {current!r}")
        current_release = next(r for r in releases if r.get("version") == current)
        archive = current_release.get("archive") or {}
        if len(str(archive.get("sha256", ""))) != 64 or not archive.get("signature_url"):
            raise SystemExit(f"current release is not artifact-backed: {channel} {current}")
print(f"validated {len(expected)} canonical channels")
PY
