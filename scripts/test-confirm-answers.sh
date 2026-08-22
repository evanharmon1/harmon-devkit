#!/usr/bin/env bash
# test-confirm-answers.sh — unit tests for the standardize-repo confirmation gate
# (ai/skills/repo/standardize-repo/assets/confirm-answers.sh).
#
# Fully hermetic and offline: builds a throwaway copier.yml, a recorded answers
# file and a data file in a temp dir, then drives the real asset against them.
# It never runs copier — the asset under test never does either. Run via
# `task test:confirm-answers`.
set -euo pipefail

repo="$(git rev-parse --show-toplevel)"
ASSET="$repo/ai/skills/repo/standardize-repo/assets/confirm-answers.sh"

command -v yq >/dev/null 2>&1 || {
    echo "test-confirm-answers: required tool 'yq' (v4) is not installed" >&2
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
expect_fail() {
    local desc="$1"
    shift
    if "$@" >/dev/null 2>&1; then bad "$desc (expected non-zero exit)"; else ok "$desc"; fi
}
# Non-zero AND says why: a rejection that fires for an unrelated reason is a
# passing assertion that proves nothing.
expect_fail_contains() {
    local desc="$1" needle="$2" output
    shift 2
    if output="$("$@" 2>&1)"; then
        bad "$desc (expected non-zero exit)"
        return
    fi
    if printf '%s\n' "$output" | grep -qF -- "$needle"; then
        ok "$desc"
    else
        bad "$desc (exited non-zero but never said: $needle)"
        printf '%s\n' "$output" | sed 's/^/      /' >&2
    fi
}
# Assert a rendered table row matches an extended regex.
expect_row() {
    local desc="$1" pattern="$2" table="$3"
    if grep -Eq -- "$pattern" "$table"; then ok "$desc"; else
        bad "$desc (no row matching: $pattern)"
        sed 's/^/      /' "$table" >&2
    fi
}

# ── fixture ───────────────────────────────────────────────────────────
FIX="$TMPROOT/fixture"
mkdir -p "$FIX/state"
cat >"$FIX/copier.yml" <<'YAML'
project_name:
  type: str
  help: "NAME: Formal name of the project"
project_slug:
  type: str
  help: "SLUG: Project slug"
  default: "[[ project_name.lower().replace(' ', '-') ]]"
use_antigravity_cli:
  type: bool
  help: "ANTIGRAVITY: enable the autonomous Antigravity agent"
  default: false
handrolled_token:
  type: str
  help: "TOKEN: this answer is Security-sensitive; review it deliberately"
  default: "unset"
ordinary_thing:
  type: str
  help: "ORDINARY: a plain configuration answer"
  default: "plain"
gated_thing:
  type: str
  help: "GATED: only asked when antigravity is on"
  default: "[[ project_slug ]]-gated"
  when: "[[ use_antigravity_cli ]]"
code_owner:
  type: str
  help: "CODE OWNER: GitHub user/team for CODEOWNERS"
  default: "[[ author_git_provider_username ]]"
use_coderabbit:
  type: bool
  help: "CODERABBIT: opt into the CodeRabbit bot reviewer"
  default: false
_secret_questions:
  - project_name
YAML
cat >"$FIX/recorded.yml" <<'YAML'
project_name: Old Project
use_antigravity_cli: false
ordinary_thing: plain
_commit: v1.0.0
_src_path: https://github.com/evanharmon1/harmon-init
YAML
cat >"$FIX/data.yml" <<'YAML'
project_name: Old Project
use_antigravity_cli: true
ordinary_thing: plain
project_slug: my-project
code_owner: someone
YAML
# Same answers minus the explicit code_owner: its Jinja default then stays
# unresolved, and because code_owner names a principal, --confirm must refuse.
grep -v '^code_owner:' "$FIX/data.yml" >"$FIX/data-unresolved.yml"

run_asset() { "$ASSET" "$@"; }
# Render the table into a file so the assertions can grep it. Keeping the
# redirection in a function (rather than an `sh -c` wrapper) keeps every
# argument a real shell word.
render_to() {
    local out="$1"
    shift
    "$ASSET" "$@" >"$out" 2>&1
}

# ── 1. the resolved table and its classification ──────────────────────
echo "==> resolved table"
TABLE="$TMPROOT/table.txt"
expect_ok "print mode exits 0 and writes nothing" \
    render_to "$TABLE" --template-copier "$FIX/copier.yml" \
    --recorded "$FIX/recorded.yml" --data-file "$FIX/data.yml" \
    --template-commit deadbeef --state-dir "$FIX/state"
expect_fail "print mode wrote no confirmation marker" test -f "$FIX/state/answers-confirmed"

expect_row "a changed answer is flagged CHANGED" \
    '^use_antigravity_cli +data-file +true CHANGED' "$TABLE"
expect_row "a listed security key is flagged SENSITIVE" \
    '^use_antigravity_cli .*SENSITIVE' "$TABLE"
expect_row "an unrecorded answer is flagged NEW" \
    '^project_slug +data-file .*NEW' "$TABLE"
expect_row "a help-matched key is flagged SENSITIVE" \
    '^handrolled_token .*SENSITIVE' "$TABLE"
expect_row "an unchanged ordinary answer carries no flag" \
    '^ordinary_thing +data-file +"plain"$' "$TABLE"
expect_row "a secret question prints <secret>, never its value" \
    '^project_name +data-file +<secret>' "$TABLE"
expect_fail "the secret answer value never reaches stdout" \
    grep -qF 'Old Project' "$TABLE"
expect_row "a template default is sourced and marked as templated" \
    '^gated_thing +template-default .*\(templated default' "$TABLE"
expect_row "a when:-gated question is marked possibly inactive" \
    '^gated_thing .*may be inactive' "$TABLE"
expect_row "an unresolved templated default is flagged UNRESOLVED" \
    '^gated_thing +template-default .*UNRESOLVED' "$TABLE"
expect_row "an explicitly stated principal is resolved, NEW and SENSITIVE" \
    '^code_owner +data-file +"someone" NEW SENSITIVE$' "$TABLE"
expect_row "a bot-trust toggle is flagged SENSITIVE" \
    '^use_coderabbit .*SENSITIVE' "$TABLE"
expect_ok "the summary calls out UNRESOLVED separately" \
    grep -q '^== UNRESOLVED' "$TABLE"
expect_ok "the guidance prefers a one-time approval over a standing rule" \
    grep -qF 'standing, prefix-wide grant' "$TABLE"
expect_ok "the summary calls out CHANGED separately" \
    grep -q '^== CHANGED' "$TABLE"
expect_ok "the summary calls out SENSITIVE separately" \
    grep -q '^== SENSITIVE' "$TABLE"
expect_ok "the guidance names the auto-mode classifier" \
    grep -qF 'auto-mode' "$TABLE"
expect_ok "the guidance names the permission rule to add" \
    grep -qF 'Bash(copier update:*)' "$TABLE"
expect_ok "the guidance forbids self-granting" \
    grep -qF 'never self-grant' "$TABLE"

# --active-keys narrows the rendered set to the active questions.
printf '%s\n' project_name use_antigravity_cli >"$FIX/active-keys"
ACTIVE_TABLE="$TMPROOT/active.txt"
expect_ok "an explicit active-keys file is honored" \
    render_to "$ACTIVE_TABLE" --template-copier "$FIX/copier.yml" \
    --recorded "$FIX/recorded.yml" --data-file "$FIX/data.yml" \
    --active-keys "$FIX/active-keys"
expect_fail "an inactive question is not listed" grep -q '^ordinary_thing ' "$ACTIVE_TABLE"
expect_ok "an active question is listed" grep -q '^use_antigravity_cli ' "$ACTIVE_TABLE"

# recorded=none: every answer is NEW, nothing is CHANGED.
NONE_TABLE="$TMPROOT/none.txt"
expect_ok "recorded 'none' is accepted (adopt-existing / new-repo)" \
    render_to "$NONE_TABLE" --template-copier "$FIX/copier.yml" --recorded none \
    --data-file "$FIX/data.yml"
expect_ok "with no recorded answers every key is NEW" \
    grep -q '^use_antigravity_cli .*NEW' "$NONE_TABLE"
expect_ok "with no recorded answers the CHANGED block is empty" \
    grep -q '^== CHANGED.*== (none)' "$NONE_TABLE"

# ── 2. the --check gate ───────────────────────────────────────────────
echo "==> confirmation gate"
UNRESOLVED_TABLE="$TMPROOT/unresolved.txt"
expect_ok "print mode still renders a set with an unresolved sensitive default" \
    render_to "$UNRESOLVED_TABLE" --template-copier "$FIX/copier.yml" \
    --recorded "$FIX/recorded.yml" --data-file "$FIX/data-unresolved.yml"
expect_row "the unresolved principal is flagged SENSITIVE UNRESOLVED" \
    '^code_owner +template-default .*SENSITIVE UNRESOLVED' "$UNRESOLVED_TABLE"
expect_fail_contains "--confirm refuses while a sensitive default is unresolved" \
    "refusing to confirm" \
    run_asset --template-copier "$FIX/copier.yml" --recorded "$FIX/recorded.yml" \
    --data-file "$FIX/data-unresolved.yml" --template-commit deadbeef \
    --state-dir "$FIX/state" --confirm
expect_fail "an unresolved sensitive default left no marker behind" \
    test -f "$FIX/state/answers-confirmed"
expect_fail_contains "--check fails before any confirmation" \
    "resolved answers not confirmed" \
    run_asset --check --data-file "$FIX/data.yml" --state-dir "$FIX/state" \
    --template-commit deadbeef
expect_ok "--confirm records the marker" \
    render_to "$TMPROOT/confirm.txt" --template-copier "$FIX/copier.yml" \
    --recorded "$FIX/recorded.yml" --data-file "$FIX/data.yml" \
    --template-commit deadbeef --state-dir "$FIX/state" --confirm
expect_ok "the marker exists" test -f "$FIX/state/answers-confirmed"
expect_ok "--check passes after confirmation" \
    run_asset --check --data-file "$FIX/data.yml" --state-dir "$FIX/state" \
    --template-commit deadbeef
expect_fail_contains "--check fails when the template commit moved" \
    "template commit changed after confirmation" \
    run_asset --check --data-file "$FIX/data.yml" --state-dir "$FIX/state" \
    --template-commit cafebabe

# Mutating the reviewed data invalidates the confirmation: the approval was for
# the answers the user actually saw, not for the file path.
printf '%s\n' 'ordinary_thing: tampered' >>"$FIX/data.yml"
expect_fail_contains "--check fails once the data file changes" \
    "data file changed after confirmation" \
    run_asset --check --data-file "$FIX/data.yml" --state-dir "$FIX/state" \
    --template-commit deadbeef

# ── 3. argument handling ──────────────────────────────────────────────
echo "==> argument handling"
expect_fail_contains "--data-file is required" "--data-file is required" \
    run_asset --template-copier "$FIX/copier.yml" --recorded none
expect_fail_contains "--confirm requires a state dir" "--confirm requires --state-dir" \
    run_asset --template-copier "$FIX/copier.yml" --recorded none \
    --data-file "$FIX/data.yml" --confirm
expect_fail_contains "--check requires a state dir" "--check requires --state-dir" \
    run_asset --check --data-file "$FIX/data.yml"
expect_fail_contains "--confirm and --check are exclusive" "exclusive" \
    run_asset --check --confirm --data-file "$FIX/data.yml" --state-dir "$FIX/state"
expect_fail_contains "an unknown flag is rejected" "unknown argument" \
    run_asset --bogus
expect_fail_contains "a missing recorded file is rejected" "no such recorded answers file" \
    run_asset --template-copier "$FIX/copier.yml" --recorded "$FIX/absent.yml" \
    --data-file "$FIX/data.yml"

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
