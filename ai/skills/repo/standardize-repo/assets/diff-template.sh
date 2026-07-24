#!/usr/bin/env bash
# diff-template.sh — show how a repo's template-owned files differ from a fresh
# harmon-init render, so the agent can find missed template improvements.
#
# Renders harmon-init using the TARGET repo's own .copier-answers.yml, then runs
# two checks against that render:
#   • DRIFT   — content differences in the curated template-owned-files.txt set
#               (mapping .yml<->.yaml). A listed file may differ because the repo
#               legitimately customized it (terraform tasks, a custom status
#               section) OR because it's missing template improvements (the
#               recurring status.sh / lint-hygiene / bootstrap class).
#   • MODE    — executable-bit differences in that same curated set. Copier can
#               preserve content while a manual copy silently drops `+x`, leaving
#               a generated script present but unusable.
#   • MISSING — template files the repo lacks ENTIRELY. This scan is
#               manifest-INDEPENDENT (it walks the whole render), because the
#               manifest is hand-maintained and lags the template — a file added
#               after the last manifest edit, or dropped by a hand-reconciled
#               `copier update`, would otherwise slip through silently. (.gitkeep
#               dir-stubs are listed as benign ABSENT, not flagged as drift.)
#               A tracked file deleted only from the working tree is compared
#               from the index, so an unstaged/transient delete is not reported
#               as drift; once the deletion is staged it is real MISSING.
# This is a REVIEW AID for apply/update/audit, not a pass/fail gate. For each
# DRIFT/MISSING, inspect and reconcile — pull template improvements in via
# `copier update`, keep legit local customizations.
#
# Usage: diff-template.sh [-v|--show] [TARGET_DIR]   (default target: .)
#        Flags and the target dir may appear in any order.
# Env:   HARMON_INIT   template checkout (default: ~/git/harmon-init)
#
# Exit: 0 = no drift, 1 = drift found (for callers that want a signal), 2 = setup error.
# Portable to macOS bash 3.2 (no mapfile, no grep -P, no associative arrays).
set -euo pipefail

show=0
target=""
while [ $# -gt 0 ]; do
    case "$1" in
    -v | --show) show=1 ;;
    -*)
        echo "FAIL: unknown argument '$1' (usage: diff-template.sh [-v|--show] [TARGET_DIR])" >&2
        exit 2
        ;;
    *)
        if [ -n "$target" ]; then
            echo "FAIL: more than one target dir given ('$target' and '$1')" >&2
            exit 2
        fi
        target="$1"
        ;;
    esac
    shift
done
[ -n "$target" ] || target="."
template="${HARMON_INIT:-$HOME/git/harmon-init}"
here="$(cd "$(dirname "$0")" && pwd)"
manifest="$here/template-owned-files.txt"

have() { command -v "$1" >/dev/null 2>&1; }
for t in copier yq; do
    have "$t" || {
        echo "FAIL: required tool '$t' is not installed" >&2
        exit 2
    }
done
[ -d "$template" ] || {
    echo "FAIL: template not found at $template (set HARMON_INIT)" >&2
    exit 2
}
[ -f "$manifest" ] || {
    echo "FAIL: manifest not found at $manifest" >&2
    exit 2
}

target="$(cd "$target" && pwd)"
answers="$target/.copier-answers.yml"
[ -f "$answers" ] || {
    echo "FAIL: $target has no .copier-answers.yml — not a template-linked repo" >&2
    exit 2
}

workdir="$(mktemp -d -t harmon-init-render-XXXXXX)"
trap 'rm -rf "$workdir"' EXIT
render="$workdir/render"
index_root="$workdir/index-snapshot"

# Reconstruct the recorded answers as a --data-file (skip copier's _ keys and
# nulls). A YAML data file — not per-key `--data k=v` strings — is required to
# round-trip non-scalar answers: the `skill_categories` multiselect is a LIST,
# and stringifying it as `--data` emits broken `k=- item` lines that fail the
# render for every repo whose answers record it (_commit >= v3.23.0).
datafile="$workdir/answers-data.yml"
yq 'with_entries(select((.key | test("^_") | not) and (.value != null)))' "$answers" >"$datafile"

