#!/usr/bin/env bash
# Keep Claude-first skills visible through the cross-harness .agents standard.
set -euo pipefail

mode="${1:-sync}"
claude_dir="${CLAUDE_SKILLS_DIR:-.claude/skills}"
portable_dir="${AGENT_SKILLS_DIR:-.agents/skills}"

case "$mode" in
sync | verify) ;;
*)
    echo "usage: link-agent-skills.sh {sync|verify}" >&2
    exit 2
    ;;
esac

mkdir -p "$claude_dir" "$portable_dir"
failed=0

# A tool other than this compatibility layer may legitimately own a skill in
# BOTH trees at once — a codegen tool that emits a Claude skill under
# .claude/skills AND a deliberately DIFFERENT portable skill of the same name
# under .agents/skills (per-harness variants). Such names are declared so this
# layer neither mirrors them nor mistakes the intended divergence for an
# accidental same-name clobber. Everything NOT declared stays fail-closed: an
# undeclared same-name portable skill is still refused below. Declarations come
# from the AGENT_SKILLS_LINK_IGNORE env var (whitespace-separated globs) and a
# .link-ignore file in the portable dir (one shell glob per line; text after
# '#' and blank lines are ignored).
ignore_globs="${AGENT_SKILLS_LINK_IGNORE:-}"
ignore_file="$portable_dir/.link-ignore"
if [ -f "$ignore_file" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
        ignore_globs="$ignore_globs ${line%%#*}"
    done <"$ignore_file"
fi

# Word-splitting on $ignore_globs is intentional: it iterates the collected
# globs and collapses the blank/comment residue left above.
is_ignored() {
    _name="$1"
    for _glob in $ignore_globs; do
        case "$_name" in
        $_glob) return 0 ;;
        esac
    done
    return 1
}

# Refuse ambiguity before changing anything. A native portable skill remains
# untouched, but it cannot silently override a different Claude-managed skill
# with the same name.
for skill_dir in "$claude_dir"/*/; do
    [ -d "$skill_dir" ] || continue
    name="$(basename "${skill_dir%/}")"
    is_ignored "$name" && continue
    link="$portable_dir/$name"
    target="../../$claude_dir/$name"
    if { [ -e "$link" ] || [ -L "$link" ]; } &&
        ! { [ -L "$link" ] && [ "$(readlink "$link")" = "$target" ]; }; then
        echo "refusing divergent same-name skill: $link" >&2
        failed=1
    fi
done
[ "$failed" -eq 0 ] || exit 1

for skill_dir in "$claude_dir"/*/; do
    [ -d "$skill_dir" ] || continue
    name="$(basename "${skill_dir%/}")"
    is_ignored "$name" && continue
    link="$portable_dir/$name"
    target="../../$claude_dir/$name"

    if [ -L "$link" ] && [ "$(readlink "$link")" = "$target" ]; then
        continue
    fi
    if [ "$mode" = "verify" ]; then
        echo "missing portable skill link: $link -> $target" >&2
        failed=1
    else
        ln -s "$target" "$link"
    fi
done

# Remove only links this compatibility layer can prove it owns. Native skills,
# declared tool-managed skills, and links to any other location are preserved.
for link in "$portable_dir"/*; do
    [ -L "$link" ] || continue
    is_ignored "$(basename "$link")" && continue
    target="$(readlink "$link")"
    case "$target" in
    "../../$claude_dir/"*) ;;
    *) continue ;;
    esac
    [ -d "$link" ] && continue
    if [ "$mode" = "verify" ]; then
        echo "stale portable skill link: $link -> $target" >&2
        failed=1
    else
        unlink "$link"
    fi
done

[ "$failed" -eq 0 ] || exit 1
