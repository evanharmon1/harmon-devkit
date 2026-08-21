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
#   --base <ref>      base for a NEW branch (default: the main worktree's
#                     HEAD, verified against its configured upstream; also
#                     skips the live remote lookup for the branch name)
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

shell_quote() {
    # Single-quote $1 for a copy-pasteable remedy: branch names — unlike
    # worktree names, whose charset is whitelisted — legally carry $, ;,
    # quotes, and parentheses, so an unquoted name in a printed command
    # expands or executes when pasted (PR #932 cloud review).
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

name=""
branch=""
base=""
do_install=1

while [ "$#" -gt 0 ]; do
    case "$1" in
    --branch)
        # Non-empty is checked HERE, not by the later default: an empty
        # supplied value would otherwise fall through `branch=name` and
        # silently create a branch the caller never asked for (#929).
        [ "$#" -ge 2 ] && [ -n "$2" ] || die "--branch needs a non-empty value"
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

# Validate the branch EARLY — git itself rejects an invalid ref name only
# after the path is reserved and locks are held, with its own error instead
# of this remedy-carrying one (#929). The validator is git's own branch
# grammar, deliberately NOT the worktree-name charset: branch names are not
# charset-restricted (create-or-attach must accept an existing
# `feature+flag` or `release@2026` — docs/conventions.md § Worktrees), and
# the branch-namespace lock key already byte-clamps arbitrary names safely
# (#916). check-ref-format is local and side-effect-free, so the full
# grammar is settled before any lock, reservation, or ref write.
branch_canon="$(git check-ref-format --branch "$branch" 2>/dev/null)" ||
    die "invalid branch name '$branch' (from --branch, or the worktree name it defaults to): rejected by git check-ref-format --branch"
# check-ref-format --branch also EXPANDS checkout shorthand (`@{-1}` exits 0
# and prints the previous branch), while everything downstream — the branch
# lock, worktree add -b, the report — would keep the literal value: wrong
# lock identity, and a deleted previous branch silently recreated under a
# name the caller never wrote (challenge r3). Requiring the canonical output
# to equal the input closes that whole class.
[ "$branch_canon" = "$branch" ] ||
    die "invalid branch name '$branch': checkout shorthand is not accepted here — name the branch explicitly (this resolves to '$branch_canon')"

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
    # The branch NAME is captured first and the SHA resolved FROM that name,
    # never from a second HEAD read: parallel use is this entrypoint's design
    # space, and two separate HEAD reads can straddle a concurrent branch
    # switch in the main worktree — the pair would then mix one branch's
    # upstream with another branch's commit. Resolving refs/heads/<captured>
    # yields a self-consistent pair even if HEAD has moved on; the
    # verification below reuses the same captured name and never re-reads
    # HEAD either. A detached HEAD has no branch: its SHA is read directly
    # and the upstream verification stays off.
    default_base_branch="$(git -C "$main_root" symbolic-ref --quiet --short HEAD || true)"
    if [ -n "$default_base_branch" ]; then
        base_label="$default_base_branch"
        base="$(git -C "$main_root" rev-parse --verify --quiet "refs/heads/$default_base_branch" || true)"
    else
        base_label="HEAD"
        base="$(git -C "$main_root" rev-parse --verify --quiet HEAD || true)"
    fi
    [ -n "$base" ] ||
        die "the main worktree has no commits yet — make an initial commit, or pass --base <ref>"
    echo "==> Base: ${base_origin} (${base_label} @ $(git rev-parse --short "$base")) — pass --base <ref> to branch elsewhere"
fi

