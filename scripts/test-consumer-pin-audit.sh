#!/usr/bin/env bash
# test-consumer-pin-audit.sh — behavioral tests for the Dev flow v2 consumer
# pin contract (harmon-devkit#604, openspec/changes/dev-flow-v2 task 5.1):
#
#   * scripts/consumer-pin-audit.sh — does a repository's vendored-skill pin
#     agree with its .devflow.toml shape, and does it refuse both directions
#     of skew with the right instruction?
#   * scripts/devflow-policy.mjs — is a non-version-2 policy refused with ONE
#     actionable message naming `copier update` and the harmon-init release
#     that ships the version-2 template, and does a version-2 policy resolve?
#
# Fully hermetic and offline: builds throwaway consumer repositories in temp
# dirs from the shape fixtures already in ai/schemas/fixtures/exit/, so no
# case depends on this repository's own (still legacy) .devflow.toml or on its
# .claude/skills symlinks. Run via `task test:consumer-pin-audit`.
set -euo pipefail

repo="$(git rev-parse --show-toplevel)"
AUDIT="$repo/scripts/consumer-pin-audit.sh"
READER="$repo/scripts/devflow-policy.mjs"
FIX="$repo/ai/schemas/fixtures/exit"

LEGACY_POLICY="$FIX/shape-refusal-legacy/policy.toml"
V1_POLICY="$FIX/shape-refusal-v1/policy.toml"
MIXED_POLICY="$FIX/shape-refusal-mixed/policy.toml"
V2_POLICY="$FIX/single-round-clean-converge/policy.toml"

for f in "$AUDIT" "$READER" "$LEGACY_POLICY" "$V1_POLICY" "$MIXED_POLICY" "$V2_POLICY"; do
    [ -e "$f" ] || {
        echo "test-consumer-pin-audit: missing required input: $f" >&2
        exit 1
    }
done

# The release name is the reader's own exported constant, not a second copy:
# when it is bumped there, these assertions follow rather than going stale in a
# way that only shows up as a confusing test failure.
# Hand the path through the environment, not argv: the reader's own
# is-main guard compares `process.argv[1]` to its own file, so passing it
# there would make this import run the CLI instead of loading the module.
V2_RELEASE="$(READER_PATH="$READER" node -e \
    'import(process.env.READER_PATH).then((m) => process.stdout.write(m.V2_TEMPLATE_RELEASE))')"
[ -n "$V2_RELEASE" ] || {
    echo "test-consumer-pin-audit: the reader exports no V2_TEMPLATE_RELEASE" >&2
    exit 1
}

# The pin-lag boundary comes from the script under test, so bumping the
# release constant there needs no edit here.
V2_BOUNDARY="$(sed -n 's/^V2_SKILLS_FIRST_RELEASE="\(.*\)"$/\1/p' "$AUDIT")"
[ -n "$V2_BOUNDARY" ] || {
    echo "test-consumer-pin-audit: could not read V2_SKILLS_FIRST_RELEASE from $AUDIT" >&2
    exit 1
}

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

pass=0
fail=0
ok() {
    pass=$((pass + 1))
    echo "  ✓ $*"
}
bad() {
    fail=$((fail + 1))
    echo "  ✗ $*" >&2
}

# run_audit DIR [EXTRA...] — run the audit, capturing stdout+stderr in
# $out and the exit status in $status. Never let `set -e` kill the run: a
# non-zero exit is the thing under test.
out=""
status=0
run_audit() {
    local dir="$1"
    shift
    set +e
    out="$("$AUDIT" --repo-root "$dir" "$@" 2>&1)"
    status=$?
    set -e
}

# expect_status DESC WANT — assert the last run's exit status.
expect_status() {
    if [ "$status" -eq "$2" ]; then
        ok "$1 (exit $2)"
    else
        bad "$1 (expected exit $2, got $status)"
        printf '%s\n' "$out" | sed 's/^/      /' >&2
    fi
}

# expect_says DESC NEEDLE — assert the last run's output contains NEEDLE. A
# refusal that fires for an unrelated reason is a passing test proving nothing.
expect_says() {
    if printf '%s' "$out" | grep -Fq -- "$2"; then
        ok "$1"
    else
        bad "$1 (output does not contain '$2')"
        printf '%s\n' "$out" | sed 's/^/      /' >&2
    fi
}

expect_not_says() {
    if printf '%s' "$out" | grep -Fq -- "$2"; then
        bad "$1 (output unexpectedly contains '$2')"
        printf '%s\n' "$out" | sed 's/^/      /' >&2
    else
        ok "$1"
    fi
}

