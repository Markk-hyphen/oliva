# Epic — Config contract: every variable has an owner, a slot and a home

> **Status:** 📋 designed, not started ·
> **Target version:** v1.6.0 (absorbs the unreleased 1.5.2 security bumps) ·
> **Origin:** framework review, 2026-11-14.

## Problem

### The incident

`.env.backend` is tracked and is loaded **after** `.env`, so it wins. It carries
`APP_SECRET`, `JWT_PASSPHRASE`, `MERCURE_PUBLISHER_JWT_KEY` and
`MERCURE_JWT_SECRET`. Measured with `docker compose config` on the prod stack:
all four resolve to the committed values, whatever `.env` says. The repo is
public and both existing apps carry the same values in their `HEAD`.

Consequences for any app deployed as documented:

- Anyone can sign a publisher or subscriber JWT for the app's Mercure hub.
- Everything Symfony signs with `APP_SECRET` can be forged.
- Filling in `.env` by hand (what `README.md` tells you to do) changes nothing,
  and nothing says so.

No error, no warning, a green `verify` and a green CI. By Oliva's own rule this
is a bug in Oliva.

### The cause behind it

Nothing in Oliva states **which variable belongs to which service, whether it
is a secret, or which file it lives in**. The knowledge is spread over
`.env.example`, `.env.backend`, `backend/.env`, a heredoc in `ci.yml`, a README
table and comments. Four separate symptoms come from that one gap:

| Symptom | Where |
|---|---|
| Committed secrets override local ones | `.env.backend` after `.env` in `env_file` |
| Silent fallbacks to public defaults | `backend/.env` (`APP_SECRET=changeme`, baked by `dump-env prod`), `{$MERCURE_PUBLISHER_JWT_KEY:!ChangeThisSecret!}` in the Caddyfile |
| The `frontend` container receives every backend secret | its `env_file` includes `.env` |
| A host edits a tracked file to deploy | runbook step 4: uncomment `DATABASE_URL` in `.env.backend` |

### Why this is roadmap work, not only a fix

Item 2 says each role is a slot with a contract, and that *writing the contracts
down* can start before the installer exists. For most slots the contract **is**
its variables: `DATABASE_URL` for the database, an AMQP DSN for the queue, a JWT
key for realtime. A service can't be cleanly absent while nobody knows which
variables go away with it, and a replaced one can't be announced while nobody
knows what it was supposed to provide. Item 3's installer will need this same
table to decide what to emit for `--queues` or `--shared-infra`.

So this epic writes the first slot contracts in executable form. It adds no
flags and no installer.

## Principles

1. **A tracked file never holds a secret.** Secrets live in `.env`
   (gitignored), and in `.env.staging` for staging. Tracked env files hold
   non-secret defaults only.
2. **One variable, one home.** No variable is defined in two layers that can
   disagree. Where derivation is possible (`DATABASE_URL` from `POSTGRES_*`), it
   is derived once by the tool, not typed twice.
3. **Check what resolves, not what is written.** The check asks Compose for the
   resolved environment of each service (as `cron-guard` already does). Parsing
   `.env` would have passed the incident above.
4. **No public fallback.** A missing secret must fail, not quietly become
   `changeme`.
5. **Default asks for nothing, replaced is loud, absent is silent** — applied
   per slot in the check's output.

## Design

### File layout after the epic

| File | Tracked | Holds |
|---|---|---|
| `.env.example` | yes | every variable with a placeholder; generated from the manifests |
| `.env` | no | the machine's real values, secrets included. Also what Compose interpolates |
| `.env.backend` | yes | non-secret backend defaults (`SERVER_NAME`, `HTTP_PORT`, `CADDY_*`, `MERCURE_URL`…) |
| `.env.frontend` | yes | non-secret frontend defaults; the **only** env file of `frontend` |
| `.env.staging` | no | staging overrides (`DATABASE_URL`) |
| `.env.prod` | — | deleted (a `#TODO` nobody reads) |

Shared infra stops editing `.env.backend`: the host's `.env` simply carries the
provisioned `DATABASE_URL`.

### The manifests

- `scripts/oliva/env.manifest` — Oliva-owned, the framework's variables.
- `env.manifest` at the repo root — **the app's extension point**, shipped
  empty. An app declares its own variables there (`MAILER_DSN`,
  `ANTHROPIC_API_KEY`), so the same check covers them. Oliva never changes it.

One line per variable, readable with bash + awk (the host has no `jq`):

```
# NAME                       SLOT      KIND      VALUE
APP_SECRET                   backend   secret    gen:hex32
JWT_PASSPHRASE               backend   secret    gen:hex32
MERCURE_PUBLISHER_JWT_KEY    realtime  secret    gen:hex32
MERCURE_JWT_SECRET           realtime  secret    same:MERCURE_PUBLISHER_JWT_KEY
POSTGRES_PASSWORD            database  stateful  gen:hex16
DATABASE_URL                 database  derived   postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@database:5432/${POSTGRES_DB}?serverVersion=${POSTGRES_VERSION}&charset=utf8
RABBITMQ_PASSWORD            queue     stateful  gen:hex16
RABBITMQ_DSN                 queue     derived   amqp://${RABBITMQ_USER}:${RABBITMQ_PASSWORD}@rabbitmq:5672/%2f
```

