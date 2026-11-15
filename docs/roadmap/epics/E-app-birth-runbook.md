# Runbook — finishing the app-birth epic

Everything needed to take [`E-app-birth.md`](E-app-birth.md) from "designed" to
released, written so that a session with no memory of the design can pick it up.
Read the epic first (10 minutes); this file is the how.

**State (2026-11-15): phases 1 to 5 are done, except the release itself.**
Everything is committed on the local branch `feat/app-birth`. The phases below
are kept as the record of how each was run and checked.

## What is left (all of it needs the maintainer)

1. **Merge `feat/app-birth` into `main`** (local, `--no-ff`).
2. **Decide 1.6.2**: its notes are in `UPGRADING.md` and its code on `main`,
   never released. Either release it first, or fold it into 1.7.0 (merge its
   section's bullets into `## 1.7.0` and delete the heading).
3. **Decide the name in the friction log**: it names an app with no public
   repository. As is, or "the third app".
4. `scripts/oliva/deps.sh audit` if the last one is more than 7 days old, then
   `scripts/oliva/release.sh 1.7.0`. This is the **first real cut**: it creates
   the `release` branch. Read its output; `git diff --stat main release` must
   list only the paths of `project-paths.txt`.
5. **Push**, when told: `git push origin main release v1.7.0`. Then check on
   GitHub: CI on `main` (the `test-db.sh` step has never run there), and that
   `git clone -b release` of the public repo plus `./oliva init` works.
6. Not urgent: the three apps cross over, each in its own repo and session,
   following `## 1.7.0` in `UPGRADING.md`. The first one is the first real test
   of those steps: record it in the friction log.

Known gaps, written down rather than fixed: CI runs on pushes to `main` only,
so a push to `release` alone triggers nothing (they always go together); only
Claude Code was checked reading the split `AGENTS.md`.

## Decisions already taken (do not reopen)

| # | Decision |
|---|---|
| 1 | A **`release` branch**: `main` minus Oliva's own project files. The single-branch alternative is only the fallback if phase 1 fails |
| 2 | The command is **`./oliva init "<name>"`**, with `--origin <url>`, `--demo`, `--adopt` |
| 3 | The **demo is removed by default**; `--demo` keeps it |
| 4 | A new app gets **`agent-commits.md`** (detailed log); `init` does not ask |
| 5 | The three existing apps **cross over later**, each when it is next worked on. Nothing in this epic touches their repos |
| — | **No service flags** in `init`. Identity only |

## Ground rules for whoever executes this

- **Nothing is pushed without the maintainer saying so.** `main` is already
  ahead of `origin` with unpublished work; keep it that way until told.
- **The real apps are read-only.** Work on copies: `git clone ~/<app>
  <scratch>/<app>`. Never run `sync`, `init` or a merge inside `~/<app>`.
- **Prove, do not reason.** Each phase ends with a check that was run. Say
  plainly what was not checked.
- **Record, do not fix, what is out of scope.** New friction goes to
  `docs/friction-log.md` as a row.
- One phase per commit series; record each phase in `agent-commits.md` without
  asking (standing decision). Read `AGENTS.local.md` before the first commit.
- Practicalities that already cost time:
  - `shellcheck`: `docker run --rm -v "$PWD:/mnt:ro" -w /mnt koalaman/shellcheck:stable -x -e SC1091 -S warning <files>`.
    `actionlint`: `docker run --rm -v "$PWD:/repo:ro" -w /repo rhysd/actionlint:latest`.
  - A stack brought up from a scratch clone leaves root-owned files. Before
    deleting it: `docker compose exec -T backend chown -R "$(id -u):$(id -g)" /app/config /app/migrations`,
    then `docker compose --profile '*' down -v`, then remove its images.
  - Only one app can hold ports 80, 3000 and 5432. Check `docker ps` first; do
    not stop a stack that is not yours.
  - `release.sh` now refuses unless `scripts/oliva/deps.sh audit` ran within 7
    days and `composer audit` is clean.

## Open items inherited from before this epic

Not part of the epic, but they sit in the way of its last phase:

1. **1.6.2 is not cut.** Its `UPGRADING.md` section is written and its code is
   on `main`. Either cut it first (`scripts/oliva/release.sh 1.6.2`, then push
   when allowed) or fold it into 1.7.0 by renaming the section. Ask.
2. **The friction log names an app that has no public repository.** Before any
   push: leave as is, or replace with "the third app". Ask.
3. The CI change of 1.6.2 (`scripts/lib/test-db.sh` before PHPUnit) has never
   run on GitHub. The first push will show it.

---

## Phase 1 — Prototype on copies (DONE, kept as the record of how it was run)

**Goal:** the conflict counts of the epic's table, on the real repos. Nothing
is committed to Oliva in this phase except its results.

Work in a scratch directory, call it `$P`.

1. `git clone ~/oliva $P/oliva` and work there, on a branch `proto`.
2. Draft `scripts/oliva/project-paths.txt` (first version, to be corrected by
   what this phase shows):
   ```
   README.md
   AGENTS.md
   agent-commits.md
   docs/roadmap.md
   docs/roadmap/
   docs/friction-log.md
   ```
   Not in the list, on purpose: `CLAUDE.md` (the one-line stub is product, an
   app needs it), `LICENCE`, `docs/oliva/`, `docs/examples/`, `backend/docs/`.
3. Do the split by hand, roughly (phase 2 does it properly):
   `git mv AGENTS.md docs/oliva/agent-guide.md`, `git mv docs/concepts.md
   docs/oliva/concepts.md`, `git mv docs/qa-y-staging.md docs/sanity-checks.md
   docs/oliva/`, and a ten-line Oliva `AGENTS.md`. Commit on `proto`.
4. Cut the branch, by hand, exactly as `release.sh` will:
   ```bash
   git switch -c release proto
   git rm -rfq --ignore-unmatch $(grep -vE '^\s*(#|$)' scripts/oliva/project-paths.txt)
   git commit -m "release (prototype)"
   ```
   **`-f` is required**: on later cuts, files `main` added since the last cut
   arrive staged and a plain `git rm` refuses them and aborts the whole command
   (found in the simulation).
5. For each of the three apps: `git clone ~/<app> $P/<app>`, add `$P/oliva` as
   a remote, `git merge <remote>/release`. Record per app: every conflicted
   path and its type (`git status -s`: `UD` is modify/delete, `UU` content,
   `AU`/`UA`/`DU` rename-related), and every path deleted for the app
   (`D ` lines). One app has uncommitted work in its real checkout: the clone
   takes its last commit, which is what is wanted.
6. Resolve as the design says (identity files: keep the app's), commit, then
   make a second change on `proto` that touches a product file and two project
   files, cut `release` again (merge `proto` into `release`, `git rm -rf` the
   list, commit), and merge again in each app. **Expected: zero conflicts.**
7. The guide check (sensitive point 3). In `$P/oliva` on `release`, write an
   app-style `AGENTS.md` whose first line is `@docs/oliva/agent-guide.md`,
   keep the `CLAUDE.md` stub, start an agent session there and ask it for a
   fact that is only in the guide (for example the name of the script that
   prepares the test database). Also read what the agent reports as loaded
   context. If the guide does not load: switch to the fallback (the guide
   stays whole inside `AGENTS.md` between two marker comments, the app writes
   outside them, and `sync.sh` replaces what is between the markers).

**Record** in a new section "Phase 1 results" at the end of the epic: a table
app × conflicts (first sync, second sync), the paths deleted per app, the
outcome of step 7, and any correction to `project-paths.txt`.

**Stop and ask if:** the second sync is not clean in any app; an app loses a
file it needs other than `AGENTS.md`; or step 7 fails *and* the fallback looks
worse than the single-branch alternative.

**Done when:** the table exists and the second sync is clean in all three.

## Phase 2 — The split (DONE)

**Goal:** Oliva's files sorted into product and project, with Oliva itself
still working.

1. `scripts/oliva/project-paths.txt`, final version from phase 1, with a
   header comment saying what it is and who reads it (`release.sh`).
2. Move the guide: `git mv AGENTS.md docs/oliva/agent-guide.md`. Inside it,
   retitle ("Operating guide for apps built on Oliva"), and take out what is
   about working *on* Oliva (the "Mantener Oliva vivo" bullet, `release.sh`,
   the friction log): that goes to step 3. Fix every relative link.
3. Write Oliva's own `AGENTS.md` (project, does not travel): what Oliva is,
   that the app guide is `@docs/oliva/agent-guide.md` and applies here too, the
   maintenance cycle, releases (including the new cut), the friction log, the
   epics, the commit log protocol.
4. `git mv docs/concepts.md docs/oliva/concepts.md`; same for
   `docs/qa-y-staging.md` and `docs/sanity-checks.md`. Update the explanation
   protocol in the guide: in an app, "explain X" appends to the app's
   `docs/concepts.md`; `docs/oliva/concepts.md` is read-only reference.
5. `scripts/oliva/owned-paths.txt`: add `agent-commands.md`; rewrite the SHARED
   comment (it loses `AGENTS.md`, `README.md`, `agent-commands.md`).
6. `grep -rn` for every moved path across the repo (README, docs, scripts,
   `ci.yml` `paths-ignore`, the templates) and fix each reference.

**Check:** `./oliva doctor` and `./oliva verify` pass; `shellcheck` clean; a
fresh agent session in `~/oliva` shows both the new `AGENTS.md` and the guide in
its loaded context.

**Done 2026-11-14.** Checked: `doctor` runs; a fresh session with tools disabled
named the guide's title and the release script, so both levels load. `verify`
was not rerun: the only non-doc change is a comment in `scripts/deploy.sh`.
**Left for phase 5:** `docs/oliva/actualizaciones.md` still describes `AGENTS.md`
as a shared file (three mentions and the ownership table).

## Phase 3 — The cut and the sync (DONE, except steps 3–4's `doctor` line, moved to phase 4)

**Goal:** `release.sh` builds `release` and cannot build a wrong one;
`sync.sh` follows it.

1. `scripts/oliva/release.sh`, after the version commit on `main`:
   ```bash
   git switch release 2>/dev/null || git switch -c release      # first time: from main
   git merge --no-ff --no-commit main || true                   # modify/delete on project paths is expected
   git rm -rfq --ignore-unmatch $(project_paths)
   # fail closed, two checks:
   [[ -z "$(git diff --name-only --diff-filter=U)" ]]            || abort   # anything still unmerged
   # release must equal main except for project paths:
   diff <(git diff --name-only main | sort) <(git ls-tree -r --name-only main -- $(project_paths) | sort) || abort
   git commit -m "release: Oliva $ver"
   git tag -a "v$ver" -m "Oliva $ver"                            # the tag is on release, not on main
   git switch main
   ```
   `abort` means `git merge --abort`, back to `main`, undo the version commit,
   and a message that names the offending paths. Print the push command for
   both branches and the tag; never push.
2. `scripts/oliva/sync.sh`:
   - `fetch_upstream` fetches `release` (variable `OLIVA_BRANCH`, default
     `release`); every use of the upstream ref follows.
   - **The identity rule** (from phase 1; git moves the app's `AGENTS.md` into
     `docs/oliva/agent-guide.md` by rename detection, which cannot be turned
     off). Record `pre=$(git rev-parse HEAD)` before the merge. After it,
     whether it conflicted or not:
     ```bash
     git checkout "$ref" -- docs/oliva/                       # product: Oliva's
     for f in README.md AGENTS.md agent-commits.md docs/concepts.md; do
       git cat-file -e "$pre:$f" 2>/dev/null && git checkout "$pre" -- "$f"   # identity: the app's
     done
     ```
     Print each restored path as `[YOURS]  <path>  → kept yours`. The identity
     list lives in one place (`lib.sh`, `identity_paths()`), next to
     `project_paths()`. Tried on copies of the three apps: first sync leaves
     only unrelated conflicts, second sync has none.
   - After a merge, if `.oliva-app` is missing: run `./oliva init --adopt`
     (phase 4) before anything else and say so.
3. `scripts/oliva/lib.sh`: `is_app()` (true when `.oliva-app` exists) and
   `project_paths()`. Replace the remote-sniffing in `oliva` (`doctor`'s
   "este no es un fork") with `is_app`.
4. `doctor`: a repo with an `oliva-upstream` remote and no `.oliva-app` gets
   `!! not initialized: run ./oliva init --adopt`.

**Check, in a scratch clone of Oliva** (never in `~/oliva`): cut a fake
`9.9.9` twice with a project-file change in between; then deliberately break
it (delete a product file on `release` by hand) and confirm the cut refuses and
leaves `main` and the tags as they were. Then the transition: a scratch copy of
an app with the *old* `sync.sh` merges `main`, then with the new one merges
`release`.

**Done 2026-11-15.** Checked in a scratch clone of Oliva and scratch copies of
the three apps, with the real scripts: two cuts (the second after changes to
project and product files) left `release` equal to `main` minus the project
paths; a `release` sabotaged by hand (a product file deleted) made the cut
refuse, with `main`, the version file and the tags untouched; the first sync of
each app kept its four identity files and left only the unrelated conflicts
(`composer.lock` in one, `.env.backend` in another, none in the third); the
second sync was `merge LIMPIO` in all three and brought product files only.
**Not built here:** the `init --adopt` hook after a merge and `doctor`'s "not
initialized" line: both need `init`, so they are part of phase 4. `sync.sh`
falls back to `main`, saying so, when the upstream has no `release` branch.

**Stop and ask if:** the fail-closed check cannot be made to distinguish a
project path from a product path in some real case.

## Phase 4 — `./oliva init` (DONE: run 3 in the friction log)

**Goal:** an app is born as itself, and a clean-room run proves it.

1. Templates in `scripts/oliva/templates/` (product, owned): `README.md`,
   `AGENTS.md`, `agent-commits.md`, `concepts.md`, each with `{{APP_NAME}}`,
   `{{OLIVA_VERSION}}`, `{{DATE}}`. The `AGENTS.md` template: first line the
   pointer to the guide (form decided in phase 1), then "What this app is"
   (one line to fill in), "Rules of this app", and the commit-log protocol.
2. `scripts/oliva/init.sh`, dispatched from `oliva` as `init`:
   1. refuse if `.oliva-app` exists (unless `--adopt`); refuse if this is Oliva
      (no `oliva-upstream`, and `origin` is Oliva's URL, and not `--adopt`);
   2. remotes: `origin` → `oliva-upstream` when `origin` is Oliva; add `origin`
      from `--origin`;
   3. identity files from the templates. With `--adopt`: write a file only if
      it is missing or still byte-identical to Oliva's version at the app's
      `OLIVA_VERSION`; never overwrite anything else, and list what was kept;
   4. the demo, unless `--demo`: delete `backend/public/live.php` and
      `frontend/src/js/live.js`, and replace `frontend/index.html`,
      `frontend/src/main.js` and `frontend/src/style.css` with minimal starter
      templates. With `--adopt`: skip the demo entirely (an existing app's
      frontend is its own);
   5. write `.oliva-app` (`name=`, `born_on=<version>`, `date=`), add it to
      nothing ignored: it is tracked;
   6. `./oliva env init`; commit `init: <name> on Oliva <version>`; print the
      next two commands (`docker compose up -d --wait`, `./oliva doctor`).
3. Unwire the demo from product files first, as its own commit: the
   `/live.php` route in `frontend/Caddyfile` and in `frontend/vite.config.js`.
   Move the endpoint under a path the gateway already forwards (look at how
   `/api` and `/health` are routed and reuse that), so that removing the demo
   leaves no dead route. `verify`'s Mercure step does not use the demo.
4. README: "Start an app on Oliva" becomes `git clone -b release …`, `cd`,
   `./oliva init "My App"`, `docker compose up -d --wait`, `./oliva doctor`.

**Check — clean-room run 3**, same shape as run 1 in the friction log: clone
`release` from the scratch Oliva, `init`, up, `doctor`, first entity, migration
and test, `verify`. Then two more cuts of `release` with project-file changes,
and two syncs. **Pass: zero conflicts in both syncs, `agent-commits.md` holds
only the app's entries, `AGENTS.md` titles the app, no demo file, `verify`
green.** Also run `init` twice (must refuse) and `init` inside Oliva (must
refuse). Record the run in `docs/friction-log.md` under "Runs".

## Phase 5 — Docs and release (docs DONE; the release is "What is left")

1. `docs/oliva/UPGRADING.md`, section `## 1.7.0`, in English, with the crossing
   for existing apps as labelled actions. **The first one is new, from phase 1,
   and must come first:**
   - `[merge]` before `sync start`, take Oliva's tooling alone and commit it:
     `git fetch oliva-upstream release && git checkout FETCH_HEAD -- oliva
     scripts/oliva scripts/lib && git commit -m "chore: Oliva 1.7.0 tooling
     before the sync"`. The old `sync.sh` does not know the identity rule and
     lets git move your `AGENTS.md` into a file Oliva owns;
   - `[merge]` the first sync comes from `release`; identity conflicts are
     resolved for you, here is what was deleted and why;
   - `[merge]` cut the framework sections out of your `AGENTS.md` and put the
     pointer to `docs/oliva/agent-guide.md` on its first line (list the section
     headings to remove; they are the ones of the 1.6.x `AGENTS.md`);
   - `[decision]` remove the demo by hand if you never used it (the paths);
   - `[local]` if `docs/concepts.md` conflicted, keep your additions in
     `docs/concepts.md` and drop Oliva's part, now in `docs/oliva/concepts.md`.
   Add a guard where one is possible: `doctor`'s "not initialized" line is one.
2. `docs/oliva/actualizaciones.md`: the model diagram and "Propiedad de
   archivos" gain the third kind of file and the `release` branch.
3. `docs/roadmap.md`: item 3 says its first slice shipped and what is still
   waiting (service flags).
4. `docs/friction-log.md`: S3, T2, T3, S1, X3 to `fixed in 1.7.0`; T2 and T3
   only for new apps until each existing app crosses, and say so.
5. Epic status to done, with "what changed from the plan".
6. `scripts/oliva/deps.sh audit` if the last one is older than 7 days, then
   `scripts/oliva/release.sh 1.7.0`. **Do not push.** Report the two branches
   and the tag that are ready, and the two inherited open items.

## Not in this epic

- Service flags at birth (`--queues`, `--no-realtime`): roadmap item 3 proper.
- Crossing the three apps over: each in its own repo, when next worked on.
- Group C of the triage (ports, root-owned files, baked files) and the
  queue-slot epic.

## If phase 1 fails: the fallback

Single branch. `project-paths.txt` stays; `sync.sh` deletes those paths after
every merge and resolves identity conflicts by rule; `init` still exists and
does the same job on a clone of `main`. Phases 2, 4 and 5 are unchanged; phase 3
loses the cut and gains the post-merge cleanup. X3 stays open.