# make_consumer NAME POLICY_SRC PIN SKILL_SPEC... — build a throwaway consumer
# repository. POLICY_SRC is a fixture path, or `none` for no .devflow.toml at
# all. Each SKILL_SPEC is `<name>:v2` (vendored WITH a policy contract),
# `<name>:v3` (vendored declaring a FUTURE schema version), `<name>:pre`
# (vendored WITHOUT one — a pre-Dev-flow-v2 skill), or
# `<name>:local` (present in dest but NOT on the provenance `# managed:`
# line, i.e. a local skill the sync never vendored). Prints the repo root.
make_consumer() {
    local name="$1" policy_src="$2" pin="$3"
    shift 3
    local root="$TMPROOT/$name"
    local dest="$root/.claude/skills"
    mkdir -p "$dest"
    cat >"$root/.skills-sync.yaml" <<YAML
source:
  repo: https://github.com/evanharmon1/harmon-devkit.git
  ref: $pin
categories: [universal]
dest: .claude/skills
YAML
    [ "$policy_src" = none ] || cp "$policy_src" "$root/.devflow.toml"

    local managed="" spec skill kind
    for spec in "$@"; do
        skill="${spec%%:*}"
        kind="${spec##*:}"
        mkdir -p "$dest/$skill"
        printf -- '---\nname: %s\ndescription: fixture\n---\n' "$skill" >"$dest/$skill/SKILL.md"
        case "$kind" in
        v2 | v3)
            mkdir -p "$dest/$skill/assets"
            printf '{"skill":"%s","policy_schema_version":%s}\n' \
                "$skill" "${kind#v}" >"$dest/$skill/assets/policy-contract.json"
            ;;
        esac
        if [ "$kind" != local ]; then
            managed="${managed:+$managed, }$skill"
        fi
    done
    {
        echo "# VENDORED from harmon-devkit — DO NOT EDIT the managed skills here."
        echo "# source: https://github.com/evanharmon1/harmon-devkit.git"
        echo "# ref: $pin (deadbeefdeadbeefdeadbeefdeadbeefdeadbeef)"
        echo "# path: ai/skills"
        echo "# categories: universal"
        echo "# managed:${managed:+ $managed}"
    } >"$dest/.SKILLS_PROVENANCE"
    printf '%s' "$root"
}

echo "== consumer-pin-audit: both halves still pre-v2 =="
c="$(make_consumer both-pre "$LEGACY_POLICY" v0.34.1 gauntlet:pre shepherd:pre)"
run_audit "$c"
expect_status "a pre-v2 pin over a legacy policy is the expected in-transition state" 0
expect_says "it says neither half has migrated" "neither half has migrated"
expect_says "it names the pin it read" "v0.34.1"

echo
echo "== consumer-pin-audit: v2 skills over an unmigrated policy =="
# `mixed` is deliberately NOT in this loop: it is indeterminate (exit 2), not
# an incompatible pin (exit 1), and has its own case below. A legacy or v1
# policy is a coherent older shape the operator can migrate; a mixed one is two
# shapes at once and the delta spec requires rejecting rather than resolving it.
for shape in legacy v1; do
    case "$shape" in
    legacy) src="$LEGACY_POLICY" ;;
    v1) src="$V1_POLICY" ;;
    esac
    c="$(make_consumer "v2-over-$shape" "$src" v0.41.0 review:v2 integrate:v2 kickoff:pre)"
    run_audit "$c"
    expect_status "a $shape policy under version-2 skills is refused" 1
    expect_says "the $shape refusal names copier update" "copier update"
    expect_says "the $shape refusal names the harmon-init release" "$V2_RELEASE"
    expect_says "the $shape refusal identifies the detected shape" "detected shape: $shape"
    expect_says "the $shape refusal says to hold the pin, not advance it" \
        "pinned to the last pre-v2 skills release"
    expect_says "the $shape refusal reports the policy as declaring no version" \
        "declaring schema_version 0"
done

echo
echo "== consumer-pin-audit: version-2 skills over a version-2 policy =="
c="$(make_consumer v2-over-v2 "$V2_POLICY" v0.41.0 review:v2 integrate:v2)"
run_audit "$c"
expect_status "a version-2 policy under version-2 skills is compatible" 0
expect_says "it names the requiring skills" "integrate,review"
expect_not_says "a compatible run does not tell anyone to run copier update" "copier update"

echo
echo "== consumer-pin-audit: migrated policy still on a pre-v2 pin =="
# The fixture is the REAL pre-v2 world: v0.39.0 shipped `gauntlet` and
# `shepherd` and no v2 stage skill at all (`git ls-tree --name-only v0.39.0
# ai/skills/universal/`). Review round 4, confirmed: the previous fixture used
# `integrate`/`orchestrator` at a pre-v2 pin — names that existed at no pre-v2
# tag — so it passed while the only pin that exists in the world returned
# `no-policy-consumer` exit 0 and told the operator nothing needed to change.
c="$(make_consumer pin-lag "$V2_POLICY" v0.39.0 gauntlet:pre shepherd:pre)"
run_audit "$c"
expect_status "a migrated policy on the real last pre-v2 pin is pin lag, not a pass" 3
expect_says "pin lag names the release boundary it compared against" "$V2_BOUNDARY"
expect_says "pin lag says to advance source.ref" "advance source.ref"
expect_says "pin lag says to re-sync" "task sync:skills"
expect_not_says "pin lag does not tell anyone to migrate an already-migrated policy" "copier update"

echo
echo "== consumer-pin-audit: version-2 skills with no policy file at all =="
c="$(make_consumer no-policy none v0.41.0 review:v2)"
run_audit "$c"
expect_status "version-2 skills with no .devflow.toml is refused, not passed" 1
expect_says "the missing-policy refusal names copier update" "copier update"

echo
echo "== consumer-pin-audit: a local skill never counts as vendored =="
# The local skill carries a version-2 contract but is absent from `# managed:`.
# Counting it would make an unadvanced pin look migrated and hide the skew —
# and it is exactly the shape harmon-devkit's own .claude/skills symlinks take.
c="$(make_consumer local-not-vendored "$LEGACY_POLICY" v0.34.1 gauntlet:pre my-local:local)"
mkdir -p "$c/.claude/skills/my-local/assets"
printf '{"skill":"my-local","policy_schema_version":2}\n' \
    >"$c/.claude/skills/my-local/assets/policy-contract.json"
