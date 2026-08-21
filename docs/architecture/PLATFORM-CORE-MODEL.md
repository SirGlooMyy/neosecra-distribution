# NeoSecra Platform Mimarisi — Ortak Çekirdek + Ayrı Domain'ler

> Karar tarihi: 2026-08-06 (kullanıcı direktifi, verbatim)
> Kapsam: NeoSecra Assessment + NeoSecra SOC + gelecek ürünler (PISH, hotspot)

## Net mimari karar

**NeoSecra Platform Core** → kimlik, tenant, lisans, secret, audit, notification, contract ve UI altyapısı
**NeoSecra Assessment** → posture, finding, scoring, remediation ve revalidation
**NeoSecra SOC** → event, detection, alert, incident, investigation ve response

SOC ve Assessment'ın ortak modülleri olacak; ama **ortak veritabanı ve ortak domain OLMAYACAK**.
Model: Ortak platform servisleri + ortak sözleşmeler + ortak UI/SDK paketleri. Assessment domain'i ayrı, SOC domain'i ayrı.

## 1. Ortak platform modülleri (güvenlik işi YAPMAZLAR)

| Ortak modül | Sorumluluk |
|---|---|
| Identity & Authentication | Kullanıcı, giriş, MFA, SSO, session |
| Tenant & Customer Directory | Müşteri kimliği, tenant ID, site referansları |
| RBAC Foundation | Ortak rol ve permission altyapısı |
| Licensing | Ürün, modül, tenant ve özellik lisansları |
| Asset Identity Registry | Aynı cihazın iki üründe aynı asset_id ile tanınması |
| Secret Management | Token, API key, certificate ve credential şifreleme |
| Audit Foundation | Standart audit formatı |
| Notification Gateway | E-posta, Teams, Telegram, webhook taşıma katmanı |
| Integration SDK | Retry, pagination, rate limit, redaction, health check |
| AI Gateway Client | Model routing, timeout, audit, structured-output |
| Design System | React bileşenleri, renkler, tablolar, form, layout |
| Update & Licensing Agent | Sürüm kontrolü, lisans doğrulama, paket doğrulama |
| Common Contracts | Tenant, Site, Asset, Identity, Observation, Alert referansları |

## 2. Ortak kimlik sözleşmeleri

tenant_id, customer_id, site_id, asset_id, identity_id, integration_id, correlation_id.
İki ürün aynı müşteriyi/cihazı farklı kimlikle tutmamalı — ama bu **aynı DB tablosunu paylaşmak demek değil**: Ortak Asset Contract ↓ Assessment kendi asset projection'ını tutar, SOC kendi asset projection'ını tutar. `external_references` ile çapraz referans (assessment_asset_id / soc_asset_id).

## 3. Ortak connector altyapısı

Low-level SDK ortak: HTTP client, auth header, secret redaction, pagination, retry/backoff, 429, timeout, TLS, API version registry, correlation ID, capability discovery, connection health.
**Collector ve iş mantığı ayrılır.** Örnek TVO: client ortak; Assessment posture/config kullanır, SOC workbench/alert operasyonu kullanır. Assessment KESİNLİKLE response action (isolate/terminate/status change) çalıştırmaz; SOC'ta bunlar approval + SOAR güvenlik kapılarından geçer.

## 4. Ortak event sözleşmeleri

Assessment SOC DB'sine DOĞRUDAN YAZMAZ — event yayınlar: SECURITY_OBSERVATION_CREATED/UPDATED/RESOLVED, ASSET_POSTURE_CHANGED, RISK_ACCEPTED, REMEDIATION_VERIFIED (event_version'lı şema). SOC bunu alert olarak değil **risk bağlamı** olarak tüketir. SOC tarafı: SOC_ALERT_CREATED. Correlation: Açık Assessment riski + aktif SOC alarmı = **Active Exposure**.

## 5. Ortak audit şeması

Aynı format (actor_id, tenant_id, product, action, entity_type, entity_id, timestamp, correlation_id). Altyapı ortak; kayıtların DB'leri ve retention'ları ayrı.

## 6. Ortak notification gateway

Motor ortak (template rendering, provider credentials, retry, rate limit, delivery tracking, dead-letter, redaction, tenant branding); event ve template domain'i ayrı.

## 7. Ortak rapor altyapısı

Ortak: design system, header/footer, gizlilik etiketi, tenant branding, PDF renderer abstraction, Türkçe font, tablo/grafik bileşenleri, snapshot integrity validator framework. Ayrı: report snapshot ve hesaplama domain'i (Assessment: posture/risk/findings; SOC: alerts/incidents/SLA).

## 8. Ortak AI gateway, ayrı ajanlar

Tek gateway (LiteLLM/OpenAI-compatible: routing, quota, prompt audit, timeout, fallback, JSON validation, PII filtering, tenant isolation). Ajanlar ayrı (Assessment: finding explanation/remediation draft/control mapping/report narrative; SOC: alert summary/timeline/hypothesis/MITRE/notification draft). Assessment prompt'una incident verisi, SOC prompt'una ham credential GİRMEZ.

## 9. KESİNLİKLE ortak olmayacaklar

- Database, migration zinciri, worker queue, scheduler, deployment, release version, domain modelleri, report snapshot, status enum'ları
- Assessment'a ait: scan orchestration, config/posture assessment'lar (FGT/AD/M365/Trend), OpenVAS lifecycle, finding rule engine, posture scoring, remediation registry, ReportSnapshot, revalidation, coverage issues, risk acceptance
- SOC'a ait: log/event ingestion, log detection, alert correlation, alert ingestion, workbench operasyonu, enrichment, detection evaluator, alert/incident severity, SOAR playbooks, incident evidence/timeline/closure, collector health, alert suppression

## 10. Paket yapısı

```
neosecra-platform/
├── auth-contracts, tenant-contracts, asset-contracts, event-contracts
├── licensing-client, secret-sdk, audit-sdk, notification-sdk
├── integration-sdk, ai-gateway-client, ui-kit, report-ui-kit

neosecra-assessment/  → assessment-api, workers, db, rules, frontend
neosecra-soc/         → soc-api, workers, db, detection/correlation/incident/soar-engine, frontend
```

## 11. Paylaşım seviyeleri

- **Merkezi servis**: Identity/SSO, Licensing, Tenant directory, Notification gateway, AI gateway
- **Versiyonlu paket**: Contracts, Integration SDK, Secret/redaction utils, Audit schema, UI kit, Report components
- **Yalnız sözleşmeyle senkron**: Asset, Identity, SecurityObservation, Alert/Incident reference, Risk materialization

Vendor client altyapısı (FGT/M365/TVO) ortaklaştırılabilir; collector'lar, izin kapsamları, veriler ve kurallar ayrı kalır — tekrar azalır, monolite dönülmez.
