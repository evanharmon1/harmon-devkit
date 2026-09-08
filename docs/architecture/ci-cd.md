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

## Authentication

CI workflows authenticate as the **`evanharmon1-ci` GitHub App** (short-lived
tokens minted at runtime), not a PAT — see [security.md](security.md).
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
