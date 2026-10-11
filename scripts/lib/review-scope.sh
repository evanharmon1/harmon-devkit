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
    # `--no-ext-diff` on every diff this file takes: `diff.external` is
    # ordinary repo or user config, and a helper that exits 0 with no output
    # silently empties the manifest and the content diff alike, which reads as
    # "nothing changed" rather than as a failure.
    git diff --no-ext-diff --name-status --ignore-submodules=none "$@"
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
                manifest="$(git diff-tree --no-ext-diff --no-commit-id --name-status -r --root --ignore-submodules=none "$2" 2>/dev/null | cap_manifest || true)"
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
        --envelope | --run-id | --head | --stage | --round | --slot | --tier | --record-dir | --registry)
            # Read as focus text, a misplaced envelope flag would silently run
            # a prose-only pass the caller is waiting on as a published one.
            echo "$1 must come before the target flags and focus text" >&2
            exit 2
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
        base="$(review_default_base)"
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
    local path status listing
    # The producer's own status matters, so it is not run in a process
    # substitution: a failing `git ls-files` there is invisible, and the loop
    # would simply see no untracked files and report a complete diff.
    listing="$(mktemp)" || return 1
    git ls-files -z --others --exclude-standard >"$listing" || {
        rm -f "$listing"
        return 1
    }
    while IFS= read -r -d '' path; do
        [ -n "$path" ] || continue
        # Belt and braces, not a live bug fix. `git diff --no-index` really
        # does open a FIFO and block forever waiting for a writer — but
        # `git ls-files --others` above does not enumerate FIFOs, sockets or
        # devices at all, so one cannot reach this loop today. The check
        # guards the day that listing source changes, and costs one test per
        # path. A symlink is left to the diff, which renders it as its target
        # path rather than following it.
        if [ ! -L "$path" ] && [ ! -f "$path" ]; then
            rm -f "$listing"
            echo "collect_review_diff: untracked path is not a regular file or symlink, refusing the scope: $path" >&2
            return 1
        fi
        # `git diff --no-index` exits 1 when the two inputs DIFFER, which is
        # the normal outcome here — every untracked file differs from
        # /dev/null. Only 0 and 1 are success; anything else (the file
        # vanished, is unreadable, git failed) is a real error and must not be
        # swallowed, or the prompt would carry a partial diff while still
        # claiming the manifest above it is authoritative.
        status=0
        git diff --no-ext-diff --no-index --ignore-submodules=none -- /dev/null "$path" || status=$?
        case "$status" in
        0 | 1) ;;
        *)
            rm -f "$listing"
            echo "collect_review_diff: cannot diff untracked file: $path" >&2
            return 1
            ;;
        esac
    done <"$listing"
    rm -f "$listing"
}

# A scope that includes uncommitted work must refuse a dirty submodule rather
# than review around it. `git diff` renders a modified submodule as its gitlink
# marker (`Subproject commit ...-dirty`) and NOT as the changed lines inside
# it, and the scratch checkout leaves the submodule uninitialized — so the
# finder gets neither the content diff nor a tree it could inspect, while the
# manifest above the prompt claims the submodule is covered. A clean result
# could then be banked for a review that never saw the change. Capturing the
# nested diff properly is the better answer and is out of this change's scope;
# refusing is the honest one.
refuse_dirty_submodules() {
    local sm
    [ -f .gitmodules ] || return 0
    # '+' = the checked-out commit differs from the index, 'U' = conflicts.
    local _submodule_status
    _submodule_status="$(git submodule status --recursive 2>/dev/null)"
    if command grep -qE '^[+U]' <<<"$_submodule_status"; then
        echo "collect_review_diff: a submodule's checked-out commit differs from the index; refusing a scope that would review only the gitlink" >&2
        return 1
    fi
    # Paths come from `git submodule foreach`, which reports $sm_path exactly,
    # NUL-delimited. An earlier revision took the second whitespace-delimited
    # field of `git submodule status`, which truncates any path containing a
    # space — `deps/my lib` was inspected as `deps/my`, the guard accepted the
    # scope, and the finder received only the gitlink marker.
    while IFS= read -r -d '' sm; do
        [ -n "$sm" ] || continue
        # An uninitialized submodule has no .git to ask, and contributes no
        # uncommitted content to miss.
        [ -e "$sm/.git" ] || continue
        # `--untracked-files=all` explicitly, exactly as the top-level helper
        # does: a submodule inheriting `status.showUntrackedFiles=no` from repo
        # or user config reports nothing for untracked-only work, so the guard
        # accepted a scope whose submodule content the superproject diff cannot
        # show and the scratch checkout does not contain.
        if [ -n "$(git -C "$sm" status --porcelain --untracked-files=all 2>/dev/null)" ]; then
            echo "collect_review_diff: submodule '$sm' has uncommitted changes that a superproject diff cannot show; refusing the scope" >&2
            return 1
        fi
    done < <(git submodule foreach --recursive --quiet 'printf "%s\0" "$displaypath"' 2>/dev/null)
    return 0
}

