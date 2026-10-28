# Sanity checks — a newcomer's guide

This is the shortest path to understanding how an Oliva checkout stays healthy,
written for someone who has **never seen this project before**. You don't need
to know Symfony, Docker Compose, or the update system to follow it.

There is exactly one entry point — the `./oliva` script at the repo root — and
all the checks run through it. Nothing here changes your code: the diagnostic
command is read-only, and the rest tell you *what to do* without doing it until
you ask.

> **If you only read one thing:** run `./oliva doctor` when you sit down. It
> prints a status board and never changes anything. Everything below explains
> what its lines mean and what you'd run next.

---

## The two moments

Oliva's health routine has just two moments in a work session:

```
         OPEN a session                    CLOSE a session
         ──────────────                    ───────────────
         ./oliva doctor                    git status -s
         (read the board,                  git log --oneline -3
          decide if anything               ./oliva verify   ← only if you
          needs acting on)                                    changed code
```

**Open:** `./oliva doctor` tells you where things stand before you touch
anything. **Close:** make sure you left nothing uncommitted, your last commit
message is clear, and — if you edited code — that it still passes the full local
smoke test.

---

## How the checks correlate

The single most important idea: **`doctor` only *reports*. You *decide*. The
other commands *act*.** `doctor` never fixes anything itself; it points at the
tools that do.

```
  ┌──────────────┐   reports    ┌──────────────┐   you run    ┌──────────────┐
  │ ./oliva      │ ───────────▶ │     YOU       │ ──────────▶ │ deps / sync / │
  │   doctor     │   a status   │   decide if   │   the right  │ verify        │
  │ (read-only)  │   board      │   it matters  │   command    │ (these ACT)   │
  └──────────────┘              └──────────────┘              └──────────────┘
```

So a healthy loop is: run `doctor` → read each line → for any line that says
something is due or wrong, run the command it points you to.

---

## What each check is

### `./oliva doctor` — the status board (read-only)

Run it first, every session. It collapses several independent checks into one
read-only board, and **no single line can break it** — it even runs with Docker
shut down (a failing step just prints `(no disponible)` and the next one
continues). What each section means:

| Section | What it tells you | If it looks wrong |
|---|---|---|
| **rama** | Which git branch you're on. | Expected `main` for Oliva itself. |
| **status** | Uncommitted changes (`git status -s`). | Empty = clean tree. Lines = you have work in progress. |
| **log** | Last 3 commits. | Sanity-check that the latest is what you expect. |
| **docker compose ps** | Which containers are running. | Empty is normal if you haven't run `docker compose up`. |
| **migraciones** | Pending database migrations. | `not running` just means the backend container is down — start the stack to see real status. |
| **deps due** | Whether the dependency cycle or the CVE audit is due (see below). | If it says **TOCA**, act — see `deps` rows below. |
| **acciones de upgrade** | Upgrade steps this machine hasn't acknowledged yet. | `ninguna` = nothing owed. Lines = do them, then `./oliva ack`. |
| **CI** | The last CI run on `main`. | `success` ✅. `failure` = CI is red even if your local build passed. |
| **sync check** | (Forks only) whether upstream Oliva moved ahead. | Skipped in Oliva itself — only appears when a `oliva-upstream` remote exists. |

### `./oliva deps due` — are the maintenance clocks due?

`doctor` already runs this, but you can run it alone. It reports **two separate
clocks**:

- **Dependency cycle (~45 days)** — keeps libraries fresh. When due → run
  `./oliva deps report`, then `./oliva deps update`.
- **CVE audit (~7 days)** — security. A vulnerability doesn't wait 45 days.
  When due → run `./oliva deps audit` (it checks composer, yarn, and the base
  Docker images with Trivy).

### `./oliva deps report` / `deps update` — the freshness cycle

`report` shows what's outdated (end-of-life, images, composer, yarn, actions,
CVEs). `update` bumps versions *within their allowed ranges*, re-runs `verify`,
and commits. Majors are done by hand, one per commit. You only run these when
`deps due` says the 45-day cycle is up.

### `./oliva deps audit` — the security scan

