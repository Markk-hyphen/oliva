#!/usr/bin/env bash
#
# Smoke + tests contra el stack DEV de este checkout. Es la red de seguridad de todo
# cambio de dependencias o sync con Oliva: si pasa, el cambio no rompió nada que se vea.
#
# Uso (desde la raíz del repo):
#   scripts/oliva/verify.sh                       # todo
#   OLIVA_VERIFY_SKIP="schema prod-build" scripts/oliva/verify.sh
#
# Pasos (nombre entre corchetes = lo que acepta OLIVA_VERIFY_SKIP):
#   [env]         el entorno que Compose resuelve es sano: ningún secreto faltante, placeholder
#                 o públicamente conocido, ninguno en un archivo trackeado ni en el frontend
#                 (scripts/lib/env-check.sh). Fix habitual: ./oliva env init
#   [queue]       messages routed to an asynchronous transport have a worker to consume them
#                 (profile `queues`), or OLIVA_QUEUE_CONSUMER=external says they are consumed
#                 elsewhere (scripts/lib/queue-guard.sh). Not to be confused with prod-worker.
#   [backend]     static, before `up`: the app answers GET /health (since 1.11.0 the backend's
#                 healthcheck; without the route `up --wait` can never pass). Same guard as the
#                 deploys (scripts/lib/backend-guard.sh)
#   [up]          docker compose up -d --build --wait (respeta COMPOSE_PROFILES del .env)
#   [php-version] el PHP que CORRE coincide con el pin de backend/Dockerfile
#   [health]      GET /health
#   [worker-mode] the DEV backend runs FrankenPHP workers (since 1.11.0, like production): the
#                 running config has a worker block. An empty FRANKENPHP_CONFIG in .env turns
#                 it off silently; this makes that red
#   [dev-cache]   no compiled Symfony cache older than a file it tracks within the same second
#                 (Symfony checks in whole seconds; scripts/lib/backend-guard.sh)
#   [mercure]     publish con JWT + suscriptor CON token recibe el update privado y
#                 suscriptor anónimo NO (la regresión real de FrankenPHP 1.13.1)
#   [migrations]  no hay migraciones pendientes
#   [app]         the repo is an initialized app (marker .oliva-app, AGENTS.md imports the
#                 framework guide), or Oliva itself
#   [schema]      doctrine:schema:validate (CMP lo saltea: drift conocido de pgvector)
#   [phpunit]     suite completa (antes: scripts/lib/test-db.sh crea y migra la base de test
#                 si algún test usa el kernel; sin esos tests no hace nada)
#   [prod-build]  buildea las imágenes de prod (composer --no-dev, dump-env, vite build)
#   [prod-worker] worker mode de FrankenPHP prendido en prod: la imagen hornea
#                 FRANKENPHP_CONFIG y el .env de este checkout no lo pisa a vacío.
#   [ci-build]    rebuildea el backend con el driver buildx del CI (docker-container). SOLO
#                 si backend/php-extensions.txt tiene extensiones: es el camino donde el
#                 driver local y el del CI se comportan distinto (ej. /tmp en 755 → exit 100,
#                 que en local pasaba verde). Sin extensiones se saltea solo, sin costo.
#

# Corre sobre la DB de dev (es la de siempre); no crea ni borra stacks.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
source "$(dirname "$0")/../lib/upgrade-guards.sh"
source "$(dirname "$0")/../lib/env-check.sh"
source "$(dirname "$0")/../lib/queue-guard.sh"
source "$(dirname "$0")/../lib/backend-guard.sh"
require_repo_root
[[ -f .env ]] || die "falta .env → ./oliva env init"

SKIP=" ${OLIVA_VERIFY_SKIP:-} "
RESULTS=()
FAILED=0

step() {
  local name="$1"; shift
  if [[ "$SKIP" == *" $name "* ]]; then RESULTS+=("SKIP  $name"); return 0; fi
  info "[$name]"
  if "$@"; then RESULTS+=("PASS  $name"); else RESULTS+=("FAIL  $name"); FAILED=1; fi
}

be() { docker compose exec -T backend "$@"; }

