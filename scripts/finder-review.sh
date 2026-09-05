#!/usr/bin/env bash
# finder-review.sh — run a non-Codex local-CLI finder over the current change.
#
#   review    — verification checkpoint (stage `review`,   role reviewer)
#   challenge — adversarial review      (stage `challenge`, role challenger)
#
# Usage:
#   finder-review.sh <review|challenge> <tool>
#                    [--base <ref>|--uncommitted|--commit <sha>] [focus text ...]
#
# `<tool>` names a registered local-CLI finder pair — `<tool>-adversarial` for
# challenge, `<tool>-verification` for review — and is refused if the registry
# has no such entry. Today that is `copilot`.
#
# Local and advisory only, exactly like scripts/codex-review.sh: nothing here
# runs in CI and no verify/ci step depends on it. WHAT gets reviewed is
# resolved by the shared scripts/lib/review-scope.sh, and the mode and
# severity prose come from scripts/lib/review-instructions/, so a finder can
# never silently review a different scope or gate on a different scale than
# Codex does.
#
# THE TOOL BOUNDARY. `/review`'s dispatch contract requires a confidence pass
# to run with shell, git, gh, network write and external credentials DENIED,
# and says that where that split "cannot be installed and verified, refuse the
# dispatch and record a blocker". This runner cannot verify it: it invokes a
# general-agent CLI which reads the operator's own configuration, and its
# arguments are overridable, so a pre-approved tool set or a tool-enabling
# override would put a writable agent in the checkout while its output was
# banked as a read-only confidence pass.
#
# So it refuses by default. FINDER_REVIEW_COPILOT_READONLY=1 is the operator
# attesting that THEIR configuration grants this CLI no tools; nothing here
# claims to have checked it, and the variable exists so the decision is made
# explicitly by someone who can check it, rather than assumed by a comment.
# An earlier revision of this file simply asserted "no tools are granted and
# none are needed" — the second half is true (the diff is in the prompt), the
# first was never enforced.
#
# What a finder here must be able to do is take OUR scope. A confidence-stage
# slot is complete only when its pass reviewed the round's exact
# `reviewed_head` (specs/dev-flow-v2.md § Configuration), so a CLI that
# resolves its own scope and accepts no target from us cannot fill one: its
# pass would be evidence about some other change reported as evidence about
# this one. GitHub Copilot CLI qualifies because it is a general agent — it is
# driven with THIS repo's mode and severity prompt and handed the diff, so it
# answers on the P0-P3 scale about exactly the resolved scope, with no tools
# granted and none needed, so the pass cannot write.
#
# CodeRabbit deliberately has no entry here, and that is a decision rather than
# an omission: its CLI reviews on its own terms and takes no target, so every
# invocation would run the same command whatever scope was asked for. It is
# registered as a PR-side finder (`coderabbit-cloud`) instead, where the head
# IS the scope and the binding problem does not arise.
#
# The tool is neither installed nor configured by this repository, and no
# finder here is in the shipped default set: `.devflow.toml` has to name one
# before a stage runs it. A missing binary is a hard refusal (exit 1), never a
# silent skip — a skipped finder that exits 0 reads as the clean pass a capped
# stage exits on.
#
# The vendor invocation is overridable, because a vendor flag change must be a
# config edit rather than a code change here:
#   FINDER_REVIEW_COPILOT_READONLY=1  REQUIRED: the operator attests this CLI
#                                is configured to grant no tools (see above)
#   FINDER_REVIEW_COPILOT_BIN    (default: copilot)
#   FINDER_REVIEW_COPILOT_ARGS   (default: -p)     prompt appended as one arg
#   FINDER_REVIEW_MAX_DIFF_BYTES (default: 60000)  refusal bound, in BYTES
#   FINDER_REVIEW_DRY_RUN=1      print the resolved command and instructions,
#                                invoke nothing, exit 0
#
# See docs/guides/codex-review.md for enabling each finder.
set -euo pipefail
script_dir="$(cd "$(dirname "$0")" && pwd)"
cd "$script_dir/.."

usage() {
    echo "usage: $0 <review|challenge> <tool> [--base <ref>|--uncommitted|--commit <sha>] [focus text ...]" >&2
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
# A slug shape, not an allowlist: which tools exist is the registry's answer,
# checked below, so adding one is a registry plus Taskfile change rather than
# an edit here.
case "$TOOL" in
'' | *[!a-z0-9-]* | -* | *-)
    usage
    exit 2
    ;;
*) shift ;;
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
*)
    # Registered, but this runner does not know how to drive it. Refusing is
    # the only honest answer: guessing an invocation would produce a pass
    # nobody can vouch for.
    echo "finder '$slug' is registered but $0 has no runner for the '$TOOL' CLI." >&2
    echo "Add one here, or drop the finder from the registry — a finder with no" >&2
    echo "runner cannot fill a round slot." >&2
    exit 2
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

# A general agent, so it is driven with the same instructions Codex gets:
# same scope sentence, same mode prose, same severity scale, same
# authoritative manifest. The DIFF is embedded too, unlike the Codex path
# which lets the CLI collect it — so this pass NEEDS no tools, whether or not
# the operator's configuration grants any. Whether it is actually denied them
# is the attestation checked below, not something this file can assert.
if [ "${FINDER_REVIEW_COPILOT_READONLY:-0}" != 1 ]; then
    echo "Refusing to run $slug: this runner cannot verify that the $TOOL CLI is denied" >&2
    echo "shell, git, network-write and credential tools, and /review requires a confidence" >&2
    echo "pass to run with those denied or the dispatch refused." >&2
    echo "The change is embedded in the prompt, so the pass needs no tools; if your" >&2
    echo "configuration grants it none, attest that with FINDER_REVIEW_COPILOT_READONLY=1." >&2
    exit 1
fi
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
# A failing diff is a refusal, never an empty one: `set -e` does not apply
# inside a command substitution's assignment on every shell, so the status is
# checked explicitly.
diff_status=0
diff_text="$(collect_review_diff)" || diff_status=$?
if [ "$diff_status" -ne 0 ]; then
    echo "Could not collect the change for $slug (git exited $diff_status)." >&2
    echo "Refusing rather than reviewing a partial diff under a manifest that claims" >&2
    echo "to be complete." >&2
    exit 1
fi
# BYTES, via LC_ALL=C wc -c, not `${#diff_text}`: the shell counts characters
# and the kernel's per-argument limit counts bytes, so on a diff carrying
# multi-byte UTF-8 a character count passes this guard and then fails the exec
# with E2BIG — an uncontrolled failure in place of the bounded refusal.
diff_size="$(printf '%s' "$diff_text" | LC_ALL=C wc -c | tr -d ' ')"
if [ "$diff_bytes" -gt 0 ] && [ "$diff_size" -gt "$diff_bytes" ]; then
    echo "The change is ${diff_size} bytes, past the ${diff_bytes}-byte prompt bound for $slug." >&2
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
