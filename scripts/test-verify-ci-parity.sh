#!/usr/bin/env bash
# `verify` and the required Build workflow run their `test:*` targets through
# ONE aggregate Taskfile task (test:suite), so the two lists cannot drift
# (harmon-init#962, #1461). This is the whole guard: it fails when the Build
# workflow stops gating on that task, when `verify` stops calling it,
# or when `verify` gains a `test:*` entry of its own that the workflow would
# never run. Plain text only — a block is the lines from its key to the next
# key at the same two-space indent; no YAML or shell is parsed, and `task`
# itself is not needed.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow="${repo}/.github/workflows/build.yml"
taskfile="${repo}/Taskfile.yml"

fail() { # shell-robustness: ok — this reporter always exits 1
    echo "TEST FAIL: $*" >&2
    exit 1
}

# block FILE KEY — the two-space-indented `KEY:` entry's lines (a Taskfile task
# or a workflow job): up to the next line indented exactly two spaces.
block() {
    awk -v key="$2" '
        $0 ~ "^  " key ":[[:space:]]*$" { on = 1; next }
        on && /^  [^ #]/ { exit }
        on' "$1"
}

# Consumers may still run the suite in lint. The source runs it in a separate
# test-suite job, which must feed its result into the required verify aggregate.
# Comments and a suite step in an unrelated job never satisfy these anchors.
workflow_calls_suite() {
    local suite_step='^[[:space:]]*(-[[:space:]]+)?run:[[:space:]]+task test:suite[[:space:]]*$'
    if block "$1" lint | grep -E "$suite_step" >/dev/null; then
        return 0
    fi
    block "$1" test-suite | grep -E "$suite_step" >/dev/null || return 1
    block "$1" verify | grep -E '^[[:space:]]+needs:.*(\[|,)[[:space:]]*test-suite[[:space:]]*(,|\])' >/dev/null || return 1
    block "$1" verify | grep -Ev '^[[:space:]]*#' | grep -F 'TEST_SUITE_RESULT: ${{ needs.test-suite.result }}' >/dev/null || return 1
    block "$1" verify | grep -E '^[[:space:]]*(-[[:space:]]+)?run:' | grep -F '"test-suite=${TEST_SUITE_RESULT}"' >/dev/null
}

# `verify` itself lists `task: test:suite` — calling a leaf the suite also
# lists would pass a weaker check while the suite went unused.
verify_runs_suite() {
    block "$1" verify | grep -E '^[[:space:]]+-[[:space:]]+task:[[:space:]]+test:suite[[:space:]]*$' >/dev/null
}

# verify_has_no_stray_tests TASKFILE WORKFLOW — every `test:*` entry in
# `verify` must be the suite, or test:template when (and only when) the same
# build.yml defines the `template-test:` job it runs as. A repository without
# that job has no required step for test:template, so there it is stray like
# any other entry: it would run locally and in no required Build step, the
# drift this guard exists for.
verify_has_no_stray_tests() {
    local stray allowed='suite'
    if grep -Eq '^  template-test:[[:space:]]*$' "$2"; then
        allowed='(suite|template)'
    fi
    stray="$(block "$1" verify | grep -E '^[[:space:]]+-[[:space:]]+task:[[:space:]]+test:' |
        grep -Ev "task:[[:space:]]+test:${allowed}[[:space:]]*\$" || true)"
    [ -z "$stray" ] || {
        echo "$stray" >&2
        return 1
    }
}

[ -f "$workflow" ] || fail "${workflow} not found"
[ -f "$taskfile" ] || fail "${taskfile} not found"
workflow_calls_suite "$workflow" ||
    fail "the Build workflow no longer gates on \`task test:suite\` in a step — add it back rather than listing test:* targets in build.yml"
verify_runs_suite "$taskfile" ||
    fail "\`verify\` no longer lists \`task: test:suite\` itself"
verify_has_no_stray_tests "$taskfile" "$workflow" ||
    fail "\`verify\` lists the test:* entries above directly — add them to test:suite instead, or the Build workflow never runs them"

# Planted cases: every check above must be able to fail.
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

grep -Ev 'run:[[:space:]]+task test:suite' "$workflow" >"${scratch}/removed.yml"
! workflow_calls_suite "${scratch}/removed.yml" ||
    fail "planted case: a workflow without the aggregate step still passed"
printf '%s\n' 'jobs:' '  lint:' '    steps:' '      # - run: task test:suite' '  security:' '    steps:' >"${scratch}/commented.yml"
! workflow_calls_suite "${scratch}/commented.yml" ||
    fail "planted case: a commented-out aggregate step still passed"
