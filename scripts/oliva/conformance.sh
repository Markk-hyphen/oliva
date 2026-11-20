#!/usr/bin/env bash
#
# The backend conformance suite: tests a backend image FROM OUTSIDE against the backend
# contract (docs/oliva/backend-contract.md), the same way for the default backend and for
# any replacement. Image and HTTP only: no PHP, no Symfony, nothing read from the backend's
# code. The default backend must be able to fail every assertion (each one was proven
# against a deliberately broken backend: E-backend-slot, "Phase B results", step 6).
#
# Usage (from the repository root):
#   ./oliva conformance                         # build this checkout's prod + staging, test them
#   ./oliva conformance <image> [--staging <image>] [--db-url-suffix '?k=v'] [--keep]
#   ./oliva conformance --down                  # remove a harness left by --keep or a killed run
#
#   <image>            the backend's `prod` image (any tag Docker can run or pull)
#   --staging <image>  its `staging` image, for the Seed clause. Without it, the staging half
#                      of K6 is not tested, and the run says INCOMPLETE (exit 2)
#   --db-url-suffix    appended to every DATABASE_URL, for a backend that cannot read a plain
#                      postgresql:// URL: the other clauses get tested, and K8 is reported unmet
#   --keep             leave the harness up afterwards (debugging); remove it with --down
#
# Assertions (ids are what the contract cites):
#   K1  mandatory    GET /health on :80, plain HTTP: 200, application/json, a JSON body;
#                    also through Oliva's gateway
#   K2  mandatory    the same with the database stopped (liveness has no I/O)
#   K3  mandatory    oliva-migrate on a fresh database: exit 0; again: exit 0, nothing changed
#   K4  mandatory    two oliva-migrate at once: at most one non-zero; a re-run exits 0; the
#                    result equals a single run's (schema and row counts)
#   K5  mandatory    oliva-migrate with an unreachable database, and with a wrong password:
#                    non-zero within K5_BOUND seconds
#   K6  mandatory    oliva-seed absent from the prod image; in staging: exits 0, twice, with
#                    the same row counts (it replaces the data, it does not add to it)
#   K7  mandatory    SIGTERM to the idle server (docker compose stop): exits within the 10 s
#                    grace period, not by SIGKILL
#   K8  recommended  a plain postgresql:// DATABASE_URL works (every run above uses one)
#   K9  recommended  a request shows on the server's stdout/stderr
#   K10 mandatory    Oliva's gateway: a forged X-Forwarded-For is dropped with the trust a
#                    standalone production stack ships, and kept with the shared-infra one
#                    (the edge proxy's client address). Read from the compose files, not copied
#   D1, D2           declared: trusted proxies (backend half) and in-flight draining.
#                    Printed on every run as declared, never as passed
#
# Output: one line per assertion (PASS, FAIL with the reason, WARN for a recommended one,
# SKIP, DECLARED). Exit 0 all mandatory passed; 1 a mandatory failed; 2 none failed but a
# mandatory one was not tested.
#
# The harness: scripts/oliva/conformance.compose.yml, project <app>-conformance, no host
# port (a probe container makes every request), always removed with its volumes. It never
# touches the app's own stacks, images or .env. Needs docker compose, openssl, awk.

set -euo pipefail
source "$(dirname "$0")/lib.sh"
source "$(dirname "$0")/../lib/env-check.sh"
require_repo_root

ROOT="$PWD"
HARNESS="$ROOT/scripts/oliva/conformance.compose.yml"
K5_BOUND=120            # seconds oliva-migrate may take to give up on a database that never answers
GRACE=10                # Compose's default stop grace period, what every deploy gives a container
HEALTH_WAIT=120         # seconds the server may take to answer /health after it starts

usage() { sed -n '/^# Usage/,/^# Assertions/p' "$0" | sed '$d; s/^# \{0,1\}//'; }

IMAGE="" STAGING="" SUFFIX="" KEEP=0 DOWN=0
while (( $# )); do
  case "$1" in
    --staging) STAGING="${2:?--staging needs an image}"; shift 2 ;;
    --db-url-suffix) SUFFIX="${2:?--db-url-suffix needs a value}"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    --down) DOWN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown option: $1 (see ./oliva conformance --help)" ;;
    *) [[ -z "$IMAGE" ]] || die "one image only (the prod one); the staging one goes after --staging"
       IMAGE="$1"; shift ;;
  esac
