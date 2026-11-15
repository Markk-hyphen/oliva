# Epic — The birth of an app: born as itself, not as a copy of Oliva

> **Status:** 🚧 phases 1–3 done (prototype, the split, the cut and the sync). Phases 4–5 to do: [`E-app-birth-runbook.md`](E-app-birth-runbook.md) ·
> **Target version:** v1.7.0 ·
> **Origin:** friction log, triage group B (S3, T2, T3, S1, X3). First slice of roadmap item 3.

## Problem

Starting an app on Oliva is `git clone`. The app is therefore born as a full
copy of the *project* Oliva, not only of the *product*:

- Its `AGENTS.md` says "# Oliva". One app still has it byte-identical after two
  weeks and three phases of work.
- Its `agent-commits.md` opens with more than twenty entries of Oliva's own history, and the
  app appends below them.
- It carries Oliva's roadmap, epics, friction log and glossary, and the live demo.

It then pays for that on every sync. Oliva keeps editing those same paths
(its log on every release, its README, its `AGENTS.md`), the app has edited them
too, and git reports a conflict each time. Measured: the last sync of one app
had `agent-commits.md` as its only conflict; another had four, two of them
`agent-commits.md` and `README.md`, both resolved by keeping the app's version.
A conflict that is always resolved the same way is not a decision, it is a tax.

The cause is that one branch does two jobs. `main` is where Oliva is developed
*and* what an app merges from, so everything Oliva writes about itself travels.

## The idea: three kinds of file

| Kind | Examples | Who edits it | Travels to an app? |
|---|---|---|---|
| **Product** | compose files, Dockerfiles, `scripts/`, CI, `docs/oliva/` | Oliva only | yes, on every sync |
| **Oliva's own project** | `README.md`, `AGENTS.md`, `agent-commits.md`, `docs/roadmap*`, `docs/friction-log.md` | Oliva only | **no, never** |
| **The app's identity** | the app's `README.md`, `AGENTS.md`, `agent-commits.md`, `docs/concepts.md` | the app only | no: created once, at birth |

Today the second and third kinds share paths, which is the whole problem. Once
they are separated, Oliva and an app no longer write to the same identity file,
and the shared class shrinks to what is genuinely shared: `composer.json`,
`package.json`, `backend/config/**`, the dev override, `.env.example`,
`.gitignore`.

## Design

### 1. A `release` branch: the product without the project

`main` stays where Oliva is developed. A second branch, `release`, holds what
an app receives: `main` minus Oliva's own project files. `release.sh` builds it
at each release by merging `main` into `release` and removing the paths listed
in a new `scripts/oliva/project-paths.txt`. Tags point at `release` commits.
Apps clone and sync from `release`.

Because `release` contains `main`'s history, an app's merge base keeps
advancing exactly as today. Simulated end to end on toy repos (2026-11-14):

