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
# Usage: codex-review.sh <review|challenge> [--model <model>] [--reasoning <level>]
#        [--envelope --run-id <id> --head <sha> --stage <stage> --round <n>
#         --slot <finder> --producer <script@sha> --record-dir <dir>
#         --policy <file> --registry <file>]
#        [--base <ref>|--uncommitted|--commit <sha>] [focus text ...]
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
    echo "usage: $0 <review|challenge> [--model <model>] [--reasoning <low|medium|high|xhigh>] [--envelope --run-id <id> --head <sha> --stage <stage> --round <n> --slot <finder> --producer <script@sha> --record-dir <dir> --policy <file> --registry <file>] [--base <ref>|--uncommitted|--commit <sha>] [focus text ...]" >&2
}

MODE="${1:-}"
case "$MODE" in
review | challenge) shift ;;
*)
    usage
    exit 2
    ;;
esac

review_model="gpt-5.6-sol"
review_reasoning="high"
model_set=false
reasoning_set=false
envelope_mode=false
run_id=
envelope_head=
envelope_stage=
envelope_round=
envelope_slot=
expected_producer=
record_dir=
policy_path=
registry_path=
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
    --envelope)
        envelope_mode=true
        shift
        ;;
    --run-id | --head | --stage | --round | --slot | --producer | --record-dir | --policy | --registry)
        [ $# -ge 2 ] || {
            echo "$1 requires a value" >&2
            exit 2
        }
        case "$1" in
        --run-id) run_id="$2" ;;
        --head) envelope_head="$2" ;;
        --stage) envelope_stage="$2" ;;
        --round) envelope_round="$2" ;;
        --slot) envelope_slot="$2" ;;
        --producer) expected_producer="$2" ;;
        --record-dir) record_dir="$2" ;;
        --policy) policy_path="$2" ;;
        --registry) registry_path="$2" ;;
        esac
        shift 2
        ;;
    *) break ;;
    esac
done

producer_identity="codex-review.sh@$(git hash-object "$script_dir/codex-review.sh")"
if [ "$envelope_mode" = true ]; then
    for required in run_id envelope_head envelope_stage envelope_round envelope_slot expected_producer record_dir policy_path registry_path; do
        [ -n "${!required}" ] || {
            echo "--envelope requires --${required//_/-}" >&2
            exit 2
        }
    done
    [ "$envelope_stage" = "$MODE" ] || {
        echo "--stage $envelope_stage does not match mode $MODE" >&2
        exit 2
    }
    [[ "$envelope_head" =~ ^[0-9a-f]{40}$ ]] || {
        echo "--head must be a 40-character lowercase sha" >&2
        exit 2
    }
    [[ "$envelope_round" =~ ^[1-9][0-9]*$ ]] || {
        echo "--round must be a positive integer" >&2
        exit 2
    }
    [ "$expected_producer" = "$producer_identity" ] || {
        echo "--producer does not match the script-derived producer identity ($producer_identity)" >&2
        exit 2
    }
    [ -d "$record_dir" ] || {
        echo "--record-dir must name an existing directory" >&2
        exit 2
    }
    [ -f "$record_dir/run.json" ] || {
        echo "--record-dir must contain run.json" >&2
        exit 2
    }
    [ -f "$policy_path" ] || {
        echo "--policy must name a readable file" >&2
        exit 2
    }
    [ -f "$registry_path" ] || {
        echo "--registry must name a readable file" >&2
        exit 2
    }
    command -v jq >/dev/null 2>&1 || {
        echo "jq is required for envelope mode" >&2
        exit 2
    }
    actual_head="$(git rev-parse HEAD)"
    [ "$actual_head" = "$envelope_head" ] || {
        echo "--head $envelope_head does not match HEAD $actual_head" >&2
        exit 1
    }
    initiated_by="$(jq -er --arg run "$run_id" 'select(.run_id == $run) | .initiated_by | select(. == "human" or . == "foreman")' "$record_dir/run.json")" || {
        echo "run.json does not bind run id '$run_id' to a valid initiated_by value" >&2
        exit 1
    }
    expected_slug="codex-${MODE/review/verification}"
    [ "$MODE" = challenge ] && expected_slug=codex-adversarial
    [ "$envelope_slot" = "$expected_slug" ] || {
        echo "--slot $envelope_slot does not match the configured Codex finder $expected_slug" >&2
        exit 1
    }
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