collect_review_diff() {
    case "$review_diff_spec" in
    base:*)
        git diff --no-ext-diff --ignore-submodules=none "${review_diff_spec#base:}...HEAD"
        ;;
    range:*)
        # Envelope mode: two immutable SHAs, never a ref that can move after
        # the scope was bound (review_envelope_bind_scope).
        local range="${review_diff_spec#range:}"
        git diff --no-ext-diff --ignore-submodules=none "${range%%:*}" "${range#*:}"
        ;;
    commit:*)
        local sha="${review_diff_spec#commit:}"
        if git rev-parse --verify --quiet "${sha}^" >/dev/null; then
            git diff --no-ext-diff --ignore-submodules=none "${sha}^" "$sha"
        else
            git diff-tree --no-ext-diff --no-commit-id -p -r --root --ignore-submodules=none "$sha"
        fi
        ;;
    worktree)
        refuse_dirty_submodules || return 1
        git diff --no-ext-diff --ignore-submodules=none HEAD || return 1
        collect_untracked_diff || return 1
        ;;
    both:*)
        local base="${review_diff_spec#both:}"
        refuse_dirty_submodules || return 1
        printf 'Committed changes (git diff %s...HEAD):\n' "$base"
        # `|| return 1` on the COMMITTED half too. Without it a transient git
        # failure here was swallowed — this function is called from an `||`
        # list, so `set -e` does not apply — and the later worktree half's
        # success became the function's status. The prompt then said both
        # halves were present while carrying only one, which is the same
        # partial-review-reads-as-clean failure the empty-scope refusals exist
        # to prevent.
        git diff --no-ext-diff --ignore-submodules=none "${base}...HEAD" || return 1
        printf '\nUncommitted changes (git diff HEAD, plus untracked files):\n'
        git diff --no-ext-diff --ignore-submodules=none HEAD || return 1
        collect_untracked_diff || return 1
        ;;
    *)
        echo "collect_review_diff: no resolved scope to diff" >&2
        return 2
        ;;
    esac
}

# The SNAPSHOT the resolved scope describes, as "<committish> <0|1>" where the
# flag says whether the working tree's own changes are part of it. A finder is
# handed the diff, but it is an agent with read access to the tree it sits in,
# so that tree has to be the one the diff is about: reviewing `--commit <old>`
# against current HEAD, or `--uncommitted` against a tree without the
# uncommitted files, shows it surroundings that contradict its own input.
review_scope_snapshot() {
    case "$review_diff_spec" in
    commit:*) printf '%s 0' "${review_diff_spec#commit:}" ;;
    range:*) printf '%s 0' "${review_diff_spec##*:}" ;;
    worktree | both:*) printf 'HEAD 1' ;;
    base:*) printf 'HEAD 0' ;;
    *) return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# Envelope mode (harmon-devkit#941)
