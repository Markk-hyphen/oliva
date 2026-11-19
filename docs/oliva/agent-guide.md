# Operating guide for apps built on Oliva

Framework base para construir webapps: backend Symfony (FrankenPHP), frontend Vite, base de datos PostgreSQL (con pgvector), tiempo real vía Mercure, colas vía RabbitMQ + Symfony Messenger, y un contenedor scheduler (cron) para tareas programadas. Todo orquestado con Docker Compose.

This file is the framework's operating guide for agents working on an app built on Oliva. It is part of the product: Oliva owns it, every sync updates it, and an app never edits it. What is specific to an app (what it is, its own rules) lives in the app's own `AGENTS.md`, whose first line imports this file.

## Versiones, actualizaciones y forks

Oliva se versiona (`OLIVA_VERSION`, tags `vX.Y.Z`) y las apps hechas con Oliva viven en **repos separados** (finanzas-ong, crypto-pulse) con un remote `oliva-upstream` que apunta acá. El sistema completo está en **`docs/oliva/actualizaciones.md`**; en corto:

- **Bajarlo a cada fork** (en el fork): `scripts/oliva/sync.sh check` en cada inicio de sesión; si está atrás → `sync.sh start` → resolver → `sync.sh locks` → commit → `sync.sh verify` → merge local a `main` → hacer lo que `./oliva doctor` lista en "acciones de upgrade" y reconocerlo con `./oliva ack` (por máquina: las `[host]` las muestra el `deploy.sh` de cada host hasta un `ack` ahí).
- **Propiedad de archivos:** `scripts/oliva/owned-paths.txt`. Un fork no edita los archivos de Oliva; si necesita otra cosa, se agrega a Oliva como opción y baja a todos.
- **Al cambiar algo que un fork tenga que acompañar** (renombre, variable nueva, paso manual), escribirlo en `docs/oliva/UPGRADING.md` en el mismo commit — es lo que `sync.sh` le muestra al fork. `release.sh` no publica sin esa sección, ni con acciones sin etiqueta `[lugar]` / `[lugar, guard: <id>]`. Antes de escribir una acción sin guard, preguntarse si se puede chequear: casi siempre es estado fuera de git (un `.env`, otro host), y un guard en `scripts/lib/upgrade-guards.sh` lo avisa en `verify`/`deploy` sin depender de que alguien lea la nota.

**Por qué importa:** antes de 1.1.0 nada avisaba que un fork había quedado atrás, y un fork con mes y medio de divergencia costó 19 conflictos (`add/add` del esqueleto Symfony, que hoy ya tiene ancestro común en todos los forks).

## Comandos principales

### Desarrollo
```bash
docker compose up
```
El `docker-compose.override.yml` se aplica automáticamente: monta el código fuente con hot-reload, expone el backend en `:80` y el frontend en `:3000`.

**Dos apps a la vez en dev:** desde 1.9.0 el único puerto HTTP que publica el stack es el del `gateway` (default `:80`); backend y frontend viven en la red privada de la app. Los puertos del host (`:80`, `:5432`, y los de RabbitMQ) salen de variables con esos defaults. Una sola app no configura nada. Para levantar una segunda app Oliva en paralelo —que si no choca con *"port is already allocated"*— poné `GATEWAY_PORT`, `DB_PORT` (y, con el profile `queues`, `RABBITMQ_PORT`/`RABBITMQ_MANAGEMENT_PORT`) con otros valores en el `.env` de esa app. `BACKEND_PORT`/`FRONTEND_PORT` en un `.env` pre-1.9.0 quedaron sin uso; el guard `dev-ports` lo avisa.

**Usuario del host en dev:** los containers del backend corren como `${HOST_UID:-1000}:${HOST_GID:-1000}`, así lo que generan (claves JWT en `config/jwt`, la migración que creás con `migrations:diff`, el cache de `var/`) queda tuyo en el host y no root-owned (antes había que `sudo chown` para borrar el dir). Si tu `id -u` no es `1000`, poné `HOST_UID`/`HOST_GID` en tu `.env`; `./oliva doctor` lo chequea y avisa si no coinciden. Prod corre como root a propósito (no define `user:`). El frontend sigue como root (su `node_modules` es un volumen anónimo, no toca el host).

**Archivos horneados que no se montan:** `phpunit.dist.xml` se bind-mountea, así que editarlo surte efecto sin rebuild. Los *inputs de build* (`composer.json`/`.lock`, `symfony.lock`, `php-extensions.txt`) NO se montan a propósito: cambiarlos pide `composer install` o recompilar extensiones, no copiar el archivo. `./oliva doctor` (paso "imagen vs fuente") compara sus hashes con la imagen y te dice "rebuildeá" si driftearon — así no corrés con una imagen vieja sin darte cuenta.

### Producción
```bash
docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d
```
Usa imágenes compiladas (`<project>-backend:prod`, `<project>-frontend:prod`; ver "Nombres de imagen" abajo). El frontend queda expuesto en `:80`.

### Build de producción
```bash
docker compose -f docker-compose.yml -f docker-compose.prod.yml build
```

