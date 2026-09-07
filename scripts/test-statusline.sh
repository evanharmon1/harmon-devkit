#!/usr/bin/env bash
# test-statusline.sh — unit-test the devcontainer status line renderer against
# hand-written payloads. The case that matters most is the absent one: a
# payload with no context percentages must render "context n/a", never a green
# 0% bar over a window that may be nearly full. Run via `task test:statusline`.
#
# No container and no network: the renderer reads stdin and prints, so the
# whole suite is `bash statusline.sh <<<'{...}'` plus string assertions.
set -euo pipefail
cd "$(dirname "$0")/.."
sl=".devcontainer/config/claude-statusline.sh"
defaults=".devcontainer/config/claude-user-defaults.json"

[ -r "$sl" ] || {
    echo "TEST FAIL: $sl not found" >&2
    exit 1
}
[ -r "$defaults" ] || {
    echo "TEST FAIL: $defaults not found" >&2
    exit 1
}
command -v jq >/dev/null 2>&1 || {
    echo "TEST FAIL: jq is required by the status line and by this suite" >&2
    exit 1
}
bash_bin=$(command -v bash)

fail() {
    # shell-robustness: ok — always exits, so its status is never read
    echo "TEST FAIL: $*" >&2
    exit 1
}

# render <json> -> the rendered status line, uncolored. current_dir is pinned
# to / so the git probe finds nothing and the output stays identical wherever
# the suite runs (a checkout's own branch would leak into line 1 otherwise).
render() {
    NO_COLOR=1 STATUSLINE_HYPERLINK=0 "$bash_bin" "$sl" <<<"$1"
}

render_hyperlinked() {
    env -u NO_COLOR STATUSLINE_COLOR=1 STATUSLINE_HYPERLINK=1 "$bash_bin" "$sl" <<<"$1"
}

echo "==> status line defaults do not force refreshInterval into user settings"
if jq -e '.statusLine | has("refreshInterval")' "$defaults" >/dev/null; then
    fail "statusLine.refreshInterval must not be seeded into user settings"
fi

# ---- pull request: present, draft, and absent ----

echo "==> a numeric pr.number renders the PR segment"
out=$(render '{"workspace":{"current_dir":"/"},"pr":{"number":1042}}')
case "$out" in *'PR #1042'*) ;; *) fail "expected PR #1042, got: $out" ;; esac

echo "==> pr.url and draft review_state are accepted without a review glyph"
out=$(render '{"workspace":{"current_dir":"/"},"pr":{"number":1042,"url":"https://github.com/evanharmon1/harmon-init/pull/1042","review_state":"draft"}}')
case "$out" in *'PR #1042'*) ;; *) fail "expected PR #1042 with URL and draft state, got: $out" ;; esac
case "$out" in *'✓'* | *'✗'* | *'⋯'*) fail "draft PR invented a review glyph: $out" ;; esac

echo "==> pr.url wraps the number in an OSC-8 hyperlink"
pr_url="https://github.com/evanharmon1/harmon-init/pull/1042"
out=$(render_hyperlinked "{\"workspace\":{\"current_dir\":\"/\"},\"pr\":{\"number\":1042,\"url\":\"$pr_url\"}}")
osc8=$'\033'
link="${osc8}]8;;${pr_url}${osc8}\\#1042${osc8}]8;;${osc8}\\"
case "$out" in *"$link"*) ;; *) fail "expected OSC-8 link for $pr_url around #1042" ;; esac

echo "==> an absent pr omits the PR segment"
out=$(render '{"workspace":{"current_dir":"/"}}')
case "$out" in *'PR #'*) fail "absent PR rendered a PR segment: $out" ;; esac

echo "==> an opted-in missing payload PR uses a bounded synchronous gh cache"
statusline_tmp=$(mktemp -d "${TMPDIR:-/tmp}/statusline.XXXXXX")
trap 'rm -rf "$statusline_tmp"' EXIT
fixture_repo="$statusline_tmp/repo"
stub_dir="$statusline_tmp/bin"
mkdir -p "$fixture_repo/.git" "$stub_dir"
printf '%s\n' 'ref: refs/heads/statusline/test-branch' >"$fixture_repo/.git/HEAD"

