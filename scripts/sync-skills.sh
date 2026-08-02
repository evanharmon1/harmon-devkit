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
#   agents:                  # OPTIONAL — omit the block entirely and nothing changes
#     names: [implementer]   # explicit list, or ["*"] for every agent at the pin
#     path: ai/agents        # optional; where agents live in the source (default)
#     dest: .claude/agents   # shared with local agents, same managed-set rule
#
# Agents ride the SAME manifest and therefore the same pinned ref as skills.
# That is deliberate: a shared agent is thin and defers to a skill by reading it
# (`.claude/skills/<name>/SKILL.md`), so a version skew between the two would
# leave an agent following a procedure that no longer exists. One ref, one
# `task sync:skills`, both kinds of asset.
#
# Agents are single Markdown files, flat, so the agents pass has no categories
# and no legacy-stamp migration — it is the simpler twin of the skills pass, not
# a copy of it. The two never share a destination (refused below), so each owns
# its own provenance file and managed set.
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

# agents_enabled — 0 when the manifest carries an `agents:` block. A manifest
# without one behaves exactly as it did before agents existed.
agents_enabled() {
    _ae="$(manifest_get '.agents')"
    [ -n "$_ae" ] && [ "$_ae" != "null" ]
}

# repo_has_synced — 0 when this repo has run at least one sync, proven by EITHER
# provenance stamp existing.
#
# The "not synced yet, skip cleanly" rule exists for a FRESH SCAFFOLD, so that a
# newly generated repo's CI and pre-push stay green before its first sync. A
# fresh scaffold has neither stamp. Once either one exists, a missing stamp for
# an asset kind the manifest requests is drift, not newness.
#
# Asked symmetrically on purpose: guarding one direction only moves the hole
# rather than closing it. Making the agents skip conditional on the skills stamp
# (and not the reverse) left a repo that had synced both, then lost its vendored
# skills, passing every check — the agents stamp proved a sync had run, and
# nothing consulted it.
repo_has_synced() {
    [ -f "$(manifest_get '.dest')/.SKILLS_PROVENANCE" ] && return 0
    if agents_enabled; then
        [ -f "$(agents_dest)/.AGENTS_PROVENANCE" ] && return 0
    fi
    return 1
}

# normalize_path PATH — the canonical spelling of a repo-relative path, for
# comparing two of them.
#
# Rebuilt from components rather than pattern-substituted, because the substring
# approach is only ever an approximation: `a/./././b` defeats a single global
# `s#/\./#/#g` (the matches overlap), and each new alias shape needs another
# rule. Component rebuild is complete by construction.
#
# NOT canonicalization — no symlink resolution, no filesystem access, and `..`
# is deliberately PRESERVED so assert_safe_dest still sees and rejects it.
# What is dropped is exactly the set that names the same directory: `.`
# components, empty components from `//`, and a trailing slash.
normalize_path() {
    _np_out=""
    _np_in="$1"
    # Preserve absolute-ness. An absolute path's leading `/` produces an EMPTY
    # first component, which the loop drops like any other — silently turning
    # `/etc/agents` into `etc/agents`, a relative path that assert_safe_dest is
    # then happy to accept. Caught by the pre-existing unsafe-dest tests.
    _np_abs=""
    case "$_np_in" in
    /*) _np_abs="/" ;;
    esac
    while [ -n "$_np_in" ]; do
        _np_seg="${_np_in%%/*}"
        case "$_np_in" in
        */*) _np_in="${_np_in#*/}" ;;
        *) _np_in="" ;;
        esac
        case "$_np_seg" in
        "" | ".") continue ;;
        esac
        _np_out="${_np_out:+$_np_out/}$_np_seg"
    done
    printf '%s' "$_np_abs$_np_out"
}

# assert_safe_dest DEST KIND — refuse a destination that could reach outside the
# repo. Both passes delete paths under their dest, so this runs before any rm.
assert_safe_dest() {
    case "$1" in
    "" | "/" | "." | "..") die "refusing to vendor $2 into unsafe dest '$1'" ;;
    /*) die "refusing absolute $2 dest '$1' — $MANIFEST dest must be repo-relative" ;;
    ../* | */../* | */..) die "refusing $2 dest with a '..' traversal component: '$1'" ;;
    esac
}

