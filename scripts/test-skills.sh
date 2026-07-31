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

# The render-backed cases below invoke copier directly. Without this preflight a
# missing copier surfaces as a bare `copier: command not found` and exit 127
# partway through the run, which names the wrong problem.
if ! command -v copier >/dev/null 2>&1; then
    echo "test-skills: required tool 'copier' is not installed" >&2
    echo "  the render-backed cases call it to build throwaway templates" >&2
    echo "  install it with 'task install' (brew host: Brewfile; otherwise uv)" >&2
    exit 1
fi

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
# Run a command, succeed iff it exits non-zero AND says why — a rejection that
# fires for an unrelated reason is a passing test that proves nothing.
expect_fail_contains() {
    local desc="$1"
    local needle="$2"
    local output
    shift 2
    if output="$("$@" 2>&1)"; then
        bad "$desc (expected non-zero exit)"
        [ -z "$output" ] || printf '%s\n' "$output" | sed 's/^/      /' >&2
    elif printf '%s\n' "$output" | grep -qF "$needle"; then
        ok "$desc"
    else
        bad "$desc (missing diagnostic: $needle)"
        [ -z "$output" ] || printf '%s\n' "$output" | sed 's/^/      /' >&2
    fi
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

git_init() { git init -q -b main "$1"; }
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
IMPLEMENT_SKILL="$repo/ai/skills/universal/implement/SKILL.md"
SHEPHERD_SKILL="$repo/ai/skills/universal/shepherd/SKILL.md"
STANDARDIZE_SKILL="$repo/ai/skills/repo/standardize-repo/SKILL.md"
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
expect_ok "new-repo guidance exposes the explicit CodeQL language matrix" \
    grep -qF '| `codeql_languages` | multiselect |' \
    "$STANDARDIZE_REFS/mode-new-repo.md"
expect_ok "new-repo guidance exposes CodeRabbit as default off" \
    grep -qF '| `use_coderabbit` | bool | `false` |' \
    "$STANDARDIZE_REFS/mode-new-repo.md"
expect_ok "new-repo guidance exposes Codex cloud review as default off" \
    grep -qF '| `use_codex_cloud_review` | bool | `false` |' \
    "$STANDARDIZE_REFS/mode-new-repo.md"
expect_ok "new-repo guidance requires the Codex classifier prerequisites" \
    grep -qF '`use_skills_sync=true`, `universal` in `skill_categories`' \
    "$STANDARDIZE_REFS/mode-new-repo.md"
expect_ok "update guidance passes one frozen reviewed-data file to preview and apply" \
    test "$(grep -Fc -- '--data-file="$REVIEWED_DATA"' \
        "$STANDARDIZE_REFS/mode-update.md")" -eq 2
expect_ok "update guidance starts from the recorded CodeRabbit answer" \
    grep -qF ".use_coderabbit // false' .copier-answers.yml" \
    "$STANDARDIZE_REFS/mode-update.md"
expect_ok "update guidance starts from the recorded Codex cloud answer" \
    grep -qF ".use_codex_cloud_review // false' .copier-answers.yml" \
    "$STANDARDIZE_REFS/mode-update.md"
expect_ok "update guidance reviews the Codex controller and conditional option" \
    sh -c 'grep -qF "use_foreman use_codex_review use_codex_cloud_review" "$1" &&
        grep -qF "use_foreman use_codex_review use_skills_sync" "$1"' sh \
    "$STANDARDIZE_REFS/mode-update.md"
expect_ok "update guidance rejects missing Codex classifier prerequisites" \
    sh -c 'grep -qF "use_codex_cloud_review requires use_skills_sync" "$1" &&
        grep -qF "use_codex_cloud_review requires the universal skill category" "$1"' sh \
    "$STANDARDIZE_REFS/mode-update.md"
expect_fail "update guidance does not preseed reviewed skill categories" \
    grep -qF 'failed to seed reviewed skill categories' \
    "$STANDARDIZE_REFS/mode-update.md"
expect_ok "shepherd starts Codex attempts only after checks settle" \
    grep -qF 'Do not reserve or post the trigger until every required check has settled.' \
    "$SHEPHERD_SKILL"
expect_ok "implement creates the normal PR as a draft" \
    grep -qF 'gh pr create --draft --repo "$repo"' "$IMPLEMENT_SKILL"
expect_ok "implement confirms the pushed draft head" \
    sh -c 'grep -qF "headRefOid,isDraft" "$1" &&
        grep -qF "isDraft == true" "$1"' sh "$IMPLEMENT_SKILL"
expect_ok "shepherd records draft state on entry" \
    grep -qF 'state,isDraft,headRepositoryOwner' "$SHEPHERD_SKILL"
expect_ok "shepherd promotes only the unchanged ready head" \
    sh -c 'grep -qF "gh pr ready <n>" "$1" &&
        grep -qF "changed head invalidates the gate" "$1" &&
        grep -qF "must not be called again" "$1"' sh "$SHEPHERD_SKILL"
expect_ok "shepherd settles automation before final ready promotion" \
    sh -c 'grep -qF "cannot be used as an automation" "$1" &&
        grep -qF "pull_request.ready_for_review" "$1" &&
        grep -qF "final agent action" "$1" &&
        grep -qF "leave the PR draft" "$1"' sh "$SHEPHERD_SKILL"
expect_fail "shepherd has no post-ready automation workbench" \
    grep -qF "bounded post-promotion window" "$SHEPHERD_SKILL"
expect_ok "shepherd blockers preserve the draft workbench" \
    grep -qF 'For every stop except Ready for human review, leave the PR draft' \
    "$SHEPHERD_SKILL"
expect_ok "shepherd documents the external Automatic-review prerequisite" \
    sh -c 'grep -qF "Codex Automatic reviews" "$1" &&
        grep -qF "must be disabled in the external integration" "$1"' sh \
    "$SHEPHERD_SKILL"
expect_ok "standardization setup disables Codex Automatic reviews" \
    sh -c 'grep -qF "Disable **Codex Automatic reviews**" "$1/post-generation-checklist.md" &&
        grep -qF "human-confirmed disabled" "$1/mode-audit.md"' sh "$STANDARDIZE_REFS"
expect_ok "standardization hands off only a ready-for-review PR" \
    sh -c 'grep -qF "open a draft PR" "$1" &&
        grep -qF "draft-time checks/review gate and final promotion" "$1" &&
        grep -qF "If the target has no vendored shepherd" "$1" &&
        grep -qF "or five rounds when it states none" "$1" &&
        grep -qF "final ready promotion is confirmed" "$1"' sh \
    "$STANDARDIZE_SKILL"
expect_ok "root policy keeps ready as the final human handoff" \
    sh -c 'grep -qF "pull_request.ready_for_review" "$1" &&
        grep -qF "configuration" "$1" &&
        grep -qF "Then run `gh pr ready`" "$1"' sh \
    "$repo/AGENTS.md"
expect_ok "standardization modes use the draft-workbench handoff" \
    sh -c 'grep -qF "open a draft PR" "$1/mode-audit.md" &&
        grep -qF "open a draft PR" "$1/mode-update.md" &&
        grep -qF "open a draft PR" "$1/mode-new-repo.md" &&
        grep -qF "open a draft PR" "$1/standards-catalog.md"' sh "$STANDARDIZE_REFS"
expect_fail "Codex classifier does not add an undeclared Perl dependency" \
    grep -qF 'need perl' \
    "$repo/ai/skills/universal/shepherd/assets/check-codex-cloud-review.sh"
expect_ok "update guidance reads the reviewed CodeQL language matrix" \
    grep -qF "'.codeql_languages' \"\$REVIEWED_DATA\"" \
    "$STANDARDIZE_REFS/mode-update.md"
expect_ok "update guidance rejects an empty enabled CodeQL matrix" \
    grep -qF 'CODEQL_LANGUAGES must be a nonempty YAML list' \
    "$STANDARDIZE_REFS/mode-update.md"
expect_ok "update guidance derives every newly introduced Copier question" \
    sh -c 'grep -qF "baseline-questions" "$1" &&
        grep -qF "target-questions" "$1" &&
        grep -qF "new-question-candidates" "$1" &&
        grep -qF "active-target-questions" "$1" &&
        grep -qF "active-new-questions" "$1" &&
        grep -qF "reviewed-keys" "$1"' sh \
    "$STANDARDIZE_REFS/mode-update.md"
expect_ok "update guidance discovers recordable questions without running tasks" \
    sh -c 'grep -qF "copy --trust --defaults --skip-tasks" "$1" &&
        grep -qF "DISCOVERY_STABLE" "$1" &&
        grep -qF "active-reviewed-data.yml" "$1" &&
        grep -qF "inactive conditional" "$1" &&
        grep -qF "questions are never passed as user data" "$1"' sh \
    "$STANDARDIZE_REFS/mode-update.md"
expect_fail "update guidance never hard-codes Foreman off" \
    grep -qF -- '--data use_foreman=false' "$STANDARDIZE_REFS/mode-update.md"
expect_ok "production guidance requires an exact remote tag on origin/main" \
    grep -qF 'HARMON_INIT_REF must exactly match a release tag on origin/main' \
    "$STANDARDIZE_REFS/mode-new-repo.md"
expect_ok "production guidance verifies the selected tag with the Copier source" \
    grep -qF 'ls-remote --exit-code "$HARMON_INIT_SOURCE"' \
    "$STANDARDIZE_REFS/mode-new-repo.md"
expect_ok "new-repo production commands use the verified canonical source" \
    test "$(grep -Fc 'copier copy "$HARMON_INIT_SOURCE" <dest>' \
        "$STANDARDIZE_REFS/mode-new-repo.md")" -eq 2
expect_ok "adopt guidance uses the verified canonical source" \
    grep -qF 'copier copy --trust "$HARMON_INIT_SOURCE" .' \
    "$STANDARDIZE_REFS/mode-adopt-existing.md"
for canonical_doc in \
    "$STANDARDIZE_REFS/mode-new-repo.md" \
    "$STANDARDIZE_REFS/mode-adopt-existing.md"; do
    expect_ok "${canonical_doc##*/} verifies tags against the Copier source" \
        grep -qF 'ls-remote --exit-code "$HARMON_INIT_SOURCE"' "$canonical_doc"
    expect_fail "${canonical_doc##*/} does not validate a checkout-specific origin" \
        grep -qF 'ls-remote --exit-code origin' "$canonical_doc"
done
expect_ok "production guidance aborts when the origin refresh fails" \
    grep -qF 'failed to refresh harmon-init from origin' \
    "$STANDARDIZE_REFS/mode-new-repo.md"
expect_ok "new-repo guidance freezes each verified release tag to its commit" \
    test "$(grep -Fc 'HARMON_INIT_COMMIT="$(git -C ~/git/harmon-init rev-parse' \
        "$STANDARDIZE_REFS/mode-new-repo.md")" -eq 2
expect_ok "adopt guidance freezes the verified release tag to its commit" \
    grep -qF 'HARMON_INIT_COMMIT="$(git -C ~/git/harmon-init rev-parse' \
    "$STANDARDIZE_REFS/mode-adopt-existing.md"
expect_ok "update guidance refreshes the origin/main tracking ref explicitly" \
    grep -qF '+refs/heads/main:refs/remotes/origin/main' \
    "$STANDARDIZE_REFS/mode-update.md"
expect_ok "update guidance requires the canonical recorded source" \
    grep -qF '_src_path must be the canonical harmon-init URL before update' \
    "$STANDARDIZE_REFS/mode-update.md"
expect_ok "update guidance freezes the verified release commit" \
    grep -qF 'HARMON_INIT_COMMIT="$(git -C ~/git/harmon-init rev-parse' \
    "$STANDARDIZE_REFS/mode-update.md"
expect_ok "update guidance freezes the recorded baseline commit" \
    grep -qF 'RECORDED_COMMIT="$(git -C ~/git/harmon-init rev-parse' \
    "$STANDARDIZE_REFS/mode-update.md"
expect_ok "update routing recognizes guarded full-hash lineages" \
    grep -qF '40-character commit recorded by a guarded update' \
    "$STANDARDIZE_REFS/mode-update.md"
expect_ok "update guidance rejects recorded baselines before v3" \
    grep -qF '"$V3_BASELINE_COMMIT" "$RECORDED_COMMIT"' \
    "$STANDARDIZE_REFS/mode-update.md"
expect_ok "update guidance routes pre-v3 lineage to adoption" \
    grep -qF 'recorded baseline predates v3' \
    "$STANDARDIZE_REFS/mode-update.md"
expect_ok "update guidance requires the target to descend from the baseline" \
    grep -qF '"$RECORDED_COMMIT" "$HARMON_INIT_COMMIT"' \
    "$STANDARDIZE_REFS/mode-update.md"
expect_ok "update guidance requires explicit legacy baseline recovery approval" \
    grep -qF 'ACCEPT_LEGACY_BASELINE:?obtain maintainer approval' \
    "$STANDARDIZE_REFS/mode-update.md"
expect_ok "update guidance accepts commit-targeted legacy releases" \
    grep -qF '"$RECORDED_COMMIT") ;;' \
    "$STANDARDIZE_REFS/mode-update.md"
expect_ok "update guidance accepts main-targeted legacy releases" \
    grep -qF 'recorded tag is not on the release target branch' \
    "$STANDARDIZE_REFS/mode-update.md"
expect_ok "update guidance freezes an offline read-only clone" \
    sh -c 'grep -qF "remote remove origin" "$1" &&
        grep -qF "chmod -R a-w" "$1"' sh \
    "$STANDARDIZE_REFS/mode-update.md"
expect_ok "update guidance snapshots from the canonical remote" \
    grep -qF 'git clone --no-checkout "$HARMON_INIT_SOURCE"' \
    "$STANDARDIZE_REFS/mode-update.md"
expect_fail "update guidance does not snapshot local-only tags" \
    grep -qF 'git clone --no-local --no-checkout ~/git/harmon-init' \
    "$STANDARDIZE_REFS/mode-update.md"
expect_ok "update guidance rejects remote-capable template submodules" \
    grep -qF '"$GUARDED_COMMIT:.gitmodules"' \
    "$STANDARDIZE_REFS/mode-update.md"
expect_ok "update guidance ignores recovery state in ordinary and linked worktrees" \
    sh -c 'grep -qF "GUARDED_STATE=.copier-guarded-update" "$1" &&
        grep -qF "git rev-parse --path-format=absolute --git-path info/exclude" "$1"' sh \
    "$STANDARDIZE_REFS/mode-update.md"
expect_ok "update guidance refuses to overwrite interrupted guarded state" \
    grep -qF 'recover or remove it before retrying' \
    "$STANDARDIZE_REFS/mode-update.md"
expect_ok "update guidance process-scopes canonical URL rewrites" \
    sh -c 'grep -qF "GIT_CONFIG_COUNT=2" "$1" &&
        grep -qF "insteadOf" "$1" &&
        grep -qF "run_guarded_copier" "$1"' sh \
    "$STANDARDIZE_REFS/mode-update.md"
expect_ok "update guidance binds apply and promotion to the prepared checkout" \
    test "$(grep -Fc 'working checkout no longer matches guarded update state' \
        "$STANDARDIZE_REFS/mode-update.md")" -eq 2
expect_ok "update guidance persists and verifies the symbolic checkout" \
    sh -c 'grep -qF "start-checkout" "$1" &&
        grep -qF "guarded_checkout_id" "$1" &&
        grep -qF "detached" "$1"' sh \
    "$STANDARDIZE_REFS/mode-update.md"
expect_ok "update guidance persists and verifies the complete reviewed answer map" \
    sh -c 'grep -qF "reviewed-data.yml" "$1" &&
        grep -qF "__REVIEW_REQUIRED__" "$1" &&
        grep -qF "reviewed-data-oid" "$1" &&
        grep -qF "applied answer differs from reviewed value" "$1"' sh \
    "$STANDARDIZE_REFS/mode-update.md"
expect_ok "update guidance validates every reviewed key after apply" \
    grep -qF 'done <"$GUARDED_STATE/reviewed-keys"' \
    "$STANDARDIZE_REFS/mode-update.md"
expect_ok "update check, preview, and apply use the guarded Copier wrapper" \
    test "$(grep -Ec '^(if )?run_guarded_copier (check-update|update)' \
        "$STANDARDIZE_REFS/mode-update.md")" -eq 3
expect_ok "update guidance runs drift only after guarded source creation" \
    test "$(grep -nF 'GUARDED_TEMPLATE="$(mktemp' \
        "$STANDARDIZE_REFS/mode-update.md" | cut -d: -f1)" -lt \
    "$(grep -nF 'assets/diff-template.sh .' \
        "$STANDARDIZE_REFS/mode-update.md" | head -1 | cut -d: -f1)"
expect_ok "update guidance restores a canonical full-hash lineage tuple" \
    sh -c 'grep -qF "._src_path = strenv(HARMON_INIT_SOURCE)" "$1" &&
        grep -qF "._commit = strenv(HARMON_INIT_COMMIT)" "$1"' sh \
    "$STANDARDIZE_REFS/mode-update.md"
expect_ok "update guidance atomically promotes the canonical answers file" \
    grep -qF 'mv "$PROMOTED_ANSWERS" .copier-answers.yml' \
    "$STANDARDIZE_REFS/mode-update.md"
expect_ok "update guidance proves Copier applied the target before promotion" \
    grep -qF 'guarded update did not apply the validated target' \
    "$STANDARDIZE_REFS/mode-update.md"
expect_ok "update guidance writes apply intent before Copier can mutate the tree" \
    sh -c 'phase_line="$(grep -nF "write_guarded_phase applying" "$1" |
            cut -d: -f1)"
        copier_line="$(grep -nF \
            "if run_guarded_copier update --trust --defaults" "$1" |
            cut -d: -f1)"
        test "$phase_line" -lt "$copier_line" &&
        grep -qF "An \`applying\`" "$1" &&
        grep -qF "state is never promotable" "$1"' sh \
    "$STANDARDIZE_REFS/mode-update.md"
expect_ok "update guidance requires a clean worktree immediately before apply" \
    sh -c 'clean_line="$(grep -nF \
            "test -z \"\$(git status --porcelain)\"" "$1" |
            sed -n "2p" | cut -d: -f1)"
        phase_line="$(grep -nF "write_guarded_phase applying" "$1" |
            cut -d: -f1)"
        test -n "$clean_line" && test "$clean_line" -lt "$phase_line"' sh \
    "$STANDARDIZE_REFS/mode-update.md"
