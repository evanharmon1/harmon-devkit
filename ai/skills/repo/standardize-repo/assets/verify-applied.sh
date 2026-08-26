#!/usr/bin/env bash
#
# verify-applied.sh — validate a repo AFTER harmon-init conventions were applied.
#
# Usage:
#   verify-applied.sh [--ack-codeowner-change @old=@new]... [TARGET_DIR]
#   TARGET_DIR defaults to ".". Each acknowledgement must name one owner that
#   was actually dropped from main and one replacement present in the new file.
#
# Mirrors the validation philosophy of harmon-init's scripts/test-template.sh,
# but runs against an ALREADY-RENDERED, real repo (the result of `copier copy`
# / `copier update`), not a throwaway copier render. So it:
#   - delegates the heavy linting to the repo's own gate (`task verify`) instead
#     of re-implementing every linter, and
#   - spot-checks the structural invariants the template guarantees
#     (AGENTS.md canonical + agent-instruction symlinks, a parseable Taskfile,
#     no unrendered jinja markers, no leaked secrets).
#
# All checks accumulate; the script exits non-zero if ANY check fails, so it is
# safe to run as a post-apply gate in CI or locally.
#
# Portable to macOS bash 3.2 (no mapfile, no grep -P, no associative arrays).

set -euo pipefail

usage() {
    cat >&2 <<'USAGE'
Usage:
  verify-applied.sh [--ack-codeowner-change @old=@new]... [TARGET_DIR]

The CODEOWNERS acknowledgement is intentionally exact: repeat it for each
intentional owner migration. The verifier rejects stale, extra, malformed, or
non-materialized mappings; there is no blanket access-control bypass.
USAGE
}

target=""
codeowner_ack_count=0
codeowner_acks=()
while [ $# -gt 0 ]; do
    case "$1" in
    --ack-codeowner-change)
        [ $# -ge 2 ] || {
            usage
            echo "FAIL: --ack-codeowner-change requires @old=@new" >&2
            exit 2
        }
        ack="$2"
        if ! printf '%s\n' "$ack" | grep -qE '^@[A-Za-z0-9_/-]+=@[A-Za-z0-9_/-]+$'; then
            usage
            echo "FAIL: malformed CODEOWNERS acknowledgement: $ack" >&2
            exit 2
        fi
        old="${ack%%=*}"
        new="${ack#*=}"
        if [ "$old" = "$new" ]; then
            echo "FAIL: CODEOWNERS acknowledgement must name a real migration: $ack" >&2
            exit 2
        fi
        codeowner_acks+=("$ack")
        codeowner_ack_count=$((codeowner_ack_count + 1))
        shift 2
        ;;
    -h | --help)
        usage
        exit 0
        ;;
    -*)
        usage
        echo "FAIL: unknown argument: $1" >&2
        exit 2
        ;;
    *)
        if [ -n "$target" ]; then
            usage
            echo "FAIL: more than one target directory given" >&2
            exit 2
        fi
        target="$1"
        shift
        ;;
    esac
done
[ -n "$target" ] || target="."

if [ ! -d "$target" ]; then
    echo "FAIL: target directory not found: $target" >&2
    exit 1
fi

cd "$target"

have() { command -v "$1" >/dev/null 2>&1; }

# owner/repo for the checkout's origin remote, or nothing when it is not a
# GitHub remote (or not a git work tree at all).
github_remote_nwo() {
    local remote_url nwo=""
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
    remote_url="$(git remote get-url origin 2>/dev/null || true)"
    case "$remote_url" in
    https://github.com/*) nwo="${remote_url#https://github.com/}" ;;
    git@github.com:*) nwo="${remote_url#git@github.com:}" ;;
    ssh://git@github.com/*) nwo="${remote_url#ssh://git@github.com/}" ;;
    esac
    nwo="${nwo%.git}"
    printf '%s\n' "${nwo%/}"
}

fail=0
fail_msgs=""
err() {
    echo "FAIL: $*" >&2
    fail=1
    # accumulate a one-line summary of each failed check for the final verdict,
    # so "FAILED" names what failed rather than trailing the advisory drift WARN
    fail_msgs="${fail_msgs}    - $(printf '%s' "$*" | head -n 1)
"
}

echo "Verifying applied conventions in: $(pwd)"

# ── 1. The repo's own gate: `task verify` (lint + output checks) ─────
# This is the authoritative check — it runs whatever lint/test targets the
# generated Taskfile defines. We only orchestrate the structural spot-checks
# below; we do NOT duplicate the linters here.
if [ -f Taskfile.yml ] || [ -f Taskfile.yaml ]; then
    if have task; then
        if ! task verify; then
            err "'task verify' failed"
        fi
    else
        echo "WARN: 'task' (go-task) not installed — skipping 'task verify' gate"
    fi
else
    echo "WARN: no Taskfile.yml — repo may not have been standardized yet"
fi

# ── 2. AGENTS.md is canonical; agent-instruction files symlink to it ─
# copier.yml sets _preserve_symlinks: true so CLAUDE.md / GEMINI.md /
# .github/copilot-instructions.md stay as links pointing at AGENTS.md
# (copilot's canonical path is one dir down, so it links to ../AGENTS.md).
if [ ! -e AGENTS.md ]; then
    err "AGENTS.md missing"
elif [ -L AGENTS.md ] || [ ! -f AGENTS.md ]; then
    err "AGENTS.md should be a regular file, not a symlink or directory"
fi

for link in CLAUDE.md GEMINI.md; do
    if [ ! -L "$link" ]; then
        err "$link should be a symlink to AGENTS.md"
    elif [ "$(readlink "$link")" != "AGENTS.md" ]; then
        err "$link should resolve to AGENTS.md (found: $(readlink "$link"))"
    fi
done

# copilot's instructions file is optional, but if present it must link upward.
copilot=".github/copilot-instructions.md"
if [ -e "$copilot" ] || [ -L "$copilot" ]; then
    if [ ! -L "$copilot" ]; then
        err "$copilot should be a symlink to ../AGENTS.md"
    elif [ "$(readlink "$copilot")" != "../AGENTS.md" ]; then
        err "$copilot should resolve to ../AGENTS.md (found: $(readlink "$copilot"))"
    fi
fi

# ── 3. The generated Taskfile actually parses ───────────────────────
# `task verify` above would catch this too, but a broken Taskfile makes that
# step error out ambiguously; this gives a precise message.
if { [ -f Taskfile.yml ] || [ -f Taskfile.yaml ]; } && have task; then
    if ! task --color=false --list-all >/dev/null 2>&1; then
        err "Taskfile does not parse ('task --list-all' failed)"
    fi
fi

# ── 3a. Skills-sync never-vendored warning (advisory) ────────────────
# A newly rendered manifest deliberately starts with no provenance so the
# skills-sync gates can remain inert until a maintainer elects to vendor. That
# decision changes the target's CI and Dev Loop, so make the state visible here
# without turning it into a hard failure. The manifest's `dest` values, rather
# than a fixed Claude/Codex path, are authoritative because consumers may choose
# a different harness layout.
skills_sync_manifest=".skills-sync.yaml"
if [ -f "$skills_sync_manifest" ]; then
    skills_sync_dest=""
    skills_sync_agents_dest=""
    skills_sync_agents_requested=false
    if have yq; then
        skills_sync_dest="$(yq -r '.dest // ""' "$skills_sync_manifest" 2>/dev/null || true)"
        skills_sync_agents_dest="$(
            yq -r '.agents.dest // ""' "$skills_sync_manifest" 2>/dev/null || true
        )"
        if [ "$(
            yq -r 'has("agents")' "$skills_sync_manifest" 2>/dev/null || true
        )" = "true" ]; then
            skills_sync_agents_requested=true
        fi
    else
        # `yq` is a standardize-repo precondition. Keep this deliberately small
        # fallback for an otherwise-readable manifest: top-level `dest` and the
        # nested agents destination are all this advisory check needs.
        skills_sync_dest="$(
            sed -n -E 's/^dest:[[:space:]]*([^#[:space:]]+).*$/\1/p' \
                "$skills_sync_manifest" 2>/dev/null |
                tail -n 1 |
                sed -E "s/^\"(.*)\"$/\1/; s/^'(.*)'$/\1/" || true
        )"
        if grep -qE '^agents:[[:space:]]*($|#)' "$skills_sync_manifest"; then
            skills_sync_agents_requested=true
            skills_sync_agents_dest="$(
                awk '
                    /^agents:[[:space:]]*($|#)/ { in_agents = 1; next }
                    /^[^[:space:]#]/ { in_agents = 0 }
                    in_agents && /^[[:space:]]+dest:[[:space:]]*/ {
                        sub(/^[[:space:]]*dest:[[:space:]]*/, "")
                        sub(/[[:space:]]+#.*$/, "")
                        sub(/[[:space:]]+$/, "")
                        print
                        exit
                    }
                ' "$skills_sync_manifest" 2>/dev/null |
                    sed -E "s/^\"(.*)\"$/\1/; s/^'(.*)'$/\1/" || true
            )"
        fi
    fi

    skills_sync_managed=0
    if [ -n "$skills_sync_dest" ] &&
        grep -q '^# managed:' "$skills_sync_dest/.SKILLS_PROVENANCE" 2>/dev/null; then
        skills_sync_managed=1
    fi

    skills_sync_agents_managed=0
    if [ "$skills_sync_agents_requested" = false ]; then
        skills_sync_agents_managed=1
    elif [ -n "$skills_sync_agents_dest" ] &&
        grep -q '^# managed:' \
            "$skills_sync_agents_dest/.AGENTS_PROVENANCE" 2>/dev/null; then
        skills_sync_agents_managed=1
    fi

    skills_sync_assets=""
    if [ -n "$skills_sync_dest" ] && [ "$skills_sync_managed" -eq 0 ]; then
        skills_sync_assets="skills"
    fi
    if [ "$skills_sync_agents_requested" = true ] &&
        [ -n "$skills_sync_agents_dest" ] &&
        [ "$skills_sync_agents_managed" -eq 0 ]; then
        if [ -n "$skills_sync_assets" ]; then
            skills_sync_assets="$skills_sync_assets and agents"
        else
            skills_sync_assets="agents"
        fi
    fi

    if [ -n "$skills_sync_assets" ]; then
        printf '%s%s\n' \
            "WARN: .skills-sync.yaml is never vendored: $skills_sync_assets have no # managed: provenance; run " \
            "'task sync:skills' to materialize them." >&2
    fi
fi

# ── 3b. Required universal Taskfile targets are present ──────────────
# Every standardized repo defines these regardless of project_type. A missing
# one means the Taskfile drifted from (or predates) the current template — the
# recurring example is status:setup (the setup-completeness audit), which older
# forks of scripts/status.sh + Taskfile never had.
if { [ -f Taskfile.yml ] || [ -f Taskfile.yaml ]; } && have task; then
    tasklist="$(task --color=false --list-all 2>/dev/null || true)"
    for t in verify check security status:setup install:hooks; do
        if ! printf '%s\n' "$tasklist" | grep -qE "^[* ]*${t}:([[:space:]]|\$)"; then
            err "Taskfile missing required target: ${t}"
        fi
    done
fi

# ── 3c. Workflow ↔ Taskfile contract ────────────────────────────────
# Every CI job / git hook delegates to a `task` target; enforce the CONVERSE —
# every `task <target>` a workflow invokes MUST exist in the Taskfile. CI's
# lint/build jobs call targets `task verify` never runs (e.g. test:tasks,
# test:hooks, test:devcontainer:permissions). A Taskfile that drifted from the
# template — or was restored wholesale from a pre-template `main` during a
# Path-B adopt while the template's workflows were taken as-is — can omit them,
# so `task verify` (and this script's §1 gate) stays GREEN while CI goes RED.
# This existence check catches that class at apply time. We anchor on a command
# CONTEXT — `run: task <t>`, a run-block line starting with `task <t>`, or
# `&& task <t>` — so prose ("the specific task described"), renovate comments
# (`go-task/task extractVersion`), and `setup-task@<sha>` never match.
if [ -d .github/workflows ] && { [ -f Taskfile.yml ] || [ -f Taskfile.yaml ]; } && have task; then
    tasklist="$(task --color=false --list-all 2>/dev/null || true)"
    called="$(
        grep -rhoE '(run:[[:space:]]*|^[[:space:]]*|&&[[:space:]]*)task +[a-z][a-z0-9:_-]*' .github/workflows/ 2>/dev/null |
            sed -E 's/.*task +//' | sort -u || true
    )"
    for t in $called; do
        if ! printf '%s\n' "$tasklist" | grep -qE "^[* ]*${t}:([[:space:]]|\$)"; then
            err "workflow calls 'task ${t}' but the Taskfile has no such target"
        fi
    done
fi

# ── 3d. Terraform lint + provider-lock contract ──────────────────────
# Terraform coverage is capability-gated, not universal. When a repo selected
# include_terraform OR contains first-party .tf files, `task check` must actually
# reach fmt, TFLint, Checkov, and the cross-platform provider-lock check. Merely
# naming those tools in docs (or committing one host's lock file) is not proof.
include_terraform_answer=""
if [ -f .copier-answers.yml ]; then
    include_terraform_answer="$(
        sed -n -E 's/^[[:space:]]*include_terraform:[[:space:]]*([^#[:space:]]+).*$/\1/p' .copier-answers.yml |
            tail -n 1 | tr '[:upper:]' '[:lower:]' | tr -d "\"'"
    )"
