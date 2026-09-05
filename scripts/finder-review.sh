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
# dispatch and record a blocker". A third-party CLI will not install it for us:
# its capability model is its own and its configuration is the operator's.
#
# So the boundary is built AROUND it instead, by scripts/lib/readonly-sandbox.sh
# — a per-run scratch `git worktree` checkout, made unwritable, entered with
# write credentials and git credential helpers stripped from the environment,
# under `bwrap --ro-bind` where bubblewrap exists — and then PROVEN: the pass
# is accepted only if that tree is byte-identical afterwards. Two earlier
# revisions tried to stand in for this, first with a comment claiming no tools
# were granted and then with an operator attestation; neither is verification,
# and a drifted configuration crossed the boundary in both.
#
# What it does not bound is network egress: the CLI must reach its model, so
# this denies writes to the checkout and to git, not exfiltration. A finder is
# handed the diff either way. Stated here rather than left to be discovered.
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
#   FINDER_REVIEW_COPILOT_BIN    (default: copilot)
#   FINDER_REVIEW_COPILOT_ARGS   (default: -p)     prompt appended as one arg
#   FINDER_REVIEW_MAX_PROMPT_BYTES (default: 60000) refusal bound on the WHOLE
#                                assembled prompt, in bytes
#                                (FINDER_REVIEW_MAX_DIFF_BYTES is the older
#                                name for it and still works)
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
coderabbit)
    # Registered on purpose, and refused on purpose. CodeRabbit's CLI resolves
    # its own review scope and takes no target from us, so a local pass could
    # not be bound to the round's `reviewed_head` — and a confidence slot is
    # complete only when its pass reviewed exactly that head. Running it anyway
    # would bank a pass over some other change as a pass over this one, which
    # is worse than not running it. The finder stays registered because the
    # requirement is that CodeRabbit be runnable locally AND on the PR; what is
    # missing is the binding, tracked as harmon-devkit#809.
    echo "finder '$slug' is registered but cannot be run locally yet." >&2
    echo "The CodeRabbit CLI resolves its own review scope and takes no target from us," >&2
    echo "so a local pass cannot be bound to this round's reviewed_head — every target" >&2
    echo "flag would run the identical command over a scope nobody chose." >&2
    echo "Tracked as harmon-devkit#809. Use coderabbit-cloud on the PR meanwhile." >&2
    exit 2
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
# per argument on Linux), so it needs a bound — and the bound is a REFUSAL,
# not a truncation. This run grants the agent no tools, so it cannot fetch
# what was cut: an earlier revision truncated with a marker telling the
# reviewer to ask for the rest, which it had no way to do, and the pass could
# still come back clean and be banked as a complete round. A partial review
# that exits 0 is indistinguishable from a clean one.
#
# The measurement is of the ASSEMBLED argument, after the diff, manifest,
# mode prose, severity scale and any focus text are all in it. Measuring the
# diff alone left the rest unbounded — the manifest repeats most of the
# diff's path bytes and the focus text has no cap at all — so a diff just
# under the limit could still fail the exec with E2BIG, which is the
# uncontrolled failure this bound exists to replace.
# FINDER_REVIEW_MAX_DIFF_BYTES is the older name, kept working because the
# guide documented it and an operator may have set it; what it bounds is the
# whole prompt, which is what the name FINDER_REVIEW_MAX_PROMPT_BYTES says.
prompt_bytes="${FINDER_REVIEW_MAX_PROMPT_BYTES:-${FINDER_REVIEW_MAX_DIFF_BYTES:-60000}}"
case "$prompt_bytes" in
'' | *[!0-9]*)
    echo "FINDER_REVIEW_MAX_PROMPT_BYTES must be a non-negative integer (got: '${prompt_bytes}')" >&2
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

instructions="${instructions}

The change itself:

${diff_text}"

# BYTES, via LC_ALL=C wc -c, not `${#instructions}`: the shell counts
# characters and the kernel's per-argument limit counts bytes, so on
# multi-byte content a character count passes this guard and then fails the
# exec.
prompt_size="$(printf '%s' "$instructions" | LC_ALL=C wc -c | tr -d ' ')"
if [ "$prompt_bytes" -gt 0 ] && [ "$prompt_size" -gt "$prompt_bytes" ]; then
    echo "The assembled prompt for $slug is ${prompt_size} bytes, past the ${prompt_bytes}-byte bound." >&2
    echo "This finder is handed the change and granted no tools, so a truncated prompt is a" >&2
    echo "review of part of it reported as a review of all of it. Narrow the scope" >&2
    echo "(--base <ref>, --commit <sha>, --uncommitted) or raise FINDER_REVIEW_MAX_PROMPT_BYTES" >&2
    echo "if your CLI and kernel accept a larger single argument." >&2
    exit 1
fi

# shellcheck disable=SC2206 # deliberate word-splitting: the override is a flag
# list, not one argument.
args=(${FINDER_REVIEW_COPILOT_ARGS:-$default_args})
if [ "$dry_run" = 1 ]; then
    printf 'finder: %s\ncommand: %s %s\n' "$slug" "$bin" "${args[*]}"
    printf '%s\n' "$instructions"
    exit 0
fi

# shellcheck source=scripts/lib/readonly-sandbox.sh
. "$script_dir/lib/readonly-sandbox.sh"
sandbox_create >/dev/null || {
    echo "Refusing to run $slug: the read-only scratch checkout could not be built, and" >&2
    echo "/review requires the capability split to be installed and verified or the" >&2
    echo "dispatch refused." >&2
    exit 1
}
trap 'sandbox_cleanup' EXIT

echo "==> $slug over: $scope" >&2
echo "    (read-only scratch checkout; the tree is verified unchanged afterwards)" >&2
finder_status=0
sandbox_exec "$bin" "${args[@]}" "$instructions" || finder_status=$?

# The verification is unconditional and runs BEFORE the exit status is
# honoured: a pass whose tree changed is not a pass, whatever the CLI
# returned, and reporting its findings would mean trusting output produced by
# something that just wrote to the checkout.
if ! sandbox_verify; then
    echo "Refusing $slug's output: the read-only checkout it ran against was modified," >&2
    echo "so this pass crossed the confidence-stage capability boundary. Nothing it" >&2
    echo "reported is accepted." >&2
    exit 1
fi
exit "$finder_status"
