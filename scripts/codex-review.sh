#!/usr/bin/env bash
# codex-review.sh — second-model review of the current change via the OpenAI
# Codex CLI (`codex exec review`). Two modes:
#
#   review    — verification checkpoint: double-check the implementation,
#               consistency with repo conventions, and test coverage.
#   challenge — adversarial review: actively try to break the change
#               (architecture, authz, data loss, rollback, races, hidden
#               coupling, operational failure modes, overdesign).
#
# Usage: codex-review.sh <review|challenge> [--base <ref>|--uncommitted|--commit <sha>] [focus text ...]
#
# Target selection when no explicit flag is given: whatever exists is in
# scope. Commits beyond the default base AND a dirty working tree are reviewed
# together as one change; either alone is reviewed on its own. The explicit
# flags stay narrow on purpose — --base is committed history only, and
# --uncommitted is the worktree only — so they remain escapes you opt into.
# The CLI's --base/--uncommitted/--commit flags are mutually exclusive with
# custom instructions ("custom review instructions" is its own review mode),
# so the resolved scope is written INTO the instructions instead.
# Codex reviews read-only; findings are advisory hypotheses for the primary
# agent/human to adjudicate (AGENTS.md "Second-Model Review") — this is never
# part of `verify`/`ci`. Both modes ask for P0/P1/P2/P3-labelled findings;
# only P0/P1 gate the local loop and P2s are reported and deferred to the PR
# stage. A label is a hypothesis and the ADJUDICATED severity is the verdict,
# P3 included; the sidecar records only what is left unresolved AND carried
# forward, so fixing one in place defers nothing and owes no entry.
# A finding badged off that scale, or not badged at all, is adjudicated as at
# least a P2, never dropped for being unrecognized.
# No target path may invoke Codex with an empty scope; every one of them
# refuses and exits non-zero instead (see refuse_empty_scope).
# Requires an authenticated Codex CLI (`codex login`);
# see docs/guides/codex-review.md.
set -euo pipefail
cd "$(dirname "$0")/.."

usage() {
    echo "usage: $0 <review|challenge> [--base <ref>|--uncommitted|--commit <sha>] [focus text ...]" >&2
}

MODE="${1:-}"
case "$MODE" in
review | challenge) shift ;;
*)
    usage
    exit 2
    ;;
esac

if ! command -v codex >/dev/null 2>&1; then
    echo "codex CLI not found. Install it (brew install --cask codex, or npm install -g @openai/codex)," >&2
    echo "authenticate with 'codex login', then re-run. See docs/guides/codex-review.md." >&2
    exit 1
fi

# Per-line ceiling for the CLI's stderr (see bound_stderr_lines at the bottom).
# Validated here rather than at the point of use so a typo fails before the
# git work and the review, not after them. 0 disables the bound.
#
# The 18-digit ceiling is about what `test -eq` can compare, not a view on
# useful line lengths: a value past INT64_MAX makes it fail with "integer
# expression expected" on stderr — leaking a confusing line into the stream
# this whole change exists to keep clean — and then fall through to an
# effectively unbounded run. 18 digits is the widest that always fits.
MAX_STDERR_BYTES="${CODEX_REVIEW_MAX_STDERR_BYTES:-1024}"
case "$MAX_STDERR_BYTES" in
'' | *[!0-9]*)
    echo "CODEX_REVIEW_MAX_STDERR_BYTES must be a non-negative integer (got: '${MAX_STDERR_BYTES}')" >&2
    exit 2
    ;;
[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]*)
    echo "CODEX_REVIEW_MAX_STDERR_BYTES is implausibly large (got: '${MAX_STDERR_BYTES}'); use 0 to disable the bound" >&2
    exit 2
    ;;
esac

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

scope=""
manifest=""
focus=""
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
        empty_desc="commit $2 changes no files (an empty commit, or a merge with no first-parent change)."
        empty_hint="Pass --base <ref> for a branch-scoped review, or name a commit that touches files."
        shift 2
        ;;
    --uncommitted)
        require_single_target
        scope="Review the uncommitted work in this repository: staged, unstaged, and untracked changes."
        manifest="$(git_status_porcelain | cap_manifest || true)"
        target_kind="uncommitted"
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
        echo "==> Reviewing branch changes against ${base} AND uncommitted work (both halves in scope)"
    elif [ -n "$dirty_manifest" ]; then
        scope="Review the uncommitted work in this repository: staged, unstaged, and untracked changes."
        manifest="$dirty_manifest"
        echo "==> Reviewing uncommitted work (HEAD changes no files beyond ${base})"
    elif [ -n "$base_manifest" ]; then
        scope="Review the changes on the current branch relative to base branch '${base}' (the merge-base diff ${base}...HEAD)."
        manifest="$base_manifest"
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

if [ "$MODE" = "challenge" ]; then
    instructions="${scope}

Run an ADVERSARIAL review: your job is to break confidence in this change,
not to validate it. Challenge the architecture and the chosen approach, not
just the diff hunks. Actively hunt for: authorization bypasses and trust
boundary gaps; data-loss or corruption paths; unsafe rollback and migration
behavior; race conditions, ordering and idempotency gaps; hidden coupling and
assumptions that stop holding under stress; operational failure modes (empty
state, timeouts, retries, partial failure, degraded dependencies); and
unnecessarily complex design choices where a simpler alternative would do.
Report EVERY materially defensible finding tied to concrete files and lines —
do not stop at the first strong one. No style nits, no speculation you cannot
support from the code. If the change looks safe, say so directly."
else
    instructions="${scope}

