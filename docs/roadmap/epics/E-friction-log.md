# Epic — Friction log: find the weak points by use, not by guess

> **Status:** ✅ phases 0–3 done on 2026-11-14. The log is `docs/friction-log.md`; it stays open, the epic does not ·
> **Target version:** none of its own (it produces a backlog; fixes ship in their own releases) ·
> **Origin:** roadmap item 1, chosen as the next epic on 2026-11-14.

## Problem

Roadmap item 1 says: bootstrap a fresh app, record every friction, and let that
log be the optimization backlog. Items 3 (installer) and 2 (composable services)
wait on it, because an installer designed before knowing what actually varies
between apps will be designed wrong.

Today that signal exists only as scattered leftovers: a line in an agent's
memory, a `--ours` in a sync, a gotcha that cost one session. Agent memory is
per repo and is pruned on purpose once work is done, so friction is recorded
where it is guaranteed to be erased. Three apps run on Oliva and nothing
compares them.

## Analysis: what the evidence already says

Measured on 2026-11-14, read-only, on the three apps (`finanzas-ong` and
`crypto-pulse` on 1.5.1, `the third app` born 2026-11-01 from `v1.5.1-3`). These
are the seed entries of the log. "Reported" means taken from an agent's notes,
not reproduced.

### Temporal — time lost, and anything repeated per app or per sync

| # | Friction | Evidence | Frequency |
|---|---|---|---|
| T1 | CI waits ~9.5 min on the Mercure step | measured on two runs; **fixed** (`9ab188d`, 5 s cut) | every CI run, every app |
| T2 | `agent-commits.md` conflicts on every sync | the only conflict of the last `finanzas-ong` sync; one of four in `crypto-pulse` (reported) | every sync, by construction: both sides append to the same file |
| T3 | Shared files rewritten by the app conflict forever | `README.md`: 241+/178− and 150+/193− against Oliva; `AGENTS.md` in `crypto-pulse`: 119+/295− | every sync that touches them |
| T4 | Two apps cannot be up at once in dev | every app publishes 80, 3000 and 5432; noted independently in three agents' memories; `verify` in one app collides with another's stack (reported) | every time a second app is needed |
| T5 | A file that is not bind-mounted goes stale inside the image, silently | `the third app`: a fixed `phpunit.dist.xml` kept failing in the container; cost a debugging session (reported) | whenever such a file is edited |
| T6 | Upgrade actions an app must do by hand | 1.6.0: 5 actions, 2 with a guard | every release that has them |

### Spatial — shipped and never used

| | finanzas-ong | crypto-pulse | the third app |
|---|---|---|---|
| Messenger / RabbitMQ / worker | unused | **used** | unused |
| Cron (crontab lines) | **2** | **4** | 0 |
| Mercure (backend) | **used** | **used** | unused |
| pgvector types | unused | **used** | unused |
| PHP extensions extension point | `bcmath` | none | `bcmath` |
| App variables in `env.manifest` | none yet (1.5.1) | none yet (1.5.1) | none yet (1.5.1) |
| Live demo (`live.php`, `live.js`) | still there | still there, plus a dead showcase link | still there |

| # | Friction | Evidence |
|---|---|---|
| S1 | The demo is never removed | present in all three apps |
| S2 | Unused services ship to every app | `rabbitmq` and `worker` blocks in all three, used by one |
| S3 | An app is born with Oliva's identity | two weeks and three phases in, `the third app`'s `AGENTS.md` is byte-identical to Oliva's (title "Oliva"); it inherited 21 entries of Oliva's `agent-commits.md` and appends its own below them (the origin of T2), plus `docs/roadmap*`, 564 lines of `concepts.md` and Oliva's whole git history |

S3 is the strongest single signal for item 3: the first thing that varies
between apps is *who the app is*, and nothing in the bootstrap asks.

### Security and correctness

| # | Friction | Evidence |
|---|---|---|
| X1 | Both older apps still run on publicly known secrets (none is in production) | 1.6.0 not synced yet; `crypto-pulse` also has an API key placeholder in tracked `.env.backend` |
| X2 | An app with no `origin` has no CI and no alerts, and nothing says so | `the third app` has only the `oliva-upstream` remote |
| X3 | An app can be born between releases | the README clones `main`; `the third app` carries three commits past `v1.5.1` while `OLIVA_VERSION` says 1.5.1. Sync is unaffected (drift uses the merge base, checked in `sync.sh`); the version shown is simply wrong |
| X4 | Oliva itself: 2 HIGH Dependabot alerts, CVE audit overdue (17 days against a 7-day cadence) | `doctor`, push output |

## Sensitive points

