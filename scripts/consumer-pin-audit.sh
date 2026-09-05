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

# The skills that resolve `.devflow.toml` and therefore ship
# `assets/policy-contract.json` in harmon-devkit. It is the pin-lag test, not
# the requirement test: the requirement is read from the contracts actually on
# disk (which is what makes a future policy-consuming skill work without
# touching this list), but telling a consumer to advance its pin is only
# actionable if advancing it could add a contract at all. Challenge round 2,
# confirmed: a manifest vendoring only contract-free categories (`frontend`,
# say) reported `pin-lag` forever over a migrated policy, instructing the
# operator to advance and re-sync when repeating those steps could never
# change the result.
POLICY_CONSUMING_SKILLS="review integrate orchestrator"

# The schema version the shipped reader can operate under. Used only to warn
# when a policy has moved ahead of the toolchain — the requirement itself is
# still read from the vendored contracts, never from this constant.
POLICY_SCHEMA_VERSION_SUPPORTED=2

die() {
    echo "consumer-pin-audit: $*" >&2
    exit 2
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
    grep -q '^# managed:' "$prov" ||
        indeterminate "provenance '$prov' has no '# managed:' line, so the vendored skill set is unknown; re-run 'task sync:skills'"
    vendored_ref="$(sed -n 's/^# ref:[[:space:]]*//p' "$prov" | head -n 1 | sed 's/[[:space:]]*(.*)$//')"
    [ -n "$vendored_ref" ] ||
        indeterminate "provenance '$prov' has an empty '# ref:' line, so the vendored pin is unknown; re-run 'task sync:skills'"
    managed="$(sed -n 's/^# managed:[[:space:]]*//p' "$prov" | head -n 1 | tr ',' '\n' | tr -d ' ')"
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
    unstamped=""
    if [ -d "$dest" ]; then
        for candidate in "$dest"/*; do
            [ -d "$candidate" ] || continue
            [ -L "$candidate" ] && continue
            [ -f "$candidate/assets/policy-contract.json" ] || continue
            unstamped="$unstamped $(basename "$candidate")"
        done
    fi
    if [ -n "$unstamped" ]; then
        # shellcheck disable=SC2086 # deliberate word-splitting into a CSV
        indeterminate "'$dest' holds policy-consuming skills ($(printf '%s\n' $unstamped | sort -u | paste -sd, -)) but no '.SKILLS_PROVENANCE' stamp — sync-skills.sh removes the stamp before it copies and rewrites it last, so this is an interrupted sync, not a never-vendored checkout; re-run 'task sync:skills'"
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
policy_consumers_present=no
while IFS= read -r skill_name; do
    [ -n "$skill_name" ] || continue
    case " $POLICY_CONSUMING_SKILLS " in
    *" $skill_name "*) policy_consumers_present=yes ;;
    esac
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
if [ "$shape" = unknown ] && [ "$policy_version" -gt 0 ]; then
    policy_is_coherent=yes
fi
if [ "$policy_is_coherent" = no ]; then
    indeterminate "policy '$policy' has shape '$shape' and declares no usable schema version — the reader cannot classify it as exactly one recognized shape, and the delta spec requires such a marker set be rejected rather than guessed into one. ${migration:-}"
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

if [ "$vendored" = no ]; then
    status=not-vendored
    code=0
    detail="no '.SKILLS_PROVENANCE' stamp under '$dest', so this repository has vendored no skills — the source.ref '$manifest_ref' in $manifest states an intent, not a state. Run 'task sync:skills' to vendor them, then re-run this audit. In harmon-devkit itself, whose '$dest_rel' entries are symlinks into its own ai/skills/ source tree, there is nothing to audit: the pin contract binds consumers."
elif [ "$required" -eq 0 ]; then
    # No vendored skill declares a requirement, so `satisfied` is not the
    # question here — whether the POLICY has migrated ahead of the pin is, and
    # that is only a pin question when the vendored set contains a skill that
    # WOULD carry a contract at a newer pin.
    if [ "$policy_version" -gt 0 ] && [ "$policy_consumers_present" = yes ]; then
        status=pin-lag
        code=3
        # Name the version the policy ACTUALLY declares, not "version-2".
        # Review round 2, confirmed by reproduction: a version-3 policy was
        # told to install version-2 stage skills, which exact-equality
        # comparison can never satisfy — the remedy would leave the repository
        # incompatible no matter how faithfully it was followed.
        detail="the policy has migrated to schema_version $policy_version but the policy-consuming skills vendored at $vendored_ref declare no policy contract, so they predate it — advance source.ref in $manifest to a skills release whose stage skills declare policy_schema_version $policy_version, then re-run 'task sync:skills'"
        if [ "$policy_version" -ne "$POLICY_SCHEMA_VERSION_SUPPORTED" ]; then
            detail="$detail. Note that this reader supports schema_version $POLICY_SCHEMA_VERSION_SUPPORTED, so no released skill set is known to declare $policy_version yet — treat this as a policy ahead of the toolchain rather than a pin you can simply advance"
        fi
    elif [ "$policy_version" -gt 0 ]; then
        status=no-policy-consumer
        code=0
        detail="the policy declares schema_version $policy_version and the skills vendored at $vendored_ref include none that resolve it ($POLICY_CONSUMING_SKILLS), so there is no pin contract to satisfy — advancing the pin would not add one, and nothing here needs to change"
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
        --arg policy_consumers_present "$policy_consumers_present" \
        --arg detail "$detail" \
        --argjson required "$required" \
        --argjson exit_code "$code" \
        '{status: $status, exit_code: $exit_code, vendored: ($vendored == "yes"),
          pin: $pin, pin_source: $pin_source,
          manifest_ref: $manifest_ref, policy_shape: $shape,
          policy_schema_version: $policy_version,
          required_policy_schema_version: $required,
          requiring_skills: $requiring_skills,
          policy_consuming_skills_vendored: ($policy_consumers_present == "yes"),
          detail: $detail}'
else
    echo "pin:             $vendored_ref (from $pin_source; manifest declares $manifest_ref)"
    echo "policy shape:    $shape (declares schema_version $policy_version)"
    echo "skills require:  schema_version $required (requiring skills: $requiring_skills)"
    echo "status:          $status"
    echo "$detail"
fi

exit "$code"
