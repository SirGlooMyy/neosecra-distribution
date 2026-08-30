## Mandatory Global NeoSecra Platform Contract

## Mandatory Stateless Cold Start

Every task starts with zero conversation history. Never rely on a previous session, resume capability, prior chat context or model memory.

Before processing the user request:

1. Read `/home/sirgloomy/AGENTS.md`.
2. Read `/home/sirgloomy/.codex/memory/neosecra-platform/00-PLATFORM-INDEX.md`.
3. Read this repository's `AGENTS.md`.
4. Read `.ai-ops/current-checkpoint.md`.
5. Determine the current branch, HEAD and dirty state.
6. Compare current HEAD with the reviewed HEAD in global memory.
7. Select the relevant NeoSecra skill.
8. Load only memory files required by that skill.
9. Inspect actual code before making implementation claims.
10. Continue the user's task without asking them to repeat prior project context.

At task completion, update the repository checkpoint so the next stateless task can continue from disk.

---

Before working in this repository, read and follow:

`/home/sirgloomy/AGENTS.md`

This repository is one module or infrastructure component of the NeoSecra
platform. The global file defines shared platform, authorization, security,
tenant, evidence, GUI, reporting, licensing, distribution, memory, skill,
testing and deployment rules.

The repository-specific rules below refine the global contract for this module.
They must not be used to reject an explicit user instruction that is allowed by
the global precedence rules.

---

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
- `deployment/upgrade/upgrade.sh` — canlı upgrade (pg_dump backup, alembic, journal, current symlink). Hedef release, current ağaçtan KOPYALANMAZ (bug #21): `prepare_target_release` channel JSON'daki release entry'sinden `distribution-<ver>.tar.gz`'yi indirir, sha256 + minisig doğrular, staging'e açıp atomik `mv` ile `releases/<target>`'a kurar; yalnızca `.env.v1` + `config/tls` eski ağaçtan taşınır. Doğrulama hatasında current symlink/container'lara DOKUNULMADAN abort (fail closed). Aynı mantık `deployment/v1/upgrade/upgrade.sh` (agent yolu) içinde de var — ikisini senkron tut.
- `deployment/v1/` — müşteriye GİDEN ağaç; shipped source of truth BU repo'dur (assessment repo'daki kopya development'tır, müşteriye giden değişiklikler buraya portlanır)
- `deployment/v1/agent/` — update-agent köprüsü (systemd path unit + heartbeat timer). Yeni kurulumlarda varsayılan AÇIK: install.sh, `NEOSECRA_INSTALL_UPDATE_AGENT=1` (default) ile `agent/install-agent.sh`'i çağırır; idempotent'tır. Journal sözleşmesi: upgrade.sh/rollback.sh `${INSTALL_ROOT}/upgrade-journal/` altına yazar; agent her koşu sonrası üretilen `upgrade-*.json`/`rollback-*.json` dosyalarını bridge journal dizinine (`state/upgrade-bridge/journal/`) kopyalar — backend bu dizini `/upgrade-bridge/journal` mount'uyla okur.
- `update-server/` — Caddy (Caddyfile=internal custom CA, Caddyfile.public=Let's Encrypt), publish.sh, channels/
- `channels/assessment-stable.json` — nested schema + minisign imzalı; schema'yı bozma. Release entry'lerinde `docker_bundle.url` yanında top-level `bundle_url` da bulunur (eski backend'lerle backward compat; publish.sh ikisini de yazar).
- `scripts/make-customer-package.sh` — müşteri paketi üretici
