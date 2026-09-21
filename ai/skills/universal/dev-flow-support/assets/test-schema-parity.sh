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
# "Both directions" is enforced on the BYTES, not just on the name listings.
# Agreeing sorted basename lists are the precondition, never the verdict: every
# file in EACH tree must end up in a `cmp` pair, and the suite asserts that the
# number of pairs compared equals the file count of each tree independently. A
# listing that silently loses an entry therefore fails instead of reporting a
# green on files nobody compared.
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
#
# `basename` in a read loop rather than `find -printf`: `-printf` is a GNU
# extension that BSD/macOS `find` rejects, and these call sites are command
# substitutions under `set -euo pipefail`, so on macOS the suite would abort
# instead of comparing. Output is unchanged — sorted basenames, one per line.
list_schemas() {
    find "$1" -maxdepth 1 -type f -name '*.schema.json' |
        while IFS= read -r schema_path; do
            basename "$schema_path"
        done | LC_ALL=C sort
}

fail=0
err() {
    echo "  ✗ $*" >&2
    fail=1
}

NL=$'\n'

# count_schemas DIR — how many *.schema.json files the tree actually holds,
# counted from a NUL-delimited walk so a name is one file however it is spelled.
count_schemas() {
    local n=0 _path
    while IFS= read -r -d '' _path; do
        n=$((n + 1))
    done < <(find "$1" -maxdepth 1 -type f -name '*.schema.json' -print0)
    printf '%s' "$n"
    return 0
}

# assert_line_safe_names DIR LABEL — refuse a basename containing a newline.
#
# The listings above are line-oriented, so such a name splits into two phantom
# entries — identically in BOTH trees. The lists then compare EQUAL, and the
# per-file loop skips each fragment because no file by that fragment's name
# exists, so two genuinely differing files are reported byte-identical. That is
# a silent green on a gate wired into `task verify`, which is the one failure
# mode this suite must not have. Bash reads NUL-delimited names portably;
# `sort -z` would not be (GNU-only), so the name is rejected rather than sorted.
assert_line_safe_names() {
    local dir="$1" label="$2" _path _base
    while IFS= read -r -d '' _path; do
        _base="${_path##*/}"
        case "$_base" in
        *"$NL"*)
            err "$label holds a schema whose filename contains a newline — rename it; this suite compares by line and cannot represent it"
            ;;
        esac
    done < <(find "$dir" -maxdepth 1 -type f -name '*.schema.json' -print0)
}

assert_line_safe_names "$authoring_schemas" "ai/schemas/"
assert_line_safe_names "$package_schemas" "assets/schemas/"

authoring_list="$(list_schemas "$authoring_schemas")"
package_list="$(list_schemas "$package_schemas")"

authoring_count="$(count_schemas "$authoring_schemas")"
package_count="$(count_schemas "$package_schemas")"

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

# The byte comparison itself, and the proof that it covered both trees. Every
# name that exists on both sides is `cmp`-ed; `compared` counts the pairs. A
# name present on only one side was already reported by the membership loops
# above, so the coverage assertion that follows is about SKIPS nobody reported:
# if either tree holds a file that never entered a pair and no membership error
# explains it, the run fails rather than printing a count of files it never
# looked at.
compared=0
while IFS= read -r name; do
    [ -n "$name" ] || continue
    [ -f "$authoring_schemas/$name" ] && [ -f "$package_schemas/$name" ] || continue
    compared=$((compared + 1))
    cmp -s "$authoring_schemas/$name" "$package_schemas/$name" ||
        err "$name differs between ai/schemas/ and the package copy — mirror the authoring edit into assets/schemas/"
done <<<"$authoring_list"

if [ "$fail" -eq 0 ]; then
    [ "$compared" -eq "$authoring_count" ] ||
        err "byte-compared $compared pair(s) but ai/schemas/ holds $authoring_count schema(s) — some file was never compared"
    [ "$compared" -eq "$package_count" ] ||
        err "byte-compared $compared pair(s) but assets/schemas/ holds $package_count schema(s) — some file was never compared"
fi

if [ "$fail" -ne 0 ]; then
    echo "  ai/schemas/ is the authoring source of truth; assets/schemas/ is its byte-identical vendored copy." >&2
    echo "  Authoring tree (source of truth): $authoring_schemas" >&2
    echo "  Package copy (parity target):     $package_schemas" >&2
    echo "  Re-mirror BOTH directions — a copy alone cannot clear a stale schema the" >&2
    echo "  package still carries and the authoring tree has deleted:" >&2
    echo "    rm -f \"$package_schemas\"/*.schema.json" >&2
    echo "    cp \"$authoring_schemas\"/*.schema.json \"$package_schemas\"/" >&2
    exit 1
fi

echo "  ✓ $compared schema(s) byte-identical in both directions"
