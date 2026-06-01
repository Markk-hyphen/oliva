# Agent Commits Log

Registro de commits realizados por el agente durante la construcción del proyecto.
Cada entrada detalla qué cambió, por qué, y qué decisión de arquitectura respalda el cambio.

---

## Formato de entrada

```
## [PASO X.Y] <título del commit>
**Hash:** `<hash>`
**Rama:** `<rama>`
**Fecha:** <fecha>

### Cambios
| Archivo | Tipo | Descripción |
|---|---|---|
| path/archivo | nuevo/modificado/eliminado | qué hace |

### Justificación
<explicación de por qué se tomaron estas decisiones, qué problema resuelven, qué alternativas se descartaron>
```

---

## [PASO 0.8] feat: PHPUnit base — instalar, configurar y habilitar en CI

**Hash:** `dc444bc`
**Rama:** `release/plan-market-pulse`
**Fecha:** 2026-06-01

### Cambios

| Archivo | Tipo | Descripción |
|---|---|---|
| `backend/composer.json` | modificado | Agrega `phpunit/phpunit ^12.5` y test-pack (browser-kit, css-selector) en require-dev |
| `backend/composer.lock` | modificado | Lock actualizado con PHPUnit 12.5.28 y dependencias |
| `backend/symfony.lock` | modificado | Recipe de phpunit/phpunit registrada |
| `backend/phpunit.dist.xml` | nuevo | Configuración PHPUnit generada por la recipe de Flex; habilita deprecation/notice/warning como errores |
| `backend/tests/bootstrap.php` | nuevo | Bootstrap de PHPUnit + Symfony generado por la recipe |
| `backend/tests/Unit/Message/IngestSourceMessageTest.php` | nuevo | Primer test unitario: verifica `IngestSourceMessage` (inmutabilidad del sourceId) |
| `backend/.dockerignore` | modificado | Elimina la exclusión de `tests/`; sin esto el build fallaba con "not found" |
| `backend/Dockerfile` | modificado | Agrega `COPY --link tests tests/` y `COPY --link phpunit.dist.xml ./` al stage base |
| `docker-compose.override.yml` | modificado | Agrega mount `./backend/tests:/app/tests` en el servicio `backend` para hot-reload de tests en dev |
| `.github/workflows/ci.yml` | modificado | Quita `if: false` del paso PHPUnit; usa `php vendor/bin/phpunit` (bin/phpunit ya no es generado por la recipe en PHPUnit 12) |
| `CLAUDE.md` | modificado | Actualiza "Próximo paso" a 1.1 |

### Justificación

**PHPUnit 12 no genera `bin/phpunit`:** la Symfony recipe de PHPUnit ≥11.1 ya no crea el wrapper `bin/phpunit` (solía descargar el phar de PHPUnit bridge). En PHPUnit 12 el binario canónico es `vendor/bin/phpunit`. El CI y la documentación se actualizan para usarlo directamente.

**`tests/` estaba excluido del build context:** el `.dockerignore` original del template excluye `tests/` y `vendor/` (correcto para el caso de uso original). Al incorporar tests en el repo, `tests/` debe estar disponible en el contexto para que `COPY --link tests tests/` funcione en CI/prod.

**Mount de `tests/` en dev:** sin el mount, los archivos de test creados en el host no son visibles en el contenedor (que solo monta `src/`, `config/`, `migrations/`). Con el mount, el ciclo edit-run-test en dev es inmediato sin rebuild.

**Test elegido — `IngestSourceMessage`:** el DTO es el artefacto más simple del dominio (solo constructor + propiedad readonly), no requiere kernel ni base de datos, y valida que el autoloading y la config de PHPUnit están correctos. El GATE del paso exige un test que pase, no un test sofisticado.

**Verificación:** `php vendor/bin/phpunit` → `OK (2 tests, 2 assertions)` en el contenedor de dev.

---

## [PASO 0.7] feat: corregir CI y agregar health endpoint

**Hash:** `a1942d4`
**Rama:** `release/plan-market-pulse`
**Fecha:** 2026-06-01

