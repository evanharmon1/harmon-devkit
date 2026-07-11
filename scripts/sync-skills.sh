#!/usr/bin/env bash
# sync-skills.sh — pinned, pull-based vendoring of shared agent skills from
# harmon-devkit into a consumer repo. harmon-devkit is the single source of
# truth; a consumer declares what it wants in a manifest (default
# `.skills-sync.yaml`) and this script materialises exactly those skill
# categories, FLATTENED, into a destination directory, stamped with provenance.
#
# This file is meant to be COPIED into a consumer repo's `scripts/` (it is also
# unit-tested here, in harmon-devkit, against a throwaway local source repo).
# See templates/skills-sync/ for the manifest, Taskfile, CI, and Lefthook
# snippets that go with it.
#
# Usage:
#   sync-skills.sh sync            [MANIFEST]   # vendor the pinned skills
#   sync-skills.sh verify          [MANIFEST]   # authoritative drift check (clones)
#   sync-skills.sh verify-offline  [MANIFEST]   # fast offline ref check (no network)
#
# MANIFEST defaults to .skills-sync.yaml. Depends on: git, yq, diff, awk.
#
# Manifest schema:
#   source:
#     repo: https://github.com/evanharmon1/harmon-devkit.git
#     ref: v1.2.0            # pinned tag (or branch) — NOT a bare SHA
#     path: ai/skills        # optional; where skills live in the source (default)
#   categories: [universal, backend, frontend]
#   dest: .claude/skills     # fully managed by sync — do not hand-edit
set -euo pipefail

MANIFEST="${2:-.skills-sync.yaml}"

WORKDIR=""
# Keep the trap's own exit status at 0 — when WORKDIR is unset (the
# verify-offline path) a bare `[ -n "$WORKDIR" ] && rm` would return non-zero
# and clobber the script's real exit code.
cleanup() {
    [ -n "$WORKDIR" ] && rm -rf "$WORKDIR"
    return 0
}
trap cleanup EXIT

die() {
    echo "sync-skills: $*" >&2
    exit 1
}

manifest_get() {
    yq -r "$1" "$MANIFEST"
}

require_tools() {
    command -v git >/dev/null 2>&1 || die "git is required"
    command -v yq >/dev/null 2>&1 || die "yq is required (https://github.com/mikefarah/yq)"
    [ -f "$MANIFEST" ] || die "manifest '$MANIFEST' not found"
}

# vendor_into DEST — clone the pinned ref and materialise the requested
# categories (flattened) into DEST, replacing whatever was there.
vendor_into() {
    dest="$1"
    case "$dest" in
    "" | "/" | "." | "..") die "refusing to vendor into unsafe dest '$dest'" ;;
    esac

    src_repo="$(manifest_get '.source.repo')"
    ref="$(manifest_get '.source.ref')"
    src_path="$(manifest_get '.source.path // "ai/skills"')"
    [ -n "$src_repo" ] && [ "$src_repo" != "null" ] || die "manifest: .source.repo is required"
    [ -n "$ref" ] && [ "$ref" != "null" ] || die "manifest: .source.ref is required"

    clone="$WORKDIR/devkit"
    rm -rf "$clone"
    git clone --quiet --depth 1 --branch "$ref" "$src_repo" "$clone" ||
        die "git clone of $src_repo @ $ref failed (bad ref, or no read access?)"
    resolved="$(git -C "$clone" rev-parse HEAD)"

    skills_src="$clone/$src_path"
    [ -d "$skills_src" ] || die "source path '$src_path' not found in $src_repo @ $ref"

    rm -rf "$dest"
    mkdir -p "$dest"

    vendored_any=0
    while IFS= read -r cat; do
        [ -n "$cat" ] || continue
        catdir="$skills_src/$cat"
        [ -d "$catdir" ] || die "category '$cat' missing in $src_repo @ $ref"
        for skilldir in "$catdir"/*/; do
            [ -d "$skilldir" ] || continue           # empty category: glob stayed literal
            [ -f "${skilldir}SKILL.md" ] || continue # skip drafts/placeholders (no SKILL.md)
            name="$(basename "$skilldir")"
            [ -e "$dest/$name" ] && die "duplicate skill name '$name' across categories (dest is flattened)"
            cp -R "${skilldir%/}" "$dest/$name"
            vendored_any=1
        done
    done <<EOF
$(manifest_get '.categories[]')
EOF

    [ "$vendored_any" -eq 1 ] || die "no skills vendored — check 'categories' in $MANIFEST"

    {
        echo "# VENDORED from harmon-devkit — DO NOT EDIT HERE."
        echo "# source: $src_repo"
        echo "# ref: $ref ($resolved)"
        echo "# path: $src_path"
        echo "# categories: $(manifest_get '.categories | join(", ")')"
        echo "# update: edit $MANIFEST, then run 'task sync:skills' and commit."
    } >"$dest/.SKILLS_PROVENANCE"
}

cmd_sync() {
    require_tools
    WORKDIR="$(mktemp -d)"
    dest="$(manifest_get '.dest')"
    vendor_into "$dest"
    echo "vendored [$(manifest_get '.categories | join(", ")')] → $dest @ $(manifest_get '.source.ref')"
}

cmd_verify() {
    require_tools
    WORKDIR="$(mktemp -d)"
    real="$(manifest_get '.dest')"
    [ -d "$real" ] || die "no vendored skills at '$real' — run 'task sync:skills' first"
    vendor_into "$WORKDIR/vendor"
    if diff -r "$real" "$WORKDIR/vendor" >/dev/null 2>&1; then
        echo "✓ vendored skills in sync with $(manifest_get '.source.ref')"
    else
        echo "✗ vendored skills are OUT OF DATE vs $(manifest_get '.source.ref'):" >&2
        diff -r "$real" "$WORKDIR/vendor" >&2 || true
        echo "" >&2
        die "run 'task sync:skills' and commit the result."
    fi
}

cmd_verify_offline() {
    [ -f "$MANIFEST" ] || die "manifest '$MANIFEST' not found"
    command -v yq >/dev/null 2>&1 || die "yq is required"
    ref="$(manifest_get '.source.ref')"
    dest="$(manifest_get '.dest')"
    prov="$dest/.SKILLS_PROVENANCE"
    [ -f "$prov" ] || die "no provenance at '$prov' — run 'task sync:skills'"
    if grep -q "^# ref: ${ref} " "$prov"; then
        echo "✓ vendored ref matches manifest ($ref) — offline check"
    else
        die "manifest ref ($ref) != vendored ref — run 'task sync:skills' and commit"
    fi
}

case "${1:-}" in
sync) cmd_sync ;;
verify) cmd_verify ;;
verify-offline) cmd_verify_offline ;;
*)
    echo "usage: sync-skills.sh {sync|verify|verify-offline} [MANIFEST]" >&2
    exit 2
    ;;
esac