do_env()        { env_check full docker compose; }
# Static, before `up`: an app that routes messages and runs no worker fails every dispatch
# in dev too (no broker either). Same check the deploys abort on.
do_queue() {
  queue_guard docker compose || return 1
  realtime_guard docker compose || return 1
  echo "queues: nothing routed asynchronously without a consumer (worker or realtime relay)"
}
# An app carries the marker written by `./oliva init`. A repo that received Oliva 1.7.0 and
# has none is still wearing Oliva's identity: say how to fix it. Oliva's own repository is
# told apart by its project files, which never reach an app. Costs nothing otherwise.
do_app() {
  local f
  if is_app; then
    echo "$(sed -n 's/^name=//p' "$OLIVA_APP_MARKER")"
    for f in AGENTS.pre-oliva-1.7.md README.pre-oliva-1.7.md; do
      [[ -f "$f" ]] && warn "$f is still here: move what is yours into ${f%.pre-oliva-1.7.md}.md, then delete it"
    done
    [[ "$(head -1 AGENTS.md 2>/dev/null)" == "@docs/oliva/agent-guide.md" ]] \
      || { warn "AGENTS.md does not import the framework guide: its first line must be @docs/oliva/agent-guide.md"; return 1; }
  elif [[ -e docs/roadmap.md ]]; then
    echo "Oliva itself"
  else
    warn "not initialized: no $OLIVA_APP_MARKER. Run: ./oliva init \"<name>\" (a new app) or ./oliva init --adopt (one that already exists)"
    return 1
  fi
}
do_backend()    { backend_health_guard && echo "GET /health route present"; }
do_up()         { docker compose up -d --build --wait; }
do_health()     { be curl -fsS http://localhost/health && echo; }
# From the host, through the gateway: proves the three routes the gateway owns
# end up at the right place with the right content type. /gateway-health is
# answered locally (the healthcheck relies on it); /health comes back as JSON
# (frontend answering HTML there was the bug 1.9.0 fixes); the CSP header must
# be present so a missing policy in prod is loud. GATEWAY_PORT lets a second app
# publish on a different port in dev.
do_gateway() {
  local base="http://localhost:${GATEWAY_PORT:-80}" code ct body hdr
  # /gateway-health
  read -r code ct < <(curl -s -o /tmp/v-gw.out -w '%{http_code} %{content_type}' "$base/gateway-health")
  body="$(cat /tmp/v-gw.out)"
  [[ "$code" == 200 && "$body" == "ok" ]] || { warn "/gateway-health = $code $body"; return 1; }
  # /health, must be JSON (the regression step 1 of the phase fixes)
  read -r code ct < <(curl -s -o /tmp/v-gw.out -w '%{http_code} %{content_type}' "$base/health")
  [[ "$code" == 200 && "$ct" == application/json* ]] \
    || { warn "/health through the gateway = $code $ct (expected 200 application/json)"; return 1; }
  # /, must be HTML (frontend upstream reachable)
  read -r code ct < <(curl -s -o /dev/null -w '%{http_code} %{content_type}' "$base/")
  [[ "$code" == 200 && "$ct" == text/html* ]] \
    || { warn "/ through the gateway = $code $ct (expected 200 text/html; is the frontend upstream reachable?)"; return 1; }
  # CSP header present (missing = the gateway stopped owning the policy).
  hdr="$(curl -sI "$base/" | tr -d '\r' | grep -i '^content-security-policy:' | sed -n 1p)"
  [[ -n "$hdr" ]] || { warn "no Content-Security-Policy header through the gateway"; return 1; }
  echo "/gateway-health ok; /health JSON; / HTML; CSP present"
}
do_worker_mode() {
  be curl -fsS http://localhost:2019/config/apps/frankenphp | grep -q '"workers":\[{' \
    || { warn "the dev backend runs no FrankenPHP worker (classic mode): is FRANKENPHP_CONFIG set, maybe empty, in .env? Remove it"; return 1; }
  echo "FrankenPHP worker mode on (dev, like production)"
}
do_dev_cache() { dev_cache_stale_check || return 1; echo "Symfony caches fresh"; }
do_migrations() { be bin/console doctrine:migrations:up-to-date; }
do_schema() { be bin/console doctrine:schema:validate; }
do_phpunit()    { scripts/lib/test-db.sh && be php vendor/bin/phpunit; }
do_prod_build() { docker compose -f docker-compose.yml -f docker-compose.prod.yml build backend frontend gateway; }

# Tras el prod-build: worker mode tiene que quedar prendido en prod. Dos mitades, las dos
# guards de lib/upgrade-guards.sh (deploy*.sh corre las mismas en el host):
#   worker-image: la imagen hornea el valor (si alguien lo saca del Dockerfile, arranca apagado).
#   worker-env:   el .env de ESTE checkout no lo pisa a vacío (el CI no ve el .env real).
do_prod_worker() {
  local prod=(docker compose -f docker-compose.yml -f docker-compose.prod.yml) rc=0
  guard_worker_image "${prod[@]}" || rc=1
  guard_worker_env "${prod[@]}" || rc=1
  (( rc == 0 )) && echo "worker mode: horneado en la imagen y sin pisar en el env"
  return $rc
}

# Builder `oliva-ci` (driver docker-container, como setup-buildx-action en el CI). Se crea
# la primera vez; guarda su propia caché, así que solo el primer build es lento.
# Sin --load: alcanza con que buildee, no hace falta pasar la imagen al daemon.
fork_has_extensions() { grep -qvE '^[[:space:]]*(#|$)' backend/php-extensions.txt 2>/dev/null; }
do_ci_build() {
  docker buildx inspect oliva-ci >/dev/null 2>&1 \
    || docker buildx create --name oliva-ci --driver docker-container >/dev/null
  docker buildx build --builder oliva-ci --target frankenphp_dev -q backend >/dev/null
}

# Versión de PHP que CORRE en el backend vs. el pin de backend/Dockerfile.
# Un build verde NO prueba que estés parcheado: si el `up` reusó un container vivo, sus
# workers siguen sirviendo el PHP anterior. Es exactamente el modo de falla de un CVE como
# PHP2Shell, donde el fix solo toma efecto al recrear el proceso — el paso que más fácil se
# saltea en un apuro, y el que no deja rastro. Este step cierra ese loop.
# También falla si el tag no pinea un patch exacto: un tag flotante es la regresión que ya
# rompió Mercure una vez (ver comentario del FROM en backend/Dockerfile).
do_php_version() {
  local pin running
  pin="$(backend_base_image | grep -oE 'php[0-9]+\.[0-9]+\.[0-9]+$' | sed 's/^php//')"
  if [[ -z "$pin" ]]; then
    warn "backend/Dockerfile no pinea un PHP exacto (x.y.z) en el FROM ... AS frankenphp_upstream"
    warn "un tag flotante hace que un rebuild cualquiera cambie el runtime sin aviso: pinealo"
    return 1
  fi
  running="$(be php -r 'echo PHP_VERSION;' | tr -d '\r')"
  if [[ "$running" != "$pin" ]]; then
    warn "el backend corre PHP $running pero backend/Dockerfile pinea $pin"
    warn "si venís de bumpear la imagen base, el container es viejo:"
    warn "  docker compose up -d --force-recreate backend"
    return 1
  fi
  echo "PHP $running (coincide con el pin de backend/Dockerfile)"
}

# JWT HS256 firmado con la clave del hub (la misma que usa MercureBundle).
jwt() {
  local key="$1" payload="$2" h p s
  b64() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
  h="$(printf '{"alg":"HS256","typ":"JWT"}' | b64)"
  p="$(printf '%s' "$payload" | b64)"
  s="$(printf '%s.%s' "$h" "$p" | openssl dgst -sha256 -hmac "$key" -binary | b64)"
  printf '%s.%s.%s' "$h" "$p" "$s"
}

do_mercure() {
  local key pub sub marker gw
  gw="http://localhost:${GATEWAY_PORT:-80}/.well-known/mercure"
  key="$(be printenv MERCURE_JWT_SECRET | tr -d '\r')"
  [[ -n "$key" ]] || { warn "MERCURE_JWT_SECRET vacía en el backend"; return 1; }
  pub="$(jwt "$key" '{"mercure":{"publish":["*"]}}')"
  sub="$(jwt "$key" '{"mercure":{"subscribe":["*"]}}')"
  marker="oliva-verify-$RANDOM$RANDOM"
  # Subscribe THROUGH THE GATEWAY from the host (browser → gateway → hub). Publish straight
  # to the hub from inside the backend (backend → hub, the relay's own path). Two subscribers
  # (token / anonymous); a PRIVATE update must reach only the token holder.
  curl -sN --max-time 5 -H "Authorization: Bearer $sub" "$gw?topic=oliva/verify" > /tmp/v-auth.out &
  curl -sN --max-time 5 "$gw?topic=oliva/verify" > /tmp/v-anon.out &
  sleep 1
  be sh -c 'curl -fsS -X POST -H "Authorization: Bearer $1" -d topic=oliva/verify -d "data=$2" -d private=on \
              "${MERCURE_URL:-http://realtime/.well-known/mercure}" >/dev/null' _ "$pub" "$marker" || { wait; warn "el hub rechazó el publish (publisher_jwt / MERCURE_URL)"; return 1; }
  wait
  if ! grep -q "$marker" /tmp/v-auth.out; then warn "el suscriptor con token NO recibió el update privado (por el gateway)"; return 1; fi
  if grep -q "$marker" /tmp/v-anon.out; then warn "un suscriptor ANÓNIMO recibió un update privado"; return 1; fi
  echo "publish al hub OK; privado entregado solo al suscriptor con token, por el gateway"
}

step env         do_env
step app         do_app
step queue       do_queue
step backend     do_backend
step up          do_up
step php-version do_php_version
step health      do_health
step worker-mode do_worker_mode
step dev-cache   do_dev_cache
step gateway     do_gateway
# The hub is its own service (profile `realtime`). No hub in this stack, nothing to test.
if docker compose ps --services 2>/dev/null | grep -qx realtime; then step mercure do_mercure
else RESULTS+=("SKIP  mercure (realtime profile off)"); fi
step migrations  do_migrations
step schema      do_schema
step phpunit     do_phpunit
step prod-build  do_prod_build
step prod-worker do_prod_worker
if fork_has_extensions; then step ci-build do_ci_build
else RESULTS+=("SKIP  ci-build (php-extensions.txt vacío)"); fi

echo
echo "── verify: $(basename "$PWD") ──"
printf '   %s\n' "${RESULTS[@]}"
exit $FAILED
