#!/usr/bin/env bash
# Docker-specific helpers for the NeoSecra Assessment deployment.
# Source after common.sh
set -Euo pipefail

# Authenticate to GHCR without persisting or echoing the token.
ghcr_login() {
  [[ -r /dev/tty ]] || die "GHCR login requires an interactive terminal for silent token entry" 4

  local ghcr_token
  read -rsp "GHCR read-only token: " ghcr_token </dev/tty
  echo >/dev/tty
  [[ -n "$ghcr_token" ]] || die "GHCR token was empty" 4
  printf '%s' "$ghcr_token" | docker login "$GHCR_REGISTRY" \
    --username SirGlooMyy \
    --password-stdin
  unset ghcr_token
  ok "GHCR authentication passed"
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
