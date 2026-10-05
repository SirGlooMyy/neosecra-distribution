#!/usr/bin/env bash
# Post-upgrade hook runner (declarative hooks in release-manifest.yaml, see
# upgrade/post_upgrade.py for the manifest contract).  Source after common.sh.
set -Euo pipefail

# Run <command...> inside compose service <service> of the CURRENT compose
# context (overlay included), bounded by <seconds>.  stdin is closed so the
# command can never consume the caller's input.
compose_exec_timeout() {
  local seconds="$1" service="$2"
  shift 2
  local -a runner=(docker) bound=()
  [[ -z "${_DOCKER_NEEDS_SUDO:-}" ]] || runner=(sudo docker)
  if command -v timeout >/dev/null 2>&1; then
    bound=(timeout --kill-after=30 "$seconds")
  else
    warn "timeout(1) is not available; post-upgrade hook runs without a time limit"
  fi
  compose_args
  "${bound[@]+"${bound[@]}"}" "${runner[@]}" compose "${COMPOSE_ARGS[@]}" exec -T "$service" "$@" < /dev/null
}

# run_post_upgrade_hooks <from_version> <to_version> [manifest]
#   0  every pending hook succeeded, or only "warn" hooks failed (journaled, retried later)
#   1  a hook declared on_failure=fail failed
#   2  the manifest hooks are invalid (fail closed: nothing is executed)
run_post_upgrade_hooks() {
  local from_version="$1" to_version="$2" manifest="${3:-$MANIFEST_FILE}" only="${4:-}"
  local helper="${V1_ROOT}/upgrade/post_upgrade.py"
  if [[ ! -f "$helper" || -L "$helper" ]]; then
    warn "post-upgrade hooks: helper is missing (${helper}); skipped"
    return 0
  fi
  local plan
  if [[ -n "$only" ]]; then
    plan="$(python3 "$helper" plan "$manifest" "$STATE_DIR" "$from_version" "$only" | tr -d '\r')" || {
      err "post-upgrade hooks: cannot select hook ${only}"; return 2; }
  else
    plan="$(python3 "$helper" plan "$manifest" "$STATE_DIR" "$from_version" | tr -d '\r')" || {
      err "post-upgrade hooks: the release manifest hooks are invalid"; return 2; }
  fi
  if [[ -z "$plan" ]]; then
    log "No post-upgrade hook pending (${from_version} -> ${to_version})"
    return 0
  fi

  local result=0 hook_id service timeout on_failure hook_rc
  local -a argv
  while IFS=$'\t' read -r hook_id service timeout on_failure; do
    [[ -n "$hook_id" ]] || continue
    argv=()
    mapfile -d '' -t argv < <(python3 "$helper" argv "$manifest" "$hook_id") || true
    if [[ ${#argv[@]} -eq 0 ]]; then
      err "post-upgrade hook ${hook_id}: command could not be read"
      [[ "$on_failure" == "fail" ]] && { result=1; break; }
      continue
    fi
    log "Post-upgrade hook ${hook_id}: ${service} ${argv[*]}"
    hook_rc=0
    compose_exec_timeout "$timeout" "$service" "${argv[@]}" || hook_rc=$?
    if [[ $hook_rc -eq 0 ]]; then
      python3 "$helper" mark "$STATE_DIR" "$hook_id" "$to_version" >/dev/null ||
        warn "post-upgrade hook ${hook_id} succeeded but its marker could not be written; it will run again"
      ok "Post-upgrade hook ${hook_id} completed"
      continue
    fi
    python3 "$helper" mark-failed "$STATE_DIR" "$hook_id" "$to_version" >/dev/null || true
    if [[ "$on_failure" == "fail" ]]; then
      err "Post-upgrade hook ${hook_id} failed (exit ${hook_rc})"
      result=1
      break
    fi
    warn "Post-upgrade hook ${hook_id} failed (exit ${hook_rc}); the upgrade continues and the hook stays pending (upgrade/post-upgrade.sh run)"
  done <<< "$plan"
  return "$result"
}
