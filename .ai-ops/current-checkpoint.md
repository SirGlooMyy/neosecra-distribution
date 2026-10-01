## 2026-10-01 — Ortak update + lisans altyapısı (GÜNCEL DURUM — aşağıdaki eski bölümler tarihseldir)

- Kaynak HEAD `5acd955` (origin/main ile eşit). Ayrıntı ve kanıtlar: `.ai-ops/fix-log.md` en üst kayıt. Plan ve kararlar: `E:\projects\.ai-ops\UPDATE-LICENSE-UNIFICATION-PLAN.md`. Ürün iş emirleri: `E:\projects\shared-guides\integration\`.
- Canlı: distribution damgası 6225c5a (Caddy yeniden başlatıldı, HSTS, registry yazma 403). 6225c5a sonrası commit'lerin dağıtımı kullanıcıda açık.
- Canlı dağıtım yalnız `neosecra-distribution/scripts/deploy-live.sh` ile, commit'lenmiş ve push edilmiş SHA'dan yapılır; bkz. `neosecra-distribution/docs/LIVE-DEPLOY.md`. Canlıda elle dosya düzenlenmez.

## 2026-09-15 Hotspot OFF metadata fix

- Sourcec4d4642 pushed; recovery8 tests/bash-n/diff-check PASS; independent review clear. Verified updater installed with backup, signed POC0.3.76 exit0 and terminal journal OFF/null/zero PASS. Evidence work/no-migration-metadata-20260915.md. Existing unrelated dirty work preserved; this mixed log remains outside scoped commit.

# neosecra-distribution — Operational Checkpoint

## 2026-09-05 — Central update/signing host consolidation
- `100.117.210.76` is the canonical Update/License/Web host; Caddy, registry,
  License containers, release tree and signing workspace are present.
- `/home/neosecra/.local/bin/minisign` **0.12** and the existing signer key
  remain user-owned (`600`); no new key was generated or exposed.
- Signed Hotspot `0.3.30` channel/archive/bootstrap verify successfully;
  public `https://update.neosecra.com` serves `0.3.30` and 16 releases.
- Fixed publisher Minisign discovery for user-local installs and atomically
  reconciled source/WWW `hotspot-stable` metadata after a dated backup.
- Checks: remote `bash -n`, default-PATH publisher dry-run, channel/archive
  Minisign verification and public HTTPS read-back **passed**. Commit/push **not run**.
- Hotspot 5651 data/volumes were not touched; the main-screen historical-log
  visibility issue is a separate UI filter concern and remains open.

## 2026-09-04 — Hotspot live agent reinstall and port map
- **2026-09-05 — Hotspot installer contract smoke**
  - Bootstrap heredoc Python blokları `python3 -` biçimine düzeltildi; zorunlu
    `CLICKHOUSE_PASSWORD` ilk kurulumda üretilip reinstall'da korunuyor.
  - `tests/test_hotspot_release_contract.py`: **3 geçti**; Git Bash ile
    bootstrap/install-agent/updater `bash -n`: **başarılı**.
  - Canlı deploy/kanal/signature değişmedi; müşteri SSH preflight bekliyor.

- Keyring-aware Hotspot installer was updated to provision state-local
  `HOME`, `XDG_CONFIG_HOME`, `DOCKER_CONFIG` and `BUILDX_CONFIG` paths so
  Docker Compose builds work under `ProtectHome=true`/`ProtectSystem=full`.
  Remote `bash -n` passed and the installer was re-run on `100.95.2.21`.
- Signed Hotspot `0.3.26` retry completed after the first sandbox failure;
  current/installed/active state is `0.3.26`, health is HTTP 200 with
  DB/Redis/Celery `ok`, and persistent services remained in place. The updater
  now writes both `installed-version` and legacy `active-release` atomically.
- Current reverse-proxy origin map: `assessment.neosecra.com -> 9443`,
  `license.neosecra.com -> 9446`, `update.neosecra.com -> 9445`,
  `registry.neosecra.com -> 9447`, `pish.neosecra.com -> 8443`,
  `soc.neosecra.com -> 9442`, `neosecra.com -> 7443`; `www.update` duplicates
  update and `www.neosecra` duplicates www. Public update access is standard
  HTTPS 443; direct public `:9445` is origin-only and timed out.
- Commit/push: **NOT_RUN**. Next: preserve this installer behavior in the
  next signed Distribution artifact and use the 443 URL in customer bootstrap.

## 2026-09-04 — Signing workstation setup
- Installed official `jedisct1.minisign` `0.12` on the current Windows
  development PC; pinned public key ID `C55D6825451AD013` successfully verified
  the checked-in Hotspot channel signature.
