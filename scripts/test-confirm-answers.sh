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
    echo "  ✓ $*" || true
    return 0
}
bad() {
    fail=$((fail + 1))
    echo "  ✗ $*" >&2 || true
    return 0
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
    if grep -qF -- "$needle" <<<"$output"; then
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
mkdir -p "$FIX/state" && chmod 0700 "$FIX/state"
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
foreman_additional_trusted_actors:
  type: str
  help: "FOREMAN TRUST: logins Foreman may trust. Security-sensitive."
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
foreman_additional_trusted_actors: ""
YAML
# Same answers minus the sensitive question that has NO default: copier
# --defaults would resolve it empty, which the human never saw.
grep -v '^foreman_additional_trusted_actors:' "$FIX/data.yml" >"$FIX/data-unanswered.yml"
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

# Marker-bearing releases use the marker rather than the fallback list.
cp "$FIX/copier.yml" "$FIX/marked.yml"
printf '\n_sensitive_questions:\n  - ordinary_thing\n' >>"$FIX/marked.yml"
MARKED_TABLE="$TMPROOT/marked-table.txt"
expect_ok "marked release renders" render_to "$MARKED_TABLE" \
    --template-copier "$FIX/marked.yml" --recorded "$FIX/recorded.yml" \
    --data-file "$FIX/data.yml"
expect_row "marker flags a key absent from the fallback" \
    '^ordinary_thing .*SENSITIVE' "$MARKED_TABLE"
expect_fail "marker suppresses fallback-only classification" \
    grep -Eq '^use_antigravity_cli .*SENSITIVE' "$MARKED_TABLE"
expect_row "help matching still widens a marked release" \
    '^handrolled_token .*SENSITIVE' "$MARKED_TABLE"
cp "$FIX/copier.yml" "$FIX/empty-marker.yml"
printf '\n_sensitive_questions: []\n' >>"$FIX/empty-marker.yml"
EMPTY_TABLE="$TMPROOT/empty-marker-table.txt"
expect_ok "empty marker is a valid authoritative list" render_to "$EMPTY_TABLE" \
    --template-copier "$FIX/empty-marker.yml" --recorded "$FIX/recorded.yml" \
    --data-file "$FIX/data.yml"
expect_fail "empty marker does not use fallback" \
    grep -Eq '^use_antigravity_cli .*SENSITIVE' "$EMPTY_TABLE"
for invalid in scalar null mapping mixed; do
    cp "$FIX/copier.yml" "$FIX/invalid.yml"
    case "$invalid" in
    scalar) printf '\n_sensitive_questions: nope\n' >>"$FIX/invalid.yml" ;;
    null) printf '\n_sensitive_questions: null\n' >>"$FIX/invalid.yml" ;;
    mapping) printf '\n_sensitive_questions: {foo: bar}\n' >>"$FIX/invalid.yml" ;;
    mixed) printf '\n_sensitive_questions: [ordinary_thing, 3]\n' >>"$FIX/invalid.yml" ;;
    esac
    expect_fail_contains "malformed marker ($invalid) fails closed" \
        '_sensitive_questions must be a list of strings' run_asset \
        --template-copier "$FIX/invalid.yml" --recorded "$FIX/recorded.yml" \
        --data-file "$FIX/data.yml"
done

for duplicate in malformed-first populated-first; do
    cp "$FIX/copier.yml" "$FIX/duplicate.yml"
    case "$duplicate" in
    malformed-first) printf '\n_sensitive_questions: nope\n_sensitive_questions: []\n' >>"$FIX/duplicate.yml" ;;
    populated-first) printf '\n_sensitive_questions: [ordinary_thing]\n_sensitive_questions: []\n' >>"$FIX/duplicate.yml" ;;
    esac
    expect_fail_contains "duplicate marker ($duplicate) fails closed" \
        'duplicate _sensitive_questions key' run_asset \
        --template-copier "$FIX/duplicate.yml" --recorded "$FIX/recorded.yml" \
        --data-file "$FIX/data.yml" --template-commit deadbeef --state-dir "$FIX/state" --confirm
