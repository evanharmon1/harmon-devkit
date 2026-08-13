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
set -euo pipefail

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
worktree_exit() {
    exit_status=$?
    if [ -e "$WORKTREE_TIMEOUT_SENTINEL" ]; then
        # Print what the sentinel HOLDS, not where it lives: it is removed
        # immediately below, so a path would point at nothing by the time
        # anyone read the message.
        echo "TEST FAIL: $(cat "$WORKTREE_TIMEOUT_SENTINEL") — the operation was killed, not merely slow (harmon-init#792)" >&2
        rm -f "$WORKTREE_TIMEOUT_SENTINEL"
        rm -rf "$test_tmp"
        exit 1
    fi
    rm -f "$WORKTREE_TIMEOUT_SENTINEL"
    rm -rf "$test_tmp"
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
cp "$repo/scripts/worktree-new.sh" "$repo/scripts/worktree-rm.sh" "$fixture/scripts/"
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

echo "==> a branch pushed after the last fetch is refreshed before creation"
git -C "$fixture" update-ref -d refs/remotes/origin/late-remote
git -C "$fixture" push -q origin HEAD:refs/heads/late-remote
new late-remote >/dev/null || fail "worktree-new.sh failed for a stale-fetch remote branch"
[ "$(git -C "$fixture/.worktrees/late-remote" rev-parse HEAD)" = \
    "$(git -C "$fixture" ls-remote origin refs/heads/late-remote | awk '{print $1}')" ] ||
    fail "worktree-new.sh created a divergent branch instead of refreshing the remote"
rm_wt late-remote >/dev/null || fail "cleanup of the stale-fetch remote branch failed"
git -C "$fixture" branch -D late-remote >/dev/null 2>&1 || true

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

echo "==> a dot-segment name cannot smuggle a worktree inside another"
new dotparent >/dev/null || fail "worktree-new.sh failed creating the dot-parent tree"
if new ./dotparent/child --branch dotchild >/dev/null 2>&1; then
    fail "worktree-new.sh nested a worktree via a './' path component"
fi
refute_exists "$fixture/.worktrees/dotparent/child" "the smuggled nested worktree was created"
rm_wt dotparent >/dev/null || fail "cleanup of the dot-parent tree failed"
refute_exists "$test_tmp/evil" "worktree-new.sh escaped the fixture directory"

# ── per-tree dependency install ──────────────────────────────────────
echo "==> a Node repo gets its dependencies installed in the NEW tree"
pnpm_marker="$test_tmp/pnpm-invoked"
cat >"$stub_bin/pnpm" <<EOF
#!/usr/bin/env bash
printf '%s %s\n' "\$*" "\$PWD" >>"$pnpm_marker"
exit 0
EOF
chmod +x "$stub_bin/pnpm"
printf '{"name":"fixture","private":true}\n' >"$fixture/package.json"
git -C "$fixture" add -A
git -C "$fixture" commit -qm "chore: add package.json" >"$test_tmp/commit.log" 2>&1 ||
    {
        cat "$test_tmp/commit.log" >&2
        fail "committing package.json in the fixture failed"
    }
new node-tree >/dev/null || fail "worktree-new.sh failed on a Node repo"
grep -qx "install $fixture/.worktrees/node-tree" "$pnpm_marker" 2>/dev/null ||
    fail "worktree-new.sh did not run 'pnpm install' inside the new tree"
rm_wt node-tree >/dev/null || fail "cleanup of the node tree failed"

echo "==> a pnpm workspace without a root package.json still installs"
: >"$pnpm_marker"
git -C "$fixture" rm -q --cached package.json >/dev/null
rm -f "$fixture/package.json"
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
# The ordered-tree case changed the fixture's tracked hook configuration as
# well as its generated hook. Reset both halves before the next case, or
# worktree:new sees post-checkout as configured and can reinstall/invoke the
# hook that this cleanup meant to retire (harmon-init#802).
cat >"$fixture/lefthook.yml" <<'EOF'
pre-commit:
  commands:
    noop:
      run: "true"
EOF
git -C "$fixture" add lefthook.yml
LEFTHOOK=0 git -C "$fixture" commit -qm "chore: reset post-checkout fixture" \
    >"$test_tmp/commit.log" 2>&1 || fail "resetting the post-checkout fixture failed"

echo "==> --no-install skips the dependency install"
: >"$pnpm_marker"
new no-install-tree --no-install >/dev/null || fail "worktree-new.sh --no-install failed"
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
exit_trap="$(trap -p EXIT)"
printf '%s\n' "$exit_trap" | grep -q 'worktree_exit' ||
    fail "the EXIT trap is no longer wired to worktree_exit"
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

echo "worktree entrypoint OK: create → hooks verified → deps installed → removed"
