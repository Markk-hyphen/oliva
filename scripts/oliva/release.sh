#!/usr/bin/env bash
#
# Publica una versión de Oliva. Solo en el repo de Oliva, sobre main.
#
#   scripts/oliva/release.sh 1.2.0
#
# Exige que docs/oliva/UPGRADING.md ya tenga la sección "## 1.2.0": las notas son lo
# que sync.sh le muestra a cada fork, así que no se publica sin escribirlas. Desde 1.5.0
# además valida que cada ítem de "Acción requerida" tenga su etiqueta [lugar(, guard: id)]
# y que el guard exista (lib/upgrade-guards.sh, lint_upgrade_actions).
# Since 1.6.2 it also refuses when `composer audit` reports advisories or when the full
# audit (`deps.sh audit`) is older than OLIVA_AUDIT_DUE_DAYS (7).
# Escribe OLIVA_VERSION, commitea y crea el tag anotado v1.2.0. NO pushea: imprime el comando.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
source "$(dirname "$0")/../lib/upgrade-guards.sh"
require_repo_root

ver="${1:-}"
[[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "uso: scripts/oliva/release.sh X.Y.Z"
[[ "$(git branch --show-current)" == main ]] || die "las versiones salen de main."
require_clean_tree
version_lt "$(local_oliva_version)" "$ver" || die "$ver no es mayor que la actual ($(local_oliva_version))."
grep -qE "^## ${ver//./\\.}( |$)" docs/oliva/UPGRADING.md \
  || die "falta la sección '## $ver' en docs/oliva/UPGRADING.md (qué cambia y qué tiene que hacer cada fork)."
lint_upgrade_actions "$ver" \
  || die "etiquetas de 'Acción requerida' inválidas en '## $ver' (formato: cabecera de docs/oliva/UPGRADING.md)."
git rev-parse -q --verify "refs/tags/v$ver" >/dev/null && die "el tag v$ver ya existe."

# A release does not go out on known advisories (friction log X7: 1.6.0 was published ten
# days after the 14 Symfony advisories it carried, because nothing here looked).
# Two checks, on purpose different:
#   - composer audit, now: a red one always has a way out (`deps update`, or an accepted
#     advisory in composer.json → config.audit.ignore), so it blocks.
#   - the full audit (images, runtime): it must be RECENT, not clean. Base images carry
#     findings with no release to move to yet; demanding zero would block every release.
audit_state=".oliva/audit-state"; audit_max="${OLIVA_AUDIT_DUE_DAYS:-7}"
[[ -f "$audit_state" ]] \
  || die "the full audit never ran in this checkout. Run: scripts/oliva/deps.sh audit"
audit_days=$(( ( $(date +%s) - $(date -d "$(awk '{print $1; exit}' "$audit_state")" +%s) ) / 86400 ))
(( audit_days < audit_max )) \
  || die "the last full audit is $audit_days days old (limit: $audit_max). Run: scripts/oliva/deps.sh audit"
info "composer audit (a release does not ship known advisories)"
run_composer audit --locked \
  || die "composer audit reports advisories. Fix: scripts/oliva/deps.sh update — or accept one explicitly in backend/composer.json (config.audit.ignore) and say why in UPGRADING.md."

printf '%s\n' "$ver" > OLIVA_VERSION
git add OLIVA_VERSION
git commit -q -m "release: Oliva $ver"
git tag -a "v$ver" -m "Oliva $ver"
# Las acciones de la versión son para los forks: en el checkout de Oliva ya están hechas
# (las escribió quien publica). Sin esto, `doctor` de Oliva las listaría como pendientes.
mkdir -p "$(dirname "$OLIVA_ACK_FILE")" && echo "$ver" > "$OLIVA_ACK_FILE"
info "Oliva $ver lista. Publicar: git push origin main v$ver"
info "Después, en cada fork: scripts/oliva/sync.sh check"