# The fleet policy treats a legacy answer file that predates use_coderabbit as
# opted out. Its recorded template baseline may still render .coderabbit.yaml
# unconditionally, so apply that effective answer when interpreting drift
# rather than telling an agent to restore the intentionally removed file.
effective_use_coderabbit="$(yq -r '.use_coderabbit // false' "$answers" 2>/dev/null || echo false)"
case "$effective_use_coderabbit" in
true | false) ;;
*)
    echo "FAIL: use_coderabbit must be true or false in $answers" >&2
    exit 2
    ;;
esac

# Force every side-effect off in the throwaway render (`--data` wins over
# `--data-file`).
data_args=(
    --data git_init=false
    --data github_remote_create=false
    --data github_release_init=false
    --data run_task_install=false
    --data bunch_add=false
    --data obsidian_project_add=false
)

# Render at the version the repo is PINNED to (_commit), not the template's HEAD.
# Drift should mean "what this repo customized relative to its own template
# baseline" — rendering at HEAD instead conflates that with template changes the
# repo simply hasn't pulled yet (which is what made early audits look huge).
# Falls back to HEAD if _commit is somehow absent.
src_ref="$(yq -r '._commit // "HEAD"' "$answers" 2>/dev/null || echo HEAD)"
[ -n "$src_ref" ] || src_ref=HEAD

copier copy "$template" "$render" --vcs-ref="$src_ref" --trust --defaults \
    --data-file "$datafile" "${data_args[@]}" >/dev/null 2>&1 || {
    echo "FAIL: copier render failed (template ref: $src_ref)" >&2
    exit 2
}

# Materialize an index copy when a tracked file is absent only from the working
# tree. This makes audit output stable while an editor/tool has a transient
# unstaged deletion. A staged deletion has no index entry and remains MISSING.
index_variant() {
    p="$1"
    git -C "$target" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
    git -C "$target" cat-file -e ":$p" 2>/dev/null || return 1
    out="$index_root/$p"
    mkdir -p "$(dirname "$out")"
    git -C "$target" show ":$p" >"$out" 2>/dev/null || return 1
    mode="$(git -C "$target" ls-files -s -- "$p" | awk 'NR == 1 { print $1 }')"
    [ "$mode" != "100755" ] || chmod +x "$out"
    echo "$out"
}

resolve_variant() {
    p="$1"
    if [ -f "$target/$p" ]; then
        echo "$target/$p"
        return 0
    fi
    if iv="$(index_variant "$p")"; then
        echo "$iv"
        return 0
    fi
    return 1
}

# Resolve a repo file path, honoring .yml<->.yaml (each tool's own convention).
repo_variant() {
    p="$1"
    if rv="$(resolve_variant "$p")"; then
        echo "$rv"
        return
    fi
    case "$p" in
    *.yml) rv="$(resolve_variant "${p%.yml}.yaml")" && {
        echo "$rv"
        return
    } ;;
    *.yaml) rv="$(resolve_variant "${p%.yaml}.yml")" && {
        echo "$rv"
        return
    } ;;
    esac
    echo ""
}

drift=0
checked=0
drift_count=0
mode_count=0
missing_count=0
while IFS= read -r f; do
    case "$f" in '' | \#*) continue ;; esac
    if [ "$f" = ".coderabbit.yaml" ] && [ "$effective_use_coderabbit" = "false" ]; then
        checked=$((checked + 1))
        rv="$(repo_variant "$f")"
        if [ -n "$rv" ]; then
            echo "DRIFT    .coderabbit.yaml  (CodeRabbit is disabled by the effective answer)"
            drift=1
            drift_count=$((drift_count + 1))
        else
            echo "ABSENT   .coderabbit.yaml  (CodeRabbit disabled — expected)"
        fi
        continue
    fi
    [ -f "$render/$f" ] || continue # conditional file not in this profile
    checked=$((checked + 1))
    rv="$(repo_variant "$f")"
    if [ -z "$rv" ]; then
        echo "MISSING  $f  (template ships it; repo doesn't)"
        drift=1
        missing_count=$((missing_count + 1))
        continue
    fi
    rv_display="${rv#"$target"/}"
    if [ "$rv_display" = "$rv" ]; then
        rv_display="${rv#"$index_root"/}"
    fi
    render_exec=0
    repo_exec=0
    [ -x "$render/$f" ] && render_exec=1
    [ -x "$rv" ] && repo_exec=1
    if [ "$render_exec" -ne "$repo_exec" ]; then
        if [ "$render_exec" -eq 1 ]; then
            mode_note="template is executable; repo is not"
        else
            mode_note="repo is executable; template is not"
        fi
        echo "MODE     $rv_display  ($mode_note)"
        drift=1
        mode_count=$((mode_count + 1))
    fi
    if ! diff -q "$render/$f" "$rv" >/dev/null 2>&1; then
        echo "DRIFT    $rv_display"
        drift=1
        drift_count=$((drift_count + 1))
        if [ "$show" -eq 1 ]; then
            # `diff` exits 1 when files differ (they always do here); `|| true`
            # keeps that from aborting the loop under `set -euo pipefail`, so
            # --show prints EVERY drifting file, not just the first.
            diff -u "$rv" "$render/$f" | sed 's/^/    /' || true
        fi
    fi
