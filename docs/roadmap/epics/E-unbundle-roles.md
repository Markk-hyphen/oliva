# Epic — Unbundle the roles: a gateway of its own, a realtime hub of its own

> **Status:** 🚧 phase 1 implemented, 1.9.0 unreleased (branch `feat/unbundle-roles`); phases 2 and 3 pending. How to execute it:
> [`E-unbundle-roles-runbook.md`](E-unbundle-roles-runbook.md) ·
> **Target versions:** v1.9.0 (gateway), v1.10.0 (realtime) ·
> **Origin:** roadmap item 2, "First: unbundle the roles". Planned 2026-11-17 against
> `main` at `9160c24` (1.8.0), with the maintainer's decisions below.

## Problem

A role that lives inside another container cannot be replaced, or left out, on its own.
Today two containers carry more than one role:

| Container | Roles it carries |
|---|---|
| `frontend`, production | static assets **and** the gateway: routes `/api`, `/health` and `/.well-known/mercure` to the backend, sets the security headers and the CSP (`frontend/Caddyfile`) |
| `frontend`, development | Vite **and a second, different gateway**: the `proxy` block of `frontend/vite.config.js` |
| `backend` | Symfony **and** the Mercure hub (the `mercure` directive in `backend/frankenphp/Caddyfile`) **and** the database lifecycle (wait-for-db, migrations, JWT keys in `docker-entrypoint.sh`) |

Replacing the frontend (say, with Next.js) silently drops the routing and the security
headers. Replacing the backend silently drops realtime. Both are silent failures by
Oliva's own rule, and both block the service flags of roadmap item 3.

`scheduler` and `worker` build from `./backend` and assume `bin/console`: they are
backend-tied by definition (roadmap, "Two kinds of replacement"). This epic writes their
contract down; it does not split them.

## Findings (2026-11-17, before any code)

**Measured.**

- **The two gateways already disagree, and the starter app shows it.** Against the Vite
  dev server, `GET /health` answers `200 text/html` with `index.html`: the Vite proxy
  covers `/api` and `/.well-known/mercure`, not `/health`. The `main.js` that
  `./oliva init` writes fetches `/health` as its "proof that the frontend reaches the
  backend through the gateway", so in the dev loop it prints "unreachable", with no error
  anywhere. Run 3 of the friction log did not see it because it checked the production
  build. Reproduced by running Vite from `frontend/` with a dead `VITE_API_URL`: `/api/x`
  goes to the proxy (500), `/health` does not.
- **The backend publishes to itself.** `MERCURE_URL=http://localhost/.well-known/mercure`
  (`.env.backend`, `.env.example`) works only because the hub runs in the same process.
  Once the hub moves, that URL points at nothing, and a publish from a Messenger handler
  that swallows the exception fails without a sound.
- **In dev, the browser reaches the hub outside any gateway.** `MERCURE_PUBLIC_URL` is
  `http://localhost/...`, the backend's published `:80`, while the page is served from
  `:3000`. It works because subscription is anonymous; it is not the production topology.
- **Oliva does not configure Symfony's trusted proxies.** `frontend/Caddyfile` keeps the
  client's `X-Forwarded-For` (`trusted_proxies static private_ranges`), but
  `backend/config/packages/framework.yaml` sets no `trusted_proxies`, so the backend sees
  the gateway's address as the client. One app added `TRUSTED_PROXIES=PRIVATE_SUBNETS` on
  its own for login throttling. Every new hop (this epic adds one) makes it worse.
- **What the apps changed near these files:** one app added a service (mailpit) to
  `docker-compose.override.yml` (shared); one added `rollupOptions` to `vite.config.js`.
  None edited `frontend/Caddyfile`, which they could not have done anyway: it is Oliva's.
  Two of the three apps subscribe to Mercure from the browser (`EventSource`); one already
  works around "zombie" proxied SSE connections.

**Read, not measured.**

- An app cannot adjust its CSP without editing a file Oliva owns. The policy is one line
  of `frontend/Caddyfile`.
- Every path that checks the stack goes to the backend's published `:80`: `verify.sh`
  (`[mercure]`), the CI Mercure step, the README's URL table, `doctor`.
- `frontend` `depends_on: backend: service_healthy`. With the backend replaced or absent,
  the gateway would wait for it.
