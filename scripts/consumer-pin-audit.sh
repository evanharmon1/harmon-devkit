#!/usr/bin/env bash
# consumer-pin-audit.sh — check that a repository's vendored-skill pin and its
# `.devflow.toml` policy shape agree.
#
# Dev flow v2's stage skills operate under `schema_version = 2` and carry no
# interpreter for the pre-v1 legacy shape or the v1 shape (harmon-devkit#604).
# Skills sync and the harmon-init `copier update` run on independent cadences,
# so the two halves migrate at different times, and both orders of skew are
# real:
#
#   * v2 skills over a not-yet-migrated policy — the skills refuse every run.
#     The fix is `copier update`, not a code change; until it lands the
#     repository holds its pin at the last pre-v2 skills release.
#   * a migrated policy under pre-v2 skills — the repository is running the
#     retired single-stage procedure against a config that no longer describes
#     it. The fix is to advance the pin and re-sync.
#
# This audit names which of those a repository is in, so the pin is advanced
# deliberately rather than discovered by a broken run.
#
# What "the vendored skills require" is read from the skills themselves, not
# from a version table this script would have to keep current: every stage
# skill that resolves policy ships `assets/policy-contract.json` declaring its
# `policy_schema_version`. The requirement is the SINGLE version every managed
# contract agrees on — a schema version names an incompatible shape, not a
# minimum capability level, so a managed set declaring two different versions
# is refused as indeterminate rather than resolved to either one. A pre-v2
# skill ships no such file and therefore requires nothing, which is exactly
# right for an unadvanced pin.
#
# Usage:
#   consumer-pin-audit.sh [--repo-root DIR] [--manifest FILE] [--policy FILE]
#                         [--reader FILE] [--json]
#
# Defaults: --repo-root `.`, --manifest <root>/.skills-sync.yaml,
# --policy <root>/.devflow.toml, --reader this repository's
# scripts/devflow-policy.mjs (the shape oracle; the audit never parses TOML
# itself, so there is one implementation of shape detection).
#
# Exit codes:
#   0  compatible — the vendored skills' policy requirement and the
#      repository's policy shape agree (including "neither has migrated"), or
#      the vendored set contains no policy-consuming skill at all
#      (`no-policy-consumer`), so there is no pin contract to satisfy.
#   1  incompatible — the vendored skills require a newer policy shape than
#      the repository has. Migrate with `copier update`; do NOT advance the
#      pin to get past it.
#   2  usage error, or the audit is indeterminate (no manifest, unreadable
#      policy, missing reader). Never reported as a pass.
#   3  pin lag — the policy has migrated but the vendored skills predate it.
#      Advance `source.ref` in the manifest and re-run `task sync:skills`.
set -euo pipefail

self_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"

# The first harmon-devkit release whose `ai/skills/universal/` ships the Dev
# flow v2 stage skills. This is the pin-lag boundary, and it is deliberately a
# RELEASE BOUNDARY rather than a list of skill names: the retired `gauntlet`
# and `shepherd` stages are replaced by `review` and `integrate` and are not
# supported, so a name table would encode dead vocabulary and need editing on
# every rename.
#
# Evidence, re-checkable with these two commands:
#
#   git ls-tree --name-only v0.39.0 ai/skills/universal/
#       -> gauntlet, shepherd, ... and NO review/integrate
#   git ls-tree --name-only main ai/skills/universal/
#       -> review, integrate, orchestrator, ...
#
# No tag through v0.39.0 ships `ai/skills/universal/review`; it exists only on
# `main`, so the first release carrying it is the next one release-please
# cuts, and the pending release PR is 0.40.0. If release-please cuts a
# different version, THIS LINE is the only thing to correct:
# scripts/test-consumer-pin-audit.sh asserts the boundary behaviour relative
# to this constant, never a hard-coded number.
#
# Review round 4, confirmed by reproduction and by git: the previous form was
# a list of the v2 skill names, so a consumer pinned at v0.39.0 — whose stages
# are `gauntlet` and `shepherd` — reported `no-policy-consumer` exit 0
# ("nothing here needs to change") over a freshly migrated policy, when the
# correct answer is pin lag. The regression test masked it by constructing
# pre-v2 fixtures under v2 names that never existed at any pre-v2 tag.
V2_SKILLS_FIRST_RELEASE="v0.40.0"

# ref_is_release_tag REF — REF is an orderable release tag.
ref_is_release_tag() {
    # No pipe into `grep -q`: grep exits on the first match and SIGPIPEs the
    # producer, which `pipefail` then turns into a failure for a MATCH.
    case "$1" in
    v[0-9]*.[0-9]*.[0-9]* | [0-9]*.[0-9]*.[0-9]*) ;;
    *) return 1 ;;
    esac
    # The glob above admits non-digits inside the components; reject those.
    _rt="${1#v}"
    case "$_rt" in
    *[!0-9.]* | *..* | .* | *.) return 1 ;;
    esac
    [ "$(printf '%s' "$_rt" | tr -cd . | wc -c)" -eq 2 ]
}

