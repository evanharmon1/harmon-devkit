#!/usr/bin/env bash
# audit-session-artifacts.sh — report every session leftover in one place,
# mutating nothing. Run via `task audit:session-artifacts`.
#
# Companion to clean-branches.sh (harmon-init#838): this script only reports —
# no deletion, no fetch, no ref write, ever. The sections, in the order a
# human should read them:
#
#   1. branches with UNPUSHED commits — work about to be lost silently
#   2. gone-upstream branches, classified by merged-PR evidence
#   3. worktrees other than this one — named, never touched
#   4. review sidecars (deferred-findings / adjudication-ledger) left behind
#   5. shepherd Codex cycle-state files
#   6. totals, so branch creep stays visible
#
# Squash-merge context: `git branch --merged` cannot see a squash-merged
# branch, so classification asks the PR API (one batched read). Where gh is
# unavailable the classification is reported UNVERIFIED, never "clean".
set -euo pipefail

# Replacement refs rewrite parentage cosmetically; evidence and reporting must
# judge RAW history — a refs/replace graft could make an unmerged branch read
# as an ancestor of the default branch (challenge r8). Ignoring replacements
# is the fail-closed direction: a grafted-in branch is kept, never deleted.
export GIT_NO_REPLACE_OBJECTS=1

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/audit-session.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

section() {
    printf '\n== %s ==\n' "$1"
}

# Bounded network probes (status.sh precedent — a hung gh call must not wedge
# the report; stock macOS gets `timeout` from coreutils).
TIMEOUT_BIN=""
if command -v timeout >/dev/null 2>&1; then
    TIMEOUT_BIN=timeout
elif command -v gtimeout >/dev/null 2>&1; then
    TIMEOUT_BIN=gtimeout
else
    echo "audit:session-artifacts: no 'timeout' found (brew install coreutils) — network probes are unbounded." >&2
fi

# net_probe <cmd...> — bounded, stdin-closed network invocation (gh or git).
net_probe() {
    if [ -n "$TIMEOUT_BIN" ]; then
        "$TIMEOUT_BIN" -k 5 "${GH_TIMEOUT:-30}" "$@" </dev/null
    else
        "$@" </dev/null
    fi
}

# %(refname:lstrip=2), not %(refname:short): when a tag shares a branch's
# name, :short disambiguates to "heads/<name>" and every "refs/heads/$branch"
# built from it dereferences nothing (challenge r1).
# Sentinels on the optionally-empty fields: tab is IFS whitespace, so `read`
# would COLLAPSE an empty middle field and shift %(symref) into the track
# column. Same hazard, same fix, as clean-branches.sh.
git for-each-ref refs/heads \
    --format='%(refname:lstrip=2)%09%(objectname)%09%(if)%(upstream:track)%(then)%(upstream:track)%(else)-%(end)%09%(if)%(symref)%(then)%(symref)%(else)-%(end)' \
    >"$tmp/branches"
total_branches="$(wc -l <"$tmp/branches" | tr -d ' ')"

has_remote=true
[ -n "$(git remote)" ] || has_remote=false

# One remote and its default branch, resolved once: origin preferred, else
# the first listed. The default branch scopes the merged-PR evidence below —
# only a merge into it proves durable delivery (challenge r2).
remote=""
default_branch=""
if [ "$has_remote" = true ]; then
    remote="$(git remote | head -n 1)"
    if git remote | grep -qx origin; then
        remote=origin
    fi
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
fi

# ── 1. Unpushed work ────────────────────────────────────────────────────────

section "Branches with unpushed commits (work on no remote)"
if [ "$has_remote" = false ]; then
    echo "No remote configured — every local commit is unpushed by definition; listing skipped."
else
    unpushed_count=0
    while IFS=$'\t' read -r branch _tip _track _symref; do
        n="$(git rev-list --count "refs/heads/$branch" --not --remotes --)"
        if [ "$n" -gt 0 ]; then
            printf '  %s — %s commit(s) on no remote\n' "$branch" "$n"
            unpushed_count=$((unpushed_count + 1))
        fi
    done <"$tmp/branches"
    if [ "$unpushed_count" -eq 0 ]; then
        echo "  none"
    fi
fi

# ── 1b. Remote-tracking freshness ───────────────────────────────────────────

# Every judgement above and below is only as fresh as the tracking refs: a
# remote branch deleted upstream (e.g. GitHub's delete-on-merge) is invisible
# here until a fetch --prune — its local branch reads neither [gone] nor
# unpushed (challenge r2). One bounded read of the remote's advertised heads
# makes that staleness explicit instead of silent.
freshness_indeterminate=0
section "Remote-tracking freshness"
if [ "$has_remote" = false ]; then
    echo "  n/a — no remote configured"
