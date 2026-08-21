#!/usr/bin/env bash
# test-worktree.sh — behavioral test for the worktree entrypoint. Run via
# `task test:worktree`.
#
# Everything happens inside a throwaway `git init` fixture, never in the calling
# repository: the scripts under test create and delete worktrees, and a test that
# did that to the developer's own checkout would be a data-loss path.
#
# lefthook is used for real when it is on PATH (the local/devcontainer case) and
# stubbed with a shim matching lefthook's documented contract otherwise, so the
# hook assertion runs everywhere — including CI runners that carry no lefthook.
#
# Every run is self-contained: the fixture repository, its worktree registry
# and lifecycle locks, the PATH stubs and masks, and the timeout sentinel all
# live under per-run mktemp paths, so any number of suites may run
# concurrently — `task verify` in two linked worktrees included — without
# sharing a byte of state (harmon-init#899).
set -euo pipefail

# The suite reads nothing from stdin, and its children must not inherit one
# that never ends: lefthook blocks `run post-checkout` until stdin reaches EOF
# (observed on v2.1.10), so an invocation context holding stdin open — an
# agent harness socket, a task runner pipe — deadlocks the fixture's hooks
# (harmon-init#802). /dev/null hands every child an immediate EOF. One case
# below deliberately re-introduces a never-ending stdin to prove the
# entrypoint itself is immune.
exec </dev/null

repo="$(git rev-parse --show-toplevel)"

# Hooks export GIT_DIR/GIT_WORK_TREE; left set, every `git` below would retarget
# the CALLING repository instead of the fixture. Same sanitation as
# scripts/test-template.sh.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

# Neutralize every out-of-tree source of git config. Without this the fixture is
# not hermetic: a `core.hooksPath` pointing at an absolute directory makes
# `git rev-parse --git-path hooks` resolve OUTSIDE the fixture, and installing
# hooks for the fixture would then write into that real directory — a test that
# runs inside `task verify` must never be able to do that. Config arrives from
# global and system files AND from the environment (`GIT_CONFIG_COUNT` with its
# KEY/VALUE pairs, and `GIT_CONFIG_PARAMETERS`), so all of them go.
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_CONFIG_NOSYSTEM=1
git_config_count="${GIT_CONFIG_COUNT:-0}"
case "$git_config_count" in
'' | *[!0-9]*) git_config_count=0 ;;
esac
i=0
while [ "$i" -lt "$git_config_count" ]; do
    unset "GIT_CONFIG_KEY_$i" "GIT_CONFIG_VALUE_$i"
    i=$((i + 1))
done
unset GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_ALTERNATE_OBJECT_DIRECTORIES

fail() {
    echo "TEST FAIL: $*" >&2
    exit 1
}

# Resolved to an ABSOLUTE path, not a bare name. The missing-pnpm case below
# runs under a PATH mask built from /usr/local/bin, /usr/bin and /bin, and on
# Apple Silicon Homebrew puts `gtimeout` in /opt/homebrew/bin — outside that
# set. A bare name would then fail to resolve inside the mask, the wrapper
# would exit 127 before worktree-new.sh ever ran, and that non-zero would be
# accepted as the refusal the case asserts: the test would pass while proving
# nothing.
TIMEOUT_BIN="$(command -v timeout || command -v gtimeout || true)"
if [ -z "$TIMEOUT_BIN" ]; then
    echo "GNU timeout is required (install coreutils on macOS)." >&2
    exit 1
fi
# post-checkout invokes lefthook, which has been observed to deadlock
# (harmon-init#792) with nothing else in the path bounding the wait. Every
# legitimate worktree operation here completes in single-digit seconds, so
# 120s is far above the real ceiling while still bounding a hang.
WORKTREE_OP_TIMEOUT=${WORKTREE_OP_TIMEOUT:-120}
WORKTREE_OP_KILL_GRACE=${WORKTREE_OP_KILL_GRACE:-10}

refute_exists() {
    # Spelled out rather than `[ -e X ] && fail ...`: the negative case of an
    # && list is itself a non-zero statement, which is a trap under set -e.
    if [ -e "$1" ]; then
        fail "$2"
    fi
}

# `pwd -P` because macOS mktemp hands back /var/... while git reports the
# physical /private/var/... — the two must agree for the path assertions below.
test_tmp="$(cd "$(mktemp -d -t harmon-init-worktree-XXXXXX)" && pwd -P)"
# The sentinel lives OUTSIDE $test_tmp because the cleanup below removes that
# directory, and this file has to outlive it to be read on the way out.
WORKTREE_TIMEOUT_SENTINEL="$(mktemp -t harmon-init-worktree-timeout-XXXXXX)"
rm -f "$WORKTREE_TIMEOUT_SENTINEL"

# A timeout must fail the SUITE, and `fail` alone cannot guarantee that: the
# expected-failure cases run these wrappers inside `if ( … ); then` subshells,
# where `exit 1` ends only the subshell and the `if` reads the non-zero status
# as the refusal it was asserting. A hang would be accepted as a pass. The
# sentinel escapes every subshell — it is a file, not an exit status — so
# however the status is swallowed, the suite still ends non-zero and says why.
# Initialized empty BEFORE the trap is armed: an exported variable of this
# name would otherwise flow in from the environment and the cleanup below
# would kill a PID this suite never owned.
WORKTREE_STDIN_HOLDER=""
worktree_exit() {
    exit_status=$?
    # Reap the hostile-stdin writer if a case aborted before its explicit kill
    # — it is backgrounded outside the timeout's process group, so nothing
    # else collects it on a failing run (harmon-init#802).
    if [ -n "${WORKTREE_STDIN_HOLDER:-}" ]; then
        kill "$WORKTREE_STDIN_HOLDER" 2>/dev/null || true
    fi
    if [ -e "$WORKTREE_TIMEOUT_SENTINEL" ]; then
        # Print what the sentinel HOLDS, not where it lives: it is removed
        # immediately below, so a path would point at nothing by the time
        # anyone read the message.
        echo "TEST FAIL: $(cat "$WORKTREE_TIMEOUT_SENTINEL") — the operation was killed, not merely slow (harmon-init#792)" >&2
        exit_status=1
    fi
    rm -f "$WORKTREE_TIMEOUT_SENTINEL" || true
    # Teardown must not be able to fail the suite in silence (harmon-init#899):
    # this trap runs under set -e, so a bare `rm -rf` that failed used to
    # abort the trap mid-way and exit 1 with rm's raw stderr as the only clue
    # — after the suite had already printed its success line, which reads as
    # an inexplicable flake. Retry once (a straggler from a killed operation
    # can hold the tree for a moment), then fail loudly, naming the
    # survivors. The retry is tolerance; the contract is loudness.
    if ! rm -rf "$test_tmp" 2>/dev/null; then
        sleep 2
        if ! rm -rf "$test_tmp"; then
            echo "TEST FAIL: teardown could not remove $test_tmp — survivors:" >&2
            find "$test_tmp" 2>/dev/null | head -20 >&2 || true
            exit 1
        fi
    fi
    exit "$exit_status"
}
trap worktree_exit EXIT

stub_bin="$test_tmp/bin"
mkdir -p "$stub_bin"

if command -v lefthook >/dev/null 2>&1; then
    echo "==> Using the real lefthook for the hook assertions"
else
    echo "==> lefthook not installed — stubbing its install contract"
    cat >"$stub_bin/lefthook" <<'STUB'
#!/usr/bin/env bash
# Minimal stand-in for `lefthook install`: writes the same shim shape lefthook
# generates — honouring LEFTHOOK=0 and LEFTHOOK_BIN — so the entrypoint's hook
# probe exercises the real contract even where lefthook is not installed.
set -euo pipefail
git_hook_names="applypatch-msg pre-applypatch post-applypatch pre-commit pre-merge-commit prepare-commit-msg commit-msg post-commit pre-rebase post-checkout post-merge pre-push pre-receive update proc-receive post-receive post-update reference-transaction push-to-checkout pre-auto-gc post-rewrite sendemail-validate fsmonitor-watchman p4-changelist p4-prepare-changelist p4-post-changelist p4-pre-submit post-index-change"
case "${1:-}" in
install)
    hooks="$(git rev-parse --path-format=absolute --git-path hooks)"
    mkdir -p "$hooks"
    # EVERY hook lefthook.yml configures, exactly as the real `lefthook install`
    # does. Writing only pre-commit would make this stub disagree with the real
    # binary about what "installed" means, and the multi-hook assertions would
    # then pass locally (real lefthook) and fail on any runner without it.
    for key in $(awk -F: '/^[a-z][a-z-]*:/ {print $1}' lefthook.yml); do
        case " $git_hook_names " in
        *" $key "*) ;;
        *) continue ;;
        esac
        sed "s/@HOOK@/$key/g" >"$hooks/$key" <<'HOOK'
#!/bin/sh
if [ "$LEFTHOOK" = "0" ]; then
  exit 0
fi
if test -n "$LEFTHOOK_BIN"; then
  "$LEFTHOOK_BIN" run "@HOOK@" "$@"
else
  lefthook run "@HOOK@" "$@"
fi
HOOK
        chmod +x "$hooks/$key"
    done
    ;;
*) exit 0 ;;
esac
STUB
    chmod +x "$stub_bin/lefthook"
fi

PATH="$stub_bin:$PATH"
export PATH

# ── Fixture repository ───────────────────────────────────────────────
fixture="$test_tmp/fixture"
mkdir -p "$fixture/scripts"
cp "$repo/scripts/worktree-new.sh" "$repo/scripts/worktree-rm.sh" "$repo/scripts/worktree-lock.sh" "$fixture/scripts/"
chmod +x "$fixture/scripts/worktree-new.sh" "$fixture/scripts/worktree-rm.sh"
cat >"$fixture/lefthook.yml" <<'EOF'
pre-commit:
  commands:
    noop:
      run: "true"
EOF
printf 'fixture\n' >"$fixture/README.md"

