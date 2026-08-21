#!/usr/bin/env bash
# clean-branches.sh — delete local branches, but only on positive evidence the
# work is safe to drop. Run via `task clean:branches` (dry run) or
# `task clean:branches -- --delete` (act).
#
# The rule this script encodes (harmon-init#838): every deletion requires
# positive evidence — either the branch is an ANCESTOR of the remote default
# branch (verified fresh against the remote's advertised tip), or a PR MERGED
# INTO THE DEFAULT BRANCH whose head commit is exactly this branch's tip
# proves the same work landed by squash or rebase. "The upstream is gone" is
# an inference, not evidence: this repo squash-merges, so a delivered branch
# is not an ancestor of main and is indistinguishable, by ancestry alone,
# from genuinely unmerged work.
#
# What it never does:
#   * force-delete (the capital-D flag) — that discards the evidence rule by
#     design, and issue #838's verify greps this file to prove its absence.
#   * remove a worktree, or touch any remote branch.
#   * delete the current branch, the default branch, or a branch checked out
#     in any worktree (update-ref does not respect git's checked-out guard,
#     so the explicit worktree check below is load-bearing).
#   * delete unpushed work. Ancestry evidence means every commit is on the
#     remote default branch; PR evidence means the merged PR's head commit IS
#     this tip, so every local commit was pushed into the PR that merged. A
#     tip that sits even one commit past the merged head matches neither and
#     is refused.
#
# Every deletion is a guarded compare-and-delete
# (`git update-ref --no-deref -d <ref> <verified-tip>`) rather than
# `git branch -d`: -d structurally refuses a squash-merged non-ancestor no
# matter how much evidence exists, and it authorizes against the CURRENT
# HEAD rather than the verified remote default (challenge r2). The old-value
# guard makes the delete atomic: if anything moves the branch between
# verification and deletion, git refuses. Same pattern as worktree-new.sh's
# rollback. Every deletion prints the tip SHA so `git branch <name> <sha>`
# can restore it until git prunes the objects.
set -euo pipefail

# Replacement refs rewrite parentage cosmetically; evidence and reporting must
# judge RAW history — a refs/replace graft could make an unmerged branch read
# as an ancestor of the default branch (challenge r8). Ignoring replacements
# is the fail-closed direction: a grafted-in branch is kept, never deleted.
export GIT_NO_REPLACE_OBJECTS=1

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

usage() {
    cat >&2 <<'EOF'
Usage: task clean:branches [-- --delete]

Dry run by default: reports what would be deleted and why, mutating nothing.
--delete performs the deletions. Only branches with positive merge evidence
(ancestry into the remote default branch, or a PR merged into the default
branch whose head commit equals the local tip) are ever deleted, always
without force.
EOF
}

die() {
    echo "clean:branches: $*" >&2
    exit 1
}

# POSIX shell-quote for values echoed into copyable commands: branch names
# legally carry shell metacharacters (challenge r7; same class as
# worktree-new.sh's printed remedies).
shell_quote() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

do_delete=false
for arg in "$@"; do
    case "$arg" in
    --delete) do_delete=true ;;
    -h | --help)
        usage
        exit 0
        ;;
    *)
        usage
        die "unknown argument: $arg"
        ;;
    esac
done

# ── Ground truth ────────────────────────────────────────────────────────────

remotes="$(git remote)"
if [ -z "$remotes" ]; then
    echo "clean:branches: no remote configured — no merge evidence is possible; nothing to do."
    exit 0
fi
if printf '%s\n' "$remotes" | grep -qx origin; then
    remote=origin
elif [ "$(printf '%s\n' "$remotes" | wc -l | tr -d ' ')" = "1" ]; then
    remote="$remotes"
else
    die "multiple remotes and none named origin — cannot pick a merge-evidence source"
fi

# Default branch of the remote: the ancestry target, and protected from
# deletion. Falls back to a main/master probe when the remote HEAD symref was
# never recorded locally (`git remote set-head $remote --auto` records it).
default_branch=""
if default_ref="$(git symbolic-ref --quiet "refs/remotes/$remote/HEAD")"; then
    default_branch="${default_ref#"refs/remotes/$remote/"}"
else
    for cand in main master; do
        if git show-ref --verify --quiet "refs/remotes/$remote/$cand"; then
            default_branch="$cand"
            break
        fi
    done
