# Post-Generation Checklist — Harmon DevKit

Work through this after generating the repo from harmon-init. Delete items
that don't apply, then keep this file as a record of what was configured.

Run **`task status:setup`** at any point to audit setup completeness — GitHub
config, toolchain, devcontainer, and dev environment — against the items below
(✓ done · ✗ missing · ? unknown · – n/a).

## 1. Local setup

- [ ] `task install` — Brewfile deps, and lefthook git hooks
- [ ] `task verify` passes locally
- [ ] Verify `harmon-devkit.code-workspace` opens the repo's folder in VS Code and has a unique VS Code Workspace color. Then add any other related repos (e.g. other org repos) to the `folders` list in the workspace file so you have quick access to those repos
- [ ] Extend `.gitignore` for your stack — the template ships a base; add stack-specific entries via [gitignore.io](https://www.toptal.com/developers/gitignore)
- [ ] macOS: add a Raycast quicklink/alias that opens the `harmon-devkit.code-workspace`
- [ ] macOS (Bunch): scaffold the launcher with `task util:bunch-add` (if not generated at copier time), then `task util:bunch-install` to move it to iCloud and leave a `.meta/*.bunch` symlink (re-run install if missing)

## 2. GitHub repo settings

- [ ] **Automated settings** — run `task setup:github` (idempotent, safe to
      re-run): enables **Dependabot alerts** and **private vulnerability
      reporting** when public. Do not add `dependabot.yml`: Renovate owns routine
      and vulnerability-remediation PRs; Dependabot owns advisory alerts.
- [ ] **Bot PAT** — the agent's `GH_TOKEN`. If a fine-grained PAT already covers
`evanharmon1`,
      just add this repo to its **selected repositories**; a token is scoped to one
      resource owner, so a **new owner needs a new PAT**. Both layers are required —
      the collaborator grant above sets the ceiling, the PAT's repo list reaches it.
      Procedure: [guides/bot-account.md](guides/bot-account.md).
- [ ] Import the branch ruleset (see [architecture/branch-protection.md](architecture/branch-protection.md)) — do this once `build.yml` is on `main` so the required `verify`/`security` checks resolve. **Use the UI import:** Settings → Rules → Rulesets → **New ruleset ▸ Import a ruleset** → select `.github/Branch Protection Ruleset - Protect Main.json`. (Prefer the UI over `gh api … rulesets`: the API `POST` is not idempotent — re-running creates a duplicate ruleset — and currently rejects the `merge_queue` rule. To later change the ruleset, edit the existing one in the UI rather than re-importing.)

- [ ] **Install and activate Renovate** — install the
      [Renovate app](https://github.com/apps/renovate) for **Only select
      repositories** and select this repo. In the Mend Developer Portal choose
      the **Renovate** product and **Scan and Alert** mode. Do not choose **Scan
      Only**: it puts Renovate in silent mode, which scans without creating
      checks, issues (including the Dependency Dashboard), or update/remediation
      PRs. This repo already has `renovate.json`; keep that configuration rather
      than replacing it with a generic onboarding config.
- [ ] **[human-only] Remove CodeRabbit access** — remove this repository from
      the CodeRabbit GitHub App installation and confirm the App no longer has
      access. Deleting `.coderabbit.yaml` and bot trust does not revoke an
      existing installation.
- [ ] Actions secret: `CLAUDE_CODE_OAUTH_TOKEN` (claude-* workflows) — generate
      with `claude setup-token`; the value must start **`sk-ant-oat01-`** (an OAuth
      token, billed to your Claude subscription), **not** `sk-ant-api03-` (a raw API
      key, billed at pay-as-you-go API rates). Then `gh secret set CLAUDE_CODE_OAUTH_TOKEN`
- [ ] **SAST coverage** — this profile has no CodeQL workflow, so Semgrep CE runs
      in `build.yml` for public and private repositories. Add CodeQL later if the
      repo gains supported first-party source: set `use_codeql=true`, select its
      `codeql_languages`, and ensure it is public (free) or has paid GitHub Code
      Security (private/internal).
- [ ] **Choose the Snyk posture** — the default is manual/local only via
      `task security:sast:snyk` and `task security:sca:snyk`; it is not part of
      `task security` or required PR CI. Free private-repository tests share the
      Snyk Organization's monthly quota, including local CLI tests. Leave the
      Snyk GitHub App off unless deliberately adopting its PR integration; its
      checks are not required by the default branch ruleset.
- [ ] **Optional scheduled Snyk** — leave this off for ordinary and free private
      repos. For a selected important public repo, re-render with
      `snyk_scan_schedule=weekly` (conservative) or `daily` (public or accepted
      unlimited OSS), set the generated workflow's `SNYK_TOKEN` Actions secret,
      and verify one manual run. Confirm Snyk classifies the public Git remote
      correctly. The workflow is advisory and never a required PR check.
- [ ] **Create** the CI GitHub App `evanharmon1-ci` by hand (one App per org;
      **Settings → Developer settings → GitHub Apps**), or reuse the org's existing one.
- [ ] **Install** the App on this repo — **Install App → Only select repositories**
      (the harmon-init repos that run release-please / claude-* / project-automation),
      **not "All"**. **Creating the App is not enough:** an App whose credentials are
      set but which is *not installed* on the repo makes
      `actions/create-github-app-token` fail at runtime with a **404**
      (`Not Found` — "not installed on this repository"). This is the single
      easiest step to miss.
- [ ] Set `CI_APP_CLIENT_ID` (Actions **variable**) + `CI_APP_PRIVATE_KEY` (Actions
      **secret**) — **pipe the `.pem` in** (never paste it; flattened newlines break
      the key), and **scope both to those same repos** (least privilege — the key can
      act as the App: commits, PRs, releases, workflow edits):

      ```bash
      gh secret set CI_APP_PRIVATE_KEY --org evanharmon1 \
        --visibility selected --repos <repo-a>,<repo-b> < evanharmon1-ci.private-key.pem
      gh variable set CI_APP_CLIENT_ID --org evanharmon1 \
        --visibility selected --repos <repo-a>,<repo-b> --body "<client-id>"  # Iv…-style, not the numeric App ID
      ```

      Personal account: use `--repo evanharmon1/harmon-devkit` instead of
      `--org`/`--visibility`/`--repos`. Re-running `--repos` **replaces** the list —
      re-run with the full list to add a repo. Drives release-please, the claude-*
      workflows, and project-automation; blast-radius + rotation in
      docs/architecture/security.md.
- [ ] GHCR: ensure the org/user allows publishing packages; the first
      devcontainer prebuild populates `ghcr.io/evanharmon1/harmon-devkit-devcontainer` on merge to main

## 3. Framework scaffolding (conventions-only template)

- [ ] Add the project's primary toolchain; extend Taskfile `build`/`test` accordingly

## 4. Secrets & environment

- [ ] For local `.env` needs, use **1Password Environments** (mounts a virtual
      `.env`; secrets never hit disk or git) or `op run`/`op inject`. Commit only
      `.env.example`-style files
- [ ] Devcontainer secrets: create a **1Password environment** that mounts
      `.devcontainer/devcontainer.env` (and `.devcontainer/dev/devcontainer.env`)
      with `GH_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN`, `AGENT_DECK_TELEGRAM_KEY`
      (+ `TS_AUTHKEY` for the dev profile). `init-env.sh` enforces the per-profile
      allow-list; on Coder the values come from workspace parameters. See
      [guides/devcontainers.md](guides/devcontainers.md)

## 5. Docs & meta

- [ ] Fill in the `TODO:` markers in README.md and docs/ (architecture diagram first)
- [ ] Confirm README badges render (Actions URLs are correct once CI runs)
- [ ] Initial release when ready: `task release:init` (v0.1.0) — releases stay manual
- [ ] Stay current with harmon-init: periodically run `copier update --trust` to pull
      template improvements (a three-way merge — your own edits are preserved). The
      standardize-repo skill (`update` mode) automates this and verifies the result.
