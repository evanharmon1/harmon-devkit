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

[ -r "$sl" ] || {
    echo "TEST FAIL: $sl not found" >&2
    exit 1
}
command -v jq >/dev/null 2>&1 || {
    echo "TEST FAIL: jq is required by the status line and by this suite" >&2
    exit 1
}

fail() {
    echo "TEST FAIL: $*" >&2
    exit 1
}

# render <json> -> the rendered status line, uncolored. current_dir is pinned
# to / so the git probe finds nothing and the output stays identical wherever
# the suite runs (a checkout's own branch would leak into line 1 otherwise).
render() {
    NO_COLOR=1 STATUSLINE_HYPERLINK=0 bash "$sl" <<<"$1"
}

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
out=$(render '{"workspace":{"current_dir":"/"},"context_window":{"used_percentage":25,"context_window_size":1000000},"model":{"display_name":"Gemini 3.1 Pro (High)"},"conversation_id":"34ee01b6-2f37-4fe7"}')
case "$out" in *' 25%'*) ;; *) fail "expected 25%, got: $out" ;; esac
case "$out" in *'750k left'*) ;; *) fail "expected '750k left', got: $out" ;; esac
case "$out" in *'Gemini 3.1 Pro (High)'*) ;; *) fail "expected model name, got: $out" ;; esac
case "$out" in *'34ee01b6'*) ;; *) fail "expected session id, got: $out" ;; esac

echo "==> scalar-shaped fields (model, effort, cost as string/numbers) do not crash jq"
out=$(render '{"workspace":"/","model":"gemini-pro","effort":"high","cost":0.12,"thinking":true,"conversation_id":"34ee01b6-2f37-4fe7"}')
case "$out" in *'gemini-pro'*) ;; *) fail "expected scalar model name, got: $out" ;; esac
case "$out" in *'34ee01b6'*) ;; *) fail "expected session id, got: $out" ;; esac

echo "statusline: all cases passed"