- Existing production Minisign private key is still unavailable. No new key,
  channel, artifact, update host or runtime mutation was created; `0.3.26`
  promotion remains `BLOCKED/NOT_RUN`.
- Next: provision the existing signing key through the approved secret path,
  then run the Hotspot prerelease/publish/agent/health gate.

## 2026-09-04 — Hotspot 0.3.26 promotion preflight
- Candidate archive is present with SHA-256
  `3e4d34ff7978dfee408ffa4c8f183da1b436324e826b345a3cb6dd82acb99ea5`;
  public/remote `hotspot-stable` read-back is signed `0.3.25`.
- Read-only SSH confirmed update host `100.117.210.76` has no `minisign` binary
  or approved signing key; Hotspot `100.95.2.21` active pointer remains
  `/opt/neosecra/hotspot/releases/0.3.25`.
- Promotion/deploy **BLOCKED/NOT_RUN**. No channel, runtime, volume or data
  mutation was performed. Next: provision the existing signing key, then run
  prerelease → sign → publish → agent trigger → health/pointer/journal smoke.

## 2026-09-04 — Unified update operations plan
- Master plan added at `docs/UNIFIED-UPDATE-OPERATIONS-PLAN.md`; it defines the
  Distribution-owned install/update/rollback/signing/test/live-pilot contract
  for Assessment, SOC, PISH, Hotspot, License and Distribution.
- Document records current evidence separately from target state, including
  public/remote Hotspot `0.3.25`, unsigned `0.3.26` candidate, SOC attestation
  blocker, PISH unavailable channel and Assessment channel/runtime drift.
- Source HEAD: `c29fae4`; documentation-only verification passed with
  `git diff --check` and nine local Markdown reference checks. No channel,
  artifact, signature or live runtime changed; commit/push/deploy **NOT_RUN**.
- Next action: provision the existing Minisign signing key through the approved
  secret process, then execute the release gate before any promotion.

## 2026-09-04 — Hotspot version metadata forward-fix
- Bootstrap now writes legacy `VERSION` alongside canonical `PRODUCT_VERSION` so retained installations cannot advertise stale health metadata.
- Remote `100.117.210.76` bootstrap was updated with a dedicated backup; remote `bash -n` and SHA read-back passed. No channel or signature was changed.
- Candidate `0.3.26` archive SHA-256 is `3e4d34ff7978dfee408ffa4c8f183da1b436324e826b345a3cb6dd82acb99ea5`; Hotspot gate **PASS**, contract test **3 passed**. Signing private key remains unavailable; publish/deploy **NOT_RUN**.

## 2026-09-04 — Hotspot update contract hardening
- Bootstrap now performs bounded single-root/version-bound extraction, preserves existing reinstall secrets and refuses unverified Docker installer piping.
- Hotspot updater rejects downgrades and persists a transaction marker with startup reconciliation for crash recovery. Publisher rejects non-monotonic targets and immutable-version hash replacement.
- Remote update host `100.117.210.76` received patched publisher/bootstrap/updater/extractor sources after `.live-backup-20260904T-livefix`; source channel was reconciled to the signed WWW channel (`hotspot-stable` `0.3.25`).
- Verification: Hotspot gate **PASS**, Distribution Hotspot contract **3 passed**, Bash syntax/hash checks **PASS**, monotonic publish negative **PASS**. Broader agent contract **12 passed / 1 failed** on the pre-existing invalid SOC channel signature. Real Minisign signing key is absent; 0.3.26 remains unsigned and unpublished.

## 2026-09-03 — SOC immutable channel publisher

- SOC publisher now requires a Docker bundle and an exact nine-service
  `name=reference@sha256:<64 lowercase hex>` lock, rejecting mutable, missing,
  unknown, duplicate, or unsafe entries before staging/signing.
- Upgrade mapping permits only the intentional shared backend/worker/beat
  digest; all other duplicate application digests remain fail-closed.
- Verification: full `pytest -q` `61 passed`; SOC publish/promotion/recovery/
  trust/platform focus `34 passed`; shell syntax and diff/secret checks passed.
- Scoped commit `6d15a5ec51f3daf045b89df112fce24003cb1df6` is pushed to
  `origin/main`. Existing Hotspot channel and scratch/debug/backup files remain
  dirty and untouched.
- `.13` live publish/deploy is `NOT_RUN/BLOCKED`: `soc-stable` is reserved with
  no release, and no real signing key, image bundle, or attested SOC artifact
  was created. Evidence is in
  `.ai-ops/evidence/soc-publish-contract-20260903.json`.

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

## Sequential rollup (2026-09-03)
- Reused the 2026-09-02 exact `.13` timeout evidence; no SSH/discovery retry was performed.
- Cloudflare TLS live mutation and two-round smoke remain `NOT_RUN`; verdict stays `BLOCKED` until authorized reachability returns.