elif net_probe git ls-remote --symref "$remote" HEAD "refs/heads/*" >"$tmp/remote-heads-raw" 2>/dev/null; then
    # The same advertisement also names the LIVE default branch (challenge
    # r5): a renamed default with a stale local origin/HEAD would otherwise
    # classify PRs against the obsolete base below. The live name wins.
    stale=0
    live_default="$(awk '$1 == "ref:" && $3 == "HEAD" { sub("^refs/heads/", "", $2); print $2; exit }' \
        "$tmp/remote-heads-raw")"
    if [ -n "$live_default" ] && [ -n "$default_branch" ] && [ "$live_default" != "$default_branch" ]; then
        printf "  stale  the remote's default branch is now '%s', not '%s' — classification below uses '%s'\n" \
            "$live_default" "$default_branch" "$live_default"
        default_branch="$live_default"
        stale=$((stale + 1))
    elif [ -n "$live_default" ] && [ -z "$default_branch" ]; then
        # No local record at all (origin/HEAD unset, default neither main nor
        # master): the successful advertisement is the answer, not a reason
        # to report UNVERIFIED (review r1).
        printf "  note   no local default-branch record — using the remote's advertised '%s'\n" "$live_default"
        default_branch="$live_default"
    fi
    awk '$1 != "ref:" && $2 != "HEAD"' "$tmp/remote-heads-raw" >"$tmp/remote-heads"
    # A tracking ref names `refs/heads/<same name>` only under the identity
    # fetch refspec. Under `refs/heads/*:refs/remotes/origin/upstream/*`, or
    # with extra refspecs pulling in e.g. pull refs, the local name is a
    # DESTINATION — comparing it marks fresh refs stale and recommends a prune
    # that can never clear the report. Say nothing rather than something false
    # (found in clean:branches by challenge r1 on #958; the same expression was
    # copied from here, so both are corrected together).
    audit_fetch_specs="$(git config --get-all "remote.$remote.fetch" 2>/dev/null || true)"
    if [ "$audit_fetch_specs" != "+refs/heads/*:refs/remotes/$remote/*" ] &&
        [ "$audit_fetch_specs" != "refs/heads/*:refs/remotes/$remote/*" ]; then
        echo "  n/a — $remote is fetched under a non-identity refspec, so a tracking name does not identify a remote branch"
        : >"$tmp/tracking"
        freshness_indeterminate=1
    else
        # Full refname with a dynamic strip, not %(refname:lstrip=3): a remote
        # name may itself contain slashes, and a fixed strip depth would mangle
        # every tracking ref into a false "deleted upstream" (review r2).
        git for-each-ref "refs/remotes/$remote" \
            --format='%(refname)%09%(objectname)%09%(if)%(symref)%(then)%(symref)%(else)-%(end)' \
            >"$tmp/tracking"
        while IFS=$'\t' read -r tref toid tsymref; do
            [ "$tsymref" = "-" ] || continue
            tname="${tref#refs/remotes/$remote/}"
            live_oid="$(awk -v r="refs/heads/$tname" '$2 == r { print $1; exit }' "$tmp/remote-heads")"
            if [ -z "$live_oid" ]; then
                printf '  stale  %s — deleted upstream; local tracking ref survives until a prune\n' "$tname"
                stale=$((stale + 1))
            elif [ "$live_oid" != "$toid" ]; then
                printf '  stale  %s — moved upstream (local tracking is behind or diverged)\n' "$tname"
                stale=$((stale + 1))
            fi
        done <"$tmp/tracking"
    fi
    if [ "${freshness_indeterminate:-0}" -eq 1 ]; then
        # Nothing was compared, so "fresh" would contradict the n/a above and
        # claim a verification that did not happen (challenge r2).
        :
    elif [ "$stale" -eq 0 ]; then
        echo "  fresh — local tracking refs match the remote's advertised heads"
    else
        echo "  -> $stale stale tracking ref(s): run 'task clean:remote-refs' (git fetch --prune), then re-run this audit"
    fi
else
    echo "  UNVERIFIED — could not read the remote's advertised heads; every section below trusts possibly-stale tracking refs"
fi

# ── 2. Gone-upstream classification ─────────────────────────────────────────

section "Branches whose upstream is gone"
awk -F'\t' '$3 == "[gone]" { print $1 "\t" $2 "\t" $4 }' "$tmp/branches" >"$tmp/gone"
gone_count="$(wc -l <"$tmp/gone" | tr -d ' ')"
if [ "$gone_count" -eq 0 ]; then
    echo "  none"
