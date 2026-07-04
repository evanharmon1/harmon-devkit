# Standards Catalog

The authoritative list of attributes a repo should have to conform to the
[harmon-init](https://github.com/evanharmon1/harmon-init) Copier template
conventions. An auditing or scaffolding agent consults this to answer: **"what
should this repo have, and where does it come from?"**

Ground-truth sources (read these, don't trust memory): `harmon-init/copier.yml`,
`harmon-init/AGENTS.md`, the `harmon-init/template/` tree. Live reference repos
that have been generated from the template: `harmonops/harmon-infra` (an `iac`
project) and `sommerlawn/sommerlawn-web` (a `web-astro` project). The platform
and client repos are kept current via mode-update passes (all six were at
v3.15.2 as of 2026-07-03), so their remaining divergences are **deliberate
customizations** (Part 3.2), not lag — but they can drift between passes, so
read the repo's actual `_commit` in `.copier-answers.yml` rather than assuming
either way. Treat the **template** as canonical; treat divergences in a live
repo as legit project-type/stack specifics (Part 3), deliberate customizations,
or — in a repo that hasn't been updated recently — template-version lag (3.3).

Every item is tagged:

- **[copier]** — the template generates this automatically; a freshly generated
  repo already has it. An audit flags it only if missing/modified.
- **[manual]** — a follow-up the operator/agent must do by hand (it lives in
  `docs/CHECKLIST.md`, depends on a side-effectful copier answer that defaults to
  `no`, or requires a GitHub/external action copier can't perform).

---

## Part 1 — Universal conventions (every repo)

These apply regardless of `project_type`.

### 1.1 Docs-folder layout

The `docs/` tree is a **routing hub** ("routes; does not hold facts"). Folder
landing pages are always `README.md`. **[copier]** generates the whole skeleton.

| Path | Purpose | Source |
|---|---|---|
| `docs/README.md` | Hub; the four-buckets table | [copier] |
| `docs/conventions.md` | Flat-lookup of enforced rules (grep, don't read) | [copier] |
| `docs/glossary.md` | Term → definition flat lookup | [copier] |
| `docs/CHECKLIST.md` | Run-once post-generation setup list | [copier] |
| `docs/product/` | Why it exists / who for — `vision.md`, `roadmap.md`, `domain.md`, `README.md` | [copier] |
| `docs/architecture/` | How it's built — `README.md`, `ci-cd.md`, `security.md`, `branch-protection.md`, `tests.md` (+ `design-language.md` for web types) | [copier] |
| `docs/decisions/` | ADRs, numbered `0001-`, zero-padded; `0001-record-architecture-decisions.md` ships as the template ADR; `README.md` index | [copier] |
| `docs/guides/` | Calm how-tos read in advance — `onboarding.md`, `deploying.md`, `troubleshooting.md`, `README.md` | [copier] |
| `docs/runbooks/` | Crisis procedures read under pressure — `README.md` | [copier] |

Repo-root siblings of `docs/` (deliberately NOT under `docs/`):

| Path | Purpose | Source |
|---|---|---|
| `specs/` | Source of truth for **WHAT to build**; `_template.md` + `README.md`; one spec per feature, Given/When/Then acceptance criteria | [copier] |
| `tests/` | Test files live here; ships with a `.gitkeep` | [copier] |

- **ADR rules:** one ADR per decision; immutable once Accepted; to change a
  decision add a new ADR that supersedes and update the old one's Status
  (Proposed / Accepted / Deprecated / Superseded). Sections: Status, Context,
  Decision, Consequences.
- **`.gitkeep`** keeps otherwise-empty dirs in git (`tests/.gitkeep`,
  `.claude/skills/.gitkeep`, and ansible `roles|playbooks|inventory/.gitkeep`
  for iac). Across the live repos, `docs/` subdirs are also kept with `.gitkeep`
  (harmon-infra: `architecture/decisions/specs`; sommerlawn-web:
  `decisions/runbooks/specs`).
- **Filling content is [manual]:** most generated docs carry literal `TODO:`
  markers (e.g. `security.md`, `design-language.md`, `DESIGN.md`); the operator
  fills them in. The CHECKLIST item "Fill in the `TODO:` markers" tracks this.

### 1.2 Taskfile (`Taskfile.yml`, go-task v3)

**[copier]** generates `Taskfile.yml`. (`Taskfile.yaml` is equally valid — go-task
accepts both; use whichever extension the tool conventionally uses, don't
normalize.) The Taskfile is the **single
source of truth for commands** — lefthook hooks and CI workflows delegate to
`task` targets so local/CI/hook runs are byte-identical. Never reimplement command
logic in a workflow or a hook.

**Staying in sync (no special repo structure). [copier]** `Taskfile.yml` and the
other template-owned files (`scripts/*`, lint configs, the standard workflows,
devcontainer — full list in
[`assets/template-owned-files.txt`](../assets/template-owned-files.txt)) are
refreshed by `copier update`'s three-way merge, which preserves a repo's own edits.
Customize them **normally, in place** — there is no extension-file convention a
repo's developers need to learn. `assets/diff-template.sh` reports both content
`DRIFT` in the curated set and `MISSING` template files the repo lacks entirely
(a whole-render, manifest-independent scan), so an audit/update pulls in missed
improvements (the recurring status.sh / lint-hygiene / bootstrap class) and missed
whole files without losing local customizations — see mode-audit drift class **K**.

Naming & structure conventions:

- **`group:action` (kebab + colon namespacing).** Group/domain first, action
  leaf last: `lint:shell`, `lint:terraform:validate`, `test:e2e`,
  `security:secrets`, `install:hooks`, `status:git`, `deploy:ansible:base`.
  **Never action-first** (`shell:lint`, `yaml:lint`).
- **Pipeline order:** `check → build → validate → test → security`, with
  `verify` (fast local gate) and `ci` (full CI mirror) as aggregates.
  **`verify`** is tuned to stay well under a minute so editors, git hooks, and AI
  agents can run it on every change: `check [→ build] → validate → test:tasks
  [→ test:hooks]`. **`ci`** reproduces the whole CI pipeline on demand (run it
  locally instead of opening a PR): `verify [→ test:devcontainer:permissions] →
  test → security`. The rule: a check only belongs in `verify` if it stays fast;
  heavy or Docker-dependent checks (`test`, `security`, `test:devcontainer:permissions`)
  live in `ci`. Every `task` target a workflow invokes must still exist (drift
  class L) — but `verify` is intentionally a *subset* of what CI runs, so "`verify`
  is green" is not "CI is green"; use `ci` for that.
- **Parallel deps:** umbrella tasks fan out via `deps:` (which run in parallel),
  e.g. `lint` deps on `lint:yaml`, `lint:shell`, `lint:markdown`,
  `lint:actions`, `lint:hygiene`; `security` deps on `security:secrets` +
  `security:audit`; `check` deps on `lint` (+ `typecheck`).
- **`{{.CLI_ARGS | default "."}}` passthrough:** lint tasks accept a file list
  (`task lint:yaml -- file.yml`) and default to the whole tree; lefthook passes
  `{staged_files}` through this so hooks lint only staged files.
- **Group output:** `output.group` wraps each task's output in
  `::group::{{.TASK}}` / `::endgroup::` for collapsible CI logs.
- **`default`** task is an interactive `tv`/`fzf` task menu.

Universal task targets every repo has (from the template):

`default`, `menu`, `menu-tv`, `ci`, `verify`, `check`, `lint`, `lint:yaml`,
`lint:shell`, `lint:markdown`, `lint:actions`, `lint:hygiene`,
`lint:commit-msg`, `validate`, `guard:no-commit-to-main`, `format`, `fix`,
`test`, `security`, `security:secrets`, `security:audit`, `security:sast`
(Snyk), `security:sca` (Snyk), `bootstrap`, `install`, `install:hooks`,
`release:init`, `release:patch`, `release:minor`, `release:major`, `clean`,
`status` (+ `status:git|gh|code|env`), `status:setup`, `util:bunch-add`,
`util:obsidian-add`.

**Lint vs. format discipline (read-only gates).** Every `lint:*` target and the
`check`/`verify` aggregates are **read-only** — they report and fail, never
modify files. All auto-fixing lives in `format`, `format:file`, and `fix` (=
format then lint); **no `lint:*` body runs `--fix`/`--write`/`-w`/`-i`**.
Pre-commit hooks call the read-only `lint:*` so a failing check blocks-and-tells
instead of silently rewriting the tree. **Flag any `lint:*` that mutates** — the
classic regression is `lint:markdown` carrying `markdownlint-cli2 --fix`, which
makes CI report green while discarding the fix and makes the markdown hook commit
the unfixed staged blob (no `stage_fixed`). Formatters (Prettier, Black, shfmt,
`terraform fmt`, markdownlint) have a check side in `lint:*` + a write side in
`format`; pure analyzers (shellcheck, actionlint, yamllint, ESLint, ansible-lint)
are check-only by design.

`status:setup` is a **setup-completeness audit** (run by hand, not part of the
default dashboard): it checks the repo against `docs/CHECKLIST.md` and reports
✓/✗/?/– per item across GitHub config (ruleset, Dependabot alerts, private vuln
reporting, Renovate/CodeRabbit apps, Actions secrets/variables by name only,
GHCR image, linked Project, release), toolchain (`brew bundle check`),
devcontainer profiles, and dev environment (1Password CLI, direnv). Useful as a
quick first pass when auditing an already-standardized repo.

Notable command bodies (for an auditor checking they match):

- `lint:shell` → `shellcheck --severity=error` + `shfmt -d`
- `lint:markdown` → `npx --yes markdownlint-cli2 '**/*.md' '#.claude/**' …`
  (check-only; **no `--fix`** — auto-fix lives in `format`)
- `lint:hygiene` → `./scripts/lint-hygiene.sh`
- `security:secrets` → `gitleaks detect --no-banner --redact --source .`
- `install` → `brew bundle --file=Brewfile` (+ `uv sync` / `pnpm install`) →
  `install:hooks`
- `install:hooks` → `lefthook install`

### 1.3 File/dir naming, branch & commit conventions

- **Doc filenames are kebab-case** (`branch-protection.md`, `ci-cd.md`). The
  conventional uppercase root files keep their names: `README.md`, `AGENTS.md`,
  `DESIGN.md`, `CHANGELOG.md`, `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`,
  `LICENSE`, `CHECKLIST.md`. **[copier]**
- **YAML extensions follow each tool's own convention** — no repo-wide
  `.yml`-vs-`.yaml` normalization (go-task → `Taskfile.yml`, CodeRabbit →
  `.coderabbit.yaml`). Don't rename a tool's file to homogenize extensions.
- **Feature branches only.** Direct commits to `main` are blocked by the
  `guard:no-commit-to-main` pre-commit hook AND the branch ruleset. **[copier]**
  for the hook/ruleset file; **[manual]** to import the ruleset to GitHub.
- **Claude bot branches** are prefixed `claude/` (set in claude workflows and
  parsed by project-automation as `claude/issue-N`).
- **Conventional Commits**, enforced by commitlint (`commit-msg` hook). The
  **type enum** (read from `commitlint.config.mjs`, identical in template and
  both live repos):

  ```text
  build, chore, ci, docs, feat, fix, perf, refactor, revert, style, test
  ```

  Format `type(scope): subject`, imperative mood. Subject/body lines ≤ 100 chars
  (config-conventional). Breaking changes: `feat!:` or `BREAKING CHANGE:` footer.
  **[copier]** ships `commitlint.config.mjs` extending
  `@commitlint/config-conventional`.
- **`TODO:` prefix** (literal, colon) marks unfinished work in code and docs so
  it stays greppable (`rg 'TODO:'`).
- **Never bypass hooks** — `--no-verify` is forbidden (and actively blocked by a
  Claude hook in the devcontainer).

### 1.4 Lint / format configs

All **[copier]** (root-level config files):

| File | Tool | Key settings |
|---|---|---|
| `.editorconfig` | EditorConfig | `root=true`; default 2-space, `lf`, utf-8, final newline, trim trailing ws; **4-space for `*.{py,tf,tfvars,sh}`**; 2-space TOML; Markdown/MDX keep trailing ws (intentional `<br>`); Makefiles tab |
| `.yamllint` | yamllint | `extends: default`; ignores `node_modules/ dist/ .astro/ .task/ .worktrees/ .venv/ .terraform/ pnpm-lock.yaml …`; `line-length max 200` (warn); comments/document-start/truthy disabled |
| `.shellcheckrc` | shellcheck | `disable=SC3037`, `disable=SC2148` |
| `.markdownlint.json` | markdownlint | `default: true`; MD003 atx; MD013 (line-length), MD034, MD036, MD041, MD060 off; blanks-around-headings/lists off |
| `.markdownlint-cli2.jsonc` | markdownlint-cli2 | only when `use_release_please`; `ignores: ["CHANGELOG.md"]` (release-please writes double blanks → MD012) |

Shell scripts must pass `shellcheck --severity=error` + `shfmt -d` and stay
portable to **macOS bash 3.2** (no `mapfile`, no `grep -P`) and Linux.

Conditional formatters/linters (see Part 2 for which project types):

- **prettier** — `prettier.config.cjs` (web only): `prettier-config-standard`
  base, `singleQuote`, no semi, `trailingComma:none`, `printWidth:100`,
  `prettier-plugin-astro` + `prettier-plugin-tailwindcss`.
- **eslint** — web only (config file is added during framework scaffolding,
  [manual]; template provides the `lint:eslint` task that calls `npx eslint`).
- **black** — Python only (`lint:python` → `uv run black --check`).
- **terraform fmt / validate** — iac/terraform only.
- **ansible-lint** — `.ansible-lint` (ansible only).

**Design-bundle shield (`specs/*/`)** — spec *subdirectories* hold vendored
design-handoff bundles (Claude Design exports; deleted at sign-off, never
committed) and are excluded from git and every linter, while top-level
`specs/*.md` stay tracked and linted. Audit that all surfaces agree:
`.gitignore` + `.prettierignore` (`specs/*/`), `.yamllint` ignores
(`specs/*/`), the markdownlint invocation in the Taskfile (`'#specs/*/**'`),
and — web repos, [manual] since those files are scaffolded — eslint `ignores`
(`'specs/'`) and tsconfig `"exclude": ["specs"]`. A repo missing these fails
`verify` the moment a bundle lands (untracked-file hygiene scans included).

### 1.5 Git hooks (lefthook)

**[copier]** ships `lefthook.yml`; installed via `task install:hooks` (`lefthook
install`). `assert_lefthook_installed: true`. Every hook **delegates to a Taskfile
target**.

| Stage | Commands (universal) |
|---|---|
| `pre-commit` (parallel) | `no-commit-to-main` (`task guard:no-commit-to-main`), `yaml`, `shell`, `markdown`, `actions`, `hygiene` — each globbed, passing `{staged_files}` |
| `commit-msg` | `conventional` → `task lint:commit-msg -- {1}` |
| `pre-push` (parallel) | `secrets` → `task security:secrets` |

Project-type stages (added conditionally): pre-commit `prettier`/`eslint`/
`typecheck` (node), `python` (python), `terraform` (terraform); pre-push
`typecheck` (node), `terraform-validate` (terraform), `ansible-syntax` (ansible).

### 1.6 Devcontainer (dual-profile) — when `devcontainer: yes` (default)

**[copier]** generates `.devcontainer/` with **two profiles**:

- **BOT profile** (`.devcontainer/devcontainer.json`) — for AI agents (Claude
  Code, Codex, Gemini). **No Tailscale.** `containerName:
  devcontainer-<slug>-bot`. `CLAUDE_CODE_EFFORT_LEVEL: max`.
- **DEV profile** (`.devcontainer/dev/devcontainer.json`) — human dev. Adds the
  Tailscale feature + `--device=/dev/net/tun` + `TS_AUTHKEY`.

Shared structure:

- **`Dockerfile`** — single Dockerfile, base
  `mcr.microsoft.com/devcontainers/base:ubuntu-24.04`. Tool version pins are
  **`ARG <NAME>_VERSION=…` annotated with `# renovate: datasource=… depName=…`**
  comments (Renovate's regex manager auto-PRs bumps). `NODE_MAJOR` is
  intentionally unmanaged. Layers ordered cheap→volatile (volatile npm globals
  like `@anthropic-ai/claude-code` LAST so frequent bumps don't bust the
  Chromium/Playwright layers).
- **`devcontainer.json` `features`:** python 3.14, docker-in-docker, github-cli,
  go-task, 1password; terraform feature when `include_terraform`; tailscale only
  in dev.
- **`devcontainer.json` `hostRequirements`:** a minimum floor (`cpus: 2`,
  `memory: 4gb`) on both profiles — a hard gate (Codespaces won't offer a smaller
  machine; VS Code warns; Coder ignores it), not a comfort target. Recommended
  sizing lives in `docs/guides/devcontainer-performance.md`.
- **`config/`** — baked dotfiles (zshrc, shell-aliases, starship, tmux, zellij,
  micro, gitconfig, television, agent-deck) + **`config/claude-settings.json`**
  (installed as Claude Code **managed settings** at
  `/etc/claude-code/managed-settings.json`, highest precedence) +
  **`config/claude-hooks/`** (5 hooks: `protect-files.sh`, `block-no-verify.sh`,
  `enforce-conventional-commits.sh`, `post-edit-format.sh`,
  `session-start-context.sh`, installed to `/etc/claude-code/hooks/`;
  `post-edit-format` + `enforce-conventional-commits` delegate to the `format:file`
  / `lint:commit-msg:text` Taskfile targets).
- **Secret standard — 1Password Environments. [manual]** The values in
  `.devcontainer/devcontainer.env` (+ `dev/devcontainer.env`) come from a
  **1Password environment** with destination "Local .env file" mounted at those
  paths — a virtual `.env` over a UNIX pipe, never written to disk or git. Vars:
  `GH_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN`, `AGENT_DECK_TELEGRAM_KEY` (+ `TS_AUTHKEY`
  dev-only).
- **`scripts/init-env.sh`** — runs as `initializeCommand` on the HOST. It does
  **not** call `op`; it enforces the per-profile allow-list (evicts forbidden
  vars — bot strips `TS_AUTHKEY`; **strips `ANTHROPIC_API_KEY` unconditionally**
  since it silently overrides `CLAUDE_CODE_OAUTH_TOKEN`) and seeds the env-file
  from the **host environment** — the path used on **Coder/Codespaces**, where
  secrets arrive as workspace/template parameters. Portable to BSD/macOS sed.
- **`post-create.sh` / `post-start.sh`** (+ `dev/` variants) and
  `scripts/post-create-common.sh`; bot sets git identity to `<user>-bot`.
- **`hooks/post-checkout`** — repo-managed git hook (auto-installs node_modules in
  new worktrees).
- **GHCR prebuild:** images push to `ghcr.io/<org>/<slug>-devcontainer[-dev]`
  (`devcontainer_image`) via the `devcontainer-build.yml` workflow as build
  caches. **[manual]** GHCR publishing permission + first prebuild on merge.
- **Coder. [manual]** The devcontainers are Coder-ready (CODER passthrough;
  `config/` baked to `/usr/local/share/devcontainer-config/` to survive Coder's
  `/tmp` shadowing). The Coder workspace *template* is **org-level infra, not
  per-repo** (canonical: harmon-infra `terraform/coder/devcontainer/`): point its
  `repo` + secret parameters at the repo → host env → `init-env.sh`. The
  generated repo's `docs/guides/devcontainers.md` has the full walkthrough.
- **`devcontainer.env`** is gitignored; only `devcontainer.env.example` is
  committed. **[manual]** to populate real secrets.
- Smoke tests: `task test:devcontainer:root` / `test:devcontainer:dev`.

### 1.7 CI/CD (GitHub Actions)

**[copier]** generates all workflows. Cross-cutting rules:

- **Delegate to `task` targets** (`task check`, `task security`, `task build`,
  `task test`).
- **Pin third-party actions by full commit SHA** + trailing `# vX.Y.Z` comment;
  annotate tool versions with `# renovate: datasource=…`.
- **Least-privilege `permissions:`** per job (top-level `contents: read`).
- **`merge_group`** trigger on `build.yml` (merge-queue support).
- **Aggregate gate:** a final `verify` job (`if: always()`, `needs: [lint,
  security, …]`) reports one rollup status. Branch protection requires the
  **`verify`** and **`security`** checks.
- Fork-PR guard: jobs gate on
  `github.event.pull_request.head.repo.full_name == github.repository`.

Workflow inventory:

| Workflow | Triggers / role | Source |
|---|---|---|
| `build.yml` (`Build & Validate`) | push/PR/`merge_group`/dispatch; jobs `lint`, `security` (+ `build-test` node, `lighthouse` web-astro), aggregate `verify` | [copier] |
| `claude-plan.yml` | `@claude plan` / `claude-plan` label → posts a plan, no writes (`--disallowedTools Edit Write Bash`, `--model opus`) | [copier] |
| `claude-implement.yml` | `@claude implement` / label → opens a PR on a `claude/` branch (`--model sonnet`) | [copier] |
| `claude-review.yml` | `@claude review` / label → review comment, no writes (sticky comment) | [copier] |
| `release.yml` | release-please; only when `use_release_please` | [copier] |
| `codeql.yml` | only when `use_node or use_python`; **opt-in via `FULL_SECURITY_SCAN=true`** variable; aggregate `codeql-verify` | [copier] |
| `devcontainer-build.yml` | only when `devcontainer`; builds bot+dev images, pushes GHCR caches on merge to main | [copier] |
| `project-automation.yml` | only when `github_org != author_git_provider_username` (org repos); syncs org Project V2 Status field | [copier] |

**GitHub App auth** (the claude-* workflows, `release.yml`, and
`project-automation.yml`): authenticate as a **`<owner>-ci` GitHub App** (one App
per org/account), not a PAT. Each job mints a short-lived (~1h) token via
`actions/create-github-app-token` reading **`CI_APP_CLIENT_ID`** (Actions **variable**) +
**`CI_APP_PRIVATE_KEY`** (Actions **secret**), with **least-privilege
`permission-*` inputs** (e.g. plan: `permission-contents: read` +
`permission-issues|pull-requests: write`; implement adds
`permission-workflows: write`; org repos add `permission-organization-projects:
write`, `permission-members: read`). Requesting a permission the installation
lacks fails token minting — that's why org-only perms are jinja-gated.
`.github/github-app-manifest.json` is the machine-readable permission reference.
**[manual]:** create the App, install it on the repo, set the variable + secret.

Required secrets/variables (**[manual]**, in CHECKLIST): `CLAUDE_CODE_OAUTH_TOKEN`
(secret), `SNYK_TOKEN` (secret), `CI_APP_CLIENT_ID` (variable) + `CI_APP_PRIVATE_KEY`
(secret), `FULL_SECURITY_SCAN=true` (variable, to enable CodeQL).

### 1.8 Security

- **gitleaks** — `.gitleaks.toml` (`[extend] useDefault = true` + an
  `[allowlist] paths` of build/cache dirs). Runs at pre-push (`task
  security:secrets`) and in the `build.yml` `security` job (with the
  `summarize-gitleaks.mjs` GH step summary). **[copier]**
- **Snyk** — `task security:sast` (`snyk code test`) + `security:sca` (`snyk
  test`); needs `SNYK_TOKEN`. **[copier]** for tasks; **[manual]** for the token.
- **CodeQL** — `codeql.yml`, opt-in via `FULL_SECURITY_SCAN`. **[copier]** /
  **[manual]** to enable.
- **Branch protection ruleset** — `.github/Branch Protection Ruleset - Protect
  Main.json`: blocks deletion/non-ff/creation, requires linear history, PR with 1
  code-owner approval + thread resolution + last-push approval, required status
  checks `verify` + `security`, merge methods squash/rebase; org repos add a
  `merge_queue` rule. **[copier]** ships the file; **[manual]** import via the
  GitHub UI (Settings → Rules → Rulesets → **Import a ruleset**) — not
  `gh api … rulesets`, whose `POST` is non-idempotent (duplicates the ruleset)
  and rejects the `merge_queue` rule (422); edit the existing ruleset in the UI
  to change it later.
- **`SECURITY.md`** lives in **`.github/`** (Private Vulnerability Reporting).
  **[copier]**
- **Renovate, NOT Dependabot** for version updates. CHECKLIST explicitly says
  enable Dependabot *alerts* + Private vulnerability reporting but **do NOT add
  `dependabot.yml`** — Renovate owns updates. **[manual]** repo settings.
- **`CODEOWNERS`** = `* @<code_owner>` — an asked question that defaults to `github_org`. **[copier]**
- **Secrets via 1Password** locally (`op run`/`op inject`); CI reads Actions
  secrets. **`.env` is fully gitignored** (`.env`, `**/.env`, `.env.*`); commit
  only `.env.example`-style files. **[copier]** gitignore; **[manual]** wiring.

### 1.9 Dependency management (Renovate)

**[copier]** ships `renovate.json` (extends `config:recommended`). **[manual]**
install the Renovate GitHub App on the repo. Conventions:

- **`automerge: false`** globally; **`minimumReleaseAge: 3 days`** on all
  packages (stability gate).
- **Custom (regex) managers** for pins invisible to native managers:
  - Devcontainer **Dockerfile `ARG …_VERSION`** annotated with `# renovate:`.
  - **Workflow tool pins** — both `version:` style and `FOO_VERSION=x.y.z`
    shell-variable style, under `.github/workflows/`.
  - Ansible: annotated container images + `*_version` vars (iac only).
- **Batching (groupName):** GitHub Actions, Docker images, Devcontainer, npm,
  Terraform providers each into one PR.
- **`anthropics/claude-code-action` ejection:** removed from the Actions group
  (`groupName: null`) and `minimumReleaseAge: 0 days` (ships near-daily; grouping
  - the 3-day gate kept the whole batch perpetually pending). Rule ordered AFTER
  the group rules so the override wins.
- npm `overrides` deptype disabled (avoids `EOVERRIDE`).
- `dependencyDashboard: true`; weekly schedule `before 9am on Monday`,
  `timezone: America/Chicago`.

### 1.10 AI steering

- **`AGENTS.md` is the canonical source of truth.** `CLAUDE.md`, `GEMINI.md`, and
  `.github/copilot-instructions.md` are **symlinks** to it — edit only
  `AGENTS.md`. (`copier.yml` sets `_preserve_symlinks: true`.) Live repos at older
  commits have the symlink flipped the other way (`AGENTS.md -> CLAUDE.md`) — see
  Part 3. **[copier]**
- **`.claude/settings.json`** (repo-level): minimal allow-list —
  `Bash(task:*)`, `Bash(git status:*)`, `Bash(git diff:*)`, `Bash(git log:*)` —
  plus a `permissions.ask` list that forces a prompt on merge commands:
  `gh pr merge` (all variants incl. `--auto`/`--admin`), `git merge`,
  `git push origin main`, and force pushes (harmon-init ≥3.18.0, init #221).
  **[copier]**
- **Agents never merge to main.** AGENTS.md Definition of Done carries the rule
  (harmon-init ≥3.18.0, init #221): no `gh pr merge`/`git merge`/push to `main`
  without the maintainer's explicit per-merge approval, even with green CI and
  a permissive ruleset — open the PR, report checks, stop. The settings `ask`
  rules above are the harness backstop (note: `ask` is skipped under
  `bypassPermissions`, e.g. the devcontainer bot profile — the AGENTS.md rule
  is the binding convention there). **[copier]**
- **`.claude/skills/`** with a `.gitkeep`. **[copier]**
- Devcontainer ships richer `config/claude-settings.json` as managed settings (see
  1.6). **[copier]**
- **`DESIGN.md`** — AI-facing statement of design intent (the *why*/prose rules);
  web types get a "Visual & UX direction" section. **[copier]** ships it with
  `TODO:` placeholders; **[manual]** to fill in.

### 1.11 Package / tool management

> **Local ↔ devcontainer parity (a hard goal).** Every tool the repo's
> `Taskfile` targets, lefthook hooks, and `scripts/` invoke must be installable
> **locally via the `Brewfile`** — the repo's tooling has to run on a bare host,
> not only inside the devcontainer. When the repo ships a devcontainer, the
> `Brewfile` (host) and the devcontainer `Dockerfile` (container) must cover the
> **same toolset** so `task <anything>` behaves identically in both. Concretely:
> if a task/script/hook calls a binary (e.g. `gum`, `tv`/television, `tokei`,
> `jq`, `gitleaks`, `shfmt`), that binary belongs in the `Brewfile` — and, if a
> devcontainer exists, also in the `Dockerfile`. Auditing this is a first-class
> check (see mode-audit drift class **I**).

- **`Brewfile`** — pins the core toolchain (go-task, lefthook, git, gh,
  shellcheck, shfmt, actionlint, yamllint, gitleaks, snyk, node, jq, fzf, fd,
  ripgrep, bat, tokei, gum, television; conditionally pnpm/lychee, uv, terraform,
  hadolint). `gum` + `television` (the `tv` binary) power the universal
  `status`/`status:*` dashboard and the interactive `task` menu (`menu-tv`), so
  they are required for the dashboard and the bare-`task` menu to work on a host.
  Installed via `task install`. `Brewfile.lock.json` is gitignored. **[copier]**
- **Python** (when `use_python`): `pyproject.toml` (`requires-python >=3.14`,
  dev group with `black`; ansible adds `ansible-lint`/`ansible-core`),
  **`.python-version`** = `3.14`, `.envrc` (direnv), managed with **uv** (`uv
  sync`). **[copier]**
- **Node** (when `use_node`): managed with **pnpm**; `package.json` must declare
  `"packageManager": "pnpm@…"` and `engines.node`. The template provides the
  Brewfile/Taskfile/devcontainer wiring; **`package.json` itself is created during
  framework scaffolding** ([manual] — see Part 2 / CHECKLIST).

### 1.12 Versioning & releases

- **Conventional commits drive releases.** **release-please** (when
  `use_release_please`, default yes) maintains a rolling release PR;
  **merging that PR** is the intentional act that cuts the tag + GitHub release +
  CHANGELOG entry (`feat`→minor, `fix`→patch; pre-1.0 `feat` bumps minor;
  chore/docs/ci → no release). Files: `release-please-config.json`,
  `.release-please-manifest.json`. **[copier]**
- **A change that alters what the repo emits to consumers must be `fix:`/`feat:`,
  never `chore:`.** This matters most for a *template/library* repo (e.g.
  harmon-init): a `chore:` edit to generated output — `template/**`, `copier.yml`
  `_tasks`, or a shipped file's mode (`chmod +x`) — cuts no release, so downstreams
  pinned to a tagged `_commit` can never `copier update` to it (they'd have to chase
  untagged HEAD via `--vcs-ref=HEAD`, which the update path forbids). Reserve
  `chore:`/`docs:`/`ci:` for changes that do **not** affect what consumers receive.
- **Keep a Changelog** format; `CHANGELOG.md` is release-please-generated (and
  ignored by markdownlint). **[copier]** seeds it.
- `task release:init` seeds the first `v0.1.0`; `task release:patch|minor|major`
  remain a **manual override**. **Releases are never automated on a normal merge
  to main.** **[manual]** to actually cut a release.
- Other root files: `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, `LICENSE`
  (mit/private), `<slug>.code-workspace`, `.vscode/{settings,extensions}.json`,
  `.coderabbit.yaml` (CodeRabbit reviews — [manual] install the app),
  `.github/PULL_REQUEST_TEMPLATE.md`, the `.github/ISSUE_TEMPLATE/` YAML **Issue
  Forms** (`{bug,feature,task,research}.yml` and `config.yml`, always generated —
  see §1.13 for the `type:`/assignee behavior), `.dockerignore`. **[copier]**

### 1.13 Project management (GitHub Projects) — when `project_management: github`

The `project_management` copier answer (`github` / `linear` / `none`, default
`none`) gates a GitHub-Projects playbook. **`github`** ships
`docs/project-management.md` — the authoritative doc (statuses, fields, labels,
milestones, hierarchy, cross-repo, views) — plus the setup tasks/scripts below.
**`linear`** ships a `# Linear` TODO stub; **`none`** ships neither. **[copier]**
for the doc/tasks/workflows; **[manual]** to run the setup (they hit the live
GitHub API and are shellcheck/shfmt-gated only, never CI-tested).

**One default Project (V2) per owner**, titled after the owner's GitHub login
(`<owner> Project`); every repo feeds the one board. Slice it (by Product /
`layer:` / Agent) instead of spinning up more projects.

**Setup tasks** (idempotent + non-destructive; **[copier]** generates them, **[manual]** to run):

| Task | Needs | Rendered when | Does |
|---|---|---|---|
| `setup:github-project` | `gh` + `project` scope | `project_management: github` | Create/sync the board + `Status` pipeline; write the `ORG_PROJECT_ID` org var (org only); on a **personal** account also create Priority/Effort/Product/Agent as project fields |
| `setup:github-labels` | `gh` + repo write | `project_management: github` | `gh label create --force` for the five label families |
| `setup:github-issue-fields` | `gh` + `admin:org` | `github` **and** org owner | Add the org **issue fields** Product + Agent (public preview) |
| `setup:github-issue-types` | `gh` + `admin:org` | **org owner** (independent of `project_management`) | Ensure org issue types Bug/Feature/Task/Research (Task is GitHub's default; adds Research) |

**Conventions the doc encodes** (audit the doc + the field/label/workflow
artifacts; the prose rules are guidance, not lint):

- **`Status`** — project single-select, one meaning ("where in delivery"):
  Inbox/Icebox/Next · Todo/Shaping/Ready/Agent Queue · In Progress/Verifying/
  In Review/Ready to Merge · Done/Deployed/Accepted. `Done` is the sole terminal
  status; **no `Archived`** (native 90-day auto-archive); Canceled/Duplicate are
  close reasons; Blocked is the native blocked-by relationship or `blocked` label.
  `Agent Queue` is the AI-agent hand-off lane.
- **Fields** — `Status` is a project field. **Size is ALWAYS a project Number
  field** (estimation points, Fibonacci): only project number fields sum in view
  group headers, so it lives on the project even for orgs. The GitHub built-in
  issue fields (**Priority**, single-select **Effort**, Start/Target date) are
  left at their defaults; **Product + Agent** are org issue fields from
  `setup:github-issue-fields`. On a personal account (no issue fields)
  `setup:github-project` creates Priority/Product/Agent/Size as project fields.
- **Issue types** — Bug/Feature/Task/Research (org). The Issue Forms set `type:` on
  org repos and a **default assignee**, and apply **no labels** (type is the Type
  field, not a label).
- **Labels** — repo-level, five color families (Concerns / Source / Workflow /
  Layer / Domain), orthogonal to Status and Type. There is no shared org label
  pool; run `setup:github-labels` per repo.
- **Milestones** — named after release versions (title == git tag), small +
  rolling, preferred over iterations pre-launch.
  `.github/workflows/close-milestone-on-release.yml` closes the matching milestone
  on release publish — **[copier]** when `use_release_please` + `github`.
- **Views** (Board / Triage / Agent queue / Planning / Mine) are **UI-only** —
  Projects V2 has no view API. **[manual]**.
- **Hierarchy** — sub-issues, no Epic type: the parent holds the spec +
  milestone/project (children inherit both); leaves hold the `Task` type + `Effort`
  points.

**Org-only automation** (`github_org != author`):
`.github/workflows/project-automation.yml` syncs `Status` from PR/CI events as the
CI GitHub App, reading the `ORG_PROJECT_ID` org variable (title fallback).
**[copier]**. The project's built-in **"Auto-add to project"** workflow
(**[manual]**, UI, no API) puts every issue/PR on the board.

---

## Part 2 — By project type

Driven by the `project_type` copier answer: `general` / `web-astro` / `web-app` /
`iac` / `docs`. Two derived flags gate most behavior: `use_node` (true for
`web-astro`, `web-app`) and `use_python` (true for `iac` or when
`include_ansible`). `include_terraform` / `include_ansible` default to true for
`iac`.

**Important:** harmon-init is a **conventions-only** template — for web/app types
it scaffolds the tooling/config but **not the framework itself**. Installing the
actual framework + stack is a [manual] CHECKLIST step.

### 2.1 general

The baseline. Only Part 1 universals apply. `use_node`/`use_python` both false
unless ansible/terraform opted in.

- `test` task is a `TODO:` echo pointing to `tests/` + `docs/architecture/tests.md`. [copier]
- `validate` task echoes "No validate steps for this project type yet — see docs/CHECKLIST.md." [copier]
- `security:audit` echoes "No package manifests to audit yet." [copier]
- **[manual]:** add the primary toolchain; extend `build`/`test` accordingly.

### 2.2 web-astro (marketing/static sites) — `use_node: true`

Adds (all [copier] unless noted):

- **Taskfile:** `build` (`pnpm build`), `build:preview`, `dev`, `typecheck`
  (`astro check`), `lint:prettier`, `lint:eslint`, `test` (vitest if config
  present), `test:e2e[:screenshot|:pdf]` (Playwright); `verify`/`ci` include
  `build`.
- **prettier.config.cjs**, eslint task. **lefthook** adds prettier/eslint/
  typecheck (pre-commit) + typecheck (pre-push).
- **`lighthouserc.json`** + a **`lighthouse`** CI job in `build.yml` (Chrome
  install, LHCI, PR comment). Asserts perf ≥0.7 (warn), a11y ≥0.85, BP ≥0.7, SEO
  ≥0.9.
- **`docs/architecture/design-language.md`** + DESIGN.md "Visual & UX direction".
- Devcontainer forwards port **4321** (Astro dev server); `astro-build.astro-vscode` extension.
- `codeql.yml` analyzes `javascript-typescript`.
- **[manual] CHECKLIST:** `pnpm create astro@latest .`; add **Tailwind v4**
  (`@tailwindcss/vite`), **zod**, **vitest**, **lucide**; move lint tooling into
  `devDependencies`; switch Taskfile `npx --yes` calls to `pnpm exec`; review
  `lighthouserc.json` URLs; enable **mobile device projects** in
  `playwright.config.ts` (e.g. Pixel + iPhone — the scaffold ships them
  commented out, and mobile-first is the stated convention).

### 2.3 web-app (TanStack/React apps) — `use_node: true`

Same node tooling as web-astro **except**:

- `typecheck` uses `tsc --noEmit` (not `astro check`). [copier]
- **No** Lighthouse job / `lighthouserc.json` (that's web-astro only). [copier]
- DESIGN.md / design-language reference **shadcn/ui** as the component set. [copier]
- **[manual] CHECKLIST:** `pnpm create @tanstack/start@latest` (TanStack Start)
  or vite + react; add **Tailwind v4**, **shadcn/ui**, **zod**, **vitest**,
  **lucide**; move lint tooling to `devDependencies`; switch to `pnpm exec`.

### 2.4 iac (Terraform/Ansible) — `use_python: true`

Adds (all [copier]):

- **`include_terraform`** → `terraform/` skeleton (`main.tf`, `variables.tf`,
  `outputs.tf`, `tfvars.env.example`); tasks `lint:terraform` (`fmt -check`),
  `lint:terraform:validate`, `validate`→validate; lefthook terraform (pre-commit)
  - terraform-validate (pre-push); terraform devcontainer feature; Renovate
  Terraform-providers group; hashicorp/terraform extension.
- **`include_ansible`** → `ansible/` skeleton (`ansible.cfg`, `requirements.yaml`,
  `inventory/ playbooks/ roles/` each `.gitkeep`); **`.ansible-lint`**; tasks
  `lint:ansible`, `validate:ansible:syntax` (both guard on `ansible/site.yml`
  existing); lefthook ansible-syntax (pre-push); `ANSIBLE_CONFIG` remoteEnv;
  Renovate ansible regex managers; redhat.ansible extension.
- **Python toolchain** active (uv, black, `.python-version`, pyproject).
- `codeql.yml` analyzes `python` (if use_python).
- **[manual] CHECKLIST:** lay out `terraform/` and/or `ansible/site.yml` — lint
  tasks activate automatically once `ansible/site.yml` exists.
- The live `harmon-infra` shows how deep the namespacing legitimately goes:
  `lint:terraform:{docs,tflint,validate,security}`,
  `validate:templates:*`, `deploy:ansible:{base,docker,services,…}`,
  `terraform:{init,plan,apply,output}` — all still `group:action` kebab.

### 2.5 docs (documentation/Obsidian) — neither node nor python

Like `general` (no `build`/framework). [copier]

- **[manual] CHECKLIST:** decide the docs toolchain (plain markdown / Obsidian
  vault / static site generator).
- `obsidian_project_add` (default no) wires `util:obsidian-add` + a vault note.

---

## Part 3 — Known divergences (do NOT flag these)

Legitimately repo- or type-specific differences. An auditor should treat these as
**expected**, not drift.

### 3.1 Conditional-by-design (driven by copier answers)

- **No `terraform/` or `ansible/`** in non-iac repos (gated by
  `include_terraform`/`include_ansible`).
- **No node tooling** (`prettier.config.cjs`, `build`/`dev` tasks, eslint/
  typecheck hooks, `lighthouse` job) in non-web repos.
- **No `pyproject.toml`/`.python-version`/`.envrc`/black** when `use_python` is
  false (general/web/docs without ansible).
- **No `lighthouserc.json` / lighthouse job** outside `web-astro`.
- **No `.devcontainer/`** when `devcontainer: no` (e.g. harmon-infra was
  generated with `devcontainer: false`, so it lacks the dual-profile setup — it
  later added its own `.devcontainer/`).
- **No `release.yml` / release-please manifest** when `use_release_please: no`
  (then releases are purely `task release:*`).
- **No `codeql.yml`** when neither node nor python.
- **No `project-automation.yml`, no org `merge_queue` rule, no
  `permission-organization-projects`/`permission-members`** for personal-account
  repos (`github_org == author_git_provider_username`). Org repos get all three.
- **`design-language.md` / DESIGN.md web section** only for web types; shadcn/ui
  named only for `web-app`.
- **macOS-only meta** (`util:bunch-add`/`util:obsidian-add`, `.meta/`, Bunch
  cask) gated by `bunch_add`/`obsidian_project_add` (default no).

### 3.2 Tech-stack preferences (web), expected to vary by repo

These are **defaults/recommendations**, not hard requirements — a conforming repo
picks from this palette:

- **Astro** (web-astro), **TanStack Start / vite + react** (web-app),
  **TypeScript**, **Vite**, **pnpm**, **Tailwind v4**, **zod**, **vitest**,
  **lucide** (icons), **shadcn/ui** (web-app components), **alpine** (some Astro
  marketing sites — e.g. sommerlawn-web uses `@astrojs/alpinejs` + `alpinejs`).
- A real web repo's `package.json` (sommerlawn-web) legitimately carries many
  extra deps (markdoc, mermaid, photoswipe, remark/rehype plugins, sitemap,
  astro-seo) and a large `pnpm.overrides` security-pin block + `auditConfig
  .ignoreCves`. **Do not flag** project-specific dependencies, overrides, or
  CVE-ignore entries — those are app decisions.

### 3.3 Drift from older template commits (recognition patterns for un-reconciled repos)

Repos generated from **pre-v3** harmon-init that haven't been reconciled show
these patterns. The platform/client reference repos were reconciled in 2026-06/07
and no longer do — keep the list for **other** older repos (pre-v3 personal or
client projects) an audit may target. These are **template-version lag**, not
violations of intent — a repo being *brought up to current standard* would update
them:

- **Symlink direction flipped:** live repos have `AGENTS.md -> CLAUDE.md` (and
  `GEMINI.md -> CLAUDE.md`), keeping the real content in `CLAUDE.md`. The current
  template makes **`AGENTS.md` canonical** with the others symlinked to it.
- **File extensions (not drift):** repos vary between `.yml` and `.yaml`
  (e.g. `Taskfile.yaml` vs `Taskfile.yml`). This is by design — use whichever
  extension each tool conventionally uses; never normalize or flag it.
- **Older docs layout:** live repos have flat top-level docs (`docs/security.md`,
  `docs/branchProtection.md` (camelCase!), `docs/containerUpdates.md`,
  `docs/dependencyUpdates.md`, `docs/architecture/architecture.md`) instead of the
  current `product/ architecture/{ci-cd,security,branch-protection,tests} guides/
  runbooks/` + kebab-case filenames. They lack `docs/product/`, `docs/guides/`,
  `docs/glossary.md`, `docs/conventions.md`.
- **Split CI workflows:** an older repo may split `build`/`security`/`validate`
  into separate workflow files where the current template consolidates
  lint+security+build-test into `build.yml`. NB: **harmon-infra retains** its
  split workflows, extra `deploy.yaml`/`mirror-devcontainer-base.yaml`, and
  self-hosted `contraption` runners as an **accepted permanent customization** —
  treat that as 3.2-class, not lag. (sommerlawn-web's old `-max` claude-workflow
  variants are gone; its extra `links-online.yml` is a legit addition.)
- **Older copier answer keys:** a pre-v3 `.copier-answers.yml` references
  now-renamed/removed questions (`github_collaboration_templates`,
  `run_task_bootstrap`, `project_url`).
- **Stale `requirements.txt`** alongside `pyproject.toml`/`uv.lock` — the current
  template is uv/pyproject-only. (Removed from harmon-infra 2026-07-03 once its
  last consumer, a legacy Snyk CI step, was dropped.)

When auditing: distinguish "**legit conditional/stack difference**" (3.1, 3.2 —
leave alone) from "**template-version lag**" (3.3 — candidate for an update toward
the current convention, but not a correctness bug).
