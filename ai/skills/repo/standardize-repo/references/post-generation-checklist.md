# Post-Generation Checklist

Steps to run **after** `copier copy` finishes and the generated files are
committed to the repo. Generalized from harmon-init's own
`template/docs/CHECKLIST.md.jinja`; see also `docs/architecture/security.md` for
the GitHub App rationale.

Every step is tagged **[scriptable via gh]** (an agent can run it
non-interactively) or **[human-only]** (requires a browser/UI, a one-time secret
the agent must not fabricate, or a deliberate manual action per the security
model). For scriptable steps the exact `gh` command is given.

Throughout, substitute the copier answers:

- `<org>` — the `github_org` answer (defaults to the author's username; an
  **org** repo is one where `github_org != author_git_provider_username`).
- `<repo>` — the `project_slug` answer.
- `<project_type>` — one of `general`, `web-astro`, `web-app`, `iac`, `docs`.

Run from the generated repo's root, on the default branch, after the first
push so the remote exists.

---

## 1. Local setup

- [ ] **[scriptable via gh]** Install deps + git hooks. Installs Brewfile deps
      and, depending on copier answers, `uv sync` (Python) / `pnpm install`
      (Node) plus lefthook hooks.

  ```bash
  task install
  ```

- [ ] **[scriptable via gh]** Confirm the full local gate passes before relying
      on CI.

  ```bash
  task verify
  ```

---

## 2. GitHub repo settings

- [ ] **[manual — GitHub UI]** Import the branch ruleset that protects `main`
      (required reviews + the `verify`/`security` status checks). The JSON is
      generated into the repo's `.github/`. Import it via the UI:
      **Settings → Rules → Rulesets → New ruleset ▸ Import a ruleset** → select
      `.github/Branch Protection Ruleset - Protect Main.json`. To change an
      existing ruleset, edit it in the UI — don't re-import.

  > Avoid `gh api … rulesets`: `POST` is **not idempotent** (re-running creates a
  > duplicate ruleset) and both `POST`/`PUT` currently reject the `merge_queue`
  > rule (`422 Invalid rule 'merge_queue'`). The UI import handles every rule type.

- [ ] **[scriptable via gh]** Enable **Dependabot alerts**. Do NOT add a
      `dependabot.yml` — Renovate owns version updates; Dependabot is alerts-only.

  ```bash
  gh api "repos/<org>/<repo>/vulnerability-alerts" --method PUT
  ```

- [ ] **[scriptable via gh]** Enable **private vulnerability reporting**.

  ```bash
  gh api "repos/<org>/<repo>/private-vulnerability-reporting" --method PUT
  ```

- [ ] **[human-only]** Install the **Renovate** GitHub App on the repo —
      <https://github.com/apps/renovate> (the generated `renovate.json` is
      pre-configured). App installation goes through GitHub's UI consent flow.

- [ ] **[human-only]** Install the **CodeRabbit** GitHub App on the repo —
      <https://github.com/apps/coderabbitai> (the generated `.coderabbit.yaml` is
      pre-configured). UI consent flow.

- [ ] **[human-only]** Set Actions **secret** `CLAUDE_CODE_OAUTH_TOKEN`
      (consumed by `claude-plan.yml`, `claude-implement.yml`,
      `claude-review.yml`). This is a real credential the agent must not invent;
      a human pastes the token. Once you have it:

  ```bash
  # human supplies the token value; do not fabricate it
  gh secret set CLAUDE_CODE_OAUTH_TOKEN --repo "<org>/<repo>"
  ```

- [ ] **[human-only]** Set Actions **secret** `SNYK_TOKEN` (consumed by
      `task security:sast` / `task security:sca`). Real credential — human
      supplies it:

  ```bash
  gh secret set SNYK_TOKEN --repo "<org>/<repo>"
  ```