Run a VERIFICATION-CHECKPOINT review of this change: double-check that the
implementation actually does what it claims, is internally consistent and
consistent with this repository's existing conventions and docs, handles
errors and edge cases, and has adequate test coverage (including regression
tests for anything it fixes). Flag docs the change should have updated.
Report only material, defensible findings tied to concrete files and lines —
no style nits. If the change holds up, say so directly."
fi

# Severity is defined HERE rather than inherited from the Codex CLI's own
# review output: its priority labels are an undocumented convention that can
# change under us, and the local dev loop gates on this scale (AGENTS.md
# "Second-Model Review"). Stating it in the prompt keeps the gate meaningful.
# The scale is closed at four levels, but the CLOUD reviewer is not driven by
# this prompt and has been seen emitting off-scale badges (a P3 on #918, back
# when the scale stopped at P2), so the unrecognized-badge invariant below is
# written for both audiences: an unknown or missing badge is worth at least a
# P2 of adjudication.
instructions="${instructions}

Label EVERY finding with a priority, as the first token of the finding:

  P0 — a defect that breaks correctness, security, or data integrity in
       ordinary use, or that breaks an existing contract. Merge-blocking.
  P1 — a real defect or materially wrong design decision with a plausible
       trigger. Merge-blocking unless argued down with evidence.
  P2 — worth knowing, but not merge-blocking: hardening, edge cases behind
       unlikely preconditions, maintainability, non-critical test gaps.
  P3 — cosmetic or purely informational: a naming or wording choice that
       will mislead a reader, an observation with no defect behind it.
       Never gating. The no-style-nits rule above still binds — P3 is the
       floor for findings worth stating, not a licence to report nits.

Only P0 and P1 decide whether this review passes. Still report P2s in full —
they are triaged later, once the pull request is open — but do not let them
hold the stage open. Do not inflate a P2 to P1 to make it heard, and do not
withhold or soften a P2 because it is non-gating: a P2 reported here is
carried into the pull request description, so an unreported one is lost
outright. The same holds one level down: report a P3 as a P3 rather than
inflating it to P2 or dropping it for being small. Use these four labels and
no others — a finding that arrives off this scale, or with no label at all,
is adjudicated as at least a P2. Every label you apply is a hypothesis the
reader adjudicates on evidence, P3 included; none of them decides its own
disposition. If there are no P0 or P1 findings, say so
explicitly and in those terms."

if [ -n "$focus" ]; then
    instructions="${instructions}

Additional focus from the invoker (weight it heavily): ${focus}"
fi

# Custom review instructions bypass the CLI's native diff-target modes (the
# two are mutually exclusive), leaving diff collection to the model. Anchor it
# with an authoritative, git-generated file manifest so nothing in scope —
# untracked files included — can be silently skipped. Unconditional: the
# backstop above guarantees a non-empty manifest, so a "if we have one" test
# here would be dead code implying an empty-manifest run is reachable.
instructions="${instructions}

Authoritative changed-file manifest from git for this scope (status + path;
cover EVERY entry, including untracked files, collecting the diffs yourself
with git):

${manifest}"

# Codex puts the verdict on stdout and everything else — progress narration
# and errors alike — on stderr, so a caller capturing both (the documented
# `task challenge > log 2>&1`) interleaves them. Harmless until the CLI logs
# an error that inlines an entire API payload: one `codex_models_manager`
# decode failure emits the whole models JSON as a single ~195 KiB line, and it
# retries, so eleven lines carried 2.1 MB of a 2.2 MB log and buried the
# verdict the run exists to produce. Bound the LINE LENGTH rather than
# matching that message: nothing upstream bounds it, and any future decode
# error dumps its payload the same way.
#
# stderr only. The verdict is on stdout, where a long line is legitimate
# prose; truncating it would corrupt the very output this protects.
bound_stderr_lines() {
    if [ "$MAX_STDERR_BYTES" -eq 0 ]; then
        cat
        return
    fi
    # LC_ALL=C makes length()/substr() count bytes rather than characters, so
    # the ceiling holds whatever encoding the payload turns out to be in.
    # fflush() per line keeps the narration live: a round runs 5-15 minutes and
    # callers are told to read growing output as "still running, not hung"
    # (docs/guides/codex-review.md), which a block-buffered filter would break.
    LC_ALL=C awk -v max="$MAX_STDERR_BYTES" '
        {
            if (length($0) > max) {
                printf "%s... [%d-byte line truncated by codex-review.sh; set CODEX_REVIEW_MAX_STDERR_BYTES=0 for the full text]\n", substr($0, 1, max), length($0)
            } else {
                print
            }
            fflush()
        }
    '
}

# Feed the prompt through stdin (`review -`): a single argv element is
# capped (~128 KiB per arg on Linux), and cap_manifest bounds entry count,
# not bytes — 200 deep paths plus instructions can exceed the argv limit.
#
# The fd dance routes ONLY stderr through the filter: `3>&1` on the group
# parks the real stdout on fd3, `2>&1` puts stderr on the pipe, `1>&3` gives
# codex the real stdout back, and `3>&-` keeps the spare descriptor out of the
# child. A pipeline rather than `2> >(...)` is deliberate — the shell waits for
# a pipeline, so the tail of the narration cannot be lost to the script exiting
# first. Under pipefail the filter exits 0, leaving codex's own status as the
# rightmost non-zero, so a failed review still fails the task.
{ printf '%s\n' "$instructions" | codex exec review \
    --model gpt-5.6-sol \
    --config model_reasoning_effort=high \
    - 2>&1 1>&3 3>&- | bound_stderr_lines >&2; } 3>&1
