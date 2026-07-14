#!/usr/bin/env bash
# test-skills.sh — unit tests for the skills tooling:
#   * verify-skills.sh  (source-of-truth guard for ai/skills/)
#   * sync-skills.sh    (pinned pull-based vendoring engine)
#
# Fully hermetic and offline: builds throwaway git repos in temp dirs and drives
# the real scripts against them (the engine clones over file://, exercising the
# same code path as a real https remote). Run via `task test:skills`.
set -euo pipefail

repo="$(git rev-parse --show-toplevel)"
SCRIPTS="$repo/scripts"
STANDARDIZE_ASSETS="$repo/ai/skills/repo/standardize-repo/assets"

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

# Run a command, succeed the assertion iff it exits 0.
expect_ok() {
    local desc="$1"
    shift
    if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc (expected exit 0)"; fi
}
# Run a command, succeed the assertion iff it exits non-zero.
expect_fail() {
    local desc="$1"
    shift
    if "$@" >/dev/null 2>&1; then bad "$desc (expected non-zero exit)"; else ok "$desc"; fi
}

git_init() { git init -q "$1"; }
git_commit_all() {
    git -C "$1" add -A
    git -C "$1" -c user.email=test@example.com -c user.name=test \
        -c commit.gpgsign=false commit -q -m "$2"
}

# mkskill DIR NAME [DESC] — write a minimal valid SKILL.md into DIR.
mkskill() {
    mkdir -p "$1"
    {
        echo "---"
        echo "name: $2"
        echo "description: ${3:-A test skill named $2.}"
        echo "---"
        echo ""
        echo "# $2"
    } >"$1/SKILL.md"
}

# ── verify-skills.sh (source guard) ────────────────────────────────────
echo "==> verify-skills.sh"

# A clean tree passes.
G1="$TMPROOT/guard-clean"
git_init "$G1"
mkskill "$G1/ai/skills/frontend/alpha" alpha
mkskill "$G1/ai/skills/repo/bravo" bravo
mkdir -p "$G1/ai/skills/frontend/draft-placeholder" # no SKILL.md -> skipped, not failed
expect_ok "clean skills tree passes" bash -c "cd '$G1' && bash '$SCRIPTS/verify-skills.sh'"

# Duplicate skill name across two categories fails.
G2="$TMPROOT/guard-dup"
git_init "$G2"
mkskill "$G2/ai/skills/frontend/shared" shared
mkskill "$G2/ai/skills/backend/shared" shared
expect_fail "duplicate name across categories fails" bash -c "cd '$G2' && bash '$SCRIPTS/verify-skills.sh'"

# Frontmatter name != directory name fails.
G3="$TMPROOT/guard-name"
git_init "$G3"
mkskill "$G3/ai/skills/frontend/charlie" not-charlie
expect_fail "frontmatter name != dir name fails" bash -c "cd '$G3' && bash '$SCRIPTS/verify-skills.sh'"

# Missing description fails.
G4="$TMPROOT/guard-desc"
git_init "$G4"
mkdir -p "$G4/ai/skills/frontend/delta"
{
    echo "---"
    echo "name: delta"
    echo "---"
    echo "# delta"
} >"$G4/ai/skills/frontend/delta/SKILL.md"
expect_fail "missing description fails" bash -c "cd '$G4' && bash '$SCRIPTS/verify-skills.sh'"

# Missing frontmatter fence fails.
G5="$TMPROOT/guard-nofm"
git_init "$G5"
mkdir -p "$G5/ai/skills/frontend/echo"
echo "# echo (no frontmatter)" >"$G5/ai/skills/frontend/echo/SKILL.md"
expect_fail "missing frontmatter fails" bash -c "cd '$G5' && bash '$SCRIPTS/verify-skills.sh'"

# ── sync-skills.sh (vendoring engine) ──────────────────────────────────
echo "==> sync-skills.sh"

# Build a source "devkit" repo with two categories, one draft (no SKILL.md).
SRC="$TMPROOT/devkit"
git_init "$SRC"
mkskill "$SRC/ai/skills/universal/uni-one" uni-one
mkskill "$SRC/ai/skills/frontend/fe-one" fe-one
# fe-one carries nested content (like the real skills' assets/ + references/).
mkdir -p "$SRC/ai/skills/frontend/fe-one/assets" "$SRC/ai/skills/frontend/fe-one/references"
echo "echo hi" >"$SRC/ai/skills/frontend/fe-one/assets/helper.sh"
echo "# reference doc" >"$SRC/ai/skills/frontend/fe-one/references/doc.md"
mkdir -p "$SRC/ai/skills/emptycat" # a present-but-empty category
touch "$SRC/ai/skills/emptycat/.gitkeep"
mkdir -p "$SRC/ai/skills/frontend/fe-draft" # no SKILL.md -> must be skipped on vendor
touch "$SRC/ai/skills/frontend/fe-draft/.gitkeep"
mkskill "$SRC/ai/skills/backend/be-one" be-one # not requested -> must NOT vendor
git_commit_all "$SRC" "init"
git -C "$SRC" tag v0.0.0-test

