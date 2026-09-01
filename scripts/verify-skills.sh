#!/usr/bin/env bash
# verify-skills.sh — source-of-truth guard for the shared agent skills in
# `ai/skills/`. harmon-devkit is vendored into consumer repos by category
# (see templates/skills-sync/), and categories are FLATTENED on vendor, so this
# guard enforces the invariants a consumer relies on:
#
#   1. Every skill directory (one that contains a SKILL.md) has valid
#      frontmatter: a leading `---` block with `name:` and `description:` keys.
#   2. The frontmatter `name:` matches the directory name.
#   3. Skill directory names are UNIQUE across categories (a flattened dest
#      can't hold backend/foo and frontend/foo at once).
#   4. Within `universal/` (the category harmon-devkit itself authors and
#      dogfoods — third-party categories are not ours to police), the
#      invocation frontmatter is internally consistent with the description:
#      a description that tells an agent how to invoke the skill must not sit
#      under a flag that forbids exactly that, and vice versa.
#
# Directories without a SKILL.md (drafts, placeholders, empty categories) are
# not yet skills — they are skipped, not failed, so work-in-progress can live in
# the tree. Runs offline with no dependency beyond coreutils + awk (no yq), so
# it is cheap enough for `task verify` and the pre-commit hook.
#
# Run via `task validate:skills`.
set -euo pipefail

repo="$(git rev-parse --show-toplevel)"
cd "$repo"

SKILLS_ROOT="ai/skills"

fail=0
err() {
    echo "  ✗ $*" >&2
    fail=1
}

if [ ! -d "$SKILLS_ROOT" ]; then
    echo "no $SKILLS_ROOT directory — nothing to verify"
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

# Join the frontmatter `description:` value into one text, whether it is a
# single-line scalar (`description: foo`) or a folded/literal block scalar
# (`>-`, `>`, `|-`, `|`) spanning indented continuation lines — the style every
# universal/ skill uses today. A continuation line is distinguished from the
# next top-level key by indentation: YAML keys never start in column 1 inside
# a mapping we've already entered at column 1, so a line starting with
# `word:` in column 1 always ends the block.
frontmatter_description_text() {
    awk '
        NR == 1 && $0 != "---" { exit }
        $0 == "---" {
            fence++
            if (fence == 2) exit
            next
        }
        fence != 1 { next }
        in_desc {
            if ($0 ~ /^[A-Za-z0-9_-]+:/) {
                in_desc = 0
            } else {
                line = $0
                sub(/^[ \t]+/, "", line)
                text = text " " line
                next
            }
        }
        /^description:[[:space:]]*[|>]-?[[:space:]]*$/ {
            in_desc = 1
            next
        }
        /^description:[[:space:]]*/ {
            line = $0
            sub(/^description:[[:space:]]*/, "", line)
            text = text " " line
        }
        END {
            gsub(/^[ \t]+|[ \t]+$/, "", text)
            print text
        }
    ' "$1"
}

# Return success if the frontmatter has a top-level `<key>: <val>` line, exact
# scalar match (used for the `true`/`false` invocation flags below).
frontmatter_flag_is() {
    awk -v key="$2" -v val="$3" '
        NR == 1 && $0 != "---" { exit }
        $0 == "---" { fence++; if (fence == 2) exit; next }
        fence == 1 && $0 ~ ("^" key ":[[:space:]]*" val "[[:space:]]*$") { found = 1 }
        END { exit (found ? 0 : 1) }
    ' "$1"
}

# Collect every SKILL.md under the skills root (sorted, newline-delimited).
skill_mds="$(find "$SKILLS_ROOT" -mindepth 2 -type f -name SKILL.md | LC_ALL=C sort)"

if [ -z "$skill_mds" ]; then
    echo "no SKILL.md files under $SKILLS_ROOT — nothing to verify"
    exit 0
fi

count=0
seen="" # newline-delimited "<name>|<dir>" records; names are kebab-case (no '|')