# Every network call this script makes must stay headless-safe and bounded:
# this entrypoint is run by agents with no terminal, where a credential
# prompt is an indefinite hang (the same failure shape as harmon-init#802),
# and a degraded remote that accepts the connection and then stalls would
# hang it just as hard. GIT_TERMINAL_PROMPT=0 turns a would-be HTTP prompt
# into a fast failure and the low-speed bounds turn an HTTP stall into one;
# neither reaches an SSH transport, so the ssh command gets BatchMode (no
# interactive auth) and a connect timeout too. The options are APPENDED to
# the user's own ssh command — ssh takes the first value obtained for an
# option, so anything they set explicitly still wins — and core.sshCommand
# is honoured before falling back to plain ssh, so a configured proxy or
# jump host keeps working.
#
# Residual, stated so nobody rediscovers it as a surprise: a server that
# ACCEPTS a connection and then stalls mid-protocol is bounded on HTTP (the
# low-speed limits) but not on SSH past the handshake, nor on git:// or
# custom remote helpers. This fleet's transport is HTTPS via gh (provisioned
# hosts rewrite SSH remotes), so the exposure is an unprovisioned host on an
# established-then-wedged non-HTTP connection — accepted rather than closed,
# because closing it means a hand-rolled process watchdog whose own failure
# modes (PID reuse, signal races, orphan supervision) outweigh the residual.
git_net() {
    _ssh_cmd="${GIT_SSH_COMMAND:-$(git -C "$main_root" config --get core.sshCommand 2>/dev/null || true)}"
    if [ -z "$_ssh_cmd" ] && [ -n "${GIT_SSH:-}" ]; then
        # GIT_SSH names a bare program that accepts no extra options —
        # appending ours would break the wrapper, and exporting
        # GIT_SSH_COMMAND would silently bypass it. Leave the SSH transport
        # to it, unbounded; the HTTP bounds and prompt suppression still
        # apply.
        GIT_TERMINAL_PROMPT=0 git -C "$main_root" \
            -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=30 "$@"
        return
    fi
    GIT_TERMINAL_PROMPT=0 \
        GIT_SSH_COMMAND="${_ssh_cmd:-ssh} -o BatchMode=yes -o ConnectTimeout=30" \
        git -C "$main_root" \
        -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=30 "$@"
}