### Cambios

| Archivo | Tipo | Descripción |
|---|---|---|
| `.github/workflows/ci.yml` | nuevo | CI correcto en la raíz del repo; trigger en `release/plan-market-pulse`; genera env files en CI; usa `docker compose build`; checks HTTP/Mercure/migrations/schema |
| `backend/.github/workflows/ci.yml` | eliminado | Estaba en ubicación incorrecta; GitHub Actions no lo leía |
| `backend/src/Controller/HealthController.php` | nuevo | `GET /health` → `{"status":"ok"}` — endpoint para CI y monitoreo |

### Justificación

**`.github/` estaba dentro de `backend/`:** el template symfony-docker asume que el repo root es el backend. En este proyecto el repo root es la app entera (`backend/` + `frontend/`). GitHub Actions solo lee `.github/` en la raíz del repositorio; el CI nunca se ejecutó.

**`if: false` en pasos de Doctrine:** el template pone `if: false` en los pasos de ORM/migraciones para que el CI verde de base. Se quitó ahora que Doctrine, Migrations y pgvector están instalados y el schema está en sync.

**PHPUnit sigue con `if: false`:** PHPUnit se instala en el paso 0.8. Habilitarlo ahora haría el CI rojo.

**Endpoint `/health` en lugar de chequear `http://localhost`:** sin rutas definidas el root devuelve 404 y `curl --fail-with-body` falla. El health endpoint es la práctica correcta (liveness probe para CI y para Kubernetes/Docker en producción).

**`docker compose build` en lugar de `bake-action`:** el bake-action de Docker usa GHA cache pero necesita configuración adicional (credenciales de registry, ARGs de build). `docker compose build` es equivalente funcional para CI sin la complejidad del cache de capas en GHA. Se puede agregar caché en una iteración futura.

**Verificación local:** todos los pasos del CI pasaron manualmente: `/health` → 200, Mercure → 200, migrations → "already at latest version", `schema:validate` → "in sync".

---

## [PASO 0.6] feat: scheduler cron container with supercronic

**Hash:** `fc7cb23`
**Rama:** `release/plan-market-pulse`
**Fecha:** 2026-06-01

### Cambios

| Archivo | Tipo | Descripción |
|---|---|---|
| `backend/Dockerfile` | modificado | Descarga supercronic v0.2.46 en el stage base; copia `scheduler/crontab` a `/etc/supercronic/crontab` |
| `backend/scheduler/crontab` | nuevo | Crontab de supercronic: `*/5 * * * *` ejecuta `bin/console app:sources:poll -v` |
| `backend/src/Command/SourcesPollCommand.php` | nuevo | Comando stub `app:sources:poll`: itera lista hardcodeada de sources y despacha `IngestSourceMessage` por cada uno |
| `backend/src/Message/IngestSourceMessage.php` | nuevo | DTO de mensaje para el pipeline de ingesta; lleva `sourceId` (string) |
| `backend/src/MessageHandler/IngestSourceHandler.php` | nuevo | Handler stub: recibe `IngestSourceMessage`, loguea no-op, retorna éxito |
| `backend/config/packages/messenger.yaml` | modificado | Agrega `default_publish_routing_key` a exchanges `ingest` y `enrich`; habilita routing `IngestSourceMessage → ingest` |
| `docker-compose.yml` | modificado | Agrega servicio base `scheduler` (imagen backend, depends_on rabbitmq+database) |
| `docker-compose.override.yml` | modificado | Agrega override `scheduler` con comando `supercronic`, mounts de src/config/crontab y healthcheck `kill -0 1` |

### Justificación

**`default_publish_routing_key` faltaba en la config del exchange:** sin esa clave, Symfony publica al exchange con routing key vacío (`''`). En un exchange `direct`, el mensaje solo llega a la queue si el routing key matchea el binding key (`ingest`). Resultado: `publish_in: 18` en el exchange pero `deliver_get: 0` en la queue — los mensajes se "perdían" silenciosamente. Detectado inspeccionando la management API de RabbitMQ; no hay error visible en el producer (el dispatch "no falla"). Fix: agregar `default_publish_routing_key: ingest/enrich` a cada exchange.

