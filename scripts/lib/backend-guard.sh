# shellcheck shell=bash
#
# Backend guards (docs/roadmap/epics/E-backend-slot.md). Sourced. Static: they read files,
# never a container, so a deploy runs them before `down`, while the old stack still serves.
#
#   backend_health_guard   → 0 fine, 1 problem (stderr, with the fix)
#
# Since 1.11.0 the backend's healthcheck is the app's own GET /health, and the deploys run
# `up --wait`. An app without that route has a backend that can never be healthy: the
# deploy would fail AFTER `down`, with the stack already stopped. This says so first.
# Zero cost when the route exists (all three known apps have it, HealthController).

backend_health_guard() {
  # A route to /health declared as an attribute in src/, or in a routes file.
  grep -rqsE "Route\([[:space:]]*(path:[[:space:]]*)?['\"]/health['\"]" backend/src && return 0
  grep -rqsE "^[[:space:]]*path:[[:space:]]*['\"]?/health['\"]?[[:space:]]*$" backend/config/routes.yaml backend/config/routes 2>/dev/null && return 0
  cat >&2 <<'EOF'

!! ================================================================
!! NO /health ROUTE: the backend's healthcheck is GET /health (since
!! Oliva 1.11.0), and nothing in backend/src or backend/config/routes
!! answers it. The backend would never become healthy, and the deploy
!! would fail after stopping the running stack.
!!
!! Fix: restore Oliva's backend/src/Controller/HealthController.php
!!   (GET /health → {"status": "ok"}, no database, no auth)
!!   git show oliva-upstream/release:backend/src/Controller/HealthController.php
!! ================================================================

EOF
  return 1
}

# dev_cache_stale_check → 0 fresh or not applicable, 1 a Symfony cache may be stale (stdout:
# what and the fix). Dev only: reads backend/var/cache/dev on the host (a bind mount).
#
# Symfony decides that a compiled cache (the container, the routes) is fresh by comparing each
# tracked file's mtime with the cache's, in WHOLE SECONDS, and an equal second counts as fresh.
# A file saved in the same second the cache was compiled, but after it, is therefore never
# seen: the old config is served until the next edit in a later second. Measured in dev worker
# mode, where the watcher recompiles right after an edit (2 of 8 rapid code+YAML edits); it
# exists in classic mode too, less often (E-backend-slot, step 7). Here the comparison is in
# nanoseconds, and only inside that blind second, so a body-only edit of a class (Symfony
# checks its hash, the cache is legitimately older) is not reported.
dev_cache_stale_check() {
  local dir="backend/var/cache/dev" meta cache cts f host fts stale=()
  [[ -d "$dir" ]] || return 0
  for meta in "$dir"/*.meta.json; do
    [[ -e "$meta" ]] || continue
    cache="${meta%.meta.json}"
    [[ -f "$cache" ]] || continue
    cts="$(stat -c '%.9Y' "$cache")"
    while IFS= read -r f; do
      host="backend/${f#/app/}"
      [[ -f "$host" ]] || continue          # vendor/ and the like live only in the image
      fts="$(stat -c '%.9Y' "$host")"
      # Same whole second, later fraction. Integers, not awk: a double cannot hold 19 digits.
      if [[ "${fts%.*}" == "${cts%.*}" ]] && (( 10#${fts#*.} > 10#${cts#*.} )); then
        stale+=("${host} (newer than ${cache##*/}, same second)")
      fi
    done < <(grep -oE '"/app/[^"]+"' "$meta" | tr -d '"' | sort -u)
  done
  (( ${#stale[@]} )) || return 0
  echo "   !! Symfony may be serving an old cache: saved in the same second it was compiled, after it:"
  printf '   !!   %s\n' "${stale[@]}"
  echo "   !! Fix: docker compose exec backend rm -rf var/cache/dev && docker compose restart backend"
  return 1
}
