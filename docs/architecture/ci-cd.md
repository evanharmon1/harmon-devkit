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
- `claude-plan` / `claude-implement` / `claude-review` — `@claude …` on issues and PRs.
- `devcontainer-build.yml` — prebuilds the devcontainer images to GHCR on `.devcontainer/**` changes.
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
so the `CI_RUNS_ON` repository variable can move CI to different runners without
a commit.

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