- `env-check.sh` reads the resolved environment of `backend` and `frontend` only.
- The shared-infra reverse proxy (`~/infra/caddy/Caddyfile`) points at `<app>-frontend`.
- The roadmap still says `/live.php` is wired into the frontend Caddyfile. It is not since
  1.7.0 (`/api/live`). Corrected with this epic.
- The `backend.${SERVER_NAME}` network alias in `docker-compose.yml` has no reader.
  Confirm and drop it in phase 1.

**What the work stands on.** `env.manifest` already names the `gateway` and `realtime`
slots and `env check` reports slots; the shared-infra network split (`proxy_net` at the
edge, `data_net` behind the backend) maps onto a separate gateway as is; the queue-slot
epic is the template for guards before `down`, a `verify` step and a CI check; names
derive from the project name; dev host ports are variables (T4); every non-HTTP container
gets a healthcheck of its own (X11).

**Timing.** No app is in production and there is no VPS. This is the cheapest moment
there will be to change the topology.

### Decisions (2026-11-17)

| Question | Decision |
|---|---|
| A gateway in dev too, or keep the Vite proxy? | **One gateway in every environment**, one routing file. In dev it sends `/` to Vite. |
| Frontend as its own container behind the gateway? | **Yes.** One more container and one more hop; replacing the frontend becomes changing one upstream. |
| Image of the realtime hub | **The official `dunglas/mercure`** (pinned). Independent of the backend, at the cost of one more base image to track. |
| Scope | **Split gateway and realtime.** Backend lifecycle, worker and scheduler: written contracts, not new containers. Exit through a throwaway fork that replaces the frontend. |
| Releases | **Two:** gateway in 1.9.0, realtime in 1.10.0. |
| Trusted proxies | **Trust the private networks at both hops.** Backend: `ENV SYMFONY_TRUSTED_PROXIES=PRIVATE_SUBNETS` in the backend image (Symfony reads it natively; any `env_file` overrides it). Gateway: `trusted_proxies static {$GATEWAY_TRUSTED_PROXIES:private_ranges}`. Not `framework.yaml` (the app's file) nor `.env.backend` (it overrides `.env`). Reasons: `docs/oliva/concepts.md`, "Trusted proxies". |
| HMR | **Through the gateway.** Publishing Vite's port publishes all of Vite, and its log prints `http://localhost:3000`: the most natural URL would bring back the divergence this epic removes. Vite's port only as a fallback if the phase-1 gate fails. |
| CSP in dev | **The production policy plus the minimum Vite needs** (`style-src 'unsafe-inline'`: Vite injects CSS as `<style>` tags). Production unchanged. Known limit: an app's own inline styles show up in staging, not in dev. |

### Decisions for phase 2 (2026-11-19, after measuring)

Evidence for each row: runbook, "Phase 2 findings".

| Question | Decision |
|---|---|
| Token mode (R1) | **Compatibility mode 8.** The standalone `dunglas/mercure:v1.1.6` accepts it with Oliva's own Caddyfile (measured with the real `symfony/mercure` client). **Watch item, not optional:** compat exists only because both the hub image and FrankenPHP are compiled with the `deprecated_topic,deprecated_claim` build tags. The day either drops them, compat stops. Moving to modern mode (an `issuer` block in the hub, `iss`/`aud` claims, which MercureBundle 0.4 cannot add without a custom token factory) is a pending item to start **before** that happens, not after. Every bump of the hub image runs `verify [mercure]` and checks the build tags. |
| Realtime optional? | **Yes, like everything in Oliva.** `realtime` (hub) and `realtime-relay` live behind a Compose profile `realtime`. An app without it pays for neither. Replaces "always on in 1.10.0". Because Mercure is always on today, an app that uses it and upgrades without the profile would lose realtime silently: a guard (Mercure used by the app, no `realtime` in the stack) is red in `verify` and aborts the deploys before `down`. |
| Publicly known keys in the hub | **Refused in every environment**, not only production. `env check` already treats a public secret as an error everywhere, and the hub cannot tell which environment it runs in. |
| History and storage | **No volume** (same as production today: survives a restart, lost on a deploy, which is acceptable) **plus a cap**: `transport bolt { path …; size N }`, N = 1000 by default, configurable. Measured: the cap keeps the last N events; a client that reconnects after a deploy gets nothing replayed. |
| Backend ↔ hub coupling | **Publishing goes through Messenger, on a Doctrine (PostgreSQL) transport, consumed by a `realtime-relay` service.** Not `depends_on` (it re-couples the startup this epic separates) and not a written warning alone (it changes nothing). Not RabbitMQ: `queues` is opt-in and realtime must not drag it in. The request never waits for the hub; a hub down for a while delays events instead of losing them; dispatched inside the business transaction, an event exists only if the data committed. Cost, paid only by apps with `realtime`: one more PHP container, a table, extra latency (gated, see runbook), and a guard for a relay that is down or a backlog that grows. `HubInterface::publish()` stays available as a synchronous escape hatch; the documented path and the demo use the bus. |

## Design

### Target topology

```
                 ┌──────────── gateway (Caddy) ────────────┐
 browser ──────► │ /api/*, /health          → backend:80   │
                 │ /.well-known/mercure*    → realtime:80  │   (backend:80 until 1.10.0)
                 │ everything else          → frontend     │   (dev: Vite :3000, HMR; prod: :80)
                 │ security headers, CSP, compression      │
                 └─────────────────────────────────────────┘
```

Every upstream is a variable with Oliva's default (`GATEWAY_BACKEND_UPSTREAM=backend:80`,
and so on). Replacing a slot is changing one value, which `env check` reports as
`REPLACED`. That is "replaced must be loud" with no extra machinery.

