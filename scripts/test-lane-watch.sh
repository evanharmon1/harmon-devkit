#!/usr/bin/env bash
# Fixture-driven regression tests for the orchestrator lane watcher.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
watcher="$repo_root/ai/skills/universal/orchestrate/assets/lane-watch.sh"
test_tmp="$(mktemp -d -t lane-watch-test-XXXXXX)"
trap 'rm -rf "$test_tmp"' EXIT

bin_dir="$test_tmp/bin"
fixture_dir="$test_tmp/fixtures"
workspace_root="$test_tmp/workspaces"
state_file="$test_tmp/watcher.state"
registry="$test_tmp/agent-registry.json"
mkdir -p "$bin_dir" "$fixture_dir" \
    "$workspace_root/harmon-devkit/.worktrees/alpha" \
    "$workspace_root/harmon-devkit/.worktrees/beta" \
    "$workspace_root/harmon-devkit/.worktrees/gamma"

fail() {
    echo "FAIL: $*" >&2
    exit 1
    return 0
}

assert_line() {
    file=$1
    expected=$2
    grep -Fxq "$expected" "$file" || fail "missing line: $expected"
}

assert_count() {
    file=$1
    expected=$2
    pattern=$3
    actual="$(grep -Ec "$pattern" "$file" || true)"
    [ "$actual" -eq "$expected" ] || fail "expected $expected matches for $pattern, got $actual"
}

cat >"$registry" <<'JSON'
{"finders":[
  {"slug":"local","trusted_actor_id":null},
  {"slug":"codex-cloud","trusted_actor_id":"999"}
]}
JSON

cat >"$workspace_root/harmon-devkit/.worktrees/alpha/.lane-report.md" <<'EOF'
Implementation complete.
MERGE-READY-alpha-n1
EOF

cat >"$bin_dir/herdr" <<'STUB'
#!/usr/bin/env bash
set -u
if [ -f "$WATCH_FIXTURES/cloud-only" ]; then
    printf '%s\n' "$*" >>"$WATCH_FIXTURES/cloud-herdr-calls"
    exit 90
fi
if [ -f "$WATCH_FIXTURES/hang-list" ] && [ "${1:-} ${2:-}" = "agent list" ]; then
    trap '' TERM
    sleep 5
fi
if [ -f "$WATCH_FIXTURES/events-mode" ]; then
    printf '%s\n' "$*" >>"$WATCH_FIXTURES/events-calls"
    case "${1:-} ${2:-}" in
    'agent list')
        [ ! -f "$WATCH_FIXTURES/events-fail-list" ] || exit 92
        if [ -f "$WATCH_FIXTURES/events-absent" ]; then
            printf '%s\n' '{"result":{"agents":[]}}'
            exit 0
        fi
        revision="$(cat "$WATCH_FIXTURES/events-revision")"
        printf '{"result":{"agents":[{"name":"events","agent_status":"%s","revision":%s,"state_change_seq":1}]}}\n' "$(cat "$WATCH_FIXTURES/events-status" 2>/dev/null || printf idle)" "$revision"
        exit 0
        ;;
    'agent explain')
        [ ! -f "$WATCH_FIXTURES/events-fail-explain" ] || exit 92
        if [ -f "$WATCH_FIXTURES/events-malformed-explain" ]; then
            printf '%s\n' 'not json'
            exit 0
        fi
        if [ -f "$WATCH_FIXTURES/events-fallback" ]; then
            printf '%s\n' '{"fallback_reason":"default_known_agent_idle_fallback"}'
        else
            printf '%s\n' '{"fallback_reason":null}'
        fi
        exit 0
        ;;
    'agent read')
        [ ! -f "$WATCH_FIXTURES/events-fail-visible" ] || [ "${5:-}" != visible ] || exit 92
        cat "$WATCH_FIXTURES/events-pane"; exit 0 ;;
    esac
fi
if [ "${1:-} ${2:-}" = "agent explain" ]; then
    printf '%s\n' '{"fallback_reason":null}'
    exit 0
fi
if [ "${1:-} ${2:-}" = "agent list" ]; then
    if [ -f "$WATCH_FIXTURES/malformed-list" ]; then
        printf '%s\n' '{"error":"temporarily unavailable"}'
        exit 0
    fi
    printf '%s\n' '{"result":{"agents":[{"name":"alpha","agent_status":"working"},{"name":"beta","agent_status":"idle"},{"name":"gamma","agent_status":"blocked"}]}}'
    exit 0
fi
if [ "${1:-} ${2:-}" = "agent read" ]; then
    lane=${3:-}
    source=${5:-}
    if [ "$source" = recent-unwrapped ]; then
        case "$lane" in
        beta)
            if [ -f "$WATCH_FIXTURES/pane-handoff" ]; then
                printf '%s\n' 'DRAFT-PUBLISHED-beta-n2'
            else
                printf '%s\n' 'BLOCKED-beta-n2'
            fi
            ;;
        gamma) printf '%s\n' 'When complete, print:' 'BLOCKED-gamma-n3' 'Continue with the task.' ;;
        esac
    elif [ "$source" = visible ] && [ "$lane" = beta ]; then
        printf '%s\n' 'Usage limit reached'
    fi
    exit 0
fi
exit 90
STUB

cat >"$bin_dir/gh" <<'STUB'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >>"$WATCH_FIXTURES/gh-calls"
if [ -f "$WATCH_FIXTURES/rate-mode" ] && {
    [[ "$*" == *reviews?per_page=100* ]] ||
        { [[ "$(cat "$WATCH_FIXTURES/rate-mode")" == *-cobra ]] && [ "${1:-}" = pr ]; }
}; then
    printf '%s\n' rate >>"$WATCH_FIXTURES/rate-calls"
    case "$(cat "$WATCH_FIXTURES/rate-mode")" in
    primary) printf '< HTTP/2.0 403 Forbidden\n< X-RateLimit-Remaining: 0\n< X-RateLimit-Reset: %s\n{ "message": "API rate limit exceeded" }\n' "$(cat "$WATCH_FIXTURES/rate-reset")" >&2; exit 1 ;;
    secondary) printf '< HTTP/2.0 429 Too Many Requests\n< X-RateLimit-Remaining: 100\n< X-RateLimit-Reset: %s\n' "$(cat "$WATCH_FIXTURES/rate-reset")" >&2; exit 1 ;;
    retry) printf '< HTTP/2.0 403 Forbidden\n< X-RateLimit-Reset: %s\n< Retry-After: 120\n' "$(cat "$WATCH_FIXTURES/rate-reset")" >&2; exit 1 ;;
    remaining) printf '< HTTP/2.0 200 OK\n< X-RateLimit-Remaining: 0\n< X-RateLimit-Reset: %s\n' "$(cat "$WATCH_FIXTURES/rate-reset")" >&2; printf '%s\n' '[]'; exit 0 ;;
    primary-api) printf '< X-RateLimit-Reset: %s\ngh: API rate limit exceeded for user ID 1 (HTTP 403)\n' "$(cat "$WATCH_FIXTURES/rate-reset")" >&2; exit 1 ;;
    secondary-api) printf '< X-RateLimit-Reset: %s\ngh: You have exceeded a secondary rate limit. (HTTP 403)\n' "$(cat "$WATCH_FIXTURES/rate-reset")" >&2; exit 1 ;;
    primary-http-cobra) printf '< X-RateLimit-Reset: %s\nHTTP 403: API rate limit exceeded for user ID 1 (https://api.github.com/graphql)\n' "$(cat "$WATCH_FIXTURES/rate-reset")" >&2; exit 1 ;;
    primary-graphql-cobra) printf '< X-RateLimit-Reset: %s\nGraphQL: API rate limit exceeded for user ID 1 (repository.pullRequest)\n' "$(cat "$WATCH_FIXTURES/rate-reset")" >&2; exit 1 ;;
    secondary-403-cobra) printf '< HTTP/2.0 403 Forbidden\n< X-RateLimit-Reset: %s\nHTTP 403: You have exceeded a secondary rate limit. (https://api.github.com/graphql)\n' "$(cat "$WATCH_FIXTURES/rate-reset")" >&2; exit 1 ;;
    secondary-graphql-cobra) printf '< X-RateLimit-Reset: %s\nGraphQL: You have exceeded a secondary rate limit. (repository.pullRequest)\n' "$(cat "$WATCH_FIXTURES/rate-reset")" >&2; exit 1 ;;
    missing-reset) printf '< HTTP/2.0 403 Forbidden\n< X-RateLimit-Remaining: 0\n' >&2; exit 1 ;;
    body-line) printf '< HTTP/2.0 200 OK\n< X-RateLimit-Remaining: 100\n\nx-ratelimit-remaining: 0\nx-ratelimit-reset: 2000201200\n' >&2 ;;
    graphql-object) printf '%s\n' '{"errors":[{"type":"RATE_LIMITED"}]}'; exit 1 ;;
    graphql-slurp) printf '%s\n' '[{"errors":[{"type":"RATE_LIMITED"}]}]'; exit 1 ;;
    body) printf '< HTTP/2.0 200 OK\n< X-RateLimit-Remaining: 100\n< X-RateLimit-Reset: %s\n\n[{"body":"x-ratelimit-remaining: 0 secondary 429"}]\n' "$(cat "$WATCH_FIXTURES/rate-reset")" >&2 ;;
    esac
fi
if [ "${1:-} ${2:-}" = "pr list" ]; then
    if [ -f "$WATCH_FIXTURES/cross-deadline" ]; then
        cp "$WATCH_FIXTURES/cross-deadline" "$WATCH_CLOCK"
        exit 92
    fi
    if [ -f "$WATCH_FIXTURES/hang-pr-list" ]; then
        sleep 3
    fi
    if [ -f "$WATCH_FIXTURES/fail-pr-list" ]; then
        exit 92
    fi
    if [ -f "$WATCH_FIXTURES/malformed-pr-list" ]; then
        printf '%s\n' '[{"error":"partial response"}]'
        exit 0
    fi
    if [ -f "$WATCH_FIXTURES/transient-pr-list" ]; then
        remaining="$(<"$WATCH_FIXTURES/transient-pr-list")"
        if [ "$remaining" -gt 0 ]; then
            printf '%s\n' "$((remaining - 1))" >"$WATCH_FIXTURES/transient-pr-list"
            exit 92
        fi
    fi
    branch=
    previous=
    for arg in "$@"; do
        if [ "$previous" = --head ]; then branch=$arg; fi
        previous=$arg
    done
    if [ -f "$WATCH_FIXTURES/fail-branch-alpha-pr-list" ] && [ "$branch" = branch-alpha ]; then
        count_file="$WATCH_FIXTURES/alpha-pr-list-attempts"
        count=0
        [ ! -f "$count_file" ] || count="$(<"$count_file")"
        count=$((count + 1))
        printf '%s\n' "$count" >"$count_file"
        exit 92
    fi
    if [ "$branch" = branch-healthy ]; then
        count_file="$WATCH_FIXTURES/healthy-pr-list-calls"
        count=0
        [ ! -f "$count_file" ] || count="$(<"$count_file")"
        count=$((count + 1))
        printf '%s\n' "$count" >"$count_file"
        printf '%s\n' '[]'
        exit 0
    fi
    if [ "$branch" = branch-theta ] && [ -f "$WATCH_FIXTURES/dormant-pr-json" ]; then
        cat "$WATCH_FIXTURES/dormant-pr-json"
        exit 0
    fi
    if [ "$branch" = claude/cloud-fixture ]; then
        cat "$WATCH_FIXTURES/cloud-pr.json"
        exit 0
    fi
    if [ "$branch" != branch-alpha ]; then
        printf '%s\n' '[]'
        exit 0
    fi
    count_file="$WATCH_FIXTURES/pr-count"
    count=0
    [ ! -f "$count_file" ] || count="$(<"$count_file")"
    count=$((count + 1))
    printf '%s\n' "$count" >"$count_file"
    printf '%s\n' "$count" >"$WATCH_FIXTURES/phase"
    case "$count" in
    1) printf '%s\n' '[{"number":77,"isDraft":true,"state":"OPEN","headRefOid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]' ;;
    2) if [ -f "$WATCH_FIXTURES/skip-ready" ]; then
        printf '%s\n' '[{"number":77,"isDraft":false,"state":"MERGED","headRefOid":"aaaaaaaabbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}]'
    else
        printf '%s\n' '[{"number":77,"isDraft":true,"state":"OPEN","headRefOid":"aaaaaaaabbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}]'
    fi ;;
    3 | 4) printf '%s\n' '[{"number":77,"isDraft":false,"state":"OPEN","headRefOid":"aaaaaaaabbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}]' ;;
    *) printf '%s\n' '[{"number":77,"isDraft":false,"state":"MERGED","headRefOid":"aaaaaaaabbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}]' ;;
    esac
    exit 0
fi

fixture_head=aaaaaaaabbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
if [[ "$*" == *number=88* ]] || [ "${3:-}" = 88 ]; then
    fixture_head=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
elif [ "$(cat "$WATCH_FIXTURES/phase" 2>/dev/null || true)" = 1 ]; then
    fixture_head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
fi
if [ "${1:-} ${2:-}" = 'pr view' ]; then
    if [ -f "$WATCH_FIXTURES/pr-read-mode" ]; then
        case "$(cat "$WATCH_FIXTURES/pr-read-mode")" in
        outage-502)
            # A slow failure must not push the next PR poll out another interval.
            clock_now="$(cat "$WATCH_CLOCK")"
            printf '%s\n' "$((clock_now + 1))" >"$WATCH_CLOCK"
            echo 'HTTP 502: Server Error (https://api.github.com/graphql)' >&2
            exit 1
            ;;
        timeout) exit 124 ;;
        transport) echo 'error connecting to api.github.com' >&2; exit 1 ;;
        not-found-repository) echo "GraphQL: Could not resolve to a Repository with the name 'evanharmon1/zz-no-such-repo-1627'. (repository)" >&2; exit 1 ;;
        not-found-404) printf '< HTTP/2.0 404 Not Found\nHTTP 404: Not Found (https://api.github.com/graphql)\n' >&2; exit 1 ;;
        esac
    fi
    if [ "${3:-}" = 999999 ]; then
        printf '%s\n' typo >>"$WATCH_FIXTURES/typo-calls"
        echo 'GraphQL: Could not resolve to a PullRequest with the number of 999999.' >&2
        exit 1
    fi
    if [ "${*: -1}" = baseRefName,headRefOid ]; then
        if [ -f "$WATCH_FIXTURES/life-meta.json" ]; then cat "$WATCH_FIXTURES/life-meta.json"; else
            printf '{"baseRefName":"release#1","headRefOid":"%s"}\n' "$fixture_head"
        fi
    else
        cat "$WATCH_FIXTURES/life-pr.json"
    fi
    exit 0
fi
if [ "${1:-} ${2:-}" = 'api graphql' ]; then
    if [[ "$*" == *reviewThreads* ]]; then
        if [ -f "$WATCH_FIXTURES/graphql-read-mode" ]; then
            case "$(cat "$WATCH_FIXTURES/graphql-read-mode")" in
            not-found-object) printf '%s\n' '{"errors":[{"type":"NOT_FOUND"}]}'; exit 1 ;;
            not-found-slurp) printf '%s\n' '[{"errors":[{"type":"NOT_FOUND"}]}]'; exit 1 ;;
            not-found-header-404)
                printf '< HTTP/2.0 404 Not Found\n' >&2
                printf '%s\n' '{"message":"Not Found"}'
                exit 1
                ;;
            esac
        fi
        if [ -f "$WATCH_FIXTURES/move-head" ]; then
            cp "$WATCH_FIXTURES/move-head" "$WATCH_FIXTURES/life-pr.json"
            rm "$WATCH_FIXTURES/move-head"
        fi
        [ ! -f "$WATCH_FIXTURES/fail-threads" ] || exit 92
        if [ -f "$WATCH_FIXTURES/threads.json" ]; then cat "$WATCH_FIXTURES/threads.json"; else
            printf '[{"data":{"repository":{"pullRequest":{"headRefOid":"%s","reviewThreads":{"nodes":[]}}}}}]\n' "$fixture_head"
        fi
    else
        if [ -f "$WATCH_FIXTURES/ci.json" ]; then cat "$WATCH_FIXTURES/ci.json"; else
            printf '[{"data":{"repository":{"pullRequest":{"headRefOid":"%s","commits":{"nodes":[{"commit":{"statusCheckRollup":null}}]}}}}}]\n' "$fixture_head"
        fi
    fi
    exit 0
