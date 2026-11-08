# Post-Generation Checklist — Harmon DevKit

<!--
AI AGENTS: This checklist is a human-maintained record for humans to check off.
Do not check, uncheck, rewrite, remove, reorder, normalize, reconcile, or
otherwise update its items based on repository state. Do not try to keep it
consistent with code, configuration, tags, releases, or external services.
Read-only inspection and reporting are allowed when requested, but never mutate
checklist state based on the findings. Only edit a checklist item when the human
user clearly and explicitly asks for that specific checklist update.
-->

Work through this after generating the repo from harmon-init. Delete items
that don't apply, then keep this file as a record of what was configured.

Run **`task status:setup`** at any point to audit setup completeness — local
credentials (gh, Codex), GitHub config, toolchain, devcontainer, and dev
environment — against the items below
(✓ done · ✗ missing · ? unknown · – n/a).

## 1. Local setup

- [ ] **[human-only]** Probe: Read installed tool versions and the configured git hooks, treating unavailable tools as missing. Write: `task install`. <!-- reconcile-id: template-task-install-brewfile-deps-if-use-py-001 --> `task install` — Brewfile deps, and lefthook git hooks
- [ ] **[human-only]** Probe: Read the exit status from the latest locally recorded verification execution, treating an absent record as unknown. Write: none. <!-- reconcile-id: template-task-verify-passes-locally-002 --> `task verify` passes locally
- [ ] **[human-only]** Probe: Read the workspace file and inspect its folder list and VS Code color. Write: none. <!-- reconcile-id: template-verify-project-slug-code-workspace-o-004 --> Verify `harmon-devkit.code-workspace` opens the repo's folder in VS Code and has a unique VS Code Workspace color. Then add any other related repos (e.g. other org repos) to the `folders` list in the workspace file so you have quick access to those repos
- [ ] **[human-only]** Probe: Read .gitignore and compare entries with the chosen project stack. Write: none. <!-- reconcile-id: template-extend-gitignore-for-your-stack-the-005 --> Extend `.gitignore` for your stack — the template ships a base; add stack-specific entries via [gitignore.io](https://www.toptal.com/developers/gitignore)
- [ ] **[human-only]** Probe: Inspect the Raycast quicklink list for the workspace target. Write: none. <!-- reconcile-id: template-macos-add-a-raycast-quicklink-alias-006 --> macOS: add a Raycast quicklink/alias that opens the `harmon-devkit.code-workspace`
- [ ] **[human-only]** Probe: Read the Bunch launcher and its installed symlink in the configured location. Write: `task util:bunch-add`. <!-- reconcile-id: template-macos-bunch-scaffold-the-launcher-wi-007 --> macOS (Bunch): scaffold the launcher with `task util:bunch-add` (if not generated at copier time), then `task util:bunch-install` to move it to iCloud and leave a `.meta/*.bunch` symlink (re-run install if missing)

## 2. GitHub repo settings

- [ ] **[human-only]** Probe: Read repository plan and draft pull request availability in GitHub settings. Write: none. <!-- reconcile-id: template-confirm-draft-pull-requests-are-avai-008 --> **Confirm draft pull requests are available on this repo** — every agent
      PR opens as a draft and is promoted only by the readiness gate (AGENTS.md,
      "Dev Loop"). GitHub restricts draft PRs on **private** repositories to its
      paid plans, so on a private free-plan repo `gh pr create --draft` fails
      outright and the whole lifecycle stops at its first step. Check the current
      plan matrix in [GitHub's draft-PR
      docs](https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/proposing-changes-to-your-work-with-pull-requests/changing-the-stage-of-a-pull-request);
      if drafts are unavailable, make the repo public, upgrade the plan, or
      decide deliberately not to run agent workflows here — do not "fix" it by
      dropping `--draft` and letting automations surprise human reviewers.
- [ ] **[agent-apply]** Probe: Read repository settings and Actions variables with the GitHub REST API and compare them with the configured desired values. Write: `task setup:github`. <!-- reconcile-id: template-automated-settings-run-task-setup-gi-009 --> **Automated settings** — run `task setup:github` (idempotent, safe to
      re-run): sets `delete_branch_on_merge: true`, `allow_update_branch: true`,
      and `allow_auto_merge: false`, verifies those settings, and enables **Dependabot alerts** and **private vulnerability
      reporting** when public. Routing uses `CI_RUNS_ON`, `BROWSER_RUNS_ON`,
      `IMAGE_BUILD_RUNS_ON`, `MULTICORE_RUNS_ON` and `ISOLATED_RUNS_ON`. Public
      repositories always create or replace all five repository overrides as
      `"ubuntu-latest"`, even without flags, so inherited persistent runners
      cannot reach jobs.
      On private/internal repositories, the script creates missing values only
      with `--ci-runs-on`, `--browser-runs-on`, `--multicore-runs-on`,
      `--image-build-runs-on` or `--isolated-runs-on`; intentional replacement
      also requires the matching `--replace-*` flag. `task setup:github`
      supplies the rendered CI answer; pass other class flags after `--`,
      for example `task setup:github -- --browser-runs-on '"ubuntu-latest"'`.
      Repository values shadow organization values. Isolated selectors may be
      strings, label arrays, or objects with usable `labels`; `self-hosted` is
      refused case-insensitively, and unsupported shapes fail closed. Requested
      invalid isolated values fail before any GitHub access or writes. Repair
      an existing unsafe repository value with a safe `--isolated-runs-on` plus
      `--replace-isolated-runs-on` (public repositories repair unsafe and
      unsupported values automatically before organization checks). Private/internal unsupported shapes fail
      closed. Unsafe or unsupported organization values fail only when inherited,
      with no repository isolated override. A safe repository value or an explicit
      safe isolated value plus replace flag shadows them and succeeds with a
      warning. Otherwise ask the organization's routing owner (whoever manages
      organization Actions variables) to repair them, or create a safe override.
      Unreadable organization values report unknown without failing setup; `task status:setup` reports known violations. Do not add
      `dependabot.yml`: Renovate owns routine and vulnerability-remediation PRs;
      Dependabot owns advisory alerts.
