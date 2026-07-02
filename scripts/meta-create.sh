#!/usr/bin/env bash
# meta-create.sh — scaffold a project's .meta sidecar (a Bunch launcher or an
# Obsidian project note) for a repo where it was not generated at copier time.
# The emitted content mirrors template/.meta/, so a project can opt into a Bunch
# or Obsidian note after the fact. Run via `task util:bunch-add` /
# `task util:obsidian-add`; pair with `util:*-install` to move the file into its
# system folder and symlink it back into .meta.
#
# Usage:
#   meta-create.sh bunch    <project_name> <project_slug> <projects_directory>
#   meta-create.sh obsidian <project_name> <author_full_name>
set -euo pipefail

repo="$(git rev-parse --show-toplevel)"
cd "$repo"

fail() {
    echo "meta-create: $*" >&2
    exit 1
}

kind="${1:-}"
mkdir -p .meta

case "$kind" in
bunch)
    name="${2:?project name required}"
    slug="${3:?project slug required}"
    projects_dir="${4:?projects directory required}"
    dest=".meta/Code Project - ${name}.bunch"
    if [ -e "$dest" ]; then
        fail "$dest already exists"
    fi
    cat >"$dest" <<EOF
---
title: Code Project - ${name} 🪛
---
< snippet.code

\$ open -a 'Visual Studio Code' ${projects_dir}/${slug}/${slug}.code-workspace
%Visual Studio Code^

< snippet.maximize
EOF
    ;;
obsidian)
    name="${2:?project name required}"
    author="${3:?author full name required}"
    today="$(date +%Y-%m-%d)"
    dest=".meta/${name}.md"
    if [ -e "$dest" ]; then
        fail "$dest already exists"
    fi
    cat >"$dest" <<EOF
---
aliases:
tags:
  - Type/Intent/Project
  - seed
publish: false
status:
due:
priority:
version: 1.1
dateCreated: ${today}
dateModified: ${today}
startDate:
by: "[[${author}|Me]]"
for:
of:
from:

  - "[[Projects]]"
  - "[[Professional]]"
related: []
contra: []
to: []
---
# ${name}

## Inbox
EOF
    ;;
*)
    fail "usage: meta-create.sh {bunch|obsidian} <project_name> [args...]"
    ;;
esac

echo "meta-create: wrote $dest"