done
cp "$FIX/copier.yml" "$FIX/multi-document.yml"
printf '\n---\n_sensitive_questions: [ordinary_thing]\n' >>"$FIX/multi-document.yml"
expect_fail_contains "marker in a later document fails closed" \
    '_sensitive_questions is not supported in multi-document' run_asset \
    --template-copier "$FIX/multi-document.yml" --recorded "$FIX/recorded.yml" \
    --data-file "$FIX/data.yml" --template-commit deadbeef --state-dir "$FIX/state" --confirm
expect_fail "invalid marker files wrote no confirmation" test -f "$FIX/state/answers-confirmed"

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
expect_fail "an inactive question is not listed as a row" grep -q '^ordinary_thing ' "$ACTIVE_TABLE"
expect_ok "an active question is listed" grep -q '^use_antigravity_cli ' "$ACTIVE_TABLE"
# ...but a data-file answer outside that set is still bound by --confirm, so it
# must surface as UNREVIEWED and block confirmation rather than vanish.
expect_ok "a data-file key outside the active set is reported UNREVIEWED" \
    sh -c 'awk "/^== UNREVIEWED/ { inblock = 1; next } /^== / { inblock = 0 } inblock && /ordinary_thing/ { found = 1 } END { exit found ? 0 : 1 }" "$1"' \
    sh "$ACTIVE_TABLE"
expect_fail_contains "--confirm refuses while a data-file key is outside the active set" \
    "outside the active question set" \
    run_asset --template-copier "$FIX/copier.yml" --recorded "$FIX/recorded.yml" \
    --data-file "$FIX/data.yml" --active-keys "$FIX/active-keys" \
    --template-commit deadbeef --state-dir "$FIX/state" --confirm
expect_fail "an unreviewed data-file key left no marker behind" \
    test -f "$FIX/state/answers-confirmed"

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
UNANSWERED_TABLE="$TMPROOT/unanswered.txt"
expect_ok "print mode renders a set with an unanswered sensitive question" \
    render_to "$UNANSWERED_TABLE" --template-copier "$FIX/copier.yml" \
    --recorded "$FIX/recorded.yml" --data-file "$FIX/data-unanswered.yml"
expect_row "a sensitive question with no answer and no default is SENSITIVE UNRESOLVED" \
    '^foreman_additional_trusted_actors +unanswered .*SENSITIVE UNRESOLVED' "$UNANSWERED_TABLE"
expect_fail_contains "--confirm refuses while a sensitive question has no answer and no default" \
    "refusing to confirm" \
    run_asset --template-copier "$FIX/copier.yml" --recorded "$FIX/recorded.yml" \
    --data-file "$FIX/data-unanswered.yml" --template-commit deadbeef \
    --state-dir "$FIX/state" --confirm
# The state dir is the only durable state: it must be private to the caller.
SHARED_STATE="$TMPROOT/shared-state"
mkdir -p "$SHARED_STATE" && chmod 0777 "$SHARED_STATE"
expect_fail_contains "--confirm refuses a group/world-writable state dir" \
    "group- or world-writable" \
    run_asset --template-copier "$FIX/copier.yml" --recorded "$FIX/recorded.yml" \
    --data-file "$FIX/data.yml" --template-commit deadbeef \
    --state-dir "$SHARED_STATE" --confirm
expect_fail_contains "--check refuses a group/world-writable state dir" \
    "group- or world-writable" \
    run_asset --check --data-file "$FIX/data.yml" --state-dir "$SHARED_STATE" \
    --recorded "$FIX/recorded.yml" --template-commit deadbeef
expect_fail_contains "--check fails before any confirmation" \
    "resolved answers not confirmed" \
    run_asset --check --data-file "$FIX/data.yml" --state-dir "$FIX/state" \
    --recorded "$FIX/recorded.yml" --template-commit deadbeef
