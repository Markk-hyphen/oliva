# Epic E — Seeding layer (staging)

> **Estado:** 🟡 parcial (tooling listo, falta el modelo de infra de staging) ·
> **Versión destino:** v1.1 · **Origen:**
> necesidad surgida en finanzas-ong (poblar staging con datos representativos sin SQL crudo).

## Problema

Oliva no tenía seeding de primera clase. Poblar la base en staging requería SQL
crudo a mano o scripts ad-hoc (`seed.sh` local). Sin una capa de factories,
los forks no pueden generar datos de prueba reproducibles ni testear flujos
post-deploy de forma consistente.

## Visión

Equivalente Symfony del par `seeders + factories` de Laravel: datos falsos pero
representativos, reproducibles, segregados por grupo (`staging` / `dev`), con
**guard estructural** contra seedear producción accidentalmente.

El guard no es una convención — es estructural: la imagen prod se compila con
`--no-dev`, así que el comando `doctrine:fixtures:load` directamente no existe en
la imagen prod.

## Stack agregado

| Paquete | Rol |
|---|---|
| `zenstruck/foundry` | Factories tipadas con estados y relaciones fluidas (trae FakerPHP) |
| `doctrine/doctrine-fixtures-bundle` | Runner (`doctrine:fixtures:load --group=`) |

Ambos como `require-dev` — no entran en la imagen prod.

## Target Docker `frankenphp_staging`

Multi-stage build: `frankenphp_staging` hereda de `frankenphp_prod` (no dev).
Staging = prod + tooling de seeding. Mantiene representatividad del entorno; si
divergiera de prod, dejaría de testear lo que realmente corre.

```
frankenphp_base
  ├── frankenphp_dev   (dev)
  ├── frankenphp_prod  (producción)
  └── frankenphp_staging  ← hereda de prod, suma --dev deps
```

## Slices entregados

- [x] `composer require --dev zenstruck/foundry doctrine/doctrine-fixtures-bundle`
- [x] `AppFixtures` con grupos `staging` / `dev` y comentarios para forks
- [x] `AppStory` como punto de entrada de escenarios Foundry
- [x] Target `frankenphp_staging` en el Dockerfile
- [x] Paso opt-in en el runbook de deploy del `CLAUDE.md`
- [x] Comando documentado en `.env.example`
- [x] Sección Foundry en `docs/concepts.md`

## Deuda crítica — el modelo de infra de staging (PENDIENTE)

> Detectado en el checkpoint del 2026-06-27, post-merge. **Riesgo de pérdida de
> datos productivos** si se sigue el runbook tal como quedó en la primera versión.

`doctrine:fixtures:load` **purga la base antes de cargar** (DELETE/TRUNCATE de
todas las tablas gestionadas, salvo `--append`). El guard estructural de la imagen
prod (`--no-dev`, sin el comando) **no alcanza**: el propio paso 11 del runbook te
hace buildear la imagen `frankenphp_staging` que SÍ tiene el comando, y en infra
compartida el container apunta al Postgres central vía el `DATABASE_URL` **de
producción**. Resultado: seedear "staging" purgaría la base productiva.

La raíz del problema: tratamos "staging" como un *modo de la app de prod* (misma
DB, mismo deploy) cuando debe ser **una app separada a nivel infra**, con su propia
DB desechable — igual que cualquier otra app en la infra compartida.

**Diseño pendiente (no implementado):**

- DB de staging propia: `provision-postgres.sh <app>_staging_db <app>_staging_user`.
- Project name propio: `-p <app>-staging` (red privada propia, sin colisión DNS).
- `DATABASE_URL` de staging apuntando a esa DB, nunca al `<app>_db` de prod.
- Decidir si va un overlay `docker-compose.staging.yml` (target `frankenphp_staging`
  + `.env.staging`) o se parametriza el de shared-infra. **Decisión abierta.**
- El seeding corre SOLO en ese stack de staging; la DB es desechable, la purga es inocua.

Hasta que esto esté, el paso 11 del runbook lleva una advertencia de PELIGRO y el
seeding **no debe correrse en infra compartida** contra la DB de una app productiva.

## Cómo extiende un fork

1. `bin/console make:factory` para cada entidad (o a mano en `src/Factory/`).
2. Llamar las factories en `AppFixtures::load()` o en `AppStory::build()`.
3. El target `frankenphp_staging` ya existe: solo necesita `docker compose build --target frankenphp_staging`.
4. **Antes de seedear en infra compartida:** resolver la "Deuda crítica" de arriba —
   staging necesita su propia DB, no la de producción.

## Por qué es un hito de framework

El target `frankenphp_staging` introduce **multi-stage build con herencia semántica**
en Oliva: cada stage tiene un propósito explícito (dev / prod / staging) y la imagen
de staging reutiliza prod sin divergir. Es el patrón Docker recomendado para tooling
de testing post-deploy y escala para sumar más tools (ej. API collection) sin tocar prod.
