#!/usr/bin/env bash
# test-agents.sh — unit tests for verify-agents.sh, the source-of-truth guard
# for `ai/agents/`. Hermetic and offline: builds throwaway repos in temp dirs
# and drives the real script against them. Run via `task test:agents`.
set -euo pipefail

repo="$(git rev-parse --show-toplevel)"
GUARD="$repo/scripts/verify-agents.sh"

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

pass=0
fail=0
ok() {
    pass=$((pass + 1))
    echo "  ✓ $*"
}
bad() {
    fail=$((fail + 1))
    echo "  ✗ $*" >&2
}

# guard DIR — run the guard with DIR as the repo root.
guard() { (cd "$1" && bash "$GUARD"); }

expect_ok() {
    local desc="$1" dir="$2" output
    if output="$(guard "$dir" 2>&1)"; then
        ok "$desc"
    else
        bad "$desc (expected exit 0)"
        [ -z "$output" ] || printf '%s\n' "$output" | sed 's/^/      /' >&2
    fi
}
# Succeed iff the guard exits non-zero AND says why — a rejection that fires for
# an unrelated reason is a passing test that proves nothing.
expect_fail_contains() {
    local desc="$1" dir="$2" needle="$3" output
    if output="$(guard "$dir" 2>&1)"; then
        bad "$desc (expected non-zero exit)"
        [ -z "$output" ] || printf '%s\n' "$output" | sed 's/^/      /' >&2
    elif printf '%s\n' "$output" | grep -qF "$needle"; then
        ok "$desc"
    else
        bad "$desc (missing diagnostic: $needle)"
        [ -z "$output" ] || printf '%s\n' "$output" | sed 's/^/      /' >&2
    fi
}

newrepo() {
    git init -q -b main "$1"
    mkdir -p "$1/ai/agents"
}

# mkagent DIR NAME [FRONTMATTER_NAME] — write a minimal valid agent file.
mkagent() {
    {
        echo "---"
        echo "name: ${3:-$2}"
        echo "description: A test agent named $2."
        echo "---"
        echo ""
        echo "# $2"
    } >"$1/ai/agents/$2.md"
}

# mkskill DIR CATEGORY NAME — write a minimal valid skill.
mkskill() {
    mkdir -p "$1/ai/skills/$2/$3"
    {
        echo "---"
        echo "name: $3"
        echo "description: A test skill named $3."
        echo "---"
        echo ""
        echo "# $3"
    } >"$1/ai/skills/$2/$3/SKILL.md"
}

echo "==> verify-agents.sh"

# A clean tree passes, and README.md is not mistaken for an agent.
R1="$TMPROOT/clean"
newrepo "$R1"
mkagent "$R1" alpha
mkagent "$R1" bravo
echo "# Agents" >"$R1/ai/agents/README.md"
mkskill "$R1" universal some-skill
expect_ok "clean agents tree passes (README.md skipped)" "$R1"

# A README-only directory is not an error.
R2="$TMPROOT/readme-only"
newrepo "$R2"
echo "# Agents" >"$R2/ai/agents/README.md"
expect_ok "README-only agents dir passes" "$R2"

# A missing ai/agents directory is not an error.
R3="$TMPROOT/absent"
git init -q -b main "$R3"
expect_ok "absent ai/agents dir passes" "$R3"

# Frontmatter name != filename fails.
R4="$TMPROOT/name-mismatch"
newrepo "$R4"
mkagent "$R4" charlie not-charlie
expect_fail_contains "frontmatter name != filename fails" "$R4" \
    "frontmatter name 'not-charlie' != filename 'charlie'"

# Missing description fails.
R5="$TMPROOT/no-desc"
newrepo "$R5"
{
    echo "---"
    echo "name: delta"
    echo "---"
    echo "# delta"
} >"$R5/ai/agents/delta.md"
expect_fail_contains "missing description fails" "$R5" \
    "missing a 'description:' field"

# Missing frontmatter fence fails.
R6="$TMPROOT/no-fm"
newrepo "$R6"
echo "# echo (no frontmatter)" >"$R6/ai/agents/echo.md"
expect_fail_contains "missing frontmatter fails" "$R6" \
    "missing YAML frontmatter"

# An unclosed frontmatter block fails — a real YAML parser sees no frontmatter
# at all, so the fields the guard parsed out of it do not exist.
R11="$TMPROOT/unclosed-fm"
newrepo "$R11"
{
    echo "---"
    echo "name: golf"
    echo "description: An agent whose frontmatter is never closed."
    echo ""
    echo "# golf"
} >"$R11/ai/agents/golf.md"
expect_fail_contains "unclosed frontmatter fails" "$R11" \
    "frontmatter block is never closed"

# Non-kebab-case names are refused — they become paths on both sides of the
# vendor, and a capital collides with its lowercase twin on a case-insensitive
# filesystem.
R14="$TMPROOT/not-kebab"
newrepo "$R14"
mkagent "$R14" "Juliet"
expect_fail_contains "an uppercase agent name fails" "$R14" "is not kebab-case"

R15="$TMPROOT/spaced-name"
newrepo "$R15"
mkagent "$R15" "kilo lima"
expect_fail_contains "an agent name with a space fails" "$R15" "is not kebab-case"

# A Claude-specific frontmatter key breaks the portability contract.
R12="$TMPROOT/extra-key"
newrepo "$R12"
{
    echo "---"
    echo "name: hotel"
    echo "description: An agent carrying non-portable metadata."
    echo "tools: Bash, Read"
    echo "model: opus"
    echo "---"
    echo "# hotel"
} >"$R12/ai/agents/hotel.md"
expect_fail_contains "a 'tools:' frontmatter key fails" "$R12" \
    "frontmatter key 'tools' breaks the portability contract"

# A folded description's indented continuation lines are values, not keys.
R13="$TMPROOT/folded-desc"
newrepo "$R13"
{
    echo "---"
    echo "name: india"
    echo "description: >-"
    echo "  A folded description whose continuation lines are indented."
    echo "  tools: this line is prose inside the value, not a key."
    echo "---"
    echo "# india"
} >"$R13/ai/agents/india.md"
expect_ok "a folded description's continuation lines are not read as keys" "$R13"

# An agent whose name collides with a skill name fails.
R7="$TMPROOT/collision"
newrepo "$R7"
mkagent "$R7" implement
mkskill "$R7" universal implement
expect_fail_contains "agent name colliding with a skill name fails" "$R7" \
    "collides with the skill of the same name"

# The collision check matches the whole name, not a prefix or substring.
R8="$TMPROOT/near-miss"
newrepo "$R8"
mkagent "$R8" implementer
mkskill "$R8" universal implement
expect_ok "a near-miss name (implementer vs implement) passes" "$R8"

# A subdirectory is refused, not silently skipped.
R9="$TMPROOT/subdir"
newrepo "$R9"
mkagent "$R9" foxtrot
mkdir -p "$R9/ai/agents/universal"
expect_fail_contains "a subdirectory under ai/agents fails" "$R9" \
    "must be flat"

# A subdirectory is caught even when it is the only thing there — the flat-layout
# failure must not be swallowed by the "nothing to verify" early exit.
R10="$TMPROOT/subdir-only"
newrepo "$R10"
mkdir -p "$R10/ai/agents/universal"
expect_fail_contains "a subdirectory with no agent files still fails" "$R10" \
    "must be flat"

echo ""
echo "test-agents: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
