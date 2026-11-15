# Friction log

Every friction found while using Oliva, in one place. This is the optimization
backlog of roadmap item 1: what to fix is decided from here, ranked by how often
it hurts and how quietly, not by intuition. Method, phases and reasons:
[`roadmap/epics/E-friction-log.md`](roadmap/epics/E-friction-log.md).

**Rules.** A row is never deleted: a fixed one keeps the hash that fixed it.
During a run, record and continue; only a silent failure with security impact is
fixed on the spot. *Measured* means reproduced or read from the repos;
*reported* means taken from an agent's notes. *Silent* means nothing warned.

**Axes.** `T` temporal (time lost, or repeated per app / per sync / per run) ·
`S` spatial (shipped and never used) · `X` security and correctness.

**Status.** `open` · `fixed <hash>` · `accepted` (known, deliberately left).

## Entries

| # | Friction | Evidence | Frequency | Silent | Candidate fix | Status |
|---|---|---|---|---|---|---|
| T1 | CI waits ~9.5 min on the Mercure reachability step | measured, two runs | every CI run, every app | yes (green, just slow) | cut the SSE stream at 5 s | fixed `9ab188d` |
| T2 | `agent-commits.md` conflicts on every sync | measured: both sides append to one file; the only conflict of the last `finanzas-ong` sync | every sync | no | an app is born with an empty log of its own | fixed in 1.7.0: the log is an identity file, never merged; existing apps once they cross over |
| T3 | Shared files rewritten by the app conflict forever | measured: `README.md` 241+/178− and 150+/193− against Oliva; `AGENTS.md` 119+/295− in `crypto-pulse` | every sync that touches them | no | split what Oliva owns from what the app writes | fixed in 1.7.0: identity files are the app's, the guide moved to `docs/oliva/`; existing apps once they cross over |
| T4 | Two apps cannot be up at once in dev | measured: every app publishes 80, 3000, 5432; reported in three agents' notes | whenever a second app is needed | no (port error) | host ports from variables, or none by default | open |
| T5 | A backend file that is not bind-mounted goes stale inside the image | reported, the third app: a fixed `phpunit.dist.xml` kept failing in the container. Mechanism measured in run 1: dev mounts `src`, `tests`, `config`, `migrations`, `public` and the single file `.env`; `phpunit.dist.xml`, `composer.json` and any new `.env.test` are baked | whenever such a file is edited | yes | mount it, or have `doctor` compare | open; documented in the README since 1.7.0 |
| T6 | Upgrade actions done by hand | measured: 1.6.0 has 5, 2 with a guard | every release that has them | partly | more guards; fewer actions | open |
| T7 | Files written by the containers are owned by root on the host | measured, run 1: the generated migration, `backend/config/jwt`, `backend/config/reference.php`, `frontend/node_modules`. The app directory cannot be deleted without a `chown` | every generated file | yes | run dev containers as the host user | open; documented in the README since 1.7.0 |
| T8 | The README stops at `doctor` | measured, run 1: nothing says how to add a first entity, migration or test; `docker compose up` is given in the foreground, so the next command needs a second terminal | per app | no | a "first feature" section; `up -d --wait` | fixed in 1.7.0 |
| S1 | The live demo is never removed | measured: `live.php` and `live.js` in all three apps; a dead showcase link in one | per app, forever | yes | the demo is opt-in at birth | fixed in 1.7.0 for new apps (`init` removes it); existing apps by hand |
| S2 | Unused services ship to every app | measured: `rabbitmq` and `worker` blocks in three apps, used by one; Mercure and pgvector unused in one | per app | yes | roadmap item 3 | open |
| S3 | An app is born with Oliva's identity | measured, the third app: `AGENTS.md` byte-identical to Oliva's after two weeks; 21 inherited entries in `agent-commits.md`; Oliva's roadmap, `concepts.md` and git history | per app | yes | the bootstrap asks who the app is | fixed in 1.7.0 for new apps (`./oliva init`); existing apps: `init --adopt` |
| X1 | Apps on 1.5.1 run on publicly known secrets | measured: `.env.backend` of both older apps. No app is in production | until each app syncs 1.6.0 | no since 1.6.0 (`env check`) | sync, when the app is next worked on | accepted |
| X2 | An app with no `origin` has no CI and no alerts, and `doctor` shows **Oliva's** last CI run as if it were the app's | measured: the third app has only `oliva-upstream`; in run 1 the newborn app's `doctor` printed Oliva's green run | per app | yes | `doctor` reads CI from `origin` only, and says when there is none | fixed in 1.7.0 |
| X3 | An app can be born between releases | measured: the README clones `main`; the third app is three commits past `v1.5.1` and reports 1.5.1. Sync is unaffected (drift uses the merge base) | per app | yes | the README clones a tag | fixed in 1.7.0: apps are born from the `release` branch, which only holds released states |
| X4 | Oliva carries known CVEs: 14 Symfony advisories (fixed in 7.4.23, installed 7.4.21) and HIGH/CRITICAL with a fix in four of five base images | measured, run 2 | until the next deps cycle | no | `deps update` (Symfony is inside the range) and image bumps: caddy 2.11.9, FrankenPHP 1.13.5 | fixed `38d9422` (1.6.1): Symfony, caddy, FrankenPHP. The rest waits on upstream images: accepted |
| X5 | The first integration test of a new app fails, twice | measured, run 1: a `WebTestCase` needs `KERNEL_CLASS` (no `.env.test` ships), then the `app_test` database does not exist. `verify` goes red without naming either fix. Across the three apps: 0 kernel or web tests in 22 test files | per app | no, but the fix is not named | ship `.env.test`, create the test database in `verify` and CI, and a web test of `/health` as the example | fixed in 1.7.0 |
| X6 | The README's "Backend API" URL answers 404 | measured, run 1: `http://localhost:80/api` has no route on a fresh app | per app | yes | point it at `/health`, or drop the row | fixed in 1.7.0 |
| X7 | A release can ship with known advisories | measured, run 2: `release.sh` does not run the audit and CI has no `composer audit`. 1.6.0 was published on 2026-11-14 with 14 Symfony advisories dated 2026-11-04 | every release | yes | `release.sh` refuses, or asks, when the audit is due or red | fixed in 1.7.0 |
| T9 | The audit answers in 1,030 lines with no summary | measured, run 2: one verdict line at the end; severity is blank on every composer advisory; nothing says "one `deps update` fixes 14 of these" or which image findings are new since the last audit | every audit (7-day cadence) | no | a closing table: layer, count, fix available, new since last run | fixed in 1.7.0 |
| X8 | The Dependabot signal disagrees with itself | measured, run 2: every push prints "2 high" while the alerts API lists 0 open (4 fixed). Not investigated | every push | no | find out which one is stale | closed: the banner stopped with the 1.6.1 push; cause not established |
| X9 | The live demo stopped publishing in 1.6.0 and kept answering `{"ok":true}` | measured 2026-11-15: `live.php` signed with the old public Mercure key written in the file; one event posted, zero delivered. The README still said it "shows Mercure working out of the box" | every app since 1.6.0 | yes | publish through the configured hub | fixed in 1.7.0: the endpoint is a controller under `/api/live` |

