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
├── backend/     # server / data / Convex
├── frontend/    # React / TanStack / shadcn / design
├── infra/       # Terraform / Cloudflare / CI
├── mobile/      # Expo / React Native (future)
└── repo/        # repo standardization / conventions
    └── standardize-repo/SKILL.md
```

| Category | For |
| --- | --- |
| `universal` | Skills every consumer repo should have |
| `backend` | Server, data, and Convex work |
| `frontend` | React / TanStack / shadcn UI and design skills |
| `infra` | Terraform, Cloudflare, CI/CD |
| `mobile` | Expo / React Native (reserved for future use) |
| `repo` | Repo standardization and conventions |

Consumers request whole **categories**, so a skill can move between categories
here without any consumer editing a per-skill list.

## The unique-name rule

Categories are **flattened** when vendored (a consumer's `.claude/skills/` holds
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