expect_ok "--confirm records the marker" \
    render_to "$TMPROOT/confirm.txt" --template-copier "$FIX/copier.yml" \
    --recorded "$FIX/recorded.yml" --data-file "$FIX/data.yml" \
    --template-commit deadbeef --state-dir "$FIX/state" --confirm
expect_ok "the marker exists" test -f "$FIX/state/answers-confirmed"
expect_ok "--check passes after confirmation" \
    run_asset --check --data-file "$FIX/data.yml" --state-dir "$FIX/state" \
    --recorded "$FIX/recorded.yml" --template-commit deadbeef
expect_fail_contains "--check fails when the template commit moved" \
    "template commit changed after confirmation" \
    run_asset --check --data-file "$FIX/data.yml" --state-dir "$FIX/state" \
    --recorded "$FIX/recorded.yml" --template-commit cafebabe

# The recorded answers are an answer source too (copier --defaults fills omitted
# questions from them), so editing that file after approval also fails closed.
cp "$FIX/recorded.yml" "$FIX/recorded-edited.yml"
printf '%s\n' 'use_antigravity_cli: true' >>"$FIX/recorded-edited.yml"
expect_fail_contains "--check fails once the recorded answers change" \
    "recorded answers changed after confirmation" \
    run_asset --check --data-file "$FIX/data.yml" --state-dir "$FIX/state" \
    --recorded "$FIX/recorded-edited.yml" --template-commit deadbeef
expect_fail_contains "--check fails when a confirmation bound to recorded answers is checked with none" \
    "recorded answers changed after confirmation" \
    run_asset --check --data-file "$FIX/data.yml" --state-dir "$FIX/state" \
    --recorded none --template-commit deadbeef
# Mutating the reviewed data invalidates the confirmation: the approval was for
# the answers the user actually saw, not for the file path.
printf '%s\n' 'ordinary_thing: tampered' >>"$FIX/data.yml"
expect_fail_contains "--check fails once the data file changes" \
    "data file changed after confirmation" \
    run_asset --check --data-file "$FIX/data.yml" --state-dir "$FIX/state" \
    --recorded "$FIX/recorded.yml" --template-commit deadbeef

# ── 3. argument handling ──────────────────────────────────────────────
echo "==> argument handling"
expect_fail_contains "--data-file is required" "--data-file is required" \
    run_asset --template-copier "$FIX/copier.yml" --recorded none
expect_fail_contains "--confirm requires a state dir" "--confirm requires --state-dir" \
    run_asset --template-copier "$FIX/copier.yml" --recorded none \
    --data-file "$FIX/data.yml" --confirm
expect_fail_contains "--check requires a state dir" "--check requires --state-dir" \
    run_asset --check --data-file "$FIX/data.yml"
expect_fail_contains "--check requires the template commit" "--check requires --template-commit" \
    run_asset --check --data-file "$FIX/data.yml" --state-dir "$FIX/state" --recorded none
expect_fail_contains "--check requires the recorded answers binding" "--check requires --recorded" \
    run_asset --check --data-file "$FIX/data.yml" --state-dir "$FIX/state" --template-commit deadbeef
expect_fail_contains "--confirm requires the template commit" "--confirm requires --template-commit" \
    run_asset --template-copier "$FIX/copier.yml" --recorded none \
    --data-file "$FIX/data.yml" --state-dir "$FIX/state" --confirm
expect_fail_contains "--confirm and --check are exclusive" "exclusive" \
    run_asset --check --confirm --data-file "$FIX/data.yml" --state-dir "$FIX/state"
expect_fail_contains "an unknown flag is rejected" "unknown argument" \
    run_asset --bogus
expect_fail_contains "a missing recorded file is rejected" "no such recorded answers file" \
    run_asset --template-copier "$FIX/copier.yml" --recorded "$FIX/absent.yml" \
    --data-file "$FIX/data.yml"