## What varies between apps

Read-only measurement, 2026-11-14. Input for roadmap item 3. *Chosen* means the
app did something to have it (code, config, a line in a file); *inherited* means
it is there only because Oliva ships it.

| | finanzas-ong | crypto-pulse | the third app |
|---|---|---|---|
| Messenger / RabbitMQ / worker | inherited, unused | **chosen** (4 classes, `queues` profile) | inherited, unused. Queues avoided on purpose, because of the missing production worker |
| Cron | **chosen** (2 tasks) | **chosen** (4 tasks, `cron` profile) | inherited, unused |
| Mercure | **chosen** | **chosen** | inherited, unused |
| pgvector | inherited, unused | **chosen** | inherited, unused |
| PHP extensions | **chosen** (`bcmath`) | none | **chosen** (`bcmath`) |
| Extra dev services | **chosen** (mailpit) | none | none |
| Integration tests | none | none | none |
| Live demo | inherited, never removed | inherited, never removed | inherited, never removed |
| `AGENTS.md` | Oliva's plus 44 lines | rewritten (119+/295−) | Oliva's, untouched |
| `README.md` | rewritten | rewritten | Oliva's, one line changed |
| `agent-commits.md` | Oliva's entries plus its own | Oliva's entries plus its own | Oliva's entries plus its own |
| `origin` remote / CI | yes | yes | no |

