# agent-commits.md — registro de commits del agente (Oliva)

Registro detallado de cambios del agente que merecen justificación de *por qué*
(no se anota cada commit — ver protocolo en `CLAUDE.md`). Formato en `CLAUDE.md`
§ "Protocolo de commits del agente".

---

## [PASO 1.1] fix(env): APP_ENV corto (prod/dev) — reactiva los bloques when@ de Symfony
**Hash:** `1fd2a7a`
**Rama:** `feat/env-isolation-deploy`
**Fecha:** 2026-06-30

### Cambios
| Archivo | Tipo | Descripción |
|---|---|---|
| `docker-compose.prod.yml` | modificado | `APP_ENV=production` → `prod` en `backend` y `scheduler` (×2). |
| `docker-compose.override.yml` | modificado | `APP_ENV: development` → `dev` en `backend`, `scheduler` y `worker` (×3). |
| `.env.example` | modificado | `APP_ENV=development` → `dev` (la `.env` base que el VPS copia en el deploy). |
| `docker-compose.staging.yml` | modificado | Comentario del override stale: citaba `APP_ENV=production` y "production no está en bundles.php" → `prod`. La lógica del override no cambia. |
| `CLAUDE.md` | modificado | Misma actualización stale en el gotcha de precedencia de `APP_ENV`. |

(El `.env` local del dev quedó alineado a `dev`, pero es gitignored y no entra en este commit.)

### Justificación
Deuda conocida (detectada 2026-06-30, ver memoria `oliva-state`): el `Dockerfile`
hornea el `ENV APP_ENV` corto y correcto (`dev`/`prod`/`staging`, los strings que
Symfony espera), pero los compose files lo **pisaban** con la palabra larga vía
`environment:`, que en Compose tiene mayor precedencia que el `ENV` de la imagen.

Symfony matchea los bloques `when@prod:` / `when@dev:` por **string exacto**:
`production` ≠ `prod`, `development` ≠ `dev`. Resultado medido (no cosmético): en
prod nunca se aplicaba el `when@prod:` de `backend/config/packages/doctrine.yaml`
— prod corría **sin** los cache pools de query/result de Doctrine y **regenerando
proxies** (`auto_generate_proxy_classes`), además de perder
`strict_requirements: null` de `routing.yaml`. En runtime, con `APP_ENV=production`,
Symfony buscaba `var/cache/production/` (inexistente; el build horneó
`var/cache/prod/`) y recompilaba la cache como entorno `production`.

Se verificó primero que **no fuera otra deuda nueva en los Dockerfiles** (sospecha
inicial): los `Dockerfile` ya estaban bien — las palabras largas que aparecen ahí
son falsos positivos (`php.ini-production`/`-development` son templates de PHP; los
stages `development`/`production` del frontend son nombres de build, no `APP_ENV`).
El bug vivía solo en compose + `.env.example`.

**Alternativa descartada:** quitar el `APP_ENV` de los compose y depender solo del
`ENV` horneado. Se eligió el cambio mínimo (`production`→`prod`, `development`→`dev`)
por ser de menor riesgo y porque el override explícito sigue siendo necesario en
`staging.yml` (donde debe pisar el `prod` heredado de `prod.yml`).

**Auditoría de regresión:** no hay ningún `when@production`/`when@development` real
(los únicos están en `config/reference.php`, un docblock de Symfony); no hay
`.env.production`/`.env.development` huérfanos; ningún código compara contra el
string largo; CI no asume la palabra larga. Verificado con `docker compose config`
que `APP_ENV` resuelve corto en `backend`/`scheduler` en los 3 entornos
(dev/prod/staging), incluyendo el `scheduler` tras el profile `cron`.

---

## [PASO 1.2] ci: post-merge smoke + caché de capas GHA + guard de APP_ENV prod
**Hash:** `57663fe`
**Rama:** `main` (mergeado vía FF desde `feat/env-isolation-deploy`)
**Fecha:** 2026-06-30

### Cambios
| Archivo | Tipo | Descripción |
|---|---|---|
| `.github/workflows/ci.yml` | modificado | Recalibración completa al flujo solo-dev (ver justificación). |

