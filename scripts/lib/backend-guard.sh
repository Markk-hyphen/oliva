# shellcheck shell=bash
#
# Backend guards (docs/roadmap/epics/E-backend-slot.md). Sourced. Static: they read files,
# never a container, so a deploy runs them before `down`, while the old stack still serves.
#
#   backend_health_guard   → 0 fine, 1 problem (stderr, with the fix)
#   build_guard COMPOSE... → 0 fine, 1 problem: a service builds a target its Dockerfile does
#                            not have, or lacks the `oliva` build context its Dockerfile uses
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
# Every service with a `build:` in the resolved config: its `target` must be a stage of its
# Dockerfile, and a Dockerfile that copies from the `oliva` context (`--from=oliva`) needs that
# context. Since 1.12.0 the backend's targets are `dev`/`prod`/`staging` (were frankenphp_*) and
# the backend and realtime builds read Oliva's list of public secrets through a named context.
# Both fail at build time, which a deploy reaches AFTER `down`, and the second with a message
# that points elsewhere: BuildKit takes `--from=oliva` for an image and answers "pull access
# denied, repository does not exist" (measured). A service of the app's own that builds
# backend/Dockerfile is the likely case. Static (`config`, no container): runs before `down`.
# Self-contained on purpose: the deploys source this file without scripts/oliva/lib.sh, so its
# `warn` does not exist there (measured: the deploy aborted printing only "warn: command not
# found", with no reason and no fix).
_bg_warn() { echo "!! $*" >&2; }
build_guard() {
  local cfg svc ctx df target ctxs dockerfile bad=0
  cfg="$("$@" --profile '*' config 2>/dev/null)" || return 0   # an unresolvable config is env_check's to report
  # \x1f, not a tab: tab is IFS whitespace, so `read` collapsed an empty target and shifted the
  # contexts into its place (measured on realtime, which has no target).
  while IFS=$'\x1f' read -r svc ctx df target ctxs; do
    [[ -n "$ctx" ]] || continue
    if [[ "$df" == /* ]]; then dockerfile="$df"; else dockerfile="$ctx/${df:-Dockerfile}"; fi
    [[ -f "$dockerfile" ]] || continue
    if [[ -n "$target" ]] && ! awk -v t="$target" 'toupper($1) == "FROM" && toupper($(NF-1)) == "AS" && $NF == t { f = 1 } END { exit !f }' "$dockerfile"; then
      _bg_warn "service '$svc' builds target '$target', which ${dockerfile#"$PWD"/} does not have."
      [[ "$target" == frankenphp_* ]] && _bg_warn "  Since Oliva 1.12.0 the backend's targets are dev, prod, staging: '${target#frankenphp_}' (docs/oliva/UPGRADING.md)."
      bad=1
    fi
    if grep -qE -- '--from=oliva([[:space:]]|$)' "$dockerfile" && [[ ",$ctxs," != *",oliva,"* ]]; then
      _bg_warn "service '$svc' builds ${dockerfile#"$PWD"/} without the 'oliva' build context it copies from."
      _bg_warn "  Add to its build:   additional_contexts: { oliva: ./scripts/oliva }   (or reuse docker-compose.yml's x-backend-build)"
      _bg_warn "  Without it the build fails with a misleading \"pull access denied, repository does not exist\"."
      bad=1
    fi
  done < <(awk '
      /^[^ ]/ { top = $0; next }
      top != "services:" { next }
      /^  [^ ]/ { flush(); svc = $1; sub(/:$/, "", svc); inb = 0; inctx = 0; next }
      /^    [^ ]/ { inb = ($1 == "build:"); inctx = 0; next }
      inb && /^      [^ ]/ {
        inctx = ($1 == "additional_contexts:")
        if ($1 == "context:") ctx = $2
        else if ($1 == "dockerfile:") df = $2
        else if ($1 == "target:") target = $2
        next }
      inb && inctx && /^        [^ ]/ { k = $1; sub(/:$/, "", k); ctxs = ctxs (ctxs ? "," : "") k; next }
      function flush() { if (svc != "" && ctx != "") printf "%s\037%s\037%s\037%s\037%s\n", svc, ctx, df, target, ctxs; svc = ""; ctx = ""; df = ""; target = ""; ctxs = "" }
      END { flush() }' <<< "$cfg")
  return $bad
}

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