fi
[ -n "$default_branch" ] ||
    die "cannot resolve $remote's default branch (try: git remote set-head $remote --auto)"
ancestry_target="refs/remotes/$remote/$default_branch"

current_branch="$(git branch --show-current || true)"

# Legacy graft files rewrite parentage exactly as replace refs do, but
# GIT_NO_REPLACE_OBJECTS does NOT disable them (review r1). Ancestry walked
# over grafted history is not evidence — refuse the whole ancestry class
# while one exists; merged-PR evidence does not walk history and stays valid.
grafts_present=false
grafts_file="$(git rev-parse --git-path info/grafts)"
if [ -s "$grafts_file" ]; then
    grafts_present=true
    echo "NOTE  legacy graft file present ($grafts_file) — ancestry evidence is unusable while it exists; only merged-PR evidence applies"
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/clean-branches.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

# Branches checked out anywhere: name<TAB>worktree-path. `git branch -d`
# refuses these on its own; the update-ref path would not, so this check
# guards it explicitly (do not work around a refusal either way).
git worktree list --porcelain | awk '
    /^worktree /            { path = substr($0, 10) }
    /^branch refs\/heads\// { printf "%s\t%s\n", substr($0, 19), path }
' >"$tmp/checked-out"

# Bounded network probes, resolved once (status.sh precedent: a hung gh call
# must not wedge the run; stock macOS gets `timeout` from coreutils).
TIMEOUT_BIN=""
if command -v timeout >/dev/null 2>&1; then
    TIMEOUT_BIN=timeout
elif command -v gtimeout >/dev/null 2>&1; then
    TIMEOUT_BIN=gtimeout
else
    echo "clean:branches: no 'timeout' found (brew install coreutils) — network probes are unbounded." >&2
fi

# net_probe <cmd...> — bounded, stdin-closed network invocation (gh or git).
net_probe() {
    if [ -n "$TIMEOUT_BIN" ]; then
        "$TIMEOUT_BIN" -k 5 "${GH_TIMEOUT:-30}" "$@" </dev/null
    else
        "$@" </dev/null
    fi
}

gh_pr_probe() {
    net_probe gh "$@"
}

# PR-evidence availability: gh present and able to name the remote's repo.
# Resolved from the remote URL rather than gh's default-repo state, because a
# multi-remote checkout can default to a different repository.
gh_repo=""
if command -v gh >/dev/null 2>&1; then
    gh_repo="$(gh_pr_probe repo view "$(git remote get-url "$remote")" \
        --json nameWithOwner --jq .nameWithOwner 2>/dev/null)" || gh_repo=""
fi

# PR evidence means: a merged PR whose head commit is exactly the branch tip
# AND whose base is the remote default branch. Tip equality is the point —
# matching by branch NAME alone would let a recycled branch name inherit an
# old PR's merged-ness and delete unrelated new work. The base filter is
# equally load-bearing (challenge r2): a PR merged into a stacked or
# temporary base that was later deleted still reports "merged" with this
# head, yet its result may be reachable from no live ref — only a merge into
# the default branch proves the work is durably delivered.
#
# Evidence is fetched as ONE batched listing (challenge r4): probing per
# branch makes total stall time N * GH_TIMEOUT when the API wedges, which is
# exactly the no-wedge contract the timeout exists for. The batch has a cap,
# so branches it does not answer fall back to one per-branch probe each —
# bounded by the number of unmatched gone branches, not the whole tree.
batch_state=unfetched # unfetched | ok | capped | failed
fallback_dead=false   # one failed per-branch probe fails the rest closed
batch_prs() {
    if [ "$batch_state" = unfetched ]; then
        pr_limit="${CLEAN_PR_LIMIT:-1000}"
        if gh_pr_probe pr list --repo "$gh_repo" --state merged --limit "$pr_limit" \
            --json number,headRefName,headRefOid,baseRefName \
            --jq '.[] | [.headRefName, .headRefOid, (.number | tostring), .baseRefName] | @tsv' \
            >"$tmp/merged-prs" 2>/dev/null; then
            if [ "$(wc -l <"$tmp/merged-prs" | tr -d ' ')" -ge "$pr_limit" ]; then
                batch_state=capped
                echo "NOTE  merged-PR listing hit its $pr_limit cap — unmatched branches get one per-branch probe each"
            else
                batch_state=ok
            fi
        else
            batch_state=failed
        fi
    fi
    [ "$batch_state" != failed ]
}

