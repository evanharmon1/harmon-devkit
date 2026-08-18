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
│   ├── _shared/                 # non-skill support bundle vendored with the category
│   ├── kickoff/SKILL.md     # /kickoff — get oriented + name the session
│   ├── breakdown/SKILL.md   # /breakdown — decompose work into session-sized issues
│   ├── claim/SKILL.md       # /claim — sanity-check + claim the issue
│   ├── implement/SKILL.md   # /implement — claimed issue → ready-for-review PR via the dev loop
│   ├── gauntlet/SKILL.md    # /gauntlet — second-model review to convergence → draft PR
│   ├── shepherd/SKILL.md    # /shepherd — shepherd a draft PR to ready for review
│   ├── retro/SKILL.md       # /retro — end-of-session retro + status tables
│   ├── wrap/SKILL.md        # /wrap — wrap up + rename done-<name>
│   ├── triage/SKILL.md      # /triage — manifest-governed backlog classifier
│   └── track-work/SKILL.md  # issue/PR tracking hygiene (model-invoked)
├── backend/     # server / data / Convex
├── frontend/    # React / TanStack / shadcn / design
├── infra/       # Terraform / Cloudflare / CI
├── matt-pocock/ # attributed third-party skills by Matt Pocock
├── mobile/      # Expo / React Native (future)
└── repo/        # repo standardization / conventions
    └── standardize-repo/SKILL.md
```

`universal/` ships the dev-workflow session suite — nine user-invoked slash
commands (`disable-model-invocation: true`) covering the phases of a working
session, from decomposing the work and naming the session to shepherding its
PR to ready for review, plus the backlog-maintenance `/triage` (run by
`task triage` with a cheap headless model, or interactively) — plus `track-work`,
which is deliberately **not** slash-only. Tracking
mistakes happen mid-flow, while a PR body is being written and nobody is typing
a command, so it must be model-invocable to fire at all. It also bundles
executable checks under `assets/` that harmon-devkit's own CI runs against every
PR body (`tracking-guard.yml`), so the skill's rules and the enforced rules are
the same code.

**harmon-devkit uses the `universal/` skills itself.** Each is symlinked into
`.agents/skills/`, with `.claude/skills` pointing at that directory for Claude
Code compatibility. Consumers vendor a pinned copy, but the source repo cannot
vendor from itself without waiting on its own release. The symlink makes the
authored skill the live one, so a change is dogfooded in the session that writes
it instead of a release and a pin bump later:

```sh
ln -s ../../ai/skills/universal/<name> .agents/skills/<name>
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

A category may carry one `_shared/` support bundle. It is not a skill and has
no `SKILL.md`; the sync engine vendors it beside the flattened skill
directories. Use it only when multiple skills need one executable
implementation while each must remain usable without the other skill.

## Third-party skills

Third-party skills live in an author-named category and retain their upstream
license and provenance inside every skill directory so those records survive
category flattening into consumer repos. Each imported skill includes:

- `LICENSE.upstream` — the upstream license and copyright notice.
- `UPSTREAM.md` — the original author, repository, pinned import commit,
  upstream path, and local modifications.
- A short attribution notice in `SKILL.md`.

The `matt-pocock` category currently vendors a dependency-complete selection
from [mattpocock/skills](https://github.com/mattpocock/skills). The upstream
`triage` skill is distributed as `matt-triage` to avoid colliding with the
existing universal `triage` skill; its internal invocation and setup references
are adapted accordingly.

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