| Case | Result |
|---|---|
| Baseline: an app cloned from `main`, syncing from `main` | 2 conflicts on identity files, on **every** sync |
| An existing app, first sync from `release` | 2 `modify/delete` conflicts, **once**, on the identity files it had edited (keep the app's); Oliva's project files it never touched are deleted for it |
| The same app, next sync | clean; only product files change |
| A new app born from `release` | clean on every sync; its log holds only its own entries |
| An app that last synced from `main` with the old script, then moves to `release` | same as the second row: one-time, then clean |
| Oliva cutting the second release | clean, provided the removal is forced (`git rm -f`): files `main` added since the last cut arrive staged |

Side effects, both wanted: an app can no longer be born between releases
(friction log X3: `release` only ever holds released states, and it is a real
branch, so no detached `HEAD`), and apps stop receiving half-finished work
sitting on `main`.

### 2. The agent guide moves into the product

`AGENTS.md` today is 31 KB of framework operating guide under the title
"Oliva", in a path the app is supposed to make its own. Split it:

- `docs/oliva/agent-guide.md`: the framework guide. Product, owned by Oliva,
  synced, never edited by an app.
- The app's `AGENTS.md`: a short file the app owns. What the app is, its own
  rules, and a first line that sends the reader to the guide.
- Oliva's own `AGENTS.md` (project, does not travel): how to work *on* Oliva.
  Releases, the friction log, the epics.

The same move for two more files: Oliva's glossary becomes
`docs/oliva/concepts.md` and the app gets an empty `docs/concepts.md` of its
own; `agent-commands.md`, which no app has ever changed (measured: zero diff in
all three), becomes owned.

### 3. `./oliva init`: the birth step

```bash
git clone -b release https://github.com/Markk-hyphen/oliva.git my-app
cd my-app
./oliva init "My App"            # optional: --origin <url>
```

What it does, in order, all of it local:

1. Refuses to run twice, and refuses to run in Oliva itself.
2. Renames the remote `origin` to `oliva-upstream`; adds `origin` if a URL was
   given. Without one, `doctor` keeps saying the app has no CI (already built).
3. Writes the identity files from templates in `scripts/oliva/templates/`:
   `README.md`, `AGENTS.md`, an empty `agent-commits.md`, an empty
   `docs/concepts.md`.
4. Removes the live demo (see 4).
5. Writes a tracked marker, `.oliva-app` (name, Oliva version it was born on,
   date). It is how every script tells an app from Oliva, instead of guessing
   from remotes as today.
6. Runs `./oliva env init`, commits as `init: <name> on Oliva X.Y.Z`, and prints
   the next two commands.

It asks one thing: the name. **No service flags.** `--queues`, `--no-realtime`
and the rest are item 3 proper and need a design this epic does not attempt;
the marker file is where they will later be recorded.

`./oliva init --adopt` is the same step for an app that already exists: it
keeps every identity file that is already the app's and creates only what is
missing.

### 4. The demo leaves by default

Nobody chose the demo and nobody removed it: it is in all three apps. `init` removes it. `init --demo` keeps it.

It is wired in six places, two of them product files (`/live.php` in
`frontend/Caddyfile` and in the Vite proxy). Before `init` can remove it
cleanly, those two routes have to stop naming the demo: the demo endpoint moves
under a path the gateway already routes.

### 5. What the tooling learns

- `sync.sh` fetches `release`. On the first sync from it, the `modify/delete`
  conflicts on identity files are resolved for the app (keep its version) and
  said out loud, not left as homework.
- `sync.sh` runs `init --adopt` when the app has no marker. Without this, an
  app that never edited `AGENTS.md` would have it deleted by its first sync
  from `release` and be left with a stub pointing at nothing. This is the
  failure to guard hardest: it is silent and it removes the agent's guide.
- `doctor` says when a repo is neither Oliva nor an initialized app.
- `owned-paths.txt` gains the new product paths; the "shared" list loses
  `AGENTS.md`, `README.md` and `agent-commands.md`.

## Sensitive points

1. **`release` is how every app receives Oliva. A bug in the cut reaches all of
   them.** The cut must fail closed: if anything is left unresolved after the
   removal, or if `release` differs from `main` in any path that is not in
   `project-paths.txt`, `release.sh` stops before tagging. That second check is
   one `git diff --name-only`.
2. **The silent loss of `AGENTS.md`** on first sync (design 5). To be reproduced
   on a copy of a real app before any release, not reasoned about.
3. **Whether the guide still reaches the agent after the split.** The app's
   `AGENTS.md` will point at `docs/oliva/agent-guide.md`. Whether Claude Code
   follows an `@` import that sits inside an imported `AGENTS.md`, and what
   other agents do with a plain "read this first" line, is **not verified**. If
   it does not hold, the fallback is a guide that stays whole in `AGENTS.md`
   between two markers, with the app writing outside them.
4. **Three existing apps have to cross over.** Two have rewritten their identity
   files (cheap: keep theirs). All three carry Oliva's framework sections inside
   their own `AGENTS.md` and need them cut by hand once. That is real work per
   app and belongs in `UPGRADING.md` as a `[merge]` action. The apps are not on
   the critical path, so this can wait, but the release must not break an app
   that syncs late.
5. **The transition window.** An app on an old `sync.sh` still fetches `main`.
   That keeps working (simulated), and its next sync after that goes through
   `release`. `main` must therefore stay mergeable by an old script for at least
   one release.
6. **What visitors see.** GitHub shows `main`: Oliva's own README, with
   `git clone -b release` in it. The project and the product now have different
   front pages, and only one of them is visible by default.
7. **Scope.** This epic gives an app its identity. It does not make services
   optional at birth. Every "while we are here" towards flags is out.
8. **Rename conflicts.** Moving the glossary to `docs/oliva/concepts.md` meets
   apps that appended to `docs/concepts.md`. Expected: one conflict per app,
   once. To be measured in phase 1 with the real files.

## Phases

| Phase | What | Proves |
|---|---|---|
| 1 | **Prototype on copies.** Build `release` in a scratch clone of Oliva; sync scratch copies of the three real apps from it, twice; check the agent guide still loads after the split | the conflict counts on real repos, sensitive points 2, 3 and 8. Nothing is published |
| 2 | **The split.** `project-paths.txt`, the guide and glossary into `docs/oliva/`, Oliva's own `AGENTS.md`, `agent-commands.md` owned | Oliva still reads right to an agent working on Oliva |
| 3 | **The cut.** `release.sh` builds `release` and fails closed; `sync.sh` fetches it and resolves the one-time conflicts | sensitive points 1 and 5 |
| 4 | **`./oliva init`** with `--adopt`, the templates, the marker; the demo unwired from product files and removed at birth | a clean-room run: born, first feature, synced twice with zero conflicts |
| 5 | **Docs and release**: README, `UPGRADING.md` with the crossing-over steps, friction log statuses, v1.7.0 | — |

Phase 1 decides whether the rest happens as designed. If the real apps show
something the toy repos did not, the design changes before any code.

## The alternative that was considered

**Keep one branch; list the project paths; have `sync.sh` delete them after
every merge and resolve identity conflicts by rule.** Cheaper: no second
branch, no change to `release.sh`. Rejected as the main design because the
conflicts still *happen* on every sync and are only cleaned up afterwards by a
script, the app's history fills with merges that add and delete the same files,
a new app is still born with everything and has to throw it away, and X3 stays
open. It remains the fallback if `release` proves fragile in phase 1.

## Decisions (taken 2026-11-14)

1. A **`release` branch**; the single-branch alternative is the fallback only.
2. The command is **`./oliva init`**.
3. The **demo is removed by default**; `--demo` keeps it.
4. A new app gets **`agent-commits.md`**; `init` does not ask.
5. The three existing apps **cross over later**, each when it is next worked on.

## Phase 1 results (2026-11-14)

A prototype `release` branch built in a scratch clone of Oliva (the split done
roughly, six project paths removed) and merged into scratch copies of the three
apps, two of them on 1.5.1. The real repos were not touched.

### What git did on the first sync, left alone

| | App 1 | App 2 | App 3 (never edited its identity files) |
|---|---|---|---|
| `README.md` | modify/delete conflict | modify/delete conflict | **deleted** |
| `agent-commits.md` | modify/delete conflict | modify/delete conflict | modify/delete conflict |
| `AGENTS.md` | **moved away**: git saw a rename to `docs/oliva/agent-guide.md`, carried the app's edits into that file and left a content conflict there | same | renamed away, no conflict: the app is left with **no `AGENTS.md` and no `README.md`** |
| `docs/concepts.md` | renamed to `docs/oliva/concepts.md`, silently | same | same |
| Unrelated, from 1.6.x | `composer.lock` | `.env.backend` | none |

**The correction to the design.** The toy simulation did not have renames. On
the real files git detects them, and that is worse than a conflict: the app's
own `AGENTS.md` is taken to a path Oliva owns. Rename detection cannot be
switched off here (git 2.43: neither `-X no-renames` nor `merge.renames=false`
changed the result). So the sync does not rely on the merge result for these
paths; it applies a rule after it:

1. everything under `docs/oliva/` is taken from Oliva;
2. every identity path (`README.md`, `AGENTS.md`, `agent-commits.md`,
   `docs/concepts.md`) that existed in the app before the merge is restored
   from the app's pre-merge commit, existence included.

### With the rule

| | App 1 | App 2 | App 3 |
|---|---|---|---|
| First sync, conflicts left for a person | 1 (`composer.lock`, unrelated) | 1 (`.env.backend`, unrelated) | 0 |
| Identity files after it | the app's | the app's | Oliva's old ones, still titled "Oliva": this is what `init --adopt` is for |
| **Second sync** (after a second cut with changes to one product file and four project files) | **0 conflicts** | **0 conflicts** | **0 conflicts** |
| What the second sync brought | the two product files, nothing else | same | same |

The fail-closed check of the cut (`release` differs from `main` only in project
paths) passed on the second cut.

### The guide still reaches the agent

Checked with a real session and tools disabled: `CLAUDE.md` → `@AGENTS.md` →
`@docs/oliva/agent-guide.md` loads all three levels. A fact present only in the
guide was in the agent's context. This holds for Claude Code; another agent
gets a plain first line telling it to read the guide, which is not verified.

### Consequences for the next phases

- The rule above is part of `sync.sh` (phase 3), not an edge case.
- **The first sync of an existing app must run the *new* `sync.sh`.** With the
  old one the rule is missing and the app's `AGENTS.md` is carried away. The
  crossing-over note in `UPGRADING.md` therefore starts with taking Oliva's
  tooling alone, in its own commit, before the sync.
- `project-paths.txt` needed no correction. `docs/concepts.md` joins the
  identity paths.