# ── 4. carried-forward comparison ────────────────────────────────────
echo "==> carried-forward comparison"
CARRY="$TMPROOT/carry"
mkdir -p "$CARRY/state" && chmod 0700 "$CARRY/state"
cat >"$CARRY/copier.yml" <<'YAML'
project_name:
  type: str
  choices: [Old, New]
  default: Old
project_mode:
  type: str
  choices: [safe, fast]
  default: safe
YAML
cat >"$CARRY/recorded.yml" <<'YAML'
project_name: Old
project_mode: safe
_commit: v1.0.0
YAML
cat >"$CARRY/data.yml" <<'YAML'
project_name: Old
project_mode: safe
YAML
expect_ok "the first explicit confirmation records the comparison snapshot" \
    run_asset --template-copier "$CARRY/copier.yml" \
    --recorded "$CARRY/recorded.yml" --data-file "$CARRY/data.yml" \
    --template-commit old-template --state-dir "$CARRY/state" --confirm
CARRY_TABLE="$TMPROOT/carried-forward.txt"
expect_ok "an unchanged set reports its earlier template commit" \
    render_to "$CARRY_TABLE" --template-copier "$CARRY/copier.yml" \
    --recorded "$CARRY/recorded.yml" --data-file "$CARRY/data.yml" \
    --template-commit new-template --state-dir "$CARRY/state"
expect_ok "the unchanged comparison is the first output line" \
    sh -c 'test "$(sed -n "1p" "$1")" = "Unchanged since confirmation at template commit old-template: active questions, choices, data file, and recorded answers."' \
    sh "$CARRY_TABLE"
expect_ok "the full table follows the unchanged line" \
    sh -c 'case "$(sed -n "2p" "$1")" in *"Resolved copier answers"*) exit 0 ;; *) exit 1 ;; esac' \
    sh "$CARRY_TABLE"
expect_fail_contains "an unchanged set is not confirmed for a new template commit" \
    "template commit changed after confirmation" \
    run_asset --check --data-file "$CARRY/data.yml" --state-dir "$CARRY/state" \
    --recorded "$CARRY/recorded.yml" --template-commit new-template
expect_ok "an explicit confirmation records the new template commit" \
    run_asset --template-copier "$CARRY/copier.yml" \
    --recorded "$CARRY/recorded.yml" --data-file "$CARRY/data.yml" \
    --template-commit new-template --state-dir "$CARRY/state" --confirm
expect_ok "the explicitly confirmed new template passes --check" \
    run_asset --check --data-file "$CARRY/data.yml" --state-dir "$CARRY/state" \
    --recorded "$CARRY/recorded.yml" --template-commit new-template

ACTIVE_CHANGED="$CARRY/active-keys"
printf '%s\n' project_name >"$ACTIVE_CHANGED"
ACTIVE_CHANGED_TABLE="$TMPROOT/active-questions-changed.txt"
expect_ok "a changed active question set is reported" \
    render_to "$ACTIVE_CHANGED_TABLE" --template-copier "$CARRY/copier.yml" \
    --recorded "$CARRY/recorded.yml" --data-file "$CARRY/data.yml" \
    --active-keys "$ACTIVE_CHANGED" --template-commit newer-template \
    --state-dir "$CARRY/state"
expect_ok "the comparison names changed active questions" \
    sh -c 'test "$(sed -n "1p" "$1")" = "Changed since confirmation at template commit new-template: active questions."' \
    sh "$ACTIVE_CHANGED_TABLE"

cat >"$CARRY/choices-changed.yml" <<'YAML'
project_name:
  type: str
  choices: [Old, New, Newer]
  default: Old
project_mode:
  type: str
  choices: [safe, fast]
  default: safe
YAML
CHOICES_CHANGED_TABLE="$TMPROOT/choices-changed.txt"
expect_ok "changed choices are reported" \
    render_to "$CHOICES_CHANGED_TABLE" --template-copier "$CARRY/choices-changed.yml" \
    --recorded "$CARRY/recorded.yml" --data-file "$CARRY/data.yml" \
    --template-commit newer-template --state-dir "$CARRY/state"
