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
    local output
    shift
    if output="$("$@" 2>&1)"; then
        ok "$desc"
    else
        bad "$desc (expected exit 0)"
        [ -z "$output" ] || printf '%s\n' "$output" | sed 's/^/      /' >&2
    fi
}
# Run a command, succeed the assertion iff it exits non-zero.
expect_fail() {
    local desc="$1"
    shift
    if "$@" >/dev/null 2>&1; then bad "$desc (expected non-zero exit)"; else ok "$desc"; fi
}
expect_ok_contains() {
    local desc="$1"
    local needle="$2"
    local output
    shift 2
    if ! output="$("$@" 2>&1)"; then
        bad "$desc (expected exit 0)"
        [ -z "$output" ] || printf '%s\n' "$output" | sed 's/^/      /' >&2
    elif printf '%s\n' "$output" | grep -qF "$needle"; then
        ok "$desc"
    else
        bad "$desc (missing output: $needle)"
        [ -z "$output" ] || printf '%s\n' "$output" | sed 's/^/      /' >&2
    fi
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
expect_ok "standards catalog documents the universal skills-sync default" \
    grep -qF 'currently defaults on for every project type' \
    "$STANDARDIZE_REFS/standards-catalog.md"
expect_ok "standards catalog documents the current Foreman default" \
    grep -qF 'It currently' \
    "$STANDARDIZE_REFS/standards-catalog.md"
expect_ok "update guidance requires an explicit Foreman decision" \
    grep -qF 'make an explicit per-repo decision' \
    "$STANDARDIZE_REFS/mode-update.md"
expect_ok "new-repo guidance derives CodeQL from stack flags" \
    grep -qF 'rather than a user-selectable Copier answer' \
    "$STANDARDIZE_REFS/mode-new-repo.md"
expect_ok "production scaffolding uses the canonical released template" \
    grep -qF 'https://github.com/evanharmon1/harmon-init.git <dest>' \
    "$STANDARDIZE_REFS/mode-new-repo.md"
expect_ok "production scaffolding pins a released ref" \
    grep -qF -- '--trust --vcs-ref=v4.1.1' \
    "$STANDARDIZE_REFS/mode-new-repo.md"
expect_ok "new-repo guidance forbids path-only lineage repair" \
    grep -qF 'do not rewrite only `_src_path`' \
    "$STANDARDIZE_REFS/mode-new-repo.md"
expect_ok "update guidance requires a remotely reachable recorded commit" \
    grep -qF 'only when the recorded commit is' \
    "$STANDARDIZE_REFS/mode-update.md"
expect_fail "new-repo production commands do not use a local template path" \
    grep -Eq '^copier copy .*harmon-init.*--vcs-ref=HEAD' \
    "$STANDARDIZE_REFS/mode-new-repo.md"
expect_ok "update guidance audits live Code Security capability read-only" \
    grep -qF '.security_and_analysis.code_security.status' \
    "$STANDARDIZE_REFS/mode-update.md"
expect_ok "audit guidance rejects fail-open CodeQL analysis" \
    grep -qF 'The analyze job/action must not use' \
    "$STANDARDIZE_REFS/mode-audit.md"
expect_ok "checklist does not treat CodeQL configuration as coverage" \
    grep -qF 'does not establish' \
    "$STANDARDIZE_REFS/post-generation-checklist.md"
expect_ok "catalog documents profile-driven CodeQL omission" \
    grep -qF 'No `codeql.yml`** when there is no Node/Python tooling profile' \
    "$STANDARDIZE_REFS/standards-catalog.md"
expect_ok "catalog distinguishes CodeQL source from tooling flags" \
    grep -qF '`use_node` and `use_python` describe tooling;' \
    "$STANDARDIZE_REFS/standards-catalog.md"
expect_ok "catalog requires the CodeQL matrix to match real source" \
    grep -qF 'generated matrix with real first-party source' \
    "$STANDARDIZE_REFS/standards-catalog.md"
expect_ok "audit guidance checks rendered CodeQL capability" \
    grep -qF 'CodeQL is not' \
    "$STANDARDIZE_REFS/mode-audit.md"
expect_ok "update guidance requires a deletion audit" \
    grep -qF 'Deletion audit — justify every removed pre-existing path.' \
    "$STANDARDIZE_REFS/mode-update.md"
expect_ok "update guidance always refreshes enabled skills sync" \
    grep -qF 'After **every** harmon-init update' \
    "$STANDARDIZE_REFS/mode-update.md"
expect_ok "skill makes credential failures human-only" \
    grep -qF 'Every credential step is human-only' \
    "$repo/ai/skills/repo/standardize-repo/SKILL.md"
expect_ok "skill completion requires green CI and review adjudication" \
    grep -qF 'every required PR check is green and every' \
    "$repo/ai/skills/repo/standardize-repo/SKILL.md"
expect_ok "catalog keeps fork aggregates from executing repository code" \
    grep -qF 'code on the aggregate runner' \
    "$STANDARDIZE_REFS/standards-catalog.md"
expect_ok "catalog normalizes an unset CodeQL scan opt-in" \
    grep -qF 'unset/empty `FULL_SECURITY_SCAN` normalizes to' \
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
expect_ok "catalog rejects generic success-or-skipped aggregates" \
    grep -qF 'never a generic' "$STANDARDIZE_REFS/standards-catalog.md"
expect_ok "catalog applies the exact contract to devcontainer aggregates" \
    grep -qF '`devcontainer-verify` aggregate follows the identical' \
    "$STANDARDIZE_REFS/standards-catalog.md"
expect_ok "catalog documents conditional Terraform required checks" \
    grep -qF 'when `include_terraform=true`,' \
    "$STANDARDIZE_REFS/standards-catalog.md"
expect_ok "catalog records CodeQL as a conditional required check" \
    grep -qF 'plus **`codeql-verify`** when a Node/Python' \
    "$STANDARDIZE_REFS/standards-catalog.md"
expect_ok "catalog records the three-route CodeQL result contract" \
    grep -qF 'successful not-applicable result only for free-private' \
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
expect_ok "catalog requires the four-part reachable Terraform lint contract" \
    grep -qF '`lint:terraform:security` (Renovate-pinned Checkov via' \
    "$STANDARDIZE_REFS/standards-catalog.md"
expect_ok "catalog requires both Terraform provider-lock platforms" \
    grep -qF 'exactly `darwin_arm64` (developer) and `linux_amd64` (GitHub CI)' \
    "$STANDARDIZE_REFS/standards-catalog.md"
expect_ok "catalog requires update-only Terraform init upgrades" \
    grep -qF 'passes `-upgrade` only in update mode' \
    "$STANDARDIZE_REFS/standards-catalog.md"
expect_ok "audit guidance rejects lock presence as platform evidence" \
    grep -qF 'file presence alone says nothing about platform' \
    "$STANDARDIZE_REFS/mode-audit.md"
expect_ok "audit guidance verifies both Terraform init modes" \
    grep -qF 'update initialization receives `-upgrade` while check' \
    "$STANDARDIZE_REFS/mode-audit.md"
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

# Exercise the build and devcontainer aggregate contract without any repository
# runtime. Fork diagnostics are workflow-inline, while trusted paths use the
# exact-result helper. The fixture proves both accepted branches and the two
# recurring false-green regressions.
AGG_TARGET="$TMPROOT/verify-applied-aggregates"
mkdir -p "$AGG_TARGET/.github/workflows" "$AGG_TARGET/scripts"
printf '%s\n' '# Test instructions' >"$AGG_TARGET/AGENTS.md"
ln -s AGENTS.md "$AGG_TARGET/CLAUDE.md"
ln -s AGENTS.md "$AGG_TARGET/GEMINI.md"

write_required_results_helper() {
    local mode="${1:-exact}"
    if [ "$mode" = generic ]; then
        cat >"$AGG_TARGET/scripts/verify-required-results.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
for pair in "$@"; do
    case "${pair#*=}" in success | skipped) ;; *) exit 1 ;; esac
