#!/usr/bin/env bash
# test-session-cleanup.sh — behavioral test for the session-cleanup surface
# (audit-session-artifacts.sh / clean-branches.sh). Run via
# `task test:session-cleanup`.
#
# Everything happens inside a throwaway fixture repository, never in the
# calling repository: the script under test deletes branches, and a test that
# did that to the developer's own checkout would be a data-loss path.
#
# `gh` is stubbed on PATH with a shim that answers exactly the invocations the
# scripts make (repo view, pr list --head, batched pr list), driven by a
# tab-separated PR table — so every case runs offline and deterministically.
# One shim mode advances a branch ref as a side effect of answering, to drive
# the compare-and-delete race window (test-worktree.sh's WTSHIM_ADVANCE
# precedent).
#
# Every run is self-contained under per-run mktemp paths, so any number of
# suites may run concurrently without sharing a byte of state.
set -euo pipefail

# No child may inherit a never-ending stdin (harmon-init#802).
exec </dev/null

repo="$(git rev-parse --show-toplevel)"

# Hooks export GIT_DIR/GIT_WORK_TREE; left set, every `git` below would
# retarget the CALLING repository instead of the fixture.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

# Neutralize every out-of-tree source of git config so the fixture is hermetic
# (same sanitation as test-worktree.sh).
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

expect_contains() {
    # expect_contains <haystack> <needle> <label>
    case "$1" in
    *"$2"*) ;;
    *) fail "$3: expected output to contain '$2'" ;;
    esac
}

expect_not_contains() {
    case "$1" in
    *"$2"*) fail "$3: expected output NOT to contain '$2'" ;;
    esac
}

branch_exists() {
    git -C "$fixture" show-ref --verify --quiet "refs/heads/$1"
}

test_tmp="$(mktemp -d "${TMPDIR:-/tmp}/session-cleanup-test.XXXXXX")"
trap 'rm -rf "$test_tmp"' EXIT
# Resolve symlinks now (macOS mktemp answers under /var -> /private/var), so
# assertions comparing against git's resolved worktree paths match literally.
test_tmp="$(cd "$test_tmp" && pwd -P)"

# ── gh stub ─────────────────────────────────────────────────────────────────

stub_bin="$test_tmp/bin"
mkdir -p "$stub_bin"
cat >"$stub_bin/gh" <<'STUB'
#!/usr/bin/env bash
# gh stub: answers the exact reads the cleanup scripts perform, from the PR
# table in $GH_STUB_PRS (lines: headRefName<TAB>headRefOid<TAB>number<TAB>baseRefName).
set -euo pipefail
if [ "${GH_STUB_FAIL:-0}" = "1" ]; then
    exit 1
fi
cmd="${1:-}"
sub="${2:-}"
if [ "$cmd" = repo ] && [ "$sub" = view ]; then
    echo "stub/fixture"
    exit 0
fi
if [ "$cmd" = pr ] && [ "$sub" = list ]; then
    head_filter=""
    batch=false
    limit=100000
    prev=""
    for a in "$@"; do
        [ "$prev" = "--head" ] && head_filter="$a"
        [ "$prev" = "--limit" ] && limit="$a"
        case "$a" in *headRefName*) batch=true ;; esac
        prev="$a"
    done
    data="${GH_STUB_PRS:-}"
    if [ -n "$data" ] && [ -f "$data" ]; then
        if [ "$batch" = true ]; then
            head -n "$limit" "$data"
        else
            if [ "${GH_STUB_HEAD_FAIL:-0}" = "1" ]; then
                exit 1
            fi
            awk -F'\t' -v b="$head_filter" '$1 == b { print $3 "\t" $2 "\t" $4 }' "$data"
            # Side effect modes, firing AFTER the answer to open the window
            # between verification and deletion: advance the queried branch,
            # or check it out into a worktree (the concurrent-session race).
            if [ -n "${GH_STUB_ADVANCE:-}" ] && [ "$head_filter" = "$GH_STUB_ADVANCE" ]; then
                tip="$(git rev-parse "refs/heads/$head_filter")"
                tree="$(git rev-parse "$tip^{tree}")"
                new="$(git commit-tree -p "$tip" -m advanced "$tree")"
                git update-ref "refs/heads/$head_filter" "$new" "$tip"
            fi
            if [ -n "${GH_STUB_CHECKOUT:-}" ] && [ "$head_filter" = "$GH_STUB_CHECKOUT" ]; then
                git worktree add -q "$GH_STUB_CHECKOUT_DIR" "$head_filter"
            fi
            # Simulate a concurrent fetch of a REWRITTEN default: move both
            # the origin's main and the local tracking ref to a divergent
            # commit built on main~1 (excludes anything merged last).
            if [ -n "${GH_STUB_REWRITE:-}" ] && [ "$head_filter" = "$GH_STUB_REWRITE" ]; then
                rw_p="$(git rev-parse main~1)"
                rw_t="$(git rev-parse "$rw_p^{tree}")"
                rw_d="$(git commit-tree -p "$rw_p" -m rewritten "$rw_t")"
                # The object lives only in this clone's odb — push it across
                # before the origin's ref can point at it.
                git push -q origin "$rw_d":refs/heads/rewrite-tmp
                git -C "$GH_STUB_ORIGIN" update-ref refs/heads/main "$rw_d"
                git -C "$GH_STUB_ORIGIN" update-ref -d refs/heads/rewrite-tmp
                git update-ref -d refs/remotes/origin/rewrite-tmp 2>/dev/null || true
                git update-ref refs/remotes/origin/main "$rw_d"
            fi
        fi
    fi
    exit 0
fi
echo "gh stub: unexpected invocation: $*" >&2
exit 64
STUB
chmod +x "$stub_bin/gh"
PATH="$stub_bin:$PATH"

# ── Fixture repository ──────────────────────────────────────────────────────

origin="$test_tmp/origin.git"
fixture="$test_tmp/fixture"
git init -q --bare --initial-branch=main "$origin"
git clone -q "$origin" "$fixture" 2>/dev/null
git -C "$fixture" config user.email test@example.invalid
git -C "$fixture" config user.name "Session Cleanup Test"
git -C "$fixture" symbolic-ref HEAD refs/heads/main
(
    cd "$fixture"
    echo base >README.md
    git add README.md
    git commit -qm "initial"
    git push -qu origin main
    git remote set-head origin --auto
)

# The scripts resolve their repo root from their own location, so the fixture
# gets its own copy — the same way generated repos ship them. worktree-lock.sh
# rides along because the delete path sources its lifecycle-lock protocol.
mkdir -p "$fixture/scripts"
cp "$repo/scripts/clean-branches.sh" "$repo/scripts/audit-session-artifacts.sh" \
    "$repo/scripts/worktree-lock.sh" "$fixture/scripts/"

# make_branch <name> <file> — new branch off main with one pushed commit;
# echoes the tip. Leaves the checkout back on main.
make_branch() {
    (
        cd "$fixture"
        git checkout -q -b "$1" main
        echo "$1" >"$2"
        git add "$2"
        git commit -qm "work on $1"
        git push -qu origin "$1" 2>/dev/null
        git rev-parse HEAD
        git checkout -q main
    )
}

# retire_remote <name> — delete the remote branch and prune, leaving the
# local upstream [gone].
retire_remote() {
    git -C "$fixture" push -q origin ":$1" 2>/dev/null
    git -C "$fixture" fetch -qp origin
}

# 1. anc-merged: fast-forwarded into main — ancestry evidence, class 1.
anc_tip="$(make_branch anc-merged anc.txt)"
(
    cd "$fixture"
    git merge -q --ff-only anc-merged
    git push -q origin main
)
retire_remote anc-merged

# 2. sq-merged: squash-merged (different commit on main), remote branch gone —
#    PR evidence, class 2.
sq_tip="$(make_branch sq-merged sq.txt)"
(
    cd "$fixture"
    echo sq-merged >sq.txt
    git add sq.txt
    git commit -qm "squash of sq-merged"
    git push -q origin main
)
retire_remote sq-merged

# 3. gone-nopr: upstream gone, no PR anywhere — must survive (negative control).
gone_nopr_tip="$(make_branch gone-nopr nopr.txt)"
retire_remote gone-nopr

# 4. gone-tipdiff: a merged PR exists for an EARLIER commit, but the local tip
#    has one more (unpushed) commit — must survive (negative control).
tipdiff_pushed="$(make_branch gone-tipdiff tipdiff.txt)"
(
    cd "$fixture"
    git checkout -q gone-tipdiff
    echo more >>tipdiff.txt
    git add tipdiff.txt
    git commit -qm "extra local work"
    git checkout -q main
)
retire_remote gone-tipdiff

# 5. wt-checked: PR evidence says merged, but the branch is checked out in a
#    linked worktree — must survive (negative control for the update-ref path,
#    which does not respect git's checked-out guard on its own).
wt_tip="$(make_branch wt-checked wt.txt)"
retire_remote wt-checked
git -C "$fixture" worktree add -q "$test_tmp/wt" wt-checked

# 5b. tracked-live: pushed, upstream still present, not merged — ordinary
#     in-flight work that WAS classified from a tracking ref. The freshness
#     caveat counts this one and must not count unpushed-live below, which has
#     no upstream for a prune to affect (Codex review on PR #991).
make_branch tracked-live tracked.txt >/dev/null

# 5c. local-upstream: tracks another LOCAL branch (branch.<name>.remote=.).
#     %(upstream) is non-empty, but it is under refs/heads/, so
#     `task clean:remote-refs` cannot affect how this branch is classified and
#     the freshness caveat must not count it (Codex review on PR #991).
(
    cd "$fixture"
    git checkout -q -b local-upstream main
    echo localup >localup.txt
    git add localup.txt
    git commit -qm "work tracking a local branch"
    git branch --set-upstream-to=main local-upstream >/dev/null 2>&1
    git checkout -q main
)

# 6. unpushed-live: never pushed anywhere — ordinary in-flight work, silent
#    survival.
(
    cd "$fixture"
    git checkout -q -b unpushed-live main
    echo local >local.txt
    git add local.txt
    git commit -qm "local-only work"
    git checkout -q main
)

# 6b. sq-stacked: a merged PR exists at exactly this tip, but its base was a
#     stacked branch, not the default — insufficient evidence; must survive.
stacked_tip="$(make_branch sq-stacked stacked.txt)"
retire_remote sq-stacked

# 6c. tf-stale: the remote branch is deleted upstream WITHOUT a local fetch
#     (bare-origin surgery), so the local tracking ref survives, the branch
#     reads neither [gone] nor unpushed — the audit's freshness section is
#     what must surface it.
tf_tip="$(make_branch tf-stale tf.txt)"
git -C "$origin" update-ref -d refs/heads/tf-stale

# 7. A tag sharing a branch's name: %(refname:short) would disambiguate the
#    branch to "heads/gone-nopr" and break every ref built from it.
git -C "$fixture" tag gone-nopr

# 8. A symbolic ref under refs/heads: deleting it via update-ref would
#    DEREFERENCE it and delete the target branch — it must be skipped, never
#    resolved.
git -C "$fixture" symbolic-ref refs/heads/alias-main refs/heads/main

# The PR table the stub serves (headRefName, headRefOid, number).
export GH_STUB_PRS="$test_tmp/prs.tsv"
printf '%s\t%s\t%s\t%s\n' \
    sq-merged "$sq_tip" 101 main \
    gone-tipdiff "$tipdiff_pushed" 102 main \
    wt-checked "$wt_tip" 103 main \
    sq-stacked "$stacked_tip" 107 feature-base \
    >"$GH_STUB_PRS"

# Audit fixtures: sidecar files and a shepherd cycle state.
gitdir="$(git -C "$fixture" rev-parse --absolute-git-dir)"
mkdir -p "$gitdir/deferred-findings" "$gitdir/adjudication-ledger/dead" "$gitdir/shepherd-codex/stub/fixture"
echo "p2 note" >"$gitdir/deferred-findings/unpushed-live"
mkdir -p "$gitdir/worktrees/wt/deferred-findings"
echo "linked-worktree note" >"$gitdir/worktrees/wt/deferred-findings/wt-checked"
echo "orphan" >"$gitdir/adjudication-ledger/dead/branch"
echo '{}' >"$gitdir/shepherd-codex/stub/fixture/42.json"

snapshot() {
    git -C "$fixture" for-each-ref --format='%(refname) %(objectname)'
    git -C "$fixture" worktree list --porcelain
}

# ── Case A: dry run is the default and mutates nothing ─────────────────────

before="$(snapshot)"
dry_out="$(cd "$fixture" && bash scripts/clean-branches.sh 2>&1)" ||
    fail "dry run exited nonzero: $dry_out"
after="$(snapshot)"
[ "$before" = "$after" ] || fail "dry run mutated refs or worktrees"

