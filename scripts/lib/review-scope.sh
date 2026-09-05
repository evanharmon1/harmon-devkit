#!/usr/bin/env bash
# review-scope.sh — resolve WHAT a local-CLI finder reviews.
#
# Sourced, never executed. `resolve_review_scope "$@"` consumes a finder
# runner's remaining arguments and sets three globals:
#
#   scope     — the prose sentence naming the target, for the instructions
#   manifest  — the authoritative git-generated changed-file manifest
#   focus     — any free-text focus the invoker appended
#
# Extracted from scripts/codex-review.sh when a second local-CLI finder runner
# (scripts/finder-review.sh, #796) needed the identical resolution. Every
# invariant below is load-bearing and was paid for once already: an empty
# scope must refuse NON-ZERO (a decline reads exactly like the clean pass a
# capped stage exits on), a branch carrying commits AND uncommitted work must
# review both halves, and a base that cannot be resolved is fatal rather than
# silently narrowed to the worktree. A second hand-rolled copy would re-lose
# them one at a time.
#
# The caller must already have cd'd to the repository root.

# Cap the manifest at 200 entries WITHOUT `head`: head exits early, the git
# producer takes SIGPIPE, and under `set -o pipefail` a >200-entry tree would
# abort the review before Codex ever runs. awk reads to EOF (no SIGPIPE) and
# marks the truncation so the reviewer knows to re-enumerate with git.
cap_manifest() {
    awk 'NR <= 200 { print } NR == 201 { print "... (manifest truncated at 200 entries; re-enumerate with git for the full set)" }'
}

# Every manifest and dirty-check goes through these, so no call site can forget
# the flags. Both spell out git's own defaults and therefore change nothing on
# a default config; they exist to neutralize repo/user settings that would
# otherwise hide real changes and make a non-empty target look empty —
# `status.showUntrackedFiles=no` (a tree whose only work is untracked reads
# clean) and `diff.ignoreSubmodules=all` / `submodule.<name>.ignore=all` (a
# commit that only bumps a submodule gitlink reads as no change at all).
git_status_porcelain() {
    git status --porcelain --untracked-files=all --ignore-submodules=none "$@"
}
git_diff_name_status() {
    git diff --name-status --ignore-submodules=none "$@"
}

# An empty scope has no correct outcome, so no target path may reach Codex
# with one. The model either invents a scope (reviewing whatever it can see)
# or declines — and a decline is textually indistinguishable from a clean
# pass, which is exactly what the local loop's exit condition reads. Refuse
# before spending the model call, and exit NON-ZERO: a capped challenge/review
# loop reads exit status, so a zero here would be banked as the clean pass the
# stage exits on.
refuse_empty_scope() {
    # $1 — the condition, $2 — how to fix it
    echo "Nothing to review: $1" >&2
    echo "$2" >&2
    exit 1
}

# --base reviews committed history only, so uncommitted work is silently out
# of scope. Say so — the surprise compounds when the working tree holds
# exactly the change the operator meant to review. Not applied to --commit:
# naming a specific sha already says the target is not "my current work".
warn_if_dirty() {
    [ -n "$(git_status_porcelain)" ] || return 0
    echo "Note: the working tree is dirty, and --base reviews committed history only." >&2
    echo "      Uncommitted changes are NOT in scope; drop the flag to review the" >&2
    echo "      commits and the working tree together, or pass --uncommitted for" >&2
    echo "      the working tree alone." >&2
}