run_audit "$c"
expect_status "an unmanaged local skill's contract does not create a requirement" 0
expect_says "the unmanaged skill is not listed as requiring anything" "requiring skills: none"

echo
echo "== consumer-pin-audit: provenance outranks an edited manifest =="
c="$(make_consumer prov-wins "$LEGACY_POLICY" v0.34.1 gauntlet:pre)"
sed -i 's/ref: v0.34.1/ref: v9.9.9/' "$c/.skills-sync.yaml"
run_audit "$c" --json
expect_status "an edited-but-unsynced manifest still audits the vendored ref" 0
if printf '%s' "$out" | jq -e '.pin == "v0.34.1" and .pin_source == "provenance" and .manifest_ref == "v9.9.9"' >/dev/null 2>&1; then
    ok "the audit reports the provenance ref as the pin and the manifest ref alongside it"
else
    bad "the audit did not prefer the provenance ref over the manifest ref"
    printf '%s\n' "$out" | sed 's/^/      /' >&2
fi

echo
echo "== consumer-pin-audit: nothing vendered at all =="
c="$(make_consumer never-synced "$V2_POLICY" v0.41.0)"
rm -f "$c/.claude/skills/.SKILLS_PROVENANCE"
run_audit "$c"
expect_status "a checkout that never ran the sync is reported, not judged" 0
expect_says "it says nothing was vendored" "no skills are vendored here"

echo
echo "== consumer-pin-audit: indeterminate inputs are never a pass =="
c="$(make_consumer no-manifest "$V2_POLICY" v0.41.0 review:v2)"
rm -f "$c/.skills-sync.yaml"
run_audit "$c"
expect_status "a missing manifest is a usage error" 2
expect_says "the missing-manifest error names the manifest" "not found"

c="$(make_consumer bad-policy "$LEGACY_POLICY" v0.41.0 review:v2)"
printf 'this is [not valid = toml\n' >"$c/.devflow.toml"
run_audit "$c"
expect_status "an unparseable policy is indeterminate, never a pass" 2
expect_says "the unparseable-policy error says the policy could not be read" "could not be read or parsed"

echo
echo "== consumer-pin-audit: --json exit_code matches the process exit =="
c="$(make_consumer json-code "$LEGACY_POLICY" v0.41.0 review:v2)"
run_audit "$c" --json
if printf '%s' "$out" | jq -e --argjson want "$status" '.exit_code == $want and .status == "incompatible"' >/dev/null 2>&1; then
    ok "--json reports the same exit code the process returned"
else
    bad "--json exit_code did not match the process exit ($status)"
    printf '%s\n' "$out" | sed 's/^/      /' >&2
fi

echo
echo "== consumer-pin-audit: the required version is compared, not assumed =="
# Challenge round 1: `satisfied` was set from `shape = v2` alone, so a skill
# declaring a FUTURE schema version was reported satisfied by a v2 policy.
c="$(make_consumer future-version "$V2_POLICY" v9.0.0 review:v3)"
run_audit "$c"
expect_status "a version-2 policy does not satisfy a skill declaring version 3" 1
expect_says "the refusal names the version actually required" "require schema_version 3"
expect_says "the refusal names the version the policy declares" "declaring schema_version 2"
run_audit "$c" --json
if printf '%s' "$out" | jq -e '.policy_schema_version == 2 and .required_policy_schema_version == 3 and .status == "incompatible"' >/dev/null 2>&1; then
    ok "--json reports both versions separately"
else
    bad "--json did not report the policy and required versions separately"
    printf '%s\n' "$out" | sed 's/^/      /' >&2
fi

echo
echo "== consumer-pin-audit: an interrupted sync is not a never-vendored checkout =="
# Challenge round 2, confirmed against sync-skills.sh's write order: it does
# `rm -f "$prov"` before its `cp -R` loop and rewrites the stamp last, so
# vendored v2 skills can sit on disk with no provenance — reported `not-vendored`
# exit 0 over a legacy policy, the exact fail-open this audit exists to catch.
c="$(make_consumer interrupted-sync "$LEGACY_POLICY" v0.41.0 review:v2 integrate:v2)"
rm -f "$c/.claude/skills/.SKILLS_PROVENANCE"
run_audit "$c"
expect_status "vendored policy-consuming skills with no stamp are indeterminate" 2
expect_says "the interrupted-sync error says the stamp is written last" "rewrites it last"
expect_says "the interrupted-sync error names the skills it found" "review"

# The counterpart that must NOT trip: local skills carry no policy contract,
# and a checkout that simply never ran the sync is a clean exit 0.
c="$(make_consumer local-only-no-stamp "$LEGACY_POLICY" v0.34.1 my-local:pre other-local:pre)"
rm -f "$c/.claude/skills/.SKILLS_PROVENANCE"
run_audit "$c"
expect_status "local skills carrying no contract are not an interrupted sync" 0
expect_says "it is still reported as never vendored" "no skills are vendored here"