done
for t in docker openssl awk; do command -v "$t" >/dev/null || die "$t is required"; done

APP="$(basename "$ROOT" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9\n_-' '-')"
P="${APP}-conformance"
TMP="$(mktemp -d)"

# Hermetic: nothing from the app's .env or the caller's shell reaches the harness compose,
# except the variables this script exports.
unset COMPOSE_FILE COMPOSE_PROFILES COMPOSE_PROJECT_NAME
dc() { docker compose --env-file /dev/null --project-directory "$TMP" -p "$P" -f "$HARNESS" "$@"; }

# Everything of the harness, by the project label Compose puts on it. Not `docker compose
# down`: that needs the variables only this script sets, and failed silently from a shell
# (measured: the command --keep used to print removed nothing).
remove_harness() {
  docker ps -aq --filter "label=com.docker.compose.project=$P" | xargs -r docker rm -fv >/dev/null 2>&1 || true
  docker network ls -q --filter "label=com.docker.compose.project=$P" | xargs -r docker network rm >/dev/null 2>&1 || true
  docker volume ls -q --filter "label=com.docker.compose.project=$P" | xargs -r docker volume rm >/dev/null 2>&1 || true
}
if (( DOWN )); then
  remove_harness
  left="$(docker ps -aq --filter "label=com.docker.compose.project=$P" | wc -l | tr -d ' ')"
  (( left == 0 )) || die "$left container(s) of $P are still there: docker ps -a --filter label=com.docker.compose.project=$P"
  echo "conformance harness $P removed"; rm -rf "$TMP"; exit 0
fi

BG_PIDS=()
OURS=1
cleanup() {
  local pid
  (( OURS )) || { rm -rf "$TMP"; return; }
  for pid in "${BG_PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
  if (( KEEP )); then
    echo
    echo "   harness left up (--keep). Remove it with: ./oliva conformance --down"
    return
  fi
  # One-off containers (`run`) that a timeout left behind carry the project label too; -v
  # takes the database's anonymous volume with its container.
  remove_harness
  rm -rf "$TMP"
}
trap cleanup EXIT
# Stop on Ctrl-C and on a cancelled CI job, explicitly. Without these, an interrupt did NOT
# stop the run (measured): `docker compose` catches SIGINT and exits normally, bash takes that
# as handled and goes on to the next assertion, and the run ended "CONFORMANT" with a step cut
# short. The EXIT trap above still removes the harness.
# The message goes to the stderr the script started with (fd 9): a trap runs inside whatever
# function was running, with that function's redirections, and `dc … > "$TMP/up.log"` sent it
# to a file the cleanup then deleted (measured: interrupted runs ended with no message).
exec 9>&2
trap 'echo >&9; echo "   INTERRUPTED: no verdict" >&9; exit 130' INT
trap 'echo >&9; echo "   TERMINATED: no verdict" >&9; exit 143' TERM

# A harness already there is another run in progress, a --keep run or a killed one. Taking it
# down could break a run in progress; reusing it would make every result a lie. Say so, and
# leave it alone (OURS=0: the cleanup does not touch it either).
if [[ -n "$(docker ps -aq --filter "label=com.docker.compose.project=$P")" ]]; then
  OURS=0
  die "a conformance harness ($P) is already there: another run in progress, or a leftover. If none is running: ./oliva conformance --down"
fi

