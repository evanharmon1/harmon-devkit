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

echo "==> portable skill layout"
expect_ok "skills-sync example preserves the Claude-first migration-safe destination" \
    grep -q '^dest: \.claude/skills' "$repo/templates/skills-sync/.skills-sync.yaml"
expect_ok "Claude compatibility path is a symlink" \
    test -L "$repo/.claude/skills"
expect_ok "Claude compatibility path targets the portable skill tree" \
    test "$(readlink "$repo/.claude/skills")" = "../.agents/skills"
expect_ok "portable dogfood tree exposes the implement skill" \
    test -f "$repo/.agents/skills/implement/SKILL.md"
expect_ok "label registry support stays visible to legacy category sync" \
    test -f "$repo/ai/skills/universal/label-registry-support/SKILL.md"
expect_ok "label registry support stays out of the slash-command menu" \
    grep -q '^user-invocable: false$' \
    "$repo/ai/skills/universal/label-registry-support/SKILL.md"
expect_ok "skills-sync compatibility step recognizes its directory symlink" \
    grep -qF 'readlink .agents/skills)" = "../.claude/skills"' \
    "$repo/templates/skills-sync/README.md"
expect_ok "skills-sync compatibility step rejects other directory symlinks" \
    grep -qF 'elif [ -L .agents/skills ]; then' \
    "$repo/templates/skills-sync/README.md"
expect_ok "skills-sync compatibility step skips an unmatched skill glob" \
    grep -qF '[ -d "$skill" ] || continue' \
    "$repo/templates/skills-sync/README.md"
expect_ok "track-work pre-approves portable asset paths" \
    grep -qF 'Bash(./.agents/skills/track-work/assets/check-issue-rot.sh:*)' \
    "$repo/ai/skills/universal/track-work/SKILL.md"
expect_ok "track-work defines the canonical scoped issue-title contract" \
    grep -qF '(<scope>): <imperative problem/outcome' \
    "$repo/ai/skills/universal/track-work/SKILL.md"
expect_ok "cross-repo filing runs the full pre-create contract" \
    grep -qF 'check-issue-metadata.sh' \
    "$repo/ai/skills/universal/track-work/references/cross-repo-work.md"
expect_ok "breakdown applies scoped titles to every issue shape" \
    grep -qF 'every parent, child, and flat issue uses' \
    "$repo/ai/skills/universal/breakdown/SKILL.md"
expect_ok "triage owns a canonical scoped rolling-report title" \
    grep -qF "DEFAULT_TITLE='(triage): Track backlog findings'" \
    "$repo/ai/skills/universal/triage/assets/triage-report.sh"
expect_ok "the configured GitHub tracker requires scoped issue titles" \
    grep -qF '(<free-form scope>): <imperative outcome>' \
    "$repo/ai/skills/matt-pocock/setup-matt-pocock-skills/issue-tracker-github.md"
expect_ok "the Matt Pocock selection includes user-facing grill-me" \
    test -f "$repo/ai/skills/matt-pocock/grill-me/SKILL.md"
expect_ok "grill-me declares its grilling dependency" \
    grep -qF 'the `grilling` skill' "$repo/ai/skills/matt-pocock/grill-me/SKILL.md"
for matt_provenance in "$repo"/ai/skills/matt-pocock/*/UPSTREAM.md; do
    matt_skill="$(basename "$(dirname "$matt_provenance")")"
    expect_ok "$matt_skill provenance pins the current upstream import" \
        grep -qF 'Imported commit: `6654f6b60cd9d5be8b54c6fafe44346dabeb3b76`' \
        "$matt_provenance"
done

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

# An UNCLOSED frontmatter block fails. Both parsers scan only the opening block,
# so without an explicit check this reads as valid here while a real YAML
# frontmatter parser sees no frontmatter at all.
G6="$TMPROOT/guard-unclosed"
git_init "$G6"
mkdir -p "$G6/ai/skills/frontend/golf"
{
    echo "---"
    echo "name: golf"
    echo "description: A skill whose frontmatter is never closed."
    echo ""
    echo "# golf"
} >"$G6/ai/skills/frontend/golf/SKILL.md"
expect_fail_contains "unclosed frontmatter fails" "frontmatter block is never closed" \
    bash -c "cd '$G6' && bash '$SCRIPTS/verify-skills.sh'"

# Mismatched quotes around the name fail. Trimming each delimiter independently
# would reduce `"hotel'` to `hotel` and match the directory, while a YAML loader
# rejects the scalar outright and the skill never loads.
G7="$TMPROOT/guard-badquote"
git_init "$G7"
mkdir -p "$G7/ai/skills/frontend/hotel"
{
    echo "---"
    printf 'name: "hotel%s\n' "'"
    echo "description: A skill whose name has mismatched quotes."
    echo "---"
    echo "# hotel"
} >"$G7/ai/skills/frontend/hotel/SKILL.md"
expect_fail_contains "mismatched-quote skill name fails" "mismatched quotes" \
    bash -c "cd '$G7' && bash '$SCRIPTS/verify-skills.sh'"

# A properly quoted name still passes.
G8="$TMPROOT/guard-quoted"
git_init "$G8"
mkdir -p "$G8/ai/skills/frontend/india"
{
    echo "---"
    echo 'name: "india"'
    echo "description: A skill whose name is double-quoted."
    echo "---"
    echo "# india"
} >"$G8/ai/skills/frontend/india/SKILL.md"
expect_ok "matched double-quoted skill name passes" \
    bash -c "cd '$G8' && bash '$SCRIPTS/verify-skills.sh'"

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

# ── sync-skills.sh agents pass ─────────────────────────────────────────
echo "==> sync-skills.sh (agents)"

# Add agents to the source repo at a new tag. README.md documents the directory
# and must never be vendored as an agent.
mkdir -p "$SRC/ai/agents"
mkagent() {
    {
        echo "---"
        echo "name: $2"
        echo "description: A test agent named $2."
        echo "---"
        echo ""
        echo "# $2"
    } >"$1/ai/agents/$2.md"
}
mkagent "$SRC" ag-one
mkagent "$SRC" ag-two
echo "# Agents" >"$SRC/ai/agents/README.md"
git_commit_all "$SRC" "add agents"
git -C "$SRC" tag v0.1.0-agents

# write_agents_manifest_at DIR REF NAMES_YAML [DEST]
write_agents_manifest_at() {
    local dir="$1" ref="$2" names="$3" adest="${4:-vendored/agents}"
    {
        echo "source:"
        echo "  repo: file://$SRC"
        echo "  ref: $ref"
        echo "categories:"
        echo "  - universal"
        echo "dest: vendored/skills"
        echo "agents:"
        echo "  names: $names"
        echo "  dest: $adest"
    } >"$dir/.skills-sync.yaml"
}

# --- a manifest with NO agents block is untouched by any of this ---------
CN="$TMPROOT/consumer-noagents"
mkdir -p "$CN"
write_manifest_at "$CN" v0.1.0-agents universal
expect_ok "no agents block: sync still succeeds" run_sync_at "$CN" sync
expect_ok "no agents block: nothing vendored to an agents dest" test ! -e "$CN/vendored/agents"
expect_ok "no agents block: verify passes" run_sync_at "$CN" verify
expect_ok "no agents block: verify-offline passes" run_sync_at "$CN" verify-offline

# --- explicit name list --------------------------------------------------
CA="$TMPROOT/consumer-agents"
mkdir -p "$CA"
write_agents_manifest_at "$CA" v0.1.0-agents "[ag-one]"
expect_ok "agents: verify skips cleanly before first sync" run_sync_at "$CA" verify
expect_ok "agents: sync vendors the named agent" run_sync_at "$CA" sync
aprov="$CA/vendored/agents/.AGENTS_PROVENANCE"
expect_ok "named agent vendored flat" test -f "$CA/vendored/agents/ag-one.md"
expect_ok "unnamed agent not vendored" test ! -e "$CA/vendored/agents/ag-two.md"
expect_ok "agents provenance records the ref" grep -q "^# ref: v0.1.0-agents " "$aprov"
expect_ok "agents provenance lists the managed set" grep -q "^# managed: ag-one$" "$aprov"
expect_ok "agents provenance carries do-not-edit marker" grep -q "DO NOT EDIT" "$aprov"
expect_ok "skills still vendored alongside agents" test -f "$CA/vendored/skills/uni-one/SKILL.md"
expect_ok "agents: verify passes right after sync" run_sync_at "$CA" verify
expect_ok "agents: verify-offline passes right after sync" run_sync_at "$CA" verify-offline

# Tamper -> drift, then re-sync heals.
echo "tampered" >>"$CA/vendored/agents/ag-one.md"
expect_fail "agents: verify detects a hand-edited vendored agent" run_sync_at "$CA" verify
expect_ok "agents: re-sync heals the drift" run_sync_at "$CA" sync
expect_ok "agents: verify passes again after re-sync" run_sync_at "$CA" verify

# A local (unmanaged) agent is never touched or reported.
echo "# local agent" >"$CA/vendored/agents/local-only.md"
expect_ok "local agent survives a re-sync" bash -c "
    cd '$CA' && bash '$SCRIPTS/sync-skills.sh' sync >/dev/null && test -f vendored/agents/local-only.md"
expect_ok "agents: verify ignores a local agent" run_sync_at "$CA" verify

# A local agent whose name collides with an incoming one is refused BEFORE any
# delete — the local file must still be there afterwards.
echo "# my own ag-two" >"$CA/vendored/agents/ag-two.md"
write_agents_manifest_at "$CA" v0.1.0-agents "[ag-one, ag-two]"
expect_fail_contains "collision with a local agent is refused" "collides with an incoming vendored agent" \
    run_sync_at "$CA" sync
expect_ok "refused collision left the local agent intact" \
    grep -q "my own ag-two" "$CA/vendored/agents/ag-two.md"
expect_ok "refused collision left the managed agent intact" test -f "$CA/vendored/agents/ag-one.md"
rm -f "$CA/vendored/agents/ag-two.md" "$CA/vendored/agents/local-only.md"

# Dropping a name from the manifest cleans up what the sync owns.
write_agents_manifest_at "$CA" v0.1.0-agents "[ag-two]"
expect_ok "agents: re-sync after a name swap" run_sync_at "$CA" sync
expect_ok "swapped-out agent removed" test ! -e "$CA/vendored/agents/ag-one.md"
expect_ok "swapped-in agent vendored" test -f "$CA/vendored/agents/ag-two.md"

# --- wildcard ------------------------------------------------------------
CW="$TMPROOT/consumer-agents-star"
mkdir -p "$CW"
write_agents_manifest_at "$CW" v0.1.0-agents '["*"]'
expect_ok "wildcard: sync succeeds" run_sync_at "$CW" sync
expect_ok "wildcard vendors every agent (1/2)" test -f "$CW/vendored/agents/ag-one.md"
expect_ok "wildcard vendors every agent (2/2)" test -f "$CW/vendored/agents/ag-two.md"
expect_ok "wildcard never vendors README.md" test ! -e "$CW/vendored/agents/README.md"
expect_ok "wildcard: verify passes" run_sync_at "$CW" verify

# The wildcard is all-or-nothing: mixing it with explicit names is a manifest
# error, not a silent union.
write_agents_manifest_at "$CW" v0.1.0-agents '["*", ag-one]'
expect_fail_contains "wildcard mixed with explicit names is refused" \
    "not both" run_sync_at "$CW" sync

# --- manifest errors -----------------------------------------------------
CE="$TMPROOT/consumer-agents-err"
mkdir -p "$CE"
write_agents_manifest_at "$CE" v0.1.0-agents "[nope]"
expect_fail_contains "a missing agent name fails clearly" "missing in the pinned source" \
    run_sync_at "$CE" sync

write_agents_manifest_at "$CE" v0.1.0-agents "[README]"
expect_fail_contains "README is refused as an agent name" "not an agent" run_sync_at "$CE" sync

write_agents_manifest_at "$CE" v0.1.0-agents "[ag-one]" "vendored/skills"
expect_fail_contains "agents.dest sharing the skills dest is refused" "each pass owns its own directory" \
    run_sync_at "$CE" sync

for bad in "/etc/agents" "//etc//agents" "/" "../outside" "./../outside" "vendored/../../outside"; do
    write_agents_manifest_at "$CE" v0.1.0-agents "[ag-one]" "$bad"
    expect_fail "agents: sync refuses unsafe dest '$bad'" run_sync_at "$CE" sync
done

# An unsafe agents dest is caught BEFORE the skills pass deletes anything —
# a manifest that cannot complete must not half-apply.
CH="$TMPROOT/consumer-agents-halt"
mkdir -p "$CH"
write_agents_manifest_at "$CH" v0.1.0-agents "[ag-one]"
run_sync_at "$CH" sync >/dev/null
write_agents_manifest_at "$CH" v0.1.0-agents "[ag-one]" "/etc/agents"
expect_fail "agents: bad dest aborts the whole sync" run_sync_at "$CH" sync
expect_ok "aborted sync left the skills pass untouched" test -f "$CH/vendored/skills/uni-one/SKILL.md"

# --- de-vendoring: removing the agents block must not strand the files ----
# A vendoring tool needs an un-vendoring path. `agents.dest` lives INSIDE the
# optional block, so deleting the block also deletes the only record of where
# the agents went — hence the `# agents-dest:` breadcrumb on the skills stamp.
CD2="$TMPROOT/consumer-agents-devendor"
mkdir -p "$CD2"
write_agents_manifest_at "$CD2" v0.1.0-agents "[ag-one]"
run_sync_at "$CD2" sync >/dev/null
expect_ok "de-vendor: agent vendored to begin with" test -f "$CD2/vendored/agents/ag-one.md"
expect_ok "de-vendor: skills stamp records the agents dest" \
    grep -q "^# agents-dest: vendored/agents$" "$CD2/vendored/skills/.SKILLS_PROVENANCE"
# A local agent in the same directory must survive the de-vendor.
echo "# local, keep me" >"$CD2/vendored/agents/mine.md"

# Drop the agents block entirely.
write_manifest_at "$CD2" v0.1.0-agents universal
expect_fail_contains "de-vendor: verify flags agents left behind" \
    "no longer requests them" run_sync_at "$CD2" verify
expect_ok "de-vendor: sync removes them" run_sync_at "$CD2" sync
expect_ok "de-vendor: managed agent gone" test ! -e "$CD2/vendored/agents/ag-one.md"
expect_ok "de-vendor: agents stamp gone" test ! -e "$CD2/vendored/agents/.AGENTS_PROVENANCE"
expect_ok "de-vendor: LOCAL agent survived" grep -q "keep me" "$CD2/vendored/agents/mine.md"
expect_ok "de-vendor: verify passes afterwards" run_sync_at "$CD2" verify
expect_ok "de-vendor: breadcrumb cleared from the skills stamp" \
    grep -q "^# agents-dest:$" "$CD2/vendored/skills/.SKILLS_PROVENANCE"
# Idempotent: a second sync with no block has nothing left to remove.
expect_ok "de-vendor: repeat sync is a no-op" run_sync_at "$CD2" sync

# A repo that NEVER had agents is unaffected by any of this.
CD3="$TMPROOT/consumer-never-agents"
mkdir -p "$CD3"
write_manifest_at "$CD3" v0.1.0-agents universal
expect_ok "never-agents: sync succeeds" run_sync_at "$CD3" sync
expect_ok "never-agents: empty breadcrumb written" \
    grep -q "^# agents-dest:$" "$CD3/vendored/skills/.SKILLS_PROVENANCE"
expect_ok "never-agents: verify passes" run_sync_at "$CD3" verify

# --- overlapping dests are refused, not just identical ones ---------------
# The skills pass does `rm -rf` on a managed skill directory, so an agents dest
# nested inside one is destroyed wholesale on every sync — stamp, managed
# agents, and any local agent parked there.
CV="$TMPROOT/consumer-agents-overlap"
mkdir -p "$CV"
write_agents_manifest_at "$CV" v0.1.0-agents "[ag-one]" "vendored/skills/uni-one"
expect_fail_contains "agents.dest nested inside the skills dest is refused" \
    "live inside it" run_sync_at "$CV" sync
write_agents_manifest_at "$CV" v0.1.0-agents "[ag-one]" "vendored"
expect_fail_contains "skills dest nested inside agents.dest is refused" \
    "lives inside agents.dest" run_sync_at "$CV" sync
# A trailing slash must not spell the same directory a second way past the check.
write_agents_manifest_at "$CV" v0.1.0-agents "[ag-one]" "vendored/skills/"
expect_fail_contains "a trailing slash cannot alias past the overlap check" \
    "each pass owns its own directory" run_sync_at "$CV" sync
# Path ALIASES must not slip past either. `./x`, `x//y` and `x/./y` name the
# same directory as `x/y`, and a string compare only caught some of them.
for alias in "./vendored/skills/uni-one" "vendored//skills/uni-one" "vendored/./skills/uni-one" "./vendored/skills"; do
    write_agents_manifest_at "$CV" v0.1.0-agents "[ag-one]" "$alias"
    expect_fail_contains "overlap alias '$alias' is refused" \
        "each pass owns its own directory" run_sync_at "$CV" sync
done

# Sibling directories remain fine, including when spelled with an alias.
write_agents_manifest_at "$CV" v0.1.0-agents "[ag-one]" "vendored/agents"
expect_ok "sibling dests are still accepted" run_sync_at "$CV" sync
write_agents_manifest_at "$CV" v0.1.0-agents "[ag-one]" "./vendored/agents/"
expect_ok "an aliased sibling dest is still accepted" run_sync_at "$CV" sync
expect_ok "the aliased sibling vendored normally" test -f "$CV/vendored/agents/ag-one.md"
# ...and normalization must not make an aliased spelling look like a moved dest.
expect_ok "an aliased spelling is not mistaken for a dest change" run_sync_at "$CV" verify

# --- moving agents.dest must not strand the old location ------------------
# Same stranding bug as removing the block, one variant over: without this the
# pass vendors into the new dest, leaves the old one untouched, and both verify
# modes inspect only the new one and pass.
CW2="$TMPROOT/consumer-agents-moved"
mkdir -p "$CW2"
write_agents_manifest_at "$CW2" v0.1.0-agents "[ag-one]" "vendored/agents-a"
run_sync_at "$CW2" sync >/dev/null
echo "# local, keep me" >"$CW2/vendored/agents-a/mine.md"
write_agents_manifest_at "$CW2" v0.1.0-agents "[ag-one]" "vendored/agents-b"
expect_fail_contains "verify flags agents left at the old dest" \
    "agents.dest is now" run_sync_at "$CW2" verify
expect_fail_contains "offline check flags agents left at the old dest" \
    "no longer points there" run_sync_at "$CW2" verify-offline
expect_ok "sync migrates the dest" run_sync_at "$CW2" sync
expect_ok "old dest's managed agent removed" test ! -e "$CW2/vendored/agents-a/ag-one.md"
expect_ok "old dest's stamp removed" test ! -e "$CW2/vendored/agents-a/.AGENTS_PROVENANCE"
expect_ok "old dest's LOCAL agent survived the move" grep -q "keep me" "$CW2/vendored/agents-a/mine.md"
expect_ok "new dest has the agent" test -f "$CW2/vendored/agents-b/ag-one.md"
expect_ok "verify passes after the move" run_sync_at "$CW2" verify
expect_ok "offline check passes after the move" run_sync_at "$CW2" verify-offline

# --- offline check must see a removed block too ---------------------------
# cmd_verify caught this already; an asymmetry would have the pre-push hook wave
# through exactly what CI then rejects.
CY="$TMPROOT/consumer-agents-offline-orphan"
mkdir -p "$CY"
write_agents_manifest_at "$CY" v0.1.0-agents "[ag-one]"
run_sync_at "$CY" sync >/dev/null
write_manifest_at "$CY" v0.1.0-agents universal
expect_fail_contains "offline check flags a removed block's leftovers" \
    "no longer points there" run_sync_at "$CY" verify-offline
expect_ok "sync de-vendors them" run_sync_at "$CY" sync
expect_ok "offline check passes after de-vendoring" run_sync_at "$CY" verify-offline

# --- a damaged orphan stamp must abort BEFORE the breadcrumb is cleared ----
# devendor_agents runs after the skills stamp is rewritten with an empty
# breadcrumb. A stamp problem discovered there would abort with the pointer
# already erased, making the orphan permanently unfindable while checks pass.
CQ="$TMPROOT/consumer-agents-damaged"
mkdir -p "$CQ"
write_agents_manifest_at "$CQ" v0.1.0-agents "[ag-one]"
run_sync_at "$CQ" sync >/dev/null
grep -v '^# managed:' "$CQ/vendored/agents/.AGENTS_PROVENANCE" >"$CQ/tmp-prov" &&
    mv "$CQ/tmp-prov" "$CQ/vendored/agents/.AGENTS_PROVENANCE"
write_manifest_at "$CQ" v0.1.0-agents universal
expect_fail_contains "a damaged orphan stamp aborts the sync" "no '# managed:' line" \
    run_sync_at "$CQ" sync
expect_ok "aborted de-vendor kept the breadcrumb findable" \
    grep -q "^# agents-dest: vendored/agents$" "$CQ/vendored/skills/.SKILLS_PROVENANCE"
expect_ok "aborted de-vendor left the agents in place" test -f "$CQ/vendored/agents/ag-one.md"

# Same rule one level deeper: an UNSAFE NAME on the managed line must abort
# before the breadcrumb is cleared too. devendor_agents validates each name
# before its rm, which is correct but too late — the skills stamp has already
# been rewritten by then, so aborting there strands the agents unfindably.
CQ2="$TMPROOT/consumer-agents-badname"
mkdir -p "$CQ2"
write_agents_manifest_at "$CQ2" v0.1.0-agents "[ag-one]"
run_sync_at "$CQ2" sync >/dev/null
sed 's|^# managed:.*|# managed: ../bad|' "$CQ2/vendored/agents/.AGENTS_PROVENANCE" >"$CQ2/tmp-prov" &&
    mv "$CQ2/tmp-prov" "$CQ2/vendored/agents/.AGENTS_PROVENANCE"
write_manifest_at "$CQ2" v0.1.0-agents universal
expect_fail_contains "an unsafe name in the orphan stamp aborts the sync" \
    "refusing unsafe skill name" run_sync_at "$CQ2" sync
expect_ok "unsafe-name abort kept the breadcrumb findable" \
    grep -q "^# agents-dest: vendored/agents$" "$CQ2/vendored/skills/.SKILLS_PROVENANCE"
expect_ok "unsafe-name abort left the agents in place" test -f "$CQ2/vendored/agents/ag-one.md"

# --- a fresh scaffold's clean skip must not hit the network ---------------
# The skip is documented as costing no clone. A placeholder ref in a
# not-yet-synced repo must therefore not fail verify.
CZ="$TMPROOT/consumer-fresh-noclone"
mkdir -p "$CZ"
write_agents_manifest_at "$CZ" v9.9.9-unreachable "[ag-one]"
expect_ok "fresh scaffold: verify skips without cloning an unreachable ref" \
    run_sync_at "$CZ" verify

# --- a malformed agents.names must never resolve to "vendor nothing" ------
# `yq '.agents.names[]'` exits 0 and prints nothing for a missing key or a
# scalar, so `names: "*"` (the natural mis-spelling of `["*"]`) would otherwise
# delete every managed agent, write an empty stamp, and exit 0 — with verify
# agreeing afterwards, because empty really is in sync with empty.
CM="$TMPROOT/consumer-agents-malformed"
mkdir -p "$CM"
write_agents_manifest_at "$CM" v0.1.0-agents '["*"]'
run_sync_at "$CM" sync >/dev/null
expect_ok "malformed guard: agents vendored to begin with" test -f "$CM/vendored/agents/ag-one.md"

write_bad_names() {
    {
        echo "source:"
        echo "  repo: file://$SRC"
        echo "  ref: v0.1.0-agents"
        echo "categories:"
        echo "  - universal"
        echo "dest: vendored/skills"
        echo "agents:"
        [ -n "$1" ] && echo "  names: $1"
        echo "  dest: vendored/agents"
    } >"$CM/.skills-sync.yaml"
}

write_bad_names '"*"'
expect_fail_contains "scalar agents.names is refused" "must be a list" run_sync_at "$CM" sync
expect_ok "refused scalar left the agents intact" test -f "$CM/vendored/agents/ag-one.md"

write_bad_names '{a: b}'
expect_fail_contains "mapping agents.names is refused" "must be a list" run_sync_at "$CM" sync
expect_ok "refused mapping left the agents intact" test -f "$CM/vendored/agents/ag-two.md"

write_bad_names ""
expect_fail_contains "missing agents.names is refused" "agents.names is required" run_sync_at "$CM" sync
expect_ok "refused missing-names left the agents intact" test -f "$CM/vendored/agents/ag-one.md"

write_bad_names '"*"'
expect_fail_contains "verify also refuses a malformed agents.names" "must be a list" \
    run_sync_at "$CM" verify

# An EXPLICIT empty list is unambiguous intent and still works — it vendors
# nothing, exactly as an empty categories list vendors no skills.
write_bad_names "[]"
expect_ok "explicit empty agents.names is allowed" run_sync_at "$CM" sync
expect_ok "explicit empty list vendored no agents" test ! -e "$CM/vendored/agents/ag-one.md"
expect_ok "explicit empty list still stamped provenance" test -f "$CM/vendored/agents/.AGENTS_PROVENANCE"
expect_ok "explicit empty list verifies" run_sync_at "$CM" verify

# --- adding an agents block without syncing is DRIFT, not a fresh scaffold --
# The skills stamp proves this repo has run a sync, so a missing agents stamp
# means the block was added and never applied. Skipping here would let agent
# adoption pass CI with no agent files committed.
CU="$TMPROOT/consumer-agents-unsynced"
mkdir -p "$CU"
write_manifest_at "$CU" v0.1.0-agents universal
run_sync_at "$CU" sync >/dev/null # skills only — no agents block yet
write_agents_manifest_at "$CU" v0.1.0-agents "[ag-one]"
expect_fail_contains "verify fails when an agents block was never synced" \
    "requests agents but none are vendored" run_sync_at "$CU" verify
expect_fail_contains "offline check fails when an agents block was never synced" \
    "requests agents but none are vendored" run_sync_at "$CU" verify-offline
expect_ok "syncing clears it" run_sync_at "$CU" sync
expect_ok "verify passes once the agents are vendored" run_sync_at "$CU" verify

# The mirror case: agents stamped, skills gone. The agents stamp proves a sync
# has run, so this is drift too — guarding only one direction moves the hole
# instead of closing it.
CX="$TMPROOT/consumer-skills-lost"
mkdir -p "$CX"
write_agents_manifest_at "$CX" v0.1.0-agents "[ag-one]"
run_sync_at "$CX" sync >/dev/null
rm -rf "$CX/vendored/skills"
expect_fail_contains "verify fails when the vendored skills went missing" \
    "requests skills but none are vendored" run_sync_at "$CX" verify
expect_fail_contains "offline check fails when the vendored skills went missing" \
    "requests skills but none are vendored" run_sync_at "$CX" verify-offline
expect_ok "re-syncing restores them" run_sync_at "$CX" sync
expect_ok "verify passes once skills are back" run_sync_at "$CX" verify

# A repo that has never synced ANYTHING still skips cleanly — that is the fresh
# scaffold case the skip exists for, and it must survive the rule above.
CF="$TMPROOT/consumer-agents-fresh"
mkdir -p "$CF"
write_agents_manifest_at "$CF" v0.1.0-agents "[ag-one]"
expect_ok "fresh scaffold: verify still skips cleanly" run_sync_at "$CF" verify
expect_ok "fresh scaffold: offline check still skips cleanly" run_sync_at "$CF" verify-offline

# --- a failing agents pass must not leave skills bumped ------------------
# Both kinds of asset are pinned to ONE ref so they cannot skew. A sync that
# replaced skills and then died on an agent collision would create that skew
# while reporting failure, so the agents pass is preflighted first.
CS="$TMPROOT/consumer-agents-skew"
mkdir -p "$CS"
write_agents_manifest_at "$CS" v0.1.0-agents "[ag-one]"
run_sync_at "$CS" sync >/dev/null
expect_ok "skew guard: baseline skill is the old one" test -f "$CS/vendored/skills/uni-one/SKILL.md"
# Plant a local agent that the NEXT sync's incoming set will collide with.
echo "# local ag-two" >"$CS/vendored/agents/ag-two.md"
write_agents_manifest_at "$CS" v0.1.0-agents "[ag-one, ag-two]"
expect_fail_contains "skew guard: the colliding sync fails" "collides with an incoming" \
    run_sync_at "$CS" sync
expect_ok "skew guard: skills provenance was NOT rewritten" \
    grep -q "^# ref: v0.1.0-agents " "$CS/vendored/skills/.SKILLS_PROVENANCE"
expect_ok "skew guard: the local agent survived" grep -q "local ag-two" "$CS/vendored/agents/ag-two.md"
expect_ok "skew guard: the managed agent survived" test -f "$CS/vendored/agents/ag-one.md"

# --- offline ref check covers agents independently -----------------------
CO="$TMPROOT/consumer-agents-offline"
mkdir -p "$CO"
write_agents_manifest_at "$CO" v0.1.0-agents "[ag-one]"
run_sync_at "$CO" sync >/dev/null
expect_ok "agents: offline check passes after sync" run_sync_at "$CO" verify-offline
# Bump only the agents provenance ref -> offline must notice.
sed -i.bak 's/^# ref: .*/# ref: v9.9.9-absent (deadbeef)/' "$CO/vendored/agents/.AGENTS_PROVENANCE"
expect_fail_contains "offline check catches an agents ref mismatch" "vendored agents ref" \
    run_sync_at "$CO" verify-offline

# ── standardize-repo audit assets ─────────────────────────────────────
echo "==> standardize-repo audit assets"

STANDARDIZE_REFS="$repo/ai/skills/repo/standardize-repo/references"
IMPLEMENT_SKILL="$repo/ai/skills/universal/implement/SKILL.md"
SHEPHERD_SKILL="$repo/ai/skills/universal/shepherd/SKILL.md"
STANDARDIZE_SKILL="$repo/ai/skills/repo/standardize-repo/SKILL.md"
CLAIM_SKILL="$repo/ai/skills/universal/claim/SKILL.md"
expect_fail "standardize-repo has no references to the deleted source follow-up doc" \
    grep -Riq 'sourceRepo''FollowUps' "$STANDARDIZE_REFS"

# ── the copier answer-confirmation gate (issue #568) ──────────────────
# Every mode that runs `copier … --trust` non-interactively must present the
# resolved answers and gate the trusted run on the recorded confirmation.
# Executable, and executable in git's index once it is tracked — a mode bit that
# only exists in the working tree does not reach the repos that vendor it.
expect_ok "the confirmation asset is executable (and 100755 in the index)" \
    sh -c 'a=ai/skills/repo/standardize-repo/assets/confirm-answers.sh
        test -x "$1/$a" || exit 1
        m="$(git -C "$1" ls-files -s -- "$a" | cut -d" " -f1)"
        test -z "$m" || test "$m" = 100755' \
    sh "$repo"
# It reads YAML and hashes files; copier is never a command it runs, which is
# what makes it safe to call before the trusted execution it gates.
expect_ok "the confirmation asset never invokes copier as a command" \
    sh -c '! grep -Eq "^[[:space:]]*(sudo[[:space:]]+)?copier[[:space:]]" "$1/confirm-answers.sh"' \
    sh "$STANDARDIZE_ASSETS"
for guarded_mode in mode-update mode-adopt-existing mode-new-repo; do
    guarded_doc="$STANDARDIZE_REFS/$guarded_mode.md"
    expect_ok "$guarded_mode gates its trusted run on confirm-answers.sh --check" \
        grep -qF 'assets/confirm-answers.sh --check' "$guarded_doc"
    expect_ok "$guarded_mode presents the resolved answers before confirming" \
        grep -qF -- '--template-copier' "$guarded_doc"
    expect_ok "$guarded_mode names the auto-mode classifier denial" \
        grep -qF "auto-mode's" "$guarded_doc"
    expect_ok "$guarded_mode forbids agents self-granting the permission" \
        grep -qF 'never self-grant permissions' "$guarded_doc"
    expect_ok "$guarded_mode names the permission rule the user may add" \
        grep -Eq 'Bash\(copier (update|copy):\*\)' "$guarded_doc"
done
expect_ok "mode-update presents every active question, not the reviewed subset" \
    grep -qF -- '--active-keys "$GUARDED_STATE/active-target-questions"' \
    "$STANDARDIZE_REFS/mode-update.md"
expect_fail "mode-update never narrows the confirmation table to reviewed-keys" \
    grep -qF -- '--active-keys "$GUARDED_STATE/reviewed-keys"' \
    "$STANDARDIZE_REFS/mode-update.md"
expect_ok "mode-adopt-existing compares a re-adopt against the stale recorded answers" \
    sh -c 'grep -qF "RECORDED_ANSWERS=.copier-answers.yml" "$1" &&
        grep -qF -- "--recorded \"\$RECORDED_ANSWERS\"" "$1"' sh \
    "$STANDARDIZE_REFS/mode-adopt-existing.md"
expect_ok "mode-adopt-existing serializes the slug instead of interpolating YAML" \
    grep -qF ".project_slug = strenv(PROJECT_SLUG)" \
    "$STANDARDIZE_REFS/mode-adopt-existing.md"
expect_ok "every mode's --check binds the recorded answers too" \
    sh -c 'for d in mode-update mode-adopt-existing mode-new-repo; do
        awk "/assets\/confirm-answers.sh --check/ { inblock = 1; next }
             inblock && /--recorded/ { found++ }
             inblock && /--state-dir/ { inblock = 0 }
             END { exit found > 0 ? 0 : 1 }" "$1/$d.md" || exit 1
    done' sh "$STANDARDIZE_REFS"
expect_ok "mode-update checks the confirmation before the --pretend rehearsal" \
    sh -c 'awk "/assets\/confirm-answers.sh --check/ { seen = 1 } /run_guarded_copier update --trust --defaults --pretend/ { exit seen ? 0 : 1 }" "$1"' \
    sh "$STANDARDIZE_REFS/mode-update.md"
expect_ok "copier-gotchas carries the trust/classifier gotcha" \
    grep -qF '`--trust` executes template code' "$STANDARDIZE_REFS/copier-gotchas.md"
expect_ok "SKILL.md states the confirmation checkpoint" \
    grep -qF 'Confirm the resolved answers before any `--trust` run' "$STANDARDIZE_SKILL"

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
expect_ok "standards catalog names the six planning axes" \
    grep -qF 'six planning axes are' \
    "$STANDARDIZE_REFS/standards-catalog.md"
expect_ok "standards catalog lists every planning axis" \
    grep -qF '**Status, Priority, Size, Product, Domain, and Layer**' \
    "$STANDARDIZE_REFS/standards-catalog.md"
expect_ok "standards catalog removes Agent from the target field set" \
    grep -qF 'The retired `Agent` field is not part of the' \
    "$STANDARDIZE_REFS/standards-catalog.md"
expect_ok "standards catalog distinguishes pre-rollout task behavior" \
    grep -qF 'Those rows describe executable behavior in pre-rollout harmon-init releases' \
    "$STANDARDIZE_REFS/standards-catalog.md"
expect_ok "standards catalog leaves transition execution to harmon-init" \
    grep -qF 'not re-specified' \
    "$STANDARDIZE_REFS/standards-catalog.md"
expect_ok "standards catalog documents model-centric suggestions" \
    grep -qF '`suggest:<family>[:<model>]` for human-authored, advisory triage' \
    "$STANDARDIZE_REFS/standards-catalog.md"
expect_ok "standards catalog documents model-centric claims" \
    grep -qF '`claim:<family>[:<model>]` for agent-authored live ownership' \
    "$STANDARDIZE_REFS/standards-catalog.md"
expect_ok "standards catalog keeps claim cleanup transition-compatible" \
    grep -qF 'Transition-compatible consumers also recognize documented legacy' \
    "$STANDARDIZE_REFS/standards-catalog.md"
expect_ok "standards catalog scopes session claim cleanup to lifecycle completion" \
    grep -qF 'Interactive session claims are released at wrap or shepherd completion' \
    "$STANDARDIZE_REFS/standards-catalog.md"
expect_ok "standards catalog guarantees failure cleanup only for Claude Actions" \
    grep -qF 'Claude Action claims are released by an unconditional `if: always()` cleanup' \
    "$STANDARDIZE_REFS/standards-catalog.md"
# …and states the residual as an exception rather than softening "always": a run
# killed at the job cap never reaches the cleanup step at all.
expect_ok "standards catalog names the stranded-claim exception" \
    sh -c 'grep -qF "never reaches that step at all" "$1"' sh \
    "$STANDARDIZE_REFS/standards-catalog.md"
expect_ok "standards catalog requires registry-derived human routing tables" \
    grep -qF 'includes family and harness tables derived from the' \
    "$STANDARDIZE_REFS/standards-catalog.md"
expect_ok "standards catalog conditions phantom Foreman labels on opt-in" \
    grep -qF 'when `use_foreman` is enabled, phantom `foreman:*` rows' \
    "$STANDARDIZE_REFS/standards-catalog.md"
expect_ok "standards catalog reserves arming for Foreman" \
    grep -qF "only an authorized actor's \`foreman:<adapter>\` label arms" \
    "$STANDARDIZE_REFS/standards-catalog.md"
expect_ok "standards catalog points to the agent registry" \
    grep -qF 'harmon-init/blob/cc5b735b6c512738cf8689df393df8a20d409cee/agent-registry.json' \
    "$STANDARDIZE_REFS/standards-catalog.md"
expect_ok "standards catalog points to the vocabulary ADR" \
    grep -qF 'cc5b735b6c512738cf8689df393df8a20d409cee/docs/decisions/0005-unified-agent-vocabulary.md' \
    "$STANDARDIZE_REFS/standards-catalog.md"
expect_fail "standards catalog does not source the agent registry from mutable main" \
    grep -qF 'harmon-init/blob/main/agent-registry.json' \
    "$STANDARDIZE_REFS/standards-catalog.md"
expect_fail "standards catalog does not source the vocabulary ADR from mutable main" \
    grep -qF 'harmon-init/blob/main/docs/decisions/0005-unified-agent-vocabulary.md' \
    "$STANDARDIZE_REFS/standards-catalog.md"
expect_ok "standards catalog classifies missing registries as version lag" \
    grep -qF 'If that revision lacks the registry, report template-version lag' \
    "$STANDARDIZE_REFS/standards-catalog.md"
expect_ok "standards catalog describes mention-only Claude workflow triggers" \
    sh -c 'test "$(grep -cF "Mention-only, no label trigger" "$1")" = 3' sh \
    "$STANDARDIZE_REFS/standards-catalog.md"
expect_ok "standards catalog records the claim:claude lifecycle" \
    sh -c 'grep -qF "Claim the target with claim:claude" "$1" &&
        grep -qF "claude-claim-" "$1"' sh \
    "$STANDARDIZE_REFS/standards-catalog.md"
# The catalog must not reconstruct a live trigger phrase: quoted into an issue
# or PR comment, the workflows' contains() gate matches it and starts a real
# run (observed on harmon-init#718). What matters is the RENDERED copy, not the
# source bytes, so the pipeline approximates it — collapse whitespace (rendered
# markdown rejoins a phrase split across a line break), drop link targets
# (`[plan](docs/x.md)` renders as `plan`), then match the mention and the
# subcommand separated only by whitespace/punctuation such as backticks or bold
# markers, which render away. Case-insensitive because GitHub's `contains()` is.
# Prose words between the tokens break the run and pass, which is the fix this
# guard exists to protect. Deliberately the same detector harmon-init's
# lint-hygiene.sh applies on its side (init#725) — the file reaches init through
# a pin bump, so a weaker guard here would just move the failure downstream. The
# needle is assembled from two pieces so this guard is not itself a phrase.
#
# BOTH forms are checked, raw and rendered. Stripping link targets models what
# a reader copies out of the rendered page, but `contains()` reads whatever is
# actually in the comment body — and someone quoting the raw Markdown ships the
# link destination and title text too. Checking only the stripped form would
# miss a phrase hiding inside a URL or a link title; checking only the raw form
# would miss the backticked and bolded spellings that render away. Feed the
# matcher both and match either.
#
# The rendered branch applies every normalization CUMULATIVELY, in one pass.
# Running them as parallel alternatives — each starting from the original text —
# misses a phrase that needs two of them at once, e.g. a reference-style link
# label followed by an HTML-wrapped subcommand, where the link branch leaves the
# tag behind and the tag branch leaves the label behind. Composing is also
# monotone: each transform only deletes characters, so the fully normalized form
# subsumes every partially normalized one and no separate branch is needed.
trigger_phrase_present() {
    _tp_mention=$(printf '@%s' claude)
    _tp_pat="${_tp_mention}[[:space:][:punct:]\`\$+<=>^|~]{1,20}(plan|implement|review)"
    _tp_norm=$(tr -s '[:space:]' ' ' <"$1")
    # `grep -iE …>/dev/null`, deliberately NOT `grep -qiE`: this file runs under
    # `set -o pipefail`, and -q exits at the first match, so the upstream
    # printf/sed die of SIGPIPE and the pipeline reports 141 instead of 0. The
    # guard would then report "no trigger phrase" for a file that has one —
    # failing open, in the one place that must fail closed. Draining the input
    # costs nothing at this size.
    {
        printf '%s\n' "$_tp_norm"
        printf '%s\n' "$_tp_norm" |
            sed -E 's/\]\([^)]*\)//g; s/\]\[[^]]*\]//g; s/<[^>]*>//g'
    } | grep -iE "$_tp_pat" >/dev/null
}
# Every reference doc, not just the catalog: these are all Markdown an agent
# quotes into an issue or PR comment, so a phrase moved into a sibling file is
# just as live. Scanning the directory also means a reference added later is
# covered without anyone remembering to add it here.
for _ref in "$STANDARDIZE_REFS"/*.md; do
    expect_fail "$(basename "$_ref") reconstructs no literal Claude trigger phrase" \
        trigger_phrase_present "$_ref"
done
# Positive controls: the guard above is an expect_fail, so a pipeline that
# silently matched nothing at all would pass just as loudly as a clean catalog.
# These prove it still fires on the forms rendered copy reconstructs.
#
# Each fixture is ASSEMBLED at run time from a mention token and a subcommand
# token held apart in the source. Writing them out would put five live trigger
# phrases in a file that is itself quotable — the exact hazard this guard
# exists to catch — while testing nothing extra: the pipeline only ever sees
# the joined string.
#
# For the same reason each fixture is reported by a LABEL, never by its
# content: test output is routinely pasted into an issue or a PR comment, so
# echoing the assembled phrase would put a live trigger in the one place that
# acts on it. Entries are `label|content`; only the label is ever printed.
_m=$(printf '@%s' claude)
_M=$(printf '@%s' Claude)
for _trigger_case in \
    "same-line adjacency|post an ${_m} plan comment" \
    "backtick-separated tokens|post an \`${_m}\` \`plan\` comment" \
    "case variant|post an ${_M} Review comment" \
    "bold subcommand|post an ${_m} **implement** comment" \
    "linked subcommand|post an ${_m} [plan](docs/x.md) comment" \
    "phrase inside a link destination|see [the docs](https://x.example/${_m}-plan)" \
    "phrase inside a link title|see [the docs](https://x.example \"${_m} plan\")" \
    "inline HTML between the tokens|post an ${_m} <em>plan</em> comment" \
    "reference-style link label|post an [${_m}][bot] plan comment" \
    "combined reference link and inline HTML|post an [${_m}][bot] <em>plan</em> comment"; do
    _label=${_trigger_case%%|*}
    _trigger_fixture=${_trigger_case#*|}
    _tf=$(mktemp)
    printf '%s\n' "$_trigger_fixture" >"$_tf"
    expect_ok "trigger-phrase guard fires on the $_label fixture" \
        trigger_phrase_present "$_tf"
    rm -f "$_tf"
done
# Negative control: prose words between the tokens must NOT fire, or the guard
# would forbid the very phrasing the catalog now uses.
_tf=$(mktemp)
printf '%s\n' "an ${_m} mention naming plan, implement, or review" >"$_tf"
expect_fail "trigger-phrase guard ignores prose-separated tokens" \
    trigger_phrase_present "$_tf"
rm -f "$_tf"
expect_ok "standards catalog keeps migration procedures out of the catalog" \
    grep -qF 'not a second procedure in this catalog' \
    "$STANDARDIZE_REFS/standards-catalog.md"
expect_ok "standards catalog pins the foreman v2 uvx wrapper" \
    grep -qF 'uvx --from git+https://github.com/ponderousdev/foreman@v' \
    "$STANDARDIZE_REFS/standards-catalog.md"
expect_fail "standards catalog no longer ships vendored foreman paths" \
    grep -qF '.claude/agents/foreman-preflight' \
    "$STANDARDIZE_REFS/standards-catalog.md"
expect_ok "standards catalog recipe matches the complete forced sweep" \
    sh -c 'grep -qF "git rm -rf --ignore-unmatch scripts/foreman" "$1" &&
        grep -qF "docs/architecture/foreman.md" "$1"' sh \
    "$STANDARDIZE_REFS/standards-catalog.md"
expect_ok "update guidance documents the Foreman default transition" \
    grep -qF 'It was default-on when introduced in v3.26.1' \
    "$STANDARDIZE_REFS/mode-update.md"
expect_ok "update guidance removes the vendored foreman tree on migration" \
    sh -c 'grep -qF "git rm -rf --ignore-unmatch scripts/foreman" "$1" &&
        grep -qF "test ! -d scripts/foreman" "$1"' sh \
    "$STANDARDIZE_REFS/mode-update.md"
expect_ok "update guidance sweeps every retired foreman artifact" \
    sh -c 'grep -qF ".claude/agents/foreman-*.md" "$1" &&
        grep -qF "docs/architecture/foreman.md" "$1"' sh \
    "$STANDARDIZE_REFS/mode-update.md"
expect_ok "update guidance branches the migration on the use_foreman answer" \
    sh -c 'grep -qF "use_foreman=false" "$1" &&
        grep -qF "nothing to migrate" "$1"' sh \
    "$STANDARDIZE_REFS/mode-update.md"
expect_ok "inventory guidance gates the wrapper proof on the reviewed answer" \
    sh -c 'grep -qF "branch on the reviewed \`use_foreman\`" "$1" &&
        grep -qF "does not exist and must not be required" "$1"' sh \
    "$STANDARDIZE_REFS/mode-update.md"
expect_ok "claim skill names the renamed foreman-vet sibling" \
    grep -qF 'foreman-vet' "$CLAIM_SKILL"
expect_fail "claim skill drops the retired foreman-preflight sibling claim" \
    grep -qF "sibling of harmon-init's \`foreman-preflight\`" "$CLAIM_SKILL"
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
# Rehearsal, preview and apply must all be handed the SAME frozen payload — a
# rehearsal run with different answers predicts a different update.
expect_ok "update guidance passes one frozen reviewed-data file to rehearsal, preview and apply" \
    test "$(grep -Fc -- '--data-file="$REVIEWED_DATA"' \
        "$STANDARDIZE_REFS/mode-update.md")" -eq 3
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
expect_ok "update guidance waives classifier prerequisites for a skills-source repo" \
    sh -c 'grep -qF "SKILLS_SOURCE_CLASSIFIER=" "$1" &&
        grep -qF "ai/skills/universal/shepherd/assets/check-codex-cloud-review.sh" "$1" &&
        grep -qF "SHIPS_CLASSIFIER_NATIVELY=true" "$1" &&
        grep -qF "git ls-files --stage -- \"\$SKILLS_SOURCE_CLASSIFIER\"" "$1" &&
        grep -qF "= \"100755\"" "$1" &&
        grep -qF "SHIPS_CLASSIFIER_NATIVELY\" != \"true\"" "$1" &&
        grep -qF "waives both the skills-sync and universal-category" "$1"' sh \
    "$STANDARDIZE_REFS/mode-update.md"
# Each waiver site is pinned through its own distinctive neighbour instead of a
# file-wide occurrence count. The counts these replace (`-eq 6` on
# SHIPS_CLASSIFIER_NATIVELY, `-eq 3` on the diagnostic) broke the moment the
# detector grew a line, and never said anything about WHERE the waiver applies:
# all three sites could collapse into one and the totals would still match.
expect_ok "update guidance waives skills-sync at the pre-review guard site" \
    sh -c 'grep -A5 -F "$2" "$1" | grep -qF "$3"' sh \
    "$STANDARDIZE_REFS/mode-update.md" \
    'USE_SKILLS_SYNC must be true or false' \
    'requires use_skills_sync (waived when this repo ships the classifier natively'
expect_ok "update guidance waives skills-sync at the post-review guard site" \
    sh -c 'grep -A5 -F "$2" "$1" | grep -qF "$3"' sh \
    "$STANDARDIZE_REFS/mode-update.md" \
    'reviewed use_skills_sync must be boolean' \
    'requires use_skills_sync (waived when this repo ships the classifier natively'
expect_ok "update guidance waives the universal category at its own guard site" \
    sh -c 'grep -A1 -F "$2" "$1" | grep -qF "$3"' sh \
    "$STANDARDIZE_REFS/mode-update.md" \
    'yq -e '"'"'contains(["universal"])'"'"' -' \
    'requires the universal skill category (waived when this repo ships the classifier natively'
expect_ok "update guidance keeps the skill_categories carve-out for a native classifier" \
    sh -c 'grep -B3 -F "$2" "$1" | grep -qF "$3"' sh \
    "$STANDARDIZE_REFS/mode-update.md" \
    'required skill_categories question is not active' \
    '[ "$SHIPS_CLASSIFIER_NATIVELY" != "true" ]'
# The detector is lifted out of the doc and RUN against throwaway repos below,
# so its marker pair has to stay unique file-wide: a second copy of either
# marker would widen the sed range and hand `bash -eu` a truncated program.
GU_CLASSIFIER_SNIPPET="$TMPROOT/classifier-detector.sh"
sed -n '/# >>> classifier-detector >>>/,/# <<< classifier-detector <<</p' \
    "$STANDARDIZE_REFS/mode-update.md" >"$GU_CLASSIFIER_SNIPPET"
expect_ok "classifier detector carries exactly one extraction marker pair" \
    sh -c 'test "$(grep -cF "# >>> classifier-detector >>>" "$1")" -eq 1 &&
        test "$(grep -cF "# <<< classifier-detector <<<" "$1")" -eq 1' sh \
    "$STANDARDIZE_REFS/mode-update.md"
# Marker drift extracts garbage silently — an empty range, or a range running to
# the end of the file — and every behavioral case below would then be testing
# whatever came out. Prove the extraction is a program before trusting it.
expect_ok "classifier detector extraction is non-empty and parses as bash" \
    sh -c 'test -s "$1" && bash -n "$1"' sh \
    "$GU_CLASSIFIER_SNIPPET"
expect_ok "classifier detector validates the shepherd entry point frontmatter" \
    sh -c 'grep -qF "ai/skills/universal/shepherd/SKILL.md" "$1" &&
        grep -qF "git ls-files --error-unmatch" "$1" &&
        grep -qF "classifier_skill_frontmatter_ok" "$1"' sh \
    "$GU_CLASSIFIER_SNIPPET"
# Structure stays static because yq does not fail closed on it: a file with no
# frontmatter, or an unclosed block whose body is valid YAML, both parse and
# resolve `.name`. Only the fence checks remain hand-rolled.
expect_ok "classifier frontmatter probe checks the fences statically" \
    sh -c 'grep -qF "$2" "$1" && grep -qF "$3" "$1"' sh \
    "$GU_CLASSIFIER_SNIPPET" \
    'NR == 1 && $0 != "---" { exit }' 'exit (fence >= 2) ? 0 : 1'
# Values come from a real parser. mode-update.md already hard-requires yq v4, so
# the detector may assume it, and the whole hand-written YAML grammar is gone.
expect_ok "classifier frontmatter probe resolves values with yq" \
    sh -c 'for needle in "$2" "$3" "$4" "$5"; do
        grep -qF "$needle" "$1" || exit 1
    done' sh \
    "$GU_CLASSIFIER_SNIPPET" \
    'yq --front-matter=extract -e' \
    '(.name | tag) == "!!str"' \
    '(.description | tag) == "!!str"' \
    '.description != ""'
# The grammar re-implementation must be GONE, not merely unused: each of these
# was a round of findings, and every one of them is the parser's job now.
expect_ok "classifier frontmatter probe reimplements no YAML grammar" \
    sh -c 'for needle in "$2" "$3" "$4" "$5" "$6" "$7"; do
        grep -qF "$needle" "$1" && exit 1
    done
    exit 0' sh \
    "$GU_CLASSIFIER_SNIPPET" \
    'in_block' 'ok_desc' 'seen_name' 'd != "null"' '\047shepherd\047' \
    'sub(/[[:space:]]#.*$/'
# verify-skills.sh stays canonical for LAYOUT; YAML semantics now come from the
# parser. Name it, so the next reader knows which side owns which question.
expect_ok "classifier frontmatter probe cross-references its canonical source" \
    sh -c 'grep -qF "$2" "$1" && grep -qF "$3" "$1"' sh \
    "$GU_CLASSIFIER_SNIPPET" \
    'verify-skills.sh' 'frontmatter_is_closed'
# The entry point is mode-checked from the index, same idiom as the classifier
# path: only regular blobs qualify, so a 120000 symlink cannot stand in.
expect_ok "classifier detector requires a regular-file shepherd entry point" \
    sh -c 'grep -qF "classifier_skill_is_regular_file" "$1" &&
        grep -qF "100644 | 100755" "$1"' sh \
    "$GU_CLASSIFIER_SNIPPET"
# The verb probes must anchor on the helper's dispatch arms, not on the usage
# strings a comment can print — that difference is the whole finding.
for cls_verb in reserve attach check show reap; do
    expect_ok "classifier detector anchors $cls_verb on a dispatch case arm" \
        sh -c 'grep -F "$2" "$1" | grep -qF classifier_code_has' sh \
        "$GU_CLASSIFIER_SNIPPET" "^$cls_verb\\)"
done
# And it must no longer anchor on anything a banner can print. Checked against
# the detector's own CODE, since its rationale comment quotes the old strings
# precisely to explain why they were abandoned.
expect_fail "classifier detector code no longer anchors on printable usage strings" \
    sh -c 'sed "s/^[[:space:]]*//" "$1" | grep -v "^#" | grep -qF -- "$2"' sh \
    "$GU_CLASSIFIER_SNIPPET" 'reserve --state'
# The exit-code pairs are the bounded-attempt lifecycle shepherd depends on,
# asserted as verdict+code pairs so neither half can drift away alone.
expect_ok "classifier detector anchors the pending and escalate exit contract" \
    sh -c 'for needle in "$2" "$3" "$4" "$5"; do
        grep -F "$needle" "$1" | grep -qF classifier_code_has || exit 1
    done' sh \
    "$GU_CLASSIFIER_SNIPPET" \
    '^emit pending ' '^exit 11$' '^emit escalate ' '^exit 13$'
# Comment stripping is what makes every probe above unsatisfiable by prose.
expect_ok "classifier detector reads helper code with comment lines stripped" \
    sh -c 'grep -qF "$2" "$1" && grep -qF "$3" "$1"' sh \
    "$GU_CLASSIFIER_SNIPPET" \
    'line ~ /^#/ { next }' 'ENVIRON["CLASSIFIER_PROBE"]'
# The probe pattern must not travel via `awk -v`, which escape-processes the
# value and would mangle the `\)` in every case-arm anchor.
expect_fail "classifier detector does not pass probe patterns through awk -v" \
    grep -qF -- 'awk -v' "$GU_CLASSIFIER_SNIPPET"
# Structural guard against reintroducing the pipefail hazard. `grep -q` exits at
# the first match, killing upstream pipeline stages with SIGPIPE; under
# `pipefail` that makes a matching probe report failure. Checked on the
# detector's CODE, since the rationale comment names the broken form on purpose.
expect_ok "classifier detector code contains no early-exit grep pipeline" \
    sh -c 'test "$(sed "s/^[[:space:]]*//" "$1" | grep -v "^#" | grep -c "grep -q")" -eq 0' sh \
    "$GU_CLASSIFIER_SNIPPET"

# Behavioral proof of the detector, one throwaway repo per way a tree can fail
# to be a skills source. The doc IS the implementation — an operator pastes it
# into a shell — so only executing it shows the waiver opening and closing where
# it should. The greps above prove the probes are written; these prove they
# decide. Staging is enough: every probe reads the index or the worktree, so no
# fixture needs a commit.
CLASSIFIER_HELPER_REL="ai/skills/universal/shepherd/assets/check-codex-cloud-review.sh"
CLASSIFIER_SKILL_REL="ai/skills/universal/shepherd/SKILL.md"
# $1 repo root, $2 `git add --chmod` flag for the helper, $3 SKILL.md shape
# (`valid` | `untracked` | `nofrontmatter` | `quotedname` | `blockscalar` |
# `unclosed` | `bodyonly` | `emptydq` | `emptysq` | `commentdesc` | `nulldesc` |
# `tildedesc` | `emptyscalar` | `flowseqdesc` | `commentedheader` |
# `commentedheadercontent` | `commentedpipe` | `inlinecomment` |
# `chompfirstfold` | `chompfirstliteral` | `chompfirstcontent` |
# `nullcomment` | `emptydqcomment` | `tildecomment` | `flowcomment` |
# `quotednull` | `indentzero` | `indentten` | `spacedflowseq` |
# `spacedflowmap`),
# $4 helper shape:
#   dispatch — a real-shaped miniature: a `case` on the command with all five
#              arms, and the pending/escalate verdicts with their exit codes.
#   usage    — a no-op whose COMMENTS print the five usage forms. This is the
#              spoof issue 336 is about, and it is a reject case.
#   empty    — a bare `exit 0` with nothing at all.
#   padded   — `dispatch` followed by ~1 MB of filler. The dispatch arms match
#              near the top while a reader still has the rest to write, which
#              turns the superseded pipeline's SIGPIPE race into a certainty.
classifier_dispatch_body() {
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'emit() { printf "%s %s\n" "$1" "$2"; }' \
        'command_name="${1:-}"' \
        'case "$command_name" in' \
        'reserve)' \
        '    : ;;' \
        'attach)' \
        '    : ;;' \
        'check)' \
        '    if [ "${2:-}" = wait ]; then' \
        '        emit pending "window open"' \
        '        exit 11' \
        '    fi' \
        '    emit escalate "both windows elapsed"' \
        '    exit 13' \
        '    ;;' \
        'show)' \
        '    : ;;' \
        'reap)' \
        '    : ;;' \
        'esac'
}
make_classifier_fixture() {
    local root="$1" chmod_flag="$2" skill_shape="$3" helper_shape="$4"
    git_init "$root"
    mkdir -p "$root/ai/skills/universal/shepherd/assets"
    case "$helper_shape" in
    dispatch)
        classifier_dispatch_body >"$root/$CLASSIFIER_HELPER_REL"
        ;;
    padded)
        {
            classifier_dispatch_body
            awk 'BEGIN { for (i = 0; i < 20000; i++)
                print ": filler keeping the writer blocked long after grep -q exits" }'
        } >"$root/$CLASSIFIER_HELPER_REL"
        ;;
    usage)
        printf '%s\n' \
            '#!/usr/bin/env bash' \
            '# Usage:' \
            '#   check-codex-cloud-review.sh reserve --state FILE --repo O/R --pr N' \
            '#   check-codex-cloud-review.sh attach --state FILE --trigger-id N' \
            '#   check-codex-cloud-review.sh check --state FILE --actor-id N' \
            '#   check-codex-cloud-review.sh show --state FILE' \
            '#   check-codex-cloud-review.sh reap --root DIR --budget-sec N' \
            'exit 0' >"$root/$CLASSIFIER_HELPER_REL"
        ;;
    *)
        printf '%s\n' '#!/usr/bin/env bash' 'exit 0' \
            >"$root/$CLASSIFIER_HELPER_REL"
        ;;
    esac
    chmod +x "$root/$CLASSIFIER_HELPER_REL"
    git -C "$root" add "--chmod=$chmod_flag" -- "$CLASSIFIER_HELPER_REL"
    case "$skill_shape" in
    nofrontmatter)
        printf '%s\n' '# Shepherd' 'No frontmatter here.'
        ;;
    quotedname)
        printf '%s\n' '---' 'name: "shepherd"' \
            'description: Double-quoted name, valid YAML.' '---' 'Body.'
        ;;
    blockscalar)
        printf '%s\n' '---' 'name: shepherd' 'description: >-' \
            '  A folded block scalar, the form the real SKILL.md uses.' \
            '---' 'Body.'
        ;;
    unclosed)
        printf '%s\n' '---' 'name: shepherd' \
            'description: The block never closes.' 'Straight into the body.'
        ;;
    bodyonly)
        printf '%s\n' '---' '---' 'name: shepherd' \
            'description: These live in the body, not the block.'
        ;;
    emptydq)
        printf '%s\n' '---' 'name: shepherd' 'description: ""' '---' 'Body.'
        ;;
    emptysq)
        printf '%s\n' '---' 'name: shepherd' "description: ''" '---' 'Body.'
        ;;
    commentdesc)
        printf '%s\n' '---' 'name: shepherd' 'description: # TODO' '---' 'Body.'
        ;;
    nulldesc)
        printf '%s\n' '---' 'name: shepherd' 'description: null' '---' 'Body.'
        ;;
    tildedesc)
        printf '%s\n' '---' 'name: shepherd' 'description: ~' '---' 'Body.'
        ;;
    emptyscalar)
        printf '%s\n' '---' 'name: shepherd' 'description: >-' '---' 'Body.'
        ;;
    flowseqdesc)
        printf '%s\n' '---' 'name: shepherd' 'description: []' '---' 'Body.'
        ;;
    commentedheader)
        printf '%s\n' '---' 'name: shepherd' 'description: >- # folded' \
            '---' 'Body.'
        ;;
    commentedheadercontent)
        printf '%s\n' '---' 'name: shepherd' 'description: >- # folded' \
            '  Real folded content behind a commented header.' '---' 'Body.'
        ;;
    commentedpipe)
        printf '%s\n' '---' 'name: shepherd' 'description: | # kept' \
            '---' 'Body.'
        ;;
    inlinecomment)
        printf '%s\n' '---' 'name: shepherd' \
            'description: A real value # with a trailing comment' '---' 'Body.'
        ;;
    chompfirstfold)
        printf '%s\n' '---' 'name: shepherd' 'description: >+2' '---' 'Body.'
        ;;
    chompfirstliteral)
        printf '%s\n' '---' 'name: shepherd' 'description: |-2' '---' 'Body.'
        ;;
    chompfirstcontent)
        printf '%s\n' '---' 'name: shepherd' 'description: >+2' \
            '  Content behind a chomp-first header.' '---' 'Body.'
        ;;
    nullcomment)
        printf '%s\n' '---' 'name: shepherd' 'description: null # TODO' \
            '---' 'Body.'
        ;;
    emptydqcomment)
        printf '%s\n' '---' 'name: shepherd' 'description: "" # TODO' \
            '---' 'Body.'
        ;;
    tildecomment)
        printf '%s\n' '---' 'name: shepherd' 'description: ~ # x' \
            '---' 'Body.'
        ;;
    flowcomment)
        printf '%s\n' '---' 'name: shepherd' 'description: [] # x' \
            '---' 'Body.'
        ;;
    quotednull)
        printf '%s\n' '---' 'name: shepherd' 'description: "null"' \
            '---' 'Body.'
        ;;
    indentzero)
        printf '%s\n' '---' 'name: shepherd' 'description: |0' \
            '  Content behind an illegal zero indent indicator.' '---' 'Body.'
        ;;
    indentten)
        printf '%s\n' '---' 'name: shepherd' 'description: |10' \
            '  Content behind a two-digit indent indicator.' '---' 'Body.'
        ;;
    spacedflowseq)
        printf '%s\n' '---' 'name: shepherd' 'description: [ ]' '---' 'Body.'
        ;;
    spacedflowmap)
        printf '%s\n' '---' 'name: shepherd' 'description: { }' '---' 'Body.'
        ;;
    *)
        printf '%s\n' '---' 'name: shepherd' \
            'description: Shepherd a draft PR to ready for review.' '---' \
            'Body.'
        ;;
    esac >"$root/$CLASSIFIER_SKILL_REL"
    if [ "$skill_shape" != untracked ]; then
        git -C "$root" add -- "$CLASSIFIER_SKILL_REL"
    fi
}
# A skills source whose entry point is a tracked SYMLINK to a perfectly valid
# SKILL.md. Every content-based probe reads straight through it; only the index
# mode tells them apart, so this needs its own builder rather than a shape.
make_classifier_symlink_fixture() {
    local root="$1" target="ai/skills/universal/shepherd/SKILL-target.md"
    make_classifier_fixture "$root" +x valid dispatch
    rm -f "$root/$CLASSIFIER_SKILL_REL"
    git -C "$root" rm -q --cached -- "$CLASSIFIER_SKILL_REL"
    printf '%s\n' '---' 'name: shepherd' \
        'description: A completely valid target file.' '---' 'Body.' \
        >"$root/$target"
    ln -s SKILL-target.md "$root/$CLASSIFIER_SKILL_REL"
    git -C "$root" add -- "$target" "$CLASSIFIER_SKILL_REL"
}
# Run a detector snippet ($1) with a fixture ($2) as cwd; report its verdict.
classifier_verdict_with() {
    (
        cd "$2" || exit 1
        bash -eu -c '. "$1"; printf "RESULT=%s\n" "$SHIPS_CLASSIFIER_NATIVELY"' \
            bash "$1"
    )
}
classifier_verdict() { classifier_verdict_with "$GU_CLASSIFIER_SNIPPET" "$1"; }
# The same, under `bash -euo pipefail`. mode-update.md's preamble tells readers
# to run its blocks with pipefail care, so the detector has to survive it — and
# a `-eu`-only harness is exactly how a pipefail-only defect stayed invisible.
classifier_verdict_pipefail_with() {
    (
        cd "$2" || exit 1
        bash -euo pipefail -c \
            '. "$1"; printf "RESULT=%s\n" "$SHIPS_CLASSIFIER_NATIVELY"' \
            bash "$1"
    )
}
classifier_verdict_pipefail() {
    classifier_verdict_pipefail_with "$GU_CLASSIFIER_SNIPPET" "$1"
}

# --- frozen predecessor probes -----------------------------------------------
# Each hardening round of the classifier waiver leaves one frozen copy of the
# probe it replaced, so its negative control can show a BEHAVIOR CHANGE rather
# than assert about code that was already strict enough. They accumulate one per
# round, so they live in a single keyed registry instead of a fresh ad-hoc
# variable and heredoc each time: `freeze_classifier_probe <key>` reads the
# snippet from stdin, and the controls name the key.
#
# Snippet bodies are verbatim copies of the shipped detector at the commit named
# in each comment. Do not tidy them — a control that has drifted from its
# predecessor proves nothing about that predecessor.
CLASSIFIER_FROZEN_DIR="$TMPROOT/classifier-frozen"
mkdir -p "$CLASSIFIER_FROZEN_DIR"
freeze_classifier_probe() { cat >"$CLASSIFIER_FROZEN_DIR/$1.sh"; }
classifier_verdict_frozen() {
    classifier_verdict_with "$CLASSIFIER_FROZEN_DIR/$1.sh" "$2"
}
classifier_verdict_frozen_pipefail() {
    classifier_verdict_pipefail_with "$CLASSIFIER_FROZEN_DIR/$1.sh" "$2"
}
# The `sed | grep -v | grep -qE` probe: same input, opposite answers depending
# only on the shell mode, which is what made the pipefail defect easy to miss.
freeze_classifier_probe code-pipeline <<'SUPERSEDEDPIPE'
SKILLS_SOURCE_CLASSIFIER="ai/skills/universal/shepherd/assets/check-codex-cloud-review.sh"
classifier_code_has() {
    sed 's/^[[:space:]]*//' "$SKILLS_SOURCE_CLASSIFIER" | grep -v '^#' | grep -qE "$1"
}
if classifier_code_has '^reserve\)'; then
    SHIPS_CLASSIFIER_NATIVELY=true
else
    SHIPS_CLASSIFIER_NATIVELY=false
fi
SUPERSEDEDPIPE
# The SKILL.md side with a tracked-only check and no index-mode probe, and the
# frontmatter awk before it learned the null spellings and block scalars: a
# symlinked entry point and a `description: null` each waived the guards.
freeze_classifier_probe skill-probes <<'SUPERSEDEDSKILL'
SKILLS_SOURCE_SHEPHERD_SKILL="ai/skills/universal/shepherd/SKILL.md"
classifier_skill_frontmatter_ok() {
    awk '
    NR == 1 && $0 != "---" { exit }
    $0 == "---" { fence++; if (fence >= 2) exit; next }
    fence == 1 && /^name:[[:space:]]*/ {
      if (!seen_name) {
        seen_name = 1
        v = $0; sub(/^name:[[:space:]]*/, "", v); sub(/\r$/, "", v)
        if (v == "shepherd" || v == "\"shepherd\"" || v == "\047shepherd\047") ok_name = 1
      }
    }
    fence == 1 && /^description:[[:space:]]*/ {
      d = $0; sub(/^description:[[:space:]]*/, "", d); sub(/\r$/, "", d)
      sub(/[[:space:]]+$/, "", d)
      if (d != "" && d != "\"\"" && d != "\047\047" && d !~ /^#/) ok_desc = 1
    }
    END { exit (fence >= 2 && ok_name && ok_desc) ? 0 : 1 }
  ' "$SKILLS_SOURCE_SHEPHERD_SKILL"
}
if git ls-files --error-unmatch -- "$SKILLS_SOURCE_SHEPHERD_SKILL" >/dev/null 2>&1 &&
    classifier_skill_frontmatter_ok; then
    SHIPS_CLASSIFIER_NATIVELY=true
else
    SHIPS_CLASSIFIER_NATIVELY=false
fi
SUPERSEDEDSKILL
# The description rules from the round that introduced the block walk but
# tested the header with a bare regex: a header carrying a trailing comment
# missed it, fell through to the value branch, and passed.
freeze_classifier_probe desc-header <<'SUPERSEDEDHEADER'
SKILLS_SOURCE_SHEPHERD_SKILL="ai/skills/universal/shepherd/SKILL.md"
classifier_skill_frontmatter_ok() {
    awk '
    NR == 1 && $0 != "---" { exit }
    $0 == "---" { fence++; if (fence >= 2) exit; next }
    fence == 1 && /^name:[[:space:]]*/ {
      if (!seen_name) {
        seen_name = 1
        v = $0; sub(/^name:[[:space:]]*/, "", v); sub(/\r$/, "", v)
        if (v == "shepherd" || v == "\"shepherd\"" || v == "\047shepherd\047") ok_name = 1
      }
    }
    fence == 1 && /^description:[[:space:]]*/ {
      d = $0; sub(/^description:[[:space:]]*/, "", d); sub(/\r$/, "", d)
      sub(/[[:space:]]+$/, "", d)
      if (d ~ /^[|>][0-9]*[+-]?$/) { in_block = 1; next }
      if (d != "" && d != "\"\"" && d != "\047\047" &&
          d != "null" && d != "Null" && d != "NULL" && d != "~" &&
          d != "[]" && d != "{}" && d !~ /^#/) ok_desc = 1
      next
    }
    fence == 1 && in_block {
      if ($0 ~ /^[^[:space:]]/) in_block = 0
      else if ($0 ~ /[^[:space:]]/) { ok_desc = 1; in_block = 0 }
    }
    END { exit (fence >= 2 && ok_name && ok_desc) ? 0 : 1 }
  ' "$SKILLS_SOURCE_SHEPHERD_SKILL"
}
if classifier_skill_frontmatter_ok; then
    SHIPS_CLASSIFIER_NATIVELY=true
else
    SHIPS_CLASSIFIER_NATIVELY=false
fi
SUPERSEDEDHEADER
# The original usage-string detector, for the one assertion that a comment-only
# stub used to pass — a hardening claim nobody can see failing is not evidence.
freeze_classifier_probe usage-strings <<'SUPERSEDED'
SKILLS_SOURCE_CLASSIFIER="ai/skills/universal/shepherd/assets/check-codex-cloud-review.sh"
SKILLS_SOURCE_SHEPHERD_SKILL="ai/skills/universal/shepherd/SKILL.md"
if [ -f "$SKILLS_SOURCE_CLASSIFIER" ] &&
    [ "$(git ls-files --stage -- "$SKILLS_SOURCE_CLASSIFIER" 2>/dev/null | cut -c1-6)" = "100755" ] &&
    git ls-files --error-unmatch -- "$SKILLS_SOURCE_SHEPHERD_SKILL" >/dev/null 2>&1 &&
    grep -qF 'reserve --state' "$SKILLS_SOURCE_CLASSIFIER" &&
    grep -qF 'attach --state' "$SKILLS_SOURCE_CLASSIFIER" &&
    grep -qF 'check --state' "$SKILLS_SOURCE_CLASSIFIER" &&
    grep -qF 'show --state' "$SKILLS_SOURCE_CLASSIFIER" &&
    grep -qF 'reap --root' "$SKILLS_SOURCE_CLASSIFIER"; then
    SHIPS_CLASSIFIER_NATIVELY=true
else
    SHIPS_CLASSIFIER_NATIVELY=false
fi
SUPERSEDED
# The whole-file frontmatter greps, scoped to just those three tests so the
# control isolates the changed semantics: they rejected a valid quoted name
# (too strict) and accepted keys appearing only in the body (too loose).
freeze_classifier_probe frontmatter-greps <<'SUPERSEDEDFM'
SKILLS_SOURCE_SHEPHERD_SKILL="ai/skills/universal/shepherd/SKILL.md"
if head -n 1 "$SKILLS_SOURCE_SHEPHERD_SKILL" | grep -qxF -- '---' &&
    grep -qE '^name:[[:space:]]*shepherd[[:space:]]*$' "$SKILLS_SOURCE_SHEPHERD_SKILL" &&
    grep -qE '^description:[[:space:]]*[^[:space:]]' "$SKILLS_SOURCE_SHEPHERD_SKILL"; then
    SHIPS_CLASSIFIER_NATIVELY=true
else
    SHIPS_CLASSIFIER_NATIVELY=false
fi
SUPERSEDEDFM
# The description rules once the comment-strip copy existed but the header test
# still assumed indentation-before-chomping: `|-2` and `>+2` are legal YAML in
# the other order, missed the test, and an empty block passed as a value.
freeze_classifier_probe header-ordering <<'SUPERSEDEDORDER'
SKILLS_SOURCE_SHEPHERD_SKILL="ai/skills/universal/shepherd/SKILL.md"
classifier_skill_frontmatter_ok() {
    awk '
    NR == 1 && $0 != "---" { exit }
    $0 == "---" { fence++; if (fence >= 2) exit; next }
    fence == 1 && /^name:[[:space:]]*/ {
      if (!seen_name) {
        seen_name = 1
        v = $0; sub(/^name:[[:space:]]*/, "", v); sub(/\r$/, "", v)
        if (v == "shepherd" || v == "\"shepherd\"" || v == "\047shepherd\047") ok_name = 1
      }
    }
    fence == 1 && /^description:[[:space:]]*/ {
      d = $0; sub(/^description:[[:space:]]*/, "", d); sub(/\r$/, "", d)
      sub(/[[:space:]]+$/, "", d)
      h = d; sub(/[[:space:]]#.*$/, "", h); sub(/[[:space:]]+$/, "", h)
      if (h ~ /^[|>][0-9]*[+-]?$/) { in_block = 1; next }
      if (d != "" && d != "\"\"" && d != "\047\047" &&
          d != "null" && d != "Null" && d != "NULL" && d != "~" &&
          d != "[]" && d != "{}" && d !~ /^#/) ok_desc = 1
      next
    }
    fence == 1 && in_block {
      if ($0 ~ /^[^[:space:]]/) in_block = 0
      else if ($0 ~ /[^[:space:]]/) { ok_desc = 1; in_block = 0 }
    }
    END { exit (fence >= 2 && ok_name && ok_desc) ? 0 : 1 }
  ' "$SKILLS_SOURCE_SHEPHERD_SKILL"
}
if classifier_skill_frontmatter_ok; then
    SHIPS_CLASSIFIER_NATIVELY=true
else
    SHIPS_CLASSIFIER_NATIVELY=false
fi
SUPERSEDEDORDER
# The description rules once both indicator orderings were covered, but with the
# comment strip still confined to a throwaway header copy: every value judgment
# read the unstripped scalar, so `null # TODO` and `"" # TODO` passed.
freeze_classifier_probe value-composition <<'SUPERSEDEDCOMPOSE'
SKILLS_SOURCE_SHEPHERD_SKILL="ai/skills/universal/shepherd/SKILL.md"
classifier_skill_frontmatter_ok() {
    awk '
    NR == 1 && $0 != "---" { exit }
    $0 == "---" { fence++; if (fence >= 2) exit; next }
    fence == 1 && /^name:[[:space:]]*/ {
      if (!seen_name) {
        seen_name = 1
        v = $0; sub(/^name:[[:space:]]*/, "", v); sub(/\r$/, "", v)
        if (v == "shepherd" || v == "\"shepherd\"" || v == "\047shepherd\047") ok_name = 1
      }
    }
    fence == 1 && /^description:[[:space:]]*/ {
      d = $0; sub(/^description:[[:space:]]*/, "", d); sub(/\r$/, "", d)
      sub(/[[:space:]]+$/, "", d)
      h = d; sub(/[[:space:]]#.*$/, "", h); sub(/[[:space:]]+$/, "", h)
      if (h ~ /^[|>]([0-9]*[+-]?|[+-][0-9]*)$/) { in_block = 1; next }
      if (d != "" && d != "\"\"" && d != "\047\047" &&
          d != "null" && d != "Null" && d != "NULL" && d != "~" &&
          d != "[]" && d != "{}" && d !~ /^#/) ok_desc = 1
      next
    }
    fence == 1 && in_block {
      if ($0 ~ /^[^[:space:]]/) in_block = 0
      else if ($0 ~ /[^[:space:]]/) { ok_desc = 1; in_block = 0 }
    }
    END { exit (fence >= 2 && ok_name && ok_desc) ? 0 : 1 }
  ' "$SKILLS_SOURCE_SHEPHERD_SKILL"
}
if classifier_skill_frontmatter_ok; then
    SHIPS_CLASSIFIER_NATIVELY=true
else
    SHIPS_CLASSIFIER_NATIVELY=false
fi
SUPERSEDEDCOMPOSE
# The final hand-written YAML grammar, before a real parser replaced it. It
# accepted an illegal `|0`, a two-digit `|10`, and the spaced flow forms
# `[ ]`/`{ }` — the shapes that ended the enumerate-a-spelling-per-round cycle.
freeze_classifier_probe value-grammar <<'SUPERSEDEDGRAMMAR'
SKILLS_SOURCE_SHEPHERD_SKILL="ai/skills/universal/shepherd/SKILL.md"
classifier_skill_frontmatter_ok() {
  awk '
    NR == 1 && $0 != "---" { exit }
    $0 == "---" { fence++; if (fence >= 2) exit; next }
    fence == 1 && /^name:[[:space:]]*/ {
      if (!seen_name) {
        seen_name = 1
        v = $0; sub(/^name:[[:space:]]*/, "", v); sub(/\r$/, "", v)
        if (v == "shepherd" || v == "\"shepherd\"" || v == "\047shepherd\047") ok_name = 1
      }
    }
    fence == 1 && /^description:[[:space:]]*/ {
      d = $0; sub(/^description:[[:space:]]*/, "", d); sub(/\r$/, "", d)
      sub(/[[:space:]]#.*$/, "", d); sub(/[[:space:]]+$/, "", d)
      if (d ~ /^[|>]([0-9]*[+-]?|[+-][0-9]*)$/) { in_block = 1; next }
      if (d != "" && d != "\"\"" && d != "\047\047" &&
          d != "null" && d != "Null" && d != "NULL" && d != "~" &&
          d != "[]" && d != "{}" && d !~ /^#/) ok_desc = 1
      next
    }
    fence == 1 && in_block {
      if ($0 ~ /^[^[:space:]]/) in_block = 0
      else if ($0 ~ /[^[:space:]]/) { ok_desc = 1; in_block = 0 }
    }
    END { exit (fence >= 2 && ok_name && ok_desc) ? 0 : 1 }
  ' "$SKILLS_SOURCE_SHEPHERD_SKILL"
}
if classifier_skill_frontmatter_ok; then
    SHIPS_CLASSIFIER_NATIVELY=true
else
    SHIPS_CLASSIFIER_NATIVELY=false
fi
SUPERSEDEDGRAMMAR
# Every frozen probe must still be a runnable program. A control that silently
# became unparseable would report `false` for the wrong reason, which for a
# control expecting a reject is a passing test that proves nothing.
for frozen_key in usage-strings frontmatter-greps code-pipeline skill-probes \
    desc-header header-ordering value-composition value-grammar; do
    expect_ok "frozen control $frozen_key is a runnable snippet" \
        sh -c 'test -s "$1" && bash -n "$1"' sh \
        "$CLASSIFIER_FROZEN_DIR/$frozen_key.sh"
done
CLS_FULL="$TMPROOT/classifier-dispatch"
CLS_MODE="$TMPROOT/classifier-nonexec"
CLS_NOSKILL="$TMPROOT/classifier-untracked-skill"
CLS_BADFM="$TMPROOT/classifier-bad-frontmatter"
CLS_USAGE="$TMPROOT/classifier-usage-stub"
CLS_STUB="$TMPROOT/classifier-empty-stub"
CLS_QUOTED="$TMPROOT/classifier-quoted-name"
CLS_SCALAR="$TMPROOT/classifier-block-scalar"
CLS_UNCLOSED="$TMPROOT/classifier-unclosed-frontmatter"
CLS_BODYONLY="$TMPROOT/classifier-body-only-keys"
CLS_EMPTYDQ="$TMPROOT/classifier-empty-dq-description"
CLS_EMPTYSQ="$TMPROOT/classifier-empty-sq-description"
CLS_COMMENTDESC="$TMPROOT/classifier-comment-description"
CLS_PADDED="$TMPROOT/classifier-padded-dispatch"
CLS_NULLDESC="$TMPROOT/classifier-null-description"
CLS_TILDEDESC="$TMPROOT/classifier-tilde-description"
CLS_EMPTYSCALAR="$TMPROOT/classifier-empty-block-scalar"
CLS_FLOWSEQ="$TMPROOT/classifier-empty-flow-description"
CLS_SYMLINK="$TMPROOT/classifier-symlinked-entry-point"
CLS_CMTHDR="$TMPROOT/classifier-commented-header-empty"
CLS_CMTHDROK="$TMPROOT/classifier-commented-header-content"
CLS_CMTPIPE="$TMPROOT/classifier-commented-pipe-empty"
CLS_INLINECMT="$TMPROOT/classifier-inline-comment-value"
CLS_CHOMPFOLD="$TMPROOT/classifier-chomp-first-fold"
CLS_CHOMPLIT="$TMPROOT/classifier-chomp-first-literal"
CLS_CHOMPOK="$TMPROOT/classifier-chomp-first-content"
CLS_NULLCMT="$TMPROOT/classifier-null-with-comment"
CLS_DQCMT="$TMPROOT/classifier-empty-dq-with-comment"
CLS_TILDECMT="$TMPROOT/classifier-tilde-with-comment"
CLS_FLOWCMT="$TMPROOT/classifier-flow-with-comment"
CLS_QUOTEDNULL="$TMPROOT/classifier-quoted-null-value"
CLS_IND0="$TMPROOT/classifier-zero-indent-indicator"
CLS_IND10="$TMPROOT/classifier-two-digit-indent-indicator"
CLS_SPSEQ="$TMPROOT/classifier-spaced-flow-sequence"
CLS_SPMAP="$TMPROOT/classifier-spaced-flow-mapping"
make_classifier_fixture "$CLS_FULL" +x valid dispatch
make_classifier_fixture "$CLS_MODE" -x valid dispatch
make_classifier_fixture "$CLS_NOSKILL" +x untracked dispatch
make_classifier_fixture "$CLS_BADFM" +x nofrontmatter dispatch
make_classifier_fixture "$CLS_USAGE" +x valid usage
make_classifier_fixture "$CLS_STUB" +x valid empty
make_classifier_fixture "$CLS_QUOTED" +x quotedname dispatch
make_classifier_fixture "$CLS_SCALAR" +x blockscalar dispatch
make_classifier_fixture "$CLS_UNCLOSED" +x unclosed dispatch
make_classifier_fixture "$CLS_BODYONLY" +x bodyonly dispatch
make_classifier_fixture "$CLS_EMPTYDQ" +x emptydq dispatch
make_classifier_fixture "$CLS_EMPTYSQ" +x emptysq dispatch
make_classifier_fixture "$CLS_COMMENTDESC" +x commentdesc dispatch
make_classifier_fixture "$CLS_PADDED" +x valid padded
make_classifier_fixture "$CLS_NULLDESC" +x nulldesc dispatch
make_classifier_fixture "$CLS_TILDEDESC" +x tildedesc dispatch
make_classifier_fixture "$CLS_EMPTYSCALAR" +x emptyscalar dispatch
make_classifier_fixture "$CLS_FLOWSEQ" +x flowseqdesc dispatch
make_classifier_symlink_fixture "$CLS_SYMLINK"
make_classifier_fixture "$CLS_CMTHDR" +x commentedheader dispatch
make_classifier_fixture "$CLS_CMTHDROK" +x commentedheadercontent dispatch
make_classifier_fixture "$CLS_CMTPIPE" +x commentedpipe dispatch
make_classifier_fixture "$CLS_INLINECMT" +x inlinecomment dispatch
make_classifier_fixture "$CLS_CHOMPFOLD" +x chompfirstfold dispatch
make_classifier_fixture "$CLS_CHOMPLIT" +x chompfirstliteral dispatch
make_classifier_fixture "$CLS_CHOMPOK" +x chompfirstcontent dispatch
make_classifier_fixture "$CLS_NULLCMT" +x nullcomment dispatch
make_classifier_fixture "$CLS_DQCMT" +x emptydqcomment dispatch
make_classifier_fixture "$CLS_TILDECMT" +x tildecomment dispatch
make_classifier_fixture "$CLS_FLOWCMT" +x flowcomment dispatch
make_classifier_fixture "$CLS_QUOTEDNULL" +x quotednull dispatch
make_classifier_fixture "$CLS_IND0" +x indentzero dispatch
make_classifier_fixture "$CLS_IND10" +x indentten dispatch
make_classifier_fixture "$CLS_SPSEQ" +x spacedflowseq dispatch
make_classifier_fixture "$CLS_SPMAP" +x spacedflowmap dispatch
expect_ok_contains "classifier detector accepts a complete skills-source tree" \
    "RESULT=true" classifier_verdict "$CLS_FULL"
# The exec bit is read from the index, never the filesystem: this helper is
# chmod +x on disk and still fails, which is the whole point of the index test.
expect_ok_contains "classifier detector rejects a helper staged non-executable" \
    "RESULT=false" classifier_verdict "$CLS_MODE"
expect_ok_contains "classifier detector rejects an untracked shepherd entry point" \
    "RESULT=false" classifier_verdict "$CLS_NOSKILL"
expect_ok_contains "classifier detector rejects a SKILL.md without frontmatter" \
    "RESULT=false" classifier_verdict "$CLS_BADFM"
# Frontmatter acceptance mirrors verify-skills.sh: a matched pair of quotes
# around the name is valid YAML that script accepts, and the folded block
# scalar is the form the real SKILL.md actually uses.
expect_ok_contains "classifier detector accepts a double-quoted skill name" \
    "RESULT=true" classifier_verdict "$CLS_QUOTED"
expect_ok_contains "classifier detector accepts a folded block-scalar description" \
    "RESULT=true" classifier_verdict "$CLS_SCALAR"
# ...and rejects what only LOOKS like frontmatter. An unterminated block reads
# fine line-by-line while a real YAML parser sees none at all, and keys sitting
# in the body after a closed empty block are not frontmatter either.
expect_ok_contains "classifier detector rejects an unclosed frontmatter block" \
    "RESULT=false" classifier_verdict "$CLS_UNCLOSED"
expect_ok_contains "classifier detector rejects name and description in the body" \
    "RESULT=false" classifier_verdict "$CLS_BODYONLY"
# "Non-empty" has to mean non-empty to YAML, not to grep: each of these carries
# text after the colon and still loads as null or nothing. Full YAML comment
# semantics stay out of scope — an inline `#` after a real value is left alone.
expect_ok_contains "classifier detector rejects a double-quoted empty description" \
    "RESULT=false" classifier_verdict "$CLS_EMPTYDQ"
expect_ok_contains "classifier detector rejects a single-quoted empty description" \
    "RESULT=false" classifier_verdict "$CLS_EMPTYSQ"
expect_ok_contains "classifier detector rejects a comment-only description" \
    "RESULT=false" classifier_verdict "$CLS_COMMENTDESC"
# The null spellings and empty flow forms are all whole-value matches, so a real
# description that merely starts with one of those words is unaffected.
expect_ok_contains "classifier detector rejects a null description" \
    "RESULT=false" classifier_verdict "$CLS_NULLDESC"
expect_ok_contains "classifier detector rejects a tilde-null description" \
    "RESULT=false" classifier_verdict "$CLS_TILDEDESC"
expect_ok_contains "classifier detector rejects an empty flow-sequence description" \
    "RESULT=false" classifier_verdict "$CLS_FLOWSEQ"
# A block-scalar header is not a value: it is followed to the end of the block,
# which here is the closing fence with nothing in between.
expect_ok_contains "classifier detector rejects an empty block-scalar description" \
    "RESULT=false" classifier_verdict "$CLS_EMPTYSCALAR"
expect_ok_contains "classifier detector rejects an empty block scalar under pipefail" \
    "RESULT=false" classifier_verdict_pipefail "$CLS_EMPTYSCALAR"
# A block-scalar header may legally carry a trailing comment. That form misses a
# bare header regex and lands in the value branch, where it is non-empty and so
# passes — an empty block granted the waiver. The header test therefore runs on
# a comment-stripped copy, while the value branch keeps the ORIGINAL, so a real
# value with a trailing comment is not silently truncated into one.
expect_ok_contains "classifier detector rejects an empty commented block-scalar header" \
    "RESULT=false" classifier_verdict "$CLS_CMTHDR"
expect_ok_contains "classifier detector rejects an empty commented header under pipefail" \
    "RESULT=false" classifier_verdict_pipefail "$CLS_CMTHDR"
expect_ok_contains "classifier detector rejects an empty commented literal header" \
    "RESULT=false" classifier_verdict "$CLS_CMTPIPE"
expect_ok_contains "classifier detector accepts a commented header with block content" \
    "RESULT=true" classifier_verdict "$CLS_CMTHDROK"
expect_ok_contains "classifier detector accepts a value with a trailing comment" \
    "RESULT=true" classifier_verdict "$CLS_INLINECMT"
# YAML allows the block header's indicators in either order — `|2-` and `|-2`
# are both legal — so a chomp-first header missed an indent-first test and its
# empty block passed as a value. The alternation closes the grammar: there is
# no remaining legal spelling that reaches the value branch.
expect_ok_contains "classifier detector rejects an empty chomp-first folded header" \
    "RESULT=false" classifier_verdict "$CLS_CHOMPFOLD"
expect_ok_contains "classifier detector rejects an empty chomp-first header under pipefail" \
    "RESULT=false" classifier_verdict_pipefail "$CLS_CHOMPFOLD"
expect_ok_contains "classifier detector rejects an empty chomp-first literal header" \
    "RESULT=false" classifier_verdict "$CLS_CHOMPLIT"
expect_ok_contains "classifier detector accepts a chomp-first header with content" \
    "RESULT=true" classifier_verdict "$CLS_CHOMPOK"
# A comment composes with every other null spelling, so each had to be checked
# on the stripped scalar rather than the raw one. These are that composition.
expect_ok_contains "classifier detector rejects a null description with a comment" \
    "RESULT=false" classifier_verdict "$CLS_NULLCMT"
expect_ok_contains "classifier detector rejects a null-with-comment under pipefail" \
    "RESULT=false" classifier_verdict_pipefail "$CLS_NULLCMT"
expect_ok_contains "classifier detector rejects empty quotes with a comment" \
    "RESULT=false" classifier_verdict "$CLS_DQCMT"
expect_ok_contains "classifier detector rejects a tilde-null with a comment" \
    "RESULT=false" classifier_verdict "$CLS_TILDECMT"
expect_ok_contains "classifier detector rejects an empty flow form with a comment" \
    "RESULT=false" classifier_verdict "$CLS_FLOWCMT"
# The other side of the same change: stripping must not turn real values into
# rejections. A quoted "null" is a string, not YAML's null, and keeps its quotes
# through the strip — so it is a description and stays accepted.
expect_ok_contains "classifier detector accepts a quoted null string as a value" \
    "RESULT=true" classifier_verdict "$CLS_QUOTEDNULL"
# The last two grammar findings, and the reason the grammar is now a parser's
# job: an illegal `|0`, a two-digit `|10`, and the spaced flow forms are all
# shapes a hand-written regex accepted and YAML does not.
expect_ok_contains "classifier detector rejects a zero indentation indicator" \
    "RESULT=false" classifier_verdict "$CLS_IND0"
expect_ok_contains "classifier detector rejects a zero indent indicator under pipefail" \
    "RESULT=false" classifier_verdict_pipefail "$CLS_IND0"
expect_ok_contains "classifier detector rejects a two-digit indentation indicator" \
    "RESULT=false" classifier_verdict "$CLS_IND10"
expect_ok_contains "classifier detector rejects a spaced empty flow sequence" \
    "RESULT=false" classifier_verdict "$CLS_SPSEQ"
expect_ok_contains "classifier detector rejects a spaced empty flow mapping" \
    "RESULT=false" classifier_verdict "$CLS_SPMAP"
# Every content probe reads straight through a symlink; only the index mode
# distinguishes it, which is why the entry point is mode-checked like the
# classifier path. verify-skills.sh takes the same stance by finding with -type f.
expect_ok_contains "classifier detector rejects a symlinked shepherd entry point" \
    "RESULT=false" classifier_verdict "$CLS_SYMLINK"
expect_ok_contains "classifier detector rejects a symlinked entry point under pipefail" \
    "RESULT=false" classifier_verdict_pipefail "$CLS_SYMLINK"
# The symlink fixture must be a genuine 120000 pointing at a valid file, or the
# rejection above would be proving something else entirely.
expect_ok "symlinked entry point fixture stages a real 120000 symlink" \
    sh -c 'test "$(git -C "$1" ls-files --stage -- "$2" | cut -c1-6)" = 120000 &&
        test -L "$1/$2" && test -f "$1/$2"' sh \
    "$CLS_SYMLINK" "$CLASSIFIER_SKILL_REL"
expect_ok_contains "classifier detector rejects a tracked executable stub" \
    "RESULT=false" classifier_verdict "$CLS_STUB"
# The negative control, and the reason this round exists. The comment-only stub
# is tracked, 100755, at the right path, beside a valid SKILL.md, and prints all
# five usage forms — so the usage-string detector waived all three guards for
# it, and shepherd's `check` would then read its exit 0 as clean evidence.
# Structural anchors reject it. Both halves are asserted: a reject case whose
# predecessor also rejected it would prove nothing was hardened.
expect_ok_contains "superseded detector accepted a comment-only usage stub" \
    "RESULT=true" classifier_verdict_frozen usage-strings "$CLS_USAGE"
expect_ok_contains "classifier detector rejects a comment-only usage stub" \
    "RESULT=false" classifier_verdict "$CLS_USAGE"
# The frontmatter negative control, both directions of the same defect.
expect_ok_contains "superseded frontmatter greps rejected a valid quoted name" \
    "RESULT=false" classifier_verdict_frozen frontmatter-greps "$CLS_QUOTED"
expect_ok_contains "superseded frontmatter greps accepted body-only keys" \
    "RESULT=true" classifier_verdict_frozen frontmatter-greps "$CLS_BODYONLY"
# This checkout ships the real thing, so the detector must say so. This is also
# what keeps every anchor above honest: they are asserted against the helper's
# actual dispatch and exit contract, not just against the doc that greps them.
expect_ok_contains "classifier detector accepts this repo as a skills source" \
    "RESULT=true" classifier_verdict "$repo"
# Every verdict above runs under `bash -eu`. Re-run the two ends of the range
# under `bash -euo pipefail` as well: an accept on the real 40 KB classifier,
# where every anchor matches early and any early-exit pipeline would blow up,
# and a reject, which exercises the paths that short-circuit instead.
expect_ok_contains "classifier detector accepts this repo under pipefail too" \
    "RESULT=true" classifier_verdict_pipefail "$repo"
expect_ok_contains "classifier detector rejects a usage stub under pipefail too" \
    "RESULT=false" classifier_verdict_pipefail "$CLS_USAGE"
# The negative control for that pair: the superseded pipeline probe answers
# `true` under `bash -eu` and `false` under `bash -euo pipefail` on the SAME
# input. The mode, not the input, decided the verdict — which is why a
# `-eu`-only harness could not see it, and why it denied harmon-devkit its own
# waiver.
#
# It runs against the PADDED fixture, not the real checkout, and that is
# deliberate. Whether `grep -q` exits before the upstream stages finish writing
# is a race: on the real 40 KB classifier the superseded probe fails
# intermittently — observed both ways across repeated runs — so pinning the
# control there would have bought a flaky test to demonstrate a real defect.
# ~1 MB of filler after the match makes the writer certain to still be blocked,
# so the control is deterministic while testing the same failure.
expect_ok_contains "superseded pipeline probe passed under bash -eu" \
    "RESULT=true" classifier_verdict_frozen code-pipeline "$CLS_PADDED"
expect_ok_contains "superseded pipeline probe failed under pipefail" \
    "RESULT=false" \
    classifier_verdict_frozen_pipefail code-pipeline "$CLS_PADDED"
# And the fix, on the input that defeats the old form: same fixture, both modes.
expect_ok_contains "classifier detector accepts a padded helper under bash -eu" \
    "RESULT=true" classifier_verdict "$CLS_PADDED"
expect_ok_contains "classifier detector accepts a padded helper under pipefail" \
    "RESULT=true" classifier_verdict_pipefail "$CLS_PADDED"
# Negative controls for this round: both shapes waived all three guards under
# the superseded SKILL.md probes, so the rejections above are a behavior change
# rather than an assertion about code that was already strict enough.
expect_ok_contains "superseded skill probes accepted a null description" \
    "RESULT=true" \
    classifier_verdict_frozen skill-probes "$CLS_NULLDESC"
expect_ok_contains "superseded skill probes accepted an empty block scalar" \
    "RESULT=true" \
    classifier_verdict_frozen skill-probes "$CLS_EMPTYSCALAR"
expect_ok_contains "superseded skill probes accepted a symlinked entry point" \
    "RESULT=true" \
    classifier_verdict_frozen skill-probes "$CLS_SYMLINK"
# Negative control for the commented header, plus the accept it had to preserve:
# the bare-regex version passed the empty block AND the real trailing-comment
# value, so only the reject is a behavior change.
expect_ok_contains "superseded header regex accepted an empty commented header" \
    "RESULT=true" \
    classifier_verdict_frozen desc-header "$CLS_CMTHDR"
expect_ok_contains "superseded header regex also accepted a trailing-comment value" \
    "RESULT=true" \
    classifier_verdict_frozen desc-header "$CLS_INLINECMT"
# Negative control for the header ordering, with the accept it had to preserve.
expect_ok_contains "superseded header ordering accepted an empty chomp-first header" \
    "RESULT=true" \
    classifier_verdict_frozen header-ordering "$CLS_CHOMPFOLD"
expect_ok_contains "superseded header ordering still handled indent-first headers" \
    "RESULT=false" \
    classifier_verdict_frozen header-ordering "$CLS_EMPTYSCALAR"
# Negative control for the composition fix, with the accepts it had to preserve.
expect_ok_contains "superseded value checks accepted a null with a comment" \
    "RESULT=true" \
    classifier_verdict_frozen value-composition "$CLS_NULLCMT"
expect_ok_contains "superseded value checks accepted empty quotes with a comment" \
    "RESULT=true" \
    classifier_verdict_frozen value-composition "$CLS_DQCMT"
expect_ok_contains "superseded value checks already rejected a bare null" \
    "RESULT=false" \
    classifier_verdict_frozen value-composition "$CLS_NULLDESC"
# Negative control for replacing the grammar with a parser: the hand-written
# version accepted all four of the shapes YAML itself rejects, while still
# handling everything it had already been taught.
expect_ok_contains "superseded grammar accepted a zero indentation indicator" \
    "RESULT=true" classifier_verdict_frozen value-grammar "$CLS_IND0"
expect_ok_contains "superseded grammar accepted a two-digit indent indicator" \
    "RESULT=true" classifier_verdict_frozen value-grammar "$CLS_IND10"
expect_ok_contains "superseded grammar accepted a spaced empty flow sequence" \
    "RESULT=true" classifier_verdict_frozen value-grammar "$CLS_SPSEQ"
expect_ok_contains "superseded grammar accepted a spaced empty flow mapping" \
    "RESULT=true" classifier_verdict_frozen value-grammar "$CLS_SPMAP"
expect_ok "audit G4 waives sync/universal for the native skills-source classifier" \
    sh -c 'grep -qF "unless the repo is the skills source itself" "$1" &&
        grep -qF "git-tracked, non-symlink executable" "$1" &&
        grep -qF "check-codex-cloud-review.sh" "$1"' sh \
    "$STANDARDIZE_REFS/mode-audit.md"
# The audit prose has to describe the same three probes the update guard runs,
# or a repo passes one mode and is reported as drift by the other.
expect_ok "audit G4 names the entry-point and dispatch-structure requirements" \
    sh -c 'grep -qF "ai/skills/universal/shepherd/SKILL.md" "$1" &&
        grep -qF "resolve to the string \`shepherd\`" "$1" &&
        grep -qF "dispatch \`case\` arms" "$1" &&
        grep -qF "emit escalate" "$1" &&
        grep -qF "exit 13" "$1" &&
        grep -qF "comments merely print" "$1" &&
        grep -qF "never that it runs" "$1" &&
        grep -qF "scripts/verify-skills.sh" "$1" &&
        grep -qF "resolved by **yq**" "$1" &&
        grep -qF "120000" "$1"' sh \
    "$STANDARDIZE_REFS/mode-audit.md"
expect_ok "standards catalog waives cloud-review sync/universal for the skills source" \
    sh -c 'grep -qF "except on a skills-source" "$1" &&
        grep -qF "may keep" "$1" &&
        grep -qF "as above and in G4" "$1" &&
        grep -qF "git-tracked, non-symlink executable" "$1" &&
        grep -qF "check-codex-cloud-review.sh" "$1"' sh \
    "$STANDARDIZE_REFS/standards-catalog.md"
expect_ok "standards catalog names the entry-point and dispatch-structure requirements" \
    sh -c 'grep -qF "ai/skills/universal/shepherd/SKILL.md" "$1" &&
        grep -qF "resolve to the string \`shepherd\`" "$1" &&
        grep -qF "dispatch \`case\` arms" "$1" &&
        grep -qF "emit escalate" "$1" &&
        grep -qF "exit 13" "$1" &&
        grep -qF "prints the usage forms in comments" "$1" &&
        grep -qF "rather than that it works" "$1" &&
        grep -qF "scripts/verify-skills.sh" "$1" &&
        grep -qF "resolved by **yq**" "$1" &&
        grep -qF "120000" "$1" &&
        grep -qF "canonical for layout" "$1"' sh \
    "$STANDARDIZE_REFS/standards-catalog.md"
expect_ok "new-repo and adopt guidance note the skills-source waiver" \
    sh -c 'grep -qF "waived only for a skills-source repo already shipping the shepherd classifier" "$1" &&
        grep -qF "already ships that classifier natively is exempt" "$2"' sh \
    "$STANDARDIZE_REFS/mode-new-repo.md" \
    "$STANDARDIZE_REFS/mode-adopt-existing.md"
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
expect_ok "shepherd fails closed on a pre-promotion head mismatch" \
    sh -c 'grep -qF "the first mismatch. Step 5" "$1" &&
        grep -qF "Never wait out a pre-promotion" "$1"' sh "$SHEPHERD_SKILL"
expect_ok "shepherd reconciles partial or raced promotion" \
    sh -c 'grep -qF "response can be lost" "$1" &&
        grep -qF "gh pr ready --undo <n> --repo" "$1" &&
        grep -qF "non-draft on a changed head" "$1" &&
        grep -qF "report must name that unresolved" "$1" &&
        grep -qF "remote-state risk" "$1"' sh "$SHEPHERD_SKILL"
expect_ok "shepherd paginates the draft-conversion undo guard" \
    sh -c 'grep -qF "/assets/gh-ro.sh --paginate repos/\"\$repo\"/issues/<n>/timeline" "$1" &&
        grep -qF "convert_to_draft" "$1"' sh "$SHEPHERD_SKILL"
expect_ok "shepherd bounds the undo per PR across sessions" \
    grep -qF 'the bound is per PR, across sessions' "$SHEPHERD_SKILL"
expect_ok "shepherd freezes review content across promotion" \
    sh -c 'grep -qF "top-level comments, inline comments" "$1" &&
        grep -qF "GraphQL review-thread resolution" "$1" &&
        grep -qF "readiness-gate.sh fingerprint --repo" "$1" &&
        grep -qF "re-read the content fingerprint" "$1" &&
        grep -qF "identical to the passing gate" "$1"' sh \
    "$SHEPHERD_SKILL"
expect_ok "shepherd settles automation before final ready promotion" \
    sh -c 'grep -qF "cannot be used as an automation" "$1" &&
        grep -qF "pull_request.ready_for_review" "$1" &&
        grep -qF "final lifecycle transition" "$1" &&
        grep -qF "coordination cleanup" "$1" &&
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
expect_ok "shepherd names all three Codex Automatic-review knobs" \
    sh -c 'grep -qF "personal **Auto review** off" "$1" &&
        grep -qF "**Auto code review**" "$1" &&
        grep -qF "review **Trigger**" "$1"' sh "$SHEPHERD_SKILL"
expect_ok "standardization setup disables Codex Automatic reviews" \
    sh -c 'grep -qF "Disable **Codex Automatic reviews**" "$1/post-generation-checklist.md" &&
        grep -qF "human-confirmed disabled" "$1/mode-audit.md"' sh "$STANDARDIZE_REFS"
expect_ok "standardization setup names the Codex review Trigger knob" \
    grep -qF 'review **Trigger** on Follow personal' \
    "$STANDARDIZE_REFS/post-generation-checklist.md"
expect_ok "standardization hands off only a ready-for-review PR" \
    sh -c 'grep -qF "open a draft PR" "$1" &&
        grep -qF "Gate the staged rollout against the target policy" "$1" &&
        grep -qF "reviews.auto_review.drafts: true" "$1" &&
        grep -qF "draft-time checks/review gate and final promotion" "$1" &&
        grep -qF "If the target has no vendored shepherd" "$1" &&
        grep -qF "or four rounds when it states none" "$1" &&
        grep -qF "ready on an unverified head" "$1" &&
        grep -qF "final ready promotion is confirmed" "$1"' sh \
    "$STANDARDIZE_SKILL"
expect_ok "standardization modes gate staged lifecycle compatibility" \
    sh -c 'grep -qF "rendered target `AGENTS.md`" "$1/mode-update.md" &&
        grep -qF "rendered target `AGENTS.md`" "$1/mode-audit.md" &&
        grep -qF "generated target `AGENTS.md`" "$1/mode-new-repo.md" &&
        grep -qF "reviews.auto_review.drafts: true" "$1/post-generation-checklist.md" &&
        grep -qF "older target policy remains" "$1/standards-catalog.md"' sh \
    "$STANDARDIZE_REFS"
expect_ok "root policy keeps ready as the final human handoff" \
    sh -c 'grep -qF "pull_request.ready_for_review" "$1" &&
        grep -qF "configuration" "$1" &&
        grep -qF "Then run `gh pr ready`" "$1"' sh \
    "$repo/AGENTS.md"
expect_ok "standardization modes use the draft-workbench handoff" \
    sh -c 'grep -qF "open a draft PR" "$1/mode-audit.md" &&
        grep -qF "open a draft PR" "$1/mode-update.md" &&
        grep -qF "draft-workbench lifecycle" "$1/mode-new-repo.md" &&
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
# Every `comm` in the guarded-update recipe reads files a `LC_ALL=C sort -u`
# produced. Left unpinned it re-derives the ordering under whatever locale the
# copying shell happens to carry — a UTF-8 collation orders `_` against letters
# differently than byte order does — then rejects its own input with `file 1 is
# not in sorted order` and exits 1 straight into the snippet's `|| { …; exit 1;
# }` handler. Counting instead of asserting a literal keeps the invariant true
# as sites are added: an unpinned newcomer moves one total and not the other.
expect_ok "update guidance pins collation on every comm invocation" \
    sh -c 'total="$(grep -cE "comm -[0-9]" "$1")"
        pinned="$(grep -cE "LC_ALL=C comm -[0-9]" "$1")"
        test "$total" -gt 0 && test "$total" -eq "$pinned"' sh \
    "$STANDARDIZE_REFS/mode-update.md"
# The §1 non-adoption classifier is lifted out of the doc and RUN against the
# guarded-update fixture far below, so the marker pair has to stay unique: a
# second copy of either marker would make the sed range swallow whatever sits
# between them and hand `bash -eu` a truncated program.
GU_NONADOPT_SNIPPET="$TMPROOT/nonadoption-classify.sh"
sed -n '/# >>> nonadoption-classify >>>/,/# <<< nonadoption-classify <<</p' \
    "$STANDARDIZE_REFS/mode-update.md" >"$GU_NONADOPT_SNIPPET"
expect_ok "non-adoption snippet carries exactly one extraction marker pair" \
    sh -c 'test "$(grep -cF "# >>> nonadoption-classify >>>" "$1")" -eq 1 &&
        test "$(grep -cF "# <<< nonadoption-classify <<<" "$1")" -eq 1' sh \
    "$STANDARDIZE_REFS/mode-update.md"
# The same count invariant as the file-wide one above, scoped to the extracted
# snippet — it reads two `LC_ALL=C sort -u` inventories, so an unpinned `comm`
# rejects its own input under an ambient UTF-8 locale. Counting rather than
# asserting three literals keeps this true as sites are added.
expect_ok "non-adoption snippet pins collation on every comm invocation" \
    sh -c 'total="$(grep -cE "comm -[0-9]" "$1")"
        pinned="$(grep -cE "LC_ALL=C comm -[0-9]" "$1")"
        test "$total" -gt 0 && test "$total" -eq "$pinned"' sh \
    "$GU_NONADOPT_SNIPPET"
# `changed_in_range` on its own, against modes this suite can actually create.
# The probe used `test -x`, which answers "may THIS process execute this file
# HERE" — a fact about the mount and the caller, not about the render. A noexec
# mount cannot be arranged in a test, but the same discrimination shows in a
# mode whose exec bits are set for somebody other than the owner: `test -x` is
# false on both sides while the STORED bits differ, which is precisely the shape
# that used to report `no` for a real mode-only change.
GU_CIR="$TMPROOT/nonadoption-changed-in-range.sh"
{
    printf '%s\n' 'set -eu'
    sed -n '/^  nonadoption_stored_mode() {/,/^  }$/p' "$GU_NONADOPT_SNIPPET"
    sed -n '/^  nonadoption_changed_in_range() {/,/^  }$/p' "$GU_NONADOPT_SNIPPET"
    printf '%s\n' 'nonadoption_changed_in_range "$1"'
} >"$GU_CIR"
expect_ok "the changed_in_range probe is extractable from the snippet" \
    sh -c 'grep -qF "nonadoption_stored_mode() {" "$1" &&
        grep -qF "nonadoption_changed_in_range() {" "$1"' sh "$GU_CIR"
# The stance itself, so a later edit cannot quietly reintroduce the effective
# test: the probe must read stored bits and never ask about executability here.
expect_ok "the changed_in_range probe reads stored bits, not effective access" \
    sh -c 'grep -qF "ls -ld --" "$1" &&
        ! grep -qE "test !? ?-x \"\\\$NONADOPT_(BASE|TGT)\"" "$1"' sh \
    "$GU_NONADOPT_SNIPPET"
GU_CIR_BASE="$TMPROOT/changed-in-range/baseline"
GU_CIR_TGT="$TMPROOT/changed-in-range/target"
mkdir -p "$GU_CIR_BASE" "$GU_CIR_TGT"
gu_cir() {
    BASELINE_DISCOVERY="$GU_CIR_BASE" TARGET_DISCOVERY="$GU_CIR_TGT" \
        bash -eu "$GU_CIR" "$1"
}
printf 'same\n' >"$GU_CIR_BASE/same.md"
printf 'same\n' >"$GU_CIR_TGT/same.md"
if [ "$(gu_cir same.md)" = no ]; then
    ok "changed_in_range reports no for an unchanged file"
else
    bad "changed_in_range reports no for an unchanged file"
fi
printf 'baseline\n' >"$GU_CIR_BASE/content.md"
printf 'target\n' >"$GU_CIR_TGT/content.md"
if [ "$(gu_cir content.md)" = yes ]; then
    ok "changed_in_range reports yes for a content change"
else
    bad "changed_in_range reports yes for a content change"
fi
printf 'script\n' >"$GU_CIR_BASE/hook.sh"
printf 'script\n' >"$GU_CIR_TGT/hook.sh"
chmod 644 "$GU_CIR_BASE/hook.sh"
chmod 755 "$GU_CIR_TGT/hook.sh"
if [ "$(gu_cir hook.sh)" = yes ]; then
    ok "changed_in_range reports yes for an ordinary exec-bit change"
else
    bad "changed_in_range reports yes for an ordinary exec-bit change"
fi
# The discrimination case: identical bytes, different STORED bits, and `test -x`
# false on both sides because the owner holds no exec bit either way.
printf 'shared\n' >"$GU_CIR_BASE/other-exec.md"
printf 'shared\n' >"$GU_CIR_TGT/other-exec.md"
chmod 644 "$GU_CIR_BASE/other-exec.md"
chmod 645 "$GU_CIR_TGT/other-exec.md"
# Root is the exception and has to be named rather than tripped over: UID 0
# passes an execute check whenever ANY execute bit is set, so `test -x` reads
# true for the 0645 side and the premise below cannot hold. The stored-mode
# comparison is unaffected — that is the whole point of it — so the fixture
# records why the discrimination is unobservable instead of failing the suite
# for a container that happens to run as root.
if [ "$(id -u)" -eq 0 ]; then
    ok "the changed_in_range mode fixture skips its effective-access premise as root"
elif [ -x "$GU_CIR_BASE/other-exec.md" ] || [ -x "$GU_CIR_TGT/other-exec.md" ]; then
    bad "the changed_in_range mode fixture keeps effective executability equal"
else
    ok "the changed_in_range mode fixture keeps effective executability equal"
fi
if [ "$(gu_cir other-exec.md)" = yes ]; then
    ok "changed_in_range sees a mode change effective executability hides"
else
    bad "changed_in_range sees a mode change effective executability hides"
fi
if [ "$(gu_cir absent.md)" = unknown ]; then
    ok "changed_in_range reports unknown for a path it cannot read"
else
    bad "changed_in_range reports unknown for a path it cannot read"
fi
# §2 promotion deletes $GUARDED_STATE outright, and both §4 and §5 still need
# the report, so it has to be copied somewhere that survives — the git dir,
# same idiom as the deferred-findings notes, BRANCH KEY included. An ordinary
# clone switches branches in place, so one shared file means branch B's update
# overwrites branch A's only copy before A's PR body was ever written.
expect_ok "update guidance persists the non-adoption report past guarded teardown" \
    sh -c 'grep -qF "cp \"\$GUARDED_STATE/nonadoption-report.tsv\"" "$1" &&
        grep -qF -- "--git-path \"guarded-update-nonadoption/\$GUARDED_NONADOPT_BRANCH\"" "$1"' sh \
    "$STANDARDIZE_REFS/mode-update.md"
expect_ok "the non-adoption report is keyed by branch on every path that touches it" \
    sh -c 'test "$(grep -cF -- "guarded-update-nonadoption/\$(git branch --show-current)" \
            "$1")" -eq 2 &&
        ! grep -qE -- "--git-path guarded-update-nonadoption[\"[:space:]]*$" "$1" &&
        grep -qF "detached HEAD" "$1" &&
        grep -qF "mkdir -p \"\$(dirname \"\$GUARDED_NONADOPT_FILE\")\"" "$1"' sh \
    "$STANDARDIZE_REFS/mode-update.md"
# Branch-keying without an orphan sweep just moves the loss: a branch renamed
# mid-update strands its report under the old name, where nothing looks again.
# §2 writes TWO branch-keyed files, so hand-off must sweep and retire both.
# Deleting the report and leaving the verdict left a clean verdict in the git
# directory forever with nothing to describe — the stale-verdict shape §1's entry
# clearing exists to prevent, reintroduced at the very end.
expect_ok "hand-off sweeps both branch-keyed trees for orphans before deleting" \
    sh -c 'grep -qF "ls -R \"\$(git rev-parse --git-path guarded-update-nonadoption)\"" "$1" &&
        grep -qF "ls -R \"\$(git rev-parse --git-path guarded-update-reconciled)\"" "$1" &&
        grep -qF "Sweep BOTH trees for orphans" "$1"' sh \
    "$STANDARDIZE_REFS/mode-update.md"
expect_ok "hand-off retires both branch-keyed files together" \
    sh -c 'grep -qF "HANDOFF_VERDICT" "$1" && grep -qF "HANDOFF_REPORT" "$1" &&
        grep -qF "never the directories" "$1"' sh \
    "$STANDARDIZE_REFS/mode-update.md"
# The ORDER is the fix. A clean verdict with no report beside it is the one
# combination that lies, so the verdict goes first and a failure there stops
# before the report is touched. Asserted on line numbers, because a comment
# saying "verdict first" over a loop that does the opposite would still pass.
expect_ok "hand-off retires the verdict before the report" \
    sh -c 'v="$(grep -nF "rm -f -- \"\$HANDOFF_VERDICT\"" "$1" | cut -d: -f1)"
        r="$(grep -nF "rm -f -- \"\$HANDOFF_REPORT\"" "$1" | cut -d: -f1)"
        test -n "$v" && test -n "$r" && test "$v" -lt "$r" &&
        grep -qF "the report is untouched at" "$1" &&
        grep -qF "either both files still exist or the verdict is already gone" "$1"' sh \
    "$STANDARDIZE_REFS/mode-update.md"
# The schema overview is what a reader meets first; it has to name the labels the
# classifier actually emits, not the ones three redesigns ago.
expect_ok "the schema overview names the classes and notes in use" \
    sh -c 'over="$(grep -n "Silent non-adoption is the one gap" "$1" | cut -d: -f1)"
        seg="$(sed -n "${over},$((over + 22))p" "$1")"
        printf "%s\n" "$seg" | grep -qF "co-owned-prose" &&
        printf "%s\n" "$seg" | grep -qF "known-false-verified" &&
        printf "%s\n" "$seg" | grep -qF "unverified-equivalent" &&
        printf "%s\n" "$seg" | grep -qF "gitkeep" &&
        printf "%s\n" "$seg" | grep -qF "unknown-until-apply"' sh \
    "$STANDARDIZE_REFS/mode-update.md"
expect_fail "no pre-redesign class label survives in the guidance" \
    grep -qE "gitkeep-benign|filtered-known" "$STANDARDIZE_REFS/mode-update.md"
# Grepping the recipe proves it says the right words; running it proves the words
# work. The branch key is a PATH, and this repo's own branch names contain `/` —
# so `mkdir -p "$(dirname …)"` is load-bearing and no grep can show that it fires.
GU_NONADOPT_PERSIST="$TMPROOT/nonadoption-persist.sh"
awk '/^GUARDED_NONADOPT_BRANCH="\$\(git branch --show-current\)"$/ { inblk = 1 }
     inblk && /^```$/ { exit }
     inblk { print }' \
    "$STANDARDIZE_REFS/mode-update.md" >"$GU_NONADOPT_PERSIST"
# An extraction that silently found nothing would run an empty program and pass.
expect_ok "the non-adoption persistence recipe is extractable" \
    sh -c 'test -s "$1" && grep -qF "cp \"\$GUARDED_STATE" "$1"' sh \
    "$GU_NONADOPT_PERSIST"
GU_PERSIST_REPO="$TMPROOT/nonadoption-persist-repo"
git init -q "$GU_PERSIST_REPO" >/dev/null
git -C "$GU_PERSIST_REPO" config user.email test@example.com
git -C "$GU_PERSIST_REPO" config user.name "Test"
git -C "$GU_PERSIST_REPO" commit -q --allow-empty -m seed >/dev/null
# A slashed name, because that is the case `mkdir -p` exists for and the case a
# `/`-folding key would silently collide with `feat-343-report`.
git -C "$GU_PERSIST_REPO" switch -q -c feat/343-report >/dev/null
mkdir -p "$GU_PERSIST_REPO/.copier-guarded-update"
printf 'seeded\tnonadopt-both\tno\tbaseline+target\t-\n' \
    >"$GU_PERSIST_REPO/.copier-guarded-update/nonadoption-report.tsv"
# Persistence refuses an unreconciled report: §2 reconciles first, and a report
# published without that verdict would describe an unverified tree.
printf 'reconciled: clean\n' \
    >"$GU_PERSIST_REPO/.copier-guarded-update/nonadoption-reconciled"
expect_ok "the non-adoption persistence recipe runs clean under bash -eu" \
    sh -c 'cd "$1" && GUARDED_STATE=.copier-guarded-update bash -eu "$2"' sh \
    "$GU_PERSIST_REPO" "$GU_NONADOPT_PERSIST"
expect_ok "the persisted report lands under the branch name verbatim" \
    grep -qxF "$(printf 'seeded\tnonadopt-both\tno\tbaseline+target\t-')" \
    "$GU_PERSIST_REPO/.git/guarded-update-nonadoption/feat/343-report"
# The whole point of the key: a second branch's run must not clobber the first.
git -C "$GU_PERSIST_REPO" switch -q -c feat/other >/dev/null
printf 'other\tnonadopt-both\tno\tbaseline+target\t-\n' \
    >"$GU_PERSIST_REPO/.copier-guarded-update/nonadoption-report.tsv"
expect_ok "a second branch's guarded run persists alongside the first" \
    sh -c 'cd "$1" && GUARDED_STATE=.copier-guarded-update bash -eu "$2"' sh \
    "$GU_PERSIST_REPO" "$GU_NONADOPT_PERSIST"
expect_ok "the first branch's non-adoption report survives the second run" \
    grep -qF seeded \
    "$GU_PERSIST_REPO/.git/guarded-update-nonadoption/feat/343-report"
expect_ok "the second branch's report is written to its own key" \
    grep -qF other "$GU_PERSIST_REPO/.git/guarded-update-nonadoption/feat/other"
# Detached HEAD has no key at all, so the recipe stops rather than guessing one.
git -C "$GU_PERSIST_REPO" switch -q --detach HEAD >/dev/null
expect_fail "the persistence recipe refuses a detached HEAD" \
    sh -c 'cd "$1" && GUARDED_STATE=.copier-guarded-update bash -eu "$2"' sh \
    "$GU_PERSIST_REPO" "$GU_NONADOPT_PERSIST"
expect_ok "update verification re-checks every non-adoption class after the merge" \
    sh -c 'grep -qF "CONFIRMED silent non-adoption" "$1" &&
        grep -qF "the real apply left it in place" "$1" &&
        grep -qF "the real apply did not" "$1"' sh \
    "$STANDARDIZE_REFS/mode-update.md"
# The table is the whole deliverable: classification nobody reads changes
# nothing, so hand-off has to name the section, its columns, and the explicit
# wording for the empty case an omitted section is otherwise indistinguishable
# from.
expect_ok "update hand-off requires a silent non-adoption disposition table" \
    sh -c 'grep -qF "## Silent non-adoption" "$1" &&
        grep -qF "| Path |" "$1" &&
        grep -qF "| Disposition |" "$1" &&
        grep -qF "No unexplained silent" "$1"' sh \
    "$STANDARDIZE_REFS/mode-update.md"
# The worked example is the part an operator actually copies, so a row that
# contradicts the contract above it is worse than no example. The contract says
# the table holds confirmed `nonadopt-both` only and that a `new-in-target`
# anomaly is called out separately; the example put a target-only CodeQL row
# straight into the table. It is the anomaly call-out now — and every remaining
# table row must be one the contract admits.
expect_ok "the hand-off example keeps apply anomalies out of the disposition table" \
    sh -c 'grep -qF "Files the update created — review what landed" "$1" &&
        ! grep -qE "^\| \`\.github/workflows/codeql\.yml\` \|" "$1" &&
        ! grep -qE "^\| \`\.github/CODEOWNERS\` \|" "$1"' sh \
    "$STANDARDIZE_REFS/mode-update.md"
# The directory case aborts the rehearsal before any report exists, so the note
# it used to produce is unreachable. §5 must state the real contract instead of
# instructing a reviewer to disposition a row that can never appear.
expect_ok "the hand-off documents the directory abort, not a phantom note" \
    sh -c 'grep -qF "A directory where the render ships a file never reaches this report" "$1" &&
        test "$(grep -cF "repo-path-is-directory" "$1")" -eq 1' sh \
    "$STANDARDIZE_REFS/mode-update.md"
expect_ok "the hand-off contract carries the note vocabulary" \
    sh -c 'grep -qF "repo-ignored-only" "$1" &&
        grep -qF "unverified-equivalent" "$1" &&
        grep -qF "known-false-verified" "$1" &&
        grep -qF "co-owned-prose" "$1" &&
        grep -qF "twin-exists:" "$1"' sh \
    "$STANDARDIZE_REFS/mode-update.md"
# The two axes, stated in the guidance itself: a class says what the apply does,
# a note says what was found out about it, and the note never removes the row.
expect_ok "update guidance separates transition class from explanation" \
    sh -c 'grep -qF "The classification is an observation, not a prediction" "$1" &&
        grep -qF "The evidence never removes the row" "$1" &&
        grep -qF "grouping, not filtering" "$1"' sh \
    "$STANDARDIZE_REFS/mode-update.md"
# Explained absences are LISTED, one line each, not collapsed to counts — a count
# cannot be audited, which is how five rounds of review each found another
# transition hiding inside one.
expect_ok "explained absences are listed per path, never collapsed to a count" \
    sh -c 'grep -qF "### Explained absences" "$1" &&
        grep -qF "One line each, never a bare count" "$1" &&
        ! grep -qF "Filtered, not silent:" "$1"' sh \
    "$STANDARDIZE_REFS/mode-update.md"
# Only notes that record a DECISION route a row out of the table. `co-owned-prose`
# records none: co-ownership explains why a file the repo HAS differs, and an
# absent file differs from nothing — so an absent docs page is a permanent
# non-adoption exactly like an absent AGENTS.md, and owes a Why and a Disposition.
expect_ok "only decision-bearing notes route a row out of the disposition table" \
    sh -c 'grep -qF "Exactly three answer it" "$1" &&
        grep -qF "\`co-owned-prose\` is on that second list" "$1" &&
        grep -qF "and it is the one note that says" "$1"' sh \
    "$STANDARDIZE_REFS/mode-update.md"
expect_ok "the worked example tables its co-owned absence" \
    sh -c 'grep -qE "^\| \`docs/runbooks/restore\.md\` \|.*co-owned-prose" "$1" &&
        ! grep -qE "^- \`docs/[^\`]*\` — co-owned-prose" "$1"' sh \
    "$STANDARDIZE_REFS/mode-update.md"
# One loop, four classes, no carve-outs — possible only because nothing is
# suppressed out of the report.
# The ordering is the fix: reconcile at the end of §2, before §3's prescribed
# edits, and have §4 read the frozen verdict rather than the tree.
expect_ok "reconciliation runs before the manual reconciliation section" \
    sh -c 'recon="$(grep -nF "nonadoption_reconcile ||" "$1" | cut -d: -f1)"
        s3="$(grep -nE "^## 3\. " "$1" | cut -d: -f1)"
        s4="$(grep -nE "^## 4\. " "$1" | cut -d: -f1)"
        test -n "$recon" && test "$recon" -lt "$s3" &&
        verdict="$(grep -nF "guarded-update-reconciled/" "$1" | head -1 | cut -d: -f1)"
        test "$verdict" -lt "$s3" &&
        later="$(grep -nF "the frozen reconciliation is not clean" "$1" | cut -d: -f1)"
        test "$later" -gt "$s4"' sh \
    "$STANDARDIZE_REFS/mode-update.md"
expect_ok "section 4 verifies the frozen verdict instead of re-reading the tree" \
    sh -c 'grep -qF "Confirm the reconciliation was recorded" "$1" &&
        grep -qF "reconciled: clean" "$1" &&
        grep -qF "Do not re-derive it by re-reading the worktree" "$1" &&
        grep -qF "restored in §3: <reason>" "$1"' sh \
    "$STANDARDIZE_REFS/mode-update.md"
# `--skip-tasks` does not cover `_migrations`; copier runs them unguarded. A
# rehearsal would fire them a second time against a copy.
expect_ok "the rehearsal is refused when the target declares _migrations" \
    sh -c 'grep -qF "_migrations // [] | length" "$1" &&
        grep -qF "NONADOPT_REHEARSED" "$1" &&
        grep -qF "unknown-until-apply" "$1" &&
        grep -qF "migrations must run exactly once" "$1"' sh \
    "$GU_NONADOPT_SNIPPET"
# Zero shared git metadata: a linked worktree's `.git` is a pointer file, and
# copier runs `git write-tree` in the subproject.
expect_ok "the rehearsal builds independent git metadata for the scratch" \
    sh -c 'grep -qF "git clone --no-hardlinks" "$1" &&
        grep -qF "rev-parse --absolute-git-dir" "$1" &&
        grep -qF "refusing to rehearse" "$1" &&
        ! grep -qF "cp -a . \"\$NONADOPT_SCRATCH/repo\"" "$1"' sh \
    "$GU_NONADOPT_SNIPPET"
expect_ok "the post-apply cross-check reconciles every class and fails closed" \
    sh -c 'grep -qF "RECONCILE_BAD" "$1" &&
        grep -qF "reconciliation failed on" "$1" &&
        grep -qF "the real apply created it" "$1" &&
        grep -qF "reconciled: clean" "$1"' sh \
    "$STANDARDIZE_REFS/mode-update.md"
# The persistence write races the branch it is keyed by, so the binding is
# re-checked at the last moment and the write is atomic.
expect_ok "the non-adoption write re-checks its checkout binding and lands atomically" \
    sh -c 'grep -qF "refusing to write the non-adoption report" "$1" &&
        grep -qF "mv \"\$GUARDED_NONADOPT_FILE.\$\$.tmp\" \"\$GUARDED_NONADOPT_FILE\"" "$1" &&
        grep -qF "The binding is re-checked immediately before the write" "$1"' sh \
    "$STANDARDIZE_REFS/mode-update.md"
expect_ok "copier gotchas own the permanent non-adoption reasoning" \
    sh -c 'grep -qE "^## 9\. " "$1" &&
        grep -qF "never adopts a file your baseline already shipped" "$1" &&
        grep -qF "permanent opt-out" "$1"' sh \
    "$STANDARDIZE_REFS/copier-gotchas.md"
# §9 used to say permanence covered files you "never had", full stop. It does
# not: a path the template gained AFTER the recorded baseline is target-only, and
# the update creates it — this suite's own end-to-end fixture asserts exactly
# that. The condition is BOTH renders, and the checklist bullet has to agree with
# the section it summarizes or the summary becomes the version people quote.
expect_ok "gotcha 9 scopes permanence to paths the baseline already shipped" \
    sh -c 'grep -qF "\"Both renders\" is the whole condition" "$1" &&
        grep -qF "is **target-only**" "$1" &&
        grep -qF "MISSING\` a file its baseline already shipped?" "$1" &&
        ! grep -qF "or never had" "$1" &&
        ! grep -qF "is opted out of paths it never saw" "$1"' sh \
    "$STANDARDIZE_REFS/copier-gotchas.md"
# The second carve-out, and the one that runs the other way: `_skip_if_exists`
# on an absent path RECREATES it. A permanence claim that omits this is not
# merely imprecise for CODEOWNERS, it is backwards.
# The Why must name copier's actual mechanism. "Presence in both renders means an
# empty diff" is wrong and predicts the wrong thing: it would have a changed-in-
# range deleted path conflict or come back, and it does neither.
expect_ok "gotcha 9 attributes permanence to copier's exclusion, not an empty diff" \
    sh -c 'grep -qF "not because the diff is empty" "$1" &&
        grep -qF "excludes them from creation" "$1" &&
        grep -qF "The exclusion is explicit, not emergent" "$1"' sh \
    "$STANDARDIZE_REFS/copier-gotchas.md"
# The quick checklist is the version people quote, so it has to name the same
# two carve-outs §9 does — and not name target-only, which is ordinary creation.
expect_ok "the gotcha checklist names both carve-outs and no phantom third" \
    sh -c 'grep -qF "Two carve-outs come" "$1" &&
        grep -qF "render'\''s own" "$1" &&
        grep -qF "is not a" "$1" &&
        ! grep -qF "Two exceptions, both" "$1"' sh \
    "$STANDARDIZE_REFS/copier-gotchas.md"
expect_ok "gotcha 9 carves out _skip_if_exists as a recreate, not a permanence" \
    sh -c 'grep -qF "There are TWO carve-outs" "$1" &&
        grep -qF "it renders the file fresh" "$1" &&
        grep -qF "never in that tree, can never show" "$1" &&
        grep -qF ".github/CODEOWNERS" "$1" &&
        grep -qF "noted `recreated`" "$1"' sh \
    "$STANDARDIZE_REFS/copier-gotchas.md"
expect_ok "audit class K sets _skip_if_exists paths aside before dispositioning" \
    sh -c 'grep -qF "Check BOTH re-creation carve-outs" "$1" &&
        grep -qF "invisible to the deleted-path scan" "$1"' sh \
    "$STANDARDIZE_REFS/mode-audit.md"
# The sweep's own MISSING lines assert permanence inline, so they carry the
# qualifier too — a flat "will NOT restore it" is false for these paths.
expect_ok "the MISSING annotations qualify permanence for _skip_if_exists" \
    sh -c 'test "$(grep -cF \
        "unless _skip_if_exists or the render'\''s own .gitignore covers it" "$1")" -eq 2 &&
        ! grep -qF "a copier update will NOT restore it" "$1"' sh \
    "$STANDARDIZE_ASSETS/diff-template.sh"
expect_ok "update guidance routes created rows to their own list and check" \
    sh -c 'grep -qF "### Files the update created" "$1" &&
        grep -qF "noted \`recreated\`" "$1" &&
        grep -qF "A rehearsal has one way to be" "$1"' sh \
    "$STANDARDIZE_REFS/mode-update.md"
# The empty-result sentence claimed every both-renders path EXISTS in the repo,
# which is false the moment a filtered row exists — and one nearly always does.
expect_ok "the empty-result sentence claims only what the report established" \
    sh -c 'grep -qF "No unexplained silent" "$1" &&
        test "$(grep -cF "every path present in both renders exists" "$1")" \
            -eq 1' sh \
    "$STANDARDIZE_REFS/mode-update.md"
expect_ok "audit drift class K routes MISSING to the non-adoption gotcha" \
    sh -c 'grep -qF "PERMANENT non-adoption candidate" "$1" &&
        grep -qF "(./copier-gotchas.md) §9" "$1"' sh \
    "$STANDARDIZE_REFS/mode-audit.md"
# The snippet duplicates ONE branch of diff-template.sh's `is_co_owned` by hand —
# the `docs/`/`specs/` prose case — because a markdown recipe cannot source a
# shell function. Check the SHAPE, not only the literals: a copy that kept the
# old one-line `docs/* | specs/*) return 0 ;;` still matches a literal `docs/*`
# grep while classifying a missing generated asset as owned prose and collapsing
# it out of the report. So require the tree label to stand alone on its line (the
# pre-filter form cannot) and the Markdown basename test directly under it.
expect_ok "co-owned prose globs agree between diff-template.sh and the non-adoption snippet" \
    sh -c 'for f in "$1" "$2"; do
        grep -A2 -E "^[[:space:]]*docs/\* \| specs/\*\)$" "$f" |
            grep -qF "case \"\${1##*/}\" in" || exit 1
        grep -A2 -E "^[[:space:]]*docs/\* \| specs/\*\)$" "$f" |
            grep -qE "^[[:space:]]*\*\.md\) return 0 ;;$" || exit 1
    done' sh \
    "$STANDARDIZE_ASSETS/diff-template.sh" "$GU_NONADOPT_SNIPPET"
# The pointer to that duplicate has to name the symbol that exists and the
# behaviour it actually has. It named `nonadoption_is_collapsible_prose` and said
# prose absences are collapsed OUT of the report, while the real helper is
# `nonadoption_is_doc_prose` and §5 tables those absences with a note — a comment
# that sends the next edit to a missing function and describes the opposite
# outcome is worse than no comment.
expect_ok "the co-ownership sync comment names the helper that exists" \
    sh -c '! grep -qF "nonadoption_is_collapsible_prose" "$1" &&
        grep -qF "nonadoption_is_doc_prose" "$1"' sh \
    "$STANDARDIZE_ASSETS/diff-template.sh"
expect_ok "the named helper is the one the snippet actually defines" \
    grep -qF "nonadoption_is_doc_prose() {" "$GU_NONADOPT_SNIPPET"
# Every repo-path resolution in diff-template.sh runs through the
# physical-parent guard, equivalence included. `find` does not descend a
# symlinked directory and `resolve_variant` refuses one before the equivalence
# walk is ever reached, so no repro survives today — which is exactly why the
# guard is worth pinning: the invariant should hold because it is checked, not
# because two unrelated behaviours happen to cover for it.
# Every path this script hands git comes from the RENDER's own file names, so a
# `*`, `?`, or `[` in one is a filename and never pathspec magic. Without
# `--literal-pathspecs` a rendered `docs/[a].md` silently answers about
# `docs/a.md` — wrong index mode, wrong staged verdict, and for the clobber gate
# a claim about a file nobody touched.
expect_ok "every pathspec-taking git probe is pinned literal" \
    sh -c 'test "$(grep -cE "(ls-files|ls-tree|diff --cached)[^|]*-- \"" "$1")" -gt 0 &&
        ! grep -nE "git -C \"\\\$target\" (ls-files|ls-tree|diff)" "$1" |
            grep -qv -- "--literal-pathspecs" &&
        test "$(grep -c -- "--literal-pathspecs" "$1")" -ge 3' sh \
    "$STANDARDIZE_ASSETS/diff-template.sh"
expect_ok "the equivalence walk honors the physical-parent guard" \
    sh -c 'test "$(sed -n "/^has_repo_equivalent() {/,/^has_nested_terraform_root() {/p" "$1" |
        grep -c "repo_parent_diverges")" -ge 3 &&
        sed -n "/^has_nested_terraform_root() {/,/^}$/p" "$1" |
            grep -qF "repo_parent_diverges" &&
        sed -n "/^has_nested_terraform_root() {/,/^}$/p" "$1" |
            grep -qF -- "-name .terraform -prune"' sh \
    "$STANDARDIZE_ASSETS/diff-template.sh"
# The REST of the co-owned list must NOT be mirrored. Co-ownership is a content
# exemption and absence is not content, so a missing AGENTS.md or LICENSE is a
# row like any other — now carrying a note instead of vanishing into a count.
expect_ok "the non-adoption snippet treats documentation prose as a note" \
    sh -c 'grep -qF "nonadoption_is_doc_prose" "$1" &&
        grep -qF "nonadoption_add_note co-owned-prose" "$1" &&
        ! grep -qE "^[[:space:]]*(AGENTS\.md|README\.md|SECURITY\.md)[[:space:]]*\|" "$1" &&
        ! grep -qF ".devcontainer/config/zshrc)" "$1"' sh \
    "$GU_NONADOPT_SNIPPET"
# THE structural invariant, and the one that ends the finding family five rounds
# of review kept re-opening: evidence ANNOTATES a row, it never withholds one.
# Concretely — the `class` column may only ever hold a transition class, and the
# former filter classes survive only as note strings. Re-introducing any of them
# as a class is exactly how a path silently stops being reported.
expect_ok "non-adoption evidence annotates rows and never suppresses them" \
    sh -c 'grep -qF "nonadoption_add_note" "$1" &&
        grep -qF "nonadoption_collect_notes" "$1" &&
        ! grep -qF "nonadoption_filtered_class" "$1" &&
        ! grep -qF "NONADOPT_FILTERED" "$1" &&
        ! grep -qE "NONADOPT_CLASS=(co-owned|ignored-policy|filtered-known|gitkeep)" "$1" &&
        ! grep -qF "NONADOPT_FILTERED" "$1"' sh \
    "$GU_NONADOPT_SNIPPET"
expect_ok "the class column carries only the observed classes" \
    sh -c 'assigned="$(grep -oE "NONADOPT_CLASS=[a-z-]+" "$1" |
            sed "s/NONADOPT_CLASS=//" | LC_ALL=C sort -u | paste -sd, -)"
        test "$assigned" = \
            "created,deleted,nonadopt-both,unknown-until-apply"' sh \
    "$GU_NONADOPT_SNIPPET"
# The inversion itself: the snippet copies the tree, runs §2's own update against
# the copy, and reads the result. If any of these three go missing it has gone
# back to predicting.
expect_ok "the snippet rehearses the apply instead of modelling it" \
    sh -c 'grep -qF "git clone --no-hardlinks" "$1" &&
        grep -qF "run_guarded_copier update --trust --defaults --skip-tasks" "$1" &&
        grep -qF "nonadoption_path_present" "$1" &&
        grep -qF "apply-created" "$1" &&
        grep -qF "apply-deleted" "$1"' sh \
    "$GU_NONADOPT_SNIPPET"
# The rehearsal must mirror §2 or it predicts nothing. These are the flags §2
# uses; `--skip-tasks` and the destination are the only sanctioned differences.
# The scratch is a CLONE. Three rounds of review each found another property the
# hand-built copy-init-add-commit construction failed to reproduce; a clone
# reproduces the index by definition, so the guard is that the construction has
# not grown back. `xargs -r`, `cp --parents` and `cp -t` are GNU-only and this
# recipe supports macOS bash 3.2, so they stay banned outright.
expect_ok "the rehearsal clones rather than rebuilding the scratch repository" \
    sh -c 'grep -qF "git clone --no-hardlinks --quiet . \"\$NONADOPT_SCRATCH/repo\"" "$1" &&
        ! grep -qE "^[^#]*(xargs|cp --parents|cp -t |cp -a)" "$1" &&
        ! grep -qF "git ls-files >" "$1" &&
        ! grep -qF "check-ignore --stdin" "$1" &&
        ! grep -qF "rehearsal baseline" "$1" &&
        ! grep -qF "scratch-copy-paths" "$1"' sh \
    "$GU_NONADOPT_SNIPPET"
# Ignored files are untracked, so the clone omits them; only the MANAGED ones are
# overlaid. Unmanaged caches stay behind — copier cannot consult them, being in
# neither render inventory nor the index.
expect_ok "the rehearsal overlays managed ignored paths only" \
    sh -c 'grep -qF "\$GUARDED_STATE/ignored-existing-paths" "$1" &&
        grep -qF "scratch-overlay-paths" "$1" &&
        grep -qF "sed '\''s#^#./#'\''" "$1"' sh \
    "$GU_NONADOPT_SNIPPET"
expect_ok "the rehearsal mirrors the real update's invocation" \
    sh -c 'grep -qF -- "--vcs-ref=\"\$HARMON_INIT_COMMIT\"" "$1" &&
        grep -qF -- "--data-file=\"\$REVIEWED_DATA\"" "$1" &&
        grep -qF "\"\$NONADOPT_SCRATCH/repo\"" "$1"' sh \
    "$GU_NONADOPT_SNIPPET"
expect_ok "non-adoption snippet requires template-side declaration for ignored-policy" \
    sh -c 'grep -qF "nonadoption_is_render_ignored" "$1" &&
        grep -qF "check-ignore -q --no-index" "$1" &&
        grep -qF "core.excludesFile=/dev/null" "$1" &&
        grep -qF "repo-ignored-only" "$1"' sh \
    "$GU_NONADOPT_SNIPPET"
expect_ok "non-adoption snippet records the known-false verdict either way" \
    sh -c 'grep -qF "nonadoption_known_false_note" "$1" &&
        grep -qF "nonadoption_has_adr_log" "$1" &&
        grep -qF "nonadoption_has_nested_terraform" "$1" &&
        grep -qF "nonadoption_has_prettier_config" "$1" &&
        grep -qF "unverified-equivalent" "$1" &&
        grep -qF "known-false-verified" "$1" &&
        ! grep -qE "^[[:space:]]*\.envrc\) return 0 ;;$" "$1"' sh \
    "$GU_NONADOPT_SNIPPET"
# Each equivalence is held to the documented evidence, and each of these lines is
# the whole of that restriction — drop one and the check silently widens back to
# "something that looks vaguely like a replacement".
expect_ok "non-adoption snippet holds each equivalence to its documented evidence" \
    sh -c 'grep -qF "*-record-architecture-decisions.md) return 0 ;;" "$1" &&
        grep -qF "test -f docs/decisions/README.md" "$1" &&
        grep -qF -- "-name .terraform -prune -o -type f -name" "$1" &&
        grep -qF "yq -r '\''.prettier // \"\"'\'' package.json" "$1" &&
        ! grep -qF "grep -q '\''\"prettier\"'\'' package.json" "$1"' sh \
    "$GU_NONADOPT_SNIPPET"
# The Brewfile stays disclosed. There is no filter list to re-enter now, so the
# guard is simply that its chezmoi evidence lands as a note.
expect_ok "non-adoption snippet discloses the contested Brewfile instead of filtering it" \
    sh -c 'grep -qF "nonadoption_add_note \"chezmoi-managed — verify per mode-audit class K\"" "$1" &&
        grep -qF "nonadoption_has_chezmoi_brewfile" "$1"' sh \
    "$GU_NONADOPT_SNIPPET"
# The reviewed-keyset probe runs on the designed first pass, where
# $REVIEWED_DATA does not exist yet. Folding its `test -e` guard into the
# command substitution made the assignment inherit exit 1, so a `bash -eu` shell
# died before the gate below it could reach the seeding block that gate exists
# to trigger — after the expensive discovery loop, and for no reason.
expect_ok "update guidance keeps the reviewed-keyset probe errexit-safe" \
    sh -c 'grep -qF "REVIEWED_KEYSET_OID=\"\"" "$1" &&
        ! grep -A1 -F "REVIEWED_KEYSET_OID=\"\$(" "$1" |
            grep -qE "^[[:space:]]*test -e"' sh \
    "$STANDARDIZE_REFS/mode-update.md"
expect_ok "update guidance states its snippet execution assumptions up front" \
    sh -c 'grep -qF "on both the producer and the consumer" "$1" &&
        grep -qF "file 1 is not in sorted order" "$1"' sh \
    "$STANDARDIZE_REFS/mode-update.md"
# Behavioral proof of the same property, on inputs chosen to trip it: under an
# ambient UTF-8 locale the unpinned form exits 1 on exactly these two files,
# because `codeql_languages` pairs off first and `github_org` then looks out of
# order against `git_init`. Pinned on both sides, the answer is the byte-order
# one in every locale.
utf8_locale=""
utf8_fallback=""
while IFS= read -r cand; do
    case "$cand" in
    en_US.UTF-8 | en_US.utf8)
        utf8_locale="$cand"
        break
        ;;
    *.UTF-8 | *.utf8)
        [ -n "$utf8_fallback" ] || utf8_fallback="$cand"
        ;;
    esac
done < <(locale -a 2>/dev/null || true)
[ -n "$utf8_locale" ] || utf8_locale="$utf8_fallback"
if [ -n "$utf8_locale" ]; then
    COLLATE_DIR="$TMPROOT/collation-pin"
    mkdir -p "$COLLATE_DIR"
    expect_ok "pinned sort|comm pair survives an ambient UTF-8 locale ($utf8_locale)" \
        env "LC_ALL=$utf8_locale" "LANG=$utf8_locale" bash -c '
            set -eu
            cd "$1"
            printf "%s\n" git_init github_org use_codeql |
                LC_ALL=C sort -u >baseline-questions
            printf "%s\n" codeql_languages git_init github_org use_codeql \
                use_codex_review | LC_ALL=C sort -u >target-questions
            got="$(LC_ALL=C comm -13 baseline-questions target-questions |
                paste -sd, -)"
            test "$got" = "codeql_languages,use_codex_review" || {
                echo "unexpected comm output under $LC_ALL: $got" >&2
                exit 1
            }
        ' bash "$COLLATE_DIR"
else
    ok "pinned sort|comm pair locale proof skipped (no UTF-8 locale available)"
fi
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
# harmon-init#475/#485 grant the bot PAT Projects: Read and write for org repos
# so the claim lifecycle can move cards through the Status pipeline; the vendored
# checklist must match the canonical template (no stale "read, never write").
expect_ok "post-generation checklist grants the bot Projects write for the org claim lifecycle" \
    sh -c 'grep -qF "Projects: Read and write" "$1" &&
        grep -qF "claim lifecycle" "$1" &&
        grep -qF "Status" "$1"' sh \
    "$STANDARDIZE_REFS/post-generation-checklist.md"
expect_fail "post-generation checklist no longer blanket-prohibits org PAT write" \
    grep -qF 'Grant read, never write' \
    "$STANDARDIZE_REFS/post-generation-checklist.md"
expect_ok "audit guidance reconciles CodeRabbit answers and external access" \
    grep -qF '**G3. CodeRabbit selection drift.**' \
    "$STANDARDIZE_REFS/mode-audit.md"
# The audit glossary has to describe the predicates diff-template.sh actually
# applies, not the looser ones it started with: prose-only under the docs/specs
# trees, and an IGNORED class the TEMPLATE grants rather than the repo's habits.
# Patterns stay backtick-free and go straight to grep rather than through
# `sh -c`: a backtick inside the double quotes of an sh -c script is command
# substitution, so such a pattern silently degrades to its surrounding prose and
# the assertion stops checking what it names.
expect_ok "audit glossary scopes the co-owned docs/specs globs to prose" \
    grep -qF 'globs are filtered to Markdown on purpose' \
    "$STANDARDIZE_REFS/mode-audit.md"
expect_ok "audit glossary gates non-prose under the docs tree" \
    grep -qF 'not prose anybody rewrote' \
    "$STANDARDIZE_REFS/mode-audit.md"
expect_ok "audit glossary keys IGNORED on the template's own declaration" \
    grep -qF 'untracked, and both the repo *and the template*' \
    "$STANDARDIZE_REFS/mode-audit.md"
expect_ok "audit glossary gates a repo-only ignore rule" \
    grep -qF 'repo-ignored, but the template tracks this file' \
    "$STANDARDIZE_REFS/mode-audit.md"
expect_ok "audit glossary records that a MODE finding still gates" \
    grep -qF 'a `MODE` finding on the same file still gates' \
    "$STANDARDIZE_REFS/mode-audit.md"
# IGNORED is a sweep-only class: the curated loop never grants it, because the
# manifest is itself an assertion of template ownership. The glossary claimed
# the exemption applied to any untracked path both sides ignore.
expect_ok "update glossary marks IGNORED as a sweep-only class" \
    grep -qF '**sweep-only** class' \
    "$STANDARDIZE_REFS/mode-update.md"
# Patterns must sit on ONE source line — markdown wraps prose, and grep -F is
# line-oriented, so a phrase that reads as a sentence can still never match.
expect_ok "update glossary states a curated path always gates" \
    grep -qF 'because the manifest is itself an assertion of template' \
    "$STANDARDIZE_REFS/mode-update.md"
expect_ok "update glossary excludes curated paths from the IGNORED class" \
    grep -qF 'a curated path is never a candidate' \
    "$STANDARDIZE_REFS/mode-update.md"
# The same exception, in the same words, in the other two places that define the
# class. `.claude/settings.json` is the concrete case: on the manifest, and
# exactly the shape a repo gitignores.
expect_ok "audit glossary marks IGNORED as a sweep-only class" \
    grep -qF 'It is also a **sweep-only** class' \
    "$STANDARDIZE_REFS/mode-audit.md"
expect_ok "audit glossary names the curated path that still gates" \
    grep -qF 'is on that list and reports `DRIFT` however thoroughly a repo ignores it' \
    "$STANDARDIZE_REFS/mode-audit.md"
expect_ok "standards catalog marks OWNED and IGNORED as sweep-only classes" \
    grep -qF '`OWNED` and `IGNORED` are **sweep-only** classes' \
    "$STANDARDIZE_REFS/standards-catalog.md"
# The OWNED class is derived from the template's own declaration rather than
# mirrored here, and the catalog has to say so: a reader who thinks it is a
# hand-maintained list would keep it in step by hand and be wrong about where
# the truth lives.
expect_ok "standards catalog says OWNED is derived from the template's declaration" \
    grep -qF 'template'"'"'s own `copier.yml` `_skip_if_exists` declares the path repo-owned' \
    "$STANDARDIZE_REFS/standards-catalog.md"
expect_ok "standards catalog names the curated path that still gates" \
    grep -qF 'is on that list and reports `DRIFT` however thoroughly a repo ignores it' \
    "$STANDARDIZE_REFS/standards-catalog.md"
# Both operating modes print the sweep's classes at an operator, so both
# glossaries have to carry OWNED — an unexplained tag in a report is a tag
# somebody adjudicates by guessing.
for owned_glossary in mode-audit.md mode-update.md; do
    expect_ok "$owned_glossary glossary documents the OWNED class" \
        grep -qF '**`OWNED`** — the **template itself** declares the path repo-owned' \
        "$STANDARDIZE_REFS/$owned_glossary"
done
# The non-adoption classifier deliberately does NOT learn about the class, and
# the reason is recorded where the next person to mirror something will look.
expect_ok "the non-adoption classifier records why OWNED is not mirrored into it" \
    grep -qF "diff-template.sh's OWNED class is likewise absent" \
    "$STANDARDIZE_REFS/mode-update.md"
expect_fail "audit glossary no longer calls every gitignored copy IGNORED" \
    grep -qF "the repo's copy is gitignored" \
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
        "$STANDARDIZE_REFS/mode-update.md")" -eq 5
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
# The branch arm commits on the freeze branch (not main), so the hook guard
# lives in the amend arm, not before the reachability check — there is no
# hook-driven manual switch to a feature branch first. @{upstream} covers the
# ordinary case (main tracks origin/main after gh repo create --push), but it is
# unset on a detached or non-tracking checkout. A published origin/main is a
# third publication signal so the freeze still branches + PRs there instead of
# wrongly amending and leaving main on the tag-valued tuple.
expect_ok "new-repo freeze detects a published main when the current branch lacks an upstream" \
    grep -qF 'refs/remotes/origin/main' \
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
# follow-up freeze commit reaches a branch + draft PR — the local-only path is
# not a fix, and a direct push to main is forbidden (it is an agent-authored
# follow-up, not the bootstrap base).
expect_ok "new-repo freeze pushes the follow-up to a branch and opens a draft PR" \
    sh -c 'grep -qF "git push -u origin" "$1" &&
        grep -qF "freeze commit is local only" "$1" &&
        grep -qF "gh pr create --draft" "$1"' sh \
    "$STANDARDIZE_REFS/mode-new-repo.md"
# The freeze is an agent-authored follow-up on a published scaffold, so it must
# branch before the commit — never push the follow-up directly to main.
expect_ok "new-repo freeze branches before the follow-up on a published scaffold" \
    sh -c 'switch_line="$(grep -nF "git switch -c" "$1" | head -1 | cut -d: -f1)"
        commit_line="$(grep -nF "chore: freeze copier lineage" "$1" |
            head -1 | cut -d: -f1)"
        test -n "$switch_line" && test -n "$commit_line" &&
        test "$switch_line" -lt "$commit_line"' sh \
    "$STANDARDIZE_REFS/mode-new-repo.md"
# The no-remote + hooks path stages the freeze, exits to publish the base, then
# reruns. A plain `git diff --quiet` sees no unstaged change (the tuple is
# staged) and skips the block — leaving main on the tag-valued tuple. The entry
# guard must diff against HEAD so a staged freeze is still committed on rerun.
expect_ok "new-repo freeze detects a staged tuple on rerun, not just an unstaged one" \
    grep -qF 'git diff --quiet HEAD -- .copier-answers.yml' \
    "$STANDARDIZE_REFS/mode-new-repo.md"
# git switch -c without a start-point branches from the current HEAD, so a
# non-main checkout would drag unrelated commits into the lineage-only PR. Anchor
# to main (the published initial base) explicitly.
expect_ok "new-repo freeze branches from main, not the current HEAD" \
    grep -qF 'git switch -c "$FREEZE_BRANCH" main' \
    "$STANDARDIZE_REFS/mode-new-repo.md"
# web-astro + github_remote_create=true + run_task_install=true: the freeze
# branch push is the first push subject to the pre-push hook (task install ran
# after Copier's step-3 --push), so it runs `astro check` on a bare repo and
# fails. The remote-created arm must extend the scaffolding exception the
# no-remote first-push caveat already has.
expect_ok "new-repo freeze extends the web-astro scaffolding caveat to the remote-created push" \
    grep -qF 'freeze push runs `astro check`' \
    "$STANDARDIZE_REFS/mode-new-repo.md"
expect_fail "new-repo freeze never pushes a follow-up directly to main" \
    grep -qF 'git push ||' \
    "$STANDARDIZE_REFS/mode-new-repo.md"
# The no-remote recommended path folds the freeze into the unpublished initial
# base and publishes it directly — a PR cannot predate its base branch.
expect_ok "new-repo no-remote path publishes the initial base directly" \
    sh -c 'grep -qF "A PR cannot predate its base branch" "$1" &&
        grep -qF "initial base" "$1"' sh \
    "$STANDARDIZE_REFS/mode-new-repo.md"
# github_remote_create=false skips §4 step 3, and post-generation-checklist.md
# starts after the first push (it does not create the remote), so the no-remote
# path must give the first-push command explicitly — otherwise the references
# reach a circular prerequisite with no remote main to target a draft PR at.
expect_ok "new-repo no-remote path gives the first-push command explicitly" \
    grep -qF 'make the first push yourself' \
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
    taskfiles/foreman.yml; do
    expect_ok "template-owned manifest includes $required" grep -qxF "$required" "$manifest"
done
expect_fail "template-owned manifest lists no vendored foreman source" \
    grep -q '^scripts/foreman/' "$manifest"

# Exercise executable-mode drift, equivalent mature layouts, legacy CodeRabbit
# opt-out handling, index-backed transient deletions, and the whole-render sweep
# (uncurated / co-owned / gitignored / symlink classes) end to end with a tiny
# local Copier template. The real manifest is reused.
DT_TEMPLATE="$TMPROOT/diff-template-source"
mkdir -p \
    "$DT_TEMPLATE/template/scripts" \
    "$DT_TEMPLATE/template/terraform" \
    "$DT_TEMPLATE/template/docs/decisions"
# _preserve_symlinks mirrors the real template, which ships CLAUDE.md/GEMINI.md/
# .github/copilot-instructions.md as symlinks to AGENTS.md. Without it copier
# dereferences the link into a duplicate file and the sweep's symlink handling
# is never exercised.
# _skip_if_exists mirrors the real template's machine-readable declaration that
# the REPO owns a path: one literal entry and one glob, because the OWNED class
# is derived from this list at run time and copier matches it with git's own
# gitignore dialect. `*.code-workspace` is deliberately a path is_co_owned()
# ALSO matches, which is what pins the precedence between the two classes.
cat >"$DT_TEMPLATE/copier.yml" <<'EOF'
_min_copier_version: "9.4.0"
_subdirectory: template
_preserve_symlinks: true
_skip_if_exists:
  - CHANGELOG.md
  - "*.code-workspace"
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
# AGENTS.md is co-owned prose; CLAUDE.md is its symlink alias; renovate.json is
# an uncurated file that is neither, so it must show as gating DRIFT. .envrc is
# the gitignored case — a resolved local config whose diff must never be printed.
printf '%s\n' '# Test Project agents' 'seeded agent prose' \
    >"$DT_TEMPLATE/template/AGENTS.md"
ln -s AGENTS.md "$DT_TEMPLATE/template/CLAUDE.md"
printf '%s\n' '{ "extends": ["config:recommended"] }' \
    >"$DT_TEMPLATE/template/renovate.json"
printf '%s\n' 'export EXAMPLE_SETTING=template-default' \
    >"$DT_TEMPLATE/template/.envrc"
# secrets.env is the TRACKED-and-pattern-matched case. `git check-ignore`
# consults the index, so tracking makes it not-ignored and it must gate as
# ordinary uncurated DRIFT — while its body must still never reach stdout,
# because withholding is keyed on the path rather than on the class.
printf '%s\n' 'EXAMPLE_TOKEN=template-default' \
    >"$DT_TEMPLATE/template/secrets.env"
# Two files under docs/ that land in DIFFERENT classes. The co-owned globs
# cover the PROSE in that tree, so guide.md is CO-OWNED while the build script
# beside it is an ordinary uncurated file — a generated script is not prose
# anybody rewrote, and inheriting the presence-only exemption for its directory
# alone would be the opposite of safe-by-default.
printf '%s\n' '# Guide' 'seeded guide prose' \
    >"$DT_TEMPLATE/template/docs/guide.md"
printf '%s\n' '#!/usr/bin/env bash' 'echo docs' \
    >"$DT_TEMPLATE/template/docs/build-docs.sh"
chmod +x "$DT_TEMPLATE/template/docs/build-docs.sh"
# .claude/settings.json is the CURATED ignore-matched case: it is on the real
# template-owned-files.txt manifest, so the curated loop owns it, and it is
# exactly the shape a repo gitignores because its local copy holds credentials.
mkdir -p "$DT_TEMPLATE/template/.claude"
printf '%s\n' '{ "permissions": { "allow": [] } }' \
    >"$DT_TEMPLATE/template/.claude/settings.json"
# The template's OWN .gitignore is what declares a rendered path local-only, and
# it is the only thing that can grant the informational IGNORED class. It ships
# seeds for both resolved-config files and ignores them, which is the shape the
# class exists for.
printf '%s\n' '.envrc' 'secrets.env' >"$DT_TEMPLATE/template/.gitignore"
# .vscode/settings.json is the counter-case: the template TRACKS it (no ignore
# rule covers it here), so a repo that ignores it locally has silenced a real
# template artifact every other clone still gets.
mkdir -p "$DT_TEMPLATE/template/.vscode"
printf '%s\n' '{ "editor.tabSize": 2 }' \
    >"$DT_TEMPLATE/template/.vscode/settings.json"
for terraform_file in main.tf variables.tf outputs.tf; do
    printf '%s\n' '# starter' >"$DT_TEMPLATE/template/terraform/$terraform_file"
done
printf '%s\n' '# Example values' >"$DT_TEMPLATE/template/terraform/tfvars.env.example"
printf '%s\n' '# Record architecture decisions' \
    >"$DT_TEMPLATE/template/docs/decisions/0001-record-architecture-decisions.md"
# The two _skip_if_exists seeds. CHANGELOG.md is the literal entry (release-please
# owns it in the real template); project.code-workspace is what the glob reaches
# AND what is_co_owned() also lists, so the pair covers both the derivation and
# the precedence.
printf '%s\n' '# Changelog' 'seeded changelog' \
    >"$DT_TEMPLATE/template/CHANGELOG.md"
printf '%s\n' '{ "folders": [] }' \
    >"$DT_TEMPLATE/template/project.code-workspace"
git_init "$DT_TEMPLATE"
# The .gitignore the template SHIPS applies to the template repo itself, and a
# caller's global excludes can add machine-specific rules such as ignoring
# `.vscode/settings.json`. `git add -A` would then skip fixtures this test says
# the template tracks, so force-add every ignore-sensitive seed explicitly.
git -C "$DT_TEMPLATE" add -f -- \
    template/.envrc \
    template/secrets.env \
    template/.vscode/settings.json
git_commit_all "$DT_TEMPLATE" "test template"
expect_ok "diff-template fixture tracks .vscode/settings.json" \
    git -C "$DT_TEMPLATE" ls-files --error-unmatch \
    template/.vscode/settings.json
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
# Mirror the new template files byte-for-byte so the pre-existing cases below
# keep their exit expectations; each new case mutates one of them in turn.
cp "$DT_TEMPLATE/template/AGENTS.md" "$DT_TARGET/AGENTS.md"
ln -s AGENTS.md "$DT_TARGET/CLAUDE.md"
cp "$DT_TEMPLATE/template/renovate.json" "$DT_TARGET/renovate.json"
cp "$DT_TEMPLATE/template/secrets.env" "$DT_TARGET/secrets.env"
cp "$DT_TEMPLATE/template/docs/guide.md" "$DT_TARGET/docs/guide.md"
cp "$DT_TEMPLATE/template/docs/build-docs.sh" "$DT_TARGET/docs/build-docs.sh"
chmod +x "$DT_TARGET/docs/build-docs.sh"
mkdir -p "$DT_TARGET/.claude" "$DT_TARGET/.vscode"
cp "$DT_TEMPLATE/template/.claude/settings.json" "$DT_TARGET/.claude/settings.json"
cp "$DT_TEMPLATE/template/.vscode/settings.json" "$DT_TARGET/.vscode/settings.json"
# .envrc diverges from the render permanently and is gitignored, so it stays
# untracked (git_commit_all honors .gitignore) and reports as informational
# IGNORED rather than drift — the class exists precisely because a resolved
# local config can hold real values that must not be printed. secrets.env
# matches an ignore rule too but is force-added below, which is what separates
# the two axes: it gates like any tracked file, yet its body stays withheld.
# The target's .gitignore is the RENDER's, byte-for-byte — it is a rendered file
# now, so any divergence would be drift in its own right. Rules the repo added
# on its own therefore go in .git/info/exclude below, which is where a
# repo-local habit actually belongs and cannot be confused with a declaration
# the template made.
cp "$DT_TEMPLATE/template/.gitignore" "$DT_TARGET/.gitignore"
# Both declared paths diverge from the render PERMANENTLY, which is the steady
# state every mature repo is in: release-please rewrites the changelog and the
# workspace file carries per-repo settings. They must stay informational, so the
# clean-baseline assertions below still expect exit 0. The sentinels prove the
# bodies are never printed, --show included.
printf '%s\n' '# Changelog' '## 1.4.0 changelog-sentinel-withheld' \
    >"$DT_TARGET/CHANGELOG.md"
printf '%s\n' '{ "folders": ["workspace-sentinel-withheld"] }' \
    >"$DT_TARGET/project.code-workspace"
printf '%s\n' 'export EXAMPLE_SETTING=envrc-sentinel-withheld' >"$DT_TARGET/.envrc"
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
# `git add -A` honors .gitignore, so the tracked-and-ignore-matched case has to
# be forced into the index — which is exactly the `git add -f` a repo runs for a
# resolved local config it nonetheless wants under version control.
# Ignore rules this repo added for its own reasons, kept out of the tracked
# .gitignore so they cannot be mistaken for the template's declaration.
# .claude/settings.json is force-added anyway (tracked → gates → body withheld);
# .vscode/settings.json stays untracked, which is the repo-only-ignored shape
# that must gate rather than collect the IGNORED exemption.
mkdir -p "$DT_TARGET/.git/info"
printf '%s\n' '.claude/settings.json' '.vscode/settings.json' \
    >"$DT_TARGET/.git/info/exclude"
git -C "$DT_TARGET" add -f -- secrets.env .claude/settings.json
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
# That run exits 0, so IGNORED appearing in it is also the proof it never gates.
if printf '%s\n' "$equivalent_out" | grep -qF "IGNORED  .envrc"; then
    ok "diff-template reports a gitignored divergence without gating"
else
    bad "diff-template reports a gitignored divergence without gating"
fi
# …and the exemption is granted by the TEMPLATE's own .gitignore, not by the
# repo's, which is what the parenthetical records.
if printf '%s\n' "$equivalent_out" |
    grep -qF "IGNORED  .envrc  (template ships it gitignored"; then
    ok "diff-template credits the template's declaration for an IGNORED file"
else
    bad "diff-template credits the template's declaration for an IGNORED file"
fi

# --- whole-render sweep: uncurated, co-owned, and symlink classes ------------
# The baseline above is green, so each case below can attribute its exit code to
# its own mutation. Every case mutates the clean target, runs the real script,
# asserts the class line AND the exit code, then restores.

# An uncurated file the repo diverges on is the gap issue 346 describes: the
# repo HAS it, the manifest does not list it, and it used to be skipped outright.
printf '%s\n' '{ "extends": ["config:base"] }' >"$DT_TARGET/renovate.json"
if uncurated_out="$(HARMON_INIT="$DT_TEMPLATE" bash "$STANDARDIZE_ASSETS/diff-template.sh" "$DT_TARGET" 2>&1)"; then
    bad "diff-template reports uncurated content drift (expected non-zero exit)"
elif printf '%s\n' "$uncurated_out" | grep -qF "DRIFT    renovate.json  (uncurated"; then
    ok "diff-template reports uncurated content drift"
else
    bad "diff-template reports uncurated content drift (DRIFT diagnostic missing)"
fi
if printf '%s\n' "$uncurated_out" |
    grep -qE '^  1 uncurated DRIFT \+ 0 uncurated MODE'; then
    ok "diff-template counts uncurated drift in its summary"
else
    bad "diff-template counts uncurated drift in its summary"
fi

# A divergent co-owned file is informational: visible, but it must NOT gate, and
# its alias symlink must stay silent (comparing link targets is what keeps one
# AGENTS.md divergence from being reported once per alias).
printf '%s\n' '# Test Project agents' 'seeded agent prose' 'co-owned-body-sentinel' \
    >"$DT_TARGET/AGENTS.md"
cp "$DT_TEMPLATE/template/renovate.json" "$DT_TARGET/renovate.json"
if co_owned_out="$(HARMON_INIT="$DT_TEMPLATE" bash "$STANDARDIZE_ASSETS/diff-template.sh" "$DT_TARGET" 2>&1)"; then
    ok "diff-template does not gate on a divergent co-owned file"
else
    bad "diff-template does not gate on a divergent co-owned file: $co_owned_out"
fi
if printf '%s\n' "$co_owned_out" | grep -qF "CO-OWNED AGENTS.md"; then
    ok "diff-template reports a divergent co-owned file"
else
    bad "diff-template reports a divergent co-owned file (CO-OWNED line missing)"
fi
if printf '%s\n' "$co_owned_out" | grep -qF "CLAUDE.md"; then
    bad "diff-template does not repeat a co-owned divergence per symlink alias"
else
    ok "diff-template does not repeat a co-owned divergence per symlink alias"
fi

# --show must print the uncurated diff body and withhold both presence-only
# classes: a co-owned diff is noise by design, and a gitignored one can leak.
printf '%s\n' '{ "extends": ["config:base"] }' >"$DT_TARGET/renovate.json"
show_out="$(HARMON_INIT="$DT_TEMPLATE" bash "$STANDARDIZE_ASSETS/diff-template.sh" \
    --show "$DT_TARGET" 2>&1 || true)"
if printf '%s\n' "$show_out" | grep -qF 'config:base'; then
    ok "diff-template --show prints an uncurated diff body"
else
    bad "diff-template --show prints an uncurated diff body"
fi
if printf '%s\n' "$show_out" | grep -qF 'co-owned-body-sentinel'; then
    bad "diff-template --show withholds a co-owned diff body"
else
    ok "diff-template --show withholds a co-owned diff body"
fi
if printf '%s\n' "$show_out" | grep -qF 'envrc-sentinel-withheld'; then
    bad "diff-template --show withholds a gitignored diff body"
else
    ok "diff-template --show withholds a gitignored diff body"
fi
# OWNED is presence-only for the same reason, on a different rationale: copier
# will never rewrite a _skip_if_exists path, so its content is not the
# template's business and printing it is pure noise (a release-please changelog
# would bury the report).
if printf '%s\n' "$show_out" | grep -qF 'changelog-sentinel-withheld'; then
    bad "diff-template --show withholds a template-declared repo-owned diff body"
else
    ok "diff-template --show withholds a template-declared repo-owned diff body"
fi
if printf '%s\n' "$show_out" | grep -qF 'workspace-sentinel-withheld'; then
    bad "diff-template --show withholds a glob-matched repo-owned diff body"
else
    ok "diff-template --show withholds a glob-matched repo-owned diff body"
fi
cp "$DT_TEMPLATE/template/renovate.json" "$DT_TARGET/renovate.json"
cp "$DT_TEMPLATE/template/AGENTS.md" "$DT_TARGET/AGENTS.md"

dt_skip_decl_variant() {
    # $1 = destination, $2… = the _skip_if_exists lines to write (none = drop it)
    dsv_dest="$1"
    shift
    cp -pR "$DT_TEMPLATE" "$dsv_dest"
    {
        printf '%s\n' '_min_copier_version: "9.4.0"' '_subdirectory: template' \
            '_preserve_symlinks: true'
        [ "$#" -eq 0 ] || printf '%s\n' "$@"
        printf '%s\n' 'project_name:' '  type: str' '  default: Test Project'
    } >"$dsv_dest/copier.yml"
    git_commit_all "$dsv_dest" "rewrite the _skip_if_exists declaration"
    git -C "$dsv_dest" tag -f v1.0.0 >/dev/null
}

# --- OWNED: the template's own _skip_if_exists declaration (issue 359) --------
# Both declared paths diverge permanently in the clean target, so this run also
# re-asserts the baseline: the class is informational and must not gate. The
# glob entry is the one that matters twice over — it proves the derivation
# matches with git's own gitignore dialect (a `*.code-workspace` pattern reaching
# a root-level file), and it proves the precedence, because is_co_owned() lists
# that same glob and the template's machine-readable declaration has to win.
if owned_out="$(HARMON_INIT="$DT_TEMPLATE" bash "$STANDARDIZE_ASSETS/diff-template.sh" "$DT_TARGET" 2>&1)"; then
    ok "diff-template does not gate on a template-declared repo-owned file"
else
    bad "diff-template does not gate on a template-declared repo-owned file: $owned_out"
fi
if printf '%s\n' "$owned_out" |
    grep -qF "OWNED    CHANGELOG.md  (template's _skip_if_exists declares the repo owns it"; then
    ok "diff-template reports a divergent _skip_if_exists path as OWNED"
else
    bad "diff-template reports a divergent _skip_if_exists path as OWNED (OWNED line missing)"
fi
if printf '%s\n' "$owned_out" | grep -qF "OWNED    project.code-workspace"; then
    ok "diff-template matches _skip_if_exists globs the way copier does"
else
    bad "diff-template matches _skip_if_exists globs the way copier does"
fi
if printf '%s\n' "$owned_out" | grep -qF "CO-OWNED project.code-workspace"; then
    bad "diff-template prefers OWNED over CO-OWNED where the two overlap"
else
    ok "diff-template prefers OWNED over CO-OWNED where the two overlap"
fi
if printf '%s\n' "$owned_out" | grep -qE '^(DRIFT|MISSING) +(CHANGELOG\.md|project\.code-workspace)'; then
    bad "diff-template stops reporting declared repo-owned paths as drift"
else
    ok "diff-template stops reporting declared repo-owned paths as drift"
fi
if printf '%s\n' "$owned_out" | grep -qF "2 OWNED"; then
    ok "diff-template counts OWNED in its summary"
else
    bad "diff-template counts OWNED in its summary"
fi

# OWNED must not be granted through the .yml/.yaml twin mapping. repo_variant
# resolves a rendered `config.yml` to a repo `config.yaml`, which is right for
# every other class — the repo renamed the file and its content is comparable.
# It is wrong here: OWNED claims copier will not rewrite THIS PATH, and copier's
# existence check is path-specific, so with `config.yml` absent from the
# destination the next update writes it alongside the `config.yaml` the repo
# kept. The divergence must gate.
DT_TWIN_TEMPLATE="$TMPROOT/diff-template-twin-source"
dt_skip_decl_variant "$DT_TWIN_TEMPLATE" '_skip_if_exists:' '  - config.yml'
printf '%s\n' 'setting: template-default' >"$DT_TWIN_TEMPLATE/template/config.yml"
git_commit_all "$DT_TWIN_TEMPLATE" "add a declared yml the repo may carry as yaml"
git -C "$DT_TWIN_TEMPLATE" tag -f v1.0.0 >/dev/null
DT_TWIN_TARGET="$TMPROOT/diff-template-twin-target"
cp -pR "$DT_TARGET" "$DT_TWIN_TARGET"
printf '%s\n' 'setting: repo-renamed-and-diverged' >"$DT_TWIN_TARGET/config.yaml"
git_commit_all "$DT_TWIN_TARGET" "carry the declared path under the other extension"
twin_rc=0
twin_out="$(HARMON_INIT="$DT_TWIN_TEMPLATE" \
    bash "$STANDARDIZE_ASSETS/diff-template.sh" "$DT_TWIN_TARGET" 2>&1)" || twin_rc=$?
if [ "$twin_rc" -eq 1 ]; then
    ok "diff-template gates a declared path the repo carries under the twin extension"
else
    bad "diff-template gates a declared path the repo carries under the twin extension (got $twin_rc)"
fi
if printf '%s\n' "$twin_out" | grep -qF "OWNED    config.yaml"; then
    bad "diff-template grants no OWNED through a .yml/.yaml extension alias"
else
    ok "diff-template grants no OWNED through a .yml/.yaml extension alias"
fi
# The index-snapshot fallback is the same hole by another route: a declared path
# deleted from the WORKING TREE only is compared from the index, and the
# snapshot's display path equals the rendered one — so the path-identity check
# passes while the destination file is absent. copier tests the destination, so
# an update renders the seed straight over it, which is exactly what OWNED
# promises cannot happen.
DT_OWNED_WT_TARGET="$TMPROOT/diff-template-owned-worktree-gone"
cp -pR "$DT_TARGET" "$DT_OWNED_WT_TARGET"
rm "$DT_OWNED_WT_TARGET/CHANGELOG.md"
owned_wt_rc=0
owned_wt_out="$(HARMON_INIT="$DT_TEMPLATE" \
    bash "$STANDARDIZE_ASSETS/diff-template.sh" "$DT_OWNED_WT_TARGET" 2>&1)" || owned_wt_rc=$?
if printf '%s\n' "$owned_wt_out" | grep -qF "OWNED    CHANGELOG.md"; then
    bad "diff-template grants no OWNED to a declared path missing from the worktree"
else
    ok "diff-template grants no OWNED to a declared path missing from the worktree (rc $owned_wt_rc)"
fi

# The same declaration on the path the repo really has is still OWNED, so the
# guard above narrows the class rather than disabling it.
DT_EXACT_TARGET="$TMPROOT/diff-template-twin-exact-target"
cp -pR "$DT_TARGET" "$DT_EXACT_TARGET"
printf '%s\n' 'setting: repo-diverged' >"$DT_EXACT_TARGET/config.yml"
git_commit_all "$DT_EXACT_TARGET" "carry the declared path at its declared name"
exact_rc=0
exact_out="$(HARMON_INIT="$DT_TWIN_TEMPLATE" \
    bash "$STANDARDIZE_ASSETS/diff-template.sh" "$DT_EXACT_TARGET" 2>&1)" || exact_rc=$?
if printf '%s\n' "$exact_out" | grep -qF "OWNED    config.yml"; then
    ok "diff-template still grants OWNED at the declared path itself"
else
    bad "diff-template still grants OWNED at the declared path itself (got rc $exact_rc)"
fi

# The exemption is about CONTENT, exactly like CO-OWNED. A declared path that
# lost or gained the exec bit is a structural divergence and still gates: nobody
# "owns" a file that stopped being what the template rendered.
chmod +x "$DT_TARGET/CHANGELOG.md"
if owned_mode_out="$(HARMON_INIT="$DT_TEMPLATE" bash "$STANDARDIZE_ASSETS/diff-template.sh" "$DT_TARGET" 2>&1)"; then
    bad "diff-template gates mode drift on a template-declared repo-owned file (expected non-zero exit)"
elif printf '%s\n' "$owned_mode_out" | grep -qF "MODE     CHANGELOG.md"; then
    ok "diff-template gates mode drift on a template-declared repo-owned file"
else
    bad "diff-template gates mode drift on a template-declared repo-owned file (MODE diagnostic missing)"
fi
chmod -x "$DT_TARGET/CHANGELOG.md"

# ABSENCE is not content either, and `_skip_if_exists` says nothing about it:
# copier freezes a declared path only when it EXISTS, so a repo that lacks one
# gets it rendered fresh on the next update. That is the MISSING an operator
# must see, and it is why the class is not mirrored into the guarded update's
# non-adoption classifier.
DT_OWNED_ABSENT="$TMPROOT/diff-template-owned-absent"
cp -pR "$DT_TARGET" "$DT_OWNED_ABSENT"
git -C "$DT_OWNED_ABSENT" rm -q -- CHANGELOG.md
git_commit_all "$DT_OWNED_ABSENT" "drop the declared CHANGELOG"
if owned_absent_out="$(HARMON_INIT="$DT_TEMPLATE" bash "$STANDARDIZE_ASSETS/diff-template.sh" "$DT_OWNED_ABSENT" 2>&1)"; then
    bad "diff-template still reports a declared repo-owned path the repo lacks (expected non-zero exit)"
elif printf '%s\n' "$owned_absent_out" | grep -qF "MISSING  CHANGELOG.md"; then
    ok "diff-template still reports a declared repo-owned path the repo lacks"
else
    bad "diff-template still reports a declared repo-owned path the repo lacks (MISSING diagnostic missing)"
fi

# Fail-closed derivation, with one deliberate exception. "I could not read the
# declaration" is a setup error and exits 2. "This baseline predates the
# declaration" is NOT — harmon-init added `_skip_if_exists` in v3.4.0 while a
# guarded audit accepts any v3.0.0 descendant, so refusing those would take the
# audit away from the repos most likely to need it. Those runs continue without
# the class and must SAY so, which is what keeps a degraded run from reading
# like a normal one. Each control is a copy of the working template with only
# its declaration changed.
# A baseline older than the declaration: the run proceeds, says so twice (stderr
# and the summary), grants no OWNED exemption, and — because there is no class
# for it to land in — restores CHANGELOG.md's historical hard skip rather than
# turning every mature repo's changelog into a new false positive.
dt_skip_decl_variant "$TMPROOT/diff-template-noskip-source"
noskip_rc=0
noskip_out="$(HARMON_INIT="$TMPROOT/diff-template-noskip-source" \
    bash "$STANDARDIZE_ASSETS/diff-template.sh" "$DT_TARGET" 2>&1)" || noskip_rc=$?
if [ "$noskip_rc" -eq 0 ]; then
    ok "diff-template still audits a baseline that predates _skip_if_exists"
else
    bad "diff-template still audits a baseline that predates _skip_if_exists (got $noskip_rc): $noskip_out"
fi
if printf '%s\n' "$noskip_out" | grep -qF "declares no _skip_if_exists"; then
    ok "diff-template says an OWNED-less run was degraded, not normal"
else
    bad "diff-template says an OWNED-less run was degraded, not normal"
fi
if printf '%s\n' "$noskip_out" | grep -qF "diff-template: NOTE —"; then
    ok "diff-template repeats the degraded-derivation note in its summary"
else
    bad "diff-template repeats the degraded-derivation note in its summary"
fi
if printf '%s\n' "$noskip_out" | grep -qF "OWNED    "; then
    bad "diff-template grants no OWNED exemption without a declaration"
else
    ok "diff-template grants no OWNED exemption without a declaration"
fi
if printf '%s\n' "$noskip_out" | grep -qF "CHANGELOG.md"; then
    bad "diff-template keeps CHANGELOG.md's hard skip when no declaration exists"
else
    ok "diff-template keeps CHANGELOG.md's hard skip when no declaration exists"
fi
# An explicitly empty list also yields no OWNED class — but it is NOT the same
# fact as a missing key, and the difference is load-bearing for exactly one
# path. `_skip_if_exists: []` is a template saying it freezes NOTHING, so copier
# owns and may rewrite the changelog like any other rendered file: CHANGELOG.md
# must be audited here, where a pre-declaration baseline keeps its legacy skip.
dt_skip_decl_variant "$TMPROOT/diff-template-emptyskip-source" '_skip_if_exists: []'
emptyskip_rc=0
emptyskip_out="$(HARMON_INIT="$TMPROOT/diff-template-emptyskip-source" \
    bash "$STANDARDIZE_ASSETS/diff-template.sh" "$DT_TARGET" 2>&1)" || emptyskip_rc=$?
if printf '%s\n' "$emptyskip_out" | grep -qF "declares an empty _skip_if_exists"; then
    ok "diff-template names an empty _skip_if_exists declaration"
else
    bad "diff-template names an empty _skip_if_exists declaration"
fi
if printf '%s\n' "$emptyskip_out" | grep -qF "DRIFT    CHANGELOG.md"; then
    ok "diff-template audits CHANGELOG.md when the template freezes nothing"
else
    bad "diff-template audits CHANGELOG.md when the template freezes nothing (got rc $emptyskip_rc)"
fi
if printf '%s\n' "$emptyskip_out" | grep -qF "OWNED    "; then
    bad "diff-template grants no OWNED exemption from an empty declaration"
else
    ok "diff-template grants no OWNED exemption from an empty declaration"
fi
# copier discovers its config by globbing `copier.*` and matching `\.ya?ml`
# case-INSENSITIVELY, so a template named copier.YAML renders fine and this
# derivation must read it rather than exiting 2 on a template that works.
DT_UPPER_TEMPLATE="$TMPROOT/diff-template-upper-source"
cp -pR "$DT_TEMPLATE" "$DT_UPPER_TEMPLATE"
git -C "$DT_UPPER_TEMPLATE" mv copier.yml copier.YAML
git_commit_all "$DT_UPPER_TEMPLATE" "rename the copier config to an upper-case suffix"
git -C "$DT_UPPER_TEMPLATE" tag -f v1.0.0 >/dev/null
upper_rc=0
upper_out="$(HARMON_INIT="$DT_UPPER_TEMPLATE" \
    bash "$STANDARDIZE_ASSETS/diff-template.sh" "$DT_TARGET" 2>&1)" || upper_rc=$?
if [ "$upper_rc" -eq 0 ]; then
    ok "diff-template reads a case-varied copier config the way copier discovers it"
else
    bad "diff-template reads a case-varied copier config the way copier discovers it (got $upper_rc): $upper_out"
fi
if printf '%s\n' "$upper_out" | grep -qF "OWNED    CHANGELOG.md"; then
    ok "diff-template derives OWNED from a case-varied copier config"
else
    bad "diff-template derives OWNED from a case-varied copier config"
fi
# A declaration that IS there and is not a list is nobody's baseline — something
# is wrong with the file or with our read of it, and guessing fails closed.
dt_skip_decl_variant "$TMPROOT/diff-template-scalarskip-source" \
    '_skip_if_exists: CHANGELOG.md'
scalarskip_rc=0
scalarskip_out="$(HARMON_INIT="$TMPROOT/diff-template-scalarskip-source" \
    bash "$STANDARDIZE_ASSETS/diff-template.sh" "$DT_TARGET" 2>&1)" || scalarskip_rc=$?
if [ "$scalarskip_rc" -eq 2 ]; then
    ok "diff-template exits 2 on a malformed _skip_if_exists declaration"
else
    bad "diff-template exits 2 on a malformed _skip_if_exists declaration (got $scalarskip_rc)"
fi
if printf '%s\n' "$scalarskip_out" | grep -qF "has a malformed _skip_if_exists"; then
    ok "diff-template names the malformed _skip_if_exists declaration"
else
    bad "diff-template names the malformed _skip_if_exists declaration"
fi
# Negation is refused rather than matched. pathspec applies `!foo/bar` after
# `foo/`, but git never descends into an excluded directory and so cannot
# re-include beneath one — `check-ignore` would call the path declared and hand
# divergent template content the OWNED exemption. Refusing keeps this evaluator
# and copier's from ever disagreeing.
dt_skip_decl_variant "$TMPROOT/diff-template-negskip-source" \
    '_skip_if_exists:' '  - "docs/"' '  - "!docs/guide.md"'
negskip_rc=0
negskip_out="$(HARMON_INIT="$TMPROOT/diff-template-negskip-source" \
    bash "$STANDARDIZE_ASSETS/diff-template.sh" "$DT_TARGET" 2>&1)" || negskip_rc=$?
if [ "$negskip_rc" -eq 2 ]; then
    ok "diff-template exits 2 on a negated _skip_if_exists pattern"
else
    bad "diff-template exits 2 on a negated _skip_if_exists pattern (got $negskip_rc)"
fi
if printf '%s\n' "$negskip_out" |
    grep -qF "FAIL: negated _skip_if_exists pattern is not supported"; then
    ok "diff-template names the negated _skip_if_exists pattern it refuses"
else
    bad "diff-template names the negated _skip_if_exists pattern it refuses"
fi
# Jinja's DEFAULT comment delimiter, not harmon-init's `[#`. The declaration is
# read from whatever template the answers point at, and a comment renders away
# to nothing — so matching the raw pattern would report a declared path as
# gating DRIFT, the opposite direction from the other refusals but the same
# defect: this evaluator disagreeing with copier's.
dt_skip_decl_variant "$TMPROOT/diff-template-jinjacomment-source" \
    '_skip_if_exists:' '  - "{# note #}CHANGELOG.md"'
jinjacomment_rc=0
jinjacomment_out="$(HARMON_INIT="$TMPROOT/diff-template-jinjacomment-source" \
    bash "$STANDARDIZE_ASSETS/diff-template.sh" "$DT_TARGET" 2>&1)" || jinjacomment_rc=$?
if [ "$jinjacomment_rc" -eq 2 ]; then
    ok "diff-template exits 2 on a default-delimiter jinja comment in _skip_if_exists"
else
    bad "diff-template exits 2 on a default-delimiter jinja comment in _skip_if_exists (got $jinjacomment_rc)"
fi
# A directory glob whose final component is a bare `*`. git ignores everything
# beneath a directory it excluded, so `docs/x/y` matches `docs/*`; pathspec
# stops at `docs/x`, leaving `docs/x/y` under copier's management. Refused
# narrowly — `docs/`, `docs`, `docs/**`, `docs/*.md` and basename globs all
# agree between the two matchers and are still accepted.
dt_skip_decl_variant "$TMPROOT/diff-template-dirglob-source" \
    '_skip_if_exists:' '  - "docs/*"'
dirglob_rc=0
dirglob_out="$(HARMON_INIT="$TMPROOT/diff-template-dirglob-source" \
    bash "$STANDARDIZE_ASSETS/diff-template.sh" "$DT_TARGET" 2>&1)" || dirglob_rc=$?
if [ "$dirglob_rc" -eq 2 ]; then
    ok "diff-template exits 2 on a _skip_if_exists pattern ending in /*"
else
    bad "diff-template exits 2 on a _skip_if_exists pattern ending in /* (got $dirglob_rc)"
fi
if printf '%s\n' "$dirglob_out" |
    grep -qF "FAIL: _skip_if_exists pattern ending in '/*' is not supported"; then
    ok "diff-template names the divergent directory glob it refuses"
else
    bad "diff-template names the divergent directory glob it refuses"
fi
# The neighbouring shapes are NOT refused: `docs/**` matches identically in both
# matchers, so a declaration using it must still classify rather than abort.
dt_skip_decl_variant "$TMPROOT/diff-template-globstar-source" \
    '_skip_if_exists:' '  - "docs/**"'
globstar_rc=0
globstar_out="$(HARMON_INIT="$TMPROOT/diff-template-globstar-source" \
    bash "$STANDARDIZE_ASSETS/diff-template.sh" "$DT_TARGET" 2>&1)" || globstar_rc=$?
if [ "$globstar_rc" -ne 2 ]; then
    ok "diff-template still accepts _skip_if_exists globs that both matchers agree on"
else
    bad "diff-template still accepts _skip_if_exists globs that both matchers agree on: $globstar_out"
fi
# A template's OWN _envops delimiters, DERIVED rather than enumerated. copier
# renders each pattern with the environment `_envops` describes, so a template
# using `<%` gets a pattern copier renders and this evaluator would otherwise
# match literally — reporting a repo-owned path as gating DRIFT.
dt_skip_decl_variant "$TMPROOT/diff-template-envops-source" \
    '_envops:' '  variable_start_string: "<%"' '  variable_end_string: "%>"' \
    '_skip_if_exists:' '  - "<% project_name %>.code-workspace"'
envops_rc=0
envops_out="$(HARMON_INIT="$TMPROOT/diff-template-envops-source" \
    bash "$STANDARDIZE_ASSETS/diff-template.sh" "$DT_TARGET" 2>&1)" || envops_rc=$?
if [ "$envops_rc" -eq 2 ]; then
    ok "diff-template exits 2 on a pattern using the template's own _envops delimiter"
else
    bad "diff-template exits 2 on a pattern using the template's own _envops delimiter (got $envops_rc)"
fi
if printf '%s\n' "$envops_out" | grep -qF "it uses the template's own _envops delimiter '<%'"; then
    ok "diff-template names the derived _envops delimiter it refused on"
else
    bad "diff-template names the derived _envops delimiter it refused on"
fi
# Per FIELD, not per template: overriding `variable_start_string` makes `{{` an
# ordinary pair of characters, so a filename containing it is a literal to match
# rather than a template to refuse — while the fields that template did NOT
# override keep their jinja defaults. Enumerating the defaults unconditionally
# beside the derived values got the first half backwards.
dt_skip_decl_variant "$TMPROOT/diff-template-envops-mixed-source" \
    '_envops:' '  variable_start_string: "<%"' '  variable_end_string: "%>"' \
    '_skip_if_exists:' '  - "{{literal}}.txt"' '  - CHANGELOG.md'
envops_mixed_rc=0
envops_mixed_out="$(HARMON_INIT="$TMPROOT/diff-template-envops-mixed-source" \
    bash "$STANDARDIZE_ASSETS/diff-template.sh" "$DT_TARGET" 2>&1)" || envops_mixed_rc=$?
if [ "$envops_mixed_rc" -ne 2 ]; then
    ok "diff-template treats an overridden delimiter's default as a literal"
else
    bad "diff-template treats an overridden delimiter's default as a literal: $envops_mixed_out"
fi
# The fields that template left alone still carry their defaults, so a block
# delimiter it never overrode is still templated.
dt_skip_decl_variant "$TMPROOT/diff-template-envops-block-source" \
    '_envops:' '  variable_start_string: "<%"' '  variable_end_string: "%>"' \
    '_skip_if_exists:' '  - "{% if x %}.txt"'
envops_block_rc=0
envops_block_out="$(HARMON_INIT="$TMPROOT/diff-template-envops-block-source" \
    bash "$STANDARDIZE_ASSETS/diff-template.sh" "$DT_TARGET" 2>&1)" || envops_block_rc=$?
if [ "$envops_block_rc" -eq 2 ]; then
    ok "diff-template keeps jinja defaults for the _envops fields a template leaves unset"
else
    bad "diff-template keeps jinja defaults for the _envops fields a template leaves unset (got $envops_block_rc)"
fi
# copier globs `copier.*` — a case-SENSITIVE basename — and folds only the
# suffix. `COPIER.yml` is ordinary payload, so deriving a declaration from it
# would grant OWNED exemptions off a file copier never read as configuration.
DT_UPPERBASE_TEMPLATE="$TMPROOT/diff-template-upperbase-source"
cp -pR "$DT_TEMPLATE" "$DT_UPPERBASE_TEMPLATE"
git -C "$DT_UPPERBASE_TEMPLATE" mv copier.yml COPIER.yml
git_commit_all "$DT_UPPERBASE_TEMPLATE" "upper-case the copier config basename"
git -C "$DT_UPPERBASE_TEMPLATE" tag -f v1.0.0 >/dev/null
upperbase_rc=0
upperbase_out="$(HARMON_INIT="$DT_UPPERBASE_TEMPLATE" \
    bash "$STANDARDIZE_ASSETS/diff-template.sh" "$DT_TARGET" 2>&1)" || upperbase_rc=$?
if [ "$upperbase_rc" -eq 2 ] &&
    printf '%s\n' "$upperbase_out" | grep -qF "has no copier.yml at"; then
    ok "diff-template reads no declaration from a case-varied copier BASENAME"
else
    bad "diff-template reads no declaration from a case-varied copier BASENAME (got $upperbase_rc)"
fi
# The converse: a delimiter sequence is only special when the template actually
# configures it. `[[` was hardcoded before and would have refused this pattern
# for a template whose jinja environment is the default one.
dt_skip_decl_variant "$TMPROOT/diff-template-noenvops-source" \
    '_skip_if_exists:' '  - "[[weird]].txt"'
noenvops_rc=0
noenvops_out="$(HARMON_INIT="$TMPROOT/diff-template-noenvops-source" \
    bash "$STANDARDIZE_ASSETS/diff-template.sh" "$DT_TARGET" 2>&1)" || noenvops_rc=$?
if [ "$noenvops_rc" -ne 2 ]; then
    ok "diff-template refuses a delimiter only when the template configures it"
else
    bad "diff-template refuses a delimiter only when the template configures it: $noenvops_out"
fi
# Non-ASCII is refused for the Unicode-normalization half of the same problem:
# copier NFD-normalizes patterns, git normalizes nothing, and the filesystem has
# opinions of its own.
dt_skip_decl_variant "$TMPROOT/diff-template-unicodeskip-source" \
    '_skip_if_exists:' '  - "CHANGELÖG.md"'
unicodeskip_rc=0
unicodeskip_out="$(HARMON_INIT="$TMPROOT/diff-template-unicodeskip-source" \
    bash "$STANDARDIZE_ASSETS/diff-template.sh" "$DT_TARGET" 2>&1)" || unicodeskip_rc=$?
if [ "$unicodeskip_rc" -eq 2 ]; then
    ok "diff-template exits 2 on a non-ASCII _skip_if_exists pattern"
else
    bad "diff-template exits 2 on a non-ASCII _skip_if_exists pattern (got $unicodeskip_rc)"
fi
if printf '%s\n' "$unicodeskip_out" |
    grep -qF "FAIL: non-ASCII _skip_if_exists pattern is not supported"; then
    ok "diff-template names the non-ASCII _skip_if_exists pattern it refuses"
else
    bad "diff-template names the non-ASCII _skip_if_exists pattern it refuses"
fi
# CASE. `git init` records core.ignoreCase=true on a default macOS volume and
# git's ignore matcher honors it, while copier's PathSpec is case-sensitive — so
# a lowercase declaration must NOT exempt the rendered CHANGELOG.md, or a file
# copier really will rewrite would be filed as the repo's property. This case
# fails on macOS without the evaluator's explicit core.ignoreCase=false.
dt_skip_decl_variant "$TMPROOT/diff-template-caseskip-source" \
    '_skip_if_exists:' '  - changelog.md'
caseskip_rc=0
caseskip_out="$(HARMON_INIT="$TMPROOT/diff-template-caseskip-source" \
    bash "$STANDARDIZE_ASSETS/diff-template.sh" "$DT_TARGET" 2>&1)" || caseskip_rc=$?
if [ "$caseskip_rc" -eq 1 ]; then
    ok "diff-template matches _skip_if_exists case-sensitively, as copier does"
else
    bad "diff-template matches _skip_if_exists case-sensitively, as copier does (got $caseskip_rc)"
fi
if printf '%s\n' "$caseskip_out" | grep -qF "OWNED    CHANGELOG.md"; then
    bad "diff-template grants no OWNED exemption on a case-mismatched declaration"
else
    ok "diff-template grants no OWNED exemption on a case-mismatched declaration"
fi
# jinja's DEFAULT delimiters are refused unconditionally, because they are what
# a template with no `_envops` of its own renders with. (An earlier version of
# this case used `[[ project_name ]]` against a template that configures no such
# delimiters, asserting a hardcoded list that was wrong in both directions — it
# refused sequences the template never made special, and missed the ones it did.
# The `[[weird]]` counter-case and the `<%` case above replace it.)
dt_skip_decl_variant "$TMPROOT/diff-template-jinjaskip-source" \
    '_skip_if_exists:' '  - "{{ project_name }}.code-workspace"'
jinjaskip_rc=0
jinjaskip_out="$(HARMON_INIT="$TMPROOT/diff-template-jinjaskip-source" \
    bash "$STANDARDIZE_ASSETS/diff-template.sh" "$DT_TARGET" 2>&1)" || jinjaskip_rc=$?
if [ "$jinjaskip_rc" -eq 2 ]; then
    ok "diff-template exits 2 on a templated _skip_if_exists pattern"
else
    bad "diff-template exits 2 on a templated _skip_if_exists pattern (got $jinjaskip_rc)"
fi
if printf '%s\n' "$jinjaskip_out" |
    grep -qF "FAIL: templated _skip_if_exists pattern is not supported"; then
    ok "diff-template names the templated _skip_if_exists pattern it refuses"
else
    bad "diff-template names the templated _skip_if_exists pattern it refuses"
fi

# Classification and withholding are INDEPENDENT axes. secrets.env is tracked
# AND matches an ignore rule: `git check-ignore` consults the index, so tracking
# makes it not-ignored and it must gate as ordinary uncurated DRIFT rather than
# being downgraded to the informational IGNORED class. Its PATH is still marked
# local-only, though, so --show must replace the body with a note instead of
# printing what a resolved config of that shape can really hold.
printf '%s\n' 'EXAMPLE_TOKEN=tracked-secret-sentinel' >"$DT_TARGET/secrets.env"
if tracked_ignored_out="$(HARMON_INIT="$DT_TEMPLATE" bash "$STANDARDIZE_ASSETS/diff-template.sh" \
    --show "$DT_TARGET" 2>&1)"; then
    bad "diff-template gates a tracked ignore-matched file (expected non-zero exit)"
elif printf '%s\n' "$tracked_ignored_out" | grep -qF "DRIFT    secrets.env  (uncurated"; then
    ok "diff-template gates a tracked ignore-matched file"
else
    bad "diff-template gates a tracked ignore-matched file (DRIFT diagnostic missing)"
fi
if printf '%s\n' "$tracked_ignored_out" | grep -qF "IGNORED  secrets.env"; then
    bad "diff-template does not downgrade a tracked ignore-matched file to IGNORED"
else
    ok "diff-template does not downgrade a tracked ignore-matched file to IGNORED"
fi
if printf '%s\n' "$tracked_ignored_out" | grep -qF 'tracked-secret-sentinel'; then
    bad "diff-template --show withholds a gating ignore-matched diff body"
else
    ok "diff-template --show withholds a gating ignore-matched diff body"
fi
if printf '%s\n' "$tracked_ignored_out" |
    grep -qF '(diff withheld — path matches an ignore pattern'; then
    ok "diff-template --show says why a gating ignore-matched diff was withheld"
else
    bad "diff-template --show says why a gating ignore-matched diff was withheld"
fi
git -C "$DT_TARGET" checkout HEAD -- secrets.env

# Withholding is not a sweep-only guarantee. .claude/settings.json is on the
# curated manifest AND matches an ignore rule — being template-owned says the
# template owns the path, not that the repo's local copy (credentials, in the
# real thing) is safe to echo. The curated loop must gate it and withhold it.
printf '%s\n' '{ "permissions": { "token": "curated-secret-sentinel" } }' \
    >"$DT_TARGET/.claude/settings.json"
if curated_withheld_out="$(HARMON_INIT="$DT_TEMPLATE" bash "$STANDARDIZE_ASSETS/diff-template.sh" \
    --show "$DT_TARGET" 2>&1)"; then
    bad "diff-template gates a curated ignore-matched file (expected non-zero exit)"
elif printf '%s\n' "$curated_withheld_out" | grep -qF "DRIFT    .claude/settings.json"; then
    ok "diff-template gates a curated ignore-matched file"
else
    bad "diff-template gates a curated ignore-matched file (DRIFT diagnostic missing)"
fi
if printf '%s\n' "$curated_withheld_out" | grep -qF 'curated-secret-sentinel'; then
    bad "diff-template --show withholds a CURATED ignore-matched diff body"
else
    ok "diff-template --show withholds a CURATED ignore-matched diff body"
fi
if printf '%s\n' "$curated_withheld_out" |
    grep -qF '(diff withheld — path matches an ignore pattern'; then
    ok "diff-template --show says why a curated ignore-matched diff was withheld"
else
    bad "diff-template --show says why a curated ignore-matched diff was withheld"
fi
git -C "$DT_TARGET" checkout HEAD -- .claude/settings.json

# Ignoring a file in the REPO's own rules is a habit, not a statement about the
# artifact: the template tracks .vscode/settings.json, so every other clone gets
# it, and letting a local .gitignore line downgrade that to informational
# IGNORED silenced real drift. It gates — and its body is still withheld,
# because somebody did mark the path local-only and being wrong about whether it
# is drift does not make the contents safe to print.
printf '%s\n' '{ "editor.tabSize": 4, "note": "repo-only-ignored-sentinel" }' \
    >"$DT_TARGET/.vscode/settings.json"
if repo_only_ignored_out="$(HARMON_INIT="$DT_TEMPLATE" bash "$STANDARDIZE_ASSETS/diff-template.sh" \
    --show "$DT_TARGET" 2>&1)"; then
    bad "diff-template gates a repo-only-ignored template file (expected non-zero exit)"
elif printf '%s\n' "$repo_only_ignored_out" |
    grep -qF "DRIFT    .vscode/settings.json  (repo-ignored, but the template tracks this file"; then
    ok "diff-template gates a repo-only-ignored template file"
else
    bad "diff-template gates a repo-only-ignored template file (DRIFT diagnostic missing)"
fi
if printf '%s\n' "$repo_only_ignored_out" | grep -qF "IGNORED  .vscode/settings.json"; then
    bad "diff-template grants no IGNORED exemption on a repo-only ignore rule"
else
    ok "diff-template grants no IGNORED exemption on a repo-only ignore rule"
fi
if printf '%s\n' "$repo_only_ignored_out" | grep -qF 'repo-only-ignored-sentinel'; then
    bad "diff-template --show withholds a repo-only-ignored body that gates"
else
    ok "diff-template --show withholds a repo-only-ignored body that gates"
fi
cp "$DT_TEMPLATE/template/.vscode/settings.json" "$DT_TARGET/.vscode/settings.json"

# The co-owned tree globs cover PROSE, not whole trees. A build script under
# docs/ is not prose anybody rewrote, so it must gate as ordinary uncurated
# DRIFT with a printed body instead of collecting the presence-only exemption
# for its directory alone.
printf '%s\n' '#!/usr/bin/env bash' 'echo docs' 'docs-script-sentinel' \
    >"$DT_TARGET/docs/build-docs.sh"
if docs_script_out="$(HARMON_INIT="$DT_TEMPLATE" bash "$STANDARDIZE_ASSETS/diff-template.sh" \
    --show "$DT_TARGET" 2>&1)"; then
    bad "diff-template gates a non-prose file under docs/ (expected non-zero exit)"
elif printf '%s\n' "$docs_script_out" | grep -qF "DRIFT    docs/build-docs.sh  (uncurated"; then
    ok "diff-template gates a non-prose file under docs/"
else
    bad "diff-template gates a non-prose file under docs/ (DRIFT diagnostic missing)"
fi
if printf '%s\n' "$docs_script_out" | grep -qF "CO-OWNED docs/build-docs.sh"; then
    bad "diff-template does not co-own a non-prose file under docs/"
else
    ok "diff-template does not co-own a non-prose file under docs/"
fi
if printf '%s\n' "$docs_script_out" | grep -qF 'docs-script-sentinel'; then
    ok "diff-template --show prints the body of a non-prose docs/ file"
else
    bad "diff-template --show prints the body of a non-prose docs/ file"
fi
git -C "$DT_TARGET" checkout HEAD -- docs/build-docs.sh

# Markdown under docs/ is still prose, so the glob restriction must not
# over-correct: guide.md stays presence-only and non-gating.
printf '%s\n' '# Guide' 'seeded guide prose' 'docs-prose-sentinel' \
    >"$DT_TARGET/docs/guide.md"
if docs_prose_out="$(HARMON_INIT="$DT_TEMPLATE" bash "$STANDARDIZE_ASSETS/diff-template.sh" "$DT_TARGET" 2>&1)"; then
    ok "diff-template still co-owns Markdown prose under docs/"
else
    bad "diff-template still co-owns Markdown prose under docs/: $docs_prose_out"
fi
if printf '%s\n' "$docs_prose_out" | grep -qF "CO-OWNED docs/guide.md"; then
    ok "diff-template reports divergent docs/ prose as CO-OWNED"
else
    bad "diff-template reports divergent docs/ prose as CO-OWNED (line missing)"
fi
git -C "$DT_TARGET" checkout HEAD -- docs/guide.md

# The exec bit is settled independently of, and before, the content class. A
# co-owned regular file whose mode diverges used to `continue` out on the
# presence-only class and exit 0. Content is IDENTICAL here, so MODE must be the
# only line: gaining `+x` on a Markdown file is a real accident, and a class
# that is informational about PROSE says nothing about the file's mode.
chmod +x "$DT_TARGET/docs/guide.md"
if co_owned_mode_out="$(HARMON_INIT="$DT_TEMPLATE" bash "$STANDARDIZE_ASSETS/diff-template.sh" "$DT_TARGET" 2>&1)"; then
    bad "diff-template gates a mode change on a co-owned file (expected non-zero exit)"
elif printf '%s\n' "$co_owned_mode_out" | grep -qF "MODE     docs/guide.md"; then
    ok "diff-template gates a mode change on a co-owned file"
else
    bad "diff-template gates a mode change on a co-owned file (MODE diagnostic missing)"
fi
if printf '%s\n' "$co_owned_mode_out" | grep -qF "CO-OWNED docs/guide.md"; then
    bad "diff-template reports no content class for a mode-only co-owned divergence"
else
    ok "diff-template reports no content class for a mode-only co-owned divergence"
fi

# Diverging in BOTH gets the gating MODE line AND the informational CO-OWNED
# line: independent findings, and the withheld body is still withheld.
printf '%s\n' '# Guide' 'seeded guide prose' 'co-owned-mode-sentinel' \
    >"$DT_TARGET/docs/guide.md"
if co_owned_both_out="$(HARMON_INIT="$DT_TEMPLATE" bash "$STANDARDIZE_ASSETS/diff-template.sh" \
    --show "$DT_TARGET" 2>&1)"; then
    bad "diff-template gates mode drift on a divergent co-owned file (expected non-zero exit)"
elif printf '%s\n' "$co_owned_both_out" | grep -qF "MODE     docs/guide.md"; then
    ok "diff-template gates mode drift on a divergent co-owned file"
else
    bad "diff-template gates mode drift on a divergent co-owned file (MODE diagnostic missing)"
fi
if printf '%s\n' "$co_owned_both_out" | grep -qF "CO-OWNED docs/guide.md"; then
    ok "diff-template keeps the co-owned content class alongside a MODE finding"
else
    bad "diff-template keeps the co-owned content class alongside a MODE finding"
fi
if printf '%s\n' "$co_owned_both_out" | grep -qF 'co-owned-mode-sentinel'; then
    bad "diff-template --show withholds a co-owned body that also has mode drift"
else
    ok "diff-template --show withholds a co-owned body that also has mode drift"
fi
git -C "$DT_TARGET" checkout HEAD -- docs/guide.md
chmod -x "$DT_TARGET/docs/guide.md"

# An uncurated regular file keeps the same mode-independence guarantee — the
# exec-bit check must not have become a co-owned-only special case.
chmod -x "$DT_TARGET/docs/build-docs.sh"
if uncurated_mode_out="$(HARMON_INIT="$DT_TEMPLATE" bash "$STANDARDIZE_ASSETS/diff-template.sh" "$DT_TARGET" 2>&1)"; then
    bad "diff-template gates an exec-bit loss on an uncurated file (expected non-zero exit)"
elif printf '%s\n' "$uncurated_mode_out" | grep -qF "MODE     docs/build-docs.sh"; then
    ok "diff-template gates an exec-bit loss on an uncurated file"
else
    bad "diff-template gates an exec-bit loss on an uncurated file (MODE diagnostic missing)"
fi
if printf '%s\n' "$uncurated_mode_out" | grep -qF "DRIFT    docs/build-docs.sh"; then
    bad "diff-template reports no content class for a mode-only uncurated divergence"
else
    ok "diff-template reports no content class for a mode-only uncurated divergence"
fi
chmod +x "$DT_TARGET/docs/build-docs.sh"

# A co-owned symlink flattened into a regular file is a STRUCTURAL divergence,
# not a prose one, so it gates rather than joining the presence-only CO-OWNED
# class: the repo now carries two independent copies of the agent instructions
# that will silently desynchronize, which is exactly the defect worth failing on.
# The CO-OWNED exemption covers content, and there is no content diff to withhold
# here — the finding is one line of metadata.
rm "$DT_TARGET/CLAUDE.md"
cp "$DT_TARGET/AGENTS.md" "$DT_TARGET/CLAUDE.md"
if flattened_out="$(HARMON_INIT="$DT_TEMPLATE" bash "$STANDARDIZE_ASSETS/diff-template.sh" "$DT_TARGET" 2>&1)"; then
    bad "diff-template gates a co-owned symlink flattened to a file (expected non-zero exit)"
elif printf '%s\n' "$flattened_out" | grep -qF "DRIFT    CLAUDE.md  (symlink mismatch"; then
    ok "diff-template gates a co-owned symlink flattened to a file"
else
    bad "diff-template gates a co-owned symlink flattened to a file (diagnostic missing)"
fi
rm "$DT_TARGET/CLAUDE.md"
ln -s AGENTS.md "$DT_TARGET/CLAUDE.md"

# A deleted alias is only visible because the sweep walks `-type l` as well as
# `-type f`. Unstaged, it is rebuilt from the index AS A SYMLINK (a regular-file
# stand-in holding the link text would read as a type mismatch); staged, it is
# real MISSING.
rm "$DT_TARGET/CLAUDE.md"
expect_ok "diff-template rebuilds an unstaged deleted symlink from the index" \
    env HARMON_INIT="$DT_TEMPLATE" bash "$STANDARDIZE_ASSETS/diff-template.sh" "$DT_TARGET"
git -C "$DT_TARGET" add -u -- CLAUDE.md
if missing_link_out="$(HARMON_INIT="$DT_TEMPLATE" bash "$STANDARDIZE_ASSETS/diff-template.sh" "$DT_TARGET" 2>&1)"; then
    bad "diff-template reports a staged symlink deletion (expected non-zero exit)"
elif printf '%s\n' "$missing_link_out" | grep -qF "MISSING  CLAUDE.md"; then
    ok "diff-template reports a staged symlink deletion as MISSING"
else
    bad "diff-template reports a staged symlink deletion (MISSING diagnostic absent)"
fi
git -C "$DT_TARGET" checkout HEAD -- CLAUDE.md

# Plain curated content drift — the manifest loop's own headline class, which
# had no direct case before.
printf '%s\n' '#!/usr/bin/env bash' 'echo customized status' \
    >"$DT_TARGET/scripts/status.sh"
if curated_out="$(HARMON_INIT="$DT_TEMPLATE" bash "$STANDARDIZE_ASSETS/diff-template.sh" "$DT_TARGET" 2>&1)"; then
    bad "diff-template reports curated content drift (expected non-zero exit)"
elif printf '%s\n' "$curated_out" | grep -qF "DRIFT    scripts/status.sh"; then
    ok "diff-template reports curated content drift"
else
    bad "diff-template reports curated content drift (DRIFT diagnostic missing)"
fi
git -C "$DT_TARGET" checkout HEAD -- scripts/status.sh

# A manifest-listed regular file swapped for a symlink to a byte-identical
# referent. `diff -q` and `-x` both FOLLOW links, so the curated loop used to
# call this perfectly clean while the sweep gated the identical shape — the
# header's "a structural divergence always gates" rule held for uncurated files
# only. The referent is a copy, so nothing about the CONTENT differs.
cp "$DT_TARGET/scripts/status.sh" "$DT_TARGET/scripts/status-impl.sh"
rm "$DT_TARGET/scripts/status.sh"
ln -s status-impl.sh "$DT_TARGET/scripts/status.sh"
if curated_link_out="$(HARMON_INIT="$DT_TEMPLATE" bash "$STANDARDIZE_ASSETS/diff-template.sh" "$DT_TARGET" 2>&1)"; then
    bad "diff-template gates a curated file flattened into a symlink (expected non-zero exit)"
elif printf '%s\n' "$curated_link_out" |
    grep -qF "DRIFT    scripts/status.sh  (symlink mismatch"; then
    ok "diff-template gates a curated file flattened into a symlink"
else
    bad "diff-template gates a curated file flattened into a symlink (diagnostic missing)"
fi
rm -f "$DT_TARGET/scripts/status.sh" "$DT_TARGET/scripts/status-impl.sh"
git -C "$DT_TARGET" checkout HEAD -- scripts/status.sh

# --- staged removal with a surviving worktree copy ---------------------------
# `git rm --cached` drops the index entry and LEAVES the file on disk, so the
# audit compared the survivor and saw nothing wrong while the next commit
# deletes a template-owned file. Three shapes, all previously silent or
# downgraded: an identical uncurated file, an ignore-matched one (dropping the
# index entry is what makes check-ignore start calling it ignored), and a
# curated one.
git -C "$DT_TARGET" rm --cached -q -- renovate.json
if staged_rm_out="$(HARMON_INIT="$DT_TEMPLATE" bash "$STANDARDIZE_ASSETS/diff-template.sh" "$DT_TARGET" 2>&1)"; then
    bad "diff-template gates a staged removal whose worktree copy survives (expected non-zero exit)"
elif printf '%s\n' "$staged_rm_out" |
    grep -qF "MISSING  renovate.json  (tracked in HEAD but staged for removal"; then
    ok "diff-template gates a staged removal whose worktree copy survives"
else
    bad "diff-template gates a staged removal whose worktree copy survives (MISSING diagnostic absent)"
fi
git -C "$DT_TARGET" reset -q HEAD -- renovate.json

printf '%s\n' 'EXAMPLE_TOKEN=staged-removal-sentinel' >"$DT_TARGET/secrets.env"
git -C "$DT_TARGET" rm --cached -q -- secrets.env
if staged_rm_ignored_out="$(HARMON_INIT="$DT_TEMPLATE" bash "$STANDARDIZE_ASSETS/diff-template.sh" "$DT_TARGET" 2>&1)"; then
    bad "diff-template gates a staged removal of an ignore-matched path (expected non-zero exit)"
elif printf '%s\n' "$staged_rm_ignored_out" |
    grep -qF "MISSING  secrets.env  (tracked in HEAD but staged for removal"; then
    ok "diff-template gates a staged removal of an ignore-matched path"
else
    bad "diff-template gates a staged removal of an ignore-matched path (MISSING diagnostic absent)"
fi
if printf '%s\n' "$staged_rm_ignored_out" | grep -qF "IGNORED  secrets.env"; then
    bad "diff-template grants no IGNORED exemption to a staged removal"
else
    ok "diff-template grants no IGNORED exemption to a staged removal"
fi
git -C "$DT_TARGET" reset -q HEAD -- secrets.env
git -C "$DT_TARGET" checkout HEAD -- secrets.env

git -C "$DT_TARGET" rm --cached -q -- scripts/status.sh
if staged_rm_curated_out="$(HARMON_INIT="$DT_TEMPLATE" bash "$STANDARDIZE_ASSETS/diff-template.sh" "$DT_TARGET" 2>&1)"; then
    bad "diff-template gates a staged removal of a curated file (expected non-zero exit)"
elif printf '%s\n' "$staged_rm_curated_out" |
    grep -qF "MISSING  scripts/status.sh  (tracked in HEAD but staged for removal"; then
    ok "diff-template gates a staged removal of a curated file"
else
    bad "diff-template gates a staged removal of a curated file (MISSING diagnostic absent)"
fi
git -C "$DT_TARGET" reset -q HEAD -- scripts/status.sh

expect_ok "diff-template returns to a clean baseline after the sweep cases" \
    env HARMON_INIT="$DT_TEMPLATE" bash "$STANDARDIZE_ASSETS/diff-template.sh" "$DT_TARGET"

# --- ignore probes must fail CLOSED ------------------------------------------
# `git check-ignore` is three-valued: 0 = match, 1 = no match, anything else =
# the probe failed. Folding "failed" in with "no match" makes the withholding
# guarantee fail OPEN — the run would decide nothing is ignored and print the
# body of a file somebody marked local-only. An exclude file that is a directory
# makes check-ignore exit 128 while every other git call in the run is fine, so
# it isolates the probe; setting it in the TARGET's own config keeps it off the
# copier render, which reads the ambient config too. .envrc is already the
# divergent-but-withheld file in this baseline, so the probe is reached with
# nothing else queued to print.
#
# The divergent file is .vscode/settings.json, not .envrc: .envrc is ignored by
# BOTH rule sets, so the render side would withhold its body even with the repo
# probe broken and the leak would not show. .vscode/settings.json is ignored by
# the repo alone, so a probe that reports "not ignored" on error is the only
# thing standing between its contents and stdout.
DT_BAD_EXCLUDES="$TMPROOT/diff-template-bad-excludes-dir"
mkdir -p "$DT_BAD_EXCLUDES"
printf '%s\n' '{ "editor.tabSize": 4, "token": "vscode-probe-leak-sentinel" }' \
    >"$DT_TARGET/.vscode/settings.json"
git -C "$DT_TARGET" config core.excludesFile "$DT_BAD_EXCLUDES"
probe_fail_rc=0
probe_fail_out="$(HARMON_INIT="$DT_TEMPLATE" bash "$STANDARDIZE_ASSETS/diff-template.sh" \
    --show "$DT_TARGET" 2>&1)" || probe_fail_rc=$?
if [ "$probe_fail_rc" -eq 2 ]; then
    ok "diff-template exits 2 when an ignore probe errors"
else
    bad "diff-template exits 2 when an ignore probe errors (got $probe_fail_rc)"
fi
if printf '%s\n' "$probe_fail_out" |
    grep -qF "FAIL: cannot evaluate the repo's ignore rules"; then
    ok "diff-template names the ignore probe that could not be evaluated"
else
    bad "diff-template names the ignore probe that could not be evaluated"
fi
if printf '%s\n' "$probe_fail_out" |
    grep -qE 'vscode-probe-leak-sentinel|envrc-sentinel-withheld'; then
    bad "diff-template prints no diff body when an ignore probe errors"
else
    ok "diff-template prints no diff body when an ignore probe errors"
fi
git -C "$DT_TARGET" config --unset core.excludesFile
cp "$DT_TEMPLATE/template/.vscode/settings.json" "$DT_TARGET/.vscode/settings.json"

# The scratch evaluator built from the render's own .gitignore files must not
# degrade to "the template declares nothing local" when it cannot be built —
# that silently downgrades every IGNORED path to a printable one. An invalid
# init.defaultBranch fails the `git init` for that scratch repo and nothing else
# in the run.
init_fail_rc=0
init_fail_out="$(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=init.defaultBranch \
    GIT_CONFIG_VALUE_0='bad branch name' HARMON_INIT="$DT_TEMPLATE" \
    bash "$STANDARDIZE_ASSETS/diff-template.sh" --show "$DT_TARGET" 2>&1)" || init_fail_rc=$?
if [ "$init_fail_rc" -eq 2 ]; then
    ok "diff-template exits 2 when the template ignore evaluator cannot be built"
else
    bad "diff-template exits 2 when the template ignore evaluator cannot be built (got $init_fail_rc)"
fi
if printf '%s\n' "$init_fail_out" |
    grep -qF "FAIL: cannot initialize the template ignore evaluator"; then
    ok "diff-template says why the template ignore evaluator is unavailable"
else
    bad "diff-template says why the template ignore evaluator is unavailable"
fi
if printf '%s\n' "$init_fail_out" | grep -qF 'envrc-sentinel-withheld'; then
    bad "diff-template prints no diff body when the ignore evaluator is unavailable"
else
    ok "diff-template prints no diff body when the ignore evaluator is unavailable"
fi
expect_ok "diff-template recovers once the ignore probes work again" \
    env HARMON_INIT="$DT_TEMPLATE" bash "$STANDARDIZE_ASSETS/diff-template.sh" "$DT_TARGET"

# --- work-tree detection must fail CLOSED ------------------------------------
# "Not a repository" and "I cannot tell whether this is a repository" are
# different answers. Reading the second as the first drops the repo half of the
# withholding probe, so a repo-only-ignored secret prints under --show precisely
# because git could not read the repo's metadata. A garbage .git file makes
# rev-parse fail with `invalid gitfile format`, which is emphatically not the
# "not a git repository" it reports for a genuine plain directory.
DT_CORRUPT_TARGET="$TMPROOT/diff-template-corrupt-git"
cp -pR "$DT_TARGET" "$DT_CORRUPT_TARGET"
rm -rf "$DT_CORRUPT_TARGET/.git"
# Without a repo of its own the copy's .envrc can no longer be IGNORED, so sync
# it to the render; a clean baseline first is what makes the exit 2 below
# attributable to the corrupt .git rather than to anything else in the copy.
cp "$DT_TEMPLATE/template/.envrc" "$DT_CORRUPT_TARGET/.envrc"
expect_ok "diff-template audits a genuine plain dir with no .git at all" \
    env HARMON_INIT="$DT_TEMPLATE" bash "$STANDARDIZE_ASSETS/diff-template.sh" \
    --show "$DT_CORRUPT_TARGET"
printf '%s\n' '{ "editor.tabSize": 4, "token": "corrupt-git-leak-sentinel" }' \
    >"$DT_CORRUPT_TARGET/.vscode/settings.json"
printf '%s\n' 'this file is not a gitdir pointer' >"$DT_CORRUPT_TARGET/.git"
corrupt_git_rc=0
corrupt_git_out="$(HARMON_INIT="$DT_TEMPLATE" bash "$STANDARDIZE_ASSETS/diff-template.sh" \
    --show "$DT_CORRUPT_TARGET" 2>&1)" || corrupt_git_rc=$?
if [ "$corrupt_git_rc" -eq 2 ]; then
    ok "diff-template exits 2 when it cannot tell whether the target is a work tree"
else
    bad "diff-template exits 2 when it cannot tell whether the target is a work tree (got $corrupt_git_rc)"
fi
if printf '%s\n' "$corrupt_git_out" |
    grep -qF "FAIL: cannot determine whether"; then
    ok "diff-template says it could not classify the target work tree"
else
    bad "diff-template says it could not classify the target work tree"
fi
if printf '%s\n' "$corrupt_git_out" | grep -qF 'corrupt-git-leak-sentinel'; then
    bad "diff-template prints no diff body when work-tree detection fails"
else
    ok "diff-template prints no diff body when work-tree detection fails"
fi

# --- a symlinked parent directory is structural, never something to read -----
# `-L` tests only a path's final component, so a repo whose `scripts` is a link
# to somewhere outside let the comparison read — and --show print — a file that
# is not the repo's at all. The rule is any symlinked parent, escaping or not:
# the template renders real directories.
DT_LINKED_OUT="$TMPROOT/diff-template-outside-scripts"
mkdir -p "$DT_LINKED_OUT"
printf '%s\n' '#!/usr/bin/env bash' 'echo status' 'EXTERNAL-SCRIPT-SENTINEL' \
    >"$DT_LINKED_OUT/status.sh"
chmod +x "$DT_LINKED_OUT/status.sh"
DT_LINKED_TARGET="$TMPROOT/diff-template-linked-parent"
cp -pR "$DT_TARGET" "$DT_LINKED_TARGET"
rm -rf "$DT_LINKED_TARGET/scripts"
ln -s ../diff-template-outside-scripts "$DT_LINKED_TARGET/scripts"
if linked_curated_out="$(HARMON_INIT="$DT_TEMPLATE" bash "$STANDARDIZE_ASSETS/diff-template.sh" \
    --show "$DT_LINKED_TARGET" 2>&1)"; then
    bad "diff-template gates a curated file under a symlinked parent (expected non-zero exit)"
elif printf '%s\n' "$linked_curated_out" |
    grep -qF "DRIFT    scripts/status.sh  (parent directory is a symlink leaving the repository"; then
    ok "diff-template gates a curated file under a symlinked parent"
else
    bad "diff-template gates a curated file under a symlinked parent (diagnostic missing)"
fi
if printf '%s\n' "$linked_curated_out" | grep -qF 'EXTERNAL-SCRIPT-SENTINEL'; then
    bad "diff-template reads no content through a symlinked parent (curated)"
else
    ok "diff-template reads no content through a symlinked parent (curated)"
fi

# Same shape one loop over: .vscode holds exactly one rendered path and the
# manifest does not list it, so this exercises the sweep. The copy drops
# info/exclude so the file is not repo-ignored either — otherwise withholding
# would mask an external body that the sweep should never have read.
DT_LINKED_VSCODE="$TMPROOT/diff-template-outside-vscode"
mkdir -p "$DT_LINKED_VSCODE"
printf '%s\n' '{ "editor.tabSize": 8, "note": "EXTERNAL-VSCODE-SENTINEL" }' \
    >"$DT_LINKED_VSCODE/settings.json"
DT_LINKED_SWEEP="$TMPROOT/diff-template-linked-parent-sweep"
cp -pR "$DT_TARGET" "$DT_LINKED_SWEEP"
rm -f "$DT_LINKED_SWEEP/.git/info/exclude"
rm -rf "$DT_LINKED_SWEEP/.vscode"
ln -s ../diff-template-outside-vscode "$DT_LINKED_SWEEP/.vscode"
if linked_sweep_out="$(HARMON_INIT="$DT_TEMPLATE" bash "$STANDARDIZE_ASSETS/diff-template.sh" \
    --show "$DT_LINKED_SWEEP" 2>&1)"; then
    bad "diff-template gates a swept file under a symlinked parent (expected non-zero exit)"
elif printf '%s\n' "$linked_sweep_out" |
    grep -qF "DRIFT    .vscode/settings.json  (parent directory is a symlink leaving the repository"; then
    ok "diff-template gates a swept file under a symlinked parent"
else
    bad "diff-template gates a swept file under a symlinked parent (diagnostic missing)"
fi
if printf '%s\n' "$linked_sweep_out" | grep -qF 'EXTERNAL-VSCODE-SENTINEL'; then
    bad "diff-template reads no content through a symlinked parent (sweep)"
else
    ok "diff-template reads no content through a symlinked parent (sweep)"
fi

# A symlinked parent that stays INSIDE the target is still structural — the
# template renders real directories — and the note says so without claiming an
# escape that did not happen.
DT_LINKED_INSIDE="$TMPROOT/diff-template-linked-parent-inside"
cp -pR "$DT_TARGET" "$DT_LINKED_INSIDE"
mkdir -p "$DT_LINKED_INSIDE/real-vscode"
cp "$DT_TEMPLATE/template/.vscode/settings.json" "$DT_LINKED_INSIDE/real-vscode/settings.json"
rm -rf "$DT_LINKED_INSIDE/.vscode"
ln -s real-vscode "$DT_LINKED_INSIDE/.vscode"
if linked_inside_out="$(HARMON_INIT="$DT_TEMPLATE" bash "$STANDARDIZE_ASSETS/diff-template.sh" \
    "$DT_LINKED_INSIDE" 2>&1)"; then
    bad "diff-template gates an in-tree symlinked parent (expected non-zero exit)"
elif printf '%s\n' "$linked_inside_out" |
    grep -qF "DRIFT    .vscode/settings.json  (parent directory is a symlink; the template renders real directories"; then
    ok "diff-template gates an in-tree symlinked parent"
else
    bad "diff-template gates an in-tree symlinked parent (diagnostic missing)"
fi

# --- the index fallback belongs to the target, not to an ambient repo --------
# `:path` in the index is resolved relative to the REPOSITORY ROOT, whatever the
# cwd, so for a plain-directory target nested inside another repo the whole
# outer root namespace shadows it: any rendered path the outer repo happens to
# track at the same relative name resolved to the outer repo's blob. The target
# then looked like it HAD a file it does not have — MISSING suppressed, and the
# outer project's content compared and printed in its place.
DT_OUTER_PARENT="$TMPROOT/diff-template-outer-index-parent"
mkdir -p "$DT_OUTER_PARENT"
git_init "$DT_OUTER_PARENT"
printf '%s\n' '{ "extends": ["outer-repo-blob-sentinel"] }' \
    >"$DT_OUTER_PARENT/renovate.json"
git_commit_all "$DT_OUTER_PARENT" "outer repo tracks a same-named path"
DT_OUTER_TARGET="$DT_OUTER_PARENT/plain-target"
cp -pR "$DT_TARGET" "$DT_OUTER_TARGET"
rm -rf "$DT_OUTER_TARGET/.git"
cp "$DT_TEMPLATE/template/.envrc" "$DT_OUTER_TARGET/.envrc"
rm "$DT_OUTER_TARGET/renovate.json"
if outer_index_out="$(HARMON_INIT="$DT_TEMPLATE" bash "$STANDARDIZE_ASSETS/diff-template.sh" \
    --show "$DT_OUTER_TARGET" 2>&1)"; then
    bad "diff-template reports a nested plain target's absent file as MISSING (expected non-zero exit)"
elif printf '%s\n' "$outer_index_out" | grep -qF "MISSING  renovate.json"; then
    ok "diff-template reports a nested plain target's absent file as MISSING"
else
    bad "diff-template reports a nested plain target's absent file as MISSING (diagnostic missing)"
fi
if printf '%s\n' "$outer_index_out" | grep -qF 'outer-repo-blob-sentinel'; then
    bad "diff-template never resolves a nested plain target through the outer index"
else
    ok "diff-template never resolves a nested plain target through the outer index"
fi

# --- an index fallback may not paper over a swapped-out directory ------------
# A tracked directory replaced by a symlink that does not lead to the rendered
# file leaves the index entry intact, so the fallback materialized the blob
# under the workdir — where the physical-parent check trivially passes, because
# the snapshot's parent really is where the snapshot says it is. The audit went
# clean on a repo whose directory now points somewhere else entirely. The parent
# check therefore runs on the WORK-TREE location before the fallback is allowed.
DT_SWAPPED_DIR="$TMPROOT/diff-template-swapped-dir"
cp -pR "$DT_TARGET" "$DT_SWAPPED_DIR"
rm -rf "$DT_SWAPPED_DIR/scripts"
ln -s ../nowhere-at-all "$DT_SWAPPED_DIR/scripts"
if swapped_dir_out="$(HARMON_INIT="$DT_TEMPLATE" bash "$STANDARDIZE_ASSETS/diff-template.sh" \
    --show "$DT_SWAPPED_DIR" 2>&1)"; then
    bad "diff-template gates a tracked dir swapped for a dangling symlink (expected non-zero exit)"
elif printf '%s\n' "$swapped_dir_out" |
    grep -qF "DRIFT    scripts/status.sh  (parent directory is a symlink that leads nowhere"; then
    ok "diff-template gates a tracked dir swapped for a dangling symlink"
else
    bad "diff-template gates a tracked dir swapped for a dangling symlink (diagnostic missing)"
fi

# Same shape, but the link leads somewhere real that simply lacks the file — the
# index entry is just as intact and the fallback was just as wrong.
DT_SWAPPED_OUT="$TMPROOT/diff-template-swapped-dir-outside"
mkdir -p "$TMPROOT/diff-template-empty-outside"
cp -pR "$DT_TARGET" "$DT_SWAPPED_OUT"
rm -rf "$DT_SWAPPED_OUT/scripts"
ln -s ../diff-template-empty-outside "$DT_SWAPPED_OUT/scripts"
if swapped_out_out="$(HARMON_INIT="$DT_TEMPLATE" bash "$STANDARDIZE_ASSETS/diff-template.sh" \
    --show "$DT_SWAPPED_OUT" 2>&1)"; then
    bad "diff-template gates a tracked dir swapped for an outside symlink (expected non-zero exit)"
elif printf '%s\n' "$swapped_out_out" |
    grep -qF "DRIFT    scripts/status.sh  (parent directory is a symlink leaving the repository"; then
    ok "diff-template gates a tracked dir swapped for an outside symlink"
else
    bad "diff-template gates a tracked dir swapped for an outside symlink (diagnostic missing)"
fi

# --- an ABSENT parent is not a structural one --------------------------------
# A failed `cd` cannot tell "the directory was replaced by a link that goes
# nowhere" from "the directory is not there", and treating both as structural
# broke the two cases that depend on an absent parent: a template that grew a
# new nested directory (every file under it is MISSING) and an unstaged deletion
# of a tracked directory (the index snapshot covers it).
rm -rf "$DT_TARGET/.vscode"
if absent_dir_out="$(HARMON_INIT="$DT_TEMPLATE" bash "$STANDARDIZE_ASSETS/diff-template.sh" "$DT_TARGET" 2>&1)"; then
    bad "diff-template reports a file under an absent directory as MISSING (expected non-zero exit)"
elif printf '%s\n' "$absent_dir_out" | grep -qF "MISSING  .vscode/settings.json"; then
    ok "diff-template reports a file under an absent directory as MISSING"
else
    bad "diff-template reports a file under an absent directory as MISSING (diagnostic missing)"
fi
if printf '%s\n' "$absent_dir_out" | grep -qF ".vscode/settings.json  (parent directory"; then
    bad "diff-template calls an absent directory absent, not structural"
else
    ok "diff-template calls an absent directory absent, not structural"
fi
mkdir -p "$DT_TARGET/.vscode"
cp "$DT_TEMPLATE/template/.vscode/settings.json" "$DT_TARGET/.vscode/settings.json"

# Unstaged deletion of a whole tracked DIRECTORY, not just a file: the
# documented index-snapshot behaviour has to survive the parent check, which
# runs before the fallback is even consulted.
rm -rf "$DT_TARGET/scripts"
expect_ok "diff-template compares an unstaged tracked directory deletion from the index" \
    env HARMON_INIT="$DT_TEMPLATE" bash "$STANDARDIZE_ASSETS/diff-template.sh" "$DT_TARGET"
git -C "$DT_TARGET" checkout HEAD -- scripts
expect_ok "diff-template returns to a clean baseline after the absent-parent cases" \
    env HARMON_INIT="$DT_TEMPLATE" bash "$STANDARDIZE_ASSETS/diff-template.sh" "$DT_TARGET"

# A brand-new nested directory two levels deep, so the component walk is
# exercised past its first step rather than only at the repo root.
DT_NEWDIR_TEMPLATE="$TMPROOT/diff-template-newdir-source"
mkdir -p "$DT_NEWDIR_TEMPLATE/template/newdir/nested"
cat >"$DT_NEWDIR_TEMPLATE/copier.yml" <<'EOF'
_min_copier_version: "9.4.0"
_subdirectory: template
# diff-template derives its OWNED class from _skip_if_exists and refuses to run
# without one; this fixture needs no repo-owned path of its own, only a
# declaration for the derivation to read.
_skip_if_exists:
  - CHANGELOG.md
project_name:
  type: str
  default: New Dir
EOF
printf '%s\n' 'kept' >"$DT_NEWDIR_TEMPLATE/template/keep.txt"
printf '%s\n' 'one' >"$DT_NEWDIR_TEMPLATE/template/newdir/one.txt"
printf '%s\n' 'two' >"$DT_NEWDIR_TEMPLATE/template/newdir/nested/two.txt"
git_init "$DT_NEWDIR_TEMPLATE"
git_commit_all "$DT_NEWDIR_TEMPLATE" "template grows a nested directory"
git -C "$DT_NEWDIR_TEMPLATE" tag v1.0.0
DT_NEWDIR_TARGET="$TMPROOT/diff-template-newdir-target"
mkdir -p "$DT_NEWDIR_TARGET"
printf '%s\n' 'kept' >"$DT_NEWDIR_TARGET/keep.txt"
cat >"$DT_NEWDIR_TARGET/.copier-answers.yml" <<EOF
_commit: v1.0.0
_src_path: file://$DT_NEWDIR_TEMPLATE
project_name: New Dir
EOF
git_init "$DT_NEWDIR_TARGET"
git_commit_all "$DT_NEWDIR_TARGET" "target predates the nested directory"
if newdir_out="$(HARMON_INIT="$DT_NEWDIR_TEMPLATE" bash "$STANDARDIZE_ASSETS/diff-template.sh" \
    "$DT_NEWDIR_TARGET" 2>&1)"; then
    bad "diff-template reports a whole absent nested directory as MISSING (expected non-zero exit)"
elif printf '%s\n' "$newdir_out" | grep -qF "MISSING  newdir/nested/two.txt" &&
    printf '%s\n' "$newdir_out" | grep -qF "MISSING  newdir/one.txt"; then
    ok "diff-template reports a whole absent nested directory as MISSING"
else
    bad "diff-template reports a whole absent nested directory as MISSING (diagnostic missing)"
fi
if printf '%s\n' "$newdir_out" | grep -qF "parent directory"; then
    bad "diff-template reports no structural finding for an absent nested directory"
else
    ok "diff-template reports no structural finding for an absent nested directory"
fi

# --- nested-worktree guard ---------------------------------------------------
# A plain directory that merely SITS INSIDE another repository's work tree is
# still a plain directory. `rev-parse --is-inside-work-tree` answers true there,
# so the sweep used to apply the PARENT repo's ignore rules and downgrade real
# divergence to a non-gating IGNORED. The clean copy below is the same target
# shape as DT_TARGET minus its .git, so the mutation's exit code is its own.
DT_NESTED_PARENT="$TMPROOT/diff-template-nested-parent"
mkdir -p "$DT_NESTED_PARENT"
git_init "$DT_NESTED_PARENT"
printf '%s\n' 'renovate.json' >"$DT_NESTED_PARENT/.gitignore"
DT_NESTED_TARGET="$DT_NESTED_PARENT/plain-target"
cp -pR "$DT_TARGET" "$DT_NESTED_TARGET"
rm -rf "$DT_NESTED_TARGET/.git"
# Without a repo of its own the copy's .envrc can no longer be IGNORED, so sync
# it to the render; this case is about renovate.json alone.
cp "$DT_TEMPLATE/template/.envrc" "$DT_NESTED_TARGET/.envrc"
expect_ok "diff-template baselines clean against a plain dir nested in another repo" \
    env HARMON_INIT="$DT_TEMPLATE" bash "$STANDARDIZE_ASSETS/diff-template.sh" "$DT_NESTED_TARGET"
printf '%s\n' '{ "extends": ["config:base"] }' >"$DT_NESTED_TARGET/renovate.json"
if nested_out="$(HARMON_INIT="$DT_TEMPLATE" bash "$STANDARDIZE_ASSETS/diff-template.sh" "$DT_NESTED_TARGET" 2>&1)"; then
    bad "diff-template gates a nested plain target the parent repo ignores (expected non-zero exit)"
elif printf '%s\n' "$nested_out" | grep -qF "DRIFT    renovate.json  (uncurated"; then
    ok "diff-template gates a nested plain target the parent repo ignores"
else
    bad "diff-template gates a nested plain target the parent repo ignores (DRIFT diagnostic missing)"
fi
if printf '%s\n' "$nested_out" | grep -qF "IGNORED  "; then
    bad "diff-template borrows no IGNORED class from a nested target's parent repo"
else
    ok "diff-template borrows no IGNORED class from a nested target's parent repo"
fi

# The render half of withholding needs no work tree, so it still applies to a
# plain-directory target where the repo half cannot: a repo that FAILED to
# ignore a template-declared-local file holds the same secret as one that did.
printf '%s\n' 'export EXAMPLE_SETTING=plain-dir-envrc-sentinel' \
    >"$DT_NESTED_TARGET/.envrc"
if nested_envrc_out="$(HARMON_INIT="$DT_TEMPLATE" bash "$STANDARDIZE_ASSETS/diff-template.sh" \
    --show "$DT_NESTED_TARGET" 2>&1)"; then
    bad "diff-template gates a template-ignored file in a plain dir (expected non-zero exit)"
elif printf '%s\n' "$nested_envrc_out" | grep -qF "DRIFT    .envrc"; then
    ok "diff-template gates a template-ignored file in a plain dir"
else
    bad "diff-template gates a template-ignored file in a plain dir (DRIFT diagnostic missing)"
fi
if printf '%s\n' "$nested_envrc_out" | grep -qF 'plain-dir-envrc-sentinel'; then
    bad "diff-template --show withholds a template-ignored body without a repo rule"
else
    ok "diff-template --show withholds a template-ignored body without a repo rule"
fi

# --- a render that ships no .gitignore at all --------------------------------
# With nothing declaring anything local, the IGNORED class cannot be granted:
# every path the repo's own rules match still gates. This is the guard on the
# render-side evaluator having no rules to evaluate.
DT_NOIGNORE_TEMPLATE="$TMPROOT/diff-template-noignore-source"
mkdir -p "$DT_NOIGNORE_TEMPLATE/template"
cat >"$DT_NOIGNORE_TEMPLATE/copier.yml" <<'EOF'
_min_copier_version: "9.4.0"
_subdirectory: template
# diff-template derives its OWNED class from _skip_if_exists and refuses to run
# without one; this fixture needs no repo-owned path of its own, only a
# declaration for the derivation to read.
_skip_if_exists:
  - CHANGELOG.md
project_name:
  type: str
  default: No Ignore
EOF
printf '%s\n' 'export EXAMPLE_SETTING=template-default' \
    >"$DT_NOIGNORE_TEMPLATE/template/.envrc"
git_init "$DT_NOIGNORE_TEMPLATE"
git_commit_all "$DT_NOIGNORE_TEMPLATE" "no-ignore template"
git -C "$DT_NOIGNORE_TEMPLATE" tag v1.0.0
DT_NOIGNORE_TARGET="$TMPROOT/diff-template-noignore-target"
mkdir -p "$DT_NOIGNORE_TARGET"
printf '%s\n' 'export EXAMPLE_SETTING=noignore-sentinel' >"$DT_NOIGNORE_TARGET/.envrc"
printf '%s\n' '.envrc' >"$DT_NOIGNORE_TARGET/.gitignore"
cat >"$DT_NOIGNORE_TARGET/.copier-answers.yml" <<EOF
_commit: v1.0.0
_src_path: file://$DT_NOIGNORE_TEMPLATE
project_name: No Ignore
EOF
git_init "$DT_NOIGNORE_TARGET"
git_commit_all "$DT_NOIGNORE_TARGET" "no-ignore target"
if noignore_out="$(HARMON_INIT="$DT_NOIGNORE_TEMPLATE" bash "$STANDARDIZE_ASSETS/diff-template.sh" \
    --show "$DT_NOIGNORE_TARGET" 2>&1)"; then
    bad "diff-template grants no IGNORED class when the render ships no .gitignore (expected non-zero exit)"
elif printf '%s\n' "$noignore_out" |
    grep -qF "DRIFT    .envrc  (repo-ignored, but the template tracks this file"; then
    ok "diff-template grants no IGNORED class when the render ships no .gitignore"
else
    bad "diff-template grants no IGNORED class when the render ships no .gitignore (DRIFT diagnostic missing)"
fi
if printf '%s\n' "$noignore_out" | grep -qF "IGNORED  "; then
    bad "diff-template emits no IGNORED line for a render with no ignore rules"
else
    ok "diff-template emits no IGNORED line for a render with no ignore rules"
fi
if printf '%s\n' "$noignore_out" | grep -qF 'noignore-sentinel'; then
    bad "diff-template --show still withholds a repo-ignored body with no render rules"
else
    ok "diff-template --show still withholds a repo-ignored body with no render rules"
fi

# --- the INDEX is part of what the repo has ----------------------------------
# Staging a divergence and then restoring only the WORKING TREE left the audit
# comparing a clean disk copy while the next commit carried the divergence —
# the same blind spot as `git rm --cached`, one class over. The comparison
# therefore inspects the staged copy too whenever the disk copy came out clean.
printf '%s\n' '{ "extends": ["staged-only-sentinel"] }' >"$DT_TARGET/renovate.json"
git -C "$DT_TARGET" add -- renovate.json
cp "$DT_TEMPLATE/template/renovate.json" "$DT_TARGET/renovate.json"
if staged_content_out="$(HARMON_INIT="$DT_TEMPLATE" bash "$STANDARDIZE_ASSETS/diff-template.sh" \
    --show "$DT_TARGET" 2>&1)"; then
    bad "diff-template reports a staged uncurated divergence the worktree hides (expected non-zero exit)"
elif printf '%s\n' "$staged_content_out" |
    grep -qF "DRIFT    renovate.json  (uncurated — staged content differs"; then
    ok "diff-template reports a staged uncurated divergence the worktree hides"
else
    bad "diff-template reports a staged uncurated divergence the worktree hides (DRIFT diagnostic missing)"
fi
# No body: the staged bytes are not the disk copy `diff -u` would be reading,
# and the line already says everything actionable.
if printf '%s\n' "$staged_content_out" | grep -qF 'staged-only-sentinel'; then
    bad "diff-template prints no body for a staged-only divergence"
else
    ok "diff-template prints no body for a staged-only divergence"
fi
git -C "$DT_TARGET" reset -q HEAD -- renovate.json
git -C "$DT_TARGET" checkout HEAD -- renovate.json

# The exec bit is staged state too: `update-index --chmod=+x` records 100755
# while the disk copy stays 644, so the mode the next commit carries is not the
# mode on disk. MODE is structural and gates for every class, staged included.
git -C "$DT_TARGET" update-index --chmod=+x -- renovate.json
if staged_mode_out="$(HARMON_INIT="$DT_TEMPLATE" bash "$STANDARDIZE_ASSETS/diff-template.sh" "$DT_TARGET" 2>&1)"; then
    bad "diff-template reports a staged mode change the worktree hides (expected non-zero exit)"
elif printf '%s\n' "$staged_mode_out" |
    grep -qF "MODE     renovate.json  (staged mode differs"; then
    ok "diff-template reports a staged mode change the worktree hides"
else
    bad "diff-template reports a staged mode change the worktree hides (MODE diagnostic missing)"
fi
git -C "$DT_TARGET" update-index --chmod=-x -- renovate.json
git -C "$DT_TARGET" reset -q HEAD -- renovate.json
git -C "$DT_TARGET" checkout HEAD -- renovate.json

# MIXED state: the worktree diverges on content while the index independently
# carries a staged mode change. The dimensions are probed separately, so gating
# on the disk finding is no reason to hide the staged one — a clean-on-both
# precondition would have skipped the index entirely.
printf '%s\n' '{ "extends": ["mixed-state-sentinel"] }' >"$DT_TARGET/renovate.json"
git -C "$DT_TARGET" update-index --chmod=+x -- renovate.json
if mixed_state_out="$(HARMON_INIT="$DT_TEMPLATE" bash "$STANDARDIZE_ASSETS/diff-template.sh" "$DT_TARGET" 2>&1)"; then
    bad "diff-template reports both a worktree and a staged dimension (expected non-zero exit)"
elif printf '%s\n' "$mixed_state_out" | grep -qF "DRIFT    renovate.json  (uncurated"; then
    ok "diff-template reports both a worktree and a staged dimension"
else
    bad "diff-template reports both a worktree and a staged dimension (DRIFT diagnostic missing)"
fi
if printf '%s\n' "$mixed_state_out" |
    grep -qF "MODE     renovate.json  (staged mode differs"; then
    ok "diff-template reports a staged mode change alongside worktree content drift"
else
    bad "diff-template reports a staged mode change alongside worktree content drift"
fi
git -C "$DT_TARGET" update-index --chmod=-x -- renovate.json
git -C "$DT_TARGET" reset -q HEAD -- renovate.json
git -C "$DT_TARGET" checkout HEAD -- renovate.json

# The curated loop owes the same guarantee — the manifest is the more
# load-bearing set, not the weaker one.
printf '%s\n' '#!/usr/bin/env bash' 'echo staged curated' \
    >"$DT_TARGET/scripts/status.sh"
git -C "$DT_TARGET" add -- scripts/status.sh
cp "$DT_TEMPLATE/template/scripts/status.sh" "$DT_TARGET/scripts/status.sh"
chmod +x "$DT_TARGET/scripts/status.sh"
if staged_curated_out="$(HARMON_INIT="$DT_TEMPLATE" bash "$STANDARDIZE_ASSETS/diff-template.sh" "$DT_TARGET" 2>&1)"; then
    bad "diff-template reports a staged curated divergence the worktree hides (expected non-zero exit)"
elif printf '%s\n' "$staged_curated_out" |
    grep -qF "DRIFT    scripts/status.sh  (staged content differs"; then
    ok "diff-template reports a staged curated divergence the worktree hides"
else
    bad "diff-template reports a staged curated divergence the worktree hides (DRIFT diagnostic missing)"
fi
git -C "$DT_TARGET" reset -q HEAD -- scripts/status.sh
git -C "$DT_TARGET" checkout HEAD -- scripts/status.sh

# …and the CO-OWNED contract survives the new probe: content is what the repo
# owns there, staged or not, so a staged prose divergence must not start gating
# a class whose whole point is that its content never does.
printf '%s\n' '# Test Project agents' 'seeded agent prose' 'staged-prose-sentinel' \
    >"$DT_TARGET/AGENTS.md"
git -C "$DT_TARGET" add -- AGENTS.md
cp "$DT_TEMPLATE/template/AGENTS.md" "$DT_TARGET/AGENTS.md"
if staged_prose_out="$(HARMON_INIT="$DT_TEMPLATE" bash "$STANDARDIZE_ASSETS/diff-template.sh" "$DT_TARGET" 2>&1)"; then
    ok "diff-template does not gate a staged co-owned prose divergence"
else
    bad "diff-template does not gate a staged co-owned prose divergence: $staged_prose_out"
fi
if printf '%s\n' "$staged_prose_out" | grep -qF "DRIFT    AGENTS.md"; then
    bad "diff-template reports no staged DRIFT for co-owned prose"
else
    ok "diff-template reports no staged DRIFT for co-owned prose"
fi
git -C "$DT_TARGET" reset -q HEAD -- AGENTS.md
git -C "$DT_TARGET" checkout HEAD -- AGENTS.md

# …but a STRUCTURAL staged change is not prose. Staging AGENTS.md as a symlink
# while the worktree keeps the real file means the next commit turns the agent
# instructions into an alias, and "structural divergence always gates" holds for
# staged state exactly as it does on disk — the CO-OWNED exemption covers
# content, and nobody owns a file that stopped being a file.
staged_link_blob="$(printf 'docs/guide.md' |
    git -C "$DT_TARGET" hash-object -w --stdin)"
git -C "$DT_TARGET" update-index --add --cacheinfo \
    "120000,$staged_link_blob,AGENTS.md"
if staged_structural_out="$(HARMON_INIT="$DT_TEMPLATE" bash "$STANDARDIZE_ASSETS/diff-template.sh" "$DT_TARGET" 2>&1)"; then
    bad "diff-template gates a staged structural change on a co-owned path (expected non-zero exit)"
elif printf '%s\n' "$staged_structural_out" |
    grep -qF "DRIFT    AGENTS.md  (staged symlink mismatch"; then
    ok "diff-template gates a staged structural change on a co-owned path"
else
    bad "diff-template gates a staged structural change on a co-owned path (diagnostic missing)"
fi
git -C "$DT_TARGET" reset -q HEAD -- AGENTS.md
git -C "$DT_TARGET" checkout HEAD -- AGENTS.md

# MIXED co-owned state: ordinary prose drift on disk AND the staged alias. The
# worktree finding is the non-gating CO-OWNED one, so making the structural
# check conditional on a clean worktree hid the staged swap completely and the
# run exited 0 — the structural verdict has to be independent of whether the
# prose also moved.
printf '%s\n' '# Test Project agents' 'seeded agent prose' 'mixed-co-owned-sentinel' \
    >"$DT_TARGET/AGENTS.md"
git -C "$DT_TARGET" update-index --add --cacheinfo \
    "120000,$staged_link_blob,AGENTS.md"
if mixed_co_owned_out="$(HARMON_INIT="$DT_TEMPLATE" bash "$STANDARDIZE_ASSETS/diff-template.sh" "$DT_TARGET" 2>&1)"; then
    bad "diff-template gates a staged alias under co-owned prose drift (expected non-zero exit)"
elif printf '%s\n' "$mixed_co_owned_out" |
    grep -qF "DRIFT    AGENTS.md  (staged symlink mismatch"; then
    ok "diff-template gates a staged alias under co-owned prose drift"
else
    bad "diff-template gates a staged alias under co-owned prose drift (diagnostic missing)"
fi
if printf '%s\n' "$mixed_co_owned_out" | grep -qF "CO-OWNED AGENTS.md"; then
    ok "diff-template keeps the co-owned prose class alongside a staged alias"
else
    bad "diff-template keeps the co-owned prose class alongside a staged alias"
fi
git -C "$DT_TARGET" reset -q HEAD -- AGENTS.md
git -C "$DT_TARGET" checkout HEAD -- AGENTS.md

# The CO-OWNED class's value is the INVERSE signal — a line that DISAPPEARS
# means the repo's prose went byte-identical to the template's. A clobber that
# is STAGED but not yet committed reads as the healthy state: the worktree still
# diverges, so the line still prints, while the next commit removes the prose.
# The repo's committed AGENTS.md carries customization here, the index is reset
# to the template's bytes, and the worktree keeps the customization.
printf '%s\n' '# Test Project agents' 'seeded agent prose' 'committed-customization' \
    >"$DT_TARGET/AGENTS.md"
git -C "$DT_TARGET" add -- AGENTS.md
git_commit_all "$DT_TARGET" "repo customizes its agent prose"
cp "$DT_TEMPLATE/template/AGENTS.md" "$DT_TARGET/AGENTS.md"
git -C "$DT_TARGET" add -- AGENTS.md
printf '%s\n' '# Test Project agents' 'seeded agent prose' 'committed-customization' \
    >"$DT_TARGET/AGENTS.md"
if staged_clobber_out="$(HARMON_INIT="$DT_TEMPLATE" bash "$STANDARDIZE_ASSETS/diff-template.sh" "$DT_TARGET" 2>&1)"; then
    bad "diff-template gates a staged clobber of co-owned prose (expected non-zero exit)"
elif printf '%s\n' "$staged_clobber_out" |
    grep -qF "DRIFT    AGENTS.md  (staged copy is byte-identical to the template"; then
    ok "diff-template gates a staged clobber of co-owned prose"
else
    bad "diff-template gates a staged clobber of co-owned prose (diagnostic missing)"
fi
if printf '%s\n' "$staged_clobber_out" | grep -qF "CO-OWNED AGENTS.md"; then
    bad "diff-template replaces the co-owned line when the clobber is staged"
else
    ok "diff-template replaces the co-owned line when the clobber is staged"
fi
git -C "$DT_TARGET" reset -q HEAD -- AGENTS.md
git -C "$DT_TARGET" checkout HEAD -- AGENTS.md

# The control that keeps that gate honest: with NOTHING staged, an index equal
# to the render just means the repo's committed copy is the template's while
# somebody edits locally. No customization is at risk, so this stays the
# informational CO-OWNED line rather than a clobber warning.
git -C "$DT_TARGET" checkout -q HEAD~1 -- AGENTS.md
git -C "$DT_TARGET" add -- AGENTS.md
git_commit_all "$DT_TARGET" "repo returns to the template's agent prose"
printf '%s\n' '# Test Project agents' 'seeded agent prose' 'unstaged-local-edit' \
    >"$DT_TARGET/AGENTS.md"
if unstaged_edit_out="$(HARMON_INIT="$DT_TEMPLATE" bash "$STANDARDIZE_ASSETS/diff-template.sh" "$DT_TARGET" 2>&1)"; then
    ok "diff-template reports no clobber when nothing is staged"
else
    bad "diff-template reports no clobber when nothing is staged: $unstaged_edit_out"
fi
if printf '%s\n' "$unstaged_edit_out" | grep -qF "staged copy is byte-identical"; then
    bad "diff-template calls an unstaged local edit no clobber"
else
    ok "diff-template calls an unstaged local edit no clobber"
fi
git -C "$DT_TARGET" checkout HEAD -- AGENTS.md
expect_ok "diff-template returns to a clean baseline after the staged-state cases" \
    env HARMON_INIT="$DT_TEMPLATE" bash "$STANDARDIZE_ASSETS/diff-template.sh" "$DT_TARGET"

# --- an INHERITED index entry is committed state, not staged state -----------
# "The index differs from the template" and "this is staged" are different
# claims. A committed customization whose worktree copy is edited BACK to the
# template stages nothing, yet its index entry still differs from the render —
# and an ordinary `git commit` writes no such entry. Reporting it as "the next
# commit carries it" turns an unstaged reconciliation into a gating lie.
DT_INHERITED_INDEX="$TMPROOT/diff-template-inherited-index"
cp -pR "$DT_TARGET" "$DT_INHERITED_INDEX"
printf '%s\n' '{ "extends": ["committed-divergence"] }' \
    >"$DT_INHERITED_INDEX/renovate.json"
git_commit_all "$DT_INHERITED_INDEX" "repo commits a renovate divergence"
cp "$DT_TEMPLATE/template/renovate.json" "$DT_INHERITED_INDEX/renovate.json"
if inherited_out="$(HARMON_INIT="$DT_TEMPLATE" bash "$STANDARDIZE_ASSETS/diff-template.sh" \
    "$DT_INHERITED_INDEX" 2>&1)"; then
    ok "diff-template does not gate an unstaged reconciliation to the template"
else
    bad "diff-template does not gate an unstaged reconciliation to the template: $inherited_out"
fi
if printf '%s\n' "$inherited_out" | grep -qF "staged content differs"; then
    bad "diff-template claims no staged content for an index entry inherited from HEAD"
else
    ok "diff-template claims no staged content for an index entry inherited from HEAD"
fi
# Same distinction on the mode dimension: an unstaged `chmod` leaves the index
# mode exactly as HEAD recorded it, so there is no staged mode to report.
DT_INHERITED_MODE="$TMPROOT/diff-template-inherited-mode"
cp -pR "$DT_TARGET" "$DT_INHERITED_MODE"
chmod -x "$DT_INHERITED_MODE/scripts/status.sh"
git_commit_all "$DT_INHERITED_MODE" "repo commits a mode divergence"
chmod +x "$DT_INHERITED_MODE/scripts/status.sh"
if inherited_mode_out="$(HARMON_INIT="$DT_TEMPLATE" bash "$STANDARDIZE_ASSETS/diff-template.sh" \
    "$DT_INHERITED_MODE" 2>&1)"; then
    ok "diff-template does not gate an unstaged mode reconciliation"
else
    bad "diff-template does not gate an unstaged mode reconciliation: $inherited_mode_out"
fi
if printf '%s\n' "$inherited_mode_out" | grep -qF "staged mode differs"; then
    bad "diff-template claims no staged mode for an index mode inherited from HEAD"
else
    ok "diff-template claims no staged mode for an index mode inherited from HEAD"
fi

# --- a staged chmod is not a staged prose clobber ----------------------------
# Mode and content stage independently: `git update-index --chmod` records a
# mode with the bytes untouched. For a co-owned file whose COMMITTED bytes
# already match the template, staging only a mode correction satisfies every
# other clobber condition — index bytes equal to the render, something staged —
# while no prose was ever staged and the customization is not at risk.
DT_MODE_ONLY_STAGE="$TMPROOT/diff-template-mode-only-stage"
cp -pR "$DT_TARGET" "$DT_MODE_ONLY_STAGE"
chmod +x "$DT_MODE_ONLY_STAGE/AGENTS.md"
git_commit_all "$DT_MODE_ONLY_STAGE" "repo commits agent prose with the exec bit"
git -C "$DT_MODE_ONLY_STAGE" update-index --chmod=-x -- AGENTS.md
printf '%s\n' '# Test Project agents' 'seeded agent prose' 'unstaged-prose-edit' \
    >"$DT_MODE_ONLY_STAGE/AGENTS.md"
chmod +x "$DT_MODE_ONLY_STAGE/AGENTS.md"
if mode_only_out="$(HARMON_INIT="$DT_TEMPLATE" bash "$STANDARDIZE_ASSETS/diff-template.sh" \
    "$DT_MODE_ONLY_STAGE" 2>&1)"; then
    bad "diff-template gates the real mode divergence beside a staged chmod (expected non-zero exit)"
elif printf '%s\n' "$mode_only_out" | grep -qF "MODE     AGENTS.md"; then
    ok "diff-template gates the real mode divergence beside a staged chmod"
else
    bad "diff-template gates the real mode divergence beside a staged chmod (MODE diagnostic missing)"
fi
if printf '%s\n' "$mode_only_out" | grep -qF "staged copy is byte-identical"; then
    bad "diff-template claims no prose clobber when only a mode was staged"
else
    ok "diff-template claims no prose clobber when only a mode was staged"
fi
if printf '%s\n' "$mode_only_out" | grep -qF "CO-OWNED AGENTS.md"; then
    ok "diff-template keeps the co-owned class when only a mode was staged"
else
    bad "diff-template keeps the co-owned class when only a mode was staged"
fi

# --- a staged TYPE change hides in the mode, not in the bytes ----------------
# git records a regular file as 100644 and a symlink as 120000, and a file whose
# contents are exactly the link's target text has the SAME blob under both. So
# an index-only file→symlink conversion moves the mode while the blob stands
# still: keying the structural verdict on staged bytes misses it, and the
# exec-bit branch cannot catch it either because it exempts symlinks by design.
DT_STAGED_TYPE="$TMPROOT/diff-template-staged-type"
cp -pR "$DT_TARGET" "$DT_STAGED_TYPE"
# AGENTS.md's committed bytes become the link text, so the blob is shared by the
# regular file and the symlink that points at it — the whole point of the case.
printf 'docs/guide.md' >"$DT_STAGED_TYPE/AGENTS.md"
git_commit_all "$DT_STAGED_TYPE" "agent prose is exactly a path string"
staged_type_blob="$(printf 'docs/guide.md' |
    git -C "$DT_STAGED_TYPE" hash-object -w --stdin)"
git -C "$DT_STAGED_TYPE" update-index --add --cacheinfo \
    "120000,$staged_type_blob,AGENTS.md"
if staged_type_out="$(HARMON_INIT="$DT_TEMPLATE" bash "$STANDARDIZE_ASSETS/diff-template.sh" \
    "$DT_STAGED_TYPE" 2>&1)"; then
    bad "diff-template gates an index-only file-to-symlink conversion (expected non-zero exit)"
elif printf '%s\n' "$staged_type_out" |
    grep -qF "DRIFT    AGENTS.md  (staged symlink mismatch"; then
    ok "diff-template gates an index-only file-to-symlink conversion"
else
    bad "diff-template gates an index-only file-to-symlink conversion (diagnostic missing)"
fi

# The SAME conversion the other way round, which is the case a byte comparison
# can never see: HEAD is a symlink, the index stages its unchanged blob as a
# REGULAR FILE, and the worktree holds the template's bytes. Nothing about the
# blob moved, and index and render are both regular files so there is no type
# mismatch to call structural — yet committing produces a file whose CONTENT is
# the old link target rather than the template's.
#
# renovate.json rather than AGENTS.md deliberately: this is a CONTENT verdict,
# and a co-owned path's staged content stays exempt by the documented contract,
# which would mask the mechanism under test rather than exercise it.
DT_STAGED_UNLINK="$TMPROOT/diff-template-staged-unlink"
cp -pR "$DT_TARGET" "$DT_STAGED_UNLINK"
rm "$DT_STAGED_UNLINK/renovate.json"
ln -s docs/guide.md "$DT_STAGED_UNLINK/renovate.json"
git_commit_all "$DT_STAGED_UNLINK" "renovate config is committed as a symlink"
staged_unlink_blob="$(git -C "$DT_STAGED_UNLINK" rev-parse HEAD:renovate.json)"
git -C "$DT_STAGED_UNLINK" update-index --add --cacheinfo \
    "100644,$staged_unlink_blob,renovate.json"
rm "$DT_STAGED_UNLINK/renovate.json"
cp "$DT_TEMPLATE/template/renovate.json" "$DT_STAGED_UNLINK/renovate.json"
if staged_unlink_out="$(HARMON_INIT="$DT_TEMPLATE" bash "$STANDARDIZE_ASSETS/diff-template.sh" \
    "$DT_STAGED_UNLINK" 2>&1)"; then
    bad "diff-template gates a staged symlink-to-file conversion (expected non-zero exit)"
elif printf '%s\n' "$staged_unlink_out" |
    grep -qF "DRIFT    renovate.json  (uncurated — staged content differs"; then
    ok "diff-template gates a staged symlink-to-file conversion"
else
    bad "diff-template gates a staged symlink-to-file conversion (DRIFT diagnostic missing)"
fi

# --- an unborn repository stages everything ----------------------------------
# Before the first commit there is no committed state, so every index entry is
# staged by definition and the initial commit carries all of it. Ending the
# inspection at the absent HEAD made this the one place staged divergence went
# unreported entirely.
DT_UNBORN="$TMPROOT/diff-template-unborn"
cp -pR "$DT_TARGET" "$DT_UNBORN"
rm -rf "$DT_UNBORN/.git"
git_init "$DT_UNBORN"
printf '%s\n' '{ "extends": ["unborn-staged-divergence"] }' \
    >"$DT_UNBORN/renovate.json"
git -C "$DT_UNBORN" add -- renovate.json
cp "$DT_TEMPLATE/template/renovate.json" "$DT_UNBORN/renovate.json"
if unborn_out="$(HARMON_INIT="$DT_TEMPLATE" bash "$STANDARDIZE_ASSETS/diff-template.sh" \
    "$DT_UNBORN" 2>&1)"; then
    bad "diff-template reports staged divergence before the first commit (expected non-zero exit)"
elif printf '%s\n' "$unborn_out" |
    grep -qF "DRIFT    renovate.json  (uncurated — staged content differs"; then
    ok "diff-template reports staged divergence before the first commit"
else
    bad "diff-template reports staged divergence before the first commit (DRIFT diagnostic missing)"
fi
# …and the clobber gate stays silent there: with nothing committed, no
# customization can be lost, so a co-owned worktree edit is an ordinary local
# edit rather than a clobber.
git -C "$DT_UNBORN" reset -q -- renovate.json
cp "$DT_TEMPLATE/template/renovate.json" "$DT_UNBORN/renovate.json"
git -C "$DT_UNBORN" add -- AGENTS.md
printf '%s\n' '# Test Project agents' 'seeded agent prose' 'unborn-local-edit' \
    >"$DT_UNBORN/AGENTS.md"
if unborn_clobber_out="$(HARMON_INIT="$DT_TEMPLATE" bash "$STANDARDIZE_ASSETS/diff-template.sh" \
    "$DT_UNBORN" 2>&1)"; then
    ok "diff-template claims no clobber in a repo with no commits"
else
    bad "diff-template claims no clobber in a repo with no commits: $unborn_clobber_out"
fi
if printf '%s\n' "$unborn_clobber_out" | grep -qF "staged copy is byte-identical"; then
    bad "diff-template makes no clobber claim without a committed customization"
else
    ok "diff-template makes no clobber claim without a committed customization"
fi

# --- the staged-removal probes must fail CLOSED ------------------------------
# `cat-file -e "HEAD:$p"` exits 128 for a path merely ABSENT from HEAD, so
# "absent" and "the probe itself failed" were indistinguishable by exit code and
# both read as "nothing is staged for removal". A corrupt index makes `ls-files`
# fail while `ls-tree` and `rev-parse` are fine, which isolates the probe: the
# run must stop with the setup-error status instead of auditing on regardless.
DT_BAD_INDEX="$TMPROOT/diff-template-bad-index"
cp -pR "$DT_TARGET" "$DT_BAD_INDEX"
printf 'not an index at all' >"$DT_BAD_INDEX/.git/index"
bad_index_rc=0
bad_index_out="$(HARMON_INIT="$DT_TEMPLATE" bash "$STANDARDIZE_ASSETS/diff-template.sh" \
    "$DT_BAD_INDEX" 2>&1)" || bad_index_rc=$?
if [ "$bad_index_rc" -eq 2 ]; then
    ok "diff-template exits 2 when a staged-removal probe errors"
else
    bad "diff-template exits 2 when a staged-removal probe errors (got $bad_index_rc)"
fi
if printf '%s\n' "$bad_index_out" |
    grep -qF "FAIL: cannot evaluate the index entry"; then
    ok "diff-template names the staged-removal probe that could not be evaluated"
else
    bad "diff-template names the staged-removal probe that could not be evaluated"
fi

# --- a target that IS a repo but reports somebody else's work tree -----------
# `rev-parse --show-toplevel` succeeding with a DIFFERENT toplevel is the nested
# plain-directory shape only when the target has no .git of its own. With one —
# a misconfigured `core.worktree`, a gitfile pointing elsewhere — the target is a
# repository whose work tree git believes is somewhere else, and taking the
# plain-directory path there silently drops the repo half of the withholding
# probe for a repository. Same fail-open direction as unreadable metadata, same
# refusal.
DT_FOREIGN_WT="$TMPROOT/diff-template-foreign-worktree"
DT_FOREIGN_ELSEWHERE="$TMPROOT/diff-template-foreign-elsewhere"
mkdir -p "$DT_FOREIGN_ELSEWHERE"
cp -pR "$DT_TARGET" "$DT_FOREIGN_WT"
printf '%s\n' '{ "editor.tabSize": 4, "token": "foreign-worktree-leak-sentinel" }' \
    >"$DT_FOREIGN_WT/.vscode/settings.json"
git -C "$DT_FOREIGN_WT" config core.worktree "$DT_FOREIGN_ELSEWHERE"
foreign_wt_rc=0
foreign_wt_out="$(HARMON_INIT="$DT_TEMPLATE" bash "$STANDARDIZE_ASSETS/diff-template.sh" \
    --show "$DT_FOREIGN_WT" 2>&1)" || foreign_wt_rc=$?
if [ "$foreign_wt_rc" -eq 2 ]; then
    ok "diff-template exits 2 when the target's own .git reports a foreign work tree"
else
    bad "diff-template exits 2 when the target's own .git reports a foreign work tree (got $foreign_wt_rc)"
fi
if printf '%s\n' "$foreign_wt_out" |
    grep -qF "FAIL: $DT_FOREIGN_WT has its own .git but git reports a different work tree"; then
    ok "diff-template says the target's work tree is not where its .git says"
else
    bad "diff-template says the target's work tree is not where its .git says"
fi
if printf '%s\n' "$foreign_wt_out" | grep -qF 'foreign-worktree-leak-sentinel'; then
    bad "diff-template prints no diff body for a foreign-work-tree target"
else
    ok "diff-template prints no diff body for a foreign-work-tree target"
fi

# --- a template-shipped SYMLINK .gitignore marks paths without enforcing -----
# _preserve_symlinks lets a template ship its ignore rules as a symlink, and the
# two axes answer that shape DIFFERENTLY:
#   • git refuses to follow a symlinked .gitignore (`unable to access`), so a
#     freshly generated repo enforces nothing from it. CLASSIFICATION must agree
#     — granting the informational IGNORED class there would downgrade drift on
#     rules no clone ever applies.
#   • WITHHOLDING must not agree: the template still WROTE those paths into its
#     ignore rules, so printing their bodies leaks exactly what somebody marked
#     local-only. The `-type f` walk fed both answers from regular files alone,
#     so this template's declared-local bodies were printed outright.
# Two files carry the two halves: .envrc, which the repo does NOT ignore, is the
# leak control; secrets.env, which the repo DOES ignore, is the git-parity one.
DT_LINKIGNORE_TEMPLATE="$TMPROOT/diff-template-linkignore-source"
mkdir -p "$DT_LINKIGNORE_TEMPLATE/template"
cat >"$DT_LINKIGNORE_TEMPLATE/copier.yml" <<'EOF'
_min_copier_version: "9.4.0"
_subdirectory: template
_preserve_symlinks: true
# diff-template derives its OWNED class from _skip_if_exists and refuses to run
# without one; this fixture needs no repo-owned path of its own, only a
# declaration for the derivation to read.
_skip_if_exists:
  - CHANGELOG.md
project_name:
  type: str
  default: Link Ignore
EOF
printf '%s\n' '.envrc' 'secrets.env' \
    >"$DT_LINKIGNORE_TEMPLATE/template/gitignore-rules"
ln -s gitignore-rules "$DT_LINKIGNORE_TEMPLATE/template/.gitignore"
printf '%s\n' 'export EXAMPLE_SETTING=template-default' \
    >"$DT_LINKIGNORE_TEMPLATE/template/.envrc"
printf '%s\n' 'EXAMPLE_TOKEN=template-default' \
    >"$DT_LINKIGNORE_TEMPLATE/template/secrets.env"
git_init "$DT_LINKIGNORE_TEMPLATE"
git -C "$DT_LINKIGNORE_TEMPLATE" add -f -- template/.envrc template/secrets.env
git_commit_all "$DT_LINKIGNORE_TEMPLATE" "template ships a symlink .gitignore"
git -C "$DT_LINKIGNORE_TEMPLATE" tag v1.0.0
DT_LINKIGNORE_TARGET="$TMPROOT/diff-template-linkignore-target"
mkdir -p "$DT_LINKIGNORE_TARGET"
printf '%s\n' '.envrc' 'secrets.env' >"$DT_LINKIGNORE_TARGET/gitignore-rules"
ln -s gitignore-rules "$DT_LINKIGNORE_TARGET/.gitignore"
printf '%s\n' 'export EXAMPLE_SETTING=linkignore-envrc-sentinel' \
    >"$DT_LINKIGNORE_TARGET/.envrc"
printf '%s\n' 'EXAMPLE_TOKEN=linkignore-secrets-sentinel' \
    >"$DT_LINKIGNORE_TARGET/secrets.env"
cat >"$DT_LINKIGNORE_TARGET/.copier-answers.yml" <<EOF
_commit: v1.0.0
_src_path: file://$DT_LINKIGNORE_TEMPLATE
project_name: Link Ignore
EOF
git_init "$DT_LINKIGNORE_TARGET"
# Only secrets.env is ignored repo-side, and through info/exclude because git
# would not read the symlinked .gitignore anyway. .envrc is left plainly visible
# to the repo, which is what makes it the leak control: nothing but the
# template's own (symlinked) declaration can withhold its body.
mkdir -p "$DT_LINKIGNORE_TARGET/.git/info"
printf '%s\n' 'secrets.env' >"$DT_LINKIGNORE_TARGET/.git/info/exclude"
git_commit_all "$DT_LINKIGNORE_TARGET" "target mirrors the symlink .gitignore"
if linkignore_out="$(HARMON_INIT="$DT_LINKIGNORE_TEMPLATE" \
    bash "$STANDARDIZE_ASSETS/diff-template.sh" --show "$DT_LINKIGNORE_TARGET" 2>&1)"; then
    bad "diff-template gates paths a symlink .gitignore cannot enforce (expected non-zero exit)"
elif printf '%s\n' "$linkignore_out" | grep -qF "DRIFT    .envrc"; then
    ok "diff-template gates paths a symlink .gitignore cannot enforce"
else
    bad "diff-template gates paths a symlink .gitignore cannot enforce (DRIFT diagnostic missing)"
fi
# The leak control: the repo has no rule of its own for .envrc, so the body is
# withheld only because the template marked the path local — through a link git
# itself will not follow.
if printf '%s\n' "$linkignore_out" | grep -qF 'linkignore-envrc-sentinel'; then
    bad "diff-template withholds a body a symlink .gitignore marks local"
else
    ok "diff-template withholds a body a symlink .gitignore marks local"
fi
# The git-parity control: a real clone enforces nothing from that link, so the
# repo's own ignore rule cannot be upgraded into the template's declaration.
if printf '%s\n' "$linkignore_out" |
    grep -qF "DRIFT    secrets.env  (repo-ignored, but the template tracks this file"; then
    ok "a symlink .gitignore grants no IGNORED class git would not grant"
else
    bad "a symlink .gitignore grants no IGNORED class git would not grant"
fi
if printf '%s\n' "$linkignore_out" | grep -qF "IGNORED  "; then
    bad "diff-template emits no IGNORED line for unenforceable template rules"
else
    ok "diff-template emits no IGNORED line for unenforceable template rules"
fi
if printf '%s\n' "$linkignore_out" | grep -qF 'linkignore-secrets-sentinel'; then
    bad "diff-template withholds a repo-ignored body under a symlink .gitignore"
else
    ok "diff-template withholds a repo-ignored body under a symlink .gitignore"
fi

# --- a curated path the template renders as a DANGLING symlink ---------------
# `-f` follows links, so such a path read as "not in this profile" and the
# curated loop skipped it — while the sweep skipped it too, deferring to the
# manifest that owns it. The run exited 0 having said nothing at all about a
# template-owned path.
DT_DANGLE_TEMPLATE="$TMPROOT/diff-template-dangling-source"
mkdir -p "$DT_DANGLE_TEMPLATE/template/scripts"
cat >"$DT_DANGLE_TEMPLATE/copier.yml" <<'EOF'
_min_copier_version: "9.4.0"
_subdirectory: template
_preserve_symlinks: true
# diff-template derives its OWNED class from _skip_if_exists and refuses to run
# without one; this fixture needs no repo-owned path of its own, only a
# declaration for the derivation to read.
_skip_if_exists:
  - CHANGELOG.md
project_name:
  type: str
  default: Dangling
EOF
ln -s status-impl.sh "$DT_DANGLE_TEMPLATE/template/scripts/status.sh"
printf '%s\n' 'kept' >"$DT_DANGLE_TEMPLATE/template/keep.txt"
git_init "$DT_DANGLE_TEMPLATE"
git_commit_all "$DT_DANGLE_TEMPLATE" "template renders a dangling alias"
git -C "$DT_DANGLE_TEMPLATE" tag v1.0.0
DT_DANGLE_TARGET="$TMPROOT/diff-template-dangling-target"
mkdir -p "$DT_DANGLE_TARGET/scripts"
ln -s status-impl.sh "$DT_DANGLE_TARGET/scripts/status.sh"
printf '%s\n' 'kept' >"$DT_DANGLE_TARGET/keep.txt"
cat >"$DT_DANGLE_TARGET/.copier-answers.yml" <<EOF
_commit: v1.0.0
_src_path: file://$DT_DANGLE_TEMPLATE
project_name: Dangling
EOF
git_init "$DT_DANGLE_TARGET"
git_commit_all "$DT_DANGLE_TARGET" "target mirrors the dangling alias"
if dangle_out="$(HARMON_INIT="$DT_DANGLE_TEMPLATE" bash "$STANDARDIZE_ASSETS/diff-template.sh" \
    "$DT_DANGLE_TARGET" 2>&1)"; then
    bad "diff-template reports a curated path rendered as a dangling symlink (expected non-zero exit)"
elif printf '%s\n' "$dangle_out" |
    grep -qF "DRIFT    scripts/status.sh  (template renders a dangling symlink"; then
    ok "diff-template reports a curated path rendered as a dangling symlink"
else
    bad "diff-template reports a curated path rendered as a dangling symlink (DRIFT diagnostic missing)"
fi

# --- `terraform init` is not a nested Terraform layout -----------------------
# An unrestricted walk counted `.terraform/modules/**/*.tf` — module sources
# copier never rendered and the repo never wrote — as the nested root that makes
# the flat seeds redundant, so running `terraform init` once was enough to award
# a benign EQUIV to a repo that still has no replacement for them.
DT_TF_CACHE="$TMPROOT/diff-template-terraform-cache"
cp -pR "$DT_TARGET" "$DT_TF_CACHE"
rm -rf "$DT_TF_CACHE/terraform"
mkdir -p "$DT_TF_CACHE/terraform/.terraform/modules/vpc"
printf '%s\n' '# vendored module source' \
    >"$DT_TF_CACHE/terraform/.terraform/modules/vpc/main.tf"
if tf_cache_out="$(HARMON_INIT="$DT_TEMPLATE" bash "$STANDARDIZE_ASSETS/diff-template.sh" \
    "$DT_TF_CACHE" 2>&1)"; then
    bad "diff-template counts no .terraform cache as a nested root (expected non-zero exit)"
elif printf '%s\n' "$tf_cache_out" | grep -qF "MISSING  terraform/main.tf"; then
    ok "diff-template counts no .terraform cache as a nested root"
else
    bad "diff-template counts no .terraform cache as a nested root (MISSING diagnostic absent)"
fi
if printf '%s\n' "$tf_cache_out" | grep -qF "EQUIV    terraform/main.tf"; then
    bad "diff-template awards no EQUIV on a terraform init cache alone"
else
    ok "diff-template awards no EQUIV on a terraform init cache alone"
fi

# The equivalence walk honors the same physical-parent guard as every other
# repo-path resolution here: a "nested root" that lives under a symlinked
# directory is somebody else's tree, not evidence this repo outgrew the seeds.
DT_TF_OUTSIDE="$TMPROOT/diff-template-terraform-outside"
mkdir -p "$DT_TF_OUTSIDE/production"
printf '%s\n' '# outside root' >"$DT_TF_OUTSIDE/production/main.tf"
DT_TF_LINKED="$TMPROOT/diff-template-terraform-linked"
cp -pR "$DT_TARGET" "$DT_TF_LINKED"
rm -rf "$DT_TF_LINKED/terraform/environments"
# Two levels deep, so the relative target needs two hops: `../` alone would
# resolve inside the copy and leave a dangling link that models nothing.
ln -s ../../diff-template-terraform-outside "$DT_TF_LINKED/terraform/environments"
if [ -f "$DT_TF_LINKED/terraform/environments/production/main.tf" ]; then
    ok "the symlinked-parent Terraform fixture points at a real outside root"
else
    bad "the symlinked-parent Terraform fixture points at a real outside root"
fi
if tf_linked_out="$(HARMON_INIT="$DT_TEMPLATE" bash "$STANDARDIZE_ASSETS/diff-template.sh" \
    "$DT_TF_LINKED" 2>&1)"; then
    bad "diff-template resolves no Terraform equivalence through a symlinked parent (expected non-zero exit)"
elif printf '%s\n' "$tf_linked_out" | grep -qF "MISSING  terraform/main.tf"; then
    ok "diff-template resolves no Terraform equivalence through a symlinked parent"
else
    bad "diff-template resolves no Terraform equivalence through a symlinked parent (MISSING diagnostic absent)"
fi
if printf '%s\n' "$tf_linked_out" | grep -qF "EQUIV    terraform/main.tf"; then
    bad "diff-template awards no EQUIV for a root outside the repository"
else
    ok "diff-template awards no EQUIV for a root outside the repository"
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
# The guarded path snapshots the canonical remote with `git clone --no-checkout`,
# so there is no copier.yml on disk there at all — carrying a _skip_if_exists
# declaration here is what proves the OWNED derivation reads it out of the
# rendered COMMIT rather than off a working copy.
cat >"$GA_TEMPLATE/copier.yml" <<'EOF'
_min_copier_version: "9.4.0"
_subdirectory: template
_skip_if_exists:
  - CHANGELOG.md
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
_skip_if_exists:
  - .github/CODEOWNERS
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
# A `_skip_if_exists` path, so the fixture's real update exercises the one
# behaviour the classifier used to need dedicated pattern-matching code for.
# Nothing reads the pattern list any more — the scratch apply just watches the
# file come back.
mkdir -p "$GU_TEMPLATE/template/.github"
printf '%s\n' '* @owner' >"$GU_TEMPLATE/template/.github/CODEOWNERS"
# Three non-adoption fixtures, all plain files that no ignore rule covers:
#   shared-note.md — shipped by BOTH renders, byte-identical across the range,
#                    and deleted from the repo below. The merge has no diff to
#                    apply and reads the absence as the user's own deletion:
#                    `nonadopt-both`, the permanent blind spot.
#   retired-doc.md — baseline-only (the target template drops it) while the repo
#                    still carries it: `delete-expected`.
#   new-doc.md     — added by the target template only: `new-in-target`.
printf '%s\n' 'shared across the update range' \
    >"$GU_TEMPLATE/template/shared-note.md"
printf '%s\n' 'retired by the target template' \
    >"$GU_TEMPLATE/template/retired-doc.md"
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
# The repo declines shared-note.md, staged and committed — indistinguishable
# from a removal made three versions ago and forgotten. From here on no
# `copier update` will ever put it back, and none will say so.
rm "$GU_TARGET/shared-note.md" "$GU_TARGET/.github/CODEOWNERS"
git_commit_all "$GU_TARGET" "drop the shared note and CODEOWNERS"

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
rm "$GU_TEMPLATE/template/retired-doc.md"
printf '%s\n' 'added by the target template' \
    >"$GU_TEMPLATE/template/new-doc.md"
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
LC_ALL=C comm -13 \
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
LC_ALL=C comm -12 \
    "$GU_TARGET/.copier-guarded-update/new-question-candidates" \
    "$GU_TARGET/.copier-guarded-update/active-target-questions" \
    >"$GU_TARGET/.copier-guarded-update/active-new-questions"
{
    cat "$GU_TARGET/.copier-guarded-update/active-new-questions"
    printf '%s\n' use_foreman use_coderabbit use_codeql codeql_languages \
        use_codex_review use_skills_sync skill_categories
} |
    LC_ALL=C sort -u |
    LC_ALL=C comm -12 - \
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
LC_ALL=C comm -12 \
    "$GU_TARGET/.copier-guarded-update/new-question-candidates" \
    "$GU_TARGET/.copier-guarded-update/active-target-questions" \
    >"$GU_TARGET/.copier-guarded-update/active-new-questions"
{
    cat "$GU_TARGET/.copier-guarded-update/active-new-questions"
    printf '%s\n' use_foreman use_coderabbit use_codeql codeql_languages \
        use_codex_review use_skills_sync skill_categories
} |
    LC_ALL=C sort -u |
    LC_ALL=C comm -12 - \
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

# Run the §1 non-adoption classifier extracted from mode-update.md against this
# fixture's frozen inventories and its two real discovery renders. The doc IS
# the implementation — an operator pastes it into a shell — so extracting and
# executing it is the only way to prove the recipe works rather than merely
# reads well. Everything it needs already exists here: both managed-path
# inventories, ignored-absent-paths, and both renders.
# The snippet now REHEARSES the update against a scratch copy instead of
# modelling it, so it needs copier and the guarded wrapper. The wrapper is
# extracted from the same document rather than restated here — a rehearsal of a
# differently-configured copier would prove nothing about §2's invocation.
GU_NONADOPT_RUNNER="$TMPROOT/nonadoption-runner.sh"
{
    printf '%s\n' 'set -eu'
    sed -n '/^run_guarded_copier() {/,/^}/p' "$STANDARDIZE_REFS/mode-update.md"
    cat "$GU_NONADOPT_SNIPPET"
} >"$GU_NONADOPT_RUNNER"
expect_ok "the guarded copier wrapper is extractable alongside the snippet" \
    sh -c 'grep -qF "run_guarded_copier() {" "$1" &&
        grep -qF "COPIER_CACHE_DIR=" "$1"' sh "$GU_NONADOPT_RUNNER"
expect_ok "the non-adoption scratch canonicalizes macOS temp-path aliases" \
    sh -c 'grep -qF '\''mktemp -d "${TMPDIR:-/tmp}/copier-nonadoption-apply-XXXXXX"'\'' "$1" &&
        grep -qF '\''NONADOPT_SCRATCH="$(cd "$NONADOPT_SCRATCH" && pwd -P)"'\'' "$1"' sh \
    "$GU_NONADOPT_RUNNER"
GU_RECONCILE="$TMPROOT/nonadoption-reconcile.sh"
{
    printf '%s\n' 'set -eu' 'GUARDED_STATE=.copier-guarded-update'
    sed -n '/^nonadoption_reconcile() {/,/^}$/p' "$STANDARDIZE_REFS/mode-update.md"
    printf '%s\n' 'nonadoption_reconcile'
} >"$GU_RECONCILE"
expect_ok "the reconciliation recipe is extractable from the guidance" \
    sh -c 'grep -qF "RECONCILE_BAD" "$1" && grep -qF "nonadoption_reconcile" "$1"' sh \
    "$GU_RECONCILE"
printf '{}\n' >"$GU_TARGET/.copier-guarded-update/nonadoption-reviewed.yml"
gu_nonadopt_classify() {
    (cd "$GU_TARGET" &&
        GUARDED_STATE=.copier-guarded-update \
            BASELINE_DISCOVERY="$GU_BASELINE_DISCOVERY" \
            TARGET_DISCOVERY="$GU_DISCOVERY_SECOND" \
            GUARDED_TEMPLATE="$GU_SNAPSHOT" \
            HARMON_INIT_SOURCE="$GU_CANONICAL_SOURCE" \
            GUARDED_COPIER_CACHE="$GU_CACHE" \
            HARMON_INIT_COMMIT="$GU_TARGET_COMMIT" \
            REVIEWED_DATA=".copier-guarded-update/reviewed-data.yml" \
            bash -eu "$GU_NONADOPT_RUNNER" >/dev/null)
}
# The rehearsal's `mktemp -d -t` honours TMPDIR, so it is pointed at a directory
# only this fixture uses. Counting `copier-nonadoption-apply-*` in the SHARED
# tmpdir was a race: another guarded run on the same machine owns directories
# matching that glob, and this suite has no business counting — or later
# deleting — them.
GU_SCRATCH_TMP="$TMPROOT/gu-rehearsal-tmp"
mkdir -p "$GU_SCRATCH_TMP"
gu_nonadopt_classify_private_tmp() {
    (
        TMPDIR="$GU_SCRATCH_TMP"
        export TMPDIR
        gu_nonadopt_classify
    )
}
expect_ok "non-adoption classifier rehearses the apply and runs clean under bash -eu" \
    gu_nonadopt_classify_private_tmp
# The rehearsal must not disturb the tree it rehearses on: it copies, applies to
# the copy, and removes the copy. A guarded run whose observation step mutated
# the worktree would be the worst possible bug in this design.
expect_ok "the scratch rehearsal leaves the real worktree untouched" \
    sh -c 'test -z "$(git -C "$1" status --porcelain)"' sh "$GU_TARGET"
# Emptiness of a directory nobody else writes to, rather than a count of a shared
# one: an exact assertion instead of a racy inequality.
expect_ok "the scratch rehearsal removes its own copy" \
    sh -c 'test -z "$(ls -A "$1")"' sh "$GU_SCRATCH_TMP"
GU_NONADOPT_TSV="$GU_TARGET/.copier-guarded-update/nonadoption-report.tsv"
# Every row below is an OBSERVATION of a real copier apply against a copy of this
# fixture, not a prediction about one. The assertions further down re-check each
# against what the fixture's own real update actually does.
expect_ok "the rehearsal observes a both-renders absence copier declines to adopt" \
    grep -qxF "$(printf 'shared-note.md\tnonadopt-both\tno\tbaseline+target\t-')" \
    "$GU_NONADOPT_TSV"
expect_ok "the rehearsal observes the template-side deletion" \
    grep -qxF "$(printf 'retired-doc.md\tdeleted\tn/a-removed\tbaseline-only\t-')" \
    "$GU_NONADOPT_TSV"
expect_ok "the rehearsal observes a target-only file being created" \
    grep -qxF "$(printf 'new-doc.md\tcreated\tn/a-new\ttarget-only\tnew-in-target')" \
    "$GU_NONADOPT_TSV"
# The case that used to need `_skip_if_exists` parsing, gitwildmatch basename
# rules and a dedicated class. It is now just a file that came back, seen.
expect_ok "the rehearsal observes a _skip_if_exists path being recreated" \
    grep -qxF "$(printf '.github/CODEOWNERS\tcreated\tno\tbaseline+target\trecreated')" \
    "$GU_NONADOPT_TSV"
# ...and no code in the snippet knows what `_skip_if_exists` is any more.
expect_ok "the snippet reads no _skip_if_exists patterns at all" \
    sh -c '! grep -qF "_skip_if_exists // []" "$1" &&
        ! grep -qF "nonadoption_is_recreated_on_update" "$1" &&
        ! grep -qF "skip-if-exists-patterns" "$1"' sh \
    "$GU_NONADOPT_SNIPPET"
# .vscode/new.json is repo-ignored but the target template NEGATES it, so the
# template is saying as loudly as a .gitignore can that the file is meant to be
# tracked. The class comes from watching the apply; the note still records whose
# rule it was.
expect_ok "a repo-only ignore is recorded as evidence, not as adoption policy" \
    grep -qxF "$(printf '.vscode/new.json\tcreated\tn/a-new\ttarget-only\tnew-in-target; repo-ignored-only')" \
    "$GU_NONADOPT_TSV"
# Adopted paths carry no row — otherwise every render file would be a finding
# and the report would be as useless as no report.
expect_fail "the rehearsal stays silent about paths the repo already has" \
    grep -qF version.txt "$GU_NONADOPT_TSV"
chmod -R a-w "$GU_SNAPSHOT"

# --- note machinery, on a real copier fixture --------------------------------
# The classes come from watching a real apply now, so this fixture no longer
# tests classification at all — it tests the NOTE machinery, which is the part
# still made of judgement rather than observation. Both renders are the same
# commit, so every declined path is a plain `nonadopt-both` and the only thing
# that varies between rows is the evidence attached to them.
#
# It is a real copier template for the same reason everything else here is now:
# the snippet rehearses an apply, and there is nothing to rehearse against a
# hand-built directory.
GU_NA_ROOT="$TMPROOT/nonadoption-notes"
GU_NA_TPL="$GU_NA_ROOT/template"
GU_NA_REPO="$GU_NA_ROOT/repo"
GU_NA_BASE="$GU_NA_ROOT/baseline-render"
GU_NA_TGT="$GU_NA_ROOT/target-render"
GU_NA_STATE="$GU_NA_REPO/.copier-guarded-update"
GU_NA_CACHE="$GU_NA_ROOT/cache"
mkdir -p "$GU_NA_TPL/template" "$GU_NA_CACHE"
cat >"$GU_NA_TPL/copier.yml" <<'EOF'
_min_copier_version: "9.4.0"
_subdirectory: template
project_name:
  type: str
  default: Notes
EOF
printf '%s\n' '{{ _copier_answers|to_nice_yaml -}}' \
    >"$GU_NA_TPL/template/.copier-answers.yml.jinja"
na_tpl_file() {
    mkdir -p "$(dirname "$GU_NA_TPL/template/$1")"
    printf '%s\n' "${2:-rendered body}" >"$GU_NA_TPL/template/$1"
}
# Root co-owned prose (no note) versus documentation-tree prose (co-owned-prose).
na_tpl_file AGENTS.md
na_tpl_file docs/guide.md
# Non-prose under docs/ is not prose at all — the Markdown-only filter.
na_tpl_file docs/build.sh
# Drift class K seeds, each needing its documented equivalent verified.
na_tpl_file docs/decisions/0001-record-architecture-decisions.md
na_tpl_file terraform/main.tf
na_tpl_file prettier.config.cjs
na_tpl_file Brewfile
# Ignore policy: local.json is ignored by BOTH sides, stray.md by the repo only.
na_tpl_file .vscode/local.json
na_tpl_file stray.md
printf '%s\n' '.vscode/*' >"$GU_NA_TPL/template/.gitignore"
# A dir stub, and a `.yml` whose `.yaml` twin the repo keeps instead.
na_tpl_file dir-stub/.gitkeep
na_tpl_file config.yml
na_tpl_file version.txt
git_init "$GU_NA_TPL"
# The .gitignore the template SHIPS also applies to the template repo, so
# `.vscode/local.json` would never be committed and never render. Force-add it:
# the point of this path is to be render-ignored AND present in the render.
git -C "$GU_NA_TPL" add -f template/.vscode/local.json
git_commit_all "$GU_NA_TPL" "notes template"
GU_NA_TPL_COMMIT="$(git -C "$GU_NA_TPL" rev-parse HEAD)"
copier copy --trust --defaults --skip-tasks --vcs-ref="$GU_NA_TPL_COMMIT" \
    "$GU_NA_TPL" "$GU_NA_REPO" >/dev/null
git_init "$GU_NA_REPO"
printf '%s\n' '.vscode/*' 'stray.md' >"$GU_NA_REPO/.gitignore"
printf '%s\n' 'the other spelling' >"$GU_NA_REPO/config.yaml"
git_commit_all "$GU_NA_REPO" "generated"
printf '%s\n' '/.copier-guarded-update/' >>"$GU_NA_REPO/.git/info/exclude"
# Decline every interesting path. `.vscode/local.json` and `stray.md` are
# gitignored, so they were never committed; removing them is still a decline.
rm "$GU_NA_REPO/AGENTS.md" "$GU_NA_REPO/docs/guide.md" \
    "$GU_NA_REPO/docs/build.sh" \
    "$GU_NA_REPO/docs/decisions/0001-record-architecture-decisions.md" \
    "$GU_NA_REPO/terraform/main.tf" "$GU_NA_REPO/prettier.config.cjs" \
    "$GU_NA_REPO/Brewfile" "$GU_NA_REPO/.vscode/local.json" \
    "$GU_NA_REPO/stray.md" "$GU_NA_REPO/dir-stub/.gitkeep" \
    "$GU_NA_REPO/config.yml"
git_commit_all "$GU_NA_REPO" "decline them all"
mkdir -p "$GU_NA_STATE"
printf '{}\n' >"$GU_NA_STATE/reviewed-data.yml"
# Both discovery renders are the same commit: nothing moved upstream, so every
# row reads `changed_in_range=no` and the notes are the only variable.
copier copy --trust --defaults --skip-tasks --vcs-ref="$GU_NA_TPL_COMMIT" \
    "$GU_NA_TPL" "$GU_NA_BASE" >/dev/null
copier copy --trust --defaults --skip-tasks --vcs-ref="$GU_NA_TPL_COMMIT" \
    "$GU_NA_TPL" "$GU_NA_TGT" >/dev/null
for na_side in BASE TGT; do
    eval "na_dir=\$GU_NA_$na_side"
    (cd "$na_dir" && find . \( -type f -o -type l \) -print) |
        sed 's#^\./##' | LC_ALL=C sort -u \
        >"$GU_NA_STATE/$(test "$na_side" = BASE &&
            printf baseline || printf target)-managed-paths"
done
: >"$GU_NA_STATE/ignored-absent-paths"
: >"$GU_NA_STATE/ignored-existing-paths"
while IFS= read -r na_path; do
    git -C "$GU_NA_REPO" check-ignore -q -- "$na_path" || continue
    test -e "$GU_NA_REPO/$na_path" ||
        printf '%s\n' "$na_path" >>"$GU_NA_STATE/ignored-absent-paths"
done <"$GU_NA_STATE/target-managed-paths"
na_classify() {
    (cd "$GU_NA_REPO" &&
        GUARDED_STATE=.copier-guarded-update \
            BASELINE_DISCOVERY="$GU_NA_BASE" \
            TARGET_DISCOVERY="$GU_NA_TGT" \
            GUARDED_TEMPLATE="$GU_NA_TPL" \
            HARMON_INIT_SOURCE="https://example.invalid/notes" \
            GUARDED_COPIER_CACHE="$GU_NA_CACHE" \
            HARMON_INIT_COMMIT="$GU_NA_TPL_COMMIT" \
            REVIEWED_DATA=".copier-guarded-update/reviewed-data.yml" \
            bash -eu "$GU_NONADOPT_RUNNER" >/dev/null)
}
GU_NA_TSV="$GU_NA_STATE/nonadoption-report.tsv"
expect_ok "note fixture rehearses its apply and runs clean under bash -eu" na_classify
# The invariant, over the whole report: only observed classes may appear.
expect_ok "every row carries an observed class" \
    sh -c 'bad="$(awk -F "\t" '"'"'$2 != "nonadopt-both" && $2 != "created" &&
            $2 != "deleted" { print $2 }'"'"' "$1" | LC_ALL=C sort -u | paste -sd, -)"
        test -z "$bad" || { echo "unexpected classes: $bad" >&2; exit 1; }' sh \
    "$GU_NA_TSV"
# Co-ownership is a content exemption and absence is not content: a missing
# AGENTS.md is a row with no explanation at all, which is the loudest row there
# is.
expect_ok "absent root co-owned prose is a row with no note" \
    grep -qxF "$(printf 'AGENTS.md\tnonadopt-both\tno\tbaseline+target\t-')" \
    "$GU_NA_TSV"
expect_ok "documentation-tree prose is a row carrying its note" \
    grep -qxF "$(printf 'docs/guide.md\tnonadopt-both\tno\tbaseline+target\tco-owned-prose')" \
    "$GU_NA_TSV"
expect_ok "non-prose under docs/ is neither noted nor exempt" \
    grep -qxF "$(printf 'docs/build.sh\tnonadopt-both\tno\tbaseline+target\t-')" \
    "$GU_NA_TSV"
expect_ok "a dir stub is noted, not dropped" \
    grep -qxF "$(printf 'dir-stub/.gitkeep\tnonadopt-both\tno\tbaseline+target\tgitkeep')" \
    "$GU_NA_TSV"
# The twin is evidence now, full stop. Round 5 had to decide per class whether it
# counted as presence; the rehearsal answers that by watching.
expect_ok "a .yaml twin is recorded as evidence on the .yml row" \
    grep -qxF "$(printf 'config.yml\tnonadopt-both\tno\tbaseline+target\ttwin-exists: config.yaml')" \
    "$GU_NA_TSV"
# Ignore policy: the TEMPLATE's declaration grants the note, not the repo's. And
# look at the CLASS — this path comes back. A file the render's own .gitignore
# covers is invisible to copier's "the subproject deleted this" scan, so deleting
# it does not opt out of it: the apply renders it again. Every predictive
# revision of this classifier called this path `nonadopt-both` and told the
# operator it would stay gone. The rehearsal simply watched it reappear. It is
# also the cleanest illustration of why class and note are separate axes: the
# note says why the repo lacks the file, the class says copier is about to put it
# back, and both are true at once.
expect_ok "an ignore-policy path the apply recreates is classed created, not absent" \
    grep -qxF "$(printf '.vscode/local.json\tcreated\tno\tbaseline+target\trecreated; ignored-policy')" \
    "$GU_NA_TSV"
expect_ok "a path only the repo ignores is noted with whose rule it was" \
    grep -qxF "$(printf 'stray.md\tnonadopt-both\tno\tbaseline+target\trepo-ignored-only')" \
    "$GU_NA_TSV"
# Drift class K: unverified first — no ADR log, no nested Terraform, no prettier
# config and no chezmoi marker, so every seed is a real absence.
expect_ok "notes accumulate when several explanations apply" \
    grep -qxF "$(printf 'docs/decisions/0001-record-architecture-decisions.md\tnonadopt-both\tno\tbaseline+target\tco-owned-prose; unverified-equivalent')" \
    "$GU_NA_TSV"
for na_seed in terraform/main.tf prettier.config.cjs; do
    expect_ok "unverified class-K equivalent is noted: $na_seed" \
        grep -qxF "$(printf '%s\tnonadopt-both\tno\tbaseline+target\tunverified-equivalent' \
            "$na_seed")" "$GU_NA_TSV"
done
expect_ok "the root Brewfile is a plain row in a repo that is not chezmoi-shaped" \
    grep -qxF "$(printf 'Brewfile\tnonadopt-both\tno\tbaseline+target\t-')" \
    "$GU_NA_TSV"
# Now supply every documented equivalent and re-run: the evidence flips.
mkdir -p "$GU_NA_REPO/docs/decisions" "$GU_NA_REPO/terraform/environments/prod"
printf '%s\n' 'renumbered' \
    >"$GU_NA_REPO/docs/decisions/0007-record-architecture-decisions.md"
printf '%s\n' 'real infra' \
    >"$GU_NA_REPO/terraform/environments/prod/main.tf"
printf '%s\n' '{}' >"$GU_NA_REPO/.prettierrc.json"
printf '%s\n' 'chezmoi' >"$GU_NA_REPO/.chezmoiroot"
printf '%s\n' 'brew bundle' >"$GU_NA_REPO/private_Brewfile"
git_commit_all "$GU_NA_REPO" "add the equivalents"
expect_ok "note fixture re-runs clean once the equivalents exist" na_classify
expect_ok "notes accumulate when the class-K evidence verifies" \
    grep -qxF "$(printf 'docs/decisions/0001-record-architecture-decisions.md\tnonadopt-both\tno\tbaseline+target\tco-owned-prose; known-false-verified')" \
    "$GU_NA_TSV"
for na_seed in terraform/main.tf prettier.config.cjs; do
    expect_ok "verified class-K equivalent is noted, not filtered: $na_seed" \
        grep -qxF "$(printf '%s\tnonadopt-both\tno\tbaseline+target\tknown-false-verified' \
            "$na_seed")" "$GU_NA_TSV"
done
expect_ok "a chezmoi-shaped repo gets the contested Brewfile annotation" \
    grep -qxF "$(printf 'Brewfile\tnonadopt-both\tno\tbaseline+target\tchezmoi-managed — verify per mode-audit class K')" \
    "$GU_NA_TSV"
# Near-misses: a flat terraform root is the seed layout itself, `.terraform` is
# generated cache, an unrelated numbered ADR is not a re-recorded decision, and a
# `private_Brewfile` without a marker is just a filename.
rm -rf "$GU_NA_REPO/terraform/environments"
printf '%s\n' 'flat' >"$GU_NA_REPO/terraform/other.tf"
mkdir -p "$GU_NA_REPO/terraform/.terraform/modules/vpc"
printf '%s\n' 'vendored' \
    >"$GU_NA_REPO/terraform/.terraform/modules/vpc/main.tf"
rm -f "$GU_NA_REPO/.chezmoiroot" "$GU_NA_REPO/.prettierrc.json" \
    "$GU_NA_REPO/docs/decisions/0007-record-architecture-decisions.md"
printf '%s\n' 'unrelated decision' \
    >"$GU_NA_REPO/docs/decisions/0002-use-postgres.md"
git_commit_all "$GU_NA_REPO" "near misses only"
expect_ok "note fixture re-runs clean on the negative controls" na_classify
expect_ok "a flat terraform root does not verify the nested-layout equivalent" \
    grep -qxF "$(printf 'terraform/main.tf\tnonadopt-both\tno\tbaseline+target\tunverified-equivalent')" \
    "$GU_NA_TSV"
expect_ok "private_Brewfile without a chezmoi marker earns no annotation" \
    grep -qxF "$(printf 'Brewfile\tnonadopt-both\tno\tbaseline+target\t-')" \
    "$GU_NA_TSV"
expect_ok "an unrelated numbered ADR does not verify the seed ADR" \
    grep -qxF "$(printf 'docs/decisions/0001-record-architecture-decisions.md\tnonadopt-both\tno\tbaseline+target\tco-owned-prose; unverified-equivalent')" \
    "$GU_NA_TSV"
printf '%s\n' '# Decisions' >"$GU_NA_REPO/docs/decisions/README.md"
git_commit_all "$GU_NA_REPO" "README-backed log"
expect_ok "note fixture re-runs clean with a README-backed ADR log" na_classify
expect_ok "a README-backed numbered ADR log is recorded as verified" \
    grep -qxF "$(printf 'docs/decisions/0001-record-architecture-decisions.md\tnonadopt-both\tno\tbaseline+target\tco-owned-prose; known-false-verified')" \
    "$GU_NA_TSV"
rm -f "$GU_NA_REPO/docs/decisions/0002-use-postgres.md"
git_commit_all "$GU_NA_REPO" "empty index"
expect_ok "note fixture re-runs clean with an empty ADR index" na_classify
expect_ok "a README with no numbered ADR does not verify the seed ADR" \
    grep -qxF "$(printf 'docs/decisions/0001-record-architecture-decisions.md\tnonadopt-both\tno\tbaseline+target\tco-owned-prose; unverified-equivalent')" \
    "$GU_NA_TSV"
# The prettier key is PARSED: a devDependency is not a config.
printf '%s\n' '{"name":"notes","devDependencies":{"prettier":"^3.3.0"}}' \
    >"$GU_NA_REPO/package.json"
git_commit_all "$GU_NA_REPO" "prettier devDependency"
expect_ok "note fixture re-runs clean with prettier as a devDependency" na_classify
expect_ok "a prettier devDependency is not a prettier config" \
    grep -qxF "$(printf 'prettier.config.cjs\tnonadopt-both\tno\tbaseline+target\tunverified-equivalent')" \
    "$GU_NA_TSV"
printf '%s\n' '{"name":"notes","prettier":{"semi":false}}' \
    >"$GU_NA_REPO/package.json"
git_commit_all "$GU_NA_REPO" "prettier key"
expect_ok "note fixture re-runs clean with a package.json prettier key" na_classify
expect_ok "a package.json prettier key is recorded as verified evidence" \
    grep -qxF "$(printf 'prettier.config.cjs\tnonadopt-both\tno\tbaseline+target\tknown-false-verified')" \
    "$GU_NA_TSV"
# Advisory, unlike the ignore probes: a malformed package.json must not abort a
# guarded run that is otherwise fine.
printf '%s\n' '{"name":"notes",,,' >"$GU_NA_REPO/package.json"
git_commit_all "$GU_NA_REPO" "malformed package.json"
expect_ok "a malformed package.json does not abort the classifier" na_classify
expect_ok "an unparseable package.json verifies nothing and says so" \
    grep -qxF "$(printf 'prettier.config.cjs\tnonadopt-both\tno\tbaseline+target\tpackage-json-unparseable; unverified-equivalent')" \
    "$GU_NA_TSV"
rm -f "$GU_NA_REPO/package.json"
git_commit_all "$GU_NA_REPO" "drop package.json"
# The render-side evaluator must answer for the TEMPLATE, never for this machine.
printf '%s\n' 'AGENTS.md' >"$GU_NA_ROOT/machine-excludes"
expect_ok "note fixture re-runs clean under a hostile machine excludesFile" \
    env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.excludesFile \
    "GIT_CONFIG_VALUE_0=$GU_NA_ROOT/machine-excludes" \
    sh -c 'cd "$1" && GUARDED_STATE=.copier-guarded-update \
        BASELINE_DISCOVERY="$2" TARGET_DISCOVERY="$3" \
        GUARDED_TEMPLATE="$5" HARMON_INIT_SOURCE="https://example.invalid/notes" \
        GUARDED_COPIER_CACHE="$6" HARMON_INIT_COMMIT="$7" \
        REVIEWED_DATA=".copier-guarded-update/reviewed-data.yml" \
        bash -eu "$4" >/dev/null' sh \
    "$GU_NA_REPO" "$GU_NA_BASE" "$GU_NA_TGT" "$GU_NONADOPT_RUNNER" \
    "$GU_NA_TPL" "$GU_NA_CACHE" "$GU_NA_TPL_COMMIT"
expect_ok "the operator's own ignore file grants no template declaration" \
    grep -qxF "$(printf 'AGENTS.md\tnonadopt-both\tno\tbaseline+target\t-')" \
    "$GU_NA_TSV"
# A DIRECTORY where the render ships a file used to be a note on a row, which
# let the guarded run continue into a real apply that copier aborts on. The
# rehearsal hits it first and stops the run before the worktree is touched —
# strictly better than annotating it, and one more behaviour nobody had to model.
mkdir -p "$GU_NA_REPO/AGENTS.md"
printf '%s\n' 'not the agents file' >"$GU_NA_REPO/AGENTS.md/NOTICE.txt"
git_commit_all "$GU_NA_REPO" "a directory where a file belongs"
# The classifier RETAINS the scratch on a diagnostic exit deliberately — when the
# apply fails, that half-applied tree and copier's own output are the diagnosis,
# and the error message names its location. So this fixture must clean up after
# itself, and it does so by owning the directory rather than by identifying which
# entries in the shared tmpdir are "its". The earlier shape diffed the system
# tmpdir before and after and `rm -rf`'d anything new — which on a machine
# running a second guarded update would have deleted that run's scratch out from
# under it.
NA_REFUSAL_TMP="$TMPROOT/dir-refusal-tmp"
mkdir -p "$NA_REFUSAL_TMP"
NA_REFUSAL_TMP="$(cd "$NA_REFUSAL_TMP" && pwd -P)"
na_classify_private_tmp() {
    (
        TMPDIR="$NA_REFUSAL_TMP"
        export TMPDIR
        na_classify
    )
}
expect_fail "the rehearsal refuses a directory at a rendered file's path" \
    na_classify_private_tmp
expect_ok "the refused rehearsal left its scratch behind for inspection" \
    sh -c 'test -n "$(ls -A "$1")"' sh "$NA_REFUSAL_TMP"
rm -rf "$NA_REFUSAL_TMP"
expect_fail "the fixture's private scratch directory is gone" \
    test -e "$NA_REFUSAL_TMP"
# The retention is only defensible if the operator is told where to look.
expect_ok "a failed rehearsal names the scratch it left behind" \
    sh -c 'test "$(grep -cF "inspect \$NONADOPT_SCRATCH" "$1")" -eq 2' sh \
    "$GU_NONADOPT_SNIPPET"
rm -rf "$GU_NA_REPO/AGENTS.md"
git_commit_all "$GU_NA_REPO" "remove the blocking directory"

# --- the rehearsal copies managed content only --------------------------------
# A whole-tree copy pulled in every ignored byte the repo happened to hold. This
# fixture plants an unmanaged cache beside a managed ignored path and checks
# which one reaches the scratch. `scratch-copy-paths` survives the run, so the
# copy set is directly assertable rather than inferred.
SCOPE_ROOT="$TMPROOT/rehearsal-scope"
SCOPE_TPL="$SCOPE_ROOT/template"
mkdir -p "$SCOPE_TPL/template/.vscode" "$SCOPE_ROOT/cache"
cat >"$SCOPE_TPL/copier.yml" <<'EOF'
_min_copier_version: "9.4.0"
_subdirectory: template
project_name:
  type: str
  default: Scope
EOF
printf '%s\n' '{{ _copier_answers|to_nice_yaml -}}' \
    >"$SCOPE_TPL/template/.copier-answers.yml.jinja"
printf '%s\n' '{"local":true}' >"$SCOPE_TPL/template/.vscode/local.json"
printf '%s\n' 'agents' >"$SCOPE_TPL/template/AGENTS.md"
printf '%s\n' 'baseline' >"$SCOPE_TPL/template/version.txt"
printf '%s\n' '.vscode/*' 'node_modules/' >"$SCOPE_TPL/template/.gitignore"
git_init "$SCOPE_TPL"
# Render-ignored yet template-managed: force-add or the template's own
# .gitignore keeps it out of the template repo and it never renders.
git -C "$SCOPE_TPL" add -f template/.vscode/local.json
git_commit_all "$SCOPE_TPL" "scope baseline"
SCOPE_BASE_COMMIT="$(git -C "$SCOPE_TPL" rev-parse HEAD)"
copier copy --trust --defaults --skip-tasks --vcs-ref="$SCOPE_BASE_COMMIT" \
    "$SCOPE_TPL" "$SCOPE_ROOT/repo" >/dev/null
git_init "$SCOPE_ROOT/repo"
git_commit_all "$SCOPE_ROOT/repo" "generated"
printf '%s\n' '/.copier-guarded-update/' >>"$SCOPE_ROOT/repo/.git/info/exclude"
# The unmanaged cache: ignored, present, and nothing to do with the template.
mkdir -p "$SCOPE_ROOT/repo/node_modules/pkg/deep"
for scope_n in 1 2 3 4 5; do
    printf '%s\n' "junk $scope_n" \
        >"$SCOPE_ROOT/repo/node_modules/pkg/deep/f$scope_n.js"
done
printf '%s\n' 'target' >"$SCOPE_TPL/template/version.txt"
git_commit_all "$SCOPE_TPL" "scope target"
SCOPE_TGT_COMMIT="$(git -C "$SCOPE_TPL" rev-parse HEAD)"
SCOPE_STATE="$SCOPE_ROOT/repo/.copier-guarded-update"
mkdir -p "$SCOPE_STATE"
printf '{}\n' >"$SCOPE_STATE/reviewed-data.yml"
copier copy --trust --defaults --skip-tasks --vcs-ref="$SCOPE_BASE_COMMIT" \
    "$SCOPE_TPL" "$SCOPE_ROOT/base-render" >/dev/null
copier copy --trust --defaults --skip-tasks --vcs-ref="$SCOPE_TGT_COMMIT" \
    "$SCOPE_TPL" "$SCOPE_ROOT/target-render" >/dev/null
for scope_side in base target; do
    (cd "$SCOPE_ROOT/$scope_side-render" && find . \( -type f -o -type l \) -print) |
        sed 's#^\./##' | LC_ALL=C sort -u \
        >"$SCOPE_STATE/$(test "$scope_side" = base &&
            printf baseline || printf target)-managed-paths"
done
: >"$SCOPE_STATE/ignored-existing-paths"
: >"$SCOPE_STATE/ignored-absent-paths"
while IFS= read -r scope_path; do
    git -C "$SCOPE_ROOT/repo" check-ignore -q -- "$scope_path" || continue
    if test -e "$SCOPE_ROOT/repo/$scope_path"; then
        printf '%s\n' "$scope_path" >>"$SCOPE_STATE/ignored-existing-paths"
    else
        printf '%s\n' "$scope_path" >>"$SCOPE_STATE/ignored-absent-paths"
    fi
done <"$SCOPE_STATE/target-managed-paths"
expect_ok "the scope fixture really has a managed ignored path" \
    grep -qx '.vscode/local.json' "$SCOPE_STATE/ignored-existing-paths"
expect_ok "the rehearsal runs clean against a repo holding an unmanaged cache" \
    sh -c 'cd "$1" && GUARDED_STATE=.copier-guarded-update \
        BASELINE_DISCOVERY="$2" TARGET_DISCOVERY="$3" \
        GUARDED_TEMPLATE="$4" HARMON_INIT_SOURCE="https://example.invalid/scope" \
        GUARDED_COPIER_CACHE="$5" HARMON_INIT_COMMIT="$6" \
        REVIEWED_DATA=".copier-guarded-update/reviewed-data.yml" \
        bash -eu "$7" >/dev/null' sh \
    "$SCOPE_ROOT/repo" "$SCOPE_ROOT/base-render" "$SCOPE_ROOT/target-render" \
    "$SCOPE_TPL" "$SCOPE_ROOT/cache" "$SCOPE_TGT_COMMIT" "$GU_NONADOPT_RUNNER"
expect_fail "the unmanaged ignored cache is not overlaid into the scratch" \
    grep -q node_modules "$SCOPE_STATE/scratch-overlay-paths"
expect_ok "the managed ignored path IS overlaid into the scratch" \
    grep -qx './.vscode/local.json' "$SCOPE_STATE/scratch-overlay-paths"
# End-to-end proof that the overlay MATTERS: without it the clone would lack the
# managed ignored file, copier would render it back, and it would surface as a
# `created` row. Its absence from the report is the overlay doing its job.
expect_fail "the overlaid ignored path is not reported as a non-adoption" \
    grep -q '.vscode/local.json' "$SCOPE_STATE/nonadoption-report.tsv"
# THE one-universe invariant. The scratch is deliberately a subset of the
# worktree, so diffing the real repo against it reported every unmanaged ignored
# file as deleted by the apply — five rows here, thousands on a real repo — and
# reconciliation then failed against a tree that still had them. Both sides of
# the diff now come from the scratch.
expect_fail "unmanaged ignored content is not reported as deleted by the apply" \
    grep -q node_modules "$SCOPE_STATE/nonadoption-report.tsv"
expect_ok "both sides of the rehearsal diff are inventoried from the scratch" \
    sh -c 'test "$(grep -c "nonadoption_inventory \"\$NONADOPT_SCRATCH/repo\"" "$1")" -eq 2 &&
        ! grep -qF "nonadoption_inventory . >" "$1"' sh \
    "$GU_NONADOPT_SNIPPET"
# A before-inventory taken after the update would make every diff empty, so the
# ordering is asserted rather than assumed.
expect_ok "the before-inventory is taken before the rehearsal update" \
    sh -c 'before="$(grep -nF "apply-before-paths\" ||" "$1" | head -1 | cut -d: -f1)"
        upd="$(grep -nF "run_guarded_copier update --trust --defaults --skip-tasks" "$1" |
            head -1 | cut -d: -f1)"
        after="$(grep -nF "apply-after-paths\" ||" "$1" | head -1 | cut -d: -f1)"
        test -n "$before" && test -n "$upd" && test -n "$after" &&
        test "$before" -lt "$upd" && test "$upd" -lt "$after"' sh \
    "$GU_NONADOPT_SNIPPET"

# --- the frozen verdict is bound to the run that produced it ------------------
# "clean" on its own is a claim with no subject. Rollback deletes GUARDED_STATE
# but leaves the branch-keyed files, so a rollback-then-rerun that dies before
# persisting used to leave a clean verdict beside a report describing a tree
# nobody has any more — and §4 accepted it.
VB_DIR="$TMPROOT/verdict-binding"
mkdir -p "$VB_DIR/.copier-guarded-update"
git_init "$VB_DIR"
printf '%s\n' 'seed' >"$VB_DIR/seed.txt"
git_commit_all "$VB_DIR" "seed"
printf '%s\n' '/.copier-guarded-update/' >>"$VB_DIR/.git/info/exclude"
VB_STATE="$VB_DIR/.copier-guarded-update"
printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' >"$VB_STATE/target-commit"
git -C "$VB_DIR" rev-parse HEAD >"$VB_STATE/start-head"
printf 'gone.md\tunknown-until-apply\tn/a-removed\tbaseline-only\t-\n' \
    >"$VB_STATE/nonadoption-report.tsv"
expect_ok "reconciliation records a verdict for this run" \
    sh -c 'cd "$1" && bash -eu "$2"' sh "$VB_DIR" "$GU_RECONCILE"
expect_ok "the verdict names the report it describes" \
    sh -c 'oid="$(git -C "$1" hash-object \
            "$1/.copier-guarded-update/nonadoption-report.tsv")"
        grep -qx "report: $oid" "$1/.copier-guarded-update/nonadoption-reconciled"' sh \
    "$VB_DIR"
expect_ok "the verdict names the run's target commit and start head" \
    sh -c 'grep -qx "target-commit: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$1" &&
        grep -qE "^start-head: [0-9a-f]{40}$" "$1"' sh \
    "$VB_STATE/nonadoption-reconciled"
# The rollback-then-rerun shape: the report changes, the old verdict does not.
# A word-only check passes here; the binding does not.
printf 'other.md\tnonadopt-both\tno\tbaseline+target\t-\n' \
    >"$VB_STATE/nonadoption-report.tsv"
expect_ok "a stale verdict still says clean — which is why the word is not enough" \
    grep -qx 'reconciled: clean' "$VB_STATE/nonadoption-reconciled"
expect_fail "a stale verdict no longer matches the report beside it" \
    sh -c 'oid="$(git -C "$1" hash-object \
            "$1/.copier-guarded-update/nonadoption-report.tsv")"
        grep -qx "report: $oid" "$1/.copier-guarded-update/nonadoption-reconciled"' sh \
    "$VB_DIR"
# §1 clears both branch-keyed files on entry, so the rerun cannot inherit them.
expect_ok "section 1 clears this branch's stale report and verdict on entry" \
    sh -c 'grep -qF "guarded-update-nonadoption guarded-update-reconciled" "$1" &&
        grep -qF "NONADOPT_STALE_FILE" "$1" &&
        grep -qF "rm -f -- \"\$NONADOPT_STALE_FILE\"" "$1"' sh \
    "$GU_NONADOPT_SNIPPET"
# EXECUTED, not grepped. §4's verification was inline bash in a fenced block with
# no extraction handle, so every assertion about it was a `grep` over the prose —
# which is exactly how it shipped hashing a variable that no longer existed in
# that scope. It is a function now, for the same reason `nonadoption_reconcile`
# is one: a recipe a test cannot run is a recipe nothing checks.
GU_VERIFY="$TMPROOT/nonadoption-verify-verdict.sh"
{
    printf '%s\n' 'set -eu'
    sed -n '/^nonadoption_verify_verdict() {/,/^}$/p' \
        "$STANDARDIZE_REFS/mode-update.md"
    printf '%s\n' 'nonadoption_verify_verdict'
} >"$GU_VERIFY"
expect_ok "the verdict verification is extractable from the guidance" \
    sh -c 'grep -qF "nonadoption_verify_verdict() {" "$1" &&
        grep -qF "VERIFY_REPORT_OID" "$1"' sh "$GU_VERIFY"
VV_DIR="$TMPROOT/verdict-verification"
mkdir -p "$VV_DIR"
git_init "$VV_DIR"
printf '%s\n' 'seed' >"$VV_DIR/seed.txt"
git_commit_all "$VV_DIR" "seed"
VV_COMMIT=cccccccccccccccccccccccccccccccccccccccc
VV_OLD_COMMIT=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
vv_write_answers() {
    printf '_commit: %s\n_src_path: https://example.invalid/vv\n' "$1" \
        >"$VV_DIR/.copier-answers.yml"
}
vv_paths() {
    VV_BR="$(git -C "$VV_DIR" branch --show-current)"
    VV_REPORT="$VV_DIR/.git/guarded-update-nonadoption/$VV_BR"
    VV_VERDICT="$VV_DIR/.git/guarded-update-reconciled/$VV_BR"
    mkdir -p "$(dirname "$VV_REPORT")" "$(dirname "$VV_VERDICT")"
}
vv_paths
vv_write_clean() {
    printf 'p\tnonadopt-both\tno\tbaseline+target\t-\n' >"$VV_REPORT"
    {
        printf 'reconciled: clean\n'
        printf 'report: %s\n' "$(git -C "$VV_DIR" hash-object "$VV_REPORT")"
        printf 'target-commit: %s\n' "$VV_COMMIT"
        printf 'start-head: %s\n' "$(git -C "$VV_DIR" rev-parse HEAD)"
    } >"$VV_VERDICT"
}
vv_write_clean_run() {
    vv_write_clean
    vv_write_answers "$VV_COMMIT"
}
# No HARMON_INIT_COMMIT in the environment at all: the verification must read the
# lineage the tree actually carries, and passing the variable would let a broken
# implementation keep passing on the intent instead of the fact.
vv_run() {
    (cd "$VV_DIR" && bash -eu "$GU_VERIFY")
}
# The clean path has to pass, or every refusal below proves nothing. This is the
# assertion that would have caught the unset variable: under `bash -eu` it aborts
# before reaching any check.
vv_write_clean_run
expect_ok "verdict verification accepts a bound, clean, current verdict" vv_run
# ...and each way it must refuse.
mv "$VV_VERDICT" "$VV_VERDICT.away"
expect_fail "verdict verification refuses a missing verdict" vv_run
mv "$VV_VERDICT.away" "$VV_VERDICT"
printf 'reconciled: clean\n' >"$VV_VERDICT"
expect_fail "verdict verification refuses a verdict with no binding" vv_run
vv_write_clean_run
printf 'q\tnonadopt-both\tno\tbaseline+target\t-\n' >"$VV_REPORT"
expect_fail "verdict verification refuses a verdict describing another report" vv_run
# THE lineage case. Reverting `.copier-answers.yml` to the pre-update baseline —
# what §3's manual reconciliation or a `git restore` does — leaves a tree at the
# old version beside a verdict describing the new one. Comparing the verdict to
# the session's own `$HARMON_INIT_COMMIT` passed happily; comparing it to the
# lineage the tree carries does not.
vv_write_clean_run
vv_write_answers "$VV_OLD_COMMIT"
expect_fail "verdict verification refuses a verdict when the answers file was reverted" \
    vv_run
vv_write_clean_run
printf '_src_path: https://example.invalid/vv\n' >"$VV_DIR/.copier-answers.yml"
expect_fail "verdict verification refuses an answers file recording no _commit" \
    vv_run
# A content-only update — every managed path present, only bytes changed —
# legitimately reports nothing. That is a successful run, and refusing it on size
# blocked hand-off on exactly the update that went best. Staleness is caught by
# the hash and lineage binding, not by emptiness.
vv_write_answers "$VV_COMMIT"
: >"$VV_REPORT"
{
    printf 'reconciled: clean\n'
    printf 'report: %s\n' "$(git -C "$VV_DIR" hash-object "$VV_REPORT")"
    printf 'target-commit: %s\n' "$VV_COMMIT"
    printf 'start-head: %s\n' "$(git -C "$VV_DIR" rev-parse HEAD)"
} >"$VV_VERDICT"
expect_ok "verdict verification accepts an empty report with a matching verdict" \
    vv_run
# ...and an empty report still has to be the one the verdict describes.
printf 'x\tnonadopt-both\tno\tbaseline+target\t-\n' >"$VV_REPORT"
expect_fail "an empty verdict binding does not excuse a non-empty report" vv_run
# Missing entirely is a different fact from empty, and still a refusal.
vv_write_clean_run
rm -f "$VV_REPORT"
expect_fail "verdict verification refuses a missing persisted report" vv_run
vv_write_clean_run
expect_ok "the verification tests for existence, not size" \
    sh -c 'grep -qF "test -f \"\$VERIFY_REPORT\"" "$1" &&
        ! grep -qF "test -s \"\$VERIFY_REPORT\"" "$1"' sh "$GU_VERIFY"
expect_ok "the verification reads the lineage rather than the session variable" \
    sh -c 'grep -qF "yq -r '\''._commit // \"\"'\'' .copier-answers.yml" "$1" &&
        ! grep -qE "^[^#]*target-commit: \\\$HARMON_INIT_COMMIT" "$1"' sh \
    "$GU_VERIFY"

# --- conflict artefacts are not adoptions -------------------------------------
# A `.rej`/`.orig` copier leaves behind is created by the apply but shipped by
# neither render. Labelling it `new-in-target` filed a merge failure in the
# adoption table.
ART_DIR="$TMPROOT/apply-artifact"
mkdir -p "$ART_DIR/.copier-guarded-update"
git_init "$ART_DIR"
printf '%s\n' 'seed' >"$ART_DIR/seed.txt"
git_commit_all "$ART_DIR" "seed"
printf '%s\n' '/.copier-guarded-update/' >>"$ART_DIR/.git/info/exclude"
ART_STATE="$ART_DIR/.copier-guarded-update"
printf 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n' >"$ART_STATE/target-commit"
git -C "$ART_DIR" rev-parse HEAD >"$ART_STATE/start-head"
printf '%s\n' 'present' >"$ART_DIR/conf.md.rej"
printf 'conf.md.rej\tunknown-until-apply\tn/a-unrendered\tunrendered\t-\n' \
    >"$ART_STATE/nonadoption-report.tsv"
expect_ok "reconciliation resolves an unrendered created path" \
    sh -c 'cd "$1" && bash -eu "$2"' sh "$ART_DIR" "$GU_RECONCILE"
expect_ok "a path neither render ships is noted as an apply artefact" \
    grep -qxF "$(printf 'conf.md.rej\tcreated\tn/a-unrendered\tunrendered\tapply-artifact')" \
    "$ART_STATE/nonadoption-report.tsv"
expect_ok "the hand-off routes apply artefacts to the anomalies, not the table" \
    sh -c 'grep -qF "noted \`apply-artifact\`" "$1" &&
        grep -qF "never let it reach the table" "$1"' sh \
    "$STANDARDIZE_REFS/mode-update.md"
expect_ok "the classifier derives the created note from target membership" \
    sh -c 'grep -qF "if test \"\$NONADOPT_IN_TARGET\" -eq 0; then" "$1" &&
        grep -qF "nonadoption_add_note apply-artifact" "$1"' sh \
    "$GU_NONADOPT_SNIPPET"

# --- the degraded path resolves with class-appropriate before/after -----------
# Exercised as a unit on the reconciliation recipe: a real `_migrations` update
# cannot produce a surviving baseline-only file on demand, and the label logic is
# what is under test. Reading present-after alone called a surviving
# baseline-only file `created` and a removed one `nonadopt-both`, both backwards.
DEG_DIR="$TMPROOT/degraded-resolution"
mkdir -p "$DEG_DIR/.copier-guarded-update"
for deg_present in keep.md made.md newf.md; do
    printf '%s\n' 'present' >"$DEG_DIR/$deg_present"
done
# §1 records the before-state as a `present-before` note, because reconciliation
# runs after the tree has moved and has no other way to recover it. Membership
# used to be read as a proxy — `baseline-only` implying present — which was only
# true while the degraded branch skipped present paths the target still ships.
# It no longer does, so the note is the contract.
{
    printf 'keep.md\tunknown-until-apply\tn/a-removed\tbaseline-only\tpresent-before\n'
    printf 'gone.md\tunknown-until-apply\tn/a-removed\tbaseline-only\tpresent-before\n'
    printf 'eaten.md\tunknown-until-apply\tno\tbaseline+target\tpresent-before\n'
    printf 'made.md\tunknown-until-apply\tno\tbaseline+target\t-\n'
    printf 'newf.md\tunknown-until-apply\tn/a-new\ttarget-only\tco-owned-prose\n'
    printf 'never.md\tunknown-until-apply\tno\tbaseline+target\t-\n'
} >"$DEG_DIR/.copier-guarded-update/nonadoption-report.tsv"
DEG_TSV="$DEG_DIR/.copier-guarded-update/nonadoption-report.tsv"
expect_ok "reconciliation resolves a degraded report cleanly" \
    sh -c 'cd "$1" && bash -eu "$2"' sh "$DEG_DIR" "$GU_RECONCILE"
# Present before AND after is not a transition; the rehearsed path emits no row
# for it, so the resolution must not invent one.
expect_fail "a surviving present file yields no row" \
    grep -q '^keep\.md' "$DEG_TSV"
expect_ok "a removed baseline-only file resolves to deleted" \
    grep -qxF "$(printf 'gone.md\tdeleted\tn/a-removed\tbaseline-only\tpresent-before')" \
    "$DEG_TSV"
# THE degraded gap. A path the repo had and the target still ships was skipped
# entirely, on the reasoning that an ordinary apply leaves it alone — but this
# branch exists BECAUSE migrations run arbitrary commands, and one can delete it.
# The row exists now, and its disappearance is flagged as a question.
expect_ok "a present in-target file the apply removed resolves to deleted" \
    grep -qxF "$(printf 'eaten.md\tdeleted\tno\tbaseline+target\tpresent-before; migration-effect?')" \
    "$DEG_TSV"
expect_ok "the degraded branch records the before-state it observed" \
    sh -c 'grep -qF "nonadoption_add_note present-before" "$1" &&
        grep -qF "*present-before*)" "$2"' sh \
    "$GU_NONADOPT_SNIPPET" "$GU_RECONCILE"
expect_ok "a both-renders file the apply wrote resolves to created/recreated" \
    grep -qxF "$(printf 'made.md\tcreated\tno\tbaseline+target\trecreated')" \
    "$DEG_TSV"
expect_ok "a target-only file the apply wrote keeps its evidence in order" \
    grep -qxF "$(printf 'newf.md\tcreated\tn/a-new\ttarget-only\tnew-in-target; co-owned-prose')" \
    "$DEG_TSV"
expect_ok "a file the apply never wrote resolves to nonadopt-both" \
    grep -qxF "$(printf 'never.md\tnonadopt-both\tno\tbaseline+target\t-')" \
    "$DEG_TSV"

# --- the rehearsal must not touch the repo it rehearses on --------------------
# A LINKED worktree's `.git` is a POINTER FILE. Copying it verbatim leaves the
# scratch resolving to the real worktree's admin dir, and copier runs
# `git write-tree` in the subproject during update — so the rehearsal would stage
# into the very tree it exists to observe from a distance. This repo is itself
# developed in linked worktrees, so the hazard is the normal case, not a corner.
ISO_ROOT="$TMPROOT/rehearsal-isolation"
ISO_TPL="$ISO_ROOT/template"
mkdir -p "$ISO_TPL/template" "$ISO_ROOT/cache"
cat >"$ISO_TPL/copier.yml" <<'EOF'
_min_copier_version: "9.4.0"
_subdirectory: template
project_name:
  type: str
  default: Iso
EOF
printf '%s\n' '{{ _copier_answers|to_nice_yaml -}}' \
    >"$ISO_TPL/template/.copier-answers.yml.jinja"
printf '%s\n' 'agents' >"$ISO_TPL/template/AGENTS.md"
printf '%s\n' 'baseline' >"$ISO_TPL/template/version.txt"
git_init "$ISO_TPL"
git_commit_all "$ISO_TPL" "iso baseline"
ISO_BASE_COMMIT="$(git -C "$ISO_TPL" rev-parse HEAD)"
copier copy --trust --defaults --skip-tasks --vcs-ref="$ISO_BASE_COMMIT" \
    "$ISO_TPL" "$ISO_ROOT/main" >/dev/null
git_init "$ISO_ROOT/main"
git_commit_all "$ISO_ROOT/main" "generated"
printf '%s\n' 'target' >"$ISO_TPL/template/version.txt"
git_commit_all "$ISO_TPL" "iso target"
ISO_TGT_COMMIT="$(git -C "$ISO_TPL" rev-parse HEAD)"
# The subject: a LINKED worktree, whose .git is a pointer file.
git -C "$ISO_ROOT/main" worktree add -q "$ISO_ROOT/wt" -b feat/rehearse >/dev/null
expect_ok "the isolation fixture really is a linked worktree" \
    test -f "$ISO_ROOT/wt/.git"
rm "$ISO_ROOT/wt/AGENTS.md"
git_commit_all "$ISO_ROOT/wt" "decline AGENTS.md"
ISO_STATE="$ISO_ROOT/wt/.copier-guarded-update"
mkdir -p "$ISO_STATE"
printf '{}\n' >"$ISO_STATE/reviewed-data.yml"
printf '%s\n' '/.copier-guarded-update/' \
    >>"$(git -C "$ISO_ROOT/wt" rev-parse --git-path info/exclude)"
copier copy --trust --defaults --skip-tasks --vcs-ref="$ISO_BASE_COMMIT" \
    "$ISO_TPL" "$ISO_ROOT/base-render" >/dev/null
copier copy --trust --defaults --skip-tasks --vcs-ref="$ISO_TGT_COMMIT" \
    "$ISO_TPL" "$ISO_ROOT/target-render" >/dev/null
for iso_side in base target; do
    (cd "$ISO_ROOT/$iso_side-render" && find . \( -type f -o -type l \) -print) |
        sed 's#^\./##' | LC_ALL=C sort -u \
        >"$ISO_STATE/$(test "$iso_side" = base &&
            printf baseline || printf target)-managed-paths"
done
: >"$ISO_STATE/ignored-absent-paths"
: >"$ISO_STATE/ignored-existing-paths"
ISO_INDEX="$(git -C "$ISO_ROOT/wt" rev-parse --git-path index)"
ISO_INDEX_BEFORE="$(git hash-object "$ISO_INDEX")"
expect_ok "the rehearsal runs clean from inside a linked worktree" \
    sh -c 'cd "$1" && GUARDED_STATE=.copier-guarded-update \
        BASELINE_DISCOVERY="$2" TARGET_DISCOVERY="$3" \
        GUARDED_TEMPLATE="$4" HARMON_INIT_SOURCE="https://example.invalid/iso" \
        GUARDED_COPIER_CACHE="$5" HARMON_INIT_COMMIT="$6" \
        REVIEWED_DATA=".copier-guarded-update/reviewed-data.yml" \
        bash -eu "$7" >/dev/null' sh \
    "$ISO_ROOT/wt" "$ISO_ROOT/base-render" "$ISO_ROOT/target-render" \
    "$ISO_TPL" "$ISO_ROOT/cache" "$ISO_TGT_COMMIT" "$GU_NONADOPT_RUNNER"
# THE isolation assertions. At 4c4a84b the pointer-file copy made `git add` in
# the scratch write straight through to this index.
expect_ok "the real worktree's index is untouched by the rehearsal" \
    sh -c 'test "$(git hash-object "$1")" = "$2"' sh \
    "$ISO_INDEX" "$ISO_INDEX_BEFORE"
expect_ok "the real worktree's status is untouched by the rehearsal" \
    sh -c 'test -z "$(git -C "$1" status --porcelain)"' sh "$ISO_ROOT/wt"
expect_ok "the rehearsal still observed the declined path from a linked worktree" \
    grep -qxF "$(printf 'AGENTS.md\tnonadopt-both\tno\tbaseline+target\t-')" \
    "$ISO_STATE/nonadoption-report.tsv"
# The three index properties the hand-built construction each failed on in turn,
# now free with the clone. Asserted on a clone of this very worktree rather than
# on the classifier, because it is `git clone` that is being trusted.
ISO_PROBE="$ISO_ROOT/clone-probe"
printf '%s\n' 'tracked yet ignored' >"$ISO_ROOT/wt/tracked-ignored.txt"
printf '%s\n' 'x' >"$ISO_ROOT/wt/--checkpoint=exec,date"
printf '%s\n' 'tracked-ignored.txt' 'cache/' >"$ISO_ROOT/wt/.gitignore"
mkdir -p "$ISO_ROOT/wt/cache"
printf '%s\n' 'junk' >"$ISO_ROOT/wt/cache/j.txt"
git -C "$ISO_ROOT/wt" add -A >/dev/null
git -C "$ISO_ROOT/wt" add -f tracked-ignored.txt './--checkpoint=exec,date' >/dev/null
git_commit_all "$ISO_ROOT/wt" "awkward index entries"
expect_ok "cloning a linked worktree reproduces its branch and index" \
    sh -c 'cd "$1" && git clone --no-hardlinks --quiet . "$2"' sh \
    "$ISO_ROOT/wt" "$ISO_PROBE"
expect_ok "the clone checks out the linked worktree's own branch" \
    sh -c 'test "$(git -C "$1" symbolic-ref --short HEAD)" = feat/rehearse' sh \
    "$ISO_PROBE"
# Round-2 P1: `git add -A` in a fresh repo drops tracked-but-ignored files, so
# copier read them as deleted. A clone keeps them in the index.
expect_ok "a tracked-but-ignored file stays in the cloned index" \
    sh -c 'test -n "$(git -C "$1" ls-files tracked-ignored.txt)"' sh "$ISO_PROBE"
# Round-3 P1: a filename that looks like a tar option was passed through a `-T`
# list. There is no path list any more, and the name survives as data.
expect_ok "an option-shaped filename survives as data, not as a flag" \
    sh -c 'test -f "$1/--checkpoint=exec,date"' sh "$ISO_PROBE"
# Untracked ignored content is NOT in the clone — which is the point of the
# managed-only overlay.
expect_fail "unmanaged ignored content is absent from the clone" \
    test -e "$ISO_PROBE/cache/j.txt"

# --- `_migrations` are NOT covered by `--skip-tasks` --------------------------
# Verified against copier 9.17.1: `_execute_tasks(self.template.tasks)` is
# guarded by `skip_tasks`, `migration_tasks("before"/"after")` is not. A
# rehearsal would therefore run migrations a second time, against a copy, with
# the real run still to come — so the rehearsal is refused instead.
MIG_ROOT="$TMPROOT/rehearsal-migrations"
MIG_TPL="$MIG_ROOT/template"
mkdir -p "$MIG_TPL/template" "$MIG_ROOT/cache"
cat >"$MIG_TPL/copier.yml" <<'EOF'
_min_copier_version: "9.4.0"
_subdirectory: template
_migrations:
  - command: ["sh", "-c", "echo ran >> migration-sentinel.txt"]
_tasks:
  - ["sh", "-c", "echo ran >> task-sentinel.txt"]
project_name:
  type: str
  default: Mig
EOF
printf '%s\n' '{{ _copier_answers|to_nice_yaml -}}' \
    >"$MIG_TPL/template/.copier-answers.yml.jinja"
printf '%s\n' 'agents' >"$MIG_TPL/template/AGENTS.md"
printf '%s\n' 'baseline' >"$MIG_TPL/template/version.txt"
git_init "$MIG_TPL"
git_commit_all "$MIG_TPL" "mig baseline"
MIG_BASE_COMMIT="$(git -C "$MIG_TPL" rev-parse HEAD)"
git -C "$MIG_TPL" tag v1.0.0
copier copy --trust --defaults --skip-tasks --vcs-ref=v1.0.0 \
    "$MIG_TPL" "$MIG_ROOT/repo" >/dev/null
git_init "$MIG_ROOT/repo"
git_commit_all "$MIG_ROOT/repo" "generated"
printf '%s\n' 'target' >"$MIG_TPL/template/version.txt"
git_commit_all "$MIG_TPL" "mig target"
git -C "$MIG_TPL" tag v2.0.0
MIG_TGT_COMMIT="$(git -C "$MIG_TPL" rev-parse HEAD)"
# The behavioural fact the guard exists for, proved directly on a throwaway copy.
cp -a "$MIG_ROOT/repo" "$MIG_ROOT/probe"
expect_ok "the migration probe update succeeds" \
    sh -c 'cd "$1" && copier update --trust --defaults --skip-tasks \
        --vcs-ref=v2.0.0 >/dev/null 2>&1' sh "$MIG_ROOT/probe"
expect_ok "_migrations RUN despite --skip-tasks" \
    test -e "$MIG_ROOT/probe/migration-sentinel.txt"
expect_fail "_tasks are correctly suppressed by --skip-tasks" \
    test -e "$MIG_ROOT/probe/task-sentinel.txt"
# ...so the classifier must refuse to rehearse.
rm "$MIG_ROOT/repo/AGENTS.md"
git_commit_all "$MIG_ROOT/repo" "decline AGENTS.md"
MIG_STATE="$MIG_ROOT/repo/.copier-guarded-update"
mkdir -p "$MIG_STATE"
printf '{}\n' >"$MIG_STATE/reviewed-data.yml"
printf '%s\n' '/.copier-guarded-update/' >>"$MIG_ROOT/repo/.git/info/exclude"
copier copy --trust --defaults --skip-tasks --vcs-ref="$MIG_BASE_COMMIT" \
    "$MIG_TPL" "$MIG_ROOT/base-render" >/dev/null
copier copy --trust --defaults --skip-tasks --vcs-ref="$MIG_TGT_COMMIT" \
    "$MIG_TPL" "$MIG_ROOT/target-render" >/dev/null
for mig_side in base target; do
    (cd "$MIG_ROOT/$mig_side-render" && find . \( -type f -o -type l \) -print) |
        sed 's#^\./##' | LC_ALL=C sort -u \
        >"$MIG_STATE/$(test "$mig_side" = base &&
            printf baseline || printf target)-managed-paths"
done
: >"$MIG_STATE/ignored-absent-paths"
: >"$MIG_STATE/ignored-existing-paths"
expect_ok "the classifier degrades cleanly when the target declares _migrations" \
    sh -c 'cd "$1" && GUARDED_STATE=.copier-guarded-update \
        BASELINE_DISCOVERY="$2" TARGET_DISCOVERY="$3" \
        GUARDED_TEMPLATE="$4" HARMON_INIT_SOURCE="https://example.invalid/mig" \
        GUARDED_COPIER_CACHE="$5" HARMON_INIT_COMMIT="$6" \
        REVIEWED_DATA=".copier-guarded-update/reviewed-data.yml" \
        bash -eu "$7" >/dev/null 2>&1' sh \
    "$MIG_ROOT/repo" "$MIG_ROOT/base-render" "$MIG_ROOT/target-render" \
    "$MIG_TPL" "$MIG_ROOT/cache" "$MIG_TGT_COMMIT" "$GU_NONADOPT_RUNNER"
expect_ok "a migrations target yields unknown-until-apply rows" \
    grep -qxF "$(printf 'AGENTS.md\tunknown-until-apply\tno\tbaseline+target\t-')" \
    "$MIG_STATE/nonadoption-report.tsv"
# The whole point: no migration fired in the repo the classifier ran against.
expect_fail "the refused rehearsal ran no migration" \
    test -e "$MIG_ROOT/repo/migration-sentinel.txt"
# And §2's reconciliation resolves those rows against the real apply.
expect_ok "the real update applies and runs its migration exactly once" \
    sh -c 'cd "$1" && copier update --trust --defaults \
        --vcs-ref="$2" >/dev/null 2>&1' sh "$MIG_ROOT/repo" "$MIG_TGT_COMMIT"
expect_ok "reconciliation resolves unknown-until-apply against the real result" \
    sh -c 'cd "$1" && bash -eu "$2" &&
        grep -qxF "$(printf "AGENTS.md\tnonadopt-both\tno\tbaseline+target\t-")" \
            .copier-guarded-update/nonadoption-report.tsv' sh \
    "$MIG_ROOT/repo" "$GU_RECONCILE"

# --- `_skip_if_exists` recreates an absent path: the load-bearing proof --------
# Every `recreate-expected` claim above rests on one fact about copier that no
# amount of reading the classifier can establish: that `_skip_if_exists` on an
# ABSENT path renders it fresh rather than preserving the absence. If that were
# false the whole class would be wrong in the most dangerous direction — telling
# an operator that CODEOWNERS stays gone while the update quietly reinstates it.
# So it is proved against real copier, as a controlled A/B: two files identical
# in every respect that matters (shipped by both renders, byte-identical across
# the range, deleted from the repo in the same commit) differing only in whether
# `_skip_if_exists` covers them. Its own fixture, because a directory-free
# minimal template is far cheaper to reason about than perturbing the guarded
# fixture above — and because a `_skip_if_exists` file added there would ride
# through its rollback and hash assertions.
SKIP_ROOT="$TMPROOT/skip-if-exists"
SKIP_TPL="$SKIP_ROOT/template"
SKIP_PROJ="$SKIP_ROOT/project"
mkdir -p "$SKIP_TPL/template/.github"
cat >"$SKIP_TPL/copier.yml" <<'EOF'
_min_copier_version: "9.4.0"
_subdirectory: template
_skip_if_exists:
  - .github/CODEOWNERS
  - "*.code-workspace"
project_name:
  type: str
  default: Skip
EOF
printf '%s\n' '{{ _copier_answers|to_nice_yaml -}}' \
    >"$SKIP_TPL/template/.copier-answers.yml.jinja"
printf '%s\n' '* @owner' >"$SKIP_TPL/template/.github/CODEOWNERS"
printf '%s\n' 'peacock' >"$SKIP_TPL/template/proj.code-workspace"
# The control: same shape, NOT covered by _skip_if_exists.
printf '%s\n' 'shared' >"$SKIP_TPL/template/shared-note.md"
# The mechanism control. Same shape as shared-note.md, except its CONTENT changes
# across the range — so a diff-driven merge would have a real hunk and no file to
# apply it to, and would conflict or recreate. Copier does neither, which is what
# distinguishes "excluded from creation" from "the diff happened to be empty".
printf '%s\n' 'v1 content' 'line two' >"$SKIP_TPL/template/changed-note.md"
printf '%s\n' 'baseline' >"$SKIP_TPL/template/version.txt"
git_init "$SKIP_TPL"
git_commit_all "$SKIP_TPL" "skip baseline"
git -C "$SKIP_TPL" tag v1.0.0
copier copy --trust --defaults --vcs-ref=v1.0.0 \
    "$SKIP_TPL" "$SKIP_PROJ" >/dev/null
# Copier 9.16 compares the update destination lexically with a resolved
# repository top. Canonicalize this macOS mktemp-derived path so /var and
# /private/var aliases cannot make the fixture crash (harmon-init#847).
SKIP_PROJ="$(cd "$SKIP_PROJ" && pwd -P)"
git_init "$SKIP_PROJ"
git_commit_all "$SKIP_PROJ" "generated"
rm "$SKIP_PROJ/.github/CODEOWNERS" "$SKIP_PROJ/proj.code-workspace" \
    "$SKIP_PROJ/shared-note.md" "$SKIP_PROJ/changed-note.md"
git_commit_all "$SKIP_PROJ" "decline all three"
expect_fail "skip-if-exists fixture starts with the declined paths absent" \
    test -e "$SKIP_PROJ/.github/CODEOWNERS"
# Only version.txt moves across the range; the three declined files are
# byte-identical in both renders, so nothing about THEM is in the applied diff.
printf '%s\n' 'target' >"$SKIP_TPL/template/version.txt"
printf '%s\n' 'v2 content' 'line two rewritten' 'line three' \
    >"$SKIP_TPL/template/changed-note.md"
git_commit_all "$SKIP_TPL" "skip target"
git -C "$SKIP_TPL" tag v2.0.0
expect_ok "skip-if-exists fixture updates cleanly to the target" \
    copier update --trust --defaults --vcs-ref=v2.0.0 "$SKIP_PROJ"
expect_ok "the update applied the target content" \
    grep -qxF target "$SKIP_PROJ/version.txt"
expect_ok "_skip_if_exists RECREATES an absent literal path" \
    test -e "$SKIP_PROJ/.github/CODEOWNERS"
expect_ok "_skip_if_exists RECREATES an absent globbed path" \
    test -e "$SKIP_PROJ/proj.code-workspace"
# The control, in the same update: this is what "permanent" actually looks like.
expect_fail "an ordinary both-renders absence stays absent in the same update" \
    test -e "$SKIP_PROJ/shared-note.md"
# The mechanism control. changed-note.md is byte-DIFFERENT between the two
# renders, so "both renders ship it, therefore the diff is empty" does not apply
# to it — and it still stays gone. Copier excluded it from creation because the
# repo deleted it, full stop. A diff-driven apply would have produced a conflict
# or recreated the file; neither happens, and no reject artifact is written.
expect_fail "a deleted path stays absent even when its content changed in range" \
    test -e "$SKIP_PROJ/changed-note.md"
expect_ok "the changed-in-range exclusion leaves no conflict artifacts" \
    sh -c 'test -z "$(find "$1" -name "*.rej" -o -name "*.orig")"' sh "$SKIP_PROJ"
# It comes back with the TARGET render's content, and untracked — which is why §4
# tells the operator to read it rather than assume their old version returned.
expect_ok "the recreated file carries the render's content, not the repo's" \
    grep -qxF '* @owner' "$SKIP_PROJ/.github/CODEOWNERS"
expect_ok "the recreated file arrives untracked" \
    sh -c 'git -C "$1" status --porcelain -- .github/CODEOWNERS |
        grep -q "^??"' sh "$SKIP_PROJ"

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
# THE payoff assertion of the redesign: replay §4's reconciliation against the
# tree the REAL update produced and require every observation to hold. The
# rehearsal ran the same copier, ref and answers against a copy; if these ever
# disagree the environment moved, and §4 stops the hand-off rather than
# publishing a report about a tree that does not exist.
cp "$GU_NONADOPT_TSV" "$TMPROOT/nonadoption-report.pre-reconcile.tsv"
expect_ok "every rehearsed observation holds against the real apply" \
    sh -c 'cd "$1" && bash -eu "$2"' sh "$GU_TARGET" "$GU_RECONCILE"
# The verdict is FROZEN at the moment of the apply, because §3 is about to make
# deliberate changes that a later presence check would read as divergence.
expect_ok "a clean reconciliation freezes its verdict" \
    grep -qx 'reconciled: clean' \
    "$GU_TARGET/.copier-guarded-update/nonadoption-reconciled"
# The recreate, confirmed on the real tree rather than on the copy.
expect_ok "the real update recreated the _skip_if_exists path too" \
    test -e "$GU_TARGET/.github/CODEOWNERS"
expect_fail "the real update left the declined both-renders file absent" \
    test -e "$GU_TARGET/shared-note.md"
# And the reconciliation FAILS CLOSED when reality disagrees: remove a file the
# rehearsal observed being created and it must report and return non-zero.
cp "$GU_TARGET/.github/CODEOWNERS" "$TMPROOT/codeowners.bak"
rm "$GU_TARGET/.github/CODEOWNERS"
cp "$TMPROOT/nonadoption-report.pre-reconcile.tsv" "$GU_NONADOPT_TSV"
rm -f "$GU_TARGET/.copier-guarded-update/nonadoption-reconciled"
expect_fail "reconciliation returns non-zero when the applied tree diverges" \
    sh -c 'cd "$1" && bash -eu "$2"' sh "$GU_TARGET" "$GU_RECONCILE"
expect_fail "a diverged reconciliation freezes no verdict" \
    test -e "$GU_TARGET/.copier-guarded-update/nonadoption-reconciled"
cp "$TMPROOT/codeowners.bak" "$GU_TARGET/.github/CODEOWNERS"
cp "$TMPROOT/nonadoption-report.pre-reconcile.tsv" "$GU_NONADOPT_TSV"
# The gotcha, proven end to end by a real `copier update`. shared-note.md is in
# both renders and unchanged between them, so the baseline→target diff says
# nothing about it and the repo's deletion stands — no conflict, no mention.
# The two assertions after it are the control: the deletion the TEMPLATE made is
# applied and the file the template ADDED is created, so the absence above is
# not an inert merge, it is the merge working exactly as designed.
expect_ok "copier update never restores a file absent from the repo" \
    test ! -e "$GU_TARGET/shared-note.md"
expect_ok "copier update applies a template-side deletion" \
    test ! -e "$GU_TARGET/retired-doc.md"
expect_ok "copier update creates a file the target template added" \
    test -f "$GU_TARGET/new-doc.md"
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
