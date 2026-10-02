# Canlı dağıtım aracı (`scripts/deploy-live.sh`)

Araç commit edilmiş kaynaktan izinli dosyaları aktarır; servis yeniden başlatmaz.
İmzalı ürün yayınlama/promotion hattı yerine geçmez. `channels/**` ve
`update-server/www/**` yalnız publisher tarafından yönetilir.

## Kullanım ve hedef profili

`--profile distribution|lisans` zorunludur. Hedef yolun son bileşeni profil ile
birebir eşleşmelidir. SSH kullanıcı/host alanı
`^[a-z_][a-z0-9_-]*@[A-Za-z0-9.-]+$` olmalıdır; mutlak hedef yolunda `.`/`..`,
boşluk, shell karakterleri ve tek bileşenli kökler reddedilir.

```bash
# Varsayılan dry-run: hedefte kilit dahil hiçbir şey yazılmaz.
scripts/deploy-live.sh --profile distribution --ref <commit-or-tag> \
  --target <user@host:/opt/neosecra/distribution>

# Aynı kontrolü uygulamak için --apply ekleyin.
scripts/deploy-live.sh --profile distribution --ref <commit-or-tag> \
  --target <user@host:/opt/neosecra/distribution> --apply

# Lisans: profilin varsayılan listesi deploy-live.lisans.allowlist'tir.
scripts/deploy-live.sh --profile lisans --repo /path/neosecra-lisans \
  --ref <commit-or-tag> --target <user@host:/opt/neosecra/lisans>

# Araç başarı/hata çıktısında gerçek yedek adını ve rollback komutunu verir.
scripts/deploy-live.sh --profile distribution --rollback <backup-name> \
  --target <user@host:/opt/neosecra/distribution> --apply
```

Seçenekler: `--repo`, `--allowlist`, `--identity` (yalnız anahtar yolu; içeriği
okunmaz), `--transport auto|tar`, `--apply`. Güvenli mutasyon tek uzak oturumda
yapıldığı için eski `rsync` yolu kapalıdır; açık `--transport rsync` reddedilir.
Host için `BatchMode=yes`, `StrictHostKeyChecking=yes`, host argümanından önce
`--` kullanılır. `known_hosts` kaydı operatör tarafından önceden sağlanmalıdır.
Git Bash SSH çağrılarında `MSYS_NO_PATHCONV=1`, `MSYS2_ARG_CONV_EXCL='*'` kullanılır;
identity yolu `cygpath -am` ile hem Git hem native OpenSSH'nin kabul ettiği biçime çevrilir.
Uzak betik akışın başında base64 satırı olarak iletilir, yalnız bellekte çözülür;
tar akışı aynı oturumda bunu izler. Böylece native Windows SSH argv uzunluk sınırı
dosya listesini kısıtlamaz ve dry-run için uzakta geçici betik yazılmaz.

## Kaynak baytları

Kirli çalışma ağacı aktarılmaz. `--apply` kaynak deponun origin'ini
`git fetch --prune origin` ile yeniler; ref güncel origin dal uçlarından erişilebilir
olmalıdır (eski ancestor kabul edilir; yalnız etiket/yerele ait commit reddedilir).
Bu komut kaynak depodaki remote-tracking reflerini günceller; aracın repo güvenliği
origin'in operatör tarafından doğru yapılandırılmış olmasına dayanır.

Arşiv `git -c core.autocrlf=false -c core.eol=lf archive` ile üretilir. Seçilen her
dosyanın arşiv blob OID'i, `git ls-tree -r -z` ile alınan commit blob OID'i ile
eşleşmelidir. Çıkarılan ağaçta tek `git hash-object --no-filters --stdin-paths`
çağrısı kullanılır; filtreler/CRLF dönüşümü uygulanmaz ve kaynak deponun nesne
formatı korunur. Tek uyumsuzlukta SSH öncesinde durulur. Uzak doğrulama ve manifest
için SHA-256, boyutlar ve 644/755 modları toplu hesaplanır/uygulanır.
Commit edilmiş attributes ve
yerel `info/attributes`, geçici index üzerinden denetlenir. Seçilen dosyada etkin
`export-ignore`/`export-subst` reddedilir. `.gitattributes` betik, Python ve Caddyfile
için LF politikasını belirler; imzalı artifact'lerin mevcut `-text` kuralları korunur.
LF kuralı geçmişteki hatalı blobları geriye dönük değiştirmez.

## İzin listesi, hard-deny ve public trust anchors