- [ ] **[human-only]** Probe: Read the live repository rulesets and required checks through the GitHub API. Write: none. <!-- reconcile-id: template-import-the-branch-ruleset-see-archit-010 --> Import the branch ruleset (see [architecture/branch-protection.md](architecture/branch-protection.md)) — do this once `build.yml`, `devcontainer-build.yml` are on `main` so the required `verify`/`security`/`devcontainer-verify` checks resolve. **Use the UI import:** Settings → Rules → Rulesets → **New ruleset ▸ Import a ruleset** → select `.github/Branch Protection Ruleset - Protect Main.json`. (Prefer the UI over `gh api … rulesets`: the API `POST` is not idempotent — re-running creates a duplicate ruleset — and currently rejects the `merge_queue` rule. Check the imported ruleset for rules GitHub omitted as unavailable. To later change the ruleset, edit the existing one in the UI rather than re-importing.) **Import it before provisioning the bot and agent PATs below:** those postures carry no local merge guard, so this ruleset's code-owner approval and required checks are the only thing between their PAT and an unreviewed merge into `main`.
- [ ] **[human-only]** Probe: Read the existing token coverage and the latest authenticated GitHub workflow result without exposing token values. Write: none. <!-- reconcile-id: template-bot-pat-the-agent-s-gh-token-if-a-fi-011 --> **Bot PAT** — the agent's `GH_TOKEN`. If a fine-grained PAT already covers
`evanharmon1`,
      just add this repo to its **selected repositories**; a token is scoped to one
      resource owner, so a **new owner needs a new PAT**. Both layers are required —
      the collaborator grant above sets the ceiling, the PAT's repo list reaches it.
      Procedure: [guides/bot-account.md](guides/bot-account.md).
- [ ] **[human-only]** Probe: Read the existing token coverage and the latest authenticated GitHub workflow result without exposing token values. Write: none. <!-- reconcile-id: template-agent-pat-only-if-this-repo-allows-u-012 --> **Agent PAT** — only if this repo allows unattended remote
      lanes (the agent devcontainer, `.devcontainer/agent/`). A **separate**
      fine-grained PAT on the bot account, same permissions as the bot's, expiry
      of 180 days at most, its own repository list, one per resource owner;
      supplied as `AGENT_GH_TOKEN`, never as `GH_TOKEN`. Procedure:
      [guides/devcontainers.md](guides/devcontainers.md) (agent posture).
- [ ] **[human-only]** Probe: Read required checks in the live branch ruleset through the GitHub API. Write: none. <!-- reconcile-id: template-add-closing-keywords-to-the-live-bra-014 --> **Add `closing-keywords` to the live branch ruleset** —
      **required, not optional, and no longer deferrable.** Until
      harmon-init#1328 the guard was enforced *transitively*: the job sat in
      `build.yml` and fed the aggregate `verify` check, so a failing guard
      failed a check the ruleset already required. Splitting it into
      `closing-keywords.yml` (so it can keep the `pull_request.edited` trigger
      the build matrix must not have) removes that path — `needs:` cannot cross
      workflows. A live ruleset that does not name `closing-keywords` therefore
      enforces nothing, and a `copier update` cannot fix that for you, because
      it does not mutate live rulesets. After every newly required job has
      reported once, preview with **`task setup:ruleset -- --dry-run`**, then
      run **`task setup:ruleset`** and confirm the additions. It updates the
      existing ruleset via `PUT`, preserving live conditions, bypass actors
      and other rules. It only adds missing contexts: extra live checks stay,
      and integration mismatches need a manual edit and exit non-zero even
      when additions were applied. Non-interactive writes require `--yes`.
      Do **not** re-import the JSON: that creates a duplicate ruleset.
      `task audit:ruleset` confirms the result and reports other policy drift.
      If the API rejects a rule (for example `merge_queue`), add the checks
      to the existing ruleset in Settings → Rules → Rulesets instead.
