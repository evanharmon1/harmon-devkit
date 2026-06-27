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
#   • MISSING — template files the repo lacks ENTIRELY. This scan is
#               manifest-INDEPENDENT (it walks the whole render), because the
#               manifest is hand-maintained and lags the template — a file added
#               after the last manifest edit, or dropped by a hand-reconciled
#               `copier update`, would otherwise slip through silently. (.gitkeep
#               dir-stubs are listed as benign ABSENT, not flagged as drift.)
# This is a REVIEW AID for apply/update/audit, not a pass/fail gate. For each
# DRIFT/MISSING, inspect and reconcile — pull template improvements in via
# `copier update`, keep legit local customizations.
#
# Usage: diff-template.sh [TARGET_DIR]            (default: .)
#        diff-template.sh -v|--show TARGET_DIR    (print the full per-file diff)
# Env:   HARMON_INIT   template checkout (default: ~/git/harmon-init)
#
# Exit: 0 = no drift, 1 = drift found (for callers that want a signal), 2 = setup error.
# Portable to macOS bash 3.2 (no mapfile, no grep -P, no associative arrays).
set -euo pipefail

show=0
case "${1:-}" in
-v | --show)
    show=1
    shift
    ;;
esac
target="${1:-.}"
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

# Reconstruct --data from the recorded answers (skip copier's _ keys and nulls).
data_args=()
while IFS= read -r line; do
    [ -n "$line" ] && data_args+=(--data "$line")
done < <(yq 'to_entries[] | select(.key | test("^_") | not) | select(.value != null) | .key + "=" + (.value | tostring)' "$answers")

# Force every side-effect off in the throwaway render (later --data wins).
data_args+=(
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

render="$(mktemp -d -t harmon-init-render-XXXXXX)"
trap 'rm -rf "$render"' EXIT
copier copy "$template" "$render" --vcs-ref="$src_ref" --trust --defaults "${data_args[@]}" >/dev/null 2>&1 || {
    echo "FAIL: copier render failed (template ref: $src_ref)" >&2
    exit 2
}

# Resolve a repo file path, honoring .yml<->.yaml (each tool's own convention).
repo_variant() {
    p="$1"
    if [ -f "$target/$p" ]; then
        echo "$target/$p"
        return
    fi
    case "$p" in
    *.yml) [ -f "$target/${p%.yml}.yaml" ] && {
        echo "$target/${p%.yml}.yaml"
        return
    } ;;
    *.yaml) [ -f "$target/${p%.yaml}.yml" ] && {
        echo "$target/${p%.yaml}.yml"
        return
    } ;;
    esac
    echo ""
}

drift=0
checked=0
while IFS= read -r f; do
    case "$f" in '' | \#*) continue ;; esac
    [ -f "$render/$f" ] || continue # conditional file not in this profile
    checked=$((checked + 1))
    rv="$(repo_variant "$f")"
    if [ -z "$rv" ]; then
        echo "MISSING  $f  (template ships it; repo doesn't)"
        drift=1
        continue
    fi
    if ! diff -q "$render/$f" "$rv" >/dev/null 2>&1; then
        echo "DRIFT    ${rv#"$target"/}"
        drift=1
        [ "$show" -eq 1 ] && diff -u "$rv" "$render/$f" | sed 's/^/    /'
    fi
done <"$manifest"

# --- Missing-file scan (manifest-INDEPENDENT) --------------------------------
# Walk the ENTIRE render and flag any template file the repo lacks. The manifest
# loop above only catches CONTENT drift in curated files; a file the repo is
# missing outright — added after the last manifest edit, or dropped by a
# hand-reconciled `copier update` — needs this manifest-free scan or it slips
# through silently. .gitkeep dir-stubs are benign (a populated dir legitimately
# omits them), so they're shown as ABSENT but not counted as drift.
while IFS= read -r abs; do
    g="${abs#"$render"/}"
    case "$g" in
    .git/* | .copier-answers.yml | CHANGELOG.md) continue ;;
    esac
    grep -qxF "$g" "$manifest" 2>/dev/null && continue # manifest loop owns it
    [ -n "$(repo_variant "$g")" ] && continue          # repo has it (or .yml/.yaml twin)
    case "$g" in
    *.gitkeep) echo "ABSENT   $g  (template dir-stub — benign if the dir has real content)" ;;
    *)
        echo "MISSING  $g  (template ships it; repo lacks it — review)"
        drift=1
        ;;
    esac
done < <(find "$render" -type f | sort)

echo ""
if [ "$drift" -ne 0 ]; then
    echo "diff-template: $checked curated files checked for drift; whole render"
    echo "  scanned for missing files. Findings above (DRIFT/MISSING). For each,"
    echo "  review the diff (\`diff-template.sh --show\`): pull missed template"
    echo "  improvements in with \`copier update\`, keep legit local customizations."
    exit 1
fi
echo "diff-template: OK — $checked curated files match and no template files missing."