fi
if [ "${1:-}" = api ]; then
    endpoint=${*: -1}
    if [ "$endpoint" = repos/evanharmon1/harmon-devkit/git/ref/heads/claude/cloud-fixture ]; then
        if [ -f "$WATCH_FIXTURES/fail-cloud-branch" ]; then
            echo 'HTTP 502: Server Error (https://api.github.com/repos/evanharmon1/harmon-devkit/git/ref/heads/claude/cloud-fixture)' >&2
            exit 1
        fi
        if [ -f "$WATCH_FIXTURES/cloud-branch-absent" ]; then
            printf 'HTTP/2.0 404 Not Found\n\n{"message":"Not Found"}\n'
            exit 1
        fi
        printf 'HTTP/2.0 200 OK\n\n'
        cat "$WATCH_FIXTURES/cloud-branch.json"
        exit 0
    fi
    if [ -f "$WATCH_FIXTURES/life-mode" ]; then
        case "$endpoint" in
        */compare/*)
            printf '%s\n' compare >>"$WATCH_FIXTURES/compare-calls"
            cat "$WATCH_FIXTURES/compare.json" ;;
        */reviews?per_page=100)
            [ ! -f "$WATCH_FIXTURES/fail-activity" ] || exit 92
            cat "$WATCH_FIXTURES/reviews.json" ;;
        */issues/*/comments?per_page=100)
            if [ -f "$WATCH_FIXTURES/comments.json" ]; then cat "$WATCH_FIXTURES/comments.json"; else printf '%s\n' '[]'; fi ;;
        */pulls/*/comments?per_page=100)
            printf '%s\n' '[{"id":812,"created_at":"2033-05-18T03:33:20Z","user":{"id":123,"login":"untrusted-bot","type":"Bot"}}]' ;;
        *) printf '%s\n' '[]' ;;
        esac
        exit 0
    fi
    if [[ "$endpoint" == repos/*/compare/* ]]; then
        printf '%s\n' '{"behind_by":0,"base_commit":{"sha":"cccccccccccccccccccccccccccccccccccccccc"}}'
        exit 0
    fi
    if [ "$endpoint" = graphql ]; then exit 91; fi
    printf '%s\n' '[]'
    exit 0
fi
exit 90
STUB
chmod +x "$bin_dir/herdr" "$bin_dir/gh"

# A narrowly-scoped `mv` stub: root bypasses chmod's discretionary permission
# checks entirely, so a `chmod 555` fixture can't simulate an unpersistable
# state directory in a root-run container. Fail only the exact rename
# persist_state() performs into the persistfail fixture directory (gated
# behind $WATCH_FIXTURES/fail-mv); every other `mv` -- the test harness's own,
# and persist_state() calls for every other test in this file -- passes
# straight through to the real binary, resolved once here before bin_dir ever
# shadows PATH.
real_mv="$(command -v mv)"
cat >"$bin_dir/mv" <<STUB
#!/usr/bin/env bash
set -u
if [ -f "\${WATCH_FIXTURES:-}/fail-mv" ]; then
    for arg in "\$@"; do
        case "\$arg" in
        */persist-fail-state/*) exit 1 ;;
        esac
    done
fi
exec "$real_mv" "\$@"
STUB
chmod +x "$bin_dir/mv"

export PATH="$bin_dir:$PATH"
export WATCH_FIXTURES="$fixture_dir"

common_args=(
    --state-file "$state_file"
    --registry "$registry"
    --workspace-root "$workspace_root"
    --interval-seconds 0
    --timeout-seconds 1
    2099-01-01T00:00:00Z
    alpha:branch-alpha:n1:evanharmon1/harmon-devkit
    beta:branch-beta:n2:evanharmon1/harmon-devkit
    gamma:branch-gamma:n3:evanharmon1/harmon-devkit
)

# #1220: render the real brief and validate its envelope, then consume each
# declared sentinel from its declared nonce-scoped report under a common Git
# directory. herdr's lowercase agent and the brief's lane label are distinct.
parity_dir="$test_tmp/common git/.git/dev-flow-v2/runs/parity"
mkdir -p "$parity_dir"
parity_report="$parity_dir/lane-report-parity1.md"
parity_brief="$parity_dir/brief.md"
python3 - "$repo_root" "$parity_report" "$parity_brief" <<'PYTHON'
import json, pathlib, re, sys
root, report, output = sys.argv[1:]
root = pathlib.Path(root)
fixture = (root / "ai/schemas/fixtures/brief.envelope/valid/minimal.md").read_text()
envelope = json.loads(re.search(r"```json\n(.*?)\n```", fixture, re.S)[1])
envelope["report_path"] = report
prefixes = {"ready": "MERGE-READY", "handoff": "DRAFT-PUBLISHED", "blocked": "BLOCKED"}
envelope["sentinels"] = {kind: f"{prefixes[kind]}-L-d1220-parity1"
                         for kind in prefixes}
envelope["sentinels"]["attempt_nonce"] = "parity1"
source = (root / "ai/skills/universal/orchestrate/assets/lane-brief.md").read_text()
values = {key: "fixture-" + key for key in re.findall(r"\{\{([^}]+)\}\}", source)}
values.update({"brief-envelope-json": json.dumps(envelope), "report-path": report,
               "lane-name": "L-d1220", "attempt-nonce": "parity1"})
values.update({kind + "-sentinel": prefixes[kind] + "-L-d1220"
               for kind in prefixes})
rendered = re.sub(r"\{\{([^}]+)\}\}", lambda m: values[m[1]], source)
pathlib.Path(output).write_text(rendered)
# Extract what the reporting protocol actually renders rather than duplicating
# its placeholder ordering in the shell test.
reporting = rendered.split("## Reporting protocol\n", 1)[1]
sentinels = re.findall(r"^  - `((?:MERGE-READY|DRAFT-PUBLISHED|BLOCKED)-[^`]+)`", reporting, re.M)
assert set(sentinels) == {envelope["sentinels"][kind]
                          for kind in ("ready", "handoff", "blocked")}
pathlib.Path(output + ".sentinels").write_text("\n".join(sentinels) + "\n")
PYTHON
node "$repo_root/ai/skills/universal/dev-flow-support/assets/validate-result-schemas.mjs" \
    brief "$parity_brief" >/dev/null || fail "rendered watcher brief fails validation"
parity_state="$parity_dir/watcher.state"
parity_args=(--iterations 1 --state-file "$parity_state" --registry "$registry"
    --workspace-root "$workspace_root" --interval-seconds 0 --timeout-seconds 1
    2099-01-01T00:00:00Z
    "alpha:branch-parity:parity1:evanharmon1/harmon-devkit:$parity_report:L-d1220")
while IFS= read -r terminal; do
    printf 'Worker result.\n%s\n\n' "$terminal" >"$parity_report"
    bash "$watcher" "${parity_args[@]}" >"$parity_dir/$terminal.out"
    assert_line "$parity_dir/$terminal.out" "SENTINEL alpha: $terminal"
    if [[ "$terminal" = DRAFT-PUBLISHED-* ]]; then
        assert_line "$parity_dir/$terminal.out" "DRAFT-PUBLISHED alpha: $terminal"
    else
        assert_count "$parity_dir/$terminal.out" 0 '^DRAFT-PUBLISHED '
    fi
    # Restarting against durable state does not repeat the transition.
    bash "$watcher" "${parity_args[@]}" >"$parity_dir/restart.out"
    assert_count "$parity_dir/restart.out" 0 '^(SENTINEL|DRAFT-PUBLISHED) '
done <"$parity_brief.sentinels"

# A valid sentinel followed by prose, a stale attempt, another lane's signal,
# whitespace and a partial/embedded signal must all stay invisible.
for bad_terminal in \
    $'DRAFT-PUBLISHED-L-d1220-parity1\nStill working.' \
    'HANDOFF-L-d1220-parity1' \
    'READY-L-d1220-parity1' \
    'DRAFT-PUBLISHED-L-d1220-oldnonce' \
    'DRAFT-PUBLISHED-L-other-parity1' \
    ' DRAFT-PUBLISHED-L-d1220-parity1' \
    'DRAFT-PUBLISHED-L-d1220-parity1 extra' \
    'prefix DRAFT-PUBLISHED-L-d1220-parity1'; do
    printf '%s\n' "$bad_terminal" >"$parity_report"
    # Fresh state makes rejection independent of the dedup above.
    bash "$watcher" --iterations 1 --registry "$registry" \
        --workspace-root "$workspace_root" --interval-seconds 0 --timeout-seconds 1 \
        2099-01-01T00:00:00Z \
        "alpha:branch-parity:parity1:evanharmon1/harmon-devkit:$parity_report:L-d1220" \
        >"$parity_dir/rejected.out"
    assert_count "$parity_dir/rejected.out" 0 '^(SENTINEL|DRAFT-PUBLISHED) '
done

# Report-only extension defaults the label to the agent; pane publications use
# the same grammar and retain the advisory pane-only tag.
printf '%s\n' 'DRAFT-PUBLISHED-alpha-parity1' >"$parity_report"
bash "$watcher" --iterations 1 --registry "$registry" --interval-seconds 0 \
    --timeout-seconds 1 2099-01-01T00:00:00Z \
    "alpha:branch-parity:parity1:evanharmon1/harmon-devkit:$parity_report" \
    >"$parity_dir/default-label.out"
assert_line "$parity_dir/default-label.out" 'DRAFT-PUBLISHED alpha: DRAFT-PUBLISHED-alpha-parity1'
touch "$fixture_dir/pane-handoff"
bash "$watcher" --iterations 1 --registry "$registry" --workspace-root "$workspace_root" \
    --interval-seconds 0 --timeout-seconds 1 2099-01-01T00:00:00Z \
    beta:branch-beta:n2:evanharmon1/harmon-devkit >"$parity_dir/pane.out"
assert_line "$parity_dir/pane.out" 'SENTINEL beta: DRAFT-PUBLISHED-beta-n2 (pane only)'
assert_line "$parity_dir/pane.out" 'DRAFT-PUBLISHED beta: DRAFT-PUBLISHED-beta-n2 (pane only)'
# INT1 / integration-r1-codex-cloud-1: pane advisory must not consume the
# later report confirmation. Each invocation restarts the watcher, testing
# that both source facts survive persistence rather than only live memory.
source_report="$parity_dir/source-report.md"
source_state="$parity_dir/source.state"
source_args=(--iterations 1 --state-file "$source_state" --registry "$registry"
    --workspace-root "$workspace_root" --interval-seconds 0 --timeout-seconds 1
    2099-01-01T00:00:00Z
    "beta:branch-beta:n2:evanharmon1/harmon-devkit:$source_report")
source_out="$parity_dir/source.out"
bash "$watcher" "${source_args[@]}" >"$source_out"
bash "$watcher" "${source_args[@]}" >>"$source_out"
assert_count "$source_out" 1 '^SENTINEL beta: DRAFT-PUBLISHED-beta-n2 \(pane only\)$'
assert_count "$source_out" 1 '^DRAFT-PUBLISHED beta: DRAFT-PUBLISHED-beta-n2 \(pane only\)$'
printf '%s\n' 'DRAFT-PUBLISHED-beta-n2' >"$source_report"
bash "$watcher" "${source_args[@]}" >>"$source_out"
assert_count "$source_out" 1 '^SENTINEL beta: DRAFT-PUBLISHED-beta-n2$'
assert_count "$source_out" 1 '^DRAFT-PUBLISHED beta: DRAFT-PUBLISHED-beta-n2$'
bash "$watcher" "${source_args[@]}" >"$parity_dir/source-restart.out"
assert_count "$parity_dir/source-restart.out" 0 '^(SENTINEL|DRAFT-PUBLISHED) '
# Even if the report later has no terminal line, confirmation suppresses a
# pane fallback for that same sentinel across restart.
printf '%s\n' 'Report continuing.' >"$source_report"
bash "$watcher" "${source_args[@]}" >"$parity_dir/source-fallback.out"
assert_count "$parity_dir/source-fallback.out" 0 '^(SENTINEL|DRAFT-PUBLISHED) '

# Report-first: only the untagged pair, never a later pane-only duplicate.
rm "$source_state"
printf '%s\n' 'DRAFT-PUBLISHED-beta-n2' >"$source_report"
bash "$watcher" "${source_args[@]}" >"$source_out"
assert_line "$source_out" 'SENTINEL beta: DRAFT-PUBLISHED-beta-n2'
assert_line "$source_out" 'DRAFT-PUBLISHED beta: DRAFT-PUBLISHED-beta-n2'
printf '%s\n' 'Report continuing.' >"$source_report"
bash "$watcher" "${source_args[@]}" >>"$source_out"
assert_count "$source_out" 1 '^SENTINEL beta:'
assert_count "$source_out" 1 '^DRAFT-PUBLISHED beta:'
assert_count "$source_out" 0 '\(pane only\)'

# Adopting a source-less legacy state must not lose report confirmation.
printf 'SENTINEL\tbeta\tDRAFT-PUBLISHED-beta-n2\t\n' >"$source_state"
printf '%s\n' 'DRAFT-PUBLISHED-beta-n2' >"$source_report"
bash "$watcher" "${source_args[@]}" >"$source_out"
assert_line "$source_out" 'SENTINEL beta: DRAFT-PUBLISHED-beta-n2'
assert_line "$source_out" 'DRAFT-PUBLISHED beta: DRAFT-PUBLISHED-beta-n2'
bash "$watcher" "${source_args[@]}" >"$parity_dir/legacy-restart.out"
assert_count "$parity_dir/legacy-restart.out" 0 '^(SENTINEL|DRAFT-PUBLISHED) '
rm "$fixture_dir/pane-handoff"

for invalid_spec in \
    'alpha:branch-parity:parity1:evanharmon1/harmon-devkit:relative/report:L-d1220' \
    "alpha:branch-parity:parity1:evanharmon1/harmon-devkit:$parity_report:L[1220" \
    "alpha:branch-parity:parity1:evanharmon1/harmon-devkit:$parity_report:L-d1220:extra" \
    'alpha:branch-parity:parity1:evanharmon1/harmon-devkit:cloud:L-d1220'; do
    invalid_rc=0
    bash "$watcher" --iterations 1 --registry "$registry" --interval-seconds 0 \
        2099-01-01T00:00:00Z "$invalid_spec" >"$parity_dir/invalid.err" 2>&1 || invalid_rc=$?
    [ "$invalid_rc" -eq 2 ] || fail "invalid spec did not exit 2: $invalid_spec"
done

# No-worktree lanes observe the pushed branch and PR without any local agent
# calls. A later poisoned local report must still be ignored, including after
# a restart, while branch/head transitions remain visible and deduplicated.
cloud_out="$test_tmp/cloud.out"
cloud_state="$test_tmp/cloud.state"
touch "$fixture_dir/cloud-only"
printf '%s\n' '{"ref":"refs/heads/claude/cloud-fixture","object":{"type":"commit","sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}' >"$fixture_dir/cloud-branch.json"
printf '%s\n' '[]' >"$fixture_dir/cloud-pr.json"
cloud_args=(--iterations 1 --state-file "$cloud_state" --registry "$registry"
    --workspace-root "$workspace_root" --interval-seconds 0 --timeout-seconds 1
    2099-01-01T00:00:00Z cloud:claude/cloud-fixture:n4:evanharmon1/harmon-devkit:cloud)
bash "$watcher" "${cloud_args[@]}" >"$cloud_out"
assert_line "$cloud_out" 'BRANCH cloud: claude/cloud-fixture head=aaaaaaaa'
assert_count "$cloud_out" 0 '^(AGENT|SENTINEL|PR) cloud:'
[ ! -e "$workspace_root/harmon-devkit/.worktrees/cloud" ] || fail "cloud fixture unexpectedly has a worktree"
mkdir -p "$workspace_root/harmon-devkit/.worktrees/cloud"
printf '%s\n' 'MERGE-READY-cloud-n4' >"$workspace_root/harmon-devkit/.worktrees/cloud/.lane-report.md"
printf '%s\n' '{"ref":"refs/heads/claude/cloud-fixture","object":{"type":"commit","sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}}' >"$fixture_dir/cloud-branch.json"
printf '%s\n' '[{"number":88,"isDraft":true,"state":"OPEN","headRefOid":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}]' >"$fixture_dir/cloud-pr.json"
bash "$watcher" "${cloud_args[@]}" >>"$cloud_out"
assert_line "$cloud_out" 'BRANCH cloud: claude/cloud-fixture head=bbbbbbbb'
assert_line "$cloud_out" 'PR cloud: #88 draft=true OPEN head=bbbbbbbb'
assert_line "$cloud_out" 'PR-WATCHING cloud: #88 head=bbbbbbbb draft=true'
assert_count "$cloud_out" 0 '^(AGENT|SENTINEL) cloud:'
[ ! -e "$fixture_dir/cloud-herdr-calls" ] || fail "cloud watcher called herdr"
bash "$watcher" "${cloud_args[@]}" >"$test_tmp/cloud-restart.out"
assert_count "$test_tmp/cloud-restart.out" 0 '^(BRANCH|PR) cloud:'
# An absent ref is an observation, even with a zero degradation
# window. It is deduplicated, and a later lane is still observed on each poll.
touch "$fixture_dir/cloud-branch-absent"
rm -f "$fixture_dir/cloud-only"
cloud_absent_out="$test_tmp/cloud-absent.out"
bash "$watcher" --iterations 2 --degrade-window-seconds 0 \
    --state-file "$cloud_state" --registry "$registry" \
    --workspace-root "$workspace_root" --interval-seconds 0 --timeout-seconds 1 \
    2099-01-01T00:00:00Z cloud:claude/cloud-fixture:n4:evanharmon1/harmon-devkit:cloud \
    beta:branch-beta:n2:evanharmon1/harmon-devkit >"$cloud_absent_out"
assert_line "$cloud_absent_out" 'BRANCH cloud: absent'
assert_count "$cloud_absent_out" 1 '^BRANCH cloud: absent$'
assert_count "$cloud_absent_out" 0 '^OBSERVATION-DEGRADED cloud:'
assert_line "$cloud_absent_out" 'AGENT beta: init -> idle'
assert_line "$cloud_absent_out" 'SENTINEL beta: BLOCKED-beta-n2 (pane only)'
bash "$watcher" "${cloud_args[@]}" >"$test_tmp/cloud-absent-restart.out"
assert_count "$test_tmp/cloud-absent-restart.out" 0 '^BRANCH cloud:'
rm -f "$fixture_dir/cloud-branch-absent"

primary_out="$test_tmp/primary.out"
bash "$watcher" --iterations 5 "${common_args[@]}" >"$primary_out"

# Three independently quoted specs pin the zsh word-splitting regression.
assert_line "$primary_out" 'AGENT alpha: init -> working'
assert_line "$primary_out" 'AGENT beta: init -> idle'
assert_line "$primary_out" 'AGENT gamma: init -> blocked'

# Report-file results win; pane-only results are tagged and prompt prose cannot match.
assert_line "$primary_out" 'SENTINEL alpha: MERGE-READY-alpha-n1'
assert_line "$primary_out" 'SENTINEL beta: BLOCKED-beta-n2 (pane only)'
assert_count "$primary_out" 0 '^SENTINEL gamma:'
assert_count "$primary_out" 1 '^SENTINEL alpha:'
assert_count "$primary_out" 1 '^SENTINEL beta:'

assert_line "$primary_out" 'PR alpha: #77 draft=true OPEN head=aaaaaaaa'
assert_count "$primary_out" 2 '^PR alpha: #77 draft=true OPEN head=aaaaaaaa$'
assert_line "$primary_out" 'PR alpha: #77 draft=false OPEN head=aaaaaaaa'
assert_line "$primary_out" 'PR alpha: #77 draft=false MERGED head=aaaaaaaa'
assert_line "$primary_out" 'PR-MERGED alpha: #77 head=aaaaaaaa'
assert_count "$primary_out" 1 '^USAGE-PAUSED beta$'
# #1041: a PR observation that fails once and heals on the very next poll
# degrades exactly once (bounded, non-blocking backoff, not an immediate
# exit) and keeps running -- the episode clears on the recovering success.
# The failing poll schedules its retry 5s out (round 1's own backoff
# schedule) and never sleeps in place (challenge r1 finding 1), so a real
# --interval-seconds longer than that is what lets the second poll land
# after the scheduled retry time.
rm -f "$fixture_dir/pr-count" "$fixture_dir/phase"
printf '%s\n' 1 >"$fixture_dir/transient-pr-list"
transient_out="$test_tmp/transient.out"
transient_state="$test_tmp/transient.state"
bash "$watcher" --iterations 2 --state-file "$transient_state" \
    --registry "$registry" --workspace-root "$workspace_root" \
    --interval-seconds 6 --degrade-window-seconds 60 --timeout-seconds 1 \
    2099-01-01T00:00:00Z alpha:branch-alpha:n1:evanharmon1/harmon-devkit \
    >"$transient_out"
rm -f "$fixture_dir/transient-pr-list"
assert_line "$transient_out" 'OBSERVATION-DEGRADED alpha: GitHub PR observation failed for lane alpha'
assert_count "$transient_out" 1 '^OBSERVATION-DEGRADED '
assert_line "$transient_out" 'PR alpha: #77 draft=true OPEN head=aaaaaaaa'
assert_count "$transient_state" 0 '^DEGRADE[[:space:]]+alpha:PR[[:space:]]+'

# #1041 restart-dedup: a DEGRADE episode already announced (notified=1)
# before a restart must not announce again, even though the underlying
# failure is still ongoing -- only the eventual give-up is new. Seeds the
# real shape the watcher actually writes -- detail "<attempt>:<next_retry_at>"
# with next_retry_at already in the past -- so this restart's one and only
# poll makes a real attempt rather than being skipped (#1041 challenge r2
# finding claude-5: an earlier version of this test seeded an empty detail
# field, describing it as a legacy shape, but no shipped version of this
# file ever wrote DEGRADE without one -- unlike WINDOW's genuine legacy
# shape, that state could never actually occur).
rm -f "$fixture_dir/pr-count" "$fixture_dir/phase"
restart_dedup_state="$test_tmp/restart-dedup.state"
restart_dedup_first_failure=$(($(date -u +%s) - 100))
printf 'DEGRADE\tdelta:PR\t%s\t1\t0:%s\nWALLCLOCK\trun\t0\t\n' \
    "$restart_dedup_first_failure" "$((restart_dedup_first_failure + 5))" \
    >"$restart_dedup_state"
touch "$fixture_dir/malformed-pr-list"
restart_dedup_out="$test_tmp/restart-dedup.out"
restart_dedup_err="$test_tmp/restart-dedup.err"
if bash "$watcher" --iterations 1 --state-file "$restart_dedup_state" \
    --registry "$registry" --workspace-root "$workspace_root" \
    --interval-seconds 0 --degrade-window-seconds 2 --timeout-seconds 1 \
    2099-01-01T00:00:00Z delta:branch-delta:n4:evanharmon1/harmon-devkit \
    >"$restart_dedup_out" 2>"$restart_dedup_err"; then
    fail 'watcher accepted a malformed GitHub PR observation after a restart'
fi
rm "$fixture_dir/malformed-pr-list"
assert_line "$restart_dedup_err" 'lane-watch: GitHub PR observation failed for lane delta'
assert_count "$restart_dedup_out" 0 '^OBSERVATION-DEGRADED '

# #1041 restart-dedup, genuine mid-episode case (challenge r1 finding 5): a
# restart against an episode that has NOT yet exceeded its window must
# resume retrying -- not give up just because a restart happened -- while
# still not re-announcing. Distinct from the case above, which restarts
# against an already-expired episode.
rm -f "$fixture_dir/pr-count" "$fixture_dir/phase"
midepisode_state="$test_tmp/restart-dedup-mid.state"
midepisode_now="$(date -u +%s)"
printf 'DEGRADE\tdelta:PR\t%s\t1\t0:%s\nWALLCLOCK\trun\t0\t\n' \
    "$((midepisode_now - 2))" "$((midepisode_now - 1))" >"$midepisode_state"
touch "$fixture_dir/malformed-pr-list"
midepisode_out="$test_tmp/restart-dedup-mid.out"
bash "$watcher" --iterations 1 --state-file "$midepisode_state" \
    --registry "$registry" --workspace-root "$workspace_root" \
    --interval-seconds 0 --degrade-window-seconds 60 --timeout-seconds 1 \
    2099-01-01T00:00:00Z delta:branch-delta:n4:evanharmon1/harmon-devkit \
    >"$midepisode_out"
rm "$fixture_dir/malformed-pr-list"
assert_count "$midepisode_out" 0 '^OBSERVATION-DEGRADED '
assert_count "$midepisode_state" 1 \
    "^DEGRADE[[:space:]]+delta:PR[[:space:]]+$((midepisode_now - 2))[[:space:]]+1[[:space:]]+1:[0-9]+\$"

# Gemini review (PR #1102): state_get can succeed with an EMPTY string (an
# existing entry whose own field is stored empty) -- the `||` fallback
# elsewhere never catches this since it only fires on state_get FAILURE.
# Pre-seeds a DEGRADE row with an empty extra (notified) field alongside a
# real, non-empty first_failure_at, so observation_record_failure() takes
# the "existing episode" branch (first_failure non-empty) with an
# unguarded-empty notified -- exactly the shape that broke `[ -eq 0 ]`
# before the defensive default. Asserts both that the shell never prints
# the bash integer-expression error AND that the fix actually restores the
# correct behavior (still announces once), not merely avoids a crash.
# The detail field must ALSO be empty here, not merely absent a colon:
# `IFS=$'\t' read` collapses CONSECUTIVE tabs because tab is one of bash's
# IFS-whitespace characters, so an empty field followed by a NON-empty
# later field cannot round-trip through this file's tab-separated state
# format at all (the later field's content shifts left into the empty
# one's slot) -- a pre-existing property of every state kind here, not
# something this fix touches. A trailing empty extra+detail (nothing
# non-empty follows) has no such field to shift into it and round-trips
# correctly, which is what actually exercises state_get returning success
# with an empty string rather than accidentally exercising a corrupted parse.
rm -f "$fixture_dir/pr-count" "$fixture_dir/phase"
degrade_empty_extra_first_failure=$(($(date -u +%s) - 5))
degrade_empty_extra_state="$test_tmp/degrade-empty-extra.state"
printf 'DEGRADE\tdelta:PR\t%s\t\t\nWALLCLOCK\trun\t0\t\n' \
    "$degrade_empty_extra_first_failure" \
    >"$degrade_empty_extra_state"
touch "$fixture_dir/malformed-pr-list"
degrade_empty_extra_out="$test_tmp/degrade-empty-extra.out"
degrade_empty_extra_err="$test_tmp/degrade-empty-extra.err"
bash "$watcher" --iterations 1 --state-file "$degrade_empty_extra_state" \
    --registry "$registry" --workspace-root "$workspace_root" \
    --interval-seconds 0 --degrade-window-seconds 60 --timeout-seconds 1 \
    2099-01-01T00:00:00Z delta:branch-delta:n4:evanharmon1/harmon-devkit \
    >"$degrade_empty_extra_out" 2>"$degrade_empty_extra_err"
rm "$fixture_dir/malformed-pr-list"
assert_count "$degrade_empty_extra_err" 0 'integer expression expected'
assert_line "$degrade_empty_extra_out" 'OBSERVATION-DEGRADED delta: GitHub PR observation failed for lane delta'

clock_bin="$test_tmp/clock-bin"
clock_file="$test_tmp/multilane.clock"
real_date="$(command -v date)"
mkdir -p "$clock_bin"
printf '%s\n' 2000000000 >"$clock_file"
cat >"$clock_bin/date" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [ "$*" = '-u +%s' ]; then
    cat "$WATCH_CLOCK"
else
    exec "$WATCH_REAL_DATE" "$@"
fi
STUB
cat >"$clock_bin/sleep" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[ "$#" -eq 1 ] && [ "$1" = 1 ] || exit 93
now="$(<"$WATCH_CLOCK")"
printf '%s\n' "$((now + 1))" >"$WATCH_CLOCK"
STUB
chmod +x "$clock_bin/date" "$clock_bin/sleep"
rm -f "$fixture_dir/pr-count" "$fixture_dir/phase" "$fixture_dir/healthy-pr-list-calls" \
    "$fixture_dir/alpha-pr-list-attempts"
touch "$fixture_dir/fail-branch-alpha-pr-list"
multilane_out="$test_tmp/multilane.out"
multilane_state="$test_tmp/multilane.state"
PATH="$clock_bin:$PATH" WATCH_CLOCK="$clock_file" WATCH_REAL_DATE="$real_date" \
    bash "$watcher" --iterations 3 --state-file "$multilane_state" \
    --registry "$registry" --workspace-root "$workspace_root" \
    --interval-seconds 1 --degrade-window-seconds 60 --timeout-seconds 1 \
    2099-01-01T00:00:00Z alpha:branch-alpha:n1:evanharmon1/harmon-devkit \
    healthy:branch-healthy:n5:evanharmon1/harmon-devkit \
    >"$multilane_out"
rm "$fixture_dir/fail-branch-alpha-pr-list"
assert_count "$multilane_out" 1 '^OBSERVATION-DEGRADED alpha: GitHub PR observation failed for lane alpha$'
[ -f "$fixture_dir/healthy-pr-list-calls" ] || fail "healthy lane's gh pr list was never called"
healthy_calls="$(<"$fixture_dir/healthy-pr-list-calls")"
[ "$healthy_calls" -eq 3 ] ||
    fail "healthy lane's gh pr list was not called on every poll (expected 3, got $healthy_calls)"
rm -f "$fixture_dir/healthy-pr-list-calls"
[ -f "$fixture_dir/alpha-pr-list-attempts" ] || fail "alpha's degraded gh pr list was never attempted"
alpha_attempts="$(<"$fixture_dir/alpha-pr-list-attempts")"
[ "$alpha_attempts" -eq 1 ] ||
    fail "alpha's degraded gh pr list was not skipped on later polls (expected exactly 1 attempt, got $alpha_attempts)"
rm -f "$fixture_dir/alpha-pr-list-attempts"
assert_count "$multilane_state" 1 '^DEGRADE[[:space:]]+alpha:PR[[:space:]]+2000000000[[:space:]]+1[[:space:]]+1:2000000005$'
assert_line "$clock_file" 2000000002

# A hanging external call times out without fabricating an absent transition.
touch "$fixture_dir/hang-list"
hang_out="$test_tmp/hang.out"
test_timeout="$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)"
[ -n "$test_timeout" ] || fail 'GNU timeout (timeout or gtimeout) is required'
"$test_timeout" --kill-after=2 8 bash "$watcher" --iterations 1 \
    --registry "$registry" --workspace-root "$workspace_root" \
    --interval-seconds 0 --timeout-seconds 1 \
    2099-01-01T00:00:00Z delta:branch-delta:n4:evanharmon1/harmon-devkit \
    >"$hang_out" || fail 'watcher did not degrade a hanging herdr call'
assert_count "$hang_out" 0 '^AGENT delta:'
rm "$fixture_dir/hang-list"

# A syntactically valid Herdr error envelope is indeterminate, not absence.
touch "$fixture_dir/malformed-list"
malformed_out="$test_tmp/malformed-list.out"
bash "$watcher" --iterations 1 --registry "$registry" --workspace-root "$workspace_root" \
    --interval-seconds 0 --timeout-seconds 1 \
    2099-01-01T00:00:00Z delta:branch-delta:n4:evanharmon1/harmon-devkit \
    >"$malformed_out"
assert_count "$malformed_out" 0 '^AGENT delta:'
rm "$fixture_dir/malformed-list"

# A syntactically valid but incomplete PR object is indeterminate, so
# persistent supervision re-arms instead of persisting a #null transition.
# #1041 persistent case: --degrade-window-seconds 0 gives this failure no
# grace period at all, so the give-up happens on the very same (only) poll
# this single-iteration invocation makes -- proving the eventual exit-1
# behavior is unchanged, and that exactly one OBSERVATION-DEGRADED marks the
# episode even when it is also the episode's last poll. A positive window is
# exercised by the transient/bounded-mid-episode cases above/below instead,
# where a real --interval-seconds lets a later poll retry non-blockingly.
touch "$fixture_dir/malformed-pr-list"
github_failure_out="$test_tmp/github-failure.out"
github_failure_err="$test_tmp/github-failure.err"
if bash "$watcher" --iterations 1 --registry "$registry" \
    --state-file "$test_tmp/github-failure.state" \
    --workspace-root "$workspace_root" --interval-seconds 0 --degrade-window-seconds 0 --timeout-seconds 1 \
    2099-01-01T00:00:00Z delta:branch-delta:n4:evanharmon1/harmon-devkit \
    >"$github_failure_out" 2>"$github_failure_err"; then
    fail 'watcher accepted a malformed GitHub PR observation'
fi
assert_line "$github_failure_err" 'lane-watch: GitHub PR observation failed for lane delta'
assert_line "$github_failure_out" 'OBSERVATION-DEGRADED delta: GitHub PR observation failed for lane delta'
assert_count "$github_failure_out" 1 '^OBSERVATION-DEGRADED '
assert_count "$test_tmp/github-failure.state" 1 '^AGENT[[:space:]]+delta[[:space:]]+absent'
rm "$fixture_dir/malformed-pr-list"

# The same asset resolves the repository root and registry in the flattened
# consumer layout when the lane spec supplies its required repository.
flattened_root="$test_tmp/consumer"
flattened_watcher="$flattened_root/.agents/skills/orchestrate/assets/lane-watch.sh"
mkdir -p "$(dirname "$flattened_watcher")" "$flattened_root/.worktrees/alpha"
cp "$watcher" "$flattened_watcher"
cp "$registry" "$flattened_root/agent-registry.json"
cp "$workspace_root/harmon-devkit/.worktrees/alpha/.lane-report.md" \
    "$flattened_root/.worktrees/alpha/.lane-report.md"
rm -f "$fixture_dir/pr-count" "$fixture_dir/phase"
flattened_out="$test_tmp/flattened.out"
bash "$flattened_watcher" --iterations 1 \
    --state-file "$test_tmp/flattened.state" --interval-seconds 0 --timeout-seconds 1 \
    2099-01-01T00:00:00Z alpha:branch-alpha:n1:evanharmon1/consumer >"$flattened_out"
assert_line "$flattened_out" 'SENTINEL alpha: MERGE-READY-alpha-n1'

# A watcher launched from a linked worktree still finds reports in sibling
# worktrees under the primary checkout.
linked_parent="$test_tmp/linked"
linked_main="$linked_parent/repo"
mkdir -p "$linked_main"
git -C "$linked_main" init -q -b main
git -C "$linked_main" config user.name test
git -C "$linked_main" config user.email test@example.invalid
mkdir -p "$linked_main/ai/skills/universal/orchestrate/assets"
cp "$watcher" "$linked_main/ai/skills/universal/orchestrate/assets/lane-watch.sh"
cp "$registry" "$linked_main/agent-registry.json"
git -C "$linked_main" add .
git -C "$linked_main" commit -qm initial
git -C "$linked_main" worktree add -q -b monitor "$linked_main/.worktrees/monitor"
mkdir -p "$linked_main/.worktrees/alpha"
cp "$workspace_root/harmon-devkit/.worktrees/alpha/.lane-report.md" \
    "$linked_main/.worktrees/alpha/.lane-report.md"
linked_watcher="$linked_main/.worktrees/monitor/ai/skills/universal/orchestrate/assets/lane-watch.sh"
linked_out="$test_tmp/linked.out"
bash "$linked_watcher" --iterations 1 \
    --state-file "$test_tmp/linked.state" --interval-seconds 0 --timeout-seconds 1 \
    2099-01-01T00:00:00Z alpha:branch-alpha:n1:evanharmon1/repo >"$linked_out"
assert_line "$linked_out" 'SENTINEL alpha: MERGE-READY-alpha-n1'

# Nonces use a literal-safe identity alphabet rather than regex syntax.
invalid_nonce_err="$test_tmp/invalid-nonce.err"
if bash "$watcher" --iterations 1 --registry "$registry" \
    --workspace-root "$workspace_root" --interval-seconds 0 --timeout-seconds 1 \
    2099-01-01T00:00:00Z 'alpha:branch-alpha:n[1:evanharmon1/harmon-devkit' \
    >/dev/null 2>"$invalid_nonce_err"; then
    fail 'watcher accepted an invalid sentinel nonce'
fi
assert_line "$invalid_nonce_err" 'lane-watch: invalid sentinel nonce in spec: alpha:branch-alpha:n[1:evanharmon1/harmon-devkit'

# Repository identity is mandatory; there is no ambient-repository fallback.
missing_repo_err="$test_tmp/missing-repo.err"
if bash "$watcher" --iterations 1 --registry "$registry" \
    --workspace-root "$workspace_root" --interval-seconds 0 --timeout-seconds 1 \
    2099-01-01T00:00:00Z alpha:branch-alpha:n1 \
    >/dev/null 2>"$missing_repo_err"; then
    fail 'watcher accepted a lane spec without owner/repo'
fi
assert_line "$missing_repo_err" 'lane-watch: invalid lane spec: alpha:branch-alpha:n1'

# The immutable kickoff registry is validated before any poll begins.
invalid_registry="$test_tmp/invalid-registry.json"
printf '%s\n' '{"finders":"not-an-array"}' >"$invalid_registry"
invalid_registry_err="$test_tmp/invalid-registry.err"
if bash "$watcher" --iterations 1 --registry "$invalid_registry" \
    --workspace-root "$workspace_root" --interval-seconds 0 --timeout-seconds 1 \
    2099-01-01T00:00:00Z alpha:branch-alpha:n1:evanharmon1/harmon-devkit \
    >/dev/null 2>"$invalid_registry_err"; then
    fail 'watcher accepted a malformed kickoff registry'
fi
assert_line "$invalid_registry_err" "lane-watch: invalid agent registry: $invalid_registry"

# Requested durable state fails loudly when its destination cannot be created.
state_parent="$test_tmp/state-parent"
printf '%s\n' occupied >"$state_parent"
state_failure_err="$test_tmp/state-failure.err"
if bash "$watcher" --iterations 1 --state-file "$state_parent/watcher.state" \
    --registry "$registry" --workspace-root "$workspace_root" \
    --interval-seconds 0 --timeout-seconds 1 \
    2099-01-01T00:00:00Z delta:branch-delta:n4:evanharmon1/harmon-devkit \
    >/dev/null 2>"$state_failure_err"; then
    fail 'watcher accepted an unpersistable requested state file'
fi
assert_line "$state_failure_err" "lane-watch: could not persist state to $state_parent/watcher.state"

# The watcher's private line-oriented state must never accept or overwrite the
# canonical JSON run monitor. The documented invocation uses a distinct path.
canonical_monitor="$test_tmp/monitor.json"
printf '%s\n' '{"generation":7,"reservations":["preserve-me"]}' >"$canonical_monitor"
cp "$canonical_monitor" "$test_tmp/monitor.before.json"
canonical_monitor_err="$test_tmp/canonical-monitor.err"
if bash "$watcher" --iterations 1 --state-file "$canonical_monitor" \
    --registry "$registry" --workspace-root "$workspace_root" \
    --interval-seconds 0 --timeout-seconds 1 \
    2099-01-01T00:00:00Z delta:branch-delta:n4:evanharmon1/harmon-devkit \
    >/dev/null 2>"$canonical_monitor_err"; then
    fail 'watcher accepted the canonical run monitor as private state'
fi
assert_line "$canonical_monitor_err" \
    "lane-watch: refusing canonical run monitor as watcher state: $canonical_monitor"
cmp -s "$canonical_monitor" "$test_tmp/monitor.before.json" ||
    fail 'watcher modified the canonical run monitor'
assert_count "$repo_root/ai/skills/universal/orchestrate/SKILL.md" 1 \
    'state-file <git-common-dir>/dev-flow-v2/slates/<slate>/lane-watch.state --registry'
assert_count "$repo_root/ai/skills/universal/orchestrate/SKILL.md" 0 \
    'state-file <run-state>'

# The watcher state implementation stays compatible with macOS Bash 3.2.
assert_count "$watcher" 0 'declare -A'
assert_count "$watcher" 0 '\$\{#state_'

# The warning uses the documented WALLCLOCK shape.
wallclock_out="$test_tmp/wallclock.out"
near_deadline="$(date -u -d '10 minutes' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
if [ -z "$near_deadline" ]; then
    near_deadline="$(date -u -v+10M +%Y-%m-%dT%H:%M:%SZ)"
fi
bash "$watcher" --iterations 1 --registry "$registry" \
    --workspace-root "$workspace_root" --interval-seconds 0 --timeout-seconds 1 \
    "$near_deadline" epsilon:branch-epsilon:n5:evanharmon1/harmon-devkit \
    >"$wallclock_out"
assert_line "$wallclock_out" "WALLCLOCK run: 10 min to $near_deadline cap"

# A bounded read that crosses the deadline terminates as wall-clock exhaustion.
crossed_deadline="$(date -u -d '1 second' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
if [ -z "$crossed_deadline" ]; then
    crossed_deadline="$(date -u -v+1S +%Y-%m-%dT%H:%M:%SZ)"
fi
touch "$fixture_dir/hang-pr-list"
deadline_out="$test_tmp/deadline-crossed.out"
bash "$watcher" --iterations 1 --registry "$registry" \
    --workspace-root "$workspace_root" --interval-seconds 0 --timeout-seconds 2 \
    "$crossed_deadline" epsilon:branch-epsilon:n5:evanharmon1/harmon-devkit \
    >"$deadline_out"
rm "$fixture_dir/hang-pr-list"
assert_line "$deadline_out" "WALLCLOCK run: deadline $crossed_deadline reached"

# Gemini 4055704932 / 4055704941 (PR #1102, #1041 remediation round 5): a
# corrupted or hand-edited state file can carry non-digit garbage in a
# numeric field, not merely an empty one -- proves this no longer breaks
# arithmetic/`-eq` and instead sanitizes safely. A valid, in-window
# first_failure paired with garbage notified/attempt fields folds the
# garbage fields to their safe default (0) without touching the valid
# first_failure.
rm -f "$fixture_dir/pr-count" "$fixture_dir/phase"
touch "$fixture_dir/fail-branch-alpha-pr-list"
sanitize_now="$(date -u +%s)"
sanitize_degrade_state="$test_tmp/sanitize-degrade.state"
printf 'PR\talpha\t#77 draft=false OPEN head=aaaaaaaabbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\t\nDEGRADE\talpha:PR\t%s\tabc\txyz:%s\nWALLCLOCK\trun\t0\t\n' \
    "$((sanitize_now - 100))" "$((sanitize_now - 10))" \
    >"$sanitize_degrade_state"
sanitize_degrade_out="$test_tmp/sanitize-degrade.out"
sanitize_degrade_err="$test_tmp/sanitize-degrade.err"
bash "$watcher" --iterations 1 --state-file "$sanitize_degrade_state" \
    --registry "$registry" --workspace-root "$workspace_root" \
    --interval-seconds 1 --degrade-window-seconds 600 --timeout-seconds 1 \
    2099-01-01T00:00:00Z alpha:branch-alpha:n1:evanharmon1/harmon-devkit \
    >"$sanitize_degrade_out" 2>"$sanitize_degrade_err"
rm "$fixture_dir/fail-branch-alpha-pr-list"
assert_count "$sanitize_degrade_err" 0 'integer expression expected'
assert_count "$sanitize_degrade_err" 0 'syntax error'
assert_line "$sanitize_degrade_out" 'OBSERVATION-DEGRADED alpha: GitHub PR observation failed for lane alpha'
assert_count "$sanitize_degrade_state" 1 "^DEGRADE[[:space:]]+alpha:PR[[:space:]]+$((sanitize_now - 100))[[:space:]]+1[[:space:]]+1:[0-9]+\$"

# Same finding: a corrupted (non-numeric) first_failure specifically --
# unlike notified/attempt, 0 is not its safe default (see the comment in
# observation_record_failure()), so it must fold into the SAME cold-start
# path an absent entry already takes, restarting a fresh episode from
# `now` rather than crashing or computing a nonsensical window age.
rm -f "$fixture_dir/pr-count" "$fixture_dir/phase"
touch "$fixture_dir/fail-branch-alpha-pr-list"
sanitize2_state="$test_tmp/sanitize-degrade-firstfailure.state"
printf 'PR\talpha\t#77 draft=false OPEN head=aaaaaaaabbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\t\nDEGRADE\talpha:PR\tnotanumber\t1\t3:%s\nWALLCLOCK\trun\t0\t\n' \
    "$((sanitize_now - 10))" \
    >"$sanitize2_state"
sanitize2_out="$test_tmp/sanitize-degrade-firstfailure.out"
sanitize2_err="$test_tmp/sanitize-degrade-firstfailure.err"
bash "$watcher" --iterations 1 --state-file "$sanitize2_state" \
    --registry "$registry" --workspace-root "$workspace_root" \
    --interval-seconds 1 --degrade-window-seconds 600 --timeout-seconds 1 \
    2099-01-01T00:00:00Z alpha:branch-alpha:n1:evanharmon1/harmon-devkit \
    >"$sanitize2_out" 2>"$sanitize2_err"
rm "$fixture_dir/fail-branch-alpha-pr-list"
assert_count "$sanitize2_err" 0 'integer expression expected'
assert_count "$sanitize2_err" 0 'syntax error'
assert_line "$sanitize2_out" 'OBSERVATION-DEGRADED alpha: GitHub PR observation failed for lane alpha'
assert_count "$sanitize2_state" 1 "^DEGRADE[[:space:]]+alpha:PR[[:space:]]+[0-9]+[[:space:]]+1[[:space:]]+1:[0-9]+\$"
assert_count "$sanitize2_state" 0 '^DEGRADE[[:space:]]+alpha:PR[[:space:]]+notanumber'

# Retire a promoted cloud lane into a PR-only watch with a past run deadline.
# Every life_poll is a process restart against the same state file.
touch "$fixture_dir/life-mode" "$fixture_dir/cloud-only"
: >"$fixture_dir/gh-calls"
printf '%s\n' '{"number":88,"isDraft":false,"state":"OPEN","headRefOid":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}' >"$fixture_dir/life-pr.json"
printf '%s\n' '{"baseRefName":"release#1","headRefOid":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}' >"$fixture_dir/life-meta.json"
printf '%s\n' '{"behind_by":0,"base_commit":{"sha":"cccccccccccccccccccccccccccccccccccccccc"}}' >"$fixture_dir/compare.json"
printf '%s\n' '[]' >"$fixture_dir/reviews.json"
life_head=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
life_state="$test_tmp/life.state"
life_out="$test_tmp/life.out"
: >"$life_out"
printf '%s\n' 2000000000 >"$clock_file"
thread_fixture() {
    jq -cn --arg head "$life_head" --argjson rows "$1" \
        '[{data:{repository:{pullRequest:{headRefOid:$head,reviewThreads:{nodes:$rows}}}}}]' >"$fixture_dir/threads.json"
}
ci_fixture() {
    jq -cn --arg head "$life_head" --arg conclusion "$1" --arg optional "${2:-FAILURE}" \
        '[{data:{repository:{pullRequest:{headRefOid:$head,commits:{nodes:[{commit:{statusCheckRollup:{contexts:{nodes:[
          {__typename:"CheckRun",name:"lint",status:"COMPLETED",conclusion:$conclusion,isRequired:true},
          {__typename:"CheckRun",name:"optional",status:"COMPLETED",conclusion:$optional,isRequired:false},
          {__typename:"StatusContext",context:"legacy",state:"SUCCESS",isRequired:true}
        ]}}}}]}}}}}]' >"$fixture_dir/ci.json"
}
life_poll() {
    PATH="$clock_bin:$PATH" WATCH_CLOCK="$clock_file" WATCH_REAL_DATE="$real_date" \
        bash "$watcher" --iterations 1 --state-file "$life_state" --registry "$registry" \
        --interval-seconds 1 --pr-interval-seconds 0 --timeout-seconds 2 --workspace-root "$workspace_root" \
        2000-01-01T00:00:00Z "${1:-retired:88:np:evanharmon1/harmon-devkit:pr}" >>"$life_out"
}
thread_fixture '[]'
ci_fixture SUCCESS
# Review R2: retirement lasts for one process; the same state can recover.
timed_failure_case() {
    local scenario=$1 rc=0 window=0 mixed_state mixed_out mixed_err fail_file failure_pattern
    mixed_state="$test_tmp/timed-$scenario.state"
    mixed_out="$test_tmp/timed-$scenario.out"
    mixed_err="$test_tmp/timed-$scenario.err"
    local timed_spec=cloud:claude/cloud-fixture:nt:evanharmon1/harmon-devkit:cloud
    local parked_spec=parked:88:np:evanharmon1/harmon-devkit:pr
    fail_file="$fixture_dir/fail-cloud-branch"
    failure_pattern='^lane-watch: GitHub branch observation failed for lane cloud$'
    if [ "$scenario" = heal-local ]; then
        timed_spec="events:claude/cloud-fixture:nt:evanharmon1/harmon-devkit:$test_tmp/recover-local.report"
        fail_file="$fixture_dir/fail-pr-list"
        failure_pattern='^lane-watch: GitHub PR observation failed for lane events$'
        rm "$fixture_dir/cloud-only"
        touch "$fixture_dir/events-mode"
        printf '%s\n' working >"$fixture_dir/events-status"
        printf '%s\n' 1 >"$fixture_dir/events-revision"
        : >"$fixture_dir/events-pane"
        : >"$test_tmp/recover-local.report"
    fi
    local specs_for_case=("$timed_spec")
    [ "$scenario" = lone ] || specs_for_case+=("$parked_spec")
    if [ "$scenario" = aged ]; then
        window=600
        printf 'DEGRADE\tcloud:BRANCH\t1999999300\t1\t0:2000000000\n' >"$mixed_state"
    fi
    printf '%s\n' '{"ref":"refs/heads/claude/cloud-fixture","object":{"type":"commit","sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}}' >"$fixture_dir/cloud-branch.json"
    printf '%s\n' "[$(cat "$fixture_dir/life-pr.json")]" >"$fixture_dir/cloud-pr.json"
    touch "$fail_file"
    : >"$fixture_dir/gh-calls"
    local args=(--iterations 2 --interval-seconds 0 --pr-interval-seconds 0
        --degrade-window-seconds "$window" --registry "$registry" --state-file "$mixed_state"
        2099-01-01T00:00:00Z "${specs_for_case[@]}")
    PATH="$clock_bin:$PATH" WATCH_CLOCK="$clock_file" WATCH_REAL_DATE="$real_date" \
        bash "$watcher" "${args[@]}" >"$mixed_out" 2>"$mixed_err" || rc=$?
    if [ "$scenario" = lone ]; then
        [ "$rc" -eq 1 ] || fail 'lone exhausted timed spec must exit 1'
    else
        [ "$rc" -eq 0 ] || fail "$scenario timed failure stopped the mixed watcher"
        assert_count "$fixture_dir/gh-calls" 2 '^pr view 88 .*--json number,isDraft,state,headRefOid$'
        assert_count "$mixed_out" 1 '^PR-WATCHING parked:'
    fi
    assert_count "$mixed_err" 1 "$failure_pattern"
    case "$scenario" in
    heal-cloud | heal-local)
        rm "$fail_file"
        # A state file left by the deleted round-1 fix must recover too.
        printf 'TERMINAL\t%s\tEXHAUSTED\t\n' "$timed_spec" >>"$mixed_state"
        if [ "$scenario" = heal-local ]; then
            printf '%s\n' blocked >"$fixture_dir/events-status"
            printf '%s\n' 'Do you want to proceed?' >"$fixture_dir/events-pane"
            printf '%s\n' 'DRAFT-PUBLISHED-events-nt' >"$test_tmp/recover-local.report"
        fi
        PATH="$clock_bin:$PATH" WATCH_CLOCK="$clock_file" WATCH_REAL_DATE="$real_date" \
            bash "$watcher" "${args[@]}" >>"$mixed_out" 2>>"$mixed_err"
        if [ "$scenario" = heal-cloud ]; then
            grep -q '^BRANCH cloud: claude/cloud-fixture head=bbbbbbbb$' "$mixed_out" || fail 'healed cloud lane did not resume BRANCH observation'
            grep -q '^PR cloud: #88 ' "$mixed_out" || fail 'healed cloud lane did not resume PR observation'
        else
            grep -q '^PR events: #88 ' "$mixed_out" || fail 'healed local lane did not resume PR observation'
            assert_line "$mixed_out" 'PROMPT events: Do you want to proceed?'
            assert_line "$mixed_out" 'SENTINEL events: DRAFT-PUBLISHED-events-nt'
            assert_line "$mixed_out" 'DRAFT-PUBLISHED events: DRAFT-PUBLISHED-events-nt'
            rm "$fixture_dir/events-mode" "$fixture_dir/events-status" "$fixture_dir/events-revision" "$fixture_dir/events-pane"
            rm -f "$fixture_dir/events-calls"
            touch "$fixture_dir/cloud-only"
        fi
        assert_count "$mixed_err" 1 "$failure_pattern"
        ;;
    *)
        # A still-failing re-arm retries and retires the spec in that process.
        rc=0
        PATH="$clock_bin:$PATH" WATCH_CLOCK="$clock_file" WATCH_REAL_DATE="$real_date" \
            bash "$watcher" "${args[@]}" >>"$mixed_out" 2>>"$mixed_err" || rc=$?
        if [ "$scenario" = lone ]; then
            [ "$rc" -eq 1 ] || fail 'lone still-failing re-arm must exit 1'
        else
            [ "$rc" -eq 0 ] || fail 'still-failing re-arm stopped the mixed watcher'
            assert_count "$fixture_dir/gh-calls" 4 '^pr view 88 .*--json number,isDraft,state,headRefOid$'
        fi
        assert_count "$fixture_dir/gh-calls" 2 'git/ref/heads/claude/cloud-fixture$'
        assert_count "$mixed_err" 2 "$failure_pattern"
        ;;
    esac
    assert_count "$mixed_state" 0 '^TERMINAL.*EXHAUSTED'
    assert_count "$mixed_out" 0 '^WATCH-COMPLETE '
    rm -f "$fail_file"
}
for timed_scenario in heal-cloud heal-local fresh aged lone; do timed_failure_case "$timed_scenario"; done
: >"$fixture_dir/compare-calls"
# End review R2 timed isolation regression.

# Cloud lanes run the identical PR observations before retirement.
printf '%s\n' "[$(cat "$fixture_dir/life-pr.json")]" >"$fixture_dir/cloud-pr.json"
PATH="$clock_bin:$PATH" WATCH_CLOCK="$clock_file" WATCH_REAL_DATE="$real_date" \
    bash "$watcher" --iterations 1 --state-file "$life_state" --registry "$registry" \
    --interval-seconds 1 --timeout-seconds 2 --workspace-root "$workspace_root" \
    2099-01-01T00:00:00Z cloud:claude/cloud-fixture:n4:evanharmon1/harmon-devkit:cloud >>"$life_out"
assert_line "$life_out" 'PR-WATCHING cloud: #88 head=bbbbbbbb draft=false'
assert_count "$life_out" 1 '^PR-CI '
life_poll
assert_count "$life_out" 1 '^PR-WATCHING '
assert_count "$life_out" 1 '^PR-CI '
assert_count "$fixture_dir/compare-calls" 1 '^compare$'
# Activity an hour later is observed; there is no expired quiet window.
printf '%s\n' 2000003600 >"$clock_file"
printf '%s\n' '[{"id":900,"submitted_at":"2033-05-18T04:33:20Z","user":{"id":999,"login":"trusted-codex","type":"Bot"}}]' >"$fixture_dir/reviews.json"
thread_fixture '[{"id":"T1","isResolved":false}]'
ci_fixture FAILURE
printf '%s\n' '{"baseRefName":"release#1","headRefOid":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}' >"$fixture_dir/life-meta.json"
printf '%s\n' '{"behind_by":2,"base_commit":{"sha":"dddddddddddddddddddddddddddddddddddddddd"}}' >"$fixture_dir/compare.json"
life_poll
assert_count "$life_out" 1 '^PR-ACTIVITY retired: #88 trusted-codex review 900 updated=2000003600 revision=[0-9]+$'
assert_line "$life_out" 'PR-THREAD retired: #88 T1 opened generation=1'
assert_line "$life_out" 'PR-BEHIND retired: #88 base=dddddddddddddddddddddddddddddddddddddddd behind_by=2'
assert_count "$life_out" 2 '^PR-CI '
life_poll
assert_count "$life_out" 1 '^PR-ACTIVITY '
assert_count "$life_out" 1 '^PR-THREAD '
assert_count "$life_out" 1 '^PR-BEHIND '
assert_count "$life_out" 2 '^PR-CI '
assert_count "$fixture_dir/compare-calls" 2 '^compare$'
# Optional CI changes do not emit required-CI changes; resolution is silent,
# and a reopened thread emits exactly once even after a label change.
thread_fixture '[{"id":"T1","isResolved":true}]'
ci_fixture FAILURE SUCCESS
life_poll
assert_count "$life_out" 2 '^PR-CI '
thread_fixture '[{"id":"T1","isResolved":false}]'
life_poll 'parked:88:new:evanharmon1/harmon-devkit:pr'
life_poll 'parked:88:new:evanharmon1/harmon-devkit:pr'
assert_line "$life_out" 'PR-THREAD parked: #88 T1 reopened generation=2'
assert_count "$life_out" 2 '^PR-THREAD '
# A second page of new threads is included. Required CI may also have many pages.
jq -c '.[0] as $page | [$page, ($page | .data.repository.pullRequest.reviewThreads.nodes=[{id:"T2",isResolved:true}])]' \
    "$fixture_dir/threads.json" >"$fixture_dir/pages.json"
mv "$fixture_dir/pages.json" "$fixture_dir/threads.json"
life_poll
assert_line "$life_out" 'PR-THREAD retired: #88 T2 opened generation=1'
life_poll
assert_count "$life_out" 3 '^PR-THREAD '
# Parked drafts are watched beyond the deadline, with no Herdr or branch reads.
jq '.isDraft=true' "$fixture_dir/life-pr.json" >"$fixture_dir/next-pr.json"
mv "$fixture_dir/next-pr.json" "$fixture_dir/life-pr.json"
ci_fixture SUCCESS
life_poll
assert_count "$life_out" 3 '^PR-CI '
assert_count "$life_out" 0 '^(AGENT|PROMPT|STALL|SENTINEL) retired:'
[ ! -e "$fixture_dir/cloud-herdr-calls" ] || fail 'PR watch called Herdr after retirement'
# A changed base is sampled once per 300 seconds, durably across restarts.
printf '%s\n' 2000003899 >"$clock_file"
life_poll
assert_count "$fixture_dir/compare-calls" 2 '^compare$'
printf '%s\n' 2000003900 >"$clock_file"
life_poll
assert_count "$fixture_dir/compare-calls" 3 '^compare$'
assert_count "$life_out" 1 '^PR-BEHIND '
# A malformed connection is indeterminate, cannot emit a watching attestation,
# and its retry episode does not vanish just because PR discovery succeeded.
printf '%s\n' '[{"data":{"repository":{"pullRequest":{"headRefOid":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","reviewThreads":{"nodes":"invalid"}}}}}]' >"$fixture_dir/threads.json"
before_watching="$(grep -c '^PR-WATCHING ' "$life_out")"
life_poll
life_poll
assert_count "$life_out" "$before_watching" '^PR-WATCHING '
assert_count "$life_out" 1 '^OBSERVATION-DEGRADED retired: GitHub threads observation failed for PR #88$'
assert_count "$life_state" 1 '^DEGRADE[[:space:]]+evanharmon1/harmon-devkit#88:threads'
printf '%s\n' 2000003905 >"$clock_file"
thread_fixture '[{"id":"T1","isResolved":false}]'
life_poll
assert_count "$life_state" 0 '^DEGRADE[[:space:]]+evanharmon1/harmon-devkit#88:threads'
# Terminal events are deduplicated, and terminal PR-only specs stop querying.
jq '.state="MERGED"' "$fixture_dir/life-pr.json" >"$fixture_dir/next-pr.json"
mv "$fixture_dir/next-pr.json" "$fixture_dir/life-pr.json"
life_poll
calls_before="$(wc -l <"$fixture_dir/gh-calls")"
life_poll
assert_count "$life_out" 1 '^PR-MERGED retired: #88 head=bbbbbbbb$'
[ "$(wc -l <"$fixture_dir/gh-calls")" -eq "$calls_before" ] || fail 'merged PR-only watch kept reading GitHub'
# Closing without merge has its own terminal event and dedup key.
life_state="$test_tmp/closed.state"
jq '.number=89 | .state="CLOSED"' "$fixture_dir/life-pr.json" >"$fixture_dir/next-pr.json"
mv "$fixture_dir/next-pr.json" "$fixture_dir/life-pr.json"
life_poll 'closed:89:np:evanharmon1/harmon-devkit:pr'
life_poll 'closed:89:np:evanharmon1/harmon-devkit:pr'
assert_count "$life_out" 1 '^PR-CLOSED closed: #89 head=bbbbbbbb$'
assert_count "$fixture_dir/gh-calls" 0 '/(check-runs|check-suites)'
assert_count "$fixture_dir/gh-calls" 0 'git/ref/heads/88'
assert_count "$fixture_dir/gh-calls" 3 'compare/release%231\.\.\.'
assert_count "$life_out" 0 '^WALLCLOCK '

# A terminal timed spec is still revisited: its event must remain deduplicated.
printf '%s\n' "[$(cat "$fixture_dir/life-pr.json")]" >"$fixture_dir/cloud-pr.json"
terminal_args=(--iterations 2 --interval-seconds 0 --registry "$registry"
    --state-file "$test_tmp/terminal-timed.state" --workspace-root "$workspace_root"
    2099-01-01T00:00:00Z terminal:claude/cloud-fixture:nt:evanharmon1/harmon-devkit:cloud)
bash "$watcher" "${terminal_args[@]}" >"$test_tmp/terminal-timed.out"
bash "$watcher" "${terminal_args[@]}" >>"$test_tmp/terminal-timed.out"
assert_count "$test_tmp/terminal-timed.out" 1 '^PR-CLOSED terminal: #89 '
assert_line "$life_out" 'WATCH-COMPLETE run: no active specs'

# Return to an open draft for the rest of the observation regressions.
printf '%s\n' '{"number":88,"isDraft":true,"state":"OPEN","headRefOid":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}' >"$fixture_dir/life-pr.json"
thread_fixture '[]'
ci_fixture SUCCESS
life_state="$test_tmp/attestation.state"
life_out="$test_tmp/attestation.out"
life_poll
assert_line "$life_out" 'PR-WATCHING retired: #88 head=bbbbbbbb draft=true'
jq '.isDraft=false' "$fixture_dir/life-pr.json" >"$fixture_dir/next-pr.json"
mv "$fixture_dir/next-pr.json" "$fixture_dir/life-pr.json"
life_poll
life_poll
assert_count "$life_out" 2 '^PR-WATCHING '
assert_line "$life_out" 'PR-WATCHING retired: #88 head=bbbbbbbb draft=false'
assert_count "$life_out" 0 'untrusted-bot'

# Each edited comment has a new timestamp marker. Reviews have no updated_at
# in the REST contract: a content revision must distinguish their edits too.
printf '%s\n' '[{"id":901,"created_at":"2033-05-18T03:33:20Z","updated_at":"2033-05-18T03:33:20Z","body":"initial","user":{"id":1,"login":"human","type":"User"}}]' >"$fixture_dir/comments.json"
life_poll
jq '.[0].updated_at="2033-05-18T04:33:20Z"' "$fixture_dir/comments.json" >"$fixture_dir/next-comments.json"
mv "$fixture_dir/next-comments.json" "$fixture_dir/comments.json"
life_poll
life_poll
assert_count "$life_out" 2 '^PR-ACTIVITY retired: #88 human comment 901 '
assert_count "$life_out" 1 '^PR-ACTIVITY retired: #88 human comment 901 updated=2000000000 '
assert_count "$life_out" 1 '^PR-ACTIVITY retired: #88 human comment 901 updated=2000003600 '
jq '.[0].body="edited review"' "$fixture_dir/reviews.json" >"$fixture_dir/next-reviews.json"
mv "$fixture_dir/next-reviews.json" "$fixture_dir/reviews.json"
life_poll
life_poll
assert_count "$life_out" 2 '^PR-ACTIVITY retired: #88 trusted-codex review 900 '
[ "$(grep '^PR-ACTIVITY .* review 900 ' "$life_out" | sort -u | wc -l)" -eq 2 ] || fail 'review edit has no distinct marker'
jq 'del(.[0].body)' "$fixture_dir/reviews.json" >"$fixture_dir/next-reviews.json"
mv "$fixture_dir/next-reviews.json" "$fixture_dir/reviews.json"
life_poll
life_poll
assert_count "$life_out" 3 '^PR-ACTIVITY retired: #88 trusted-codex review 900 '
assert_count "$life_state" 1 '^PRSEEN[[:space:]]+evanharmon1/harmon-devkit#88:review:900[[:space:]]'
rm "$fixture_dir/comments.json"

# A malformed selected activity entry fails the entire snapshot. Keep its
# user/id valid so removing the timestamp validation makes this test fail.
cp "$fixture_dir/reviews.json" "$fixture_dir/valid-reviews.json"
printf '%s\n' '[{"id":902,"user":{"id":999,"login":"trusted-codex","type":"Bot"}}]' >"$fixture_dir/reviews.json"
life_state="$test_tmp/malformed-activity-entry.state"
life_out="$test_tmp/malformed-activity-entry.out"
life_poll 2>"$test_tmp/malformed-activity-entry.err"
life_poll 2>>"$test_tmp/malformed-activity-entry.err"
assert_count "$life_out" 1 '^OBSERVATION-DEGRADED retired: GitHub activity observation failed for PR #88$'
assert_count "$life_out" 0 '^PR-(ACTIVITY|WATCHING) '
assert_count "$life_state" 1 '^DEGRADE[[:space:]]+evanharmon1/harmon-devkit#88:activity'
[ ! -s "$test_tmp/malformed-activity-entry.err" ] || fail 'malformed activity leaked diagnostics'
# Pin row validation independently of timestamp parsing: a string id with
# a valid timestamp must fail too, even though fromdateiso8601 succeeds.
printf '%s\n' '[{"id":"bad-id","submitted_at":"2033-05-18T03:33:20Z","user":{"id":999,"login":"trusted-codex","type":"Bot"}}]' >"$fixture_dir/reviews.json"
life_state="$test_tmp/malformed-activity-id.state"
life_out="$test_tmp/malformed-activity-id.out"
life_poll
assert_count "$life_out" 1 '^OBSERVATION-DEGRADED retired: GitHub activity observation failed for PR #88$'
assert_count "$life_out" 0 '^PR-(ACTIVITY|WATCHING) '
mv "$fixture_dir/valid-reviews.json" "$fixture_dir/reviews.json"

# A required-check row missing its isRequired flag must not attest a complete
# observation, on the failed attempt OR a skipped backoff attempt (M9).
ci_fixture SUCCESS
jq 'del(.[0].data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup.contexts.nodes[0].isRequired)' "$fixture_dir/ci.json" >"$fixture_dir/next-ci.json"
mv "$fixture_dir/next-ci.json" "$fixture_dir/ci.json"
life_state="$test_tmp/invalid-checks.state"
life_out="$test_tmp/invalid-checks.out"
life_poll 2>"$test_tmp/invalid-checks.err"
life_poll 2>>"$test_tmp/invalid-checks.err"
assert_count "$life_out" 1 '^OBSERVATION-DEGRADED retired: GitHub ci observation failed for PR #88$'
assert_count "$life_out" 0 '^PR-(CI|WATCHING) '
[ ! -s "$test_tmp/invalid-checks.err" ] || fail 'invalid checks leaked jq diagnostics'
ci_fixture SUCCESS

# A push between discovery and the thread page restarts discovery immediately.
# No old-head attestation/CI or degraded-read episode may escape (M6).
cp "$fixture_dir/life-pr.json" "$fixture_dir/move-head"
jq '.headRefOid="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' "$fixture_dir/life-pr.json" >"$fixture_dir/next-pr.json"
mv "$fixture_dir/next-pr.json" "$fixture_dir/life-pr.json"
life_state="$test_tmp/moved-head.state"
life_out="$test_tmp/moved-head.out"
life_poll 2>"$test_tmp/moved-head.err"
assert_count "$life_out" 0 '^OBSERVATION-DEGRADED '
assert_count "$life_out" 0 '^PR-(CI|WATCHING) .* head=aaaaaaaa'
assert_count "$life_out" 1 '^PR-WATCHING retired: #88 head=bbbbbbbb draft=false$'
assert_count "$life_out" 2 '^PR retired: #88 '
assert_count "$life_state" 0 '^DEGRADE'
[ ! -s "$test_tmp/moved-head.err" ] || fail 'head rediscovery leaked jq diagnostics'

# A temporary activity outage stays degraded, even with a zero timed window.
touch "$fixture_dir/fail-activity"
activity_failure_out="$test_tmp/activity-failure.out"
for restart in 1 2; do
    PATH="$clock_bin:$PATH" WATCH_CLOCK="$clock_file" WATCH_REAL_DATE="$real_date" \
        bash "$watcher" --iterations 1 --degrade-window-seconds 0 --registry "$registry" \
        --state-file "$test_tmp/activity-failure.state" --pr-interval-seconds 0 \
        2000-01-01T00:00:00Z retired:88:np:evanharmon1/harmon-devkit:pr \
        >>"$activity_failure_out" 2>"$test_tmp/activity-failure.err"
done
assert_line "$activity_failure_out" 'OBSERVATION-DEGRADED retired: GitHub activity observation failed for PR #88'
assert_count "$activity_failure_out" 0 '^(PR-UNREADABLE|WATCH-COMPLETE) '
assert_count "$activity_failure_out" 0 '^PR-WATCHING '
assert_count "$test_tmp/activity-failure.state" 0 '^TERMINAL'
rm "$fixture_dir/fail-activity"

# A typo beside a live local lane cannot stop supervision or loop on re-arm.
rm "$fixture_dir/cloud-only"
healthy_before="$(cat "$fixture_dir/healthy-pr-list-calls" 2>/dev/null || printf 0)"
for restart in 1 2 3 4; do
    PATH="$clock_bin:$PATH" WATCH_CLOCK="$clock_file" WATCH_REAL_DATE="$real_date" \
        bash "$watcher" --iterations 2 --interval-seconds 0 --degrade-window-seconds 0 \
        --registry "$registry" --state-file "$test_tmp/typo.state" --pr-interval-seconds 0 \
        --workspace-root "$workspace_root" 2099-01-01T00:00:00Z \
        typo:999999:np:evanharmon1/harmon-devkit:pr \
        healthy:branch-healthy:nh:evanharmon1/harmon-devkit >>"$test_tmp/typo.out"
    if [ "$restart" -le 2 ]; then
        assert_count "$test_tmp/typo.out" 0 '^PR-UNREADABLE '
    fi
done
assert_count "$fixture_dir/typo-calls" 6 '^typo$'
assert_count "$test_tmp/typo.out" 1 '^PR-UNREADABLE typo: #999999 reason='
assert_count "$test_tmp/typo.out" 0 '^WATCH-COMPLETE '
assert_count "$test_tmp/typo.out" 1 '^AGENT healthy: init -> absent$'
touch "$fixture_dir/cloud-only"
[ "$(cat "$fixture_dir/healthy-pr-list-calls")" -eq "$((healthy_before + 8))" ] || fail 'typo stopped healthy lane supervision'

# Outages spanning four old windows never retire, complete, or poll early.
for read_mode in outage-502 timeout transport; do
    printf '%s\n' "$read_mode" >"$fixture_dir/pr-read-mode"
    life_state="$test_tmp/$read_mode.state"
    life_out="$test_tmp/$read_mode.out"
    calls_before="$(wc -l <"$fixture_dir/gh-calls")"
    for elapsed in 0 5 299 300 600 900 1200 1500 1800 2100 2400; do
        printf '%s\n' "$((2000000000 + elapsed))" >"$clock_file"
        PATH="$clock_bin:$PATH" WATCH_CLOCK="$clock_file" WATCH_REAL_DATE="$real_date" \
            bash "$watcher" --iterations 1 --registry "$registry" --state-file "$life_state" \
            2000-01-01T00:00:00Z retired:88:np:evanharmon1/harmon-devkit:pr >>"$life_out"
    done
    [ "$(wc -l <"$fixture_dir/gh-calls")" -eq "$((calls_before + 9))" ] || fail 'outage changed PR cadence'
    assert_count "$life_out" 1 '^OBSERVATION-DEGRADED '
    assert_count "$life_out" 0 '^(PR-UNREADABLE|WATCH-COMPLETE|PR-WATCHING) '
    assert_count "$life_state" 0 '^TERMINAL'
    rm "$fixture_dir/pr-read-mode"
    printf '%s\n' 2000002700 >"$clock_file"
    life_poll
    assert_count "$life_out" 1 '^PR-WATCHING '
done

# Definitive discovery and lifecycle identity failures retire on poll six.
# GraphQL errors JSON belongs to api graphql, not pr view's stderr errors.
# A temporary answer from the same endpoint resets its consecutive count.
for read_mode in not-found-repository not-found-404 not-found-object not-found-slurp not-found-header-404; do
    case "$read_mode" in
    not-found-repository | not-found-404)
        mode_file="$fixture_dir/pr-read-mode"
        degrade_key=retired:PR
        ;;
    *)
        mode_file="$fixture_dir/graphql-read-mode"
        degrade_key=evanharmon1/harmon-devkit#88:threads
        ;;
    esac
    printf '%s\n' "$read_mode" >"$mode_file"
    life_state="$test_tmp/$read_mode.state"
    life_out="$test_tmp/$read_mode.out"
    # Pre-existing generic retry attempts are not definitive identity answers.
    printf 'DEGRADE\t%s\t%s\t1\t99:0\n' "$degrade_key" "$(cat "$clock_file")" >"$life_state"
    for attempt in 1 2 3 4 5; do life_poll; done
    assert_count "$life_out" 0 '^PR-UNREADABLE '
    if [ "$degrade_key" = retired:PR ]; then
        printf '%s\n' outage-502 >"$mode_file"
        life_poll
    else
        rm "$mode_file"
        touch "$fixture_dir/fail-threads"
        life_poll
        rm "$fixture_dir/fail-threads"
    fi
    printf '%s\n' "$read_mode" >"$mode_file"
    for attempt in 1 2 3 4 5; do life_poll; done
    assert_count "$life_out" 0 '^PR-UNREADABLE '
    life_poll
    calls_after_retirement="$(wc -l <"$fixture_dir/gh-calls")"
    life_poll
    [ "$(wc -l <"$fixture_dir/gh-calls")" -eq "$calls_after_retirement" ] || fail 'retired identity was queried again'
    assert_count "$life_out" 1 '^PR-UNREADABLE '
    assert_count "$life_state" 1 '^TERMINAL[[:space:]]+evanharmon1/harmon-devkit#88[[:space:]]+UNREADABLE'
    rm "$mode_file"
done

# A PR event is echoed before a persistence failure can consume it.
persistfail_dir="$test_tmp/persist-fail-state"
mkdir -p "$persistfail_dir"
life_state="$persistfail_dir/pr-order.state"
life_out="$test_tmp/persist-fail.out"
printf 'PR\tretired\t#88 draft=false OPEN head=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\t\n' >"$life_state"
touch "$fixture_dir/fail-mv"
if life_poll 2>"$test_tmp/persist-fail.err"; then fail 'PR persistence fault unexpectedly succeeded'; fi
rm "$fixture_dir/fail-mv"
assert_count "$life_out" 1 '^PR-ACTIVITY '
assert_count "$test_tmp/persist-fail.err" 1 'could not persist state'
assert_count "$life_state" 0 '^PRSEEN'

# Slow discovery must refresh now before checking a later endpoint's retry.
printf '%s\n' "[$(cat "$fixture_dir/life-pr.json")]" >"$fixture_dir/cloud-pr.json"
slow_now="$(date -u +%s)"
slow_state="$test_tmp/slow-observation-ready.state"
printf 'DEGRADE\tevanharmon1/harmon-devkit#88:threads\t%s\t1\t1:%s\n' "$((slow_now - 100))" "$((slow_now + 1))" >"$slow_state"
touch "$fixture_dir/hang-pr-list"
bash "$watcher" --iterations 1 --state-file "$slow_state" --registry "$registry" \
    --timeout-seconds 5 --workspace-root "$workspace_root" 2099-01-01T00:00:00Z \
    cloud:claude/cloud-fixture:ns:evanharmon1/harmon-devkit:cloud >"$test_tmp/slow-observation-ready.out"
rm "$fixture_dir/hang-pr-list"
assert_count "$slow_state" 0 '^DEGRADE[[:space:]]+evanharmon1/harmon-devkit#88:threads'
assert_count "$test_tmp/slow-observation-ready.out" 1 '^PR-WATCHING '

# Deadline crossed during timed discovery must leave the later PR-only spec
# alive in the SAME poll. Fake clock advancement makes this deterministic.
printf '%s\n' 2000000000 >"$clock_file"
printf '%s\n' 2000000002 >"$fixture_dir/cross-deadline"
cross_deadline="$($real_date -u -d @2000000001 +%Y-%m-%dT%H:%M:%SZ)"
PATH="$clock_bin:$PATH" WATCH_CLOCK="$clock_file" WATCH_REAL_DATE="$real_date" \
    bash "$watcher" --iterations 1 --registry "$registry" --workspace-root "$workspace_root" \
    --state-file "$test_tmp/mixed-deadline.state" "$cross_deadline" \
    timed:claude/cloud-fixture:nt:evanharmon1/harmon-devkit:cloud \
    retired:88:np:evanharmon1/harmon-devkit:pr >"$test_tmp/mixed-deadline.out"
rm "$fixture_dir/cross-deadline"
assert_count "$test_tmp/mixed-deadline.out" 1 '^WALLCLOCK run: deadline .* reached$'
assert_count "$test_tmp/mixed-deadline.out" 1 '^PR-WATCHING retired:'
assert_count "$test_tmp/mixed-deadline.out" 0 '^(OBSERVATION-DEGRADED|WATCH-COMPLETE) '

# Re-arm the same state with a later deadline: each deadline owns its latch.
rearm_out="$test_tmp/rearm-deadline.out"
for rearm_epoch in 2000000001 2000000600; do
    rearm_deadline="$($real_date -u -d @"$rearm_epoch" +%Y-%m-%dT%H:%M:%SZ)"
    printf '%s\n' "$((rearm_epoch - 1))" >"$clock_file"
    PATH="$clock_bin:$PATH" WATCH_CLOCK="$clock_file" WATCH_REAL_DATE="$real_date" \
        bash "$watcher" --iterations 1 --registry "$registry" --state-file "$test_tmp/rearm-deadline.state" \
        "$rearm_deadline" timed:claude/cloud-fixture:nt:evanharmon1/harmon-devkit:cloud >>"$rearm_out"
    printf '%s\n' "$rearm_epoch" >"$clock_file"
    PATH="$clock_bin:$PATH" WATCH_CLOCK="$clock_file" WATCH_REAL_DATE="$real_date" \
        bash "$watcher" --iterations 1 --registry "$registry" --state-file "$test_tmp/rearm-deadline.state" \
        "$rearm_deadline" timed:claude/cloud-fixture:nt:evanharmon1/harmon-devkit:cloud >>"$rearm_out"
    PATH="$clock_bin:$PATH" WATCH_CLOCK="$clock_file" WATCH_REAL_DATE="$real_date" \
        bash "$watcher" --iterations 1 --registry "$registry" --state-file "$test_tmp/rearm-deadline.state" \
        "$rearm_deadline" timed:claude/cloud-fixture:nt:evanharmon1/harmon-devkit:cloud >>"$rearm_out"
    assert_count "$rearm_out" 1 "^WALLCLOCK run: deadline $rearm_deadline reached$"
done
assert_count "$rearm_out" 2 '^WALLCLOCK run: 1 min to '
assert_count "$rearm_out" 2 '^WALLCLOCK run: deadline .* reached$'

# PR-only specs (promoted OR parked) default to one observation per 300 s,
# durably across restarts; timed lane discovery keeps the fast cadence.
life_out="$test_tmp/cadence.out"
for draft in false true; do
    jq --argjson draft "$draft" '.isDraft=$draft' "$fixture_dir/life-pr.json" >"$fixture_dir/next-pr.json"
    mv "$fixture_dir/next-pr.json" "$fixture_dir/life-pr.json"
    life_state="$test_tmp/cadence-$draft.state"
    for cadence_time in 2000100000 2000100299 2000100300; do
        printf '%s\n' "$cadence_time" >"$clock_file"
        calls_before="$(wc -l <"$fixture_dir/gh-calls")"
        PATH="$clock_bin:$PATH" WATCH_CLOCK="$clock_file" WATCH_REAL_DATE="$real_date" \
            bash "$watcher" --iterations 1 --registry "$registry" --state-file "$life_state" \
            2000-01-01T00:00:00Z retired:88:np:evanharmon1/harmon-devkit:pr >>"$life_out"
        calls_after="$(wc -l <"$fixture_dir/gh-calls")"
        if [ "$cadence_time" -eq 2000100299 ]; then
            [ "$calls_after" -eq "$calls_before" ] || fail 'quiescent PR polled before 300 seconds'
        else
            [ "$calls_after" -gt "$calls_before" ] || fail 'quiescent PR did not poll when due'
        fi
    done
done
calls_before="$(wc -l <"$fixture_dir/gh-calls")"
PATH="$clock_bin:$PATH" WATCH_CLOCK="$clock_file" WATCH_REAL_DATE="$real_date" \
    bash "$watcher" --iterations 2 --interval-seconds 0 --registry "$registry" \
    --state-file "$test_tmp/timed-fast.state" 2099-01-01T00:00:00Z \
    fast:claude/cloud-fixture:nf:evanharmon1/harmon-devkit:cloud >"$test_tmp/timed-fast.out"
calls_after="$(wc -l <"$fixture_dir/gh-calls")"
[ "$((calls_after - calls_before))" -ge 14 ] || fail 'timed lane lost its fast cadence'

# A quiescent spec still appears in the all-lane heartbeat without another
# GitHub read. Reproduce a heartbeat due before the 300-second PR poll.
printf '%s\n' 2000100360 >"$clock_file"
calls_before="$(wc -l <"$fixture_dir/gh-calls")"
PATH="$clock_bin:$PATH" WATCH_CLOCK="$clock_file" WATCH_REAL_DATE="$real_date" \
    bash "$watcher" --iterations 1 --registry "$registry" --state-file "$life_state" \
    --heartbeat-minutes 1 2000-01-01T00:00:00Z \
    retired:88:np:evanharmon1/harmon-devkit:pr >"$test_tmp/quiescent-heartbeat.out"
[ "$(wc -l <"$fixture_dir/gh-calls")" -eq "$calls_before" ] || fail 'heartbeat polled a quiescent PR'
assert_count "$test_tmp/quiescent-heartbeat.out" 1 '^HEARTBEAT retired: state=cloud age=360s pr=#88 '

# Primary limits use reset; secondary and GraphQL limits use retry or 60 s.
# Persisted pauses survive process restarts without extending either window.
for rate_mode in primary secondary retry remaining graphql-object graphql-slurp \
    primary-api secondary-api primary-http-cobra primary-graphql-cobra \
    secondary-403-cobra secondary-graphql-cobra missing-reset; do
    case "$rate_mode" in
    primary | remaining | primary-api | primary-http-cobra | primary-graphql-cobra) pause_until=2000201200 ;;
    missing-reset) pause_until=2000203600 ;;
    retry) pause_until=2000200120 ;;
    *) pause_until=2000200060 ;;
    esac
    printf '%s\n' "$rate_mode" >"$fixture_dir/rate-mode"
    printf '%s\n' 2000201200 >"$fixture_dir/rate-reset"
    printf '%s\n' 2000200000 >"$clock_file"
    life_state="$test_tmp/rate-$rate_mode.state"
    life_out="$test_tmp/rate-$rate_mode.out"
    life_poll
    assert_line "$life_out" "RATE-LIMITED github: until=$pause_until"
    calls_before="$(wc -l <"$fixture_dir/gh-calls")"
    printf '%s\n' "$((pause_until - 1))" >"$clock_file"
    life_poll
    [ "$(wc -l <"$fixture_dir/gh-calls")" -eq "$calls_before" ] || fail 'rate pause issued another GitHub read'
    assert_count "$life_out" 1 '^RATE-LIMITED '
    assert_count "$life_out" 0 '^(OBSERVATION-DEGRADED|PR-WATCHING|WATCH-COMPLETE) '
    assert_count "$life_state" 0 '^DEGRADE'
    rm "$fixture_dir/rate-mode"
    printf '%s\n' "$pause_until" >"$clock_file"
    life_poll
    assert_count "$life_out" 1 '^PR-WATCHING '
done

# A header-shaped string in a successful response BODY never pauses reads.
for body_mode in body body-line; do
    printf '%s\n' "$body_mode" >"$fixture_dir/rate-mode"
    life_state="$test_tmp/rate-$body_mode.state"
    life_out="$test_tmp/rate-$body_mode.out"
    life_poll
    life_poll
    assert_count "$life_out" 0 '^RATE-LIMITED '
    assert_count "$life_out" 1 '^PR-WATCHING '
    assert_count "$life_state" 0 '^RATE'
    rm "$fixture_dir/rate-mode"
done

echo 'PASS: deadline isolation, PR cadence, rate pauses, edits, head rediscovery and restored regression coverage'

rm "$fixture_dir/life-mode" "$fixture_dir/cloud-only" "$fixture_dir/threads.json" "$fixture_dir/ci.json"
printf '%s\n' '[]' >"$fixture_dir/cloud-pr.json"
echo 'PASS: PR lifecycle observations, retirement past deadline, pagination, restart dedup and terminal events'

# Approval episodes are keyed by visibility, not text or redraw revision.
# Each invocation is a restart against the same durable state and fake clock.
touch "$fixture_dir/events-mode" "$fixture_dir/events-fallback"
printf '%s\n' 1 >"$fixture_dir/events-revision"
printf '%s\n' 'Requesting permission for:' 'echo same' 'Run this command?' '❯ 1. Yes, approve' '  2. No, deny' >"$fixture_dir/events-pane"
events_state="$test_tmp/events.state"
events_report="$test_tmp/events-report.md"
events_out="$test_tmp/events.out"
: >"$events_out"
printf '%s\n' 2000000000 >"$clock_file"
events_poll() {
    PATH="$clock_bin:$PATH" WATCH_CLOCK="$clock_file" WATCH_REAL_DATE="$real_date" \
        bash "$watcher" --iterations 1 --state-file "$events_state" \
        --registry "$registry" --workspace-root "$workspace_root" \
        --prompt-reemit-seconds 180 --stall-minutes 1 --heartbeat-minutes 1 "$@" \
        2099-01-01T00:00:00Z \
        "events:branch-events:a2:evanharmon1/harmon-devkit:$events_report" >>"$events_out"
}
events_poll
events_poll
assert_line "$events_out" 'AGENT events: init -> blocked (fallback)'
assert_line "$events_out" 'PROMPT events: Requesting permission for: echo same (fallback)'
assert_count "$events_out" 1 '^PROMPT '
assert_count "$events_out" 0 '^AGENT .* -> (done|idle)'
# Redraw metadata changes do not turn a waiting prompt into a new instance.
printf '%s\n' 2 >"$fixture_dir/events-revision"
events_poll
assert_count "$events_out" 1 '^PROMPT '
printf '%s\n' 2000000180 >"$clock_file"
events_poll
events_poll
assert_count "$events_out" 2 '^PROMPT '
assert_count "$events_out" 1 '^STALL '
assert_count "$events_out" 1 '^HEARTBEAT '
assert_line "$events_out" 'STALL events: no pane change for 3m'
# A disappearance then identical reappearance starts another prompt episode,
# even with the same timestamp. Restart dedup must not swallow that instance.
printf '%s\n' 'I am checking Run this command? in logs.' >"$fixture_dir/events-pane"
events_poll
assert_line "$events_out" 'AGENT events: blocked (fallback) -> unknown (fallback)'
assert_count "$events_out" 2 '^PROMPT '
printf '%s\n' 'Requesting permission for:' 'echo same' 'Run this command?' '❯ 1. Yes, approve' '  2. No, deny' >"$fixture_dir/events-pane"
events_poll
assert_count "$events_out" 3 '^PROMPT '
printf '%s\n' 2000000240 >"$clock_file"
events_poll
events_poll
assert_count "$events_out" 2 '^STALL '
assert_count "$events_out" 2 '^HEARTBEAT '
# Both report and pane terminals suppress stalls. Use the real DRAFT-PUBLISHED grammar.
printf '%s\n' 'DRAFT-PUBLISHED-events-a2' >"$events_report"
printf '%s\n' 2000000360 >"$clock_file"
events_poll
assert_count "$events_out" 2 '^STALL '
assert_line "$events_out" 'DRAFT-PUBLISHED events: DRAFT-PUBLISHED-events-a2'
rm "$events_report"
printf '%s\n' 'DRAFT-PUBLISHED-events-a2' >"$fixture_dir/events-pane"
events_poll
printf '%s\n' 2000000480 >"$clock_file"
events_poll
assert_count "$events_out" 2 '^STALL '
# Classified Codex and Claude episodes follow state, without fallback tagging.
rm "$fixture_dir/events-fallback"
printf '%s\n' blocked >"$fixture_dir/events-status"
printf '%s\n' 'Would you like to run the following command?' 'echo codex' '› 1. Yes, just this once (y)' '  2. No, and tell Codex what to do differently (esc)' '' '  Press enter to confirm or esc to cancel' >"$fixture_dir/events-pane"
events_poll
assert_line "$events_out" 'PROMPT events: Would you like to run the following command?'
printf '%s\n' working >"$fixture_dir/events-status"
printf '%s\n' 'working' >"$fixture_dir/events-pane"
events_poll
printf '%s\n' blocked >"$fixture_dir/events-status"
printf '%s\n' 'Do you want to proceed?' '❯ 1. Yes' '  2. No' >"$fixture_dir/events-pane"
events_poll
assert_line "$events_out" 'PROMPT events: Do you want to proceed?'
# Claude edit, create and command approvals each start a visible episode.
for approval in 'Do you want to make this edit to file.sh?' 'Do you want to create file.sh?' 'Do you want to run echo hello?'; do
    printf '%s\n' working >"$fixture_dir/events-status"
    printf '%s\n' working >"$fixture_dir/events-pane"
    events_poll
    printf '%s\n' blocked >"$fixture_dir/events-status"
    printf '%s\n' "$approval" '❯ 1. Yes' '  2. No, and tell Claude what to do differently (esc)' >"$fixture_dir/events-pane"
    events_poll
    assert_line "$events_out" "PROMPT events: $approval"
done
# A failed explain conveys no new state, including while approval stays live.
printf '%s\n' 'Requesting permission for:' 'echo same' 'Run this command?' '❯ 1. Yes, approve' '  2. No, deny' >"$fixture_dir/events-pane"
touch "$fixture_dir/events-fallback"
events_poll
agent_count="$(grep -c '^AGENT ' "$events_out")"
touch "$fixture_dir/events-fail-explain"
events_poll
events_poll
assert_count "$events_out" "$agent_count" '^AGENT '
assert_count "$events_out" 0 '^AGENT events: blocked \(fallback\) -> idle$'
rm "$fixture_dir/events-fail-explain" "$fixture_dir/events-fallback"
# A working classified lane never prompts for an answered dialog.
printf '%s\n' idle >"$fixture_dir/events-status"
for following in '› Write tests for @filename' 'Tests passed'; do
    printf '%s\n' 'Would you like to make the following edits?' \
        '› 1. Yes, just this once (y)' \
        '  2. No, and tell Codex what to do differently (esc)' \
        '  Press enter to confirm or esc to cancel' "$following" >"$fixture_dir/events-pane"
    prompt_count="$(grep -c '^PROMPT ' "$events_out")"
    events_poll
    printf '%s\n' 2000000720 >"$clock_file"
    events_poll
    assert_count "$events_out" "$prompt_count" '^PROMPT '
done
assert_line "$events_out" 'AGENT events: blocked (fallback) -> idle'
# Pane text alone never starts a classified prompt episode.
printf '%s\n' 'Do you want to create old.sh?' >"$fixture_dir/events-pane"
prompt_count="$(grep -c '^PROMPT ' "$events_out")"
events_poll
assert_count "$events_out" "$prompt_count" '^PROMPT '
# Keep enough following output for the independent usage-window regression.
for row in {1..9}; do printf 'working %s\n' "$row" >>"$fixture_dir/events-pane"; done
# Usage text above the last eight lines is historical output.
sed '1s/.*/Usage limit reached/' "$fixture_dir/events-pane" >"$test_tmp/usage-pane"
cp "$test_tmp/usage-pane" "$fixture_dir/events-pane"
events_poll
assert_count "$events_out" 0 '^USAGE-PAUSED events$'
printf '%s\n' 'Usage limit reached' >"$fixture_dir/events-pane"
events_poll
assert_count "$events_out" 1 '^USAGE-PAUSED events$'
# Failed visible reads report unknown age despite previously observed progress.
touch "$fixture_dir/events-fail-visible"
printf '%s\n' 2000000780 >"$clock_file"
events_poll
grep -Eq '^HEARTBEAT events: state=idle age=unknown pr=' "$events_out" || fail 'failed pane read retained heartbeat age'
rm "$fixture_dir/events-fail-visible"
# Failed list polls read only the visible pane: no explain/recent fan-out.
touch "$fixture_dir/events-fail-list"
: >"$fixture_dir/events-calls"
events_poll
assert_count "$fixture_dir/events-calls" 1 '^agent list$'
assert_count "$fixture_dir/events-calls" 1 '^agent read events --source visible '
assert_count "$fixture_dir/events-calls" 0 '^agent (explain|read events --source recent-unwrapped)'
rm "$fixture_dir/events-fail-list"
# Working panes cannot announce advisory sentinels or draft publications.
printf '%s\n' working >"$fixture_dir/events-status"
for terminal in MERGE-READY DRAFT-PUBLISHED BLOCKED; do
    events_state="$test_tmp/working-$terminal.state"
    printf '%s\n' "$terminal-events-a2" >"$fixture_dir/events-pane"
    events_poll