# list_agent_names DIR — names (basename minus .md) of the agent files in DIR,
# one per line, sorted. Non-files and the provenance stamp never count.
list_agent_names() {
    _lan_dir="$1"
    [ -d "$_lan_dir" ] || return 0
    for _lan_f in "$_lan_dir"/*.md; do
        [ -f "$_lan_f" ] || continue # empty dir: glob stayed literal
        basename "$_lan_f" .md
    done | sort
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

# assert_agents_names — require `.agents.names` to be a YAML SEQUENCE.
#
# This is a data-loss guard, not a tidiness check. `yq '.agents.names[]'` exits
# 0 and prints NOTHING when the key is missing or holds a scalar — so
# `names: "*"`, the natural mis-spelling of `names: ["*"]`, would resolve the
# incoming set to empty, and the pass would then delete every agent it manages,
# write an empty `# managed:` stamp, and exit 0. `verify` would agree
# afterwards, because an empty managed set really is in sync with an empty
# incoming set. The typo destroys the vendored agents and every check reports
# success.
#
# A mapping is refused for the same reason it is dangerous: `[]` over a mapping
# iterates its VALUES, so `names: {a: b}` silently means `[b]`.
#
# An explicit empty sequence is allowed — `names: []` is an unambiguous "vendor
# no agents", the same way an empty `categories` list vendors no skills. What is
# refused is a shape that *reads* as a request and *resolves* as nothing.
assert_agents_names() {
    _aan_type="$(manifest_get '.agents.names | type')"
    case "$_aan_type" in
    '!!seq') return 0 ;;
    '!!null')
        die "manifest: agents.names is required when an 'agents:' block is present (use [] to vendor none)"
        ;;
    *)
        die "manifest: agents.names must be a list, got $_aan_type — write names: [\"*\"], not names: \"*\""
        ;;
    esac
}

# vendor_agents CLONE NAMES OUTDIR — materialise the named agents (newline
# list, or the single entry `*` meaning every agent at the pin) from CLONE,
# flat, into OUTDIR.
vendor_agents() {
    _va_src="$1/$(manifest_get '.agents.path // "ai/agents"')"
    [ -d "$_va_src" ] || die "agents path not found in the pinned clone ($_va_src)"
    mkdir -p "$3"
    # The wildcard is resolved BEFORE assert_sane_name, which rejects `*` as an
    # unsafe name — it is a manifest sentinel, never a filename.
    if printf '%s\n' "$2" | grep -qxF '*'; then
        [ "$(printf '%s\n' "$2" | grep -cv '^$')" -eq 1 ] ||
            die "manifest: agents.names is either [\"*\"] (every agent) or an explicit list, not both"
        for _va_f in "$_va_src"/*.md; do
            [ -f "$_va_f" ] || continue # no agents at this ref: glob stayed literal
            _va_n="$(basename "$_va_f" .md)"
            [ "$_va_n" = "README" ] && continue # documents the dir, is not an agent
            cp "$_va_f" "$3/$_va_n.md"
        done
        return 0
    fi
    while IFS= read -r _va_name; do
        [ -n "$_va_name" ] || continue
        assert_sane_name "$_va_name"
        [ "$_va_name" = "README" ] &&
            die "'README' is the agents directory's own doc, not an agent — drop it from $MANIFEST"
        [ -f "$_va_src/$_va_name.md" ] ||
            die "agent '$_va_name' missing in the pinned source ($_va_src/$_va_name.md)"
        cp "$_va_src/$_va_name.md" "$3/$_va_name.md"
    done <<EOF
$2
EOF
}

# agents_managed_names PROV — the vendored agent names the sync owns, one per
# line. Simpler than the skills equivalent: agents shipped with the `# managed:`
# line from their first release, so there is no legacy generation to reconstruct
# from an older pin. A stamp without the line is therefore not an old format —
# it is damage, and guessing what it owned could delete a local agent.
agents_managed_names() {
    [ -f "$1" ] || return 0
    grep -q '^# managed:' "$1" ||
        die "agents provenance '$1' has no '# managed:' line — inspect it by hand before re-syncing"
    prov_list "$1" "managed"
}

write_agents_provenance() {
    _wap_csv="$(echo "$2" | grep -v '^$' | paste -sd ',' - | sed 's/,/, /g' || true)"
    {
        echo "# VENDORED from harmon-devkit — DO NOT EDIT the managed agents here."
        echo "# source: $(manifest_get '.source.repo')"
        echo "# ref: $(manifest_get '.source.ref') ($3)"
        echo "# path: $(manifest_get '.agents.path // "ai/agents"')"
        echo "# names: $(manifest_get '.agents.names | join(", ")')"
        echo "# managed:${_wap_csv:+ $_wap_csv}"
        echo "# update: edit $MANIFEST, then run 'task sync:skills' and commit."
        echo "# Any file NOT listed on '# managed:' is a local agent owned by this"
        echo "# repo — the sync never touches it."
    } >"$1"
}

write_provenance() {
    _wp_managed_csv="$(echo "$2" | grep -v '^$' | paste -sd ',' - | sed 's/,/, /g' || true)"
    {
        echo "# VENDORED from harmon-devkit — DO NOT EDIT the managed skills here."
        echo "# source: $(manifest_get '.source.repo')"
        echo "# ref: $(manifest_get '.source.ref') ($3)"
        echo "# path: $(manifest_get '.source.path // "ai/skills"')"
        echo "# categories: $(manifest_get '.categories | join(", ")')"
        # Breadcrumb for de-vendoring. `agents.dest` lives INSIDE the optional
        # agents block, so deleting that block also deletes the only record of
        # where the agents went — leaving vendored files that claim to be
        # managed, with nothing able to find them. The skills stamp is always
        # findable (`dest` is top-level and required), so it carries the pointer.
        echo "# agents-dest:${4:+ $4}"
        echo "# managed:${_wp_managed_csv:+ $_wp_managed_csv}"
        echo "# update: edit $MANIFEST, then run 'task sync:skills' and commit."
        echo "# Any directory NOT listed on '# managed:' is a local skill owned by this"
        echo "# repo — the sync never touches it."
    } >"$1"
}

# agents_dest — the validated agents destination. Also refuses sharing the
# skills dest: two independent managed sets over one directory would each have
# to reason about the other's deletions, and that is a correctness argument
# worth not having.
agents_dest() {
    _ad="$(manifest_get '.agents.dest')"
    [ -n "$_ad" ] && [ "$_ad" != "null" ] || die "manifest: agents.dest is required when an 'agents:' block is present"
    _ad="$(normalize_path "$_ad")"
    assert_safe_dest "$_ad" "agents"
    # Not just inequality — NON-OVERLAP. Either dest containing the other is the
    # same hazard as sharing one: the skills pass does `rm -rf` on a managed
    # skill directory, so an agents dest nested inside one is deleted wholesale
    # (stamp, managed agents, and any LOCAL agent parked there) on every sync,
    # and agent files inside a skill directory fail skill verification anyway.
    # Trailing slashes are stripped so `vend/skills/` and `vend/skills` cannot
    # spell the same directory two ways and slip past a string compare.
    # Normalize before comparing: `./vend/skills/x` and `vend/skills/x` name the
    # same directory, and only the second was caught by a string compare.
    _ad="$(normalize_path "$_ad")"
    _sd="$(normalize_path "$(manifest_get '.dest')")"
    case "$_ad" in
    "$_sd" | "$_sd"/*)
        die "manifest: agents.dest ('$_ad') must not be the skills dest or live inside it — each pass owns its own directory"
        ;;
    esac
    case "$_sd" in
    "$_ad"/*)
        die "manifest: the skills dest ('$_sd') lives inside agents.dest ('$_ad') — each pass owns its own directory"
        ;;
    esac
    echo "$_ad"
}

# orphaned_agents_dest PROV — echo the agents dest recorded on a skills stamp
# whose manifest no longer requests agents, when agents are still vendored
# there. Empty when there is nothing to de-vendor.
#
# Only ever called with agents DISABLED, so the dest cannot come from the
# manifest — it comes from the stamp, which is why the breadcrumb exists. It is
# validated like any other dest before anything deletes under it: the stamp is
# committed config, but a corrupted line must not become an rm.
orphaned_agents_dest() {
    [ -f "$1" ] || return 0
    _oad="$(prov_field "$1" "agents-dest")"
    [ -n "$_oad" ] || return 0
    _oad="$(normalize_path "$_oad")"
    [ -f "$_oad/.AGENTS_PROVENANCE" ] || return 0
    echo "$_oad"
}

# assert_orphan_usable DEST — validate a de-vendor target, in PARENT context.
#
# Deliberately not inside orphaned_agents_dest, which runs inside `$( )`. `die`
# there exits only the subshell: the message prints, the caller's `[ -n "$x" ]
# || return 0` reads the empty result as "nothing to do", and the run continues
# reporting success. Observed exactly that — a damaged orphan stamp printed its
# error, the sync exited 0, and the skills stamp was rewritten with an empty
# breadcrumb, leaving agents no later run could find.
#
# So the checks that must ABORT live here, where the shell is the parent and
# `die` means what it says, and they run before the skills pass mutates
# anything.
assert_orphan_usable() {
    assert_safe_dest "$1" "orphaned agents"
    _aou_prov="$1/.AGENTS_PROVENANCE"
    grep -q '^# managed:' "$_aou_prov" ||
        die "agents provenance '$_aou_prov' has no '# managed:' line — inspect it by hand before re-syncing"
    # Every NAME too, not just the line's presence. devendor_agents validates
    # each name before its `rm`, which is correct but too late: by then the
    # skills stamp carries an empty breadcrumb, so aborting there leaves agents
    # no later run can find. Validating here — parent context, pre-mutation —
    # means a stamp carrying `../bad` aborts with the pointer still intact.
    while IFS= read -r _aou_n; do
        [ -n "$_aou_n" ] || continue
        assert_sane_name "$_aou_n"
    done <<EOF
$(prov_list "$_aou_prov" "managed")
EOF
}

# stale_agents_dest PROV CURRENT — the agents dest a previous sync used and this
# one no longer will, when agents are still vendored there. Empty when there is
# nothing to clean up. CURRENT is the dest this run will use, or empty when the
# manifest no longer requests agents at all.
#
# Moving `agents.dest` is the same stranding bug as deleting the block, one
# variant over: the pass would vendor into the new location, leave the old one
# untouched, and both verify modes would inspect only the new one and pass. The
# old copy stays on disk, still stamped, still loaded by the harness.
stale_agents_dest() {
    _sad="$(orphaned_agents_dest "$1")"
    [ -n "$_sad" ] || return 0
    [ "$_sad" != "$(normalize_path "$2")" ] || return 0
    echo "$_sad"
}

# devendor_agents DEST — remove the agents this sync previously managed, plus
# their stamp, after the manifest stopped requesting them.
#
# A vendoring tool needs an un-vendoring path. Without one, deleting the
# `agents:` block silently stranded every vendored agent: still on disk, still
# loaded by the harness, still stamped DO NOT EDIT, pinned to a ref nothing will
# ever bump, and invisible to both drift checks. Deletes only what the stamp's
# `# managed:` line claims — a local agent in the same directory is untouched,
# exactly as during a normal sync.
devendor_agents() {
    _dv_prov="$1/.AGENTS_PROVENANCE"
    _dv_managed="$(agents_managed_names "$_dv_prov")"
    _dv_n=0
    while IFS= read -r _dv_name; do
        [ -n "$_dv_name" ] || continue
        assert_sane_name "$_dv_name"
        rm -f "${1:?}/${_dv_name:?}.md"
        _dv_n=$((_dv_n + 1))
    done <<EOF
$_dv_managed
EOF
    rm -f "$_dv_prov"
    echo "de-vendored $_dv_n agent(s) from $1 — ${2:-the manifest no longer requests agents}"
}

# agents_preflight CLONE — resolve and validate everything the agents pass
# needs, WITHOUT mutating anything. Every way the pass can die lives here, so
# cmd_sync can run it before the skills pass starts deleting.
#
# Ordering matters more than it looks. Both kinds of asset are pinned to one ref
# precisely so a consumer cannot end up with skills at the new pin and agents at
# the old one; a sync that replaced skills and then died on an agent collision
# would create that exact skew, while reporting failure. Preflighting keeps the
# run all-or-nothing up to the point where only I/O can fail.
#
# Results land in _AGP_* globals for agents_apply.
agents_preflight() {
    _AGP_DEST="$(agents_dest)"
    _AGP_PROV="$_AGP_DEST/.AGENTS_PROVENANCE"
    assert_agents_names
    vendor_agents "$1" "$(manifest_get '.agents.names[]')" "$WORKDIR/vendor-agents"
    _AGP_INCOMING="$(list_agent_names "$WORKDIR/vendor-agents")"
    _AGP_MANAGED="$(agents_managed_names "$_AGP_PROV")"

    # Collision gate: a file we do not own that an incoming agent wants is local
    # work. Checked here, before ANY deletion anywhere in the run.
    while IFS= read -r _agp_name; do
        [ -n "$_agp_name" ] || continue
        if [ -e "$_AGP_DEST/$_agp_name.md" ] && ! printf '%s\n' "$_AGP_MANAGED" | grep -qxF "$_agp_name"; then
            die "local agent '$_agp_name' collides with an incoming vendored agent — rename the local file or drop it from $MANIFEST"
        fi
    done <<EOF
$_AGP_INCOMING
EOF
    # Names about to be rm'd are validated here too, for the same reason.
    while IFS= read -r _agp_name; do
        [ -n "$_agp_name" ] || continue
        assert_sane_name "$_agp_name"
    done <<EOF
$_AGP_MANAGED
EOF
}

# agents_apply RESOLVED_SHA — mutate the agents dest using what
# agents_preflight resolved. Replaces only what this sync owns.
agents_apply() {
    _sa_dest="$_AGP_DEST"
    _sa_prov="$_AGP_PROV"
    _sa_incoming="$_AGP_INCOMING"
    _sa_managed="$_AGP_MANAGED"

    while IFS= read -r _sa_name; do
        [ -n "$_sa_name" ] || continue
        assert_sane_name "$_sa_name"
        rm -f "${_sa_dest:?}/${_sa_name:?}.md"
    done <<EOF
$_sa_managed
EOF
    rm -f "$_sa_prov"
    mkdir -p "$_sa_dest"
    _sa_n=0
    while IFS= read -r _sa_name; do
        [ -n "$_sa_name" ] || continue
        cp "$WORKDIR/vendor-agents/$_sa_name.md" "$_sa_dest/$_sa_name.md"
        _sa_n=$((_sa_n + 1))
    done <<EOF
$_sa_incoming
EOF
    write_agents_provenance "$_sa_prov" "$_sa_incoming" "$1"
    echo "vendored $_sa_n agent(s) → $_sa_dest @ $(manifest_get '.source.ref')"
}

cmd_sync() {
    require_tools
    WORKDIR="$(mktemp -d)"
    dest="$(manifest_get '.dest')"
    # dest is committed config (.skills-sync.yaml), but sync deletes paths under
    # it — so refuse anything that could reach outside the repo before any rm.
    assert_safe_dest "$dest" "skills"
    # Validate the agents dest too, before the skills pass starts deleting: a
    # manifest that would be rejected halfway through should be rejected before
    # anything is removed.
    if agents_enabled; then agents_dest >/dev/null; fi
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

    # Capture the de-vendor breadcrumb BEFORE anything rewrites the stamp. The
    # skills pass deletes and re-writes $prov further down, and the new stamp is
    # written with an empty `# agents-dest:` (agents are disabled on this path) —
    # so reading it afterwards would always find nothing to de-vendor, and the
    # orphaned agents would survive the very run meant to remove them.
    # Covers BOTH stranding cases: the block removed entirely, and agents.dest
    # moved while the block stays. Either way the previous location is only
    # recoverable from the breadcrumb, which the skills pass is about to erase.
    if agents_enabled; then
        _cs_orphan="$(stale_agents_dest "$prov" "$(agents_dest)")"
    else
        _cs_orphan="$(stale_agents_dest "$prov" "")"
    fi
    [ -z "$_cs_orphan" ] || assert_orphan_usable "$_cs_orphan"

    # Preflight the agents pass while the tree is still untouched. Everything
    # that can make it die — a name absent at the pin, a corrupt stamp, a
    # collision with a local agent — is resolved here, so the run cannot replace
    # skills and then fail, leaving the two kinds of asset at different pins.
    if agents_enabled; then agents_preflight "$WORKDIR/devkit"; fi

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
    if agents_enabled; then
        write_provenance "$prov" "$incoming" "$resolved" "$(agents_dest)"
    else
        write_provenance "$prov" "$incoming" "$resolved"
    fi

    cats="$(manifest_get '.categories | join(", ")')"
    if [ "$n" -eq 0 ]; then
        echo "vendored [$cats] → $dest @ $ref (0 skills — categories are empty at this ref)"
    else
        echo "vendored $n skill(s) [$cats] → $dest @ $ref"
    fi

    if [ -n "$_cs_orphan" ]; then
        if agents_enabled; then
            devendor_agents "$_cs_orphan" "agents.dest moved to $(agents_dest)"
        else
            devendor_agents "$_cs_orphan"
        fi
    fi
    if agents_enabled; then agents_apply "$resolved"; fi
}

# verify_agents_pass CLONE — drift-check the vendored agents against the pin.
# Requires CLONE to hold a clone of the manifest ref. Dies on drift.
verify_agents_pass() {
    _vap_dest="$(agents_dest)"
    _vap_prov="$_vap_dest/.AGENTS_PROVENANCE"
    _vap_stale="$(stale_agents_dest "$(manifest_get '.dest')/.SKILLS_PROVENANCE" "$_vap_dest")"
    if [ -n "$_vap_stale" ]; then
        assert_orphan_usable "$_vap_stale"
        die "agents are still vendored in $_vap_stale but agents.dest is now $_vap_dest — run 'task sync:skills' to de-vendor the old location, and commit"
    fi
    if [ ! -f "$_vap_prov" ]; then
        # "Not synced yet" is only benign on a repo that has never synced at
        # all. Where the SKILLS stamp exists, this repo has run the sync — so a
        # missing agents stamp means the `agents:` block was added and never
        # applied, and skipping would let agent adoption pass CI with no agent
        # files committed. That is exactly the drift this feature exists to
        # catch, so it fails instead.
        if repo_has_synced; then
            die "manifest requests agents but none are vendored ($_vap_prov missing) — run 'task sync:skills' and commit"
        fi
        echo "verify:skills: agents not synced yet — skipping (run 'task sync:skills')"
        return 0
    fi
    _vap_ref="$(manifest_get '.source.ref')"
    _vap_pinned="$(prov_field "$_vap_prov" "ref" | sed 's/ (.*//')"
    [ "$_vap_pinned" = "$_vap_ref" ] ||
        die "vendored agents ref ($_vap_pinned) != manifest ref ($_vap_ref) — run 'task sync:skills' and commit"

    assert_agents_names
    vendor_agents "$1" "$(manifest_get '.agents.names[]')" "$WORKDIR/vendor-agents"
    _vap_incoming="$(list_agent_names "$WORKDIR/vendor-agents")"
    _vap_managed="$(agents_managed_names "$_vap_prov")"

    _vap_drift=0
    while IFS= read -r _vap_n; do
        [ -n "$_vap_n" ] || continue
        if ! diff "$_vap_dest/$_vap_n.md" "$WORKDIR/vendor-agents/$_vap_n.md" >/dev/null 2>&1; then
            echo "✗ vendored agent '$_vap_n' differs from the pin:" >&2
            diff "$_vap_dest/$_vap_n.md" "$WORKDIR/vendor-agents/$_vap_n.md" >&2 || true
            _vap_drift=1
        fi
    done <<EOF
$_vap_incoming
EOF
    # A managed agent no longer named by the manifest is a leftover to clean up.
    while IFS= read -r _vap_n; do
        [ -n "$_vap_n" ] || continue
        if ! printf '%s\n' "$_vap_incoming" | grep -qxF "$_vap_n"; then
            echo "✗ '$_vap_n' is vendored (managed) but no longer shipped by the pin" >&2
            _vap_drift=1
        fi
    done <<EOF
$_vap_managed
EOF
    if [ "$_vap_drift" -ne 0 ]; then
        echo "" >&2
        die "run 'task sync:skills' and commit the result."
    fi
    echo "✓ vendored agents in sync with $_vap_ref (local agents untouched/ignored)"
}

