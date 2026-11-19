# shellcheck shell=bash
#
# The environment contract, checked on what Compose RESOLVES (not on what a file says).
# Sourced: `source "$(dirname "$0")/lib/env-check.sh"`.
#
# Why resolved: until 1.6.0 `.env.backend` (tracked, loaded after `.env`) overrode the
# secrets of `.env` with values that are public in git. `.env` looked right and every check
# that read it would have passed. Only `docker compose config` shows what a service gets.
#
#   env_check <full|quiet> COMPOSE...   → 0 = no errors, 1 = at least one error
#       full   one line per active slot (./oliva env check, doctor)
#       quiet  only problems and replaced slots (guards: verify, deploy)
#   guard_env COMPOSE...                → env_check quiet, for run_upgrade_guards
#
# Per slot (docs/roadmap.md): the default asks for nothing, a replaced slot is announced,
# an absent slot prints nothing. Errors: a secret that is missing, a placeholder or
# publicly known; a secret in a tracked file; a secret reaching a service that doesn't own
# it; a value that contradicts the ones it is derived from; a JWT key that the resolved
# passphrase doesn't open. With CI=true, a secret that a person provides (value `-` in the
# manifest) is not required: CI has no real value for it. Stateful secrets (bound to a data volume) only warn: rotating
# them isn't one command, and the service isn't reachable from outside the app's network.
#
# What each variable is comes from the manifests: scripts/oliva/env.manifest (Oliva's) and
# ./env.manifest (the app's). Needs bash, awk, sha256sum and docker compose: it runs on
# the host, where there is no jq.

OLIVA_MANIFESTS=(scripts/oliva/env.manifest env.manifest)
OLIVA_PUBLIC_LIST="backend/frankenphp/known-public-secrets.sha256"
# Where the JWT private key can be: dev (bind mount of backend/config) and prod (./secrets).
OLIVA_JWT_KEYS=(backend/config/jwt/private.pem secrets/jwt/private.pem)