# The stubs prove the renderer asks `timeout` to cap every lookup at one second,
# never permits an interactive gh prompt, and asks `gh` to resolve the PR for
# the checkout's current branch.
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    '[ "${GH_PROMPT_DISABLED:-}" = 1 ] || exit 42' \
    '[ -z "${GH_REPO+x}" ] || exit 43' \
    'printf "%s\n" "$*" >>"$STATUSLINE_GH_LOG"' \
    'case "${STATUSLINE_GH_MODE:-ok}" in' \
    'ok) printf "%s\n" "${STATUSLINE_GH_RESPONSE:?}" ;;' \
    'switch) printf "%s\n" "${STATUSLINE_GH_RESPONSE:?}"; printf "%s\n" "${STATUSLINE_GH_SWITCH_HEAD:?}" >"${STATUSLINE_GIT_HEAD:?}" ;;' \
    'fail) exit 1 ;;' \
    '*) exit 64 ;;' \
    'esac' >"$stub_dir/gh"
chmod +x "$stub_dir/gh"

printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    '[ "${1:-}" = -s ] && [ "${2:-}" = KILL ] && [ "${3:-}" = 1 ] || exit 64' \
    'printf "%s\n" "$*" >>"$STATUSLINE_TIMEOUT_LOG"' \
    'case "${STATUSLINE_TIMEOUT_MODE:-run}" in' \
    'run) shift 3; exec "$@" ;;' \
    'fail) exit 124 ;;' \
    '*) exit 64 ;;' \
    'esac' >"$stub_dir/timeout"
chmod +x "$stub_dir/timeout"

# render_cached <cache-dir> <ttl-seconds> <json>
render_cached() {
    local cache_dir=$1 ttl=$2 payload=$3
    PATH="$stub_dir:$PATH" STATUSLINE_PR_LOOKUP_ENABLED=1 \
        STATUSLINE_PR_CACHE_DIR="$cache_dir" STATUSLINE_PR_CACHE_TTL="$ttl" \
        NO_COLOR=1 STATUSLINE_HYPERLINK=0 "$bash_bin" "$sl" <<<"$payload"
}

render_cached_hyperlinked() {
    local cache_dir=$1 ttl=$2 payload=$3
    env -u NO_COLOR PATH="$stub_dir:$PATH" STATUSLINE_PR_LOOKUP_ENABLED=1 \
        STATUSLINE_PR_CACHE_DIR="$cache_dir" STATUSLINE_PR_CACHE_TTL="$ttl" \
        STATUSLINE_COLOR=1 STATUSLINE_HYPERLINK=1 "$bash_bin" "$sl" <<<"$payload"
}

# With no environment override, either production marker location enables the
# opt-in: the installed config directory or the marker shipped beside the
# status-line script. This exercises renderer discovery without duplicating
# scripts/test-template.sh's rendered-asset assertions.
render_marker_default() {
    local cache_dir=$1 ttl=$2 payload=$3
    env -u STATUSLINE_PR_LOOKUP_ENABLED PATH="$stub_dir:$PATH" \
        STATUSLINE_PR_CACHE_DIR="$cache_dir" STATUSLINE_PR_CACHE_TTL="$ttl" \
        NO_COLOR=1 STATUSLINE_HYPERLINK=0 "$bash_bin" "$sl" <<<"$payload"
}

