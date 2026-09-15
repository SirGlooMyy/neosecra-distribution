# OFF migration metadata repair

2026-09-15: POC 0.3.75 runtime healthy, but final journal failed because Bash tab IFS collapsed empty checksum/schema fields. Preserve nullable fields with ASCII unit separator and reject separator/newline injection.

Files: deployment/v1/agent/hotspot-updater.sh; tests/test_hotspot_updater_recovery.py. Checks: actual metadata-to-journal regression and recovery suite 8 passed; bash -n and git diff --check passed. Existing unrelated dirty files preserved. Next: install verified updater and execute signed 0.3.76 unchanged application release; do not rewrite 0.3.75 failure evidence.

Live acceptance: updaterc4d4642 installed after exact base SHA verification and backup. Signed Hotspot0.3.75→0.3.76 completed at18:47:48Z, systemd exit0; journal COMPLETED100%, SKIPPED_NO_MIGRATION, checksum/schema null and numeric budgets0. Runtime source7f51027 healthy; independent GPT-5.6-sol patch review found no blocker. No .75 failure evidence rewritten.