# Consumer repo + manifest requesting universal + frontend.
CON="$TMPROOT/consumer"
mkdir -p "$CON"
write_manifest() {
    cat >"$CON/.skills-sync.yaml" <<EOF
source:
  repo: file://$SRC
  ref: $1
categories:
$(for c in "${@:2}"; do echo "  - $c"; done)
dest: vendored/skills
EOF
}
write_manifest v0.0.0-test universal frontend

run_sync() { (cd "$CON" && bash "$SCRIPTS/sync-skills.sh" "$@"); }

# Before the first sync there is no provenance -> drift checks skip cleanly.
# This is what keeps a fresh scaffold's CI + pre-push green until first sync.
expect_ok "verify skips cleanly before first sync (no clone)" run_sync verify
expect_ok "verify-offline skips cleanly before first sync" run_sync verify-offline

expect_ok "sync vendors the pinned ref" run_sync sync
prov="$CON/vendored/skills/.SKILLS_PROVENANCE"
expect_ok "requested universal skill vendored (flattened)" test -f "$CON/vendored/skills/uni-one/SKILL.md"
expect_ok "requested frontend skill vendored (flattened)" test -f "$CON/vendored/skills/fe-one/SKILL.md"
expect_ok "unrequested category not vendored" test ! -e "$CON/vendored/skills/be-one"
expect_ok "draft dir without SKILL.md skipped" test ! -e "$CON/vendored/skills/fe-draft"
expect_ok "categories are flattened (no category dirs)" test ! -e "$CON/vendored/skills/universal"
expect_ok "nested skill assets/ vendored intact" test -f "$CON/vendored/skills/fe-one/assets/helper.sh"
expect_ok "nested skill references/ vendored intact" test -f "$CON/vendored/skills/fe-one/references/doc.md"
expect_ok "provenance records the ref" grep -q "^# ref: v0.0.0-test " "$prov"
expect_ok "provenance carries do-not-edit marker" grep -q "DO NOT EDIT" "$prov"
expect_ok "provenance lists the managed (vendored) dirs" grep -q "^# managed: fe-one, uni-one$" "$prov"

expect_ok "verify passes right after sync" run_sync verify
expect_ok "verify-offline passes right after sync" run_sync verify-offline

# Tamper a vendored skill -> drift check must fail, then re-sync heals it.
echo "tampered" >>"$CON/vendored/skills/uni-one/SKILL.md"
expect_fail "verify detects a hand-edited vendored skill" run_sync verify
expect_ok "re-sync heals the drift" run_sync sync
expect_ok "verify passes again after re-sync" run_sync verify

# Bump the manifest ref without re-syncing -> offline check must fail.
write_manifest v9.9.9-absent universal frontend
expect_fail "verify-offline fails when manifest ref != vendored ref" run_sync verify-offline
write_manifest v0.0.0-test universal frontend # restore

# Missing category -> sync fails clearly.
write_manifest v0.0.0-test universal nonexistent
expect_fail "sync fails on a missing category" run_sync sync
write_manifest v0.0.0-test universal frontend

# A present-but-empty category vendors zero skills but still succeeds (e.g.
# 'universal' before it has any skills) and still writes provenance.
write_manifest v0.0.0-test emptycat
expect_ok "sync succeeds with a present-but-empty category" run_sync sync
expect_ok "provenance written even when zero skills vendored" test -f "$CON/vendored/skills/.SKILLS_PROVENANCE"
expect_ok "verify passes on an empty (but synced) dest" run_sync verify
write_manifest v0.0.0-test universal frontend # restore

# Duplicate skill name across two requested categories -> sync fails.
SRC2="$TMPROOT/devkit-dup"
git_init "$SRC2"
mkskill "$SRC2/ai/skills/universal/clash" clash
mkskill "$SRC2/ai/skills/frontend/clash" clash
git_commit_all "$SRC2" "init"
git -C "$SRC2" tag v0.0.0-test
cat >"$CON/.skills-sync.yaml" <<EOF
source:
  repo: file://$SRC2
  ref: v0.0.0-test
categories:
  - universal
  - frontend
dest: vendored/skills
EOF
expect_fail "sync fails on duplicate skill name across categories" run_sync sync

# ── sync-skills.sh managed-set semantics ───────────────────────────────
# The dest is SHARED with the repo's own local skills; the sync owns only the
# dirs on the provenance `# managed:` line and never touches anything else.
echo "==> sync-skills.sh (managed set / local skills)"

# write_manifest_at DIR REF CATEGORY... — like write_manifest, for any consumer.
write_manifest_at() {
    local dir="$1" ref="$2"
    shift 2
    {
        echo "source:"
        echo "  repo: file://$SRC"
        echo "  ref: $ref"
        echo "categories:"
        for c in "$@"; do echo "  - $c"; done
        echo "dest: vendored/skills"
    } >"$dir/.skills-sync.yaml"
}
run_sync_at() {
    local dir="$1"
    shift
    (cd "$dir" && bash "$SCRIPTS/sync-skills.sh" "$@")
}
# make_legacy_stamp PROV REF CATEGORIES — rewrite PROV in the pre-managed-line
# (legacy, wholesale-managed) format the old engine wrote. CATEGORIES is the
# comma-separated list the legacy sync recorded (what it actually vendored).
make_legacy_stamp() {
    {
        echo "# VENDORED from harmon-devkit — DO NOT EDIT HERE."
        echo "# source: file://$SRC"
        echo "# ref: $2 ($(git -C "$SRC" rev-parse "$2"))"
        echo "# path: ai/skills"
        echo "# categories: $3"
        echo "# update: edit .skills-sync.yaml, then run 'task sync:skills' and commit."
    } >"$1"
}

