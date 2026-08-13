#!/usr/bin/env bash
# worktree-new.sh — create a ready-to-work linked git worktree under .worktrees/.
#
# Run via `task worktree:new -- <name> [options]`.
#
# One blessed entrypoint so every consumer — a parallel Claude session, Foreman,
# herdr, agent-deck, workmux, or a human — gets the same tree: checked out,
# dependencies installed for THIS tree, and git hooks proven to fire in it.
# Without it each tool rediscovers the same setup steps and the same breakers
# (a fresh worktree has no node_modules; `-c core.hooksPath=.git/hooks` silently
# resolves to nothing because `.git` is a FILE in a linked worktree).
#
# Options:
#   --branch <name>   branch to create/attach (default: the worktree name)
#   --base <ref>      base for a NEW branch (default: HEAD)
#   --no-install      skip the per-tree dependency install
#
# Exits non-zero with the fix in the message when a precondition is missing, and
# rolls back a half-provisioned tree rather than leaving debris behind.
set -euo pipefail

usage() {
    cat >&2 <<'EOF'
Usage: task worktree:new -- <name> [--branch <branch>] [--base <ref>] [--no-install]

Creates .worktrees/<name> as a linked git worktree, installs this tree's
dependencies, verifies git hooks fire inside it, and prints the ready path.
EOF
}

die() {
    echo "worktree:new: $*" >&2
    exit 1
}

name=""
branch=""
base=""
do_install=1

while [ "$#" -gt 0 ]; do
    case "$1" in
    --branch)
        [ "$#" -ge 2 ] || die "--branch needs a value"
        branch="$2"
        shift 2
        ;;
    --base)
        [ "$#" -ge 2 ] || die "--base needs a value"
        base="$2"
        shift 2
        ;;
    --no-install)
        do_install=0
        shift
        ;;
    -h | --help)
        usage
        exit 0
        ;;
    -*)
        usage
        die "unknown option: $1"
        ;;
    *)
        [ -z "$name" ] || die "unexpected extra argument: $1"
        name="$1"
        shift
        ;;
    esac
done

if [ -z "$name" ]; then
    usage
    die "a worktree name is required"
fi

