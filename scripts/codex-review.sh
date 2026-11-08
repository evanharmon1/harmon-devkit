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
# Usage: codex-review.sh <review|challenge> [--repo-root <path>]
#        [--model <model>] [--reasoning <level>] [--require-effort]
#        [--envelope --run-id <id> --head <sha> --stage <stage> --round <n>
#         --slot <finder> --tier <tier>
#         --record-dir <dir> [--registry <file>]]
#        [--profile standardize --release <release> --frozen-render <bundle>]
#        [--base <ref>|--uncommitted|--commit <sha>] [focus text ...]
#
# --repo-root <path> reviews another checkout while this runner and its
# libraries stay the trusted copy beside this script (docs/guides/codex-review.md
# "Trusted runner for another checkout"). It must name a Git worktree root; it
# is stripped from the arguments here and never reaches review-scope.sh.
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
# part of `verify`/`ci`. Both modes ask for findings labelled on the P0–P3
# scale whose single normative statement is docs/review-guidelines.md
# ("Severity scale"); the prompt carries the same lines, read from
# scripts/lib/review-instructions/severity.txt, and test-codex-review.sh fails
# when the two differ. Only P0/P1 gate the local
# loop; everything else about adjudication is AGENTS.md's.
# The repository's own reviewer guidance — priorities, that scale, its
# invariants — is read from .devflow.toml [review_guidelines] and the file it
# names at the review's BASE revision (see "Review guidelines" below), so the
# change under review cannot rewrite the instructions that review it.
# No target path may invoke Codex with an empty scope; every one of them
# refuses and exits non-zero instead (see refuse_empty_scope).
# Requires an authenticated Codex CLI (`codex login`);
# see docs/guides/codex-review.md.
set -euo pipefail
# Resolved BEFORE any cd: the shared libraries below live beside this script,
# and `dirname "$0"` re-evaluated after the cd resolves against the new cwd
# (running `./codex-review.sh` from inside scripts/ would look for lib/ in the
# repository root). They are also what stays fixed when --repo-root points the
# review at a different checkout.
script_dir="$(cd "$(dirname "$0")" && pwd)"

usage() {
    echo "usage: $0 <review|challenge> [--repo-root <path>] [--model <model>] [--reasoning <low|medium|high|xhigh>] [--require-effort] [--envelope --run-id <id> --head <sha> --stage <stage> --round <n> --slot <finder> --tier <tier> --record-dir <dir> [--registry <file>]] [--profile standardize --release <release> --frozen-render <bundle>] [--base <ref>|--uncommitted|--commit <sha>] [focus text ...]" >&2
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

# Ordinarily the trusted runner lives inside the checkout it reviews. A
# confidence-stage launcher can instead hold these runner/library bytes fixed
# and point them at a separate candidate checkout. Strip only this runner-owned
# option; review-scope.sh receives every remaining argument unchanged.
repo_root="$script_dir/.."
repo_root_seen=false
review_args=()
while [ "$#" -gt 0 ]; do
    case "$1" in
    --repo-root)
        if [ "$repo_root_seen" = true ] || [ "$#" -lt 2 ] || [ -z "$2" ]; then
            echo "--repo-root requires exactly one non-empty path" >&2
            usage
            exit 2
        fi
        repo_root="$2"
        repo_root_seen=true
        shift 2
        ;;
    *)
        review_args+=("$1")
        shift
        ;;
    esac
done
# Bash 3.2/4.3 treats an empty array as unset under `set -u`, so expanding
# "${review_args[@]}" directly aborts the ordinary no-extra-arguments path.
if [ "${#review_args[@]}" -eq 0 ]; then
    set --
else
    set -- "${review_args[@]}"
fi

if [ ! -d "$repo_root" ]; then
    echo "--repo-root is not a directory: $repo_root" >&2
    exit 2
fi
repo_root="$(cd "$repo_root" && pwd -P)"
git_root="$(git -C "$repo_root" rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$git_root" ]; then
    echo "--repo-root is not a Git worktree: $repo_root" >&2
    exit 2
fi
git_root="$(cd "$git_root" && pwd -P)"
if [ "$git_root" != "$repo_root" ]; then
    echo "--repo-root must name the Git worktree root (got: $repo_root; root: $git_root)" >&2
    exit 2
fi
cd "$repo_root"

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
review_scope_apply_profile