## Estructura
- `backend/` — Symfony con FrankenPHP (Doctrine ORM/Migrations, pgvector, Mercure, Messenger)
- `frontend/` — Vite (Node), incluye demo de Mercure en vivo (`src/js/live.js`, sección "Live" de `index.html`)
- `docs/oliva/concepts.md` — glosario técnico del framework (pgvector, RabbitMQ, AMQP, modelo de sync, etc.). Solo lectura en una app; el glosario propio de la app es `docs/concepts.md`
- `docs/oliva/qa-y-staging.md` — qué garantías ofrece el framework (verify.sh, los jobs de CI, stack de staging, seeding) y qué NO cubre. Es el doc humano de lo que acá está desperdigado en runbooks
- `docs/oliva/` — docs **del framework** que bajan a cada fork: `actualizaciones.md` (sistema de updates) y `UPGRADING.md` (notas por versión)
- `scripts/oliva/` — herramientas de mantenimiento y sync (`deps.sh`, `sync.sh`, `verify.sh`, `release.sh`, `owned-paths.txt`)
- `OLIVA_VERSION` — versión del framework sobre la que está el checkout
- `docs/examples/` — esqueletos de referencia (`*.php.example`) no registrados como código de la app
- `.env` — this machine's real values, **secrets included**. Gitignored. Created and repaired by `./oliva env init`
- `.env.backend`, `.env.frontend` — tracked, **non-secret** defaults. `.env.backend` loads after `.env` and overrides it
- `scripts/oliva/env.manifest` (Oliva's variables) and `env.manifest` (the app's, an extension point) — what each variable is: slot, kind, how its value is made. See "Environment contract" below

## Servicios incluidos y cómo desactivarlos

Además de `database`, `backend`, `frontend` y `gateway` (el edge Caddy que ruta `/api`, `/health` y `/.well-known/mercure` al backend, y lo demás al frontend; publica el único puerto HTTP del stack), `docker-compose.yml` define:

| Servicio | Para qué | Si la app no lo necesita |
|---|---|---|
| `rabbitmq` | Broker para Symfony Messenger (colas `ingest`/`enrich` de ejemplo, comentadas) | Quitar el bloque `rabbitmq` y las dependencias `depends_on: rabbitmq` de `backend`/`scheduler`/`worker` |
| `scheduler` | Ejecuta `supercronic` con `backend/scheduler/crontab` para tareas periódicas. **Opt-in:** vive tras el profile `cron`, no arranca por defecto (mismo criterio que `rabbitmq`/`queues`). El crontab base viene vacío. | Por defecto ya no corre. Una app que necesite cron llena `backend/scheduler/crontab` y activa el profile con `COMPOSE_PROFILES=cron` en el `.env` (en prod, el `.env` **del host**: es lo que lee el `up` de `deploy.sh`). Si el crontab tiene tareas y el profile no está activo, `deploy.sh`/`deploy-staging.sh` lo avisan al final (`scripts/lib/cron-guard.sh`). Para eliminarlo del todo: quitar el bloque `scheduler` y `backend/scheduler/crontab` |
| `worker` | Consumes Messenger messages (`oliva-consume`). **Opt-in** with the `queues` profile, together with `rabbitmq`, in every environment (dev, prod, staging, shared infra) since 1.8.0. See "The queue worker" below | Nothing: it only runs with `queues`. If the app routes messages asynchronously, `verify` and the deploys require it |
| `realtime` | Standalone Mercure hub (`dunglas/mercure`). **Opt-in** with the `realtime` profile since 1.10.0. See "The realtime hub" below | Nothing: it only runs with `realtime`. If the app publishes to Mercure, `verify` and the deploys require it |
| `realtime-relay` | Delivers dispatched Mercure updates to the hub (`oliva-relay`). Same `realtime` profile | Same: only with `realtime` |

La base de datos usa la imagen `pgvector/pgvector:pg${POSTGRES_VERSION}` — es un Postgres normal con la extensión `vector` compilada y una migración que la habilita (`CREATE EXTENSION IF NOT EXISTS vector`). No tiene costo si la app no usa tipos `vector`; no hace falta quitarla.

### The queue worker

Since 1.8.0 `worker` is a service of `docker-compose.yml`, behind `queues`, built from the
backend image; each overlay only sets its image and environment. Before, it existed only in
dev, and an app with queues in production enqueued messages that nothing consumed. Design and
reasons: `docs/roadmap/epics/E-queue-slot.md`.

- **Command:** `oliva-consume` (`backend/frankenphp/consume-messages.sh`) consumes every
  transport except the app's failure transport (its name is asked to Symfony) and recycles
  itself every hour or 128M; `restart:` brings it back. To change it, set
  `WORKER_CONSUME_ARGS` in `.env.backend` (the arguments after `messenger:consume`). Never
  consume the failure transport in the same loop: a poison message would be retried forever.
- **It never migrates.** It starts once the backend is healthy, that is, migrated, and the
  entrypoint skips its setup for any `messenger:consume`.