else
    # One batched read of merged PRs, matched locally. Tip equality decides
    # "prunable" — a recycled branch name can match an old PR by name alone —
    # and so does the base: only a PR merged into the default branch proves
    # durable delivery, since a stacked base can be deleted with the merge
    # result in it (challenge r2).
    gh_repo=""
    if command -v gh >/dev/null 2>&1 && [ "$has_remote" = true ] && [ -n "$default_branch" ]; then
        gh_repo="$(net_probe gh repo view "$(git remote get-url "$remote")" \
            --json nameWithOwner --jq .nameWithOwner 2>/dev/null)" || gh_repo=""
    fi
    pr_limit="${AUDIT_PR_LIMIT:-1000}"
    if [ -n "$gh_repo" ] &&
        net_probe gh pr list --repo "$gh_repo" --state merged --limit "$pr_limit" \
            --json number,headRefName,headRefOid,baseRefName \
            --jq '.[] | [.headRefName, .headRefOid, (.number | tostring), .baseRefName] | @tsv' \
            >"$tmp/merged-prs" 2>/dev/null; then
        merged_seen="$(wc -l <"$tmp/merged-prs" | tr -d ' ')"
        if [ "$merged_seen" -ge "$pr_limit" ]; then
            echo "  (note: merged-PR listing hit its $pr_limit cap — 'no merged PR' below may be incomplete)"
        fi
        # A branch checked out in a linked worktree is one `clean:branches`
        # will refuse — `git branch -d` declines it, and that task guards the
        # update-ref path explicitly. Counting it as prunable made this report
        # hand the operator a number and name the very task that would decline
        # part of it (harmon-init#958). Same derivation clean-branches.sh uses,
        # so the two cannot disagree about what is checked out.
        #
        # A worktree PATH may contain a newline, which this line-delimited form
        # truncates; a branch NAME cannot (git refnames forbid control
        # characters), so the classification below is unaffected and only a
        # displayed path could be short.
        git worktree list --porcelain | awk '
            /^worktree /            { path = substr($0, 10) }
            /^branch refs\/heads\// { printf "%s\t%s\n", substr($0, 19), path }
        ' >"$tmp/checked-out"

        prunable=0
        held=0
        tip_differs=0
        no_pr=0
        while IFS=$'\t' read -r branch tip symref; do
            match="$(awk -F'\t' -v b="$branch" -v tip="$tip" -v base="$default_branch" \
                '$1 == b && $2 == tip && $4 == base { print $3; exit }' "$tmp/merged-prs")"
            if [ -n "$match" ] && [ "$symref" != "-" ]; then
                # clean:branches skips every symbolic ref rather than
                # dereferencing it, so evidence about its TARGET says nothing
                # about the alias. Counting it prunable named a task that
                # refuses it — the same defect as the worktree case above, in a
                # second form (Codex review on PR #991).
                printf '  held          %s — merged PR #%s, but it is a symbolic ref to %s (never dereferenced)\n' "$branch" "$match" "$symref"
                held=$((held + 1))
            elif [ -n "$match" ]; then
                held_path="$(awk -F'\t' -v b="$branch" '$1 == b { print $2; exit }' "$tmp/checked-out")"
                if [ -n "$held_path" ]; then
                    # Still shown — the evidence is real and the operator
                    # should see it — but not counted toward a total
                    # attributed to a task that will decline it.
                    printf '  held          %s — merged PR #%s, but checked out in worktree %s\n' "$branch" "$match" "$held_path"
                    held=$((held + 1))
                else
                    printf '  prunable      %s — merged PR #%s into %s (head == tip %s)\n' "$branch" "$match" "$default_branch" "${tip:0:12}"
                    prunable=$((prunable + 1))
                fi
            elif awk -F'\t' -v b="$branch" '$1 == b { found = 1; exit } END { exit !found }' "$tmp/merged-prs"; then
                printf '  tip differs   %s — a merged PR matches by name but not tip/base (a human decides)\n' "$branch"
                tip_differs=$((tip_differs + 1))
            else
                printf '  no merged PR  %s — abandoned or renamed (a human decides)\n' "$branch"
                no_pr=$((no_pr + 1))
            fi
        done <"$tmp/gone"
        # The invariant this line now keeps: the figure attributed to
        # `clean:branches` equals what that task reports as deletable on the
        # same tree.
        if [ "$held" -gt 0 ]; then
            # "held" covers two distinct reasons — a worktree checkout and a
            # symbolic ref — so the bucket is labelled generically. Saying
            # "held by a worktree" told the operator the wrong reason whenever
            # a symbolic hold was in the count, or the only thing in it (Codex
            # review on PR #991). Each entry names its own reason above; the
            # aggregate does not have to guess at one.
            printf '  -> %s prunable (task clean:branches), %s held (see above), %s tip-differs, %s without a merged PR\n' \
                "$prunable" "$held" "$tip_differs" "$no_pr"
        else
            printf '  -> %s prunable (task clean:branches), %s tip-differs, %s without a merged PR\n' \
                "$prunable" "$tip_differs" "$no_pr"
        fi
    else
        echo "  UNVERIFIED — gh unavailable or the merged-PR read failed; $gone_count gone branch(es) unclassified:"
        awk -F'\t' '{ print "    " $1 }' "$tmp/gone"
    fi