done
assert_count "$events_out" 0 '^(SENTINEL|DRAFT-PUBLISHED) events: .* \(pane only\)$'
# Fallback idle lanes still surface each pane-only terminal, including DRAFT-PUBLISHED.
touch "$fixture_dir/events-fallback"
for terminal in MERGE-READY DRAFT-PUBLISHED BLOCKED; do
    events_state="$test_tmp/fallback-$terminal.state"
    printf '%s\n' "$terminal-events-a2" >"$fixture_dir/events-pane"
    events_poll
    assert_line "$events_out" "SENTINEL events: $terminal-events-a2 (pane only)"
done
assert_line "$events_out" 'DRAFT-PUBLISHED events: DRAFT-PUBLISHED-events-a2 (pane only)'
rm "$fixture_dir/events-fallback"
# Transient failed/malformed explain reads never flap a normally working lane.
events_state="$test_tmp/explain-working.state"
printf '%s\n' working >"$fixture_dir/events-pane"
events_poll
agent_count="$(grep -c '^AGENT ' "$events_out")"
for explain_failure in events-fail-explain events-malformed-explain; do
    touch "$fixture_dir/$explain_failure"
    events_poll
    rm "$fixture_dir/$explain_failure"
    events_poll
    assert_count "$events_out" "$agent_count" '^AGENT '
