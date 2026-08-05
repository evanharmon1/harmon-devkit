# Troubleshooting

Common issues in Harmon DevKit and how to fix them.

## Git hooks

- **"lefthook is not installed" on commit** — run `task install:hooks` (or `task install`).
- **Hook failures** — never bypass with `--no-verify`; run `task fix` and re-stage.

## Devcontainer

- **Stale tools after a Dockerfile change** — rebuild the container; prebuilt images come from GHCR (see `.github/workflows/devcontainer-build.yml`).
- **Missing secrets in the container** — locally, the env-file is provided by a **1Password environment** mounted at `.devcontainer/devcontainer.env` (see [devcontainers.md](devcontainers.md)); on Coder/Codespaces it's seeded from host/workspace env by `.devcontainer/scripts/init-env.sh`. Note `init-env.sh` does **not** call `op` — if values are missing locally, check the 1Password environment is authorized and mounted at the right path.
- **Boxes, blank gaps, or run-together segments in the shell prompt** — the starship prompt is a powerline theme built on Nerd Font glyphs, and fonts are **client-side**: the container emits the codepoints, your terminal draws them. Install a Nerd Font on the machine running the terminal and point it at that font (`terminal.integrated.fontFamily` in VS Code, or your terminal's own font setting). The devcontainer deliberately does *not* set that for you — devcontainer settings land at VS Code's Remote scope and would override a Nerd Font you already have under a different name.
- **"unknown terminal type" / broken keys in `vim`, `less`, or `htop`** — you are running Ghostty (`TERM=xterm-ghostty`) somewhere that lacks that terminfo entry. The container itself has it; a remote host over SSH, or another container you `docker exec` into, does not — see [Terminal type](devcontainers.md#terminal-type-and-ghostty-terminfo).
## CI

- **Required check missing on a PR** — ensure Build & Validate ran;
  required checks are `verify`, `security`.

## Deeper devcontainer failures

The above are the everyday cases. For failures already hit and diagnosed in
this devcontainer — a `postCreateCommand` abort silently cancelling every
later lifecycle command, Claude Code re-prompting for login after each
rebuild, a recreated Coder workspace reusing stale volumes — see
[devcontainer-incidents.md](devcontainer-incidents.md).

TODO: add project-specific issues as they come up.
