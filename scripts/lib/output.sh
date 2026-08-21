#!/usr/bin/env bash
# Shared terminal presentation for status boards and action scripts.
#
# Source this file after resolving the repository root. It has no required
# dependencies: ANSI color and Unicode are used only on a capable terminal,
# gum is an optional enhancement, and redirected/NO_COLOR/TERM=dumb output is
# stable ASCII. Action scripts may set OUTPUT_FD=2 before sourcing so Task's
# grouped stdout does not hide live progress.

OUTPUT_FD="${OUTPUT_FD:-1}"

output_is_tty() {
    if [ "${OUTPUT_TEST_TTY:-0}" = 1 ]; then
        return 0
    fi
    [ -t "${OUTPUT_FD}" ]
}

output_emit() {
    if [ "${OUTPUT_FD}" = 2 ]; then
        printf "$@" >&2
    else
        printf "$@"
    fi
}

output_write() {
    if [ "${OUTPUT_FD}" = 2 ]; then
        cat >&2
    else
        cat
    fi
}

OUTPUT_UTF8=false
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
*[Uu][Tt][Ff]-8* | *[Uu][Tt][Ff]8*) OUTPUT_UTF8=true ;;
esac

# NO_COLOR disables gum as well as ANSI. Besides respecting the convention,
# that makes logs and test snapshots plain, greppable text. Gum's borders are
# Unicode, so a non-UTF-8 locale also selects the built-in ASCII presentation.
HAS_GUM=false
if $OUTPUT_UTF8 && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != dumb ] && command -v gum >/dev/null 2>&1; then
    HAS_GUM=true
fi

USE_COLOR=false
if [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != dumb ]; then
    if output_is_tty || { [ -n "${CLICOLOR_FORCE:-}" ] && [ "${CLICOLOR_FORCE}" != 0 ]; }; then
        USE_COLOR=true
    fi
fi

USE_UNICODE=false
if $OUTPUT_UTF8 && $USE_COLOR; then USE_UNICODE=true; fi

# Gum's stdout is captured, so it cannot probe the terminal background with
# OSC 11 and wait several seconds on terminals that do not answer. Preserve
# its status: gum is optional presentation, and callers fall back to the
# built-in renderer when an installed binary is broken or incompatible.
gum_style() {
    local styled
    if ! styled="$(CLICOLOR_FORCE=1 gum style "$@")"; then
        return 1
    fi
    printf '%s\n' "$styled"
}

# action_banner KIND TITLE [DETAIL] — a task-family masthead for mutating
# commands. KIND is deliberately semantic rather than a raw color: a setup,
# secret, release, cleanup, sync, or install task should be recognizable before
# the reader reaches its title. The word always remains visible, so color and
# emoji reinforce meaning without carrying it alone.
action_banner() {
    local kind="$1" title="$2" detail="${3:-}" icon="✦" sgr="1;35" gum_color=212 styled=""
    case "$kind" in
    setup) icon="⚙" && sgr="1;36" && gum_color=39 ;;
    secret) icon="🔐" && sgr="1;35" && gum_color=135 ;;
    release) icon="🚀" && sgr="1;33" && gum_color=220 ;;
    clean) icon="◇" && sgr="1;33" && gum_color=214 ;;
    sync) icon="↻" && sgr="1;34" && gum_color=75 ;;
    install) icon="⬡" && sgr="1;32" && gum_color=42 ;;
    esac
    if ! $USE_UNICODE; then icon="*"; fi

    if $HAS_GUM && output_is_tty &&
        styled="$({
            printf '%s  %s\n' "$icon" "$(printf '%s' "$kind" | tr '[:lower:]' '[:upper:]')"
            printf '%s\n' "$title"
            [ -z "$detail" ] || printf '%s\n' "$detail"
        } | gum_style --bold --foreground "$gum_color" --border double \
            --border-foreground "$gum_color" --padding "0 2" --margin "0 0 1 0")"; then
        output_emit '%s\n' "$styled"
        return 0
    fi
    if $USE_COLOR; then
        output_emit '\n\033[%sm%s  %s\033[0m  \033[1m%s\033[0m\n' "$sgr" "$icon" \
            "$(printf '%s' "$kind" | tr '[:lower:]' '[:upper:]')" "$title"
        [ -z "$detail" ] || output_emit '\033[2m   %s\033[0m\n' "$detail"
        if $USE_UNICODE; then
            output_emit '\033[2;90m%s\033[0m\n' '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
        else
            output_emit '\033[2;90m%s\033[0m\n' '----------------------------------------'
        fi
    else
        output_emit '\n== %s :: %s ==\n' \
            "$(printf '%s' "$kind" | tr '[:lower:]' '[:upper:]')" "$title"
        [ -z "$detail" ] || output_emit '   %s\n' "$detail"
        output_emit '%s\n' '----------------------------------------'
    fi
}