done
# Classified approvals exist because herdr reports blocked, regardless of layout.
printf '%s\n' blocked >"$fixture_dir/events-status"
for dialog in run edit permissions terminal terminal-id tall-run; do
    case "$dialog" in
    run | tall-run) header='Would you like to run the following command?' ;;
    edit) header='Would you like to make the following edits?' ;;
    permissions) header='Would you like to grant these permissions?' ;;
    terminal) header='Would you like to send input to the existing terminal?' ;;
    terminal-id) header='Would you like to send input to terminal 123?' ;;
    esac
    events_state="$test_tmp/codex-$dialog.state"
    printf '  %s\n\n  Reason: run the gate outside the sandbox\n\n' "$header" >"$fixture_dir/events-pane"
    if [ "$dialog" = tall-run ]; then
        for row in {1..25}; do printf '  $ command line %s\n' "$row" >>"$fixture_dir/events-pane"; done
    fi
    printf '%s\n' '' '› 1. Yes, just this once (y)' \
        '  2. Yes, and do not ask again for this command in this session (a)' \
        '  3. No, and tell Codex what to do differently (esc)' '' \
        '  Press enter to confirm or esc to cancel' >"$test_tmp/codex-footer"
    cat "$test_tmp/codex-footer" >>"$fixture_dir/events-pane"
    prompt_count="$(grep -c '^PROMPT ' "$events_out")"
    events_poll
    assert_count "$events_out" "$((prompt_count + 1))" '^PROMPT '
    if [ "$dialog" = tall-run ]; then
        assert_line "$events_out" 'PROMPT events: (input requested; text not captured)'
    else
        assert_line "$events_out" "PROMPT events:   $header"
    fi
