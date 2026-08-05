#!/usr/bin/env bash
# meta-install.sh — move a .meta sidecar (a Bunch launcher or an Obsidian
# project note) into its system folder and leave a symlink behind in .meta/, so
# the file lives where its app expects it while staying visible in the repo.
# Run via `task util:bunch-install` / `task util:obsidian-install`; pair with
# `meta-create.sh`, which scaffolds the file this moves.
#
# The destination is a copier answer rendered into the Taskfile inside single
# quotes, so the shell never expands a leading `~`. Expanding it here — rather
# than in the Taskfile string — is what keeps the answer defaults free of any
# one user's absolute home path (see issue #552).
#
# There is deliberately no macOS platform check. Both destinations are macOS
# conventions in practice, but nothing here is macOS-specific — it moves a file
# and symlinks it back — and a `uname` gate would only replace the clear "that
# directory does not exist" failure with a less useful one, while making the
# whole script unexercised on this repo's Linux CI.
#
# Usage:
#   meta-install.sh bunch    <project_name> <bunches_directory>
#   meta-install.sh obsidian <project_name> <obsidian_directory>
set -euo pipefail

repo="$(git rev-parse --show-toplevel)"
cd "$repo"

fail() {
    echo "meta-install: $*" >&2
    exit 1
}

# Expand a leading `~` or `~/` to $HOME. A `~user/` prefix is left alone: we
# cannot resolve another user's home portably, and the answer is meant to point
# at the calling user's own directories.
expand_home() {
    case "$1" in
    "~") printf '%s\n' "$HOME" ;;
    "~/"*) printf '%s\n' "$HOME/${1#\~/}" ;;
    *) printf '%s\n' "$1" ;;
    esac
}

kind="${1:-}"

case "$kind" in
bunch)
    name="${2:?project name required}"
    dest_dir="$(expand_home "${3:?bunches directory required}")"
    file="Code Project - ${name}.bunch"
    ;;
obsidian)
    name="${2:?project name required}"
    dest_dir="$(expand_home "${3:?obsidian directory required}")"
    file="${name}.md"
    ;;
*)
    fail "usage: meta-install.sh {bunch|obsidian} <project_name> <destination_directory>"
    ;;
esac

src=".meta/${file}"

# The destination has to be absolute before it is used. `mv` resolves a relative
# path from the repo root (this script cd'd there), but the symlink written into
# .meta/ resolves the SAME text from .meta/ — so a relative answer like `vault`
# would move the file to <repo>/vault/ and then link to .meta/vault/, reporting
# success while leaving a dangling link. Canonicalising here also collapses a
# symlinked destination directory to its real path. The check comes first
# because `cd` needs the directory to exist.
if [ ! -d "$dest_dir" ]; then
    fail "destination directory does not exist: $dest_dir"
fi
dest_dir="$(cd "$dest_dir" && pwd -P)"
dest="${dest_dir}/${file}"

# Already installed: .meta/<file> is the symlink pointing at an existing dest.
if [ -L "$src" ] && [ "$(readlink "$src")" = "$dest" ] && [ -e "$dest" ]; then
    echo "meta-install: $src already links to $dest"
    exit 0
fi

# `-e` follows symlinks, so test for a link first: a dangling or misdirected
# symlink at .meta/<file> is a broken install, not a missing one.
if [ -L "$src" ]; then
    fail "$src is a symlink to $(readlink "$src"), not to $dest"
fi
if [ ! -e "$src" ]; then
    fail "$src not found — run 'task util:${kind}-add' first"
fi
# `-L` as well as `-e`: a DANGLING symlink at the destination is something that
# already exists and would be silently clobbered by `mv`, but `-e` follows the
# link and reports false. A vault or cloud-synced folder going missing leaves
# exactly that state behind.
if [ -e "$dest" ] || [ -L "$dest" ]; then
    fail "$dest already exists"
fi

mv "$src" "$dest"

# Put the file back if the backlink cannot be created — otherwise the sidecar
# has left .meta/ and a re-run cannot repair it (the source is gone and the
# destination now exists, which is the refusal case above). A repo on a
# filesystem without symlink support hits this.
if ! ln -s "$dest" "$src"; then
    mv "$dest" "$src" || fail "could not symlink $src, AND could not move $dest back — the file is at $dest"
    fail "could not create the symlink at $src — $file was left in .meta/"
fi
echo "meta-install: moved $file to $dest_dir and linked it back into .meta/"
