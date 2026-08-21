#!/usr/bin/env bash
# test-setup-github-project.sh — unit-test setup-github-project.sh's field
# reconciliation against a stubbed `gh`; no live API calls, so it is safe in CI.
# Run via `task test:setup-github-project`.
#
# The invariant worth a test: `updateProjectV2Field` REPLACES the whole
# singleSelectOptions array, and per GitHub's schema an existing option re-sent
# WITHOUT its `id` is destroyed and recreated — silently blanking that field on
# every board item already assigned to it. Appending is therefore only safe while
# every pre-existing option goes back with its id, and nothing else in `verify`
# executes this path (the script talks to the live API, so lint is its only other
# gate). A future edit that drops the ids would otherwise pass every check and
# lose data on the next re-run.
set -euo pipefail
cd "$(dirname "$0")/.."
script="$PWD/scripts/setup-github-project.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
    echo "TEST FAIL: $*" >&2
    [ -f "$tmp/out" ] && sed 's/^/    /' "$tmp/out" >&2
    exit 1
}

# A fake `gh` on PATH: canned reads, and every field mutation appended to
# $MUTATIONS instead of sent. The fields-snapshot case must come first — that
# query also mentions ProjectV2Field* types.
mkdir -p "$tmp/bin"
cat >"$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
# The scope preflight's probe. $STUB_SCOPES unset means "authenticated, but the
# scope list could not be parsed" — the state every reconciliation case below
# runs in, and one the preflight must not treat as a failure.
if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
    [ -n "${STUB_SCOPES:-}" ] && echo "  - Token scopes: ${STUB_SCOPES}"
    exit 0
fi
if [ "$1" = "variable" ] && [ "$2" = "set" ]; then
    exit "${STUB_VARIABLE_RC:-0}"
fi
q=""
for a in "$@"; do case "$a" in query=*) q="${a#query=}" ;; esac; done
case "$q" in
*"fields(first:50)"*)
    if [ -s "${STUB_FIELDS_FILE2:-}" ] && [ -f "$tmp_seen" ]; then
        cat "$STUB_FIELDS_FILE2"
    else
        : >"$tmp_seen"
        cat "$STUB_FIELDS_FILE"
    fi
    ;;
*repositoryOwner*__typename*) printf '{"data":{"repositoryOwner":{"__typename":"%s","id":"U_1"}}}\n' "${STUB_OWNER_TYPE:-User}" ;;
*projectsV2*) echo '{"data":{"repositoryOwner":{"projectsV2":{"pageInfo":{"hasNextPage":false},"nodes":[{"id":"P_1","number":7,"title":"Test Project"}]}}}}' ;;
*ProjectV2Field*) printf '%s\n' "$q" >>"$MUTATIONS"; echo '{"data":{}}' ;;
*) echo "fake gh: unexpected query: $q" >&2; exit 1 ;;
esac
STUB
chmod +x "$tmp/bin/gh"
tmp_seen="$tmp/seen"
export tmp_seen
PATH="$tmp/bin:$PATH"
export PATH

MUTATIONS="$tmp/mutations"
STUB_FIELDS_FILE="$tmp/fields.json"
STUB_FIELDS_FILE2="$tmp/fields2.json"
export MUTATIONS STUB_FIELDS_FILE STUB_FIELDS_FILE2
export STUB_OWNER_TYPE STUB_VARIABLE_RC

# run_with FIELDS_JSON — run the script against that project snapshot.
run_with() {
    printf '%s' "$1" >"$STUB_FIELDS_FILE"
    printf '%s' "${2:-}" >"$STUB_FIELDS_FILE2"
    rm -f "$tmp_seen"
    : >"$MUTATIONS"
    "$script" --owner someuser --title "Test Project" >"$tmp/out" 2>&1 ||
        fail "script exited non-zero"
}

updates() { grep -c updateProjectV2Field "$MUTATIONS" || true; }

