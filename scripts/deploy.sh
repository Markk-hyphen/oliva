#!/usr/bin/env bash
#
# Deploy de una app Oliva sobre infra compartida (down + build + up).
# Reemplaza la tira de comandos manuales del runbook de docs/oliva/agent-guide.md.
#
# Uso:
#   ./scripts/deploy.sh            # app_name = nombre del directorio actual (ej. en ~/ong → "ong")
#   ./scripts/deploy.sh ong        # app_name explícito
#   SKIP_PULL=1 ./scripts/deploy.sh   # no hace git pull (deploy de cambios ya presentes)
#
# Corre desde la raíz del repo de la app en el VPS (ahí viven los 3 compose files).
set -euo pipefail

APP_NAME="${1:-$(basename "$PWD")}"

source "$(dirname "$0")/lib/project-guard.sh"
source "$(dirname "$0")/lib/docker-prune.sh"
source "$(dirname "$0")/lib/upgrade-guards.sh"
source "$(dirname "$0")/lib/env-check.sh"
source "$(dirname "$0")/lib/queue-guard.sh"
source "$(dirname "$0")/lib/backend-guard.sh"
assert_not_staging_name "$APP_NAME"
assert_project_owned_here "$APP_NAME"

COMPOSE=(docker compose -p "$APP_NAME"
  -f docker-compose.yml
  -f docker-compose.prod.yml
  -f docker-compose.shared-infra.yml)

echo ">> Deploy de '$APP_NAME' desde $PWD"

# Antes del pull: si este host no tiene estado de acciones de upgrade, se siembra con la
# versión que corre ahora, así las acciones [host] de lo que traiga el pull quedan pendientes.
seed_acked_version

if [[ "${SKIP_PULL:-0}" != "1" ]]; then
  echo ">> git pull"
  git pull
fi

# The guards that ABORT a deploy, both before `down` (every other guard only warns, see
# upgrade-guards.sh). A production stack on a secret that is missing, a placeholder or publicly known has no
# secret at all: going on IS the damage. It runs before `down`, so the stack that is
# serving now keeps serving. Checked on what Compose resolves for THIS stack.
echo ">> env check"
if ! env_check quiet "${COMPOSE[@]}"; then
  cat >&2 <<EOF

!! ================================================================
!! DEPLOY ABORTED: the environment of '$APP_NAME' is not fit for
!! production (see above). Nothing was stopped: the current stack
!! is still running.
!!
!! Fix: ./oliva env init     (generates what is missing in .env)
!!      ./oliva env check    (to see it again)
!! then: SKIP_PULL=1 ./scripts/deploy.sh
!! ================================================================

EOF
  exit 1
fi

# Queues (lib/queue-guard.sh): messages routed to an asynchronous transport with no worker
# to consume them, or a worker on the default vhost of the shared broker, where it would
# consume other apps' messages. Neither fails at boot, and a late effect is not undone by
# processing the backlog later, so it stops here too, with the old stack serving.
echo ">> queue check"
if ! queue_guard "${COMPOSE[@]}"; then
  echo "!! DEPLOY ABORTED (see above). Nothing was stopped: the current stack is still running." >&2
  echo "!! After the fix: SKIP_PULL=1 ./scripts/deploy.sh" >&2
  exit 1
fi

# Realtime (lib/queue-guard.sh): the app publishes to Mercure but runs no hub. Same reason
# as the queue check — the effect (updates lost to a 502, piling up in the DB) is not undone
# later, so it stops here with the old stack serving.
if ! realtime_guard "${COMPOSE[@]}"; then
  echo "!! DEPLOY ABORTED (see above). Nothing was stopped: the current stack is still running." >&2
  echo "!! After the fix: SKIP_PULL=1 ./scripts/deploy.sh" >&2
  exit 1
fi

# Backend (lib/backend-guard.sh): the healthcheck is the app's GET /health and the `up` below
# waits for it. Without the route the backend never becomes healthy and the deploy would
# fail after `down`; stop here instead, with the old stack serving.
if ! backend_health_guard; then
  echo "!! DEPLOY ABORTED (see above). Nothing was stopped: the current stack is still running." >&2
  exit 1
fi

# Docs internos: no pertenecen al host de prod. El código de la app vive
# en los builds Docker; estos archivos no los necesita nadie en el server.
echo ">> limpieza de docs internos"
find . -maxdepth 1 -name "*.md" -delete
rm -rf docs/

# down borra los containers viejos antes de recrearlos.
# --profile '*' mete en scope del down a TODOS los servicios con profile (cron,
# queues, y los que agregue el fork). Sin esto, un servicio detrás de un profile
# inactivo no se baja — `down` lo saltea y --remove-orphans tampoco (sigue
# definido en el YAML, no es huérfano) → queda corriendo stale. Antes se usaba
# COMPOSE_PROFILES=cron, que REEMPLAZA los profiles del .env: dejaba afuera a
# `queues`. Los servicios desactivados en shared-infra (database/rabbitmq) entran
# en scope pero no tienen containers en este project: el down no los toca.
# El `up` de abajo usa los profiles del `.env` del host (COMPOSE_PROFILES): cada
# servicio con profile vuelve a levantar solo si la app lo declaró ahí.
echo ">> down"
"${COMPOSE[@]}" --profile '*' down --remove-orphans

# --wait: OK only when the one-shot `migrate` exited 0 and every long-running service is
# healthy (the backend's healthcheck is its own GET /health). Until 1.11.0 a plain `up -d`
# returned 0 with the backend in a restart loop on a failed migration (E-backend-slot, M1).
# The timeout bounds a service that never becomes healthy (the backend's start period is 60 s).
echo ">> up -d --build --wait"
if ! "${COMPOSE[@]}" up -d --build --wait --wait-timeout "${OLIVA_DEPLOY_WAIT_TIMEOUT:-300}"; then
  # The reason is in the containers' logs, not in the output of `up` (a failed migration,
  # the backend refusing to start on a public secret, a bad Caddyfile in the gateway, which
  # makes the whole stack look down even when the backend is fine): bring them here.
  echo "!! up failed: the stack is NOT serving. Last lines of migrate, backend and gateway:" >&2
  "${COMPOSE[@]}" logs --no-color --tail 25 migrate backend gateway >&2 || true
  exit 1
fi

echo ">> estado:"
"${COMPOSE[@]}" ps

# La imagen que se acaba de reemplazar queda sin tag: sin esto, cada deploy suma ~750 MB.
prune_build_leftovers

# Solo avisan, no abortan (el stack ya está arriba). UPGRADING.md se lee de git: el
# working tree ya no tiene docs/.
run_upgrade_guards "${COMPOSE[@]}"
show_pending_upgrade_actions host || true

echo ">> OK. Profiles opcionales (cron, queues): se activan con COMPOSE_PROFILES en el .env del host."