### Gateway (1.9.0)

- **A new `gateway/` directory, Oliva's:** `gateway/Caddyfile` and `gateway/Dockerfile`
  (pinned `caddy`, the routing file baked in for prod and staging, mounted in dev). Image
  `<project>-gateway:<env>`.
- **An extension point that belongs to the app,** imported by the Caddyfile: a file
  under `gateway/app.d/` for the app's own routes and its CSP. Oliva ships an example and
  never edits the directory. The CSP default stays as strict as today.
- **The frontend becomes a plain upstream.** Dev: Vite on `:3000`, no published port, no
  proxy needed (a fork that keeps its proxy block loses nothing: the gateway routes `/api`
  before Vite sees it). Prod: Caddy `file_server` on `:80`, internal, no headers of its own.
  `frontend/Caddyfile` stays Oliva's and shrinks to that.
- **Ports.** The gateway publishes the stack's only port: `${GATEWAY_PORT:-80}` in dev,
  `80` in prod. The browser uses the same URL in dev and prod. `backend` and `frontend`
  publish nothing by default. `BACKEND_PORT`/`FRONTEND_PORT` in an app's `.env` stop
  meaning anything: an upgrade guard says so, and how to move the value to `GATEWAY_PORT`.
  `DB_PORT` and the RabbitMQ ports do not change.
