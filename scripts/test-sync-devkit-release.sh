#!/usr/bin/env bash
# test-sync-devkit-release.sh — unit tests for the downstream
# sync-devkit-release.sh helper, stubbing gh and task with a real git fixture.
#
# This is the downstream twin of harmon-init's root test suite. The root tests
# cover the twin-manifest variant; these cover the single-manifest (generated
# repo) variant. The test uses the REAL helper — stubs are per-test, not mocked
# functions — so every case exercises the actual command dispatch and
# error-handling paths.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# The helper is co-located. In the template source both files carry conditional
# names ([% if … %]…[% endif %]); in a rendered repo they are plain
# sync-devkit-release.sh. Resolve whichever is present.
if [ -f "$SCRIPT_DIR/sync-devkit-release.sh" ]; then
    HELPER="$SCRIPT_DIR/sync-devkit-release.sh"
elif [ -f "$SCRIPT_DIR/[% if use_skills_sync %]sync-devkit-release.sh[% endif %]" ]; then
    HELPER="$SCRIPT_DIR/[% if use_skills_sync %]sync-devkit-release.sh[% endif %]"
else
    echo "cannot find sync-devkit-release.sh" >&2
    exit 1
fi
TEST_ROOT="$(mktemp -d)"
cleanup() { rm -rf "$TEST_ROOT"; }
trap cleanup EXIT

BIN_DIR="$TEST_ROOT/bin"
mkdir -p "$BIN_DIR"
export PATH="$BIN_DIR:$PATH"

note() { printf '\n  \033[1;37m%s\033[0m\n' "$*"; }

# ── Fixture helpers ───────────────────────────────────────────────────
# build_fixture TAG — a git repo with one commit (the current pin) on main,
# plus a bare 'origin' to observe pushes.
build_fixture() {
    _bf_tag="${1:-v0.1.0}"
    _bf_dir="$TEST_ROOT/fixture"
    _bf_bare="$TEST_ROOT/origin.git"
    rm -rf "$_bf_dir" "$_bf_bare"
    mkdir -p "$_bf_dir"
    cd "$_bf_dir"
    git init -b main >/dev/null 2>&1
    git config user.name "test"
    git config user.email "test@test"

    cat >.skills-sync.yaml <<YAML
source:
  repo: https://github.com/evanharmon1/harmon-devkit.git
  ref: $_bf_tag
  path: ai/skills
categories:
  - universal
dest: .claude/skills
YAML
    mkdir -p .claude/skills
    echo "scripts/_sync-devkit-release.sh" >.gitignore

    git add -A && git commit -m "initial" >/dev/null 2>&1
    git init --bare "$_bf_bare" >/dev/null 2>&1
    git remote add origin "$_bf_bare"
    git push -u origin main >/dev/null 2>&1
    echo "$_bf_dir"
}

# add_agents_block DIR — add an agents: block to the manifest so the agents
# paths are exercised.
add_agents_block() {
    cat >>"$1/.skills-sync.yaml" <<YAML
agents:
  names: ["*"]
  dest: .claude/agents
YAML
    git -C "$1" add -A && git -C "$1" commit -m "add agents block" >/dev/null 2>&1
    git -C "$1" push origin main >/dev/null 2>&1
}

# ── Stubs ─────────────────────────────────────────────────────────────
# Every test writes fresh stubs into BIN_DIR so concurrent cases are isolated.

