#!/usr/bin/env bash
# clean-worktree-records.sh — prune stale worktree ADMIN RECORDS only, never a
# worktree directory. Run via `task clean:worktree-records`.
#
# A raw `git worktree prune` is not safe here (harmon-init#838, challenge r3):
# a stale record's HEAD can be DETACHED at a commit no branch, tag or
# remote-tracking ref contains, in which case the record is the only thing
# keeping that commit alive — pruning it makes the commit unreachable and
# eventually GC-collectible.
#
# The design decisions, each deliberate (challenge r4-r7):
#
#   * Only records in git's own dry-run plan are removed, each one
#     individually, never via the global `git worktree prune` — a global
#     prune re-computes eligibility at its own moment, so a LIVE worktree
#     whose directory vanishes mid-run could be pruned on a stale HEAD
#     snapshot. A plan-verified stale record has no working directory, so
#     its HEAD cannot move. Live records are never touched, and git's own
#     `locked` marker is re-checked under the lock — a worktree locked
#     after the plan (removable media) stays preserved. A `git worktree
#     lock` racing the removal itself does not take the lifecycle lock;
#     that is the same native-command residual as raw `git worktree add`.
#   * Each removal runs under the same per-path lifecycle lock that
#     worktree:new / worktree:rm hold (for trees under the blessed
#     .worktrees layout), so a removal cannot race a re-creation of the
#     same path by the blessed tooling. Raw `git worktree add` outside the
#     tooling remains the documented residual.
#   * A record that carries worktree-local state is refused, never swept:
#     review sidecars, per-worktree ref files, in-progress operation state
#     (rebase/merge/cherry-pick — the worktree-rm.sh list), and an index
#     that diverges from the recorded HEAD (staged-but-uncommitted blobs
#     the index alone keeps alive). An unreadable HEAD refuses outright,
#     and ORIG_HEAD and FETCH_HEAD — ref files, not reflogs — refuse when
#     they name a commit no shared ref contains. Reflogs are deliberately NOT state —
#     every record has one, and accepting reflog loss matches git's own
#     prune semantics.
#   * A detached record HEAD is pinned as refs/session-cleanup/pin/<record>
#     BEFORE its record is removed, with a CREATE-ONLY ref write; an
#     existing mismatched pin from an earlier run refuses that record. Pins
#     are removed only by EXPLICIT human settlement — an auto-drop races
#     concurrent ref deletion — and the run exits nonzero while any await
#     action, prior runs' pins included. The pin is re-asserted after the
#     removal (a racing settlement could drop it in the window), and its
#     drop remedy instructs re-verification, never asserts present safety.
#     Nothing is ever lost.
#   * The pin report judges RAW history: replacement refs are disabled for
#     the whole run and a legacy graft file forces the conservative wording,
#     because a forged "also reachable from shared refs" would hand the
#     human a copyable command that drops the only real reference.
#   * The sweep is allowlist-gated: a record is removed only when every
#     entry in its admin dir is known to this tool — validated, refused
#     when carried, or accepted by design (reflogs). Unknown entries
#     refuse, so a git version that grows new state files fails closed
#     instead of being silently swept.
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

# Replacement refs rewrite parentage cosmetically; the pin report below must
# judge RAW history (challenge r8, ported at resurrection: harmon-init#945) —
# a refs/replace graft could make an orphaned commit read as reachable from
# shared refs, and the printed remedy would then invite dropping the pin that
# holds its only real reference.
export GIT_NO_REPLACE_OBJECTS=1

die() {
    echo "clean:worktree-records: $*" >&2
    exit 1
}

# POSIX shell-quote for values echoed into copyable commands: refnames and
# record names legally carry shell metacharacters (challenge r7; same class
# as worktree-new.sh's printed remedies).
shell_quote() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# Refs that would STILL reference a commit once the record is gone — the same
# exclusion set as worktree-rm.sh (per-worktree refs vanish with their
# worktree), plus this script's own pin namespace: a pin must never vouch for
# the commit it exists to protect. refs/replace/ is excluded for the same
# reason GIT_NO_REPLACE_OBJECTS is exported: a replacement's synthetic commit
# contains the grafted-in parent in RAW history, so the ref itself would
# vouch for exactly the commit the forgery targets.
shared_refs_containing() {
    git for-each-ref --contains "$1" --format='%(refname)' 2>/dev/null |
        grep -Ev '^refs/((worktree|bisect|rewritten|replace)/|session-cleanup/pin/)' || true
}

