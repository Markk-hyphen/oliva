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
| T2 | `agent-commits.md` conflicts on every sync | measured: both sides append to one file; the only conflict of the last `finanzas-ong` sync | every sync | no | an app is born with an empty log of its own | open |
| T3 | Shared files rewritten by the app conflict forever | measured: `README.md` 241+/178− and 150+/193− against Oliva; `AGENTS.md` 119+/295− in `crypto-pulse` | every sync that touches them | no | split what Oliva owns from what the app writes | open |
| T4 | Two apps cannot be up at once in dev | measured: every app publishes 80, 3000, 5432; reported in three agents' notes | whenever a second app is needed | no (port error) | host ports from variables, or none by default | open |
| T5 | A backend file that is not bind-mounted goes stale inside the image | reported, `the third app`: a fixed `phpunit.dist.xml` kept failing in the container | whenever such a file is edited | yes | mount it, or have `doctor` compare | open |
| T6 | Upgrade actions done by hand | measured: 1.6.0 has 5, 2 with a guard | every release that has them | partly | more guards; fewer actions | open |
| S1 | The live demo is never removed | measured: `live.php` and `live.js` in all three apps; a dead showcase link in one | per app, forever | yes | the demo is opt-in at birth | open |
| S2 | Unused services ship to every app | measured: `rabbitmq` and `worker` blocks in three apps, used by one; Mercure and pgvector unused in one | per app | yes | roadmap item 3 | open |
| S3 | An app is born with Oliva's identity | measured, `the third app`: `AGENTS.md` byte-identical to Oliva's after two weeks; 21 inherited entries in `agent-commits.md`; Oliva's roadmap, `concepts.md` and git history | per app | yes | the bootstrap asks who the app is | open |
| X1 | Apps on 1.5.1 run on publicly known secrets | measured: `.env.backend` of both older apps. No app is in production | until each app syncs 1.6.0 | no since 1.6.0 (`env check`) | sync, when the app is next worked on | accepted |
| X2 | An app with no `origin` has no CI and no alerts | measured: `the third app` has only `oliva-upstream` | per app | yes | `doctor` says so | open |
| X3 | An app can be born between releases | measured: the README clones `main`; `the third app` is three commits past `v1.5.1` and reports 1.5.1. Sync is unaffected (drift uses the merge base) | per app | yes | the README clones a tag | open |
| X4 | Oliva has 2 HIGH Dependabot alerts and an overdue CVE audit | measured: `doctor`, push output | — | no | epic phase 2 | open |

## What varies between apps

Read-only measurement, 2026-11-14. Input for roadmap item 3.

| | finanzas-ong | crypto-pulse | the third app |
|---|---|---|---|
| Messenger / RabbitMQ / worker | unused | used | unused |
| Cron (crontab lines) | 2 | 4 | 0 |
| Mercure (backend) | used | used | unused |
| pgvector types | unused | used | unused |
| PHP extensions | `bcmath` | none | `bcmath` |
| Extra dev services | mailpit | none | none |
| Live demo | still there | still there | still there |
| `origin` remote / CI | yes | yes | no |

Still missing: whether each difference was chosen or inherited (epic phase 3).

## Runs

None yet. Next: clean-room bootstrap from `v1.6.0` (epic phase 1).