# ── Review guidelines (harmon-init#1530) ────────────────────────────────────
# The repository's reviewer instructions live in ONE file named by .devflow.toml
# [review_guidelines] (docs/review-guidelines.md by convention), so the local
# finders and the PR-side reviewers read the same copy. Both the table and the
# file are read from the review's BASE revision, never the working tree, so the
# change under review cannot rewrite the instructions that review it: the merge
# base for a branch-scoped review (explicit --base or the auto-detected union),
# the parent for --commit, HEAD for --uncommitted. The policy reader is
# materialized from that same revision — a branch editing the reader may not
# choose how its own policy is read (AGENTS.md "Rigor and Strategy") — and a
# reader that predates the table, or no reader at all, falls back to the
# conventional path at that revision. Nothing configured leaves the built-in
# instructions untouched, byte for byte.
guidelines_rev=""
case "$review_diff_spec" in
base:* | both:*)
    guidelines_rev="$(git merge-base "${review_diff_spec#*:}" HEAD 2>/dev/null || true)"
    ;;
range:*)
    # Envelope mode rebinds the scope to immutable SHAs (merge base first).
    guidelines_rev="${review_diff_spec#range:}"
    guidelines_rev="${guidelines_rev%%:*}"
    ;;
commit:*)
    # Revision traversal hides parents at a shallow boundary. Read the commit
    # headers instead so missing history cannot masquerade as a genuine root.
    guidelines_commit="$(git cat-file -p "${review_diff_spec#commit:}^{commit}")" || {
        echo "could not read the reviewed commit for the review guidelines" >&2
        exit 2
    }
    guidelines_rev="$(sed -n '/^$/q; s/^parent //p' <<<"$guidelines_commit")"
    guidelines_rev="${guidelines_rev%%$'\n'*}"
    if [ -n "$guidelines_rev" ] && ! git cat-file -e "${guidelines_rev}^{commit}"; then
        echo "parent history unavailable at $guidelines_rev for the review guidelines; fetch the missing history before reviewing" >&2
        exit 2
    fi
    ;;
worktree)
    guidelines_rev="$(git rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null || true)"
    ;;
esac

guidelines_tmp="$(mktemp -d "${TMPDIR:-/tmp}/harmon-review-guidelines.XXXXXX")" || {
    echo "could not create a scratch directory for the review guidelines" >&2
    exit 2
}
trap 'rm -rf "$guidelines_tmp"' EXIT
# Node resolves import.meta.url physically; its CLI entry-point check must see
# the same path in argv even when TMPDIR contains a symlink.
guidelines_tmp_physical="$(cd "$guidelines_tmp" && pwd -P)" || {
    echo "could not resolve the scratch directory for the review guidelines" >&2
    exit 2
}
guidelines_tmp="$guidelines_tmp_physical"

# Prove absence with a successful literal tree lookup before reading content.
# Failed tree/blob reads are fatal even inside conditional callers, where
# errexit is suppressed; only a genuinely absent path returns 1 for fallback.
# Writing content to a file preserves its exact bytes (including newlines).
show_at_rev() {
    local entry
    entry="$(git --literal-pathspecs ls-tree --full-tree "$1" -- "$2")" || {
        echo "could not inspect '$2' at $1 for the review guidelines" >&2
        exit 2
    }
    [ -n "$entry" ] || return 1
    case "$entry" in
    '100644 blob '* | '100755 blob '*) ;;
    *)
        echo "'$2' at $1 is not a regular file for the review guidelines" >&2
        exit 2
        ;;
    esac
    git show "${1}:${2}" >"$3" || {
        echo "could not read '$2' at $1 for the review guidelines" >&2
        exit 2
    }
}

# The merge-base copy of the policy reader, in the layouts a repository can
# carry it: a repository-local script, harmon-devkit's own skill source tree,
# then the vendored dev-flow-support skill.
# Both import only ./lib/toml-lite.mjs beside themselves, so the pair is the
# whole program.
materialize_policy_reader() {
    local rev="$1" dest="$2" candidate
    for candidate in scripts/devflow-policy.mjs \
        ai/skills/universal/dev-flow-support/assets/devflow-policy.mjs \
        .claude/skills/dev-flow-support/assets/devflow-policy.mjs \
        .agents/skills/dev-flow-support/assets/devflow-policy.mjs; do
        mkdir -p "$dest/lib"
        if show_at_rev "$rev" "$candidate" "$dest/devflow-policy.mjs" &&
            show_at_rev "$rev" "${candidate%/*}/lib/toml-lite.mjs" "$dest/lib/toml-lite.mjs"; then
            return 0
        fi
    done
    rm -rf "$dest"
    return 1
}

