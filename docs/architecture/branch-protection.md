# Branch Protection: Protecting `main` from AI Agents

## Purpose

This document explains the branch protection ruleset applied to `main` and how it ensures that AI coding agents (e.g., Claude Code running in a dev container) cannot push to or merge into `main` without explicit human approval. The ruleset works in combination with a dedicated machine user account (`evanharmon1-bot`) that has Write collaborator access and a scoped fine-grained PAT.

## Applying the Ruleset

An importable copy of the ruleset ships in this repo at
`.github/Branch Protection Ruleset - Protect Main.json`. Apply it through the
GitHub **UI import** (do this once `build.yml` is on `main`, so the required
`verify`/`security` checks resolve):

> Settings → Rules → Rulesets → **New ruleset ▸ Import a ruleset** → select
> `.github/Branch Protection Ruleset - Protect Main.json`.

To change the ruleset later, **edit the existing one in the UI** (Settings →
Rules → Rulesets → Protect Main) — don't re-import.

**Why the UI for a one-time import:** a blind REST `POST` is **not idempotent**
(every run creates another "Protect Main" ruleset — silent duplicates). The
[REST ruleset API](https://docs.github.com/en/rest/repos/rules?apiVersion=2022-11-28)
now supports `merge_queue`, but safe automation must first discover exactly one
matching live ruleset and then `PUT` its id. The UI import keeps the initial
application explicit and reviewable; edit the existing ruleset thereafter.

## Dependabot and Renovate

Routine updates and vulnerability-remediation PRs are owned by **Renovate**
(`renovate.json`, with `vulnerabilityAlerts.enabled=true`) — do not add a
`dependabot.yml`, which would create competing update PRs. Dependabot still owns
the GitHub-native advisory feed; enable these in Settings → Advanced Security:

- Dependabot alerts
- Private vulnerability reporting (used by `.github/SECURITY.md`)

## Security Model Overview

Three independent layers enforce the boundary between AI agent work and production code:

1. **Fine-grained PAT** — Scoped to `contents: write` and `pull_requests: write` on specific repos. This is the token the AI agent uses in the dev container. It cannot modify repo settings, branch protection, or workflows.
2. **Repository ruleset on `main`** — Server-side enforcement that blocks direct pushes, requires PR reviews from a code owner, and mandates passing status checks before merge.
3. **CODEOWNERS file** — Designates the human owner as the required reviewer for all file changes, ensuring the bot's PRs always require human approval.

No single layer is sufficient alone. The PAT controls _what operations the token can attempt_. The ruleset controls _what operations GitHub allows on `main`_. The CODEOWNERS file controls _whose approval counts_.

## Prerequisites

### CODEOWNERS File

The `require_code_owner_review` rule in the ruleset **only works if a `CODEOWNERS` file exists** in the repo. Without it, the rule is silently unenforced. Create one at the repo root or `.github/CODEOWNERS`:

```text
# All files require the repo owner's approval
* @evanharmon1
```

Replace `@evanharmon1` with the GitHub username of the human who should approve all changes.

### Bot Account PAT Permissions

> This covers the **devcontainer agent's** push token (Claude Code running in the
> container). CI _workflows_ (release-please, claude-*, project-automation)
> authenticate separately as the CI **GitHub App** — see
> [security.md](security.md) for that App and its permissions. The ruleset below
> protects `main` from every actor (App, bot PAT, or human) equally.

The machine user account's fine-grained PAT should have these **repository**
permissions and nothing more:

| Permission      | Level          | Purpose                                               |
| --------------- | -------------- | ----------------------------------------------------- |
| Contents        | Read and write | Clone, push, create branches, commit                  |
| Issues          | Read and write | Read the issue graph; apply labels; post comments     |
| Pull requests   | Read and write | Open PRs, update PRs, comment                         |
| Metadata        | Read-only      | Mandatory — granted to every fine-grained PAT         |
| Actions         | Read-only      | Read workflow run status (red-CI triage)              |
| Commit statuses | Read-only      | Read the PR status rollup                             |
| Variables       | Read-only      | Read CI configuration when reasoning about a workflow |

> **There is no `Checks` permission for fine-grained PATs.** Only GitHub Apps can
> hold it — it was briefly offered, then withdrawn. Don't go looking for it: CI
> state comes from **Actions** (workflow runs) and **Commit statuses** (the PR
> rollup), which is what the tooling actually reads.
**Read is cheap; write is the line.** Variables and Projects are read-only above
for a reason that is not squeamishness — see the exclusions below.

**Deliberately excluded.** This list is _what the bot needs_, and the distinction
is load-bearing, because the bot's PAT is the **agent's own credential**:
anything running in the bot devcontainer can read it out of the environment.
Every permission here is one a prompt-injected agent has.

