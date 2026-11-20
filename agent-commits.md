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

---

## [1.1.0] Oliva 1.1.0 — nombres por proyecto + sistema de actualizaciones para Oliva y sus forks
**Hash:** `1090b30..d6b95b4` (9 commits; registrados juntos al cerrar la versión, a pedido de Marcos)
**Rama:** `main`
**Fecha:** 2026-10-21

### Cambios
| Archivo | Tipo | Descripción |
|---|---|---|
| `docker-compose.override.yml` / `docker-compose.prod.yml` / `docker-compose.staging.yml` | modificado | Imágenes `${COMPOSE_PROJECT_NAME}-<servicio>:<dev\|prod\|staging>` en vez de `app-*-<env>:1.0` (`1090b30`). |
| `docker-compose.yml` | modificado | `app_network` sin `name:` fijo → `<project>_app_network` (`1090b30`). |
| `scripts/lib/project-guard.sh` | nuevo | Guard de colisión: aborta si el project pertenece a otro checkout; rechaza apps `*-staging` (`1090b30`). |
| `scripts/deploy.sh`, `deploy-staging.sh`, `down.sh`, `down-staging.sh` | modificado | Sourcean el guard (`1090b30`). |
| `.github/workflows/ci.yml` | modificado | `COMPOSE_PROJECT_NAME` fijo para que bake y compose coincidan (`1090b30`); pasos `schema`/`phpunit` apagables por fork con la variable de repo `OLIVA_CI_SKIP` (`f31a329`). |
| `frontend/yarn.lock`, `.gitignore`, `frontend/Dockerfile` | nuevo / modificado | Lock versionado + `yarn install --frozen-lockfile` (`920d6f4`). |
| `backend/Dockerfile` | modificado | PECL y composer fijados: `amqp-2.2.0`, `apcu-5.1.28`, `xdebug-3.5.3`, composer `2.10.3` (`a857f44`); instala lo que liste `backend/php-extensions.txt` (`d6b95b4`). |
| `backend/php-extensions.txt` | nuevo | Extension point: extensiones PHP propias de la app, vacío en Oliva (`d6b95b4`). |
| `frontend/Caddyfile` | modificado | `trusted_proxies static private_ranges`, backport de finanzas-ong `a42aced` (`4db5de1`). |
| `OLIVA_VERSION` | nuevo | `1.1.0` (`15fc532`). |
| `docs/oliva/actualizaciones.md`, `docs/oliva/UPGRADING.md` | nuevo | Modelo de actualización y notas por versión para forks (`15fc532`, ampliados después). |
| `scripts/oliva/deps.sh`, `sync.sh`, `verify.sh`, `release.sh`, `lib.sh`, `owned-paths.txt` | nuevo | Herramientas de mantenimiento y sync (`15fc532`; shellcheck en `b6893aa`; triage seguro en `d6b95b4`). |
| `claude-commands.md` | modificado | `-f` de `claude reiniciar`, ruta de memoria genérica, comandos `claude oliva deps` / `claude oliva sync` (`15fc532`, `76d8e79`). |
| `CLAUDE.md`, `README.md` | modificado | Sección de versiones/forks, aislamiento por app, chequeos de inicio con `deps.sh due` (`1090b30`, `15fc532`). |
| `agent-commits.md`, `scripts/oliva/sync.sh`, `scripts/oliva/owned-paths.txt`, `docs/oliva/actualizaciones.md` | modificado | Esta entrada; el log del proyecto queda fuera del sync (gana el del fork). |

### Justificación
**Nombres por proyecto.** Un nombre fijo en Docker es global al daemon, no al repo. Con dos apps en la misma máquina, el build de finanzas-ong pisaba `app-backend-dev:1.0` y los containers de CMP quedaron apuntando a un ID huérfano: un `up` sin `--build` habría arrancado CMP con el `vendor` de finanzas. La red fija `app_network` metía los dos stacks dev en la misma red, donde el DNS de Docker hace round-robin entre los `backend`/`database` de ambas apps (el mismo bug que motivó el split de redes de la infra). En el VPS iba a pasar lo mismo con `app-backend-prod:1.0` el día que CMP se deployara al lado de finanzas. Se eligió `<project>-<servicio>:<entorno>` en vez de omitir `image:` (Compose nombraría `<project>-<servicio>` solo) porque `backend`/`worker`/`scheduler` comparten una imagen: sin nombre explícito se construirían tres veces y dev y prod se pisarían dentro del mismo proyecto. El guard cierra la deuda documentada: si el nombre de proyecto se repite entre checkouts, ahora también chocarían las imágenes, así que el chequeo pasa a ser parte del mismo fix.

**Todo fijado.** Los dos incidentes de dependencias tuvieron la misma causa: algo flotante que cambió en un rebuild cualquiera (el tag `1-php8.3` de FrankenPHP rompió Mercure; el `yarn.lock` sin versionar hacía lo mismo con el frontend). Las extensiones PECL se fijaron después de ver a pecl.php.net devolver 500/504 en plena sesión.

**Sistema de actualización.** Se descartó Dependabot/Renovate con PRs (el flujo es solo-dev sin PRs; un bot abriendo PRs que nadie mergea es ruido) y un cron que syncee solo (un merge puede tocar código del fork; alguien tiene que verlo). Lo elegido: recordatorios baratos en el chequeo de inicio de sesión (`deps.sh due`, `sync.sh check`), un ciclo semiautomático que solo sube versiones dentro de los rangos y la red de seguridad `verify.sh`. Los saltos de major e imagen base quedan manuales, uno por commit. La pieza clave es la propiedad de archivos (`owned-paths.txt`) con extension points: el ensayo del sync de finanzas mostró que quedarse con la versión de Oliva del Dockerfile **borraba `bcmath`** y rompía el cálculo de dinero. De ahí `backend/php-extensions.txt` y que `sync.sh` muestre lo que cambió el fork antes de sugerir nada.

**Problema encontrado durante la ejecución:** el `agent-commits.md` de Oliva viaja con cada merge y chocaría con el log propio de cada fork. `sync.sh` ahora lo clasifica `[FORK]` (gana el del fork).

---

## [1.1.1] chore(scripts): limpiar restos de build al deployar y al actualizar dependencias
**Hash:** ver `git log --grep "prune build leftovers"` (se registra en el mismo commit)
**Rama:** `main`
**Fecha:** 2026-10-21

### Cambios
| Archivo | Tipo | Descripción |
|---|---|---|
| `scripts/lib/docker-prune.sh` | nuevo | `prune_build_leftovers`: `docker image prune -f` (solo sin tag) + `docker builder prune --filter until=168h`. Saltea con `OLIVA_NO_PRUNE=1`. |
| `scripts/deploy.sh`, `scripts/deploy-staging.sh` | modificado | Lo llaman al final, después del `ps`. |
| `scripts/oliva/deps.sh` | modificado | `update` lo llama tras el commit del ciclo. |
| `docs/oliva/actualizaciones.md`, `docs/oliva/UPGRADING.md` | modificado | Sección "Espacio en disco" y notas de 1.1.1. |
| `agent-commits.md` | modificado | Esta entrada. |

### Justificación
Marcos preguntó si las actualizaciones periódicas engordan los proyectos. Medido el 2026-10-21 en su máquina: git no (un ciclo son decenas de KB de lockfile), Docker sí, y por cualquier rebuild, no solo por las actualizaciones. Había 4,1 GB de caché de build sin usar, 2,3 GB de imágenes recuperables y 1 GB de volúmenes anónimos huérfanos. En el VPS (droplet chico) cada `deploy.sh --build` deja ~750 MB de imagen de backend sin tag, así que el disco se llena solo con el tiempo.

Qué se limpia y qué no: solo imágenes **sin tag**. Las imágenes de plan B para cuando pecl está caído van taggeadas a propósito, y el prune nunca toca volúmenes. La caché de build se poda con antigüedad (7 días) en vez de entera, para que el próximo deploy no rebuildee todo desde cero; eso además importa cuando pecl está caído, porque una capa de extensiones cacheada evita descargarlas. Los volúmenes anónimos de dev quedan documentados como limpieza manual: borrarlos desde un script de deploy podría llevarse el `var/` de un stack que está parado pero que se quiere volver a levantar.

---

## [1.1.2–1.1.4] Migración de extensiones PECL → PIE (sacar el build de pecl.php.net)
**Hash:** `3c6fba2` (1.1.2, band-aid), `f7a1f9d` (1.1.3, PIE), `0c7435c` (apt sandbox + hadolint), `f32398a` (1.1.4, fix de orden)
**Rama:** `main`
**Fecha:** 2026-10-22

### Cambios
| Archivo | Tipo | Descripción |
|---|---|---|
| `backend/Dockerfile` | modificado | `amqp`/`apcu`/`xdebug` pasan de `install-php-extensions` (PECL) a `pie install` (imagen oficial `ghcr.io/php/pie:1.5.3-bin` montada en build-time, no queda en la imagen). `@composer`/`intl`/`opcache`/`pdo_pgsql`/`zip` siguen en `install-php-extensions` (pineado `mlocati/php-extension-installer:2.12.3`): no pasan por pecl. El RUN de PIE va al final del stage base y usa `-o APT::Sandbox::User=root`. |
| `docs/oliva/UPGRADING.md` | modificado | Secciones 1.1.2 (band-aid), 1.1.3 (PIE) y 1.1.4 (fix de orden). |
| `OLIVA_VERSION` | modificado | 1.1.1 → 1.1.4 (tres releases en el mismo día). |
| `agent-commits.md` | modificado | Esta entrada. |

### Justificación
`pecl.php.net` entró en phase-out (RFC "Adopt PIE, deprecate PECL", aceptada 2025-09-20) y su REST de metadata responde intermitente, rompiendo el build de backend con `install-php-extensions ... exit code 100`. El CI de los 3 repos estaba en rojo y, peor, no se podía buildear limpio desde cero (VPS, futuro bump de PHP).

**Por qué NO el camino "obvio" primero.** Se probó bumpear `install-php-extensions` a 2.12.3 (band-aid, 1.1.2): consulta el REST solo cuando hace falta, pero las extensiones con versión pineada se SIGUEN bajando de pecl.php.net. Verificó local por suerte (pecl arriba en ese momento) y el CI lo tiró igual en `xdebug`. Lección: para extensiones pecl-dependientes, bumpear el instalador no alcanza — hay que salir de pecl.

**Por qué PIE y por qué híbrido.** Al verificar contra Packagist (no de memoria: el corte de conocimiento era pre-ecosistema-PIE), los tres (`xdebug/xdebug`, `apcu/apcu`, `php-amqp/php-amqp`) ya existen como `php-ext` instalables con PIE, que baja de Packagist/GitHub y nunca toca pecl. Se migran esos tres; el resto (composer de getcomposer, y las bundled de PHP que se compilan del source) no toca pecl, así que queda en `install-php-extensions` — que además resuelve solo las libs de sistema. PIE no instala libs de SO: `amqp` necesitó `librabbitmq-dev` explícito.

