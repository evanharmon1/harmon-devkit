#!/usr/bin/env bash
# sync-skills.sh — pinned, pull-based vendoring of shared agent skills from
# harmon-devkit into a consumer repo. harmon-devkit is the single source of
# truth; a consumer declares what it wants in a manifest (default
# `.skills-sync.yaml`) and this script materialises exactly those skill
# categories, FLATTENED, into a destination directory, stamped with provenance.
#
# The destination is SHARED with the repo's own local skills. The sync manages
# ONLY the skill directories it vendored — recorded on the provenance
# `# managed:` line. Any other directory in dest is a local skill: create,
# edit, and delete it like any normal `.claude/skills/<name>` — the sync and
# both verify modes never touch or report it. If a local directory's name
# collides with an incoming vendored skill, the sync dies before deleting
# anything (rename the local skill or drop the category from the manifest).
#
# Canonical home: harmon-init's template (rendered into every harmon-init repo);
# unit-tested in harmon-devkit (scripts/test-skills.sh). Change it there, not in
# a generated repo — local edits are overwritten on the next `copier update`.
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
#   dest: .claude/skills     # shared with local skills; sync manages only what it vendored
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

# assert_sane_name NAME — refuse path-traversal-shaped skill names before they
# reach an rm -rf / cp. Names come from the source tree and the provenance
# file, both repo-controlled, but a corrupted line must not become `rm -rf /`.
assert_sane_name() {
    case "$1" in
    "" | "." | ".." | */* | .*) die "refusing unsafe skill name '$1'" ;;
    esac
}

# list_skill_dirs DIR — names of the skill directories in DIR, one per line,
# sorted. Non-directories (.SKILLS_PROVENANCE, .gitkeep, …) never count.
list_skill_dirs() {
    _lsd_dir="$1"
    [ -d "$_lsd_dir" ] || return 0
    for _lsd_d in "$_lsd_dir"/*/; do
        [ -d "$_lsd_d" ] || continue # empty dir: glob stayed literal
        basename "${_lsd_d%/}"
    done | sort
}

# prov_field PROV FIELD — value of a `# FIELD: …` provenance header line.
prov_field() {
    sed -n "s/^# $2:[[:space:]]*//p" "$1" | head -n 1
}

# prov_list PROV FIELD — a comma-separated provenance field as a sorted
# one-per-line list (empty output for a missing line).
prov_list() {
    prov_field "$1" "$2" | tr ',' '\n' |
        sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' | sort || true
}

# clone_ref REF OUTDIR — shallow-clone the manifest source at REF into OUTDIR
# and echo the resolved commit sha.
clone_ref() {
    _cr_repo="$(manifest_get '.source.repo')"
    [ -n "$_cr_repo" ] && [ "$_cr_repo" != "null" ] || die "manifest: .source.repo is required"
    rm -rf "$2"
    # Pinned by tag -> the clone lands in detached HEAD by design; silence the
    # advice so it doesn't clutter CI logs.
    git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$1" "$_cr_repo" "$2" ||
        die "git clone of $_cr_repo @ $1 failed (bad ref, or no read access?)"
    git -C "$2" rev-parse HEAD
}

