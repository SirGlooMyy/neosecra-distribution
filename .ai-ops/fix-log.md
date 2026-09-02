# neosecra-distribution — Fix Log

- **2026-08-30 (DIST-FOUNDATION-001 / 002):**
  - **P0 Fix:** `artifact-verifier.sh` fail-open vulnerabilities closed.
  - **SBOM Fix:** SPDX/CycloneDX strict validation integrated.
  - **Runtime Enforcement:** `upgrade.sh` tied directly to fail-closed checks before pull and post-load.
  - **Schema & Pinned Digests:** `.env.v1` atomic updates to pin immutable SHA-256 digests. Multi-image 1:1 service manifest mapping enforced.

- **2026-08-30 (DIST-TRUST-002):**
  - **Platform Manifest Signature:** Created `verify_platform_manifest.py` to enforce strictly signed JSON manifests.
  - **Anti-Rollback (Monotonic State):** Implemented `.release_state.json` tracker, preventing replay of old manifests.
  - **Signed Rollback Auth:** Modified `rollback.sh` to require an explicit `--auth` payload (`verify_rollback_auth.py`) mapped to exact target version and expiration timestamp.
  - **Legacy Allowlist Expiry:** Tested and enforced expiry logic on legacy hotspot/assessment packages.

- **2026-08-31 (DIST-RECOVERY-003):**
  - **Single-Instance Lock:** Python-backed `lock_acquire`/`lock_release` overriding basic `mkdir` locks in `common.sh`.
  - **Stale Takeover & Heartbeat:** Background heartbeat loop appended to upgrade process. If crashed, new instances takeover stale locks (>60s).
  - **Crash-Safe Journal:** Operations (`PULL_LOAD`, `MIGRATE`, `PROMOTE`) logged chronologically to `.update.journal`.
  - **Deterministic Resume:** `check_resume_policy` prevents resuming if process crashed during critical schema migrations or symlink promotion (Requires signed rollback).
  - **Disk Space Preflight:** `check_disk_space` added natively into `upgrade.sh`.

- **2026-08-31 (DIST-CI-GATE-004):**
  - **Prerelease Gate:** Created `ci/prerelease-gate.sh` forcing missing tools (`cosign`, `minisign`, `pytest`) to Exit 1.
  - **Stable Promotion Hook:** Injected into `publish.sh`; blocks stable releases if gate fails.
  - **Compatibility Tests:** Filled test matrix gap for `compatibility` schema validation.
  - **Deterministic Fixtures:** Added explicit `tests/fixtures/` and integrated them natively into pytest scripts.

- **2026-08-31 (DIST-PACKAGE-005 / AUDIT):**
  - **Air-Gap Packager:** Developed `airgap_installer.py` for selectable multi-product customer plans.
  - **Cryptographic Entitlement:** Replaced plain payload decode with strict `nacl.signing.VerifyKey` Ed25519 signature enforcement.
  - **Tenant Binding & Path Traversal:** Added explicit `--tenant` mismatch blocks and `sanitize_product_name()` regex guards.
  - **Bash Integrity Hash:** Injected explicit `sha256sum` loops in the generated `airgap_plan.sh` script to catch tampering before `docker load`.

- **2026-08-31 (DIST-CONSOLIDATE-006):**
  - **Cleanup:** `__pycache__`, scratch files (`patch_*.py`), and duplicate schemas removed.
  - **Canonical Pathing:** Duplicate `deployment/lib/artifact-verifier.sh` removed; tests synced precisely to use `deployment/v1/agent/artifact-verifier.sh`.
  - **State Segregation:** Marked real infrastructure deployments as `NOT_RUN` and strictly local offline contracts as `IMPLEMENTED-CONTRACT`.

- **2026-08-31 (DIST-PISH-PACKAGE-007-AUDIT):**
  - **Pish-Stable Parity:** Verified 1:1 service compose parity in `verify_mapping.py` with zero legacy bypass for `pish-stable`.
  - **Fail-Closed Security:** Pinned digest checking, Cosign signature/attestation enforcement, and anti-rollback verification before start.
  - **Rollback Atomicity & E2E Negative Promotion:** Validated migration abort exit code 13, crash-safe journal logging, and verified negative promotion via `tests/test_e2e_promotion.sh`.

- **2026-09-02 (DIST-GEMINI-AUDIT-011):**
  - **Fail-closed upgrade context:** Stabilized the canonical upgrade/recovery root across release switches, fixed the EXIT trap, anchored PROMOTE journals and signed rollback, and enforced anti-rollback for explicit targets.
  - **Read-only dry-run:** Signed channel metadata and host preflight are checked without lock, backup, release installation, environment/state mutation, image pull, or active promotion; legacy state self-heal is disabled for this mode.
  - **Origin TLS naming:** Renamed the public Cloudflare Origin candidate to `neosecra-origin.crt` and aligned Caddy, static validation, runbook, and evidence; the private key remains outside Git.
  - **Verification:** pytest 58 passed; real offline missing-minisig E2E passed; Origin TLS static 12 passed/0 failed/3 skipped; `bash -n` passed; shellcheck unavailable; live `10.33.99.13` gates remain blocked/not run.
  - **Release orchestrator closure:** `cleanup()` now returns success so a successful dry-run exits `0`; immutable digest promotion remains the only stable path and refuses missing CI digests, missing cosign/SPDX verification, or mutable target replacement.
  - **Final local verification:** focused promotion/recovery/trust tests 31 passed; full pytest 58 passed; release dry-run `rc=0`; all shell syntax checks passed; prerelease gate failed closed on unavailable local `cosign`; live `.13` was not retried.
