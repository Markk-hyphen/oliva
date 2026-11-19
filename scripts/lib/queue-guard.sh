# shellcheck shell=bash
#
# Queue guards (docs/roadmap/epics/E-queue-slot.md). Sourced after lib/env-check.sh, whose
# readers of the resolved configuration it uses (_ec_services, _ec_service_env). Static:
# they read files and what Compose resolves, never a container, so a deploy can run them
# before `down`, while the old stack still serves.
#
# A queue is a broker and a consumer, and both can go wrong without a word:
#   - messages routed to an asynchronous transport and nothing consuming them (profile
#     `queues` off). Standalone has no broker either, so every dispatch throws and the
#     user's action is lost; shared infra keeps its broker, so messages pile up silently.
#   - a worker consuming someone else's messages. Every app inherits the same queue names
#     from Oliva, so staging on production's vhost, or two apps on the default vhost "/" of
#     the shared broker, eat each other's messages. Measured during the epic.
#
#   queue_guard COMPOSE...                    → 0 fine or not applicable, 1 problem (stderr)
#   queue_guard_staging PROD_CONFIG COMPOSE... → 1 when staging's worker would consume
#                                                production's queues (PROD_CONFIG: the
#                                                output of `config` for the prod stack)
#
# OLIVA_QUEUE_CONSUMER=external, in this machine's .env, declares that the messages are
# consumed outside this stack (another service or host). It is a replaced slot: every
# check passes, and says so out loud.
#
# What it reads: the main `framework:` block of backend/config/packages/messenger.yaml
# (not `when@...` blocks, not other files) and #[AsMessage(...)] attributes in backend/src.
# A DSN written as %env(NAME)% is resolved against the backend's resolved environment.

QG_MESSENGER="backend/config/packages/messenger.yaml"

# Transports and routes of messenger.yaml: "T<TAB>name<TAB>dsn" and "R<TAB>transport".
_qg_yaml() {
  [[ -f "$QG_MESSENGER" ]] || return 0
  awk -v q="'" '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    function unq(s) {
      s = trim(s)
      if ((substr(s, 1, 1) == q && substr(s, length(s)) == q) || s ~ /^".*"$/) s = substr(s, 2, length(s) - 2)
      return s
    }
    function routes(v,   a, k, m) {
      v = trim(v)
      if (v == "") return
      if (v ~ /^\[.*\]$/) {
        m = split(substr(v, 2, length(v) - 2), a, ",")
        for (k = 1; k <= m; k++) if (unq(a[k]) != "") print "R\t" unq(a[k])
      } else print "R\t" unq(v)
    }
    /^[ \t]*(#|$)/ { next }
    {
      line = $0; sub(/[ \t]+#.*$/, "", line)
      match(line, /^ */); ind = RLENGTH; body = substr(line, ind + 1)
      if (ind == 0) { top = body; n = 0; next }
      if (top != "framework:") next
      if (substr(body, 1, 2) == "- ") {
        if (n == 3 && key[1] == "messenger" && key[2] == "routing") print "R\t" unq(substr(body, 3))
        next
      }
      i = index(body, ":"); if (i == 0) next
      k = unq(substr(body, 1, i - 1)); v = substr(body, i + 1)
      while (n > 0 && kind[n] >= ind) n--
      n++; kind[n] = ind; key[n] = k
      if (key[1] != "messenger") next
      if (n == 3 && key[2] == "transports" && trim(v) != "") print "T\t" k "\t" unq(v)
      if (n == 4 && key[2] == "transports" && k == "dsn") print "T\t" key[3] "\t" unq(v)
      if (n == 3 && key[2] == "routing") routes(v)
    }
  ' "$QG_MESSENGER"
}

# Routes declared with #[AsMessage('transport')] or #[AsMessage(transport: [...])], on one
# line or several: every quoted string inside the attribute is a transport name.
_qg_attributes() {
  [[ -d backend/src ]] || return 0
  local f
  grep -rlE '#\[AsMessage\(' backend/src 2>/dev/null | while IFS= read -r f; do
    tr '\n' ' ' < "$f" | grep -oP '#\[AsMessage\(.*?\)\]' | grep -oE "'[^']+'|\"[^\"]+\"" | tr -d "'\""
  done | sed 's/^/R\t/'
}

# The backend's resolved environment, from a `config` output.
declare -gA QG_ENV=()
_qg_load_env() {
  QG_ENV=()
  local name val
  while IFS=$'\t' read -r name val; do [[ -n "$name" ]] && QG_ENV[$name]="$val"; done < <(_ec_service_env backend <<< "$1")
}

# %env(NAME)% and %env(processor:NAME)% → the resolved value.
_qg_resolve() {
  local v="$1" name
  while [[ "$v" =~ %env\(([^\)]*)\)% ]]; do
    name="${BASH_REMATCH[1]##*:}"
    v="${v/"${BASH_REMATCH[0]}"/${QG_ENV[$name]:-}}"
  done
  printf '%s' "$v"
}