expect_contains "$dry_out" "WOULD DELETE  anc-merged" "dry run: ancestry candidate"
expect_contains "$dry_out" "WOULD DELETE  sq-merged" "dry run: PR-evidence candidate"
expect_contains "$dry_out" "merged PR #101" "dry run: names the vouching PR"
expect_not_contains "$dry_out" "WOULD DELETE  main" "dry run: default branch is never a candidate"
expect_not_contains "$dry_out" "WOULD DELETE  gone-nopr" "dry run: no-evidence branch is not a candidate"
expect_contains "$dry_out" "gone-nopr" "dry run: no-evidence branch is skipped loudly"
expect_contains "$dry_out" "unpushed work is never deleted" "dry run: tip-past-PR branch refused as unpushed"
expect_contains "$dry_out" "checked out in worktree" "dry run: worktree branch refused loudly"
expect_contains "$dry_out" "SKIP  alias-main — symbolic ref" "dry run: symbolic ref skipped, never dereferenced"
expect_not_contains "$dry_out" "WOULD DELETE  sq-stacked" "dry run: PR into a non-default base is not evidence"
expect_contains "$dry_out" "sq-stacked" "dry run: stacked-base branch skipped loudly"
expect_not_contains "$dry_out" "WOULD DELETE  alias-main" "dry run: symbolic ref is never a candidate"
expect_not_contains "$dry_out" "heads/gone-nopr" "dry run: tag/branch name collision does not mangle the branch name"
echo "ok: dry run classifies and mutates nothing"

# ── Case B: audit reports everything and mutates nothing ───────────────────

before="$(snapshot)"
audit_out="$(cd "$fixture" && bash scripts/audit-session-artifacts.sh 2>&1)" ||
    fail "audit exited nonzero: $audit_out"
after="$(snapshot)"
[ "$before" = "$after" ] || fail "audit mutated refs or worktrees"

expect_contains "$audit_out" "unpushed-live — 1 commit(s) on no remote" "audit: unpushed work is the headline"
expect_contains "$audit_out" "prunable      sq-merged — merged PR #101" "audit: prunable classification"
expect_contains "$audit_out" "no merged PR  gone-nopr" "audit: gone without PR"
expect_contains "$audit_out" "tip differs   gone-tipdiff" "audit: PR matched by name but not tip"
expect_contains "$audit_out" "tip differs   sq-stacked" "audit: non-default-base PR is not prunable evidence"
expect_contains "$audit_out" "tf-stale — deleted upstream" "audit: stale tracking ref surfaced by the freshness section"
expect_contains "$audit_out" "$test_tmp/wt — wt-checked" "audit: other worktree named"
expect_contains "$audit_out" "active    deferred-findings/unpushed-live" "audit: live sidecar"
expect_contains "$audit_out" "leftover  adjudication-ledger/dead/branch" "audit: orphan sidecar"
expect_contains "$audit_out" "deferred-findings/wt-checked (branch exists) [worktrees/wt]" "audit: linked-worktree sidecar state scanned"
expect_contains "$audit_out" "stub/fixture/42.json" "audit: shepherd cycle state listed"
echo "ok: audit reports all artifact classes read-only"

# ── Case B2: the audit's prunable figure equals what clean:branches deletes ──
#
# wt-checked has merged-PR evidence AND is checked out in a linked worktree.
# The audit counted it as prunable and attributed the total to a task that
# refuses it, so the operator was handed a number nothing would act on
# (harmon-init#958). It must now be shown, classified as held, and excluded
# from the figure.
expect_contains "$audit_out" "held          wt-checked" "audit: worktree-checked-out branch is held, not prunable"
expect_not_contains "$audit_out" "prunable      wt-checked" "audit: worktree-checked-out branch is not counted prunable"
# Generic on purpose: "held" covers a worktree checkout AND a symbolic ref, so
# a summary naming only one gives the wrong reason whenever the other is in the
# count (Codex, PR #991). Each entry states its own reason.
expect_contains "$audit_out" "held (see above)" "audit: the summary names the held bucket without guessing its reason"
expect_not_contains "$audit_out" "held by a worktree" "audit: the aggregate does not claim a single reason (#958)"

# The invariant is SUBSET, not equality, and the distinction is load-bearing.
# clean:branches deletes on two evidence types — ancestry or a merged PR —
# while the audit classifies prunable on PR evidence alone, so an
# ancestry-merged branch is legitimately deletable without being prunable
# (tracked separately). What #958 fixes is the other direction: nothing may be
# called prunable that clean:branches will refuse. Asserted per branch rather
# than on the totals, because two counts can coincide while naming different
# branches.
audit_prunable_names="$(printf '%s\n' "$audit_out" |
    sed -n 's/^  prunable      \([^ ]*\) .*/\1/p' | sort)"
clean_deletable_names="$(printf '%s\n' "$dry_out" |
    sed -n 's/^WOULD DELETE  \([^ ]*\) .*/\1/p' | sort)"
[ -n "$audit_prunable_names" ] || fail "the audit classified nothing prunable — the fixture no longer exercises this (#958)"
[ -n "$clean_deletable_names" ] || fail "clean:branches found nothing deletable — the fixture no longer exercises this (#958)"
not_deletable="$(comm -23 <(printf '%s\n' "$audit_prunable_names") <(printf '%s\n' "$clean_deletable_names"))"
[ -z "$not_deletable" ] ||
    fail "the audit called these prunable but clean:branches will not delete them (#958): $(printf '%s' "$not_deletable" | tr '\n' ' ')"
echo "ok: every branch the audit calls prunable is one clean:branches would delete"

# ── Case B3: clean:branches reports tracking-ref staleness ──────────────────
#
# Every classification reads local tracking refs, so a branch whose upstream is
# already gone reads as neither [gone] nor unpushed and lands in `in-flight
# kept` — a bucket that says "deliberately left alone", not "I could not tell".
# The audit has said so since it was written; the task that actually deletes
# did not (harmon-init#958). The fixture's tf-stale ref is exactly that shape.
expect_contains "$dry_out" "were classified from local tracking refs" "clean:branches: the in-flight bucket carries its caveat"
expect_contains "$dry_out" "skipFetchAll" "clean:branches: the remedy names the remote fetch --all passes over"
expect_contains "$dry_out" "task clean:remote-refs" "clean:branches: the caveat names the remedy"
# The caveat must count only branches an upstream could have misclassified.
# The fixture's unpushed-live has none, so it must not be included: keying on
# the aggregate in-flight count warned about ordinary local-only branches, and
# a caveat that fires in the common case is one nobody reads (Codex, PR #991).
# The caveat no longer prints a count — the figure needed redefining four
# times and a skipFetchAll remote would have broken it again. What must hold is
# that it fires only when a remote-backed upstream is in play: unpushed-live
# and local-upstream must not, on their own, be able to trigger it.
expect_not_contains "$dry_out" " of the " "clean:branches: the caveat asserts no count (#958)"

# Suppression needs its OWN repository: the main fixture always has a
# remote-tracking in-flight branch, so it can only ever show the caveat firing.
# Without this, keying the caveat back on the aggregate in-flight count passes
# every assertion above (mutant M9).
untracked_only="$test_tmp/untracked-only"
untracked_origin="$test_tmp/untracked-only-origin.git"
git init -q --bare --initial-branch=main "$untracked_origin"
git init -q --initial-branch=main "$untracked_only"
(
    cd "$untracked_only"
    git config user.name "Session Cleanup Test"
    git config user.email "session-cleanup@example.invalid"
    git config commit.gpgsign false
    git remote add origin "$untracked_origin"
    echo seed >seed.txt
    git add seed.txt
    git commit -qm "chore: seed"
    git push -q origin main
    # Its OWN unmerged commit: a branch sitting at main's tip is deletable by
    # ancestry, not kept in-flight, and would exercise nothing here.
    git checkout -q -b local-only-work
    echo local >local.txt
    git add local.txt
    git commit -qm "local-only work"
    git checkout -q main
)
mkdir -p "$untracked_only/scripts"
cp "$repo/scripts/clean-branches.sh" "$untracked_only/scripts/"
untracked_out="$(cd "$untracked_only" && bash scripts/clean-branches.sh 2>&1)" ||
    fail "untracked-only dry run exited nonzero: $untracked_out"
# The summary line prints "N in-flight kept" even when N is zero, so match the
# count, not the phrase — otherwise this passes against a fixture that keeps
# nothing and the suppression below proves nothing.
expect_contains "$untracked_out" "1 in-flight kept" "untracked-only: the local branch is kept in-flight"
expect_not_contains "$untracked_out" "classified from local tracking refs" \
    "clean:branches: no caveat when no in-flight branch has a remote-backed upstream (#958)"
# Degraded mode: a failing gh probe is UNVERIFIED, never silently clean.
audit_fail_out="$(cd "$fixture" && GH_STUB_FAIL=1 bash scripts/audit-session-artifacts.sh 2>&1)" ||
    fail "degraded audit exited nonzero: $audit_fail_out"
expect_contains "$audit_fail_out" "UNVERIFIED" "audit: failed PR read reported unverified"
echo "ok: audit fails closed when gh is unavailable"

# ── Case C: a failed PR probe blocks PR-evidence deletion (fail closed) ────

failrun_out="$(cd "$fixture" && GH_STUB_FAIL=1 bash scripts/clean-branches.sh --delete 2>&1)" ||
    fail "fail-closed delete run exited nonzero: $failrun_out"
branch_exists sq-merged || fail "fail-closed: sq-merged deleted without a reachable PR check"
expect_contains "$failrun_out" "gh is unavailable" "fail-closed: refusal is loud"
branch_exists anc-merged && fail "fail-closed: ancestry evidence needs no gh, anc-merged should have been deleted"
expect_contains "$failrun_out" "deleted  anc-merged" "fail-closed: ancestry deletion proceeded offline"
echo "ok: PR-evidence deletion fails closed without gh"

# ── Case D: --delete removes exactly the evidenced branches ────────────────

del_out="$(cd "$fixture" && bash scripts/clean-branches.sh --delete 2>&1)" ||
    fail "delete run exited nonzero: $del_out"
expect_contains "$del_out" "deleted  sq-merged" "delete: squash-merged branch removed"
expect_contains "$del_out" "recover: git branch 'sq-merged'" "delete: recovery hint printed, branch name quoted"
branch_exists sq-merged && fail "delete: sq-merged still exists"
git -C "$fixture" config --get-regexp '^branch\.sq-merged\.' >/dev/null 2>&1 &&
    fail "delete: branch.sq-merged config section left behind"
branch_exists gone-nopr || fail "negative control: gone-nopr was deleted without evidence"
branch_exists gone-tipdiff || fail "negative control: gone-tipdiff was deleted despite unpushed tip"
branch_exists wt-checked || fail "negative control: worktree-checked-out branch was deleted"
branch_exists unpushed-live || fail "negative control: unpushed in-flight branch was deleted"
branch_exists sq-stacked || fail "negative control: stacked-base PR branch was deleted"
branch_exists main || fail "negative control: default branch was deleted"
[ -d "$test_tmp/wt" ] || fail "delete: worktree directory was removed"
git -C "$fixture" symbolic-ref -q refs/heads/alias-main >/dev/null ||
    fail "negative control: symbolic ref alias-main was deleted"
echo "ok: delete removes evidenced branches only, negative controls survive"

# ── Case E: compare-and-delete refuses a tip that moved after verification ─

cad_tip="$(make_branch sq-cad cad.txt)"
(
    cd "$fixture"
    echo cad >cad.txt
    git add cad.txt
    git commit -qm "squash of sq-cad"
    git push -q origin main
)
retire_remote sq-cad
printf '%s\t%s\t%s\t%s\n' sq-cad "$cad_tip" 104 main >>"$GH_STUB_PRS"

cad_out="$(cd "$fixture" && CLEAN_PR_LIMIT=1 GH_STUB_ADVANCE=sq-cad bash scripts/clean-branches.sh --delete 2>&1)" ||
    fail "CAD run exited nonzero: $cad_out"
expect_contains "$cad_out" "tip moved since verification" "CAD: refusal is loud"
branch_exists sq-cad || fail "CAD: sq-cad deleted although its tip moved after verification"
echo "ok: compare-and-delete refuses a moved tip"

# ── Case E2: a branch claimed by a worktree AFTER classification survives ──
# Classification saw it unclaimed; the stub checks it out while answering the
# PR probe. Only the delete-phase re-check stands between update-ref and
# another session's workspace.

race_tip="$(make_branch sq-race race.txt)"
(
    cd "$fixture"
    echo race >race.txt
    git add race.txt
    git commit -qm "squash of sq-race"
    git push -q origin main
)
retire_remote sq-race
printf '%s\t%s\t%s\t%s\n' sq-race "$race_tip" 105 main >>"$GH_STUB_PRS"

race_out="$(cd "$fixture" && CLEAN_PR_LIMIT=1 GH_STUB_CHECKOUT=sq-race GH_STUB_CHECKOUT_DIR="$test_tmp/wt-race" \
    bash scripts/clean-branches.sh --delete 2>&1)" ||
    fail "worktree-race run exited nonzero: $race_out"
expect_contains "$race_out" "became checked out in a worktree since classification" "race: delete-phase re-check refused"
branch_exists sq-race || fail "race: sq-race deleted although a worktree claimed it mid-run"
echo "ok: delete-phase worktree re-check catches a mid-run checkout"