**Handler stub para evitar failed queue churn:** sin un handler registrado, Symfony lanza `NoHandlerForMessageException`, reintenta 3 veces y manda el mensaje a la failed queue. Para la fase 0.6 (stub), eso generaría ruido en la failed queue con cada ejecución del cron. El handler stub simplemente loguea y retorna éxito; el handler real llega en Fase 1.

**Supercronic en el stage base (no en un stage separado):** el scheduler necesita PHP para ejecutar `bin/console`. Añadir supercronic al mismo Dockerfile evita un segundo contexto de build y permite que worker y scheduler compartan la misma imagen (menos superficie de mantenimiento). El binario es estático (~7MB), sin impacto significativo en la imagen.

**Verificación:** supercronic ejecutó `app:sources:poll` a las 03:45 y 03:50 UTC (automáticos); worker logueó `IngestSourceHandler: stub no-op` + `acknowledged to transport` para los 3 mensajes de cada run.

---

## [docs] docs: agregar explicación de RabbitMQ a concepts.md

**Hash:** `18e1740`
**Rama:** `release/plan-market-pulse`
**Fecha:** 2026-06-01

### Cambios

| Archivo | Tipo | Descripción |
|---|---|---|
| `concepts.md` | modificado | Agrega sección `## RabbitMQ` con explicación conceptual, tabla de términos AMQP, diagrama de flujo del proyecto y justificación de la elección vs Kafka/Redis Streams |

### Justificación

El usuario pidió explicación de RabbitMQ. No estaba en `concepts.md`. Se agregó siguiendo el protocolo de explicaciones conceptuales del CLAUDE.md.

---

## [PASO 0.5] feat: add RabbitMQ, Symfony Messenger, worker service (step 0.5)

**Hash:** `b6c53f1`
**Rama:** `release/plan-market-pulse`
**Fecha:** 2026-06-01

### Cambios

| Archivo | Tipo | Descripción |
|---|---|---|
| `docker-compose.yml` | modificado | Agrega servicio `rabbitmq` (imagen `3-management`, volumen `rabbitmq_data`, healthcheck); backend `depends_on` rabbitmq healthy; agrega volumen `rabbitmq_data` |
| `docker-compose.override.yml` | modificado | Expone puertos `5672` y `15672` de RabbitMQ en dev; agrega servicio `worker` con `messenger:consume ingest enrich` |
| `backend/Dockerfile` | modificado | Agrega extensión PHP `amqp` a `install-php-extensions` |
| `backend/composer.json` | modificado | Agrega `symfony/messenger` y `symfony/amqp-messenger` |
| `backend/composer.lock` | modificado | Lock actualizado |
| `backend/symfony.lock` | modificado | Recipe Flex de messenger registrada |
| `backend/config/packages/messenger.yaml` | modificado | Configuración completa: transportes `ingest` + `enrich` + `failed` con DSN AMQP, DLX (`x-dead-letter-exchange`), retry strategy (3 intentos, backoff exponencial) |
| `backend/.env` | modificado | Agrega `RABBITMQ_DSN` placeholder |
| `.env.backend` (raíz) | modificado | Agrega `RABBITMQ_USER`, `RABBITMQ_PASSWORD`, `RABBITMQ_DSN` con valores de dev |
| `.env.example` | modificado | Documenta variables de RabbitMQ y Mercure |

### Justificación

**`ext-amqp` no estaba en el Dockerfile:** igual que `pdo_pgsql` en el paso 0.2, el template no incluye extensiones específicas. Sin `ext-amqp`, Composer rechaza `symfony/amqp-messenger` por falta de plataforma. Solución: agregar al Dockerfile y rebuildar.

**Tres transportes desde el inicio (ingest / enrich / failed):** diseño deliberado. `ingest` y `enrich` son los dos stages del pipeline. `failed` es el dead-letter — los mensajes que agotan los reintentos van ahí en lugar de perderse. Permite inspeccionarlos y reprocesarlos con `messenger:failed:retry`.