expect_ok "update guidance makes interrupted rollback explicitly destructive" \
    sh -c 'grep -qF "git clean -nd" "$1" &&
        grep -qF "git diff HEAD --stat" "$1" &&
        grep -qF "explicit maintainer approval" "$1" &&
        grep -qF "This rollback is" "$1" &&
        grep -qF "destructive and must never" "$1"' sh \
    "$STANDARDIZE_REFS/mode-update.md"
expect_ok "update guidance snapshots and restores ignored managed paths" \
    sh -c 'grep -qF "ignored-backup.tar" "$1" &&
        grep -qF "ignored-absent-paths" "$1" &&
        grep -qF "ignored-preapply.tar" "$1" &&
        grep -qF "ignored-verify.tar" "$1"' sh \
    "$STANDARDIZE_REFS/mode-update.md"
expect_ok "update guidance stages the promoted full-hash answers" \
    grep -qF 'git add -- .copier-answers.yml' \
    "$STANDARDIZE_REFS/mode-update.md"
expect_ok "orphan sweep compares the repo against a rendered target inventory" \
    sh -c 'grep -qF "failed to render the target inventory" "$1" &&
        grep -qF "git ls-files '\''scripts/*'\'' |" "$1"' sh \
    "$STANDARDIZE_REFS/mode-update.md"
expect_ok "orphan sweep counts only scripts surviving in the worktree" \
    sh -c 'grep -qF "test -e \"\$SCRIPT_PATH\" || test -L \"\$SCRIPT_PATH\"" "$1" &&
        grep -qF "reads the **index**" "$1"' sh \
    "$STANDARDIZE_REFS/mode-update.md"
expect_ok "orphan sweep renders from the frozen guarded source" \
    sh -c 'end="$(grep -nF "failed to render the target inventory" "$1" |
            cut -d: -f1)"
        test -n "$end" || exit 1
        block="$(sed -n "$((end - 6)),${end}p" "$1")"
        printf "%s\n" "$block" |
            grep -qF "run_guarded_copier copy --trust --defaults --skip-tasks" &&
        printf "%s\n" "$block" |
            grep -qF -- "--vcs-ref=\"\$HARMON_INIT_COMMIT\"" &&
        printf "%s\n" "$block" |
            grep -qF "\"\$HARMON_INIT_SOURCE\" \"\$RENDERED_TREE\""' sh \
    "$STANDARDIZE_REFS/mode-update.md"
expect_fail "orphan sweep never renders from a mutable checkout or tag" \
    grep -qF 'copier copy --trust --defaults --skip-tasks --vcs-ref=<new>' \
    "$STANDARDIZE_REFS/mode-update.md"
expect_fail "orphan sweep never strips template/ off a raw tree listing" \
    grep -qF "sed 's|^template/||'" \
    "$STANDARDIZE_REFS/mode-update.md"
expect_fail "orphan sweep does not ask the reader to un-gate raw names by hand" \
    grep -qF 'jinja-wrapped in the raw listing' \
    "$STANDARDIZE_REFS/mode-update.md"
expect_ok "post-generation guidance requires Renovate Scan and Alert mode" \
    grep -qF '**Scan and Alert** mode' \
    "$STANDARDIZE_REFS/post-generation-checklist.md"
expect_ok "post-generation guidance requires Codex connector verification" \
    sh -c 'grep -qF "only when \`use_codex_cloud_review=true\`" "$1" &&
        grep -qF "exact PR head" "$1"' sh \
    "$STANDARDIZE_REFS/post-generation-checklist.md"
expect_ok "post-generation guidance requires external CodeRabbit access removal" \
    grep -qF 'deleting the config alone does not revoke App' \
    "$STANDARDIZE_REFS/post-generation-checklist.md"
expect_ok "audit guidance reconciles CodeRabbit answers and external access" \
    grep -qF '**G3. CodeRabbit selection drift.**' \
    "$STANDARDIZE_REFS/mode-audit.md"
expect_ok "audit guidance requires the guarded canonical baseline render" \
    sh -c 'grep -qF "Do not set \`HARMON_INIT\` for a normal audit" "$1" &&
        grep -qF "ACCEPT_LEGACY_BASELINE=true" "$1" &&
        grep -qF "read-only clone" "$1"' sh \
    "$STANDARDIZE_REFS/mode-audit.md"
expect_ok "top-level prerequisites require a local checkout for every mode" \
    sh -c 'grep -qF "required by **every**" "$1" &&
        grep -qF "**harmon-init** cloned locally" "$1" &&
        grep -qF "assets/diff-template.sh" "$1"' sh \
    "$STANDARDIZE_SKILL"
expect_fail "top-level prerequisites do not exempt audit mode wholesale" \
    grep -qF "**Audit mode does not require a local checkout**" \
    "$STANDARDIZE_SKILL"
expect_ok "audit guidance states the catalog comparison needs the checkout" \
    sh -c 'grep -qF "Audit mode **does** require this local checkout" "$1" &&
        grep -qF "never-templated repo it is the only source of truth" "$1"' sh \
    "$STANDARDIZE_REFS/mode-audit.md"
expect_ok "template drift helper snapshots and freezes the canonical baseline" \
    sh -c 'grep -qF "git clone --no-checkout" "$1" &&
        grep -qF "remote remove origin" "$1" &&
        grep -qF "recorded_commit" "$1" &&
        grep -qF "chmod -R a-w" "$1"' sh \
    "$STANDARDIZE_ASSETS/diff-template.sh"
expect_ok "update guidance gates on a release supporting CodeRabbit selection" \
    grep -qF "grep -q '^use_coderabbit:'" \
    "$STANDARDIZE_REFS/mode-update.md"
expect_ok "status setup keeps CodeRabbit access removal human-visible" \
    grep -qF 'checkline unknown "CodeRabbit app access"' \
    "$repo/scripts/status.sh"
expect_ok "new-repo production scaffolding pins the immutable verified commit" \
    test "$(grep -Fc -- '--trust --vcs-ref="$HARMON_INIT_COMMIT"' \
        "$STANDARDIZE_REFS/mode-new-repo.md")" -eq 2
expect_ok "adopt production scaffolding pins the immutable verified commit" \
    grep -qF -- '--vcs-ref="$HARMON_INIT_COMMIT"' \
    "$STANDARDIZE_REFS/mode-adopt-existing.md"
expect_fail "production copy commands do not reuse the mutable release tag" \
    grep -RF -- '--vcs-ref="$HARMON_INIT_REF"' \
    "$STANDARDIZE_SKILL" \
    "$STANDARDIZE_REFS/mode-new-repo.md" \
    "$STANDARDIZE_REFS/mode-adopt-existing.md"
expect_ok "every update Copier run pins the same immutable release commit" \
    test "$(grep -Fc -- '--vcs-ref="$HARMON_INIT_COMMIT"' \
        "$STANDARDIZE_REFS/mode-update.md")" -eq 4
expect_fail "update commands do not reuse the mutable release tag" \
    grep -qF -- '--vcs-ref="$HARMON_INIT_REF"' "$STANDARDIZE_REFS/mode-update.md"
expect_fail "production command examples do not pin an obsolete release" \
    grep -REq 'copier (copy|update).*(v3\.26\.1|v4\.4\.0)|--vcs-ref=(v3\.26\.1|v4\.4\.0)' \
    "$STANDARDIZE_SKILL" "$STANDARDIZE_REFS"
expect_ok "new-repo guidance forbids path-only lineage repair" \
    grep -qF 'do not rewrite only `_src_path`' \
    "$STANDARDIZE_REFS/mode-new-repo.md"
# Copier records `_commit` from `git describe --tags --always`, so a released tag
# overrides the peeled `--vcs-ref` SHA. Both rendering modes must freeze the
# tuple afterward or every scaffold lands in update mode's legacy recovery path.
for scaffold_mode in mode-new-repo mode-adopt-existing; do
    expect_ok "$scaffold_mode freezes the canonical source into the tuple" \
        grep -qF '._src_path = strenv(HARMON_INIT_SOURCE)' \
        "$STANDARDIZE_REFS/$scaffold_mode.md"
    expect_ok "$scaffold_mode freezes the peeled commit into the tuple" \
        grep -qF '._commit = strenv(HARMON_INIT_COMMIT)' \
        "$STANDARDIZE_REFS/$scaffold_mode.md"
    expect_ok "$scaffold_mode promotes the frozen tuple atomically" \
        grep -qF 'mv "$PROMOTED_ANSWERS" .copier-answers.yml' \
        "$STANDARDIZE_REFS/$scaffold_mode.md"
    expect_ok "$scaffold_mode asserts the frozen commit is a full hash" \
        grep -qF "lineage freeze failed: _commit is not a full hash" \
        "$STANDARDIZE_REFS/$scaffold_mode.md"
    expect_ok "$scaffold_mode explains why --vcs-ref does not reach the answers" \
        grep -qF 'git describe --tags --always' \
        "$STANDARDIZE_REFS/$scaffold_mode.md"
done
expect_ok "new-repo guidance carries the freeze into the scaffold commit" \
    sh -c 'grep -qF "git commit --amend --no-edit" "$1" &&
        grep -qF "failed to record the frozen lineage tuple" "$1"' sh \
    "$STANDARDIZE_REFS/mode-new-repo.md"
# github_remote_create runs `gh repo create --push` and github_release_init runs
# `task release:init`, so the scaffold commit can already be published and tagged
# by the time the freeze runs. The amend must be gated in code, not just prose.
expect_ok "new-repo freeze never rewrites a published scaffold commit" \
    sh -c 'grep -qF "git rev-parse --verify '\''@{upstream}'\''" "$1" &&
        grep -qF "git tag --points-at HEAD" "$1" &&
        grep -qF "never rewrite published history" "$1"' sh \
    "$STANDARDIZE_REFS/mode-new-repo.md"
expect_ok "new-repo freeze offers a follow-up commit for published scaffolds" \
    grep -qF "chore: freeze copier lineage to the verified template commit" \
    "$STANDARDIZE_REFS/mode-new-repo.md"
# §2/§3 leave the shell in the parent dir; freezing there would amend whatever
# repo the shell is in. The freeze must cd first and refuse a mismatched tuple.
# Anchored to the command at line start, not prose mentioning the same words.
expect_ok "new-repo freeze enters the destination before touching answers" \
    sh -c 'cd_line="$(grep -nE "^cd <dest> \|\|$" "$1" | head -1 | cut -d: -f1)"
        freeze_line="$(grep -nF "PROMOTED_ANSWERS=\"\$(mktemp" "$1" |
            head -1 | cut -d: -f1)"
        test -n "$cd_line" && test "$cd_line" -lt "$freeze_line"' sh \
    "$STANDARDIZE_REFS/mode-new-repo.md"
