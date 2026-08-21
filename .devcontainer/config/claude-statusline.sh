#!/usr/bin/env bash
# claude-statusline.sh — Claude Code `statusLine` renderer for the dev container.
#
# Gives a container session the same four-line status line as a host session:
#
#   📁 ~/git/my-project  🌿 main  PR #512 ✓  ▪ session name  · a1b2c3d4
#   🧠 ▕████░░░░░░░░░░░░▏ 24%  760k left  🤖 Opus 5 1M · medium · ⚡ · 💭  📟 v2.1.220
#   💰 $0.43  ✎ +120/-45  ⏱ 11m session
#   🚦 5h ▕█░░░░░░▏ ⧖ 2h13m   ·   7d ▕░░░░░░░▏ ⧖ 4d20h
#
# Reading down: where you are, how much room and horsepower you have left, what
# the session has cost, and how close the subscription limits are to biting.
# Line 4's bars are the same gauge as line 2's at roughly half the width and a
# muted palette — same reading habit, lower priority.
#
# Claude Code pipes the session JSON on stdin and renders whatever we print.
# Baked into the image at /etc/claude-code/statusline.sh (see the Dockerfile) so
# it survives the ~/.claude volume mount, and wired up via the `statusLine` key
# in config/claude-user-defaults.json — a seed default the user can override.
#
# This runs on every keystroke-ish refresh, so it is built to stay cheap: it
# executes exactly two external commands, `jq` and `date`. In particular there
# is no `git` subprocess — the branch is read straight out of .git/HEAD — stdin
# is drained by `read` rather than `cat`, and jq is fed by here-string rather
# than a pipeline, so neither costs an extra process. No logging, and no
# network. Everything else is bash builtins, and the helpers below
# deliberately return through $REPLY rather than $(...) because a command
# substitution is a subshell fork; at ~20 segments a render that is the
# difference between a couple of forks and two dozen.
#
# `set -e` is deliberately omitted: a single failing probe (no git repo, a
# field a newer payload no longer emits) must degrade to a shorter line rather
# than blank the status line entirely.
set -uo pipefail

# Drain stdin with the builtin rather than `cat`. -d '' reads to EOF in one go
# and returns nonzero there, which is the normal path — the payload is in
# $input either way, so the status is deliberately ignored.
IFS= read -r -d '' input || true

# ---- toggles (override in the environment) ----
: "${STATUSLINE_COLOR:=1}"     # 0 disables color (NO_COLOR is honored too)
: "${STATUSLINE_HYPERLINK:=1}" # 0 disables the OSC-8 link on the PR number
: "${STATUSLINE_CTX_WIDTH:=16}"
: "${STATUSLINE_RL_WIDTH:=7}" # deliberately under half the context bar
: "${STATUSLINE_RL_PCT:=0}"   # 1 also prints the exact limit percentage

[ -n "${NO_COLOR:-}" ] && STATUSLINE_COLOR=0

# ---- color, precomputed (no forks at render time) ----
if [ "$STATUSLINE_COLOR" = 1 ]; then
    e=$'\033'
    RST="${e}[0m"
    DIR="${e}[38;5;117m"   # sky blue
    ROOT="${e}[38;5;103m"  # muted blue
    GIT="${e}[38;5;150m"   # soft green
    PR="${e}[38;5;213m"    # pink
    MODEL="${e}[38;5;147m" # light purple
    # Both grays sit a step brighter than a "secondary text" palette would
    # suggest. Anything below ~244 disappears into a dark terminal background —
    # legible in a screenshot, invisible in use.
    META="${e}[38;5;250m" # gray
    DIM="${e}[38;5;245m"  # softer gray
    COST="${e}[38;5;180m" # soft yellow
    OK="${e}[38;5;158m"   # mint
    WARN="${e}[38;5;215m" # peach
    HOT="${e}[38;5;203m"  # coral
    # Same three signals a few shades down, for the usage-limit bars. They are
    # the same gauge as the context window and must read that way, so the hues
    # match — but they sit further back, and a duller palette says "same idea,
    # lower priority" without needing a second shape to say it.
    OK_D="${e}[38;5;71m"    # moss
    WARN_D="${e}[38;5;173m" # clay
    HOT_D="${e}[38;5;167m"  # brick
