# NeoSecra Product & Version Compatibility Matrix

**Platform Version Line:** `1.x`  
**Standard Updated:** 2026-08-30

| Ürün / Servis | Uyumlu Versiyon Aralığı | Veritabanı Gereksinimi | Redis Gereksinimi | Lisans Sözleşmesi | Event Sözleşmesi |
|---|---|---|---|---|---|
| **Assessment** | `1.3.0` – `1.3.53` | PostgreSQL 15 / 16 | Redis 7+ | `ed25519_v1` (`assessment.*`) | `SecurityObservation` v1 |
| **SOC** | `1.0.0` (Target) | PostgreSQL 16 (Forced RLS) | Redis 7+ | `ed25519_v1` (`soc.*`) | `SecurityObservation` v1 |
| **Hotspot** | `0.3.0` – `0.3.6` | PostgreSQL 16 | Redis 7+ | `ed25519_v1` (`hotspot.core`) | 5651 Legal WORM v1 |
| **Phishing** | `1.0.0` (Target) | PostgreSQL 16 | Redis 7+ | `ed25519_v1` (`phishing.core`) | `UserRiskEvent` v1 |
| **License Authority** | `1.0.0` | PostgreSQL 16 | N/A | Canonical Signer | Entitlement Authority |
