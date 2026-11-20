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