# ---------------------------------------------------------------------------
#
# With `--envelope`, a runner stops being a prose-only advisory pass and
# becomes the PRODUCER of one schema-bound `result.challenger` /
# `result.reviewer` envelope, published as one immutable file under the run
# record's `passes/`. It lives here, beside the scope it binds, because both
# runners need the identical contract and a second hand-rolled copy would
# drift the way the scope rules once did.
#
# What a runner in envelope mode does and does not do:
#   - binds the finder's structured payload to the captured run, head, stage,
#     round, finder and slot, and refuses a payload that names anything else;
#   - wraps it in the envelope, recording the CLI that actually ran (its
#     registry harness slug) as `producer.harness`;
#   - validates the complete envelope with dev-flow-support's
#     `validate-result-schemas.mjs envelope --receipt` before anything lands;
#   - publishes it with a HARD LINK into `passes/<stage>-r<round>-<slot>.json`.
#     link(2) fails when the destination exists, so publication is atomic and
#     no-clobber in one call: a timed-out original still running beside its
#     retry cannot overwrite what the retry published, and no check-then-
#     rename window exists for either to slip through;
#   - never writes `run.json`. Appending the `{kind: "pass"}` receipt is the
#     CALLER's step, so receipt authority stays with the orchestrator; a
#     published pass with no receipt is an orphan that no consumer counts
#     (review/SKILL.md § "Dispatch and receipt").
#
# Nothing partial is ever visible under a `.json` name: every intermediate is
# a dot-file without that suffix inside `passes/` (the same filesystem as the
# destination, which link(2) needs), removed on every exit path.

envelope_mode=false
envelope_run_id=
envelope_head=
envelope_stage=
envelope_round=
envelope_slot=
envelope_tier=
envelope_record_dir=
envelope_registry=
envelope_shift=0

# review_envelope_flag FLAG [VALUE] — consume one envelope-mode flag, setting
# `envelope_shift` to how many words it took. Returns 1 for anything that is
# not an envelope flag, so a runner's own parse loop can fall through to the
# scope arguments. A repeated flag is refused rather than last-wins: two
# values for one binding is an ambiguous caller, not a preference.
review_envelope_flag() {
    local var
    case "$1" in
    --envelope)
        [ "$envelope_mode" = false ] || {
            echo "--envelope may be specified only once" >&2
            exit 2
        }
        envelope_mode=true
        envelope_shift=1
        return 0
        ;;
    --run-id) var=envelope_run_id ;;
    --head) var=envelope_head ;;
    --stage) var=envelope_stage ;;
    --round) var=envelope_round ;;
    --slot) var=envelope_slot ;;
    --tier) var=envelope_tier ;;
    --record-dir) var=envelope_record_dir ;;
    --registry) var=envelope_registry ;;
    *) return 1 ;;
    esac
    [ $# -ge 2 ] && [ -n "$2" ] || {
        echo "$1 requires a value" >&2
        exit 2
    }
    [ -z "${!var}" ] || {
        echo "$1 may be specified only once" >&2
        exit 2
    }
    printf -v "$var" '%s' "$2"
    envelope_shift=2
}

# The repository's default branch as a ref: origin/HEAD first (the remote's
# real default), then a local main/master for a remoteless repository. Shared
# by the auto-detected scope above and the envelope scope binding below.
review_default_base() {
    local candidate base
    base="$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || true)"
    if [ -z "$base" ]; then
        for candidate in main master; do
            if git rev-parse --verify --quiet "$candidate" >/dev/null; then
                base="$candidate"
                break
            fi
        done
    fi
    printf '%s' "$base"
}

# dev-flow-support's assets directory: the validator and the schema family it
# validates against. Source tree first, then the two vendored layouts — a
# consumer has no repository-root copy (harmon-devkit#974).
review_envelope_support_dir() {
    local candidate
    for candidate in ai/skills/universal/dev-flow-support/assets \
        .agents/skills/dev-flow-support/assets \
        .claude/skills/dev-flow-support/assets; do
        if [ -f "$candidate/validate-result-schemas.mjs" ] &&
            [ -f "$candidate/schemas/result.challenger.schema.json" ]; then
            (cd "$candidate" && pwd -P)
            return 0
        fi
    done
    return 1
}

