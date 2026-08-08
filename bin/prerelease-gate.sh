#!/usr/bin/env bash
# prerelease-gate.sh — clean-VM install validation (task #8)
#
# Yayın öncesi gate: hedef temiz bir VM'e PUBLISH EDİLMİŞ bootstrap.sh'i SSH
# üzerinden çalıştırır, kurulum sonrası aşağıdaki maddeleri PASS/FAIL olarak
# doğrular ve herhangi bir FAIL'de exit 1 döner:
#
#   (a) 7 container ayakta (backend frontend worker beat openvas postgres redis)
#   (b) .env.v1'de LICENSE_PUBLIC_KEY_B64 + UPGRADE_CHANNEL_* +
#       FIRST_ADMIN_EMAIL=admin@neosecra.com
#   (c) backend /app/ca'da 2 dosya
#   (d) BACKEND_PORT /api/v1/health -> 200
#   (e) version uç noktasında commit != UNKNOWN
#   (f) admin girişi çalışır (kimlik bilgileri hedefin .env.v1'inden okunur)
#   (g) /api/v1/openvas/readiness -> 200
#   (h) backend log'larında 'Channel fetch failed' yok
#   (i) PG* env değişkenleri mevcut VEYA pg_dump aşaması çalışır
#
# Kimlik bilgileri burada ASLA hardcode edilmez; hedef makinenin
# /opt/neosecra/assessment/current/.env.v1 dosyasından okunur.
set -Eeuo pipefail

usage() {
  cat <<'EOF'
prerelease-gate.sh — clean-VM yayın öncesi kurulum doğrulama

Kullanım:
  prerelease-gate.sh --host <user@host> [--dry-run] [--skip-install]
  prerelease-gate.sh <user@host> [--dry-run] [--skip-install]
  prerelease-gate.sh --help

Seçenekler:
  --host <user@host>   Hedef temiz VM (root SSH erişimi gerekir)
  --dry-run            SSH çalıştırmaz; komutları ve kontrol listesini basar
  --skip-install       Bootstrap'i atla; sadece mevcut kurulumu doğrula
  --help               Bu yardımı göster

Ortam değişkenleri (opsiyonel):
  PRERELEASE_BOOTSTRAP_URL    Yayınlanmış bootstrap adresi (varsayılan:
                              https://update.neosecra.com/bootstrap.sh)
  PRERELEASE_TLS_MODE         public|internal (varsayılan: public)
  PRERELEASE_VERSION_ENDPOINT Version uç noktası (varsayılan: /api/v1/version)
EOF
}

TARGET=""
DRY_RUN=0
SKIP_INSTALL=0
BOOTSTRAP_URL="${PRERELEASE_BOOTSTRAP_URL:-https://update.neosecra.com/bootstrap.sh}"
TLS_MODE="${PRERELEASE_TLS_MODE:-public}"
VERSION_ENDPOINT="${PRERELEASE_VERSION_ENDPOINT:-/api/v1/version}"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=30 -o ServerAliveCountMax=200)

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)        usage; exit 0 ;;
    --host)           shift; TARGET="${1:-}" ;;
    --dry-run)        DRY_RUN=1 ;;
    --skip-install)   SKIP_INSTALL=1 ;;
    --*)              echo "Beklenmeyen argüman: $1" >&2; usage; exit 2 ;;
    *)                TARGET="$1" ;;
  esac
  shift
done

[[ -n "$TARGET" ]] || { echo "Hata: --host <user@host> gerekli" >&2; usage; exit 2; }
case "$TLS_MODE" in
  public|internal) ;;
  *) echo "Hata: PRERELEASE_TLS_MODE public|internal olmalı" >&2; exit 2 ;;
esac
command -v ssh >/dev/null 2>&1 || { echo "Hata: ssh bulunamadı" >&2; exit 2; }

install_bootstrap() {
  if [[ $SKIP_INSTALL -eq 1 ]]; then
    echo "[skip-install] bootstrap atlanıyor, sadece doğrulama yapılacak" >&2
    return 0
  fi
  local cmd="curl -fsSL '${BOOTSTRAP_URL}' | sudo NEOSECRA_TLS_MODE='${TLS_MODE}' bash"
  echo "== Bootstrap install (${TARGET}) ==" >&2
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "[dry-run] ssh ${TARGET} \"${cmd}\"" >&2
    return 0
  fi
  ssh "${SSH_OPTS[@]}" "$TARGET" "$cmd"
}

