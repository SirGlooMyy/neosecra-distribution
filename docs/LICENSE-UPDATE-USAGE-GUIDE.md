# NeoSecra lisans ve güncelleme kullanım kılavuzu

**Kapsam:** Assessment, SOC, PISH ve Hotspot ürünlerinin merkezi lisans
sunucusu ile Distribution/update-server entegrasyonu. Bu belge ürün ekranı,
backend veya release pipeline'ı değiştiren herkes için ortak sözleşmedir.

Kanonik tasarım sözleşmesi:
/home/sirgloomy/.codex/NEOSECRA-LICENSE-UPDATE-INTEGRATION-PLAN.md

## 1. Kaynakların sahibi

| Konu | Tek kaynak | Tüketici |
|---|---|---|
| Ürün, edition, müşteri, installation, lisans, teslimat ve ack | neosecra-lisans API/DB | License ekranı ve ürün backend'i |
| Release kanalı ve artifact manifesti | Bu repodaki channels/ | update-agent ve ürün backend'i |
| Yayınlanmış HTTP kopyası | update-server/www/ | Müşteri kurulumları |
| Ürün çalışma sürümü | Ürün backend'inin PRODUCT_VERSION değeri | UI ve preflight |
| Job durumu | Ürün backend'inin gerçek journal/session endpointi | Update ekranı |

update-server/www/channels elle düzenlenmez. channels/ ile WWW kopyası
arasındaki drift publish öncesi hatadır. Ürünler ortak Compose, ortak DB veya
ortak update job'ı kullanmaz; yalnızca bu sözleşmeyi paylaşır.

## 2. Ürün kimliği ve kanallar

| Ürün | product_code | Stable kanal | Edition |
|---|---|---|---|
| Assessment | assessment | assessment-stable | standard, enterprise |
| SOC | soc | soc-stable | standard, enterprise |
| PISH | pish | pish-stable | standard, enterprise |
| Hotspot | hotspot | hotspot-stable | standard, enterprise |

security-health, neosecra-soc, neosecra-pish ve neosecra-hotspot yalnızca eski
girdilerde API sınırında alias olabilir. Yeni lisans, release veya config
canonical kod yazmalıdır. distribution bir müşteri ürünü değil, yayın
bileşenidir.

Bir kanal status: available ise en az bir gerçek, imzalı release içermelidir.
Artifact yokken current_version veya “güncelleme var” gösterilmez; kanal
unavailable/NO_RELEASE olarak görünür.

## 3. Lisans yöneticisi akışı

### 3.1 Lisans üretme

1. Admin müşteri ve gerekiyorsa installation seçer; product_code ve edition_id
   açıkça belirlenir.
2. POST /api/v1/licenses/quick-issue çağrısında her denemede benzersiz
   Idempotency-Key kullanılır. Aynı anahtar aynı sonucu döndürür, ikinci lisans
   üretmez.
3. SIGNING_MODE=embedded yalnızca kontrollü test/HSM ortamında kullanılabilir.
   Üretimde external signer/HSM akışıyla signing-request export/import yapılır.
4. İmzalı envelope immutable saklanır; private key API, container, UI, log veya
   commit içine girmez.

Örnek istek gövdesi (sahte UUID ve TOTP kullanın):

~~~json
{
  "product_code": "soc",
  "customer_id": "<customer-uuid>",
  "edition_id": "<edition-uuid>",
  "installation_id": "<installation-public-id>",
  "perpetual": false,
  "validity_days": 365,
  "totp_code": "<step-up-code>"
}
~~~

### 3.2 Kurulum kaydı ve teslimat

Kurulum ilk açılışta lisans yöneticisinden kısa ömürlü, tek kullanımlık bir
enrollment token alır. Token yalnızca hash olarak lisans sunucusunda saklanır;
cihaz kimliği tahmin edilse bile token olmadan public key bağlanamaz.

~~~text
POST /api/v1/installations/{installation_id}/registration-token?ttl_hours=24
  Authorization: Bearer <license-admin-token>
  -> token (bir kez gösterilir; loglamayın)
~~~

Cihaz daha sonra bir defa Ed25519 public key'i üretir:

~~~text
POST /api/v1/installations/register
  X-Installation-Enrollment-Token: <one-time-token>
  product_code, installation_id, public_key, version, agent_version
  -> one-time credential