Deny kontrolü kullanıcı allowlist'inden önce yapılır. Allowlist harf duyarlıdır;
hard-deny harf duyarsızdır. `*` bir bileşen içinde, `?` tek karakter, `**` birden çok
bileşen, `**/` sıfır veya daha çok üst bileşen eşleştirir. Regex özel karakterleri
literaldir. `./scripts/**` commit yollarındaki `scripts/...` ile eşleşmez. Boş satırlar
ve tam satır `#` yorumları atlanır; sondaki CR temizlenir. Çıplak `*`/`**` satırı,
mutlak desen, `..` ve ters eğik çizgi reddedilir. Dosya adlarında kontrol karakteri,
ters eğik çizgi, mutlak/`.`/`..` yol kabul edilmez. Kaynak symlink/submodule atlanır.

Allowlist'te olsa bile reddedilenler:

- `channels`, `update-server/www` ve altları;
- `certs`, `secrets`, `credentials`, `state`, `backups`, `.git`, `node_modules`
  bileşenlerinin hem kendileri hem altları;
- `.env*`, `create_user.py`, `.htpasswd`, `*.sql`, `*.sql.gz`, `*.dump`;
- `*.key`, `*.pem`, `*.p12`, `*.crt`, `*.cer`, `*.pfx`, `*.jks`, `*.keystore`,
  `id_rsa*`, `id_ed25519*`, `id_ecdsa*`, `*.minisign`, `minisign.key`, `*.sec`;
- `.deploy-backups`, `.deploy-staging`, `.deploy-lock`, `.deploy-incomplete*`,
  `.deployed-commit*` ve ilgili kontrol ağaçları.

**Public trust anchors** betikte kullanıcı tarafından değiştirilemeyen ayrı listeyle
tanımlıdır: `public-keys/*.pub`, `deployment/**/ca/*.crt`, `deployment/**/*.pub`.
CA sertifikası bu listede eşleşirse sertifika uzantısı yasağından istisnadır;
korunan dizin/özel anahtar yasakları devam eder. Allowlist eşleşmesi yine gereklidir.
Örneğin `deployment/ca/root.crt` kabul edilir, `deployment/tls.crt` reddedilir.

**Lisans profilinde** kök `docker-compose.yml`, `VERSION`, `.env*`, `create_user.py`
allowlist'ten bağımsız reddedilir. Geliştirme compose'u üretim compose'unu ezemez.

## Hedef, kilit ve aktarım

Uzak host Ubuntu/GNU Bash, coreutils, tar kullanmalıdır. Hedef kökün tüm üst
bileşenleri, seçilen her dosyanın tüm üst bileşenleri, damgalar, kilit, staging ve
backup yolları symlink açısından kontrol edilir. Kontrol ağaçlarında mevcut
symlink/özel dosya da reddedilir. Mevcut hedef dosya normal dosya olmalıdır;
dizin, symlink, FIFO/cihaz reddedilir. İlk kontroller kilit dahil her yazmadan önce
çalışır; kilit alındıktan sonra plan yeniden doğrulanır. Dizinler her bileşeni
yeniden kontrol ederek oluşturulur; dosya/damga taşımaları `mv -T --` kullanır.

Salt okunur plan hash **ve mod** karşılaştırır. Aynı içerik/mod dosyaları tar
aktarımından çıkarılır ve hedefte yeniden yazılmaz. Ön kontrol ile kilit altındaki
değişiklik kümesi farklıysa araç durur. Tüm mutasyon — yedek, staging, taşıma,
doğrulama, damga — `bash -euo pipefail -c` ile **tek SSH oturumunda** çalışır.
Kilit atomik `mkdir` ile alınır; rastgele sahiplik token'ı taşır. Uzak EXIT trap
yalnız token eşleşirse kilidi kaldırır. İstemci ayrı SSH çağrısıyla kilit kaldırmaz.
Temizlik hataları görünürdür; mevcut kilit otomatik çalınmaz.

Tar önce ayrı ve çıkış kodu denetlenen `-tf`/`-tvf` adımlarında listelenir. Üye kümesi
beklenen transfer listesiyle birebir eşleşmeli; yinelenen, fazla/eksik, mutlak/`..`,
dizin, symlink, hardlink veya özel üye reddedilmelidir. Mode 700 staging altında
açılır, Git executable modundan 755/644 uygulanır, SHA-256/mod/boyut doğrulanır.
Yalnız bundan sonra değişen dosyalar taşınır; hedefte tüm adaylar tekrar doğrulanır
ve commit damgası yazılır. Servis reload/restart ayrı operatör eylemidir.

