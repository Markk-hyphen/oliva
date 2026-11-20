# Oliva

**A webapp starter that keeps improving the apps built on it, and that an agent can operate without anything failing silently.**

Most starter kits are a snapshot: you copy them on day one and they stop helping you on day two. Oliva is versioned like a library. Every app built on it can pull each new release with one guided command, so a security fix or a deploy fix made once in Oliva reaches every app. The whole thing is designed for whoever is actually at the keyboard today, which is often an AI agent, so every mistake that used to be silent now produces a message that names the fix.

It ships with a default stack that is already wired together, passing CI and patched: Symfony on FrankenPHP, Vite, PostgreSQL with pgvector, Mercure, RabbitMQ and a scheduler. The direction is for every one of those pieces to become optional and replaceable (see [Where it's heading](#where-its-heading)).

> **Honest scope.** Oliva is built and maintained by one developer (plus an agent) to run a handful of real apps on shared infrastructure. It solves *that* problem well. It assumes no community and makes no promises beyond what's written here. Some operational docs are in Spanish, the maintainer's language; this README and the roadmap are in English.

---

## What makes it different

### 1. Apps stay current after day one

Each app is its own repo, with a git remote called `oliva-upstream` pointing here. When Oliva ships a version, the app pulls it:

```bash
./oliva sync check    # how far behind am I, plus the upgrade notes I haven't applied
./oliva sync start    # branch + merge Oliva, every conflict classified
./oliva sync locks    # regenerate composer.lock / yarn.lock without dragging the app's own deps
./oliva sync verify   # the full smoke test before merging to main
```

Three things make this hold up over time instead of rotting into a 19-conflict merge:

- **File ownership.** [`scripts/oliva/owned-paths.txt`](scripts/oliva/owned-paths.txt) says which files belong to Oliva (Dockerfiles, compose files, scripts, CI). An app doesn't edit them. If it needs something different, that becomes an option in Oliva and ships to every app. `sync start` tags each conflict `[OLIVA]`, `[LOCK]` or `[MANUAL]`, and reports *drift*: Oliva files the app edited anyway.
- **One channel to every app.** [`docs/oliva/UPGRADING.md`](docs/oliva/UPGRADING.md) holds the per-version notes an app must act on, and `sync check` shows them. `./oliva release` refuses to cut a version without its section.
- **Extension points instead of edits.** The most common reason to touch an owned file (an extra PHP extension) has its own fork-owned file, `backend/php-extensions.txt`, which Oliva never changes.

It's pull, not push: Oliva doesn't know its apps exist and holds no credentials to them. The full system is in [`docs/oliva/actualizaciones.md`](docs/oliva/actualizaciones.md).

### 2. No silent failures, for humans and agents

A failure that makes no noise is treated as a bug in Oliva, not in whoever triggered it. People who build by prompting an agent are included on purpose: the inattention is real and inevitable, and catching it works better than scorning it. In practice the reader is often the agent itself, so the guards live where it acts, in the scripts it runs and in CI, and each message names the fix.

Some of what is loud today:

| Silent before | Loud now |
|---|---|
| A cron job that never runs because the `cron` profile isn't active | the deploy scripts warn when the crontab has jobs and the profile is off |
| A deploy that takes over another app's containers on the same host | the project guard aborts before `down`/`up` |
| Containers of the old stack surviving a deploy | `down` covers every profile (`--profile '*'`) |
| `composer update` silently jumping a major | every constraint must have a ceiling, enforced before each update and in CI |
| A transitive dependency jumping a major | flagged `⇑ MAJOR` in the update summary |
| Rebuilding with a patched PHP while the old binary keeps serving | `verify` fails if the running PHP isn't the pinned one |
| The prod stack not actually running `APP_ENV=prod` | a CI job checks the resolved config |
| A release with nothing telling the apps what changed | `release` refuses without an `UPGRADING.md` section |
| Forgetting that a dependency or security cycle is due | `./oliva doctor` says so every session |
| Secrets committed in a tracked file, overriding the ones you set in `.env` | `./oliva env check` reads what Compose *resolves*: red in `verify` and CI, and a production deploy aborts before stopping anything |
| A service running on a placeholder or a publicly known secret | same check; in production the backend refuses to start |
| Changing the JWT passphrase without re-encrypting the key (every login fails, nothing at boot) | `./oliva env init` re-encrypts the key; `env check` verifies it opens |

Guards cost nothing when they don't apply: an empty crontab or no PHP extensions means no output at all.

The operating rules travel with the code. [`docs/oliva/agent-guide.md`](docs/oliva/agent-guide.md) is the operating guide, imported by `AGENTS.md`, the open format that Claude Code, Codex, Cursor, Gemini CLI, Copilot, Aider, Zed and others read natively. A one-line `CLAUDE.md` stub imports it. `./oliva` is the single entry point, so docs never depend on script paths, and `./oliva doctor` is the read-only status check an agent runs before touching code. New to the project? [`docs/oliva/sanity-checks.md`](docs/oliva/sanity-checks.md) walks through every check, how they correlate, and what each one does — with a run-it-yourself ✅/❌ checklist.

### 3. Staying patched is the default

Freshness and security run on separate clocks. The dependency cycle (`./oliva deps report` → `deps update`) comes due every ~45 days. A CVE doesn't wait for it: `./oliva deps audit` checks four layers, and `doctor` reminds you once a week has passed.

- **PHP packages:** `composer audit`.
- **JS packages:** `yarn audit`.
- **Inside the base images:** [Trivy](https://trivy.dev/) scans each base image's OS packages and binaries — where a libc or OpenSSL CVE lives — the layer the package audits can't see.
- **The compiled runtime:** PHP and the FrankenPHP server are built from source, so they're a package to no scanner — Trivy included. This layer reads the versions pinned in the backend `FROM` and compares them upstream: PHP against its release branch on php.net, FrankenPHP against its latest GitHub release.

There's one authoritative source per layer, never stacked. Trivy is version-pinned and run as a container, not through a floating action tag. Every app runs the same audit, so a CVE means one command per app instead of per-repo archaeology. Each layer points you at a published fix waiting for something you pinned.

### 4. Several apps on one small server

Everything Compose creates is derived from the project name (images, networks, volumes, network aliases), so apps never collide on the same Docker host. Staging is just one more app on the same host, with its own throwaway database and seeded data.

Going further, several apps can share one Postgres, RabbitMQ and reverse proxy instead of each running its own. That's the opt-in `docker-compose.shared-infra.yml` overlay. Today it's built around the maintainer's own server layout (the shared services live in a separate infra repo) and isn't packaged for general use. Making it a self-contained option is on the roadmap. The runbooks are in [`AGENTS.md`](AGENTS.md).

---

## Getting started

### Prerequisites

- [Docker](https://docs.docker.com/get-docker/) with Compose **v2.24+**. v2.10 is enough for the core dev stack, but the shared-infra and staging overlays use the `!override` merge tag. Check with `docker compose version`.

### Start an app on Oliva

```bash
git clone -b release https://github.com/Markk-hyphen/oliva.git my-app
cd my-app
./oliva init "My App"                       # optional: --origin <your-app-repo-url>
docker compose up -d --wait                 # returns when every service is healthy
./oliva doctor
```

`release` is Oliva as an app receives it: the framework, without Oliva's own README, log and roadmap. `./oliva init` is the birth of the app. It asks for one thing, the name, and then: points the `oliva-upstream` remote at Oliva (that is how `oliva sync` finds it), writes the app's own `README.md`, `AGENTS.md`, `agent-commits.md` and `docs/concepts.md`, removes the live demo (`--demo` keeps it), creates `.env` with every secret generated, and makes the first commit. From then on Oliva never writes to those files again, so they never conflict in a sync.

| Service | URL (dev) |
|---|---|
| App | http://localhost (the gateway publishes the only HTTP port; everything below rides it) |
| Backend | http://localhost/health answers `{"status":"ok"}`. Your routes go under `/api` (nothing is there yet) |
| Mercure hub | http://localhost/.well-known/mercure |
| RabbitMQ management (`queues` profile) | http://localhost:15672 |
| Database | localhost:5432 |

Hot reload is on: changes to `backend/src` and `frontend/src` show up without rebuilding. With `--demo`, the live canvas (`backend/src/Controller/LiveController.php` + `frontend/src/js/live.js`) shows Mercure working out of the box.

### Your first feature

```bash
docker compose exec backend bin/console make:entity        # asks for the fields, writes src/Entity/
docker compose exec backend bin/console make:migration     # diffs the schema into migrations/
docker compose up -d --wait                                # the migrate service applies it
docker compose exec backend php vendor/bin/phpunit
./oliva verify                                             # everything CI will check, before you push
```

A first integration test to copy is `backend/tests/Controller/HealthControllerTest.php`. Tests that boot the kernel use their own database (`<name>_test`); `./oliva verify` and CI create and migrate it for you (`scripts/lib/test-db.sh`, which you can also run by hand).

Two things worth knowing before they cost you an afternoon:

- **Only some backend paths are live-mounted** in dev: `src`, `tests`, `config`, `migrations`, `public`. Anything else (`composer.json`, `phpunit.dist.xml`) is baked into the image, so after editing it run `docker compose up -d --build backend`. Otherwise the container keeps the old copy and nothing tells you.
- **A failed migration stops the stack from coming up**, by design: `up --wait` says `service "migrate" didn't complete successfully`, and `docker compose logs migrate` (or `./oliva doctor`) shows the SQL error. Fix the migration and run `docker compose up -d --wait` again.

> Choosing at birth which services an app carries (`--queues`, `--no-realtime`) is on the roadmap (item 3). `init` is its first slice: identity only.

### Production

```bash
docker compose -f docker-compose.yml -f docker-compose.prod.yml build
docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d
```

The frontend is served by Caddy on **http://localhost**. Backend, database and RabbitMQ are internal and never reachable from outside. On a server, redeploys are `./oliva deploy` (pull + build + down + up) and `./oliva deploy-staging`.

Run `./oliva env check --prod` before the first `up`. In production the backend refuses to start on a secret that is missing, a placeholder or publicly known, and `./oliva deploy` checks the same before it stops the running stack. The fix is always `./oliva env init` on that machine.

> **Queues:** with the `queues` profile, every environment runs a `worker` that consumes every transport except the failure one (since 1.8.0; until then it existed only in dev). On a shared broker, give each app and each environment a vhost of its own: they all inherit the same queue names.

---

## The default stack

These are the pieces Oliva makes robust, and the ones its guards, CI and update cycle know about.

| Layer | Technology |
|---|---|
| Backend | Symfony 7.4 (PHP 8.3) · FrankenPHP · Caddy · JWT auth (Lexik) |
| Frontend | Vite 6 · vanilla JS · Bootstrap 5, served by Caddy |
| Database | PostgreSQL + [pgvector](https://github.com/pgvector/pgvector) |
| Real-time | [Mercure](https://mercure.rocks/) hub, built into the backend's Caddy |
| Queues | RabbitMQ + Symfony Messenger |
| Scheduled tasks | `supercronic` running `backend/scheduler/crontab` |
| Staging / seeding | [Foundry](https://symfony.com/bundles/ZenstruckFoundryBundle/current/index.html) + Doctrine Fixtures · `frankenphp_staging` image stage (the fixtures command doesn't exist in the prod image) |
| API testing | a [Bruno](https://www.usebruno.com/) collection in `api/`, per app (not shipped by Oliva: the requests are 100% domain) |
| Infrastructure | Docker Compose · multi-stage builds (dev / prod / staging) |

```
Browser
  │  HTTP
  ▼
Gateway (Caddy)
  │  /                       │  /api, /health   │  /.well-known/mercure
  ▼                          ▼                  ▼
Frontend (Caddy · Vite)   Backend (FrankenPHP · Symfony)   Realtime hub (Mercure)
                               │  SQL   │  AMQP        │  publish        ▲ SSE
                               ▼        ▼              ▼                 │
                             PostgreSQL  RabbitMQ      realtime-relay ───┘
                              (+ pgvector)  └ worker / scheduler
```

The gateway owns routing, the Content-Security-Policy and trusted-proxy handling; it is the only service that publishes a port. Backend and frontend never face the client directly. In production, the shared-infra edge proxy terminates TLS and reaches the gateway over an internal network.

Realtime (opt-in, profile `realtime`) is a standalone Mercure hub. The backend does not publish to it inline: it dispatches the update on the message bus, and a `realtime-relay` delivers it, so a request never waits on the hub and nothing is lost if the hub restarts.

[`docs/oliva/concepts.md`](docs/oliva/concepts.md) explains the less obvious pieces (pgvector, AMQP, Mercure, the sync model). `docs/examples/` has reference skeletons of a queue producer/consumer and a Mercure publisher.

### Optional services (Compose profiles)

`backend`, `frontend` and `database` always come up. The rest is behind profiles, switched with `COMPOSE_PROFILES` in `.env` (empty = core only):

| Profile | Adds | You must also set |
|---|---|---|
| _(none)_ | `backend`, `frontend`, `gateway`, `database` | `DATABASE_URL`, `APP_SECRET`, JWT keys |
| `realtime` | `realtime` (Mercure hub), `realtime-relay` | the Mercure keys; `REALTIME_HISTORY_SIZE` (optional) |
| `queues` | `rabbitmq`, `worker` | `RABBITMQ_USER`, `RABBITMQ_PASSWORD`, `RABBITMQ_DSN`; `WORKER_CONSUME_ARGS` (optional, `.env.backend`) |
| `cron` | `scheduler` | nothing, but `backend/scheduler/crontab` must have jobs |

Publishing to Mercure from a message handler or a scheduled command works the same: the update is dispatched on the bus and the relay delivers it. An app that uses Mercure without the `realtime` profile is caught before a deploy (the gateway would answer 502 and updates would pile up).

```bash
COMPOSE_PROFILES=queues,cron docker compose up -d
```

- **Enabling a profile doesn't configure it.** A missing DSN or key crashes the service at boot, which at least is loud.
- **Forgetting a profile:** the deploy scripts catch it for `cron` (a warning) and for `queues` (they abort before stopping anything when messages are routed to an asynchronous transport and no worker would consume them).
- **Removing a profile from `COMPOSE_PROFILES` doesn't stop a container that's already running.** Use `docker compose stop <service>` or `down`.
- **Adding a new optional service:** give it `profiles: ["<name>"]`, and never let a core service `depends_on` it, or Compose pulls it back up with the profile off. Then add a row above and a line in `.env.example`.

---

## Where it's heading

The through-line of Oliva is one move: **turn what is assumed into what is chosen.** Taken to its end, it has three steps:

1. **A fixed core with optional extras.** This is where Oliva is today. Backend, frontend and database always come up. Queues and the scheduler are opt-in. The database and the broker can already live outside the app (a managed Postgres, say) as long as the connection matches. But every app still ships every piece, even the ones it switched off.
2. **No mandatory services.** An app has only the pieces it asked for.
3. **Every piece optional *and* replaceable.** Every role (gateway, frontend, backend, realtime, database, queue, worker, scheduler) becomes a slot that is either the **default** (what Oliva makes robust), **replaced** (anything that honors the slot's contract) or **absent**.

Oliva will stand behind one robust default per role and won't pretend to make every alternative robust. A replacement is the replacer's responsibility, and Oliva says so out loud: `doctor`, `verify` and CI will name the slot that's outside the net. Profiles can't get there, because they switch off services but still ship their code. The mechanism is install-time scaffolding, and it waits on what real use shows actually varies between apps.

The full reasoning, the slot contracts and the sequencing are in [`docs/roadmap.md`](docs/roadmap.md).

---

## Reference

### `./oliva`

| Command | What it does |
|---|---|
| `doctor` | read-only status: branch, git, containers, migrations, resolved environment, deps/audit due, sync status (in an app) |
| `env <init\|check [--prod]>` | `init` creates or repairs `.env` (generates secrets, derives values, re-encrypts the JWT key). `check` verifies what Compose resolves for each service |
| `deps <due\|report\|update\|audit\|scan-images>` | Oliva's maintenance cycle and CVE audit |
| `sync <check\|start\|locks\|verify>` | pull Oliva into an app |
| `verify` | full local smoke test (environment, migrations, schema, PHPUnit, prod build, running PHP version) |
| `release X.Y.Z` | cut an Oliva version (refuses without its `UPGRADING.md` section) |
| `deploy`, `deploy-staging`, `down`, `down-staging` | operate an app on a server |
| `version` | print `OLIVA_VERSION` |

### CI

`.github/workflows/ci.yml` runs on every push and PR, skipping docs-only changes. It has six jobs:

- **Env contract:** `./oliva env init`, then `env check` on the dev and prod stacks. Red when a tracked file carries a real secret or overrides `.env`.
- **Tests:** build the images, bring up the stack, check `/health` and Mercure, run migrations, validate the Doctrine schema, run PHPUnit.
- **Prod config guard:** `APP_ENV` really resolves to `prod`.
- **Composer constraints guard.**
- **Docker lint:** hadolint.
- **Image scan:** Trivy, report-only.

An app can skip a step that legitimately doesn't apply to it, with `OLIVA_VERIFY_SKIP` locally or the `OLIVA_CI_SKIP` repo variable in CI. [`docs/oliva/qa-y-staging.md`](docs/oliva/qa-y-staging.md) covers what this verifies, the staging stack, and what Oliva deliberately does *not* check.

### Adding PHP extensions

`backend/php-extensions.txt` belongs to the app, one per line. Extensions bundled with PHP go without a version (the base image pins them). PECL extensions get an exact version:

```
bcmath
redis-6.2.0
```

### Environment variables

`./oliva env init` creates `.env` from `.env.example` and generates the secrets. Where things live:

| File | Tracked | Holds |
|---|---|---|
| `.env` | no | this machine's real values, secrets included |
| `.env.backend`, `.env.frontend` | yes | non-secret defaults. Never a secret: `.env.backend` loads after `.env` and would override it, publicly |
| `.env.example` | yes | every variable, with placeholders |
| `scripts/oliva/env.manifest`, `env.manifest` | yes | what each variable is (slot, kind, how its value is made). The second one is the app's: declare your own variables there |

Per service:

| Variable | Description |
|---|---|
| `COMPOSE_PROFILES` | optional services to bring up (see above) |
| `POSTGRES_USER` / `POSTGRES_PASSWORD` / `POSTGRES_DB` / `POSTGRES_VERSION` | local database |
| `DATABASE_URL` | Doctrine connection, always in `.env`. Standalone: derived from `POSTGRES_*` by `env init`. Shared infra or a managed database: the external URL (`env check` reports the slot as `REPLACED`) |
| `APP_ENV` / `APP_SECRET` | Symfony environment (`dev`; prod/staging are set by their overlays) and secret |
| `JWT_PASSPHRASE` | JWT key passphrase (keys are generated on first boot into `secrets/`) |
| `SERVER_NAME` | domain (default `localhost`) |
| `RABBITMQ_USER` / `RABBITMQ_PASSWORD` / `RABBITMQ_DSN` | broker credentials and Messenger DSN |
| `MERCURE_URL` / `MERCURE_PUBLIC_URL` / `CADDY_MERCURE_URL` / `CADDY_MERCURE_PUBLIC_URL` | Mercure hub URLs (internal vs public) |
| `MERCURE_PUBLISHER_JWT_KEY` / `MERCURE_JWT_SECRET` | Mercure JWT keys |

### Project structure

```
oliva/
├── oliva                   # the CLI: ./oliva <command>
├── OLIVA_VERSION
├── env.manifest            # the app's own variables (Oliva's are in scripts/oliva/env.manifest)
├── AGENTS.md / CLAUDE.md   # the repo's own agent notes; first line imports docs/oliva/agent-guide.md (+ one-line stub)
├── agent-commands.md       # chat commands for the agent
├── backend/                # Symfony app (FrankenPHP + Caddy)
│   ├── src/DataFixtures/   # Foundry fixtures, grouped by env
│   ├── php-extensions.txt  # the app's extra PHP extensions (Oliva ships it empty)
│   ├── scheduler/crontab   # consumed by supercronic
│   └── frankenphp/         # Caddy and PHP runtime config
├── frontend/               # Vite app (dev) / static build served by Caddy (prod)
├── gateway/                # Caddy edge: routing, CSP, trusted_proxies, /gateway-health
│   ├── Caddyfile           # Oliva-owned
│   └── app.d/              # the app's own route snippets (*.caddy)
├── realtime/               # Mercure hub (profile realtime): Caddyfile, key-guard entrypoint
├── docs/
│   ├── roadmap.md          # where Oliva is heading and why (Oliva's own: does not ship to apps)
│   ├── oliva/              # framework docs that ship to every app: agent guide, glossary,
│   │                       #   sync system, UPGRADING, QA and staging, sanity checks
│   └── examples/           # reference skeletons (not live code)
├── scripts/
│   ├── oliva/              # deps, sync, verify, release, env, owned-paths.txt
│   ├── lib/                # project guard, cron guard, env check, docker prune
│   └── deploy*.sh / down*.sh
├── docker-compose.yml               # base
├── docker-compose.override.yml      # dev (auto-applied)
├── docker-compose.prod.yml
├── docker-compose.staging.yml
├── docker-compose.shared-infra.yml  # opt-in: shared Postgres/RabbitMQ/proxy
└── secrets/                # JWT keys, generated at first boot (gitignored)
```

---

## License

MIT