- **A consumer does not reload code:** after editing a handler, `docker compose restart worker`.
- **One vhost per app and per environment on a shared broker.** Every app inherits the same
  queue names (`ingest`, `enrich`, `failed`): on the same vhost, a worker consumes another
  app's or environment's messages (measured: staging handled production's). See the shared
  infra and staging runbooks (`provision-rabbitmq.sh`).
- **Guarded** (`scripts/lib/queue-guard.sh`): messages routed to an asynchronous transport with
  no worker, a worker on the default vhost of an external broker, or staging on production's
  vhost → `deploy*.sh` abort before `down` (the running stack keeps serving), `verify` step
  `queue` is red, `doctor` shows it. A consumer that lives outside the stack on purpose is
  declared with `OLIVA_QUEUE_CONSUMER=external` in `.env`, and announced on every run.
- **Known limit:** the production worker does not mount the JWT keys (`./secrets/jwt`), same as
  the scheduler. A handler that signs tokens needs that mount added in Oliva.

### The realtime hub

Since 1.10.0 Mercure is its own `realtime` service (`realtime/`, the official `dunglas/mercure`
image with Oliva's Caddyfile), not a block inside the backend. **Opt-in** behind the `realtime`
profile, like `queues` and `cron`. Design and reasons: `docs/roadmap/epics/E-unbundle-roles.md`.

- **Publishing is through the bus, never inline.** The backend dispatches a
  `Symfony\Component\Mercure\Update`; it lands on the `realtime` transport
  (Doctrine/PostgreSQL, `messenger.yaml`) and the `realtime-relay` (`oliva-relay`) POSTs it to
  the hub. So a request never waits on the hub; a hub down for a while delays events instead of
  losing them; an update dispatched inside a transaction exists only if the data committed. An
  app that needs an update sent inline injects `HubInterface` and calls `publish()` — the escape
  hatch. The `MessageBusInterface` path is the documented one and what the demo uses.
- **Latency:** the relay runs `--sleep=0.01` with the transport's `get_notify_timeout: 5000`;
  both are required (either alone is ~1 s; measured p95 ≈ 9 ms). Do not change one without the
  other.
- **The relay never migrates.** It waits for the backend healthy (migrated), then runs
  `messenger:setup-transports realtime` to create `messenger_messages` and consumes. A
  `schema_filter` in `doctrine.yaml` hides that table, so an app **without** the profile has a
  green `doctrine:schema:validate` and never creates it.
- **The hub holds only its key.** It gets `MERCURE_PUBLISHER_JWT_KEY` via `environment:` (not
  `env_file`), so no other secret reaches it; its entrypoint refuses an empty, placeholder or
  publicly known key in every environment. Admin API on localhost (it returns the key in clear).
  History: bolt, capped at `REALTIME_HISTORY_SIZE` (default 1000), no volume — kept across a
  restart, lost on a deploy.
- **`MERCURE_URL`** (`.env.backend`) points the backend/relay at the hub by name
  (`http://realtime/.well-known/mercure`). Leaving it at `localhost`/`backend` makes the backend
  publish to itself: `env check` errors, `verify` is red, `deploy*.sh` abort before `down`.
- **Guarded** (`scripts/lib/queue-guard.sh`, `realtime_guard`): the app uses Mercure (code
  references `Symfony\Component\Mercure`) but the stack has no `realtime` service → the gateway
  answers 502 and updates pile up, so `verify` step `queue` is red and `deploy*.sh` abort. The
  `queues` worker (`oliva-consume`) excludes the realtime transports: they are the relay's.
- **One hub and one relay per app and per environment** on a shared setup, same as the worker
  (the relay reads the app's own database; nothing is shared). `./oliva init --demo` turns on the
  `realtime` profile, since the live canvas publishes through Mercure.

### Aislamiento por app: todo cuelga del project name

Varias apps Oliva conviven en el mismo host (en dev, tu máquina; en prod, el VPS). Todo lo que Compose crea se deriva del **project name** (nombre del directorio, `-p <app>` o `COMPOSE_PROJECT_NAME`), y nada se nombra fijo:

| Recurso | Nombre | Ejemplo (`-p ong`) |
|---|---|---|
| Imágenes | `<project>-<servicio>:<entorno>` (`dev`/`prod`/`staging`) | `ong-backend:prod`, `ong-staging-frontend:staging` |
| Red privada | `<project>_app_network` | `ong_app_network` |
| Volúmenes | `<project>_<volumen>` | `ong_db_data` |
| Alias en `proxy_net` | `<project>-frontend` | `ong-frontend` |

**Regla para forks:** no introducir nombres globales (`image:` con tag fijo, `name:` en redes/volúmenes, `container_name:`). Un nombre fijo es global al daemon Docker y choca en silencio con la otra app: hasta Oliva 1.1 el tag `app-backend-dev:1.0` hacía que el build de finanzas-ong pisara la imagen de CMP (y viceversa), y la red `app_network` era la misma para las dos.

**Guard de colisión en los scripts** (`scripts/lib/project-guard.sh`, sourceado por `deploy*.sh`/`down*.sh`): antes de `down`/`up`, aborta si el project ya tiene containers levantados desde **otro** directorio (label `com.docker.compose.project.working_dir`, que Compose pone solo), y rechaza nombres de app que terminen en `-staging` (sufijo reservado). Lo que el guard **no** cubre: `infra/scripts/provision-postgres.sh` se sigue tipeando a mano y puede driftear del project name. Convención: `<app>_db`/`<app>_user` con el mismo `<app>` que el `-p`.

**Profiles en el `down` de los scripts:** `deploy*.sh`/`down*.sh` bajan con `--profile '*'`. Un `down` sin profile activo deja corriendo, sin error, a los servicios con `profiles:` que un overlay redefine (`scheduler`/`rabbitmq` en `prod.yml`): el stack viejo sobrevive al deploy. El `COMPOSE_PROFILES=cron` de antes reemplazaba los profiles del `.env` y dejaba afuera a `queues`. `'*'` también mete en scope a `database`/`rabbitmq` desactivados en shared-infra; no tienen containers en ese project, así que el `down` no hace nada con ellos.

### Constraints de composer: siempre con techo, pisos con `bump-after-update`

Todo constraint de `require`/`require-dev` en `backend/composer.json` lleva techo (`^x.y`,
`x.y.*`). Uno sin techo (`*`, `>=x`, `dev-main`) deja que `composer update` instale un major
sin aviso: así entró mercure-bundle 0.6 y rompió el build. Lo frena
`scripts/oliva/unbound-constraints.php`, que corre antes de `deps.sh update`, antes de
`sync.sh locks` y en el CI (job `composer-constraints`). `composer validate` hace lo mismo
pero solo sobre `require`.

`"bump-after-update": true` **se queda a propósito**: sube el piso de cada constraint a la
versión instalada (`^3.6` → `^3.7.5`) y nunca toca el techo. Ese piso es lo que impide que
composer **baje** una versión sin avisar cuando un fork agrega una dep que la restringe
(`composer require -W`) o en `sync.sh locks`: sin piso, el fork se queda en una versión que
Oliva ya no testea y el comando termina OK. El costo es ~6 líneas de diff por ciclo de deps en
un archivo SHARED.

Lo que los techos no cubren: una dep **transitiva** puede saltar de major si la directa declara
compatibilidad (`doctrine/orm` acepta `dbal ^3 || ^4`). `deps.sh update` las marca con
`⇑ MAJOR` en el resumen: mirar el changelog antes de mergear.

### Deuda conocida: environments de Bruno commiteados se ensucian solos al testear

La convención de API testing con Bruno (ver `README.md` de la collection `api/` de cada fork, heredada de este patrón) commitea `environments/{staging,prod}.bru` con valores de ejemplo (`project_id`, `member_id`, `batch_id`, montos de los requests). Bruno **escribe de vuelta al archivo en disco** cada vez que el usuario edita una variable desde la UI (el ícono del ojo) o cuando un script `post-response` hace `bru.setVar(...)`. Como esos `.bru` están trackeados en git, **cada sesión de testeo real dirty-ea archivos commiteados** con valores efímeros de esa sesión (ids de fixtures, montos de prueba) — encontrado al testear finanzas-ong (Marcos: `project_id: 1→29`, `member_id: 1→76`, montos `150.00→15000.00`).

Hoy la única mitigación es manual: `git checkout -- api/` después de cada sesión, antes de commitear cualquier otra cosa — funciona pero depende de acordarse.

**Fix sugerido (no implementado), evaluado con Marcos en finanzas-ong:** clonar los environments a una copia personal gitignoreada (`environments/staging.local.bru`, `environments/prod.local.bru`) y trabajar siempre sobre esa en Bruno — los archivos commiteados quedan de plantilla limpia para siempre, nunca los toca la UI. Mismo patrón que `.env.example` → `.env` (gitignoreado) ya usado para los secrets de prod en esta misma collection. Implementar en Oliva (`api/README.md` + `.gitignore` + generar los `.local.bru` iniciales a partir de los committeados) para que baje ya resuelto a cada fork, en vez de backportearlo desde un fork puntual.

## Infra compartida (opcional): `docker-compose.shared-infra.yml`

Overlay genérico, **opt-in**, para cuando varias apps Oliva comparten un mismo
VPS con Postgres/RabbitMQ/reverse-proxy en un repo de infra separado (no es
código de Oliva ni de ninguna app — es su propia capa de Infrastructure-as-Code,
ver convención en `agent-commands.md`/memoria del proyecto de infra).

Se apila encima de `docker-compose.prod.yml`, no lo reemplaza:

```bash
# Standalone (DB propia, de siempre):
docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d

# Con infra compartida (project name ÚNICO con -p, sin DB/Rabbit locales):
docker compose -p ong \
  -f docker-compose.yml -f docker-compose.prod.yml \
  -f docker-compose.shared-infra.yml up -d
# (sin listar servicios: el profile inerte excluye database/rabbitmq y el
#  profile `cron` excluye scheduler. Si la app necesita cron, declarar
#  COMPOSE_PROFILES=cron en el .env y llenar backend/scheduler/crontab.)
```

Qué hace (requiere Docker Compose ≥ 2.24, por la tag de merge `!override`):
- Anula `depends_on: database` de `backend`/`scheduler` con `!override {}` —
  necesario porque los merges de Compose son aditivos: omitir una clave en el
  overlay no la borra, hay que reemplazarla explícitamente.
- Anula los `ports` de `frontend` (deja de exponer `:80` al host — en infra
  compartida el único que publica puertos es el reverse-proxy de infra).
- Desactiva `database`/`rabbitmq` locales con un profile inerte
  (`disabled-in-shared-infra`) para que un `up -d` sin listar servicios no los
  levante por accidente.
- **Topología de red (split, ver README de infra):** `gateway` → red privada
  de la app + `proxy_net` (con alias `<app>-gateway` y, transitoriamente,
  `<app>-frontend`); `frontend` → red privada SOLA; `backend`/`scheduler` →
  red privada + `data_net`. El frontend no toca `proxy_net` (no habla con el
  edge directo) ni `data_net`. Las redes `proxy_net`/`data_net` son externas
  (las crea el repo de infra). Desde 1.9.0 el reverse-proxy compartido debería
  apuntar a `<app>-gateway`; el alias `<app>-frontend` sobrevive una versión
  para no romper Caddyfiles de infra ya escritos.

**Cada fork que use este overlay debe:** (1) **arrancar con `-p <appname>`
único** — eso hace su red privada `<appname>_app_network` y deriva el alias de
`frontend` en `proxy_net` (`${COMPOSE_PROJECT_NAME}-frontend`, ej.
`ong-frontend`), evitando que el DNS interno colisione con otra app (ver
[`infra` README, "Topología de red"]); (2) setear `DATABASE_URL`
en el `.env` del host (gitignored; nunca en `.env.backend`, que está trackeado) apuntando al Postgres compartido (`postgres`), no a `database`.

> **Gotcha — colisión de alias en `proxy_net`:** `proxy_net` es externa y
> compartida entre TODOS los `-p` del VPS. Si dos apps (o prod/staging de la
> misma app) registraran el mismo alias fijo, el DNS interno de Docker hace
> round-robin entre ambas → el reverse-proxy rutearía tráfico de una al
> frontend de la otra. Por eso el alias se
> deriva de `${COMPOSE_PROJECT_NAME:-app}` en vez de hardcodearse: con `-p
> ong` da `ong-frontend`, con `-p ong-staging` da `ong-staging-frontend` —
> nunca colisionan.

Es reversible: si una app deja de usar infra compartida, simplemente no se pasa
ese `-f` al arrancar — `docker-compose.prod.yml` standalone sigue intacto.

### Runbook de deploy con infra compartida (pasos manuales por app)

Estos pasos se repiten en **cada** deploy de **cada** fork sobre infra
compartida. El código viene del `git pull`, pero estos NO (o requieren un valor
único por app):

> **Atajo para redeploys:** los pasos 1, 5 y 6 (pull + build + up) están
> envueltos en `scripts/deploy.sh`. Después del setup inicial (pasos 2-4, que
> se hacen una sola vez por app), cada redeploy es solo:
> `cd ~/<app> && ./scripts/deploy.sh` (toma el `app_name` del nombre del dir;
> hace `down` antes del `up` para no dejar containers stale). Si la app usa
> cron (o colas), declararlo en el `.env` del host: `COMPOSE_PROFILES=cron`
> (o `queues,cron`) — el script no se edita; si el crontab tiene tareas y el
> profile falta, avisa al final. Los pasos de abajo quedan
> como referencia de qué hace cada cosa.

1. **En el VPS, traer el código:** `cd ~/<app> && git pull`.
2. **Create `.env`** (gitignored → it does NOT come with the pull): `./oliva env init`.
   It copies `.env.example` and generates every secret. In shared infra the
   `POSTGRES_*` values stay unused (there is no local `database`), but the file must
   exist: Compose interpolates it and it is the base `env_file`.
3. **Provisionar la base** en el Postgres compartido, desde `~/infra`:
   `./scripts/provision-postgres.sh <app>_db <app>_user` → imprime el
   `DATABASE_URL` con la password generada (guardarla en el gestor de claves).
   El script ya crea la extensión `vector` como superuser (ver nota pgvector
   abajo).
4. **Set `DATABASE_URL`** in `~/<app>/.env` (the host's, gitignored): replace the
   line with the provisioned URL (host `postgres`, `<app>_user`, `<app>_db`). Never in
   `.env.backend`: it is tracked. `./oliva env check` then reports
   `database  REPLACED (points at "postgres" …)`, which is the expected line here.
   `deploy.sh` runs the same check before stopping anything and **aborts** on a secret
   that is missing, a placeholder or publicly known.
   - **If the app uses queues** (profile `queues`): give it a vhost of its own on the
     shared broker, from `~/infra`: `./scripts/provision-rabbitmq.sh <app> <app>_user`,
     and put the printed `RABBITMQ_DSN` in the same `.env`, with `COMPOSE_PROFILES=queues`.
     Every app inherits the same queue names from Oliva (`ingest`, `enrich`, `failed`):
     two apps on the default vhost `/` consume each other's messages, silently.
     `deploy.sh` **aborts** when the worker would run on `/` of the shared broker.
5. **Build:** `docker compose -f docker-compose.yml -f docker-compose.prod.yml build`.
6. **Up** (project name `-p <app>` ÚNICO, los 3 overlays; sin listar servicios,
   el profile inerte ya excluye `database`/`rabbitmq`; el alias de `frontend`
   en `proxy_net` se deriva solo de `-p <app>`, no hace falta tocar nada):
   `docker compose -p <app> -f docker-compose.yml -f docker-compose.prod.yml -f docker-compose.shared-infra.yml up -d`.
7. **Migraciones:** automáticas. El entrypoint del backend las corre en cada
   boot (`doctrine:migrations:migrate`), junto con la generación de las claves
   JWT y el wait-for-db. Solo verificar que no quedaron pendientes:
   `docker exec <app>-backend-1 bin/console doctrine:migrations:status`.
8. **Claves JWT:** en el primer boot el entrypoint las genera en `./secrets/jwt`
   (bind-mount al host, gitignored) usando `JWT_PASSPHRASE`. **Backupear**
   `~/<app>/secrets/jwt/{private,public}.pem` + la `JWT_PASSPHRASE` al gestor de
   claves. De ahí en más persisten y NUNCA se regeneran (recrear el container no
   desloguea a nadie). Para restaurar en un host nuevo: poné los `.pem` ahí antes
   del `up`.
9. **Health:** `docker exec <app>-backend-1 curl -s http://localhost/health` → `{"status":"ok"}`.
10. **(Opt-in) Levantar el stack de staging:** staging es una app aparte en el VPS
    con su propia DB desechable. Ver **"Runbook de staging"** más abajo.
11. **(Cuando haya dominio)** vhost en `~/infra/caddy/Caddyfile` apuntando al
    alias `<app>-gateway` (desde 1.9.0; el `<app>-frontend` queda como alias
    transitorio una versión) + `docker exec infra-reverse-proxy-1 caddy reload`.
12. **Smoke de flujos de negocio:** correr la collection Bruno de la app (`api/`,
    si existe) contra el entorno recién levantado — apuntar `{{base_url}}` al host
    correcto (público tras el paso 11, o `http://localhost` local) y verificar que
    login + los flujos de dominio responden OK. Simétrico al `fixtures:load` del
    runbook de staging: el health check confirma que el proceso arranca; la
    collection confirma que el dominio funciona end-to-end. Es opt-in y por app —
    Oliva no shipea la collection (los requests son 100% dominio, ver tabla de
    stack del README).

> **Gotcha pgvector / shared-infra:** en standalone la app conecta como el
> superuser del Postgres local, así que la migración que hace
> `CREATE EXTENSION vector` funciona. En shared-infra conecta como `<app>_user`
> (no-superuser) y esa migración falla con *"permission denied to create
> extension"*. Por eso `provision-postgres.sh` crea la extensión como superuser
> al provisionar; la migración la encuentra con su `IF NOT EXISTS` y hace no-op.

### Runbook de staging (pasos manuales, primera vez)

Staging es **una app más** en el VPS: misma infra compartida, pero DB propia
desechable y project name propio (`-p <app>-staging`). No interfiere con el
stack de producción.

> **Atajo para redeploys:** `./scripts/deploy-staging.sh` (ejecuta build + up
> + migraciones + `fixtures:load` en una sola llamada). Los pasos de abajo
> documentan el setup inicial (una sola vez) y la lógica de cada paso.

1. **Provisionar la DB de staging** en el Postgres compartido, desde `~/infra`:
   `./scripts/provision-postgres.sh <app>_staging_db <app>_staging_user`
   → imprime el `DATABASE_URL` con la password generada (guardarla en el
   gestor de claves). El script crea la extensión `vector` como superuser.
   **If the app uses queues**, staging also needs a vhost of its own:
   `./scripts/provision-rabbitmq.sh <app>_staging <app>_staging_user`. Without it, staging
   inherits production's `RABBITMQ_DSN` and **its worker consumes production's messages**
   (measured: a message dispatched by production was handled by the staging worker,
   against the staging database). `deploy-staging.sh` aborts when staging and production
   resolve the same broker and vhost.
2. **Crear `.env.staging`** (gitignored → NO viene del pull):
   `cp .env.staging.example .env.staging`
   Setear `DATABASE_URL` con la URL impresa en el paso anterior
   (host `postgres`, `<app>_staging_user`, `<app>_staging_db`), and, with queues, the
   staging `RABBITMQ_DSN`.
3. **Build + up** (project name `-p <app>-staging` propio; staging como app en
   shared-infra). `up -d --build` buildea automáticamente cualquier servicio
   con sección `build` (backend/scheduler con tag `<app>-staging-backend:staging`,
   target `frankenphp_staging`; frontend con tag `<app>-staging-frontend:staging`) —
   no se enumeran servicios a propósito, ver gotcha más abajo:
   ```bash
   docker compose -p <app>-staging \
     -f docker-compose.yml -f docker-compose.prod.yml \
     -f docker-compose.shared-infra.yml -f docker-compose.staging.yml \
     up -d --build
   ```
   Env files que se cargan: `.env` → `.env.backend` → `.env.staging`
   (`.env.staging` carga último y pisa `DATABASE_URL`). `APP_ENV=staging` lo
   fija `docker-compose.staging.yml` vía `environment:` (no vía env_file —
   ver gotcha de precedencia abajo).
5. **Migraciones:** automáticas en el entrypoint. Verificar:
   `docker exec <app>-staging-backend-1 bin/console doctrine:migrations:status`
6. **Seeding:** la imagen `frankenphp_staging` sí tiene `doctrine:fixtures:load`
   (a diferencia de prod). La DB de staging es desechable — la purga es inocua:
   ```bash
   docker exec <app>-staging-backend-1 \
     bin/console doctrine:fixtures:load --group=staging --no-interaction
   ```
7. **Health:** `docker exec <app>-staging-backend-1 curl -s http://localhost/health`

Para reiniciar con datos frescos: `SKIP_PULL=1 ./scripts/deploy-staging.sh`.
Para bajar staging (preserva el volumen de la DB desechable): `./scripts/down-staging.sh`
(o `./scripts/down-staging.sh <app>`; análogo a `down.sh` pero con los 4 overlays
y project name `<app>-staging`). Para purgar también el volumen, bajar a mano
con `-v` agregado al comando de los 4 overlays.

> **env_file de staging:** `docker-compose.staging.yml` usa `env_file: !override`
> (Compose >= 2.24, mismo requisito que shared-infra) para REEMPLAZAR (no concatenar)
> la lista del base. Sin `!override`, Compose concatena listas → `.env`/`.env.backend`
> aparecerían duplicados. Con él, la lista queda `[.env, .env.backend, .env.staging]`
> y `.env.staging` carga último, pisando `DATABASE_URL`.

> **Gotcha — precedencia de `APP_ENV` (la saga que costó 3 capas):** en Compose,
> `environment:` > `env_file:` > `ENV` horneado en la imagen. `prod.yml`
> hardcodea `environment: APP_ENV=prod` en backend/scheduler — sin un
> override explícito en `staging.yml`, ese `environment:` pisaba
> `.env.staging` (env_file) Y el `ENV` del Dockerfile, pese a apilarse encima.
> Síntoma real: `fixtures:load` fallaba con "command not defined" porque
> `prod` no está en `bundles.php`. Por eso `docker-compose.staging.yml`
> fija `environment: [APP_ENV=staging]` explícito en backend/scheduler, y el
> stage `frankenphp_staging` del Dockerfile borra el `.env.local.php` heredado
> de prod (otra capa que pisaba el entorno). Regla general para diagnosticar
> cualquier env var que no toma el valor esperado: primero
> `docker exec <c> printenv VAR` + `docker compose ... config` (de qué capa
> sale), recién después editar.

## Variables de entorno

Ver `.env.example` como referencia. Agrupadas por servicio:
- **DB — standalone (en `.env`)**: `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB`, `POSTGRES_VERSION` y `DATABASE_URL` (la lee Doctrine). `./oliva env init` deriva `DATABASE_URL` de los `POSTGRES_*`; `env check` avisa si dejan de coincidir.
- **DB — infra compartida (también en `.env`, el del host)**: `DATABASE_URL` apunta al `postgres` compartido. `env check` lo anuncia como slot `REPLACED`.
- **Mercure**: `MERCURE_URL`, `MERCURE_PUBLIC_URL`, `MERCURE_PUBLISHER_JWT_KEY`, `MERCURE_JWT_SECRET`, `CADDY_MERCURE_URL`, `CADDY_MERCURE_PUBLIC_URL`
- **RabbitMQ**: `RABBITMQ_USER`, `RABBITMQ_PASSWORD`, `RABBITMQ_DSN`
- **JWT**: `JWT_PASSPHRASE`

## Environment contract (rules for whoever edits configuration)

Since 1.6.0. Until then `.env.backend` (tracked, loaded after `.env`) carried `APP_SECRET`,
`JWT_PASSPHRASE` and the Mercure keys, so every app ran on values that are public in git and
whatever was written in `.env` was ignored, with no error anywhere. Design and reasons:
`docs/roadmap/epics/E-config-contract.md`.

- **A secret lives in `.env` and nowhere else.** Never in `.env.backend`, `.env.frontend`,
  `backend/.env` or a compose file. A tracked file gets a placeholder at most.
- **A variable "doesn't take"? Run `./oliva env check` before editing anything.** It reads what
  Compose *resolves* for each service and says which layer wins. Do not "fix" a container that
  won't start by copying the secret into a tracked file: CI goes red (job `env-contract`) and
  the value is public from the first push.
- **A new variable is declared in `env.manifest`** (the app's; `scripts/oliva/env.manifest` is
  Oliva's) in the same commit that adds it to `.env.example`: `NAME SLOT KIND VALUE`. Kind
  `secret` with `gen:hex32` if it can be generated, `secret` with `-` if a person provides it
  (an API key), `plain` if it isn't secret. Then `env init` and `env check` cover it.
- **`./oliva env init` instead of `cp .env.example .env`**, and again whenever `env check` says
  so. It only touches what is missing, a placeholder or publicly known, and it re-encrypts the
  JWT key when the passphrase changes. Never change `JWT_PASSPHRASE` by hand: the key stays
  encrypted with the old one and every login fails with nothing wrong at boot.
- **Database and broker passwords are bound to their data volume.** Changing the variable alone
  locks the app out of its own data. `env init` won't do it once a volume exists and prints how.
- **Production refuses public secrets.** `deploy.sh` aborts before `down` (the running stack
  keeps serving), and the backend image refuses to start with `APP_ENV=prod`. There is no switch
  to turn either off. The fix is always `./oliva env init` on that machine.
- **A frontend variable goes in `.env.frontend`** (non-secret) or in `environment:`. The
  frontend container does not load `.env`.

## Health check y CI

- `GET /health` → `{"status": "ok"}` (`backend/src/Controller/HealthController.php`).
- `.github/workflows/ci.yml`, job `env-contract` (sin build): `./oliva env init` + `env check` sobre los stacks dev y prod. Rojo si un archivo trackeado lleva un secreto real o pisa a `.env` con un placeholder o un valor públicamente conocido.
- `.github/workflows/ci.yml`: build de imágenes, levanta los servicios, chequea `/health` y `/.well-known/mercure`, corre migraciones, valida el schema de Doctrine y corre PHPUnit. Job adicional de lint de Dockerfile con hadolint.

## Protocolo de explicaciones conceptuales

Cuando el usuario pide que se le explique un concepto (`"explicame X"`, `"enseñame X"`), el agente debe:
1. Agregar la explicación al **final** de `docs/concepts.md` (el glosario de la app) como una nueva sección `## NombreDelConcepto`.
2. Commitear `docs/concepts.md` junto con el trabajo en curso (o en un commit separado si el usuario lo pide).
3. No repetir explicaciones ya presentes — si el concepto ya está en `docs/concepts.md` o en `docs/oliva/concepts.md` (el glosario del framework), referenciarlo.

`docs/concepts.md` es acumulativo: nunca se borra contenido, solo se agrega. `docs/oliva/concepts.md` es de Oliva: una app no lo edita.

## Protocolo de commits del agente

Para proyectos multi-sesión o de trabajo autónomo, `agent-commits.md` en la raíz del proyecto registra cambios del agente con formato detallado. **No se anota cada commit**: cuando el agente haga un cambio que le parezca interesante (una decisión de diseño, un fix con *por qué* no obvio, algo que afecte cómo se opera el proyecto), **le pregunta a Marcos si lo registra** — Marcos decide. Lo rutinario no se anota ni se pregunta.

### Formato

```markdown
## [PASO X.Y] <título del commit>
**Hash:** `<hash completo>`
**Rama:** `<rama>`
**Fecha:** <fecha>

### Cambios
| Archivo | Tipo | Descripción |
|---|---|---|
| path/archivo | nuevo/modificado/eliminado | qué hace |

### Justificación
<por qué se tomaron estas decisiones, qué problema resuelven, qué alternativas se descartaron>
```

### Reglas
- Registrar **todos** los archivos modificados, no solo los principales.
- La justificación debe responder **por qué**, no solo describir el qué (eso ya lo hace la tabla).
- Si un cambio resuelve un problema encontrado durante la ejecución (no previsto en el plan), documentarlo explícitamente.
- El commit de git y la entrada en `agent-commits.md` van en el **mismo commit**.

## Comandos del agente

Ver `agent-commands.md` en la raíz del proyecto para los comandos que el usuario puede invocar en el chat (protocolos de reinicio de sesión, etc.).

## Chequeos de sanidad (inicio y cierre de sesión)

Correr al **inicio** de cada sesión antes de tocar código:

```bash
./oliva doctor
```

Colapsa rama, status, log, `docker compose ps`, estado de migraciones, el entorno que Compose
resuelve (`env check`: secretos faltantes o públicos, slots reemplazados), `deps.sh due`,
acciones de upgrade pendientes en esta máquina (`sync.sh pending`; se reconocen con `./oliva ack`)
y (si el repo es un fork, detectando el remote `oliva-upstream`) `sync.sh check` en
una sola llamada read-only (lo único que escribe es `.oliva/acked-version` la primera vez, gitignored).
Ningún paso lo aborta — ni con Docker abajo.

`deps.sh due` (dentro de `doctor`) reporta DOS cadencias: el ciclo de deps (frescura, ~45 días → `report`/`update`)
y el audit de CVEs (seguridad, ~7 días → `scripts/oliva/deps.sh audit`, que corre composer +
yarn audit + Trivy sobre las imágenes base). Si el audit avisa que TOCA, correr `deps.sh audit`
— un CVE no espera al ciclo de 45 días. Ver `docs/oliva/actualizaciones.md` ("El aviso por advisory").

En un **fork**, `doctor` agrega el chequeo de `sync.sh check` (¿Oliva avanzó?) automáticamente.
Si deps o sync avisan, mencionárselo a Marcos al arrancar — no ejecutar el ciclo ni el audit sin que lo pida.

Verificar al **cierre** de sesión antes de cortar:

```bash
git status -s                      # sin archivos sin commitear (salvo intencional)
git log --oneline -3               # último commit con mensaje claro
```

Si el proyecto usa `agent-commits.md`, verificar si el último commit merece una entrada (si es un cambio interesante, agregar; si es rutinario, omitir).