# A local HEAD goes stale: merges land on the forge and nothing pulls, so an
# agent handed a fresh tree can be missing recently merged work
# (harmon-init#813). When HEAD's branch has an upstream, verify against it —
# not a guessed branch name; the upstream of whatever HEAD points at is
# configuration, which keeps #757's no-guessing design intact. Called ONLY
# where the default base is actually consumed — creating a NEW branch from
# it. Attaching an existing branch or tracking a remote-only branch never
# uses the base, so neither should be blocked (or even warned) by its
# staleness. May rewrite $base/$base_label or die.
verify_default_base() {
    # Everything resolves from $default_base_branch, captured with $base —
    # never from a fresh HEAD read (the main worktree can have switched
    # branches since). The remote name comes from branch config, never from
    # splitting ref text (a remote name may itself contain '/'), and the
    # probe/fetch SOURCE comes from branch.<name>.merge, never from the
    # abbreviated upstream name (a non-identity fetch refspec makes them
    # differ).
    [ -n "$default_base_branch" ] || return 0
    upstream_remote="$(git -C "$main_root" config --get "branch.$default_base_branch.remote" 2>/dev/null || true)"
    upstream_merge="$(git -C "$main_root" config --get "branch.$default_base_branch.merge" 2>/dev/null || true)"
    upstream_full="$(git -C "$main_root" rev-parse --symbolic-full-name "$default_base_branch@{upstream}" 2>/dev/null || true)"
    { [ -n "$upstream_remote" ] && [ -n "$upstream_full" ]; } || return 0
    upstream_label="$(git -C "$main_root" rev-parse --abbrev-ref "$default_base_branch@{upstream}" 2>/dev/null || echo "$upstream_full")"
    if [ "$upstream_remote" != "." ]; then
        [ -n "$upstream_merge" ] || return 0
        # The freshness answer is read LIVE off the remote and lands in no
        # ref of ours (harmon-init#916). The earlier form fetched
        # "+$upstream_merge:$upstream_full" — but @{upstream}'s full name is
        # wherever the user's refspec maps it, including refs/heads/*, so
        # that synthesized force-refspec could overwrite a LOCAL branch and
        # unref local-only commits merely because worktree:new refreshed the
        # base. Nor is dropping the destination enough: a fetch that names a
        # mapped source triggers git's opportunistic tracking update, which
        # force-writes the configured mapping even without "+" in the
        # refspec (verified empirically on git 2.x — "(forced update)" on a
        # refs/heads/* mapping). `--refmap=` is what actually detaches the
        # fetch from remote.<name>.fetch: objects arrive, FETCH_HEAD moves,
        # and no configured mapping is consulted (verified empirically) —
        # while the NAMED remote keeps remote-specific transport config
        # (remote.<name>.uploadpack, .proxy) that an anonymous URL fetch
        # would silently drop (challenge round 1).
        verify_known_before="$(git -C "$main_root" rev-parse --verify --quiet "$upstream_full^{commit}" || true)"
        verify_failed=0
        verify_probed_tip=""
        probe_out="$(git_net ls-remote "$upstream_remote" "$upstream_merge")" || verify_failed=1
        if [ "$verify_failed" -eq 0 ]; then
            upstream_tip="$(printf '%s\n' "$probe_out" | awk -v ref="$upstream_merge" -F'\t' '$2 == ref {print $1; exit}')"
            if [ -z "$upstream_tip" ]; then
                # Nothing to verify against: the configured source branch is
                # gone from the remote, and the local ref is all there is.
                echo "==> Note: '$upstream_remote' no longer has ${upstream_merge#refs/heads/} — basing on the local ${base_label}"
                return 0
            fi
            verify_probed_tip="$upstream_tip"
        fi
        if [ "$verify_failed" -eq 0 ]; then
            git_net fetch --quiet --refmap= "$upstream_remote" "$upstream_merge" || verify_failed=1
        fi
        if [ "$verify_failed" -eq 0 ]; then
            # One unconditional post-fetch probe, exactly as the remote-only
            # branch path below: the remote can advance between the first
            # probe and the fetch, and a stale tip resolving locally is no
            # evidence it stayed current. A tip that arrives unresolvable
            # means the remote moved again mid-operation, which no
            # client-side sequence can chase.
            probe_out="$(git_net ls-remote "$upstream_remote" "$upstream_merge")" || verify_failed=1
        fi
        if [ "$verify_failed" -eq 0 ]; then
            upstream_tip="$(printf '%s\n' "$probe_out" | awk -v ref="$upstream_merge" -F'\t' '$2 == ref {print $1; exit}')"
            if [ -z "$upstream_tip" ]; then
                echo "==> Note: '$upstream_remote' no longer has ${upstream_merge#refs/heads/} — basing on the local ${base_label}"
                return 0
            fi
            git -C "$main_root" rev-parse --verify --quiet "$upstream_tip^{commit}" >/dev/null ||
                die "${upstream_label} is moving on '$upstream_remote' — retry, or pass --base <ref>"
        fi
        if [ "$verify_failed" -eq 1 ]; then
            # An unverifiable upstream fails CLOSED (harmon-init#916), the
            # same policy the branch probes apply: proceeding on the
            # last-known tracking ref silently defeats the freshness
            # guarantee this function exists for. The one exception is
            # positive evidence of a concurrent refresh — the tracking ref
            # moved between this run's snapshot and the failure, so a
            # parallel worktree:new won the race and its answer is current
            # enough to verify against (harmon-init#813).
            verify_known_after="$(git -C "$main_root" rev-parse --verify --quiet "$upstream_full^{commit}" || true)"
            verify_trusted=0
            if [ -n "$verify_known_after" ] && [ "$verify_known_after" != "$verify_known_before" ]; then
                # Movement alone is not evidence: a custom refspec can map
                # the upstream into refs/heads/*, where an ordinary LOCAL
                # commit moves the ref too, and counting that as a
                # concurrent refresh would silently base the new tree on
                # unrelated local work (challenge round 2). Trust the
                # movement only when the moved value equals the tip this
                # run's own probe returned — remote-attested, THIS run's
                # answer. The namespace is deliberately not an arm of its
                # own: a concurrent fetch can publish an OLDER advertised
                # tip into refs/remotes/* after this run probed a newer
                # one, and proceeding on it would knowingly contradict the
                # fresher answer already in hand (challenge round 3).
                if [ -n "$verify_probed_tip" ] && [ "$verify_known_after" = "$verify_probed_tip" ]; then
                    verify_trusted=1
                fi
            fi
            if [ "$verify_trusted" -eq 1 ]; then
                echo "worktree:new: warning: could not fetch '$upstream_remote' — a concurrent fetch refreshed ${upstream_label} mid-run; verifying ${base_label} against that update (harmon-init#813)" >&2
                upstream_tip="$verify_known_after"
            else
                die "could not verify ${base_label} against ${upstream_label} — offline, unreachable, or needs interactive credentials; retry with network/auth, or pass --base <ref> to skip the freshness check"
            fi
        fi
    else
        upstream_tip="$(git -C "$main_root" rev-parse --verify --quiet "$upstream_full^{commit}" || true)"
    fi
    { [ -n "$upstream_tip" ] && [ "$upstream_tip" != "$base" ]; } || return 0
    if git -C "$main_root" merge-base --is-ancestor "$base" "$upstream_tip"; then
        # Behind: hand out the current upstream tip, not the stale local one.
        # Resolved to a SHA so branch creation picks up no tracking side
        # effects.
        echo "==> Base: ${base_label} is behind ${upstream_label} — using ${upstream_label} @ $(git rev-parse --short "$upstream_tip")"
        base="$upstream_tip"
        base_label="$upstream_label"
    elif git -C "$main_root" merge-base --is-ancestor "$upstream_tip" "$base"; then
        # Ahead: local has everything the upstream has, plus unpushed work
        # the caller presumably wants. Say so.
        echo "==> Note: ${base_label} is ahead of ${upstream_label}; basing on the local tip"
    else
        die "${base_label} has diverged from ${upstream_label} — reconcile them, or pass --base <ref> to choose a start point explicitly"
    fi
}