# Nor a source checkout whose skill entries are SYMLINKS (harmon-devkit's own
# .claude/skills shape): `cp -R` makes real directories, a symlink never.
c="$(make_consumer symlinked-source "$LEGACY_POLICY" v0.41.0)"
rm -f "$c/.claude/skills/.SKILLS_PROVENANCE"
mkdir -p "$c/src/integrate/assets"
printf -- '---\nname: integrate\ndescription: fixture\n---\n' >"$c/src/integrate/SKILL.md"
printf '{"skill":"integrate","policy_schema_version":2}\n' >"$c/src/integrate/assets/policy-contract.json"
ln -s ../../src/integrate "$c/.claude/skills/integrate"
run_audit "$c"
expect_status "a symlinked source tree is not an interrupted sync" 0
expect_says "the symlinked source is reported as never vendored" "no skills are vendored here"

echo
echo "== consumer-pin-audit: a contract-free vendored subset is not pin lag =="
# Challenge round 2, confirmed: a manifest vendoring only categories with no
# policy-consuming skill returned pin-lag forever over a migrated policy,
# telling the operator to advance and re-sync when that could never help.
# At or past the boundary with still no contract, the consumer genuinely
# vendors no policy-consuming skill and advancing the pin cannot help.
c="$(make_consumer no-policy-consumer "$V2_POLICY" v9.0.0 some-frontend-skill:pre another:pre)"
run_audit "$c"
expect_status "a pin past the boundary with no contract is not pin lag" 0
expect_says "it says advancing the pin would not add a contract" "advancing the pin would not add one"
expect_not_says "it does not tell anyone to re-sync pointlessly" "task sync:skills"

# Below the boundary it is pin lag whatever the old skills were CALLED — the
# rule is the release boundary, not a table of retired stage names.
c="$(make_consumer real-pin-lag "$V2_POLICY" v0.34.1 gauntlet:pre shepherd:pre)"
run_audit "$c"
expect_status "a pre-boundary pin is pin lag whatever its skills were named" 3
expect_says "real pin lag still says to advance source.ref" "advance source.ref"

# A pin that cannot be ordered against the boundary is indeterminate, not a
# guess in either direction.
c="$(make_consumer unorderable-pin "$V2_POLICY" main gauntlet:pre)"
run_audit "$c"
expect_status "a non-tag pin over a migrated policy is indeterminate" 2
expect_says "the unorderable-pin error says it cannot be ordered" "cannot be ordered"

echo
echo "== consumer-pin-audit: schema versions are shapes, not capability levels =="
# Challenge round 2, confirmed: `-ge` treated a newer policy as satisfying an
# older skill. The reader itself requires `schema_version === 2` exactly.
c="$(make_consumer newer-policy "$V2_POLICY" v0.41.0 review:v2)"
run_audit "$c"
expect_status "an exactly-matching version pair is compatible" 0

c="$(make_consumer mixed-declared "$V2_POLICY" v0.41.0 review:v2 integrate:v3)"
run_audit "$c"
expect_status "vendored skills declaring two different versions is indeterminate" 2
expect_says "the mixed-set error names both versions" "more than one policy schema version"

echo
echo "== consumer-pin-audit: a malformed manifest is indeterminate, not incompatible =="
# Challenge round 3, confirmed: `var="$(yq ...)"` under `set -e` exits with
# yq's status, and yq exits 1 on bad YAML — this script's "incompatible" code,
# sending the caller to `copier update` for a damaged file.
c="$(make_consumer bad-manifest "$V2_POLICY" v0.41.0 review:v2)"
printf 'source: [this is: not valid\n  yaml\n' >"$c/.skills-sync.yaml"
run_audit "$c"
expect_status "an unparseable manifest is a usage error, not an incompatibility" 2
expect_says "the malformed-manifest error says it could not be parsed" "could not be parsed as YAML"

echo
echo "== consumer-pin-audit: a policy past this reader's version is still versioned =="
# Challenge round 3, confirmed: `schema_version = 3` detects as `unknown`, so
# the reported version was null, the audit read it as 0, and pre-v2 skills over
# an already-migrated policy came back `compatible` — defeating the equality
# comparison the previous round introduced.
future_policy="$TMPROOT/future-policy.toml"
printf 'schema_version = 3\ndefault_rigor = "standard"\n' >"$future_policy"
c="$(make_consumer future-policy "$future_policy" v0.34.1 integrate:pre review:pre)"
run_audit "$c"
expect_status "pre-v2 skills under a version-3 policy is pin lag, not compatible" 3
expect_says "pin lag reports the version the policy actually declares" "schema_version 3"
# Review round 2: the remedy must name the version the policy declares. Telling
# the operator to install version-2 skills for a version-3 policy is advice
# exact-equality comparison can never satisfy.
expect_says "the remedy names the version the skills must declare" \
    "declare policy_schema_version 3"
expect_not_says "the remedy does not send them after version-2 skills" \
    "ships the version-2 stage skills"
expect_says "it warns that the policy is ahead of this toolchain" \
    "ahead of the toolchain"

c="$(make_consumer v2-skills-future-policy "$future_policy" v0.41.0 review:v2)"
run_audit "$c"
expect_status "version-2 skills under a version-3 policy are incompatible" 1

# stdout only: the refusal also goes to stderr, and folding the two together
# would hand jq a JSON document with a prose line appended.
set +e
out="$(node "$READER" detect --policy "$future_policy" --json 2>/dev/null)"
status=$?
set -e
expect_status "detect still refuses a version this reader cannot operate under" 1
if printf '%s' "$out" | jq -e '.policy_schema_version == 3 and .migration != null' >/dev/null 2>&1; then
    ok "detect reports the declared version while still refusing it"