expect_ok "new-repo freeze refuses a tuple that is not the ref just rendered" \
    sh -c 'grep -qF "refusing to freeze" "$1" &&
        grep -qF "is the shell inside the generated repo?" "$1"' sh \
    "$STANDARDIZE_REFS/mode-new-repo.md"
# An unset HARMON_INIT_COMMIT would blank the tuple; both render modes must
# require the §2/§3 environment and prove the render actually happened.
for scaffold_mode in mode-new-repo mode-adopt-existing; do
    expect_ok "$scaffold_mode freeze requires the validated commit in the env" \
        grep -qF 'must still hold the peeled commit validated in' \
        "$STANDARDIZE_REFS/$scaffold_mode.md"
    expect_ok "$scaffold_mode freeze requires the canonical source in the env" \
        grep -qF 'must still hold the canonical harmon-init URL from' \
        "$STANDARDIZE_REFS/$scaffold_mode.md"
    expect_ok "$scaffold_mode freeze proves the recorded ref was just rendered" \
        grep -qF 'refusing to freeze' \
        "$STANDARDIZE_REFS/$scaffold_mode.md"
done
expect_ok "adopt freeze refuses a tuple from an aborted or stale render" \
    grep -qF 'did the adoption render complete in this shell?' \
    "$STANDARDIZE_REFS/mode-adopt-existing.md"
# A published scaffold keeps the tag-valued tuple on the remote until the
# follow-up freeze commit is pushed, so the local-only path is not a fix.
expect_ok "new-repo freeze pushes the follow-up commit on a published scaffold" \
    sh -c 'grep -qF "git push ||" "$1" &&
        grep -qF "freeze commit is local only" "$1"' sh \
    "$STANDARDIZE_REFS/mode-new-repo.md"
# run_task_install=yes installs lefthook before the freeze runs, so committing on
# main trips guard:no-commit-to-main. Branch and PR — never --no-verify.
expect_ok "new-repo freeze refuses to commit on main behind installed hooks" \
    sh -c 'grep -qF "test -x .git/hooks/pre-commit" "$1" &&
        grep -qF "guard:no-commit-to-main" "$1" &&
        grep -qF "never --no-verify" "$1"' sh \
    "$STANDARDIZE_REFS/mode-new-repo.md"
# Matches a real bypass invocation, not the prose that prohibits one.
expect_fail "new-repo freeze never invokes a hook bypass" \
    grep -qE '^[^#]*git (commit|push)([[:space:]]|[^#])*--no-verify' \
    "$STANDARDIZE_REFS/mode-new-repo.md"
# `target_commitish` is branch-valued for releases cut from a branch — the `main)`
# arm exists for exactly that. Guidance must not claim it is always a commit.
expect_ok "update guidance grades release-record evidence by target_commitish" \
    sh -c 'grep -qF "does **not** distinguish a retag to another commit" "$1" &&
        grep -qF "Weak evidence" "$1"' sh \
    "$STANDARDIZE_REFS/mode-update.md"
expect_fail "update guidance does not claim target_commitish is always a commit" \
    grep -qF 'returns the actual release commit, not the branch name' \
    "$STANDARDIZE_REFS/mode-update.md"
expect_ok "cardinal rules require freezing the tuple after every render" \
    grep -qF '`--vcs-ref` does not survive into the answers file' \
    "$STANDARDIZE_SKILL"
# The legacy recovery branch calls `gh api`, which needs a credential even for a
# public repo. Preconditions must say so, and gh failures must not be reported as
# a missing release record.
expect_ok "top-level prerequisites scope gh to the legacy update branch" \
    sh -c 'grep -qF "update mode'\''s legacy-baseline branch" "$1" &&
        grep -qF "\`_commit\` is tag-valued" "$1"' sh \
    "$STANDARDIZE_SKILL"
expect_ok "top-level prerequisites explain why gh needs a credential" \
    grep -qF 'requires a credential even on' "$STANDARDIZE_SKILL"
# diff-template.sh resolves its baseline with git ls-remote and never calls
# gh api, so audit must not inherit update mode's credential requirement.
expect_ok "top-level prerequisites exempt audit from the gh requirement" \
    grep -qF "legacy-baseline recovery — that path is \`git\`-only" \
    "$STANDARDIZE_SKILL"
# The Code Security check calls gh api on private/internal repos whatever the
# recorded lineage is, so the gh exemption must not be stated as blanket.
expect_ok "top-level prerequisites keep gh for the Code Security check" \
    sh -c 'grep -qF "Code Security capability check" "$1" &&
        grep -qF "regardless of lineage, including full-hash baselines" "$1"' sh \
    "$STANDARDIZE_SKILL"
expect_fail "audit drift helper does not depend on gh" \
    grep -qE '(^|[^[:alnum:]])gh (api|auth|release) ' \
    "$STANDARDIZE_ASSETS/diff-template.sh"
expect_fail "top-level prerequisites do not limit gh to side-effect steps" \
    grep -qF 'only needed for the GitHub side-effect' "$STANDARDIZE_SKILL"
expect_ok "top-level prerequisites declare the yq dependency" \
    grep -qF '**yq** on PATH' "$STANDARDIZE_SKILL"
expect_ok "update guidance probes gh before the legacy release lookup" \
    sh -c 'grep -qF "legacy baseline recovery requires the gh CLI on PATH" "$1" &&
        grep -qF "requires authenticated gh; run gh auth login" "$1"' sh \
    "$STANDARDIZE_REFS/mode-update.md"
expect_ok "update guidance detects a missing release by HTTP status" \
    grep -qF "grep -q 'HTTP 404'" \
    "$STANDARDIZE_REFS/mode-update.md"
expect_ok "update guidance reports a release API failure distinctly" \
    grep -qF 'cannot read the GitHub release record for' \
    "$STANDARDIZE_REFS/mode-update.md"
expect_ok "update guidance justifies keeping the gh release check" \
    grep -qF 'Do not "simplify" this by dropping `gh`' \
    "$STANDARDIZE_REFS/mode-update.md"
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
expect_ok "catalog documents answer-driven CodeQL omission" \
    grep -qF 'No `codeql.yml`** when `use_codeql=false`' \
    "$STANDARDIZE_REFS/standards-catalog.md"
expect_ok "catalog distinguishes CodeQL source from tooling flags" \
    grep -qF '`use_node` and `use_python` describe tooling;' \
    "$STANDARDIZE_REFS/standards-catalog.md"
expect_ok "catalog requires the CodeQL matrix to match real source" \
    grep -qF 'persisted matrix with real first-party source' \
    "$STANDARDIZE_REFS/standards-catalog.md"
expect_ok "catalog scopes the Copier payload exclusion to capability gating" \
    grep -qF 'Security coverage does **not** skip it' \
    "$STANDARDIZE_REFS/standards-catalog.md"
expect_ok "catalog requires protected-event CodeQL triggers" \
    grep -qF 'triggers on PR and `merge_group`' \
    "$STANDARDIZE_REFS/standards-catalog.md"
expect_ok "skill favors rolling updates over permanent version migrations" \
    grep -qF 'regular rolling updates' \
    "$STANDARDIZE_SKILL"
expect_ok "skill keeps credential writes human-only" \
    grep -qF 'Keep secret and credential-store writes human-only.' \
    "$STANDARDIZE_SKILL"
expect_ok "update guidance requires a deletion audit" \
    grep -qF 'Deletion audit — justify every removed pre-existing path.' \
    "$STANDARDIZE_REFS/mode-update.md"
expect_ok "skill always refreshes enabled skills sync" \
    grep -qF 'After a template apply or update, if `.skills-sync.yaml` exists' \
    "$STANDARDIZE_SKILL"
expect_ok "skill completion requires green CI and review adjudication" \
    grep -qF 'watch every required check to a terminal green result' \
    "$STANDARDIZE_SKILL"
expect_fail "repository checklist has no bare Copier update path" \
    grep -qE '`copier update --trust` to pull' "$repo/docs/CHECKLIST.md"
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
    grep -qF 'plus **`codeql-verify`** exactly when' \
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
expect_ok "audit guidance classifies required checks that cannot report" \
    grep -qF '**D2. A required context that cannot report.**' \
    "$STANDARDIZE_REFS/mode-audit.md"
expect_ok "audit guidance classes a job-level if bypass as fail-open, not a wedge" \
    grep -qF 'that one is fail-**open** (the gate is bypassed, not wedged)' \
    "$STANDARDIZE_REFS/mode-audit.md"
expect_ok "catalog requires unfiltered triggers for every required context" \
    grep -qF 'Every required context must report unconditionally.' \
    "$STANDARDIZE_REFS/standards-catalog.md"
expect_ok "audit guidance binds provisioning to the gate job" \
    grep -qF 'in a sibling job, an unused `./.github/actions/*`, or a dead workflow' \
    "$STANDARDIZE_REFS/mode-audit.md"
expect_ok "catalog binds the Terraform toolchain to the gate job" \
    grep -qF 'per job, not per workflow or per repo:' \
    "$STANDARDIZE_REFS/standards-catalog.md"
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
        cat >"$AGG_TARGET/scripts/verify-ci-results.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
for pair in "$@"; do
    case "${pair#*=}" in success | skipped) ;; *) exit 1 ;; esac
done
EOF
    else
        cat >"$AGG_TARGET/scripts/verify-ci-results.sh" <<'EOF'
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
    chmod +x "$AGG_TARGET/scripts/verify-ci-results.sh"
}

