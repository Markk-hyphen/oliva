# oliva

Webapp con backend Symfony (FrankenPHP), frontend Vite, y base de datos PostgreSQL. Todo orquestado con Docker Compose.

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
- `backend/` — Symfony con FrankenPHP
- `frontend/` — Vite (Node)
- `.env`, `.env.backend`, `.env.frontend` — variables por entorno
- `.env.prod` — variables de producción

## Variables de entorno
Las variables se definen en `.env` (compartidas), `.env.backend` y `.env.frontend`. Ver `.env.example` como referencia.

## Estado actual vs. proyecto en curso
El backend está **graduado de boilerplate a app versionada** (paso 0.1 completado: `backend/src/`, `composer.json/lock`, `symfony.lock` en git; Dockerfile usa `composer install` sobre el repo). Mercure **sí funciona** (hub activo en `backend/frankenphp/Caddyfile`; demo de canvas en `public/live.php` + `frontend/src/js/live.js`).

Se está construyendo **encima** un proyecto-vidriera: **"Crypto Pulse"** — plataforma de inteligencia de mercado cripto en tiempo real (ingesta de fuentes públicas → enriquecimiento con IA → dashboard en vivo vía Mercure). El headline es **DevOps × IA**; cripto es el dominio de datos, no el producto.

- **Plan completo y runbook ejecutable:** `PLAN-MARKET-PULSE.md` (leer §11 "convenciones de ejecución" antes de implementar).
- **Log de commits del agente:** `agent-commits.md` (detalle de cada cambio con justificación).
- **Glosario de conceptos técnicos:** `concepts.md` (explicaciones teóricas agregadas a pedido).
- **Rama de trabajo:** `release/plan-market-pulse` (no tocar `main`).
- **Decisiones cerradas:** broker **RabbitMQ**, scheduler **contenedor cron (supercronic)**, LLM **Anthropic** (Haiku volumen / Sonnet agregados), vector **pgvector**, dominio **cripto** (RSS CoinDesk/Cointelegraph + CoinGecko; CryptoPanic en Fase 2).
- **Próximo paso:** 1.5 — Publish a Mercure (al persistir Enrichment, publicar el item enriquecido al topic `crypto/feed` con `HubInterface`).
- **Modelo:** planificado con Opus; **ejecutar con Sonnet** (Haiku solo para pasos mecánicos).

## Deuda conocida antes de 1.5 (revisión de sanidad, 2026-06-01)

Hallazgos de una revisión de lo hecho en pasos 1.1–1.4. Atender los 🔴/🟡 antes o durante 1.5.

- 🔴 **Falta el mock de `EnrichmentProvider` en dev (viola §11.6 del plan).** `config/services.yaml` cablea `AnthropicEnrichmentProvider` como default en *todos* los entornos. Hoy solo estás protegido por accidente (la key placeholder da 401). Con una key real, el scheduler (`*/5`) gastaría en cada item de cada poll. **Fix:** `NullEnrichmentProvider` (resultado fijo, costo 0) aliaseado por default en `config/services_dev.yaml`; Anthropic solo en prod o detrás de un flag (`ENRICHMENT_PROVIDER`).
- 🟡 **El prompt caching de Anthropic es un no-op.** El system prompt (~250 tokens) está por debajo del mínimo cacheable de Haiku (2048 tokens) → `cache_control: ephemeral` se ignora; no hay ahorro. El header beta `prompt-caching-2024-07-31` ya es innecesario (GA). El control de costo "(c)" del plan **no está activo**; el ahorro real lo da la capa Symfony Cache por `contentHash`.
- 🟢 **Dual-write DB↔broker → items huérfanos en `pending`.** Si el broker falla tras el `flush()` de ingesta, queda un `NewsItem(pending)` sin mensaje de enrich. Mitigado por `app:enrich:requeue-pending`. Para 1.8: correrlo periódico o documentarlo como recovery path.
- 🟢 **`contentHash` es un hash de la URL**, no del contenido (`hash('sha256', $raw['url'])`). Dedup por URL es razonable, pero el nombre engaña: ediciones de título/cuerpo no re-ingestan. Renombrar o hashear título+body si se quiere detectar ediciones.
- 🟢 **`RssAdapter` asume RSS 2.0** (`channel->item`): un feed Atom devuelve vacío en silencio; sin header `User-Agent`. Para el paso 1.8 (robustez).
- 🟢 **Gap de re-embedding:** items enriquecidos sin key de Voyage quedan con `embedding=null` permanente (requeue saltea los `enriched`). La búsqueda semántica (2.2) los ignora. Hará falta un comando de re-embed o un estado intermedio antes de Fase 2.

## Chequeos de sanidad (inicio y cierre de sesión)

Correr al **inicio** de cada sesión antes de tocar código:

```bash
git branch --show-current          # debe ser release/plan-market-pulse
git status -s                      # debe estar limpio (o saber qué hay pendiente)
git log --oneline -3               # orientarse en dónde quedó la sesión anterior
docker compose ps                  # todos los servicios healthy
docker compose exec backend bin/console doctrine:migrations:status  # sin migraciones pendientes
```

Verificar al **cierre** de sesión antes de cortar:

```bash
git status -s                      # sin archivos sin commitear (salvo intencional)
git log --oneline -3               # el último commit tiene hash real en agent-commits.md
```

Y en `CLAUDE.md` asegurarse de que **"Próximo paso"** apunte al paso correcto para la sesión siguiente.

## Protocolo de explicaciones conceptuales

Cuando el usuario pide que se le explique un concepto (`"explicame X"`, `"enseñame X"`), el agente debe:
1. Agregar la explicación al **final** de `concepts.md` como una nueva sección `## NombreDelConcepto`.
2. Commitear `concepts.md` junto con el trabajo del paso en curso (o en un commit separado si el usuario lo pide).
3. No repetir explicaciones ya presentes en el archivo — si el concepto ya está, referenciarlo.

El archivo `concepts.md` es acumulativo: nunca se borra contenido, solo se agrega.

---

## Protocolo de commits del agente

**Cada commit que realice el agente debe registrarse en `agent-commits.md`** antes o junto con el commit de git. El registro es parte del entregable, no opcional.

### Formato obligatorio

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
- `agent-commits.md` se agrega al staging junto con los demás archivos del paso.