else
    bad "detect did not report the declared version of an unoperatable policy"
    printf '%s\n' "$out" | sed 's/^/      /' >&2
fi

echo
echo "== consumer-pin-audit: THE COHERENCE INVARIANT, as a property =="
# The audit states one rule: an input the shared reader refuses, or a stamp
# inconsistent with the tree, is indeterminate — exit 2, never `compatible`.
# This is tested as a PROPERTY over every incoherent input rather than as one
# assertion per case, because the case-by-case form demonstrably regressed:
# `mixed` was closed while `unknown` stayed open, a missing managed directory
# was closed while a missing SKILL.md payload stayed open, each fix drawing the
# next review round's finding. A newly discovered incoherent input belongs in
# the table below, not in a new branch of the script.
#
# Each row builds a consumer that is incoherent in exactly one way and asserts
# BOTH halves of the invariant: exit 2, and the word `compatible` never
# appears. Rows deliberately vary the policy shape (legacy and v2) so no row
# passes merely because some other branch happened to fire first.
incoherent_policy="$TMPROOT/incoherent"
mkdir -p "$incoherent_policy"
printf 'schema_version = 2\ndefault_method = "plan"\n[method]\nrank = ["oneshot"]\n' \
    >"$incoherent_policy/mixed.toml"
printf '[rigor.standard]\nchallenge = 3\n' >"$incoherent_policy/partial.toml"

# A stamp with no `# managed:` line is deliberately NOT in this table: Codex
# cloud review confirmed it is the LEGACY stamp generation, which
# sync-skills.sh's own `managed_names` still honours, so refusing it rejected a
# valid state. Its behaviour is asserted in the round-1 regression block below.
# A stamp with no `# ref:` line stays incoherent — sync-skills.sh dies on that
# one too.
#
# name|policy fixture|skill specs|mutation applied to the built consumer
INCOHERENT_CASES="
policy-is-mixed|$incoherent_policy/mixed.toml|review:v2 integrate:v2|none
policy-is-incomplete|$incoherent_policy/partial.toml|integrate:pre|none
policy-incomplete-with-v2-skills|$incoherent_policy/partial.toml|review:v2|none
contract-version-zero|LEGACY|review:v2|zero_contract
contract-version-noninteger|LEGACY|review:v2|noninteger_contract
contract-versions-disagree|V2|review:v2 integrate:v3|none
stamp-has-no-ref-line|LEGACY|review:v2|strip_ref
managed-name-has-no-directory|LEGACY|review:v2|drop_dir
managed-name-has-no-payload|LEGACY|review:v2|drop_skill_md
vendored-skills-with-no-stamp|LEGACY|review:v2 integrate:v2|drop_stamp
"

apply_mutation() {
    local root="$1" how="$2" d="$1/.claude/skills"
    case "$how" in
    none) ;;
    zero_contract) printf '{"skill":"review","policy_schema_version":0}\n' >"$d/review/assets/policy-contract.json" ;;
    noninteger_contract) printf '{"skill":"review","policy_schema_version":"two"}\n' >"$d/review/assets/policy-contract.json" ;;
    strip_ref) grep -v '^# ref:' "$d/.SKILLS_PROVENANCE" >"$root/p.tmp" && mv "$root/p.tmp" "$d/.SKILLS_PROVENANCE" ;;
    drop_dir) rm -rf "$d/review" ;;
    drop_skill_md) rm -f "$d/review/SKILL.md" ;;
    drop_stamp) rm -f "$d/.SKILLS_PROVENANCE" ;;
    *)
        echo "test bug: unknown mutation '$how'" >&2
        exit 1
        ;;
    esac
}

while IFS='|' read -r case_name policy_ref skill_specs mutation; do
    [ -n "$case_name" ] || continue
    case "$policy_ref" in
    LEGACY) policy_src="$LEGACY_POLICY" ;;
    V2) policy_src="$V2_POLICY" ;;
    *) policy_src="$policy_ref" ;;
    esac
    # shellcheck disable=SC2086 # skill specs are a deliberate word-split list
    c="$(make_consumer "inv-$case_name" "$policy_src" v0.41.0 $skill_specs)"
    apply_mutation "$c" "$mutation"
    run_audit "$c"
    expect_status "invariant: $case_name is indeterminate" 2
    expect_not_says "invariant: $case_name is never reported compatible" "compatible"
done <<INCOHERENT
$INCOHERENT_CASES
INCOHERENT

# The invariant must not swallow the coherent inputs it sits beside: a legacy
# or v1 policy is a coherent older shape the audit reports on, not an
# incoherent one, and an empty `# managed:` line is a valid zero-skill answer.
c="$(make_consumer inv-coherent-legacy "$LEGACY_POLICY" v0.34.1 integrate:pre)"
run_audit "$c"
expect_status "invariant: a coherent legacy policy still gets a verdict, not exit 2" 0
c="$(make_consumer inv-coherent-v1 "$V1_POLICY" v0.34.1 integrate:pre)"
run_audit "$c"
expect_status "invariant: a coherent v1 policy still gets a verdict, not exit 2" 0
c="$(make_consumer inv-empty-managed "$LEGACY_POLICY" v0.34.1)"
run_audit "$c"
expect_status "invariant: an empty '# managed:' line is coherent, not damage" 0