# A project already carrying every starter value.
complete='{"data":{"node":{"fields":{"nodes":[
 {"id":"F_status","name":"Status","dataType":"SINGLE_SELECT","options":[
   {"id":"s1","name":"Inbox","color":"GRAY","description":"Newly landed, unsorted"},
   {"id":"s2","name":"Icebox","color":"GRAY","description":"Real, but not now"},
   {"id":"s3","name":"Next","color":"PINK","description":"Will pull in soon"},
   {"id":"s4","name":"Todo","color":"BLUE","description":"Committed, not started"},
   {"id":"s5","name":"Shaping","color":"BLUE","description":"Problem/approach being defined"},
   {"id":"s6","name":"Ready","color":"BLUE","description":"Shaped, ready to pick up"},
   {"id":"s7","name":"Agent Queue","color":"BLUE","description":"Queued for an AI agent"},
   {"id":"s8","name":"In Progress","color":"YELLOW","description":"Actively being worked"},
   {"id":"s9","name":"Verifying","color":"ORANGE","description":"CI/checks running"},
   {"id":"s10","name":"In Review","color":"GREEN","description":"Under human review"},
   {"id":"s11","name":"Ready to Merge","color":"GREEN","description":"Approved, awaiting merge"},
   {"id":"s12","name":"Done","color":"PURPLE","description":"Merged/shipped"},
   {"id":"s13","name":"Deployed","color":"PURPLE","description":"Deployed"},
   {"id":"s14","name":"Accepted","color":"PURPLE","description":"Smoke/QA/manual check passed"}]},
 {"id":"F_size","name":"Size","dataType":"NUMBER"},
 {"id":"F_prod","name":"Product","dataType":"TEXT"},
 {"id":"F_pri","name":"Priority","dataType":"SINGLE_SELECT","options":[
   {"id":"p1","name":"Urgent","color":"RED","description":""},
   {"id":"p2","name":"High","color":"ORANGE","description":""},
   {"id":"p3","name":"Medium","color":"YELLOW","description":""},
   {"id":"p4","name":"Low","color":"GRAY","description":""}]}
]}}}}'

echo "==> a re-run against an already-synced project writes nothing"
run_with "$complete"
[ "$(updates)" = 0 ] || fail "expected no mutations on an unchanged project, got $(updates)"
grep -q "leaving it as-is" "$tmp/out" || fail "expected 'leaving it as-is' output"
grep -q "DONE: GitHub Project is ready" "$tmp/out" || fail "expected an explicit ready outcome"

echo "==> visual progress stays on one ordered stream under Task grouping"
printf '%s' "$complete" >"$STUB_FIELDS_FILE"
rm -f "$tmp_seen"
: >"$MUTATIONS"
NO_COLOR=1 "$script" --owner someuser --title "Test Project" \
    >"$tmp/stdout" 2>"$tmp/stderr" || fail "ordered-stream run exited non-zero"
[ ! -s "$tmp/stdout" ] || fail "action progress leaked onto Task's buffered stdout"
banner_line="$(grep -n '== SETUP :: GitHub Project ==' "$tmp/stderr" | cut -d: -f1 || true)"
progress_line="$(grep -n "Resolving owner 'someuser'" "$tmp/stderr" | cut -d: -f1 || true)"
done_line="$(grep -n 'DONE: GitHub Project is ready' "$tmp/stderr" | cut -d: -f1 || true)"
[ -n "$banner_line" ] && [ -n "$progress_line" ] && [ -n "$done_line" ] ||
    fail "ordered stream is missing its banner, progress, or final outcome"
[ "$banner_line" -lt "$progress_line" ] && [ "$progress_line" -lt "$done_line" ] ||
    fail "action stream did not preserve banner -> progress -> outcome chronology"

echo "==> a failed ORG_PROJECT_ID write degrades the final outcome"
STUB_OWNER_TYPE=Organization
STUB_VARIABLE_RC=19
run_with "$complete"
grep -q "ORG_PROJECT_ID was not written" "$tmp/out" ||
    fail "expected the failed org-variable write in the outcome rows"
grep -q "WARN: GitHub Project needs attention" "$tmp/out" ||
    fail "expected a warning final outcome after the org-variable write failed"
! grep -q "DONE: GitHub Project is ready" "$tmp/out" ||
    fail "failed org-variable write claimed the project was ready"
STUB_OWNER_TYPE=User
STUB_VARIABLE_RC=0

echo "==> the retired Agent field is never created"
# The fixture above deliberately has no Agent field, so any mutation naming one
# is the script recreating it. Advisory routing is the suggest:* label family
# plus Status: Agent Queue; the live claim is a claim:* label (ADR 0005 D4).
case "$(cat "$MUTATIONS")" in
*'name:"Agent"'*) fail "the retired Agent field was created — routing lives in suggest:*/claim:* labels" ;;
esac