write_task_stub() {
    _ts_mode="$1" # pass | fail
    cat >"$BIN_DIR/task" <<SCRIPT
#!/usr/bin/env bash
echo "task \$*" >>"$TASK_LOG"
# \$GH_TOKEN must stay escaped: this heredoc is unquoted, so an unescaped
# reference would bake the GENERATING shell's token in as a constant instead of
# reading the stub's own environment. That inverted the test in both
# directions — vacuously green wherever GH_TOKEN was unset (the leak branch
# could never fire, so scrubbing went unverified), and unconditionally red
# wherever a developer had one exported, whatever run_untrusted did.
[ -n "\${GH_TOKEN:-}" ] && echo "LEAKED GH_TOKEN" >>"$TASK_LOG"
case "\${1:-}" in
sync:skills)
    if [ "$_ts_mode" = "pass" ]; then
        mkdir -p .claude/skills/universal
        echo "# ref: \$(awk '/^[[:space:]]*ref:/{sub(/^[[:space:]]*ref:[[:space:]]*/,""); print}' .skills-sync.yaml)" > .claude/skills/.SKILLS_PROVENANCE
        echo "# categories: universal" >> .claude/skills/.SKILLS_PROVENANCE
        echo "# managed: universal" >> .claude/skills/.SKILLS_PROVENANCE
    else
        echo "sync:skills failed" >&2
        exit 1
    fi
    ;;
verify:skills:offline) ;;
security:secrets) ;;
*)
    echo "unexpected task target: \$*" >&2
    exit 1
    ;;
esac
SCRIPT
    chmod +x "$BIN_DIR/task"
}

write_gh_stub() {
    cat >"$BIN_DIR/gh" <<'SCRIPT'
#!/usr/bin/env bash
echo "gh $*" >>"$GH_LOG"
# Emulate --jq output: the helper passes --jq <expr> which gh applies to the
# JSON response. Reproduce the two expressions the helper actually uses.
case "${1:-}--${2:-}" in
api--repos/*/releases/latest)
    # helper calls: --jq '.tag_name'
    echo 'v0.9.0'
    ;;
api--repos/*/releases/tags/*)
    _tag="${2##*/}"
    case "$_tag" in
    v0.8.0|v0.9.0|v0.10.0|v1.0.0|v2.0.0)
        # helper calls: --jq '[.tag_name, (.draft|tostring), (.prerelease|tostring)] | join(" ")'
        echo "$_tag false false"
        ;;
    v9.9.9) echo "no published release" >&2; exit 1;;
    *) echo "$_tag false false" ;;
    esac
    ;;
pr--list) echo "${STUB_PR_LIST:-}";;
pr--create) echo "created";;
pr--edit)
    if [ -n "${STUB_EDIT_MAKES_READY:-}" ]; then
        rm -f "${STUB_PR_DRAFT_MARKER:-/nonexistent}"
    fi
    echo "edited"
    ;;
pr--view)
    case "$*" in
    *"--json title"*)
        [ -z "${STUB_FAIL_PR_TITLE_VIEW:-}" ] || exit 1
        echo "${STUB_PR_TITLE:-}"
        ;;
    *"--json number"*)
        [ -z "${STUB_FAIL_PR_NUMBER_VIEW:-}" ] || exit 1
        echo "${STUB_PR_NUMBER:-42}"
        ;;
    *"--json headRefOid,isDraft"*)
        [ -z "${STUB_FAIL_PR_DRAFT_VIEW:-}" ] || exit 1
        _stub_head="${STUB_PR_HEAD:-$(git rev-parse HEAD)}"
        if [ -f "${STUB_PR_DRAFT_MARKER:-/nonexistent}" ]; then
            echo "$_stub_head true"
        else
            echo "$_stub_head ${STUB_PR_IS_DRAFT:-true}"
        fi
        ;;
    *) exit 1;;
    esac
    ;;
pr--ready)
    [ "${3:-}" = "--undo" ] || exit 1
    [ -z "${STUB_FAIL_READY_UNDO:-}" ] || exit 1
    : >"$STUB_PR_DRAFT_MARKER"
    ;;
