# Runbook — the backend slot, phase A (1.11.0): the default honours its own contract

How to execute phase A of [`E-backend-slot.md`](E-backend-slot.md). Written for a session
with no memory of the planning, possibly run by a smaller model. Read the epic first (the
*why*, the findings M1–M8, the decisions Q1–Q5); this file is the *how*. Every dangerous
point is marked **⚠**; every assumption to check before acting is marked **🔍 re-check**.

**Phase A in one line:** take the database lifecycle out of the server's entrypoint, make
every deploy loud on failure, make the PHP containers stop cleanly, make the healthcheck
real, put the JWT keys under provisioning, and run dev in worker mode. **Nothing is asked
of a replaced backend yet** (that is phases B and C). An app that changes nothing keeps
working after the sync.

**State:** steps 0–9 done 2026-11-20 (B1–B6, S1–S43, G1–G4 in the epic). Next: step 10, the release, **only with the maintainer's OK**. The branch is not pushed. The local shared-infra simulation (networks, `oliva-sim-pg`, scratch `simapp`) is still there for the gates. Branch `feat/backend-slot`, off `main` at `6230607` (1.10.0).

## Decisions already taken (do not reopen)

| # | Decision |
|---|---|
| Q1 | The schema is the backend's implementation. Replacing the backend is greenfield, at birth |
| Q2 | Worker, scheduler and relay follow the backend's state |
| Q3 | Server, Migrate, Seed and Signals clauses are mandatory (block a deploy); the rest warn |
| Q4 | **Worker mode in dev too.** If the gate (step 7) shows the dev loop degraded, stop and ask. No silent fallback to classic |
| Q5 | Three releases; this is A = 1.11.0 |
| — | **The apps (forks) are not a constraint.** All are the maintainer's, none in production. Write the upgrade notes; never trade a better design for a smaller diff in the apps. The sync can be forceful |

If a step contradicts a decision, the decision wins: stop and ask.

## Ground rules

- **Start of session:** `./oliva doctor`; read `AGENTS.local.md` and the project memory;
  `git switch feat/backend-slot` and `git log --oneline main..`.
- **Nothing is pushed without the maintainer saying so.** Authorization is per push.
- **Never touch `~/finanzas-ong`, `~/crypto-pulse` or `~/viri-engine`.** To try against an
  app: `git clone ~/<app> <scratchpad>/<app>`.
- **Prove, do not reason.** Each gate is a command that was run and whose output was read.
  Report what was run and what was not.
- **New docs and comments: English, no person's name.**
- **A silent failure is a bug in Oliva.** For each change ask: if this breaks, does anything
  make noise? If not, add the guard in the same phase.
