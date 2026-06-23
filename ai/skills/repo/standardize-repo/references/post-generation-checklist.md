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

- [ ] **[scriptable via gh]** Import the branch ruleset that protects `main`
      (required reviews + the `verify`/`security` status checks). The JSON is
      generated into the repo's `.github/`:

  ```bash
  gh api "repos/<org>/<repo>/rulesets" --method POST \
    --input ".github/Branch Protection Ruleset - Protect Main.json"
  ```

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
      set `CI_APP_ID` (Actions **variable**) + `CI_APP_PRIVATE_KEY` (Actions
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

  - Generate a private key (`.pem`) and note the **App ID**.
  - **Install App** → on this org → **Only select repositories** (not "All").
  - Set the variable + secret. **Do this by hand and do not script org-scoped
    secret-setting** — the bulk `--repos` form *replaces* the secret's value and
    its repo allow-list, silently evicting other repos. For a **personal-account
    repo** the per-repo form is safe:

    ```bash
    # personal-account repo only; org-level should be set in the UI / non-destructively
    gh variable set CI_APP_ID --repo "<org>/<repo>" --body "<app-id>"
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

- [ ] **[scriptable via gh]** Create a **Project V2** so that, after linking, it
      is **project number 1** for the org, with a `Status` single-select field
      (`project-automation.yml` and the `claude-*` workflows drive it). Use the
      GraphQL API via `gh`:

  ```bash
  # 1. org node id
  ORG_ID=$(gh api graphql -f query='query($l:String!){organization(login:$l){id}}' \
    -f l="<org>" --jq '.data.organization.id')

  # 2. create the project (note its number in the response)
  gh api graphql -f query='mutation($o:ID!,$t:String!){createProjectV2(input:{ownerId:$o,title:$t}){projectV2{id number}}}' \
    -f o="$ORG_ID" -f t="<repo>"

  # 3. add the Status single-select field (capture PROJECT_ID from step 2)
  gh api graphql -f query='mutation($p:ID!){createProjectV2Field(input:{projectId:$p,dataType:SINGLE_SELECT,name:"Status",singleSelectOptions:[{name:"Shaping",color:GRAY,description:""},{name:"In Progress",color:BLUE,description:""},{name:"Validating",color:YELLOW,description:""},{name:"In Review",color:PURPLE,description:""},{name:"Done",color:GREEN,description:""}]}){projectV2Field{... on ProjectV2SingleSelectField{id}}}}' \
    -f p="<PROJECT_ID>"
  ```

  > Note: "number 1" assumes this is the org's first Project V2. If other
  > projects exist, the new project's number will differ — record the actual
  > number and reconcile it with whatever the automation workflow references.
  > TODO: confirm whether `project-automation.yml` hardcodes project number 1
  > or reads it from a variable.

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

- [ ] **[human-only]** For local `.env` needs, use **1Password** (`op inject` /
      `op run`, or the 1Password Developer Environments feature). Commit only
      `.env.example`-style files — never real secrets. (Requires an
      authenticated `op` session, so treat as human-driven.)

- [ ] **[human-only]** (devcontainer projects) Devcontainer secrets land in
      `.devcontainer/devcontainer.env` via `init-env.sh` (1Password locally, host
      env on Coder) — never committed.

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