**DLX via `x-dead-letter-exchange` en las queue arguments:** configura el DLX a nivel de RabbitMQ, no solo a nivel Symfony. Si el worker muere sin hacer ACK, Rabbit mueve el mensaje al exchange `failed` sin necesidad de que Symfony intervenga. Más robusto que depender solo del retry de Messenger.

**Retry strategy diferenciada:** `ingest` usa delay 1s (errores de red cortos); `enrich` usa 2s (LLM puede tardar en responder). Multiplicador x2 en ambos para backoff exponencial. 3 reintentos máximos antes de DLX.

**Worker con `--time-limit=3600`:** el worker reinicia cada hora para liberar memoria y recibir código actualizado (en dev). `restart: unless-stopped` lo relanza automáticamente.

**Verificación:** `messenger:stats` muestra los 3 transportes conectados con 0 mensajes; management UI en `:15672` muestra las colas `ingest`, `enrich`, `failed`.

---

## [PASO 0.4] feat: install MercureBundle, configure publisher (step 0.4)

**Hash:** `88f4a93`
**Rama:** `release/plan-market-pulse`
**Fecha:** 2026-06-01

### Cambios

| Archivo | Tipo | Descripción |
|---|---|---|
| `backend/composer.json` | modificado | Agrega `symfony/mercure-bundle ^0.4.2` |
| `backend/composer.lock` | modificado | Lock actualizado con mercure-bundle y dependencias |
| `backend/symfony.lock` | modificado | Recipe Flex registrada |
| `backend/config/bundles.php` | modificado | Agrega `MercureBundle::class => ['all' => true]` |
| `backend/config/packages/mercure.yaml` | nuevo | Config del bundle: `MERCURE_URL`, `MERCURE_PUBLIC_URL`, `MERCURE_JWT_SECRET` |
| `backend/.env` | modificado | Agrega bloque `symfony/mercure-bundle` con placeholders de las 3 variables |
| `backend/src/Command/MercurePublishTestCommand.php` | nuevo | Console command `app:mercure:test` para smoke test del publisher |
| `.env.backend` (raíz) | modificado | Agrega `MERCURE_PUBLISHER_JWT_KEY`, `MERCURE_JWT_SECRET`, `MERCURE_URL`, `MERCURE_PUBLIC_URL` con valores reales de dev |

### Justificación

**`!ChangeThisSecret!` tiene 144 bits — HMAC-SHA256 requiere mínimo 256 bits:** el Caddyfile original usa ese placeholder como default. Al instalar el MercureBundle, la librería JWT fuerza un mínimo de 32 bytes en el secret. Solución: generar un hex de 64 chars (256 bits) y propagarlo a ambos lados. Documentado: `MERCURE_PUBLISHER_JWT_KEY` (Caddy) y `MERCURE_JWT_SECRET` (bundle) deben ser el mismo valor.

**Por qué `MERCURE_URL=http://localhost/.well-known/mercure`:** el hub Mercure está embebido en Caddy, que corre en el mismo contenedor que PHP (arquitectura FrankenPHP). El backend publica al hub por localhost — no hay red entre servicios. En producción esta URL no cambia.

**`MERCURE_PUBLIC_URL` igual a `MERCURE_URL` por ahora:** el bundle usa `public_url` para generar headers `Link` en respuestas API. El frontend (`live.js`) construye la URL de suscripción desde `window.location.origin` (no usa los headers), así que el valor actual es irrelevante hasta que se use esa feature. Se puede sobrescribir por entorno vía `env_file`.

**Rebuild obligatorio al cambiar `composer.lock`:** en dev, el `vendor/` vive dentro de la imagen (no está montado). Al instalar paquetes dentro del contenedor y sincronizar solo `composer.json/lock` al host, la imagen queda desactualizada. La imagen debe rebuildearse para que el nuevo `vendor/` quede baked in.

