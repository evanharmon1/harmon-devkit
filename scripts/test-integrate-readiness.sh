#!/usr/bin/env bash
# Hermetic regression tests for the integration-stage readiness gate and the
# read-only gh wrapper (ai/skills/universal/integrate/assets/readiness-gate.sh,
# gh-ro.sh) — formerly the shepherd stage's; renamed with the stage, see
# specs/dev-flow-v2.md.
#
# The point of the gate is that no condition can be printed-and-promoted past:
# every fixture below asserts an exit code AND the machine token naming the
# decisive condition, and the full-pass fixture asserts the fingerprint is
# printed and stable. gh is stubbed on PATH; nothing talks to the network.
#
# The gate is NOT fully hermetic any more: it resolves render-dev-flow.sh and
# validate-result-schemas.mjs from the sibling `dev-flow-support` skill package
# (`$script_dir/../../dev-flow-support/assets`, harmon-devkit#974 — it used to
# reach for the checkout's `git rev-parse --show-toplevel`), so those two run
# for REAL against the record/integrator-result fixtures this file builds,
# rather than being stubbed. That is deliberate — it proves the integration,
# not just that the gate calls the right command name — and it is why `gate`
# below is called directly from its real path: a copy of the gate resolves its
# helpers relative to WHERE IT WAS COPIED, so any copied-gate fixture has to
# reproduce the package layout around it (see recheck_dir below, which does).

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
assets="${repo_root}/ai/skills/universal/integrate/assets"
gate="${assets}/readiness-gate.sh"
ghro="${assets}/gh-ro.sh"
ghwb="${assets}/gh-write-broker.sh"
validator="${repo_root}/ai/skills/universal/dev-flow-support/assets/validate-result-schemas.mjs"
test_tmp="$(mktemp -d -t integrate-readiness-test-XXXXXX)"
trap 'rm -rf "$test_tmp"' EXIT

bin_dir="${test_tmp}/bin"
fixtures="${test_tmp}/fixtures"
record_dir="${test_tmp}/record"
log="${test_tmp}/gh.log"
mkdir -p "$bin_dir" "$fixtures" "$record_dir/adjudications" "$record_dir/passes"

fail() {
    # shell-robustness: ok — always exits, so its status is never read
    echo "FAIL: $*" >&2
    exit 1
}

# Watchdog for gate invocations, same idiom as test-integrate-codex.sh: a
# fired watchdog means the helper hung, which is a distinct failure from any
# assertion below.
watchdog_bin=
if command -v timeout >/dev/null 2>&1; then
    watchdog_bin=timeout
elif command -v gtimeout >/dev/null 2>&1; then
    watchdog_bin=gtimeout
else
    fail "GNU timeout is required for the test suite's hang watchdog (coreutils; gtimeout on macOS)"
fi
watchdog_sec=120

check_watchdog() {
    rc=$1
    label=$2
    output=$3
    [ "$rc" -ne 124 ] && [ "$rc" -ne 137 ] ||
        fail "$label: watchdog fired after ${watchdog_sec}s — genuinely hung, not an assertion mismatch: $output"
}

cat >"${bin_dir}/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$GH_LOG"

# gh-ro pass-through cases: exit with a scripted code so propagation is
# observable without any endpoint dispatch.
if [ -f "$GH_FIXTURES/ro-exit" ]; then
    exit "$(cat "$GH_FIXTURES/ro-exit")"
fi

if [ "${1:-}" = pr ] && [ "${2:-}" = view ]; then
    if [ -f "$GH_FIXTURES/fail-closing-references" ] &&
        [[ "$*" = *closingIssuesReferences* ]]; then
        exit 94
    fi
    count_file="$GH_FIXTURES/pr-view-count"
    count=0
    [ ! -f "$count_file" ] || count="$(cat "$count_file")"
    count=$((count + 1))
    printf '%s\n' "$count" >"$count_file"
    if [ "$count" -ge 3 ] && [ -f "$GH_FIXTURES/pr-view-third.json" ]; then
        file="$GH_FIXTURES/pr-view-third.json"
    elif [ "$count" -ge 2 ] && [ -f "$GH_FIXTURES/pr-view-second.json" ]; then
        file="$GH_FIXTURES/pr-view-second.json"
    else
        file="$GH_FIXTURES/pr-view.json"
    fi
    if [[ "$*" = *closingIssuesReferences* ]]; then
        linkage="$GH_FIXTURES/closing-view.json"
        if [ "$count" -ge 3 ] && [ -f "$GH_FIXTURES/second-closing-view.json" ]; then
            linkage="$GH_FIXTURES/second-closing-view.json"
        fi
        jq -c --slurpfile linkage "$linkage" \
            '. + $linkage[0]' "$file"
    else
        cat "$file"
    fi
    exit 0
fi

[ "${1:-}" = api ] || exit 90
shift
endpoint=
skip_next=0
for arg in "$@"; do
    if [ "$skip_next" = 1 ]; then
        skip_next=0
        continue
    fi
    case "$arg" in
    --paginate | --slurp) ;;
    --method | -F | -f | --jq | -q) skip_next=1 ;;
    *) [ -n "$endpoint" ] || endpoint=$arg ;;
    esac
done
[ -n "$endpoint" ] || exit 91

if [ -f "$GH_FIXTURES/fail-endpoint" ] &&
    grep -Fq "$(cat "$GH_FIXTURES/fail-endpoint")" <<<"$endpoint"; then
    exit 92
fi

case "$endpoint" in
user) file=user.json ;;
graphql) file=threads.pages.json ;;
repos/*/pulls/*/comments*) file=inline.pages.json ;;
repos/*/pulls/*/reviews*) file=reviews.pages.json ;;
repos/*/issues/*/comments*) file=top.pages.json ;;
repos/*/issues/[0-9]*)
    issue_number="${endpoint##*/}"
    file="issue-${issue_number}.json"
    [ -f "$GH_FIXTURES/$file" ] || file=issue.json
    ;;