cmd_verify() {
    require_tools
    real="$(manifest_get '.dest')"
    prov="$real/.SKILLS_PROVENANCE"
    # Fresh scaffold / not synced yet: no provenance means nothing to drift-check.
    # Skip cleanly (no clone) so a new repo's CI and pre-push stay green until the
    # first `task sync:skills`. The agents pass is still evaluated below — the
    # two are stamped independently, so "skills not synced" must not silently
    # skip an agents drift check.
    if [ ! -f "$prov" ]; then
        if repo_has_synced; then
            die "manifest requests skills but none are vendored ($prov missing) — run 'task sync:skills' and commit"
        fi
        # Nothing is stamped, so nothing can have drifted — return WITHOUT
        # cloning. The clean skip is documented as costing no network, and a
        # fresh scaffold's ref is often still a placeholder: cloning here would
        # fail verify on an unreachable source before the repo's first sync,
        # which is precisely the state the skip exists to keep green.
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

    if agents_enabled; then
        verify_agents_pass "$WORKDIR/devkit"
    else
        _cv_orphan="$(stale_agents_dest "$prov" "")"
        if [ -n "$_cv_orphan" ]; then
            assert_orphan_usable "$_cv_orphan"
            die "agents are still vendored in $_cv_orphan but the manifest no longer requests them — run 'task sync:skills' to de-vendor, and commit"
        fi
    fi
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
    ref="$(manifest_get '.source.ref')"
    # Not synced yet -> skip cleanly (keeps fresh scaffolds green).
    if [ ! -f "$prov" ]; then
        if repo_has_synced; then
            die "manifest requests skills but none are vendored ($prov missing) — run 'task sync:skills' and commit"
        fi
        echo "verify:skills:offline: not synced yet — skipping (run 'task sync:skills')"
    # Compare extracted values — the ref is data, not a regex ('.' in semver
    # tags would otherwise match any character).
    elif [ "$(prov_field "$prov" "ref" | sed 's/ (.*//')" = "$ref" ]; then
        echo "✓ vendored ref matches manifest ($ref) — offline check"
    else
        die "manifest ref ($ref) != vendored ref — run 'task sync:skills' and commit"
    fi

    # Stranded agents FIRST. cmd_verify checks this too, and an asymmetry
    # between the modes would have the pre-push hook wave through exactly what
    # CI then rejects. Ordered ahead of the per-dest checks below because both
    # can fire on a moved dest, and "files are stranded at the old location" is
    # the one that tells you what to do — "none are vendored here" is true but
    # says nothing about the copy still on disk.
    if agents_enabled; then
        _cvo_stale="$(stale_agents_dest "$prov" "$(agents_dest)")"
    else
        _cvo_stale="$(stale_agents_dest "$prov" "")"
    fi
    if [ -n "$_cvo_stale" ]; then
        assert_orphan_usable "$_cvo_stale"
        die "agents are still vendored in $_cvo_stale but the manifest no longer points there — run 'task sync:skills' to de-vendor, and commit"
    fi

    # Agents are stamped independently, so their ref is checked independently —
    # bumping the manifest and re-syncing only skills must not pass this hook.
    if agents_enabled; then
        _cvo_aprov="$(agents_dest)/.AGENTS_PROVENANCE"
        if [ ! -f "$_cvo_aprov" ]; then
            # Same rule as the networked check: benign only before the repo's
            # first sync, drift once the skills stamp proves it has run one.
            ! repo_has_synced ||
                die "manifest requests agents but none are vendored ($_cvo_aprov missing) — run 'task sync:skills' and commit"
            echo "verify:skills:offline: agents not synced yet — skipping (run 'task sync:skills')"
        elif [ "$(prov_field "$_cvo_aprov" "ref" | sed 's/ (.*//')" = "$ref" ]; then
            echo "✓ vendored agents ref matches manifest ($ref) — offline check"
        else
            die "manifest ref ($ref) != vendored agents ref — run 'task sync:skills' and commit"
        fi
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