# (a) A pre-existing local skill in the shared dest survives the sync.
CM="$TMPROOT/consumer-managed"
mkdir -p "$CM"
write_manifest_at "$CM" v0.0.0-test universal frontend
mkskill "$CM/vendored/skills/local-note" local-note "LOCAL skill — the sync must never touch this."
expect_ok "sync succeeds alongside a pre-existing local skill" run_sync_at "$CM" sync
expect_ok "local skill survives the sync" test -f "$CM/vendored/skills/local-note/SKILL.md"
expect_ok "managed line lists exactly the vendored dirs" \
    grep -q "^# managed: fe-one, uni-one$" "$CM/vendored/skills/.SKILLS_PROVENANCE"

# (b) verify ignores local-skill edits but still catches vendored drift.
expect_ok "verify passes with a local skill present" run_sync_at "$CM" verify
echo "local edit" >>"$CM/vendored/skills/local-note/SKILL.md"
expect_ok "verify ignores local-skill edits" run_sync_at "$CM" verify
echo "tampered" >>"$CM/vendored/skills/fe-one/SKILL.md"
expect_fail "verify still catches vendored drift alongside local skills" run_sync_at "$CM" verify
expect_ok "re-sync heals the vendored drift" run_sync_at "$CM" sync
expect_ok "re-sync preserved the local skill's edit" grep -q "local edit" "$CM/vendored/skills/local-note/SKILL.md"

# (e) Orphan cleanup: manifest drops a category -> verify flags the leftover
# managed dir; re-sync removes it; the local skill is untouched.
write_manifest_at "$CM" v0.0.0-test universal
expect_fail "verify flags a managed dir the pin no longer ships" run_sync_at "$CM" verify
expect_ok "re-sync after a category drop succeeds" run_sync_at "$CM" sync
expect_ok "dropped category's vendored skill removed" test ! -e "$CM/vendored/skills/fe-one"
expect_ok "local skill intact after the category drop" test -f "$CM/vendored/skills/local-note/SKILL.md"

# (c) A local dir colliding with an incoming vendored skill is a hard error
# BEFORE any deletion: nothing removed, no provenance written.
CC="$TMPROOT/consumer-collide"
mkdir -p "$CC"
write_manifest_at "$CC" v0.0.0-test universal frontend
mkskill "$CC/vendored/skills/uni-one" uni-one "LOCAL original — must not be clobbered."
mkskill "$CC/vendored/skills/keep-me" keep-me
if collide_out="$(run_sync_at "$CC" sync 2>&1)"; then
    bad "collision with a local skill fails the sync"
else
    ok "collision with a local skill fails the sync"
fi
if echo "$collide_out" | grep -q "local skill 'uni-one' collides"; then
    ok "collision names the local skill in the error"
else
    bad "collision names the local skill in the error"
fi
expect_ok "collision deleted nothing (local content intact)" \
    grep -q "must not be clobbered" "$CC/vendored/skills/uni-one/SKILL.md"
expect_ok "collision deleted nothing (other local skill intact)" test -f "$CC/vendored/skills/keep-me/SKILL.md"
expect_ok "no provenance written on collision" test ! -f "$CC/vendored/skills/.SKILLS_PROVENANCE"

# (d) Legacy stamp (no `# managed:` line), SAME ref: sync derives the owned set
# from the pin and upgrades the stamp; post-legacy local skills are never claimed.
CL="$TMPROOT/consumer-legacy"
mkdir -p "$CL"
write_manifest_at "$CL" v0.0.0-test universal frontend
run_sync_at "$CL" sync >/dev/null
make_legacy_stamp "$CL/vendored/skills/.SKILLS_PROVENANCE" v0.0.0-test "universal, frontend"
mkskill "$CL/vendored/skills/post-legacy" post-legacy "Local skill added AFTER the legacy sync."
expect_ok "verify with a legacy stamp ignores post-legacy local skills" run_sync_at "$CL" verify
expect_ok "legacy stamp (same ref): sync upgrades in place" run_sync_at "$CL" sync
expect_ok "legacy upgrade preserved the post-legacy local skill" test -f "$CL/vendored/skills/post-legacy/SKILL.md"
expect_ok "legacy upgrade wrote the managed line" \
    grep -q "^# managed: fe-one, uni-one$" "$CL/vendored/skills/.SKILLS_PROVENANCE"
expect_ok "verify passes after the legacy upgrade" run_sync_at "$CL" verify

