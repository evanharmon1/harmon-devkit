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
# Usage: codex-review.sh <review|challenge> [--model <model>] [--reasoning <level>] [--require-effort]
#        [--envelope --run-id <id> --head <sha> --stage <stage> --round <n>
#         --slot <finder> --tier <tier>
#         --record-dir <dir> [--registry <file>]]
#        [--base <ref>|--uncommitted|--commit <sha>] [focus text ...]
#
# --require-effort exits non-zero if the reported effort differs from the
# request or is unknown. By default this is recorded and warned on stderr.
# --envelope makes this run the producer of one schema-bound result envelope
# for a dev-flow v2 run instead of a prose-only pass: Codex answers in the
# result.<role> payload schema, and the runner binds, validates and publishes
# that as exactly one immutable file under <record-dir>/passes/, printing its
# path on stdout. It never writes run.json — the caller appends the pass
# receipt. The contract is scripts/lib/review-scope.sh § "Envelope mode".
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
    echo "usage: $0 <review|challenge> [--model <model>] [--reasoning <low|medium|high|xhigh>] [--require-effort] [--envelope --run-id <id> --head <sha> --stage <stage> --round <n> --slot <finder> --tier <tier> --record-dir <dir> [--registry <file>]] [--base <ref>|--uncommitted|--commit <sha>] [focus text ...]" >&2
    echo "--require-effort: fail on mismatched or unknown effective effort (default: warn and preserve CLI status)" >&2
}

# WHAT gets reviewed — the target flags, the auto-detected scope, the
# authoritative manifest, and every refusal that keeps an empty or half scope
# from reading as a clean pass — is scripts/lib/review-scope.sh, shared with
# scripts/finder-review.sh. It sets `scope`, `manifest` and `focus`, and owns
# the envelope-mode flags and publication both runners share.
# shellcheck source=scripts/lib/review-scope.sh
. "$script_dir/lib/review-scope.sh"

MODE="${1:-}"
case "$MODE" in
review | challenge) shift ;;
*)
    usage
    exit 2
    ;;
esac

review_model="gpt-6.1-sol"
review_reasoning="high"
model_set=false
reasoning_set=false
require_effort=false
while [ $# -gt 0 ]; do
    case "$1" in
    --model)
        [ $# -ge 2 ] || {
            echo "--model requires a value" >&2
            exit 2
        }
        [ "$model_set" = false ] || {
            echo "--model may be specified only once" >&2
            exit 2
        }
        [[ "$2" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || {
            echo "invalid model name: $2" >&2
            exit 2
        }
        review_model="$2"
        model_set=true
        shift 2
        ;;
    --require-effort)
        require_effort=true
        shift
        ;;
    --reasoning)
        [ $# -ge 2 ] || {
            echo "--reasoning requires a value" >&2
            exit 2
        }
        [ "$reasoning_set" = false ] || {
            echo "--reasoning may be specified only once" >&2
            exit 2
        }
        case "$2" in
        low | medium | high | xhigh) review_reasoning="$2" ;;
        *)
            echo "unsupported reasoning level: $2" >&2
            exit 2
            ;;
        esac
        reasoning_set=true
        shift 2
        ;;
    *)
        review_envelope_flag "$@" || break
        shift "$envelope_shift"
        ;;
    esac
done

if [ "$envelope_mode" = true ]; then
    case "$MODE" in
    challenge) envelope_slug=codex-adversarial ;;
    review) envelope_slug=codex-verification ;;
    esac
    review_envelope_prepare "$MODE" "$envelope_slug" codex-cli
else
    review_envelope_refuse_stray_flags
fi

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

resolve_review_scope "$@"
[ "$envelope_mode" = false ] || review_envelope_bind_scope

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

if [ "$envelope_mode" = true ]; then
    instructions="${instructions}

$(review_envelope_instructions)"
fi

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
    # LC_ALL=C makes length()/substr() count bytes rather than characters, so
    # the ceiling holds whatever encoding the payload turns out to be in.
    # fflush() per line keeps the narration live: a round runs 5-15 minutes and
    # callers are told to read growing output as "still running, not hung"
    # (docs/guides/codex-review.md), which a block-buffered filter would break.
    LC_ALL=C awk -v max="$MAX_STDERR_BYTES" -v effort_file="$effort_capture" '
        BEGIN { effective = "unknown" }
        {
            # Only startup narration can attest effort. Later quoted output
            # from commands or findings must not impersonate the banner.
            if ($0 == "user" || $0 == "thinking" || $0 == "codex") startup_done = 1
            if ($0 ~ /^--------+$/ && ++separators == 2) startup_done = 1
            if (!startup_done && $0 ~ /^reasoning effort: [a-z]+\r?$/) {
                value = $0
                sub(/^reasoning effort: /, "", value)
                sub(/\r$/, "", value)
                if (++observations == 1) effective = value
                else if (value != effective) effective = "unknown"
            }
            if (max != 0 && length($0) > max) {
                printf "%s... [%d-byte line truncated by codex-review.sh; set CODEX_REVIEW_MAX_STDERR_BYTES=0 for the full text]\n", substr($0, 1, max), length($0)
            } else {
                print
            }
            fflush()
        }
        END { print effective > effort_file }
    '
}

