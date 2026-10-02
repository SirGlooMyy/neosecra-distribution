## D11/D12 yedekten rollback — 2026-10-02

- Sorun: backup-restore ürünlerde (Assessment, SOC, PISH) ajan rollback'i koşulsuz `--pointer-only` gönderiyordu ve `rollback.sh` şifreli (`*.sql.gz.age`) ön yedeği okuyamıyordu; yedekten geri dönüş ne arayüzden ne otomatik çalışıyordu. Stack kapalıyken güvenlik yedeği alınamadığı için rollback duruyordu.
- Değişen (origin/main): `ec4c175` ajan politikayı manifestten okur, `rollback.sh` şifreli yedeği önce sınar sonra akışla yükler, güvenlik yedeği `backup.sh` ile şifreli; ardından kapalı stack düzeltmesi: yalnız veritabanı başlatılır, hazır olması beklenir (en çok 60 sn), güvenlik yedeği atlanmaz.
- Yerel test kanıtı (Codex, Windows): rollback/ajan paketleri **73 passed, 3 skipped** (izin/symlink testleri). Linux'ta ve gerçek servisle koşmadı.
- Canlı: uygulanmadı (cihaz tarafı betikleri; ilk ürün yayınıyla gider).
- Sıradaki: Assessment WP7 (rollback düğmesi) bu sürümle açılabilir; gerçek cihazda bir rollback provası.

## D10 deploy-live hızlandırma — 2026-10-02