api--/users/*) echo '12345' ;;
*) exit 0;;
esac
SCRIPT
    chmod +x "$BIN_DIR/gh"
}

export TASK_LOG="$TEST_ROOT/task.log"
export GH_LOG="$TEST_ROOT/gh.log"
export STUB_PR_LIST=""
export STUB_PR_TITLE=""
export STUB_FAIL_PR_TITLE_VIEW=""
export STUB_PR_NUMBER="42"
export STUB_PR_HEAD=""
export STUB_PR_IS_DRAFT="true"
export STUB_PR_DRAFT_MARKER="$TEST_ROOT/pr-draft"
export STUB_FAIL_PR_NUMBER_VIEW=""
export STUB_FAIL_PR_DRAFT_VIEW=""
export STUB_FAIL_READY_UNDO=""
export STUB_EDIT_MAKES_READY=""

clear_logs() {
    rm -f "$TASK_LOG" "$GH_LOG"
    : >"$TASK_LOG"
    : >"$GH_LOG"
    STUB_PR_LIST=""
    STUB_PR_TITLE=""
    STUB_FAIL_PR_TITLE_VIEW=""
    STUB_PR_NUMBER="42"
    STUB_PR_HEAD=""
    STUB_PR_IS_DRAFT="true"
    rm -f "$STUB_PR_DRAFT_MARKER"
    STUB_FAIL_PR_NUMBER_VIEW=""
    STUB_FAIL_PR_DRAFT_VIEW=""
    STUB_FAIL_READY_UNDO=""
    STUB_EDIT_MAKES_READY=""
}

# ── Assertions ────────────────────────────────────────────────────────
assert_pin() {
    _ap_tag="$1" _ap_file="$2"
    _ap_got="$(awk '/^[[:space:]]*ref:/{sub(/^[[:space:]]*ref:[[:space:]]*/,""); print; exit}' "$_ap_file")"
    [ "$_ap_got" = "$_ap_tag" ] || {
        echo "expected pin $_ap_tag, got $_ap_got" >&2
        return 1
    }
}

assert_task_logged() {
    grep -qxF "$1" "$TASK_LOG" || {
        echo "expected task '$1' in log" >&2
        return 1
    }
}

assert_task_not_logged() {
    grep -qxF "$1" "$TASK_LOG" && {
        echo "expected task '$1' NOT in log" >&2
        return 1
    } || true
}

assert_gh_logged() {
    grep -qF "$1" "$GH_LOG" || {
        echo "expected gh '$1' in log" >&2
        return 1
    }
}

assert_commit_title() {
    _act_dir="$1" _act_title="$2"
    _act_got="$(git -C "$_act_dir" log -1 --format=%s)"
    [ "$_act_got" = "$_act_title" ] || {
        echo "expected commit '$_act_title', got '$_act_got'" >&2
        return 1
    }
}

# ── run_helper ────────────────────────────────────────────────────────
# Copies the helper into the fixture's scripts/ directory and runs the copy
# from the fixture root. Scrubs GH_TOKEN so a stale env value cannot leak
# into the helper — the test stubs gh, so the token must never reach git.
# The helper calls cd "$(dirname "$0")/.." to reach the repo root from its
# scripts/ location; we replicate that layout so it resolves to the fixture.
run_helper() {
    mkdir -p "$FIXTURE/scripts"
    cp "$HELPER" "$FIXTURE/scripts/_sync-devkit-release.sh"
    (cd "$FIXTURE" && PATH="$BIN_DIR:$PATH" env -u GH_TOKEN -u GITHUB_TOKEN bash scripts/_sync-devkit-release.sh "$@")
}

run_helper_with_tag() {
    mkdir -p "$FIXTURE/scripts"
    cp "$HELPER" "$FIXTURE/scripts/_sync-devkit-release.sh"
    git -C "$FIXTURE" add scripts/_sync-devkit-release.sh >/dev/null 2>&1 || true
    (cd "$FIXTURE" && PATH="$BIN_DIR:$PATH" env -u GH_TOKEN -u GITHUB_TOKEN SYNC_DEVKIT_TAG="$1" bash scripts/_sync-devkit-release.sh run)
}

