import os
import subprocess
import pytest
import shutil
import json
import datetime

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
UPGRADE_SH = os.path.join(REPO_ROOT, "deployment", "v1", "upgrade", "upgrade.sh")

@pytest.fixture
def base_env(tmp_path):
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    pubkey = tmp_path / "cosign.pub"
    pubkey.write_text("fake-key")

    env_file = tmp_path / ".env.v1"
    env_file.write_text("BACKEND_IMAGE=old\nFRONTEND_IMAGE=old\n")

    legacy_list = tmp_path / "legacy_allowlist.json"
    legacy_list.write_text(json.dumps({
        "assessment-stable": {
            "product": "assessment",
            "releases": {
                "1.0.0": {
                    "archive_sha256": "473a0f4c3be8a93681a267e3b1e9a7dcda1151010ac40cccabe1aa561f0acef5",
                    "expires_at": "2099-01-01T00:00:00Z"
                },
                "2.0.0": {
                    "product": "assessment",
                    "archive_sha256": "473a0f4c3be8a93681a267e3b1e9a7dcda1151010ac40cccabe1aa561f0acef5",
                    "expires_at": "2020-01-01T00:00:00Z"
                }
            }
        }
    }))

    def run_script(docker_mock_content, cosign_mock_content, channel_json, extra_env=None):
        docker_mock = bin_dir / "docker"
        docker_mock.write_text(docker_mock_content)
        docker_mock.chmod(0o755)

        cosign_mock = bin_dir / "cosign"
        if cosign_mock_content:
            cosign_mock.write_text(cosign_mock_content)
            cosign_mock.chmod(0o755)
        elif cosign_mock.exists():
            cosign_mock.unlink()

        test_script = tmp_path / "test.sh"
        test_script.write_text(f"""#!/bin/bash
export PATH="{bin_dir}:$PATH"
export NEOSECRA_COSIGN_PUBKEY="{pubkey}"
export V1_ROOT="{REPO_ROOT}/deployment/v1"
export CHANNEL_JSON='{json.dumps(channel_json)}'
export TARGET="1.0.0"
if [[ -n "$BASH_X" ]]; then set -x; fi
export ENV_FILE="{env_file}"
export EXPECTED_SHA256="473a0f4c3be8a93681a267e3b1e9a7dcda1151010ac40cccabe1aa561f0acef5"

sed -n '/upsert_env_value_atomic() {{/,/^}}/p' "{UPGRADE_SH}" > enforce.sh
sed -n '/enforce_image_security() {{/,/^}}/p' "{UPGRADE_SH}" >> enforce.sh
source enforce.sh

warn() {{ echo "WARN: $*"; }}
log() {{ echo "LOG: $*"; }}
ok() {{ echo "OK: $*"; }}
die() {{ echo "DIE: $*"; exit $2; }}
run_compose() {{ docker compose "$@"; }}

enforce_image_security
""")
        test_script.chmod(0o755)

        env = os.environ.copy()
        if extra_env:
            env.update(extra_env)
        
        return subprocess.run(["bash", str(test_script)], capture_output=True, text=True, env=env)

    return run_script, env_file

def get_standard_channel(digest):
    return {
        "channel": "soc-stable",
        "product": "soc",
        "releases": [{"version": "1.0.0", "images": {"backend": {"reference": "reg/backend", "digest": digest}}}]
    }

def get_standard_docker_mock(digest):
    return f"""#!/bin/bash
if [[ "$1" == "compose" && "$2" == "config" ]]; then
  echo '{{"services": {{"backend": {{"image": "reg/backend"}}}}}}'
  exit 0
fi
if [[ "$1" == "inspect" ]]; then
  echo "{digest}"
  exit 0
fi
exit 0
"""

def test_compose_config_failure(base_env):
    run_script, _ = base_env
    docker_mock = """#!/bin/bash
if [[ "$1" == "compose" && "$2" == "config" ]]; then exit 1; fi
"""
    res = run_script(docker_mock, "#!/bin/bash\nexit 0", get_standard_channel("sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"))
    assert res.returncode == 4
    assert "Compose config failure" in res.stdout

def test_service_enumeration_failure(base_env):
    run_script, _ = base_env
    docker_mock = """#!/bin/bash
if [[ "$1" == "compose" && "$2" == "config" ]]; then echo ""; exit 0; fi
"""
    res = run_script(docker_mock, "#!/bin/bash\nexit 0", get_standard_channel("sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"))
    assert res.returncode == 4
    assert "Service enumeration failure" in res.stdout