write_aggregate_workflows() {
    local mode="${1:-safe}"
    cat >"$AGG_TARGET/.github/workflows/build.yml" <<'EOF'
name: Build
on: [push, pull_request, merge_group]
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
        run: ./scripts/verify-ci-results.sh "lint=${LINT_RESULT}" "security=${SECURITY_RESULT}"
EOF
    cat >"$AGG_TARGET/.github/workflows/devcontainer-build.yml" <<'EOF'
name: Devcontainer
on: [push, pull_request, merge_group]
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
        run: ./scripts/verify-ci-results.sh "build=${BUILD_RESULT}"
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
    local extra_context="" conditions=""
    local base_contexts=$'{"context": "verify"},\n          {"context": "security"}'
    # Split-workflow repos require per-workflow aggregate rollups instead of the
    # template's verify/security pair (e.g. harmon-infra).
    local split_contexts=$'{"context": "build-verify"},\n          {"context": "validate-verify"},\n          {"context": "security-verify"}'
    case "$mode" in
    baseline) ;;
    terraform) extra_context=$',\n          {"context": "terraform-verify"}' ;;
    codeql) extra_context=$',\n          {"context": "codeql-verify"}' ;;
    split-terraform | split-terraform-ghost)
        base_contexts="$split_contexts"
        extra_context=$',\n          {"context": "terraform-verify"}'
        if [ "$mode" = split-terraform-ghost ]; then
            extra_context="$extra_context"$',\n          {"context": "ghost-verify"}'
        fi
        ;;
    nested-protected-branch)
        # A protected ref with path segments — the case where GitHub's `*`
        # (which stops at `/`) and a shell glob disagree.
        base_contexts="$split_contexts"
        extra_context=$',\n          {"context": "terraform-verify"}'
        conditions=$'  "conditions": {\n    "ref_name": {\n      "include": ["refs/heads/releases/2026/q3"],\n      "exclude": []\n    }\n  },\n'
        ;;
    wildcard-protected-branch)
        # A ref SELECTOR rather than a branch — coverage is a manual audit.
        base_contexts="$split_contexts"
        extra_context=$',\n          {"context": "terraform-verify"}'
        conditions=$'  "conditions": {\n    "ref_name": {\n      "include": ["refs/heads/releases/**"],\n      "exclude": []\n    }\n  },\n'
        ;;
    excluded-included-branch)
        # `exclude` removes one of the included refs — it is not protected.
        base_contexts="$split_contexts"
        extra_context=$',\n          {"context": "terraform-verify"}'
        conditions=$'  "conditions": {\n    "ref_name": {\n      "include": ["refs/heads/main", "refs/heads/release"],\n      "exclude": ["refs/heads/release"]\n    }\n  },\n'
        ;;
    bracketed-protected-branch)
        # A ref name containing `]` — a regex-based array scan would stop early.
        # Spaces around the key colons too: valid JSON the walker must accept.
        base_contexts="$split_contexts"
        extra_context=$',\n          {"context": "terraform-verify"}'
        conditions='  "conditions" : {"ref_name" : {"include" : ["refs/heads/release]","refs/heads/main"], "exclude" : []}},'$'\n'
        ;;
    wildcard-excluded-branch)
        # A wildcard exclusion whose reach this auditor will not guess at.
        base_contexts="$split_contexts"
        extra_context=$',\n          {"context": "terraform-verify"}'
        conditions=$'  "conditions": {\n    "ref_name": {\n      "include": ["refs/heads/main", "refs/heads/main1"],\n      "exclude": ["refs/heads/main?"]\n    }\n  },\n'
        ;;
    escaped-protected-branch)
        # A protected branch whose name contains a glob special character.
        base_contexts="$split_contexts"
        extra_context=$',\n          {"context": "terraform-verify"}'
        conditions=$'  "conditions": {\n    "ref_name": {\n      "include": ["refs/heads/release/v1+"],\n      "exclude": []\n    }\n  },\n'
        ;;
    all-branches-protected)
        # `~ALL` selects every branch — not reducible to one branch name.
        base_contexts="$split_contexts"
        extra_context=$',\n          {"context": "terraform-verify"}'
        conditions=$'  "conditions": {\n    "ref_name": {\n      "include": ["~ALL"],\n      "exclude": []\n    }\n  },\n'
        ;;
    compact-multi-branch)
        # Compact JSON putting every ref on one line, `exclude` ahead of
        # `include` (member order must not matter), and an excluded ref that
        # must NOT be treated as protected.
        base_contexts="$split_contexts"
        extra_context=$',\n          {"context": "terraform-verify"}'
        conditions='  "conditions":{"ref_name":{"exclude":["refs/heads/wip"],"include":["refs/heads/main","refs/heads/release"]}},'$'\n'
        ;;
    *) fail "unknown ruleset fixture mode: $mode" ;;
    esac
    mkdir -p "$target/.github"
    cat >"$target/.github/Branch Protection Ruleset - Protect Main.json" <<EOF
{
$conditions  "rules": [
    {
      "type": "required_status_checks",
      "parameters": {
        "required_status_checks": [
          $base_contexts$extra_context
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
expect_fail "verify-applied rejects codeql-verify without CodeQL intent" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$AGG_TARGET"
write_required_check_ruleset "$AGG_TARGET"

# A Copier template repo's payload belongs to the repos it generates, not to
# itself: harmon-init ships jinja-gated `.tf` files that must not switch on this
# repo's Terraform contract. The same tree without a copier.yml still does.
mkdir -p "$AGG_TARGET/template/[% if include_terraform %]terraform[% endif %]"
printf '%s\n' 'terraform {}' \
    >"$AGG_TARGET/template/[% if include_terraform %]terraform[% endif %]/main.tf"
expect_fail_contains "verify-applied treats .tf outside a template payload as first-party" \
    "Terraform is present but scripts/terraform-provider-locks.sh is missing" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$AGG_TARGET"
printf '%s\n' '_subdirectory: template' >"$AGG_TARGET/copier.yml"
expect_ok_contains "verify-applied excludes a Copier template's payload from capability detection" \
    "excluding the 'template/' payload" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$AGG_TARGET"
# Copier accepts several spellings of the same payload root; all must normalize
# or the exclusion silently misses and the false positive returns.
for payload_spelling in './template' 'template/' '"template"' 'template  # payload root'; do
    printf '_subdirectory: %s\n' "$payload_spelling" >"$AGG_TARGET/copier.yml"
    expect_ok_contains "verify-applied normalizes the payload root '$payload_spelling'" \
        "excluding the 'template/' payload" \
        bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$AGG_TARGET"
done
# `_subdirectory` is a top-level setting: the same text nested in a question
# must not be believed, or an arbitrary directory drops out of capability
# detection and the Terraform contract is skipped for a repo that owns it.
printf '%s\n' 'questions:' '  example:' '    _subdirectory: template' \
    >"$AGG_TARGET/copier.yml"
expect_fail_contains "verify-applied ignores a nested _subdirectory setting" \
    "Terraform is present but scripts/terraform-provider-locks.sh is missing" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$AGG_TARGET"
# copier.yml may hold several YAML documents, which Copier merges with the
# later ones overriding — so the LAST top-level setting is the effective payload
# root. Taking the first would exclude the wrong directory and skip the contract
# for source the repo really owns.
printf '%s\n' '_subdirectory: nonpayload' '---' '{_subdirectory: template}' \
    >"$AGG_TARGET/copier.yml"
expect_ok_contains "verify-applied takes the effective payload root from merged documents" \
    "excluding the 'template/' payload" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$AGG_TARGET"
# Copier splices `!include <glob>` documents into the manifest before merging.
# yq has no such tag and fails the whole merge on it, so the include is expanded
# first — otherwise a valid template loses its payload root.
printf '%s\n' '_subdirectory: template' >"$AGG_TARGET/copier-shared.yml"
printf '%s\n' '!include copier-shared.yml' >"$AGG_TARGET/copier.yml"
expect_ok_contains "verify-applied resolves a payload root behind a Copier !include" \
    "excluding the 'template/' payload" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$AGG_TARGET"
# Copier's include constructor reuses the same loader, so includes nest — and
# it closes over the TOP-LEVEL manifest, so a nested glob still resolves against
# that directory, not the included file's.
mkdir -p "$AGG_TARGET/config"
printf '%s\n' '!include copier-shared.yml' >"$AGG_TARGET/config/outer.yml"
printf '%s\n' '!include config/outer.yml' >"$AGG_TARGET/copier.yml"
expect_ok_contains "verify-applied roots a nested Copier !include at the manifest" \
    "excluding the 'template/' payload" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$AGG_TARGET"
rm -rf "$AGG_TARGET/config"
# A glob matching several fragments is declined: the last one setting
# `_subdirectory` wins, and shell expansion orders them differently from
# Python's Path.glob (and hides dotfiles).
printf '%s\n' '_subdirectory: template' >"$AGG_TARGET/frag-a.yml"
printf '%s\n' '_subdirectory: elsewhere' >"$AGG_TARGET/frag-b.yml"
printf '%s\n' '!include frag-*.yml' >"$AGG_TARGET/copier.yml"
expect_fail_contains "verify-applied declines a multi-fragment include glob" \
    "uses an '!include' glob this auditor does not" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$AGG_TARGET"
rm -f "$AGG_TARGET/frag-a.yml" "$AGG_TARGET/frag-b.yml"
# Copier globs with Path.glob, which matches leading-dot names — so a hidden
# fragment is part of the match set and must not leave this looking single.
printf '%s\n' '_subdirectory: template' >"$AGG_TARGET/a-frag.yml"
printf '%s\n' '_subdirectory: elsewhere' >"$AGG_TARGET/.b-frag.yml"
printf '%s\n' '!include *frag.yml' >"$AGG_TARGET/copier.yml"
expect_fail_contains "verify-applied counts hidden include fragments like Path.glob" \
    "uses an '!include' glob this auditor does not" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$AGG_TARGET"
rm -f "$AGG_TARGET/a-frag.yml" "$AGG_TARGET/.b-frag.yml"
# Copier rejects a non-string _subdirectory, so `123` is not a directory here.
printf '%s\n' '_subdirectory: 123' >"$AGG_TARGET/copier.yml"
expect_fail_contains "verify-applied declines a non-string payload root" \
    "declares a non-string _subdirectory" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$AGG_TARGET"
# An include glob this auditor cannot reproduce exactly (Copier uses Python's
# Path.glob) is declined with a diagnostic rather than half-matched.
printf '%s\n' '!include "fragments/shared config.yml"' >"$AGG_TARGET/copier.yml"
expect_fail_contains "verify-applied declines an include glob it cannot reproduce" \
    "uses an '!include' glob this auditor does not" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$AGG_TARGET"
rm -f "$AGG_TARGET/copier-shared.yml"
# Copier matches the manifest suffix case-insensitively, so an uppercase
# spelling is a real template — and two of them are ambiguous to Copier.
printf '%s\n' '_subdirectory: template' >"$AGG_TARGET/copier.YAML"
rm -f "$AGG_TARGET/copier.yml"
expect_ok_contains "verify-applied discovers a case-variant Copier manifest" \
    "excluding the 'template/' payload" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$AGG_TARGET"
printf '%s\n' '_subdirectory: template' >"$AGG_TARGET/copier.yml"
expect_fail_contains "verify-applied declines to exclude across case-variant manifests" \
    "Copier rejects that as ambiguous" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$AGG_TARGET"
rm -f "$AGG_TARGET/copier.YAML"
# An unparseable manifest is diagnosed rather than silently treated as "no
# payload root" — the exclusion is declined either way, which over-reports the
# capability instead of skipping a contract the repo really owes.
printf '%s\n' '_subdirectory: [unclosed' >"$AGG_TARGET/copier.yml"
expect_fail_contains "verify-applied reports a Copier manifest it cannot parse" \
    "yq could not parse" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$AGG_TARGET"
# Lexical dot segments must normalize, or the prefix compare matches nothing
# against the `template/main.tf` paths git reports.
for payload_dots in 'template/.' '././template' 'template//'; do
    printf '_subdirectory: "%s"\n' "$payload_dots" >"$AGG_TARGET/copier.yml"
    expect_ok_contains "verify-applied normalizes dot segments in '$payload_dots'" \
        "excluding the 'template/' payload" \
        bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$AGG_TARGET"
done
# A `..` segment has no lexical prefix to compare against repo-relative paths.
printf '%s\n' '_subdirectory: "../template"' >"$AGG_TARGET/copier.yml"
expect_fail_contains "verify-applied declines a payload root walking outside the repo" \
    "walks" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$AGG_TARGET"
# Copier rejects an absolute include path outright, so a repo-root fragment must
# not be read and trusted here.
printf '%s\n' '_subdirectory: elsewhere' >"$AGG_TARGET/frag.yml"
printf '%s\n' '!include /frag.yml' >"$AGG_TARGET/copier.yml"
expect_fail_contains "verify-applied rejects an absolute Copier include path" \
    "absolute '!include' path, which Copier rejects" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$AGG_TARGET"
rm -f "$AGG_TARGET/frag.yml"
# Copier's Path.glob yields directories too and its loader dies reading one, so
# a non-file match is reason to decline rather than quietly skip.
mkdir -p "$AGG_TARGET/frag-dir.yml"
printf '%s\n' '_subdirectory: template' >"$AGG_TARGET/frag-ok.yml"
printf '%s\n' '!include frag-dir.yml' >"$AGG_TARGET/copier.yml"
expect_fail_contains "verify-applied declines an include glob matching a directory" \
    "uses an '!include' glob this auditor does not" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$AGG_TARGET"
rm -rf "$AGG_TARGET/frag-dir.yml" "$AGG_TARGET/frag-ok.yml"
# `_envops` can set any Jinja delimiters, so a templated payload root need not
# use a spelling the delimiter list knows. It is still not a real directory —
# excluding it would match nothing while announcing that it excluded something.
printf '%s\n' '_subdirectory: "<< payload >>"' >"$AGG_TARGET/copier.yml"
expect_fail_contains "verify-applied declines a payload root that is not a directory" \
    "but no such" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$AGG_TARGET"
# A templated payload root cannot be resolved without answers; say so and
# exclude nothing rather than compare against the literal Jinja text.
printf '%s\n' '_subdirectory: "template/{{ variant }}"' >"$AGG_TARGET/copier.yml"
expect_fail_contains "verify-applied reports an unresolvable templated payload root" \
    "copier.yml declares a templated payload root" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$AGG_TARGET"
rm -rf "$AGG_TARGET/template" "$AGG_TARGET/copier.yml"

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
cp "$AGG_TARGET/scripts/verify-ci-results.sh" \
    "$CQ_TARGET/scripts/verify-ci-results.sh"
write_required_check_ruleset "$CQ_TARGET"
# Some CI runner images provide gitleaks in the lint job. Give its repository
# scan a real HEAD so an unrelated empty-history error cannot make every
# verify-applied assertion look like an expected CodeQL failure.
git_commit_all "$CQ_TARGET" "record CodeQL fixture baseline"
expect_ok "CodeQL fixture has a committed baseline for repository scanners" \
    git -C "$CQ_TARGET" rev-parse --verify HEAD

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
    local job_continue="$1"
    local analyze_continue="${2:-}"
    local extra_steps="${3:-}"
    local language_matrix="${4:-}"
    local aggregate_mode="${5:-safe}"
    local event_style="${6:-mapping}"
    local workflow_events=$'on:\n  pull_request:\n  merge_group:'
    local checkout_guard=$'        if: >-\n          github.event_name != '\''pull_request'\'' ||\n          github.event.pull_request.head.repo.full_name == github.repository\n'
    if [ "$aggregate_mode" = unsafe-checkout ]; then
        checkout_guard=""
    fi
    if [ "$event_style" = inline ]; then
        workflow_events='on: [pull_request, merge_group]'
    elif [ "$event_style" = list ]; then
        workflow_events=$'on:\n  - pull_request\n  - merge_group'
    fi
    cat >"$CQ_TARGET/.github/workflows/codeql.yml" <<EOF
name: CodeQL
$workflow_events
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
          EXPECTED_RESULT: \${{ vars.FULL_SECURITY_SCAN == 'true' && 'success' || 'skipped' }}
          ANALYZE_RESULT: \${{ needs.analyze.result }}
        run: ./scripts/verify-ci-results.sh "analyze=\${ANALYZE_RESULT}"
      - name: Check deliberate fork skip
        if: >-
          github.event_name == 'pull_request' &&
          github.event.pull_request.head.repo.full_name != github.repository
        env:
          ANALYZE_RESULT: \${{ needs.analyze.result }}
        run: |
          if [ "\$ANALYZE_RESULT" != "skipped" ]; then
            exit 1
          fi
EOF
}
remove_codeql_event() {
    grep -v "^  $1:" "$CQ_TARGET/.github/workflows/codeql.yml" \
        >"$CQ_TARGET/.github/workflows/codeql.yml.tmp"
    mv "$CQ_TARGET/.github/workflows/codeql.yml.tmp" \
        "$CQ_TARGET/.github/workflows/codeql.yml"
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
write_required_check_ruleset "$CQ_TARGET" codeql
expect_fail "verify-applied rejects codeql-verify when CodeQL is disabled" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$CQ_TARGET"
write_required_check_ruleset "$CQ_TARGET"

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
write_codeql_workflow ""
remove_codeql_event pull_request
expect_fail "verify-applied requires the CodeQL pull_request trigger" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$CQ_TARGET"
write_codeql_workflow ""
remove_codeql_event merge_group
expect_fail "verify-applied requires the CodeQL merge_group trigger" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$CQ_TARGET"
write_codeql_workflow $'    continue-on-error: true\n'
expect_fail "verify-applied rejects a fail-open CodeQL analyze job" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$CQ_TARGET"
write_codeql_workflow "" $'        continue-on-error: true\n'
expect_fail "verify-applied rejects a fail-open CodeQL analyze action" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$CQ_TARGET"
write_codeql_workflow ""
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' \
    >"$CQ_TARGET/scripts/verify-ci-results.sh"
chmod +x "$CQ_TARGET/scripts/verify-ci-results.sh"
expect_fail "verify-applied rejects a CodeQL aggregate that accepts every result" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$CQ_TARGET"
cp "$AGG_TARGET/scripts/verify-ci-results.sh" \
    "$CQ_TARGET/scripts/verify-ci-results.sh"
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
expect_fail "verify-applied requires codeql-verify when CodeQL is enabled" \
    env PATH="$FAKE_GH_BIN:$PATH" GH_TEST_VISIBILITY=private \
    GH_TEST_CODE_SECURITY=enabled \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$CQ_TARGET"
write_required_check_ruleset "$CQ_TARGET" codeql
write_codeql_workflow "" "" "" "" safe inline
expect_ok "verify-applied accepts inline CodeQL protected-event triggers" \
    env PATH="$FAKE_GH_BIN:$PATH" GH_TEST_VISIBILITY=private \
    GH_TEST_CODE_SECURITY=enabled \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$CQ_TARGET"
write_codeql_workflow "" "" "" "" safe list
expect_ok "verify-applied accepts block-list CodeQL protected-event triggers" \
    env PATH="$FAKE_GH_BIN:$PATH" GH_TEST_VISIBILITY=private \
    GH_TEST_CODE_SECURITY=enabled \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$CQ_TARGET"
write_codeql_workflow ""
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
# A Copier payload is excluded from CAPABILITY detection but stays in the CodeQL
# source inventory — it is authored code the template distributes, so a missing
# language is a real scanning gap, not a template artifact.
printf '%s\n' '_subdirectory: template' >"$CQ_TARGET/copier.yml"
mkdir -p "$CQ_TARGET/template/src"
printf '%s\n' 'print("shipped to generated repos")' \
    >"$CQ_TARGET/template/src/app.py"
write_codeql_workflow "" "" "" \
    $'    strategy:\n      matrix:\n        language: [javascript-typescript]\n'
expect_ok_contains "verify-applied keeps a Copier payload in CodeQL source coverage" \
    'first-party Python source exists but CodeQL omits python.' \
    env PATH="$FAKE_GH_BIN:$PATH" GH_TEST_VISIBILITY=private \
    GH_TEST_CODE_SECURITY=enabled \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$CQ_TARGET"
rm -rf "$CQ_TARGET/template" "$CQ_TARGET/copier.yml"
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
printf '%s\n' 'include_terraform: true' 'use_codeql: false' \
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
    local mode="${2:-inline}"
    local tflint_step='      - uses: terraform-linters/setup-tflint@1111111111111111111111111111111111111111'
    local lint_setup_steps sibling_toolchain_job=""
    local gate_step='      - run: task check'
    if [ "$include_tflint" = false ]; then
        tflint_step=""
    fi
    case "$mode" in
    inline)
        # The gate job installs the toolchain in its own steps (harmon-infra).
        lint_setup_steps="      - uses: hashicorp/setup-terraform@1111111111111111111111111111111111111111
$tflint_step
      - uses: astral-sh/setup-uv@1111111111111111111111111111111111111111"
        ;;
    composite)
        # The gate job installs it through the local composite action a freshly
        # rendered repo ships (.github/actions/setup).
        lint_setup_steps="      - uses: ./.github/actions/setup"
        ;;
    prefixed-gate)
        # `task check` behind an environment prefix is still the gate.
        lint_setup_steps="      - uses: hashicorp/setup-terraform@1111111111111111111111111111111111111111
$tflint_step
      - uses: astral-sh/setup-uv@1111111111111111111111111111111111111111"
        gate_step='      - run: CI=true task check'
        ;;
    sibling-toolchain | sibling-toolchain-anchored)
        # The toolchain is provisioned in a DIFFERENT job — nothing lands on
        # the gate job's runner, so `task check` cannot reach Terraform lint.
        # The anchored variant puts a YAML anchor on the sibling's job header;
        # a job-boundary test that demanded a bare `job:` line would miss the
        # header and hand the gate job its sibling's steps.
        local sibling_header="  toolchain:"
        if [ "$mode" = sibling-toolchain-anchored ]; then
            sibling_header="  toolchain: &toolchain"
        fi
        lint_setup_steps=""
        sibling_toolchain_job="$sibling_header
    runs-on: ubuntu-latest
    steps:
      - uses: hashicorp/setup-terraform@1111111111111111111111111111111111111111
$tflint_step
      - uses: astral-sh/setup-uv@1111111111111111111111111111111111111111
      - run: echo toolchain"
        ;;
    *) fail "unknown Terraform build workflow fixture mode: $mode" ;;
    esac
    cat >"$TF_TARGET/.github/workflows/build.yml" <<EOF
