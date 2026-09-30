# NeoSecra Assessment — Müşteri Yedekleme ve Geri Yükleme Runbook'u

> **Versiyon:** 1.1
> **Son Güncelleme:** 2026-09-30

---

## İçindekiler

1. [Genel Bakış](#1-genel-bakış)
1a. [Şifreleme ve Anahtar Yönetimi](#1a-şifreleme-ve-anahtar-yönetimi)
2. [Kurulum — Zamanlanmış Yedek](#2-kurulum--zamanlanmış-yedek)
3. [Manuel Yedek](#3-manuel-yedek)
4. [Geri Yükleme (Restore)](#4-geri-yükleme-restore)
5. [Off-Site Yedekleme](#5-off-site-yedekleme)
6. [Aylık Test Restore Hatırlatıcısı](#6-aylık-test-restore-hatırlatıcısı)
   - 6a. [Eski (Şifresiz) Yedeklerin Ele Alınması](#6a-eski-şifresiz-yedeklerin-ele-alınması)
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

**Çıktı:** `/opt/neosecra/backups/neosecra-backup-YYYYMMDD-HHMMSS.tar.gz.age` + `.sha256`
(`age` ile şifreli; bkz. bölüm 1a)

**Saklama:** Varsayılan 14 gün (`BACKUP_RETENTION_DAYS`), son 1 yedek her zaman korunur.

---

## 1a. Şifreleme ve Anahtar Yönetimi

Yedek; `.env.v1` parolalarını, `/opt/neosecra/secrets` içeriğini ve veritabanını
(TOTP sırları dahil) içerir. Okunabilir bir yedek, kimlik bilgisi sızıntısıyla
aynıdır. Betikler bu yüzden şunları **koşulsuz** uygular:

- **Şifreleme (fail-closed):** `age` ile alıcı (public key) tabanlı. Alıcı yoksa
  ya da `age` kurulu değilse yedek **alınmaz**, net hata verilir. Secret dosyaları
  yalnızca şifreli arşivin içindedir.
- **Akış halinde şifreleme:** DB dump'ı `pg_dump | age` ile şifrelenerek yazılır;
  düz metin dump diske hiç yazılmaz. Arşiv `tar | gzip | age > dosya.partial`
  olarak yazılır, başarıyla bitince yeniden adlandırılır. Akıştaki herhangi bir
  hata yedeği başarısız sayar ve `.partial` silinir.
- **İzinler:** `umask 077`; yedek dizini `0700`; her çıktı dosyası `0600`. Gevşek
  izinli mevcut dizin/dosya bulunursa sıkılaştırılır ve uyarı yazılır. Geçici
  (staging) dizin yedek dizini ile aynı dosya sisteminde, `0700` ve çıkışta silinir.
- **Bütünlük:** Şifreli dosyanın SHA-256'sı `<dosya>.sha256` olarak (`0600`)
  yanına yazılır ve restore öncesi doğrulanır.
- **Özel anahtar yedek hostunda bulunmaz.** Yedek alan host yalnızca genel anahtarı
  (alıcıyı) bilir.

### Anahtar çifti üretimi (operatör, yedek hostunda DEĞİL)

```bash
# Operatör iş istasyonunda / güvenli yönetim hostunda:
age-keygen -o neosecra-backup.key
#   Public key: age1xxxxxxxx...      <- yalnızca bu yedek hostuna verilir
chmod 600 neosecra-backup.key
```

- `neosecra-backup.key` (özel anahtar) çevrimdışı ya da şirket parola kasasında
  saklanır; **yedek hostuna kopyalanmaz**. Kaybedilirse yedekler açılamaz — en az
  iki korumalı kopya tutun.
- Birden fazla alıcı (ör. iki operatör + kurtarma anahtarı) için her satırda bir
  genel anahtar olan bir alıcı dosyası kullanın.

### Ortam değişkenleri

| Değişken | Kullanıldığı yer | Açıklama |
|----------|------------------|----------|
| `BACKUP_AGE_RECIPIENT` | backup | Tek alıcı dizgisi (`age1...`) |
| `BACKUP_AGE_RECIPIENTS_FILE` | backup | Alıcı dosyası yolu (satır başına bir alıcı) |
| `BACKUP_ALLOW_PLAINTEXT=1` | backup | **Bilinçli istisna:** alıcı yokken şifresiz yedek. Her çalıştırmada stderr'e belirgin uyarı yazılır, dosya adı `.PLAINTEXT` içerir. Alıcı tanımlıysa her zaman şifrelenir; `age` eksikse şifresize düşülmez |
| `BACKUP_AGE_IDENTITY_FILE` | restore | Özel anahtar (identity) dosyası yolu; izinleri `0600` olmalı, değilse reddedilir |
| `NEOSECRA_SECRETS_DIR` | backup | Secrets dizini (varsayılan `/opt/neosecra/secrets`) |

Alıcı ortamı systemd override ile verilir (`0600` root dosyası):

```bash
sudo install -m 0600 /dev/null /etc/neosecra/backup.env
echo 'BACKUP_AGE_RECIPIENT=age1xxxxxxxx...' | sudo tee /etc/neosecra/backup.env >/dev/null
sudo mkdir -p /etc/systemd/system/neosecra-backup.service.d/
sudo tee /etc/systemd/system/neosecra-backup.service.d/age.conf <<'EOF'
[Service]
EnvironmentFile=/etc/neosecra/backup.env
EOF
sudo systemctl daemon-reload
```

> `neosecra upgrade` öncesi otomatik yedek (`deployment/v1/backup/backup.sh`) de
> aynı ortam değişkenlerini kullanır; upgrade'i çalıştıran ortamda
> `BACKUP_AGE_RECIPIENT` tanımlı değilse yedek — dolayısıyla upgrade — reddedilir.
> V1 yedeği dizin biçimindedir: `neosecra-<sürüm>-db.sql.gz.age` (DB) ve
> `neosecra-<sürüm>-config.tar.gz.age` (env.v1 + snapshot'lar), her biri `.sha256` ile,
> ayrıca secret içermeyen `MANIFEST`. Doğrulama: `deployment/v1/backup/restore.sh
> --target <dizin>` (`BACKUP_AGE_IDENTITY_FILE` gerekir; uygulama modu hâlâ
> uygulanmamış bir iskelettir, `--confirm` reddedilir).

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
sudo BACKUP_AGE_RECIPIENT='age1xxxxxxxx...' \
  bash /opt/neosecra/assessment/current/scripts/backup.sh
```

Alıcı tanımlı değilse betik yedek almadan hata ile durur (bölüm 1a).

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
[info]  pg_dump (custom format, streamed, age-encrypted): neosecra_assessment as neosecra...
[ok]    pg_dump: 142.3MB
[ok]    env.v1 copied
[ok]    Secrets copied from /opt/neosecra/secrets
[ok]    Upgrade journal copied
[ok]    BACKUP-MANIFEST written
[ok]    Archive: /opt/neosecra/backups/neosecra-backup-20260727-031700.tar.gz.age (142.8MB)
[ok]    SHA256: /opt/neosecra/backups/neosecra-backup-20260727-031700.tar.gz.age.sha256
[info]  Retention: 2 backup(s) retained
[ok]    Backup complete: 20260727-031700
```

---

## 4. Geri Yükleme (Restore)

> **UYARI:** Restore işlemi **mevcut veritabanını üzerine yazar**.  
> Önce bir yedek alınır (pre-restore safety dump), ardından restore edilir.  
> **Üretimde yalnızca DBA gözetiminde çalıştırın.**

### 4.1 Ön Koşullar

- `age` kurulu olmalı; özel anahtar (identity) dosyası `0600` izinli olmalı
  ve **yalnızca restore sırasında** operatör tarafından sağlanmalıdır
- Docker ve Docker Compose v2 çalışıyor olmalı (yalnızca `--confirm` ile yazarken)
- Yedek dosyası (`tar.gz.age` + `.sha256`) erişilebilir olmalı
- Yeterli disk alanı (yedek boyutunun en az 2 katı)

### 4.2 Restore Komutu

`restore.sh` **varsayılan olarak yalnızca doğrular** (verify-only): SHA256'yı
kontrol eder, arşivi ve içindeki dump'ı boru hattında (diske yazmadan) çözer.
Servislere/veritabanına yazmak için açık `--confirm` bayrağı gerekir.
`--yes` tek başına onay değildir.

```bash
export BACKUP_AGE_IDENTITY_FILE=/guvenli/neosecra-backup.key   # izin: 0600

# 1) Yalnızca doğrulama (varsayılan) — hiçbir şeye yazmaz
sudo -E bash /opt/neosecra/assessment/current/scripts/restore.sh \
  /opt/neosecra/backups/neosecra-backup-20260727-031700.tar.gz.age

# 2) Gerçek restore (etkileşimli y/N onayı ister)
sudo -E bash /opt/neosecra/assessment/current/scripts/restore.sh \
  /opt/neosecra/backups/neosecra-backup-20260727-031700.tar.gz.age --confirm

# 3) Onaysız (otomasyon/script için)
sudo -E bash /opt/neosecra/assessment/current/scripts/restore.sh \
  /opt/neosecra/backups/neosecra-backup-20260727-031700.tar.gz.age --confirm --yes
```

Eski (şifresiz) biçimdeki bir yedek için: `... restore.sh <dosya>.tar.gz --legacy-plaintext [--confirm]`.

### 4.3 Restore Akışı

1. **SHA256 doğrulama** — şifreli dosyanın bütünlüğü kontrol edilir (uyuşmazlık → dur)
2. **Kimlik dosyası kontrolü** — `BACKUP_AGE_IDENTITY_FILE` var ve `0600` olmalı
3. **Çözme doğrulaması** — arşiv ve içindeki dump tamamen çözülür (yanlış anahtar
   ya da bozulma → hedefe **hiçbir şey yazılmadan** dur). `--confirm` yoksa burada biter
4. **Servisler durdurulur** — backend, worker, frontend, beat
5. **Pre-restore safety dump** — mevcut veritabanının yedeği (`0700` geçici dizinde) alınır
6. **Database drop & recreate** — eski veritabanı silinir, yeniden oluşturulur
7. **pg_restore** — dump, çözülerek doğrudan `pg_restore` girdisine akıtılır (düz metin dosya yok)
8. **Alembic migration kontrol** — şema versiyonu kontrol edilir, gerekirse `upgrade head`
9. **Servisler başlatılır** — tüm compose servisleri ayağa kaldırılır
10. **Health check** — `/api/v1/health` endpoint'i 200 dönene kadar beklenir

### 4.4 Restore Çıktısı Örneği

```
[ok]    SHA256 verified
[info]  Backup contents:
        ./BACKUP-MANIFEST
        ./VERSION.txt
        ./env.v1
        ./neosecra-db-20260727-031700.dump.age
        ./secrets/
        ...
[ok]    Backup verified (dump: 149303296 bytes)
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
   # (yedek dizini altında 0700 izinli .restore-safety.* klasörü)
   sudo ls -la /opt/neosecra/backups/.restore-safety.*
   ```

2. Servisleri manuel başlatın:
   ```bash
   sudo docker compose -f /opt/neosecra/assessment/current/deployment/docker-compose.v1.yml \
     -p neosecra-assessment up -d
   ```

3. Destek ekibiyle iletişime geçin: `support@neosecra.com`

> **ÖNEMLİ:** Safety dump şifresiz (yalnızca `0700` dizinde) geçicidir ve script
> çıkışında silinir. Kritik durumlarda script çalışırken kopyalayıp şifreleyerek
> (`age -r ...`) güvenli bir konuma taşıyın.

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

> Off-site yedeklerin de SHA256 bütünlük kontrolü yapılmalıdır. Yedekler zaten
> `age` ile şifrelidir; **özel anahtar (identity) yedeklerle aynı yere
> konmamalıdır.** Eski şifresiz yedeklerin off-site kopyaları da düz metindir
> (bkz. bölüm 6a).

---

## 6. Aylık Test Restore Hatırlatıcısı

> **Her ayın ilk haftasında** bir test restore yapılması **ÖNERİLİR.**

Test restore akışı:

1. **Yalıtılmış ortam** (farklı sunucu veya Docker Compose profili)
2. Yedek dosyasını (`.tar.gz.age` + `.sha256`) test ortamına kopyalayın; özel anahtarı
   yalnızca bu adım için operatörden alın (`0600`), iş bitince test ortamından silin
3. Önce yalnızca doğrulama: `restore.sh <dosya>` — `SHA256 verified` ve
   `Backup verified (dump: N bytes)` beklenir
4. Sonra gerçek restore: `restore.sh <dosya> --confirm`
5. Uygulamaya giriş yapın ve temel işlevleri test edin:
   - Admin login
   - Tarama başlatma
   - Rapor görüntüleme
6. Sonuçları (tarih, yedek dosya adı, sonuç) loglayın

```bash
# Test ortamı kurulumu (örnek)
sudo NEOSECRA_TLS_MODE=public \
  NEOSECRA_GHCR_USER=test-robot \
  NEOSECRA_GHCR_TOKEN=test-token \
  bash bootstrap.sh

# Yedekten restore (özel anahtar yalnızca test süresince)
export BACKUP_AGE_IDENTITY_FILE=/guvenli/neosecra-backup.key
sudo -E bash /opt/neosecra/assessment/current/scripts/restore.sh \
  /path/to/test-backup.tar.gz.age            # doğrulama
sudo -E bash /opt/neosecra/assessment/current/scripts/restore.sh \
  /path/to/test-backup.tar.gz.age --confirm --yes
```

Test restore başarısız olursa derhal NeoSecra desteğe başvurun.

---

## 6a. Eski (Şifresiz) Yedeklerin Ele Alınması

Bu değişiklikten önce alınmış yedekler (`neosecra-backup-*.tar.gz`, `*.sql` vb.)
**şifresizdir** ve `.env.v1`/secret/TOTP sırlarını düz metin içerir. Betikler bunları
kendiliğinden silmez ya da dönüştürmez (normal retention süresi dışında); nasıl
ele alınacağı **kullanıcı/sahip kararıdır**:

- **Yeniden şifrele (saklanacaksa):**
  `age -r age1xxxxxxxx... < eski.tar.gz > eski.tar.gz.age`, ardından
  `sha256sum eski.tar.gz.age > eski.tar.gz.age.sha256` ve şifresiz özgün dosyayı
  güvenle sil.
- **Güvenle sil (gerekmiyorsa):** `shred -u eski.tar.gz` (dosya sistemi izin
  veriyorsa; aksi halde sil ve disk/volume şifrelemesine güven).
- Gerekirse eski bir yedekten restore: `restore.sh <dosya> --legacy-plaintext`
  (eski biçimde `.sha256` yalnızca hash içerir; betik bunu da okur).
- Off-site kopyaları (rsync hedefi, NAS, S3) ve yedek dizininin eski izinlerini de
  gözden geçirin; oradaki kopyalar da düz metindir. Şifresiz yedekteki secret'ların
  (TOTP sırları, token'lar) rotasyonu ayrıca değerlendirilmelidir.

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

# Eski yedekleri temizle (yedek + .sha256 birlikte)
sudo rm -f /opt/neosecra/backups/neosecra-backup-<eski-damga>.tar.gz.age{,.sha256}

# Retention süresini kısalt
sudo BACKUP_RETENTION_DAYS=7 bash /opt/neosecra/assessment/current/scripts/backup.sh
```

### 7.3 "SHA256 MISMATCH"

**Sebep:** Yedek dosyası bozulmuş veya `.sha256` dosyası uyuşmuyor.

**Çözüm:**
```bash
# Dosya bütünlüğünü manuel kontrol et (yeni biçim: "hash  dosyaadı")
cd /opt/neosecra/backups && sha256sum -c neosecra-backup-<damga>.tar.gz.age.sha256

# Bozuk yedek varsa daha eski bir yedek dene
ls -lt /opt/neosecra/backups/neosecra-backup-*.tar.gz.age
```

### 7.3a "No age recipient configured" / "age is not installed"

**Sebep:** Şifreleme alıcısı tanımlı değil ya da `age` kurulu değil; betik güvenlik
gereği yedek almaz.

**Çözüm:** `apt install age` (Debian/Ubuntu) / `dnf install age`; alıcıyı bölüm 1a'daki
gibi tanımlayın. Geçici köprü olarak `BACKUP_ALLOW_PLAINTEXT=1` mümkündür ancak
şifresiz yedek üretir ve her çalıştırmada uyarı verir.

### 7.3b "Identity file ... must be mode 0600" / "decrypt failed"

**Sebep:** Özel anahtar dosyasının izni geniş, yanlış anahtar ya da yedek bozuk.

**Çözüm:** `chmod 600 $BACKUP_AGE_IDENTITY_FILE`; doğru anahtarı kullandığınızdan
emin olun; başka bir yedek deneyin. Hata durumunda hedefe hiçbir şey yazılmaz.

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
