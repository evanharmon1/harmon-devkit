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
# Target selection when no explicit flag is given (mirrors the Codex Claude
# Code plugin's auto scope): a dirty working tree reviews staged + unstaged +
# untracked work; a clean tree reviews the branch against the default base.
# The CLI's --base/--uncommitted/--commit flags are mutually exclusive with
# custom instructions ("custom review instructions" is its own review mode),
# so the resolved scope is written INTO the instructions instead.
# Codex reviews read-only; findings are advisory hypotheses for the primary
# agent/human to adjudicate (AGENTS.md "Second-Model Review") — this is never
# part of `verify`/`ci`. Both modes ask for P0/P1/P2-labelled findings; only
# P0/P1 gate the local loop, P2s are reported and deferred to the PR stage.
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
    echo "      Uncommitted changes are NOT in scope; use --uncommitted for those." >&2
}

scope=""
manifest=""
focus=""
# Which explicit target flag was given, plus the wording its empty-scope
# refusal should use. Resolved during parsing, acted on after it.
target_kind=""
empty_desc=""
empty_hint=""
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
        empty_desc="the merge-base diff $2...HEAD is empty — HEAD changes no files beyond '$2'."
        # --commit belongs here too: a branch whose commits net out to no change
        # (an add and its revert) is already committed and has a clean tree, so
        # both of the other two remedies would be dead ends.
        empty_hint="Pass --uncommitted for working-tree changes, --commit <sha> for a single commit, or commit your work first."
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
fi
if [ -n "$target_kind" ] && [ -z "$manifest" ]; then
    refuse_empty_scope "$empty_desc" "$empty_hint"
fi

if [ -z "$scope" ]; then
    # Same helper as the manifest built from it two lines down, so the tree
    # cannot test clean here and then yield a non-empty manifest (or vice
    # versa) because the two calls disagreed about what counts as a change.
    if [ -n "$(git_status_porcelain)" ]; then
        scope="Review the uncommitted work in this repository: staged, unstaged, and untracked changes."
        manifest="$(git_status_porcelain | cap_manifest || true)"
        echo "==> Reviewing uncommitted work (dirty tree; pass --base <ref> to review the branch instead)"
    else
        # origin/HEAD (the remote's actual default branch) outranks local
        # branch-name guesses: a stray local `main` in a develop-default repo
        # must not silently become the comparison base. The remote-qualified
        # ref is kept as-is — stripping origin/ could name a branch that does
        # not exist locally. Name guesses only apply to remoteless repos.
        base="$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || true)"
        if [ -z "$base" ]; then
            for candidate in main master; do
                if git rev-parse --verify --quiet "$candidate" >/dev/null; then
                    base="$candidate"
                    break
                fi
            done
        fi
        if [ -z "$base" ] || ! git rev-parse --verify --quiet "$base" >/dev/null; then
            echo "Could not detect a base branch; pass --base <ref> or --uncommitted." >&2
            exit 2
        fi
        if ! git merge-base "$base" HEAD >/dev/null 2>&1; then
            echo "Auto-detected base '${base}' shares no merge base with HEAD; pass --base <ref> or --uncommitted." >&2
            exit 2
        fi
        if [ "$(git rev-list --count "${base}..HEAD" 2>/dev/null || echo 0)" -eq 0 ]; then
            refuse_empty_scope \
                "the working tree is clean and HEAD has no commits beyond ${base}." \
                "Pass --base <ref> or --commit <sha> to name a target explicitly."
        fi
        scope="Review the changes on the current branch relative to base branch '${base}' (the merge-base diff ${base}...HEAD)."
        manifest="$(git_diff_name_status "${base}...HEAD" | cap_manifest || true)"
        # Commits beyond the base do not guarantee a non-empty diff: an empty
        # commit, or one later reverted, leaves nothing for Codex to read.
        if [ -z "$manifest" ]; then
            refuse_empty_scope \
                "the merge-base diff ${base}...HEAD is empty — the commits beyond ${base} change no files." \
                "Pass --commit <sha> to review a specific commit, or --uncommitted for working-tree changes."
        fi
        echo "==> Reviewing branch changes against ${base}"
    fi
fi

# Backstop for every path, so the invariant does not depend on each one
# remembering it. The auto dirty-tree path in particular decides on one
# `git status` and builds its manifest from a second: a tree cleaned between
# the two calls — or a call that failed into `|| true` — would otherwise still
# reach the model with nothing to review.
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
instructions="${instructions}

Label EVERY finding with a priority, as the first token of the finding:

  P0 — a defect that breaks correctness, security, or data integrity in
       ordinary use, or that breaks an existing contract. Merge-blocking.
  P1 — a real defect or materially wrong design decision with a plausible
       trigger. Merge-blocking unless argued down with evidence.
  P2 — worth knowing, but not merge-blocking: hardening, edge cases behind
       unlikely preconditions, maintainability, non-critical test gaps.

Only P0 and P1 decide whether this review passes. Still report P2s in full —
they are triaged later, once the pull request is open — but do not let them
hold the stage open. Do not inflate a P2 to P1 to make it heard, and do not
withhold or soften a P2 because it is non-gating: a P2 reported here is
carried into the pull request description, so an unreported one is lost
outright. If there are no P0 or P1 findings, say so explicitly and in those
terms."

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

# Feed the prompt through stdin (`review -`): a single argv element is
# capped (~128 KiB per arg on Linux), and cap_manifest bounds entry count,
# not bytes — 200 deep paths plus instructions can exceed the argv limit.
printf '%s\n' "$instructions" | codex exec review -