# merged_pr_for <branch> <tip> — the per-branch fallback probe, used only
# when the capped batch could not answer for this branch. Echoes the PR
# number on a tip+base match, nothing when none exists, nonzero when the
# probe itself failed (a network error is never mistaken for "no PR").
merged_pr_for() {
    gh_pr_probe pr list --repo "$gh_repo" --head "$1" --state merged \
        --json number,headRefOid,baseRefName \
        --jq '.[] | [(.number | tostring), .headRefOid, .baseRefName] | @tsv' \
        >"$tmp/pr-probe" 2>/dev/null || return 1
    awk -F'\t' -v tip="$2" -v base="$default_branch" \
        '$2 == tip && $3 == base { print $1; exit }' "$tmp/pr-probe"
}

# ── Classify every branch ───────────────────────────────────────────────────

# %(refname:lstrip=2), not %(refname:short): when a tag shares the branch's
# name, :short disambiguates to "heads/<name>", which would break every
# "refs/heads/$branch" built from it (challenge r1). %(symref) is nonempty
# for a symbolic ref — deleting one via update-ref would DEREFERENCE it and
# delete the target branch instead, so symbolic entries are skipped outright.
# The two optionally-empty fields carry a '-' sentinel: tab is IFS
# whitespace, so `read` would otherwise COLLAPSE an empty middle field and
# shift %(symref) into the track column.
git for-each-ref refs/heads \
    --format='%(refname:lstrip=2)%09%(objectname)%09%(if)%(upstream:track)%(then)%(upstream:track)%(else)-%(end)%09%(if)%(symref)%(then)%(symref)%(else)-%(end)%09%(if)%(upstream)%(then)%(upstream)%(else)-%(end)' \
    >"$tmp/branches"

total=0
candidates=0
refused=0
active=0
active_tracked=0

