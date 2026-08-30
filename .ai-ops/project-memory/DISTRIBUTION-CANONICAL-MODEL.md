# neosecra-distribution — Canonical Domain Memory & Architecture

**Son Doğrulama Tarihi:** 2026-08-30  
**Doğrulanan HEAD:** `08c4a19bb67f6160c483fd230176de1fedf9dfc9`  
**Branch:** `main`  
**Rol:** Müşteri Kurulum Paketleri, Dağıtım Motoru, Güncelleme Kanalları, Yedekleme ve Sıfır Veri Kayıplı Geri Alma.

---

## 1. Doğrulanmış Mimari Bileşenler ve Dağıtım Zinciri

### 1.1 Dağıtım ve Kurulum Zinciri
- **Kaynak:** `docs/CUSTOMER-INSTALL.md`, `deployment/v1/install/install.sh`
- **Model:** İmzalı release manifestosu üzerinden `/opt/neosecra-v1` (veya modül bazlı hedef) dizinine kurulum yapılır.
- **Güvenlik Doğrulaması:** Minisign ve SHA-256 sağlama toplamı kontrol edilmeden staging'den aktife geçiş yapılmaz.

### 1.2 Güncelleme ve Atomik Geçiş (Atomic Activation)
- **Kaynak:** `deployment/v1/upgrade/upgrade.sh`
- **Mekanizma:** Yeni sürüm izole staging dizinine açılır (`/opt/neosecra-candidate-...`), pre-migration veritabanı yedeği alınır, Alembic migration uygulanır, health check probe çalıştırılır ve başarılı olursa atomik symlink switch ile aktif hale getirilir.

### 1.3 Yedekleme ve Geri Alma (Backup & Rollback)
- **Kaynak:** `docs/BACKUP-RESTORE.md`, `deployment/backup/neosecra-backup.sh`
- **Zamanlama:** Systemd timer (`neosecra-backup.timer`) ve pre-upgrade kancaları.
- **Rollback Güvencesi:** Önceki imaj etiketleri ve SQL dump'ları saklanır; arıza durumunda symlink eski dizine döndürülür (5-10 dk RTO).

### 1.4 Güncelleme Ajanı (Update-Agent)
- **Kaynak:** `docs/HOTSPOT-UPDATE-AGENT.md`, `docs/CUSTOMER-UPDATER-AUTH.md`
- **Davranış:** Periyodik olarak güncelleme sunucusunu (`update-server/`) yoklar, imzalı manifestoyu çeker ve onaylı kanala (`stable` / `candidate`) göre güncellemeyi başlatır.