# amqp://user:pass@host:port/vhost?opts → "host:port|vhost", the default vhost as "/"
# (empty, "/" or "%2f"). Never carries credentials.
_qg_endpoint() {
  local rest="${1#*://}" hostport vhost=""
  rest="${rest##*@}"; rest="${rest%%\?*}"
  hostport="${rest%%/*}"
  [[ "$rest" == */* ]] && vhost="${rest#*/}"
  vhost="${vhost//%2[fF]//}"
  [[ -z "$vhost" ]] && vhost="/"
  [[ "$hostport" == *:* ]] || hostport="$hostport:5672"
  printf '%s|%s' "$hostport" "$vhost"
}

# Fills QG_DSN (transport → resolved DSN) and QG_ROUTED (routed transport names, unique)
# from the files and QG_ENV.
declare -gA QG_DSN=()
declare -ga QG_ROUTED=()
_qg_read() {
  QG_DSN=(); QG_ROUTED=()
  local kind a b seen=" "
  while IFS=$'\t' read -r kind a b; do
    case "$kind" in
      T) QG_DSN[$a]="$(_qg_resolve "$b")" ;;
      R) [[ "$seen" == *" $a "* ]] || { QG_ROUTED+=("$a"); seen+="$a "; } ;;
    esac
  done < <(_qg_yaml; _qg_attributes)
}

_qg_is_amqp() { [[ "${1%%:*}" == amqp || "${1%%:*}" == amqps ]]; }

