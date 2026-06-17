# Epic B — Modelo de upgrade de forks

> **Estado:** 🟡 en análisis · **Versión destino:** v1.1 (slice inicial) ·
> **Origen:** `v1/optional-services.md` §5, item 3 + sesión de diseño 2026-06.

## Problema

Una app que forkeó Oliva **no recibe automáticamente** los cambios del
framework. Hoy Oliva y cada fork son repos independientes cuyas historias
**divergieron** desde un ancestro común. "Pullear v2" = mergear dos historias
divergidas = conflictos en archivos compartidos + heredar meta-archivos del
framework (su README, sus docs de planificación) que no son del fork.

## Análisis: por qué pasa (no es un bug)

Hay dos modelos de consumo de un "framework base":

| Modelo | Cómo se consume | Upgrade |
|---|---|---|
| **Dependencia** (Symfony-los-paquetes, React) | `vendor/`, version constraint; el source nunca está en tu historia | Bumpeás versión, `update`, arreglás *tu* código en los seams documentados. El framework se reemplaza atómico. **Sin merge de historias.** |
| **Fork / boilerplate** (Oliva hoy, `rails new`, create-next-app, cookiecutter) | clonás y construís encima, en una sola historia | `git merge` de historias divergidas, conflictos en archivos compartidos |

**Oliva es un boilerplate/skeleton, no una librería.** Para esa capa, "scaffold
and own" (generás una vez, después es tuyo) es el estándar — los templates de
GitHub a propósito no mantienen link con upstream. Así que la fricción del
upgrade manual es el comportamiento *de diseño* del patrón, no un error.

> Matiz importante: que el upgrade cueste trabajo manual es **universal** (subir
> Symfony 6→7 también). Lo que cambia entre modelos es la **naturaleza** del
> trabajo: editar solo tu código en seams documentados (dependencia) vs. resolver
> conflictos de merge en archivos del framework (fork).

## Dónde sí hay olor a diseño

Oliva mezcla **tres tipos de contenido en una sola historia**:

1. Infra reutilizable (compose, Dockerfiles, Caddy) ← lo que *sí* querés actualizar.
2. Meta-docs del framework (README, docs de roadmap, CLAUDE.md) ← narrativa de Oliva.
3. Código de ejemplo/scaffold (docs/examples, demo live) ← se borra o reemplaza.

Como están entremezclados, **cada commit upstream toca una mezcla** → ningún
pull es limpio.

## Dirección (de menor a mayor esfuerzo)

1. **Tags / releases en Oliva** _(hecho parcial: tag `v1.0`)_. Da trazabilidad:
   "esta app está en Oliva v1.0", `git diff v1.0 v2.0` para ver qué portar.
   **Mejora la legibilidad del port, no la limpieza del merge.**
2. **Separar archivos framework vs app en el fork.** Rama espejo limpia de
   upstream; no customizar meta-archivos del framework en el fork → los merges
   tocan archivos disjuntos.
3. **Extraer la infra reutilizable a un artefacto versionado** (imagen base /
   compose `include` / mini-scaffolder). Único camino al "bumpeo una versión y
   sigo". Trabajo real; se paga **recién con varias apps**. Converge con el Eje A.

## Slices candidatos

- [x] Tags de release en Oliva (`v1.0`). _(v1.1)_
- [ ] Documentar el workflow de port fork↔upstream (remote `oliva-upstream`,
      cherry-pick selectivo vs. port a mano, cuándo cada uno). _(v1.1)_
- [ ] Convención: qué archivos del framework NO customizar en un fork. _(v1.1)_
- [ ] (mayor) Extraer infra a artefacto versionado → converge con Eje A / v2.0.

> **Límite duro (heredado del runbook de deploy):** NO construir un sistema de
> sincronización fork↔upstream ahora. El slice de v1.1 es **documentar el
> workflow + tags**, no automatizarlo. La automatización/extracción es v2.0.