section_header() {
    local title="$1" styled=""
    if $HAS_GUM && output_is_tty &&
        styled="$(gum_style --bold --foreground 212 --border-foreground 240 \
            --border rounded --padding "0 1" -- "$title")"; then
        output_emit '%s\n' "$styled"
        return 0
    fi
    if $USE_COLOR; then
        output_emit '\n\033[1;35m◆ %s\033[0m\n' "$title"
        output_emit '\033[2;90m────────────────────────────────────────\033[0m\n'
    else
        output_emit '\n==> %s\n' "$title"
        output_emit '%s\n' '----------------------------------------'
    fi
}

section_box() {
    local content styled=""
    content="$(cat)"
    if $HAS_GUM && output_is_tty &&
        styled="$(printf '%s\n' "$content" | gum_style --border rounded \
            --border-foreground 240 --padding "0 1" --margin "0 0")"; then
        output_emit '%s\n' "$styled"
        return 0
    fi
    output_emit '%s\n\n' "$content"
}

kv() {
    local key="$1" val="$2" styled_key
    if $HAS_GUM && output_is_tty &&
        styled_key="$(gum_style --bold --foreground 39 "$key:")"; then
        output_emit '  %s  %s\n' "$styled_key" "$val"
        return 0
    fi
    if $USE_COLOR; then
        output_emit '  \033[1;36m%-20s\033[0m %s\n' "$key:" "$val"
    else
        output_emit '  %-20s %s\n' "$key:" "$val"
    fi
}

# c SGR TEXT — emit TEXT wrapped in ANSI when color is active. This writes to
# stdout deliberately: callers use it inside command substitutions.
c() {
    if $USE_COLOR; then printf '\033[%sm%s\033[0m' "$1" "$2"; else printf '%s' "$2"; fi
}

if $USE_UNICODE; then
    I_OK="$(c '1;32' '✓')"
    I_NO="$(c '1;31' '✗')"
    I_UNKNOWN="$(c '1;33' '?')"
    I_NA="$(c '2' '–')"
    I_INFO="$(c '1;36' '•')"
    DETAIL_SEPARATOR=' — '
else
    I_OK='[x]'
    I_NO='[ ]'
    I_UNKNOWN='[?]'
    I_NA='[-]'
    I_INFO=' * '
    DETAIL_SEPARATOR=' - '
fi

subhead() {
    if $USE_UNICODE; then
        output_emit '\n  %s\n' "$(c '1;36' "▸ $1")"
    else
        output_emit '\n  > %s\n' "$1"
    fi
}

bar() {
    local pct="$1" width=20 i=0 fill="" track="" filled
    filled=$((pct * width / 100))
    [ "${filled}" -gt "${width}" ] && filled="${width}"
    [ "${filled}" -lt 0 ] && filled=0
    while [ "${i}" -lt "${width}" ]; do
        if [ "${i}" -lt "${filled}" ]; then
            if $USE_UNICODE; then fill="${fill}█"; else fill="${fill}#"; fi
        else
            if $USE_UNICODE; then track="${track}░"; else track="${track}-"; fi
        fi
        i=$((i + 1))
    done
    printf '%s%s' "$(c '32' "${fill}")" "$(c '2' "${track}")"
}

SETUP_OK=0
SETUP_NO=0
SETUP_UNKNOWN=0
SETUP_NA=0

# checkline STATUS LABEL [DETAIL]
# STATUS: ok | no | unknown | na | info
checkline() {
    local status="$1" label="$2" detail="${3:-}" icon=""
    case "$status" in
    ok) icon="$I_OK" && SETUP_OK=$((SETUP_OK + 1)) ;;
    no) icon="$I_NO" && SETUP_NO=$((SETUP_NO + 1)) ;;
    unknown) icon="$I_UNKNOWN" && SETUP_UNKNOWN=$((SETUP_UNKNOWN + 1)) ;;
    na) icon="$I_NA" && SETUP_NA=$((SETUP_NA + 1)) ;;
    info) icon="$I_INFO" ;;
    *)
        output_emit 'output: unknown check status: %s\n' "$status"
        return 2
        ;;
    esac
    if [ -n "$detail" ]; then
        output_emit '  %s %s%s%s\n' "$icon" "$label" "$DETAIL_SEPARATOR" "$detail"
    else
        output_emit '  %s %s\n' "$icon" "$label"
    fi
}