echo
echo "== consumer-pin-audit: Codex cloud review round 1 regressions =="
# [P1] Version ordering must not depend on GNU `sort -V` (docs/conventions.md
# requires macOS bash 3.2 portability). The defect was silent: the pipeline
# fails, the comparison reads false, and pin lag degrades to a clean exit 0.
# Exercised by running the audit with a PATH whose `sort` rejects -V, the way
# BSD sort does.
bsd_sort_dir="$TMPROOT/bsd-sort-bin"
mkdir -p "$bsd_sort_dir"
cat >"$bsd_sort_dir/sort" <<'BSDSORT'
#!/bin/sh
for a in "$@"; do
    case "$a" in
    -V | --version-sort) echo "sort: illegal option -- V" >&2; exit 2 ;;
    esac
done
exec /usr/bin/sort "$@"
BSDSORT
chmod +x "$bsd_sort_dir/sort"
c="$(make_consumer bsd-sort-pin-lag "$V2_POLICY" v0.39.0 gauntlet:pre shepherd:pre)"
set +e
out="$(PATH="$bsd_sort_dir:$PATH" "$AUDIT" --repo-root "$c" 2>&1)"
status=$?
set -e
expect_status "pin lag is still detected where sort(1) has no -V" 3
expect_says "the no-GNU-sort run still names the boundary" "$V2_BOUNDARY"

# (The pre-v2 interrupted-sync pair that used to sit here asserted a verdict
# the deleted mechanism produced by guessing. Contract-free unstamped
# directories are undecidable offline and are covered above by
# `contract-free-dirs`, which asserts the stated limitation instead.)

# [P2] A legacy provenance stamp (no `# managed:` line) is a valid older
# generation that sync-skills.sh's own managed_names still honours, not damage.
c="$(make_consumer legacy-stamp "$V2_POLICY" v0.34.1 gauntlet:pre)"
printf '# ref: v0.34.1 (deadbeef)\n# categories: universal\n' \
    >"$c/.claude/skills/.SKILLS_PROVENANCE"
run_audit "$c"
expect_status "a legacy stamp without '# managed:' is audited, not refused" 3
expect_says "the legacy-stamp verdict is pin lag from its recorded ref" "advance source.ref"

# [P2] A policy AHEAD of the vendored skills must never be told to migrate
# down to the skills' version.
c="$(make_consumer ahead-policy "$TMPROOT/future-policy.toml" v0.41.0 review:v2)"
run_audit "$c"
expect_status "a policy ahead of the skills is incompatible" 1
expect_says "it says the policy is ahead of these skills" "ahead of these skills"
expect_not_says "it never tells a newer policy to run copier update" "copier update"

echo
echo "== consumer-pin-audit: Codex cloud review round 2 regressions =="
# [P1] A legacy stamp must not be ASSUMED pre-boundary: an older synchronizer
# can write that format while vendoring a post-boundary ref, and an empty
# managed set then inspects no contract at all.
c="$(make_consumer legacy-stamp-post-boundary "$LEGACY_POLICY" v9.0.0 review:v2)"
printf '# ref: v9.0.0 (deadbeef)\n# categories: universal\n' \
    >"$c/.claude/skills/.SKILLS_PROVENANCE"
run_audit "$c"
expect_status "a legacy stamp recording a post-boundary ref is indeterminate" 2
expect_says "it says the set cannot be assumed pre-v2" "cannot be assumed pre-v2"

# [P2] An explicitly EMPTY managed list is "vendored nothing", never pin lag.
c="$(make_consumer empty-managed-migrated "$V2_POLICY" v0.34.1)"
run_audit "$c"
expect_status "an explicitly empty managed set over a migrated policy is not pin lag" 0
expect_says "it says the consumer vendors no skills at all" "vendors no skills at all"

# [P2] A contract whose version is a JSON *string* must not pass as an integer.
c="$(make_consumer string-contract-version "$LEGACY_POLICY" v0.41.0 review:v2)"
printf '{"skill":"review","policy_schema_version":"2"}\n' \
    >"$c/.claude/skills/review/assets/policy-contract.json"
run_audit "$c"
expect_status "a string-typed contract version is indeterminate" 2
expect_says "it requires a JSON number" "JSON number"

# [P2] The residue check must not fire in a SOURCE-linked tree (symlinked
# skills beside real local ones) — this repository's own shape once #711
# migrates its policy.
c="$(make_consumer source-linked-migrated "$V2_POLICY" v0.41.0)"
rm -f "$c/.claude/skills/.SKILLS_PROVENANCE"
mkdir -p "$c/ai/skills/universal/review" "$c/.claude/skills/openspec-local"
printf -- '---\nname: review\ndescription: f\n---\n' >"$c/ai/skills/universal/review/SKILL.md"
printf -- '---\nname: openspec-local\ndescription: f\n---\n' >"$c/.claude/skills/openspec-local/SKILL.md"
# The link must resolve into <repo>/ai/skills/ — that is the source-repo
# signature the exemption keys on, not "a symlink exists somewhere".
ln -s ../../ai/skills/universal/review "$c/.claude/skills/review"
run_audit "$c"
expect_status "a source-linked tree with real local skills is not interrupted-sync residue" 0
expect_says "it is still reported as never vendored" "no skills are vendored here"

