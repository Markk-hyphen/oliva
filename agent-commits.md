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