done
EOF
    else
        cat >"$AGG_TARGET/scripts/verify-required-results.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
expected="${EXPECTED_RESULT:-success}"
case "$expected" in success | skipped) ;; *) exit 2 ;; esac
[ "$#" -gt 0 ] || exit 2
for pair in "$@"; do
    case "$pair" in *=*) ;; *) exit 2 ;; esac
    name="${pair%%=*}"
    result="${pair#*=}"
    [ -n "$name" ] && [ "$result" = "$expected" ] || exit 1
done
EOF
    fi
    chmod +x "$AGG_TARGET/scripts/verify-required-results.sh"
}

write_aggregate_workflows() {
    local mode="${1:-safe}"
    cat >"$AGG_TARGET/.github/workflows/build.yml" <<'EOF'
name: Build
on: [push, pull_request]
jobs:
  lint:
    if: >-
      github.event_name != 'pull_request' ||
      github.event.pull_request.head.repo.full_name == github.repository
    runs-on: ubuntu-latest
    steps:
      - run: echo lint
  security:
    if: >-
      github.event_name != 'pull_request' ||
      github.event.pull_request.head.repo.full_name == github.repository
    runs-on: ubuntu-latest
    steps:
      - run: echo security
  verify:
    if: always()
    needs: [lint, security]
    runs-on: ubuntu-latest
    env:
      IS_FORK: ${{ github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name != github.repository }}
    steps:
      - name: Verify deliberate skips at the untrusted-fork boundary
        if: env.IS_FORK == 'true'
        env:
          LINT_RESULT: ${{ needs.lint.result }}
          SECURITY_RESULT: ${{ needs.security.result }}
        run: |
          if [ "$LINT_RESULT" != "skipped" ] || [ "$SECURITY_RESULT" != "skipped" ]; then
            exit 1
          fi
          echo "Untrusted fork trust boundary enforced: all repository-controlled jobs were deliberately skipped."
      - if: env.IS_FORK != 'true'
        uses: actions/checkout@1111111111111111111111111111111111111111
      - name: Verify required jobs succeeded
        if: env.IS_FORK != 'true'
        env:
          EXPECTED_RESULT: success
          LINT_RESULT: ${{ needs.lint.result }}
          SECURITY_RESULT: ${{ needs.security.result }}
        run: ./scripts/verify-required-results.sh "lint=${LINT_RESULT}" "security=${SECURITY_RESULT}"
EOF
    cat >"$AGG_TARGET/.github/workflows/devcontainer-build.yml" <<'EOF'
name: Devcontainer
on: [push, pull_request]
jobs:
  build:
    if: >-
      github.event_name != 'pull_request' ||
      github.event.pull_request.head.repo.full_name == github.repository
    runs-on: ubuntu-latest
    steps:
      - run: echo build
  devcontainer-verify:
    if: always()
    needs: [build]
    runs-on: ubuntu-latest
    env:
      IS_FORK: ${{ github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name != github.repository }}
    steps:
      - name: Verify deliberate skip at the untrusted-fork boundary
        if: env.IS_FORK == 'true'
        env:
          BUILD_RESULT: ${{ needs.build.result }}
        run: |
          if [ "$BUILD_RESULT" != "skipped" ]; then
            exit 1
          fi
          echo "Untrusted fork trust boundary enforced: the repository-controlled devcontainer build was deliberately skipped."
      - if: env.IS_FORK != 'true'
        uses: actions/checkout@1111111111111111111111111111111111111111
      - name: Verify devcontainer build succeeded
        if: env.IS_FORK != 'true'
        env:
          EXPECTED_RESULT: success
          BUILD_RESULT: ${{ needs.build.result }}
        run: ./scripts/verify-required-results.sh "build=${BUILD_RESULT}"
EOF

    case "$mode" in
    safe) ;;
    unsafe-build-fork-code)
        sed -i.bak '/all repository-controlled jobs were deliberately skipped/i\
          ./scripts/fork-controlled.sh' \
            "$AGG_TARGET/.github/workflows/build.yml"
        rm "$AGG_TARGET/.github/workflows/build.yml.bak"
        ;;
    unsafe-devcontainer-fork-code)
        sed -i.bak '/repository-controlled devcontainer build was deliberately skipped/i\
          ./scripts/fork-controlled.sh' \
            "$AGG_TARGET/.github/workflows/devcontainer-build.yml"
        rm "$AGG_TARGET/.github/workflows/devcontainer-build.yml.bak"
        ;;
    missing-leaf-guard)
        sed -i.bak '/head.repo.full_name == github.repository/d' \
            "$AGG_TARGET/.github/workflows/build.yml"
        rm "$AGG_TARGET/.github/workflows/build.yml.bak"
        ;;
    *) fail "unknown aggregate fixture mode: $mode" ;;
    esac
}

