# Epic C — Worker de producción

> **Estado:** 💡 idea · **Versión destino:** v1.2 · **Origen:**
> `v1/optional-services.md` §5, item 2 + deuda conocida en `CLAUDE.md` / `README.md`.

## Problema

`docker-compose.override.yml` (dev) define `worker` con
`bin/console messenger:consume`, pero **no hay equivalente en producción**
(`docker-compose.prod.yml` ni el `docker-compose.yml` base). Si una app usa
RabbitMQ/Messenger en serio, hoy llega a prod sin worker.

`scheduler` sí está cubierto en prod (usa `app-backend-prod:1.0` / target
`frankenphp_prod`, igual que `backend`). El `worker` quedó como deuda.

## Visión

Definir un servicio `worker` de producción, detrás del profile `queues` (para
que solo exista cuando la app usa colas), consistente con cómo está resuelto
`scheduler`:

- imagen `app-backend-prod:1.0`, target `frankenphp_prod`
- comando `messenger:consume` (con `--time-limit` y restart)
- sin puertos expuestos
- `profiles: ["queues"]`

## Slices candidatos

- [ ] Bloque `worker` en `docker-compose.prod.yml` (profile `queues`).
- [ ] Verificar que `COMPOSE_PROFILES=queues` lo levante en prod y que vacío no.
- [ ] Documentar en README (tabla de perfiles) que `queues` ahora cubre prod.
- [ ] Quitar la nota de "deuda conocida" de `CLAUDE.md` / `README.md` al cerrarlo.

> **Scope guard:** es chico y acotado. No mezclar con el Eje A. No aplica a apps
> que no usan Messenger (ej. finanzas-ong), por eso vive detrás del profile.