# Capture only the effort readout, not the potentially huge narration. The
# filter parses before truncating, so even a tiny stderr ceiling cannot hide
# the effective value. No config or credential store is read or changed.
effort_capture="$(mktemp)"
trap 'rm -f -- "$effort_capture"' EXIT

check_review_effort() {
    effective_effort="$(cat "$effort_capture")"
    : "${effective_effort:=unknown}"
    effort_source=unknown
    [ "$effective_effort" = unknown ] || effort_source=banner
    effort_matched=false
    [ "$effective_effort" != "$review_reasoning" ] || effort_matched=true
    printf 'Codex reasoning effort: requested=%s effective=%s source=%s matched=%s\n' \
        "$review_reasoning" "$effective_effort" "$effort_source" "$effort_matched" >&2
    if [ "$effort_matched" = false ]; then
        printf 'WARNING: Codex reasoning effort mismatch: requested=%s effective=%s\n' \
            "$review_reasoning" "$effective_effort" >&2
        if [ "$require_effort" = true ]; then
            echo '--require-effort refuses mismatched or unknown reasoning effort' >&2
            return 1
        fi
    fi
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
if [ "$envelope_mode" = false ]; then
    codex_status=0
    { printf '%s\n' "$instructions" | codex exec review \
        --model "$review_model" \
        --config "model_reasoning_effort=$review_reasoning" \
        - 2>&1 1>&3 3>&- | bound_stderr_lines >&2; } 3>&1 || codex_status=$?
    effort_status=0
    check_review_effort || effort_status=$?
    [ "$codex_status" -eq 0 ] || exit "$codex_status"
    exit "$effort_status"
fi

# Envelope mode. Codex reviews an immutable checkout of the captured head —
# never the live worktree, which can move while the model runs — through the
# SAME `codex exec review` invocation legacy mode uses, and with it the same
# approval-never posture. Plain `codex exec` was tried and is ruled out: it
# runs approval on-request, so a command the model marks escalated escaped
# the read-only sandbox with no prompt (challenge-r4-codex-adversarial-2,
# maintainer decision 2026-10-11). The review subcommand takes no enforced
# output schema (it accepts --output-schema and never reads it), so the
# payload schema is requested in the prompt and the answer is parsed by
# review_envelope_publish, which refuses anything but exactly one object.
# Codex's answer (its stdout) goes to a private file and its narration to
# stderr; the runner's own stdout carries exactly one line, the published
# pass path.
# shellcheck source=scripts/lib/readonly-sandbox.sh
. "$script_dir/lib/readonly-sandbox.sh"
trap 'rm -f -- "$effort_capture"; sandbox_cleanup; review_envelope_cleanup' EXIT
mkdir -p "$envelope_record_dir/passes"
review_envelope_temp raw_payload codex-raw || exit 1
sandbox_create "$envelope_head" 0 >/dev/null || {
    echo "could not build the immutable review checkout at $envelope_head; no review ran" >&2
    exit 1
}
codex_status=0
{ printf '%s\n' "$instructions" | codex exec --cd "$readonly_sandbox_dir" review \
    --model "$review_model" \
    --config "model_reasoning_effort=$review_reasoning" \
    - 2>&1 1>&3 3>&- | bound_stderr_lines >&2; } 3>"$raw_payload" || codex_status=$?
effort_status=0
check_review_effort || effort_status=$?
# Verified before the status is honoured: output produced by something that
# changed its own review checkout is not accepted, whatever it returned.
sandbox_verify || {
    echo "Codex modified its immutable review checkout; refusing its output" >&2
    exit 1
}
[ "$codex_status" -eq 0 ] || {
    echo "codex exited $codex_status; no pass published" >&2
    exit "$codex_status"
}
[ "$effort_status" -eq 0 ] || exit "$effort_status"
[ "$(git rev-parse HEAD)" = "$envelope_head" ] || {
    echo "HEAD moved off $envelope_head during the review; refusing the stale pass" >&2
    exit 1
}
# Publish metadata only for the invocation that wins immutable pass
# publication. A late original losing to a retry must not replace its effort.
effort_dir="$envelope_record_dir/finder-effort"
mkdir -p "$effort_dir"
effort_metadata="$(mktemp "$effort_dir/.effort.XXXXXX")"
trap 'rm -f -- "$effort_capture" "$effort_metadata"; sandbox_cleanup; review_envelope_cleanup' EXIT
jq -n --arg requested "$review_reasoning" --arg effective "$effective_effort" \
    --arg source "$effort_source" --argjson matched "$effort_matched" \
    '{requested: $requested, effective: $effective, source: $source, matched: $matched}' >"$effort_metadata"
# Keep stdout empty until pass publication succeeds. Failed publication exits
# in the shared helper; its cleanup and ours remove every temporary. Metadata
# is advisory: a failed link must not invalidate the immutable published pass.
review_envelope_publish "$raw_payload" "$review_model" >"$effort_capture"
effort_path="$effort_dir/${envelope_pass_path##*/}"
ln -- "$effort_metadata" "$effort_path" || {
    echo "WARNING: could not publish advisory effort metadata $effort_path; keeping published pass" >&2
}
cat "$effort_capture"
