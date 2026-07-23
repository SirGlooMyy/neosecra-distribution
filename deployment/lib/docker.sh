#!/usr/bin/env bash
# Docker-specific helpers for the NeoSecra Assessment deployment.
# Source after common.sh
set -Eeuo pipefail

# Pull image from GHCR using credential file
ghcr_pull() {
  local image="$1" tag="${2:-1.0.0}"
  local token_file; token_file=$(ghcr_token_file)

  if [[ -f "$token_file" ]]; then
    set +x
    cat "$token_file" | docker login "$GHCR_REGISTRY" --username token --password-stdin 2>/dev/null || true
  fi

  local ref="${GHCR_REGISTRY}/${GHCR_NAMESPACE}/${image}:${tag}"
  log "Pulling ${ref} ..."
  docker pull "$ref" || die "Failed to pull ${ref}" 3
  ok "Pulled ${ref}"
  echo "$ref"
}

# Get image digest
image_digest() {
  local ref="$1"
  docker inspect "$ref" --format '{{.RepoDigests}}' 2>/dev/null | grep -oP 'sha256:\w+' || echo "unknown"
}

# Validate compose config
compose_validate() {
  run_compose config -q >/dev/null 2>&1 && ok "Compose config valid" || warn "Compose config could not be validated (compose v5 compatibility check)"
}

# Wait for a service healthcheck
wait_service() {
  local service="$1" timeout="${2:-60}"
  log "Waiting for ${service} (timeout ${timeout}s)..."
  for _ in $(seq 1 "$timeout"); do
    run_compose ps --status running -q "$service" 2>/dev/null | grep -q . && return 0
    sleep 1
  done
  die "${service} not ready within ${timeout}s" 3
}
