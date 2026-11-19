# Epic — Symfony 8.4 LTS: the backend framework upgrade worth waiting for

> **Status:** 🧭 stub, evaluation only — no design, no branch, no target version yet ·
> **Decision:** deferred until the current epic (`E-unbundle-roles.md`, realtime hub /
> 1.10.0) ships ·
> **Origin:** a "major Symfony update is out" question, 2026-11-19. Relates to roadmap
> item 2 ("Composable services") and its sub-section "The backend: the hardest slot".

## The question that started this

Oliva's backend is pinned to **Symfony 7.4** (`backend/composer.json`: `symfony/* 7.4.*`,
`php >=8.3.31`). Symfony 8.0 shipped in November 2025, and the reflex is "a major is out,
should we migrate for the new features?". The answer is more interesting than yes/no, and
it is the reason this is a stub and not a plan: **the features worth having are not in 8.0,
and the version worth landing on is not 8.1 or 8.2 either.**

## Finding 1 — 7.4 and 8.0 are the same release, feature for feature

Symfony ships the last minor of a series (`x.4`) and the next major (`x+1.0`) **together**,
with an identical feature set. 8.0 is "7.4 minus the deprecations" (~13.2k lines of
deprecated code removed) plus a bump to **PHP 8.4**. Nothing in 8.0 is absent from 7.4.

| | Symfony 7.4 (Oliva today) | Symfony 8.0 |
|---|---|---|
| Features | all of them | the same, none new |
| Deprecated code | kept (compat layers) | removed |
| PHP minimum | 8.2 (Oliva pins ≥8.3.31) | **8.4** |
| Support | **LTS** — bugfix to ~Nov 2028, security to ~Nov 2029 | standard, ~8 months |

**Consequence:** "upgrade to 8.0 for the features" is empty — Oliva already has them on 7.4.
The only deltas 8.0 offers are a PHP 8.4 requirement and a cleaner tree, at the cost of
leaving the LTS line. Not worth it on its own.

## Finding 2 — the features that *do* match Oliva's philosophy are in 8.1 and 8.2

These are the ones that matter here, because they are the same move Oliva makes
(decoupling, opt-in) but made **inside the framework**:

- **Symfony 8.1 — HTTP-less applications.** The DI container and bundle infrastructure
  were extracted out of `HttpKernel`; `FrameworkBundle` splits into `ServicesBundle` (DI
  base: event dispatcher, filesystem, clock, env processors) and `ConsoleBundle`. A CLI or
  worker workload boots the container **without the HTTP stack**. Full BC for HTTP apps
  (`HttpKernel\Kernel` extends the new `AbstractKernel`).

- **Symfony 8.2 — one bundle per component.** `FrameworkBundle` is split into 29
  per-component bundles (`MessengerBundle`, `MailerBundle`, `CacheBundle`,
  `HttpClientBundle`, …) that **auto-register only when their package is installed** — no
  `config/bundles.php` edits. BC preserved via key aliasing. One behavior change to watch:
  enabling forms no longer enables validation (now `symfony/validator` must be installed).

### Why this is relevant to Oliva specifically, not in the abstract

Oliva **already runs two HTTP-less workloads** that today boot the full HTTP stack for
nothing:

- **`worker`** — `oliva-consume` (`backend/frankenphp/consume-messages.sh`): a pure
  Messenger consumer, never serves HTTP.
- **`scheduler`** — supercronic over `backend/scheduler/crontab`: runs console commands.

Under 8.1 both could boot without `HttpKernel` → lighter start, less memory, smaller attack
surface. And 8.2's auto-register-when-installed model is Oliva's own slot philosophy
("services you turn on/off": `queues`, `cron`, realtime) pushed down to the framework
level. These two releases are, conceptually, the framework-level mirror of
`E-unbundle-roles.md`.

## Finding 3 — the honest trade, and the version actually worth targeting

The gains above are **refinements, not new capabilities**: the worker already works, 8.1
just makes it boot clean. Against that, the cost is real:

1. **8.1 and 8.2 are not LTS** (~8 months each). Taking them now means leaving 7.4 LTS and
   riding the 8.x treadmill — directly against the low-churn value Oliva is built on.
2. **PHP 8.4 required** (from 8.0). Oliva pins ≥8.3.31; the PHP bump comes first.

Symfony's pattern is `x.4 = LTS`. So **Symfony 8.4 (≈ Nov 2027) will be the next LTS and
will roll up 8.0 + 8.1 (HTTP-less) + 8.2 (per-component bundles) + 8.3** — every feature
that matters here, *plus* LTS support, without paying the treadmill.

**Target: Symfony 8.4 LTS, not 8.1/8.2 piecemeal.**

## What can start before any migration (and is worth doing regardless)

Independent of the target version, the preparation is the same and de-risks the eventual
jump:

- **Clear 7.4 deprecations as they surface** — read the deprecation log from the test
  suite; resolving them on 7.4 is exactly Symfony's recommended path to any 8.x.
- **Plan the PHP 8.4 bump** (`php` constraint, base image, `php-extensions.txt`, CI, and
  the one fork that carries `bcmath`).
- **Adopt the genuinely new *components* on 7.4 now, opt-in, no migration** — `ObjectMapper`
  (DTO ↔ entity, the clearest fit for apps with an API), `JsonStreamer`, `JsonPath`. These
  are app-level and can be documented in `docs/oliva/concepts.md` without touching the
  framework version.

## Open questions (to settle when this leaves stub state)

- Does the HTTP-less boot for `worker`/`scheduler` measure a win worth the config change,
  or is it cosmetic given FrankenPHP's footprint? (Measure before committing — Oliva's rule:
  changes are proven, not argued.)
- How does the per-component bundle split interact with FrankenPHP and the current
  `framework-bundle` pin? Any `owned-paths.txt` / sync implications.
- The forms→validation behavior change, and any other 8.2 BC break, as labelled
  `UPGRADING.md` actions when the time comes.
- Whether to track this as its own roadmap item or fold it under "The backend: the hardest
  slot".

## Sources (captured 2026-11-19; verify against symfony.com before acting)

- Preparing for Symfony 7.4 and 8.0 — https://symfony.com/blog/preparing-for-symfony-7-4-and-symfony-8-0
- New in Symfony 8.1: HTTP-Less Symfony Applications — https://symfony.com/blog/new-in-symfony-8-1-http-less-symfony-applications
- New in Symfony 8.2: One Bundle per Component — https://symfony.com/blog/new-in-symfony-8-2-one-bundle-per-component
