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
# `policy_schema_version`, and the requirement is the highest one any vendored
# skill declares. A pre-v2 skill ships no such file and therefore requires
# nothing — which is exactly right for an unadvanced pin.
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
#      repository's policy shape agree (including "neither has migrated").
#   1  incompatible — the vendored skills require a newer policy shape than
#      the repository has. Migrate with `copier update`; do NOT advance the
#      pin to get past it.
#   2  usage error, or the audit is indeterminate (no manifest, unreadable
#      policy, missing reader). Never reported as a pass.
#   3  pin lag — the policy has migrated but the vendored skills predate it.
#      Advance `source.ref` in the manifest and re-run `task sync:skills`.
set -euo pipefail

self_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"

die() {
    echo "consumer-pin-audit: $*" >&2
    exit 2
}

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

manifest_ref="$(yq -r '.source.ref // ""' "$manifest")"
dest_rel="$(yq -r '.dest // ".claude/skills"' "$manifest")"
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
        die "provenance '$prov' has no '# ref:' line — the vendored pin is unknown; inspect it and re-run 'task sync:skills' before auditing"
    grep -q '^# managed:' "$prov" ||
        die "provenance '$prov' has no '# managed:' line — the vendored skill set is unknown, so no policy requirement can be read from it; inspect it and re-run 'task sync:skills' before auditing"
    vendored_ref="$(sed -n 's/^# ref:[[:space:]]*//p' "$prov" | head -n 1 | sed 's/[[:space:]]*(.*)$//')"
    [ -n "$vendored_ref" ] ||
        die "provenance '$prov' has an empty '# ref:' line — the vendored pin is unknown; inspect it and re-run 'task sync:skills' before auditing"
    managed="$(sed -n 's/^# managed:[[:space:]]*//p' "$prov" | head -n 1 | tr ',' '\n' | tr -d ' ')"
else
    vendored_ref="$manifest_ref"
fi

# ── what those skills require of the policy ──────────────────────────────────

required=0
requiring_skills=""
while IFS= read -r skill_name; do
    [ -n "$skill_name" ] || continue
    contract="$dest/$skill_name/assets/policy-contract.json"
    [ -f "$contract" ] || continue
    declared="$(jq -r '.policy_schema_version // empty' "$contract" 2>/dev/null || true)"
    case "$declared" in
    '' | *[!0-9]*)
        die "'$contract' declares no integer policy_schema_version"
        ;;
    esac
    [ "$declared" -le "$required" ] || required="$declared"
    requiring_skills="$requiring_skills $skill_name"
done <<EOF
$managed
EOF
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
    shape="$(printf '%s' "$detect_out" | jq -r '.shape // "unknown"')"
    migration="$(printf '%s' "$detect_out" | jq -r '.migration // ""')"
    # The reader reports the POLICY's own declared schema version, and null
    # for a shape that declares none.
    policy_version="$(printf '%s' "$detect_out" | jq -r '.policy_schema_version // 0')"
    case "$policy_version" in
    '' | *[!0-9]*) die "policy '$policy' reported a non-integer schema version: $policy_version" ;;
    esac
fi

# ── verdict ──────────────────────────────────────────────────────────────────
#
# `required` is the highest schema version any vendored skill declares and
# `policy_version` is the one the policy actually declares, so the comparison
# is numeric. Challenge round 1, confirmed: testing `shape = v2` instead let a
# version-2 policy satisfy a skill declaring version 3, reporting an
# incompatible pair as compatible — the exact future-version case the
# comparison exists to survive. `required = 0` (no vendored skill declares
# anything) is handled by its own branch below, so it is excluded here rather
# than being trivially satisfied by every policy.

satisfied=no
[ "$required" -gt 0 ] && [ "$policy_version" -ge "$required" ] && satisfied=yes

if [ "$vendored" = no ]; then
    status=not-vendored
    code=0
    detail="no '.SKILLS_PROVENANCE' stamp under '$dest', so this repository has vendored no skills — the source.ref '$manifest_ref' in $manifest states an intent, not a state. Run 'task sync:skills' to vendor them, then re-run this audit. In harmon-devkit itself, whose '$dest_rel' entries are symlinks into its own ai/skills/ source tree, there is nothing to audit: the pin contract binds consumers."
elif [ "$required" -eq 0 ]; then
    # No vendored skill declares a requirement, so `satisfied` is not the
    # question here — whether the POLICY has migrated ahead of the pin is.
    if [ "$policy_version" -gt 0 ]; then
        status=pin-lag
        code=3
        detail="the policy has migrated to schema_version $policy_version but the skills vendored at $vendored_ref declare no policy contract, so they predate Dev flow v2 — advance source.ref in $manifest to a skills release that ships the version-2 stage skills, then re-run 'task sync:skills'"
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
        detail="the skills vendored at $vendored_ref require schema_version $required (requiring skills: $requiring_skills) but the policy is '$shape', declaring schema_version $policy_version — $migration"
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
        --arg detail "$detail" \
        --argjson required "$required" \
        --argjson exit_code "$code" \
        '{status: $status, exit_code: $exit_code, vendored: ($vendored == "yes"),
          pin: $pin, pin_source: $pin_source,
          manifest_ref: $manifest_ref, policy_shape: $shape,
          policy_schema_version: $policy_version,
          required_policy_schema_version: $required,
          requiring_skills: $requiring_skills, detail: $detail}'
else
    echo "pin:             $vendored_ref (from $pin_source; manifest declares $manifest_ref)"
    echo "policy shape:    $shape (declares schema_version $policy_version)"
    echo "skills require:  schema_version $required (requiring skills: $requiring_skills)"
    echo "status:          $status"
    echo "$detail"
fi

exit "$code"
