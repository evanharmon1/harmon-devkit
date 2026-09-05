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
c="$(make_consumer pin-lag "$V2_POLICY" v0.34.1 integrate:pre orchestrator:pre)"
run_audit "$c"
expect_status "a migrated policy under pre-v2 skills is pin lag, not a pass" 3
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
expect_says "it says nothing was vendored" "vendored no skills"

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
echo "== consumer-pin-audit: a damaged provenance stamp is indeterminate =="
# Challenge round 1: with the `# managed:` line gone, the managed set read as
# empty, nothing declared a requirement, and genuinely-vendored v2 skills over
# a legacy policy were reported compatible. A stamp this audit treats as
# authoritative must fail closed when it is unreadable.
c="$(make_consumer damaged-managed "$LEGACY_POLICY" v0.41.0 review:v2 integrate:v2)"
grep -v '^# managed:' "$c/.claude/skills/.SKILLS_PROVENANCE" >"$c/prov.tmp"
mv "$c/prov.tmp" "$c/.claude/skills/.SKILLS_PROVENANCE"
run_audit "$c"
expect_status "provenance with no '# managed:' line is indeterminate, not a pass" 2
expect_says "the damaged-provenance error names the missing line" "no '# managed:' line"

c="$(make_consumer damaged-ref "$LEGACY_POLICY" v0.41.0 review:v2)"
grep -v '^# ref:' "$c/.claude/skills/.SKILLS_PROVENANCE" >"$c/prov.tmp"
mv "$c/prov.tmp" "$c/.claude/skills/.SKILLS_PROVENANCE"
run_audit "$c"
expect_status "provenance with no '# ref:' line is indeterminate, not a pass" 2
expect_says "the missing-ref error names the missing line" "no '# ref:' line"

# The counterpart that must NOT fail: an EMPTY `# managed:` is what
# sync-skills.sh writes when it legitimately manages nothing.
c="$(make_consumer empty-managed "$LEGACY_POLICY" v0.34.1)"
run_audit "$c"
expect_status "an empty '# managed:' line is a valid zero-skill answer, not damage" 0
expect_says "an empty managed set requires nothing" "requiring skills: none"

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
expect_says "it is still reported as never vendored" "vendored no skills"

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
expect_says "the symlinked source is reported as never vendored" "vendored no skills"

echo
echo "== consumer-pin-audit: a contract-free vendored subset is not pin lag =="
# Challenge round 2, confirmed: a manifest vendoring only categories with no
# policy-consuming skill returned pin-lag forever over a migrated policy,
# telling the operator to advance and re-sync when that could never help.
c="$(make_consumer no-policy-consumer "$V2_POLICY" v9.0.0 some-frontend-skill:pre another:pre)"
run_audit "$c"
expect_status "a vendored set with no policy-consuming skill is not pin lag" 0
expect_says "it says advancing the pin would not add a contract" "advancing the pin would not add one"
expect_not_says "it does not tell anyone to re-sync pointlessly" "task sync:skills"

# The genuine pin-lag case must still fire: the policy-consuming skills ARE
# vendored, they just predate the contract.
c="$(make_consumer real-pin-lag "$V2_POLICY" v0.34.1 integrate:pre review:pre)"
run_audit "$c"
expect_status "policy-consuming skills without a contract over a migrated policy is pin lag" 3
expect_says "real pin lag still says to advance source.ref" "advance source.ref"

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
echo "== consumer-pin-audit: a mixed policy fails closed, never compatible =="
# Challenge round 4, confirmed by reproduction: a policy declaring
# `schema_version = 2` alongside a legacy marker detects as `mixed` (reader
# exits 1) while still reporting version 2, so the equality-only test set
# satisfied=yes and the audit exited 0 `compatible` on a policy the reader had
# just refused — a fail-open introduced by round 3's own fix.
mixed_policy="$TMPROOT/mixed-policy.toml"
printf 'schema_version = 2\ndefault_method = "plan"\n[method]\nrank = ["oneshot"]\n' >"$mixed_policy"
set +e
out="$(node "$READER" detect --policy "$mixed_policy" --json 2>/dev/null)"
status=$?
set -e
expect_status "the reader refuses a mixed policy" 1
if printf '%s' "$out" | jq -e '.shape == "mixed" and .policy_schema_version == 2' >/dev/null 2>&1; then
    ok "the reader reports a mixed shape while still naming its declared version"
else
    bad "the mixed fixture did not reproduce the reader state this case guards"
    printf '%s\n' "$out" | sed 's/^/      /' >&2
fi

c="$(make_consumer mixed-over-v2-skills "$mixed_policy" v0.41.0 review:v2 integrate:v2)"
run_audit "$c"
expect_status "a mixed policy is indeterminate, never compatible" 2
expect_says "the mixed refusal says the policy is two shapes at once" "more than one shape at once"

# A mixed policy is not a pin question either: it must refuse whatever the pin.
c="$(make_consumer mixed-over-pre-v2-skills "$mixed_policy" v0.34.1 integrate:pre)"
run_audit "$c"
expect_status "a mixed policy refuses under a pre-v2 pin too, rather than reporting pin lag" 2

echo
echo "== consumer-pin-audit: a contract version must be a positive integer =="
# Challenge round 4, confirmed: `0` passed the digit-only check and then
# collapsed into `required = 0`, which reads as "no contract at all", so a
# damaged contract over a legacy policy reported compatible exit 0.
c="$(make_consumer zero-contract "$LEGACY_POLICY" v0.41.0 review:v2)"
printf '{"skill":"review","policy_schema_version":0}\n' \
    >"$c/.claude/skills/review/assets/policy-contract.json"
run_audit "$c"
expect_status "a contract declaring version 0 is indeterminate, not 'no contract'" 2
expect_says "the zero-version error says it must be positive" "must be a positive integer"

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