write_required_check_ruleset() {
    local target="$1"
    local mode="${2:-baseline}"
    local extra_context=""
    case "$mode" in
    baseline) ;;
    terraform) extra_context=$',\n          {"context": "terraform-verify"}' ;;
    codeql) extra_context=$',\n          {"context": "codeql-verify"}' ;;
    *) fail "unknown ruleset fixture mode: $mode" ;;
    esac
    mkdir -p "$target/.github"
    cat >"$target/.github/Branch Protection Ruleset - Protect Main.json" <<EOF
{
  "rules": [
    {
      "type": "required_status_checks",
      "parameters": {
        "required_status_checks": [
          {"context": "verify"},
          {"context": "security"}$extra_context
        ]
      }
    }
  ]
}
EOF
}

write_required_results_helper
write_aggregate_workflows
write_required_check_ruleset "$AGG_TARGET"
git_init "$AGG_TARGET"
git_commit_all "$AGG_TARGET" "record aggregate fixture"
expect_ok "verify-applied accepts exact build and devcontainer result contracts" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$AGG_TARGET"
write_required_results_helper generic
expect_fail "verify-applied rejects a generic success-or-skipped result helper" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$AGG_TARGET"
write_required_results_helper
write_aggregate_workflows unsafe-build-fork-code
expect_fail "verify-applied rejects build fork diagnostics that run repository code" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$AGG_TARGET"
write_aggregate_workflows unsafe-devcontainer-fork-code
expect_fail "verify-applied rejects devcontainer fork diagnostics that run repository code" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$AGG_TARGET"
write_aggregate_workflows missing-leaf-guard
expect_fail "verify-applied rejects aggregated leaves without same-repo guards" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$AGG_TARGET"
write_aggregate_workflows
write_required_check_ruleset "$AGG_TARGET" terraform
expect_fail "verify-applied rejects terraform-verify for a non-Terraform repo" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$AGG_TARGET"
write_required_check_ruleset "$AGG_TARGET" codeql
expect_fail "verify-applied does not claim CodeQL is branch-required yet" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$AGG_TARGET"
write_required_check_ruleset "$AGG_TARGET"

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
mkdir -p \
    "$CQ_TARGET/.github/workflows" \
    "$CQ_TARGET/docs/architecture" \
    "$CQ_TARGET/scripts"
