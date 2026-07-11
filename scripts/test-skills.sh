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

expect_ok "sync vendors the pinned ref" run_sync sync
prov="$CON/vendored/skills/.SKILLS_PROVENANCE"
expect_ok "requested universal skill vendored (flattened)" test -f "$CON/vendored/skills/uni-one/SKILL.md"
expect_ok "requested frontend skill vendored (flattened)" test -f "$CON/vendored/skills/fe-one/SKILL.md"
expect_ok "unrequested category not vendored" test ! -e "$CON/vendored/skills/be-one"
expect_ok "draft dir without SKILL.md skipped" test ! -e "$CON/vendored/skills/fe-draft"
expect_ok "categories are flattened (no category dirs)" test ! -e "$CON/vendored/skills/universal"
expect_ok "provenance records the ref" grep -q "^# ref: v0.0.0-test " "$prov"
expect_ok "provenance carries do-not-edit marker" grep -q "DO NOT EDIT HERE" "$prov"

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

echo ""
echo "skills tooling tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
