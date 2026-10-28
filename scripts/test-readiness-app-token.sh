#!/usr/bin/env bash
# Self-contained real-gate fixtures for App authentication. No live API calls.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
gate="${APP_TEST_GATE:-$repo_root/ai/skills/universal/integrate/assets/readiness-gate.sh}"
validator="$repo_root/ai/skills/universal/dev-flow-support/assets/validate-result-schemas.mjs"
test_tmp="$(mktemp -d -t readiness-app-test-XXXXXX)"
trap 'rm -rf "$test_tmp"' EXIT
bin_dir="$test_tmp/bin"
fixtures="$test_tmp/fixtures"
record_dir="$test_tmp/record"
log="$test_tmp/argv.log"
mkdir -p "$bin_dir" "$fixtures" "$record_dir/adjudications" "$record_dir/passes"
fail() {
    # shell-robustness: ok — always exits, so its status is never read
    echo "FAIL: $*" >&2
    exit 1
}
head_sha=1111111111111111111111111111111111111111
git -C "$repo_root" rev-parse HEAD >"$fixtures/asset-base"
export GH_FIXTURES="$fixtures" APP_ARGV_LOG="$log" APP_AUTH_LOG="$test_tmp/auth.log"
export APP_TEST_TOKEN=installation-token-fixture APP_TEST_PRIVATE_KEY=private-key-fixture
real_timeout="$(command -v timeout || command -v gtimeout)"
export APP_REAL_TIMEOUT="$real_timeout"
export PATH="$bin_dir:$PATH"
cat >"$bin_dir/timeout" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >>"$APP_ARGV_LOG"
if [ "${4:-}" = "${READINESS_APP_TOKEN_HELPER:-}" ]; then
    exec "$APP_REAL_TIMEOUT" -k 1 0.1 "${@:4}"
fi
exec "$APP_REAL_TIMEOUT" "$@"
STUB
cat >"$bin_dir/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >>"$APP_ARGV_LOG"
if [ "$1" = pr ]; then
    if [[ "$*" = *'--json baseRefOid --jq .baseRefOid'* ]]; then
        cat "$GH_FIXTURES/asset-base"
    else
        jq -s '.[0] + .[1]' "$GH_FIXTURES/pr-view.json" "$GH_FIXTURES/closing-view.json"
    fi
    exit
fi
endpoint=
for arg in "$@"; do
    case "$arg" in repos/* | graphql | user) endpoint="$arg"; break ;; esac
done
case "$endpoint" in
*/check-runs* | */statuses*)
    if [ "${GH_TOKEN:-}" = "$APP_TEST_TOKEN" ]; then
        [ "${GH_ENTERPRISE_TOKEN:-}" = "$APP_TEST_TOKEN" ] || exit 91
        echo app-read >>"$APP_AUTH_LOG"
    elif [ "${APP_PAT_ALLOWED:-0}" != 1 ]; then
        echo 'gh: Resource not accessible by personal access token (HTTP 403)' >&2
        exit 1
    fi
    ;;