# (d, edge) Legacy stamp + SAME ref + categories GROWN in the manifest: the
# owned set must come from the provenance's recorded categories, never the
# current manifest — otherwise a local dir matching a skill in the newly-added
# category would be wrongly claimed and clobbered. It must instead collide.
CG="$TMPROOT/consumer-legacy-grow"
mkdir -p "$CG"
write_manifest_at "$CG" v0.0.0-test universal
run_sync_at "$CG" sync >/dev/null
make_legacy_stamp "$CG/vendored/skills/.SKILLS_PROVENANCE" v0.0.0-test "universal"
mkskill "$CG/vendored/skills/fe-one" fe-one "LOCAL fe-one — predates the frontend category request."
cp "$CG/vendored/skills/.SKILLS_PROVENANCE" "$TMPROOT/legacy-grow-prov-before"
write_manifest_at "$CG" v0.0.0-test universal frontend # grow categories, same ref
if grow_out="$(run_sync_at "$CG" sync 2>&1)"; then
    bad "legacy + grown categories: colliding local dir fails the sync"
else
    ok "legacy + grown categories: colliding local dir fails the sync"
fi
if echo "$grow_out" | grep -q "local skill 'fe-one' collides"; then
    ok "legacy + grown categories: collision names the local skill"
else
    bad "legacy + grown categories: collision names the local skill"
fi
expect_ok "legacy + grown categories: local dir untouched" \
    grep -q "predates the frontend category request" "$CG/vendored/skills/fe-one/SKILL.md"
expect_ok "legacy + grown categories: vendored skill not deleted" test -f "$CG/vendored/skills/uni-one/SKILL.md"
expect_ok "legacy + grown categories: provenance not rewritten" \
    cmp -s "$CG/vendored/skills/.SKILLS_PROVENANCE" "$TMPROOT/legacy-grow-prov-before"

# (d+e) Legacy stamp + PIN BUMP: the owned set comes from a clone of the OLD
# ref; a skill the new pin dropped is cleaned up, the local skill survives.
mkskill "$SRC/ai/skills/universal/uni-two" uni-two
rm -rf "$SRC/ai/skills/frontend/fe-one"
git_commit_all "$SRC" "drop fe-one, add uni-two"
git -C "$SRC" tag v0.0.1-test
CP="$TMPROOT/consumer-legacy-bump"
mkdir -p "$CP"
write_manifest_at "$CP" v0.0.0-test universal frontend
run_sync_at "$CP" sync >/dev/null
make_legacy_stamp "$CP/vendored/skills/.SKILLS_PROVENANCE" v0.0.0-test "universal, frontend"
mkskill "$CP/vendored/skills/post-legacy" post-legacy "Local skill added AFTER the legacy sync."
write_manifest_at "$CP" v0.0.1-test universal frontend
expect_ok "legacy stamp + pin bump: sync re-derives the old vendored set" run_sync_at "$CP" sync
expect_ok "pin bump vendored the newly-shipped skill" test -f "$CP/vendored/skills/uni-two/SKILL.md"
expect_ok "pin bump cleaned up the skill the pin dropped" test ! -e "$CP/vendored/skills/fe-one"
expect_ok "pin bump preserved the post-legacy local skill" test -f "$CP/vendored/skills/post-legacy/SKILL.md"
expect_ok "managed line reflects the new pin" \
    grep -q "^# managed: uni-one, uni-two$" "$CP/vendored/skills/.SKILLS_PROVENANCE"
expect_ok "verify passes after the pin bump" run_sync_at "$CP" verify

# (f) Empty categories are called out explicitly in the sync summary.
CE="$TMPROOT/consumer-emptymsg"
mkdir -p "$CE"
write_manifest_at "$CE" v0.0.0-test emptycat
if empty_out="$(run_sync_at "$CE" sync 2>&1)" &&
    echo "$empty_out" | grep -qF "(0 skills — categories are empty at this ref)"; then
    ok "empty-category sync logs the 0-skills message"
else
    bad "empty-category sync logs the 0-skills message"
fi

# (g) Unsafe dest values are refused before any deletion (absolute path or a
# `..` traversal component that could reach outside the repo).
CD="$TMPROOT/consumer-dest-guard"
mkdir -p "$CD"
for bad in "/tmp/escape" "../../escape" "a/../../escape"; do
    {
        echo "source:"
        echo "  repo: file://$SRC"
        echo "  ref: v0.0.0-test"
        echo "categories:"
        echo "  - universal"
        echo "dest: $bad"
    } >"$CD/.skills-sync.yaml"
    expect_fail "sync refuses unsafe dest '$bad'" run_sync_at "$CD" sync
done

# ── standardize-repo audit assets ─────────────────────────────────────
echo "==> standardize-repo audit assets"

STANDARDIZE_REFS="$repo/ai/skills/repo/standardize-repo/references"
expect_fail "standardize-repo has no references to the deleted source follow-up doc" \
    grep -Riq 'sourceRepo''FollowUps' "$STANDARDIZE_REFS"