printf '%s\n' '# Test instructions' >"$CQ_TARGET/AGENTS.md"
ln -s AGENTS.md "$CQ_TARGET/CLAUDE.md"
ln -s AGENTS.md "$CQ_TARGET/GEMINI.md"
git_init "$CQ_TARGET"
cp "$AGG_TARGET/.github/workflows/build.yml" \
    "$CQ_TARGET/.github/workflows/build.yml"
cp "$AGG_TARGET/scripts/verify-required-results.sh" \
    "$CQ_TARGET/scripts/verify-required-results.sh"
# Some CI runner images provide gitleaks in the lint job. Give its repository
# scan a real HEAD so an unrelated empty-history error cannot make every
# verify-applied assertion look like an expected CodeQL failure.
git_commit_all "$CQ_TARGET" "record CodeQL fixture baseline"
expect_ok "CodeQL fixture has a committed baseline for repository scanners" \
    git -C "$CQ_TARGET" rev-parse --verify HEAD

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
write_codeql_result_helper() {
    cat >"$CQ_TARGET/scripts/verify-codeql-result.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

scan="${FULL_SECURITY_SCAN:-false}"
case "$scan" in true | false) ;; *) exit 1 ;; esac
case "${IS_FORK:-}" in true | false) ;; *) exit 1 ;; esac
case "${ANALYZE_RESULT:-}" in success | failure | cancelled | skipped) ;; *) exit 1 ;; esac

