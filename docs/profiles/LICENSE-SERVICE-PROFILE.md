# NeoSecra License Service — Deployment & Update Profile

**Canonical Repository:** `/home/sirgloomy/projects/neosecra-lisans`  
**Host Target:** `10.34.99.13` (:8080, :5174, :9446)  
**Database:** PostgreSQL 16 (`neosecra_license` / user: `neosecra`)  
**Status:** `IMPLEMENTED_LAB_VERIFIED`

---

## 1. Servis İzolasyonu ve Mimari Sınırları

- **Private Signing Key İzolasyonu:** Ed25519 özel imzalama anahtarı (`signer/private.key`) hiçbir zaman lisans servis sınırının dışına çıkmaz.
- **Dağıtım Mimarisi:**
  - `lisans-backend`: FastAPI tabanlı lisans yönetim ve imzalama API'si (:8080).
  - `lisans-db`: Dedicated PostgreSQL 16 veritabanı container'ı.
  - `lisans-frontend`: Vite/React tabanlı yönetim konsolu (:5174).
  - `update-server-caddy`: Caddy TLS reverse proxy.

---

## 2. Pre-Migration Yedekleme & Kurtarma (Fail-Closed)

Lisans servisine yönelik her migration veya versiyon yükseltme öncesinde:
1. `docker exec lisans-db-1 pg_dump -U neosecra -d neosecra_license -F c -f /var/backups/license-pre-migration-$(date +%s).dump`
2. Migration offline SQL incelemesi yapılır (`alembic upgrade --sql`).
3. Sağlık kontrolü: `GET http://localhost:8000/health` -> `{"status":"ok","app":"NeoSecra License Platform"}`.
4. Başarısızlık durumunda veritabanı yedeği izole şekilde geri yüklenir.
