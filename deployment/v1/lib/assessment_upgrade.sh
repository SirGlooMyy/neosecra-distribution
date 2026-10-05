#!/usr/bin/env bash
# Assessment-specific upgrade steps, kept apart from the generic transaction in
# upgrade/upgrade.sh so they can be exercised on their own.  Source after
# common.sh and docker.sh.  Every function is a no-op or the historic behaviour
# for any other product identity.
set -Euo pipefail

# Canonical product of the running installation (same mapping as the agent).
upgrade_product_code() {
  case "$(printf '%s' "${NEOSECRA_PRODUCT:-assessment}" | tr '[:upper:]' '[:lower:]')" in
    assessment|neosecra-security-health|security-health) printf 'assessment' ;;
    *) printf '%s' "$(printf '%s' "${NEOSECRA_PRODUCT:-assessment}" | tr '[:upper:]' '[:lower:]')" ;;
  esac
}
is_assessment_runtime() { [[ "$(upgrade_product_code)" == "assessment" ]]; }

compose_has_service() {
  run_compose config --services 2>/dev/null | tr -d '\r' | grep -qx -- "$1"
}

# Switch every application service to the new release together.
#
# Assessment: the beat scheduler runs the same image as backend/worker and must
# not be left on the old release, and the optional DAST scanner services follow
# the new pinned images when the dast profile is enabled (docker compose only
# recreates them when their image or configuration really changed).  Other
# products keep exactly the historic command.
switch_application_services() {
  if ! is_assessment_runtime; then
    run_compose up -d --force-recreate backend worker frontend
    return $?
  fi
  local -a services=(backend worker frontend)
  compose_has_service beat && services=(backend worker beat frontend)
  run_compose up -d --force-recreate "${services[@]}" || return 1
  if dast_overlay_active; then
    run_compose up -d zap dast-egress || return 1
  fi
  return 0
}

# Login probe used after an upgrade.
#
# Assessment installations are stateful: the operator has changed the initial
# admin password and may have enabled a second factor, so "log in with the
# initial credentials" cannot be the success criterion of an upgrade.  What the
# probe must prove is that the frontend TLS proxy reaches a healthy backend auth
# endpoint: 200 (token or second-factor challenge) and the credential-policy
# answers 401/403/423/429 all show that, while 5xx, 404, TLS or connection
# errors still fail the upgrade.  A fresh install keeps the strict check
# (install.sh calls verify_initial_admin_login_via_frontend directly).
verify_admin_login_for_upgrade() {
  if ! is_assessment_runtime; then
    verify_initial_admin_login_via_frontend
    return $?
  fi
  log "Verifying the authentication endpoint through the frontend API proxy..."
  if run_compose run --rm --no-deps -T backend python - <<'PY' >/dev/null
import json
import ssl
import sys
import urllib.error
import urllib.request

from app.config import settings

payload = json.dumps({
    "email": settings.first_admin_email,
    "password": settings.first_admin_password,
}).encode()
request = urllib.request.Request(
    "https://frontend/api/v1/auth/login",
    data=payload,
    headers={"Content-Type": "application/json"},
    method="POST",
)
try:
    ctx = ssl.create_default_context(cafile="/app/tls/server.crt")
    with urllib.request.urlopen(request, timeout=10, context=ctx) as response:
        status = response.getcode()
        body = response.read(8192)
except urllib.error.HTTPError as exc:
    status = exc.code
    body = b""
except Exception as exc:
    print(f"authentication endpoint request failed: {type(exc).__name__}", file=sys.stderr)
    sys.exit(1)

if status in (401, 403, 423, 429):
    sys.exit(0)  # reachable; the operator's own credential policy answered
if status != 200:
    print(f"authentication endpoint returned HTTP {status}", file=sys.stderr)
    sys.exit(1)
try:
    json.loads(body.decode())
except Exception:
    print("authentication endpoint returned invalid JSON", file=sys.stderr)
    sys.exit(1)
PY
  then
    ok "Authentication endpoint reachable through the frontend API proxy"
    return 0
  fi
  return 1
}
