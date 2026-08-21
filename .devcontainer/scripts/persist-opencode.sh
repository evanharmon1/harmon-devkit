#!/usr/bin/env bash
# Persist OpenCode's config and application data through Coder rebuilds.
set -euo pipefail

persistent_root="${1:?usage: persist-opencode.sh <persistent-root>}"

mkdir -p "$persistent_root" "$HOME/.config" "$HOME/.local/share"
for mapping in \
    ".config/opencode:opencode-config" \
    ".local/share/opencode:opencode-data"; do
    source_dir="$HOME/${mapping%%:*}"
    target_dir="$persistent_root/${mapping#*:}"
    mkdir -p "$target_dir"
    if [ -d "$source_dir" ] && [ ! -L "$source_dir" ]; then
        if ! cp -a "$source_dir/." "$target_dir/"; then
            echo "ERROR: OpenCode state migration from ${source_dir} failed;" \
                "fix the persistent volume and rebuild" >&2
            exit 1
        fi
        rm -rf "${source_dir:?}"
    fi
    ln -sfn "$target_dir" "$source_dir"
done