echo
echo "== devflow-policy: a policy ahead of this reader is not sent backwards =="
# [P2] detect/resolve must not tell a future policy to migrate down to 2.
ahead_policy="$TMPROOT/ahead-policy.toml"
printf 'schema_version = 9\ndefault_rigor = "standard"\n' >"$ahead_policy"
set +e
out="$(node "$READER" detect --policy "$ahead_policy" --json 2>/dev/null)"
status=$?
set -e
expect_status "detect still refuses a policy ahead of the reader" 1
if printf '%s' "$out" | jq -e '.migration | test("upgrade the tooling")' >/dev/null 2>&1 &&
    printf '%s' "$out" | jq -e '.migration | test("copier update") | not' >/dev/null 2>&1; then
    ok "an ahead policy is told to upgrade the tooling, never to copier update backwards"
else
    bad "the ahead-policy refusal still recommends migrating the policy backwards"
    printf '%s\n' "$out" | sed 's/^/      /' >&2
fi
# The ordinary older-shape message must be unchanged.
set +e
out="$(node "$READER" detect --policy "$LEGACY_POLICY" --json 2>/dev/null)"
set -e
if printf '%s' "$out" | jq -e '.migration | test("copier update")' >/dev/null 2>&1; then
    ok "an older-shape policy still gets the copier update remedy"
else
    bad "the older-shape refusal lost its copier update remedy"
fi

echo
echo "== consumer-pin-audit: unstamped residue is decided ONLY by a policy contract =="
# The tree-wide "source checkout" exemption is deleted, not scoped again: it
# produced a P1 in three consecutive rounds (#845 and its predecessors) and
# existed only to undo a companion check that counted every real directory as
# residue — a question this audit cannot decide, since with no stamp
# sync-skills.sh's own rule is that nothing is managed. One provable rule
# remains: a REAL directory carrying a policy contract, with no stamp, is
# vendored v2 residue.

# Provable residue is still caught, whatever else is in the tree.
c="$(make_consumer provable-residue "$V2_POLICY" v0.41.0 review:v2)"
rm -f "$c/.claude/skills/.SKILLS_PROVENANCE"
run_audit "$c"
expect_status "an unstamped contract-carrying directory is indeterminate" 2
expect_says "the residue error names the skill it found" "review"

# ...including beside a symlink, which is the #845 fail-open: no tree-wide
# state exists any more, so nothing can suppress the check for a sibling.
c="$(make_consumer provable-residue-beside-link "$V2_POLICY" v0.41.0 review:v2)"
rm -f "$c/.claude/skills/.SKILLS_PROVENANCE"
mkdir -p "$c/ai/skills/universal/local"
printf -- '---\nname: local\ndescription: f\n---\n' >"$c/ai/skills/universal/local/SKILL.md"
ln -s ../../ai/skills/universal/local "$c/.claude/skills/local"
run_audit "$c"
expect_status "a source symlink cannot suppress a sibling's residue check (#845)" 2

# A symlink is skipped as an ENTRY — provably, since `cp -R` makes real
# directories — and a source checkout legitimately links to contract-carrying
# skills, which is this repository's own shape.
c="$(make_consumer symlinked-contract-skill "$V2_POLICY" v0.41.0)"
rm -f "$c/.claude/skills/.SKILLS_PROVENANCE"
mkdir -p "$c/ai/skills/universal/review/assets"
printf -- '---\nname: review\ndescription: f\n---\n' >"$c/ai/skills/universal/review/SKILL.md"
printf '{"skill":"review","policy_schema_version":2}\n' \
    >"$c/ai/skills/universal/review/assets/policy-contract.json"
ln -s ../../ai/skills/universal/review "$c/.claude/skills/review"
run_audit "$c"
expect_status "a symlinked contract-carrying skill is not residue" 0

# Contract-FREE directories are undecidable and are no longer guessed at: the
# verdict says so and names the tool that can decide it by cloning the pin.
# This is the deliberate trade for deleting the mechanism — stated, not silent.
c="$(make_consumer contract-free-dirs "$V2_POLICY" v0.39.0 gauntlet:pre)"
rm -f "$c/.claude/skills/.SKILLS_PROVENANCE"
run_audit "$c"
expect_status "contract-free unstamped directories are not guessed at" 0
expect_says "the verdict states the limitation" "cannot tell a contract-free local skill"
expect_says "and names the check that can decide it" "task verify:skills"

echo
echo "== devflow-policy: an older shape is refused with one actionable message =="
for shape in legacy v1 mixed; do
    case "$shape" in
    legacy) src="$LEGACY_POLICY" ;;
    v1) src="$V1_POLICY" ;;
    mixed) src="$MIXED_POLICY" ;;
    esac
    for mode in detect resolve; do
        set +e
        out="$(node "$READER" "$mode" --policy "$src" 2>&1)"
        status=$?
        set -e
        expect_status "$mode refuses a $shape policy" 1
        expect_says "$mode's $shape refusal names copier update" "copier update"
        expect_says "$mode's $shape refusal names the harmon-init release" "$V2_RELEASE"
        expect_says "$mode's $shape refusal names the pin to hold" \
            "pinned to the last pre-v2 skills release"
    done
done

echo
echo "== devflow-policy: the version-2 success path =="
set +e
out="$(node "$READER" detect --policy "$V2_POLICY" --json 2>&1)"
status=$?
set -e
expect_status "detect accepts a version-2 policy" 0
if printf '%s' "$out" | jq -e '.shape == "v2" and .migration == null and .policy_schema_version == 2' >/dev/null 2>&1; then
    ok "a version-2 policy carries no migration message and declares version 2"
