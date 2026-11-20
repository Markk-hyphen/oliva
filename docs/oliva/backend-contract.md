# The backend contract

What any backend in an Oliva app must do, should do, and declares, so that Oliva's
compose files, deploys and checks keep working when the backend is not the default one.
The default backend (Symfony on FrankenPHP, `backend/`) is written to this contract, and
every statement about it below is measured, not intended.

Since 1.12.0. Declaring a replaced backend in an app (`./oliva init --backend=external`,
slot-aware sync and checks) is not there yet: until it is, a replaced backend lives behind
the clauses below on its own, and the limits in "What Oliva cannot see yet" apply.

## Behaviour, not connectivity

A backend that answers on the right port is **not** a backend that honours this contract.
Every value Oliva hands a backend is a connection, and a connection guarantees nothing about
behaviour:

| Oliva gives | It does not guarantee |
|---|---|
| a name on the app network (`backend:80`) the gateway proxies to | that the server is ready, or that `/health` means anything |
| `DATABASE_URL` | that the schema exists, that migrations ran, or that two runs at once are safe |
| `MERCURE_URL` and a key | that updates are published, or published only after the data committed |
| `RABBITMQ_DSN` | that a worker can read what the backend enqueues |
| `SIGTERM` on every deploy | that the process stops, or stops cleanly |

Each clause below closes one of those gaps. The clauses that, unmet, would let a deploy look
fine while something is lost are mandatory.

## The clauses

**Kind.** *Mandatory*: unmet, a deploy or a check fails (Q3 of the backend-slot epic).
*Recommended*: unmet, it warns; the stack works with less. *Declared*: nothing observable
from outside proves it in general; the backend states it, and Oliva verifies it for the
default at every release.

**Check.** The ids `K1`–`K10` are the assertions of the conformance suite
(`./oliva conformance [image]`, run in CI against the default; see "The conformance suite"
below). A backend that wants to know whether it honours this contract runs the suite against
its image.

| Clause | Requirement | Kind | Check |
|---|---|---|---|
| Image | One image, built from `backend/Dockerfile`, with the build targets `dev`, `prod` and `staging`. The compose files build those targets by name | mandatory | the build (`target stage … could not be found` otherwise) |
| Server | The image's default command serves plain HTTP on `:80` (no TLS: the edge terminates it). `GET /health` answers `200`, `Content-Type: application/json`, with a JSON body, without touching the database or any other dependency, and without authentication. It is the backend's healthcheck | mandatory | K1, K2; the healthcheck and `up --wait` |
| Migrate | An executable `oliva-migrate` in every target. It waits for the database, applies the schema, and exits: `0` when the schema is current (a second run exits `0` and changes nothing), non-zero on any failure, and within 120 s when the database never answers. Two runs at once are safe: at most one fails, and the result is the same as one run's | mandatory | K3, K4, K5; the one-shot `migrate` service, which every backend-tied service waits for |
| Seed | An executable `oliva-seed` in the `dev` and `staging` targets, **absent from `prod`**. It replaces the database's data with known data (seeding twice leaves the same data, it does not add to it), and exits non-zero when it cannot seed | mandatory | K6 (`prod` and `staging`; `dev` is not tested); `deploy-staging.sh` calls it |
| Signals | On `SIGTERM` the server stops and exits within the grace period (10 s), not by `SIGKILL` | mandatory | K7 |
| Logs | The server writes to stdout/stderr, requests included; nothing that matters only to a file inside the container | recommended | K9 |
| Database URL | Reads a plain `postgresql://user:password@host:port/db` URL, with no driver-specific parameters | recommended | K8 |
| Trusted hosts | Honours `SYMFONY_TRUSTED_HOSTS` (or its own equivalent): when set, a request with another `Host` is refused | recommended | `env check` (production warns while it is empty) |
| Error envelope | Errors on `/api` are JSON: `{"error": "<message>", "status": <code>}`, the shape of the gateway's own errors | recommended | none yet. **The default does not meet it** (friction X20) |
| Trusted proxies | Takes the client address from `X-Forwarded-For` only when the peer is a trusted proxy (the gateway, on the app network) | declared | gateway half: K10. Backend half: verified for the default at release |
| Draining | A request in flight when `SIGTERM` arrives completes before the process exits | declared | verified for the default at release |
| Request isolation | Nothing one request leaves in memory reaches the next one | declared | default: Symfony resets its services between requests; state the app keeps in `static` properties or non-resettable services is the app's |