# review_envelope_prepare MODE FINDER_SLUG HARNESS — validate every
# envelope input before any model call, and set the derived values the later
# steps use: envelope_role, envelope_initiated_by, envelope_substitutes_for,
# envelope_support_dir, envelope_payload_schema, envelope_pass_path.
# Usage errors exit 2; a binding that is well-formed but false (HEAD moved,
# run.json names another run) exits 1.
review_envelope_prepare() {
    local mode="$1" finder_slug="$2" harness="$3" required flag actual_head slot_entry
    for required in run_id head stage round slot tier record_dir; do
        flag="--${required//_/-}"
        required="envelope_${required}"
        [ -n "${!required}" ] || {
            echo "--envelope requires ${flag}" >&2
            exit 2
        }
    done
    : "${envelope_registry:=agent-registry.json}"
    [ "$envelope_stage" = "$mode" ] || {
        echo "--stage $envelope_stage does not match mode $mode" >&2
        exit 2
    }
    [[ "$envelope_head" =~ ^[0-9a-f]{40}$ ]] || {
        echo "--head must be a 40-character lowercase commit sha" >&2
        exit 2
    }
    [[ "$envelope_round" =~ ^[1-9][0-9]{0,5}$ ]] || {
        echo "--round must be a positive integer" >&2
        exit 2
    }
    [[ "$envelope_slot" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || {
        echo "--slot must be a finder slug" >&2
        exit 2
    }
    case "$envelope_tier" in
    local | economy | standard | frontier | apex) ;;
    *)
        echo "--tier must be one of local, economy, standard, frontier, apex (got: $envelope_tier)" >&2
        exit 2
        ;;
    esac
    command -v jq >/dev/null 2>&1 && command -v node >/dev/null 2>&1 || {
        echo "envelope mode requires jq and node" >&2
        exit 2
    }
    [ -d "$envelope_record_dir" ] && [ -f "$envelope_record_dir/run.json" ] || {
        echo "--record-dir must name an existing run record directory containing run.json" >&2
        exit 2
    }
    [ -f "$envelope_registry" ] || {
        echo "--registry '$envelope_registry' is not a readable file" >&2
        exit 2
    }
    # producer.harness is the registry slug of the CLI that actually ran, the
    # same vocabulary every other producer uses.
    jq -e --arg h "$harness" '[.harnesses[]? | select(.slug == $h)] | length == 1' "$envelope_registry" >/dev/null || {
        echo "harness '$harness' is not registered in $envelope_registry" >&2
        exit 2
    }
    envelope_harness="$harness"
    envelope_support_dir="$(review_envelope_support_dir)" || {
        echo "envelope mode needs the dev-flow-support package (validate-result-schemas.mjs and its schemas);" >&2
        echo "vendor the universal skill category as a unit." >&2
        exit 2
    }
    actual_head="$(git rev-parse HEAD)"
    [ "$actual_head" = "$envelope_head" ] || {
        echo "--head $envelope_head does not match HEAD $actual_head" >&2
        exit 1
    }
    envelope_initiated_by="$(jq -er --arg run "$envelope_run_id" \
        'select(.run_id == $run) | .initiated_by | select(. == "human" or . == "foreman")' \
        "$envelope_record_dir/run.json" 2>/dev/null)" || {
        echo "run.json does not bind run id '$envelope_run_id' to a valid initiated_by" >&2
        exit 1
    }
    # A pass fills its own slot, or substitutes for another configured primary
    # of this stage. Whether THIS finder is in that primary's fallback chain is
    # policy, and the exit computation enforces it against .devflow.toml; the
    # runner only refuses a slot that cannot exist for this stage at all.
    envelope_substitutes_for=
    if [ "$envelope_slot" != "$finder_slug" ]; then
        slot_entry="$(jq -c --arg slot "$envelope_slot" --arg stage "$mode" \
            '.finders[] | select(.slug == $slot and .surface == "local-cli" and ((.stages // []) | index($stage) != null))' \
            "$envelope_registry")" || {
            echo "could not read $envelope_registry" >&2
            exit 2
        }
        [ -n "$slot_entry" ] || {
            echo "--slot $envelope_slot is not a registered local-cli finder for stage $mode" >&2
            exit 1
        }
        envelope_substitutes_for="$envelope_slot"
    fi
    envelope_finder="$finder_slug"
    envelope_role=challenger
    [ "$mode" = review ] && envelope_role=reviewer
    envelope_payload_schema="$envelope_support_dir/schemas/result.${envelope_role}.schema.json"
    envelope_pass_path="$envelope_record_dir/passes/${mode}-r${envelope_round}-${envelope_slot}.json"
    # Refused up front as well as at publication: a slot already published is
    # not worth a model call. Publication re-checks atomically, which is the
    # check that actually decides.
    [ ! -e "$envelope_pass_path" ] || {
        echo "refusing: $envelope_pass_path already exists; a published pass is immutable" >&2
        exit 1
    }
}