**Dos gotchas no obvios, cada uno un release más (ver [[oliva-reference]] #12):**
1. **apt no podía escribir `/tmp`** (`mkstemp Permission denied` → exit 100): el `COPY --link php-extensions.txt /tmp/` le saca el sticky 1777 en el buildkit del CI, y el sandbox `_apt` falla. Fix: `apt-get -o APT::Sandbox::User=root update` (como hacía install-php-extensions por dentro). También se silenció hadolint DL3008/SC2086 en los RUN de PIE (no se pinean paquetes apt a propósito).
2. **`gcc: not found` (exit 127):** el RUN de PIE purga el toolchain al final; estaba ANTES del extension point del fork (`install-php-extensions $exts`), que necesita gcc para compilar. Un fork con algo en `php-extensions.txt` (finanzas-ong: bcmath) rompía; Oliva/crypto no, por tenerlo vacío. Fix: mover el RUN de PIE al final del stage base (1.1.4).

**Problema de método encontrado durante la ejecución:** la verificación local se hacía siempre sobre Oliva (con `php-extensions.txt` vacío), que no ejercita el extension point del fork — justo el caso que el gotcha #2 rompía. Lo atrapó el `verify` de finanzas-ong (con bcmath). Regla nueva: todo cambio al Dockerfile se prueba con una extensión en `php-extensions.txt`, no solo sobre Oliva. Propagado a los 3 repos con `sync.sh`, todos en verde (crypto saltea `schema` por el drift pgvector/HNSW conocido).

---

## [1.1.5] fix(security): parche PHP2Shell (PHP 8.3.36 / FrankenPHP 1.13.2) + cerrar el loop de verificación
**Hash:** `7c8bfd4` (parche), `e400f69` (untrack + UPGRADING), `2b3f09f` (release 1.1.5 + tag `v1.1.5`)
**Rama:** `main`
**Fecha:** 2026-10-22

### Cambios
| Archivo | Tipo | Descripción |
|---|---|---|
| `backend/Dockerfile` | modificado | Imagen base `dunglas/frankenphp:1.13.1-php8.3.35` → `1.13.2-php8.3.36`. Comentario del `FROM` ampliado con el porqué del bump (CVEs concretos, por qué 1.13.2 y no el mínimo `1.13.1-php8.3.36`, y que el fix exige RECREAR containers). |
| `.env.backend` | modificado | Eliminada `PHP_VERSION=8.3.13` (variable muerta). En su lugar, comentario que explica que la única fuente de verdad es el tag del `FROM` y por qué no debe volver. |
| `scripts/oliva/verify.sh` | modificado | Step nuevo `[php-version]` (corre justo después de `[up]`): compara `PHP_VERSION` del container contra el pin del Dockerfile y falla también si el tag no pinea un patch exacto. Header de pasos realineado. |
| `.gitignore` | modificado | Ignora `backend/config/reference.php`, con el porqué. |
| `backend/config/reference.php` | eliminado del índice | `git rm --cached` (queda en disco). Auto-generado por `cache:clear` solo para autocompletado del IDE. |
| `docs/oliva/UPGRADING.md` | modificado | Sección 1.1.5, la primera de esta serie con **4 pasos** de acción requerida en el fork, no "ninguna". |
| `OLIVA_VERSION` | modificado | 1.1.4 → 1.1.5. |
| `agent-commits.md` | modificado | Esta entrada. |

### Justificación
**El parche.** PHP 8.3.36 (21 Oct 2026, release marcada `security` en php.net) arregla PHP2Shell: CVE-2026-109618 y CVE-2026-109619, dos RCE sin autenticación, CVSS 9.2. Oliva y los dos forks corrían 8.3.35, una patch por debajo. No es un CVE de espectador: el 109619 es **estado de request stale que un worker reusa en el request siguiente**, y `frankenphp_prod` corre worker mode (`FRANKENPHP_CONFIG="import worker.Caddyfile"`).

**Por qué 1.13.2 y no el bump mínimo.** La nota de sesión anterior decía que no existía `1.13.1-php8.3.36` y que por eso había que mover FrankenPHP también. **Es falso** — se verificó contra Docker Hub que ese tag existe (pusheado 2026-10-21 17:45 UTC, 4 arquitecturas), así que el bump mínimo de solo-PHP era posible. Se eligió igual 1.13.2 porque es a su vez un security release y 2 de sus 4 vulns propias aplican a esta topología: fuga de fragmentos del input del cliente anterior vía `error_get_last()`/`libxml_get_errors()` en worker mode (GHSA-4gfw-9v29-gp9h) y thread pool ocupable por un cliente sin auth que encola requests y se desconecta (GHSA-fq24-r53r-xcx3). La tercera (arrays cíclicos a Go) es marginal y la "high" (embedded apps en temp dir predecible) no aplica: Oliva no usa embedded apps. Sus upgrade notes son todas de static builds (glibc 2.28, assets de macOS) → irrelevantes, acá se usa la imagen Docker. Riesgo de regresión bajo: patch dentro del mismo minor, y el warning histórico del `FROM` era por el tag **flotante** `1-php8.3`, no por un bump deliberado.

**Costo real del bump: una línea.** El ejercicio confirmó que la versión de PHP vive en **un solo lugar** (`backend/Dockerfile:6`) y que nada la duplica: no hay `ARG PHP_VERSION`, `composer.json` pide `php: >=8.3.31` (8.3.36 lo cumple → sin `composer update` ni lock tocado), y al ser el mismo minor el ABI de Zend no cambia, así que las extensiones por PIE (`apcu 5.1.28`, `amqp 2.2.0`, `xdebug 3.5.3`) recompilan igual. `deps.sh` lee la imagen por `awk` del `FROM` en vez de duplicar el dato, así que siguió funcionando sin tocarlo (verificado: `backend_base_image`, detección de EOL y `report_images`).

**La variable muerta era una trampa, no un valor viejo.** `.env.backend` tenía `PHP_VERSION=8.3.13`, que no consumía **nadie** (verificado sobre todo el árbol: ni Dockerfile, ni compose, ni código PHP, ni docs, ni el heredoc que arma el CI) y estaba 23 patches atrás. El riesgo no era el número desactualizado: es que se lee como "la versión de PHP del proyecto", así que en un apuro por un CVE se bumpea **eso**, se ve el número correcto y se cree que el fix se aplicó. Como `.env.backend` es un path SHARED, los dos forks cargaban la misma mentira. Se borra en el mismo commit del parche, a propósito: dejarla para después mantenía la trampa viva justo durante la ventana en que se la iba a consultar.

**El hueco estructural que expuso el ejercicio.** Este CVE lo detectó Marcos leyendo las noticias, no el tooling: `deps.sh due` es **por calendario**, no por advisory, y un 9.2 explotándose activamente no puede esperar el ciclo mensual. No se resuelve en este commit (requiere decidir una fuente de advisories y dónde engancharla), queda anotado como deuda.

Lo que **sí** se cierra acá es el otro hueco: `verify.sh` no tenía forma de asegurar que el PHP que corre sea el que se pineó. En este CVE puntualmente, un build verde no prueba nada — el fix no toma efecto en procesos vivos, así que un `up` que reusa un container deja los workers sirviendo el PHP viejo, sin dejar rastro. Es el paso que más fácil se saltea en un apuro. El step `[php-version]` lo asserta, y de paso falla si el tag deja de pinear un patch exacto, convirtiendo en check automático la convención que hoy vive solo en un comentario (y cuya violación ya rompió Mercure una vez). Mismo criterio que el step `[mercure]`: cada incidente pasado se vuelve una assertion.

**Nota de operación:** el restart ya estaba cubierto — `scripts/deploy.sh` hace `down --remove-orphans` antes del `up`, así que no quedan workers vivos con el PHP viejo. Un `up -d` suelto sobre un tag cambiado también recrea; el peligro es solo un `restart` del servicio, que no.

**Hallazgo lateral: `backend/config/reference.php` estaba trackeado y cada build lo reescribía.** Lo expuso el propio `verify.sh` de este parche, que dejó el árbol sucio. Es auto-generado (`cache:clear`, vía `auto-scripts` → `post-install-cmd`) y solo sirve para el autocompletado del IDE: nada en runtime lo lee. Es la misma clase de problema que los environments de Bruno ya documentados en `CLAUDE.md` —archivo trackeado que una herramienta reescribe sola—, pero acá con un costo extra: `release.sh` exige árbol limpio, así que un archivo que se ensucia en cada build bloquea el release justo cuando se quiere publicar rápido. Encima la copia que estaba en git quedó **stale**: listaba `when@development`, un entorno que el proyecto dejó de usar cuando `APP_ENV` pasó a nombres cortos (PASO 1.1), así que lo versionado era además incorrecto. Se destrackeó en vez de commitear la regeneración (volvería a ensuciarse en el build siguiente). Verificado antes de sacarlo del índice que se regenera: borrado del disco + `cache:clear` lo recrea idéntico en tamaño (1577 líneas).

**Deuda que este ejercicio expuso y NO se resolvió acá:** `deps.sh due` avisa **por calendario**, no por advisory. Un CVSS 9.2 explotándose activamente no puede esperar el ciclo mensual, y este lo detectó Marcos leyendo las noticias, no el tooling. No se improvisó un fix en el commit del parche a propósito: requiere decidir una fuente de advisories (GitHub Security Advisories, feed de php.net) y dónde engancharla, y mezclarlo con un parche urgente habría sido meter una decisión de diseño sin discutir en un commit que tiene que ser revisable de un vistazo.

## [deps 1er ciclo] chore(deps): techo `^0.4` en mercure-bundle + update dentro de rangos (a medias)
**Hash:** `98c19fd` (techo), `46e661f` (update), merge `aa3b6c9`
**Rama:** `chore/deps-2026-10-22` → `main` (local, sin pushear)
**Fecha:** 2026-10-22

### Cambios
| Archivo | Tipo | Descripción |
|---|---|---|
| `backend/composer.json` | modificado | `symfony/mercure-bundle` `"*"` → `"^0.4"` (98c19fd). Después `deps.sh update` subió el resto dentro de rangos (46e661f). |
| `backend/composer.lock` | modificado | ~50 paquetes: Symfony 7.4.21, doctrine/orm 3.7.5, dbal 4.5.0, phpunit 12.5.40, `mercure-bundle` 0.4.3. |
| `frontend/package.json`, `frontend/yarn.lock` | modificado | `yarn upgrade` dentro de rangos; `package.json` quedó reordenado alfabéticamente (ruido, sin cambio funcional). |
| `agent-commits.md` | modificado | Esta entrada. |

### Justificación
**Primer ciclo de mantenimiento de Oliva.** Cierra las 2 CVE del `composer audit` (`http-foundation` ReDoS, `yaml` recursión sin tope): ambas se tapan con bumps dentro de rango (→ 7.4.21). `verify.sh` 8/8 y `composer audit` limpio.

**Problema no previsto: el primer `update` rompió el build.** `composer.json` tenía `"*"` en `mercure-bundle` (también en `doctrine-migrations-bundle` y `maker-bundle`). Para composer cualquier versión está "en rango", así que `deps.sh update` lo subió 0.4.2 → **0.6.1**, aunque `report` lo marcaba `⇑` (manual). 0.6.1 exige claims `iss`/`sub`/`client_id` (RFC 9068) en `mercure.yaml` y el build de prod caía en `cache:clear` (`verify.sh`: 6 de 8 en FAIL). El `report` y el `update` no coinciden porque el primero compara contra el lock y el segundo contra el constraint.

**Decisión: techo, no fix de config.** Se descartó arreglar `mercure.yaml` en el mismo ciclo: toca el corazón de Oliva, requiere decidir qué claims poner y afecta a los forks (es la deuda "Mercure en modo compat 8"). El doc pide un commit por salto, así que el 0.6 va aparte. El bundle no se puede sacar: Oliva no lo usa (`live.php` publica con HTTP crudo), pero **ambos forks inyectan `HubInterface`** (finanzas-ong en `NotificationPublisher`, crypto-pulse en 3 clases) y un fork no edita archivos de Oliva.

**Efecto lateral a tener presente:** `"bump-after-update": true` en `composer.json` reescribe los constraints a lo instalado (`"*"` → `">=x"`, `^2.18` → `^2.19.1`), así que se pierden techos; uno explícito como `^0.4` sí sobrevive. Quedan otros `"*"` sin techo. Los forks tienen `"*"` en mercure-bundle: su próximo `composer update` rompe igual.

**Pendiente del ciclo (no hecho):** Node 20→24 (EOL), RabbitMQ 3→4 (EOL), notas en `UPGRADING.md`, `release.sh`, push y sync a forks. Fuera de alcance a propósito: pg15→18, php8.3→8.5, 6 majors de frontend, actions.

## [1.2.0] chore(deps): cierre del 1er ciclo — Node 24 + RabbitMQ 4 (ambos EOL) y release
**Hash:** `d409ce9` (node), `fb0370b` (rabbitmq), `e146283` (UPGRADING), `8304522` (release)
**Rama:** `main` (directo; los saltos de imagen no fueron por `chore/deps-*`)
**Fecha:** 2026-10-22

### Cambios
| Archivo | Tipo | Descripción |
|---|---|---|
| `frontend/Dockerfile` | modificado | Imagen base `node:20-slim` → `node:24-slim` (d409ce9). |
| `docker-compose.yml` | modificado | `rabbitmq:3-management` → `rabbitmq:4-management` (4.4.0) (fb0370b). |
| `docs/oliva/UPGRADING.md` | modificado | Sección 1.2.0: acción requerida por fork + qué cambió (e146283). |
| `OLIVA_VERSION` | modificado | `1.1.5` → `1.2.0` (8304522, vía `release.sh`). |
| `agent-commits.md` | modificado | Esta entrada. |

### Justificación
**Cierra los pendientes que el 1er ciclo dejó anotados** (ver entrada anterior): Node 20→24 y RabbitMQ 3→4, ambos por EOL, más notas y release. Un commit por salto, como pide el protocolo — no un bump masivo.

**Node: por qué 24 y no 26.** Node 20 quedó EOL el 2026-04-30. Se eligió 24 ("Krypton") por ser **Active LTS**; 26 salió este mes como *Current* y todavía no es LTS. Un framework base no estrena línea no-LTS: el costo de equivocarse lo pagan todos los forks. Swap limpio, `verify.sh` 8/8 con el `vite build` de prod sobre node 24.

**RabbitMQ: el salto con trampa, y es la razón por la que esto necesitó `UPGRADING.md` sí o sí.** 3.x está EOL desde 2024-09. Pero un nodo 4.0 levantado sobre un volumen poblado por un 3.x **se niega a bootear** si quedan *required feature flags* sin habilitar, y **no deja rastro obvio** — parece que el container simplemente no arranca. El `enable_feature_flag all` hay que correrlo **antes** del swap, con el nodo todavía en 3.13. Dato que evita un paso intermedio: el tag viejo `3-management` ya resolvía a 3.13.7, que es la única versión desde la que 4.0 soporta upgrade directo. Un fork que nunca activó el profile `queues` no tiene nada que hacer (un nodo 4.0 fresco nace con todos los flags enabled), y por eso la nota está escrita por caso y no como un paso único.

**Además, 4.0 eliminó las classic mirrored queues.** Se verificó que no afecta: los transports de ejemplo de Oliva (`ingest`/`enrich`/`failed`) son classic queues normales, no mirrored. Se dejó dicho igual en `UPGRADING.md` porque un fork sí pudo haber definido HA policies propias.

**Por qué el release es parte de esta entrada y no un trámite:** `release.sh` se niega a publicar una versión sin su sección en `UPGRADING.md`. En un salto como el de RabbitMQ ese gate es lo único que separa a un fork con datos de un nodo que no bootea — el canal hacia los forks es la entrega, no un anexo.

**No verificado por imposibilidad:** el procedimiento de feature flags sobre un volumen 3.x real. Se validó el camino limpio (nodo 4.4.0 healthy por `rabbitmq-diagnostics ping`, worker de Messenger conectando por AMQP y declarando colas). AMQP 0-9-1 no cambió entre 3 y 4, así que `php-amqp` no necesitó bump.

## [PASO 3.1] feat(deps): el aviso por advisory — audit de CVEs fuera del ciclo + Trivy para imágenes base
**Hash:** `14aaeaa`
**Rama:** `feat/advisory-audit`
**Fecha:** 2026-10-22

### Cambios
| Archivo | Tipo | Descripción |
|---|---|---|
| `scripts/oliva/deps.sh` | modificado | Subcomando `audit` (solo CVEs: `composer audit` + `yarn audit` + Trivy sobre las imágenes base) y `scan-images` (solo Trivy, lo usa el CI). `due` ahora reporta también la frescura del audit (umbral `OLIVA_AUDIT_DUE_DAYS`, default 7). `report` incluye `report_trivy`. Refactor: extracción de imágenes base a `base_images()` (compartido por `report_images` y `scan_images`). Constantes `AUDIT_DUE_DAYS`, `AUDIT_STATE`, `TRIVY_VERSION` (0.72.0). |
| `.github/workflows/ci.yml` | modificado | Job `image-scan` (report-only, `|| true`) que corre `deps.sh scan-images`. Opt-out por fork: `OLIVA_CI_SKIP=trivy`. Usa el mismo Trivy pinneado vía `docker run`, no la `trivy-action`. |
| `.gitignore` | modificado | `.oliva/` (estado local del audit, por-repo). |
| `.trivyignore` | nuevo | Plantilla para CVEs aceptados/infixables de las imágenes base. |
| `CLAUDE.md` | modificado | "Chequeos de sanidad": `deps.sh due` reporta las dos cadencias; mención de `deps.sh audit`. |
| `docs/oliva/actualizaciones.md` | modificado | Sección nueva "El aviso por advisory": modelo de capas, una-fuente-por-capa, detalles operativos de Trivy. |
| `docs/oliva/UPGRADING.md` | modificado | Sección 1.3.0 (acción requerida + qué cambió). |
| `agent-commits.md` | modificado | Esta entrada. |

### Justificación
**El gap que cierra:** el ciclo de deps (`report`/`update`) corre cada ~45 días por **frescura**; un CVE crítico no espera. Y había una capa sin cubrir por ninguna fuente: el SO y los binarios **dentro** de las imágenes base (OpenSSL del postgres, el binario de Caddy en FrankenPHP). `composer`/`yarn audit` solo ven los *paquetes* de la app.

**Decisión de diseño — una fuente por capa, no varias apiladas.** Las bases de advisories de paquetes se alimentan entre sí (GHSA ⟵ NVD + FriendsOfPHP; Packagist ⟵ FriendsOfPHP + GHSA; OSV ⟵ GHSA), así que apilar GHSA + OSV + Packagist sobre el mismo `composer.lock` es redundancia, no robustez (mismos hallazgos, distinto ID). La robustez viene de cubrir capas distintas: PHP (`composer audit`), JS (`yarn audit`), imágenes (**Trivy**). Se descartó osv-scanner (no hay gap en la capa de paquetes) y la API de NVD/OSV por-request (online, rate-limited; Trivy con DB local encaja mejor con el flujo de sesión/CI).

**Mecanismo del aviso:** `deps.sh audit` (a demanda, solo CVEs) + gate barato y offline en `deps.sh due` (lee la fecha de `.oliva/audit-state`, umbral 7 días). Fiel a "el recordatorio vive en el flujo": el chequeo de inicio de sesión de siempre ahora surfacea el audit sin red.

**Trivy:** corre como contenedor pinneado (`aquasec/trivy:0.72.0` — nada que instalar en el host) sobre el **ref base** fijado (no la imagen prod buildeada: ahí viven casi todos los CVEs de imagen y no hace falta buildear), filtra HIGH/CRITICAL **con fix** (`--ignore-unfixed`) y lee `.trivyignore`. Pin ≥ 0.71.1 obligatorio: la v0.69.4 estuvo comprometida (incidente de supply-chain 2026-03, que también afectó tags de `trivy-action` → por eso en CI se usa `docker run` con el pin, no la action). En CI el job es report-only a propósito: un CVE de imagen base puede ser infixable hasta que el upstream rebuildee; no se quiere `main` en rojo perpetuo.

**Dos bugs propios que destapó la corrida real** (no previstos en el plan), ambos de interacción con `set -e`: (1) `[[ cond ]] && rc=1` abortaba el loop en la 1ª imagen sin findings (short-circuit → lista en falso → `set -e`); (2) el pipeline `trivy ... | sed` con `--exit-code 1` + `pipefail` abortaba en la 1ª imagen *con* findings. Por eso la 1ª corrida solo escaneó `caddy`. Fix: capturar salida+estado con `out="$(...)" || status=$?` y un `if` explícito, nunca el idiom `&&`. Verificado: scan de las 5 imágenes completo, exit 1 con findings (caddy 26+68, node 3, pgvector 29+26, rabbitmq 4; FrankenPHP 0 — ya parchado en 1.1.5).

## [docs] README — sección "Built for agentic development"
**Hash:** `b6f83df`
**Rama:** `main`
**Fecha:** 2026-10-23

### Cambios
| Archivo | Tipo | Descripción |
|---|---|---|
| `README.md` | modificado | Sección nueva, hermana de `## Staying patched`: qué guardrails para agentes shipea Oliva con el código. |
| `agent-commits.md` | modificado | Esta entrada. |

### Justificación
**Qué hace distinto a la sección:** encuadra los guardrails **por nivel de garantía**, no como una lista plana de features. Ownership (`owned-paths.txt`) se nombra explícitamente como **convención, no candado** — *"git won't stop you"* —; `release.sh` y `project-guard.sh` se nombran como **gates reales** (abortan); `deps.sh due` como **cadencia**. Mezclar los tres niveles vendería como garantía algo que no lo es, y la primera vez que un fork editara un `owned-path` sin que pasara nada, el README quedaría desmentido.

**Omisiones deliberadas:** no menciona `rules-claude.md` ni el `CLAUDE.md` raíz de la máquina. Son setup personal y **no bajan a ningún fork**; nombrarlos en el README público daría a entender que son parte de lo que se clona.

**Consecuencia a tener presente:** `README.md` es **SHARED**, así que esta sección **no baja por sync**. Si se la quiere en los READMEs de los forks hay que adaptarla a mano, uno por uno (no pedido aún).

Solo-docs → no dispara CI, gracias al `paths-ignore` de `a7c3267`.

## [docs] Epic de la capa agéntica + ítem 5 del roadmap
**Hash:** `87632ca`
**Rama:** `main`
**Fecha:** 2026-10-23

### Cambios
| Archivo | Tipo | Descripción |
|---|---|---|
| `docs/roadmap/epics/E-capa-agentica.md` | nuevo | Plan completo de los 2 ejes (CLI `./oliva` + migración a `AGENTS.md`): decisiones cerradas, diseño del CLI, 4 fases con gates, texto obligatorio de `UPGRADING.md` 1.4.0, riesgos. |
| `docs/roadmap.md` | modificado | Ítem 5 "Agent layer: one entry point, vendor-neutral spec" + diagrama de secuencia actualizado. |
| `agent-commits.md` | modificado | Esta entrada. |

### Justificación
**El hallazgo que define el diseño, y la razón de que esto se planificara antes de ejecutar:** el rename directo de `CLAUDE.md` a `AGENTS.md` **rompe, y rompe mudo**. Verificado contra la doc oficial: Claude Code lee `AGENTS.md` nativo desde v2.1.277, pero **solo si no hay `CLAUDE.md` ni `CLAUDE.local.md` en el cwd ni en ningún directorio por encima**. Como existe uno por encima de los repos, taparía el `AGENTS.md` de cada proyecto y el agente dejaría de leer la guía operativa **sin ningún síntoma**. De ahí que la solución no sea el rename limpio sino `AGENTS.md` (contenido real) + stub `CLAUDE.md` de una línea con `@AGENTS.md`. El symlink se descartó por no ser Windows-safe: git lo checkoutea como texto plano salvo `core.symlinks`.

**Por qué el CLI no se justifica por ergonomía.** El argumento inicial (ahorro de tipeo) era débil y se corrigió durante el análisis: `scripts/oliva/deps.sh due` → `oliva deps due` no vale el churn. Lo que sí lo vale es que hoy **los docs referencian paths** y el doc agéntico es **SHARED**, así que mover, partir o renombrar un script es un diff en un archivo que cada fork también edita → superficie de conflicto en todos. Un `oliva <verbo>` estable es una **capa de indirección**: las internals se mueven sin tocar los docs compartidos. Es el mismo razonamiento que ya justifica `owned-paths.txt`, y es lo que hace al ítem 5 independiente del friction log del ítem 1.

**Hallazgo lateral que mejora el diseño:** el stub `CLAUDE.md` se declara **OLIVA-owned**. Nunca cambia y ningún fork lo edita → conflicto cero para siempre, y la superficie SHARED queda solo en `AGENTS.md` (igual que hoy, no empeora).

**Guardrail escrito por duplicado, a propósito:** los comandos de operación (`deploy`/`down`) son pass-throughs sin flags nuevos. Está en el epic **y** en el roadmap porque es la decisión más fácil de erosionar después, y el roadmap es donde alguien va a ir a buscar permiso para agregar `--cron`. Los flags son el ítem 3 y esperan la señal del ítem 1.

**Alcance de la planificación:** las fases 1-3 quedaron con gates verificables (comparar exit codes, un `grep` de completitud con allowlist de 4 archivos, `/context` para confirmar que el import carga) justamente porque el modo de falla es mudo. La fase 4 (forks) se marcó como **criterio, no mecánica**: resolver merges sobre un archivo SHARED no se delega a un checklist.

## [1.4.0] feat: capa agéntica — CLI `./oliva` + migración a `AGENTS.md` (vendor-neutral)
**Commits:** `0fb3a68` feat(cli) · `9ac83f3` feat(agents) · `e4ca9ec` docs(upgrading) · `e644e09` release
**Rama:** `main`
**Fecha:** 2026-10-23
**Ejecuta el plan de:** `docs/roadmap/epics/E-capa-agentica.md` (entrada `87632ca`). Release `v1.4.0`.

### Cambios
| Archivo | Tipo | Descripción |
|---|---|---|
| `oliva` | nuevo | Entry point del framework. Dispatcher puro (`exec` preserva args/stdin/stdout/exit) sobre `scripts/oliva/*.sh` y `scripts/*.sh`; única lógica propia: `doctor` (chequeos read-only que sobreviven a cada paso). No va al PATH. |
| `CLAUDE.md` | nuevo | Stub de 1 línea `@AGENTS.md` (import de Claude Code). OLIVA-owned. |
| `CLAUDE.md` → `AGENTS.md` | renombrado (`git mv`) | La guía operativa pasa al formato abierto. `git mv` preserva rename-detection para que el fork merjee limpio. Self-refs internas actualizadas; bloque de 7 chequeos de sanidad reemplazado por `./oliva doctor`. |
| `claude-commands.md` → `agent-commands.md` | renombrado (`git mv`) | Título `# Agent Commands`; nota de prefijo configurable. Los triggers `claude <x>` quedan igual (es frase-gatillo, no herramienta). |
| `rules-claude.md` → `AGENTS.local.md` | renombrado (`mv`, gitignored) | + entrada en `.gitignore`. |
| `scripts/oliva/owned-paths.txt` | modificado | `oliva` y `CLAUDE.md` marcados OLIVA-owned; comentario SHARED actualizado a `AGENTS.md`/`agent-commands.md`. |
| `README.md`, `docs/oliva/actualizaciones.md`, `docs/qa-y-staging.md`, `docs/concepts.md`, `scripts/deploy.sh`, `scripts/oliva/sync.sh`, `docs/roadmap/epics/E-seeding-layer.md` | modificado | Barrido de cross-refs `CLAUDE.md`→`AGENTS.md` / `claude-commands.md`→`agent-commands.md`. |
| `docs/oliva/UPGRADING.md` | modificado | Sección `## 1.4.0` (gate del release): "Acción requerida en el fork" + "Qué cambió". |
| `OLIVA_VERSION` | modificado | `1.3.0` → `1.4.0` (vía `./oliva release`). Tag anotado `v1.4.0`. |
| `agent-commits.md` | modificado | Esta entrada. |

### Justificación
**Por qué el stub `CLAUDE.md` y no el rename limpio** (lo que define todo el diseño): Claude Code lee `AGENTS.md` nativo pero **solo si no hay `CLAUDE.md`/`CLAUDE.local.md` en el cwd ni en ningún padre**; como `/home/marcos/CLAUDE.md` vive por encima de todos los repos, un `AGENTS.md` a secas quedaría tapado y el agente dejaría de leer la guía **sin ningún síntoma**. El stub (import `@AGENTS.md` en primera línea sin fence) resuelve el choque sin duplicar contenido, y se declara OLIVA-owned → conflicto cero para siempre, la superficie SHARED queda solo en `AGENTS.md`.

**Por qué el CLI vale el churn:** no es ergonomía (eso se descartó en el análisis) sino una **capa de indirección**. Los docs SHARED referencian paths de scripts; mover/partir/renombrar un script era un diff en archivo compartido → conflicto en cada fork. `oliva <verbo>` estable desacopla las internals de los docs. Mismo razonamiento que `owned-paths.txt`.

**`doctor` y `set -e`:** read-only por diseño, ningún paso puede matar al comando (helper `step()` captura cada fallo y sigue) — tiene que correr con Docker abajo, que es justo cuando más se lo necesita al arrancar. Verificado en sesión posterior: con containers abajo, el paso de migraciones informó el fallo y el resto siguió.

**Gates verificados antes del release** (el modo de falla es mudo, así que no alcanzaba con revisar el código): output idéntico CLI vs script directo, bit ejecutable (`100755`), propagación de exit codes, resiliencia de `doctor`, `verify.sh` full PASS, barrido `grep` de cross-refs con allowlist, y **gate 13** — `/context all` en sesión fresca confirmó que cargan tanto el stub `CLAUDE.md` (14 tokens) como `AGENTS.md` (11k). 

**Fuera del repo pero parte del trabajo:** `/home/marcos/CLAUDE.md` (spec de `claude new project`) se actualizó a la convención nueva en una sesión posterior — no se versiona (no es repo). La **Fase 4** (sync de forks a 1.4.0) queda pendiente, explícitamente no-mecánica, una sesión por fork.


## [1.4.1] fix: extension point de PHP por bind-mount — el CI rojo de finanzas-ong desde 1.1.0
**Commits:** `324c448` fix(backend) · `9e627c5` feat(verify) · `e05bf71` feat(doctor) · `db18c2a` docs(agents) · `e73607d` docs(upgrading) · `f9930cf` release
**Rama:** `main`
**Fecha:** 2026-10-23
**Origen:** diagnóstico `/home/marcos/diagnose.md` + auditoría de "puntos sensibles para forks" pedida por Marcos. Release `v1.4.1`.

### Cambios
| Archivo | Tipo | Descripción |
|---|---|---|
| `backend/Dockerfile` | modificado | `php-extensions.txt` entra por `RUN --mount=type=bind` en vez de `COPY --link ... /tmp/`. Líneas con `/` (`vendor/paquete:versión`) se instalan con PIE dentro del RUN de PIE. `APT::Sandbox::User=root` queda como defensa en profundidad. `DL4006` silenciado en los dos RUN con pipe. |
| `scripts/oliva/verify.sh` | modificado | Paso `[ci-build]`: rebuild del backend con un builder `docker-container` (`oliva-ci`). Solo si `php-extensions.txt` tiene extensiones. |
| `oliva` | modificado | `doctor` muestra el último run del CI en `main` (solo con `gh` instalado y logueado; timeout de 10 s). |
| `AGENTS.md` | modificado | Deuda: worker en prod (ya no es teórica), profiles en deploy, constraints sin techo. |
| `docs/oliva/UPGRADING.md` | modificado | Sección `## 1.4.1`. |
| `OLIVA_VERSION` | modificado | `1.4.0` → `1.4.1`. |
| `agent-commits.md` | modificado | Esta entrada. |

### Justificación
**Tres versiones apuntaron a la causa equivocada.** Los 9 runs rojos de finanzas-ong (sync 1.1.2 → 1.4.0) tienen el mismo error, `mkstemp /tmp/apt.sig.* Permission denied`, desde el primer push con el extension point. 1.1.2–1.1.4 (PECL→PIE) arreglaron problemas reales, pero no este: se validaron en Oliva y crypto-pulse, con `php-extensions.txt` vacío, donde el RUN del fork es no-op.

**La causa no es "el buildkit del CI" en general, es el driver.** `COPY --link` a un directorio existente deja `/tmp` en 755 con el driver buildx `docker-container` (el de `setup-buildx-action`, buildkit v0.33); con el driver `docker` local (buildkit v0.23) queda en 1777. Reproducido con un Dockerfile de 3 líneas. Por eso "local verde, CI rojo" y por eso `verify.sh` no lo podía ver.

**Por qué bind-mount y no las opciones del diagnóstico:** (A) apt global como root parchea el síntoma y deja /tmp roto para cualquier otra herramienta; (C) `chmod 1777` es igual de local. El bind-mount no crea capa, así que no hay nada que rompa /tmp, y de paso el archivo no queda en la imagen.

**Por qué `[ci-build]` es condicional:** Marcos pidió que el framework siga sirviendo para desarrollos simples. El driver local y el del CI difieren justo en el camino del extension point, así que el paso solo corre cuando el fork lo usa; sin extensiones cuesta cero. Verificado que sobre finanzas-ong sin fix **falla** (antes, verde).

**Sintaxis PIE en el extension point:** el comentario del archivo invitaba a `redis-6.2.0`, que sigue bajando de pecl.php.net — la dependencia que Oliva abandonó en 1.1.2. No se cambió el `php-extensions.txt` de Oliva: es del fork, y editar su cabecera le generaría conflicto a todo fork que haya agregado líneas.

**Descartado con pruebas** (para no reabrirlo): la purga `--auto-remove` del RUN de PIE no borra libs de runtime (gd/gmp andan); con pecl.php.net caído, las extensiones bundled instalan igual (el `Updating channel` falla y sigue).

## [1.4.2] fix: cron en prod vía `COMPOSE_PROFILES` del host + aviso si falta (#7 de la auditoría)
**Hash:** `1ad0625`
**Rama:** `main`
**Fecha:** 2026-10-23
**Origen:** auditoría "puntos sensibles para forks" (#7). Va en la release 1.4.2 (sin publicar).

### Cambios
| Archivo | Tipo | Descripción |
|---|---|---|
| `scripts/lib/cron-guard.sh` | nuevo | `warn_if_cron_inactive`: si `backend/scheduler/crontab` tiene tareas y `config --services` no incluye `scheduler`, imprime `!! CRON INACTIVO` con el fix. No aborta. Silencioso si Compose no resuelve la config. |
| `scripts/deploy.sh` | modificado | Sourcea el guard y lo llama al final. El mensaje final ya no pide `--profile cron` (editar el script). Comentario del `down` corregido: el `up` sí respeta los profiles del `.env`. |
| `scripts/deploy-staging.sh` | modificado | Sourcea y llama el guard al final. |
| `AGENTS.md` | modificado | Tabla de servicios, bloque shared-infra y runbook: `COMPOSE_PROFILES` en el `.env` del host es el mecanismo. Sale el ítem de cron de la deuda de profiles. |
| `.env.example` | modificado | Aclara que en prod vale el `.env` del host y que el deploy avisa. |
| `docs/oliva/UPGRADING.md` | modificado | Sección `## 1.4.2 — sin publicar`. |
| `agent-commits.md` | modificado | Esta entrada (commit aparte, pedido después del commit del fix). |

### Justificación
**El mensaje del script le pedía al fork romper la regla de propiedad.** `deploy.sh` es OLIVA-owned; "agregá `--profile cron` al up" solo se cumple editándolo, y el próximo sync lo pisa. El mecanismo correcto ya existía y estaba verificado (`config --services` respeta `COMPOSE_PROFILES` del `.env`): faltaba decirlo.

**Por qué un aviso y no solo docs:** el modo de falla es silencioso (el scheduler no levanta y ninguna tarea corre, sin error). finanzas-ong necesita cron en prod (auto-confirm de pagos, reintentos de notificaciones) y su `.env.example` tiene `COMPOSE_PROFILES=` vacío: exactamente el caso.

**Por qué preguntarle a Compose y no parsear el `.env`:** `config --services` resuelve lo mismo que el `up` (`.env`, variable exportada, overlays). Un parser propio driftearía.

**Por qué no aborta:** un fork puede tener el crontab lleno y elegir no correr cron en un host puntual; el deploy no debe fallar por eso. Si Compose falla al resolver, no se avisa (sería un falso positivo).

**Descartado:** sumar el aviso a `./oliva doctor`. En dev no tener `cron` activo es normal y sería ruido (decisión de Marcos).

## [1.4.2] fix: `down` con `--profile '*'` en los scripts de deploy (#8 de la auditoría)
**Hash:** `642fd13`
**Rama:** `main`
**Fecha:** 2026-10-23
**Origen:** auditoría "puntos sensibles para forks" (#8). Prerequisito del worker de prod (#6). Release 1.4.2 (sin publicar).

### Cambios
| Archivo | Tipo | Descripción |
|---|---|---|
| `scripts/deploy.sh` | modificado | `COMPOSE_PROFILES=cron ... down` → `... --profile '*' down --remove-orphans`. Comentario reescrito con el porqué. |
| `scripts/deploy-staging.sh` | modificado | Ídem. |
| `scripts/down.sh` | modificado | Ídem. |
| `scripts/down-staging.sh` | modificado | Ídem. |
| `AGENTS.md` | modificado | Sale la deuda "profiles en los scripts de deploy"; queda una nota de por qué `'*'`. La deuda del worker ya no depende de esto. |
| `docs/oliva/UPGRADING.md` | modificado | Ítem en la sección `## 1.4.2 — sin publicar`. Sin acción para el fork. |
| `agent-commits.md` | modificado | Esta entrada (commit aparte). |

### Justificación
**El disparador es el overlay, no el profile solo.** Con Compose 2.26, un `down` sin el profile activo deja corriendo (sin error) a un servicio con `profiles:` **cuando un overlay lo redefine**, como hace `prod.yml` con `scheduler`/`rabbitmq`. Con un solo archivo, el `down` sí lo baja: las primeras pruebas mínimas daban falso negativo. Con el overlay: `down` sin profile deja `scheduler`+`rabbitmq`; el `COMPOSE_PROFILES=cron` de antes deja `rabbitmq` (la variable **reemplaza** los profiles del `.env`, no suma); `--profile '*'` no deja nada. Verificado también con el `down.sh` real contra un stack busybox que imita los 3 archivos de prod, con `COMPOSE_PROFILES=queues,cron` y vacío.

**Por qué `'*'` y no listar los profiles:** una lista fija (`cron,queues`) se pudre en cuanto un fork agrega un servicio con profile propio, y el script es OLIVA-owned: el fork no la puede extender.

**Por qué es inocuo con shared-infra:** `'*'` mete en scope a `database`/`rabbitmq` desactivados (`disabled-in-shared-infra`). En ese project no tienen containers, así que el `down` no los toca; sin `-v` no se borra ningún volumen.

**Impacto real hoy:** latente. En shared-infra no corre nada de `queues` en prod (`rabbitmq` desactivado, sin `worker`), así que ningún fork lo sufría todavía. Le iba a pegar al `worker` de #6.

## [1.4.2] fix: techos en composer.json + guard de constraints sin techo (#9 de la auditoría)
**Hash:** `456aea7`
**Rama:** `main`
**Fecha:** 2026-10-23
**Origen:** auditoría "puntos sensibles para forks" (#9). Cierra la release 1.4.2 junto con #7 y #8.

### Cambios
| Archivo | Tipo | Descripción |
|---|---|---|
| `backend/composer.json` | modificado | `doctrine/doctrine-migrations-bundle` `>=3.7.1` → `^3.7.1`; `symfony/maker-bundle` `>=1.68` → `^1.68`. `bump-after-update` se queda. |
| `backend/composer.lock` | modificado | Solo `content-hash` (`update --lock`); ninguna versión cambia. |
| `scripts/oliva/unbound-constraints.php` | nuevo | Lista constraints sin techo en `require` + `require-dev` con `composer/semver` del phar (`getUpperBound()->isPositiveInfinity()`), más `dev-*`. Ignora `php`/`ext-*`. Sale 1 si hay alguno. |
| `scripts/oliva/lib.sh` | modificado | `require_bounded_constraints`: corre el guard en la imagen de herramientas y aborta con la lista. |
| `scripts/oliva/deps.sh` | modificado | `update`: guard al principio (antes de crear la rama). El resumen marca `⇑ MAJOR` (en 0.x, salto de minor). |
| `scripts/oliva/sync.sh` | modificado | `locks`: guard después del chequeo de marcadores, antes de tocar el lock. |
| `.github/workflows/ci.yml` | modificado | Job nuevo `composer-constraints` (sin build, imagen `composer/composer:2`). |
| `AGENTS.md` | modificado | La deuda "constraints sin techo" pasa a sección de convención: techos siempre, por qué bump se queda, riesgo transitivo. |
| `docs/oliva/UPGRADING.md` | modificado | #9 en la sección `## 1.4.2`; encabezado con fecha (este commit). |
| `agent-commits.md` | modificado | Esta entrada. |

### Justificación
**El riesgo no era teórico.** `doctrine-migrations-bundle` 4.0.1 ya está publicado. Con `>=3.7.1`, lo único que lo frenaba eran sus requisitos (PHP `^8.4`, `doctrine-bundle ^3`). Esa protección indirecta se caía sola el día que Oliva subiera PHP: el mismo patrón que mercure-bundle 0.6.

**Se corrigió un diagnóstico propio.** Se había atribuido parte del incidente de mercure a `bump-after-update`. Falso: el salto lo eligió `composer update` porque el `*` lo permitía. Bump solo reescribe el texto del constraint después (`*` → `>=x`, `^3.6` → `^3.7.5`) y nunca quita un techo.

**Por qué bump se queda (decisión con Marcos, con pruebas).** Su piso impide que composer **baje** versiones sin avisar. Probado en un proyecto descartable con una dep de fork que exige `doctrine/orm <3.7`:
- Sin piso, `composer require -W` bajó orm 3.7.5 → 3.6.9 con rc=0.
- Sin piso, `sync.sh locks` dejó al fork en 3.6.9 con rc=0, sin la versión que testeó Oliva.
- Con piso, los dos fallan y nombran al culpable.

El costo es diff en un archivo SHARED, que Marcos acepta.

**Por qué un guard propio y no `composer validate --strict`.** `validate` solo mira `require` (no vio `maker-bundle >=1.68` en `require-dev`) y deja pasar `dev-main`. El guard reusa la lógica de composer en vez de una regex: se probaron 10 formas de constraint.

**Por qué en esos tres lugares y no en `verify.sh`.** El CI no corre `verify.sh`, y en `deps.sh update` el verify corre después del `composer update`, cuando el major ya entró. El guard tiene que estar antes de cada `composer update` que corre el tooling (`deps.sh update`, `sync.sh locks`) y en el CI para lo que se agrega a mano.

**`⇑ MAJOR`.** Los techos cubren las deps directas. Una transitiva puede saltar si la directa declara compatibilidad (orm acepta `dbal ^3 || ^4`). No se bloquea, porque es una promesa del upstream, pero se hace visible antes de mergear.

**Verificación end-to-end** en un clon descartable de finanzas-ong contra este `main`:
- Merge limpio de `composer.json`.
- `sync.sh locks` cambia solo el hash.
- Una dep propia con `*` aborta `sync.sh locks` sin tocar el lock.
- `>=1.68` commiteado aborta `deps.sh update` sin crear rama.

No se corrió un `deps.sh update` real (el ciclo no toca) y el job de CI recién corre con el push.

## [docs] Roadmap: "composable services": cada rol es un slot default / reemplazado / ausente
**Hash:** `294cf25` (ítem 6, backend reemplazable) + `28bf5dd` (fusión de 2+4+6). El hash de esta entrada es el del commit que la agrega.
**Rama:** `main`
**Fecha:** 2026-10-23

### Cambios
| Archivo | Tipo | Descripción |
|---|---|---|
| `docs/roadmap.md` | modificado | El principio rector "decoupling → full optionality" pasa a ser la escalera de 3 pasos y la tabla de estados de un slot. Los ítems 2 (optionality), 4 (shared-infra como flag) y 6 (backend reemplazable) se fusionan en el ítem 2 "Composable services". El agent layer pasa de 5 a 4. Diagrama de secuencia actualizado. |
| `agent-commits.md` | modificado | Esta entrada. |

### Justificación
**La idea de Marcos, llevada a su fin.** Oliva va de "algunos servicios opcionales + shared-infra" a "ningún servicio obligatorio" y después a "todo opcional y reemplazable", ofreciendo y recomendando lo que ya tiene robusto. Al escribirlo apareció que esos tres pasos son el mismo mecanismo: opcional = reemplazado por nada, y shared-infra ya era reemplazar por algo externo. Por eso se fusionaron: tres ítems separados repetían la misma tesis con distintos ejemplos.

**Por qué un solo default robusto por rol (decisión de Marcos).** Casi toda la red de guards es PHP: `deps.sh`, `sync.sh locks`, `unbound-constraints`, `verify.sh` y el CI. Duplicarla por stack no es sostenible para un mantenedor solo. Marcos es core PHP y no puede garantizar robustez de otro stack escribiéndolo a fuerza de prompts. Un guard escrito sin dominar el stack es peor que ninguno, porque sugiere una protección que no existe. Por eso el reemplazo corre por cuenta de quien reemplaza, y Oliva lo **avisa** (`doctor`/`verify`/CI). Es el principio de "ninguna falla silenciosa" aplicado a los límites de Oliva. El estado ausente no cuesta nada ni imprime nada. Queda abierta la puerta a contribuciones: una alternativa pasa a ser default cuando alguien se hace dueño de su red.

**Lo no obvio que encontró el análisis.**
- Los containers mezclan roles. `frontend` es también el gateway: si se reemplaza por Next.js, se pierde en silencio el ruteo a `/api` y los headers de seguridad. `backend` es también el hub de Mercure y el que corre el ciclo de vida de la DB. `scheduler` y `worker` usan la imagen del backend.
- Separar roles es el primer paso, y sirve aunque nadie reemplace nada.
- Hay dos clases de slot: independiente (gateway, frontend, realtime) y atado al backend (DB, cola, worker, scheduler, que los habla Doctrine o Messenger).

**Descartado / diferido.**
- Sacar Mercure a su propio servicio **no se hace ahora** (decisión de Marcos). Queda dentro del ítem 2. Revierte la decisión de `oliva-upgrade-optional-services.md` cuando se trabaje.
- La forma limpia del ítem sigue esperando al scaffolding (ítem 3), porque los profiles no sacan código ni cortan el sync de `owned-paths`.

**Renumeración segura.** La única referencia externa a un número del roadmap es "item 3", en `E-capa-agentica.md`, y sigue siendo válida.

## [1.4.3] feat(deps): 4ª capa del audit — runtime PHP/FrankenPHP (Trivy no ve a PHP)
**Hash:** el del commit que agrega esta entrada (self-referencial; fijar el SHA exacto re-amendaría y lo cambiaría otra vez)
**Rama:** `main`
**Fecha:** 2026-10-24

### Cambios
| Archivo | Tipo | Descripción |
|---|---|---|
| `scripts/oliva/deps.sh` | modificado | Capa `runtime` nueva: `check_runtime` (orquesta + guarda C1 base-no-frankenphp), `check_php_runtime` (DURO: rama en php.net, `rc=1` si hay patch más nuevo; guardas C2 tag ilegible / C3 versión no figura en php.net), `check_frankenphp_runtime` (BLANDO: frescura vs. último release de GitHub, con `curl -L`). `report_runtime` informativo. Cableada en `cmd_audit` (afecta exit code vía PHP) y `cmd_report`. Localiza sus libs por `BASH_SOURCE` (no `$0`) y el dispatcher va tras guarda `[[ BASH_SOURCE == $0 ]]` para sourcear en tests. |
| `README.md` | modificado | §3: de tres a cuatro capas; corregido el texto que atribuía el runtime de PHP a Trivy; 4º bullet del runtime compilado, en positivo. |
| `docs/oliva/actualizaciones.md` | modificado | Tabla de capas: 4ª fila (runtime compilado) + párrafo del hueco (Trivy no ve PHP) y el diseño duro/blando. |
| `docs/oliva/UPGRADING.md` | modificado | Sección `## 1.4.3`: acción requerida en forks (ninguna, archivo owned) + qué cambió. |
| `agent-commits.md` | modificado | Esta entrada. |

### Justificación
**El hallazgo no obvio: Trivy no ve a PHP.** En la imagen de FrankenPHP, PHP y el propio
servidor salen **compilados del source**, no figuran como paquete, y Trivy no los matchea
contra ninguna CVE DB. Se probó empíricamente (Trivy 0.72.0 sobre la imagen vulnerable a
PHP2Shell → 0 rastro). `composer`/`yarn audit` tampoco (PHP no es paquete). El único aviso
posible era `deps report` mostrando el bump de imagen cada ~45 días, sin marca de seguridad.
O sea: el sistema de tres capas no hubiera cazado PHP2Shell. Esta capa cierra ese runtime.

**Qué resuelve y qué no (sin disclaimer de meteoritos, decisión de Marcos).** No es detección
de lo no publicado — eso es imposible y nadie lo hace. Avisa cuando el upstream **ya publicó**
un patch más nuevo, que es la ventana n-day donde pasa casi todo el ataque real. Es exactamente
el upgrade "una vez identificado por la comunidad, parcheable por esta vía".

**Por qué duro para PHP y blando para FrankenPHP.** Separado por confianza de la fuente, no por
proyecto. php.net lista cada release de la rama con fuente limpia → chequeo duro que falla el
audit. El módulo Go de FrankenPHP sale pseudo-versionado (`v0.0.0-…`) y no se matchea con
advisories con confianza → solo frescura, aviso blando que no falla. Es un flag menor, presente
pero sin pretender que resuelve advisories (no se entierra).

**El punto sensible: el parseo del `FROM`.** Si no se puede confiar en el parseo, NO se reporta
"al día" — un falso verde es peor que no tener la capa. Tres guardas que avisan y saltean, nunca
pasan en silencio: C1 base que no es frankenphp, C2 tag ilegible, C3 la versión pinneada no
figura en php.net para esa rama (parseo roto o rama EOL). Probado con 7 casos contra php.net y
GitHub reales: pin viejo `8.3.35` → `rc=1` marcando `8.3.36`; pin actual `8.3.36` → verde;
bogus/basura/base-node → warn+skip rc=0; FrankenPHP `1.13.2` → aviso blando `→ 1.13.3`.

**Dos fallas derivadas encontradas en el camino.** (1) `dunglas/frankenphp` hace 301 redirect
(el repo se movió) → sin `curl -L` volvía `null`; la capa blanda lo usa. (2) Para testear sin
docker, `deps.sh` se hizo sourceable (guarda `BASH_SOURCE` + locate de libs por `BASH_SOURCE`),
sin cambio de comportamiento al ejecutarlo normal.

**No se tocó `OLIVA_VERSION` ni se corrió `release.sh`.** La sección de UPGRADING queda lista
para que `release.sh 1.4.3` la exija al publicar, cuando Marcos lo pida.

---

## [PASO 4.1] fix(prod): worker mode de FrankenPHP ON por defecto — quitar el apagado silencioso del env_file
**Hash:** `f394cc50fc8c84a788d6f42b7edc144af20c6137`
**Rama:** `main`
**Fecha:** 2026-10-24

### Cambios
| Archivo | Tipo | Descripción |
|---|---|---|
| `.env.example` | modificado | Quitada la línea `FRANKENPHP_CONFIG=` (vacía). Reemplazada por un comentario que explica por qué NO debe definirse acá. |
| `backend/frankenphp/worker.Caddyfile` | modificado | `env FRANKENPHP_LOOP_MAX 500` explícito (era el default implícito del runtime Symfony). |
| `.github/workflows/ci.yml` | modificado | Job `prod-config`: step nuevo que falla si el stack prod resuelve `FRANKENPHP_CONFIG=''` a nivel compose. |
| `scripts/oliva/verify.sh` | modificado | Step `prod-worker`: tras `prod-build`, verifica que la imagen prod hornee `FRANKENPHP_CONFIG=import worker.Caddyfile` (inspect de ENV). |
| `backend/docs/production.md` | modificado | Nota de opt-out corregida: worker ON por imagen; para clásico, var vacía en el `environment:` de `prod.yml`, NUNCA en `.env`. |
| `docs/oliva/UPGRADING.md` | modificado | Sección 1.4.3: acción requerida para forks (borrar `FRANKENPHP_CONFIG` del `.env` del host, local y VPS) + qué cambió. |
| `docs/concepts.md` | modificado | Hallazgo 2026-10-23 cerrado: de "Fix pendiente" a "✅ Resuelto en 1.4.3" con el cómo y las tres guardas. |
| `agent-commits.md` | modificado | Esta entrada. |

(El `.env` local de desarrollo quedó alineado —línea quitada— pero es gitignored y no entra en el commit.)

### Justificación
**El bug (confirmado en código, no en memoria).** La imagen `frankenphp_prod` siempre horneó
`ENV FRANKENPHP_CONFIG="import worker.Caddyfile"` → worker mode. Pero `backend` carga
`env_file: [.env, .env.backend]`, y `.env.example` shipeaba `FRANKENPHP_CONFIG=` vacío. En
Compose, una variable de `env_file` **pisa el `ENV` de la imagen aunque esté vacía**. Resultado:
prod corría clásico, en silencio (`/health` daba ok igual). No es teórico y no se había
ejercitado en ningún lado: CI levanta solo dev (clásico a propósito), staging hereda de prod
(mismo override), y no hay commits que lo probaran — solo docs.

**El fix (mínimo, alineado al upstream).** `backend/docs/production.md` del template original ya
documentaba el opt-out correcto: apagar worker = agregar `FRANKENPHP_CONFIG` vacío al
`environment:` de `prod.yml` (deliberado, por deploy). Oliva lo había roto al shipear el vacío en
el `env_file` base (global a todos los entornos). El fix es sacar esa línea: gana el valor
horneado por imagen (dev=clásico, prod=worker). Cero código PHP nuevo.

**Decisión de diseño (con Marcos).** Opt-out a clásico = la vía documentada (línea explícita en
`prod.yml`), NO un flag con nombre propio (`FRANKENPHP_WORKER=on|off`). Menos superficie que
mantener y sincronizar a forks; el único cambio es dejar de shipear el apagado accidental.

**Tres guardas contra la regresión** (porque `docker compose config` NO ve el `ENV` de la imagen,
cada capa cubre una mitad): (1) CI `prod-config` — el compose no debe resolver la var a vacío;
(2) `verify.sh prod-worker` — la imagen debe hornear el valor; (3) prueba empírica de levantar
prod local. Juntas prueban "worker on en prod" sin levantar un stack prod completo en CI.

**Verificación empírica (prod local, 2026-10-24).** Build + up del stack prod standalone:
`worker_threads: 16` en el arranque de FrankenPHP (en clásico sería 0) ⬅️ la prueba que faltaba;
`/health` ok; migraciones up-to-date; Mercure 200 + pub/sub privado entregado solo al suscriptor
con token (sin fuga) bajo worker mode; 0 de 300 requests no-200 (reuso de proceso/conexión sano).

**Pendiente (no bloquea el fix).** (1) E2E bajo carga real en el VPS y reciclado sostenido: el
boundary de `FRANKENPHP_LOOP_MAX=500` no es testeable local (16 threads → ~8000 requests para
forzar un respawn); el loop es código canónico del runtime upstream. (2) Test de fuga de identidad
fino: Oliva no tiene endpoint autenticado de dominio (solo `HealthController`) — es chequeo de
cada fork con auth real. (3) Migración de forks: borrar `FRANKENPHP_CONFIG` del `.env` del host
(gitignored, el merge no lo limpia) — ya escrito en `UPGRADING.md` 1.4.3.

**No se tocó `OLIVA_VERSION` ni se corrió `release.sh`.** Este cambio cierra el segundo frente de
1.4.3 (el primero fue la 4ª capa del audit, `61eb6bc`); el release se publica cuando Marcos lo pida.

## [1.5.0] feat(sync): acciones de upgrade que no se pierden — guards + ack por máquina
**Hash:** el del commit que agrega esta entrada (self-referencial, ver nota en [1.4.3])
**Rama:** `feat/upgrade-actions` → `main`
**Fecha:** 2026-10-24

### Cambios
| Archivo | Tipo | Descripción |
|---|---|---|
| `scripts/lib/upgrade-guards.sh` | nuevo | Registro de guards (`cron`, `worker-env`, `worker-image`) + `run_upgrade_guards` (solo avisa, rc 0 siempre); pendientes por máquina (`.oliva/acked-version`, `seed_acked_version`, `pending_upgrade_actions`, `show_pending_upgrade_actions`, `ack_upgrade_actions`); `lint_upgrade_actions` para `release.sh`. Sin `jq`; lee `UPGRADING.md` con `git show`. |
| `scripts/lib/cron-guard.sh` | modificado | `warn_if_cron_inactive` devuelve 1 al avisar (contrato de guard). Solo se llama vía `run_upgrade_guards`. |
| `scripts/oliva/verify.sh` | modificado | `prod-worker` = `guard_worker_image` + `guard_worker_env`. Fix del falso positivo de `config --images \| head -1`. |
| `scripts/deploy.sh`, `scripts/deploy-staging.sh` | modificado | Siembran el estado antes del `git pull`; al final, guards + acciones `[host]` pendientes. Reemplazan la llamada directa al cron-guard. |
| `scripts/oliva/sync.sh` | modificado | `start` siembra antes del merge; subcomandos `pending` y `ack`; ayuda actualizada. |
| `scripts/oliva/release.sh` | modificado | Desde 1.5.0 corre `lint_upgrade_actions` sobre la sección que publica. |
| `oliva` | modificado | `./oliva ack`; `doctor` suma el paso "acciones de upgrade" (`sync.sh pending`). |
| `docs/oliva/UPGRADING.md` | modificado | Cabecera: formato de etiquetas + escala eliminar > guard > etiqueta > texto. Sección `## 1.5.0`. |
| `docs/oliva/actualizaciones.md` | modificado | Paso 5 del lado fork + sección "Acciones de upgrade: por qué no alcanza con escribirlas". |
| `AGENTS.md` | modificado | Flujo de sync termina en doctor → ack; al escribir una acción, preguntarse primero si lleva guard. |
| `agent-commits.md` | modificado | Esta entrada. |

### Justificación
Nació del sync de finanzas-ong a 1.4.3, que dejó dos tareas para Oliva.

**Causa raíz, medida en el código, no en la conducta del lector.** `sync.sh` mostraba las notas
de upgrade como "secciones más nuevas que el `OLIVA_VERSION` local": solo antes del merge. Después
el fork queda en la versión de upstream y no vuelven a aparecer. Pero las acciones de host (el
`.env` del VPS) se hacen después y en otra máquina, y `deploy.sh` no mostraba nada; además borra
`docs/` del working tree del host. Los pendientes de VPS de 1.4.2 y 1.4.3 en fong solo
sobrevivieron porque el agente los anotó en su memoria. La propuesta inicial ("que el agente lo
tome en serio") apuntaba al síntoma.

**Decisiones:**
- *Guards antes que avisos.* Clasificando las acciones de 1.3.0–1.4.3, casi nada era manual de
  verdad: era estado fuera de git (un `.env`, otro host). Eso se chequea donde vive: `verify` en
  desarrollo, `deploy*.sh` en el host. Precedente que ya funcionaba: el cron-guard de 1.4.2.
- *El ack no calla a un guard.* El lector es casi siempre un agente; si "corré ack para que deje de
  avisar" silenciara un chequeo, lo correría. Un ítem con guard nunca se lista como pendiente:
  desaparece cuando el estado está bien.
- *Pendientes por diferencia de versión por máquina, no por evento de sync.* El host nunca corre
  `sync.sh` (hace pull + deploy), así que un state file escrito por `sync` no le llegaría.
  `.oliva/acked-version` vs `OLIVA_VERSION`, uno por checkout: dev y host reconocen lo suyo.
- *Siembra en silencio, antes del cambio de versión* (decisión de Marcos). Un host o clon nuevo
  arranca del template vigente y no arrastra historia; sembrar antes del pull/merge hace que lo
  que llega quede pendiente. Lo anterior a 1.5.0 lo cubren los guards.
- *Guards solo avisan, nunca abortan* (decisión de Marcos): el stack ya está arriba; abortar se
  reserva para riesgo de datos.
- *`release.sh` exige etiquetas, no guards.* No puede saber si algo se puede chequear; sí puede
  obligar a quien escribe el release a declarar el lugar y a responderse por qué no hay guard.
- *Sin `jq`* en lo que corre en el host (no verificable hoy: no hay VPS). Se parsea el bloque YAML
  del servicio en `config`; probado con `mawk`, el default de Ubuntu.

**Problema encontrado en la ejecución (tarea 1).** El falso positivo de `prod-worker` en fong
no era una diferencia de entorno: `config --images backend` lista también las imágenes de los
`depends_on` en orden **no determinista** (en Oliva, 5 de 6 corridas daban `pgvector` primero).
Oliva pasó el verify de 1.4.3 por suerte. Además, el fix que quedó anotado en fong (reemplazar el
chequeo de imagen por el del env) perdía una guarda: si alguien saca el `ENV` del Dockerfile, el
env da `unset` y pasa. Quedaron los dos chequeos.

Verificado: `verify.sh` 9/9; guards contra el repo real (imagen 10/10, `.env` viejo detectado) y con
compose falso (DB listada antes que el backend, imagen inexistente, compose que no resuelve);
pendientes/ack/siembra/lint en un clon con una 1.5.1 de fixture; shellcheck sin errores.

**Revisión post-release → 1.5.1 (`fix(sync): ajustes de 1.5.0 tras revisión`):** `release.sh` deja reconocida la versión que publica (sin esto, el `doctor` de Oliva listaba como pendientes las acciones de los forks; confirmado en clon). Hallazgo no obvio: `git pull` reemplaza `deploy.sh` con un inode nuevo y bash termina de ejecutar el script **viejo** (probado), así que el deploy que trae 1.5.x no corre los guards → acción `[host]` en 1.5.1 (`git pull && SKIP_PULL=1 ./scripts/deploy.sh`). Además: fences ignorados en lint/pendientes, `ack` robusto con `set -e`. Deploy simulado en clon: el tramo final con `docs/` borrado dio los 3 avisos.

---

> Entries from here on are written in English and address the maintainer by role
> (roadmap item 5). Earlier entries stay as they were written.

## [1.6.0 · phase 1] fix(security): no secrets in tracked env files; no public fallback for the Mercure key
**Hash:** `14da99c04e5f` (phase 1 of the epic; the epic doc is `2a1278c`)
**Branch:** `feat/config-contract`
**Date:** 2026-11-14

### Changes
| File | Type | Description |
|---|---|---|
| `.env.backend` | modified | Non-secret defaults only. `APP_SECRET`, `JWT_PASSPHRASE`, `RABBITMQ_*`, both Mercure keys and the commented shared-infra `DATABASE_URL` are gone. |
| `docker-compose.yml` | modified | `frontend` loads only `.env.frontend` (it was receiving every backend secret through `.env`). |
| `backend/frankenphp/Caddyfile` | modified | Mercure key: no default, quoted. |
| `backend/frankenphp/docker-entrypoint.sh` | modified | Refuses to start the server when `MERCURE_PUBLISHER_JWT_KEY` is empty. |
| `backend/frankenphp/known-public-secrets.sha256` | new | SHA-256 of every value a secret variable ever had in a tracked file, plus placeholders and CI values (19). No consumer yet (phase 3). |
| `.env.example`, `backend/.env`, `docker-compose.shared-infra.yml` | modified | Comments: secrets and `DATABASE_URL` live in `.env`, in shared infra too. |
| `.env.prod` | deleted | A `#TODO` nobody read. |
| `docs/roadmap/epics/E-config-contract.md` | new | The epic (previous commit). |
| `agent-commits.md` | modified | This entry (separate commit). |

### Why
Found while reviewing the framework for its next epic, not from an incident: `.env.backend` is
tracked and is listed **after** `.env` in `env_file`, so it wins. Measured with
`docker compose config` on the prod stack: `APP_SECRET`, `JWT_PASSPHRASE` and both Mercure keys
resolved to the committed values regardless of `.env`. The repo is public and both apps carry the
same values. The local `.env` of this checkout had placeholders in all four and everything worked,
which is the tell: filling in `.env` never had any effect.

It also invalidated the work that was planned next (a `doctor` guard for placeholders in `.env`
plus an `env:init` that generates secrets into `.env`): both would have reported success while the
committed values kept winning. Hence the rule the epic sets for the check: look at what Compose
**resolves**, not at what a file says.

**Decisions:**
- *`.env` is the only home for secrets*, shared infra included. The old layout had the host edit
  a tracked file (`.env.backend`) to set `DATABASE_URL`: a password in a tracked file, and a
  conflict with the `git pull` of `deploy.sh` waiting to happen. One gitignored file per machine
  is simpler than a third layer.
- *`backend/.env` keeps its `changeme` placeholders.* Removing them would make Symfony fail on a
  missing variable, which is the loud failure wanted, but it also breaks the image build
  (`cache:clear`, `dump-env prod`) and it is a file every app shares with Symfony recipes. They
  are in the hash list instead, and phase 3 refuses them in production.
- *Hashes, not plaintext,* in the public-values list: the values are public already, but a list
  of plaintext secrets trips every secret scanner and reads like an invitation.

**Found during execution.** Removing the Caddyfile default was not enough and, done naively, made
things worse. With the variable empty and unquoted, Caddy drops the token and parses
`publisher_jwt HS256` with **`HS256` as the key**, and reports "Valid configuration". Quoted, an
empty key is also accepted. Caddy cannot be the component that fails, so the entrypoint is: it
refuses to start the server without a key.

Verified: resolved config of dev, prod and prod+shared-infra (all four secrets come from `.env`
in `backend` and `scheduler`, none in the public list; `frontend` receives no secret, counted in
the running container too); entrypoint with an empty key exits 1 with the fix; `verify` 9/9, its
`mercure` step running on the key from `.env`. Not verified: CI (it still writes its own
`.env.backend`; changes in phase 4).

---

## [1.6.0 · phase 2] feat(env): `./oliva env init` — manifests of variables per slot
**Hash:** `a652e1f`
**Branch:** `feat/config-contract`
**Date:** 2026-11-14

### Changes
| File | Type | Description |
|---|---|---|
| `scripts/oliva/env.manifest` | new | Oliva's variables: `NAME SLOT KIND VALUE`. Kinds `secret`, `stateful`, `derived`, `plain`; values `gen:hexN`, `same:VAR`, `-` or a `${VAR}` template. |
| `env.manifest` | new | The app's extension point, shipped empty (same pattern as `backend/php-extensions.txt`). |
| `scripts/oliva/env.sh` | new | `init`: creates `.env` from `.env.example` or repairs an existing one. |
| `oliva` | modified | `env` command. |
| `scripts/oliva/verify.sh`, `backend/frankenphp/docker-entrypoint.sh` | modified | Their "missing `.env`" / "empty key" messages now name `./oliva env init`. |
| `scripts/oliva/owned-paths.txt` | modified | `env.manifest` listed as an extension point. |
| `docs/roadmap/epics/E-config-contract.md` | modified | Three rules learned while testing (below) and one change of plan. |

### Why
Replaces `cp .env.example .env` plus filling four secrets by hand. Each rule below exists because
the obvious implementation breaks something without an error.

- *The JWT key is the upgrade path, not a corner case.* The private key is encrypted with
  `JWT_PASSPHRASE`. Until 1.6.0 the effective passphrase was the committed one, so **every existing
  key** is encrypted with it; after phase 1 the effective one becomes whatever `.env` holds, and
  every login would start failing with nothing wrong at boot. `init` therefore re-encrypts any key
  the passphrase of `.env` doesn't open (same key pair, nobody is logged out), looking for the old
  passphrase in the previous `.env` and in the git history of the tracked env files. Keys created
  by the container are root-owned, so that case goes through a container. It was live in this very
  checkout: `secrets/jwt/private.pem` still opened with the public passphrase.
- *A stateful secret is generated only while nothing stored it.* Postgres and RabbitMQ keep the
  password of their first start in the data volume; rotating the variable alone locks the app out
  of its own database. `init` asks Docker whether the slot's volume exists. No volume: generate.
  Volume, or Docker unreachable: leave it and print how to rotate.
- *A derived value that doesn't match its sources is external.* First version: recompute
  `DATABASE_URL` whenever `POSTGRES_PASSWORD` changes. On a shared-infra host that rewrites the
  provisioned URL to the local `database` service. Now it is recomputed only if the current value
  equals what the old sources would have produced.
- *If nothing opens a key, nothing changes* and the command exits 1: a new passphrase can't help
  and could bury the one that works.

**Change of plan:** `.env.example` stays hand-written instead of generated from the manifests. Its
comments carry gotchas and apps add their own lines to it (it is a SHARED file); a lint will keep
it in step with the manifests (phase 3).

Verified: fresh clone → `init` → `verify` 9/9, second run "nothing to do"; old `.env` with the
public values and a root-owned key (secrets replaced, key opens with the new passphrase and no
longer with the public one, same public key); key with an unknown passphrase (exit 1, nothing
changed); shared-infra `DATABASE_URL` untouched; without Docker; malformed manifest; app manifest;
shellcheck clean. Not verified: an HTTP login (Oliva has no login endpoint) and a real host.

---

## [1.6.0 · phase 3] feat(env): `./oliva env check` — the resolved environment, checked where it is used
**Hash:** `a019fe9`
**Branch:** `feat/config-contract`
**Date:** 2026-11-14

### Changes
| File | Type | Description |
|---|---|---|
| `scripts/lib/env-check.sh` | new | `env_check <full\|quiet> COMPOSE...` and `guard_env`. Also the helpers `env.sh` shares: manifest reader, "is this value a secret at all", JWT key access. bash + awk, no `jq`. |
| `scripts/oliva/env.sh` | modified | `check [--prod]`; uses the shared helpers. |
| `oliva` | modified | `doctor` gets the step `env` (reports, never fails it). |
| `scripts/oliva/verify.sh` | modified | Step `env`, first, and it fails. Its name is the guard id `env` for `UPGRADING.md`. |
| `scripts/deploy.sh` | modified | Aborts before `down` on an env error. When `up` fails, prints the last lines of the backend log. |
| `scripts/deploy-staging.sh` | modified | Warns (after the stack is up). |
| `backend/frankenphp/docker-entrypoint.sh` | modified | `APP_ENV=prod`: refuses to start on an empty, placeholder or public value of the four framework secrets. `staging`: warns. |
| `backend/Dockerfile` | modified | Copies the public-values list into the image. |
| `docs/roadmap/epics/E-config-contract.md` | modified | Status and the decisions below. |

### Why
The check had to be built on `docker compose config`, not on `.env`: the incident was a tracked
file overriding `.env`, and anything that parses `.env` passes it. Hence also the wording of the
fix: when the resolved value isn't the one in `.env`, the message does not say `env init` (which
would change nothing) but "something overrides `.env`, remove it there".

**Decisions:**
- *The first guard that aborts.* The rule from 1.5.0 stands (guards warn, the stack is already
  up). This one runs before `down`, so aborting costs nothing: the current stack keeps serving.
  Decided by the maintainer: a publicly known secret in production aborts.
- *Entrypoint as the net under the deploy check, with no escape variable.* Three paths never reach
  the check in `deploy.sh`: the standalone `docker compose up` the README documents, any manual
  `up` on a host, and the first deploy that brings 1.6.0 (`git pull` replaces `deploy.sh` while
  bash is still running the old one, the 1.5.1 gotcha). The entrypoint is inside the image that
  same deploy builds. Its cost is honest: there the old stack is already down, so it turns a silent
  exposure into an outage. No switch to turn it off, because there is no legitimate production on
  a public secret and a switch is what an agent would flip to make the container start.
- *A stateful secret only warns, in production too* (pending the maintainer's confirmation).
  Rotating a database password is not one command, and the service isn't reachable from outside
  the app's network. Aborting would block a host until someone does an `ALTER USER` by hand.
- *Slot states are inferred from the resolved state, not declared.* A `DATABASE_URL` whose host
  isn't `database` is a replaced slot, announced on every run. A flag could drift from reality;
  declaration belongs to roadmap item 3.
- *Called explicitly, not through `UPGRADE_GUARDS`.* The registry runs after `up` and only warns;
  production needs it before `down`. `guard: env` is still valid in `UPGRADING.md` because the
  lint accepts verify steps.

Verified: every finding reproduced on purpose in a clone (placeholder, public value, tracked file
overriding `.env`, real secret in a tracked file, Mercure keys that differ, `DATABASE_URL` against
`POSTGRES_PASSWORD`, secrets reaching the frontend, JWT key that doesn't open, replaced database
with and without a placeholder, app secret without a value, no `.env`, no Docker). A real
`deploy.sh` on a temporary shared-infra setup (two networks and a Postgres, removed afterwards):
healthy deploy announces `database REPLACED`; with a public `APP_SECRET` it exits 1 and the same
containers keep answering `/health`; a direct `docker compose up` with that secret fails with 1
and the reason is in the backend log; `env init` then deploy brings it back. `verify` 10/10.
`doctor` survives without Docker. Not verified: a real host, CI.

---

## [1.6.0 · phase 4] ci: environment through `./oliva env init`; job `env-contract`
**Hash:** `856c08b`
**Branch:** `feat/config-contract`
**Date:** 2026-11-14

### Changes
| File | Type | Description |
|---|---|---|
| `.github/workflows/ci.yml` | modified | `tests`: `./oliva env init` replaces `cp` + `sed` + a heredoc that rewrote `.env.backend`. New job `env-contract` (no build): `env init`, then `env check` on the dev and prod stacks. |
| `scripts/lib/env-check.sh` | modified | With `CI=true`, a secret a person provides (`-` in the manifest) only warns. New error: `DATABASE_URL` pointing at the local `database` service in a stack that doesn't run it. |

### Why
- *CI was part of why the bug stayed hidden.* It overwrote the tracked `.env.backend` with its own
  values on every run, so it never tested the file the apps actually shipped. It now runs the
  command a newcomer runs.
- *No separate `tracked-secrets` job* (the epic planned one): `env check` already includes the
  tracked-files check and also catches the other half, a tracked file overriding `.env` with a
  placeholder or a public value. One job, same code as `verify` and `deploy`.
- *No `OLIVA_CI_SKIP` for it.* Same reason as no escape variable in the entrypoint.
- *`CI=true` instead of a flag.* An app with an API key in its manifest would be red forever in
  CI, which has no real value for it. A flag on `env init` that fills in throwaway values was the
  alternative; it is exactly what would get used locally to quiet the check.
- *The shared-infra case came from writing the upgrade notes:* a host that pulls 1.6.0 and
  forgets to move its `DATABASE_URL` from `.env.backend` to `.env` resolves the standalone URL,
  the database slot looks absent, and the check said nothing. Now it is an error before `down`.

Verified locally by running the job's commands in a clone: clean branch passes; a real key
committed in `.env.backend` fails; the same key moved to `.env` passes in CI and is required
without `CI=true`; a placeholder in `.env.backend` overriding the real value in `.env` is named as
an override; the old public `APP_SECRET` back in `.env.backend` fails. `actionlint` clean.
Not verified: a real run on GitHub (CI only runs on `main`).

---

## [1.6.0 · phase 5] docs: the config contract in README, AGENTS.md, runbooks and UPGRADING
**Hash:** `f8e9049`
**Branch:** `feat/config-contract`
**Date:** 2026-11-14

### Changes
| File | Type | Description |
|---|---|---|
| `AGENTS.md` | modified | New section "Environment contract"; structure list; shared-infra runbook steps 1, 2 and 4; env variables; `doctor` and CI descriptions. |
| `README.md` | modified | Quickstart, production note, "silent before / loud now" rows, `./oliva` table, CI jobs, where env files live, project structure. |
| `docs/oliva/UPGRADING.md` | modified | Section `## 1.6.0` and the note that sections are in English from here on. |
| `scripts/lib/upgrade-guards.sh`, `scripts/oliva/sync.sh` | modified | Accept `**Action required` next to `**Acción requerida`, and the place `decision`. |
| `docs/qa-y-staging.md` | modified | `verify` steps and CI jobs brought up to date (it said 8 steps and three jobs); stale note on advisories replaced. |
| `docs/sanity-checks.md`, `docs/oliva/actualizaciones.md` | modified | `env` step and the `env.manifest` extension point. |
| `docs/roadmap.md`, `docs/roadmap/epics/E-config-contract.md` | modified | Pointer from item 2 to the epic; status and what changed from the plan. |

### Why
- *`UPGRADING.md` in English, forward-only.* Roadmap item 5 left this decision open and called
  forward-only the cheaper bet. A security release that every app must act on is the wrong one to
  ship in a language a fork may not read. Old sections are untouched; the parser takes both
  headings. The `sync.sh` of an app still on 1.5.1 prints whole sections, so it shows this one
  as is (checked with its own awk).
- *The upgrade actions are guarded where they can be.* `[local, guard: env]` is the `env` step of
  `verify`; `[host, guard: env]` is the abort in `deploy.sh` plus the entrypoint. Only the
  password-manager backup is unguarded and shows until `./oliva ack`.
- *The host action asks to rotate before deploying* (`git pull && ./oliva env init &&
  SKIP_PULL=1 ./scripts/deploy.sh`), and says what happens otherwise: that first deploy runs the
  old script, so the entrypoint is what stops it, after the old stack is down.
- `AGENTS.md` keeps its Spanish sections; only what this epic touches is in English. Translating
  the whole file is item 5's own work and a larger merge for every app.

Verified: `release.sh`'s lint accepts section 1.6.0 (and still 1.5.1); a simulated app going
1.5.1 → 1.6.0 lists only the unguarded item in `doctor` and on the host, and `ack` clears it;
`verify` 10/10 on the final tree; shellcheck clean.

## [friction log · phases 0–3] docs: the friction log, two runs and a triage
**Hash:** `4f32a74` (last of five on the branch; 1.6.1 is `38d9422`, the CI fix `9ab188d`)
**Branch:** `feat/friction-log`
**Date:** 2026-11-14

### Changes
| File | Type | Description |
|---|---|---|
| `docs/friction-log.md` | new | 20 entries (temporal, spatial, security), run 1 (clean-room bootstrap), run 2 (audit), the table of what varies between apps and a ranked triage. |
| `docs/roadmap/epics/E-friction-log.md` | new | Analysis, sensitive points, phases, decisions, outcome. |
| `docs/roadmap.md` | modified | Item 1 points at the log. |
| `.github/workflows/ci.yml` | modified (on `main`) | Mercure reachability step cut at 5 s; it waited ~9.5 min per run. |
| `backend/composer.lock`, `frontend/yarn.lock`, both Dockerfiles, `docs/oliva/UPGRADING.md`, `OLIVA_VERSION` | modified (on `main`) | Dependency cycle released as 1.6.1 after run 2. |

### Why
- *The apps left the critical path.* The first plan opened with bringing 1.6.0 down to the two
  older apps, because they run on public secrets. None is in production, so that is not a live
  hole; the maintainer cut it. The apps are read-only evidence and no sync run was made.
- *Record, do not fix, during a run.* Run 1 found the first integration test broken and `doctor`
  showing Oliva's CI in an app with no `origin`. Both were left as rows. The one exception was
  taken after run 2, on request: the audit was red (14 Symfony advisories), so a dependency cycle
  ran and shipped as 1.6.1.
- *The tooling findings outrank the CVE list.* 1.6.0 was published ten days after the advisories
  it carried, because `release.sh` does not look at the audit. That is entry X7, ranked second.
- *The triage groups four entries into one problem*: an app is a clone, so it is born with
  Oliva's name, log, roadmap and demo, and pays in conflicts on every sync. That is proposed as
  the next epic and as the first slice of roadmap item 3, ahead of the queue-slot epic.
- *Not pushed.* The log names an app that has no public repository. Whether it goes to `main` as
  is, or with that app anonymised, is the maintainer's call.
- Not covered by run 1: a cold build, a production `up`, the frontend dev loop, staging, two apps
  up at once.

## [friction log · batch A] five small fixes out of the triage (for 1.6.2)
**Hash:** `05a36e0` (last of four on the branch)
**Branch:** `fix/friction-batch-a`
**Date:** 2026-11-14

### Changes
| File | Type | Description |
|---|---|---|
| `oliva` | modified | `doctor` asks for the CI of the repo `origin` points at (`gh -R`), and warns when there is no `origin`. |
| `backend/phpunit.dist.xml` | modified | `KERNEL_CLASS`. |
| `scripts/lib/test-db.sh` | new | Creates and migrates the test database when a test boots the kernel; exits otherwise. |
| `scripts/oliva/verify.sh`, `.github/workflows/ci.yml` | modified | Call `test-db.sh` before PHPUnit. |
| `backend/tests/Controller/HealthControllerTest.php` | new | Example web test; Oliva's first test. |
| `scripts/oliva/deps.sh` | modified | `audit` closes with a summary table and records ids in `.oliva/audit-findings`. |
| `scripts/oliva/release.sh` | modified | Audit gate before writing the version. |
| `README.md`, `docs/oliva/UPGRADING.md`, `docs/oliva/actualizaciones.md`, `docs/friction-log.md` | modified | First-feature section, notes for 1.6.2, statuses. |

### Why
- *`KERNEL_CLASS` in `phpunit.dist.xml`, not in a `.env.test`.* The Symfony recipe uses
  `.env.test`, but `backend/.dockerignore` excludes it and the Dockerfile copies files one by
  one, so it would never reach the container. One line in a file that is already copied.
- *`test-db.sh` looks for a test that boots the kernel before doing anything.* An app with unit
  tests only pays nothing. The check is a grep for the base class names, so a test that boots the
  kernel through a custom base class is not seen: it fails loudly on the missing database.
- *The release gate asks for a recent full audit, not a clean one.* Four of five base images
  carry findings with no release to move to; a clean requirement would block every release.
  `composer audit` does block, because it always has a way out (`deps update`, or an advisory
  accepted in `config.audit.ignore`). No switch turns the gate off.
- *X3 (clone a tag) was left out.* `git clone --branch vX` leaves a detached `HEAD`, which is
  worse for a newcomer than being three commits past a tag. It moved to the app-birth epic.
- *T5 and T7 are documented, not fixed.* Baked files and root-owned files now have two lines in
  the README; the fixes need decisions (which mounts, which user) and stay open in the log.
- Checked: `verify` green with the new test; the gate in a scratch clone (audit never run, ten
  days old, the 1.6.0 lock, clean); `doctor` with four kinds of `origin`; the summary with 14
  advisories reported as new. **Not checked:** the CI change on GitHub, since nothing was pushed
  (only `actionlint` and the same script run locally).

## [app birth · phases 1–2] prototype on copies of the apps; the split into product and project
**Hash:** `f27893c`
**Branch:** `feat/app-birth`
**Date:** 2026-11-14

### Changes
| File | Type | Description |
|---|---|---|
| `docs/roadmap/epics/E-app-birth.md`, `E-app-birth-runbook.md` | new | Design, the five decisions, phase 1 results, and how to finish. |
| `AGENTS.md` → `docs/oliva/agent-guide.md` | moved | The framework guide becomes product. The "keeping Oliva alive" bullet left it. |
| `AGENTS.md` | new | Oliva's own: the three kinds of file, maintenance, where direction lives. Imports the guide. |
| `docs/concepts.md`, `docs/qa-y-staging.md`, `docs/sanity-checks.md` → `docs/oliva/` | moved | Product docs. |
| `scripts/oliva/project-paths.txt` | new | What never travels to an app. |
| `scripts/oliva/owned-paths.txt` | modified | `agent-commands.md` owned; identity paths described. |
| `README.md`, `scripts/deploy.sh` | modified | References. |

### Why
- *A `release` branch instead of cleaning up after each merge.* Simulated first on toy repos,
  then on scratch copies of the three apps: from `main`, identity files conflict on every sync;
  from `release`, once for an existing app and never for a new one.
- *The prototype corrected the design.* On the real files git detects the move of `AGENTS.md` as
  a rename and carries the app's own file into `docs/oliva/`. On git 2.43 neither
  `-X no-renames` nor `merge.renames=false` changed that. So `sync.sh` will restore identity
  paths from the pre-merge commit and take `docs/oliva/` from Oliva, whatever the merge did.
  With that rule the second sync was clean in all three copies.
- *The split depends on a nested import* (`CLAUDE.md` → `AGENTS.md` → the guide). Checked with
  a real session and tools disabled, in a scratch directory and then in this repository. Only
  Claude Code was checked; another agent gets a plain first line.
- Not done yet: the cut in `release.sh`, the rule in `sync.sh`, `./oliva init`, the demo,
  `UPGRADING.md` for 1.7.0. The runbook has each step.

## [app birth · phases 3–5] the cut, the identity rule, `./oliva init`, notes for 1.7.0
**Hash:** `36deb24` (last of the series; not released)
**Branch:** `feat/app-birth`
**Date:** 2026-11-15

### Changes
| File | Type | Description |
|---|---|---|
| `scripts/oliva/release.sh` | modified | Cuts `release` (main minus `project-paths.txt`), fails closed, tags on `release`. |
| `scripts/oliva/sync.sh` | modified | Follows `release` (falls back to `main`); identity rule after every merge; warns when not initialized. |
| `scripts/oliva/lib.sh` | modified | `OLIVA_BRANCH`, `project_paths`, `identity_paths`, `is_app`. |
| `scripts/oliva/init.sh`, `scripts/oliva/templates/` | new | Birth and `--adopt`; identity templates and a starter frontend. |
| `oliva` | modified | `init`; "app" line in `doctor`. |
| `scripts/oliva/verify.sh` | modified | Step `app`. |
| `backend/src/Controller/LiveController.php` | new | The demo's endpoint, at `/api/live`, through `HubInterface`. |
| `backend/public/live.php` | deleted | It signed with a key that no longer exists. |
| `frontend/Caddyfile`, `frontend/vite.config.js`, `frontend/src/js/live.js` | modified | `/live.php` route gone. |
| `README.md`, `docs/oliva/UPGRADING.md`, `docs/oliva/actualizaciones.md`, `docs/oliva/agent-guide.md`, `docs/roadmap.md`, `docs/friction-log.md`, both epic docs | modified | 1.7.0 notes, the three kinds of file, run 3, outcome, what is left. |

### Why
- *The cut fails closed with one comparison*: the staged difference against `main` must be
  exactly the project paths. A `release` sabotaged by hand made it refuse, with `main`, the
  version file and the tags untouched.
- *The identity rule runs after every merge, not only on conflicts.* git resolves the move of
  the guide as a rename without conflict in an app that never edited its `AGENTS.md`; a rule
  tied to conflicts would miss exactly that case.
- *`sync.sh` warns instead of running `init --adopt`.* `init` needs a clean tree and a merge
  in progress is not one; and with the rule in place nothing is lost by waiting.
- *`--adopt` sets aside a file still titled "Oliva"* instead of replacing it: one real app has
  its own notes appended to Oliva's `AGENTS.md`, and the two cases look the same from outside.
- *The demo moved under `/api` to get out of the product files, and that fixed it.* It had
  answered `{"ok":true}` and delivered nothing since 1.6.0 (checked before and after).
- *The `app` step of `verify` exists so the adoption note has a guard*: `release.sh` rejects
  a guard that does not exist.
- Checked: clean-room run 3 (birth, first feature, `verify` green, two syncs with zero
  conflicts); `--adopt` on scratch copies of the three apps; the `app` step in three states.
  **Not checked:** the first real cut and push, CI on GitHub, the real crossing of an app, and
  any agent other than Claude Code.

## [friction-log C] dev ergonomics: host ports, host-user containers, baked files (T4/T7/T5)
**Hash:** `edfbc05cb46ae9e6b21593af7874e2d4095c67dc`
**Branch:** `feat/dev-ergonomics`
**Date:** 2026-11-17

### Changes
| File | Type | Description |
|---|---|---|
| `docker-compose.override.yml` | modified | T4: the 5 published dev ports come from `${*_PORT:-default}`. T7: `user: ${HOST_UID:-1000}:${HOST_GID:-1000}` on backend/scheduler/worker; `./backend/var` bind-mounted; `XDG_DATA_HOME`/`XDG_CONFIG_HOME` → `/app/var`. T5: `phpunit.dist.xml` mounted `:ro`. |
| `backend/frankenphp/docker-entrypoint.sh` | modified | T7: `setfacl` uses `$(id -u)` instead of `$(whoami)` — a host uid has no `/etc/passwd` entry and `whoami` failed under `set -e`. |
| `backend/Dockerfile` | modified | T5: the `frankenphp_dev` stage bakes `build-inputs.sha256` (hashes of composer.json/lock, symfony.lock, php-extensions.txt) for `doctor` to compare. At the stage tail so the xdebug layer stays cached. |
| `backend/.gitignore` | modified | T7: `var/` → `var/*` + `!var/.gitkeep` so the dir is tracked and exists host-owned. |
| `backend/var/.gitkeep` | new | T7: makes `./backend/var` exist before the bind-mount (else Docker creates it root-owned). |
| `oliva` | modified | T5/T7: `doctor` steps "imagen vs fuente" (baked-input drift → rebuild) and "usuario del backend (dev)" (container uid vs host uid). |
| `.env.example` | modified | Documented blocks "Dev host ports" (T4) and "Dev container user" (T7), commented with the defaults. |
| `docs/oliva/agent-guide.md` | modified | Dev section: two apps at once (T4), host-user in dev (T7), baked-vs-mounted files (T5). |

### Why
- *Group C of the friction-log triage; each friction was decided with Marcos.* They ship
  together because T4/T7/T5 are intertwined in the same three shared files (the override,
  `.env.example`, the guide); splitting them into separate commits would need fragile
  hunk-level staging for no real gain. The friction log keeps the three rows open.
- *T4 — ports from variables, defaults unchanged.* Inline `:-` defaults mean a single app
  behaves exactly as before; a second app sets the ports in its own `.env`. prod.yml's
  standalone `80:80` was left alone: it is not the measured friction (dev) and shared-infra
  already overrides it.
- *T7 — run as the host user, not chown-after.* The real pain is bind-mounted writes (JWT,
  generated migrations, var) owned by root, so the app dir cannot be deleted. Three decisions
  the mechanism forced: `var` is **bind-mounted** (not the anonymous VOLUME, which is born
  root-owned and cannot be chowned past Docker's "writes after VOLUME are discarded" rule);
  the entrypoint uses the **numeric uid** (a host uid has no passwd entry → `whoami` broke the
  boot); Caddy/Mercure storage is redirected to `/app/var` via **XDG_*_HOME** (its `/data` and
  `/config` VOLUMEs are root-owned and the hub died on `permission denied` for mercure.db).
  Default uid is 1000 (the usual Linux first user, and Marcos's); other hosts set HOST_UID in
  `.env` and `doctor` flags the mismatch. prod is untouched (no `user:`; root runs the setfacl
  that shares var with www-data). The frontend stays root for now — its `node_modules` is an
  anonymous volume, off the host, so its T7 cost is near zero.
- *T5 — split by file class, because the two options were never alternatives.* A file that is
  only read at runtime (`phpunit.dist.xml`) is **mounted**, so an edit takes effect without a
  rebuild — this kills the exact reported case. A build input (composer.*, symfony.lock,
  php-extensions.txt) must NOT be mounted: changing it needs `composer install` / a recompile,
  and a live mount would make the manifest disagree with the baked `vendor/` silently — worse
  than today. So the image bakes their hashes and `doctor` compares and says "rebuild".
- Proven on a real build + `up`: backend healthy as uid 1000, JWT and `var/` host-owned,
  `/health` ok, `doctor`'s two new steps green, drift correctly flagged when php-extensions.txt
  changed, stack torn down leaving no new root-owned files. **Not checked:** a non-1000 host,
  the frontend as host user, and the real crossing of a fork.

## [queue slot · phase 1] a production worker, healthchecks of their own, WORKER_CONSUME_ARGS
**Hash:** `f9010e44c0e5e774ac88cbeedd23a061c68e003f`
**Branch:** `feat/queue-slot`
**Date:** 2026-11-17

### Changes
| File | Type | Description |
|---|---|---|
| `docker-compose.yml` | modified | New `worker` service (profile `queues`, command `oliva-consume`, `depends_on` backend and rabbitmq healthy, healthcheck). `scheduler` gets a healthcheck of its own. |
| `docker-compose.prod.yml` | modified | `worker`: `:prod` image, `APP_ENV=prod`. Everything else comes from the base. |
| `docker-compose.override.yml` | modified | The dev `worker` keeps only what is dev (image, host user, mounts, `SHELL_VERBOSITY=2` for `-vv`); the duplicated `scheduler` healthcheck goes. |
| `backend/frankenphp/consume-messages.sh` | new | `oliva-consume`: `WORKER_CONSUME_ARGS` if set; otherwise `--all`, excluding the failure transport whose name it asks Symfony for, recycled at 3600 s / 128M. |
| `backend/Dockerfile` | modified | Installs `oliva-consume` next to the entrypoint. |
| `backend/frankenphp/docker-entrypoint.sh` | modified | A `messenger:consume` command never runs the setup block (JWT, wait-for-db, `migrate`, ACLs). |
| `.env.backend` | modified | `WORKER_CONSUME_ARGS=` (empty = the default), documented. |

### Why
- *The worker lives in the base file, like `scheduler`,* so prod, staging and shared infra
  only adjust it. Before, it existed only in dev and an app had no way to a production one:
  the README told it to edit `docker-compose.prod.yml`, a file Oliva owns.
- *A healthcheck of their own for `worker` and `scheduler`.* The image bakes an HTTP check
  (`curl :2019/metrics`) that fails for any container without FrankenPHP: measured exit 7.
  The prod scheduler was `unhealthy` with nothing saying so (the deploy does not `--wait`).
- *`depends_on: backend (healthy)` replaces the setup in the worker.* The backend is healthy
  only after its entrypoint has migrated, so the worker starts on a migrated schema; the dev
  worker used to run `migrate` at the same time as the backend (seen in its log).
- *A script for the command, not the variable in `command:`.* Compose interpolates `command:`
  from the project's `.env` only, and `WORKER_CONSUME_ARGS` is an app decision that belongs in
  the tracked `.env.backend`; `sh -c` in compose would make `$1 = sh`, the trap the Dockerfile
  warns about.
- *The failure transport is asked, not assumed* (found while testing, not in the design):
  Symfony silently ignores an `--exclude-receivers` that names no transport, so a fixed
  `failed` would stop excluding anything in an app that renamed it, and a poison message would
  loop forever. Checked with the real config, with it pointed at another transport, and with
  none.
- Proven: dev stack with `queues` (worker healthy, no setup in its log, starts after the
  backend, PID 1 is the consumer, `WORKER_CONSUME_ARGS` honoured); production stack on a scratch
  copy with `queues` and `cron`: every service healthy, and a round trip with
  `RunCommandMessage` (worker stopped → one message waiting in `ingest` → worker started →
  queue at 0 and the mark written inside the worker). **Not checked yet:** staging and shared
  infra (phase 2).

## [queue slot · phase 2] the worker in staging and shared infra; a vhost per app and environment
**Hash:** `0954669a0d52c54a8ad16827c8c809fa25301fe7`
**Branch:** `feat/queue-slot`
**Date:** 2026-11-17

### Changes
| File | Type | Description |
|---|---|---|
| `docker-compose.shared-infra.yml` | modified | `worker`: `depends_on` reduced to the backend (the broker is external), networks `app_network` + `data_net`. |
| `docker-compose.staging.yml` | modified | `worker`: `:staging` image, explicit `APP_ENV=staging`, the staging `env_file` (loads last). |
| `.env.staging.example` | modified | Asks for a staging `RABBITMQ_DSN` on a vhost of its own when the app uses queues. |
| `docs/oliva/agent-guide.md` | modified | Shared-infra and staging runbooks: `provision-rabbitmq.sh` for production and for staging, and why. |
| `docs/roadmap/epics/E-queue-slot.md` | modified | The isolation finding, its decision, and phase 3's gate extended to it. |

### Why
- *Without the shared-infra override the project is rejected*: with phase 1 alone,
  `--profile queues` on shared infra failed with `worker depends on undefined service
  "rabbitmq"` (measured). The backend stays as the dependency: it is what guarantees a
  migrated schema.
- *The isolation work was not in the plan; the gate found it.* Run with the real
  `deploy.sh` and `deploy-staging.sh` on a local shared-infra setup (external networks, a
  shared Postgres and RabbitMQ under the infra's hostnames): with production's worker
  stopped, a production message was consumed by the **staging** worker, against the staging
  database. The template separated the database and inherited the broker. Every app also
  inherits the same queue names, so two apps on `/` would do the same to each other. Latent
  until now (no production worker existed); this epic would have made it live.
- *Fixed where it is decided, then guarded*: the template and the runbook ask for a vhost
  per app and environment, using the infra's existing `provision-rabbitmq.sh`; the guards
  that abort the deploys come in phase 3 (decided with the maintainer).
- Proven: shared infra through `deploy.sh` (worker healthy on `data_net`, no setup, round trip
  through the shared broker); staging through `deploy-staging.sh` (worker on the `:staging`
  image); cross-consumption reproduced, then gone once staging had its own vhost (production's
  message stayed queued until production's worker drained it).

## [queue slot · phase 3] the queue guards: abort before `down`, red in verify, shown in doctor
**Hash:** `1bb3c83c66d15c13d5a06890cd6119196d6b6d27`
**Branch:** `feat/queue-slot`
**Date:** 2026-11-17

### Changes
| File | Type | Description |
|---|---|---|
| `scripts/lib/queue-guard.sh` | new | `queue_guard` (async routes and no worker; a worker on `/` of an external broker) and `queue_guard_staging` (staging on production's broker and vhost). Static: messenger.yaml, `#[AsMessage]`, and the resolved environment. |
| `scripts/deploy.sh` | modified | `queue check` after the env check, before `down`: aborts with the old stack serving. |
| `scripts/deploy-staging.sh` | modified | The same, plus the comparison with production's resolved configuration. |
| `scripts/oliva/verify.sh` | modified | Step `queue` (static, before `up`): red. |
| `oliva` | modified | `doctor` step "colas": informs, and announces a declared external consumer. |
| `.env.example` | modified | `OLIVA_QUEUE_CONSUMER=external`, commented, with when to use it. |

### Why
- *Abort, not warn* (decided with the maintainer): neither failure shows at boot, a warning
  protects only whoever reads it, and processing a backlog later does not undo a late effect.
  Aborting before `down` costs nothing: the running stack keeps serving and the fix is one
  line of `.env`.
- *Static, so it can run before `down`*: the new image does not exist yet at that point. The
  guard reads messenger.yaml and the attributes, and resolves each `%env(NAME)%` against what
  Compose resolves for the backend, the reader `env-check.sh` already had.
- *Only asynchronous routes are evidence*: a route to `sync://` or `in-memory://` needs no
  worker, so it must not stop a deploy. The vhost check looks at every AMQP transport, not only
  the routed ones, because `--all` consumes them all.
- *The declared exception is a replaced slot*: it passes and is announced on every run, the
  roadmap's rule for replacements.
- *Not registered in `UPGRADE_GUARDS`*: those run after `up` and only warn. The verify step
  named `queue` makes `guard: queue` a valid label for `UPGRADING.md`.
- Proven, on a local shared-infra setup through the real deploy scripts: worker on `/` →
  aborted, stack untouched; a vhost of its own → deployed; staging inheriting production's
  vhost → aborted, staging untouched; staging on its own vhost → deployed; async routes with the
  profile off → aborted, the old worker kept consuming; the same with the declaration → deployed
  and announced; `verify` red (exit 1) and green on the same states; sync-only routes and no
  routes → silent. The parser was unit-tested on inline and nested transports, scalar, inline
  and block-list routes, comments, a `when@prod` block, and single- and multi-line attributes.

## [queue slot · phase 4] CI, docs, the 1.8.0 notes, and the upgrade hazard of T7
**Hash:** `ec8380a073da8c876cca6c6c3129d46d746a19b1`
**Branch:** `feat/queue-slot`
**Date:** 2026-11-17

### Changes
| File | Type | Description |
|---|---|---|
| `.github/workflows/ci.yml` | modified | `prod-config`: with `--profile queues`, the prod worker resolves (`APP_ENV=prod`, `oliva-consume`) and `worker`/`scheduler` have a healthcheck that is not the image's; shared infra resolves with `queues` and no local `rabbitmq`. |
| `oliva` | modified | `doctor` step "archivos de root (dev)": root-owned files in the backend's bind-mounts, with the `chown` fix. |
| `docs/oliva/UPGRADING.md` | modified | `## 1.8.0`: group C (dev ergonomics) and the queue slot, six labelled actions. |
| `docs/oliva/agent-guide.md` | modified | "The queue worker" replaces the known-debt section; services table. |
| `README.md`, `docs/oliva/qa-y-staging.md`, `docs/roadmap.md` | modified | The gap is gone; profile table; verify step `queue`; slots table. |
| `docs/friction-log.md` | modified | X10 (no production worker), X11 (unhealthy scheduler), X12 (cross-vhost consumption), all fixed; group D note. |
| `docs/roadmap/epics/E-queue-slot.md` | modified | Status: implemented, release pending. |

### Why
- *The CI checks are structural, no build*: they guard the two regressions this epic can have
  without a running stack (the prod worker or a healthcheck disappearing from a compose file,
  and shared infra being rejected again). Run locally as CI runs them, plus a negative case
  (the scheduler's healthcheck removed → the step fails).
- *T7 had an upgrade hazard, found while writing these notes, not when T7 was built*: an app
  whose dev backend ran as root has `config/jwt/private.pem` owned by root with mode 600; the
  backend, now the host user, cannot read it, and only logins fail. Nothing has synced since,
  and nothing is released, so it ships with a labelled `[local]` action and a `doctor` step that
  works with the stack down. Checked on this repository's own leftovers: one root file found,
  the printed fix applied, zero after.
- *UPGRADING actions follow the preference order*: what can be checked carries a guard
  (`queue`); the rest is labelled so `doctor` and the deploys show it until acknowledged.
  `lint_upgrade_actions 1.8.0` passes, and the pending view shows the `[local]` and `[host]`
  items and not the guarded one.
- **Not done here:** the release itself (`release.sh 1.8.0`) and the push, which are the
  maintainer's call; the real crossing of an app.

## [unbundle roles · phase 1] the gateway as its own container
**Hashes:** `3c53b69…` (gateway + compose), `4687662…` (trusted proxies + env-check + verify + docs)
**Branch:** `feat/unbundle-roles`
**Date:** 2026-11-19

### Changes
| File | Type | Description |
|---|---|---|
| `gateway/Dockerfile`, `gateway/Caddyfile`, `gateway/app.d/example.caddy` | new | The edge Caddy. Baked `ENV GATEWAY_CSP_STYLE_EXTRA=` (dev overlay sets it to `'unsafe-inline'`); Dockerfile `HEALTHCHECK` hits `/gateway-health` (local, never proxied). `app.d/*.caddy` is the app's. Pinned to `caddy:2.11.9` (same tag as `frontend/Dockerfile`, so `deps.sh` reports one caddy). |
| `frontend/Caddyfile`, `frontend/vite.config.js` | modified | Frontend becomes a plain `file_server`: no CSP, routing, `encode`, `trusted_proxies` or logging. Vite drops the `proxy` block, `VITE_API_URL` and `hmr.clientPort`. |
| `backend/Dockerfile` | modified | `frankenphp_base`: `ENV SYMFONY_TRUSTED_PROXIES=PRIVATE_SUBNETS`. `SYMFONY_TRUSTED_HEADERS` stays unset. |
| `docker-compose.yml`, `docker-compose.override.yml`, `docker-compose.prod.yml`, `docker-compose.staging.yml`, `docker-compose.shared-infra.yml` | modified | `gateway` service in all overlays with its own `:dev/:staging/:prod` tags; `backend/frontend` lose their host ports in dev (GATEWAY_PORT publishes 80 through the gateway); prod moves `80:80` and the caddy_data/config volumes to the gateway; shared-infra puts the gateway on `proxy_net` with aliases `<app>-gateway` (new) and `<app>-frontend` (transitional). The dead `backend.${SERVER_NAME}` alias gone. |
| `scripts/lib/env-check.sh` | modified | Reads the gateway's resolved env; extends the leaked-secret check; reports a slot REPLACED when a `GATEWAY_*_UPSTREAM` host is not Oliva's default; errors on an empty `SYMFONY_TRUSTED_HEADERS`. |
| `scripts/lib/upgrade-guards.sh` | modified | New `dev-ports` guard. |
| `scripts/oliva/verify.sh` | modified | New `gateway` step: `/gateway-health`, `/health` JSON, `/` HTML and CSP present through the gateway. `do_prod_build` builds `backend frontend gateway`. |
| `scripts/oliva/deps.sh` | modified | `base_images()` reads `gateway/Dockerfile`. |
| `scripts/deploy.sh` | modified | On a failed `up`, prints backend and gateway logs. |
| `scripts/oliva/owned-paths.txt` | modified | `gateway/Dockerfile` and `gateway/Caddyfile` only — `gateway/app.d/` stays the app's. |
| `scripts/oliva/env.manifest` | modified | No new rows: `GATEWAY_*_UPSTREAM` have Caddyfile defaults, `SYMFONY_TRUSTED_PROXIES` is in the backend image. `env-check` reads them directly and reports REPLACED where it matters. |
| `.github/workflows/ci.yml` | modified | Bake target `gateway`; `/health` asserts `application/json`. |
| `scripts/oliva/templates/README.md.tpl`, `README.md`, `docs/roadmap.md`, `docs/oliva/agent-guide.md` | modified | One URL (the gateway) in dev; tree; slots table row; shared-infra topology; agent-guide runbook step. |
| `docs/oliva/UPGRADING.md` | modified | Section `## 1.9.0 — unreleased` with labelled actions (`[merge]`, `[local, guard: dev-ports]`, `[decision]`, `[host]`). |
| `.env.example` | modified | `GATEWAY_PORT` replaces `BACKEND_PORT`/`FRONTEND_PORT`; `GATEWAY_*_UPSTREAM` and `SYMFONY_TRUSTED_PROXIES` as commented placeholders. |

### Baseline (step 1 of the runbook, on `9160c24` before this branch's code changes)

| Measurement | Value |
|---|---|
| `docker compose up -d --wait` | 18.6s |
| `./oliva verify` | 13.3s, every step PASS (`ci-build` SKIP by design — `php-extensions.txt` empty) |
| `curl :3000/health` | **`200 text/html`** (the regression this phase fixes) |
| prod services, no profile | `backend database frontend` |
| prod services, `--profile '*'` | `backend database frontend rabbitmq scheduler worker` |

### Gate (step 11, dev — ran and read)

1. `up -d --wait`: all four services healthy.
2. `curl -sI localhost/` → `200`, `text/html`, `Content-Security-Policy` with `'unsafe-inline'` in `style-src` (dev variant) and nothing else that prod does not also carry.
3. `curl -s localhost/health` → `{"status":"ok"} application/json`. **The regression of step 1 is gone.**
7. `docker compose stop backend` → `curl localhost/api/x` = **502**, gateway still `healthy`. Then `start backend` returns to normal.
8. `gateway/app.d/test.caddy` with `handle /x { respond "x" 200 }` → `/x` answers `x 200` after `docker compose restart gateway`, deleted at the end.
9. `GATEWAY_PORT=8080 docker compose up -d --force-recreate gateway` → `/gateway-health` on `:8080` = 200 (nothing on `:80`); after bringing it back, `:80` = 200. `BACKEND_PORT=81` added to `.env` → the `dev-ports` guard prints the labelled warning and returns 1; removed.
10. `./oliva env check` prints no new errors (gateway slot has no secrets to flag; a public `POSTGRES_PASSWORD` warning is expected on this checkout's volume).
11. Linters: `caddy validate` on both gateway and frontend Caddyfiles → `Valid configuration`; `hadolint` on `gateway/Dockerfile` → no findings; `shellcheck -S warning` on the four scripts touched → clean; `actionlint` on the workflows → clean.

### Gate (step 12, prod — the parts that need no scratch clone)

- `config --services` with `prod.yml`: `backend database frontend gateway`; with `--profile '*'` adds `rabbitmq scheduler worker`. Staging (`-p oliva-staging` + `staging.yml`): same list.
- **SSE through the gateway, measured (R3 of the runbook):** subscribe through `localhost/.well-known/mercure?topic=t`, publish from the backend immediately → delivered. Idle the subscription 90 seconds, publish again → delivered, same topic. The `encode` exclusion on `/.well-known/mercure*` holds.

### What was not run

- Step 11.4 (the scratch app born with `./oliva init` from a fake `9.9.x` release) and 11.5 (HMR in a browser): both need a release dry-run clone and a real browser. They are what proves R2 (the CSP covering the HMR websocket) and the "unreachable" → "ok" of `main.js.tpl`. Deferred.
- Step 11.6 (two-browser Mercure demo).
- Step 12.1 (building the prod stack on a scratch clone and asserting production CSP without `'unsafe-inline'`).
- Step 13 (shared infra simulation and `$request->getClientIp()` behind the edge). The code path is small (one env var in the backend image and a `trusted_proxies` directive in the gateway) but the simulation stands up `proxy_net`, `data_net`, Postgres and an edge Caddy and deserves a session.
- The release itself (`release.sh 1.9.0`).

Phase 2 (realtime hub, target 1.10.0) starts at the runbook's step 1 and must decide on compat vs. modern Mercure tokens before touching code (R1). It is marked for a more capable model.

## [unbundle roles · phase 2] the realtime hub as its own service
**Hash:** `833274c…` (code), plus this docs commit
**Branch:** `feat/realtime-hub`
**Date:** 2026-11-19

### Changes
| File | Type | Description |
|---|---|---|
| `realtime/Dockerfile`, `realtime/Caddyfile`, `realtime/docker-entrypoint.sh` | new | The hub: `dunglas/mercure:v1.1.6` + Oliva's Caddyfile (compat mode 8, bolt cap `REALTIME_HISTORY_SIZE`, admin on localhost) + an entrypoint refusing an empty/placeholder/public key in every environment. The known-public list comes via a named build context. |
| `backend/frankenphp/realtime-relay.sh` | new | `oliva-relay`: `setup-transports` then `messenger:consume realtime --sleep=0.01` (with `get_notify_timeout: 5000`, both needed for ~9ms). |
| `backend/Dockerfile` | modified | Installs `oliva-relay`. |
| `backend/frankenphp/docker-entrypoint.sh` | modified | Drops the embedded-hub empty-key check and `MERCURE_PUBLISHER_JWT_KEY` from the prod secret list (the hub owns both); backend keeps `MERCURE_JWT_SECRET` (it signs). |
| `backend/frankenphp/Caddyfile` | modified | The `mercure` block and its `@phpRoute` exclusion are gone. |
| `backend/frankenphp/consume-messages.sh` | modified | The `queues` worker excludes `realtime`/`realtime_failed` unconditionally. |
| `backend/config/packages/messenger.yaml` | modified | `realtime` + `realtime_failed` Doctrine transports, `Update` routed to `realtime`, retries over minutes, `get_notify_timeout`; in-memory in tests. |
| `backend/config/packages/doctrine.yaml` | modified | `schema_filter` hides `messenger_messages`. |
| `backend/composer.json`/`.lock` | modified | `symfony/doctrine-messenger` (only new package). |
| `backend/src/Controller/LiveController.php` | modified | Dispatches the Update on the bus (the recommended path). |
| `docker-compose.yml` + 4 overlays | modified | `realtime` + `realtime-relay` behind profile `realtime`; the hub gets only its key via `environment:`; the relay mirrors the worker (dev user/mounts, shared-infra `data_net`); gateway default realtime upstream → `realtime:80`. |
| `scripts/lib/queue-guard.sh` | modified | `realtime_guard` (app uses Mercure, no hub → abort); the async check skips realtime transports. |
| `scripts/lib/env-check.sh` | modified | Reads the hub, flags a secret leaked to it, errors on `MERCURE_URL` pointing at the backend. |
| `scripts/oliva/verify.sh` | modified | `do_queue` runs `realtime_guard`; `mercure` step goes through the gateway, skipped when the profile is off. |
| `scripts/deploy.sh`, `scripts/deploy-staging.sh` | modified | Run `realtime_guard` before `down`. |
| `scripts/oliva/init.sh` | modified | `--demo` enables the `realtime` profile. |
| `scripts/oliva/deps.sh`, `scripts/oliva/owned-paths.txt` | modified | Track the hub base image; own `realtime/*`. |
| `.github/workflows/ci.yml` | modified | Bakes `realtime`, runs with the profile, checks the prod relay; hadolint over a matrix of the clean Dockerfiles. |
| `.env.backend`, `.env.example` | modified | `MERCURE_URL` → `http://realtime/…`; `REALTIME_HISTORY_SIZE`. |
| `README.md`, `docs/oliva/agent-guide.md`, `docs/roadmap.md`, `docs/oliva/UPGRADING.md` | modified | Topology, "The realtime hub", slots row, `## 1.10.0`. |

### Why
- *Publishing through a Doctrine-transport relay, not inline, is the whole point of the unbundling*: the request stops depending on the hub (no 500 when the hub restarts), an outage delays instead of loses, and dispatch-in-transaction is an outbox for free. Doctrine not RabbitMQ so realtime never drags in `queues`; a dedicated `realtime-relay`, not the worker, so the queue slot of 1.8.0 is untouched.
- *Optional, like everything in Oliva* (the maintainer's correction): a `realtime` profile, a guard for an app that uses Mercure without it, and nothing paid by an app that does not. Supersedes the plan's "always on in 1.10.0".
- *The hub holds only its key*: `environment:` not `env_file`, so no backend/database secret reaches it (env-check enforces it). Compat mode kept (R1 measured), with modern mode a watch item tied to the `deprecated_*` build tags.
- **Not done here:** the release (`release.sh 1.10.0`) and the push — the maintainer's call; the real crossing of an app; a fork actually exercising the relay under load.

## [backend slot · phase A] the default honours its own contract (1.11.0)
**Hash:** `f8e6024`, `776926d`, `3af800d`, `7df4666`, `f0e93f7`, `40137be`, `388cc0b`, plus this commit
**Branch:** `feat/backend-slot`
**Date:** 2026-11-20

### Changes
| File | Type | Description |
|---|---|---|
| `backend/Dockerfile` | modified | `pcntl`; installs `oliva-migrate` and `worker.dev.Caddyfile`; healthcheck `GET /health` (was Caddy's admin `:2019/metrics`); dev stage `FRANKENPHP_CONFIG="import worker.dev.Caddyfile"`. |
| `backend/frankenphp/migrate.sh` | new | `oliva-migrate`: wait-for-db (70 s), then `migrate --all-or-nothing`, moved out of the entrypoint unchanged in behaviour. |
| `backend/frankenphp/docker-entrypoint.sh` | modified | No longer waits for the database, migrates or generates JWT keys; keeps the production secret refusal and the `var/` ACLs. |
| `backend/frankenphp/worker.dev.Caddyfile` | new | Dev worker block with `watch` on `src/`, `config/`, `.env`, `public/index.php` (never the default patterns: they cover `var/cache`). |
| `docker-compose.yml` | modified | One-shot `migrate` service (healthcheck disabled); backend, scheduler, worker and relay depend on it; `WORKER_STOP_GRACE_PERIOD`. |
| `docker-compose.override.yml`, `docker-compose.prod.yml`, `docker-compose.staging.yml`, `docker-compose.shared-infra.yml` | modified | `migrate` per environment (staging on `.env.staging`; shared infra on `data_net`, every `depends_on: !override` re-declares it); `./secrets/jwt` read-only into every PHP service; the dev worker file mounted. |
| `scripts/oliva/env.sh` | modified | `env init` generates the JWT pair in `secrets/jwt`, moves a pre-1.11.0 dev pair, gives back a root-owned directory. |
| `scripts/lib/env-check.sh` | modified | Errors on a missing pair, on a pair still in the old place, and on a key the backend's user cannot read; warns on a leftover old pair. |
| `scripts/lib/backend-guard.sh` | new | `backend_health_guard` (no `/health` route → abort before `down`); `dev_cache_stale_check` (nanosecond detector of Symfony's whole-second freshness blind spot). |
| `scripts/deploy.sh`, `scripts/deploy-staging.sh` | modified | Health guard before `down`; `up --wait` bounded by `OLIVA_DEPLOY_WAIT_TIMEOUT`; logs of migrate/backend/gateway on failure; staging no longer migrates by hand. |
| `scripts/oliva/verify.sh` | modified | Steps `backend` (static, the route), `worker-mode` (dev runs workers), `dev-cache`. |
| `oliva` | modified | `doctor`: last `migrate` run, and the Symfony cache line. |
| `.github/workflows/ci.yml` | modified | `migrations:up-to-date` instead of migrating again. |
| `.env.example` | modified | `WORKER_STOP_GRACE_PERIOD`. |
| `docs/oliva/UPGRADING.md`, `docs/oliva/agent-guide.md`, `docs/oliva/concepts.md`, `docs/oliva/qa-y-staging.md`, `README.md`, `scripts/oliva/templates/README.md.tpl`, `docs/roadmap.md`, `docs/friction-log.md` | modified | `## 1.11.0` with labelled, guarded actions; the migrate service, dev worker mode and provisioned keys everywhere the old behaviour was described; X16 progress, X17–X19. |
| `docs/roadmap/epics/E-backend-slot.md`, `E-backend-slot-runbook.md` | new | Analysis, decisions Q1–Q5, every measurement (B1–B6, S1–S43, G1–G4). |

### Why
- *A failed migration deployed as OK* (measured, rc 0 with a restart loop) because the database lifecycle was a side effect of the server starting. As a one-shot service it fails the `up` itself, even a plain `up -d`, and the backend never starts on a broken schema. Two concurrent runs were measured before deciding on a lock: transactional DDL plus `--all-or-nothing` already make the loser fail cleanly, so no lock.
- *The healthcheck proved Caddy, not the app*, and deploys did not wait for it: both together make "deployed" mean "healthy". The `/health` route is guarded before `down` because without it `--wait` can only fail after the stack is stopped.
- *PHP as PID 1 ignored SIGTERM*: every deploy SIGKILLed consumers mid-message. `pcntl` was checked harmless inside FrankenPHP's SAPI before keeping it.
- *JWT keys out of boot*: they came out root-owned and only the server had them. Found on a real checkout: a root-owned 0600 key the dev backend could not read while every check passed, so `env check` now looks at who can read it.
- *Dev in worker mode* (decision Q4) so isolation bugs appear where they are written. The gate stopped once on Symfony's whole-second cache freshness (≈30% of rapid edits); the maintainer chose to keep worker mode with a detector (option A). Healing it automatically is X19.
- **Not done here:** the release and the push (the maintainer's call); the long-jump sync rehearsal on the first app; a CI run.