- **HMR** goes through the gateway (Vite's websocket on the same origin). Caddy proxies
  websockets with no configuration; the risks are configuration: `hmr.clientPort: 3000`
  in `vite.config.js` must go (Vite then uses the page's port, so it follows
  `GATEWAY_PORT`), and the gateway must keep the `Host` header (Vite's `allowedHosts`
  check). Fallback, only if the gate fails: publish Vite's port for HMR.
- **CSP per environment.** Dev gets the production policy plus `style-src 'unsafe-inline'`,
  nothing else; `connect-src 'self'` should already cover the same-origin websocket (to be
  measured). Until now dev had no CSP at all.
- **Dependencies and health.** The gateway depends on nothing: an absent upstream answers
  `502` on its routes, which is loud. `frontend` stops depending on `backend`. The gateway
  gets its own healthcheck (an internal route answered by Caddy itself), never one that
  passes through an upstream.
- **Shared infra.** The gateway joins `proxy_net` with the alias `<project>-gateway`; the
  frontend leaves `proxy_net`. For one release the gateway **also** carries the old alias
  `<project>-frontend`, so an existing `~/infra/caddy/Caddyfile` keeps routing with no
  action. The alias is removed later behind a guard that names the line to change.
- **Trusted proxies, end to end** (decided above). Declared in `env.manifest` (slot
  `backend`, `plain`) and commented in `.env.example`, since an image `ENV` is otherwise
  invisible. `env check` flags `SYMFONY_TRUSTED_HEADERS` set but empty: Symfony throws at
  boot on it (read in the 7.4 kernel).

### Realtime (1.10.0)

- **R1 closed (2026-11-19):** compatibility mode works in the standalone hub with Oliva's
  own Caddyfile. FrankenPHP 1.13.5 already embeds the same Mercure (v1.1.6): no version
  jump. Modern mode is a watch item (decisions for phase 2).
- **A `realtime` service** on the official `dunglas/mercure:v1.1.6` image, behind the
  profile `realtime`, on `app_network` only, with no published port. The same
  configuration as today: anonymous subscribe, publisher and subscriber keys from
  `MERCURE_PUBLISHER_JWT_KEY`, compatibility mode 8. The Caddy admin API stays on
  localhost: `/config/` returns the JWT key in clear (measured).
- **A `realtime-relay` service**, same profile, built from the backend image, running
  `messenger:consume` on the realtime transport only. It is the only publisher to the hub.
- **The "no empty key" net moves with the hub.** Today the backend entrypoint refuses to
  start FrankenPHP with an empty key. The hub needs the same refusal, and the same
  quoted, no-default key in its configuration. The production check for publicly known
  secrets has to cover the realtime container as well.
- **URLs.** `MERCURE_URL=http://realtime/.well-known/mercure` (internal, backend → hub).
  `MERCURE_PUBLIC_URL` goes through the gateway, same origin as the page, in every
  environment. The backend keeps `MERCURE_JWT_SECRET`: it still signs.
- **The guard for the silent publish:** `MERCURE_URL` resolving to the backend itself
  (`localhost`, `127.0.0.1`, `backend`) while a `realtime` service exists is an error in
  `env check`, red in `verify`, and aborts `deploy*.sh` before `down`.
- **The backend Caddyfile loses the `mercure` block**, and the "Mercure in FrankenPHP"
  notes move (`deps.sh`: after bumping FrankenPHP, `verify [mercure]` was mandatory; now
  it is mandatory after bumping the hub image).
- **History and storage.** Measured: today production keeps `mercure.db` in the
  container's writable layer (survives a restart, lost on every deploy), dev keeps it in
  the `backend/var` bind mount. The hub gets no volume and a bolt cap (decisions).
- **Optional, with a guard** (decisions). Supersedes "always on in 1.10.0".
- **Fixes a latent bug:** today the worker and the scheduler cannot publish
  (`MERCURE_URL=http://localhost/…` and no hub in those containers; measured, friction log
  X14). With `MERCURE_URL` pointing at `realtime`, and publishing through the relay, it
  goes away.

### Both phases touch

- All four compose files and the shared override; `deploy.sh`, `deploy-staging.sh`,
  `down*.sh` (service lists, if any); `verify.sh`; the CI jobs that list services or hit
  `localhost:80`; `doctor`; the README URL table and its template
  (`scripts/oliva/templates/README.md.tpl`).
- `env-check.sh` and `queue-guard.sh` read the resolved environment of the new services;
  the "secrets leaked to the frontend" check extends to the gateway.
- `deps.sh`: the gateway and hub base images join the image report, Trivy and the audit.
- `owned-paths.txt`: `gateway/` (except `gateway/app.d/`), and no change of ownership for
  `frontend/Caddyfile`.
- `env.manifest`: the upstream variables (slot `gateway`) and `GATEWAY_PORT`.

## Contracts (written in this epic, enforced where they can be)

| Slot | Contract |
|---|---|
| Gateway | Publishes the stack's one port. Routes `/api/*` and `/health` to the backend, `/.well-known/mercure*` to realtime, the rest to the frontend. Keeps `X-Forwarded-For`, sets the security headers and the CSP, does not buffer `text/event-stream`. Healthy on its own, whatever the upstreams. |
| Frontend | HTTP on its port inside `app_network`; serves the app; calls the API and the hub on its own origin. Knows no backend hostname. |
| Backend | HTTP on `:80`, no TLS. A real `GET /health`. Trusts the private networks' `X-Forwarded-For`. Migrates before it reports healthy. Accepts a `DATABASE_URL` without Doctrine-only parameters. A `seed` hook for staging that cannot run in production by construction (today: the command does not exist in the `--no-dev` image). |
| Realtime | Mercure protocol: publish by HTTP POST with a JWT signed with the publisher key, subscribe over SSE. |
| Worker | An image and one long-running command. Starts only once the backend is healthy, and never migrates. |
| Scheduler | An image and one long-running command that runs tasks on a schedule. |
| Database, queue | Unchanged (roadmap slots table): backend-tied, their contract is what the default backend speaks. |

## Phases

1. **The gateway, in every environment (1.9.0).** *Gate:* in dev and prod, the same
   requests through the gateway's one port: `/` serves the app, `/health` answers JSON
   (the starter's fetch shows "ok" in the dev loop, the finding above), `/api/*` reaches
   Symfony, Mercure subscribe and publish work end to end, HMR reloads a change and the
   page keeps its styles under the dev CSP. The
   security headers are present on every response, and an app's file under
   `gateway/app.d/` changes the CSP without touching an Oliva file. Through a local
   shared-infra proxy with TLS, Symfony sees the client's IP and `isSecure()` is true;
   with `GATEWAY_TRUSTED_PROXIES` narrowed, a forged `X-Forwarded-For` is dropped. Stopping the backend leaves the gateway `healthy` and
   answering `502` on `/api`. A local shared-infra setup routes through
   `<project>-gateway` **and** the transitional `<project>-frontend` alias. A
   `BACKEND_PORT` left in `.env` is reported, with the fix.
2. **Realtime, its own service (1.10.0).** *Gate:* publish from the backend reaches a
   browser subscribed through the gateway, in dev, prod and staging. SSE through two hops
   delivers an event immediately (no buffering, compression or proxy timeout in the way)
   and survives an idle minute. An empty or publicly known key stops the hub in
   production. `MERCURE_URL=http://localhost/...` with the hub separate: `env check`
   error, `verify` red, deploy aborts before `down`. The backend image has no `mercure`
   directive left. Restart behaviour matches what was measured before the switch.
3. **The probe: a throwaway app that replaces a slot.** A scratch app born with
   `./oliva init` replaces the frontend with something that is not Vite, and then the
   backend with a minimal non-PHP HTTP server that honours the backend contract. Every
   place that breaks, or worse, does not break, is a row in the friction log. *Exit
   criterion of the epic:* the replaced frontend works through the gateway with no Oliva
   file edited, and every gap the backend probe finds is either fixed or on the friction
   log.

Each phase is one entry in `agent-commits.md` and one `UPGRADING.md` section with its
actions labelled, preferring a change that asks nothing of the app, then a guard.

## What an app has to do (expected)

| Change | For the app | How |
|---|---|---|
| New `gateway` service, frontend behind it | nothing | Oliva-owned compose files |
| Its `docker-compose.override.yml` (shared) | merge by hand if it added services | labelled action; the measured case is one service, mailpit |
| A Vite `proxy` block left in its config | nothing | harmless behind the gateway; removal optional |
| `BACKEND_PORT`/`FRONTEND_PORT` in `.env` | move to `GATEWAY_PORT` | guard |
| The shared-infra vhost pointing at `<app>-frontend` | nothing for one release, then one line in `~/infra` | transitional alias, then a guard |
| `MERCURE_URL` in `.env.backend` (shared) | take Oliva's new value on sync | guard (phase 2) |
| Trusted proxies | nothing | image default; an app that set its own `framework.trusted_proxies` keeps it |

## Out of scope

- **Service flags** (`--realtime`, `--frontend=<kind>`): roadmap item 3. This epic makes
  them possible, and nothing more.
- **Splitting the database lifecycle out of the backend** (an init or migrate container).
  It stays in the backend; the contract above makes it explicit.
- **Mercure modern mode** (issuer blocks, `iss` claim): a pending item of its own. R1
  showed compatibility mode still works; it is a **watch item** with a known trigger (the
  `deprecated_*` build tags leaving either image), see the decisions for phase 2.
- **TLS at the gateway.** The edge keeps terminating TLS where it does today: the
  shared-infra reverse proxy.
- **A second default for any slot.** Oliva stands behind one implementation per role
  (roadmap item 2).