done
# Claude Code boxed option blocks are live even without a separate footer.
events_state="$test_tmp/claude-boxed.state"
cat >"$fixture_dir/events-pane" <<'DIALOG'
╭────────────────────────────────────────────────────────────────╮
│ Do you want to make this edit to main.py?                       │
│ ❯ 1. Yes                                                      │
│   2. Yes, allow all edits during this session (shift+tab)        │
│   3. No, and tell Claude what to do differently (esc)            │
╰────────────────────────────────────────────────────────────────╯
DIALOG
events_poll
assert_count "$events_out" 1 '^PROMPT events: │ Do you want to make this edit to main.py[?]'
# Actual hint rows and wrapped options are quotations, never prompt gates.
events_state="$test_tmp/claude-bash.state"
cat >"$fixture_dir/events-pane" <<'DIALOG'
╭──────────────────────────────────────────────────────────────╮
 Bash command

   task verify
   Run the definition-of-done gate

 Do you want to proceed?
 ❯ 1. Yes
   2. Yes, and don't ask again for task commands in this project
   3. No, and tell Claude what to do differently (esc)

 Esc to cancel · Tab to amend · ctrl+e to explain
DIALOG
prompt_count="$(grep -c '^PROMPT ' "$events_out")"
events_poll
assert_count "$events_out" "$((prompt_count + 1))" '^PROMPT '
# Leaving blocked ends the episode even with the same old dialog on screen.
printf '%s\n' working >"$fixture_dir/events-status"
events_poll
assert_count "$events_out" "$((prompt_count + 1))" '^PROMPT '
printf '%s\n' blocked >"$fixture_dir/events-status"
events_poll
assert_count "$events_out" "$((prompt_count + 2))" '^PROMPT '
events_state="$test_tmp/claude-edit.state"
cat >"$fixture_dir/events-pane" <<'DIALOG'
 Edit file
 scripts/foo.sh

 Do you want to make this edit to foo.sh?
 ❯ 1. Yes
   2. Yes, allow all edits during this session (shift+tab)
   3. No, and tell Claude what to do differently (esc)

 Esc to cancel
