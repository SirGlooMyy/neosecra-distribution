# NeoSecra Public Update Server — Kurulum ve İşletim

> **Durum:** Konfigürasyon + dokümantasyon hazır, DNS henüz point edilmedi.
> Canlı sunucuya dokunulmamıştır.

## İçindekiler

1. [Mimari](#1-mimari)
2. [DNS Gereksinimi](#2-dns-gereksinimi)
3. [Port Gereksinimi](#3-port-gereksinimi)
4. [İlk Kurulum (Public TLS / Let's Encrypt)](#4-i̇lk-kurulum-public-tls--lets-encrypt)
5. [İç/Ağ Air-Gap Müşteriler (Internal TLS / Custom CA)](#5-i̇çağ-air-gap-müşteriler-internal-tls--custom-ca)
6. [Kanal Publish — Çoklu Hedef](#6-kanal-publish--çoklu-hedef)
7. [Let's Encrypt Rate Limit Notu](#7-lets-encrypt-rate-limit-notu)
8. [Lab → Public Geçiş](#8-lab--public-geçiş)
9. [Sorun Giderme](#9-sorun-giderme)
10. [Referanslar](#10-referanslar)

---

## 1. Mimari

```
                         Internet/WA
                             │
              ┌──────────────┴──────────────┐
              │     Public DNS (update.     │
              │    neosecra.com A <IP>)     │
              └──────────────┬──────────────┘
                             │ 80 (LE HTTP-01) + 443 (TLS)
                             ▼
              ┌──────────────────────────────┐
              │   update.neosecra.com        │
              │   (Public Sunucu)            │
              │   ┌────────────────────────┐ │
              │   │  Caddy (Let's Encrypt) │ │
              │   │  ┌──────────────────┐  │ │
              │   │  │  /srv/update/   │  │ │
              │   │  │  ├─ channels/   │  │ │
              │   │  │  └─ releases/   │  │ │
              │   │  └──────────────────┘  │ │
              │   └────────────────────────┘ │
              └──────────────┬───────────────┘
                             │ rsync
              ┌──────────────┴───────────────┐
              │   Publish Workstation        │
              │   (publish.sh)               │
              └──────────────────────────────┘
```

İki ortam paralel çalışabilir:

| Ortam | TLS | Adres | Kullanım |
|-------|-----|-------|----------|
| **Lab** (100.125.0.108) | Custom CA (internal) | update.neosecra.com (hosts) | Geliştirme/test |
| **Public** (<public-ip>) | Let's Encrypt (public) | update.neosecra.com (DNS) | Müşteri dağıtımı |

Her iki sunucu da aynı `www/` dizininden beslenir — `publish.sh` çoklu rsync hedefine
yayın yapabilir (bkz. [Bölüm 6](#6-kanal-publish--çoklu-hedef)).

---

## 2. DNS Gereksinimi

Müşteri (kullanıcı) `neosecra.com` domain'ini yönetiyor. Aşağıdaki **A kayıtları**
kullanıcının DNS sağlayıcısında (veya Cloudflare/kendi DNS'i) oluşturulmalıdır:

```dns
update.neosecra.com.   A    <public-ip>
license.neosecra.com.  A    <public-ip>
```

Her iki subdomain aynı public IP'ye point eder. Caddy (Let's Encrypt) otomatik
olarak her domain için ayrı sertifika alır.

**ÖNEMLİ:** DNS kayıtları oluşturulmadan Caddy Let's Encrypt sertifikası alamaz.
Önce DNS'i point edin, sonra Caddy'yi başlatın.

---

## 3. Port Gereksinimi

| Port | Protokol | Amaç | Zorunlu? |
|------|----------|------|----------|
| 80 | TCP | Let's Encrypt HTTP-01 challenge | **EVET** — kapatılamaz |
| 443 | TCP | HTTPS (TLS) trafiği | **EVET** |

**UYARI:** Let's Encrypt HTTP-01 challenge'ı **80 portundan** gelir.
Port 80'i kapatmak veya yönlendirmek sertifika yenilemesini kırar.
Port 80'de bir web sunucusu çalıştırmak zorundasınız (Caddy veya başka bir reverse proxy).

Firewall'da inbound izinleri:

```bash
# Varsayılan (UFW):
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw reload

# Veya iptables:
iptables -A INPUT -p tcp --dport 80 -j ACCEPT
iptables -A INPUT -p tcp --dport 443 -j ACCEPT
```

---

## 4. İlk Kurulum (Public TLS / Let's Encrypt)

### 4.1 Sunucu Hazırlığı

```bash
# Sistem güncellemesi
sudo apt update && sudo apt upgrade -y

# Gerekli paketler
sudo apt install -y docker.io docker-compose-v2 git

# NeoSecra update server dizini
sudo mkdir -p /opt/neosecra-update
sudo chown $USER:$USER /opt/neosecra-update
cd /opt/neosecra-update
```

### 4.2 Repo Klonlama

```bash
git clone <repo-url> .
cp -r update-server/* .
```

### 4.3 Caddy'yi Public Modda Başlatma

```bash
# Public mod: Let's Encrypt otomatik TLS
#   - CADDY_MODE=public          → loglarda mod gösterimi
#   - CADDYFILE=./Caddyfile.public → tls satırı YOK, Caddy auto-provision
CADDY_MODE=public CADDYFILE=./Caddyfile.public docker compose up -d

# Doğrulama:
docker compose logs caddy | head -20
# "server running" mesajı görülmeli
```

### 4.4 TLS Doğrulama

```bash
# DNS çözümlemesi kontrol:
dig +short update.neosecra.com
# → <public-ip>

# HTTPS erişim testi (sistem trust store kullanılır, --cacert gerekmez):
curl -fsSL https://update.neosecra.com/channels/assessment-stable.json | head

# License server:
curl -fsSL https://license.neosecra.com/health
```

### 4.5 Müşteri Bootstrap (Appliance)

```bash
# Public modda kurulum — hiçbir --cacert gerekmez:
bash -c "$(curl -fsSL https://update.neosecra.com/releases/<version>/bootstrap.sh)"
```
---

## 5. İç/Ağ Air-Gap Müşteriler (Internal TLS / Custom CA)

İnternet erişimi olmayan veya özel ağdaki müşteriler için **internal TLS modu**
kullanılır. Bu modda NeoSecra Root CA sertifikası appliance'lara yüklenir ve
update server ile TLS doğrulaması bu özel CA üzerinden yapılır.

### Ne zaman internal kullanılır?

- **Air-gap / kapalı devre:** Sunucu public DNS'te değil, yalnızca LAN'da erişilebilir
- **Custom domain:** Müşteri kendi domain'ini kullanıyor, sertifikalarını kendi yönetiyor
- **Lab ortamı:** Geliştirme/test sunucusu (ör. 100.125.0.108)

### Internal modda sunucu başlatma

```bash
# Internal mod: custom CA (varsayılan, CADDY_MODE belirtmeye gerek yok)
docker compose up -d

# Veya açıkça:
CADDY_MODE=internal docker compose up -d
```

### Internal modda müşteri bootstrap

```bash
# NEOSECRA_TLS_MODE=internal ile CA trust kurulumu aktif:
NEOSECRA_TLS_MODE=internal \
  bash -c "$(curl -fsSL --cacert /path/to/update-neosecra-com-root.crt \
    https://update.neosecra.com/releases/<version>/bootstrap.sh)"
```

Detaylı custom CA dokümanı: [CUSTOM-CA.md](CUSTOM-CA.md)

---

## 6. Kanal Publish — Çoklu Hedef

`publish.sh` script'i artık birden fazla update sunucusuna eşzamanlı rsync
yapabilir. Bu sayede lab ve public sunucuları tek komutla güncellenir.

### Kullanım

```bash
# Tek hedef (--rsync ile, mevcut akış):
bash update-server/publish.sh \
  --product assessment --channel stable --version 1.1.7 \
  --archive /path/to/distribution.tar.gz \
  --rsync user@100.125.0.108:/srv/update

# Çoklu hedef (UPDATE_SERVER_TARGETS env var ile):
UPDATE_SERVER_TARGETS="user@100.125.0.108:/srv/update user@<public-ip>:/srv/update" \
  bash update-server/publish.sh \
  --product assessment --channel stable --version 1.1.7 \
  --archive /path/to/distribution.tar.gz

# --rsync ile UPDATE_SERVER_TARGETS birleşebilir (tüm hedeflere gider):
UPDATE_SERVER_TARGETS="user@100.125.0.108:/srv/update" \
  bash update-server/publish.sh \
  --product assessment --channel stable --version 1.1.7 \
  --archive /path/to/distribution.tar.gz \
  --rsync user@<public-ip>:/srv/update
```

### SSH Anahtarı

Rsync SSH üzerinden çalışır. Publish workstation'ın public SSH anahtarı her
update sunucusunun `authorized_keys`'ine eklenmelidir:

```bash
ssh-copy-id user@100.125.0.108
ssh-copy-id user@<public-ip>
```

---

## 7. Let's Encrypt Rate Limit Notu

Let's Encrypt'in üretim ortamında **rate limit**leri vardır:

| Limit | Değer |
|-------|-------|
| Sertifika / Domain / Hafta | 50 |
| Sertifika / Kayıtlı Domain / Hafta | 5 (tekrarlanan) |
| Failed validation / Domain / Saat | 5 |
| Yeni sertifika / Domain / Saat | 300 |

Bu nedenle:

- **Geliştirme/test için staging ortamı önerilir:**
  Caddy'de `CADDY_ENVIRONMENT=staging` env var'ı kullanılabilir.
  Bu, LE staging endpoint'ine yönlendirir (rate limit'ler çok daha yüksek).

- **Sertifika yenileme sırasında rate limit aşımı durumunda:**
  Caddy otomatik olarak exponential backoff uygular. Müdahale gerekmez.

- **Sık restart:** Caddy her restart'ta yeni sertifika almaya çalışmaz,
  mevcut sertifikaları `/data` volume'unda saklar.

---

## 8. Lab → Public Geçiş

Mevcut lab sunucusu (100.125.0.108) internal CA ile çalışıyor. Public sunucu
**ayrı bir host** olacak (kullanıcı kuracak). İki ortam birbirinden bağımsızdır.

### Geçiş Adımları

1. **Public sunucu kurulumu** (bkz. [Bölüm 4](#4-i̇lk-kurulum-public-tls--lets-encrypt))
2. **DNS A kaydı** oluşturma: `update.neosecra.com A <public-ip>`
3. **Publish script'ine public hedef ekleme:**
   ```bash
   UPDATE_SERVER_TARGETS="user@100.125.0.108:/srv/update user@<public-ip>:/srv/update"
   ```
4. **İlk publish:** Her iki sunucuyu da aynı release ile besle
5. **Müşteri appliance'larını geçirme:**
   - Müşteri henüz public update server'a geçmediyse lab sunucusundan (internal CA)
     almaya devam eder
   - Müşteri public update server'a geçecekse:
     - `NEOSECRA_TLS_MODE=public` (veya varsayılan) ile bootstrap/upgrade çalıştırır
     - DNS sorgusu `update.neosecra.com`'u public IP'ye çözeceği için otomatik geçer
     - Ek bir konfigürasyon gerekmez
6. **Lab sunucusu:** Public geçiş tamamlanana kadar internal CA ile çalışmaya devam eder.
   İki sunucu da aynı `www/` içeriğini sunduğu sürece sorun olmaz.

### Geçiş Sırasında Dikkat Edilecekler

| Konu | Açıklama |
|------|----------|
| **Channel URL** | Tüm appliance'lar `https://update.neosecra.com/channels/...` kullanır — DNS değişince otomatik yeni sunucuya gider |
| **Bootstrap/upgrade** | Aynı URL'ler kullanılır, TLS modu farkı otomatik |
| **İmzalama** | Aynı minisign anahtarı kullanılır — geçişten etkilenmez |
| **Rollback** | Lab sunucusu geçiş sonrası da yedek olarak tutulabilir |
---

## 9. Sorun Giderme

### 9.1 Caddy sertifika alamıyor

```bash
# Log kontrol:
docker compose logs caddy

# Yaygın nedenler:
# - DNS kaydı yok / yanlış → dig ile kontrol et
# - Port 80 kapalı → firewall'u kontrol et
# - LE rate limit → bekle (birkaç saat)
# - Alan adı başka bir sunucuda sertifika almış → bekle

# Staging ile test:
CADDY_ENVIRONMENT=staging CADDY_MODE=public CADDYFILE=./Caddyfile.public \
  docker compose up -d
```

### 9.2 Müşteri appliance TLS hatası alıyor

```bash
# Public modda:
# Sistem trust store LE'yi tanımalıdır.
curl -fsSL https://update.neosecra.com/channels/assessment-stable.json
# Hata alınıyorsa: system CA paketini güncelle
sudo apt install --reinstall ca-certificates

# Internal modda:
# --cacert kullanılıyor mu kontrol et
curl -fsSL --cacert /path/to/root.crt https://update.neosecra.com/channels/...
```

### 9.3 Rsync başarısız

```bash
# SSH bağlantısı:
ssh user@<target> "ls /srv/update/channels/"

# Hedef path doğru mu?
# publish.sh default: user@host:/srv/update
```

---

## 10. Referanslar

| Doküman | İçerik |
|---------|--------|
| [CUSTOM-CA.md](CUSTOM-CA.md) | Custom CA oluşturma ve rotasyon prosedürü |
| [T7-DNS-PUBLISH-ANALYSIS.md](T7-DNS-PUBLISH-ANALYSIS.md) | DNS/Publish strateji analizi |
| [update-server/README.md](../update-server/README.md) | Update server teknik dokümanı |
| [Caddy Automatic HTTPS](https://caddyserver.com/docs/automatic-https) | Caddy TLS dokümanı |
| [Let's Encrypt Rate Limits](https://letsencrypt.org/docs/rate-limits/) | Rate limit ayrıntıları |


