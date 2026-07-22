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
# part of `verify`/`ci`. Requires an authenticated Codex CLI (`codex login`);
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

scope=""
manifest=""
focus=""
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
        manifest="$(git diff --name-status "$2...HEAD" 2>/dev/null | cap_manifest || true)"
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
            manifest="$(git diff --name-status "$2^" "$2" 2>/dev/null | cap_manifest || true)"
        else
            manifest="$(git diff-tree --no-commit-id --name-status -r --root "$2" 2>/dev/null | cap_manifest || true)"
        fi
        shift 2
        ;;
    --uncommitted)
        require_single_target
        scope="Review the uncommitted work in this repository: staged, unstaged, and untracked changes."
        manifest="$(git status --porcelain --untracked-files=all | cap_manifest || true)"
        shift
        ;;
    *)
        focus="${focus:+${focus} }$1"
        shift
        ;;
    esac
done

if [ -z "$scope" ]; then
    if [ -n "$(git status --porcelain)" ]; then
        scope="Review the uncommitted work in this repository: staged, unstaged, and untracked changes."
        manifest="$(git status --porcelain --untracked-files=all | cap_manifest || true)"
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
            echo "Nothing to review: the working tree is clean and HEAD has no commits beyond ${base}."
            exit 0
        fi
        scope="Review the changes on the current branch relative to base branch '${base}' (the merge-base diff ${base}...HEAD)."
        manifest="$(git diff --name-status "${base}...HEAD" | cap_manifest || true)"
        echo "==> Reviewing branch changes against ${base}"
    fi
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

if [ -n "$focus" ]; then
    instructions="${instructions}

Additional focus from the invoker (weight it heavily): ${focus}"
fi

# Custom review instructions bypass the CLI's native diff-target modes (the
# two are mutually exclusive), leaving diff collection to the model. Anchor it
# with an authoritative, git-generated file manifest so nothing in scope —
# untracked files included — can be silently skipped.
if [ -n "$manifest" ]; then
    instructions="${instructions}

Authoritative changed-file manifest from git for this scope (status + path;
cover EVERY entry, including untracked files, collecting the diffs yourself
with git):

${manifest}"
fi

# Feed the prompt through stdin (`review -`): a single argv element is
# capped (~128 KiB per arg on Linux), and cap_manifest bounds entry count,
# not bytes — 200 deep paths plus instructions can exceed the argv limit.
printf '%s\n' "$instructions" | codex exec review -
