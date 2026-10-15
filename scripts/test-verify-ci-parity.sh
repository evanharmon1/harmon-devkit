#!/usr/bin/env bash
# `verify` and the required Build workflow run their `test:*` targets through
# ONE aggregate Taskfile task (test:suite) and the project's own test tier
# through `task test`, so local `verify` and CI cannot drift
# (harmon-init#962, #1461, #1681). This is the whole guard: it fails when the
# Build workflow stops gating on `task test:suite`, when the project
# test job stops calling `task test`, when `verify` stops calling either, or
# when `verify` gains a `test:*` entry of its own that the workflow would never
# run. Plain text only — a block is the lines from its key to the next key at
# the same two-space indent; no YAML or shell is parsed, and `task` itself is
# not needed.
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

# An uncommented `run: task test` step (that exact command — `task test:*`
# fails the end anchor) inside any job in the Build workflow (`build-test` in
# the template; `test`, `test-*`, `unit-tests`, or any other job name when a
# consumer names or splits the job differently). A comment starts with `#`, so
# it cannot satisfy the anchor.
workflow_calls_test() {
    local job
    while IFS= read -r job; do
        [ -n "$job" ] || continue
        if block "$1" "$job" | grep -E '^[[:space:]]*(-[[:space:]]+)?run:[[:space:]]+task test[[:space:]]*$' >/dev/null; then
            return 0
        fi
    done < <(awk '
        /^jobs:[[:space:]]*$/ { on = 1; next }
        on && /^[^ #]/ { exit }
        on && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ {
            sub(/^  /, "")
            sub(/:[[:space:]]*$/, "")
            print
        }' "$1")
    return 1
}

# `verify` itself lists `task: test:suite` — calling a leaf the suite also
# lists would pass a weaker check while the suite went unused.
verify_runs_suite() {
    block "$1" verify | grep -E '^[[:space:]]+-[[:space:]]+task:[[:space:]]+test:suite[[:space:]]*$' >/dev/null
}

# `verify` itself lists `task: test` (generated repos do; harmon-init's root
# Taskfile runs `task: test:template` instead).
verify_runs_test() {
    block "$1" verify | grep -E '^[[:space:]]+-[[:space:]]+task:[[:space:]]+test[[:space:]]*$' >/dev/null
}

# is_template_source_root TASKFILE — true only when TASKFILE lives in
# harmon-init's own template-source root (which carries `copier.yml` and
# `template/Taskfile.yml.jinja` beside `Taskfile.yml`), never in a generated
# consumer repository — even one that defines its own `template-test` job.
is_template_source_root() {
    local dir
    dir="$(dirname "$1")"
    [ -f "${dir}/copier.yml" ] && [ -f "${dir}/template/Taskfile.yml.jinja" ]
}

# unwired_non_node_scaffold TASKFILE — true only when `test` is still the
# unchanged non-Node scaffold stub (harmon-init#978): its body has the exact
# stub `echo` item and no other non-comment lines besides `desc:` and `cmds:`.
unwired_non_node_scaffold() {
    local stub='^[[:space:]]+-[[:space:]]+'\''echo "TODO: wire tests for this project \(see docs/architecture/tests\.md\); test files live in tests/"'\''[[:space:]]*$'
    block "$1" test | grep -E "$stub" >/dev/null || return 1
    ! block "$1" test | grep -Ev '^[[:space:]]*(#|$|desc:[[:space:]]|cmds:[[:space:]]*$)' | grep -Ev "$stub" >/dev/null
}

# project_test_tier_active TASKFILE WORKFLOW — true when the Build workflow
# must carry a `run: task test` step: every consumer repository (any repo
# outside the template-source root) except a fresh non-Node render that has no
# `build-test` job yet and whose `test` task is still the unchanged scaffold
# stub.
project_test_tier_active() {
    is_template_source_root "$1" && return 1
    grep -Eq '^  build-test:[[:space:]]*$' "$2" && return 0
    ! unwired_non_node_scaffold "$1"
}

# guard_test_tier TASKFILE WORKFLOW — enforce both halves of the project test
# tier contract (`run: task test` in the Build workflow when active, and
# `task: test` in `verify` for every consumer repository).
guard_test_tier() {
    if project_test_tier_active "$1" "$2"; then
        workflow_calls_test "$2" ||
            fail "the Build workflow no longer runs \`task test\` in a job — add an uncommented \`run: task test\` step rather than enumerating test:* targets in build.yml"
    fi
    if ! is_template_source_root "$1"; then
        verify_runs_test "$1" ||
            fail "\`verify\` no longer lists \`task: test\` itself"
    fi
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
guard_test_tier "$taskfile" "$workflow"
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

if project_test_tier_active "$taskfile" "$workflow"; then
    grep -Ev 'run:[[:space:]]+task test([[:space:]]|$)' "$workflow" >"${scratch}/test-removed-live.yml"
    ! workflow_calls_test "${scratch}/test-removed-live.yml" ||
        fail "planted case: the live workflow without its task test step still passed"
fi
printf '%s\n' 'jobs:' '  build-test:' '    steps:' '      - run: task build' '      - run: task validate' \
    '  security:' '    steps:' >"${scratch}/test-removed.yml"
! workflow_calls_test "${scratch}/test-removed.yml" ||
    fail "planted case: a workflow without the project test step still passed"
printf '%s\n' 'jobs:' '  build-test:' '    steps:' '      # - run: task test' \
    '  security:' '    steps:' >"${scratch}/test-commented.yml"
! workflow_calls_test "${scratch}/test-commented.yml" ||
    fail "planted case: a commented-out project test step still passed"
printf '%s\n' 'jobs:' '  build-test:' '    steps:' '      - run: task test:unit' \
    '  security:' '    steps:' >"${scratch}/test-leaf.yml"
! workflow_calls_test "${scratch}/test-leaf.yml" ||
    fail "planted case: a project test job running only a test:* target instead of task test still passed"
printf '%s\n' 'jobs:' '  build-test:' '    steps:' '      - run: task test' \
    '  security:' '    steps:' >"${scratch}/test-ok.yml"
workflow_calls_test "${scratch}/test-ok.yml" ||
    fail "planted case: a build-test job that runs task test was rejected"
printf '%s\n' 'jobs:' '  unit-tests:' '    steps:' '      - run: task test' \
    '  security:' '    steps:' >"${scratch}/test-arbitrary-job-ok.yml"
workflow_calls_test "${scratch}/test-arbitrary-job-ok.yml" ||
    fail "planted case: an arbitrarily named job (unit-tests) that runs task test was rejected"

printf '%s\n' 'tasks:' '  verify:' '    cmds:' '      - task: check' '      - task: test:suite' '      - task: test' \
    '  test:' '    # TODO: wire tests for this project' '    cmds:' '      - ./scripts/test-unit.sh' >"${scratch}/wired-test.Taskfile"
project_test_tier_active "${scratch}/wired-test.Taskfile" "${scratch}/ok.yml" ||
    fail "planted case: a Taskfile with a wired test task was not treated as active"
verify_runs_test "${scratch}/wired-test.Taskfile" ||
    fail "planted case: a verify block that runs task: test was rejected"
printf '%s\n' 'tasks:' '  verify:' '    cmds:' '      - task: check' '      - task: test:suite' \
    '  test:' '    cmds:' '      - ./scripts/test-unit.sh' >"${scratch}/verify-no-test.Taskfile"
! verify_runs_test "${scratch}/verify-no-test.Taskfile" ||
    fail "planted case: a verify block without task: test still passed"
printf '%s\n' 'jobs:' '  lint:' '    steps:' '      - run: task test:suite' \
    '  template-test:' '    steps:' '      - run: task test:template' >"${scratch}/consumer-template-test.yml"
project_test_tier_active "${scratch}/wired-test.Taskfile" "${scratch}/consumer-template-test.yml" ||
    fail "planted case: a consumer workflow defining template-test was misclassified as the template-source root"
! (guard_test_tier "${scratch}/wired-test.Taskfile" "${scratch}/consumer-template-test.yml") 2>/dev/null ||
    fail "planted case: a consumer with a template-test job and no task test step still passed"
printf '%s\n' 'jobs:' '  lint:' '    steps:' '      - run: task test:suite' \
    '  template-test:' '    steps:' '      - run: task test:template' \
    '  unit-tests:' '    steps:' '      - run: task test' >"${scratch}/consumer-template-test-with-unit.yml"
! (guard_test_tier "${scratch}/verify-no-test.Taskfile" "${scratch}/consumer-template-test-with-unit.yml") 2>/dev/null ||
    fail "planted case: a consumer with a template-test job and verify missing task: test still passed"
! (guard_test_tier "${scratch}/verify-no-test.Taskfile" "${scratch}/consumer-template-test.yml") 2>/dev/null ||
    fail "planted case: a consumer with a template-test job missing both task test and verify task: test still passed"
printf '%s\n' 'tasks:' '  verify:' '    cmds:' '      - task: check' '      - task: test:suite' '      - task: test' \
    '  test:' '    cmds:' '      - '\''echo "TODO: wire tests for this project (see docs/architecture/tests.md); test files live in tests/"'\''' >"${scratch}/unwired-test.Taskfile"
! project_test_tier_active "${scratch}/unwired-test.Taskfile" "${scratch}/ok.yml" ||
    fail "planted case: an unwired non-Node scaffold Taskfile without build-test was treated as active"
project_test_tier_active "${scratch}/unwired-test.Taskfile" "${scratch}/test-removed.yml" ||
    fail "planted case: a workflow with build-test was not treated as active"

printf '%s\n' 'jobs:' '  lint:' '    steps:' '      - run: task test:suite' '  template-test:' '    steps:' >"${scratch}/with-matrix.yml"
printf '%s\n' 'tasks:' '  verify:' '    cmds:' '      - task: check' '      - task: test:suite' '      - task: test:template' \
    '  test:suite:' '    cmds:' '      - task: test:verify-ci-parity' >"${scratch}/ok.Taskfile"
verify_runs_suite "${scratch}/ok.Taskfile" && verify_has_no_stray_tests "${scratch}/ok.Taskfile" "${scratch}/with-matrix.yml" ||
    fail "planted case: a verify that runs the suite (+ test:template, with the template-test job present) was rejected"
mkdir -p "${scratch}/template-root/template"
: >"${scratch}/template-root/copier.yml"
: >"${scratch}/template-root/template/Taskfile.yml.jinja"
cp "${scratch}/ok.Taskfile" "${scratch}/template-root/Taskfile.yml"
is_template_source_root "${scratch}/template-root/Taskfile.yml" ||
    fail "planted case: a template-source root (copier.yml + template/Taskfile.yml.jinja) was not recognized"
! project_test_tier_active "${scratch}/template-root/Taskfile.yml" "${scratch}/with-matrix.yml" ||
    fail "planted case: the template-source root was treated as a consumer project test tier"
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
