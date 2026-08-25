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
- [ ] Verify `harmon-devkit.code-workspace` opens the repo's folder in VS Code and has a unique VS Code Workspace color. Then add any other related repos (e.g. other org repos) to the `folders` list in the workspace file so you have quick access to those repos
- [ ] Extend `.gitignore` for your stack — the template ships a base; add stack-specific entries via [gitignore.io](https://www.toptal.com/developers/gitignore)
- [ ] macOS: add a Raycast quicklink/alias that opens the `harmon-devkit.code-workspace`
- [ ] macOS (Bunch): scaffold the launcher with `task util:bunch-add` (if not generated at copier time), then `task util:bunch-install` to move it to iCloud and leave a `.meta/*.bunch` symlink (re-run install if missing)

## 2. GitHub repo settings

- [ ] **Confirm draft pull requests are available on this repo** — every agent
      PR opens as a draft and is promoted only by the readiness gate (AGENTS.md,
      "Dev Loop"). GitHub restricts draft PRs on **private** repositories to its
      paid plans, so on a private free-plan repo `gh pr create --draft` fails
      outright and the whole lifecycle stops at its first step. Check the current
      plan matrix in [GitHub's draft-PR
      docs](https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/proposing-changes-to-your-work-with-pull-requests/changing-the-stage-of-a-pull-request);
      if drafts are unavailable, make the repo public, upgrade the plan, or
      decide deliberately not to run agent workflows here — do not "fix" it by
      dropping `--draft`, which would make an open PR mean nothing again.
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
- [ ] Labels: run `task setup:github-labels` to seed this repo's starter label
      families from `label-registry.json`      (see the generated taxonomy table in
      [project-management.md](project-management.md)) — grow `domain:` values
      there as the product's own problem-space vocabulary and `area:` values as
      its solution-space subsystems; both starter lists are a floor. `layer:`
      is product-independent and normally needs no edits. Labels are per-repo,
      so run it in each repo; org default labels (org Settings → Repository,
      UI-only) only seed new repos.
- [ ] **After a `copier update` that adds a genuinely new label family**
      (e.g. `tier:<role>:*`), re-run `task setup:github-labels` to provision
      it here — it is additive and never deletes, so existing labels and the
      issues they sit on are untouched — then classify open issues with the
      added family.
- [ ] **[human-only] `strategy:*` is not a new family — it is `method:*`
      renamed (harmon-init#1047).** If this repo has no live `method:*`
      labels, the plain additive step above is enough. If it does,
      **rename before provisioning**: `task setup:github-labels` creates
      `strategy:<value>` fresh, and GitHub label names are unique, so a
      rename attempted after that line runs is rejected as a name collision —
      leaving an orphaned old label beside an empty new one instead of one
      migrated label. Use
      [`assets/migrate-label-family.sh`](../ai/skills/repo/standardize-repo/assets/migrate-label-family.sh)
      (the mechanism `mode-update.md` §6b walks through) — `inventory method`
      first (refuses while any issue/PR carries more than one `method:*`
      label; the old family had no `exclusive` constraint, the new one does),
      then `rename method:<value> strategy:<value> --execute` for each of the
      six values, then `verify method` to confirm none remain. If a value's
      `strategy:*` destination already exists live, `rename` refuses and
      points at `transfer` instead, which adds-and-verifies onto every item
      before deleting the source.
- [ ] **[human-only] Retire any legacy `agent:*` claim labels** — needed only
      where `gh label list --limit 1000` still shows the harness-named family
      (`agent:claude-code`, `agent:gemini-cli`, …) a pre-registry harmon-init
      seeded. **Start with an explicit `--limit 1000` on every `gh label list`,
      `gh issue list`, and `gh pr list` in this step**: all three default to 30.
      If any list returns exactly 1000 entries (`--json name --jq length` for
      labels; `--json number --jq length` for issues and PRs), treat it as capped:
      double the limit and re-run until the count is below the cap before any
      rename or delete. Otherwise a clean-looking result can leave legacy
      labels, in-flight claims, or labelled pull requests unseen.
      `setup-github-labels` never deletes a label, so the old family
      survives beside the registry-rendered `claim:*` one, and every reader
      tolerates both — this is cleanup, not a fix for something broken.
      **Rename, never re-create**: `gh label edit agent:claude-code --name
      claim:claude --repo <owner/repo>` edits the label object in place, so every
      issue and PR carrying it keeps it, where create-then-delete would silently
      drop those associations. Map by **model family, not harness** —
      `agent:gemini-cli` → `claim:gemini`, `agent:kimi-k2` → `claim:kimi`,
      `agent:qwen-code` → `claim:qwen` — these three are fixed-family
      harnesses, so the mapping is unconditional. `agent:github-copilot` is
      **not**: Copilot is a broker (registry `family_constraint.kind:
      "broker"`, default `mai`), so an old claim under that label may
      actually have run GPT, Claude, or another brokered family — check the
      claim/session record for which one before renaming, and rename to
      `claim:<actual-family>` (only `claim:mai` when the record confirms
      MAI). When the actual family can't be recovered: for a live claim,
      settle it with its owner first rather than guess; for a
      released/historical one, just delete the stale `agent:github-copilot`
      label off that issue/PR instead of renaming it — a guessed family is
      worse than none, since the claim label's whole meaning is the family.
      Target names otherwise come from
      `node scripts/agent-registry-labels.mjs suggest-claim`.
      **Destination-collision procedure**: a rename whose target already
      exists is rejected by GitHub (`gh label edit` errors: the destination
      name is already in use — e.g. `claim:claude` already exists from a prior
      `setup-github-labels` run). When that happens, migrate ASSOCIATIONS
      instead of the label object: for every issue and PR carrying the old
      label, add the destination label and remove the old one
      (`gh issue edit <number> --add-label claim:claude --remove-label
      agent:claude-code --repo <owner/repo>`; the same `--add-label
      X --remove-label Y` pair works on `gh pr edit`), then delete the
      now-empty old label (`gh label delete agent:claude-code --repo
      <owner/repo> --yes`) once a re-read of `gh issue list --label
      agent:claude-code --state all --limit 1000` **and** the equivalent
      `gh pr list` both return nothing — only then is it safe to delete; the
      other checklist items below that reference this procedure reuse it
      verbatim. Enumerate **`gh pr list` as well as `gh issue list`**
      throughout, collision or not: labels apply to
      pull requests too and `gh issue list` never returns them, so deleting the
      legacy label afterwards would drop exactly the associations the re-labelling
      missed — the loss this whole item exists to avoid. Check for in-flight
      claims first — `gh issue list --label agent:… --state all --limit 1000`
      **and** `gh pr list --label agent:… --state all --limit 1000`: a claim
      record naming the old label will not release the renamed one, so settle or
      amend those records in the same sitting. Re-read `gh label list --limit 1000` afterwards — no `agent:*`
      should remain.
- [ ] **[human-only] Retire pre-2026-refresh `codex`/`copilot` agent labels** —
      needed only where an explicit enumeration shows
      `suggest:codex`/`claim:codex` or `suggest:copilot`/`claim:copilot`
      still exist: `gh label list --repo <owner/repo> --limit 1000 --json
      name --jq '.[].name' | grep -E '^(suggest|claim):(codex|copilot)$'`
      (the default `gh label list --limit 200` paged listing can miss these
      on a repo with many labels — use this enumeration, not the paged form,
      everywhere in this item). harmon-init issue #751 replaced those
      harness-named families with model-family vocabulary: Codex maps to `gpt`;
      Copilot is a broker that defaults to `mai`, but each association must use
      the actual family recovered by the procedure below.
      A `setup-github-labels` re-run never deletes the old family, so it
      survives beside the new registry-rendered one.

      **`codex` → `gpt` is a fixed mapping** (Codex only ever ran GPT) —
      **rename, never re-create**, the same way as the `agent:*` item above:
      `gh label edit suggest:codex --name suggest:gpt --repo <owner/repo>`
      (repeat for `claim:codex`), which preserves issue/PR associations
      instead of dropping them.

      **`copilot` is NOT a fixed mapping — apply the same broker caution as
      the `agent:github-copilot` entry in the `agent:*` item above, not a
      blanket rename to `mai`.** Copilot is a broker (registry
      `family_constraint.kind: "broker"`, default `mai`): a `claim:copilot`
      may have actually run GPT, Claude, or another brokered family, and
      `suggest:copilot` only ever named a harness preference, never an MAI
      one. For `claim:copilot`, follow the `agent:*` item's procedure exactly
      — check the claim/session record for the actual family and rename to
      `claim:<actual-family>` (only `claim:mai` when the record confirms
      MAI); when unrecoverable, settle a live claim with its owner first, or
      delete the stale label from a released/historical issue/PR instead of
      guessing. For `suggest:copilot`, there is no rename to make: re-express
      the intent by re-labelling each issue with whichever family it actually
      meant, or drop the label, rather than mechanically renaming a harness
      name into a family slot it never occupied.

      **If the destination already exists** — a `setup-github-labels` re-run
      already created `suggest:gpt`/`claim:mai` before this cleanup runs —
      `gh label edit` is rejected the same way; use the **destination-collision
      procedure from the `agent:*` item above** (add the new label to every
      issue/PR carrying the old one, remove the old, then delete the old label
      once empty) instead of trying to rename over it. Check for in-flight
      claims first — `gh issue list --label claim:codex --state all --limit
      1000` **and** `gh pr list --label claim:codex --state all --limit
      1000` (repeat for `claim:copilot`, remembering the broker caution above
      governs what you rename it to) — and settle or amend any that name the
      old label before renaming it out from under them. Re-run the
      enumeration above afterwards — it should return nothing.

      **Also check for model-level labels naming the old family** —
      `suggest:codex:<model>` / `claim:codex:<model>` /
      `suggest:copilot:<model>` / `claim:copilot:<model>` (`suggest:codex:sol`,
      `claim:copilot:code-1-flash`, …). Those are created on demand rather than
      seeded, so the same paged-listing gap applies — enumerate with the
      family prefix: `gh label list --repo <owner/repo> --limit 1000 --json
      name --jq '.[].name' | grep -E '^(suggest|claim):(codex|copilot):'`.
      Rename each `codex:<model>` label the same fixed-mapping way,
      **preserving its model suffix** (`suggest:codex:sol` →
      `suggest:gpt:sol` — the model slug is unchanged, only the family
      segment moves), and run the same in-flight-claim check per label before
      renaming it (`gh issue list --label suggest:codex:sol --state all
      --limit 1000` / `gh pr list --label suggest:codex:sol --state all
      --limit 1000`, one pair per label found). **`copilot:<model>` labels get
      the same broker treatment as the family-level ones above** — determine
      the actual family per label from its claim/session record and rename
      preserving the suffix (`claim:copilot:code-1-flash` →
      `claim:<actual-family>:code-1-flash`), or remove/re-express rather than
      assume `mai`. **Collisions use the same destination-collision procedure
      too** — a model-level label can already exist for the same reason a
      family-level one can (an on-demand `suggest:gpt:sol` created before this
      cleanup ran) — migrate associations from `suggest:codex:sol` to
      `suggest:gpt:sol` and delete `suggest:codex:sol` once it carries no
      issues or PRs, rather than renaming over the existing one. Re-run the
      `grep` above afterwards — it should return nothing.
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