## Yedek ve tam dosya geri dönüşü

Yedek adı `<UTC>-<previous-short-SHA-or-none>-<random>` biçimindedir. Transfer
listesindeki mevcut dosyalar içerik aynı ama mod farklı olsa bile `cp -p` ile
yedeklenir ve hedefle hash/mod/boyut açısından karşılaştırılır. `MANIFEST.sha256`
satır biçimi TAB ayrımlı `sha256 mode size relative-path` alanlarıdır; eski iki
alanlı yedek formatı kabul edilmez. `files/` altındaki eski dosyalara ek olarak:

- `NEW-FILES`: yeni dosyaların dağıtılan hash/mod/boyut/yol kayıtları;
- `PREVIOUS-STAMP`: önceki damganın tam baytları ve korunmuş modu;
- `STAMP-PRESENT`: önceki damganın varlığı;
- `NEW-DIRS`: dağıtımın oluşturduğu üst dizinler.

Bu metadata dosyaları da manifest kapsamındadır. Yedek `.partial` altında hazırlanır,
tamamlanınca `mv -T` ile tamamlanmış ada geçer. Yedekler otomatik silinmez.

Rollback dry-run da bütün doğrulamaları yapar ve yazmaz. Gerçek yedek yolu hedefin
`.deploy-backups/` ağacı altında, symlink içermeyen beklenen yol olmalıdır. Gerçek
dosya kümesi manifestle **birebir** eşleşir; fazla/eksik dosya ve fazla dizin
reddedilir. Hash/mod/boyut, yol, tür, deny ve metadata tutarlılığı doğrulanır.
Yalnız manifestteki dosyalar geri taşınır; eski modlar ve önceki damga tam olarak
geri getirilir. Önceden damga yoksa yeni damga silinir. `NEW-FILES` dosyaları yalnız
halen dağıtılan hash'i taşıyorsa silinir; sonradan değiştirilmiş yeni dosya varsa
**hiçbir geri yükleme yapmadan durulur ve dosya raporlanır**. Zaten yok olan yeni
dosya kabul edilir. Yeni dizinler yalnız boşsa kaldırılır; operatörün sonradan
eklediği içerik korunur. Bu, dağıtımın değiştirdiği dosyaların tam geri dönüşüdür.

## Yarıda kesilme ve sınırlar

Tamamlanmış yedekten sonra, staging/taşıma başlamadan `.deploy-incomplete` yazılır.
Başarılı doğrulama, damga ve temizlik sonrası kaldırılır. Hata/TERM/HUP işareti
korur; sonraki apply ve dry-run açık hata ve profil içeren rollback komutuyla durur.
Yalnız işaretteki yedeğe rollback kabul edilir. Rollback'in kendisi yarıda kalırsa
aynı işaret korunur. Staging kalıntıları kanıt için korunur; otomatik temizlenmez.

Dosya taşıma atomiktir; tüm dosya kümesi atomik değildir. SIGKILL/host kapanması
trap'i çalıştırmaz ve kilit de kalabilir: çalışan işlem olmadığı operatör tarafından
doğrulanmadan kilit kaldırılmamalıdır. Backup tamamlanmadan oluşan hata hedef
dosyaları değiştirmez; `.partial` inceleme gerektirebilir. Bash kontrolleri başka
ayrıcalıklı süreçlerin eşzamanlı dizin değiştirmesine karşı descriptor tabanlı
`openat` izolasyonu sağlamaz; hedef/control ağaçları dağıtım kullanıcısı dışında
yazılabilir olmamalıdır. Yedek manifesti checksum kanıtıdır, dijital imza değildir;
yedek + manifesti birlikte değiştirebilen aktöre karşı güven çapası sayılmaz.

## Canlıda öğrenilen sınırlar (30.09.2026, ilk gerçek dağıtımlar)

Kaynak SHA'lar: araç `6225c5a` ile canlıya alındı; bu bölümün yazıldığı kaynak
Distribution `origin/main` `b496e36`, Lisans `b793d21`. Canlı damga: distribution
`6225c5a` (`b496e36` henüz dağıtılmadı), lisans `b793d21`. Aşağıdakiler araç
sözleşmesinin **dışında** kalan, elle yapılması gereken adımlardır; her biri ayrı
açık yetki ister (`CLAUDE.md` SSH kuralı: servis durdurma/başlatma, config
değiştirme, migration apply, silme serbest değildir).