# vendor_categories CLONE CATEGORIES OUTDIR — materialise the named categories
# (newline list) from CLONE, flattened, into OUTDIR.
vendor_categories() {
    _vc_src="$1/$(manifest_get '.source.path // "ai/skills"')"
    [ -d "$_vc_src" ] || die "source path not found in the pinned clone ($_vc_src)"
    mkdir -p "$3"
    while IFS= read -r _vc_cat; do
        [ -n "$_vc_cat" ] || continue
        _vc_catdir="$_vc_src/$_vc_cat"
        [ -d "$_vc_catdir" ] || die "category '$_vc_cat' missing in the pinned source"
        # A category may legitimately be empty (e.g. 'universal' before it has
        # skills) — vendor whatever SKILL.md-bearing dirs it holds, if any.
        for _vc_skilldir in "$_vc_catdir"/*/; do
            [ -d "$_vc_skilldir" ] || continue           # empty category: glob stayed literal
            [ -f "${_vc_skilldir}SKILL.md" ] || continue # skip drafts/placeholders (no SKILL.md)
            _vc_name="$(basename "${_vc_skilldir%/}")"
            assert_sane_name "$_vc_name"
            [ -e "$3/$_vc_name" ] && die "duplicate skill name '$_vc_name' across categories (dest is flattened)"
            cp -R "${_vc_skilldir%/}" "$3/$_vc_name"
        done
    done <<EOF
$2
EOF
}

# managed_names PROV DEST — the vendored dir names the sync owns, one per
# line. Requires $WORKDIR/devkit to hold a clone of the CURRENT manifest ref
# (both callers clone before calling). Three provenance generations:
#   * no provenance file      -> nothing is managed (never synced)
#   * `# managed:` line       -> exactly that list
#   * legacy stamp (no line)  -> the old wholesale-managed model; everything it
#     vendored is managed. That set is "dirs in DEST that the OLD pin's
#     recorded `# categories:` shipped" — always computed from the provenance,
#     never the current manifest (whose ref AND categories may both have
#     changed since), so a local skill added AFTER a legacy sync is never
#     claimed. Unchanged ref reuses the existing clone; a moved ref costs one
#     extra shallow clone.
managed_names() {
    _mn_prov="$1" _mn_dest="$2"
    [ -f "$_mn_prov" ] || return 0
    if grep -q '^# managed:' "$_mn_prov"; then
        prov_list "$_mn_prov" "managed"
        return 0
    fi
    _mn_oldref="$(prov_field "$_mn_prov" "ref" | sed 's/ (.*//')"
    [ -n "$_mn_oldref" ] || die "provenance '$_mn_prov' has no '# ref:' line — re-run sync manually after inspecting $_mn_dest"
    if [ "$_mn_oldref" = "$(manifest_get '.source.ref')" ]; then
        _mn_oldclone="$WORKDIR/devkit" # same ref -> same content; reuse the clone
    else
        _mn_oldclone="$WORKDIR/oldref"
        clone_ref "$_mn_oldref" "$_mn_oldclone" >/dev/null
    fi
    _mn_oldvendor="$WORKDIR/oldvendor"
    vendor_categories "$_mn_oldclone" "$(prov_list "$_mn_prov" "categories")" "$_mn_oldvendor"
    _mn_oldnames="$(list_skill_dirs "$_mn_oldvendor")"
    # dirs actually present in dest ∩ what the old pin shipped
    while IFS= read -r _mn_name; do
        [ -n "$_mn_name" ] || continue
        [ -d "$_mn_dest/$_mn_name" ] && echo "$_mn_name"
    done <<EOF
$_mn_oldnames
EOF
    return 0
}

write_provenance() {
    _wp_managed_csv="$(echo "$2" | grep -v '^$' | paste -sd ',' - | sed 's/,/, /g' || true)"
    {
        echo "# VENDORED from harmon-devkit — DO NOT EDIT the managed skills here."
        echo "# source: $(manifest_get '.source.repo')"
        echo "# ref: $(manifest_get '.source.ref') ($3)"
        echo "# path: $(manifest_get '.source.path // "ai/skills"')"
        echo "# categories: $(manifest_get '.categories | join(", ")')"
        echo "# managed:${_wp_managed_csv:+ $_wp_managed_csv}"
        echo "# update: edit $MANIFEST, then run 'task sync:skills' and commit."
        echo "# Any directory NOT listed on '# managed:' is a local skill owned by this"
        echo "# repo — the sync never touches it."
    } >"$1"
}

cmd_sync() {
    require_tools
    WORKDIR="$(mktemp -d)"
    dest="$(manifest_get '.dest')"
    # dest is committed config (.skills-sync.yaml), but sync deletes paths under
    # it — so refuse anything that could reach outside the repo before any rm.
    case "$dest" in
    "" | "/" | "." | "..") die "refusing to vendor into unsafe dest '$dest'" ;;
    /*) die "refusing absolute dest '$dest' — .skills-sync.yaml dest must be repo-relative" ;;
    ../* | */../* | */..) die "refusing dest with a '..' traversal component: '$dest'" ;;
    esac
    ref="$(manifest_get '.source.ref')"
    [ -n "$ref" ] && [ "$ref" != "null" ] || die "manifest: .source.ref is required"

    resolved="$(clone_ref "$ref" "$WORKDIR/devkit")"
    vendor_categories "$WORKDIR/devkit" "$(manifest_get '.categories[]')" "$WORKDIR/vendor"
    incoming="$(list_skill_dirs "$WORKDIR/vendor")"

    prov="$dest/.SKILLS_PROVENANCE"
    if [ -f "$prov" ] && ! grep -q '^# managed:' "$prov"; then
        echo "sync-skills: legacy provenance stamp — computing the vendored set from the old pin, then upgrading the stamp"
    fi
    old_managed="$(managed_names "$prov" "$dest")"

    # Collision gate BEFORE any deletion: an existing dir that we do not own
    # and that an incoming skill wants is local work — never overwrite it.
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        if [ -e "$dest/$name" ] && ! printf '%s\n' "$old_managed" | grep -qxF "$name"; then
            die "local skill '$name' collides with an incoming vendored skill — rename the local dir or drop its category from $MANIFEST"
        fi
    done <<EOF