expect_ok "the comparison names changed choices" \
    sh -c 'test "$(sed -n "1p" "$1")" = "Changed since confirmation at template commit new-template: choices."' \
    sh "$CHOICES_CHANGED_TABLE"

cat >"$CARRY/data-changed.yml" <<'YAML'
project_name: New
project_mode: safe
YAML
DATA_CHANGED_TABLE="$TMPROOT/data-changed.txt"
expect_ok "a changed data file is reported" \
    render_to "$DATA_CHANGED_TABLE" --template-copier "$CARRY/copier.yml" \
    --recorded "$CARRY/recorded.yml" --data-file "$CARRY/data-changed.yml" \
    --template-commit newer-template --state-dir "$CARRY/state"
expect_ok "the comparison names the changed data file" \
    sh -c 'test "$(sed -n "1p" "$1")" = "Changed since confirmation at template commit new-template: data file."' \
    sh "$DATA_CHANGED_TABLE"

# A marker also binds the recorded answers, including a sensitive value that
# the data file omits. The lead line must not claim unchanged after that file
# changes underneath the same marker.
MARKER="$TMPROOT/marker-recorded"
mkdir -p "$MARKER/state" && chmod 0700 "$MARKER/state"
cat >"$MARKER/copier.yml" <<'YAML'
code_owner:
  type: str
  help: "CODE OWNER: GitHub user/team for CODEOWNERS"
YAML
cat >"$MARKER/recorded.yml" <<'YAML'
code_owner: alice
_commit: old-template
YAML
cat >"$MARKER/data.yml" <<'YAML'
{}
YAML
expect_ok "the marker baseline confirms an omitted recorded answer" \
    run_asset --template-copier "$MARKER/copier.yml" \
    --recorded "$MARKER/recorded.yml" --data-file "$MARKER/data.yml" \
    --template-commit old-template --state-dir "$MARKER/state" --confirm
sed 's/^code_owner: alice$/code_owner: mallory/' "$MARKER/recorded.yml" \
    >"$MARKER/recorded-changed.yml"
MARKER_CHANGED_TABLE="$TMPROOT/marker-recorded-changed.txt"
expect_ok "a recorded answer change under the same marker is reported" \
    render_to "$MARKER_CHANGED_TABLE" --template-copier "$MARKER/copier.yml" \
    --recorded "$MARKER/recorded-changed.yml" --data-file "$MARKER/data.yml" \
    --template-commit newer-template --state-dir "$MARKER/state"
expect_ok "the marker comparison leads with Changed for recorded answers" \
    sh -c 'test "$(sed -n "1p" "$1")" = "Changed since confirmation at template commit old-template: recorded answers."' \
    sh "$MARKER_CHANGED_TABLE"

# Normal guarded updates create a fresh state directory, so their prior
# confirmation is represented by the recorded answers and the offline clone's
# immutable _commit rather than a reusable answers-confirmed marker.
BASELINE="$TMPROOT/baseline"
mkdir -p "$BASELINE/template" "$BASELINE/state" && chmod 0700 "$BASELINE/state"
git -c init.defaultBranch=main init --quiet "$BASELINE/template"
git -C "$BASELINE/template" config user.name "Confirmation Test"
git -C "$BASELINE/template" config user.email "confirmation-test@example.invalid"
cat >"$BASELINE/template/copier.yml" <<'YAML'
project_name:
  type: str
  choices: [Old, New]
  default: Old
project_mode:
  type: str
  choices: [safe, fast]
  default: safe
code_owner:
  type: str
  help: "CODE OWNER: GitHub user/team for CODEOWNERS"
