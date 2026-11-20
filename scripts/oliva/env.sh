#!/usr/bin/env bash
#
# The environment contract of this checkout (docs/roadmap/epics/E-config-contract.md).
#
#   scripts/oliva/env.sh init            # create or repair .env: generate secrets, derive values
#   scripts/oliva/env.sh check [--prod]  # read-only: is what Compose resolves a sound environment?
#
# `check` looks at the stack `docker compose` resolves here (dev: base + override, or
# COMPOSE_FILE); --prod looks at the standalone production stack. Exits 1 on an error.
# The deploy scripts run the same check on their own stack (scripts/lib/env-check.sh).
#
# `init` replaces `cp .env.example .env`. It is safe to run again at any time:
#   - no .env        → created from .env.example, every secret generated, every derived
#                      value computed
#   - existing .env  → touches only what is missing, a placeholder or a publicly known
#                      value. A healthy value is never rewritten.
# It never prints a secret, and it keeps the previous file in .oliva/env.backup.
#
# What each variable is comes from the manifests: scripts/oliva/env.manifest (Oliva's)
# and ./env.manifest (the app's). Needs bash, awk, openssl and sha256sum; Docker only to
# reach a JWT key that the container created as root.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
source "$(dirname "$0")/../lib/env-check.sh"
require_repo_root

ENV_FILE=".env"
ENV_TEMPLATE=".env.example"
# Tracked files that have carried secret values: their git history is where a passphrase
# that still encrypts an existing key can come from.
SECRET_HISTORY_FILES=(.env.backend .env.example backend/.env)

declare -A ENVV=()      # current values of the env file
declare -A OLDV=()      # the values it had before this run
declare -A CHANGED=()   # names this run sets
REPORT=()
WARNINGS=()

