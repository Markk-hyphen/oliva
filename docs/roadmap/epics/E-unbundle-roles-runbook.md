# Runbook — unbundling the roles (gateway, realtime, probe)

How to execute [`E-unbundle-roles.md`](E-unbundle-roles.md), written for a session with
no memory of the planning, possibly run by a smaller model. Read the epic first (it has
the *why* and the decisions); this file is the *how*, step by step, with every place that
is known to be dangerous marked **⚠**, and every point that must be re-checked before
acting marked **🔍 re-check**.

**State (2026-11-19):** phase 1 implemented on `feat/unbundle-roles` (not pushed).
The dev and prod-config gates passed; step 11 items 4–6 (scratch app, HMR, two-tab
Mercure) and step 12 items 1–2 (prod stack on a scratch clone, SSE idle in prod) and
step 13 (shared-infra simulation) were deferred. Release pending the maintainer's call.
Phases 2 and 3 are untouched — phase 2 begins at this document's "Phase 2 — The
realtime hub" section, whose step 1 is the compat-mode decision (R1) and must come
before any code.

## Decisions already taken (do not reopen)

| # | Decision |
|---|---|
| 1 | **One gateway in every environment** (dev included), one routing file. The Vite proxy stops being the dev gateway |
| 2 | **Frontend is its own container** behind the gateway (dev: Vite; prod: static Caddy) |
| 3 | **Realtime hub = official `dunglas/mercure` image**, pinned |
| 4 | **Scope:** split gateway and realtime only. Backend lifecycle, worker, scheduler: written contracts |
| 5 | **Two releases:** gateway → 1.9.0, realtime → 1.10.0. Then the probe (phase 3) |
| 6 | **Trusted proxies, option A:** trust private networks at both hops. Backend: `ENV SYMFONY_TRUSTED_PROXIES=PRIVATE_SUBNETS` in the backend image. Gateway: `{$GATEWAY_TRUSTED_PROXIES:private_ranges}` |
| 7 | **HMR through the gateway.** Publishing Vite's port is a fallback only if the phase-1 gate fails, and needs the maintainer's OK |
| 8 | **Dev CSP = production CSP + `style-src 'unsafe-inline'`**, nothing more. Production CSP unchanged |
| — | **The apps (forks) are not a constraint.** Three non-production apps of the maintainer. Choose what is right for Oliva; write the upgrade notes, but never trade a better design for a smaller diff in the apps |

If something below contradicts a decision, the decision wins: stop and ask the
maintainer instead of improvising.

## Ground rules for whoever executes this

- **Start of session:** `./oliva doctor`; read `AGENTS.local.md` (commit attribution rule)
  and the project memory. Then `git switch feat/unbundle-roles` and `git log --oneline main..`.
- **Nothing is pushed without the maintainer saying so.** Authorization is per push.
- **Never touch `~/finanzas-ong`, `~/crypto-pulse` or the third app.** To try something
  against an app, `git clone ~/<app> <scratchpad>/<app>`.
- **Prove, do not reason.** Every gate below is a command that was run, with its output
  read. When reporting, say what was run and what was not. "It should work" is not a gate.
- **New docs and new comments: English, no person's name.** Existing Spanish comments
  stay unless the block is rewritten anyway.
- **A silent failure is a bug in Oliva.** For each change, ask: if this breaks, does
  anything make noise? If not, add the guard (in `verify`, `doctor`, `env check` or the
  deploy scripts) in the same phase.
- **Record, do not fix, what is out of scope:** a row in `docs/friction-log.md`.
- **One entry in `agent-commits.md` per phase**, without asking (standing decision).
  Commit messages in English, conventional (`feat(gateway): …`).
- **Ports:** before any `up`, run `docker ps` and do not stop a stack that is not yours.
  This repository's own dev stack is project `oliva`.
- **Linters, as CI runs them** (run before every commit that touches these files):
  - shellcheck: `docker run --rm -v "$PWD:/mnt:ro" -w /mnt koalaman/shellcheck:stable -x -e SC1091 -S warning <files>`
  - actionlint: `docker run --rm -v "$PWD:/repo:ro" -w /repo rhysd/actionlint:latest`
  - hadolint, **pinned** (`latest` gives false DL3025): `docker run --rm -i hadolint/hadolint:v2.12.0 hadolint - < <Dockerfile>`
  - Caddyfiles: `docker run --rm -v "$PWD/gateway:/w:ro" caddy:<pinned> caddy validate --config /w/Caddyfile --adapter caddyfile`
    (needs the env vars it interpolates, or their defaults)
- **A prod stack started from a scratch clone leaves root-owned `secrets/jwt`.** Clean with
  `docker run --rm -v "$PWD:/x" alpine rm -rf /x/secrets`, then `--profile '*' down -v`.
- **Simulating shared infra without a VPS** (there is none): `docker network create proxy_net`,
  `docker network create data_net`; a `pgvector/pgvector:pg15` container on `data_net` with
  `--network-alias postgres`; a scratch clone with `.env` pointing `DATABASE_URL` there;
  `SKIP_PULL=1 ./scripts/deploy.sh <app>`. For the edge, a `caddy` container on `proxy_net`
  with `tls internal` and a `reverse_proxy <app>-gateway:80` site (see phase 1, step 13).

## Map of what exists today (verified 2026-11-17 on `9160c24`)

Read these before editing; line numbers drift, search by content.

