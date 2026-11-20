# Runbook — the backend slot, phase B (1.12.0): the contract, written and tested from outside

How to execute phase B of [`E-backend-slot.md`](E-backend-slot.md). Written for a session
with no memory of the planning, possibly run by a smaller model. Read the epic first (the
findings, decisions Q1–Q5 and QB1–QB3, the phase C design notes); phase A's runbook
([`E-backend-slot-runbook.md`](E-backend-slot-runbook.md)) is the model for method and
tone. **⚠** marks a dangerous point, **🔍 re-check** an assumption to measure before acting.

**Phase B in one line:** write the backend contract as a product document an app reads,
give it a conformance suite that tests any backend image from outside (and that the default
can fail), make the build targets slot-neutral, give seeding its own entrypoint with the
structural guard kept, decouple what still hides under `backend/frankenphp/`, and land the
three small default fixes. Still **nothing changes for an app that keeps the default**
beyond labelled upgrade actions; declaring a replaced backend is phase C.

**State:** step 0 done 2026-11-20 (answers P1–P10, findings B-F1..B-F3 in the epic's "Phase B
baseline"). B-F3 decided: **QB4, option C** (see the epic). Steps 1–7 done (results S44–S56 in the epic; step 5 found X20: the default's own errors are HTML, so the error envelope is a recommended clause the default does not meet yet; step 6's negative controls, 22/22, are recorded there). Step 8 done (S57–S59; new `build_guard`; friction X21 recorded). Step 9 done locally (GB1–GB6 in the epic; the gate found a guard that printed nothing in the deploys, fixed in `aa124e7`); CI after the push is the gate left. Next: step 10, only with the maintainer's OK. `UPGRADING.md` says "unreleased" in the 1.12.0 header: step 10 puts the date. Docs for steps 1–4 (guide: targets, seeding, trusted hosts, gateway trust) are step 8. Branch
`feat/backend-slot-b`, off `main` at `330c3f6` (1.11.0, CI green).

**Step 0 outcome, folded into the steps below:**
- B-F1 → step 4 gains a fourth fix: `oliva-migrate` fails fast on an error waiting cannot
  fix (authentication, unknown database), and prints the driver's error as its last line,
  not `dbal:run-sql`'s usage (P3).
- B-F2 → step 4.2 drops `serverVersion`; `charset` goes too only with the contract saying
  the database's default `client_encoding` must be UTF8 (Postgres' default), since that is
  what the driver uses without it (P6).
- P7 → step 4.3 confirmed: today the 502 has no body at all.
- B-F3 → QB4 (option C) → step 4 gains a fifth fix: in `docker-compose.prod.yml` the gateway
  trusts no proxy (`GATEWAY_TRUSTED_PROXIES` set to a range nothing comes from; 🔍 what Caddy
  accepts as "none"); `docker-compose.shared-infra.yml` sets it back to `private_ranges`;
  `env check` warns when a standalone production stack resolves it to something wider. K10
  asserts the standalone default drops a forged header from a private peer.

## Decisions already taken (do not reopen)

| # | Decision |
|---|---|
| Q1–Q5 | See the epic. Q3: Server, Migrate, Seed and Signals are mandatory clauses |
| QB1 | The suite tests what is observable from outside, the same for any backend. "Trusts `X-Forwarded-*` only from private networks" and "SIGTERM lets an in-flight request finish" are **declared** clauses, verified for the default at the gates; the gateway half of `X-Forwarded-For` is tested (the gateway is Oliva's). The probe that would test them is phase C (design notes in the epic). Never add an endpoint to the app's `src/` in this phase |
| QB2 | `SYMFONY_TRUSTED_HOSTS` unset by default; `env check` warns in production when unset |
| QB3 | The suite runs in CI against the default, and as `./oliva conformance [image]`. Not inside `verify` |
| — | The apps are not a constraint. Write the upgrade notes; never trade a better design for a smaller diff in the apps |

## Ground rules

Those of phase A's runbook, unchanged (session start, no push without the maintainer, never
touch the apps, prove do not reason, English, a silent failure is a bug, friction rows for
what is out of scope, one `agent-commits.md` entry, ports, linters, root-owned scratch
files). One addition: **every assertion of the suite gets a negative control** at the gate,
a deliberately broken backend that the assertion must reject. An assertion that no broken
backend can fail is theatre and is removed.