## DIST-GEMINI-AUDIT-011 completion checkpoint (2026-09-02)
- Upgrade path now keeps canonical script/recovery roots stable across target-context switches; EXIT recovery trap is valid at top level and signed rollback invokes the original verifier.
- Explicit targets pass anti-rollback; dry-run performs signed metadata/channel and read-only preflight only, with no lock, backup, release install, env/state write, image pull, or promotion.
- Origin certificate is tracked as `update-server/certs/neosecra-origin.crt`; Caddy and the static test use the matching operator-supplied `neosecra-origin.key` name (private key remains untracked).
- Full local verification: pytest 58 passed; focused promotion/recovery/trust tests 31 passed; real negative E2E passed; TLS static 12 passed/0 failed/3 skipped; release dry-run `rc=0`; all shell syntax checks passed. `ci/prerelease-gate.sh` correctly failed closed because local `cosign` is unavailable; `shellcheck` is unavailable. Live `.13` status remains `BLOCKED/NOT_RUN` and was not retried.
- Scoped commit/push: `4adedccf7a46661ccb9b7bfda1702122ddcc73b6` is published on `origin/main`; unrelated scratch/debug/backup files remain untracked and untouched.
2026-09-15 K01: Hotspot updater restores old env, rebuilds/checks radius, starts from permanent path, retains failed recovery state. 14 focused tests + bash -n passed; GPT-5.6 review. No generic rollback edits. Live .71 acceptance next.
## 2026-09-28 15:40 +03:00 — Hotspot fresh-host bootstrap candidate

- Source HEAD `898a9a7` plus preserved pre-existing dirty work. `update-server/bootstrap-hotspot.sh` now installs missing signed apt host prerequisites, Docker Engine and Ubuntu 26.04 `docker-compose-v2` (or compatible `docker-compose-plugin`) and verifies daemon access instead of ignoring a failed service start. No channel, publisher or signer was changed.
- `bash -n` and focused Hotspot bootstrap/release contract tests **11 passed**; initial Windows test run failed only because `python3` resolved to the Windows Store alias, then passed with a temporary local executable shim. `git diff --check` passed. On the clean Ubuntu 26.04 host the required `minisign` and Compose v2 packages were available from apt; Docker/Compose were installed and a staging Hotspot stack started separately.
- Candidate is **not published** to the update server. User clarified that storage layout must be automatic: the local bootstrap prefers an existing data mount, otherwise can format/mount exactly one signature-free blank disk of at least 500 GB, otherwise uses a root filesystem only if it has at least 900 GB total and 700 GB free. Ambiguous or previously used disks fail closed. `bash -n` and 12 focused tests passed; physical blank-disk formatting has **not** been tested on a disposable dual-disk VM. A signed Hotspot release and independent backup/restore acceptance remain open; the update server's active script has not been replaced.
## 2026-09-28 16:38 +03:00 — Hotspot automatic storage selection

- Source HEAD `898a9a7` plus preserved dirty work. Bootstrap now auto-selects an existing mounted data volume, one provably blank >=500 GB disk, or a >=900 GB root with >=700 GB free. Customers need not select `sda`/`sdb` or layout.
- An unmounted disk carrying a filesystem/signature, multiple blank candidates, missing expected mount, or undersized root stops the install before formatting. Focused bootstrap tests `19 passed`; Bash syntax and diff check passed. No disk on the new host was formatted by this change.
- Source is uncommitted and unpublished. Disposable dual-disk acceptance, signed channel release, external backup UI/full restore and customer install remain open.
status: `HOTSPOT_SIGNED_CANDIDATE_0.3.113_INSTALLED`
verified_at: `2026-09-28 20:20 +03:00`
source_head: `0d952c93513cdb13bd854854dc528a418c218f29`

- Candidate archive SHA-256 `f5ec058a41815d2dcb35244747558cd9846dfc7d7f8bad9a713e2e57dfcbf164`, migration off; channel/archive/bootstrap Minisign verified and source/WWW channel synchronized. `hotspot-candidate` is 0.3.113; `hotspot-stable` remains 0.3.108. Installed pointer on `192.168.2.135` is 0.3.113 with healthy dependencies and Admin/Portal HTTP 200.
- IP-only bootstrap and recovery fixes: `da02a77`, `b19a6df`, `9b6025f`, `58a61c6`; signed channel record `0d952c9`. Installer focused tests 22 passed for IP-only contract and 11 passed after final recovery fix; archive gate and Bash syntax passed. Unrelated pre-existing dirty Distribution files were not staged.
- Remaining: authenticated onboarding, backup/restore, real portal FQDN/ACME, SMS delivery and physical NAS acceptance. No stable promotion or old POC mutation.