git -C "$fixture" init -q
git -C "$fixture" config user.name "Worktree Test"
git -C "$fixture" config user.email "worktree-test@example.invalid"
git -C "$fixture" config commit.gpgsign false
git -C "$fixture" add -A
git -C "$fixture" commit -qm "chore: fixture"
# Containment is asserted BEFORE anything installs a hook, and it is asserted on
# the path git itself resolves — so it holds whatever made the path escape
# (global config, system config, GIT_CONFIG_* in the environment, a future
# mechanism). Checking afterwards would report the escape only once the damage
# was done.
shared_hooks="$(cd "$fixture" && git rev-parse --path-format=absolute --git-path hooks)"
case "$shared_hooks" in
"$test_tmp"/*) : ;;
*) fail "refusing to install hooks: the fixture's hooks directory resolves outside the sandbox ($shared_hooks)" ;;
esac
(cd "$fixture" && lefthook install >/dev/null 2>&1) || fail "could not install hooks in the fixture"

# `-k` is not optional: without it `timeout` sends TERM at the deadline and
# then waits forever if the process ignores it — which is the very hang this
# bound exists to stop. The grace period converts that into a KILL.
#
# A timeout is FATAL, never a return value. Many cases below assert that these
# wrappers fail (`if new …; then fail …; fi`), usually with output redirected
# to /dev/null, so a returned 124 would be indistinguishable from the expected
# refusal: the hang would read as a pass, and the state assertions after it
# would agree because the operation never ran. `fail` exits, so a deadlock can
# only ever end the suite loudly.
# ONE bounded entry point for every worktree-new.sh / worktree-rm.sh
# invocation. The nested-caller cases below run the script from inside a
# linked worktree, and when those called it directly they bypassed the bound
# entirely — the same indefinite hang, reachable by three call sites that
# happened not to use the wrapper.
run_worktree_op() {
    op_label=$1
    op_dir=$2
    op_script=$3
    shift 3
    status=0
    (cd "$op_dir" && "$TIMEOUT_BIN" -k "$WORKTREE_OP_KILL_GRACE" "$WORKTREE_OP_TIMEOUT" bash "$op_script" "$@") || status=$?
    if [ "$status" -eq 124 ] || [ "$status" -eq 137 ]; then
        echo "$op_label timed out after ${WORKTREE_OP_TIMEOUT}s: $*" >"$WORKTREE_TIMEOUT_SENTINEL"
        fail "$op_label timed out after ${WORKTREE_OP_TIMEOUT}s: $* (see harmon-init#792)"
    fi
    return "$status"
}
new() { run_worktree_op "worktree:new" "$fixture" scripts/worktree-new.sh "$@"; }
# Same operation, run from a caller directory that is not the main worktree.
new_in() {
    op_from=$1
    shift
    run_worktree_op "worktree:new" "$op_from" scripts/worktree-new.sh "$@"
}
# Map a worktree path to its admin-record directory, the way worktree-rm.sh
# does: each record's `gitdir` file names that worktree's .git file.
record_admin_dir_probe() {
    probe_common="$(git -C "$1" rev-parse --path-format=absolute --git-common-dir)"
    for probe_candidate in "$probe_common"/worktrees/*; do
        [ -f "$probe_candidate/gitdir" ] || continue
        if [ "$(cat "$probe_candidate/gitdir" 2>/dev/null || true)" = "$2/.git" ]; then
            printf '%s\n' "$probe_candidate"
            return 0
        fi
    done
    return 1
}
rm_wt() { run_worktree_op "worktree:rm" "$fixture" scripts/worktree-rm.sh "$@"; }
# Removal run from inside the tree being removed: caller directory and script
# path both differ, and it is the last invocation that would otherwise bypass
# the bound.
rm_in() {
    op_from=$1
    op_path=$2
    shift 2
    run_worktree_op "worktree:rm" "$op_from" "$op_path" "$@"
}

# ── create → work inside → remove ────────────────────────────────────
echo "==> worktree:new creates .worktrees/<name> with its own branch"
out="$(new scratch)" || fail "worktree-new.sh failed"
[ -d "$fixture/.worktrees/scratch" ] || fail "worktree-new.sh did not create .worktrees/scratch"
git -C "$fixture" worktree list --porcelain | grep -qx "worktree $fixture/.worktrees/scratch" ||
    fail "the new tree is not registered as a worktree"
git -C "$fixture" show-ref --verify --quiet refs/heads/scratch ||
    fail "worktree-new.sh did not create the branch"
case "$out" in *"Worktree ready:"*) : ;; *) fail "worktree-new.sh did not print the ready path" ;; esac

echo "==> hooks are asserted, not assumed, inside the new tree"
case "$out" in *"Hooks verified"*) : ;; *) fail "worktree-new.sh did not verify hooks in the new tree" ;; esac
tree_hooks="$(git -C "$fixture/.worktrees/scratch" rev-parse --path-format=absolute --git-path hooks)"
[ "$tree_hooks" = "$shared_hooks" ] ||
    fail "git in the linked worktree resolves hooks to $tree_hooks, not the shared $shared_hooks"
[ -x "$tree_hooks/pre-commit" ] || fail "no executable pre-commit hook for the linked worktree"
# The gotcha this entrypoint exists to absorb: in a linked worktree `.git` is a
# FILE, so a hand-rolled `-c core.hooksPath=.git/hooks` resolves to nothing.
[ -f "$fixture/.worktrees/scratch/.git" ] ||
    fail "fixture assumption broken: .git in a linked worktree should be a file"

echo "==> a commit made INSIDE the worktree runs the shared hooks"
cat >"$test_tmp/commit-probe" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$test_tmp/commit-probe.log"
EOF
chmod +x "$test_tmp/commit-probe"
printf 'work\n' >"$fixture/.worktrees/scratch/WORK.md"
git -C "$fixture/.worktrees/scratch" add WORK.md
LEFTHOOK_BIN="$test_tmp/commit-probe" \
    git -C "$fixture/.worktrees/scratch" commit -qm "chore: work in the worktree" \
    >"$test_tmp/commit.log" 2>&1 ||
    {
        cat "$test_tmp/commit.log" >&2
        fail "committing inside the worktree failed"
    }
grep -qx "run pre-commit" "$test_tmp/commit-probe.log" 2>/dev/null ||
    fail "the pre-commit hook did not fire for a real commit inside the worktree"

echo "==> a second create with the same name fails loudly"
if new scratch >/dev/null 2>&1; then
    fail "worktree-new.sh silently reused an existing path"
fi

echo "==> worktree:rm removes the tree and prunes the registry"
rm_wt scratch >/dev/null || fail "worktree-rm.sh failed on a clean tree"
refute_exists "$fixture/.worktrees/scratch" "worktree-rm.sh left the directory behind"
if git -C "$fixture" worktree list --porcelain | grep -q "scratch"; then
    fail "worktree-rm.sh left a stale registry record"
fi

# ── dirty-tree refusal ───────────────────────────────────────────────
echo "==> worktree:rm refuses a dirty tree, and --force overrides"
new dirty >/dev/null || fail "worktree-new.sh failed for the dirty-tree case"
printf 'uncommitted\n' >"$fixture/.worktrees/dirty/NOTES.md"
if rm_wt dirty >/dev/null 2>&1; then
    fail "worktree-rm.sh removed a dirty tree without --force"
fi
[ -d "$fixture/.worktrees/dirty" ] || fail "worktree-rm.sh removed the dirty tree despite refusing"
rm_wt dirty --force >/dev/null || fail "worktree-rm.sh --force failed on a dirty tree"
refute_exists "$fixture/.worktrees/dirty" "worktree-rm.sh --force left the directory behind"

# ── edits hidden by skip-worktree / assume-unchanged ─────────────────
# Git omits entries carrying either flag from `git status --porcelain` AND
# `git diff-files` — hiding a locally modified tracked file is what the flags
# are for — so the dirty-tree refusal above cannot see them, and before
# harmon-init#785 an ordinary removal deleted the edit while reporting
# success. Each case asserts the porcelain status is EMPTY first: were the
# edit visible there, the ordinary dirty check would refuse and the case
# would pass without exercising the hidden-edit guard at all.
echo "==> worktree:rm refuses an edit hidden by skip-worktree, and --force overrides"
new hidden-skip >/dev/null || fail "worktree-new.sh failed for the skip-worktree case"
git -C "$fixture/.worktrees/hidden-skip" update-index --skip-worktree README.md
printf 'hidden edit\n' >"$fixture/.worktrees/hidden-skip/README.md"
[ -z "$(git -C "$fixture/.worktrees/hidden-skip" status --porcelain)" ] ||
    fail "fixture assumption broken: a skip-worktree edit shows in git status"
if rm_wt hidden-skip >"$test_tmp/hidden-skip.log" 2>&1; then
    fail "worktree-rm.sh removed a tree with a skip-worktree-hidden edit without --force"
fi
grep -qx 'hidden edit' "$fixture/.worktrees/hidden-skip/README.md" 2>/dev/null ||
    fail "the skip-worktree-hidden edit did not survive the refusal"
grep -q 'README.md' "$test_tmp/hidden-skip.log" ||
    fail "the refusal did not name the hidden path"
rm_wt hidden-skip --force >/dev/null || fail "worktree-rm.sh --force failed on a skip-worktree-hidden edit"
refute_exists "$fixture/.worktrees/hidden-skip" "worktree-rm.sh --force left the directory behind"

echo "==> worktree:rm refuses an edit hidden by assume-unchanged"
new hidden-assume >/dev/null || fail "worktree-new.sh failed for the assume-unchanged case"
git -C "$fixture/.worktrees/hidden-assume" update-index --assume-unchanged README.md
printf 'hidden edit\n' >"$fixture/.worktrees/hidden-assume/README.md"
[ -z "$(git -C "$fixture/.worktrees/hidden-assume" status --porcelain)" ] ||
    fail "fixture assumption broken: an assume-unchanged edit shows in git status"
if rm_wt hidden-assume >/dev/null 2>&1; then
    fail "worktree-rm.sh removed a tree with an assume-unchanged-hidden edit without --force"
fi
grep -qx 'hidden edit' "$fixture/.worktrees/hidden-assume/README.md" 2>/dev/null ||
    fail "the assume-unchanged-hidden edit did not survive the refusal"
rm_wt hidden-assume --force >/dev/null || fail "worktree-rm.sh --force failed on an assume-unchanged-hidden edit"
refute_exists "$fixture/.worktrees/hidden-assume" "worktree-rm.sh --force left the directory behind"

echo "==> an UNMODIFIED flagged entry does not block an ordinary removal"
new hidden-clean >/dev/null || fail "worktree-new.sh failed for the unmodified-flag case"
git -C "$fixture/.worktrees/hidden-clean" update-index --skip-worktree README.md
rm_wt hidden-clean >/dev/null ||
    fail "worktree-rm.sh refused an ordinary removal over an unmodified skip-worktree entry"
refute_exists "$fixture/.worktrees/hidden-clean" "worktree-rm.sh left the tree behind"

echo "==> a clean SPARSE worktree is removable (absent skip-worktree paths)"
# Sparse checkout marks every excluded path skip-worktree with no file on
# disk, so treating that absence as a hidden edit would refuse the removal
# of every clean sparse worktree. `sparse-checkout set` scopes its config to
# the worktree (extensions.worktreeConfig), so the shared fixture is not
# affected.
new hidden-sparse >/dev/null || fail "worktree-new.sh failed for the sparse case"
git -C "$fixture/.worktrees/hidden-sparse" sparse-checkout set --no-cone '/scripts' >/dev/null 2>&1 ||
    fail "could not enable sparse checkout in the fixture worktree"
[ ! -e "$fixture/.worktrees/hidden-sparse/README.md" ] ||
    fail "fixture assumption broken: sparse checkout left README.md in place"
git -C "$fixture/.worktrees/hidden-sparse" ls-files -v | grep -q '^S README.md' ||
    fail "fixture assumption broken: sparse README.md is not marked skip-worktree"
rm_wt hidden-sparse >/dev/null ||
    fail "worktree-rm.sh refused an ordinary removal of a clean sparse worktree"
refute_exists "$fixture/.worktrees/hidden-sparse" "worktree-rm.sh left the tree behind"

echo "==> a DELETED in-cone flagged file in a SPARSE tree blocks removal"
# Sparse-enabled is a per-tree fact; the skip-worktree flag is per path. A
# user who manually flags an IN-CONE (included) file and deletes it shows
# the same absent-`S` state as a sparse-excluded path, and the pre-#919
# guard skipped it as sparse-absent — discarding the uncommitted
# deletion-intent. The active rules decide now: excluded stays exempt (the
# case above), in-cone refuses, naming the path.
new hidden-sparse-cone >/dev/null || fail "worktree-new.sh failed for the in-cone sparse case"
git -C "$fixture/.worktrees/hidden-sparse-cone" sparse-checkout set --no-cone '/scripts' >/dev/null 2>&1 ||
    fail "could not enable sparse checkout in the fixture worktree"
[ -f "$fixture/.worktrees/hidden-sparse-cone/scripts/worktree-lock.sh" ] ||
    fail "fixture assumption broken: sparse checkout removed an in-cone file"
git -C "$fixture/.worktrees/hidden-sparse-cone" update-index --skip-worktree scripts/worktree-lock.sh
rm "$fixture/.worktrees/hidden-sparse-cone/scripts/worktree-lock.sh"
[ -z "$(git -C "$fixture/.worktrees/hidden-sparse-cone" status --porcelain)" ] ||
    fail "fixture assumption broken: the flagged in-cone deletion shows in git status"
cone_out="$(rm_wt hidden-sparse-cone 2>&1)" &&
    fail "worktree-rm.sh removed a sparse tree with a deleted in-cone flagged file without --force"
case "$cone_out" in *"scripts/worktree-lock.sh"*) : ;; *) fail "the in-cone sparse refusal did not name the deleted path" ;; esac
rm_wt hidden-sparse-cone --force >/dev/null || fail "worktree-rm.sh --force failed on the in-cone sparse case"
refute_exists "$fixture/.worktrees/hidden-sparse-cone" "worktree-rm.sh --force left the directory behind"

echo "==> on git < 2.42 the whole-tree sparse exemption is kept (#919 decision)"
# The decided AC-3 behavior: without `sparse-checkout check-rules` the
# guard cannot ask the rules, and it deliberately keeps the pre-#919
# per-tree exemption rather than failing closed — which would refuse every
# clean sparse removal on e.g. macOS system git ~2.39 and teach routine
# --force. The stub fakes ONLY the version probe; a correct gate then never
# invokes check-rules, so delegating everything else to the real git is
# faithful — while a gate that ignores the version DOES reach the real
# check-rules, refuses the deletion below, and fails this case.
oldgit_dir="$test_tmp/oldgit-bin"
mkdir -p "$oldgit_dir"
real_git="$(command -v git)"
cat >"$oldgit_dir/git" <<OLDGIT
#!/usr/bin/env bash
if [ "\$1" = "--version" ]; then
    echo "git version 2.39.5"
    exit 0
fi
exec "$real_git" "\$@"
OLDGIT
chmod +x "$oldgit_dir/git"
new hidden-sparse-oldgit >/dev/null || fail "worktree-new.sh failed for the old-git sparse case"
git -C "$fixture/.worktrees/hidden-sparse-oldgit" sparse-checkout set --no-cone '/scripts' >/dev/null 2>&1 ||
    fail "could not enable sparse checkout in the fixture worktree"
git -C "$fixture/.worktrees/hidden-sparse-oldgit" update-index --skip-worktree scripts/worktree-lock.sh
rm "$fixture/.worktrees/hidden-sparse-oldgit/scripts/worktree-lock.sh"
(
    PATH="$oldgit_dir:$PATH"
    export PATH
    rm_wt hidden-sparse-oldgit >/dev/null
) || fail "worktree-rm.sh on git < 2.42 did not keep the documented whole-tree sparse exemption"
refute_exists "$fixture/.worktrees/hidden-sparse-oldgit" "worktree-rm.sh left the tree behind"

echo "==> a check-rules failure fails CLOSED, refusing the removal"
# The batch query's success sentinel mirrors the enumeration's: bash does
# not propagate a process-substitution failure, so without the sentinel a
# check-rules error would be swallowed and the removal waved through on an
# unevaluated exemption. The shim passes the version gate (real git
# answers --version) and breaks exactly the check-rules invocation; the
# tree's absent excluded entries are candidate enough to force the batch
# query to run.
brokenrules_dir="$test_tmp/brokenrules-bin"
mkdir -p "$brokenrules_dir"
cat >"$brokenrules_dir/git" <<BROKENRULES
#!/usr/bin/env bash
for brk_arg in "\$@"; do
    if [ "\$brk_arg" = "check-rules" ]; then
        echo "git: simulated check-rules failure" >&2
        exit 1
    fi
done
exec "$real_git" "\$@"
BROKENRULES
chmod +x "$brokenrules_dir/git"
new hidden-sparse-broken >/dev/null || fail "worktree-new.sh failed for the broken-rules case"
git -C "$fixture/.worktrees/hidden-sparse-broken" sparse-checkout set --no-cone '/scripts' >/dev/null 2>&1 ||
    fail "could not enable sparse checkout in the fixture worktree"
if (
    PATH="$brokenrules_dir:$PATH"
    export PATH
    rm_wt hidden-sparse-broken >/dev/null 2>&1
); then
    fail "worktree-rm.sh removed a sparse tree although the sparse-rules check failed"
fi
[ -d "$fixture/.worktrees/hidden-sparse-broken" ] || fail "the tree was removed despite the fail-closed refusal"
rm_wt hidden-sparse-broken >/dev/null || fail "cleanup of the broken-rules tree failed"
refute_exists "$fixture/.worktrees/hidden-sparse-broken" "worktree-rm.sh left the tree behind"

echo "==> a DELETED skip-worktree file WITHOUT sparse checkout blocks removal"
# Absence is only sparse-normal where sparse checkout is actually enabled;
# without it, an absent flagged file can only be a user's uncommitted
# deletion.
new hidden-swdel >/dev/null || fail "worktree-new.sh failed for the skip-worktree-deletion case"
git -C "$fixture/.worktrees/hidden-swdel" update-index --skip-worktree README.md
rm "$fixture/.worktrees/hidden-swdel/README.md"
[ -z "$(git -C "$fixture/.worktrees/hidden-swdel" status --porcelain)" ] ||
    fail "fixture assumption broken: a skip-worktree deletion shows in git status"
if rm_wt hidden-swdel >/dev/null 2>&1; then
    fail "worktree-rm.sh removed a tree with a skip-worktree-hidden deletion without --force"
fi
rm_wt hidden-swdel --force >/dev/null || fail "worktree-rm.sh --force failed on a skip-worktree deletion"
refute_exists "$fixture/.worktrees/hidden-swdel" "worktree-rm.sh --force left the directory behind"

echo "==> a chmod-only change to a flagged file blocks removal"
# The content hash cannot see an executable-bit change, but where
# core.fileMode says the filesystem tracks it, a chmod is an uncommitted
# change like any edit.
if [ "$(git -C "$fixture" config --get --type=bool --default=true core.fileMode)" = "true" ]; then
    new hidden-mode >/dev/null || fail "worktree-new.sh failed for the chmod case"
    git -C "$fixture/.worktrees/hidden-mode" update-index --skip-worktree README.md
    chmod +x "$fixture/.worktrees/hidden-mode/README.md"
    [ -z "$(git -C "$fixture/.worktrees/hidden-mode" status --porcelain)" ] ||
        fail "fixture assumption broken: a flagged chmod shows in git status"
    if rm_wt hidden-mode >/dev/null 2>&1; then
        fail "worktree-rm.sh removed a tree with a chmod-only hidden change without --force"
    fi
    rm_wt hidden-mode --force >/dev/null || fail "worktree-rm.sh --force failed on a chmod-only change"
    refute_exists "$fixture/.worktrees/hidden-mode" "worktree-rm.sh --force left the directory behind"
else
    echo "    (skipped: fixture filesystem does not track the executable bit)"
fi

echo "==> an UNMODIFIED flagged file under an eol filter does not block removal"
# With `eol=crlf` the checkout legitimately differs byte-for-byte from the
# index blob, so a raw-byte comparison would report every clean flagged
# checkout as a hidden edit; the guard must compare content as git sees it
# (clean filter applied). Scoped to one filename nothing else uses so the
# shared fixture attributes cannot leak into other cases.
printf 'hidden-filter.txt text eol=crlf\n' >>"$(git -C "$fixture" rev-parse --path-format=absolute --git-path info/attributes)"
new hidden-filter >/dev/null || fail "worktree-new.sh failed for the eol-filter case"
printf 'line one\nline two\n' >"$fixture/.worktrees/hidden-filter/hidden-filter.txt"
git -C "$fixture/.worktrees/hidden-filter" add hidden-filter.txt
LEFTHOOK=0 git -C "$fixture/.worktrees/hidden-filter" commit -qm "chore: eol-filtered file"
rm "$fixture/.worktrees/hidden-filter/hidden-filter.txt"
git -C "$fixture/.worktrees/hidden-filter" checkout -- hidden-filter.txt
grep -q "$(printf 'line one\r')" "$fixture/.worktrees/hidden-filter/hidden-filter.txt" ||
    fail "fixture assumption broken: the eol=crlf checkout does not carry CRLF"
git -C "$fixture/.worktrees/hidden-filter" update-index --skip-worktree hidden-filter.txt
rm_wt hidden-filter >/dev/null ||
    fail "worktree-rm.sh refused an ordinary removal over a clean eol-filtered flagged file"
refute_exists "$fixture/.worktrees/hidden-filter" "worktree-rm.sh left the tree behind"

echo "==> an edit a LOSSY clean filter would normalize away still blocks removal"
# A non-round-tripping clean filter makes the cleaned working file hash
# identical to the index blob, so a cleaned-hash comparison would wave the
# edit through — and the discarded bytes are exactly what a fresh checkout
# cannot restore. The guard must compare against the checkout
# representation instead. The filter config is shared repo config, but the
# attribute is scoped to one filename nothing else uses.
git -C "$fixture" config filter.testlossy.clean "grep -v '^LOCAL:' || true"
printf 'hidden-lossy.txt filter=testlossy\n' >>"$(git -C "$fixture" rev-parse --path-format=absolute --git-path info/attributes)"
new hidden-lossy >/dev/null || fail "worktree-new.sh failed for the lossy-filter case"
printf 'shared line\n' >"$fixture/.worktrees/hidden-lossy/hidden-lossy.txt"
git -C "$fixture/.worktrees/hidden-lossy" add hidden-lossy.txt
LEFTHOOK=0 git -C "$fixture/.worktrees/hidden-lossy" commit -qm "chore: lossy-filtered file"
printf 'shared line\nLOCAL: uncommitted local-only note\n' >"$fixture/.worktrees/hidden-lossy/hidden-lossy.txt"
git -C "$fixture/.worktrees/hidden-lossy" update-index --skip-worktree hidden-lossy.txt
[ -z "$(git -C "$fixture/.worktrees/hidden-lossy" status --porcelain)" ] ||
    fail "fixture assumption broken: the lossy-filtered edit shows in git status"
if rm_wt hidden-lossy >/dev/null 2>&1; then
    fail "worktree-rm.sh removed a tree whose edit only a lossy clean filter hides"
fi
grep -q 'LOCAL: uncommitted' "$fixture/.worktrees/hidden-lossy/hidden-lossy.txt" ||
    fail "the lossy-hidden edit did not survive the refusal"
rm_wt hidden-lossy --force >/dev/null || fail "worktree-rm.sh --force failed on the lossy-filter case"
refute_exists "$fixture/.worktrees/hidden-lossy" "worktree-rm.sh --force left the directory behind"

echo "==> a DELETED assume-unchanged file still blocks removal"
# Absence is only sparse-normal for skip-worktree entries. git never marks a
# path assume-unchanged on its own, so an absent one means the user deleted
# a file they had flagged — an uncommitted deletion the removal would
# discard.
new hidden-del >/dev/null || fail "worktree-new.sh failed for the hidden-deletion case"
git -C "$fixture/.worktrees/hidden-del" update-index --assume-unchanged README.md
rm "$fixture/.worktrees/hidden-del/README.md"
[ -z "$(git -C "$fixture/.worktrees/hidden-del" status --porcelain)" ] ||
    fail "fixture assumption broken: an assume-unchanged deletion shows in git status"
if rm_wt hidden-del >/dev/null 2>&1; then
    fail "worktree-rm.sh removed a tree with an assume-unchanged-hidden deletion without --force"
fi
[ -d "$fixture/.worktrees/hidden-del" ] || fail "the tree was removed despite the refusal"
rm_wt hidden-del --force >/dev/null || fail "worktree-rm.sh --force failed on a hidden deletion"
refute_exists "$fixture/.worktrees/hidden-del" "worktree-rm.sh --force left the directory behind"

echo "==> an UNMODIFIED flagged symlink does not block removal"
# Hashing a symlink's PATH follows the link, so a content hash would compare
# the target file's bytes against an index blob that holds the target STRING
# — every clean flagged symlink would read as a hidden edit.
new hidden-link >/dev/null || fail "worktree-new.sh failed for the symlink case"
ln -s README.md "$fixture/.worktrees/hidden-link/hidden-link-ln"
git -C "$fixture/.worktrees/hidden-link" add hidden-link-ln
LEFTHOOK=0 git -C "$fixture/.worktrees/hidden-link" commit -qm "chore: tracked symlink"
git -C "$fixture/.worktrees/hidden-link" update-index --skip-worktree hidden-link-ln
rm_wt hidden-link >/dev/null ||
    fail "worktree-rm.sh refused an ordinary removal over an unmodified flagged symlink"
refute_exists "$fixture/.worktrees/hidden-link" "worktree-rm.sh left the tree behind"

echo "==> a REPOINTED flagged symlink blocks removal"
new hidden-link-mod >/dev/null || fail "worktree-new.sh failed for the repointed-symlink case"
ln -s README.md "$fixture/.worktrees/hidden-link-mod/hidden-link-ln2"
git -C "$fixture/.worktrees/hidden-link-mod" add hidden-link-ln2
LEFTHOOK=0 git -C "$fixture/.worktrees/hidden-link-mod" commit -qm "chore: tracked symlink"
git -C "$fixture/.worktrees/hidden-link-mod" update-index --skip-worktree hidden-link-ln2
rm "$fixture/.worktrees/hidden-link-mod/hidden-link-ln2"
ln -s lefthook.yml "$fixture/.worktrees/hidden-link-mod/hidden-link-ln2"
[ -z "$(git -C "$fixture/.worktrees/hidden-link-mod" status --porcelain)" ] ||
    fail "fixture assumption broken: a flagged symlink repoint shows in git status"
if rm_wt hidden-link-mod >/dev/null 2>&1; then
    fail "worktree-rm.sh removed a tree with a repointed flagged symlink without --force"
fi
rm_wt hidden-link-mod --force >/dev/null || fail "worktree-rm.sh --force failed on a repointed symlink"
refute_exists "$fixture/.worktrees/hidden-link-mod" "worktree-rm.sh --force left the directory behind"

echo "==> a flagged filename that looks like pathspec magic is looked up literally"
# `git ls-files -s -- ':(literal)foo'` resolves the pathspec MAGIC — the
# entry for `foo` — not the file literally named `:(literal)foo`. Comparing
# against the wrong blob waved a real edit through when its content matched
# the other file's checkout.
new hidden-magic >/dev/null || fail "worktree-new.sh failed for the pathspec-magic case"
printf 'AAA\n' >"$fixture/.worktrees/hidden-magic/plain-foo"
printf 'BBB\n' >"$fixture/.worktrees/hidden-magic/:(literal)plain-foo"
# --literal-pathspecs on the setup too: `git add ':(literal)plain-foo'`
# would itself resolve the magic and add plain-foo instead.
git --literal-pathspecs -C "$fixture/.worktrees/hidden-magic" add plain-foo ':(literal)plain-foo'
LEFTHOOK=0 git -C "$fixture/.worktrees/hidden-magic" commit -qm "chore: magic-named file"
git --literal-pathspecs -C "$fixture/.worktrees/hidden-magic" update-index --skip-worktree ':(literal)plain-foo'
printf 'AAA\n' >"$fixture/.worktrees/hidden-magic/:(literal)plain-foo"
[ -z "$(git -C "$fixture/.worktrees/hidden-magic" status --porcelain)" ] ||
    fail "fixture assumption broken: the magic-named edit shows in git status"
if rm_wt hidden-magic >/dev/null 2>&1; then
    fail "worktree-rm.sh removed a tree whose magic-named flagged file was edited"
fi
rm_wt hidden-magic --force >/dev/null || fail "worktree-rm.sh --force failed on the pathspec-magic case"
refute_exists "$fixture/.worktrees/hidden-magic" "worktree-rm.sh --force left the directory behind"

echo "==> core.symlinks=false: a real symlink refuses, the regular-file form passes"
# With core.symlinks=false git checks a 120000 entry out as a regular file
# holding the target text — so THAT is the clean representation there, and
# an actual symlink is a local type change the guard must refuse.
git -C "$fixture" config extensions.worktreeConfig true
new hidden-symfalse >/dev/null || fail "worktree-new.sh failed for the core.symlinks case"
ln -s README.md "$fixture/.worktrees/hidden-symfalse/hidden-sym-ln"
git -C "$fixture/.worktrees/hidden-symfalse" add hidden-sym-ln
LEFTHOOK=0 git -C "$fixture/.worktrees/hidden-symfalse" commit -qm "chore: tracked symlink"
git -C "$fixture/.worktrees/hidden-symfalse" config --worktree core.symlinks false
git -C "$fixture/.worktrees/hidden-symfalse" update-index --skip-worktree hidden-sym-ln
if rm_wt hidden-symfalse >/dev/null 2>&1; then
    fail "worktree-rm.sh accepted a real symlink as clean under core.symlinks=false"
fi
rm "$fixture/.worktrees/hidden-symfalse/hidden-sym-ln"
printf '%s' README.md >"$fixture/.worktrees/hidden-symfalse/hidden-sym-ln"
rm_wt hidden-symfalse >/dev/null ||
    fail "worktree-rm.sh refused the regular-file symlink representation under core.symlinks=false"
refute_exists "$fixture/.worktrees/hidden-symfalse" "worktree-rm.sh left the tree behind"

echo "==> an UNINITIALIZED flagged gitlink does not block removal"
# An uninitialized submodule checks out as an empty directory (index mode
# 160000) — nothing local to lose, and native 'git worktree remove' accepts
# it. Initialized submodules never reach the decision: git refuses to remove
# worktrees containing them.
new hidden-sub >/dev/null || fail "worktree-new.sh failed for the gitlink case"
subsha="$(git -C "$fixture/.worktrees/hidden-sub" rev-parse HEAD)"
git -C "$fixture/.worktrees/hidden-sub" update-index --add --cacheinfo "160000,$subsha,hidden-sub-mod"
LEFTHOOK=0 git -C "$fixture/.worktrees/hidden-sub" commit -qm "chore: gitlink"
mkdir "$fixture/.worktrees/hidden-sub/hidden-sub-mod"
git -C "$fixture/.worktrees/hidden-sub" update-index --skip-worktree hidden-sub-mod
[ -z "$(git -C "$fixture/.worktrees/hidden-sub" status --porcelain)" ] ||
    fail "fixture assumption broken: the flagged gitlink shows in git status"
rm_wt hidden-sub >/dev/null ||
    fail "worktree-rm.sh refused an ordinary removal over an uninitialized flagged gitlink"
refute_exists "$fixture/.worktrees/hidden-sub" "worktree-rm.sh left the tree behind"

echo "==> a flagged filename containing a NEWLINE is parsed intact"
# `ls-files -z` keeps a newline inside a filename verbatim; a line-based
# sha extraction read the name's remainder as more records, corrupted the
# sha, and falsely refused a byte-identical flagged file.
new hidden-nl >/dev/null || fail "worktree-new.sh failed for the newline-name case"
nl_name="$(printf 'odd\nsecond field')"
printf 'content\n' >"$fixture/.worktrees/hidden-nl/$nl_name"
git -C "$fixture/.worktrees/hidden-nl" add "$nl_name"
LEFTHOOK=0 git -C "$fixture/.worktrees/hidden-nl" commit -qm "chore: newline-named file"
git -C "$fixture/.worktrees/hidden-nl" update-index --skip-worktree "$nl_name"
rm_wt hidden-nl >/dev/null ||
    fail "worktree-rm.sh falsely refused over an unmodified newline-named flagged file"
refute_exists "$fixture/.worktrees/hidden-nl" "worktree-rm.sh left the tree behind"

# ── ignored local files are not silently deleted ─────────────────────
# `git worktree remove` counts modified and untracked files but not ignored
# ones, so a plain remove would take a .env with it.
echo "==> worktree:rm refuses to delete ignored local FILES without --force"
printf '.env\nnode_modules/\nlocal-data/\n__pycache__/\n' >>"$fixture/.gitignore"
git -C "$fixture" add .gitignore
git -C "$fixture" commit -qm "chore: ignore .env, node_modules and local-data" >"$test_tmp/commit.log" 2>&1 ||
    fail "committing the fixture .gitignore failed"
new secrets-tree >/dev/null || fail "worktree-new.sh failed for the ignored-file case"
printf 'TOKEN=keep-me\n' >"$fixture/.worktrees/secrets-tree/.env"
if rm_wt secrets-tree >/dev/null 2>&1; then
    fail "worktree-rm.sh deleted an ignored local file without --force"
fi
[ -f "$fixture/.worktrees/secrets-tree/.env" ] || fail "the ignored file was deleted despite the refusal"

echo "==> an ignored STATE directory also blocks removal without --force"
rm -f "$fixture/.worktrees/secrets-tree/.env"
mkdir -p "$fixture/.worktrees/secrets-tree/local-data"
printf 'rows\n' >"$fixture/.worktrees/secrets-tree/local-data/db.sqlite"
if rm_wt secrets-tree >/dev/null 2>&1; then
    fail "worktree-rm.sh deleted an ignored state directory without --force"
fi
[ -f "$fixture/.worktrees/secrets-tree/local-data/db.sqlite" ] ||
    fail "the ignored state directory was deleted despite the refusal"
rm -rf "$fixture/.worktrees/secrets-tree/local-data"

echo "==> an ignored dependency DIRECTORY does not block an ordinary removal"
rm -f "$fixture/.worktrees/secrets-tree/.env"
mkdir -p "$fixture/.worktrees/secrets-tree/node_modules/pkg"
printf '{}\n' >"$fixture/.worktrees/secrets-tree/node_modules/pkg/package.json"
# Nested too: a monorepo package's node_modules and a __pycache__ beside a
# module are just as reinstallable as the root-level ones.
mkdir -p "$fixture/.worktrees/secrets-tree/packages/api/node_modules/dep"
printf '{}\n' >"$fixture/.worktrees/secrets-tree/packages/api/node_modules/dep/package.json"
mkdir -p "$fixture/.worktrees/secrets-tree/src/pkg/__pycache__"
printf 'x\n' >"$fixture/.worktrees/secrets-tree/src/pkg/__pycache__/mod.pyc"
rm_wt secrets-tree >/dev/null ||
    fail "worktree-rm.sh refused an ordinary removal over a reinstallable node_modules/"
refute_exists "$fixture/.worktrees/secrets-tree" "worktree-rm.sh left the tree behind"

# ── in-progress git operations and unreferenced detached HEADs ───────
# `git status --porcelain` is CLEAN at a rebase stop, so the dirty check alone
# waves away sequencer state and any commit amended at that stop.
echo "==> worktree:rm refuses a tree with an in-progress git operation"
new midrebase >/dev/null || fail "worktree-new.sh failed for the rebase case"
midrebase_git="$(git -C "$fixture/.worktrees/midrebase" rev-parse --path-format=absolute --git-dir)"
mkdir -p "$midrebase_git/rebase-merge"
if rm_wt midrebase >/dev/null 2>&1; then
    fail "worktree-rm.sh removed a tree with an in-progress rebase"
fi
[ -d "$fixture/.worktrees/midrebase" ] || fail "the mid-rebase tree was removed despite the refusal"
rm -rf "$midrebase_git/rebase-merge"
rm_wt midrebase >/dev/null || fail "worktree-rm.sh failed once the rebase state was cleared"

# MERGE_AUTOSTASH can be the ONLY marker: a `git merge --autostash` killed
# after the autostash is written but before MERGE_HEAD exists leaves the
# user's dirty work referenced by that one file alone (#951).
echo "==> worktree:rm refuses a tree holding only MERGE_AUTOSTASH"
new autostash >/dev/null || fail "worktree-new.sh failed for the autostash case"
autostash_git="$(git -C "$fixture/.worktrees/autostash" rev-parse --path-format=absolute --git-dir)"
printf '%s\n' "$(git -C "$fixture/.worktrees/autostash" rev-parse HEAD)" >"$autostash_git/MERGE_AUTOSTASH"
if rm_wt autostash >/dev/null 2>&1; then
    fail "worktree-rm.sh removed a tree with an interrupted merge --autostash"
fi
[ -d "$fixture/.worktrees/autostash" ] || fail "the autostash tree was removed despite the refusal"
rm -f "$autostash_git/MERGE_AUTOSTASH"
rm_wt autostash >/dev/null || fail "worktree-rm.sh failed once the autostash state was cleared"

# The same marker must also block STALE-RECORD cleanup: with the directory
# already gone, the record's admin dir holds the only MERGE_AUTOSTASH
# reference, and pruning the record would drop it (#951, challenge r2).
# The fixture path deliberately carries a single quote AND a space so the
# emitted recovery recipe (executed verbatim below) proves its printf %q
# escaping under exactly the characters that broke earlier revisions.
echo "==> worktree:rm refuses to prune a stale record holding MERGE_AUTOSTASH"
qfix="$test_tmp/q'uote fixture"
mkdir -p "$qfix/scripts"
cp "$repo/scripts/worktree-rm.sh" "$repo/scripts/worktree-lock.sh" "$qfix/scripts/"
git -C "$qfix" init -q
git -C "$qfix" config user.name "Worktree Test"
git -C "$qfix" config user.email "worktree-test@example.invalid"
git -C "$qfix" config commit.gpgsign false
printf 'fixture\n' >"$qfix/README.md"
git -C "$qfix" add -A
git -C "$qfix" commit -qm "chore: quote fixture"
git -C "$qfix" worktree add -q "$qfix/.worktrees/stalestash" -b stalestash
stalestash_git="$(git -C "$qfix/.worktrees/stalestash" rev-parse --path-format=absolute --git-dir)"
# A real autostash OID, not a bare HEAD: `git stash store` (the emitted
# recovery recipe, executed below) refuses commits that are not stash-shaped.
printf 'dirty\n' >>"$qfix/.worktrees/stalestash/README.md"
printf '%s\n' "$(git -C "$qfix/.worktrees/stalestash" stash create)" >"$stalestash_git/MERGE_AUTOSTASH"
rm -rf "$qfix/.worktrees/stalestash"
stalestash_err="$(rm_in "$qfix" scripts/worktree-rm.sh stalestash 2>&1 >/dev/null)" &&
    fail "worktree-rm.sh pruned a stale record whose admin dir holds a merge autostash"
[ -s "$stalestash_git/MERGE_AUTOSTASH" ] || fail "the stale record's autostash reference was dropped despite the refusal"
# The refusal's recovery recipe must be RUNNABLE as emitted — a malformed
# quoting of the marker path once shipped a recipe that failed even on
# space-free paths (#951 review r1). Execute it verbatim.
stalestash_cmd="$(printf '%s\n' "$stalestash_err" | sed -n 's/.*keep the work with: \(.*\) — then re-run.*/\1/p')"
[ -n "$stalestash_cmd" ] || fail "the stale-autostash refusal did not carry a recovery command"
(cd "$qfix" && eval "$stalestash_cmd" >/dev/null 2>&1) ||
    fail "the emitted stale-autostash recovery command is not runnable: $stalestash_cmd"
[ "$(git -C "$qfix" rev-parse refs/stash)" = "$(cat "$stalestash_git/MERGE_AUTOSTASH")" ] ||
    fail "the recovery command did not store the autostash commit in refs/stash"
rm_in "$qfix" scripts/worktree-rm.sh stalestash --force >/dev/null ||
    fail "worktree-rm.sh --force failed on the stale autostash record"

echo "==> worktree:rm refuses a detached HEAD no branch contains"
new detached >/dev/null || fail "worktree-new.sh failed for the detached case"
git -C "$fixture/.worktrees/detached" checkout -q --detach
printf 'orphan\n' >"$fixture/.worktrees/detached/ORPHAN.md"
git -C "$fixture/.worktrees/detached" add ORPHAN.md
LEFTHOOK=0 git -C "$fixture/.worktrees/detached" commit -qm "chore: commit only this detached HEAD has"
if rm_wt detached >/dev/null 2>&1; then
    fail "worktree-rm.sh removed a detached HEAD whose commit no branch contains"
fi
[ -d "$fixture/.worktrees/detached" ] || fail "the detached tree was removed despite the refusal"
rm_wt detached --force >/dev/null || fail "worktree-rm.sh --force failed on the detached tree"
git -C "$fixture" branch -D detached >/dev/null 2>&1 || true

# ── a standalone repo at the path is never auto-cleaned ──────────────
# A linked worktree's gitlink is a FILE; a `.git` DIRECTORY means somebody's own
# repository lives here and that directory holds its only objects.
echo "==> worktree:rm refuses to delete a .git DIRECTORY as debris"
mkdir -p "$fixture/.worktrees/standalone"
git -C "$fixture/.worktrees/standalone" init -q
if rm_wt standalone >/dev/null 2>&1; then
    fail "worktree-rm.sh deleted a standalone repository as gitlink debris"
fi
[ -d "$fixture/.worktrees/standalone/.git" ] ||
    fail "worktree-rm.sh destroyed a standalone repository's .git directory"
rm -rf "${fixture:?}/.worktrees/standalone"

# ── removal works from inside the tree being removed ─────────────────
echo "==> worktree:rm works when run from inside the tree it removes"
new selfremove >/dev/null || fail "worktree-new.sh failed for the self-removal case"
rm_in "$fixture/.worktrees/selfremove" "$fixture/scripts/worktree-rm.sh" selfremove >/dev/null ||
    fail "worktree-rm.sh failed when run from inside the tree being removed"
refute_exists "$fixture/.worktrees/selfremove" "the self-removed tree was left behind"