echo "==> a field missing a starter option gains ONLY that option"
# Priority lacks `Low` and carries an owner-added `Critical`.
partial=$(printf '%s' "$complete" | jq -c '
    .data.node.fields.nodes |= map(
        if .name == "Priority" then
            .options = [ .options[] | if .name == "Low"
                then {id: "p9", name: "Critical", color: "PINK", description: "owner added"}
                else . end ]
        else . end)')
run_with "$partial"
[ "$(updates)" = 1 ] || fail "expected exactly 1 update mutation, got $(updates)"
mut=$(cat "$MUTATIONS")
case "$mut" in
*'{name:"Low"'*) : ;;
*) fail "the appended option should be sent WITHOUT an id" ;;
esac

echo "==> every pre-existing option is re-sent WITH its id (identity preserved)"
for pair in 'p1:Urgent' 'p9:Critical' 'p3:Medium'; do
    case "$mut" in
    *"{id:\"${pair%%:*}\",name:\"${pair##*:}\""*) : ;;
    *) fail "existing option '${pair##*:}' lost its id '${pair%%:*}' — item values would be cleared" ;;
    esac
done

echo "==> an owner-added option survives the append"
case "$mut" in
*'name:"Critical"'*) : ;;
*) fail "owner-added option 'Critical' was dropped from the replacement list" ;;
esac

echo "==> a field of the wrong data type is warned about, never appended to"
wrong=$(printf '%s' "$complete" | jq -c '
    .data.node.fields.nodes |= map(
        if .name == "Priority" then {id: .id, name: .name, dataType: "TEXT"} else . end)')
run_with "$wrong"
[ "$(updates)" = 0 ] || fail "a wrong-typed field must not receive an option update"
grep -q "already exists as TEXT" "$tmp/out" || fail "expected a data-type warning for Priority"

echo "==> a non-single-select Status warns and is skipped, never aborting the run"
# Status is reconciled by its own call site rather than create_single_select, so
# it needs its own coverage: without the field_exists guard there, existing_options
# runs `.options[]` over a field that has none, jq exits 5, and `set -euo pipefail`
# kills the whole run — a stack trace instead of the warning this script promises,
# and on an org it happens after ORG_PROJECT_ID was already repointed. run_with
# fails the test on any non-zero exit, so the exit-0 half of this is implicit.
wrong_status=$(printf '%s' "$complete" | jq -c '
    .data.node.fields.nodes |= map(
        if .name == "Status" then {id: .id, name: .name, dataType: "TEXT"} else . end)')
run_with "$wrong_status"
[ "$(updates)" = 0 ] || fail "a wrong-typed Status must not receive an option update"
grep -q "field 'Status' already exists as TEXT" "$tmp/out" ||
    fail "expected a data-type warning naming Status and its actual type"
grep -q "Status (is TEXT, wanted SINGLE_SELECT)" "$tmp/out" ||
    fail "expected Status in the end-of-run incompatible summary"
grep -q "WARN: GitHub Project needs attention" "$tmp/out" ||
    fail "expected a warning final outcome for incomplete reconciliation"
! grep -q "DONE: GitHub Project is ready" "$tmp/out" ||
    fail "incomplete reconciliation claimed the project was ready"

echo "==> a field at the option cap warns instead of attempting an oversized write"
capped=$(printf '%s' "$complete" | jq -c '
    .data.node.fields.nodes |= map(
        if .name == "Priority" then
            .options = ([ .options[] | select(.name != "Low") ]
                + [ range(0; 47) | {id: "x\(.)", name: "custom\(.)", color: "GRAY", description: ""} ])
        else . end)')
run_with "$capped"
[ "$(updates)" = 0 ] || fail "an over-capacity append must be skipped, not attempted"
grep -q "cannot fit Low" "$tmp/out" || fail "expected a capacity warning naming the missing option"
grep -q "WARN: GitHub Project needs attention" "$tmp/out" ||
    fail "expected a warning final outcome at the option cap"

echo "==> a field deleted during reconciliation cannot produce a ready outcome"
without_status=$(printf '%s' "$complete" | jq -c '
    .data.node.fields.nodes |= map(select(.name != "Status"))')
run_with "$complete" "$without_status"
grep -q "field 'Status' disappeared" "$tmp/out" || fail "expected a concurrent-disappearance warning"
grep -q "WARN: GitHub Project needs attention" "$tmp/out" ||
    fail "expected a warning final outcome after a field disappeared"
! grep -q "DONE: GitHub Project is ready" "$tmp/out" ||
    fail "a skipped field reconciliation claimed the project was ready"

echo "==> an option added after the startup snapshot survives the append"
# The re-read immediately before the write is what saves it: the replacement is
# built from the fresh list, not the stale one.
concurrent=$(printf '%s' "$partial" | jq -c '
    .data.node.fields.nodes |= map(
        if .name == "Priority" then
            .options += [{id: "p42", name: "raced-in", color: "BLUE", description: "added concurrently"}]
        else . end)')
run_with "$partial" "$concurrent"
mut=$(cat "$MUTATIONS")
case "$mut" in
*'name:"raced-in"'*) : ;;
*) fail "an option added between the snapshot and the write was deleted — the pre-write re-read is missing" ;;
esac

# ── Scope preflight ─────────────────────────────────────────────────────────
# Without the 'project' scope the run fails either way — `gh api graphql` exits
# non-zero on INSUFFICIENT_SCOPES and `set -e` takes the script with it. What is
# being tested is that it fails BEFORE any API call and says what to do about
# it, instead of surfacing a raw GraphQL error that names neither.

# run_expecting_scope_failure SCOPES — run with that scope list, require a
# non-zero exit, and echo the output.
run_expecting_scope_failure() {
    printf '%s' "$complete" >"$STUB_FIELDS_FILE"
    : >"$STUB_FIELDS_FILE2"
    rm -f "$tmp_seen"
    : >"$MUTATIONS"
    if STUB_SCOPES="$1" "$script" --owner someuser --title "Test Project" \
        >"$tmp/out" 2>&1; then
        fail "a token with scopes '$1' must not be accepted for board writes"
    fi
    cat "$tmp/out"
}

echo "==> a token without the project scope is refused, naming the remedy"
out=$(run_expecting_scope_failure "'gist', 'read:org', 'repo'")
case "$out" in
*"gh auth refresh -s project"*) ;;
*) fail "expected the refusal to name the remedy, got: $out" ;;
esac
[ "$(updates)" = 0 ] || fail "the preflight must refuse before any mutation"
case "$out" in
*"Resolving owner"*) fail "the preflight must refuse before the first API call" ;;
esac