while IFS=$'\t' read -r branch tip track symref upstream_ref; do
    total=$((total + 1))

    [ "$branch" = "$current_branch" ] && continue
    [ "$branch" = "$default_branch" ] && continue

    if [ "$symref" != "-" ]; then
        echo "SKIP  $branch — symbolic ref (points at $symref; never dereferenced or deleted)"
        refused=$((refused + 1))
        continue
    fi

    if wt_path="$(awk -F'\t' -v b="$branch" '$1 == b { print $2; exit }' "$tmp/checked-out")" &&
        [ -n "$wt_path" ]; then
        echo "SKIP  $branch — checked out in worktree $wt_path (never deleted from here)"
        refused=$((refused + 1))
        continue
    fi

    # Evidence class 1 — ancestry: every commit is reachable from the remote
    # default branch, so nothing local can be lost. The deletion itself is
    # the same guarded compare-and-delete as the PR class (see delete_one) —
    # authorized by this verified ancestry, re-validated at delete time.
    if [ "$grafts_present" = false ] &&
        git merge-base --is-ancestor "refs/heads/$branch" "$ancestry_target"; then
        printf '%s\t%s\tancestry\t\n' "$branch" "$tip" >>"$tmp/candidates"
        candidates=$((candidates + 1))
        continue
    fi

    # Evidence class 2 — a merged PR whose HEAD COMMIT equals this tip. Squash
    # merge rewrites history, so after the remote branch is deleted these
    # commits sit on no remote-tracking ref and no rev-list check can clear
    # them; tip equality is what proves every local commit was in the merged
    # PR (pushed, reviewed, delivered). Anything short of that equality —
    # including one extra local commit on top of the merged head — falls
    # through to the refusals below.
    if [ "$track" = "[gone]" ] && [ -n "$gh_repo" ]; then
        if ! batch_prs; then
            echo "SKIP  $branch — upstream gone, but the merged-PR listing failed (gh/network error)"
            refused=$((refused + 1))
            continue
        fi
        pr="$(awk -F'\t' -v b="$branch" -v tip="$tip" -v base="$default_branch" \
            '$1 == b && $2 == tip && $4 == base { print $3; exit }' "$tmp/merged-prs")"
        if [ -z "$pr" ] && [ "$batch_state" = capped ]; then
            # Circuit breaker (challenge r5): one failed fallback probe fails
            # the REMAINING unmatched set closed — otherwise a stalled API
            # costs GH_TIMEOUT per unmatched branch instead of once.
            if [ "$fallback_dead" = true ]; then
                echo "SKIP  $branch — upstream gone; per-branch probes suspended after an earlier probe failure (fail closed)"
                refused=$((refused + 1))
                continue
            fi
            if ! pr="$(merged_pr_for "$branch" "$tip")"; then
                fallback_dead=true
                echo "SKIP  $branch — upstream gone, but the merged-PR probe failed (gh/network error); suspending remaining per-branch probes"
                refused=$((refused + 1))
                continue
            fi
        fi
        if [ -n "$pr" ]; then
            printf '%s\t%s\tpr\t%s\n' "$branch" "$tip" "$pr" >>"$tmp/candidates"
            candidates=$((candidates + 1))
            continue
        fi
    fi

    # No evidence. A gone upstream still gets a loud line (it is the
    # population this tool exists to triage); everything else is ordinary
    # in-flight work and stays quiet.
    if [ "$track" = "[gone]" ]; then
        unpushed="$(git rev-list --count "refs/heads/$branch" --not --remotes --)"
        if [ -z "$gh_repo" ]; then
            echo "SKIP  $branch — upstream gone, but gh is unavailable so no merged PR can vouch for it"
        elif [ "$unpushed" -gt 0 ]; then
            echo "SKIP  $branch — upstream gone, $unpushed commit(s) on no remote and no PR merged into $default_branch matches tip ${tip:0:12} (unpushed work is never deleted)"
        else
            echo "SKIP  $branch — upstream gone and no PR merged into $default_branch matches tip ${tip:0:12} (a human decides)"
        fi
        refused=$((refused + 1))
        continue
    fi
    active=$((active + 1))
    # Only a branch with an upstream can have been classified from a tracking
    # ref, so only those make the freshness caveat relevant. Keying the caveat
    # on the aggregate count instead warned about ordinary local-only feature
    # branches, which no prune can affect — a warning that fires in the common
    # case is one nobody reads (Codex review on PR #991).
    #
    # The upstream REF, not merely its presence, and not %(upstream:track):
    # track is empty for a branch in sync with its upstream, so it cannot tell
    # "no upstream" from "up to date"; and presence alone counts a branch that
    # tracks another LOCAL branch (branch.<name>.remote=.), whose upstream is
    # under refs/heads/ and which no prune can affect.
    #
    # refs/remotes/ is the terminal test rather than another narrowing in a
    # series: `task clean:remote-refs` is `git fetch --all --prune`, so it
    # affects exactly the refs under that prefix — every one of them, and
    # nothing else. Whichever remote they belong to.
    case "$upstream_ref" in
    refs/remotes/*) active_tracked=$((active_tracked + 1)) ;;
    esac
done <"$tmp/branches"

# ── Act (or report) ─────────────────────────────────────────────────────────

# Deletion evidence is only as fresh as the local refs it was computed from,
# so --delete mode verifies the live remote once — a single bounded read-only
# `ls-remote --symref` — and fails closed on any mismatch or error:
#
#   * The remote's advertised HEAD must still name $default_branch
#     (challenge r4): after a default-branch rename, the obsolete branch can
#     survive remotely and pass a tip-equality check, authorizing deletions
#     against a base that is no longer the default. A mismatch refuses EVERY
#     deletion — PR evidence filtered on the stale base name is equally void.
#   * For ancestry evidence, the advertised default tip must equal the local
#     tracking ref (challenge r1): a force-pushed or repointed default can
#     leave refs/remotes/$remote/<default> vouching for commits the remote no
#     longer holds.
#
# The verified advertised OID is kept for delete_one to re-validate ancestry
# against (challenge r4): classification ran against whatever the tracking
# ref held THEN, and a concurrent fetch of a rewritten default can make the
# tip-equality check pass against a tip the candidate was never proven into.
remote_state_checked=false
default_ok=false
ancestry_ok=false
ancestry_advertised_oid=""
verify_remote_state() {
    if [ "$remote_state_checked" = true ]; then
        return 0
    fi
    remote_state_checked=true
    symref_out="$(net_probe git ls-remote --symref "$remote" HEAD \
        "refs/heads/$default_branch" 2>/dev/null)" || symref_out=""
    live_default="$(printf '%s\n' "$symref_out" |
        awk '$1 == "ref:" && $3 == "HEAD" { sub("^refs/heads/", "", $2); print $2; exit }')"
    advertised="$(printf '%s\n' "$symref_out" |
        awk -v r="refs/heads/$default_branch" '$1 != "ref:" && $2 == r { print $1; exit }')"
    if [ -n "$live_default" ] && [ "$live_default" = "$default_branch" ]; then
        default_ok=true
    elif [ -n "$live_default" ]; then
        echo "NOTE  the remote's default branch is now '$live_default', not '$default_branch' — refusing every deletion (git remote set-head $remote --auto && git fetch --prune $remote, then re-run)"
    fi
    if [ "$default_ok" = true ] && [ -n "$advertised" ] &&
        [ "$advertised" = "$(git rev-parse "$ancestry_target")" ]; then
        ancestry_ok=true
        ancestry_advertised_oid="$advertised"
    fi
}

# delete_one <branch> <tip> <evidence> <why> — runs in a SUBSHELL so a lock
# refusal (die) aborts this branch only. The whole check-then-delete sequence
# holds the per-branch lifecycle lock shared with worktree:new / worktree:rm
# (challenge r1): without it, a concurrent creation can claim the branch
# between the worktree re-check and the ref delete — stranding a live
# worktree on a deleted ref — or recreate the branch before the config sweep
# and have its fresh branch.<name> configuration erased.
# Exit codes: 0 deleted, 3 refused cleanly (message already printed),
# anything else = lock contention or fatal (die's message is on stderr).
delete_one() (
    branch="$1"
    tip="$2"
    evidence="$3"
    why="$4"
    # shellcheck source=scripts/worktree-lock.sh
    . "$REPO_ROOT/scripts/worktree-lock.sh"
    mkdir -p "$lock_root"
    trap release_locks EXIT
    trap 'exit 129' HUP INT TERM
    acquire_branch_lock "$branch"
    # Re-check checkout state under the lock: another session can have
    # claimed the branch since classification, and update-ref does not
    # respect git's checked-out guard.
    if git worktree list --porcelain | grep -Fxq "branch refs/heads/$branch"; then
        echo "SKIP  $branch — became checked out in a worktree since classification"
        exit 3
    fi
    # Re-validate ancestry against the VERIFIED advertised tip (challenge
    # r4): classification proved ancestry into whatever the tracking ref
    # held at scan time, and a concurrent fetch of a rewritten default can
    # satisfy the tip-equality check with a tip that no longer contains
    # this branch. The evidence must hold against the tip the deletion is
    # actually trusting.
    if [ "$evidence" = ancestry ] &&
        ! git merge-base --is-ancestor "refs/heads/$branch" "$ancestry_advertised_oid"; then
        echo "SKIP  $branch — no longer an ancestor of the verified remote default tip (default moved since classification)"
        exit 3
    fi
    # ONE deletion mechanism for both evidence classes: a guarded
    # compare-and-delete. `git branch -d` was deliberately dropped even for
    # the ancestry class (challenge r2): -d authorizes against the CURRENT
    # HEAD, so running cleanup from a divergent feature branch would refuse
    # a deletion the dry run promised — the authority here is the verified
    # evidence (fresh ancestry into the remote default, or a merged default-
    # base PR at exactly this tip), not the checkout. The old-value guard
    # makes it atomic: anything moving the branch since verification refuses
    # the delete. --no-deref as a belt behind the classification symref
    # skip: the named ref itself is what dies, never a target it points at.
    # LEFTHOOK=0: a reference-transaction hook must not fire on cleanup ref
    # writes (worktree-new.sh precedent).
    if ! LEFTHOOK=0 git update-ref --no-deref -d "refs/heads/$branch" "$tip" 2>/dev/null; then
        echo "SKIP  $branch — tip moved since verification (compare-and-delete refused)"
        exit 3
    fi
    # Clear the branch's config section, and never silently fail (challenge
    # r2): a locked or unwritable config would otherwise leave stale
    # branch.<name>.remote/merge settings for the next branch of this name
    # to inherit. Absence afterwards is the success condition — the section
    # legitimately may not exist at all.
    git config --local --remove-section "branch.$branch" 2>/dev/null || true
    # Exact-section match: a sibling branch named "$branch.<more>" flattens
    # to keys sharing this prefix, so the leftover check requires a key whose
    # remainder has no further dot (review r1).
    if git config --local --list --name-only 2>/dev/null |
        awk -v p="branch.$branch." 'index($0, p) == 1 { rest = substr($0, length(p) + 1); if (rest !~ /\./) found = 1 } END { exit !found }'; then
        echo "WARN  $branch was deleted but its branch.$branch.* config could not be removed — remove it by hand (git config --local --remove-section $(shell_quote "branch.$branch"))"
    fi
    echo "deleted  $branch (was ${tip}) — $why — recover: git branch $(shell_quote "$branch") ${tip:0:12}"
)

deleted=0
if [ -s "$tmp/candidates" ]; then
    while IFS=$'\t' read -r branch tip evidence pr; do
        case "$evidence" in
        ancestry) why="merged by ancestry into $remote/$default_branch" ;;
        pr) why="merged PR #$pr (head == tip)" ;;
        esac
        if [ "$do_delete" != true ]; then
            echo "WOULD DELETE  $branch (${tip:0:12}) — $why"
            continue
        fi
        verify_remote_state
        if [ "$default_ok" != true ]; then
            echo "SKIP  $branch — the remote's live default branch could not be verified as '$default_branch' (renamed default or unreachable remote; see NOTE above)"
            refused=$((refused + 1))
            continue
        fi
        if [ "$evidence" = ancestry ] && [ "$ancestry_ok" != true ]; then
            echo "SKIP  $branch — $remote/$default_branch is stale or unverifiable against the live remote (run 'task clean:remote-refs', then re-run)"
            refused=$((refused + 1))
            continue
        fi
        rc=0
        delete_one "$branch" "$tip" "$evidence" "$why" || rc=$?
        case "$rc" in
        0) deleted=$((deleted + 1)) ;;
        3) refused=$((refused + 1)) ;;
        *)
            echo "SKIP  $branch — the branch lifecycle lock refused (a worktree operation is active; details above)"
            refused=$((refused + 1))
            ;;
        esac
    done <"$tmp/candidates"
fi

# Every classification above reads LOCAL tracking refs, so a branch whose
# upstream was deleted on merge reads as neither [gone] nor unpushed and lands
# in `in-flight kept` — a bucket that means "deliberately left alone" rather
# than "I could not tell". Say so whenever that bucket is non-empty.
#
# Deliberately NOT a live probe. An earlier revision asked the remote which
# refs were stale, and the exactness cost more than it bought: the answer has
# to be captured atomically with the classification snapshot or a concurrent
# fetch silences it, it needs the HEAD symref to notice a renamed default, and
# it is meaningless under a non-identity fetch refspec. Six findings across two
# review rounds, all in the probe, none in the reporting this issue is about.
# The issue asks only that the task "performs, or explicitly reports the
# absence of" the check, and says a one-line note would be enough. This is that
# note: deterministic, no network, and impossible to race.
tracking_caveat() {
    [ "$active_tracked" -gt 0 ] || return 0
    # No count. The predicate below decides WHETHER this is relevant, and that
    # is worth getting right; the figure is not. It needed redefining four
    # times — the aggregate in-flight count, then upstream presence, then
    # %(upstream:track) versus presence, then local-upstream branches — and a
    # remote configured `skipFetchAll` would have made it wrong again, since
    # the remedy below is `fetch --all --prune` and that skips such a remote.
    # A sentence that names the condition needs none of those distinctions.
    echo "clean:branches: some branches kept as in-flight were classified from local tracking refs, and a branch whose upstream is already gone reads as in-flight until you prune. If in doubt, run 'task clean:remote-refs' — plus an explicit fetch for any remote set to skipFetchAll, which 'fetch --all' passes over — and re-run."
}

echo
if [ "$do_delete" = true ]; then
    echo "clean:branches: $deleted deleted, $refused skipped, $active in-flight kept, $total local branches scanned."
    tracking_caveat
else
    echo "clean:branches (dry run): $candidates deletable, $refused skipped, $active in-flight kept, $total local branches scanned."
    tracking_caveat
    if [ "$candidates" -gt 0 ]; then
        echo "Run 'task clean:branches -- --delete' to delete the branches listed above."
    fi
fi