~~~

Credential yalnızca secret store'da tutulur; tekrar kayıtta overwrite yapılmaz.
Cihaz daha sonra aşağıdaki çağrıları yapar:

~~~text
POST /api/v1/fleet/heartbeat
  installation_id, product_code, version, agent_version, nonce, signature

GET /api/v1/installations/{installation_id}/license
  X-Installation-Credential: <credential>
  If-None-Match: <son-fingerprint>

POST /api/v1/installations/{installation_id}/license/ack
  X-Installation-Credential: <credential>
  { fingerprint, verifier_status, applied_at }
~~~

Değişmemiş lisans için 304 Not Modified normaldir. 200 teslimat sonrası ürün
yerel Ed25519 doğrulaması yapar ve yalnız başarılı uygulamayı ack eder. Public
license_id ile veritabanı UUID (id) hiçbir sorguda karıştırılmaz.

ACK doğrulaması fail-closed'dur: ürünün gönderdiği fingerprint, imzalı
payload'ın canonical JSON SHA-256 değeridir; `verifier_status` da ürünün
hesapladığı ortak yaşam döngüsü durumuyla aynı olmalıdır. Lisans sunucusu
kayıtlı envelope'dan fingerprint ve durum değerini yeniden hesaplar, uyumsuz
istekleri `LICENSE_FINGERPRINT_MISMATCH` veya `LICENSE_STATUS_MISMATCH` ile
reddeder ve başarılı yanıtta yalnız canonical fingerprint'i kabul eder. Eski
ajanlar için envelope-hash geriye uyumluluğu bounded tutulur.

### 3.3 Envelope ve ortak durumlar

Envelope, payload string'i üzerinde Ed25519 imzasıdır:

~~~json
{
  "schema_version": 1,
  "key_id": "neosecra-license-prod-2026-01",
  "algorithm": "Ed25519",
  "payload": "<base64url-canonical-json>",
  "signature": "<base64url-signature>"
}
~~~

Payload en az license_id, product_code/product, edition, installation_id,
valid_from, expires_at, update_entitlement_until, grace_period_days, modules
ve limits alanlarını taşır. Ürün verifier'ı şu durum adlarını korur:
NOT_INSTALLED, ACTIVE, EXPIRING_SOON, GRACE_PERIOD, EXPIRED, REVOKED,
INVALID_PRODUCT, INVALID_SIGNATURE, INSTALLATION_MISMATCH ve NOT_YET_VALID.

## 4. Ürün License ekranı sözleşmesi

Her ürünün License ekranı aynı bilgileri kendi API'sinden göstermelidir:

- ürün kodu, edition, installation ID ve lisans public ID'si;
- doğrulanmış status, valid_from/expires_at ve update entitlement tarihi;
- modüller, limitler/kullanım, fingerprint ve key ID;
- son heartbeat, teslimat ve ack zamanı/durumu;
- online pull/ack sonucu ve offline .lic import seçeneği.

UI lisans sunucusuna doğrudan secret ile bağlanmaz; backend credential ve
ETag'ı yönetir. “Kuruldu”, “aktif” veya “senkronize” bildirimi yalnız backend
başarısı ve local signature/product/installation doğrulamasından sonra gösterilir.
Hata kodu kullanıcıya kaybolmadan gösterilir; sahte başarı toast'ı yoktur.

## 5. Release kanalı sözleşmesi

Her channels/<product>-stable.json aynı alanları taşır:

~~~json
{
  "channel": "soc-stable",
  "product": "soc",
  "product_code": "soc",
  "edition": "enterprise",
  "current_version": "1.4.0",
  "status": "available",
  "releases": [
    {
      "version": "1.4.0",
      "minimum_current_version": "1.3.0",
      "released_at": "2026-08-26T12:00:00Z",
      "release_notes": "...",
      "archive": {
        "url": "https://update.neosecra.com/releases/1.4.0/soc-1.4.0.tar.gz",
        "sha256": "<64-hex>",
        "size_bytes": 123,
        "signature_url": "https://update.neosecra.com/releases/1.4.0/soc-1.4.0.tar.gz.minisig"
      },
      "migrations": true,
      "backup_required": true,
      "rollback_supported": true
    }
  ]
}
~~~

