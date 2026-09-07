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

- [ ] `task install` — Brewfile deps, and lefthook git hooks
- [ ] `task verify` passes locally
- [ ] Import the branch ruleset (see [architecture/branch-protection.md](architecture/branch-protection.md)) — do this once `build.yml`, `devcontainer-build.yml` are on `main` so the required `verify`/`security`/`devcontainer-verify` checks resolve. **Use the UI import:** Settings → Rules → Rulesets → **New ruleset ▸ Import a ruleset** → select `.github/Branch Protection Ruleset - Protect Main.json`. (Prefer the UI over `gh api … rulesets`: the API `POST` is not idempotent — re-running creates a duplicate ruleset — and currently rejects the `merge_queue` rule. To later change the ruleset, edit the existing one in the UI rather than re-importing.)
- [ ] **[human-only] Add `closing-keywords` to the live branch ruleset** — after
      the `closing-keywords` build job has reported once, edit the existing
      main-branch ruleset in Settings → Rules → Rulesets and add that exact
      required status check. Do not re-import the JSON solely for this change:
      GitHub creates a duplicate ruleset rather than updating the live one.
- [ ] **[human-only] Enable unattributed-changes approval in the live branch
      ruleset** — after a `copier update` adds this parameter, edit the existing
      main-branch ruleset in Settings → Rules → Rulesets and enable the matching
      additional-approval setting. Do not re-import the JSON: GitHub creates a
      duplicate ruleset rather than updating the live one.

