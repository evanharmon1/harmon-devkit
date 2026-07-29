#!/usr/bin/env bash
# claude-statusline.sh — Claude Code `statusLine` renderer for the dev container.
#
# Gives a container session the same two-line status line as a host session:
#
#   📁 ~/git/harmon-init  🌿 main  🤖 Opus 5  📟 v2.1.220  🎨 default
#   🧠 Context Remaining: 60% [======----]
#
# Claude Code pipes the session JSON on stdin and renders whatever we print.
# Baked into the image at /etc/claude-code/statusline.sh (see the Dockerfile) so
# it survives the ~/.claude volume mount, and wired up via the `statusLine` key
# in config/claude-user-defaults.json — a seed default the user can override.
#
# `set -e` is deliberately omitted: this runs on every render, so a single
# failing probe (no git repo, a field a newer payload no longer emits) must
# degrade to a shorter line rather than blank the status line entirely.
set -uo pipefail

input=$(cat)

# ---- colors (256-color palette; honors NO_COLOR) ----
if [ -n "${NO_COLOR:-}" ]; then
    color() { :; }
    reset() { :; }
else
    color() { printf '\033[38;5;%sm' "$1"; }
    reset() { printf '\033[0m'; }
fi

COLOR_DIR=117     # sky blue
COLOR_GIT=150     # soft green
COLOR_MODEL=147   # light purple
COLOR_VERSION=249 # light gray
COLOR_STYLE=245   # gray

# Claude Code renders our stdout as ANSI, and a directory name may legally
# contain ESC or a newline — so every value that reaches the terminal is
# stripped of control bytes first. Without this, a checkout under a crafted
# path could inject escape sequences (OSC 52 clipboard writes, extra status
# lines) on every refresh.
sanitize() { printf '%s' "$1" | tr -d '[:cntrl:]'; }

# field <emoji> <color> <text> — one "  <emoji> <colored text>" segment.
field() {
    printf '  %s %s%s%s' "$1" "$(color "$2")" "$(sanitize "$3")" "$(reset)"
}

# jq is baked into the image. Without it there is no payload to read, so fall
# back to the one thing we can still resolve locally.
if ! command -v jq >/dev/null 2>&1; then
    printf '📁 %s\n' "$(sanitize "$PWD")"
    exit 0
fi

json() { printf '%s' "$input" | jq -r "$1" 2>/dev/null; }

current_dir=$(json '.workspace.current_dir // .cwd // ""')
model_name=$(json '.model.display_name // ""')
cc_version=$(json '.version // ""')
output_style=$(json '.output_style.name // ""')

# jq exits nonzero (and prints nothing) on an unparseable payload, so the
# fallbacks belong here rather than in the filters above.
[ -n "$model_name" ] || model_name="Claude"

# ---- git branch (resolved in the session's directory, not ours) ----
git_branch=""
if [ -n "$current_dir" ] && cd "$current_dir" 2>/dev/null; then
    if git rev-parse --git-dir >/dev/null 2>&1; then
        git_branch=$(git branch --show-current 2>/dev/null)
        [ -n "$git_branch" ] || git_branch=$(git rev-parse --short HEAD 2>/dev/null)
    fi
fi

# ---- display path (~ for $HOME, matching the host status line) ----
display_dir="${current_dir:-unknown}"
case "$display_dir" in
"$HOME") display_dir="~" ;;
"$HOME"/*) display_dir="~${display_dir#"$HOME"}" ;;
esac

# ---- context window ----
# Claude Code already reports `remaining_percentage`; prefer it so the bar never
# disagrees with the figure the CLI itself shows (its rounding is not ours, and
# it accounts for reserved output tokens). The token sum is a fallback for
# payloads that predate the field.
context_pct=""
context_bar=""
context_color=158 # mint green
remaining=$(json '.context_window.remaining_percentage // empty')
if ! [[ "$remaining" =~ ^[0-9]+$ ]]; then
    remaining=""
    context_size=$(json '.context_window.context_window_size // 0')
    context_used=$(json '(.context_window.current_usage // {})
        | (.input_tokens // 0)
        + (.cache_creation_input_tokens // 0)
        + (.cache_read_input_tokens // 0)')
    if [[ "$context_size" =~ ^[0-9]+$ ]] && [[ "$context_used" =~ ^[0-9]+$ ]] &&
        [ "$context_size" -gt 0 ] && [ "$context_used" -gt 0 ]; then
        remaining=$((100 - context_used * 100 / context_size))
    fi
fi

if [ -n "$remaining" ]; then
    ((remaining < 0)) && remaining=0
    ((remaining > 100)) && remaining=100

    if [ "$remaining" -le 20 ]; then
        context_color=203 # coral red
    elif [ "$remaining" -le 40 ]; then
        context_color=215 # peach
    fi

    filled=$((remaining / 10))
    context_bar=$(printf '%*s' "$filled" '' | tr ' ' '=')
    context_bar+=$(printf '%*s' "$((10 - filled))" '' | tr ' ' '-')
    context_pct="${remaining}%"
fi

# ---- render ----
printf '📁 %s%s%s' "$(color "$COLOR_DIR")" "$(sanitize "$display_dir")" "$(reset)"
[ -n "$git_branch" ] && field '🌿' "$COLOR_GIT" "$git_branch"
field '🤖' "$COLOR_MODEL" "$model_name"
[ -n "$cc_version" ] && field '📟' "$COLOR_VERSION" "v${cc_version}"
[ -n "$output_style" ] && field '🎨' "$COLOR_STYLE" "$output_style"

if [ -n "$context_pct" ]; then
    printf '\n🧠 %sContext Remaining: %s [%s]%s' \
        "$(color "$context_color")" "$context_pct" "$context_bar" "$(reset)"
else
    printf '\n🧠 %sContext Remaining: TBD%s' "$(color "$context_color")" "$(reset)"
fi
printf '\n'