expected=success
if [ "$scan" = false ] || [ "$IS_FORK" = true ]; then
    expected=skipped
fi
[ "$ANALYZE_RESULT" = "$expected" ]
EOF
    chmod +x "$CQ_TARGET/scripts/verify-codeql-result.sh"
}
write_codeql_workflow() {
    local job_continue="$1"
    local analyze_continue="${2:-}"
    local extra_steps="${3:-}"
    local language_matrix="${4:-}"
    local aggregate_mode="${5:-safe}"
    local checkout_guard=$'        if: >-\n          github.event_name != '\''pull_request'\'' ||\n          github.event.pull_request.head.repo.full_name == github.repository\n'
    if [ "$aggregate_mode" = unsafe-checkout ]; then
        checkout_guard=""
    fi
    cat >"$CQ_TARGET/.github/workflows/codeql.yml" <<EOF
name: CodeQL
on: workflow_dispatch
jobs:
  analyze:
    if: >-
      vars.FULL_SECURITY_SCAN == 'true' &&
      (github.event_name != 'pull_request' ||
       github.event.pull_request.head.repo.full_name == github.repository)
$job_continue    runs-on: ubuntu-latest
$language_matrix
    steps:
      - name: Perform CodeQL Analysis
$analyze_continue        uses: github/codeql-action/analyze@v4
$extra_steps
  codeql-verify:
    if: always()
    needs: [analyze]
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@1111111111111111111111111111111111111111
$checkout_guard        with:
          persist-credentials: false
      - name: Verify CodeQL result
        if: >-
          github.event_name != 'pull_request' ||
          github.event.pull_request.head.repo.full_name == github.repository
        env:
          FULL_SECURITY_SCAN: \${{ vars.FULL_SECURITY_SCAN }}
          IS_FORK: \${{ github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name != github.repository }}
          ANALYZE_RESULT: \${{ needs.analyze.result }}
        run: ./scripts/verify-codeql-result.sh
      - name: Check deliberate fork skip
        if: >-
          github.event_name == 'pull_request' &&
          github.event.pull_request.head.repo.full_name != github.repository
        env:
          FULL_SECURITY_SCAN: \${{ vars.FULL_SECURITY_SCAN }}
          ANALYZE_RESULT: \${{ needs.analyze.result }}
        run: |
          scan="\${FULL_SECURITY_SCAN:-false}"
          case "\$scan" in
            true | false) ;;
            *) exit 1 ;;
          esac
          if [ "\$ANALYZE_RESULT" != "skipped" ]; then
            exit 1
          fi
EOF
}

write_codeql_result_helper

write_codeql_taskfile
printf '%s\n' '_commit: v4.1.1' >"$CQ_TARGET/.copier-answers.yml"
printf '%s\n' 'CodeQL coverage requires a successful SARIF upload.' \
    >"$CQ_TARGET/docs/architecture/security.md"
write_codeql_workflow $'    continue-on-error: true\n'
expect_fail "verify-applied rejects a fail-open CodeQL analyze job" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$CQ_TARGET"
write_codeql_workflow "" $'        continue-on-error: true\n'
expect_fail "verify-applied rejects a fail-open CodeQL analyze action" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$CQ_TARGET"
write_codeql_workflow ""
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' \
    >"$CQ_TARGET/scripts/verify-codeql-result.sh"