### Justificación
Marcos cuestionó si PRs + GitHub Actions tienen sentido a su escala (solo-dev, ONG,
1-3 apps chicas) si igual no mira el CI y tarda ~15 min. Diagnóstico tras leer el
workflow: **no había testeo de más** — el `tests` job ya es un smoke test correcto
(health + Mercure + migraciones + `schema:validate` + PHPUnit). El tiempo se iba en
**buildear sin caché** (compila extensiones PHP + `composer install` + `yarn install`
desde cero cada corrida). Tres cambios quirúrgicos:
- **Triggers:** se saca `pull_request` (se elimina la ceremonia de PR, ver
  [[feedback]] flujo solo-dev), se deja `push:main` + `workflow_dispatch`. El CI pasa a
  correr DESPUÉS del merge — red de seguridad que solo avisa en rojo, no algo que
  haya que vigilar.
- **Caché de capas GHA:** build vía `docker/bake-action` con `cache-from/to=type=gha`.
  Con deps sin cambios, las capas caras son cache-hit → el build cae de minutos a
  segundos. Requiere el driver docker-container de `setup-buildx-action` (el driver
  por defecto no soporta backends de caché). Sólo se buildean `backend`+`frontend`
  (los únicos con `build`); `database` se pullea en el `up`.
- **Job `prod-config` (la guarda que pidió Marcos):** valida vía `compose config`
  (sin build, corrió en **3s** en CI) que `APP_ENV` resuelve a `prod` en backend y
  scheduler del stack prod. Atrapa la clase de bug del PASO 1.1 (palabra larga
  pisando `APP_ENV` → `when@prod` de Symfony desactivado), que el job `tests` NO ve
  porque solo levanta el stack DEV.

**Resultado en CI:** los 3 jobs verdes. Primera corrida 12m18s (priming: además de
buildear, *escribe* el caché). El speedup esperado (~2-4 min) se valida recién en el
próximo push a main (caché disponible para *leer*). Deuda menor anotada: las actions
targetean Node 20 (deprecado), bumpear a `checkout@v5` etc. cuando convenga.

> Nota: este PASO 1.2 se registró a posteriori (en el `claude reiniciar` de cierre),
> no en el mismo commit `57663fe` — excepción puntual a la regla de "log y commit
> juntos", porque el valor de dejar el cierre de sesión documentado lo justifica.

---

## [PASO 2.1] docs(bruno): convención de API testing doc-only (README + runbook)
**Hash:** `468b2c2`
**Rama:** `main`
**Fecha:** 2026-06-30

### Cambios
| Archivo | Tipo | Descripción |
|---|---|---|
| `README.md` | modificado | Nueva fila en la tabla de stack: `API testing → Bruno collection in api/` (marcada como per-app, no shipeada por Oliva). |
| `CLAUDE.md` | modificado | Nuevo paso 12 en el runbook de deploy shared-infra: smoke de flujos de negocio con la collection Bruno contra `{{base_url}}`, simétrico al `fixtures:load` del runbook de staging. |
| `agent-commits.md` | modificado | Esta entrada. |

### Justificación
finanzas-ong (primer fork real) tiene una collection Bruno funcionando en `api/`
(commit `27ff98c`): environments prod/staging, auto-token post-login, `batch_id`
capturado para confirmar sin copy-paste, 9 requests cubriendo todos los flujos.
Surgió la pregunta de si eso debía subir a Oliva como stub físico (igual que
`AppFixtures` de la seeding layer).

**Decisión: NO shipear archivos.** A diferencia de las fixtures —donde el stub
`AppFixtures` es genérico y reutilizable—, una collection Bruno es 100% dominio de
la app (los endpoints, los payloads, los flujos son de finanzas-ong, no de Oliva) y
Bruno es una app externa, no parte del stack corriendo. Con n=1 fork, extraer una
convención de *layout de archivos* es prematuro: no hay evidencia de qué es
invariante entre apps.

**Lo que SÍ va en Oliva (doc-only, este commit):** (1) una línea en la tabla de
stack del README declarando la convención "API testing: Bruno en `api/`, por app";
(2) un paso en el runbook de deploy simétrico al `fixtures:load` de seeding —
health check confirma que el proceso arranca, la collection confirma que el dominio
funciona end-to-end. Extraer una convención de archivos recién cuando la app #2
confirme que el layout es invariante.
