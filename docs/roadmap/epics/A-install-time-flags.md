# Epic A — Flags en instalación / scaffolding

> **Estado:** 💡 idea · **Versión destino:** v2.0 (major) · **Origen:**
> `v1/optional-services.md` §5, item 1.

## Problema

Hoy forkear Oliva hereda **todo** el stack y se apaga lo que no se usa con
Compose profiles (la palanca de v1.0). Los profiles son el **puente**, no el
destino: el fork igual arrastra los bloques de servicios que no usa en su
`docker-compose.yml`, sus variables en `.env.example`, su doc, etc.

## Visión

Que **instalar/forkear Oliva pregunte** (o lea un manifiesto) qué servicios
incluir, y genere un fork con **solo** esos servicios cableados — en vez de
heredar todo y togglear.

```
$ create-oliva-app miapp
? ¿Colas async (RabbitMQ + worker)?      (y/N)
? ¿Búsqueda / cache / ...?               (y/N)
→ genera miapp/ con solo lo elegido
```

## Por qué es un major (v2.0)

Cambia **cómo se consume Oliva**: deja de ser un fork monolítico que se poda, y
pasa a ser un *generador/scaffolder*. Eso reescribe la experiencia de
instalación y se relaciona con el Eje B (modelo de upgrade): un Oliva que
genera forks también cambia cómo esos forks reciben mejoras.

## Preguntas abiertas

- ¿CLI generador (cookiecutter-style) vs. template repo + script post-clone?
- ¿Qué es "servicio opcional" elegible? (queues hoy; futuros: cache, search…)
- ¿Cómo convive con el Eje B? Un scaffolder puede emitir un fork que ya separe
  capas framework/app (ver `B-fork-upgrade-model.md`).

## Slices candidatos

- [ ] Definir mecanismo (CLI vs template+script).
- [ ] Inventario de servicios opcionales y sus preguntas.
- [ ] Generación del `docker-compose.yml` / `.env` mínimos por selección.
- [ ] Reemplazar la doc de "apagar con profiles" por "no se instaló".

> **Scope guard:** esto es el major. No empezar a construirlo hasta cerrar v1.1
> y v1.2, y hasta que el disparador (2da app real, o dolor real del modelo
> actual) lo justifique.