# An explicit --base gets the same guarantee the auto-detect path already has:
# the comparison base must be the branch the PR will actually merge into. A
# local branch lagging its upstream is precisely the case that path resolves
# refs/remotes/origin/HEAD to avoid — with a stale base, commits that already
# merged upstream sit inside base...HEAD and get reviewed as if this branch
# introduced them. Observed cost: findings against a file the branch never
# touched, and a whole review round spent triaging them.
#
# Advisory, never fatal (exit stays 0): reviewing against a deliberately older
# base is a legitimate thing to ask for, and the run is advisory anyway.
#
# The trigger compares the two MERGE BASES, not "is the upstream tip an
# ancestor of HEAD". Contamination is a property of where each diff starts:
# base...HEAD begins at merge-base(base, HEAD), upstream...HEAD begins at
# merge-base(upstream, HEAD), and the commits the stale base drags in are
# exactly those the second reaches and the first does not. Counting them IS the
# test — a count of zero covers both innocent shapes without a special case:
# a branch carrying nothing of the upstream (the merge bases coincide, so
# base...HEAD is already correct and a warning would be crying wolf), and a
# base that has diverged ahead of its upstream rather than fallen behind.
#
# Testing the upstream tip instead would miss the ordinary half-updated branch
# — base at A, upstream since advanced A→B→C, HEAD carrying B but not yet C —
# where C is not an ancestor of HEAD and yet B's already-merged changes sit
# inside base...HEAD.
#
# Only a local branch has an upstream, and only its SHORT name answers to
# @{upstream} — `refs/heads/main@{upstream}` is not an upstream query and just
# fails, so the full-ref spelling that --base otherwise accepts would skip this
# check silently. Normalize through symbolic-full-name, which maps every local
# spelling (main, heads/main, refs/heads/main) onto one name and resolves tags,
# raw shas, and remote-qualified refs like origin/main to something outside
# refs/heads/ — none of which has an upstream to compare against, and
# origin/main is already the ref this warning would have recommended.
warn_if_base_stale() {
    local full ref upstream mb_base mb_up t_base t_up carried plural
    full="$(git rev-parse --symbolic-full-name "$1" 2>/dev/null || true)"
    case "$full" in
    refs/heads/*) ref="${full#refs/heads/}" ;;
    *) return 0 ;;
    esac
    upstream="$(git rev-parse --abbrev-ref "${ref}@{upstream}" 2>/dev/null || true)"
    [ -n "$upstream" ] || return 0
    mb_base="$(git merge-base "$ref" HEAD 2>/dev/null || true)"
    mb_up="$(git merge-base "$upstream" HEAD 2>/dev/null || true)"
    { [ -n "$mb_base" ] && [ -n "$mb_up" ]; } || return 0
    carried="$(git rev-list --count "${mb_base}..${mb_up}" 2>/dev/null || echo 0)"
    [ "$carried" -gt 0 ] || return 0
    # Commits are the unit of the count but trees are the unit of the review:
    # an upstream gap that nets out to nothing — a change and its revert — puts
    # commits between the two merge bases while leaving base...HEAD and
    # upstream...HEAD byte-identical. Codex would read the same diff either way,
    # so warning there is the same crying-wolf this check exists to avoid.
    t_base="$(git rev-parse "${mb_base}^{tree}" 2>/dev/null || true)"
    t_up="$(git rev-parse "${mb_up}^{tree}" 2>/dev/null || true)"
    [ "$t_base" != "$t_up" ] || return 0
    if [ "$carried" -eq 1 ]; then
        plural=""
    else
        plural="s"
    fi
    echo "Warning: base '$1' lags its upstream '${upstream}', so the review scope $1...HEAD" >&2
    echo "         contains ${carried} commit${plural} that already merged upstream." >&2
    echo "         Pass --base ${upstream} to review only this branch's changes." >&2
}

resolve_review_scope() {
    scope=""
    manifest=""
    focus=""
    review_diff_spec=""
    # Which explicit target flag was given, plus the wording its empty-scope
    # refusal should use. Resolved during parsing, acted on after it.
    target_kind=""
    empty_desc=""
    empty_hint=""
    # The --base ref itself, kept because the post-parse warnings need it: it is
    # otherwise only reachable interpolated into the scope sentence.
    base_ref=""
    require_single_target() {
        if [ -n "$scope" ]; then
            echo "conflicting target flags: --base, --uncommitted, and --commit are mutually exclusive." >&2
            exit 2
        fi
    }
    while [ $# -gt 0 ]; do
        case "$1" in
        --base)
            if [ $# -lt 2 ]; then
                echo "$1 requires a value" >&2
                exit 2
            fi
            require_single_target
            # Fail fast on a typo/stale/unfetched ref: without this, an expensive
            # Codex run would launch with a nonsense scope and no manifest.
            if ! git rev-parse --verify --quiet "$2^{commit}" >/dev/null; then
                echo "--base '$2' does not resolve to a commit (typo, or fetch the ref first)." >&2
                exit 2
            fi
            if ! git merge-base "$2" HEAD >/dev/null 2>&1; then
                echo "--base '$2' shares no merge base with HEAD (unrelated history) — the diff would be meaningless." >&2
                exit 2
            fi
            scope="Review the changes on the current branch relative to base branch '$2' (the merge-base diff $2...HEAD)."
            manifest="$(git_diff_name_status "$2...HEAD" 2>/dev/null | cap_manifest || true)"
            target_kind="base"
            review_diff_spec="base:$2"
            base_ref="$2"
            empty_desc="the merge-base diff $2...HEAD is empty — HEAD changes no files beyond '$2'."
            # --commit belongs here too: a branch whose commits net out to no change
            # (an add and its revert) is already committed and has a clean tree, so
            # both of the other two remedies would be dead ends.
            empty_hint="Drop --base to review the commits and the working tree together, pass --uncommitted for working-tree changes only, or --commit <sha> for a single commit."
            shift 2
            ;;
        --commit)
            if [ $# -lt 2 ]; then
                echo "$1 requires a value" >&2
                exit 2
            fi
            require_single_target
            if ! git rev-parse --verify --quiet "$2^{commit}" >/dev/null; then
                echo "--commit '$2' does not resolve to a commit." >&2
                exit 2
            fi
            scope="Review the changes introduced by commit $2."
            # First-parent diff for commits with a parent: diff-tree -m would also
            # emit each merge parent's diff, pulling pre-merge mainline files into
            # the "authoritative" manifest. --root covers parentless root commits.
            if git rev-parse --verify --quiet "$2^" >/dev/null; then
                manifest="$(git_diff_name_status "$2^" "$2" 2>/dev/null | cap_manifest || true)"
            else
                manifest="$(git diff-tree --no-commit-id --name-status -r --root --ignore-submodules=none "$2" 2>/dev/null | cap_manifest || true)"
            fi
            target_kind="commit"
            review_diff_spec="commit:$2"
            empty_desc="commit $2 changes no files (an empty commit, or a merge with no first-parent change)."
            empty_hint="Pass --base <ref> for a branch-scoped review, or name a commit that touches files."
            shift 2
            ;;
        --uncommitted)
            require_single_target
            scope="Review the uncommitted work in this repository: staged, unstaged, and untracked changes."
            manifest="$(git_status_porcelain | cap_manifest || true)"
            target_kind="uncommitted"
            review_diff_spec="worktree"
            empty_desc="the working tree is clean — there is no staged, unstaged, or untracked work."
            empty_hint="Pass --base <ref> to review the branch's commits instead."
            shift
            ;;
        *)
            focus="${focus:+${focus} }$1"
            shift
            ;;
        esac
    done

    # Checked after the parse loop, not inside it: an empty diff is a property of
    # a fully-resolved target, so reporting it mid-parse would mask a genuine
    # argument error (e.g. `--base <ref> --uncommitted` must still be rejected as
    # conflicting flags, whatever that base's diff contains).
    if [ "$target_kind" = "base" ]; then
        warn_if_dirty
        warn_if_base_stale "$base_ref"
    fi
    if [ -n "$target_kind" ] && [ -z "$manifest" ]; then
        refuse_empty_scope "$empty_desc" "$empty_hint"
    fi

    if [ -z "$scope" ]; then
        # BOTH halves are resolved before either is chosen, because a branch
        # carrying commits AND uncommitted work is the ordinary state mid-loop —
        # fixes are not committed until the PR stage — and the two scopes are
        # disjoint: `git status` sees the worktree, `${base}...HEAD` sees the
        # commits. Choosing one used to silently drop the other, so a re-run after
        # an uncommitted fix reviewed that fix alone and reported the clean pass
        # the challenge/review stage exits on: the pass attested to the fix rather
        # than to the change. Resolving both and reviewing both is what keeps the
        # exit condition honest without relying on the operator remembering to
        # commit between rounds.
        #
        # One `git status` call feeds both the choice and the manifest, so a tree
        # cleaned between two calls cannot make the run pick a scope it then fails
        # to enumerate.
        #
        # No `|| true` on either half here, unlike the explicit target flags above:
        # those refuse when their one manifest comes back empty, so a failed git
        # call there still fails closed. This path composes two halves, so a failure
        # swallowed into "" would leave the OTHER half non-empty, satisfy the guard,
        # and ship a partial review that exits 0 — the precise shape of the bug this
        # path exists to close.
        if ! dirty_manifest="$(git_status_porcelain | cap_manifest)"; then
            echo "git status failed; refusing rather than reading an unreadable worktree as clean." >&2
            exit 2
        fi

        # origin/HEAD (the remote's actual default branch) outranks local
        # branch-name guesses: a stray local `main` in a develop-default repo must
        # not silently become the comparison base. The remote-qualified ref is
        # kept as-is — stripping origin/ could name a branch that does not exist
        # locally. Name guesses only apply to remoteless repos.
        base="$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || true)"
        if [ -z "$base" ]; then
            for candidate in main master; do
                if git rev-parse --verify --quiet "$candidate" >/dev/null; then
                    base="$candidate"
                    break
                fi
            done
        fi
        # An unresolvable base is fatal, on a dirty tree as much as a clean one.
        # Degrading to the worktree half would be the old bug in a new place: the
        # run would review a fraction of the change and still exit 0, and the
        # stage's exit condition reads the status, not the stderr warning. Which
        # commits are missing is exactly what cannot be determined here, so there
        # is no honest partial scope to fall back to — make the narrowing an
        # explicit act instead. `--uncommitted` is the one-flag way to say "the
        # worktree really is all I want reviewed".
        base_problem=""
        if [ -z "$base" ] || ! git rev-parse --verify --quiet "$base" >/dev/null; then
            base_problem="no base branch could be detected (no origin/HEAD, no local main or master)"
        elif ! git merge-base "$base" HEAD >/dev/null 2>&1; then
            base_problem="the auto-detected base '${base}' shares no merge base with HEAD"
        fi
        if [ -n "$base_problem" ]; then
            # Not refuse_empty_scope: nothing was resolved to be empty. This is a
            # repository/argument problem, and it keeps the usage exit code (2)
            # the explicit target flags use for the same class of failure.
            echo "Could not resolve a base to review this branch against: ${base_problem}." >&2
            echo "Refusing rather than reviewing the working tree alone — a partial review that" >&2
            echo "exits 0 reads as the clean pass a challenge/review stage exits on." >&2
            echo "Name a target explicitly: --base <ref>, --uncommitted, or --commit <sha>." >&2
            exit 2
        fi
        # Commits beyond the base do not guarantee a non-empty diff (an empty
        # commit, or one later reverted), and an empty diff is indistinguishable
        # from no commits at all here — both simply leave this half out.
        if ! base_manifest="$(git_diff_name_status "${base}...HEAD" | cap_manifest)"; then
            echo "git diff ${base}...HEAD failed; refusing rather than reading an unreadable" >&2
            echo "branch diff as an empty half (a partial clone missing objects, for one)." >&2
            exit 2
        fi

        if [ -n "$base_manifest" ] && [ -n "$dirty_manifest" ]; then
            scope="Review the complete current change, which has two parts: (1) the commits on this branch relative to base branch '${base}' — the merge-base diff ${base}...HEAD — and (2) the uncommitted work in the working tree: staged, unstaged, and untracked changes. BOTH parts are in scope and must be reviewed as one change. The uncommitted part is typically a fix to the committed part, so do not treat either part as settled background for the other; a file may legitimately appear in both."
            # Each half is capped independently: a single 200-entry cap over the
            # concatenation would let a large committed half swallow the worktree
            # half whole, which is the exact silent narrowing this path exists to
            # prevent. The prompt goes over stdin, so the extra entries are cheap.
            manifest="Committed changes (git diff --name-status ${base}...HEAD):
${base_manifest}

Uncommitted changes (git status --porcelain):
${dirty_manifest}"
            review_diff_spec="both:${base}"
            echo "==> Reviewing branch changes against ${base} AND uncommitted work (both halves in scope)"
        elif [ -n "$dirty_manifest" ]; then
            scope="Review the uncommitted work in this repository: staged, unstaged, and untracked changes."
            manifest="$dirty_manifest"
            review_diff_spec="worktree"
            echo "==> Reviewing uncommitted work (HEAD changes no files beyond ${base})"
        elif [ -n "$base_manifest" ]; then
            scope="Review the changes on the current branch relative to base branch '${base}' (the merge-base diff ${base}...HEAD)."
            manifest="$base_manifest"
            review_diff_spec="base:${base}"
            echo "==> Reviewing branch changes against ${base} (clean working tree)"
        elif [ "$(git rev-list --count "${base}..HEAD" 2>/dev/null || echo 0)" -eq 0 ]; then
            refuse_empty_scope \
                "the working tree is clean and HEAD has no commits beyond ${base}." \
                "Pass --base <ref> or --commit <sha> to name a target explicitly."
        else
            refuse_empty_scope \
                "the working tree is clean and the merge-base diff ${base}...HEAD is empty — the commits beyond ${base} change no files." \
                "Pass --commit <sha> to review a specific commit."
        fi
    fi

    # Backstop for every path, so the invariant does not depend on each one
    # remembering it. The explicit target flags build their manifest through
    # `|| true`, so a git call that failed rather than returning nothing arrives
    # here as an empty one — and a new target path added later inherits the guard
    # for free instead of having to re-derive it.
    if [ -z "$manifest" ]; then
        refuse_empty_scope \
            "the resolved target contains no changed files." \
            "Name a target explicitly with --base <ref>, --commit <sha>, or --uncommitted."
    fi
}

# The DIFF for the scope `resolve_review_scope` just settled on, for a finder
# whose CLI is handed the change rather than sent to collect it itself. Never
# re-resolves the target: it replays `review_diff_spec`, so the diff and the
# manifest can never describe two different scopes.
#
# Untracked files are diffed one by one against /dev/null, because `git diff`
# alone cannot see them and a new file is exactly the thing a review most
# needs to read.
#
# NUL-delimited, not line-delimited: `git ls-files` QUOTES a path containing a
# newline by default, and the quoted display form is not a path `git diff` can
# open — so such a file would stay in the claimed scope while its contents were
# silently missing from the review.
#
# There is deliberately no per-file cap here. An earlier revision truncated at
# 200 files and returned success, which is the same defect the byte bound in
# scripts/finder-review.sh exists to prevent: a caller that grants the reviewer
# no repository tools cannot fetch what was cut, so a partial review could
# still exit clean and be banked as a complete round. Size is bounded once, by
# that caller, as a refusal.
collect_untracked_diff() {
    local path
    while IFS= read -r -d '' path; do
        [ -n "$path" ] || continue
        git diff --no-index --ignore-submodules=none -- /dev/null "$path" 2>/dev/null || true
    done < <(git ls-files -z --others --exclude-standard)
}

collect_review_diff() {
    case "$review_diff_spec" in
    base:*)
        git diff --ignore-submodules=none "${review_diff_spec#base:}...HEAD"
        ;;
    commit:*)
        local sha="${review_diff_spec#commit:}"
        if git rev-parse --verify --quiet "${sha}^" >/dev/null; then
            git diff --ignore-submodules=none "${sha}^" "$sha"
        else
            git diff-tree --no-commit-id -p -r --root --ignore-submodules=none "$sha"
        fi
        ;;
    worktree)
        git diff --ignore-submodules=none HEAD
        collect_untracked_diff
        ;;
    both:*)
        local base="${review_diff_spec#both:}"
        printf 'Committed changes (git diff %s...HEAD):\n' "$base"
        git diff --ignore-submodules=none "${base}...HEAD"
        printf '\nUncommitted changes (git diff HEAD, plus untracked files):\n'
        git diff --ignore-submodules=none HEAD
        collect_untracked_diff
        ;;
    *)
        echo "collect_review_diff: no resolved scope to diff" >&2
        return 2
        ;;
    esac
}