for rest_doc in \
    "$STANDARDIZE_REFS/mode-audit.md" \
    "$STANDARDIZE_REFS/post-generation-checklist.md" \
    "$STANDARDIZE_REFS/standards-catalog.md"; do
    rest_name="${rest_doc##*/}"
    expect_ok "$rest_name documents REST merge_queue support" \
        grep -qF 'supports `merge_queue`' "$rest_doc"
    expect_fail "$rest_name has no stale merge_queue rejection claim" \
        grep -Eiq '(rejects?|reject).{0,80}merge_queue|merge_queue.{0,80}(rejects?|reject)' "$rest_doc"
done

expect_ok "standards catalog documents the valid CODEOWNERS account default" \
    grep -qF '`author_git_provider_username` (a bare organization is not a valid CODEOWNERS' \
    "$STANDARDIZE_REFS/standards-catalog.md"
expect_ok "standards catalog documents the web-only skills-sync default" \
    grep -qF 'current template source defaults it on only for' \
    "$STANDARDIZE_REFS/standards-catalog.md"
expect_ok "standards catalog documents Foreman as deliberate opt-in" \
    grep -qF 'current template source now deliberately' \
    "$STANDARDIZE_REFS/standards-catalog.md"
expect_ok "update guidance documents the Foreman default transition" \
    grep -qF 'It was default-on when introduced in v3.26.1' \
    "$STANDARDIZE_REFS/mode-update.md"
expect_ok "new-repo guidance exposes the explicit CodeQL answer" \
    grep -qF '| `use_codeql` | bool |' \
    "$STANDARDIZE_REFS/mode-new-repo.md"
expect_ok "update guidance audits live Code Security capability read-only" \
    grep -qF '.security_and_analysis.code_security.status' \
    "$STANDARDIZE_REFS/mode-update.md"
expect_ok "audit guidance rejects fail-open CodeQL analysis" \
    grep -qF 'The analyze step must not use' \
    "$STANDARDIZE_REFS/mode-audit.md"
expect_ok "checklist does not treat CodeQL configuration as coverage" \
    grep -qF 'does not establish coverage.' \
    "$STANDARDIZE_REFS/post-generation-checklist.md"
expect_ok "catalog documents intentional CodeQL omission" \
    grep -qF 'use `use_codeql=false`, omit the workflow/badge/setup variable' \
    "$STANDARDIZE_REFS/standards-catalog.md"
expect_ok "applied-state verifier reads live Code Security capability" \
    grep -qF '.security_and_analysis.code_security.status' \
    "$STANDARDIZE_ASSETS/verify-applied.sh"
expect_ok "standards catalog documents the fail-closed locked Python audit" \
    grep -qF '`uv export --locked --all-extras --all-groups`' \
    "$STANDARDIZE_REFS/standards-catalog.md"
expect_fail "canonical guidance has no freshness-skipping frozen export" \
    rg -qF 'uv export --frozen' "$STANDARDIZE_REFS"
expect_ok "audit guidance locks existing-lock syncs in CI" \
    grep -qF '`uv sync --locked` (or first run `uv lock --check`)' \
    "$STANDARDIZE_REFS/mode-audit.md"
expect_ok "standards catalog documents bounded devcontainer smoke tests" \
    grep -qF 'lifecycle at `-k 30 1800`' \
    "$STANDARDIZE_REFS/standards-catalog.md"
expect_ok "standards catalog documents 1Password pre-validation" \
    grep -qF 'fully materializes and validates the item JSON' \
    "$STANDARDIZE_REFS/standards-catalog.md"
expect_ok "standards catalog documents the human-only op prerequisite" \
    grep -qF '`op` is a deliberate human-only toolchain exception' \
    "$STANDARDIZE_REFS/standards-catalog.md"
expect_ok "audit guidance checks repo-specific test gate reachability" \
    grep -qF 'A repo-specific test is a gate only when all three links exist' \
    "$STANDARDIZE_REFS/mode-audit.md"
expect_ok "update guidance checks workflow trigger semantics" \
    grep -qF 'run proves syntax, not trigger semantics.' \
    "$STANDARDIZE_REFS/mode-update.md"
expect_ok "catalog requires fail-closed aggregate result handling" \
    grep -qF 'that rejects only `failure` is fail-open.' \
    "$STANDARDIZE_REFS/standards-catalog.md"
expect_ok "audit guidance forbids shared fixed temp artifacts" \
    grep -qF 'On workflows that may use self-hosted runners, reject shared fixed `/tmp`' \
    "$STANDARDIZE_REFS/mode-audit.md"
expect_ok "catalog keeps public pull requests on hosted runners" \
    grep -qF '`pull_request` jobs must stay GitHub-hosted' \
    "$STANDARDIZE_REFS/standards-catalog.md"
expect_ok "catalog marks public PR runner policy as a manual residual" \
    grep -qF 'Runner trust boundary [manual residual / audit requirement]' \
    "$STANDARDIZE_REFS/standards-catalog.md"
expect_ok "catalog does not overclaim public PR runner enforcement" \
    grep -qF 'does not mechanically enforce hosted-only public PRs' \
    "$STANDARDIZE_REFS/standards-catalog.md"