Runs the four-layer CVE scan on demand. Run it whenever `deps due` flags the
7-day security clock, regardless of the 45-day cycle.

### `./oliva verify` — the full local smoke test

This is the real "does it still work" check, and it **acts** (builds things). It
runs migrations, validates the Doctrine schema, runs PHPUnit, builds the
production image, and checks the running PHP version. Run it at the end of a
session **if you changed code**, before you consider the work done. CI runs the
same kind of checks on `main`, so a green `verify` locally and a green CI line in
`doctor` should agree.

### `./oliva sync check` — (forks only) did Oliva move ahead?

Only relevant in an **app built on Oliva** (a fork with an `oliva-upstream`
remote), not in Oliva itself. It reports whether the upstream framework has new
commits to pull in. In the Oliva repo this line is always skipped.

---

## What each command does *not* do

A common newcomer confusion is expecting `doctor` to fix things. It doesn't.
Here's the clean split:

| Command | Reads only | Changes files / state |
|---|---|---|
| `./oliva doctor` | ✅ (read-only board) | — |
| `./oliva deps due` | ✅ (just reports the clocks) | — |
| `./oliva sync check` | ✅ (just reports) | — |
| `./oliva deps report` | ✅ (shows what's outdated) | — |
| `./oliva deps audit` | ✅ (scans) | — |
| `./oliva deps update` | — | ✅ bumps versions + commits |
| `./oliva verify` | — | ✅ builds images, runs tests |
| `./oliva ack` | — | ✅ marks upgrade actions done on this machine |

---

## Usability checklist — run these in order, mark ✅ / ❌

If you're testing how easy the system is to pick up cold, go top to bottom.
Each row is one action and what you should see. Mark ✅ if it was obvious and
worked, ❌ if you got stuck or confused (note *why* — that's the useful signal).

| # | Do this | You should see | ✅ / ❌ | Notes if ❌ |
|---|---|---|---|---|
| 1 | From the repo root, run `./oliva help` | A grouped command list (Framework / Operación / Diagnóstico). | ☐ | |
| 2 | Run `./oliva doctor` | A status board with sections: rama, status, log, docker, migraciones, deps due, acciones de upgrade, CI, sync check. | ☐ | |
| 3 | Read the **status** section | Empty if the tree is clean; otherwise a list of changed files. Do you understand which it is? | ☐ | |
| 4 | Read the **deps due** section | A line saying whether the 45-day cycle and the 7-day audit are OK or due (**TOCA**). | ☐ | |
| 5 | Decide what `doctor` is telling you to do next | Nothing (all green) **or** one specific command to run (e.g. `deps audit`). Was it clear? | ☐ | |
| 6 | Run `./oliva deps due` on its own | The same two-clock report as inside `doctor`. | ☐ | |
| 7 | If the audit clock is due, run `./oliva deps audit` | A security scan across composer, yarn, and base images. | ☐ | |
| 8 | Confirm `doctor` did **not** change any files | `git status -s` shows the same as before you ran it. | ☐ | |
| 9 | (Pretend you edited code) run `./oliva verify` | Migrations, schema check, PHPUnit, prod build all run and pass. | ☐ | |
| 10 | Close-of-session check: `git status -s` then `git log --oneline -3` | Clean tree (or intentional changes) + a clear last commit message. | ☐ | |

**The one question that matters:** after step 5, did you know what to do next
*without asking anyone*? If not, that's the gap to report back.

---

## Where the deeper docs live

This guide is the on-ramp. When you need more:

- **[`AGENTS.md`](../AGENTS.md)** → section "Chequeos de sanidad" — the same
  routine, written for an AI agent, with the open/close protocol in detail.
- **[`docs/oliva/actualizaciones.md`](oliva/actualizaciones.md)** — the full
  dependency + fork-sync system (the TOCA → report → update → release cycle, and
  check → start → locks for forks).
- **[`docs/qa-y-staging.md`](qa-y-staging.md)** — exactly what guarantees the
  framework offers (verify, the CI jobs, staging) and what it does **not** cover.
- **[`README.md`](../README.md)** → the `./oliva` reference table — one line per
  command.