echo "==> read-only 'read:project' is refused too — writes need the full scope"
# Easy to mistake for sufficient: it reads a board perfectly well, and every
# write below still fails.
out=$(run_expecting_scope_failure "'gist', 'read:project', 'repo'")
case "$out" in
*"gh auth refresh -s project"*) ;;
*) fail "read:project must be refused for writes, got: $out" ;;
esac

echo "==> a fine-grained/App token is NOT refused — its access is a permission"
# It reports no OAuth scopes at all, which is not the same as lacking one: such a
# token may well be able to write Projects, and `gh auth refresh` cannot change
# it either way. Refusing here would block a capable credential.
printf '%s' "$complete" >"$STUB_FIELDS_FILE"
: >"$STUB_FIELDS_FILE2"
rm -f "$tmp_seen"
: >"$MUTATIONS"
STUB_SCOPES="none" "$script" --owner someuser --title "Test Project" \
    >"$tmp/out" 2>&1 || fail "a token reporting no OAuth scopes must not be refused"
grep -q "no OAuth scopes" "$tmp/out" ||
    fail "expected the fine-grained-token notice, got: $(cat "$tmp/out")"
grep -q "gh auth refresh" "$tmp/out" &&
    fail "gh auth refresh cannot fix a fine-grained token"

echo "==> a token WITH the project scope reconciles normally"
printf '%s' "$complete" >"$STUB_FIELDS_FILE"
: >"$STUB_FIELDS_FILE2"
rm -f "$tmp_seen"
: >"$MUTATIONS"
STUB_SCOPES="'gist', 'project', 'repo'" "$script" --owner someuser \
    --title "Test Project" >"$tmp/out" 2>&1 ||
    fail "a token with the project scope must be accepted"
[ "$(updates)" = 0 ] || fail "an already-synced project should still write nothing"

echo "PASS: setup-github-project.sh field reconciliation"