# Like run_helper_with_tag but deliberately passes GH_TOKEN through so the
# test can verify that run_untrusted scrubs it before task subprocesses see it.
run_helper_with_token() {
    mkdir -p "$FIXTURE/scripts"
    cp "$HELPER" "$FIXTURE/scripts/_sync-devkit-release.sh"
    git -C "$FIXTURE" add scripts/_sync-devkit-release.sh >/dev/null 2>&1 || true
    (cd "$FIXTURE" && PATH="$BIN_DIR:$PATH" SYNC_DEVKIT_TAG="$1" bash scripts/_sync-devkit-release.sh run)
}

# ── Tests ─────────────────────────────────────────────────────────────

test_resolve_latest() {
    note "resolve prints the latest release tag"
    FIXTURE="$(build_fixture v0.1.0)"
    clear_logs
    write_gh_stub
    _got="$(run_helper resolve)"
    [ "$_got" = "v0.9.0" ] || {
        echo "expected v0.9.0, got $_got" >&2
        return 1
    }
}

test_resolve_explicit_tag() {
    note "resolve validates and echoes an explicit tag"
    FIXTURE="$(build_fixture v0.1.0)"
    clear_logs
    write_gh_stub
    _got="$(run_helper resolve v1.0.0)"
    [ "$_got" = "v1.0.0" ] || {
        echo "expected v1.0.0, got $_got" >&2
        return 1
    }
}

test_reject_bad_tag_shape() {
    note "resolve rejects a malformed tag"
    FIXTURE="$(build_fixture v0.1.0)"
    clear_logs
    write_gh_stub
    ! run_helper resolve "not-a-tag" || {
        echo "should have rejected"
        return 1
    }
}

test_reject_unknown_release() {
    note "resolve rejects a tag with no published release"
    FIXTURE="$(build_fixture v0.1.0)"
    clear_logs
    write_gh_stub
    ! run_helper resolve v9.9.9 || {
        echo "should have rejected"
        return 1
    }
}

test_pinned() {
    note "pinned prints the current tag"
    FIXTURE="$(build_fixture v0.5.0)"
    _got="$(run_helper pinned)"
    [ "$_got" = "v0.5.0" ] || {
        echo "expected v0.5.0, got $_got" >&2
        return 1
    }
}

test_happy_path() {
    note "happy path: pin bump, sync, verify, push, open PR"
    FIXTURE="$(build_fixture v0.1.0)"
    clear_logs
    write_gh_stub
    write_task_stub pass
    run_helper_with_tag v0.9.0 || return 1
    assert_pin v0.9.0 "$FIXTURE/.skills-sync.yaml" || return 1
    assert_task_logged "task sync:skills" || return 1
    assert_task_logged "task verify:skills:offline" || return 1
    assert_task_logged "task security:secrets" || return 1
    assert_task_not_logged "task verify:skills" || return 1
    assert_task_not_logged "task verify" || return 1
    assert_gh_logged "gh pr create" || return 1
    assert_gh_logged "gh pr create --draft" || return 1
    assert_gh_logged "gh pr view 42 --json headRefOid,isDraft" || return 1
    assert_commit_title "$FIXTURE" "fix: sync harmon-devkit skills to v0.9.0" || return 1
}

test_ready_created_pr_is_reverted() {
    note "a created PR that lands ready is returned to draft"
    FIXTURE="$(build_fixture v0.1.0)"
    clear_logs
    STUB_PR_IS_DRAFT="false"
    write_gh_stub
    write_task_stub pass
    run_helper_with_tag v0.9.0 || return 1
    assert_gh_logged "gh pr ready --undo 42" || return 1
    [ "$(grep -cF 'gh pr view 42 --json headRefOid,isDraft' "$GH_LOG")" -ge 2 ] || {
        echo "draft conversion was not re-confirmed" >&2
        return 1
    }
}

test_created_pr_head_mismatch_fails() {
    note "a created PR on a different head fails closed"
    FIXTURE="$(build_fixture v0.1.0)"
    clear_logs
    STUB_PR_HEAD="0000000000000000000000000000000000000000"
    write_gh_stub
    write_task_stub pass
    ! run_helper_with_tag v0.9.0 || {
        echo "a PR on an unverified head was reported as success" >&2
        return 1
    }
}

