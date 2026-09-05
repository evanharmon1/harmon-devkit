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
# Resolved BEFORE the cd: the shared libraries below live beside this script,
# and `dirname "$0"` re-evaluated after the cd resolves against the new cwd
# (running `./codex-review.sh` from inside scripts/ would look for lib/ in the
# repository root).
script_dir="$(cd "$(dirname "$0")" && pwd)"
cd "$script_dir/.."

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

# WHAT gets reviewed — the target flags, the auto-detected scope, the
# authoritative manifest, and every refusal that keeps an empty or half scope
# from reading as a clean pass — is scripts/lib/review-scope.sh, shared with
# scripts/finder-review.sh. It sets `scope`, `manifest` and `focus`.
# shellcheck source=scripts/lib/review-scope.sh
. "$script_dir/lib/review-scope.sh"
resolve_review_scope "$@"

# The mode prose and the severity scale below are read from
# scripts/lib/review-instructions/ rather than inlined here: scripts/
# finder-review.sh renders the same two blocks for the other local-CLI
# finders, and the P0-P3 scale is normative (AGENTS.md "Second-Model Review"
# gates the local loop on it, and every finder's registry severity_map maps
# onto it). One copy cannot drift from itself.
read_instruction() {
    instruction_file="$script_dir/lib/review-instructions/$1.txt"
    [ -f "$instruction_file" ] || {
        echo "missing shared review instruction: $instruction_file" >&2
        exit 2
    }
    cat "$instruction_file"
}

instructions="${scope}

$(read_instruction "$MODE")"

# Severity is defined by THIS REPO (scripts/lib/review-instructions/
# severity.txt) rather than inherited from the Codex CLI's own review output:
# its priority labels are an undocumented convention that can change under us,
# and the local dev loop gates on this scale (AGENTS.md "Second-Model
# Review"). Stating it in the prompt keeps the gate meaningful.
# The scale is closed at four levels, but the CLOUD reviewer is not driven by
# this prompt and has been seen emitting off-scale badges (a P3 on #918, back
# when the scale stopped at P2), so the unrecognized-badge invariant below is
# written for both audiences: an unknown or missing badge is worth at least a
# P2 of adjudication.
instructions="${instructions}

$(read_instruction severity)"

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
