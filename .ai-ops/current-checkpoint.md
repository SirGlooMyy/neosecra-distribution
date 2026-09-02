# neosecra-distribution — Operational Checkpoint

- **Updated:** 2026-09-02
- **Repository:** `/home/sirgloomy/projects/neosecra-distribution`
- **Branch:** `main`
- **Verified code commit:** `4adedccf7a46661ccb9b7bfda1702122ddcc73b6` (`origin/main`; checkpoint docs follow)
- **Canonical Governance:** `/home/sirgloomy/AGENTS.md`
- **Project Memory:** `.ai-ops/project-memory/DISTRIBUTION-CANONICAL-MODEL.md`

---

## 1. Durum Etiketleri (Status)
- **IMPLEMENTED-CONTRACT:** P0 Trust-002, Recovery-003, CI-Gate-004, Package-005, DIST-PISH-PACKAGE-007 (Phish Online/Offline Operator)
- **TESTED:** `pytest -q` 58 passed; release/recovery/trust/promotion focus 31 passed; `tests/test_e2e_promotion.sh` real offline missing-minisig negative path passed; Origin TLS static test 12 passed/0 failed/3 skipped; release dry-run exited 0; `bash -n` clean across all scripts.
- **NOT_RUN:** CI push, live deploy to `.13`, real signed production artifact generation, and Origin TLS direct-SNI/public smoke (authorized origin remains unreachable). No mock/forge material created.
- **LAB UPDATE/ROLLBACK:** `VERIFIED_FAIL_CLOSED` (Anti-rollback, monotonic version, strict Ed25519 payload enforcing for phishing.core entitlement, atomic rollback on failure).
- **PRODUCTION RELEASE:** `BLOCKED` until CI has `cosign`/`minisign`/Docker and a real signed artifact promotion is executed.

---

## 2. P0 — Yayına Çıkmadan Önce
- [x] Manifestin kendisinin imzalanması ve anti-rollback (monotonic state `.release_state.json`) kontrolü (TRUST-002).
- [x] Gerçek compose profillerindeki bütün servislerin manifestle birebir eşleşmesinin kanıtlanması (TRUST-001/002).
- [x] Production Cosign trust root/public key kurulumu ve rotation prosedürü (Directory/keychain support).
- [x] Rollback sırasında `.env.v1`, symlink, image ve DB sürümünün birlikte eski hâline dönmesi (TRUST-002, Signed Rollback Auth).
- [x] Aynı anda iki updater çalışmasını engelleyen lock ve heartbeat (RECOVERY-003).
- [x] Update sırasında elektrik/process kesilmesi recovery testi ve crash-safe journal (RECOVERY-003).
- [x] Disk dolması, partial registry failure handled (RECOVERY-003, Exit 4 fail-closed).
- [x] Customer package (Air-Gap) kurulum testi, tenant binding, fail-closed entegrasyon (PACKAGE-005).
- [x] Phish-specific operator flow, license entitlement checks, exact composition verification, health verification patching.
- [ ] SOC, Phish, Assessment, vb. için gerçek CI pipeline'larında release manifest üretilmesi (NOT_RUN).
- [ ] CI pipeline push ve entegrasyon tatbikatı (NOT_RUN).

## 3. P1 — Operasyonel Kapanış
- [x] Tek komutla çalışan CI prerelease gate (CI-GATE-004).
- [ ] Migration öncesi backup ve gerçek restore.
- [ ] Assessment/Hotspot legacy allow-list’in sahibi, sona erme tarihi ve tamamen kaldırılacağı sürümün belirlenmesi.
- [ ] License servisinin gerçek paketleme/update/rollback akışı (Manifest kuralı hazır, entegrasyon bekliyor).
- [ ] Update audit kayıtları GUI entegrasyonu (Heartbeat ve EXEC_ID oluşturuldu, UI'a yansıtılması gerekiyor).

## 4. P2 — Hardening
- [ ] Tam SPDX/CycloneDX validation ve vulnerability/license policy (şu an sadece yapısal checksum/signature düzeyde).
- [ ] Keyless/Rekor politikası.
- [ ] Canary/percentage rollout.
- [ ] Çoklu mimari image doğrulaması.
- [ ] Release promotion dashboard’u.

---

## DIST-LIVE-CLOUDFLARE-TLS-012 (2026-09-01 retry)
- Authorized origin `10.33.99.13`: TCP 22/80/443/7443/9445/9446/9447 unreachable; no SSH authentication or live mutation occurred.
- Public Cloudflare baseline: `license.neosecra.com`, `update.neosecra.com`, and `registry.neosecra.com` each returned strict TLS `526`.
- Local candidate: Cloudflare Origin wildcard SAN `*.neosecra.com`, issuer Cloudflare Origin SSL CA, valid 2026-08-29 through 2041-08-25; public-key/key match PASS; Caddy/Compose validation PASS.
- Scoped runbook/test/evidence added: `docs/CLOUDFLARE-ORIGIN-TLS-012.md`, `update-server/src/cloudflare-origin-test-012.sh`, `.ai-ops/evidence/DIST-LIVE-CLOUDFLARE-TLS-012.md`.
- Status: `BLOCKED`; direct `.33` SNI, pre-change live backup, proxy reload, and two-round public smokes are `NOT_RUN`; `LIVE_VERIFIED` is prohibited until all gates pass.

## DIST-LIVE-CLOUDFLARE-TLS-012 current attempt (2026-09-02)
- Exact authorized SSH target `neosecra@10.33.99.13` was attempted once with a 15-second connection timeout and timed out before authentication (`rc=255`). No secret was entered or stored, no alternate host was used, and no further discovery/retry was performed.
- Live config/cert inspection, metadata backup, Caddy validation/reload, rollback, direct SNI, and two-round public smoke remain `NOT_RUN`; public strict-TLS baseline remains `526` for all three names. `LIVE_VERIFIED` is prohibited.
- Distribution task verdict: `BLOCKED` on the single verified reachability blocker. Next authorized workstream: `/home/sirgloomy/projects/neosecra-lisans` existing License entitlement implementation.

## DIST-GEMINI-AUDIT-011 completion checkpoint (2026-09-02)
- Upgrade path now keeps canonical script/recovery roots stable across target-context switches; EXIT recovery trap is valid at top level and signed rollback invokes the original verifier.
- Explicit targets pass anti-rollback; dry-run performs signed metadata/channel and read-only preflight only, with no lock, backup, release install, env/state write, image pull, or promotion.
- Origin certificate is tracked as `update-server/certs/neosecra-origin.crt`; Caddy and the static test use the matching operator-supplied `neosecra-origin.key` name (private key remains untracked).
- Full local verification: pytest 58 passed; focused promotion/recovery/trust tests 31 passed; real negative E2E passed; TLS static 12 passed/0 failed/3 skipped; release dry-run `rc=0`; all shell syntax checks passed. `ci/prerelease-gate.sh` correctly failed closed because local `cosign` is unavailable; `shellcheck` is unavailable. Live `.13` status remains `BLOCKED/NOT_RUN` and was not retried.
- Scoped commit/push: `4adedccf7a46661ccb9b7bfda1702122ddcc73b6` is published on `origin/main`; unrelated scratch/debug/backup files remain untracked and untouched.