- [ ] **[human-only]** Probe: Read the live branch ruleset approval conditions through the GitHub API. Write: none. <!-- reconcile-id: template-enable-unattributed-changes-approval-015 --> **Enable unattributed-changes approval in the live branch
      ruleset** — after a `copier update` adds this parameter, edit the existing
      main-branch ruleset in Settings → Rules → Rulesets and enable the matching
      additional-approval setting. Do not re-import the JSON: GitHub creates a
      duplicate ruleset rather than updating the live one.

- [ ] **[human-only]** Probe: Read the repository app installation and the Renovate dashboard issue. Write: none. <!-- reconcile-id: template-install-and-activate-renovate-instal-016 --> **Install and activate Renovate** — install the
      [Renovate app](https://github.com/apps/renovate) for **Only select
      repositories** and select this repo. In the Mend Developer Portal choose
      the **Renovate** product and **Scan and Alert** mode. Do not choose **Scan
      Only**: it puts Renovate in silent mode, which scans without creating
      checks, issues (including the Dependency Dashboard), or update/remediation
      PRs. This repo already has `renovate.json`; keep that configuration rather
      than replacing it with a generic onboarding config.
- [ ] **[human-only]** Probe: Read the repository app installation and review settings in the GitHub and CodeRabbit interfaces. Write: none. <!-- reconcile-id: template-install-the-coderabbit-app-https-git-017 --> Install the [CodeRabbit app](https://github.com/apps/coderabbitai) on the repo
      (`.coderabbit.yaml` turns automatic reviews off; the dev loop requests them with
      `@coderabbitai review`). Confirm the organization's **Automatic Review**
      setting in the CodeRabbit UI is off as well: CodeRabbit falls back to it when
      the file is missing, and a setting left on reviews every push.
- [ ] **[human-only]** Probe: Read the repository app installation and review settings in the GitHub and Greptile interfaces. Write: none. <!-- reconcile-id: template-install-the-greptile-app-https-githu-019 --> Install the [Greptile app](https://github.com/apps/greptile-apps) on the repo
      (`.greptile/config.json` turns automatic reviews off; the dev loop requests them)
- [ ] **[human-only]** Probe: Read the Gemini Code Assist connection in Google Cloud and GitHub settings. Write: none. <!-- reconcile-id: template-connect-gemini-code-assist-on-github-020 --> **Connect Gemini Code Assist on GitHub** — in Google Cloud
      Console (under your foundation project), navigate to **Gemini Code Assist →
      Agents & Tools → Code Assist Source Code Management**, create/select the
      connection in `us-east1`, install the Gemini Code Assist GitHub App for
      this repository, and complete the Cloud-side repository link.
- [ ] **[human-only]** Probe: Read the repository connection and review preferences in Codex settings. Write: none. <!-- reconcile-id: template-connect-codex-cloud-review-connect-t-021 --> **Connect Codex cloud review** — connect this repository in
      ChatGPT Codex settings, grant private-repository access if applicable,
      and confirm review activity is authored by GitHub actor ID `199175422`
      (`chatgpt-codex-connector[bot]`, type `Bot`).
- [ ] **[human-only]** Probe: Read personal Auto review and repository review trigger preferences in Codex settings. Write: none. <!-- reconcile-id: template-disable-codex-automatic-reviews-turn-022 --> **Disable Codex Automatic reviews** — turn **personal Auto
      review** off and set this repository's **Auto code review** preference to
      **Follow personal** — and its review **Trigger** to Follow personal too,
      since an "On every push" trigger sits dormant while Auto review is off
      and arms across every Follow-personal repo at once the moment the
      personal toggle changes. The draft-workbench lifecycle drives Codex with
      explicit `@codex review` requests while the PR is draft; left on,
      `gh pr ready` starts a *new* asynchronous review after the readiness gate,
      and non-draft stops truthfully meaning "ready for a human". No API exposes
      this setting, so it is a human-configured prerequisite the gate trusts on
      the strength of this record — never report it as mechanically verified,
      and re-check it here if Codex's settings change.
      **Codex Auto-review attestation (confirmed 2026-08-13):** personal Auto
      review **off**; this repository's Auto code review preference **Follow
      personal**; its review Trigger **Follow personal**. Agents rely on this
      entry silently and re-raise only on drift evidence (an unsolicited Codex
      review nobody triggered); re-confirm and re-date it if that happens.
- [ ] **[human-only]** Probe: Read each connected review service configuration and its draft review setting. Write: none. <!-- reconcile-id: template-any-other-automatic-reviewer-must-re-023 --> **Any other automatic reviewer must review drafts** — if you
      enable one (GitHub Copilot code review, for example), turn on its draft-review option.
      A reviewer that skips drafts first reports *after* promotion, so the
      readiness gate would hand a human a PR it had not actually reviewed.
      Leave it off rather than run it blind to the workbench.
- [ ] **[human-only]** Probe: Read Actions secret names with gh secret list and compare the expected name. Write: none. <!-- reconcile-id: template-actions-secret-claude-code-oauth-tok-024 --> Actions secret: `CLAUDE_CODE_OAUTH_TOKEN` (claude-* workflows) — generate
      with `claude setup-token`; the value must start **`sk-ant-oat01-`** (an OAuth
      token, billed to your Claude subscription), **not** `sk-ant-api03-` (a raw API
      key, billed at pay-as-you-go API rates). Then `gh secret set CLAUDE_CODE_OAUTH_TOKEN`
- [ ] **[human-only]** Probe: Read Foreman configuration and the names of its credential references without revealing credentials. Write: none. <!-- reconcile-id: template-foreman-operator-setup-provision-the-025 --> **Foreman operator setup** — provision the separate READ-ONLY PAT that
      foreman hands to dispatched agents: export/store it as
      `FOREMAN_AGENT_GH_TOKEN` where the bot devcontainer's `init-env.sh` can
      inject it (1Password → devcontainer.env). Run `task setup:github-labels`
      so the `foreman:*` arming labels exist. Import the two tag rulesets
      (`.github/Tag Protection Ruleset - Version Tag Creation.json` /
      `… Immutability.json`, same UI import as the branch ruleset). At
      generation, set `ci_app_integration_id` to the CI GitHub App's numeric
      App ID (the Integration ID used by the ruleset). Find it under the
      account that owns the App: Settings → Developer settings → GitHub Apps →
      your App; use **App ID**, not the client ID or installation ID. If you
      leave it empty, release-please cannot create version tags after importing
      the ruleset; add the Integration actor manually or regenerate with the
      answer set, or update an existing checkout with
      `copier update --trust --data ci_app_integration_id=<id>`. The bypass
      applies to every workflow that mints a token from this App, including the
      Claude implement job's agent push token, so an opted-in repository lets
      that job create `v*` tags, which Version Tag Immutability then makes
      undeletable. Recommend a dedicated release-only GitHub App when that
      matters. The
      Creation ruleset grants it `always` bypass; Immutability keeps an
      empty bypass list on purpose: a moved `v*` tag is code execution in
      every consumer, so nobody bypasses it. Create the standing probe tag on
      an **orphan commit**, so it is reachable from no branch:
      `git tag v0.0.0-probe "$(git commit-tree "$(git hash-object -t tree /dev/null)" -m 'foreman tag-immutability probe target (orphan; keep unreachable from any branch)')" && git push origin v0.0.0-probe`.
      Do not tag `HEAD` or any commit on `main`: `git describe` considers only
      tags reachable from `HEAD` and prefers the nearest, so a probe tag on a
      release commit outranks the release tag, and everything deriving a
      version from `git describe` — release tooling, image tags, package
      builds — then reports `0.0.0-probe` instead of the release. The probe
      only needs the remote tag's sha to differ from `main`'s, so an orphan
      target satisfies it permanently. Preflight
      empirically asserts `v*` tags are immutable and fails until both
      rulesets and the tag exist. Then `task foreman:preflight` (inside the
      bot devcontainer — foreman refuses to start anywhere else) to assert
      the security controls before any dispatch.
- [ ] **[human-only]** Probe: Read .foreman.toml reviewer settings and the latest reviewer gate evidence. Write: none. <!-- reconcile-id: template-foreman-reviewer-gate-check-foreman-026 --> **Foreman reviewer-gate check** — `.foreman.toml`'s
      `[reviewer]` table is foreman's current-head review gate for the PRs it
      shepherds. Before the first dispatch (and again after any Foreman bump),
      confirm the configured `login` still matches the live Codex connector
      identity (actor ID `199175422`), that its terminal results — an APPROVED
      review at the head, or a 👍 from that login on foreman's own request
      comment — still mean what the readiness gate assumes, and that required
      checks run on draft PRs (foreman promotes only after they conclude).
- [ ] **[unknown-when-unprivileged]** Probe: Read the Semgrep workflow and the repository code scanning configuration. Write: none. <!-- reconcile-id: template-sast-coverage-this-profile-has-no-co-029 --> **SAST coverage** — this profile has no CodeQL workflow, so Semgrep CE runs
      in `build.yml` for public and private repositories. Add CodeQL later if the
      repo gains supported first-party source: turn off GitHub's CodeQL Default
      setup (**Settings → Advanced Security → CodeQL analysis**, or
      `gh api --method PATCH repos/OWNER/REPO/code-scanning/default-setup -f state=not-configured`),
      re-apply the template with `use_codeql=true` and the selected
      `codeql_languages` (then, if Default setup had disabled an existing CodeQL
      workflow, re-enable it via **Actions → CodeQL → "Enable workflow"** or
      `gh workflow enable codeql.yml`), and ensure the repository is public
      (free) or has paid GitHub Code Security (private/internal).
- [ ] **[unknown-when-unprivileged]** Probe: Read the Snyk workflow schedule and configured secret names. Write: none. <!-- reconcile-id: template-choose-the-snyk-posture-the-default-030 --> **Choose the Snyk posture** — the default is manual/local only via
      `task security:sast:snyk` and `task security:sca:snyk`; it is not part of
      `task security` or required PR CI. Free private-repository tests share the
      Snyk Organization's monthly quota, including local CLI tests. Leave the
      Snyk GitHub App off unless deliberately adopting its PR integration; its
      checks are not required by the default branch ruleset.
- [ ] **[unknown-when-unprivileged]** Probe: Read the Snyk workflow schedule and Actions secret names. Write: none. <!-- reconcile-id: template-activate-scheduled-snyk-snyk-scan-sc-031 --> **Activate scheduled Snyk (weekly)** —
      `snyk-scheduled.yml` was generated as an advisory SAST + SCA second
      opinion. Set the Actions secret `SNYK_TOKEN`, use **Run workflow** once to
      verify it, and check the Snyk Organization Usage page. It has schedule and
      manual triggers only—never PR/push—and is not a required check. Daily is
      intended for public or accepted unlimited OSS. Confirm Snyk recognizes the
      public Git remote and does not debit private-test usage; if it does, run
      `snyk monitor` once and set the Project's Git remote URL in Snyk. Reconsider
      weekly private scans if the shared quota is too small.
- [ ] **[human-only]** Probe: Read GitHub App registrations for the expected CI app name. Write: none. <!-- reconcile-id: template-create-the-ci-github-app-github-org-034 --> **Create** the CI GitHub App `evanharmon1-ci` by hand (one App per org;
      **Settings → Developer settings → GitHub Apps**), or reuse the org's existing one.
- [ ] **[human-only]** Probe: Read the CI GitHub App permissions in its settings. Write: none. <!-- reconcile-id: template-confirm-ci-github-app-permissions-th-035 --> **Confirm CI GitHub App permissions** — the App must grant
      **Checks: Read-only**, **Commit statuses: Read-only**, and
      **Actions: Read-only** for
      claude-implement's `gh pr checks`. For an existing App, update its
      **Permissions & events** and accept the new permissions on **every
      installation**; until then, `create-github-app-token` fails and
      claude-implement cannot start. See
      [architecture/security.md](architecture/security.md#ci-automation-identity-github-app).
- [ ] **[human-only]** Probe: Read GitHub App installations for this repository. Write: none. <!-- reconcile-id: template-install-the-app-on-this-repo-install-036 --> **Install** the App on this repo — **Install App → Only select repositories**
      (the harmon-init repos that run release-please / claude-* / project-automation),
      **not "All"**. **Creating the App is not enough:** an App whose credentials are
      set but which is *not installed* on the repo makes
      `actions/create-github-app-token` fail at runtime with a **404**
      (`Not Found` — "not installed on this repository"). This is the single
      easiest step to miss.
- [ ] **[human-only]** Probe: Read Actions variable and secret names with gh variable list and gh secret list. Write: none. <!-- reconcile-id: template-set-ci-app-client-id-actions-variabl-037 --> Set `CI_APP_CLIENT_ID` (Actions **variable**) + `CI_APP_PRIVATE_KEY` (Actions
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
- [ ] **[human-only]** Probe: Read package publishing permissions and the current package list. Write: none. <!-- reconcile-id: template-ghcr-ensure-the-org-user-allows-publ-038 --> GHCR: ensure the org/user allows publishing packages; the first
      devcontainer prebuild populates `ghcr.io/evanharmon1/harmon-devkit-devcontainer` on merge to main
- [ ] **[agent-apply]** Probe: Read the owner project list and project fields with gh project list and gh project field-list. Write: `task setup:github-project`. <!-- reconcile-id: template-github-project-run-task-setup-github-039 --> GitHub Project: run `task setup:github-project` (needs
      `gh auth refresh -s project`) to create the owner's default project (titled
      `evanharmon1 Project`) and idempotently sync its `Status` pipeline —
      see [project-management.md](project-management.md).
      On a personal account it also creates Product as a project field (issue
      fields are org-only; there is deliberately no Priority, Size, Domain, or
      Layer field — see [project-management.md](project-management.md),
      "Fields" and "Label or field?"); status automation is a separate
      follow-up — the board is set up, but issue/PR status isn't auto-synced
      yet. Re-runs **append** any starter option the Status field is missing
      (so a value added by a later harmon-init release lands on the next run)
      and never touch, reorder, or delete the options you added.
- [ ] **[human-only]** Probe: Read the project field list and compare it with the documented migration state. Write: none. <!-- reconcile-id: template-upgrading-from-a-release-before-harm-041 --> **Upgrading from a release before harmon-init#875?**
      If this repo's board still carries `Domain`/`Layer` fields from an
      earlier release, they are not deleted automatically.
      Retiring them is a deliberate, irreversible operator step — see
      [project-management.md](project-management.md), "Migrating a board that
      still has one."
- [ ] **[human-only]** Probe: Read the project field list for Priority and Size. Write: none. <!-- reconcile-id: template-delete-the-priority-and-size-project-042 --> **Delete the `Priority` and `Size` project fields on an
      existing board** — only if this repo's board was set up by a release
      before harmon-init#1451; they are not deleted automatically, and
      deleting a field destroys every value on it, unrecoverably. Do it after
      the classification labels exist (on a personal account,
      `task setup:github-labels` provisions the `priority:*` labels that
      replace `Priority`, plus `priority-ai:*` for the AI's separate
      suggestion beside it) and
      after enumerating every board and view that references each field
      (harmon-init#910), as [project-management.md](project-management.md),
      "Migrating a board that still has one" (the Priority / Size entry) lays
      out. On a personal account both fields go; on an organization only `Size`
      was ever a project field — its `Priority` is GitHub's built-in issue
      field and stays.
- [ ] **[human-only]** Probe: Read the project field configuration and compare it with the documented migration state. Write: none. <!-- reconcile-id: template-upgrading-from-a-release-before-harm-043 --> **Upgrading from a release before harmon-init#1047
      (`method:*` → `strategy:*`)?** Run `task setup:github-labels` first so
      the `strategy:*` destinations exist, then use the read-only report and
      guarded maintenance flow below. For each live value among `oneshot`,
      `plan`, `plan-approved`, `orchestrate`, `council`, and `human-led`, pass
      one `--migrate method:<v>=strategy:<v>`; the guarded flow attempts to move
      associations for matching issues, PRs, and discussions found in its paginated snapshots,
      re-reads them, and only then allows `--prune` to remove zero-association
      retired labels.
- [ ] **[agent-apply]** Probe: Read repository labels with gh label list and compare them with the label registry. Write: `task setup:github-labels`. <!-- reconcile-id: template-labels-run-task-setup-github-labels-044 --> Labels: run `task setup:github-labels` to seed this repo's starter label
      families from `label-registry.json`
      (see the generated taxonomy table in
      [project-management.md](project-management.md)) — grow `domain:` values
      there as the product's own problem-space vocabulary and `area:` values as
      its solution-space subsystems; both starter lists are a floor. `layer:`
      is product-independent and normally needs no edits. Labels are per-repo,
      so run it in each repo; org default labels (org Settings → Repository,
      UI-only) only seed new repos.
- [ ] **[human-only]** Probe: Read issue Tier labels and the tier pin labels before classification. Write: none. <!-- reconcile-id: template-pin-any-hand-applied-tier-before-the-045 --> **Pin any hand-applied Tier before the first classification
      write** — on an existing repository an unqualified `tier:<value>` label
      used to be a human's implementer override; it is now the cache automation
      rewrites. On an unpinned issue with Risk and Complexity set, a writer of
      those axes (such as the triage skill, once its pin carries
      harmon-devkit#1250) adds the derived Tier and removes every other tier
      label.
      The classification reconciler does the same on its schedule (daily on a
      personal-account repository, monthly on an organization one).
      Before that first write, add `tier:pinned` to each open issue whose
      hand-set tier label you want to keep.
- [ ] **[agent-apply]** Probe: Read the repository label list and compare it with the label registry. Write: `task setup:github-labels`. <!-- reconcile-id: template-after-a-copier-update-that-adds-labe-046 --> **After a `copier update` that adds label families** (e.g. `impact:*` — a
      pure addition), re-run `task setup:github-labels` to provision the new
      labels here — it is additive and never deletes, so existing labels and
      the issues they sit on are untouched — then classify open issues with the
      added families. A RENAMED family (like `method:*` → `strategy:*` above)
      is not a pure addition — provision the new destinations first, then
      migrate the old associations before retiring their labels.
- [ ] **[human-only]** Probe: Read the repository label list and its issue usage before considering retirement. Write: none. <!-- reconcile-id: template-inspect-live-label-drift-before-reti-047 --> **Inspect live label drift before retiring anything** — keep
      the default setup path additive, then run
      `./scripts/setup-github-labels.sh --repo <owner/repo> --report-unregistered`
      with the same `--foreman` / `--release-please` profile flags used for
      setup when you want to mirror provisioning. Maintenance protection still
      includes every non-retired registered family, including gated tool labels,
      when those flags are omitted. This is read-only: it pages through the
      live labels, all-state issues and pull requests, and repository
      discussions, and reports separate association counts. An indeterminate read is a stop, not
      permission to clean up.
- [ ] **[human-only]** Probe: Read legacy label names and their issue usage. Write: none. <!-- reconcile-id: template-retire-any-legacy-agent-claim-labels-048 --> **Retire any legacy `agent:*` claim labels or pre-2026
      `codex`/`copilot` labels** — use the guarded maintenance flow, never a
      direct `gh label delete` or a hand-written association list. Perform its
      write path in a quiescent maintenance window: pause claim/release,
      Foreman, release-please, and other human/API label writers for the whole
      run. `--report-unregistered` is read-only, but its counts are a snapshot;
      run it again immediately before `--prune`.

      `suggest:*` (superseded by the derived Tier) and `tier:adaptive` (no rung
      on the Tier scale) have no `--migrate` destination, and the command
      refuses one: remove the label from every issue, pull request and
      discussion that carries it (an issue then resolves through its derived
      Tier), then run `--prune`.

      For fixed-family sources, these mappings are authoritative:
      `agent:claude-code` → `claim:claude`, `agent:codex` → `claim:gpt`,
      `agent:gemini-cli` → `claim:gemini`, `agent:kimi-k2` → `claim:kimi`, `agent:qwen-code` →
      `claim:qwen`, and `claim:codex` → `claim:gpt`. Pass one repeatable
      `--migrate OLD=NEW` per exact live
      source, together with `--prune`; for example,
      `./scripts/setup-github-labels.sh --repo <owner/repo> --prune
      --migrate agent:gemini-cli=claim:gemini`. `--migrate` does not match a
      prefix, so each live model-level source needs its own mapping. The
      `OLD=NEW` form contains exactly one `=`; a label name containing `=` must
      be relabeled per record instead of passed to bulk migration. Move only
      the family segment for fixed mappings and preserve the recorded model
      suffix, e.g. `claim:codex:sol` → `claim:gpt:sol`; model-level labels
      refine rather
      than replace their family-level label, and the command retains or adds
      both associations. If a recognized model-level
      destination is absent, the command creates it after confirmation by
      copying metadata from the live family label; missing family labels stop
      maintenance and require setup first.

      Use this association-migration path, not `gh label edit` or a hand-written
      create-then-delete sequence: the command validates a live registry
      destination or creates a recognized on-demand model destination as
      described above, attempts the association move for each matching issue,
      PR, and discussion found in its paginated snapshots, then permits
      `--prune` only when a fresh snapshot
      shows the source has zero associations. Enumerate
      model-level names explicitly with `gh label list --repo <owner/repo>
      --limit 1000 --json name --jq '.[].name' | grep -E
      '^claim:(codex|copilot):'`; for each source, inspect all-state
      `gh issue list --label <old> --state all --limit 1000` **and**
      `gh pr list --label <old> --state all --limit 1000`. An exactly-full
      manual result is capped; increase the limit and rerun before writes. The
      maintenance path itself uses `gh api --paginate` and refuses an
      indeterminate read.

      Copilot is a broker, not a fixed family: `mai` is only the picker default
      and is never a guessed destination. Do **not** pass
      `agent:github-copilot*` or `claim:copilot*` to bulk
      `--migrate` — the command rejects broker-derived sources because one
      destination cannot represent mixed runtime records. For `claim:copilot`,
      inspect each issue/PR's claim/session record and relabel that record to
      `claim:<actual-family>`; use `claim:mai` only when the record confirms
      MAI. Apply the same per-record distinction to
      `claim:copilot:<model>` and preserve a model
      suffix only after the actual family is known. Include Discussions in that
      per-record inventory: the read-only report gives their association count,
      and the Discussions UI or GraphQL API identifies the records to relabel.
      If a live claim's record is
      missing, settle it with its owner or leave the label untouched rather
      than guess. Add and verify the per-record destination before removing the
      old association; after every record is handled, a fresh zero-association
      snapshot may permit guarded `--prune` to attempt retiring the source.

      Before moving any in-flight `claim:*`/legacy `agent:*` marker, settle the
      claim or amend its durable record in the same sitting: its release path
      names the exact label it will remove, and moving only the issue/PR
      association strands the replacement marker. Interactive runs confirm on
      the TTY; automation must state destructive intent again with separate
      `--yes` (piped stdin is refused).

      The command verifies each migration around source removal, then takes one
      complete, bounded post-migration association snapshot before the deletion
      batch and fails closed on read/verification errors, but GitHub has no transaction or
      compare-and-swap that binds the final read to the following edit/DELETE.
      A concurrent writer can still change labels after that read and before
      the request, and the command cannot undo a successful concurrent
      mutation. If writers were not paused or any verification drifts, treat
      the operation as incomplete, reconcile live associations, and rerun in a
      new quiet window; do not infer association preservation from a successful
      exit alone; this is a guarded best-effort operation at that API boundary.
- [ ] **[human-only]** Probe: none. Write: none. <!-- reconcile-id: template-project-views-create-the-starter-vie-049 --> Project views: create the starter views that the Views section of
      [project-management.md](project-management.md) specifies — including
      Needs review and Human queue — in the Project UI. Projects V2 has no view
      API, so this is a one-time manual step; the filters and layouts are in
      that section.
- [ ] **[human-only]** Probe: none. Write: none. <!-- reconcile-id: template-github-project-auto-add-adds-every-i-050 --> GitHub Project auto-add (**adds every issue to the board**): in the
      Project's **Settings → Workflows**, turn on **"Auto-add to project"** and
      point it at this repo (filter `is:issue`, `is:pr`) so *every* new issue and
      PR lands on the board automatically, however it's created. GitHub's native
      built-in — no Actions or tokens, and it's the reliable way to guarantee
      coverage (the issue-form `projects:` key only covers form-created issues and
      needs a static project number). See
      [project-management.md](project-management.md).

## 3. Framework scaffolding (conventions-only template)

- [ ] **[human-only]** Probe: Read project manifests and Taskfile build and test tasks for the chosen toolchain. Write: none. <!-- reconcile-id: template-add-the-project-s-primary-toolchain-087 --> Add the project's primary toolchain; extend Taskfile `build`/`test` accordingly

## 4. Secrets & environment

- [ ] **[human-only]** Probe: Read local environment references and the configured 1Password environment without exposing secret values. Write: none. <!-- reconcile-id: template-for-local-env-needs-use-1password-en-090 --> For local `.env` needs, use **1Password Environments** (mounts a virtual
      `.env`; secrets never hit disk or git) or `op run`/`op inject`. Commit only
      `.env.example`-style files
- [ ] **[human-only]** Probe: Read the configured secret references and the devcontainer configuration without reading secret values. Write: none. <!-- reconcile-id: template-devcontainer-secrets-create-a-1passw-092 --> Devcontainer secrets: create a **1Password environment** that mounts
      `.devcontainer/devcontainer.env` (and `.devcontainer/dev/devcontainer.env`)
      with `CLAUDE_CODE_OAUTH_TOKEN` and `AGENT_DECK_TELEGRAM_KEY`, plus
      `GH_TOKEN` for the bot profile and `TS_AUTHKEY` for the dev one — the dev
      profile carries no `GH_TOKEN` and runs `gh auth login` instead.
      `init-env.sh` enforces the per-profile
      allow-list; on Coder the values come from workspace parameters. The
      agent posture's `.devcontainer/agent/devcontainer.env` takes only
      `AGENT_GH_TOKEN` and `CLAUDE_CODE_OAUTH_TOKEN` (plus opted-in provider
      keys) and refuses to build with anything else. See
      [guides/devcontainers.md](guides/devcontainers.md)

## 5. Docs & meta

- [ ] **[human-only]** Probe: Read README.md and docs for unresolved TODO markers. Write: none. <!-- reconcile-id: template-fill-in-the-todo-markers-in-readme-m-093 --> Fill in the `TODO:` markers in README.md and docs/ (architecture diagram first)
- [ ] **[human-only]** Probe: Read README badge links and the latest GitHub Actions results. Write: none. <!-- reconcile-id: template-confirm-readme-badges-render-actions-094 --> Confirm README badges render (Actions URLs are correct once CI runs)
- [ ] **[human-only]** Probe: Read the repository release list and release task configuration. Write: `task release:init`. <!-- reconcile-id: template-initial-release-when-ready-task-rele-095 --> Initial release when ready: `task release:init` (v0.1.0) — releases stay manual
- [ ] **[human-only]** Probe: Read the Copier answers commit and compare it with the current harmon-init release. Write: none. <!-- reconcile-id: template-stay-current-with-harmon-init-period-096 --> Stay current with harmon-init: periodically use the standardize-repo skill's
      `update` mode to pull template improvements (a three-way merge — your own edits
      are preserved). Follow its guarded source/ref/answer flow end to end; do not
      substitute a bare `copier update --trust`.