printf '%s\n' 'jobs:' '  lint:' '    steps:' '      - run: task check' \
    '  security:' '    steps:' '      - run: task test:suite' >"${scratch}/moved.yml"
! workflow_calls_suite "${scratch}/moved.yml" ||
    fail "planted case: the aggregate step in another job still passed"
printf '%s\n' 'jobs:' '  lint:' '    steps:' '      - run: task test:suite' '  security:' '    steps:' >"${scratch}/ok.yml"
workflow_calls_suite "${scratch}/ok.yml" ||
    fail "planted case: a lint job that runs the aggregate step was rejected"

printf '%s\n' 'jobs:' '  lint:' '    steps:' '      - run: task check' \
    '  test-suite:' '    steps:' '      - run: task test:suite' \
    '  verify:' '    needs: [lint, test-suite, security]' '    steps:' \
    '      - env:' '          TEST_SUITE_RESULT: ${{ needs.test-suite.result }}' \
    '        run: ./scripts/verify-ci-results.sh "test-suite=${TEST_SUITE_RESULT}"' >"${scratch}/split.yml"
workflow_calls_suite "${scratch}/split.yml" ||
    fail "planted case: a suite feeding the required verify aggregate was rejected"
grep -v '^    needs:' "${scratch}/split.yml" >"${scratch}/ungated.yml"
! workflow_calls_suite "${scratch}/ungated.yml" ||
    fail "planted case: an ungated test-suite job still passed"
grep -v 'TEST_SUITE_RESULT:' "${scratch}/split.yml" >"${scratch}/missing-result.yml"
! workflow_calls_suite "${scratch}/missing-result.yml" ||
    fail "planted case: a suite whose result is not captured still passed"
grep -v 'run: ./scripts/verify-ci-results.sh' "${scratch}/split.yml" >"${scratch}/unused-result.yml"
! workflow_calls_suite "${scratch}/unused-result.yml" ||
    fail "planted case: a suite whose result is not checked still passed"
sed 's/TEST_SUITE_RESULT:/# TEST_SUITE_RESULT:/' "${scratch}/split.yml" >"${scratch}/commented-result.yml"
! workflow_calls_suite "${scratch}/commented-result.yml" ||
    fail "planted case: a commented-out result capture still passed"
sed 's/run: .\/scripts\/verify-ci-results.sh/# run: .\/scripts\/verify-ci-results.sh/' "${scratch}/split.yml" >"${scratch}/commented-check.yml"
! workflow_calls_suite "${scratch}/commented-check.yml" ||
    fail "planted case: a commented-out result check still passed"

printf '%s\n' 'jobs:' '  lint:' '    steps:' '      - run: task test:suite' '  template-test:' '    steps:' >"${scratch}/with-matrix.yml"
printf '%s\n' 'tasks:' '  verify:' '    cmds:' '      - task: check' '      - task: test:suite' '      - task: test:template' \
    '  test:suite:' '    cmds:' '      - task: test:verify-ci-parity' >"${scratch}/ok.Taskfile"
verify_runs_suite "${scratch}/ok.Taskfile" && verify_has_no_stray_tests "${scratch}/ok.Taskfile" "${scratch}/with-matrix.yml" ||
    fail "planted case: a verify that runs the suite (+ test:template, with the template-test job present) was rejected"
! verify_has_no_stray_tests "${scratch}/ok.Taskfile" "${scratch}/ok.yml" 2>/dev/null ||
    fail "planted case: a direct test:template in verify passed although the workflow has no template-test job"
printf '%s\n' 'tasks:' '  verify:' '    cmds:' '      - task: check' '      - task: test:verify-ci-parity' \
    '  test:suite:' '    cmds:' '      - task: test:verify-ci-parity' >"${scratch}/leaf.Taskfile"
! verify_runs_suite "${scratch}/leaf.Taskfile" ||
    fail "planted case: a verify calling a suite member instead of the suite still passed"
printf '%s\n' 'tasks:' '  verify:' '    cmds:' '      - task: check' '      - echo no suite here' \
    '  test:suite:' '    cmds:' '      - task: test:suite-ish' >"${scratch}/drifted.Taskfile"
! verify_runs_suite "${scratch}/drifted.Taskfile" ||
    fail "planted case: a verify that does not run the suite still passed"
printf '%s\n' 'tasks:' '  verify:' '    cmds:' '      - task: test:suite' '      - task: test:renovate-config' \
    '  test:suite:' '    cmds:' '      - task: test:verify-ci-parity' >"${scratch}/stray.Taskfile"
! verify_has_no_stray_tests "${scratch}/stray.Taskfile" "${scratch}/with-matrix.yml" 2>/dev/null ||
    fail "planted case: a verify with a direct test:* entry still passed"

echo "test-verify-ci-parity: PASS"