else
    bad "detect on a version-2 policy did not report a clean v2 result"
    printf '%s\n' "$out" | sed 's/^/      /' >&2
fi

# Supply the fixture's own registry and Taskfile target list: without them
# cross-validation is indeterminate (exit 3) and the run would not prove the
# clean success path this case exists for.
set +e
out="$(node "$READER" resolve --policy "$V2_POLICY" --json \
    --registry "$FIX/single-round-clean-converge/registry.json" \
    --task-targets "$FIX/single-round-clean-converge/task-targets.json" 2>&1)"
status=$?
set -e
expect_status "resolve accepts a version-2 policy" 0
if printf '%s' "$out" | jq -e '.rounds.challenge != null and .rounds.integration != null' >/dev/null 2>&1; then
    ok "resolve returns the version-2 round caps"
else
    bad "resolve on a version-2 policy did not return round caps"
    printf '%s\n' "$out" | sed 's/^/      /' >&2
fi

echo
echo "== the closure recipe validates the BRANCH policy, not only the merge base =="
# Codex cloud review final cycle, confirmed on this repository's own fixture:
# `cliResolve` selects only `--merge-base-registry` when a merge-base policy is
# in play, so a recipe that omits `--registry` leaves `branch_cross_validation`
# null and never checks the branch policy against the registry that becomes
# active after merge. A self-modifying policy change could then ship an invalid
# finder reference.
BXV="$repo/ai/schemas/fixtures/exit/merge-base-branch-cross-validation-visible"
if [ -d "$BXV" ]; then
    # `resolve` legitimately exits non-zero here (gate slugs are indeterminate
    # without a Taskfile target list), so shield both runs from `set -e`.
    set +e
    out="$(node "$READER" resolve --policy "$BXV/policy.toml" \
        --merge-base-policy "$BXV/policy.merge-base.toml" \
        --merge-base-registry "$BXV/registry.json" --json 2>/dev/null)"
    set -e
    if printf '%s' "$out" | jq -e '.branch_cross_validation == null' >/dev/null 2>&1; then
        ok "omitting --registry really does leave branch_cross_validation null (the defect)"
    else
        bad "the fixture no longer reproduces the omitted-branch-registry state"
    fi
    set +e
    out="$(node "$READER" resolve --policy "$BXV/policy.toml" \
        --merge-base-policy "$BXV/policy.merge-base.toml" \
        --merge-base-registry "$BXV/registry.json" \
        --registry "$BXV/registry.json" --json 2>/dev/null)"
    set -e
    if printf '%s' "$out" | jq -e '.branch_cross_validation.errors | length > 0' >/dev/null 2>&1; then
        ok "supplying --registry surfaces the branch policy's own errors"
    else
        bad "supplying --registry did not surface the branch policy's errors"
        printf '%s\n' "$out" | sed 's/^/      /' >&2
    fi
else
    bad "fixture merge-base-branch-cross-validation-visible is missing"
fi

# The recipe itself must carry the flag and the obligation to settle what it
# reports — the reader deliberately keeps branch_cross_validation out of its
# exit code, so reading it is the operator's job and the skill has to say so.
INTEGRATE_MD="$repo/ai/skills/universal/integrate/SKILL.md"
if grep -q -- '--registry agent-registry.json' "$INTEGRATE_MD"; then
    ok "the closure recipe passes the branch registry"
else
    bad "the closure recipe does not pass --registry agent-registry.json"
fi
if grep -q 'branch_cross_validation.errors` entry as a finding to settle' "$INTEGRATE_MD"; then
    ok "the recipe requires branch_cross_validation errors to be settled before readiness"
else
    bad "the recipe does not require branch_cross_validation errors to be settled"
fi

echo
echo "== the successor stage skills declare the contract the audit reads =="
for skill in review integrate orchestrator; do
    contract="$repo/ai/skills/universal/$skill/assets/policy-contract.json"
    if [ -f "$contract" ] &&
        jq -e --arg s "$skill" '.policy_schema_version == 2 and .skill == $s' "$contract" >/dev/null 2>&1; then
        ok "/$skill declares policy_schema_version 2"
    else
        bad "/$skill does not declare policy_schema_version 2 in assets/policy-contract.json"
    fi
done

echo
echo "== the successor stage skills carry no legacy-shape branch =="
# The pre-v1 legacy vocabulary must not survive as an ALTERNATE RESOLUTION
# PATH in any successor skill. `shepherd` as a merge-base decoder field name
# is allowed (it is what the older file literally calls that budget), so the
# guard targets the resolution vocabulary itself.
for skill in review integrate orchestrator implement retro; do
    md="$repo/ai/skills/universal/$skill/SKILL.md"
    [ -f "$md" ] || continue
    if grep -nE 'default_tier|default_method|\[method\]|per-stage[, ]*(to the )?highest|highest cap present' "$md" >/dev/null 2>&1; then
        bad "/$skill still resolves the legacy shape"
        grep -nE 'default_tier|default_method|\[method\]|per-stage[, ]*(to the )?highest|highest cap present' "$md" | sed 's/^/      /' >&2
    else
        ok "/$skill carries no legacy-shape resolution"
    fi
done

echo
echo "consumer-pin-audit tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