def test_manifest_missing_image(base_env):
    run_script, _ = base_env
    channel = get_standard_channel("sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
    channel["releases"][0]["images"] = {} # missing backend
    res = run_script(get_standard_docker_mock("sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"), "#!/bin/bash\nexit 0", channel)
    assert res.returncode == 4
    assert "Image mapping failure" in res.stdout

def test_duplicate_digest(base_env):
    run_script, _ = base_env
    channel = {
        "channel": "soc-stable", "product": "soc",
        "releases": [{"version": "1.0.0", "images": {
            "backend": {"reference": "reg/backend", "digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
            "frontend": {"reference": "reg/frontend", "digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
        }}]
    }
    docker_mock = """#!/bin/bash
if [[ "$1" == "compose" && "$2" == "config" ]]; then
  echo '{"services": {"backend": {"image": "reg/backend"}, "frontend": {"image": "reg/frontend"}}}'
  exit 0
fi
echo "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
exit 0
"""
    res = run_script(docker_mock, "#!/bin/bash\nexit 0", channel)
    assert res.returncode == 4

def test_compose_reference_mismatch(base_env):
    run_script, _ = base_env
    channel = get_standard_channel("sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
    docker_mock = """#!/bin/bash
if [[ "$1" == "compose" && "$2" == "config" ]]; then
  echo '{"services": {"backend": {"image": "wrong/backend"}}}'
  exit 0
fi
"""
    res = run_script(docker_mock, "#!/bin/bash\nexit 0", channel)
    assert res.returncode == 4

def test_local_repodigest_mismatch(base_env):
    run_script, _ = base_env
    res = run_script(get_standard_docker_mock("sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"), "#!/bin/bash\nexit 0", get_standard_channel("sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"))
    assert res.returncode == 4
    assert "Enforcement checks failed" in res.stdout

def test_unpinned_third_party(base_env):
    run_script, _ = base_env
    channel = get_standard_channel("sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
    docker_mock = """#!/bin/bash
if [[ "$1" == "compose" && "$2" == "config" ]]; then
  echo '{"services": {"backend": {"image": "reg/backend"}, "redis": {"image": "redis:latest"}}}'
  exit 0
fi
echo "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
"""
    res = run_script(docker_mock, "#!/bin/bash\nexit 0", channel)
    assert res.returncode == 4 # redis not in manifest dependencies

def test_legacy_channel_release_not_in_allowlist(base_env):
    run_script, _ = base_env
    channel = {"channel": "assessment-stable", "product": "assessment", "releases": [{"version": "9.9.9"}]}
    res = run_script(get_standard_docker_mock("sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"), "#!/bin/bash\nexit 0", channel)
    assert res.returncode == 4

def test_legacy_allowlist_expired(base_env):
    run_script, _ = base_env
    channel = {"channel": "assessment-stable", "product": "assessment", "releases": [{"version": "2.0.0"}]}
    res = run_script(get_standard_docker_mock("sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"), "#!/bin/bash\nexit 0", channel)
    assert res.returncode == 4

def test_minisign_archive_digest_missing(base_env):
    run_script, _ = base_env
    channel = {"channel": "assessment-stable", "product": "assessment", "releases": [{"version": "1.0.0"}]}
    res = run_script(get_standard_docker_mock("sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"), "#!/bin/bash\nexit 0", channel, {"EXPECTED_SHA256": "wrong"})
    assert res.returncode == 4

def test_atomic_env_update(base_env):
    run_script, env_file = base_env
    # We simulate a success mapping, but signature fails. Env should remain unchanged.
    channel = {
        "channel": "soc-stable", "product": "soc",
        "releases": [{"version": "1.0.0", "images": {
            "backend": {"reference": "reg/backend", "digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
        }}]
    }
    docker_mock = get_standard_docker_mock("sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
    cosign_mock = """#!/bin/bash\nexit 1""" # fails signature
    res = run_script(docker_mock, cosign_mock, channel, {"BASH_X": "1"})
    assert res.returncode == 4
    assert env_file.read_text() == "BACKEND_IMAGE=old\nFRONTEND_IMAGE=old\n"

def test_success_three_images(base_env):
    run_script, env_file = base_env
    channel = {
        "channel": "soc-stable", "product": "soc",
        "releases": [{"version": "1.0.0", 
            "images": {
                "backend": {"reference": "reg/backend", "digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
                "frontend": {"reference": "reg/frontend", "digest": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}
            },
            "dependencies": {
                "redis": {"reference": "redis", "digest": "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"}
            }
        }]
    }
    docker_mock = """#!/bin/bash
if [[ "$1" == "compose" && "$2" == "config" ]]; then
  echo '{"services": {"backend": {"image": "reg/backend"}, "frontend": {"image": "reg/frontend"}, "redis": {"image": "redis"}}}'
  exit 0
fi
if [[ "$1" == "inspect" ]]; then
  if [[ "$4" == *"backend"* ]]; then echo "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"; fi
  if [[ "$4" == *"frontend"* ]]; then echo "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"; fi
  if [[ "$4" == *"redis"* ]]; then echo "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"; fi
  exit 0
fi
exit 0
"""
    cosign_mock = """#!/bin/bash\nexit 0"""
    res = run_script(docker_mock, cosign_mock, channel, {"BASH_X": "1"})
    assert res.returncode == 0
    assert "All images enforced and pinned" in res.stdout
    content = env_file.read_text()
    assert "BACKEND_IMAGE=reg/backend@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" in content
    assert "FRONTEND_IMAGE=reg/frontend@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" in content
    assert "REDIS_IMAGE=redis@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc" in content

