# NeoSecra ortak lisans ve güncelleme kullanım kılavuzu

Bu kılavuz dört ürünün (`assessment`, `soc`, `pish`, `hotspot`) aynı yönetim
ekranı sözleşmesini kullanırken kendi veritabanı, Compose projesi ve rollback
sınırlarını koruması içindir. Lisans sunucusu lisansın kaynağıdır; ürün
backend'i Ed25519 envelope'i yerelde doğrular. Private signing key hiçbir ürün
sunucusuna veya update sunucusuna kopyalanmaz.

## Lisans akışı

1. Lisans portalında ürün kodu ve edition (`standard` veya `enterprise`) seçilir.
2. `quick-issue` komutu idempotency key ile başlatılır; external signer
   kullanılıyorsa signing request indirilip izole signer'da imzalanır.
3. Ürün License ekranında online delivery/pull veya güvenli offline `.lic`
   import seçilir. Envelope yerelde doğrulanmadan veritabanına yazılmaz.
4. Uygulama `/licensing/status` (legacy uyumluluk için `/system/license`)
   üzerinden `license_status`, installation, fingerprint, modüller, limitler,
   CRL ve update entitlement alanlarını gösterir.
5. Pull sonrası ürün, delivery fingerprint'i `/licensing/ack` ile bildirir.

Ortak durumlar: `NOT_INSTALLED`, `ACTIVE`, `EXPIRING_SOON`, `GRACE_PERIOD`,
`EXPIRED`, `REVOKED`, `INVALID_PRODUCT`, `INVALID_SIGNATURE`,
`INSTALLATION_MISMATCH`, `NOT_YET_VALID`. `expires_at` tam sınırında lisans
geçersizdir; yalnız pozitif grace süresi varsa `GRACE_PERIOD` görülür.
Bozuk veya negatif grace değeri `INVALID_SIGNATURE` olur.

## Güncelleme akışı

1. Admin Update ekranında ürünün kendi kanalını kontrol eder: `assessment-stable`,
   `soc-stable`, `pish-stable` veya `hotspot-stable`.
2. Backend gerçek preflight sonucunu döndürür. Tek tık düğmesi yalnız lisans
   update entitlement'ı, imzalı kanal, hedef semver, taze agent heartbeat,
   backup, migration ve health/rollback kapıları PASS ise etkinleşir.
3. Agent kanalı ve kanal `.minisig` dosyasını pinned public key ile doğrular;
   arşiv TLS üzerinden indirilir ve hem SHA-256 hem minisign ile doğrulanır.
   İmzasız, hash'siz veya doğrulanamayan payload reddedilir.
4. Ürün updater'ı staging → backup → migration → health sırasını journal'lar;
   başarılı health sonrası `current` atomik değişir. Hata halinde eski release
   ve backup ile rollback yapılır.
5. UI journal'daki gerçek durumu okur. Ağ kesintisi veya sayfa kapanması
   başarı olarak gösterilmez; aynı session yeniden okunur.

`MANUAL_ONLY`/`MANUAL` provider, TwinCore orchestration ve canlı release kanıtı
olmadan otomatik yürütme ilan etmez. `NEOSECRA_REQUIRE_SIGNATURE=0` kabul
edilmez; updater ve bootstrap bu değeri açıkça reddeder.

## Sürüm ve kanal drift kapısı

Ürün çalışma sürümü ile kanalın `current_version` değeri aynı release kaynağını
temsil etmelidir. Runtime daha yeni görünüyorsa, o sürümün gerçek arşivi,
SHA-256 sidecar'ı ve minisign imzası üretilmeden kanal `available` yapılmaz.
Eski bir imzalı artifact'i yeni sürüm adıyla yeniden etiketlemek de geçerli
değildir; archive içindeki ürün sürümü, Compose `PRODUCT_VERSION` varsayılanı
ve release manifest birlikte doğrulanmalıdır.

Yayın öncesi zorunlu yerel kontroller:

```bash
bash -n update-server/publish.sh
./bin/validate-channels.sh . update-server/www
minisign -Vm update-server/www/channels/<product>-stable.json \
  -p public-keys/update-neosecra-com.pub
```

Bu kontrollerden biri başarısızsa durum `NOT_RUN/BLOCKED` kalır; update ekranı
tek tık aksiyonunu etkinleştirmez. Drift düzeltmesi yeni artifact üretimi,
imza doğrulaması ve kanal source-of-truth kopyalarının atomik güncellenmesiyle
yapılır; mevcut release dosyası üzerine yazılmaz.

## Sık kullanılan endpoint sözleşmesi

| Amaç | Ortak yol | Legacy yol |
|---|---|---|
| Durum | `GET /api/v1/licensing/status` | `GET /api/v1/system/license` |
| Offline/online kurulum | `POST /api/v1/licensing/install` | `POST /api/v1/system/license/activate` |
| Dosya kurulumu | `POST /api/v1/licensing/install/file` | `POST /api/v1/system/license/upload` |
| Yeniden doğrulama | `POST /api/v1/licensing/validate` | `POST /api/v1/system/license/validate` |
| Delivery ACK | `POST /api/v1/licensing/ack` | Ürüne göre `/license/ack` |
| Kanal kontrolü | `POST /api/v1/system/updates/check` | Aynı |
| Preflight | `POST /api/v1/system/updates/preflight` | Aynı |
| Güncelleme başlatma | `POST /api/v1/system/updates/start` | Aynı |

## Operatör güvenlik notları

- Gerçek private key, token, parola veya lisans sırrı log'a, issue'ya ve
  repository'ye yazılmaz.
- Ürünler ortak Compose veya ortak veritabanı değildir; her ürünün state,
  trigger, journal ve rollback dizini ayrıdır.
- Canlı rollout öncesi backup doğrulaması, rollback planı ve bakım penceresi
  yazılı onayla alınır.
- İmzalı artifact veya gerçek backend kanıtı yoksa kanal `no_release`/`NOT_AVAILABLE`
  kalır; UI sahte başarı üretmez.
