# neosecra-distribution — Operational Checkpoint

- **Updated:** 2026-08-30
- **Repository:** `/home/sirgloomy/projects/neosecra-distribution`
- **Branch:** `main`
- **Canonical Governance:** `/home/sirgloomy/AGENTS.md`
- **Project Memory:** `.ai-ops/project-memory/DISTRIBUTION-CANONICAL-MODEL.md`

---

## 1. Durum Etiketleri (Status)
- **IMPLEMENTATION:** `UNCOMMITTED`
- **UNIT/NEGATIVE TESTS:** `REPORTED_PASS`
- **CI:** `NOT_RUN`
- **REAL SIGNED ARTIFACT:** `NOT_RUN`
- **LAB UPDATE/ROLLBACK:** `NOT_RUN`
- **PRODUCTION RELEASE:** `BLOCKED`

---

## 2. P0 — Yayına Çıkmadan Önce
- [ ] Değişiklikler için bağımsız code review yapılması.
- [ ] Commit/push yapılması ve CI sonucunun alınması.
- [ ] Production Cosign trust root/public key kurulumu ve rotation prosedürü.
- [ ] SOC ve Phish için gerçek imzalı image, attestation ve SBOM üretilmesi.
- [ ] Manifestin kendisinin imzalanması ve anti-rollback (eski manifestin yeniden oynatılmasını engelleyen) kontrolü.
- [ ] Gerçek compose profillerindeki bütün servislerin manifestle birebir eşleşmesinin kanıtlanması.
- [ ] `.13` üzerinde gerçek online/offline update ve başarısız doğrulama tatbikatı.

## 3. P1 — Operasyonel Kapanış
- [ ] Gerçek atomic upgrade/rollback tatbikatı.
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