test_unresolvable_created_pr_fails() {
    note "an unresolvable created PR fails closed"
    FIXTURE="$(build_fixture v0.1.0)"
    clear_logs
    STUB_FAIL_PR_NUMBER_VIEW="true"
    write_gh_stub
    write_task_stub pass
    ! run_helper_with_tag v0.9.0 || {
        echo "an unresolvable PR was reported as success" >&2
        return 1
    }
}

test_ready_existing_pr_is_drafted_before_push() {
    note "a ready existing PR must become draft before force-push"
    FIXTURE="$(build_fixture v0.1.0)"
    clear_logs
    STUB_PR_LIST="42"
    STUB_PR_IS_DRAFT="false"
    STUB_FAIL_READY_UNDO="true"
    write_gh_stub
    write_task_stub pass
    ! run_helper_with_tag v0.9.0 || {
        echo "a ready PR was overwritten without draft conversion" >&2
        return 1
    }
    ! git --git-dir="$TEST_ROOT/origin.git" show-ref --verify --quiet "refs/heads/bot/sync-harmon-devkit" || {
        echo "sync branch was pushed before draft conversion" >&2
        return 1
    }
}

test_updated_pr_is_rechecked_after_edit() {
    note "an updated PR is re-converted if editing publishes it ready"
    FIXTURE="$(build_fixture v0.1.0)"
    clear_logs
    STUB_PR_LIST="42"
    STUB_PR_IS_DRAFT="false"
    STUB_EDIT_MAKES_READY="true"
    write_gh_stub
    write_task_stub pass
    run_helper_with_tag v0.9.0 || return 1
    [ "$(grep -cF 'gh pr ready --undo 42' "$GH_LOG")" -eq 2 ] || {
        echo "PR was not converted before push and after edit" >&2
        return 1
    }
}

test_indeterminate_title_preserves_handoff() {
    note "an indeterminate title read preserves an unchanged handed-off PR"
    FIXTURE="$(build_fixture v0.1.0)"
    clear_logs
    write_gh_stub
    write_task_stub pass
    run_helper_with_tag v0.9.0 || return 1
    _pushed_before="$(git --git-dir="$TEST_ROOT/origin.git" rev-parse bot/sync-harmon-devkit)"
    git -C "$FIXTURE" checkout --quiet main
    clear_logs
    STUB_PR_LIST="42"
    STUB_PR_IS_DRAFT="false"
    STUB_FAIL_PR_TITLE_VIEW="true"
    write_gh_stub
    ! run_helper_with_tag v0.9.0 || {
        echo "an unreadable title was treated as stale metadata" >&2
        return 1
    }
    [ "$(git --git-dir="$TEST_ROOT/origin.git" rev-parse bot/sync-harmon-devkit)" = "$_pushed_before" ] || {
        echo "an unreadable title churned the remote branch" >&2
        return 1
    }
    ! grep -qF "gh pr edit" "$GH_LOG" || {
        echo "an unreadable title triggered metadata repair" >&2
        return 1
    }
    ! grep -qF "gh pr ready --undo" "$GH_LOG" || {
        echo "an unreadable title revoked the human handoff" >&2
        return 1
    }
}

test_happy_path_with_agents() {
    note "happy path with agents block"
    FIXTURE="$(build_fixture v0.1.0)"
    add_agents_block "$FIXTURE"
    clear_logs
    write_gh_stub
    write_task_stub pass
    run_helper_with_tag v0.9.0 || return 1
    assert_pin v0.9.0 "$FIXTURE/.skills-sync.yaml" || return 1
}

