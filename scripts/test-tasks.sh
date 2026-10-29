#!/usr/bin/env bash
# test-tasks.sh — guard the Taskfile against regressions that only surface at
# run time: a Taskfile that no longer compiles, and setup tasks that fail when
# they should be safe no-ops. Run via `task test:tasks`.
#
# Setup uses isolated stubs: tests never install a global toolchain.
set -euo pipefail

repo="$(git rev-parse --show-toplevel)"
cd "$repo"

fail() {
    # shell-robustness: ok — always exits, so its status is never read
    echo "TEST FAIL: $*" >&2
    exit 1
}

test_tmp="$(mktemp -d)"
trap 'chmod -R u+w "$test_tmp" 2>/dev/null || true; rm -rf "$test_tmp"' EXIT

echo "==> Taskfile compiles (every task parses)"
if ! task --list-all >/dev/null 2>&1; then
    fail "task --list-all failed — the Taskfile does not compile"
fi

check_taskfile_paths() {
    local taskfile matches
    for taskfile in "$@"; do
        [ -f "$taskfile" ] || continue
        matches="$(grep -nHE '\{\{[^}]*\.PWD[^A-Za-z0-9_]' "$taskfile" || true)"
        [ -z "$matches" ] ||
            fail "$matches — derive paths from ROOT_DIR or TASKFILE_DIR, never PWD"
    done
}

task_block() {
    local taskfile=$1 task_name=$2
    awk -v target="  ${task_name}:" '
        $0 == target { in_task = 1; next }
        in_task && /^  [[:alnum:]_-]+:/ { exit }
        in_task { print }
    ' "$taskfile"
}

echo "==> check and test:suite expose parallel deps and the serial concurrency knob"
checked_task_groups=0
for taskfile in Taskfile.yml template/Taskfile.yml.jinja; do
    [ -f "$taskfile" ] || continue
    checked_task_groups=$((checked_task_groups + 1))

    suite_block="$(task_block "$taskfile" test:suite)"
    [ -n "$suite_block" ] || fail "${taskfile}: test:suite task not found"
    grep -Eq '^    deps:' <<<"$suite_block" ||
        fail "${taskfile}: test:suite members are not parallel deps"
    if grep -Eq '^    cmds:' <<<"$suite_block"; then
        fail "${taskfile}: test:suite has a second sequential member list"
    fi
    grep -Fq 'TASK_CONCURRENCY=1' <<<"$suite_block" ||
        fail "${taskfile}: test:suite does not document Task's serial override"

    check_block="$(task_block "$taskfile" check)"
    [ -n "$check_block" ] || fail "${taskfile}: check task not found"
    grep -Eq '^    deps:' <<<"$check_block" ||
        fail "${taskfile}: check is not defined through parallel deps"
    grep -Fq 'TASK_CONCURRENCY=1' <<<"$check_block" ||
        fail "${taskfile}: check does not document Task's serial override"
done
[ "$checked_task_groups" -gt 0 ] || fail "no Taskfile check/test:suite groups were inspected"

if [ -f template/Taskfile.yml.jinja ]; then
    template_check="$(task_block template/Taskfile.yml.jinja check)"
    grep -Fq 'lint:typescript' <<<"$template_check" ||
        fail "template Taskfile check dropped its parallel typecheck dependency"
    grep -Fq '~6 GB' <<<"$template_check" ||
        fail "template Taskfile check does not document the parallel memory floor"
fi

for doc in docs/architecture/tests.md template/docs/architecture/tests.md.jinja; do
    [ -f "$doc" ] || continue
    grep -Fq 'TASK_CONCURRENCY=1' "$doc" ||
        fail "${doc}: serial Task concurrency setting is undocumented"
    doc_taskfile=Taskfile.yml
    case "$doc" in
    template/docs/architecture/tests.md.jinja)
        doc_taskfile=template/Taskfile.yml.jinja
        ;;
    esac
    if [ -f "$doc_taskfile" ]; then
        doc_check="$(task_block "$doc_taskfile" check)"
        if grep -Fq 'lint:typescript' <<<"$doc_check"; then
            grep -Fq '6 GB' "$doc" ||
                fail "${doc}: parallel check memory floor is undocumented"
        fi
    fi
done

echo "==> Task concurrency setting serializes dependency fan-out without changing results"
concurrency_fixture="${test_tmp}/task-concurrency-fixture"
mkdir -p "$concurrency_fixture"
cat >"$concurrency_fixture/Taskfile.yml" <<'EOF'
version: "3"
tasks:
  check:
    deps: [eslint, typecheck]
  test:suite:
    deps: [suite:alpha, suite:beta]
  eslint:
    cmds:
      - ./member.sh eslint
  typecheck:
    cmds:
      - ./member.sh typecheck
  suite:alpha:
    cmds:
      - ./member.sh suite-alpha
  suite:beta:
    cmds:
      - ./member.sh suite-beta
EOF
cat >"$concurrency_fixture/member.sh" <<'EOF'
#!/usr/bin/env bash
set -eu
name=$1
case "$name" in
    eslint) peer=typecheck ;;
    typecheck) peer=eslint ;;
    suite-alpha) peer=suite-beta ;;
    suite-beta) peer=suite-alpha ;;
    *) echo "unknown concurrency fixture member: $name" >&2; exit 2 ;;
esac
if [ "${DELAY_START_FOR:-}" = "$name" ]; then
    sleep "${DELAY_START_SECONDS:-0.5}"
fi
: >"$RUN_DIR/started-$name"
if [ "${EXPECT_OVERLAP:-no}" = yes ]; then
    waited=0
    while [ ! -f "$RUN_DIR/started-$peer" ]; do
        if [ "$waited" -ge 200 ]; then
            echo "timed out waiting for peer $peer to start" >&2
            exit 10
        fi
        sleep 0.1
        waited=$((waited + 1))
    done
    : >"$RUN_DIR/overlap"
else
    if mkdir "$RUN_DIR/active" 2>/dev/null; then
        sleep 0.3
        rmdir "$RUN_DIR/active"
    else
        : >"$RUN_DIR/overlap"
    fi
fi
if [ "${FAIL_TASK:-}" = "$name" ]; then exit 9; fi
EOF
chmod +x "$concurrency_fixture/member.sh"

run_concurrency_case() {
    local concurrency=$1 task_name=$2 failing_task=$3 expected=$4 overlap=$5 run_name=$6 members=$7
    local delay_task=${8:-} delay_seconds=${9:-0.5}
    local run_dir="${concurrency_fixture}/${run_name}" rc member
    mkdir -p "$run_dir"
    if TASK_CONCURRENCY="$concurrency" EXPECT_OVERLAP="$overlap" TASK_FAILFAST=0 \
        RUN_DIR="$run_dir" FAIL_TASK="$failing_task" DELAY_START_FOR="$delay_task" \
        DELAY_START_SECONDS="$delay_seconds" \
        task --dir "$concurrency_fixture" --color=false "$task_name" >"$run_dir/output" 2>&1; then
        rc=0
    else
        rc=$?
    fi

    if [ "$expected" = pass ]; then
        [ "$rc" -eq 0 ] || fail "${run_name}: expected pass with TASK_CONCURRENCY=${concurrency}: $(cat "$run_dir/output")"
    else
        [ "$rc" -ne 0 ] || fail "${run_name}: a failing dependency passed with TASK_CONCURRENCY=${concurrency}"
    fi
    for member in $members; do
        [ -f "$run_dir/started-${member}" ] ||
            fail "${run_name}: dependency ${member} did not run with TASK_CONCURRENCY=${concurrency}"
    done
    if [ "$overlap" = yes ]; then
        [ -f "$run_dir/overlap" ] || fail "${run_name}: default parallel dependencies did not overlap"
    else
        [ ! -e "$run_dir/overlap" ] || fail "${run_name}: TASK_CONCURRENCY=1 allowed dependencies to overlap"
    fi
}

run_concurrency_case 0 check '' pass yes check-parallel-pass 'eslint typecheck' typecheck 0.5
run_concurrency_case 1 check '' pass no check-serial-pass 'eslint typecheck'
run_concurrency_case 0 check typecheck fail yes check-parallel-fail 'eslint typecheck'
run_concurrency_case 1 check typecheck fail no check-serial-fail 'eslint typecheck'
run_concurrency_case 0 test:suite '' pass yes suite-parallel-pass 'suite-alpha suite-beta'
run_concurrency_case 1 test:suite '' pass no suite-serial-pass 'suite-alpha suite-beta'
run_concurrency_case 0 test:suite suite-beta fail yes suite-parallel-fail 'suite-alpha suite-beta'
run_concurrency_case 1 test:suite suite-beta fail no suite-serial-fail 'suite-alpha suite-beta'

