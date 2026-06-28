#!/usr/bin/env bash
# shellcheck shell=bash
#
# shell-aliases.sh — interactive shell aliases & functions, baked into the
# devcontainer image at /usr/local/share/devcontainer-config/shell-aliases.sh
# (via the Dockerfile COPY of .devcontainer/config/). It is SOURCED — not
# executed — from ~/.bashrc and ~/.zshrc (wired up by post-create-common.sh),
# so it intentionally omits `set -euo pipefail`.

export PATH="$HOME/.local/bin:$PATH"

# Prevent VS Code JS debug bootloader from breaking lefthook Node hooks.
unset NODE_OPTIONS

# Prevent VS Code's BROWSER helper script from confusing Playwright.
unset BROWSER

# Prevent a host-exported ANTHROPIC_API_KEY from silently winning over
# CLAUDE_CODE_OAUTH_TOKEN and billing the API account instead.
unset ANTHROPIC_API_KEY

# Zellij: auto-create/attach to "main" session.
alias zj='zellij attach --create main'

# Tailscale: only available in the dev profile (DEVCONTAINER_TAILSCALE=true).
if [ "${DEVCONTAINER_TAILSCALE:-}" = "true" ]; then
    alias ts-up='bash .devcontainer/scripts/tailscale-connect.sh'
fi

# workmux: short alias and zsh completions.
alias wm=workmux
command -v workmux &>/dev/null && eval "$(workmux completions zsh)"

# ── Agent Deck ──────────────────────────────────────────────
alias ad='agent-deck'
adf() { agent-deck worktree finish --no-merge "$@"; }
# Usage: adl my-branch Implement the abc plan
# Expands to: agent-deck launch . -c claude -w feat/my-branch -b -m "Implement the abc plan"
adl() { agent-deck launch . -c claude -w "feat/$1" -b -m "${*:2}"; }

# ── pnpm ────────────────────────────────────────────────────
alias p='pnpm'
alias pi='pnpm install'
alias pif='pnpm install --frozen-lockfile'
alias pa='pnpm add'
alias pad='pnpm add --save-dev'
alias prm='pnpm remove'
alias pu='pnpm update'
alias pui='pnpm update --interactive --latest'

# Script runners
alias pd='pnpm run dev'
alias pb='pnpm run build'
alias pt='pnpm test'
alias pst='pnpm start'
alias pln='pnpm run lint'
alias pfmt='pnpm run format'

# Execute (npx equivalent)
alias px='pnpm dlx'
alias pex='pnpm exec'

# Monorepo workspace filter
alias pf='pnpm --filter'

# Nuclear cleanup
alias rnm='rm -rf node_modules'
alias fresh='rm -rf node_modules pnpm-lock.yaml && pnpm install'

# ── Git (beyond oh-my-zsh) ──────────────────────────────────
# Soft undo: reset last commit, keep changes staged
alias gundo='git reset --soft HEAD~1'

# Amend everything into last commit, no message edit
alias gamend='git add -A && git commit --amend --no-edit'

# Add-commit-push (use function for message argument)
gacp() { git add -A && git commit -m "$*" && git push; }

# Empty commit to retrigger CI
alias gcempty='git commit --allow-empty -m "chore: trigger CI"'

# Diff vs main (essential for PR review)
alias gdm='git diff main...HEAD'
alias gchanged='git diff --name-only main...HEAD'
alias gdstat='git diff --stat'

# Branches sorted by most recent commit
alias gbrecent='git branch --sort=-committerdate --format="%(refname:short) %(committerdate:relative)"'

# Fixup commit (pairs with autosquash rebase)
gfixup() { git commit --fixup="$1"; }
alias grbia='git rebase -i --autosquash'

# Fetch + prune stale remote-tracking branches
alias gfp='git fetch --prune'

# Switch to main, pull latest, create new branch
gnew() { git checkout main && git pull && git checkout -b "$1"; }

# Cleanup: delete branches whose remote is gone
# shellcheck disable=SC2142  # $1 is an awk field ref, not a shell positional
alias gcleanup='git fetch -p && git branch -vv | grep ": gone]" | awk "{print \$1}" | xargs -r git branch -D'

# Interactive stash (stash specific hunks)
alias gstap='git stash push -p'

# Quick branch switch with fzf
alias gswf='git branch --sort=-committerdate | fzf --height=20% | xargs git switch'

# ── Conventional commits ────────────────────────────────────
# gc* = commit only | gca* = add all + commit
gcfeat() { git commit -m "feat: $*"; }
gcafix() { git add -A && git commit -m "fix: $*"; }
gcfix() { git commit -m "fix: $*"; }
gcafeat() { git add -A && git commit -m "feat: $*"; }
gcdocs() { git commit -m "docs: $*"; }
gcadocs() { git add -A && git commit -m "docs: $*"; }
gcstyle() { git commit -m "style: $*"; }
gcastyle() { git add -A && git commit -m "style: $*"; }
gcref() { git commit -m "refactor: $*"; }
gcaref() { git add -A && git commit -m "refactor: $*"; }
gcperf() { git commit -m "perf: $*"; }
gcaperf() { git add -A && git commit -m "perf: $*"; }
gctest() { git commit -m "test: $*"; }
gcatest() { git add -A && git commit -m "test: $*"; }
gcbuild() { git commit -m "build: $*"; }
gcabuild() { git add -A && git commit -m "build: $*"; }
gcci() { git commit -m "ci: $*"; }
gcaci() { git add -A && git commit -m "ci: $*"; }
gcchore() { git commit -m "chore: $*"; }
gcachore() { git add -A && git commit -m "chore: $*"; }