# ── leftover gitlink debris (the #716 class) ─────────────────────────
echo "==> worktree:rm clears a leftover gitlink directory"
new debris >/dev/null || fail "worktree-new.sh failed for the debris case"
common_dir="$(git -C "$fixture" rev-parse --path-format=absolute --git-common-dir)"
rm -rf "${common_dir:?}/worktrees/debris"
find "$fixture/.worktrees/debris" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
rm_wt debris >/dev/null || fail "worktree-rm.sh could not clear leftover gitlink debris"
refute_exists "$fixture/.worktrees/debris" "worktree-rm.sh left gitlink debris behind"
git -C "$fixture" branch -D debris >/dev/null 2>&1 || true

# ── .worktrees/ is anchored to the MAIN worktree ─────────────────────
echo "==> creating from inside a linked worktree still anchors to the main tree"
new outer >/dev/null || fail "worktree-new.sh failed creating the outer tree"
new_in "$fixture/.worktrees/outer" inner >/dev/null ||
    fail "worktree-new.sh failed when run from inside a linked worktree"
[ -d "$fixture/.worktrees/inner" ] ||
    fail "worktree-new.sh did not anchor .worktrees/ to the main worktree"
refute_exists "$fixture/.worktrees/outer/.worktrees" "worktree-new.sh nested .worktrees/ inside a linked worktree"
echo "==> a tree created from inside a worktree bases on the MAIN head, not the caller's"
printf 'outer work\n' >"$fixture/.worktrees/outer/OUTER.md"
git -C "$fixture/.worktrees/outer" add OUTER.md
LEFTHOOK=0 git -C "$fixture/.worktrees/outer" commit -qm "chore: outer-only commit"
new_in "$fixture/.worktrees/outer" sibling >/dev/null ||
    fail "worktree-new.sh failed creating a sibling from inside a worktree"
main_head="$(git -C "$fixture" rev-parse HEAD)"
sibling_head="$(git -C "$fixture/.worktrees/sibling" rev-parse HEAD)"
[ "$sibling_head" = "$main_head" ] ||
    fail "the sibling tree stacked on the caller's branch instead of the main worktree's HEAD"

echo "==> --base HEAD still stacks deliberately"
new_in "$fixture/.worktrees/outer" stacked --base HEAD >/dev/null ||
    fail "worktree-new.sh --base HEAD failed"
outer_head="$(git -C "$fixture/.worktrees/outer" rev-parse HEAD)"
[ "$(git -C "$fixture/.worktrees/stacked" rev-parse HEAD)" = "$outer_head" ] ||
    fail "--base HEAD did not stack on the caller's HEAD"
rm_wt stacked >/dev/null || fail "cleanup of the stacked tree failed"
rm_wt sibling >/dev/null || fail "cleanup of the sibling tree failed"
rm_wt inner >/dev/null || fail "cleanup of the inner tree failed"
rm_wt outer --force >/dev/null || fail "cleanup of the outer tree failed"

# ── remote-only branches are attached, not recreated ─────────────────
echo "==> a branch that exists only on a remote is tracked, not recreated at base"
upstream="$test_tmp/upstream.git"
git init -q --bare "$upstream"
git -C "$fixture" remote add origin "$upstream"
git -C "$fixture" push -q origin HEAD:refs/heads/remote-only
git -C "$fixture" fetch -q origin
remote_tip="$(git -C "$fixture" rev-parse refs/remotes/origin/remote-only)"
printf 'diverge\n' >"$fixture/DIVERGE.md"
git -C "$fixture" add DIVERGE.md
LEFTHOOK=0 git -C "$fixture" commit -qm "chore: move main ahead of the remote branch"
new remote-only >/dev/null || fail "worktree-new.sh failed for a remote-only branch"
[ "$(git -C "$fixture/.worktrees/remote-only" rev-parse HEAD)" = "$remote_tip" ] ||
    fail "worktree-new.sh recreated the remote-only branch at the base instead of tracking it"
[ "$(git -C "$fixture" rev-parse --abbrev-ref remote-only@{upstream} 2>/dev/null)" = "origin/remote-only" ] ||
    fail "worktree-new.sh did not set up tracking for the remote-only branch"
rm_wt remote-only >/dev/null || fail "cleanup of the remote-only tree failed"
git -C "$fixture" branch -D remote-only >/dev/null 2>&1 || true

# ── partial-failure rollback ─────────────────────────────────────────
# `git worktree add` is not atomic: a failing post-checkout hook leaves the tree
# registered and the branch created while the command still exits non-zero. The
# rollback contract has to cover that, not just failures after it returns.
echo "==> a partially successful 'git worktree add' is rolled back"
cat >"$shared_hooks/post-checkout" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$shared_hooks/post-checkout"
if new half-made >/dev/null 2>&1; then
    fail "worktree-new.sh reported success despite a failing post-checkout hook"
fi
rm -f "$shared_hooks/post-checkout"
refute_exists "$fixture/.worktrees/half-made" "a partially created worktree was not rolled back"
if git -C "$fixture" worktree list --porcelain | grep -q "half-made"; then
    fail "a partially created worktree stayed in the registry"
fi
if git -C "$fixture" show-ref --verify --quiet refs/heads/half-made; then
    fail "the branch from a partially created worktree was not rolled back"
fi

# ── a concurrent same-name run cannot destroy the winner's tree ──────
echo "==> a second run that loses the path race does not roll back the winner"
new raced >/dev/null || fail "worktree-new.sh failed creating the raced tree"
raced_head="$(git -C "$fixture/.worktrees/raced" rev-parse HEAD)"
if new raced >/dev/null 2>&1; then
    fail "a second worktree-new.sh claimed an already-owned path"
fi
[ -d "$fixture/.worktrees/raced" ] ||
    fail "the loser's rollback destroyed the winner's worktree"
[ "$(git -C "$fixture/.worktrees/raced" rev-parse HEAD)" = "$raced_head" ] ||
    fail "the winner's worktree was disturbed by the loser"
git -C "$fixture" show-ref --verify --quiet refs/heads/raced ||
    fail "the loser's rollback deleted the winner's branch"
rm_wt raced >/dev/null || fail "cleanup of the raced tree failed"

# ── the resolved base is announced, never silent ─────────────────────
echo "==> the defaulted base is printed so a surprising branch point is visible"
base_out="$(new announced)" || fail "worktree-new.sh failed for the base-announcement case"
case "$base_out" in *"==> Base: the main worktree's HEAD"*) : ;; *) fail "worktree-new.sh did not announce the defaulted base" ;; esac
rm_wt announced >/dev/null || fail "cleanup of the announced tree failed"

# ── branch-style names with a slash ──────────────────────────────────
echo "==> a branch-style name like feat/foo works end to end"
new feat/nested >/dev/null || fail "worktree-new.sh failed on a slash-delimited name"
[ -d "$fixture/.worktrees/feat/nested" ] ||
    fail "worktree-new.sh did not create the nested worktree directory"
git -C "$fixture" show-ref --verify --quiet refs/heads/feat/nested ||
    fail "worktree-new.sh did not create the slash-delimited branch"
rm_wt feat/nested >/dev/null || fail "worktree-rm.sh failed on a slash-delimited name"
refute_exists "$fixture/.worktrees/feat/nested" "worktree-rm.sh left the nested tree behind"
refute_exists "$fixture/.worktrees/feat" "worktree-rm.sh left an empty parent directory behind"

# ── never nest a worktree inside a registered worktree ───────────────
# Git's own guard is on branch names, so a differing --branch walks straight
# past it and the child lands inside the parent — where `rm parent --force`
# would take the child's uncommitted work with it.
echo "==> a name nested under an existing worktree is refused"
new parent --branch alpha >/dev/null || fail "worktree-new.sh failed creating the parent tree"
if new parent/child --branch beta >/dev/null 2>&1; then
    fail "worktree-new.sh created a worktree nested inside a registered worktree"
fi
refute_exists "$fixture/.worktrees/parent/child" "the nested worktree was created despite the refusal"
[ -z "$(git -C "$fixture/.worktrees/parent" status --porcelain)" ] ||
    fail "the refused nested create left the parent worktree dirty"
rm_wt parent >/dev/null || fail "cleanup of the parent tree failed"
git -C "$fixture" branch -D alpha beta >/dev/null 2>&1 || true

# ── a nested worktree is never the parent's disposable dirt ───────────
# worktree:new refuses to create this shape, but a tree made by hand or before
# this entrypoint existed can still be nested. `git worktree remove --force`
# would delete the child's uncommitted work and the cleanup would drop its
# record, so removal has to look for descendants — in BOTH modes, since --force
# only ever promised to discard the target's own changes.
echo "==> worktree:rm refuses a target that contains a registered worktree"
new nestparent >/dev/null || fail "worktree-new.sh failed creating the nesting parent"
git -C "$fixture" worktree add -q "$fixture/.worktrees/nestparent/kid" -b nestkid ||
    fail "could not plant a nested worktree by hand"
printf 'child work\n' >"$fixture/.worktrees/nestparent/kid/KID.md"
for mode in "--force" ""; do
    if rm_wt nestparent $mode >"$test_tmp/nested.log" 2>&1; then
        fail "worktree-rm.sh ${mode:-(no --force)} removed a target containing a registered worktree"
    fi
    grep -qF "$fixture/.worktrees/nestparent/kid" "$test_tmp/nested.log" ||
        fail "the refusal did not name the nested worktree: $(cat "$test_tmp/nested.log")"
done
[ -f "$fixture/.worktrees/nestparent/kid/KID.md" ] ||
    fail "worktree-rm.sh deleted the nested worktree's uncommitted work"
git -C "$fixture" worktree list --porcelain | grep -qx "worktree $fixture/.worktrees/nestparent/kid" ||
    fail "worktree-rm.sh dropped the nested worktree's registry record"
rm_wt nestparent/kid --force >/dev/null || fail "cleanup of the nested child failed"
rm_wt nestparent >/dev/null || fail "cleanup of the nesting parent failed"
git -C "$fixture" branch -D nestkid >/dev/null 2>&1 || true

# ── cleanup is scoped to this record, never a repo-wide prune ─────────
# `git worktree prune` takes no path: pruning here would drop every OTHER stale
# record too, and such a record can be the only reference to a detached HEAD.
echo "==> removing one worktree leaves an unrelated stale record alone"
new keeper >/dev/null || fail "worktree-new.sh failed creating the keeper tree"
git -C "$fixture/.worktrees/keeper" checkout -q --detach
printf 'only the record holds this\n' >"$fixture/.worktrees/keeper/HELD.md"
git -C "$fixture/.worktrees/keeper" add HELD.md
LEFTHOOK=0 git -C "$fixture/.worktrees/keeper" commit -qm "chore: commit only the keeper record references"
held="$(git -C "$fixture/.worktrees/keeper" rev-parse HEAD)"
# The record outliving its directory is the ordinary shape here: an interrupted
# job, a hand `rm -rf`, a deleted external drive.
rm -rf "${fixture:?}/.worktrees/keeper"
keeper_admin="$common_dir/worktrees/keeper"
[ -d "$keeper_admin" ] || fail "fixture assumption broken: no admin dir for the keeper record"
new goer >/dev/null || fail "worktree-new.sh failed creating the unrelated tree"
rm_wt goer >/dev/null || fail "worktree-rm.sh failed removing the unrelated tree"
[ -d "$keeper_admin" ] ||
    fail "removing one worktree pruned an unrelated worktree's stale record"
git -C "$fixture" worktree list --porcelain | grep -qx "worktree $fixture/.worktrees/keeper" ||
    fail "removing one worktree deregistered an unrelated worktree"
if git -C "$fixture" fsck --unreachable --no-progress 2>/dev/null | grep -q "$held"; then
    fail "removing one worktree left another's commit unreachable"
fi
# The scoped cleanup still clears the record it IS asked about. `--force`
# because the keeper's own HEAD is the unreferenced detached commit above, and
# discarding the last reference to it is exactly what the stale-record guard
# below makes deliberate.
rm_wt keeper --force >/dev/null || fail "worktree-rm.sh could not clear the keeper's own stale record"
if git -C "$fixture" worktree list --porcelain | grep -q "keeper"; then
    fail "worktree-rm.sh left the keeper's stale record behind"
fi
git -C "$fixture" branch -D keeper goer >/dev/null 2>&1 || true

# ── the rollback path is scoped too ──────────────────────────────────
# `worktree:new`'s rollback ran the same repository-wide prune, so a FAILED
# create destroyed unrelated stale records — including one holding a commit
# nothing else references.
echo "==> a failed create leaves an unrelated stale record alone"
new rbkeeper >/dev/null || fail "worktree-new.sh failed creating the rollback-keeper tree"
git -C "$fixture/.worktrees/rbkeeper" checkout -q --detach
printf 'held through a failed create\n' >"$fixture/.worktrees/rbkeeper/HELD.md"
git -C "$fixture/.worktrees/rbkeeper" add HELD.md
LEFTHOOK=0 git -C "$fixture/.worktrees/rbkeeper" commit -qm "chore: commit only the rbkeeper record references"
rb_held="$(git -C "$fixture/.worktrees/rbkeeper" rev-parse HEAD)"
rm -rf "${fixture:?}/.worktrees/rbkeeper"
rb_admin="$common_dir/worktrees/rbkeeper"
[ -d "$rb_admin" ] || fail "fixture assumption broken: no admin dir for the rollback-keeper record"
# A create that fails AFTER reserving its path: git refuses a branch that is
# already checked out in another worktree, which is the deterministic way there.
new rbholder >/dev/null || fail "worktree-new.sh failed creating the rollback-holder tree"
if new rbfail --branch rbholder >/dev/null 2>&1; then
    fail "worktree-new.sh attached a branch already checked out elsewhere"
fi
[ -d "$rb_admin" ] || fail "a failed create pruned an unrelated worktree's stale record"
if git -C "$fixture" fsck --unreachable --no-progress 2>/dev/null | grep -q "$rb_held"; then
    fail "a failed create left an unrelated worktree's commit unreachable"
fi
rm_wt rbholder >/dev/null || fail "cleanup of the rollback-holder tree failed"
rm_wt rbkeeper --force >/dev/null || fail "cleanup of the rollback-keeper record failed"
git -C "$fixture" branch -D rbkeeper rbholder >/dev/null 2>&1 || true

# ── per-worktree refs do not vouch for the worktree ──────────────────
# `refs/worktree/*` lives in the worktree's own admin dir and dies with it, so
# counting it as reachability makes the guard vouch for what it is removing.
echo "==> a detached HEAD held only by a per-worktree ref still needs --force"
new wtref >/dev/null || fail "worktree-new.sh failed creating the per-worktree-ref tree"
git -C "$fixture/.worktrees/wtref" checkout -q --detach
printf 'only a per-worktree ref holds this\n' >"$fixture/.worktrees/wtref/PW.md"
git -C "$fixture/.worktrees/wtref" add PW.md
LEFTHOOK=0 git -C "$fixture/.worktrees/wtref" commit -qm "chore: commit held only by refs/worktree"
git -C "$fixture/.worktrees/wtref" update-ref refs/worktree/keep HEAD
if rm_wt wtref >/dev/null 2>&1; then
    fail "worktree-rm.sh accepted refs/worktree/* as proof the detached commit survives"
fi
[ -d "$fixture/.worktrees/wtref" ] || fail "the per-worktree-ref tree was removed despite the refusal"
rm_wt wtref --force >/dev/null || fail "worktree-rm.sh --force failed on the per-worktree-ref tree"
git -C "$fixture" branch -D wtref >/dev/null 2>&1 || true

# ── a stale record's own HEAD is guarded too ─────────────────────────
# With the directory gone the live-tree guards are all skipped, yet the record
# can still be the only reference to a detached commit.
echo "==> a stale record holding an unreferenced detached commit needs --force"
new stalehead >/dev/null || fail "worktree-new.sh failed creating the stale-head tree"
git -C "$fixture/.worktrees/stalehead" checkout -q --detach
printf 'only the stale record holds this\n' >"$fixture/.worktrees/stalehead/SH.md"
git -C "$fixture/.worktrees/stalehead" add SH.md
LEFTHOOK=0 git -C "$fixture/.worktrees/stalehead" commit -qm "chore: commit only the stale record references"
stale_held="$(git -C "$fixture/.worktrees/stalehead" rev-parse HEAD)"
rm -rf "${fixture:?}/.worktrees/stalehead"
if rm_wt stalehead >/dev/null 2>&1; then
    fail "worktree-rm.sh discarded a stale record holding an unreferenced detached commit"
fi
git -C "$fixture" worktree list --porcelain | grep -qx "worktree $fixture/.worktrees/stalehead" ||
    fail "the stale record was dropped despite the refusal"
if git -C "$fixture" fsck --unreachable --no-progress 2>/dev/null | grep -q "$stale_held"; then
    fail "the refused removal still left the commit unreachable"
fi
rm_wt stalehead --force >/dev/null || fail "worktree-rm.sh --force failed on the stale record"
git -C "$fixture" branch -D stalehead >/dev/null 2>&1 || true

# ── creation refuses a registered DESCENDANT ─────────────────────────
# A missing-but-registered `<name>/child` does not block `git worktree add` at
# `<name>`, and the result strands the removal guard: `worktree:rm <name>`
# refuses (a descendant is registered) while `worktree:rm <name>/child` cannot
# work either, the path being an ordinary directory inside a live checkout.
echo "==> creating over a registered descendant record is refused"
git -C "$fixture" worktree add -q "$fixture/.worktrees/dparent/kid" -b dkid ||
    fail "could not plant the descendant worktree"
rm -rf "${fixture:?}/.worktrees/dparent"
git -C "$fixture" worktree list --porcelain | grep -qx "worktree $fixture/.worktrees/dparent/kid" ||
    fail "fixture assumption broken: the descendant record did not survive"
if new dparent >"$test_tmp/descendant.log" 2>&1; then
    fail "worktree-new.sh provisioned over a registered descendant record"
fi
grep -qF "$fixture/.worktrees/dparent/kid" "$test_tmp/descendant.log" ||
    fail "the refusal did not name the descendant: $(cat "$test_tmp/descendant.log")"
refute_exists "$fixture/.worktrees/dparent/.git" "the refused create provisioned the parent anyway"
rm_wt dparent/kid >/dev/null || fail "cleanup of the descendant record failed"
git -C "$fixture" branch -D dkid >/dev/null 2>&1 || true

# ── rollback never deletes a branch this run did not create ──────────
# The dangerous shape is a failed `git worktree add` while the branch exists but
# nothing was registered at our path — the state a concurrent creator produces.
# Reached deterministically here by pointing at a branch that is already checked
# out in another worktree, which git refuses for exactly that reason.
echo "==> a failed create never deletes a branch it did not make"
new holder >/dev/null || fail "worktree-new.sh failed creating the holder tree"
if new borrower --branch holder >/dev/null 2>&1; then
    fail "worktree-new.sh attached a branch already checked out elsewhere"
fi
git -C "$fixture" show-ref --verify --quiet refs/heads/holder ||
    fail "rollback deleted a branch this run did not create"
[ -d "$fixture/.worktrees/holder" ] || fail "rollback removed another run's worktree"
refute_exists "$fixture/.worktrees/borrower" "the failed create left its reservation behind"
rm_wt holder >/dev/null || fail "cleanup of the holder tree failed"

# ── rollback never deletes anything it did not create ────────────────
# The ancestor/descendant race: a concurrent run can occupy this run's reserved
# directory before `git worktree add` gets to it. Rollback must degrade to a
# report, never a recursive delete. Simulated by planting a live worktree where
# a reservation would be and driving a create that fails after reserving.
echo "==> rollback refuses to delete a non-empty path it did not create"
new occupant >/dev/null || fail "worktree-new.sh failed creating the occupant tree"
printf 'precious\n' >"$fixture/.worktrees/occupant/PRECIOUS.md"
mkdir -p "$fixture/.worktrees/victim"
printf 'also precious\n' >"$fixture/.worktrees/victim/KEEP.md"
# A create for `victim` reserves nothing (the path is taken) and must not touch
# the contents; the pre-existing directory is reported, not deleted.
if new victim >/dev/null 2>&1; then
    fail "worktree-new.sh claimed a path that was already occupied"
fi
[ -f "$fixture/.worktrees/victim/KEEP.md" ] ||
    fail "worktree-new.sh deleted files at an occupied path"
[ -f "$fixture/.worktrees/occupant/PRECIOUS.md" ] ||
    fail "worktree-new.sh disturbed a live neighbouring worktree"
rm -rf "${fixture:?}/.worktrees/victim"
rm_wt occupant --force >/dev/null || fail "cleanup of the occupant tree failed"

# ── an abandoned empty reservation is recoverable ────────────────────
# An interrupted create leaves `.worktrees/<name>` with nothing in it. Running
# git inside it finds the ENCLOSING repo, so liveness has to come from the
# registry or the advertised recovery command cannot clean it up.
echo "==> an abandoned empty reservation can be removed by the advertised command"
mkdir -p "$fixture/.worktrees/abandoned"
rm_wt abandoned >/dev/null || fail "worktree-rm.sh could not clear an abandoned reservation"
refute_exists "$fixture/.worktrees/abandoned" "worktree-rm.sh left the abandoned reservation behind"

# ── every configured hook is installed and verified ──────────────────
echo "==> all hooks in lefthook.yml are installed and probed, not just pre-commit"
cat >"$fixture/lefthook.yml" <<'EOF'
assert_lefthook_installed: true

pre-commit:
  commands:
    noop:
      run: "true"

commit-msg:
  commands:
    noop:
      run: "true"

pre-push:
  commands:
    noop:
      run: "true"

reference-transaction:
  commands:
    noop:
      run: "true"
EOF
git -C "$fixture" add lefthook.yml
git -C "$fixture" commit -qm "chore: configure four hooks" >"$test_tmp/commit.log" 2>&1 ||
    fail "committing the multi-hook lefthook.yml failed"
# A partial installation is the case that used to pass: pre-commit present,
# the others missing. `reference-transaction` is deliberately one of the
# less-common git hooks — an incomplete name list would silently drop it and
# report the tree ready without it.
rm -f "$shared_hooks/commit-msg" "$shared_hooks/pre-push" "$shared_hooks/reference-transaction"
hooks_out="$(new all-hooks)" || fail "worktree-new.sh failed with four hooks configured"
for hook in pre-commit commit-msg pre-push reference-transaction; do
    [ -x "$shared_hooks/$hook" ] ||
        fail "worktree-new.sh reported ready without installing the $hook hook"
done
case "$hooks_out" in
*"commit-msg"*) : ;;
*) fail "worktree-new.sh did not report verifying commit-msg" ;;
esac
rm_wt all-hooks >/dev/null || fail "cleanup of the all-hooks tree failed"
# Back to the single-hook config: `reference-transaction` fires on every ref
# update, so leaving it configured would have the rest of the suite running
# lefthook on each git command for no added coverage.
cat >"$fixture/lefthook.yml" <<'EOF'
pre-commit:
  commands:
    noop:
      run: "true"
EOF
git -C "$fixture" add lefthook.yml
LEFTHOOK=0 git -C "$fixture" commit -qm "chore: back to one hook" >"$test_tmp/commit.log" 2>&1 ||
    fail "restoring the single-hook lefthook.yml failed"
# The installed shim outlives the config change (nothing re-runs `lefthook
# install`), so drop it too.
rm -f "$shared_hooks/reference-transaction"

# ── name validation ──────────────────────────────────────────────────
echo "==> path-escaping and empty names are rejected"
# `.` and empty components are rejected because the nesting guard compares the
# candidate path against git's canonical registry paths as text: `./p/child`
# would never match the registered `p`, so the guard would miss the nesting it
# exists to catch.
for bad in "../evil" "/abs" "" "./sneaky" "a/./b" "a//b" "."; do
    if new "$bad" >/dev/null 2>&1; then
        fail "worktree-new.sh accepted the invalid name '$bad'"
    fi
done

echo "==> worktree:rm rejects the same dot-segment spellings"
new dotlive >/dev/null || fail "worktree-new.sh failed creating the dot-live tree"
if rm_wt ./dotlive >/dev/null 2>&1; then
    fail "worktree-rm.sh accepted a './' spelling of a live worktree"
fi
[ -f "$fixture/.worktrees/dotlive/.git" ] ||
    fail "worktree-rm.sh deleted the live worktree's gitlink via a './' spelling"
rm_wt dotlive >/dev/null || fail "cleanup of the dot-live tree failed"

echo "==> a pre-existing stale registry record is refused, not force-removed"
new stalereg >/dev/null || fail "worktree-new.sh failed creating the stale-record tree"
# Delete the directory behind git's back: the record survives, the tree does not.
rm -rf "${fixture:?}/.worktrees/stalereg"
stale_admin="$(git -C "$fixture" rev-parse --path-format=absolute --git-common-dir)/worktrees/stalereg"
[ -d "$stale_admin" ] || fail "fixture assumption broken: no admin dir for the stale record"
if new stalereg >/dev/null 2>&1; then
    fail "worktree-new.sh provisioned over a pre-existing registry record"
fi
[ -d "$stale_admin" ] ||
    fail "the failed create destroyed pre-existing worktree metadata"
rm_wt stalereg >/dev/null || fail "worktree-rm.sh could not clear the stale record"
git -C "$fixture" branch -D stalereg >/dev/null 2>&1 || true

echo "==> a remote whose NAME contains a slash is still matched"
git init -q --bare "$test_tmp/upstream-team.git"
git -C "$fixture" remote add team/sub "$test_tmp/upstream-team.git"
git -C "$fixture" push -q team/sub HEAD:refs/heads/team-only
git -C "$fixture" fetch -q team/sub
team_tip="$(git -C "$fixture" rev-parse refs/remotes/team/sub/team-only)"
printf 'ahead\n' >"$fixture/AHEAD.md"
git -C "$fixture" add AHEAD.md
LEFTHOOK=0 git -C "$fixture" commit -qm "chore: move main ahead of the slash-remote branch" >"$test_tmp/commit.log" 2>&1 ||
    fail "committing ahead of the slash-remote branch failed"
new team-only >/dev/null || fail "worktree-new.sh failed for a slash-named remote's branch"
[ "$(git -C "$fixture/.worktrees/team-only" rev-parse HEAD)" = "$team_tip" ] ||
    fail "worktree-new.sh recreated the branch at base instead of tracking the slash-named remote"