What each clause means in the default backend, and the details a replacement needs, follow.

### Image and targets

- `dev`: development (the compose override mounts the source; the default runs FrankenPHP in
  worker mode with a file watcher). `prod`: what runs in production. `staging`: production's
  build plus the seed and what it needs. The default's `staging` inherits from `prod` and adds
  `oliva-seed` and its dev dependencies (the fixtures), so they differ only in what `staging`
  adds.
- Oliva builds the same image for every backend-tied service: `migrate`, `backend`, and, with
  their profiles, `worker`, `scheduler` and `realtime-relay`. Each runs another command of
  that image.
- The build receives a named build context `oliva` (Oliva's `scripts/oliva/`): the default
  copies the list of publicly known secrets from it, to refuse them in production.
- Writable paths: the default writes only to `/app/var` (a volume). In production the JWT
  key pair is mounted read-only from `./secrets/jwt` at `/app/config/jwt`; that path is the
  default's, and phase C makes it the slot's.

### Server

- `/health` is **liveness**, not readiness: the database stopped, it still answers `200`
  (measured on the default: `{"status":"ok"}`, the container stays healthy). Readiness, "the
  schema is there", is the `migrate` service having exited `0`, which the backend's start
  already waits for. A `/health` that queries the database turns a database blip into an
  unhealthy backend: `up --wait` and every deploy fail, and the services that wait for a
  healthy backend (worker, relay) do not start. K2 rejects it.
- The gateway routes `/api`, `/api/*` and `/health` to the backend; the backend serves
  nothing else to the outside. `/gateway-health` is the gateway's own and never reaches it.
- Image healthcheck in the default: `curl -fsS http://localhost/health`. A backend whose
  trusted-hosts setting refuses `localhost` is never healthy (`env check` errors on such a
  value).

### Migrate

- In the default: wait for the database (retries for about a minute while the host does not
  answer; gives up **at once** on errors waiting cannot fix: wrong password, unknown
  database or role, no `pg_hba` entry), then `doctrine:migrations:migrate --all-or-nothing`.
  On failure, the last line is the driver's own error.
- "Safe twice at once" holds in the default without a lock because Postgres DDL is
  transactional and the whole run is one transaction: one run wins, the other exits
  non-zero, nothing is half-applied, a third run exits `0`. It does **not** hold for a
  migration that opts out of transactions (`isTransactional(): false`,
  `CREATE INDEX CONCURRENTLY`): that is the app's responsibility.
- It runs on every `docker compose up`, so a migration added in dev is applied by the next
  `up`. Nothing else migrates: not the server, not the worker, not the relay.

### Seed

- In the default: `doctrine:fixtures:load --group=<group>`, the group being
  `OLIVA_SEED_GROUP` or else the environment (`dev`, `staging`). Fixtures purge first: the
  data is **replaced**, and the command's first line says so.
- The guard is structural: the `prod` image has neither `oliva-seed` nor the fixtures bundle
  (`composer --no-dev`). Seeding production is impossible by construction, not forbidden by a
  switch. A replacement keeps it that way: no seed entrypoint in `prod`, not one that refuses.

### Signals

- In the default: the server stops in well under a second (measured 0.1–0.3 s), exit `0`. The worker finishes the message
  in hand and exits; a handler longer than `WORKER_STOP_GRACE_PERIOD` (default `10s`) is
  killed and its message redelivered (delivery is at least once). The relay stops between
  updates.
- A process that is PID 1 and installs no handler ignores `SIGTERM`: every deploy then waits
  10 s and kills it. That was the default's worker and relay until 1.11.0.

### Database URL and charset

`DATABASE_URL` is `postgresql://…` with nothing after the database name since 1.12.0. libpq
(`psql`, and most non-PHP drivers) refuses Doctrine's `?serverVersion=…`, so a URL with it
works only for the default. The default sets the server version and `charset: utf8` in
`doctrine.yaml`. Without an explicit charset a client takes the cluster's default
`client_encoding`: UTF8 on Oliva's Postgres, possibly something else on a managed one, so a
replacement sets its client encoding to UTF8 itself.

### Trusted proxies and hosts

- The gateway is the backend's only client from outside. Its trust depends on the topology:
  a standalone production stack trusts no proxy at the gateway (`127.0.0.1/32`: it is the
  edge, a forged `X-Forwarded-For` is dropped); the shared-infra overlay trusts the private
  ranges (the edge proxy is in front); dev trusts the private ranges. `env check` warns when
  a standalone production gateway is widened again.
- The default backend trusts `PRIVATE_SUBNETS` (`SYMFONY_TRUSTED_PROXIES`, baked in the
  image) and the headers `for`, `port`, `proto`. Never set `SYMFONY_TRUSTED_HEADERS`.
- Known limit: in shared infra, any container of any app on `data_net` is inside the private
  ranges and can reach the backend directly with a forged header. Every app has the same
  owner today; it is a threat-model note, not a fix.
- `SYMFONY_TRUSTED_HOSTS` is empty by default (any `Host` accepted). Absolute URLs (a reset
  link, a redirect) are built from `Host`, so production should set it, and it must accept
  `localhost` (the healthcheck): `'^(localhost|example\.org)$'`.

### Error envelope

The gateway answers its own `502`, `503` and `504` on `/api*` and `/health` (backend down or
not answering) as `application/json`, `{"error":"backend unavailable","status":502}`. A `5xx`
the backend itself returns passes through untouched.

The backend's own errors are the backend's. The recommended shape is the gateway's, so a
frontend parses one envelope. **The default backend returns HTML** for its own errors in
production (`404` on `/api/nope`: `text/html`, Symfony's error page, even with
`Accept: application/json`), because it ships no serializer. Friction X20.

## Backend-tied slots

The database, the queue, the worker, the scheduler and the relay are spoken to by the
backend's own code. They follow the backend's state: a replaced backend replaces them or
runs without them (Q2 of the backend-slot epic).

### Database

Postgres 15 or later, with the `vector` extension available (the default's first migration
creates it; in shared infra, provisioning creates it, since the app's user is not a
superuser). One database per app and per environment. Oliva does not size connections: on a
shared Postgres, every backend's connections count against one server's limit.

**The schema is implementation, not contract.** It belongs to the backend that writes it:
the default's Doctrine mappings and migrations are not something a replacement inherits.
**Replacing the backend is a choice made when the app is born, not a migration path:** a
replacement starts from an empty database, or brings its own way to move the data.

### Queue and worker

Declared, not portable. The default enqueues with Symfony Messenger and **no serializer is
configured, so messages are PHP-serialized** (`PhpSerializer`): only a PHP Messenger consumer
built from the same code can read them. The `worker` service is therefore the default
backend's worker. A replacement brings its own consumer (or none) and declares it
(`OLIVA_QUEUE_CONSUMER=external` in `.env`, announced on every run). One vhost per app and
per environment on a shared broker, whatever the backend.

### Scheduler

The `scheduler` service runs `backend/scheduler/crontab` with supercronic from the backend
image, so its commands are the default's (`bin/console …`). A replacement brings its own.

### Realtime

A backend publishes to the hub by **HTTP `POST` to `MERCURE_URL`** with a JWT signed with
`MERCURE_JWT_SECRET` (HS256, claim `mercure.publish`), or does not publish at all. The hub is
its own service (`realtime`) and does not care what publishes.

The default does not post inline: it dispatches a Mercure `Update` to a Doctrine transport
in its own database, and `realtime-relay` (PHP, the same image) posts it. So an update
dispatched inside a transaction exists only if the data committed, and a hub down for a
while delays events instead of losing them. A replacement gets none of that for free: the
relay reads PHP-serialized rows. A replacement that wants the same guarantee writes its own
outbox.

## Combinations

What each pairing of the backend's state and a backend-tied slot means. *Default* is Oliva's
backend; *replaced* is any other that honours the mandatory clauses.

| Backend | Database | Queue + worker | Scheduler | Realtime publishing |
|---|---|---|---|---|
| default | Oliva's Postgres, or external (shared infra) | default worker (`queues`), or a declared external consumer | default (`cron`) | through the relay (`realtime`) |
| replaced | any Postgres ≥ 15; the schema is the replacement's | the replacement's own consumer, declared; the default worker cannot read its messages | the replacement's own | direct `POST` + JWT to the hub, or none |

A replaced backend with the default worker, scheduler or relay is not a valid combination:
they run the default's code against a schema and messages they do not know.

## CORS

None needed: the frontend, the backend and the hub are served under one origin by the
gateway. A backend that adds CORS headers widens what other origins can do and is not asked
to.

## The conformance suite

`./oliva conformance` builds this checkout's `prod` and `staging` backend targets and tests
them; `./oliva conformance <prod-image> --staging <staging-image>` tests any other backend.
It needs nothing from the backend's code: it runs the image and makes HTTP requests.

- **The harness** is a throwaway stack (`scripts/oliva/conformance.compose.yml`) under its own
  project name, `<app>-conformance`: a Postgres, the image under test, Oliva's gateway, and a
  probe container every request comes from. It publishes no host port, so it runs next to a
  dev stack, and it is always removed, volumes included. It never reads the app's `.env`: the
  backend gets `.env.example` with every generated secret of the manifests freshly made, then
  `.env.backend`, as a real stack would.
- **The gateway's trust (K10)** is read from what `docker-compose.prod.yml` and
  `docker-compose.shared-infra.yml` ship, not from this host's `.env`.
- **Output:** one line per assertion, `PASS`, `FAIL` (mandatory, with the reason), `WARN`
  (recommended), `SKIP` (not tested, and why), `DECLARED`. Exit `0` when every mandatory
  assertion passed, `1` when one failed, `2` when none failed but one was not tested (for
  example K6's staging half, without `--staging`).
- **`--db-url-suffix '?k=v'`** for a backend that cannot read a plain URL: the other clauses get
  tested, and K8 is reported unmet. **`--keep`** leaves the harness up to look at it;
  **`--down`** removes it (and a harness left by a killed run).
- **One run at a time per app.** A harness already there is refused, never taken down: it may
  be another run in progress. An interrupted run (Ctrl-C, a cancelled CI job) prints
  `INTERRUPTED: no verdict`, exits `130` (`143` on SIGTERM) and removes the harness.
- **Time:** about a minute and a half on the default (measured 74–85 s with its images built).
  Most of it is K5's unreachable database, which the default retries for about a minute by
  design; it runs in the background while the other assertions do.
- **Every assertion can fail.** Each one was run against a backend broken on purpose, and
  failed: a `/health` that queries the database (K2, also with the default's own PHP), a
  migrate that is not idempotent or that races (K3, K4), that exits `0` on an error or never
  gives up (K5), a production image with a seed, a seed that adds instead of replacing (K6), a
  PID 1 that ignores `SIGTERM` (K7), a silent server (K9), a gateway whose standalone trust
  was widened or whose shared-infra trust was narrowed (K10). A conforming backend written in
  Python passes all of them, which is what "the same for any backend" means.

Not tested by the suite: a migration that fails on its own SQL (the suite cannot write one
into an image it did not build), the seed in `dev`, the error envelope, and the declared
clauses.

## What Oliva cannot see yet

Until a replaced backend can be declared (phase C of the backend-slot epic), some of
Oliva's checks read the default's PHP and are blind to anything else:

- the `/health` route guard of the deploys looks for a Symfony route;
- the queue and realtime guards grep `messenger.yaml` and PHP sources;
- `verify`, CI, `deps.sh` and `release.sh` assume composer and Symfony.

A replaced backend today runs the conformance suite (`./oliva conformance <image>`) to know
it honours the clauses, and treats a green PHP-specific check as saying nothing about it.
