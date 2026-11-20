# Epic — The backend slot: split the lifecycle, write the contract, make replacement declared

> **Status:** phase A ✅ released in **1.11.0** (2026-11-20, CI green;
> [`E-backend-slot-runbook.md`](E-backend-slot-runbook.md)). Phase B 🧭 designed, decisions
> QB1–QB3 taken, runbook [`E-backend-slot-runbook-b.md`](E-backend-slot-runbook-b.md), target
> 1.12.0. Phase C: design notes below ·
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

### Decisions for phase B (2026-11-20, the maintainer's)

| # | Question | Decision |
|---|---|---|
| QB1 | Conformance clauses with nothing observable from outside in the default backend: "trusts `X-Forwarded-*` only from private networks" (its effect shows in login throttling, which the default does not ship) and "SIGTERM lets an in-flight request finish" (every default request takes milliseconds) | **Phase B tests what is observable from outside**, the same way for any backend: liveness without the database, `oliva-migrate` (fresh, twice at once, re-run, unreachable database), `oliva-seed` absent from `prod`, idle SIGTERM, plain `DATABASE_URL`, HTTP on `:80`, logs on stdout. The `X-Forwarded-For` half that lives in the gateway (Oliva's) is tested there. The two clauses stay **declared**, verified for the default at release gates. **Not because no second backend exists** (the point of the epic is that one can), but because of ownership and attack surface; the intermediate design below is phase C's |
| QB2 | `SYMFONY_TRUSTED_HOSTS` default | **Unset** (today's behaviour), declared in the manifest; `env check` **warns in production** when it is unset and names the fix |
| QB3 | Where the suite runs | **Always in CI** against the default image, plus **`./oliva conformance [image]`** on demand (what a replaced backend runs). Not inside `verify`: the dev loop stays as fast |
| QB4 | B-F3: how far the gateway trusts `X-Forwarded-*` (decided after step 0) | **Option C: topology-aware default plus a warning.** A standalone production stack trusts no proxy at the gateway (it is the edge, nothing is in front); the shared-infra overlay trusts the private ranges again (the edge proxy is there). `env check` warns on a standalone production stack whose gateway trust was opened again. K10 tests it. `data_net` peers reaching the backend directly stay a threat-model note (every app has the same owner) |

### Phase C design notes (recorded 2026-11-20, to apply when phase C starts)

**A probe for the two declared clauses, without dirtying ownership or growing the attack
surface.** The maintainer's constraint: the system has to be ready for other backends, so
"no second backend exists yet" is not an argument; the real costs are ownership and attack
surface. The intermediate design to evaluate first in phase C:

- **Never routed by the gateway.** It lives under a prefix the gateway does not route
  (`/_oliva/…`; the gateway routes only `/api`, `/health`, `/.well-known/mercure` to
  backends), so even if left on it is unreachable from outside the app's private network.
- **Off unless the conformance harness turns it on**, with a variable only the throwaway
  conformance stack sets (never in dev, staging or production compose files), and the env
  check errors if that variable ever reaches a real stack.
- **In Oliva-owned files, not the app's `src/`.** For the default, served from Oliva's side
  (the backend Caddyfile or a file under `backend/frankenphp/`), so an app never edits or
  owns it. To check first: whether it can exercise Symfony's own trusted-proxy handling
  without living in the app's kernel (if it only reads the environment variable, it tests the
  configuration, not the framework, and says so).
- **For a replacement: recommended, not mandatory.** A replacement that implements it gets
  the two clauses tested; one that does not gets them reported, every run, as "declared, not
  tested". Never silent.
- What it would answer: the client address the backend resolved for a request carrying a
  forged `X-Forwarded-For` (from inside and outside the private ranges), and a request that
  takes a known time (to send SIGTERM while it is in flight).

**The universal template, made concrete at birth.** `./oliva init --backend=external` writes,
in the app's own files, a contract card to fill (mandatory clauses first, then recommended),
with placeholders where a value is needed (the image, the migrate and seed commands, the
health path). Every clause is then visible in three places: the card, `doctor` (which clauses
are mandatory and failing, which recommended and unmet, which declared and untested) and
`verify`/CI through `./oliva conformance`. Mandatory clauses block a deploy (Q3); recommended
ones warn on every run; declared ones are announced on every run. The default backend fills
the card out of the box.

## Phase B results

**Step 1 — slot-neutral targets (2026-11-20).** `frankenphp_dev`/`frankenphp_prod`/`frankenphp_staging`
→ `dev`/`prod`/`staging` in the Dockerfile, the compose files, the scripts and the live docs
(old `UPGRADING.md` sections, `agent-commits.md` and closed epics keep the old names as
history). `frankenphp_upstream`/`frankenphp_base` kept (internal, parsed by the scripts).
A leftover old name fails loudly: `target stage "frankenphp_dev" could not be found` (rc 17).
Prod and staging build; the rename invalidated no cache (the prod image came out identical:
RB6 closed). `verify` all green.

**Step 2 — `oliva-seed` (2026-11-20).** `backend/frankenphp/seed.sh`, copied in the `dev`
and `staging` stages only. Group = `OLIVA_SEED_GROUP`, else the environment. Measured: present
in `dev` and `staging`, **absent from `prod`** (`docker run --entrypoint oliva-seed` → 127),
next to the fixtures bundle already missing there (P4); dev seed purges and loads the `dev`
group; `OLIVA_SEED_GROUP=staging` switches it; an unknown group fails (rc 1, "Could not find
any fixture services"), as the contract's "fail on an incompatible target" asks.
`deploy-staging.sh` calls `oliva-seed` (measured end to end at the gates, step 9).

## Phase B baseline (step 0, 2026-11-20, on 1.11.0)

Scratch clone of `main` at `330c3f6`, production stack, a scratch controller (`/api/gt/ip`,
`/api/gt/slow`) for 0.7 only, never committed. What the suite must later reproduce.

| # | Question | Answer |
|---|---|---|
| P1 | `/health` with the database stopped | 200 `application/json` `{"status":"ok"}`, direct and through the gateway; the backend stays `healthy` 35 s later. Liveness has no I/O |
| P2 | `oliva-migrate`, database unreachable | exit 1 after 68 s |
| P3 | `oliva-migrate`, **wrong password** | exit 1 after 67 s too: an authentication failure is retried 60 times although waiting cannot fix it (the exit-255 shortcut does not catch it), and the last line printed is `dbal:run-sql`'s usage text, not the error (finding B-F1) |
| P4 | Seeding in prod | `doctrine:fixtures:load` not defined (rc 1); `oliva-seed` does not exist yet |
| P5 | A plain `DATABASE_URL` (`postgresql://u:p@database:5432/app`) | `oliva-migrate` exit 0, the same as with `?serverVersion=15&charset=utf8`; the parsed parameters carry no `serverVersion` and nothing breaks (`doctrine.yaml` sets it) |
| P6 | Client encoding without `charset` | UTF8 on a UTF8 database **and on a `SQL_ASCII` one** (where `psql` reports `SQL_ASCII`): without `charset` the driver gets the cluster's default `client_encoding` (UTF8, `source=default`). On an external Postgres whose cluster default was changed, it would follow that (finding B-F2) |
| P7 | Gateway with the backend stopped | `/api/x` and `/health`: **502, empty body, no `Content-Type`**; `/` still served |
| P8 | Gateway `X-Forwarded-For`, echo upstream, host at `172.19.0.1` | default `private_ranges`: a forged `6.6.6.6` is forwarded as `6.6.6.6, 172.19.0.1` (the host is a private peer, so trusted); `GATEWAY_TRUSTED_PROXIES` narrowed to a range without the host: forwarded as `172.19.0.1`, the forgery dropped |
| P9 | Client IP Symfony resolves | through the gateway, forged: `6.6.6.6`; straight to the backend from any container on the app network, forged: `6.6.6.6`; with `SYMFONY_TRUSTED_PROXIES=127.0.0.1`: the peer (`172.19.0.2`). The trust does what it is configured to do; the breadth of the configuration is the question (B-F3) |
| P10 | SIGTERM during a 3 s request, worker mode, ×2 | the response completes (200, `slept` 3.0), the stop waits the remainder (2.4–2.5 s), exit 0. The declared draining clause holds for the default |

**B-F3, the one that matters.** Both hops trust every private peer by default (gateway
`private_ranges`, backend `PRIVATE_SUBNETS`). Right behind the shared-infra edge proxy. But:
(a) in a **standalone** production stack the gateway is the edge, and whether it sees the
client's real address or a Docker bridge address (private, so trusted) depends on how Docker
publishes the port on that host (NAT keeps the client address; a userland proxy does not).
If it sees a bridge address, anyone can forge their IP and login throttling is void. Not
measurable without a real host; to verify on one. (b) In shared infra, any container of any
app on `data_net` can reach this backend directly with a forged header (noted in phase A as
a threat-model line; P9 confirms the mechanism). Decision needed before step 4 (see the
runbook's step 0 outcome).

## Phase A baseline (step 0, 2026-11-20, on 1.10.0)

Scratch clone of `8239ab0`, project `m1`, this machine. The numbers phase A is compared to.

| # | Measurement | Result |
|---|---|---|
| B1 | Prod stack, a migration that fails (`SELECT 1/0`), no profiles, `up -d --build` as `deploy.sh` runs it | **rc 0.** Backend `Restarting`, 8 restarts in 25 s, the error only in its log. Gateway `healthy`. `GET /health` through the gateway: `502` with **no content type** (input to B9) |
| B2 | Same, `COMPOSE_PROFILES=realtime` | rc 1, `dependency failed to start: container m1-backend-1 is unhealthy` |
| B3 | `docker compose stop`, dev | worker 10.3 s exit 137; realtime-relay 10.3 s exit 137; backend 0.2 s; gateway 0.3 s; realtime 0.2 s (all exit 0) |
| B4 | Same, prod (worker mode) | worker 10.2 s exit 137; realtime-relay 10.3 s exit 137; backend 0.2 s exit 0 |
| B5 | Dev reload, classic mode, three runs | a controller edit visible after 1.6 / 0.9 / 2.9 s (opcache's default `revalidate_freq` of 2 s); a `services.yaml` parameter after 0.36 / 0.37 / 0.39 s |
| B6 | Cold `up -d --wait`, images built | dev 17.4 s (no profiles), 23.3 s (`queues,realtime`); prod 16.8 s, 22.8 s |

Consequence for the runbook: step 7's reload criterion is "no worse than B5", not an
absolute 2 s, since classic mode already reaches 2.9 s.

## Phase A results

**Step 1 — `pcntl` (2026-11-20).** R1 closed: `pcntl` loads in FrankenPHP's own SAPI
(`extension_loaded` true from a request, dev classic and prod worker mode), no new log
lines, 50/50 and 100/100 `/health` at 200, `verify` all green on this checkout.

| # | Measurement | Before (B3/B4) | After |
|---|---|---|---|
| S1 | Worker stopped during a handler doing a 4 s Postgres query + 3 s CPU, dev ×2 and prod | 10.2–10.3 s, exit 137 | 5.4 / 5.9 s (dev), 5.7 s (prod), exit 0; the handler ran to its end; queue 0 ready, 0 unacked |
| S2 | Handler longer than the grace period (14 s query) | — | SIGKILL at 10.2 s, the message back in the queue, handled on restart: **at least once, never lost** |
| S3 | Relay idle stop, ×3 dev, ×1 prod | 10.3 s, exit 137 | 0.2–0.3 s, exit 0: the LISTEN wait does not hold the signal |
| S4 | Backend stop, prod | 0.2 s | 0.3 s |
| S5 | A signal during `sleep()` in a handler | — | `sleep(5)` returned after ~1 s: signals cut sleeps short. Written in the guide |
| S6 | Relay SIGKILLed mid-POST to a paused hub | — | the row stays delivered until `redeliver_timeout` (3600 s): a duplicate or a one-hour delay. Friction X18; graceful stops no longer cause it |

Grace period: none of Oliva's services needs more than 10 s, so no fixed
`stop_grace_period`. The worker gets `WORKER_STOP_GRACE_PERIOD` (default `10s`, project
`.env`): S2 shows an app with long handlers needs a knob, and without one its only way out
would be editing an Oliva file.

**Step 2 — `oliva-migrate` and concurrency (2026-11-20).** R2 closed: **no lock.**

| # | Measurement | Result |
|---|---|---|
| S7 | No database reachable | waits, gives up after 70 s (60 attempts), exit 1, the driver error on stderr |
| S8 | Two runs 0.5 s apart, fresh database, a migration of `pg_sleep(5)` + `CREATE TABLE` | one exit 0 (both migrations applied); the other exit 7, `Unique violation … (extname)=(vector)` (two concurrent `CREATE EXTENSION IF NOT EXISTS` race, a known Postgres behaviour). Each version recorded once, the table created once |
| S9 | Same with the extension already there (the usual case) | one exit 0; the other exit 7, `relation "race_probe2" already exists`, rolled back by `--all-or-nothing`. Each version once, the table once |
| S10 | A third run after the race | exit 0, `Already at the latest version` |

So the clause holds as "one wins, the other fails non-zero, nothing half-applied": Postgres
DDL is transactional and `--all-or-nothing` keeps the whole run in one transaction. The
loser's message points at the migration instead of at the race. A lock would turn it into
"wait, then nothing to do", at the cost of a PHP wrapper holding a session lock; not worth
it while a stack runs exactly one `migrate`. Does **not** hold for a migration that opts out
of transactions (`isTransactional(): false`, `CREATE INDEX CONCURRENTLY`): the app's choice,
one line in the guide.

**Steps 3–4 — the entrypoint lets go, the `migrate` service (2026-11-20).** One commit:
taking the migrations out of the entrypoint without the service would leave the repository
broken in between. JWT key generation stays in the entrypoint until step 6, for the same
reason. Nothing in `scripts/`, `docs/oliva/` or CI relied on `compose run backend …`
migrating as a side effect (grep).

| # | Measurement | Result |
|---|---|---|
| S11 | `config --format json`, five stacks (dev; prod; prod+shared-infra; prod+shared-infra+staging; prod+staging), `--profile '*'` | `migrate` with the right image and target in each, `healthcheck: disable`, `data_net` in shared infra and no `database` dependency there; backend, scheduler, worker and relay depend on `migrate: completed_successfully` in all five; worker and relay keep `backend: healthy`. R3 (the `!override` trap) closed |
| S12 | Staging with a marker `DATABASE_URL` in `.env.staging` | `migrate` resolves `APP_ENV=staging` and the staging database, like every other service |
| S13 | **M1 again, prod, no profiles, plain `up -d --build` (what `deploy.sh` runs today, no `--wait`)** | **rc 1**, `service "migrate" didn't complete successfully: exit 7`; the backend stays `Created`, never started on a broken schema. Before: rc 0 and a restart loop (B1). Migration fixed: rc 0, everything healthy |
| S14 | Dev: a new migration added to a running stack, then `docker compose up -d --wait` | applied (rc 0, table created) |
| S15 | Dev: a broken migration added to a running stack | rc 1 with the migrate message; the running backend stays up and healthy |
| S16 | Two plain `up -d --wait` in a row | only `migrate` runs again; backend, worker and relay are not restarted |
| S17 | `verify` on this checkout | all green; `migrate Exited (0)` |

**Step 5 — a real healthcheck, loud deploys (2026-11-20).** Measured with the real
`deploy.sh`/`deploy-staging.sh` on a local shared-infra simulation (`proxy_net`, `data_net`,
a `pgvector:pg15` container aliased `postgres`, a scratch app pointing `DATABASE_URL` at it).

| # | Measurement | Result |
|---|---|---|
| S18 | `deploy.sh`, healthy path | rc 0; `migrate` waited for the external Postgres and exited 0; backend healthy through its own `/health` (healthcheck `curl … /health`) |
| S19 | `deploy.sh`, a broken migration | rc 1, `service "migrate" didn't complete successfully: exit 7`, and the migration's SQL error printed by the script |
| S20 | `deploy.sh`, `/health` answering 500 (the backend starts but is not healthy) | rc 1 after 132 s, `container … is unhealthy`, the backend's access log printed. Before phase A, with no dependent profile, this deployed as OK |
| S21 | `deploy.sh` with no `/health` route | aborted **before `down`** by `backend_health_guard`; the running backend untouched (same start time) and healthy |
| S22 | `deploy-staging.sh`, healthy path | rc 0; `migrate` migrated the **staging** database; `fixtures:load --group=staging` purged and loaded; the production database untouched |
| S23 | `doctor`, failed and passed `migrate` | failed: exit code, the SQL error, the fix (`docker compose up -d --wait`); passed: `last run: exit 0 (<time>)` |
| S24 | The guard against this repository and the three apps (read only) | passes on all four; fails on a copy without `HealthController` |

R6 closed: every long-running service has a healthcheck except the frontend, which `--wait`
treats as ready once running, as `verify` already did. Not a regression; noted.

**Step 6 — JWT keys under provisioning (2026-11-20).** The pair lives in `./secrets/jwt` in
every environment, created by `./oliva env init`, mounted read-only into backend, worker,
scheduler and relay; the entrypoint no longer generates it.

| # | Measurement | Result |
|---|---|---|
| S25 | Fresh `env init` | pair generated, `private.pem` 0600 and `public.pem` 0644, owned by the host user; `env check` ok |
| S26 | Pair missing | `env check` error: "every login would fail → ./oliva env init" |
| S27 | Pre-1.11.0 dev pair only in `backend/config/jwt` | `env check` error naming the move; `env init` moved it, byte-identical private key, `env check` ok |
| S28 | Empty `secrets/jwt` owned by root | `env init` gave it back to the host user (through a root container) and generated the pair |
| S29 | Dev, `lexik:jwt:check-config` in backend, worker, relay | "correct" in all three; the nested `./secrets/jwt` mount wins over `./backend/config` (R5 closed) |
| S30 | Prod (root in the container), same command | "correct" in all three; the mount is read-only (`touch` refused); `secrets/jwt` still owned by the host user after the run (the root-owned gotcha is gone) |
| S31 | **Found on this checkout:** `secrets/jwt` root-owned 0600 from an older local prod run, plus a different pair in `backend/config/jwt` | the dev backend (uid 1000) could not read the key (`does not exist or is not readable`) while `env check` passed, since its passphrase check reaches root-owned keys through a root container. A silent failure: fixed in this step. `env check` now errors when the key is unreadable by the user the backend runs as (dev) and warns otherwise; `env init` gives such a directory back; a leftover pair in the old location is a warning ("no longer read, delete it"). After `env init`: `The configuration seems correct.` |
| S32 | `verify` on this checkout | all green |

**Step 7 — dev in worker mode (2026-11-20).** `worker.dev.Caddyfile` (the prod worker block
plus `watch` on `src/**/*.php`, `config/**/*.{yaml,yml,php}`, `.env`, `public/index.php`).
The gate stopped once, as Q4 requires; the maintainer chose option A (worker mode plus a
detector), recorded here.

| # | Measurement | Result |
|---|---|---|
| S33 | Patterns for `templates/` and `translations/` (absent in Oliva and in all three apps) | each floods the log on start (`watcher was closed prematurely` ×5, `giving up watching`). Removed: Twig checks template freshness on render in debug |
| S34 | Code reload (same probe as B5) | 0.01–0.32 s (classic: 0.9–2.9 s) |
| S35 | YAML reload, edits spaced 3 s, rename and in-place writes | 0.2–0.75 s, all six seen |
| S36 | Idle 120 s | 0 watcher restarts: no reload loop |
| S37 | Syntax error in a controller | readable error, recovery 0.06 s after the fix, no restart |
| S38 | Xdebug with a trigger, listener on the host | DBGp `<init … fileuri="file:///app/public/index.php">` received from a worker request |
| S39 | Request isolation smoke | a `ResetInterface` service is reset between requests (Symfony's `services_resetter` runs in dev workers); a `static` property leaks between users (`bob` sees `alice`). That leak class used to appear first in staging |
| S40 | **Code edit then YAML edit, back to back** | the old YAML value served (worker mode 2/8, then 9/30); `services.yaml` and the compiled container carry the **same mtime second**. Symfony's freshness check is in whole seconds, equal counts as fresh; `touch` triggers no watcher event. **Also in classic mode:** a stale container compiled in the same second as a restore was found after the classic run (1 in 17). Worker mode makes it far likelier because it recompiles right after each edit |
| S41 | Detector (`dev_cache_stale_check`: same whole second, later nanoseconds, for every path a `*.meta.json` tracks) against the real outcome | 44 runs: 10 true positives, 0 false positives, 34 true negatives, 0 false negatives; the printed fix worked 10/10 |
| S42 | `verify` `worker-mode` with `FRANKENPHP_CONFIG=` in `.env` | red; green again once removed |
| S43 | `verify` on this checkout (dev now in worker mode) | all green, `phpunit` included; `doctor` shows the cache line |

Healing it on its own (rather than detecting it) is friction X19, with a design to measure.

**Step 9 — gates (2026-11-20).** Besides the per-step measurements above:

| # | Gate | Result |
|---|---|---|
| G1 | `verify` on this checkout, final tree | 16 PASS, `ci-build` skipped (no extensions) |
| G2 | Shared-infra simulation, final tree: `deploy.sh` then `deploy-staging.sh` on a scratch app that had been deployed with the step-5 tree | `env check` caught the root-owned `secrets/jwt` the old entrypoint had left (the `[host]` action, for real); `env init` gave it back; both deploys rc 0; `lexik:jwt:check-config` correct in backend and relay; staging seeded; `secrets/jwt` still host-owned |
| G3 | **Sync rehearsal**, a copy of the third app (1.10.0) against a scratch 1.11.0 `release` cut exactly as `release.sh` does | `check` listed the 1.11.0 notes; `start`: **clean merge**, no conflict (its shared override carries services of its own); `doctor` showed the JWT error and its fix, and no unguarded pending action (correct: both are guarded); `env init` moved the app's own pair, byte-identical; `verify` all green, `ci-build` included (the app has PHP extensions); JWT correct in worker mode |
| G4 | Manual steps the sync needed | one: `./oliva env init`, the labelled `[local, guard: env]` action. Nothing unlabelled |
| — | Not run | the long-jump rehearsal on the first app (1.5.1 → 1.11.0, expected to hit X17 first); no CI run (the branch is not pushed) |

Found during the gates: the 1.11.0 note pointed at this epic, which apps do not carry; now
says so.

## Out of scope

OpenAPI (B7); correlation ids (A8); `kid` rotation (A2); connection budget beyond one line
(A7); a second default backend; Symfony 8.4 itself.