# output_summary [TITLE] — a compact, scan-friendly outcome table. Counts are
# collected by checkline, so action scripts get a truthful summary without
# duplicating bookkeeping. The plain form is one stable key/value line for CI,
# grep, and snapshots; the terminal form is intentionally more visual.
output_summary() {
    local title="${1:-Outcome}" total
    total=$((SETUP_OK + SETUP_NO + SETUP_UNKNOWN + SETUP_NA))
    if $USE_UNICODE; then
        output_emit '\n  %s\n' "$(c '1;36' "╭─ $title")"
        output_emit '  %s  %-12s %s\n' "$(c '1;32' '│ ✓')" "Succeeded" "$SETUP_OK"
        output_emit '  %s  %-12s %s\n' "$(c '1;31' '│ ✗')" "Failed" "$SETUP_NO"
        output_emit '  %s  %-12s %s\n' "$(c '1;33' '│ ?')" "Attention" "$SETUP_UNKNOWN"
        output_emit '  %s  %-12s %s\n' "$(c '2' '│ –')" "Skipped" "$SETUP_NA"
        output_emit '  %s\n' "$(c '1;36' "╰─ $total checks")"
    else
        output_emit '\nSUMMARY: %s - succeeded=%s failed=%s attention=%s skipped=%s total=%s\n' \
            "$title" "$SETUP_OK" "$SETUP_NO" "$SETUP_UNKNOWN" "$SETUP_NA" "$total"
    fi
}

output_done() {
    if $USE_UNICODE; then
        output_emit '\n%s %s\n' "$(c '1;32' '╰─ ✨')" "$(c '1;32' "$1")"
    else
        output_emit '\nDONE: %s\n' "$1"
    fi
}

output_warning() {
    if $USE_UNICODE; then
        output_emit '\n%s %s\n' "$(c '1;33' '╰─ ⚠')" "$(c '1;33' "$1")"
    else
        output_emit '\nWARN: %s\n' "$1"
    fi
}

output_spinner_loop() {
    local label="$1" i=0 frame
    local unicode_frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local ascii_frames=('|' '/' '-' '\\')
    trap 'exit 0' HUP INT TERM
    while :; do
        if $USE_UNICODE; then
            frame="${unicode_frames[$i]}"
            i=$(((i + 1) % ${#unicode_frames[@]}))
        else
            frame="${ascii_frames[$i]}"
            i=$(((i + 1) % ${#ascii_frames[@]}))
        fi
        printf '\r\033[2K%s %s' "$(c '1;35' "$frame")" "$label" >&2
        sleep "${OUTPUT_SPINNER_DELAY:-0.08}"
    done
}

# output_run LABEL COMMAND... — keep COMMAND in the foreground and animate a
# background-only indicator. The subshell owns every trap, always erases the
# frame, and returns COMMAND's exact status. Redirected/CI output runs COMMAND
# directly and emits no control sequences.
output_run() (
    local label="$1" spinner_pid="" diagnostics="" rc
    shift

    if [ "${OUTPUT_FD}" != 2 ] || { ! output_is_tty && [ "${OUTPUT_TEST_SPINNER:-0}" != 1 ]; } ||
        [ "${CI:-}" = true ] || [ -n "${NO_COLOR:-}" ] || [ "${TERM:-}" = dumb ]; then
        "$@"
        return
    fi

    diagnostics="$(mktemp "${TMPDIR:-/tmp}/harmon-output.XXXXXX")" || return 1
    output_spinner_loop "$label" &
    spinner_pid=$!
    output_spinner_cleanup() {
        if [ -n "$spinner_pid" ]; then
            kill "$spinner_pid" 2>/dev/null || true
            wait "$spinner_pid" 2>/dev/null || true
            spinner_pid=""
        fi
        printf '\r\033[2K' >&2
    }
    output_run_cleanup() {
        output_spinner_cleanup
        [ -z "$diagnostics" ] || rm -f "$diagnostics"
    }
    trap 'output_run_cleanup' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    if "$@" 2>"$diagnostics"; then rc=0; else rc=$?; fi
    output_spinner_cleanup
    if [ -s "$diagnostics" ]; then cat "$diagnostics" >&2; fi
    rm -f "$diagnostics"
    diagnostics=""
    trap - EXIT HUP INT TERM
    return "$rc"
)