# ref_predates_v2_skills REF — REF is a release tag strictly older than the
# boundary above, so nothing it vendored can declare a policy contract.
#
# Compared field by field rather than with `sort -V`: that option is GNU-only
# and docs/conventions.md requires these scripts to stay portable to macOS
# bash 3.2, where BSD `sort` has no `-V`. Codex cloud review, confirmed: the
# failure there is silent rather than loud — the pipeline fails, the equality
# test is simply false, and a migrated policy over genuinely pre-v2 skills
# falls through to `no-policy-consumer` exit 0 instead of `pin-lag`, which is
# the exact defect the release boundary was added to fix.
#
# (The review suggested reusing a portable comparison from sync-skills.sh;
# that script only ever compares refs for EQUALITY and has no ordering
# helper, so this is written here rather than borrowed.)
ref_predates_v2_skills() {
    _rp_a="${1#v}"
    _rp_b="${V2_SKILLS_FIRST_RELEASE#v}"
    _rp_a1="${_rp_a%%.*}"
    _rp_b1="${_rp_b%%.*}"
    _rp_a="${_rp_a#*.}"
    _rp_b="${_rp_b#*.}"
    _rp_a2="${_rp_a%%.*}"
    _rp_b2="${_rp_b%%.*}"
    _rp_a3="${_rp_a#*.}"
    _rp_b3="${_rp_b#*.}"
    if [ "$_rp_a1" -ne "$_rp_b1" ]; then
        [ "$_rp_a1" -lt "$_rp_b1" ]
    elif [ "$_rp_a2" -ne "$_rp_b2" ]; then
        [ "$_rp_a2" -lt "$_rp_b2" ]
    else
        [ "$_rp_a3" -lt "$_rp_b3" ]
    fi
}

# The schema version the shipped reader can operate under. Used only to warn
# when a policy has moved ahead of the toolchain — the requirement itself is
# still read from the vendored contracts, never from this constant.
POLICY_SCHEMA_VERSION_SUPPORTED=2

die() {
    echo "consumer-pin-audit: $*" >&2
    exit 2
}