YAML
git -C "$BASELINE/template" add copier.yml
git -C "$BASELINE/template" commit --quiet -m "baseline template"
BASELINE_COMMIT="$(git -C "$BASELINE/template" rev-parse HEAD)"
git -C "$BASELINE/template" tag v1.0.0
printf '%s\n' "$BASELINE/template" >"$BASELINE/state/template-path"
cat >"$BASELINE/recorded.yml" <<YAML
project_name: Old
project_mode: safe
code_owner: alice
_commit: v1.0.0
YAML
cat >"$BASELINE/data.yml" <<'YAML'
project_name: Old
project_mode: safe
YAML
git hash-object "$BASELINE/recorded.yml" >"$BASELINE/state/canonical-answers-oid"
BASELINE_TABLE="$TMPROOT/baseline-comparison.txt"
expect_ok "a fresh guarded-update state compares with the recorded template baseline" \
    render_to "$BASELINE_TABLE" --template-copier "$BASELINE/template/copier.yml" \
    --recorded "$BASELINE/recorded.yml" --data-file "$BASELINE/data.yml" \
    --template-commit new-template --state-dir "$BASELINE/state"
expect_ok "the baseline comparison names the earlier template commit" \
    sh -c 'test "$(sed -n "1p" "$1")" = "Unchanged since confirmation at template commit $2: active questions, choices, data file answers, and recorded answers."' \
    sh "$BASELINE_TABLE" "$BASELINE_COMMIT"
expect_fail "the baseline data file omits the recorded code owner" \
    grep -q '^code_owner:' "$BASELINE/data.yml"
cp "$BASELINE/recorded.yml" "$BASELINE/recorded-changed.yml"
sed 's/^code_owner: alice$/code_owner: mallory/' "$BASELINE/recorded.yml" \
    >"$BASELINE/recorded-changed.yml"
BASELINE_RECORDED_CHANGED_TABLE="$TMPROOT/baseline-recorded-changed.txt"
expect_ok "a recorded answer omitted from data is compared with the baseline snapshot" \
    render_to "$BASELINE_RECORDED_CHANGED_TABLE" \
    --template-copier "$BASELINE/template/copier.yml" \
    --recorded "$BASELINE/recorded-changed.yml" --data-file "$BASELINE/data.yml" \
    --template-commit new-template --state-dir "$BASELINE/state"
expect_ok "the baseline comparison leads with Changed for recorded answers" \
    sh -c 'test "$(sed -n "1p" "$1")" = "Changed since confirmation at template commit $2: recorded answers."' \
    sh "$BASELINE_RECORDED_CHANGED_TABLE" "$BASELINE_COMMIT"
expect_fail_contains "the baseline comparison does not create a confirmation marker" \
    "resolved answers not confirmed" \
    run_asset --check --data-file "$BASELINE/data.yml" --state-dir "$BASELINE/state" \
    --recorded "$BASELINE/recorded.yml" --template-commit new-template
cat >"$BASELINE/data-changed.yml" <<'YAML'
project_name: New
project_mode: safe
YAML
BASELINE_CHANGED_TABLE="$TMPROOT/baseline-changed.txt"
expect_ok "a changed answer against the recorded baseline is reported" \
    render_to "$BASELINE_CHANGED_TABLE" --template-copier "$BASELINE/template/copier.yml" \
    --recorded "$BASELINE/recorded.yml" --data-file "$BASELINE/data-changed.yml" \
    --template-commit new-template --state-dir "$BASELINE/state"
expect_ok "the baseline comparison names changed data file answers" \
    sh -c 'test "$(sed -n "1p" "$1")" = "Changed since confirmation at template commit $2: data file answers."' \
    sh "$BASELINE_CHANGED_TABLE" "$BASELINE_COMMIT"

sed 's/^_commit: v1.0.0$/_commit: missing-tag/' "$BASELINE/recorded.yml" \
    >"$BASELINE/recorded-unresolved.yml"
BASELINE_UNRESOLVED_TABLE="$TMPROOT/baseline-unresolved-commit.txt"
expect_ok "an unresolvable recorded _commit is reported without aborting the answer table" \
    render_to "$BASELINE_UNRESOLVED_TABLE" \
    --template-copier "$BASELINE/template/copier.yml" \
    --recorded "$BASELINE/recorded-unresolved.yml" --data-file "$BASELINE/data.yml" \
    --template-commit new-template --state-dir "$BASELINE/state"