# review_envelope_bind_scope — after resolve_review_scope: envelope mode is a
# branch review whose merge base is the canonical default branch's, rewritten
# to immutable SHAs so the finder's scope cannot drift with a moving ref.
review_envelope_bind_scope() {
    local canonical selected canonical_mb
    [ "$target_kind" = base ] || {
        echo "envelope mode requires an explicit branch-scoped --base <ref> review" >&2
        exit 2
    }
    canonical="$(review_default_base)"
    [ -n "$canonical" ] || {
        echo "envelope mode cannot bind --base: no default-branch ref is available" >&2
        exit 2
    }
    selected="$(git merge-base "$base_ref" "$envelope_head")"
    canonical_mb="$(git merge-base "$canonical" "$envelope_head")" || {
        echo "envelope mode cannot bind --base: $canonical shares no merge base with $envelope_head" >&2
        exit 2
    }
    [ "$selected" = "$canonical_mb" ] || {
        echo "--base $base_ref resolves merge base $selected, not the default branch's $canonical_mb" >&2
        exit 1
    }
    envelope_merge_base="$selected"
    scope="Review the changes at captured head ${envelope_head} relative to captured merge base ${envelope_merge_base} (the immutable diff ${envelope_merge_base}...${envelope_head})."
    # Everything downstream — the manifest here, the diff and the snapshot a
    # finder is handed — reads these two SHAs, never `$base_ref` or HEAD
    # again: a ref rewritten after binding must not change the reviewed bytes.
    review_diff_spec="range:${envelope_merge_base}:${envelope_head}"
    manifest="$(git_diff_name_status "$envelope_merge_base" "$envelope_head" | cap_manifest)" || {
        echo "could not list the captured range ${envelope_merge_base}..${envelope_head}" >&2
        exit 2
    }
    [ -n "$manifest" ] || refuse_empty_scope \
        "the captured range ${envelope_merge_base}..${envelope_head} changes no files." \
        "Envelope mode reviews a branch's commits; there is nothing to review."
}

