# Mode: New Repo — Scaffold from harmon-init

Procedure for generating a brand-new repo from the
[harmon-init](https://github.com/evanharmon1/harmon-init) Copier template. Use
this when the destination directory does not yet exist (or is empty). To
standardize an *existing* repo instead, use the apply/update mode, not this one.

The source of truth is `harmon-init/copier.yml`. Do not invent questions, task
names, or defaults — they are derived from that file below.

## 1. Preconditions

Verify before running anything:

- [ ] **Tools installed:** `copier` (>= 9.4.0, per `_min_copier_version`),
      `git`, and — if you will create the remote or release — `gh` (GitHub CLI,
      authenticated: `gh auth status`).
- [ ] **Released template ref chosen.** Production scaffolds use the canonical
      GitHub source and a reviewed release such as `v4.1.1`. A local checkout is
      needed only to inspect source or preview unreleased work.
- [ ] **Destination does not already exist / is empty.** Copier writes into
      `<dest>`; pick a path that is free.
- [ ] **Hidden author/org defaults are correct for you.** Identity, org info,
      and machine-specific paths live in `copier.yml` under `when: false`
      (e.g. `author_full_name`, `author_email`, `author_git_provider_username`,
      `organization`, `projects_directory`, `bunches_directory`,
      `obsidian_directory`). These are NOT asked interactively — they are baked
      in for the template owner. If you are not the template owner, fork
      harmon-init and edit those once before first use.

## 2. Generate — interactive form

The `--trust` flag is required: it allows copier to run the `_tasks` (git init,
commit, etc.) defined in `copier.yml`.

```bash
copier copy https://github.com/evanharmon1/harmon-init.git <dest> \
  --trust --vcs-ref=v4.1.1
```

`v4.1.1` is the current reviewed example; replace it when a newer release has
been deliberately selected. Do not use a moving branch for production lineage.
For an unreleased template preview only, a developer may render a local checkout
with `--vcs-ref=HEAD` into a disposable destination. That preview can contain a
Copier-created throwaway commit and must not be promoted as a production scaffold.

Copier prompts for each asked question. Answer them; everything else falls back
to the hidden defaults.

## 3. Generate — non-interactive form

Supply answers with `--data key=value` (repeat per key). Side-effectful
questions all default to `no`, so omitting them is safe in CI. Add `--defaults`
to accept the default for any key you do not pass.

```bash
copier copy https://github.com/evanharmon1/harmon-init.git <dest> \
  --trust --vcs-ref=v4.1.1 --defaults \
  --data project_name="My Project" \
  --data project_slug="my-project" \
  --data project_description="One-line description of the project" \
  --data github_org="evanharmon1" \
  --data project_type="general" \
  --data include_terraform=false \
  --data include_ansible=false \
  --data ci_runner="ubuntu-latest" \
  --data license="mit" \
  --data use_release_please=true \
  --data use_skills_sync=true \
  --data use_foreman=true \
  --data devcontainer=true \
  --data project_management="none" \
  --data git_init=true \
  --data github_remote_create=false \
  --data github_release_init=false \
  --data bunch_add=false \
  --data obsidian_project_add=false \
  --data run_task_install=false
```

### Answerable questions (from `copier.yml`)

| Key | Type | Default | Choices / notes |
|---|---|---|---|
| `project_name` | str | — (required) | Formal name, e.g. "My Project". |
| `project_slug` | str | slugified `project_name` | lowercase, spaces → `-`. |
| `project_description` | str | `TODO: project_description` | Short description; replace the TODO. |
| `github_org` | str | `evanharmon1` (`author_git_provider_username`) | Org/user that owns the repo; drives repo URL, GHCR images, workflows. |
| `project_type` | str | `general` | `general` \| `web-astro` \| `web-app` \| `iac` \| `docs`. Drives Taskfile, CI jobs, devcontainer tooling. |
| `include_terraform` | bool | `true` iff `project_type == 'iac'` | Adds `terraform/` skeleton + terraform linting. |
| `include_ansible` | bool | `true` iff `project_type == 'iac'` | Adds `ansible/` skeleton + ansible linting. |
| `ci_runner` | str | `ubuntu-latest` | `ubuntu-latest` \| `self-hosted`. |
| `license` | str | `mit` | `mit` \| `private`. |
| `use_release_please` | bool | `true` | release-please rolling release PR + auto CHANGELOG. |
| `use_skills_sync` | bool | `true` | Vendor pinned harmon-devkit skills and verify drift. |
| `skill_categories` | multiselect | profile-seeded | Starts with `universal`; adds frontend/backend/infra categories from the selected stack. |
| `use_foreman` | bool | `true` | Include the Foreman supervisor, agents, tasks, docs, and tests. |
| `devcontainer` | bool | `true` | Dual-profile `.devcontainer` (AI bot + human dev). |
| `project_management` | str | `none` | `none` \| `github` \| `linear`; controls the project-management playbook. |
| `git_init` | bool | `true` | Initialize the git repo (see `_tasks`). |
| `github_remote_create` | bool | `false` | `gh repo create` (private, pushes initial state). |
| `github_release_init` | bool | `false` | Runs `task release:init` (initial release). |
| `bunch_add` | bool | `false` | Add Bunch file (macOS-only; moves to iCloud). |
| `obsidian_project_add` | bool | `false` | Add Obsidian project note to the vault (macOS-only). |
| `run_task_install` | bool | `false` | Run `task install` after generation (brew bundle + git hooks). |

Notes:
- Several defaults are *computed* from earlier answers. Setting `project_type=iac`
  flips `include_terraform`/`include_ansible` to `true` unless you override them.
- CodeQL rendering is derived from the hidden `use_node` / `use_python` tooling
  flags rather than a user-selectable Copier answer. Public
  repositories run the generated workflow automatically. Free private repos keep
  the workflow's not-applicable aggregate and use Semgrep CE; paid private CodeQL
  is enabled later with the `FULL_SECURITY_SCAN` runtime variable. Reconcile the
  rendered language matrix with real first-party source and report any mismatch as
  a harmon-init limitation rather than inventing a Copier answer.
- Hidden, derived flags you do **not** answer but that follow from your choices:
  `use_node` (true for `web-astro`/`web-app`), `use_python` (true for `iac` or
  `include_ansible`), `repo_url`, `devcontainer_image`, `ci_runner_labels`.

## 4. Post-generation `_tasks` (run automatically, in order)

Because `--trust` was passed, copier runs the `_tasks` from `copier.yml`
**after** rendering, in this exact order. Each is gated on the answer in
brackets; all side-effectful ones default to `no` so `copier copy --defaults`
is CI-safe (only `git_init` runs by default, and it only touches the new
project directory):

1. `git init -b main` — when `git_init`.
2. `git add -A && git commit -m "chore: initial scaffold from harmon-init"` —
   when `git_init`. The initial commit exists so steps 3 and 5 have a `HEAD`.
   It runs *before* `task install`, so lefthook hooks are not yet installed and
   nothing intercepts this commit.
3. `gh repo create <github_org>/<project_slug> --private --source=. --push` —
   when `github_remote_create`.
4. `task install` — when `run_task_install` (brew bundle + `lefthook install`,
   plus `uv sync` / `pnpm install` if applicable).
5. `task release:init` — when `github_release_init` (tags `v0.1.0`, pushes it,
   `gh release create`). Requires the remote to exist (step 3).
6. `task util:bunch-add` — when `bunch_add` (macOS-only).
7. `task util:obsidian-add` — when `obsidian_project_add` (macOS-only).

If you left the side-effectful answers at their `no` defaults (the CI-safe,
recommended path for unattended generation), only steps 1–2 run and you finish
setup manually in the next section.

## 4a. Verify durable Copier lineage

The production command above records both the canonical `_src_path` and the
released `_commit` in `.copier-answers.yml`. Treat those fields as one lineage
tuple and verify both before the first push:

```bash
grep -E '^(_src_path|_commit):' .copier-answers.yml
```

If a repo was rendered from a local checkout, **do not rewrite only `_src_path`**.
A dirty `--vcs-ref=HEAD` render may record a temporary commit that is not reachable
from the canonical remote, leaving the next `copier update` unable to reconstruct
its base. Use that render only as a preview, then re-render/re-adopt production
from the canonical URL and a released ref. The narrow exception is a deliberately
pushed pre-release commit: first prove the recorded `_commit` is reachable from
the canonical remote, then verify and commit both lineage fields together.

## 5. After generation — local setup & self-check

```bash
cd <dest>

# If you did NOT set run_task_install=true, do it now:
task install          # Brewfile deps (+ uv sync / pnpm install as applicable) + lefthook hooks

task verify           # lint + (template's) checks — the local merge gate

# Skill self-check that the conventions actually landed:
bash <skill-dir>/assets/verify-applied.sh <dest>
```

`<skill-dir>` is the root of this skill
(`.../ai/skills/repo/standardize-repo`). `assets/verify-applied.sh` asserts the
expected artifacts are present (e.g. `Taskfile.yml`, `lefthook.yml`, the
`AGENTS.md` symlinks, `.github/workflows/`). Investigate any failure before
proceeding.

**`web-app` / `web-astro` are conventions-only stubs.** A fresh render ships the
DevOps tooling but **no application framework** — there is no `package.json`
until you scaffold one (`docs/CHECKLIST.md` §3: `pnpm create @tanstack/start` for
`web-app`, `pnpm create astro` for `web-astro`). This is expected, not a broken
scaffold: the framework-scaffolding step is the operator's next action, and the
lint/typecheck/build tasks all skip cleanly in this pre-framework window so
`task verify` stays green until then. (If you are on a template *older* than
harmon-init's build-guard fix, `task verify` / CI's build step may go red at
`pnpm build` until the framework is added — scaffold the app to clear it, or pull
the latest template.)

## 6. Hand off — GitHub setup

Finish remote/GitHub configuration via the generated checklist and this skill's
companion reference:

- In the new repo: work through `docs/CHECKLIST.md` (rendered from
  `template/docs/CHECKLIST.md.jinja`). It covers, in order: local setup → GitHub
  repo settings (branch ruleset import via the GitHub UI, Dependabot
  alerts + private vulnerability reporting, Renovate app, CodeRabbit app, Actions
  secrets/variables, the CI GitHub App, GHCR publishing) → framework scaffolding
  for the chosen `project_type` → secrets/env → docs/meta (fill `TODO:` markers,
  confirm badges, optional `task release:init`).
- Then follow **`references/post-generation-checklist.md`** in this skill for the
  agent-driven walkthrough of that GitHub setup.