chmod +x "$CQ_TARGET/scripts/verify-codeql-result.sh"
expect_fail "verify-applied rejects a CodeQL aggregate that accepts every result" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$CQ_TARGET"
write_codeql_result_helper
write_codeql_workflow "" "" "" "" unsafe-checkout
expect_fail "verify-applied rejects fork-unsafe aggregate checkout" \
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
COLOR_TASK_BIN="$TMPROOT/codeql-color-task"
REAL_TASK_BIN="$(command -v task)"
mkdir -p "$COLOR_TASK_BIN"
cat >"$COLOR_TASK_BIN/task" <<'EOF'
#!/usr/bin/env bash
case " $* " in
*" --list-all "* | *" --dry "*)
    case " $* " in
    *" --color=false "*) ;;
    *) exit 42 ;;
    esac
    ;;
esac
exec "${REAL_TASK_BIN:?}" "$@"
EOF
chmod +x "$COLOR_TASK_BIN/task"
expect_ok "verify-applied explicitly disables colored task introspection" \
    env PATH="$COLOR_TASK_BIN:$FAKE_GH_BIN:$PATH" \
    REAL_TASK_BIN="$REAL_TASK_BIN" GH_TEST_VISIBILITY=private \
    GH_TEST_CODE_SECURITY=enabled \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$CQ_TARGET"
write_codeql_workflow "" "" $'      - name: Best-effort cleanup\n        if: always()\n        continue-on-error: true\n        run: docker buildx prune -af\n'
expect_ok "verify-applied allows continue-on-error on unrelated CodeQL cleanup" \
    env PATH="$FAKE_GH_BIN:$PATH" GH_TEST_VISIBILITY=private \
    GH_TEST_CODE_SECURITY=enabled \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$CQ_TARGET"
write_codeql_workflow ""
mkdir -p "$CQ_TARGET/src"
printf '%s\n' 'print("first-party source")' >"$CQ_TARGET/src/app.py"
write_codeql_workflow "" "" "" \
    $'    strategy:\n      matrix:\n        language: [javascript-typescript]\n'
expect_ok_contains "verify-applied warns when CodeQL scans tooling-only JavaScript" \
    'CodeQL matrix includes javascript-typescript but no first-party JS/TS source was found.' \
    env PATH="$FAKE_GH_BIN:$PATH" GH_TEST_VISIBILITY=private \
    GH_TEST_CODE_SECURITY=enabled \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$CQ_TARGET"
expect_ok_contains "verify-applied warns when CodeQL omits first-party Python" \
    'first-party Python source exists but CodeQL omits python.' \
    env PATH="$FAKE_GH_BIN:$PATH" GH_TEST_VISIBILITY=private \
    GH_TEST_CODE_SECURITY=enabled \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$CQ_TARGET"
rm -rf "$CQ_TARGET/src"
write_codeql_workflow ""
expect_ok "verify-applied defers an unreadable Code Security field to manual audit" \
    env PATH="$FAKE_GH_BIN:$PATH" GH_TEST_VISIBILITY=private \
    GH_TEST_CODE_SECURITY=unknown \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$CQ_TARGET"
TF_TARGET="$TMPROOT/verify-applied-terraform"
mkdir -p \
    "$TF_TARGET/.github/workflows" \
    "$TF_TARGET/scripts" \
    "$TF_TARGET/terraform"
printf '%s\n' '# Test instructions' >"$TF_TARGET/AGENTS.md"
ln -s AGENTS.md "$TF_TARGET/CLAUDE.md"
ln -s AGENTS.md "$TF_TARGET/GEMINI.md"
printf '%s\n' 'include_terraform: true' \
    >"$TF_TARGET/.copier-answers.yml"
