# Backlog — ideas sin asignar

Embudo de ideas para Oliva que todavía **no** están asignadas a una versión ni
maduraron en un epic. Cuando una idea crece, se promueve a `epics/` y/o se
asigna a una `versions/vX.Y.md`; cuando se descarta, se mueve a "Descartadas"
con el motivo.

> Mantener barato: una línea por idea. El detalle vive en el epic, no acá.

## Formato

```
- [ ] <título corto> — <una línea de qué/por qué>. (origen: <de dónde salió>)
```

## Ideas

- [ ] **Modos de configuración del instalador** — capa sobre el Eje A (flags en
  instalación). En vez de solo preguntar servicio por servicio, ofrecer tres
  modos: (a) **config avanzada** = elegir servicio por servicio; (b)
  **pre-configs** = sets predefinidos (ej. "Fullstack app chica" sin RabbitMQ,
  "Stack IA", etc.); (c) **config automática** = una serie de preguntas infiere
  el stack. La automática usa primero un **filtro determinista** (mapear
  respuestas a un stack sin gastar tokens) y solo escala a una request a un LLM
  si el input queda demasiado inconcluso. Candidato a **v2.1** (upgrade del
  sistema de instalación de v2.0). Depende de `epics/A-install-time-flags.md`.
  (origen: sesión 2026-06)

- [ ] **Manejo de secretos** — promovido a `epics/D-secret-management.md`. La
  credencial de la DB está duplicada (`DATABASE_URL` vs `POSTGRES_*`) y todos los
  secretos del backend están en texto plano versionado. Opciones de fondo (Symfony
  Secrets vault / Docker secrets) vs tactical (derivar `DATABASE_URL`); decisión
  diferida hasta que haya disparador (colaborador, CI con secretos, rotación).
  (origen: sesión 2026-06, fix `DATABASE_URL` → `.env.backend`)

## Descartadas

_(nada todavía)_
