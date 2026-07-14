# Brewfile for Harmon DevKit
# Install with: task install  (brew bundle --file=Brewfile)

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
tap "snyk/tap"
brew "snyk/tap/snyk"

# Runtime for commitlint and pinned npx fallbacks
brew "node"

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
brew "coreutils"    # `timeout` portability (`gtimeout` on macOS)
brew "direnv"
brew "jq"
brew "fzf"
brew "fd"
brew "ripgrep"
brew "bat"
brew "tokei"
brew "gum"          # status dashboard rendering (scripts/status.sh)
brew "television"   # interactive task menu (`task` / task menu-tv → tv)

# macOS apps
cask "bunch"
