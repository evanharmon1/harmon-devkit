# Brewfile for Harmon DevKit
# Install with: task install  (brew bundle --file=Brewfile)
#
# Base-OS prerequisite, deliberately not a brew entry: `file(1)`, which
# scripts/lint-hygiene.sh requires. macOS ships /usr/bin/file and every
# mainstream Linux distro installs it in the base system, so a brew formula
# would shadow the system binary to no benefit. CI provisions it explicitly via
# scripts/ensure-file.sh; if it is somehow absent locally, lint-hygiene.sh says
# so by name and exits rather than misreporting binaries as text.

# Task runner + git hooks
brew "go-task"
brew "lefthook"

# Git / GitHub
brew "git"
brew "gh"
brew "git-delta"

# Lint / format
brew "shellcheck"
brew "shfmt"
brew "actionlint"
brew "yamllint"
brew "markdownlint-cli2"

# Security
brew "gitleaks"

# Runtime for commitlint and pinned npx fallbacks
brew "node"
# Python tool runner (Semgrep CE use uv/uvx)
brew "uv"

# Universal scripts parse JSON/TOML and require Python 3.11+
brew "python"

# Devcontainer
brew "hadolint"
brew "devcontainer"

# Skills tooling tests parse manifests and render tiny local Copier templates
# even though this source repo intentionally does not vendor its own skills.
brew "copier"
brew "yq"

# Utilities
# coreutils provides `timeout`, which stock macOS lacks — scripts/status.sh
# bounds its network probes with it.
brew "coreutils"
brew "direnv"
brew "jq"
brew "fzf"
brew "fd"
brew "ripgrep"
brew "bat"
brew "tokei"
brew "gum"          # status dashboard rendering (scripts/status.sh)
brew "television"   # interactive task menu (`task` / task menu-tv → tv)

# Second-model review (task challenge / task review drive the Codex CLI).
# Cask = macOS only; on Linux/devcontainers install with
# `npm install -g @openai/codex` (a bare cask line would abort `brew bundle`
# on Linux before any of the remaining deps install).
cask "codex" if OS.mac?

# macOS apps
cask "bunch"