# ── Case E3: a held branch lifecycle lock refuses the deletion ─────────────
# The lock is the serialization boundary shared with worktree:new/rm; an
# ownerless entry always refuses (crash-vs-suspension is undecidable), which
# doubles here as the cheapest way to simulate a concurrent holder.

lock_tip="$(make_branch sq-locked lock.txt)"
(
    cd "$fixture"
    echo locked >lock.txt
    git add lock.txt
    git commit -qm "squash of sq-locked"
    git push -q origin main
)
retire_remote sq-locked
printf '%s\t%s\t%s\t%s\n' sq-locked "$lock_tip" 106 main >>"$GH_STUB_PRS"

commondir="$(git -C "$fixture" rev-parse --path-format=absolute --git-common-dir)"
mkdir -p "$commondir/worktree-locks/branch=sq-locked+lock"
locked_out="$(cd "$fixture" && bash scripts/clean-branches.sh --delete 2>&1)" ||
    fail "locked run exited nonzero: $locked_out"
expect_contains "$locked_out" "branch lifecycle lock refused" "lock: contended branch skipped loudly"
branch_exists sq-locked || fail "lock: sq-locked deleted although its lifecycle lock was held"
rmdir "$commondir/worktree-locks/branch=sq-locked+lock"
unlocked_out="$(cd "$fixture" && bash scripts/clean-branches.sh --delete 2>&1)" ||
    fail "post-lock run exited nonzero: $unlocked_out"
expect_contains "$unlocked_out" "deleted  sq-locked" "lock: released lock lets the evidenced delete proceed"
branch_exists sq-locked && fail "lock: sq-locked still exists after the lock was released"
echo "ok: branch lifecycle lock serializes deletion with worktree operations"

# ── Case E4: stale ancestry evidence fails closed ──────────────────────────
# The remote default branch moves (force-push/repoint) after the last fetch;
# the local tracking ref then vouches for commits the remote no longer
# holds. The delete phase compares against the ADVERTISED tip and refuses.

fresh_tip="$(make_branch anc-fresh fresh.txt)"
(
    cd "$fixture"
    git merge -q --ff-only anc-fresh
    git push -q origin main
)
retire_remote anc-fresh

sab_sha="$(
    cd "$fixture"
    git checkout -q -b sabotage main
    echo sab >sab.txt
    git add sab.txt
    git commit -qm "divergent remote main"
    git push -q origin sabotage:refs/heads/main-sab 2>/dev/null
    git rev-parse HEAD
    git checkout -q main
    git update-ref -d refs/heads/sabotage
)"
git -C "$origin" update-ref refs/heads/main "$sab_sha"

stale_out="$(cd "$fixture" && bash scripts/clean-branches.sh --delete 2>&1)" ||
    fail "stale-ancestry run exited nonzero: $stale_out"
expect_contains "$stale_out" "stale or unverifiable against the live remote" "freshness: stale tracking ref refused"
branch_exists anc-fresh || fail "freshness: anc-fresh deleted against stale ancestry evidence"

git -C "$origin" update-ref refs/heads/main "$(git -C "$fixture" rev-parse refs/remotes/origin/main)"
fresh_out="$(cd "$fixture" && bash scripts/clean-branches.sh --delete 2>&1)" ||
    fail "restored-freshness run exited nonzero: $fresh_out"
expect_contains "$fresh_out" "deleted  anc-fresh" "freshness: fresh evidence lets the ancestry delete proceed"
branch_exists anc-fresh && fail "freshness: anc-fresh still exists after freshness was restored"
echo "ok: ancestry deletion fails closed on stale remote evidence"

# ── Case E5: ancestry deletion works from a divergent checkout ─────────────
# `git branch -d` would authorize against the current HEAD and refuse here;
# the verified-evidence compare-and-delete must not (challenge r2).

anc_head_tip="$(make_branch anc-head head.txt)"
(
    cd "$fixture"
    git merge -q --ff-only anc-head
    git push -q origin main
)
retire_remote anc-head
# runner branches from BEFORE the anc-head merge, so anc-head is not an
# ancestor of HEAD during the run — exactly the state where `git branch -d`
# would refuse what the dry run promised.
(
    cd "$fixture"
    git checkout -q -b runner main~1
    echo runner >runner.txt
    git add runner.txt
    git commit -qm "divergent runner work"
)
div_out="$(cd "$fixture" && bash scripts/clean-branches.sh --delete 2>&1)" ||
    fail "divergent-checkout run exited nonzero: $div_out"
git -C "$fixture" checkout -q main
expect_contains "$div_out" "deleted  anc-head" "divergent HEAD: verified ancestry deletes regardless of checkout"
branch_exists anc-head && fail "divergent HEAD: anc-head still exists"
branch_exists runner || fail "divergent HEAD: the current branch itself was deleted"
echo "ok: ancestry deletion is checkout-independent"

# ── Case E6: a config write failure after deletion is loud ─────────────────
# A stale config.lock makes --remove-section fail; the deletion must still
# report the leftover branch.<name> config instead of swallowing it.

cfg_tip="$(make_branch sq-cfg cfg.txt)"
(
    cd "$fixture"
    echo cfg >cfg.txt
    git add cfg.txt
    git commit -qm "squash of sq-cfg"
    git push -q origin main
)
retire_remote sq-cfg
printf '%s\t%s\t%s\t%s\n' sq-cfg "$cfg_tip" 108 main >>"$GH_STUB_PRS"

gitdir_cfg="$(git -C "$fixture" rev-parse --absolute-git-dir)"
touch "$gitdir_cfg/config.lock"
cfg_out="$(cd "$fixture" && bash scripts/clean-branches.sh --delete 2>&1)" ||
    fail "config-lock run exited nonzero: $cfg_out"
rm -f "$gitdir_cfg/config.lock"
expect_contains "$cfg_out" "deleted  sq-cfg" "config lock: the evidenced deletion itself proceeds"
expect_contains "$cfg_out" "WARN  sq-cfg was deleted but its branch.sq-cfg" "config lock: leftover config reported loudly"
git -C "$fixture" config --local --remove-section branch.sq-cfg 2>/dev/null || true
echo "ok: config cleanup failure is reported, never swallowed"

# ── Case E7: worktree-record pruning pins detached commits through the prune ─
# A stale record whose HEAD is detached at a commit no shared ref contains is
# the only thing keeping that commit alive (challenge r3); the guard is a pin
# created BEFORE the prune, so no interleaving can strand the commit
# (challenge r4). Branch-attached stale records prune normally; a live
# detached worktree's pin is dropped as redundant.

cp "$repo/scripts/clean-worktree-records.sh" "$fixture/scripts/"

git -C "$fixture" worktree add -q -b prune-br "$test_tmp/wt-br" main
git -C "$fixture" worktree add -q --detach "$test_tmp/wt-det" main
git -C "$fixture" worktree add -q --detach "$test_tmp/wt-live" main
(
    cd "$test_tmp/wt-det"
    echo det >det.txt
    git add det.txt
    git commit -qm "detached-only work"
)
det_sha="$(git -C "$test_tmp/wt-det" rev-parse HEAD)"
rm -rf "$test_tmp/wt-br" "$test_tmp/wt-det"

if prune_out="$(cd "$fixture" && bash scripts/clean-worktree-records.sh 2>&1)"; then
    fail "record prune exited zero although an orphan pin should have been kept: $prune_out"
fi
expect_contains "$prune_out" "KEPT  refs/session-cleanup/pin/wt-det" "record prune: orphan commit's pin kept and reported"
expect_contains "$prune_out" "git update-ref -d 'refs/session-cleanup/pin/wt-det' $det_sha" "record prune: drop remedy is compare-and-delete, immune to record-name reuse"
worktrees_admin="$(git -C "$fixture" rev-parse --path-format=absolute --git-common-dir)/worktrees"
if ls "$worktrees_admin" 2>/dev/null | grep -Eq '^(wt-det|wt-br)$'; then
    fail "record prune: stale records survived the prune"
fi
[ "$(git -C "$fixture" rev-parse --quiet --verify refs/session-cleanup/pin/wt-det)" = "$det_sha" ] ||
    fail "record prune: pin does not hold the detached commit"
git -C "$fixture" rev-parse --quiet --verify refs/session-cleanup/pin/wt-live >/dev/null &&
    fail "record prune: redundant pin for a live worktree was kept"
if git -C "$fixture" fsck --unreachable 2>/dev/null | grep -q "$det_sha"; then
    fail "record prune: detached commit became unreachable despite the pin"
fi
echo "ok: record prune pins an orphan detached commit through the prune"

# The audit surfaces a lingering pin as a decision waiting to be made.
pin_audit_out="$(cd "$fixture" && bash scripts/audit-session-artifacts.sh 2>&1)" ||
    fail "audit exited nonzero with a pin present: $pin_audit_out"
expect_contains "$pin_audit_out" "wt-det — pins $det_sha" "audit: leftover rescue pin reported"
echo "ok: audit reports leftover rescue pins"

# The contract holds across retries: an otherwise-empty re-run must stay
# nonzero while any pin awaits settlement, not report cleanup complete.
if pin_retry_out="$(cd "$fixture" && bash scripts/clean-worktree-records.sh 2>&1)"; then
    fail "record prune exited zero while a rescue pin awaited settlement: $pin_retry_out"
fi
expect_contains "$pin_retry_out" "rescue pins await settlement" "retry: pending pin keeps the run nonzero"
echo "ok: a pending rescue pin keeps retries nonzero"

# A pruning run made while an earlier pin is outstanding reports the TOTAL
# awaiting settlement, not just this run's — "0 pins" beside a nonzero exit
# would contradict the disposition.
mkdir -p "$gitdir/worktrees/plainrec"
printf 'ref: refs/heads/main\n' >"$gitdir/worktrees/plainrec/HEAD"
printf '%s\n' "/nonexistent/plainrec/.git" >"$gitdir/worktrees/plainrec/gitdir"
if inherit_out="$(cd "$fixture" && bash scripts/clean-worktree-records.sh 2>&1)"; then
    fail "record prune exited zero while an inherited pin awaited settlement: $inherit_out"
fi
expect_contains "$inherit_out" "pruned record 'plainrec'" "retry-summary: unrelated record still prunes"
expect_contains "$inherit_out" "1 total awaiting settlement" "retry-summary: inherited pin counted in the total"
echo "ok: inherited pins are counted in the settlement total"

git -C "$fixture" branch -q rescue-det "$det_sha"
git -C "$fixture" update-ref -d refs/session-cleanup/pin/wt-det
prune_ok_out="$(cd "$fixture" && bash scripts/clean-worktree-records.sh 2>&1)" ||
    fail "record prune failed after the pin was settled: $prune_ok_out"
expect_contains "$prune_ok_out" "nothing to prune" "record prune: live worktrees leave nothing plan-scoped to remove"
git -C "$fixture" rev-parse --quiet --verify refs/session-cleanup/pin/wt-live >/dev/null &&
    fail "record prune: live-worktree pin left behind on the clean run"
git -C "$fixture" cat-file -e "$det_sha" || fail "record prune: rescued commit lost from the object db"
echo "ok: record prune settles cleanly once every commit is referenced"

# ── Case E7c: an unsettled pin from an earlier run is never overwritten ────
# A record name reused after a kept pin would silently replace the sole
# reference to the older commit; the create-only pin write must refuse.

orph_sha="$(git -C "$fixture" commit-tree "main^{tree}" -p main -m "old orphan")"
git -C "$fixture" update-ref refs/session-cleanup/pin/pin-reuse "$orph_sha"
mkdir -p "$gitdir/worktrees/pin-reuse"
git -C "$fixture" rev-parse main >"$gitdir/worktrees/pin-reuse/HEAD"
printf '%s\n' "/nonexistent/pin-reuse/.git" >"$gitdir/worktrees/pin-reuse/gitdir"

if reuse_out="$(cd "$fixture" && bash scripts/clean-worktree-records.sh 2>&1)"; then
    fail "record prune proceeded over a foreign unsettled pin: $reuse_out"
fi
expect_contains "$reuse_out" "already pins $orph_sha" "pin reuse: refusal names the earlier pin"
expect_contains "$reuse_out" "git update-ref -d 'refs/session-cleanup/pin/pin-reuse' $orph_sha" "pin reuse: refusal drop remedy is compare-and-delete"
[ "$(git -C "$fixture" rev-parse --quiet --verify refs/session-cleanup/pin/pin-reuse)" = "$orph_sha" ] ||
    fail "pin reuse: the earlier pin was overwritten"
[ -d "$gitdir/worktrees/pin-reuse" ] || fail "pin reuse: the record was removed despite the refusal"

git -C "$fixture" update-ref -d refs/session-cleanup/pin/pin-reuse "$orph_sha"
if reuse_ok_out="$(cd "$fixture" && bash scripts/clean-worktree-records.sh 2>&1)"; then
    fail "record prune exited zero although its fresh pin awaits settlement: $reuse_ok_out"