1. **Silinen dosyalar hedeften kaldırılmaz.** Araç yalnız ekler/günceller.
   Repoda silinen kaynak dosyalar canlıda kalır ve derlemeyi bozabilir (30.09.2026
   dağıtımında 11 eski frontend sayfası canlıda kalmıştı ve elle silindi).
   Her dağıtımdan sonra, yerel depoda ve dağıtımdan **önce** hedefte okunan eski
   damgayla (`cat <hedef>/.deployed-commit`; yedeğin `PREVIOUS-STAMP` dosyasında da
   bulunur):

   ```bash
   git diff --name-only --diff-filter=D <önceki-damga> <yeni-sha>
   ```

   Çıktı listelenir, kullanıcıya gösterilir, onaydan sonra hedefteki karşılıkları
   kalıcı silme yerine tarihli bir yedek dizinine taşınır (`backups/` bileşeni aracın
   sert-yasak listesindedir, araç ona dokunmaz). Kalıcı silme ayrı açık yetkidir.
   Lisans frontend derlemesi bu adımdan sonra yapılır.
2. **Caddyfile tek dosya bind-mount'tur** (`update-server/docker-compose.yml:25`
   `${CADDYFILE:-./Caddyfile}:/etc/caddy/Caddyfile:ro`). Araç dosyayı `mv -T` ile
   yeni inode olarak değiştirir; kapsayıcı eski inode'u görmeye devam ettiği için
   `caddy reload` "config unchanged" der ve değişiklik uygulanmış görünür ama
   uygulanmamıştır. `update-server/Caddyfile` (ya da `Caddyfile.public`) değiştiyse:
   önce `caddy validate`, sonra `docker restart update-server-caddy-1` (ayrı onay;
   kısa kesinti). Yeniden başlatma sonrası public kanal URL'leri ve registry
   salt-okunur kuralı (yazma 403) yeniden doğrulanır.
3. **Windows'tan çalıştırma kalıbı** (PowerShell; SSH ve `git fetch` etkileşimsiz
   olmalı, Git Bash yolu kullanılır):

   ```powershell
   & "C:\Program Files\Git\bin\bash.exe" -c "export GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never; cd /e/projects/neosecra-distribution && bash scripts/deploy-live.sh --profile distribution --ref <sha> --target <user@host:/opt/neosecra/distribution> --identity <anahtar-yolu>"
   # Lisans: --profile lisans --repo /e/projects/neosecra-lisans --ref <sha> --target <user@host:/opt/neosecra/lisans>
   # Uygulamak için aynı komuta --apply eklenir (önce dry-run çıktısı onaylanır).
   ```

   Yerel doğrulama toplu blob OID, SHA-256, boyut ve mod kontrolleri kullanır;
   dosya başına araç süreci başlatmaz. 350–352 küçük dosyada Windows Git Bash
   hedefi 30 saniyenin altı, kabul sınırı 60 saniyenin altıdır (disk/dosya
   büyüklüğüne bağlıdır). Uzun aşamaların başlangıç/bitişi stderr'e yazılır;
   stdout plan biçimi korunur. CI süre testi, yavaş ortam payıyla 90 saniye sınırını
   kullanır. Uzak plan/yedek/staging/rollback kontrolleri de topludur; dry-run
   hedefte geçici dosya veya kilit oluşturmaz.

   D10 ölçümü (02.10.2026, Windows Git Bash, `lisans`): aynı sentetik commit ve
   boş geçici hedefte 350 küçük dosyanın dry-run süresi **438,8 sn → 22,5 sn**;
   yeni yerel doğrulama **11 sn**. Eski betik `a1a7ccf` HEAD'inden `git show`
   ile alındı; yeni betik çalışma ağacından çalıştırıldı. Testlerdeki yerel SSH
   vekili kullanıldı, ağ bağlantısı yapılmadı ve hedef ağacı iki koşuda da değişmedi.
4. **Lisans dağıtımı dosya aktarımıyla bitmez.** Kök `docker-compose.yml` araç
   tarafından aktarılmaz ve reddedilir (geliştirme dosyasıdır). Canlıdaki kök
   `docker-compose.yml`, `license-server/deployment/compose/docker-compose.prod.yml`
   dosyasının kopyasıdır ve elle kopyalanır (ayrı onay; önce hedefte mevcut dosyanın
   tarihli yedeği, sonra `diff`). Lisans hedef yolu `/opt/neosecra/lisans` biçimindedir
   (yolun son bileşeni `lisans`); canlı hostun gerçek yolu DOĞRULANACAK.

