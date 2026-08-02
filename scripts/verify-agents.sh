#!/usr/bin/env bash
# verify-agents.sh — source-of-truth guard for the shared subagents in
# `ai/agents/`. Agents are single Markdown files (frontmatter + system prompt)
# vendored into consumer repos alongside skills, so this guard enforces the
# invariants a consumer relies on:
#
#   1. Every agent file has valid frontmatter: a leading `---` block with
#      `name:` and `description:` keys.
#   2. The frontmatter `name:` matches the filename (minus `.md`).
#   3. No agent name collides with a skill directory name under `ai/skills/`.
#   4. Frontmatter carries `name` and `description` and nothing else — the
#      portability contract in ai/agents/README.md, which is otherwise a rule
#      with nothing checking it.
#
# (3) is the rule with no skills-side equivalent. Agents and skills land in
# sibling destinations (`.claude/agents/` vs `.claude/skills/`), so a shared
# name never collides on disk — it collides in the reader, which is worse
# precisely because nothing fails.
#
# `README.md` documents the directory rather than declaring an agent, so it is
# skipped by name. The layout is deliberately FLAT (see ai/agents/README.md); a
# subdirectory is refused rather than ignored, because an unscanned agent is
# also an unvendored one and would fail silently.
#
# The frontmatter parsers below are twins of the ones in verify-skills.sh. They
# are duplicated on purpose: merging the two guards, or extracting a shell
# library for ~20 lines of awk over a format fixed by the Agent Skills
# convention, would cost a rename across the Taskfile, the git hooks, the tests,
# and the docs. Revisit if a third asset type wants the same parse.
#
# Runs offline with no dependency beyond coreutils + awk, so it is cheap enough
# for `task verify` and the pre-commit hook.
#
# Run via `task validate:agents`.
set -euo pipefail

repo="$(git rev-parse --show-toplevel)"
cd "$repo"

AGENTS_ROOT="ai/agents"
SKILLS_ROOT="ai/skills"

fail=0
err() {
    echo "  ✗ $*" >&2
    fail=1
}

if [ ! -d "$AGENTS_ROOT" ]; then
    echo "no $AGENTS_ROOT directory — nothing to verify"
    exit 0
fi

# Extract the value of the first top-level `name:` key inside the leading `---`
# frontmatter block. Prints nothing if there is no frontmatter or no name.
frontmatter_name() {
    awk '
        NR == 1 && $0 != "---" { exit }        # file does not open with frontmatter
        $0 == "---" { fence++; if (fence == 2) exit; next }
        fence == 1 && /^name:[[:space:]]*/ {
            sub(/^name:[[:space:]]*/, "")
            print
            exit
        }
    ' "$1"
}

# Return success if the leading frontmatter block is CLOSED by a second `---`.
# Checked before the two parsers below, which both scan only the opening block
# and would otherwise accept an unterminated one: `---`, name, description, then
# straight into the body reads as valid here while a real YAML frontmatter
# parser sees no frontmatter at all. Counting fences anywhere in the file is
# deliberate — the block ends at the next `---` whatever follows it, which is
# what an actual parser does too.
frontmatter_is_closed() {
    awk '
        NR == 1 && $0 != "---" { exit }
        $0 == "---" { fence++ }
        END { exit (fence >= 2 ? 0 : 1) }
    ' "$1"
}

# Print the top-level keys of the leading frontmatter block, one per line.
# Column-anchored, so the indented continuation lines of a folded scalar
# (`description: >-`) are values, not keys.
frontmatter_keys() {
    awk '
        NR == 1 && $0 != "---" { exit }
        fence >= 2 { next }
        $0 == "---" { fence++; next }
        fence == 1 && /^[A-Za-z_][A-Za-z0-9_-]*:/ {
            sub(/:.*/, "")
            print
        }
    ' "$1"
}

# Return success if the leading frontmatter block contains a `description:` key.
# Note: awk `exit` runs the END rule, so route every path through END (a bare
# `exit 0` here would be overridden by `END { exit 1 }`).
frontmatter_has_description() {
    awk '
        NR == 1 && $0 != "---" { exit }
        fence >= 2 { next }
        $0 == "---" { fence++; next }
        fence == 1 && /^description:[[:space:]]*/ { found = 1 }
        END { exit (found ? 0 : 1) }
    ' "$1"
}