name: Build
on:
  pull_request:
  merge_group:
jobs:
  lint:
    if: >-
      github.event_name != 'pull_request' ||
      github.event.pull_request.head.repo.full_name == github.repository
    runs-on: ubuntu-latest
    steps:
$lint_setup_steps
$gate_step
$sibling_toolchain_job
  security:
    if: >-
      github.event_name != 'pull_request' ||
      github.event.pull_request.head.repo.full_name == github.repository
    runs-on: ubuntu-latest
    steps:
      - run: echo security
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
        run: ./scripts/verify-ci-results.sh "lint=\${LINT_RESULT}"
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
# The ruleset requires terraform-verify, so a workflow must define that job —
# a required check no workflow reports would wedge every PR.
cat >"$TF_TARGET/.github/workflows/terraform.yml" <<'EOF'
name: Terraform
on:
  push:
  pull_request:
  merge_group:
  workflow_dispatch:
jobs:
  changes:
    runs-on: ubuntu-latest
    steps:
      - run: echo changes
  terraform-verify:
    if: always()
    needs: [changes]
    runs-on: ubuntu-latest
    steps:
      - env:
          CHANGES_RESULT: ${{ needs.changes.result }}
        run: |
          [ "$CHANGES_RESULT" = "success" ] || exit 1
EOF
cp "$AGG_TARGET/scripts/verify-ci-results.sh" \
    "$TF_TARGET/scripts/verify-ci-results.sh"
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
write_terraform_build_workflow true sibling-toolchain
expect_fail_contains "verify-applied rejects a toolchain provisioned outside the 'task check' job" \
    "job 'lint' runs 'task check' but neither it nor the composite actions it uses provisions Terraform lint dependency: hashicorp/setup-terraform@" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$TF_TARGET"
write_terraform_build_workflow true sibling-toolchain-anchored
expect_fail_contains "verify-applied stops a gate job's block at an anchored sibling job header" \
    "job 'lint' runs 'task check' but neither it nor the composite actions it uses provisions Terraform lint dependency: hashicorp/setup-terraform@" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$TF_TARGET"
# The gate job may instead reach the toolchain through the local composite
# action a freshly rendered repo ships; an unused composite must not vouch.
mkdir -p "$TF_TARGET/.github/actions/setup"
cat >"$TF_TARGET/.github/actions/setup/action.yml" <<'EOF'
name: Setup toolchain
description: Install the shared toolchain.
runs:
  using: composite
  steps:
    - uses: hashicorp/setup-terraform@1111111111111111111111111111111111111111
    - uses: terraform-linters/setup-tflint@1111111111111111111111111111111111111111
    - uses: astral-sh/setup-uv@1111111111111111111111111111111111111111
EOF
expect_fail_contains "verify-applied rejects a composite action the gate job never uses" \
    "job 'lint' runs 'task check' but neither it nor the composite actions it uses provisions Terraform lint dependency: hashicorp/setup-terraform@" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$TF_TARGET"
write_terraform_build_workflow true composite
expect_ok "verify-applied accepts a gate job provisioned by its composite action" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$TF_TARGET"
rm -rf "$TF_TARGET/.github/actions"
write_terraform_build_workflow true prefixed-gate
expect_ok "verify-applied finds the gate job behind an environment prefix" \
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

# Split-workflow layout (harmon-infra shape): per-workflow aggregates named
# build-verify/validate-verify/security-verify, lint toolchain provisioned in
# validate.yml instead of build.yml, and the ruleset requiring the rollup set.
write_split_terraform_workflows() {
    cat >"$TF_TARGET/.github/workflows/build.yml" <<EOF
name: Build
on:
  pull_request:
  merge_group:
jobs:
  build-homepage:
    if: >-
      github.event_name != 'pull_request' ||
      github.event.pull_request.head.repo.full_name == github.repository
    runs-on: ubuntu-latest
    steps:
      - run: echo build
  build-verify:
    if: always()
    needs: [build-homepage]
    runs-on: ubuntu-latest
    env:
      IS_FORK: \${{ github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name != github.repository }}
    steps:
      - name: Verify deliberate skips at the untrusted-fork boundary
        if: env.IS_FORK == 'true'
        env:
          BUILD_HOMEPAGE_RESULT: \${{ needs.build-homepage.result }}
        run: |
          if [ "\$BUILD_HOMEPAGE_RESULT" != "skipped" ]; then
            exit 1
          fi
          echo "Untrusted fork trust boundary enforced: all repository-controlled jobs were deliberately skipped."
      - if: env.IS_FORK != 'true'
        uses: actions/checkout@1111111111111111111111111111111111111111
      - name: Verify required jobs succeeded
        if: env.IS_FORK != 'true'
        env:
          EXPECTED_RESULT: success
          BUILD_HOMEPAGE_RESULT: \${{ needs.build-homepage.result }}
        run: ./scripts/verify-ci-results.sh "build-homepage=\${BUILD_HOMEPAGE_RESULT}"
EOF
    cat >"$TF_TARGET/.github/workflows/validate.yml" <<'EOF'
name: Validate
on:
  pull_request:
  merge_group:
jobs:
  lint:
    if: >-
      github.event_name != 'pull_request' ||
      github.event.pull_request.head.repo.full_name == github.repository
    runs-on: ubuntu-latest
    steps:
      - uses: hashicorp/setup-terraform@1111111111111111111111111111111111111111
      - uses: terraform-linters/setup-tflint@1111111111111111111111111111111111111111
      - uses: astral-sh/setup-uv@1111111111111111111111111111111111111111
      - run: task check
  validate-verify:
    if: always()
    needs: [lint]
    runs-on: ubuntu-latest
    steps:
      - env:
          IS_FORK: ${{ github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name != github.repository }}
          LINT_RESULT: ${{ needs.lint.result }}
        run: |
          case "$IS_FORK" in
            true) expected=skipped ;;
            false) expected=success ;;
            *) exit 1 ;;
          esac
          [ "$LINT_RESULT" = "$expected" ] || exit 1
EOF
    cat >"$TF_TARGET/.github/workflows/security.yml" <<'EOF'
name: Security
on:
  pull_request:
  merge_group:
jobs:
  secrets:
    runs-on: ubuntu-latest
    steps:
      - run: echo secrets
  security-verify:
    if: always()
    needs: [secrets]
    runs-on: ubuntu-latest
    steps:
      - env:
          SECRETS_RESULT: ${{ needs.secrets.result }}
        run: |
          [ "$SECRETS_RESULT" = "success" ] || exit 1
EOF
}
# Echo-only substitute rollup: exists as a job but is not result-gated, so it
# must NOT satisfy the ruleset in place of the template aggregates.
write_ungated_security_workflow() {
    cat >"$TF_TARGET/.github/workflows/security.yml" <<'EOF'
name: Security
on:
  pull_request:
  merge_group:
jobs:
  security-verify:
    runs-on: ubuntu-latest
    steps:
      - run: echo security-verify
EOF
}
write_split_terraform_workflows
write_required_check_ruleset "$TF_TARGET" split-terraform
expect_ok "verify-applied accepts a split-workflow layout (per-workflow aggregates)" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$TF_TARGET"
write_required_check_ruleset "$TF_TARGET" split-terraform-ghost
expect_fail "verify-applied rejects a required check no workflow defines" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$TF_TARGET"
write_required_check_ruleset "$TF_TARGET" split-terraform
write_ungated_security_workflow
expect_fail "verify-applied rejects an echo-only substitute rollup" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$TF_TARGET"
write_split_terraform_workflows
cat >"$TF_TARGET/.github/workflows/terraform.yml" <<'EOF'
name: Terraform
on: workflow_dispatch
jobs:
  terraform-verify:
    runs-on: ubuntu-latest
    steps:
      - run: echo terraform-verify
EOF
expect_fail "verify-applied rejects a required check whose workflow never runs on protected events" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$TF_TARGET"
# Path-filtered protected events: the workflow triggers on pull_request and
# merge_group, but never starts for an out-of-scope change, so the required
# context stays pending and wedges that merge.
cat >"$TF_TARGET/.github/workflows/terraform.yml" <<'EOF'
name: Terraform
on:
  push:
    branches: [main]
    paths:
      - "terraform/**"
  pull_request:
    branches: [main]
    paths:
      - "terraform/**"
  merge_group:
  workflow_dispatch:
jobs:
  changes:
    runs-on: ubuntu-latest
    steps:
      - run: echo changes
  terraform-verify:
    if: always()
    needs: [changes]
    runs-on: ubuntu-latest
    steps:
      - env:
          CHANGES_RESULT: ${{ needs.changes.result }}
        run: |
          [ "$CHANGES_RESULT" = "success" ] || exit 1
EOF
expect_fail_contains "verify-applied rejects a required check behind a pull_request paths filter" \
    "its pull_request trigger carries a 'paths' filter" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$TF_TARGET"
sed -i.bak '/^      - "terraform\/\*\*"$/d; /^    paths:$/d' \
    "$TF_TARGET/.github/workflows/terraform.yml"
rm "$TF_TARGET/.github/workflows/terraform.yml.bak"
expect_ok "verify-applied accepts branch filters that cover the protected branch" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$TF_TARGET"
# $1/$2 are the block bodies of the pull_request / merge_group triggers
# (indented four spaces).
write_filtered_terraform_workflow() {
    cat >"$TF_TARGET/.github/workflows/terraform.yml" <<EOF
name: Terraform
on:
  push:
    branches: [main]
  pull_request:
$1
  merge_group:
${2:-}
  workflow_dispatch:
jobs:
  changes:
    runs-on: ubuntu-latest
    steps:
      - run: echo changes
  terraform-verify:
    if: always()
    needs: [changes]
    runs-on: ubuntu-latest
    steps:
      - env:
          CHANGES_RESULT: \${{ needs.changes.result }}
        run: |
          [ "\$CHANGES_RESULT" = "success" ] || exit 1
EOF
}
# An unlisted trigger key is rejected on sight rather than assumed harmless —
# the allowlist is `branches`, `branches-ignore`, `types`.
write_filtered_terraform_workflow '    paths-ignore: ["docs/**"]'
expect_fail_contains "verify-applied rejects an unlisted trigger filter key" \
    "its pull_request trigger carries a 'paths-ignore' filter" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$TF_TARGET"
# A narrowed activity-type list that drops `synchronize` reports once and never
# again, so a pushed commit leaves the required check pending forever.
write_filtered_terraform_workflow '    types: [opened, reopened]'
expect_fail_contains "verify-applied rejects a types filter that drops synchronize" \
    "its pull_request types: filter omits 'synchronize'" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$TF_TARGET"
write_filtered_terraform_workflow '    types: [opened, reopened, synchronize]'
expect_ok "verify-applied accepts an explicit types list that keeps synchronize" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$TF_TARGET"
# merge_group has exactly one activity type; a list omitting it wedges the queue.
write_filtered_terraform_workflow '' '    types: [checks_required]'
expect_fail_contains "verify-applied rejects a merge_group types list without checks_requested" \
    "its merge_group types: filter omits 'checks_requested'" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$TF_TARGET"
write_filtered_terraform_workflow '' '    types: [checks_requested]'
expect_ok "verify-applied accepts an explicit merge_group checks_requested type" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$TF_TARGET"
# A branch filter is only safe when it COVERS the protected branch; one that
# excludes it wedges every protected merge just like a paths filter.
write_filtered_terraform_workflow '    branches: [develop]'
expect_fail_contains "verify-applied rejects a branches filter that excludes the protected branch" \
    "its pull_request branches: filter excludes main" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$TF_TARGET"
write_filtered_terraform_workflow '    branches: develop'
expect_fail_contains "verify-applied reads a scalar branches filter" \
    "its pull_request branches: filter excludes main" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$TF_TARGET"
