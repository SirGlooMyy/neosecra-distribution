# knowledge/ — kanonik bilgi bu dizinde ÇOĞALTILMAZ.
# Proje bilgisi repo'nun kendi belgelerinde yaşar; bu dosya yalnızca işaret eder.
# (Tasarım kararı: çift kaynak sapmasını önlemek.)

Kanonik belgeler (.agent/project.yaml → canonical_docs):

- AGENTS.md — çalışma kuralları, branch/push, yasaklar (curl -k, secret commit)
- README.md — yapı + erişim modeli (update server, bootstrap, müşteri paketleri)
- bootstrap.sh — müşteri kurulum giriş noktası
- docs/CUSTOMER-INSTALL.md — kurulum akışı
- docs/CUSTOMER-UPDATER-AUTH.md — GHCR/registry credential şartları
- docs/CUSTOM-CA.md — custom CA ve TLS doğrulama
- docs/BACKUP-RESTORE.md — pg_dump backup/restore
- docs/LICENSE-ISSUANCE.md — lisans çıkarma
- docs/PUBLIC-UPDATE-SERVER.md — canlı update server
- docs/TOKEN-ROTATION.md — token rotasyonu
- docs/ASSESSMENT_AGENT_HANDOFF.md — assessment canlı kurulum el devri
- docs/architecture/ — mimari kararlar
- schemas/release-manifest.schema.json — release/channel schema
- update-server/README.md — update server operasyonu
- deployment/README.md — deployment katmanı

Kalıcı mimari kararlar gerektiğinde repo kökünde DECISIONS.md açılır
(yoksa ilk kararla birlikte oluşturulur). Run kayıtları .agent/runs/
altındadır ve git'e girmez.