while IFS= read -r md; do
    [ -n "$md" ] || continue
    count=$((count + 1))
    dir="$(dirname "$md")"
    name="$(basename "$dir")"

    # --- uniqueness across categories -----------------------------------
    prev="$(printf '%s\n' "$seen" | awk -F'|' -v n="$name" '$1 == n { print $2; exit }')"
    if [ -n "$prev" ]; then
        err "duplicate skill name '$name' in two categories:"
        err "    $prev/SKILL.md"
        err "    $dir/SKILL.md"
        err "  skill directory names must be unique across categories (flattened on vendor)"
    else
        seen="${seen}${name}|${dir}"$'\n'
    fi

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
    fm_name="${fm_name%$'\r'}"
    # Strip surrounding quotes only as a MATCHED pair. Trimming each delimiter
    # independently reduces `"alpha'` to `alpha`, so a mismatched quote passes
    # as valid — and a YAML loader rejects that scalar outright, meaning the
    # skill never loads at all while the guard calls the file well-formed.
    case "$fm_name" in
    '"'*'"')
        fm_name="${fm_name#\"}"
        fm_name="${fm_name%\"}"
        ;;
    "'"*"'")
        fm_name="${fm_name#\'}"
        fm_name="${fm_name%\'}"
        ;;
    '"'* | *'"' | "'"* | *"'")
        err "$md: frontmatter name has mismatched quotes: $fm_name"
        continue
        ;;
    esac

    if [ -z "$fm_name" ]; then
        err "$md: frontmatter is missing a 'name:' field"
    elif [ "$fm_name" != "$name" ]; then
        err "$md: frontmatter name '$fm_name' != directory name '$name'"
    fi

    if ! frontmatter_has_description "$md"; then
        err "$md: frontmatter is missing a 'description:' field"
    else
        # --- universal/ invocation consistency (issue #702) -----------------
        # Third-party categories (matt-pocock/) are not ours to police, so this
        # is scoped to the category harmon-devkit itself authors and dogfoods.
        rel="${dir#"$SKILLS_ROOT"/}"
        category="${rel%%/*}"
        if [ "$category" = "universal" ]; then
            desc="$(frontmatter_description_text "$md")"
            if frontmatter_flag_is "$md" "user-invocable" "false"; then
                case "$desc" in
                *"Do not invoke directly"*) ;;
                *)
                    err "$md: user-invocable: false requires 'Do not invoke directly' in the description"
                    ;;
                esac
            elif frontmatter_flag_is "$md" "disable-model-invocation" "true"; then
                case "$desc" in
                *"Invoke as /$name"*) ;;
                *)
                    err "$md: disable-model-invocation: true requires 'Invoke as /$name' in the description"
                    ;;
                esac
                case "$desc" in
                *"Use when"*)
                    err "$md: disable-model-invocation: true but description contains 'Use when' (a user-only skill must not carry model-trigger phrasing)"
                    ;;
                esac
                case "$desc" in
                *"Trigger it"*)
                    err "$md: disable-model-invocation: true but description contains 'Trigger it' (a user-only skill must not carry model-trigger phrasing)"
                    ;;
                esac
            else
                case "$desc" in
                *"Use when"*) ;;
                *)
                    err "$md: model-invocable skill (no disable-model-invocation) must contain 'Use when' in the description"
                    ;;
                esac
            fi
        fi
    fi
done <<EOF
$skill_mds
EOF

# Informational: category subdirectories that are not (yet) skills.
non_skill=""
while IFS= read -r d; do
    [ -n "$d" ] || continue
    [ -f "$d/SKILL.md" ] && continue
    non_skill="${non_skill}    ${d} (no SKILL.md)"$'\n'
done <<EOF
$(find "$SKILLS_ROOT" -mindepth 2 -maxdepth 2 -type d | LC_ALL=C sort)
EOF

if [ "$fail" -ne 0 ]; then
    echo "" >&2
    echo "skills validation FAILED — fix the issues above" >&2
    exit 1
fi

echo "✓ $count skill(s) valid: unique names across categories, well-formed SKILL.md frontmatter"
if [ -n "$non_skill" ]; then
    printf 'note: skipped non-skill directories (drafts/placeholders):\n%s' "$non_skill"
fi
