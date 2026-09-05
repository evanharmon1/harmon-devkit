#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"

assert_repo_link() {
    local path="$1"
    local expected="$2"

    if [ ! -L "$repo_root/$path" ]; then
        echo "test-agent-skill-links: missing dogfood link: $path" >&2
        exit 1
    fi
    if [ "$(readlink "$repo_root/$path")" != "$expected" ]; then
        echo "test-agent-skill-links: wrong dogfood target: $path" >&2
        exit 1
    fi
    if [ ! -e "$repo_root/$path" ]; then
        echo "test-agent-skill-links: dangling dogfood link: $path" >&2
        exit 1
    fi
}

assert_repo_link .agents/skills/review ../../ai/skills/universal/review
assert_repo_link .agents/skills/orchestrator ../../ai/skills/universal/orchestrator
assert_repo_link .claude/agents/challenger.md ../../ai/agents/challenger.md
assert_repo_link .claude/agents/reviewer.md ../../ai/agents/reviewer.md
if [ -e "$repo_root/.agents/skills/gauntlet" ] || [ -L "$repo_root/.agents/skills/gauntlet" ]; then
    echo "test-agent-skill-links: retired gauntlet dogfood link remains" >&2
    exit 1
fi

fixture="$(mktemp -d -t agent-skill-links-XXXXXX)"
trap 'rm -rf "$fixture"' EXIT
cd "$fixture"

mkdir -p .claude/skills/shared .claude/skills/local .agents/skills/native
printf '%s\n' shared >.claude/skills/shared/SKILL.md
printf '%s\n' local >.claude/skills/local/SKILL.md
printf '%s\n' native >.agents/skills/native/SKILL.md

"$repo_root/scripts/link-agent-skills.sh" sync
[ "$(readlink .agents/skills/shared)" = "../../.claude/skills/shared" ]
[ "$(readlink .agents/skills/local)" = "../../.claude/skills/local" ]
[ -f .agents/skills/native/SKILL.md ]
"$repo_root/scripts/link-agent-skills.sh" verify

rm -rf .claude/skills/shared
if "$repo_root/scripts/link-agent-skills.sh" verify >/dev/null 2>&1; then
    echo "test-agent-skill-links: verify accepted a stale compatibility link" >&2
    exit 1
fi
"$repo_root/scripts/link-agent-skills.sh" sync
[ ! -e .agents/skills/shared ] && [ ! -L .agents/skills/shared ]

mkdir -p .claude/skills/native
printf '%s\n' claude >.claude/skills/native/SKILL.md
if "$repo_root/scripts/link-agent-skills.sh" sync >/dev/null 2>&1; then
    echo "test-agent-skill-links: accepted divergent same-name skills" >&2
    exit 1
fi
[ ! -L .agents/skills/native ]
[ "$(cat .agents/skills/native/SKILL.md)" = native ]

echo "test-agent-skill-links: PASS"