## Step 0 — Ground truth (before any change)

Answer each future suite assertion **by hand** against the 1.11.0 images, and record the
answers in the epic ("Phase B baseline"). The suite must later reproduce them.

1. `/health` with the database stopped (`docker compose stop database`): code and body.
2. `oliva-migrate` with `DATABASE_URL` pointing at nothing: exit code and time to give up.
3. `docker run --rm <prod image> oliva-seed` does not exist yet; record `doctrine:fixtures:load`
   in prod (rc 1, "not defined": phase A's M3) as the structural guard to keep.
4. A plain URL: `DATABASE_URL=postgresql://u:p@db:5432/db` (no `serverVersion`, no
   `charset`) → `oliva-migrate` rc and `/health`. 🔍 re-check `charset`: what client
   encoding `pdo_pgsql` uses without it (`SHOW client_encoding` through
   `dbal:run-sql`), on a database created with the image's defaults.
5. Gateway with the backend stopped: `GET /api/x` and `GET /health` code, `Content-Type`,
   body (phase A's B1: `502` with no content type).
6. Gateway `X-Forwarded-For`: point `GATEWAY_BACKEND_UPSTREAM` at a scratch echo container
   (`caddy` answering `{http.request.header.X-Forwarded-For}`) and send a forged header from
   the host. Record what the upstream receives with the default `GATEWAY_TRUSTED_PROXIES`
   and with it narrowed to a range that excludes the host.
7. The two declared clauses, for the default, with a scratch controller in a scratch app
   only (never committed): the client IP Symfony resolves for a forged header from outside
   and from inside the private ranges; SIGTERM during a request that sleeps 3 s (does it
   complete?). These are the release-gate measurements QB1 keeps.

## Step 1 — Slot-neutral build targets

**Files:** `backend/Dockerfile`, `docker-compose.override.yml`, `docker-compose.prod.yml`,
`docker-compose.staging.yml`, `scripts/deploy-staging.sh` (comments), `scripts/oliva/verify.sh`
(`ci-build`), `scripts/lib/upgrade-guards.sh` (comments), the guide.

1. Rename the stages compose builds: `frankenphp_dev` → `dev`, `frankenphp_prod` → `prod`,
   `frankenphp_staging` → `staging`. **Keep** `frankenphp_upstream` and `frankenphp_base`:
   they are internal, and `lib.sh`/`deps.sh`/`env-check.sh` parse `frankenphp_upstream`.
2. `grep -rn "frankenphp_\(dev\|prod\|staging\)"` over the repository: nothing left outside
   history and the epic. Measured 2026-11-20: in the apps, only Oliva's own blocks of their
   shared override use the names (finanzas-ong's `mailpit` does not), so the sync brings the
   rename; a leftover name fails the build loudly (`target stage … not found`, 🔍 confirm
   the message).
3. 🔍 re-check: `verify` green; the prod and staging images build; CI's bake targets are
   service names, not stages (it should need no change).

## Step 2 — `oliva-seed`: the Seed clause, structural guard kept

**Files:** new `backend/frankenphp/seed.sh`; `backend/Dockerfile` (COPY in the `dev` and
`staging` stages **only**); `scripts/deploy-staging.sh`; the guide.

1. `oliva-seed`: `exec php bin/console doctrine:fixtures:load --group="${OLIVA_SEED_GROUP:-<env>}"
   --no-interaction`, the group defaulting to the stage's environment (`dev`, `staging`).
   **It replaces the data** (fixtures purge first): the contract declares it, and the script
   says so on its first line of output.
2. ⚠ **The guard stays structural:** the `prod` stage has neither the fixtures bundle
   (`--no-dev`, phase A's M3) nor the `oliva-seed` executable. `staging` inherits from
   `prod`, so the COPY goes in `staging` and `dev`, never in `base` or `prod`.
3. `deploy-staging.sh` calls `oliva-seed` (through `docker exec`, as today, or `compose run
   --rm`: measure which keeps working in shared infra). 
4. 🔍 re-check: `docker run --rm --entrypoint oliva-seed <prod image>` → not found (exit
   127); in staging it seeds; the three apps' fixtures use the `dev` and `staging` groups
   (measured 2026-11-20), so the default group matches them.

## Step 3 — Decouple what hides under `backend/frankenphp/`

**Files:** `backend/frankenphp/known-public-secrets.sha256` → `scripts/oliva/known-public-secrets.sha256`;
`backend/Dockerfile`, `realtime/Dockerfile`, `docker-compose.yml` (`additional_contexts`),
`scripts/lib/env-check.sh` (`OLIVA_PUBLIC_LIST`), `scripts/oliva/owned-paths.txt` if needed.

1. Move the list to `scripts/oliva/` (owned already). The backend image reads it through a
   named build context, the way `realtime` does since 1.10.0 (finding F11: bake reads it).
2. ⚠ CI builds with bake: 🔍 re-check that bake passes the new `additional_contexts` of the
   backend (it did for `realtime`). Run the CI build locally with the `oliva-ci` builder.
3. Why: a fork that drops Oliva's `backend/frankenphp/` (a replaced backend, phase C) must
   keep a working `env check` and a buildable hub.
4. Scope guard: reading the backend's environment by slot instead of by service name is
   phase C, with the declared state. Not here.

## Step 4 — Three small default fixes

1. **Trusted hosts (QB2):** `SYMFONY_TRUSTED_HOSTS` declared (`backend plain -`) and
   commented in `.env.example`; `env check` warns, production stacks only, when it is unset:
   "any Host header is accepted; set it to the app's domain (regex, e.g. `^example\.org$`)".
   🔍 how env-check tells a production stack (the resolved `APP_ENV` of the backend).
2. **Plain `DATABASE_URL`:** the manifest's derived template without `serverVersion` (and
   without `charset` if step 0.4 shows UTF-8 either way). `doctrine.yaml` already sets
   `server_version`. Existing `.env` files keep working (the derived check looks for the
   source values, not the exact string): 🔍 confirm with an old `.env`. `~/infra`'s
   provisioning script prints the old form: it is a separate repository, so a note in the
   guide, never an edit from here.
3. **The gateway's own 502 in JSON** on `/api*` and `/health` (B9): `handle_errors` in
   `gateway/Caddyfile`, `Content-Type: application/json`, body `{"error":"backend unavailable"}`;
   everything else keeps Caddy's default. 🔍 re-check `handle_errors` fires on a dial failure
   to the upstream and on a timeout, and does not swallow a 502 the backend itself returns.

## Step 5 — The contract, as a product document

**File:** new `docs/oliva/backend-contract.md` (product: apps read it). English.

Built from the default **as it now behaves**, not from intentions:

1. **Preamble (B1):** behaviour, not connectivity; what each connection value does not
   guarantee.
2. **Clauses table:** clause, requirement, mandatory or recommended or declared, how it is
   checked (suite assertion id, guard, or "declared, verified for the default at release").
   Mandatory: Image and targets (`dev`, `prod`, `staging`), Server (`:80`, `GET /health`
   200 JSON, no I/O, no auth), Migrate (`oliva-migrate`: idempotent, non-zero on failure,
   safe twice at once if transactional), Seed (`oliva-seed` in `dev`/`staging`, absent from
   `prod`, replaces data), Signals (SIGTERM, clean exit within the grace period).
   Recommended: logs on stdout, plain `DATABASE_URL`, trusted hosts. Declared: trusted
   proxies, in-flight draining, request isolation (B3: the default resets services; statics
   are the app's).
3. **Database (B4)**, **queue (B5, declared: `PhpSerializer`, the worker is coupled to the
   backend's language)**, **realtime (B6: publish by HTTP POST with a JWT, or not at all)**,
   **error envelope (B9)**, **the combination matrix (B10)**, **CORS in one line (B12)**,
   **schema ownership (Q1: replacing the backend is greenfield)**.
4. Linked from the guide and the README template.

## Step 6 — The conformance suite

**Files:** new `scripts/oliva/conformance.sh`; `oliva` (verb `conformance`); a throwaway
compose file for the harness (under `scripts/oliva/`, owned).

1. **Harness:** its own project name (`<app>-conformance`), a `pgvector` database, the image
   under test (default: this checkout's `prod` image) run as `migrate`, `backend`, and a
   `gateway` built from Oliva's gateway. No host ports (it talks from a helper container on
   the harness network), so it never collides with a running dev stack. Always torn down
   (`trap`), volumes included.
2. **Assertions** (ids are what the contract cites):

   | Id | Assertion | Kind |
   |---|---|---|
   | K1 | `GET /health` on `:80`, plain HTTP: 200, JSON | mandatory |
   | K2 | the same with the database stopped (liveness has no I/O) | mandatory |
   | K3 | `oliva-migrate` on a fresh database: exit 0; again: exit 0 (idempotent) | mandatory |
   | K4 | two `oliva-migrate` at once: at most one non-zero, the schema intact (re-run exit 0) | mandatory |
   | K5 | `oliva-migrate` with an unreachable database: non-zero, within a bound | mandatory |
   | K6 | `oliva-seed` absent from the `prod` target; present in `staging` | mandatory |
   | K7 | SIGTERM to an idle backend: exits (not SIGKILL) within the grace period | mandatory |
   | K8 | a plain `postgresql://` `DATABASE_URL` accepted (K3 and K1 pass with it) | recommended |
   | K9 | something on stdout/stderr after a request | recommended |
   | K10 | gateway: a forged `X-Forwarded-For` from outside the trusted ranges is not forwarded as trusted | mandatory (gateway, Oliva's) |
   | D1, D2 | trusted proxies, in-flight draining | declared: printed as "declared, not tested" on every run |

3. **Output:** one line per id (`PASS`, `FAIL` with the reason, `DECLARED`), mandatory
   failures exit non-zero, recommended ones warn.
4. ⚠ **Negative controls (the rule of this phase), at the gate, each must make its
   assertion FAIL:** a `/health` that queries the database (K2); a migrate that exits 0 on
   error (K5); a `prod` image with an `oliva-seed` (K6); a PID 1 that ignores SIGTERM (K7,
   the 1.10.0 behaviour); a gateway with `trusted_proxies` wide open (K10). Small scratch
   images (busybox, caddy) or scratch builds; recorded in the epic, not committed.

## Step 7 — CI and the verb

1. CI job `conformance`: builds the `prod` image (bake cache) and runs the suite. 🔍 its
   time; the job must stay well under the tests job.
2. `./oliva conformance [image]`: default image from this checkout, or any image tag. Help
   text names the contract document.

## Step 8 — Docs and upgrade notes

`UPGRADING.md` 1.12.0, labelled: `[merge]` the target rename in the shared override; the
seed command in `deploy-staging.sh` is Oliva's (nothing for the app); `[decision]` set
`SYMFONY_TRUSTED_HOSTS` on production hosts (guard: env). The guide (targets, seeding,
trusted hosts, the contract link), concepts if needed, the epic, the friction log.

## Step 9 — Gates

- `verify` green on this checkout; the suite green on the default; every negative control
  red on its assertion.
- The two declared clauses re-measured for the default (step 0.7), numbers in the epic.
- Shared-infra simulation: `deploy.sh` and `deploy-staging.sh` (seeding through `oliva-seed`).
- Sync rehearsal on a copy of the third app (now on 1.11.0) against a scratch 1.12.0 cut:
  every manual step is a labelled action or a bug.
- CI green after the push (the maintainer pushes).

## Step 10 — Release (only with the maintainer's OK)

As phase A.

## Things to re-evaluate, not just execute

| # | Assumption | Why it might be wrong | When |
|---|---|---|---|
| RB1 | bake honours the backend's new `additional_contexts` | it did for `realtime`; the backend has more stages | step 3.2 |
| RB2 | `pdo_pgsql` without `charset` talks UTF-8 | client encoding follows the server's default, which an external Postgres may set otherwise | step 0.4 |
| RB3 | `handle_errors` covers dial failures and timeouts but not a backend's own 502 | Caddy distinguishes proxy errors from upstream responses; to measure | step 4.3 |
| RB4 | The harness needs no host port | the helper container must reach the gateway and the backend by name | step 6.1 |
| RB5 | Every assertion can fail | an assertion with no failing backend is theatre | step 6.4 |
| RB6 | Renaming the targets costs one cold rebuild and nothing else | caches keyed on the stage name | step 1.3 |