# Validated here, before anything is created, so a bad --base fails without a
# rollback message about a tree that never existed.
git rev-parse --verify --quiet "$base^{commit}" >/dev/null ||
    die "base ref '$base' does not resolve to a commit"

tree="$main_root/.worktrees/$name"

# ── Per-path lifecycle locks ─────────────────────────────────────────
# The protocol lives in worktree-lock.sh, SHARED with the sibling command:
# both must run identical lock semantics, so there is exactly one copy to
# correct. See that file for the design and its residuals.
# shellcheck source=scripts/worktree-lock.sh
. "$(dirname "$0")/worktree-lock.sh"

# The traps are armed BEFORE the first acquisition, so a signal or failure
# landing mid-acquisition still releases whatever partial set was taken.
# `cleanup` replaces the EXIT trap once rollback is armed and releases the
# locks itself. Held from before the registry snapshot to script exit,
# provisioning included: a removal attempted mid-provisioning refuses with
# "operation in progress" instead of pulling the tree out from under the
# installer.
trap release_locks EXIT
trap 'exit 129' HUP INT TERM
acquire_path_locks "$name"
# The branch is a second, independent resource: two creations under
# DIFFERENT names can name the same --branch, and their path locks never
# contend — see acquire_branch_lock for the race this closes.
acquire_branch_lock "$branch"

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
    # A sibling's removal can rmdir the emptied shared parent between our
    # mkdir -p above and this leaf claim — both operations are deliberately
    # admitted through the shared ancestor lock — so a missing parent gets
    # one re-create-and-retry before the failure is real.
    mkdir -p "$(dirname "$tree")" 2>/dev/null || true
    if ! mkdir "$tree" 2>/dev/null; then
        if [ -d "$tree" ]; then
            die "$tree already exists (or another worktree:new is creating it) — remove it with 'task worktree:rm -- $name' first"
        fi
        die "could not create $tree"
    fi
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
branch_owned=0
branch_owned_tip=""
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
        if [ "$branch_owned" -eq 0 ] &&
            [ "$branch_created" -eq 1 ] && [ "$tree_registered_before" -eq 0 ] &&
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
        rollback_tree_gone=1
        if git worktree list --porcelain | grep -qxF "worktree $tree"; then
            rollback_tree_gone=0
            echo "worktree:new: $tree is still registered after rollback — clear it with 'task worktree:rm -- $name'" >&2
        fi
        if [ "$branch_owned" -eq 1 ]; then
            # The remote-only path published this branch atomically at a
            # recorded tip, so rollback is a COMPARE-and-delete: the ref
            # goes only if it still holds exactly that tip. Path locks do
            # not serialize branch refs, so a concurrent fetch or push can
            # legitimately move the branch between creation and this
            # rollback — a moved tip holds commits this run did not create,
            # and deleting it would discard them (challenge round 1). And
            # it is gated on the tree actually being DEREGISTERED:
            # update-ref is plumbing that bypasses git's checked-out guard,
            # so deleting the branch under a tree the removal failed to
            # clear would leave a live registered worktree on an unborn
            # HEAD (challenge round 3).
            if [ "$rollback_tree_gone" -eq 0 ]; then
                echo "worktree:new: leaving branch '$branch' alone — its worktree could not be removed and still has it checked out" >&2
            elif git worktree list --porcelain | grep -qxF "branch refs/heads/$branch"; then
                # A non-cooperating client — a raw `git worktree add`,
                # outside the branch lock — can attach the just-published
                # branch before this run's own attach fails on it, and
                # update-ref bypasses git's checked-out guard (challenge
                # round 5). No commit can be orphaned here — any commit
                # moves the tip and the compare-and-delete below refuses —
                # but the attach is not ours to break. The moments between
                # this scan and the delete are the documented residual.
                echo "worktree:new: leaving branch '$branch' alone — another worktree has it checked out" >&2
            elif LEFTHOOK=0 git update-ref -d "refs/heads/$branch" "$branch_owned_tip" 2>/dev/null; then
                # This run's writes are the only possible values here — a
                # pre-existing remote/merge key refuses creation up front —
                # so rollback removes exactly the two keys it wrote and
                # nothing else (pushRemote, rebase, a description are never
                # touched; challenge round 3). Guarded, because this runs
                # inside the EXIT trap under set -e and a config-lock
                # failure must never abort the trap before release_locks
                # (challenge round 4).
                # A failed unset (a concurrent process holding the config
                # lock) leaves debris the stale-config guard will refuse at
                # the next use of this branch name, so name the remedy NOW
                # rather than then. Unsetting before the ref delete instead
                # would be worse: a compare-and-delete refusal after the
                # unsets leaves a SURVIVING branch silently untracked
                # (PR #932 cloud review).
                git config --unset "branch.$branch.remote" 2>/dev/null ||
                    echo "worktree:new: could not remove branch.$branch.remote — clear it with: git config --unset $(shell_quote "branch.$branch.remote")" >&2 || true
                git config --unset "branch.$branch.merge" 2>/dev/null ||
                    echo "worktree:new: could not remove branch.$branch.merge — clear it with: git config --unset $(shell_quote "branch.$branch.merge")" >&2 || true
            else
                echo "worktree:new: leaving branch '$branch' alone — its tip moved since this run created it" >&2
            fi
        elif [ "$branch_is_ours" -eq 1 ]; then
            LEFTHOOK=0 git branch -D "$branch" >/dev/null 2>&1 || true
        elif [ "$branch_created" -eq 1 ]; then
            echo "worktree:new: leaving branch '$branch' alone — this run did not create it" >&2
        fi
    fi
    release_locks
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
    remote_match_remote=""
    remote_count=0
    while IFS= read -r remote_name; do
        [ -n "$remote_name" ] || continue
        # Each remote is probed LIVE (harmon-init#840): the local
        # refs/remotes/* namespace is only as fresh as the last fetch, so a
        # branch pushed since then would read as absent and be silently
        # recreated at the default base — diverging from the collaborator's
        # branch. `ls-remote` patterns are tail-matched, so the answer is
        # filtered to the exact ref before it counts. A probe that cannot
        # answer fails CLOSED: "the remote is unreachable" is not evidence
        # the branch is new, and guessing here is the data-loss path.
        probe_out="$(git_net ls-remote --heads "$remote_name" "refs/heads/$branch")" ||
            die "could not query remote '$remote_name' for branch '$branch' — offline, unreachable, or needs interactive credentials; retry with network/auth, or pass --base <ref> to skip the remote lookup"
        probe_sha="$(printf '%s\n' "$probe_out" | awk -v ref="refs/heads/$branch" -F'\t' '$2 == ref {print $1; exit}')"
        if [ -n "$probe_sha" ]; then
            remote_matches="refs/remotes/$remote_name/$branch"
            remote_match_remote="$remote_name"
            remote_probe_sha="$probe_sha"
            remote_count=$((remote_count + 1))
        fi
    done <<EOF