# --- flat-layout guard --------------------------------------------------
# Fail closed on a subdirectory: it would hold agents that this guard never
# validates and the vendoring engine never ships.
subdirs="$(find "$AGENTS_ROOT" -mindepth 1 -maxdepth 1 -type d | LC_ALL=C sort)"
if [ -n "$subdirs" ]; then
    err "$AGENTS_ROOT must be flat — found subdirector(ies):"
    while IFS= read -r d; do
        [ -n "$d" ] || continue
        err "    $d"
    done <<EOF
$subdirs
EOF
    err "  one file per agent, no categories (see $AGENTS_ROOT/README.md)"
fi

# --- collect the agent files -------------------------------------------
agent_files="$(find "$AGENTS_ROOT" -mindepth 1 -maxdepth 1 -type f -name '*.md' \
    ! -name 'README.md' | LC_ALL=C sort)"

if [ -z "$agent_files" ]; then
    if [ "$fail" -ne 0 ]; then
        echo "" >&2
        echo "agents validation FAILED — fix the issues above" >&2
        exit 1
    fi
    echo "no agent files under $AGENTS_ROOT — nothing to verify"
    exit 0
fi

# --- skill names, for the collision check ------------------------------
# Empty when ai/skills/ is absent; the collision check then trivially passes.
# A read loop rather than `find -exec … | xargs`: BSD and GNU xargs disagree on
# empty input (`-r` does not exist on macOS), and this repo's scripts are
# expected to run under both.
skill_names=""
if [ -d "$SKILLS_ROOT" ]; then
    while IFS= read -r sd; do
        [ -n "$sd" ] || continue
        skill_names="${skill_names}$(basename "$(dirname "$sd")")"$'\n'
    done <<EOF
$(find "$SKILLS_ROOT" -mindepth 2 -type f -name SKILL.md | LC_ALL=C sort)
EOF
fi

count=0
while IFS= read -r md; do
    [ -n "$md" ] || continue
    count=$((count + 1))
    name="$(basename "$md" .md)"

    # --- frontmatter validity -------------------------------------------
    if [ "$(head -n 1 "$md")" != "---" ]; then
        err "$md: missing YAML frontmatter (must open with '---')"
        continue
    fi
    if ! frontmatter_is_closed "$md"; then
        err "$md: frontmatter block is never closed (needs a second '---')"
        continue
    fi
    fm_name="$(frontmatter_name "$md")"
    # trim CR and surrounding quotes
    fm_name="${fm_name%$'\r'}"
    fm_name="${fm_name#\"}"
    fm_name="${fm_name%\"}"
    fm_name="${fm_name#\'}"
    fm_name="${fm_name%\'}"

    if [ -z "$fm_name" ]; then
        err "$md: frontmatter is missing a 'name:' field"
    elif [ "$fm_name" != "$name" ]; then
        err "$md: frontmatter name '$fm_name' != filename '$name'"
    fi

    if ! frontmatter_has_description "$md"; then
        err "$md: frontmatter is missing a 'description:' field"
    fi

    # --- portability: no keys beyond name/description --------------------
    # ai/agents/README.md states the contract; without this it is aspirational,
    # and `tools:`/`model:`/`color:` would ship to every consumer as a decision
    # the calling session can no longer make. Adding a key later is meant to
    # cost a deliberate edit here — that friction IS the portability review.
    while IFS= read -r key; do
        [ -n "$key" ] || continue
        case "$key" in
        name | description) ;;
        *)
            err "$md: frontmatter key '$key' breaks the portability contract"
            err "  shared agents carry 'name' and 'description' only (see $AGENTS_ROOT/README.md)"
            ;;
        esac
    done <<EOF
$(frontmatter_keys "$md")
EOF

    # --- no collision with a skill name ---------------------------------
    # Match on the filename, not the frontmatter: the two are required to agree
    # above, and the filename is what a consumer's vendored copy is named.
    if printf '%s\n' "$skill_names" | grep -qxF "$name"; then
        err "$md: agent name '$name' collides with the skill of the same name"
        err "  rename one — sibling dests mean nothing fails, it just reads ambiguously"
    fi
done <<EOF
$agent_files
EOF

if [ "$fail" -ne 0 ]; then
    echo "" >&2
    echo "agents validation FAILED — fix the issues above" >&2
    exit 1
fi

echo "✓ $count agent(s) valid: well-formed frontmatter, names match filenames, no skill-name collisions"
