# Epic — The queue slot, complete: a production worker and a guard for the forgotten profile

> **Status:** 🔨 in progress (branch `feat/queue-slot`) ·
> **Target version:** v1.8.0 (1.7.0 shipped without it) ·
> **Origin:** framework review, 2026-11-14. Follows `E-config-contract.md`. Re-checked
> against `main` on 2026-11-17, before any code: see "Findings of the re-check".

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

## Findings of the re-check (2026-11-17)

Every claim above still holds on `main` (checked live: the dev worker waits for the
database and runs `migrate` next to the backend; `--all --exclude-receivers=failed`
consumes `ingest, enrich` and exits 0 on Symfony 7.4.23). Four things the first design
missed:

- **The image healthcheck is wrong for every non-HTTP container.** The backend image
  bakes `HEALTHCHECK curl localhost:2019/metrics`. A container of that image that runs
  supercronic or `messenger:consume` has no FrankenPHP, so the check always fails (exit 7,
  measured). The production `scheduler` is `unhealthy` today and nothing says so: the
  deploy does not `--wait`. Copying the scheduler's pattern would give the worker the same
  bug. Fixed in phase 1 for both.
- **There is no legitimate way to have a production worker today.** The README tells an app
  to "add one to `docker-compose.prod.yml`", a file Oliva owns. An app has no compose file
  of its own that loads in production, so `WORKER_CONSUME_ARGS` is the only lever an app
  has over the production command.
- **The guards run after `up`.** In `deploy.sh` the env check runs before `down` (and can
  abort with the old stack still serving); `run_upgrade_guards` runs after `up`, when
  nothing can be stopped any more.
- **"Recoverable" was true of the data, not of the effect.** With `queues` off: standalone
  has no broker either (same profile), so every dispatch throws and the user's action is
  lost; shared infra keeps a broker up, so messages pile up silently. They are processed
  once a worker starts only if someone acts, the queues are durable, nothing expires, and
  a late effect is still wanted (a verification mail three days late, a charge, a timed
  job). Shared infra is also the only stack `deploy.sh` knows how to deploy.

Found during phase 2, on a local shared-infra setup with the real deploy scripts:

- **A worker consumes whatever its vhost holds, and nothing kept environments or apps
  apart.** `.env.staging.example` separates the database but inherits production's
  `RABBITMQ_DSN`. Measured: with production's worker stopped, a message dispatched by
  production was handled by the **staging** worker, against the staging database. Every app
  inherits the same queue names from Oliva, so two apps on the default vhost `/` of the
  shared broker do the same to each other. It was latent while no production worker
  existed; this epic would have made it live. The infra already has the tool
  (`provision-rabbitmq.sh`, one vhost per app); Oliva's runbook never mentioned it. With a
  vhost of its own, staging left production's message alone (measured).

### Decisions (2026-11-17)

| Question | Decision |
|---|---|
| Healthcheck | A healthcheck of their own for `worker` **and** `scheduler`, in the base file |
| `WORKER_CONSUME_ARGS` | From day one; empty means the default command |
| The guard in a deploy | **Abort before `down`**, only when a routed transport is asynchronous, with a declared exception for a consumer that lives outside the stack |
| Round trip | Proven once, during implementation, on a scratch copy (`RunCommandMessage`: Symfony ships the handler). `verify` and CI stay structural |
| Queue isolation | Template and runbook ask for a vhost per app and per environment; the deploys **abort before `down`** when staging resolves production's broker and vhost, or when a shared-infra worker would run on `/`. Same declared exception |

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

An app that needs something else (priorities, one set of transports) sets
`WORKER_CONSUME_ARGS` in `.env.backend` (non-secret, tracked): it replaces the
arguments after `messenger:consume`. Empty or unset means the default above. More than
one worker is out of scope (no app-owned compose file loads in production).

### Healthcheck

`worker` and `scheduler` get a healthcheck of their own in `docker-compose.yml`, so every
overlay inherits it instead of the image's HTTP check. PID 1 is the long-running command
itself (the entrypoint `exec`s it), so "PID 1 is alive" is the honest minimum.

### The guard: queues used, nothing consuming

Same shape as `cron-guard.sh`: static evidence that the app uses queues, checked
against what Compose will actually start.

- Evidence: an uncommented entry under `routing:` in
  `backend/config/packages/messenger.yaml` (or `#[AsMessage(` in `backend/src`) whose
  transport is **asynchronous**. A routing to a `sync://` or `in-memory://` transport needs
  no worker and is not evidence.
- State: is `worker` in `docker compose … config --services` for this stack?
- Declared exception: `OLIVA_QUEUE_CONSUMER=external` in this machine's `.env` says the
  messages are consumed outside this stack (another service or host on the shared broker).
  It is a replaced slot, so it is loud: `doctor` and the deploy print that consumption is
  outside Oliva's net.
- If there is evidence, no worker and no declaration: the fix is named
  (`COMPOSE_PROFILES=queues` in this machine's `.env`).

Where it acts:

| Where | What it does |
|---|---|
| `deploy.sh`, `deploy-staging.sh` | **aborts before `down`**, next to the env check: the running stack keeps serving |
| `verify` | step `queue`: red |
| `doctor` | shows it, and shows the declared exception |

It costs nothing when the app routes no message.

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
  The round trip (dispatch → consumed) is proven once during implementation, not in
  `verify`: it would need a dispatch entry point in every app's backend.
- Naming trap to avoid: `verify` already has a step `prod-worker`, which is about
  FrankenPHP **worker mode**, not this worker. New names say `queue`.

## Phases

1. **Worker in the base stack + prod + entrypoint + healthchecks + `WORKER_CONSUME_ARGS`.**
   *Gate:* prod `config --services` with `queues` lists `worker`; in a running prod stack a
   dispatched message is handled; the worker does not run migrations; `worker` and
   `scheduler` are `healthy` in prod.
2. **Staging and shared-infra overlays.** *Gate:* both resolve a worker on the right
   image, env and networks; a local shared-infra setup (external networks and a broker
   of its own; there is no VPS) brings it up.
3. **The `queue` guards** in `deploy*.sh` (before `down`), `verify` and `doctor`. *Gate:*
   async routing and profile off → deploy aborts with the old stack up, `verify` red;
   sync-only routing → silent; no routing → silent; profile on → silent; declared
   external consumer → passes, and says so; staging on production's vhost → aborts;
   shared-infra worker on `/` → aborts; each with its own vhost → passes.
4. **CI + docs + release 1.8.0.** README "Known gap" removed, slots table in the
   roadmap updated, `UPGRADING.md` section (apps drop the `worker` block from their
   override or keep only their additions).

## Out of scope

- **Autoscaling or several workers by default.** One worker; an app adds more.
- **Replacing RabbitMQ** (Redis, Doctrine transport). A backend-tied slot; the
  replacer changes `messenger.yaml` and takes the cost.
- **A dashboard or alerting on queue depth.**
- **Install flags.** Still roadmap item 3.