fi
expect_contains "$reuse_ok_out" "pruned record 'pin-reuse'" "pin reuse: settled pin lets the removal proceed"
expect_contains "$reuse_ok_out" "PINNED  refs/session-cleanup/pin/pin-reuse" "pin reuse: fresh pin reported for explicit settlement"
expect_contains "$reuse_ok_out" "re-verify before dropping (GIT_GRAFT_FILE=/dev/null git --no-replace-objects" "pin reuse: the re-verification command itself disables grafts and replacements"
[ "$(git -C "$fixture" rev-parse --quiet --verify refs/session-cleanup/pin/pin-reuse)" = "$(git -C "$fixture" rev-parse main)" ] ||
    fail "pin reuse: fresh pin missing or wrong — pins must never be auto-dropped"
git -C "$fixture" update-ref -d refs/session-cleanup/pin/pin-reuse
echo "ok: an unsettled rescue pin refuses the prune instead of being overwritten"

# ── Case E7d: a record carrying worktree-local state is refused, not swept ─
# Sidecars and per-worktree ref files under worktrees/<id>/ are single-copy;
# no pin can stand in for them.

for rec in state-rec refs-rec op-rec cfg-rec stash-rec; do
    mkdir -p "$gitdir/worktrees/$rec"
    printf 'ref: refs/heads/main\n' >"$gitdir/worktrees/$rec/HEAD"
    printf '%s\n' "/nonexistent/$rec/.git" >"$gitdir/worktrees/$rec/gitdir"
done
mkdir -p "$gitdir/worktrees/state-rec/deferred-findings"
echo "p2 from a dead session" >"$gitdir/worktrees/state-rec/deferred-findings/some-branch"
mkdir -p "$gitdir/worktrees/refs-rec/refs/worktree"
refs_orph="$(git -C "$fixture" commit-tree "main^{tree}" -p main -m "worktree-ref orphan")"
printf '%s\n' "$refs_orph" >"$gitdir/worktrees/refs-rec/refs/worktree/only"
# A merge parked at an edit: MERGE_HEAD is sequencer state the record alone
# holds (the worktree-rm.sh op-state list).
git -C "$fixture" rev-parse main >"$gitdir/worktrees/op-rec/MERGE_HEAD"
# User-set per-worktree configuration is single-copy exactly like a sidecar.
printf '[review]\n\tunique = KEEP-ME\n' >"$gitdir/worktrees/cfg-rec/config.worktree"
# An interrupted merge --autostash: the stash commit can be referenced by
# this one file alone.
git -C "$fixture" rev-parse main >"$gitdir/worktrees/stash-rec/MERGE_AUTOSTASH"

if state_out="$(cd "$fixture" && bash scripts/clean-worktree-records.sh 2>&1)"; then
    fail "record prune exited zero with refused state-carrying records: $state_out"
fi
expect_contains "$state_out" "record 'state-rec' — carries worktree-local state (deferred-findings)" "state: sidecar-carrying record refused"
expect_contains "$state_out" "record 'refs-rec' — carries worktree-local state (refs)" "state: per-worktree-ref record refused"
expect_contains "$state_out" "record 'op-rec' — carries worktree-local state (MERGE_HEAD)" "state: in-progress-operation record refused"
expect_contains "$state_out" "record 'cfg-rec' — carries worktree-local state (config.worktree)" "state: per-worktree-config record refused"
expect_contains "$state_out" "record 'stash-rec' — carries worktree-local state (MERGE_AUTOSTASH)" "state: autostash record refused"
[ -d "$gitdir/worktrees/state-rec" ] || fail "state: sidecar-carrying record was swept"
[ -d "$gitdir/worktrees/refs-rec" ] || fail "state: ref-carrying record was swept"
[ -d "$gitdir/worktrees/op-rec" ] || fail "state: op-state record was swept"
git -C "$fixture" cat-file -e "$refs_orph" || fail "state: worktree-ref orphan commit lost"

rm -rf "$gitdir/worktrees/state-rec/deferred-findings" "$gitdir/worktrees/refs-rec/refs" "$gitdir/worktrees/op-rec/MERGE_HEAD" "$gitdir/worktrees/cfg-rec/config.worktree" "$gitdir/worktrees/stash-rec/MERGE_AUTOSTASH"
state_ok_out="$(cd "$fixture" && bash scripts/clean-worktree-records.sh 2>&1)" ||
    fail "record prune failed after the state was adopted: $state_ok_out"
expect_contains "$state_ok_out" "pruned record 'state-rec'" "state: adopted record prunes normally"
expect_contains "$state_ok_out" "pruned record 'refs-rec'" "state: rescued record prunes normally"
expect_contains "$state_ok_out" "pruned record 'op-rec'" "state: finished-operation record prunes normally"
expect_contains "$state_ok_out" "pruned record 'cfg-rec'" "state: adopted-config record prunes normally"
expect_contains "$state_ok_out" "pruned record 'stash-rec'" "state: recovered-autostash record prunes normally"
echo "ok: state-carrying records are refused until adopted, never swept"

# ── Case E7e: an index diverging from the recorded HEAD refuses the sweep ──
# Staged-but-uncommitted blobs can be referenced by the record's index
# alone; sweeping the record hands them to the next gc.

git -C "$fixture" worktree add -q --detach "$test_tmp/wt-staged" main
(
    cd "$test_tmp/wt-staged"
    echo staged-only >staged.txt
    git add staged.txt
)
rm -rf "$test_tmp/wt-staged"

if staged_out="$(cd "$fixture" && bash scripts/clean-worktree-records.sh 2>&1)"; then
    fail "record prune exited zero with a staged-divergent index present: $staged_out"
fi
expect_contains "$staged_out" "record 'wt-staged' — its index diverges from the recorded HEAD" "staged: divergent index refused"
expect_contains "$staged_out" "GIT_INDEX_FILE='" "staged: recovery command shell-quotes the index path"
[ -d "$gitdir/worktrees/wt-staged" ] || fail "staged: index-carrying record was swept"

rm -f "$gitdir/worktrees/wt-staged/index"
if staged_ok_out="$(cd "$fixture" && bash scripts/clean-worktree-records.sh 2>&1)"; then
    fail "record prune exited zero although the detached record's pin awaits settlement: $staged_ok_out"
fi
expect_contains "$staged_ok_out" "pruned record 'wt-staged'" "staged: adopted record prunes normally"
expect_contains "$staged_ok_out" "PINNED  refs/session-cleanup/pin/wt-staged" "staged: detached head pinned for explicit settlement"
git -C "$fixture" update-ref -d refs/session-cleanup/pin/wt-staged
echo "ok: a staged-divergent index refuses the sweep until adopted"

# ── Case E7f: record removal honors the worktree lifecycle lock ────────────
# A record for a tree under .worktrees/ takes the same per-path lock that
# worktree:new/rm hold, so removal cannot race a blessed re-creation.

mkdir -p "$gitdir/worktrees/lockrec"
printf 'ref: refs/heads/main\n' >"$gitdir/worktrees/lockrec/HEAD"
printf '%s\n' "$fixture/.worktrees/lockrec/.git" >"$gitdir/worktrees/lockrec/gitdir"
commondir_l="$(git -C "$fixture" rev-parse --path-format=absolute --git-common-dir)"
mkdir -p "$commondir_l/worktree-locks/lockrec+lock"

if lockrec_out="$(cd "$fixture" && bash scripts/clean-worktree-records.sh 2>&1)"; then
    fail "record prune exited zero although the lifecycle lock was held: $lockrec_out"
fi
expect_contains "$lockrec_out" "worktree lifecycle lock refused" "record lock: contended record skipped loudly"
[ -d "$gitdir/worktrees/lockrec" ] || fail "record lock: record removed although its lifecycle lock was held"

rmdir "$commondir_l/worktree-locks/lockrec+lock"
lockrec_ok_out="$(cd "$fixture" && bash scripts/clean-worktree-records.sh 2>&1)" ||
    fail "record prune failed after the lock was released: $lockrec_ok_out"
expect_contains "$lockrec_ok_out" "pruned record 'lockrec'" "record lock: released lock lets the removal proceed"
echo "ok: record removal is serialized by the worktree lifecycle lock"

# ── Case E7g: a replacement ref cannot forge the pin-drop remedy ───────────
# The kept-pin report picks its wording from raw history: a refs/replace
# graft that makes an orphan read as reachable from shared refs would
# otherwise print a copyable "drop it" command for the only real reference.

orph_g="$(git -C "$fixture" commit-tree "main^{tree}" -m "orphan-behind-replace")"
mkdir -p "$gitdir/worktrees/reptrap"
printf '%s\n' "$orph_g" >"$gitdir/worktrees/reptrap/HEAD"
printf '%s\n' "$test_tmp/gone-reptrap/.git" >"$gitdir/worktrees/reptrap/gitdir"
repg_main="$(git -C "$fixture" rev-parse refs/heads/main)"
repg_synth="$(git -C "$fixture" commit-tree "main^{tree}" -p "$repg_main" -p "$orph_g" -m "graft")"
git -C "$fixture" update-ref "refs/replace/$repg_main" "$repg_synth"

if repg_out="$(cd "$fixture" && bash scripts/clean-worktree-records.sh 2>&1)"; then
    fail "record prune exited zero although a forged-reachability pin should await settlement: $repg_out"
fi
git -C "$fixture" update-ref -d "refs/replace/$repg_main"
expect_contains "$repg_out" "KEPT  refs/session-cleanup/pin/reptrap" "replace ref: pin reported as the only reference"
expect_not_contains "$repg_out" "reachable from shared refs at prune time" "replace ref: forged containment does not invite dropping the pin"
git -C "$fixture" update-ref -d refs/session-cleanup/pin/reptrap
echo "ok: a replacement ref cannot forge the pin-drop remedy"

# ── Case E7h: a legacy graft file forces the conservative pin wording ──────
# info/grafts rewrites parentage and GIT_NO_REPLACE_OBJECTS does not cover
# it; while one exists, containment is not evidence and every kept pin gets
# the conservative wording.

orph_h="$(git -C "$fixture" commit-tree "main^{tree}" -m "orphan-behind-graft")"
mkdir -p "$gitdir/worktrees/grafttrap"
printf '%s\n' "$orph_h" >"$gitdir/worktrees/grafttrap/HEAD"
printf '%s\n' "$test_tmp/gone-grafttrap/.git" >"$gitdir/worktrees/grafttrap/gitdir"
printf '%s %s\n' "$(git -C "$fixture" rev-parse refs/heads/main)" "$orph_h" >"$gitdir/info/grafts"

if graftrec_out="$(cd "$fixture" && bash scripts/clean-worktree-records.sh 2>&1)"; then
    fail "record prune exited zero although a grafted-reachability pin should await settlement: $graftrec_out"
fi
rm -f "$gitdir/info/grafts"
expect_contains "$graftrec_out" "legacy graft file present" "grafts: presence announced by the record prune"
expect_contains "$graftrec_out" "KEPT  refs/session-cleanup/pin/grafttrap" "grafts: pin reported conservatively"
expect_not_contains "$graftrec_out" "reachable from shared refs at prune time" "grafts: grafted containment does not invite dropping the pin"
git -C "$fixture" update-ref -d refs/session-cleanup/pin/grafttrap
echo "ok: a legacy graft file forces the conservative pin wording"

# The two interleaving guards below need a mid-run event; a PATH shim around
# git injects it deterministically at the exact seam, then passes through.
shim_dir="$test_tmp/git-shim"
mkdir -p "$shim_dir"
real_git="$(command -v git)"

# ── Case E7i: a git worktree lock taken after the plan still protects ──────
# `git worktree prune` skips locked records at plan time, but a lock created
# between the plan and the removal (removable media coming under protection)
# must be honored by the re-check under the lifecycle lock.

mkdir -p "$gitdir/worktrees/lockedrec"
printf 'ref: refs/heads/main\n' >"$gitdir/worktrees/lockedrec/HEAD"
printf '%s\n' "/nonexistent/lockedrec/.git" >"$gitdir/worktrees/lockedrec/gitdir"
cat >"$shim_dir/git" <<SHIM
#!/usr/bin/env bash
if [[ "\$*" == *"worktree prune --dry-run"* ]]; then
    "$real_git" "\$@"
    touch "$gitdir/worktrees/lockedrec/locked"
    exit 0
fi
exec "$real_git" "\$@"
SHIM
chmod +x "$shim_dir/git"

if lockmark_out="$(cd "$fixture" && PATH="$shim_dir:$PATH" bash scripts/clean-worktree-records.sh 2>&1)"; then
    fail "record prune exited zero although a git worktree lock landed post-plan: $lockmark_out"
fi
expect_contains "$lockmark_out" "locked by git worktree lock since the plan" "post-plan lock: record skipped loudly"
[ -d "$gitdir/worktrees/lockedrec" ] || fail "post-plan lock: locked record was swept"

rm -f "$gitdir/worktrees/lockedrec/locked"
lockmark_ok_out="$(cd "$fixture" && bash scripts/clean-worktree-records.sh 2>&1)" ||
    fail "record prune failed after the git lock was released: $lockmark_ok_out"
expect_contains "$lockmark_ok_out" "pruned record 'lockedrec'" "post-plan lock: unlocked record prunes normally"
echo "ok: a git worktree lock taken after the plan still protects the record"