$incoming
EOF

    # Replace only what we own.
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        assert_sane_name "$name"
        rm -rf "${dest:?}/${name:?}"
    done <<EOF
$old_managed
EOF
    rm -f "$prov"
    mkdir -p "$dest"
    n=0
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        cp -R "$WORKDIR/vendor/$name" "$dest/$name"
        n=$((n + 1))
    done <<EOF
$incoming
EOF
    write_provenance "$prov" "$incoming" "$resolved"

    cats="$(manifest_get '.categories | join(", ")')"
    if [ "$n" -eq 0 ]; then
        echo "vendored [$cats] → $dest @ $ref (0 skills — categories are empty at this ref)"
    else
        echo "vendored $n skill(s) [$cats] → $dest @ $ref"
    fi
}

cmd_verify() {
    require_tools
    real="$(manifest_get '.dest')"
    prov="$real/.SKILLS_PROVENANCE"
    # Fresh scaffold / not synced yet: no provenance means nothing to drift-check.
    # Skip cleanly (no clone) so a new repo's CI and pre-push stay green until the
    # first `task sync:skills`.
    if [ ! -f "$prov" ]; then
        echo "verify:skills: not synced yet — skipping (run 'task sync:skills')"
        return 0
    fi
    ref="$(manifest_get '.source.ref')"
    if [ "$(prov_field "$prov" "ref" | sed 's/ (.*//')" != "$ref" ]; then
        die "vendored ref ($(prov_field "$prov" "ref" | sed 's/ (.*//')) != manifest ref ($ref) — run 'task sync:skills' and commit"
    fi

    WORKDIR="$(mktemp -d)"
    clone_ref "$ref" "$WORKDIR/devkit" >/dev/null
    vendor_categories "$WORKDIR/devkit" "$(manifest_get '.categories[]')" "$WORKDIR/vendor"
    incoming="$(list_skill_dirs "$WORKDIR/vendor")"
    managed="$(managed_names "$prov" "$real")"

    drift=0
    # Every pinned skill must be present and byte-identical.
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        if ! diff -r "$real/$name" "$WORKDIR/vendor/$name" >/dev/null 2>&1; then
            echo "✗ vendored skill '$name' differs from the pin:" >&2
            diff -r "$real/$name" "$WORKDIR/vendor/$name" >&2 || true
            drift=1
        fi
    done <<EOF
$incoming
EOF
    # A managed dir no longer shipped by the pin is a leftover to clean up.
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        if ! printf '%s\n' "$incoming" | grep -qxF "$name"; then
            echo "✗ '$name' is vendored (managed) but no longer shipped by the pin" >&2
            drift=1
        fi
    done <<EOF
$managed
EOF
    # Local skills — anything in dest that is neither managed nor incoming —
    # are deliberately NOT inspected.
    if [ "$drift" -ne 0 ]; then
        echo "" >&2
        die "run 'task sync:skills' and commit the result."
    fi
    echo "✓ vendored skills in sync with $ref (local skills untouched/ignored)"
}

cmd_verify_offline() {
    [ -f "$MANIFEST" ] || die "manifest '$MANIFEST' not found"
    # This runs as a pre-push hook on bare hosts too — a missing yq must not
    # block a push (CI still runs the networked check with yq installed;
    # `task install` / the Brewfile provide yq locally).
    if ! command -v yq >/dev/null 2>&1; then
        echo "verify:skills:offline: yq not installed — skipping (run 'task install'; CI still enforces the drift check)"
        return 0
    fi
    dest="$(manifest_get '.dest')"
    prov="$dest/.SKILLS_PROVENANCE"
    # Not synced yet -> skip cleanly (keeps fresh scaffolds green).
    if [ ! -f "$prov" ]; then
        echo "verify:skills:offline: not synced yet — skipping (run 'task sync:skills')"
        return 0
    fi
    ref="$(manifest_get '.source.ref')"
    # Compare extracted values — the ref is data, not a regex ('.' in semver
    # tags would otherwise match any character).
    if [ "$(prov_field "$prov" "ref" | sed 's/ (.*//')" = "$ref" ]; then
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