parse_and_report() {
  # stdin: PRERELEASE_GATE|PASS|name|detail  satırları
  local line status name detail pass_count=0 fail_count=0
  while IFS= read -r line; do
    [[ "$line" == PRERELEASE_GATE\|* ]] || continue
    IFS='|' read -r _ status name detail <<< "$line"
    if [[ "$status" == "PASS" ]]; then
      printf 'PASS  %-28s %s\n' "$name" "$detail"
      pass_count=$((pass_count + 1))
    else
      printf 'FAIL  %-28s %s\n' "$name" "$detail"
      fail_count=$((fail_count + 1))
    fi
  done
  echo ""
  echo "== Özet =="
  if [[ $pass_count -eq 0 && $fail_count -eq 0 ]]; then
    echo "PRERELEASE GATE FAILED — hedefte doğrulama çıktısı alınamadı (SSH/bağlantı hatası?)"
    return 1
  fi
  if [[ $fail_count -eq 0 ]]; then
    echo "PRERELEASE GATE PASSED (${pass_count} PASS, 0 FAIL)"
    return 0
  else
    echo "PRERELEASE GATE FAILED (${pass_count} PASS, ${fail_count} FAIL)"
    return 1
  fi
}

run_checks() {
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "== Doğrulama kontrol listesi (${TARGET}) ==" >&2
    for item in \
      "containers: 7 container ayakta (backend frontend worker beat openvas postgres redis)" \
      "env: LICENSE_PUBLIC_KEY_B64 + UPGRADE_CHANNEL_* + FIRST_ADMIN_EMAIL=admin@neosecra.com" \
      "backend-ca: /app/ca'da 2 dosya" \
      "health: BACKEND_PORT /api/v1/health -> 200" \
      "version-commit: commit != UNKNOWN (${VERSION_ENDPOINT})" \
      "login: FIRST_ADMIN_EMAIL / FIRST_ADMIN_PASSWORD (.env.v1'den) ile giriş" \
      "openvas-readiness: /api/v1/openvas/readiness -> 200" \
      "logs: backend log'larında 'Channel fetch failed' yok" \
      "pg-dump: PG* env mevcut VEYA pg_dump çalışıyor"; do
      echo "  - ${item}" >&2
    done
    echo "Exit 0 (dry-run tamam)." >&2
    return 0
  fi

  # shellcheck disable=SC2029
  ssh "${SSH_OPTS[@]}" "$TARGET" \
    "PRERELEASE_VERSION_ENDPOINT='${VERSION_ENDPOINT}' bash -s" <<'REMOTE' | parse_and_report
set -Eeuo pipefail

ENV_FILE=/opt/neosecra/assessment/current/.env.v1
COMPOSE_DIR=/opt/neosecra/assessment/current
[[ -f "$ENV_FILE" ]] || { echo "PRERELEASE_GATE|FAIL|install|current .env.v1 missing"; exit 1; }
cd "$COMPOSE_DIR"

env_val() { grep -E "^$1=" "$ENV_FILE" 2>/dev/null | tail -n1 | cut -d= -f2- || true; }

BACKEND_PORT="$(env_val BACKEND_PORT)"; BACKEND_PORT="${BACKEND_PORT:-23800}"
BASE="http://127.0.0.1:${BACKEND_PORT}"
ADMIN_EMAIL="$(env_val FIRST_ADMIN_EMAIL)"
ADMIN_PASSWORD="$(env_val FIRST_ADMIN_PASSWORD)"
VERSION_ENDPOINT="${PRERELEASE_VERSION_ENDPOINT:-/api/v1/version}"

COMPOSE=(docker compose --profile openvas -f docker-compose.v1.yml --env-file .env.v1)

# (a) 7 container ayakta
running="$("${COMPOSE[@]}" ps --status running --format '{{.Service}}' 2>/dev/null || true)"
for svc in backend frontend worker beat openvas postgres redis; do
  if grep -qx "$svc" <<< "$running" 2>/dev/null; then
    echo "PRERELEASE_GATE|PASS|containers:$svc|running"
  else
    echo "PRERELEASE_GATE|FAIL|containers:$svc|not running"
  fi
done

# (b) .env.v1 gerekli anahtarlar
for key in LICENSE_PUBLIC_KEY_B64 UPGRADE_CHANNEL_URL UPGRADE_CHANNEL_CA_BUNDLE UPGRADE_CHANNEL_PUBLIC_KEY; do
  if [[ -n "$(env_val "$key")" ]]; then
    echo "PRERELEASE_GATE|PASS|env:$key|present"
  else
    echo "PRERELEASE_GATE|FAIL|env:$key|missing"
  fi
done
if [[ "$ADMIN_EMAIL" == "admin@neosecra.com" ]]; then
  echo "PRERELEASE_GATE|PASS|env:FIRST_ADMIN_EMAIL|admin@neosecra.com"
else
  echo "PRERELEASE_GATE|FAIL|env:FIRST_ADMIN_EMAIL|got '${ADMIN_EMAIL}'"
fi

# (c) backend /app/ca 2 dosya
ca_files="$("${COMPOSE[@]}" exec -T backend sh -c 'ls -1 /app/ca 2>/dev/null | wc -l' 2>/dev/null || true)"
if [[ "${ca_files:-0}" == "2" ]]; then
  echo "PRERELEASE_GATE|PASS|backend-ca|2 files in /app/ca"
else
  echo "PRERELEASE_GATE|FAIL|backend-ca|expected 2 files, got ${ca_files:-0}"
fi

# (d) health 200
health_code="$(curl -s --max-time 10 -o /dev/null -w '%{http_code}' "${BASE}/api/v1/health" 2>/dev/null || true)"
if [[ "$health_code" == "200" ]]; then
  echo "PRERELEASE_GATE|PASS|health|HTTP ${health_code}"
else
  echo "PRERELEASE_GATE|FAIL|health|HTTP ${health_code:-?}"
fi

# (e) version commit NOT UNKNOWN
version_body="$(curl -s --max-time 10 "${BASE}${VERSION_ENDPOINT}" 2>/dev/null || true)"
commit="$(printf '%s' "$version_body" | grep -oiE '"(commit|git_commit|build_commit|revision)"[[:space:]]*:[[:space:]]*"[^"]*"' 2>/dev/null | head -n1 | sed -E 's/.*":[[:space:]]*"([^"]*)".*/\1/' || true)"
if [[ -n "$commit" && "${commit^^}" != "UNKNOWN" ]]; then
  echo "PRERELEASE_GATE|PASS|version-commit|${commit}"
else
  echo "PRERELEASE_GATE|FAIL|version-commit|commit missing or UNKNOWN"
fi

# (f) admin girişi (kimlik bilgileri .env.v1'den)
json_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
login_tmp="$(mktemp)"
login_code="$(curl -s --max-time 15 -o "$login_tmp" -w '%{http_code}' \
  -H 'Content-Type: application/json' \
  --data-binary "{\"email\":\"$(json_escape "$ADMIN_EMAIL")\",\"password\":\"$(json_escape "$ADMIN_PASSWORD")\"}" \
  "${BASE}/api/v1/auth/login" 2>/dev/null || true)"
if [[ "$login_code" == "200" ]] && grep -q '"access_token"' "$login_tmp" 2>/dev/null; then
  echo "PRERELEASE_GATE|PASS|login|HTTP 200 + access_token (${ADMIN_EMAIL})"
else
  echo "PRERELEASE_GATE|FAIL|login|HTTP ${login_code:-?}"
fi
rm -f "$login_tmp"

# (g) openvas readiness 200
readiness_code="$(curl -s --max-time 15 -o /dev/null -w '%{http_code}' "${BASE}/api/v1/openvas/readiness" 2>/dev/null || true)"
if [[ "$readiness_code" == "200" ]]; then
  echo "PRERELEASE_GATE|PASS|openvas-readiness|HTTP ${readiness_code}"
else
  echo "PRERELEASE_GATE|FAIL|openvas-readiness|HTTP ${readiness_code:-?}"
fi

# (h) backend log'larında 'Channel fetch failed' yok
fetch_failed="$("${COMPOSE[@]}" logs --tail=500 backend 2>/dev/null | grep -c 'Channel fetch failed' || true)"
if [[ "${fetch_failed:-0}" -eq 0 ]]; then
  echo "PRERELEASE_GATE|PASS|logs|no 'Channel fetch failed' (count 0)"
else
  echo "PRERELEASE_GATE|FAIL|logs|'Channel fetch failed' seen ${fetch_failed} times"
fi

# (i) PG* env mevcut VEYA pg_dump çalışıyor
pg_ok=1
for key in POSTGRES_USER POSTGRES_PASSWORD POSTGRES_DB DATABASE_URL; do
  if [[ -z "$(env_val "$key")" ]]; then pg_ok=0; break; fi
done
if [[ $pg_ok -eq 1 ]]; then
  echo "PRERELEASE_GATE|PASS|pg-dump|PG* env present in .env.v1"
elif "${COMPOSE[@]}" exec -T postgres pg_dump -U "$(env_val POSTGRES_USER)" -d "$(env_val POSTGRES_DB)" >/dev/null 2>&1; then
  echo "PRERELEASE_GATE|PASS|pg-dump|pg_dump stage works"
else
  echo "PRERELEASE_GATE|FAIL|pg-dump|PG* env missing and pg_dump failed"
fi
REMOTE
}

install_bootstrap
run_checks