payload=$(printf '{"workspace":{"current_dir":"%s"}}' "$fixture_repo")
cache_dir="$statusline_tmp/cache"
export STATUSLINE_GH_LOG="$statusline_tmp/gh.log"
export STATUSLINE_TIMEOUT_LOG="$statusline_tmp/timeout.log"
export STATUSLINE_GH_MODE=ok STATUSLINE_TIMEOUT_MODE=run
export GH_REPO='wrong-owner/wrong-repository'
export STATUSLINE_GH_RESPONSE='{"number":1042,"url":"https://example.test/pull/1042","isDraft":false,"reviewDecision":"APPROVED","state":"OPEN"}'
: >"$STATUSLINE_GH_LOG"
: >"$STATUSLINE_TIMEOUT_LOG"

out=$(render_cached_hyperlinked "$cache_dir" 30 "$payload")
case "$out" in *'#1042'*'✓'*) ;; *) fail "expected cached fallback PR #1042 approval, got: $out" ;; esac
pr_url="https://example.test/pull/1042"
osc8=$'\033'
link="${osc8}]8;;${pr_url}${osc8}\\#1042${osc8}]8;;${osc8}\\"
case "$out" in *"$link"*) ;; *) fail "expected fallback OSC-8 link for $pr_url around #1042" ;; esac
[ "$(wc -l <"$STATUSLINE_GH_LOG")" -eq 1 ] || fail "expected one gh lookup on a cache miss"
[ "$(wc -l <"$STATUSLINE_TIMEOUT_LOG")" -eq 1 ] || fail "expected one one-second timeout wrapper"
grep -qx 'pr view --json number,url,isDraft,reviewDecision,state' "$STATUSLINE_GH_LOG" ||
    fail "lookup did not resolve the current checkout's PR"

echo "==> either production opt-in marker controls no-override lookup"
marker_cache="$statusline_tmp/marker-cache"
: >"$STATUSLINE_GH_LOG"
: >"$STATUSLINE_TIMEOUT_LOG"
out=$(render_marker_default "$marker_cache" 30 "$payload")
if [ -r /usr/local/share/devcontainer-config/statusline-pr-lookup.enabled ] ||
    [ -r "${sl%/*}/statusline-pr-lookup.enabled" ]; then
    case "$out" in *'PR #1042 ✓'*) ;; *) fail "production marker did not enable fallback: $out" ;; esac
    [ "$(wc -l <"$STATUSLINE_GH_LOG")" -eq 1 ] || fail "marker-enabled fallback did not make one gh lookup"
    [ "$(wc -l <"$STATUSLINE_TIMEOUT_LOG")" -eq 1 ] || fail "marker-enabled fallback did not use timeout"
else
    case "$out" in *'PR #'*) fail "absent marker unexpectedly rendered a PR: $out" ;; esac
    [ ! -s "$STATUSLINE_GH_LOG" ] || fail "absent marker unexpectedly called gh"
    [ ! -s "$STATUSLINE_TIMEOUT_LOG" ] || fail "absent marker unexpectedly called timeout"
fi

# Restore the logs before cache assertions below, which are scoped to the
# explicitly enabled cache directory rather than the marker-detection probe.
: >"$STATUSLINE_GH_LOG"
: >"$STATUSLINE_TIMEOUT_LOG"

echo "==> a fresh positive cache makes no second gh call"
out=$(render_cached "$cache_dir" 30 "$payload")
case "$out" in *'PR #1042 ✓'*) ;; *) fail "fresh fallback cache did not render PR #1042: $out" ;; esac
[ ! -s "$STATUSLINE_GH_LOG" ] || fail "fresh cache made a second gh call"
[ ! -s "$STATUSLINE_TIMEOUT_LOG" ] || fail "fresh cache invoked timeout again"

