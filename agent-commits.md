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
