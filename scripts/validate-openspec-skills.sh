#!/usr/bin/env bash
# Validate the six vendored OpenSpec workflow skills without invoking OpenSpec.
set -euo pipefail

repo="$(git rev-parse --show-toplevel)"
cd "$repo"

skills=(.agents/skills/openspec-*/SKILL.md)
fail=0

err() {
    echo "  ✗ $*" >&2
    fail=1
}

frontmatter_is_closed() {
    awk '
        NR == 1 && $0 != "---" { exit }
        $0 == "---" { fences++ }
        END { exit (fences >= 2 ? 0 : 1) }
    ' "$1"
}

frontmatter_value() {
    local file="$1"
    local key="$2"

    awk -v key="$key" '
        NR == 1 && $0 != "---" { exit }
        NR > 1 && $0 == "---" { exit }
        index($0, key ":") == 1 {
            sub("^" key ":[[:space:]]*", "")
            print
            exit
        }
    ' "$file"
}

frontmatter_key_count() {
    local file="$1"
    local key="$2"

    awk -v key="$key" '
        NR == 1 && $0 != "---" { exit }
        NR > 1 && $0 == "---" { exit }
        index($0, key ":") == 1 { count++ }
        END { print count + 0 }
    ' "$file"
}

require_permission() {
    local file="$1"
    local commands_pattern="$2"
    local permission="$3"
    local allowed_tools="$4"

    if grep -Eq "$commands_pattern" "$file" &&
        ! grep -Fq "$permission" <<<"$allowed_tools"; then
        err "$file: command requires undeclared permission $permission"
    fi
}

if [ "${#skills[@]}" -ne 6 ] || [ ! -f "${skills[0]}" ]; then
    err "expected six .agents/skills/openspec-*/SKILL.md files, found ${#skills[@]}"
fi

for skill in "${skills[@]}"; do
    [ -f "$skill" ] || continue

    if [ "$(head -n 1 "$skill")" != "---" ]; then
        err "$skill: missing leading YAML frontmatter fence"
        continue
    fi
    if ! frontmatter_is_closed "$skill"; then
        err "$skill: frontmatter block is not closed"
        continue
    fi

    for key in name description allowed-tools; do
        count="$(frontmatter_key_count "$skill" "$key")"
        if [ "$count" -ne 1 ]; then
            err "$skill: frontmatter must contain exactly one $key field"
        fi
    done

    name="$(frontmatter_value "$skill" name)"
    name="${name%$'\r'}"
    case "$name" in
    '"'*'"')
        name="${name#\"}"
        name="${name%\"}"
        ;;
    "'"*"'")
        name="${name#\'}"
        name="${name%\'}"
        ;;
    '"'* | *'"' | "'"* | *"'")
        err "$skill: frontmatter name has mismatched quotes"
        continue
        ;;
    esac
    expected_name="$(basename "$(dirname "$skill")")"
    if [ "$name" != "$expected_name" ]; then
        err "$skill: frontmatter name '$name' does not match '$expected_name'"
    fi

    description="$(frontmatter_value "$skill" description)"
    allowed_tools="$(frontmatter_value "$skill" allowed-tools)"
    [ -n "$description" ] || err "$skill: frontmatter description is empty"
    [ -n "$allowed_tools" ] || err "$skill: frontmatter allowed-tools is empty"

    if ! grep -Fq '$(git rev-parse --show-toplevel)/scripts/openspec.sh' "$skill"; then
        err "$skill: missing the repository-pinned OpenSpec wrapper"
    fi
    if grep -En '(^|[^[:alnum:]_/.-])openspec[[:space:]]+(new|status|instructions|list|show|validate|archive|doctor|context|schemas|view|store)([^[:alnum:]_-]|$)' "$skill" >/dev/null; then
        err "$skill: contains a bare openspec command instead of the pinned wrapper"
    fi
    if grep -En 'npx[[:space:]].*@fission-ai/openspec' "$skill" >/dev/null; then
        err "$skill: invokes the OpenSpec package directly instead of the pinned wrapper"
    fi
    if awk '
        $0 ~ /scripts\/openspec\.sh"?[[:space:]]+(new|status|instructions|list|show|validate|archive|doctor|context|schemas|view|store)([^[:alnum:]_-]|$)/ &&
            !index($0, "$(git rev-parse --show-toplevel)/scripts/openspec.sh") {
            bad = 1
        }
        END { exit bad ? 0 : 1 }
    ' "$skill"; then
        err "$skill: contains a wrapper path that is not anchored to the repository root"
    fi
    if grep -Fq '"$openspec_wrapper"' "$skill" &&
        ! grep -Fq 'openspec_wrapper="$(git rev-parse --show-toplevel)/scripts/openspec.sh"' "$skill"; then
        err "$skill: uses openspec_wrapper without the pinned absolute initialization"
    fi

    require_permission "$skill" 'git rev-parse[[:space:]]+--show-toplevel' \
        'Bash(git rev-parse:*)' "$allowed_tools"
    require_permission "$skill" 'scripts/openspec\.sh|"\$openspec_wrapper"' \
        'Bash(*scripts/openspec.sh":*)' "$allowed_tools"
    require_permission "$skill" '^[[:space:]]*mkdir[[:space:]]' \
        'Bash(mkdir' "$allowed_tools"
    require_permission "$skill" '^[[:space:]]*mv[[:space:]]' \
        'Bash(mv' "$allowed_tools"
done

if [ "$fail" -ne 0 ]; then
    echo "OpenSpec skill validation FAILED" >&2
    exit 1
fi

echo "✓ ${#skills[@]} OpenSpec skills use the pinned wrapper with valid frontmatter and permissions"