# Globals the prompt assembly reads. Source is the human-readable provenance
# the prompt and the ledger name; text is the content; focus is the mode's
# configured default, used only when the CLI gave none.
guidelines_source=""
guidelines_text=""
guidelines_focus=""
resolve_review_guidelines() {
    local rev="$1" state=none policy="$guidelines_tmp/devflow.toml" reader="$guidelines_tmp/reader"
    local out="$guidelines_tmp/policy.json" err="$guidelines_tmp/reader.err" status=0 file
    [ -n "$rev" ] || {
        echo "==> Review guidelines: no base revision for this scope; built-in instructions only" >&2
        return 0
    }
    if show_at_rev "$rev" .devflow.toml "$policy"; then
        if ! command -v node >/dev/null 2>&1; then
            echo "Note: node is not installed, so .devflow.toml [review_guidelines] cannot be read; using the conventional path." >&2
        elif ! materialize_policy_reader "$rev" "$reader"; then
            echo "Note: no policy reader at $rev, so .devflow.toml [review_guidelines] cannot be read; using the conventional path." >&2
        else
            node "$reader/devflow-policy.mjs" resolve --policy "$policy" --json >"$out" 2>"$err" || status=$?
            # 3 is "resolved, cross-validation indeterminate" (no registry was
            # offered); the projection is complete either way.
            case "$status" in
            0 | 3)
                # Each projected value lands in its own file: `text` may span
                # lines, and a file keeps it intact without any quoting.
                node -e '
const fs = require("node:fs")
const [out, dir] = process.argv.slice(1)
const policy = JSON.parse(fs.readFileSync(out, "utf8"))
if (!Object.hasOwn(policy, "review_guidelines")) {
  fs.writeFileSync(`${dir}/state`, "unsupported")
} else if (policy.review_guidelines === null) {
  fs.writeFileSync(`${dir}/state`, "absent")
} else {
  fs.writeFileSync(`${dir}/state`, "table")
  for (const key of ["file", "text", "challenge_focus", "review_focus"]) {
    const value = policy.review_guidelines[key]
    if (typeof value === "string") fs.writeFileSync(`${dir}/${key}`, value)
  }
}
' "$out" "$guidelines_tmp" || {
                    echo "could not read the policy reader's output for [review_guidelines]" >&2
                    exit 2
                }
                state="$(cat "$guidelines_tmp/state")"
                ;;
            *)
                echo "Note: the policy reader at $rev refused .devflow.toml (exit ${status}); using the conventional path for the review guidelines." >&2
                sed 's/^/      /' "$err" >&2
                ;;
            esac
        fi
    fi
    case "$state" in
    table)
        if [ -f "$guidelines_tmp/file" ]; then
            file="$(cat "$guidelines_tmp/file")"
            # The reader already refused an unsafe path; a configured file that
            # does not exist at the base revision is a misconfiguration worth
            # failing on before the review is paid for.
            show_at_rev "$rev" "$file" "$guidelines_tmp/guidelines" || {
                echo ".devflow.toml [review_guidelines].file names '$file', which does not exist at $rev" >&2
                exit 2
            }
            guidelines_source="$file"
        elif [ -f "$guidelines_tmp/text" ]; then
            cp "$guidelines_tmp/text" "$guidelines_tmp/guidelines"
            guidelines_source=".devflow.toml [review_guidelines].text"
        fi
        if [ -f "$guidelines_tmp/${MODE}_focus" ]; then
            guidelines_focus="$(cat "$guidelines_tmp/${MODE}_focus")"
        fi
        ;;
    esac
    # No table, a reader that does not project it, or a table naming neither
    # source: the conventional path at the same revision, when it exists.
    if [ -z "$guidelines_source" ] && show_at_rev "$rev" docs/review-guidelines.md "$guidelines_tmp/guidelines"; then
        guidelines_source="docs/review-guidelines.md"
    fi
    if [ -n "$guidelines_source" ]; then
        guidelines_text="$(cat "$guidelines_tmp/guidelines")"
        echo "==> Review guidelines: ${guidelines_source} at $(git rev-parse --short "$rev")" >&2
    else
        echo "==> Review guidelines: none at $(git rev-parse --short "$rev"); built-in instructions only" >&2
    fi
}
resolve_review_guidelines "$guidelines_rev"
# Everything the prompt needs is now in variables; the scratch directory (and
# its EXIT trap, which the cleanup traps below would replace anyway) can go.
rm -rf -- "$guidelines_tmp"
trap - EXIT

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

# The repository's guidelines come straight after the mode preamble, so the
# reviewer reads what THIS repository asks for before the scale that labels it.
# Their provenance is stated so a reader of the prompt (or of a ledger quoting
# it) can tell which revision's instructions governed.
if [ -n "$guidelines_source" ]; then
    instructions="${instructions}

Repository review guidelines (${guidelines_source}, read at $(git rev-parse --short "$guidelines_rev")). Apply them throughout this review:

${guidelines_text}"
fi

if [ "$review_profile" = standardize ]; then
    instructions="${instructions}

$(read_instruction standardize)"
fi

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
elif [ -n "$guidelines_focus" ]; then
    # The policy's default focus for this mode stands in only when the CLI
    # gave none: an invoker's focus text is always the more specific ask.
    instructions="${instructions}

Default focus from the repository's review policy (.devflow.toml [review_guidelines].${MODE}_focus; weight it heavily): ${guidelines_focus}"
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
