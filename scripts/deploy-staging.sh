#!/usr/bin/env bash
#
# Deploy del stack de STAGING de una app Oliva sobre infra compartida.
# Análogo a deploy.sh, pero usa la imagen staging y un project
# name propio (-p <app>-staging) para no interferir con el stack de producción.
#
# Prerequisitos (primera vez, una sola vez por app):
#   1. Provisionar la DB de staging en el Postgres compartido:
#        ~/infra/scripts/provision-postgres.sh <app>_staging_db <app>_staging_user
#   2. Completar .env.staging (copiar de .env.staging.example y setear DATABASE_URL).
#
# Uso:
#   ./scripts/deploy-staging.sh            # app_name = nombre del directorio actual
#   ./scripts/deploy-staging.sh ong        # app_name explícito
#   SKIP_PULL=1 ./scripts/deploy-staging.sh   # no hace git pull
set -euo pipefail

APP_NAME="${1:-$(basename "$PWD")}"
STAGING_PROJECT="${APP_NAME}-staging"

source "$(dirname "$0")/lib/project-guard.sh"
source "$(dirname "$0")/lib/docker-prune.sh"
source "$(dirname "$0")/lib/upgrade-guards.sh"
source "$(dirname "$0")/lib/env-check.sh"
source "$(dirname "$0")/lib/queue-guard.sh"
source "$(dirname "$0")/lib/backend-guard.sh"
assert_not_staging_name "$APP_NAME"
assert_project_owned_here "$STAGING_PROJECT"

COMPOSE=(docker compose -p "$STAGING_PROJECT"
  -f docker-compose.yml
  -f docker-compose.prod.yml
  -f docker-compose.shared-infra.yml
  -f docker-compose.staging.yml)

echo ">> Deploy de STAGING '$STAGING_PROJECT' desde $PWD"

# Antes del pull: mismo motivo que en deploy.sh (sembrar el estado de acciones de upgrade).
seed_acked_version

if [[ "${SKIP_PULL:-0}" != "1" ]]; then
  echo ">> git pull"
  git pull
fi

# Queues, before `down` (lib/queue-guard.sh): the same checks as production, plus the one
# only staging has. .env.staging.example separated the database and inherited production's
# broker, so the staging worker consumed production's messages (measured in the queue-slot
# epic). Production's configuration is resolved to compare: no container is touched.
echo ">> queue check"
PROD_CONFIG="$(docker compose -p "$APP_NAME" -f docker-compose.yml -f docker-compose.prod.yml \
  -f docker-compose.shared-infra.yml config 2>/dev/null)" || PROD_CONFIG=""
queue_ok=1
queue_guard "${COMPOSE[@]}" || queue_ok=0
realtime_guard "${COMPOSE[@]}" || queue_ok=0
if [[ -n "$PROD_CONFIG" ]]; then queue_guard_staging "$PROD_CONFIG" "${COMPOSE[@]}" || queue_ok=0; fi
backend_health_guard || queue_ok=0
if (( ! queue_ok )); then
  echo "!! STAGING DEPLOY ABORTED (see above). Nothing was stopped." >&2
  exit 1
fi

echo ">> down"
# --profile '*': mismo motivo que en deploy.sh (bajar todos los servicios con profile).
"${COMPOSE[@]}" --profile '*' down --remove-orphans

# build-everything (no enumerar servicios): enumerar es lo frágil — es lo que
# en finanzas-ong dejó el frontend STALE (build solo listaba backend) y se
# pudre de nuevo en cuanto un fork agregue un servicio buildeable más. Alinea
# además con deploy.sh (prod), que ya usa up -d --build.
# --wait, like deploy.sh: OK only when `migrate` exited 0 (it migrates the staging database,
# .env.staging loads last) and every service is healthy. The explicit migrate that used to
# follow is gone: the one-shot `migrate` service does it before anything else starts.
echo ">> up -d --build --wait (target backend/scheduler/migrate: staging)"
if ! "${COMPOSE[@]}" up -d --build --wait --wait-timeout "${OLIVA_DEPLOY_WAIT_TIMEOUT:-300}"; then
  echo "!! up failed. Last lines of migrate, backend and gateway:" >&2
  "${COMPOSE[@]}" logs --no-color --tail 25 migrate backend gateway >&2 || true
  exit 1
fi

echo ">> seeding (fixtures:load --group=staging)"
docker exec "${STAGING_PROJECT}-backend-1" bin/console doctrine:fixtures:load --group=staging --no-interaction

echo ">> estado:"
"${COMPOSE[@]}" ps

# La imagen que se acaba de reemplazar queda sin tag: sin esto, cada deploy suma ~750 MB.
prune_build_leftovers

run_upgrade_guards "${COMPOSE[@]}"
# Staging only warns about its environment (its data is disposable); prod aborts (deploy.sh).
guard_env "${COMPOSE[@]}" || true
show_pending_upgrade_actions host || true

echo ">> OK — staging corriendo en project '${STAGING_PROJECT}'."
echo "   DB de staging es desechable. Para reiniciar con datos frescos:"
echo "   SKIP_PULL=1 ./scripts/deploy-staging.sh"