# ── TypeScript ──────────────────────────────────────────────
alias tsc='pnpm exec tsc'
alias tscw='pnpm exec tsc --watch'
alias tscn='pnpm exec tsc --noEmit' # type-check only, no output

# ── Vitest ──────────────────────────────────────────────────
alias vt='pnpm exec vitest'
alias vtr='pnpm exec vitest run' # single run (CI-like)
alias vtc='pnpm exec vitest run --coverage'
alias vtu='pnpm exec vitest --ui'

# ── Playwright ──────────────────────────────────────────────
alias pw='pnpm exec playwright'
alias pwt='pnpm exec playwright test'
alias pwth='pnpm exec playwright test --headed'
alias pwtu='pnpm exec playwright test --ui'
alias pwtd='pnpm exec playwright test --debug'
alias pwshow='pnpm exec playwright show-report'

# ── Taskfile (go-task) ──────────────────────────────────────
alias t='task'
alias tl='task --list'

# ── Linting / Formatting ───────────────────────────────────
alias lint='pnpm run lint'
alias lintf='pnpm run lint -- --fix'
alias fmt='pnpm run format'

# ── Ports & networking ──────────────────────────────────────
alias ports='ss -tlnp'
killport() { lsof -ti:"$1" | xargs kill -9 2>/dev/null && echo "Killed port $1" || echo "Nothing on port $1"; }
listening() { lsof -i -P -n | grep ":${1:-}.*LISTEN"; }
alias myip='curl -s https://icanhazip.com'
# shellcheck disable=SC2142  # $1 is an awk field ref, not a shell positional
alias localip='hostname -I | awk "{print \$1}"'

# ── Navigation ──────────────────────────────────────────────
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'
alias cd..='cd ..'
alias -- -='cd -'

# Zoxide auto-creates `z` (jump) and `zi` (interactive via fzf).
# No manual aliases needed — just ensure it's initialized.

# Project workspace root
alias ws='cd /workspaces'

# ── Shell management ────────────────────────────────────────
alias reload='exec zsh'                # full shell reload
alias zshrc='${EDITOR:-code} ~/.zshrc' # quick config edit
alias path='echo -e ${PATH//:/\\n}'    # PATH one-per-line
alias aliases='alias | sort'           # list all aliases
alias ag='alias | rg'                  # search aliases by keyword

# ── Quick utilities ─────────────────────────────────────────
alias c='clear'
mkcd() { mkdir -p "$1" && cd "$1"; }
alias sizeof='du -sh'
alias now='date +"%Y-%m-%d %H:%M:%S"'
alias timestamp='date +%s'
alias weather='curl -s wttr.in/?format=3'
alias help='tldr'
alias md='glow' # render markdown in terminal
alias lg='lazygit'

# ── Docker ──────────────────────────────────────────────────
alias dk='docker'
alias dps='docker ps'
alias dpsa='docker ps -a'
alias dex='docker exec -it'
alias dlog='docker logs -f'
alias drun='docker run --rm -it'

# Docker Compose (modern subcommand syntax)
alias dco='docker compose'
alias dcup='docker compose up -d'
alias dcupb='docker compose up --build -d'
alias dcdn='docker compose down'
alias dcl='docker compose logs -f'
alias dcps='docker compose ps'
alias dcr='docker compose run --rm'

# Cleanup
alias docker-clean='docker system prune -f'
alias docker-nuke='docker system prune -af --volumes'

# ── fzf-powered workflows ──────────────────────────────────
# Fuzzy-find and open file
fe() {
    local file
    file=$(fd --type f | fzf --preview 'bat --color=always --line-range=:500 {}')
    [[ -n "$file" ]] && ${EDITOR:-code} "$file"
}

# Fuzzy grep: search content, preview match, open file
fg() {
    local result
    result=$(rg --line-number --no-heading --color=always "${1:-}" |
        fzf --ansi --delimiter : \
            --preview 'bat --color=always --highlight-line {2} {1}' \
            --preview-window '+{2}-5')
    [[ -n "$result" ]] && ${EDITOR:-code} "$(echo "$result" | cut -d: -f1)"
}

alias preview='fzf --preview "bat --color=always --style=numbers --line-range=:500 {}"'

# ── GitHub CLI ──────────────────────────────────────────────
alias ghpr='gh pr create'
alias ghprl='gh pr list'
alias ghprv='gh pr view --web'
alias ghprc='gh pr checkout'
alias ghis='gh issue list'
alias ghrv='gh repo view --web'
alias ghb='gh browse'
alias ghppr='git push && gh pr create --fill'
alias ghpprd='git push && gh pr create --fill --draft'
alias ghpprm='git push && gh pr create --fill && gh pr merge --auto --squash --delete-branch'
alias ghil='gh issue list'
alias ghic='gh issue create'

# ── Clipboard (OSC 52 — works in VS Code terminal) ─────────
# Usage: echo "text" | clip
#        clip < file.txt
#        git diff --stat | clip
clip() {
    local data
    data=$(cat "$@" | base64 | tr -d '\n')
    printf '\033]52;c;%s\007' "$data" >/dev/tty
}

# Extract any archive
extract() {
    case $1 in
    *.tar.bz2) tar xjf "$1" ;; *.tar.gz) tar xzf "$1" ;;
    *.tar.xz) tar xJf "$1" ;; *.bz2) bunzip2 "$1" ;;
    *.gz) gunzip "$1" ;; *.tar) tar xf "$1" ;;
    *.zip) unzip "$1" ;; *.7z) 7z x "$1" ;;
    *) echo "'$1' — unknown format" ;;
    esac
}
