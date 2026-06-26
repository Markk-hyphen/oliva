# Oliva

Framework base para construir webapps: backend Symfony (FrankenPHP), frontend Vite, base de datos PostgreSQL (con pgvector), tiempo real vía Mercure, colas vía RabbitMQ + Symfony Messenger, y un contenedor scheduler (cron) para tareas programadas. Todo orquestado con Docker Compose.

Este `CLAUDE.md` es la guía operativa para agentes que trabajen sobre proyectos construidos con Oliva. La documentación humana (stack, getting started) está en `README.md`.

## Comandos principales

### Desarrollo
```bash
docker compose up
```
El `docker-compose.override.yml` se aplica automáticamente: monta el código fuente con hot-reload, expone el backend en `:80` y el frontend en `:3000`.

### Producción
```bash
docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d
```
Usa imágenes compiladas (`app-backend-prod:1.0`, `app-frontend-prod:1.0`). El frontend queda expuesto en `:80`.

### Build de producción
```bash
docker compose -f docker-compose.yml -f docker-compose.prod.yml build
```

## Estructura
- `backend/` — Symfony con FrankenPHP (Doctrine ORM/Migrations, pgvector, Mercure, Messenger)
- `frontend/` — Vite (Node), incluye demo de Mercure en vivo (`src/js/live.js`, sección "Live" de `index.html`)
- `docs/concepts.md` — glosario técnico acumulativo (pgvector, RabbitMQ, AMQP, etc.)
- `docs/examples/` — esqueletos de referencia (`*.php.example`) no registrados como código de la app
- `.env`, `.env.backend`, `.env.frontend` — variables por entorno
- `.env.prod` — variables de producción

## Servicios incluidos y cómo desactivarlos

Además de `database`, `backend` y `frontend`, `docker-compose.yml` define:

| Servicio | Para qué | Si la app no lo necesita |
|---|---|---|
| `rabbitmq` | Broker para Symfony Messenger (colas `ingest`/`enrich` de ejemplo, comentadas) | Quitar el bloque `rabbitmq` y las dependencias `depends_on: rabbitmq` de `backend`/`scheduler`/`worker` |
| `scheduler` | Ejecuta `supercronic` con `backend/scheduler/crontab` para tareas periódicas. **Opt-in:** vive tras el profile `cron`, no arranca por defecto (mismo criterio que `rabbitmq`/`queues`). El crontab base viene vacío. | Por defecto ya no corre. Una app que necesite cron activa el profile (`--profile cron` o listando `scheduler` en `up`) y llena `backend/scheduler/crontab`. Para eliminarlo del todo: quitar el bloque `scheduler` y `backend/scheduler/crontab` |
| `worker` (en `docker-compose.override.yml`, dev) | Corre `bin/console messenger:consume` | Quitar el bloque `worker` si no hay mensajes async |

La base de datos usa la imagen `pgvector/pgvector:pg${POSTGRES_VERSION}` — es un Postgres normal con la extensión `vector` compilada y una migración que la habilita (`CREATE EXTENSION IF NOT EXISTS vector`). No tiene costo si la app no usa tipos `vector`; no hace falta quitarla.

### Deuda conocida: `worker` no tiene definición de producción

`docker-compose.override.yml` (dev) define `worker` con `bin/console messenger:consume`, pero no hay equivalente en `docker-compose.prod.yml` ni en el `docker-compose.yml` base. Si una app usa RabbitMQ/Messenger en serio, antes de ir a producción hay que agregar un servicio `worker` (imagen `app-backend-prod:1.0`, comando `messenger:consume`, sin exponer puertos). `scheduler` sí está cubierto en prod (usa `app-backend-prod:1.0` / target `frankenphp_prod`, igual que `backend`).

Mercure (`/.well-known/mercure`) está siempre activo vía el hub de Caddy (`backend/frankenphp/Caddyfile`); la demo de canvas en vivo (`backend/public/live.php` + `frontend/src/js/live.js`) muestra que funciona out of the box.

## Infra compartida (opcional): `docker-compose.shared-infra.yml`

Overlay genérico, **opt-in**, para cuando varias apps Oliva comparten un mismo
VPS con Postgres/RabbitMQ/reverse-proxy en un repo de infra separado (no es
código de Oliva ni de ninguna app — es su propia capa de Infrastructure-as-Code,
ver convención en `claude-commands.md`/memoria del proyecto de infra).

Se apila encima de `docker-compose.prod.yml`, no lo reemplaza:

```bash
# Standalone (DB propia, de siempre):
docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d

# Con infra compartida (project name ÚNICO con -p, sin DB/Rabbit locales):
docker compose -p ong \
  -f docker-compose.yml -f docker-compose.prod.yml \
  -f docker-compose.shared-infra.yml up -d
# (sin listar servicios: el profile inerte excluye database/rabbitmq y el
#  profile `cron` excluye scheduler. Si la app necesita cron, agregar
#  `--profile cron` y llenar backend/scheduler/crontab.)
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
- **Topología de red (split, ver README de infra):** `frontend` → red privada
  de la app + `proxy_net` (alias único); `backend`/`scheduler` → red privada +
  `data_net`. El frontend no toca `data_net` (no llega a la DB). Las redes
  `proxy_net`/`data_net` son externas (las crea el repo de infra).

**Cada fork que use este overlay debe:** (1) reemplazar el placeholder
`CHANGE-THIS-ALIAS-frontend` por un alias único (ej. `ong-frontend`); (2)
**arrancar con `-p <appname>` único** — eso hace su red privada
`<appname>_app_network` y evita que el DNS interno colisione con otra app (ver
[`infra` README, "Topología de red"]); (3) descomentar/setear `DATABASE_URL`
en `.env.backend` de prod apuntando al Postgres compartido (`postgres`), no a `database`.

Es reversible: si una app deja de usar infra compartida, simplemente no se pasa
ese `-f` al arrancar — `docker-compose.prod.yml` standalone sigue intacto.

### Runbook de deploy con infra compartida (pasos manuales por app)

Estos pasos se repiten en **cada** deploy de **cada** fork sobre infra
compartida. El código viene del `git pull`, pero estos NO (o requieren un valor
único por app):

> **Atajo para redeploys:** los pasos 1, 6 y 7 (pull + build + up) están
> envueltos en `scripts/deploy.sh`. Después del setup inicial (pasos 2-5, que
> se hacen una sola vez por app), cada redeploy es solo:
> `cd ~/<app> && ./scripts/deploy.sh` (toma el `app_name` del nombre del dir;
> hace `down` antes del `up` para no dejar containers stale). Si la app usa
> cron, editar el script o agregar `--profile cron`. Los pasos de abajo quedan
> como referencia de qué hace cada cosa.

1. **En el VPS, traer el código:** `cd ~/<app> && git pull` (trae el overlay y
   el `.env.backend` con el `DATABASE_URL` comentado).
2. **Crear el `.env`** (gitignored → NO viene en el pull): `cp .env.example .env`.
   En shared-infra casi todo el `.env` queda inerte (no hay `database` local) o
   lo pisa `.env.backend`; igual debe existir porque Compose lo interpola
   (`POSTGRES_VERSION`, etc.) y es el `env_file` base.
3. **Provisionar la base** en el Postgres compartido, desde `~/infra`:
   `./scripts/provision-postgres.sh <app>_db <app>_user` → imprime el
   `DATABASE_URL` con la password generada (guardarla en el gestor de claves).
   El script ya crea la extensión `vector` como superuser (ver nota pgvector
   abajo).
4. **Setear el `DATABASE_URL`** en `~/<app>/.env.backend`: **descomentar** la
   línea y pegar la URL provisionada (host `postgres`, `<app>_user`, `<app>_db`).
   Al cargarse después de `.env`, pisa el `DATABASE_URL` standalone.
5. **Alias de red único** en `docker-compose.shared-infra.yml`: reemplazar
   `CHANGE-THIS-ALIAS-frontend` por `<app>-frontend` (esto sí se commitea en el
   fork, una vez).
6. **Build:** `docker compose -f docker-compose.yml -f docker-compose.prod.yml build`.
7. **Up** (project name `-p <app>` ÚNICO, los 3 overlays; sin listar servicios,
   el profile inerte ya excluye `database`/`rabbitmq`):
   `docker compose -p <app> -f docker-compose.yml -f docker-compose.prod.yml -f docker-compose.shared-infra.yml up -d`.
8. **Migraciones:** automáticas. El entrypoint del backend las corre en cada
   boot (`doctrine:migrations:migrate`), junto con la generación de las claves
   JWT y el wait-for-db. Solo verificar que no quedaron pendientes:
   `docker exec <app>-backend-1 bin/console doctrine:migrations:status`.
9. **Claves JWT:** en el primer boot el entrypoint las genera en `./secrets/jwt`
   (bind-mount al host, gitignored) usando `JWT_PASSPHRASE`. **Backupear**
   `~/<app>/secrets/jwt/{private,public}.pem` + la `JWT_PASSPHRASE` al gestor de
   claves. De ahí en más persisten y NUNCA se regeneran (recrear el container no
   desloguea a nadie). Para restaurar en un host nuevo: poné los `.pem` ahí antes
   del `up`.
10. **Health:** `docker exec <app>-backend-1 curl -s http://localhost/health` → `{"status":"ok"}`.
11. **(Cuando haya dominio)** vhost en `~/infra/caddy/Caddyfile` apuntando al
    alias `<app>-frontend` + `docker exec infra-reverse-proxy-1 caddy reload`.