write_filtered_terraform_workflow $'    branches-ignore:\n      - main'
expect_fail_contains "verify-applied rejects a branches-ignore filter naming the protected branch" \
    "its pull_request branches-ignore: filter excludes main" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$TF_TARGET"
write_filtered_terraform_workflow '    branches: ["releases/**", main]'
expect_ok "verify-applied accepts a glob branch filter covering the protected branch" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$TF_TARGET"
# GitHub evaluates branch patterns in order, so a later positive pattern
# re-includes a branch an earlier negative one excluded.
write_filtered_terraform_workflow '    branches: ["!main", main]'
expect_ok "verify-applied honors ordered branch patterns re-including a branch" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$TF_TARGET"
write_filtered_terraform_workflow '    branches: [main, "!main"]'
expect_fail_contains "verify-applied honors a later negative branch pattern" \
    "its pull_request branches: filter excludes main" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$TF_TARGET"
# An event body written as an inline flow mapping cannot be audited per key.
write_filtered_terraform_workflow ''
sed -i.bak 's|^  pull_request:$|  pull_request: {branches: main}|' \
    "$TF_TARGET/.github/workflows/terraform.yml"
rm "$TF_TARGET/.github/workflows/terraform.yml.bak"
expect_fail_contains "verify-applied rejects an unauditable inline event body" \
    "inline flow mapping this auditor cannot read per event" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$TF_TARGET"
# A flow mapping for the whole `on:` block hides its filters on one line; it is
# rejected outright rather than accepted unread.
cat >"$TF_TARGET/.github/workflows/terraform.yml" <<'EOF'
name: Terraform
on: {push: {branches: [main]}, pull_request: {paths: ["terraform/**"]}, merge_group: {}, workflow_dispatch: {}}
jobs:
  changes:
    runs-on: ubuntu-latest
    steps:
      - run: echo changes
  terraform-verify:
    if: always()
    needs: [changes]
    runs-on: ubuntu-latest
    steps:
      - env:
          CHANGES_RESULT: ${{ needs.changes.result }}
        run: |
          [ "$CHANGES_RESULT" = "success" ] || exit 1
EOF
expect_fail_contains "verify-applied rejects an unauditable inline flow-mapping on: block" \
    "inline flow mapping this auditor cannot read per event" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$TF_TARGET"
# GitHub branch globs are not shell globs: `*` stops at `/`, `**` crosses it. A
# nested protected branch is covered by `**` and NOT by a single `*`.
write_required_check_ruleset "$TF_TARGET" nested-protected-branch
write_filtered_terraform_workflow '    branches: ["releases/*"]'
expect_fail_contains "verify-applied applies GitHub glob semantics to a single-star branch filter" \
    "its pull_request branches: filter excludes releases/2026/q3" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$TF_TARGET"
write_filtered_terraform_workflow '    branches: ["releases/**"]'
expect_ok "verify-applied accepts a double-star branch filter crossing path segments" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$TF_TARGET"
# GitHub's `?` is "zero or one of the PRECEDING character", not "any one
# character": `main?` covers main and mai, never mainx.
write_required_check_ruleset "$TF_TARGET" split-terraform
write_filtered_terraform_workflow '    branches: ["main?"]'
expect_ok "verify-applied reads ? as an optional preceding character" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$TF_TARGET"
write_filtered_terraform_workflow '    branches: ["mai?"]'
expect_fail_contains "verify-applied does not treat ? as a wildcard character" \
    "its pull_request branches: filter excludes main" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$TF_TARGET"
# A wildcard ruleset selector names a set of branches; coverage is not decided
# statically, so it is surfaced for manual audit instead of matched literally.
write_required_check_ruleset "$TF_TARGET" wildcard-protected-branch
write_filtered_terraform_workflow '    branches: ["releases/*"]'
expect_ok_contains "verify-applied defers wildcard protected ref selectors to manual audit" \
    "ruleset protects the wildcard ref selector 'refs/heads/releases/**'" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$TF_TARGET"
# `~ALL` protects every branch; it is a selector, not a branch, so it must not
# silently collapse to the default branch.
write_required_check_ruleset "$TF_TARGET" all-branches-protected
write_filtered_terraform_workflow '    branches: [main]'
expect_ok_contains "verify-applied defers a ~ALL ruleset selector to manual audit" \
    "ruleset protects the ref selector '~ALL'" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$TF_TARGET"
# A comma inside a quoted pattern belongs to that pattern; splitting on it would
# invent a covering `main` that GitHub never sees.
write_required_check_ruleset "$TF_TARGET" split-terraform
write_filtered_terraform_workflow '    branches: ["main,release"]'
expect_fail_contains "verify-applied keeps a quoted comma inside one branch pattern" \
    "its pull_request branches: filter excludes main" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$TF_TARGET"
# Compact JSON keeps every protected ref on one line; all of them must be read,
# `exclude` refs must not be mistaken for protected ones, and `include` must be
# found whatever its position among the object's members.
write_required_check_ruleset "$TF_TARGET" compact-multi-branch
write_filtered_terraform_workflow '    branches: [release]'
expect_fail_contains "verify-applied reads every protected ref from a compact ruleset" \
    "its pull_request branches: filter excludes main" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$TF_TARGET"
write_filtered_terraform_workflow '    branches: [main, release]'
expect_ok "verify-applied ignores excluded refs when deriving protected branches" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$TF_TARGET"
# `exclude` carves a branch back out of `include`, so it is no longer protected
# and a filter that omits it must not be reported as a wedge.
write_required_check_ruleset "$TF_TARGET" excluded-included-branch
write_filtered_terraform_workflow '    branches: [main]'
expect_ok "verify-applied subtracts excluded refs from the included ones" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$TF_TARGET"
# A backslash escapes a literal special character in a GitHub branch pattern —
# in both YAML spellings, since double quotes eat one level of backslash.
write_required_check_ruleset "$TF_TARGET" escaped-protected-branch
write_filtered_terraform_workflow "    branches: ['release/v1\\+']"
expect_ok "verify-applied honors an escaped literal in a branch pattern" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$TF_TARGET"
write_filtered_terraform_workflow '    branches: ["release/v1\\+"]'
expect_ok "verify-applied decodes a YAML double-quoted escape in a branch pattern" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$TF_TARGET"
write_filtered_terraform_workflow '    branches: ["release/v1+"]'
expect_fail_contains "verify-applied reads an unescaped + as a quantifier" \
    "its pull_request branches: filter excludes release/v1+" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$TF_TARGET"
# A `#` only starts a YAML comment after whitespace, so it stays inside a
# branch name — truncating to `main` would fake coverage of the protected ref.
write_required_check_ruleset "$TF_TARGET" split-terraform
write_filtered_terraform_workflow '    branches: "main#backup"'
expect_fail_contains "verify-applied keeps a hash inside a quoted branch pattern" \
    "its pull_request branches: filter excludes main" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$TF_TARGET"
write_filtered_terraform_workflow '    branches: [main] # only the protected branch'
expect_ok "verify-applied still strips a real trailing comment" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$TF_TARGET"
# Ruleset JSON is walked as strings, so a ref name may contain the delimiters a
# regex would trip over.
write_required_check_ruleset "$TF_TARGET" bracketed-protected-branch
write_filtered_terraform_workflow '    branches: [main]'
expect_fail_contains "verify-applied reads a protected ref containing a JSON delimiter" \
    "its pull_request branches: filter excludes release]" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$TF_TARGET"
# A wildcard EXCLUSION is not applied: ruleset selectors use fnmatch, whose
# globstar reading differs from the Actions dialect, and guessing wrong would
# drop a genuinely protected branch. It warns and the branch stays protected.
write_required_check_ruleset "$TF_TARGET" wildcard-excluded-branch
write_filtered_terraform_workflow '    branches: [main]'
expect_fail_contains "verify-applied keeps branches protected against a wildcard exclusion" \
    "its pull_request branches: filter excludes main1" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$TF_TARGET"
write_filtered_terraform_workflow '    branches: [main, main1]'
expect_ok_contains "verify-applied reports an unapplied wildcard exclusion" \
    "ruleset excludes the wildcard ref selector 'refs/heads/main?'" \
    bash "$STANDARDIZE_ASSETS/verify-applied.sh" "$TF_TARGET"
write_required_check_ruleset "$TF_TARGET" terraform
cat >"$TF_TARGET/.github/workflows/terraform.yml" <<'EOF'
name: Terraform
on:
  push:
  pull_request:
  merge_group:
  workflow_dispatch:
jobs:
  changes:
    runs-on: ubuntu-latest
    steps:
      - run: echo changes
  terraform-verify:
    if: always()
    needs: [changes]
    runs-on: ubuntu-latest
    steps:
      - env:
          CHANGES_RESULT: ${{ needs.changes.result }}
        run: |
          [ "$CHANGES_RESULT" = "success" ] || exit 1
EOF

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
    scripts/test-terraform-provider-locks.sh \
    scripts/test-terraform-ci.sh \
    scripts/verify-ci-results.sh \
    scripts/sync-skills.sh \
    .github/workflows/close-milestone-on-release.yml \
    .foreman.toml \
    taskfiles/foreman.yml \
    scripts/foreman/cli.py; do
    expect_ok "template-owned manifest includes $required" grep -qxF "$required" "$manifest"
done

# Exercise executable-mode drift, equivalent mature layouts, legacy CodeRabbit
# opt-out handling, and index-backed transient deletions end to end with a tiny
# local Copier template. The real manifest is reused.
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
printf '%s\n' 'reviews:' '  profile: chill' >"$DT_TEMPLATE/template/.coderabbit.yaml"
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
if printf '%s\n' "$equivalent_out" |
    grep -qF "ABSENT   .coderabbit.yaml  (CodeRabbit disabled — expected)"; then
    ok "diff-template accepts legacy CodeRabbit opt-out as intentional absence"
else
    bad "diff-template accepts legacy CodeRabbit opt-out as intentional absence"
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

GA_TEMPLATE="$TMPROOT/guarded-audit-template"
GA_REMOTE="$TMPROOT/guarded-audit-remote.git"
GA_TARGET="$TMPROOT/guarded-audit-target"
mkdir -p "$GA_TEMPLATE/template"
cat >"$GA_TEMPLATE/copier.yml" <<'EOF'
_min_copier_version: "9.4.0"
_subdirectory: template
project_name:
  type: str
  default: Guarded Audit
EOF
cat >"$GA_TEMPLATE/template/.copier-answers.yml.jinja" <<'EOF'
{{ _copier_answers|to_nice_yaml -}}
EOF
printf '%s\n' guarded-audit >"$GA_TEMPLATE/template/audit.txt"
git_init "$GA_TEMPLATE"
git_commit_all "$GA_TEMPLATE" "guarded audit baseline"
git -C "$GA_TEMPLATE" tag v3.0.0
git clone --bare "$GA_TEMPLATE" "$GA_REMOTE" >/dev/null 2>&1
copier copy --trust --defaults --vcs-ref=v3.0.0 \
    "$GA_TEMPLATE" "$GA_TARGET" >/dev/null
GA_CANONICAL_SOURCE=https://github.com/evanharmon1/harmon-init
GA_CANONICAL_SOURCE="$GA_CANONICAL_SOURCE" \
    yq -i '._src_path = strenv(GA_CANONICAL_SOURCE)' \
    "$GA_TARGET/.copier-answers.yml"
expect_fail "guarded audit refuses an unapproved tag-valued baseline" \
    env \
    GIT_CONFIG_COUNT=1 \
    "GIT_CONFIG_KEY_0=url.$GA_REMOTE.insteadOf" \
    "GIT_CONFIG_VALUE_0=$GA_CANONICAL_SOURCE" \
    "$STANDARDIZE_ASSETS/diff-template.sh" "$GA_TARGET"
expect_ok "guarded audit snapshots the approved canonical tag baseline" \
    env \
    ACCEPT_LEGACY_BASELINE=true \
    GIT_CONFIG_COUNT=1 \
    "GIT_CONFIG_KEY_0=url.$GA_REMOTE.insteadOf" \
    "GIT_CONFIG_VALUE_0=$GA_CANONICAL_SOURCE" \
    "$STANDARDIZE_ASSETS/diff-template.sh" "$GA_TARGET"

GU_TEMPLATE="$TMPROOT/guarded-update-source"
GU_REMOTE="$TMPROOT/guarded-update-remote.git"
GU_TARGET="$TMPROOT/guarded-update-target"
GU_SNAPSHOT="$TMPROOT/guarded-update-snapshot"
GU_CACHE="$TMPROOT/guarded-update-cache"
mkdir -p "$GU_TEMPLATE/template"
mkdir -p "$GU_CACHE"
cat >"$GU_TEMPLATE/copier.yml" <<'EOF'
_min_copier_version: "9.4.0"
_subdirectory: template
project_name:
  type: str
  default: Guarded Update
use_foreman:
  type: bool
  default: false
use_coderabbit:
  type: bool
  default: false
use_codeql:
  type: bool
  default: false
codeql_languages:
  type: yaml
  default: []
EOF
cat >"$GU_TEMPLATE/template/.copier-answers.yml.jinja" <<'EOF'
{{ _copier_answers|to_nice_yaml -}}
EOF
mkdir -p "$GU_TEMPLATE/template/.vscode"
printf '%s\n' '.vscode/*' \
    '!.vscode/settings.json' \
    '!.vscode/legacy.json' >"$GU_TEMPLATE/template/.gitignore"
printf '%s\n' '{"setting":"baseline"}' \
    >"$GU_TEMPLATE/template/.vscode/settings.json"
printf '%s\n' '{"legacy":"baseline"}' \
    >"$GU_TEMPLATE/template/.vscode/legacy.json"
printf '%s\n' 'baseline' >"$GU_TEMPLATE/template/version.txt"
git_init "$GU_TEMPLATE"
git_commit_all "$GU_TEMPLATE" "baseline template"
GU_BASELINE="$(git -C "$GU_TEMPLATE" rev-parse HEAD)"
git -C "$GU_TEMPLATE" tag v1.0.0
copier copy --trust --defaults --vcs-ref=v1.0.0 \
    "$GU_TEMPLATE" "$GU_TARGET" >/dev/null
GU_CANONICAL_SOURCE=https://github.com/example/guarded-update
GU_CANONICAL_SOURCE="$GU_CANONICAL_SOURCE" \
    yq -i '._src_path = strenv(GU_CANONICAL_SOURCE)' \
    "$GU_TARGET/.copier-answers.yml"