# The name becomes a path segment under .worktrees/ — keep it to characters that
# are safe in both a path and a branch name, and refuse anything that could
# escape the directory.
case "$name" in
/* | -*) die "invalid name '$name': must not start with '/' or '-'" ;;
*..*) die "invalid name '$name': must not contain '..'" ;;
esac
case "$name" in
*[!A-Za-z0-9._/-]*) die "invalid name '$name': use only A-Z a-z 0-9 . _ - /" ;;
esac
# Reject `.` and empty path components. They are harmless to the filesystem but
# poisonous to the ancestry check below, which compares the candidate path
# against git's CANONICAL registry paths as text: `./parent/child` yields
# `.worktrees/./parent`, which never string-matches the registered
# `.worktrees/parent`, so the nesting guard would wave through exactly the
# layout it exists to prevent — and a later `worktree:rm parent --force` would
# take the child's uncommitted work with it.
case "/$name/" in
*//* | */./*) die "invalid name '$name': path components must not be empty or '.'" ;;
esac

git rev-parse --git-dir >/dev/null 2>&1 || die "not inside a git repository"

[ -n "$branch" ] || branch="$name"

# Anchor .worktrees/ to the MAIN worktree, never to whichever linked tree the
# caller happens to be standing in — otherwise running this from inside a
# worktree nests .worktrees/a/.worktrees/b and every tool's assumption about
# where trees live stops holding. The first `git worktree list --porcelain`
# record is always the main worktree.
main_root="$(git worktree list --porcelain | awk '/^worktree /{print substr($0, 10); exit}')"
[ -n "$main_root" ] && [ -d "$main_root" ] || die "could not resolve the main worktree root"

# The default base is the MAIN worktree's HEAD, not the caller's. Running this
# from inside a feature worktree is supported, and a bare `HEAD` there would
# stack the new branch on the caller's commits — the new tree would look
# independent while carrying unrelated work into its PR. Pass `--base HEAD` to
# stack deliberately, or `--base <ref>` for anything else.
#
# It stays HEAD-of-main rather than a guessed default branch: `main` is not
# universal, `origin/HEAD` is often unset on a fresh clone, and inferring one
# would silently branch from somewhere the caller never named. What that leaves
# — a main checkout parked on someone else's branch — is answered by printing
# the resolved base below rather than by guessing.
base_origin="explicit"
if [ -z "$base" ]; then
    base_origin="the main worktree's HEAD"
    base_label="$(git -C "$main_root" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)"
    base="$(git -C "$main_root" rev-parse --verify --quiet HEAD || true)"
    [ -n "$base" ] ||
        die "the main worktree has no commits yet — make an initial commit, or pass --base <ref>"
    echo "==> Base: ${base_origin} (${base_label} @ $(git rev-parse --short "$base")) — pass --base <ref> to branch elsewhere"
fi

# Validated here, before anything is created, so a bad --base fails without a
# rollback message about a tree that never existed.
git rev-parse --verify --quiet "$base^{commit}" >/dev/null ||
    die "base ref '$base' does not resolve to a commit"

tree="$main_root/.worktrees/$name"

# Refuse to nest a worktree INSIDE another registered worktree. Git's own
# guard is on branch names (it will not let `parent/child` coexist with
# `parent`), so a differing --branch slips straight past it and the new tree
# lands inside the old one. That is a data-loss path, not just untidy: the
# parent then reads as dirty, and removing it with --force takes the child's
# uncommitted work with it.
registered="$(git worktree list --porcelain | awk '/^worktree /{print substr($0, 10)}')"

# Snapshot whether this path is ALREADY registered, before anything this run
# does. Rollback's ownership test below compares against it, so a record that
# predates this invocation can never be mistaken for one this run created.
tree_registered_before=0
case "
$registered
" in *"
$tree
"*) tree_registered_before=1 ;; esac

# A path that is ALREADY registered is not ours to provision, even when the
# directory is missing. Its `.git/worktrees/<name>` metadata can be the only
# thing holding an unreferenced detached HEAD, and the rollback below removes
# whatever worktree sits at this path — which for a pre-existing record means
# deleting somebody else's metadata on our way out. Refusing here is both safer
# and simpler than teaching rollback to tell the two apart, and it makes the
# rollback's `git worktree remove` unambiguously ours.
if [ "$tree_registered_before" -eq 1 ]; then
    die "$tree is already a registered worktree (its directory may be missing) — clear it with 'task worktree:rm -- $name' first"
fi

ancestor="$(dirname "$tree")"
while [ "$ancestor" != "$main_root/.worktrees" ] && [ "$ancestor" != "/" ]; do
    case "
$registered
" in *"
$ancestor
"*)
        die "$ancestor is already a worktree — '$name' would nest inside it; pick a name that is not under an existing worktree"
        ;;
    esac
    ancestor="$(dirname "$ancestor")"
done

# ...and the mirror image: a worktree registered BELOW the candidate path. A
# missing-but-registered `<name>/child` record does not stop `git worktree add`
# at `<name>`, and the result is a trap rather than a mess — `worktree:rm
# <name>` then correctly refuses because a descendant is registered, while the
# recovery it prescribes, `worktree:rm <name>/child`, cannot work either: that
# path is now an ordinary directory inside a live checkout with no gitlink of
# its own. Refusing at creation is what keeps the removal guard recoverable.
while IFS= read -r registered_tree; do
    case "$registered_tree" in
    "$tree"/*)
        die "$registered_tree is already a registered worktree inside '$name' — clear it first ('task worktree:rm -- ${registered_tree#"$main_root"/.worktrees/}'), then retry"
        ;;
    esac
done <<EOF
$registered
EOF

# Parents first: a branch-style name like `feat/foo` is explicitly allowed, and
# the leaf mkdir below is deliberately NOT recursive, so `.worktrees/feat` has
# to exist before it runs.
mkdir -p "$(dirname "$tree")"

# Claim the path with mkdir, which is atomic, rather than testing for it and
# then creating it. This entrypoint exists FOR parallel use, and a test-then-act
# check lets two concurrent runs of the same name both believe they own the
# path: whichever loses `git worktree add` would then roll back — force-removing
# the winner's registered tree and deleting its branch. Losing the mkdir means
# never arming the rollback at all.
#
# `git worktree add` accepts an existing EMPTY directory, so the reservation
# costs nothing.
if ! mkdir "$tree" 2>/dev/null; then
    if [ -d "$tree" ]; then
        die "$tree already exists (or another worktree:new is creating it) — remove it with 'task worktree:rm -- $name' first"
    fi
    die "could not create $tree"
fi

# Roll back on any failure from here on. A half-provisioned worktree is worse
# than none: the next run refuses because the path is taken, and the tool that
# called this one sees a directory that looks ready and is not.
#
# The flags are armed BEFORE `git worktree add`, not after it returns. That
# command is not atomic — a failing `post-checkout` hook makes it register the
# worktree and create the branch and still exit non-zero — so arming afterwards
# would skip cleanup in exactly the case that needs it. Cleanup is written to
# tolerate a tree or branch that was never created.
#
# tree_created starts at 1 because the reservation above already created the
# directory: every exit path from here owns it and must clean it up.
tree_created=1
branch_created=0
probe_dir=""
cleanup() {
    status=$?
    [ -n "$probe_dir" ] && rm -rf "$probe_dir"
    if [ "$status" -ne 0 ] && [ "$tree_created" -eq 1 ]; then
        echo "worktree:new: rolling back the half-provisioned tree $tree" >&2
        # Decide branch ownership FIRST, while the registry still holds the
        # record that answers it. A worktree registered at this path BY THIS RUN
        # is the unambiguous signal that `git worktree add -b` got far enough to
        # create the branch itself. The failure that must never delete anything
        # is `add` refusing because a concurrent run created the same branch —
        # and in that case this run registered nothing. Comparing the branch tip
        # against the base cannot separate the two: a concurrent creator working
        # from the same base produces an identical SHA.
        #
        # "By this run" is why the pre-add snapshot matters. A path can be
        # registered yet missing on disk (a stale record someone deleted around
        # git's back); the reservation still succeeds, `add` still fails, and a
        # bare "is it registered now?" would read that PRE-EXISTING record as
        # proof of ownership and delete a branch this run never made.
        # `tree_registered_before` is necessarily 0 here — creation refuses a
        # pre-existing record outright — so a record at this path now can only be
        # one this run made. It is still tested rather than assumed: the day that
        # refusal is relaxed, this stays correct instead of silently deleting a
        # stranger's branch.
        branch_is_ours=0
        if [ "$branch_created" -eq 1 ] && [ "$tree_registered_before" -eq 0 ] &&
            git worktree list --porcelain | grep -qxF "worktree $tree"; then
            branch_is_ours=1
        fi
        # `rmdir`, never `rm -rf`. What this run created is either a worktree
        # git can remove, or the EMPTY directory it reserved — and rmdir undoes
        # exactly the latter. A recursive delete here is a data-loss primitive
        # pointed at a path that another run may legitimately be occupying: with
        # `parent` and `parent/child` created concurrently, the child can land
        # inside the parent's reservation before the parent's `add` fails, and
        # `rm -rf` would then destroy a tree whose own command reported success.
        # Refusing to delete anything non-empty makes that impossible without a
        # lock; the leftover is reported and `worktree:rm` clears it.
        if ! git worktree remove --force "$tree" >/dev/null 2>&1; then
            rmdir "$tree" 2>/dev/null ||
                echo "worktree:new: left $tree in place — it is not empty and is not a registered worktree; inspect it, then 'task worktree:rm -- $name'" >&2
        fi
        # Deliberately NOT `git worktree prune`. Prune takes no path and is
        # repository-WIDE, so a failed create would also drop every OTHER stale
        # record — and such a record can be the only reference to a detached
        # commit, the very metadata this script refuses to provision over a few
        # lines up. The `git worktree remove --force "$tree"` above is already
        # the scoped form for the only record this run can have created, so a
        # prune has nothing left to do that is ours to do. A record surviving
        # both is reported, never swept.
        if git worktree list --porcelain | grep -qxF "worktree $tree"; then
            echo "worktree:new: $tree is still registered after rollback — clear it with 'task worktree:rm -- $name'" >&2
        fi
        if [ "$branch_is_ours" -eq 1 ]; then
            git branch -D "$branch" >/dev/null 2>&1 || true
        elif [ "$branch_created" -eq 1 ]; then
            echo "worktree:new: leaving branch '$branch' alone — this run did not create it" >&2
        fi
    fi
    exit "$status"
}
trap cleanup EXIT

# Attach to the branch when it already exists, create it otherwise. git itself
# refuses (loudly) when the branch is already checked out in another worktree,
# which is exactly the right failure.
#
# A branch that exists only on a remote counts as existing. After a fresh clone
# every branch but the default one is remote-only, so treating that as "new"
# would create a same-named local branch at the base commit and silently drop
# the remote branch's work — the push that follows diverges or is rejected.
# `git worktree add <path> <name>` does this DWIM itself; passing -b opts out of
# it, so the remote lookup has to be explicit.
#
# An EXPLICIT --base opts out of the lookup entirely: the caller named the start
# point, so there is nothing to guess, and refusing an ambiguous remote name
# would reject the very command that resolves the ambiguity. Git's own
# branch.autoSetupMerge still sets up tracking when that base is a
# remote-tracking ref.
#
# The remotes are ENUMERATED and each tracking ref tested exactly, rather than
# globbed as `refs/remotes/*/<branch>`: a remote name may itself contain a
# slash (`team/sub` is legal), and that pattern's `*` does not cross `/`, so a
# remote-only branch under such a remote would read as absent and be recreated
# at the base — the very silent-divergence this lookup exists to prevent.
remote_ref=""
if [ "$base_origin" != "explicit" ] && ! git show-ref --verify --quiet "refs/heads/$branch"; then
    remote_matches=""
    remote_count=0
    while IFS= read -r remote_name; do
        [ -n "$remote_name" ] || continue
        candidate="refs/remotes/$remote_name/$branch"
        if git show-ref --verify --quiet "$candidate"; then
            remote_matches="$candidate"
            remote_count=$((remote_count + 1))
        fi
    done <<EOF
$(git remote)
EOF
    if [ "$remote_count" -gt 1 ]; then
        die "branch '$branch' exists on more than one remote — pass --base <remote>/<branch> to choose one"
    fi
    [ "$remote_count" -eq 1 ] && remote_ref="$remote_matches"
fi

if git show-ref --verify --quiet "refs/heads/$branch"; then
    echo "==> Attaching existing branch '$branch'"
    LEFTHOOK=0 git worktree add "$tree" "$branch"
elif [ -n "$remote_ref" ]; then
    echo "==> Creating branch '$branch' tracking ${remote_ref#refs/remotes/}"
    branch_created=1
    LEFTHOOK=0 git worktree add "$tree" --track -b "$branch" "${remote_ref#refs/remotes/}"
else
    echo "==> Creating branch '$branch' from '$base'"
    branch_created=1
    LEFTHOOK=0 git worktree add "$tree" -b "$branch" "$base"
fi

have() { command -v "$1" >/dev/null 2>&1; }

# ── Per-tree dependency install ──────────────────────────────────────
# A linked worktree gets its own working files, so node_modules/.venv from the
# main checkout are NOT there. Detect what this repo needs from the files in the
# tree rather than from a scaffold-time answer: the same script then works in
# every generated repo and stays a byte-identical root<->template twin.
if [ "$do_install" -eq 1 ]; then
    # `pnpm-workspace.yaml` counts as a Node signal in its own right: a monorepo
    # may define the workspace there and keep package.json only in members, so
    # keying solely on a root package.json would report such a tree ready with
    # none of its dependencies installed.
    if [ -f "$tree/package.json" ] || [ -f "$tree/pnpm-workspace.yaml" ]; then
        have pnpm || die "a Node manifest is present but pnpm is not installed — run 'task bootstrap' (or install pnpm) and re-run"
        echo "==> Installing Node dependencies (pnpm) in the new tree"
        (cd "$tree" && pnpm install)
    fi
    if [ -f "$tree/pyproject.toml" ]; then
        have uv || die "pyproject.toml is present but uv is not installed — run 'task bootstrap' (or install uv) and re-run"
        echo "==> Installing Python dependencies (uv sync) in the new tree"
        (cd "$tree" && uv sync)
    fi
fi

# ── Hooks must FIRE in the new tree, not merely be configured ────────
# git looks a hook up in core.hooksPath when set, else $GIT_COMMON_DIR/hooks —
# `rev-parse --git-path hooks` implements exactly that resolution, so asking git
# is the assertion. --path-format=absolute resolves it against the new tree,
# which is what catches the classic breaker: `-c core.hooksPath=.git/hooks`
# points at a FILE's child in a linked worktree and silently finds nothing.
hooks_dir="$(git -C "$tree" rev-parse --path-format=absolute --git-path hooks)"

# EVERY hook lefthook.yml configures, not just pre-commit. A tree with
# pre-commit installed but commit-msg missing looks ready and quietly skips
# commit-message validation; the same gap on pre-push skips secret scanning.
# The list comes from lefthook.yml's top-level keys filtered against real git
# hook names, so a repo that adds a hook is covered without editing this script,
# and config keys like `assert_lefthook_installed` drop out by not being hooks.
git_hook_names="applypatch-msg pre-applypatch post-applypatch pre-commit pre-merge-commit prepare-commit-msg commit-msg post-commit pre-rebase post-checkout post-merge pre-push pre-receive update proc-receive post-receive post-update reference-transaction push-to-checkout pre-auto-gc post-rewrite sendemail-validate fsmonitor-watchman p4-changelist p4-prepare-changelist p4-post-changelist p4-pre-submit post-index-change"
configured_hooks=""
if [ -f "$tree/lefthook.yml" ]; then
    for key in $(awk -F: '/^[a-z][a-z-]*:/ {print $1}' "$tree/lefthook.yml"); do
        case " $git_hook_names " in
        *" $key "*) configured_hooks="$configured_hooks $key" ;;
        esac
    done
fi

missing_hooks() {
    _missing=""
    for _hook in $configured_hooks; do
        [ -x "$hooks_dir/$_hook" ] || _missing="$_missing $_hook"
    done
    printf '%s' "$_missing"
}

if [ -n "$configured_hooks" ] && [ -n "$(missing_hooks)" ]; then
    have lefthook || die "git hooks are not installed and lefthook is missing — install lefthook, run 'task install:hooks', and re-run"
    echo "==> Installing git hooks (lefthook) — missing:$(missing_hooks)"
    # Output is NOT swallowed: when lefthook refuses to install (a global
    # core.hooksPath is the common case) its diagnosis names the fix, and
    # discarding it would leave the user with nothing but a rollback notice.
    (cd "$tree" && lefthook install)
    hooks_dir="$(git -C "$tree" rev-parse --path-format=absolute --git-path hooks)"
fi

if [ -z "$configured_hooks" ]; then
    echo "==> Note: this repo configures no git hooks; skipping the hook assertion"
elif [ -n "$(missing_hooks)" ]; then
    die "hooks still missing after install ($(missing_hooks) ) at $hooks_dir — run 'task install:hooks' in $main_root and re-run"
else
    # Prove each hook RUNS from inside the tree and delegates to lefthook,
    # without running any actual lint. The lefthook-generated shim execs
    # $LEFTHOOK_BIN when set, so a probe binary records the delegation.
    probe_dir="$(mktemp -d)"
    marker="$probe_dir/invoked"
    cat >"$probe_dir/probe" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$marker"
EOF
    chmod +x "$probe_dir/probe"
    for hook in $configured_hooks; do
        : >"$marker"
        # commit-msg is handed a message file; pass a real one so the shim is
        # exercised the way git would call it.
        printf 'chore: worktree hook probe\n' >"$probe_dir/msg"
        (cd "$tree" && LEFTHOOK_BIN="$probe_dir/probe" "$hooks_dir/$hook" "$probe_dir/msg") ||
            die "the $hook hook at $hooks_dir failed to execute from $tree"
        grep -q "^run $hook" "$marker" 2>/dev/null ||
            die "the $hook hook did not delegate to lefthook from $tree — reinstall with 'task install:hooks'"
    done
    echo "==> Hooks verified: git resolves $hooks_dir and$configured_hooks fire in the new tree"
fi

# ── post-checkout, deferred until the tree can actually satisfy it ───
# `git worktree add` fires post-checkout itself, BEFORE this script has
# installed anything — so a hook that uses project dependencies (a codegen step,
# a version check running through the local toolchain) fails in every fresh
# worktree and takes the whole creation down with it. The provisioning checkout
# therefore runs with LEFTHOOK=0, and the hook runs here instead, once the tree
# is provisioned. Git's own argument shape: previous HEAD, new HEAD, and 1 for a
# branch checkout; the null OID stands in for "no previous HEAD", sized to the
# repository's hash algorithm rather than assumed to be SHA-1.
#
# Gated on post-checkout being LEFTHOOK-CONFIGURED, not merely present. Only a
# lefthook shim honours the LEFTHOOK=0 that suppressed it during the add; a
# hand-written post-checkout ran already, and re-running it here would be a
# second execution the repository never asked for.
case " $configured_hooks " in
*" post-checkout "*) run_post_checkout=1 ;;
*) run_post_checkout=0 ;;
esac
if [ "$run_post_checkout" -eq 1 ] && [ -x "$hooks_dir/post-checkout" ]; then
    new_head="$(git -C "$tree" rev-parse HEAD)"
    null_oid="$(printf '%s' "$new_head" | tr '[:alnum:]' '0')"
    echo "==> Running post-checkout now that the tree is provisioned"
    (cd "$tree" && "$hooks_dir/post-checkout" "$null_oid" "$new_head" 1) ||
        die "the repository's post-checkout hook failed in $tree"
fi

echo
echo "Worktree ready: $tree"
echo "Branch:         $branch"
echo "Next:           cd $tree && task check"