rm_wt team-only >/dev/null || fail "cleanup of the slash-remote tree failed"
git -C "$fixture" branch -D team-only >/dev/null 2>&1 || true
git -C "$fixture" remote remove team/sub

# ── stale remote state must not decide anything (#813 / #840) ────────
echo "==> a branch pushed after the last fetch is still detected and tracked"
# Push, then delete the tracking ref the push just wrote: the local
# refs/remotes namespace now predates the branch, which is exactly the state
# after a collaborator pushes and nothing fetches (harmon-init#840).
git -C "$fixture" push -q origin HEAD:refs/heads/late-remote
git -C "$fixture" update-ref -d refs/remotes/origin/late-remote
late_tip="$(git -C "$fixture" ls-remote origin refs/heads/late-remote | awk '{print $1}')"
# Advance main past the push, so a helper that misses the remote branch
# creates 'late-remote' at a DIFFERENT commit — the divergence itself, not
# only the missing tracking, is what the assertion below must catch.
printf 'ahead of late-remote\n' >"$fixture/LATE.md"
git -C "$fixture" add LATE.md
LEFTHOOK=0 git -C "$fixture" commit -qm "chore: move main ahead of the late-pushed branch" >"$test_tmp/commit.log" 2>&1 ||
    fail "committing ahead of the late-pushed branch failed"
new late-remote >/dev/null || fail "worktree-new.sh failed for a branch with no local tracking ref"
[ "$(git -C "$fixture/.worktrees/late-remote" rev-parse HEAD)" = "$late_tip" ] ||
    fail "worktree-new.sh created 'late-remote' from the default base instead of the remote branch (harmon-init#840)"
[ "$(git -C "$fixture" rev-parse --abbrev-ref late-remote@{upstream} 2>/dev/null)" = "origin/late-remote" ] ||
    fail "worktree-new.sh did not set up tracking for the late-pushed branch"
rm_wt late-remote >/dev/null || fail "cleanup of the late-remote tree failed"
git -C "$fixture" branch -D late-remote >/dev/null 2>&1 || true

echo "==> a stale tracking ref is refreshed to the remote's current tip"
git -C "$fixture" push -q origin HEAD:refs/heads/moving-remote
stale_tip="$(git -C "$fixture" rev-parse refs/remotes/origin/moving-remote)"
printf 'advance\n' >"$fixture/MOVING.md"
git -C "$fixture" add MOVING.md
LEFTHOOK=0 git -C "$fixture" commit -qm "chore: advance the moving branch" >"$test_tmp/commit.log" 2>&1 ||
    fail "committing the moving-branch advance failed"
git -C "$fixture" push -q origin HEAD:refs/heads/moving-remote
moving_tip="$(git -C "$fixture" rev-parse HEAD)"
# Roll main back and force the tracking ref stale, so only a live probe plus
# fetch can know where the remote actually is.
git -C "$fixture" reset -q --hard HEAD~1
git -C "$fixture" update-ref refs/remotes/origin/moving-remote "$stale_tip"
new moving-remote >/dev/null || fail "worktree-new.sh failed for a branch with a stale tracking ref"
[ "$(git -C "$fixture/.worktrees/moving-remote" rev-parse HEAD)" = "$moving_tip" ] ||
    fail "worktree-new.sh attached 'moving-remote' at the stale tracking tip instead of the remote's current commit (harmon-init#840)"
rm_wt moving-remote >/dev/null || fail "cleanup of the moving-remote tree failed"
git -C "$fixture" branch -D moving-remote >/dev/null 2>&1 || true

echo "==> an unqueryable remote fails closed, and an explicit --base opts out"
git -C "$fixture" remote add badremote "$test_tmp/nonexistent-bare.git"
if new probe-fail >/dev/null 2>&1; then
    fail "worktree-new.sh invented a new branch although a remote could not be queried (harmon-init#840)"
fi
refute_exists "$fixture/.worktrees/probe-fail" "the fail-closed probe left a tree behind"
if git -C "$fixture" show-ref --verify --quiet refs/heads/probe-fail; then
    fail "the fail-closed probe left the branch behind"
fi
new probe-fail --base HEAD >/dev/null || fail "an explicit --base did not skip the remote probe"
rm_wt probe-fail >/dev/null || fail "cleanup of the probe-fail tree failed"
git -C "$fixture" branch -D probe-fail >/dev/null 2>&1 || true
git -C "$fixture" remote remove badremote

echo "==> a default base behind its upstream hands out the upstream tip"
base_upstream="$test_tmp/base-upstream.git"
git init -q --bare "$base_upstream"
git -C "$fixture" remote add baseup "$base_upstream"
fixture_head_branch="$(git -C "$fixture" symbolic-ref --short HEAD)"
git -C "$fixture" push -q -u baseup "$fixture_head_branch" >/dev/null 2>&1 ||
    fail "seeding the base upstream failed"
anchor_sha="$(git -C "$fixture" rev-parse HEAD)"
printf 'merged upstream\n' >"$fixture/UPSTREAM.md"
git -C "$fixture" add UPSTREAM.md
LEFTHOOK=0 git -C "$fixture" commit -qm "chore: land work on the upstream" >"$test_tmp/commit.log" 2>&1 ||
    fail "committing the upstream advance failed"
git -C "$fixture" push -q baseup "$fixture_head_branch"
upstream_sha="$(git -C "$fixture" rev-parse HEAD)"
# Roll local back AND stale the tracking ref: only the fetch inside
# worktree-new.sh can now learn where the upstream is (harmon-init#813).
git -C "$fixture" reset -q --hard "$anchor_sha"
git -C "$fixture" update-ref "refs/remotes/baseup/$fixture_head_branch" "$anchor_sha"
base_out="$(new fresh-base)" || fail "worktree-new.sh failed with a behind upstream"
[ "$(git -C "$fixture/.worktrees/fresh-base" rev-parse HEAD)" = "$upstream_sha" ] ||
    fail "worktree-new.sh based 'fresh-base' on the stale local HEAD instead of the upstream tip (harmon-init#813)"
case "$base_out" in *"is behind baseup/$fixture_head_branch"*) : ;; *) fail "worktree-new.sh did not announce the behind-upstream base" ;; esac
rm_wt fresh-base >/dev/null || fail "cleanup of the fresh-base tree failed"
git -C "$fixture" branch -D fresh-base >/dev/null 2>&1 || true

echo "==> a failed refresh with a concurrently-updated tracking ref proceeds on that update"
# The loser of two parallel worktree:new runs fails its own fetch while the
# winner's fetch refreshes the tracking ref mid-run. Deterministic
# reconstruction: a git shim plays the winner — on the loser's anonymous
# URL fetch it updates the tracking ref to the remote's value and then
# fails the fetch. The loser must read that in-run movement as positive
# evidence of a concurrent refresh and verify against it (harmon-init#813),
# rather than refusing (harmon-init#916's fail-closed default) or basing on
# its stale pre-fetch snapshot.
evshim_dir="$test_tmp/evshim"
mkdir -p "$evshim_dir"
ev_real_git="$(command -v git)"
git -C "$fixture" update-ref "refs/remotes/baseup/$fixture_head_branch" "$anchor_sha"
cat >"$evshim_dir/git" <<SHIM
#!/bin/sh
if [ "\$WTSHIM_EVIDENCE" = "1" ]; then
  saw_fetch=0
  for _arg in "\$@"; do
    if [ "\$_arg" = "fetch" ]; then saw_fetch=1; fi
    if [ \$saw_fetch -eq 1 ] && [ "\$_arg" = "--refmap=" ]; then
      "$ev_real_git" -C "$fixture" update-ref "refs/remotes/baseup/$fixture_head_branch" "$upstream_sha"
      exit 1
    fi
  done
fi
exec "$ev_real_git" "\$@"
SHIM
chmod +x "$evshim_dir/git"
evidence_out="$(cd "$fixture" && PATH="$evshim_dir:$PATH" WTSHIM_EVIDENCE=1 "$TIMEOUT_BIN" -k "$WORKTREE_OP_KILL_GRACE" "$WORKTREE_OP_TIMEOUT" bash scripts/worktree-new.sh evidence-base 2>&1)" ||
    fail "worktree-new.sh refused although a concurrent fetch refreshed the tracking ref: $evidence_out"
[ "$(git -C "$fixture/.worktrees/evidence-base" rev-parse HEAD)" = "$upstream_sha" ] ||
    fail "the loser did not base on the concurrently-refreshed tracking value (harmon-init#813)"
case "$evidence_out" in *"concurrent fetch refreshed"*) : ;; *) fail "the concurrent-evidence path produced no warning" ;; esac
rm_wt evidence-base >/dev/null || fail "cleanup of the evidence-base tree failed"
git -C "$fixture" branch -D evidence-base >/dev/null 2>&1 || true

echo "==> a failed refresh with an unmoved tracking ref refuses, and --base opts out"
# harmon-init#916 P2: proceeding on the last-known tracking ref after a
# failed refresh silently defeats the freshness guarantee. With no in-run
# movement of the tracking ref there is no evidence anything refreshed it,
# so the creation must fail closed — the same policy the branch probes
# apply — and name --base as the deliberate opt-out.
cat >"$evshim_dir/git" <<SHIM
#!/bin/sh
if [ "\$WTSHIM_EVIDENCE" = "1" ]; then
  saw_fetch=0
  for _arg in "\$@"; do
    if [ "\$_arg" = "fetch" ]; then saw_fetch=1; fi
    if [ \$saw_fetch -eq 1 ] && [ "\$_arg" = "--refmap=" ]; then
      exit 1
    fi
  done
fi
exec "$ev_real_git" "\$@"
SHIM
chmod +x "$evshim_dir/git"
deadend_out="$(cd "$fixture" && PATH="$evshim_dir:$PATH" WTSHIM_EVIDENCE=1 "$TIMEOUT_BIN" -k "$WORKTREE_OP_KILL_GRACE" "$WORKTREE_OP_TIMEOUT" bash scripts/worktree-new.sh deadend-base 2>&1)" &&
    fail "worktree-new.sh based a new tree on an unverifiable upstream (harmon-init#916)"
case "$deadend_out" in *"could not verify"*) : ;; *) fail "the fail-closed refusal did not say what it could not verify: $deadend_out" ;; esac
case "$deadend_out" in *"--base"*) : ;; *) fail "the fail-closed refusal named no --base opt-out" ;; esac
refute_exists "$fixture/.worktrees/deadend-base" "the fail-closed refusal left a tree behind"
if git -C "$fixture" show-ref --verify --quiet refs/heads/deadend-base; then
    fail "the fail-closed refusal left the branch behind"
fi
new deadend-base --base HEAD >/dev/null || fail "an explicit --base did not skip the unverifiable-upstream refusal"
rm_wt deadend-base >/dev/null || fail "cleanup of the deadend-base tree failed"
git -C "$fixture" branch -D deadend-base >/dev/null 2>&1 || true

echo "==> movement that contradicts this run's probed tip is not fetch evidence"
# challenge round 3: an overlapping fetch can publish an OLDER advertised
# tip into refs/remotes/* after this run probed a newer one. Proceeding on
# it would knowingly contradict the fresher answer in hand, so only
# movement to exactly the probed tip counts — the namespace alone does
# not. The shim plays that slower fetch: it moves the tracking ref to a
# value that is not the probe's answer and fails this run's fetch.
stale_alt="$(git -C "$fixture" commit-tree -m "older advertised tip" -p "$anchor_sha" "$(git -C "$fixture" rev-parse "$anchor_sha^{tree}")")"
git -C "$fixture" update-ref "refs/remotes/baseup/$fixture_head_branch" "$anchor_sha"
cat >"$evshim_dir/git" <<SHIM
#!/bin/sh
if [ "\$WTSHIM_EVIDENCE" = "1" ]; then
  for _arg in "\$@"; do
    if [ "\$_arg" = "--refmap=" ]; then
      "$ev_real_git" -C "$fixture" update-ref "refs/remotes/baseup/$fixture_head_branch" "$stale_alt"
      exit 1
    fi
  done
fi
exec "$ev_real_git" "\$@"
SHIM
chmod +x "$evshim_dir/git"
staleatt_out="$(cd "$fixture" && PATH="$evshim_dir:$PATH" WTSHIM_EVIDENCE=1 "$TIMEOUT_BIN" -k "$WORKTREE_OP_KILL_GRACE" "$WORKTREE_OP_TIMEOUT" bash scripts/worktree-new.sh staleatt-base 2>&1)" &&
    fail "worktree-new.sh trusted tracking-ref movement that contradicts its own probe (harmon-init#916)"
case "$staleatt_out" in *"could not verify"*) : ;; *) fail "the contradicted-movement refusal did not say what it could not verify: $staleatt_out" ;; esac
refute_exists "$fixture/.worktrees/staleatt-base" "the contradicted-movement refusal left a tree behind"
if git -C "$fixture" show-ref --verify --quiet refs/heads/staleatt-base; then
    fail "the contradicted-movement refusal left the branch behind"
fi
# Restore the tracking ref the cases above moved.
git -C "$fixture" update-ref "refs/remotes/baseup/$fixture_head_branch" "$upstream_sha"

echo "==> a non-identity fetch refspec still verifies against the true source branch"
# The upstream's short name and its source branch deliberately differ
# (+refs/heads/trunk-src:refs/remotes/niup/localname): a helper that derives
# the fetch source by splitting the abbreviated upstream name would fetch a
# branch that does not exist and silently keep the stale base (challenge
# round 2 of harmon-init#813/#840).
ni_upstream="$test_tmp/ni-upstream.git"
git init -q --bare "$ni_upstream"
git -C "$fixture" remote add niup "$ni_upstream"
git -C "$fixture" config remote.niup.fetch "+refs/heads/trunk-src:refs/remotes/niup/localname"
git -C "$fixture" push -q niup HEAD:refs/heads/trunk-src
ni_anchor="$(git -C "$fixture" rev-parse HEAD)"
printf 'landed on trunk-src\n' >"$fixture/NI.md"
git -C "$fixture" add NI.md
LEFTHOOK=0 git -C "$fixture" commit -qm "chore: advance the non-identity upstream" >"$test_tmp/commit.log" 2>&1 ||
    fail "committing the non-identity advance failed"
git -C "$fixture" push -q niup HEAD:refs/heads/trunk-src
ni_tip="$(git -C "$fixture" rev-parse HEAD)"
git -C "$fixture" reset -q --hard "$ni_anchor"
git -C "$fixture" config "branch.$fixture_head_branch.remote" niup
git -C "$fixture" config "branch.$fixture_head_branch.merge" refs/heads/trunk-src
git -C "$fixture" update-ref refs/remotes/niup/localname "$ni_anchor"
new ni-base >/dev/null || fail "worktree-new.sh failed with a non-identity upstream refspec"
[ "$(git -C "$fixture/.worktrees/ni-base" rev-parse HEAD)" = "$ni_tip" ] ||
    fail "worktree-new.sh did not fetch the true source branch through the non-identity refspec (harmon-init#813)"
rm_wt ni-base >/dev/null || fail "cleanup of the ni-base tree failed"
git -C "$fixture" branch -D ni-base >/dev/null 2>&1 || true
git -C "$fixture" config "branch.$fixture_head_branch.remote" baseup
git -C "$fixture" config "branch.$fixture_head_branch.merge" "refs/heads/$fixture_head_branch"
git -C "$fixture" remote remove niup

echo "==> a default base diverged from its upstream is refused"
printf 'local divergence\n' >"$fixture/DIVERGED.md"
git -C "$fixture" add DIVERGED.md
LEFTHOOK=0 git -C "$fixture" commit -qm "chore: diverge from the upstream" >"$test_tmp/commit.log" 2>&1 ||
    fail "committing the divergence failed"
if new diverged-base >/dev/null 2>&1; then
    fail "worktree-new.sh picked a base although local and upstream have diverged (harmon-init#813)"
fi
refute_exists "$fixture/.worktrees/diverged-base" "the diverged-base refusal left a tree behind"
new diverged-base --base HEAD >/dev/null || fail "an explicit --base did not bypass the divergence refusal"
rm_wt diverged-base >/dev/null || fail "cleanup of the diverged-base tree failed"
git -C "$fixture" branch -D diverged-base >/dev/null 2>&1 || true

echo "==> attaching an existing branch is never blocked by base staleness"
# The default base is only consumed when a NEW branch is created from it, so
# the diverged main that just refused 'diverged-base' must not block — or
# even warn about — attaching a branch that already exists: the base plays
# no part in that path (harmon-init#813, challenge round 1).
git -C "$fixture" branch attach-diverged
local_tip="$(git -C "$fixture" rev-parse HEAD)"
attach_out="$(new attach-diverged 2>&1)" || fail "worktree-new.sh refused to attach an existing branch while main is diverged from its upstream"
[ "$(git -C "$fixture/.worktrees/attach-diverged" rev-parse HEAD)" = "$local_tip" ] ||
    fail "the attach did not check out the existing branch tip"
case "$attach_out" in *"has diverged from"*) fail "attaching an existing branch surfaced the base divergence it never uses" ;; esac
rm_wt attach-diverged >/dev/null || fail "cleanup of the attach-diverged tree failed"
git -C "$fixture" branch -D attach-diverged >/dev/null 2>&1 || true
# Teardown: restore the pre-case fixture state so later default-base cases
# are decided by the local HEAD again, exactly as before this block.
git -C "$fixture" branch --unset-upstream >/dev/null 2>&1 || true
git -C "$fixture" remote remove baseup
git -C "$fixture" reset -q --hard "$anchor_sha"

echo "==> the freshness check never writes a local branch mapped by a custom refspec"
# harmon-init#916 P1: @{upstream}'s full name is wherever the user's refspec
# maps it — including refs/heads/*. The old form force-fetched
# "+<merge>:<that ref>", unreferencing local-only commits; and even a
# destination-less fetch of the mapped source triggers git's opportunistic
# tracking update, which force-writes the configured mapping ("(forced
# update)" observed even without "+" in the refspec). Only the anonymous
# URL fetch leaves the user's refs alone; this case pins exactly that: the
# freshness answer must come from the remote while the mapped LOCAL branch
# keeps its local-only commit.
p1_up="$test_tmp/p1-up.git"
git init -q --bare "$p1_up"
git -C "$fixture" remote add p1rem "$p1_up"
p1_anchor="$(git -C "$fixture" rev-parse HEAD)"
p1_local="$(git -C "$fixture" commit-tree -m "local-only work" -p "$p1_anchor" "$(git -C "$fixture" rev-parse "$p1_anchor^{tree}")")"
p1_tip="$(git -C "$fixture" commit-tree -m "remote advance" -p "$p1_anchor" "$(git -C "$fixture" rev-parse "$p1_anchor^{tree}")")"
# Pushes happen BEFORE the custom refspec exists: a push also updates the
# ref the fetch refspec maps its branch to, so pushing afterwards would
# write refs/heads/local-mirror itself and pre-empt the very state this
# case plants.
git -C "$fixture" push -q p1rem HEAD:refs/heads/trunk-src
git -C "$fixture" push -q p1rem "$p1_tip:refs/heads/trunk-src"
git -C "$fixture" config remote.p1rem.fetch "+refs/heads/trunk-src:refs/heads/local-mirror"
git -C "$fixture" update-ref refs/heads/local-mirror "$p1_local"
git -C "$fixture" config "branch.$fixture_head_branch.remote" p1rem
git -C "$fixture" config "branch.$fixture_head_branch.merge" refs/heads/trunk-src
new p1-fresh >/dev/null || fail "worktree-new.sh failed under a refs/heads-mapped upstream"
[ "$(git -C "$fixture/.worktrees/p1-fresh" rev-parse HEAD)" = "$p1_tip" ] ||
    fail "the freshness check did not base on the remote tip under a refs/heads mapping"
[ "$(git -C "$fixture" rev-parse refs/heads/local-mirror)" = "$p1_local" ] ||
    fail "the freshness check rewrote a local branch mapped by a custom refspec (harmon-init#916 P1)"
rm_wt p1-fresh >/dev/null || fail "cleanup of the p1-fresh tree failed"
git -C "$fixture" branch -D p1-fresh >/dev/null 2>&1 || true
git -C "$fixture" branch -D local-mirror >/dev/null 2>&1 || true
git -C "$fixture" config --unset "branch.$fixture_head_branch.remote" || true
git -C "$fixture" config --unset "branch.$fixture_head_branch.merge" || true
git -C "$fixture" remote remove p1rem

echo "==> movement of a refs/heads-mapped upstream is not fetch evidence"
# harmon-init#916 challenge round 2: under a refspec mapping the upstream
# into refs/heads/*, an ordinary LOCAL commit moves @{upstream}'s ref too.
# If the refresh also fails, that movement must not read as a concurrent
# fetch — the run would silently base on unrelated local work. The shim
# plays the local committer: it moves the mapped ref to a local-only
# commit and fails the fetch.
p2h_up="$test_tmp/p2h-up.git"
git init -q --bare "$p2h_up"
git -C "$fixture" remote add p2hrem "$p2h_up"
p2h_anchor="$(git -C "$fixture" rev-parse HEAD)"
p2h_local="$(git -C "$fixture" commit-tree -m "local-only move" -p "$p2h_anchor" "$(git -C "$fixture" rev-parse "$p2h_anchor^{tree}")")"
p2h_tip="$(git -C "$fixture" commit-tree -m "remote advance" -p "$p2h_anchor" "$(git -C "$fixture" rev-parse "$p2h_anchor^{tree}")")"
git -C "$fixture" push -q p2hrem HEAD:refs/heads/trunk-src
git -C "$fixture" push -q p2hrem "$p2h_tip:refs/heads/trunk-src"
git -C "$fixture" config remote.p2hrem.fetch "+refs/heads/trunk-src:refs/heads/local-mirror2"
git -C "$fixture" update-ref refs/heads/local-mirror2 "$p2h_anchor"
git -C "$fixture" config "branch.$fixture_head_branch.remote" p2hrem
git -C "$fixture" config "branch.$fixture_head_branch.merge" refs/heads/trunk-src
cat >"$evshim_dir/git" <<SHIM
#!/bin/sh
if [ "\$WTSHIM_EVIDENCE" = "1" ]; then
  for _arg in "\$@"; do
    if [ "\$_arg" = "--refmap=" ]; then
      "$ev_real_git" -C "$fixture" update-ref refs/heads/local-mirror2 "$p2h_local"
      exit 1
    fi
  done
fi
exec "$ev_real_git" "\$@"
SHIM
chmod +x "$evshim_dir/git"
p2h_out="$(cd "$fixture" && PATH="$evshim_dir:$PATH" WTSHIM_EVIDENCE=1 "$TIMEOUT_BIN" -k "$WORKTREE_OP_KILL_GRACE" "$WORKTREE_OP_TIMEOUT" bash scripts/worktree-new.sh heads-ev 2>&1)" &&
    fail "worktree-new.sh accepted a local-branch move as fetch evidence (harmon-init#916)"
case "$p2h_out" in *"could not verify"*) : ;; *) fail "the untrusted-movement refusal did not say what it could not verify: $p2h_out" ;; esac
refute_exists "$fixture/.worktrees/heads-ev" "the untrusted-movement refusal left a tree behind"
if git -C "$fixture" show-ref --verify --quiet refs/heads/heads-ev; then
    fail "the untrusted-movement refusal left the branch behind"
fi

echo "==> movement to the remote-attested probed tip still counts as evidence"
# The trust gate's other arm: the same failure with the mapped ref moved to
# exactly the tip this run's probe returned is a concurrent fetch by
# definition — whoever moved it had the remote's answer — and must proceed.
git -C "$fixture" update-ref refs/heads/local-mirror2 "$p2h_anchor"
cat >"$evshim_dir/git" <<SHIM
#!/bin/sh
if [ "\$WTSHIM_EVIDENCE" = "1" ]; then
  for _arg in "\$@"; do
    if [ "\$_arg" = "--refmap=" ]; then
      "$ev_real_git" -C "$fixture" update-ref refs/heads/local-mirror2 "$p2h_tip"
      exit 1
    fi
  done
fi
exec "$ev_real_git" "\$@"
SHIM
chmod +x "$evshim_dir/git"
p2h_out2="$(cd "$fixture" && PATH="$evshim_dir:$PATH" WTSHIM_EVIDENCE=1 "$TIMEOUT_BIN" -k "$WORKTREE_OP_KILL_GRACE" "$WORKTREE_OP_TIMEOUT" bash scripts/worktree-new.sh heads-ev2 2>&1)" ||
    fail "worktree-new.sh refused although the moved value was the probed remote tip: $p2h_out2"
[ "$(git -C "$fixture/.worktrees/heads-ev2" rev-parse HEAD)" = "$p2h_tip" ] ||
    fail "the attested-movement path did not base on the probed remote tip"
case "$p2h_out2" in *"concurrent fetch refreshed"*) : ;; *) fail "the attested-movement path produced no warning" ;; esac
rm_wt heads-ev2 >/dev/null || fail "cleanup of the heads-ev2 tree failed"
git -C "$fixture" branch -D heads-ev2 >/dev/null 2>&1 || true
git -C "$fixture" branch -D local-mirror2 >/dev/null 2>&1 || true
git -C "$fixture" config --unset "branch.$fixture_head_branch.remote" || true
git -C "$fixture" config --unset "branch.$fixture_head_branch.merge" || true
git -C "$fixture" remote remove p2hrem

echo "==> a remote-only branch under a custom refspec never clobbers foreign tracking refs"
# The remote maps ONLY decoy into refs/remotes/cref/victim. Creating the
# remote-only branch 'victim' must attach it at the remote's tip via the
# probe — not via any ref this script writes — and the mapped tracking ref
# that belongs to decoy must be exactly as it was afterwards.
cref_up="$test_tmp/cref-up.git"
git init -q --bare "$cref_up"
git -C "$fixture" remote add cref "$cref_up"
git -C "$fixture" config remote.cref.fetch "+refs/heads/decoy:refs/remotes/cref/victim"
git -C "$fixture" push -q cref HEAD:refs/heads/decoy
decoy_tip="$(git -C "$fixture" rev-parse HEAD)"
printf 'victim work\n' >"$fixture/VICTIM.md"
git -C "$fixture" add VICTIM.md
LEFTHOOK=0 git -C "$fixture" commit -qm "chore: advance the victim branch" >"$test_tmp/commit.log" 2>&1 ||
    fail "committing the victim advance failed"