expect_ok "an unresolvable _commit names the actual resolution failure" \
    grep -qF "Cannot compare with recorded baseline _commit 'missing-tag': it cannot be resolved to a commit in the guarded template snapshot." \
    "$BASELINE_UNRESOLVED_TABLE"
expect_fail "an unresolvable _commit is not mislabeled as a missing copier.yml" \
    grep -qF "copier.yml is unavailable in the guarded template snapshot" \
    "$BASELINE_UNRESOLVED_TABLE"

echo
# Parent batch presents carried answers and release additions once per repo.
BATCH="$TMPROOT/batch"
mkdir -p "$BATCH/one-state" "$BATCH/two-state"
chmod 0700 "$BATCH/one-state" "$BATCH/two-state"
cat >"$BATCH/copier.yml" <<'YAML'
project_name:
  type: str
  default: Old
new_question:
  type: str
  default: safe
YAML
printf 'project_name: Old\n' >"$BATCH/recorded.yml"
printf '{}\n' >"$BATCH/one-data.yml"
printf '{}\n' >"$BATCH/two-data.yml"
python3 - "$BATCH" <<'PY'
import json
from pathlib import Path
import sys

directory = Path(sys.argv[1])
rows = [dict(repository=f'example/{name}', template_copier='copier.yml',
             data_file=f'{name}-data.yml', recorded='recorded.yml',
             template_commit='release-commit', state_dir=f'{name}-state')
        for name in ('one', 'two')]
(directory / 'manifest.json').write_text(json.dumps(rows))
(directory / 'single.json').write_text(json.dumps(rows[:1]))
(directory / 'duplicate.json').write_text(json.dumps([rows[0], rows[0]]))
PY
BATCH_TABLE="$BATCH/table.txt"
expect_ok "parent renders the default fleet batch" \
    render_to "$BATCH_TABLE" --batch "$BATCH/manifest.json"
expect_ok "each repository is presented exactly once" \
    sh -c 'test "$(grep -c "^Repository: example/one$" "$1")" = 1 && test "$(grep -c "^Repository: example/two$" "$1")" = 1' \
    sh "$BATCH_TABLE"
expect_row "batch carries recorded answers" '^project_name +recorded ' "$BATCH_TABLE"
expect_row "batch marks the release addition NEW" '^new_question .*NEW' "$BATCH_TABLE"
expect_fail "presentation does not confirm answers" test -f "$BATCH/one-state/answers-confirmed"
expect_ok "parent can explicitly confirm the default batch" \
    run_asset --batch "$BATCH/manifest.json" --confirm
expect_ok "all default batch bindings pass the gate" \
    run_asset --batch "$BATCH/manifest.json" --check
printf 'project_name: Changed\n' >"$BATCH/two-data.yml"
expect_fail_contains "a per-repository answer edit invalidates its batch binding" \
    'data file changed after confirmation' run_asset --batch "$BATCH/manifest.json" --check
expect_ok "parent presents per-repository changes" \
    render_to "$BATCH_TABLE" --batch "$BATCH/manifest.json"
expect_row "changed per-repo answers are labeled CHANGED" '^project_name .*CHANGED' "$BATCH_TABLE"
expect_ok "a one-row manifest supports a parent per-repo invocation" \
    run_asset --batch "$BATCH/single.json" --check
expect_ok "parent reconfirms the reviewed batch after changes" \
    run_asset --batch "$BATCH/manifest.json" --confirm
expect_ok "changed per-repo batch passes after approval" \
    run_asset --batch "$BATCH/manifest.json" --check
expect_fail_contains "duplicate repos are refused before presenting the batch" \
    'duplicate batch repository' run_asset --batch "$BATCH/duplicate.json"

echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