# ── Case E7j: a pin dropped mid-run by a racing settlement is re-asserted ──
# The audit advertises pins, so a human settlement can delete one in the
# window between the create and the record removal; the pin is re-asserted
# before the run reports it kept.

race_orph="$(git -C "$fixture" commit-tree "main^{tree}" -m "orphan-behind-race")"
mkdir -p "$gitdir/worktrees/racepin"
printf '%s\n' "$race_orph" >"$gitdir/worktrees/racepin/HEAD"
printf '%s\n' "/nonexistent/racepin/.git" >"$gitdir/worktrees/racepin/gitdir"
rm -f "$test_tmp/racepin-dropped"
cat >"$shim_dir/git" <<SHIM
#!/usr/bin/env bash
if [[ "\$1" == "update-ref" && "\$2" == "refs/session-cleanup/pin/racepin" && ! -e "$test_tmp/racepin-dropped" ]]; then
    touch "$test_tmp/racepin-dropped"
    "$real_git" "\$@" || exit \$?
    "$real_git" update-ref -d refs/session-cleanup/pin/racepin
    exit 0
fi
exec "$real_git" "\$@"
SHIM
chmod +x "$shim_dir/git"

if racepin_out="$(cd "$fixture" && PATH="$shim_dir:$PATH" bash scripts/clean-worktree-records.sh 2>&1)"; then
    fail "record prune exited zero although its re-asserted pin awaits settlement: $racepin_out"
fi
expect_contains "$racepin_out" "KEPT  refs/session-cleanup/pin/racepin" "pin race: pin reported kept"
[ "$(git -C "$fixture" rev-parse --quiet --verify refs/session-cleanup/pin/racepin)" = "$race_orph" ] ||
    fail "pin race: pin dropped mid-run was not re-asserted — the KEPT report is a lie"
git -C "$fixture" cat-file -e "$race_orph" || fail "pin race: orphan commit lost"
git -C "$fixture" update-ref -d refs/session-cleanup/pin/racepin
echo "ok: a pin dropped mid-run by a racing settlement is re-asserted"

# ── Case E7k: a failed record removal is loud and never lock-labeled ───────
# A partial rm is corrupt state needing inspection; reporting it as lock
# contention hands the operator the wrong remedy. An rm shim forces the
# failure deterministically — chmod tricks do not survive running as root
# (containers commonly do).

mkdir -p "$gitdir/worktrees/stuckrec"
printf 'ref: refs/heads/main\n' >"$gitdir/worktrees/stuckrec/HEAD"
printf '%s\n' "/nonexistent/stuckrec/.git" >"$gitdir/worktrees/stuckrec/gitdir"
real_rm="$(command -v rm)"
cat >"$shim_dir/rm" <<SHIM
#!/usr/bin/env bash
for a in "\$@"; do
    if [[ "\$a" == *"/worktrees/stuckrec" ]]; then
        echo "rm: simulated I/O failure" >&2
        exit 1
    fi
done
exec "$real_rm" "\$@"
SHIM
chmod +x "$shim_dir/rm"

if stuck_out="$(cd "$fixture" && PATH="$shim_dir:$PATH" bash scripts/clean-worktree-records.sh 2>&1)"; then
    rm -f "$shim_dir/rm"
    fail "record prune exited zero although removal failed: $stuck_out"
fi
rm -f "$shim_dir/rm"
expect_contains "$stuck_out" "removal failed midway" "rm failure: reported as its own outcome"
expect_not_contains "$stuck_out" "lifecycle lock refused" "rm failure: never mislabeled as lock contention"
[ -d "$gitdir/worktrees/stuckrec" ] || fail "rm failure: record vanished although rm was refused"

stuck_ok_out="$(cd "$fixture" && bash scripts/clean-worktree-records.sh 2>&1)" ||
    fail "record prune failed after the blocker was cleared: $stuck_ok_out"
expect_contains "$stuck_ok_out" "pruned record 'stuckrec'" "rm failure: unshimmed re-run prunes normally"
echo "ok: a failed record removal is loud and never lock-labeled"

# ── Case E7m: an unreachable ORIG_HEAD refuses the sweep ───────────────────
# ORIG_HEAD is a ref file, not a reflog: a reset --hard's abandoned commit
# can live in it alone, so reflog accepted-loss does not cover it. A
# reachable ORIG_HEAD sweeps normally.

orph_o="$(git -C "$fixture" commit-tree "main^{tree}" -m "reset-away")"
mkdir -p "$gitdir/worktrees/origrec"
printf 'ref: refs/heads/main\n' >"$gitdir/worktrees/origrec/HEAD"
printf '%s\n' "/nonexistent/origrec/.git" >"$gitdir/worktrees/origrec/gitdir"
printf '%s\n' "$orph_o" >"$gitdir/worktrees/origrec/ORIG_HEAD"

if orig_out="$(cd "$fixture" && bash scripts/clean-worktree-records.sh 2>&1)"; then
    fail "record prune exited zero with an unreachable ORIG_HEAD present: $orig_out"
fi
expect_contains "$orig_out" "ORIG_HEAD $orph_o is reachable from no shared ref" "orig-head: reset-away commit refused"
[ -d "$gitdir/worktrees/origrec" ] || fail "orig-head: record swept despite its unreachable ORIG_HEAD"
git -C "$fixture" cat-file -e "$orph_o" || fail "orig-head: reset-away commit lost"

git -C "$fixture" branch -q rescue-orig "$orph_o"
orig_ok_out="$(cd "$fixture" && bash scripts/clean-worktree-records.sh 2>&1)" ||
    fail "record prune failed after the ORIG_HEAD commit was rescued: $orig_ok_out"
expect_contains "$orig_ok_out" "pruned record 'origrec'" "orig-head: reachable ORIG_HEAD sweeps normally"
echo "ok: an unreachable ORIG_HEAD refuses the sweep until rescued"

# ── Case E7n: a record with an unreadable HEAD is refused, never swept ─────
# An empty or missing HEAD would fall through every HEAD-derived guard and
# sweep unpinned; an unvalidatable record fails closed.

mkdir -p "$gitdir/worktrees/noheadrec"
printf '%s\n' "/nonexistent/noheadrec/.git" >"$gitdir/worktrees/noheadrec/gitdir"

if nohead_out="$(cd "$fixture" && bash scripts/clean-worktree-records.sh 2>&1)"; then
    fail "record prune exited zero with an unvalidatable record present: $nohead_out"
fi
expect_contains "$nohead_out" "cannot read its HEAD" "no-head: unvalidatable record refused"
[ -d "$gitdir/worktrees/noheadrec" ] || fail "no-head: unvalidatable record was swept"

printf 'ref: refs/heads/main\n' >"$gitdir/worktrees/noheadrec/HEAD"
nohead_ok_out="$(cd "$fixture" && bash scripts/clean-worktree-records.sh 2>&1)" ||
    fail "record prune failed after HEAD was restored: $nohead_ok_out"
expect_contains "$nohead_ok_out" "pruned record 'noheadrec'" "no-head: restored record prunes normally"
echo "ok: a record with an unreadable HEAD is refused, never swept"

# ── Case E7o: a pin retargeted mid-run fails closed, never reported kept ───
# Existence alone verifies nothing: a pin rewritten between its creation
# and the post-removal check must fail the run loudly with a rescue remedy,
# not be overwritten and not be reported as keeping the commit.

ret_orph="$(git -C "$fixture" commit-tree "main^{tree}" -m "orphan-behind-retarget")"
ret_main="$(git -C "$fixture" rev-parse main)"
mkdir -p "$gitdir/worktrees/retarg"
printf '%s\n' "$ret_orph" >"$gitdir/worktrees/retarg/HEAD"
printf '%s\n' "/nonexistent/retarg/.git" >"$gitdir/worktrees/retarg/gitdir"
rm -f "$test_tmp/retarg-hit"
cat >"$shim_dir/git" <<SHIM
#!/usr/bin/env bash
if [[ "\$1" == "update-ref" && "\$2" == "refs/session-cleanup/pin/retarg" && ! -e "$test_tmp/retarg-hit" ]]; then
    touch "$test_tmp/retarg-hit"
    "$real_git" "\$@" || exit \$?
    "$real_git" update-ref refs/session-cleanup/pin/retarg "$ret_main"
    exit 0
fi
exec "$real_git" "\$@"
SHIM
chmod +x "$shim_dir/git"

if retarg_out="$(cd "$fixture" && PATH="$shim_dir:$PATH" bash scripts/clean-worktree-records.sh 2>&1)"; then
    fail "record prune exited zero although its pin was retargeted mid-run: $retarg_out"
fi
expect_contains "$retarg_out" "no longer pins $ret_orph" "pin retarget: OID mismatch fails closed with the rescue remedy"
expect_not_contains "$retarg_out" "KEPT  refs/session-cleanup/pin/retarg" "pin retarget: a retargeted pin is never reported as keeping the commit"
[ "$(git -C "$fixture" rev-parse --quiet --verify refs/session-cleanup/pin/retarg)" = "$ret_main" ] ||
    fail "pin retarget: the foreign write was overwritten — settlement is human-only"
git -C "$fixture" cat-file -e "$ret_orph" || fail "pin retarget: orphan commit lost from the object db"
short_r="$(printf '%.7s' "$ret_orph")"
[ "$(git -C "$fixture" rev-parse --quiet --verify "refs/session-cleanup/pin/retarg-rescue-$short_r")" = "$ret_orph" ] ||
    fail "pin retarget: no rescue ref re-protects the orphan whose record is already gone"
git -C "$fixture" update-ref -d "refs/session-cleanup/pin/retarg-rescue-$short_r"
git -C "$fixture" update-ref -d refs/session-cleanup/pin/retarg
echo "ok: a pin retargeted mid-run fails closed, never reported kept"

# ── Case E7p: an unresolvable detached HEAD refuses the sweep ──────────────
# A truncated HEAD, a missing object, or a promisor-held commit cannot be
# pinned; falling through to rm -rf would destroy the only recovery
# breadcrumb.

mkdir -p "$gitdir/worktrees/badheadrec"
printf '%s\n' "0123456789abcdef0123456789abcdef01234567" >"$gitdir/worktrees/badheadrec/HEAD"
printf '%s\n' "/nonexistent/badheadrec/.git" >"$gitdir/worktrees/badheadrec/gitdir"

if badhead_out="$(cd "$fixture" && bash scripts/clean-worktree-records.sh 2>&1)"; then
    fail "record prune exited zero with an unresolvable detached HEAD present: $badhead_out"
fi
expect_contains "$badhead_out" "does not resolve to a commit" "unresolvable: refusal names the failure"
[ -d "$gitdir/worktrees/badheadrec" ] || fail "unresolvable: record swept despite an unresolvable HEAD"

printf 'ref: refs/heads/main\n' >"$gitdir/worktrees/badheadrec/HEAD"
badhead_ok_out="$(cd "$fixture" && bash scripts/clean-worktree-records.sh 2>&1)" ||
    fail "record prune failed after the HEAD was repaired: $badhead_ok_out"
expect_contains "$badhead_ok_out" "pruned record 'badheadrec'" "unresolvable: repaired record prunes normally"
echo "ok: an unresolvable detached HEAD refuses the sweep"

# ── Case E7q: a failed state scan refuses the record, never sweeps it ──────
# An errored find is not an empty find: treating scan failure as "no state"
# would sweep exactly the record that could not be inspected.

mkdir -p "$gitdir/worktrees/scanfail/deferred-findings"
echo "p2 note" >"$gitdir/worktrees/scanfail/deferred-findings/some-branch"
printf 'ref: refs/heads/main\n' >"$gitdir/worktrees/scanfail/HEAD"
printf '%s\n' "/nonexistent/scanfail/.git" >"$gitdir/worktrees/scanfail/gitdir"
rm -f "$shim_dir/git"
cat >"$shim_dir/find" <<'SHIM'
#!/usr/bin/env bash
exit 1
SHIM
chmod +x "$shim_dir/find"

if scanfail_out="$(cd "$fixture" && PATH="$shim_dir:$PATH" bash scripts/clean-worktree-records.sh 2>&1)"; then
    fail "record prune exited zero although the state scan failed: $scanfail_out"
fi
expect_contains "$scanfail_out" "cannot scan deferred-findings" "scan failure: refused fail-closed"
[ -d "$gitdir/worktrees/scanfail" ] || fail "scan failure: uninspectable record was swept"

rm -f "$shim_dir/find"
rm -rf "$gitdir/worktrees/scanfail/deferred-findings"
scanfail_ok_out="$(cd "$fixture" && bash scripts/clean-worktree-records.sh 2>&1)" ||
    fail "record prune failed after the scan blocker was cleared: $scanfail_ok_out"
expect_contains "$scanfail_ok_out" "pruned record 'scanfail'" "scan failure: adopted record prunes normally"
echo "ok: a failed state scan refuses the record, never sweeps it"

# ── Case E7r: an unreachable FETCH_HEAD entry refuses the sweep ────────────
# A URL fetch of an unbranched tip (a PR head) can leave FETCH_HEAD as the
# only mapping to that commit; ordinary fetches list tips the tracking refs
# contain and sweep normally.