**`MercurePublishTestCommand`:** permanece como smoke test útil para CI (paso 0.7). No es código temporal — sirve para verificar publisher en cualquier entorno.

**Verificación:** `bin/console app:mercure:test` retorna `Published OK. Message ID: urn:uuid:...`; cliente EventSource en browser recibe el mensaje.

---

## [PASO 0.3] feat: add pgvector — extension, migration, Doctrine type

**Hash:** `1435f0c`
**Rama:** `release/plan-market-pulse`
**Fecha:** 2026-06-01

### Cambios

| Archivo | Tipo | Descripción |
|---|---|---|
| `docker-compose.yml` | modificado | Cambia imagen `database` de `postgres:15` a `pgvector/pgvector:pg15` |
| `backend/migrations/Version20260601001301.php` | nuevo | Migración que habilita la extensión `vector` en Postgres (`CREATE EXTENSION IF NOT EXISTS vector`) |
| `backend/composer.json` | modificado | Agrega `pgvector/pgvector ^0.2.2` |
| `backend/composer.lock` | modificado | Lock actualizado |
| `backend/symfony.lock` | modificado | Recipe registrada |
| `backend/config/packages/doctrine.yaml` | modificado | Registra el tipo Doctrine `vector` → `Pgvector\Doctrine\VectorType`; fija `server_version: '15'` |

### Justificación

**`pgvector/pgvector:pg15` es compatible con el volumen existente:** la imagen es `postgres:15` + la extensión preinstalada. El formato del directorio de datos es idéntico, por lo que el volumen `db_data` no se pierde ni hay que reinicializarlo.

**La extensión se habilita con una migración, no en `initdb`:** esto la mantiene versionada junto con el esquema de la app. Si se destruye y recrea la DB, la migración la reinstala automáticamente. Alternativa descartada: script de init de Postgres (`docker-entrypoint-initdb.d`) — funciona, pero es una pieza de infra separada que no está bajo control de Migrations.

**`server_version: '15'` en doctrine.yaml:** el comentario original del template decía `server_version: '16'`; fijar `15` evita que Doctrine use features de PG16 (ej: generación de identidad con nueva sintaxis) que no están disponibles en el servidor en uso.

**Tipo Doctrine `vector`:** sin este registro, `#[ORM\Column(type: 'vector')]` en una entidad lanza `UnknownColumnType`. El paquete `pgvector/pgvector` provee `VectorType` que convierte entre `float[]` PHP y el literal `[x,y,z]` que espera el tipo SQL `vector(n)`.

**Verificación:** `pgvector 0.8.2` instalada en la DB; operación de similitud coseno (`<=>`) funciona; `doctrine:schema:validate` verde.

---

## [PASO 0.2] feat: install Doctrine ORM + Migrations, add pdo_pgsql extension

**Hash:** `0d607537` (ver `git show 0d60753`)
**Rama:** `release/plan-market-pulse`
**Fecha:** 2026-05-31

### Cambios

| Archivo | Tipo | Descripción |
|---|---|---|
| `backend/Dockerfile` | modificado | Agrega `pdo_pgsql` a `install-php-extensions`; agrega `COPY --link migrations migrations/` |
| `backend/composer.json` | modificado | Agrega `symfony/orm-pack`, `doctrine/doctrine-migrations-bundle`; y `symfony/maker-bundle` en dev |
| `backend/composer.lock` | modificado | Lock actualizado con todas las dependencias de Doctrine y maker |
| `backend/symfony.lock` | modificado | Recipes Flex de doctrine-bundle y maker-bundle registradas |
| `backend/config/bundles.php` | modificado | Agrega `DoctrineMigrationsBundle` (Flex no pudo escribirlo por el .env read-only) |
| `backend/config/packages/doctrine.yaml` | nuevo | Configuración de Doctrine DBAL + ORM generada por Flex; mapeo de entidades en `src/Entity/` |
| `backend/config/packages/doctrine_migrations.yaml` | nuevo | Configuración de migraciones; directorio `migrations/` como `App\Migrations` |
| `backend/.env` | modificado | Agrega bloque `DATABASE_URL` con placeholder (valor real llega del root `.env` vía Docker) |
| `docker-compose.override.yml` | modificado | Agrega mount `./backend/migrations:/app/migrations` para dev hot-reload de migraciones |
| `.env` (raíz) | modificado | Corrige contraseña en `DATABASE_URL` y `BACKEND_DATABASE_URL`: `password` → `your_db_password` (bug preexistente: la contraseña del volumen Postgres difería de la URL) |

