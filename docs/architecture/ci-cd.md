# CI/CD

How continuous integration and delivery are wired in Harmon DevKit. Every
job delegates to `task` targets, so local hooks, CI, and humans run identical
commands (the Taskfile is the single source of truth).

## Quality gate

The pipeline runs `check → build → validate → test → security` (see
[../conventions.md](../conventions.md)). `build.yml` runs these as parallel jobs
plus an aggregate **`verify`** job; branch protection requires `verify` +
`security` to pass before a PR can merge to `main`.

## Workflows

- `build.yml` — on push/PR to `main`: lint, security, then the aggregate **`verify`** job. Security always runs gitleaks + dependency audit + Semgrep CE SAST.
  Its `pull_request:` trigger is `[opened, synchronize, reopened]`.
  **`edited` is deliberately absent**: it fires on a title/body edit, and the
  dev loop's readiness gate *requires* body edits to tick
  `## Deferred findings` — so carrying it here made settling a finding restart
  the whole matrix at the last step before promotion. `edited` also covers a
  base-**branch** change; losing that re-run is accepted, because retargeting a
  PR is rare and a strict required-status-checks policy forces an up-to-date
  head before merge, which arrives as a `synchronize`.
  **One list, not two**: the `test-suite` job runs a single `task test:suite`
  step — the Taskfile's aggregate of every shared `test:*` target `task verify`
  runs. It has its own runner and 30-minute budget; `lint` runs `check`, the
  instruction audit, the parity guard, and validation in parallel with it.
  The required `verify` aggregate checks both jobs, along with the project test
  jobs and security. Fork PRs skip all repository-controlled jobs and the
  trusted aggregate verifies those deliberate skips.
  `task test:verify-ci-parity` — itself in the suite, and also its own `lint`
  step so deleting the suite step cannot silence it — fails if the suite stops
  feeding `verify`, if local `verify` stops running it, or if local `verify`
  lists a shared `test:*` target directly. Existing consumers that run the
  suite inside `lint` retain support.

- `closing-keywords.yml` — the metadata-only gate that refuses a same-repo
  `Closes #N` while `#N` has unchecked task-list items. It lives in its own
  workflow precisely so it can keep `pull_request.edited`: it reads the PR
  title and body, so a body edit genuinely changes its input. `closing-keywords`
  is a required status check in its own right, keyed by the job id — keep that
  id stable. `task guard:closing-keywords` is the local pre-flight
  (`scripts/guard-closing-keywords.sh`).
- `claude-plan` / `claude-implement` / `claude-review` — **mention-only**: an
  explicit `@claude` mention naming `plan`, `implement`, or `review` in a
  comment or review from a sender on the `claude_authorized_members` allowlist. There is no
  label trigger and no open/assign trigger; the retired `claude-plan`,
  `claude-implement`, and `claude-review` labels are gone, because a label or an
  assignment carries no actor the allowlist can check on every path. Each run
  applies `claim:claude` to the target once the sender gate passes and removes it
  in an `always()` cleanup step, which covers the failure, step-timeout and
  cancellation paths. It is not a guarantee: a release whose DELETE fails leaves
  the marker in place and turns the job **red** on purpose (a masked failure
  would be permanent, since the next run reads the surviving claim and refuses),
  and runner loss, a force-cancel, or the job cap firing can strand the label
  with no cleanup at all. A stranded `claim:claude` blocks further mentions on
  that target until someone removes it by hand.
- `snyk-scheduled.yml` — optional weekly Snyk Code + Open
  Source second-opinion scans. It has schedule/manual triggers only, consumes no
  PR checks, and is not part of branch protection. See
  [security.md](security.md) for quota guidance.
