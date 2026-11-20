# Epic — The backend slot: split the lifecycle, write the contract, make replacement declared

> **Status:** 🧭 designed, decisions taken 2026-11-20 (section "Decisions"). Phase A has a
> runbook: [`E-backend-slot-runbook.md`](E-backend-slot-runbook.md). No code yet ·
> Branch `feat/backend-slot` · **Origin:** roadmap item 2, "The backend: the
> hardest slot", and friction X16 (the phase-3 probe of `E-unbundle-roles.md`). Written
> 2026-11-20 against `main` at `6230607` (1.10.0), after reading the code, measuring the
> built images, and contrasting an external list of considerations (the "refuerzo" notes,
> referenced below by their ids D1–D4, A1–A10, B1–B12, C1–C10).

## The problem in one paragraph

The probe proved that the backend's **HTTP contract** is already replaceable: a non-PHP
server behind `GATEWAY_BACKEND_UPSTREAM` served `/health`, `/api` and `/` with the PHP
backend stopped. Everything else is not. The `backend` service carries two roles, the
**HTTP server** and the **database lifecycle** (wait-for-db, migrations, JWT keys), started
by a PHP entrypoint; Oliva's tooling (`verify`, `doctor`, `deploy-staging`, CI, `deps`,
the guards) reaches into the PHP container by name; and the files that would have to change
are Oliva's (`owned-paths.txt`). A replaced backend today *looks* clean and silently drops
the schema, the seed, and every check. That is a silent failure by Oliva's own rule.

## Findings (2026-11-20)

### Measured

| # | Finding | How |
|---|---|---|
| M1 | **A failed migration is reported as a successful deploy** in the default app (no `queues`/`realtime` profile). The entrypoint exits, `restart: unless-stopped` loops it, and `up -d` returns 0, so `deploy.sh` prints `>> OK`. With a dependent service (worker/relay `depends_on: service_healthy`) the same `up -d` fails loudly. Whether a deploy is loud depends on which profiles are on | throwaway compose: crash-looping service, `up -d` rc=0; same with a `service_healthy` dependent, rc=1 `dependency failed to start` |
| M2 | **The PHP containers ignore SIGTERM.** The image has no `pcntl`; PHP is PID 1 in `worker` and `realtime-relay` (`exec php …`). PID 1 without a handler ignores SIGTERM, so every `down`/deploy waits the full 10 s and SIGKILLs (exit 137), mid-message if one is in flight. Messenger's graceful stop needs `pcntl` (`Console\Application`: "Signals are not supported…") | `docker stop` on a PHP PID 1, directly and through `docker-entrypoint`: 10.1 s, exit 137 both times; `php -m` |
| M3 | **The seed guard is structural and holds.** `doctrine:fixtures:load` does not exist in the `prod` image (`command not defined`, rc 1) | `bin/console` in `oliva-backend:prod` |
| M4 | **Production runs FrankenPHP worker mode, dev runs classic.** `FRANKENPHP_CONFIG="import worker.Caddyfile"` in `frankenphp_prod` (and so staging), `""` in `frankenphp_dev`. A request-isolation leak can never show in dev. Symfony does reset services between requests (`services_resetter` in `HttpKernel\Kernel::boot`) | Dockerfile; vendor |
| M5 | No migration lock: `doctrine/migrations` 3.9.8 takes no advisory lock. Migrations run on **every** start of the backend container (restarts included), again in `deploy-staging.sh` (`docker exec … migrate`), and again in CI | grep of vendor; scripts |
| M6 | The backend healthcheck is **not** `/health`: the image's `HEALTHCHECK` curls Caddy's admin `:2019/metrics`, which proves Caddy is up, not that PHP or the app answer. "Migrates before it reports healthy" holds only because the entrypoint migrates before `exec frankenphp` | Dockerfile, compose files |
| M7 | Symfony reads `SYMFONY_TRUSTED_HOSTS` natively (`trusted_hosts` defaults to `%env(default::SYMFONY_TRUSTED_HOSTS)%`), like the proxies. Oliva sets no trusted hosts: any `Host` the gateway forwards is accepted | vendor `Configuration.php` |
| M8 | `DATABASE_URL`'s Doctrine-only parameter is redundant in the default: `doctrine.yaml` already sets `server_version: '15'`, yet the manifest's derivation and `~/infra/scripts/provision-postgres.sh` both append `?serverVersion=15&charset=utf8` | manifest, doctrine.yaml, infra script |