if [ "$envelope_mode" = true ]; then
    envelope_role=challenger
    [ "$MODE" = review ] && envelope_role=reviewer
    payload_schema="$script_dir/../ai/schemas/result.${envelope_role}.schema.json"
    instructions="${instructions}

Return only one JSON object matching the supplied output schema. This object is
the payload for a result.${envelope_role} envelope. Bind stage to
${MODE}, round to ${envelope_round}, reviewed_head to ${envelope_head}, finder
and slot to ${envelope_slot}, and use finding ids beginning
${MODE}-r${envelope_round}-${envelope_slot}-. Do not wrap it in Markdown."
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
if [ "$envelope_mode" = false ]; then
    { printf '%s\n' "$instructions" | codex exec review \
        --model "$review_model" \
        --config "model_reasoning_effort=$review_reasoning" \
        - 2>&1 1>&3 3>&- | bound_stderr_lines >&2; } 3>&1
    exit
fi

raw_payload="$(mktemp "$record_dir/.codex-payload.XXXXXX")"
envelope_tmp="$(mktemp "$record_dir/.codex-envelope.XXXXXX")"
known_ids="$(mktemp "$record_dir/.codex-known-ids.XXXXXX")"
cleanup_envelope() {
    rm -f "$raw_payload" "$envelope_tmp" "$known_ids"
}
trap cleanup_envelope EXIT

{ printf '%s\n' "$instructions" | codex exec review \
    --model "$review_model" \
    --config "model_reasoning_effort=$review_reasoning" \
    --output-schema "$payload_schema" \
    - 2>&1 1>&3 3>&- | bound_stderr_lines >&2; } 3>"$raw_payload"

jq -e --arg stage "$MODE" --argjson round "$envelope_round" \
    --arg head "$envelope_head" --arg finder "$expected_slug" \
    '.stage == $stage and .round == $round and .reviewed_head == $head and
     .finder == $finder and .slot == $finder' "$raw_payload" >/dev/null || {
    echo "finder payload does not match the captured stage, round, head, finder, and slot" >&2
    exit 1
}

producer_tier="$(jq -er --arg model "${review_model##*-}" \
    '[.families[].models[] | select(.slug == $model) | .tier] | unique | if length == 1 then .[0] else empty end' \
    "$registry_path")" || {
    echo "could not derive one producer tier for model $review_model from $registry_path" >&2
    exit 1
}

jq -n \
    --arg head "$envelope_head" \
    --arg produced_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg harness "$producer_identity" \
    --arg model "$review_model" \
    --arg tier "$producer_tier" \
    --arg run_id "$run_id" \
    --arg initiated_by "$initiated_by" \
    --slurpfile payload "$raw_payload" \
    --arg role "$envelope_role" \
    '{schema: 2, role: $role, status: "completed", head: $head,
      produced_at: $produced_at,
      producer: {harness: $harness, model: $model, tier: $tier},
      run: {run_id: $run_id, initiated_by: $initiated_by}, payload: $payload[0]}' \
    >"$envelope_tmp"

set -- "$record_dir"/passes/*.json
if [ -e "$1" ]; then
    jq -s '[.[].payload.findings[]?.id]' "$@" >"$known_ids"
else
    printf '[]\n' >"$known_ids"
fi

node "$script_dir/validate-result-schemas.mjs" envelope "$envelope_tmp" \
    --run-id "$run_id" --initiated-by "$initiated_by" --known-ids "$known_ids" --receipt

mkdir -p "$record_dir/passes"
pass_path="$record_dir/passes/${MODE}-r${envelope_round}-${envelope_slot}.json"
if ! ln "$envelope_tmp" "$pass_path" 2>/dev/null; then
    echo "refusing to overwrite existing pass $pass_path" >&2
    exit 1
fi
printf '%s\n' "$pass_path"