expect_ok "audit guidance treats fork guards as defense in depth" \
    grep -qF 'A same-repository job guard is defense in' \
    "$STANDARDIZE_REFS/mode-audit.md"
expect_ok "audit guidance requires isolated self-hosted runner policy" \
    grep -qF 'groups and clean ephemeral/JIT isolation' \
    "$STANDARDIZE_REFS/mode-audit.md"
expect_ok "catalog makes tracked Terraform locks read-only in CI" \
    grep -qF '`terraform init -lockfile=readonly`' \
    "$STANDARDIZE_REFS/standards-catalog.md"
expect_ok "catalog preserves intentional local Terraform lock updates" \
    grep -qF 'intentional local provider' \
    "$STANDARDIZE_REFS/standards-catalog.md"
expect_ok "audit guidance orders plan and apply after validation" \
    grep -qF 'Plan/apply must be downstream of validation' \
    "$STANDARDIZE_REFS/mode-audit.md"
expect_ok "catalog requires exact saved-plan apply" \
    grep -qF 'display that exact artifact, and apply' \
    "$STANDARDIZE_REFS/standards-catalog.md"
expect_ok "catalog requires an always-emitted Terraform aggregate" \
    grep -qF 'A required `terraform-verify` must always emit on `push`, `pull_request`' \
    "$STANDARDIZE_REFS/mode-audit.md"
expect_ok "audit guidance rejects workflow-level Terraform path filters" \
    grep -qF 'internal change detector, not workflow-level path filters' \
    "$STANDARDIZE_REFS/mode-audit.md"
expect_ok "catalog binds Terraform skips to explicit predicates" \
    grep -qF 'predicates prove that result deliberate.' \
    "$STANDARDIZE_REFS/standards-catalog.md"
expect_ok "catalog namespaces Terraform CI artifacts per run" \
    grep -qF 'repository/run/attempt artifact key namespaces each run' \
    "$STANDARDIZE_REFS/standards-catalog.md"
expect_ok "catalog requires bounded Terraform state locking" \
    grep -qF 'use bounded state-lock waits (`-lock-timeout`), never' \
    "$STANDARDIZE_REFS/standards-catalog.md"
expect_ok "catalog always cleans Terraform CI artifacts" \
    grep -qF '`-lock=false`, and clean up under `if: always()`' \
    "$STANDARDIZE_REFS/standards-catalog.md"
expect_ok "catalog preserves exact approval for Terraform mutation" \
    grep -qF 'explicit approval for that exact operation' \
    "$STANDARDIZE_REFS/standards-catalog.md"

starter="$repo/templates/scriptTemplates/shellScriptTemplate.sh"
signal_fixture="$TMPROOT/shell-starter-signals.sh"
sed '$d' "$starter" >"$signal_fixture"
for signal_case in "INT 130" "TERM 143"; do
    signal="${signal_case% *}"
    expected="${signal_case#* }"
    cleanup_marker="$TMPROOT/cleanup-$signal"
    if CLEANUP_MARKER="$cleanup_marker" bash -c '
        . "$1"
        cleanup() { : >"${CLEANUP_MARKER:?}"; }
        kill "-$2" "$$"
        exit 99
    ' _ "$signal_fixture" "$signal" >/dev/null 2>&1; then
        rc=0
    else
        rc=$?
    fi
    if [ "$rc" -eq "$expected" ]; then
        ok "shell starter exits $expected on SIG$signal"
    else
        bad "shell starter exits $expected on SIG$signal (got $rc)"
    fi
    if [ -e "$cleanup_marker" ]; then
        ok "shell starter runs EXIT cleanup after SIG$signal"
    else
        bad "shell starter runs EXIT cleanup after SIG$signal"
    fi
done

VA_TARGET="$TMPROOT/verify-applied-codeowners"
mkdir -p "$VA_TARGET/.github"
printf '%s\n' '# Test instructions' >"$VA_TARGET/AGENTS.md"
ln -s AGENTS.md "$VA_TARGET/CLAUDE.md"
ln -s AGENTS.md "$VA_TARGET/GEMINI.md"
printf '%s\n' '* @ponderousdev' >"$VA_TARGET/.github/CODEOWNERS"
git_init "$VA_TARGET"
git_commit_all "$VA_TARGET" "record original code owner"
git -C "$VA_TARGET" branch -M main
git -C "$VA_TARGET" switch -q -c codeowner-migration
printf '%s\n' '* @evanharmon1' >"$VA_TARGET/.github/CODEOWNERS"

expect_fail "verify-applied rejects an unacknowledged CODEOWNERS migration" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$VA_TARGET"
expect_fail "verify-applied rejects an absent replacement owner" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" \
    --ack-codeowner-change @ponderousdev=@missing-owner "$VA_TARGET"
expect_fail "verify-applied rejects a stale CODEOWNERS acknowledgement" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" \
    --ack-codeowner-change @not-on-main=@evanharmon1 "$VA_TARGET"
expect_ok "verify-applied accepts the exact materialized CODEOWNERS migration" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" \
    --ack-codeowner-change @ponderousdev=@evanharmon1 "$VA_TARGET"