Kinds: `secret` (generated, safe to rotate), `stateful` (a secret bound to a
volume: rotating the variable alone locks the app out of its own database),
`derived` (computed from others), `plain`.

Slot names are the ones in the roadmap table. A slot is **active** when its
service is in `docker compose config --services`; the variables of an inactive
slot are not required and print nothing.

### `./oliva env init`

Replaces `cp .env.example .env` in the README, the runbooks and CI.

- No `.env`: creates it, generates every secret, derives every derived value.
- Existing `.env`: touches only what is missing, a placeholder or a publicly
  known value. Never rewrites a healthy value. Idempotent.
- Never rotates a `stateful` variable on an existing `.env`; prints the manual
  procedure instead.
- When it replaces `JWT_PASSPHRASE` and a key pair already exists, it
  re-encrypts the private key with the new passphrase, so nobody is logged out
  and login doesn't break. (To be proven in phase 2; if it can't be made
  reliable, it stops and prints the fix.)

### `./oliva env check`

Read-only. For each active slot, on the **resolved** environment:

| Finding | Example message ends with |
|---|---|
| secret missing or empty | `→ ./oliva env init` |
| placeholder (`your_…`, `generate_with_…`, `changeme…`) | `→ ./oliva env init` |
| publicly known value | `→ ./oliva env init` (the value is in a public git history) |
| secret present in a tracked file | `→ move it to .env, never commit it` |
| derived value disagrees with its sources | `DATABASE_URL` vs `POSTGRES_*` |
| secret reaches a service that doesn't own it | backend secrets in `frontend` |
| slot replaced | `database: REPLACED (external host "postgres") — credentials not checked by Oliva` |

Publicly known values are kept as SHA-256 hashes in
`backend/frankenphp/known-public-secrets.sha256` (inside the backend build
context, so the image can read the same list). It includes every value that was
ever committed and the CI ones, forever.

### Where it runs, and how hard

| Place | Behaviour |
|---|---|
| `doctor` | new step `env`; reports, never fails |
| `verify` | step `env`; **fails** (this is the guard for the upgrade action) |
| `deploy.sh` (prod) | **aborts before `down`** on a missing, placeholder or public secret: the old stack keeps serving |
| `deploy-staging.sh` | warns |
| backend entrypoint | with `APP_ENV=prod`, refuses to boot on a public or placeholder secret. Covers the standalone path that never runs `deploy.sh` |
| CI, new job `tracked-secrets` | fails if a tracked file assigns a real value to a variable any manifest marks secret. Stops the regression where an agent "fixes" a boot error by committing the secret |

This is the first guard that aborts a deploy. The rule from 1.5.0 (guards warn)
stays for everything else; the exception is written down with its reason: here
continuing is the damage.

### For the agent at the keyboard

- Every message names the command that fixes it.
- `AGENTS.md` gets a short rule set: secrets go in `.env` only; a new variable
  is declared in `env.manifest` in the same commit; when a variable "doesn't
  take", run `./oliva env check` before editing anything.
- `owned-paths.txt`: `scripts/oliva/env.manifest` is Oliva's, `env.manifest` is
  listed as an extension point.

## Phases

Each phase ends in a commit with its gate passed.

1. **Stop the leak.** Secrets out of `.env.backend`; `frontend` loses `.env`;
   no fallback in the Caddyfile; hash list. *Gate:* prod `config` resolves every
   secret from `.env`; `frontend` resolves none; `verify` green.
2. **Manifest + `env init`.** *Gate:* fresh clone → `init` → `docker compose up`
   healthy; a second `init` changes nothing; an old `.env` with public values is
   repaired and login still works with the existing key pair.
3. **`env check` + wiring** into `doctor`, `verify`, `deploy*`, entrypoint.
   *Gate:* each finding in the table reproduced on purpose and caught; prod
   deploy with a public secret aborts with the old stack still up; `doctor`
   survives Docker down.
4. **CI.** `env init` replaces the heredoc; `tracked-secrets` job. *Gate:* a
   branch that commits a secret goes red.
5. **Docs + release.** README, `AGENTS.md`, runbooks, `UPGRADING.md` `## 1.6.0`
   with guarded actions (`[merge]` resolve `.env.backend`; `[local, guard: env]`
   and `[host, guard: env]` run `env init`). `release 1.6.0`.
6. **Apps** (separate sessions, one each): sync, rotate, and move their own
   keys from `.env.backend` to `.env` + `env.manifest`.

## Out of scope

- **Install flags and `oliva new`.** Item 3; still waits on the friction log.
- **The production `worker` and the "queues forgotten" guard.** Next epic: the
  queue slot isn't complete until something consumes. Here only the reverse is
  checked (profile on ⇒ its variables are set).
- **Rewriting git history** to remove the old values. They are public; the fix
  is rotation plus the hash list.
- **A secrets manager** (Vault, SOPS, Docker secrets). `.env` on the host is the
  scale Oliva runs at.
- **Declaring replaced slots by flag.** Replacement is inferred from the
  resolved state for now; declaration arrives with item 3.