# ── Manifests ────────────────────────────────────────────────────────────────────
# Prints NAME<TAB>SLOT<TAB>KIND<TAB>VALUE for every variable; 1 (with the errors on
# stderr) on a malformed line.
oliva_manifest_rows() {
  local f rc=0
  for f in "${OLIVA_MANIFESTS[@]}"; do
    [[ -f "$f" ]] || continue
    awk -v f="$f" '
      /^[[:space:]]*(#|$)/ { next }
      { sub(/[[:space:]]+#.*$/, "") }
      NF < 4 { printf "ERROR: %s:%d: expected NAME SLOT KIND VALUE\n", f, NR > "/dev/stderr"; bad = 1; next }
      $3 !~ /^(secret|stateful|derived|plain)$/ {
        printf "ERROR: %s:%d: unknown kind \"%s\" (secret, stateful, derived, plain)\n", f, NR, $3 > "/dev/stderr"; bad = 1; next }
      { print $1 "\t" $2 "\t" $3 "\t" $4 }
      END { exit bad }' "$f" || rc=1
  done
  return $rc
}

# ── What counts as "no secret at all" ────────────────────────────────────────────
oliva_is_public() {
  [[ -f "$OLIVA_PUBLIC_LIST" ]] || return 1
  grep -q "^$(printf %s "$1" | sha256sum | cut -d' ' -f1) " "$OLIVA_PUBLIC_LIST"
}
oliva_is_placeholder() { [[ "$1" =~ ^(your_|generate_with_|changeme) || "$1" =~ _here$ || "$1" =~ ^\<.*\>$ ]]; }

# oliva_unhealthy <value> <was|is> → prints why and returns 0 if it can't stand as a secret.
oliva_unhealthy() {
  local verb="${2:-is}"
  if [[ -z "$1" ]]; then echo "$verb missing"
  elif oliva_is_placeholder "$1"; then echo "$verb a placeholder"
  elif oliva_is_public "$1"; then echo "$verb a publicly known value"
  else return 1; fi
}

# ── JWT key ──────────────────────────────────────────────────────────────────────
# Runs a shell snippet in the key's directory: directly when the files are ours, in a
# container (as root) when the backend created them. Passphrases travel in the
# environment (OLIVA_PIN / OLIVA_POUT), never on a command line.
_oliva_backend_base_image() { awk '/^FROM / && /frankenphp_upstream/ {print $2; exit}' backend/Dockerfile 2>/dev/null; }
oliva_in_keydir() {
  local key="$1" script="$2" dir
  dir="$(dirname "$key")"
  export OLIVA_PIN OLIVA_POUT
  if [[ -r "$key" && -w "$key" && -w "$dir" ]]; then
    (cd "$dir" && sh -c "$script") </dev/null 2>/dev/null
  else
    docker run --rm -u 0 -e OLIVA_PIN -e OLIVA_POUT -v "$(realpath "$dir"):/k" -w /k \
      --entrypoint sh "$(_oliva_backend_base_image)" -c "$script" </dev/null 2>/dev/null
  fi
}
# shellcheck disable=SC2016  # the snippet is expanded by the inner shell
oliva_key_opens() { OLIVA_PIN="$2" oliva_in_keydir "$1" 'openssl rsa -in private.pem -passin env:OLIVA_PIN -noout'; }

# ── Resolved configuration ───────────────────────────────────────────────────────
# Reads `docker compose config` (YAML) on stdin.
_ec_services() { awk '/^[^ ]/ { top = $0 } top == "services:" && /^  [^ ]/ { s = $1; sub(/:$/, "", s); print s }'; }

# _ec_service_env <service> → NAME<TAB>VALUE of its resolved environment.
_ec_service_env() {
  awk -v s="  $1:" -v q="'" '
    /^[^ ]/ { top = $0; insvc = 0; inenv = 0; next }
    top != "services:" { next }
    /^  [^ ]/ { insvc = ($0 == s); inenv = 0; next }
    !insvc { next }
    /^    [^ ]/ { inenv = ($0 == "    environment:"); next }
    inenv && /^      [^ ]/ {
      line = substr($0, 7); i = index(line, ":")
      name = substr(line, 1, i - 1); val = substr(line, i + 1); sub(/^ /, "", val)
      if (val == "null") val = ""
      else if (val ~ /^".*"$/) { val = substr(val, 2, length(val) - 2); gsub(/\\"/, "\"", val); gsub(/\\\\/, "\\", val) }
      else if (substr(val, 1, 1) == q && substr(val, length(val)) == q) { val = substr(val, 2, length(val) - 2); gsub(q q, q, val) }
      gsub(/\$\$/, "$", val)
      print name "\t" val
    }'
}

# Host of a URL-shaped value: scheme://user:pass@HOST:port/…
_ec_url_host() { [[ "$1" =~ @([^@/:?]+)(:[0-9]+)?(/|\?|$) ]] && printf '%s' "${BASH_REMATCH[1]}"; }

# The compose service that fills each slot by default, and the service a value points at.
_ec_slot_service() {
  case "$1" in
    backend|realtime) echo backend ;; database) echo database ;; queue) echo rabbitmq ;;
    scheduler) echo scheduler ;; gateway) echo gateway ;; frontend) echo frontend ;; *) echo "$1" ;;
  esac
}

# The host portion of a GATEWAY_*_UPSTREAM value (`host` or `host:port`).
_ec_upstream_host() { printf '%s' "${1%%:*}"; }