$(git -C "$main_root" remote)
EOF
    if [ "$remote_count" -gt 1 ]; then
        die "branch '$branch' exists on more than one remote — pass --base <remote>/<branch> to choose one"
    fi
    if [ "$remote_count" -eq 1 ]; then
        # Fetched WITHOUT a destination refspec, so the only tracking refs
        # updated are the ones the remote's OWN configured refspec maps —
        # a synthesized identity destination could overwrite a tracking ref
        # that a custom refspec maps a different branch into. The commit to
        # attach is the one the probe saw ($remote_probe_sha), verified
        # present after the fetch rather than read from any ref of ours.
        # LEFTHOOK=0: this fetch deliberately updates whatever tracking ref
        # the remote's own refspec maps, and a lefthook-shimmed
        # reference-transaction hook must not fire on a ref write of this
        # operation before the new tree exists (PR #932 cloud review).
        LEFTHOOK=0 git_net fetch --quiet "$remote_match_remote" "refs/heads/$branch" ||
            die "found branch '$branch' on remote '$remote_match_remote' but could not fetch it — retry, or pass --base <ref>"
        # One UNCONDITIONAL post-fetch probe. The remote can advance between
        # the first probe and the fetch, and the first probe's tip resolving
        # locally is no evidence it stayed current — a stale tracking ref
        # can make an outdated commit resolve just fine. The fetch already
        # imported whatever the remote advanced to, so the fresh probe's
        # answer normally resolves and the attach lands on it; a tip that
        # arrives unresolvable means the remote moved again mid-operation,
        # which no client-side sequence can chase — stop and say so. (The
        # window between this probe and the attach is inherent; this keeps
        # it one probe wide instead of pretending to close it.)
        probe_out="$(git_net ls-remote --heads "$remote_match_remote" "refs/heads/$branch")" ||
            die "remote '$remote_match_remote' became unqueryable while fetching '$branch' — retry, or pass --base <ref>"
        remote_probe_sha="$(printf '%s\n' "$probe_out" | awk -v ref="refs/heads/$branch" -F'\t' '$2 == ref {print $1; exit}')"
        [ -n "$remote_probe_sha" ] ||
            die "branch '$branch' disappeared from remote '$remote_match_remote' while fetching — retry, or pass --base <ref>"
        git rev-parse --verify --quiet "$remote_probe_sha^{commit}" >/dev/null ||
            die "branch '$branch' on remote '$remote_match_remote' is moving — retry, or pass --base <ref>"
        remote_ref="$remote_matches"
    fi
