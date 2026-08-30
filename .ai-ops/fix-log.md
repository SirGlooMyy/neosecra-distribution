# neosecra-distribution — Fix Log

- **2026-08-30 (DIST-FOUNDATION-001-CORRECTION):**
  - **P0 Fix:** `artifact-verifier.sh` içindeki `verify_image_attestation` fonksiyonunun eksik cosign/key durumunda 0 dönmesi (fail-open) giderildi; `verify_image_signature` ve `verify_image_attestation` ayrı fail-closed fonksiyonlar haline getirildi.
  - **SBOM Fix:** `verify_sbom_integrity` fonksiyonuna SPDX (`spdxVersion`) ve CycloneDX (`bomFormat`, `specVersion`) yapısal JSON doğrulama mantığı eklendi.
  - **Drift Fix:** `deployment/lib/artifact-verifier.sh` ve `deployment/v1/agent/artifact-verifier.sh` eşitlendi; `test_verifier_copies_are_byte_identical` testi eklendi.
  - **Schema & Test Fix:** `platform-release-manifest.schema.json` içine RFC 4122 strict UUID pattern'i, URI formatı ve `additionalProperties: false` eklendi. Test yolları dinamik repo root'una bağlandı.
  - **Test Kapsamı:** 24 adet fail-closed ve negatif test eklendi ve %100 doğrulandı (`24 passed`).
