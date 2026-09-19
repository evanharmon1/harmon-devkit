#!/usr/bin/env bash
# test-schema-parity.sh — assert this package's vendored `assets/schemas/` copy
# is byte-identical to the authoring source of truth, `ai/schemas/`.
#
# Why a copy at all (harmon-devkit#974, maintainer ruling 2): the validators in
# this package default their schemas directory to `assets/schemas/`, so a
# consumer that vendored only skills still has the schemas its own vendored
# validators validate against. The sync manifest's `schemas:` block stays
# OPTIONAL — this copy is what makes it optional. `ai/schemas/` remains the
# authoring source: its README, its conformance fixture corpus, and Foreman's
# reference all point there, and an edit is made there and mirrored here.
#
# Byte-identity is checked in BOTH directions. A one-way "every root schema
# also exists here and matches" check passes happily when the package carries
# an extra schema the root has since deleted — which is the drift that lets a
# vendored validator accept a shape the source of truth no longer describes.
#
# Where the authoring tree is absent — a consumer repository that vendored this
# package and has no `ai/schemas/` of its own — there is nothing to compare and
# the check SKIPS (exit 0). It is a source-tree guard riding along with the
# package, not a consumer-side requirement.
#
# Run via `task test:schema-parity`.
set -euo pipefail

asset_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
package_schemas="$asset_dir/schemas"

if ! repo_root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    echo "test-schema-parity: not inside a git checkout — nothing to compare" >&2
    exit 0
fi
repo_root="$(cd "$repo_root" && pwd -P)"
authoring_schemas="$repo_root/ai/schemas"

# Only compare when this package is the one that repository authors. A
# consumer's vendored copy lives outside its own `ai/` tree, so a same-named
# directory there is not this package's source and must not be diffed against.
case "$asset_dir" in
"$repo_root"/ai/skills/*) ;;
*)
    echo "==> schema parity: skipped (vendored copy at $asset_dir, not an authoring tree)"
    exit 0
    ;;
esac

if [ ! -d "$authoring_schemas" ]; then
    echo "==> schema parity: skipped ($authoring_schemas does not exist)"
    exit 0
fi

[ -d "$package_schemas" ] || {
    echo "  ✗ $package_schemas is missing — the package must carry its own schema copy" >&2
    exit 1
}

echo "==> schema parity: $authoring_schemas <-> $package_schemas"

# `ls` over a fixed glob rather than a recursive walk: both trees are flat by
# construction (the authoring tree's subdirectories are fixtures, which are a
# conformance corpus and deliberately NOT vendored).
list_schemas() {
    find "$1" -maxdepth 1 -type f -name '*.schema.json' -printf '%f\n' | LC_ALL=C sort
}

fail=0
err() {
    echo "  ✗ $*" >&2
    fail=1
}

authoring_list="$(list_schemas "$authoring_schemas")"
package_list="$(list_schemas "$package_schemas")"

[ -n "$authoring_list" ] || err "no *.schema.json found under $authoring_schemas"

if [ "$authoring_list" != "$package_list" ]; then
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        grep -qxF "$name" <<<"$package_list" ||
            err "ai/schemas/$name is not vendored into the package copy — add it to assets/schemas/"
    done <<<"$authoring_list"
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        grep -qxF "$name" <<<"$authoring_list" ||
            err "assets/schemas/$name has no counterpart in ai/schemas/ — the authoring tree is the source of truth"
    done <<<"$package_list"
fi

while IFS= read -r name; do
    [ -n "$name" ] || continue
    [ -f "$package_schemas/$name" ] || continue
    cmp -s "$authoring_schemas/$name" "$package_schemas/$name" ||
        err "$name differs between ai/schemas/ and the package copy — mirror the authoring edit into assets/schemas/"
done <<<"$authoring_list"

if [ "$fail" -ne 0 ]; then
    echo "  ai/schemas/ is the authoring source of truth; assets/schemas/ is its byte-identical vendored copy." >&2
    echo "  Re-mirror with: cp ai/schemas/*.schema.json schemas/" >&2
    exit 1
fi

count="$(wc -l <<<"$authoring_list" | tr -d ' ')"
echo "  ✓ $count schema(s) byte-identical in both directions"
