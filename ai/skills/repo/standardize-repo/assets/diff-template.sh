#!/usr/bin/env bash
# diff-template.sh — show how a repo's template-owned files differ from a fresh
# harmon-init render, so the agent can find missed template improvements.
#
# Renders harmon-init using the TARGET repo's own .copier-answers.yml, then diffs
# each path in template-owned-files.txt against the repo (mapping .yml<->.yaml).
# This is a REVIEW AID for apply/update/audit, not a pass/fail gate: a listed file
# may differ because the repo legitimately customized it (terraform tasks, a custom
# status section) OR because it's missing template improvements (the recurring
# status.sh / lint-hygiene / bootstrap class). For each DRIFT, inspect the diff and
# reconcile — pull template improvements in via `copier update`, keep local edits.
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

echo ""
if [ "$drift" -ne 0 ]; then
    echo "diff-template: $checked template-owned files checked; some differ from the"
    echo "  template (above). For each, review the diff (\`diff-template.sh --show\`):"
    echo "  pull missed template improvements in with \`copier update\`, and keep the"
    echo "  repo's legitimate local customizations."
    exit 1
fi
echo "diff-template: OK — all $checked template-owned files match the template."