# ── Results ──────────────────────────────────────────────────────────────────────
MANDATORY_FAIL=0
MANDATORY_SKIP=0
# result <PASS|FAIL|SKIP|DECLARED> <id> <mandatory|recommended|declared> <message>
result() {
  local status="$1" id="$2" kind="$3" msg="$4"
  if [[ "$kind" == recommended && "$status" == FAIL ]]; then status=WARN; fi
  [[ "$kind" == mandatory && "$status" == FAIL ]] && MANDATORY_FAIL=1
  [[ "$kind" == mandatory && "$status" == SKIP ]] && MANDATORY_SKIP=1
  printf '   %-9s %-4s %s\n' "$status" "$id" "$msg"
}
# The last lines of a log, indented, for a FAIL that needs its evidence.
tail_of() { tail -n "${2:-6}" "$1" 2>/dev/null | sed 's/^/                    | /'; }
# What changed between two fingerprints. `|| true`: diff exits 1 when they differ, and under
# pipefail + set -e that killed the whole run right after printing (found by the negative
# controls: the remaining assertions and the verdict never appeared).
show_diff() { { diff "$1" "$2" || true; } | sed -n '1,8p' | sed 's/^/                    | /'; }
# Milliseconds, without GNU date's %N (bash 5's EPOCHREALTIME; its decimal mark follows the locale).
now_ms() { local t="${EPOCHREALTIME:-}"; if [[ -n "$t" ]]; then t="${t//[.,]/}"; echo $((10#$t / 1000)); else echo $((SECONDS * 1000)); fi; }

# ── The images ───────────────────────────────────────────────────────────────────
GATEWAY_IMAGE="$P-gateway:conformance"
# `--load`, always: with a builder of the docker-container driver (what CI's setup-buildx-action
# makes the default) a plain `docker build` leaves the image in the build cache, not in Docker,
# and the harness would not find it (measured).
build() { docker buildx build --load -q "$@" >/dev/null; }
if [[ -z "$IMAGE" ]]; then
  info "building this checkout's backend (prod, staging): cached layers are reused, a cold build takes minutes"
  IMAGE="$P-backend:prod"; STAGING="$P-backend:staging"
  build --build-context oliva=scripts/oliva --target prod -t "$IMAGE" backend
  build --build-context oliva=scripts/oliva --target staging -t "$STAGING" backend
fi
# Every image must exist (locally or pullable) before anything is judged: a missing one made
# `docker run` exit 125, which K6 would have reported as "oliva-seed exists in production".
for img in "$IMAGE" ${STAGING:+"$STAGING"}; do
  docker image inspect "$img" >/dev/null 2>&1 || docker pull -q "$img" >/dev/null 2>&1 \
    || die "image not found, locally or in a registry: $img"
done
info "building Oliva's gateway from this checkout (also the probe and the echo upstream)"
build -t "$GATEWAY_IMAGE" gateway

# ── What the product ships: the gateway's proxy trust per topology ─────────────
# Resolved by Compose from the real compose files, in a scratch directory with empty env
# files and the host's .env ignored, so the value is the SHIPPED default, not this host's.
shipped_trust() {
  local d="$TMP/trust" f
  mkdir -p "$d"
  cp docker-compose.yml docker-compose.prod.yml docker-compose.shared-infra.yml "$d/"
  # Every env_file the compose files name must exist for `config` to run.
  grep -hoE '^[[:space:]]*-[[:space:]]+\.env[A-Za-z0-9._-]*' docker-compose*.yml | awk '{print $2}' \
    | sort -u | while read -r f; do : > "$d/$f"; done
  (cd "$d" && env -u GATEWAY_TRUSTED_PROXIES docker compose --env-file /dev/null -p trust \
      -f docker-compose.yml -f docker-compose.prod.yml "$@" config 2>/dev/null) \
    | _ec_service_env gateway | awk -F'\t' '$1 == "GATEWAY_TRUSTED_PROXIES" { print $2 }'
}
TRUST_PROD="$(shipped_trust)"
TRUST_SHARED="$(shipped_trust -f docker-compose.shared-infra.yml)"
[[ -n "$TRUST_PROD" && -n "$TRUST_SHARED" ]] \
  || die "could not resolve GATEWAY_TRUSTED_PROXIES from docker-compose.prod.yml / docker-compose.shared-infra.yml"

# ── The backend's environment: what a real stack hands it ────────────────────────
# .env.example as `./oliva env init` starts from it, every generated secret of the manifests
# filled with a fresh value (a production image refuses empty, placeholder and publicly known
# ones), the database pointed at the harness; then .env.backend, in the same order as
# docker-compose.yml's env_file.
DB_PASSWORD="$(openssl rand -hex 16)"
db_url() { printf 'postgresql://conformance:%s@%s:5432/%s%s' "${3:-$DB_PASSWORD}" "${2:-database}" "$1" "$SUFFIX"; }
make_env() {
  local name slot kind value src out="$TMP/backend.env"
  declare -A V=()
  while IFS=$'\t' read -r name _ kind value; do
    if [[ "$value" =~ ^gen:hex([0-9]+)$ ]]; then V[$name]="$(openssl rand -hex "${BASH_REMATCH[1]}")"; fi
  done < <(oliva_manifest_rows)
  while IFS=$'\t' read -r name _ kind value; do
    if [[ "$value" == same:* ]]; then V[$name]="${V[${value#same:}]:-}"; fi
  done < <(oliva_manifest_rows)
  V[POSTGRES_USER]=conformance; V[POSTGRES_PASSWORD]="$DB_PASSWORD"; V[POSTGRES_DB]=app
  V[DATABASE_URL]="$(db_url app)"
  : > "$out"
  if [[ -f .env.example ]]; then
    while IFS= read -r src || [[ -n "$src" ]]; do
      name="${src%%=*}"
      if [[ "$src" == *=* && "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ && -n "${V[$name]+x}" ]]; then
        printf '%s=%s\n' "$name" "${V[$name]}" >> "$out"; unset "V[$name]"
      else
        printf '%s\n' "$src" >> "$out"
      fi
    done < .env.example
  fi
  for name in "${!V[@]}"; do printf '%s=%s\n' "$name" "${V[$name]}" >> "$out"; done
  if [[ -f .env.backend ]]; then cp .env.backend "$TMP/backend2.env"; else : > "$TMP/backend2.env"; fi
}
make_env

PG="$(sed -n 's/^POSTGRES_VERSION=\([0-9][0-9]*\).*/\1/p' .env.example 2>/dev/null | sed -n 1p)"
export OLIVA_CF_IMAGE="$IMAGE" OLIVA_CF_STAGING_IMAGE="${STAGING:-$IMAGE}" \
  OLIVA_CF_GATEWAY_IMAGE="$GATEWAY_IMAGE" OLIVA_CF_PG="${PG:-15}" \
  OLIVA_CF_DB_PASSWORD="$DB_PASSWORD" OLIVA_CF_ENV_FILE="$TMP/backend.env" \
  OLIVA_CF_ENV_BACKEND="$TMP/backend2.env" \
  OLIVA_CF_TRUST_PROD="$TRUST_PROD" OLIVA_CF_TRUST_SHARED="$TRUST_SHARED"

# ── Helpers ──────────────────────────────────────────────────────────────────────
probe() { dc exec -T probe "$@"; }
psql_db() { dc exec -T database psql -v ON_ERROR_STOP=1 -U conformance -d "$1" -At "${@:2}"; }

# fetch <url> [curl args] → F_CODE, F_CTYPE, F_BODY. Never fails: an unreachable server is code 000.
fetch() {
  local out
  out="$(probe curl -sS -m 5 -w '\n%{http_code} %{content_type}' "$@" 2>&1)" || true
  local meta="${out##*$'\n'}"
  F_BODY="${out%$'\n'*}"; [[ "$out" == *$'\n'* ]] || F_BODY=""
  F_CODE="${meta%% *}"; F_CTYPE="${meta#* }"
}
# json_ok <text> → 0 when Postgres parses it as JSON (no jq on the host: Oliva's rule).
# Needs the harness database up.
json_ok() { psql_db app -v "body=$1" >/dev/null 2>&1 <<< "SELECT :'body'::json;"; }

# migrate_run <log> [docker compose run args...] → the exit code of oliva-migrate.
migrate_run() {
  local log="$1" rc=0; shift
  dc run --rm --no-deps -T "$@" migrate > "$log" 2>&1 || rc=$?
  return $rc
}
# fingerprint <db> → the schema (pg_dump, without comments and the dump's random restrict
# key) plus an exact row count per table, written to $TMP/fp-<db>; prints its hash.
fingerprint() {
  local f="$TMP/fp-$1"
  { dc exec -T database pg_dump -U conformance --schema-only --no-owner --no-privileges "$1" \
      | awk '!/^--/ && !/^\\(un)?restrict / && NF'
    echo '-- row counts'
    psql_db "$1" <<'SQL'
SELECT format('SELECT %L, count(*) FROM %I.%I', schemaname || '.' || tablename, schemaname, tablename)
FROM pg_tables WHERE schemaname NOT IN ('pg_catalog', 'information_schema') ORDER BY 1 \gexec
SQL
  } > "$f"
  sha256sum < "$f" | cut -c1-16
}
tables_of() { awk '/^-- row counts/ { on = 1; next } on' "$TMP/fp-$1" | wc -l | tr -d ' '; }

echo
echo "── conformance: $IMAGE ──"
echo "   staging image: ${STAGING:-(none given)} · harness: $P · gateway trust shipped: standalone=$TRUST_PROD shared-infra=$TRUST_SHARED"
[[ -n "$SUFFIX" ]] && echo "   DATABASE_URL suffix: $SUFFIX"
echo

dc up -d --wait database probe > "$TMP/up.log" 2>&1 || { tail -n 8 "$TMP/up.log" >&2; die "the harness (database, probe) did not start"; }

# ── K5 (background: the unreachable case takes about a minute by design) ─────────
k5_run() {
  local name="$1" url="$2" start=$SECONDS rc=0
  timeout $((K5_BOUND + 15)) docker compose --env-file /dev/null --project-directory "$TMP" -p "$P" -f "$HARNESS" \
    run --rm --no-deps -T -e "DATABASE_URL=$url" migrate > "$TMP/k5-$name.log" 2>&1 || rc=$?
  echo "$rc $((SECONDS - start))" > "$TMP/k5-$name.rc"
}
# `probe` resolves on the harness network and listens on no 5432: connection refused, the
# "database not up (yet)" case. A wrong password: the case waiting cannot fix.
k5_run unreachable "$(db_url app probe)" & BG_PIDS+=($!)
k5_run badauth "$(db_url app database wrong-password)" & BG_PIDS+=($!)

# ── K3: fresh database, then again ────────────────────────────────────────────────
k3_ok=0
r1=0; migrate_run "$TMP/k3-1.log" || r1=$?
if (( r1 != 0 )); then
  result FAIL K3 mandatory "oliva-migrate on a fresh database exited $r1"
  tail_of "$TMP/k3-1.log"
else
  fp1="$(fingerprint app)"; cp "$TMP/fp-app" "$TMP/fp-app-1"
  r2=0; migrate_run "$TMP/k3-2.log" || r2=$?
  fp2="$(fingerprint app)"
  if (( r2 != 0 )); then
    result FAIL K3 mandatory "oliva-migrate exited 0, then $r2 on the second run (not idempotent)"
    tail_of "$TMP/k3-2.log"
  elif [[ "$fp1" != "$fp2" ]]; then
    result FAIL K3 mandatory "the second run exited 0 but changed the database (schema or row counts)"
    show_diff "$TMP/fp-app-1" "$TMP/fp-app"
  else
    k3_ok=1
    result PASS K3 mandatory "fresh database: exit 0; second run: exit 0, database unchanged (tables: $(tables_of app))"
  fi
fi

# ── K4: two at once ───────────────────────────────────────────────────────────────
dc exec -T database createdb -U conformance k4
ra=0; rb=0
migrate_run "$TMP/k4-a.log" -e "DATABASE_URL=$(db_url k4)" & pa=$!
migrate_run "$TMP/k4-b.log" -e "DATABASE_URL=$(db_url k4)" & pb=$!
wait "$pa" || ra=$?; wait "$pb" || rb=$?
rc_again=0; migrate_run "$TMP/k4-c.log" -e "DATABASE_URL=$(db_url k4)" || rc_again=$?
fp4="$(fingerprint k4)"
if (( ! k3_ok )); then
  result SKIP K4 mandatory "cannot judge: K3 (a single run) did not pass, so its failures would only repeat here"
elif (( ra != 0 && rb != 0 )); then
  result FAIL K4 mandatory "both concurrent runs failed (exit $ra and $rb): two deploys at once would both fail"
  tail_of "$TMP/k4-a.log" 4; tail_of "$TMP/k4-b.log" 4
elif (( rc_again != 0 )); then
  result FAIL K4 mandatory "concurrent runs exited $ra and $rb, then a re-run exited $rc_again: the race left the schema broken"
  tail_of "$TMP/k4-c.log"
elif [[ "$fp4" != "${fp1:-}" ]]; then
  result FAIL K4 mandatory "concurrent runs exited $ra and $rb but left a database different from a single run's (half-applied or applied twice)"
  show_diff "$TMP/fp-app" "$TMP/fp-k4"
else
  result PASS K4 mandatory "two at once: exit $ra and $rb; re-run exit 0; same database as a single run"
fi

# ── K6: the seed, absent from prod, present (and replacing) in staging ───────────
rc6=0; docker run --rm --entrypoint oliva-seed "$IMAGE" > "$TMP/k6-prod.log" 2>&1 || rc6=$?
if (( rc6 == 127 )); then
  result PASS K6 mandatory "prod: oliva-seed absent (not found, exit 127)"
else
  result FAIL K6 mandatory "prod: oliva-seed EXISTS in the production image (exit $rc6): seeding production must be impossible, not refused"
  tail_of "$TMP/k6-prod.log" 3
fi
if [[ -z "$STAGING" ]]; then
  result SKIP K6 mandatory "staging: no --staging image given, the staging half is not tested"
else
  dc exec -T database createdb -U conformance k6
  rm6=0; dc run --rm --no-deps -T -e "DATABASE_URL=$(db_url k6)" seed oliva-migrate > "$TMP/k6-migrate.log" 2>&1 || rm6=$?
  s1=0; s2=0
  if (( rm6 != 0 )); then
    result FAIL K6 mandatory "staging: oliva-migrate (needed before seeding) exited $rm6"
    tail_of "$TMP/k6-migrate.log"
  else
    dc run --rm --no-deps -T -e "DATABASE_URL=$(db_url k6)" seed > "$TMP/k6-1.log" 2>&1 || s1=$?
    fs1="$(fingerprint k6)"; cp "$TMP/fp-k6" "$TMP/fp-k6-1"
    dc run --rm --no-deps -T -e "DATABASE_URL=$(db_url k6)" seed > "$TMP/k6-2.log" 2>&1 || s2=$?
    fs2="$(fingerprint k6)"
    if (( s1 == 127 )); then
      result FAIL K6 mandatory "staging: oliva-seed absent from the staging image"
    elif (( s1 != 0 || s2 != 0 )); then
      result FAIL K6 mandatory "staging: oliva-seed exited $s1, then $s2"
      tail_of "$TMP/k6-1.log" 4; (( s2 )) && tail_of "$TMP/k6-2.log" 4
    elif [[ "$fs1" != "$fs2" ]]; then
      result FAIL K6 mandatory "staging: seeding twice gave different data: it adds to the data instead of replacing it"
      show_diff "$TMP/fp-k6-1" "$TMP/fp-k6"
    else
      result PASS K6 mandatory "staging: oliva-seed exit 0, twice, same data both times (replaces, does not add)"
    fi
  fi
fi

# ── K1: the server ────────────────────────────────────────────────────────────────
dc up -d --no-deps backend gateway > "$TMP/up.log" 2>&1 || { tail -n 8 "$TMP/up.log" >&2; die "the backend container could not be created"; }
deadline=$((SECONDS + HEALTH_WAIT))
while :; do
  fetch http://backend:80/health
  [[ "$F_CODE" == 200 ]] && break
  if [[ "$(docker inspect -f '{{.State.Running}}' "$(dc ps -aq backend)" 2>/dev/null)" != true ]] || (( SECONDS >= deadline )); then break; fi
  sleep 1
done
k1_ok=0
if [[ "$F_CODE" != 200 ]]; then
  result FAIL K1 mandatory "GET http://backend:80/health → ${F_CODE:-000} after ${HEALTH_WAIT}s at most (expected 200)"
  dc logs --no-color --tail 6 backend 2>/dev/null | sed 's/^/                    | /'
elif [[ "$F_CTYPE" != application/json* ]]; then
  result FAIL K1 mandatory "GET /health → 200 but Content-Type '${F_CTYPE}' (expected application/json)"
elif ! json_ok "$F_BODY"; then
  result FAIL K1 mandatory "GET /health → 200 application/json, but the body is not JSON: ${F_BODY:0:80}"
else
  direct_body="$F_BODY"
  fetch http://gateway:80/health
  if [[ "$F_CODE" != 200 || "$F_CTYPE" != application/json* ]]; then
    result FAIL K1 mandatory "direct /health is fine, but through Oliva's gateway → $F_CODE '$F_CTYPE'"
  else
    k1_ok=1
    result PASS K1 mandatory "GET /health on :80: 200 application/json ${direct_body:0:40}, direct and through the gateway"
  fi
fi

# ── K9: a request shows in the logs ───────────────────────────────────────────────
if (( k1_ok )); then
  token="oliva-conformance-$(openssl rand -hex 6)"
  # The Z matters: without a zone, `docker logs --since` reads the time as the host's LOCAL
  # time (measured): on a UTC-3 host it pointed 3 h ahead and saw nothing, on a UTC+ host it
  # would reach back into the startup logs and pass a backend that never logs a request.
  since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  sleep 1
  fetch "http://backend:80/api/$token"
  sleep 2
  logs="$(docker logs --since "$since" "$(dc ps -q backend)" 2>&1)"
  if grep -q "$token" <<< "$logs"; then
    result PASS K9 recommended "a request to /api/$token shows on stdout/stderr"
  elif [[ -n "$logs" ]]; then
    result PASS K9 recommended "the server wrote to stdout/stderr after a request (the request path itself does not appear)"
  else
    result FAIL K9 recommended "nothing on stdout/stderr after a request: logs that only live inside the container are lost with it"
  fi
else
  result SKIP K9 recommended "needs a server that answers (K1)"
fi

# ── K10: the gateway's half of X-Forwarded-For ────────────────────────────────────
dc up -d --wait --no-deps echo > "$TMP/up.log" 2>&1 || { tail -n 8 "$TMP/up.log" >&2; die "the echo upstream of K10 did not start"; }
dc up -d --no-deps gateway-standalone gateway-shared > "$TMP/up.log" 2>&1 || { tail -n 8 "$TMP/up.log" >&2; die "the K10 gateways did not start"; }
probe_ip="$(probe hostname -i | tr -d '\r' | awk '{print $1}')"
for _ in $(seq 1 30); do fetch http://gateway-standalone:80/api/xff; [[ "$F_CODE" == 200 ]] && break; sleep 0.5; done
fetch http://gateway-standalone:80/api/xff -H 'X-Forwarded-For: 6.6.6.6'; xff_alone="$F_BODY"; code_alone="$F_CODE"
for _ in $(seq 1 30); do fetch http://gateway-shared:80/api/xff; [[ "$F_CODE" == 200 ]] && break; sleep 0.5; done
fetch http://gateway-shared:80/api/xff -H 'X-Forwarded-For: 6.6.6.6'; xff_shared="$F_BODY"; code_shared="$F_CODE"
if [[ "$code_alone" != 200 || "$code_shared" != 200 ]]; then
  result FAIL K10 mandatory "the gateway did not proxy to the echo upstream ($code_alone / $code_shared)"
elif [[ "$xff_alone" == *6.6.6.6* ]]; then
  result FAIL K10 mandatory "standalone production (trust '$TRUST_PROD'): a forged X-Forwarded-For from $probe_ip reached the backend as '$xff_alone'. Anyone can pick their IP"
elif [[ "$xff_alone" != "$probe_ip" ]]; then
  result FAIL K10 mandatory "standalone production: the backend got X-Forwarded-For '$xff_alone', expected the peer's address $probe_ip"
elif [[ "$xff_shared" != 6.6.6.6,* ]]; then
  result FAIL K10 mandatory "shared infra (trust '$TRUST_SHARED'): the edge proxy's client address was dropped ('$xff_shared'): every request would look like it came from the edge"
else
  result PASS K10 mandatory "forged X-Forwarded-For dropped in standalone production ('$xff_alone'), the edge's kept in shared infra ('$xff_shared')"
fi

# ── K2: liveness without the database ─────────────────────────────────────────────
if (( k1_ok )); then
  dc stop -t "$GRACE" database >/dev/null 2>&1
  k2_bodies=() k2_fail=""
  for i in 1 2 3; do
    fetch http://backend:80/health
    if [[ "$F_CODE" != 200 || "$F_CTYPE" != application/json* ]]; then k2_fail="request $i → $F_CODE '$F_CTYPE'"; break; fi
    k2_bodies+=("$F_BODY")
    sleep 1
  done
  dc start database >/dev/null 2>&1; dc up -d --wait database >/dev/null 2>&1 || true
  if [[ -z "$k2_fail" ]]; then
    for b in "${k2_bodies[@]}"; do json_ok "$b" || { k2_fail="the body is not JSON: ${b:0:80}"; break; }; done
  fi
  if [[ -n "$k2_fail" ]]; then
    result FAIL K2 mandatory "with the database stopped, /health fails ($k2_fail): liveness must not touch the database"
  else
    result PASS K2 mandatory "database stopped: /health still 200 application/json (3 requests over 3 s)"
  fi
else
  result SKIP K2 mandatory "needs a server that answers (K1)"
fi

# ── K7: SIGTERM to the idle server ────────────────────────────────────────────────
cid="$(dc ps -q backend)"
if [[ -n "$cid" ]]; then
  # Compose sends the image's STOPSIGNAL, SIGTERM unless the image says otherwise; a deploy
  # does the same, so that is what is tested, and named when it is not SIGTERM.
  sig="$(docker inspect -f '{{.Config.StopSignal}}' "$cid")"; sig="${sig:-SIGTERM}"
  t0=$(now_ms)
  dc stop -t "$GRACE" backend >/dev/null 2>&1
  ms=$(( $(now_ms) - t0 ))
  code="$(docker inspect -f '{{.State.ExitCode}}' "$cid")"
  secs="$((ms / 1000)).$((ms % 1000 / 100))"
  [[ "$sig" == SIGTERM || "$sig" == 15 ]] || secs+="; the image's stop signal is $sig"
  case "$code" in
    0|143) result PASS K7 mandatory "SIGTERM: exited $code in ${secs}s (grace period ${GRACE}s)" ;;
    137) result FAIL K7 mandatory "SIGTERM ignored: killed by SIGKILL after ${secs}s (exit 137). Every deploy waits ${GRACE}s and kills it" ;;
    *) result FAIL K7 mandatory "SIGTERM: exited $code in ${secs}s (expected 0, or 143 for the default action of SIGTERM)" ;;
  esac
else
  result SKIP K7 mandatory "the server is not running (see K1)"
fi

# ── K5: collect the background runs ──────────────────────────────────────────────
for pid in "${BG_PIDS[@]}"; do wait "$pid" 2>/dev/null || true; done
BG_PIDS=()
k5_fail="" k5_unreachable="" k5_badauth=""
for name in unreachable badauth; do
  read -r rc secs 2>/dev/null < "$TMP/k5-$name.rc" || { rc=x; secs=0; }
  label="$([[ $name == unreachable ]] && echo "unreachable database" || echo "wrong password")"
  if [[ "$rc" == 124 ]]; then
    k5_fail+="${k5_fail:+; }$label: still running after ${secs}s (bound ${K5_BOUND}s)"
  elif [[ "$rc" == 0 ]]; then
    k5_fail+="${k5_fail:+; }$label: exit 0, a failure reported as success"
  elif [[ "$rc" == x ]]; then
    k5_fail+="${k5_fail:+; }$label: no result recorded"
  elif (( secs > K5_BOUND )); then
    k5_fail+="${k5_fail:+; }$label: exit $rc but after ${secs}s (bound ${K5_BOUND}s)"
  fi
  printf -v "k5_$name" '%s' "exit $rc in ${secs}s"
done
if [[ -n "$k5_fail" ]]; then
  result FAIL K5 mandatory "$k5_fail"
  tail_of "$TMP/k5-unreachable.log" 2; tail_of "$TMP/k5-badauth.log" 2
else
  result PASS K5 mandatory "unreachable database: $k5_unreachable; wrong password: $k5_badauth (bound ${K5_BOUND}s)"
fi

# ── K8: derived from every run above ──────────────────────────────────────────────
if [[ -n "$SUFFIX" ]]; then
  result FAIL K8 recommended "not met: every DATABASE_URL carried '$SUFFIX' (--db-url-suffix); libpq and most non-PHP drivers refuse driver-specific parameters"
elif (( k3_ok )); then
  result PASS K8 recommended "every run used a plain postgresql:// URL (no parameters)"
else
  result FAIL K8 recommended "unknown: K3 failed with a plain URL. If the backend needs URL parameters, rerun with --db-url-suffix to test the rest"
fi

# ── Declared clauses ──────────────────────────────────────────────────────────────
result DECLARED D1 declared "trusted proxies, backend half: declared, not tested here (verified for the default at release)"
result DECLARED D2 declared "in-flight draining on SIGTERM: declared, not tested here (verified for the default at release)"

echo
if (( MANDATORY_FAIL )); then
  echo "   NOT CONFORMANT: a mandatory clause failed. The contract: docs/oliva/backend-contract.md"
  exit 1
elif (( MANDATORY_SKIP )); then
  echo "   INCOMPLETE: no mandatory clause failed, but at least one was not tested (SKIP above)."
  exit 2
fi
echo "   CONFORMANT: every mandatory clause passed. The contract: docs/oliva/backend-contract.md"