mkdir -p "$GU_TARGET/.vscode"
printf '%s\n' '.vscode/*' >"$GU_TARGET/.gitignore"
printf '%s\n' '{"setting":"custom"}' >"$GU_TARGET/.vscode/settings.json"
printf '%s\n' '{"legacy":"custom"}' >"$GU_TARGET/.vscode/legacy.json"
git_init "$GU_TARGET"
git_commit_all "$GU_TARGET" "generated baseline"
GU_TARGET_REAL="$(cd "$GU_TARGET" && pwd -P)"

printf '%s\n' 'target' >"$GU_TEMPLATE/template/version.txt"
printf '%s\n' '.vscode/*' \
    '!.vscode/settings.json' \
    '!.vscode/new.json' \
    >"$GU_TEMPLATE/template/.gitignore"
printf '%s\n' '{"setting":"target"}' \
    >"$GU_TEMPLATE/template/.vscode/settings.json"
rm "$GU_TEMPLATE/template/.vscode/legacy.json"
printf '%s\n' '{"new":"target"}' \
    >"$GU_TEMPLATE/template/.vscode/new.json"
cat >>"$GU_TEMPLATE/copier.yml" <<'EOF'
use_codex_review:
  type: bool
  default: false
use_codex_cloud_review:
  type: bool
  default: false
  when: "{{ use_codex_review }}"
use_skills_sync:
  type: bool
  default: false
skill_categories:
  type: yaml
  default: []
deploy_preview:
  type: bool
  default: false
preview_region:
  type: str
  default: iad
  when: "{{ deploy_preview }}"
hidden_rollout:
  type: str
  default: internal
  when: false
EOF
git_commit_all "$GU_TEMPLATE" "target template"
GU_TARGET_COMMIT="$(git -C "$GU_TEMPLATE" rev-parse HEAD)"
git -C "$GU_TEMPLATE" tag v2.0.0
git clone --bare "$GU_TEMPLATE" "$GU_REMOTE" >/dev/null 2>&1
git -C "$GU_TEMPLATE" tag v9.9.9
git clone --no-local --no-checkout "$GU_REMOTE" "$GU_SNAPSHOT" >/dev/null 2>&1
git -C "$GU_SNAPSHOT" remote remove origin
expect_fail "guarded snapshot excludes local-only template tags" \
    git -C "$GU_SNAPSHOT" rev-parse --verify refs/tags/v9.9.9
printf '%s\n' '/.copier-guarded-update/' >>"$GU_TARGET/.git/info/exclude"
mkdir "$GU_TARGET/.copier-guarded-update"
git -C "$GU_TARGET" rev-parse HEAD \
    >"$GU_TARGET/.copier-guarded-update/start-head"
printf '%s\n' branch:main \
    >"$GU_TARGET/.copier-guarded-update/start-checkout"
git -C "$GU_TARGET" hash-object "$GU_TARGET/.copier-answers.yml" \
    >"$GU_TARGET/.copier-guarded-update/canonical-answers-oid"
printf '%s\n' "$GU_TARGET_COMMIT" \
    >"$GU_TARGET/.copier-guarded-update/target-commit"
printf '%s\n' "$GU_SNAPSHOT" \
    >"$GU_TARGET/.copier-guarded-update/template-path"
printf '%s\n' "$GU_CACHE" \
    >"$GU_TARGET/.copier-guarded-update/cache-path"
cp "$GU_TARGET/.copier-answers.yml" \
    "$GU_TARGET/.copier-guarded-update/original-answers.yml"
git -C "$GU_SNAPSHOT" show "$GU_BASELINE":copier.yml |
    yq -r 'keys | .[] | select(test("^_") | not)' |
    LC_ALL=C sort -u \
        >"$GU_TARGET/.copier-guarded-update/baseline-questions"
git -C "$GU_SNAPSHOT" show "$GU_TARGET_COMMIT":copier.yml |
    yq -r 'keys | .[] | select(test("^_") | not)' |
    LC_ALL=C sort -u \
        >"$GU_TARGET/.copier-guarded-update/target-questions"
comm -13 \
    "$GU_TARGET/.copier-guarded-update/baseline-questions" \
    "$GU_TARGET/.copier-guarded-update/target-questions" \
    >"$GU_TARGET/.copier-guarded-update/new-question-candidates"
GU_DISCOVERY="$TMPROOT/guarded-update-discovery"
yq 'with_entries(select(.key | test("^_") | not))' \
    "$GU_TARGET/.copier-guarded-update/original-answers.yml" \
    >"$GU_TARGET/.copier-guarded-update/discovery-data.yml"
copier copy --trust --defaults --skip-tasks \
    --vcs-ref="$GU_TARGET_COMMIT" \
    --data-file="$GU_TARGET/.copier-guarded-update/discovery-data.yml" \
    "$GU_SNAPSHOT" "$GU_DISCOVERY" >/dev/null
yq -r 'keys | .[] | select(test("^_") | not)' \
    "$GU_DISCOVERY/.copier-answers.yml" |
    LC_ALL=C sort -u \
        >"$GU_TARGET/.copier-guarded-update/active-target-questions"
comm -12 \
    "$GU_TARGET/.copier-guarded-update/new-question-candidates" \
    "$GU_TARGET/.copier-guarded-update/active-target-questions" \
    >"$GU_TARGET/.copier-guarded-update/active-new-questions"
{
    cat "$GU_TARGET/.copier-guarded-update/active-new-questions"
    printf '%s\n' use_foreman use_coderabbit use_codeql codeql_languages \
        use_codex_review use_skills_sync skill_categories
} |
    LC_ALL=C sort -u |
    comm -12 - \
        "$GU_TARGET/.copier-guarded-update/active-target-questions" \
        >"$GU_TARGET/.copier-guarded-update/reviewed-keys"
USE_FOREMAN=true USE_CODERABBIT=false USE_CODEQL=true \
    USE_CODEX_REVIEW=true USE_CODEX_CLOUD_REVIEW=true \
    USE_SKILLS_SYNC=true SKILL_CATEGORIES='["universal"]' \
    CODEQL_LANGUAGES='["javascript-typescript"]' DEPLOY_PREVIEW=true \
    yq -n -o=yaml \
    '{"use_foreman": (strenv(USE_FOREMAN) == "true"),
      "use_coderabbit": (strenv(USE_CODERABBIT) == "true"),
      "use_codeql": (strenv(USE_CODEQL) == "true"),
      "use_codex_review": (strenv(USE_CODEX_REVIEW) == "true"),
      "use_codex_cloud_review": (strenv(USE_CODEX_CLOUD_REVIEW) == "true"),
      "use_skills_sync": (strenv(USE_SKILLS_SYNC) == "true"),
      "skill_categories": (strenv(SKILL_CATEGORIES) | from_json),
      "codeql_languages": (strenv(CODEQL_LANGUAGES) | from_json),
      "deploy_preview": (strenv(DEPLOY_PREVIEW) == "true")}' \
    >"$GU_TARGET/.copier-guarded-update/reviewed-data.yml"
expect_fail "first discovery excludes a conditional question whose controller defaults off" \
    grep -qxF preview_region \
    "$GU_TARGET/.copier-guarded-update/active-target-questions"
yq eval-all \
    'select(fileIndex == 0) * select(fileIndex == 1)' \
    "$GU_TARGET/.copier-guarded-update/discovery-data.yml" \
    "$GU_TARGET/.copier-guarded-update/reviewed-data.yml" \
    >"$GU_TARGET/.copier-guarded-update/discovery-data.next.yml"
GU_DISCOVERY_SECOND="$TMPROOT/guarded-update-discovery-second"
copier copy --trust --defaults --skip-tasks \
    --vcs-ref="$GU_TARGET_COMMIT" \
    --data-file="$GU_TARGET/.copier-guarded-update/discovery-data.next.yml" \
    "$GU_SNAPSHOT" "$GU_DISCOVERY_SECOND" >/dev/null
yq -r 'keys | .[] | select(test("^_") | not)' \
    "$GU_DISCOVERY_SECOND/.copier-answers.yml" |
    LC_ALL=C sort -u \
        >"$GU_TARGET/.copier-guarded-update/active-target-questions"
comm -12 \
    "$GU_TARGET/.copier-guarded-update/new-question-candidates" \
    "$GU_TARGET/.copier-guarded-update/active-target-questions" \
    >"$GU_TARGET/.copier-guarded-update/active-new-questions"
{
    cat "$GU_TARGET/.copier-guarded-update/active-new-questions"
    printf '%s\n' use_foreman use_coderabbit use_codeql codeql_languages \
        use_codex_review use_skills_sync skill_categories
} |
    LC_ALL=C sort -u |
    comm -12 - \
        "$GU_TARGET/.copier-guarded-update/active-target-questions" \
        >"$GU_TARGET/.copier-guarded-update/reviewed-keys"
PREVIEW_REGION=ord yq -i \
    '.preview_region = strenv(PREVIEW_REGION)' \
    "$GU_TARGET/.copier-guarded-update/reviewed-data.yml"
find "$GU_DISCOVERY_SECOND" \( -type f -o -type l \) -print |
    sed "s#^$GU_DISCOVERY_SECOND/##" |
    LC_ALL=C sort -u \
        >"$GU_TARGET/.copier-guarded-update/target-managed-paths"
GU_BASELINE_DISCOVERY="$TMPROOT/guarded-update-baseline-discovery"
copier copy --trust --defaults --skip-tasks \
    --vcs-ref="$GU_BASELINE" \
    --data-file="$GU_TARGET/.copier-guarded-update/discovery-data.yml" \
    "$GU_SNAPSHOT" "$GU_BASELINE_DISCOVERY" >/dev/null
find "$GU_BASELINE_DISCOVERY" \( -type f -o -type l \) -print |
    sed "s#^$GU_BASELINE_DISCOVERY/##" |
    LC_ALL=C sort -u \
        >"$GU_TARGET/.copier-guarded-update/baseline-managed-paths"
cat \
    "$GU_TARGET/.copier-guarded-update/baseline-managed-paths" \
    "$GU_TARGET/.copier-guarded-update/target-managed-paths" |
    LC_ALL=C sort -u \
        >"$GU_TARGET/.copier-guarded-update/managed-paths"
git -C "$GU_TARGET" hash-object \
    "$GU_TARGET/.copier-guarded-update/reviewed-data.yml" \
    >"$GU_TARGET/.copier-guarded-update/reviewed-data-oid"
expect_ok "guarded review set derives every target-only Copier question" \
    sh -c 'grep -qxF deploy_preview "$1" &&
        grep -qxF preview_region "$1"' sh \
    "$GU_TARGET/.copier-guarded-update/active-new-questions"
expect_ok "second discovery activates a conditional question after controller review" \
    grep -qxF preview_region \
    "$GU_TARGET/.copier-guarded-update/active-target-questions"
cp "$GU_TARGET/.copier-guarded-update/reviewed-data.yml" \
    "$GU_TARGET/.copier-guarded-update/stale-reviewed-data.yml"
yq -i '.deploy_preview = false' \
    "$GU_TARGET/.copier-guarded-update/stale-reviewed-data.yml"
printf '%s\n' '{}' \
    >"$GU_TARGET/.copier-guarded-update/stale-active-reviewed.yml"
yq -r 'keys | .[] | select(test("^_") | not)' \
    "$GU_DISCOVERY/.copier-answers.yml" |
    LC_ALL=C sort -u |
    while IFS= read -r active_key; do
        if ACTIVE_KEY="$active_key" yq -e \
            'has(strenv(ACTIVE_KEY))' \
            "$GU_TARGET/.copier-guarded-update/stale-reviewed-data.yml" \
            >/dev/null; then
            ACTIVE_VALUE="$(
                ACTIVE_KEY="$active_key" yq -o=json -I=0 \
                    '.[strenv(ACTIVE_KEY)]' \
                    "$GU_TARGET/.copier-guarded-update/stale-reviewed-data.yml"
            )"
            ACTIVE_KEY="$active_key" ACTIVE_VALUE="$ACTIVE_VALUE" yq -i \
                '.[strenv(ACTIVE_KEY)] =
                    (strenv(ACTIVE_VALUE) | from_json)' \
                "$GU_TARGET/.copier-guarded-update/stale-active-reviewed.yml"
        fi
    done
yq eval-all \
    'select(fileIndex == 0) * select(fileIndex == 1)' \
    "$GU_TARGET/.copier-guarded-update/discovery-data.yml" \
    "$GU_TARGET/.copier-guarded-update/stale-active-reviewed.yml" \
    >"$GU_TARGET/.copier-guarded-update/stale-discovery-data.yml"
GU_DISCOVERY_STALE="$TMPROOT/guarded-update-discovery-stale"
copier copy --trust --defaults --skip-tasks \
    --vcs-ref="$GU_TARGET_COMMIT" \
    --data-file="$GU_TARGET/.copier-guarded-update/stale-discovery-data.yml" \
    "$GU_SNAPSHOT" "$GU_DISCOVERY_STALE" >/dev/null
expect_fail "fixed-point filtering drops stale values from newly inactive questions" \
    yq -e 'has("preview_region")' \
    "$GU_DISCOVERY_STALE/.copier-answers.yml"
expect_fail "guarded review set excludes hidden target-only questions" \
    grep -qxF hidden_rollout \
    "$GU_TARGET/.copier-guarded-update/reviewed-keys"
expect_ok "guarded review data covers every required reviewed question" \
    sh -c 'while IFS= read -r key; do
        KEY="$key" yq -e "has(strenv(KEY))" "$1" >/dev/null || exit 1
    done <"$2"' sh \
    "$GU_TARGET/.copier-guarded-update/reviewed-data.yml" \
    "$GU_TARGET/.copier-guarded-update/reviewed-keys"
expect_ok "guarded update carries valid Codex classifier prerequisites" \
    sh -c 'test "$(yq -r ".use_codex_cloud_review" "$1")" = true &&
        test "$(yq -r ".use_codex_review" "$1")" = true &&
        test "$(yq -r ".use_skills_sync" "$1")" = true &&
        yq -e ".skill_categories | contains([\"universal\"])" "$1" \
            >/dev/null' sh \
    "$GU_TARGET/.copier-guarded-update/reviewed-data.yml"
while IFS= read -r managed_path; do
    if git -C "$GU_TARGET" check-ignore -q -- "$managed_path"; then
        printf '%s\n' "$managed_path"
    fi
done <"$GU_TARGET/.copier-guarded-update/managed-paths" \
    >"$GU_TARGET/.copier-guarded-update/ignored-managed-paths"