# review_envelope_extract RAW — print the one JSON object a finder answered
# with, or fail. Structured output is requested in the PROMPT (neither CLI
# offers an enforced schema on its review path), so the answer is parsed
# here and anything but exactly one object fails closed: the whole reply
# as one object, or one fenced block holding one object and nothing outside
# it. Prose, a second object, or an object buried in narration is refused —
# guessing which part was meant would publish a pass nobody asked for.
review_envelope_extract() {
    local raw="$1" inner
    if jq -se 'length == 1 and (.[0] | type) == "object"' "$raw" >/dev/null 2>&1; then
        jq -s '.[0]' "$raw"
        return
    fi
    inner="$(awk '
        { sub(/[ \t\r]+$/, "") }
        NF { body[++n] = $0 }
        END {
            if (n < 3 || body[1] !~ /^```(json)?$/ || body[n] != "```") exit 1
            for (i = 2; i < n; i++) if (body[i] ~ /^```/) exit 1
            for (i = 2; i < n; i++) print body[i]
        }
    ' "$raw")" || return 1
    jq -se 'length == 1 and (.[0] | type) == "object"' <<<"$inner" >/dev/null 2>&1 || return 1
    jq -s '.[0]' <<<"$inner"
}

# review_envelope_normalize SCHEMA PAYLOAD — drop every null whose key the
# schema marks optional, at every object level the schema describes: a model
# asked for JSON routinely writes `"substitutes_for": null` where the schema
# means "absent". A null on a required key is left for the validator to judge.
review_envelope_normalize() {
    jq --slurpfile root "$1" '
        def resolve($r): if has("$ref") then $r["$defs"][.["$ref"] | ltrimstr("#/$defs/")] else . end;
        def norm($sch; $r):
            ($sch | resolve($r)) as $s
            | if type == "object" and ($s | has("properties")) then
                ($s.required // []) as $req
                | with_entries(.key as $k | select(.value != null or ($req | index($k)) != null))
                | with_entries(.key as $k
                    | if $s.properties[$k] then .value |= norm($s.properties[$k]; $r) else . end)
              elif type == "array" and ($s | has("items")) then map(norm($s.items; $r))
              else . end;
        norm($root[0]; $root[0])
    ' "$2"
}

# review_envelope_instructions — the binding clause and the payload schema
# appended to the finder's
# prompt. The runner checks every bound field afterwards, so this is the
# request, not the enforcement.
review_envelope_instructions() {
    local binding
    if [ -n "$envelope_substitutes_for" ]; then
        binding="Set finder to \"${envelope_finder}\", slot to \"${envelope_slot}\", and substitutes_for to \"${envelope_substitutes_for}\"."
    else
        binding="Set finder and slot both to \"${envelope_finder}\" and omit substitutes_for."
    fi
    cat <<INSTRUCTIONS
Return exactly one JSON object and nothing else — no Markdown fence, no prose
around it. It is the payload of a result.${envelope_role} envelope and must
validate against the result.${envelope_role} JSON Schema. Set stage to
"${envelope_stage}", round to ${envelope_round}, and reviewed_head to
"${envelope_head}". ${binding} Number finding ids
"${envelope_stage}-r${envelope_round}-${envelope_finder}-1", "-2", and so on.
Set counts to the tally of findings by priority. For provenance use "original"
and for fingerprint use "new" unless you can name the earlier finding exactly.

The result.${envelope_role} JSON Schema:

$(cat "$envelope_payload_schema")
INSTRUCTIONS
}

# review_envelope_publish RAW_PAYLOAD MODEL — bind, wrap, validate and publish
# the finder's payload; print the published path. Every failure exits 1 with
# nothing under a `.json` name.
review_envelope_publish() {
    local raw="$1" model="$2" passes_dir tmp_payload tmp_envelope tmp_ids
    passes_dir="$envelope_record_dir/passes"
    mkdir -p "$passes_dir" || {
        echo "could not create $passes_dir" >&2
        exit 1
    }
    # Each temporary is registered for cleanup the moment it exists, so a
    # later mktemp failing cannot strand an earlier one.
    review_envelope_temp tmp_payload payload || exit 1
    review_envelope_temp tmp_envelope envelope || exit 1
    review_envelope_temp tmp_ids known-ids || exit 1

    # Exactly one JSON object, then bound to what the caller captured.
    local answer
    answer="$(review_envelope_extract "$raw")" || {
        echo "finder output is not exactly one JSON object; no pass published" >&2
        exit 1
    }
    review_envelope_normalize "$envelope_payload_schema" <(printf '%s\n' "$answer") >"$tmp_payload" || {
        echo "could not normalize the finder payload; no pass published" >&2
        exit 1
    }
    jq -e --arg stage "$envelope_stage" --argjson round "$envelope_round" \
        --arg head "$envelope_head" --arg finder "$envelope_finder" --arg slot "$envelope_slot" \
        --arg sub "$envelope_substitutes_for" \
        '.stage == $stage and .round == $round and .reviewed_head == $head and
         .finder == $finder and .slot == $slot and
         (if $sub == "" then has("substitutes_for") | not else .substitutes_for == $sub end)' \
        "$tmp_payload" >/dev/null || {
        echo "finder payload does not bind the captured stage, round, head, finder and slot; no pass published" >&2
        exit 1
    }

    jq -n \
        --arg role "$envelope_role" \
        --arg head "$envelope_head" \
        --arg produced_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg harness "$envelope_harness" \
        --arg model "$model" \
        --arg tier "$envelope_tier" \
        --arg run_id "$envelope_run_id" \
        --arg initiated_by "$envelope_initiated_by" \
        --slurpfile payload "$tmp_payload" \
        '{schema: 2, role: $role, status: "completed", head: $head,
          produced_at: $produced_at,
          producer: {harness: $harness, model: $model, tier: $tier},
          run: {run_id: $run_id, initiated_by: $initiated_by},
          payload: $payload[0]}' >"$tmp_envelope"

    # Finding ids already used by RECEIPTED passes. An orphan is not evidence,
    # so its ids are not reserved either.
    review_envelope_known_ids >"$tmp_ids" || {
        echo "could not read the finding ids of the run's receipted passes" >&2
        exit 1
    }

    node "$envelope_support_dir/validate-result-schemas.mjs" envelope "$tmp_envelope" \
        --run-id "$envelope_run_id" --initiated-by "$envelope_initiated_by" \
        --known-ids "$tmp_ids" --receipt >&2 || {
        echo "envelope failed receipt validation; no pass published" >&2
        exit 1
    }

    if ! ln -- "$tmp_envelope" "$envelope_pass_path" 2>/dev/null; then
        if [ -e "$envelope_pass_path" ]; then
            echo "refusing: $envelope_pass_path already exists; a published pass is never overwritten" >&2
        else
            echo "could not publish $envelope_pass_path" >&2
        fi
        exit 1
    fi
    printf '%s\n' "$envelope_pass_path"
}

# The finding ids of every pass run.json's receipts name, as a JSON array.
review_envelope_known_ids() {
    local names name file
    local -a files=()
    names="$(jq -r '(.receipts // [])[] | select(.kind == "pass") | .file' "$envelope_record_dir/run.json")" || return 1
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        file="$envelope_record_dir/passes/${name}.json"
        [ -f "$file" ] && files+=("$file")
    done <<<"$names"
    if [ "${#files[@]}" -eq 0 ]; then
        printf '[]\n'
    else
        jq -s '[.[].payload.findings[]?.id]' "${files[@]}"
    fi
}

envelope_temps=()
# review_envelope_temp VAR NAME — create a dot-file temporary inside passes/
# (never a `.json` name, so no reader mistakes it for a pass), register it for
# cleanup, and assign its path to VAR. Runs in the caller's shell rather than
# a command substitution, which could not append to `envelope_temps`.
review_envelope_temp() {
    local tmp
    tmp="$(mktemp "$envelope_record_dir/passes/.$2.XXXXXX")" || {
        echo "could not create a temporary file in $envelope_record_dir/passes" >&2
        return 1
    }
    envelope_temps+=("$tmp")
    printf -v "$1" '%s' "$tmp"
}
review_envelope_cleanup() {
    [ "${#envelope_temps[@]}" -eq 0 ] || rm -f -- "${envelope_temps[@]}"
}

# An envelope binding flag without --envelope would otherwise be silently
# ignored, and the caller would wait for a pass that legacy mode never writes.
review_envelope_refuse_stray_flags() {
    if [ -n "${envelope_run_id}${envelope_head}${envelope_stage}${envelope_round}${envelope_slot}${envelope_tier}${envelope_record_dir}${envelope_registry}" ]; then
        echo "envelope binding flags (--run-id, --head, ...) require --envelope" >&2
        exit 2
    fi
}
