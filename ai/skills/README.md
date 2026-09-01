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
│   ├── gauntlet/SKILL.md    # /gauntlet — second-model review to convergence → draft PR
│   ├── shepherd/SKILL.md    # /shepherd — shepherd a draft PR to ready for review
│   ├── retro/SKILL.md       # /retro — end-of-session retro + status tables
│   ├── wrap/SKILL.md        # /wrap — wrap up + rename done-<name>
│   ├── triage/SKILL.md      # /triage — manifest-governed backlog classifier
│   ├── track-work/SKILL.md  # issue/PR tracking hygiene (model-invoked)
│   └── label-registry-support/SKILL.md  # shared runtime, not a workflow
├── backend/     # server / data / Convex
├── frontend/    # React / TanStack / shadcn / design
├── infra/       # Terraform / Cloudflare / CI
├── matt-pocock/ # attributed third-party skills by Matt Pocock
├── mobile/      # Expo / React Native (future)
└── repo/        # repo standardization / conventions
    └── standardize-repo/SKILL.md
```

`universal/` ships the dev-workflow session suite, split on whether invoking
the skill is itself the thing that authorizes what it does. Four stay
user-only (`disable-model-invocation: true`): `/claim` and `/breakdown`,
because invoking them **is** the human consent for the GitHub writes they
make (claiming the issue; proposing a decomposition for one human approval),
so a model triggering either on its own would be writing to a shared system
with nobody having agreed to it; and `/wrap` and `/retro`, because they are
human-timed session rituals — only the person at the keyboard knows a session
is actually ending. The rest are model-invocable, so an agent following the
repo's own dev loop (`AGENTS.md`) can enter a stage through the Skill tool
instead of waiting for a human to type the command: `/kickoff`, `/implement`,
`/gauntlet`, and `/shepherd` cover orienting at the start of a session through
driving a claimed issue to a shepherded PR, and `/triage` (also run by
`task triage` with a cheap headless model, or interactively) classifies the
backlog. `track-work` is model-invocable too, and deliberately **not**
slash-only. Tracking
mistakes happen mid-flow, while a PR body is being written and nobody is typing
a command, so it must be model-invocable to fire at all. It also bundles
executable checks under `assets/` that harmon-devkit's own CI runs against every
PR body (`tracking-guard.yml`), so the skill's rules and the enforced rules are
the same code. `label-registry-support` is an internal runtime package rather
than a workflow. Its `SKILL.md` ensures legacy category-sync engines vendor the
shared interpreter that `track-work` and `triage` both call.

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