- Sorun: `scripts/deploy-live.sh` yerel doğrulamada dosya başına birkaç süreç açıyordu; Windows'ta 352 dosyalık lisans dağıtımı 9 dk 18 sn sessiz kalıyor, takılmış sanılıyordu.
- Değişen (source HEAD `1c6caaf`, origin/main): toplu `git hash-object --no-filters --stdin-paths` (ls-tree OID'leriyle karşılaştırma), toplu sha256/stat/chmod, bir kez derlenen glob desenleri, stderr'e aşama satırları. Deny-önce-allow, blob/arşiv eşleşmesi, yedek manifesti ve taşıma sonrası doğrulama aynı.
- Yerel test kanıtı (Codex, Windows): `tests/test_deploy_live.py tests/test_deploy_live_real.py` **85 passed, 12 skipped** (POSIX testleri Windows'ta koşmadı); 350 dosyalık sentetik dry-run 438,8 sn → 22,5 sn.
- Canlı kanıt (salt-okunur dry-run, 100.117.210.76, lisans profili): 38 sn, plan önceki araçla aynı (değişecek 32, yeni 17, aynı 265). `--apply` yeni araçla henüz koşmadı; POSIX testleri Linux'ta yeniden koşmadı.
- Sıradaki: lisans `892a73a` dağıtımı bu araçla; canlıdaki distribution damgası `a1a7ccf` (araç yerelden çalışır, yeniden dağıtım zorunlu değil).

## UNIFIED-UPDATE-20260930 — 2026-10-01T11:30+03:00

- Sorun: publisher ürün adına göre dallanıyordu (SOC genel kapıya düşüyor, her ürüne Assessment bootstrap'ı, sürüm yolu çakışması, imzadan önce etkinleşen kanal, tüm www'ya `rsync --delete`); canlı host git deposu değildi ve kaynaktan ayrışmıştı; rollback doğrulama hatasını yutuyordu; bootstrap kanal imzasını doğrulamadan sürüm seçiyordu; registry dışarıdan yazılabilirdi; yayımlanmış eski Hotspot arşivlerinde (0.3.18–0.3.21) gerçek cihaz anahtarları vardı.
- Değişen (source HEAD `3fbd8b9`, origin/main): `5c7ce69` kanal eşitleme · `881cc0e` ürün kaydı tabanlı publisher · `8a24794` rollback fail-closed + manifest politikası · `ea6c038` bootstrap güvenliği + yedek şifreleme · `a81dd7e` Caddy/mailer + registry pull-only + HSTS · `6225c5a` deploy-live aracı · `b496e36` kanal doğrulayıcı · `e96167d` tek güven politikası (Minisign) · `ec20120` şablon env + Hotspot VERSION kapısı · `3fbd8b9` manifestte zorunlu trust_policy · `6fd8909` LIVE-DEPLOY sınırları.
- Yerel test kanıtı (Codex/ajan): publisher/registry/SOC/uyumluluk/rollback **111 passed** (orkestratör yeniden koşturdu); tek politika **143 passed**; yayın sertleştirme **146 passed**; manifest **222 passed**; bootstrap güvenliği **42 passed**; yedek betikleri **36 passed, 2 skipped**. deploy-live Linux'ta (update hostunda tek kullanımlık konteyner): **88 passed, 1 failed** (`test_identical_content_and_mode_not_written_or_transferred`, güvenlik dışı; canlı dry-run "ayni: 62" raporladı).
- Canlı (100.117.210.76): damga `6225c5a` (deploy-live, yedek `.deploy-backups/20260930T181450Z-none-677d169d3c547a27`); Caddy yeni yapılandırmayla yeniden başlatıldı (bind-mount inode'u nedeniyle reload yetmedi); HSTS üç vhost'ta; registry yazma 403; kanallar 200, hotspot-stable 0.3.108; canlı `channels/` soc-beta ve pish-stable yayındaki doğrulanmış çiftlerle eşitlendi. SEC-00: dört arşiv `.quarantine-sec00-20260930T104519Z` altına taşındı.
- Canlı AÇIK: `6225c5a` sonrası commit'ler (`b496e36`…`3fbd8b9`) henüz dağıtılmadı — kullanıcı deploy-live komutunu çalıştıracak; ardından hostta `bin/validate-channels.sh` 7 kanal beklenir. Cloudflare önbelleği (4 arşiv URL'si) kullanıcıda. Mailer `SMTP_PASS` env'i kullanıcıda. Gerçek anahtarla yeni publisher üzerinden imzalı yayın henüz yapılmadı.
- Sıradaki: ortak update-agent (backup-restore ürünlerde ajan rollback'i `--pointer-only` gönderiyor); release builder'ın commit'ten üretmesi; kök `AGENTS.md`/`README.md`/`docs/UNIFIED-UPDATE-OPERATIONS-PLAN.md` eski görev değişiklikleri commit edilmedi (sahibi belirsiz).

## 2026-09-15 Hotspot OFF metadata fix

- Sourcec4d4642 pushed; recovery8 tests/bash-n/diff-check PASS; independent review clear. Verified updater installed with backup, signed POC0.3.76 exit0 and terminal journal OFF/null/zero PASS. Evidence work/no-migration-metadata-20260915.md. Existing unrelated dirty work preserved; this mixed log remains outside scoped commit.

# neosecra-distribution — Fix Log

- **2026-09-05 (CENTRAL-UPDATE-SIGNING-HOST):** `100.117.210.76` verified as
  the central Update/License/Web host with Caddy/registry/runtime healthy,
  Minisign 0.12 and the existing `600` signer key in the operator home.
  Publisher now discovers `~/.local/bin/minisign`/`MINISIGN_BIN`; source and
  WWW Hotspot channel files were reconciled after a dated backup. Remote syntax,
  default-PATH dry-run, signed artifact checks and public HTTPS read-back passed.
  No Hotspot data/volume change; commit/push not run.

- **2026-09-05 (HOTSPOT-INSTALLER-CONTRACT-SMOKE):** Hotspot bootstrap'taki
  heredoc Python çağrıları `python3 -` olarak düzeltildi; Compose'un zorunlu
  ClickHouse parolası `ensure_env` ile üretilip reinstall'da korunuyor.
  Hotspot sözleşme testi **3 geçti**, üç shell syntax kontrolü geçti. Canlı
  deploy/signature/kanal değişmedi; SSH preflight bekliyor.

- **2026-09-04 (HOTSPOT-AGENT-SANDBOX-FIX):** The first live `0.3.26` trigger
  reached the Docker build but failed because systemd sandboxing left
  `/root/.docker` unwritable. Installer now creates state-local Docker/Buildx
  config and HOME paths; updater state writes keep `installed-version` and
  `active-release` aligned. Remote syntax and retry promotion passed; no
  secret was recorded and no commit/push was made.
- **2026-09-04 (UPDATE-PORT-MAP):** Recorded operator-provided reverse-proxy
  mappings. Update Caddy listens on origin `9445`; public clients use HTTPS
  443 via the hostname rewrite. Direct public `:9445` timeout is expected.

- **2026-09-04 (SIGNING-WORKSTATION-SETUP):** Installed official `minisign 0.12`
  on the current Windows development PC and verified the pinned public key
  against the checked-in Hotspot channel signature. Root cause of the blocked
  promotion is narrowed to the missing existing production private key; no key
  was generated and no channel/runtime mutation occurred. Verification PASS;
  commit/push **NOT_RUN**. Next: provision the existing key securely and run
  the release gate.

- **2026-09-04 (HOTSPOT-0.3.26-PROMOTION-PREFLIGHT):** Read-only promotion gate
  confirmed candidate archive SHA-256 `3e4d34ff7978dfee408ffa4c8f183da1b436324e826b345a3cb6dd82acb99ea5`,
  public/remote channel `0.3.25`, and Hotspot active pointer `0.3.25`.
  Update host lacks both `minisign` and the approved signing key, so publish and
  deploy were fail-closed (`BLOCKED/NOT_RUN`); no runtime/channel mutation.
  Next: provision signing key via secret management and execute the full release
  gate; commit/push **NOT_RUN**.

- **2026-09-04 (UNIFIED-UPDATE-OPERATIONS-PLAN):** Master Turkish runbook added
  at `docs/UNIFIED-UPDATE-OPERATIONS-PLAN.md`; README and project-memory index
  links updated. Root cause addressed: product-specific update knowledge was
  fragmented across runbooks without one release authority and rollout gate.
  Verification: `git diff --check` PASS and 9 Markdown references PASS; no
  channel/signature/live mutation, commit/push **NOT_RUN**. Next: provision the
  approved Minisign key and run the release gate before promotion.

- **2026-09-04 (HOTSPOT-VERSION-METADATA-FORWARD-FIX):** Bootstrap now keeps legacy `VERSION` aligned with `PRODUCT_VERSION`; remote file was backed up, atomically replaced and hash/syntax-verified. Candidate `0.3.26` was rebuilt (`3e4d34ff7978dfee408ffa4c8f183da1b436324e826b345a3cb6dd82acb99ea5`); Hotspot gate **PASS**, contract **3 passed**, archive scan **unsafe=0**. No channel/signature/runtime deploy; signing private key remains unavailable.

- **2026-09-04 (HOTSPOT-UPDATE-CONTRACT-019):** Hardened Hotspot bootstrap extraction, reinstall secret preservation, updater anti-downgrade/crash recovery, and publisher monotonic/immutable release checks. Added Hotspot contract regressions. Hotspot gate and 3 contract tests passed; broader agent contract was 12 passed / 1 failed on the pre-existing SOC signature. Remote source updates were applied after backup. Real Minisign private key is unavailable, so candidate 0.3.26 was not signed or promoted.

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

- **2026-09-02 (DIST-LIVE-CLOUDFLARE-TLS-012 current attempt):**
  - **Reachability gate:** One exact-target SSH attempt to `neosecra@10.33.99.13` timed out before authentication after 15 seconds (`rc=255`). No credentials, private key material, alternate host, or repeated discovery was used.
  - **Live change state:** No backup, proxy/certificate inspection, install, validation, reload, recreate, rollback, direct SNI, or public smoke was possible. Strict Cloudflare `526` baseline and `BLOCKED` verdict remain; `LIVE_VERIFIED` is prohibited.
2026-09-15 K01: Hotspot updater restores old env, rebuilds/checks radius, starts from permanent path, retains failed recovery state. 14 focused tests + bash -n passed; GPT-5.6 review. No generic rollback edits. Live .71 acceptance next.
## 2026-09-28 15:40 +03:00 — Hotspot clean-host apt bootstrap

- **Error/root cause:** A clean Ubuntu 26.04 server had no Docker, Compose or Minisign; bootstrap attempted `docker-compose-plugin`/legacy `docker-compose`, while Ubuntu publishes `docker-compose-v2`, and assumed other verification prerequisites were preinstalled.
- **Files/fix:** `update-server/bootstrap-hotspot.sh`, `tests/test_hotspot_release_contract.py`; install missing prerequisites from signed apt repositories, prefer Compose v2 package with plugin fallback, verify Docker daemon and fail closed on installation errors.
- **Checks:** Git Bash `bash -n`, 12 focused tests and diff check; clean-host apt package availability confirmed. Automatic disk choice covers existing mount, one provably blank disk or a high-headroom single disk; the destructive branch still needs disposable dual-disk VM acceptance. **Commit/publish:** none; existing unrelated dirty files preserved. **Next:** test physical blank-disk provisioning, then signed-channel publish after Hotspot release and independent restore acceptance.
## 2026-09-28 16:38 +03:00 — Hotspot automatic storage layout

- Error/root cause: bootstrap required a separately mounted data disk, forcing a customer to understand device names; initial auto-layout could silently fall back to root when an unmounted signed disk existed.
- Fix: `update-server/bootstrap-hotspot.sh` selects mounted/blank/root safely and rejects occupied or ambiguous disks; `docs/HOTSPOT-CLEAN-INSTALL-CONTRACT.md`, `tests/test_hotspot_storage_layout.py`, and release contract tests document/check it.
- Verify: Git Bash `bash -n update-server/bootstrap-hotspot.sh`; `python -m pytest tests/test_hotspot_release_contract.py tests/test_hotspot_bootstrap_config.py tests/test_hotspot_storage_layout.py -q` -> 19 passed; `git diff --check` passed. Commit/push/sign/publish: none.
- Next: disposable two-disk auto-provision test, then signed release; external backup and full restore still gate production use.
## 2026-09-28 20:20 +03:00 — Hotspot IP-only signed bootstrap and live acceptance smoke

- Root causes: mandatory customer FQDN/SMS config contradicted deferred UI setup; extraction rejected `__init__.py` and denied container read access; MinIO first-install directory ownership was wrong; final state write hit an unbound Bash variable.
- Files/fix: `update-server/bootstrap-hotspot.sh`, `tests/test_hotspot_bootstrap_config.py`, `docs/HOTSPOT-CLEAN-INSTALL-CONTRACT.md`, signed `channels/hotspot-candidate.json(.minisig)`. IP-only config generation, safe archive permissions, MinIO UID ownership and atomic state write corrected; 0.3.113 signed candidate installed on `192.168.2.135`.
- Checks: focused installer tests 11 passed, Bash syntax, archive gate, publisher dry-run and three Minisign checks passed; installed version/pointer 0.3.113, health dependencies ok, Admin/Portal 200. Commits `da02a77`, `b19a6df`, `9b6025f`, `58a61c6`, `0d952c9`. Stable remained 0.3.108; next is customer onboarding and full backup/NAS acceptance.