CQ_TARGET="$TMPROOT/verify-applied-codeql"
mkdir -p "$CQ_TARGET/.github/workflows" "$CQ_TARGET/docs/architecture"
printf '%s\n' '# Test instructions' >"$CQ_TARGET/AGENTS.md"
ln -s AGENTS.md "$CQ_TARGET/CLAUDE.md"
ln -s AGENTS.md "$CQ_TARGET/GEMINI.md"
git_init "$CQ_TARGET"
cat >"$CQ_TARGET/.github/workflows/build.yml" <<'EOF'
name: Build
on: workflow_dispatch
jobs:
  verify:
    runs-on: ubuntu-latest
    steps:
      - run: task verify
EOF

write_codeql_answer() {
    printf 'use_codeql: %s\n' "$1" >"$CQ_TARGET/.copier-answers.yml"
}
write_codeql_taskfile() {
    cat >"$CQ_TARGET/Taskfile.yml" <<'EOF'
version: "3"
tasks:
  verify:
    cmds: ["true"]
  check:
    cmds: ["true"]
  security:
    cmds: ["true"]
  status:setup:
    cmds: ["true"]
  install:hooks:
    cmds: ["true"]
EOF
}
write_codeql_workflow() {
    cat >"$CQ_TARGET/.github/workflows/codeql.yml" <<EOF
name: CodeQL
on: workflow_dispatch
jobs:
  analyze:
    if: vars.FULL_SECURITY_SCAN == 'true'
$1    runs-on: ubuntu-latest
    steps:
      - run: "true"
EOF
}

write_codeql_answer false
write_codeql_taskfile
printf '%s\n' 'CodeQL is enabled for first-party SAST.' \
    >"$CQ_TARGET/docs/architecture/security.md"
write_codeql_workflow ""
expect_fail "verify-applied rejects a CodeQL workflow when use_codeql=false" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$CQ_TARGET"
rm "$CQ_TARGET/.github/workflows/codeql.yml"
expect_fail "verify-applied requires the CodeQL-off SAST gap in security docs" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$CQ_TARGET"
printf '%s\n' 'CodeQL is deliberately omitted; first-party SAST is not configured.' \
    >"$CQ_TARGET/docs/architecture/security.md"
expect_ok "verify-applied accepts a clean intentional CodeQL omission" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$CQ_TARGET"

printf '%s\n' '[![CodeQL](badge)](actions/workflows/codeql.yml)' >"$CQ_TARGET/README.md"
expect_fail "verify-applied rejects a stale CodeQL badge when disabled" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$CQ_TARGET"
rm "$CQ_TARGET/README.md"
printf '%s\n' '# setup sets FULL_SECURITY_SCAN' >>"$CQ_TARGET/Taskfile.yml"
expect_fail "verify-applied rejects stale FULL_SECURITY_SCAN setup when disabled" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$CQ_TARGET"
write_codeql_taskfile

write_codeql_answer true
printf '%s\n' 'CodeQL is selected; live SARIF results establish coverage.' \
    >"$CQ_TARGET/docs/architecture/security.md"
expect_fail "verify-applied requires a workflow when use_codeql=true" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$CQ_TARGET"
write_codeql_workflow $'    continue-on-error: true\n'
expect_fail "verify-applied rejects fail-open CodeQL analysis" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$CQ_TARGET"
write_codeql_workflow ""

git -C "$CQ_TARGET" remote add origin https://github.com/example/codeql-fixture.git
FAKE_GH_BIN="$TMPROOT/codeql-fake-gh"
mkdir -p "$FAKE_GH_BIN"
cat >"$FAKE_GH_BIN/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\t%s\n' "${GH_TEST_VISIBILITY:-private}" "${GH_TEST_CODE_SECURITY:-unknown}"
EOF
chmod +x "$FAKE_GH_BIN/gh"
expect_fail "verify-applied rejects private CodeQL with Code Security disabled" \
    env PATH="$FAKE_GH_BIN:$PATH" GH_TEST_VISIBILITY=private \
    GH_TEST_CODE_SECURITY=disabled \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$CQ_TARGET"
expect_ok "verify-applied accepts private CodeQL with Code Security enabled" \
    env PATH="$FAKE_GH_BIN:$PATH" GH_TEST_VISIBILITY=private \
    GH_TEST_CODE_SECURITY=enabled \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$CQ_TARGET"
expect_ok "verify-applied defers an unreadable Code Security field to manual audit" \
    env PATH="$FAKE_GH_BIN:$PATH" GH_TEST_VISIBILITY=private \
    GH_TEST_CODE_SECURITY=unknown \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$CQ_TARGET"

manifest="$STANDARDIZE_ASSETS/template-owned-files.txt"
for required in \
    Brewfile \
    .skills-sync.yaml \
    scripts/shell-quality.sh \
    scripts/markdownlint.sh \
    scripts/secret-set-1p.sh \
    scripts/secret-set-gh.sh \
    scripts/python-audit.sh \
    scripts/terraform-changed.sh \
    scripts/terraform-ci.sh \
    scripts/test-terraform-ci.sh \
    scripts/sync-skills.sh \
    .github/workflows/close-milestone-on-release.yml \
    .foreman.toml \
    taskfiles/foreman.yml \
    scripts/foreman/cli.py; do
    expect_ok "template-owned manifest includes $required" grep -qxF "$required" "$manifest"