orph_f="$(git -C "$fixture" commit-tree "main^{tree}" -m "url-fetched-tip")"
mkdir -p "$gitdir/worktrees/fetchrec"
printf 'ref: refs/heads/main\n' >"$gitdir/worktrees/fetchrec/HEAD"
printf '%s\n' "/nonexistent/fetchrec/.git" >"$gitdir/worktrees/fetchrec/gitdir"
printf '%s\t\tbranch pr-head of https://example.invalid/repo\n' "$orph_f" >"$gitdir/worktrees/fetchrec/FETCH_HEAD"

if fetch_out="$(cd "$fixture" && bash scripts/clean-worktree-records.sh 2>&1)"; then
    fail "record prune exited zero with an unreachable FETCH_HEAD entry present: $fetch_out"
fi
expect_contains "$fetch_out" "FETCH_HEAD names $orph_f" "fetch-head: url-fetched tip refused"
short_f="$(printf '%.7s' "$orph_f")"
expect_contains "$fetch_out" "rescue/fetchrec-fetch-$short_f" "fetch-head: rescue name is per-OID, successive rescues cannot collide"
[ -d "$gitdir/worktrees/fetchrec" ] || fail "fetch-head: record swept despite its unreachable FETCH_HEAD"
git -C "$fixture" cat-file -e "$orph_f" || fail "fetch-head: fetched tip lost"

git -C "$fixture" branch -q rescue-fetch "$orph_f"
fetch_ok_out="$(cd "$fixture" && bash scripts/clean-worktree-records.sh 2>&1)" ||
    fail "record prune failed after the FETCH_HEAD commit was rescued: $fetch_ok_out"
expect_contains "$fetch_ok_out" "pruned record 'fetchrec'" "fetch-head: reachable FETCH_HEAD sweeps normally"
echo "ok: an unreachable FETCH_HEAD entry refuses the sweep until rescued"

# A truncated write can leave the final FETCH_HEAD record unterminated; the
# guard must validate that entry too, not skip it with the read loop.
orph_f2="$(git -C "$fixture" commit-tree "main^{tree}" -m "truncated-fetch-tip")"
mkdir -p "$gitdir/worktrees/fetchrec2"
printf 'ref: refs/heads/main\n' >"$gitdir/worktrees/fetchrec2/HEAD"
printf '%s\n' "/nonexistent/fetchrec2/.git" >"$gitdir/worktrees/fetchrec2/gitdir"
printf '%s\t\tbranch other of https://example.invalid/repo' "$orph_f2" >"$gitdir/worktrees/fetchrec2/FETCH_HEAD"

if fetch2_out="$(cd "$fixture" && bash scripts/clean-worktree-records.sh 2>&1)"; then
    fail "record prune exited zero with an unterminated FETCH_HEAD entry present: $fetch2_out"
fi
expect_contains "$fetch2_out" "FETCH_HEAD names $orph_f2" "fetch-head: unterminated final entry still validated"
[ -d "$gitdir/worktrees/fetchrec2" ] || fail "fetch-head: record swept despite its unterminated FETCH_HEAD entry"
rm -f "$gitdir/worktrees/fetchrec2/FETCH_HEAD"
fetch2_ok_out="$(cd "$fixture" && bash scripts/clean-worktree-records.sh 2>&1)" ||
    fail "record prune failed after the truncated FETCH_HEAD was removed: $fetch2_ok_out"
expect_contains "$fetch2_ok_out" "pruned record 'fetchrec2'" "fetch-head: cleared record prunes normally"
echo "ok: an unterminated FETCH_HEAD entry is still validated"

# ── Case E7t: an unreferenced annotated tag in FETCH_HEAD refuses the sweep ─
# Peeling the fetched OID to its commit would let the tag object itself —
# message and signature — vanish with the record; containment for a tag is
# exact points-at, not ancestry.

git -C "$fixture" tag -a -m "fetched annotated tag" tmp-fetched-tag main
tagoid_t="$(git -C "$fixture" rev-parse tmp-fetched-tag)"
git -C "$fixture" tag -d tmp-fetched-tag >/dev/null
mkdir -p "$gitdir/worktrees/tagrec"
printf 'ref: refs/heads/main\n' >"$gitdir/worktrees/tagrec/HEAD"
printf '%s\n' "/nonexistent/tagrec/.git" >"$gitdir/worktrees/tagrec/gitdir"
printf '%s\t\ttag fetched-tag of https://example.invalid/repo\n' "$tagoid_t" >"$gitdir/worktrees/tagrec/FETCH_HEAD"

if tagrec_out="$(cd "$fixture" && bash scripts/clean-worktree-records.sh 2>&1)"; then
    fail "record prune exited zero with an unreferenced annotated tag in FETCH_HEAD: $tagrec_out"
fi
expect_contains "$tagrec_out" "annotated tag object $tagoid_t with no ref pointing at it" "fetch-tag: unreferenced tag object refused"
[ -d "$gitdir/worktrees/tagrec" ] || fail "fetch-tag: record swept despite its unreferenced tag object"
git -C "$fixture" cat-file -e "$tagoid_t" || fail "fetch-tag: tag object lost"

git -C "$fixture" tag rescue-fetched-tag "$tagoid_t"
tagrec_ok_out="$(cd "$fixture" && bash scripts/clean-worktree-records.sh 2>&1)" ||
    fail "record prune failed after the tag object was rescued: $tagrec_ok_out"
expect_contains "$tagrec_ok_out" "pruned record 'tagrec'" "fetch-tag: referenced tag object sweeps normally"
echo "ok: an unreferenced annotated tag in FETCH_HEAD refuses the sweep until rescued"

# ── Case E7u: an unrecognized admin-dir entry refuses the sweep ────────────
# The sweep is allowlist-gated: git grows state files over time (sequencer/,
# AUTO_MERGE, ...) and enumerating dangerous ones loses that game — anything
# this tool does not understand fails closed.

mkdir -p "$gitdir/worktrees/oddrec/sequencer"
echo "pick deadbeef subject" >"$gitdir/worktrees/oddrec/sequencer/todo"
printf 'ref: refs/heads/main\n' >"$gitdir/worktrees/oddrec/HEAD"
printf '%s\n' "/nonexistent/oddrec/.git" >"$gitdir/worktrees/oddrec/gitdir"

if odd_out="$(cd "$fixture" && bash scripts/clean-worktree-records.sh 2>&1)"; then
    fail "record prune exited zero with an unrecognized admin entry present: $odd_out"
fi
expect_contains "$odd_out" "unrecognized entry 'sequencer'" "unknown entry: refused fail-closed"
[ -d "$gitdir/worktrees/oddrec" ] || fail "unknown entry: record swept despite unrecognized state"

rm -rf "$gitdir/worktrees/oddrec/sequencer"
mkdir -p "$gitdir/worktrees/oddrec/info"
echo "mystery" >"$gitdir/worktrees/oddrec/info/attributes-cache"
if oddinfo_out="$(cd "$fixture" && bash scripts/clean-worktree-records.sh 2>&1)"; then
    fail "record prune exited zero with an unrecognized info/ entry present: $oddinfo_out"
fi
expect_contains "$oddinfo_out" "unrecognized entry info/attributes-cache" "unknown info entry: refused fail-closed"
[ -d "$gitdir/worktrees/oddrec" ] || fail "unknown info entry: record swept despite unrecognized state"

rm -rf "$gitdir/worktrees/oddrec/info"
odd_ok_out="$(cd "$fixture" && bash scripts/clean-worktree-records.sh 2>&1)" ||
    fail "record prune failed after the unknown entries were adopted: $odd_ok_out"
expect_contains "$odd_ok_out" "pruned record 'oddrec'" "unknown entry: understood record prunes normally"
echo "ok: an unrecognized admin-dir entry refuses the sweep"

# ── Case E7v: an unreadable gitdir or a surviving tree directory refuses ───
# An unreadable gitdir target is not an absent worktree; and a worktree
# DIRECTORY that outlives its .git link still holds the user's files —
# sweeping the record would orphan them as a plain untracked directory.

mkdir -p "$gitdir/worktrees/nogit-rec"
printf 'ref: refs/heads/main\n' >"$gitdir/worktrees/nogit-rec/HEAD"

if nogit_out="$(cd "$fixture" && bash scripts/clean-worktree-records.sh 2>&1)"; then
    fail "record prune exited zero with an unreadable gitdir present: $nogit_out"
fi
expect_contains "$nogit_out" "cannot read its gitdir file" "no-gitdir: unvalidatable record refused"
[ -d "$gitdir/worktrees/nogit-rec" ] || fail "no-gitdir: record swept despite its unreadable gitdir"
printf '%s\n' "/nonexistent/nogit-rec/.git" >"$gitdir/worktrees/nogit-rec/gitdir"
nogit_ok_out="$(cd "$fixture" && bash scripts/clean-worktree-records.sh 2>&1)" ||
    fail "record prune failed after the gitdir was restored: $nogit_ok_out"
expect_contains "$nogit_ok_out" "pruned record 'nogit-rec'" "no-gitdir: restored record prunes normally"

mkdir -p "$test_tmp/live-dir"
echo "precious" >"$test_tmp/live-dir/work.txt"
mkdir -p "$gitdir/worktrees/livedir-rec"
printf 'ref: refs/heads/main\n' >"$gitdir/worktrees/livedir-rec/HEAD"
printf '%s\n' "$test_tmp/live-dir/.git" >"$gitdir/worktrees/livedir-rec/gitdir"

if livedir_out="$(cd "$fixture" && bash scripts/clean-worktree-records.sh 2>&1)"; then
    fail "record prune exited zero although the worktree directory survives: $livedir_out"
fi
expect_contains "$livedir_out" "its worktree directory still exists" "live-dir: surviving directory refused"
[ -d "$gitdir/worktrees/livedir-rec" ] || fail "live-dir: record swept although its directory survives"
rm -rf "$test_tmp/live-dir"
livedir_ok_out="$(cd "$fixture" && bash scripts/clean-worktree-records.sh 2>&1)" ||
    fail "record prune failed after the directory was moved aside: $livedir_ok_out"
expect_contains "$livedir_ok_out" "pruned record 'livedir-rec'" "live-dir: cleared record prunes normally"

# A gitdir value without the /.git suffix is malformed AND would skip the
# surviving-directory guard above — it must refuse outright.
mkdir -p "$gitdir/worktrees/badsuffix-rec"
printf 'ref: refs/heads/main\n' >"$gitdir/worktrees/badsuffix-rec/HEAD"
printf '%s\n' "/nonexistent/badsuffix-rec/.gi" >"$gitdir/worktrees/badsuffix-rec/gitdir"
if badsuffix_out="$(cd "$fixture" && bash scripts/clean-worktree-records.sh 2>&1)"; then
    fail "record prune exited zero with a malformed gitdir suffix present: $badsuffix_out"
fi
expect_contains "$badsuffix_out" "gitdir value does not end in /.git" "bad-suffix: malformed gitdir refused"
[ -d "$gitdir/worktrees/badsuffix-rec" ] || fail "bad-suffix: record swept despite its malformed gitdir"
printf '%s\n' "/nonexistent/badsuffix-rec/.git" >"$gitdir/worktrees/badsuffix-rec/gitdir"
badsuffix_ok_out="$(cd "$fixture" && bash scripts/clean-worktree-records.sh 2>&1)" ||
    fail "record prune failed after the gitdir was repaired: $badsuffix_ok_out"
expect_contains "$badsuffix_ok_out" "pruned record 'badsuffix-rec'" "bad-suffix: repaired record prunes normally"
echo "ok: an unreadable gitdir or a surviving tree directory refuses the sweep"

# ── Case E7w: resolve-undo state in a stage-0-clean index refuses ──────────
# After a conflict is resolved back to HEAD's content, the index compares
# clean yet its resolve-undo section still holds conflict-stage OIDs the
# index alone references.

blob_t="$(printf 'theirs\n' | git -C "$fixture" hash-object -w --stdin)"
reuc_idx="$test_tmp/reuc-idx"
GIT_INDEX_FILE="$reuc_idx" git -C "$fixture" read-tree main
GIT_INDEX_FILE="$reuc_idx" git -C "$fixture" update-index --add --cacheinfo "100644,$blob_t,cf.txt"
ttree="$(GIT_INDEX_FILE="$reuc_idx" git -C "$fixture" write-tree)"
tcommit="$(git -C "$fixture" commit-tree "$ttree" -p main -m theirs)"
git -C "$fixture" worktree add -q -b reuc-br "$test_tmp/wt-reuc" main
(
    cd "$test_tmp/wt-reuc"
    printf 'ours\n' >cf.txt
    git add cf.txt
    git commit -qm ours
    git merge -q "$tcommit" >/dev/null 2>&1 || true
    git checkout -q --ours -- cf.txt
    git add cf.txt
)
reuc_admin="$gitdir/worktrees/wt-reuc"
rm -rf "$test_tmp/wt-reuc"
rm -f "$reuc_admin/MERGE_HEAD" "$reuc_admin/MERGE_MSG" "$reuc_admin/MERGE_MODE" "$reuc_admin/AUTO_MERGE" "$reuc_admin/ORIG_HEAD"