echo "==> future-dated cache rows are stale after a clock rollback"
future_cache="$statusline_tmp/future-cache"
: >"$STATUSLINE_GH_LOG"
: >"$STATUSLINE_TIMEOUT_LOG"
export STATUSLINE_GH_RESPONSE='{"number":1045,"url":"https://example.test/pull/1045","isDraft":false,"reviewDecision":"APPROVED","state":"OPEN"}'
out=$(render_cached "$future_cache" 30 "$payload")
case "$out" in *'PR #1045 ✓'*) ;; *) fail "future-cache setup did not render PR #1045: $out" ;; esac
future_files=("$future_cache"/*)
[ "${#future_files[@]}" -eq 1 ] || fail "future-cache setup did not write exactly one cache row"
IFS=$'\t' read -r _ future_kind future_number future_url future_state <"${future_files[0]}"
future_at=$(($(date +%s) + 3600))
printf '%s\t%s\t%s\t%s\t%s\n' "$future_at" "$future_kind" "$future_number" "$future_url" "$future_state" >"${future_files[0]}"
export STATUSLINE_GH_RESPONSE='{"number":1046,"url":"https://example.test/pull/1046","isDraft":false,"reviewDecision":"APPROVED","state":"OPEN"}'
out=$(render_cached "$future_cache" 30 "$payload")
case "$out" in *'PR #1046 ✓'*) ;; *) fail "future-dated cache row was reused: $out" ;; esac
[ "$(wc -l <"$STATUSLINE_GH_LOG")" -eq 2 ] || fail "future-dated cache row did not refresh"

echo "==> merged pull requests are negative-cached and never rendered"
closed_cache="$statusline_tmp/closed-cache"
: >"$STATUSLINE_GH_LOG"
: >"$STATUSLINE_TIMEOUT_LOG"
export STATUSLINE_GH_RESPONSE='{"number":1046,"url":"https://example.test/pull/1046","isDraft":false,"reviewDecision":"APPROVED","state":"MERGED"}'
out=$(render_cached "$closed_cache" 30 "$payload")
case "$out" in *'PR #'*) fail "merged pull request rendered as active: $out" ;; esac
[ "$(wc -l <"$STATUSLINE_GH_LOG")" -eq 1 ] || fail "merged pull request did not make one lookup"
out=$(render_cached "$closed_cache" 30 "$payload")
case "$out" in *'PR #'*) fail "negative-cached merged pull request rendered as active: $out" ;; esac
[ "$(wc -l <"$STATUSLINE_GH_LOG")" -eq 1 ] || fail "negative-cached merged pull request retried before its TTL"

echo "==> a branch change during gh lookup cannot cache or render the old branch PR"
switch_cache="$statusline_tmp/switch-cache"
: >"$STATUSLINE_GH_LOG"
: >"$STATUSLINE_TIMEOUT_LOG"
export STATUSLINE_GH_MODE=switch
export STATUSLINE_GIT_HEAD="$fixture_repo/.git/HEAD"
export STATUSLINE_GH_SWITCH_HEAD='ref: refs/heads/statusline/switched-branch'
export STATUSLINE_GH_RESPONSE='{"number":1047,"url":"https://example.test/pull/1047","isDraft":false,"reviewDecision":"APPROVED","state":"OPEN"}'
out=$(render_cached "$switch_cache" 30 "$payload")
case "$out" in *'PR #'*) fail "branch-switch race rendered the old branch PR: $out" ;; esac
[ "$(wc -l <"$STATUSLINE_GH_LOG")" -eq 1 ] || fail "branch-switch race did not make one lookup"
if grep -q . < <(find "$switch_cache" -type f -print -quit); then
    fail "branch-switch race wrote a cache row for the old branch"
fi
export STATUSLINE_GH_MODE=ok
export STATUSLINE_GH_RESPONSE='{"number":1048,"url":"https://example.test/pull/1048","isDraft":false,"reviewDecision":"APPROVED","state":"OPEN"}'
out=$(render_cached "$switch_cache" 30 "$payload")
case "$out" in *'PR #1048 ✓'*) ;; *) fail "new branch did not refresh its own PR after a discarded lookup: $out" ;; esac
[ "$(wc -l <"$STATUSLINE_GH_LOG")" -eq 2 ] || fail "new branch reused a discarded old-branch lookup"
unset STATUSLINE_GIT_HEAD STATUSLINE_GH_SWITCH_HEAD
: >"$STATUSLINE_GH_LOG"
: >"$STATUSLINE_TIMEOUT_LOG"

echo "==> branch and repository cache keys do not reuse another PR"
printf '%s\n' 'ref: refs/heads/statusline/other-branch' >"$fixture_repo/.git/HEAD"
export STATUSLINE_GH_RESPONSE='{"number":1043,"url":"https://example.test/pull/1043","isDraft":false,"reviewDecision":"REVIEW_REQUIRED","state":"OPEN"}'
out=$(render_cached "$cache_dir" 30 "$payload")
case "$out" in *'PR #1043 ⋯'*) ;; *) fail "branch-keyed cache reused the old PR: $out" ;; esac
[ "$(wc -l <"$STATUSLINE_GH_LOG")" -eq 1 ] || fail "new branch did not make one lookup"
fixture_other_repo="$statusline_tmp/other-repo"
mkdir -p "$fixture_other_repo/.git"
printf '%s\n' 'ref: refs/heads/statusline/other-branch' >"$fixture_other_repo/.git/HEAD"
other_payload=$(printf '{"workspace":{"current_dir":"%s"}}' "$fixture_other_repo")
export STATUSLINE_GH_RESPONSE='{"number":1044,"url":"https://example.test/pull/1044","isDraft":true,"reviewDecision":"APPROVED","state":"OPEN"}'
out=$(render_cached "$cache_dir" 30 "$other_payload")
case "$out" in *'PR #1044'*) ;; *) fail "repository-keyed cache reused another repository's PR: $out" ;; esac
case "$out" in *'✓'* | *'✗'* | *'⋯'*) fail "draft fallback invented a review glyph: $out" ;; esac
[ "$(wc -l <"$STATUSLINE_GH_LOG")" -eq 2 ] || fail "new repository did not make one lookup"

echo "==> failures are capped and negative-cached"
failure_cache="$statusline_tmp/failure-cache"
: >"$STATUSLINE_GH_LOG"
: >"$STATUSLINE_TIMEOUT_LOG"
export STATUSLINE_TIMEOUT_MODE=fail
out=$(render_cached "$failure_cache" 30 "$payload")
case "$out" in *'PR #'*) fail "bounded lookup failure rendered a PR: $out" ;; esac
[ "$(wc -l <"$STATUSLINE_GH_LOG")" -eq 0 ] || fail "timed-out lookup reached gh"
[ "$(wc -l <"$STATUSLINE_TIMEOUT_LOG")" -eq 1 ] || fail "failure did not use the one-second timeout"
out=$(render_cached "$failure_cache" 30 "$payload")
case "$out" in *'PR #'*) fail "negative cache rendered a PR: $out" ;; esac
[ "$(wc -l <"$STATUSLINE_TIMEOUT_LOG")" -eq 1 ] || fail "negative cache retried before its ten-second TTL"
export STATUSLINE_TIMEOUT_MODE=run

echo "==> expired positive cache is never reused when refresh cannot run"
stale_cache="$statusline_tmp/stale-cache"
: >"$STATUSLINE_GH_LOG"
: >"$STATUSLINE_TIMEOUT_LOG"
export STATUSLINE_GH_RESPONSE='{"number":1045,"url":"https://example.test/pull/1045","isDraft":false,"reviewDecision":"APPROVED","state":"OPEN"}'
out=$(render_cached "$stale_cache" 30 "$payload")
case "$out" in *'PR #1045 ✓'*) ;; *) fail "fresh cache did not seed the stale-cache regression: $out" ;; esac
[ "$(wc -l <"$STATUSLINE_GH_LOG")" -eq 1 ] || fail "stale-cache setup did not call gh"
[ "$(wc -l <"$STATUSLINE_TIMEOUT_LOG")" -eq 1 ] || fail "stale-cache setup did not invoke timeout"
stale_files=("$stale_cache"/*)
[ "${#stale_files[@]}" -eq 1 ] || fail "stale-cache setup did not write exactly one cache row"
IFS=$'\t' read -r _ stale_kind stale_number stale_url stale_state <"${stale_files[0]}"
printf '0\t%s\t%s\t%s\t%s\n' "$stale_kind" "$stale_number" "$stale_url" "$stale_state" >"${stale_files[0]}"
missing_refresh_dir="$statusline_tmp/missing-refresh"
mkdir -p "$missing_refresh_dir"
for tool in jq date sha256sum shasum; do
    tool_path=$(command -v "$tool" || true)
    [ -z "$tool_path" ] || ln -s "$tool_path" "$missing_refresh_dir/$tool"
done
out=$(PATH="$missing_refresh_dir" STATUSLINE_PR_LOOKUP_ENABLED=1 \
    STATUSLINE_PR_CACHE_DIR="$stale_cache" NO_COLOR=1 \
    STATUSLINE_HYPERLINK=0 "$bash_bin" "$sl" <<<"$payload")
case "$out" in *'PR #'*) fail "expired positive cache rendered without refresh tools: $out" ;; esac
[ "$(wc -l <"$STATUSLINE_GH_LOG")" -eq 1 ] || fail "missing refresh tools unexpectedly called gh"
[ "$(wc -l <"$STATUSLINE_TIMEOUT_LOG")" -eq 1 ] || fail "missing refresh tools unexpectedly called timeout"

echo "==> payload PR remains authoritative and runtime disable skips lookup"
: >"$STATUSLINE_GH_LOG"
: >"$STATUSLINE_TIMEOUT_LOG"
payload_with_pr=$(printf '{"workspace":{"current_dir":"%s"},"pr":{"number":999}}' "$fixture_repo")
out=$(render_cached "$statusline_tmp/payload-cache" 30 "$payload_with_pr")
case "$out" in *'PR #999'*) ;; *) fail "payload PR did not win over fallback: $out" ;; esac
[ ! -s "$STATUSLINE_GH_LOG" ] || fail "payload PR unexpectedly queried gh"
[ ! -s "$STATUSLINE_TIMEOUT_LOG" ] || fail "payload PR unexpectedly invoked timeout"
PATH="$stub_dir:$PATH" STATUSLINE_PR_LOOKUP_ENABLED=0 \
    STATUSLINE_PR_CACHE_DIR="$statusline_tmp/disabled-cache" NO_COLOR=1 \
    STATUSLINE_HYPERLINK=0 "$bash_bin" "$sl" <<<"$payload" >/dev/null
[ ! -s "$STATUSLINE_GH_LOG" ] || fail "runtime-disabled fallback unexpectedly queried gh"
[ ! -s "$STATUSLINE_TIMEOUT_LOG" ] || fail "runtime-disabled fallback unexpectedly invoked timeout"

echo "==> missing gh and timeout leave the PR segment empty"
missing_tools_dir="$statusline_tmp/missing-tools"
mkdir -p "$missing_tools_dir"
for tool in jq date sha256sum shasum; do
    tool_path=$(command -v "$tool" || true)
    [ -z "$tool_path" ] || ln -s "$tool_path" "$missing_tools_dir/$tool"
done
out=$(PATH="$missing_tools_dir" STATUSLINE_PR_LOOKUP_ENABLED=1 \
    STATUSLINE_PR_CACHE_DIR="$statusline_tmp/missing-tools-cache" NO_COLOR=1 \
    STATUSLINE_HYPERLINK=0 "$bash_bin" "$sl" <<<"$payload")
case "$out" in *'PR #'*) fail "missing lookup tools rendered a PR: $out" ;; esac

# ---- context window: present, derivable, and unknown ----

echo "==> used_percentage renders as the used figure"
out=$(render '{"workspace":{"current_dir":"/"},"context_window":{"used_percentage":24}}')
case "$out" in *' 24%'*) ;; *) fail "expected 24%, got: $out" ;; esac

echo "==> only remaining_percentage: used is derived from it"
out=$(render '{"workspace":{"current_dir":"/"},"context_window":{"remaining_percentage":70}}')
case "$out" in *' 30%'*) ;; *) fail "expected 30% derived from 70% remaining, got: $out" ;; esac

echo "==> a real 0% still renders as 0% (absence is the only unknown)"
out=$(render '{"workspace":{"current_dir":"/"},"context_window":{"used_percentage":0}}')
case "$out" in *' 0%'*) ;; *) fail "expected a real 0% to render, got: $out" ;; esac
case "$out" in *'context n/a'*) fail "a real 0% must not render as unknown: $out" ;; esac

# The regression the whole file exists for: `used // (100 - (remaining // 100))`
# collapsed to 0 when both were absent, so "unknown" was drawn as an empty
# green bar — the reading a near-full window is most dangerous to get wrong.
echo "==> neither percentage present renders n/a, never 0%"
for payload in \
    '{"workspace":{"current_dir":"/"},"context_window":{"context_window_size":1000000}}' \
    '{"workspace":{"current_dir":"/"}}'; do
    out=$(render "$payload")
    case "$out" in *'context n/a'*) ;; *) fail "expected 'context n/a' for $payload, got: $out" ;; esac
    case "$out" in *'0%'*) fail "unknown context rendered as 0%: $out" ;; esac
    case "$out" in *'left'*) fail "unknown context printed a headroom figure: $out" ;; esac
    case "$out" in *'█'* | *'░'*) fail "unknown context drew a gauge: $out" ;; esac
done

echo "==> a non-numeric percentage is unknown, not 0%"
out=$(render '{"workspace":{"current_dir":"/"},"context_window":{"used_percentage":"n/a"}}')
case "$out" in *'context n/a'*) ;; *) fail "expected a string percentage to read as unknown, got: $out" ;; esac

echo "==> headroom is derived from the same percentage the bar uses"
out=$(render '{"workspace":{"current_dir":"/"},"context_window":{"used_percentage":25,"context_window_size":1000000}}')
case "$out" in *'750k left'*) ;; *) fail "expected '750k left', got: $out" ;; esac

# ---- the surrounding line must survive the unknown case ----

echo "==> the rest of the line still renders when the context is unknown"
out=$(render '{"workspace":{"current_dir":"/"},"model":{"display_name":"Opus 5"},"version":"9.9.9"}')
case "$out" in *'Opus 5'*) ;; *) fail "model missing from an unknown-context render: $out" ;; esac
case "$out" in *'v9.9.9'*) ;; *) fail "version missing from an unknown-context render: $out" ;; esac

echo "==> an empty payload degrades instead of blanking"
out=$(render '')
[ -n "$out" ] || fail "an empty payload produced no output at all"

echo "==> Antigravity payload (conversation_id, model, headroom)"
out=$(render '{"workspace":{"current_dir":"/"},"context_window":{"used_percentage":25,"context_window_size":1000000},"model":{"display_name":"Gemini 3.7 Flash (High)"},"conversation_id":"34ee01b6-2f37-4fe7"}')
case "$out" in *' 25%'*) ;; *) fail "expected 25%, got: $out" ;; esac
case "$out" in *'750k left'*) ;; *) fail "expected '750k left', got: $out" ;; esac
case "$out" in *'Gemini 3.7 Flash (High)'*) ;; *) fail "expected model name, got: $out" ;; esac
case "$out" in *'34ee01b6'*) ;; *) fail "expected session id, got: $out" ;; esac

echo "==> scalar-shaped fields (model, effort, cost as string/numbers) do not crash jq"
out=$(render '{"workspace":"/","model":"gemini-pro","effort":"high","cost":0.12,"thinking":true,"conversation_id":"34ee01b6-2f37-4fe7"}')
case "$out" in *'gemini-pro'*) ;; *) fail "expected scalar model name, got: $out" ;; esac
case "$out" in *'34ee01b6'*) ;; *) fail "expected session id, got: $out" ;; esac

echo "statusline: all cases passed"