: >"$GU_TARGET/.copier-guarded-update/ignored-absent-paths"
: >"$GU_TARGET/.copier-guarded-update/ignored-existing-paths"
while IFS= read -r ignored_path; do
    if test -e "$GU_TARGET/$ignored_path" ||
        test -L "$GU_TARGET/$ignored_path"; then
        printf '%s\n' "$ignored_path" \
            >>"$GU_TARGET/.copier-guarded-update/ignored-existing-paths"
    else
        printf '%s\n' "$ignored_path" \
            >>"$GU_TARGET/.copier-guarded-update/ignored-absent-paths"
    fi
done <"$GU_TARGET/.copier-guarded-update/ignored-managed-paths"
tar -C "$GU_TARGET" \
    -cf "$GU_TARGET/.copier-guarded-update/ignored-backup.tar" \
    -T "$GU_TARGET/.copier-guarded-update/ignored-existing-paths"
git -C "$GU_TARGET" hash-object \
    "$GU_TARGET/.copier-guarded-update/ignored-backup.tar" \
    >"$GU_TARGET/.copier-guarded-update/ignored-backup-oid"
git -C "$GU_TARGET" hash-object \
    "$GU_TARGET/.copier-guarded-update/ignored-managed-paths" \
    >"$GU_TARGET/.copier-guarded-update/ignored-managed-paths-oid"
printf '%s\n' ready \
    >"$GU_TARGET/.copier-guarded-update/ignored-snapshot-ready"
expect_ok "guarded ignored backup is derived from the task-free target render" \
    grep -qxF .vscode/settings.json \
    "$GU_TARGET/.copier-guarded-update/ignored-managed-paths"
expect_ok "guarded ignored backup includes baseline-only existing paths" \
    grep -qxF .vscode/legacy.json \
    "$GU_TARGET/.copier-guarded-update/ignored-existing-paths"
expect_ok "guarded ignored backup records target-only absent paths" \
    grep -qxF .vscode/new.json \
    "$GU_TARGET/.copier-guarded-update/ignored-absent-paths"
chmod -R a-w "$GU_SNAPSHOT"

# Move the original mutable tag after the guarded snapshot exists. Copier 9.16
# re-describes the baseline internally, so this proves its nested clone resolves
# against the frozen local tag mapping instead of the changed source repository.
git --git-dir="$GU_REMOTE" tag -f v1.0.0 "$GU_TARGET_COMMIT" >/dev/null
git -C "$GU_TARGET" switch -c guarded-wrong-branch >/dev/null
expect_fail "guarded update state rejects another branch at the same HEAD" \
    sh -c 'test "$(cat "$1/.copier-guarded-update/start-checkout")" = \
        "branch:$(git -C "$1" symbolic-ref --quiet --short HEAD)"' sh \
    "$GU_TARGET"
git -C "$GU_TARGET" switch main >/dev/null
printf '%s\n' intervening >"$GU_TARGET/intervening.txt"
expect_fail "guarded apply rejects intervening untracked worktree changes" \
    sh -c 'test -z "$(git -C "$1" status --porcelain)"' sh "$GU_TARGET"
rm "$GU_TARGET/intervening.txt"
tar -C "$GU_TARGET" \
    -cf "$GU_TARGET/.copier-guarded-update/ignored-preapply.tar" \
    -T "$GU_TARGET/.copier-guarded-update/ignored-existing-paths"
expect_ok "guarded apply verifies ignored managed paths before mutation" \
    sh -c 'test "$(git -C "$1" hash-object \
            "$1/.copier-guarded-update/ignored-preapply.tar")" = \
        "$(cat "$1/.copier-guarded-update/ignored-backup-oid")"' sh \
    "$GU_TARGET"
rm "$GU_TARGET/.copier-guarded-update/ignored-preapply.tar"
GU_APPLY_PHASE_CANDIDATE="$GU_TARGET/.copier-guarded-update/apply-phase.candidate"
printf '%s\n' applying >"$GU_APPLY_PHASE_CANDIDATE"
mv "$GU_APPLY_PHASE_CANDIDATE" \
    "$GU_TARGET/.copier-guarded-update/apply-phase"
expect_ok "guarded Copier update survives a source release retag" \
    env \
    "COPIER_CACHE_DIR=$GU_CACHE" \
    GIT_CONFIG_COUNT=2 \
    "GIT_CONFIG_KEY_0=url.$GU_SNAPSHOT.insteadOf" \
    "GIT_CONFIG_VALUE_0=$GU_CANONICAL_SOURCE.git" \
    "GIT_CONFIG_KEY_1=url.$GU_SNAPSHOT.insteadOf" \
    "GIT_CONFIG_VALUE_1=$GU_CANONICAL_SOURCE" \
    copier update --trust --defaults \
    --vcs-ref="$GU_TARGET_COMMIT" \
    --data-file="$GU_TARGET_REAL/.copier-guarded-update/reviewed-data.yml" \
    "$GU_TARGET_REAL"
expect_ok "guarded recovery retains write-ahead applying state after a crash window" \
    grep -qxF applying "$GU_TARGET/.copier-guarded-update/apply-phase"
expect_fail "guarded recovery never promotes an ambiguous applying state" \
    sh -c 'case "$(cat "$1/.copier-guarded-update/apply-phase")" in
        applied) exit 0 ;;
        applying) exit 1 ;;
        *) exit 2 ;;
    esac' sh "$GU_TARGET"
printf '%s\n' applied >"$GU_TARGET/.copier-guarded-update/apply-phase"
expect_ok "guarded Copier update applies the intended target content" \
    grep -qxF target "$GU_TARGET/version.txt"
if git -C "$GU_TARGET" diff --name-only --diff-filter=U |
    grep -qxF .gitignore; then
    printf '%s\n' '.vscode/*' \
        '!.vscode/settings.json' \
        '!.vscode/new.json' >"$GU_TARGET/.gitignore"
    git -C "$GU_TARGET" add -- .gitignore
fi
expect_ok "guarded Copier update leaves canonical answers conflict-free" \
    sh -c 'yq -e "." "$1/.copier-answers.yml" >/dev/null &&
        test -z "$(git -C "$1" diff --name-only --diff-filter=U)"' sh \
    "$GU_TARGET"
GU_APPLIED_REF="$(
    yq -r '._commit // ""' "$GU_TARGET/.copier-answers.yml"
)"
GU_APPLIED_COMMIT="$(
    git -C "$GU_SNAPSHOT" rev-parse "$GU_APPLIED_REF^{commit}"
)"
expect_ok "guarded Copier update records the validated applied target" \
    test "$GU_APPLIED_COMMIT" = "$GU_TARGET_COMMIT"
expect_ok "guarded Copier update retains the canonical source URL" \
    test "$(yq -r '._src_path' "$GU_TARGET/.copier-answers.yml")" = \
    "$GU_CANONICAL_SOURCE"
expect_ok "guarded update state remains bound to checkout and original answers" \
    sh -c 'test "$(cat "$1/.copier-guarded-update/start-head")" = \
            "$(git -C "$1" rev-parse HEAD)" &&
        test "$(cat "$1/.copier-guarded-update/canonical-answers-oid")" = \
            "$(git -C "$1" hash-object \
                "$1/.copier-guarded-update/original-answers.yml")"' sh \
    "$GU_TARGET"
expect_ok "guarded Copier update applies the exact reviewed answers" \
    sh -c 'test "$(yq -r ".use_foreman" "$1/.copier-answers.yml")" = true &&
        test "$(yq -r ".use_coderabbit" "$1/.copier-answers.yml")" = false &&
        test "$(yq -r ".use_codeql" "$1/.copier-answers.yml")" = true &&
        test "$(yq -r ".use_codex_review" "$1/.copier-answers.yml")" = true &&
        test "$(yq -r ".use_codex_cloud_review" "$1/.copier-answers.yml")" = true &&
        test "$(yq -r ".use_skills_sync" "$1/.copier-answers.yml")" = true &&
        test "$(yq -o=json -I=0 ".skill_categories" \
            "$1/.copier-answers.yml")" = "[\"universal\"]" &&
        test "$(yq -o=json -I=0 ".codeql_languages" \
            "$1/.copier-answers.yml")" = "[\"javascript-typescript\"]" &&
        test "$(yq -r ".deploy_preview" "$1/.copier-answers.yml")" = true &&
        test "$(yq -r ".preview_region" "$1/.copier-answers.yml")" = ord &&
        ! yq -e "has(\"hidden_rollout\")" "$1/.copier-answers.yml" \
            >/dev/null' sh \
    "$GU_TARGET"
expect_ok "guarded recovery validates every reviewed answer before promotion" \
    sh -c 'while IFS= read -r key; do
        KEY="$key" yq -e "has(strenv(KEY))" "$1/.copier-answers.yml" \
            >/dev/null || exit 1
        actual="$(KEY="$key" yq -o=json -I=0 \
            ".[strenv(KEY)]" "$1/.copier-answers.yml")"
        expected="$(KEY="$key" yq -o=json -I=0 \
            ".[strenv(KEY)]" "$1/.copier-guarded-update/reviewed-data.yml")"
        test "$actual" = "$expected" || exit 1
    done <"$1/.copier-guarded-update/reviewed-keys"' sh \
    "$GU_TARGET"
printf '%s\n' '{"setting":"interrupted"}' >"$GU_TARGET/.vscode/settings.json"
while IFS= read -r absent_ignored_path; do
    rm -f "$GU_TARGET/$absent_ignored_path"
done <"$GU_TARGET/.copier-guarded-update/ignored-absent-paths"
tar -C "$GU_TARGET" \
    -xf "$GU_TARGET/.copier-guarded-update/ignored-backup.tar"
tar -C "$GU_TARGET" \
    -cf "$GU_TARGET/.copier-guarded-update/ignored-verify.tar" \
    -T "$GU_TARGET/.copier-guarded-update/ignored-existing-paths"
expect_ok "guarded rollback restores and verifies ignored managed files" \
    sh -c 'grep -qxF "{\"setting\":\"custom\"}" \
            "$1/.vscode/settings.json" &&
        grep -qxF "{\"legacy\":\"custom\"}" \
            "$1/.vscode/legacy.json" &&
        test ! -e "$1/.vscode/new.json" &&
        test "$(git -C "$1" hash-object \
            "$1/.copier-guarded-update/ignored-verify.tar")" = \
        "$(cat "$1/.copier-guarded-update/ignored-backup-oid")"' sh \
    "$GU_TARGET"
rm "$GU_TARGET/.copier-guarded-update/ignored-verify.tar"
expect_fail "guarded Copier update state refuses a concurrent or blind retry" \
    mkdir "$GU_TARGET/.copier-guarded-update"
git -C "$GU_TARGET" add -A
GU_PROMOTED_ANSWERS="$GU_TARGET/.copier-answers.yml.promote"
cp "$GU_TARGET/.copier-answers.yml" "$GU_PROMOTED_ANSWERS"
GU_CANONICAL_SOURCE="$GU_CANONICAL_SOURCE" \
    GU_TARGET_COMMIT="$GU_TARGET_COMMIT" \
    yq -i \
    '._src_path = strenv(GU_CANONICAL_SOURCE) |
     ._commit = strenv(GU_TARGET_COMMIT)' \
    "$GU_PROMOTED_ANSWERS"
mv "$GU_PROMOTED_ANSWERS" "$GU_TARGET/.copier-answers.yml"
git -C "$GU_TARGET" add -- .copier-answers.yml
expect_ok "promoted full-hash answers replace the staged tag lineage" \
    sh -c 'git -C "$1" show :.copier-answers.yml |
        EXPECTED_COMMIT="$2" yq -e "._commit == strenv(EXPECTED_COMMIT)" - \
            >/dev/null' sh \
    "$GU_TARGET" "$GU_TARGET_COMMIT"
chmod -R u+w "$GU_SNAPSHOT"

RB_TARGET="$TMPROOT/guarded-rollback-target"
mkdir -p "$RB_TARGET"
git_init "$RB_TARGET"
printf '%s\n' staged-original >"$RB_TARGET/staged.txt"
printf '%s\n' unstaged-original >"$RB_TARGET/unstaged.txt"
git_commit_all "$RB_TARGET" "rollback baseline"
printf '%s\n' '/.copier-guarded-update/' >>"$RB_TARGET/.git/info/exclude"
mkdir "$RB_TARGET/.copier-guarded-update"
git -C "$RB_TARGET" rev-parse HEAD \
    >"$RB_TARGET/.copier-guarded-update/start-head"
printf '%s\n' staged-change >"$RB_TARGET/staged.txt"
git -C "$RB_TARGET" add -- staged.txt
printf '%s\n' unstaged-change >"$RB_TARGET/unstaged.txt"
printf '%s\n' untracked-change >"$RB_TARGET/untracked.txt"
expect_ok "rollback preview includes staged and unstaged tracked changes" \
    sh -c 'git -C "$1" diff HEAD --stat | grep -qF staged.txt &&
        git -C "$1" diff HEAD --stat | grep -qF unstaged.txt' sh \
    "$RB_TARGET"
expect_ok "rollback preview includes untracked removal candidates" \
    sh -c 'git -C "$1" clean -nd | grep -qF untracked.txt' sh \
    "$RB_TARGET"
git -C "$RB_TARGET" restore \
    --source="$(
        cat "$RB_TARGET/.copier-guarded-update/start-head"
    )" \
    --staged --worktree -- .
git -C "$RB_TARGET" clean -fd >/dev/null
expect_ok "guarded rollback restores staged, unstaged, and untracked state" \
    sh -c 'test "$(cat "$1/staged.txt")" = staged-original &&
        test "$(cat "$1/unstaged.txt")" = unstaged-original &&
        test ! -e "$1/untracked.txt" &&
        test -z "$(git -C "$1" status --porcelain)"' sh \
    "$RB_TARGET"

WT_REPO="$TMPROOT/guarded-answers-worktree-repo"
WT_TARGET="$TMPROOT/guarded-answers-linked-worktree"
mkdir -p "$WT_REPO"
git_init "$WT_REPO"
printf '%s\n' tracked >"$WT_REPO/tracked.txt"
git_commit_all "$WT_REPO" "linked worktree fixture"
git -C "$WT_REPO" worktree add -b guarded-answers-test "$WT_TARGET" >/dev/null
WT_EXCLUDE="$(
    git -C "$WT_TARGET" rev-parse --path-format=absolute --git-path info/exclude
)"
printf '%s\n' '/.copier-guarded-update/' >>"$WT_EXCLUDE"
mkdir "$WT_TARGET/.copier-guarded-update"
printf '%s\n' guarded >"$WT_TARGET/.copier-guarded-update/original-answers.yml"
expect_ok "guarded recovery state remains untracked in a linked worktree" \
    test -z "$(git -C "$WT_TARGET" status --porcelain)"

echo ""
echo "skills tooling tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