DIALOG
prompt_count="$(grep -c '^PROMPT ' "$events_out")"
events_poll
assert_count "$events_out" "$((prompt_count + 1))" '^PROMPT '
# Leaving blocked ends the episode even with the same old dialog on screen.
printf '%s\n' working >"$fixture_dir/events-status"
events_poll
assert_count "$events_out" "$((prompt_count + 1))" '^PROMPT '
printf '%s\n' blocked >"$fixture_dir/events-status"
events_poll
assert_count "$events_out" "$((prompt_count + 2))" '^PROMPT '
events_state="$test_tmp/codex-wrap.state"
cat >"$fixture_dir/events-pane" <<'DIALOG'
  Would you like to run the following command?

  Reason: run the gate outside the sandbox

  $ task verify

› 1. Yes, proceed (y)
  2. Yes, and don't ask again for commands that start with `task
     verify` (p)
  3. No, and tell Codex what to do differently (esc)

  Press enter to confirm or esc to cancel
DIALOG
prompt_count="$(grep -c '^PROMPT ' "$events_out")"
events_poll
assert_count "$events_out" "$((prompt_count + 1))" '^PROMPT '
# Leaving blocked ends the episode even with the same old dialog on screen.
printf '%s\n' working >"$fixture_dir/events-status"
events_poll
assert_count "$events_out" "$((prompt_count + 1))" '^PROMPT '
printf '%s\n' blocked >"$fixture_dir/events-status"
events_poll
assert_count "$events_out" "$((prompt_count + 2))" '^PROMPT '
# State-based episodes survive pane failure/redraws and re-emit on schedule.
events_state="$test_tmp/classified-episode.state"
printf '%s\n' 2000001000 >"$clock_file"
printf '%s\n' 'no question captured' >"$fixture_dir/events-pane"
prompt_count="$(grep -c '^PROMPT ' "$events_out")"
events_poll
assert_line "$events_out" 'PROMPT events: (input requested; text not captured)'
assert_count "$events_state" 1 '^PROMPT[[:space:]]+events:a2[[:space:]]+2000001000[[:space:]]+2000001000'
printf '%s\n' 'different pane text' >"$fixture_dir/events-pane"
events_poll
assert_count "$events_out" "$((prompt_count + 1))" '^PROMPT '
touch "$fixture_dir/events-fail-visible" "$fixture_dir/events-fail-explain"
printf '%s\n' 2000001180 >"$clock_file"
events_poll
assert_count "$events_out" "$((prompt_count + 2))" '^PROMPT '
assert_count "$events_state" 1 '^PROMPT[[:space:]]+events:a2[[:space:]]+2000001000[[:space:]]+2000001180'
rm "$fixture_dir/events-fail-explain"
printf '%s\n' working >"$fixture_dir/events-status"
events_poll
assert_count "$events_state" 0 '^PROMPT[[:space:]]+events:a2[[:space:]]'
printf '%s\n' blocked >"$fixture_dir/events-status"
events_poll
assert_count "$events_out" "$((prompt_count + 3))" '^PROMPT '
assert_count "$events_state" 1 '^PROMPT[[:space:]]+events:a2[[:space:]]+2000001180[[:space:]]+2000001180'
rm "$fixture_dir/events-fail-visible"
# A successful list is authoritative about disappearance, even if explain fails.
events_state="$test_tmp/disappeared.state"
printf '%s\n' working >"$fixture_dir/events-status"
events_poll
touch "$fixture_dir/events-absent" "$fixture_dir/events-fail-explain"
events_poll
assert_line "$events_out" 'AGENT events: working -> absent'
assert_count "$events_state" 1 '^AGENT[[:space:]]+events[[:space:]]+absent[[:space:]]'
rm "$fixture_dir/events-absent" "$fixture_dir/events-fail-explain"
# Answered agy dialogs cannot remain blocked or re-emit prompts.
touch "$fixture_dir/events-fallback"
for answered_row in Approved 'Command completed' '› Type your next request'; do
    events_state="$test_tmp/answered-agy.state"
    events_out="$test_tmp/answered-agy.out"
    rm -f "$events_state"
    : >"$events_out"
    printf '%s\n' 'Run this command?' '❯ 1. Yes, approve' '  2. No, deny' \
        "$answered_row" >"$fixture_dir/events-pane"
    events_poll
    printf '%s\n' 2000001360 >"$clock_file"
    events_poll
    assert_count "$events_out" 0 '^PROMPT '
    assert_count "$events_out" 0 '^AGENT .* -> blocked \(fallback\)$'
done
# The reported question followed by approval/completion output is answered too.
printf '%s\n' 'Requesting permission for:' 'echo same' 'Run this command?' \
    Approved 'Command completed' >"$fixture_dir/events-pane"
events_poll
assert_count "$events_out" 0 '^PROMPT '
assert_count "$events_out" 0 '^AGENT .* -> blocked \(fallback\)$'
rm "$fixture_dir/events-fallback"
# Quotes prefer known bottom-of-pane headers, including Codex MCP approvals
# without a question mark, rather than questions elsewhere in the transcript.
printf '%s\n' blocked >"$fixture_dir/events-status"
events_out="$test_tmp/excerpt.out"
: >"$events_out"
events_state="$test_tmp/mcp-excerpt.state"
cat >"$fixture_dir/events-pane" <<'DIALOG'
• Should I also delete the old release branch? I will wait for the gate first.

• Calling github.create_pull_request

  github needs your approval.

  Tool: create_pull_request

› 1. Approve this call (y)
  2. Deny (esc)

  Press enter to confirm or esc to cancel
DIALOG
events_poll
assert_line "$events_out" 'PROMPT events:   github needs your approval.'
assert_count "$events_out" 0 'Should I also delete'
events_state="$test_tmp/old-question-excerpt.state"
printf '%s\n' 'Would you like to run the following command?' >"$fixture_dir/events-pane"
for row in {1..25}; do printf 'transcript output %s\n' "$row" >>"$fixture_dir/events-pane"; done
events_poll
assert_line "$events_out" 'PROMPT events: (input requested; text not captured)'
assert_count "$events_out" 0 'Would you like to run'
# Integration 1: list availability must not alter an unchanged-pane episode.
events_out="$test_tmp/list-failure-stall.out"
: >"$events_out"
events_state="$test_tmp/list-failure-stall.state"
printf '%s\n' working >"$fixture_dir/events-status"
printf '%s\n' 'unchanged work' >"$fixture_dir/events-pane"
printf '%s\n' 2100000000 >"$clock_file"
events_poll
touch "$fixture_dir/events-fail-list"
printf '%s\n' 2100000030 >"$clock_file"
events_poll
printf '%s\n' 2100000060 >"$clock_file"
events_poll
assert_line "$events_out" 'STALL events: no pane change for 1m'
rm "$fixture_dir/events-fail-list"
printf '%s\n' 2100000090 >"$clock_file"
events_poll
touch "$fixture_dir/events-fail-list"
printf '%s\n' 2100000120 >"$clock_file"
events_poll
rm "$fixture_dir/events-fail-list"
printf '%s\n' 2100000180 >"$clock_file"
events_poll
assert_count "$events_out" 1 '^STALL '
assert_count "$events_state" 1 '^PROGRESS[[:space:]]+events:a2[[:space:]]+[^[:space:]]+[[:space:]]+2100000000[[:space:]]+1$'

# Integration 2/3: missing pane reads preserve fallback state; failed explains
# still permit reminders when a successful pane read confirms the approval.
events_out="$test_tmp/fallback-read-failures.out"
: >"$events_out"
events_state="$test_tmp/fallback-read-failures.state"
touch "$fixture_dir/events-fallback"
printf '%s\n' 'Requesting permission for:' 'echo same' 'Run this command?' \
    '❯ 1. Yes, approve' '  2. No, deny' >"$fixture_dir/events-pane"
events_poll
touch "$fixture_dir/events-fail-visible"
events_poll
rm "$fixture_dir/events-fail-visible"
events_poll
assert_count "$events_out" 1 '^AGENT '
assert_count "$events_out" 0 '^AGENT .*blocked \(fallback\) -> unknown \(fallback\)$'
touch "$fixture_dir/events-fail-explain"
printf '%s\n' 2100000360 >"$clock_file"
events_poll
assert_count "$events_out" 2 '^PROMPT events: Requesting permission for: echo same \(fallback\)$'
assert_count "$events_out" 1 '^AGENT '
rm "$fixture_dir/events-fail-explain" "$fixture_dir/events-fallback"

# Integration 4: blocked input is not necessarily an approval.
events_out="$test_tmp/blocked-question.out"
: >"$events_out"
events_state="$test_tmp/blocked-question.state"
printf '%s\n' blocked >"$fixture_dir/events-status"
printf '%s\n' 'Which deployment target should I use?' >"$fixture_dir/events-pane"
events_poll
assert_line "$events_out" 'PROMPT events: (input requested; text not captured)'
assert_count "$events_out" 0 'approval prompt'
grep -qF 'Read the full pane with' "$repo_root/ai/skills/universal/orchestrate/SKILL.md" || fail 'prompt guidance omits full pane read'
grep -qF 'A Herdr `blocked` state can be a question rather than an approval' "$repo_root/ai/skills/universal/orchestrate/SKILL.md" || fail 'prompt guidance treats all input as approval'

# Integration 5: zero-padded thresholds are decimal (08 means eight minutes).
events_out="$test_tmp/decimal-options.out"
: >"$events_out"
events_state="$test_tmp/decimal-options.state"
printf '%s\n' working >"$fixture_dir/events-status"
printf '%s\n' 'unchanged work' >"$fixture_dir/events-pane"
printf '%s\n' 2100001000 >"$clock_file"
events_poll --stall-minutes 08 --heartbeat-minutes 09 --prompt-reemit-seconds 08
assert_count "$events_out" 0 '^STALL '
printf '%s\n' 2100001480 >"$clock_file"
events_poll --stall-minutes 08 --heartbeat-minutes 09 --prompt-reemit-seconds 08
assert_line "$events_out" 'STALL events: no pane change for 8m'

# Integration 6: each numeric supervision field rejects corrupt persisted data.
for corrupt_field in progress-time progress-marker prompt-first prompt-last heartbeat; do
    events_out="$test_tmp/corrupt-$corrupt_field.out"
    : >"$events_out"
    events_state="$test_tmp/corrupt-$corrupt_field.state"
    case "$corrupt_field" in
    progress-time) corrupt_row='PROGRESS\tevents:a2\tfingerprint\tbadtime\t0' ;;
    progress-marker) corrupt_row='PROGRESS\tevents:a2\tfingerprint\t2100002000\tbadmarker' ;;
    prompt-first) corrupt_row='PROMPT\tevents:a2\tbadfirst\t2100002000' ;;
    prompt-last) corrupt_row='PROMPT\tevents:a2\t2100002000\tbadlast' ;;
    heartbeat) corrupt_row='HEARTBEAT\trun\tbadtime' ;;
    esac
    printf '%b\n' "$corrupt_row" >"$events_state"
    printf '%s\n' blocked >"$fixture_dir/events-status"
    printf '%s\n' 2100002000 >"$clock_file"
    events_poll 2>"$test_tmp/corrupt-$corrupt_field.err"
    assert_count "$events_state" 0 'badtime|badmarker|badfirst|badlast'
    assert_count "$test_tmp/corrupt-$corrupt_field.err" 0 'syntax error|unbound variable|value too great for base'
    assert_count "$events_state" 1 '^PROGRESS[[:space:]]+events:a2[[:space:]]+[^[:space:]]+[[:space:]]+2100002000[[:space:]]+0$'
    assert_count "$events_state" 1 '^PROMPT[[:space:]]+events:a2[[:space:]]+2100002000[[:space:]]+2100002000'
    assert_count "$events_state" 1 '^HEARTBEAT[[:space:]]+run[[:space:]]+2100002000'
done

# Integration 7: deliver STALL even when persisting its dedup marker fails.
persistfail_dir="$test_tmp/persist-fail-state"
mkdir -p "$persistfail_dir"
events_out="$test_tmp/stall-before-persist.out"
: >"$events_out"
events_state="$persistfail_dir/stall-order.state"
printf '%s\n' working >"$fixture_dir/events-status"
printf '%s\n' 2100003000 >"$clock_file"
events_poll
touch "$fixture_dir/fail-mv"
printf '%s\n' 2100003060 >"$clock_file"
if events_poll 2>"$test_tmp/stall-before-persist.err"; then
    fail 'STALL persistence fault unexpectedly succeeded'
fi
rm "$fixture_dir/fail-mv"
assert_line "$events_out" 'STALL events: no pane change for 1m'
assert_count "$test_tmp/stall-before-persist.err" 1 'could not persist state'
assert_count "$events_state" 1 '^PROGRESS[[:space:]]+events:a2[[:space:]]+[^[:space:]]+[[:space:]]+2100003000[[:space:]]+0$'

# Integration 8: zero thresholds are polling controls, not disable switches.
bash "$watcher" --help >"$test_tmp/usage.txt"
assert_line "$test_tmp/usage.txt" '  A value of 0 for the three options above means "every poll", not "disabled".'
rm "$fixture_dir/events-mode"

# Cloud heartbeat tracks branch/PR age without any Herdr reads or local events.
touch "$fixture_dir/cloud-only"
cloud_heartbeat_state="$test_tmp/cloud-heartbeat.state"
cloud_heartbeat_out="$test_tmp/cloud-heartbeat.out"
: >"$cloud_heartbeat_out"
for events_time in 2000000000 2000000060 2000000060; do
    printf '%s\n' "$events_time" >"$clock_file"
    PATH="$clock_bin:$PATH" WATCH_CLOCK="$clock_file" WATCH_REAL_DATE="$real_date" \
        bash "$watcher" --iterations 1 --state-file "$cloud_heartbeat_state" \
        --registry "$registry" --heartbeat-minutes 1 --stall-minutes 0 \
        2099-01-01T00:00:00Z \
        cloud:claude/cloud-fixture:nc:evanharmon1/harmon-devkit:cloud >>"$cloud_heartbeat_out"
done
assert_count "$cloud_heartbeat_out" 1 '^HEARTBEAT '
assert_count "$cloud_heartbeat_out" 0 '^(PROMPT|STALL|AGENT) '
grep -Eq '^HEARTBEAT cloud: state=cloud age=60s pr=' "$cloud_heartbeat_out" || fail 'cloud heartbeat lacks age and PR state'
[ ! -f "$fixture_dir/cloud-herdr-calls" ] || fail 'cloud heartbeat read Herdr'
rm "$fixture_dir/cloud-only"
echo 'PASS: lane watcher prompt episodes, fallback, stalls and heartbeat'

# Every watcher event-output file uses .out, including parity, events.out,
# answered-agy.out, the redeclared events_out (excerpt.out), and cloud heartbeat.
# Invalid-input diagnostics are .err files and do not contain event streams.
# Run this last so all event families and every output file are checked.
lane_pattern='[A-Za-z0-9_-]+'
state_pattern='(absent|unknown|working|idle|blocked|done)( \(fallback\))?'
pr_pattern='#[0-9]+ draft=(true|false) (OPEN|CLOSED|MERGED) head=[0-9A-Fa-f]{8,64}'
heartbeat_lane_pattern="$lane_pattern: state=(cloud|$state_pattern) age=(unknown|[0-9]+s) pr=(absent|$pr_pattern)"
event_patterns=(
    "PROMPT $lane_pattern: .{1,300}( \(fallback\))?"
    "AGENT $lane_pattern: (init|$state_pattern) -> $state_pattern"
    "STALL $lane_pattern: no pane change for [0-9]+m"
    "HEARTBEAT $heartbeat_lane_pattern(; $heartbeat_lane_pattern)*"
    "SENTINEL $lane_pattern: (MERGE-READY|DRAFT-PUBLISHED|BLOCKED)-[A-Za-z0-9_-]+-[A-Za-z0-9_-]+( \(pane only\))?"
    "DRAFT-PUBLISHED $lane_pattern: DRAFT-PUBLISHED-[A-Za-z0-9_-]+-[A-Za-z0-9_-]+( \(pane only\))?"
    "BRANCH $lane_pattern: (absent|[^[:space:]]+ head=[0-9A-Fa-f]{8})"
    "PR $lane_pattern: #[0-9]+ draft=(true|false) (OPEN|CLOSED|MERGED) head=[0-9A-Fa-f]{8}"
    "PR-ACTIVITY $lane_pattern: #[0-9]+ [^[:space:]]+ (review|comment|inline) [0-9]+ updated=[0-9]+ revision=[0-9]+"
    "PR-THREAD $lane_pattern: #[0-9]+ [A-Za-z0-9_=-]+ (opened|reopened) generation=[0-9]+"
    "PR-CI $lane_pattern: #[0-9]+ head=[0-9A-Fa-f]{8} required=.+"
    "PR-BEHIND $lane_pattern: #[0-9]+ base=[0-9A-Fa-f]{40,64} behind_by=[0-9]+"
    "PR-(MERGED|CLOSED) $lane_pattern: #[0-9]+ head=[0-9A-Fa-f]{8}"
    "PR-WATCHING $lane_pattern: #[0-9]+ head=[0-9A-Fa-f]{8} draft=(true|false)"
    "PR-UNREADABLE $lane_pattern: #[0-9]+ reason=.+"
    "RATE-LIMITED github: until=[0-9]+"
    "WATCH-COMPLETE run: no active specs"
    "OBSERVATION-DEGRADED $lane_pattern: .+"
    "USAGE-PAUSED $lane_pattern"
    "WALLCLOCK (run|$lane_pattern): .+"
)
event_grammar="^($(
    IFS='|'
    printf '%s' "${event_patterns[*]}"
))$"
grammar_status=0
grep -Env "$event_grammar" "$test_tmp"/*.out "$parity_dir"/*.out || grammar_status=$?
[ "$grammar_status" -eq 1 ] || fail 'watcher emitted a line outside the documented event grammar'
echo 'PASS: every lane watcher event output matches the stable event grammar'