done

# Exercise executable-mode drift, equivalent mature layouts, and index-backed
# transient deletions end to end with a tiny local Copier template. The real
# manifest is reused, but only scripts/status.sh exists in its curated set.
DT_TEMPLATE="$TMPROOT/diff-template-source"
mkdir -p \
    "$DT_TEMPLATE/template/scripts" \
    "$DT_TEMPLATE/template/terraform" \
    "$DT_TEMPLATE/template/docs/decisions"
cat >"$DT_TEMPLATE/copier.yml" <<'EOF'
_min_copier_version: "9.4.0"
_subdirectory: template
project_name:
  type: str
  default: Test Project
EOF
cat >"$DT_TEMPLATE/template/scripts/status.sh" <<'EOF'
#!/usr/bin/env bash
echo status
EOF
chmod +x "$DT_TEMPLATE/template/scripts/status.sh"
for terraform_file in main.tf variables.tf outputs.tf; do
    printf '%s\n' '# starter' >"$DT_TEMPLATE/template/terraform/$terraform_file"
done
printf '%s\n' '# Example values' >"$DT_TEMPLATE/template/terraform/tfvars.env.example"
printf '%s\n' '# Record architecture decisions' \
    >"$DT_TEMPLATE/template/docs/decisions/0001-record-architecture-decisions.md"
git_init "$DT_TEMPLATE"
git_commit_all "$DT_TEMPLATE" "test template"
git -C "$DT_TEMPLATE" tag v1.0.0

DT_TARGET="$TMPROOT/diff-template-target"
mkdir -p \
    "$DT_TARGET/scripts" \
    "$DT_TARGET/terraform/environments/production" \
    "$DT_TARGET/docs/decisions"
cp "$DT_TEMPLATE/template/scripts/status.sh" "$DT_TARGET/scripts/status.sh"
chmod -x "$DT_TARGET/scripts/status.sh"
printf '%s\n' '# production root' \
    >"$DT_TARGET/terraform/environments/production/main.tf"
printf '%s\n' '# Record architecture decisions' \
    >"$DT_TARGET/docs/decisions/0007-record-architecture-decisions.md"
cat >"$DT_TARGET/.copier-answers.yml" <<EOF
_commit: v1.0.0
_src_path: file://$DT_TEMPLATE
project_name: Test Project
EOF

if mode_out="$(HARMON_INIT="$DT_TEMPLATE" bash "$STANDARDIZE_ASSETS/diff-template.sh" "$DT_TARGET" 2>&1)"; then
    bad "diff-template reports executable-mode drift (expected non-zero exit)"
elif printf '%s\n' "$mode_out" | grep -qF "MODE     scripts/status.sh"; then
    ok "diff-template reports executable-mode drift"
else
    bad "diff-template reports executable-mode drift (MODE diagnostic missing)"
fi
chmod +x "$DT_TARGET/scripts/status.sh"
git_init "$DT_TARGET"
git_commit_all "$DT_TARGET" "record mature target layout"

if equivalent_out="$(HARMON_INIT="$DT_TEMPLATE" bash "$STANDARDIZE_ASSETS/diff-template.sh" "$DT_TARGET" 2>&1)"; then
    ok "diff-template passes after executable mode is restored"
else
    bad "diff-template passes after executable mode is restored: $equivalent_out"
fi
if printf '%s\n' "$equivalent_out" | grep -qF "EQUIV    terraform/main.tf"; then
    ok "diff-template recognizes nested Terraform roots as equivalent"
else
    bad "diff-template recognizes nested Terraform roots as equivalent"
fi
if printf '%s\n' "$equivalent_out" |
    grep -qF "EQUIV    docs/decisions/0001-record-architecture-decisions.md"; then
    ok "diff-template recognizes a renumbered seed ADR as equivalent"
else
    bad "diff-template recognizes a renumbered seed ADR as equivalent"
fi

rm "$DT_TARGET/scripts/status.sh"
expect_ok "diff-template compares an unstaged tracked deletion from the index" \
    env HARMON_INIT="$DT_TEMPLATE" bash "$STANDARDIZE_ASSETS/diff-template.sh" "$DT_TARGET"
git -C "$DT_TARGET" add -u -- scripts/status.sh
if staged_delete_out="$(HARMON_INIT="$DT_TEMPLATE" bash "$STANDARDIZE_ASSETS/diff-template.sh" "$DT_TARGET" 2>&1)"; then
    bad "diff-template reports a staged deletion (expected non-zero exit)"
elif printf '%s\n' "$staged_delete_out" | grep -qF "MISSING  scripts/status.sh"; then
    ok "diff-template reports a staged deletion as MISSING"
else
    bad "diff-template reports a staged deletion (MISSING diagnostic absent)"
fi

echo ""
echo "skills tooling tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
