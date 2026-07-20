# Standards Catalog

The authoritative list of attributes a repo should have to conform to the
[harmon-init](https://github.com/evanharmon1/harmon-init) Copier template
conventions. An auditing or scaffolding agent consults this to answer: **"what
should this repo have, and where does it come from?"**

Ground-truth sources (read these, don't trust memory): `harmon-init/copier.yml`,
`harmon-init/AGENTS.md`, the `harmon-init/template/` tree. Live reference repos
that have been generated from the template: `harmonops/harmon-infra` (an `iac`
project) and `sommerlawn/sommerlawn-site` (a `web-astro` project). This catalog
was refreshed against harmon-init v3.26.1 and harmon-devkit v0.6.2 on 2026-07-13.
The platform and client repos are kept current via mode-update passes, so their
remaining divergences are often **deliberate customizations** (Part 3.2), not lag
— but they can drift between passes, so
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
  (harmon-infra: `architecture/decisions/specs`; sommerlawn-site:
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
(a whole-render, manifest-independent scan). It compares an unstaged tracked
deletion from the index and reports mature nested Terraform/ADR replacements as
benign `EQUIV`, so an audit/update pulls in missed improvements (the recurring
status.sh / lint-hygiene / bootstrap class) and missed whole files without losing
local customizations — see mode-audit drift class **K**.

Naming & structure conventions:

- **`group:action` (kebab + colon namespacing).** Group/domain first, action
  leaf last: `lint:shell`, `lint:terraform:validate`, `test:e2e`,
  `security:secrets`, `install:hooks`, `status:git`, `deploy:ansible:base`.
  **Never action-first** (`shell:lint`, `yaml:lint`).
- **Pipeline order:** `check → build → validate → test → security`, with
  `verify` (fast local gate) and `ci` (full CI mirror) as aggregates.
  **`verify`** is tuned to stay well under a minute so editors, git hooks, and AI
  agents can run it on every change: `check [→ build] → validate
  [→ test:devcontainer:permissions] → test:tasks [→ test:hooks]`. The devcontainer
  permission assertion is a static, daemon-free configuration check. **`ci`**
  reproduces the whole CI pipeline on demand (run it locally instead of opening a
  PR): `verify → test → security`. The rule: a check only belongs in `verify` if
  it stays fast; genuinely heavy or environment-dependent checks (`test`,
  `security`, container smoke/build tests) live in `ci`. Every `task` target a
  workflow invokes must still exist (drift
  class L) — but `verify` is intentionally a *subset* of what CI runs, so "`verify`
  is green" is not "CI is green"; use `ci` for that.
- **Repo-specific test reachability:** a test is a real local/CI gate only when
  `task install` (the root `Brewfile`) supplies its local runtime, CI
  provisions the same runtime, and the workflow invokes `task test` or that
  specific target. Merely adding it beneath the Taskfile's `test` aggregate is
  not enough when the workflow still calls only `test:tasks`.
- **Hermetic task regression tests:** current `test:tasks` uses temporary fake
  `brew`, `npm`, and `curl` commands; it must not install or update shared
  machine tools. When auditing multiple repos, run older live-tool variants
  serially until the current hermetic script is ported.
- **Parallel deps:** umbrella tasks fan out via `deps:` (which run in parallel),
  e.g. `lint` deps on `lint:yaml`, `lint:shell`, `lint:markdown`,
  `lint:actions`, `lint:hygiene`; `security` deps on `security:sast` +
  `security:secrets` + `security:audit`; `check` deps on `lint` (+
  `lint:typescript` on node repos — the old bare `typecheck` name survives as an
  alias).
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
(Semgrep CE), `security:sca` (free package-audit alias),
`security:sast:snyk`, `security:sca:snyk`, `secret:set:1p`, `secret:set:gh`,
`bootstrap`, `install`, `install:hooks`, `release:init`, `release:patch`,
`release:minor`, `release:major`, `clean`, `status` (+
`status:git|gh|code|env`), `status:setup`, `util:bunch-add`,
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
reporting, visibility-appropriate SAST route, Renovate/CodeRabbit apps, Actions
secrets/variables by name only, GHCR image, linked Project, release), toolchain
(`brew bundle check`), devcontainer profiles, and dev environment (1Password
CLI, direnv). Useful as a quick first pass when auditing an already-standardized
repo.

Notable command bodies (for an auditor checking they match):

- `lint:shell` → `scripts/shell-quality.sh check`, which passes NUL-delimited
  tracked `*.sh`/`*.bash` paths (or explicit argv paths) intact to
  `shellcheck --severity=error` + `shfmt -d`; `format` calls the same helper
  in write mode
- `lint:markdown` → markdownlint-cli2 `'**/*.md' '#.claude/**' …` — prefers the
  repo-pinned `node_modules/.bin` copy when installed, then a global
  `markdownlint-cli2` from the Brewfile, then a version-pinned npx fallback;
  same pattern in
  `format`/`format:file` for prettier + markdownlint (check-only here; **no
  `--fix`** — auto-fix lives in `format`)
- `lint:hygiene` → `./scripts/lint-hygiene.sh`
- `security:secrets` → `gitleaks detect --no-banner --redact --source .`
- Python `security:audit` → fail-closed `scripts/python-audit.sh`: with a
  `uv.lock`, require it to match `pyproject.toml` while exporting the exact graph
  with `uv export --locked --all-extras --all-groups`; before the first lock,
  compile the project plus `dev` group to a temporary requirements file. Audit
  it with pinned `pip-audit==2.10.1`; no `|| true` or ignored exit status. Any
  CI-only command that consumes an existing lock must use `--locked` (for
  example, `uv sync --locked`) or first run `uv lock --check`; CI must fail on
  staleness and never silently rewrite the lock. Local install/update workflows
  may intentionally create or refresh it.
- `security:sast` → `./scripts/run-semgrep.sh` (Semgrep CE; no account/token)
- `security:sca` → the same free package-manager audit as `security:audit`
- `security:sast:snyk` / `security:sca:snyk` → explicit optional Snyk Code /
  Open Source second-opinion scans; the latter uses `--all-projects`; both accept
  CLI args so the scheduled workflow can pass the repository URL
- `secret:set:1p` / `secret:set:gh` → `./scripts/secret-set-{1p,gh}.sh` —
  destination-only secret writes, value on **stdin** (see §1.8)
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
  Code, Codex, Gemini). **No Tailscale and no 1Password CLI feature** — the bot
  container must hold no path to the tailnet or a credential store
  (`devcontainer-assert.sh` enforces both structurally, per profile).
  `containerName: devcontainer-<slug>-bot`. `CLAUDE_CODE_EFFORT_LEVEL: max`.
- **DEV profile** (`.devcontainer/dev/devcontainer.json`) — human dev. Adds the
  Tailscale feature + `--device=/dev/net/tun` + `TS_AUTHKEY` + the 1Password
  CLI feature.

Shared structure:

- **`Dockerfile`** — single Dockerfile, base
  `mcr.microsoft.com/devcontainers/base:ubuntu-24.04`. Tool version pins are
  **`ARG <NAME>_VERSION=…` annotated with `# renovate: datasource=… depName=…`**
  comments (Renovate's regex manager auto-PRs bumps). `NODE_MAJOR` is
  intentionally unmanaged. Layers ordered cheap→volatile (volatile npm globals
  like `@anthropic-ai/claude-code` LAST so frequent bumps don't bust the
  Chromium/Playwright layers).
- **`devcontainer.json` `features`:** python 3.14, docker-in-docker, github-cli,
  go-task; terraform feature when `include_terraform`; 1password and tailscale
  only in dev.
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
- **Static permission test:** `test:devcontainer:permissions` calls
  `read-configuration` with `--docker-path /usr/bin/true`, so the fast
  configuration/permission assertion remains Docker-daemon-independent.
- **Smoke tests:** `task test:devcontainer:root` /
  `test:devcontainer:dev` require Docker and GNU `timeout`. They hard-bound
  daemon preflight and cleanup at `-k 5 20`, and the full `devcontainer up`
  lifecycle at `-k 30 1800`, so a wedged daemon or build cannot hang fleet
  verification indefinitely.

### 1.7 CI/CD (GitHub Actions)

**[copier]** generates all workflows. Cross-cutting rules:

- **Delegate to `task` targets** (`task check`, `task security`, `task build`,
  `task test`).
- **Pin third-party actions by full commit SHA** + trailing `# vX.Y.Z` comment;
  annotate tool versions with `# renovate: datasource=…`.
- **Least-privilege `permissions:`** per job (top-level `contents: read`).
- **`merge_group`** trigger on `build.yml` (merge-queue support).
- **Aggregate gate:** a final `verify` job (`if: always()`, `needs: [lint,
  security, …]`) reports one rollup status. Branch protection requires
  **`verify`** and **`security`**, plus **`codeql-verify`** exactly when
  `use_codeql=true` and **`terraform-verify`** for a Terraform-capable
  repo (when `include_terraform=true`, the Terraform aggregate is required).
  Result acceptance is predicate-exact, never a generic
  `success || skipped` allowlist. On a fork PR, every fork-suppressed leaf must be
  exactly `skipped`; the diagnostic is workflow-inline, states the untrusted-fork
  boundary explicitly, and neither checks out nor executes repository-controlled
  code. On a same-repository PR or non-PR event, every required leaf must be
  exactly `success`; a conditionally disabled leaf may be `skipped` only when its
  explicit change/enabled predicate proves that exact result. Reject `failure`,
  `cancelled`, `timed_out`, unexpected `skipped`, unexpected `success`, and every
  unknown state. A check that rejects only `failure` is fail-open. The
  `devcontainer-verify` aggregate follows the identical fork-skipped/trusted-
  success contract for its build leaf.
- Fork-PR guard: jobs gate on
  `github.event.pull_request.head.repo.full_name == github.repository`.
- **Runner trust boundary [manual residual / audit requirement]:** public
  `pull_request` jobs must stay GitHub-hosted; never let `CI_RUNS_ON` redirect
  them to persistent self-hosted runners.
  Self-hosted execution is limited to private/trusted repositories or trusted
  `push`/`workflow_dispatch` events, with server-side repository-scoped runner
  groups **and** clean ephemeral/JIT isolation. Keep same-repository guards on
  configurable-runner jobs as defense in depth, but a job guard alone is not a
  complete trust boundary. The current template's configurable-runner pattern
  does not mechanically enforce hosted-only public PRs: audit repository
  visibility, events, and `CI_RUNS_ON`, then specialize `runs-on` where needed.
  See [GitHub's self-hosted runner hardening
  guidance](https://docs.github.com/en/actions/reference/security/secure-use#hardening-for-self-hosted-runners).
- **Self-hosted-safe temporary artifacts:** never use a shared fixed `/tmp`
  path for sensitive or cross-step state such as a saved Terraform plan. Create
  a private per-repo/run path beneath `${{ runner.temp }}` (include run
  id/attempt), pass that exact path between steps, and clean it up.

Workflow inventory:

| Workflow | Triggers / role | Source |
|---|---|---|
| `build.yml` (`Build & Validate`) | push/PR/`merge_group`/dispatch; jobs `lint`, `security` (+ `build-test` node, `lighthouse` web-astro); Semgrep runs for free private repos or profiles without CodeQL; aggregate `verify` | [copier] |
| `claude-plan.yml` | `@claude plan` / `claude-plan` label → posts a plan, no writes (`--disallowedTools Edit Write Bash`, `--model opus`) | [copier] |
| `claude-implement.yml` | `@claude implement` / label → opens a PR on a `claude/` branch (`--model sonnet`) | [copier] |
| `claude-review.yml` | `@claude review` / label → review comment, no writes (sticky comment) | [copier] |
| `release.yml` | release-please; only when `use_release_please` | [copier] |
| `codeql.yml` | only when `use_codeql=true`; triggers on PR and `merge_group` so required `codeql-verify` reports; matrix is exactly `codeql_languages`; automatic/free for public repos; private/internal requires GitHub Code Security + `FULL_SECURITY_SCAN=true` | [copier] |
| `snyk-scheduled.yml` | only when `snyk_scan_schedule` is `weekly` or `daily`; schedule/manual advisory SAST + SCA, no PR/push trigger or required check | [copier] |
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
(secret), `CI_APP_CLIENT_ID` (variable) + `CI_APP_PRIVATE_KEY` (secret).
`FULL_SECURITY_SCAN=true` is optional and only means a private/internal owner has
enabled paid GitHub Code Security. `SNYK_TOKEN` remains local when
`snyk_scan_schedule=off`; it becomes an Actions secret only when the optional
scheduled workflow is generated (or a paid Snyk CI posture is deliberately
adopted).

### 1.8 Security

The repository-class policy is:

| Repository class | Standard |
|---|---|
| Public, CodeQL-supported | CodeQL + Dependabot alerts/Renovate + gitleaks; no Snyk by default |
| Selected important public | Optionally add Snyk Free as a scheduled SAST/SCA second opinion |
| Private | Semgrep CE is the dependable free CI SAST baseline; keep Snyk Free manual/local by default because Organization-wide quotas can stop scans mid-month |
| Important private | Consider paid GitHub Code Security/private CodeQL and/or paid Snyk, then decide whether per-PR scans should be merge-gating |
| Qualifying public OSS | Consider Snyk's [unlimited open-source program](https://snyk.io/open-source/) |

- **gitleaks** — `.gitleaks.toml` (`[extend] useDefault = true` + an
  `[allowlist] paths` of build/cache dirs). Runs at pre-push (`task
  security:secrets`) and in the `build.yml` `security` job (with the
  `summarize-gitleaks.mjs` GH step summary). **[copier]**
- **Semgrep CE** — `task security:sast` via `scripts/run-semgrep.sh`; part of the
  free local `task security` baseline. `build.yml` uses it for free private
  repositories and profiles without generated CodeQL. **[copier]**
- **Dependabot alerts + package audit** — Dependabot supplies continuous advisory
  monitoring for public and private repositories; `task security:audit` /
  `security:sca` runs the package-manager audit. **[manual]** to enable alerts;
  **[copier]** for tasks.
- **CodeQL** — `codeql.yml` is generated only when `use_codeql=true`, with the
  exact persisted `codeql_languages` matrix. It runs automatically on public
  repositories; private/internal repositories run it only with
  GitHub Code Security + `FULL_SECURITY_SCAN=true`, otherwise `build.yml` uses
  Semgrep CE. An unset/empty `FULL_SECURITY_SCAN` normalizes to the free-private
  route. The analyze job/action never uses `continue-on-error`; its stable
  aggregate requires success for public/paid-private analysis and reports a
  successful not-applicable result only for free-private or untrusted-fork
  routes. The fork path does not check out or execute fork-controlled repository
  code on the aggregate runner. `use_node` and `use_python` describe tooling;
  neither proves that its corresponding source language exists, so reconcile the
  persisted matrix with real first-party source. **[copier]**; **[manual]** only
  for the paid private opt-in.
- **Snyk** — optional `security:sast:snyk` (`snyk code test`) +
  `security:sca:snyk` (`snyk test --all-projects`) second opinions. The default
  `snyk_scan_schedule=off` keeps `SNYK_TOKEN` local and Snyk outside required PR
  CI. `weekly`/`daily` generates an advisory schedule/manual-only matrix workflow;
  daily is intended for public or accepted unlimited OSS projects. Public repos
  must be classified with their public Git remote so private tests are not
  debited. Free private repos normally stay manual/local; weekly is a deliberate
  quota-budgeted exception. A daily Snyk Code schedule is about 30 tests/month
  before manual runs, and SCA can consume one test per detected manifest. No Snyk
  GitHub App is required. **[copier]** for tasks/workflow; **[manual]** for the
  token and posture decision.
- **Branch protection ruleset** — `.github/Branch Protection Ruleset - Protect
  Main.json`: blocks deletion/non-ff/creation, requires linear history, PR with 1
  code-owner approval + thread resolution + last-push approval, required status
  checks `verify` + `security` (+ `codeql-verify` exactly when
  `use_codeql=true`), merge methods
  squash/rebase; org repos add a `merge_queue` rule. Scheduled Snyk and Snyk App
  checks are never required by default. **[copier]** ships the file; **[manual]**
  import via the GitHub UI (Settings → Rules → Rulesets → **Import a ruleset**) — not
  a blind `gh api … rulesets` `POST`, which is non-idempotent and can duplicate
  the ruleset. REST supports `merge_queue`; safe automation must discover
  exactly one matching ruleset and `PUT` its id. Edit the existing ruleset in
  the UI to change it later.
- **`SECURITY.md`** lives in **`.github/`** (Private Vulnerability Reporting).
  **[copier]**
- **Renovate, NOT Dependabot** for version updates. CHECKLIST explicitly says
  enable Dependabot *alerts* + Private vulnerability reporting but **do NOT add
  `dependabot.yml`** — Renovate owns updates. **[manual]** repo settings.
- **`CODEOWNERS`** = `* @<code_owner>` — an asked question that defaults to
  `author_git_provider_username` (a bare organization is not a valid CODEOWNERS
  principal; org repos can deliberately choose `org/team`). **[copier]**
  Existing owners are access control: an intentional replacement must be
  user-confirmed and acknowledged to `verify-applied.sh` as the exact
  `--ack-codeowner-change @old=@new` mapping. Old must exist on `main` and be
  dropped, new must be present, and extra/stale mappings fail.
- **Secrets via 1Password** locally (`op run`/`op inject`); CI reads Actions
  secrets. **`.env` is fully gitignored** (`.env`, `**/.env`, `.env.*`) with a
  single committed exception, `!/.env.example` (names/placeholders only; node
  repos ship a stub). **[copier]** gitignore; **[manual]** wiring.
- **Destination-only secret writes** — `task secret:set:1p VAULT=… ITEM=…
  FIELD=… [SECTION=…]` (existing 1Password fields) and `task secret:set:gh
  NAME=… REPO=owner/repo` (GitHub repo secrets), backed by
  `scripts/secret-set-{1p,gh}.sh`: the value is read from **stdin only** — never
  argv, `--body`, exported env vars, or Taskfile vars (history/process-listing
  hygiene). The 1Password helper fully materializes and validates the item JSON
  before `op item edit` can start; it requires one matching `CONCEALED` field
  and rejects `SSH_KEY`/`PASSKEY` categories, `SSHKEY` fields, and structured
  values because a full-item edit can clobber those credentials. Both helpers
  fail without destination metadata (`test-tasks.sh` asserts it), and agents
  still must not write to a password manager without explicit per-write
  confirmation. **[copier]**
- **`op` is a deliberate human-only toolchain exception.** Root `Brewfile` /
  `task install` does not provision 1Password CLI: install and authenticate it
  explicitly on a human host, or use the human DEV devcontainer profile that
  supplies the feature. The BOT profile must continue to omit every credential-
  store path; never satisfy parity by adding `op` there.
- **1Password credential naming (source of truth).** Authoritative convention is
  in the generated repo's `docs/architecture/security.md` ("1Password
  conventions"); when creating a repo's credentials, follow it verbatim:
  - **One vault per org** (the `<org>` vault) — nothing in personal/shared vaults.
  - **API credentials** use 1Password's **API Credential** type, named
    `<Provider> <scope-descriptor>` — e.g. `Cloudflare <slug>-terraform`,
    `Cloudflare R2 <slug>-tfstate` (Terraform state backend), and **`Cloudflare
    <slug>-github-actions`** for a per-site Workers-deploy token
    (`CLOUDFLARE_API_TOKEN`). One token per site/purpose (least privilege), one
    1Password item per credential.
  - **Account-level identifiers** get their own per-account item — e.g. `Cloudflare
    <org>` holding `Account ID` (drives the `CLOUDFLARE_ACCOUNT_ID` Actions var).
  - **Field labels match the provider's docs verbatim** (`Account ID`, `API Token`,
    `Access Key ID`, `Secret Access Key`, `Default Endpoint`) — don't invent
    generic labels (`key`, `secret`) or re-case them; references must match exactly.
  **[manual]** — a human creates credentials; the agent never fabricates them.

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
- **`.claude/skills/`** — vendored shared agent skills from harmon-devkit via
  **skills-sync**, gated on the **`use_skills_sync`** copier answer. v3.26.1
  defaulted it on universally; current template source defaults it on only for
  `web-astro` and `web-app`. The profile-seeded `universal` and `infra`
  categories are currently empty, so new general/iac repos default off instead
  of managing an empty set; repos updated through v3.26.1 may already record
  `true` and need an explicit review. When enabled, `skill_categories` starts with
  `universal`, adds `frontend` for both web types, `backend` for `web-app`,
  and `infra` when Terraform/Ansible or the iac type applies. The generated
  machinery is `.skills-sync.yaml`, `scripts/sync-skills.sh`, the
  `sync:skills`/`verify:skills`/`verify:skills:offline` tasks, a CI drift check
  (in the `lint` job) and a pre-push offline check. The drift checks skip cleanly
  until the first `task sync:skills`, so a fresh scaffold stays green. **[copier]**
  ships the machinery + an empty `.claude/skills/` (`.gitkeep`); pinning the
  manifest `ref` to a harmon-devkit release and running `task sync:skills` is
  **[manual]**. harmon-devkit is public, so no token is needed. The dest is
  **shared**: the sync manages only the dirs on the provenance `# managed:`
  line — any other `.claude/skills/<name>` is a **local skill** the repo owns
  (coexists freely; never drift, never touched by sync/verify; a name collision
  with an incoming vendored skill fails the sync loudly before any deletion).
  Pin bumps are the manual pair "bump `ref` → `task sync:skills` → commit"
  (Renovate can't do the re-sync half). Source-repo exception: **harmon-devkit
  itself sets `use_skills_sync: false`** — it IS the source of the skills;
  self-vendoring a pinned copy of its own `ai/skills/` would be circular.
  The harmon-devkit **v0.6 series** introduced this managed-set behavior and
  upgrades a legacy provenance stamp on the first sync; v0.6.2 also rejects an
  absolute or `..`-traversing destination before deletion. Repos on older pins
  need an engine update plus one deliberate re-sync, not merely a ref edit.
  **[copier]**
- **Foreman** — milestone/issue-driven agent dispatch, gated on the
  **`use_foreman`** Copier answer. When enabled it adds `.foreman.toml`,
  `taskfiles/foreman.yml`, `scripts/foreman/`, three `.claude/agents/`, the
  architecture doc, Taskfile targets, hooks, and Python tooling. The v3.26
  release introduced it default-on; current template source now deliberately
  defaults to `no`. Always pass an explicit per-repo answer on update because
  this is a substantial operational subsystem, not a passive lint config.
  Absence is deliberate when `use_foreman: false`. **[copier]**
- Devcontainer ships richer `config/claude-settings.json` as managed settings (see
  1.6). **[copier]**
- **`DESIGN.md`** — AI-facing statement of design intent (the *why*/prose rules);
  web types get a "Visual & UX direction" section. **[copier]** ships it with
  `TODO:` placeholders; **[manual]** to fill in.

### 1.11 Package / tool management

> **Local ↔ devcontainer parity (a hard goal).** Every binary that the repo's
> routine `Taskfile` gates, lefthook hooks, and `scripts/` invoke must be
> installable **locally via the `Brewfile`** — the repo's baseline tooling has
> to run on a bare host, not only inside the devcontainer. Explicit optional
> integrations are exempt: local `*:snyk` use requires a separately installed
> CLI, and the optional scheduled workflow installs its own pinned CLI. When the
> repo ships a devcontainer, the `Brewfile` (host) and the devcontainer
> `Dockerfile` (container) must cover the
> **same toolset** so `task <anything>` behaves identically in both. Concretely:
> if a task/script/hook calls a binary (e.g. `gum`, `tv`/television, `tokei`,
> `jq`, `gitleaks`, `shfmt`), that binary belongs in the `Brewfile` — and, if a
> devcontainer exists, also in the `Dockerfile`. Auditing this is a first-class
> check (see mode-audit drift class **I**).

- **`Brewfile`** — pins the core toolchain (go-task, lefthook, git, gh,
  shellcheck, shfmt, actionlint, yamllint, gitleaks, uv, node, jq, fzf, fd,
  ripgrep, bat, tokei, gum, television; conditionally pnpm/lychee, terraform,
  hadolint). Semgrep CE is pinned by `scripts/run-semgrep.sh` and executed through
  `uvx`, so the same version runs on a host and in CI. `gum` + `television` (the
  `tv` binary) power the universal
  `status`/`status:*` dashboard and the interactive `task` menu (`menu-tv`), so
  they are required for the dashboard and the bare-`task` menu to work on a host.
  `scripts/status.sh` resolves GNU `timeout` on Linux or Homebrew `gtimeout` on
  macOS, falling back to an unbounded command before dependencies are installed.
  Python is universal because hygiene parses TOML and the secret helpers use
  `python3`; it is not limited to projects that opt into the Python stack.
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

**Repo naming (`<base>-<suffix>`).** Name a repo by what it contains:
`-site` (websites / marketing / static sites — typically `web-astro`), `-app`
(web/product applications — `web-app`), `-infra` (IaC — `iac`), `-docs`
(documentation sites — `docs`), `-mobile` (mobile apps), `-hub`
(umbrella / landing repos). Use **`-site`, never the older `-web`**: "web" is
overloaded (every app is on the web) and collides with the natural name for a
web client, whereas `-site` lines up cleanly with the other suffixes. So
`sommerlawn-site` / `ponderous-site`, not `*-web`.

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

- **Taskfile:** `build` (`pnpm build`), `build:preview`, `dev`,
  `lint:typescript` (`astro check`; `typecheck` alias kept), `lint:prettier`,
  `lint:eslint`, `test` (vitest if config present),
  `test:e2e[:screenshot|:pdf]` (Playwright); `verify`/`ci` include `build`.
  `test:e2e` loads `.env.local` and runs **`scripts/e2e-env-guard.sh` first** —
  a fail-closed guard against production-capable credentials/targets in the e2e
  environment that **fails until configured** with the app's providers and prod
  domains ([manual] at scaffold time; omator's guard is the reference).
- **prettier.config.cjs**, eslint task. **lefthook** adds prettier/eslint/
  typecheck (pre-commit) + typecheck (pre-push).
- **`lighthouserc.json`** + a **`lighthouse`** CI job in `build.yml` (Chrome
  install, LHCI, PR comment). Asserts perf ≥0.7 (warn), a11y ≥0.85, BP ≥0.7, SEO
  ≥0.9.
- **`docs/architecture/design-language.md`** + DESIGN.md "Visual & UX direction".
- Devcontainer forwards port **4321** (Astro dev server); `astro-build.astro-vscode` extension.
- With first-party JS/TS source, `use_codeql=true`, and live Code Security
  capability, `codeql.yml` analyzes `javascript-typescript`; otherwise the
  workflow is intentionally absent and the SAST gap is documented. Do not count
  an ESLint/Prettier/Astro config file by itself as application source.
- **[manual] CHECKLIST:** `pnpm create astro@latest .`; add **Tailwind v4**
  (`@tailwindcss/vite`), **zod**, **vitest**, **lucide**; move lint tooling into
  `devDependencies` (the Taskfile auto-prefers repo-pinned `node_modules` bins
  over `npx --yes` once installed); review `lighthouserc.json` URLs; enable
  **mobile device projects** in `playwright.config.ts` (e.g. Pixel + iPhone —
  the scaffold ships them commented out, and mobile-first is the stated
  convention).

### 2.3 web-app (TanStack/React apps) — `use_node: true`

Same node tooling as web-astro **except**:

- `lint:typescript` uses `tsc --noEmit` (not `astro check`) — and when the root
  `tsconfig.json` is **solution-style** (`files: []` + `references`) it
  auto-detects that and runs **`tsc -b`** instead (a plain `--noEmit` against a
  solution file type-checks nothing and reports green). [copier]
- **Shipped `eslint.config.js` is ESLint 10 with type-aware linting on by
  default**: `tseslint.configs.recommendedTypeChecked` + `projectService`
  (catches floating/misused promises against async backend APIs like Convex
  `ctx`); **no `eslint-plugin-react`** (not v10-ready; ESLint 10 tracks JSX
  natively) — react-hooks, `@tanstack/eslint-plugin-router`, and
  `@convex-dev/eslint-plugin` plugins; `eslint-config-prettier` last; typed
  rules disabled for plain `js/cjs/mjs` config files. Generated files are
  committed but never linted/formatted: `src/routeTree.gen.ts` +
  `convex/_generated/` sit in the ESLint `ignores` and `.prettierignore`.
  Under `projectService` **every linted TS file must belong to a tsconfig
  project** — `convex/` carries its own runtime-accurate `convex/tsconfig.json`
  (`"types": []`, excludes `./_generated`). [copier]
- `pnpm-workspace.yaml`: `sharp: false` (web-astro keeps `true` for Astro's
  image pipeline); `workerd: true` only when deploying to Cloudflare Workers.
  pnpm 11's default `minimumReleaseAge` (1 day) is documented in the file —
  version-pinned `minimumReleaseAgeExclude` entries unblock a freshly published
  pin and age into no-ops. [copier]
- `prettier.config.cjs` ships `tailwindStylesheet` **commented** (Tailwind v4
  has no config file for the plugin to discover; the plugin hard-fails on a
  missing path) — uncomment once the app's main stylesheet exists. [copier] +
  [manual] activation.
- **No** Lighthouse job / `lighthouserc.json` (that's web-astro only). [copier]
- DESIGN.md / design-language reference **shadcn/ui** as the component set. [copier]
- **[manual] CHECKLIST:** `pnpm create @tanstack/start@latest` (TanStack Start)
  or vite + react; add **Tailwind v4**, **shadcn/ui**, **zod**, **vitest**,
  **lucide**; move lint tooling to `devDependencies` (Taskfile auto-prefers the
  pinned bins); install the ESLint 10 plugin set; configure
  `scripts/e2e-env-guard.sh` before the first e2e run; document env vars in
  `.env.example`; split `vitest.config.ts` into **projects** when the backend
  needs a different runtime (e.g. `react`/jsdom + `convex`/edge-runtime with
  `convex-test`).

### 2.4 iac (Terraform/Ansible) — `use_python: true`

Adds (all [copier]):

- **`include_terraform`** → `terraform/` skeleton (`main.tf`, `variables.tf`,
  `outputs.tf`, `tfvars.env.example`). `lint:terraform`, reached transitively by
  `check`, aggregates `lint:terraform:fmt` (`terraform fmt -check -recursive`),
  `lint:terraform:tflint`, `lint:terraform:security` (Renovate-pinned Checkov via
  `uvx --from "checkov==…"`), and `lint:terraform:locks`.
  `lint:terraform:validate` remains the separate validation path. The root
  `Brewfile` supplies Terraform, TFLint, and uv locally; the build workflow
  provisions Terraform, pinned TFLint, and uv before invoking the shared task
  gate. A docs claim or a defined-but-unreachable leaf task is not lint coverage.
  Lefthook runs the lint aggregate pre-commit and validate pre-push; the
  devcontainer includes Terraform; Renovate groups Terraform providers; VS Code
  includes hashicorp/terraform.
- **Terraform CI invariants:** commit `.terraform.lock.hcl` after the explicit
  first provider-bearing initialization. `task terraform:providers:lock` calls
  `scripts/terraform-provider-locks.sh update terraform`; the lint aggregate calls
  the same helper in `check` mode. The helper generates and compares checksums for
  exactly `darwin_arm64` (developer) and `linux_amd64` (GitHub CI) in a scratch
  copy, leaving the checkout untouched in check mode. Scratch initialization
  passes `-upgrade` only in update mode, so an intentional provider constraint
  bump can move beyond the selection in the committed lock; check mode must omit
  `-upgrade`. A fresh scaffold with no provider requirements cleanly skips lock
  creation. The hermetic
  `scripts/test-terraform-provider-locks.sh` regression must remain reachable
  through the task tests. A lock file's mere presence does **not** prove platform
  coverage; require this authoritative update/check process.

  Once a lock is tracked, CI uses
  `terraform init -lockfile=readonly`; only an explicit fresh-scaffold/local
  initialization may create the initial lock, and an intentional local provider
  update may refresh it; ordinary CI must not. The workflow listens to `push`,
  `pull_request`, `merge_group`, and `workflow_dispatch` with no top-level
  `paths` filter. Its internal change detector makes unrelated paths a no-op,
  while the required GitHub-hosted `terraform-verify` aggregate runs under
  `if: always()` and accepts `skipped` only when the explicit fork/change/enabled
  predicates prove that result deliberate.

  Credentialed plan/apply is downstream of successful validation and guarded by
  the change result, an explicit enable flag, same-repository trust, and a
  trusted-main push/dispatch apply condition. Repository/ref concurrency plus a
  repository/run/attempt artifact key namespaces each run. Save the binary plan
  under a private run-scoped directory, display that exact artifact, and apply
  it without re-planning; use bounded state-lock waits (`-lock-timeout`), never
  `-lock=false`, and clean up under `if: always()`. Agents never run
  `terraform apply`, `destroy`, `import`, or state-mutating commands without
  explicit approval for that exact operation. The reviewed trusted-main CI apply
  of its own saved plan is the defined automation exception.
- **`include_ansible`** → `ansible/` skeleton (`ansible.cfg`, `requirements.yaml`,
  `inventory/ playbooks/ roles/` each `.gitkeep`); **`.ansible-lint`**; tasks
  `lint:ansible`, `validate:ansible:syntax` (both guard on `ansible/site.yml`
  existing); lefthook ansible-syntax (pre-push); `ANSIBLE_CONFIG` remoteEnv;
  Renovate ansible regex managers; redhat.ansible extension.
- **Python toolchain** active (uv, black, `.python-version`, pyproject).
- Do not infer Python CodeQL coverage from the iac type. An infrastructure repo
  may have no first-party `.py` files. Select `use_codeql` deliberately and
  reconcile `codeql_languages` with actual source (including another supported
  language such as `javascript-typescript` when present) plus live Code Security
  capability.
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
- **No `codeql.yml`** when `use_codeql=false`. When enabled, the workflow matrix
  is exactly the persisted `codeql_languages`; audit that selection against real
  first-party source rather than treating tooling flags as coverage. A
  private/internal repository should select CodeQL only when GitHub Code Security
  is enabled; otherwise it uses Semgrep CE and documents the deliberate omission.
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
  marketing sites — e.g. sommerlawn-site uses `@astrojs/alpinejs` + `alpinejs`).
- A real web repo's `package.json` (sommerlawn-site) legitimately carries many
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
  treat that as 3.2-class, not lag. (sommerlawn-site's old `-max` claude-workflow
  variants are gone; its extra `links-online.yml` is a legit addition.)
- **Older copier answer keys:** a pre-v3 `.copier-answers.yml` references
  now-renamed/removed questions (`github_collaboration_templates`,
  `run_task_bootstrap`, `project_url`).
- **Stale `requirements.txt`** alongside `pyproject.toml`/`uv.lock` — the current
  template is uv/pyproject-only. (Removed from harmon-infra 2026-07-03 once its
  last consumer, a legacy Snyk CI step, was dropped.)
- **Bare `typecheck` task** (no `lint:typescript`): repos rendered before the
  omator retro (harmon-init ≤ v3.23) predate the rename; the current template
  names it `lint:typescript` with a `typecheck` alias, so both invocations work
  after an update. Lefthook hook *names* legitimately stay `typecheck`.
- **1Password CLI feature in the BOT devcontainer profile:** pre-retro renders
  ship `ghcr.io/itsmechlark/features/1password` in both profiles; the current
  standard is **dev-profile only** (the bot container must hold no credential-
  store path, enforced by `devcontainer-assert.sh`). Unlike most 3.3 lag this
  one is security-relevant — recommend the update rather than just noting it.
- **Missing `secret:set:*` tasks / `scripts/secret-set-*.sh`, or a bare
  `npx --yes`-only `lint:markdown`/`format`:** pre-retro renders lack the
  destination-only secret helpers and the pinned-bin preference — `copier
  update` brings both in.

When auditing: distinguish "**legit conditional/stack difference**" (3.1, 3.2 —
leave alone) from "**template-version lag**" (3.3 — candidate for an update toward
the current convention, but not a correctness bug).