common="$(git rev-parse --path-format=absolute --git-common-dir)"

# The blessed-path anchor is the registry's first entry — the SAME source
# worktree-new.sh reads to place .worktrees/, because these locks only
# serialize anything if both sides key identically. Empirically git derives
# this entry as ${common%/.git} in every layout we could produce
# (separate-git-dir included), so this is consistency by construction with
# the peer tool rather than a behavioral change: if git's registry
# computation ever shifts, both tools move together (challenge r2).
main_root="$(git worktree list --porcelain | sed -n '1s/^worktree //p')"

# Legacy graft files rewrite parentage exactly as replace refs do, but
# GIT_NO_REPLACE_OBJECTS does NOT disable them (review r1, ported at
# resurrection): containment walked over grafted history is not evidence, so
# while one exists every kept pin gets the conservative wording — never the
# "also reachable, drop it" remedy.
grafts_present=false
grafts_file="$(git rev-parse --git-path info/grafts)"
if [ -s "$grafts_file" ]; then
    grafts_present=true
    echo "NOTE  legacy graft file present ($grafts_file) — shared-ref containment is unusable while it exists; kept pins are reported conservatively"
fi

# The header's contract: the run stays nonzero while ANY pin awaits human
# settlement — including pins left by an earlier run, which an otherwise
# empty retry would otherwise report as "cleanup complete" (challenge r1).
# --count=1 avoids a git|head pipeline, which pipefail turns into SIGPIPE.
pins_outstanding() {
    git for-each-ref --count=1 refs/session-cleanup/pin --format='%(refname)'
}

finish_no_work() {
    # Enumeration failure is not an empty namespace: a broken ref backend
    # must never let the run report cleanup complete (challenge r4).
    outstanding="$(pins_outstanding)" || die "cannot enumerate rescue pins (refs/session-cleanup/pin unreadable); refusing to report cleanup complete"
    if [ -n "$outstanding" ]; then
        echo "clean:worktree-records: nothing to prune, but rescue pins await settlement (task audit:session-artifacts lists them)." >&2
        exit 2
    fi
    echo "clean:worktree-records: nothing to prune."
    exit 0
}

# git's own dry run is the authority on what is prunable
# ("Removing worktrees/<name>: <reason>"); LC_ALL=C pins the message shape.
# A failed dry run must surface git's own diagnostic, not a bare set -e
# death (review r2).
if ! prune_plan="$(LC_ALL=C git worktree prune --dry-run -v 2>&1)"; then
    die "git worktree prune --dry-run failed: $prune_plan"
fi
if [ -z "$prune_plan" ]; then
    finish_no_work
fi