echo "==> Taskfile paths derive from ROOT_DIR or TASKFILE_DIR, never PWD"
# Assemble the copier marker so this verbatim script ships without an
# unrendered marker, just like the path-safe formatter fixture below.
taskfile_jinja_open='[%'
template_taskfiles="template/${taskfile_jinja_open} if use_foreman %]taskfiles${taskfile_jinja_open} endif %]"
check_taskfile_paths Taskfile.yml taskfiles/*.yml template/Taskfile.yml.jinja "$template_taskfiles"/*.yml

echo "==> Taskfile PWD guard rejects bare, trimmed and piped references (negative controls)"
pwd_taskfile="${test_tmp}/Taskfile.yml"
for pwd_reference in '{{.PWD}}' '{{ .PWD }}' '{{- .PWD -}}' '{{.PWD | dir}}'; do
    printf '%s\n' 'version: "3"' 'tasks:' '  probe:' '    cmds:' \
        "      - echo \"$pwd_reference\"" >"$pwd_taskfile"
    out=$(check_taskfile_paths "$pwd_taskfile" 2>&1) && rc=0 || rc=$?
    [ "$rc" -ne 0 ] || fail "Taskfile PWD guard accepted $pwd_reference"
    case "$out" in
    *"${pwd_taskfile}:5:"*"${pwd_reference}"*'never PWD'*) ;;
    *) fail "Taskfile PWD guard failed for the wrong reason: $out" ;;
    esac
done

echo "==> Taskfile PWD guard accepts PWD_ROOT and shell PWD references"
cat >"$pwd_taskfile" <<'EOF'
version: "3"
tasks:
  probe:
    cmds:
      - echo "{{.PWD_ROOT}} $PWD"
EOF
out=$(check_taskfile_paths "$pwd_taskfile" 2>&1) && rc=0 || rc=$?
[ "$rc" -eq 0 ] || fail "Taskfile PWD guard rejected PWD_ROOT or shell PWD: $out"

echo "==> closing-keyword preflight delegates to a linted script, not inline Taskfile bash"
# The logic lives in scripts/guard-closing-keywords.sh so shellcheck/shfmt see
# it (harmon-init#1196); inline `cmds:` strings are invisible to lint:shell.
for taskfile in Taskfile.yml template/Taskfile.yml.jinja; do
    [ -f "$taskfile" ] || continue
    block="$(awk '
        $0 == "  guard:closing-keywords:" { inblock = 1; next }
        inblock && /^  [a-zA-Z0-9]/ { inblock = 0 }
        inblock { print }
    ' "$taskfile")"
    [ -n "$block" ] || fail "${taskfile}: guard:closing-keywords task not found"
    grep -Fq './scripts/guard-closing-keywords.sh' <<<"$block" ||
        fail "${taskfile}: guard:closing-keywords does not call scripts/guard-closing-keywords.sh"
    if grep -Fq 'git merge-base' <<<"$block"; then
        fail "${taskfile}: guard:closing-keywords re-inlined shell that lint:shell cannot see"
    fi
done

echo "==> closing-keyword preflight mirrors the API cap and supports pre-PR metadata"
for guard in scripts/guard-closing-keywords.sh template/scripts/guard-closing-keywords.sh; do
    [ -f "$guard" ] || continue
    grep -Fq 'git merge-base "$base_sha" "$head_sha"' "$guard" ||
        fail "${guard}: closing-keyword guard does not resolve the merge base"
    grep -Fq 'git rev-list --count "${merge_base}..${head_sha}"' "$guard" ||
        fail "${guard}: closing-keyword guard does not mirror the workflow commit cap"
    grep -Fq 'git log --format=%B "${merge_base}..${head_sha}"' "$guard" ||
        fail "${guard}: closing-keyword guard does not scan merge-base-to-head only"
    if grep -Fq '${BASE_SHA:-origin/main}...${HEAD_SHA:-HEAD}' "$guard"; then
        fail "${guard}: closing-keyword guard still scans the symmetric difference"
    fi
    grep -Fq '[ -z "${PR_TITLE+x}" ] || [ -z "${PR_BODY+x}" ]' "$guard" ||
        fail "${guard}: closing-keyword guard does not distinguish unset metadata from an empty body"
    grep -Fq 'gh_rest_paginate_array "repos/${repo}/pulls?state=open&sort=updated&direction=desc" 100' "$guard" ||
        fail "${guard}: closing-keyword guard does not list open PRs through the bounded helper, so a failed listing cannot be told from a missing PR"
done

echo "==> every REST pagination caller passes an explicit bound"
# The helpers refuse a missing MAX_ITEMS and cap every walk at GH_REST_MAX_PAGES,
# but a caller that passes 0 still asks for every page under that ceiling. The
# session scripts' reads are all answerable from a bounded window, so each one
# names its bound here (challenge r1: the REST rewrite had turned bounded single
# reads into whole-repository walks).
for status in scripts/status.sh template/scripts/status.sh; do
    [ -f "$status" ] || continue
    grep -Fq '"repos/${status_repo}/pulls?state=open&sort=updated&direction=desc" 10' "$status" ||
        fail "${status}: open-PR list is not bounded to 10"
    grep -Fq '"repos/${OWNER}/${REPO}/pulls?state=all&sort=updated&direction=desc" 100' "$status" ||
        fail "${status}: renovate heuristic is not bounded to the 100 most recent PRs"
    grep -Fq '"repos/${OWNER}/${REPO}/pulls/comments?sort=updated&direction=desc" 100' "$status" ||
        fail "${status}: coderabbit heuristic is not bounded to the 100 most recent review comments"
done
for audit in scripts/audit-session-artifacts.sh template/scripts/audit-session-artifacts.sh; do
    [ -f "$audit" ] || continue
    grep -Fq '"repos/${gh_repo}/pulls?state=closed&sort=updated&direction=desc" "$pr_limit"' "$audit" ||
        fail "${audit}: closed-PR scan does not pass pr_limit as its pagination bound"
done
for lib in scripts/lib/gh-rest.sh template/scripts/lib/gh-rest.sh; do
    [ -f "$lib" ] || continue
    grep -Fq 'GH_REST_MAX_PAGES:-10' "$lib" ||
        fail "${lib}: the page ceiling no longer defaults to 10"
done

echo "==> the closing-keyword workflow fetches every library the guard sources"
# The workflow runs the guard from a FETCH, not a checkout: it pulls
# scripts/check-closing-keywords.sh out of the contents API and executes it. The
# moment that guard grew `. "${script_dir}/lib/gh-rest.sh"`, a one-file fetch
# became a program that dies on a missing file — and no PR's own CI can catch
# that, because GitHub takes the workflow definition from the DEFAULT BRANCH:
# every PR keeps running the pair already on main, and the new script and the
# new workflow only meet after the merge, in the NEXT PR's required check. So the
# pairing is asserted here instead — each library the guard sources is fetched
# from the same parameterised ref, written where ${script_dir} resolves it, and
# removed by the step's trap.
for pair in \
    'scripts/check-closing-keywords.sh|.github/workflows/closing-keywords.yml' \
    'template/scripts/check-closing-keywords.sh|template/.github/workflows/closing-keywords.yml.jinja'; do
    guard_script="${pair%%|*}"
    workflow="${pair#*|}"
    { [ -f "$guard_script" ] && [ -f "$workflow" ]; } || continue
    trap_line="$(grep -F "trap 'rm -f" "$workflow" || true)"
    sourced="$(sed -n 's|^\. "[$]{script_dir}/\([^"]*\)".*|\1|p' "$guard_script")"
    [ -n "$sourced" ] ||
        fail "${guard_script}: no \${script_dir} library is sourced, so this assertion checks nothing — remove it, or fix the extraction"
    while IFS= read -r lib; do
        grep -Fq "contents/scripts/${lib}?ref=\$1" "$workflow" ||
            fail "${workflow}: ${guard_script} sources ${lib}, but the workflow never fetches scripts/${lib} from the ref it fetches the guard from — the guard it runs would die on a missing file"
        grep -Fq "> ./${lib}" "$workflow" ||
            fail "${workflow}: scripts/${lib} is not written to ./${lib}, where the guard's \${script_dir}/${lib} resolves"
        grep -Fq "./${lib}" <<<"$trap_line" ||
            fail "${workflow}: ./${lib} is fetched into the workspace and never removed by the step's trap"
        libdir="$(dirname "$lib")"
        if [ "$libdir" != . ] &&
            ! grep -Fq "rmdir ./${libdir}" <<<"$trap_line" &&
            ! grep -Fq "rm -rf ./${libdir}" <<<"$trap_line"; then
            fail "${workflow}: the trap removes ./${lib} but leaves the ./${libdir} directory behind"
        fi
    done <<<"$sourced"
done

guard_bin="${test_tmp}/closing-keywords-bin"
guard_git_args="${test_tmp}/closing-keywords-git-args"
guard_gh_args="${test_tmp}/closing-keywords-gh-args"
guard_issues="${test_tmp}/closing-keywords-issues"
mkdir -p "$guard_bin" "$guard_issues"
printf '%s\n' '- [x] complete' >"${guard_issues}/acme_repo__1.md"
printf '%s\n' '- [ ] unfinished' >"${guard_issues}/acme_repo__2.md"
cat >"${guard_bin}/git" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
merge-base)
    [ -z "${GIT_MERGE_BASE_FAIL:-}" ] || exit 1
    printf '%s\n' merge-base
    ;;
rev-list) printf '%s\n' "${GIT_COMMIT_COUNT:-1}" ;;
rev-parse) printf '%s\n' headsha ;;
branch) printf '%s\n' feature ;;
log) printf '%s\n' "$@" >"${GIT_ARGS:?}" ;;
*) exit 1 ;;
esac
EOF
cat >"${guard_bin}/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GH_ARGS:?}"
[ -z "${GH_PR_LIST_FAIL:-}" ] || exit 1
case "${1:-} ${2:-}" in
"api repos/acme/repo/pulls?state=open&sort=updated&direction=desc&per_page=100&page=1")
    if [ -n "${GH_NO_PR:-}" ]; then
        printf '%s\n' '[]'
    else
        printf '%s\n' '[{"title":"Fixes #2","body":"","head":{"sha":"headsha","ref":"feature"}}]'
    fi
    ;;
*) exit 1 ;;
esac
EOF
chmod +x "${guard_bin}/git" "${guard_bin}/gh"

out=$(env -u PR_TITLE -u PR_BODY PATH="${guard_bin}:${PATH}" \
    GIT_ARGS="$guard_git_args" GH_ARGS="$guard_gh_args" GH_REPO=acme/repo \
    ISSUE_BODY_DIR="$guard_issues" BASE_SHA=base HEAD_SHA=head \
    task guard:closing-keywords 2>&1) && rc=0 || rc=$?
[ "$rc" -ne 0 ] || fail "closing-keyword guard did not use fetched PR metadata: $out"
grep -Fxq 'merge-base..head' "$guard_git_args" ||
    fail "closing-keyword guard did not scan exactly merge-base..head"
[ "$(grep -c '^api repos/acme/repo/pulls?state=open&sort=updated&direction=desc&per_page=100&page=1$' "$guard_gh_args")" -eq 1 ] ||
    fail "closing-keyword guard did not fetch missing PR metadata atomically"

echo "==> native closing-keyword preflight rejects cross-repository references without API reads"
guard_gh_calls="$(wc -l <"$guard_gh_args" | tr -d ' ')"
out=$(PR_TITLE='fix: local change' PR_BODY='Closes acme/other#123' \
    PATH="${guard_bin}:${PATH}" GIT_ARGS="$guard_git_args" GH_ARGS="$guard_gh_args" \
    GH_REPO=acme/repo BASE_SHA=base HEAD_SHA=head \
    task guard:closing-keywords 2>&1) && rc=0 || rc=$?
[ "$rc" -ne 0 ] || fail "native closing-keyword preflight accepted a cross-repository closing reference"
case "$out" in
*'acme/other#123 is in another repository; use Refs instead of a closing keyword'*) ;;
*) fail "native closing-keyword preflight rejected the reference for the wrong reason: $out" ;;
esac
[ "$(wc -l <"$guard_gh_args" | tr -d ' ')" -eq "$guard_gh_calls" ] ||
    fail "native cross-repository closing rejection attempted an API read"

out=$(env -u PR_TITLE -u PR_BODY PATH="${guard_bin}:${PATH}" \
    GH_NO_PR=1 GIT_ARGS="$guard_git_args" GH_ARGS="$guard_gh_args" GH_REPO=acme/repo \
    ISSUE_BODY_DIR="$guard_issues" BASE_SHA=base HEAD_SHA=head \
    task guard:closing-keywords 2>&1) && rc=0 || rc=$?
[ "$rc" -eq 0 ] || fail "closing-keyword guard rejected a branch before its PR exists: $out"
case "$out" in
*'checking commits with inert pre-PR metadata'*) ;;
*) fail "closing-keyword guard did not explain its pre-PR metadata fallback: $out" ;;
esac

out=$(env -u PR_TITLE -u PR_BODY PATH="${guard_bin}:${PATH}" \
    GIT_MERGE_BASE_FAIL=1 GIT_ARGS="$guard_git_args" GH_ARGS="$guard_gh_args" \
    GH_REPO=acme/repo ISSUE_BODY_DIR="$guard_issues" BASE_SHA=base HEAD_SHA=head \
    task guard:closing-keywords 2>&1) && rc=0 || rc=$?
[ "$rc" -ne 0 ] || fail "closing-keyword guard accepted an unresolved merge base"
case "$out" in
*'could not resolve merge-base'*) ;;
*) fail "closing-keyword guard reported the wrong merge-base failure: $out" ;;
esac

out=$(env -u PR_TITLE -u PR_BODY PATH="${guard_bin}:${PATH}" \
    GH_PR_LIST_FAIL=1 GIT_ARGS="$guard_git_args" GH_ARGS="$guard_gh_args" \
    GH_REPO=acme/repo ISSUE_BODY_DIR="$guard_issues" BASE_SHA=base HEAD_SHA=head \
    task guard:closing-keywords 2>&1) && rc=0 || rc=$?
[ "$rc" -ne 0 ] || fail "closing-keyword guard accepted unreadable PR metadata"
case "$out" in
*'supply both PR_TITLE and PR_BODY'*) ;;
*) fail "closing-keyword guard reported the wrong metadata failure: $out" ;;
esac

out=$(PR_TITLE='' PR_BODY='' PATH="${guard_bin}:${PATH}" GIT_COMMIT_COUNT=251 \
    GIT_ARGS="$guard_git_args" GH_ARGS="$guard_gh_args" GH_REPO=acme/repo \
    ISSUE_BODY_DIR="$guard_issues" BASE_SHA=base HEAD_SHA=head \
    task guard:closing-keywords 2>&1) && rc=0 || rc=$?
[ "$rc" -ne 0 ] || fail "closing-keyword guard accepted a range beyond the workflow API cap"
case "$out" in
*'exceeding the workflow'*) ;;
*) fail "closing-keyword guard reported the wrong commit-cap failure: $out" ;;
esac

echo "==> brew-less setup requires a positive toolchain marker"
brewless_bin="${test_tmp}/brewless-bin"
toolchain_manifest="${test_tmp}/toolchain-manifest.json"
mkdir -p "$brewless_bin"
# Restrict PATH rather than assuming the runner has no Homebrew or Node.
for tool in bash dirname; do
    ln -s "$(command -v "$tool")" "${brewless_bin}/${tool}"
done
printf '%s\n' '{}' >"$toolchain_manifest"
for helper in scripts/install-brewfile.sh scripts/bootstrap-pnpm.sh; do
    [ -x "$helper" ] || continue
    out=$(PATH="$brewless_bin" HARMON_TOOLCHAIN_MANIFEST="$toolchain_manifest" \
        "$helper" 2>&1) && rc=0 || rc=$?
    [ "$rc" -eq 0 ] || fail "$helper rejected the toolchain manifest: $out"
    out=$(PATH="$brewless_bin" HARMON_TOOLCHAIN_MANIFEST="${test_tmp}/absent-manifest" \
        "$helper" 2>&1) && rc=0 || rc=$?
    [ "$rc" -ne 0 ] || fail "$helper silently skipped setup on a brew-less host"
    case "$out" in
    *"Homebrew not found"*"task bootstrap"*) ;;
    *) fail "$helper failed without setup instructions: $out" ;;
    esac
done
if [ -x scripts/bootstrap-pnpm.sh ]; then
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"${brewless_bin}/node"
    chmod +x "${brewless_bin}/node"
    out=$(PATH="$brewless_bin" HARMON_TOOLCHAIN_MANIFEST="${test_tmp}/absent-manifest" \
        ./scripts/bootstrap-pnpm.sh 2>&1) && rc=0 || rc=$?
    [ "$rc" -ne 0 ] || fail "Node alone allowed an unmarked brew-less bootstrap"
    case "$out" in
    *"Homebrew not found"*"task bootstrap"*) ;;
    *) fail "Node-only bootstrap failed without setup instructions: $out" ;;
    esac
fi
# Generated installs must reach dependency installation and hook setup. Stubs
# prove task wiring; a real consumer devcontainer install remains a QA check.
if [ ! -f scripts/install-copier.sh ]; then
    install_marker="${test_tmp}/dependencies-installed"
    for tool in task; do
        ln -s "$(command -v "$tool")" "${brewless_bin}/${tool}"
    done
    for stub in pnpm uv lefthook; do
        printf '%s\n' '#!/usr/bin/env bash' 'echo "$0 $*" >>"${INSTALL_MARKER:?}"' >"${brewless_bin}/${stub}"
        chmod +x "${brewless_bin}/${stub}"
    done
    PATH="$brewless_bin" HARMON_TOOLCHAIN_MANIFEST="$toolchain_manifest" \
        INSTALL_MARKER="$install_marker" task install >/dev/null ||
        fail "rendered task install failed with the toolchain manifest"
    grep -q 'lefthook install' "$install_marker" || fail "rendered install never installed hooks"
    if [ -f package.json ]; then
        grep -q 'pnpm install' "$install_marker" || fail "rendered install never installed Node dependencies"
    fi
    if [ -f pyproject.toml ]; then
        grep -q 'uv sync' "$install_marker" || fail "rendered install never installed Python dependencies"
    fi
    if PATH="$brewless_bin" HARMON_TOOLCHAIN_MANIFEST="${test_tmp}/absent-manifest" \
        INSTALL_MARKER="$install_marker" task install >/dev/null 2>&1; then
        fail "rendered task install succeeded on an unmarked brew-less host"
    fi
fi

echo "==> bootstrap is a no-op when Homebrew is already installed"
# Run against STUBS, never the real toolchain. `test:tasks` is part of `verify`,
# and in a generated use_node repo `bootstrap` runs `brew install node` plus
# the pnpm bootstrap helper — so invoking it for real made running the tests mutate
# the developer's machine, and CI too (GitHub's ubuntu images carry linuxbrew on
# PATH). A test must not install a global toolchain as a side effect.
#
# Stubbing also removes the old `command -v brew` skip, so the assertion now
# runs everywhere instead of silently doing nothing on most CI runners.
bootstrap_bin="${test_tmp}/bootstrap-bin"
installer_marker="${test_tmp}/homebrew-installer-fetched"
brew_prefix="${test_tmp}/homebrew"
pnpm_prefix="${brew_prefix}/opt/pnpm"
mkdir -p "$bootstrap_bin"
for stub in npm node pnpm; do
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"${bootstrap_bin}/${stub}"
    chmod +x "${bootstrap_bin}/${stub}"
done
mkdir -p "${brew_prefix}/bin" "${pnpm_prefix}/bin"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"${pnpm_prefix}/bin/pnpm"
chmod +x "${pnpm_prefix}/bin/pnpm"
ln -s "${pnpm_prefix}/bin/pnpm" "${brew_prefix}/bin/pnpm"
cat >"${bootstrap_bin}/brew" <<EOF
#!/usr/bin/env bash
case "\$*" in
--prefix) printf '%s\\n' "${brew_prefix}" ;;
"--prefix pnpm") printf '%s\\n' "${pnpm_prefix}" ;;
esac
exit 0
EOF
chmod +x "${bootstrap_bin}/brew"
# Fake curl records any attempt to fetch the Homebrew installer, so we can prove
# the `command -v brew` guard short-circuited instead of re-running setup.
cat >"${bootstrap_bin}/curl" <<EOF
#!/usr/bin/env bash
for arg in "\$@"; do
    case "\$arg" in
    *Homebrew/install*) : >"${installer_marker}" ;;
    esac
done
exit 0
EOF
chmod +x "${bootstrap_bin}/curl"

if ! PATH="${bootstrap_bin}:${PATH}" task bootstrap >/dev/null 2>&1; then
    fail "task bootstrap failed with brew already on PATH"
fi
if [ -f "$installer_marker" ]; then
    fail "task bootstrap fetched the Homebrew installer despite brew being on PATH"
fi

if [ -x scripts/bootstrap-pnpm.sh ]; then
    echo "==> pnpm bootstrap migrates legacy npm-global ownership to Homebrew"
    pnpm_test_bin="${test_tmp}/pnpm-test-bin"
    pnpm_brew_prefix="${test_tmp}/pnpm-homebrew"
    pnpm_cellar="${pnpm_brew_prefix}/Cellar/pnpm/11.0.0"
    pnpm_opt="${pnpm_brew_prefix}/opt/pnpm"
    pnpm_legacy="${pnpm_brew_prefix}/lib/node_modules/pnpm"
    pnpm_uninstall_marker="${test_tmp}/pnpm-uninstalled"
    pnpm_install_entry_marker="${test_tmp}/pnpm-install-entry"
    mkdir -p "$pnpm_test_bin" "${pnpm_brew_prefix}/bin" "${pnpm_brew_prefix}/opt" "${pnpm_cellar}/bin" "$pnpm_legacy"
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"${pnpm_cellar}/bin/pnpm"
    chmod +x "${pnpm_cellar}/bin/pnpm"
    ln -s "$pnpm_cellar" "$pnpm_opt"
    ln -s "${pnpm_legacy}/bin/pnpm.cjs" "${pnpm_brew_prefix}/bin/pnpm"
    cat >"${pnpm_test_bin}/brew" <<EOF
#!/usr/bin/env bash
case "\$*" in
"install node") : >"${pnpm_install_entry_marker}" ;;
"install pnpm") exit 1 ;;
"list --formula pnpm") exit 0 ;;
bundle\ --file=*)
    case "\$(readlink "${pnpm_brew_prefix}/bin/pnpm")" in
    "${pnpm_legacy}"/*) exit 1 ;;
    esac
    ;;
--prefix) printf '%s\\n' "${pnpm_brew_prefix}" ;;
"--prefix pnpm") printf '%s\\n' "${pnpm_opt}" ;;
"unlink pnpm")
    [ ! -L "${pnpm_brew_prefix}/bin/pnpm" ] || unlink "${pnpm_brew_prefix}/bin/pnpm"
    ;;
"link --overwrite pnpm")
    ln -s "${pnpm_cellar}/bin/pnpm" "${pnpm_brew_prefix}/bin/pnpm"
    ;;
*) exit 1 ;;
esac
EOF
    chmod +x "${pnpm_test_bin}/brew"
    cat >"${pnpm_test_bin}/npm" <<EOF
#!/usr/bin/env bash
[ "\$*" = "uninstall --global --prefix ${pnpm_brew_prefix} pnpm" ] || exit 1
rmdir "${pnpm_legacy}"
: >"${pnpm_uninstall_marker}"
EOF
    chmod +x "${pnpm_test_bin}/npm"
    for stub in pnpm lefthook uv; do
        printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"${pnpm_test_bin}/${stub}"
        chmod +x "${pnpm_test_bin}/${stub}"
    done
    printf '%s\n' '#!/usr/bin/env bash' 'exit 127' >"${pnpm_test_bin}/realpath"
    chmod +x "${pnpm_test_bin}/realpath"
    PATH="${pnpm_test_bin}:${PATH}" ./scripts/bootstrap-pnpm.sh >/dev/null
    [ -f "$pnpm_uninstall_marker" ] ||
        fail "pnpm bootstrap did not retire the Homebrew-prefix npm package"
    [ "$(readlink "${pnpm_brew_prefix}/bin/pnpm")" = "${pnpm_cellar}/bin/pnpm" ] ||
        fail "pnpm bootstrap did not transfer executable ownership to Homebrew"
    if [ "$(grep -c -- './scripts/bootstrap-pnpm.sh' Taskfile.yml)" -ge 2 ]; then
        unlink "$pnpm_install_entry_marker"
        unlink "${pnpm_brew_prefix}/bin/pnpm"
        mkdir -p "$pnpm_legacy"
        ln -s "${pnpm_legacy}/bin/pnpm.cjs" "${pnpm_brew_prefix}/bin/pnpm"
        PATH="${pnpm_test_bin}:${PATH}" task install >/dev/null
        [ -f "$pnpm_install_entry_marker" ] ||
            fail "task install did not invoke the pnpm ownership migration"
    fi
fi

if [ -n "${HARMON_TEST_PNPM_BOOTSTRAP_ONLY:-}" ]; then
    exit 0
fi

echo "==> Markdown lint excludes lane artifact paths regardless of Git tracking"
markdown_repo="${test_tmp}/markdown-repo"
mkdir -p "${markdown_repo}/.lane"
git -C "$markdown_repo" init -q
printf '%s\n' '.lane/' '.lane-report.md' >>"${markdown_repo}/.git/info/exclude"
printf '%s\n' '# Fixture' >"${markdown_repo}/valid.md"
printf '%s\n' '| A | B |' '| --- | --- |' '| one |' >"${markdown_repo}/.lane-report.md"
cp "${markdown_repo}/.lane-report.md" "${markdown_repo}/.lane/x.md"
printf '%s\n' '{"unformatted":true}' >"${markdown_repo}/.lane/x.json"
(
    cd "$markdown_repo"
    "$repo/scripts/markdownlint.sh" check
) || fail "Markdown lint scanned untracked lane artifacts"
git -C "$markdown_repo" add -f .lane/x.md
(
    cd "$markdown_repo"
    "$repo/scripts/markdownlint.sh" check
) || fail "Markdown lint scanned tracked files under .lane/"
# A non-lane Markdown file must still be checked, including spaces in paths.
cp "${markdown_repo}/.lane/x.md" "${markdown_repo}/bad file.md"
out=$(
    cd "$markdown_repo"
    "$repo/scripts/markdownlint.sh" check 2>&1
) && rc=0 || rc=$?
[ "$rc" -ne 0 ] || fail "Markdown lint skipped non-lane Markdown"
case "$out" in
*'MD056'*) ;;
*) fail "non-lane Markdown failed for the wrong reason: $out" ;;
esac
rm "${markdown_repo}/bad file.md"

prettier_ignore="$repo/.prettierignore"
if [ ! -f "$prettier_ignore" ]; then
    prettier_ignore="$repo/template/${taskfile_jinja_open} if use_node %].prettierignore${taskfile_jinja_open} endif %].jinja"
fi
if [ -f "$prettier_ignore" ]; then
    echo "==> Prettier excludes lane reports and envelopes"
    cp "$prettier_ignore" "${markdown_repo}/.prettierignore"
    prettier_bin=""
    if prettier_bin="$(command -v prettier)"; then
        :
    elif [ -x "$repo/node_modules/.bin/prettier" ]; then
        prettier_bin="$repo/node_modules/.bin/prettier"
    fi
    if [ -n "$prettier_bin" ]; then
        (
            cd "$markdown_repo"
            "$prettier_bin" --check .
        ) || fail "Prettier scanned lane artifacts"
        cp "${markdown_repo}/.lane/x.json" "${markdown_repo}/bad.json"
        out=$(
            cd "$markdown_repo"
            "$prettier_bin" --check . 2>&1
        ) && rc=0 || rc=$?
        [ "$rc" -ne 0 ] || fail "Prettier fixture did not detect nonignored unformatted JSON"
        case "$out" in
        *'bad.json'*) ;;
        *) fail "Prettier negative control failed for the wrong reason: $out" ;;
        esac
    else
        grep -Fxq '.lane/' "${markdown_repo}/.prettierignore" ||
            fail "Prettier ignore entries omit .lane/"
        grep -Fxq '.lane-report.md' "${markdown_repo}/.prettierignore" ||
            fail "Prettier ignore entries omit .lane-report.md"
        echo "SKIP: live Prettier check — Prettier is not installed; ignore entries verified."
    fi
fi

echo "==> Semgrep wrapper preserves explicit scan targets"
semgrep_bin="${test_tmp}/semgrep-bin"
semgrep_args="${test_tmp}/semgrep-args"
semgrep_env="${test_tmp}/semgrep-env"
mkdir -p "$semgrep_bin"
cat >"${semgrep_bin}/uvx" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"${SEMGREP_ARGS:?}"
if [ -n "${SEMGREP_ENV:-}" ]; then
    printf 'UV_TOOL_DIR=%s\nUV_CACHE_DIR=%s\nUV_PYTHON_INSTALL_DIR=%s\n' "${UV_TOOL_DIR:-}" "${UV_CACHE_DIR:-}" "${UV_PYTHON_INSTALL_DIR:-}" >"$SEMGREP_ENV"
fi
EOF
chmod +x "${semgrep_bin}/uvx"
PATH="${semgrep_bin}:${PATH}" SEMGREP_ARGS="$semgrep_args" \
    ./scripts/run-semgrep.sh scripts
[ "$(sed -n 1p "$semgrep_args")" = "--python" ] && [ "$(sed -n 2p "$semgrep_args")" = "3.14" ] ||
    fail "Semgrep wrapper did not select its compatible interpreter"
[ "$(tail -n 1 "$semgrep_args")" = "scripts" ] ||
    fail "Semgrep wrapper did not preserve the explicit target"
if grep -Fxq . "$semgrep_args"; then
    fail "Semgrep wrapper appended a repository-wide target"
fi

echo "==> Semgrep wrapper falls back when default uv dirs are read-only and fails clearly when none is writable"
semgrep_ro_home="${test_tmp}/semgrep-ro-home"
semgrep_ro_xdg_data="${test_tmp}/semgrep-ro-xdg-data"
semgrep_ro_xdg_cache="${test_tmp}/semgrep-ro-xdg-cache"
semgrep_ro_tmp="${test_tmp}/semgrep-ro-tmp"
semgrep_tmp="${test_tmp}/semgrep-tmp"
semgrep_custom_tools="${test_tmp}/semgrep-custom-tools"
semgrep_custom_cache="${test_tmp}/semgrep-custom-cache"
semgrep_custom_python="${test_tmp}/semgrep-custom-python"
mkdir -p "$semgrep_ro_home" "$semgrep_ro_xdg_data" "$semgrep_ro_xdg_cache" "$semgrep_ro_tmp" "$semgrep_tmp"
chmod 500 "$semgrep_ro_home" "$semgrep_ro_xdg_data" "$semgrep_ro_xdg_cache" "$semgrep_ro_tmp"
if [ -w "$semgrep_ro_home" ]; then
    # Root with CAP_DAC_OVERRIDE ignores 0500 on directories; regular files still block mkdir -p.
    chmod 700 "$semgrep_ro_home" "$semgrep_ro_xdg_data" "$semgrep_ro_xdg_cache" "$semgrep_ro_tmp"
    rm -rf "$semgrep_ro_home" "$semgrep_ro_xdg_data" "$semgrep_ro_xdg_cache" "$semgrep_ro_tmp"
    : >"$semgrep_ro_home"
    : >"$semgrep_ro_xdg_data"
    : >"$semgrep_ro_xdg_cache"
    : >"$semgrep_ro_tmp"
fi

rm -f "$semgrep_args" "$semgrep_env"
env -u UV_PYTHON_INSTALL_DIR -u UV_TOOL_DIR -u UV_CACHE_DIR -u XDG_DATA_HOME -u XDG_CACHE_HOME \
    HOME="$semgrep_ro_home" TMPDIR="$semgrep_tmp" \
    PATH="${semgrep_bin}:${PATH}" SEMGREP_ARGS="$semgrep_args" SEMGREP_ENV="$semgrep_env" \
    ./scripts/run-semgrep.sh scripts
[ "$(tail -n 1 "$semgrep_args")" = "scripts" ] ||
    fail "Semgrep wrapper lost explicit target under read-only HOME fallback"
expected_fallback_tools="${semgrep_tmp}/uv-$(id -u)/tools"
expected_fallback_cache="${semgrep_tmp}/uv-$(id -u)/cache"
expected_fallback_python="${semgrep_tmp}/uv-$(id -u)/python"
grep -Fxq "UV_TOOL_DIR=${expected_fallback_tools}" "$semgrep_env" ||
    fail "Semgrep wrapper did not export fallback UV_TOOL_DIR under read-only HOME: $(cat "$semgrep_env")"
grep -Fxq "UV_CACHE_DIR=${expected_fallback_cache}" "$semgrep_env" ||
    fail "Semgrep wrapper did not export fallback UV_CACHE_DIR under read-only HOME: $(cat "$semgrep_env")"
grep -Fxq "UV_PYTHON_INSTALL_DIR=${expected_fallback_python}" "$semgrep_env" ||
    fail "Semgrep wrapper did not export fallback UV_PYTHON_INSTALL_DIR under read-only HOME"

rm -f "$semgrep_args" "$semgrep_env"
env -u UV_PYTHON_INSTALL_DIR -u UV_TOOL_DIR -u UV_CACHE_DIR \
    XDG_DATA_HOME="$semgrep_ro_xdg_data" XDG_CACHE_HOME="$semgrep_ro_xdg_cache" TMPDIR="$semgrep_tmp" \
    PATH="${semgrep_bin}:${PATH}" SEMGREP_ARGS="$semgrep_args" SEMGREP_ENV="$semgrep_env" \
    ./scripts/run-semgrep.sh scripts
grep -Fxq "UV_TOOL_DIR=${expected_fallback_tools}" "$semgrep_env" ||
    fail "Semgrep wrapper did not export fallback UV_TOOL_DIR under read-only XDG_DATA_HOME: $(cat "$semgrep_env")"
grep -Fxq "UV_CACHE_DIR=${expected_fallback_cache}" "$semgrep_env" ||
    fail "Semgrep wrapper did not export fallback UV_CACHE_DIR under read-only XDG_CACHE_HOME: $(cat "$semgrep_env")"
grep -Fxq "UV_PYTHON_INSTALL_DIR=${expected_fallback_python}" "$semgrep_env" ||
    fail "Semgrep wrapper did not export fallback UV_PYTHON_INSTALL_DIR under read-only XDG_DATA_HOME"

rm -f "$semgrep_args" "$semgrep_env"
HOME="$semgrep_ro_home" TMPDIR="$semgrep_tmp" \
    UV_TOOL_DIR="$semgrep_custom_tools" UV_CACHE_DIR="$semgrep_custom_cache" UV_PYTHON_INSTALL_DIR="$semgrep_custom_python" \
    PATH="${semgrep_bin}:${PATH}" SEMGREP_ARGS="$semgrep_args" SEMGREP_ENV="$semgrep_env" \
    ./scripts/run-semgrep.sh scripts
grep -Fxq "UV_TOOL_DIR=${semgrep_custom_tools}" "$semgrep_env" ||
    fail "Semgrep wrapper did not respect caller-exported UV_TOOL_DIR: $(cat "$semgrep_env")"
grep -Fxq "UV_CACHE_DIR=${semgrep_custom_cache}" "$semgrep_env" ||
    fail "Semgrep wrapper did not respect caller-exported UV_CACHE_DIR: $(cat "$semgrep_env")"
grep -Fxq "UV_PYTHON_INSTALL_DIR=${semgrep_custom_python}" "$semgrep_env" ||
    fail "Semgrep wrapper did not respect caller-exported UV_PYTHON_INSTALL_DIR"

rm -f "$semgrep_args" "$semgrep_env"
out=$(env -u UV_PYTHON_INSTALL_DIR -u UV_TOOL_DIR -u UV_CACHE_DIR -u XDG_DATA_HOME -u XDG_CACHE_HOME \
    HOME="$semgrep_ro_home" TMPDIR="$semgrep_ro_tmp" \
    PATH="${semgrep_bin}:${PATH}" SEMGREP_ARGS="$semgrep_args" \
    ./scripts/run-semgrep.sh scripts 2>&1) && rc=0 || rc=$?
[ "$rc" -ne 0 ] ||
    fail "Semgrep wrapper succeeded when neither default nor TMPDIR was writable"
[ ! -e "$semgrep_args" ] ||
    fail "Semgrep wrapper invoked uvx despite unwritable uv directories"
case "$out" in
*"${semgrep_ro_home}/.local/share/uv/tools"*UV_TOOL_DIR*UV_CACHE_DIR*) ;;
*) fail "Semgrep wrapper did not report the unwritable directory and UV_TOOL_DIR/UV_CACHE_DIR: $out" ;;
esac

rm -f "$semgrep_args" "$semgrep_env"
semgrep_writable_home="${test_tmp}/semgrep-writable-home"
mkdir -p "$semgrep_writable_home"
env -u UV_PYTHON_INSTALL_DIR -u UV_TOOL_DIR -u UV_CACHE_DIR -u XDG_DATA_HOME -u XDG_CACHE_HOME \
    HOME="$semgrep_writable_home" TMPDIR="$semgrep_tmp" \
    PATH="${semgrep_bin}:${PATH}" SEMGREP_ARGS="$semgrep_args" SEMGREP_ENV="$semgrep_env" \
    ./scripts/run-semgrep.sh scripts
grep -Fxq "UV_TOOL_DIR=" "$semgrep_env" ||
    fail "Semgrep wrapper exported UV_TOOL_DIR when default tool dir was already writable: $(cat "$semgrep_env")"
grep -Fxq "UV_CACHE_DIR=" "$semgrep_env" ||
    fail "Semgrep wrapper exported UV_CACHE_DIR when default cache dir was already writable: $(cat "$semgrep_env")"
grep -Fxq "UV_PYTHON_INSTALL_DIR=" "$semgrep_env" ||
    fail "Semgrep wrapper exported UV_PYTHON_INSTALL_DIR when the default was writable"

rm -f "$semgrep_args" "$semgrep_env"
out=$(HOME="$semgrep_ro_home" TMPDIR="$semgrep_tmp" \
    UV_TOOL_DIR="${semgrep_ro_home}/tools" UV_CACHE_DIR="$semgrep_custom_cache" \
    PATH="${semgrep_bin}:${PATH}" SEMGREP_ARGS="$semgrep_args" \
    ./scripts/run-semgrep.sh scripts 2>&1) && rc=0 || rc=$?
[ "$rc" -ne 0 ] ||
    fail "Semgrep wrapper succeeded with unwritable caller-exported UV_TOOL_DIR"
[ ! -e "$semgrep_args" ] ||
    fail "Semgrep wrapper invoked uvx despite unwritable caller-exported UV_TOOL_DIR"
case "$out" in
*"${semgrep_ro_home}/tools"*UV_TOOL_DIR*UV_CACHE_DIR*) ;;
*) fail "Semgrep wrapper did not report unwritable caller-exported UV_TOOL_DIR: $out" ;;
esac
rm -f "$semgrep_args" "$semgrep_env"
out=$(HOME="$semgrep_writable_home" TMPDIR="$semgrep_tmp" \
    UV_PYTHON_INSTALL_DIR="${semgrep_ro_home}/python" \
    PATH="${semgrep_bin}:${PATH}" SEMGREP_ARGS="$semgrep_args" \
    ./scripts/run-semgrep.sh scripts 2>&1) && rc=0 || rc=$?
[ "$rc" -ne 0 ] && [ ! -e "$semgrep_args" ] ||
    fail "Semgrep wrapper ignored an unwritable explicit UV_PYTHON_INSTALL_DIR"
case "$out" in
*"UV_PYTHON_INSTALL_DIR directory"*) ;;
*) fail "Semgrep wrapper did not name the unwritable Python directory: $out" ;;
esac
chmod -R u+w "$semgrep_ro_home" "$semgrep_ro_xdg_data" "$semgrep_ro_xdg_cache" "$semgrep_ro_tmp" 2>/dev/null || true

echo "==> shell lint enforces the CI ShellCheck pin before linting"
# Use the same extraction as lint-shell.sh on the real source of truth, so
# reshaping the action's pin cannot silently turn the version guard off.
if [ -f .github/actions/setup/action.yml ]; then
    actual_shellcheck_pin="$(sed -nE \
        -e 's/^[[:space:]]*SHELLCHECK_VERSION=([0-9]+\.[0-9]+\.[0-9]+)([[:space:]]+#.*)?[[:space:]]*$/\1/p' \
        -e 's/^[[:space:]]*SHELLCHECK_VERSION="([0-9]+\.[0-9]+\.[0-9]+)"([[:space:]]+#.*)?[[:space:]]*$/\1/p' \
        -e "s/^[[:space:]]*SHELLCHECK_VERSION='([0-9]+\.[0-9]+\.[0-9]+)'([[:space:]]+#.*)?[[:space:]]*$/\1/p" \
        .github/actions/setup/action.yml)"
    [[ "$actual_shellcheck_pin" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
        fail "the setup action's SHELLCHECK_VERSION pin is not readable as a single x.y.z version"
else
    echo "SKIP: real ShellCheck pin check — setup action is absent."
fi
lint_repo="${test_tmp}/lint-repo"
lint_bin="${test_tmp}/lint-bin"
lint_calls="${test_tmp}/lint-calls"
lint_stderr="${test_tmp}/lint-stderr"
mkdir -p "${lint_repo}/.github/actions/setup" "${lint_repo}/subdir" "$lint_bin"
printf '%s\n' '#!/usr/bin/env bash' 'echo ok' >"${lint_repo}/script with spaces.sh"
git -C "$lint_repo" init -q
git -C "$lint_repo" add -- 'script with spaces.sh'
cat >"${lint_bin}/shellcheck" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
    printf 'ShellCheck - shell script analysis tool\nversion: %s\n' "${LINT_TEST_VERSION:?}"
else
    printf '%s\n' shellcheck "$@" >>"${LINT_TEST_CALLS:?}"
fi
EOF
cat >"${lint_bin}/shfmt" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' shfmt "$@" >>"${LINT_TEST_CALLS:?}"
EOF
chmod +x "${lint_bin}/shellcheck" "${lint_bin}/shfmt"
for lint_script in scripts/lint-shell.sh template/scripts/lint-shell.sh; do
    [ -f "$lint_script" ] || continue
    # An arbitrary pin proves the guard reads the fixture rather than a copied
    # version constant. Exercise both explicit hook paths and tracked discovery.
    for pin_case in match mismatch commented quoted single-quoted crlf duplicate missing-pin missing-action; do
        printf '%s\n' '        SHELLCHECK_VERSION=7.8.9' >"${lint_repo}/.github/actions/setup/action.yml"
        case "$pin_case" in
        commented) printf '%s\n' '        SHELLCHECK_VERSION=7.8.9 # pin-pair: shellcheck' >"${lint_repo}/.github/actions/setup/action.yml" ;;
        quoted) printf '%s\n' '        SHELLCHECK_VERSION="7.8.9"' >"${lint_repo}/.github/actions/setup/action.yml" ;;
        single-quoted) printf '%s\n' "        SHELLCHECK_VERSION='7.8.9' # pin-pair: shellcheck" >"${lint_repo}/.github/actions/setup/action.yml" ;;
        crlf) printf '%s\r\n' '        SHELLCHECK_VERSION="7.8.9" # CRLF pin' >"${lint_repo}/.github/actions/setup/action.yml" ;;
        duplicate) printf '%s\n' '        SHELLCHECK_VERSION="7.8.9" # duplicate' >>"${lint_repo}/.github/actions/setup/action.yml" ;;
        missing-pin) printf '%s\n' 'name: Setup without ShellCheck' >"${lint_repo}/.github/actions/setup/action.yml" ;;
        missing-action) rm "${lint_repo}/.github/actions/setup/action.yml" ;;
        esac
        lint_version=7.8.9
        case "$pin_case" in
        mismatch | commented | quoted | single-quoted | crlf) lint_version=1.2.3 ;;
        esac
        for lint_mode in explicit tracked subdirectory; do
            : >"$lint_calls"
            out=$(
                cd "$lint_repo"
                lint_args=()
                [ "$lint_mode" != explicit ] || lint_args=('script with spaces.sh')
                if [ "$lint_mode" = subdirectory ]; then
                    cd subdir
                    lint_args=('../script with spaces.sh')
                fi
                PATH="${lint_bin}:${PATH}" LINT_TEST_VERSION="$lint_version" \
                    LINT_TEST_CALLS="$lint_calls" bash "$repo/$lint_script" ${lint_args[@]+"${lint_args[@]}"} 2>"$lint_stderr"
            ) && rc=0 || rc=$?
            [ -z "$out" ] || fail "$lint_script ($pin_case): unexpected stdout: $out"
            if [ "$lint_version" = 1.2.3 ]; then
                [ "$rc" -ne 0 ] || fail "$lint_script accepted a mismatched ShellCheck"
                [ ! -s "$lint_calls" ] || fail "$lint_script linted before rejecting the mismatch"
                grep -Fq '1.2.3' "$lint_stderr" && grep -Fq '7.8.9' "$lint_stderr" &&
                    grep -Fq 'install shellcheck 7.8.9' "$lint_stderr" ||
                    fail "$lint_script mismatch diagnostic omitted versions or installation advice: $(cat "$lint_stderr")"
            elif [ "$pin_case" = duplicate ]; then
                [ "$rc" -ne 0 ] || fail "$lint_script accepted duplicate ShellCheck pins"
                [ ! -s "$lint_calls" ] || fail "$lint_script linted despite duplicate pins"
                [ "$(wc -l <"$lint_stderr" | tr -d ' ')" -eq 1 ] &&
                    grep -Fq 'multiple SHELLCHECK_VERSION pins in ' "$lint_stderr" ||
                    fail "$lint_script omitted a clear duplicate-pin diagnostic: $(cat "$lint_stderr")"
            else
                [ "$rc" -eq 0 ] || fail "$lint_script ($pin_case) failed: $(cat "$lint_stderr")"
                lint_path='script with spaces.sh'
                [ "$lint_mode" != subdirectory ] || lint_path='../script with spaces.sh'
                expected_calls=$(printf '%s\n' shellcheck --severity=error "$lint_path" shfmt -d "$lint_path")
                [ "$(cat "$lint_calls")" = "$expected_calls" ] || fail "$lint_script ($pin_case) did not lint the intended path"
                if [ "$pin_case" = match ]; then
                    [ ! -s "$lint_stderr" ] || fail "$lint_script warned despite a matching pin"
                else
                    [ "$(wc -l <"$lint_stderr" | tr -d ' ')" -eq 1 ] &&
                        grep -Fq 'WARNING: no SHELLCHECK_VERSION pin' "$lint_stderr" &&
                        grep -Fq 'continuing' "$lint_stderr" ||
                        fail "$lint_script ($pin_case) did not warn once on stderr: $(cat "$lint_stderr")"
                fi
            fi
        done
    done
done

echo "==> shell formatter preserves tracked paths and failures"
format_repo="${test_tmp}/format-repo"
# Assemble the jinja-style segment so this file never contains a literal
# copier marker: the standardize-repo skill's unrendered-marker scan
# (verify-applied.sh) would otherwise flag scripts/test-tasks.sh in every
# generated repo. The RUNTIME path still opens a real block marker ("[%"
# followed by " if ... %]") plus whitespace — the case the repo's shell
# formatter helper must survive.
jinja_open='[%'
format_path="${format_repo}/template/${jinja_open} if sample %]/script with spaces.sh"
mkdir -p "$(dirname "$format_path")"
git -C "$format_repo" init -q
printf '%s\n' '#!/usr/bin/env bash' 'if true;then' 'echo ok' 'fi' >"$format_path"
git -C "$format_repo" add -- "${format_path#"$format_repo"/}"
(
    cd "$format_repo"
    "$repo/scripts/shell-quality.sh" format
)
if ! shfmt -d "$format_path" >/dev/null; then
    fail "shell formatter did not safely format a tracked path containing spaces"
fi

format_fail_bin="${test_tmp}/format-fail-bin"
mkdir -p "$format_fail_bin"
cat >"${format_fail_bin}/shfmt" <<'EOF'
#!/usr/bin/env bash
exit 42
EOF
chmod +x "${format_fail_bin}/shfmt"
if (
    cd "$format_repo"
    PATH="${format_fail_bin}:${PATH}" "$repo/scripts/shell-quality.sh" format
); then
    fail "shell formatter masked a shfmt failure"
fi
if ! grep -qF './scripts/shell-quality.sh format' Taskfile.yml; then
    fail "Taskfile.yml does not delegate shell formatting to the path-safe helper"
fi

echo "==> secret helper tasks reject missing destination metadata"
# Assert the stable missing-destination diagnostic, not just a nonzero exit:
# a bare `if ! task ...` would also be satisfied by an unrelated failure
# (missing op/gh, a Taskfile parse error). Clear any inherited destination
# metadata first so the tests actually exercise the missing-metadata path.
out=$(printf '%s' 'dummy-secret' |
    env -u VAULT -u ITEM -u FIELD -u SECTION task secret:set:1p 2>&1) && rc=0 || rc=$?
if [ "$rc" -eq 0 ]; then
    fail "task secret:set:1p succeeded without destination metadata"
fi
case "$out" in
*"VAULT, ITEM, and FIELD are required"*) ;;
*) fail "task secret:set:1p failed for the wrong reason: $out" ;;
esac
out=$(printf '%s' 'dummy-secret' |
    env -u NAME -u REPO task secret:set:gh 2>&1) && rc=0 || rc=$?
if [ "$rc" -eq 0 ]; then
    fail "task secret:set:gh succeeded without destination metadata"
fi
case "$out" in
*"NAME and REPO are required"*) ;;
*) fail "task secret:set:gh failed for the wrong reason: $out" ;;
esac

echo "==> 1Password helper rejects SSH Key categories at runtime"
op_bin="${test_tmp}/op-bin"
op_edit_called="${test_tmp}/op-edit-called"
mkdir -p "$op_bin"
cat >"${op_bin}/op" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-} ${2:-}" in
"item get")
    printf '{"category":"%s","fields":[{"label":"password","type":"CONCEALED","value":"old"}]}\n' \
        "${OP_FIXTURE_CATEGORY:?}"
    ;;
"item edit")
    : >"${OP_EDIT_CALLED:?}"
    cat >/dev/null
    ;;
*)
    exit 1
    ;;
esac
EOF
chmod +x "${op_bin}/op"
for category in SSH_KEY SSHKEY; do
    rm -f "$op_edit_called"
    out=$(printf '%s' 'dummy-secret' |
        PATH="${op_bin}:${PATH}" OP_FIXTURE_CATEGORY="$category" \
            OP_EDIT_CALLED="$op_edit_called" VAULT=test ITEM=test FIELD=password \
            ./scripts/secret-set-1p.sh 2>&1) && rc=0 || rc=$?
    if [ "$rc" -eq 0 ]; then
        fail "secret:set:1p accepted unsupported category $category"
    fi
    case "$out" in
    *"item holds a passkey or SSH key"*) ;;
    *) fail "secret:set:1p rejected $category for the wrong reason: $out" ;;
    esac
    if [ -e "$op_edit_called" ]; then
        fail "secret:set:1p attempted an item edit for $category"
    fi
done

echo "==> secret helpers print styled outcomes without echoing secret values"
secret_value='sensitive-value-must-not-appear'
rm -f "$op_edit_called"
out=$(printf '%s' "$secret_value" |
    PATH="${op_bin}:${PATH}" OP_FIXTURE_CATEGORY=LOGIN \
        OP_EDIT_CALLED="$op_edit_called" VAULT=test ITEM=test FIELD=password \
        ./scripts/secret-set-1p.sh 2>&1) || fail "secret:set:1p success fixture failed: $out"
[ -e "$op_edit_called" ] || fail "secret:set:1p success fixture never edited the item"
case "$out" in
*'DONE: 1Password secret updated'*) ;;
*) fail "secret:set:1p omitted its final outcome: $out" ;;
esac
case "$out" in
*"$secret_value"*) fail "secret:set:1p printed the secret value" ;;
esac

gh_bin="${test_tmp}/gh-bin"
gh_secret_capture="${test_tmp}/gh-secret"
mkdir -p "$gh_bin"
cat >"${gh_bin}/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-} ${2:-}" = "secret set" ] || exit 1
cat >"${GH_SECRET_CAPTURE:?}"
EOF
chmod +x "${gh_bin}/gh"
out=$(printf '%s' "$secret_value" |
    PATH="${gh_bin}:${PATH}" GH_SECRET_CAPTURE="$gh_secret_capture" \
        NAME=DEPLOY_TOKEN REPO=owner/repo ./scripts/secret-set-gh.sh 2>&1) ||
    fail "secret:set:gh success fixture failed: $out"
[ "$(cat "$gh_secret_capture")" = "$secret_value" ] ||
    fail "secret:set:gh changed the secret value sent to gh"
case "$out" in
*'DONE: GitHub secret updated'*) ;;
*) fail "secret:set:gh omitted its final outcome: $out" ;;
esac
case "$out" in
*"$secret_value"*) fail "secret:set:gh printed the secret value" ;;
esac

echo "==> terminal-aware tasks stay interactive through Task grouping, in both twins"
# A run-time-only regression, and a total one: this Taskfile sets `output:
# group` GLOBALLY, so Task pipes each task's stdout. A script guarding on
# `[ -t 1 ]` then sees a pipe and refuses even in a real terminal, which made
# `task setup:gh-scopes` impossible to use through its own documented entry
# point (the smoke tests called the script directly and never saw the wiring).
# `interactive: true` makes Task skip grouping and attach the task to the
# terminal.
#
# Pinned for BOTH twins, because a generated repo inherits the same global
# grouping and would inherit the same defect. Asserted against the file rather
# than by running the task: running it would open a real browser device-code
# flow against the operator's own credential.
#
# Keyed to a fatal `-t 1` check specifically. A `-t 0` guard (secret:set:*,
# codex:gate:disable) is untouched by output grouping, which redirects stdout
# only. The status tasks do not refuse without a TTY, but their intentionally
# visual dashboard would otherwise lose color, Unicode, and gum through its
# documented Task entrypoints.
# Both layers where they exist. A GENERATED repo has only the first — it is the
# rendered output, with no template/ of its own — so a missing file is skipped
# rather than failed, and the counter below keeps "skipped everything" from
# passing silently.
tty_gated_tasks="setup:gh-scopes status status:git status:gh status:creds status:code status:env status:setup"
checked_taskfiles=0
for taskfile in Taskfile.yml template/Taskfile.yml.jinja; do
    [ -f "$taskfile" ] || continue
    checked_taskfiles=$((checked_taskfiles + 1))
    taskfile_tty_tasks="$tty_gated_tasks"
    if grep -q '^  sync:skills:' "$taskfile"; then
        taskfile_tty_tasks="$taskfile_tty_tasks groom"
    fi
    for t in $taskfile_tty_tasks; do
        block="$(awk -v name="  ${t}:" '
            $0 == name { inblock = 1; next }
            inblock && /^  [a-zA-Z0-9]/ { inblock = 0 }
            inblock { print }
        ' "$taskfile")"
        [ -n "$block" ] || fail "${taskfile}: task ${t} not found — did it get renamed?"
        # A whole-line DIRECTIVE, never a substring: the task carries a comment
        # explaining why the key is there, and that comment names the key — so a
        # substring match passes on the prose alone and the assertion silently
        # stops asserting. (It did, until a mutation test caught it.)
        grep -qE '^[[:space:]]*interactive:[[:space:]]*true[[:space:]]*$' < <(printf '%s\n' "$block" | grep -vE '^[[:space:]]*#') ||
            fail "${taskfile}: ${t} lacks 'interactive: true' — global 'output: group' hides its terminal from the script"
    done
done

[ "$checked_taskfiles" -gt 0 ] ||
    fail "no Taskfile was checked for the interactive: true requirement — the assertion above proved nothing"

# The guard above is worth nothing if the grouping it defends against is gone;
# in that case the requirement should be re-derived rather than silently kept.
# GROUP specifically, not merely the presence of an `output:` key: `interleaved`
# and `prefixed` keep the key while dropping the stdout pipe that makes
# `interactive: true` necessary, and a check on the key alone would keep
# demanding it long after the reason had evaporated.
awk '
    /^output:/ { inout = 1; next }
    inout && /^[^[:space:]]/ { inout = 0 }
    inout && /^[[:space:]]+group:[[:space:]]*$/ { found = 1 }
    END { exit(found ? 0 : 1) }
' Taskfile.yml ||
    fail "Taskfile.yml no longer selects 'output: group' — re-derive whether the interactive: true assertion above still describes a real hazard"

echo "==> setup:github delegates action logic to the tested script in both twins"
checked_setup_tasks=0
for taskfile in Taskfile.yml template/Taskfile.yml.jinja; do
    [ -f "$taskfile" ] || continue
    checked_setup_tasks=$((checked_setup_tasks + 1))
    block="$(awk '
        $0 == "  setup:github:" { inblock = 1; next }
        inblock && /^  [a-zA-Z0-9]/ { inblock = 0 }
        inblock { print }
    ' "$taskfile")"
    [ -n "$block" ] || fail "${taskfile}: setup:github task not found"
    grep -Fq './scripts/setup-github.sh --repo "{{.REPO}}"' <<<"$block" ||
        fail "${taskfile}: setup:github does not delegate to scripts/setup-github.sh"
    if grep -Eq 'gh api|^[[:space:]]*-[[:space:]]*[|]' <<<"$block"; then
        fail "${taskfile}: setup:github contains inline action logic instead of a trivial script command"
    fi
done
[ "$checked_setup_tasks" -gt 0 ] || fail "no Taskfile setup:github wiring was checked"

echo "==> groom delegates to its skill wrapper with a precondition guard"
groom_wrapper_for_taskfile() {
    if grep -Fq './ai/skills/universal/groom/assets/groom.sh {{.CLI_ARGS}}' "$1"; then
        printf '%s\n' ai/skills/universal/groom/assets/groom.sh
    else
        printf '%s\n' .claude/skills/groom/assets/groom.sh
    fi
}
checked_groom_tasks=0
for taskfile in Taskfile.yml template/Taskfile.yml.jinja; do
    [ -f "$taskfile" ] || continue
    grep -q '^  sync:skills:' "$taskfile" || continue
    checked_groom_tasks=$((checked_groom_tasks + 1))
    block="$(awk '
        $0 == "  groom:" { inblock = 1; next }
        inblock && /^  [a-zA-Z0-9]/ { inblock = 0 }
        inblock { print }
    ' "$taskfile")"
    [ -n "$block" ] || fail "${taskfile}: groom task not found alongside sync:skills"
    groom_wrapper="$(groom_wrapper_for_taskfile "$taskfile")"
    grep -Fq "./$groom_wrapper {{.CLI_ARGS}}" <<<"$block" ||
        fail "${taskfile}: groom does not forward {{.CLI_ARGS}} to ./.claude/skills/groom/assets/groom.sh"
    grep -Fq "sh: test -x $groom_wrapper" <<<"$block" ||
        fail "${taskfile}: groom lacks the executable precondition for .claude/skills/groom/assets/groom.sh"
    if [ "$groom_wrapper" = .claude/skills/groom/assets/groom.sh ]; then
        grep -Fq '.skills-sync.yaml' <<<"$block" ||
            fail "${taskfile}: groom precondition message does not name .skills-sync.yaml"
        grep -Fq 'universal' <<<"$block" ||
            fail "${taskfile}: groom precondition message does not name the universal category"
        grep -Fq 'task sync:skills' <<<"$block" ||
            fail "${taskfile}: groom precondition message does not name task sync:skills"
    else
        grep -Fq 'restore it from this repository' <<<"$block" ||
            fail "${taskfile}: source groom precondition lacks source recovery guidance"
    fi
    if grep -Eq '^[[:space:]]*-[[:space:]]*[|]' <<<"$block"; then
        fail "${taskfile}: groom contains inline multiline shell in cmds instead of a single wrapper invocation"
    fi
done
if grep -q '^  sync:skills:' Taskfile.yml || [ -f template/Taskfile.yml.jinja ]; then
    [ "$checked_groom_tasks" -gt 0 ] || fail "no Taskfile groom wiring was checked"
fi

if grep -q '^  groom:' Taskfile.yml; then
    groom_wrapper="$(groom_wrapper_for_taskfile Taskfile.yml)"
    groom_tokens=("$groom_wrapper" universal)
    if [ "$groom_wrapper" = .claude/skills/groom/assets/groom.sh ]; then
        groom_tokens+=(.skills-sync.yaml 'task sync:skills')
    else
        groom_tokens+=('restore it from this repository')
    fi
    list_out="$(task --color=false --list-all 2>&1)"
    grep -qE '^\* groom:' <<<"$list_out" ||
        fail "task --list-all did not list groom"
    groom_tmp="${test_tmp}/groom-fixture"
    mkdir -p "$groom_tmp"
    cp Taskfile.yml "$groom_tmp/Taskfile.yml"
    if [ -d taskfiles ]; then
        cp -R taskfiles "$groom_tmp/taskfiles"
    fi
    out="$(task --dir "$groom_tmp" --color=false groom 2>&1)" && rc=0 || rc=$?
    [ "$rc" -ne 0 ] || fail "task groom succeeded when .claude/skills/groom/assets/groom.sh was missing"
    for token in "${groom_tokens[@]}"; do
        grep -Fq "$token" <<<"$out" ||
            fail "task groom missing-skill output did not mention '${token}': ${out}"
    done
    mkdir -p "$groom_tmp/$(dirname "$groom_wrapper")"
    cat >"$groom_tmp/$groom_wrapper" <<'EOF'
#!/usr/bin/env bash
echo "RAN_GROOM_STUB" >"$(dirname "$0")/ran"
exit 99
EOF
    chmod 0644 "$groom_tmp/$groom_wrapper"
    out="$(task --dir "$groom_tmp" --color=false groom 2>&1)" && rc=0 || rc=$?
    [ "$rc" -ne 0 ] || fail "task groom succeeded when .claude/skills/groom/assets/groom.sh was not executable"
    [ ! -e "$groom_tmp/$(dirname "$groom_wrapper")/ran" ] ||
        fail "task groom executed non-executable .claude/skills/groom/assets/groom.sh"
    chmod +x "$groom_tmp/$groom_wrapper"
    out="$(task --dir "$groom_tmp" --color=false --dry groom -- --execute groom-report.sh render 2>&1)" && rc=0 || rc=$?
    [ "$rc" -eq 0 ] || fail "task --dry groom failed with executable stub: ${out}"
    [ ! -e "$groom_tmp/$(dirname "$groom_wrapper")/ran" ] ||
        fail "task --dry groom executed .claude/skills/groom/assets/groom.sh instead of dry-running"
    grep -Fq "./$groom_wrapper --execute groom-report.sh render" <<<"$out" ||
        fail "task --dry groom did not resolve to ./.claude/skills/groom/assets/groom.sh --execute groom-report.sh render: ${out}"
    if [ -x "$groom_wrapper" ]; then
        out="$(task --color=false --dry groom -- --execute groom-report.sh render 2>&1)" && rc=0 || rc=$?
        [ "$rc" -eq 0 ] || fail "repo task --dry groom failed: ${out}"
        grep -Fq "./$groom_wrapper --execute groom-report.sh render" <<<"$out" ||
            fail "repo task --dry groom did not resolve to ./.claude/skills/groom/assets/groom.sh --execute groom-report.sh render: ${out}"
    fi
fi

if [ -x ./scripts/test-terraform-provider-locks.sh ]; then
    echo "==> Terraform provider locks cover developer and CI platforms"
    ./scripts/test-terraform-provider-locks.sh
fi

if [ -x ./scripts/test-terraform-changed.sh ]; then
    echo "==> Terraform change detection drives the required terraform-verify check"
    ./scripts/test-terraform-changed.sh
fi

echo "==> verify × test dedupe guard (no target in both verify cmds and test deps)"
verify_cmds="$(yq -r '.tasks.verify.cmds[] | select(.task) | .task' Taskfile.yml | sort)"
test_deps="$(yq -r '.tasks.test.deps[] | (.task // .)' Taskfile.yml | sort)"
[ -n "$verify_cmds" ] || fail "verify has no task-type cmds — did the task get renamed?"
[ -n "$test_deps" ] || fail "test has no deps — did the task get renamed?"
dupes="$(comm -12 <(printf '%s\n' "$verify_cmds") <(printf '%s\n' "$test_deps"))"
if [ -n "$dupes" ]; then
    fail "targets registered in both verify cmds and test deps (would run twice): $(echo "$dupes" | tr '\n' ' ')"
fi

dedupe_fixture="${test_tmp}/dedupe-Taskfile.yml"
cat >"$dedupe_fixture" <<'YAML'
version: '3'
tasks:
  verify:
    cmds:
      - task: check
      - task: test:alpha
      - task: test
  test:
    deps:
      - task: test:alpha
        vars: { SCOPE: unit }
      - test:beta
  check:
    cmds:
      - echo check
  test:alpha:
    cmds:
      - echo alpha
  test:beta:
    cmds:
      - echo beta
YAML
fixture_verify="$(yq -r '.tasks.verify.cmds[] | select(.task) | .task' "$dedupe_fixture" | sort)"
fixture_deps="$(yq -r '.tasks.test.deps[] | (.task // .)' "$dedupe_fixture" | sort)"
fixture_dupes="$(comm -12 <(printf '%s\n' "$fixture_verify") <(printf '%s\n' "$fixture_deps"))"
[ -n "$fixture_dupes" ] || fail "dedupe fixture did not detect the planted duplicate (test:alpha)"
case "$fixture_dupes" in
*test:alpha*) ;;
*) fail "dedupe fixture found the wrong duplicate: $fixture_dupes" ;;
esac

if [ -x ./scripts/test-setup-action-tool-versions.sh ]; then
    echo "==> setup action replaces mismatched lint-tool versions"
    ./scripts/test-setup-action-tool-versions.sh
fi

echo "==> task targets OK (compile + bootstrap idempotency + path-safe formatting + dedupe guard)"