done <"$manifest"

# --- Missing-file scan (manifest-INDEPENDENT) --------------------------------
# Walk the ENTIRE render and flag any template file the repo lacks. The manifest
# loop above only catches CONTENT drift in curated files; a file the repo is
# missing outright — added after the last manifest edit, or dropped by a
# hand-reconciled `copier update` — needs this manifest-free scan or it slips
# through silently. A mature repo can intentionally replace two seed shapes:
# flat Terraform starter files with nested/split Terraform roots, and the seed
# ADR with a renumbered equivalent or an already-active ADR log. Report those as
# benign EQUIV instead of false MISSING. .gitkeep dir-stubs are likewise benign.
equivalent_note=""
has_repo_equivalent() {
    g="$1"
    equivalent_note=""
    case "$g" in
    terraform/main.tf | terraform/variables.tf | terraform/outputs.tf | terraform/tfvars.env.example)
        if [ -d "$target/terraform" ] &&
            find "$target/terraform" -type f -name '*.tf' 2>/dev/null |
            awk -v root="$target/terraform/" '
                    index($0, root) == 1 {
                        rel = substr($0, length(root) + 1)
                        if (rel ~ /\//) found = 1
                    }
                    END { exit(found ? 0 : 1) }
                '; then
            equivalent_note="repo uses nested/split Terraform roots"
            return 0
        fi
        ;;
    docs/decisions/0001-record-architecture-decisions.md)
        for adr in "$target"/docs/decisions/[0-9]*.md; do
            [ -f "$adr" ] || continue
            case "${adr##*/}" in
            *-record-architecture-decisions.md)
                equivalent_note="repo carries a renumbered equivalent ADR"
                return 0
                ;;
            esac
        done
        if [ -f "$target/docs/decisions/README.md" ]; then
            for adr in "$target"/docs/decisions/[0-9]*.md; do
                [ -f "$adr" ] || continue
                equivalent_note="repo already has an active ADR log; the seed ADR is redundant"
                return 0
            done
        fi
        ;;
    esac
    return 1
}

while IFS= read -r abs; do
    g="${abs#"$render"/}"
    case "$g" in
    .git/* | .copier-answers.yml | CHANGELOG.md) continue ;;
    esac
    grep -qxF "$g" "$manifest" 2>/dev/null && continue # manifest loop owns it
    [ -n "$(repo_variant "$g")" ] && continue          # repo has it (or .yml/.yaml twin)
    if has_repo_equivalent "$g"; then
        echo "EQUIV    $g  ($equivalent_note)"
        continue
    fi
    case "$g" in
    *.gitkeep) echo "ABSENT   $g  (template dir-stub — benign if the dir has real content)" ;;
    *)
        echo "MISSING  $g  (template ships it; repo lacks it — review)"
        drift=1
        missing_count=$((missing_count + 1))
        ;;
    esac
done < <(find "$render" -type f | sort)

echo ""
if [ "$drift" -ne 0 ]; then
    # The counts make truncated output self-evident: if you can't see
    # $drift_count DRIFT + $missing_count MISSING lines above, you cut them off.
    echo "diff-template: ${drift_count} DRIFT + ${mode_count} MODE + ${missing_count} MISSING across $checked curated files"
    echo "  checked and a whole-render missing-file scan. Findings above. For each,"
    echo "  review the diff (\`diff-template.sh --show\`): pull missed template"
    echo "  improvements in with \`copier update\`, keep legit local customizations."
    exit 1
fi
echo "diff-template: OK — $checked curated files match and no template files missing."