archive.sha256, TLS ve archive .minisig doğrulaması olmadan release uygulanmaz.
Ürün/edition/channel uyuşmazlığı fail-closed'dur. releases boşsa update
butonu değil “release yok” durumu gösterilir.

## 6. Release yayınlama

Yayın workstation'ında private minisign key repo dışında (600) bulunur. Gerçek
secret kullanmadan önce dry-run yapın:

~~~bash
./update-server/publish.sh \
  --product soc --channel stable --version 1.4.0 \
  --archive /path/to/soc-1.4.0.tar.gz \
  --dry-run
~~~

Gerçek publish için minisign, sha256sum, python3 ve imzalama anahtarı zorunludur:

~~~bash
./update-server/publish.sh \
  --product soc --channel stable --version 1.4.0 \
  --archive /path/to/soc-1.4.0.tar.gz \
  --rsync user@update-host:/srv/update
~~~

--bundle yalnız gerçekten üretilmiş Docker bundle varsa eklenir. PISH/SOC için
artifact üretilmediyse publish çalıştırılmaz ve kanal available yapılmaz.
Çoklu hedef için UPDATE_SERVER_TARGETS kullanılabilir. Publish:

1. arşivi www/releases/<version>/ altında stage eder;
2. SHA-256 ve minisign sidecar üretir;
3. channels/ ile WWW kopyası drift'ini reddeder;
4. kanal release entry'sini günceller ve kanal JSON'unu imzalar;
5. yalnızca açıkça verilen rsync hedeflerine kopyalar.

Publish sonrası doğrulama:

~~~bash
bash -n update-server/publish.sh
./bin/validate-channels.sh
sha256sum -c www/releases/<version>/<archive>.sha256
minisign -Vm www/channels/<product>-stable.json \
  -p public-keys/update-neosecra-com.pub
~~~

Temiz VM release gate'i geçmeden müşteri veya canlı sunucuya rsync/deploy
yapılmaz. Canlı hostlarda deploy, restart veya migration için açık operatör
onayı gerekir.

## 7. Update-agent ve backend akışı

Ürün backend'i update-server'a değil kendi host bridge'ine yazar. Ürün başına
aşağıdaki ayarlar canonical kodla doldurulur:

~~~text
UPGRADE_EXECUTION_PROVIDER=AGENT
UPGRADE_EXECUTION_ENABLED=false       # change window'da açıkça true
UPGRADE_PRODUCT=soc
UPGRADE_EDITION=enterprise
UPGRADE_RELEASE_CHANNEL=soc-stable
UPGRADE_CHANNEL_URL=https://update.neosecra.com/channels/soc-stable.json
UPGRADE_TRIGGER_DIR=/upgrade-bridge/trigger
UPGRADE_JOURNAL_DIR=/upgrade-bridge/journal
UPGRADE_AGENT_HEARTBEAT=/upgrade-bridge/agent-alive
~~~

Agent ve backend şu sırayı uygular:

1. product_code, edition ve semver kontrolü; trigger JSON shell komutu olarak
   çalıştırılmaz.
2. Kanal JSON ve kanal minisign doğrulanır.
3. Hedef arşiv TLS ile indirilir; SHA-256 ve archive minisign doğrulanır.
4. Staging layout kontrol edilir; çalışan release ve config'e dokunulmaz.
5. Backup, migration ve authenticated health gate çalışır.
6. Başarıda current atomik değiştirilir; her adım journal'a yazılır.
7. Hata/retry durumunda eski release ve backup ile rollback yapılır; UI
   journal'ı tekrar okuyarak gerçek durumu gösterir.

Update backend'de entitlement, imzalı kanal, hedef semver, taze heartbeat,
backup, migration preflight ve health/rollback kapıları PASS olmadan başlamaz.
`POST /system/updates/start` için `Idempotency-Key` header'ı zorunludur; eksik
header `400 IDEMPOTENCY_KEY_REQUIRED` döner. Aynı ürün/installation/target
için aynı anahtar aynı journal/session sonucunu replay eder ve ikinci bir job
üretmez. Anahtar farklı müşteri, ürün veya hedef sürüm arasında yeniden
kullanılamaz; replay kaydı backend tarafından tutulur.

## 8. Ürün Update ekranı sözleşmesi

Ekranlar ortak alanları okur; farklı ürünler için field adı veya anlamı
değiştirilmez:

~~~json
{
  "product_code": "soc",
  "installation_id": "...",
  "current_version": "1.3.0",
  "license": {
    "status": "ACTIVE",
    "update_entitlement_until": "..."
  },
  "update": {
    "channel": "soc-stable",
    "channel_status": "ok",
    "target_version": "1.4.0",
    "can_auto_upgrade": false,
    "heartbeat_fresh": false,
    "can_backup": true,
    "can_rollback": true,
    "preflight": "fail",
    "reason_code": "AGENT_STALE"
  },
  "active_job": null
}
~~~

Minimum UI davranışı:

- Sürüm ve release notes kanaldan gelir; hard-code version kullanılmaz.
- Tek tık güncelle yalnız can_auto_upgrade=true ve tüm preflight kontrolleri
  PASS ise enabled olur.
- Disabled nedeni LICENSE_EXPIRED, LICENSE_REVOKED, CHANNEL_INVALID, NO_RELEASE,
  AGENT_STALE, BACKUP_UNAVAILABLE veya HEALTH_GATE_FAILED gibi sabit kodlardan
  biriyle gösterilir.
- Onay penceresi hedef sürüm, backup/rollback ve beklenen kesintiyi gösterir.
- Başlatma sonrası yalnız gerçek session/journal state gösterilir:
  PREFLIGHT, BACKING_UP, MIGRATING, VERIFYING, COMPLETED, FAILED, ROLLED_BACK.
  Browser refresh veya yeniden girişte session yeniden okunur; sahte yüzde veya
  progress üretilmez.

## 9. Sorun giderme sırası

1. UPGRADE_CHANNEL_URL doğru ürün kanalını gösteriyor mu?
2. /system/updates/check HTTP/TLS ile kanalı okuyabiliyor mu?
3. Kanal product_code, edition, status ve imzayı geçiyor mu?
4. releases içinde mevcut sürümden büyük, SHA-256/minisig'li entry var mı?
5. Local lisans status ve update_entitlement_until update'e izin veriyor mu?
6. Agent heartbeat taze mi, preflight ve backup PASS mi?

Bunlardan biri başarısızsa UI “güncelleme yok” diye maskelemek yerine gerçek
reason code/message göstermelidir. NO_RELEASE ile CHANNEL_INVALID aynı değildir.

## 10. Yapılmaması gerekenler

- License private key, installation credential, TOTP, CA key veya gerçek token'ı
  repo/log/UI response'a yazma.
- Ürünü assessment lisansına gizli modül olarak bağlama; her ürün canonical
  koduyla lisanslanır.
- Customer quota lisansını platform license entitlement ile karıştırma.
- İmzalanmamış, hash'i uyuşmayan veya artifact'i olmayan release'i available
  ilan etme.
- Frontend'de yalnız state değiştirerek lisans/update başarılı gösterme.
- curl -k, --insecure, git reset --hard, git clean veya docker compose down -v
  kullanma.
- Aynı idempotency key'i farklı müşteri/ürün/target için tekrar kullanma.
- Ortak Compose/DB veya ürünler arası update job'ı oluşturma.

## 11. Kabul ve teslim checklist'i

- [ ] Golden envelope: geçerli, yanlış ürün, yanlış installation, expired/grace,
      revoked, bad signature ve rotated key.
- [ ] Register → heartbeat → pull (200/304) → local verify → ack akışı.
- [ ] Quick-issue idempotency ve external signer fail-closed testi.
- [ ] Channel signature, product/edition mismatch, no-release ve SHA/minisig
      mismatch testleri.
- [ ] Entitlement expired/revoked, stale heartbeat, backup/migration/health
      failure ve rollback testleri.
- [ ] UI disabled reason, gerçek journal/session, refresh-after-restart ve
      erişilebilir hata mesajı testi.
- [ ] bash -n/shellcheck, ilgili backend suite ve frontend build.
- [ ] Gerçek backend/PostgreSQL ve gerekiyorsa izole Docker E2E; mock sonucu canlı
      kanıtı olarak raporlanmaz.

Canlı rollout bu kılavuzun parçası değildir: canlıya çıkılmadıysa raporda
NOT_RUN açıkça yazılır; backup, rollback ve operator onayı olmadan deploy
yapılmaz.