| Not granted | Why |
| --- | --- |
| **Workflows** | The agent could rewrite `.github/workflows/`, then let CI run it with every Actions secret. The classic escalation. |
| **Administration** | Rulesets, settings, bypass lists. The bot must not be able to unlock the door it is locked behind. |
| **Variables — write** | Read is granted; write is not. Write could opt a private repo into paid CodeQL or mutate another security/deploy switch without a PR diff. Public CodeQL cannot be disabled with `FULL_SECURITY_SCAN`. |
| **Deployments** | Write lets the agent create deployments, colliding with release-gated deploys. Read buys nothing the agent's loop uses. |
| **Secrets**, **Environments**, **Webhooks**, … | Never needed; each is one more thing a leaked token reaches. |

Variables are **non-secret by design** — GitHub separates Secrets from Variables
precisely so config can be read without exposing credentials. That makes the read
grant above safe, and it depends on the separation being honoured: if a variable
ever holds something sensitive, read becomes exfiltration. Check once, when
adding a variable — not forever.

Grant on demand, with a reason. You can edit a fine-grained PAT's permissions
later without regenerating the token, so there is no cost to waiting until
something is genuinely blocked.

## Ruleset Configuration

This mirrors the importable
`.github/Branch Protection Ruleset - Protect Main.json` — keep the two in sync.

```json
{
  "name": "Protect Main",
  "target": "branch",
  "source_type": "Repository",
  "source": "evanharmon1/harmon-devkit",
  "enforcement": "active",
  "conditions": {
    "ref_name": {
      "include": ["~DEFAULT_BRANCH", "refs/heads/main"],
      "exclude": []
    }
  },
  "rules": [
    {
      "type": "deletion"
    },
    {
      "type": "non_fast_forward"
    },
    {
      "type": "creation"
    },
    {
      "type": "required_linear_history"
    },
    {
      "type": "pull_request",
      "parameters": {
        "required_approving_review_count": 1,
        "dismiss_stale_reviews_on_push": true,
        "required_reviewers": [],
        "require_code_owner_review": true,
        "require_last_push_approval": true,
        "required_review_thread_resolution": true,
        "allowed_merge_methods": ["squash", "rebase"]
      }
    },
    {
      "type": "required_status_checks",
      "parameters": {
        "strict_required_status_checks_policy": true,
        "do_not_enforce_on_create": true,
        "required_status_checks": [
          {
            "context": "verify",
            "integration_id": 15368
          },
          {
            "context": "security",
            "integration_id": 15368
          }
        ]
      }
    }
  ],
  "bypass_actors": [
    {
      "actor_id": 5,
      "actor_type": "RepositoryRole",
      "bypass_mode": "pull_request"
    }
  ]
}
```

## Rule-by-Rule Explanation

### Target and Conditions

The ruleset targets branches matching `~DEFAULT_BRANCH` and `refs/heads/main`. The `~DEFAULT_BRANCH` is a GitHub alias that always resolves to whatever the repo's default branch is, so even if the default branch name changes, the ruleset follows. Including `refs/heads/main` explicitly is belt-and-suspenders.

### `bypass_actors`

> **Design intent — leave this `pull_request`, not `always`.** Every bypass actor is
> scoped to `bypass_mode: pull_request` on purpose: an admin may _merge_ a
> non-compliant PR (a solo maintainer's own PR, which GitHub won't let them
> self-approve, or a genuinely stuck check) but **cannot push directly to `main`**.
> Widening any bypass to `always` re-enables accidental (or malicious) direct pushes
> to `main` and is a real security loosening — only do it deliberately, and call it
> out in review. A bypass actor is required at all (rather than `bypass_actors: []`)
> because a solo maintainer otherwise can't merge anything; with multiple human
> reviewers you can drop the bypass entirely instead.

Only the **Repository admin** role (`RepositoryRole` id `5`) can bypass these rules,
and only in `pull_request` mode — you can **merge** a PR that hasn't met every
requirement (e.g. your own PR, which GitHub won't let you self-approve, or a stuck
check), but you **cannot push directly to `main`**: a direct push isn't a pull
request, so the bypass doesn't apply and the ruleset rejects it. This prevents
accidental `git push origin main` while still letting a solo maintainer merge. The
bot has only Write access (below Admin), so it can never bypass.

### `deletion`

Prevents deleting the `main` branch. Without this, anyone with write access could delete and recreate `main`, potentially losing branch protection in the process.

### `non_fast_forward`

Blocks force pushes (`git push --force`) to `main`. Force pushes rewrite history and can silently remove commits, including security fixes. This ensures `main`'s history is append-only.

### `creation`

Prevents creating a branch matching the pattern. Since `main` already exists, this blocks scenarios where someone deletes `main` and recreates it (bypassing protection that was on the original branch).

### `required_linear_history`

Enforces a linear commit history on `main` — no merge commits. Combined with `allowed_merge_methods: ["squash", "rebase"]`, this means every PR becomes either a single squashed commit or a rebased series of commits. This makes `git log` on `main` clean and easy to reason about, and simplifies `git bisect` for debugging.

### `pull_request`

This is the core rule that prevents the AI agent from pushing directly to `main`. All changes must come through a pull request. The parameters enforce multiple safeguards:

| Parameter                           | Value                  | Effect                                                                                                                                                                                                                        |
| ----------------------------------- | ---------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `required_approving_review_count`   | `1`                    | At least one approving review required before merge                                                                                                                                                                           |
| `require_code_owner_review`         | `true`                 | The approving review **must** come from a designated code owner (see CODEOWNERS file). A review from the bot or any non-code-owner does not satisfy this.                                                                     |
| `require_last_push_approval`        | `true`                 | The person who pushed the most recent commit cannot be the one to approve it. Since the bot pushes, the bot cannot self-approve — even if it could submit reviews. A human code owner must approve after the bot's last push. |
| `dismiss_stale_reviews_on_push`     | `true`                 | If the bot pushes new commits after a human approves, the approval is dismissed and the human must re-review. Prevents a pattern where the bot gets approval, then pushes different code and merges.                          |
| `required_review_thread_resolution` | `true`                 | All review comments must be resolved before merge. Prevents merging while a human reviewer still has open concerns.                                                                                                           |
| `allowed_merge_methods`             | `["squash", "rebase"]` | Only squash and rebase merges allowed. No merge commits, consistent with `required_linear_history`.                                                                                                                           |

### `required_status_checks`

All specified CI checks must pass before the PR can merge. The `strict_required_status_checks_policy: true` setting means the PR branch must be up-to-date with `main` before merging — if `main` advances after the checks ran, the checks must re-run. The `do_not_enforce_on_create: true` setting skips enforcement when the branch is first created (before any CI has had a chance to run).

The required checks are the build gates (see
[ci-cd.md](ci-cd.md)):

| Check      | Purpose                                                                                          |
| ---------- | ----------------------------------------------------------------------------------------------- |
| `verify`   | Aggregate gate — rolls up `lint`, and `security` so one check reports overall pass/fail |
| `security` | gitleaks + dependency audit; Semgrep CE when this job owns the visibility/profile SAST route |

Requiring the stable `verify` aggregate alongside the direct `security` context
keeps the required-check list small while preserving explicit security visibility.

Snyk PR/App checks are absent by default. Only a high-consequence repository that deliberately adopts
paid Snyk should consider per-PR scans and whether to make them merge
requirements. See [security.md](security.md) for the scanner policy.

## What the AI Agent Can and Cannot Do

| Operation                               | Allowed? | Enforced by                                     |
| --------------------------------------- | -------- | ----------------------------------------------- |
| Clone the repo                          | ✅       | PAT `contents: read`                            |
| Create feature branches                 | ✅       | No ruleset on non-main branches                 |
| Push commits to feature branches        | ✅       | PAT `contents: write` + no protection           |
| Open PRs targeting main                 | ✅       | PAT `pull_requests: write`                      |
| Update PRs with new commits             | ✅       | Push to PR source branch                        |
| View CI status on PRs                   | ✅       | PAT `actions: read`, `checks: read`             |
| Push directly to main                   | ❌       | `pull_request` rule requires PR                 |
| Self-approve its own PR                 | ❌       | `require_last_push_approval` blocks it          |
| Merge after non-code-owner approves     | ❌       | `require_code_owner_review` blocks it           |
| Merge after approval then push new code | ❌       | `dismiss_stale_reviews_on_push` resets approval |
| Force push to main                      | ❌       | `non_fast_forward` rule                         |
| Delete main                             | ❌       | `deletion` rule                                 |
| Modify branch protection rules          | ❌       | Write collaborator role has no settings access  |

## Applying This Ruleset to Other Repos

This ruleset ships with every repo generated from harmon-init. To replicate manually:

1. Create a `CODEOWNERS` file with `* @evanharmon1`
2. Create a branch ruleset targeting `~DEFAULT_BRANCH` with the same rules
3. Add the bot as a Write collaborator
4. Update the `required_status_checks` to match that repo's CI checks
5. Verify by attempting a direct push to main from the bot account — it should be rejected

For an organization with many repos, consider creating an **org-level ruleset** (requires GitHub Team plan) that applies these rules across all repos automatically, eliminating the need to configure each repo individually.

## Future Considerations

- **GitHub App for the devcontainer agent**: CI **workflows** already authenticate as the `evanharmon1-ci` GitHub App (short-lived 1h tokens, no seat cost — see [security.md](security.md)). The remaining machine-user PAT documented above is the **devcontainer agent's** push token; it could likewise move to an App if rotation becomes burdensome. The ruleset protects `main` identically for App tokens, the bot PAT, or any actor.
- **Terraform management**: The GitHub Terraform provider supports `github_repository_ruleset` resources. Codifying the ruleset in Terraform ensures consistency as repos multiply.
- **Additional status checks**: For `web-app` and `web-astro`, the `a11y` job
  (axe-core via Playwright) already ships **non-blocking** — promote it to the
  required list
  once real routes pass (add `a11y` to `verify.needs` + a `check a11y` line in
  `build.yml`, and to `required_status_checks`). As the pipeline matures,
  likewise add E2E (Playwright) and, where not already gating, Lighthouse CI.