if reuc_out="$(cd "$fixture" && bash scripts/clean-worktree-records.sh 2>&1)"; then
    fail "record prune exited zero with resolve-undo state present: $reuc_out"
fi
expect_contains "$reuc_out" "carries resolve-undo (conflict) state" "resolve-undo: clean-looking index refused"
[ -d "$reuc_admin" ] || fail "resolve-undo: record swept despite conflict state"

# An uninspectable index refuses the same way an unscannable state dir does.
rm -f "$shim_dir/find"
cat >"$shim_dir/git" <<SHIM
#!/usr/bin/env bash
if [[ "\$*" == *"ls-files --resolve-undo"* ]]; then
    exit 1
fi
exec "$real_git" "\$@"
SHIM
chmod +x "$shim_dir/git"
if reuc_shim_out="$(cd "$fixture" && PATH="$shim_dir:$PATH" bash scripts/clean-worktree-records.sh 2>&1)"; then
    fail "record prune exited zero although the index was uninspectable: $reuc_shim_out"
fi
expect_contains "$reuc_shim_out" "cannot inspect its index for resolve-undo state" "resolve-undo inspect: failure refused fail-closed"
[ -d "$reuc_admin" ] || fail "resolve-undo inspect: record swept although the index was uninspectable"
rm -f "$shim_dir/git"

rm -f "$reuc_admin/index"
reuc_ok_out="$(cd "$fixture" && bash scripts/clean-worktree-records.sh 2>&1)" ||
    fail "record prune failed after the resolve-undo state was recovered: $reuc_ok_out"
expect_contains "$reuc_ok_out" "pruned record 'wt-reuc'" "resolve-undo: recovered record prunes normally"
echo "ok: resolve-undo state in a clean index refuses the sweep"

# ── Case E7x: symlinked state paths are carried state, broken links judged ─
# find scans a symlink's target (or nothing when broken), never the link;
# and [ -e ] dereferences, so a broken unknown symlink would slip past the
# allowlist unjudged.

mkdir -p "$gitdir/worktrees/symrec"
printf 'ref: refs/heads/main\n' >"$gitdir/worktrees/symrec/HEAD"
printf '%s\n' "/nonexistent/symrec/.git" >"$gitdir/worktrees/symrec/gitdir"
ln -s /nonexistent-target "$gitdir/worktrees/symrec/refs"

if symrec_out="$(cd "$fixture" && bash scripts/clean-worktree-records.sh 2>&1)"; then
    fail "record prune exited zero with a symlinked state path present: $symrec_out"
fi
expect_contains "$symrec_out" "carries worktree-local state (refs)" "symlink: linked state path refused as carried"
[ -d "$gitdir/worktrees/symrec" ] || fail "symlink: record swept despite a symlinked state path"

rm -f "$gitdir/worktrees/symrec/refs"
ln -s /nowhere-at-all "$gitdir/worktrees/symrec/mystery-link"
if symrec2_out="$(cd "$fixture" && bash scripts/clean-worktree-records.sh 2>&1)"; then
    fail "record prune exited zero with a broken unknown symlink present: $symrec2_out"
fi
expect_contains "$symrec2_out" "unrecognized entry 'mystery-link'" "symlink: broken unknown link judged, not skipped"
[ -d "$gitdir/worktrees/symrec" ] || fail "symlink: record swept despite a broken unknown symlink"

rm -f "$gitdir/worktrees/symrec/mystery-link"
symrec_ok_out="$(cd "$fixture" && bash scripts/clean-worktree-records.sh 2>&1)" ||
    fail "record prune failed after the symlinks were cleared: $symrec_ok_out"
expect_contains "$symrec_ok_out" "pruned record 'symrec'" "symlink: cleared record prunes normally"
echo "ok: symlinked state paths are carried state and broken links are judged"

# ── Case E7y: an allowlisted name of the wrong type refuses the sweep ──────
# ORIG_HEAD as a DIRECTORY skips its -f validator yet a basename-only
# allowlist would still admit it and rm -rf its contents.

mkdir -p "$gitdir/worktrees/typerec/ORIG_HEAD"
echo "trapped" >"$gitdir/worktrees/typerec/ORIG_HEAD/contents"
printf 'ref: refs/heads/main\n' >"$gitdir/worktrees/typerec/HEAD"
printf '%s\n' "/nonexistent/typerec/.git" >"$gitdir/worktrees/typerec/gitdir"

if typerec_out="$(cd "$fixture" && bash scripts/clean-worktree-records.sh 2>&1)"; then
    fail "record prune exited zero with a mistyped allowlisted entry present: $typerec_out"
fi
expect_contains "$typerec_out" "entry 'ORIG_HEAD' is not the regular file git writes there" "type gate: mistyped entry refused"
[ -d "$gitdir/worktrees/typerec" ] || fail "type gate: record swept despite malformed state"

rm -rf "$gitdir/worktrees/typerec/ORIG_HEAD"

# info as a regular FILE matches no child glob and would otherwise be
# accepted uninspected — the same gate, one level up.
echo "not-a-directory" >"$gitdir/worktrees/typerec/info"
if typeinfo_out="$(cd "$fixture" && bash scripts/clean-worktree-records.sh 2>&1)"; then
    fail "record prune exited zero with a non-directory info entry present: $typeinfo_out"
fi
expect_contains "$typeinfo_out" "entry 'info' is not the directory git writes there" "type gate: non-directory info refused"
[ -d "$gitdir/worktrees/typerec" ] || fail "type gate: record swept despite a non-directory info entry"
rm -f "$gitdir/worktrees/typerec/info"

typerec_ok_out="$(cd "$fixture" && bash scripts/clean-worktree-records.sh 2>&1)" ||
    fail "record prune failed after the malformed entry was cleared: $typerec_ok_out"
expect_contains "$typerec_ok_out" "pruned record 'typerec'" "type gate: well-formed record prunes normally"
echo "ok: an allowlisted name of the wrong type refuses the sweep"

# ── Case E7z: a gitdir that changed across the lock refuses the sweep ──────
# The lifecycle lock is keyed off a pre-lock gitdir read; a record replaced
# while the lock is approached could otherwise be validated under no lock
# (or the wrong key) and swept mid-creation.

mkdir -p "$gitdir/worktrees/lockswap"
printf 'ref: refs/heads/main\n' >"$gitdir/worktrees/lockswap/HEAD"
printf '%s\n' "$fixture/.worktrees/lockswap/.git" >"$gitdir/worktrees/lockswap/gitdir"
rm -f "$test_tmp/lockswap-hit"
cat >"$shim_dir/cat" <<SHIM
#!/usr/bin/env bash
if [[ "\${1:-}" == *"/worktrees/lockswap/gitdir" && ! -e "$test_tmp/lockswap-hit" ]]; then
    touch "$test_tmp/lockswap-hit"
    echo "$fixture/.worktrees/other-tree/.git"
    exit 0
fi
exec /bin/cat "\$@"
SHIM
chmod +x "$shim_dir/cat"

if lockswap_out="$(cd "$fixture" && PATH="$shim_dir:$PATH" bash scripts/clean-worktree-records.sh 2>&1)"; then
    fail "record prune exited zero although the lock key drifted: $lockswap_out"
fi
rm -f "$shim_dir/cat"
expect_contains "$lockswap_out" "gitdir changed while the lock was being acquired" "lock-key drift: refused for a re-run"
[ -d "$gitdir/worktrees/lockswap" ] || fail "lock-key drift: record swept under a missing or wrong lock"

lockswap_ok_out="$(cd "$fixture" && bash scripts/clean-worktree-records.sh 2>&1)" ||
    fail "record prune failed on the stable re-run: $lockswap_ok_out"
expect_contains "$lockswap_ok_out" "pruned record 'lockswap'" "lock-key drift: stable re-run prunes normally"
echo "ok: a gitdir that changed across the lock refuses the sweep"

# ── Case E7s: pin-enumeration failure never reports cleanup complete ───────
# A broken ref backend is not an empty pin namespace; the empty-plan path
# must fail closed instead of printing "nothing to prune" with exit 0.

rm -f "$shim_dir/find"
cat >"$shim_dir/git" <<SHIM
#!/usr/bin/env bash
if [[ "\$*" == *"--count=1 refs/session-cleanup/pin"* ]]; then
    echo "fatal: simulated ref backend failure" >&2
    exit 1
fi
exec "$real_git" "\$@"
SHIM
chmod +x "$shim_dir/git"

if enum_out="$(cd "$fixture" && PATH="$shim_dir:$PATH" bash scripts/clean-worktree-records.sh 2>&1)"; then
    fail "record prune exited zero although pin enumeration failed: $enum_out"
fi
expect_contains "$enum_out" "cannot enumerate rescue pins" "pin enumeration: failure refuses to report completion"
expect_not_contains "$enum_out" "nothing to prune." "pin enumeration: no false cleanup-complete report"
rm -f "$shim_dir/git"
echo "ok: pin-enumeration failure never reports cleanup complete"

# A failed dry run surfaces git's own diagnostic, never a bare set -e death.
cat >"$shim_dir/git" <<SHIM
#!/usr/bin/env bash
if [[ "\$*" == *"worktree prune --dry-run"* ]]; then
    echo "fatal: simulated metadata corruption" >&2
    exit 128
fi
exec "$real_git" "\$@"
SHIM
chmod +x "$shim_dir/git"
if planfail_out="$(cd "$fixture" && PATH="$shim_dir:$PATH" bash scripts/clean-worktree-records.sh 2>&1)"; then
    fail "record prune exited zero although the dry-run failed: $planfail_out"
fi
expect_contains "$planfail_out" "worktree prune --dry-run failed" "plan failure: named as the failing step"
expect_contains "$planfail_out" "simulated metadata corruption" "plan failure: git's own diagnostic preserved"
rm -f "$shim_dir/git"
echo "ok: a failed dry run surfaces its diagnostic"

# A failed FULL pin enumeration must not print an unreliable settlement
# total beside the summary.
git -C "$fixture" update-ref refs/session-cleanup/pin/stale-old "$(git -C "$fixture" rev-parse main)"
mkdir -p "$gitdir/worktrees/enumrec"
printf 'ref: refs/heads/main\n' >"$gitdir/worktrees/enumrec/HEAD"
printf '%s\n' "/nonexistent/enumrec/.git" >"$gitdir/worktrees/enumrec/gitdir"
cat >"$shim_dir/git" <<SHIM
#!/usr/bin/env bash
if [[ "\$*" == *"for-each-ref refs/session-cleanup/pin"* && "\$*" != *"--count=1"* ]]; then
    exit 1
fi
exec "$real_git" "\$@"
SHIM
chmod +x "$shim_dir/git"
if totalfail_out="$(cd "$fixture" && PATH="$shim_dir:$PATH" bash scripts/clean-worktree-records.sh 2>&1)"; then
    fail "record prune exited zero although the total-pin enumeration failed: $totalfail_out"
fi
expect_contains "$totalfail_out" "refusing to report an unreliable settlement count" "total enumeration: failure refused, no fabricated count"
rm -f "$shim_dir/git"
git -C "$fixture" update-ref -d refs/session-cleanup/pin/stale-old
echo "ok: a failed total-pin enumeration never fabricates a count"

# ── Case E8: a renamed remote default refuses every deletion ───────────────
# The local origin/HEAD still names the old default; the live remote HEAD
# must be verified before any evidence computed against the old name is
# trusted (challenge r4).

ren_tip="$(make_branch anc-ren ren.txt)"
(
    cd "$fixture"
    git merge -q --ff-only anc-ren
    git push -q origin main
)
retire_remote anc-ren

git -C "$origin" branch trunk main
git -C "$origin" symbolic-ref HEAD refs/heads/trunk
ren_out="$(cd "$fixture" && bash scripts/clean-branches.sh --delete 2>&1)" ||
    fail "renamed-default run exited nonzero: $ren_out"
expect_contains "$ren_out" "default branch is now 'trunk'" "rename: live default named in the note"
expect_contains "$ren_out" "could not be verified as 'main'" "rename: deletions refused"
branch_exists anc-ren || fail "rename: anc-ren deleted although the remote default moved"
ren_audit_out="$(cd "$fixture" && bash scripts/audit-session-artifacts.sh 2>&1)" ||
    fail "audit exited nonzero inside the renamed-default window: $ren_audit_out"
expect_contains "$ren_audit_out" "default branch is now 'trunk'" "rename: audit resolves the live default over stale origin/HEAD"

