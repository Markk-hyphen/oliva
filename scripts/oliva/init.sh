#!/usr/bin/env bash
#
# The birth of an app. Run once, in a fresh clone of Oliva's `release` branch:
#
#   git clone -b release https://github.com/Markk-hyphen/oliva.git my-app
#   cd my-app
#   ./oliva init "My App" [--origin <url>] [--demo]
#
# It gives the app its identity and nothing else: remotes, its own README.md,
# AGENTS.md, agent-commits.md and docs/concepts.md (from scripts/oliva/templates/),
# the live demo out (kept with --demo), the tracked marker .oliva-app, a .env,
# and a first commit. It asks for one thing, the name. No service flags: which
# services an app carries is roadmap item 3 and is not decided here.
#
#   ./oliva init --adopt ["Name"]
#
# The same step for an app that already exists (born before 1.7.0). It never
# overwrites or deletes anything of the app's: it creates what is missing, sets
# aside an AGENTS.md / README.md that is still Oliva's, and leaves the demo alone.
#
# Why: until 1.7.0 an app was born as a clone of Oliva, with Oliva's name, log,
# roadmap and demo, and paid for it in conflicts on every sync
# (docs/friction-log.md S3, T2, T3, S1).
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_repo_root

TPL="scripts/oliva/templates"
GUIDE_IMPORT="@docs/oliva/agent-guide.md"
name="" origin="" demo=0 adopt=0
while (( $# )); do
  case "$1" in
    --origin) origin="${2:-}"; [[ -n "$origin" ]] || die "--origin needs a URL"; shift 2 ;;
    --demo)   demo=1; shift ;;
    --adopt)  adopt=1; shift ;;
    -h|--help) sed -n '3,22p' "$0"; exit 0 ;;
    -*)       die "unknown option: $1 (see ./oliva init --help)" ;;
    *)        [[ -z "$name" ]] || die "one name only (quote it if it has spaces)"; name="$1"; shift ;;
  esac
done

is_app && die "already initialized: $OLIVA_APP_MARKER exists ($(sed -n 's/^name=//p' "$OLIVA_APP_MARKER")). Nothing to do."
[[ -d "$TPL" ]] || die "$TPL is missing: this checkout is older than Oliva 1.7.0. Sync first."
has_upstream() { git remote get-url "$OLIVA_REMOTE" >/dev/null 2>&1; }

render() {  # render <template> <destination>
  mkdir -p "$(dirname "$2")"
  sed -e "s|{{APP_NAME}}|${name//|/\\|}|g" \
      -e "s|{{OLIVA_VERSION}}|$(local_oliva_version)|g" \
      -e "s|{{DATE}}|$(date +%F)|g" "$1" > "$2"
}
write_marker() {
  printf 'name=%s\nborn_on=%s\ndate=%s\n' "$name" "$(local_oliva_version)" "$(date +%F)" > "$OLIVA_APP_MARKER"
}