queue_guard() {
  local cfg services name dsn ep
  local -a async=() on_default=()
  cfg="$("$@" config 2>/dev/null)" || return 0
  services=" $(_ec_services <<< "$cfg" | tr '\n' ' ')"
  _qg_load_env "$cfg"
  _qg_read

  # A route is asynchronous unless its transport is sync:// or in-memory://. A transport
  # this file does not define counts as asynchronous: it is going somewhere. The realtime
  # transports are the realtime relay's (profile `realtime`), not the `queues` worker's:
  # skip them, or an app with realtime but no queues would trip "queues with no consumer".
  for name in "${QG_ROUTED[@]}"; do
    case "$name" in realtime|realtime_failed) continue ;; esac
    dsn="${QG_DSN[$name]-unknown}"
    case "${dsn%%:*}" in sync|in-memory) ;; *) async+=("$name") ;; esac
  done

  if [[ "${QG_ENV[OLIVA_QUEUE_CONSUMER]:-}" == external ]]; then
    if (( ${#async[@]} )) || [[ "$services" == *" worker "* ]]; then
      echo "   queue: OLIVA_QUEUE_CONSUMER=external — the messages are consumed outside this stack." >&2
      echo "          Oliva does not check that anything consumes them, nor on which vhost." >&2
    fi
    return 0
  fi

  if (( ${#async[@]} )) && [[ "$services" != *" worker "* ]]; then
    cat >&2 <<EOF

!! ================================================================
!! QUEUES WITH NO CONSUMER: messages are routed to ${async[*]}
!! (asynchronous), but this stack runs no worker: the 'queues' profile
!! is off. Without a broker every dispatch fails; with an external one,
!! messages pile up and nothing handles them.
!!
!! Fix: in this machine's .env add queues to COMPOSE_PROFILES
!!   COMPOSE_PROFILES=queues          (or queues,cron)
!! If they are consumed outside this stack on purpose, declare it:
!!   OLIVA_QUEUE_CONSUMER=external
!! ================================================================

EOF
    return 1
  fi

  # A worker on an external broker (no local `rabbitmq` service): shared infra. On the
  # default vhost it shares every queue name with every other app on that broker.
  if [[ "$services" == *" worker "* && "$services" != *" rabbitmq "* ]]; then
    for name in "${!QG_DSN[@]}"; do
      dsn="${QG_DSN[$name]}"
      _qg_is_amqp "$dsn" || continue
      ep="$(_qg_endpoint "$dsn")"
      if [[ "${ep#*|}" == "/" ]]; then on_default+=("$name"); fi
    done
    if (( ${#on_default[@]} )); then
      cat >&2 <<EOF

!! ================================================================
!! SHARED VHOST: the worker would consume ${on_default[*]} on the
!! default vhost "/" of an external broker. Every app inherits the same
!! queue names from Oliva: apps on "/" consume each other's messages.
!!
!! Fix: give this app a vhost of its own, from ~/infra:
!!   ./scripts/provision-rabbitmq.sh <app> <app>_user
!! and put the RABBITMQ_DSN it prints in this machine's .env.
!! ================================================================

EOF
      return 1
    fi
  fi
  return 0
}

# The realtime relay (profile `realtime`) is the only publisher to the hub. An app that uses
# Mercure — code referencing Symfony\Component\Mercure in src — but runs no `realtime` service
# would publish nowhere: the gateway answers 502 on /.well-known/mercure and dispatched
# Updates pile up in the database. Static (file grep + resolved services), so the deploys can
# run it before `down`. The Update→realtime route in messenger.yaml is Oliva's default and is
# NOT the signal: an app that never publishes must not be forced to run the hub.
realtime_guard() {
  grep -rqlF 'Symfony\Component\Mercure' backend/src 2>/dev/null || return 0
  local cfg services
  cfg="$("$@" config 2>/dev/null)" || return 0
  services=" $(_ec_services <<< "$cfg" | tr '\n' ' ')"
  [[ "$services" == *" realtime "* ]] && return 0
  cat >&2 <<'EOF'

!! ================================================================
!! REALTIME USED WITH NO HUB: the app publishes to Mercure (code uses
!! Symfony\Component\Mercure) but this stack runs no 'realtime' service.
!! The gateway answers 502 on /.well-known/mercure and dispatched
!! updates pile up in the database, consumed by nothing.
!!
!! Fix: in this machine's .env add realtime to COMPOSE_PROFILES
!!   COMPOSE_PROFILES=realtime        (or realtime,queues,cron)
!! If realtime is consumed/served outside this stack on purpose, run
!! the hub there and point GATEWAY_REALTIME_UPSTREAM at it.
!! ================================================================

EOF
  return 1
}

queue_guard_staging() {
  local prod_cfg="$1"; shift
  local cfg name ep
  local -A staging_ep=()
  local -a shared=()
  cfg="$("$@" config 2>/dev/null)" || return 0
  [[ " $(_ec_services <<< "$cfg" | tr '\n' ' ')" == *" worker "* ]] || return 0

  _qg_load_env "$cfg"
  [[ "${QG_ENV[OLIVA_QUEUE_CONSUMER]:-}" == external ]] && return 0
  _qg_read
  for name in "${!QG_DSN[@]}"; do
    _qg_is_amqp "${QG_DSN[$name]}" && staging_ep[$name]="$(_qg_endpoint "${QG_DSN[$name]}")"
  done

  _qg_load_env "$prod_cfg"
  _qg_read
  for name in "${!staging_ep[@]}"; do
    _qg_is_amqp "${QG_DSN[$name]:-}" || continue
    ep="$(_qg_endpoint "${QG_DSN[$name]}")"
    [[ "$ep" == "${staging_ep[$name]}" ]] && shared+=("$name")
  done
  (( ${#shared[@]} )) || return 0

  cat >&2 <<EOF

!! ================================================================
!! STAGING ON PRODUCTION'S QUEUES: staging resolves the same broker and
!! vhost as production for ${shared[*]}. Its worker would consume
!! production's messages, against the staging database.
!!
!! Fix: give staging a vhost of its own, from ~/infra:
!!   ./scripts/provision-rabbitmq.sh <app>_staging <app>_staging_user
!! and put the RABBITMQ_DSN it prints in .env.staging.
!! ================================================================

EOF
  return 1
}
