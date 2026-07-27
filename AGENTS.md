# NeoSecra Distribution — Worker Kuralları

Bu repo update server, bootstrap ve müşteri kurulum paketlerini içerir.

## Branch & Push
- Aktif branch: `fix/assessment-live-installer` (main ESKİ, kullanma!)
- Push yalnızca görev prompt'unda açıkça istendiyse. Aksi halde commit'le, push'u orkestratör yapar.
- Commit trailer: `Co-Authored-By: Claude <noreply@anthropic.com>`

## Kesin Yasaklar
- `curl -k` / `--insecure` YASAK. TLS doğrulaması her zaman açık; custom CA ile `--cacert` kullanılır.
- Private key, CA key, token, parola COMMIT'LENMEZ. Secret'lar `/opt/neosecra/secrets/` altında yaşar (600 root:root).
- `git reset --hard`, `git clean -fd` YASAK (safety-gate engeller; worktree'yi bozma).

## Doğrulama Zorunluluğu
- Shell script değişikliğinde: `bash -n <dosya>` + varsa `shellcheck` ÇALIŞTIR, çıktıyı raporla.
- bootstrap.sh / upgrade.sh değişikliğinde gerçek akışı bozmadan test et; "çalışır" demek için kanıt göster.
- Dokümandaki her komut, script'lerde GERÇEKTEN var olan flag/argümanla eşleşmeli. Uydurma flag yok.

## Yapı
- `bootstrap.sh` — müşteri kurulum giriş noktası (NEOSECRA_TLS_MODE=public|internal, NEOSECRA_GHCR_USER/TOKEN)
- `deployment/upgrade/upgrade.sh` — canlı upgrade (pg_dump backup, alembic, journal, current symlink)
- `update-server/` — Caddy (Caddyfile=internal custom CA, Caddyfile.public=Let's Encrypt), publish.sh, channels/
- `channels/assessment-stable.json` — nested schema + minisign imzalı; schema'yı bozma
- `scripts/make-customer-package.sh` — müşteri paketi üretici