# ── adopt ──────────────────────────────────────────────────────────────────────────
if (( adopt )); then
  has_upstream || die "--adopt is for an existing app: no '$OLIVA_REMOTE' remote here."
  require_clean_tree
  [[ -n "$name" ]] || name="$(basename "$PWD")"
  info "adopting '$name' (nothing of yours is overwritten or deleted)"
  todo=()
  for f in AGENTS.md README.md; do
    if [[ ! -f "$f" ]]; then
      render "$TPL/$f.tpl" "$f"; echo "   created   $f"
    elif [[ "$(head -1 "$f")" == "# Oliva" ]]; then
      # Still Oliva's file, maybe with the app's own notes added to it. Set it aside
      # whole and start the app's own; a person moves across what is theirs.
      git mv "$f" "${f%.md}.pre-oliva-1.7.md"
      render "$TPL/$f.tpl" "$f"
      echo "   set aside $f → ${f%.md}.pre-oliva-1.7.md (it was still titled 'Oliva'); new $f written"
      todo+=("move what is yours from ${f%.md}.pre-oliva-1.7.md into $f, then delete it")
    else
      echo "   kept      $f"
    fi
  done
  if [[ "$(head -1 AGENTS.md)" != "$GUIDE_IMPORT" ]]; then
    printf '%s\n\n' "$GUIDE_IMPORT" | cat - AGENTS.md > AGENTS.md.tmp && mv AGENTS.md.tmp AGENTS.md
    echo "   AGENTS.md: added the import of the framework guide as its first line"
    todo+=("AGENTS.md still carries framework sections of its own: cut them, the guide is now docs/oliva/agent-guide.md")
  fi
  for pair in "agent-commits.md:agent-commits.md" "concepts.md:docs/concepts.md"; do
    f="${pair#*:}"
    if [[ "$f" == agent-commits.md && -f commits.md ]]; then echo "   kept      commits.md"; continue; fi
    if [[ -f "$f" ]]; then echo "   kept      $f"; else render "$TPL/${pair%%:*}.tpl" "$f"; echo "   created   $f"; fi
  done
  write_marker
  git add -A
  git commit -q -m "init: adopt $name as an app on Oliva $(local_oliva_version)"
  info "done: $OLIVA_APP_MARKER written and committed."
  if (( ${#todo[@]} )); then
    echo "   Left for you:"; printf '   - %s\n' "${todo[@]}"
  fi
  exit 0
fi

# ── birth ──────────────────────────────────────────────────────────────────────────
[[ -n "$name" ]] || die "give the app a name: ./oliva init \"My App\""
if [[ -f docs/roadmap.md || -f README.md ]] && ! has_upstream; then
  die "this is Oliva's own repository, or a clone of its main branch. An app starts from the release branch:
       git clone -b release $OLIVA_REMOTE_URL my-app && cd my-app && ./oliva init \"My App\"
       (an app that already exists: ./oliva init --adopt)"
fi
has_upstream && [[ -f README.md ]] \
  && die "this looks like an existing app (it has a README.md and the '$OLIVA_REMOTE' remote). Use: ./oliva init --adopt"
require_clean_tree

# remotes: where the clone came from is Oliva, not the app's home
if ! has_upstream; then
  git remote get-url origin >/dev/null 2>&1 || die "no 'origin' remote: clone Oliva's release branch first."
  git remote rename origin "$OLIVA_REMOTE"
fi
[[ -z "$origin" ]] || git remote add origin "$origin"
# the app's own line of history is called main; the clone left it on `release`
if [[ "$(git branch --show-current)" != main ]]; then
  git branch -m main
  git branch --unset-upstream 2>/dev/null || true
fi

info "identity"
render "$TPL/README.md.tpl" README.md
render "$TPL/AGENTS.md.tpl" AGENTS.md
render "$TPL/agent-commits.md.tpl" agent-commits.md
render "$TPL/concepts.md.tpl" docs/concepts.md
echo "   README.md  AGENTS.md  agent-commits.md  docs/concepts.md"

if (( demo )); then
  info "demo kept (--demo)"
else
  info "demo removed (keep it next time with --demo)"
  rm -f backend/src/Controller/LiveController.php frontend/src/js/live.js
  render "$TPL/frontend/index.html.tpl" frontend/index.html
  render "$TPL/frontend/main.js.tpl" frontend/src/main.js
  render "$TPL/frontend/style.css.tpl" frontend/src/style.css
fi

write_marker
[[ -f .env ]] || scripts/oliva/env.sh init
git add -A
git commit -q -m "init: $name on Oliva $(local_oliva_version)"

info "$name is born on Oliva $(local_oliva_version). Next:"
echo "   docker compose up -d --wait"
echo "   ./oliva doctor"
[[ -n "$origin" ]] || echo "   (no --origin given: add one when the app has a home, or doctor keeps saying it has no CI)"