- [ ] **Install and activate Renovate** — install the
      [Renovate app](https://github.com/apps/renovate) for **Only select
      repositories** and select this repo. In the Mend Developer Portal choose
      the **Renovate** product and **Scan and Alert** mode. Do not choose **Scan
      Only**: it puts Renovate in silent mode, which scans without creating
      checks, issues (including the Dependency Dashboard), or update/remediation
      PRs. This repo already has `renovate.json`; keep that configuration rather
      than replacing it with a generic onboarding config.
- [ ] **[human-only] Confirm CodeRabbit has no access** — for a repository that
      previously used it, remove this repo from the CodeRabbit GitHub App
      installation. Deleting `.coderabbit.yaml` and bot trust does not revoke
      existing App access.
- [ ] **[human-only] Connect Codex cloud review** — connect this repository in
      ChatGPT Codex settings, grant private-repository access if applicable,
      and confirm review activity is authored by GitHub actor ID `199175422`
      (`chatgpt-codex-connector[bot]`, type `Bot`).
- [ ] **[human-only] Disable Codex Automatic reviews** — turn **personal Auto
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
- [ ] **[human-only] Any other automatic reviewer must review drafts** — if you
      enable one (GitHub Copilot code review, for example), turn on its draft-review option.
      A reviewer that skips drafts first reports *after* promotion, so the
      readiness gate would hand a human a PR it had not actually reviewed.
      Leave it off rather than run it blind to the workbench.
- [ ] Actions secret: `CLAUDE_CODE_OAUTH_TOKEN` (claude-* workflows) — generate
      with `claude setup-token`; the value must start **`sk-ant-oat01-`** (an OAuth
      token, billed to your Claude subscription), **not** `sk-ant-api03-` (a raw API
      key, billed at pay-as-you-go API rates). Then `gh secret set CLAUDE_CODE_OAUTH_TOKEN`
- [ ] **Foreman operator setup** — provision the separate READ-ONLY PAT that
      foreman hands to dispatched agents: export/store it as
      `FOREMAN_AGENT_GH_TOKEN` where the bot devcontainer's `init-env.sh` can
      inject it (1Password → devcontainer.env). Run `task setup:github-labels`
      so the `foreman:*` arming labels exist. Import the two tag rulesets
      (`.github/Tag Protection Ruleset - Version Tag Creation.json` /
      `… Immutability.json`, same UI import as the branch ruleset), then add
      the CI GitHub App to the **Creation** ruleset's bypass list (`always`) —
      release-please tags via that App, and bypass-actor App IDs are
      per-installation so the JSON cannot ship them. (Immutability keeps an
      empty bypass list on purpose: a moved `v*` tag is code execution in
      every consumer, so nobody bypasses it.) Create the standing probe tag on
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
- [ ] **[human-only] Foreman reviewer-gate check** — `.foreman.toml`'s
      `[reviewer]` table is foreman's current-head review gate for the PRs it
      shepherds. Before the first dispatch (and again after any Foreman bump),
      confirm the configured `login` still matches the live Codex connector
      identity (actor ID `199175422`), that its terminal results — an APPROVED
      review at the head, or a 👍 from that login on foreman's own request
      comment — still mean what the readiness gate assumes, and that required
      checks run on draft PRs (foreman promotes only after they conclude).
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
- [ ] GitHub Project: run `task setup:github-project` (needs
      `gh auth refresh -s project`) to create the owner's default project (titled
      `evanharmon1 Project`) and idempotently sync its `Status` pipeline and
      `Size` number field — see
      [project-management.md](project-management.md).
      On a personal account it also creates Priority/Product/Size as project
      fields (issue fields are org-only; there is deliberately no Domain or
      Layer field — see [project-management.md](project-management.md), "Label
      or field?"); status automation is a separate follow-up — the board is set
      up, but issue/PR status isn't auto-synced yet. Re-runs **append** any
      starter option a single-select field is missing (so a value added by a
      later harmon-init release lands on the next run) and never touch,
      reorder, or delete the options you added.
- [ ] **Upgrading from a release before harmon-init#875?**
      If this repo's board still carries `Domain`/`Layer` fields from an
      earlier release, they are not deleted automatically.
      Retiring them is a deliberate, irreversible operator step — see
      [project-management.md](project-management.md), "Migrating a board that
      still has one."
- [ ] **Upgrading from a release before harmon-init#1047
      (`method:*` → `strategy:*`)?** Run `task setup:github-labels` first so
      the `strategy:*` destinations exist, then use the read-only report and
      guarded maintenance flow below. For each live value among `oneshot`,
      `plan`, `plan-approved`, `orchestrate`, `council`, and `human-led`, pass
      one `--migrate method:<v>=strategy:<v>`; the guarded flow attempts to move
      associations for matching issues, PRs, and discussions found in its paginated snapshots,
      re-reads them, and only then allows `--prune` to remove zero-association
      retired labels.
- [ ] Labels: run `task setup:github-labels` to seed this repo's starter label
      families from `label-registry.json`      (see the generated taxonomy table in
      [project-management.md](project-management.md)) — grow `domain:` values
      there as the product's own problem-space vocabulary and `area:` values as
      its solution-space subsystems; both starter lists are a floor. `layer:`
      is product-independent and normally needs no edits. Labels are per-repo,
      so run it in each repo; org default labels (org Settings → Repository,
      UI-only) only seed new repos.
- [ ] **After a `copier update` that adds label families** (e.g. `tier:*` — a
      pure addition), re-run `task setup:github-labels` to provision the new
      labels here — it is additive and never deletes, so existing labels and
      the issues they sit on are untouched — then classify open issues with the
      added families. A RENAMED family (like `method:*` → `strategy:*` above)
      is not a pure addition — provision the new destinations first, then
      migrate the old associations before retiring their labels.
- [ ] **[human-only] Inspect live label drift before retiring anything** — keep
      the default setup path additive, then run
      `./scripts/setup-github-labels.sh --repo <owner/repo> --report-unregistered`
      with the same `--foreman` / `--release-please` profile flags used for
      setup when you want to mirror provisioning. Maintenance protection still
      includes every non-retired registered family, including gated tool labels,
      when those flags are omitted. This is read-only: it pages through the
      live labels, all-state issues and pull requests, and repository
      discussions, and reports separate association counts. An indeterminate read is a stop, not
      permission to clean up.
- [ ] **[human-only] Retire any legacy `agent:*` claim labels or pre-2026
      `codex`/`copilot` labels** — use the guarded maintenance flow, never a
      direct `gh label delete` or a hand-written association list. Perform its
      write path in a quiescent maintenance window: pause claim/release,
      Foreman, release-please, and other human/API label writers for the whole
      run. `--report-unregistered` is read-only, but its counts are a snapshot;
      run it again immediately before `--prune`.

      For fixed-family sources, these mappings are authoritative:
      `agent:claude-code` → `claim:claude`, `agent:codex` → `claim:gpt`,
      `agent:gemini-cli` → `claim:gemini`, `agent:kimi-k2` → `claim:kimi`, `agent:qwen-code` →
      `claim:qwen`, `suggest:codex` → `suggest:gpt`, and `claim:codex` →
      `claim:gpt`. Pass one repeatable `--migrate OLD=NEW` per exact live
      source, together with `--prune`; for example,
      `./scripts/setup-github-labels.sh --repo <owner/repo> --prune
      --migrate agent:gemini-cli=claim:gemini`. `--migrate` does not match a
      prefix, so each live model-level source needs its own mapping. The
      `OLD=NEW` form contains exactly one `=`; a label name containing `=` must
      be relabeled per record instead of passed to bulk migration. Move only
      the family segment for fixed mappings and preserve the recorded model
      suffix, e.g. `suggest:codex:sol` → `suggest:gpt:sol` and
      `claim:codex:sol` → `claim:gpt:sol`; model-level labels refine rather
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
      '^(suggest|claim):(codex|copilot):'`; for each source, inspect all-state
      `gh issue list --label <old> --state all --limit 1000` **and**
      `gh pr list --label <old> --state all --limit 1000`. An exactly-full
      manual result is capped; increase the limit and rerun before writes. The
      maintenance path itself uses `gh api --paginate` and refuses an
      indeterminate read.

      Copilot is a broker, not a fixed family: `mai` is only the picker default
      and is never a guessed destination. Do **not** pass
      `agent:github-copilot*`, `suggest:copilot*`, or `claim:copilot*` to bulk
      `--migrate` — the command rejects broker-derived sources because one
      destination cannot represent mixed runtime records. For
      `suggest:copilot`, there is no claim/session record: re-express each
      issue/PR's planning intent as `suggest:<actual-family>` or drop the old
      association; do not rename it to `suggest:mai`. For `claim:copilot`,
      inspect each issue/PR's claim/session record and relabel that record to
      `claim:<actual-family>`; use `claim:mai` only when the record confirms
      MAI. Apply the same per-record distinction to
      `suggest:copilot:<model>`/`claim:copilot:<model>` and preserve a model
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
- [ ] Project views: create the starter views (Board / Triage / Agent queue /
      Planning / Mine) in the Project UI — Projects V2 has no view API,
      so this is a one-time manual step. Filters/layouts are in
      [project-management.md](project-management.md).
- [ ] GitHub Project auto-add (**adds every issue to the board**): in the
      Project's **Settings → Workflows**, turn on **"Auto-add to project"** and
      point it at this repo (filter `is:issue`, `is:pr`) so *every* new issue and
      PR lands on the board automatically, however it's created. GitHub's native
      built-in — no Actions or tokens, and it's the reliable way to guarantee
      coverage (the issue-form `projects:` key only covers form-created issues and
      needs a static project number). See
      [project-management.md](project-management.md).

## 3. Framework scaffolding (conventions-only template)

- [ ] Add the project's primary toolchain; extend Taskfile `build`/`test` accordingly

## 4. Secrets & environment

- [ ] For local `.env` needs, use **1Password Environments** (mounts a virtual
      `.env`; secrets never hit disk or git) or `op run`/`op inject`. Commit only
      `.env.example`-style files
- [ ] Devcontainer secrets: create a **1Password environment** that mounts
      `.devcontainer/devcontainer.env` (and `.devcontainer/dev/devcontainer.env`)
      with `CLAUDE_CODE_OAUTH_TOKEN` and `AGENT_DECK_TELEGRAM_KEY`, plus
      `GH_TOKEN` for the bot profile and `TS_AUTHKEY` for the dev one — the dev
      profile carries no `GH_TOKEN` and runs `gh auth login` instead.
      `init-env.sh` enforces the per-profile
      allow-list; on Coder the values come from workspace parameters. See
      [guides/devcontainers.md](guides/devcontainers.md)

## 5. Docs & meta

- [ ] Fill in the `TODO:` markers in README.md and docs/ (architecture diagram first)
- [ ] Confirm README badges render (Actions URLs are correct once CI runs)
- [ ] Initial release when ready: `task release:init` (v0.1.0) — releases stay manual
- [ ] Stay current with harmon-init: periodically use the standardize-repo skill's
      `update` mode to pull template improvements (a three-way merge — your own edits
      are preserved). Follow its guarded source/ref/answer flow end to end; do not
      substitute a bare `copier update --trust`.
