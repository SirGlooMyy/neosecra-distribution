#!/usr/bin/env bash
# Docker-specific helpers for the NeoSecra Assessment deployment.
# Source after common.sh
set -Euo pipefail

# Registry erisim kontrolu — artik GHCR degil kendi registry'miz (registry.neosecra.com).
# Token/login GEREKMEZ: registry Tailscale/LAN ici acik, TLS custom CA ile.
# Fonksiyon adi geriye donuk uyumluluk icin korunuyor (install.sh/upgrade.sh cagiriyor).
ghcr_login() {
  local release_ver
  release_ver=$(tr -d ' 
' < "${V1_ROOT}/VERSION" 2>/dev/null || true)
  local ref="registry.neosecra.com/security-health-backend:${release_ver:-latest}"
  if docker manifest inspect "$ref" >/dev/null 2>&1; then
    ok "NeoSecra registry erisilebilir (registry.neosecra.com)"
    return 0
  fi
  # manifest inspect auth'suz calismazsa /v2/ ping dene
  if curl -fsS --max-time 10 "https://registry.neosecra.com/v2/" >/dev/null 2>&1; then
    ok "NeoSecra registry API erisilebilir (v2 ping)"
    return 0
  fi
  die "registry.neosecra.com erisilemiyor — /etc/hosts kaydi ve CA sertifikasi kurulumunu kontrol edin (bootstrap.sh internal mod)" 4
}

pull_service_image() {
  local service="$1"
  log "Pulling image for service: ${service}"
  run_compose pull "$service" || die "Failed to pull image for service: ${service}" 3
  ok "Pulled image for service: ${service}"
}

# Get image digest
image_digest() {
  local ref="$1"
  docker inspect "$ref" --format '{{.RepoDigests}}' 2>/dev/null | grep -oP 'sha256:\w+' || echo "unknown"
}

# Validate compose config
compose_validate() {
  run_compose config -q
  ok "Compose config valid"
}

# Wait for a service healthcheck
wait_service_running() {
  local service="$1" timeout="${2:-60}"
  log "Waiting for ${service} (timeout ${timeout}s)..."
  for _ in $(seq 1 "$timeout"); do
    run_compose ps --status running -q "$service" 2>/dev/null | grep -q . && return 0
    sleep 1
  done
  die "${service} not ready within ${timeout}s" 3
}

wait_service_healthy() {
  local service="$1" timeout="${2:-90}" cid status
  log "Waiting for ${service} healthcheck (timeout ${timeout}s)..."
  for _ in $(seq 1 "$timeout"); do
    cid="$(run_compose ps -q "$service" 2>/dev/null || true)"
    if [[ -n "$cid" ]]; then
      status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$cid" 2>/dev/null || true)"
      [[ "$status" == "healthy" || "$status" == "running" ]] && { ok "${service} healthy"; return 0; }
    fi
    sleep 1
  done
  die "${service} not healthy within ${timeout}s" 3
}