git -C "$fixture" push -q cref HEAD:refs/heads/victim
victim_tip="$(git -C "$fixture" rev-parse HEAD)"
git -C "$fixture" reset -q --hard "$decoy_tip"
git -C "$fixture" update-ref refs/remotes/cref/victim "$decoy_tip"
victim_out="$(new victim)" || fail "worktree-new.sh failed for a remote-only branch under a custom refspec"
[ "$(git -C "$fixture/.worktrees/victim" rev-parse HEAD)" = "$victim_tip" ] ||
    fail "worktree-new.sh did not attach 'victim' at the remote tip under a custom refspec"
[ "$(git -C "$fixture" rev-parse refs/remotes/cref/victim)" = "$decoy_tip" ] ||
    fail "worktree-new.sh clobbered a tracking ref the custom refspec maps from another branch (harmon-init#840)"
[ "$(git -C "$fixture" config branch.victim.remote)" = "cref" ] ||
    fail "the custom-refspec branch is not configured to track its remote"
[ "$(git -C "$fixture" config branch.victim.merge)" = "refs/heads/victim" ] ||
    fail "the custom-refspec branch tracks the wrong merge ref"
# The refspec maps only decoy, so @{upstream} for victim CANNOT resolve —
# and the command must say so rather than claim full tracking.
if git -C "$fixture" rev-parse --verify --quiet "victim@{upstream}" >/dev/null 2>&1; then
    fail "victim@{upstream} resolved although the refspec maps no such branch — fixture assumption broken"
fi
case "$victim_out" in *"does not map refs/heads/victim"*) : ;; *) fail "the unmapped-refspec degradation was not announced" ;; esac
rm_wt victim >/dev/null || fail "cleanup of the victim tree failed"
git -C "$fixture" branch -D victim >/dev/null 2>&1 || true
git -C "$fixture" remote remove cref

# ── per-path lifecycle locks (#839 / #784) ───────────────────────────
fixture_locks="$fixture/.git/worktree-locks"
this_host="$(hostname)"

echo "==> a live parent-path operation refuses a child creation, and vice versa"
# Both #839 creation orders, deterministically: holding the entries a real
# concurrent operation would hold IS the race's exclusion state, minus the
# scheduler. An operation ON parent holds parent exclusively; an operation
# on parent/child holds parent shared (a holder marker) and the child
# exclusively.
mkdir -p "$fixture_locks/lockparent+lock"
printf '%s %s %s %s\n' "$$" "$this_host" "$(id -u)" "$(ps -o pgid= -p $$ | tr -d ' ')" >"$fixture_locks/lockparent+lock/owner"
if new lockparent/child --branch lockchild >/dev/null 2>&1; then
    fail "a child creation proceeded while a parent-path operation held the lock (harmon-init#839)"
fi
refute_exists "$fixture/.worktrees/lockparent/child" "the refused child creation left a tree behind"
if git -C "$fixture" show-ref --verify --quiet refs/heads/lockchild; then
    fail "the refused child creation left its branch behind"
fi
rm -rf "$fixture_locks/lockparent+lock"
mkdir -p "$fixture_locks/lockparent+holders"
printf '%s %s %s %s\n' "$$" "$this_host" "$(id -u)" "$(ps -o pgid= -p $$ | tr -d ' ')" >"$fixture_locks/lockparent+holders/sim.marker"
mkdir -p "$fixture_locks/lockparent%child+lock"
printf '%s %s %s %s\n' "$$" "$this_host" "$(id -u)" "$(ps -o pgid= -p $$ | tr -d ' ')" >"$fixture_locks/lockparent%child+lock/owner"
if new lockparent >/dev/null 2>&1; then
    fail "a parent creation proceeded while a child-path operation held its ancestor marker (harmon-init#839)"
fi
refute_exists "$fixture/.worktrees/lockparent" "the refused parent creation left a tree behind"
refute_exists "$fixture_locks/lockparent+lock" "the refused parent creation left its exclusive lock held"

echo "==> sibling operations under one ancestor stay concurrent"
# The same child-operation simulation is still holding lockparent shared —
# a SIBLING (lockparent/other) shares that ancestor without conflict and
# must proceed; only an operation ON the ancestor is exclusive.
new lockparent/other --branch locksibling >/dev/null ||
    fail "a sibling creation was refused although only shared ancestor holds were live (harmon-init#839 round 1)"
rm_wt lockparent/other >/dev/null || fail "cleanup of the sibling tree failed"
git -C "$fixture" branch -D locksibling >/dev/null 2>&1 || true
echo "==> unrelated names stay concurrent under held locks"
new lockfree >/dev/null || fail "an unrelated creation was blocked by another name's lock"
rm_wt lockfree >/dev/null || fail "cleanup of the unrelated tree failed"
rm -rf "$fixture_locks/lockparent+holders" "$fixture_locks/lockparent%child+lock"

echo "==> two same-process holder claims yield two markers, released cleanly"
# Helper-level pin of the mktemp marker claim: the pre-fix implementation
# named markers by bare PID, so two claims from one pid (as two PID
# namespaces over a shared checkout would present) collapsed to one file
# and a single release destroyed both holds. Two acquisitions from THIS
# process must produce two distinct markers, and release must remove
# exactly its own.
(
    cd "$fixture"
    die() {
        echo "lockcheck: $*" >&2
        exit 1
    }
    # shellcheck source=/dev/null
    . scripts/worktree-lock.sh
    acquire_shared "collide-lk" "collide-lk"
    acquire_shared "collide-lk" "collide-lk"
    marker_count="$(find "$fixture_locks/collide-lk+holders" -type f | wc -l | tr -d ' ')"
    [ "$marker_count" -eq 2 ] || exit 9
    release_locks
    remaining="$(find "$fixture_locks/collide-lk+holders" -type f | wc -l | tr -d ' ')"
    [ "$remaining" -eq 0 ] || exit 8
)
collide_status=$?
[ "$collide_status" -ne 9 ] || fail "two same-process holder claims collided into one marker (review r3/r4)"
[ "$collide_status" -ne 8 ] || fail "release did not remove exactly its own markers"
[ "$collide_status" -eq 0 ] || fail "the helper-level collision check failed (exit $collide_status)"

echo "==> a name the whitelist refuses cannot reach the lock bookkeeping"
if rm_wt 'bad name' >/dev/null 2>&1; then
    fail "worktree-rm.sh accepted a name outside the creation whitelist"
fi

echo "==> case-aliased names contend on one lock key"
# Default macOS filesystems are case-insensitive: Foo and foo are one
# worktree path, so their operations must exclude each other whatever the
# spelling. The key is lowercased, so holding the lower-spelling lock must
# refuse an upper-spelling operation.
mkdir -p "$fixture_locks/case-lk+lock"
printf '%s %s %s %s\n' "$$" "$this_host" "$(id -u)" "$(ps -o pgid= -p $$ | tr -d ' ')" >"$fixture_locks/case-lk+lock/owner"
if new Case-LK >/dev/null 2>&1; then
    fail "a case-aliased spelling bypassed the held lock (PR #911 cloud review)"
fi
rm -rf "$fixture_locks/case-lk+lock"

echo "==> operations naming one --branch under different names contend on the branch lock"
# Path locks never contend for different worktree names, yet both runs
# write or attach the ONE branch — without a branch-namespace lock the
# loser's rollback can delete the ref out from under the winner's
# checked-out tree (harmon-init#916, challenge round 2).
mkdir -p "$fixture_locks/branch=lk-branch+lock"
printf '%s %s %s %s\n' "$$" "$this_host" "$(id -u)" "$(ps -o pgid= -p $$ | tr -d ' ')" >"$fixture_locks/branch=lk-branch+lock/owner"
if new lockbr-a --branch lk-branch >/dev/null 2>&1; then
    fail "a creation proceeded while another operation held its --branch (harmon-init#916)"
fi
refute_exists "$fixture/.worktrees/lockbr-a" "the refused branch-locked creation left a tree behind"
if new lk-branch >/dev/null 2>&1; then
    fail "a default-named creation bypassed the held branch lock"
fi
new lockbr-b --branch other-branch >/dev/null ||
    fail "an unrelated branch name was blocked by another branch's lock"
rm_wt lockbr-b >/dev/null || fail "cleanup of the unrelated-branch tree failed"
git -C "$fixture" branch -D other-branch >/dev/null 2>&1 || true
rm -rf "$fixture_locks/branch=lk-branch+lock"
new lk-branch >/dev/null || fail "the branch lock was not released for a later creation"
rm_wt lk-branch >/dev/null || fail "cleanup of the lk-branch tree failed"

echo "==> a hashed long-branch lock key stays outside the path-key namespace"
# A branch encoding over 200 bytes collapses its lock key to a checksum.
# Hashed WITHOUT the branch= prefix, that key lands in the path-key
# namespace — and the creation whitelist admits a worktree literally named
# the checksum string, so `new <hash> --branch <long>` would contend with
# its own path lock and refuse itself (PR #932 cloud review). The name
# below is derived exactly as acquire_branch_lock derives the key, so the
# case stages the collision deterministically whatever cksum returns.
long_branch="$(printf '%0201d' 0 | tr '0' 'a')"
hash_name="h$(printf 'branch=%s' "$long_branch" |
    tr '/' '%' | tr '[:upper:]' '[:lower:]' | cksum | tr ' \t' '--')"
new "$hash_name" --branch "$long_branch" >/dev/null ||
    fail "a worktree named its own hashed branch-lock key refused itself (PR #932 cloud review)"
rm_wt "$hash_name" >/dev/null || fail "cleanup of the hashed-name tree failed"
git -C "$fixture" branch -D "$long_branch" >/dev/null 2>&1 || true

echo "==> a stale lock from a dead process is broken, once"
# Death is proven through a CONTROLLED ps, not the host's: a sandbox that
# denies or restricts ps makes the implementation (correctly) refuse to
# break, which would fail this case for the wrong reason. The shim renders
# every probe visible and alive — self, pid 1, anything — except the one
# recorded dead pid, so the case tests the breaking logic itself on every
# host.
stale_dead_pid=999999
psstale_dir="$test_tmp/psstale"
mkdir -p "$psstale_dir"
cat >"$psstale_dir/ps" <<PSSHIM
#!/bin/sh
# Emulated process table: every pid is visible and alive with a fixed
# start time and lives in group 4242 — except the designated dead pid,
# which is absent, and whose recorded group (itself) appears in no scan.
pid=""
prev=""
for arg in "\$@"; do
  if [ "\$prev" = "-p" ]; then pid="\$arg"; fi
  prev="\$arg"
done
if [ "\$pid" = "$stale_dead_pid" ]; then
  exit 1
fi
case "\$*" in
*pgid*)
  echo "4242"
  ;;
*lstart*) echo "Mon Jan  1 00:00:00 2026" ;;
*) echo "\${pid:-1}" ;;
esac
exit 0
PSSHIM
chmod +x "$psstale_dir/ps"
mkdir -p "$fixture_locks/stale-lk+lock"
printf '%s %s %s %s\n' "$stale_dead_pid" "$this_host" "$(id -u)" "$stale_dead_pid" >"$fixture_locks/stale-lk+lock/owner"
(
    PATH="$psstale_dir:$PATH"
    export PATH
    new stale-lk >/dev/null
) || fail "worktree-new.sh could not break a dead process's stale lock"
refute_exists "$fixture_locks/stale-lk+lock" "the stale-lock run did not release its own lock"
rm_wt stale-lk >/dev/null || fail "cleanup of the stale-lk tree failed"

echo "==> a dead pid with a surviving process group is still alive"
# Proven through the controlled ps shim on every host: the recorded pid is
# the shim's dead one, but the recorded GROUP is the shim's live group
# 4242 (self-group visible, survivor present) — alive by group evidence,
# so the lock must refuse, not break. Removing the group scan turns this
# into a dead verdict and fails the case.
mkdir -p "$fixture_locks/livegroup-lk+lock"
printf '%s %s %s %s\n' "$stale_dead_pid" "$this_host" "$(id -u)" "4242" >"$fixture_locks/livegroup-lk+lock/owner"
if (
    PATH="$psstale_dir:$PATH"
    export PATH
    new livegroup-lk >/dev/null 2>&1
); then
    fail "a lock with a surviving process group was broken (harmon-init#784 review r3)"
fi
[ -d "$fixture_locks/livegroup-lk+lock" ] || fail "the surviving-group lock was removed"
rm -rf "$fixture_locks/livegroup-lk+lock"

echo "==> a reused pid (mismatched start time) is judged dead and broken"
# The shim reports pid 999998 as visible with a FIXED start time; an owner
# recorded with a different start time is therefore a dead process whose
# pid was reused, and the lock must break. Removing the start-time compare
# turns this into a live-owner refusal and fails the case.
mkdir -p "$fixture_locks/reuse-lk+lock"
printf '%s %s %s %s %s %s\n' "999998" "$this_host" "$(id -u)" "999998" "n0" "Tue Feb  2 02:02:02 2027" >"$fixture_locks/reuse-lk+lock/owner"
(
    PATH="$psstale_dir:$PATH"
    export PATH
    new reuse-lk >/dev/null
) || fail "a reused-pid stale lock (start-time mismatch) was not broken"
rm_wt reuse-lk >/dev/null || fail "cleanup of the reuse-lk tree failed"

echo "==> a dead breaker's break mutex refuses with its own remedy"
# Break mutexes are never auto-reclaimed — that recursion has no bottom
# (PR #911 cloud review). The refusal must name the break directory
# itself, and removing it per the remedy must unblock the next run.
mkdir -p "$fixture_locks/deadbreak-lk+lock"
printf '%s %s %s %s\n' "$stale_dead_pid" "$this_host" "$(id -u)" "$stale_dead_pid" >"$fixture_locks/deadbreak-lk+lock/owner"
mkdir -p "$fixture_locks/deadbreak-lk+lock+break"
printf '%s %s %s %s\n' "$stale_dead_pid" "$this_host" "$(id -u)" "$stale_dead_pid" >"$fixture_locks/deadbreak-lk+lock+break/owner"
deadbreak_out="$(
    PATH="$psstale_dir:$PATH"
    export PATH
    new deadbreak-lk 2>&1
)" && fail "a dead-owned break mutex was auto-reclaimed despite the no-reclamation policy"
case "$deadbreak_out" in *"crashed lock-recovery attempt left"*) : ;; *) fail "the dead-breaker refusal did not name the break mutex" ;; esac
rm -rf "$fixture_locks/deadbreak-lk+lock+break"
(
    PATH="$psstale_dir:$PATH"
    export PATH
    new deadbreak-lk >/dev/null
) || fail "removing the break mutex per the remedy did not unblock the dead-lock break"
rm_wt deadbreak-lk >/dev/null || fail "cleanup of the deadbreak-lk tree failed"

echo "==> a foreign host's lock is refused with the remedy, never broken"
mkdir -p "$fixture_locks/foreign-lk+lock"
printf '%s %s %s %s\n' "12345" "not-$this_host" "$(id -u)" "12345" >"$fixture_locks/foreign-lk+lock/owner"
foreign_out="$(new foreign-lk 2>&1)" && fail "worktree-new.sh broke a lock it could not liveness-check"
case "$foreign_out" in *"remove the lock directory and re-run"*) : ;; *) fail "the foreign-lock refusal named no remedy" ;; esac
[ -d "$fixture_locks/foreign-lk+lock" ] || fail "the foreign host's lock was removed"
rm -rf "$fixture_locks/foreign-lk+lock"

echo "==> an ownerless lock always refuses with the remedy, whatever its age"
# Crash-inside-the-claim-window and suspension are indistinguishable, so
# ownerless entries are never auto-reclaimed (challenge round 5) — the
# refusal carries the manual remedy instead.
mkdir -p "$fixture_locks/fresh-lk+lock"
if new fresh-lk >/dev/null 2>&1; then
    fail "a fresh ownerless lock (a live acquisition window) was broken"
fi
rm -rf "$fixture_locks/fresh-lk+lock"
mkdir -p "$fixture_locks/aged-lk+lock"
touch -t 202601010000 "$fixture_locks/aged-lk+lock"
aged_out="$(new aged-lk 2>&1)" && fail "an aged ownerless lock was auto-reclaimed despite the undecidable window"
case "$aged_out" in *"remove the lock directory and re-run"*) : ;; *) fail "the ownerless refusal named no remedy" ;; esac
rm -rf "$fixture_locks/aged-lk+lock"

echo "==> a repository path containing whitespace releases every marker"
# The array-tracked marker paths exist for exactly this repository shape —
# a space-joined scalar word-splits absolute paths and release strands
# every marker. Run under /bin/bash so macOS exercises its 3.2 baseline.
spaced_root="$test_tmp/with space"
mkdir -p "$spaced_root/r/scripts"
cp "$fixture/scripts/worktree-new.sh" "$fixture/scripts/worktree-rm.sh" "$fixture/scripts/worktree-lock.sh" "$spaced_root/r/scripts/"
git -C "$spaced_root/r" init -q
git -C "$spaced_root/r" config user.name "Worktree Test"
git -C "$spaced_root/r" config user.email "worktree-test@example.invalid"
git -C "$spaced_root/r" config commit.gpgsign false
printf 'spaced\n' >"$spaced_root/r/README.md"
git -C "$spaced_root/r" add -A
LEFTHOOK=0 git -C "$spaced_root/r" commit -qm "chore: spaced fixture" >/dev/null 2>&1 ||
    fail "committing the spaced fixture failed"
(cd "$spaced_root/r" && "$TIMEOUT_BIN" -k "$WORKTREE_OP_KILL_GRACE" "$WORKTREE_OP_TIMEOUT" /bin/bash scripts/worktree-new.sh sp/child --no-install >/dev/null 2>&1) ||
    fail "worktree:new failed in a repository path containing whitespace"
(cd "$spaced_root/r" && "$TIMEOUT_BIN" -k "$WORKTREE_OP_KILL_GRACE" "$WORKTREE_OP_TIMEOUT" /bin/bash scripts/worktree-rm.sh sp/child >/dev/null 2>&1) ||
    fail "worktree:rm failed in a repository path containing whitespace"
spaced_leftover="$(find "$spaced_root/r/.git/worktree-locks" -type f 2>/dev/null | wc -l | tr -d ' ')"
[ "$spaced_leftover" -eq 0 ] ||
    fail "a whitespace repository path stranded $spaced_leftover lock marker(s) (review r4/r5)"

echo "==> an unusable ps fails closed instead of breaking a dead lock"
# The liveness probe must read "ps itself is broken" as indeterminate: a
# sandboxed host that denies ps would otherwise turn every held lock into
# a breakable one (challenge round 2 of harmon-init#839/#784).
psshim_dir="$test_tmp/psshim"
mkdir -p "$psshim_dir"
printf '#!/bin/sh\nexit 1\n' >"$psshim_dir/ps"
chmod +x "$psshim_dir/ps"
sleep 0 &
psdead_pid=$!
wait "$psdead_pid" 2>/dev/null || true
mkdir -p "$fixture_locks/psdead-lk+lock"
printf '%s %s %s %s\n' "$psdead_pid" "$this_host" "$(id -u)" "$psdead_pid" >"$fixture_locks/psdead-lk+lock/owner"
if (
    PATH="$psshim_dir:$PATH"
    export PATH
    new psdead-lk >/dev/null 2>&1
); then
    fail "a dead lock was broken although ps could prove nothing (fail-open liveness)"
fi
[ -d "$fixture_locks/psdead-lk+lock" ] || fail "the unprovable lock was removed"
rm -rf "$fixture_locks/psdead-lk+lock"

echo "==> an empty holder marker refuses with the remedy, whatever its age"
mkdir -p "$fixture_locks/marker-lk+holders"
: >"$fixture_locks/marker-lk+holders/999999.marker"
touch -t 202601010000 "$fixture_locks/marker-lk+holders/999999.marker"
marker_out="$(new marker-lk 2>&1)" && fail "an aged empty holder marker was auto-swept despite the undecidable window"
case "$marker_out" in *"remove the marker file and re-run"*) : ;; *) fail "the empty-marker refusal named no remedy" ;; esac
rm -rf "$fixture_locks/marker-lk+holders"
mkdir -p "$fixture_locks/marker2-lk+holders"
: >"$fixture_locks/marker2-lk+holders/999999.marker"
if new marker2-lk >/dev/null 2>&1; then
    fail "a fresh empty holder marker (a live publication window) was ignored"
fi
rm -rf "$fixture_locks/marker2-lk+holders"

echo "==> a post-acquisition failure releases the lock"
new lock-rel >/dev/null || fail "creating the lock-release probe tree failed"
if new lock-rel >/dev/null 2>&1; then
    fail "a second creation of a registered name succeeded"
fi
refute_exists "$fixture_locks/lock-rel+lock" "a refused creation left its lock held"
rm_wt lock-rel >/dev/null || fail "cleanup of the lock-rel tree failed"
refute_exists "$fixture_locks/lock-rel+lock" "worktree:rm left its lock held"

echo "==> a removal in progress refuses a same-name recreation end to end"
# The #784 window itself, interposed: a git shim pauses worktree-rm.sh
# inside `git worktree remove`, a recreation is attempted mid-window (it
# must refuse at the lock), and only then is the removal released.
new interp >/dev/null || fail "creating the interposition tree failed"
shim_dir="$test_tmp/gitshim"
mkdir -p "$shim_dir"
real_git="$(command -v git)"
# The pause lands AFTER `git worktree remove` completes: that is when the
# tree is gone and the path is claimable again, which is exactly the window
# between removal and the later sweep steps that #784 is about. Pausing
# before the remove would leave the tree in place and the recreation would
# be refused by mere path occupancy, proving nothing about the lock.
cat >"$shim_dir/git" <<SHIM
#!/bin/sh
if [ "\$WTSHIM_PAUSE_REMOVE" = "1" ] && [ "\$1" = "worktree" ] && [ "\$2" = "remove" ]; then
  "$real_git" "\$@"
  shim_status=\$?
  : >"$test_tmp/shim-paused"
  while [ ! -e "$test_tmp/shim-release" ]; do sleep 0.2; done
  exit "\$shim_status"
fi
exec "$real_git" "\$@"
SHIM
chmod +x "$shim_dir/git"
rm -f "$test_tmp/shim-paused" "$test_tmp/shim-release"
(cd "$fixture" && PATH="$shim_dir:$PATH" WTSHIM_PAUSE_REMOVE=1 "$TIMEOUT_BIN" -k "$WORKTREE_OP_KILL_GRACE" "$WORKTREE_OP_TIMEOUT" bash scripts/worktree-rm.sh interp >"$test_tmp/interp-rm.log" 2>&1) &
interp_rm_pid=$!
shim_deadline=$(($(date +%s) + 30))
while [ ! -e "$test_tmp/shim-paused" ]; do
    [ "$(date +%s)" -lt "$shim_deadline" ] || {
        : >"$test_tmp/shim-release"
        fail "the removal never reached its pause point"
    }
    kill -0 "$interp_rm_pid" 2>/dev/null || {
        : >"$test_tmp/shim-release"
        fail "the paused removal died before pausing: $(cat "$test_tmp/interp-rm.log")"
    }
    sleep 0.2
done
if new interp >/dev/null 2>&1; then
    : >"$test_tmp/shim-release"
    fail "a recreation succeeded while the removal held the name (harmon-init#784)"
fi
: >"$test_tmp/shim-release"
wait "$interp_rm_pid" || fail "the interposed removal failed: $(cat "$test_tmp/interp-rm.log")"
refute_exists "$fixture/.worktrees/interp" "the interposed removal left the tree behind"
refute_exists "$fixture_locks/interp+lock" "the interposed removal left its lock held"
new interp >/dev/null || fail "recreation after the removal completed was refused"
rm_wt interp >/dev/null || fail "cleanup of the interp tree failed"

echo "==> a child removal in progress refuses an operation on its parent"
# worktree-rm.sh must hold the same shared ancestor markers creation holds:
# an rm integration taking only its leaf lock would let an operation ON the
# parent overlap the child's removal.
new rmparent/child --branch rmancestor >/dev/null || fail "creating the rm-ancestor tree failed"
rm -f "$test_tmp/shim-paused" "$test_tmp/shim-release"
cat >"$shim_dir/git" <<SHIM
#!/bin/sh
if [ "\$WTSHIM_PAUSE_REMOVE" = "1" ] && [ "\$1" = "worktree" ] && [ "\$2" = "remove" ]; then
  "$real_git" "\$@"
  shim_status=\$?
  : >"$test_tmp/shim-paused"
  while [ ! -e "$test_tmp/shim-release" ]; do sleep 0.2; done
  exit "\$shim_status"
fi
exec "$real_git" "\$@"
SHIM
chmod +x "$shim_dir/git"
(cd "$fixture" && PATH="$shim_dir:$PATH" WTSHIM_PAUSE_REMOVE=1 "$TIMEOUT_BIN" -k "$WORKTREE_OP_KILL_GRACE" "$WORKTREE_OP_TIMEOUT" bash scripts/worktree-rm.sh rmparent/child >"$test_tmp/rmanc.log" 2>&1) &
rmanc_pid=$!
shim_deadline=$(($(date +%s) + 30))
while [ ! -e "$test_tmp/shim-paused" ]; do
    [ "$(date +%s)" -lt "$shim_deadline" ] || {
        : >"$test_tmp/shim-release"
        fail "the child removal never reached its pause point"
    }
    kill -0 "$rmanc_pid" 2>/dev/null || {
        : >"$test_tmp/shim-release"
        fail "the paused child removal died: $(cat "$test_tmp/rmanc.log")"
    }
    sleep 0.2
done
# The child's removal leaves the emptied ancestor DIRECTORY until the
# paused script resumes; clear it so the probe below can only be refused by
# the shared marker, never by mere path occupancy.
rmdir "$fixture/.worktrees/rmparent" 2>/dev/null || {
    : >"$test_tmp/shim-release"
    fail "the emptied ancestor directory could not be cleared — the probe below would test path occupancy, not the marker"
}
if new rmparent >/dev/null 2>&1; then
    : >"$test_tmp/shim-release"
    fail "an operation on the parent proceeded while the child removal held its ancestor marker"