fi

repo_files=""
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    repo_files="$(git ls-files --cached --others --exclude-standard 2>/dev/null || true)"
else
    repo_files="$(find . -type f 2>/dev/null | sed 's#^\./##' || true)"
fi

# A Copier TEMPLATE repo's payload is not its own source, for the purpose of
# deciding which CAPABILITIES this repo implements. harmon-init ships
# `template/[% if include_terraform %]terraform[% endif %]/main.tf` — a file the
# GENERATED repo receives, not Terraform harmon-init lints — and counting it
# turns on the whole Terraform contract (lint tasks, provider-lock helper, a
# required terraform-verify) against a repo that rightly implements none of it.
# The payload root is whatever `copier.yml` declares as `_subdirectory`, so only
# a real template repo is affected.
#
# SCOPE: capability gating only. `repo_files` itself stays whole, because the
# payload IS authored code the template distributes — hiding it from the CodeQL
# matrix-drift check below would turn a security-coverage question ("is this
# language scanned?") into a blind spot.
# Expand Copier's `!include <glob>` documents in place. Copier splices the
# referenced files' documents into the manifest before merging; yq has no such
# tag and fails the whole merge on it ("cannot multiply !!map with !include"),
# which would drop the payload root for a perfectly valid template.
#
# Two details are taken from Copier's own loader (`_template.load_template_config`)
# rather than guessed: its `!include` constructor closes over the TOP-LEVEL
# manifest, so every nested glob resolves against that one directory, and it
# reuses the same loader class, so includes nest.
#
# DELIBERATE BOUNDARY: Copier globs with Python's `Path.glob`, which this cannot
# reproduce in portable shell — a quoted path containing spaces would be word
# split, and bash 3.2 has no `globstar` for `**`. Rather than half-match those,
# the expansion refuses them and the caller declines the exclusion with a
# diagnostic. Declining only over-reports a capability; guessing the wrong
# directory would skip a contract the repo really owes.
copier_include_unsupported=0
copier_include_invalid=0
copier_manifest_expanded() {
    local manifest="$1" root_dir="$2" depth="${3:-0}"
    local line include_glob include_file include_matches include_unreadable
    local saved_dotglob
    # Cap the depth: a cyclic include would otherwise spin forever. At the cap
    # the file is emitted unexpanded, leaving any tag for yq to reject — which
    # surfaces as the "could not parse" diagnostic.
    if [ "$depth" -ge 8 ]; then
        cat "$manifest"
        return 0
    fi
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
        '!include '*)
            include_glob="$(
                printf '%s' "${line#!include }" |
                    sed -E 's/[[:space:]]+#.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//' |
                    sed -E 's/^"(.*)"$/\1/; s/^'"'"'(.*)'"'"'$/\1/'
            )"
            case "$include_glob" in
            /*)
                # Copier rejects the manifest outright here:
                # `raise ValueError("YAML include file path must be a relative
                # path")`. Concatenating it onto the root would happily read a
                # repo-root fragment and trust a `_subdirectory` Copier never
                # loads.
                copier_include_invalid=1
                continue
                ;;
            *[[:space:]]* | *'**'*)
                copier_include_unsupported=1
                continue
                ;;
            esac
            # `Path.glob` matches leading-dot names (unlike the `glob` module
            # and unlike bash's default), so `*frag.yml` finds `.b-frag.yml` for
            # Copier but not for us. Without dotglob a hidden fragment that
            # overrides `_subdirectory` stays invisible here, the match below
            # still counts 1, and we would trust a payload root Copier never
            # uses. Restore the setting straight after.
            # `shopt -p` exits non-zero when the option is OFF, which under
            # `set -e` would abort the whole run — hence `|| true`.
            saved_dotglob="$(shopt -p dotglob || true)"
            shopt -s dotglob
            # Deliberately unquoted: Copier's include target is a glob, and it
            # resolves against the top-level manifest's directory at every
            # nesting level.
            # shellcheck disable=SC2086
            set -- "$root_dir"/$include_glob
            eval "$saved_dotglob"
            # Count EVERY glob result, not just the readable files. Copier's
            # `Path.glob` yields directories too and its loader then dies trying
            # to read one — so skipping them here could let us parse a manifest
            # Copier rejects outright, and act on a `_subdirectory` it never
            # honours. A non-file match is reason to decline, not to ignore.
            include_matches=0
            include_unreadable=0
            for include_file in "$@"; do
                [ -e "$include_file" ] || continue
                include_matches=$((include_matches + 1))
                if [ ! -f "$include_file" ] || [ ! -r "$include_file" ]; then
                    include_unreadable=1
                fi
            done
            # Several fragments: whichever sets `_subdirectory` last wins, and
            # shell expansion orders them differently from Python's `Path.glob`.
            # Decline rather than pick.
            if [ "$include_matches" -gt 1 ] || [ "$include_unreadable" -eq 1 ]; then
                copier_include_unsupported=1
                continue
            fi
            for include_file in "$@"; do
                [ -f "$include_file" ] || continue
                printf -- '---\n'
                copier_manifest_expanded "$include_file" "$root_dir" "$((depth + 1))"
                printf -- '\n---\n'
            done
            ;;
        *) printf '%s\n' "$line" ;;
        esac
    done <"$manifest"
}

template_payload_dir=""
copier_manifest=""
copier_manifest_count=0
# Mirror Copier's own discovery: it globs `copier.*` and keeps files whose
# suffix matches /\.ya?ml/ CASE-INSENSITIVELY, raising MultipleConfigFilesError
# when more than one matches. Looking only for the two lowercase spellings would
# miss a valid `copier.YAML`, and picking one of two would trust a manifest
# Copier refuses to read.
for candidate_manifest in copier.*; do
    [ -f "$candidate_manifest" ] || continue
    case "$candidate_manifest" in
    *.[Yy][Mm][Ll] | *.[Yy][Aa][Mm][Ll]) ;;
    *) continue ;;
    esac
    copier_manifest_count=$((copier_manifest_count + 1))
    [ -n "$copier_manifest" ] || copier_manifest="$candidate_manifest"
done
if [ "$copier_manifest_count" -gt 1 ]; then
    # Copier itself rejects a template carrying both manifests, so there is no
    # effective payload root to honour — picking one would exclude a directory
    # on the authority of a file Copier refuses to read.
    echo "WARN: several copier.y[a]ml manifests exist; Copier rejects that as ambiguous," >&2
    echo "      so no payload root is assumed and payload files are read as first-party." >&2
elif [ -n "$copier_manifest" ]; then
    if have yq; then
        # Let a real YAML parser decide. copier.yml may hold several documents
        # (Copier merges them, later winning) in block or flow syntax, so a
        # textual scan keeps disagreeing with the value Copier actually renders
        # from — and disagreeing here excludes the WRONG directory, silently
        # skipping the Terraform contract for source the repo really owns. The
        # reduce below reproduces Copier's own merge order.
        copier_manifest_merged="$(mktemp "${TMPDIR:-/tmp}/verify-copier-manifest.XXXXXX")"
        copier_manifest_expanded "$copier_manifest" "$(dirname "$copier_manifest")" \
            >"$copier_manifest_merged"
        if [ "$copier_include_invalid" -eq 1 ]; then
            template_payload_dir=""
            echo "WARN: $copier_manifest has an absolute '!include' path, which Copier rejects" >&2
            echo "      as an invalid manifest — no payload root is assumed and payload files" >&2
            echo "      are read as first-party source." >&2
        elif [ "$copier_include_unsupported" -eq 1 ]; then
            template_payload_dir=""
            echo "WARN: $copier_manifest uses an '!include' glob this auditor does not" >&2
            echo "      reproduce exactly (whitespace or '**'), so no payload root is" >&2
            echo "      assumed and payload files are read as first-party source." >&2
        elif copier_payload_tag="$(
            yq ea -r '. as $document ireduce ({}; . * $document) | ._subdirectory | tag' \
                "$copier_manifest_merged" 2>/dev/null
        )"; then
            # Copier hands a non-string `_subdirectory` to Jinja and rejects the
            # template, so `123` is not a directory named "123" — treating it as
            # one could exclude real source.
            case "$copier_payload_tag" in
            '!!str')
                # Normalize lexically before comparing: `git ls-files` reports
                # `template/main.tf`, so a root spelled `././template` or
                # `template/.` would pass the -d check below and then match no
                # prefix at all. Drop empty and `.` segments; a `..` segment
                # cannot be resolved by string comparison, so leave it in place
                # for the directory guard to reject.
                template_payload_dir="$(
                    yq ea -r '. as $document ireduce ({}; . * $document) | ._subdirectory' \
                        "$copier_manifest_merged" 2>/dev/null |
                        awk '{
                            count = split($0, segment, "/")
                            normalized = ""
                            for (i = 1; i <= count; i++) {
                                if (segment[i] == "" || segment[i] == ".") {
                                    continue
                                }
                                normalized = (normalized == "" ? segment[i] : normalized "/" segment[i])
                            }
                            print normalized
                        }'
                )"
                ;;
            '!!null') template_payload_dir="" ;;
            *)
                template_payload_dir=""
                echo "WARN: $copier_manifest declares a non-string _subdirectory ($copier_payload_tag)," >&2
                echo "      which Copier rejects — no payload root is assumed and payload files" >&2
                echo "      are read as first-party source." >&2
                ;;
            esac
        else
            template_payload_dir=""
            echo "WARN: yq could not parse $copier_manifest, so no payload root is assumed" >&2
            echo "      and payload files are read as first-party source. Check the manifest" >&2
            echo "      if this repo is a Copier template." >&2
        fi
        rm -f "$copier_manifest_merged"
    else
        echo "WARN: $copier_manifest exists but yq is not installed, so this repo's Copier" >&2
        echo "      payload root cannot be resolved — payload files will be read as" >&2
        echo "      first-party source. Install yq for accurate capability detection." >&2
    fi
fi
capability_files="$repo_files"
case "$template_payload_dir" in
"" | "." | "/") ;;
*'..'*)
    # A `..` segment cannot be compared lexically against the repo-relative
    # paths `git ls-files` reports, so there is no safe prefix to filter on.
    echo "WARN: $copier_manifest declares payload root '$template_payload_dir', which walks" >&2
    echo "      outside the repo layout — nothing is excluded from capability detection." >&2
    ;;
*'{{'* | *'{%'* | *'[['* | *'[%'*)
    # Copier renders `_subdirectory` from the answers, so a templated value has
    # no single payload root to compare against here. Say so and exclude
    # nothing: over-reporting a capability is the safe direction.
    echo "WARN: copier.yml declares a templated payload root ('$template_payload_dir');" >&2
    echo "      it cannot be resolved without answers, so nothing is excluded from" >&2
    echo "      capability detection — expect payload files to be read as first-party." >&2
    ;;
*)
    # A payload root that is not a real directory here cannot be what Copier
    # renders from. The delimiter list above only knows the default and harmon
    # spellings, and `_envops` can set any others (`<< payload >>`), so this
    # catches every templated value regardless of delimiters — and a typo too.
    # Without it the exclusion silently matches nothing while announcing that
    # it excluded something.
    if [ ! -d "$template_payload_dir" ]; then
        echo "WARN: $copier_manifest declares payload root '$template_payload_dir' but no such" >&2
        echo "      directory exists here — a value templated with custom Jinja delimiters" >&2
        echo "      (_envops) reads like this, as does a typo. Nothing is excluded from" >&2
        echo "      capability detection; payload files are read as first-party." >&2
    else
        echo "INFO: Copier template repo detected; excluding the '$template_payload_dir/' payload" >&2
        echo "      from capability detection (it belongs to generated repos). CodeQL source" >&2
        echo "      coverage still counts it." >&2
        # Prefix compare rather than a regex, so a payload name needs no escaping.
        capability_files="$(
            printf '%s\n' "$repo_files" |
                PAYLOAD_DIR="$template_payload_dir" \
                    awk 'index($0, ENVIRON["PAYLOAD_DIR"] "/") != 1'
        )"
    fi
    ;;
esac
terraform_sources="$(
    printf '%s\n' "$capability_files" |
        grep -E '\.tf$' |
        grep -vE '(^|/)(\.terraform|node_modules|vendor|dist|build)/' || true
)"

# Print the lines of one job's block (everything under `  <job>:` up to the next
# job header). Used to bind a contract to the job that carries it rather than to
# the whole workflow file. Inside `jobs:`, EVERY key at exactly two spaces is a
# job header, whatever trails the colon — a boundary that also insisted on an
# empty tail would let a header carrying a YAML anchor (`toolchain: &toolchain`)
# slip through and hand the previous job its sibling's steps, which is the
# fail-OPEN direction for a provisioning check. Job-level keys sit at four
# spaces and block scalars must indent past their key, so nothing inside a job
# can reach two.
workflow_job_block() {
    awk -v target="$2" '
        BEGIN { in_job = 0 }
        {
            if (!in_job) {
                if ($0 ~ ("^  " target ":([ ]|$)")) {
                    in_job = 1
                }
                next
            }
            if ($0 ~ /^  [A-Za-z0-9_-]+:/ || $0 ~ /^[A-Za-z0-9_-]+:/) {
                exit
            }
            print
        }
    ' "$1"
}

# Print the job keys whose own steps run the shared gate (`task check`). The
# match is anchored on a command CONTEXT — after `run:`, at the start of a
# run-block line, or after a `&&`/`||`/`;` separator — optionally behind an
# environment or wrapper prefix (`CI=true task check`, `env FOO=bar task check`).
# Comments are skipped, so prose mentioning the gate (harmon-infra's
# claude-implement.yml does) never nominates a job.
gate_jobs_running_check() {
    awk '
        function flush() {
            if (job != "" && runs_check) {
                print job
            }
            runs_check = 0
        }
        BEGIN {
            in_jobs = 0
            job = ""
            runs_check = 0
            prefix = "(([A-Za-z_][A-Za-z0-9_]*=[^ \t]*|env|command|sudo|nice|time)[ \t]+)*"
            gate = prefix "task[ \t]+check([ \t]|$)"
        }
        {
            line = $0
            if (!in_jobs) {
                if (line ~ /^jobs:[ ]*(#.*)?$/) {
                    in_jobs = 1
                }
                next
            }
            if (line ~ /^[A-Za-z0-9_-]+:/) {
                flush()
                in_jobs = 0
                next
            }
            if (line ~ /^  [A-Za-z0-9_-]+:([ ]|$)/) {
                flush()
                job = line
                sub(/^  /, "", job)
                sub(/:.*$/, "", job)
                next
            }
            if (line ~ /^[[:space:]]*#/) {
                next
            }
            if (line ~ ("run:[ \t]*" gate) ||
                line ~ ("^[ \t]*" gate) ||
                line ~ ("(&&|\\|\\||;)[ \t]*" gate)) {
                runs_check = 1
            }
        }
        END { flush() }
    ' "$1"
}

provider_lock_init_modes_are_safe() {
    local helper="$1"
    local probe fake_terraform check_root update_root result

    probe="$(mktemp -d "${TMPDIR:-/tmp}/verify-provider-lock-init.XXXXXX")" || return 1
    fake_terraform="$probe/terraform"
    check_root="$probe/check"
    update_root="$probe/update"
    result=0

    cat >"$fake_terraform" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
-chdir=*) ;;
*) exit 2 ;;
esac
shift

case "${1:-}" in
init)
    shift
    upgrade=false
    for arg in "$@"; do
        if [ "$arg" = -upgrade ]; then
            upgrade=true
        fi
    done
    case "${EXPECT_INIT_UPGRADE:-}:$upgrade" in
    false:false | true:true) ;;
    *) exit 90 ;;
    esac
    ;;
providers)
    shift
    [ "${1:-}" = lock ] || exit 2
    ;;
*) exit 2 ;;
esac
EOF
    chmod +x "$fake_terraform"
    mkdir "$check_root" "$update_root"
    printf '%s\n' 'terraform {}' >"$check_root/main.tf"
    printf '%s\n' 'terraform {}' >"$update_root/main.tf"

    if ! EXPECT_INIT_UPGRADE=false TERRAFORM_BIN="$fake_terraform" \
        "$helper" check "$check_root" >/dev/null 2>&1; then
        result=1
    fi
    if ! EXPECT_INIT_UPGRADE=true TERRAFORM_BIN="$fake_terraform" \
        "$helper" update "$update_root" >/dev/null 2>&1; then
        result=1
    fi

    rm -rf "$probe"
    [ "$result" -eq 0 ]
}

has_terraform=false
case "$include_terraform_answer" in
true | yes)
    has_terraform=true
    ;;
false | no | "") ;;
*)
    err "invalid include_terraform value in .copier-answers.yml: $include_terraform_answer"
    ;;
esac
if [ -n "$terraform_sources" ]; then
    has_terraform=true
fi

if [ "$has_terraform" = true ]; then
    provider_lock_helper="scripts/terraform-provider-locks.sh"
    if [ ! -f "$provider_lock_helper" ]; then
        err "Terraform is present but $provider_lock_helper is missing"
    else
        if [ ! -x "$provider_lock_helper" ]; then
            err "$provider_lock_helper must be executable"
        fi
        provider_lock_program="$(sed -E 's/[[:space:]]*#.*$//' "$provider_lock_helper")"
        for lock_contract in \
            'providers lock' \
            '-platform=darwin_arm64' \
            '-platform=linux_amd64'; do
            if ! grep -qF -- "$lock_contract" <<<"$provider_lock_program"; then
                err "$provider_lock_helper does not establish '$lock_contract'"
            fi
        done
        if [ -x "$provider_lock_helper" ] &&
            ! provider_lock_init_modes_are_safe "$provider_lock_helper"; then
            err "$provider_lock_helper must pass -upgrade to init only in update mode"
        fi
    fi

    provider_lock_regression="scripts/test-terraform-provider-locks.sh"
    if [ ! -f "$provider_lock_regression" ]; then
        err "Terraform is present but $provider_lock_regression is missing"
    elif [ ! -x "$provider_lock_regression" ]; then
        err "$provider_lock_regression must be executable"
    elif ! "$provider_lock_regression" >/dev/null 2>&1; then
        err "$provider_lock_regression failed its hermetic lock-process checks"
    fi

    if have task && { [ -f Taskfile.yml ] || [ -f Taskfile.yaml ]; }; then
        terraform_tasklist="$(task --color=false --list-all 2>/dev/null || true)"
        for terraform_task in lint:terraform terraform:providers:lock; do
            if ! grep -qE "^[* ]*${terraform_task}:([[:space:]]|\$)" \
                <<<"$terraform_tasklist"; then
                err "Terraform Taskfile contract is missing target: $terraform_task"
            fi
        done

        terraform_lint_dry="$(task --color=false --dry lint:terraform 2>&1 || true)"
        terraform_check_dry="$(task --color=false --dry check 2>&1 || true)"
        terraform_lock_dry="$(task --color=false --dry terraform:providers:lock 2>&1 || true)"

        for dry_contract in \
            'terraform fmt -check' \
            'tflint --recursive' \
            'checkov==' \
            'checkov -d'; do
            if ! grep -qF -- "$dry_contract" <<<"$terraform_lint_dry"; then
                err "task lint:terraform does not reach '$dry_contract'"
            fi
            if ! grep -qF -- "$dry_contract" <<<"$terraform_check_dry"; then
                err "task check does not reach Terraform contract '$dry_contract'"
            fi
        done
        if ! grep -qE 'terraform-provider-locks\.sh[[:space:]]+check[[:space:]]+[^[:space:]]' \
            <<<"$terraform_lint_dry"; then
            err "task lint:terraform does not reach the provider-lock check helper"
        fi
        if ! grep -qE 'terraform-provider-locks\.sh[[:space:]]+check[[:space:]]+[^[:space:]]' \
            <<<"$terraform_check_dry"; then
            err "task check does not reach the Terraform provider-lock check helper"
        fi
        if ! grep -qE 'uvx .*--from .*checkov==' <<<"$terraform_lint_dry"; then
            err "task lint:terraform must run pinned Checkov through uvx --from"
        fi
        if ! grep -qE 'terraform-provider-locks\.sh[[:space:]]+update[[:space:]]+[^[:space:]]' \
            <<<"$terraform_lock_dry"; then
            err "task terraform:providers:lock does not reach the explicit lock update helper"
        fi
    else
        echo "WARN: task is unavailable; Terraform lint/lock task reachability needs manual audit." >&2
    fi

    if [ ! -f Brewfile ]; then
        err "Terraform is present but Brewfile is missing its local tool contract"
    else
        for formula in terraform tflint uv; do
            if ! grep -qE "^[[:space:]]*brew[[:space:]]+['\"]${formula}['\"]" Brewfile; then
                err "Terraform local lint contract is missing brew formula: $formula"
            fi
        done
    fi

    # The toolchain must be reachable from the JOB that actually runs the shared
    # gate (`task check`) — a setup action in a sibling job installs nothing on
    # the gate job's runner. Split repos provision it in the gate job directly
    # (harmon-infra's validate.yml lint job), while freshly rendered repos
    # provision it through a local composite action that job invokes
    # (.github/actions/setup). So each gate job is satisfied by its OWN steps
    # plus the composite actions IT uses; a dead workflow — or a live but
    # unrelated job — carrying the setup actions cannot vouch for it.
    gate_jobs_found=false
    for workflow_file in .github/workflows/*.y*ml; do
        [ -f "$workflow_file" ] || continue
        while IFS= read -r gate_job; do
            [ -n "$gate_job" ] || continue
            gate_jobs_found=true
            gate_job_block="$(workflow_job_block "$workflow_file" "$gate_job")"
            # The job's own steps, plus every local composite action it uses.
            gate_provision_text="$gate_job_block"
            while IFS= read -r composite_ref; do
                [ -n "$composite_ref" ] || continue
                for composite_file in "$composite_ref"/action.yml "$composite_ref"/action.yaml; do
                    [ -f "$composite_file" ] || continue
                    gate_provision_text="$gate_provision_text
$(cat "$composite_file")"
                done
            done <<<"$(
                printf '%s\n' "$gate_job_block" |
                    sed -n -E 's|^[[:space:]]*-?[[:space:]]*uses:[[:space:]]*(\./\.github/actions/[A-Za-z0-9_./-]+).*|\1|p'
            )"
            for setup_action in \
                'hashicorp/setup-terraform@' \
                'terraform-linters/setup-tflint@' \
                'astral-sh/setup-uv@'; do
                if ! printf '%s\n' "$gate_provision_text" |
                    grep -qE "^[[:space:]]*-?[[:space:]]*uses:[[:space:]]+${setup_action}"; then
                    err "$workflow_file job '$gate_job' runs 'task check' but neither it nor the composite actions it uses provisions Terraform lint dependency: $setup_action"
                fi
            done
        done <<<"$(gate_jobs_running_check "$workflow_file")"
    done
    if [ "$gate_jobs_found" = false ]; then
        err "Terraform is present but no CI workflow runs 'task check' to reach its lint contract"
    fi
fi

# ── 3e. Build/devcontainer aggregate result contracts ──────────────
# A generic "success or skipped" aggregate is not fail-closed: on a trusted
# event it can disguise a job that never ran, and on a fork it can disguise a
# repository-controlled job that unexpectedly ran. The standard has two exact
# branches. Fork PRs validate every suppressed leaf as `skipped` in workflow-
# inline shell without checkout/repo code; trusted events check out only after
# the fork branch and require every leaf to be `success` through the tested
# helper.
aggregate_job_contract_is_safe() {
    local workflow="$1"
    local aggregate_job="$2"

    awk -v target="$aggregate_job" '
        function clear_step_refs(key) {
            for (key in step_refs) {
                delete step_refs[key]
            }
        }
        function reset_step() {
            clear_step_refs()
            in_step = 0
            is_boundary = 0
            fork_condition = 0
            trusted_condition = 0
            is_checkout = 0
            is_helper = 0
            has_run = 0
            checks_skipped = 0
            boundary_message = 0
            expected_success = 0
            uses_any = 0
            repo_code = 0
        }
        function finish_step(key) {
            if (!in_step) {
                return
            }
            if (is_boundary) {
                if (fork_condition && has_run && checks_skipped &&
                    boundary_message && !uses_any && !repo_code) {
                    safe_boundary = 1
                }
                for (key in step_refs) {
                    fork_refs[key] = 1
                }
            }
            if (is_checkout) {
                if (trusted_condition) {
                    safe_checkout = 1
                } else {
                    unsafe_checkout = 1
                }
            }
            if (is_helper) {
                if (trusted_condition && expected_success) {
                    safe_helper = 1
                } else {
                    unsafe_helper = 1
                }
                for (key in step_refs) {
                    trusted_refs[key] = 1
                }
            }
            reset_step()
        }
        function collect_refs(value, token) {
            value = $0
            while (match(value, /needs\.[A-Za-z0-9_-]+\.result/)) {
                token = substr(value, RSTART, RLENGTH)
                step_refs[token] = 1
                value = substr(value, RSTART + RLENGTH)
            }
        }
        BEGIN {
            in_job = 0
            found_job = 0
            always_job = 0
            fork_expression = 0
            safe_boundary = 0
            safe_checkout = 0
            safe_helper = 0
            unsafe_checkout = 0
            unsafe_helper = 0
            generic_allowlist = 0
            reset_step()
        }
        {
            line = $0
            if (!in_job) {
                if (line ~ ("^  " target ":[ ]*(#.*)?$")) {
                    in_job = 1
                    found_job = 1
                }
                next
            }
            if (line ~ /^  [A-Za-z0-9_-]+:[ ]*(#.*)?$/) {
                finish_step()
                in_job = 0
                next
            }
            if (line ~ /^[[:space:]]*if:[[:space:]]*always\(\)/) {
                always_job = 1
            }
            if (index(line, "IS_FORK:") &&
                index(line, "github.event_name ==") && index(line, "pull_request") &&
                index(line, "head.repo.full_name != github.repository")) {
                fork_expression = 1
            }
            if (index(line, "success") && index(line, "skipped") &&
                index(line, "||")) {
                generic_allowlist = 1
            }
            if (line ~ /^      - /) {
                finish_step()
                in_step = 1
            }
            if (!in_step || line ~ /^[[:space:]]*#/) {
                next
            }
            if (index(line, "name:") && index(line, "untrusted-fork boundary")) {
                is_boundary = 1
            }
            if (index(line, "if:") && index(line, "env.IS_FORK ==") &&
                index(line, "true")) {
                fork_condition = 1
            }
            if (index(line, "if:") && index(line, "env.IS_FORK !=") &&
                index(line, "true")) {
                trusted_condition = 1
            }
            if (line ~ /uses:[ ]*actions\/checkout@/) {
                is_checkout = 1
            }
            if (line ~ /run:[ ]*\.\/scripts\/verify-ci-results\.sh/) {
                is_helper = 1
            }
            if (line ~ /^[[:space:]]*run:/) {
                has_run = 1
            }
            if (index(line, "EXPECTED_RESULT:") && index(line, "success")) {
                expected_success = 1
            }
            if (index(line, "!=") && index(line, "skipped")) {
                checks_skipped = 1
            }
            if (index(line, "Untrusted fork trust boundary enforced:")) {
                boundary_message = 1
            }
            if (line ~ /uses:/) {
                uses_any = 1
            }
            if (is_boundary &&
                (line ~ /scripts\// || line ~ /run:[ ]*(\.\/|bash |sh )/)) {
                repo_code = 1
            }
            collect_refs()
        }
        END {
            finish_step()
            ref_count = 0
            refs_match = 1
            for (key in fork_refs) {
                ref_count++
                if (!(key in trusted_refs)) {
                    refs_match = 0
                }
            }
            for (key in trusted_refs) {
                if (!(key in fork_refs)) {
                    refs_match = 0
                }
            }
            exit(found_job && always_job && fork_expression && safe_boundary &&
                 safe_checkout && safe_helper && !unsafe_checkout &&
                 !unsafe_helper && !generic_allowlist && ref_count > 0 &&
                 refs_match ? 0 : 1)
        }
    ' "$workflow"
}

workflow_job_has_fork_guard() {
    local workflow="$1"
    local leaf_job="$2"

    awk -v target="$leaf_job" '
        BEGIN { in_job = 0; found = 0; event_guard = 0; repo_guard = 0 }
        {
            line = $0
            if (!in_job) {
                if (line ~ ("^  " target ":[ ]*(#.*)?$")) {
                    in_job = 1
                    found = 1
                }
                next
            }
            if (line ~ /^  [A-Za-z0-9_-]+:[ ]*(#.*)?$/) {
                in_job = 0
                next
            }
            if (index(line, "github.event_name !=") && index(line, "pull_request")) {
                event_guard = 1
            }
            if (index(line, "head.repo.full_name == github.repository")) {
                repo_guard = 1
            }
        }
        END { exit(found && event_guard && repo_guard ? 0 : 1) }
    ' "$workflow"
}

required_results_helper="scripts/verify-ci-results.sh"
# The aggregate job is discovered, not hardcoded: split-workflow repos name
# their rollups per workflow (`build-verify`, `validate-verify`, …) instead of
# the template's `verify`. The job that runs the trusted-results helper IS the
# trusted aggregate for that workflow.
find_aggregate_job() {
    # Only 2-space keys inside the jobs: block are job headers — the same
    # indent appears under on:/permissions:, and a paths: trigger can name
    # verify-ci-results.sh without being an aggregate job.
    awk '
        /^jobs:[ ]*(#.*)?$/ {
            in_jobs = 1
            next
        }
        in_jobs && /^[A-Za-z0-9_-]+:/ {
            in_jobs = 0
        }
        in_jobs && /^  [A-Za-z0-9_-]+:[ ]*(#.*)?$/ {
            job = $1
            sub(/:$/, "", job)
        }
        in_jobs && /verify-ci-results\.sh/ && job != "" {
            print job
            exit
        }
    ' "$1"
}
aggregate_workflows=""
for aggregate_workflow in \
    .github/workflows/build.yml .github/workflows/build.yaml \
    .github/workflows/devcontainer-build.yml .github/workflows/devcontainer-build.yaml; do
    [ -f "$aggregate_workflow" ] || continue
    aggregate_job="$(find_aggregate_job "$aggregate_workflow")"
    if [ -z "$aggregate_job" ]; then
        err "$aggregate_workflow has no job running $required_results_helper — the trusted aggregate is missing"
        continue
    fi
    aggregate_workflows="${aggregate_workflows}${aggregate_workflow}:${aggregate_job}
"
done

if [ -n "$aggregate_workflows" ]; then
    if [ ! -f "$required_results_helper" ]; then
        err "aggregate workflows exist but $required_results_helper is missing"
    elif [ ! -x "$required_results_helper" ]; then
        err "$required_results_helper must be executable because trusted aggregates run it directly"
    else
        required_results_contract_ok=true
        if ! EXPECTED_RESULT=success "$required_results_helper" \
            lint=success security=success >/dev/null 2>&1; then
            required_results_contract_ok=false
        fi
        if ! EXPECTED_RESULT=skipped "$required_results_helper" \
            lint=skipped security=skipped >/dev/null 2>&1; then
            required_results_contract_ok=false
        fi
        for rejected_contract in \
            'success lint=success security=skipped' \
            'skipped lint=skipped security=success' \
            'success lint=success security=failure' \
            'success lint=success security=cancelled' \
            'success lint=success security=unknown'; do
            rejected_expected="${rejected_contract%% *}"
            rejected_pairs="${rejected_contract#* }"
            # Intentional word splitting: each fixture token is one name=result pair.
            # shellcheck disable=SC2086
            if EXPECTED_RESULT="$rejected_expected" "$required_results_helper" \
                $rejected_pairs >/dev/null 2>&1; then
                required_results_contract_ok=false
            fi
        done
        if [ "$required_results_contract_ok" != true ]; then
            err "$required_results_helper does not enforce one exact expected result for every leaf"
        fi
    fi

    while IFS=: read -r aggregate_workflow aggregate_job; do
        [ -n "$aggregate_workflow" ] || continue
        if ! aggregate_job_contract_is_safe "$aggregate_workflow" "$aggregate_job"; then
            err "$aggregate_workflow job '$aggregate_job' must enforce exact fork-skipped/trusted-success results without fork checkout or repository code"
            continue
        fi
        aggregate_leaves="$(
            awk -v target="$aggregate_job" '
                BEGIN { in_job = 0 }
                {
                    if (!in_job) {
                        if ($0 ~ ("^  " target ":[ ]*(#.*)?$")) in_job = 1
                        next
                    }
                    if ($0 ~ /^  [A-Za-z0-9_-]+:[ ]*(#.*)?$/) exit
                    print
                }
            ' "$aggregate_workflow" |
                grep -oE 'needs\.[A-Za-z0-9_-]+\.result' |
                sed -E 's/^needs\.//; s/\.result$//' | sort -u || true
        )"
        for aggregate_leaf in $aggregate_leaves; do
            if ! workflow_job_has_fork_guard "$aggregate_workflow" "$aggregate_leaf"; then
                err "$aggregate_workflow leaf '$aggregate_leaf' is aggregated as fork-skipped but lacks the same-repository PR guard"
            fi
        done
    done <<<"$aggregate_workflows"
fi

# The shipped ruleset has an exact answer-derived required-check set.
use_codeql_answer=""
if [ -f .copier-answers.yml ]; then
    use_codeql_answer="$(
        sed -n -E 's/^[[:space:]]*use_codeql:[[:space:]]*([^#[:space:]]+).*$/\1/p' .copier-answers.yml |
            tail -n 1 | tr '[:upper:]' '[:lower:]' | tr -d "\"'"
    )"
fi

codeql_required=false
case "$use_codeql_answer" in
true | yes)
    codeql_required=true
    ;;
esac

ruleset_file=".github/Branch Protection Ruleset - Protect Main.json"
if [ -f "$ruleset_file" ]; then
    ruleset_contexts="$(
        sed -n -E 's/.*"context"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' \
            "$ruleset_file" | sort -u
    )"
    has_ruleset_context() {
        printf '%s\n' "$ruleset_contexts" | grep -qxF "$1"
    }
    # Match a workflow `branches:` pattern. GitHub's Actions filter patterns are
    # NOT shell globs, and every difference points at accepting a filter that
    # never actually runs:
    #   *   any characters EXCEPT `/`   (a shell `*` crosses `/`)
    #   **  any characters including `/`
    #   ?   zero or one of the PRECEDING character   (not "any one character")
    #   +   one or more of the preceding character
    # Translate to an anchored ERE rather than matching with `case`, whose `*`
    # would happily cross `/` and accept `releases/*` for `releases/1/2`.
    # Remaining regex metacharacters are escaped to literals, so a `[abc]`
    # character class (legal but unheard of in a branch filter) simply fails to
    # match — closed. The pattern crosses into awk through the environment, not
    # `-v`: `-v` processes escape sequences in the value, so a pattern's `\+`
    # would arrive as a bare `+` and be read back as a quantifier.
    branch_pattern_matches() {
        BRANCH_PATTERN="$1" BRANCH_NAME="$2" awk '
            BEGIN {
                pattern = ENVIRON["BRANCH_PATTERN"]
                branch = ENVIRON["BRANCH_NAME"]
                expr = "^"
                count = length(pattern)
                for (i = 1; i <= count; i++) {
                    char = substr(pattern, i, 1)
                    if (char == "\\") {
                        # GitHub escapes a literal special character with a
                        # backslash (`release/v1\+`); carry it through as a
                        # literal instead of reading the quantifier.
                        i++
                        escaped = substr(pattern, i, 1)
                        if (escaped != "") {
                            if (index("\\^$.[]|(){}*+?", escaped) > 0) {
                                expr = expr "\\" escaped
                            } else {
                                expr = expr escaped
                            }
                        }
                        continue
                    }
                    if (char == "*") {
                        if (substr(pattern, i + 1, 1) == "*") {
                            expr = expr ".*"
                            i++
                        } else {
                            expr = expr "[^/]*"
                        }
                    } else if (char == "?" || char == "+") {
                        # ERE quantifiers bind to the preceding atom, which is
                        # exactly what these two mean here.
                        expr = expr char
                    } else if (index("\\^$.[]|(){}", char) > 0) {
                        expr = expr "\\" char
                    } else {
                        expr = expr char
                    }
                }
                exit(branch ~ (expr "$") ? 0 : 1)
            }
        '
    }

    # The refs the ruleset protects — the branches a required context must be
    # able to report on. Read `ref_name.include` specifically, not every
    # `refs/heads/…` in the file: `exclude` entries are not protected, and
    # treating one as a protected branch would invent a wedge.
    #
    # The scan is a JSON string walk, not a regex: a ref name may legally
    # contain the very delimiters a regex would key on (`refs/heads/release]`
    # ends an `[^]]*` array early, and the fallback would then audit the wrong
    # branch). Walking characters with quote/escape state also makes member
    # order irrelevant and pretty-printed vs compact JSON identical. Emits
    # `include <ref>` / `exclude <ref>` lines.
    ruleset_ref_selectors() {
        awk '
            function flush_string(   text) {
                text = buffer
                buffer = ""
                return text
            }
            BEGIN {
                RS = "^$"          # slurp the whole file
                depth = 0
                in_string = 0
                escaped = 0
                buffer = ""
                pending_key = ""
                ref_depth = -1
                bucket = ""
                seen_ref_name = 0
            }
            {
                count = length($0)
                for (i = 1; i <= count; i++) {
                    char = substr($0, i, 1)
                    if (in_string) {
                        if (escaped) {
                            buffer = buffer char
                            escaped = 0
                        } else if (char == "\\") {
                            escaped = 1
                        } else if (char == "\"") {
                            in_string = 0
                            text = flush_string()
                            # A string followed by `:` is a key; otherwise it is
                            # a value — and inside ref_name`s arrays, a ref.
                            # JSON allows whitespace before the colon.
                            lookahead = i + 1
                            while (substr($0, lookahead, 1) ~ /[ \t\r\n]/) {
                                lookahead++
                            }
                            if (substr($0, lookahead, 1) == ":") {
                                pending_key = text
                                if (text == "ref_name" && !seen_ref_name) {
                                    seen_ref_name = 1
                                    ref_depth = depth
                                }
                                if (ref_depth >= 0 && depth == ref_depth + 1 &&
                                    (text == "include" || text == "exclude")) {
                                    bucket = text
                                }
                            } else if (bucket != "" && ref_depth >= 0 &&
                                depth == ref_depth + 2) {
                                print bucket " " text
                            }
                        } else {
                            buffer = buffer char
                        }
                        continue
                    }
                    if (char == "\"") {
                        in_string = 1
                        buffer = ""
                        continue
                    }
                    if (char == "{" || char == "[") {
                        depth++
                        continue
                    }
                    if (char == "}" || char == "]") {
                        depth--
                        if (ref_depth >= 0 && depth <= ref_depth) {
                            exit
                        }
                        if (ref_depth >= 0 && depth == ref_depth + 1) {
                            bucket = ""
                        }
                        continue
                    }
                }
            }
        ' "$1"
    }
    ruleset_ref_selector_lines="$(ruleset_ref_selectors "$ruleset_file")"
    protected_selectors="$(
        printf '%s\n' "$ruleset_ref_selector_lines" |
            { grep '^include ' || true; } | cut -d' ' -f2- | sort -u
    )"
    excluded_selectors="$(
        printf '%s\n' "$ruleset_ref_selector_lines" |
            { grep '^exclude ' || true; } | cut -d' ' -f2- | sort -u
    )"
    # `exclude` carves branches back out of `include`, so an excluded branch is
    # not protected and auditing a filter against it would invent a wedge.
    # Only a CONCRETE exclusion is applied. Ruleset ref selectors are matched
    # with `File.fnmatch`, whose treatment of `**` under pathname semantics does
    # not agree with the Actions dialect used everywhere else here (Ruby's
    # `fnmatch("releases/**", "releases/2026/q3", FNM_PATHNAME)` is false, the
    # Actions reading is true), and guessing wrong on an EXCLUSION drops a
    # genuinely protected branch from the audit — the fail-open direction. So a
    # wildcard exclusion is reported and left unapplied: the branch stays
    # protected and its coverage still has to hold.
    ruleset_excludes_branch() {
        local branch="$1" excluded
        for excluded in $excluded_selectors; do
            case "$excluded" in
            *'*'* | *'?'* | *'['*)
                continue
                ;;
            "refs/heads/$branch")
                return 0
                ;;
            esac
        done
        return 1
    }
    for excluded_selector in $excluded_selectors; do
        case "$excluded_selector" in
        *'*'* | *'?'* | *'['*)
            echo "WARN: ruleset excludes the wildcard ref selector '$excluded_selector';" >&2
            echo "      it is left applied-to-nothing (branches stay protected) — confirm by" >&2
            echo "      hand which refs it actually removes." >&2
            ;;
        esac
    done
    # Resolve `~DEFAULT_BRANCH` to a branch name. GitHub resolves it against the
    # repository's LIVE default branch, so ask the API first and fall back to the
    # local `origin/HEAD` (which a default-branch rename leaves stale). Prints
    # nothing when neither is available — the caller defers to a manual audit
    # rather than guessing a name and vouching for a filter against it.
    # `|| true`: under `pipefail` a repo with no origin remote (every test
    # fixture, a fresh local scaffold) would otherwise abort the whole run.
    live_default_branch() {
        local nwo branch=""
        nwo="$(github_remote_nwo)"
        if [ -n "$nwo" ] && have gh; then
            branch="$(gh api "repos/$nwo" --jq '.default_branch' 2>/dev/null || true)"
        fi
        if [ -z "$branch" ]; then
            branch="$(
                { git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || true; } |
                    sed 's|^origin/||'
            )"
        fi
        printf '%s\n' "$branch"
    }
    # Only a selector that names ONE concrete branch can be matched against a
    # workflow's branch filter. `~ALL`, a glob (`refs/heads/releases/**`), and
    # any selector form this auditor does not model each name a SET of branches,
    # and deciding whether a filter covers the whole set is glob containment —
    # not attempted here, so they are surfaced for manual audit rather than
    # matched as if they were literal branch names (which would silently accept
    # `releases/*` for `releases/2026/q3`). Path and activity-type filters are
    # still checked for those contexts; only branch coverage is deferred.
    protected_branches=""
    for protected_selector in $protected_selectors; do
        case "$protected_selector" in
        '~DEFAULT_BRANCH')
            resolved_default_branch="$(live_default_branch)"
            if [ -n "$resolved_default_branch" ]; then
                ruleset_excludes_branch "$resolved_default_branch" ||
                    protected_branches="${protected_branches}${resolved_default_branch}
"
            else
                echo "WARN: ruleset protects '~DEFAULT_BRANCH' but this checkout cannot resolve the" >&2
                echo "      repository's default branch — audit required-check branch-filter" >&2
                echo "      coverage for it by hand." >&2
            fi
            ;;
        refs/heads/*'*'* | refs/heads/*'?'* | refs/heads/*'['*)
            echo "WARN: ruleset protects the wildcard ref selector '$protected_selector' —" >&2
            echo "      audit required-check branch-filter coverage for it by hand." >&2
            ;;
        refs/heads/*)
            ruleset_excludes_branch "${protected_selector#refs/heads/}" ||
                protected_branches="${protected_branches}${protected_selector#refs/heads/}
"
            ;;
        *)
            echo "WARN: ruleset protects the ref selector '$protected_selector', which this" >&2
            echo "      auditor cannot reduce to a single branch — audit required-check" >&2
            echo "      branch-filter coverage for it by hand." >&2
            ;;
        esac
    done
    # A ruleset with no `conditions` at all is not a shape GitHub exports; treat
    # it as protecting the default branch so the rest of the audit still runs,
    # and use `main` when even that is unknowable — unlike the explicit
    # `~DEFAULT_BRANCH` selector above, there is no stated intent to be faithful
    # to here.
    if [ -z "$protected_selectors" ]; then
        protected_branches="$(live_default_branch)"
        [ -n "$protected_branches" ] || protected_branches=main
    fi
    # A split rollup standing in for the template's verify/security must be
    # result-gated — it needs `needs:` and must inspect `needs.<leaf>.result`
    # (or run the trusted-results helper). A job that exists but just echoes
    # success would launder a failing leaf into a green required check.
    # DELIBERATE BOUNDARY: this is a drift auditor, not a proof system — it
    # rejects the launderable shapes (no needs:, or no result inspection at
    # all) but does not statically prove the shell enforces exact outcomes;
    # without `if: always()` branch protection is already fail-closed (a
    # failing leaf skips the rollup and blocks the merge), and exact-contract
    # verification belongs to the repo's own regression (e.g. harmon-infra's
    # test-tasks.sh aggregate assertions).
    # The shipped ruleset stacks a merge_queue rule on the required checks, so
    # a required context must report on BOTH pull_request and merge_group — a
    # PR-only workflow wedges the merge queue exactly like a dispatch-only one.
    workflow_reports_on_protected_events() {
        awk '
            BEGIN { in_on = 0; pr = 0; mg = 0 }
            {
                line = $0
                sub(/#.*$/, "", line)
            }
            line ~ /^on:/ {
                in_on = 1
                if (line ~ /pull_request([^_a-z]|$)/) pr = 1
                if (line ~ /merge_group([^_a-z]|$)/) mg = 1
                next
            }
            in_on && line ~ /^[A-Za-z_-]+:/ { in_on = 0 }
            in_on {
                if (line ~ /pull_request([^_a-z]|$)/) pr = 1
                if (line ~ /merge_group([^_a-z]|$)/) mg = 1
            }
            END { exit(pr && mg ? 0 : 1) }
        ' "$1"
    }
    # A required context must report on EVERY protected-event run, not only the
    # runs a trigger filter lets through. A filter that keeps the workflow from
    # starting means the context never posts a status at all, and branch
    # protection blocks that merge forever — the same wedge as a required check
    # no workflow defines.
    #
    # This is an allowlist, not a blocklist of known-bad filters: under
    # `on.pull_request` / `on.merge_group` only three keys are auditable —
    #   * `branches:`        must cover the protected branch (`branches: [main]`,
    #                        the standard's own shape, is fine)
    #   * `branches-ignore:` must not name it
    #   * `types:`           must keep `synchronize`, or a later push to the PR
    #                        never re-reports and the check stays pending
    # — and ANY other key (`paths`, `paths-ignore`, an unknown one) or any shape
    # this parser cannot read (an inline flow mapping for the whole `on:` block
    # or for an event body) is rejected unread. Enumerating unsafe shapes would
    # fail open on the next legal variant; enumerating auditable ones fails
    # closed on it. The standard keeps path scoping INSIDE the workflow anyway:
    # terraform.yml always starts and an internal `changes` job makes unrelated
    # changes a fast no-op (mode-audit: "internal change detector, not
    # workflow-level path filters").
    #
    # DELIBERATE BOUNDARY: an event-dependent job-level `if:` can wedge the same
    # way, but proving a conditional never evaluates true on a protected event
    # needs expression evaluation, not static analysis — and the standard's
    # aggregates are `if: always()`, so the filtered-*workflow* half is the
    # cheap, unambiguous one and is what this rejects.

    # Judge one protected event from its collected trigger keys/values. Echoes
    # the reason it cannot always report, or nothing.
    protected_event_verdict() {
        local event="$1" keys="$2" values="$3" branches="$4"
        local key value branch state required_types required_type
        for key in $keys; do
            case "$key" in
            branches | branches-ignore | types) ;;
            *)
                printf "its %s trigger carries a '%s' filter, so a filtered-out run never starts the workflow\n" \
                    "$event" "$key"
                return 0
                ;;
            esac
        done
        # A narrowed types: list leaves some protected run unreported. For
        # pull_request the default is [opened, synchronize, reopened] — without
        # `opened` the check is missing until someone pushes, without
        # `synchronize` a pushed commit never re-reports on the new head SHA.
        # merge_group has exactly one activity type, so a list that omits
        # `checks_requested` (an empty list, a typo) never runs in the queue.
        if printf '%s\n' "$keys" | grep -qx types; then
            case "$event" in
            pull_request) required_types="opened synchronize reopened" ;;
            *) required_types="checks_requested" ;;
            esac
            for required_type in $required_types; do
                if ! printf '%s\n' "$values" | grep -qx "types $required_type"; then
                    printf "its %s types: filter omits '%s', so some protected run never reports\n" \
                        "$event" "$required_type"
                    return 0
                fi
            done
        fi
        for branch in $branches; do
            if printf '%s\n' "$keys" | grep -qx branches; then
                # GitHub evaluates the patterns IN ORDER and the last match
                # wins, so `['!main', main]` does run on main.
                state=""
                while read -r key value; do
                    [ "$key" = branches ] || continue
                    case "$value" in
                    '!'*)
                        if branch_pattern_matches "${value#!}" "$branch"; then
                            state=excluded
                        fi
                        ;;
                    *)
                        if branch_pattern_matches "$value" "$branch"; then
                            state=included
                        fi
                        ;;
                    esac
                done <<<"$values"
                if [ "$state" != included ]; then
                    printf 'its %s branches: filter excludes %s\n' "$event" "$branch"
                    return 0
                fi
            fi
            while read -r key value; do
                [ "$key" = branches-ignore ] || continue
                if branch_pattern_matches "$value" "$branch"; then
                    printf 'its %s branches-ignore: filter excludes %s\n' "$event" "$branch"
                    return 0
                fi
            done <<<"$values"
        done
    }

    # Prints why the workflow cannot always report, or nothing when it can.
    protected_event_filter_reason() {
        local workflow="$1" branches="$2"
        local tag rest reason="" event="" keys="" values="" unparsed=0
        local unparsed_reason="its 'on:' triggers use an inline flow mapping this auditor cannot read per event — write them in block form"
        while read -r tag rest; do
            case "$tag" in
            FLOWMAP | UNPARSED)
                [ -n "$reason" ] || reason="$unparsed_reason"
                unparsed=1
                ;;
            EVENT)
                # An EVENT line closes the previous event; awk emits a final
                # sentinel so the last one is always closed.
                if [ -z "$reason" ] && [ -n "$event" ] && [ "$unparsed" -eq 0 ]; then
                    reason="$(
                        protected_event_verdict "$event" "$keys" "$values" "$branches"
                    )"
                fi
                event="$rest"
                keys=""
                values=""
                unparsed=0
                ;;
            K)
                keys="${keys}${rest}
"
                ;;
            V)
                values="${values}${rest}
"
                ;;
            esac
        done <<<"$(
            awk '
                function indent_of(text) {
                    match(text, /^[ ]*/)
                    return RLENGTH
                }
                # Read one YAML scalar: strip quotes, decode double-quoted
                # escapes, and drop a trailing comment. A `#` only starts a
                # comment at the start of the value or after whitespace, so the
                # branch pattern `main#backup` survives intact.
                function scan_scalar(text,   i, count, char, quote, buffer) {
                    count = length(text)
                    quote = ""
                    buffer = ""
                    for (i = 1; i <= count; i++) {
                        char = substr(text, i, 1)
                        if (quote != "") {
                            if (quote == "\"" && char == "\\") {
                                i++
                                buffer = buffer substr(text, i, 1)
                            } else if (char == quote) {
                                quote = ""
                            } else {
                                buffer = buffer char
                            }
                            continue
                        }
                        if (char == "\"" || char == "\047") {
                            quote = char
                            continue
                        }
                        if (char == "#" &&
                            (i == 1 || substr(text, i - 1, 1) ~ /[ \t]/)) {
                            break
                        }
                        buffer = buffer char
                    }
                    gsub(/^[ \t]+/, "", buffer)
                    gsub(/[ \t]+$/, "", buffer)
                    return buffer
                }
                function emit_item(key, item) {
                    gsub(/^[ \t]+/, "", item)
                    gsub(/[ \t]+$/, "", item)
                    if (item != "") {
                        print "V " key " " item
                    }
                }
                # Emit a key value: a flow sequence ([a, b]) or a scalar.
                # Returns 0 when the value is empty, i.e. a block list follows.
                # The sequence is walked character by character rather than
                # split on /,/ so a comma inside a quoted member stays part of
                # that one pattern ("main,release" is a single branch filter,
                # not two) and a `]` inside quotes does not end the sequence.
                function emit_value(key, value,   i, count, char, quote, buffer) {
                    gsub(/^[ \t]+/, "", value)
                    if (value !~ /^\[/) {
                        buffer = scan_scalar(value)
                        if (buffer != "") {
                            print "V " key " " buffer
                            return 1
                        }
                        return 0
                    }
                    count = length(value)
                    quote = ""
                    buffer = ""
                    for (i = 2; i <= count; i++) {
                        char = substr(value, i, 1)
                        if (quote != "") {
                            # Inside YAML double quotes a backslash escapes the
                            # next character, so `"a\\+"` is the three-character
                            # branch pattern `a\+`. Single quotes take the text
                            # verbatim.
                            if (quote == "\"" && char == "\\") {
                                i++
                                buffer = buffer substr(value, i, 1)
                            } else if (char == quote) {
                                quote = ""
                            } else {
                                buffer = buffer char
                            }
                            continue
                        }
                        if (char == "\"" || char == "\047") {
                            quote = char
                            continue
                        }
                        if (char == "]") {
                            break
                        }
                        if (char == ",") {
                            emit_item(key, buffer)
                            buffer = ""
                            continue
                        }
                        buffer = buffer char
                    }
                    emit_item(key, buffer)
                    return 1
                }
                BEGIN {
                    in_on = 0
                    event_indent = -1
                    in_protected = 0
                    pending = ""
                    pending_indent = -1
                }
                {
                    line = $0
                    if (line ~ /^[ \t]*#/ || line ~ /^[ \t]*$/) {
                        next
                    }
                    if (line ~ /^on:/) {
                        in_on = 1
                        event_indent = -1
                        in_protected = 0
                        pending = ""
                        # `on: [push, pull_request]` is a flow SEQUENCE and
                        # carries no filters; `on: {pull_request: {…}}` is a
                        # flow mapping that hides them all on one line.
                        rest = line
                        sub(/^on:/, "", rest)
                        gsub(/^[ \t]+|[ \t]+$/, "", rest)
                        if (rest ~ /^\{/) {
                            print "FLOWMAP"
                        }
                        next
                    }
                    if (!in_on) {
                        next
                    }
                    if (line ~ /^[^ ]/) {
                        in_on = 0
                        next
                    }
                    indent = indent_of(line)
                    if (event_indent < 0) {
                        event_indent = indent
                    }
                    if (indent <= event_indent) {
                        pending = ""
                        in_protected = 0
                        if (line ~ /^[ ]*["\047]?(pull_request|merge_group)["\047]?[ ]*:/) {
                            in_protected = 1
                            name = line
                            sub(/^[ ]*["\047]?/, "", name)
                            sub(/["\047]?[ ]*:.*$/, "", name)
                            print "EVENT " name
                            rest = line
                            sub(/^[^:]*:/, "", rest)
                            sub(/[ \t]*#.*$/, "", rest)
                            gsub(/^[ \t]+|[ \t]+$/, "", rest)
                            # A block event body is empty here; anything else
                            # (`pull_request: {branches: main}`) is unreadable.
                            if (rest != "") {
                                print "UNPARSED"
                            }
                        }
                        next
                    }
                    if (!in_protected) {
                        next
                    }
                    if (pending != "" && indent > pending_indent && line ~ /^[ ]*-[ ]*/) {
                        item = line
                        sub(/^[ ]*-[ ]*/, "", item)
                        item = scan_scalar(item)
                        if (item != "") {
                            print "V " pending " " item
                        }
                        next
                    }
                    pending = ""
                    if (line !~ /^[ ]*["\047]?[A-Za-z0-9_-]+["\047]?[ ]*:/) {
                        print "UNPARSED"
                        next
                    }
                    key = line
                    sub(/^[ ]*["\047]?/, "", key)
                    sub(/["\047]?[ ]*:.*$/, "", key)
                    print "K " key
                    rest = line
                    sub(/^[^:]*:/, "", rest)
                    if (!emit_value(key, rest)) {
                        pending = key
                        pending_indent = indent
                    }
                }
                END { print "EVENT --end--" }
            ' "$workflow"
        )"
        [ -z "$reason" ] || printf '%s\n' "$reason"
    }
    ruleset_job_is_result_gated() {
        local context="$1" workflow_file
        for workflow_file in .github/workflows/*.y*ml; do
            [ -f "$workflow_file" ] || continue
            # Bind gating to a workflow that actually reports on protected
            # events — a stale dispatch-only file containing a gated job must
            # not vouch for an echo-only job in the reporting workflow.
            workflow_reports_on_protected_events "$workflow_file" || continue
            if awk -v target="$context" '
                function finalize() {
                    if ((key_match || name_match) && has_needs && gated && always) ok = 1
                }
                BEGIN { in_jobs = 0; ok = 0 }
                {
                    line = $0
                    sub(/#.*$/, "", line)
                }
                line ~ /^jobs:[ ]*$/ { in_jobs = 1; next }
                in_jobs && line ~ /^[A-Za-z_-]+:/ { finalize(); in_jobs = 0 }
                in_jobs && line ~ /^  [A-Za-z0-9_-]+:[ ]*$/ {
                    finalize()
                    key_match = (line ~ ("^  " target ":[ ]*$"))
                    name_match = 0
                    has_needs = 0
                    gated = 0
                    always = 0
                    next
                }
                in_jobs && line ~ ("^    name:[ ]*[\"\047]?" target "[\"\047]?[ ]*$") { name_match = 1 }
                in_jobs && line ~ /^    needs:/ { has_needs = 1 }
                in_jobs && line ~ /always\(\)/ { always = 1 }
                in_jobs && (line ~ /needs\.[A-Za-z0-9_-]+\.result/ || line ~ /verify-ci-results\.sh/) { gated = 1 }
                END {
                    finalize()
                    exit(ok ? 0 : 1)
                }
            ' "$workflow_file"; then
                return 0
            fi
        done
        return 1
    }
    require_result_gated_substitute() {
        local context="$1"
        if ! ruleset_job_is_result_gated "$context"; then
            err "$ruleset_file accepts '$context' in place of a template aggregate, but that job is not result-gated (if: always() + needs: + needs.<leaf>.result or verify-ci-results.sh) — GitHub counts a skipped required check as successful, so a non-always() or echo-only rollup launders failing leaves"
        fi
    }
    # Coverage, not exact match: a split-workflow repo satisfies the template's
    # `verify` with its per-workflow rollups (`build-verify` + `validate-verify`)
    # and `security` with `security-verify`. Extra required contexts are fine
    # only when a workflow actually defines that aggregate job — a context no
    # workflow reports wedges every PR.
    if has_ruleset_context verify; then
        # The canonical verify context is an aggregate by design — an
        # echo-only job named verify outside the audited build workflow must
        # not satisfy it. (Canonical security is deliberately NOT gated: the
        # template's security job is a working leaf, not a rollup.)
        require_result_gated_substitute verify
    elif has_ruleset_context build-verify && has_ruleset_context validate-verify; then
        require_result_gated_substitute build-verify
        require_result_gated_substitute validate-verify
    else
        err "$ruleset_file must require 'verify' (or the split 'build-verify' + 'validate-verify'); found: $(printf '%s' "$ruleset_contexts" | tr '\n' ' ')"
    fi
    if ! has_ruleset_context security; then
        if has_ruleset_context security-verify; then
            require_result_gated_substitute security-verify
        else
            err "$ruleset_file must require 'security' (or the split 'security-verify'); found: $(printf '%s' "$ruleset_contexts" | tr '\n' ' ')"
        fi
    fi
    if [ "$has_terraform" = true ] && ! has_ruleset_context terraform-verify; then
        err "$ruleset_file must require 'terraform-verify' when Terraform is present"
    fi
    if [ "$has_terraform" = false ] && has_ruleset_context terraform-verify; then
        err "$ruleset_file requires 'terraform-verify' but the repo has no Terraform — the stale check can stop reporting and wedge every PR"
    fi
    if [ "$has_terraform" = true ] && has_ruleset_context terraform-verify; then
        # terraform-verify is an aggregate in the standard (mode-audit: emits
        # on push/pull_request/merge_group/workflow_dispatch for the trusted
        # main-apply and manual paths) — existence is not enough.
        require_result_gated_substitute terraform-verify
        terraform_events_ok=false
        for workflow_file in .github/workflows/*.y*ml; do
            [ -f "$workflow_file" ] || continue
            grep -qE "^  terraform-verify:[ ]*(#.*)?$" "$workflow_file" || continue
            if awk '
                BEGIN { in_on = 0; pr = 0; mg = 0; pu = 0; wd = 0 }
                {
                    line = $0
                    sub(/#.*$/, "", line)
                }
                line ~ /^on:/ {
                    in_on = 1
                    if (line ~ /pull_request([^_a-z]|$)/) pr = 1
                    if (line ~ /merge_group([^_a-z]|$)/) mg = 1
                    if (line ~ /push([^_a-z]|$)/) pu = 1
                    if (line ~ /workflow_dispatch([^_a-z]|$)/) wd = 1
                    next
                }
                in_on && line ~ /^[A-Za-z_-]+:/ { in_on = 0 }
                in_on {
                    if (line ~ /pull_request([^_a-z]|$)/) pr = 1
                    if (line ~ /merge_group([^_a-z]|$)/) mg = 1
                    if (line ~ /push([^_a-z]|$)/) pu = 1
                    if (line ~ /workflow_dispatch([^_a-z]|$)/) wd = 1
                }
                END { exit(pr && mg && pu && wd ? 0 : 1) }
            ' "$workflow_file"; then
                terraform_events_ok=true
                break
            fi
        done
        if [ "$terraform_events_ok" = false ]; then
            err "terraform-verify must emit on push, pull_request, merge_group, and workflow_dispatch (trusted main apply + manual paths) — its workflow is missing one of those triggers"
        fi
    fi
    if [ "$codeql_required" = false ] && has_ruleset_context codeql-verify; then
        err "$ruleset_file requires 'codeql-verify' but use_codeql is off — the check would never report and wedge every PR"
    fi
    if [ "$codeql_required" = true ] && ! has_ruleset_context codeql-verify; then
        err "$ruleset_file must require 'codeql-verify' when use_codeql is on"
    fi
    while IFS= read -r ruleset_context; do
        [ -n "$ruleset_context" ] || continue
        context_defined=false
        context_reports=false
        context_filter_reason=""
        context_filtered_workflow=""
        for workflow_file in .github/workflows/*.y*ml; do
            [ -f "$workflow_file" ] || continue
            # GitHub reports a check under the job-level name: when present,
            # falling back to the job key — accept either. The name: match is
            # anchored to the job level (exactly 4-space indent, no list dash)
            # so a step's `- name:` cannot masquerade as a defined context.
            if ! grep -qE "^  ${ruleset_context}:[ ]*(#.*)?$" "$workflow_file" &&
                ! grep -qE "^    name:[[:space:]]*[\"']?${ruleset_context}[\"']?[[:space:]]*(#.*)?$" "$workflow_file"; then
                continue
            fi
            context_defined=true
            workflow_reports_on_protected_events "$workflow_file" || continue
            workflow_filter_reason="$(
                protected_event_filter_reason "$workflow_file" "$protected_branches"
            )"
            if [ -n "$workflow_filter_reason" ]; then
                # Keep looking: another workflow may define the same context
                # without filters. Remember the first filtered one to name it.
                if [ -z "$context_filtered_workflow" ]; then
                    context_filtered_workflow="$workflow_file"
                    context_filter_reason="$workflow_filter_reason"
                fi
                continue
            fi
            context_reports=true
            break
        done
        if [ "$context_defined" = false ]; then
            err "$ruleset_file requires check '$ruleset_context' but no workflow defines that job — it would never report and wedge every PR"
        elif [ "$context_reports" = true ]; then
            :
        elif [ -n "$context_filtered_workflow" ]; then
            err "$ruleset_file requires check '$ruleset_context' but $context_filtered_workflow cannot always report: $context_filter_reason — the check never reports on a filtered-out run and wedges that merge; make the workflow always start on the protected events and gate the work on an internal change-detection job"
        else
            err "$ruleset_file requires check '$ruleset_context' but its workflow never triggers on pull_request/merge_group — it would never report and wedge every protected merge"
        fi
    done <<<"$ruleset_contexts"
fi

# ── 3f. CodeQL selection, result truth table, and live capability ──
# CodeQL is not universal merely because a repo contains Node/Python. The Copier
# answer selects it, FULL_SECURITY_SCAN starts it, and GitHub must accept SARIF.
# Public repositories have Code Security by default; private/internal repos need
# the live feature enabled. The API check below is GET-only. Missing permissions
# produce a manual-audit warning, never a guessed claim of coverage.
codeql_workflow=""
for candidate in .github/workflows/codeql.yml .github/workflows/codeql.yaml; do
    if [ -f "$candidate" ]; then
        codeql_workflow="$candidate"
        break
    fi
done

if [ -n "$codeql_workflow" ] && ! awk '
    function record_event(value) {
        gsub(/^[[:space:]]+/, "", value)
        gsub(/[[:space:]]+$/, "", value)
        if (value == "pull_request") {
            has_pull_request = 1
        } else if (value == "merge_group") {
            has_merge_group = 1
        }
    }
    function record_inline_events(value, count, events, i) {
        sub(/^on:[ ]*\[/, "", value)
        sub(/\].*$/, "", value)
        count = split(value, events, /[ ]*,[ ]*/)
        for (i = 1; i <= count; i++) {
            record_event(events[i])
        }
    }
    BEGIN {
        in_events = 0
        has_pull_request = 0
        has_merge_group = 0
    }
    /^on:[ ]*\[/ {
        record_inline_events($0)
        in_events = 0
        next
    }
    /^on:[ ]*(#.*)?$/ {
        in_events = 1
        next
    }
    in_events && /^[^[:space:]#]/ {
        in_events = 0
    }
    in_events && /^  pull_request:/ {
        has_pull_request = 1
    }
    in_events && /^  merge_group:/ {
        has_merge_group = 1
    }
    in_events && /^  -[ ]*(pull_request|merge_group)([ ]*(#.*)?)?$/ {
        event = $0
        sub(/^  -[ ]*/, "", event)
        sub(/[ ]*#.*/, "", event)
        record_event(event)
    }
    END {
        exit(has_pull_request && has_merge_group ? 0 : 1)
    }
' "$codeql_workflow"; then
    err "$codeql_workflow must trigger on pull_request and merge_group so required codeql-verify checks are reported"
fi

if [ -n "$codeql_workflow" ] && awk '
    function indentation(value) {
        match(value, /^[ ]*/)
        return RLENGTH
    }
    function finish_step() {
        if (step_is_analyze && step_continues) {
            fail_open = 1
        }
        step_is_analyze = 0
        step_continues = 0
    }
    BEGIN {
        in_analyze_job = 0
        job_indent = -1
        steps_indent = -1
        step_indent = -1
        fail_open = 0
    }
    {
        line = $0
        normalized = tolower(line)
        if (line ~ /^[[:space:]]*(#|$)/) {
            next
        }
        indent = indentation(line)
        if (!in_analyze_job) {
            if (line ~ /^[ ]*analyze:[ ]*(#.*)?$/) {
                in_analyze_job = 1
                job_indent = indent
            }
            next
        }
        if (indent <= job_indent) {
            finish_step()
            in_analyze_job = 0
            next
        }
        if (indent == job_indent + 2 &&
            normalized ~ /^[ ]*continue-on-error:[ ]*true([ ]|$)/) {
            fail_open = 1
        }
        if (indent == job_indent + 2 && line ~ /^[ ]*steps:[ ]*$/) {
            steps_indent = indent
            next
        }
        if (steps_indent >= 0) {
            if (indent == steps_indent + 2 && line ~ /^[ ]*-[ ]/) {
                finish_step()
                step_indent = indent
            }
            if (step_indent >= 0) {
                if (normalized ~ /uses:[ ]*github\/codeql-action\/analyze@/) {
                    step_is_analyze = 1
                }
                if (normalized ~ /^[ ]*continue-on-error:[ ]*true([ ]|$)/) {
                    step_continues = 1
                }
            }
        }
    }
    END {
        finish_step()
        exit(fail_open ? 0 : 1)
    }
' "$codeql_workflow"; then
    err "$codeql_workflow lets the CodeQL analyze job/action fail via 'continue-on-error: true'"
fi

if [ -n "$codeql_workflow" ] && ! awk '
    BEGIN {
        in_analyze = 0
        scan_gate = 0
        trusted_event = 0
        trusted_repo = 0
    }
    {
        line = $0
        if (!in_analyze) {
            if (line ~ /^  analyze:[ ]*(#.*)?$/) {
                in_analyze = 1
            }
            next
        }
        if (line ~ /^  [A-Za-z0-9_-]+:[ ]*(#.*)?$/) {
            in_analyze = 0
            next
        }
        if (index(line, "vars.FULL_SECURITY_SCAN ==") && index(line, "true")) {
            scan_gate = 1
        }
        if (index(line, "github.event_name !=") && index(line, "pull_request")) {
            trusted_event = 1
        }
        if (index(line, "head.repo.full_name == github.repository")) {
            trusted_repo = 1
        }
    }
    END {
        exit(scan_gate && trusted_event && trusted_repo ? 0 : 1)
    }
' "$codeql_workflow"; then
    err "$codeql_workflow analyze job must require FULL_SECURITY_SCAN=true and a trusted same-repository event"
fi

if [ -n "$codeql_workflow" ]; then
    for workflow_contract in \
        'EXPECTED_RESULT:' \
        'vars.FULL_SECURITY_SCAN' \
        'github.event.pull_request.head.repo.full_name != github.repository' \
        'ANALYZE_RESULT:' \
        'needs.analyze.result' \
        'run: ./scripts/verify-ci-results.sh'; do
        if ! grep -qF "$workflow_contract" "$codeql_workflow"; then
            err "$codeql_workflow does not wire the aggregate result contract: $workflow_contract"
        fi
    done

    # A fork PR must not make a potentially self-hosted aggregate runner check
    # out and execute fork-controlled repository code. Trusted events may run the
    # tested helper; forks use a tiny workflow-defined diagnostic instead.
    if ! awk '
        function reset_step() {
            is_checkout = 0
            is_helper = 0
            is_fork_check = 0
            trusted_event = 0
            trusted_repo = 0
            fork_event = 0
            fork_repo = 0
            validates_skip = 0
            executes_repo_code = 0
        }
        function finish_step() {
            if (is_checkout && trusted_event && trusted_repo) {
                safe_checkout = 1
            }
            if (is_helper && trusted_event && trusted_repo) {
                safe_helper = 1
            }
            if (is_fork_check && fork_event && fork_repo && validates_skip &&
                !executes_repo_code) {
                safe_fork_check = 1
            }
            reset_step()
        }
        BEGIN {
            in_verify = 0
            in_step = 0
            safe_checkout = 0
            safe_helper = 0
            safe_fork_check = 0
            reset_step()
        }
        {
            line = $0
            if (!in_verify) {
                if (line ~ /^  codeql-verify:[ ]*(#.*)?$/) {
                    in_verify = 1
                }
                next
            }
            if (line ~ /^  [A-Za-z0-9_-]+:[ ]*(#.*)?$/) {
                finish_step()
                in_verify = 0
                next
            }
            if (line ~ /^      - /) {
                if (in_step) {
                    finish_step()
                }
                in_step = 1
            }
            if (!in_step || line ~ /^[[:space:]]*#/) {
                next
            }
            if (line ~ /uses:[ ]*actions\/checkout@/) {
                is_checkout = 1
            }
            if (line ~ /run:[ ]*\.\/scripts\/verify-ci-results\.sh/) {
                is_helper = 1
            }
            if (line ~ /name:[ ]*Check deliberate fork skip/) {
                is_fork_check = 1
            }
            if (index(line, "github.event_name !=") && index(line, "pull_request")) {
                trusted_event = 1
            }
            if (index(line, "head.repo.full_name == github.repository")) {
                trusted_repo = 1
            }
            if (index(line, "github.event_name ==") && index(line, "pull_request")) {
                fork_event = 1
            }
            if (index(line, "head.repo.full_name != github.repository")) {
                fork_repo = 1
            }
            if (index(line, "ANALYZE_RESULT") && index(line, "!=") &&
                index(line, "skipped")) {
                validates_skip = 1
            }
            if (is_fork_check &&
                (line ~ /uses:/ || line ~ /run:[ ]*(\.\/|bash |sh ).*scripts\// ||
                 line ~ /(^|[ ])\.\/scripts\//)) {
                executes_repo_code = 1
            }
        }
        END {
            if (in_step) {
                finish_step()
            }
            exit(safe_checkout && safe_helper && safe_fork_check ? 0 : 1)
        }
    ' "$codeql_workflow"; then
        err "$codeql_workflow must guard aggregate checkout/helper execution to trusted events and validate fork skips without repository code"
    fi

    # The Copier stack flags decide which languages can be rendered, but they do
    # not prove that a repository actually contains that first-party language.
    # Warn on source/matrix drift so an audit can choose the explicit language
    # set rather than silently scanning only tooling or missing real code.
    first_party_source_files="$(
        printf '%s\n' "$repo_files" |
            grep -vE '(^|/)(\.git|\.github|\.claude|\.codex|\.agents|node_modules|\.venv|\.terraform|vendor|dist|build|coverage|generated|_generated)/' |
            grep -vE '(^|/)(astro|commitlint|eslint|knip|playwright|postcss|prettier|tailwind|vite|vitest|webpack)\.config\.(cjs|mjs|js|jsx|ts|tsx)$' |
            grep -vE '(^|/)scripts/summarize-gitleaks\.mjs$' || true
    )"
    has_javascript_source=false
    has_python_source=false
    if printf '%s\n' "$first_party_source_files" |
        grep -qE '\.(cjs|mjs|js|jsx|cts|mts|ts|tsx)$'; then
        has_javascript_source=true
    fi
    if printf '%s\n' "$first_party_source_files" | grep -qE '\.py$'; then
        has_python_source=true
    fi

    matrix_has_javascript=false
    matrix_has_python=false
    if grep -qF 'javascript-typescript' "$codeql_workflow"; then
        matrix_has_javascript=true
    fi
    if grep -qE '(^|[^[:alnum:]_-])python([^[:alnum:]_-]|$)' "$codeql_workflow"; then
        matrix_has_python=true
    fi

    if [ "$matrix_has_javascript" = true ] && [ "$has_javascript_source" = false ]; then
        echo "WARN: CodeQL matrix includes javascript-typescript but no first-party JS/TS source was found." >&2
    elif [ "$matrix_has_javascript" = false ] && [ "$has_javascript_source" = true ]; then
        echo "WARN: first-party JS/TS source exists but CodeQL omits javascript-typescript." >&2
    fi
    if [ "$matrix_has_python" = true ] && [ "$has_python_source" = false ]; then
        echo "WARN: CodeQL matrix includes python but no first-party Python source was found." >&2
    elif [ "$matrix_has_python" = false ] && [ "$has_python_source" = true ]; then
        echo "WARN: first-party Python source exists but CodeQL omits python." >&2
    fi
fi

if [ -n "$codeql_workflow" ]; then
    echo "INFO: CodeQL workflow presence and FULL_SECURITY_SCAN are configuration only;" >&2
    echo "      verify a successful analysis/SARIF upload before claiming coverage." >&2

    codeql_nwo="$(github_remote_nwo)"

    if [ -n "$codeql_nwo" ] && have gh; then
        if repo_security="$(gh api "repos/$codeql_nwo" \
            --jq '[.visibility, (.security_and_analysis.code_security.status // "unknown")] | @tsv' \
            2>/dev/null)"; then
            IFS=$'\t' read -r visibility code_security <<<"$repo_security"
            [ -n "$code_security" ] || code_security="unknown"
            case "$visibility" in
            public)
                echo "INFO: $codeql_nwo is public; GitHub Code Security is available by default." >&2
                ;;
            private | internal)
                case "$code_security" in
                enabled)
                    echo "INFO: $codeql_nwo reports GitHub Code Security enabled." >&2
                    ;;
                disabled)
                    err "CodeQL workflow exists but $codeql_nwo is $visibility with GitHub Code Security disabled; enable it first or select use_codeql=false and remove the workflow/coverage claims"
                    ;;
                *)
                    echo "WARN: $codeql_nwo is $visibility but Code Security capability is '$code_security' —" >&2
                    echo "      verify Settings > Code security manually; do not infer CodeQL coverage." >&2
                    ;;
                esac
                ;;
            *)
                echo "WARN: could not classify repository visibility for $codeql_nwo —" >&2
                echo "      verify Code Security capability manually; do not infer coverage." >&2
                ;;
            esac
        else
            echo "WARN: read-only Code Security API audit failed for $codeql_nwo —" >&2
            echo "      verify Settings > Code security manually; do not infer CodeQL coverage." >&2
        fi
    else
        echo "WARN: no queryable GitHub origin/gh CLI for the CodeQL capability audit —" >&2
        echo "      verify Code Security manually; do not infer coverage from workflow files." >&2
    fi
fi

case "$use_codeql_answer" in
true | yes)
    if [ -z "$codeql_workflow" ]; then
        err "use_codeql=true but no .github/workflows/codeql.yml or codeql.yaml exists"
    fi
    if [ -f docs/architecture/security.md ] &&
        grep -qF 'CodeQL is deliberately omitted' docs/architecture/security.md; then
        err "use_codeql=true but security docs still say CodeQL is deliberately omitted"
    fi
    ;;
false | no)
    if [ -n "$codeql_workflow" ]; then
        err "use_codeql=false but $codeql_workflow still exists"
    fi
    for taskfile in Taskfile.yml Taskfile.yaml; do
        if [ -f "$taskfile" ] && grep -qF 'FULL_SECURITY_SCAN' "$taskfile"; then
            err "use_codeql=false but $taskfile still configures FULL_SECURITY_SCAN"
        fi
    done
    if [ -f README.md ] && grep -qE 'actions/workflows/codeql\.ya?ml' README.md; then
        err "use_codeql=false but README.md still advertises the CodeQL workflow"
    fi
    if [ -f docs/architecture/security.md ] &&
        ! grep -qF 'CodeQL is deliberately omitted' docs/architecture/security.md; then
        err "use_codeql=false but security docs do not explicitly document the SAST gap"
    fi
    ;;
"")
    if [ -n "$codeql_workflow" ]; then
        echo "WARN: CodeQL workflow exists but .copier-answers.yml has no explicit use_codeql answer —" >&2
        echo "      review stack + live capability on the next template update." >&2
    fi
    ;;
*)
    err "invalid use_codeql value in .copier-answers.yml: $use_codeql_answer"
    ;;
esac

# ── 4. No unrendered template markers leaked into the repo ──────────
# harmon-init uses CUSTOM jinja delimiters ([[ var ]], [% block %]). Legitimate
# look-alikes must NOT trip this: go-task uses {{.VAR}} (dot, no space), GitHub
# Actions uses ${{ }}, bash uses [[ -n "$x" ]] / array[idx], and terminfo uses
# \E[%p1%d — none of which have the "<delim><optional-ws-dash><space><token>"
# shape we match. We anchor variable markers on the copier answer-variable name
# stems (kept in sync with copier.yml; every question variable must be covered
# by one stem) so a real leak ([[ git_init ]], {{ author_full_name }}) is caught
# while bash bare-word tests ([[ true ]]) are not. Block markers anchor on the
# jinja keyword set, including the raw/endraw the template actually emits and the
# [%- whitespace-control form used in LICENSE.jinja.
#
# Enumerate files the way gitleaks (step 5) does — honoring .gitignore — so
# vendored dependencies in gitignored dirs cannot false-trip the scan: .venv
# ships Ansible's own .j2/jinja templates and plugin docs, .terraform caches
# provider source, node_modules is third-party. `git ls-files --cached --others
# --exclude-standard` lists tracked AND untracked-but-not-ignored files, so a
# freshly rendered, not-yet-staged repo is still fully checked. Fall back to a
# recursive grep (with explicit excludes) when the target is not a git work tree.
varpfx='project_|author_|github_|organization|repo_url|ci_runner|include_|use_|devcontainer|git_init|bunch_add|obsidian_|run_task_install|projects_directory|bunches_directory|license|current_|country|state'
blockkw='if|for|set|else|elif|endif|endfor|endset|raw|endraw|macro|endmacro|block|endblock|include|extends|with|endwith|filter|endfilter'
marker_re="\[\[-? ($varpfx)|\{\{-? ($varpfx)|\[%-? ($blockkw) "
# Exclude *.j2 / *.jinja from the scan: those are legitimately full of standard
# Jinja ({{ x }} / {% x %}) — Ansible templates, nginx configs, etc. — and the
# {{ <stem> }} branch of marker_re can't tell `{{ github_runner_image }}` (a real
# Ansible var) from a copier leak. Copier's own delimiters are [[ ]] / [% %], so
# dropping these files loses no real-leak coverage. Likewise drop anything under
# a `skills/` dir: agent-skill references/assets legitimately DOCUMENT copier's
# [[ ]] / [% %] delimiters as examples (the standardize-repo skill itself does),
# so they would false-positive on the repo that HOSTS the skill — cf. the
# .claude/** exclude in the markdownlint config.
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    leaks=$(git ls-files --cached --others --exclude-standard -z 2>/dev/null |
        xargs -0 grep -IlE "$marker_re" 2>/dev/null |
        grep -vE '\.(j2|jinja)$|(^|/)skills/' || true)
else
    leaks=$(grep -rIlE "$marker_re" \
        --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=.venv \
        --exclude-dir=.terraform --exclude-dir=.task --exclude-dir=.worktrees \
        --exclude-dir=dist --exclude-dir=skills --exclude='*.j2' --exclude='*.jinja' . 2>/dev/null || true)
fi
if [ -n "$leaks" ]; then
    err "unrendered template markers found in:"
    # Print one path per line for readability; indented so it groups under the FAIL.
    echo "$leaks" | sed 's/^/    /' >&2
fi

# ── 5. No secrets committed/sitting in the tree (gitleaks) ──────────
# Matches test-template.sh: gitleaks is best-effort locally, but if it is
# installed a finding is a hard failure.
if have gitleaks; then
    if ! gitleaks detect --no-banner --redact --source .; then
        err "gitleaks reported findings"
    fi
else
    echo "WARN: gitleaks not installed — skipping secrets scan"
fi

# ── 6. Template-owned file content drift (advisory) ─────────────────
# Renders harmon-init from this repo's .copier-answers.yml and diffs the
# template-owned file set (see diff-template.sh / template-owned-files.txt).
# Advisory here — some drift is legitimate local customization, and the
# update/audit modes review and reconcile it. After a `copier update` it should
# show only intentional customizations.
diff_tool="$(dirname "$0")/diff-template.sh"
if [ -f .copier-answers.yml ] && [ -x "$diff_tool" ] && have copier && have yq; then
    if ! "$diff_tool" . >/dev/null 2>&1; then
        echo "WARN: template-owned files differ from a fresh harmon-init render —" >&2
        echo "      review with $diff_tool --show . and reconcile (mode-update.md /" >&2
        echo "      mode-audit.md drift class K). Legit customizations are expected." >&2
    fi
fi

# ── 7. CODEOWNERS must not lose owners on adopt (access-control regression) ─
# CODEOWNERS is rendered from the single `code_owner` answer (`* @owner`), so a
# Path-B adopt over a repo with MORE owners (or a team) silently drops them — an
# access-control change that must be surfaced and confirmed, never auto-applied.
# harmon-init also freezes CODEOWNERS via _skip_if_exists; this is the belt to
# that suspenders (and catches a hand-overwritten CODEOWNERS too). Compare the
# @owners in the pre-adopt CODEOWNERS (on `main`) against the current one. An
# intentional migration is acknowledged only with an exact
# `--ack-codeowner-change @old=@new` mapping: @old must truly be dropped and
# @new must be present now. Extra/stale mappings fail, so this cannot become a
# blanket bypass. Skip cleanly only when there is no main or not a git tree.
co=".github/CODEOWNERS"
codeowners_compared=0
if git rev-parse --is-inside-work-tree >/dev/null 2>&1 &&
    git cat-file -e "main:$co" 2>/dev/null; then
    codeowners_compared=1
    # LC_ALL=C on the producers AND the consumer: `comm` re-derives the ordering
    # its inputs must already be in, so both sides have to agree on collation,
    # and owner tokens carry `_`/`-`/`/`, which UTF-8 locales order differently
    # than byte value does.
    before="$(git show "main:$co" 2>/dev/null | grep -oE '@[A-Za-z0-9_/-]+' | LC_ALL=C sort -u)"
    if [ -f "$co" ]; then
        after="$(grep -oE '@[A-Za-z0-9_/-]+' "$co" 2>/dev/null | LC_ALL=C sort -u)"
    else
        after=""
    fi
    dropped="$(LC_ALL=C comm -23 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | grep -v '^$' || true)"
    acknowledged_old=""
    if [ "$codeowner_ack_count" -gt 0 ]; then
        for ack in "${codeowner_acks[@]}"; do
            old="${ack%%=*}"
            new="${ack#*=}"
            if ! printf '%s\n' "$before" | grep -qxF "$old"; then
                err "CODEOWNERS acknowledgement is stale: $old was not present on main"
                continue
            fi
            if ! printf '%s\n' "$dropped" | grep -qxF "$old"; then
                err "CODEOWNERS acknowledgement is extra: $old was not actually dropped"
                continue
            fi
            if ! printf '%s\n' "$after" | grep -qxF "$new"; then
                err "CODEOWNERS acknowledgement is not materialized: replacement $new is absent"
                continue
            fi
            if printf '%s' "$acknowledged_old" | grep -qxF "$old"; then
                err "CODEOWNERS owner acknowledged more than once: $old"
                continue
            fi
            acknowledged_old="${acknowledged_old}${old}
"
            echo "ACK: intentional CODEOWNERS migration $old -> $new"
        done
    fi

    unacknowledged=""
    for owner in $dropped; do
        if ! printf '%s' "$acknowledged_old" | grep -qxF "$owner"; then
            unacknowledged="${unacknowledged}${owner}
"
        fi
    done
    if [ -n "$unacknowledged" ]; then
        err "CODEOWNERS dropped owner(s) present on main without an exact migration acknowledgement: $(printf '%s ' $unacknowledged)— restore them, or repeat --ack-codeowner-change @old=@new for each intentional migration after confirming it with the user."
    fi
fi
if [ "$codeowner_ack_count" -gt 0 ] && [ "$codeowners_compared" -eq 0 ]; then
    err "CODEOWNERS acknowledgement supplied, but main has no comparable .github/CODEOWNERS"
fi

# ── Result ──────────────────────────────────────────────────────────
if [ "$fail" -ne 0 ]; then
    echo "verify-applied: FAILED — checks that did not pass:" >&2
    printf '%s' "$fail_msgs" >&2
    exit 1
fi
echo "verify-applied: PASS"
