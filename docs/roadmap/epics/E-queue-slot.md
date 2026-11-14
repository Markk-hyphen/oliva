# Epic — The queue slot, complete: a production worker and a guard for the forgotten profile

> **Status:** 📋 designed, not started (branch `feat/queue-slot`) ·
> **Target version:** v1.7.0 ·
> **Origin:** framework review, 2026-11-14. Follows `E-config-contract.md`.

## Problem

A queue is two things: a broker and something that consumes from it. Oliva ships the
broker in every environment and the consumer only in development.

Measured on the prod stack with both profiles on
(`docker compose -f docker-compose.yml -f docker-compose.prod.yml --profile queues --profile cron config --services`):

```
database scheduler backend frontend rabbitmq
```

No `worker`. An app that dispatches to an async transport in production gets a
`202`-style success on every request while its messages pile up in RabbitMQ and
nothing ever handles them. No error, no log line, green `verify`, green CI. By
Oliva's own rule that is a bug in Oliva.

It is not theoretical: one app declares `COMPOSE_PROFILES=queues,cron` and routes
two message classes to `ingest`/`enrich`; another chose not to use queues at all to
stay clear of this.

Four separate gaps:

| Gap | Where |
|---|---|
| No worker outside dev | `worker` exists only in `docker-compose.override.yml` |
| The transports are hardcoded to the example names | its command is `messenger:consume ingest enrich`; an app with other transports must edit the file, and can't for prod (the prod file is Oliva's) |
| Nothing notices the profile is off | the README says so: "There's no equivalent guard for `queues` yet" (`cron` has one) |
| The dev worker runs migrations | its command starts with `bin/console`, which enters the entrypoint's setup block (JWT keys, wait-for-db, `migrate`) at the same time as the backend |

## Design

### The worker becomes a service of the base stack

`worker` moves to `docker-compose.yml`, behind the `queues` profile, built from the
backend image like `scheduler`. Each overlay only adjusts it:

| File | What it sets for `worker` |
|---|---|
| `docker-compose.yml` | the service: profile `queues`, backend image, the consume command, `depends_on` backend (healthy) and rabbitmq (healthy) |
| `docker-compose.override.yml` | dev image/target, source mounts, `-vv` |
| `docker-compose.prod.yml` | `:prod` image, `APP_ENV=prod`, `restart: unless-stopped` |
| `docker-compose.staging.yml` | `:staging` image, `APP_ENV=staging`, the staging `env_file` |
| `docker-compose.shared-infra.yml` | `data_net`; `depends_on` reduced to `backend` (the broker is external) |

`depends_on: backend (service_healthy)` is what replaces running the setup block in
the worker: the backend migrates at boot and is healthy only after, so the worker
starts on a migrated schema without migrating itself. The entrypoint stops treating a
`messenger:consume` command as a reason to run setup.

### Consume everything by default

Verified on the pinned Symfony (7.4.21): `messenger:consume` has `--all` and
`--exclude-receivers` (only valid with `--all`).

Default command:

```
bin/console messenger:consume --all --exclude-receivers=failed --time-limit=3600 --memory-limit=128M
```

- An app that adds a transport gets it consumed with no change anywhere: the default
  asks for nothing.
- `failed` is excluded: consuming the failure transport in the same loop retries a
  poison message forever, with no delay.
- `--time-limit` and `--memory-limit` recycle the process; `restart: unless-stopped`
  brings it back. Same idea as `FRANKENPHP_LOOP_MAX` for the HTTP workers.

An app that needs something else (priorities, one worker per transport) sets
`WORKER_CONSUME_ARGS` in `.env.backend` (non-secret, tracked) and, for more than one
worker, adds services in its own override. To decide in phase 1: whether the variable
is worth having on day one or only when an app asks for it.

### The guard: queues used, nothing consuming

Same shape as `cron-guard.sh`: static evidence that the app uses queues, checked
against what Compose will actually start.

- Evidence: an uncommented entry under `routing:` in
  `backend/config/packages/messenger.yaml`, or an `#[AsMessage(` attribute in
  `backend/src`.
- State: is `worker` in `docker compose … config --services` for this stack?
- If there is evidence and no worker: a loud message with the fix
  (`COMPOSE_PROFILES=queues` in this machine's `.env`).

Registered as an upgrade guard (`queues`), so it runs in `verify` and after every
deploy, and warns. It costs nothing when the app routes no message.

To decide in phase 3: whether a production deploy should **abort** on it, like the env
check. Unlike a public secret, the damage is recoverable (messages wait in the
broker), which argues for a warning.

### Tie-in with the config contract

`env check` already treats `queue` as a slot (active when `rabbitmq` runs, replaced
when `RABBITMQ_DSN` points elsewhere). Known limit to fix here: in shared infra the
shared broker is also called `rabbitmq`, so a replaced queue looks absent. With the
worker in the stack, "the worker runs but no `rabbitmq` service does" identifies the
replaced case.

### CI and verify

- `prod-config` job: with `--profile queues`, the prod stack resolves a `worker`
  whose `APP_ENV` is `prod` and whose command consumes. Structural, no build.
- `verify`: when `queues` is active, `up --wait` already requires a healthy worker.
  A real round trip (dispatch → consumed) needs a message class Oliva doesn't ship;
  decide in phase 2 whether a tiny built-in ping message is worth it.
- Naming trap to avoid: `verify` already has a step `prod-worker`, which is about
  FrankenPHP **worker mode**, not this worker. New names say `queue`.

## Phases

1. **Worker in the base stack + prod + entrypoint.** *Gate:* prod `config --services`
   with `queues` lists `worker`; in a running prod stack a dispatched message is
   handled; the worker does not run migrations.
2. **Staging and shared-infra overlays.** *Gate:* both resolve a worker on the right
   image, env and networks; a deploy on the temporary shared-infra setup (as in
   1.6.0) brings it up.
3. **The `queues` guard** in `verify` and `deploy*.sh`. *Gate:* routing present and
   profile off → loud; no routing → silent; profile on → silent.
4. **CI + docs + release 1.7.0.** README "Known gap" removed, slots table in the
   roadmap updated, `UPGRADING.md` section (apps drop the `worker` block from their
   override or keep only their additions).

## Out of scope

- **Autoscaling or several workers by default.** One worker; an app adds more.
- **Replacing RabbitMQ** (Redis, Doctrine transport). A backend-tied slot; the
  replacer changes `messenger.yaml` and takes the cost.
- **A dashboard or alerting on queue depth.**
- **Install flags.** Still roadmap item 3.
