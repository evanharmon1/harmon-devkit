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
    # CodeRabbit's CLI takes no review instructions of ours, so there is no
    # prompt to build. The resolved scope is still printed: it is what the
    # round is supposed to cover, and a reader comparing it against what the
    # CLI actually reported is how a scope mismatch gets noticed at all.
    echo "==> $slug over: $scope" >&2
    # shellcheck disable=SC2206 # deliberate word-splitting: the override is a
    # flag list, not one argument.
    args=(${FINDER_REVIEW_CODERABBIT_ARGS:-$default_args})
    if [ "$dry_run" = 1 ]; then
        printf 'finder: %s\ncommand: %s %s\nscope: %s\n' "$slug" "$bin" "${args[*]}" "$scope"
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
# per argument on Linux). Bound the embedded diff rather than letting a large
# change fail the exec with a confusing E2BIG, and MARK the truncation so the
# reviewer knows the manifest above is the complete list and the diff is not.
diff_bytes="${FINDER_REVIEW_MAX_DIFF_BYTES:-60000}"
case "$diff_bytes" in
'' | *[!0-9]*)
    echo "FINDER_REVIEW_MAX_DIFF_BYTES must be a non-negative integer (got: '${diff_bytes}')" >&2
    exit 2
    ;;
esac
diff_text="$(collect_review_diff)"
if [ "$diff_bytes" -gt 0 ] && [ "${#diff_text}" -gt "$diff_bytes" ]; then
    diff_text="$(printf '%s' "$diff_text" | LC_ALL=C cut -c "1-${diff_bytes}")
... [diff truncated at ${diff_bytes} bytes; the manifest above is complete — ask for the rest by file]"
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
