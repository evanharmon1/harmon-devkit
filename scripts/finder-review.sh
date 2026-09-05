#!/usr/bin/env bash
# finder-review.sh — run a non-Codex local-CLI finder over the current change.
#
#   review    — verification checkpoint (stage `review`,   role reviewer)
#   challenge — adversarial review      (stage `challenge`, role challenger)
#
# Usage:
#   finder-review.sh <review|challenge> <coderabbit|copilot>
#                    [--base <ref>|--uncommitted|--commit <sha>] [focus text ...]
#
# Local and advisory only, exactly like scripts/codex-review.sh: nothing here
# runs in CI and no verify/ci step depends on it. WHAT gets reviewed is
# resolved by the shared scripts/lib/review-scope.sh, and the mode and
# severity prose come from scripts/lib/review-instructions/, so a finder can
# never silently review a different scope or gate on a different scale than
# Codex does.
#
# The two backends differ in kind, and the difference is the point:
#
#   copilot     — a general agent (GitHub Copilot CLI) driven with THIS repo's
#                 review prompt, so it answers on the P0-P3 scale directly.
#                 The change is embedded in the prompt; no tools are granted
#                 and none are needed, so the pass cannot write.
#   coderabbit  — a review product that analyses the repository on its own
#                 terms and takes no instructions of ours. It answers in its
#                 own vocabulary; agent-registry.json's `severity_map` for
#                 `coderabbit-adversarial`/`coderabbit-verification` is what
#                 maps that vocabulary onto P0-P3.
#
# NEITHER tool is installed or configured by this repository, and neither is
# in the shipped default finder set: `.devflow.toml` has to name one before a
# stage runs it. A missing binary is a hard refusal (exit 1), never a silent
# skip — a skipped finder that exits 0 reads as the clean pass a capped stage
# exits on.
#
# The invocation of each vendor CLI is overridable, because a vendor flag
# change must be a config edit rather than a code change here:
#   FINDER_REVIEW_COPILOT_BIN     (default: copilot)
#   FINDER_REVIEW_COPILOT_ARGS    (default: -p)      prompt appended as one arg
#   FINDER_REVIEW_CODERABBIT_BIN  (default: coderabbit)
#   FINDER_REVIEW_CODERABBIT_ARGS (default: review --plain)
#   FINDER_REVIEW_DRY_RUN=1       print the resolved command and instructions,
#                                 invoke nothing, exit 0
#
# See docs/guides/codex-review.md for enabling each finder.
set -euo pipefail
script_dir="$(cd "$(dirname "$0")" && pwd)"
cd "$script_dir/.."

usage() {
    echo "usage: $0 <review|challenge> <coderabbit|copilot> [--base <ref>|--uncommitted|--commit <sha>] [focus text ...]" >&2
}

MODE="${1:-}"
case "$MODE" in
review | challenge) shift ;;
*)
    usage
    exit 2
    ;;
esac

TOOL="${1:-}"
case "$TOOL" in
coderabbit | copilot) shift ;;
*)
    usage
    exit 2
    ;;
esac

# The registry is the authority on which finders exist and what each one is
# for; this script only knows how to DRIVE them. Resolving the slug here means
# an unregistered finder refuses before a model call rather than producing a
# pass nothing can bind to a configured slot.
case "$MODE" in
challenge) slug="${TOOL}-adversarial" ;;
review) slug="${TOOL}-verification" ;;
esac
registry="agent-registry.json"
command -v jq >/dev/null 2>&1 || {
    echo "jq is required to resolve '$slug' against $registry." >&2
    exit 2
}
[ -f "$registry" ] || {
    echo "$registry not found — cannot confirm '$slug' is a registered finder." >&2
    exit 2
}
finder_entry="$(jq -c --arg slug "$slug" '.finders[] | select(.slug == $slug)' "$registry")" || {
    echo "could not read $registry" >&2
    exit 2
}
[ -n "$finder_entry" ] || {
    echo "'$slug' is not a registered finder in $registry." >&2
    exit 2
}
printf '%s' "$finder_entry" | jq -e '.surface == "local-cli"' >/dev/null || {
    echo "finder '$slug' is not a local-cli finder; only a local-cli finder is invoked from a CLI." >&2
    exit 2
}
expected_target="$MODE:$TOOL"
actual_target="$(printf '%s' "$finder_entry" | jq -r '.invocation.target')"
[ "$actual_target" = "$expected_target" ] || {
    echo "finder '$slug' declares Taskfile target '$actual_target', but this run is '$expected_target'." >&2
    echo "Reconcile $registry with the Taskfile rather than guessing which one is right." >&2
    exit 2
}

case "$TOOL" in
copilot)
    bin="${FINDER_REVIEW_COPILOT_BIN:-copilot}"
    default_args="-p"
    install_hint="Install the GitHub Copilot CLI (npm install -g @github/copilot), authenticate it, then re-run."
    ;;
coderabbit)
    bin="${FINDER_REVIEW_CODERABBIT_BIN:-coderabbit}"
    default_args="review --plain"
    install_hint="Install the CodeRabbit CLI (see https://docs.coderabbit.ai), authenticate it, then re-run."
    ;;