# remove_one_record <record> — runs in a SUBSHELL so a lock refusal (die)
# aborts this record only. Every validation runs UNDER the lock (challenge
# r7): checked outside it, worktree:rm clearing the record and worktree:new
# recreating the same path could interleave before the rm -rf and lose a
# live record. Exit codes: 0 removed, 2 removed with a pin awaiting
# settlement, 3 refused cleanly (message printed), else lock/fatal.
remove_one_record() (
    record="$1"
    admin_dir="$common/worktrees/$record"
    # shellcheck source=scripts/worktree-lock.sh
    . "$REPO_ROOT/scripts/worktree-lock.sh"
    trap release_locks EXIT
    trap 'exit 129' HUP INT TERM
    wt_gitfile="$(cat "$admin_dir/gitdir" 2>/dev/null || true)"
    tree_path="${wt_gitfile%/.git}"
    case "$tree_path" in
    "$main_root/.worktrees/"*)
        acquire_path_locks "${tree_path#"$main_root/.worktrees/"}"
        ;;
    esac

    [ -d "$admin_dir" ] || exit 3 # already gone (another cleaner won)
    # Re-read under the lock — failing closed when the gitdir file cannot
    # be read to a value: an unreadable target is not an absent worktree,
    # and sweeping on that guess can orphan a live tree (challenge r7).
    if ! wt_gitfile="$(cat "$admin_dir/gitdir" 2>/dev/null)" || [ -z "$wt_gitfile" ]; then
        echo "SKIP  record '$record' — cannot read its gitdir file; refusing to sweep an unvalidatable record (inspect $admin_dir)"
        exit 3 # unreadable gitdir refuses
    fi
    # The lock above was keyed off a PRE-lock read; if the gitdir changed
    # while the lock was being approached (a record replaced mid-plan), the
    # held key may be wrong or missing — refuse, and let a re-run evaluate
    # the new record under the right lock (review r1).
    if [ "${wt_gitfile%/.git}" != "$tree_path" ]; then
        echo "SKIP  record '$record' — its gitdir changed while the lock was being acquired; re-run to re-evaluate"
        exit 3 # lock-key drift refuses
    fi
    # If the gitdir target exists again (a worktree recreated at the old
    # path), the record is live — leave it.
    if [ -e "$wt_gitfile" ]; then
        echo "SKIP  record '$record' — its worktree reappeared since the plan"
        exit 3
    fi
    # A surviving worktree DIRECTORY whose .git link is gone still holds
    # the user's files; sweeping its record would orphan them as a plain
    # directory nothing tracks (challenge r7). A gitdir value that does not
    # end in /.git is malformed — and would silently skip this very guard —
    # so it refuses outright (shepherd r1).
    tree_dir="${wt_gitfile%/.git}"
    if [ "$tree_dir" = "$wt_gitfile" ]; then
        echo "SKIP  record '$record' — its gitdir value does not end in /.git (malformed); refusing to sweep an unvalidatable record (inspect $admin_dir/gitdir)"
        exit 3 # malformed gitdir suffix refuses
    fi
    if [ -d "$tree_dir" ]; then
        echo "SKIP  record '$record' — its worktree directory still exists ($tree_dir) though the .git link is gone; restore the link or move the directory aside first"
        exit 3 # surviving tree dir refuses
    fi

    # git's own worktree lock (worktrees/<id>/locked) protects e.g. a tree on
    # removable media; the plan predates it, so re-check under our lifecycle
    # lock — git preserves locked records and so must we (challenge r1).
    if [ -e "$admin_dir/locked" ]; then
        echo "SKIP  record '$record' — locked by git worktree lock since the plan (git worktree unlock, or remove $admin_dir/locked, to release)"
        exit 3
    fi

    # Single-copy worktree-local state is refused, never swept. The op-state
    # names mirror worktree-rm.sh: a rebase/merge/cherry-pick parked at an
    # edit leaves sequencer state — and, after an amend there, commits —
    # nothing else references (challenge r1).
    carried=""
    # config.worktree and info/sparse-checkout carry user-set per-worktree
    # configuration (extensions.worktreeConfig, sparse patterns) — the same
    # adopt-or-rescue class as the review sidecars, and present only on
    # worktreeConfig-enabled records, so refusing costs no sweepability
    # (challenge r5, reversing r2's "dead config" declination).
    # MERGE_AUTOSTASH extends the worktree-rm.sh op-state list: a merge
    # --autostash killed before MERGE_HEAD exists leaves the user's dirty
    # work referenced by that one file alone (challenge r6).
    for sub in deferred-findings adjudication-ledger shepherd-codex refs rebase-merge rebase-apply MERGE_HEAD MERGE_AUTOSTASH CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG config.worktree info/sparse-checkout; do
        # A symlinked state path is carried state whatever it points at —
        # find would scan the target (or nothing, broken), not the link
        # (challenge r7).
        if [ -L "$admin_dir/$sub" ]; then
            carried="$carried $sub"
            continue
        fi
        [ -e "$admin_dir/$sub" ] || continue
        # A failed scan is not an empty scan: treating an errored find as
        # "no state" would sweep exactly the record it could not inspect
        # (challenge r3).
        if ! state_scan="$(find "$admin_dir/$sub" -type f 2>&1)"; then
            echo "SKIP  record '$record' — cannot scan $sub for worktree-local state ($state_scan); failing closed"
            exit 3
        fi
        [ -z "$state_scan" ] || carried="$carried $sub"
    done
    if [ -n "$carried" ]; then
        echo "SKIP  record '$record' — carries worktree-local state (${carried# }); adopt or rescue it first, it exists nowhere else"
        exit 3
    fi

    # Fail closed by construction: a record is swept only when EVERY entry
    # in its admin dir is known to this tool — validated below, refused
    # above when carried, or accepted by design (reflogs). Git grows state
    # files over time and an enumeration of dangerous ones can only lose
    # that game; the unknown refuses instead (challenge r6 restructure,
    # maintainer-approved).
    for entry in "$admin_dir"/* "$admin_dir"/.[!.]* "$admin_dir"/..?*; do
        [ -e "$entry" ] || [ -L "$entry" ] || continue # -e dereferences: a broken symlink must still be judged
        entry_name="${entry##*/}"
        case "$entry_name" in
        gitdir | commondir | HEAD | locked | COMMIT_EDITMSG | ORIG_HEAD | FETCH_HEAD | index)
            # Validated by the guards here or disposable scratch — but only
            # as the regular files git writes: a directory or symlink in one
            # of these slots would skip its -f validator yet still be
            # rm -rf'd with the record (challenge r8).
            if [ ! -f "$entry" ] || [ -L "$entry" ]; then
                echo "SKIP  record '$record' — entry '$entry_name' is not the regular file git writes there; refusing to sweep malformed state (inspect $admin_dir)"
                exit 3 # type mismatch refuses
            fi
            ;;
        logs)
            # Reflogs (accepted loss by design) — as the directory git
            # writes, same type gate as above.
            if [ ! -d "$entry" ] || [ -L "$entry" ]; then
                echo "SKIP  record '$record' — entry 'logs' is not the directory git writes there; refusing to sweep malformed state (inspect $admin_dir)"
                exit 3 # type mismatch refuses
            fi
            ;;
        deferred-findings | adjudication-ledger | shepherd-codex | refs | rebase-merge | rebase-apply | MERGE_HEAD | MERGE_AUTOSTASH | CHERRY_PICK_HEAD | REVERT_HEAD | BISECT_LOG | config.worktree) : ;; # carried-state names: the scan above refused them when non-empty
        info)
            # As a regular file or symlink, the child globs below match
            # nothing and the entry would be accepted uninspected
            # (shepherd r1) — the same type gate the other slots carry.
            if [ ! -d "$entry" ] || [ -L "$entry" ]; then
                echo "SKIP  record '$record' — entry 'info' is not the directory git writes there; refusing to sweep malformed state (inspect $admin_dir)"
                exit 3 # info type mismatch refuses
            fi
            for info_entry in "$entry"/* "$entry"/.[!.]* "$entry"/..?*; do
                [ -e "$info_entry" ] || [ -L "$info_entry" ] || continue
                case "${info_entry##*/}" in
                sparse-checkout) : ;; # refused above when present with content
                *)
                    echo "SKIP  record '$record' — unrecognized entry info/${info_entry##*/}; refusing to sweep what this tool does not understand (inspect $admin_dir)"
                    exit 3 # unknown info entry refuses
                    ;;
                esac
            done
            ;;
        *)
            echo "SKIP  record '$record' — unrecognized entry '$entry_name'; refusing to sweep what this tool does not understand (inspect $admin_dir)"
            exit 3 # unknown entry refuses
            ;;
        esac
    done

    record_head="$(cat "$admin_dir/HEAD" 2>/dev/null || true)"

    # A record whose HEAD cannot be read would fall through every
    # HEAD-derived guard below and sweep unpinned; an unvalidatable record
    # is refused, never swept (challenge r2).
    if [ -z "$record_head" ]; then
        echo "SKIP  record '$record' — cannot read its HEAD; refusing to sweep an unvalidatable record (inspect $admin_dir)"
        exit 3
    fi

    # ORIG_HEAD is a ref file, not a reflog: a reset --hard's abandoned
    # commit can live in this one file alone, so reflog accepted-loss does
    # not cover it. A reachable ORIG_HEAD sweeps normally (every used tree
    # has one); unreachable or unreadable refuses — and a legacy graft file
    # makes containment unusable, so it refuses too (challenge r2).
    if [ -f "$admin_dir/ORIG_HEAD" ]; then
        orig_head="$(cat "$admin_dir/ORIG_HEAD" 2>/dev/null || true)"
        orig_commit=""
        [ -z "$orig_head" ] || orig_commit="$(git rev-parse --quiet --verify "$orig_head^{commit}" || true)"
        if [ -z "$orig_commit" ]; then
            echo "SKIP  record '$record' — its ORIG_HEAD is unreadable or names no commit; refusing to sweep (inspect $admin_dir/ORIG_HEAD)"
            exit 3
        fi
        if [ "$grafts_present" = true ] || [ -z "$(shared_refs_containing "$orig_commit")" ]; then
            echo "SKIP  record '$record' — ORIG_HEAD $orig_commit is reachable from no shared ref, or containment is unusable under a legacy graft file (a reset/rebase abandoned it here); rescue it (git branch $(shell_quote "rescue/$record-orig") $orig_commit) then remove $admin_dir/ORIG_HEAD"
            exit 3
        fi
    fi

    # FETCH_HEAD can hold the only mapping to a URL-fetched, unbranched tip
    # (a PR head). Ordinary fetches list tips the remote-tracking refs
    # contain, so — exactly as with ORIG_HEAD — only an unreadable,
    # unresolvable, or unreachable entry refuses; the conditional guard has
    # none of the unsweepability cost an unconditional refusal would
    # (challenge r4, revising r3's declination of the unconditional form).
    if [ -f "$admin_dir/FETCH_HEAD" ]; then
        # `|| [ -n ... ]`: a truncated write can leave the final record
        # unterminated, and a plain read would skip exactly that entry
        # (challenge r5).
        while IFS= read -r fetch_line || [ -n "$fetch_line" ]; do
            [ -n "$fetch_line" ] || continue
            fetch_sha="${fetch_line%%[[:space:]]*}"
            # An annotated tag fetched without a destination ref is its own
            # object: peeling to the commit would let the tag body (message,
            # signature) vanish with the record. Exact points-at containment
            # — object equality, so ancestry forgery does not apply
            # (challenge r6).
            fetch_type=""
            [ -z "$fetch_sha" ] || fetch_type="$(git cat-file -t "$fetch_sha" 2>/dev/null || true)"
            if [ "$fetch_type" = "tag" ]; then
                if [ -z "$(git for-each-ref --points-at "$fetch_sha" --format='%(refname)' 2>/dev/null | grep -Ev '^refs/((worktree|bisect|rewritten|replace)/|session-cleanup/pin/)' || true)" ]; then
                    echo "SKIP  record '$record' — FETCH_HEAD names annotated tag object $fetch_sha with no ref pointing at it; rescue it (git tag $(shell_quote "rescue/$record-fetch-tag-$(printf '%.7s' "$fetch_sha")") $fetch_sha) then remove $admin_dir/FETCH_HEAD"
                    exit 3
                fi
                continue
            fi
            fetch_commit=""
            [ -z "$fetch_sha" ] || fetch_commit="$(git rev-parse --quiet --verify "$fetch_sha^{commit}" || true)"
            if [ -z "$fetch_commit" ]; then
                echo "SKIP  record '$record' — FETCH_HEAD entry '$fetch_sha' is unreadable or names no commit; refusing to sweep (inspect $admin_dir/FETCH_HEAD)"
                exit 3
            fi
            if [ "$grafts_present" = true ] || [ -z "$(shared_refs_containing "$fetch_commit")" ]; then
                echo "SKIP  record '$record' — FETCH_HEAD names $fetch_commit, reachable from no shared ref (a URL fetch left it here); rescue it (git branch $(shell_quote "rescue/$record-fetch-$(printf '%.7s' "$fetch_commit")") $fetch_commit) then remove $admin_dir/FETCH_HEAD"
                exit 3
            fi
        done <"$admin_dir/FETCH_HEAD"
    fi

    # The index can be the only structure referencing staged-but-uncommitted
    # blobs (challenge r7): an index that diverges from the recorded HEAD —
    # or that cannot be verified against it — is state, and refused.
    if [ -f "$admin_dir/index" ]; then
        head_commit=""
        case "$record_head" in
        ref:*) head_commit="$(git rev-parse --quiet --verify "${record_head#ref: }^{commit}" || true)" ;;
        '') : ;;
        *) head_commit="$(git rev-parse --quiet --verify "$record_head^{commit}" || true)" ;;
        esac
        if [ -z "$head_commit" ] ||
            ! GIT_INDEX_FILE="$admin_dir/index" git diff-index --cached --quiet "$head_commit" 2>/dev/null; then
            echo "SKIP  record '$record' — its index diverges from the recorded HEAD (staged-only changes, or unverifiable); recover them first (GIT_INDEX_FILE=$(shell_quote "$admin_dir/index") git checkout-index ...), then remove the index file"
            exit 3
        fi
        # A stage-0-clean index can still carry resolve-undo entries whose
        # conflict-stage blobs it alone references; an uninspectable index
        # refuses the same way an unscannable state dir does (challenge r7).
        if ! resolve_undo="$(GIT_INDEX_FILE="$admin_dir/index" git ls-files --resolve-undo 2>&1)"; then
            echo "SKIP  record '$record' — cannot inspect its index for resolve-undo state ($resolve_undo); failing closed"
            exit 3 # resolve-undo-inspect refuses
        fi
        if [ -n "$resolve_undo" ]; then
            echo "SKIP  record '$record' — its index carries resolve-undo (conflict) state the index alone references; recover it (GIT_INDEX_FILE=$(shell_quote "$admin_dir/index") git ls-files --resolve-undo), then remove the index file"
            exit 3 # resolve-undo refuses
        fi
    fi

    pinned_here=false
    case "$record_head" in
    ref:* | '') : ;; # attached to a branch: the branch keeps the commits
    *)
        if git rev-parse --quiet --verify "$record_head^{commit}" >/dev/null 2>&1; then
            existing_pin="$(git rev-parse --quiet --verify "refs/session-cleanup/pin/$record" || true)"
            if [ -n "$existing_pin" ] && [ "$existing_pin" != "$record_head" ]; then
                echo "SKIP  record '$record' — refs/session-cleanup/pin/$record already pins $existing_pin from an earlier run; settle it first (git branch $(shell_quote "rescue/$record") $existing_pin, or git update-ref -d $(shell_quote "refs/session-cleanup/pin/$record") $existing_pin)"
                exit 3
            fi
            # Create-only (old value ''): never overwrite a pin this run did
            # not just verify.
            if ! LEFTHOOK=0 git update-ref "refs/session-cleanup/pin/$record" "$record_head" "${existing_pin:-}"; then
                echo "SKIP  record '$record' — cannot pin detached commit $record_head; refusing to remove it unprotected"
                exit 3
            fi
            pinned_here=true
        else
            # A nonempty detached HEAD that resolves to no commit — a
            # truncated file, a missing or promisor-held object — cannot be
            # pinned, and sweeping would destroy the only recovery
            # breadcrumb; refuse instead of falling through (challenge r3).
            echo "SKIP  record '$record' — its detached HEAD $record_head does not resolve to a commit (missing or corrupt object); refusing to sweep the only reference"
            exit 3 # unresolvable HEAD refuses
        fi
        ;;
    esac

    # Records only: the stale admin directory is all that goes. A failed
    # removal is its own loud outcome, never mislabeled as lock contention
    # (challenge r1).
    if ! rm -rf "$admin_dir"; then
        echo "ERROR  record '$record' — removal failed midway; inspect $admin_dir before re-running"
        exit 4
    fi
    echo "pruned record '$record'"

    if [ "$pinned_here" = true ]; then
        pin_ref="refs/session-cleanup/pin/$record"
        # The pin must have outlived the removal AND still target the
        # detached commit: the audit advertises pins, so a settlement can
        # race this run — a dropped pin is re-asserted, and a retargeted
        # one fails closed rather than being overwritten or reported kept
        # (challenge r1, tightened r2: existence alone verifies nothing).
        pin_now="$(git rev-parse --quiet --verify "$pin_ref" || true)"
        if [ -z "$pin_now" ]; then
            if ! LEFTHOOK=0 git update-ref "$pin_ref" "$record_head" ""; then
                echo "CRITICAL  $pin_ref vanished during the prune and could not be recreated — rescue detached commit $record_head NOW: git branch $(shell_quote "rescue/$record") $record_head"
                exit 5
            fi
        elif [ "$pin_now" != "$record_head" ]; then
            # The record is already gone, so the commit must not ride on the
            # human seeing the diagnostic alone: best-effort re-protect under
            # a fresh unique name — create-only, so the foreign write to the
            # original pin is never overwritten (challenge r8).
            rescue_ref="refs/session-cleanup/pin/$record-rescue-$(printf '%.7s' "$record_head")"
            LEFTHOOK=0 git update-ref "$rescue_ref" "$record_head" "" 2>/dev/null || true
            echo "CRITICAL  $pin_ref no longer pins $record_head (it now holds $pin_now) — a rescue ref was created at $rescue_ref if possible (verify: git rev-parse $(shell_quote "$rescue_ref")); rescue the detached commit NOW: git branch $(shell_quote "rescue/$record") $record_head"
            exit 5
        fi
        # Reporting only — pins are settled by humans, never auto-dropped
        # (challenge r6): the reachability check picks the wording, and a
        # race can at worst mislabel, never delete. The wording never asserts
        # PRESENT safety: reachability is a prune-time snapshot, so the drop
        # remedy instructs re-verification first (challenge r1).
        if [ "$grafts_present" = false ] && [ -n "$(shared_refs_containing "$record_head")" ]; then
            # Every printed drop remedy carries the expected OID: update-ref
            # -d with an old value is compare-and-delete, so a stale command
            # re-run after record-name reuse cannot delete a newer pin
            # (challenge r3).
            echo "PINNED  $pin_ref — $record_head was reachable from shared refs at prune time; re-verify before dropping (GIT_GRAFT_FILE=/dev/null git --no-replace-objects for-each-ref --contains $record_head refs/heads refs/tags refs/remotes), then: git update-ref -d $(shell_quote "$pin_ref") $record_head"
        else
            echo "KEPT  $pin_ref — pruned record '$record' held the only reference to detached commit $record_head; branch it (git branch $(shell_quote "rescue/$record") $record_head) or discard it (git update-ref -d $(shell_quote "$pin_ref") $record_head)"
        fi
        exit 2
    fi
)

