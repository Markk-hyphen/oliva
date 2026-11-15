@docs/oliva/agent-guide.md

# Oliva (the framework's own repository)

The line above imports the operating guide every app built on Oliva follows. It
applies here too: this repository is also a running Oliva stack. If your agent
does not follow imports, read `docs/oliva/agent-guide.md` first.

This file is about working **on Oliva itself**. It is one of Oliva's project
files: it lives on `main` and never reaches an app (`scripts/oliva/project-paths.txt`).

## Three kinds of file

| Kind | Where | Reaches an app? |
|---|---|---|
| Product | everything not listed below: compose files, Dockerfiles, `scripts/`, CI, `docs/oliva/` | yes, on every sync |
| Oliva's own project | the paths in `scripts/oliva/project-paths.txt`: this file, `README.md`, `agent-commits.md`, `docs/roadmap*`, `docs/friction-log.md` | never |
| An app's identity | the app's `README.md`, `AGENTS.md`, `agent-commits.md`, `docs/concepts.md` | created once, by the app |

Before adding a file, decide which kind it is. A document about where Oliva is
heading is project. A document an app's agent needs is product and goes under
`docs/oliva/`. Design and reasons: `docs/roadmap/epics/E-app-birth.md`.

## Keeping Oliva alive

- `./oliva doctor` at the start of every session. When `deps due` says it is
  time: `scripts/oliva/deps.sh report` (EOL, images, composer, yarn, actions,
  CVEs), then `deps.sh update` (bump within ranges, `verify`, commit on
  `chore/deps-<date>`). Major jumps and base images by hand, one per commit.
- The CVE audit has its own, shorter cadence: `scripts/oliva/deps.sh audit`. Do
  not run a cycle or an audit unless the maintainer asks; mention that it is due.
- Whatever an app has to do because of a change goes in
  `docs/oliva/UPGRADING.md` **in the same commit**, as a labelled action. Order
  of preference: the change asks nothing of the app, then a guard
  (`scripts/lib/upgrade-guards.sh`), then a labelled action, then prose.
- Releasing: notes in `UPGRADING.md`, then `scripts/oliva/release.sh X.Y.Z`. It
  refuses when `composer audit` reports advisories or the full audit is more
  than 7 days old. It never pushes: it prints the command.
- Full description: `docs/oliva/actualizaciones.md`.

## Where the direction lives

- `docs/roadmap.md`: where Oliva is heading and why. Dependency-ordered, not a
  schedule.
- `docs/roadmap/epics/`: one document per piece of work with a design. An epic
  in progress may have a runbook next to it; start there.
- `docs/friction-log.md`: every friction found by using Oliva, ranked. What to
  fix next is decided from it. During a run, record and continue; only a silent
  failure with security impact is fixed on the spot.

## Rules that are specific to this repository

- **A failure that makes no noise is a bug in Oliva.** When designing a change,
  ask whether it leaves one. Guards go where the agent acts (scripts, CI), say
  the fix, and cost nothing when they do not apply.
- **New documents are written in English and name no person** (roadmap item 5).
  Older Spanish sections stay until their file is reworked for another reason.
- **The apps built on Oliva are separate repositories.** Never edit them from
  here. To try something against an app, work on a scratch copy.
- **Changes are proven, not argued.** State what was run and what was not.
- The commit log protocol is the one in the guide; this repository uses
  `agent-commits.md`, and each phase of an epic gets an entry.