test_noop_when_current() {
    note "no-op when already pinned and vendored"
    FIXTURE="$(build_fixture v0.1.0)"
    clear_logs
    write_gh_stub
    write_task_stub pass
    # First run: pin to v0.1.0 (already there — no-op if vendored matches)
    # Manually write provenance so the no-op fires
    echo "# ref: v0.1.0" >"$FIXTURE/.claude/skills/.SKILLS_PROVENANCE"
    echo "# categories: universal" >>"$FIXTURE/.claude/skills/.SKILLS_PROVENANCE"
    echo "# managed: universal" >>"$FIXTURE/.claude/skills/.SKILLS_PROVENANCE"
    mkdir -p "$FIXTURE/.claude/skills/universal"
    git -C "$FIXTURE" add .claude/skills/.SKILLS_PROVENANCE .claude/skills/universal >/dev/null 2>&1 || true
    git -C "$FIXTURE" commit -m "add provenance" >/dev/null 2>&1
    git -C "$FIXTURE" push origin main >/dev/null 2>&1
    run_helper_with_tag v0.1.0 || return 1
    # The sync always runs now (the early no-op return was removed); when the
    # pin and vendored output are already current, task sync:skills still
    # executes but produces no diff, so no commit is made and no PR is opened.
    assert_task_logged "task sync:skills" || return 1
    ! grep -qF "gh pr create" "$GH_LOG" 2>/dev/null || {
        echo "should not have opened a PR" >&2
        return 1
    }
}

test_dirty_tree_refused() {
    note "refuses a dirty working tree"
    FIXTURE="$(build_fixture v0.1.0)"
    echo "dirty" >"$FIXTURE/dirty.txt"
    clear_logs
    write_gh_stub
    write_task_stub pass
    ! run_helper_with_tag v0.9.0 || {
        echo "should have refused dirty tree"
        return 1
    }
}

test_off_base_branch_refused() {
    note "refuses to run from a non-base branch"
    FIXTURE="$(build_fixture v0.1.0)"
    git -C "$FIXTURE" checkout -b feature >/dev/null 2>&1
    clear_logs
    write_gh_stub
    write_task_stub pass
    ! run_helper_with_tag v0.9.0 || {
        echo "should have refused off-base branch"
        return 1
    }
}

test_downgrade_refused() {
    note "refuses to move the pin backwards"
    FIXTURE="$(build_fixture v0.9.0)"
    clear_logs
    write_gh_stub
    write_task_stub pass
    ! run_helper_with_tag v0.8.0 || {
        echo "should have refused downgrade"
        return 1
    }
}

test_downgrade_allowed_with_env() {
    note "allows downgrade when SYNC_DEVKIT_ALLOW_DOWNGRADE=true"
    FIXTURE="$(build_fixture v0.9.0)"
    clear_logs
    write_gh_stub
    write_task_stub pass
    SYNC_DEVKIT_ALLOW_DOWNGRADE=true run_helper_with_tag v0.8.0 || return 1
    assert_pin v0.8.0 "$FIXTURE/.skills-sync.yaml" || return 1
}

test_failing_sync_never_pushes() {
    note "a failing sync:skills never pushes"
    FIXTURE="$(build_fixture v0.1.0)"
    clear_logs
    write_gh_stub
    write_task_stub fail
    ! run_helper_with_tag v0.9.0 || {
        echo "should have failed"
        return 1
    }
    # Pin should not have changed (the helper aborts before pushing)
}

test_failing_verify_never_pushes() {
    note "a failing verification never pushes"
    FIXTURE="$(build_fixture v0.1.0)"
    clear_logs
    write_gh_stub
    # Stub task: sync passes, verify:skills:offline fails
    cat >"$BIN_DIR/task" <<'SCRIPT'
#!/usr/bin/env bash
echo "task $*" >>"$TASK_LOG"
case "${1:-}" in
sync:skills)
    mkdir -p .claude/skills/universal
    echo "# ref: $(awk '/^[[:space:]]*ref:/{sub(/^[[:space:]]*ref:[[:space:]]*/,""); print}' .skills-sync.yaml)" > .claude/skills/.SKILLS_PROVENANCE
    echo "# managed: universal" >> .claude/skills/.SKILLS_PROVENANCE
    ;;
