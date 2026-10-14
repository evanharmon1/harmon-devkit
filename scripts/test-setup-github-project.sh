#!/usr/bin/env bash
# test-setup-github-project.sh — unit-test setup-github-project.sh's field
# reconciliation against a stubbed `gh`; no live API calls, so it is safe in CI.
# Run via `task test:setup-github-project`.
#
# The invariant worth a test: `updateProjectV2Field` REPLACES the whole
# singleSelectOptions array, and per GitHub's schema an existing option re-sent
# WITHOUT its `id` is destroyed and recreated — silently blanking that field on
# every board item already assigned to it. Appending is therefore only safe while
# every pre-existing option goes back with its id. This test, run directly and
# through test-template.sh for the full and minimal profiles, guards that
# option-id contract against a stubbed `gh`; the live-API path is not exercised.
# A future edit that drops the ids would otherwise lose data on the next re-run.
set -euo pipefail
cd "$(dirname "$0")/.."
script="$PWD/scripts/setup-github-project.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
    # shell-robustness: ok — always exits, so its status is never read
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
*projectsV2*)
    if [ "${STUB_NEW_PROJECT:-0}" = 1 ]; then
        echo '{"data":{"repositoryOwner":{"projectsV2":{"pageInfo":{"hasNextPage":false},"nodes":[]}}}}'
    else
        echo '{"data":{"repositoryOwner":{"projectsV2":{"pageInfo":{"hasNextPage":false},"nodes":[{"id":"P_1","number":7,"title":"Test Project"}]}}}}'
    fi
    ;;
*createProjectV2\(*)
    printf '%s\n' "$q" >>"$MUTATIONS"
    echo '{"data":{"createProjectV2":{"projectV2":{"id":"P_1","number":7}}}}'
    ;;
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
STUB_NEW_PROJECT=0
export STUB_NEW_PROJECT

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
 {"id":"F_prod","name":"Product","dataType":"TEXT"}
]}}}}'

# The same board as it looked before harmon-init#1451: Priority and Size were project fields
# then, and a board set up by an older release still carries them. Priority lacks
# options its old starter set had and carries an owner-added `Critical`.
legacy=$(printf '%s' "$complete" | jq -c '
    .data.node.fields.nodes += [
        {"id":"F_size","name":"Size","dataType":"NUMBER"},
        {"id":"F_pri","name":"Priority","dataType":"SINGLE_SELECT","options":[
            {"id":"p1","name":"Urgent","color":"RED","description":""},
            {"id":"p9","name":"Critical","color":"PINK","description":"owner added"}]}]')

# run_expecting_snapshot_failure FIELDS — a malformed/errored snapshot is
# UNKNOWN, never evidence that every expected field is absent. Require a loud
# refusal before any field mutation.
run_expecting_snapshot_failure() {
    printf '%s' "$1" >"$STUB_FIELDS_FILE"
    : >"$STUB_FIELDS_FILE2"
    rm -f "$tmp_seen"
    : >"$MUTATIONS"
    if "$script" --owner someuser --title "Test Project" >"$tmp/out" 2>&1; then
        fail "an invalid project-field snapshot was accepted"
    fi
    grep -q "snapshot was malformed or contained GraphQL errors" "$tmp/out" ||
        fail "the invalid snapshot refusal did not explain the parse/GraphQL failure"
    [ ! -s "$MUTATIONS" ] ||
        fail "an invalid project-field snapshot reached a field mutation"
}

echo "==> malformed field JSON fails closed before field creation"
run_expecting_snapshot_failure '{"data":{"node":{"fields":{"nodes":'

echo "==> HTTP-200 GraphQL errors fail closed before field creation"
run_expecting_snapshot_failure \
    '{"errors":[{"message":"partial field failure"}],"data":{"node":{"fields":{"nodes":[]}}}}'

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

echo "==> a run creates none of the retired Agent, Domain, Layer, Priority, or Size fields, on either owner type"
# Priority is an issue field on an organization and a priority:* label on a
# personal account; Size is retired (harmon-init#1451); Agent is retired too — the live
# claim is a claim:* label (ADR 2026-08-07 D4). Domain and Layer are label-only
# taxonomies, not project fields (harmon-init#875). The board below is missing
# Product as well, so a personal-account run provably does write — it creates
# Product, the one field it still owns — and the assertions are about everything
# else. The fixture has no Agent, Domain, or Layer field, so any mutation naming one
# is the script recreating it; reading it from a personal-account run is what
# makes the check able to fail (an organization run exits before any field is
# created).
bare=$(printf '%s' "$complete" | jq -c '
    .data.node.fields.nodes |= map(select(.name != "Product"))')
for owner_type in User Organization; do
    STUB_OWNER_TYPE=$owner_type
    run_with "$bare"
    mut=$(cat "$MUTATIONS")
    case "$mut" in
    *'name:"Agent"'*) fail "a $owner_type run created the retired Agent project field" ;;
    *'name:"Domain"'*) fail "a $owner_type run created the retired Domain project field" ;;
    *'name:"Layer"'*) fail "a $owner_type run created the retired Layer project field" ;;
    *'name:"Priority"'*) fail "a $owner_type run created the retired Priority project field" ;;
    *'name:"Size"'*) fail "a $owner_type run created the retired Size project field" ;;
    *'dataType:NUMBER'*) fail "a $owner_type run created a number field — Size was the only one" ;;
    esac
    if [ "$owner_type" = User ]; then
        case "$mut" in
        *'dataType:TEXT,name:"Product"'*) : ;;
        *) fail "a personal-account run should still create the Product text field" ;;
        esac
        [ "$(grep -c createProjectV2Field "$MUTATIONS")" = 1 ] ||
            fail "a personal-account run should create exactly 1 field (Product), got $(grep -c createProjectV2Field "$MUTATIONS")"
    else
        [ ! -s "$MUTATIONS" ] || fail "an organization run reconciles Status only; it wrote: $mut"
    fi