- `devcontainer-build.yml` — prebuilds the devcontainer images to GHCR and
  aggregates into the **required** `devcontainer-verify` status check. Like
  `verify`, it carries **no workflow-level `paths:`
  filter** — a filtered workflow never reports on an unrelated PR, and a
  required check that never reports blocks the merge forever — so a
  `devcontainer-changes` job decides internally whether the expensive `build`
  and `devcontainer-assert-bot` jobs need to run, and a docs-only PR gets a
  passing `devcontainer-verify` without either one building. Its
  `devcontainer-assert-bot` job starts a real bot container
  (`scripts/devcontainer-smoke.sh`, sharing the build job's registry cache)
  and runs `bot-autonomy.sh verify` inside it via `docker exec`, so the
  fail-closed, non-interactive policy every installed harness is supposed to
  run under (see [security.md](security.md)) is checked against the built
  image, not just its source files. This container-assertion step is a
  **CI-only** check, deliberately absent from the local `task ci` mirror:
  `scripts/devcontainer-smoke.sh` has no graceful skip (it falls back to `npx
  @devcontainers/cli` rather than a no-op when the CLI is absent, fails hard
  without a reachable Docker daemon, and refuses outright from a linked git
  worktree). `task test:devcontainer:root` remains the separate, manually
  invoked local equivalent. The fail-closed guarantee is independently
  satisfied by `apply`/`verify` failing container creation or start directly,
  regardless of any CI signal; this job is a second, PR-visible one on top,
  now a required one. A fork pull request touching `.devcontainer/**` still
  passes `devcontainer-verify` vacuously (every repository-controlled job is
  skipped at the fork trust boundary). `merge_group` builds run in a
  dedicated `build-merge-group` job whose own `permissions:` grant no
  `packages` scope at all, bounding what unreviewed devcontainer content
  can do (the actual enforcement is `require_code_owner_review`, which
  covers this workflow file too — see branch-protection.md), and jobs that
  run on `merge_group` are pinned to a GitHub-hosted runner regardless of
  `CI_RUNS_ON`. `devcontainer-assert-bot` stands down entirely there
  instead, because its registry cache cannot go credential-free per event —
  see [branch-protection.md](branch-protection.md) for the fork-PR trusted-rerun
  runbook and the merge_group carve-out.
- `claim-release.yml` — on `issues closed`, on `pull_request closed`
  **unmerged**, and on `pull_request` **merged into the default branch**
  (releasing the branch-bound claim of a partial `Refs` PR whose issue
  correctly stays open, via `scripts/claim-release-merged.sh`),
  releases the claim markers an agent session left on an issue
  (assignee, `claim:*` label — or a legacy `agent:*` one, both of which
  `release-claim.sh` accepts — and the `Claiming —` comment's supersede). It
  holds `issues: write` and parses attacker-writable comment bodies, so it
  always checks out the **default branch** and never a PR head. It only wires
  events to `release-claim.sh` in the vendored `track-work` skill, so it
  no-ops until you have run `task sync:skills`.
- `release.yml` — release-please maintains the rolling release PR.

## Issue classification reconciler

Two workflows keep each open issue's derived Tier (`tier:<value>`) and
`needs-triage` current. They implement the "Reconcile drift" half of
[ADR 2026-09-30](https://github.com/evanharmon1/harmon-init/blob/main/docs/decisions/2026-09-30-classify-issues-by-impact-risk-complexity-and-derive-the-tier.md)
D4 and D6, as amended by
[ADR 2026-10-01](https://github.com/evanharmon1/harmon-init/blob/main/docs/decisions/2026-10-01-store-the-tier-as-a-label-on-every-owner-type.md),
under which the Tier is a label on every owner type. The logic lives in
`scripts/classification-reconcile.mjs`, and `task test:classification-reconcile`
tests it hermetically. Both workflows are generated when
`project_management == 'github'`.

- **`classification-reconcile.yml`** walks open issues, reads Impact, Risk and
  Complexity in both storage shapes, and writes the Tier and `needs-triage`.
  Impact, Risk and Complexity are organization issue fields (a field wins over
  a same-axis label) or `impact:*`/`risk:*`/`complexity:*` labels. It derives
  the Tier with the policy reader's `deriveTier` over the repository's own
  `.devflow.toml` `[tier.matrix]` and never re-implements the matrix. Its
  triggers are `schedule`, `workflow_dispatch` (optionally a dry run), and
  `workflow_call`.
- **`classification-event.yml`** re-derives one issue when a human changes an
  input in the GitHub UI. It triggers on `issues` `opened, labeled, unlabeled,
  typed, untyped` and calls the reconcile workflow for that issue.

**Ownership.** This workflow pair is the only automated writer of the Tier
besides the skills (triage, track-work, breakdown), which set the Tier and
`needs-triage` in the same write that sets Risk or Complexity, and the opt-in
organization workflow ("Organization-wide walk" below), which runs the same
script with the CI App installation token and writes the same two labels
under the same rules. The reconciler writes only `tier:<value>` and
`needs-triage`, under `GITHUB_TOKEN` with `issues: write` (the organization
workflow under the App token). It never writes over an issue carrying
`tier:pinned` (it still maintains `needs-triage` there). It never writes
`tier:pinned`, `priority:*`, `priority-ai:*`, `rigor:*`, `strategy:*` or
`claim:*`.

The reconciler reports these cases and leaves the Tier, and the offending
input, as it is. `needs-triage` is still maintained unless an item says
otherwise:

- A pinned issue with two or more tier values (it never picks one), or with
  none.
- An unpinned Tier whose Risk or Complexity is missing (`cache-unverifiable`).
  Derive-on-read ignores that label anyway.
- A leftover `tier:adaptive`. The label is left for its migration (#1447);
  the derived Tier is still written beside it.
- A conflicted axis (two values, or two Type-bearing work-type labels
  without a native Type), or a retired or unknown value. A work-type label is
  Type-bearing when it is non-retired and its registry writers (its own, else
  its family's) include a human or agent writer; one written only by a tool,
  such as Renovate's `dependencies`, is never a Type. That axis
  does not count toward "triaged", so `needs-triage` stays. Recognized values
  come from the repository's `label-registry.json`; when that file is
  unreadable, every axis is unverifiable: `needs-triage` is left as it is and
  no Tier is written.
- An issue whose labels or field values span more than one page. It is
  skipped entirely, `needs-triage` included, rather than decided on a partial
  read.
- A repository whose reader cannot derive. Either the reader has no
  `deriveTier`, which is every repository whose vendored `dev-flow-support`
  predates [harmon-devkit#1248](https://github.com/evanharmon1/harmon-devkit/issues/1248), or the reader throws on the policy. Such a
  repository still gets `needs-triage` maintained, and the job never fails on
  an old reader.

**Event filter and the pin race.** Every `issues` event creates a run, but a
job whose `if` is false is skipped before a runner is assigned, and a skipped
job bills nothing. The event job starts only when all three hold:

- the sender is not a `Bot`;
- the sender is not listed in **`CLASSIFICATION_AGENT_LOGINS`**, a repository
  or organization variable holding a JSON array of agent logins (unset reads
  as an empty list);
- the event changed an input: an issue was opened, typed or untyped, or a
  `risk:`, `complexity:`, `impact:`, `area:`, `layer:`, `domain:` or
  work-type label was added or removed.

`tier:*` (including `tier:pinned`) and `needs-triage` are never inputs. A
human pins with two UI edits in either order (set the Tier label, add
`tier:pinned`), so a Tier or pin edit never starts a job and cannot be
overwritten mid-pin.

The remaining windows are narrow:

- A pin made while a job is already writing. Every Tier write is preceded by
  a read, made after the previous write, that shows no `tier:pinned`. On a pin
  the job stops its remaining Tier writes and reports the issue
  (`pin-appeared`). GitHub's label API has no compare-and-swap, so one round
  trip between that read and its write is the irreducible residual.
  `needs-triage` writes are not guarded, since it is maintained on pinned
  issues too.
- A scheduled run landing between the two pin edits. With the pin added first,
  it sees two tier values and reports them. With the Tier set first, it
  re-derives once, and the human's pin then restores the intended value.

After its Tier writes the job re-reads the issue once. Unpinned, the issue
must carry exactly one rung, the Tier derived from its inputs on that read.
A failed delete or a concurrent run's write breaks that, so one bounded repair
pass runs under the same pin guard; an issue still not exclusive after it is
reported (`tier-not-exclusive`) and fails the run. So does a guard or verify
read that spans more than one page (`pin-guard-indeterminate`), since it can
rule out neither a pin nor a second rung, and so does an API error the repair
does not heal, or any API error outside the Tier writes. A Tier write error
the repair heals is reported (`write-failed`) but is not a failure, and nor is
a pin that stops the Tier writes. Either way the walk moves on to the next
issue, and the run exits 1 after the whole list.

Every write, Tier or `needs-triage`, is decided from the most recent read of
the issue: `needs-triage` from the verify read when Tier writes happened,
otherwise from the read taken just before writing. The same one round trip
between that read and its write is the irreducible residual.

Label writes made with `GITHUB_TOKEN` start no workflow runs, so the
reconciler's own writes never re-trigger the event workflow. `edited` is
deliberately absent. `field_added`/`field_removed` are absent until actionlint
recognizes them ([harmon-init#1485](https://github.com/evanharmon1/harmon-init/issues/1485)),
so an organization repository's field edits are repaired by the schedule, not
instantly.

**Caller wiring.** `GITHUB_TOKEN` is repository-scoped, so each repository
runs the reconcile on its own schedule and walks only its own issues. The
schedule is **monthly** on an organization repository and **daily** on a
personal-account one, rendered from the owner type. The reconcile workflow's
`workflow_call` is for the repository's own `classification-event.yml`; a
call from another repository is not supported, because the job checks out
the calling repository and runs the script from there. The `use-token` and
`repositories` inputs and the `CLASSIFICATION_TOKEN` secret that v4.49.0
shipped for such calls are removed; an organization-wide walk is the
standalone workflow below.

The reconcile workflow always uses `GITHUB_TOKEN`. It declares no token input
and no secret, so no stored, long-lived token reaches it, whatever secrets the
repository or organization holds (no PAT, no stored secret).

**Organization-wide walk.** An organization that wants a daily walk of all its
repositories adds one standalone workflow to a private repository of the
organization (opt-in;
[harmon-init#1463](https://github.com/evanharmon1/harmon-init/issues/1463)).
Host it in a private repository, because a public repository's run logs and
job summaries would publish each walked private repository's issue numbers
and label changes; that is `<org>/.github` only when it is private.
It is an ordinary workflow that runs in the organization, not a call into
another repository's reusable workflow: a job that calls a reusable workflow
runs no steps, and GitHub redacts a job output that carries a secret, so a
token minted beside such a call could never reach the called workflow. The
hosting repository needs this one file and nothing else: no script, no
policy reader, no `label-registry.json` and no `.devflow.toml`. Its one job
mints an installation token from the CI GitHub App that already exists (the
same App `claude-*.yml` and `release.yml` use), checks out the repository that
carries the reconciler script, and runs the script, so the token is minted and
used in the same job:

```yaml
# A private repository of <org>: .github/workflows/org-classification-reconcile.yml
name: Classification Reconcile (organization)

on:
  schedule:
    - cron: "17 6 * * *"

permissions:
  contents: read

jobs:
  reconcile:
    runs-on: ubuntu-latest
    timeout-minutes: 15
    steps:
      - id: app-token
        uses: actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1 # v3.2.0
        with:
          client-id: ${{ vars.CI_APP_CLIENT_ID }}
          private-key: ${{ secrets.CI_APP_PRIVATE_KEY }}
          owner: ${{ github.repository_owner }}
          repositories: |
            <repository-a>
            <repository-b>
          permission-contents: read
          permission-issues: write
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          repository: <owner>/<repo>
          ref: <full-commit-sha> # <release-tag>
          persist-credentials: false
      - uses: actions/setup-node@820762786026740c76f36085b0efc47a31fe5020 # v7.0.0
        with:
          node-version: "24"
      - name: Reconcile Tier and needs-triage
        env:
          GH_TOKEN: ${{ steps.app-token.outputs.token }}
          RECONCILE_REPOSITORIES: >-
            <org>/<repository-a>
            <org>/<repository-b>
          RECONCILE_CALLER_CHECKOUT: "false"
        run: node scripts/classification-reconcile.mjs
```

- **The trigger.** A schedule only, with no `workflow_dispatch`: GitHub runs
  the selected ref's workflow definition, so an unreviewed branch could
  rewrite the token-minting step.
- **The token.** The App needs Issues: write and Contents: read on every
  listed repository. `repositories:` limits where the token reaches, to the
  listed repositories (bare names under `owner`, the same ones
  `RECONCILE_REPOSITORIES` names as `owner/name`), and the `permission-*`
  inputs limit what it may do there. It is used only by the reconcile step.
  `vars.CI_APP_CLIENT_ID` and `secrets.CI_APP_PRIVATE_KEY` must be visible to
  the hosting repository (an organization variable and secret whose access
  list includes it, or repository-level copies); `repositories:` and the
  `permission-*` inputs limit the minted token, not the key.
- **The script's source.** `<owner>/<repo>` is the repository that carries
  `scripts/classification-reconcile.mjs` and its policy reader. It is checked
  out with the run's own `GITHUB_TOKEN`, no secret and no persisted
  credentials, so it must be public or otherwise readable without one. Pin it
  by full commit SHA with the release tag as a trailing comment: a tag follows
  wherever it is moved, so a workflow that uses one trusts whoever can move it.
  Nothing bumps that `ref:` automatically, because Renovate updates `uses:`
  lines, not a `with: ref:`. Move it whenever the organization takes a new
  release of `<owner>/<repo>`, so the daily walk and each repository's own
  runs use the same script, and take the SHA from the tag in that repository,
  for example `gh api repos/<owner>/<repo>/commits/vX.Y.Z --jq .sha`: a SHA
  copied from elsewhere can name a commit that exists only in a fork.
- **The foreign checkout.** `RECONCILE_CALLER_CHECKOUT: "false"` tells the
  script that the checkout is not the repository it runs in. It then treats
  no walked repository as the checkout, reads every listed repository's
  `label-registry.json` and `.devflow.toml` through the contents API, and
  refuses an empty `RECONCILE_REPOSITORIES` with one error before any API
  call, so the hosting repository is walked only when it is listed. Run it
  from the root of its checkout (no `path:` on the checkout step): it finds
  its policy reader relative to the working directory, and run from
  elsewhere it derives no Tier and still exits 0.
- **Loops.** Label writes made with the App token do start workflow runs,
  unlike `GITHUB_TOKEN`'s, but their sender is a `Bot`, so each repository's
  event job is skipped (see "Event filter and the pin race").

A repository is only ever judged by its own registry and its own policy. A
repository running its own copy uses its checkout; every repository of the
organization walk, and any other repository in a list, has its
`label-registry.json` and `.devflow.toml` read from its default branch
through the contents API, which is why the token needs Contents: read there.
A registry it cannot read makes every axis unverifiable there (no
`needs-triage` change), and a policy or matrix it cannot read makes the Tier
not derivable there (no Tier write); each is reported once per repository.
The reader code is always the checkout's: it is the function, not the policy.

**Minutes model.** On a paid organization plan the Actions minutes are a
shared pool and private repositories bill them; public repositories run free.
A job bills at least one full minute, and GitHub emits one `labeled` event per
label. Expected monthly cost:

| Source | Estimate |
|---|---|
| Monthly schedule, organization repository | ≈ 1 min per private repository |
| Daily schedule, personal-account repository | ≈ 30 min per private repository, from the account's own quota |
| Event jobs | ≈ 2 min per issue whose inputs a human or an unlisted agent changes (a burst of label events on one issue collapses to at most two jobs through the per-issue concurrency group) |
| Opt-in daily organization workflow | ≈ 30 min per organization |

Agent sessions that write under a human's own login look human to the filter,
which is the main event cost. Agents with a login of their own belong in
`CLASSIFICATION_AGENT_LOGINS`.

## Authentication

CI workflows authenticate as the **`evanharmon1-ci` GitHub App** (short-lived
tokens minted at runtime), not a PAT — see [security.md](security.md).
The classification reconciler is the exception: it runs on the
repository-scoped `GITHUB_TOKEN` with `issues: write` (see
[Issue classification reconciler](#issue-classification-reconciler)), and an
organization-wide walk mints an App installation token in its own job and
pins its script's source by a `ref:` that Renovate does not bump.
Third-party actions are pinned by commit SHA and bumped by Renovate.

## Releases

release-please opens a rolling release PR from conventional commits; merging it
cuts the tag, GitHub release, and CHANGELOG. Nothing auto-releases on a normal
merge.

TODO: document deployment targets/environments here once they exist; the deploy
how-to lives at [../guides/deploying.md](../guides/deploying.md).

## Runners

Jobs use `runs-on: ${{ fromJSON(vars.CI_RUNS_ON || '"ubuntu-latest"') }}`,
so the `CI_RUNS_ON` variable dynamically controls runner placement without
requiring a commit or template re-render.

### Job-private filesystem contract

CI may run on persistent self-hosted runners. Only `$GITHUB_WORKSPACE` and
`$RUNNER_TEMP` are treated as job-private; the runner empties `$RUNNER_TEMP`
for each job, while files elsewhere can survive and affect another job or
repository. Package-manager and tool-cache setup must not write global
configuration (`pnpm`/`npm`/`yarn config`, `~/.npmrc`, or
`~/.config/<tool>`), pass a persistent store override, or construct a
supposedly private store path from `$GITHUB_WORKSPACE/..`. The shared setup
action therefore puts pnpm's store under `${RUNNER_TEMP}/.pnpm-store` through
a job-scoped environment variable.

Global Git identity and `safe.directory` settings are explicit exceptions.
Workflows set only deterministic, non-secret values needed by the current job;
they do not redirect a mutable package cache, and they disappear with a
recreated runner rather than becoming repository state.

### Variable hierarchy and precedence

Runner selection resolves hierarchically via GitHub Actions variables:

1. **Repository variable (`vars.CI_RUNS_ON`)**: An individual repository can set
   `CI_RUNS_ON` (via `task setup:github` or `gh variable set CI_RUNS_ON --repo`).
   In GitHub Actions, repository variables shadow organization variables of the
   same name. This allows a repository to override an organization default (for
   example, to opt into specialized hardware or pin a specific repository to
   `"ubuntu-latest"`).
2. **Organization variable (`vars.CI_RUNS_ON`)**: Organizations across the platform
   (`ponderousdev`, `harmonops`, `sommerlawn`) define an organization-level
   `CI_RUNS_ON` variable scoped via `selected` visibility to audited private
   repositories (such as `["self-hosted","linux","x64","ponderousdev"]` or
   `["self-hosted","linux","x64","harmonops","contraption"]`). All audited member
   repositories inherit this fleet routing unless explicitly overridden at the
   repository level.
3. **Workflow fallback (`"ubuntu-latest"`)**: If neither a repository
   variable nor an organization variable is defined or accessible, the workflow
   expression cleanly falls back to the render-time default `ci_runs_on_default`
   (typically `"ubuntu-latest"` or the initial self-hosted label set).

### Reconciliation and lifecycle

`task setup:github` creates this variable when it is missing and preserves every
existing value on non-public repositories; it never infers ownership from a JSON
shape. An intentional replacement requires `scripts/setup-github.sh` with
`--replace-ci-runs-on`. Public repositories are the safety exception and are
always canonicalized to `"ubuntu-latest"` directly at the repository variable layer,
ensuring public projects explicitly declare GitHub-hosted execution while retaining
the workflow fallback.

### Security boundaries

That convenience is also the risk: it is a runtime change with no diff and no
review. **Do not point a public repository at a persistent self-hosted runner.**
The generated workflows already refuse to check out fork-controlled code on the
trusted aggregate job, but that contract bounds one specific job — it does not
make a long-lived runner safe for untrusted contributions generally. A fork PR
that can execute anything on a persistent runner can read its filesystem, its
credentials, and whatever the previous job left behind.

Before setting `CI_RUNS_ON` to a self-hosted value, audit every workflow for
`pull_request_target` and for any step that runs code from the PR head. Keep
untrusted-contribution workflows on GitHub-hosted runners.