### Justificación

**`pdo_pgsql` no estaba en el Dockerfile original:** el template de symfony-docker no lo incluye porque no asume una base de datos específica. Al adoptar Postgres como base, es obligatorio. Sin él, `PDO` no puede conectarse aunque la extensión `pgsql` esté presente (son dos extensiones distintas).

**`DoctrineMigrationsBundle` no se registró automáticamente:** Symfony Flex intenta escribir en `.env` al instalar recipes, y falla porque el archivo está montado read-only en dev. El lado visible de ese fallo es que algunos bundles no se agregan a `bundles.php`. Solución: registrarlos manualmente.

**`migrations/` no se montaba ni se copiaba:** el directorio existía en el host pero no llegaba al contenedor en dev (no estaba en el override) ni en build (no estaba en el Dockerfile). Resultado: el comando de migraciones fallaba con "not a valid directory". Corregido en ambos lados: mount para dev, COPY para prod.

**Bug de contraseña en root `.env`:** `DATABASE_URL` tenía `password` como contraseña pero el volumen Postgres fue inicializado con `POSTGRES_PASSWORD=your_db_password`. Error silencioso — el backend anterior no usaba `DATABASE_URL` para conectarse a la DB (usaba el healthcheck de FrankenPHP sin ORM). Al instalar Doctrine, el bug se hizo visible. Se corrigió el root `.env`; `backend/.env` actualizado para coherencia.

**Verificación final:** `doctrine:schema:validate` retorna "mapping correct + database in sync". El error "no registered migrations" de `migrations:migrate` es esperado y correcto (no hay migraciones todavía).

---

## [PASO 0.1] feat: graduate backend from generated boilerplate to versioned app

**Hash:** `59aab7c2513b18e1f6266b7503bbfffc30fafd57`
**Rama:** `release/plan-market-pulse`
**Fecha:** 2026-05-31

### Cambios

