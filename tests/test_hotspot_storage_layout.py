"""Exercise the signed bootstrap's storage admission with isolated host commands."""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[1]
BOOTSTRAP = ROOT / "update-server" / "bootstrap-hotspot.sh"
BASH = Path(r"C:\Program Files\Git\bin\bash.exe")


def _storage_block() -> str:
    source = BOOTSTRAP.read_text(encoding="utf-8")
    start = source.index("# Prefer an already-mounted data filesystem.")
    end = source.index("\nCURL_OPTS=", start)
    return source[start:end].replace(">> /etc/fstab", '>> "$TEST_FSTAB"')


@pytest.mark.parametrize(
    ("scenario", "expected_code", "expected_layout", "expected_formats"),
    [
        ("single", 0, "1", "0"),
        ("mounted", 0, "0", "0"),
        ("blank", 0, "0", "1"),
        ("ambiguous", 2, None, "0"),
        ("signed", 2, None, "0"),
        ("missing_mount", 2, None, "0"),
        ("small_root", 2, None, "0"),
    ],
)
def test_storage_layout_fails_closed(
    scenario: str, expected_code: int, expected_layout: str | None, expected_formats: str
) -> None:
    shell = r'''
set -Eeuo pipefail
DATA_ROOT="$(mktemp -d)"
TEST_FSTAB="$(mktemp)"
FORMAT_LOG="$(mktemp)"
SINGLE_DISK=0
TEST_MOUNTED=0
trap 'rmdir "$DATA_ROOT"; rm -f "$TEST_FSTAB" "$FORMAT_LOG"' EXIT
die() { printf 'DENIED:%s\n' "$1"; printf 'FORMATS:%s\n' "$(wc -l < "$FORMAT_LOG")"; exit "${2:-2}"; }
info() { :; }
install() { :; }
findmnt() {
  if [[ "$1" == --fstab ]]; then [[ "$SCENARIO" == missing_mount ]]; return; fi
  if [[ "$TEST_MOUNTED" == 1 || "$SCENARIO" == mounted ]]; then
    printf '%s\n' "$DATA_ROOT"
  else
    printf '/\n'
  fi
}
lsblk() {
  case "$*" in
    '-dn -b -o PATH,TYPE,SIZE')
      printf '/dev/os disk 1000000000000\n'
      if [[ "$SCENARIO" == blank || "$SCENARIO" == ambiguous || "$SCENARIO" == signed ]]; then
        printf '/dev/data disk 1000000000000\n'
      fi
      if [[ "$SCENARIO" == ambiguous ]]; then printf '/dev/data2 disk 1000000000000\n'; fi ;;
    '-nr -o TYPE /dev/os') printf 'disk\npart\n' ;;
    '-nr -o TYPE /dev/data'|'-nr -o TYPE /dev/data2') printf 'disk\n' ;;
    '-dn -o FSTYPE /dev/data'|'-dn -o FSTYPE /dev/data2') : ;;
    *) return 1 ;;
  esac
}
wipefs() { if [[ "$SCENARIO" == signed ]]; then printf 'ext4 signature\n'; fi; }
mkfs.ext4() { printf '%s\n' "$2" >> "$FORMAT_LOG"; }
mount() { TEST_MOUNTED=1; }
blkid() { printf 'test-uuid\n'; }
df() {
  if [[ "$*" == *'--output=size'* ]]; then
    if [[ "$SCENARIO" == small_root ]]; then printf 'Size\n100G\n'; else printf 'Size\n1000G\n'; fi
  else
    if [[ "$SCENARIO" == small_root ]]; then printf 'Avail\n90G\n'; else printf 'Avail\n900G\n'; fi
  fi
}
'''
    shell += _storage_block()
    shell += '\nprintf "LAYOUT:%s FORMATS:%s\\n" "$SINGLE_DISK" "$(wc -l < "$FORMAT_LOG")"\n'
    result = subprocess.run(
        [str(BASH), "-c", shell],
        env={**os.environ, "SCENARIO": scenario},
        text=True,
        capture_output=True,
        check=False,
    )
    assert result.returncode == expected_code, result.stderr + result.stdout
    assert f"FORMATS:{expected_formats}" in result.stdout
    if expected_layout is not None:
        assert f"LAYOUT:{expected_layout}" in result.stdout