# ── Env file ─────────────────────────────────────────────────────────────────────
load_env() {
  local line name val
  ENVV=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
    name="${BASH_REMATCH[1]}"; val="${BASH_REMATCH[2]}"
    if [[ "$val" =~ ^\"(.*)\"$ || "$val" =~ ^\'(.*)\'$ ]]; then val="${BASH_REMATCH[1]}"; fi
    ENVV[$name]="$val"
  done < "$1"
}

env_set() { ENVV[$1]="$2"; CHANGED[$1]=1; }

# Rewrites the env file with the changed values: in place where the variable exists,
# appended where it doesn't. Comments and order are kept.
write_env() {
  local kv tmp name
  kv="$(mktemp)"; tmp="$(mktemp)"
  for name in "${!CHANGED[@]}"; do printf '%s\t%s\n' "$name" "${ENVV[$name]}" >> "$kv"; done
  awk -F'\t' '
    FNR == NR { val[$1] = substr($0, length($1) + 2); pending[$1] = 1; next }
    { name = $0; sub(/=.*/, "", name) }
    $0 ~ /^[A-Za-z_][A-Za-z0-9_]*=/ && (name in val) { print name "=" val[name]; delete pending[name]; next }
    { print }
    END {
      n = 0; for (name in pending) n++
      if (n) { print ""; print "# Added by ./oliva env init"; for (name in pending) print name "=" val[name] }
    }' "$kv" "$ENV_FILE" > "$tmp"
  rm -f "$kv"
  mkdir -p .oliva
  if [[ -f "$ENV_FILE" && "${FRESH:-0}" != 1 ]]; then
    cp -p "$ENV_FILE" .oliva/env.backup; chmod 600 .oliva/env.backup
  fi
  cat "$tmp" > "$ENV_FILE"; rm -f "$tmp"
  chmod 600 "$ENV_FILE"
}

# ── Values ───────────────────────────────────────────────────────────────────────
unhealthy() { oliva_unhealthy "$1" was; }

generate() {   # gen:hexN
  [[ "$1" =~ ^gen:hex([0-9]+)$ ]] || die "manifest: unknown generator '$1' (use gen:hexN)"
  openssl rand -hex "${BASH_REMATCH[1]}"
}

# expand <template> [array] → replaces ${VAR} with the values of ENVV (or of <array>).
expand() {
  local t="$1" out=""
  local -n _vals="${2:-ENVV}"
  while [[ "$t" =~ ^([^$]*)\$\{([A-Za-z_][A-Za-z0-9_]*)\}(.*)$ ]]; do
    out+="${BASH_REMATCH[1]}${_vals[${BASH_REMATCH[2]}]:-}"; t="${BASH_REMATCH[3]}"
  done
  printf '%s' "$out$t"
}

note() { REPORT+=("$(printf '   %-28s %s' "$1" "$2")"); }
warn_later() { WARNINGS+=("$1"); }

# ── JWT key pair ─────────────────────────────────────────────────────────────────
# The private key is encrypted with JWT_PASSPHRASE. Changing the variable without
# re-encrypting the key breaks every login with no error at boot. So whenever the
# passphrase in .env doesn't open an existing key, the key is re-encrypted with it: same
# key pair, nobody is logged out.
#
# shellcheck disable=SC2016  # the snippet is expanded by the inner shell
key_reencrypt() {
  OLIVA_PIN="$2" OLIVA_POUT="$3" oliva_in_keydir "$1" '
    openssl rsa -in private.pem -passin env:OLIVA_PIN -aes256 -passout env:OLIVA_POUT -out private.pem.oliva-new \
      && cat private.pem.oliva-new > private.pem; rc=$?; rm -f private.pem.oliva-new; exit $rc'
}

# Passphrases that may still encrypt a key: the value .env had, and every value the
# variable ever had in a tracked file (before 1.6.0 the committed one was the effective one).
passphrase_candidates() {
  [[ -n "${1:-}" ]] && printf '%s\n' "$1"
  git log --all -p --format= -- "${SECRET_HISTORY_FILES[@]}" 2>/dev/null \
    | sed -nE 's/^[+-]JWT_PASSPHRASE=//p' | sed -E 's/^"(.*)"$/\1/' | awk 'NF && !seen[$0]++'
}

handle_jwt_passphrase() {
  local rule="$1" current="${ENVV[JWT_PASSPHRASE]:-}" desired why="" key cand old
  local -a keys=() plan=() blocked=()

  if why="$(unhealthy "$current")"; then desired="$(generate "$rule")"; else desired="$current"; fi
  for key in "${OLIVA_JWT_KEYS[@]}"; do [[ -e "$key" ]] && keys+=("$key"); done

  for key in "${keys[@]}"; do
    oliva_key_opens "$key" "$desired" && continue
    old=""
    while IFS= read -r cand; do
      if oliva_key_opens "$key" "$cand"; then old="$cand"; break; fi
    done < <(passphrase_candidates "$current")
    if [[ -n "$old" ]]; then plan+=("$key"$'\t'"$old"); else blocked+=("$key"); fi
  done

  if (( ${#blocked[@]} )); then
    # Nothing known opens the key: changing the passphrase can't help and could hide the
    # one that does. Leave everything as it is and say what to do.
    warn_later "JWT_PASSPHRASE not changed: no known passphrase opens ${blocked[*]}.
!!   If the key is owned by root, Docker must be running for this command to reach it.
!!   Otherwise the key is unusable as it is. To start over (logs every user out):
!!     delete the key pair (private.pem and public.pem) and run ./oliva env init again;
!!     ./oliva env init then generates a new pair."
    note JWT_PASSPHRASE "NOT changed (see below)"
    return 1
  fi

  for cand in "${plan[@]}"; do
    key="${cand%%$'\t'*}"; old="${cand#*$'\t'}"
    # shellcheck disable=SC2015  # either step failing must stop here
    key_reencrypt "$key" "$old" "$desired" && oliva_key_opens "$key" "$desired" \
      || die "could not re-encrypt $key. Nothing was written to $ENV_FILE."
    note "$key" "re-encrypted with the passphrase of $ENV_FILE (same key pair)"
  done
  if [[ "$desired" != "$current" ]]; then
    env_set JWT_PASSPHRASE "$desired"; note JWT_PASSPHRASE "generated ($why)"
  fi
  return 0
}

# ── JWT key pair: where it lives, and its birth ──────────────────────────────────
# Since 1.11.0 the pair lives in ./secrets/jwt in every environment (gitignored, mounted
# read-only into every PHP service) and is created HERE, not by the backend at boot. At boot
# it came out root-owned in production, only the server container had it, and an app whose
# backend never started had none.
JWT_DIR="secrets/jwt"
JWT_LEGACY_DIR="backend/config/jwt"   # where dev kept it before 1.11.0

# A directory the backend container created as root (older production stacks, or a
# `docker compose up` that ran before this): give it back to the host user, through a
# container since the host user can't. Nothing else here needs root.
reclaim_dir() {
  local dir="$1"
  # Not writable, or a key in it the host user cannot read: the dev backend runs as that
  # user, so a root-owned 0600 key there means every login fails (measured on a checkout
  # that had run the production stack before 1.11.0).
  [[ -d "$dir" ]] || return 0
  if [[ -w "$dir" ]] && { [[ ! -e "$dir/private.pem" ]] || [[ -r "$dir/private.pem" && -w "$dir/private.pem" ]]; }; then
    return 0
  fi
  docker run --rm -u 0 -v "$(realpath "$dir"):/k" --entrypoint chown "$(_oliva_backend_base_image)" \
    -R "$(id -u):$(id -g)" /k </dev/null >/dev/null 2>&1 \
    || die "$dir is owned by root and Docker could not give it back. Fix by hand: sudo chown -R $(id -u):$(id -g) $dir"
  note "$dir" "was owned by root: given back to $(id -un)"
}

provision_jwt_keys() {
  local pass="${ENVV[JWT_PASSPHRASE]:-}"
  if [[ -e "$JWT_DIR/private.pem" ]]; then reclaim_dir "$JWT_DIR"; return 0; fi
  # A dev pair from before 1.11.0: move it, same keys, nobody is logged out.
  if [[ -f "$JWT_LEGACY_DIR/private.pem" ]]; then
    reclaim_dir "$JWT_LEGACY_DIR"; mkdir -p "$JWT_DIR"; reclaim_dir "$JWT_DIR"
    mv "$JWT_LEGACY_DIR/private.pem" "$JWT_DIR/private.pem"
    [[ -f "$JWT_LEGACY_DIR/public.pem" ]] && mv "$JWT_LEGACY_DIR/public.pem" "$JWT_DIR/public.pem"
    note "$JWT_DIR" "key pair moved here from $JWT_LEGACY_DIR (same keys)"
    return 0
  fi
  oliva_unhealthy "$pass" is >/dev/null && return 0   # no usable passphrase: reported above
  mkdir -p "$JWT_DIR"; reclaim_dir "$JWT_DIR"
  ( umask 077
    OLIVA_PIN="$pass" openssl genrsa -aes256 -passout env:OLIVA_PIN -out "$JWT_DIR/private.pem" 2048 2>/dev/null
    OLIVA_PIN="$pass" openssl rsa -pubout -in "$JWT_DIR/private.pem" -passin env:OLIVA_PIN -out "$JWT_DIR/public.pem" 2>/dev/null
  ) || die "could not generate the JWT key pair in $JWT_DIR"
  chmod 600 "$JWT_DIR/private.pem"; chmod 644 "$JWT_DIR/public.pem"
  note "$JWT_DIR" "key pair generated (encrypted with JWT_PASSPHRASE)"
}

# ── Data volumes ─────────────────────────────────────────────────────────────────
# A stateful secret is only "stored" once its service has started on a data volume.
# existing_volume <volume> → 0 and its full name if it exists, 1 if it doesn't, 2 if
# Docker can't be asked (then nothing can be assumed).
existing_volume() {
  local project="${COMPOSE_PROJECT_NAME:-${ENVV[COMPOSE_PROJECT_NAME]:-}}" all
  [[ -n "$project" ]] || project="$(basename "$PWD" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')"
  all="$(docker volume ls -q 2>/dev/null)" || return 2
  grep -qx "${project}_$1" <<< "$all" || return 1
  echo "${project}_$1"
}
volume_of() { case "$1" in database) echo db_data ;; queue) echo rabbitmq_data ;; esac; }

# ── init ─────────────────────────────────────────────────────────────────────────
cmd_init() {
  local rows name slot kind rule why vol volrc target computed failed=0
  command -v openssl >/dev/null || die "openssl is required."
  command -v sha256sum >/dev/null || die "sha256sum is required."
  rows="$(oliva_manifest_rows)" || die "fix the manifest and run again."

  FRESH=0
  if [[ ! -f "$ENV_FILE" ]]; then
    [[ -f "$ENV_TEMPLATE" ]] || die "$ENV_TEMPLATE not found: nothing to start from."
    cp "$ENV_TEMPLATE" "$ENV_FILE"; chmod 600 "$ENV_FILE"; FRESH=1
    info "$ENV_FILE created from $ENV_TEMPLATE"
  fi
  load_env "$ENV_FILE"
  # shellcheck disable=SC2034  # OLDV is read through the nameref of expand()
  for name in "${!ENVV[@]}"; do OLDV[$name]="${ENVV[$name]}"; done

  # 1. Secrets and stateful secrets.
  while IFS=$'\t' read -r name slot kind rule; do
    case "$kind" in
      secret)
        if [[ "$name" == JWT_PASSPHRASE ]]; then handle_jwt_passphrase "$rule" || failed=1; continue; fi
        why="$(unhealthy "${ENVV[$name]:-}")" || continue
        case "$rule" in
          gen:*)  env_set "$name" "$(generate "$rule")"; note "$name" "generated ($why)" ;;
          same:*) : ;;   # second pass: its source may not be set yet
          *)      note "$name" "NEEDS A VALUE from you ($why): set it in $ENV_FILE" ;;
        esac ;;
      stateful)
        why="$(unhealthy "${ENVV[$name]:-}")" || continue
        volrc=0; vol="$(existing_volume "$(volume_of "$slot")")" || volrc=$?
        if [[ "$FRESH" == 1 || -z "${ENVV[$name]:-}" || "$volrc" == 1 ]]; then
          # Nothing has stored this value yet (or there is no value to keep).
          env_set "$name" "$(generate "$rule")"; note "$name" "generated ($why)"
          [[ "$volrc" == 0 ]] && warn_later "$name was generated, but the volume $vol already exists:
!!   the $slot service keeps the password it was first started with, not this one.
!!   Either set $name to that password, or (disposable data only) remove the volume:
!!     docker compose down -v"
        else
          if [[ "$volrc" == 0 ]]; then vol="the volume $vol holds it"; else vol="Docker isn't reachable to see whether a data volume holds it"; fi
          note "$name" "NOT changed ($why; $vol)"
          warn_later "$name ${why/was/is} and was left alone: the $slot service stores it the
!!   first time it starts, so changing it here alone locks the app out of its own data.
!!   To rotate: change the password inside the service first, then set the same value
!!   here and in the variables derived from it. Disposable data: docker compose down -v
!!   and run ./oliva env init again."
        fi ;;
    esac
  done <<< "$rows"

  # 2. Values that must equal another.
  while IFS=$'\t' read -r name slot kind rule; do
    [[ "$rule" == same:* ]] || continue
    target="${rule#same:}"
    if [[ -n "${CHANGED[$target]:-}" ]] || unhealthy "${ENVV[$name]:-}" >/dev/null; then
      [[ "${ENVV[$name]:-}" == "${ENVV[$target]:-}" ]] && continue
      env_set "$name" "${ENVV[$target]:-}"; note "$name" "= $target"
    fi
  done <<< "$rows"

  # 3. Derived values: computed on a new file, when they are missing, or when one of their
  #    sources changed in this run AND the value really was derived from them. A value
  #    that doesn't match its sources is left alone: that is how a slot is pointed at
  #    something external (DATABASE_URL at a shared Postgres), and it isn't ours to rewrite.
  while IFS=$'\t' read -r name slot kind rule; do
    [[ "$kind" == derived ]] || continue
    local src touched=0 t="$rule"
    while [[ "$t" =~ \$\{([A-Za-z_][A-Za-z0-9_]*)\}(.*)$ ]]; do
      src="${BASH_REMATCH[1]}"; t="${BASH_REMATCH[2]}"
      [[ -n "${CHANGED[$src]:-}" ]] && touched=1
    done
    if [[ "$touched" == 1 && "${ENVV[$name]:-}" != "$(expand "$rule" OLDV)" ]]; then touched=0; fi
    if [[ "$FRESH" == 1 || "$touched" == 1 || -z "${ENVV[$name]:-}" ]]; then
      computed="$(expand "$rule")"
      [[ "${ENVV[$name]:-}" == "$computed" ]] && continue
      env_set "$name" "$computed"; note "$name" "derived"
    fi
  done <<< "$rows"

  if (( ${#CHANGED[@]} )); then write_env; fi

  # 4. The JWT key pair, once the passphrase is final (it encrypts the private key).
  (( failed )) || provision_jwt_keys

  if (( ${#REPORT[@]} )); then
    printf '%s\n' "${REPORT[@]}"
  else
    echo "   nothing to do: every secret in $ENV_FILE has a value of its own."
  fi
  if (( ${#WARNINGS[@]} )); then
    echo
    printf '!! %s\n' "${WARNINGS[@]}" >&2
    echo
  fi
  if [[ "$FRESH" == 1 ]]; then
    info "$ENV_FILE is ready. Next: docker compose up"
  elif (( ${#CHANGED[@]} )); then
    info "previous $ENV_FILE kept in .oliva/env.backup"
    info "$ENV_FILE updated. Containers read it when they are created: recreate them"
    info "(docker compose up -d --force-recreate) for the new values to take effect."
  fi
  return $failed
}

# ── check ────────────────────────────────────────────────────────────────────────
cmd_check() {
  local compose=(docker compose)
  case "${1:-}" in
    --prod) compose=(docker compose -f docker-compose.yml -f docker-compose.prod.yml) ;;
    "") ;;
    *) die "usage: scripts/oliva/env.sh check [--prod]" ;;
  esac
  env_check full "${compose[@]}"
}

case "${1:-}" in
  init)  cmd_init ;;
  check) shift; cmd_check "$@" ;;
  *) sed -n '3,20p' "$0"; exit 1 ;;
esac
