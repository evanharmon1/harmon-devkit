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

# Refuse ambiguity before changing anything. A native portable skill remains
# untouched, but it cannot silently override a different Claude-managed skill
# with the same name.
for skill_dir in "$claude_dir"/*/; do
    [ -d "$skill_dir" ] || continue
    name="$(basename "${skill_dir%/}")"
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

# Remove only links this compatibility layer can prove it owns. Native skills
# and links to any other location are always preserved.
for link in "$portable_dir"/*; do
    [ -L "$link" ] || continue
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
