# Gemini audit baseline (secrets-free)

- captured_at_utc: 2026-08-31T14:07:06Z
- repository: /home/sirgloomy/projects/neosecra-distribution
- branch: main (repository AGENTS.md describes fix/assessment-live-installer as its expected work branch; current checkout is main)
- head: e9f7df4e0b618d0602c77719828ec396aac92edf
- origin_main: e9f7df4e0b618d0602c77719828ec396aac92edf
- ahead_behind: 0 0
- worktree: dirty; 52 modified/deleted/untracked status entries captured below
- release/runtime references: deployment/VERSION 1.3.44; deployment/v1/VERSION 1.3.44; deployment/v1 manifest version 1.3.44
- migration inventory: no Alembic tree found in this repository; runtime migration is delegated to product repositories
- reviewed commit window: 08c4a19, b77644f, fc00d20, 5172329, f2cc096, 45c1303, 8a88b7d, e9f7df4 (2026-08-30)
- remote operation: fetched origin metadata only; no checkout/reset/clean

## Protected pre-existing worktree paths

All paths below existed dirty/untracked before this audit and are not to be overwritten or staged by default. Their contents will be inspected read-only and any necessary fix will be kept as a separate, explicit change.

```
M .ai-ops/current-checkpoint.md
M .ai-ops/fix-log.md
M channels/pish-stable.json
D deployment/lib/artifact-verifier.sh
D deployment/schemas/release-manifest.schema.json
M deployment/v1/agent/update-agent.sh
M deployment/v1/install/postflight.sh
M deployment/v1/lib/common.sh
M deployment/v1/release-manifest.yaml
M deployment/v1/upgrade/rollback.sh
M deployment/v1/upgrade/upgrade.sh
M deployment/v1/upgrade/verify_mapping.py
D schemas/release-manifest.schema.json
M tests/test_artifact_verifier.py
M tests/test_platform_release_contract.py
M update-server/publish.sh
?? .github/
?? COMMIT_PLAN.md
?? ci/
?? deployment/v1/install/airgap_installer.py
?? deployment/v1/upgrade/recovery.py
?? deployment/v1/upgrade/verify_platform_manifest.py
?? deployment/v1/upgrade/verify_rollback_auth.py
?? diff.patch
?? enforce.sh
?? patch_debug.py
?? patch_debug2.py
?? patch_docker.py
?? patch_mock.py
?? patch_postflight.py
?? patch_postflight_allowlist.py
?? patch_resolve.py
?? patch_tar.sh
?? patch_tar2.sh
?? patch_tar3.sh
?? patch_test.sh
?? patch_test2.sh
?? patch_test3.sh
?? patch_test4.sh
?? patch_test5.sh
?? patch_test6.sh
?? patch_test7.sh
?? patch_verify_mapping.py
?? test_verify.sh
?? tests/fixtures/
?? tests/test_airgap_package.py
?? tests/test_compatibility_matrix.py
?? tests/test_e2e_promotion.sh
?? tests/test_pish_operator.py
?? tests/test_recovery_003.py
?? tests/test_trust_002.py
?? verify_debug.py
```
