# AGENTS.md

Guidance for AI coding agents (Claude Code, Gemini CLI, GitHub Copilot, Codex,
...) working in Harmon DevKit. `CLAUDE.md`, `GEMINI.md`, and
`.github/copilot-instructions.md` are symlinks to this file — edit only
`AGENTS.md`.

## Project Overview

Harmon DevKit — my personal developer kit of reusable templates and boilerplates
(Docker Compose, Ansible, shell scripts, serverless functions, and more),
standalone scripts, and AI assets (skills, prompts, agents). This is **not** a
monorepo and has no application code of its own — it is a flat collection of
independent, copy-paste assets organized by category under `templates/`,
`scripts/`, and `ai/`.

Repo: https://github.com/evanharmon1/harmon-devkit — see [docs/README.md](docs/README.md) for the
documentation map, [docs/architecture/README.md](docs/architecture/README.md)
for the architecture, and [DESIGN.md](DESIGN.md) for design/UX intent.

## harmon-platform

One of five repos in **harmon-platform** (Evan's developer & DevOps platform + homelab):
[harmon-init](https://github.com/evanharmon1/harmon-init) (the Copier repo template),
[**harmon-devkit**](https://github.com/evanharmon1/harmon-devkit) (this repo — boilerplates/scripts/AI assets),
[harmon-dotfiles](https://github.com/evanharmon1/harmon-dotfiles) (chezmoi dotfiles),
[harmon-ops](https://github.com/evanharmon1/harmon-ops) (machine setup),
[harmon-infra](https://github.com/harmonops/harmon-infra) (homelab IaC). See the README for the full table.

## Repository Layout

- `templates/` — copy-paste boilerplates by category: `ansible.md`, `docker/`
  (genericStack, n8n-compose), `scriptTemplates/` (Go, Python, Shell),
  `serverlessFunctionTemplates/` (AWS Lambda, GCP, Netlify), `webTemplates/`.
  Each category has a README; the root README has the full template index.
- `scripts/` — standalone scripts and utilities: `appleScripts/`
  (AppleScript/Automator apps), plus the harmon-init helper scripts
  (`status.sh`, `lint-hygiene.sh`, `test-*.sh`, …) that back the Taskfile.
- `ai/` — AI assets by type: `skills/`, `prompts/`, `agents/`, `rules/`,
  `evals/`, `tools/`, `workflows/`, `mcp/`, `knowledge/`, `memories/`. `skills/`
  is the populated one (Agent Skills convention — a `SKILL.md` with
  `name`/`description` frontmatter); the standout is `repo/standardize-repo`
  (applies harmon-init's conventions to a repo) and the `design/` suite.
- `snippets/` — small reusable code snippets (placeholder).
- `docs/` — project docs (see [docs/README.md](docs/README.md)); the
  new-project [checklist](docs/CHECKLIST.md) lives here.

## Commands

All commands go through the Taskfile (single source of truth — CI, git hooks,
and humans run the same targets):

```bash
task verify      # FAST local gate (<~1 min) — run constantly; safe for hooks/agents
task ci          # FULL CI mirror — run before/instead of opening a PR
task check       # all linters
task fix         # auto-format then lint
task test        # tests
task security    # gitleaks + dependency audit
```

`verify` is deliberately kept fast (lint + the quick
Taskfile/hook guards) so editors, git hooks, and AI agents can run it on every
change without getting bogged down. `ci` is the full pipeline — everything CI
runs (`verify` + `test` + `security` + the devcontainer permission assert) — so you
can reproduce a CI run locally on demand instead of waiting on a PR.

## Definition of Done

- `task verify` passes.
- Conventional commit message (types: build, change, chore, ci, docs, feat,
  fix, perf, refactor, remove, revert, style, test).
- Never bypass git hooks (`--no-verify` is forbidden); fix the underlying issue.
- Work on a feature branch; direct commits to `main` are blocked.
- Releases are intentional: release-please keeps a rolling release PR from
  conventional commits; merging it cuts the tag/release. Nothing bumps on a
  normal merge. `task release:*` remains as a manual override.

## Conventions

Full reference: [docs/conventions.md](docs/conventions.md). Highlights:

- Conventional Commits; `group:action` Taskfile naming (e.g. `lint:shell`, not
  `shell:lint`); pin actions by SHA + `# vX.Y.Z`.
- Git hooks are managed by lefthook (`lefthook.yml`) and delegate to Taskfile
  targets — don't duplicate logic in hooks or workflows.
- Keep Taskfile `cmds:` trivial — inline strings aren't linted (`lint:shell`
  only covers `scripts/*.sh`). Put any pipeline/conditional/loop/`curl | bash`
  in a `scripts/*.sh` the task calls. `task test:tasks` checks the Taskfile
  compiles and setup tasks are safe no-ops.
- Indentation: 2 spaces default, 4 for Python/Terraform/Shell (`.editorconfig`).
- Secrets never go in git; local env via 1Password (`op run` / `op inject`).