fi

# ── 3. Other worktrees ──────────────────────────────────────────────────────

section "Worktrees other than this one (reported only — no cleanup task touches these)"
this_tree="$(git rev-parse --show-toplevel)"
git worktree list --porcelain | awk -v self="$this_tree" '
    /^worktree /            { path = substr($0, 10) }
    /^branch refs\/heads\// { branch = substr($0, 19) }
    /^detached$/            { branch = "(detached)" }
    /^$/ {
        if (path != "" && path != self) { printf "  %s — %s\n", path, branch; found = 1 }
        path = ""; branch = "?"
    }
    END {
        if (path != "" && path != self) { printf "  %s — %s\n", path, branch; found = 1 }
        if (!found) print "  none"
    }
'

# ── 4. Review sidecars ──────────────────────────────────────────────────────

# The gauntlet stage keeps per-branch scratch state under the git directory
# (deliberately outside the worktree). `git rev-parse --git-path` resolves
# these paths PER WORKTREE, so a session working in a linked worktree writes
# them under .git/worktrees/<id>/ — an audit reading only its own git dir
# would silently omit that single-copy, unpushed state (challenge r4). Every
# scan below therefore walks the common dir plus every registered worktree's
# admin dir.
common_dir="$(git rev-parse --path-format=absolute --git-common-dir)"
{
    printf 'main\t%s\n' "$common_dir"
    if [ -d "$common_dir/worktrees" ]; then
        for admin_dir in "$common_dir"/worktrees/*; do
            [ -d "$admin_dir" ] || continue
            printf 'worktrees/%s\t%s\n' "$(basename "$admin_dir")" "$admin_dir"
        done
    fi
} >"$tmp/state-roots"

section "Review sidecars (deferred-findings / adjudication-ledger)"
# Each entry is a single file whose repo-relative path IS the branch name
# (slashes in the branch nest directories), per the gauntlet skill's layout.
sidecars_found=false
while IFS=$'\t' read -r root_label root_path; do
    for treename in deferred-findings adjudication-ledger; do
        dir="$root_path/$treename"
        [ -d "$dir" ] || continue
        find "$dir" -type f 2>/dev/null >"$tmp/sidecar-list"
        [ -s "$tmp/sidecar-list" ] || continue
        sidecars_found=true
        while IFS= read -r f; do
            rel="${f#"$dir"/}"
            if git show-ref --verify --quiet "refs/heads/$rel"; then
                printf '  active    %s/%s (branch exists) [%s]\n' "$treename" "$rel" "$root_label"
            else
                printf '  leftover  %s/%s — no such branch; stale scratch state [%s]\n' "$treename" "$rel" "$root_label"
            fi
        done <"$tmp/sidecar-list"
    done
done <"$tmp/state-roots"
[ "$sidecars_found" = true ] || echo "  none"

# ── 5. Shepherd cycle state ─────────────────────────────────────────────────

section "Shepherd Codex cycle-state files"
cycles_found=false
while IFS=$'\t' read -r root_label root_path; do
    cycles_dir="$root_path/shepherd-codex"
    [ -d "$cycles_dir" ] || continue
    find "$cycles_dir" -type f 2>/dev/null >"$tmp/cycles-list"
    [ -s "$tmp/cycles-list" ] || continue
    cycles_found=true
    while IFS= read -r f; do
        printf '  %s [%s]\n' "${f#"$cycles_dir"/}" "$root_label"
    done <"$tmp/cycles-list"
done <"$tmp/state-roots"
if [ "$cycles_found" = true ]; then
    echo "  (the shepherd checker's 'reap' subcommand sweeps states whose PR has closed)"
else
    echo "  none"
fi

# ── 5b. Rescue pins ─────────────────────────────────────────────────────────

# clean:worktree-records keeps refs/session-cleanup/pin/<record> when a
# pruned record held the only reference to a detached commit; a lingering pin
# is a decision waiting to be made.
section "Rescue pins (refs/session-cleanup/pin)"
git for-each-ref refs/session-cleanup/pin \
    --format='  %(refname:lstrip=3) — pins %(objectname) (branch it or delete the pin)' >"$tmp/pins"
if [ -s "$tmp/pins" ]; then
    cat "$tmp/pins"
else
    echo "  none"
fi

# ── 6. Totals ───────────────────────────────────────────────────────────────

section "Totals"
echo "  $total_branches local branches ($gone_count with a gone upstream)"
echo "  Report only — nothing was mutated. Deletion lives in 'task clean:branches' (dry run by default)."
