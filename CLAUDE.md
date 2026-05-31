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
**La codebase Oliva es hoy un boilerplate** (Symfony se genera en build vía `composer create-project`; `backend/src/` está vacío y `composer.json` no está versionado). Mercure **sí funciona** (hub activo en `backend/frankenphp/Caddyfile`; demo de canvas en `public/live.php` + `frontend/src/js/live.js`).

Se está construyendo **encima** un proyecto-vidriera: **"Crypto Pulse"** — plataforma de inteligencia de mercado cripto en tiempo real (ingesta de fuentes públicas → enriquecimiento con IA → dashboard en vivo vía Mercure). El headline es **DevOps × IA**; cripto es el dominio de datos, no el producto.

- **Plan completo y runbook ejecutable:** `PLAN-MARKET-PULSE.md` (leer §11 "convenciones de ejecución" antes de implementar).
- **Rama de trabajo:** `release/plan-market-pulse` (no tocar `main`).
- **Decisiones cerradas:** broker **RabbitMQ**, scheduler **contenedor cron (supercronic)**, LLM **Anthropic** (Haiku volumen / Sonnet agregados), vector **pgvector**, dominio **cripto** (RSS CoinDesk/Cointelegraph + CoinGecko; CryptoPanic en Fase 2).
- **Primer paso estructural:** versionar `backend/src/` y quitar `create-project` del Dockerfile (§3.1 / paso 0.1 del plan).
- **Modelo:** planificado con Opus; **ejecutar con Sonnet** (Haiku solo para pasos mecánicos).