- [ ] **[human-only]** Create or reuse the CI **GitHub App** `<org>-ci`, then
      set `CI_APP_CLIENT_ID` (Actions **variable**) + `CI_APP_PRIVATE_KEY` (Actions
      **secret**). This App authenticates `release.yml` (release-please) and the
      `claude-*` workflows; minting an App-authored commit is what lets a release
      PR's required checks actually run (the built-in `GITHUB_TOKEN` would not
      retrigger CI).

  **One App per org** (or per personal account) — `<org>-ci`, e.g.
  `evanharmon1-ci` — so a leaked key is contained to one org. The App must be
  created in the GitHub UI: the app-manifest "one-click" flow can't be completed
  by a static page (the one-time `?code=` expires), so this is human-only. The
  exact permission set is checked into the generated repo as
  `.github/github-app-manifest.json`; mirror it in the form.

  - New GitHub App: org → `https://github.com/organizations/<org>/settings/apps/new`;
    personal → `https://github.com/settings/apps/new`.
  - Name `<org>-ci`; uncheck the **Active** webhook; **"Only on this account"**;
    grant exactly these permissions and nothing more:

    | Permission | Level | Why |
    |---|---|---|
    | Contents | Read and write | commits, branches, tags, releases |
    | Pull requests | Read and write | open/update the release PR and claude PRs |
    | Issues | Read and write | claude comments/labels/updates issues |
    | Workflows | Read and write | claude may edit files under `.github/workflows/` |
    | Metadata | Read-only | required baseline |

  - Generate a private key (`.pem`) and copy the **Client ID** (the Iv-style string on the App's settings page, not the numeric App ID).
  - **Install App** → on this org → **Only select repositories** (not "All").
  - Set the variable + secret. **Do this by hand and do not script org-scoped
    secret-setting** — the bulk `--repos` form *replaces* the secret's value and
    its repo allow-list, silently evicting other repos. For a **personal-account
    repo** the per-repo form is safe:

    ```bash
    # personal-account repo only; org-level should be set in the UI / non-destructively
    gh variable set CI_APP_CLIENT_ID --repo "<org>/<repo>" --body "<client-id>"
    gh secret set CI_APP_PRIVATE_KEY --repo "<org>/<repo>" < path/to/app.pem
    ```

  See `docs/architecture/security.md` for blast-radius and rotation notes.

- [ ] **[scriptable via gh]** Enable **CodeQL** by setting the Actions variable
      `FULL_SECURITY_SCAN=true` (the generated `codeql.yml` is gated
      `if: vars.FULL_SECURITY_SCAN == 'true'`; only present when the project uses
      Node and/or Python):

  ```bash
  gh variable set FULL_SECURITY_SCAN --repo "<org>/<repo>" --body "true"
  ```

- [ ] **[human-only]** (devcontainer projects) Ensure the org/user **allows
      GHCR package publishing** so the first `devcontainer-build.yml` prebuild on
      merge to main can populate `ghcr.io/<org>/<repo>-devcontainer`. The
      workflow already requests `packages: write` and logs in with
      `GITHUB_TOKEN`; org package-creation policy is a UI setting.

### Org repos only (`github_org != author_git_provider_username`)

- [ ] **[scriptable via gh]** Create/sync the org **Project V2**. The generated
      repo ships an idempotent task; run it (needs the `project` scope —
      `gh auth refresh -s project`):

  ```bash
  task setup:github-project
  ```

  > It looks the project up by title, so it is safe to re-run and safe to run
  > from any org repo (the first run creates it, later runs only reconcile). It
  > seeds the full `Status` pipeline plus the Priority/Estimate/Product/Agent
  > fields and never deletes existing options or fields.
  > `project-automation.yml` and the `claude-*` workflows drive `Status`.
  >
  > It must be the org's **project number 1** — those workflows query
  > `projectV2(number: 1)`, and the task warns if it isn't. For the exact
  > GraphQL (or to run it by hand), see `scripts/setup-github-project.sh`.

- [ ] **[scriptable via gh]** Add the bot machine account
      (`<author_git_provider_username>-bot`) as a **Write** collaborator (it does
      the in-container git pushes; it cannot merge `main`):

  ```bash
  gh api "repos/<org>/<repo>/collaborators/<author_git_provider_username>-bot" \
    --method PUT -f permission=push
  ```

---

## 3. Framework scaffolding (conventions-only template)

The template ships conventions, not an application. Scaffold the framework that
matches `<project_type>`:

- [ ] **[scriptable via gh]** (`web-astro`) Scaffold Astro and add the standard
      stack:

  ```bash
  pnpm create astro@latest . --template minimal
  pnpm add -D @tailwindcss/vite vitest
  pnpm add zod lucide
  ```

  Then move lint tooling (prettier, eslint, markdownlint-cli2, @commitlint/cli)
  into `devDependencies` and switch the generated `Taskfile.yml`'s `npx --yes`
  calls to `pnpm exec`. Review `lighthouserc.json` URLs once routes exist.

- [ ] **[scriptable via gh]** (`web-app`) Scaffold a TanStack Start app (or
      vite + react) and add the standard stack:

  ```bash
  pnpm create @tanstack/start@latest   # or: pnpm create vite@latest . -- --template react-ts
  pnpm add -D vitest
  pnpm add zod lucide
  # shadcn/ui + Tailwind v4 per their installers, e.g.:
  pnpm dlx shadcn@latest init
  ```

  Move lint tooling into `devDependencies` and switch Taskfile `npx --yes` calls
  to `pnpm exec`.

- [ ] **[scriptable via gh]** (`iac`) Lay out the IaC tree. Lint tasks for
      Ansible activate automatically once `ansible/site.yml` exists:

  ```bash
  mkdir -p terraform ansible/inventory ansible/roles
  : > terraform/main.tf
  : > terraform/variables.tf
  : > terraform/outputs.tf
  : > ansible/site.yml
  : > ansible/ansible.cfg
  ```

- [ ] **[human-only]** (`docs`) Decide the docs toolchain (plain markdown /
      Obsidian vault / static-site generator) — a judgment call, not scripted.

- [ ] **[scriptable via gh]** (`general` / anything else) Add the project's
      primary toolchain and extend the Taskfile `build`/`test` targets
      accordingly.

---

## 4. Secrets & environment

- [ ] **[human-only]** For local `.env` needs, use **1Password Environments**
      (mounts a virtual `.env` over a UNIX pipe — values never hit disk or git)
      or `op run` / `op inject`. Commit only `.env.example`-style files.

- [ ] **[human-only]** (devcontainer projects) Devcontainer secrets: create a
      **1Password environment** with destination "Local .env file" mounted at
      `.devcontainer/devcontainer.env` (and `.devcontainer/dev/devcontainer.env`),
      holding `GH_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN`, `AGENT_DECK_TELEGRAM_KEY`
      (+ `TS_AUTHKEY` for the dev profile; `ANTHROPIC_API_KEY` is forbidden).
      `init-env.sh` only enforces the per-profile allow-list and seeds from the
      **host env** (the Coder/Codespaces path) — it does **not** call `op`. Full
      walkthrough in the generated repo's `docs/guides/devcontainers.md`.

- [ ] **[human-only]** (Coder) To run the devcontainer in Coder, create a
      workspace from the **org-level Coder devcontainer template** (not part of
      the repo — canonical example: `terraform/coder/devcontainer/` in
      harmonops/harmon-infra) with its `repo` parameter set to this repo and the
      secret parameters above (Coder passes them as host env → `init-env.sh`).
      The build pulls `<devcontainer_image>` from GHCR as a cache (private
      package ⇒ give the builder a read token; a miss only slows the first build).

---

## 5. Docs & meta

- [ ] **[human-only]** Fill in the `TODO:` markers in `README.md` and `docs/`
      (architecture diagram first) — authoring, not scripting.

- [ ] **[scriptable via gh]** Confirm README badges render once CI has run
      (Actions URLs become valid after the first workflow run):

  ```bash
  gh run list --repo "<org>/<repo>" --limit 5
  ```

- [ ] **[human-only]** Cut the initial release when ready — releases stay
      **intentional**, never automated on merge:

  ```bash
  task release:init   # v0.1.0
  ```
