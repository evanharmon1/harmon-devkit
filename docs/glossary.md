# Glossary

Term → one-line definition for the cross-cutting vocabulary of Harmon DevKit.
This is the **dictionary projection** of [the domain model](product/domain.md): it
points at the model for the real relationships and reasoning — it never restates
them. A flat lookup: scan for a term, don't read top-to-bottom.

Terms below are part of the harmon-init toolchain this repo is built on; add
project-specific (domain) terms as the model firms up.

| Term | Meaning |
|---|---|
| `verify` | The aggregate CI job in `build.yml` that rolls up the other jobs into one required status check (the merge gate). See [architecture/ci-cd.md](architecture/ci-cd.md). |
| `security` (check) | The required CI job running gitleaks + dependency audit, plus Semgrep CE when this job owns the SAST route. |
| `task` / Taskfile | go-task is the single source of truth for commands; lefthook hooks and CI both delegate to `task` targets so local and CI runs are identical. |
| release-please | Bot that maintains a rolling "release" PR from Conventional Commits; merging it cuts the tag, GitHub release, and CHANGELOG. Releases are intentional, never automatic on merge. |
| `evanharmon1-ci` (GitHub App) | The CI automation app that mints short-lived tokens for CI workflows (not a PAT). See [architecture/security.md](architecture/security.md). |
| bot profile / dev profile | The two devcontainer profiles: `bot` (`.devcontainer/`, AI agents, no Tailscale) and `dev` (`.devcontainer/dev/`, human, with Tailscale). See [guides/devcontainers.md](guides/devcontainers.md). |
| 1Password Environments | How devcontainer/local secrets are supplied — a virtual `.env` mounted over a pipe, never written to disk or git. |
| bot vs operator | Two identities: the AI **bot** account (scoped, can't merge `main`) and the human **operator** (full access). See [architecture/security.md](architecture/security.md). |
| TODO: term | TODO: project-specific definition |