| Archivo | Tipo | Descripción |
|---|---|---|
| `backend/src/Kernel.php` | nuevo | Kernel de Symfony extraído del contenedor; ahora vive en git |
| `backend/src/Controller/.gitignore` | nuevo | Placeholder para la carpeta Controller (git no versiona dirs vacíos) |
| `backend/composer.json` | nuevo | Dependencias de la app; antes solo existía dentro de la imagen Docker |
| `backend/composer.lock` | nuevo | Lock file de Composer; garantiza reproducibilidad de dependencias |
| `backend/symfony.lock` | nuevo | Lock de recipes de Symfony Flex |
| `backend/bin/console` | nuevo | Entrypoint CLI de Symfony; extraído del contenedor |
| `backend/config/bundles.php` | nuevo | Registro de bundles Symfony habilitados |
| `backend/config/services.yaml` | nuevo | Configuración del contenedor de servicios DI |
| `backend/config/routes.yaml` | nuevo | Definición de rutas de la app |
| `backend/config/preload.php` | nuevo | Preload de OPcache para producción |
| `backend/config/reference.php` | nuevo | Archivo de referencia de configuración de Symfony |
| `backend/config/packages/*.yaml` | nuevo | Configuración de bundles (framework, cache, routing, security, jwt) |
| `backend/config/routes/framework.yaml` | nuevo | Rutas del framework Symfony |
| `backend/config/routes/security.yaml` | nuevo | Rutas del bundle de seguridad |
| `backend/migrations/.gitkeep` | nuevo | Directorio de migraciones Doctrine; vacío por ahora, listo para paso 0.2 |
| `backend/public/live.php` | nuevo | Demo de Mercure (publisher manual); preservado del branch `feat/interactive-demo` |
| `backend/.env` | nuevo | Variables de entorno de Symfony con **placeholders** (secretos reales vienen del `env_file` Docker) |
| `backend/.gitignore` | modificado | Eliminado `./config/packages` (bloqueaba commitear yamls de config); agregados `var/`, `.env.local`, `.env.local.php` |
| `backend/Dockerfile` | modificado | Eliminado bloque `composer create-project`; reemplazado por `COPY composer.*/symfony.lock` + `composer install` + `COPY src/config/bin/public` + `dump-autoload`; eliminados ARGs `SYMFONY_VERSION`/`STABILITY` que ya no se usan |
| `backend/frankenphp/docker-entrypoint.sh` | modificado | Eliminado bloque "install first time" (el propio comentario del archivo lo marcaba como temporal); conservado: generación de JWT keys si no existen, espera de DB, ejecución de migraciones |
| `docker-compose.yml` | modificado | Eliminados `build.args` `SYMFONY_VERSION` y `STABILITY` del servicio backend (el Dockerfile ya no los necesita) |
| `docker-compose.override.yml` | modificado | Agregado mount `./backend/.env:/app/.env:ro`; Symfony necesita el archivo físico en `/app/.env` en dev (el `env_file` de Compose solo inyecta variables de entorno, no crea el archivo) |
| `.gitignore` (raíz) | modificado | Agregada excepción `!backend/.env`; la regla `.env` del root bloqueaba commitear el `.env` de Symfony que sí debe versionarse (tiene solo placeholders, no secretos) |
| `CLAUDE.md` | nuevo | Contexto del proyecto para el agente: stack, comandos, estado actual, decisiones cerradas, referencia al plan |
| `PLAN-MARKET-PULSE.md` | nuevo | Runbook ejecutable completo: arquitectura, decisiones, fases 0–4, convenciones de ejecución, checklist de producción |
| `frontend/src/js/live.js` | nuevo | Módulo JS del demo de Mercure (canvas colaborativo); preservado del branch `feat/interactive-demo` |

### Justificación

**Problema central:** la codebase usaba el patrón del template `symfony-docker` donde el skeleton de Symfony se genera en tiempo de `docker build` con `composer create-project`. Esto es aceptable para aprender DevOps (el objetivo original), pero incompatible con construir una app real: el código de dominio solo existe dentro de la imagen, se destruye en cada rebuild limpio, no se puede versionar ni testear en CI.

**Decisión tomada:** extraer el skeleton generado del contenedor en ejecución (no regenerarlo) y comitearlo. Esto evita divergencias: el código que corre en producción es exactamente el código en git.

**Por qué no regenerar con `create-project`:** el skeleton ya tiene configuraciones específicas del proyecto (JWT configurado, rutas de seguridad, etc.) que `create-project` generaría en blanco. Regenerar implicaría reconfigurar todo desde cero.

**`backend/.env` con placeholders vs. secretos reales:** el `.env` de Symfony por convención se versiona con valores de ejemplo/placeholder. Los valores reales (JWT_PASSPHRASE, APP_SECRET) vienen del `env_file` del root (`/.env.backend`) que Docker inyecta en tiempo de ejecución como variables de entorno — estas tienen mayor precedencia que el `.env` de la app. Así se mantiene la convención Symfony sin exponer secretos en el repo.

**Mount del `.env` en dev:** el `env_file` de Docker Compose inyecta variables de entorno al proceso, pero no crea un archivo en disco. Symfony intenta leer `/app/.env` como archivo físico en modo dev. Sin el mount, `bin/console` falla con `PathException`. En producción esto no ocurre porque `composer dump-env prod` genera `.env.local.php` (binario compilado) que toma precedencia sobre `.env`.

**Preservación del demo de Mercure:** `live.php` y `live.js` son prueba viva de que el hub Mercure funciona end-to-end. Se preservan como activo de la codebase (documentado en §1 del plan).