# A non-identity fetch refspec makes a tracking name a DESTINATION, not a
# remote branch — comparing them marks fresh refs stale and recommends a prune
# that can never clear the warning. Both tasks must decline to compare and say
# why, rather than emit something false (challenge r1). The audit copied this
# expression first, so both are asserted.
orig_fetch="$(git -C "$fixture" config --get remote.origin.fetch)"
git -C "$fixture" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/upstream/*'
spec_audit_out="$(cd "$fixture" && bash scripts/audit-session-artifacts.sh 2>&1)" ||
    fail "non-identity-refspec audit exited nonzero: $spec_audit_out"
expect_contains "$spec_audit_out" "non-identity refspec" "refspec: audit declines to compare (#958)"
expect_not_contains "$spec_audit_out" "deleted upstream" "refspec: audit emits no false staleness (#958)"
# ...and must then reach NO verdict at all. Both of the section's conclusions
# are claims about a comparison that did not happen — "fresh" asserts the refs
# match, and "-> N stale" asserts a count from an empty scan. An assertion
# naming only one of them passes while the other fires (found by mutant M8).
expect_not_contains "$spec_audit_out" "fresh — local tracking refs match" "refspec: audit does not claim fresh after skipping the comparison (#958)"
expect_not_contains "$spec_audit_out" "stale tracking ref(s):" "refspec: audit does not report a stale count after skipping the comparison (#958)"
git -C "$fixture" config remote.origin.fetch "$orig_fetch"

git -C "$origin" symbolic-ref HEAD refs/heads/main
git -C "$origin" update-ref -d refs/heads/trunk
ren_ok_out="$(cd "$fixture" && bash scripts/clean-branches.sh --delete 2>&1)" ||
    fail "post-rename-restore run exited nonzero: $ren_ok_out"
expect_contains "$ren_ok_out" "deleted  anc-ren" "rename: restored default lets the deletion proceed"
echo "ok: a renamed remote default fails every deletion closed"

# ── Case E9: the capped batch falls back to per-branch verification ────────
# With the listing capped at one row, evidence for a later branch is only
# reachable through the fallback probe — which must still deliver a deletion.

late_tip="$(make_branch sq-late late.txt)"
(
    cd "$fixture"
    echo late >late.txt
    git add late.txt
    git commit -qm "squash of sq-late"
    git push -q origin main
)
retire_remote sq-late
printf '%s\t%s\t%s\t%s\n' sq-late "$late_tip" 110 main >>"$GH_STUB_PRS"

late_out="$(cd "$fixture" && CLEAN_PR_LIMIT=1 bash scripts/clean-branches.sh --delete 2>&1)" ||
    fail "capped-batch run exited nonzero: $late_out"
expect_contains "$late_out" "hit its 1 cap" "cap: fallback engagement announced"
expect_contains "$late_out" "deleted  sq-late" "cap: fallback evidence still deletes"
branch_exists sq-late && fail "cap: sq-late still exists after fallback deletion"
branch_exists gone-tipdiff || fail "cap: fallback deleted gone-tipdiff despite its tip mismatch"
branch_exists sq-stacked || fail "cap: fallback deleted sq-stacked despite its non-default base"
echo "ok: capped merged-PR listing falls back per branch"

# ── Case E10: ancestry is re-validated against the verified advertised tip ─
# Mid-run, a "concurrent fetch" (stub side effect) swings both the origin
# default and the local tracking ref to a rewritten tip that does NOT
# contain the candidate: tip equality then passes, and only the delete-time
# ancestry re-validation stands between the branch and deletion.

race2_tip="$(make_branch anc-race race2.txt)"
(
    cd "$fixture"
    git merge -q --ff-only anc-race
    git push -q origin main
)
retire_remote anc-race

rw_out="$(cd "$fixture" && CLEAN_PR_LIMIT=1 GH_STUB_REWRITE=gone-nopr GH_STUB_ORIGIN="$origin" \
    bash scripts/clean-branches.sh --delete 2>&1)" ||
    fail "rewrite-race run exited nonzero: $rw_out"
expect_contains "$rw_out" "no longer an ancestor of the verified remote default tip" "rewrite race: re-validation refused"
branch_exists anc-race || fail "rewrite race: anc-race deleted although the verified tip no longer contains it"

git -C "$origin" update-ref refs/heads/main "$(git -C "$fixture" rev-parse main)"
git -C "$fixture" update-ref refs/remotes/origin/main "$(git -C "$fixture" rev-parse main)"
rw_ok_out="$(cd "$fixture" && bash scripts/clean-branches.sh --delete 2>&1)" ||
    fail "post-rewrite-restore run exited nonzero: $rw_ok_out"
expect_contains "$rw_ok_out" "deleted  anc-race" "rewrite race: restored default lets the deletion proceed"
echo "ok: ancestry deletion re-validates against the verified advertised tip"

# ── Case E11: one failed fallback probe fails the remaining set closed ─────
# With the batch capped and per-branch probes failing, the run must spend
# ONE bounded probe, not one per unmatched branch.

circ_out="$(cd "$fixture" && CLEAN_PR_LIMIT=1 GH_STUB_HEAD_FAIL=1 bash scripts/clean-branches.sh --delete 2>&1)" ||
    fail "circuit-breaker run exited nonzero: $circ_out"
expect_contains "$circ_out" "suspending remaining per-branch probes" "circuit: first failure trips the breaker"
expect_contains "$circ_out" "per-branch probes suspended after an earlier probe failure" "circuit: later branches skipped without probing"
branch_exists gone-nopr || fail "circuit: a branch was deleted while probes were failing"
echo "ok: a failed fallback probe suspends the remaining probes"

# ── Case E12: shell metacharacters in branch names stay inert in remedies ──
# Refnames legally carry \$ and friends; a copyable recovery command must
# quote them.

meta_tip="$(make_branch 'sq-$meta' meta.txt)"
(
    cd "$fixture"
    echo meta >meta.txt
    git add meta.txt
    git commit -qm "squash of sq-meta"
    git push -q origin main
)
retire_remote 'sq-$meta'
printf '%s\t%s\t%s\t%s\n' 'sq-$meta' "$meta_tip" 111 main >>"$GH_STUB_PRS"

meta_out="$(cd "$fixture" && bash scripts/clean-branches.sh --delete 2>&1)" ||
    fail "metachar run exited nonzero: $meta_out"
expect_contains "$meta_out" "recover: git branch 'sq-\$meta'" "metachar: recovery command quotes the branch name"
branch_exists 'sq-$meta' && fail "metachar: sq-\$meta still exists after evidenced deletion"
echo "ok: recovery commands shell-quote branch names"

# ── Case E13: replacement refs cannot forge ancestry evidence ──────────────
# A refs/replace graft can rewrite the default tip's parentage so an
# unmerged branch walks as an ancestor; evidence must be judged on raw
# history.

rep_tip="$(make_branch rep-trap trap.txt)"
rep_main="$(git -C "$fixture" rev-parse refs/remotes/origin/main)"
rep_synth="$(git -C "$fixture" commit-tree "main^{tree}" -p "$rep_tip" -m "graft")"
git -C "$fixture" update-ref "refs/replace/$rep_main" "$rep_synth"

rep_out="$(cd "$fixture" && bash scripts/clean-branches.sh 2>&1)" ||
    fail "replace-ref dry run exited nonzero: $rep_out"
git -C "$fixture" update-ref -d "refs/replace/$rep_main"
expect_not_contains "$rep_out" "WOULD DELETE  rep-trap" "replace ref: grafted parentage is not ancestry evidence"
branch_exists rep-trap || fail "replace ref: rep-trap vanished during a dry run"
echo "ok: replacement refs cannot forge ancestry evidence"

# ── Case E14: a dotted sibling's config never triggers a false WARN ────────
# branch "sq-dot.sub"'s keys flatten to branch.sq-dot.sub.*, which shares a
# prefix with branch.sq-dot.* — the leftover check must match the exact
# section.

dot_tip="$(make_branch sq-dot dot.txt)"
(
    cd "$fixture"
    echo dot >dot.txt
    git add dot.txt
    git commit -qm "squash of sq-dot"
    git push -q origin main
)
retire_remote sq-dot
printf '%s\t%s\t%s\t%s\n' sq-dot "$dot_tip" 112 main >>"$GH_STUB_PRS"
git -C "$fixture" config --local branch.sq-dot.sub.remote origin

dot_out="$(cd "$fixture" && bash scripts/clean-branches.sh --delete 2>&1)" ||
    fail "dotted-sibling run exited nonzero: $dot_out"
expect_contains "$dot_out" "deleted  sq-dot" "dotted sibling: evidenced deletion proceeds"
expect_not_contains "$dot_out" "WARN  sq-dot" "dotted sibling: no false leftover-config warning"
git -C "$fixture" config --local --remove-section branch.sq-dot.sub 2>/dev/null || true
echo "ok: leftover-config check matches the exact section"

# ── Case E15: a legacy graft file disables ancestry evidence ───────────────
# info/grafts rewrites parentage and GIT_NO_REPLACE_OBJECTS does not cover
# it; ancestry walked over grafts is not evidence.

graft_tip="$(make_branch anc-graft graft.txt)"
(
    cd "$fixture"
    git merge -q --ff-only anc-graft
    git push -q origin main
)
retire_remote anc-graft
printf '%s\n' "# legacy graft" >"$gitdir/info/grafts"

graft_out="$(cd "$fixture" && bash scripts/clean-branches.sh 2>&1)" ||
    fail "grafts dry run exited nonzero: $graft_out"
expect_contains "$graft_out" "legacy graft file present" "grafts: presence announced"
expect_not_contains "$graft_out" "WOULD DELETE  anc-graft" "grafts: ancestry evidence disabled"

rm -f "$gitdir/info/grafts"
graft_ok_out="$(cd "$fixture" && bash scripts/clean-branches.sh --delete 2>&1)" ||
    fail "post-grafts run exited nonzero: $graft_ok_out"
expect_contains "$graft_ok_out" "deleted  anc-graft" "grafts: removal restores ancestry evidence"
echo "ok: a legacy graft file fails ancestry evidence closed"

# ── Case E16: the audit adopts the advertised default when none is local ───
# origin/HEAD unset and a default named neither main nor master: the
# advertisement the freshness probe already read is the answer, not a reason
# to report UNVERIFIED.

o2="$test_tmp/o2.git"
f2="$test_tmp/f2"
git init -q --bare --initial-branch=trunk "$o2"
git clone -q "$o2" "$f2" 2>/dev/null
git -C "$f2" config user.email test@example.invalid
git -C "$f2" config user.name "Session Cleanup Test"
git -C "$f2" symbolic-ref HEAD refs/heads/trunk
(
    cd "$f2"
    echo base >README.md
    git add README.md
    git commit -qm "initial"
    git push -qu origin trunk
    git checkout -q -b g1 trunk
    echo g1 >g1.txt
    git add g1.txt
    git commit -qm "work on g1"
    git push -qu origin g1 2>/dev/null
    git checkout -q trunk
    echo g1 >g1.txt
    git add g1.txt
    git commit -qm "squash of g1"
    git push -q origin trunk
    git push -q origin :g1 2>/dev/null
    git fetch -qp origin
)
git -C "$f2" symbolic-ref --delete refs/remotes/origin/HEAD 2>/dev/null || true
g1_tip="$(git -C "$f2" rev-parse refs/heads/g1)"
printf '%s\t%s\t%s\t%s\n' g1 "$g1_tip" 201 trunk >>"$GH_STUB_PRS"
mkdir -p "$f2/scripts"
cp "$repo/scripts/audit-session-artifacts.sh" "$f2/scripts/"

nodef_out="$(cd "$f2" && bash scripts/audit-session-artifacts.sh 2>&1)" ||
    fail "no-local-default audit exited nonzero: $nodef_out"
expect_contains "$nodef_out" "using the remote's advertised 'trunk'" "no local default: advertisement adopted"
expect_contains "$nodef_out" "prunable      g1 — merged PR #201 into trunk" "no local default: classification still runs"
expect_not_contains "$nodef_out" "UNVERIFIED" "no local default: a successful advertisement is not UNVERIFIED"
echo "ok: the audit adopts the advertised default when no local record exists"

# ── Case E17: a slash-containing remote name does not mangle freshness ─────
# Remote names may legally contain slashes; a fixed strip depth would read
# every tracking ref as deleted upstream.

git -C "$f2" remote rename origin ns/origin 2>/dev/null
slash_out="$(cd "$f2" && bash scripts/audit-session-artifacts.sh 2>&1)" ||
    fail "slash-remote audit exited nonzero: $slash_out"
expect_contains "$slash_out" "fresh — local tracking refs match" "slash remote: tracking refs matched, not mangled"
expect_not_contains "$slash_out" "deleted upstream" "slash remote: no false deleted-upstream reports"
echo "ok: slash-containing remote names keep freshness accurate"

# ── Case F: the evidence rule is not bypassable by force ───────────────────

grep -q 'branch -D' "$repo/scripts/clean-branches.sh" &&
    fail "clean-branches.sh contains 'branch -D' — the evidence rule was bypassed"
grep -q 'branch -D' "$repo/scripts/audit-session-artifacts.sh" &&
    fail "audit-session-artifacts.sh contains 'branch -D'"
echo "ok: no force deletion anywhere in the cleanup surface"

# ── Case G: unknown arguments are refused ──────────────────────────────────

if (cd "$fixture" && bash scripts/clean-branches.sh --force >/dev/null 2>&1); then
    fail "clean-branches.sh accepted an unknown --force flag"
fi
echo "ok: unknown flags are refused"

echo "PASS: session-cleanup surface behaves (evidence-gated deletion, loud refusals, read-only audit)"