removed=0
skipped=0
errors=0
pins_pending=0
while IFS= read -r line; do
    record="$(printf '%s\n' "$line" | sed -n 's/^Removing worktrees\/\(.*\): .*$/\1/p')"
    [ -n "$record" ] || continue
    rc=0
    remove_one_record "$record" || rc=$?
    case "$rc" in
    0) removed=$((removed + 1)) ;;
    2)
        removed=$((removed + 1))
        pins_pending=$((pins_pending + 1))
        ;;
    3) skipped=$((skipped + 1)) ;;
    4 | 5) errors=$((errors + 1)) ;; # own message printed above; never lock-labeled
    *)
        echo "SKIP  record '$record' — the worktree lifecycle lock refused, or an unexpected failure (details above)"
        skipped=$((skipped + 1))
        ;;
    esac
done <<EOF
$prune_plan
EOF

if [ "$removed" -eq 0 ] && [ "$skipped" -eq 0 ] && [ "$errors" -eq 0 ]; then
    finish_no_work
fi
if [ "$errors" -gt 0 ]; then
    echo "clean:worktree-records: $removed record(s) pruned; $errors record removal(s) FAILED above — resolve before re-running." >&2
    exit 1
fi
outstanding="$(pins_outstanding)" || die "cannot enumerate rescue pins (refs/session-cleanup/pin unreadable); refusing to report cleanup complete"
if [ "$pins_pending" -gt 0 ] || [ "$skipped" -gt 0 ] || [ -n "$outstanding" ]; then
    # Total, not just this run's: a pin inherited from an earlier run is
    # exactly as much awaiting settlement as a fresh one, and printing "0"
    # beside a nonzero exit contradicts the disposition (challenge r4).
    total_pins="$(git for-each-ref refs/session-cleanup/pin --format='%(refname)' | wc -l | tr -d ' ')" || die "cannot enumerate rescue pins (refs/session-cleanup/pin unreadable); refusing to report an unreliable settlement count"
    echo "clean:worktree-records: $removed record(s) pruned; $pins_pending new pin(s) this run, $total_pins total awaiting settlement, $skipped record(s) refused above." >&2
    exit 2
fi
echo "clean:worktree-records: stale records pruned (worktree directories are never touched)."