- **Out of scope found on the way:** a row in `docs/friction-log.md`, not a fix.
- **One `agent-commits.md` entry for the phase**; conventional commits in English.
- **Ports:** `docker ps` before any `up`; never stop a stack that is not yours.
- **Linters, as CI runs them,** before each commit touching these files:
  - shellcheck: `docker run --rm -v "$PWD:/mnt:ro" -w /mnt koalaman/shellcheck:stable -x -e SC1091 -S warning <files>`
  - actionlint: `docker run --rm -v "$PWD:/repo:ro" -w /repo rhysd/actionlint:latest`
  - hadolint, pinned: `docker run --rm -i hadolint/hadolint:v2.12.0 hadolint - < backend/Dockerfile`
  - Caddyfiles: `caddy validate` (see the unbundle runbook's ground rules for the command)
- **A prod stack from a scratch clone leaves root-owned files** until step 6 lands; clean
  with `docker run --rm -v "$PWD:/x" alpine rm -rf /x/secrets`, then `--profile '*' down -v`.

## Step 0 — Baseline (before any change)

Numbers to compare against at the gates. Record them in the epic under "Phase A baseline".

1. **M1 reproduced on a scratch clone** (`git clone ~/oliva <scratch>/m1`, `./oliva env init`):
   add a migration whose `up()` runs `SELECT 1/0`, run the prod stack the way `deploy.sh`
   does (standalone overlays: `SKIP_PULL=1` and a copy of the `down`/`up -d --build`
   lines, since `deploy.sh` stacks the shared-infra overlay), and confirm `up` returns 0
   while the backend restarts in a loop. Then the same with `COMPOSE_PROFILES=realtime`:
   `up` fails. This is the bug the phase closes.
2. **M2 with the real stack** (dev, `COMPOSE_PROFILES=queues,realtime`): `time docker
   compose stop worker`, `… realtime-relay`, `… backend`. Expect ~10 s, exit 137 for the
   PHP ones.
3. **Dev reload latency, classic mode:** edit `HealthController` to return another field,
   `curl` until it changes; note the time. Same for a `config/packages/*.yaml` change.
4. **Cold start:** `time docker compose up -d --wait` from stopped, dev and prod.

## Step 1 — Signals: `pcntl`

**Files:** `backend/Dockerfile`.

1. Add `pcntl` to the `install-php-extensions` list of `frankenphp_base` (bundled with PHP,
   no pecl). Comment why: PID 1 without a handler ignores SIGTERM (M2), Messenger needs
   `pcntl` to stop between messages.
2. 🔍 re-check: `php -m` lists it in the CLI; FrankenPHP starts in **both** modes (dev
   classic still, prod worker); `verify` green. ⚠ `pcntl` in a threaded SAPI: loading it
   must not change FrankenPHP's behaviour. If FrankenPHP refuses or logs warnings, stop
   and record; the fallback is to enable it for the CLI only (`php-cli.ini`), decided with
   the maintainer.
3. **Measure, worker:** a scratch handler that sleeps 5 s and writes a row at its end.
   Dispatch one message, `docker compose stop worker` during the sleep. Expected: stop
   takes ≈ the rest of the handler, exit 0, the row exists, the message is acked (not
   redelivered on the next start). Record the time.
4. **Measure, relay:** `docker compose stop realtime-relay` while idle. The LISTEN wait
   (`get_notify_timeout: 5000`) may hold the signal up to 5 s. Must be well under 10 s.
5. **Grace period:** if any measured stop is close to 10 s, add `stop_grace_period` to that
   service in `docker-compose.yml` with a comment saying what was measured. Do not set one
   that was not measured. A worker whose handlers outlast the grace period is the app's
   problem, but say so in the guide's worker section: a long handler needs a longer grace
   period, or it is SIGKILLed and redelivered (at least once).
6. Measure again the Doctrine redelivery case from the epic ("read, not measured"): SIGKILL
   the relay mid-publish (`docker kill`), restart it, and time when the update arrives. Only
   record it; if it is the hour Messenger's default suggests, a friction row.

## Step 2 — `oliva-migrate`, and concurrency measured before choosing a lock

**Files:** new `backend/frankenphp/migrate.sh` → `/usr/local/bin/oliva-migrate`;
`backend/Dockerfile` (one `COPY`).

1. The script moves, unchanged in behaviour, the wait-for-db loop and the
   `doctrine:migrations:migrate --no-interaction --all-or-nothing` call (only when
   `migrations/` has PHP files) out of `docker-entrypoint.sh`. `set -e`; exit non-zero on
   any failure; log to stdout. `exec` the last command.
2. **Concurrency (contract clause "safe if run twice concurrently"), measured first:** on a
   scratch DB, a migration with `SELECT pg_sleep(5)` followed by a `CREATE TABLE`. Start
   two `oliva-migrate` at once. Record each exit code, the `doctrine_migration_versions`
   rows, and whether the table exists once.
   - If one exits 0, the other exits non-zero with a clear message, and the schema is
     right: **no lock** (Postgres DDL is transactional, `--all-or-nothing` holds). Write
     the result as the contract's evidence.
   - If anything is half-applied or both exit 0 with a duplicate: add an advisory lock
     around the run, held on the same connection as the migration (a shell wrapper cannot
     hold a session lock across two commands). Stop and present the design first.
3. 🔍 re-check: `--all-or-nothing` with a migration that is not transactional (an app's
   `isTransactional(): false`, or `CREATE INDEX CONCURRENTLY`) is the app's choice; the
   guide says so in one line.

## Step 3 — The entrypoint keeps only what the server needs

**Files:** `backend/frankenphp/docker-entrypoint.sh`, `backend/Dockerfile` (comments).

1. Remove from the setup block: JWT key generation (moves in step 6), wait-for-db and
   migrations (moved in step 2). Keep: the production secret refusal (all containers), and
   the `setfacl` on `var/` for the server only.
2. ⚠ Today `$1` = `php` or `bin/console` also triggered the setup, so a `docker compose run
   backend bin/console …` migrated as a side effect. After this step it does not. Grep the
   repo and the guide for anything relying on it (`grep -rn "compose run" scripts docs`).
3. Rewrite the comment above `CMD` in the Dockerfile (the `sh -c` trap still applies to the
   `setfacl` and the secret refusal) and the worker/relay comments that say "the backend
   migrates".

## Step 4 — The `migrate` service and the dependencies

**Files:** the four compose files and `docker-compose.override.yml`.

1. `docker-compose.yml`: a `migrate` service: build `./backend`, `command:
   ["oliva-migrate"]`, `restart: "no"`, `env_file: [.env, .env.backend]`, `depends_on:
   database: service_healthy`, `healthcheck: disable: true` (⚠ otherwise it inherits the
   image's HTTP healthcheck from step 5), `networks: [app_network]`. No profile: every app
   has a database.
2. `backend`, `scheduler`, `worker`, `realtime-relay`: add `migrate:
   service_completed_successfully` to `depends_on`. The scheduler had only `database`
   until now, so it could run a command against an unmigrated schema: fixed here.
3. Overlays, same pattern as the backend in each:
   - override (dev): image `${COMPOSE_PROJECT_NAME}-backend:dev`, target `frankenphp_dev`,
     `user: HOST_UID:HOST_GID`, `APP_ENV: dev`, bind mounts `./backend/.env`,
     `src`, `migrations`, `config`, `var` (a migration can use app classes).
   - prod: image `…-backend:prod`, target `frankenphp_prod`, `APP_ENV=prod`.
   - staging: image `…-backend:staging`, target, `APP_ENV=staging`, `env_file: !override`
     with `.env.staging` last (⚠ the APP_ENV precedence saga in the guide; same three
     lines as the backend).
   - shared-infra: `depends_on: !override {}` and `data_net`. ⚠ the backend, scheduler,
     worker and relay already use `depends_on: !override` there: each must **re-add**
     `migrate: service_completed_successfully`, or shared infra loses the ordering
     silently. The wait-for-db loop in `oliva-migrate` covers the absent `database`.
4. 🔍 re-check with `config` for each stack (dev; prod; prod+shared-infra; prod+shared-infra
   +staging; each with `--profile '*'`): every PHP service depends on `migrate`, `migrate`
   has the right image/target/env files/networks, no service lost a dependency.
5. Measured already (epic, "Measured after the decisions"): `up -d --wait` returns 1 with
   `service "migrate" didn't complete successfully` on failure, and a second `up` re-runs
   it. Re-measure on the real stack, not only the throwaway.

## Step 5 — A real healthcheck and loud deploys

**Files:** `backend/Dockerfile`, `scripts/deploy.sh`, `scripts/deploy-staging.sh`,
`scripts/lib/` (one guard), `oliva` (doctor), `.github/workflows/ci.yml`.

1. Image `HEALTHCHECK`: `curl -fsS http://localhost/health` (was Caddy's `:2019/metrics`,
   M6). Keep `--start-period=60s`. Worker, scheduler and relay already override it.
2. **Guard before `down`** (`backend_health_guard`, aborts like the env/queue checks): no
   route `/health` in `backend/src` → the backend can never be healthy and `--wait` fails
   after the old stack is down. Message names the fix (restore `HealthController`). Static
   grep, zero cost when the route exists. All three apps have it (checked 2026-11-20).
3. `deploy.sh`: `up -d --build --wait --wait-timeout 300`. On failure, print the last lines
   of `migrate`, `backend` and `gateway`. ⚠ the stack is already down at that point (that
   was true before too: `down` then `up`). The phase makes it loud, not zero-downtime;
   migrating before `down` is out of scope (friction row if it is not there).
4. `deploy-staging.sh`: same `--wait`; remove the explicit `docker exec … migrate` (the
   service does it); keep `fixtures:load` (phase B turns it into `oliva-seed`).
5. `doctor`: a line for the last `migrate` run: `exited 0`, or the exit code and its last
   log lines. Survives Docker being down, like the other steps.
6. CI: the explicit migrate step becomes `doctrine:migrations:up-to-date` (proves the
   service did its job). The `up --wait` step already exists.
7. 🔍 re-check: `--wait` with a profile service that has no healthcheck of its own (the
   gateway has one, the hub inherits the image's). Every long-running service must have a
   healthcheck or `--wait` treats "running" as ready; list them in the commit.

## Step 6 — JWT keys: provisioning, one location

**Files:** `scripts/oliva/env.sh`, `scripts/lib/env-check.sh`, `docker-compose.override.yml`,
`docker-compose.prod.yml`, the guide.

1. **One location in every environment: `./secrets/jwt`** (gitignored already). Dev mounts
   `./secrets/jwt:/app/config/jwt` on top of the `./backend/config` mount. 🔍 re-check the
   nested bind mount wins in dev (the backend reads the keys from `secrets/`).
2. `./oliva env init` **generates** the pair when `JWT_PASSPHRASE` is set and no key exists,
   with openssl through the existing `oliva_in_keydir` (the host may have no openssl); keys
   owned by the host user (closes the root-owned `secrets/jwt` gotcha). It **moves** a
   legacy `backend/config/jwt/*.pem` to `secrets/jwt/` when only the legacy one exists, and
   says so. The change asks nothing of an app that runs `env init`.
3. `env check`: `JWT_PASSPHRASE` set and no key in `secrets/jwt` → error ("every login
   would fail") → fix `./oliva env init`. Runs before `down` in deploys. Drop the
   "the backend generates a new pair on its next start" text in `env.sh`.
4. Prod: mount `./secrets/jwt` read-only into worker, scheduler and relay too (the "known
   limit" in the guide's worker section goes away).
5. 🔍 re-check: root in the prod backend reads a `0600` key owned by the host user; CI's
   `env init` produces keys the dev stack (HOST_UID = runner) reads; `verify` green.

## Step 7 — Dev in worker mode (Q4)

**Files:** new `backend/frankenphp/worker.dev.Caddyfile`, `backend/Dockerfile` (dev
stage), `docker-compose.override.yml` (mount it), `scripts/oliva/verify.sh`.

1. `worker.dev.Caddyfile`: the prod worker block plus `watch` patterns. ⚠ **Never** the
   default pattern set: it covers `var/cache/**/*.php`, which Symfony rewrites on every
   rebuild → reload loop. Watch `./src/**/*.php`, `./config/**/*.{yaml,php}`,
   `./templates/**/*`, `./.env`, `./public/index.php`, `./migrations` not needed.
2. Dev stage: `ENV FRANKENPHP_CONFIG="import worker.dev.Caddyfile"`. ⚠ The 1.4.3 trap:
   `FRANKENPHP_CONFIG` must never be defined in `.env`/`.env.example` (an empty value turns
   worker mode off). `guard_worker_env` covers prod; extend it to dev.
3. `verify`: a step `[worker-mode]` that asserts the **dev** backend runs workers (a
   FrankenPHP worker metric on `:2019/metrics`; 🔍 find its exact name in the running
   image), so a silent fallback to classic is red.
4. **Gate (Q4: if any line fails after an honest attempt, stop and ask):**
   - an edit to a controller shows up no slower than baseline B5 in the epic (classic mode:
     0.9–2.9 s, set by opcache's `revalidate_freq`), a YAML edit no slower than ~0.4 s;
   - an edit to a `config/packages/*.yaml` shows up;
   - a syntax error shows a readable error and the next good save recovers, without a
     restart;
   - no reload loop in 2 minutes idle (watch the log);
   - Xdebug still stops at a breakpoint with `XDEBUG_MODE=debug`;
   - `phpunit` unaffected (CLI);
   - the request-isolation smoke: a scratch controller that stores the authenticated user
     in a static property and returns it; two requests with different users never see each
     other's (Symfony resets services; a static is the app's bug, but the smoke proves the
     worker is real in dev).

## Step 8 — Docs and upgrade notes

1. `docs/oliva/UPGRADING.md`, section 1.11.0, actions labelled:
   - `[local]` run `./oliva env init` once (moves the dev JWT keys to `secrets/jwt`);
     backed by the env-check error.
   - `[host, guard: …]` same on each host (the keys are already in `secrets/jwt` there).
   - An app's `docker-compose.override.yml` (shared) that re-declares `backend`: merge the
     `migrate` service by hand (measured case: one app added mailpit only).
   - Nothing else: migrations and keys keep working without action.
2. The guide (`docs/oliva/agent-guide.md`): host-user paragraph (keys are no longer in
   `config/jwt`), the worker and relay sections ("waits for `migrate`"), shared-infra runbook
   steps 7–8, staging runbook step 5, the CI paragraph, a short "Migrations" paragraph
   (the `migrate` service, `docker compose up -d` re-runs it, how to read its failure).
3. Roadmap: the two stale lines (epic, "What the roadmap says that is no longer true").
4. Epic: status, baseline and gate numbers. Friction log: X16 progress note.

## Step 9 — Gates

**Dev (this checkout):** `./oliva verify` all green, including the new steps; step-0
numbers re-measured and recorded; a broken migration makes `docker compose up -d --wait`
fail with the migrate message.

**Prod and staging (scratch clones, never this checkout's volumes):** the M1 reproduction
now fails the deploy loudly with the migration's error in the output; the healthy path
deploys; staging deploys and seeds; `stop` timings from step 1 hold in prod (worker mode).

**Shared infra (local simulation, see the unbundle runbook's ground rules):** `migrate`
waits for the external Postgres, the stack comes up, ordering holds (backend starts after
`migrate` exited 0).

**Sync rehearsal:** on a scratch clone of `viri-engine` (on 1.10.0, the realistic case),
`sync.sh start` against a scratch 1.11.0 `release`, then `env init`, `verify`. Record every
manual step: each is either an `UPGRADING.md` action or a bug. Optionally the same on
`finanzas-ong` (1.5.1, a long jump: expected to hit X17 first; record, do not fix).

**Linters** (ground rules) on every touched file.

## Step 10 — Release (only with the maintainer's OK)

`agent-commits.md` entry; `scripts/oliva/release.sh 1.11.0` (it refuses without the audit
and the `UPGRADING.md` section); it prints the push command, nobody runs it without
authorization.

## Things to re-evaluate, not just execute

| # | Assumption | Why it might be wrong | When |
|---|---|---|---|
| R1 | `pcntl` is harmless inside FrankenPHP | it was CLI-only for years; threads + signals | step 1.2 |
| R2 | Two concurrent migrations need no lock in Postgres | non-transactional migrations exist | step 2.2 |
| R3 | `up --wait` behaves on the real stack like in the throwaway | profiles, overlays, `!override` | step 4.5 |
| R4 | FrankenPHP's watcher reloads Symfony's container on a config change | the kernel caches the container; a reload may need the worker restart the watcher does | step 7.4 |
| R5 | The nested bind mount `secrets/jwt` over `backend/config` wins | mount order | step 6.1 |
| R6 | Every long-running service has a healthcheck for `--wait` | the hub inherits its image's; a fork's own services may have none | step 5.7 |
