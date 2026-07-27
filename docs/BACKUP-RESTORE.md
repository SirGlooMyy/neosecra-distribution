# NeoSecra Assessment — Müşteri Yedekleme ve Geri Yükleme Runbook'u

> **Versiyon:** 1.0
> **Son Güncelleme:** 2026-07-27

---

## İçindekiler

1. [Genel Bakış](#1-genel-bakış)
2. [Kurulum — Zamanlanmış Yedek](#2-kurulum--zamanlanmış-yedek)
3. [Manuel Yedek](#3-manuel-yedek)
4. [Geri Yükleme (Restore)](#4-geri-yükleme-restore)
5. [Off-Site Yedekleme](#5-off-site-yedekleme)
6. [Aylık Test Restore Hatırlatıcısı](#6-aylık-test-restore-hatırlatıcısı)
7. [Sorun Giderme](#7-sorun-giderme)
8. [Referanslar](#8-referanslar)

---

## 1. Genel Bakış

NeoSecra Assessment, aşağıdaki bileşenleri içeren otomatik yedekleme sunar:

| Bileşen | İçerik | Açıklama |
|---------|--------|----------|
| **PostgreSQL** | `pg_dump -Fc` (custom format) | Tüm veritabanı — compress edilmiş, parallel restore destekler |
| **.env.v1** | Uygulama konfigürasyonu | Parolalar, image referansları, portlar |
| **Secrets** | `/opt/neosecra/secrets/` | GHCR token, lisans envelope (varsa) |
| **Upgrade Journal** | Upgrade geçmişi | Her upgrade'in zaman damgası ve versiyon bilgisi |

**Çıktı:** `/opt/neosecra/backups/neosecra-backup-YYYYMMDD-HHMMSS.tar.gz` + `.sha256`

**Saklama:** Varsayılan 14 gün (`BACKUP_RETENTION_DAYS`), son 1 yedek her zaman korunur.

---

## 2. Kurulum — Zamanlanmış Yedek

### 2.1 Systemd Timer ve Servis

```bash
# Timer ve servis dosyalarını kopyala
sudo cp /opt/neosecra/assessment/current/deployment/neosecra-backup.service \
       /opt/neosecra/assessment/current/deployment/neosecra-backup.timer \
       /etc/systemd/system/

# Yetkilendir
sudo chmod 0644 /etc/systemd/system/neosecra-backup.*

# Timer'ı etkinleştir ve başlat
sudo systemctl daemon-reload
sudo systemctl enable --now neosecra-backup.timer

# Durumu kontrol et
sudo systemctl status neosecra-backup.timer
sudo systemctl list-timers --all | grep neosecra
```

Varsayılan çalışma zamanı: her gün **03:17** (randomized delay ±300sn).

### 2.2 Özelleştirme

```bash
# Retention süresini değiştir (ör: 30 gün)
sudo mkdir -p /etc/systemd/system/neosecra-backup.service.d/
sudo tee /etc/systemd/system/neosecra-backup.service.d/override.conf <<'EOF'
[Service]
Environment=BACKUP_RETENTION_DAYS=30
EOF
sudo systemctl daemon-reload
```

### 2.3 Timer Log'ları

```bash
# Son çalıştırmayı gör
sudo journalctl -u neosecra-backup.service --since "24 hours ago"

# Sürekli takip
sudo journalctl -u neosecra-backup.timer -f
```

---

## 3. Manuel Yedek

### 3.1 Tek Komut

```bash
sudo bash /opt/neosecra/assessment/current/scripts/backup.sh
```

### 3.2 Özel Dizin

```bash
sudo BACKUP_BASE=/mnt/nfs/neosecra-backups \
  bash /opt/neosecra/assessment/current/scripts/backup.sh
```

### 3.3 Özel Retention

```bash
sudo BACKUP_RETENTION_DAYS=30 \
  bash /opt/neosecra/assessment/current/scripts/backup.sh
```

### 3.4 Çıktı Örneği

```
[info]  Disk: 45678MB free in /opt/neosecra/backups
[info]  pg_dump (custom format): neosecra_assessment as neosecra...
[ok]    pg_dump: 142.3MB
[ok]    env.v1 copied
[ok]    Secrets copied from /opt/neosecra/secrets
[info]  No upgrade journal at /opt/neosecra/assessment/upgrade-journal
[ok]    BACKUP-MANIFEST written
[ok]    Archive: /opt/neosecra/backups/neosecra-backup-20260727-031700.tar.gz (142.8MB)
[ok]    SHA256: /opt/neosecra/backups/neosecra-backup-20260727-031700.tar.gz.sha256
[info]  Retention: 2 backup(s) retained
[ok]    Backup complete: 20260727-031700
```

---

## 4. Geri Yükleme (Restore)

> **UYARI:** Restore işlemi **mevcut veritabanını üzerine yazar**.  
> Önce bir yedek alınır (pre-restore safety dump), ardından restore edilir.  
> **Üretimde yalnızca DBA gözetiminde çalıştırın.**

### 4.1 Ön Koşullar

- Docker ve Docker Compose v2 çalışıyor olmalı
- Yedek dosyası (`tar.gz` + `.sha256`) erişilebilir olmalı
- Yeterli disk alanı (yedek boyutunun en az 2 katı)

### 4.2 Restore Komutu

```bash
# Etkileşimli (onay ister)
sudo bash /opt/neosecra/assessment/current/scripts/restore.sh \
  /opt/neosecra/backups/neosecra-backup-20260727-031700.tar.gz
```

```bash
# Onaysız (otomasyon/script için)
sudo bash /opt/neosecra/assessment/current/scripts/restore.sh \
  /opt/neosecra/backups/neosecra-backup-20260727-031700.tar.gz --yes
```

### 4.3 Restore Akışı

1. **SHA256 doğrulama** — yedek dosyasının bütünlüğü kontrol edilir
2. **Servisler durdurulur** — backend, worker, frontend, beat
3. **Pre-restore safety dump** — mevcut veritabanının yedeği alınır (geri dönüş için)
4. **Database drop & recreate** — eski veritabanı silinir, yeniden oluşturulur
5. **pg_restore** — yedekteki dump custom formattan geri yüklenir
6. **Alembic migration kontrol** — şema versiyonu kontrol edilir, gerekirse `upgrade head`
7. **Servisler başlatılır** — tüm compose servisleri ayağa kaldırılır
8. **Health check** — `/api/v1/health` endpoint'i 200 dönene kadar beklenir

### 4.4 Restore Çıktısı Örneği

```
[ok]    SHA256 verified
[info]  Backup contents:
        BACKUP-MANIFEST
        VERSION.txt
        env.v1
        neosecra-db-20260727-031700.dump
        secrets/
        ...
[info]  Taking pre-restore safety snapshot...
[ok]    Pre-restore safety dump saved to /tmp/...
[ok]    Application services stopped
[ok]    Database neosecra_assessment recreated
[ok]    Database restore complete
[info]  Checking alembic migration state...
[info]  Running alembic upgrade head...
[ok]    Alembic migrations up to date
[info]  Starting all services...
[ok]    Health check passed (HTTP 200)
[ok]    Restore complete: neosecra-backup-20260727-031700.tar.gz
```

### 4.5 Hata Durumunda

Eğer restore başarısız olursa:

1. **Pre-restore safety dump** ile geri dönün:
   ```bash
   # Safety dump'un yerini restore çıktısında bulabilirsiniz
   ls -la /tmp/neosecra-restore-*
   ```

2. Servisleri manuel başlatın:
   ```bash
   sudo docker compose -f /opt/neosecra/assessment/current/deployment/docker-compose.v1.yml \
     -p neosecra-assessment up -d
   ```

3. Destek ekibiyle iletişime geçin: `support@neosecra.com`

> **ÖNEMLİ:** Safety dump, restore scripti tarafından `/tmp/` altına yazılır.  
> Sistem yeniden başlatılırsa silinebilir. Kritik durumlarda safety dump'ı hemen güvenli bir konuma taşıyın.

---

## 5. Off-Site Yedekleme

Yerel yedekler tek başına yeterli DEĞİLDİR. Aşağıdaki yöntemlerden en az birini kullanın:

### 5.1 rsync ile Uzak Sunucu

```bash
#!/bin/bash
# /etc/cron.daily/neosecra-offsite-backup
rsync -avz --remove-source-files \
  /opt/neosecra/backups/ \
  backup@uzak-sunucu:/backups/neosecra/
```

### 5.2 S3 / S3-Compatible

```bash
# AWS CLI kurulu olmalı
aws s3 sync /opt/neosecra/backups/ s3://neosecra-backups/musteri-adi/
```

### 5.3 NFS / NAS

```bash
# Yedekleri doğrudan NAS'a yazmak için:
sudo BACKUP_BASE=/mnt/nfs/neosecra-backups \
  bash /opt/neosecra/assessment/current/scripts/backup.sh
```

> Off-site yedeklerin de SHA256 bütünlük kontrolü yapılmalıdır.

---

## 6. Aylık Test Restore Hatırlatıcısı

> **Her ayın ilk haftasında** bir test restore yapılması **ÖNERİLİR.**

Test restore akışı:

1. **Yalıtılmış ortam** (farklı sunucu veya Docker Compose profili)
2. Yedek dosyasını test ortamına kopyalayın
3. Restore scriptini çalıştırın
4. Uygulamaya giriş yapın ve temel işlevleri test edin:
   - Admin login
   - Tarama başlatma
   - Rapor görüntüleme
5. Sonuçları loglayın

```bash
# Test ortamı kurulumu (örnek)
sudo NEOSECRA_TLS_MODE=public \
  NEOSECRA_GHCR_USER=test-robot \
  NEOSECRA_GHCR_TOKEN=test-token \
  bash bootstrap.sh

# Yedekten restore
sudo bash /opt/neosecra/assessment/current/scripts/restore.sh \
  /path/to/test-backup.tar.gz --yes
```

Test restore başarısız olursa derhal NeoSecra desteğe başvurun.

---

## 7. Sorun Giderme

### 7.1 Backup "Postgres not running" diyor

**Sebep:** PostgreSQL container'ı çalışmıyor veya compose dosyası bulunamıyor.

**Çözüm:**
```bash
# Servisleri kontrol et
sudo docker compose -f /opt/neosecra/assessment/current/deployment/docker-compose.v1.yml \
  -p neosecra-assessment ps

# Gerekirse başlat
sudo docker compose -f /opt/neosecra/assessment/current/deployment/docker-compose.v1.yml \
  -p neosecra-assessment up -d postgres
```

### 7.2 "Insufficient disk space"

**Sebep:** `/opt/neosecra/backups` altında yeterli alan yok.

**Çözüm:**
```bash
# Alan kontrolü
df -h /opt/neosecra/backups

# Eski yedekleri temizle
sudo rm -f /opt/neosecra/backups/neosecra-backup-*.tar.gz

# Retention süresini kısalt
sudo BACKUP_RETENTION_DAYS=7 bash /opt/neosecra/assessment/current/scripts/backup.sh
```

### 7.3 "SHA256 MISMATCH"

**Sebep:** Yedek dosyası bozulmuş veya `.sha256` dosyası uyuşmuyor.

**Çözüm:**
```bash
# Dosya bütünlüğünü manuel kontrol et
sha256sum -c /opt/neosecra/backups/neosecra-backup-*.tar.gz.sha256

# Bozuk yedek varsa daha eski bir yedek dene
ls -lt /opt/neosecra/backups/neosecra-backup-*.tar.gz
```

### 7.4 "pg_restore failed"

**Sebep:** Veritabanı dump'ı bozuk veya PostgreSQL versiyon uyumsuzluğu.

**Çözüm:**
```bash
# Postgres log'larını kontrol et
sudo docker compose -f /opt/neosecra/assessment/current/deployment/docker-compose.v1.yml \
  -p neosecra-assessment logs postgres

# Farklı bir yedek dene
# Eğer hepsi başarısızsa, NeoSecra desteğe başvurun
```

### 7.5 Timer çalışmıyor

```bash
# Timer durumunu kontrol et
sudo systemctl status neosecra-backup.timer

# Manuel tetikle
sudo systemctl start neosecra-backup.service

# Log'ları incele
sudo journalctl -u neosecra-backup.service --no-pager -n 50
```

---

## 8. Referanslar

| Doküman | İçerik |
|---------|--------|
| [CUSTOMER-INSTALL.md](CUSTOMER-INSTALL.md) | Müşteri kurulum dokümanı |
| `scripts/backup.sh` | Yedekleme scripti |
| `scripts/restore.sh` | Geri yükleme scripti |
| `deployment/neosecra-backup.service` | Systemd servis dosyası |
| `deployment/neosecra-backup.timer` | Systemd timer dosyası |
| [PUBLIC-UPDATE-SERVER.md](PUBLIC-UPDATE-SERVER.md) | Update server mimarisi |
| [CUSTOM-CA.md](CUSTOM-CA.md) | Custom CA yönetimi |