esac
if ! command -v "$bin" >/dev/null 2>&1; then
    echo "$TOOL CLI ('$bin') not found. $install_hint" >&2
    echo "See docs/guides/codex-review.md. Refusing rather than skipping: a finder that" >&2
    echo "exits 0 without running reads as the clean pass a capped stage exits on." >&2
    exit 1
fi

# shellcheck source=scripts/lib/review-scope.sh
. "$script_dir/lib/review-scope.sh"
resolve_review_scope "$@"

read_instruction() {
    instruction_file="$script_dir/lib/review-instructions/$1.txt"
    [ -f "$instruction_file" ] || {
        echo "missing shared review instruction: $instruction_file" >&2
        exit 2
    }
    cat "$instruction_file"
}

dry_run="${FINDER_REVIEW_DRY_RUN:-0}"

if [ "$TOOL" = coderabbit ]; then
    # CodeRabbit's CLI takes no review instructions of ours AND no target from
    # us: it resolves its own scope. So an explicit target flag here would be
    # a claim this runner cannot honour — `--base main` and `--uncommitted`
    # select deliberately disjoint content, and running the same unscoped
    # command for both would let a pass that reviewed the wrong change count
    # as a complete finder pass for the one that was asked for. Refuse the
    # flag instead, and leave the escape to an operator who knows their own
    # CLI's scope flags.
    if [ -n "$target_kind" ]; then
        echo "$TOOL resolves its own review scope; this runner cannot pass --${target_kind} through to it." >&2
        echo "Run it with no target flag, or set FINDER_REVIEW_CODERABBIT_ARGS to the vendor" >&2
        echo "flags that express the scope you want. Refusing rather than reviewing a" >&2
        echo "different change than the one you named and reporting it as that one." >&2
        exit 2
    fi
    # The repo-resolved scope is printed as an advisory CROSS-CHECK, never as
    # a claim about what the CLI reviewed: a reader comparing the two is how a
    # scope mismatch gets noticed at all.
    echo "==> $slug — this repo resolves: $scope" >&2
    echo "    (the CodeRabbit CLI resolves its own scope; compare its report against the above)" >&2
    # shellcheck disable=SC2206 # deliberate word-splitting: the override is a
    # flag list, not one argument.
    args=(${FINDER_REVIEW_CODERABBIT_ARGS:-$default_args})
    if [ "$dry_run" = 1 ]; then
        printf 'finder: %s\ncommand: %s %s\nrepo-resolved scope (advisory): %s\n' \
            "$slug" "$bin" "${args[*]}" "$scope"
        printf 'manifest:\n%s\n' "$manifest"
        exit 0
    fi
    exec "$bin" "${args[@]}"
fi

# ── copilot ──────────────────────────────────────────────────────────────
# A general agent, so it is driven with the same instructions Codex gets:
# same scope sentence, same mode prose, same severity scale, same
# authoritative manifest. The DIFF is embedded too, unlike the Codex path
# which lets the CLI collect it: no tool is granted to this run, so nothing
# else could read the tree.
instructions="${scope}

$(read_instruction "$MODE")

$(read_instruction severity)"

if [ -n "$focus" ]; then
    instructions="${instructions}

Additional focus from the invoker (weight it heavily): ${focus}"
fi

instructions="${instructions}

Authoritative changed-file manifest from git for this scope (status + path;
every entry is in scope, including untracked files):

${manifest}"

# The prompt travels as a single argv element, which the kernel caps (~128 KiB
# per argument on Linux), so the embedded diff needs a bound. That bound is a
# REFUSAL, not a truncation. This run grants the agent no tools, so it cannot
# fetch what was cut — an earlier revision truncated with a marker telling the
# reviewer to ask for the rest, which it had no way to do, and the pass could
# still come back clean and be banked as a complete round. A partial review
# that exits 0 is indistinguishable from a clean one.
diff_bytes="${FINDER_REVIEW_MAX_DIFF_BYTES:-60000}"
case "$diff_bytes" in
'' | *[!0-9]*)
    echo "FINDER_REVIEW_MAX_DIFF_BYTES must be a non-negative integer (got: '${diff_bytes}')" >&2
    exit 2
    ;;
esac
diff_text="$(collect_review_diff)"
if [ "$diff_bytes" -gt 0 ] && [ "${#diff_text}" -gt "$diff_bytes" ]; then
    echo "The change is ${#diff_text} bytes, past the ${diff_bytes}-byte prompt bound for $slug." >&2
    echo "This finder is handed the diff and granted no tools, so a truncated prompt is a" >&2
    echo "review of part of the change reported as a review of all of it. Narrow the scope" >&2
    echo "(--base <ref>, --commit <sha>, --uncommitted) or raise FINDER_REVIEW_MAX_DIFF_BYTES" >&2
    echo "if your CLI and kernel accept a larger single argument." >&2
    exit 1
fi
instructions="${instructions}

The change itself:

${diff_text}"

# shellcheck disable=SC2206 # deliberate word-splitting: the override is a flag
# list, not one argument.
args=(${FINDER_REVIEW_COPILOT_ARGS:-$default_args})
if [ "$dry_run" = 1 ]; then
    printf 'finder: %s\ncommand: %s %s\n' "$slug" "$bin" "${args[*]}"
    printf '%s\n' "$instructions"
    exit 0
fi
echo "==> $slug over: $scope" >&2
exec "$bin" "${args[@]}" "$instructions"
