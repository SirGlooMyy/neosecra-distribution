# NeoSecra License Issuance — Ops Runbook

> **Hedef Kitle:** NeoSecra Ops (iç ekip)
> **Versiyon:** 1.0
> **Son Güncelleme:** 2026-07-27

---

## İçindekiler

1. [GitHub Robot PAT Üretimi](#1-github-robot-pat-üretimi)
2. [Müşteri Lisans Envelope'i](#2-müşteri-lisans-envelopei)
3. [Müşteri Paketi Hazırlama](#3-müşteri-paketi-hazırlama)
4. [Müşteri Ayrılırsa / Token Kompromize Olursa](#4-müşteri-ayrılırsa--token-kompromize-olursa)
5. [Müşteri Takip Tablosu](#5-müşteri-takip-tablosu)
6. [Referanslar](#6-referanslar)

---

## 1. GitHub Robot PAT Üretimi

Her müşteri için **read-only** bir GitHub PAT (Personal Access Token) oluşturulur.
Bu token yalnızca `ghcr.io` üzerinden Docker image pull yapmak için kullanılır.

### 1.1 PAT Tipi Seçimi

| Özellik | Classic PAT | Fine-grained PAT |
|---------|-------------|------------------|
| `read:packages` scope | ✅ Desteklenir | ❌ Desteklenmez |
| GHCR (ghcr.io) erişimi | ✅ **Çalışır** | ❌ GHCR okumaz |
| Repository bazlı kısıtlama | ❌ (org-wide) | ✅ |
| Süre sonu | ✅ (en fazla 1 yıl) | ✅ |

> **⚠️ KRİTİK:** GHCR (GitHub Container Registry), **yalnızca Classic PAT**
> ile `read:packages` scope üzerinden erişime izin verir. Fine-grained PAT'ler
> henüz GHCR'ı desteklemediği için **Classic PAT kullanmak zorunludur.**
>
> Distribution (release metadata) erişimi için **fine-grained PAT** kullanılabilir
> (bkz. [CUSTOMER-UPDATER-AUTH.md](CUSTOMER-UPDATER-AUTH.md)), ancak bu
> paketleme runbook'u yalnızca GHCR için classic PAT üretimini kapsar.

### 1.2 Classic PAT Oluşturma (GitHub UI)

```
1. GitHub.com → Settings → Developer settings → Personal access tokens → Tokens (classic)
2. "Generate new token (classic)" tıkla
3. Note:    "neosecra-ghcr-<musteri-adi>"   (ör: "neosecra-ghcr-acme-ltd")
4. Expiration: 90 gün (maksimum 1 yıl; müşteri sözleşmesine göre ayarla)
5. Scopes:  Sadece "read:packages" işaretle (diğerlerini işaretleme)
6. "Generate token" tıkla
7. Token'ı hemen kopyala → geçici güvenli kasaya kaydet (bitwarden / 1password)
```

### 1.3 Classic PAT Oluşturma (gh CLI) — Alternatif

```bash
TOKEN=$(gh api \
  -H "Accept: application/vnd.github+json" \
  -f "note=neosecra-ghcr-<musteri-adi>" \
  -f "expires_at=$(date -u -d '+90 days' +%Y-%m-%dT%H:%M:%SZ)" \
  --jq '.token' \
  /user/access_tokens \
  <<'EOF'
{
  "scopes": ["read:packages"]
}
EOF
)
echo "$TOKEN" > /tmp/neosecra-ghcr-<musteri-adi>.txt
```

> **NOT:** gh CLI ile classic PAT oluşturmak için `GITHUB_TOKEN` env var'ında
> yeterli yetkiye sahip (admin:org veya token yönetimi izni) bir token olmalıdır.

### 1.4 Doğrulama

```bash
echo "<token>" | docker login ghcr.io --username <musteri-robot-adi> --password-stdin
docker pull ghcr.io/sirgloomyy/neosecra-assessment-backend:1.0.0
```

---

## 2. Müşteri Lisans Envelope'i

Lisans envelope (şifrelenmiş lisans payload + metadata) oluşturma prosedürü
**neosecra-licans** reposunda bulunan runbook'a aittir.

> **➡️ Ayrıntılı lisans envelope oluşturma prosedürü için:**
> [`neosecra-licans/docs/LICENSE-ISSUANCE.md`](https://github.com/SirGlooMyy/neosecra-licans/blob/main/docs/LICENSE-ISSUANCE.md)
>
> Bu repo yalnızca **distribution** sürecini kapsar. Lisans kriptografisi,
> imzalama ve envelope şeması `neosecra-licans` reposunun sorumluluğundadır.

### Envelope Ön Koşulları

`make-customer-package.sh` çalıştırılmadan önce aşağıdakiler hazır olmalıdır:

- [ ] GitHub robot PAT oluşturuldu (bkz. [Bölüm 1](#1-github-robot-pat-üretimi))
- [ ] `neosecra-licans` reposundaki runbook izlenerek `envelope.json` üretildi
- [ ] Müşterinin aktif sözleşmesi var, lisans süresi ve modülleri net

---

## 3. Müşteri Paketi Hazırlama

Tüm müşteri teslimat malzemeleri `make-customer-package.sh` script'i ile
tek bir arşive paketlenir.

### Kullanım

```bash
bash scripts/make-customer-package.sh \
  --customer "acme-ltd" \
  --envelope /path/to/acme-envelope.json \
  --token-file /path/to/acme-robot-token.txt \
  --output /tmp/neosecra-packages/
```

### Paket İçeriği

| Dosya | Zorunlu | Açıklama |
|-------|---------|----------|
| `CUSTOMER-INSTALL.md` | ✅ | Müşteri kurulum dokümanı |
| `bootstrap.sh` | ✅ | Tek-komut kurulum betiği |
| `upgrade/upgrade.sh` | ✅ | Upgrade betiği |
| `envelope.json` | ✅ | Lisans envelope (neosecra-licans çıktısı) |
| `robot-token.txt` | ✅ | GHCR read-only PAT |
| `SUPPORT.md` | ✅ | İletişim ve destek bilgisi (placeholder) |

### Çıktılar

```
dist/neosecra-customer-<musteri>-<YYYYMMDD>.tar.gz     # Paket
dist/neosecra-customer-<musteri>-<YYYYMMDD>.sha256      # Manifest
```

> **⚠️ GÜVENLİK UYARISI:** Paket, müşteriye ait GHCR read-only token
> içerir. Güvenli kanal ile iletilmelidir.

---

## 4. Müşteri Ayrılırsa / Token Kompromize Olursa

### 4.1 Token Revoke — GitHub UI

```
1. GitHub.com → Settings → Developer settings → Personal access tokens → Tokens (classic)
2. İlgili token'ı bul (note: "neosecra-ghcr-<musteri-adi>")
3. "Delete" tıkla → onayla
4. Revoke edildiğini doğrula:
   echo "<token>" | docker login ghcr.io --username <musteri-adi> --password-stdin
   # → "authentication required" hatası alınmalı
```

### 4.2 Token Revoke — gh CLI

```bash
TOKEN_ID=$(gh api "/user/access_tokens" \
  --jq '.access_tokens[] | select(.note | startswith("neosecra-ghcr-<musteri-adi>")) | .id')
gh api -X DELETE "/user/access_tokens/$TOKEN_ID"
gh api "/user/access_tokens/$TOKEN_ID" --jq '.active'  # → 404
```

### 4.3 Müşteri Tam Ayrılma Prosedürü

1. GHCR read-only PAT'ı revoke et (bkz. 4.1 veya 4.2)
2. GHCR package access kaldır: GitHub → Packages → Manage actions access
3. Lisansı iptal et: `neosecra-licans` reposundaki runbook'u izle
4. Takip tablosunu güncelle: Müşteri durumu → ❌ İptal Edildi
5. Audit log: Tarih, işlem, operatör adı ve ticket ID'sini kaydet

### 4.4 Acil Durum: Tüm Müşteri Token'larını Listele

```bash
gh api "/user/access_tokens" --jq \
  '.access_tokens[] | select(.note | startswith("neosecra-ghcr-")) | {id, note, expires_at}'
```

---

## 5. Müşteri Takip Tablosu

Aşağıdaki tablo, her müşteri için bir satır içerecek şekilde güncellenir:

```
# NeoSecra Müşteri Lisans Takip Tablosu

| Müşteri | Token Etiketi | Lisans ID | Modüller | Expiry | Kurulum Tarihi | Durum |
|---------|--------------|-----------|----------|--------|----------------|-------|
| Acme Ltd | neosecra-ghcr-acme-ltd | LIC-2026-001 | Assessment (core) | 2026-10-27 | 2026-07-27 | ✅ Aktif |
| Beta Corp | neosecra-ghcr-beta-corp | LIC-2026-002 | Assessment + SOC | 2026-11-15 | 2026-08-01 | ✅ Aktif |
| Gamma Inc | neosecra-ghcr-gamma-inc | LIC-2026-003 | Assessment (core) | 2026-09-01 | 2026-06-15 | ❌ İptal Edildi |
```

### Sütun Açıklamaları

| Sütun | Açıklama |
|-------|----------|
| **Müşteri** | Müşterinin kısa adı (--customer parametresiyle aynı) |
| **Token Etiketi** | GitHub PAT note alanı (ör: `neosecra-ghcr-<musteri>`) |
| **Lisans ID** | `neosecra-licans` tarafından üretilen lisans ID'si |
| **Modüller** | Lisans kapsamındaki ürün modülleri |
| **Expiry** | Token son kullanma tarihi (lisans expiry'si farklı olabilir) |
| **Kurulum Tarihi** | Paketin müşteriye teslim edildiği tarih |
| **Durum** | ✅ Aktif / ❌ İptal Edildi / ⏳ Süresi Doldu / 🔄 Rotasyonda |

> **ÖNERİ:** Bu tabloyu ops ekibi kendi wiki'sinde (Notion / Confluence / GitHub
> Project) tutmalıdır. Yukarıdaki örnek yalnızca başlangıç şablonudur.

---

## 6. Referanslar

| Doküman | İçerik | Hedef Kitle |
|---------|--------|-------------|
| [CUSTOMER-INSTALL.md](CUSTOMER-INSTALL.md) | Müşteri kurulum adımları | Müşteri |
| [CUSTOMER-UPDATER-AUTH.md](CUSTOMER-UPDATER-AUTH.md) | Token tipleri ve kurulumu | Ops / Müşteri IT |
| [TOKEN-ROTATION.md](TOKEN-ROTATION.md) | Token rotasyon prosedürü | Ops |
| [PUBLIC-UPDATE-SERVER.md](PUBLIC-UPDATE-SERVER.md) | Update server mimarisi | Ops |
| [CUSTOM-CA.md](CUSTOM-CA.md) | Custom CA yönetimi | Ops |
| `neosecra-licans/docs/LICENSE-ISSUANCE.md` | Lisans envelope üretimi (canonical) | Ops (iç) |
| [GitHub — Managing PATs](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens) | GitHub PAT dokümantasyonu | Ops |
| [GitHub — About GHCR](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry) | GHCR kullanımı | Ops |