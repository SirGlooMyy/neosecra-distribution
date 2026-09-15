# OFF migration metadata repair

2026-09-15: POC 0.3.75 runtime healthy, but final journal failed because Bash tab IFS collapsed empty checksum/schema fields. Preserve nullable fields with ASCII unit separator and reject separator/newline injection.

Files: deployment/v1/agent/hotspot-updater.sh; tests/test_hotspot_updater_recovery.py. Checks: actual metadata-to-journal regression and recovery suite 8 passed; bash -n and git diff --check passed. Existing unrelated dirty files preserved. Next: install verified updater and execute signed 0.3.76 unchanged application release; do not rewrite 0.3.75 failure evidence.