fi
: >"$test_tmp/shim-release"
wait "$rmanc_pid" || fail "the interposed child removal failed: $(cat "$test_tmp/rmanc.log")"
git -C "$fixture" branch -D rmancestor >/dev/null 2>&1 || true

echo "==> a remote advancing between probe and fetch still lands the fresh tip"
# The regression deferred from PR #906: the shim advances the bare remote
# the moment worktree-new.sh runs its fetch, so the first ls-remote's
# answer is stale by fetch time and only the UNCONDITIONAL post-fetch
# probe attaches the fresh tip.
padv_up="$test_tmp/probe-adv.git"
git init -q --bare "$padv_up"
git -C "$fixture" remote add padv "$padv_up"
git -C "$fixture" push -q padv HEAD:refs/heads/adv-branch
adv_a="$(git -C "$fixture" rev-parse HEAD)"
adv_b="$(git -C "$fixture" commit-tree -m "advanced mid-operation" -p "$adv_a" "$(git -C "$fixture" rev-parse "$adv_a^{tree}")")"
cat >"$shim_dir/git" <<SHIM
#!/bin/sh
if [ -n "\$WTSHIM_ADVANCE" ] && [ "\$1" != "push" ]; then
  for _arg in "\$@"; do
    if [ "\$_arg" = "fetch" ]; then
      if [ ! -e "$test_tmp/shim-advanced" ]; then
        : >"$test_tmp/shim-advanced"
        "$real_git" -C "$fixture" push -q padv "$adv_b:refs/heads/adv-branch"
      fi
      break
    fi
  done
fi
exec "$real_git" "\$@"
SHIM
chmod +x "$shim_dir/git"
rm -f "$test_tmp/shim-advanced"
(cd "$fixture" && PATH="$shim_dir:$PATH" WTSHIM_ADVANCE=1 "$TIMEOUT_BIN" -k "$WORKTREE_OP_KILL_GRACE" "$WORKTREE_OP_TIMEOUT" bash scripts/worktree-new.sh adv-branch >"$test_tmp/adv.log" 2>&1) ||
    fail "worktree-new.sh failed under the advancing remote: $(cat "$test_tmp/adv.log")"
[ "$(git -C "$fixture/.worktrees/adv-branch" rev-parse HEAD)" = "$adv_b" ] ||
    fail "worktree-new.sh attached the stale probed tip instead of the advanced remote tip (PR #906 deferral)"
rm_wt adv-branch >/dev/null || fail "cleanup of the adv-branch tree failed"
git -C "$fixture" branch -D adv-branch >/dev/null 2>&1 || true
git -C "$fixture" remote remove padv

echo "==> a dot-segment name cannot smuggle a worktree inside another"
new dotparent >/dev/null || fail "worktree-new.sh failed creating the dot-parent tree"
if new ./dotparent/child --branch dotchild >/dev/null 2>&1; then
    fail "worktree-new.sh nested a worktree via a './' path component"
fi
refute_exists "$fixture/.worktrees/dotparent/child" "the smuggled nested worktree was created"
rm_wt dotparent >/dev/null || fail "cleanup of the dot-parent tree failed"
refute_exists "$test_tmp/evil" "worktree-new.sh escaped the fixture directory"

echo "==> post-checkout at attach time already sees the remote-only branch tracked"
# harmon-init#916: `git worktree add` fires any HAND-WRITTEN post-checkout
# hook itself (LEFTHOOK=0 suppresses only lefthook-shaped shims), so
# tracking config written after the add left such a hook observing an
# untracked branch. The hook below records what @{upstream} resolves to at
# checkout time; the branch and its tracking config must already be there.
cat >"$shared_hooks/post-checkout" <<EOF
#!/bin/sh
git rev-parse --abbrev-ref '@{upstream}' >"$test_tmp/track-order.log" 2>/dev/null ||
    echo "UNTRACKED" >"$test_tmp/track-order.log"
exit 0
EOF
chmod +x "$shared_hooks/post-checkout"
git -C "$fixture" push -q origin HEAD:refs/heads/track-order
git -C "$fixture" update-ref -d refs/remotes/origin/track-order 2>/dev/null || true
new track-order >/dev/null || fail "worktree-new.sh failed for the tracking-order case"
grep -qx "origin/track-order" "$test_tmp/track-order.log" ||
    fail "post-checkout observed the remote-only branch untracked at attach time (harmon-init#916): $(cat "$test_tmp/track-order.log")"
rm -f "$shared_hooks/post-checkout"
rm_wt track-order >/dev/null || fail "cleanup of the track-order tree failed"
git -C "$fixture" branch -D track-order >/dev/null 2>&1 || true
git -C "$fixture" push -q origin :refs/heads/track-order

echo "==> a failed attach on the remote-only path rolls the pre-created branch back"
# The branch now exists BEFORE `git worktree add` (harmon-init#916), so a
# failing attach must take the pre-created branch and its tree with it —
# `git branch` refusing an existing name is what makes that deletion
# unambiguously safe (branch_owned in the rollback).
cat >"$shared_hooks/post-checkout" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$shared_hooks/post-checkout"
git -C "$fixture" push -q origin HEAD:refs/heads/rollback-remote
git -C "$fixture" update-ref -d refs/remotes/origin/rollback-remote 2>/dev/null || true
if new rollback-remote >/dev/null 2>&1; then
    rm -f "$shared_hooks/post-checkout"
    fail "worktree-new.sh reported success despite a failing attach on the remote-only path"
fi
rm -f "$shared_hooks/post-checkout"
refute_exists "$fixture/.worktrees/rollback-remote" "the failed remote-only attach left its tree behind"
if git -C "$fixture" show-ref --verify --quiet refs/heads/rollback-remote; then
    fail "the failed remote-only attach left its pre-created branch behind"
fi
if git -C "$fixture" worktree list --porcelain | grep -q "rollback-remote"; then
    fail "the failed remote-only attach left a registry record behind"
fi
git -C "$fixture" push -q origin :refs/heads/rollback-remote

echo "==> rollback leaves a branch whose tip moved since this run created it"
# The rollback is a COMPARE-and-delete: path locks do not serialize branch
# refs, so a concurrent actor can move the just-created branch before the
# attach fails, and deleting whatever tip exists then would discard commits
# this run never created (harmon-init#916, challenge round 1). The failing
# hook plays the concurrent actor deterministically: it moves the branch
# tip and then fails the attach.
moved_tip="$(git -C "$fixture" commit-tree -m "concurrent work" -p "$(git -C "$fixture" rev-parse HEAD)" "$(git -C "$fixture" rev-parse "HEAD^{tree}")")"
cat >"$shared_hooks/post-checkout" <<EOF
#!/bin/sh
git update-ref refs/heads/rollback-moved "$moved_tip"
exit 1
EOF
chmod +x "$shared_hooks/post-checkout"
git -C "$fixture" push -q origin HEAD:refs/heads/rollback-moved
git -C "$fixture" update-ref -d refs/remotes/origin/rollback-moved 2>/dev/null || true
moved_out="$(new rollback-moved 2>&1)" && {
    rm -f "$shared_hooks/post-checkout"
    fail "worktree-new.sh reported success despite the moved-tip attach failure"
}
rm -f "$shared_hooks/post-checkout"
[ "$(git -C "$fixture" rev-parse --verify --quiet refs/heads/rollback-moved || true)" = "$moved_tip" ] ||
    fail "rollback discarded a branch tip this run did not create (harmon-init#916)"
case "$moved_out" in *"leaving branch 'rollback-moved' alone"*) : ;; *) fail "the moved-tip rollback did not say it left the branch: $moved_out" ;; esac
refute_exists "$fixture/.worktrees/rollback-moved" "the moved-tip rollback left its tree behind"
git -C "$fixture" branch -D rollback-moved >/dev/null 2>&1 || true
git -C "$fixture" push -q origin :refs/heads/rollback-moved

echo "==> rollback leaves a branch a non-cooperating client attached mid-window"
# challenge round 5: a raw `git worktree add` (outside the branch lock)
# can attach the just-published branch between this run's update-ref and
# its own failing attach. update-ref -d bypasses git's checked-out guard,
# so rollback must scan for foreign attachments and leave the ref — no
# commit can be orphaned (any commit moves the tip and the
# compare-and-delete refuses), but the attach is not this run's to break.
git -C "$fixture" push -q origin HEAD:refs/heads/attachrace
git -C "$fixture" update-ref -d refs/remotes/origin/attachrace 2>/dev/null || true
rival_tree="$test_tmp/rival-tree"
rm -f "$test_tmp/attachrace-fired"
cat >"$shim_dir/git" <<SHIM
#!/bin/sh
if [ "\$WTSHIM_ATTACH_RACE" = "1" ] && [ ! -e "$test_tmp/attachrace-fired" ]; then
  for _arg in "\$@"; do
    if [ "\$_arg" = "$fixture/.worktrees/attachrace" ]; then
      : >"$test_tmp/attachrace-fired"
      "$real_git" -C "$fixture" worktree add "$rival_tree" attachrace >/dev/null 2>&1
      break
    fi
  done
fi
exec "$real_git" "\$@"
SHIM
chmod +x "$shim_dir/git"
attachrace_out="$(cd "$fixture" && PATH="$shim_dir:$PATH" WTSHIM_ATTACH_RACE=1 "$TIMEOUT_BIN" -k "$WORKTREE_OP_KILL_GRACE" "$WORKTREE_OP_TIMEOUT" bash scripts/worktree-new.sh attachrace 2>&1)" &&
    fail "worktree-new.sh reported success although its branch was attached elsewhere mid-run"
git -C "$fixture" worktree list --porcelain | grep -qx "worktree $rival_tree" ||
    fail "fixture assumption broken: the rival attach did not register"
git -C "$fixture" show-ref --verify --quiet refs/heads/attachrace ||
    fail "rollback deleted a branch another worktree had attached (harmon-init#916)"
case "$attachrace_out" in *"another worktree has it checked out"*) : ;; *) fail "the foreign-attach rollback did not say it left the branch: $attachrace_out" ;; esac
refute_exists "$fixture/.worktrees/attachrace" "the foreign-attach rollback left its own tree behind"
git -C "$fixture" worktree remove --force "$rival_tree" >/dev/null 2>&1 || true
git -C "$fixture" branch -D attachrace >/dev/null 2>&1 || true
git -C "$fixture" push -q origin :refs/heads/attachrace

echo "==> rollback keeps the branch when its worktree could not be removed"
# challenge round 3: update-ref is plumbing that bypasses git's
# checked-out guard, so deleting the branch under a tree the removal
# failed to clear would leave a live registered worktree on an unborn
# HEAD. `git worktree remove --force` deregisters even when directory
# deletion fails on permissions, so the deterministic stand-in for "the
# removal failed and the registration survived" is a LOCKED worktree:
# remove --force refuses one outright unless --force is given twice, and
# rollback passes it once. The failing hook locks its own tree.
cat >"$shared_hooks/post-checkout" <<'EOF'
#!/bin/sh
git worktree lock "$PWD"
exit 1
EOF
chmod +x "$shared_hooks/post-checkout"
git -C "$fixture" push -q origin HEAD:refs/heads/heldtree
git -C "$fixture" update-ref -d refs/remotes/origin/heldtree 2>/dev/null || true
heldtree_out="$(new heldtree 2>&1)" && {
    rm -f "$shared_hooks/post-checkout"
    fail "worktree-new.sh reported success despite the locked-tree attach failure"
}
rm -f "$shared_hooks/post-checkout"
git -C "$fixture" worktree list --porcelain | grep -qx "worktree $fixture/.worktrees/heldtree" ||
    fail "fixture assumption broken: the locked tree was deregistered after all"
git -C "$fixture" show-ref --verify --quiet refs/heads/heldtree ||
    fail "rollback deleted the branch of a worktree it could not remove (harmon-init#916)"
case "$heldtree_out" in *"could not be removed and still has it checked out"*) : ;; *) fail "the held-tree rollback did not say it kept the branch: $heldtree_out" ;; esac
git -C "$fixture" worktree unlock "$fixture/.worktrees/heldtree" 2>/dev/null || true
rm_wt heldtree --force >/dev/null || fail "cleanup of the held tree failed once unblocked"
git -C "$fixture" branch -D heldtree >/dev/null 2>&1 || true
git -C "$fixture" push -q origin :refs/heads/heldtree

echo "==> stale branch remote/merge config refuses creation instead of being overwritten"
# challenge rounds 3-4: branch.<name> config can outlive a deleted branch.
# Overwriting its remote/merge and trying to restore them on rollback grew
# capture-and-restore machinery with its own failure modes (a signal
# before the capture, multi-valued merge keys), so the design refuses the
# stale keys up front with the remedy — this run's writes are then the
# only possible values, and rollback is two guarded unsets.
git -C "$fixture" config branch.rollcfg.pushRemote myfork
git -C "$fixture" config branch.rollcfg.remote oldrem
git -C "$fixture" push -q origin HEAD:refs/heads/rollcfg
git -C "$fixture" update-ref -d refs/remotes/origin/rollcfg 2>/dev/null || true
rollcfg_out="$(new rollcfg 2>&1)" &&
    fail "worktree-new.sh overwrote stale branch config instead of refusing"
case "$rollcfg_out" in *"stale config from a deleted branch"*) : ;; *) fail "the stale-config refusal named no remedy: $rollcfg_out" ;; esac
refute_exists "$fixture/.worktrees/rollcfg" "the stale-config refusal left a tree behind"
if git -C "$fixture" show-ref --verify --quiet refs/heads/rollcfg; then
    fail "the stale-config refusal left the branch behind"
fi
[ "$(git -C "$fixture" config --get branch.rollcfg.remote || true)" = "oldrem" ] ||
    fail "the stale-config refusal modified the pre-existing remote key"
[ "$(git -C "$fixture" config --get branch.rollcfg.pushRemote || true)" = "myfork" ] ||
    fail "the stale-config refusal modified an unrelated branch config key"

echo "==> an invalid --branch is refused early, before any lock or side effect"
# The front door of the creation path: an explicit --branch used to bypass
# validation entirely and fail late, inside git, with the path reserved and
# locks held (#929). The validator is git's own branch grammar
# (check-ref-format), deliberately NOT the worktree-name charset: branch
# names legally carry metacharacters, and create-or-attach must keep
# accepting an existing 'feature+flag' (challenge r2).
for badbr in '../evil' '/abs' '-lead' 'a b' 'a//b' 'a/./b' '.topic' 'topic.' 'topic.lock' 'topic/.child'; do
    badbr_out="$(new brcheck --branch "$badbr" 2>&1)" &&
        fail "worktree-new.sh accepted the invalid --branch '$badbr'"
    # The distinctive prefix matters: git's own LATE failure ("fatal: ...
    # not a valid branch name / hint: See 'git help check-ref-format'")
    # also mentions check-ref-format, and a loose match let a mutant with
    # the early guard deleted pass this very case.
    case "$badbr_out" in *"rejected by git check-ref-format --branch"*) : ;; *) fail "the invalid --branch '$badbr' was not refused by the early guard: $badbr_out" ;; esac
done
# Checkout SHORTHAND must be refused even though check-ref-format accepts
# it: with checkout history, `--branch '@{-1}'` exits 0 there while
# expanding to the previous branch — the literal value would then feed the
# branch lock and worktree add (#929 challenge r3). Needs real history, or
# the shorthand fails the validator for the wrong reason.
git -C "$fixture" switch -qc shorthand-prev
git -C "$fixture" switch -q - >/dev/null 2>&1
short_out="$(new brcheck --branch '@{-1}' 2>&1)" &&
    fail "worktree-new.sh accepted the checkout shorthand @{-1} as a branch"
case "$short_out" in *"checkout shorthand is not accepted"*) : ;; *) fail "the @{-1} shorthand was refused for the wrong reason: $short_out" ;; esac
git -C "$fixture" branch -qD shorthand-prev
# An explicitly EMPTY --branch must be refused, not silently defaulted to
# the worktree name (#929 challenge r1).
empty_out="$(new brcheck --branch '' 2>&1)" &&
    fail "worktree-new.sh accepted an explicitly empty --branch"
case "$empty_out" in *"non-empty"*) : ;; *) fail "the empty --branch was refused for the wrong reason: $empty_out" ;; esac
refute_exists "$fixture/.worktrees/brcheck" "an invalid --branch refusal left a tree behind"
if git -C "$fixture" show-ref --verify --quiet refs/heads/brcheck; then
    fail "an invalid --branch refusal left the name branch behind"
fi
echo "==> the default branch = name path is unchanged"
new brcheck >/dev/null || fail "worktree-new.sh failed with the default branch after --branch refusals"
rm_wt brcheck >/dev/null || fail "cleanup of the default-branch tree failed"
git -C "$fixture" branch -D brcheck >/dev/null 2>&1 || true

echo "==> the stale-config remedy is shell-quoted for a metacharacter branch name"
# Branch names — unlike whitelisted worktree names — legally carry \$, ;,
# and quotes, so the pasted remedy must quote the key: unquoted,
# branch.rollcfg\$x.remote expands \$x away in the user's shell and clears
# the wrong key, or worse (PR #932 cloud review). This also pins the
# create-or-attach contract: a git-valid metacharacter branch passes the
# early --branch validation and reaches the deeper guards (#929
# challenge r2).
git -C "$fixture" config 'branch.rollcfg$x.remote' oldrem
git -C "$fixture" push -q origin 'HEAD:refs/heads/rollcfg$x'
git -C "$fixture" update-ref -d 'refs/remotes/origin/rollcfg$x' 2>/dev/null || true
metacfg_out="$(new rollcfg-meta --branch 'rollcfg$x' 2>&1)" &&
    fail "worktree-new.sh accepted a metacharacter branch with stale config"
case "$metacfg_out" in *"stale config from a deleted branch"*) : ;; *) fail "the metacharacter branch was refused for the wrong reason: $metacfg_out" ;; esac
case "$metacfg_out" in *"--unset-all 'branch.rollcfg\$x.remote'"*) : ;; *) fail "the stale-config remedy was not shell-quoted: $metacfg_out" ;; esac
refute_exists "$fixture/.worktrees/rollcfg-meta" "the metacharacter refusal left a tree behind"
git -C "$fixture" config --unset 'branch.rollcfg$x.remote'
git -C "$fixture" push -q origin ':refs/heads/rollcfg$x'

echo "==> a non-local stale branch config value does not refuse creation"
# PR #932 cloud review: the stale-debris guard exists for LOCAL config this
# script's own rollback can leave; a global/system/include-provided value
# is user configuration the advertised unset cannot clear (git config
# --unset-all exits 5 for a global-only value), so an unscoped lookup
# turned it into a permanent refusal. The guard reads --local only.
git -C "$fixture" push -q origin HEAD:refs/heads/globalcfg
git -C "$fixture" update-ref -d refs/remotes/origin/globalcfg 2>/dev/null || true
global_cfg="$test_tmp/globalcfg.gitconfig"
git config --file "$global_cfg" branch.globalcfg.remote elsewhere
(cd "$fixture" && GIT_CONFIG_GLOBAL="$global_cfg" "$TIMEOUT_BIN" -k "$WORKTREE_OP_KILL_GRACE" "$WORKTREE_OP_TIMEOUT" bash scripts/worktree-new.sh globalcfg) >/dev/null 2>&1 ||
    fail "a global-scope branch config value refused a remote-only creation (PR #932 cloud review)"
[ "$(git config --file "$global_cfg" --get branch.globalcfg.remote)" = "elsewhere" ] ||
    fail "the creation modified non-local user configuration"
rm_wt globalcfg >/dev/null || fail "cleanup of the globalcfg tree failed"
git -C "$fixture" branch -D globalcfg >/dev/null 2>&1 || true
git -C "$fixture" push -q origin :refs/heads/globalcfg
rm -f "$global_cfg"

echo "==> lefthook-shimmed hooks stay suppressed during branch publication"
# PR #932 cloud review: a repo can shim reference-transaction through
# lefthook, and the bare update-ref publication fired it before the new
# tree and its project tooling existed. Every ref write this operation
# makes runs under LEFTHOOK=0, so a shim that refuses whenever LEFTHOOK
# is not 0 must not block a remote-only creation.
git -C "$fixture" push -q origin HEAD:refs/heads/refhook
git -C "$fixture" update-ref -d refs/remotes/origin/refhook 2>/dev/null || true
cat >"$shared_hooks/reference-transaction" <<'HOOK'
#!/bin/sh
[ "${LEFTHOOK:-}" = "0" ] && exit 0
exit 1
HOOK
chmod +x "$shared_hooks/reference-transaction"
refhook_status=0
new refhook >/dev/null 2>&1 || refhook_status=$?
rm -f "$shared_hooks/reference-transaction"
[ "$refhook_status" -eq 0 ] ||
    fail "an unsuppressed reference-transaction hook fired during publication (PR #932 cloud review)"
rm_wt refhook >/dev/null || fail "cleanup of the refhook tree failed"
git -C "$fixture" branch -D refhook >/dev/null 2>&1 || true
git -C "$fixture" push -q origin :refs/heads/refhook

echo "==> a signal landing on a failed publication cannot reach an armed rollback"
# PR #932 cloud review: HUP/INT/TERM trap to 'exit 129', which runs
# cleanup, and bash executes a pending trap between a FAILED create-only
# update-ref and the un-arm that follows it — cleanup then saw
# branch_owned=1 and its compare-and-delete matched a COMPETING client's
# branch at the same probed tip, deleting a branch this run never
# created. The fix defers the three signals across the create -> flag
# transition and re-raises them after. The shim stages the race
# deterministically: it creates the competing ref, signals the script,
# and lets the real create-only update-ref fail.
git -C "$fixture" push -q origin HEAD:refs/heads/sigrace
git -C "$fixture" update-ref -d refs/remotes/origin/sigrace 2>/dev/null || true
sigrace_tip="$(git -C "$fixture" rev-parse HEAD)"
rm -f "$test_tmp/sigrace-fired"
cat >"$shim_dir/git" <<SHIM
#!/bin/sh
if [ "\$WTSHIM_SIG_RACE" = "1" ] && [ ! -e "$test_tmp/sigrace-fired" ] && [ "\$1" = "update-ref" ]; then
  for _arg in "\$@"; do
    if [ "\$_arg" = "refs/heads/sigrace" ]; then
      : >"$test_tmp/sigrace-fired"
      "$real_git" -C "$fixture" update-ref refs/heads/sigrace "$sigrace_tip"
      kill -TERM "\$PPID"
      break
    fi
  done
fi
exec "$real_git" "\$@"
SHIM
chmod +x "$shim_dir/git"
sigrace_status=0
(cd "$fixture" && PATH="$shim_dir:$PATH" WTSHIM_SIG_RACE=1 "$TIMEOUT_BIN" -k "$WORKTREE_OP_KILL_GRACE" "$WORKTREE_OP_TIMEOUT" bash scripts/worktree-new.sh sigrace) >/dev/null 2>&1 || sigrace_status=$?
[ "$sigrace_status" -ne 0 ] ||
    fail "fixture assumption broken: the raced creation reported success"
[ -e "$test_tmp/sigrace-fired" ] ||
    fail "fixture assumption broken: the update-ref shim never fired"
git -C "$fixture" show-ref --verify --quiet refs/heads/sigrace ||
    fail "a signal on a failed publication deleted a competing client's branch (PR #932 cloud review)"
[ "$(git -C "$fixture" rev-parse refs/heads/sigrace)" = "$sigrace_tip" ] ||
    fail "the competing branch tip changed under the raced rollback"
refute_exists "$fixture/.worktrees/sigrace" "the raced creation left a tree behind"
git -C "$fixture" branch -D sigrace >/dev/null 2>&1 || true
git -C "$fixture" push -q origin :refs/heads/sigrace

echo "==> rollback removes only the branch config keys this run wrote"
# With the stale keys cleared, creation proceeds; a failing attach must
# take back exactly the remote/merge keys this run wrote while the
# untouched pushRemote survives.
git -C "$fixture" config --unset-all branch.rollcfg.remote
cat >"$shared_hooks/post-checkout" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$shared_hooks/post-checkout"
if new rollcfg >/dev/null 2>&1; then
    rm -f "$shared_hooks/post-checkout"
    fail "worktree-new.sh reported success despite the failing attach in the config case"
fi
rm -f "$shared_hooks/post-checkout"
[ "$(git -C "$fixture" config --get branch.rollcfg.pushRemote || true)" = "myfork" ] ||
    fail "rollback removed a pre-existing branch config key it never wrote (harmon-init#916)"
if git -C "$fixture" config --get branch.rollcfg.remote >/dev/null 2>&1; then
    fail "rollback left the branch.<name>.remote key this run wrote"
fi
if git -C "$fixture" config --get branch.rollcfg.merge >/dev/null 2>&1; then
    fail "rollback left the branch.<name>.merge key this run wrote"
fi
git -C "$fixture" config --remove-section branch.rollcfg 2>/dev/null || true
git -C "$fixture" push -q origin :refs/heads/rollcfg

# ── per-tree dependency install ──────────────────────────────────────
echo "==> a Node repo gets its dependencies installed in the NEW tree"
pnpm_marker="$test_tmp/pnpm-invoked"
cat >"$stub_bin/pnpm" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "--version" ]; then
    echo 9.0.0
    exit 0
fi
printf '%s %s\n' "\$*" "\$PWD" >>"$pnpm_marker"
exit 0
EOF
chmod +x "$stub_bin/pnpm"
# The lockfile is what marks this repo as pnpm's: package.json alone is shared
# by npm, Yarn, and Bun, so it selects no installer (harmon-init#841) — the
# signal-less case has its own coverage below.
printf '{"name":"fixture","private":true}\n' >"$fixture/package.json"
printf 'lockfileVersion: "9.0"\n' >"$fixture/pnpm-lock.yaml"
git -C "$fixture" add -A
git -C "$fixture" commit -qm "chore: add package.json" >"$test_tmp/commit.log" 2>&1 ||
    {
        cat "$test_tmp/commit.log" >&2
        fail "committing package.json in the fixture failed"
    }