# assert_sane_name NAME — refuse path-traversal-shaped skill names before they
# reach a path join. Matches sync-skills.sh's guard exactly.
assert_sane_name() {
    case "$1" in
    "" | "." | ".." | */* | .*) die "refusing unsafe managed skill name '$1'" ;;
    esac
}

# ── THE COHERENCE INVARIANT ─────────────────────────────────────────────────
#
#   An input the shared reader refuses, or a stamp inconsistent with the tree,
#   is INDETERMINATE: exit 2, never `compatible`.
#
# This is one rule, not a list of special cases. The audit compares a pin
# against a policy, and that comparison is only meaningful on inputs that are
# internally coherent; anything else has no pin verdict to give, and guessing
# one is precisely the fail-open this script exists to prevent.
#
# It is stated here and enforced through `indeterminate` below because the
# case-by-case alternative demonstrably regresses: `mixed` was closed while
# `unknown` stayed open, a missing managed directory was closed while a
# missing `SKILL.md` payload stayed open, each fix drawing the next round's
# finding. `scripts/test-consumer-pin-audit.sh` tests it as a PROPERTY over
# every incoherent input rather than as one assertion per case, so a newly
# discovered incoherent input is a new row in that table, not a new branch here.
#
# Two classes are covered:
#
#   * the POLICY is not exactly one shape the reader recognizes — `mixed` or
#     `unknown` (an incomplete marker set), which
#     `openspec/changes/dev-flow-v2/specs/config/spec.md` requires be rejected
#     "not guessed into either shape". `legacy` and `v1` are NOT incoherent:
#     they are coherent older shapes, and reporting on them is the audit's
#     whole job.
#   * the VENDORED STATE disagrees with itself — a provenance stamp missing
#     its `# ref:`/`# managed:` lines, a managed name with no directory or no
#     `SKILL.md` payload, vendored contract-carrying skills with no stamp at
#     all (an interrupted sync), a contract whose version is not a positive
#     integer, or managed contracts that do not agree on one version.
indeterminate() {
    echo "consumer-pin-audit: indeterminate — $*" >&2
    echo "consumer-pin-audit: an input the shared reader refuses, or a stamp inconsistent with the tree, is never a pass" >&2
    exit 2
}

# The policy shapes the audit can give a pin verdict on. `absent` is this
# script's own sentinel for "no policy file"; every other value the reader can
# return (`mixed`, `unknown`) is incoherent by the invariant above.
COHERENT_POLICY_SHAPES="v2 v1 legacy absent"

repo_root="."
manifest=""
policy=""
reader="$self_dir/devflow-policy.mjs"
as_json=no

while [ "$#" -gt 0 ]; do
    case "$1" in
    --repo-root)
        [ "$#" -ge 2 ] || die "--repo-root requires a directory"
        repo_root="$2"
        shift 2
        ;;
    --manifest)
        [ "$#" -ge 2 ] || die "--manifest requires a file"
        manifest="$2"
        shift 2
        ;;
    --policy)
        [ "$#" -ge 2 ] || die "--policy requires a file"
        policy="$2"
        shift 2
        ;;
    --reader)
        [ "$#" -ge 2 ] || die "--reader requires a file"
        reader="$2"
        shift 2
        ;;
    --json)
        as_json=yes
        shift
        ;;
    -h | --help)
        sed -n '2,50p' "$0"
        exit 0
        ;;
    *) die "unknown argument '$1'" ;;
    esac
done

[ -d "$repo_root" ] || die "--repo-root '$repo_root' is not a directory"
[ -n "$manifest" ] || manifest="$repo_root/.skills-sync.yaml"
[ -n "$policy" ] || policy="$repo_root/.devflow.toml"

command -v yq >/dev/null 2>&1 || die "yq is required (https://github.com/mikefarah/yq)"
command -v jq >/dev/null 2>&1 || die "jq is required"
command -v node >/dev/null 2>&1 || die "node is required"
[ -f "$manifest" ] || die "manifest '$manifest' not found — nothing vendors skills here"
[ -f "$reader" ] || die "policy reader '$reader' not found"

# ── what the repository vendored ─────────────────────────────────────────────

# `var="$(cmd)"` under `set -e` exits with CMD's status, and yq exits 1 on
# malformed YAML — which is this script's "incompatible" code, so a damaged
# manifest read as a migration problem and sent the caller to `copier update`.
# Challenge round 3, confirmed: unreadable input is exit 2 by this file's own
# documented contract, so both reads route through `die`.
manifest_ref="$(yq -r '.source.ref // ""' "$manifest" 2>/dev/null)" ||
    die "manifest '$manifest' could not be parsed as YAML — the vendored pin is unknown; fix the file before auditing"
dest_rel="$(yq -r '.dest // ".claude/skills"' "$manifest" 2>/dev/null)" ||
    die "manifest '$manifest' could not be parsed as YAML — the vendored skill destination is unknown; fix the file before auditing"
[ -n "$manifest_ref" ] || die "manifest '$manifest' declares no source.ref"
case "$dest_rel" in
/*) dest="$dest_rel" ;;
*) dest="$repo_root/$dest_rel" ;;
esac

# The provenance stamp is the only proof that anything was actually vendored,
# and it is authoritative twice over. Its `# ref:` records the ref the skills
# on disk came from, which outranks the manifest — anyone can edit
# `source.ref` without re-running the sync, so auditing the manifest alone
# would report a pin no file on disk is at. Its `# managed:` list records
# WHICH directories the sync owns, which is how a local or symlinked skill
# beside them is correctly excluded: harmon-devkit itself has
# `.claude/skills/<name>` symlinks into its own `ai/skills/` source tree, and
# reading those as "vendored" would have the source repository auditing itself
# against its own unreleased work.
prov="$dest/.SKILLS_PROVENANCE"
vendored=no
vendored_ref=""
managed=""
managed_declared=no
legacy_stamp=no
pin_source=manifest
if [ -f "$prov" ]; then
    vendored=yes
    pin_source=provenance
    # A DAMAGED stamp is indeterminate, never "nothing is managed". Challenge
    # round 1, confirmed: with the `# managed:` line missing or truncated away,
    # the managed set came out empty, no contract was inspected, and a legacy
    # policy sitting under genuinely-vendored v2 skills was reported
    # `compatible` with exit 0 — a fail-open on exactly the file this audit
    # treats as authoritative. sync-skills.sh refuses the same stamp
    # ("provenance has no '# managed:' line"); this only matches it.
    #
    # PRESENCE of the line is the test, not the emptiness of its value: an
    # empty `# managed:` is what sync-skills.sh writes when it legitimately
    # manages nothing, and must stay a valid zero-skill answer.
    grep -q '^# ref:' "$prov" ||
        indeterminate "provenance '$prov' has no '# ref:' line, so the vendored pin is unknown; re-run 'task sync:skills'"
    # A stamp with NO `# managed:` line is the LEGACY generation, not damage:
    # scripts/sync-skills.sh's own `managed_names` recognizes it and
    # reconstructs the set from the recorded ref and categories. Codex cloud
    # review, confirmed: refusing it rejected a state the synchronizer still
    # considers valid, for a consumer deliberately holding a pre-v2 pin.
    #
    # The audit cannot reconstruct that set offline (sync-skills clones the
    # pin to do it), but it does not need to: with no enumerable contracts the
    # requirement is zero, and the release boundary below decides the verdict
    # from the recorded `# ref:` alone — which is the right answer for a stamp
    # generation that predates the v2 skills anyway.
    legacy_stamp=no
    grep -q '^# managed:' "$prov" || legacy_stamp=yes
    # The round-1 legacy-stamp fix carried an unstated assumption — that the
    # stamp GENERATION implies an old recorded ref. Codex cloud review round 2,
    # confirmed: an older synchronizer can write the legacy format while
    # vendoring a post-boundary ref, and then an empty managed set means no
    # contract is inspected at all, so post-v2 skills over an unmigrated policy
    # read as `compatible`. Reconstructing the set needs a clone of the pin
    # (that is how sync-skills.sh:419-455 does it) and this audit is offline,
    # so a legacy stamp is only safe to treat as pre-boundary when its own
    # recorded ref says so. Otherwise it is indeterminate.
    vendored_ref="$(sed -n 's/^# ref:[[:space:]]*//p' "$prov" | head -n 1 | sed 's/[[:space:]]*(.*)$//')"
    [ -n "$vendored_ref" ] ||
        indeterminate "provenance '$prov' has an empty '# ref:' line, so the vendored pin is unknown; re-run 'task sync:skills'"
    vendored_categories=""
    if grep -q '^# categories:' "$prov"; then
        vendored_categories="$(sed -n 's/^# categories:[[:space:]]*//p' "$prov" | head -n 1 | tr ',' '\n' | tr -d ' ')"
    fi
    if [ "$legacy_stamp" = no ]; then
        managed="$(sed -n 's/^# managed:[[:space:]]*//p' "$prov" | head -n 1 | tr ',' '\n' | tr -d ' ')"
        managed_declared=yes
    elif ref_is_release_tag "$vendored_ref" && ref_predates_v2_skills "$vendored_ref"; then
        managed_declared=no
    else
        indeterminate "provenance '$prov' uses the legacy stamp format (no '# managed:' line) but records ref '$vendored_ref', which does not predate $V2_SKILLS_FIRST_RELEASE — the vendored skill set cannot be enumerated offline and cannot be assumed pre-v2; re-run 'task sync:skills' to write a modern stamp"
    fi
else
    # No stamp is NOT proof that nothing was vendored. Challenge round 2,
    # confirmed against sync-skills.sh's own write order: `cmd_sync` does
    # `rm -f "$prov"` BEFORE the `cp -R` loop and rewrites the stamp last, so
    # an interrupted sync leaves real vendored skill directories with no
    # provenance at all.
    #
    # Directory PRESENCE cannot separate that from a checkout that simply has
    # local skills and never ran the sync — sync-skills.sh's own rule is that
    # anything not on `# managed:` is local, and with no stamp that is
    # everything. The evidence that discriminates is a POLICY CONTRACT: the
    # fail-open this closes is "version-2 skills over an unmigrated policy
    # read as compatible", and a version-2 skill is exactly one carrying
    # `assets/policy-contract.json`. A local skill carries none, so it is
    # untouched.
    #
    # Symlinks are excluded: `cp -R` produces real directories, so a symlinked
    # entry is a source checkout rather than an interrupted sync —
    # harmon-devkit's own `.claude/skills/<name>` links into `ai/skills/` and
    # must stay a clean exit 0.
    # ONE rule, and it is the only one this audit can actually decide:
    #
    #   a REAL (non-symlink) directory carrying `assets/policy-contract.json`,
    #   with no stamp beside it, is vendored version-2 residue.
    #
    # `sync-skills.sh` removes the stamp before it copies and rewrites it last,
    # so that pairing means an interrupted sync, and a policy contract is
    # something only a vendored stage skill carries — a local skill has none.
    # Both halves are provable from the tree.
    #
    # The tree-wide "this looks like a source checkout" exemption that used to
    # sit here is DELETED rather than scoped a fourth time. It produced a P1 in
    # three consecutive rounds (broadened, then narrowed by link target, and
    # still leaking tree-wide), which is the accretion signature: it existed
    # only to undo a companion check that counted EVERY real directory as
    # residue, and that check was never decidable. With no stamp,
    # `sync-skills.sh`'s own rule is that nothing is managed, so a
    # contract-free directory is indistinguishable from a local skill —
    # harmon-devkit's own `.claude/skills` holds six real, tracked
    # `openspec-*` directories that are exactly that. Deleting the undecidable
    # check removes the need for any exemption, and with no exemption there is
    # nothing left to leak.
    #
    # What is lost is detection of an interrupted PRE-v2 sync (contract-free
    # `gauntlet`/`shepherd` residue). That was never decidable here either, and
    # it is not undetectable in general: `sync-skills.sh verify`
    # (`task verify:skills`) clones the pinned ref and diffs, so it answers
    # tree-integrity questions by comparison instead of by guess. The
    # `not-vendored` detail below says so rather than leaving the gap silent.
    #
    # Symlinks are skipped as ENTRIES, per entry and never tree-wide, for a
    # reason that is provable rather than heuristic: `cp -R` produces real
    # directories, so a symlink cannot be sync residue — and a source checkout
    # legitimately links to contract-carrying skills (this repository's
    # `.claude/skills/{review,integrate,orchestrator}` do exactly that).
    unstamped=""
    if [ -d "$dest" ]; then
        for candidate in "$dest"/*; do
            [ -d "$candidate" ] || continue
            [ -L "$candidate" ] && continue
            [ -f "$candidate/assets/policy-contract.json" ] || continue
            unstamped="$unstamped $(basename "$candidate")"
        done
    fi
    # A stamp elsewhere in the repository outranks the manifest's word that
    # nothing was vendored here. `dest` comes from `.skills-sync.yaml`, which
    # anyone can edit without re-running the sync, so repointing `dest` at an
    # empty path turned "v2 skills over an unmigrated policy" into a clean
    # exit 0 — a manifest edit alone silenced the audit (Codex cloud review,
    # confirmed). The stamp is a real file with a recorded ref and managed
    # list; finding one outside `$dest` means the tree and the manifest
    # disagree about where the skills live, which this audit cannot resolve
    # offline and must not paper over. `.git` and `node_modules` are excluded
    # because neither can hold a live vendored tree.
    stale_prov=""
    if [ -d "$repo_root" ]; then
        stale_prov="$(find "$repo_root" -name .SKILLS_PROVENANCE -type f \
            -not -path '*/.git/*' -not -path '*/node_modules/*' 2>/dev/null |
            head -n 5)"
    fi
    if [ -n "$stale_prov" ]; then
        indeterminate "no '.SKILLS_PROVENANCE' under the manifest's dest '$dest', but the repository holds one elsewhere ($(printf '%s' "$stale_prov" | paste -sd, -)) — '.skills-sync.yaml' declares a destination the vendored tree is not at, so the manifest is not evidence that nothing is vendored; re-run 'task sync:skills' so the tree and the manifest agree, or point --manifest at the tree you mean to audit"
    fi

    if [ -n "$unstamped" ]; then
        # shellcheck disable=SC2086 # deliberate word-splitting into a CSV
        indeterminate "'$dest' holds vendored policy-consuming skills ($(printf '%s\n' $unstamped | sort -u | paste -sd, -)) but no '.SKILLS_PROVENANCE' stamp — sync-skills.sh removes the stamp before it copies and rewrites it last, so this is an interrupted sync, not a never-vendored checkout; re-run 'task sync:skills'"
    fi
    vendored_ref="$manifest_ref"
fi

# ── what those skills require of the policy ──────────────────────────────────

# A policy schema version names an INCOMPATIBLE SHAPE, not a minimum
# capability level (the reader itself requires `schema_version === 2`
# exactly), so the vendored skills must agree on ONE version and the policy
# must equal it. Challenge round 2, confirmed: aggregating to the highest
# declared version and comparing with `-ge` let a version-2 skill be reported
# satisfied by a hypothetical version-3 policy — a shape it cannot read.
# Two different declared versions among the vendored skills is a broken
# vendored set that no single policy can satisfy, so it is indeterminate here
# rather than silently resolved to either one.
required=0
declared_versions=""
requiring_skills=""
while IFS= read -r skill_name; do
    [ -n "$skill_name" ] || continue
    # #847: a managed token containing a path separator or `..` would join to a
    # path OUTSIDE $dest. sync-skills.sh has assert_sane_name for the same
    # reason; the audit reads rather than writes, so the blast radius is a wrong
    # verdict rather than data loss, but the same validation belongs here.
    assert_sane_name "$skill_name"
    # #849: sync-skills.sh creates REAL directories; a symlinked managed entry
    # is a stamp/tree mismatch even when the target contains a valid SKILL.md
    # and contract. Unstamped symlinks (the no-stamp loop above) are correctly
    # skipped as entries, per entry and never tree-wide.
    if [ -L "$dest/$skill_name" ]; then
        indeterminate "provenance '$prov' lists managed skill '$skill_name' but '$dest/$skill_name' is a symlink — sync-skills.sh creates real directories, so a symlinked managed entry is a stamp/tree mismatch; re-run 'task sync:skills'"
    fi
    # The stamp is authoritative for WHICH skills are vendored, so a managed
    # name the tree does not actually hold is the stamp disagreeing with the
    # tree — the coherence invariant, not "a pre-v2 skill with no contract".
    # `sync-skills.sh` only ever manages a directory containing `SKILL.md`, so
    # that file is what "the tree holds this skill" means; checking the
    # directory alone left a half-deleted payload passing.
    if [ ! -d "$dest/$skill_name" ] || [ ! -f "$dest/$skill_name/SKILL.md" ]; then
        indeterminate "provenance '$prov' lists managed skill '$skill_name' but '$dest/$skill_name' is not a vendored skill directory (no SKILL.md) — the stamp and the tree disagree; re-run 'task sync:skills'"
    fi
    contract="$dest/$skill_name/assets/policy-contract.json"
    [ -f "$contract" ] || continue
    # Check the JSON TYPE, not the rendered text: `jq -r` prints the string
    # "2" and the number 2 identically, so a digit test alone accepted
    # malformed metadata. Codex cloud review round 2, confirmed.
    jq -e '(.policy_schema_version | type) == "number"' "$contract" >/dev/null 2>&1 ||
        indeterminate "'$contract' must declare policy_schema_version as a JSON number, not a string or other type"
    declared="$(jq -r '.policy_schema_version // empty' "$contract" 2>/dev/null || true)"
    # A contract version must be a POSITIVE integer — the coherence invariant
    # again: `0` and a non-integer are both indistinguishable from "declares
    # no contract", so trusting either would let a damaged contract read as a
    # legitimate pre-v2 skill.
    case "$declared" in
    '' | *[!0-9]*)
        indeterminate "'$contract' declares no integer policy_schema_version"
        ;;
    esac
    [ "$declared" -gt 0 ] ||
        indeterminate "'$contract' declares policy_schema_version $declared — it must be positive; 0 is indistinguishable from a skill that declares no contract at all"
    declared_versions="$declared_versions $declared"
    requiring_skills="$requiring_skills $skill_name"
done <<EOF
$managed
EOF
# shellcheck disable=SC2086 # deliberate word-splitting: collapse to a set
declared_versions="$(printf '%s\n' $declared_versions | sort -u | paste -sd, -)"
case "$declared_versions" in
'') required=0 ;;
*,*) indeterminate "the vendored skills declare more than one policy schema version ($declared_versions) — no single policy can satisfy that set; re-run 'task sync:skills' so every vendored skill comes from one pin" ;;
*) required="$declared_versions" ;;
esac
# shellcheck disable=SC2086 # deliberate word-splitting: rebuild as a sorted CSV
requiring_skills="$(printf '%s\n' $requiring_skills | sort -u | paste -sd, -)"
[ -n "$requiring_skills" ] || requiring_skills=none

# ── what shape the policy actually is ────────────────────────────────────────

shape=absent
migration=""
policy_version=0
if [ -f "$policy" ]; then
    detect_out=""
    set +e
    detect_out="$(node "$reader" detect --policy "$policy" --json 2>/dev/null)"
    detect_status=$?
    set -e
    if [ "$detect_status" -ge 2 ] || [ -z "$detect_out" ]; then
        die "policy '$policy' could not be read or parsed (reader exit $detect_status)"
    fi
    # #844: validate that the reader's output is parseable JSON before piping
    # into jq. A reader that exits 0 or 1 but emits truncated or invalid JSON
    # would otherwise propagate jq's status under set -e and terminate with
    # exit 5 — outside the documented 0–3 contract.
    if ! printf '%s' "$detect_out" | jq -e 'type == "object"' >/dev/null 2>&1; then
        die "policy reader '$reader' exited $detect_status but its output is not a JSON object — the policy shape cannot be determined"
    fi
    shape="$(printf '%s' "$detect_out" | jq -r '.shape // "unknown"')"
    migration="$(printf '%s' "$detect_out" | jq -r '.migration // ""')"
    # #850: cross-check the reader's exit status against the reported shape.
    # Exit 1 is the reader's "I refuse this policy" signal, used for older and
    # mixed shapes. A reader that exits 1 but reports shape 'v2' is a
    # contradiction: the status says refused, the shape says compatible. Exit 0
    # remains the only accepted signal for a v2-compatible verdict.
    if [ "$detect_status" -eq 1 ] && [ "$shape" = v2 ]; then
        indeterminate "policy reader exited 1 (refusing the policy) but reported shape 'v2' — the exit status and the reported shape contradict; the reader's refusal is authoritative"
    fi
    # The reader reports the POLICY's own declared schema version, and null
    # for a shape that declares none.
    policy_version="$(printf '%s' "$detect_out" | jq -r '.policy_schema_version // 0')"
    case "$policy_version" in
    '' | *[!0-9]*) die "policy '$policy' reported a non-integer schema version: $policy_version" ;;
    esac
fi

# ── verdict ──────────────────────────────────────────────────────────────────
#
# The coherence invariant applied to the policy: a shape the reader cannot
# classify as exactly one recognized shape has no pin verdict, so it is
# refused before any comparison. This replaces what were separate `mixed` and
# `unknown` special cases — `COHERENT_POLICY_SHAPES` is the whole rule, and a
# future shape is added there rather than as another branch.
# One exception, and it is a distinction in kind rather than a special case: a
# policy that DECLARES a positive `schema_version` this reader cannot operate
# (say 3) is coherent — it is a policy ahead of the toolchain, and the audit
# reports it as pin lag or incompatible. What the delta spec requires rejecting
# is an incomplete or contradictory MARKER SET, which is `unknown` with no
# declared version at all, or `mixed` whatever it declares.
policy_is_coherent=no
case " $COHERENT_POLICY_SHAPES " in
*" $shape "*) policy_is_coherent=yes ;;
esac
if [ "$shape" = unknown ] && [ "$policy_version" -gt "$POLICY_SCHEMA_VERSION_SUPPORTED" ]; then
    # #851: only a version ABOVE the supported one is coherent-but-unsupported
    # (a policy ahead of the toolchain). A version at or below the supported
    # one with shape=unknown is an incomplete marker set — malformed, not ahead.
    policy_is_coherent=yes
fi
if [ "$policy_is_coherent" = no ]; then
    if [ "$policy_version" -gt 0 ] && [ "$policy_version" -le "$POLICY_SCHEMA_VERSION_SUPPORTED" ]; then
        indeterminate "policy '$policy' has shape '$shape' but declares schema_version $policy_version (at or below the supported $POLICY_SCHEMA_VERSION_SUPPORTED) — an incomplete marker set for a version this reader should recognize is malformed, not ahead of the toolchain; the delta spec requires it be rejected rather than guessed into either shape"
    else
        indeterminate "policy '$policy' has shape '$shape' and declares no usable schema version — the reader cannot classify it as exactly one recognized shape, and the delta spec requires such a marker set be rejected rather than guessed into one. ${migration:-}"
    fi
fi

# Satisfaction needs BOTH a successful detection and an equal version.
# Challenge round 4, confirmed by reproduction: a policy declaring
# `schema_version = 2` alongside a legacy marker detects as `mixed` (the
# reader exits 1) while still reporting version 2, so an equality-only test
# set `satisfied=yes` and the audit exited 0 `compatible` on a policy the
# reader had just refused — a fail-open introduced by round 3's own fix, in
# the very check that exists to fail closed. `shape = v2` alone is equally
# wrong (round 1 confirmed that a version-2 policy then satisfied a skill
# declaring version 3), so both conditions are required, not either.
# `required = 0` (no vendored skill declares anything) has its own branch
# below rather than being trivially satisfied by every policy.

satisfied=no
[ "$required" -gt 0 ] && [ "$shape" = v2 ] && [ "$policy_version" -eq "$required" ] && satisfied=yes

# `detect` answers "what shape is this", not "can the stages run against it".
# A file containing only `schema_version = 2` detects as v2 and exits 0, while
# `resolve` on the same file exits 1 ("policy has no rigor_order ranking") —
# so the audit reported `compatible` for a policy every stage refuses, which
# is precisely the incomplete `copier update` it exists to catch and a direct
# violation of the invariant in this file's own banner (Codex cloud review,
# confirmed by execution). Satisfaction therefore asks the reader the question
# the consumer will actually ask it.
#
# The accepted statuses are the reader's documented resolve contract: 0
# resolved clean, 3 resolved with an INDETERMINATE cross-validation — which is
# the ordinary answer here, since this audit supplies no registry or Taskfile
# target list and has no business inventing either. 1 is the refusal that
# matters, and 2 is unreadable input; both are indeterminate for the audit
# rather than a verdict, because "the reader says no" is never a pass and is
# also not the `incompatible` the exit-1 code means (that one names a SHAPE
# mismatch the pin can describe).
if [ "$satisfied" = yes ]; then
    resolve_err=""
    set +e
    resolve_err="$(node "$reader" resolve --policy "$policy" --json 2>&1 >/dev/null)"
    resolve_status=$?
    set -e
    case "$resolve_status" in
    0 | 3) : ;;
    *) indeterminate "policy '$policy' detects as schema version $policy_version but the shared reader refuses to resolve it (resolve exit $resolve_status: ${resolve_err:-no diagnostic}) — every stage will refuse the same way, so this is an incomplete migration, not a satisfied pin; finish the 'copier update' that migrated it (the reader's own refusal message names the harmon-init release) and re-run" ;;
    esac
fi

if [ "$vendored" = no ]; then
    status=not-vendored
    code=0
    detail="no '.SKILLS_PROVENANCE' stamp under '$dest', so no skills are vendored here — the source.ref '$manifest_ref' in $manifest states an intent, not a state. Run 'task sync:skills' to vendor them, then re-run this audit. NOTE: with no stamp this audit cannot tell a contract-free local skill from the residue of an interrupted PRE-v2 sync, because sync-skills.sh's own rule is that nothing is managed without provenance; run 'task verify:skills', which clones the pinned ref and diffs, for that question."
elif [ "$required" -eq 0 ]; then
    # No vendored skill declares a requirement, so `satisfied` is not the
    # question here — whether the POLICY has migrated ahead of the pin is. And
    # "ahead of the pin" is decided by the RELEASE BOUNDARY, not by which skill
    # names the old pin happened to carry: every release from
    # $V2_SKILLS_FIRST_RELEASE onward ships stage skills that declare a
    # contract, so a pin older than it necessarily predates them whatever it
    # was called, and a pin at or after it that still declares nothing is a
    # consumer that genuinely vendors no policy-consuming skill.
    if [ "$policy_version" -gt 0 ] && ! ref_is_release_tag "$vendored_ref"; then
        indeterminate "the policy declares schema_version $policy_version but the vendored pin '$vendored_ref' is not a comparable release tag, so it cannot be ordered against the first release shipping the version-2 stage skills ($V2_SKILLS_FIRST_RELEASE) — pin a release tag in $manifest and re-run 'task sync:skills'"
    fi
    if [ "$policy_version" -gt 0 ] && [ "$managed_declared" = yes ] && [ -z "$(printf '%s' "$managed" | tr -d '[:space:]')" ]; then
        # An explicitly empty `# managed:` list is the synchronizer stating it
        # vendored nothing, so no policy-consuming skill can lag and advancing
        # the pin changes nothing. Codex cloud review round 2, confirmed:
        # a pre-boundary recorded ref was reporting pin lag here.
        status=no-policy-consumer
        code=0
        detail="the policy declares schema_version $policy_version and provenance '$prov' declares an empty managed set, so this consumer vendors no skills at all — there is no pin contract to satisfy and advancing the pin would not create one"
    elif [ "$policy_version" -gt 0 ] && ref_predates_v2_skills "$vendored_ref"; then
        # #842: the release boundary proves what the release SHIPPED, not
        # what this consumer SELECTED. When managed_declared=yes and
        # categories are known, check whether the consumer vendors a
        # policy-consuming category (universal). Without it, advancing
        # the pin gains no policy contract, so the work is pointless.
        _has_universal=no
        # shellcheck disable=SC2086 # deliberate word-splitting on categories
        for _cat in $vendored_categories; do
            [ "$_cat" = universal ] && _has_universal=yes
        done
        if [ "$managed_declared" = yes ] && [ -n "$vendored_categories" ] && [ "$_has_universal" = no ]; then
            status=no-policy-consumer
            code=0
            detail="the policy declares schema_version $policy_version and the pin $vendored_ref predates $V2_SKILLS_FIRST_RELEASE, but the vendored categories do not include 'universal' (the policy-consuming category), so advancing the pin would not add a policy contract — this consumer vendors no policy-consuming skill"
        else
            status=pin-lag
            code=3
            detail="the policy has migrated to schema_version $policy_version but the pin $vendored_ref predates $V2_SKILLS_FIRST_RELEASE, the first release shipping the version-2 stage skills, so nothing vendored declares a policy contract — advance source.ref in $manifest to a release whose stage skills declare policy_schema_version $policy_version, then re-run 'task sync:skills'"
            if [ "$policy_version" -ne "$POLICY_SCHEMA_VERSION_SUPPORTED" ]; then
                detail="$detail. Note that this reader supports schema_version $POLICY_SCHEMA_VERSION_SUPPORTED, so no released skill set is known to declare $policy_version yet — treat this as a policy ahead of the toolchain rather than a pin you can simply advance"
            fi
        fi
    elif [ "$policy_version" -gt 0 ]; then
        status=no-policy-consumer
        code=0
        detail="the policy declares schema_version $policy_version and the pin $vendored_ref is already at or past $V2_SKILLS_FIRST_RELEASE, the first release shipping the version-2 stage skills, yet no managed skill declares a policy contract — this consumer vendors no policy-consuming skill, so there is no pin contract to satisfy and advancing the pin would not add one"
    else
        status=compatible
        code=0
        detail="neither half has migrated: the skills vendored at $vendored_ref require no particular policy shape and the policy is '$shape' — hold this pin until the policy migrates"
    fi
elif [ "$satisfied" = yes ]; then
    status=compatible
    code=0
    detail="the skills vendored at $vendored_ref require schema_version $required and the policy declares schema_version $policy_version (requiring skills: $requiring_skills)"
else
    status=incompatible
    code=1
    if [ "$shape" = absent ]; then
        detail="the skills vendored at $vendored_ref require schema_version $required (requiring skills: $requiring_skills) but '$policy' does not exist — render it with 'copier update' before running any Dev flow stage"
    else
        if [ "$policy_version" -gt "$required" ]; then
            # The reader's migration message says "migrate to schema_version
            # 2", which for a policy ALREADY past 2 is a downgrade that could
            # never make these skills compatible. Codex cloud review,
            # confirmed. Point at newer skills instead, as the contract-free
            # branch already does.
            detail="the policy declares schema_version $policy_version but the skills vendored at $vendored_ref declare schema_version $required (requiring skills: $requiring_skills) — the policy is ahead of these skills, so advance source.ref in $manifest to a release whose stage skills declare schema_version $policy_version rather than migrating the policy backwards"
        elif [ "$required" -gt "$POLICY_SCHEMA_VERSION_SUPPORTED" ]; then
            # #846: the reader's migration message says "migrate to
            # schema_version 2", but these skills need a version ABOVE
            # what this reader supports — copier update to the schema-2
            # template can never satisfy them.
            detail="the skills vendored at $vendored_ref require schema_version $required (requiring skills: $requiring_skills) but the policy is '$shape', declaring schema_version $policy_version — upgrade the policy tooling to one that supports schema_version $required rather than running 'copier update' to the schema-$POLICY_SCHEMA_VERSION_SUPPORTED template, which cannot satisfy these skills"
        else
            detail="the skills vendored at $vendored_ref require schema_version $required (requiring skills: $requiring_skills) but the policy is '$shape', declaring schema_version $policy_version — $migration"
        fi
    fi
fi

if [ "$as_json" = yes ]; then
    jq -n \
        --arg status "$status" \
        --arg vendored "$vendored" \
        --arg pin "$vendored_ref" \
        --arg pin_source "$pin_source" \
        --arg manifest_ref "$manifest_ref" \
        --arg shape "$shape" \
        --argjson policy_version "$policy_version" \
        --arg requiring_skills "$requiring_skills" \
        --arg v2_skills_first_release "$V2_SKILLS_FIRST_RELEASE" \
        --arg detail "$detail" \
        --argjson required "$required" \
        --argjson exit_code "$code" \
        '{status: $status, exit_code: $exit_code, vendored: ($vendored == "yes"),
          pin: $pin, pin_source: $pin_source,
          manifest_ref: $manifest_ref, policy_shape: $shape,
          policy_schema_version: $policy_version,
          required_policy_schema_version: $required,
          requiring_skills: $requiring_skills,
          v2_skills_first_release: $v2_skills_first_release,
          detail: $detail}'
else
    echo "pin:             $vendored_ref (from $pin_source; manifest declares $manifest_ref)"
    echo "policy shape:    $shape (declares schema_version $policy_version)"
    echo "skills require:  schema_version $required (requiring skills: $requiring_skills)"
    echo "status:          $status"
    echo "$detail"
fi

exit "$code"