fi

if git show-ref --verify --quiet "refs/heads/$branch"; then
    echo "==> Attaching existing branch '$branch'"
    LEFTHOOK=0 git worktree add "$tree" "$branch"
elif [ -n "$remote_ref" ]; then
    echo "==> Creating branch '$branch' tracking $remote_match_remote/$branch"
    # Created from the PROBED commit with tracking written as plain branch
    # config, never via `--track` DWIM and never via a ref this script
    # wrote: --track derives the upstream by reverse-mapping the start point
    # through the remote's fetch refspec and aborts under a non-identity
    # one, and any destination ref we synthesized could collide with what a
    # custom refspec maps there. branch.<name>.remote + branch.<name>.merge
    # are correct under EVERY refspec, and @{u} then resolves through
    # whatever mapping the repo actually configures.
    #
    # Branch and tracking config land BEFORE the worktree attach
    # (harmon-init#916): `git worktree add` fires any hand-written
    # post-checkout hook itself — LEFTHOOK=0 suppresses only lefthook-shaped
    # shims — and a hook that resolves @{upstream} must never observe the
    # branch untracked.
    #
    # Pre-existing branch.<name>.remote/.merge config for a branch that
    # does not exist locally is refused up front — stale debris from a
    # deleted branch. Refusing is what keeps the rollback below trivial
    # and lossless (challenge round 4): this run's writes become the ONLY
    # possible values for those two keys, so there are no prior values to
    # capture, no multi-valued snapshots to restore faithfully, and no
    # signal window in which a capture could be missed. Everything else
    # in the section (pushRemote, rebase, a description) is never touched
    # in either direction.
    # Scoped to --local deliberately: the repository config is the only
    # scope this script writes and the only one its rollback and the
    # remedy below can clear — an unscoped lookup would also match a
    # global/system/include-provided value, which is user configuration
    # rather than debris, and refuse forever with a remedy git answers
    # with exit 5 (PR #932 cloud review).
    for _bk in remote merge; do
        if git config --local --get-all "branch.$branch.$_bk" >/dev/null 2>&1; then
            die "branch '$branch' does not exist locally but branch.$branch.$_bk is configured — stale config from a deleted branch; review it, clear it with: git config --unset-all $(shell_quote "branch.$branch.$_bk") — and re-run"
        fi
    done
    # Ownership bookkeeping is armed BEFORE the ref exists and the ref is
    # created atomically create-only (old value "" = must not exist), so a
    # signal landing between the ref transaction committing and the next
    # shell statement already finds the flags set — cleanup can never be
    # left unaware of a branch this run published (challenge round 1). A
    # refused create un-arms before dying; what makes the early arming safe
    # is cleanup's compare-and-delete, which only ever removes the exact
    # tip recorded here.
    #
    # HUP/INT/TERM are DEFERRED (recorded, re-raised after) across the
    # create -> flag transition: bash runs a pending trap between a FAILED
    # create-only update-ref and the un-arm below, so the 'exit 129' trap
    # could reach cleanup still armed — and the compare-and-delete would
    # match a COMPETING client's branch at the same probed tip, deleting a
    # branch this run never created (PR #932 cloud review). LEFTHOOK=0 for
    # the same reason the worktree-add calls carry it: a lefthook-shimmed
    # reference-transaction hook must not fire mid-publication, before the
    # tree its project tooling expects exists.
    publish_sig=""
    trap 'publish_sig=HUP' HUP
    trap 'publish_sig=INT' INT
    trap 'publish_sig=TERM' TERM
    branch_created=1
    branch_owned=1
    branch_owned_tip="$remote_probe_sha"
    publish_rc=0
    LEFTHOOK=0 git update-ref "refs/heads/$branch" "$remote_probe_sha" "" 2>/dev/null || publish_rc=$?
    if [ "$publish_rc" -ne 0 ]; then
        branch_created=0
        branch_owned=0
    fi
    trap 'exit 129' HUP INT TERM
    [ -z "$publish_sig" ] || kill -s "$publish_sig" $$
    [ "$publish_rc" -eq 0 ] ||
        die "branch '$branch' appeared while this run was creating it (or a reference-transaction hook refused the update) — re-run to attach it"
    git config "branch.$branch.remote" "$remote_match_remote"
    git config "branch.$branch.merge" "refs/heads/$branch"
    LEFTHOOK=0 git worktree add "$tree" "$branch"
    # Honesty check on the tracking claim: pull and push work off the branch
    # config just written, but @{upstream}-based tooling (status ahead/behind,
    # verify_default_base if this branch ever becomes the main HEAD) resolves
    # through the remote's fetch refspec — which a custom refspec may simply
    # not map for this branch. Say so instead of letting "tracking" imply
    # more than it delivers.
    git rev-parse --verify --quiet "$branch@{upstream}" >/dev/null 2>&1 ||
        echo "==> Note: '$remote_match_remote's fetch refspec does not map refs/heads/$branch — pull/push work via branch config, but @{upstream} tooling will not see an upstream"