*) [ "${GH_TOKEN:-}" != "$APP_TEST_TOKEN" ] || exit 92 ;;
esac
case "$endpoint" in
*/rules/branches/*) printf '%s\n' '[[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"build","integration_id":null}]}}]]'; exit ;;
*/protection/required_status_checks) printf '%s\n' '{"contexts":[],"checks":[]}'; exit ;;
graphql) printf '%s\n' '[{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}]'; exit ;;
*/check-runs*) file=check-runs.pages.json ;;
*/statuses*) file=statuses.pages.json ;;
*/actions/runs*) file=workflow-runs.pages.json ;;
*/git/ref/heads/*) file=live-base.json ;;
*/compare/*) file=compare.json ;;
*/pulls/*/comments*) file=inline.pages.json ;;
*/pulls/*/reviews*) file=reviews.pages.json ;;
*/issues/*/comments*) file=top.pages.json ;;
*/issues/*) file=issue.json ;;
*/pulls/*) file=pr.json ;;
user) file=user.json ;;
*) echo "unhandled endpoint: $endpoint" >&2; exit 93 ;;
esac
cat "$GH_FIXTURES/$file"
STUB
chmod +x "$bin_dir/gh" "$bin_dir/timeout"

default_body() {
    cat <<'BODY'
What/why prose.


- task verify
BODY
}

lifecycle_transitions() {
    jq -cn --arg ended "${1:-}" --argjson loops "${2:-0}" '
      ([["kickoff","claimed"],["claim","planned"],["plan","briefed"],
        ["implement","verified"],["verify","green"],["challenge","converged"],
        ["review","converged"],["security","clean"]]
       + ([range(0; $loops)] | map(
           [["integration","remediating"],["implement","fixed"],
            ["verify","green"],["security","clean"]]) | add // [])
       + [["integration","converged"]])
      | to_entries
      | map({stage: .value[0],
             entered_at: ("2026-01-01T00:" + (.key | tostring | ("0" * (2 - length)) + .) + ":00Z"),
             exit: .value[1]})
      | if $ended == "ended" then . else (.[-1] |= del(.exit)) end'
}

write_finder_policy() {
    jq -cn --argjson finders "$1" --argjson entries "${2:-[]}" '
      {rigor:{level:"standard",source:"test"},
       rounds:{challenge:100,review:100,integration:100,remediation:100,min_rounds:1},
       stages:{integration:{finders:$finders,finder:$entries}}}' >"${record_dir}/policy.json"
}

write_default_record() {
    jq -cn --arg head "$head_sha" --argjson transitions "$(lifecycle_transitions)" '
      {schema:2, run_id:"test-run", initiated_by:"human",
       started_at:"2026-01-01T00:00:00Z",
       stage_transitions:$transitions,
       interventions:[], outcome:null,
       pr:{number:493,url:"https://github.com/example/repo/pull/493"},
       evidence_comments:[], settlements:[], promotion:null,
       evidence_registrations:[], outcome_transitions:[],
       pr_bindings:[{seq:0,prev_digest:"genesis",
         digest:"ec64b9703afdb8ec84d58495e89b4b11dc8c0a96720b330f649e0fe10a498ec1",
         number:493,url:"https://github.com/example/repo/pull/493",
         bound_at:"2026-01-01T00:00:00Z"}]}' \
        >"${record_dir}/run.json"
    rm -f "${record_dir}"/adjudications/*.json "${record_dir}"/passes/*.json "${record_dir}/policy.json"
    write_finder_policy '["codex-cloud"]'
}

write_integrator_result() {
    local name="$1" codex_cycle="$2" head="${3:-$head_sha}"
    local out="${fixtures}/integrator-result-${name}.json"
    local exit_code
    exit_code="$(jq -r '.exit_code // "null"' <<<"$codex_cycle")"
    local verdict findings='[]' checks='[]'
    case "$exit_code" in
    null | 0)
        verdict=clean
        checks='[{"name":"build","bucket":"pass","run_id":"1","required":true}]'
        ;;
    10)
        verdict=findings
        findings='[{"id":"integration-r1-codex-cloud-1","body":"a finding","source_id":"1"}]'
        ;;
    11 | 12 | 16) verdict=pending ;;
    13 | 14 | 15 | 19 | 2) verdict=escalate ;;
    *) verdict=pending ;;
    esac
    jq -cn --arg head "$head" --argjson codex_cycle "$codex_cycle" \
        --argjson checks "$checks" --argjson findings "$findings" \
        --arg verdict "$verdict" '
      {schema:2, role:"integrator", status:"completed", head:$head,
       produced_at:"2026-01-01T00:00:00Z",
       producer:{harness:"claude-code",model:"test",tier:"economy"},
       run:{run_id:"test-run",initiated_by:"human"},
       payload:({checks:$checks, codex_cycle:$codex_cycle, integration_round:1,
                 findings:$findings, unanswered_thread_roots:[],
                 settled_at:"2026-01-01T00:00:00Z", verdict:$verdict}
         + (if $verdict == "clean" then {applied_dispositions:[]} else {} end))}' \
        >"$out"
    node "$validator" envelope "$out" >/dev/null ||
        fail "write_integrator_result $name: fixture failed schema validation"
    printf '%s' "$out"
}

write_defaults() {
    jq -cn --arg head "$head_sha" \
        '{state:"OPEN",isDraft:true,headRefOid:$head,
          reviewDecision:"REVIEW_REQUIRED",mergeStateStatus:"BLOCKED",
          headRefName:"feature-branch",baseRefName:"main",baseRefOid:"b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0"}' \
        >"${fixtures}/pr-view.json"
    jq -cn --arg body "$(default_body)" \
        '{body:$body,closingIssuesReferences:[]}' \
        >"${fixtures}/closing-view.json"
    jq -cn --arg head "$head_sha" --arg body "$(default_body)" \
        '{number:493,title:"feat: change",body:$body,
          head:{sha:$head},user:{id:4242,login:"pr-author"}}' \
        >"${fixtures}/pr.json"
    jq -cn '[{total_count:2,check_runs:[
        {name:"build",status:"completed",conclusion:"success"},
        {name:"optional",status:"completed",conclusion:"skipped"}]}]' \
        >"${fixtures}/check-runs.pages.json"
    jq -cn '[[{context:"ci/legacy",state:"pending",id:1},
              {context:"ci/legacy",state:"success",id:3}]]' \
        >"${fixtures}/statuses.pages.json"
    printf '%s\n' '[{"total_count":0,"workflow_runs":[]}]' \
        >"${fixtures}/workflow-runs.pages.json"
    jq -cn '{behind_by:0,ahead_by:1,status:"ahead",base_commit:{sha:"b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0"}}' >"${fixtures}/compare.json"
    jq -cn '{object:{sha:"b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0"}}' >"${fixtures}/live-base.json"
    jq -cn '{login:"pr-author"}' >"${fixtures}/user.json"
    jq -cn '{number:380}' >"${fixtures}/issue.json"
    printf '%s\n' '[[]]' >"${fixtures}/inline.pages.json"
    printf '%s\n' '[[]]' >"${fixtures}/reviews.pages.json"
    printf '%s\n' '[[]]' >"${fixtures}/top.pages.json"
    printf '%s\n' '[]' >"${fixtures}/resolved-roots.json"
    rm -f "${fixtures}/threads.pages.json" "${fixtures}/rules.pages.json" "${fixtures}/classic-checks.json"
    rm -f "${fixtures}/fail-endpoint" "${fixtures}/fail-diagnostic" "${fixtures}/fail-body"
    rm -f "${fixtures}/fail-closing-references"
    rm -f "${fixtures}/pr-view-count" "${fixtures}/pr-view-second.json" "${fixtures}/pr-view-third.json"
    rm -f "${fixtures}/second-closing-view.json"
    rm -f "${fixtures}"/issue-*.json
    rm -f "${fixtures}"/count-* "${fixtures}"/second-* "${fixtures}"/third-*
    rm -f "${fixtures}/ro-exit"
    : >"$log"
    write_default_record
    write_integrator_result disabled null >/dev/null
}

assert_gate() {
    expected_rc=$1
    expected_status=$2
    expected_condition=$3
    [ "$gate_rc" -eq "$expected_rc" ] ||
        fail "expected rc $expected_rc, got $gate_rc: $gate_out"
    actual_status="$(gate_field status 2>/dev/null || true)"
    [ "$actual_status" = "$expected_status" ] ||
        fail "expected status $expected_status, got '$actual_status': $gate_out"
    actual_condition="$(gate_field condition 2>/dev/null || true)"
    [ "$actual_condition" = "$expected_condition" ] ||
        fail "expected condition $expected_condition, got '$actual_condition': $gate_out"
}

gate_field() {
    printf '%s\n' "$gate_out" | sed -n '/^{/p' | tail -n 1 | jq -r --arg f "$1" '.[$f]'
}
run_gate() {
    local trace="${1:-}"
    set +e
    if [ "$trace" = trace ]; then
        gate_out="$(bash -x "$gate" check --repo example/repo --pr 493 --head "$head_sha" \
            --record "$record_dir" --integrator-result "$fixtures/integrator-result-disabled.json" \
            --integration-cap 0 --remediation-cap 4 2>&1)"
    else
        gate_out="$("$gate" check --repo example/repo --pr 493 --head "$head_sha" \
            --record "$record_dir" --integrator-result "$fixtures/integrator-result-disabled.json" \
            --integration-cap 0 --remediation-cap 4 2>&1)"
    fi
    gate_rc=$?
    set -e
    for secret in "$APP_TEST_TOKEN" "$APP_TEST_PRIVATE_KEY"; do
        [[ "$gate_out" != *"$secret"* ]] || fail "secret appeared in stdout/stderr"
        ! grep -Fq "$secret" "$APP_ARGV_LOG" || fail "secret appeared in argv"
    done
}
write_helper() {
    cat >"$bin_dir/app-token" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >>"$APP_ARGV_LOG"
[ "$#" -eq 1 ] && [ "$1" = example/repo ] || exit 1
echo mint >>"$APP_AUTH_LOG"
case "$APP_HELPER_MODE" in
fail) printf '%s\n' "$APP_TEST_PRIVATE_KEY" >&2; exit 7 ;;
empty) exit 0 ;;
multiline) printf 'one\ntwo\n' ;;
cr) printf 'junk\rvalue\n' ;;
hang) sleep 2; printf '%s\n' "$APP_TEST_TOKEN" ;;
*) printf '%s\n' "$APP_TEST_TOKEN" ;;
esac
STUB
    chmod +x "$bin_dir/app-token"
}
write_helper
for fixture in pat success fallback empty multiline cr hang trace path nonexec diagnostic; do
    [ -z "${APP_TEST_CASE:-}" ] || [ "$fixture" = "$APP_TEST_CASE" ] || continue
    echo "==> App authentication: $fixture"
    write_defaults
    : >"$APP_AUTH_LOG"
    export READINESS_APP_TOKEN_HELPER="$bin_dir/app-token" APP_HELPER_MODE=success APP_PAT_ALLOWED=0
    case "$fixture" in
    pat) unset READINESS_APP_TOKEN_HELPER ;;
    fallback) export APP_HELPER_MODE=fail APP_PAT_ALLOWED=1 ;;
    empty | multiline | cr | hang) export APP_HELPER_MODE="$fixture" APP_PAT_ALLOWED=1 ;;
    path) export READINESS_APP_TOKEN_HELPER=app-token APP_PAT_ALLOWED=1 ;;
    nonexec)
        export READINESS_APP_TOKEN_HELPER="$test_tmp/nonexec" APP_PAT_ALLOWED=1
        : >"$test_tmp/nonexec"
        ;;
    diagnostic) export APP_HELPER_MODE=fail APP_PAT_ALLOWED=1 ;;
    esac
    if [ "$fixture" = trace ]; then run_gate trace; else run_gate; fi
    case "$fixture" in
    success | trace)
        assert_gate 0 pass ready
        awk 'NR % 2 == 1 && $0 != "mint" {exit 1}
             NR % 2 == 0 && $0 != "app-read" {exit 1}
             END {if (NR < 4 || NR % 2 != 0) exit 1}' "$APP_AUTH_LOG" || fail "missing fresh mint before read"
        ;;
    *)
        assert_gate 2 indeterminate fetch-failed
        case "$fixture" in
        pat) expected='cannot fetch check runs for the head' ;;
        diagnostic) expected='App token helper failed (exit 7)' ;;
        path | nonexec) expected='App token helper failed (invalid executable path)' ;;
        *) expected= ;;
        esac
        [ -z "$expected" ] || [ "$(gate_field detail)" = "$expected" ] || fail "wrong diagnostic: $gate_out"
        ;;
    esac
done
echo 'PASS: self-contained readiness App authentication, fail-closed helpers, timeout, xtrace and secret argv'