printf '%s\n' 'terraform {}' >"$TF_TARGET/terraform/main.tf"
cat >"$TF_TARGET/Brewfile" <<'EOF'
brew "terraform"
brew "tflint"
brew "uv"
EOF

write_terraform_taskfile() {
    local mode="${1:-complete}"
    local security_dep='      - lint:terraform:security'
    local lock_dep='      - lint:terraform:locks'
    local lock_update='./scripts/terraform-provider-locks.sh update terraform'
    if [ "$mode" = missing-security ]; then
        security_dep=""
    elif [ "$mode" = missing-lock ]; then
        lock_dep=""
    elif [ "$mode" = wrong-lock-update ]; then
        lock_update='./scripts/terraform-provider-locks.sh check terraform'
    fi
    cat >"$TF_TARGET/Taskfile.yml" <<EOF
version: "3"
tasks:
  verify:
    cmds: ["true"]
  check:
    deps: [lint:terraform]
  security:
    cmds: ["true"]
  status:setup:
    cmds: ["true"]
  install:hooks:
    cmds: ["true"]
  lint:terraform:
    deps:
      - lint:terraform:fmt
      - lint:terraform:tflint
$security_dep
$lock_dep
  lint:terraform:fmt:
    cmds:
      - terraform fmt -check -recursive terraform/
  lint:terraform:tflint:
    cmds:
      - tflint --recursive --chdir=terraform/
  lint:terraform:security:
    cmds:
      - 'uvx --from "checkov==3.3.8" checkov -d terraform/ --framework terraform --quiet'
  lint:terraform:locks:
    cmds:
      - ./scripts/terraform-provider-locks.sh check terraform
  terraform:providers:lock:
    cmds:
      - $lock_update
EOF
}
write_terraform_build_workflow() {
    local include_tflint="${1:-true}"
    local tflint_step='      - uses: terraform-linters/setup-tflint@1111111111111111111111111111111111111111'
    if [ "$include_tflint" = false ]; then
        tflint_step=""
    fi
    cat >"$TF_TARGET/.github/workflows/build.yml" <<EOF
name: Build
on: workflow_dispatch
jobs:
  lint:
    if: >-
      github.event_name != 'pull_request' ||
      github.event.pull_request.head.repo.full_name == github.repository
    runs-on: ubuntu-latest
    steps:
      - uses: hashicorp/setup-terraform@1111111111111111111111111111111111111111
$tflint_step
      - uses: astral-sh/setup-uv@1111111111111111111111111111111111111111
  verify:
    if: always()
    needs: [lint]
    runs-on: ubuntu-latest
    env:
      IS_FORK: \${{ github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name != github.repository }}
    steps:
      - name: Verify deliberate skips at the untrusted-fork boundary
        if: env.IS_FORK == 'true'
        env:
          LINT_RESULT: \${{ needs.lint.result }}
        run: |
          if [ "\$LINT_RESULT" != "skipped" ]; then
            exit 1
          fi
          echo "Untrusted fork trust boundary enforced: all repository-controlled jobs were deliberately skipped."
      - if: env.IS_FORK != 'true'
        uses: actions/checkout@1111111111111111111111111111111111111111
      - name: Verify required jobs succeeded
        if: env.IS_FORK != 'true'
        env:
          EXPECTED_RESULT: success
          LINT_RESULT: \${{ needs.lint.result }}
        run: ./scripts/verify-required-results.sh "lint=\${LINT_RESULT}"
EOF
}
write_terraform_lock_helper() {
    local include_linux="${1:-true}"
    local init_mode="${2:-conditional}"
    local linux_platform='    -platform=linux_amd64'
    local init_upgrade
    if [ "$include_linux" = false ]; then
        linux_platform=""
    fi
    case "$init_mode" in
    conditional)
        init_upgrade='if [ "$mode" = update ]; then
    init_args+=(-upgrade)