# ── The check ────────────────────────────────────────────────────────────────────
env_check() {
  local mode="$1"; shift
  local cfg rows services name slot kind rule val why src t host svc line f up
  local -A RES=() FE=() GW=() RT=() FILEV=() SLOT_ERR=() SLOT_WARN=() SLOT_SEEN=()
  local -a slot_order=() global_err=() global_warn=()
  local errors=0 leaked=""

  _err()  { SLOT_ERR[$1]+="$2"$'\n'; errors=1; }
  _warn() { SLOT_WARN[$1]+="$2"$'\n'; }

  if [[ ! -f .env ]]; then
    echo "!! env: there is no .env in $(basename "$PWD") → ./oliva env init" >&2
    return 1
  fi
  rows="$(oliva_manifest_rows)" || { echo "!! env: fix the manifest errors above and run again." >&2; return 1; }
  # If Compose can't resolve the configuration there is nothing reliable to assert.
  if ! cfg="$("$@" config 2>/dev/null)"; then
    echo "!! env: could not resolve the configuration ($* config failed): not checked." >&2
    return 0
  fi
  services=" $(_ec_services <<< "$cfg" | tr '\n' ' ')"

  while IFS=$'\t' read -r name val; do [[ -n "$name" ]] && RES[$name]="$val"; done < <(_ec_service_env backend <<< "$cfg")
  while IFS=$'\t' read -r name val; do [[ -n "$name" ]] && FE[$name]="$val"; done < <(_ec_service_env frontend <<< "$cfg")
  while IFS=$'\t' read -r name val; do [[ -n "$name" ]] && GW[$name]="$val"; done < <(_ec_service_env gateway <<< "$cfg")
  while IFS=$'\t' read -r name val; do [[ -n "$name" ]] && RT[$name]="$val"; done < <(_ec_service_env realtime <<< "$cfg")
  while IFS= read -r line; do
    [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
    name="${BASH_REMATCH[1]}"; val="${BASH_REMATCH[2]}"
    if [[ "$val" =~ ^\"(.*)\"$ || "$val" =~ ^\'(.*)\'$ ]]; then val="${BASH_REMATCH[1]}"; fi
    FILEV[$name]="$val"
  done < .env

  # Which slots are replaced: their URL points at something that isn't the default service.
  local -A REPLACED=()
  host="$(_ec_url_host "${RES[DATABASE_URL]:-}")"
  [[ -n "$host" && "$host" != database ]] && REPLACED[database]="$host"
  host="$(_ec_url_host "${RES[RABBITMQ_DSN]:-}")"
  [[ -n "$host" && "$host" != rabbitmq ]] && REPLACED[queue]="$host"
  # The gateway's "URL" per slot is GATEWAY_*_UPSTREAM resolved on the gateway
  # service itself (not on the backend). A value whose host is not Oliva's
  # default for that slot = REPLACED (the probe of E-unbundle-roles phase 3).
  up="$(_ec_upstream_host "${GW[GATEWAY_BACKEND_UPSTREAM]:-}")"
  [[ -n "$up" && "$up" != backend ]] && REPLACED[backend]="$up"
  up="$(_ec_upstream_host "${GW[GATEWAY_REALTIME_UPSTREAM]:-}")"
  # In 1.9.0 realtime still rides the backend; 1.10.0 moves this default to `realtime`.
  [[ -n "$up" && "$up" != backend && "$up" != realtime ]] && REPLACED[realtime]="$up"
  up="$(_ec_upstream_host "${GW[GATEWAY_FRONTEND_UPSTREAM]:-}")"
  [[ -n "$up" && "$up" != frontend ]] && REPLACED[frontend]="$up"

  # A URL that points at Oliva's own service while that service isn't in this stack goes
  # nowhere (shared infra with the standalone DATABASE_URL still in .env). The backend
  # would only find out at boot, after the old stack is down.
  if [[ "$(_ec_url_host "${RES[DATABASE_URL]:-}")" == database && "$services" != *" database "* ]]; then
    global_err+=("DATABASE_URL points at the local \"database\" service, but this stack doesn't run it (shared infra?) → set DATABASE_URL in .env to the external database")
    errors=1
  fi

  # _fix <name> <fix> → the fix to print. When the resolved value isn't the one in .env,
  # fixing .env can't help: something overrides it, and that is the trap this file exists for.
  _fix() {
    if [[ "${FILEV[$1]:-}" == "${RES[$1]:-}" ]]; then echo "$2"; return 0; fi
    echo "this value does not come from .env: another env file (.env.backend?) or an \`environment:\` entry overrides it. Remove it there; secrets live in .env only"
  }

  while IFS=$'\t' read -r name slot kind rule; do
    svc="$(_ec_slot_service "$slot")"
    # Absent: the slot's service isn't in this stack and nothing points elsewhere. Silent.
    if [[ "$services" != *" $svc "* && -z "${REPLACED[$slot]:-}" ]]; then continue; fi
    [[ -n "${SLOT_SEEN[$slot]:-}" ]] || { SLOT_SEEN[$slot]=1; slot_order+=("$slot"); }
    val="${RES[$name]:-}"

    if [[ -n "${REPLACED[$slot]:-}" ]]; then
      # Replaced: only what Oliva still depends on, the connection value itself.
      if [[ "$kind" == derived ]] && { [[ -z "$val" ]] || [[ "$val" =~ (your_|PROVISIONED|\<[a-z_]+\>|changeme) ]]; }; then
        _err "$slot" "$name still has a placeholder in it → $(_fix "$name" "set the real connection value in .env")"
      fi
      continue
    fi

    case "$kind" in
      secret)
        if why="$(oliva_unhealthy "$val" is)"; then
          if [[ "$rule" == "-" && "${CI:-}" == true ]]; then
            # CI has no real value for a secret a person provides; everything else still applies.
            _warn "$slot" "$name $why (a person provides it; not required in CI)"
          elif [[ "$rule" == "-" ]]; then
            _err "$slot" "$name $why → $(_fix "$name" "set its real value in .env (a person provides this one)")"
          else
            _err "$slot" "$name $why → $(_fix "$name" "./oliva env init")"
          fi
        fi
        if [[ "$rule" == same:* && -n "$val" && "$val" != "${RES[${rule#same:}]:-}" ]]; then
          _err "$slot" "$name differs from ${rule#same:}: they must be the same value → set both to the same in .env"
        fi ;;
      stateful)
        if why="$(oliva_unhealthy "$val" is)"; then
          _warn "$slot" "$name $why. It is bound to the $slot data volume: ./oliva env init says how to rotate it."
        fi ;;
      derived)
        t="$rule"
        while [[ "$t" =~ \$\{([A-Za-z_][A-Za-z0-9_]*)\}(.*)$ ]]; do
          src="${BASH_REMATCH[1]}"; t="${BASH_REMATCH[2]}"
          if [[ -n "${RES[$src]:-}" && "$val" != *"${RES[$src]}"* ]]; then
            _err "$slot" "$name does not carry the value of $src: the service and the app would disagree → fix $name in .env (or delete the line and run ./oliva env init)"
            break
          fi
        done ;;
    esac

    # A secret has one owner. The frontend serves files, the gateway only routes, and the
    # realtime hub owns only its Mercure key: none should receive another slot's secret.
    if [[ "$kind" != plain && "$slot" != frontend && "$slot" != gateway ]]; then
      [[ -n "${FE[$name]+x}" ]] && leaked+="frontend:$name "
      [[ -n "${GW[$name]+x}" ]] && leaked+="gateway:$name "
      [[ "$slot" != realtime && -n "${RT[$name]+x}" ]] && leaked+="realtime:$name "
    fi
  done <<< "$rows"

  # The backend/relay POST updates to MERCURE_URL. With a `realtime` hub in the stack, a
  # MERCURE_URL still pointing at the backend itself (the pre-1.10.0 default) makes the
  # backend publish to a path it no longer serves: updates go nowhere, silently. MERCURE_URL
  # has no credentials (scheme://host/path), so parse the host by expansion, not _ec_url_host.
  if [[ "$services" == *" realtime "* ]]; then
    local murl="${RES[MERCURE_URL]:-}"
    murl="${murl#*://}"; murl="${murl%%/*}"; murl="${murl##*@}"; murl="${murl%%:*}"
    case "$murl" in
      localhost|127.0.0.1|backend)
        global_err+=("MERCURE_URL resolves to \"$murl\", but the hub is the \"realtime\" service → set MERCURE_URL to http://realtime/.well-known/mercure in .env.backend")
        errors=1 ;;
    esac
  fi

  # SYMFONY_TRUSTED_PROXIES=PRIVATE_SUBNETS is baked into the backend image.
  # SYMFONY_TRUSTED_HEADERS is left unset on purpose (= `for, port, proto`); an
  # EMPTY value makes Symfony throw at boot with no useful message. Flag it.
  if [[ -n "${RES[SYMFONY_TRUSTED_HEADERS]+x}" && -z "${RES[SYMFONY_TRUSTED_HEADERS]:-}" ]]; then
    global_err+=("SYMFONY_TRUSTED_HEADERS is set to an empty value: Symfony throws at boot → remove the line (unset = the default: for, port, proto)")
    errors=1
  fi

  if [[ -n "$leaked" ]]; then
    global_err+=("a service receives a secret it has no use for (${leaked% }) → the frontend's env_file is .env.frontend only and the gateway has none: take .env out of either")
    errors=1
  fi

  # Secrets in tracked files: public the moment they are pushed, and they override .env.
  if git rev-parse --git-dir >/dev/null 2>&1; then
    while IFS= read -r f; do
      [[ -f "$f" ]] || continue
      while IFS=$'\t' read -r name slot kind rule; do
        [[ "$kind" == secret || "$kind" == stateful ]] || continue
        val="$(sed -nE "s/^$name=//p" "$f" | tail -1)"
        if [[ "$val" =~ ^\"(.*)\"$ || "$val" =~ ^\'(.*)\'$ ]]; then val="${BASH_REMATCH[1]}"; fi
        [[ -z "$val" ]] && continue
        oliva_is_placeholder "$val" && continue
        oliva_is_public "$val" && continue
        global_err+=("$name has a real value in $f, which is tracked by git → move it to .env (gitignored), leave a placeholder there, and rotate it if it was ever pushed")
        errors=1
      done <<< "$rows"
    done < <(git ls-files 2>/dev/null | grep -E '(^|/)\.env[^/]*$')
  fi

  # The JWT private key must open with the passphrase the backend will get.
  if [[ -n "${RES[JWT_PASSPHRASE]:-}" ]]; then
    for f in "${OLIVA_JWT_KEYS[@]}"; do
      [[ -e "$f" ]] || continue
      if [[ ! -r "$f" ]] && ! docker version >/dev/null 2>&1; then
        global_warn+=("$f is owned by root and Docker isn't reachable: could not check that JWT_PASSPHRASE opens it")
      elif ! oliva_key_opens "$f" "${RES[JWT_PASSPHRASE]}"; then
        global_err+=("JWT_PASSPHRASE does not open $f: every login would fail → ./oliva env init (it re-encrypts the key, same key pair)")
        errors=1
      fi
    done
  fi

  # Every manifest variable needs its placeholder in .env.example (what `env init` copies).
  if [[ -f .env.example ]]; then
    while IFS=$'\t' read -r name slot kind rule; do
      grep -qE "^$name=" .env.example || global_warn+=("$name is in a manifest but not in .env.example → add it there with a placeholder")
    done <<< "$rows"
  fi

  # A replaced slot must surface even with no manifest variables of its own (frontend and
  # gateway have none): otherwise REPLACED is computed and never shown. Append any replaced
  # slot not already in the manifest-driven order.
  for slot in "${!REPLACED[@]}"; do
    [[ -n "${SLOT_SEEN[$slot]:-}" ]] || { SLOT_SEEN[$slot]=1; slot_order+=("$slot"); }
  done

  # ── Output ──
  local printed=0 state
  for slot in "${slot_order[@]}"; do
    if [[ -n "${REPLACED[$slot]:-}" ]]; then
      state="REPLACED (points at \"${REPLACED[$slot]}\", not Oliva's $(_ec_slot_service "$slot") service): its credentials and data are not checked by Oliva"
    elif [[ -n "${SLOT_ERR[$slot]:-}${SLOT_WARN[$slot]:-}" ]]; then state="default"
    else
      [[ "$mode" == full ]] || continue
      state="default  ok"
    fi
    printf '   %-9s %s\n' "$slot" "$state"; printed=1
    [[ -n "${SLOT_ERR[$slot]:-}" ]]  && printf '%s' "${SLOT_ERR[$slot]}"  | sed 's/^/      !! /' >&2
    [[ -n "${SLOT_WARN[$slot]:-}" ]] && printf '%s' "${SLOT_WARN[$slot]}" | sed 's/^/      !  /' >&2
  done
  for line in "${global_err[@]}";  do echo "   !! $line" >&2; printed=1; done
  for line in "${global_warn[@]}"; do echo "   !  $line" >&2; printed=1; done
  [[ "$printed" == 0 && "$mode" == full ]] && echo "   nothing to check: no slot is active."
  return $errors
}

# For run_upgrade_guards (lib/upgrade-guards.sh): warns, never aborts.
guard_env() {
  local out rc=0
  out="$(env_check quiet "$@" 2>&1)" || rc=1
  [[ -n "$out" ]] || return $rc
  {
    echo
    echo "!! ================================================================"
    echo "!! ENV: the resolved environment of this stack"
    echo "$out"
    echo "!! ================================================================"
    echo
  } >&2
  return $rc
}