else
    # The one path that consumes the default base — verify its freshness
    # here and nowhere earlier, so attaching an existing branch or tracking
    # a remote-only one is never blocked by a stale or diverged main
    # (harmon-init#813).
    [ "$base_origin" = "explicit" ] || verify_default_base
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
        # package.json is shared by npm, Yarn, Bun, and pnpm alike, so it
        # proves "this is a Node repo", never "this repo uses pnpm"
        # (harmon-init#841) — running the wrong installer resolves a different
        # dependency graph and writes a foreign lockfile into the new tree.
        # Select the manager deterministically, in this precedence
        # (documented in docs/conventions.md § Worktrees):
        #   1. The `packageManager` field in package.json — the repo's own
        #      declaration (the Corepack convention). It wins over a stale
        #      foreign lockfile when the declared manager's own
        #      infrastructure is present — but a declaration whose manager
        #      has NO files here while other managers' files exist is a
        #      contradiction, refused before any install: the declared
        #      manager would succeed by writing a second lockfile into the
        #      fresh tree, reporting ready with a dirty worktree
        #      (challenge round 2). Parsed best-effort because jq is not
        #      one of this script's dependencies: the file is flattened
        #      first (the field's name, colon, and value legally sit on
        #      separate lines, and values never contain whitespace), then
        #      matched as a string-valued key. The spec puts the field at
        #      top level with a string value; nested objects like
        #      devEngines.packageManager carry an object value, which this
        #      pattern does not match.
        #   2. Exactly one manager's own files at the tree root:
        #      pnpm-lock.yaml or pnpm-workspace.yaml → pnpm;
        #      package-lock.json or npm-shrinkwrap.json → npm;
        #      yarn.lock → yarn; bun.lock or bun.lockb → bun.
        #      Files from two managers at once is a contradiction only the
        #      repo can resolve — fail loudly rather than guess, because the
        #      guess that loses writes the wrong lockfile.
        #   3. No signal at all (a bare package.json): skip the install with
        #      a note naming the fix. Installing on a guess here is the exact
        #      defect this block replaces, and a skipped install is visible
        #      while a wrong lockfile is not.
        node_pm=""
        pm_decl=""
        if [ -f "$tree/package.json" ]; then
            # tr collapses the whole file to one line, so sed emits at most
            # one match and needs no `head` (whose early exit would race a
            # SIGPIPE under pipefail).
            pm_decl="$(tr -d '\n\r\t ' <"$tree/package.json" | sed -n 's/.*"packageManager":"\([^"]*\)".*/\1/p')"
        fi
        node_signals=""
        if [ -f "$tree/pnpm-lock.yaml" ] || [ -f "$tree/pnpm-workspace.yaml" ]; then
            node_signals="$node_signals pnpm"
        fi
        if [ -f "$tree/package-lock.json" ] || [ -f "$tree/npm-shrinkwrap.json" ]; then
            node_signals="$node_signals npm"
        fi
        if [ -f "$tree/yarn.lock" ]; then
            node_signals="$node_signals yarn"
        fi
        if [ -f "$tree/bun.lock" ] || [ -f "$tree/bun.lockb" ]; then
            node_signals="$node_signals bun"
        fi
        if [ -n "$pm_decl" ]; then
            node_pm=${pm_decl%%@*}
            case "$node_pm" in
            pnpm | npm | yarn | bun) ;;
            *) die "package.json declares packageManager '$pm_decl', which this script does not support (pnpm, npm, yarn, bun) — install dependencies with it yourself, or re-run with --no-install" ;;
            esac
            if [ -n "$node_signals" ]; then
                case " $node_signals " in
                *" $node_pm "*) : ;;
                *) die "package.json declares packageManager '$pm_decl' but the tree carries other managers' files (${node_signals# }) and none of $node_pm's — remove the stale file(s), or install and commit $node_pm's lockfile in the main checkout, then re-run (or use --no-install)" ;;
                esac
            fi
        else
            node_pm_count=0
            for node_pm_candidate in $node_signals; do
                node_pm_count=$((node_pm_count + 1))
                node_pm=$node_pm_candidate
            done
            if [ "$node_pm_count" -gt 1 ]; then
                die "conflicting Node package-manager signals in this tree:$node_signals — remove the stale manager's file(s) or declare \"packageManager\" in package.json, then re-run"
            fi
        fi
        if [ -n "$node_pm" ]; then
            have "$node_pm" || die "this repo's Node package manager is $node_pm but it is not installed — install $node_pm (for pnpm, 'task bootstrap' does) and re-run"
            # Honor a numeric major in the declaration's version pin
            # (challenge round 2): a drifted major can rewrite the committed
            # lockfile in a fresh tree. A corepack-shimmed binary reports the
            # pinned version itself, so corepack-managed repos pass; a pin
            # with no numeric major (or none at all) leaves nothing to
            # verify and skips — signal-selected managers carry no pin.
            pm_pin=""
            case "$pm_decl" in
            *@*)
                pm_pin=${pm_decl#*@}
                pm_pin=${pm_pin%%+*}
                ;;
            esac
            pm_pin_major=${pm_pin%%.*}
            case "$pm_pin_major" in
            '' | *[!0-9]*) : ;;
            *)
                installed_ver="$("$node_pm" --version 2>/dev/null || true)"
                installed_ver=${installed_ver#v}
                installed_major=${installed_ver%%.*}
                case "$installed_major" in
                '' | *[!0-9]*) die "packageManager pins $node_pm@$pm_pin but the installed $node_pm's version could not be read — reinstall $node_pm and re-run (or use --no-install)" ;;
                *) [ "$installed_major" = "$pm_pin_major" ] || die "packageManager pins $node_pm@$pm_pin but $node_pm $installed_ver is installed — a different major can rewrite the committed lockfile; install the pinned major (corepack does this) or update the declaration, then re-run (or use --no-install)" ;;
                esac
                ;;
            esac
            # When the selected manager's own lockfile is present, install in
            # its immutable mode (challenge round 3): a plain install can
            # legally REWRITE a committed lockfile — npm 11 upgrades a
            # lockfileVersion-1 file in place — and a provisioning step must
            # fail and roll back on drift, not report a dirty tree as ready.
            # The devcontainer post-checkout hook set this precedent (npm ci,
            # --frozen-lockfile). With no lockfile — a workspace-file-only
            # root, or a declaration with no manager files yet — plain
            # install remains: there is nothing to preserve, and the first
            # install legitimately creates the lockfile.
            node_pm_args=("install")
            case "$node_pm" in
            pnpm)
                if [ -f "$tree/pnpm-lock.yaml" ]; then
                    node_pm_args=("install" "--frozen-lockfile")
                fi
                ;;
            npm)
                if [ -f "$tree/package-lock.json" ] || [ -f "$tree/npm-shrinkwrap.json" ]; then
                    node_pm_args=("ci")
                fi
                ;;
            yarn)
                # Classic (1.x) spells the immutable mode --frozen-lockfile;
                # Berry spells it --immutable. Version-split rather than
                # relying on Berry's deprecated alias.
                if [ -f "$tree/yarn.lock" ]; then
                    yarn_ver="$(yarn --version 2>/dev/null || true)"
                    case "${yarn_ver%%.*}" in
                    1) node_pm_args=("install" "--frozen-lockfile") ;;
                    '' | *[!0-9]*) die "yarn.lock is present but yarn's version could not be read — reinstall yarn and re-run (or use --no-install)" ;;
                    *) node_pm_args=("install" "--immutable") ;;
                    esac
                fi
                ;;
            bun)
                if [ -f "$tree/bun.lock" ] || [ -f "$tree/bun.lockb" ]; then
                    node_pm_args=("install" "--frozen-lockfile")
                fi
                ;;
            esac
            echo "==> Installing Node dependencies ($node_pm ${node_pm_args[*]}) in the new tree"
            (cd "$tree" && "$node_pm" "${node_pm_args[@]}")
        else
            echo "==> Note: package.json carries no package-manager signal (no packageManager field, no lockfile) — skipping the Node install; declare \"packageManager\" in package.json, or install dependencies in the tree yourself"
        fi
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
    # </dev/null is load-bearing: lefthook blocks `run post-checkout` until its
    # stdin reaches EOF (observed on v2.1.10), so inheriting a stdin the caller
    # holds open — an agent harness socket, a task runner pipe — deadlocks the
    # hook here indefinitely (harmon-init#802). Git hands post-checkout no
    # stdin payload, so an immediate EOF loses nothing.
    (cd "$tree" && "$hooks_dir/post-checkout" "$null_oid" "$new_head" 1 </dev/null) ||
        die "the repository's post-checkout hook failed in $tree"
fi

echo
echo "Worktree ready: $tree"
echo "Branch:         $branch"
echo "Next:           cd $tree && task check"