fi'
        ;;
    missing-upgrade)
        init_upgrade='# Deliberately omit the update-mode upgrade flag.'
        ;;
    unconditional-upgrade)
        init_upgrade='init_args+=(-upgrade)'
        ;;
    *)
        fail "unknown Terraform lock helper fixture mode: $init_mode"
        ;;
    esac
    cat >"$TF_TARGET/scripts/terraform-provider-locks.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail

mode="\${1:-}"
root="\${2:-terraform}"
case "\$mode" in
check | update) ;;
*) exit 2 ;;
esac

terraform_bin="\${TERRAFORM_BIN:-terraform}"
init_args=(-backend=false -input=false)
$init_upgrade
"\$terraform_bin" "-chdir=\$root" init "\${init_args[@]}" >/dev/null
"\$terraform_bin" "-chdir=\$root" providers lock \\
    -platform=darwin_arm64 \\
$linux_platform
EOF
    chmod +x "$TF_TARGET/scripts/terraform-provider-locks.sh"
}
write_terraform_lock_regression() {
    local result="${1:-0}"
    cat >"$TF_TARGET/scripts/test-terraform-provider-locks.sh" <<EOF
#!/usr/bin/env bash
# The canonical regression drives the helper with a fake Terraform executable.
exit $result
EOF
    chmod +x "$TF_TARGET/scripts/test-terraform-provider-locks.sh"
}

write_terraform_taskfile
write_terraform_build_workflow
cp "$AGG_TARGET/scripts/verify-required-results.sh" \
    "$TF_TARGET/scripts/verify-required-results.sh"
write_required_check_ruleset "$TF_TARGET" terraform
write_terraform_lock_helper
write_terraform_lock_regression
git_init "$TF_TARGET"
git_commit_all "$TF_TARGET" "record Terraform verifier fixture"
expect_ok "verify-applied accepts reachable fmt, TFLint, Checkov, and lock checks" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$TF_TARGET"
write_required_check_ruleset "$TF_TARGET"
expect_fail "verify-applied requires terraform-verify for a Terraform repo" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$TF_TARGET"
write_required_check_ruleset "$TF_TARGET" terraform

write_terraform_taskfile missing-security
expect_fail "verify-applied rejects unreachable Checkov despite a defined leaf task" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$TF_TARGET"
write_terraform_taskfile missing-lock
expect_fail "verify-applied rejects an unreachable provider-lock check" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$TF_TARGET"
write_terraform_taskfile wrong-lock-update
expect_fail "verify-applied rejects a provider-lock mutation task that cannot update" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$TF_TARGET"
write_terraform_taskfile

write_terraform_build_workflow false
expect_fail "verify-applied rejects Terraform lint without reachable TFLint in CI" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$TF_TARGET"
write_terraform_build_workflow
write_terraform_lock_helper false
expect_fail "verify-applied requires linux_amd64 provider-lock evidence" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$TF_TARGET"
write_terraform_lock_helper
write_terraform_lock_helper true missing-upgrade
expect_fail "verify-applied rejects update init without -upgrade" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$TF_TARGET"
write_terraform_lock_helper true unconditional-upgrade
expect_fail "verify-applied rejects check init with -upgrade" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$TF_TARGET"
write_terraform_lock_helper
write_terraform_lock_regression 1
expect_fail "verify-applied runs the hermetic provider-lock regression" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$TF_TARGET"
write_terraform_lock_regression

manifest="$STANDARDIZE_ASSETS/template-owned-files.txt"
for required in \
    Brewfile \
    .skills-sync.yaml \
    scripts/shell-quality.sh \
    scripts/markdownlint.sh \
    scripts/secret-set-1p.sh \
    scripts/secret-set-gh.sh \
    scripts/python-audit.sh \
    scripts/terraform-provider-locks.sh \
    scripts/terraform-changed.sh \
    scripts/terraform-ci.sh \
    scripts/test-codeql-result.sh \
    scripts/test-required-results.sh \
    scripts/test-terraform-provider-locks.sh \
    scripts/test-terraform-ci.sh \
    scripts/verify-codeql-result.sh \
    scripts/verify-required-results.sh \
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
