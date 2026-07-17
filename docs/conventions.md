# Conventions

How we do things in Harmon DevKit — the conventions a contributor (human or
AI) should follow. Most are **enforced** by git hooks (lefthook) and CI; the rest
is the residue a linter can't mechanize. A **flat lookup** — grep for the rule
you need rather than reading it through. `AGENTS.md` is the AI quick-reference;
it points here.

## Commits & git

- **Conventional Commits**, enforced by commitlint at the `commit-msg` hook.
  Allowed types: `build`, `chore`, `ci`, `docs`, `feat`, `fix`, `perf`,
  `refactor`, `revert`, `style`, `test`. Format
  `type(scope): subject`, imperative mood.
- **Subject and body lines ≤ 100 characters** (config-conventional).
- **Breaking changes:** `feat!:` (or a `BREAKING CHANGE:` footer) — drives a
  major bump.
- **Feature branches only.** Direct commits to `main` are blocked by the
  `guard:no-commit-to-main` pre-commit hook and the branch ruleset. Land changes
  via a PR; code-owner review and the `verify` + `security` checks are required.
- **Never bypass hooks** (`--no-verify` is forbidden) — fix the underlying issue.
  In the devcontainer a Claude Code hook actively blocks `--no-verify` and
  validates commit messages.
- Run **`task verify`** before pushing; the pre-push hook runs secret scanning
  (and type/IaC checks where applicable).

## Task runner (Taskfile)

- Tasks are named **`group:action`** — the group/domain comes first, the action
  is the leaf: `lint:shell`, `lint:typescript`, `test:e2e`, `security:secrets`,
  `install:hooks`, `status:git`. **Never action-first** (`typescript:lint`,
  `yaml:lint`).
- Pipeline order is **`check → build → validate → test → security`**, with
  `verify` (the definition-of-done gate — check + validate + test) and
  `ci` (full — verify + security) as the aggregates. `check` is the fast
  inner-loop/hook gate.
- **`lint:*` and `check` are read-only gates** — they report and fail, never
  modify files. All auto-fixing lives in **`task format`**, **`task format:file
  -- <path>`**, and **`task fix`** (= format then lint). Pre-commit hooks run the
  read-only `lint:*`, so a failing check **blocks the commit and tells you** to
  run `task format` rather than silently rewriting your tree.
- Formatters (e.g. Prettier, Black, shfmt, `terraform fmt`, markdownlint) expose
  a check side in `lint:*` and a write side in `format`; pure analyzers (e.g.
  shellcheck, actionlint, yamllint, ESLint) are check-only by design.
- **Workflows delegate to `task` targets** so local hooks, CI, and humans run
  identical commands — the Taskfile is the single source of truth. Don't
  reimplement command logic in a workflow or a hook.

## Code style

- Indentation: **2 spaces** by default; **4 spaces** for Python, Terraform, and
  Shell (`.editorconfig`). Final newline; trim trailing whitespace (except
  Markdown/MDX).

## TODOs

- Mark unfinished work with `TODO: <description>` — the literal `TODO:` prefix, in
  code and docs alike, so it stays greppable (`rg 'TODO:'`).

## YAML, Markdown & shell

- **YAML:** 2-space indent, linted by yamllint. Use whichever extension
  (`.yml` or `.yaml`) each tool conventionally uses (e.g. `Taskfile.yml`,
  `.coderabbit.yaml`) — don't normalize extensions repo-wide.
- **Markdown:** markdownlint — ATX headings, no duplicate headings, emphasis and
  strong markers consistent within a file; line-length and first-line-heading
  rules are off.
- **Shell:** must pass `shellcheck --severity=error` and `shfmt -d`, and stay
  portable to macOS bash 3.2 (no `mapfile`, no `grep -P`).

## CI / GitHub Actions

- **Pin third-party actions by full commit SHA** with a trailing `# vX.Y.Z`
  comment, and annotate tool versions with `# renovate: datasource=…` so
  Renovate keeps them current.
- Third-party CI/SaaS integrations that require an account, app installation,
  trial, or payment must be explicit opt-ins that default off. Document free-tier
  and private-repository limitations before adding them to generated output.
- **Least-privilege `permissions:`** per job; never log secrets.
- CI authenticates as the **`evanharmon1-ci` GitHub App** (short-lived
  tokens), not a PAT — see [architecture/security.md](architecture/security.md).

## Secrets

- Local env comes from **1Password** (`op run` / `op inject`); CI reads GitHub
  Actions secrets. `gitleaks` runs on pre-push and in CI.
- When generating or rotating secrets, keep the value **on stdin** and use the
  destination-only helpers: `task secret:set:1p VAULT=… ITEM=… FIELD=…
  [SECTION=…]` for existing 1Password fields, `task secret:set:gh NAME=…
  REPO=owner/repo` for GitHub repo secrets. Never pass secret values as command
  arguments, `--body` values, exported env vars, or Taskfile vars — they end up
  in shell history and process listings.

## Docs & AI steering

- **`AGENTS.md` is the single source of truth** for AI guidance; `CLAUDE.md`,
  `GEMINI.md`, and `.github/copilot-instructions.md` are **symlinks** to it —
  edit only `AGENTS.md`.
- **Doc filenames are kebab-case** (`branch-protection.md`, `ci-cd.md`). The
  conventional uppercase project files keep their names: `README.md`,
  `AGENTS.md`, `DESIGN.md`, `CHANGELOG.md`, `CONTRIBUTING.md`,
  `CODE_OF_CONDUCT.md`, `LICENSE`, `CHECKLIST.md`.
- Documentation layering: `docs/product/` (why/where) · `specs/` (what to build)
  · `docs/architecture/` (how) · `docs/decisions/` (ADRs, numbered `0001-`) ·
  `docs/guides/` (build it) · `docs/runbooks/` (operate it). Folder landing
  pages are `README.md`.

## Releases

- Releases are intentional via **release-please**: merge the rolling release PR
  to cut the tag, GitHub release, and CHANGELOG entry. `task release:*` remains a
  manual override. Nothing auto-releases on a normal merge.
- **The commit type drives the release.** release-please reads the type to pick
  the CHANGELOG section and bump: `feat` → **Features** (minor), `fix` → **Bug
  Fixes** (patch), `feat!` / `BREAKING CHANGE:` → major. The rest (`build`,
  `chore`, `ci`, `docs`, `perf`, `refactor`, `revert`, `style`, `test`) don't cut
  a release on their own — they ride along in the next one.
