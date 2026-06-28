# Troubleshooting

Common issues in Harmon DevKit and how to fix them.

## Git hooks

- **"lefthook is not installed" on commit** — run `task install:hooks` (or `task install`).
- **Hook failures** — never bypass with `--no-verify`; run `task fix` and re-stage.

## Devcontainer

- **Stale tools after a Dockerfile change** — rebuild the container; prebuilt images come from GHCR (see `.github/workflows/devcontainer-build.yml`).
- **Missing secrets in the container** — locally, the env-file is provided by a **1Password environment** mounted at `.devcontainer/devcontainer.env` (see [devcontainers.md](devcontainers.md)); on Coder/Codespaces it's seeded from host/workspace env by `.devcontainer/scripts/init-env.sh`. Note `init-env.sh` does **not** call `op` — if values are missing locally, check the 1Password environment is authorized and mounted at the right path.

## CI

- **`verify` check missing on a PR** — ensure the Build & Validate workflow ran; required checks are `verify` and `security`.

TODO: add project-specific issues as they come up.
