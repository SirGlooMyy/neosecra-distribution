# T7 DNS + Publish Kaynağı Analizi
## e2e bulgusu oc-6e7a4bbb / T7

**Durum:** `update.neosecra.com` sadece `/etc/hosts` ile çözülüyor.
Bu dokümanda DNS stratejisi seçenekleri ve kanal publish akışı önerileri sunulmuştur.
KARAR KULLANICIDA — bu adım uygulanmamıştır, sadece analiz + öneri.

---

## (a) Müşteri Kurulumlarında DNS Stratejisi

### Seçenek 1: Gerçek DNS Kaydı (ÖNERİLEN)
- **Nasıl:** `update.neosecra.com` için gerçek bir DNS A/AAAA kaydı oluştur.
  `update.neosecra.com.  A  <sunucu-public-ip>`
- **Artıları:**
  - Let's Encrypt / ZeroSSL ile otomatik TLS sertifikası (Caddy auto-HTTPS)
  - `tls internal` ihtiyacı kalkar → CA dağıtımına gerek kalmaz
  - Tüm müşteriler için tek bir update URL'i tutarlı
- **Eksileri:**
  - Public DNS kaydı gerektirir (domain + DNS yönetimi)
  - Sunucu public IP'ye ihtiyaç duyar (NAT/arkasındaysa ek yapılandırma)
- **Uygulama:**
  1. DNS sağlayıcıda A kaydı ekle
  2. Caddyfile'dan `tls` bloğunu kaldır (Let's Encrypt otomatik)
  3. Port 80 + 443'ü firewall'da aç

### Seçenek 2: Bootstrap /etc/hosts Eklesin
- **Nasıl:** `bootstrap.sh` başında `100.125.0.108 update.neosecra.com` satırını
  `/etc/hosts`'a ekle (henüz yoksa).
- **Artıları:**
  - DNS kaydı gerekmez, tamamen LAN'da çalışır
  - Mevcut kurulumla uyumlu (şu anki hosts çözümü)
- **Eksileri:**
  - `tls internal` → CA dağıtımı + trust store güncellemesi zorunlu
  - Yeni müşteri kurulumlarında hosts güncellemesi için root yetkisi gerekir
  - /etc/hosts yönetimi ölçeklenmez (çok müşteri → karmaşa)
  - DNS değişikliği durumunda her müşteriye hosts güncellemesi dağıtmak zor

### Seçenek 3: IP + SNI (TLS sertifikasında IP SAN)
- **Nasıl:** TLS sertifikasında `subjectAltName = IP:100.125.0.108` kullan,
  curl'e `--resolve` veya direkt IP ile çağır.
- **Artıları:**
  - DNS/hosts gerekmez
  - Doğrudan IP ile çalışır
- **Eksileri:**
  - `tls internal` kullanımı devam eder (CA yönetimi)
  - IP adresi değişirse sertifika yenilenmeli
  - --resolve/--connect-to kullanımı bootstrap/upgrade kodunu karmaşıklaştırır

### Öneri: **Seçenek 1 (gerçek DNS)**
En temiz ve sürdürülebilir çözüm. Caddy auto-HTTPS ile TLS tamamen
otomatikleşir, CA dağıtımına gerek kalmaz, müşteri kurulumu basitleşir.
Geçiş sürecinde Seçenek 2 (bootstrap hosts eklemesi) ile çakışma olmaz.

---

## (b) Kanal Publish Akışı

### Bileşenler

| Bileşen | Açıklama |
|---------|----------|
| **Signing key (minisign)** | `~/.neosecra/update-signing.key` — GİZLİ, asla reposuya commitlenmez |
| **Public key** | `public-keys/update-neosecra-com.pub` — reposu'da, client tarafından kullanılır |
| **publish.sh** | Artifact'leri stage'ler, imzalar, channel JSON'u günceller, rsync eder |
| **WWW root** | `update-server/www/` — Caddy'nin servis ettiği statik dosyalar |

### Seçenek A: Geliştirici Makinesinden (ÖNERİLEN)
- **Akış:**
  1. `build-release.sh 1.1.4` ile distribution.tar.gz oluştur
  2. `publish.sh --product assessment --channel stable --version 1.1.4 --archive ...` çalıştır
  3. `publish.sh --rsync user@update.neosecra.com:/srv/update` ile canlıya gönder
- **Signing key nerede:** Geliştirici makinesinde `~/.neosecra/` altında
- **Artıları:**
  - İmzalama anahtarı tek bir kontrollü yerde
  - Tam kontrol, audit trail basit
  - CI'a bağımlılık yok
- **Eksileri:**
  - İnsan hatası riski (yanlış versiyon, unutulan adım)
  - Geliştirici makinesi çalınır/kaybolursa signing key riski

### Seçenek B: CI/CD Pipeline'dan
- **Akış:**
  1. GitHub Actions (veya başka CI) release tag'ine tetiklenir
  2. `build-release.sh` çalışır, artifact oluşur
  3. `publish.sh` çalışır (signing key CI secret'ında)
  4. rsync veya SSH ile canlıya deploy
- **Signing key nerede:** CI secret store'da (GitHub Actions secrets, HashiCorp Vault)
- **Artıları:**
  - Tekrarlanabilir, otomatik, audit log'lu
  - İnsan hatası minimize
- **Eksileri:**
  - CI kurulumu + bakımı ek yük
  - Signing key'in CI'a güvenli iletilmesi gerekir (secret rotation)
  - rollback daha karmaşık

### Seçenek C: Update Sunucusu Lokal
- **Akış:** publish.sh direkt update sunucusunda çalıştırılır
  (repository update sunucusunda clone'lu)
- **Signing key nerede:** Update sunucusunda (NİSPETEN RİSKLİ)
- **Artıları:** rsync gerekmez, direkt www dizinine yazılır
- **Eksileri:** Signing key'in sunucuda durması riskli; sunucuya SSH/erişim izni
  olan herkes release imzalayabilir

### Öneri: **Seçenek A** (geliştirici makinesi) + **B** (CI) hibrit
- Küçük release'ler/patch'ler için A (hızlı)
- Major release'ler için CI (güvenli, denetlenebilir)
- Signing key: Hardware-backed (YubiKey) veya parola korumalı minisign key,
  asla plaintext dosyada saklanmaz

### Mevcut durum: publish.sh rsync hedefi olarak
```
publish.sh --rsync user@update.neosecra.com:/srv/update
```
Bu zaten Seçenek A'ya uygun. `--rsync` parametresi verilmezse sadece stage'ler
(www dizini güncellenir) — manuel `scp`/`rsync` için hazır.

---

## Özet Karar Tablosu

| Konu | Öneri | KARAR (kullanıcı) |
|------|-------|-------------------|
| DNS stratejisi | Gerçek DNS A kaydı (Seçenek 1) | ⬜ |
| Publish kaynağı | Geliştirici makinesi (Seçenek A) | ⬜ |
| Signing key lokasyonu | `~/.neosecra/`, YubiKey korumalı | ⬜ |
| CI pipeline | Gelecek: major release'ler için | ⬜ |