| File | What it does today | Touched in |
|---|---|---|
| `frontend/Caddyfile` | **The production gateway**: `handle /api/*`, `/health`, `/.well-known/mercure*` → `backend:80`; `trusted_proxies static private_ranges`; CSP and headers; `encode zstd gzip`; `file_server`; `handle_errors` → `respond "Something went wrong!" 500`; site address `{$SERVER_NAME:localhost}` | 1 (shrinks to a static server) |
| `frontend/Dockerfile` | `development` stage (Vite, `EXPOSE 3000`), `builder`, `production` (`caddy:2.11.9`, copies `dist` and the Caddyfile) | 1 (production stage only serves files) |
| `frontend/vite.config.js` | `server.proxy` for `/api` and `/.well-known/mercure` to `VITE_API_URL`; `hmr.clientPort: 3000`. **No `/health`** | 1 |
| `backend/frankenphp/Caddyfile` | `http://:80`, the `mercure { … protocol_version_compatibility 8 }` block, `php_server` | 2 (mercure block removed) |
| `backend/frankenphp/docker-entrypoint.sh` | refuses public secrets in prod (`APP_SECRET JWT_PASSPHRASE MERCURE_PUBLISHER_JWT_KEY MERCURE_JWT_SECRET`); refuses an empty `MERCURE_PUBLISHER_JWT_KEY` when `$1 = frankenphp` | 2 |
| `backend/Dockerfile` | `frankenphp_base` sets `ENV PROJECT_DIR`, `HTTP_PORT`; `HEALTHCHECK curl localhost:2019/metrics`; copies `known-public-secrets.sha256` to `/usr/local/share/oliva/` | 1 (`SYMFONY_TRUSTED_PROXIES`) |
| `docker-compose.yml` | `frontend` with `env_file: .env.frontend` and `depends_on: backend: service_healthy`; `backend` with alias `backend.${SERVER_NAME}` | 1, 2 |
| `docker-compose.override.yml` (shared) | dev: backend publishes `${BACKEND_PORT:-80}:80`, frontend `${FRONTEND_PORT:-3000}:3000` and `VITE_API_URL=http://backend:80` | 1 |
| `docker-compose.prod.yml` | frontend: target `production`, `SERVER_NAME: ":80"`, `ports: 80:80`, volumes `frontend_caddy_data/config` | 1 |
| `docker-compose.staging.yml` | frontend: own image tag `:staging` | 1, 2 |
| `docker-compose.shared-infra.yml` | frontend: `ports: !override []`, networks `app_network` + `proxy_net` with alias `${COMPOSE_PROJECT_NAME:-app}-frontend` | 1 |
| `.env.backend` (shared) | `MERCURE_URL` and `MERCURE_PUBLIC_URL` = `http://localhost/.well-known/mercure` | 2 |
| `.env.example` | same Mercure URLs; `SERVER_NAME=localhost`; "Dev host ports" block with `BACKEND_PORT`, `FRONTEND_PORT` | 1, 2 |
| `.env.frontend` | `FRONTEND_DOC_ROOT`, `VITE_PROJECT_DIR`, `SERVER_NAME=localhost` | 1 |
| `scripts/lib/env-check.sh` | `_ec_slot_service`: `backend\|realtime → backend`, `frontend\|gateway → frontend`. Reads resolved env of `backend` (`RES`) and `frontend` (`FE`) only; "leaked secrets" check is on `FE` | 1, 2 |
| `scripts/oliva/env.manifest` | slots; Mercure keys under `realtime` | 1, 2 |
| `scripts/oliva/verify.sh` | `do_health` curls `localhost/health` **inside the backend**; `do_mercure` runs publish/subscribe **inside the backend** against `http://localhost/.well-known/mercure`; `do_prod_build` builds `backend frontend` | 1, 2 |
| `.github/workflows/ci.yml` | bake targets `backend frontend`; `curl http://localhost/health` and the Mercure 5-second check **from the runner**, i.e. whatever publishes host port 80 | 1, 2 |
| `scripts/deploy.sh` | env check and queue guard before `down`; on failed `up` prints the **backend** log only | 1 |
| `scripts/deploy-staging.sh` | `up -d --build`; `docker exec <app>-staging-backend-1` migrate + fixtures | 1 (check only) |
| `scripts/oliva/deps.sh` | `base_images()`: `FROM` lines of `backend/Dockerfile frontend/Dockerfile` + every `image: x:tag` in `docker-compose*.yml` | 1, 2 |
| `scripts/oliva/owned-paths.txt` | owns `frontend/Dockerfile`, `frontend/Caddyfile`, the compose files except the override | 1, 2 |
| `scripts/oliva/templates/README.md.tpl` | URL table: frontend `:3000`, backend `localhost/health`, Mercure `localhost/...` | 1 |
| `scripts/oliva/templates/frontend/main.js.tpl` | `fetch('/health')` as the "reaches the backend through the gateway" proof | 1 (gate) |
| `oliva` (CLI) | `doctor` execs into `backend` for migrations, build inputs, uid | — |
| `README.md` (Oliva's own) | URL table (`:3000`), "The frontend proxies `/api/*`", tree comment "Vite app + production Caddyfile" | 1, 2 |
| `docs/oliva/agent-guide.md` | dev ports, shared-infra topology (alias `<app>-frontend`), runbooks | 1, 2 |
| `~/infra/caddy/Caddyfile` | **not in this repo**: `reverse_proxy ong-frontend:80`. Never edit it from here | 1 (transitional alias) |

## Phase 1 — The gateway (target 1.9.0)

Branch: keep working on `feat/unbundle-roles`. Commit in small steps; the phase is one
entry in `agent-commits.md` at the end.

### Step 1 — Baseline, before changing anything

Record numbers to compare against later (paste them into the phase's commit entry):

1. `docker compose up -d --wait` on this repo; `./oliva verify` → all steps green? Note
   the time.
2. `curl -s -o /dev/null -w '%{http_code} %{content_type}\n' http://localhost:3000/health`
   → expected today: `200 text/html` (the known bug). This is the regression this phase
   fixes; keep the output.
3. `docker compose -f docker-compose.yml -f docker-compose.prod.yml config --services` and
   the same with `--profile '*'`: keep both lists.

### Step 2 — Create `gateway/`

Files (all Oliva-owned except `app.d/`):

- `gateway/Dockerfile`: `FROM caddy:<same pinned tag as frontend/Dockerfile>`; copy
  `Caddyfile` to `/etc/caddy/Caddyfile` and `app.d/` to `/etc/caddy/app.d/`.
  **🔍 re-check** the current caddy tag in `frontend/Dockerfile` and use the same one, so
  `deps.sh` reports one caddy, not two.
- `gateway/Caddyfile`. Shape (adapt, do not paste blindly):

  ```caddyfile
  {
      servers {
          trusted_proxies static {$GATEWAY_TRUSTED_PROXIES:private_ranges}
      }
  }

  http://:80 {
      # Order matters: specific routes before the catch-all.
      handle /api /api/* {
          reverse_proxy {$GATEWAY_BACKEND_UPSTREAM:backend:80}
      }
      handle /health {
          reverse_proxy {$GATEWAY_BACKEND_UPSTREAM:backend:80}
      }
      handle /.well-known/mercure* {
          reverse_proxy {$GATEWAY_REALTIME_UPSTREAM:backend:80}
      }
      handle /gateway-health {
          respond "ok" 200
      }
      import /etc/caddy/app.d/*.caddy
      handle {
          reverse_proxy {$GATEWAY_FRONTEND_UPSTREAM:frontend:80}
      }
      # headers, CSP (from a variable or an imported snippet per environment), encode, logs
  }
  ```

  **⚠ Site address.** Use `http://:80` (or `:80`), **never** `{$SERVER_NAME:localhost}`:
  a site address of `localhost` makes Caddy serve HTTPS on 443 with its internal CA and
  redirect HTTP to HTTPS. That is why `docker-compose.prod.yml` sets `SERVER_NAME: ":80"`
  for the current frontend, and `.env.frontend` still says `SERVER_NAME=localhost`.
  TLS is terminated by the edge (shared-infra proxy), not by the gateway (epic, out of
  scope).

  **⚠ `handle_errors`.** The current file answers every error with a fixed
  `500 "Something went wrong!"`. Behind a dead upstream that turns a `502` into a `500`
  and hides which slot is down. Either drop it or respond with `{err.status_code}`. The
  phase gate requires a `502` on `/api` with the backend stopped.

  **⚠ `/api` vs `/api/*`.** `handle /api/*` does not match `/api` itself. `/api*` would
  also match `/apiary`. Use both matchers as above.

  **⚠ Compression and SSE.** `encode zstd gzip` on the Mercure route can buffer the event
  stream. Exclude the Mercure path from `encode` (a named matcher `not path
  /.well-known/mercure*`), and prove it in the gate (step 12), do not assume it.

  **⚠ The app snippet's position.** `import /etc/caddy/app.d/*.caddy` must come **before**
  the catch-all `handle`, or an app route never matches. An empty `app.d/` must not break
  the import: **🔍 re-check** that Caddy accepts a glob that matches nothing (it should,
  for globs); if not, ship `app.d/README.caddy` with only a comment.

- `gateway/app.d/` — **the app's directory.** Ship one example file with comments only
  (how to add a route, how to extend the CSP). Add `gateway/app.d/` as an exception in
  `owned-paths.txt` (see step 9).

- **CSP per environment.** Production: exactly today's policy (copy it from
  `frontend/Caddyfile`). Dev: the same plus `'unsafe-inline'` in `style-src`. Implement it
  as a variable (`GATEWAY_CSP`) whose value differs in `docker-compose.override.yml`, or
  as two snippet files chosen by an env var. **🔍 re-check** which one keeps the policy in
  one place: the risk is two copies of the policy drifting. Prefer a single base policy
  plus a dev-only addition.

### Step 3 — Frontend becomes a plain upstream

- `frontend/Caddyfile` → a static server only: `http://:80`, `root`, `file_server`, the
  cache header for immutable assets is fine to keep here or move to the gateway (pick one,
  never both). **No CSP, no routing, no `trusted_proxies`.**
- **🔍 re-check SPA fallback.** Today `try_files {path} /index.html` is commented out. Keep
  that behaviour (a fork that needs it adds it). Do not enable it silently.
- `frontend/vite.config.js`: remove `hmr.clientPort` (Vite 6.4.2's client then uses the
  page's port, read in `node_modules/vite/dist/client/client.mjs`: `hmrPort ||
  importMetaUrl.port`). Remove the `proxy` block. Remove the `VITE_API_URL` define only
  if nothing else reads it: **🔍 re-check** with `grep -rn VITE_API_URL frontend/src
  scripts/oliva/templates`.
- **⚠ Vite's host check** (`server.allowedHosts`, since Vite 6.0.9). Caddy's
  `reverse_proxy` keeps the incoming `Host` by default, so Vite sees `localhost` and
  accepts it. If anything rewrites `Host` to `frontend:3000`, Vite answers 403 for every
  request. The gate catches it.

### Step 4 — Compose files

- `docker-compose.yml`: add `gateway` (build `./gateway`, `restart: unless-stopped`,
  `networks: app_network`, **no `depends_on`**, healthcheck on `/gateway-health` with the
  tool that exists in the caddy image; **🔍 re-check**: `caddy:2.x` is Alpine-based and has
  `wget`, not `curl`). Remove `frontend`'s `depends_on: backend`. Drop the
  `backend.${SERVER_NAME}` alias after `grep -rn 'backend\.' --include=*.yml --include=*.sh
  --include=Caddyfile .` shows no reader.
- `docker-compose.override.yml` (dev): gateway publishes `${GATEWAY_PORT:-80}:80`, mounts
  `./gateway/Caddyfile` and `./gateway/app.d` read-only, sets
  `GATEWAY_FRONTEND_UPSTREAM=frontend:3000` and the dev CSP. **Remove** the host ports of
  `backend` (`BACKEND_PORT`) and `frontend` (`FRONTEND_PORT`). Keep `DB_PORT` and the
  RabbitMQ ports.
  **⚠** `verify.sh` and `doctor` exec into the backend and do not need its host port;
  CI curls `localhost:80`, which is now the gateway (better: CI then tests the gateway).
  **🔍 re-check** anything else that reached `localhost:80` expecting the backend:
  `grep -rn 'localhost' scripts oliva .github frontend/src scripts/oliva/templates`.
- `docker-compose.prod.yml`: `gateway` image `${COMPOSE_PROJECT_NAME}-gateway:prod`,
  `ports: 80:80`, the Caddy data/config volumes move from `frontend` to `gateway`.
  `frontend` loses `ports` and `SERVER_NAME`.
- `docker-compose.staging.yml`: `gateway` with its own `:staging` image tag (same reason
  as the frontend comment there: a staging rebuild must never overwrite the prod image).
- `docker-compose.shared-infra.yml`: `gateway` → `ports: !override []`, networks
  `app_network` + `proxy_net` with aliases `${COMPOSE_PROJECT_NAME:-app}-gateway` **and,
  transitionally, `${COMPOSE_PROJECT_NAME:-app}-frontend`**. `frontend` → `app_network`
  only.
  **⚠ Alias collision:** while the gateway carries `<app>-frontend`, the frontend must
  NOT also be on `proxy_net`, or Docker's DNS round-robins between them (the bug in
  `infra-shared-topology`). Verify with `docker network inspect proxy_net`.
- `.env.example`: replace `BACKEND_PORT`/`FRONTEND_PORT` in the "Dev host ports" block
  with `GATEWAY_PORT`; document the `GATEWAY_*` upstream variables commented out, with
  "replace a slot by pointing its upstream elsewhere".

### Step 5 — Trusted proxies in the backend

- `backend/Dockerfile`, stage `frankenphp_base`: `ENV SYMFONY_TRUSTED_PROXIES=PRIVATE_SUBNETS`.
  **Never** set `SYMFONY_TRUSTED_HEADERS` (empty value = exception at boot; unset =
  `for, port, proto`, which is what we want).
- `scripts/oliva/env.manifest`: `SYMFONY_TRUSTED_PROXIES backend plain -` and the
  `GATEWAY_*` variables as `gateway plain -`. Every manifest variable must also be in
  `.env.example` (the manifest header says so; `env check` fails otherwise): add them
  commented with their defaults. **🔍 re-check** how the manifest treats a variable whose
  default lives in an image `ENV` rather than in `.env`: read `oliva_manifest_rows` and
  the `plain` handling in `env-check.sh` before adding it. If it would report the variable
  as missing, decide with the maintainer whether to put the value in `.env.example`
  instead.
- `env-check.sh`: flag `SYMFONY_TRUSTED_HEADERS` present but empty as an error, with the
  fix ("remove the line").

### Step 6 — `env check` knows the gateway

- `_ec_slot_service`: `gateway → gateway`, `frontend → frontend`.
- Read the resolved environment of `gateway` too, and extend the "secrets leaked" check
  from `frontend` to `gateway`: the gateway needs no secret either.
- A `GATEWAY_*_UPSTREAM` that differs from its default → that slot reported `REPLACED`
  (loud, by design). **🔍 re-check** how `REPLACED` is computed today for `database`
  (`_ec_url_host`) and follow the same pattern.

### Step 7 — Guards for what an app has to do

Add to `scripts/lib/upgrade-guards.sh` (and to `UPGRADE_GUARDS`):

- `guard_dev_ports`: `BACKEND_PORT` or `FRONTEND_PORT` set in `.env` → warn: "no longer
  used since 1.9.0; the stack's port is `GATEWAY_PORT`". Zero cost when absent.
- The transitional alias needs no guard in 1.9.0 (it keeps working). Write in the epic
  which release removes it; the removal comes with a guard that names the line in
  `~/infra/caddy/Caddyfile`.

### Step 8 — `verify`, CI, `doctor`, deploy

- `verify.sh`: add a `gateway` step run **from the host** against
  `http://localhost:${GATEWAY_PORT:-80}`: `/health` is JSON (`content-type` contains
  `json`), `/` is HTML, `/gateway-health` is `ok`, and the CSP header is present.
  Keep `do_health` as is (it checks the backend itself).
  `do_prod_build` builds `backend frontend gateway`.
- CI (`.github/workflows/ci.yml`): bake targets + `gateway`; the existing `curl
  localhost/health` now goes through the gateway: also assert the content type is JSON
  (a frontend answering HTML with 200 is exactly the bug). Lint with actionlint.
- `deploy.sh`: when `up` fails, print the logs of `gateway` as well as `backend`.
- `deps.sh` `base_images()`: add `gateway/Dockerfile` to the `awk` file list.
- `doctor`: nothing required; **🔍 re-check** its "app" URLs, if any, point at the gateway.

### Step 9 — Ownership and templates

- `owned-paths.txt`: add `gateway/Dockerfile` and `gateway/Caddyfile` (one line each,
  **not** `gateway/`, so `gateway/app.d/` stays the app's). Update the SHARED comment.
- `scripts/oliva/templates/README.md.tpl`: one URL for the app
  (`http://localhost`), the hub and `/health` under it; drop `:3000`.
- `README.md` (Oliva's): the URL table, "The frontend proxies `/api/*`" → the gateway,
  the tree (`gateway/`), the slots description.
- `docs/oliva/agent-guide.md`: dev ports, shared-infra alias and topology
  (`proxy_net` → gateway), the runbook step that names `<app>-frontend`.
- `docs/roadmap.md` slots table, "Today" column for gateway and frontend.

### Step 10 — `UPGRADING.md`, section `## 1.9.0`

English, labelled actions (`[merge]`, `[local]`, `[host]`, with `guard: <id>` where one
exists). Expected content, from the epic's table: the override (shared) merge for apps
that added services; `BACKEND_PORT`/`FRONTEND_PORT` → `GATEWAY_PORT` (guard
`dev-ports`); the app's URL in dev is now the gateway's (was `:3000`); an app's own
Vite `proxy` block is harmless and can go; an app's own `framework.trusted_proxies`
keeps working (explicit config beats the env default); shared infra: nothing now, the
`<app>-gateway` alias exists and the old one will be removed in a later release.
Run `lint_upgrade_actions` (through `release.sh` dry-run, see below) before committing.

### Step 11 — Gate, dev (all must be run and pass)

1. `docker compose up -d --wait` → `gateway`, `frontend`, `backend`, `database` healthy.
2. `curl -sI http://localhost/` → `200`, `text/html`, `Content-Security-Policy` present
   (dev variant, with `'unsafe-inline'` in `style-src` and nothing else different).
3. `curl -s -w ' %{content_type}\n' http://localhost/health` → `{"status":"ok"} application/json`.
   **This is the regression of step 1.2, now fixed.**
4. A throwaway app born with `./oliva init`. **⚠** `init` refuses in a clone of `main`
   or of this branch (it sees `docs/roadmap.md`/`README.md`, `scripts/oliva/init.sh`
   ~line 98). Use the release recipe from memory on a scratch clone of this branch (fake
   `## 9.9.x` section, `release.sh 9.9.x`), then `git clone -b release <scratch>
   <scratch>/app` and `./oliva init "Probe"` there. Open it in a browser: the starter
   page shows the health status "ok" (not "unreachable").
5. HMR: with the page open, edit a CSS rule and a JS line in `frontend/src`; the change
   appears without a reload and the page keeps its styles. Check the browser console:
   no CSP violation, the websocket connects to the gateway's port. **If HMR does not
   work after a honest attempt, stop and report to the maintainer** (decision 7: the
   fallback needs their OK).
6. Mercure through the gateway (still served by the backend in this phase): with
   `--demo` in the scratch app, two browser tabs see each other's strokes.
7. `docker compose stop backend` → `curl -s -o /dev/null -w '%{http_code}' localhost/api/x`
   is `502`; `docker compose ps gateway` still `healthy`. Start it again.
8. An app route in `gateway/app.d/test.caddy` (for example `handle /x { respond "x" }`)
   answers after `docker compose restart gateway`, without editing an Oliva file. Delete
   the test file.
9. `GATEWAY_PORT=8080` in `.env` → the app answers on `:8080`, HMR still works.
   `BACKEND_PORT=81` in `.env` → `verify` or `doctor` shows the `dev-ports` warning.
10. `./oliva verify` all green; `./oliva env check` shows the gateway slot.
11. Linters (shellcheck, hadolint on the new Dockerfile, actionlint, `caddy validate`).

### Step 12 — Gate, prod and staging (local)

1. `docker compose -f docker-compose.yml -f docker-compose.prod.yml build` then `up -d
   --wait` on a scratch clone (never on this checkout's dev volumes): `/` serves the built
   frontend; production CSP (no `'unsafe-inline'`); `/health` JSON.
2. **SSE through the gateway, measured:** subscribe with
   `curl -sN 'http://localhost/.well-known/mercure?topic=t'` in one terminal, publish
   from inside the backend (copy `do_mercure` from `verify.sh`) and confirm the event
   arrives **within a second**. Then leave the subscription idle for 90 seconds and
   publish again: it must still arrive. Repeat with `Accept-Encoding: gzip` on the
   subscriber. If anything buffers, fix the `encode` exclusion before going on.
3. `config --services` with `--profile '*'` for prod and staging lists `gateway`.

### Step 13 — Gate, shared infra and trusted proxies (local simulation)

1. Networks and Postgres as in the ground rules; deploy a scratch clone with
   `SKIP_PULL=1 ./scripts/deploy.sh <app>`.
2. An edge proxy: `caddy` container on `proxy_net`, Caddyfile
   `https://localhost:8443 { tls internal; reverse_proxy <app>-gateway:80 }`, published
   on 8443. A second site block pointing at `<app>-frontend:80` proves the transitional
   alias.
3. Add a temporary debug route in the scratch app only (never committed) that returns
   `$request->getClientIp()` and `$request->isSecure()`. Through
   `curl -k https://localhost:8443/api/debug` it must show the client IP the edge saw
   (not the gateway's) and `isSecure() = true`.
4. With `GATEWAY_TRUSTED_PROXIES` narrowed to an address that is not the edge's, a
   request with `-H 'X-Forwarded-For: 6.6.6.6'` must **not** show `6.6.6.6`.
5. `docker network inspect proxy_net`: only the gateway (and the edge) on it; the
   frontend is not.
6. `./scripts/deploy-staging.sh <app>` works and staging's gateway has its own image tag.
7. Clean up: stacks down with `-v`, networks removed, `secrets/` removed as above.

### Step 14 — Close the phase

- `agent-commits.md` entry (format in the guide), with the baseline numbers of step 1
  and the gate results; say plainly what was not run.
- Friction log rows for anything found and not fixed.
- Epic status line → "phase 1 implemented". Update the memory state file.
- Release: **only when the maintainer says so.** Dry-run first on a scratch clone (memory
  has the recipe: fake `## 9.9.x` section, `.oliva/audit-state` with today's date,
  `release.sh 9.9.x`). Then `deps.sh audit` if due, then `scripts/oliva/release.sh 1.9.0`.
  It never pushes: it prints the command.

## Phase 2 — The realtime hub (target 1.10.0)

Decisions for this phase are in the epic ("Decisions for phase 2", 2026-11-19). They
supersede anything below that contradicts them, in particular: realtime is **optional**
(profile `realtime`), and the backend publishes **through Messenger on a Doctrine
transport consumed by `realtime-relay`**, never straight to the hub.

### Phase 2 findings (measured 2026-11-19, on 1.9.0)

| # | Finding | How it was measured |
|---|---|---|
| F1 | **Compat mode works in the standalone hub.** `dunglas/mercure:v1.1.6` with Oliva's Caddyfile (`anonymous`, `publisher_jwt`/`subscriber_jwt` quoted, `protocol_version_compatibility 8`): publish accepted, private update delivered to the token holder only, never to the anonymous subscriber. No deprecation logged | probe container on `oliva_app_network`, published with the real `symfony/mercure` `Hub` + `LcobucciFactory` from the backend |
| F2 | **No version jump.** FrankenPHP 1.13.5 embeds Mercure v1.1.6, the same as the image. `v1.1.6` and `latest` were the same image id | `frankenphp build-info`, `caddy build-info`, `docker image inspect` |
| F3 | **Compat depends on build tags.** Image: `-tags=deprecated_transport,deprecated_topic,deprecated_claim`; FrankenPHP: `deprecated_topic,deprecated_claim`. Not a new risk, but a bump that drops them turns compat off while `caddy adapt` still says "Valid". Watch item | `build-info` of both |
| F4 | MercureBundle 0.4.3 has no `issuer`/`audience` setting: modern mode needs a custom token factory (`LcobucciFactory::create` accepts additional claims) | vendor source |
| F5 | **Today the worker and the scheduler cannot publish**: `MERCURE_URL=http://localhost/…` from `.env.backend`, no hub in those containers → `Failed to send an update.` (friction log X14) | one-off container from the backend image |
| F6 | The Caddy admin API (`:2019/config/`) returns the JWT key in clear. Keep admin on localhost in the hub | probe with `admin :2019` |
| F7 | Default transport is bolt. Prod: `mercure.db` in the writable layer (image `VOLUME` is `/app/var/` only): survives `restart`, lost on every deploy. Dev: in the `backend/var` bind mount, survives everything, uncapped | publish, restart, replay from `earliest` |
| F8 | **Bolt cap works**: `transport bolt { path /data/mercure.db; size 5 }`, 12 events published → replay returns ev8–ev12. Use the block form: `transport_url` needs the `deprecated_transport` tag FrankenPHP does not have | standalone hub, `caddy adapt` + runtime |
| F9 | Reconnecting with an unknown `Last-Event-ID` (the after-deploy case) replays nothing; the hub answers `Last-Event-Id: earliest` | standalone hub |
| F10 | **Corrected during the gate.** The image ships its own `HEALTHCHECK`: `wget -q --spider http://127.0.0.1:2019/mercure/health/ready` (200). `realtime/Dockerfile` inherits it as long as the admin API stays on localhost (F6). The earlier "no health route" came from trying `/mercure/health` and `/mercure/health/transport` only | `docker image inspect`, the hub's own access log |
| F11 | Compose `build.additional_contexts` lets `realtime/Dockerfile` copy `backend/frankenphp/known-public-secrets.sha256` without duplicating it; bake reads it too | throwaway compose project, Compose 2.26 |
| F12 | `symfony/mercure` ships `Messenger\UpdateHandler`; the bundle registers it when Messenger is installed, so `$bus->dispatch(new Update(...))` works. `symfony/doctrine-messenger` is **not** installed; every transport today is RabbitMQ, including the failure transport `failed` | vendor, `config/packages/messenger.yaml` |

### Step 1 — Latency gate for the relay path: DONE 2026-11-19, passed

Prototype in the dev stack, removed afterwards (`composer require` inside the container
only, two temporary files deleted, `git status` clean, `verify` green). Standalone hub
`v1.1.6` + bolt cap, gateway pointed at it, one `messenger:consume realtime`, a host
subscriber **through the gateway**, 200 updates one every 50 ms, payload timestamp vs
arrival.

| # | Configuration / scenario | Result |
|---|---|---|
| G1 | Defaults (`get_notify_timeout: 0`, `--sleep` 1 s) | p50 518 ms, **p95 961 ms**: fails |
| G2 | `get_notify_timeout: 5000`, `--sleep` 1 s | p95 ≈ 960 ms: still fails (cause below) |
| G3 | **`get_notify_timeout: 5000` + `--sleep=0.01`** | three runs: p50 7–8 ms, **p95 8.7–9.4 ms**, max 17–31 ms. **Gate passed** |
| G4 | Hub stopped 60 s, 20 updates dispatched meanwhile; retry `max_retries 10, delay 1000, multiplier 2, max_delay 60000` | 20/20 delivered 7 s after the hub returned, none failed. **Order not kept** (4…19, then 0…3): each retry has its own delay |
| G5 | Relay stopped, 20 dispatched | backlog stays in the table; relay restarted → 20/20, in order |
| G6 | Idle cost with G3 | 8 database transactions in 10 s for the whole stack: no busy loop |
| G7 | `messenger_messages` | without `schema_filter`, `doctrine:schema:validate` is red when the table is missing (doctrine-messenger adds it to the expected schema of every app with the transport configured). With `doctrine.dbal.schema_filter: '~^(?!messenger_messages$)~'`, validate is green with and without the table; `messenger:setup-transports realtime` creates it |

**Why G2 fails (instrumented `PostgreSqlConnection::get()`, then reverted):** after each
message the next `get()` takes the plain-poll path (no LISTEN), finds nothing, and the
worker sleeps the whole `--sleep`; only the following `get()` LISTENs, and the
notification is already waiting (`waited 0ms`, `emptiedAgo=1000ms`). LISTEN covers idle
periods, not bursts. `pg_notify` is sent by `send()` itself in 7.4, no trigger involved.

Decisions that follow (mandatory, written as comments where they are configured):

- Relay command: `messenger:consume realtime --sleep=0.01`; transport option
  `get_notify_timeout: 5000`. Either one alone gives ~1 s latency. 🔍 measure in step 4 how
  long a `docker stop` of the relay takes (the LISTEN wait can hold a signal up to 5 s;
  Compose's default stop timeout is 10 s).
- Retry strategy as G4; own failure transport `realtime_failed` (Doctrine).
- Contract: during an outage events arrive late and **out of order**; apps that care carry
  a sequence or re-read state on reconnect.
- Table: `schema_filter` + the relay runs `messenger:setup-transports realtime` before
  consuming. An app without the profile never gets the table and its schema check stays
  green. No migration shipped by Oliva.

### Step 2 — `realtime/` (Oliva-owned)

- `realtime/Dockerfile` `FROM dunglas/mercure:v1.1.6` + `realtime/Caddyfile`. A
  Dockerfile (rather than `image:` in compose) so the configuration is baked in prod and
  `deps.sh` sees the base image either way (`base_images()` reads `FROM` lines of the
  listed Dockerfiles: add `realtime/Dockerfile`).
- Our own Caddyfile, not the image's: `http://:80` (**⚠ same `localhost`/HTTPS trap as
  the gateway**), `anonymous`, keys from the env **quoted with no default** (read the
  comment in `backend/frankenphp/Caddyfile` for why: unquoted, an empty key makes Caddy
  read `HS256` as the key), no welcome page, admin API on localhost (F6), and
  `transport bolt { path /data/mercure.db; size {$REALTIME_HISTORY_SIZE:1000} }` (F8).
- **The secret refusal moves with the hub.** The image has no entrypoint (`caddy run`).
  Add a small entrypoint script that refuses to start on an empty key, and on a publicly
  known one **in every environment** (decision). The list
  `backend/frankenphp/known-public-secrets.sha256` reaches the build through
  `build.additional_contexts` (F11): one file, no copy.
- **⚠ The image runs as root** (`id` → uid 0). Same as the frontend today; T7 only
  concerns files written into bind mounts. **🔍 re-check** that in dev nothing of the hub
  is bind-mounted writable (its storage stays in a named volume or nowhere).
- **Storage:** no volume, bolt capped (F7, F8, decision). Re-measure after: survives a
  restart, capped at N, nothing replayed after a recreate (F9).
- Healthcheck: the subscribe check of F10. Never `/`.

### Step 3 — Wire it

- Compose: `realtime` and `realtime-relay` in `docker-compose.yml` behind the profile
  `realtime` (decision: optional), `app_network` only, no published port; prod/staging
  image tags; shared-infra: the relay joins `data_net` (it reads the database), the hub
  touches neither `data_net` nor `proxy_net`. No `depends_on` from the backend to either.
- Messenger: `symfony/doctrine-messenger`; transports `realtime` and `realtime_failed`
  (Doctrine, own failure transport: `failed` is RabbitMQ); `Update` routed to
  `realtime`; retry strategy of minutes (a hub restart or deploy must not exhaust it).
  `oliva-consume` and `queue-guard.sh` ignore the realtime transports (the relay owns
  them; an app without `queues` must not be told it lacks a worker).
- **Two guards, both abort the deploys before `down`:** (a) the app uses Mercure (code in
  `src/` referencing `Symfony\Component\Mercure`, or `Update` routed) and the stack has
  no `realtime` → "enable the `realtime` profile"; (b) `realtime` present and the relay
  not running, or pending realtime messages older than a threshold → red in `verify`,
  shown in `doctor`.
- The demo (`LiveController`) dispatches through the bus; `./oliva init --demo` adds
  `realtime` to `COMPOSE_PROFILES`.
- Gateway: `GATEWAY_REALTIME_UPSTREAM` default → `realtime:80`.
- `.env.backend` and `.env.example`: `MERCURE_URL=http://realtime/.well-known/mercure`;
  `MERCURE_PUBLIC_URL` stays `http://localhost/.well-known/mercure` in dev (the gateway is
  on that origin now). **🔍 re-check** what `MERCURE_PUBLIC_URL` is used for (discovery
  `Link` header, the demo uses a relative URL) and whether prod needs it per host.
- `backend/frankenphp/Caddyfile`: remove the `mercure` block and the
  `not path /.well-known/mercure*` exclusion; the entrypoint's "empty Mercure key" check
  for `frankenphp` goes (the hub has its own now); the backend still needs
  `MERCURE_JWT_SECRET` (it signs) and keeps checking it is not public in prod.
- `env.manifest`: Mercure keys stay slot `realtime`; `_ec_slot_service realtime →
  realtime`; `env check` reads the `realtime` service's resolved env.
- **The guard** (in `env-check.sh`, so `verify`, `doctor` and `deploy*.sh` all get it):
  a `realtime` service exists and `MERCURE_URL`'s host is `localhost`, `127.0.0.1` or
  `backend` → error, "the backend would publish to itself; the hub is `realtime`". Must
  abort `deploy.sh` before `down`.
- `verify.sh` `do_mercure`: keep the in-backend publish (proves backend → hub on the
  internal URL), and subscribe **through the gateway from the host** (proves browser →
  gateway → hub). Both subscribers (token / anonymous) and the private update, as today.
- CI: the Mercure reachability step already goes through port 80, now the gateway.
- `deps.sh`: the note "after bumping FrankenPHP, `verify [mercure]` is mandatory" moves
  to the hub image.

### Step 4 — Gate: DONE 2026-11-19, passed

Run on the dev stack with `COMPOSE_PROFILES=realtime` (Oliva's own repo carries the demo,
which uses Mercure, so its stack runs the profile). `./oliva verify` green on all steps,
including the reworked `mercure` (publish to the hub from the backend, subscribe through the
gateway from the host, private update to the token holder only). Plus:

| # | Check | Result |
|---|---|---|
| H1 | End-to-end via the bus: `POST /api/live` (dispatch) → relay → hub → gateway → subscriber | delivered |
| H2 | SSE alive after 90 s idle through the full stack, then a dispatch | delivered |
| H3 | Hub refuses an empty key / a placeholder / a publicly known key (`app`) | all three refused, every environment |
| H4 | `grep mercure backend/frankenphp/Caddyfile` | no `mercure {` block (only comments); backend answers 404 on `/.well-known/mercure` |
| H5 | `MERCURE_URL=http://localhost/...` with realtime present | `env check` error, `env_check quiet` exits 1 (→ `verify` red, deploys abort) |
| H6 | App uses Mercure, `realtime` profile off | `realtime_guard` aborts (exit 1) |
| H7 | App does NOT use Mercure (LiveController moved away), profile off | `realtime_guard` silent (exit 0) |
| H8 | `verify` with the profile off | `mercure` step SKIP, not FAIL |
| H9 | Linters: hadolint (realtime Dockerfile, matrix), `caddy validate` with the mercure image, shellcheck, actionlint | clean |
| H10 | Relay resilience (from the step-1 gate, same code): hub down 60 s → delivered on return, out of order; relay down → backlog drained in order | holds |

Known, accepted:
- `env check` still lists the `realtime` slot as `ok` even with the profile off: the Mercure
  signing keys (`MERCURE_JWT_SECRET`, slot realtime) live on the backend and are read there.
  It is informational, not an error; `_ec_slot_service realtime` stays `backend` so the
  `same:` cross-check keeps working within one service (the runbook had suggested remapping
  it, which would break that check).
- `caddy validate` for `realtime/Caddyfile` needs the `dunglas/mercure` image, not vanilla
  `caddy` (the `mercure` directive is only in that build). Noted in the linter list.

### Step 5 — Close the phase

- `agent-commits.md` entry (done with the code commit's log).
- Epic status → "phase 2 implemented". Memory updated.
- Release: **only when the maintainer says so** (dry-run recipe in memory, then `deps.sh audit`
  if due, then `release.sh 1.10.0`).

## Phase 3 — The probe

**DONE 2026-11-19** on a born app ("Probe", `./oliva init --demo` from a scratch 9.9.9
release of this branch). Exit criterion met.

- **Step 2 (replace the frontend): PASS, clean.** A plain `nginx` sidecar on `app_network`
  with `GATEWAY_FRONTEND_UPSTREAM=probe-nginx:80`, in an app-owned `docker-compose.probe.yml`.
  `/` served nginx; `/api` and `/health` still reached the backend; `git status` showed only
  app files. One deviation, fixed in Oliva during the probe (X15): `env check` computed the
  `frontend REPLACED` state but never printed it (the frontend slot has no manifest variables,
  so it never reached the output list). After the fix it prints `frontend  REPLACED (…)`.
- **Step 3 (replace the backend): findings logged, nothing fixed (X16).** A non-PHP `caddy`
  impostor behind `GATEWAY_BACKEND_UPSTREAM` honoured the contract — with the PHP `backend`
  stopped, the gateway still served `/health` (JSON), `/api` and `/`. So the HTTP contract is
  replaceable. What stays bound to the `backend` service and the FrankenPHP image: migrations
  (the entrypoint; the schema would never exist), `verify`'s PHP steps and `doctor`
  (`docker compose exec backend`), `deploy-staging` fixtures, and the worker/scheduler/relay
  building from `./backend`. These are the input to roadmap item 3, not work for this epic —
  the gateway/frontend/realtime slots are independent, which is what the epic set out to prove.

The original plan follows.

1. Scratch app born with `./oliva init` from the released state.
2. **Replace the frontend** with something that is not Vite (a static site generator, or
   a minimal Node server): point `GATEWAY_FRONTEND_UPSTREAM` at it, remove nothing else.
   Expected: works through the gateway, `env check` reports the frontend `REPLACED`, no
   Oliva file edited. Every deviation is a friction-log row.
3. **Replace the backend** with a minimal non-PHP HTTP server that honours the backend
   contract of the epic (`:80`, `/health`, `/api`). Log, without fixing, everything that
   breaks or, worse, does not break: the entrypoint-driven migrations, `verify`'s PHP
   steps, `doctor`'s execs into `backend`, `deploy-staging.sh`'s fixtures call, the
   worker and scheduler building from `./backend`, `owned-paths.txt` still syncing
   FrankenPHP. These rows are the input to roadmap item 3, not work for this epic.
4. Exit criterion: step 2 passes clean; step 3's findings are all on the friction log.

## Things to re-evaluate, not just execute

Points where the plan rests on an assumption that was read, not measured. Treat each
as a question to answer during the phase, and update the epic with the answer.

| # | Assumption | Why it might be wrong | When |
|---|---|---|---|
| R1 | The standalone Mercure hub still accepts compat-mode tokens | 1.1.6 ships modern mode by default | **closed 2026-11-19: yes (F1)**; watch item F3 |
| R2 | `connect-src 'self'` covers the HMR websocket | CSP3 says yes; older engines treated `ws:` separately | phase 1 gate, step 11.5 |
| R3 | Caddy does not buffer SSE through `reverse_proxy` + `encode` | it auto-flushes `text/event-stream`, but compression is the classic culprit | phase 1, step 12.2 |
| R4 | An empty `app.d/` glob import is accepted | Caddy's behaviour with no matches | phase 1, step 2 |
| R5 | An image `ENV` variable fits the manifest/`env check` model | the model assumes values live in env files | phase 1, step 5 |
| R6 | Nothing else depends on the backend's host port 80 | found: CI and README; there may be more | phase 1, step 4 grep |
| R7 | One extra hop costs nothing measurable | two Caddy hops for every asset in prod | phase 1, step 12: compare `/` latency with step 1's baseline; report, do not optimise |
| R8 | The transitional `<app>-frontend` alias can be dropped after one release | only matters once a real VPS exists again | write the removal plan in the epic |
| R9 | The dev CSP with only `'unsafe-inline'` styles is enough for the starter and the demo | the demo uses canvas and Google Fonts; the starter is minimal | phase 1 gate, browser console |

## Not in this epic

Service flags (item 3), splitting the database lifecycle out of the backend, TLS at the
gateway, a second default for any slot, Mercure modern mode **unless R1 forces it**.
