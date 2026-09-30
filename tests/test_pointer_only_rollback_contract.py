from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ROLLBACK = ROOT / "deployment" / "v1" / "upgrade" / "rollback.sh"
AGENT = ROOT / "deployment" / "v1" / "agent" / "update-agent.sh"


def test_canonical_rollback_keeps_pointer_only_contract():
    # Rollback policy is selected per manifest (pointer-only | backup-restore).
    # Behavior for both policies is covered in test_rollback_policy_behavior.py;
    # this only pins that the pointer-only contract markers stay in place.
    source = ROLLBACK.read_text(encoding="utf-8")

    assert "--pointer-only" in source
    assert "verify_pointer_only_metadata" in source
    assert "backup_required" in source
    assert "rollback_safe_without_db_restore" in source


def test_generic_agent_requests_pointer_only_rollback():
    source = AGENT.read_text(encoding="utf-8")
    assert '"--pointer-only"' in source