Three readings:

1. **Every optional service is chosen by at least one app and inherited unused by
   at least one.** That is the case for install-time flags, and it is now measured
   rather than assumed.
2. **What every app changes is its identity** (`README.md`, `AGENTS.md`, its own
   log), and those are exactly the files that conflict on every sync.
3. **Nobody chose the demo, and nobody removed it.**

## Triage

Ranked 2026-11-14 by frequency × cost, silent ones first. Three apps and one
maintainer: this orders the pain, it does not prove generality.

**A. Small, and silent or wrong today. One batch, no design needed.**

| Order | Entry | Why here | Size |
|---|---|---|---|
| 1 | X2 `doctor` shows Oliva's CI in an app with no `origin` | a green that belongs to someone else, in the tool meant to be trusted | a few lines in `oliva` |
| 2 | X7 a release does not gate on the audit | it already happened once (1.6.0) | a few lines in `release.sh` |
| 3 | X5 the first integration test fails twice | zero integration tests in three apps is the measured consequence; also gives Oliva its first real test | `.env.test`, test database in `verify` and CI, one example test |
| 4 | X6, X3, T8 README: 404 URL, clone a tag, a "first feature" section | first contact of every new app | docs |
| 5 | T9 the audit has no summary | paid every 7 days, by whoever reads 1,030 lines | a closing table in `deps.sh` |

**B. The birth of an app. One epic, and the first slice of roadmap item 3.**