new node-tree >/dev/null || fail "worktree-new.sh failed on a Node repo"
grep -qx "install --frozen-lockfile $fixture/.worktrees/node-tree" "$pnpm_marker" 2>/dev/null ||
    fail "worktree-new.sh did not run 'pnpm install --frozen-lockfile' inside the new tree"
rm_wt node-tree >/dev/null || fail "cleanup of the node tree failed"

echo "==> a pnpm workspace without a root package.json still installs"
: >"$pnpm_marker"
git -C "$fixture" rm -q --cached package.json >/dev/null
# The lockfile goes too: with it present this case would pass even if
# workspace-file recognition regressed, which is the property it exists for.
rm -f "$fixture/package.json" "$fixture/pnpm-lock.yaml"
printf 'packages:\n  - "packages/*"\n' >"$fixture/pnpm-workspace.yaml"
git -C "$fixture" add -A
LEFTHOOK=0 git -C "$fixture" commit -qm "chore: workspace without a root manifest" >"$test_tmp/commit.log" 2>&1 ||
    fail "committing the workspace-only layout failed"
new workspace-tree >/dev/null || fail "worktree-new.sh failed on a manifest-less pnpm workspace"
grep -qx "install $fixture/.worktrees/workspace-tree" "$pnpm_marker" 2>/dev/null ||
    fail "worktree-new.sh skipped pnpm install for a pnpm-workspace.yaml-only repo"
rm_wt workspace-tree >/dev/null || fail "cleanup of the workspace tree failed"
printf '{"name":"fixture","private":true}\n' >"$fixture/package.json"
git -C "$fixture" add -A
LEFTHOOK=0 git -C "$fixture" commit -qm "chore: restore the root manifest" >"$test_tmp/commit.log" 2>&1 ||
    fail "restoring the root package.json failed"

# ── package-manager detection (harmon-init#841) ──────────────────────
# package.json is shared by npm, Yarn, Bun, and pnpm, so worktree-new.sh
# selects the installer from the repo's own signals instead of assuming pnpm.
# Every case states its whole fixture through det_reset (all Node signal files
# cleared first) and asserts BOTH halves of the invariant: the selected
# installer ran in the tree, and every competitor stayed silent — the second
# half is what catches a regression to the old unconditional pnpm.
# Each stub answers --version without logging (worktree-new.sh reads it to
# verify a declared version pin) and records every other invocation.
for det_name in npm yarn bun; do
    case "$det_name" in
    npm) det_stub_ver=10.9.2 ;;
    yarn) det_stub_ver=4.1.0 ;;
    bun) det_stub_ver=1.2.10 ;;
    esac
    cat >"$stub_bin/$det_name" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "--version" ]; then
    echo $det_stub_ver
    exit 0
fi
printf '%s %s\n' "\$*" "\$PWD" >>"$test_tmp/$det_name-invoked"
exit 0
EOF
    chmod +x "$stub_bin/$det_name"
done

det_signal_files="package.json pnpm-workspace.yaml pnpm-lock.yaml package-lock.json npm-shrinkwrap.json yarn.lock bun.lock bun.lockb"
det_reset() {
    for det_name in pnpm npm yarn bun; do
        : >"$test_tmp/$det_name-invoked"
    done
    for det_name in $det_signal_files; do
        rm -f "$fixture/$det_name"
    done
}
det_commit() {
    git -C "$fixture" add -A
    LEFTHOOK=0 git -C "$fixture" commit -qm "chore: $1" >"$test_tmp/commit.log" 2>&1 ||
        {
            cat "$test_tmp/commit.log" >&2
            fail "committing the detection fixture ($1) failed"
        }
}
det_assert_installer() {
    # $1 = the manager that must have installed ('' for none); $2 = the exact
    # arguments it must have been invoked with, so the immutable-mode
    # selection is asserted too; $3 = the tree path ('' when no tree should
    # exist).
    for det_name in pnpm npm yarn bun; do
        if [ "$det_name" = "$1" ]; then
            grep -qx "$2 $3" "$test_tmp/$det_name-invoked" 2>/dev/null ||
                fail "worktree-new.sh did not run '$det_name $2' inside $3"
        elif [ -s "$test_tmp/$det_name-invoked" ]; then
            fail "worktree-new.sh invoked $det_name in a tree whose manager is '${1:-none}'"
        fi
    done
}

echo "==> an npm lockfile selects npm, and no competing installer runs"
det_reset
printf '{"name":"fixture","private":true}\n' >"$fixture/package.json"
printf '{"lockfileVersion": 3}\n' >"$fixture/package-lock.json"
det_commit "npm lockfile"
new det-npm >/dev/null || fail "worktree-new.sh failed on an npm repo"
det_assert_installer npm ci "$fixture/.worktrees/det-npm"
rm_wt det-npm >/dev/null || fail "cleanup of the npm tree failed"

echo "==> a yarn.lock selects Yarn"
det_reset
printf '{"name":"fixture","private":true}\n' >"$fixture/package.json"
printf '# yarn lockfile v1\n' >"$fixture/yarn.lock"
det_commit "yarn lockfile"
new det-yarn >/dev/null || fail "worktree-new.sh failed on a Yarn repo"
det_assert_installer yarn "install --immutable" "$fixture/.worktrees/det-yarn"
rm_wt det-yarn >/dev/null || fail "cleanup of the yarn tree failed"

echo "==> a bun.lock selects Bun"
det_reset
printf '{"name":"fixture","private":true}\n' >"$fixture/package.json"
printf '{}\n' >"$fixture/bun.lock"
det_commit "bun lockfile"
new det-bun >/dev/null || fail "worktree-new.sh failed on a Bun repo"
det_assert_installer bun "install --frozen-lockfile" "$fixture/.worktrees/det-bun"
rm_wt det-bun >/dev/null || fail "cleanup of the bun tree failed"

echo "==> a declared packageManager with its own lockfile wins over a stale foreign one"
det_reset
printf '{"name":"fixture","private":true,"packageManager":"npm@10.9.2+sha512.0123abcdef"}\n' >"$fixture/package.json"
printf '{"lockfileVersion": 3}\n' >"$fixture/package-lock.json"
printf 'lockfileVersion: "9.0"\n' >"$fixture/pnpm-lock.yaml"
det_commit "declared npm with its own lockfile over a stale pnpm one"
new det-declared >/dev/null || fail "worktree-new.sh failed on a declared-manager repo"
det_assert_installer npm ci "$fixture/.worktrees/det-declared"
rm_wt det-declared >/dev/null || fail "cleanup of the declared-manager tree failed"

echo "==> a declaration whose manager has no files here fails instead of writing a second lockfile"
det_reset
printf '{"name":"fixture","private":true,"packageManager":"npm@10.9.2"}\n' >"$fixture/package.json"
printf 'lockfileVersion: "9.0"\n' >"$fixture/pnpm-lock.yaml"
det_commit "declared npm against a foreign-only lockfile"
det_status=0
det_out="$(new det-foreign 2>&1)" || det_status=$?
[ "$det_status" -ne 0 ] || fail "worktree-new.sh succeeded for a declaration contradicted by a foreign-only lockfile"
printf '%s\n' "$det_out" | grep -q "carries other managers' files (pnpm) and none of npm's" ||
    fail "the foreign-only-lockfile refusal did not name the contradiction"
det_assert_installer "" "" ""
refute_exists "$fixture/.worktrees/det-foreign" "worktree-new.sh left a tree behind after refusing a contradicted declaration"
if git -C "$fixture" show-ref --verify --quiet refs/heads/det-foreign; then
    fail "worktree-new.sh left the branch behind after refusing a contradicted declaration"
fi

echo "==> a declared version pin with a drifted major fails instead of installing"
det_reset
printf '{"name":"fixture","private":true,"packageManager":"npm@6.14.18"}\n' >"$fixture/package.json"
printf '{"lockfileVersion": 1}\n' >"$fixture/package-lock.json"
det_commit "declared npm@6 against a newer installed npm"
det_status=0
det_out="$(new det-verpin 2>&1)" || det_status=$?
[ "$det_status" -ne 0 ] || fail "worktree-new.sh installed under a version pin its npm does not satisfy"
printf '%s\n' "$det_out" | grep -q "pins npm@6.14.18 but npm 10.9.2 is installed" ||
    fail "the version-pin refusal did not name the pinned and installed versions"
det_assert_installer "" "" ""
refute_exists "$fixture/.worktrees/det-verpin" "worktree-new.sh left a tree behind after refusing a version-pin mismatch"
if git -C "$fixture" show-ref --verify --quiet refs/heads/det-verpin; then
    fail "worktree-new.sh left the branch behind after refusing a version-pin mismatch"
fi

echo "==> an unsupported packageManager fails loudly, installs nothing, rolls back"
det_reset
printf '{"name":"fixture","private":true,"packageManager":"moon@1.2.3"}\n' >"$fixture/package.json"
det_commit "unsupported manager declaration"
det_status=0
det_out="$(new det-unsupported 2>&1)" || det_status=$?
[ "$det_status" -ne 0 ] || fail "worktree-new.sh succeeded with an unsupported packageManager declaration"
printf '%s\n' "$det_out" | grep -q "does not support" ||
    fail "the unsupported-manager refusal did not say the declaration is unsupported"
det_assert_installer "" "" ""
refute_exists "$fixture/.worktrees/det-unsupported" "worktree-new.sh left a tree behind after refusing an unsupported manager"
if git -C "$fixture" show-ref --verify --quiet refs/heads/det-unsupported; then
    fail "worktree-new.sh left the branch behind after refusing an unsupported manager"
fi

echo "==> lockfiles from two managers fail loudly instead of guessing"
det_reset
printf '{"name":"fixture","private":true}\n' >"$fixture/package.json"
printf '{"lockfileVersion": 3}\n' >"$fixture/package-lock.json"
printf 'bun-binary-lockfile\n' >"$fixture/bun.lockb"
det_commit "conflicting lockfiles"
det_status=0
det_out="$(new det-conflict 2>&1)" || det_status=$?
[ "$det_status" -ne 0 ] || fail "worktree-new.sh succeeded with lockfiles from two package managers"
printf '%s\n' "$det_out" | grep -q "conflicting Node package-manager signals in this tree: npm bun" ||
    fail "the conflicting-lockfile refusal did not name both managers"
det_assert_installer "" "" ""
refute_exists "$fixture/.worktrees/det-conflict" "worktree-new.sh left a tree behind after refusing conflicting lockfiles"
if git -C "$fixture" show-ref --verify --quiet refs/heads/det-conflict; then
    fail "worktree-new.sh left the branch behind after refusing conflicting lockfiles"
fi

echo "==> a bare package.json with no signal skips the install, saying why"
det_reset
printf '{"name":"fixture","private":true}\n' >"$fixture/package.json"
det_commit "bare manifest, no manager signal"
det_out="$(new det-bare 2>&1)" || fail "worktree-new.sh failed on a signal-less Node repo"
printf '%s\n' "$det_out" | grep -q "no package-manager signal" ||
    fail "the signal-less run did not say why the install was skipped"
det_assert_installer "" "" ""
rm_wt det-bare >/dev/null || fail "cleanup of the signal-less tree failed"

echo "==> a packageManager declaration split across lines still parses"
det_reset
printf '{\n  "name": "fixture",\n  "private": true,\n  "packageManager":\n    "yarn@4.1.0"\n}\n' >"$fixture/package.json"
det_commit "multi-line packageManager declaration"
new det-multiline >/dev/null || fail "worktree-new.sh failed on a multi-line packageManager declaration"
det_assert_installer yarn install "$fixture/.worktrees/det-multiline"
rm_wt det-multiline >/dev/null || fail "cleanup of the multi-line tree failed"

# The shipped devcontainer post-checkout hook auto-installs Node dependencies
# and is NOT a lefthook shim — post-create.sh copies it straight into
# .git/hooks, so `git worktree add` fires it before the detector ever runs.
# The guard under test is that hook's own LEFTHOOK=0 gate (harmon-init#841):
# without it, its lockfile-first fallback runs a competing installer — pnpm
# from a stale pnpm-lock.yaml in a repo whose package.json declares npm. The
# REAL hook is exercised, not a mimic, so dropping the guard upstream fails
# this case. A rendered tree without the devcontainer profile has no hook to
# pin down, and the case skips.
if [ -f "$repo/.devcontainer/hooks/post-checkout" ]; then
    echo "==> the devcontainer post-checkout hook defers to the detector"
    det_reset
    printf '{"name":"fixture","private":true,"packageManager":"npm@10.9.2"}\n' >"$fixture/package.json"
    printf '{"lockfileVersion": 3}\n' >"$fixture/package-lock.json"
    printf 'lockfileVersion: "9.0"\n' >"$fixture/pnpm-lock.yaml"
    det_commit "declared npm with a stale pnpm lockfile"
    cp "$repo/.devcontainer/hooks/post-checkout" "$shared_hooks/post-checkout"
    chmod +x "$shared_hooks/post-checkout"
    # The hook chains git-lfs before its install section and exits 2 when the
    # binary is missing — which would fail the worktree add for a reason this
    # case is not about. Satisfy the chain with a stub.
    cat >"$stub_bin/git-lfs" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$stub_bin/git-lfs"
    new det-hook >/dev/null || fail "worktree-new.sh failed with the devcontainer post-checkout hook installed"
    det_assert_installer npm ci "$fixture/.worktrees/det-hook"
    rm_wt det-hook >/dev/null || fail "cleanup of the hook tree failed"
    rm -f "$shared_hooks/post-checkout" "$stub_bin/git-lfs"
else
    echo "==> Note: no devcontainer post-checkout hook in this tree; skipping its suppression case"
fi

# Restore the pnpm fixture the cases below assume — package.json plus the
# workspace file, exactly as it stood before this block.
det_reset
printf '{"name":"fixture","private":true}\n' >"$fixture/package.json"
printf 'packages:\n  - "packages/*"\n' >"$fixture/pnpm-workspace.yaml"
det_commit "restore the pnpm fixture"
: >"$pnpm_marker"

# ── post-checkout runs AFTER dependencies are installed ──────────────
# `git worktree add` fires post-checkout itself, before anything is installed,
# so a hook that needs project dependencies would fail in every fresh worktree.
echo "==> post-checkout runs only after the dependency install"
cat >"$fixture/lefthook.yml" <<'EOF'
pre-commit:
  commands:
    noop:
      run: "true"

post-checkout:
  commands:
    noop:
      run: "true"
EOF
git -C "$fixture" add lefthook.yml
LEFTHOOK=0 git -C "$fixture" commit -qm "chore: configure post-checkout" >"$test_tmp/commit.log" 2>&1 ||
    fail "committing the post-checkout lefthook.yml failed"
cat >"$shared_hooks/post-checkout" <<EOF
#!/bin/sh
# Shaped like a lefthook-installed shim: it honours LEFTHOOK=0 (which is what
# lets the provisioning checkout suppress it) and delegates to LEFTHOOK_BIN
# (which is what the entrypoint's hook probe uses). Only a real invocation —
# neither suppressed nor probed — reaches the assertion, which fails unless the
# per-tree dependency install has already happened.
if [ "\$LEFTHOOK" = "0" ]; then
  exit 0
fi
if [ -n "\$LEFTHOOK_BIN" ]; then
  exec "\$LEFTHOOK_BIN" run "post-checkout" "\$@"
fi
[ -n "\$(cat "$pnpm_marker" 2>/dev/null)" ] || exit 1
printf 'post-checkout %s\n' "\$PWD" >>"$test_tmp/post-checkout.log"
EOF
chmod +x "$shared_hooks/post-checkout"
: >"$pnpm_marker"
: >"$test_tmp/post-checkout.log"
new ordered-tree >/dev/null || fail "worktree-new.sh failed with a dependency-using post-checkout hook"
grep -qx "post-checkout $fixture/.worktrees/ordered-tree" "$test_tmp/post-checkout.log" 2>/dev/null ||
    fail "post-checkout did not run in the new tree after provisioning"
rm_wt ordered-tree >/dev/null || fail "cleanup of the ordered tree failed"
rm -f "$shared_hooks/post-checkout"

echo "==> --no-install skips the dependency install"
: >"$pnpm_marker"
# This case runs under a stdin that never reaches EOF — the agent-session
# condition the suite's own `exec </dev/null` shields everything else from.
# lefthook blocks `run post-checkout` until stdin EOF (harmon-init#802), so
# worktree-new.sh must hand the deferred hook an already-EOF stdin. The shim
# below asserts that invariant ITSELF (`cat` drains to EOF before logging):
# relying on the real lefthook to do the blocking would make this case
# vacuous under the stub (whose `run` reads nothing) and hostage to whichever
# stdin behavior a future lefthook ships. A worktree-new.sh that ties the
# hook to the caller's stdin blocks in `cat` and hangs into the #792 bound.
cat >"$shared_hooks/post-checkout" <<EOF
#!/bin/sh
if [ "\$LEFTHOOK" = "0" ]; then
  exit 0
fi
if [ -n "\$LEFTHOOK_BIN" ]; then
  exec "\$LEFTHOOK_BIN" run "post-checkout" "\$@"
fi
cat >/dev/null
printf 'post-checkout-eof %s\n' "\$PWD" >>"$test_tmp/post-checkout.log"
EOF
chmod +x "$shared_hooks/post-checkout"
: >"$test_tmp/post-checkout.log"
mkfifo "$test_tmp/hostile-stdin"
# The writer is UNBOUNDED (`tail -f /dev/null` never exits, on macOS and
# Linux alike): a `sleep <n>` writer would close the fifo at n seconds, and a
# WORKTREE_OP_TIMEOUT configured above n would then hand a regressed hook its
# EOF and pass this case instead of failing it. The explicit kill below and
# the EXIT trap are what end this process.
tail -f /dev/null >"$test_tmp/hostile-stdin" &
WORKTREE_STDIN_HOLDER=$!
new no-install-tree --no-install <"$test_tmp/hostile-stdin" >/dev/null ||
    fail "worktree-new.sh --no-install failed under a non-EOF stdin"
grep -qx "post-checkout-eof $fixture/.worktrees/no-install-tree" "$test_tmp/post-checkout.log" 2>/dev/null ||
    fail "the deferred post-checkout never reached EOF on its stdin — is it still tied to the caller's stdin? (harmon-init#802)"
kill "$WORKTREE_STDIN_HOLDER" 2>/dev/null || true
wait "$WORKTREE_STDIN_HOLDER" 2>/dev/null || true
WORKTREE_STDIN_HOLDER=""
# The shim deliberately stays installed: the missing-pnpm case below runs
# under a PATH mask that hides lefthook, so a configured-but-absent
# post-checkout hook would fail it at the hook stage instead of the pnpm
# gate it exists to assert.
if [ -s "$pnpm_marker" ]; then
    fail "worktree-new.sh ran the installer despite --no-install"
fi
rm_wt no-install-tree >/dev/null || fail "cleanup of the --no-install tree failed"

echo "==> a missing package manager fails loudly and rolls the tree back"
rm -f "$stub_bin/pnpm"
# `worktree-new.sh` gates on `have pnpm`, so this case needs pnpm genuinely
# absent from PATH — a stub that fails would still be FOUND and would prove
# something else. Naming system directories directly cannot deliver that: pnpm
# is a corepack shim at /usr/bin/pnpm in this repo's own devcontainer, so
# `PATH="$stub_bin:/usr/bin:/bin"` left pnpm reachable, the run succeeded, and
# the assertion failed on every machine that installs it there — CI passed only
# because its pnpm happens to live elsewhere (harmon-init#791). Dropping the
# offending directory wholesale is not an option either: git and coreutils live
# beside it.
#
# So mirror the system tools into a sandbox and omit exactly one. The mask then
# holds wherever pnpm is installed, because it is defined by what the sandbox
# CONTAINS rather than by what some directory is assumed not to.
mask_bin="$test_tmp/mask-bin"
rm -rf "$mask_bin"
mkdir -p "$mask_bin"
for mask_dir in /usr/local/bin /usr/bin /bin; do
    [ -d "$mask_dir" ] || continue
    for mask_src in "$mask_dir"/*; do
        [ -x "$mask_src" ] || continue
        mask_name=${mask_src##*/}
        case "$mask_name" in
        pnpm) continue ;;
        esac
        if [ -e "$mask_bin/$mask_name" ]; then
            continue
        fi
        ln -s "$mask_src" "$mask_bin/$mask_name"
    done
done
# The guard the sandbox exists to create — if pnpm is still reachable the case
# below would pass for the wrong reason, and a mask that silently stops masking
# is worse than no mask.
if (
    PATH="$mask_bin"
    export PATH
    command -v pnpm >/dev/null 2>&1
); then
    fail "the pnpm mask did not take effect; the missing-pnpm case would prove nothing"
fi
if (
    PATH="$mask_bin"
    export PATH
    new missing-pnpm >/dev/null 2>&1
); then
    fail "worktree-new.sh succeeded with package.json present and no pnpm"
fi
refute_exists "$fixture/.worktrees/missing-pnpm" "worktree-new.sh left a half-provisioned tree behind"
if git -C "$fixture" show-ref --verify --quiet refs/heads/missing-pnpm; then
    fail "worktree-new.sh left the branch behind after rolling back"
fi

# The bound itself needs a test, or both protections above could regress in
# silence: nothing else in this suite ever exceeds the deadline or ignores
# TERM. The stub traps TERM and sleeps, so it can only die to the KILL that
# `-k` schedules, and the assertions below check all three properties that
# matter — it is killed promptly, it says why, and it is FATAL rather than
# passing for the expected-failure assertion that follows a refusal.
# Any sentinel present HERE was left by an earlier case whose timeout was
# swallowed — exactly the evidence the EXIT trap exists to surface. The
# self-test below writes and then clears the sentinel, so without this check it
# would erase that evidence and the suite could still exit 0.
if [ -e "$WORKTREE_TIMEOUT_SENTINEL" ]; then
    fail "an earlier worktree operation timed out and was swallowed: $(cat "$WORKTREE_TIMEOUT_SENTINEL")"
fi
echo "==> a hung worktree operation is killed, explained, and fatal"
cp "$fixture/scripts/worktree-new.sh" "$test_tmp/worktree-new.sh.bak"
cat >"$fixture/scripts/worktree-new.sh" <<'HANGSTUB'
#!/usr/bin/env bash
trap '' TERM
sleep 300
HANGSTUB
chmod +x "$fixture/scripts/worktree-new.sh"
hang_log="$test_tmp/hang.log"
hang_start=$(date +%s)
if (
    WORKTREE_OP_TIMEOUT=2
    WORKTREE_OP_KILL_GRACE=1
    new hang-tree
) >"$hang_log" 2>&1; then
    fail "a hung worktree:new reported success"
fi
hang_elapsed=$(($(date +%s) - hang_start))
[ "$hang_elapsed" -lt 30 ] ||
    fail "the hung operation was not killed promptly (${hang_elapsed}s) — is -k still passed?"
grep -q 'timed out after' "$hang_log" ||
    fail "the timeout emitted no diagnostic naming the operation"
grep -q 'TEST FAIL' "$hang_log" ||
    fail "a timeout must be fatal, not returned as an ordinary failure"
# The property the subshell construct above would otherwise hide: the negative
# cases run these wrappers exactly this way, so `fail` alone ends only the
# subshell and the `if` accepts the non-zero status as the refusal it asserts.
# The sentinel is what survives that, and it is what the EXIT trap reads.
[ -e "$WORKTREE_TIMEOUT_SENTINEL" ] ||
    fail "a timeout inside a subshell left no sentinel, so the suite could still exit 0"
rm -f "$WORKTREE_TIMEOUT_SENTINEL"
cp "$test_tmp/worktree-new.sh.bak" "$fixture/scripts/worktree-new.sh"
chmod +x "$fixture/scripts/worktree-new.sh"

# The self-test above proves the sentinel is WRITTEN; this proves it is
# ACTED ON. Removing or miswiring the EXIT trap would leave that test green,
# so assert the wiring and then run the real `worktree_exit` against throwaway
# paths — the subshell's assignments keep the live $test_tmp and sentinel out
# of its `rm -rf`.
echo "==> the EXIT trap turns a swallowed timeout into a failing suite"
# Captured, never piped: Bash 3.2 resets traps in a pipeline's subshell, so
# `trap -p EXIT | grep -q …` reads an empty trap list and fails even when the
# trap is wired (harmon-init#844). `$(trap -p EXIT)` reports the parent
# shell's traps on every supported Bash.
exit_trap="$(trap -p EXIT)"
case "$exit_trap" in *worktree_exit*) : ;; *) fail "the EXIT trap is no longer wired to worktree_exit" ;; esac
trap_log="$test_tmp/trap.log"
if (
    test_tmp="$(mktemp -d -t harmon-init-worktree-trap-XXXXXX)"
    WORKTREE_TIMEOUT_SENTINEL="$(mktemp -t harmon-init-worktree-trapsentinel-XXXXXX)"
    echo "worktree:new timed out after 1s: probe-tree" >"$WORKTREE_TIMEOUT_SENTINEL"
    worktree_exit
) >"$trap_log" 2>&1; then
    fail "worktree_exit reported success despite a sentinel"
fi
grep -q 'probe-tree' "$trap_log" ||
    fail "worktree_exit did not report what timed out: $(cat "$trap_log")"

echo "==> a teardown that cannot remove its directory fails loudly, not silently"
# The harmon-init#899 signature: the suite printed its success line and still
# exited 1, because the trap's bare `rm -rf` failed under set -e with nothing
# but rm's raw stderr to explain it. The hardened teardown must NAME the
# failure instead — that naming, not the retry, is the contract this case
# pins. Root can delete a mode-000 directory, so the simulation is
# impossible there.
if [ "$(id -u)" -ne 0 ]; then
    teardown_log="$test_tmp/teardown.log"
    teardown_probe="$(mktemp -d -t harmon-init-worktree-teardown-XXXXXX)"
    mkdir -p "$teardown_probe/held"
    printf 'survivor\n' >"$teardown_probe/held/file"
    chmod 000 "$teardown_probe/held"
    if (
        test_tmp="$teardown_probe"
        WORKTREE_TIMEOUT_SENTINEL="$(mktemp -t harmon-init-worktree-tdsentinel-XXXXXX)"
        rm -f "$WORKTREE_TIMEOUT_SENTINEL"
        worktree_exit
    ) >"$teardown_log" 2>&1; then
        chmod 755 "$teardown_probe/held" 2>/dev/null || true
        rm -rf "$teardown_probe"
        fail "worktree_exit reported success although its teardown could not remove the directory"
    fi
    chmod 755 "$teardown_probe/held" 2>/dev/null || true
    rm -rf "$teardown_probe"
    grep -q 'teardown could not remove' "$teardown_log" ||
        fail "a failing teardown did not name itself — the harmon-init#899 silent-teardown signature is back: $(cat "$teardown_log")"
