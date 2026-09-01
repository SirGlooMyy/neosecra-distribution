# neosecra-distribution — Operational Checkpoint

- **Updated:** 2026-08-30
- **Repository:** `/home/sirgloomy/projects/neosecra-distribution`
- **Branch:** `main`
- **Canonical Governance:** `/home/sirgloomy/AGENTS.md`
- **Project Memory:** `.ai-ops/project-memory/DISTRIBUTION-CANONICAL-MODEL.md`

---

## 1. Durum Etiketleri (Status)
- **IMPLEMENTATION:** `COMMITTED`
- **UNIT/NEGATIVE TESTS:** `REPORTED_PASS`
- **CI:** `PENDING_VERIFICATION`
- **REAL SIGNED ARTIFACT:** `NOT_RUN`
- **LAB UPDATE/ROLLBACK:** `VERIFIED_FAIL_CLOSED` (Anti-rollback ve imza denetimi)
- **PRODUCTION RELEASE:** `BLOCKED`

---

## 2. P0 — Yayına Çıkmadan Önce
- [x] Değişiklikler için bağımsız code review yapılması (Artifact onayı alındı).
- [x] Commit/push yapılması ve CI sonucunun alınması.
- [x] Production Cosign trust root/public key kurulumu ve rotation prosedürü (Keychain/directory desteği eklendi).
- [ ] SOC ve Phish için gerçek imzalı image, attestation ve SBOM üretilmesi.
- [x] Manifestin kendisinin imzalanması ve anti-rollback (eski manifestin yeniden oynatılmasını engelleyen) kontrolü (ISO8601 Timestamp karşılaştırması uygulandı).
- [x] Gerçek compose profillerindeki bütün servislerin manifestle birebir eşleşmesinin kanıtlanması.
- [x] `.13` üzerinde gerçek online/offline update ve başarısız doğrulama tatbikatı (Gerçekleştirildi, Exit 4 mekanizması ve atomic `.env.v1` rollback kanıtlandı).

## 3. P1 — Operasyonel Kapanış
- [ ] Gerçek atomic upgrade/rollback tatbikatı (Başarılı tam akış).
- [ ] Migration öncesi backup ve gerçek restore.
- [ ] Update sırasında elektrik/process kesilmesi recovery testi.
- [ ] Aynı anda iki updater çalışmasını engelleyen lock.
- [ ] Disk dolması, registry kesintisi ve yarım bundle senaryoları.
- [ ] Rollback sırasında `.env.v1`, symlink, image ve DB sürümünün birlikte eski hâline dönmesi.
- [ ] Assessment/Hotspot legacy allow-list’in sahibi, sona erme tarihi ve tamamen kaldırılacağı sürümün belirlenmesi.
- [ ] License servisinin gerçek paketleme/update/rollback akışı.
- [ ] Update audit kayıtları, heartbeat ve merkezi GUI görünürlüğü.
- [ ] Customer package ile gerçek air-gap kurulum testi.

## 4. P2 — Hardening
- [ ] Tam SPDX/CycloneDX validation ve vulnerability/license policy (şu an sadece yapısal düzeyde).
- [ ] Key rotation, certificate-chain ve keyless/Rekor politikası.
- [ ] Canary/percentage rollout.
- [ ] Otomatik compatibility çözümleme.
- [ ] Çoklu mimari image doğrulaması.
- [ ] Release promotion dashboard’u.

---

## DIST-LIVE-CLOUDFLARE-TLS-012 (2026-09-01 retry)
- Authorized origin `10.33.99.13`: TCP 22/80/443/7443/9445/9446/9447 unreachable; no SSH authentication or live mutation occurred.
- Public Cloudflare baseline: `license.neosecra.com`, `update.neosecra.com`, and `registry.neosecra.com` each returned strict TLS `526`.
- Local candidate: Cloudflare Origin wildcard SAN `*.neosecra.com`, issuer Cloudflare Origin SSL CA, valid 2026-08-29 through 2041-08-25; public-key/key match PASS; Caddy/Compose validation PASS.
- Scoped runbook/test/evidence added: `docs/CLOUDFLARE-ORIGIN-TLS-012.md`, `update-server/src/cloudflare-origin-test-012.sh`, `.ai-ops/evidence/DIST-LIVE-CLOUDFLARE-TLS-012.md`.
- Status: `BLOCKED`; direct `.33` SNI, pre-change live backup, proxy reload, and two-round public smokes are `NOT_RUN`; `LIVE_VERIFIED` is prohibited until all gates pass.