done
STUB_OWNER_TYPE=User

echo "==> a new personal-account project creates none of the retired fields"
STUB_NEW_PROJECT=1
run_with "$bare"
STUB_NEW_PROJECT=0
mut=$(cat "$MUTATIONS")
grep -q 'Created project #7' "$tmp/out" || fail "expected the new-project path"
case "$mut" in
*'name:"Agent"'*) fail "a new personal-account project created the retired Agent project field" ;;
*'name:"Domain"'*) fail "a new personal-account project created the retired Domain project field" ;;
*'name:"Layer"'*) fail "a new personal-account project created the retired Layer project field" ;;
*'name:"Priority"'*) fail "a new personal-account project created the retired Priority project field" ;;
*'name:"Size"'*) fail "a new personal-account project created the retired Size project field" ;;
*'dataType:NUMBER'*) fail "a new personal-account project created a number field — Size was the only one" ;;
esac
case "$mut" in
*'dataType:TEXT,name:"Product"'*) : ;;
*) fail "a new personal-account project should create the Product text field" ;;
esac
[ "$(grep -c createProjectV2Field "$MUTATIONS")" = 1 ] ||
    fail "a new personal-account project should create exactly 1 field (Product), got $(grep -c createProjectV2Field "$MUTATIONS")"

echo "==> a board that still carries Priority and Size is left exactly as it is"
# Reconciling is additive and the script never deletes: an existing Priority is no
# longer appended to, resized, or warned about, and neither is an existing Size.
# Deleting them is the operator's step (docs/CHECKLIST.md). A wrong-typed one is
# the sharper probe — it would have been an `incompatible` warning before.
legacy_wrong=$(printf '%s' "$legacy" | jq -c '
    .data.node.fields.nodes |= map(
        if .name == "Priority" or .name == "Size" then {id: .id, name: .name, dataType: "TEXT"} else . end)')
for owner_type in User Organization; do
    STUB_OWNER_TYPE=$owner_type
    for board in "$legacy" "$legacy_wrong"; do
        run_with "$board"
        [ ! -s "$MUTATIONS" ] || fail "a $owner_type run mutated a board that only carries the retired fields: $(cat "$MUTATIONS")"
        ! grep -Eq "[Ff]ield '(Priority|Size)'|(Priority|Size) \(is " "$tmp/out" ||
            fail "a $owner_type run reported on a retired field it no longer manages"
        grep -q "DONE: GitHub Project is ready" "$tmp/out" ||
            fail "a $owner_type run did not finish ready over a board carrying retired fields"
    done
done
STUB_OWNER_TYPE=User

echo "==> a field missing a starter option gains ONLY that option"
# Status lacks `Accepted` and carries an owner-added `Blocked`.
partial=$(printf '%s' "$complete" | jq -c '
    .data.node.fields.nodes |= map(
        if .name == "Status" then
            .options = [ .options[] | if .name == "Accepted"
                then {id: "s99", name: "Blocked", color: "PINK", description: "owner added"}
                else . end ]
        else . end)')
run_with "$partial"
[ "$(updates)" = 1 ] || fail "expected exactly 1 update mutation, got $(updates)"
mut=$(cat "$MUTATIONS")
case "$mut" in
*'{name:"Accepted"'*) : ;;
*) fail "the appended option should be sent WITHOUT an id" ;;
esac

echo "==> every pre-existing option is re-sent WITH its id (identity preserved)"
for pair in 's1:Inbox' 's99:Blocked' 's3:Next'; do
    case "$mut" in
    *"{id:\"${pair%%:*}\",name:\"${pair##*:}\""*) : ;;
    *) fail "existing option '${pair##*:}' lost its id '${pair%%:*}' — item values would be cleared" ;;
    esac
done

echo "==> an owner-added option survives the append"
case "$mut" in
*'name:"Blocked"'*) : ;;
*) fail "owner-added option 'Blocked' was dropped from the replacement list" ;;
esac

echo "==> a field of the wrong data type is warned about, never created over"
# Product is the one custom field left, and a text field has no options to append
# to — so the guard here is create_text's: warn, report it in the end-of-run
# summary, and write nothing (a second Product would shadow the owner's).
wrong=$(printf '%s' "$complete" | jq -c '
    .data.node.fields.nodes |= map(
        if .name == "Product" then {id: .id, name: .name, dataType: "NUMBER"} else . end)')
run_with "$wrong"
[ ! -s "$MUTATIONS" ] || fail "a wrong-typed field must be neither updated nor re-created: $(cat "$MUTATIONS")"
grep -q "already exists as NUMBER" "$tmp/out" || fail "expected a data-type warning for Product"
grep -q "Product (is NUMBER, wanted TEXT)" "$tmp/out" ||
    fail "expected Product in the end-of-run incompatible summary"

echo "==> a non-single-select Status warns and is skipped, never aborting the run"
# Status is reconciled at its own call site, so
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
        if .name == "Status" then
            .options = ([ .options[] | select(.name != "Accepted") ]
                + [ range(0; 37) | {id: "x\(.)", name: "custom\(.)", color: "GRAY", description: ""} ])
        else . end)')
run_with "$capped"
[ "$(updates)" = 0 ] || fail "an over-capacity append must be skipped, not attempted"
grep -q "cannot fit Accepted" "$tmp/out" || fail "expected a capacity warning naming the missing option"
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
        if .name == "Status" then
            .options += [{id: "s42", name: "raced-in", color: "BLUE", description: "added concurrently"}]
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
