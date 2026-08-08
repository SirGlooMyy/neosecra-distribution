# NeoSecra Distribution Channel

Private distribution repository for NeoSecra product releases.

**This repository contains NO source code.** Only release metadata,
channel manifests, schemas, and public verification keys.

## Products

| Product | Edition | Channel |
|---------|---------|---------|
| NeoSecra Assessment | security-health | `assessment-stable`, `assessment-beta` |
| NeoSecra SOC | soc | `soc-stable`, `soc-beta` (future) |

## Repository Structure

```
schemas/          JSON Schemas for release/channel/revocation manifests
channels/         Channel manifests listing available releases
public-keys/      Public verification keys (signing, when implemented)
docs/             Customer updater documentation
```

## Access

- **Source repositories**: No customer access
- **Distribution repository**: Customer `Contents: read` only
- **GHCR packages**: Customer `read:packages` only

See `docs/CUSTOMER-UPDATER-AUTH.md` for credential requirements.

## Release Gate (zorunlu)

**Her yayın, publish edilmeden önce `bin/prerelease-gate.sh` ile temiz bir
VM üzerinde geçmelidir.** Gate, hedef VM'e yayınlanmış `bootstrap.sh`'i SSH ile
çalıştırır ve kurulum sonrası 7 container'ın ayakta olduğunu, `.env.v1`'de
lisans/kanal/admin değerlerinin bulunduğunu, backend health/version/login ve
openvas readiness uç noktalarının doğru yanıt verdiğini, loglarda kanal hatası
olmadığını ve veritabanı yedeklenebilirliğini doğrular. Herhangi bir madde
FAIL dönerse gate exit 1 ile başarısız olur ve publish yapılmamalıdır:

```bash
bin/prerelease-gate.sh --host root@<temiz-vm>        # bootstrap + tüm kontroller
bin/prerelease-gate.sh --host root@<temiz-vm> --dry-run   # komut/kontrol önizleme
```
