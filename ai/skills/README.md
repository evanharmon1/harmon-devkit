# Agent Skills

Reusable [Agent Skills](https://agentskills.io) — each a directory with a
`SKILL.md` (`name`/`description` frontmatter). harmon-devkit is the **single
source of truth**; consumer repos vendor a selected subset via the
[`skills-sync`](../../templates/skills-sync/) template.

## Layout

Skills are grouped into **category subdirectories**:

```text
ai/skills/
├── universal/   # every repo gets these
│   ├── kickoff/SKILL.md     # /kickoff — get oriented + name the session
│   ├── breakdown/SKILL.md   # /breakdown — decompose work into session-sized issues
│   ├── claim/SKILL.md       # /claim — sanity-check + claim the issue
│   ├── implement/SKILL.md   # /implement — claimed issue → ready-for-review PR via the dev loop
│   ├── review/SKILL.md      # /review — challenge/review confidence stages
│   ├── integrate/SKILL.md   # /integrate — draft integration to ready-for-review
│   ├── orchestrate/SKILL.md # standing multi-lane operating mode
│   ├── retro/SKILL.md       # /retro — end-of-session retro: run evidence + status tables
│   ├── wrap/SKILL.md        # /wrap — wrap up + rename done-<name>
│   ├── triage/SKILL.md      # /triage — manifest-governed backlog classifier
│   ├── groom/SKILL.md       # /groom — verify, dispose, regroup, and record decisions across a backlog
│   ├── track-work/SKILL.md  # issue/PR tracking hygiene (model-invoked)
│   └── label-registry-support/SKILL.md  # shared runtime, not a workflow
├── backend/     # server / data / Convex
├── frontend/    # React / TanStack / shadcn / design
├── herdr/       # Herdr terminal multiplexer and agent coordination
│   └── herdr/SKILL.md
├── infra/       # Terraform / Cloudflare / CI
├── matt-pocock/ # attributed third-party skills by Matt Pocock
├── mobile/      # Expo / React Native (future)
└── repo/        # repo standardization / conventions
    └── standardize-repo/SKILL.md
```

`universal/` ships the dev-workflow session suite. `/retro` stays user-only
(`disable-model-invocation: true`) because it is a human-timed session ritual
— only the person at the keyboard knows a session is actually ending. The
rest are model-invocable, including `/breakdown`: consent for its bulk GitHub
writes is enforced by the interactive-human approval gate in §6, not by who
typed the command. An unattended `/breakdown` may only file its proposal for a
later interactive approval; it cannot execute the proposed writes. This lets
an agent following the repo's own dev loop (`AGENTS.md`) enter a
stage through the Skill tool instead of waiting for a human to type the
command: `/claim` (the invocation still names and confirms the target issue
before any write, exactly as it does when a human types it; its writes are
idempotent and released by the ordinary lifecycle, not gated behind a
standing human-only rule) and `/wrap` join `/kickoff`, `/implement`,
`/review`, `/integrate`, and `/orchestrate` covering orienting at the start of a session
through driving a claimed issue to a draft PR and on into the integration
stage — the same session continues from `/implement` into `/integrate`
without waiting for a separate human trigger, stopping only at
`/integrate`'s own terminal condition (ready-for-review, or a blocker);
ready-for-review is still the dev loop's human-handoff point, it is just the
*output* of that stage rather than a gate on entering it. `/triage` (also run
by `task triage` with a cheap headless model, or interactively) classifies
the backlog; `/groom` (also run by `task groom`, with a fan-out of read-only
subagents that verify claims against the live code and merged PRs) decides
what the backlog should contain — closes, regroups, and surfaces
maintainer-only decisions with a recommendation each. The two stay separate:
triage classifies, groom decides, and a groom run ends by recommending a
triage run. `track-work` is model-invocable too, and deliberately **not**
slash-only. Tracking
mistakes happen mid-flow, while a PR body is being written and nobody is typing
a command, so it must be model-invocable to fire at all. It also bundles
executable checks under `assets/` that harmon-devkit's own CI runs against every
PR body (`tracking-guard.yml`), so the skill's rules and the enforced rules are
the same code. `label-registry-support` is an internal runtime package rather
than a workflow. Its `SKILL.md` ensures legacy category-sync engines vendor the
shared interpreter that `track-work` and `triage` both call.
`dev-flow-support` is the third such package: it carries the shared dev-flow v2
runtime (`devflow-policy.mjs`, `validate-result-schemas.mjs`,
`render-dev-flow.*`, `dev-flow-exit.*`, and their `lib/`) that `review`,
`integrate`, `orchestrate`, and `retro` all call.

**A skill's runtime ships with the skill, never from a repository-root
`scripts/`** ([#974](https://github.com/evanharmon1/harmon-devkit/issues/974)).
`task sync:skills` vendors `ai/skills/` and nothing else, and harmon-init's
template renders no runtime for these skills, so a skill that reaches for a
root path installs somewhere it cannot run — and the failure surfaces only when
somebody tries to use it. A script one skill uses lives in that skill's own
`assets/`; a script several skills share lives in a support package like the
three above.

What `task verify` guarantees today is **coverage, not a guard**: a synced
consumer can execute the 15 runtime entrypoints that `review`, `integrate`,
`orchestrate`, and `retro` invoke by name (#974 AC 5).
`scripts/test-skills.sh` (via `task test:skills`) publishes this checkout's real
`ai/` tree, runs the real `sync-skills.sh` into a pristine consumer that has no
repository-root `scripts/` and no `ai/` tree, and then *executes* each of those
entrypoints from inside it — including the cross-package hop from an
`orchestrate` asset to its sibling `dev-flow-support` reader.

That sweep names the entrypoints it executes and makes no claim about an asset
it does not name. A *mechanical* check that fails whenever any vendored asset
references a repository-root `scripts/` path is tracked separately in
[#1099](https://github.com/evanharmon1/harmon-devkit/issues/1099) — three
successive mechanisms for it were defeated in adversarial review, so it was
split out of #974 rather than shipped unsound.

**Consumers vendor the `universal` category as a unit.** A support package is
reached from its callers as `$asset_dir/../../<package>/assets/<name>` —
resolved from the calling asset's own *physical* directory, the same shape
`track-work/assets/check-issue-metadata.sh` uses for `issue-title-support` —
which holds in this source tree and in a consumer's flattened
`.claude/skills/` tree alike, because categories are flattened on vendor.
Vendoring a strict subset of `universal` can therefore leave a stage skill
without the package it calls. A missing sibling package is a blocker the
caller reports, never something it routes around; making the sync itself refuse
a partial install is tracked separately in
[#877](https://github.com/evanharmon1/harmon-devkit/issues/877).

**harmon-devkit uses the `universal/` and `matt-pocock/` skills itself.** Each
is symlinked into `.agents/skills/`, with `.claude/skills` pointing at that
directory for Claude Code compatibility. `.skills-sync.yaml` and the weekly
`sync-harmon-devkit.yml` workflow are present here because the copier template
renders them, but the sync cannot vendor into this repo: every dogfood symlink
is a local skill whose name collides with the incoming vendored copy, so
`sync-skills.sh` refuses (the scheduled run fails on that guard by design).
That is the wanted outcome — vendoring a released copy over the live source
would make `verify:skills` fail on every edit until a release and pin bump. Consumers vendor a pinned copy, but the source repo cannot
vendor from itself without waiting on its own release. The symlink makes the
authored skill the live one, so a change is dogfooded in the session that writes
it instead of a release and a pin bump later:

```sh
ln -s ../../ai/skills/<category>/<name> .agents/skills/<name>
ln -s ../.agents/skills .claude/skills
```

Safe with the repo's gates: `lint-hygiene.sh` skips symlinks, `.claude/**` is
excluded from markdownlint, and `verify-skills.sh` only walks `ai/skills/`, so
nothing is linted or counted twice.

| Category | For |
| --- | --- |
| `universal` | Skills every consumer repo should have |
| `backend` | Server, data, and Convex work |
| `frontend` | React / TanStack / shadcn UI and design skills |
| `herdr` | Herdr terminal multiplexer and agent coordination |
| `infra` | Terraform, Cloudflare, CI/CD |
| `matt-pocock` | Opt-in, attributed skills originally written by Matt Pocock |
| `mobile` | Expo / React Native (reserved for future use) |
| `repo` | Repo standardization and conventions |

Consumers request whole **categories**, so a skill can move between categories
here without any consumer editing a per-skill list.

## Third-party skills

Third-party skills live in an author-named category and retain their upstream
license and provenance inside every skill directory so those records survive
category flattening into consumer repos. Each imported skill includes:

- `LICENSE.upstream` — the upstream license and copyright notice.
- `UPSTREAM.md` — the original author, repository, pinned import commit,
  upstream path, and local modifications.
- A short attribution notice in `SKILL.md`.

The `matt-pocock` category currently vendors a dependency-complete selection
from [mattpocock/skills](https://github.com/mattpocock/skills), all imported at
one pinned upstream commit (recorded in each skill's `UPSTREAM.md`). Two skills
are redistributed under a `matt-`-prefixed name so they don't shadow a local
name, with their internal invocation and setup references adapted accordingly:

- The upstream `triage` skill is distributed as `matt-triage` to avoid
  colliding with the existing universal `triage` skill.
- The upstream `implement` skill is distributed as `matt-implement`, reserving
  the `implement` name for local use. It composes with the `tdd` and
  `code-review` skills (also vendored here); `tdd` in turn draws its
  deep-module vocabulary from the vendored `codebase-design` skill. Cross-skill
  calls are rephrased to load the target skill through the harness's native
  skill mechanism rather than a hardcoded slash command.

The selection includes `grill-me` and its `grilling` dependency, along with
`grill-with-docs` and its `grilling` and `domain-modeling` dependencies. It
also includes `handoff`, `matt-triage`, `prototype`, `research`,
`setup-matt-pocock-skills`, `to-spec`, `to-tickets`, and `wayfinder`.

The `backend` category vendors the complete suite of 33 official Convex agent
skills from [get-convex/agent-skills](https://github.com/get-convex/agent-skills)
(Apache-2.0). It covers project quickstarting (`convex-quickstart`),
core backend capabilities (`convex-auth`, `convex-crons`, `convex-billing`,
`convex-agent`, `convex-docs`), architecture/design (`convex-design`,
`convex-create-component`), and operation/auditing (`convex-reviewer`,
`convex-authz`, `convex-test`, `convex-optimize`, `convex-migrate`, `convex-verify`).
Each skill preserves upstream attribution, `LICENSE.upstream`, and
`UPSTREAM.md` provenance.

## The unique-name rule

Categories are **flattened** when vendored (a consumer's `.agents/skills/` holds
`<skill>/`, not `<category>/<skill>/`). So **skill directory names must be
unique across all categories** — `backend/foo` and `frontend/foo` would collide
in a consumer.

`task validate:skills` enforces this, plus that every skill has valid
`SKILL.md` frontmatter (`name:` + `description:`, and `name:` matching the
directory). It runs in `task verify`, in CI, and in the pre-commit hook.
Directories without a `SKILL.md` (drafts, placeholders) are skipped, not
failed — work-in-progress can live in the tree.

## Add a skill

1. Create `ai/skills/<category>/<skill-name>/SKILL.md` with frontmatter:

   ```markdown
   ---
   name: your-skill-name
   description: >-
     One or two sentences on when to use this skill (trigger phrases help).
   ---

   # Your Skill Name

   Skill body…
   ```

2. Make `<skill-name>` **globally unique** across categories and match the
   `name:` field to the directory name.
3. Run `task validate:skills` (or `task verify`) to check it.
4. Bundle any helper files under `assets/` and long-form docs under
   `references/`, mirroring the existing skills.

## How consumers get these

Consumers vendor a pinned subset with `task sync:skills` — see
[`templates/skills-sync/`](../../templates/skills-sync/) for the manifest,
tasks, CI job, and git-hook wiring. After a new skill ships in a harmon-devkit
release, a consumer bumps its manifest `ref` and re-syncs.