S3, T2, T3 and S1 are one problem: an app is a clone of Oliva, so it starts with
Oliva's name, log, roadmap and demo, and pays for it in conflicts on every sync.
A birth step that resets identity (an empty log, an `AGENTS.md` split into
Oliva's part and the app's, the demo and Oliva's own docs left behind) removes
the two conflicts that happen on *every* sync, and it is the smallest honest
version of `oliva new`: no service flags yet, only "who is this app". X3 (born
from a tag) and X2 (no `origin`) land in the same step.

**C. Dev ergonomics. Each needs a decision, none is urgent.**

| Entry | Open question |
|---|---|
| T4 two apps cannot be up at once | host ports from variables, or no published ports by default |
| T7 root-owned files on the host | run dev containers as the host user: touches the entrypoint and every mount |
| T5 stale baked files | mount more, or have `doctor` compare; X5's fix needs one of the two for `.env.test` |

**D. Waits for item 3, as planned.** S2 (unused services shipped). The
queue-slot epic belongs here too: one app uses queues, none is in production, and
it should be built as a slot the birth step can leave out, not before it.

**Accepted.** X1 (apps on old secrets, not in production), T6 (upgrade actions:
keep preferring guards), the residue of X4.

**Recommendation.** Batch A (done, shipped in 1.7.0; except X3, which moved to epic B: cloning a tag leaves a detached `HEAD`, and the birth step is where the starting point is chosen), then epic B. The exit criterion of the
friction-log epic is met: one clean-room run and the table above.

## Runs

### Run 1 — clean-room bootstrap, 2026-11-14

A throwaway app cloned from GitHub (`9ab188d`, one commit past `v1.6.0`),
following "Start an app on Oliva" in the README literally, without an `origin`.
Then a first entity, endpoint, migration and web test, `./oliva verify`, and
teardown. Build cache was warm, so build times are a floor, not a cold start.

| Step | Time | Result |
|---|---|---|
| `git clone` + remote rename | 1.5 s | ok |
| `./oliva env init` | 0.1 s | ok, every secret generated, nothing asked |
| `docker compose up` (as `-d --wait`) | 44.6 s | ok, three services healthy |
| `./oliva doctor` | 3.2 s | ok; CI line wrong (X2) |
| URLs of the README table | — | frontend, `/health`, Mercure ok; `/api` 404 (X6) |
| `doctrine:migrations:diff` + `migrate` | 0.8 s | ok; file owned by root (T7) |
| First web test | — | failed twice (X5); 2 undocumented steps to get it green |
| `./oliva verify` | 39 s | `FAIL phpunit` (X5), every other step passed, prod build included |

Worked the first time with no human decision: environment, first boot, health,
realtime, migrations, schema check, production build. Human decisions up to a
running stack: none. Undocumented steps up to a green test: two.

Confirmed from the inside: S3 (the new app carries 91 KB of Oliva's
`agent-commits.md` and Oliva's `AGENTS.md`), S1, S2.

Not covered by this run: a cold build, a production `up`, the frontend dev
loop, staging, and two apps up at once (T4).

### Run 2 — security pass on Oliva, 2026-11-14

`./oliva deps audit` on `main` + the Dependabot alerts API. About 2 minutes.

| Layer | Result |
|---|---|
| Composer | **14 advisories in 9 Symfony packages**, all published 2026-11-04, all fixed in 7.4.23 (installed: 7.4.21, constraint `7.4.*`) |
| Yarn | 0 in 255 packages |
| `caddy:2.11.7` | 3 in the OS (1 critical, brotli), 7 in the caddy binary; 2.11.9 exists |
| `dunglas/frankenphp:1.13.4` | 60 in the OS (59 are kernel headers, `linux-libc-dev`), 1 in the binary; 1.13.5 exists |
| `node:24-slim` | 6, in npm's own packages (build stage only) |
| `pgvector/pgvector:pg15` | 26 in `gosu` (Go stdlib); no newer pg15 tag was checked |
| `rabbitmq:4-management` | 0 |
| PHP runtime | 8.3.36, current |

Nothing here is exploitable through an app that is not deployed, and none was
fixed during the run. Findings about the tooling itself: X7, T9, X8.

### Run 3 — clean-room birth with `./oliva init`, 2026-11-15

A scratch copy of Oliva cut three fake releases; a throwaway app was cloned from
its `release` branch, initialized, given a first feature, and synced twice.
Build cache warm. Same shape as run 1, to compare.

| Step | Run 1 | Run 3 |
|---|---|---|
| Clone | ok; the app holds Oliva's README, `AGENTS.md`, log, roadmap | ok; none of those are there |
| Birth | by hand: rename the remote, `env init` | `./oliva init "My App"`, 0.3 s: remotes, four identity files, demo out, marker, `.env`, first commit |
| First `up` | 44.6 s | 55.5 s |
| `doctor` | showed Oliva's CI as the app's | names the app, says it has no `origin` and no CI |
| First web test | failed twice, two undocumented steps | passed first time (the batch A fixes) |
| `./oliva verify` | `FAIL phpunit` | all steps pass, production build of the starter frontend included |
| Sync 1 and sync 2, after releases that changed Oliva's README, `AGENTS.md`, log, roadmap, a new epic, the guide and a script | not run; measured on real apps: identity conflicts every time | `merge LIMPIO` both times; brought the guide, the script, the version and the notes, nothing else |
| The app's log after it all | Oliva's entries plus its own | its own entry only |

Also checked: `init` twice refuses; `init` in Oliva's own repository refuses and
says to clone `release`. `init --adopt`, on scratch copies of the three real
apps after their first sync from `release`: an `AGENTS.md` still titled "Oliva"
was set aside and a new one written (two apps), an app's own `AGENTS.md` was
kept and given the import line (one app), nothing was deleted, and `doctor`
lists what is left to do by hand.

Found on the way: X9 (the demo had been silently dead since 1.6.0).

Not covered: a cold build, a production `up`, staging, another agent than
Claude Code reading the split `AGENTS.md`, and the real crossing of the three
apps, which will be the first true test of the `UPGRADING.md` steps.