> **Gotcha pgvector / shared-infra:** en standalone la app conecta como el
> superuser del Postgres local, así que la migración que hace
> `CREATE EXTENSION vector` funciona. En shared-infra conecta como `<app>_user`
> (no-superuser) y esa migración falla con *"permission denied to create
> extension"*. Por eso `provision-postgres.sh` crea la extensión como superuser
> al provisionar; la migración la encuentra con su `IF NOT EXISTS` y hace no-op.

## Variables de entorno

Ver `.env.example` como referencia. Agrupadas por servicio:
- **DB — standalone (en `.env`)**: `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB`, `POSTGRES_VERSION` y `DATABASE_URL` (la lee Doctrine). Las credenciales de `DATABASE_URL` deben coincidir con los `POSTGRES_*` — es el mismo Postgres local.
- **DB — infra compartida (override en `.env.backend`)**: `DATABASE_URL` viene comentado por default; se descomenta/setea solo en deploys con infra compartida (apunta al `postgres` compartido) y pisa al de `.env`.
- **Mercure**: `MERCURE_URL`, `MERCURE_PUBLIC_URL`, `MERCURE_PUBLISHER_JWT_KEY`, `MERCURE_JWT_SECRET`, `CADDY_MERCURE_URL`, `CADDY_MERCURE_PUBLIC_URL`
- **RabbitMQ**: `RABBITMQ_USER`, `RABBITMQ_PASSWORD`, `RABBITMQ_DSN`
- **JWT**: `JWT_PASSPHRASE`

## Health check y CI

- `GET /health` → `{"status": "ok"}` (`backend/src/Controller/HealthController.php`).
- `.github/workflows/ci.yml`: build de imágenes, levanta los servicios, chequea `/health` y `/.well-known/mercure`, corre migraciones, valida el schema de Doctrine y corre PHPUnit. Job adicional de lint de Dockerfile con hadolint.

## Protocolo de explicaciones conceptuales

Cuando el usuario pide que se le explique un concepto (`"explicame X"`, `"enseñame X"`), el agente debe:
1. Agregar la explicación al **final** de `docs/concepts.md` como una nueva sección `## NombreDelConcepto`.
2. Commitear `docs/concepts.md` junto con el trabajo en curso (o en un commit separado si el usuario lo pide).
3. No repetir explicaciones ya presentes en el archivo — si el concepto ya está, referenciarlo.

`docs/concepts.md` es acumulativo: nunca se borra contenido, solo se agrega.

## Protocolo de commits del agente

Para proyectos donde se quiera dejar un registro detallado de cada cambio del agente (recomendado para trabajo autónomo o de varias sesiones), crear un `agent-commits.md` en la raíz del proyecto y registrar ahí **cada commit que realice el agente**, antes o junto con el commit de git.

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

Ver `claude-commands.md` en la raíz del proyecto para los comandos que el usuario puede invocar en el chat (protocolos de reinicio de sesión, etc.).

## Chequeos de sanidad (inicio y cierre de sesión)

Correr al **inicio** de cada sesión antes de tocar código:

```bash
git branch --show-current          # confirmar la rama de trabajo esperada
git status -s                      # debe estar limpio (o saber qué hay pendiente)
git log --oneline -3               # orientarse en dónde quedó la sesión anterior
docker compose ps                  # todos los servicios healthy
docker compose exec backend bin/console doctrine:migrations:status  # sin migraciones pendientes
```

Verificar al **cierre** de sesión antes de cortar:

```bash
git status -s                      # sin archivos sin commitear (salvo intencional)
git log --oneline -3               # último commit con mensaje claro
```

Si el proyecto usa `agent-commits.md`, verificar que el último commit tenga su entrada correspondiente.
