#!/usr/bin/env bash
#
# detect-project-type.sh — inspect a repo and print suggested copier --data flags
# for the harmon-init template (https://github.com/evanharmon1/harmon-init).
#
# Usage:
#   detect-project-type.sh [TARGET_DIR]   # TARGET_DIR defaults to "."
#
# Output:
#   stdout — copy-pasteable `--data key=value` flags for `copier copy/update`.
#   stderr — a one-line human-readable summary of what was detected.
#
# The emitted flags mirror the questions in harmon-init's copier.yml:
#   project_type ∈ {general, web-astro, web-app, iac, docs}
#   include_terraform / include_ansible (booleans)
# copier derives use_node/use_python from these, so they are not emitted.
#
# Detection is best-effort. Always review the suggestions before running copier.
# Portable to macOS bash 3.2 (no mapfile, no grep -P, no associative arrays).

set -euo pipefail

target="${1:-.}"

if [ ! -d "$target" ]; then
    echo "error: target directory not found: $target" >&2
    exit 1
fi

# ── Detection helpers ───────────────────────────────────────────────
# All helpers are silent (exit status only) so callers can branch on them.

pkg_json="$target/package.json"
have_node=false
[ -f "$pkg_json" ] && have_node=true

# pkg_has PATTERN — true if package.json exists and contains PATTERN (case-insensitive).
pkg_has() {
    [ -f "$pkg_json" ] || return 1
    grep -i -q -e "$1" "$pkg_json"
}

# find_first GLOB... — print the first matching path under target, or nothing.
# Uses find (not bash globbing) so it works without nullglob and recurses.
find_first() {
    find "$target" -type f \( "$@" \) 2>/dev/null | head -n 1
}

# Terraform: any *.tf file anywhere, or a terraform/ directory.
have_terraform=false
if [ -d "$target/terraform" ]; then
    have_terraform=true
elif [ -n "$(find_first -name '*.tf')" ]; then
    have_terraform=true
fi

# Ansible: an ansible/ dir, an ansible.cfg, a pyproject declaring ansible,
# or a *.yml/*.yaml file that looks like a playbook (top-level `hosts:`).
have_ansible=false
ansible_reason=""
if [ -d "$target/ansible" ]; then
    have_ansible=true
    ansible_reason="ansible/ directory"
elif [ -f "$target/ansible.cfg" ]; then
    have_ansible=true
    ansible_reason="ansible.cfg"
elif [ -f "$target/pyproject.toml" ] && grep -i -q -e 'ansible' "$target/pyproject.toml"; then
    have_ansible=true
    ansible_reason="ansible in pyproject.toml"
else
    # Scan YAML files for a playbook signature without grep -P or mapfile.
    while IFS= read -r yml; do
        [ -n "$yml" ] || continue
        if grep -E -q '^[[:space:]]*-?[[:space:]]*hosts:[[:space:]]' "$yml"; then
            have_ansible=true
            ansible_reason="playbook ($yml)"
            break
        fi
    done <<EOF
$(find "$target" -type f \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null)
EOF
fi

# Python (non-node) project markers.
have_python=false
if [ -f "$target/pyproject.toml" ] || [ -f "$target/requirements.txt" ]; then
    have_python=true
fi

# Markdown / docs presence, and whether any "code" file exists at all.
have_markdown=false
if [ -n "$(find_first -name '*.md' -o -name '*.markdown')" ]; then
    have_markdown=true
fi

# A small set of source extensions that would disqualify a "docs-only" repo.
have_code=false
if [ -n "$(
    find_first \
        -name '*.ts' -o -name '*.tsx' -o -name '*.js' -o -name '*.jsx' \
        -o -name '*.py' -o -name '*.go' -o -name '*.rs' -o -name '*.rb' \
        -o -name '*.sh' -o -name '*.tf' -o -name '*.java' -o -name '*.c' \
        -o -name '*.cpp' -o -name '*.cs' -o -name '*.php'
)" ]; then
    have_code=true
fi

# ── Decide project_type ─────────────────────────────────────────────
# Priority: web-astro > web-app > iac > docs > general. Terraform/Ansible
# also force iac when no web framework is present.

project_type="general"
type_reason="no stronger signal"

if "$have_node" && pkg_has 'astro'; then
    project_type="web-astro"
    type_reason="astro in package.json"
elif "$have_node" && { pkg_has 'react' || pkg_has '@tanstack'; }; then
    project_type="web-app"
    type_reason="react/@tanstack in package.json"
elif "$have_ansible" || "$have_terraform"; then
    project_type="iac"
    if "$have_ansible" && "$have_terraform"; then
        type_reason="terraform + ansible"
    elif "$have_ansible"; then
        type_reason="ansible ($ansible_reason)"
    else
        type_reason="terraform files"
    fi
elif "$have_python" && ! "$have_node"; then
    # A Python project that isn't IaC and isn't a JS app: closest fit is general.
    project_type="general"
    type_reason="python project (pyproject/requirements, no node)"
elif "$have_markdown" && ! "$have_code"; then
    project_type="docs"
    type_reason="markdown only, no source files"
fi

# ── Emit copier --data flags ────────────────────────────────────────

printf -- '--data project_type=%s\n' "$project_type"

if "$have_terraform"; then
    printf -- '--data include_terraform=true\n'
fi

if "$have_ansible"; then
    printf -- '--data include_ansible=true\n'
fi

# ── Human summary (stderr) ──────────────────────────────────────────

summary="detected project_type=$project_type ($type_reason)"
if "$have_terraform"; then
    summary="$summary; include_terraform=true"
fi
if "$have_ansible"; then
    summary="$summary; include_ansible=true"
fi
echo "$summary" >&2