1. **The log must not live in agent memory.** Memory is per repo and gets
   pruned. Friction shows up in the *app's* sessions, while the backlog belongs
   to Oliva. Same shape as the sync reminder problem, same answer: it lives in
   the flow. Proposal in "Design".
2. **A sync run touches real secrets and real data.** Rotating secrets in the two
   older apps involves the JWT key (re-encrypted with the new passphrase) and
   database passwords bound to volumes. `finanzas-ong`'s dev database holds
   manual test data, and `verify` there brings up the real dev stack, not a
   throwaway one. One app per session, in its own repo, checks reproduced and
   not assumed.
3. **Logging against fixing.** A run that stops to fix each friction never
   finishes and measures nothing after the first fix. Rule: record, work around,
   continue. Only exception: a silent failure with security impact is fixed on
   the spot.
4. **Three apps, one maintainer.** The sample is small. The log ranks pain; it
   does not prove generality. That is exactly why the installer keeps waiting
   for it, and why the exit criterion below is a table of what varies, not a
   feature list.
5. **No server exists.** The host axis (deploy, `[host]` actions, shared infra)
   can only be simulated locally. Entries from it are marked as simulated.
6. **`the third app` has work in flight** (uncommitted, waiting on a human
   check). It is not synced until that lands.
7. **One variable at a time.** The planned test of syncing with a cheaper model
   changes who is at the keyboard. Mixed into a first sync run, a conflict
   count would no longer say whether the friction is Oliva's or the model's.
8. **The retrospective evidence is biased** towards what an agent bothered to
   write down. The clean-room run (phase 1) exists to catch what nobody noted
   because it "just worked after a retry".

## Design

**The log.** `docs/friction-log.md` in Oliva. One row per friction: id, axis,
where it happens, evidence (measured or reported), frequency (once, per app,
per sync, per run), whether it is silent or loud, candidate fix, status
(open, fixed in `<hash>`, accepted). Rows are never deleted; a fixed one keeps
its hash. It starts with the tables above.

**Where an app records friction (deferred, see Decisions).** In a file it owns: `docs/friction.md`,
free-form, appended by whoever hits something while working on the app. Oliva
never syncs it. A session in Oliva harvests those files into the log and marks
the harvested lines. One sentence in `agent-commands.md` tells the agent to
append there instead of to memory. No new tooling until the log shows the
habit sticks.

**What a run measures.** Wall time per step, steps not written in the docs,
human decisions required, conflicts by class (`[OLIVA]`, `[LOCK]`,
`[MANUAL]`), and every edit made to a file the app does not own.

## Phases

| Phase | What | Where | Touches |
|---|---|---|---|
| 0 | Create the log from this analysis | Oliva | docs only |
| 1 | **Clean-room bootstrap**: a throwaway app from tag `v1.6.0`, following the README literally, on other ports, up to a first entity, migration, test, `verify` and prod build. Then deleted | scratch directory | nothing permanent |
| 2 | **Security pass** on Oliva: `deps audit`, the two Dependabot alerts, `/security-review` on what audit can't see | Oliva | deps |
| 3 | **Triage**: rank by frequency × cost, silent ones first. Write the table of what varies between apps. Each chosen fix becomes its own change or epic; the queue-slot epic is re-ranked here against the rest | Oliva | docs only |

**The apps are not on the critical path** (decided 2026-11-14). None of them is
in production, so their public secrets (X1) are not a live hole and bringing
1.6.0 down to them is not urgent. The apps stay what they were in the analysis:
a read-only source of evidence. A sync run is recorded in the log whenever an
app is next worked on for its own reasons; it is not a phase of this epic.

**Exit criterion.** Item 3 may start when the log holds one clean-room run and a
table stating, per slot and per shared file, what is different in each app and
whether the app chose it or inherited it.

## Decisions

1. **Order** (decided): the epic runs inside Oliva; clean-room first, no app
   syncs as part of it.
2. **Fix policy during runs** (proposal, in use): record and continue, except
   silent security failures.
3. **Where apps record friction** (open, not needed yet): a `docs/friction.md`
   of their own, harvested by an Oliva session. Deferred with the apps.
4. **Cheaper-model sync test** (deferred with the apps).

## Outcome

- Log: 20 entries, two runs, the table of what varies and a ranked triage, in
  [`docs/friction-log.md`](../../friction-log.md).
- Fixed along the way: the CI wait on Mercure (`9ab188d`) and, after run 2, a
  dependency cycle released as 1.6.1 (Symfony 7.4.23, caddy 2.11.9, FrankenPHP
  1.13.5).
- What changed from the plan: the apps left the critical path (none is in
  production), so no sync run was made; the evidence from them is read-only.
- Next, from the triage: a batch of small fixes (1.6.2), then an epic on the
  birth of an app, which is the first slice of roadmap item 3.