### Read, not measured

- **Hidden couplings X16 did not list:**
  - `backend/frankenphp/known-public-secrets.sha256` is read by `env-check.sh` (every
    `env check`, `verify`, deploy) and is a build context of `realtime/`. A fork that drops
    Oliva's `backend/frankenphp/` breaks the env contract and the hub's build.
  - `env-check.sh` reads secrets from the service **named** `backend` and checks JWT keys
    at `backend/config/jwt` and `secrets/jwt`.
  - The queue and realtime guards grep **PHP** (`messenger.yaml`, `#[AsMessage]`,
    `Symfony\Component\Mercure` in `backend/src`). Against a non-PHP backend they are
    blind and pass: a guard that passes on what it cannot see is a silent failure.
  - `deps.sh`, `release.sh` (`composer audit`), `lib.sh`, `test-db.sh`, the CI jobs
    (migrate, schema, phpunit, worker-mode, APP_ENV) all assume composer/Symfony.
  - `deploy.sh` prints the last log lines of `backend` and `gateway` on failure, by name.
- **The queue protocol is PHP-only.** No serializer is configured, so Messenger uses
  `PhpSerializer`: the worker is coupled to the backend's language by construction. The
  relay too (it unserializes a PHP `Update`).
- **Doctrine transport redelivery:** a relay SIGKILLed mid-handle (M2) leaves its row
  marked delivered until `redeliver_timeout` (Messenger's default is 3600 s). To measure:
  the worst case is a realtime event delayed an hour after a deploy.
- **Shared infra:** the backend joins `data_net`, shared by every app. A container of
  another app is inside `PRIVATE_SUBNETS` and could reach this backend by IP with a forged
  `X-Forwarded-For`. Same owner for every app today, so a threat-model note, not a fix.
- FrankenPHP (Go) handles SIGTERM itself; whether in-flight requests complete within
  Compose's 10 s is not measured.

### What the roadmap says that is no longer true

- Slots table, backend row, "Today": "carries the realtime hub" — not since 1.10.0.
- "The backend: the hardest slot": "the dev healthcheck is `kill -0 1`" — that is the
  worker/scheduler/relay healthcheck; the backend's is `:2019/metrics` (M6), also not real.

## Contrast with the "refuerzo" notes

| Id | Verdict | Why |
|---|---|---|
| Premise "fix the default before writing the contract" | **Adopted** | M1, M5, M6 are exactly the default not honouring the contract the epic wrote in 1.9.0 |
| D1 schema = implementation | **Adopted** | Already implied by Database being backend-tied. Consequence written loud: replacing the backend is a greenfield choice made at birth, not a migration path |
| D2 taxonomy | **Adopted, reshaped** | Not a fourth state. The real gap is the *family*: worker, scheduler, relay, queue and database are backend-tied, so they follow the backend's state. See decision Q2 |
| D3 worker vs classic | **Answered by the code** | Prod is already worker mode (M4). The open point is dev/prod parity, not the choice |
| D4 contract for discipline first | **Adopted** | The contract's first beneficiary is the default (M1, M2, M6). Minimal honest contract over complete fiction |
| A1 migrations out of startup | **Adopted, stronger** | Beyond replicas (Oliva runs one): it is X16's core coupling, and the source of M1. Lock as belt only |
| A2 JWT/Mercure out of the entrypoint | **Partly wrong** | "Every recreation invalidates sessions" is false: keys persist in `./secrets/jwt` (prod) and the `backend/config` bind mount (dev), and `env check` verifies the passphrase opens them. The Mercure key is never generated in the entrypoint. Moving key generation to `./oliva env init` is still right (provisioning, not boot; lets worker/relay mount keys). `kid` rotation: **deferred**, no current need |
| A3 liveness vs readiness | **Adopted, simplified** | `/health` stays liveness without I/O, and becomes the healthcheck (M6). The DB gate is the migrate step completing, not a readiness endpoint |
| A4 trusted proxies/hosts | **Mostly done in 1.9.0**; trusted hosts **adopted** | CIDR (`PRIVATE_SUBNETS`), bounded headers (`for, port, proto`), no published backend port: already true. Missing: trusted hosts (M7) |
| A5 SIGTERM | **Adopted, confirmed broken** (M2) | |
| A6 request isolation | **Adopted as a test** | Symfony resets; the gap is that dev never exercises worker mode (M4) |
| A7 connection budget | **Deferred** | Real in shared infra; there is no VPS. One line in the database contract |
| A8 correlation id | **Out of scope** | An observability item across all slots, not the backend's |
| A9 timezone | **Moot under D1** | Two writers to one schema is exactly what D1 rules out |
| A10 pgvector | **Already decided** | First migration (standalone) and provisioning (shared infra). Under a replaced backend the extension is the database slot's, not a migration's |
| B1 behaviour, not connectivity | **Adopted** as the contract's preamble | |
| B2 runtime contract | **Adopted, minimal** | Image, targets, PID 1 signals, stdout logs, writable paths |
| B3 request isolation | **Default-only clause** | A Go server gets it free; it is the default's discipline |
| B4 database contract | **Adopted, short** | |
| B5 queue | **Declare only** | Worker is language-coupled (PhpSerializer). Declared, not redesigned |
| B6 realtime | **Mostly done in 1.10.0** | SSE through the gateway measured; the relay on a Doctrine transport is an outbox. New: a replaced backend publishes to the hub directly (HTTP POST + JWT) |
| B7 OpenAPI | **Deferred** | Matters when frontend and backend are replaced independently |
| B8 seed | **Adopted** | Keep the structural guard (M3); generalise it to "the prod image has no seed entrypoint" |
| B9 error envelope | **Adopted, small** | The gateway answers its own HTML 502 on `/api` |
| B10 combination matrix | **Adopted**, inside Q2 | |
| B11 ownership by layers | **Adopted, simplified** | Ownership by slot state, not five categories |
| B12 CORS | **One line** | |
| C suite | **Adopted, subset**, and the key rule: the default must be able to fail it | C1, C3, C4, C9 + liveness, signals, migrate exit codes. C5, C6, C8 default-only or deferred |

## Symfony 8.4 LTS and this epic

`E-symfony-8-4-lts.md` targets 8.4 (≈ Nov 2027) for 8.1's HTTP-less applications and 8.2's
per-component bundles. They help **one axis** of this problem and not the other:

- **Splitting roles inside the PHP default: yes.** A migrate job, the worker, the relay and
  the scheduler are HTTP-less workloads; under 8.4 they boot without `HttpKernel`.
- **Replacing the backend with another stack: no.** That is about the contract, the
  tooling and ownership, none of which depends on how Symfony boots.

So this epic does not wait for 8.4. It should produce the **shape 8.4 slots into**: one
image, several entrypoints (`server`, `migrate`, `seed`, `consume`, `relay`, `cron`), each
its own process. When 8.4 lands, the non-HTTP entrypoints get lighter with no change to the
contract, the compose files or the tooling. Claims about 8.1/8.2 are from the stub's
sources and must be re-checked against symfony.com before that epic starts.

## Proposed design

### 1. The backend lifecycle leaves the server's entrypoint

- A one-shot **`migrate`** service: the backend image, command `oliva-migrate`
  (wait-for-db, then the migrations, as an advisory-lock-guarded run), `restart: "no"`.
- `backend` depends on `migrate: service_completed_successfully`; so do worker, relay and
  scheduler. A failed migration stops the stack from coming up instead of crash-looping.
- `deploy*.sh` use `up -d --wait`: a deploy is OK only when every healthcheck is green
  (fixes M1 for every profile combination).
- JWT key generation moves from the entrypoint to `./oliva env init`, which already owns
  the passphrase and re-encrypts the key.
- The backend healthcheck becomes `GET /health` on the app itself (M6).
- The entrypoint keeps only the production secret refusal.

### 2. Signals

`pcntl` in the base image, so Messenger stops between messages on SIGTERM. Then
`stop_grace_period` sized to the relay's notify wait. Measured before and after (M2).

### 3. The contract, written as a template the app fills (the "universal template")

Not prose. A **mandatory**, machine-checked card, because a replacement that skips part of
it fails silently somewhere. The default fills it out of the box; a replacement must.

| Clause | Requirement | Checked by |
|---|---|---|
| Image | `backend/Dockerfile` with slot-neutral targets `dev`, `prod`, `staging` (renamed from `frankenphp_*`) | compose build |
| Server | default command serves HTTP on `:80`, no TLS; `GET /health` → `200` JSON, no I/O, no auth | healthcheck, `verify` via the gateway |
| Migrate | executable `oliva-migrate` in every target: idempotent, non-zero on failure, safe if run twice concurrently (may be a no-op that exits 0) | the `migrate` service, conformance |
| Seed | executable `oliva-seed` in `staging` (and `dev`) only; **absent from `prod`** | conformance: `prod` image → not found |
| Signals | SIGTERM stops cleanly within the grace period | conformance |
| Logs | stdout/stderr | conformance |
| Proxies | trusts `X-Forwarded-*` from private networks only; honours `SYMFONY_TRUSTED_HOSTS` or equivalent | conformance (forged header from outside) |
| Database | accepts a plain `postgresql://` URL with no driver-specific parameters | conformance |
| Realtime | publishes by HTTP POST + JWT to `MERCURE_URL`, or not at all | declared |
| Queue / worker / scheduler | a replaced backend brings its own or runs without them | declared, see Q2 |

### 4. Replacement is declared, not inferred

The roadmap says "replacement is inferred there, not yet declared". This epic makes it
declared: the slot state lives in the app's marker (`.oliva-app`, e.g. `backend=external`),
written at birth by `./oliva init --backend=external` (item 3's first service flag).
Everything reads it:

- **`verify`/`doctor`/CI:** contract steps run for every backend; PHP steps run for the
  default and print `SKIP php-version (backend replaced: outside Oliva's net)` otherwise.
  Loud, never silent.
- **Guards:** the queue/realtime guards, blind on a non-PHP backend, become declarations
  (`OLIVA_QUEUE_CONSUMER=external` already exists as the pattern).
- **`sync.sh` and ownership:** `owned-paths.txt` gains slot tags. For an app with
  `backend=external`, Oliva's `backend/Dockerfile`, `backend/frankenphp/`, composer
  tooling and Symfony config stop being owned and stop travelling. Forks are not a
  constraint here (all of them are the maintainer's, none in production): the sync can be
  forceful, with a labelled action.
- **De-coupling first:** `known-public-secrets.sha256` moves out of `backend/frankenphp/`
  to `scripts/oliva/`; `env-check` reads the backend's environment through the slot, not
  the service name, where it matters.

### 5. Small default fixes that ride along

Trusted hosts via `SYMFONY_TRUSTED_HOSTS` (M7); `DATABASE_URL` without `serverVersion` in
the manifest and the infra script (M8); a JSON 502 from the gateway on `/api` and `/health`
when the backend is down (B9); dev in worker mode, or a CI/verify check that exercises it
(M4, pending Q4).

### 6. Conformance suite

A script that tests the backend **from outside**, image and HTTP only, the same for the
default and any replacement, and that the default can fail: liveness without the DB;
`oliva-migrate` twice concurrently; `oliva-seed` missing in `prod`; SIGTERM timing; a
forged `X-Forwarded-For` from outside the private networks; a plain `postgresql://` URL.
It runs in `verify` and CI against the default.

## Decisions (2026-11-20, the maintainer's)

| # | Question | Decision |
|---|---|---|
| Q1 | Schema: contract or implementation (D1) | **Implementation.** Replacing the backend is a greenfield choice at birth; the data loss is stated loudly. Not a migration path |
| Q2 | The backend-tied family | **It follows the backend.** Worker, scheduler and relay are replaced with it or absent. `absent` as a backend state (static site + gateway) is designed for, shipped later |
| Q3 | The template | **Mandatory where silence would hide a failure:** Server, Migrate, Seed, Signals block a deploy; the other clauses warn |
| Q4 | Dev/prod parity of FrankenPHP's mode | **Worker mode in dev too** (FrankenPHP's watcher reloads the workers). If the phase-A gate shows the dev loop degraded, stop and ask; no silent fallback to classic |
| Q5 | Phasing | **Three releases.** A (1.11.0): the default honours its own contract, nothing asked of a replacement. B: the written contract, the conformance suite, slot-neutral targets, decoupling and the small default fixes. C: declared state, `init --backend`, slot-aware ownership and tooling, then the phase-3 probe re-run against it |

**Measured after the decisions (shapes phase A):** with Compose 2.26, a one-shot `migrate`
service plus `depends_on: service_completed_successfully` behaves as needed. `up -d --wait`
returns 0 when it exits 0 and 1 with `service "migrate" didn't complete successfully` when
it fails; a second `up` re-runs it, so `docker compose up -d` still applies a new migration
in dev.

## Out of scope

OpenAPI (B7); correlation ids (A8); `kid` rotation (A2); connection budget beyond one line
(A7); a second default backend; Symfony 8.4 itself.