verify:skills:offline) echo "verify failed" >&2; exit 1;;
security:secrets) ;;
*) ;;
esac
SCRIPT
    chmod +x "$BIN_DIR/task"
    ! run_helper_with_tag v0.9.0 || {
        echo "should have failed"
        return 1
    }
}

test_token_never_reaches_task() {
    note "GH_TOKEN is scrubbed from task subprocesses"
    FIXTURE="$(build_fixture v0.1.0)"
    clear_logs
    write_gh_stub
    write_task_stub pass
    export GH_TOKEN=fake-token
    # Use run_helper_with_token (not run_helper_with_tag) so GH_TOKEN reaches
    # the helper: run_untrusted must scrub it before task subprocesses see it.
    run_helper_with_token v0.9.0 || return 1
    # The task stub logs "LEAKED GH_TOKEN" if it sees the token.
    grep -qxF "LEAKED GH_TOKEN" "$TASK_LOG" && {
        echo "GH_TOKEN leaked into a task subprocess" >&2
        return 1
    } || true
}

test_app_slug_identity() {
    note "configures git identity from GH_APP_SLUG"
    FIXTURE="$(build_fixture v0.1.0)"
    clear_logs
    write_gh_stub
    write_task_stub pass
    GH_APP_SLUG=my-ci-app run_helper_with_tag v0.9.0 || return 1
    _name="$(git -C "$FIXTURE" log -1 --format='%an')"
    [ "$_name" = "my-ci-app[bot]" ] || {
        echo "expected my-ci-app[bot], got $_name" >&2
        return 1
    }
}

test_bogus_app_slug_refused() {
    note "refuses a bogus GitHub App slug"
    FIXTURE="$(build_fixture v0.1.0)"
    clear_logs
    write_gh_stub
    write_task_stub pass
    ! GH_APP_SLUG="bad/slug" run_helper_with_tag v0.9.0 || {
        echo "should have refused bogus slug"
        return 1
    }
}

test_usage_exit() {
    note "no subcommand prints usage and exits 2"
    FIXTURE="$(build_fixture v0.1.0)"
    _rc=0
    _out="$(run_helper 2>&1)" || _rc=$?
    echo "$_out" | grep -q usage || {
        echo "expected usage, got: $_out"
        return 1
    }
    [ "$_rc" -eq 2 ] || {
        echo "expected exit 2, got $_rc"
        return 1
    }
}

# ── Runner ────────────────────────────────────────────────────────────
TESTS=(
    test_resolve_latest
    test_resolve_explicit_tag
    test_reject_bad_tag_shape
    test_reject_unknown_release
    test_pinned
    test_happy_path
    test_ready_created_pr_is_reverted
    test_unresolvable_created_pr_fails
    test_created_pr_head_mismatch_fails
    test_ready_existing_pr_is_drafted_before_push
    test_updated_pr_is_rechecked_after_edit
    test_indeterminate_title_preserves_handoff
    test_happy_path_with_agents
    test_noop_when_current
    test_dirty_tree_refused
    test_off_base_branch_refused
    test_downgrade_refused
    test_downgrade_allowed_with_env
    test_failing_sync_never_pushes
    test_failing_verify_never_pushes
    test_token_never_reaches_task
    test_app_slug_identity
    test_bogus_app_slug_refused
    test_usage_exit
)

FAILED=0
for t in "${TESTS[@]}"; do
    if "$t"; then
        printf '  \033[32m✓\033[0m %s\n' "$t"
    else
        printf '  \033[31m✗\033[0m %s\n' "$t"
        FAILED=$((FAILED + 1))
    fi
done

echo ""
if [ "$FAILED" -eq 0 ]; then
    printf '\033[32mAll %d tests passed.\033[0m\n' "${#TESTS[@]}"
    exit 0
else
    printf '\033[31m%d of %d tests failed.\033[0m\n' "$FAILED" "${#TESTS[@]}"
    exit 1
fi