else
    echo "    (skipped: running as root, a permission-held teardown cannot be simulated)"
fi

# ── Target resolution: the name must account for something (#963) ───────────
#
# Every fixture worktree above is created through worktree:new, which always
# lands under .worktrees/ — so the constructed path <main_root>/.worktrees/<name>
# is satisfied by construction and no existing case can see a name that does
# not resolve there. These three build the shapes deliberately. Each asserts
# BOTH halves: a nonzero exit, and that the target actually survived — a
# refusal that still deleted something would pass an exit-code-only check.

# A worktree registered to this repo but living outside .worktrees/, which
# `git worktree add` permits and `git worktree list` reports. worktree:rm
# cannot reach it, and must say so rather than claim a removal.
outside_root="$test_tmp/outside-cone"
git -C "$fixture" worktree add -q "$outside_root/parked" -b feat/parked-outside ||
    fail "could not create a worktree outside .worktrees/ for the #963 case"
rm_out="$test_tmp/rm-outside.log"
if rm_wt parked >"$rm_out" 2>&1; then
    fail "worktree:rm reported success for a worktree outside .worktrees/ (#963): $(cat "$rm_out")"
fi
# Anchored on the LOCATION clause, not on the path alone: the real path also
# appears in the `git worktree remove` remedy, so a bare substring match stays
# green even when the clause names the constructed path instead (mutant N3).
grep -q "names the worktree at $outside_root/parked" "$rm_out" ||
    fail "the refusal did not name where the worktree actually is (#963): $(cat "$rm_out")"
grep -q "names the worktree at $fixture/.worktrees/parked" "$rm_out" &&
    fail "the refusal located the worktree at the constructed path, which does not exist (#963): $(cat "$rm_out")"
# The refusal must NOT hand over `git worktree remove`: that command applies
# none of this script's guards — it deletes ignored files such as .env and
# takes an unreferenced detached HEAD without complaint — so advertising it
# walks the operator past the protections this task exists to provide
# (review r4). It must instead say what would go unchecked.
grep -qE 'remove it with: git worktree remove|instead: git worktree remove' "$rm_out" &&
    fail "the refusal advertised an unguarded removal command (#963): $(cat "$rm_out")"
grep -q 'skip-worktree' "$rm_out" ||
    fail "the refusal did not name the guards a raw removal would skip (#963): $(cat "$rm_out")"
grep -qi 'removed:' "$rm_out" &&
    fail "the refusal still printed a removal line (#963): $(cat "$rm_out")"
[ -d "$outside_root/parked" ] ||
    fail "worktree:rm deleted a worktree it had refused to remove (#963)"
git -C "$fixture" worktree list --porcelain | grep -qxF "worktree $outside_root/parked" ||
    fail "worktree:rm dropped the registry record of a worktree it refused (#963)"
git -C "$fixture" worktree remove --force "$outside_root/parked"

# A moved worktree: git names the admin record from the path basename at
# creation and NEVER renames it, while `git worktree move` rewrites the
# record's stored path — so record name and directory name diverge by design.
# Asking by the record name must not read as a stale record.
# --no-install: this fixture only needs to EXIST and then move. A real
# dependency install leaves the tree dirty, and worktree:rm then refuses it
# on uncommitted changes — correct behaviour, wrong fixture for this case.
new movedrec --no-install >/dev/null || fail "could not create the #963 move fixture"
git -C "$fixture" worktree move .worktrees/movedrec .worktrees/movednew ||
    fail "could not move the #963 fixture worktree"
rm_moved="$test_tmp/rm-moved.log"
if rm_wt movedrec >"$rm_moved" 2>&1; then
    fail "worktree:rm reported success for a record name whose directory moved (#963): $(cat "$rm_moved")"
fi
grep -q "names the worktree at $fixture/.worktrees/movednew" "$rm_moved" ||
    fail "the refusal did not name the moved worktree's current directory (#963): $(cat "$rm_moved")"
grep -q 'no worktree or admin record named' "$rm_moved" &&
    fail "the record name resolved to nothing — resolution no longer matches admin-record names (#963): $(cat "$rm_moved")"
[ -d "$fixture/.worktrees/movednew" ] ||
    fail "worktree:rm deleted a moved worktree it had refused to remove (#963)"
# ...and the directory name, which is what actually resolves, still works.
rm_movednew="$test_tmp/rm-movednew.log"
rm_wt movednew >"$rm_movednew" 2>&1 ||
    fail "worktree:rm could not remove a moved worktree by its directory name (#963): $(cat "$rm_movednew")"
[ -d "$fixture/.worktrees/movednew" ] &&
    fail "worktree:rm reported success but left the moved worktree behind (#963)"

# A name matching neither a worktree nor an admin record: the original report.
rm_none="$test_tmp/rm-nomatch.log"
if rm_wt definitely-no-such-worktree >"$rm_none" 2>&1; then
    fail "worktree:rm exited 0 for a name matching nothing (#963): $(cat "$rm_none")"
fi
grep -qi 'removed:' "$rm_none" &&
    fail "worktree:rm claimed a removal for a name matching nothing (#963): $(cat "$rm_none")"
grep -q 'no worktree or admin record named' "$rm_none" ||
    fail "the no-match refusal did not say what was wrong (#963): $(cat "$rm_none")"

# The main checkout is registered but is not a linked worktree, so resolution
# must skip it — otherwise `worktree:rm <repo-basename>` reports the main
# checkout as an out-of-cone worktree and recommends a `git worktree remove`
# that git refuses outright (challenge r1).
main_base="${fixture##*/}"
rm_mainbase="$test_tmp/rm-mainbase.log"
if rm_wt "$main_base" >"$rm_mainbase" 2>&1; then
    fail "worktree:rm accepted the main checkout's own basename (#963): $(cat "$rm_mainbase")"
fi
grep -q "names the worktree at $fixture " "$rm_mainbase" &&
    fail "worktree:rm resolved the main checkout as a removable worktree (#963): $(cat "$rm_mainbase")"
grep -q "no worktree or admin record named" "$rm_mainbase" ||
    fail "the main checkout's basename did not fall through to the no-match branch (#963): $(cat "$rm_mainbase")"
grep -q 'git worktree remove' "$rm_mainbase" &&
    fail "worktree:rm recommended removing the main checkout, which git refuses (#963): $(cat "$rm_mainbase")"

# ...and skipping it must not blind resolution to a LINKED worktree that
# happens to share the main checkout's basename.
samebase_root="$test_tmp/samebase"
git -C "$fixture" worktree add -q "$samebase_root/$main_base" -b feat/samebase ||
    fail "could not create the same-basename worktree for the #963 case"
rm_samebase="$test_tmp/rm-samebase.log"
if rm_wt "$main_base" >"$rm_samebase" 2>&1; then
    fail "worktree:rm reported success for a same-basename linked worktree (#963): $(cat "$rm_samebase")"
fi
grep -q "names the worktree at $samebase_root/$main_base" "$rm_samebase" ||
    fail "resolution missed a linked worktree sharing the main checkout's basename (#963): $(cat "$rm_samebase")"
git -C "$fixture" worktree remove --force "$samebase_root/$main_base"

# A worktree path may legally contain a newline. Line-parsed porcelain output
# truncates it, which both hides the real worktree and invents a candidate at
# the truncated prefix — so asking for that prefix must NOT resolve to it
# (challenge r1).
nl_parent="$test_tmp/nl-cone"
mkdir -p "$nl_parent"
nl_tree="$nl_parent/trunc
tail"
# Probe the FILESYSTEM's capability directly. Treating any `git worktree add`
# failure as "newlines unsupported" would swallow a broken hook, a branch
# collision, or a git regression and silently drop this coverage while the
# suite still reported a pass (challenge r2).
nl_probe="$nl_parent/probe
newline"
if mkdir -p "$nl_probe" 2>/dev/null && [ -d "$nl_probe" ]; then
    rmdir "$nl_probe" 2>/dev/null || true
    nl_supported=1
else
    nl_supported=0
fi
# `--porcelain -z` (git 2.36+) is what makes a newline-bearing path
# representable at all. Without it the command fails closed by design, so these
# cases assert behaviour that git cannot deliver — gate on the capability, not
# only on the filesystem (review r4).
if git worktree list --porcelain -z >/dev/null 2>&1; then
    nl_z_supported=1
else
    nl_z_supported=0
fi
if [ "$nl_supported" -eq 0 ]; then
    echo "    (skipped: this filesystem rejects a newline in a path)"
elif [ "$nl_z_supported" -eq 0 ]; then
    echo "    (skipped: this git has no 'worktree list --porcelain -z'; the command fails closed instead)"
elif git -C "$fixture" worktree add -q "$nl_tree" -b feat/newline-path; then
    rm_trunc="$test_tmp/rm-trunc.log"
    if rm_wt trunc >"$rm_trunc" 2>&1; then
        fail "worktree:rm resolved a truncated newline path as a real worktree (#963): $(cat "$rm_trunc")"
    fi
    # With the path read whole, "trunc" is nobody's basename, so the no-match
    # branch must run. Line-parsing instead invents a candidate at the
    # truncated prefix and resolves to it — a different branch entirely.
    # Asserting the branch is robust; grepping a path out of a sentence that
    # itself contains a newline is not.
    grep -q "no worktree or admin record named 'trunc'" "$rm_trunc" ||
        fail "the truncated prefix of a newline path resolved as a real worktree (#963): $(cat "$rm_trunc")"
    git -C "$fixture" worktree remove --force "$nl_tree"
else
    fail "could not create a newline-bearing worktree although the filesystem accepts newline paths (#963)"
fi

# Two worktrees sharing a basename make the name ambiguous. The refusal must
# name the ones that actually collided — printing the whole registry hides
# which two are in conflict and points at unrelated paths (challenge r2).
amb_root="$test_tmp/amb"
git -C "$fixture" worktree add -q "$amb_root/a/twin" -b feat/twin-a ||
    fail "could not create the first #963 ambiguity worktree"
git -C "$fixture" worktree add -q "$amb_root/b/twin" -b feat/twin-b ||
    fail "could not create the second #963 ambiguity worktree"
git -C "$fixture" worktree add -q "$amb_root/unrelated/bystander" -b feat/bystander ||
    fail "could not create the #963 ambiguity bystander"
rm_amb="$test_tmp/rm-ambiguous.log"
if rm_wt twin >"$rm_amb" 2>&1; then
    fail "worktree:rm reported success for an ambiguous name (#963): $(cat "$rm_amb")"
fi
grep -q 'is ambiguous' "$rm_amb" ||
    fail "an ambiguous name did not report ambiguity (#963): $(cat "$rm_amb")"
grep -q "$amb_root/a/twin" "$rm_amb" && grep -q "$amb_root/b/twin" "$rm_amb" ||
    fail "the ambiguity refusal did not name both colliding worktrees (#963): $(cat "$rm_amb")"
grep -q 'bystander' "$rm_amb" &&
    fail "the ambiguity refusal listed an unrelated worktree as a collision (#963): $(cat "$rm_amb")"
git -C "$fixture" worktree remove --force "$amb_root/a/twin"
git -C "$fixture" worktree remove --force "$amb_root/b/twin"
git -C "$fixture" worktree remove --force "$amb_root/unrelated/bystander"

# An in-cone worktree whose relative path is not a name this command accepts:
# the remedy must be git's own command, shell-escaped. Emitting
# `task worktree:rm -- team space/leaf` would split on the space and be
# rejected by the charset guard anyway (challenge r2).
mkdir -p "$fixture/.worktrees/team space"
git -C "$fixture" worktree add -q ".worktrees/team space/leaf" -b feat/spaced-cone ||
    fail "could not create the #963 unaddressable in-cone worktree"
rm_unaddr="$test_tmp/rm-unaddressable.log"
if rm_wt leaf >"$rm_unaddr" 2>&1; then
    fail "worktree:rm reported success for an unaddressable in-cone path (#963): $(cat "$rm_unaddr")"
fi
grep -q 'git worktree remove' "$rm_unaddr" ||
    fail "the refusal did not fall back to git's own command for an unaddressable path (#963): $(cat "$rm_unaddr")"
grep -q 'task worktree:rm --' "$rm_unaddr" &&
    fail "the refusal suggested a task invocation that cannot parse (#963): $(cat "$rm_unaddr")"

# The candidate listing's first column must be a name this command actually
# takes. For a NESTED in-cone worktree that is the relative path, not the
# basename: .worktrees/feat/deep is addressed as feat/deep, and advertising
# "deep" sends the operator through an extra refusal to discover that.
new nestedlist --no-install >/dev/null ||
    fail "could not create the #963 nested-listing fixture"
# `git worktree move` does not create the destination's parent.
mkdir -p "$fixture/.worktrees/feat"
git -C "$fixture" worktree move .worktrees/nestedlist ".worktrees/feat/deep" ||
    fail "could not nest the #963 listing fixture"
rm_list="$test_tmp/rm-listing.log"
rm_wt definitely-absent-name >"$rm_list" 2>&1 || true
grep -qE '^  feat/deep( |$)' "$rm_list" ||
    fail "the listing did not offer the nested worktree's usable name (#963): $(cat "$rm_list")"
# ...and an unaddressable path must not be advertised as if it were a name.
grep -qE '^  \(not removable here\)' "$rm_list" ||
    fail "the listing did not mark the unaddressable in-cone path as not removable (#963): $(cat "$rm_list")"
grep -q 'git worktree remove' "$rm_list" &&
    fail "the listing re-offered the unguarded command the refusal withholds (#963): $(cat "$rm_list")"
# ...and specifically for an OUT-OF-CONE worktree, which the in-cone-with-space
# case above cannot prove: classifying every path as in-cone would advertise an
# absolute path as though it were a name this command takes.
outcone_list="$test_tmp/outcone-list"
git -C "$fixture" worktree add -q "$outcone_list/stray" -b feat/outcone-listing ||
    fail "could not create the #963 out-of-cone listing fixture"
rm_list2="$test_tmp/rm-listing-outcone.log"
rm_wt definitely-absent-name >"$rm_list2" 2>&1 || true
grep -qE "^  \(not removable here\)  .*$outcone_list/stray" "$rm_list2" ||
    fail "the listing advertised an out-of-cone worktree under a name this command cannot take (#963): $(cat "$rm_list2")"
git -C "$fixture" worktree remove --force "$outcone_list/stray"
git -C "$fixture" worktree remove --force ".worktrees/feat/deep"
git -C "$fixture" worktree remove --force ".worktrees/team space/leaf"

# A remedy this command would itself reject is worse than no remedy. The
# nameability test must apply EVERY rule the argument check applies — it
# originally applied only the charset and component rules, so an in-cone path
# beginning with `-` or containing `..` was advertised as
# `task worktree:rm -- …` and then refused by the parser it was handed to
# (review r1). Both shapes are checked, because they fail different rules.
for bad_component in '-dash' 'a..b'; do
    new "remedycheck" --no-install >/dev/null ||
        fail "could not create the #963 remedy fixture for '$bad_component'"
    mkdir -p "$fixture/.worktrees/$bad_component"
    git -C "$fixture" worktree move .worktrees/remedycheck ".worktrees/$bad_component/leaf" ||
        fail "could not move the #963 remedy fixture into '$bad_component'"
    rm_remedy="$test_tmp/rm-remedy.log"
    if rm_wt remedycheck >"$rm_remedy" 2>&1; then
        fail "worktree:rm reported success for a path under '$bad_component' (#963): $(cat "$rm_remedy")"
    fi
    grep -q 'task worktree:rm --' "$rm_remedy" &&
        fail "the remedy advertised a task invocation this command rejects, for '$bad_component' (#963): $(cat "$rm_remedy")"
    grep -qE 'remove it with: git worktree remove' "$rm_remedy" &&
        fail "the remedy advertised an unguarded removal for '$bad_component' (#963): $(cat "$rm_remedy")"
    # The LISTING must reach the same verdict about the same path, and it must
    # be checked while this worktree still exists. Both components pass the
    # charset rule and fail a different one, so a listing that applied only the
    # charset rule would advertise them as names — the drift the shared
    # predicate exists to prevent.
    rm_remedy_list="$test_tmp/rm-remedy-list.log"
    rm_wt definitely-absent-name >"$rm_remedy_list" 2>&1 || true
    grep -qE "^  \(not removable here\)  .*$bad_component/leaf" "$rm_remedy_list" ||
        fail "the listing advertised '$bad_component/leaf' under a name this command rejects (#963): $(cat "$rm_remedy_list")"
    git -C "$fixture" worktree remove --force ".worktrees/$bad_component/leaf"
    rmdir "$fixture/.worktrees/$bad_component" 2>/dev/null || true
done

# The argument check must keep naming the SPECIFIC rule that failed — routing
# both callers through one predicate must not flatten the diagnostics.
rm_badname="$test_tmp/rm-badname.log"
rm_wt '../escape' >"$rm_badname" 2>&1 && fail "worktree:rm accepted '../escape' (#963)"
grep -q "must not contain '\.\.'" "$rm_badname" ||
    fail "the argument check stopped naming which rule failed (#963): $(cat "$rm_badname")"

# The THIRD outcome the issue requires the message to distinguish: a registry
# record whose directory is already gone. Clearing it is correct and useful,
# but "Worktree removed" claims a directory was deleted that never existed,
# directly contradicting the line printed just above it (review r2).
new stalemsg --no-install >/dev/null || fail "could not create the #963 stale-record fixture"
rm -rf "$fixture/.worktrees/stalemsg"
rm_stale="$test_tmp/rm-stalemsg.log"
rm_wt stalemsg >"$rm_stale" 2>&1 ||
    fail "worktree:rm failed to clear a stale record (#963): $(cat "$rm_stale")"
grep -q 'Stale record cleared' "$rm_stale" ||
    fail "clearing a stale record did not say so (#963): $(cat "$rm_stale")"
grep -q '^Worktree removed:' "$rm_stale" &&
    fail "clearing a stale record still claimed a directory was removed (#963): $(cat "$rm_stale")"

# ...and a genuine removal must still say it removed a worktree, so the fix
# above cannot be satisfied by simply never printing the removal line.
new realmsg --no-install >/dev/null || fail "could not create the #963 real-removal fixture"
rm_real="$test_tmp/rm-realmsg.log"
rm_wt realmsg >"$rm_real" 2>&1 ||
    fail "worktree:rm failed to remove a live worktree (#963): $(cat "$rm_real")"
grep -q '^Worktree removed:' "$rm_real" ||
    fail "a genuine removal stopped reporting itself as one (#963): $(cat "$rm_real")"
grep -q 'Stale record cleared' "$rm_real" &&
    fail "a genuine removal was reported as a stale-record cleanup (#963): $(cat "$rm_real")"

# git SANITIZES an admin-record name — a worktree at `trunc<LF>tail` gets the
# record `trunc-tail` — so that record name is typeable and resolves to a path
# carrying a raw newline. Every diagnostic must escape the path it prints, not
# only the remedy: an unescaped location clause splits the message across lines
# (review r3).
if [ "$nl_supported" -eq 1 ] && [ "$nl_z_supported" -eq 1 ]; then
    esc_parent="$test_tmp/escpath"
    mkdir -p "$esc_parent"
    esc_tree="$esc_parent/trunc
tail"
    if git -C "$fixture" worktree add -q "$esc_tree" -b feat/escaped-diagnostic; then
        esc_record="$(basename "$(record_admin_dir_probe "$fixture" "$esc_tree")")"
        [ -n "$esc_record" ] || fail "could not read the admin record for the #963 escaping case"
        rm_esc="$test_tmp/rm-escaped.log"
        rm_wt "$esc_record" >"$rm_esc" 2>&1 &&
            fail "worktree:rm reported success for an out-of-cone newline path (#963): $(cat "$rm_esc")"
        [ "$(wc -l <"$rm_esc" | tr -d ' ')" -eq 1 ] ||
            fail "the diagnostic split across lines on a newline-bearing path (#963): $(cat "$rm_esc")"
        git -C "$fixture" worktree remove --force "$esc_tree"
    else
        fail "could not create the #963 escaping fixture although newlines are supported"
    fi
fi

# The pre-2.36 path is unreachable on a modern git, so it is simulated: a shim
# makes `worktree list --porcelain -z` fail and passes everything else through
# to the real binary. Without this the fail-closed branch is only exercisable
# by installing an old git, which means in practice never (review r4).
if [ "$nl_supported" -eq 1 ]; then
    oldgit_shim="$test_tmp/oldgit-shim"
    mkdir -p "$oldgit_shim"
    real_git="$(command -v git)"
    cat >"$oldgit_shim/git" <<SHIM
#!/usr/bin/env bash
# Reject only the worktree-list capability probe; else the real git.
if [ "\$1" = "worktree" ] && [ "\$2" = "list" ]; then
    for arg in "\$@"; do
        [ "\$arg" = "-z" ] && exit 129
    done
fi
exec "$real_git" "\$@"
SHIM
    chmod +x "$oldgit_shim/git"
    # Prove the shim actually simulates the old git before relying on it — a
    # shim that silently passed -z through would make this case vacuous.
    PATH="$oldgit_shim:$PATH" git worktree list --porcelain -z >/dev/null 2>&1 &&
        fail "the pre-2.36 git shim did not reject --porcelain -z (#963)"
    PATH="$oldgit_shim:$PATH" git worktree list --porcelain >/dev/null 2>&1 ||
        fail "the pre-2.36 git shim broke ordinary git invocations (#963)"

    oldgit_parent="$test_tmp/oldgit-cone"
    mkdir -p "$oldgit_parent"
    oldgit_tree="$oldgit_parent/span
ning"
    if git -C "$fixture" worktree add -q "$oldgit_tree" -b feat/oldgit-span; then
        rm_oldgit="$test_tmp/rm-oldgit.log"
        (cd "$fixture" && PATH="$oldgit_shim:$PATH" bash scripts/worktree-rm.sh spanning) \
            >"$rm_oldgit" 2>&1 &&
            fail "worktree:rm resolved a spanning path on a git without -z (#963): $(cat "$rm_oldgit")"
        grep -q 'cannot look up' "$rm_oldgit" ||
            fail "the pre-2.36 path did not refuse registry lookup (#963): $(cat "$rm_oldgit")"
        grep -qi 'removed' "$rm_oldgit" &&
            fail "the pre-2.36 refusal still claimed a removal (#963): $(cat "$rm_oldgit")"
        git -C "$fixture" worktree remove --force "$oldgit_tree"
    else
        fail "could not create the #963 pre-2.36 fixture although newlines are supported"
    fi
    rm -rf "$oldgit_shim"
fi

# A registry read that fails or truncates must not read as a complete one.
# bash does not propagate a process-substitution failure, so without a success
# sentinel the resolver would treat a partial list as the whole registry and
# could call a name unique, or absent, on evidence it never finished reading
# (review r6). Simulated with a shim that exits nonzero for the enumeration.
trunc_shim="$test_tmp/trunc-shim"
mkdir -p "$trunc_shim"
trunc_real_git="$(command -v git)"
cat >"$trunc_shim/git" <<TRUNCSHIM
#!/usr/bin/env bash
# The capability probe and the real enumeration are the SAME invocation, so
# they cannot be told apart by arguments — count instead. The first armed
# -z call (the probe) succeeds so the command clears its version gate; the
# next one (the enumeration it actually reads) fails.
if [ "\$1" = "worktree" ] && [ "\$2" = "list" ]; then
    for arg in "\$@"; do
        if [ "\$arg" = "-z" ] && [ -n "\$WT_TRUNC_ARMED" ]; then
            if [ -e "\$WT_TRUNC_ARMED" ]; then
                exit 1
            fi
            : >"\$WT_TRUNC_ARMED"
            exec "$trunc_real_git" "\$@"
        fi
    done
fi
exec "$trunc_real_git" "\$@"
TRUNCSHIM
chmod +x "$trunc_shim/git"
# Prove the shim behaves as described before relying on it.
trunc_marker="$test_tmp/trunc-marker"
rm -f "$trunc_marker"
PATH="$trunc_shim:$PATH" git worktree list --porcelain -z >/dev/null 2>&1 ||
    fail "the truncation shim broke the unarmed enumeration (#963)"
PATH="$trunc_shim:$PATH" WT_TRUNC_ARMED="$trunc_marker" git worktree list --porcelain -z >/dev/null 2>&1 ||
    fail "the truncation shim failed the FIRST armed call, which must succeed as the capability probe (#963)"
PATH="$trunc_shim:$PATH" WT_TRUNC_ARMED="$trunc_marker" git worktree list --porcelain -z >/dev/null 2>&1 &&
    fail "the truncation shim did not fail the SECOND armed call (#963)"
rm -f "$trunc_marker"

new truncprobe --no-install >/dev/null || fail "could not create the #963 truncation fixture"
rm -rf "$fixture/.worktrees/truncprobe"
git -C "$fixture" worktree prune
rm_trunc_log="$test_tmp/rm-truncated.log"
(cd "$fixture" && PATH="$trunc_shim:$PATH" WT_TRUNC_ARMED="$trunc_marker" bash scripts/worktree-rm.sh some-absent-name) \
    >"$rm_trunc_log" 2>&1 &&
    fail "worktree:rm succeeded on a registry read that failed (#963): $(cat "$rm_trunc_log")"
grep -q 'could not read the worktree registry completely' "$rm_trunc_log" ||
    fail "a failed registry read did not fail closed (#963): $(cat "$rm_trunc_log")"
grep -qi 'removed' "$rm_trunc_log" &&
    fail "a failed registry read still claimed a removal (#963): $(cat "$rm_trunc_log")"
rm -rf "$trunc_shim"

echo "    worktree:rm target resolution: outside-cone, moved-record, and no-match all refuse without claiming a removal (#963)"

echo "worktree entrypoint OK: create → hooks verified → deps installed → removed"
