# NeoSecra Assessment — Müşteri Kurulum Dokümanı

> **Versiyon:** 1.0
> **Hazırlayan:** NeoSecra Ops
> **Son Güncelleme:** 2026-07-27

---

## İçindekiler

1. [Önkoşullar](#1-önkoşullar)
2. [Tek Komut Kurulum](#2-tek-komut-kurulum)
3. [Adım Adım Manuel Kurulum](#3-adım-adım-manuel-kurulum)
4. [İlk Açılış](#4-i̇lk-açılış)
5. [Upgrade Akışı](#5-upgrade-akışı)
6. [Yedekleme ve Geri Yükleme](#6-yedekleme-ve-geri-yükleme)
7. [Air-Gap (İzole Ağ) Varyantı](#7-air-gap-i̇zole-ağ-varyantı)
8. [Sorun Giderme](#8-sorun-giderme)
9. [Referanslar](#9-referanslar)

---

## 1. Önkoşullar

### Donanım

| Kaynak | Minimum | Önerilen |
|--------|---------|----------|
| CPU | 4 çekirdek (x86_64) | 8 çekirdek |
| RAM | 8 GB | 16 GB |
| Disk | 100 GB (SSD) | 200 GB (NVMe) |
| İşletim Sistemi | Ubuntu 22.04/24.04 LTS **veya** RHEL 9 | Ubuntu 24.04 LTS |

> **UYARI:** RHEL 9'da SELinux ek yapılandırma gerektirebilir. Ubuntu önerilir.

### Yazılım

| Bileşen | Sürüm | Kontrol |
|---------|-------|---------|
| Docker | 24+ | `docker --version` |
| Docker Compose v2 (plugin) | 2.24+ | `docker compose version` |

Docker yüklü değilse:

```bash
# Ubuntu
curl -fsSL https://get.docker.com | sudo bash

# RHEL 9
sudo dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo
sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl enable --now docker
```

### Ağ (Network)

| Yön | Port | Protokol | Amaç |
|-----|------|----------|------|
| **Inbound** | 23300 | TCP | NeoSecra Web UI |
| **Inbound** | 22 | TCP | SSH (opsiyonel) |
| **Outbound** | 443 | TCP | `update.neosecra.com` — güncelleme/metadata |
| **Outbound** | 443 | TCP | `ghcr.io` — Docker image pull |
| **Outbound** | 443 | TCP | `api.github.com` — lisans doğrulama |
| Internal | 5432 | TCP | PostgreSQL (yalnızca container'lar arası) |
| Internal | 6379 | TCP | Redis (yalnızca container'lar arası) |

```bash
# Ubuntu / RHEL 9 — firewalld
sudo firewall-cmd --permanent --add-port=23300/tcp
sudo firewall-cmd --reload

# Ubuntu — UFW
sudo ufw allow 23300/tcp
```

> **ÖNEMLİ:** Outbound 443 kapalıysa kurulum ve upgrade başarısız olur.
> Proxy arkasında kurulum yapıyorsanız `HTTP_PROXY`/`HTTPS_PROXY` ortam değişkenlerini ayarlayın.

---

## 2. Tek Komut Kurulum

> ⚠️ **Yayın öncesi notu:** Aşağıdaki komut, bootstrap.sh'in `update.neosecra.com`
> üzerinde yayınlanması sonrası geçerlidir. Şu an için manuel kurulum adımlarını izleyin.

```bash
curl -fsSL https://update.neosecra.com/bootstrap.sh 
  | sudo NEOSECRA_TLS_MODE=public 
    NEOSECRA_GHCR_USER=<musteri-robot-adi> 
    NEOSECRA_GHCR_TOKEN=<ghcr-readonly-pat> 
    bash
```

**Yayın sonrası geçerlidir.** Öncesinde [Adım Adım Manuel Kurulum](#3-adım-adım-manuel-kurulum)'u kullanın.

---

## 3. Adım Adım Manuel Kurulum

Güvenlik bilinçli müşteriler için bootstrap betiğini inceleme imkanı sunan
alternatif kurulum yöntemi.

### 3.1 Bootstrap Betiğini İndir ve İncele

```bash
# Betiği indir
curl -fsSL -o bootstrap.sh https://update.neosecra.com/bootstrap.sh

# SHA256 sağlama kontrolü (opsiyonel — imzalı kanaldan alınan manifest'e bakın)
sha256sum bootstrap.sh

# İncele (isteğe bağlı — güvenlik kontrolü)
less bootstrap.sh
```

### 3.2 GHCR Kimlik Doğrulama

NeoSecra size bir **GitHub robot kullanıcı adı** ve **read-only PAT (Personal
Access Token)** sağlayacaktır. Token'ın `packages:read` yetkisi vardır.

```bash
# Token'ı bir env değişkenine ata (shell oturumu boyunca)
read -rsp "GHCR Token: " NEOSECRA_GHCR_TOKEN
export NEOSECRA_GHCR_USER="<musteri-robot-adi>"
export NEOSECRA_GHCR_TOKEN
export NEOSECRA_TLS_MODE=public
```

### 3.3 Kurulumu Başlat

```bash
sudo NEOSECRA_TLS_MODE=public \
  NEOSECRA_GHCR_USER="$NEOSECRA_GHCR_USER" \
  NEOSECRA_GHCR_TOKEN="$NEOSECRA_GHCR_TOKEN" \
  bash bootstrap.sh
```

Kurulum sırasında:

1. Docker kontrolü yapılır
2. Update server'dan channel metadata indirilir
3. Dağıtım paketi (`distribution.tar.gz`) indirilir ve `/opt/neosecra/assessment/`
   altına açılır
4. Rastgele parolalar üretilir ve `.env.v1` dosyasına yazılır
5. Docker image'ları `ghcr.io`'dan çekilir
6. PostgreSQL + Redis başlatılır
7. Veritabanı migrasyonları çalıştırılır
8. Backend, worker ve frontend servisleri başlatılır

**Başarılı kurulum sonu çıktısı:**

```
[neosecra] ============================================
[neosecra] NeoSecra Assessment v1.x.x KURULDU
[neosecra] Web: http://<sunucu-ip>:23300
[neosecra] Yönetim: neosecra <komut>
[neosecra] ============================================
```

---

## 4. İlk Açılış

### 4.1 Admin Kullanıcı

Kurulum tamamlandığında aşağıdaki bilgilerle giriş yapabilirsiniz:

- **Adres:** `http://<sunucu-ip>:23300`
- **E-posta:** `admin@neosecra.io`
- **Parola:** `.env.v1` dosyasında `FIRST_ADMIN_PASSWORD` olarak kaydedilir

```bash
# Admin parolasını görüntüle
sudo grep FIRST_ADMIN_PASSWORD /opt/neosecra/assessment/current/.env.v1
```

İlk girişte **admin parolasını değiştirmeniz** önerilir.

### 4.2 Lisans Envelope Yükleme

NeoSecra lisansı, bir **lisans envelope** (JSON dosyası) aracılığıyla yüklenir.
Lisans dosyası NeoSecra tarafından sağlanır.

1. Admin panele giriş yapın
2. Sol menüden **"Lisans"** sayfasına gidin
3. "Lisans Yükle" butonuna tıklayın
4. NeoSecra'dan aldığınız `envelope.json` dosyasını seçin
5. Yükleme sonrası lisans bilgileri panele yansır

Lisans yüklenmeden tarama yapılamaz.

### 4.3 İlk Tarama

1. Admin panel → **"Tarama"** sayfası → Yeni Tarama
2. Hedef IP/domain girin
3. Tarama türünü seçin (Hızlı / Tam / Özel)
4. Başlat'a tıklayın
5. Sonuçlar tarama tamamlandığında rapor sayfasında görüntülenebilir

---

## 5. Upgrade Akışı

### 5.1 UI Üzerinden (PlatformUpgrade)

1. Admin panel → **"Platform Upgrade"** sayfasına gidin
2. Mevcut sürüm ve yeni sürüm bilgisi görüntülenir
3. "Yükselt" butonuna tıklayın
4. Süreç: backup → image pull → migrasyon → restart → health check
5. Tamamlandığında bildirim gösterilir

### 5.2 CLI ile (upgrade.sh)

```bash
# Mevcut sürümü kontrol et
sudo neosecra version

# En son kararlı sürüme yükselt
sudo neosecra upgrade

# Belirli bir sürüme yükselt
sudo neosecra upgrade 1.2.0

# Hata durumunda rollback ile yükselt
sudo neosecra upgrade --rollback-on-failure
```

> **Not:** upgrade.sh bootstrap.sh ile aynı GHCR kimlik bilgilerini kullanır.
> `/opt/neosecra/secrets/ghcr-auth` dosyası mevcutsa otomatik olarak algılanır.

### 5.3 Upgrade Sonrası Doğrulama

```bash
# Sürüm kontrolü
sudo neosecra version

# Servis durumu
sudo neosecra status

# Health check (detaylı)
sudo bash /opt/neosecra/assessment/current/install/postflight.sh --timeout 120
```

---

## 6. Yedekleme ve Geri Yükleme

> Detaylı runbook için [BACKUP-RESTORE.md](BACKUP-RESTORE.md) dosyasına bakın.

NeoSecra Assessment, aşağıdaki bileşenleri içeren otomatik yedekleme sunar:

| Bileşen | Yöntem |
|---------|--------|
| PostgreSQL veritabanı | `pg_dump -Fc` (custom format, compress) |
| Uygulama konfigürasyonu (`.env.v1`) | Anlık kopya |
| Secret'lar (`/opt/neosecra/secrets/`) | Varsa dahil edilir |
| Upgrade journal | Varsa dahil edilir |

### 6.1 Zamanlanmış Yedek (Önerilen)

```bash
# Systemd timer'ı etkinleştir
sudo cp /opt/neosecra/assessment/current/deployment/neosecra-backup.{service,timer} /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now neosecra-backup.timer

# Doğrulama
sudo systemctl status neosecra-backup.timer
```

Yedekler her gün **03:17**'de alınır ve `/opt/neosecra/backups/` altında saklanır.
Varsayılan saklama: **14 gün** (`BACKUP_RETENTION_DAYS`). En az 1 yedek her zaman korunur.

### 6.2 Manuel Yedek

```bash
sudo bash /opt/neosecra/assessment/current/scripts/backup.sh
```

Çıktı: `/opt/neosecra/backups/neosecra-backup-YYYYMMDD-HHMMSS.tar.gz` + `.sha256`

### 6.3 Geri Yükleme

> **UYARI:** Restore mevcut veritabanını üzerine yazar. Önce pre-restore safety dump alınır.

```bash
# Etkileşimli (onay ister)
sudo bash /opt/neosecra/assessment/current/scripts/restore.sh \
  /opt/neosecra/backups/neosecra-backup-20260727-031700.tar.gz

# Onaysız (otomasyon)
sudo bash /opt/neosecra/assessment/current/scripts/restore.sh \
  /opt/neosecra/backups/neosecra-backup-20260727-031700.tar.gz --yes
```

Restore akışı: SHA256 doğrula → servisleri durdur → safety dump → pg_restore → alembic kontrol → servisleri başlat → /health smoke test.

### 6.4 Off-Site Yedekleme

Otomatik yedekler yalnızca yereldir. Off-site kopya için:

```bash
# rsync örneği
rsync -avz /opt/neosecra/backups/ backup@uzak-sunucu:/backups/neosecra/

# S3 örneği (AWS CLI)
aws s3 sync /opt/neosecra/backups/ s3://neosecra-backups/musteri-adi/
```

> **ÖNEMLİ:** Ayda en az bir kez test restore yapılması önerilir.  
> Detaylı prosedür: [BACKUP-RESTORE.md#6-aylık-test-restore-hatırlatıcısı](BACKUP-RESTORE.md#6-aylık-test-restore-hatırlatıcısı)

---

## 7. Air-Gap (İzole Ağ) Varyantı

İnternet erişimi olmayan ortamlar için **docker-bundle** ile offline dağıtım.

### Önkoşullar

- Bir internet bağlantılı makinede bundle hazırlanır
- USB veya ağ üzerinden hedef sunucuya aktarılır
- **Internal TLS** (Custom CA) kullanılır — bkz. [CUSTOM-CA.md](CUSTOM-CA.md)

### Adımlar

```bash
# 1. Docker bundle'ı al (NeoSecra tarafından sağlanır)
#    docker-bundle-<version>.tar.zst

# 2. Bundle'ı hedef sunucuda aç
sudo tar --zstd -xf docker-bundle-1.x.x.tar.zst -C /opt/neosecra/

# 3. Internal TLS modunda kurulum
sudo NEOSECRA_TLS_MODE=internal \
  NEOSECRA_CHANNEL_URL=file:///opt/neosecra/bundle/channel.json \
  bash bootstrap.sh
```

Detaylı air-gap prosedürü için: [CUSTOM-CA.md](CUSTOM-CA.md) ve
[PUBLIC-UPDATE-SERVER.md](PUBLIC-UPDATE-SERVER.md) dokümanlarına bakın.

---

## 8. Sorun Giderme

### 8.1 "GHCR robot token gerekli"

**Hata:** `[neosecra] GHCR robot token gerekli — NeoSecra'dan alınan
CUSTOMER-INSTALL paketine bakın`

**Çözüm:** NeoSecra'dan sağlanan kullanıcı adı ve token'ı `NEOSECRA_GHCR_USER` /
`NEOSECRA_GHCR_TOKEN` olarak ayarlayın.

### 8.2 Yetersiz Disk Alanı

**Hata:** Kurulum sırasında "No space left on device" veya Docker pull hatası.

**Çözüm:**
```bash
# Disk kullanımını kontrol et
df -h /

# Docker temizliği
docker system prune -af

# Eski release'leri temizle (son ikisi hariç)
ls -d /opt/neosecra/assessment/releases/*/ | head -n -2 | xargs sudo rm -rf
```

### 8.3 DNS Çözümleme Hatası

**Hata:** `Could not resolve host: update.neosecra.com`

**Çözüm:**
```bash
# DNS kontrolü
dig update.neosecra.com +short

# DNS sunucularını kontrol et
cat /etc/resolv.conf

# HTTP proxy kullanılıyorsa:
export HTTP_PROXY=http://proxy:8080
export HTTPS_PROXY=http://proxy:8080
```

### 8.4 "docker login failed — token expired"

**Hata:** ghcr.io girişi başarısız.

**Çözüm:** Token süresi dolmuş olabilir. NeoSecra ops ile iletişime geçerek
yeni token talep edin.

### 8.5 Migration Hatası / Rollback

**Hata:** `Upgrade failed at migration`

**Çözüm:** Upgrade otomatik rollback yapacak şekilde başlatılmadıysa:

```bash
# Son backup'ı kontrol et
ls -lt /opt/neosecra/assessment/backups/

# Manuel rollback
sudo bash /opt/neosecra/assessment/current/upgrade/rollback.sh \
  --to <onceki-surum> \
  --from-backup /opt/neosecra/assessment/backups/<backup-dizini>
```

### 8.6 "Frontend HTTP not reachable"

**Hata:** UI 23300 portunda erişilebilir değil.

**Çözüm:**
```bash
# Servis log'larını kontrol et
sudo docker compose -f /opt/neosecra/assessment/current/docker-compose.yml logs frontend

# Port dinleme kontrolü
sudo ss -tlnp | grep 23300

# Firewall kontrolü
sudo firewall-cmd --list-ports  # RHEL 9
sudo ufw status                  # Ubuntu
```

### 8.7 SELinux (RHEL 9)

```bash
# SELinux modunu kontrol et
getenforce

# Gerekirse geçici kapatma (troubleshooting için)
sudo setenforce 0
# Kalıcı çözüm için: doğru context'leri ayarlayın
sudo semanage fcontext -a -t container_file_t "/opt/neosecra(/.*)?"
sudo restorecon -Rv /opt/neosecra/
```

---

## 9. Referanslar

| Doküman | İçerik | Hedef Kitle |
|---------|--------|-------------|
| [BACKUP-RESTORE.md](BACKUP-RESTORE.md) | Yedekleme ve geri yükleme runbook'u | Müşteri admin / Ops |
| [CUSTOM-CA.md](CUSTOM-CA.md) | Custom CA oluşturma ve rotasyon | Air-gap müşteriler |
| [PUBLIC-UPDATE-SERVER.md](PUBLIC-UPDATE-SERVER.md) | Public update server mimarisi | Ops / İlgili müşteri IT |
| [CUSTOMER-UPDATER-AUTH.md](CUSTOMER-UPDATER-AUTH.md) | Token yönetimi detayları | Ops / Müşteri IT |
| [TOKEN-ROTATION.md](TOKEN-ROTATION.md) | Token rotasyon prosedürü | Ops |
| [LICENSE-ISSUANCE.md](LICENSE-ISSUANCE.md) | Lisans ve token oluşturma runbook | NeoSecra Ops (iç) |
| `neosecra --help` | CLI yardım | Müşteri admin |