repos/*/commits/*/check-runs*) file=check-runs.pages.json ;;
repos/*/commits/*/statuses*) file=statuses.pages.json ;;
repos/*/actions/runs*) file=workflow-runs.pages.json ;;
repos/*/compare/*) file=compare.json ;;
repos/*/pulls/*) file=pr.json ;;
*) exit 93 ;;
esac
# The gate re-reads several surfaces before its verdict (checks twice, and
# every fingerprint surface once evaluated + once fresh); a second-<fixture>
# file, when present, is what the LATER fetches of that fixture see.
if [ -f "$GH_FIXTURES/second-$file" ]; then
    count_file="$GH_FIXTURES/count-$file"
    count=0
    [ ! -f "$count_file" ] || count="$(cat "$count_file")"
    count=$((count + 1))
    printf '%s\n' "$count" >"$count_file"
    if [ "$count" -ge 2 ]; then
        file="second-$file"
    fi
fi
cat "$GH_FIXTURES/$file"
STUB
chmod +x "${bin_dir}/gh"

# Review round 2, finding `review-r2-codex-verification-3` (confirmed P2): the
# retry-delay case asserted a whole-second `date +%s` difference measured
# around the ENTIRE gate invocation, and the gate costs about a second on its
# own, so the assertion had zero headroom — replacing the sleep with a no-op
# left the suite green. Wall clock cannot pin this; the REQUEST can. This stub
# records what the gate asked to sleep for and returns immediately, so a case
# asserts the configured delay rather than hoping to observe it.
#
# It delegates to the real sleep whenever `SLEEP_CALL_LOG` is unset, so it can
# never silently remove a delay some future case actually depends on — and
# where no real sleep can be found it fails the suite rather than returning
# success, because those are the only two ways to keep that promise.
cat >"${bin_dir}/sleep" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [ -n "${SLEEP_CALL_LOG:-}" ]; then
    printf '%s\n' "$*" >>"$SLEEP_CALL_LOG"
    exit 0
fi
# Review round 3, finding `review-r3-codex-verification-5` (confirmed P3):
# this was `|| exit 0`, which is precisely the silent delay removal the
# comment above promises can never happen — and suite-wide rather than for one
# case. A harness that cannot honour a delay fails loudly.
# `SLEEP_REAL_PATH` exists for the same reason `CODEX_RECHECK_RETRY_DELAY`
# does: so a case can drive this branch. The lookup path was hardcoded, which
# made the refusal below unprovable -- and an unprovable guard is how the
# `|| exit 0` it replaced shipped in the first place.
real_sleep="$(PATH="${SLEEP_REAL_PATH:-/usr/bin:/bin}" command -v sleep)" || {
    printf 'test harness: no real sleep on PATH; refusing to skip a delay\n' >&2
    exit 1
}
exec "$real_sleep" "$@"
STUB
chmod +x "${bin_dir}/sleep"

export PATH="${bin_dir}:$PATH"
export GH_FIXTURES="$fixtures"
export GH_LOG="$log"

head_sha="1111111111111111111111111111111111111111"
# A second, distinct full SHA for the fixtures that need one head to disagree
# with another (harmon-devkit#685's promotion-head binding).
stale_head_sha="2222222222222222222222222222222222222222"
moved_sha="2222222222222222222222222222222222222222"

default_body() {
    cat <<'BODY'
What/why prose.

## Verification

- task verify
BODY
}

# ensure_issue_evidence_markers — harmon-devkit#685 (challenge round 3) makes
# a per-round issue evidence comment a promotion condition, so a record the
# gate is handed must carry one for every adjudication document in it. Rather
# than making ~10 cases remember that, run_gate/run_audit complete the record
# themselves; the cases that are ABOUT the marker being missing set
# skip_evidence_markers=1 for exactly one invocation.
#
# The registration digest is the canonical-JSON sha256 over
# {id, author_actor_id, login, payload_digest, marker, registered_at,
# prev_digest} that validate-result-schemas.mjs's checkRunChainIntegrity
# recomputes — `jq -Sc` is that canonical form. The marker's stage must also
# appear in stage_transitions (checkEvidenceMarkerStageVisited), which is why
# every default record below carries the full lifecycle path rather than a
# lone integration entry.
skip_evidence_markers=0

add_issue_evidence_marker() {
    add_evidence_marker "$1" "$2" issue
}

# $3 = destination (issue|pr). A `pr` marker must be chain-registered exactly
# like an issue one: the gate's authenticity check rejects any marker the
# append-only chain never registered, so an injected one would never reach the
# destination condition it is meant to exercise.
add_evidence_marker() {
    local stage="$1" round="$2" destination="${3:-issue}"
    local marker comment_id payload_digest registered_at prev content digest
    comment_id="21${stage}${destination}$(printf '%04d' "$round")"
    comment_id="$(printf '%s' "$comment_id" | tr -cd '0-9')0"
    payload_digest="sha256:$(printf '%064d' "$round")"
    registered_at="2026-01-01T00:30:00Z"
    marker="$(jq -cn --arg stage "$stage" --argjson round "$round" \
        --arg destination "$destination" \
        '{run_id:"test-run", stage:$stage, destination:$destination,
          round:$round, sequence:1}')"
    prev="$(jq -r '(.evidence_registrations | last | .digest) // "genesis"' "${record_dir}/run.json")"
    content="$(jq -cn --arg id "$comment_id" --arg digest "$payload_digest" \
        --arg at "$registered_at" --argjson marker "$marker" --arg prev "$prev" \
        '{id:$id, author_actor_id:12345678, login:"evanharmon1",
          payload_digest:$digest, marker:$marker, registered_at:$at,
          prev_digest:$prev}')"
    digest="$(printf '%s' "$content" | jq -Sc . | tr -d '\n' | sha256sum | cut -d' ' -f1)"
    jq -c --arg id "$comment_id" --arg digest "$payload_digest" \
        --arg at "$registered_at" --argjson marker "$marker" \
        --arg prev "$prev" --arg entry_digest "$digest" '
      .evidence_comments += [{id:$id, author_actor_id:12345678,
                              login:"evanharmon1", digest:$digest,
                              marker:$marker}]
      | .evidence_registrations += [{seq:(.evidence_registrations | length),
          digest:$entry_digest, prev_digest:$prev, id:$id,
          author_actor_id:12345678, login:"evanharmon1",
          payload_digest:$digest, marker:$marker, registered_at:$at}]' \
        "${record_dir}/run.json" >"${record_dir}/run.json.tmp"
    mv "${record_dir}/run.json.tmp" "${record_dir}/run.json"
}

ensure_issue_evidence_markers() {
    local adj stage round
    [ "$skip_evidence_markers" -eq 0 ] || return 0
    for adj in "${record_dir}"/adjudications/*.json; do
        [ -f "$adj" ] || continue
        stage="$(jq -r '.stage' "$adj" 2>/dev/null)" || continue
        round="$(jq -r '.round' "$adj" 2>/dev/null)" || continue
        [ "$stage" != null ] && [ "$round" != null ] || continue
        jq -e --arg stage "$stage" --argjson round "$round" \
            'any(.evidence_comments[]?.marker;
                 .stage == $stage and .round == $round and .destination == "issue")' \
            "${record_dir}/run.json" >/dev/null 2>&1 && continue
        add_issue_evidence_marker "$stage" "$round"
    done
    node "$validator" run "${record_dir}/run.json" >/dev/null ||
        fail "completing the record's issue evidence markers produced an invalid run record"
}

# The full, legal lifecycle path every default record carries: run.schema.json
# requires the first entry to be kickoff and every consecutive pair to be an
# ALLOWED_EDGES edge, and checkEvidenceMarkerStageVisited requires a marker's
# stage to appear here — so a record that adjudicates a review round must
# record having been in review. $1 = "ended" gives the last entry an exit too,
# required once outcome is non-null.
# $2 = number of integration -> implement -> integration remediation loops to
# record (default 0). A record whose gated pass applies a code-changing
# disposition needs at least one: integration's only outgoing edge is
# implement, so a code change during integration always records the re-entry
# (Codex cloud-review cycle 1 on PR #800).
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

# A minimal valid run.json (ai/schemas/run.schema.json) with no findings at
# all — zero adjudications means readiness-input's finding index has nothing
# disposition:"defer" to report, so deferred_findings.{settled,unsettled} are
# always [] against it. This is the default record for every test that is
# not itself about deferred-finding settlement.
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
    rm -f "${record_dir}"/adjudications/*.json "${record_dir}"/passes/*.json
}

write_record_with_integration_entries() {
    jq -cn --argjson n "$1" '
      # A minute counter keeps entered_at non-decreasing across the whole
      # array (checkRunChronology) while the edges stay on ALLOWED_EDGES'"'"'s
      # own graph: kickoff -> claim -> plan -> implement -> verify ->
      # security -> integration, then $n loops of
      # integration -> implement -> verify -> security -> integration.
      def at($m): "2026-01-01T" + (($m / 60 | floor) | tostring | ("0" * (2 - length)) + .) + ":" + (($m % 60) | tostring | ("0" * (2 - length)) + .) + ":00Z";
      [{stage:"kickoff",exit:"claimed"},
       {stage:"claim",exit:"planned"},
       {stage:"plan",exit:"briefed"},
       {stage:"implement",exit:"verified"},
       {stage:"verify",exit:"green"},
       {stage:"security",exit:"clean"}]
      + ([range(0; $n)] | map(
          [{stage:"integration",exit:"remediating"},
           {stage:"implement",exit:"fixed"},
           {stage:"verify",exit:"green"},
           {stage:"security",exit:"clean"}]) | flatten)
      + [{stage:"integration"}]
      | to_entries | map(.value + {entered_at: at(.key)})
      | . as $transitions
      | {schema:2, run_id:"test-run", initiated_by:"human",
         started_at:"2026-01-01T00:00:00Z",
         stage_transitions:$transitions,
         interventions:[], outcome:null,
         pr:{number:493,url:"https://github.com/example/repo/pull/493"},
         evidence_comments:[], settlements:[], promotion:null,
         evidence_registrations:[], outcome_transitions:[],
         pr_bindings:[{seq:0,prev_digest:"genesis",
           digest:"ec64b9703afdb8ec84d58495e89b4b11dc8c0a96720b330f649e0fe10a498ec1",
           number:493,url:"https://github.com/example/repo/pull/493",
           bound_at:"2026-01-01T00:00:00Z"}]}' >"${record_dir}/run.json"
    node "$validator" run "${record_dir}/run.json" >/dev/null ||
        fail "#685(4) record fixture with $1 remediation loop(s) is not a valid run record"
    rm -f "${record_dir}"/adjudications/*.json "${record_dir}"/passes/*.json
}

# write_review_r1_pass — the reviewer pass that RAISED review-r1-codex-cli-9.
# The known-ids universe is derived from passes, not adjudications (integrate
# cycle 2 on PR #800: an adjudication is a judgement ABOUT a finding, never
# evidence one was produced), so every fixture whose gated pass disposes of
# that finding needs the pass behind it or its record is incomplete.
# $1 = the finding id this pass raises (default review-r1-codex-cli-9); it
# must match whatever the accompanying adjudication document adjudicates, or
# render-dev-flow rejects the pass as carrying an unadjudicated finding.
write_review_r1_pass() {
    jq -cn --arg head "$head_sha" --arg fid "${1:-review-r1-codex-cli-9}" '
      {schema:2, role:"reviewer", status:"completed", head:$head,
       produced_at:"2026-01-01T00:00:00Z",
       producer:{harness:"codex-cli",model:"test",tier:"standard"},
       run:{run_id:"test-run",initiated_by:"human"},
       payload:{stage:"review", round:1, reviewed_head:$head,
                slot:"codex-cli", finder:"codex-cli",
                findings:[{id:$fid,
                           path:"scripts/example.mjs", line:10,
                           class:"correctness", provenance:"original",
                           fingerprint:"new", priority:"P2",
                           recommended_disposition:"defer",
                           evidence:"needs a second look"}],
                counts:{P0:0,P1:0,P2:1,P3:0}}}' \
        >"${record_dir}/passes/review-r1-codex-cli.json"
}

# A schema-valid result.envelope (role integrator) at
# ${fixtures}/integrator-result-<name>.json. $2 is the codex_cycle sub-object
# (or the literal string "null"); $3 overrides the head baked into the
# envelope/codex_cycle/accepted (defaults to $head_sha) so a head-mismatch
# fixture can be built without hand-editing JSON.
write_integrator_result() {
    local name="$1" codex_cycle="$2" head="${3:-$head_sha}"
    local out="${fixtures}/integrator-result-${name}.json"
    # verdict is constrained against codex_cycle.exit_code by
    # validate-result-schemas.mjs's EXIT_CODE_VERDICT_CONSTRAINTS (0->clean,
    # 10->findings, 11|12->pending, 13|2->escalate); the gate's own step 9c
    # additionally requires status:"completed" and verdict:"clean" of the
    # gated pass, after the codex_cycle/findings checks, so a non-clean
    # fixture that gets past those still fails there. A null codex_cycle
    # (cap 0) takes the same "clean" path as exit_code 0.
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
    # 14 excludes BOTH clean and pending (the PR is gone, so there is nothing
    # to wait for and nothing to certify), which is why it needs its own arm
    # rather than the pending default — review round 1 finding
    # `review-r1-codex-verification-4` added the first fixture to reach it.
    13 | 14 | 15 | 2) verdict=escalate ;;
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

# codex_cycle with exit_code 0 requires `accepted` (schema: required exactly
# when exit_code is 0 or 10); everything else omits it.
codex_cycle_json() {
    local exit_code="$1" head="${2:-$head_sha}"
    case "$exit_code" in
    0 | 10)
        jq -cn --arg head "$head" --argjson exit_code "$exit_code" \
            '{head:$head, cycle:1, attempt:1, trigger_comment_id:"1",
              accepted:{surface:"review", id:"1", reviewed_commit:$head},
              exit_code:$exit_code}'
        ;;
    *)
        jq -cn --arg head "$head" --argjson exit_code "$exit_code" \
            '{head:$head, cycle:1, attempt:1, trigger_comment_id:"1",
              exit_code:$exit_code}'
        ;;
    esac
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
    # One completed-success run, one skipped (neutral) run.
    jq -cn '[{total_count:2,check_runs:[
        {name:"build",status:"completed",conclusion:"success"},
        {name:"optional",status:"completed",conclusion:"skipped"}]}]' \
        >"${fixtures}/check-runs.pages.json"
    # A context whose OLDER post is pending and NEWER is success: pins that
    # the gate reads only the latest status per context.
    jq -cn '[[{context:"ci/legacy",state:"pending",id:1},
              {context:"ci/legacy",state:"success",id:3}]]' \
        >"${fixtures}/statuses.pages.json"
    # No GitHub Actions workflow runs for this head by default: check runs
    # with no matching check_suite_id fall back to their app id (harmon-devkit#714).
    printf '%s\n' '[{"total_count":0,"workflow_runs":[]}]' \
        >"${fixtures}/workflow-runs.pages.json"
    # Head level with its base by default. `behind_by` is the TRUTH check the
    # gate uses; mergeStateStatus above is only the cache.
    jq -cn '{behind_by:0,ahead_by:1,status:"ahead",base_commit:{sha:"b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0"}}' >"${fixtures}/compare.json"
    jq -cn '{login:"pr-author"}' >"${fixtures}/user.json"
    jq -cn '{number:380}' >"${fixtures}/issue.json"
    printf '%s\n' '[[]]' >"${fixtures}/inline.pages.json"
    printf '%s\n' '[[]]' >"${fixtures}/reviews.pages.json"
    printf '%s\n' '[[]]' >"${fixtures}/top.pages.json"
    printf '%s\n' \
        '[{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"T1","isResolved":false}]}}}}}]' \
        >"${fixtures}/threads.pages.json"
    rm -f "${fixtures}/fail-endpoint"
    rm -f "${fixtures}/fail-closing-references"
    rm -f "${fixtures}/pr-view-count" "${fixtures}/pr-view-second.json" "${fixtures}/pr-view-third.json"
    rm -f "${fixtures}/second-closing-view.json"
    rm -f "${fixtures}"/issue-*.json
    rm -f "${fixtures}"/count-* "${fixtures}"/second-*
    rm -f "${fixtures}/ro-exit"
    : >"$log"
    write_default_record
    write_integrator_result disabled null >/dev/null
}

# Both --record and --integrator-result are baked in here as the default
# (cap-0-equivalent, clean) case; a test that needs a different record or
# integrator result appends its own "$@" override — the gate's flag parser
# overwrites on repeat, so the last occurrence of either flag wins.
run_gate() {
    ensure_issue_evidence_markers
    set +e
    gate_out="$("$watchdog_bin" -k 5 "$watchdog_sec" "$gate" check \
        --repo example/repo --pr 493 --head "$head_sha" \
        --record "$record_dir" \
        --integrator-result "${fixtures}/integrator-result-disabled.json" \
        --integration-cap 0 --remediation-cap 4 \
        "$@" 2>&1)"
    gate_rc=$?
    set -e
    check_watchdog "$gate_rc" run_gate "$gate_out"
}

run_audit() {
    ensure_issue_evidence_markers
    set +e
    gate_out="$("$watchdog_bin" -k 5 "$watchdog_sec" "$gate" audit \
        --repo example/repo --pr 493 --head "$head_sha" \
        --record "$record_dir" \
        --integrator-result "${fixtures}/integrator-result-disabled.json" \
        --integration-cap 0 --remediation-cap 4 \
        "$@" 2>&1)"
    gate_rc=$?
    set -e
    check_watchdog "$gate_rc" run_audit "$gate_out"
}

# --codex-recheck's target is resolved as readiness-gate.sh's own sibling
# (script_dir/check-codex-cloud-review.sh), so proving a clean recheck
# actually unblocks the gate means giving it a REAL sibling — a copy of the
# gate beside a fake checker stub scripted via $RECHECK_FAKE_EXIT — rather
# than driving the real checker's full GitHub call sequence end to end
# (scripts/test-integrate-codex.sh owns that coverage; this file only proves
# the wiring). The stub is #!/bin/sh with no external calls, so it execs
# correctly even under the restricted-PATH fixture further down.
# The copy must sit in a real skills layout, not a bare directory: since
# harmon-devkit#974 the gate resolves its shared helpers as
# `$script_dir/../../dev-flow-support/assets/...`, so a copy dropped anywhere
# else cannot find them. Reproducing the vendored shape here is the point —
# it is the same two-levels-up hop a consumer's `.claude/skills/` tree has.
recheck_root="${test_tmp}/recheck-gate"
recheck_dir="${recheck_root}/integrate/assets"
mkdir -p "$recheck_dir" "${recheck_root}/dev-flow-support"
ln -s "${repo_root}/ai/skills/universal/dev-flow-support/assets" \
    "${recheck_root}/dev-flow-support/assets"
cp "$gate" "${recheck_dir}/readiness-gate.sh"
chmod +x "${recheck_dir}/readiness-gate.sh"
# Challenge round 3, finding `challenge-r3-codex-adversarial-13` (confirmed
# P2): a constant-exit stub cannot express a SEQUENCE, so the #508 recheck
# retry — read, and on 16 read once more — had no way to be exercised, and
# deleting the retry outright left every case passing. `RECHECK_FAKE_EXITS` is
# a space-separated list consumed one entry per invocation (the last entry
# repeats once exhausted), which is the minimum needed to tell "16 then clean"
# from "16 twice". `RECHECK_FAKE_EXIT` keeps working unchanged for the many
# cases that only need one fixed answer.
cat >"${recheck_dir}/check-codex-cloud-review.sh" <<'STUB'
#!/bin/sh
if [ -n "${RECHECK_FAKE_EXITS:-}" ]; then
    counter="${RECHECK_CALL_COUNTER:-/dev/null}"
    n=0
    [ ! -f "$counter" ] || n=$(cat "$counter")
    n=$((n + 1))
    [ "$counter" = /dev/null ] || printf '%s' "$n" >"$counter"
    i=0
    for code in $RECHECK_FAKE_EXITS; do
        i=$((i + 1))
        [ "$i" -lt "$n" ] || exit "$code"
    done
    exit "$code"
fi
exit "${RECHECK_FAKE_EXIT:-0}"
STUB
chmod +x "${recheck_dir}/check-codex-cloud-review.sh"
recheck_gate="${recheck_dir}/readiness-gate.sh"

# recheck_codex_freshness checks repo/pr/head against the gate's own before
# ever invoking the checker, so these three fields are the only ones that
# matter here — a real check-codex-cloud-review.sh state file carries much
# more (phase, trigger, timestamps), but the fake stub above never reads it.
recheck_state="${fixtures}/codex-recheck-state.json"
jq -cn --arg repo example/repo --argjson pr 493 --arg head "$head_sha" \
    '{repo:$repo, pr:$pr, head:$head}' >"$recheck_state"

# Runs $recheck_gate (the copy with the fake checker sibling) in place of the
# real gate for exactly one run_gate call, with the fake checker scripted to
# exit clean — for the handful of "codex_cycle exit_code 0" tests elsewhere
# in this file that need --codex-recheck to actually confirm freshness
# rather than merely be present.
run_gate_recheck_clean() {
    local saved_gate="$gate"
    gate="$recheck_gate"
    export RECHECK_FAKE_EXIT=0
    run_gate --codex-recheck "$recheck_state" "$@"
    unset RECHECK_FAKE_EXIT
    gate="$saved_gate"
}

# The gate emits its verdict as the final line; earlier lines are incidental
# stderr from the tools it drives.
gate_field() {
    printf '%s\n' "$gate_out" | tail -n 1 | jq -r --arg f "$1" '.[$f]'
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

echo "==> full pass (Codex cycle terminal-clean) prints a fingerprint, stable across two runs on identical data"
write_defaults
clean_result="$(write_integrator_result clean "$(codex_cycle_json 0)")"
run_gate_recheck_clean --integrator-result "$clean_result" --integration-cap 1
assert_gate 0 pass ready
first_fingerprint="$(gate_field fingerprint)"
[ -n "$first_fingerprint" ] && [ "$first_fingerprint" != "null" ] ||
    fail "pass did not print a fingerprint: $gate_out"
rm -f "${fixtures}/pr-view-count"
run_gate_recheck_clean --integrator-result "$clean_result" --integration-cap 1
assert_gate 0 pass ready
second_fingerprint="$(gate_field fingerprint)"
[ "$first_fingerprint" = "$second_fingerprint" ] ||
    fail "fingerprint unstable across identical runs: $first_fingerprint vs $second_fingerprint"

echo "==> the fingerprint subcommand reproduces the pass fingerprint (post-promotion compare)"
set +e
fp_out="$("$watchdog_bin" -k 5 "$watchdog_sec" "$gate" fingerprint \
    --repo example/repo --pr 493 2>&1)"
fp_rc=$?
set -e
check_watchdog "$fp_rc" fingerprint "$fp_out"
[ "$fp_rc" -eq 0 ] || fail "fingerprint subcommand failed: $fp_out"
standalone_fingerprint="$(printf '%s\n' "$fp_out" | tail -n 1 | jq -r '.fingerprint')"
[ "$standalone_fingerprint" = "$first_fingerprint" ] ||
    fail "fingerprint subcommand disagrees with check's: $standalone_fingerprint vs $first_fingerprint"

echo "==> BLOCKED mergeStateStatus and REVIEW_REQUIRED are promotable (never require CLEAN)"
# The defaults above already pin BLOCKED + REVIEW_REQUIRED; this case exists
# so a regression toward must-be-CLEAN names itself.
write_defaults
run_gate
assert_gate 0 pass ready

echo "==> a GraphQL empty body and REST null body are the same no-claim description"
write_defaults
jq '.body = "" | .closingIssuesReferences = []' \
    "${fixtures}/closing-view.json" >"${fixtures}/closing-view.json.tmp"
mv "${fixtures}/closing-view.json.tmp" "${fixtures}/closing-view.json"
jq '.body = null' \
    "${fixtures}/pr.json" >"${fixtures}/pr.json.tmp"
mv "${fixtures}/pr.json.tmp" "${fixtures}/pr.json"
run_gate
assert_gate 0 pass ready

echo "==> a missing REST body stays malformed instead of becoming empty"
write_defaults
jq '.body = "" | .closingIssuesReferences = []' \
    "${fixtures}/closing-view.json" >"${fixtures}/closing-view.json.tmp"
mv "${fixtures}/closing-view.json.tmp" "${fixtures}/closing-view.json"
jq 'del(.body)' \
    "${fixtures}/pr.json" >"${fixtures}/pr.json.tmp"
mv "${fixtures}/pr.json.tmp" "${fixtures}/pr.json"
run_gate
assert_gate 2 indeterminate malformed-data

echo "==> a GraphQL false body stays malformed instead of becoming empty"
write_defaults
jq '.body = false | .closingIssuesReferences = []' \
    "${fixtures}/closing-view.json" >"${fixtures}/closing-view.json.tmp"
mv "${fixtures}/closing-view.json.tmp" "${fixtures}/closing-view.json"
jq '.body = null' \
    "${fixtures}/pr.json" >"${fixtures}/pr.json.tmp"
mv "${fixtures}/pr.json.tmp" "${fixtures}/pr.json"
run_gate
assert_gate 2 indeterminate malformed-data

echo "==> a REST body of any other non-string shape stays malformed"
write_defaults
jq '.body = []' \
    "${fixtures}/pr.json" >"${fixtures}/pr.json.tmp"
mv "${fixtures}/pr.json.tmp" "${fixtures}/pr.json"
run_gate
assert_gate 2 indeterminate malformed-data

echo "==> a claimed same-repo closing keyword without linkage fails closed"
write_defaults
closing_body='Closes #380'
jq --arg body "$closing_body" '.body = $body | .closingIssuesReferences = []' \
    "${fixtures}/closing-view.json" >"${fixtures}/closing-view.json.tmp"
mv "${fixtures}/closing-view.json.tmp" "${fixtures}/closing-view.json"
jq --arg body "$closing_body" '.body = $body' \
    "${fixtures}/pr.json" >"${fixtures}/pr.json.tmp"
mv "${fixtures}/pr.json.tmp" "${fixtures}/pr.json"
run_gate
assert_gate 1 fail closing-linkage-missing

echo "==> a claimed full-URL closing keyword without linkage fails closed"
write_defaults
closing_body='Closes https://github.com/owner/repo/issues/5'
jq --arg body "$closing_body" '.body = $body | .closingIssuesReferences = []' \
    "${fixtures}/closing-view.json" >"${fixtures}/closing-view.json.tmp"
mv "${fixtures}/closing-view.json.tmp" "${fixtures}/closing-view.json"
jq --arg body "$closing_body" '.body = $body' \
    "${fixtures}/pr.json" >"${fixtures}/pr.json.tmp"
mv "${fixtures}/pr.json.tmp" "${fixtures}/pr.json"
run_gate
assert_gate 1 fail closing-linkage-missing

echo "==> a claimed full-URL closing keyword with linkage passes"
write_defaults
closing_body='Fixed https://github.com/owner/repo/issues/5'
closing_refs='[{"number":5,"repository":{"name":"repo","owner":{"login":"owner"}}}]'
jq --arg body "$closing_body" --argjson refs "$closing_refs" \
    '.body = $body | .closingIssuesReferences = $refs' \
    "${fixtures}/closing-view.json" >"${fixtures}/closing-view.json.tmp"
mv "${fixtures}/closing-view.json.tmp" "${fixtures}/closing-view.json"
jq --arg body "$closing_body" '.body = $body' \
    "${fixtures}/pr.json" >"${fixtures}/pr.json.tmp"
mv "${fixtures}/pr.json.tmp" "${fixtures}/pr.json"
run_gate
assert_gate 0 pass ready

echo "==> a non-closing Refs-only body does not require linkage"
write_defaults
refs_body='Refs #380'
jq --arg body "$refs_body" '.body = $body | .closingIssuesReferences = []' \
    "${fixtures}/closing-view.json" >"${fixtures}/closing-view.json.tmp"
mv "${fixtures}/closing-view.json.tmp" "${fixtures}/closing-view.json"
jq --arg body "$refs_body" '.body = $body' \
    "${fixtures}/pr.json" >"${fixtures}/pr.json.tmp"
mv "${fixtures}/pr.json.tmp" "${fixtures}/pr.json"
run_gate
assert_gate 0 pass ready

echo "==> a closing keyword on one line does not claim a reference on the next"
write_defaults
cross_line_body="$(printf 'Closes\n#380\n')"
jq --arg body "$cross_line_body" '.body = $body | .closingIssuesReferences = []' \
    "${fixtures}/closing-view.json" >"${fixtures}/closing-view.json.tmp"
mv "${fixtures}/closing-view.json.tmp" "${fixtures}/closing-view.json"
jq --arg body "$cross_line_body" '.body = $body' \
    "${fixtures}/pr.json" >"${fixtures}/pr.json.tmp"
mv "${fixtures}/pr.json.tmp" "${fixtures}/pr.json"
run_gate
assert_gate 0 pass ready

echo "==> a closing keyword targeting a pull request needs no issue linkage"
write_defaults
closing_body='Closes #493'
jq --arg body "$closing_body" '.body = $body | .closingIssuesReferences = []' \
    "${fixtures}/closing-view.json" >"${fixtures}/closing-view.json.tmp"
mv "${fixtures}/closing-view.json.tmp" "${fixtures}/closing-view.json"
jq --arg body "$closing_body" '.body = $body' \
    "${fixtures}/pr.json" >"${fixtures}/pr.json.tmp"
mv "${fixtures}/pr.json.tmp" "${fixtures}/pr.json"
jq -cn '{number:493,pull_request:{url:"https://api.github.test/repos/example/repo/pulls/493"}}' \
    >"${fixtures}/issue-493.json"
run_gate
assert_gate 0 pass ready
resolve_count="$(awk '$0 ~ /^api repos\/example\/repo\/issues\/493([[:space:]]|$)/ { count++ } END { print count + 0 }' "$log")"
[ "$resolve_count" -eq 1 ] ||
    fail "expected the same-repo PR target to resolve once, saw $resolve_count reads"

echo "==> a null pull_request marker is malformed, not a PR-target exemption"
write_defaults
closing_body='Closes #493'
jq --arg body "$closing_body" '.body = $body | .closingIssuesReferences = []' \
    "${fixtures}/closing-view.json" >"${fixtures}/closing-view.json.tmp"
mv "${fixtures}/closing-view.json.tmp" "${fixtures}/closing-view.json"
jq --arg body "$closing_body" '.body = $body' \
    "${fixtures}/pr.json" >"${fixtures}/pr.json.tmp"
mv "${fixtures}/pr.json.tmp" "${fixtures}/pr.json"
jq -cn '{number:493,pull_request:null}' >"${fixtures}/issue-493.json"
run_gate
assert_gate 2 indeterminate malformed-data

echo "==> a non-object pull_request marker is malformed, not a PR-target exemption"
write_defaults
closing_body='Closes #493'
jq --arg body "$closing_body" '.body = $body | .closingIssuesReferences = []' \
    "${fixtures}/closing-view.json" >"${fixtures}/closing-view.json.tmp"
mv "${fixtures}/closing-view.json.tmp" "${fixtures}/closing-view.json"
jq --arg body "$closing_body" '.body = $body' \
    "${fixtures}/pr.json" >"${fixtures}/pr.json.tmp"
mv "${fixtures}/pr.json.tmp" "${fixtures}/pr.json"
jq -cn '{number:493,pull_request:"not-an-object"}' >"${fixtures}/issue-493.json"
run_gate
assert_gate 2 indeterminate malformed-data

echo "==> a failed claimed-target resolve is indeterminate"
write_defaults
closing_body='Closes #380'
jq --arg body "$closing_body" '.body = $body | .closingIssuesReferences = []' \
    "${fixtures}/closing-view.json" >"${fixtures}/closing-view.json.tmp"
mv "${fixtures}/closing-view.json.tmp" "${fixtures}/closing-view.json"
jq --arg body "$closing_body" '.body = $body' \
    "${fixtures}/pr.json" >"${fixtures}/pr.json.tmp"
mv "${fixtures}/pr.json.tmp" "${fixtures}/pr.json"
printf '%s\n' 'repos/example/repo/issues/380' >"${fixtures}/fail-endpoint"
run_gate
assert_gate 2 indeterminate fetch-failed

echo "==> a claimed same-repo closing keyword with linkage passes"
write_defaults
closing_body='Fixed #380'
closing_refs='[{"number":380,"repository":{"name":"repo","owner":{"login":"example"}}}]'
jq --arg body "$closing_body" --argjson refs "$closing_refs" \
    '.body = $body | .closingIssuesReferences = $refs' \
    "${fixtures}/closing-view.json" >"${fixtures}/closing-view.json.tmp"
mv "${fixtures}/closing-view.json.tmp" "${fixtures}/closing-view.json"
jq --arg body "$closing_body" '.body = $body' \
    "${fixtures}/pr.json" >"${fixtures}/pr.json.tmp"
mv "${fixtures}/pr.json.tmp" "${fixtures}/pr.json"
run_gate
assert_gate 0 pass ready

echo "==> a linked leading-zero issue number is normalized numerically"
write_defaults
closing_body='Closes #0380'
closing_refs='[{"number":380,"repository":{"name":"repo","owner":{"login":"example"}}}]'
jq --arg body "$closing_body" --argjson refs "$closing_refs" \
    '.body = $body | .closingIssuesReferences = $refs' \
    "${fixtures}/closing-view.json" >"${fixtures}/closing-view.json.tmp"
mv "${fixtures}/closing-view.json.tmp" "${fixtures}/closing-view.json"
jq --arg body "$closing_body" '.body = $body' \
    "${fixtures}/pr.json" >"${fixtures}/pr.json.tmp"
mv "${fixtures}/pr.json.tmp" "${fixtures}/pr.json"
run_gate
assert_gate 0 pass ready

echo "==> linkage disappearing before the final snapshot fails closed"
write_defaults
closing_body='Fixes #380'
closing_refs='[{"number":380,"repository":{"name":"repo","owner":{"login":"example"}}}]'
jq --arg body "$closing_body" --argjson refs "$closing_refs" \
    '.body = $body | .closingIssuesReferences = $refs' \
    "${fixtures}/closing-view.json" >"${fixtures}/closing-view.json.tmp"
mv "${fixtures}/closing-view.json.tmp" "${fixtures}/closing-view.json"
jq --arg body "$closing_body" '.body = $body' \
    "${fixtures}/pr.json" >"${fixtures}/pr.json.tmp"
mv "${fixtures}/pr.json.tmp" "${fixtures}/pr.json"
jq --arg body "$closing_body" '.body = $body | .closingIssuesReferences = []' \
    "${fixtures}/closing-view.json" >"${fixtures}/second-closing-view.json"
run_gate
assert_gate 1 fail closing-linkage-missing

echo "==> a claimed cross-repo closing keyword with linkage passes"
write_defaults
closing_body='Resolved owner/repo#5'
closing_refs='[{"number":5,"repository":{"name":"repo","owner":{"login":"owner"}}}]'
jq --arg body "$closing_body" --argjson refs "$closing_refs" \
    '.body = $body | .closingIssuesReferences = $refs' \
    "${fixtures}/closing-view.json" >"${fixtures}/closing-view.json.tmp"
mv "${fixtures}/closing-view.json.tmp" "${fixtures}/closing-view.json"
jq --arg body "$closing_body" '.body = $body' \
    "${fixtures}/pr.json" >"${fixtures}/pr.json.tmp"
mv "${fixtures}/pr.json.tmp" "${fixtures}/pr.json"
run_gate
assert_gate 0 pass ready

echo "==> a closing-linkage fetch failure is indeterminate"
write_defaults
closing_body='Closes #380'
jq --arg body "$closing_body" '.body = $body' \
    "${fixtures}/pr.json" >"${fixtures}/pr.json.tmp"
mv "${fixtures}/pr.json.tmp" "${fixtures}/pr.json"
: >"${fixtures}/fail-closing-references"
run_gate
assert_gate 2 indeterminate fetch-failed

# ---- SKILL.md base-reconciliation contract (harmon-devkit#873, #836) -------
# Prose, not behaviour — but the prose is the whole fix for #873, and a
# directional distinction that quietly disappears from a document fails
# silently and forever. An implementer who reads "never merge to main" and
# concludes it forbids merging main INTO the branch waits for a reconciliation
# that will never come (observed on evanharmon1/harmon-init#1203).
echo "==> SKILL.md keeps the base-reconciliation contract"
skill_md="${repo_root}/ai/skills/universal/integrate/SKILL.md"
[ -f "$skill_md" ] || fail "integrate SKILL.md not found at $skill_md"
# Match against a WHITESPACE-NORMALIZED copy: the assertions are about prose
# that markdown wraps, and one keyed to today's line breaks would fail the next
# time someone re-wraps a paragraph — which invites "fixing" it by loosening
# the pattern until it no longer asserts anything.
skill_flat="$(tr '\n' ' ' <"$skill_md" | tr -s ' ')"
assert_skill() {
    case "$skill_flat" in
    *"$2"*) ;;
    *) fail "SKILL.md lost: $1" ;;
    esac
}
assert_skill "the permitted base-into-feature direction" \
    "base branch **into** the feature branch is permitted"
assert_skill "the prohibited feature-into-base direction" \
    "feature branch **into** the base is the operation that needs per-merge human approval"
assert_skill "the no-rebase rule for pushed history" \
    "never rebased or force-pushed"
assert_skill "behind-ness deferred to the gate, not acted on mid-stage" \
    "not a mid-stage blocker"
assert_skill "the base bound to the PR's own baseRefName in the target repo" \
    "own \`baseRefName\` in the **target** repository"
assert_skill "reconciliation being an ordinary remediation round" \
    "ordinary remediation round"
assert_skill "the exhausted-remediation blocked stop" \
    "no remediation budget left, reconciliation is the **blocked stop**"
assert_skill "the last cycle reserved for the reconciled head" \
    "last permitted cycle is therefore reserved for the reconciled head"
assert_skill "the executable preflight for the reserved cycle" \
    "readiness-gate.sh behind --repo <repo> --pr <n>"
assert_skill "promotion staying a one-way door when the base moves after it" \
    "Undoing a promotion because the base moved afterwards is **not** the remedy"
assert_skill "indeterminate never licensing an undo" \
    "every \`audit\` exit 2, whatever its condition"
assert_skill "the stay-draft rule scoped to this session's own promotion" \
    "governs **this session's own promotion decision**"
assert_skill "an unestablished promotion being escalated, not accepted" \
    "escalated loudly, not silently accepted"
assert_skill "post-promotion drift being reported, not undone" \
    "State that changed *after* a correct promotion"
assert_skill "behind-base counted as drift, not an undo trigger" \
    "\`audit-behind\`, \`behind-base\`, \`base-retargeted\`, \`head-moved\`"
assert_skill "the undo branch being limited to established injustice" \
    "the gate positively established that the promotion sits on"
assert_skill "the rule being about kinds, not a list of conditions" \
    "a rule about kinds rather than a list of conditions"
assert_skill "the last remediation push reserved like the last cycle" \
    "last remediation push is reserved the same way the last cycle is"
assert_skill "the cap-0 integration carve-out" \
    "integration cap is 0 no cloud cycle is owed"
assert_skill "the overriding never-ready-when-behind invariant" \
    "gate can establish is behind is never reported ready"
assert_skill "the Base reconciliation section heading" \
    "### Base reconciliation"

echo "==> a head behind its base fails behind-base even when the cache says CLEAN"
# The omator#758 shape (harmon-devkit#836): GitHub returned CLEAN/MERGEABLE for
# a head 16 commits behind main. mergeStateStatus is a lazily recomputed cache;
# behind_by is the commit graph. If this ever passes, the gate is reporting
# ready for a PR the maintainer will have to "Update branch" — which moves the
# head and invalidates the Codex result the gate just relied on.
write_defaults
jq -cn --arg head "$head_sha" \
    '{state:"OPEN",isDraft:true,headRefOid:$head,
      reviewDecision:"REVIEW_REQUIRED",mergeStateStatus:"CLEAN",
      headRefName:"feature-branch",baseRefName:"main",baseRefOid:"b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0"}' \
    >"${fixtures}/pr-view.json"
jq -cn '{behind_by:16,ahead_by:3,status:"diverged",base_commit:{sha:"b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0"}}' >"${fixtures}/compare.json"
run_gate
assert_gate 1 fail behind-base

echo "==> a head level with its base passes with the same CLEAN cache"
# The negative control for the case above: same mergeStateStatus, behind_by 0.
write_defaults
jq -cn --arg head "$head_sha" \
    '{state:"OPEN",isDraft:true,headRefOid:$head,
      reviewDecision:"REVIEW_REQUIRED",mergeStateStatus:"CLEAN",
      headRefName:"feature-branch",baseRefName:"main",baseRefOid:"b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0"}' \
    >"${fixtures}/pr-view.json"
jq -cn '{behind_by:0,ahead_by:3,status:"ahead",base_commit:{sha:"b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0"}}' >"${fixtures}/compare.json"
run_gate
assert_gate 0 pass ready

echo "==> a base that advances DURING the gate fails on the final re-read"
# The race the single up-front comparison cannot see: level when checked, behind
# by the verdict. Gate evaluation is long, and the pre-verdict re-read used to
# consult only mergeStateStatus — the cache this condition exists to distrust —
# so a lagging cache let the gate pass for a head that had fallen behind.
write_defaults
jq -cn '{behind_by:2,ahead_by:3,status:"diverged",base_commit:{sha:"b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0"}}' >"${fixtures}/second-compare.json"
run_gate
assert_gate 1 fail behind-base

echo "==> a retarget DURING the gate stops the run rather than re-measuring"
# Every condition already evaluated used the OLD base, so re-deriving against
# the new one mid-verdict would mix two baselines in one verdict.
write_defaults
jq -cn --arg head "$head_sha" \
    '{state:"OPEN",isDraft:true,headRefOid:$head,
      reviewDecision:"REVIEW_REQUIRED",mergeStateStatus:"BLOCKED",
      baseRefName:"release/2.0",baseRefOid:"b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0"}' \
    >"${fixtures}/pr-view-second.json"
run_gate
assert_gate 1 fail base-retargeted
grep -Fq 'release/2.0' <<<"$gate_out" ||
    fail "retarget case did not name the new base ref: $gate_out"

echo "==> audit does NOT fail a behind head (post-promotion drift is not an undo)"
# Had audit failed here, SKILL.md's unexplained-promotion "Otherwise" branch
# would route a perfectly valid human handoff into `gh pr ready --undo`,
# reversing it because the base moved afterwards. Ordinary drift, not a defect.
write_defaults
jq -cn --arg head "$head_sha" \
    '{state:"OPEN",isDraft:false,headRefOid:$head,
      reviewDecision:"REVIEW_REQUIRED",mergeStateStatus:"BLOCKED",
      headRefName:"feature-branch",baseRefName:"main",baseRefOid:"b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0"}' \
    >"${fixtures}/pr-view.json"
jq -cn '{behind_by:9,ahead_by:1,status:"diverged",base_commit:{sha:"b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0"}}' >"${fixtures}/compare.json"
run_gate_audit() {
    set +e
    gate_out="$("$watchdog_bin" -k 5 "$watchdog_sec" "$gate" audit \
        --repo example/repo --pr 493 --head "$head_sha" \
        --record "$record_dir" \
        --integrator-result "${fixtures}/integrator-result-disabled.json" \
        --integration-cap 0 --remediation-cap 4 "$@" 2>&1)"
    gate_rc=$?
    set -e
}
run_gate_audit
[ "$gate_rc" -eq 0 ] ||
    fail "audit failed on a behind head (rc $gate_rc) — this routes a valid promotion to an undo: $gate_out"
# ...and it must not pass SILENTLY either: a bare `audit` verdict would let §2
# complete the ready stop for a PR that is in fact behind (review round 2).
# The third answer: pass, so no undo, but say so, so the caller reports it.
grep -Fq '"condition":"audit-behind"' <<<"$gate_out" ||
    fail "audit passed a behind head without flagging the drift: $gate_out"
grep -Fq '9 commit(s) behind' <<<"$gate_out" ||
    fail "audit-behind did not report the distance: $gate_out"

# ...and the TRUE lag shape: cache says BEHIND while the graph says 0. Only
# then is `merge-state-stale` an honest claim, and it is indeterminate in both
# modes — safe because SKILL.md §2 never undoes on an exit 2. (Where the graph
# also says behind, the two signals agree, re-polling can never resolve it,
# and audit must reach `audit-behind` instead — covered separately.)
jq -cn --arg head "$head_sha" \
    '{state:"OPEN",isDraft:false,headRefOid:$head,
      reviewDecision:"REVIEW_REQUIRED",mergeStateStatus:"BEHIND",
      headRefName:"feature-branch",baseRefName:"main",baseRefOid:"b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0"}' \
    >"${fixtures}/pr-view.json"
jq -cn '{behind_by:0,ahead_by:1,status:"ahead",base_commit:{sha:"b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0"}}' \
    >"${fixtures}/compare.json"
run_gate_audit
[ "$gate_rc" -eq 2 ] ||
    fail "a true cache lag in audit should be indeterminate (rc $gate_rc): $gate_out"
grep -Fq 'merge-state-stale' <<<"$gate_out" ||
    fail "cached-BEHIND audit did not name the cache lag: $gate_out"

echo "==> a head that moves DURING the final compare fails as head-moved"
# The compare is a network call after the pre-verdict scalar read, so without
# re-binding afterwards the verdict would rest on an identity nothing checked.
# Only the THIRD read moves. Seeding the counter instead made the FIRST read
# return the moved SHA, so the gate exited early on `head-mismatch` and the
# case passed with the new guard deleted — a vacuous assertion (review r3).
write_defaults
jq -cn --arg head "$moved_sha" \
    '{state:"OPEN",isDraft:true,headRefOid:$head,
      reviewDecision:"REVIEW_REQUIRED",mergeStateStatus:"BLOCKED",
      headRefName:"feature-branch",baseRefName:"main",baseRefOid:"b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0"}' \
    >"${fixtures}/pr-view-third.json"
run_gate
assert_gate 1 fail head-moved

echo "==> a promotion DURING the final compare fails, not just a head move"
# The post-compare read reapplies every scalar gate, not only identity:
# checking head/base alone would let a close, a promotion, a CHANGES_REQUESTED
# review or a DIRTY merge state land during the comparison and still say ready.
write_defaults
jq -cn --arg head "$head_sha" \
    '{state:"OPEN",isDraft:false,headRefOid:$head,
      reviewDecision:"REVIEW_REQUIRED",mergeStateStatus:"BLOCKED",
      headRefName:"feature-branch",baseRefName:"main",baseRefOid:"b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0"}' \
    >"${fixtures}/pr-view-third.json"
run_gate
assert_gate 1 fail pr-not-draft

echo "==> a CHANGES_REQUESTED review DURING the final compare fails"
write_defaults
jq -cn --arg head "$head_sha" \
    '{state:"OPEN",isDraft:true,headRefOid:$head,
      reviewDecision:"CHANGES_REQUESTED",mergeStateStatus:"BLOCKED",
      headRefName:"feature-branch",baseRefName:"main",baseRefOid:"b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0"}' \
    >"${fixtures}/pr-view-third.json"
run_gate
assert_gate 1 fail changes-requested

echo "==> audit re-establishes drift that appears DURING the run"
# Level at the start, behind by the verdict: audit must still say audit-behind
# rather than emitting a plain clean verdict the caller reports as ready.
write_defaults
jq -cn --arg head "$head_sha" \
    '{state:"OPEN",isDraft:false,headRefOid:$head,
      reviewDecision:"REVIEW_REQUIRED",mergeStateStatus:"BLOCKED",
      headRefName:"feature-branch",baseRefName:"main",baseRefOid:"b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0"}' \
    >"${fixtures}/pr-view.json"
jq -cn '{behind_by:0,ahead_by:1,status:"ahead",base_commit:{sha:"b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0"}}' >"${fixtures}/compare.json"
jq -cn '{behind_by:5,ahead_by:1,status:"diverged",base_commit:{sha:"b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0"}}' >"${fixtures}/second-compare.json"
run_gate_audit
[ "$gate_rc" -eq 0 ] ||
    fail "audit failed on mid-run drift (rc $gate_rc): $gate_out"
grep -Fq '"condition":"audit-behind"' <<<"$gate_out" ||
    fail "audit missed drift that appeared during the run: $gate_out"

echo "==> UNKNOWN arriving DURING the final compare is indeterminate, not ready"
# Writing only the DIRTY arm on the final read let the other two prohibited
# merge states fall straight through to `ready` (review round 4).
write_defaults
jq -cn --arg head "$head_sha" \
    '{state:"OPEN",isDraft:true,headRefOid:$head,
      reviewDecision:"REVIEW_REQUIRED",mergeStateStatus:"UNKNOWN",
      headRefName:"feature-branch",baseRefName:"main",baseRefOid:"b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0"}' \
    >"${fixtures}/pr-view-third.json"
run_gate
assert_gate 2 indeterminate merge-state-unknown

echo "==> a cache turning BEHIND DURING the final compare is indeterminate"
write_defaults
jq -cn --arg head "$head_sha" \
    '{state:"OPEN",isDraft:true,headRefOid:$head,
      reviewDecision:"REVIEW_REQUIRED",mergeStateStatus:"BEHIND",
      headRefName:"feature-branch",baseRefName:"main",baseRefOid:"b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0"}' \
    >"${fixtures}/pr-view-third.json"
run_gate
assert_gate 2 indeterminate merge-state-stale

echo "==> audit drift that RESOLVES before the verdict is not reported"
# behind at the first comparison, level at the recheck: only ever SETTING
# audit_behind left the stale count standing and reported drift that was gone.
write_defaults
jq -cn --arg head "$head_sha" \
    '{state:"OPEN",isDraft:false,headRefOid:$head,
      reviewDecision:"REVIEW_REQUIRED",mergeStateStatus:"BLOCKED",
      headRefName:"feature-branch",baseRefName:"main",baseRefOid:"b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0"}' \
    >"${fixtures}/pr-view.json"
jq -cn '{behind_by:6,ahead_by:1,status:"diverged",base_commit:{sha:"b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0"}}' >"${fixtures}/compare.json"
jq -cn '{behind_by:0,ahead_by:1,status:"ahead",base_commit:{sha:"b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0"}}' >"${fixtures}/second-compare.json"
run_gate_audit
[ "$gate_rc" -eq 0 ] || fail "audit failed after drift resolved (rc $gate_rc): $gate_out"
grep -Fq '"condition":"audit"' <<<"$gate_out" ||
    fail "audit reported stale drift after a level recheck: $gate_out"

echo "==> a retarget during AUDIT stops it too, and names the new base"
# Evidence gathered against the old base says nothing about a new one.
# Safe to fail now: §2 classifies base-retargeted as drift, reported not undone.
write_defaults
jq -cn --arg head "$head_sha" \
    '{state:"OPEN",isDraft:false,headRefOid:$head,
      reviewDecision:"REVIEW_REQUIRED",mergeStateStatus:"BLOCKED",
      headRefName:"feature-branch",baseRefName:"main",baseRefOid:"b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0"}' \
    >"${fixtures}/pr-view.json"
jq -cn --arg head "$head_sha" \
    '{state:"OPEN",isDraft:false,headRefOid:$head,
      reviewDecision:"REVIEW_REQUIRED",mergeStateStatus:"BLOCKED",
      headRefName:"feature-branch",baseRefName:"release/2.0",baseRefOid:"b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0"}' \
    >"${fixtures}/pr-view-second.json"
run_gate_audit
[ "$gate_rc" -eq 1 ] || fail "audit accepted a retarget (rc $gate_rc): $gate_out"
grep -Fq 'base-retargeted' <<<"$gate_out" || fail "audit retarget not named: $gate_out"

echo "==> the base branch ADVANCING after the compare invalidates the count"
# Name and head unchanged, tip moved: comparing names alone reported `level`
# off a stale count (review round 5).
write_defaults
jq -cn --arg head "$head_sha" \
    '{state:"OPEN",isDraft:true,headRefOid:$head,
      reviewDecision:"REVIEW_REQUIRED",mergeStateStatus:"BLOCKED",
      headRefName:"feature-branch",baseRefName:"main",baseRefOid:"cafecafecafecafecafecafecafecafecafecafe"}' \
    >"${fixtures}/pr-view-third.json"
run_gate
assert_gate 1 fail behind-base

echo "==> the base-tip race is reachable in AUDIT too, and is classed as drift"
# check mode already covers this; audit reaches the same `behind-base` via the
# final identity read, and §2 must class it as drift or the undo branch claims
# a valid human handoff (Codex, current head).
write_defaults
jq -cn --arg head "$head_sha" \
    '{state:"OPEN",isDraft:false,headRefOid:$head,
      reviewDecision:"REVIEW_REQUIRED",mergeStateStatus:"BLOCKED",
      headRefName:"feature-branch",baseRefName:"main",baseRefOid:"b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0"}' \
    >"${fixtures}/pr-view.json"
jq -cn --arg head "$head_sha" \
    '{state:"OPEN",isDraft:false,headRefOid:$head,
      reviewDecision:"REVIEW_REQUIRED",mergeStateStatus:"BLOCKED",
      headRefName:"feature-branch",baseRefName:"main",baseRefOid:"cafecafecafecafecafecafecafecafecafecafe"}' \
    >"${fixtures}/pr-view-third.json"
run_gate_audit
[ "$gate_rc" -eq 1 ] || fail "audit base-tip race exited $gate_rc: $gate_out"
grep -Fq 'behind-base' <<<"$gate_out" ||
    fail "audit base-tip race did not emit behind-base: $gate_out"

echo "==> a genuinely behind audit reaches audit-behind, not a permanent stale"
# Both signals agree here, so `merge-state-stale` would be a false lag claim
# AND a permanent indeterminate — re-polling cannot resolve real drift, and it
# would block the drift verdict audit mode exists to produce (Codex, cycle 2).
write_defaults
jq -cn --arg head "$head_sha" \
    '{state:"OPEN",isDraft:false,headRefOid:$head,
      reviewDecision:"REVIEW_REQUIRED",mergeStateStatus:"BEHIND",
      headRefName:"feature-branch",baseRefName:"main",baseRefOid:"b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0"}' \
    >"${fixtures}/pr-view.json"
jq -cn '{behind_by:7,ahead_by:1,status:"diverged",base_commit:{sha:"b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0"}}' \
    >"${fixtures}/compare.json"
run_gate_audit
[ "$gate_rc" -eq 0 ] || fail "genuinely-behind audit exited $gate_rc: $gate_out"
grep -Fq '"condition":"audit-behind"' <<<"$gate_out" ||
    fail "genuinely-behind audit did not reach the drift verdict: $gate_out"

echo "==> no network read follows the final checks evaluation"
# The gate promises its final scalar read is the last network call. A compare
# placed after the content fingerprint and second evaluate_checks broke that:
# a check turning red during it went unseen (Codex, cycle 2).
gate_src="${repo_root}/ai/skills/universal/integrate/assets/readiness-gate.sh"
last_checks="$(grep -n '^evaluate_checks$' "$gate_src" | tail -1 | cut -d: -f1)"
last_compare="$(grep -n 'establish_behind "\$recheck"' "$gate_src" | tail -1 | cut -d: -f1)"
[ -n "$last_checks" ] && [ -n "$last_compare" ] ||
    fail "could not locate the final checks evaluation or the base comparison"
[ "$last_compare" -lt "$last_checks" ] ||
    fail "the base comparison (line $last_compare) runs AFTER the final evaluate_checks (line $last_checks) — a network call behind the last snapshots"

echo "==> the behind preflight refuses a head that moved while comparing"
# The preflight makes exactly two PR reads: the first captures the identity,
# the second re-binds it after comparing. Only the second moves here.
write_defaults
jq -cn --arg head "$moved_sha" \
    '{state:"OPEN",isDraft:true,headRefOid:$head,
      reviewDecision:"REVIEW_REQUIRED",mergeStateStatus:"BLOCKED",
      headRefName:"feature-branch",baseRefName:"main",baseRefOid:"b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0"}' \
    >"${fixtures}/pr-view-second.json"
set +e
preflight_out="$("$watchdog_bin" -k 5 "$watchdog_sec" "$gate" behind \
    --repo example/repo --pr 493 2>&1)"
preflight_rc=$?
set -e
[ "$preflight_rc" -eq 2 ] ||
    fail "behind preflight certified a moved head (rc $preflight_rc): $preflight_out"
grep -Fq 'behind-base-unknown' <<<"$preflight_out" ||
    fail "behind preflight did not name the identity drift: $preflight_out"

echo "==> the gate emits no stray output before its own argument parsing"
# A header-comment edit once dropped its leading `#`, leaving an executable
# line at top level. `set -euo pipefail` is BELOW the header, so it failed with
# 127, execution continued, and every test still passed while stderr carried
# "command not found" on every single run. Assert the shape, not that one line.
stray_out="$("$gate" 2>&1 || true)"
case "$stray_out" in
*"command not found"* | *"No such file or directory"*)
    fail "the gate emits stray shell output before parsing arguments: $stray_out"
    ;;
esac
grep -q '^Usage:' <<<"$stray_out" ||
    fail "a bare invocation did not print usage first: $stray_out"

echo "==> the behind preflight reports level, behind, and indeterminate"
# The reserved-cycle rule sends integrators here instead of re-deriving the
# comparison, so it must carry the same fail-closed behaviour as the gate.
write_defaults
jq -cn '{behind_by:0,ahead_by:2,status:"ahead",base_commit:{sha:"b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0"}}' >"${fixtures}/compare.json"
set +e
preflight_out="$("$watchdog_bin" -k 5 "$watchdog_sec" "$gate" behind \
    --repo example/repo --pr 493 2>&1)"
preflight_rc=$?
set -e
[ "$preflight_rc" -eq 0 ] || fail "behind preflight on a level head exited $preflight_rc: $preflight_out"
grep -Fq '"status":"level"' <<<"$preflight_out" ||
    fail "behind preflight did not report level: $preflight_out"

jq -cn '{behind_by:4,ahead_by:2,status:"diverged",base_commit:{sha:"b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0"}}' >"${fixtures}/compare.json"
set +e
preflight_out="$("$watchdog_bin" -k 5 "$watchdog_sec" "$gate" behind \
    --repo example/repo --pr 493 2>&1)"
preflight_rc=$?
set -e
[ "$preflight_rc" -eq 1 ] || fail "behind preflight on a behind head exited $preflight_rc: $preflight_out"
grep -Fq 'behind-base' <<<"$preflight_out" ||
    fail "behind preflight did not name behind-base: $preflight_out"

# Indeterminate must NOT read as level: spending the reserved cycle on an
# unverified head is the failure this preflight exists to prevent.
write_defaults
printf '%s\n' 'compare' >"${fixtures}/fail-endpoint"
set +e
preflight_out="$("$watchdog_bin" -k 5 "$watchdog_sec" "$gate" behind \
    --repo example/repo --pr 493 2>&1)"
preflight_rc=$?
set -e
[ "$preflight_rc" -eq 2 ] || fail "behind preflight on an unreadable compare exited $preflight_rc: $preflight_out"
grep -Fq 'behind-base-unknown' <<<"$preflight_out" ||
    fail "behind preflight did not report behind-base-unknown: $preflight_out"
write_defaults

echo "==> a URL-significant base ref is encoded, and a slash is left literal"
# `release#1` interpolated raw would truncate the endpoint at the fragment and
# silently compare against `release` — the wrong branch, answered confidently.
# `/` must survive, because GitHub expects it literally inside a ref.
write_defaults
jq -cn --arg head "$head_sha" \
    '{state:"OPEN",isDraft:true,headRefOid:$head,
      reviewDecision:"REVIEW_REQUIRED",mergeStateStatus:"BLOCKED",
      headRefName:"feature-branch",baseRefName:"release#1/rc",baseRefOid:"b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0"}' \
    >"${fixtures}/pr-view.json"
jq -cn '{behind_by:0,ahead_by:1,status:"ahead",base_commit:{sha:"b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0"}}' >"${fixtures}/compare.json"
run_gate
assert_gate 0 pass ready
grep -Fq 'compare/release%231/rc...' "$log" ||
    fail "compare endpoint did not encode the base ref: $(grep -F compare/ "$log" | head -1)"

echo "==> a cache-only BEHIND (graph says 0) is indeterminate, not a merge to do"
# Merging a base the head is already level with creates no commit, so there is
# nothing to push or re-review and the blocker would reproduce forever.
write_defaults
jq -cn --arg head "$head_sha" \
    '{state:"OPEN",isDraft:true,headRefOid:$head,
      reviewDecision:"REVIEW_REQUIRED",mergeStateStatus:"BEHIND",
      headRefName:"feature-branch",baseRefName:"main",baseRefOid:"b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0"}' \
    >"${fixtures}/pr-view.json"
run_gate
assert_gate 2 indeterminate merge-state-stale

echo "==> an unreadable compare is indeterminate, never a pass"
write_defaults
printf '%s\n' 'compare' >"${fixtures}/fail-endpoint"
run_gate
assert_gate 2 indeterminate behind-base-unknown

echo "==> a compare payload without a numeric behind_by is indeterminate"
write_defaults
jq -cn '{status:"ahead"}' >"${fixtures}/compare.json"
run_gate
assert_gate 2 indeterminate behind-base-unknown

echo "==> a closed PR fails as pr-not-open"
write_defaults
jq -cn --arg head "$head_sha" \
    '{state:"MERGED",isDraft:false,headRefOid:$head,
      reviewDecision:"",mergeStateStatus:"UNKNOWN",
      headRefName:"feature-branch",baseRefName:"main",baseRefOid:"b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0"}' >"${fixtures}/pr-view.json"
run_gate
assert_gate 1 fail pr-not-open

echo "==> a non-draft PR fails as pr-not-draft"
write_defaults
jq -cn --arg head "$head_sha" \
    '{state:"OPEN",isDraft:false,headRefOid:$head,
      reviewDecision:"REVIEW_REQUIRED",mergeStateStatus:"BLOCKED",
      headRefName:"feature-branch",baseRefName:"main",baseRefOid:"b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0"}' \
    >"${fixtures}/pr-view.json"
run_gate
assert_gate 1 fail pr-not-draft

echo "==> a head other than the adjudicated one fails as head-mismatch"
write_defaults
jq -cn --arg head "$moved_sha" \
    '{state:"OPEN",isDraft:true,headRefOid:$head,
      reviewDecision:"REVIEW_REQUIRED",mergeStateStatus:"BLOCKED",
      headRefName:"feature-branch",baseRefName:"main",baseRefOid:"b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0"}' \
    >"${fixtures}/pr-view.json"
run_gate
assert_gate 1 fail head-mismatch

echo "==> a failing check run fails as checks-failing and names the check"
write_defaults
jq -cn '[{total_count:2,check_runs:[
    {name:"build",status:"completed",conclusion:"success"},
    {name:"lint",status:"completed",conclusion:"failure"}]}]' \
    >"${fixtures}/check-runs.pages.json"
run_gate
assert_gate 1 fail checks-failing
grep -Fq 'lint' <<<"$gate_out" ||
    fail "checks-failing did not name the failing check: $gate_out"

echo "==> a pending (unconcluded) check run fails as checks-pending"
write_defaults
jq -cn '[{total_count:2,check_runs:[
    {name:"build",status:"completed",conclusion:"success"},
    {name:"verify",status:"in_progress",conclusion:null}]}]' \
    >"${fixtures}/check-runs.pages.json"
run_gate
assert_gate 1 fail checks-pending
grep -Fq 'verify' <<<"$gate_out" ||
    fail "checks-pending did not name the pending check: $gate_out"

echo "==> a failing latest legacy status fails as checks-failing"
write_defaults
jq -cn '[[{context:"ci/legacy",state:"success",id:1},
          {context:"ci/legacy",state:"failure",id:3}]]' \
    >"${fixtures}/statuses.pages.json"
run_gate
assert_gate 1 fail checks-failing

echo "==> a multi-MB check-runs payload still classifies (ARG_MAX regression)"
# A much-rerun head accumulates thousands of check runs. Passed to jq through
# argv (`--argjson runs`), that payload exceeds the kernel's per-argument
# limit and jq dies "Argument list too long" — which the gate could only
# report as `malformed-data`, indeterminate for a mechanical reason, on
# exactly the heads it matters most for (harmon-init#821's gate, 2026-08-12).
# The fixture must stay far above the limit for this test to keep reproducing,
# so its size is asserted rather than assumed.
write_defaults
jq -cn '[{total_count:60001,
    check_runs:([range(0;60000) |
        {name:("rerun-" + (. | tostring)),
         status:"completed",conclusion:"success"}] +
        [{name:"lint",status:"completed",conclusion:"failure"}])}]' \
    >"${fixtures}/check-runs.pages.json"
oversized_bytes="$(wc -c <"${fixtures}/check-runs.pages.json")"
[ "$oversized_bytes" -gt 1048576 ] ||
    fail "the ARG_MAX fixture shrank to ${oversized_bytes} bytes — below the per-argument limit it exists to exceed, so it no longer reproduces"
run_gate
assert_gate 1 fail checks-failing
grep -Fq 'lint' <<<"$gate_out" ||
    fail "the oversized payload was not classified — the failing check went unnamed: $gate_out"

# The downstream twin of the same death: with the classification surviving
# --slurpfile, a payload where the checks FAIL en masse used to join every
# name into the detail string, and emit's `jq --arg detail` put that
# multi-megabyte join back into one argv entry (exit 126). The detail must
# stay bounded — first names plus a count — while still naming real checks.
echo "==> an oversized payload of FAILING checks yields a bounded detail"
write_defaults
jq -cn '[{total_count:60000,
    check_runs:[range(0;60000) |
        {name:("broken-" + (. | tostring)),
         status:"completed",conclusion:"failure"}]}]' \
    >"${fixtures}/check-runs.pages.json"
run_gate
assert_gate 1 fail checks-failing
grep -Fq 'broken-0' <<<"$gate_out" ||
    fail "the bounded detail names no failing check: $gate_out"
grep -Eq 'and 599[0-9]+ more' <<<"$gate_out" ||
    fail "the bounded detail does not carry the truncation count: $gate_out"
detail_bytes="$(printf '%s' "$gate_out" | wc -c)"
[ "$detail_bytes" -lt 8192 ] ||
    fail "the failing-checks detail is ${detail_bytes} bytes — unbounded diagnostics reintroduce the argv death one step downstream"

echo "==> a stale failed check suite superseded by a later success passes (harmon-devkit#714)"
# A workflow triggering on pull_request.edited (this repo's guard jobs) starts
# a fresh check suite on every PR-body edit against an unchanged head:
# filter=latest collapses only WITHIN one suite, so an early failure and a
# later success for the same check name both survive as separate check runs.
# The gate must collapse them itself, by workflow identity, and keep the
# later one — "later" by check-run id (delivery order), not started_at,
# which queuing can reorder relative to delivery.
write_defaults
jq -cn '[{total_count:2,check_runs:[
    {id:1,name:"guard",status:"completed",conclusion:"failure",
     started_at:"2026-01-01T00:00:00Z",check_suite:{id:10}},
    {id:2,name:"guard",status:"completed",conclusion:"success",
     started_at:"2026-01-01T00:05:00Z",check_suite:{id:20}}]}]' \
    >"${fixtures}/check-runs.pages.json"
jq -cn '[{total_count:2,workflow_runs:[
    {check_suite_id:10,workflow_id:100,event:"pull_request"},
    {check_suite_id:20,workflow_id:100,event:"pull_request"}]}]' \
    >"${fixtures}/workflow-runs.pages.json"
run_gate
assert_gate 0 pass ready

echo "==> a stale PASSING check suite superseded by a later failure still fails (inverse of the above)"
write_defaults
jq -cn '[{total_count:2,check_runs:[
    {id:1,name:"guard",status:"completed",conclusion:"success",
     started_at:"2026-01-01T00:00:00Z",check_suite:{id:30}},
    {id:2,name:"guard",status:"completed",conclusion:"failure",
     started_at:"2026-01-01T00:05:00Z",check_suite:{id:40}}]}]' \
    >"${fixtures}/check-runs.pages.json"
jq -cn '[{total_count:2,workflow_runs:[
    {check_suite_id:30,workflow_id:100,event:"pull_request"},
    {check_suite_id:40,workflow_id:100,event:"pull_request"}]}]' \
    >"${fixtures}/workflow-runs.pages.json"
run_gate
assert_gate 1 fail checks-failing
grep -Fq 'guard' <<<"$gate_out" ||
    fail "checks-failing did not name the check whose latest run fails: $gate_out"

echo "==> a cancelled check suite superseded by a later success passes (harmon-devkit#461)"
write_defaults
jq -cn '[{total_count:2,check_runs:[
    {id:1,name:"guard",status:"completed",conclusion:"cancelled",
     started_at:"2026-01-01T00:00:00Z",check_suite:{id:45}},
    {id:2,name:"guard",status:"completed",conclusion:"success",
     started_at:"2026-01-01T00:05:00Z",check_suite:{id:46}}]}]' \
    >"${fixtures}/check-runs.pages.json"
jq -cn '[{total_count:2,workflow_runs:[
    {check_suite_id:45,workflow_id:100,event:"pull_request"},
    {check_suite_id:46,workflow_id:100,event:"pull_request"}]}]' \
    >"${fixtures}/workflow-runs.pages.json"
run_gate
assert_gate 0 pass ready

echo "==> a cancelled-only check suite blocks (harmon-devkit#461)"
write_defaults
jq -cn '[{total_count:1,check_runs:[
    {id:1,name:"guard",status:"completed",conclusion:"cancelled",
     check_suite:{id:47}}]}]' \
    >"${fixtures}/check-runs.pages.json"
jq -cn '[{total_count:1,workflow_runs:[
    {check_suite_id:47,workflow_id:100,event:"pull_request"}]}]' \
    >"${fixtures}/workflow-runs.pages.json"
run_gate
assert_gate 1 fail checks-failing
grep -Fq 'guard' <<<"$gate_out" ||
    fail "checks-failing did not name the cancelled check: $gate_out"

echo "==> a newer cancelled suite supersedes an earlier success and blocks (harmon-devkit#461)"
write_defaults
jq -cn '[{total_count:2,check_runs:[
    {id:1,name:"guard",status:"completed",conclusion:"success",
     started_at:"2026-01-01T00:00:00Z",check_suite:{id:48}},
    {id:2,name:"guard",status:"completed",conclusion:"cancelled",
     started_at:"2026-01-01T00:05:00Z",check_suite:{id:49}}]}]' \
    >"${fixtures}/check-runs.pages.json"
jq -cn '[{total_count:2,workflow_runs:[
    {check_suite_id:48,workflow_id:100,event:"pull_request"},
    {check_suite_id:49,workflow_id:100,event:"pull_request"}]}]' \
    >"${fixtures}/workflow-runs.pages.json"
run_gate
assert_gate 1 fail checks-failing
grep -Fq 'guard' <<<"$gate_out" ||
    fail "checks-failing did not name the newer cancelled check: $gate_out"

echo "==> a newer still-running suite remains pending after an older cancelled run (harmon-devkit#461)"
write_defaults
jq -cn '[{total_count:2,check_runs:[
    {id:1,name:"guard",status:"completed",conclusion:"cancelled",
     started_at:"2026-01-01T00:00:00Z",check_suite:{id:50}},
    {id:2,name:"guard",status:"in_progress",conclusion:null,
     started_at:"2026-01-01T00:05:00Z",check_suite:{id:51}}]}]' \
    >"${fixtures}/check-runs.pages.json"
jq -cn '[{total_count:2,workflow_runs:[
    {check_suite_id:50,workflow_id:100,event:"pull_request"},
    {check_suite_id:51,workflow_id:100,event:"pull_request"}]}]' \
    >"${fixtures}/workflow-runs.pages.json"
run_gate
assert_gate 1 fail checks-pending
grep -Fq 'guard' <<<"$gate_out" ||
    fail "checks-pending did not name the still-running check: $gate_out"

echo "==> a suite that started later but was delivered earlier is not mistaken for the latest"
# started_at reflects when a runner picked the job up, not delivery order;
# under queuing an EARLIER delivery (the lower check_suite id) can start
# running AFTER a later one. Suite 80 is still the later delivery even though
# its run started first (00:00 vs suite 70's 00:05) — the gate must trust
# check_suite.id, not started_at, so suite 80's failure is the one that
# counts.
write_defaults
jq -cn '[{total_count:2,check_runs:[
    {id:1,name:"guard",status:"completed",conclusion:"success",
     started_at:"2026-01-01T00:05:00Z",check_suite:{id:70}},
    {id:2,name:"guard",status:"completed",conclusion:"failure",
     started_at:"2026-01-01T00:00:00Z",check_suite:{id:80}}]}]' \
    >"${fixtures}/check-runs.pages.json"
jq -cn '[{total_count:2,workflow_runs:[
    {check_suite_id:70,workflow_id:100,event:"pull_request"},
    {check_suite_id:80,workflow_id:100,event:"pull_request"}]}]' \
    >"${fixtures}/workflow-runs.pages.json"
run_gate
assert_gate 1 fail checks-failing

echo "==> two distinct workflows whose jobs share a literal name are kept apart, never suite-broken"
# Same started_at and two different check_suite ids below: collapsing by name
# alone (the pre-#714 bug) feeds group_by a single group, and picking the
# latest suite then keeps whichever suite id is higher regardless of which
# workflow it belongs to — silently hiding this workflow's failure behind the
# other's success. Keyed on workflow identity, the two never share a group,
# so the failure cannot be hidden by which suite happens to sort higher.
write_defaults
jq -cn '[{total_count:2,check_runs:[
    {id:1,name:"guard",status:"completed",conclusion:"failure",
     started_at:"2026-01-01T00:00:00Z",check_suite:{id:50}},
    {id:2,name:"guard",status:"completed",conclusion:"success",
     started_at:"2026-01-01T00:00:00Z",check_suite:{id:60}}]}]' \
    >"${fixtures}/check-runs.pages.json"
jq -cn '[{total_count:2,workflow_runs:[
    {check_suite_id:50,workflow_id:100,event:"pull_request"},
    {check_suite_id:60,workflow_id:200,event:"pull_request"}]}]' \
    >"${fixtures}/workflow-runs.pages.json"
run_gate
assert_gate 1 fail checks-failing
grep -Fq 'guard' <<<"$gate_out" ||
    fail "checks-failing did not surface the failing workflow's guard job when a same-named passing job from a different workflow has a higher id: $gate_out"

echo "==> the same workflow answering two different trigger events is kept apart (harmon-devkit#714 round 1)"
# build.yml here runs on pull_request, push, merge_group, AND workflow_dispatch
# alike. A later successful manual dispatch of the same workflow/job name is
# not a supersession of an earlier failed pull_request run — they answer
# different questions on the same commit. The event must be part of the
# collapse key, not just the workflow id.
write_defaults
jq -cn '[{total_count:2,check_runs:[
    {id:1,name:"verify",status:"completed",conclusion:"failure",
     started_at:"2026-01-01T00:00:00Z",check_suite:{id:90}},
    {id:2,name:"verify",status:"completed",conclusion:"success",
     started_at:"2026-01-01T00:05:00Z",check_suite:{id:91}}]}]' \
    >"${fixtures}/check-runs.pages.json"
jq -cn '[{total_count:2,workflow_runs:[
    {check_suite_id:90,workflow_id:100,event:"pull_request"},
    {check_suite_id:91,workflow_id:100,event:"workflow_dispatch"}]}]' \
    >"${fixtures}/workflow-runs.pages.json"
run_gate
assert_gate 1 fail checks-failing
grep -Fq 'verify' <<<"$gate_out" ||
    fail "checks-failing did not surface the failed pull_request run when a later workflow_dispatch of the same workflow/job succeeded: $gate_out"

echo "==> two jobs in one workflow that render the same name are BOTH kept when they coexist in the latest suite (harmon-devkit#714 round 2)"
# A workflow can define two job blocks that both render as "verify" (a
# hardcoded name:, or a matrix with no differentiating label). Both check
# runs land in the SAME latest suite -- collapsing the whole identity group
# to a single highest-id winner would keep whichever job happened to get the
# higher id and silently drop the other's failure, even though neither
# superseded the other. An OLDER suite's run for the same identity must
# still be dropped as genuinely superseded.
write_defaults
jq -cn '[{total_count:3,check_runs:[
    {id:1,name:"verify",status:"completed",conclusion:"success",
     started_at:"2026-01-01T00:00:00Z",check_suite:{id:100}},
    {id:2,name:"verify",status:"completed",conclusion:"failure",
     started_at:"2026-01-01T00:00:00Z",check_suite:{id:200}},
    {id:3,name:"verify",status:"completed",conclusion:"success",
     started_at:"2026-01-01T00:00:00Z",check_suite:{id:200}}]}]' \
    >"${fixtures}/check-runs.pages.json"
jq -cn '[{total_count:1,workflow_runs:[
    {check_suite_id:200,workflow_id:100,event:"pull_request"}]}]' \
    >"${fixtures}/workflow-runs.pages.json"
run_gate
assert_gate 1 fail checks-failing
grep -Fq 'verify' <<<"$gate_out" ||
    fail "checks-failing did not surface the failing sibling job when a same-named passing sibling shares its (latest) suite: $gate_out"

echo "==> a same-sha run scoped to a DIFFERENT PR cannot supersede this PR's failure (harmon-devkit#714 round 3)"
# head_sha alone does not scope to one PR: the same commit can back open PRs
# against more than one base branch, and actions/runs returns every run for
# the sha regardless of which PR it belongs to. A newer, higher-suite-id run
# that is provably for PR 999 (not this gate's PR 493) must not be treated
# as superseding this PR's own failing suite, even though its check_suite id
# sorts higher.
write_defaults
jq -cn '[{total_count:2,check_runs:[
    {id:1,name:"guard",status:"completed",conclusion:"failure",
     started_at:"2026-01-01T00:00:00Z",check_suite:{id:10}},
    {id:2,name:"guard",status:"completed",conclusion:"success",
     started_at:"2026-01-01T00:05:00Z",check_suite:{id:20}}]}]' \
    >"${fixtures}/check-runs.pages.json"
jq -cn '[{total_count:2,workflow_runs:[
    {check_suite_id:10,workflow_id:100,event:"pull_request",
     pull_requests:[{number:493}]},
    {check_suite_id:20,workflow_id:100,event:"pull_request",
     pull_requests:[{number:999}]}]}]' \
    >"${fixtures}/workflow-runs.pages.json"
run_gate
assert_gate 1 fail checks-failing
grep -Fq 'guard' <<<"$gate_out" ||
    fail "checks-failing did not survive when a higher-suite-id run scoped to a different PR shared the same name/workflow/event: $gate_out"

echo "==> an empty pull_requests association still allows the normal collapse (unscoped, as before)"
# GitHub is known to leave pull_requests empty even for a run that genuinely
# belongs to the open PR being gated -- absence must not be read as "wrong
# PR," or every ordinary same-PR case using this shape would wrongly split
# into two identities and both survive as false failures.
write_defaults
jq -cn '[{total_count:2,check_runs:[
    {id:1,name:"guard",status:"completed",conclusion:"failure",
     started_at:"2026-01-01T00:00:00Z",check_suite:{id:10}},
    {id:2,name:"guard",status:"completed",conclusion:"success",
     started_at:"2026-01-01T00:05:00Z",check_suite:{id:20}}]}]' \
    >"${fixtures}/check-runs.pages.json"
jq -cn '[{total_count:2,workflow_runs:[
    {check_suite_id:10,workflow_id:100,event:"pull_request",pull_requests:[]},
    {check_suite_id:20,workflow_id:100,event:"pull_request",pull_requests:[]}]}]' \
    >"${fixtures}/workflow-runs.pages.json"
run_gate
assert_gate 0 pass ready

echo "==> a run naming MULTIPLE PRs (a genuinely shared head) cannot clear this PR's own failure (harmon-devkit#714 review r1)"
# GitHub populates pull_requests with EVERY open PR whose head currently
# matches, not the one that triggered the run, so a run listing both 493 and
# 999 does not confidently belong to either -- a same-PR-number membership
# test alone would wrongly treat it as "ours" and let its later success
# supersede this PR's own confidently-scoped failure. It must still be kept
# (dropping it could hide a real failure), just never allowed to collapse
# against a run this gate IS confident belongs to this PR.
write_defaults
jq -cn '[{total_count:2,check_runs:[
    {id:1,name:"guard",status:"completed",conclusion:"failure",
     started_at:"2026-01-01T00:00:00Z",check_suite:{id:10}},
    {id:2,name:"guard",status:"completed",conclusion:"success",
     started_at:"2026-01-01T00:05:00Z",check_suite:{id:20}}]}]' \
    >"${fixtures}/check-runs.pages.json"
jq -cn '[{total_count:2,workflow_runs:[
    {check_suite_id:10,workflow_id:100,event:"pull_request",
     pull_requests:[{number:493}]},
    {check_suite_id:20,workflow_id:100,event:"pull_request",
     pull_requests:[{number:493},{number:999}]}]}]' \
    >"${fixtures}/workflow-runs.pages.json"
run_gate
assert_gate 1 fail checks-failing
grep -Fq 'guard' <<<"$gate_out" ||
    fail "checks-failing did not survive when a later run naming multiple PRs (including this one) shared the same name/workflow/event: $gate_out"

echo "==> a failing run that itself names multiple PRs still surfaces (ambiguous is kept, not dropped)"
write_defaults
jq -cn '[{total_count:1,check_runs:[
    {id:1,name:"guard",status:"completed",conclusion:"failure",
     started_at:"2026-01-01T00:00:00Z",check_suite:{id:10}}]}]' \
    >"${fixtures}/check-runs.pages.json"
jq -cn '[{total_count:1,workflow_runs:[
    {check_suite_id:10,workflow_id:100,event:"pull_request",
     pull_requests:[{number:493},{number:999}]}]}]' \
    >"${fixtures}/workflow-runs.pages.json"
run_gate
assert_gate 1 fail checks-failing
grep -Fq 'guard' <<<"$gate_out" ||
    fail "a failing run naming multiple PRs (including this one) was dropped instead of surfaced: $gate_out"

echo "==> two ambiguous (multi-PR) suites do not clear one another (harmon-devkit#714 review r2)"
# There is no more confident basis for "later ambiguous suite supersedes an
# earlier ambiguous suite" than there was for "supersedes this PR's own
# confidently-scoped run" -- an ambiguous suite's identity must be
# permanently distinct so a later ambiguous success cannot hide an earlier
# ambiguous failure.
write_defaults
jq -cn '[{total_count:2,check_runs:[
    {id:1,name:"guard",status:"completed",conclusion:"failure",
     started_at:"2026-01-01T00:00:00Z",check_suite:{id:10}},
    {id:2,name:"guard",status:"completed",conclusion:"success",
     started_at:"2026-01-01T00:05:00Z",check_suite:{id:20}}]}]' \
    >"${fixtures}/check-runs.pages.json"
jq -cn '[{total_count:2,workflow_runs:[
    {check_suite_id:10,workflow_id:100,event:"pull_request",
     pull_requests:[{number:493},{number:999}]},
    {check_suite_id:20,workflow_id:100,event:"pull_request",
     pull_requests:[{number:493},{number:999}]}]}]' \
    >"${fixtures}/workflow-runs.pages.json"
run_gate
assert_gate 1 fail checks-failing
grep -Fq 'guard' <<<"$gate_out" ||
    fail "checks-failing did not survive when a later ambiguous suite's success shared its nominal workflow/event with an earlier ambiguous failure: $gate_out"

echo "==> a failing run unambiguously scoped to another PR is dropped outright, not just its metadata (harmon-devkit#714 review r2)"
# Excluding a run from the workflow lookup alone is not enough: its check
# run must not survive at all, or it falls to the app-id identity and, if
# failing, wrongly fails a PR it was never testing.
write_defaults
jq -cn '[{total_count:1,check_runs:[
    {id:1,name:"guard",status:"completed",conclusion:"failure",
     started_at:"2026-01-01T00:00:00Z",check_suite:{id:10}}]}]' \
    >"${fixtures}/check-runs.pages.json"
jq -cn '[{total_count:1,workflow_runs:[
    {check_suite_id:10,workflow_id:100,event:"pull_request",
     pull_requests:[{number:999}]}]}]' \
    >"${fixtures}/workflow-runs.pages.json"
run_gate
assert_gate 0 pass ready

echo "==> two different non-Actions apps sharing a check name are never conflated (harmon-devkit#714 review r3)"
# A check run with no actions/runs match falls back to its own app id. Piping
# the suite lookup result into a variable changes jq's current input for
# that branch -- reading .app.id from inside it (instead of capturing the
# outer run's app id first) silently reads the LOOKUP's non-existent app.id
# instead, which is always null, so every non-Actions run collapsed into the
# same "app:0" bucket regardless of which app actually posted it. Two
# different real app ids sharing a check name must stay in separate
# identities, or one app's later success can hide an entirely different
# app's failure.
write_defaults
jq -cn '[{total_count:2,check_runs:[
    {id:1,name:"lint",status:"completed",conclusion:"failure",
     started_at:"2026-01-01T00:00:00Z",check_suite:{id:10},app:{id:42}},
    {id:2,name:"lint",status:"completed",conclusion:"success",
     started_at:"2026-01-01T00:05:00Z",check_suite:{id:20},app:{id:77}}]}]' \
    >"${fixtures}/check-runs.pages.json"
run_gate
assert_gate 1 fail checks-failing
grep -Fq 'lint' <<<"$gate_out" ||
    fail "checks-failing did not survive when a different non-Actions app's later success shared a check name with an earlier failure: $gate_out"

echo "==> a shared head where BOTH PRs get an empty pull_requests is still told apart by branch name (harmon-devkit#714 shepherd, PR #723)"
# GitHub can return an empty pull_requests for a run genuinely triggered by a
# SIBLING PR too, not only for this one -- pull_requests[] membership alone
# then has nothing to compare. head_branch is available at no extra fetch
# cost and, when it does not match this PR's own branch (write_defaults sets
# headRefName to "feature-branch"), is positive evidence the run belongs to
# a different PR even though pull_requests came back empty on both sides.
write_defaults
jq -cn '[{total_count:2,check_runs:[
    {id:1,name:"guard",status:"completed",conclusion:"failure",
     started_at:"2026-01-01T00:00:00Z",check_suite:{id:10}},
    {id:2,name:"guard",status:"completed",conclusion:"success",
     started_at:"2026-01-01T00:05:00Z",check_suite:{id:20}}]}]' \
    >"${fixtures}/check-runs.pages.json"
jq -cn '[{total_count:2,workflow_runs:[
    {check_suite_id:10,workflow_id:100,event:"pull_request",
     pull_requests:[],head_branch:"feature-branch"},
    {check_suite_id:20,workflow_id:100,event:"pull_request",
     pull_requests:[],head_branch:"someone-elses-branch"}]}]' \
    >"${fixtures}/workflow-runs.pages.json"
run_gate
assert_gate 1 fail checks-failing
grep -Fq 'guard' <<<"$gate_out" ||
    fail "checks-failing did not survive when a later run on a DIFFERENT branch (both sides reporting empty pull_requests) shared the same name/workflow/event: $gate_out"

echo "==> a push/workflow_dispatch run on another branch is never excluded by the branch heuristic (harmon-devkit#714 shepherd r2)"
# The branch-mismatch exclusion only makes sense for pull_request-triggered
# runs -- a push or workflow_dispatch run has no PR to belong to at all, so
# judging it against this PR's branch name is a category error. It already
# gets its own distinct identity via `event`, so a later same-named
# pull_request success must not hide an earlier push-triggered failure.
write_defaults
jq -cn '[{total_count:2,check_runs:[
    {id:1,name:"guard",status:"completed",conclusion:"failure",
     started_at:"2026-01-01T00:00:00Z",check_suite:{id:10}},
    {id:2,name:"guard",status:"completed",conclusion:"success",
     started_at:"2026-01-01T00:05:00Z",check_suite:{id:20}}]}]' \
    >"${fixtures}/check-runs.pages.json"
jq -cn '[{total_count:2,workflow_runs:[
    {check_suite_id:10,workflow_id:100,event:"push",
     pull_requests:[],head_branch:"main"},
    {check_suite_id:20,workflow_id:100,event:"pull_request",
     pull_requests:[],head_branch:"feature-branch"}]}]' \
    >"${fixtures}/workflow-runs.pages.json"
run_gate
assert_gate 1 fail checks-failing
grep -Fq 'guard' <<<"$gate_out" ||
    fail "checks-failing did not survive a push-triggered failure on an unrelated branch, which the branch heuristic must not exclude: $gate_out"

echo "==> a multi-PR run that OMITS this PR entirely is excluded, not treated as ambiguous (harmon-devkit#714 shepherd r2)"
# A pull_requests list naming two or more OTHER PRs, with this PR's number
# nowhere in it, is just as conclusive as a singleton naming one other PR --
# length alone must not decide ambiguity; whether this PR's number appears
# in the list does.
write_defaults
jq -cn '[{total_count:1,check_runs:[
    {id:1,name:"guard",status:"completed",conclusion:"failure",
     started_at:"2026-01-01T00:00:00Z",check_suite:{id:10}}]}]' \
    >"${fixtures}/check-runs.pages.json"
jq -cn '[{total_count:1,workflow_runs:[
    {check_suite_id:10,workflow_id:100,event:"pull_request",
     pull_requests:[{number:999},{number:1000}]}]}]' \
    >"${fixtures}/workflow-runs.pages.json"
run_gate
assert_gate 0 pass ready

echo "==> a push run with a stale PR association naming only a sibling is never excluded (harmon-devkit#714 shepherd r3)"
# pull_requests[] on a non-pull_request-triggered run is a best-effort
# historical association GitHub attaches after the fact, not evidence about
# what the run itself tested -- a push run naming only PR 999 must not be
# judged "other-pr" and dropped, the same category error as judging it by
# branch would be.
write_defaults
jq -cn '[{total_count:1,check_runs:[
    {id:1,name:"guard",status:"completed",conclusion:"failure",
     started_at:"2026-01-01T00:00:00Z",check_suite:{id:10}}]}]' \
    >"${fixtures}/check-runs.pages.json"
jq -cn '[{total_count:1,workflow_runs:[
    {check_suite_id:10,workflow_id:100,event:"push",
     pull_requests:[{number:999}],head_branch:"main"}]}]' \
    >"${fixtures}/workflow-runs.pages.json"
run_gate
assert_gate 1 fail checks-failing
grep -Fq 'guard' <<<"$gate_out" ||
    fail "checks-failing did not survive a push run whose only pull_requests association names a different PR: $gate_out"

echo "==> two push suites on different branches sharing a sha are kept apart by branch (harmon-devkit#714 shepherd r3)"
# The same tree pushed to two branches produces two independently
# significant answers -- without the branch in the identity, both would
# render as the same wf:<id>:push and collapse, letting one branch's later
# success hide the other's earlier failure.
write_defaults
jq -cn '[{total_count:2,check_runs:[
    {id:1,name:"guard",status:"completed",conclusion:"failure",
     started_at:"2026-01-01T00:00:00Z",check_suite:{id:10}},
    {id:2,name:"guard",status:"completed",conclusion:"success",
     started_at:"2026-01-01T00:05:00Z",check_suite:{id:20}}]}]' \
    >"${fixtures}/check-runs.pages.json"
jq -cn '[{total_count:2,workflow_runs:[
    {check_suite_id:10,workflow_id:100,event:"push",
     pull_requests:[],head_branch:"main"},
    {check_suite_id:20,workflow_id:100,event:"push",
     pull_requests:[],head_branch:"release"}]}]' \
    >"${fixtures}/workflow-runs.pages.json"
run_gate
assert_gate 1 fail checks-failing
grep -Fq 'guard' <<<"$gate_out" ||
    fail "checks-failing did not survive when a push suite on a different branch shared the workflow/event but not the branch: $gate_out"

echo "==> an EMPTY check list is indeterminate, never a pass"
write_defaults
printf '%s\n' '[{"total_count":0,"check_runs":[]}]' \
    >"${fixtures}/check-runs.pages.json"
printf '%s\n' '[[]]' >"${fixtures}/statuses.pages.json"
run_gate
assert_gate 2 indeterminate checks-indeterminate

echo "==> CHANGES_REQUESTED fails as changes-requested"
write_defaults
jq -cn --arg head "$head_sha" \
    '{state:"OPEN",isDraft:true,headRefOid:$head,
      reviewDecision:"CHANGES_REQUESTED",mergeStateStatus:"BLOCKED",
      headRefName:"feature-branch",baseRefName:"main",baseRefOid:"b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0"}' \
    >"${fixtures}/pr-view.json"
run_gate
assert_gate 1 fail changes-requested

# BEHIND is RECLASSIFIED, not relaxed: the graph check above already failed a
# genuinely behind head as `behind-base`, so reaching the cache branch means
# the cache disagrees with the graph. Both outcomes refuse promotion — exit 1
# vs exit 2 — but `merge-state-stale` says "re-poll", where the old
# `merge-state-behind` sent the caller to merge a base it is level with.
echo "==> DIRTY fails; a cache-only BEHIND and UNKNOWN are indeterminate"
for pair in "DIRTY 1 fail merge-state-dirty" "BEHIND 2 indeterminate merge-state-stale" \
    "UNKNOWN 2 indeterminate merge-state-unknown"; do
    # shellcheck disable=SC2086
    set -- $pair
    write_defaults
    jq -cn --arg head "$head_sha" --arg ms "$1" \
        '{state:"OPEN",isDraft:true,headRefOid:$head,
          reviewDecision:"REVIEW_REQUIRED",mergeStateStatus:$ms,
          headRefName:"feature-branch",baseRefName:"main",baseRefOid:"b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0"}' \
        >"${fixtures}/pr-view.json"
    run_gate
    assert_gate "$2" "$3" "$4"
done

echo "==> an unsettled deferred finding fails as deferred-unsettled"
write_defaults
jq -cn --arg head "$head_sha" \
    '{schema:2, run_id:"test-run", stage:"review", round:1,
      reviewed_head:$head,
      adjudications:[{finding_id:"review-r1-codex-cli-1",
        reviewer_priority:"P2", adjudicated_priority:"P2",
        disposition:"defer", reason:"carrying to integration",
        evidence:"needs a second look", override:null}]}' \
    >"${record_dir}/adjudications/review-r1.json"
write_review_r1_pass review-r1-codex-cli-1
# run.json's settlements[] stays empty from write_default_record — nothing
# has settled the one deferred finding the adjudication above declares.
run_gate
assert_gate 1 fail deferred-unsettled
grep -Fq 'review-r1-codex-cli-1' <<<"$gate_out" ||
    fail "deferred-unsettled did not name the unsettled finding: $gate_out"

echo "==> the same finding, once settled in run.json, passes that condition"
write_defaults
jq -cn --arg head "$head_sha" \
    '{schema:2, run_id:"test-run", stage:"review", round:1,
      reviewed_head:$head,
      adjudications:[{finding_id:"review-r1-codex-cli-1",
        reviewer_priority:"P2", adjudicated_priority:"P2",
        disposition:"defer", reason:"carrying to integration",
        evidence:"needs a second look", override:null}]}' \
    >"${record_dir}/adjudications/review-r1.json"
write_review_r1_pass review-r1-codex-cli-1
jq -cn --arg head "$head_sha" --argjson transitions "$(lifecycle_transitions)" \
    '{schema:2, run_id:"test-run", initiated_by:"human",
      started_at:"2026-01-01T00:00:00Z",
      stage_transitions:$transitions,
      interventions:[], outcome:null,
      pr:{number:493,url:"https://github.com/example/repo/pull/493"},
      evidence_comments:[],
      settlements:[{finding_id:"review-r1-codex-cli-1", disposition:"decline",
        settled_at:"2026-01-01T00:12:00Z",
        reference:{type:"comment_id",value:"555"}}],
      promotion:null,
      evidence_registrations:[], outcome_transitions:[],
      pr_bindings:[{seq:0,prev_digest:"genesis",
        digest:"ec64b9703afdb8ec84d58495e89b4b11dc8c0a96720b330f649e0fe10a498ec1",
        number:493,url:"https://github.com/example/repo/pull/493",
        bound_at:"2026-01-01T00:00:00Z"}]}' >"${record_dir}/run.json"
run_gate
assert_gate 0 pass ready

echo "==> a record with no deferred findings at all passes that condition"
write_defaults
run_gate
assert_gate 0 pass ready

# 9a: the pass's own findings[] is unconditional evidence, independent of
# codex_cycle (review round 2 gauntlet challenge, harmon-devkit#639). A
# schema-valid verdict:"clean" cannot itself carry an undispositioned finding
# (validate-result-schemas.mjs already ties every listed finding to a
# decline/file disposition there), so exercise the gap the schema does allow:
# a non-"clean" verdict (here "findings") whose codex_cycle is independently
# waived by --integration-cap 0. Nothing else in the gate (thread-linkage is
# inline-only, deferred-findings only covers findings already carried from an
# earlier stage) can ever catch a finding surfaced only here.
echo "==> a pass reporting a non-empty findings[] fails as unresolved-integrator-findings"
write_defaults
findings_result="${fixtures}/integrator-result-with-findings.json"
jq -cn --arg head "$head_sha" '
  {schema:2, role:"integrator", status:"completed", head:$head,
   produced_at:"2026-01-01T00:00:00Z",
   producer:{harness:"claude-code",model:"test",tier:"economy"},
   run:{run_id:"test-run",initiated_by:"human"},
   payload:{checks:[{name:"build",bucket:"pass",run_id:"1",required:true}],
            codex_cycle:null, integration_round:1,
            findings:[{id:"integration-r1-human-1",
                       body:"a top-level finding needing adjudication",
                       source_id:"42"}],
            unanswered_thread_roots:[], settled_at:"2026-01-01T00:00:00Z",
            verdict:"findings"}}' \
    >"$findings_result"
node "$validator" envelope "$findings_result" >/dev/null ||
    fail "with-findings fixture failed schema validation"
run_gate --integrator-result "$findings_result"
assert_gate 1 fail unresolved-integrator-findings
grep -Fq 'integration-r1-human-1' <<<"$gate_out" ||
    fail "unresolved-integrator-findings did not name the finding: $gate_out"

# 9c (Codex cloud-review cycle on PR harmon-devkit#758): a pass that never
# finished is not a waiver. Under --integration-cap 0 a null codex_cycle is
# the legitimate waived case, but the SAME null cycle is what the agent
# reports when it skipped the cycle because CI was still pending (verdict
# "pending"), or when it stopped in its §1 before reading anything (status
# "blocked") — and both can carry empty findings[]/unanswered_thread_roots
# that mean "never collected". Live checks/threads above are green in these
# fixtures, so nothing but the verdict/status requirement itself can catch
# them.
write_integrator_pass_fixture() {
    local name="$1" status="$2" verdict="$3"
    local out="${fixtures}/integrator-result-${name}.json"
    jq -cn --arg head "$head_sha" --arg status "$status" --arg verdict "$verdict" '
      {schema:2, role:"integrator", status:$status, head:$head,
       produced_at:"2026-01-01T00:00:00Z",
       producer:{harness:"claude-code",model:"test",tier:"economy"},
       run:{run_id:"test-run",initiated_by:"human"},
       payload:{checks:[{name:"build",bucket:"pass",run_id:"1",required:true}],
                codex_cycle:null, integration_round:1, findings:[],
                unanswered_thread_roots:[], settled_at:"2026-01-01T00:00:00Z",
                verdict:$verdict}}' >"$out"
    node "$validator" envelope "$out" >/dev/null ||
        fail "$name fixture failed schema validation"
    printf '%s' "$out"
}

echo "==> a cap-0 pass with verdict pending (CI unsettled, cycle skipped) fails as integrator-not-clean"
write_defaults
pending_result="$(write_integrator_pass_fixture cap-zero-pending completed pending)"
run_gate --integrator-result "$pending_result" --integration-cap 0
assert_gate 1 fail integrator-not-clean
grep -Fq 'verdict is pending' <<<"$gate_out" ||
    fail "integrator-not-clean did not name the verdict: $gate_out"

echo "==> a cap-0 pass with status blocked fails as integrator-not-clean"
write_defaults
blocked_result="$(write_integrator_pass_fixture cap-zero-blocked blocked pending)"
run_gate --integrator-result "$blocked_result" --integration-cap 0
assert_gate 1 fail integrator-not-clean
grep -Fq 'status is blocked' <<<"$gate_out" ||
    fail "integrator-not-clean did not name the status: $gate_out"

echo "==> a cap-0 pass with verdict escalate fails as integrator-not-clean"
write_defaults
escalate_result="$(write_integrator_pass_fixture cap-zero-escalate completed escalate)"
run_gate --integrator-result "$escalate_result" --integration-cap 0
assert_gate 1 fail integrator-not-clean

echo "==> an unanswered inline thread fails as threads-unanswered"
write_defaults
jq -cn '[[{id:900,user:{login:"reviewer-bot"},path:"f.sh",in_reply_to_id:null,
           created_at:"2026-08-01T00:00:00Z",updated_at:"2026-08-01T00:00:00Z",
           body:"finding"}]]' >"${fixtures}/inline.pages.json"
run_gate
assert_gate 1 fail threads-unanswered
grep -Fq '900' <<<"$gate_out" ||
    fail "threads-unanswered did not name the root: $gate_out"

echo "==> an answered thread passes; a reviewer follow-up after the reply fails"
write_defaults
jq -cn '[[
    {id:900,user:{login:"reviewer-bot"},path:"f.sh",in_reply_to_id:null,
     created_at:"2026-08-01T00:00:00Z",updated_at:"2026-08-01T00:00:00Z",
     body:"finding"},
    {id:901,user:{login:"pr-author"},path:"f.sh",in_reply_to_id:900,
     created_at:"2026-08-01T01:00:00Z",updated_at:"2026-08-01T01:00:00Z",
     body:"fixed in abc"}]]' >"${fixtures}/inline.pages.json"
run_gate
assert_gate 0 pass ready
write_defaults
jq -cn '[[
    {id:900,user:{login:"reviewer-bot"},path:"f.sh",in_reply_to_id:null,
     created_at:"2026-08-01T00:00:00Z",updated_at:"2026-08-01T00:00:00Z",
     body:"finding"},
    {id:901,user:{login:"pr-author"},path:"f.sh",in_reply_to_id:900,
     created_at:"2026-08-01T01:00:00Z",updated_at:"2026-08-01T01:00:00Z",
     body:"fixed in abc"},
    {id:902,user:{login:"reviewer-bot"},path:"f.sh",in_reply_to_id:900,
     created_at:"2026-08-01T02:00:00Z",updated_at:"2026-08-01T02:00:00Z",
     body:"follow-up"}]]' >"${fixtures}/inline.pages.json"
run_gate
assert_gate 1 fail threads-new-follow-up

# --------------------------------------------------------------------------
# harmon-devkit#675: the #665 thread, verbatim. Root 3886138416 is a badged P1
# from the connector; the owner replied "Fixed in dfc3648…" at 09:23:57Z; the
# connector then ran a fix task of its own and posted its report at 09:25:52Z
# ("### Summary … Committed the change on `codex/name-review-trigger-broker`
# as `77379cf` … A pull request could not be created"). The gate raised
# `threads-new-follow-up` and blocked until a human replied to a machine a
# second time.
# --------------------------------------------------------------------------
self_fix_thread() {
    jq -cn --arg followup "$1" '[[
        {id:3886138416,user:{login:"chatgpt-codex-connector[bot]",id:199175422},
         path:"AGENTS.md",in_reply_to_id:null,
         created_at:"2026-08-29T09:20:04Z",updated_at:"2026-08-29T09:20:05Z",
         body:"**![P1 Badge](https://img.shields.io/badge/P1-orange?style=flat) Authorize a writer for the Codex trigger**\n\nprose"},
        {id:3886146197,user:{login:"pr-author",id:37220977},
         path:"AGENTS.md",in_reply_to_id:3886138416,
         author_association:"OWNER",
         created_at:"2026-08-29T09:23:57Z",updated_at:"2026-08-29T09:23:57Z",
         body:"Adjudicated P2. Fixed in dfc3648."},
        {id:3886149775,user:{login:"chatgpt-codex-connector[bot]",id:199175422},
         path:"AGENTS.md",in_reply_to_id:3886138416,
         created_at:"2026-08-29T09:25:52Z",updated_at:"2026-08-29T09:25:52Z",
         body:$followup}]]' >"${fixtures}/inline.pages.json"
}

echo "==> harmon-devkit#675: an unbadged bot self-fix summary is informational, not a follow-up"
write_defaults
self_fix_thread "### Summary

* Named the Codex-cycle helper broker.
* Committed the change on \`codex/name-review-trigger-broker\` as \`77379cf\`.
* A pull request could not be created because the required tool is unavailable."
run_gate
assert_gate 0 pass ready

echo "==> challenge-r1-codex-adversarial-1: an unbadged bot follow-up with the heading but NO self-work marker blocks"
# The reproduced hole: the first predicate accepted a bare `### Summary`
# heading, so an unbadged concern the bot wrote under it passed as
# informational. A self-report now needs positive evidence that the bot is
# describing its own work.
write_defaults
self_fix_thread "### Summary

The authorization check on the trigger broker is missing; any caller can post."
run_gate
assert_gate 1 fail threads-new-follow-up

echo "==> challenge-r1-codex-adversarial-1: a finding footer defeats the self-report shape"
write_defaults
self_fix_thread "### Summary

* Committed the change on \`codex/name-review-trigger-broker\` as \`77379cf\`.

The rollback path still drops the lock.

Useful? React with 👍 / 👎."
run_gate
assert_gate 1 fail threads-new-follow-up

echo "==> challenge-r1-codex-adversarial-1: each observed self-work marker still reads as informational"
for marker in \
    "Committed the change on \`codex/name-review-trigger-broker\` as \`77379cf\`." \
    "A pull request could not be created because the required tool is unavailable." \
    "Reviewed commit \`dfc3648\` and found no additional code changes necessary."; do
    write_defaults
    self_fix_thread "### Summary

* $marker"
    run_gate
    assert_gate 0 pass ready
done

echo "==> review-r1-codex-verification-2: a finder_cycles exit-16 uses the finder-prefixed token too"
# The 15 arm was renamed in challenge round 1 and its 16 sibling was left
# codex-prefixed and untested. Both are per-finder conditions; both say so.
write_defaults
fc_transient="$(write_integrator_result fc-transient "$(codex_cycle_json 0)")"
jq '.payload.verdict = "pending"
    | .payload.findings = [{id:"integration-r1-coderabbit-cloud-1",
                            body:"a finder finding",source_id:"1"}]
    | del(.payload.applied_dispositions)
    | .payload.finder_cycles = [{finder:"coderabbit-cloud",head:.head,
                                 cycle:1,attempt:1,exit_code:16}]' \
    "$fc_transient" >"${fixtures}/integrator-result-fc-transient-16.json"
node "$validator" envelope "${fixtures}/integrator-result-fc-transient-16.json" >/dev/null ||
    fail "the finder-transient fixture must itself be schema-valid"
run_gate_recheck_clean \
    --integrator-result "${fixtures}/integrator-result-fc-transient-16.json" \
    --integration-cap 1
assert_gate 2 indeterminate finder-transient-read

echo "==> review-r1-codex-verification-4: a codex_cycle exit-14 is a recognized terminal, not the catch-all"
# 14 is documented at every other layer; here it fell into `*)` and was
# reported as an unrecognized value.
write_defaults
result="$(write_integrator_result exit-14 "$(codex_cycle_json 14)")"
run_gate --integrator-result "$result" --integration-cap 1
assert_gate 1 fail codex-pr-not-open
printf '%s\n' "$gate_out" | tail -n 1 | jq -e '.detail | test("no longer open")' >/dev/null ||
    fail "the exit-14 condition must name the closed PR: $gate_out"

echo "==> 4067133481: a live recheck that comes back quota-exhausted is a blocker, not staleness"
# 16 had its own handling on this path and 15 did not, so a recheck that came
# back quota-exhausted fell into the generic `codex-stale` arm -- which
# prescribes dispatching a fresh integrator pass, the one remedy exit 15 rules
# out. The cached path has emitted `codex-quota-exhausted` since #573; this
# path had the same obligation and not the same code.
write_defaults
quota_recheck="$(write_integrator_result clean "$(codex_cycle_json 0)")"
saved_gate="$gate"
gate="$recheck_gate"
export RECHECK_FAKE_EXITS="15"
run_gate --codex-recheck "$recheck_state" \
    --integrator-result "$quota_recheck" --integration-cap 1
unset RECHECK_FAKE_EXITS
gate="$saved_gate"
assert_gate 1 fail codex-quota-exhausted
printf '%s\n' "$gate_out" | tail -n 1 | jq -e '.detail | test("usage limit is exhausted")' >/dev/null ||
    fail "the recheck quota condition must name the exhausted limit: $gate_out"
printf '%s\n' "$gate_out" | tail -n 1 | jq -e '.detail | test("1115")' >/dev/null ||
    fail "the recheck quota condition must name the recovery route: $gate_out"

echo "==> review-r1/r2-codex-verification-3: the recheck retry waits the CONFIGURED delay"
# The retry used to re-invoke with no delay at all, so both reads landed within
# microseconds and a transient failure could not have cleared between them.
#
# Review round 2 (`review-r2-codex-verification-3`): the first version of this
# case asserted `delay_elapsed -ge 1` over the whole gate run, which the gate
# saturates on its own — replacing the sleep with a no-op passed it, so the
# case pinned nothing it named. The delay is observed through the PATH `sleep`
# stub now, and the configured value is deliberately 7 rather than 1: a mutant
# that drops the sleep records nothing, and one that hardcodes some other
# delay records the wrong number. Neither can pass.
write_defaults
clean_delay="$(write_integrator_result clean "$(codex_cycle_json 0)")"
saved_gate="$gate"
gate="$recheck_gate"
export RECHECK_FAKE_EXITS="16 0"
export RECHECK_CALL_COUNTER="${test_tmp}/recheck-delay-calls"
export CODEX_RECHECK_RETRY_DELAY=7
export SLEEP_CALL_LOG="${test_tmp}/recheck-delay-sleeps"
rm -f "$RECHECK_CALL_COUNTER" "$SLEEP_CALL_LOG"
run_gate --codex-recheck "$recheck_state" \
    --integrator-result "$clean_delay" --integration-cap 1
unset RECHECK_FAKE_EXITS RECHECK_CALL_COUNTER CODEX_RECHECK_RETRY_DELAY SLEEP_CALL_LOG
gate="$saved_gate"
assert_gate 0 pass ready
[ "$(cat "${test_tmp}/recheck-delay-calls")" = "2" ] ||
    fail "the retry must still fire exactly once"
[ -s "${test_tmp}/recheck-delay-sleeps" ] ||
    fail "the retry must sleep before re-reading, but no sleep was requested"
[ "$(cat "${test_tmp}/recheck-delay-sleeps")" = "7" ] ||
    fail "the retry must sleep the configured delay, asked for: $(cat "${test_tmp}/recheck-delay-sleeps")"

echo "==> item C: a finder_cycles quota exit uses the finder-prefixed condition token"
write_defaults
fc_quota="$(write_integrator_result fc-quota "$(codex_cycle_json 0)")"
# A clean verdict requires every finder cycle to be terminal-clean, so the
# fixture carries `findings` instead — exit_code 0 permits it, and condition 8b
# (finder cycles) is evaluated before 9a (the pass's own findings[]), so the
# finder arm is what this case reaches.
jq '.payload.verdict = "escalate"
    | .payload.findings = [{id:"integration-r1-coderabbit-cloud-1",
                            body:"a finder finding",source_id:"1"}]
    | del(.payload.applied_dispositions)
    | .payload.finder_cycles = [{finder:"coderabbit-cloud",head:.head,
                                 cycle:1,attempt:1,exit_code:15}]' \
    "$fc_quota" >"${fixtures}/integrator-result-fc-quota-15.json"
node "$validator" envelope "${fixtures}/integrator-result-fc-quota-15.json" >/dev/null ||
    fail "the finder-quota fixture must itself be schema-valid"
run_gate_recheck_clean \
    --integrator-result "${fixtures}/integrator-result-fc-quota-15.json" \
    --integration-cap 1
assert_gate 1 fail finder-quota-exhausted

# --------------------------------------------------------------------------
# Review round 2, finding `review-r2-codex-verification-4` (confirmed P2,
# disposition RESTRUCTURE): one `exit_condition` mapping now serves both the
# codex_cycle and finder_cycles surfaces, so the suite owes a case per code
# per surface. The codex surface already has one for every code (0 through the
# recheck cases, 2, 10-13, 14, 15, 16); these complete the finder side, whose
# 14 and catch-all arms did not exist before this round.
# --------------------------------------------------------------------------
write_finder_cycle_result() {
    wfc_label=$1
    wfc_exit=$2
    # A DISTINCT base name: the finished fixture is
    # integrator-result-fc-<label>.json, so building it from a base of the
    # same name would let the shell truncate the output before jq read it.
    wfc_base="$(write_integrator_result "fc-${wfc_label}-base" "$(codex_cycle_json 0)")"
    # A clean verdict requires every finder cycle to be terminal-clean, so the
    # fixture carries `findings` instead — exit_code 0 permits it, and
    # condition 8b (finder cycles) is evaluated before 9a (the pass's own
    # findings[]), so the finder arm is what these cases reach. `accepted` is
    # schema-required for exit 0 and 10 and forbidden nowhere else, so it is
    # attached only for those two.
    # The verdict must be the one the cycle's exit code demands: the envelope
    # validator aggregates EXIT_CODE_VERDICT_CONSTRAINTS over codex_cycle AND
    # every finder_cycles entry now (harmon-devkit#1050 integration cycle 1),
    # so a finder at 16 makes the pass `pending` and a finder at 15 makes it
    # `escalate` however clean the Codex cycle is.
    jq --argjson ec "$wfc_exit" \
        '(if $ec == 11 or $ec == 12 or $ec == 16 then "pending"
          elif $ec == 13 or $ec == 14 or $ec == 15 or $ec == 2 then "escalate"
          else "findings" end) as $verdict
         | .payload.verdict = $verdict
         | .payload.findings = [{id:"integration-r1-coderabbit-cloud-1",
                                 body:"a finder finding",source_id:"1"}]
         | del(.payload.applied_dispositions)
         | .payload.finder_cycles =
             [({finder:"coderabbit-cloud",head:.head,
                cycle:1,attempt:1,exit_code:$ec}
               + (if ($ec == 0 or $ec == 10) then
                    {accepted:{surface:"comment",id:"1",
                               reviewed_commit:.head}}
                  else {} end))]' \
        "$wfc_base" >"${fixtures}/integrator-result-fc-${wfc_label}.json"
    node "$validator" envelope "${fixtures}/integrator-result-fc-${wfc_label}.json" >/dev/null ||
        fail "the fc-${wfc_label} fixture must itself be schema-valid: $(node "$validator" envelope "${fixtures}/integrator-result-fc-${wfc_label}.json" 2>&1 | tail -5)"
    printf '%s\n' "${fixtures}/integrator-result-fc-${wfc_label}.json"
}

echo "==> review-r2-codex-verification-4: a finder_cycles exit 10/11/12/13 is finder-not-clean"
for fc_code in 10 11 12 13; do
    write_defaults
    fc_result="$(write_finder_cycle_result "notclean-${fc_code}" "$fc_code")"
    run_gate_recheck_clean --integrator-result "$fc_result" --integration-cap 1
    assert_gate 1 fail finder-not-clean
done

echo "==> review-r2-codex-verification-4: a finder_cycles exit-14 is a recognized terminal, not the catch-all"
# The defect this round found: 14 is in the finder_cycles exit_code enum, whose
# schema description reads "Same contract as codex_cycle.exit_code above", yet
# the finder arm reported it as an unrecognized value under a codex-prefixed
# condition — prescribing a re-poll of a PR GitHub had already answered was
# closed, while the codex arm correctly ended the stage.
write_defaults
fc_closed="$(write_finder_cycle_result closed-14 14)"
run_gate_recheck_clean --integrator-result "$fc_closed" --integration-cap 1
assert_gate 1 fail finder-pr-not-open
printf '%s\n' "$gate_out" | tail -n 1 | jq -e '.detail | test("no longer open")' >/dev/null ||
    fail "the finder exit-14 condition must name the closed PR: $gate_out"
printf '%s\n' "$gate_out" | tail -n 1 | jq -e '.detail | test("coderabbit-cloud")' >/dev/null ||
    fail "the finder condition must name which finder answered: $gate_out"

echo "==> review-r2/r3-codex-verification-4: a finder exit 2 is its own arm, not the catch-all"
# Round 2 gave this case the title "an unrecognized finder exit_code" and drove
# exit_code 2, which enshrined the one documented code the gate mis-described
# as though being unrecognized were correct for it
# (`review-r3-codex-verification-4`). 2 has its own arm now, and the assertion
# below is on the DETAIL as well as the token: the token was already right, the
# sentence the operator reads was not.
#
# The catch-all itself has no case, deliberately and on evidence: the gate
# validates the integrator envelope before reading it, so an exit_code outside
# the schema enum is rejected as `codex-indeterminate` ("is not a schema-valid
# result.envelope") and never reaches `exit_condition` at all. An attempt to
# drive it proved exactly that. It stays as defence against a future caller
# that skips validation -- deleting it would let an unexpected value fall out
# of the `case` with no condition at all -- and the enum sweep below is what
# guarantees no DOCUMENTED code lands there.
write_defaults
fc_indet="$(write_finder_cycle_result indeterminate-2 2)"
run_gate_recheck_clean --integrator-result "$fc_indet" --integration-cap 1
assert_gate 2 indeterminate finder-indeterminate
printf '%s\n' "$gate_out" | tail -n 1 | jq -e '.detail | test("could not determine a verdict")' >/dev/null ||
    fail "a documented exit 2 must name the undetermined verdict, not call itself unrecognized: $gate_out"
printf '%s\n' "$gate_out" | tail -n 1 | jq -e '.detail | test("not a recognized") | not' >/dev/null ||
    fail "exit 2 is documented and must not be reported unrecognized: $gate_out"

echo "==> review-r3-codex-verification-5: the sleep stub refuses to skip a delay it cannot honour"
# Round 2 added this stub with `|| exit 0`, which silently removed the delay
# whenever no real sleep was found -- precisely what its own comment promised
# could never happen, and suite-wide rather than for one case. The branch is
# unreachable through the gate (every case that reaches the stub sets
# SLEEP_CALL_LOG, and every supported image has coreutils sleep), so it is
# exercised directly against the stub. That is the whole point: the shipped
# `|| exit 0` had no case at all.
stub_rc=0
(
    unset SLEEP_CALL_LOG
    SLEEP_REAL_PATH=/nonexistent bash "${bin_dir}/sleep" 1
) >/dev/null 2>&1 || stub_rc=$?
[ "$stub_rc" -eq 1 ] ||
    fail "a harness that cannot honour a delay must fail loudly, got rc $stub_rc"
stub_msg="$(
    (
        unset SLEEP_CALL_LOG
        SLEEP_REAL_PATH=/nonexistent bash "${bin_dir}/sleep" 1
    ) 2>&1 || true
)"
case "$stub_msg" in
*"refusing to skip a delay"*) ;;
*) fail "the refusal must name what it refused: $stub_msg" ;;
esac
# And where a real sleep exists it still delegates rather than no-oping.
(
    unset SLEEP_CALL_LOG
    bash "${bin_dir}/sleep" 0
) || fail "the stub must delegate to the real sleep when it can find one"

echo "==> review-r3-codex-verification-4: every schema exit code has its own arm, on BOTH surfaces"
# THE ASSERTION THAT ENDS THE ONE-MEMBER-PER-ROUND PATTERN. Three consecutive
# review rounds each closed a single member of this enum by hand: r1 gave 14
# an arm on the codex surface, r2 keyed the mapping by surface so 14 was right
# on both, r3 found 2 still in the catch-all. Round 2's claim that adding a
# code is now one arm in one place is only true if something checks that every
# code was actually added -- so this reads the enum out of the schema and
# drives every member through both surfaces, asserting none of them is
# described as unrecognized and each carries its own surface prefix.
#
# 0 is excluded deliberately: it is the one code `exit_condition` does not
# own, because its meaning IS surface-specific (the Codex cycle re-checks its
# cached clean result, a finder cycle is simply terminal-clean), so it stays
# at each call site and has its own cases elsewhere in this suite.
# Every `exit_code` enum anywhere in the integrator schema, unioned: the
# codex_cycle field and the finder_cycles mirror declare the same contract, so
# a code documented on either must have an arm.
enum_codes="$(jq -r '
  .. | objects | select(has("exit_code")) | .exit_code.enum? // empty
  | .[] | tostring' "${repo_root}/ai/schemas/result.integrator.schema.json" |
    sort -u | grep -v '^0$' | tr '\n' ' ')"
[ -n "$enum_codes" ] ||
    fail "could not read the exit-code enum out of result.integrator.schema.json"
echo "    enum members under test: $enum_codes"
for enum_code in $enum_codes; do
    # codex surface
    write_defaults
    enum_result="$(write_integrator_result "enum-codex-${enum_code}" "$(codex_cycle_json "$enum_code")")"
    run_gate --integrator-result "$enum_result" --integration-cap 1
    enum_line="$(printf '%s\n' "$gate_out" | tail -n 1)"
    printf '%s\n' "$enum_line" | jq -e '.detail | test("not a recognized") | not' >/dev/null ||
        fail "codex exit_code $enum_code is documented but reported unrecognized: $enum_line"
    printf '%s\n' "$enum_line" | jq -e '.condition | startswith("codex-")' >/dev/null ||
        fail "codex exit_code $enum_code must carry a codex-prefixed condition: $enum_line"
    # finder surface
    write_defaults
    enum_fc="$(write_finder_cycle_result "enum-finder-${enum_code}" "$enum_code")"
    run_gate_recheck_clean --integrator-result "$enum_fc" --integration-cap 1
    enum_line="$(printf '%s\n' "$gate_out" | tail -n 1)"
    printf '%s\n' "$enum_line" | jq -e '.detail | test("not a recognized") | not' >/dev/null ||
        fail "finder exit_code $enum_code is documented but reported unrecognized: $enum_line"
    printf '%s\n' "$enum_line" | jq -e '.condition | startswith("finder-")' >/dev/null ||
        fail "finder exit_code $enum_code must carry a finder-prefixed condition: $enum_line"
done

echo "==> harmon-devkit#675: a BADGED bot follow-up still blocks"
write_defaults
self_fix_thread "### Summary

**P1** the write boundary still has no executable path.

* Committed the change on \`codex/name-review-trigger-broker\` as \`77379cf\`."
run_gate
assert_gate 1 fail threads-new-follow-up

echo "==> harmon-devkit#675: an ordinary unbadged bot follow-up with no self-report shape still blocks"
write_defaults
self_fix_thread "Have you considered handling the empty case here as well?"
run_gate
assert_gate 1 fail threads-new-follow-up

echo "==> harmon-devkit#675: a self-report from a NON-bot actor still blocks"
# The exemption is pinned to the trusted actor id, not to the body shape
# alone: anyone can write "### Summary" in a review comment.
write_defaults
jq -cn '[[
    {id:900,user:{login:"reviewer-bot",id:4242},path:"f.sh",in_reply_to_id:null,
     created_at:"2026-08-01T00:00:00Z",updated_at:"2026-08-01T00:00:00Z",
     body:"finding"},
    {id:901,user:{login:"pr-author"},path:"f.sh",in_reply_to_id:900,
     created_at:"2026-08-01T01:00:00Z",updated_at:"2026-08-01T01:00:00Z",
     body:"fixed in abc"},
    {id:902,user:{login:"human-reviewer",id:7777},path:"f.sh",in_reply_to_id:900,
     created_at:"2026-08-01T02:00:00Z",updated_at:"2026-08-01T02:00:00Z",
     body:"### Summary\n\nCommitted the change on `wip` as `abcdef1`."}]]' \
    >"${fixtures}/inline.pages.json"
run_gate
assert_gate 1 fail threads-new-follow-up

echo "==> harmon-devkit#675: an unanswered thread whose ONLY comment is a bot self-report still blocks"
# The exemption is scoped to the follow-up state; a thread with no reply from
# you at all is still unanswered, whoever wrote it.
write_defaults
jq -cn '[[
    {id:905,user:{login:"chatgpt-codex-connector[bot]",id:199175422},
     path:"f.sh",in_reply_to_id:null,
     created_at:"2026-08-01T00:00:00Z",updated_at:"2026-08-01T00:00:00Z",
     body:"### Summary\n\nCommitted the change on `wip` as `abcdef1`."}]]' \
    >"${fixtures}/inline.pages.json"
run_gate
assert_gate 1 fail threads-unanswered

edited_thread() {
    jq -cn '[[
        {id:900,user:{login:"reviewer-bot"},path:"f.sh",in_reply_to_id:null,
         created_at:"2026-08-01T00:00:00Z",updated_at:"2026-08-01T02:00:00Z",
         body:"finding, reworded"},
        {id:901,user:{login:"pr-author"},path:"f.sh",in_reply_to_id:900,
         created_at:"2026-08-01T01:00:00Z",updated_at:"2026-08-01T01:00:00Z",
         body:"fixed in abc"}]]' >"${fixtures}/inline.pages.json"
}

echo "==> an edit after the reply fails distinctly as threads-edited-since-reply"
write_defaults
edited_thread
run_gate
assert_gate 1 fail threads-edited-since-reply

echo "==> --allow-edited-root clears exactly that edited root"
write_defaults
edited_thread
run_gate --allow-edited-root 900
assert_gate 0 pass ready

echo "==> --allow-edited-root never clears an unanswered thread"
write_defaults
jq -cn '[[{id:900,user:{login:"reviewer-bot"},path:"f.sh",in_reply_to_id:null,
           created_at:"2026-08-01T00:00:00Z",updated_at:"2026-08-01T00:00:00Z",
           body:"finding"}]]' >"${fixtures}/inline.pages.json"
run_gate --allow-edited-root 900
assert_gate 1 fail threads-unanswered

echo "==> a failed identity lookup is indeterminate, never answered"
write_defaults
printf 'user' >"${fixtures}/fail-endpoint"
run_gate
assert_gate 2 indeterminate fetch-failed

echo "==> a failed inline-comment fetch is indeterminate, never a pass"
write_defaults
printf 'pulls/493/comments' >"${fixtures}/fail-endpoint"
run_gate
assert_gate 2 indeterminate fetch-failed

echo "==> a failed fingerprint-surface fetch (reviews) is indeterminate"
write_defaults
printf 'pulls/493/reviews' >"${fixtures}/fail-endpoint"
run_gate
assert_gate 2 indeterminate fetch-failed

echo "==> a failed thread-resolution fetch (graphql) is indeterminate"
write_defaults
printf 'graphql' >"${fixtures}/fail-endpoint"
run_gate
assert_gate 2 indeterminate fetch-failed

echo "==> a head that moves mid-gate fails as head-moved on the final re-read"
write_defaults
jq -cn --arg head "$moved_sha" \
    '{state:"OPEN",isDraft:true,headRefOid:$head,
      reviewDecision:"REVIEW_REQUIRED",mergeStateStatus:"BLOCKED",baseRefName:"main",baseRefOid:"b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0"}' \
    >"${fixtures}/pr-view-second.json"
run_gate
assert_gate 1 fail head-moved

echo "==> a promotion mid-gate fails as pr-not-draft on the final re-read"
write_defaults
jq -cn --arg head "$head_sha" \
    '{state:"OPEN",isDraft:false,headRefOid:$head,
      reviewDecision:"REVIEW_REQUIRED",mergeStateStatus:"BLOCKED",baseRefName:"main",baseRefOid:"b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0"}' \
    >"${fixtures}/pr-view-second.json"
run_gate
assert_gate 1 fail pr-not-draft

echo "==> an integrator result reporting Codex findings/pending/retry/escalate all fail as codex-not-clean"
for exit_code in 10 11 12 13; do
    write_defaults
    result="$(write_integrator_result "exit-${exit_code}" "$(codex_cycle_json "$exit_code")")"
    run_gate --integrator-result "$result" --integration-cap 1
    assert_gate 1 fail codex-not-clean
done

echo "==> a codex_cycle exit_code of 2 (indeterminate) is codex-indeterminate"
write_defaults
result="$(write_integrator_result exit-2 "$(codex_cycle_json 2)")"
run_gate --integrator-result "$result" --integration-cap 1
assert_gate 2 indeterminate codex-indeterminate

echo "==> harmon-devkit#508: exit 16 is codex-transient-read, never codex-not-clean"
# The original defect: the helper mapped a transient evidence-read failure to
# exit 12, which the gate rendered as `codex-not-clean` — a hard fail asserting
# a review problem that did not exist, with blind re-runs as the only remedy.
# A failed read is unknown WITH THE REASON, so the caller repeats the read.
write_defaults
result="$(write_integrator_result exit-16 "$(codex_cycle_json 16)")"
run_gate --integrator-result "$result" --integration-cap 1
assert_gate 2 indeterminate codex-transient-read
printf '%s\n' "$gate_out" | tail -n 1 | jq -e '.detail | test("evidence read failed")' >/dev/null ||
    fail "the transient-read condition must name the failed read: $gate_out"

echo "==> harmon-devkit#573: exit 15 is codex-quota-exhausted, a named blocker rather than an unknown"
write_defaults
result="$(write_integrator_result exit-15 "$(codex_cycle_json 15)")"
run_gate --integrator-result "$result" --integration-cap 1
assert_gate 1 fail codex-quota-exhausted
printf '%s\n' "$gate_out" | tail -n 1 | jq -e '.detail | test("usage limit is exhausted")' >/dev/null ||
    fail "the quota condition must name the exhausted limit: $gate_out"

echo "==> harmon-devkit#508: a cached clean cycle whose recheck cannot read twice is codex-transient-read"
# The gate re-invokes the checker to reconfirm a cached clean result. A read
# failure there is retried ONCE; only a second failure is reported, and it is
# reported as a read problem rather than as staleness — those are different
# things to the operator, and only one of them means the clean result is gone.
write_defaults
clean_recheck="$(write_integrator_result clean "$(codex_cycle_json 0)")"
saved_gate="$gate"
gate="$recheck_gate"
export RECHECK_FAKE_EXIT=16
run_gate --codex-recheck "$recheck_state" \
    --integrator-result "$clean_recheck" --integration-cap 1
unset RECHECK_FAKE_EXIT
gate="$saved_gate"
assert_gate 2 indeterminate codex-transient-read
printf '%s\n' "$gate_out" | tail -n 1 | jq -e '.detail | test("one retry")' >/dev/null ||
    fail "the recheck must report that it retried the read once: $gate_out"

echo "==> challenge-r3-codex-adversarial-13: a transient recheck read that succeeds on the RETRY passes"
# The case the constant-exit stub could not express: 16 first, clean second.
# Deleting the retry from readiness-gate.sh makes exactly this case fail.
write_defaults
clean_retry="$(write_integrator_result clean "$(codex_cycle_json 0)")"
saved_gate="$gate"
gate="$recheck_gate"
export RECHECK_FAKE_EXITS="16 0"
export RECHECK_CALL_COUNTER="${test_tmp}/recheck-calls"
rm -f "$RECHECK_CALL_COUNTER"
run_gate --codex-recheck "$recheck_state" \
    --integrator-result "$clean_retry" --integration-cap 1
unset RECHECK_FAKE_EXITS RECHECK_CALL_COUNTER
gate="$saved_gate"
assert_gate 0 pass ready
[ "$(cat "${test_tmp}/recheck-calls")" = "2" ] ||
    fail "the recheck must have been retried exactly once, saw $(cat "${test_tmp}/recheck-calls") call(s)"

echo "==> challenge-r3-codex-adversarial-13: the retry is bounded at ONE — a third read is never made"
write_defaults
saved_gate="$gate"
gate="$recheck_gate"
export RECHECK_FAKE_EXITS="16 16 0"
export RECHECK_CALL_COUNTER="${test_tmp}/recheck-calls"
rm -f "$RECHECK_CALL_COUNTER"
run_gate --codex-recheck "$recheck_state" \
    --integrator-result "$clean_retry" --integration-cap 1
unset RECHECK_FAKE_EXITS RECHECK_CALL_COUNTER
gate="$saved_gate"
assert_gate 2 indeterminate codex-transient-read
[ "$(cat "${test_tmp}/recheck-calls")" = "2" ] ||
    fail "the retry must be bounded at one, saw $(cat "${test_tmp}/recheck-calls") call(s)"

echo "==> harmon-devkit#508: a recheck that genuinely no longer confirms the clean result is still codex-stale"
# The inverse guard: the retry above must not swallow a real staleness signal.
write_defaults
saved_gate="$gate"
gate="$recheck_gate"
export RECHECK_FAKE_EXIT=10
run_gate --codex-recheck "$recheck_state" \
    --integrator-result "$clean_recheck" --integration-cap 1
unset RECHECK_FAKE_EXIT
gate="$saved_gate"
assert_gate 2 indeterminate codex-stale

echo "==> a missing --integrator-result file is refused as a usage error, never a pass"
write_defaults
set +e
missing_out="$("$gate" check --repo example/repo --pr 493 --head "$head_sha" \
    --record "$record_dir" \
    --integrator-result "${fixtures}/no-such-result.json" 2>&1)"
missing_rc=$?
set -e
[ "$missing_rc" -eq 2 ] ||
    fail "a missing --integrator-result file should exit 2, got $missing_rc: $missing_out"
grep -Fq 'integrator-result' <<<"$missing_out" ||
    fail "the missing-integrator-result error does not name the flag: $missing_out"

echo "==> an integrator result naming a different head is refused before the Codex condition is read"
write_defaults
result="$(write_integrator_result other-head null "$moved_sha")"
run_gate --integrator-result "$result"
assert_gate 2 indeterminate codex-indeterminate

echo "==> an integrator result whose role is not integrator is refused"
write_defaults
non_integrator_result="${fixtures}/integrator-result-wrong-role.json"
jq -cn --arg head "$head_sha" \
    '{schema:2, role:"reviewer", status:"completed", head:$head,
      produced_at:"2026-01-01T00:00:00Z",
      producer:{harness:"claude-code",model:"test",tier:"economy"},
      run:{run_id:"test-run",initiated_by:"human"},
      payload:{stage:"review",reviewed_head:$head,findings:[],
               verdict:"clean"}}' >"$non_integrator_result"
run_gate --integrator-result "$non_integrator_result"
assert_gate 2 indeterminate codex-indeterminate

echo "==> an --integrator-result that fails schema validation is refused"
write_defaults
malformed_result="${fixtures}/integrator-result-malformed.json"
printf '%s\n' '{"not":"a valid envelope"}' >"$malformed_result"
run_gate --integrator-result "$malformed_result"
assert_gate 2 indeterminate codex-indeterminate

echo "==> an integrator result from a different run (same head) is refused — the run-identity invariant"
write_defaults
stale_run_result="$(write_integrator_result stale-run null)"
# write_integrator_result always stamps run:{run_id:"test-run",
# initiated_by:"human"}, matching write_default_record's own run.json — this
# is the one fixture in the suite that deliberately makes them disagree,
# simulating a superseded/resumed run's evidence surviving on disk with the
# SAME head as the active run (specs/dev-flow-v2.md:177-185).
jq -c '.run.run_id = "a-different-run"' "$stale_run_result" >"${stale_run_result}.tmp"
mv "${stale_run_result}.tmp" "$stale_run_result"
run_gate --integrator-result "$stale_run_result"
assert_gate 2 indeterminate codex-indeterminate

# ── harmon-devkit#685 criteria owned by #639 ────────────────────────────────
# codex_cycle.cycle <= [rounds.<policy>].integration; cap 0 <=> null cycle; a
# clean verdict with a null cycle under a positive cap is not clean.
# --integration-cap is required context the caller supplies (this script
# never reads .devflow.toml itself) — see the dedicated "never skippable by
# silence" case above for the omitted-flag usage error; every case below
# passes it explicitly.

echo "==> a non-null codex_cycle against --integration-cap 0 is codex-cap-mismatch"
write_defaults
clean_result="$(write_integrator_result cap-zero-nonnull "$(codex_cycle_json 0)")"
run_gate --integrator-result "$clean_result" --integration-cap 0
assert_gate 2 indeterminate codex-cap-mismatch

echo "==> a null codex_cycle against a positive --integration-cap is codex-cap-mismatch"
write_defaults
run_gate --integration-cap 3
assert_gate 2 indeterminate codex-cap-mismatch

echo "==> a null codex_cycle against --integration-cap 0 passes (the waived case)"
write_defaults
run_gate --integration-cap 0
assert_gate 0 pass ready

echo "==> codex_cycle.cycle within --integration-cap passes"
write_defaults
cycle_two="$(jq -c '.cycle = 2' <<<"$(codex_cycle_json 0)")"
clean_result="$(write_integrator_result cap-cycle-ok "$cycle_two")"
run_gate_recheck_clean --integrator-result "$clean_result" --integration-cap 2
assert_gate 0 pass ready

echo "==> codex_cycle.cycle exceeding --integration-cap is codex-cap-mismatch"
write_defaults
cycle_three="$(jq -c '.cycle = 3' <<<"$(codex_cycle_json 0)")"
clean_result="$(write_integrator_result cap-cycle-exceeded "$cycle_three")"
run_gate --integrator-result "$clean_result" --integration-cap 2
assert_gate 2 indeterminate codex-cap-mismatch

# harmon-init#1326: base-merge-only cycles are exempt from the integration
# cap and spend a separate ceiling instead. A producer declares that it
# classified its cycles by reporting `charged`/`exempt`; one that does not is
# treated exactly as before, which is what keeps an older pinned skill working
# rather than silently granting it an exemption it never computed.

echo "==> a total cycle count above the cap passes when the excess is exempt"
write_defaults
# 3 cycles run, only 2 charged: the third was a base merge that changed
# nothing under review. Under the OLD single-counter rule this was a
# cap-mismatch — that is the whole bug #1326 fixes.
split_ok="$(jq -c '.cycle = 3 | .charged = 2 | .exempt = 1' <<<"$(codex_cycle_json 0)")"
clean_result="$(write_integrator_result cap-split-ok "$split_ok")"
# A claimed split owes durable proof, so the checker state carries the same
# counters a real run would have written — the result agreeing with itself is
# not evidence.
jq '.charged_cycles = 2 | .exempt_cycles = 1' "$recheck_state" >"${recheck_state}.next"
mv "${recheck_state}.next" "$recheck_state"
run_gate_recheck_clean --integrator-result "$clean_result" \
    --integration-cap 2 --integration-exempt-cap 2
assert_gate 0 pass ready

echo "==> a claimed split with no durable counters is codex-cap-mismatch"
# The result agreeing with itself is not evidence. A producer old enough to
# have written counter-less state also omits the split entirely and takes the
# legacy branch, so a split arriving with no state counters is an assertion
# with nothing behind it — and accepting it would let spend be moved from the
# charged column into the exempt one to satisfy both ceilings.
write_defaults
# The preceding case wrote counters into the shared recheck state; this case is
# about their ABSENCE, so strip them rather than inherit them.
jq 'del(.charged_cycles) | del(.exempt_cycles)' "$recheck_state" >"${recheck_state}.next"
mv "${recheck_state}.next" "$recheck_state"
split_unproven="$(jq -c '.cycle = 3 | .charged = 2 | .exempt = 1' <<<"$(codex_cycle_json 0)")"
clean_result="$(write_integrator_result cap-split-unproven "$split_unproven")"
run_gate_recheck_clean --integrator-result "$clean_result" \
    --integration-cap 2 --integration-exempt-cap 2
assert_gate 2 indeterminate codex-cap-mismatch

echo "==> charged cycles exceeding --integration-cap is still codex-cap-mismatch"
write_defaults
# The exemption must not launder a genuine overspend: 3 CHARGED against a cap
# of 2 is over the cap no matter how many exempt cycles sit beside it.
split_over="$(jq -c '.cycle = 4 | .charged = 3 | .exempt = 1' <<<"$(codex_cycle_json 0)")"
clean_result="$(write_integrator_result cap-split-over "$split_over")"
run_gate --integrator-result "$clean_result" \
    --integration-cap 2 --integration-exempt-cap 2
assert_gate 2 indeterminate codex-cap-mismatch

echo "==> exempt cycles exceeding --integration-exempt-cap is codex-cap-mismatch"
write_defaults
# Exempt is not free: a busy base branch must not be able to spend a whole run
# on re-reviews of code nobody changed.
exempt_over="$(jq -c '.cycle = 4 | .charged = 1 | .exempt = 3' <<<"$(codex_cycle_json 0)")"
clean_result="$(write_integrator_result cap-exempt-over "$exempt_over")"
run_gate --integrator-result "$clean_result" \
    --integration-cap 2 --integration-exempt-cap 2
assert_gate 2 indeterminate codex-cap-mismatch

echo "==> exempt cycles with no declared exempt ceiling is codex-cap-mismatch"
write_defaults
# An undeclared ceiling is nothing to check against, so a pass claiming exempt
# cycles under a caller that never declared one is refused, not trusted.
exempt_undeclared="$(jq -c '.cycle = 2 | .charged = 1 | .exempt = 1' <<<"$(codex_cycle_json 0)")"
clean_result="$(write_integrator_result cap-exempt-undeclared "$exempt_undeclared")"
run_gate --integrator-result "$clean_result" --integration-cap 2
assert_gate 2 indeterminate codex-cap-mismatch

echo "==> exempt without charged is malformed-data"
# The mirror of the case below. This direction is the dangerous one: without
# the check, `exempt` alone falls through to the legacy single-counter branch
# and is silently ignored, hiding spend rather than reporting it.
write_defaults
lone_exempt="$(jq -c '.cycle = 2 | .exempt = 1' <<<"$(codex_cycle_json 0)")"
clean_result="$(write_integrator_result cap-lone-exempt "$lone_exempt")"
run_gate --integrator-result "$clean_result" \
    --integration-cap 2 --integration-exempt-cap 2
assert_gate 2 indeterminate malformed-data

echo "==> charged without exempt is malformed-data"
write_defaults
half_split="$(jq -c '.cycle = 2 | .charged = 2' <<<"$(codex_cycle_json 0)")"
clean_result="$(write_integrator_result cap-half-split "$half_split")"
run_gate --integrator-result "$clean_result" \
    --integration-cap 2 --integration-exempt-cap 2
assert_gate 2 indeterminate malformed-data

echo "==> charged + exempt disagreeing with cycle is malformed-data"
write_defaults
# The three numbers are one statement about the same run; a producer whose
# arithmetic does not close is not one whose counters can be trusted.
bad_sum="$(jq -c '.cycle = 5 | .charged = 2 | .exempt = 1' <<<"$(codex_cycle_json 0)")"
clean_result="$(write_integrator_result cap-bad-sum "$bad_sum")"
run_gate --integrator-result "$clean_result" \
    --integration-cap 3 --integration-exempt-cap 3
assert_gate 2 indeterminate malformed-data

# --codex-recheck (harmon-devkit#639 gauntlet challenge round 1, finding 3):
# a cached codex_cycle.exit_code 0 can go stale between the dispatched
# integrator pass and this gate, so a clean exit_code 0 reconfirms itself
# against live state rather than being trusted unconditionally. All four
# cases below are cap-agnostic — no --integration-cap involved — since the
# recheck applies whenever codex_cycle reports exit_code 0, independent of
# whether a cap was given at all.

echo "==> a clean codex_cycle with no --codex-recheck is codex-stale"
write_defaults
recheck_missing_result="$(write_integrator_result recheck-missing "$(codex_cycle_json 0)")"
run_gate --integrator-result "$recheck_missing_result" --integration-cap 1
assert_gate 2 indeterminate codex-stale

echo "==> --codex-recheck naming a file that does not exist is codex-stale"
write_defaults
recheck_absent_result="$(write_integrator_result recheck-absent "$(codex_cycle_json 0)")"
run_gate --integrator-result "$recheck_absent_result" --integration-cap 1 \
    --codex-recheck "${fixtures}/does-not-exist.json"
assert_gate 2 indeterminate codex-stale

echo "==> --codex-recheck naming a state file for a different repo/pr/head is codex-stale"
write_defaults
recheck_mismatch_result="$(write_integrator_result recheck-mismatch "$(codex_cycle_json 0)")"
mismatched_state="${fixtures}/codex-recheck-state-mismatched.json"
jq -cn --arg repo other/repo --argjson pr 1 --arg head "$moved_sha" \
    '{repo:$repo, pr:$pr, head:$head}' >"$mismatched_state"
run_gate --integrator-result "$recheck_mismatch_result" --integration-cap 1 \
    --codex-recheck "$mismatched_state"
assert_gate 2 indeterminate codex-stale

echo "==> --codex-recheck against a real but not-yet-attached state is codex-stale (the real checker, exit 2)"
write_defaults
recheck_disagree_result="$(write_integrator_result recheck-disagrees "$(codex_cycle_json 0)")"
not_attached_state="${fixtures}/codex-recheck-state-not-attached.json"
jq -cn --arg repo example/repo --argjson pr 493 --arg head "$head_sha" \
    '{version:2, repo:$repo, pr:$pr, head:$head, attempt:1, phase:"reserved",
      settled:null, cycle_requested_at:null,
      previous_trigger_comment_id:null, timeout_min:15}' \
    >"$not_attached_state"
run_gate --integrator-result "$recheck_disagree_result" --integration-cap 1 \
    --codex-recheck "$not_attached_state"
assert_gate 2 indeterminate codex-stale
grep -Fq 'not attached' <<<"$gate_out" ||
    fail "codex-stale did not surface the real checker's own complaint: $gate_out"

# promotion.head equals the final integrator result's head AND its
# accepted-cycle reviewed commit; a stale pass cannot certify a newer head.
# The gate never gets a chance to check this itself: validate-result-
# schemas.mjs's own envelope receipt validation already rejects any envelope
# whose accepted.reviewed_commit disagrees with the envelope's own head
# (unconditionally, cap or no cap) — and the gate's separate envelope_head
# == --head check closes the remaining leg, so the two together are what
# make a stale reviewed_commit unable to certify a newer head. Prove the
# upstream half directly, since the gate can never observe a fixture that
# fails it (write_integrator_result's own validation step refuses first).
echo "==> a schema-valid envelope cannot carry a stale accepted.reviewed_commit"
stale_result="${fixtures}/integrator-result-stale-reviewed-commit.json"
jq -cn --arg head "$head_sha" '
  {schema:2, role:"integrator", status:"completed", head:$head,
   produced_at:"2026-01-01T00:00:00Z",
   producer:{harness:"claude-code",model:"test",tier:"economy"},
   run:{run_id:"test-run",initiated_by:"human"},
   payload:{checks:[{name:"build",bucket:"pass",run_id:"1",required:true}],
            codex_cycle:{head:$head, cycle:1, attempt:1,
              trigger_comment_id:"1",
              accepted:{surface:"review", id:"1",
                reviewed_commit:"3333333333333333333333333333333333333333"},
              exit_code:0},
            integration_round:1, findings:[], unanswered_thread_roots:[],
            settled_at:"2026-01-01T00:00:00Z", verdict:"clean",
            applied_dispositions:[]}}' >"$stale_result"
validator_out="$(node "$validator" envelope "$stale_result" 2>&1)" &&
    fail "a stale accepted.reviewed_commit should fail schema validation, got: $validator_out"
grep -Fq 'reviewed_commit' <<<"$validator_out" ||
    fail "the validator's rejection does not name reviewed_commit: $validator_out"

# Codex cloud-review cycle on PR harmon-devkit#758: a Codex-clean cycle
# (exit_code 0) alongside a separate, same-pass human/CI finding is the
# routine mixed-source case ai/agents/integrator.md §7 documents
# (verdict:"findings" even though the Codex cycle itself is clean) — the
# schema must not force verdict:"clean" whenever exit_code is 0, or this
# ordinary case could never produce a validatable envelope.
echo "==> a clean codex_cycle (exit_code 0) alongside verdict:findings is schema-valid"
mixed_source_result="${fixtures}/integrator-result-mixed-source.json"
jq -cn --arg head "$head_sha" '
  {schema:2, role:"integrator", status:"completed", head:$head,
   produced_at:"2026-01-01T00:00:00Z",
   producer:{harness:"claude-code",model:"test",tier:"economy"},
   run:{run_id:"test-run",initiated_by:"human"},
   payload:{checks:[{name:"build",bucket:"pass",run_id:"1",required:true}],
            codex_cycle:{head:$head, cycle:1, attempt:1,
              trigger_comment_id:"1",
              accepted:{surface:"review", id:"1", reviewed_commit:$head},
              exit_code:0},
            integration_round:1,
            findings:[{id:"integration-r1-human-1",
                       body:"a top-level finding needing adjudication",
                       source_id:"42"}],
            unanswered_thread_roots:[], settled_at:"2026-01-01T00:00:00Z",
            verdict:"findings"}}' >"$mixed_source_result"
node "$validator" envelope "$mixed_source_result" >/dev/null ||
    fail "a clean codex_cycle alongside verdict:findings should validate: $(node "$validator" envelope "$mixed_source_result" 2>&1)"

# 9b is scoped to DEFERRED findings only (review round 2 gauntlet challenge,
# harmon-devkit#639): a finding this same integration pass discovered fresh
# was never carried with disposition `defer` by any adjudication document, so
# render-dev-flow.mjs's own cross-document consistency would reject a
# settlement for one outright — requiring a settlement here would make such a
# finding impossible to ever pass this gate, resolved or not. Prove that
# first, before proving the deferred case below still requires one.
echo "==> applied_dispositions naming a FRESH (never-deferred) finding needs no settlement and passes"
write_defaults
# One remediation loop, because this pass applies `fix`: a code change during
# integration always records an integration -> implement -> integration
# re-entry (Codex cloud-review cycle 1 on PR #800), so a record claiming the
# fix with zero loops is internally inconsistent. This case is about
# settlement, not remediation, so give it the consistent record.
write_record_with_integration_entries 1
fresh_result="${fixtures}/integrator-result-fresh-disposition.json"
jq -cn --arg head "$head_sha" '
  {schema:2, role:"integrator", status:"completed", head:$head,
   produced_at:"2026-01-01T00:00:00Z",
   producer:{harness:"claude-code",model:"test",tier:"economy"},
   run:{run_id:"test-run",initiated_by:"human"},
   payload:{checks:[{name:"build",bucket:"pass",run_id:"1",required:true}],
            codex_cycle:null, integration_round:1, findings:[],
            unanswered_thread_roots:[], settled_at:"2026-01-01T00:00:00Z",
            verdict:"clean",
            applied_dispositions:[{finding_id:"integration-r1-human-1",
                                    disposition:"fix"}]}}' \
    >"$fresh_result"
node "$validator" envelope "$fresh_result" >/dev/null ||
    fail "fresh-disposition fixture failed schema validation"
# The record must hold the evidence for integration-r1-human-1, or the
# gate's known-ids universe (harmon-devkit#685, challenge round 2) has
# nothing to account for it — which is the separate thing the next case
# asserts. This case is about settlement, so give it the earlier integrator
# pass that surfaced the finding AND the adjudication that dispositioned it:
# render-dev-flow.mjs's own cross-document check rejects a pass whose
# finding no adjudication document covers, so a record carrying one without
# the other is not a record at all.
write_earlier_integration_finding() {
    jq -cn --arg head "$head_sha" '
      {schema:2, role:"integrator", status:"completed", head:$head,
       produced_at:"2026-01-01T00:00:00Z",
       producer:{harness:"claude-code",model:"test",tier:"economy"},
       run:{run_id:"test-run",initiated_by:"human"},
       payload:{checks:[{name:"build",bucket:"pass",run_id:"1",required:true}],
                codex_cycle:null, integration_round:1,
                findings:[{id:"integration-r1-human-1",
                           body:"a human review finding",source_id:"9100"}],
                unanswered_thread_roots:[], settled_at:"2026-01-01T00:00:00Z",
                verdict:"findings"}}' \
        >"${record_dir}/passes/integration-r1.json"
    jq -cn --arg head "$head_sha" '
      {schema:2, run_id:"test-run", stage:"integration", round:1,
       reviewed_head:$head,
       adjudications:[{finding_id:"integration-r1-human-1",
         reviewer_priority:null, adjudicated_priority:"P2",
         disposition:"fix", reason:"confirmed against the code",
         evidence:"reproduced locally", override:null}]}' \
        >"${record_dir}/adjudications/integration-r1.json"
}
write_earlier_integration_finding
run_gate --integrator-result "$fresh_result"
assert_gate 0 pass ready

echo "==> #685(10): an applied_disposition the record has no evidence for anywhere is refused"
write_defaults
run_gate --integrator-result "$fresh_result"
assert_gate 2 indeterminate codex-indeterminate
grep -Fq "known finding universe" <<<"$gate_out" ||
    fail "#685(10): the gate did not name the finding universe: $gate_out"

# A disposition claim alone, with no durable settlement behind it, cannot
# promote a genuinely deferred finding — check 6 (deferred-unsettled) already
# guards every deferred-and-unsettled finding regardless of what the current
# pass's applied_dispositions claims, so it fires here before 9b's own
# (narrower, settlement-existence-only) check ever gets a chance to.
echo "==> a DEFERRED finding claimed fixed in applied_dispositions still fails as deferred-unsettled without a settlement"
write_defaults
jq -cn --arg head "$head_sha" \
    '{schema:2, run_id:"test-run", stage:"review", round:1,
      reviewed_head:$head,
      adjudications:[{finding_id:"review-r1-codex-cli-9",
        reviewer_priority:"P2", adjudicated_priority:"P2",
        disposition:"defer", reason:"carrying to integration",
        evidence:"needs a second look", override:null}]}' \
    >"${record_dir}/adjudications/review-r1.json"
write_review_r1_pass
undisclosed_result="${fixtures}/integrator-result-undisclosed.json"
jq -cn --arg head "$head_sha" '
  {schema:2, role:"integrator", status:"completed", head:$head,
   produced_at:"2026-01-01T00:00:00Z",
   producer:{harness:"claude-code",model:"test",tier:"economy"},
   run:{run_id:"test-run",initiated_by:"human"},
   payload:{checks:[{name:"build",bucket:"pass",run_id:"1",required:true}],
            codex_cycle:null, integration_round:1, findings:[],
            unanswered_thread_roots:[], settled_at:"2026-01-01T00:00:00Z",
            verdict:"clean",
            applied_dispositions:[{finding_id:"review-r1-codex-cli-9",
                                    disposition:"fix"}]}}' \
    >"$undisclosed_result"
node "$validator" envelope "$undisclosed_result" >/dev/null ||
    fail "undisclosed-disposition fixture failed schema validation"
run_gate --integrator-result "$undisclosed_result"
assert_gate 1 fail deferred-unsettled
grep -Fq 'review-r1-codex-cli-9' <<<"$gate_out" ||
    fail "deferred-unsettled did not name the unsettled finding: $gate_out"

echo "==> applied_dispositions naming a finding WITH a matching settlement passes"
write_defaults
# render-dev-flow.mjs's own cross-document consistency rejects an "orphan"
# settlement (one naming a finding no adjudication document declares) and a
# settlement for a finding never dispositioned defer — both real invariants,
# so the fixture needs a genuine defer-dispositioned adjudication behind the
# settlement, not just the settlement alone.
jq -cn --arg head "$head_sha" \
    '{schema:2, run_id:"test-run", stage:"review", round:1,
      reviewed_head:$head,
      adjudications:[{finding_id:"review-r1-codex-cli-9",
        reviewer_priority:"P2", adjudicated_priority:"P2",
        disposition:"defer", reason:"carrying to integration",
        evidence:"needs a second look", override:null}]}' \
    >"${record_dir}/adjudications/review-r1.json"
write_review_r1_pass
# One remediation loop: this pass settles the deferred finding with `fix`, and
# a code change during integration always records the integration -> implement
# -> integration re-entry (Codex cloud-review cycle 1 on PR #800).
jq -cn --arg head "$head_sha" --argjson transitions "$(lifecycle_transitions "" 1)" \
    '{schema:2, run_id:"test-run", initiated_by:"human",
      started_at:"2026-01-01T00:00:00Z",
      stage_transitions:$transitions,
      interventions:[], outcome:null,
      pr:{number:493,url:"https://github.com/example/repo/pull/493"},
      evidence_comments:[],
      settlements:[{finding_id:"review-r1-codex-cli-9", disposition:"fix",
        settled_at:"2026-01-01T00:16:00Z",
        reference:{type:"sha",value:"c0ffeec0ffeec0ffeec0ffeec0ffeec0ffeec0ff"}}],
      promotion:null,
      evidence_registrations:[], outcome_transitions:[],
      pr_bindings:[{seq:0,prev_digest:"genesis",
        digest:"ec64b9703afdb8ec84d58495e89b4b11dc8c0a96720b330f649e0fe10a498ec1",
        number:493,url:"https://github.com/example/repo/pull/493",
        bound_at:"2026-01-01T00:00:00Z"}]}' >"${record_dir}/run.json"
disclosed_result="${fixtures}/integrator-result-disclosed.json"
jq -cn --arg head "$head_sha" '
  {schema:2, role:"integrator", status:"completed", head:$head,
   produced_at:"2026-01-01T00:00:00Z",
   producer:{harness:"claude-code",model:"test",tier:"economy"},
   run:{run_id:"test-run",initiated_by:"human"},
   payload:{checks:[{name:"build",bucket:"pass",run_id:"1",required:true}],
            codex_cycle:null, integration_round:1, findings:[],
            unanswered_thread_roots:[], settled_at:"2026-01-01T00:00:00Z",
            verdict:"clean",
            applied_dispositions:[{finding_id:"review-r1-codex-cli-9",
                                    disposition:"fix"}]}}' \
    >"$disclosed_result"
node "$validator" envelope "$disclosed_result" >/dev/null ||
    fail "disclosed-disposition fixture failed schema validation"
run_gate --integrator-result "$disclosed_result"
assert_gate 0 pass ready

# review round 3 gauntlet challenge, harmon-devkit#639 (Codex cloud-review
# cycle on PR #758): an id-only match let run.json record a DIFFERENT
# disposition than applied_dispositions claims and still read as settled.
echo "==> applied_dispositions naming fix but run.json's settlement says decline is disposition-unsettled"
write_defaults
jq -cn --arg head "$head_sha" \
    '{schema:2, run_id:"test-run", stage:"review", round:1,
      reviewed_head:$head,
      adjudications:[{finding_id:"review-r1-codex-cli-9",
        reviewer_priority:"P2", adjudicated_priority:"P2",
        disposition:"defer", reason:"carrying to integration",
        evidence:"needs a second look", override:null}]}' \
    >"${record_dir}/adjudications/review-r1.json"
write_review_r1_pass
jq -cn --arg head "$head_sha" --argjson transitions "$(lifecycle_transitions)" \
    '{schema:2, run_id:"test-run", initiated_by:"human",
      started_at:"2026-01-01T00:00:00Z",
      stage_transitions:$transitions,
      interventions:[], outcome:null,
      pr:{number:493,url:"https://github.com/example/repo/pull/493"},
      evidence_comments:[],
      settlements:[{finding_id:"review-r1-codex-cli-9", disposition:"decline",
        settled_at:"2026-01-01T00:12:00Z",
        reference:{type:"comment_id",value:"555"}}],
      promotion:null,
      evidence_registrations:[], outcome_transitions:[],
      pr_bindings:[{seq:0,prev_digest:"genesis",
        digest:"ec64b9703afdb8ec84d58495e89b4b11dc8c0a96720b330f649e0fe10a498ec1",
        number:493,url:"https://github.com/example/repo/pull/493",
        bound_at:"2026-01-01T00:00:00Z"}]}' >"${record_dir}/run.json"
mismatched_disposition_result="${fixtures}/integrator-result-mismatched-disposition.json"
jq -cn --arg head "$head_sha" '
  {schema:2, role:"integrator", status:"completed", head:$head,
   produced_at:"2026-01-01T00:00:00Z",
   producer:{harness:"claude-code",model:"test",tier:"economy"},
   run:{run_id:"test-run",initiated_by:"human"},
   payload:{checks:[{name:"build",bucket:"pass",run_id:"1",required:true}],
            codex_cycle:null, integration_round:1, findings:[],
            unanswered_thread_roots:[], settled_at:"2026-01-01T00:00:00Z",
            verdict:"clean",
            applied_dispositions:[{finding_id:"review-r1-codex-cli-9",
                                    disposition:"fix"}]}}' \
    >"$mismatched_disposition_result"
node "$validator" envelope "$mismatched_disposition_result" >/dev/null ||
    fail "mismatched-disposition fixture failed schema validation"
run_gate --integrator-result "$mismatched_disposition_result"
assert_gate 1 fail disposition-unsettled
grep -Fq 'review-r1-codex-cli-9' <<<"$gate_out" ||
    fail "disposition-unsettled did not name the mismatched finding: $gate_out"

# ---------------------------------------------------------------------------
# harmon-devkit#685 — run-trajectory receipt invariants de-scoped from #634,
# carried here as required test cases. Each block below names the acceptance
# criterion it discharges and pairs the attack with its legitimate neighbour,
# so a check cannot be satisfied by an over-broad reading of either half.
# ---------------------------------------------------------------------------

# --- #685 criterion 9: the moment an integrator pass applies fix|decline|file
# --- to a deferred finding, the matching append-only settlement exists,
# --- REGARDLESS OF OUTCOME. The `fix` case is covered above; decline and file
# --- are the two dispositions that leave the head alone, so nothing else in
# --- this gate would ever notice them going unrecorded.
write_deferred_adjudication() {
    write_review_r1_pass
    jq -cn --arg head "$head_sha" \
        '{schema:2, run_id:"test-run", stage:"review", round:1,
          reviewed_head:$head,
          adjudications:[{finding_id:"review-r1-codex-cli-9",
            reviewer_priority:"P2", adjudicated_priority:"P2",
            disposition:"defer", reason:"carrying to integration",
            evidence:"needs a second look", override:null}]}' \
        >"${record_dir}/adjudications/review-r1.json"
}

# $1 name, $2 disposition
write_disposition_result() {
    local out="${fixtures}/integrator-result-685-$1.json"
    jq -cn --arg head "$head_sha" --arg disp "$2" '
      {schema:2, role:"integrator", status:"completed", head:$head,
       produced_at:"2026-01-01T00:00:00Z",
       producer:{harness:"claude-code",model:"test",tier:"economy"},
       run:{run_id:"test-run",initiated_by:"human"},
       payload:{checks:[{name:"build",bucket:"pass",run_id:"1",required:true}],
                codex_cycle:null, integration_round:1, findings:[],
                unanswered_thread_roots:[], settled_at:"2026-01-01T00:00:00Z",
                verdict:"clean",
                applied_dispositions:[{finding_id:"review-r1-codex-cli-9",
                                        disposition:$disp}]}}' \
        >"$out"
    node "$validator" envelope "$out" >/dev/null ||
        fail "#685 disposition fixture ($2) failed schema validation"
    printf '%s\n' "$out"
}

for disposition in decline file; do
    echo "==> #685(9): a DEFERRED finding ${disposition}d in applied_dispositions with no settlement fails"
    write_defaults
    write_deferred_adjudication
    disposition_result="$(write_disposition_result "unsettled-${disposition}" "$disposition")"
    run_gate --integrator-result "$disposition_result"
    assert_gate 1 fail deferred-unsettled
    grep -Fq 'review-r1-codex-cli-9' <<<"$gate_out" ||
        fail "#685(9) ${disposition}: gate did not name the unsettled finding: $gate_out"
done

# $1 settlement disposition, $2 reference type, $3 reference value. Writes a
# whole record rather than patching: write_defaults resets run.json via
# write_default_record, so every case here restates it in full.
write_record_with_settlement() {
    jq -cn --arg disp "$1" --arg reftype "$2" --arg refvalue "$3" --argjson transitions "$(lifecycle_transitions "" 1)" '
      {schema:2, run_id:"test-run", initiated_by:"human",
       started_at:"2026-01-01T00:00:00Z",
       stage_transitions:$transitions,
       interventions:[], outcome:null,
       pr:{number:493,url:"https://github.com/example/repo/pull/493"},
       evidence_comments:[],
       settlements:[{finding_id:"review-r1-codex-cli-9", disposition:$disp,
                     settled_at:"2026-01-01T00:13:00Z",
                     reference:{type:$reftype, value:$refvalue}}],
       promotion:null, evidence_registrations:[], outcome_transitions:[],
       pr_bindings:[{seq:0,prev_digest:"genesis",
         digest:"ec64b9703afdb8ec84d58495e89b4b11dc8c0a96720b330f649e0fe10a498ec1",
         number:493,url:"https://github.com/example/repo/pull/493",
         bound_at:"2026-01-01T00:00:00Z"}]}' >"${record_dir}/run.json"
}

echo "==> #685(9): the same decline, once settled in run.json with the SAME disposition, passes"
write_defaults
write_record_with_settlement decline comment_id 9001
write_deferred_adjudication
disposition_result="$(write_disposition_result settled-decline decline)"
run_gate --integrator-result "$disposition_result"
assert_gate 0 pass ready

echo "==> #685(9): a settlement recording file where the pass applied decline is disposition-unsettled"
write_defaults
write_record_with_settlement file issue_number 9002
write_deferred_adjudication
run_gate --integrator-result "$disposition_result"
assert_gate 1 fail disposition-unsettled

# --- #685 criterion 7: every adjudicated round has a matching issue evidence
# --- marker, and a pr-destination marker does not substitute. The validator
# --- enforces this over a run record once it is promoted; this is the
# --- pre-promotion half, so an otherwise-clean PR cannot be promoted before
# --- the invariant holds (challenge round 3, confirmed). run_gate completes
# --- the markers for every other case, so these three opt out of that.
echo "==> #685(7): an adjudicated round with no issue evidence marker cannot promote"
write_defaults
write_deferred_adjudication
write_record_with_settlement decline comment_id 9001
skip_evidence_markers=1
disposition_result="$(write_disposition_result marker-missing decline)"
run_gate --integrator-result "$disposition_result"
skip_evidence_markers=0
assert_gate 1 fail evidence-marker-missing
grep -Fq 'review round 1' <<<"$gate_out" ||
    fail "#685(7): the gate did not name the unrecorded round: $gate_out"

echo "==> #685(7): a pr-destination marker for that round does not substitute"
write_defaults
write_deferred_adjudication
write_record_with_settlement decline comment_id 9001
add_evidence_marker review 1 pr
skip_evidence_markers=1
run_gate --integrator-result "$disposition_result"
skip_evidence_markers=0
assert_gate 1 fail evidence-marker-missing
grep -Fq 'never substitutes' <<<"$gate_out" ||
    fail "#685(7): the gate did not say a pr comment never substitutes: $gate_out"

echo "==> #685(7): the same round, once its issue evidence is recorded, promotes"
write_defaults
write_deferred_adjudication
write_record_with_settlement decline comment_id 9001
run_gate --integrator-result "$disposition_result"
assert_gate 0 pass ready

# --- #685 criterion 6: promotion.head equals the head of the final integrator
# --- result and its accepted-cycle reviewed commit; a stale integration pass
# --- cannot certify a newer promoted head. The envelope-head and
# --- accepted.reviewed_commit halves are proven elsewhere in this file; this
# --- is the record's own promotion entry, which was bound to nothing.
# $1 = the head the record claims it promoted (a promoted record is
# outcome: ready-for-review, which run.schema.json ties to a non-null
# promotion and a last stage_transitions entry of integration).
write_promoted_record() {
    jq -cn --arg head "$1" --argjson transitions "$(lifecycle_transitions ended)" '
      {schema:2, run_id:"test-run", initiated_by:"human",
       started_at:"2026-01-01T00:00:00Z",
       stage_transitions:$transitions,
       interventions:[], outcome:"ready-for-review",
       pr:{number:493,url:"https://github.com/example/repo/pull/493"},
       evidence_comments:[], settlements:[],
       promotion:{head:$head, promoted_at:"2026-01-01T02:00:00Z",
                  gate_fingerprint:"sha256:fingerprint"},
       evidence_registrations:[],
       outcome_transitions:[{seq:0,prev_digest:"genesis",
         digest:"9e521465a134c406ecae9a38eab52d859721d5c0307652016f2d02d0c5a96bcf",
         outcome:"ready-for-review", at:"2026-01-01T02:00:00Z"}],
       pr_bindings:[{seq:0,prev_digest:"genesis",
         digest:"ec64b9703afdb8ec84d58495e89b4b11dc8c0a96720b330f649e0fe10a498ec1",
         number:493,url:"https://github.com/example/repo/pull/493",
         bound_at:"2026-01-01T00:00:00Z"}]}' >"${record_dir}/run.json"
    rm -f "${record_dir}"/adjudications/*.json "${record_dir}"/passes/*.json
}

write_promoted_pr_view() {
    jq -cn --arg head "$head_sha" \
        '{state:"OPEN",isDraft:false,headRefOid:$head,
          reviewDecision:"REVIEW_REQUIRED",mergeStateStatus:"BLOCKED",
          headRefName:"feature-branch",baseRefName:"main",baseRefOid:"b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0"}' >"${fixtures}/pr-view.json"
}

echo "==> #685(6): audit passes when run.json's promotion.head IS the gated head"
write_defaults
write_promoted_record "$head_sha"
write_promoted_pr_view
run_audit
assert_gate 0 pass audit

echo "==> #685(6): a promotion.head naming a different commit is promotion-head-mismatch"
write_defaults
write_promoted_record "$stale_head_sha"
write_promoted_pr_view
run_audit
assert_gate 2 indeterminate promotion-head-mismatch

echo "==> #685(6): the same stale promotion.head is refused by check too, not only audit"
write_defaults
write_promoted_record "$stale_head_sha"
run_gate
assert_gate 2 indeterminate promotion-head-mismatch

# --- #685 criterion 4: integration -> implement -> integration loops are
# --- counted against [rounds.<policy>].remediation; exceeding it is capped
# --- with escalation, and code-changing integration dispositions past the cap
# --- are rejected. --remediation-cap is what supplies the resolved value.
# $1 = number of integration entries in stage_transitions

echo "==> #685(4): remediation loops within --remediation-cap pass"
write_defaults
write_record_with_integration_entries 2
run_gate --remediation-cap 3
assert_gate 0 pass ready

echo "==> #685(4): remediation loops exceeding --remediation-cap fail as remediation-capped"
write_defaults
write_record_with_integration_entries 2
run_gate --remediation-cap 1
assert_gate 1 fail remediation-capped

echo "==> #685(4): omitting --remediation-cap is a usage error, never a skipped check"
write_defaults
write_record_with_integration_entries 2
set +e
missing_cap_out="$("$watchdog_bin" -k 5 "$watchdog_sec" "$gate" check \
    --repo example/repo --pr 493 --head "$head_sha" --record "$record_dir" \
    --integrator-result "${fixtures}/integrator-result-disabled.json" \
    --integration-cap 0 2>&1)"
missing_cap_rc=$?
set -e
[ "$missing_cap_rc" -eq 2 ] ||
    fail "#685(4): omitting --remediation-cap should exit 2, got $missing_cap_rc: $missing_cap_out"

# A record that is exactly AT one remediation loop (two integration entries)
# and carries a settlement for the deferred finding, so the cases below turn
# only on the disposition the gated pass applies.
# $1 settlement disposition, $2 reference type, $3 reference value.
write_at_cap_record() {
    jq -cn --arg disp "$1" --arg reftype "$2" --arg refvalue "$3" '
      {schema:2, run_id:"test-run", initiated_by:"human",
       started_at:"2026-01-01T00:00:00Z",
       # Exactly one remediation loop, on the full lifecycle path — review
       # included, because a record that adjudicates a review round must
       # record having been in review (checkEvidenceMarkerStageVisited).
       stage_transitions:[
         {stage:"kickoff",entered_at:"2026-01-01T00:00:00Z",exit:"claimed"},
         {stage:"claim",entered_at:"2026-01-01T00:01:00Z",exit:"planned"},
         {stage:"plan",entered_at:"2026-01-01T00:02:00Z",exit:"briefed"},
         {stage:"implement",entered_at:"2026-01-01T00:03:00Z",exit:"verified"},
         {stage:"verify",entered_at:"2026-01-01T00:04:00Z",exit:"green"},
         {stage:"challenge",entered_at:"2026-01-01T00:05:00Z",exit:"converged"},
         {stage:"review",entered_at:"2026-01-01T00:06:00Z",exit:"converged"},
         {stage:"security",entered_at:"2026-01-01T00:07:00Z",exit:"clean"},
         {stage:"integration",entered_at:"2026-01-01T00:08:00Z",exit:"remediating"},
         {stage:"implement",entered_at:"2026-01-01T00:09:00Z",exit:"fixed"},
         {stage:"verify",entered_at:"2026-01-01T00:10:00Z",exit:"green"},
         {stage:"security",entered_at:"2026-01-01T00:11:00Z",exit:"clean"},
         {stage:"integration",entered_at:"2026-01-01T00:12:00Z"}],
       interventions:[], outcome:null,
       pr:{number:493,url:"https://github.com/example/repo/pull/493"},
       evidence_comments:[],
       settlements:[{finding_id:"review-r1-codex-cli-9", disposition:$disp,
                     settled_at:"2026-01-01T00:11:00Z",
                     reference:{type:$reftype, value:$refvalue}}],
       promotion:null, evidence_registrations:[], outcome_transitions:[],
       pr_bindings:[{seq:0,prev_digest:"genesis",
         digest:"ec64b9703afdb8ec84d58495e89b4b11dc8c0a96720b330f649e0fe10a498ec1",
         number:493,url:"https://github.com/example/repo/pull/493",
         bound_at:"2026-01-01T00:00:00Z"}]}' >"${record_dir}/run.json"
    node "$validator" run "${record_dir}/run.json" >/dev/null ||
        fail "#685(4) at-cap record fixture is not a valid run record"
}

# The regression that the criterion's "code-changing dispositions past the
# cap" clause invites and that must NOT happen (challenge round 1,
# confirmed): a run that spends its whole remediation budget converges with
# the fix that caused the final loop still listed in applied_dispositions —
# SKILL.md has the dispatched agent echo everything "accumulated so far this
# integration stage" onto the clean pass that closes the stage. Reading that
# as "a code change still needs applying" would refuse exactly the run that
# converged on budget.
echo "==> #685(4): AT the cap, a clean pass still echoing its historical fix converges"
write_defaults
write_at_cap_record fix sha "$head_sha"
write_deferred_adjudication
fix_result="$(write_disposition_result at-cap-fix fix)"
run_gate --integrator-result "$fix_result" --remediation-cap 1
assert_gate 0 pass ready

echo "==> #685(4): one loop OVER the cap fails whatever the dispositions say"
write_defaults
write_at_cap_record fix sha "$head_sha"
write_deferred_adjudication
run_gate --integrator-result "$fix_result" --remediation-cap 0
assert_gate 1 fail remediation-capped

# The round-indexed form of this bound (`loops >= the finding's own round`)
# was implemented at integrate cycle 2 and WITHDRAWN at cycle 3: a finding
# id's round segment is its pass's `integration_round`, which counts passes
# rather than rounds, so a finding first raised by pass 2 and fixed by the
# first fix push has one legitimate loop and the round-indexed bound rejected
# it forever. Its two cases are deleted with it rather than left asserting a
# property the gate no longer has. The residual it reached for — one loop
# covering several later code-changing cycles — needs per-finding loop
# attribution the record does not carry, and is filed as
# harmon-devkit#808.

echo "==> #685(4): a non-integer --remediation-cap is a usage error, never silently ignored"
write_defaults
write_default_record
set +e
bad_cap_out="$("$watchdog_bin" -k 5 "$watchdog_sec" "$gate" check \
    --repo example/repo --pr 493 --head "$head_sha" --record "$record_dir" \
    --integrator-result "${fixtures}/integrator-result-disabled.json" \
    --integration-cap 0 --remediation-cap not-a-number 2>&1)"
bad_cap_rc=$?
set -e
[ "$bad_cap_rc" -eq 2 ] ||
    fail "#685(4): a malformed --remediation-cap should exit 2, got $bad_cap_rc: $bad_cap_out"
grep -Fq -- '--remediation-cap must be a non-negative integer' <<<"$bad_cap_out" ||
    fail "#685(4): malformed --remediation-cap did not name the flag: $bad_cap_out"

# --- #685 criterion 5: codex_cycle.cycle <= [rounds].integration; cap 0 =>
# --- null cycle; a clean verdict with a null cycle under a positive cap is
# --- not clean. The five `check`-mode cases above cover all three clauses;
# --- this pins that `audit` — the mode the connector-flip reconcile path
# --- uses — waives none of them just because the PR is already promoted.
echo "==> #685(5): audit refuses a null codex_cycle under a positive --integration-cap too"
write_defaults
write_default_record
jq -cn --arg head "$head_sha" \
    '{state:"OPEN",isDraft:false,headRefOid:$head,
      reviewDecision:"REVIEW_REQUIRED",mergeStateStatus:"BLOCKED",
      headRefName:"feature-branch",baseRefName:"main",baseRefOid:"b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0"}' >"${fixtures}/pr-view.json"
run_audit --integration-cap 3
assert_gate 2 indeterminate codex-cap-mismatch

echo "==> a CHANGES_REQUESTED review landing mid-gate fails on the final re-read"
write_defaults
jq -cn --arg head "$head_sha" \
    '{state:"OPEN",isDraft:true,headRefOid:$head,
      reviewDecision:"CHANGES_REQUESTED",mergeStateStatus:"BLOCKED",baseRefName:"main",baseRefOid:"b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0"}' \
    >"${fixtures}/pr-view-second.json"
run_gate
assert_gate 1 fail changes-requested

echo "==> a DIRTY merge state arising mid-gate fails on the final re-read"
write_defaults
jq -cn --arg head "$head_sha" \
    '{state:"OPEN",isDraft:true,headRefOid:$head,
      reviewDecision:"REVIEW_REQUIRED",mergeStateStatus:"DIRTY",baseRefName:"main",baseRefOid:"b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0"}' \
    >"${fixtures}/pr-view-second.json"
run_gate
assert_gate 1 fail merge-state-dirty

echo "==> a body edit after fingerprinting fails on the final re-read"
write_defaults
final_body="$(printf 'What/why prose edited after fingerprinting.\n\n## Verification\n\n- task verify\n')"
jq -cn --arg head "$head_sha" \
    '{state:"OPEN",isDraft:true,headRefOid:$head,
      reviewDecision:"REVIEW_REQUIRED",mergeStateStatus:"BLOCKED",
      headRefName:"feature-branch",baseRefName:"main",baseRefOid:"b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0"}' \
    >"${fixtures}/pr-view-third.json"
jq -cn --arg body "$final_body" \
    '{body:$body,closingIssuesReferences:[]}' \
    >"${fixtures}/second-closing-view.json"
run_gate
assert_gate 1 fail content-moved

echo "==> the fingerprint is double-read: gated evaluation plus a fresh compare"
write_defaults
run_gate
assert_gate 0 pass ready
pr_object_fetches="$(grep -cxF 'api repos/example/repo/pulls/493' "$log")"
[ "$pr_object_fetches" -eq 2 ] ||
    fail "expected exactly two PR-object fetches (the gated body, then the fresh compare), saw $pr_object_fetches"

echo "==> a body edit mid-gate fails as content-moved, never laundered into a pass"
write_defaults
edited_body="$(printf 'What/why prose, edited after the gate read it.\n\n## Verification\n\n- task verify\n')"
jq -cn --arg head "$head_sha" --arg body "$edited_body" \
    '{number:493,title:"t",body:$body,head:{sha:$head},
      user:{id:4242,login:"pr-author"}}' >"${fixtures}/second-pr.json"
run_gate
assert_gate 1 fail content-moved
grep -Fq 'PR-title/body' <<<"$gate_out" ||
    fail "content-moved did not name the changed surface: $gate_out"

echo "==> a top-level comment landing mid-gate fails as content-moved"
write_defaults
jq -cn '[[{id:70,user:{login:"reviewer-bot"},body:"a late finding",
           updated_at:"2026-08-01T03:00:00Z"}]]' \
    >"${fixtures}/second-top.pages.json"
run_gate
assert_gate 1 fail content-moved
grep -Fq 'top-level-comments' <<<"$gate_out" ||
    fail "content-moved did not name the changed surface: $gate_out"

echo "==> a check turning red mid-gate fails on the final re-evaluation"
write_defaults
jq -cn '[{total_count:1,check_runs:[
    {name:"late-red",status:"completed",conclusion:"failure"}]}]' \
    >"${fixtures}/second-check-runs.pages.json"
run_gate
assert_gate 1 fail checks-failing
grep -Fq 'late-red' <<<"$gate_out" ||
    fail "the final re-evaluation did not name the late-failing check: $gate_out"

echo "==> without GNU timeout the gate still runs, loudly unbounded"
write_defaults
clean_result="$(write_integrator_result timeout-fallback "$(codex_cycle_json 0)")"
restricted_bin="${test_tmp}/restricted-bin"
mkdir -p "$restricted_bin"
# node, git, and gitleaks are required now (node for schema validation, git
# because the record projections are derived from the checkout, gitleaks
# because render-dev-flow.mjs secret-scans every projection it
# renders, unconditionally, before printing it), on top of the original
# minimal toolset this fixture restricts PATH to. `rm` joined them with
# harmon-devkit#685, when the gate started materializing the run's
# known-finding-id universe in a temp file and cleaning it up in an EXIT
# trap. The trap now ends in `|| :` so a missing `rm` can no longer become
# the verdict the caller reads, but `rm` stays listed here deliberately:
# this fixture is about running under a minimal toolset, not about proving
# the cleanup degrades — the trap's own robustness is asserted just below.
# `mktemp` joined it for the same reason at challenge round 3, when that temp
# file stopped being a predictable $$-derived path.
for tool in bash jq grep tr dirname cat node git gitleaks rm mktemp; do
    tool_path="$(command -v "$tool")" ||
        fail "missing $tool for the no-timeout fixture"
    ln -s "$tool_path" "${restricted_bin}/$tool"
done
for hasher in sha256sum shasum; do
    hasher_path="$(command -v "$hasher" 2>/dev/null || true)"
    [ -z "$hasher_path" ] || ln -s "$hasher_path" "${restricted_bin}/$hasher"
done
ln -s "${bin_dir}/gh" "${restricted_bin}/gh"
# $recheck_gate (not $gate) and RECHECK_FAKE_EXIT=0: codex_cycle here is
# exit_code 0, so recheck_codex_freshness runs and needs its fake checker
# sibling to confirm clean — see run_gate_recheck_clean's comment above. The
# fake stub is #!/bin/sh with no external calls, so it execs fine under this
# restricted PATH too.
set +e
gate_out="$("$watchdog_bin" -k 5 "$watchdog_sec" env PATH="$restricted_bin" RECHECK_FAKE_EXIT=0 \
    "$recheck_gate" check --repo example/repo --pr 493 --head "$head_sha" \
    --record "$record_dir" --integrator-result "$clean_result" \
    --integration-cap 1 --remediation-cap 4 --codex-recheck "$recheck_state" 2>&1)"
gate_rc=$?
set -e
check_watchdog "$gate_rc" no-timeout-fallback "$gate_out"
assert_gate 0 pass ready
grep -Fq 'no GNU timeout' <<<"$gate_out" ||
    fail "the timeout fallback must warn that calls are unbounded: $gate_out"

echo "==> #685: a cleanup that cannot run never becomes the verdict"
# The gate's verdict IS its exit code, so its EXIT trap must not be able to
# change it. Drop `rm` from the restricted toolset and the same green run
# must still report pass/0 rather than the trap's own failure — this fixture
# reproduced exactly that as a bare 127 while the trap lacked its `|| :`.
rm -f "${restricted_bin}/rm"
set +e
gate_out="$("$watchdog_bin" -k 5 "$watchdog_sec" env PATH="$restricted_bin" RECHECK_FAKE_EXIT=0 \
    "$recheck_gate" check --repo example/repo --pr 493 --head "$head_sha" \
    --record "$record_dir" --integrator-result "$clean_result" \
    --integration-cap 1 --remediation-cap 4 --codex-recheck "$recheck_state" 2>&1)"
gate_rc=$?
set -e
check_watchdog "$gate_rc" no-rm-fallback "$gate_out"
assert_gate 0 pass ready

nondraft_pr_view() {
    jq -cn --arg head "$head_sha" \
        '{state:"OPEN",isDraft:false,headRefOid:$head,
          reviewDecision:"REVIEW_REQUIRED",mergeStateStatus:"BLOCKED",
          headRefName:"feature-branch",baseRefName:"main",baseRefOid:"b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0"}' \
        >"${fixtures}/pr-view.json"
}

echo "==> audit passes a green already-promoted PR (check refuses the same PR)"
write_defaults
nondraft_pr_view
run_audit
assert_gate 0 pass audit
write_defaults
nondraft_pr_view
run_gate
assert_gate 1 fail pr-not-draft

echo "==> audit still fails red checks on an already-promoted PR"
write_defaults
nondraft_pr_view
jq -cn '[{total_count:1,check_runs:[
    {name:"lint",status:"completed",conclusion:"failure"}]}]' \
    >"${fixtures}/check-runs.pages.json"
run_audit
assert_gate 1 fail checks-failing

echo "==> audit refuses a draft target — there is no promotion to audit"
write_defaults
run_audit
assert_gate 1 fail pr-draft

echo "==> --record, --integrator-result, and the two caps are never skippable by silence"
write_defaults
clean_result="$(write_integrator_result skip-check "$(codex_cycle_json 0)")"
set +e
usage_out="$("$gate" check --repo example/repo --pr 493 --head "$head_sha" 2>&1)"
usage_rc=$?
set -e
[ "$usage_rc" -eq 2 ] ||
    fail "omitting --record and --integrator-result should exit 2, got $usage_rc: $usage_out"
set +e
no_record_out="$("$gate" check --repo example/repo --pr 493 --head "$head_sha" \
    --integrator-result "$clean_result" --integration-cap 1 --remediation-cap 4 2>&1)"
no_record_rc=$?
set -e
[ "$no_record_rc" -eq 2 ] ||
    fail "omitting --record alone should exit 2, got $no_record_rc: $no_record_out"
set +e
no_result_out="$("$gate" check --repo example/repo --pr 493 --head "$head_sha" \
    --record "$record_dir" --integration-cap 1 --remediation-cap 4 2>&1)"
no_result_rc=$?
set -e
[ "$no_result_rc" -eq 2 ] ||
    fail "omitting --integrator-result alone should exit 2, got $no_result_rc: $no_result_out"
set +e
no_cap_out="$("$gate" check --repo example/repo --pr 493 --head "$head_sha" \
    --record "$record_dir" --integrator-result "$clean_result" --remediation-cap 4 2>&1)"
no_cap_rc=$?
set -e
[ "$no_cap_rc" -eq 2 ] ||
    fail "omitting --integration-cap alone should exit 2, got $no_cap_rc: $no_cap_out"
set +e
no_remediation_out="$("$gate" check --repo example/repo --pr 493 --head "$head_sha" \
    --record "$record_dir" --integrator-result "$clean_result" --integration-cap 1 2>&1)"
no_remediation_rc=$?
set -e
[ "$no_remediation_rc" -eq 2 ] ||
    fail "omitting --remediation-cap alone should exit 2, got $no_remediation_rc: $no_remediation_out"

echo "==> a short --head is a usage error, exit 2"
write_defaults
clean_result="$(write_integrator_result short-head "$(codex_cycle_json 0)")"
set +e
short_out="$("$gate" check --repo example/repo --pr 493 --head abc123 \
    --record "$record_dir" --integrator-result "$clean_result" \
    --integration-cap 1 --remediation-cap 4 2>&1)"
short_rc=$?
set -e
[ "$short_rc" -eq 2 ] ||
    fail "a short --head should exit 2, got $short_rc: $short_out"

# ---------------------------------- gh-ro ----------------------------------

refuse_case() {
    label=$1
    shift
    set +e
    ro_out="$("$ghro" "$@" 2>&1)"
    ro_rc=$?
    set -e
    [ "$ro_rc" -eq 2 ] ||
        fail "gh-ro $label: expected refusal rc 2, got $ro_rc: $ro_out"
    grep -Fq 'refused' <<<"$ro_out" ||
        fail "gh-ro $label: refusal did not say refused: $ro_out"
    if grep -q '^api ' "$log"; then
        fail "gh-ro $label: a refused invocation still reached gh: $(cat "$log")"
    fi
}

echo "==> gh-ro refuses every mutation-capable argument"
write_defaults
refuse_case "-X POST" repos/example/repo/issues/493/comments -X POST
refuse_case "--method DELETE" repos/example/repo/issues/comments/1 --method DELETE
refuse_case "--method=PATCH" repos/example/repo/pulls/493 --method=PATCH
refuse_case "-f body" repos/example/repo/issues/493/comments -f body=hi
refuse_case "--field" repos/example/repo/issues/493/comments --field body=hi
refuse_case "-F body" repos/example/repo/issues/493/comments -F body=@file
refuse_case "--raw-field" repos/example/repo/issues/493/comments --raw-field body=hi
refuse_case "--input" repos/example/repo/issues/493/comments --input payload.json
refuse_case "--hostname" repos/example/repo/pulls/493 --hostname ghe.example
refuse_case "--header" repos/example/repo/pulls/493 -H 'Accept: application/vnd.github+json'
refuse_case "unknown flag" repos/example/repo/pulls/493 --verbose
refuse_case "attached -XGET" repos/example/repo/pulls/493 -XGET
refuse_case "graphql" graphql -f query=x
refuse_case "graphql alone" graphql
refuse_case "/graphql" /graphql
refuse_case "GraphQL case" GraphQL
refuse_case "absolute https URL" https://api.github.com/repos/example/repo/pulls/493
refuse_case "absolute http URL" http://127.0.0.1/latest/meta-data
refuse_case "two endpoints" repos/a/b/pulls/1 repos/a/b/pulls/2
refuse_case "no endpoint" --paginate
refuse_case "trailing -X without value" repos/a/b/pulls/1 -X

echo "==> gh-ro forwards a vetted read and pins --method GET exactly once"
write_defaults
printf '0\n' >"${fixtures}/ro-exit"
"$ghro" repos/example/repo/pulls/493/comments --paginate --slurp --jq '.[0]' \
    >/dev/null
grep -Fxq 'api --method GET --paginate --slurp --jq .[0] repos/example/repo/pulls/493/comments' "$log" ||
    fail "gh-ro forwarded unexpected arguments: $(cat "$log")"

echo "==> gh-ro accepts an explicit GET without duplicating the method flag"
write_defaults
printf '0\n' >"${fixtures}/ro-exit"
"$ghro" user --jq .login -X GET >/dev/null
grep -Fxq 'api --method GET --jq .login user' "$log" ||
    fail "gh-ro -X GET handling forwarded unexpected arguments: $(cat "$log")"
write_defaults
printf '0\n' >"${fixtures}/ro-exit"
"$ghro" user --method=GET >/dev/null
grep -Fxq 'api --method GET user' "$log" ||
    fail "gh-ro --method=GET handling forwarded unexpected arguments: $(cat "$log")"

echo "==> gh-ro propagates gh's own exit code"
write_defaults
printf '7\n' >"${fixtures}/ro-exit"
set +e
"$ghro" repos/example/repo/pulls/493/comments --paginate >/dev/null 2>&1
ro_rc=$?
set -e
[ "$ro_rc" -eq 7 ] ||
    fail "gh-ro should propagate gh's exit 7, got $ro_rc"

# ------------------------------ gh-write-broker -----------------------------

wb_refuse_case() {
    label=$1
    shift
    set +e
    wb_out="$("$ghwb" "$@" 2>&1)"
    wb_rc=$?
    set -e
    [ "$wb_rc" -eq 2 ] ||
        fail "gh-write-broker $label: expected refusal rc 2, got $wb_rc: $wb_out"
    grep -qE 'refused|Usage:' <<<"$wb_out" ||
        fail "gh-write-broker $label: refusal did not say refused or print usage: $wb_out"
    if grep -q '^api ' "$log"; then
        fail "gh-write-broker $label: a refused invocation still reached gh: $(cat "$log")"
    fi
}

echo "==> gh-write-broker refuses a malformed or mismatched call before reaching gh"
write_defaults
reply_body="${fixtures}/reply-body.txt"
printf 'exact reply text' >"$reply_body"
empty_body="${fixtures}/empty-body.txt"
: >"$empty_body"
wb_refuse_case "trigger with --comment-id" trigger --repo example/repo --pr 493 --comment-id 900
wb_refuse_case "trigger with --body-file" trigger --repo example/repo --pr 493 --body-file "$reply_body"
wb_refuse_case "reply missing --comment-id" reply --repo example/repo --pr 493 --body-file "$reply_body"
wb_refuse_case "reply missing --body-file" reply --repo example/repo --pr 493 --comment-id 900
wb_refuse_case "reply with nonexistent --body-file" reply --repo example/repo --pr 493 --comment-id 900 --body-file "${fixtures}/does-not-exist.txt"
wb_refuse_case "reply with empty --body-file" reply --repo example/repo --pr 493 --comment-id 900 --body-file "$empty_body"
wb_refuse_case "reply with non-numeric --comment-id" reply --repo example/repo --pr 493 --comment-id abc --body-file "$reply_body"
wb_refuse_case "top-level is not a recognized subcommand" top-level --repo example/repo --pr 493 --body-file "$reply_body"
wb_refuse_case "invalid repo" trigger --repo not-a-repo --pr 493
wb_refuse_case "invalid pr" trigger --repo example/repo --pr abc
wb_refuse_case "unknown subcommand" delete --repo example/repo --pr 493
wb_refuse_case "no subcommand"

echo "==> gh-write-broker trigger posts exactly the hardcoded body, nothing else"
write_defaults
printf '0\n' >"${fixtures}/ro-exit"
"$ghwb" trigger --repo example/repo --pr 493 >/dev/null
grep -Fxq "api repos/example/repo/issues/493/comments -f body=@codex review --jq .id" "$log" ||
    fail "gh-write-broker trigger forwarded unexpected arguments: $(cat "$log")"

echo "==> gh-write-broker reply posts exactly the given file to exactly that comment's replies"
write_defaults
printf '0\n' >"${fixtures}/ro-exit"
"$ghwb" reply --repo example/repo --pr 493 --comment-id 900 --body-file "$reply_body" >/dev/null
grep -Fxq "api repos/example/repo/pulls/493/comments/900/replies -F body=@${reply_body}" "$log" ||
    fail "gh-write-broker reply forwarded unexpected arguments: $(cat "$log")"

echo "==> gh-write-broker propagates gh's own exit code"
write_defaults
printf '7\n' >"${fixtures}/ro-exit"
set +e
"$ghwb" trigger --repo example/repo --pr 493 >/dev/null 2>&1
wb_rc=$?
set -e
[ "$wb_rc" -eq 7 ] ||
    fail "gh-write-broker should propagate gh's exit 7, got $wb_rc"

# harmon-init#752: a CARRIED cycle is the one result shape claiming that no
# reviewer ever read the gated head. The gate cannot re-derive the patch
# identity itself — that is the checker's job, and --codex-recheck is what
# runs it — but it can refuse a claim with nothing durable behind it, which is
# the same integrity rule the charged/exempt split answers to.
carried_origin=0a1b2c3d4e5f60718293a4b5c6d7e8f900112233
carried_id=fedcba9876543210fedcba9876543210fedcba98

# The carry record, as BOTH the result discloses it and the checker state
# records it — one definition, because challenge round 2 made the gate compare
# them as whole objects rather than field by field, and two definitions here
# would let this suite pass a mismatch the gate is supposed to catch.
# $1 origin head, $2 change id, $3 attested head
carried_record_json() {
    jq -cn --arg origin "$1" --arg id "$2" --arg attests "$3" '{
        origin_head: $origin,
        attests_head: $attests,
        from_head: $origin,
        base_sha: "99887766554433221100998877665544332211aa",
        change_id: $id,
        algorithm: "git-diff-digest/three-dot/v1",
        generation: 1,
        carried_at: "2026-09-22T12:00:00Z"
      }'
}

# $1 origin head, $2 change id
carried_cycle_json() {
    jq -c --arg origin "$1" \
        --argjson carried "$(carried_record_json "$1" "$2" "$head_sha")" '
      .accepted.reviewed_commit = $origin |
      .carried = $carried' <<<"$(codex_cycle_json 0)"
}

echo "==> a carried verdict the checker state corroborates passes"
write_defaults
jq --arg o "$carried_origin" \
    --argjson carry "$(carried_record_json "$carried_origin" "$carried_id" "$head_sha" |
        jq -c 'del(.origin_head)')" \
    '.head = $o | .carry = $carry' "$recheck_state" >"${recheck_state}.next"
mv "${recheck_state}.next" "$recheck_state"
carried_result="$(write_integrator_result carried-ok "$(carried_cycle_json "$carried_origin" "$carried_id")")"
run_gate_recheck_clean --integrator-result "$carried_result" \
    --integration-cap 2 --integration-exempt-cap 2
assert_gate 0 pass ready

echo "==> a carried verdict with no --codex-recheck state is codex-carried-unproven"
# The advisory flag stops being advisory for exactly this shape: with no
# reviewer evidence for this head, the result's own say-so is all there is.
write_defaults
carried_result="$(write_integrator_result carried-no-state "$(carried_cycle_json "$carried_origin" "$carried_id")")"
run_gate --integrator-result "$carried_result" \
    --integration-cap 2 --integration-exempt-cap 2
assert_gate 2 indeterminate codex-carried-unproven

echo "==> a carried verdict the checker state does not record is codex-carried-unproven"
write_defaults
jq --arg h "$head_sha" 'del(.carry) | .head = $h' "$recheck_state" >"${recheck_state}.next"
mv "${recheck_state}.next" "$recheck_state"
carried_result="$(write_integrator_result carried-unrecorded "$(carried_cycle_json "$carried_origin" "$carried_id")")"
run_gate_recheck_clean --integrator-result "$carried_result" \
    --integration-cap 2 --integration-exempt-cap 2
assert_gate 2 indeterminate codex-carried-unproven

echo "==> a carried verdict whose identity disagrees with the state is codex-carried-unproven"
# The direction that matters: a producer naming a DIFFERENT proven change
# would otherwise have this head accepted on a verdict about other bytes.
write_defaults
jq --arg o "$carried_origin" \
    --argjson carry "$(carried_record_json "$carried_origin" "$carried_id" "$head_sha" |
        jq -c 'del(.origin_head)')" \
    '.head = $o | .carry = $carry' "$recheck_state" >"${recheck_state}.next"
mv "${recheck_state}.next" "$recheck_state"
carried_result="$(write_integrator_result carried-wrong-patch \
    "$(carried_cycle_json "$carried_origin" 1111111111111111111111111111111111111111)")"
run_gate_recheck_clean --integrator-result "$carried_result" \
    --integration-cap 2 --integration-exempt-cap 2
assert_gate 2 indeterminate codex-carried-unproven

echo "==> a carried record altered in ANY field is codex-carried-unproven"
# Challenge round 2, finding `challenge-r2-codex-adversarial-3` (confirmed P2):
# spot-checking two fields let a schema-valid result rewrite the rest of the
# provenance — `from_head`, `base_sha`, `generation`, `carried_at` — and still
# pass. The disclosure IS the record, so it is compared as one object; this
# case mutates a field nobody would think to check individually.
write_defaults
jq --arg o "$carried_origin" \
    --argjson carry "$(carried_record_json "$carried_origin" "$carried_id" "$head_sha" |
        jq -c 'del(.origin_head)')" \
    '.head = $o | .carry = $carry' "$recheck_state" >"${recheck_state}.next"
mv "${recheck_state}.next" "$recheck_state"
carried_result="$(write_integrator_result carried-altered-provenance \
    "$(jq -c '.carried.generation = 7' \
        <<<"$(carried_cycle_json "$carried_origin" "$carried_id")")")"
run_gate_recheck_clean --integrator-result "$carried_result" \
    --integration-cap 2 --integration-exempt-cap 2
assert_gate 2 indeterminate codex-carried-unproven

write_defaults
jq --arg h "$head_sha" 'del(.carry) | .head = $h' "$recheck_state" >"${recheck_state}.next"
mv "${recheck_state}.next" "$recheck_state"

# harmon-init#752. The checker suite grew this property test at
# harmon-init#1326's challenge round 3, after a flag was added to the inner assigning
# `case` and not the outer name allowlist. The same mistake was made in THIS
# script's gate on the same day — and the fix was replicated to one of the two
# sites, which is the shape the whole finding was about. So the property lives
# here too now: every flag the gate's own synopsis documents must parse.
echo "==> a non-codex finder claiming a carry is codex-carried-unproven"
# There is no carry mechanism for any finder but codex-cloud, and nothing
# durable records one, so the claim is unfounded by construction rather than
# merely unproven. The receipt validator's carve-out is schema-wide; this is
# where that breadth is closed.
write_defaults
jq --arg o "$carried_origin" \
    --argjson carry "$(carried_record_json "$carried_origin" "$carried_id" "$head_sha" |
        jq -c 'del(.origin_head)')" \
    '.head = $o | .carry = $carry' "$recheck_state" >"${recheck_state}.next"
mv "${recheck_state}.next" "$recheck_state"
carried_base="$(write_integrator_result carried-foreign-finder \
    "$(carried_cycle_json "$carried_origin" "$carried_id")")"
jq --arg origin "$carried_origin" \
    --argjson carried "$(carried_record_json "$carried_origin" "$carried_id" "$head_sha")" '
    .payload.finder_cycles = [{
      finder: "coderabbit-cloud", head: .head, cycle: 1, attempt: 1,
      trigger_comment_id: "9001", exit_code: 0,
      accepted: {surface: "review", id: "9002", reviewed_commit: $origin},
      carried: $carried}]' \
    "$carried_base" >"${fixtures}/integrator-result-carried-foreign-finder-fc.json"
node "$validator" envelope \
    "${fixtures}/integrator-result-carried-foreign-finder-fc.json" >/dev/null ||
    fail "the foreign-finder carry fixture must itself be schema-valid — the point is that the GATE refuses it, not the schema"
run_gate_recheck_clean \
    --integrator-result "${fixtures}/integrator-result-carried-foreign-finder-fc.json" \
    --integration-cap 2 --integration-exempt-cap 2
assert_gate 2 indeterminate codex-carried-unproven

write_defaults
jq --arg h "$head_sha" 'del(.carry) | .head = $h' "$recheck_state" >"${recheck_state}.next"
mv "${recheck_state}.next" "$recheck_state"

echo "==> every flag named in the gate's usage text is actually parsed"
gate_usage="$("$gate" --help 2>&1 || true)"
gate_flags="$(printf '%s\n' "$gate_usage" |
    awk '/^Usage:/{inblock=1; next} inblock && /^[[:space:]]*$/{exit} inblock' |
    grep -oE -- '--[a-z][a-z-]*' | sort -u)"
[ -n "$gate_flags" ] || fail "could not extract any flag from the gate's usage text"
while IFS= read -r gate_flag; do
    [ -n "$gate_flag" ] || continue
    case "$gate_flag" in
    --help) continue ;;
    esac
    # Unlike the checker's probe, this one has to supply every REQUIRED flag
    # first: the gate prints usage for a missing one, so a bare probe reports
    # each parsed flag as unparsed and the property test would fail on all of
    # them at once — which is a test that can never pass rather than one that
    # catches the bug. With the requirements satisfied, `probe` as a VALUE is
    # rejected by the gate's own validation (`die`, no usage block), so usage
    # in the output can only mean the flag name itself fell through.
    gate_probe="$("$gate" check \
        --repo example/repo --pr 493 \
        --head 1111111111111111111111111111111111111111 \
        --record "${test_tmp}/no-such-record" \
        --integrator-result "${test_tmp}/no-such-result.json" \
        --integration-cap 1 --remediation-cap 1 \
        "$gate_flag" probe 2>&1 || true)"
    case "$gate_probe" in
    *"Usage:"*)
        fail "flag $gate_flag appears in the gate's usage text but is not parsed (missing from the outer allowlist?)"
        ;;
    esac
done <<EOF
$gate_flags
EOF

echo "integration readiness gate + gh-ro + gh-write-broker: PASS"