### Lisans dağıtımı sonrası sunucuda yapılacaklar (sıralı, her adım ayrı onay)

Önkoşul: dağıtım yalnız temiz, push edilmiş commit'ten (`--apply`); DB yedeği ve izole
restore kanıtı (migration varsa); `.env` değerleri rapora/loga yazılmaz. Gereken
ortam değişkeni **adları** (`docker-compose.prod.yml:27-33,59-74,101-104,122`):
`BACKEND_IMAGE`, `FRONTEND_IMAGE`, `SIGNER_IMAGE` (değişmez, digest'li referans:
`ad@sha256:<64 hex>`; compose boşsa başlamaz), `MFA_ENCRYPTION_KEY`,
`SIGNER_SHARED_SECRET` (en az 32 bayt), `SIGNING_PUBLIC_KEY_PIN` (opsiyonel; signer
public key'inin base64'ü ya da SHA-256 parmak izi).

1. Migration (yalnız backend imajı yeni koddan derlendikten sonra):

   ```bash
   docker compose run --rm --no-deps -e PYTHONPATH=/app backend alembic upgrade head
   ```

   Sonuç `alembic current` ile doğrulanır (canlı son kayıt: `009_ui_support`).
   Migration apply ayrı açık yetkidir; geri dönüş için önceki imaj digest'i ve DB
   yedeği kayıtlı olmalıdır (migration geri alınmaz).
2. İmajlar sunucuda, dağıtılan ağaçtan derlenir (Dockerfile'lar):
   `license-server/backend/Dockerfile.prod`, `license-server/signer/Dockerfile`,
   `license-server/frontend/Dockerfile.prod` (`docker build -f <Dockerfile> <bağlam>`;
   bağlam Dockerfile'ın `COPY` yollarına göre servis klasörüdür). Derleme sonrası
   compose'un istediği digest'li referansın nasıl üretildiği/kaydedildiği
   DOĞRULANACAK (yerel `docker build` tek başına registry digest'i üretmez).
3. Servisler yeniden oluşturulur; **backend ve signer birlikte** (backend↔signer
   istek kimliği HMAC protokolüdür, sürüm uyumsuzluğu imzalamayı bozar):

   ```bash
   docker compose up -d --force-recreate --no-deps backend signer frontend
   ```

   Postgres yeniden oluşturulmaz (`--no-deps`).
4. Doğrulama: `docker compose ps` (dört servis sağlıklı), `alembic current`, frontend
   derlemesi (eski dosyalar adım 1'deki gibi kaldırıldıktan sonra), imzalı CRL'in public
   `LIC-*` kimliğiyle yayında olduğu ve `license-status` uç noktasının imzalı cevap
   verdiği (secret basmadan) kaydı. Bu smoke kaydı, ürünlerin `block_updates`'i açması
   için ön koşuldur (`shared-guides/PRODUCT-INTEGRATION-PROCEDURE.md` §4.8).

### Distribution dağıtımı sonrası kısa liste

Dry-run çıktısı onaylanır → `--apply` → silinenler (madde 1) → Caddy/compose/mailer
değiştiyse madde 2 → `bash bin/validate-channels.sh` ve public kanal URL'leri +
`minisign -Vm` doğrulaması (kanallar ve `www` bu araçla taşınmaz; publisher yazar) →
publisher `--dry-run`. Bu araç yayın/kanal güncellemesi yapmaz; imzalı yayın yalnız
`update-server/publish.sh` iledir.

## Yerel doğrulama

```powershell
$env:TEMP="$PWD\.codex-tmp"; $env:TMP=$env:TEMP
New-Item -ItemType Directory -Force .codex-tmp | Out-Null
.\.codex-python\python.exe -m pytest tests/test_deploy_live.py tests/test_deploy_live_real.py -q -p no:cacheprovider --basetemp=.codex-tmp\pt-D10
& 'C:\Program Files\Git\bin\bash.exe' -n scripts/deploy-live.sh
```

İlk test dosyası SSH argüman/akış sözleşmesini kaydeden sahte SSH kullanır. İkinci
dosya gerçek uzak komutu geçici hedefte `bash -c` ile çalıştıran yerel SSH vekili
kullanır. Ağ kullanılmaz; test origin'leri yerel bare depolardır. Windows symlink
yetkisi veya Git Bash/NTFS POSIX mod desteği yoksa ilgili test gerekçeli skip olur;
bu kontroller Ubuntu üzerinde ayrıca çalıştırılmalıdır. Canlı kabul bu paketle yapılmaz.