else
    RST='' DIR='' ROOT='' GIT='' PR='' MODEL='' META='' DIM='' COST=''
    OK='' WARN='' HOT='' OK_D='' WARN_D='' HOT_D=''
fi

# ---- payload ----
# One jq invocation emits every field in a fixed order. Control bytes are
# stripped inside jq: Claude Code renders our stdout as ANSI, and a directory,
# branch, or session name may legally contain ESC or a newline — so without
# this a checkout under a crafted path could inject escape sequences (OSC 52
# clipboard writes, extra status lines) on every refresh, or desync the field
# split below.
if ! command -v jq >/dev/null 2>&1; then
    printf '📁 %s\n' "${PWD//[[:cntrl:]]/}"
    exit 0
fi

fields=$(jq -r '
  # C0 (0-31), DEL, and C1 (128-159) all go. C1 matters because a terminal in
  # 8-bit mode reads U+009B as CSI outright — the same escape this strips in
  # its ESC-[ form, arriving by a route a C0-only filter would wave through.
  def s: (. // "") | tostring | explode
         | map(select(. > 31 and . != 127 and (. < 128 or . > 159))) | implode;
  def n: (. // 0) | if type == "number" then floor else 0 end;
  # Like n, but absence stays absent. A session without a subscription — API
  # key, Bedrock, Vertex, an alternative provider — has no .rate_limits at all,
  # and folding that to 0 would draw two empty quota bars claiming a fresh
  # allowance the session does not have. Only a real 0 may render as 0.
  def o: if . == null then "" else (. | n) end;
  [ (((if (.workspace | type) == "object" then .workspace.current_dir else .workspace end) // .cwd // .workspace_path) | s)
  , ((if (.workspace | type) == "object" then .workspace.project_dir else "" end) | s)
  , ((if (.model | type) == "object" then (.model.display_name // .model.id) else .model end) | s)
  , ((if (.effort | type) == "object" then .effort.level else .effort end) | s)
  , (((.fast_mode == true) or (.fast == true)) | s)
  , (((if (.thinking | type) == "object" then .thinking.enabled else .thinking end) == true) | s)
  , (.version | s)
  , ((if (.output_style | type) == "object" then .output_style.name else .output_style end) | s)
  , ((.session_id // .conversation_id // .conversationId) | s | .[0:8])
  , (.session_name | s)
  # The context gauge has three states, not two: a percentage, and "unknown".
  # A payload carrying neither field — an early-session refresh, or an agent
  # that reports only token counts — must reach the renderer as absent so
  # it draws `context n/a`. Defaulting the missing remainder to 100 would make
  # `100 - 100 = 0` and paint an empty green bar over a context window that may
  # be nearly full: the one wrong answer worse than no answer. Same rule as `o`
  # above, one field deeper.
  , (if   ((.context_window | type) == "object" and (.context_window.used_percentage | type) == "number")
     then (.context_window.used_percentage | floor)
     elif ((.context_window | type) == "object" and (.context_window.remaining_percentage | type) == "number")
     then ((100 - .context_window.remaining_percentage) | floor)
     elif ((.context_window | type) == "object" and (.context_window.total_tokens | type) == "number" and (.context_window.context_window_size | type) == "number" and .context_window.context_window_size > 0 and .context_window.total_tokens <= .context_window.context_window_size)
     then ((.context_window.total_tokens * 100 / .context_window.context_window_size) | floor)
     else "" end)
  , ((if (.context_window | type) == "object" then .context_window.context_window_size else 0 end) | n)
  , ((if (.cost | type) == "object" then .cost.total_cost_usd else .cost end) | (. // 0) | tostring)
  , ((if (.cost | type) == "object" then .cost.total_lines_added else 0 end) | n)
  , ((if (.cost | type) == "object" then .cost.total_lines_removed else 0 end) | n)
  , ((if (.cost | type) == "object" then .cost.total_duration_ms else 0 end) | n)
  , ((if (.pr | type) == "object" then .pr.number else "" end) | s)
  , ((if (.pr | type) == "object" then .pr.url else "" end) | s)
  , ((if (.pr | type) == "object" then .pr.review_state else "" end) | s)
  , ((if (.rate_limits | type) == "object" then .rate_limits.five_hour.used_percentage elif (.quota | type) == "object" then .quota.five_hour.used_percentage else null end) | o)
  , ((if (.rate_limits | type) == "object" then .rate_limits.five_hour.resets_at elif (.quota | type) == "object" then .quota.five_hour.resets_at else null end) | o)
  , ((if (.rate_limits | type) == "object" then .rate_limits.seven_day.used_percentage elif (.quota | type) == "object" then .quota.seven_day.used_percentage else null end) | o)
  , ((if (.rate_limits | type) == "object" then .rate_limits.seven_day.resets_at elif (.quota | type) == "object" then .quota.seven_day.resets_at else null end) | o)
  ] | map(tostring) | join("\u001f")' <<<"$input" 2>/dev/null)

# Split on U+001F (unit separator), not a tab: TAB is IFS *whitespace*, so
# `read` would collapse runs of it and silently shift every field after the
# first empty one. The filter above strips control bytes from every value, so
# a US can never occur inside one.
IFS=$'\037' read -r cur_dir proj_dir model effort fast thinking cc_ver style \
    sid sname ctx_pct ctx_size cost lines_add lines_del dur_ms \
    pr_num pr_url pr_state rl5_pct rl5_at rl7_pct rl7_at <<<"$fields"

[ -n "${model:-}" ] || model="Claude"
# $PWD never passed through the jq filter, so it is stripped here instead.
# Without this, running from a directory whose name contains ESC or BEL would
# reopen the injection path on exactly the paths that reach this fallback — an
# unparseable payload, or one carrying no workspace at all.
[ -n "${cur_dir:-}" ] || cur_dir="${PWD//[[:cntrl:]]/}"

# One clock read serves every relative figure below. The wall-clock time itself
# is deliberately not shown: the terminal, the OS, and the wall already have it,
# and it is the one number here that says nothing about the session.
now=$(date +%s)

# ---- helpers (results land in $REPLY) ----
num() { case "${1:-}" in '' | *[!0-9]*) return 1 ;; esac }

# sane <value> <default> <min> <max> — a bounded integer, whatever was passed.
#
# The numeric overrides are user-supplied and end up inside (( )), where bash
# resolves a bare word as a *variable name*: STATUSLINE_CTX_WIDTH=abc is an
# unbound variable under `set -u`, which aborts the render mid-line. A typo in
# an optional knob must not be able to blank the status line, and an absurd
# width must not make every refresh build an unbounded string.
sane() {
    local v=$1
    case "$v" in '' | *[!0-9]*) v=$2 ;; esac
    # 10# because bash reads a leading zero as octal: STATUSLINE_CTX_WIDTH=08
    # passes the digits-only test above and then dies on "value too great for
    # base", which is a stranger failure than the typo it came from.
    v=$((10#$v))
    ((v < $3)) && v=$3
    ((v > $4)) && v=$4
    REPLY=$v
}
sane "$STATUSLINE_CTX_WIDTH" 16 1 60 && STATUSLINE_CTX_WIDTH=$REPLY
sane "$STATUSLINE_RL_WIDTH" 7 0 60 && STATUSLINE_RL_WIDTH=$REPLY
sane "$STATUSLINE_RL_PCT" 0 0 1 && STATUSLINE_RL_PCT=$REPLY

# bar <used-pct> <width> — the filled portion represents consumption.
bar() {
    local pct=$1 width=$2 i=0
    ((pct < 0)) && pct=0
    ((pct > 100)) && pct=100
    local filled=$((pct * width / 100))
    REPLY='▕'
    while ((i < width)); do
        if ((i < filled)); then REPLY+='█'; else REPLY+='░'; fi
        ((i++))
    done
    REPLY+='▏'
}

# heat <used-pct> [ok] [warn] [hot] — go/caution/stop by consumption, at the
# same 60/80 thresholds everywhere. The palette is an argument so the limit
# bars can run the muted set without forking the thresholds along with it.
heat() {
    if (($1 >= 80)); then
        REPLY=${4:-$HOT}
    elif (($1 >= 60)); then
        REPLY=${3:-$WARN}
    else
        REPLY=${2:-$OK}
    fi
}

# compact <tokens> — 940k / 1.2M, so the figure never jitters in width.
compact() {
    local v=$1
    if ((v >= 1000000)); then
        printf -v REPLY '%d.%dM' $((v / 1000000)) $((v % 1000000 / 100000))
    elif ((v >= 1000)); then
        printf -v REPLY '%dk' $((v / 1000))
    else
        REPLY=$v
    fi
}

# dur <seconds> — 1d6h / 2h13m / 14m / 45s, dropping units that read as noise.
dur() {
    local s=$1
    if ((s >= 86400)); then
        printf -v REPLY '%dd%dh' $((s / 86400)) $((s % 86400 / 3600))
    elif ((s >= 3600)); then
        printf -v REPLY '%dh%02dm' $((s / 3600)) $((s % 3600 / 60))
    elif ((s >= 60)); then
        printf -v REPLY '%dm' $((s / 60))
    else
        printf -v REPLY '%ds' "$s"
    fi
}

tilde() {
    case "$1" in
    "$HOME") REPLY='~' ;;
    "$HOME"/*) REPLY="~${1#"$HOME"}" ;;
    *) REPLY=$1 ;;
    esac
}

# seg <emoji> <color> <text>
seg() { printf '  %s %s%s%s' "$1" "$2" "$3" "$RST"; }

# ---- git branch, without forking git ----
# Walk up from the session directory to the first .git. In a linked worktree
# .git is a FILE holding `gitdir: <path>`, and that path's HEAD is the one that
# describes the checkout you are actually sitting in.
branch='' gitdir='' d=$cur_dir
while [ -n "$d" ] && [ "$d" != / ]; do
    if [ -d "$d/.git" ]; then
        gitdir="$d/.git"
        break
    elif [ -f "$d/.git" ]; then
        read -r _ gitdir <"$d/.git" 2>/dev/null
        case "$gitdir" in /*) ;; *) gitdir="$d/$gitdir" ;; esac
        break
    fi
    # A relative or otherwise slashless value leaves `${d%/*}` equal to `d`,
    # which would spin here forever. Stop instead of ascending nowhere.
    parent=${d%/*}
    [ "$parent" = "$d" ] && break
    d=$parent
done
if [ -n "$gitdir" ] && [ -r "$gitdir/HEAD" ]; then
    read -r head <"$gitdir/HEAD" 2>/dev/null
    case "$head" in
    "ref: refs/heads/"*) branch="${head#ref: refs/heads/}" ;;
    *) branch="${head:0:7}" ;;
    esac
    branch="${branch//[[:cntrl:]]/}"
fi

# =====================================================================
# line 1 — where you are
# =====================================================================
tilde "$cur_dir"
printf '📁 %s%s%s' "$DIR" "$REPLY" "$RST"

# The launch directory only earns space when it is not the one you are in.
if [ -n "${proj_dir:-}" ] && [ "$proj_dir" != "$cur_dir" ]; then
    tilde "$proj_dir"
    seg '⌂' "$ROOT" "$REPLY"
fi

[ -n "$branch" ] && seg '🌿' "$GIT" "$branch"

if num "${pr_num:-}"; then
    label="#$pr_num"
    # OSC-8 hides pr.url behind the number: clickable, zero extra columns.
    # Terminals that do not implement it ignore the sequence.
    if [ "$STATUSLINE_HYPERLINK" = 1 ] && [ -n "${pr_url:-}" ] && [ "$STATUSLINE_COLOR" = 1 ]; then
        label="${e}]8;;${pr_url}${e}\\${label}${e}]8;;${e}\\"
    fi
    case "${pr_state:-}" in
    approved) label+=' ✓' ;;
    changes_requested) label+=' ✗' ;;
    pending | commented) label+=' ⋯' ;;
    esac
    # The only word in an emoji slot on this line, so it is dimmed: left at the
    # default foreground it would be the BRIGHTEST thing on line 1, which is the
    # opposite of what a label should be. Gray label, pink number — the same
    # "quiet key, loud value" the rest of the line already reads as.
    seg "${DIM}PR${RST}" "$PR" "$label"
fi

[ -n "${sname:-}" ] && seg '▪' "$META" "$sname"
[ -n "${sid:-}" ] && seg '·' "$DIM" "$sid"

# =====================================================================
# line 2 — context window, and what is answering
# =====================================================================
printf '\n'
if num "${ctx_pct:-}"; then
    heat "$ctx_pct"
    ctx_color=$REPLY
    bar "$ctx_pct" "$STATUSLINE_CTX_WIDTH"
    printf '🧠 %s%s %s%%%s' "$ctx_color" "$REPLY" "$ctx_pct" "$RST"
    # Derive the headroom from the same percentage the bar uses. The raw token
    # sum is more precise but disagrees with used_percentage (which also counts
    # reserved output tokens), and a bar that contradicts the number beside it
    # is worse than a slightly rounded figure.
    if num "${ctx_size:-}" && ((ctx_size > 0)); then
        compact $((ctx_size * (100 - ctx_pct) / 100))
        printf ' %s%s left%s' "$DIM" "$REPLY" "$RST"
    fi
else
    printf '🧠 %scontext n/a%s' "$DIM" "$RST"
fi

# "Opus 5 (1M context)" is accurate and too wide; the parenthetical is the only
# part that varies between the two, so keep it and drop the filler word.
mode="${model/ (1M context)/ 1M}"
[ -n "${effort:-}" ] && mode+=" · $effort"
[ "${fast:-}" = true ] && mode+=' · ⚡'
[ "${thinking:-}" = true ] && mode+=' · 💭'
seg '🤖' "$MODEL" "$mode"

[ -n "${cc_ver:-}" ] && seg '📟' "$DIM" "v$cc_ver"
[ -n "${style:-}" ] && [ "$style" != default ] && seg '🎨' "$META" "$style"

# =====================================================================
# line 3 — what the session has spent
# =====================================================================
printf '\n'
case "${cost:-}" in
'' | *[!0-9.]*) cost=0 ;;
esac
printf '💰 %s$%.2f%s' "$COST" "$cost" "$RST"

if num "${lines_add:-}" && num "${lines_del:-}" && ((lines_add + lines_del > 0)); then
    printf '  ✎ %s+%s%s/%s-%s%s' "$OK" "$lines_add" "$RST" "$HOT" "$lines_del" "$RST"
fi

if num "${dur_ms:-}" && ((dur_ms > 0)); then
    dur $((dur_ms / 1000))
    seg '⏱' "$META" "$REPLY session"
fi

# =====================================================================
# line 4 — subscription usage limits
# =====================================================================
# Two independent rolling windows, each with its own allowance and its own
# reset, on a line of their own. Each reads as: window, how full it is, how long
# until it empties. Same bar and same heat colors as the context window, so one
# reading habit covers both — but at well under half the width, because these
# are a background concern and should not compete with the context gauge for
# attention at a glance.
rl() {
    local label=$1 pct=$2 at=$3 gauge
    num "$pct" || return 0
    heat "$pct" "$OK_D" "$WARN_D" "$HOT_D"
    gauge=$REPLY
    bar "$pct" "$STATUSLINE_RL_WIDTH"
    gauge+="$REPLY$RST"
    ((STATUSLINE_RL_PCT)) && gauge+="$DIM ${pct}%$RST"
    printf '%s%s%s %s' "$META" "$label" "$RST" "$gauge"
    # A reset already in the past means a stale payload, not "due now" — drop
    # it rather than render a countdown that has stopped meaning anything.
    if num "$at" && ((at > now)); then
        dur $((at - now))
        printf ' %s⧖ %s%s' "$DIM" "$REPLY" "$RST"
    fi
}
if num "${rl5_pct:-}" || num "${rl7_pct:-}"; then
    printf '\n🚦 '
    rl 5h "${rl5_pct:-}" "${rl5_at:-}"
    if num "${rl5_pct:-}" && num "${rl7_pct:-}"; then
        printf '%s   ·   %s' "$DIM" "$RST"
    fi
    rl 7d "${rl7_pct:-}" "${rl7_at:-}"
fi

printf '\n'
