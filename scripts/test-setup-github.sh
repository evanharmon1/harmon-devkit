#!/usr/bin/env bash
# Unit-test setup-github.sh against a stubbed gh; never touches GitHub.
set -euo pipefail
cd "$(dirname "$0")/.."

script="$PWD/scripts/setup-github.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
    # shell-robustness: ok — always exits, so its status is never read
    echo "TEST FAIL: $*" >&2
    [ -f "$tmp/out" ] && sed 's/^/    /' "$tmp/out" >&2
    exit 1
}

mkdir -p "$tmp/bin"
stub_calls="$tmp/calls"
cat >"$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${STUB_CALLS:?}"
case "$*" in
*"${GH_FAIL_MATCH:-__never__}"*) exit "${GH_FAIL_RC:-1}" ;;
esac
case "$*" in
*"collaborators/"*" --method PUT"*) printf '%s' "${GH_COLLAB_RESPONSE:-}" ;;
*"variable list --repo "*" --json name,value --jq "*)
    [ "${GH_VARIABLE_GET_RC:-0}" -eq 0 ] || exit "$GH_VARIABLE_GET_RC"
    variable_present="${GH_VARIABLE_PRESENT:-}"
    if [ -z "$variable_present" ]; then
        [ -n "${GH_VARIABLE_VALUE:-}" ] && variable_present=true || variable_present=false
    fi
    if [ "$variable_present" = true ]; then
        jq -cn --arg value "${GH_VARIABLE_VALUE:-}" '[{name:"CI_RUNS_ON",value:$value}]'
    else
        printf '[]\n'
    fi
    ;;
*"/permission --jq .permission")
    [ -n "${GH_PERMISSION:-}" ] || exit 1
    printf '%s\n' "$GH_PERMISSION"
    ;;
*" --jq .visibility")
    if [ -n "${GH_VISIBILITY:-}" ]; then
        printf '%s\n' "$GH_VISIBILITY"
    elif [ "${GH_PRIVATE:-true}" = true ]; then
        printf 'private\n'
    else
        printf 'public\n'
    fi
    ;;
esac
STUB
chmod +x "$tmp/bin/gh"

run_case() {
    : >"$stub_calls"
    set +e
    PATH="$tmp/bin:$PATH" STUB_CALLS="$stub_calls" NO_COLOR=1 \
        "$script" "$@" >"$tmp/out" 2>&1
    run_rc=$?
    set -e
}

echo "==> private repositories report success plus the reason for a skip"
GH_PRIVATE=true run_case --repo owner/private
[ "$run_rc" -eq 0 ] || fail "private path exited $run_rc"
grep -Fq '[x] Dependabot alerts - enabled' "$tmp/out" || fail "missing Dependabot success"
grep -Fq '[-] Private vulnerability reporting - skipped: private repository' "$tmp/out" || fail "missing private-repo skip reason"
grep -Fq 'DONE: GitHub repository settings are ready for owner/private' "$tmp/out" || fail "missing final outcome"
LC_ALL=C od -An -tu1 -v "$tmp/out" | awk '
    { for (i = 1; i <= NF; i++) if ($i != 9 && $i != 10 && $i != 13 && ($i < 32 || $i > 126)) exit 1 }
' || fail "plain setup output contains non-ASCII presentation bytes"
if grep -q 'private-vulnerability-reporting' "$stub_calls"; then
    fail "private repository attempted to enable public-only reporting"
fi

desired='["self-hosted","linux","x64","owner"]'

echo "==> missing private CI_RUNS_ON variables are created"
GH_PRIVATE=true GH_VARIABLE_VALUE= run_case --repo owner/private --ci-runs-on "$desired"
[ "$run_rc" -eq 0 ] || fail "missing-variable path exited $run_rc"
grep -Fq '[x] Actions runner routing - created CI_RUNS_ON' "$tmp/out" || fail "missing created routing outcome"
grep -Fq "api repos/owner/private/actions/variables --method POST -f name=CI_RUNS_ON -f value=$desired" "$stub_calls" ||
    fail "missing CI_RUNS_ON variable was not created"

echo "==> missing private CI_RUNS_ON creation fails closed on a concurrent create"
GH_PRIVATE=true GH_VARIABLE_VALUE= GH_FAIL_MATCH='actions/variables --method POST' GH_FAIL_RC=17 \
    run_case --repo owner/private --ci-runs-on "$desired"
[ "$run_rc" -eq 17 ] || fail "concurrent-create conflict exited $run_rc"
if grep -q 'variable set CI_RUNS_ON' "$stub_calls"; then
    fail "concurrent create fell back to an overwriting upsert"
fi

echo "==> an existing empty private CI_RUNS_ON is preserved instead of duplicate-created"
GH_PRIVATE=true GH_VARIABLE_PRESENT=true GH_VARIABLE_VALUE= \
    run_case --repo owner/private --ci-runs-on "$desired"
[ "$run_rc" -eq 0 ] || fail "empty existing private variable exited $run_rc"
grep -Fq '[-] Actions runner routing - preserved existing private CI_RUNS_ON' "$tmp/out" ||
    fail "empty existing private variable was not preserved"
if grep -q 'actions/variables --method POST\|variable set CI_RUNS_ON' "$stub_calls"; then
    fail "empty existing private variable was rewritten"
fi

echo "==> matching private CI_RUNS_ON variables are unchanged"
GH_PRIVATE=true GH_VARIABLE_VALUE="$desired" run_case --repo owner/private --ci-runs-on "$desired"
[ "$run_rc" -eq 0 ] || fail "matching-variable path exited $run_rc"
grep -Fq '[x] Actions runner routing - CI_RUNS_ON already matches' "$tmp/out" || fail "missing matching routing outcome"
if grep -q 'variable set CI_RUNS_ON' "$stub_calls"; then fail "matching CI_RUNS_ON was rewritten"; fi

echo "==> existing private self-hosted labels are preserved by default"
GH_PRIVATE=true GH_VARIABLE_VALUE='["self-hosted","linux"]' \
    run_case --repo owner/private --ci-runs-on "$desired"
[ "$run_rc" -eq 0 ] || fail "stale-variable path exited $run_rc"
grep -Fq '[-] Actions runner routing - preserved existing private CI_RUNS_ON' "$tmp/out" ||
    fail "missing conservative preserve outcome"
if grep -q 'variable set CI_RUNS_ON' "$stub_calls"; then fail "existing private routing was rewritten"; fi

echo "==> internal repositories preserve existing self-hosted routing"
GH_VISIBILITY=internal GH_VARIABLE_VALUE='["self-hosted","linux"]' \
    run_case --repo owner/internal --ci-runs-on "$desired"
[ "$run_rc" -eq 0 ] || fail "internal repository path exited $run_rc"
grep -Fq '[-] Actions runner routing - preserved existing internal CI_RUNS_ON' "$tmp/out" ||
    fail "internal runner routing was not preserved"
if grep -q 'variable set CI_RUNS_ON' "$stub_calls"; then fail "internal routing was rewritten"; fi

echo "==> explicit replace flag updates an existing private value"
GH_PRIVATE=true GH_VARIABLE_VALUE='["self-hosted","linux"]' \
    run_case --repo owner/private --ci-runs-on "$desired" --replace-ci-runs-on
[ "$run_rc" -eq 0 ] || fail "explicit replace path exited $run_rc"
grep -Fq '[x] Actions runner routing - replaced CI_RUNS_ON by explicit request' "$tmp/out" ||
    fail "missing explicit replace outcome"
grep -Fq "variable set CI_RUNS_ON --repo owner/private --body $desired" "$stub_calls" ||
    fail "explicit replace did not update CI_RUNS_ON"

echo "==> explicit private runner overrides are preserved"
GH_PRIVATE=true GH_VARIABLE_VALUE='"ubuntu-24.04-16core"' \
    run_case --repo owner/private --ci-runs-on "$desired"
[ "$run_rc" -eq 0 ] || fail "hosted-override path exited $run_rc"
grep -Fq '[-] Actions runner routing - preserved existing private CI_RUNS_ON' "$tmp/out" ||
    fail "missing preserved override outcome"
if grep -q 'variable set CI_RUNS_ON' "$stub_calls"; then fail "hosted override was rewritten"; fi

echo "==> private group and label runner objects are preserved"
GH_PRIVATE=true GH_VARIABLE_VALUE='{"group":"ubuntu-runners","labels":"ubuntu-24.04-16core"}' \
    run_case --repo owner/private --ci-runs-on "$desired"
[ "$run_rc" -eq 0 ] || fail "runner-object path exited $run_rc"
grep -Fq '[-] Actions runner routing - preserved existing private CI_RUNS_ON' "$tmp/out" ||
    fail "missing preserved runner-object outcome"
if grep -q 'variable set CI_RUNS_ON' "$stub_calls"; then fail "runner object was rewritten"; fi

echo "==> private multi-label runner arrays are preserved"
GH_PRIVATE=true GH_VARIABLE_VALUE='["ubuntu-latest","windows-latest"]' \
    run_case --repo owner/private --ci-runs-on "$desired"
[ "$run_rc" -eq 0 ] || fail "multi-label runner array exited $run_rc"
grep -Fq '[-] Actions runner routing - preserved existing private CI_RUNS_ON' "$tmp/out" ||
    fail "multi-label runner array was not preserved"
if grep -q 'variable set CI_RUNS_ON' "$stub_calls"; then fail "multi-label hosted array was rewritten"; fi

echo "==> private scalar runner labels are preserved as explicit overrides"
GH_PRIVATE=true GH_VARIABLE_VALUE='"self-hosted"' \
    run_case --repo owner/private --ci-runs-on '"ubuntu-latest"'
[ "$run_rc" -eq 0 ] || fail "explicit-scalar path exited $run_rc"
grep -Fq '[-] Actions runner routing - preserved existing private CI_RUNS_ON' "$tmp/out" ||
    fail "explicit scalar was not preserved"
if grep -q 'variable set CI_RUNS_ON' "$stub_calls"; then fail "ambiguous scalar was rewritten"; fi

echo "==> changing template answers does not replace existing private routing implicitly"
GH_PRIVATE=true GH_VARIABLE_VALUE="$desired" \
    run_case --repo owner/private --ci-runs-on '"ubuntu-latest"'
[ "$run_rc" -eq 0 ] || fail "hosted transition exited $run_rc"
grep -Fq '[-] Actions runner routing - preserved existing private CI_RUNS_ON' "$tmp/out" ||
    fail "template answer change did not preserve existing routing"
if grep -q 'variable set CI_RUNS_ON' "$stub_calls"; then fail "template answer change rewrote private routing"; fi

echo "==> explicit replace can switch an existing private route to GitHub-hosted"
GH_PRIVATE=true GH_VARIABLE_VALUE="$desired" \
    run_case --repo owner/private --ci-runs-on '"ubuntu-latest"' --replace-ci-runs-on
[ "$run_rc" -eq 0 ] || fail "explicit hosted transition exited $run_rc"
grep -Fq 'variable set CI_RUNS_ON --repo owner/private --body "ubuntu-latest"' "$stub_calls" ||
    fail "explicit hosted transition did not replace private routing"

echo "==> unrecognized existing private JSON is preserved without ownership inference"
GH_PRIVATE=true GH_VARIABLE_VALUE='{"custom":"runner-contract"}' \
    run_case --repo owner/private --ci-runs-on "$desired"
[ "$run_rc" -eq 0 ] || fail "custom existing value exited $run_rc"
grep -Fq '[-] Actions runner routing - preserved existing private CI_RUNS_ON' "$tmp/out" ||
    fail "custom existing private value was not preserved"
if grep -q 'variable set CI_RUNS_ON' "$stub_calls"; then fail "custom existing private value was rewritten"; fi

echo "==> variable lookup failures stop before a write"
GH_PRIVATE=true GH_VARIABLE_GET_RC=23 run_case --repo owner/private --ci-runs-on "$desired"
[ "$run_rc" -eq 23 ] || fail "variable lookup exit 23 became $run_rc"
grep -Fq '[ ] Actions runner routing - could not list repository variables (exit 23)' "$tmp/out" ||
    fail "missing variable-lookup failure"
if grep -q 'variable set CI_RUNS_ON' "$stub_calls"; then fail "lookup failure attempted a write"; fi

echo "==> malformed runner JSON is rejected before GitHub access"
GH_PRIVATE=true run_case --repo owner/private --ci-runs-on 'not-json "self-hosted"'
[ "$run_rc" -eq 2 ] || fail "malformed runner JSON exited $run_rc"
if [ -s "$stub_calls" ]; then fail "malformed runner JSON reached GitHub"; fi

echo "==> multiple JSON documents are rejected before GitHub access"
GH_PRIVATE=true run_case --repo owner/private --ci-runs-on '42 "ubuntu-latest"'
[ "$run_rc" -eq 2 ] || fail "multiple JSON documents exited $run_rc"
if [ -s "$stub_calls" ]; then fail "multiple JSON documents reached GitHub"; fi

echo "==> empty self-hosted labels are rejected before GitHub access"
GH_PRIVATE=true run_case --repo owner/private --ci-runs-on '["self-hosted",""]'
[ "$run_rc" -eq 2 ] || fail "empty runner label exited $run_rc"
if [ -s "$stub_calls" ]; then fail "empty runner label reached GitHub"; fi

echo "==> an explicitly empty runner value is rejected before GitHub access"
GH_PRIVATE=true run_case --repo owner/private --ci-runs-on ''
[ "$run_rc" -eq 2 ] || fail "explicitly empty runner value exited $run_rc"
grep -Fq -- '--ci-runs-on requires a non-empty value' "$tmp/out" ||
    fail "explicitly empty runner value did not name the invalid option"
if [ -s "$stub_calls" ]; then fail "explicitly empty runner value reached GitHub"; fi

echo "==> replace flag requires an explicit desired value"
GH_PRIVATE=true run_case --repo owner/private --replace-ci-runs-on
[ "$run_rc" -eq 2 ] || fail "replace-without-value exited $run_rc"
if [ -s "$stub_calls" ]; then fail "replace-without-value reached GitHub"; fi

echo "==> public repositories force self-hosted selections to GitHub-hosted routing"
GH_PRIVATE=false run_case --repo owner/public --ci-runs-on "$desired"
[ "$run_rc" -eq 0 ] || fail "public self-hosted path exited $run_rc"
grep -Fq '[?] Actions runner routing - public repository selected non-canonical routing; enforcing ubuntu-latest' "$tmp/out" ||
    fail "missing public-repo safety override explanation"
grep -Fq 'api repos/owner/public/actions/variables --method POST -f name=CI_RUNS_ON -f value="ubuntu-latest"' "$stub_calls" ||
    fail "public repo did not receive a GitHub-hosted safety override"

echo "==> an existing empty public CI_RUNS_ON is repaired instead of duplicate-created"
GH_PRIVATE=false GH_VARIABLE_PRESENT=true GH_VARIABLE_VALUE= \
    run_case --repo owner/public --ci-runs-on '"ubuntu-latest"'
[ "$run_rc" -eq 0 ] || fail "empty existing public variable exited $run_rc"
grep -Fq '[x] Actions runner routing - standardized public CI_RUNS_ON to ubuntu-latest' "$tmp/out" ||
    fail "empty existing public variable was not repaired"
grep -Fq 'variable set CI_RUNS_ON --repo owner/public --body "ubuntu-latest"' "$stub_calls" ||
    fail "empty existing public variable was not updated"
if grep -q 'actions/variables --method POST' "$stub_calls"; then
    fail "empty existing public variable was duplicate-created"
fi

echo "==> public repositories replace ambiguous self-hosted scalar routing"
GH_PRIVATE=false GH_VARIABLE_VALUE='"self-hosted"' \
    run_case --repo owner/public --ci-runs-on '"ubuntu-latest"'
[ "$run_rc" -eq 0 ] || fail "public ambiguous self-hosted path exited $run_rc"
grep -Fq '[x] Actions runner routing - standardized public CI_RUNS_ON to ubuntu-latest' "$tmp/out" ||
    fail "public ambiguous self-hosted routing was not explained"
grep -Fq 'variable set CI_RUNS_ON --repo owner/public --body "ubuntu-latest"' "$stub_calls" ||
    fail "public ambiguous self-hosted routing was not replaced"

echo "==> public repositories do not infer hosted ownership from a custom label prefix"
GH_PRIVATE=false GH_VARIABLE_VALUE='"ubuntu-owner-runner"' \
    run_case --repo owner/public --ci-runs-on '"ubuntu-latest"'
[ "$run_rc" -eq 0 ] || fail "public custom-label path exited $run_rc"
grep -Fq 'variable set CI_RUNS_ON --repo owner/public --body "ubuntu-latest"' "$stub_calls" ||
    fail "custom self-hosted-looking label was mistaken for GitHub-hosted"

echo "==> public larger-runner labels are canonicalized without ownership inference"
GH_PRIVATE=false GH_VARIABLE_VALUE='"ubuntu-24.04-16core"' \
    run_case --repo owner/public --ci-runs-on '"ubuntu-latest"'
[ "$run_rc" -eq 0 ] || fail "public larger-runner path exited $run_rc"
grep -Fq 'variable set CI_RUNS_ON --repo owner/public --body "ubuntu-latest"' "$stub_calls" ||
    fail "public larger-runner label was not canonicalized"

echo "==> public runner safety is written before unrelated settings can fail"
GH_PRIVATE=false GH_VARIABLE_VALUE='["self-hosted","linux"]' \
    GH_FAIL_MATCH=vulnerability-alerts GH_FAIL_RC=23 \
    run_case --repo owner/public --ci-runs-on '"ubuntu-latest"'
[ "$run_rc" -eq 23 ] || fail "post-routing failure exited $run_rc"
grep -Fq 'variable set CI_RUNS_ON --repo owner/public --body "ubuntu-latest"' "$stub_calls" ||
    fail "public routing was not repaired before the unrelated failure"
set_line="$(grep -n 'variable set CI_RUNS_ON' "$stub_calls" | cut -d: -f1)"
fail_line="$(grep -n 'vulnerability-alerts' "$stub_calls" | cut -d: -f1)"
[ "$set_line" -lt "$fail_line" ] || fail "public routing ran after the fallible setting"

echo "==> public repositories enable every requested setting and collaborator"
GH_PRIVATE=false GH_PERMISSION=write GH_VARIABLE_VALUE= \
    run_case --repo owner/public --ci-runs-on '"ubuntu-latest"' --bot-collaborator owner-bot
[ "$run_rc" -eq 0 ] || fail "public path exited $run_rc"
grep -Fq '[x] Private vulnerability reporting - enabled' "$tmp/out" || fail "missing reporting success"
grep -Fq '[x] Bot collaborator - owner-bot has write access' "$tmp/out" || fail "missing collaborator success"
grep -q 'private-vulnerability-reporting --method PUT' "$stub_calls" || fail "reporting API was not called"
grep -q 'collaborators/owner-bot --method PUT -f permission=push' "$stub_calls" || fail "collaborator API was not called"
grep -q 'collaborators/owner-bot/permission --jq .permission' "$stub_calls" || fail "collaborator access was not verified"
grep -Fq 'api repos/owner/public/actions/variables --method POST -f name=CI_RUNS_ON -f value="ubuntu-latest"' "$stub_calls" ||
    fail "public repository did not receive explicit GitHub-hosted routing"

echo "==> a new collaborator invitation is reported as pending until accepted"
GH_PRIVATE=false GH_COLLAB_RESPONSE='{"id":42,"invitee":{"login":"owner-bot"}}' \
    run_case --repo owner/public --bot-collaborator owner-bot
[ "$run_rc" -eq 0 ] || fail "pending invitation path exited $run_rc"
grep -Fq '[?] Bot collaborator - invitation sent to owner-bot; access starts after acceptance' "$tmp/out" ||
    fail "missing pending-invitation outcome"
grep -Fq 'WARN: GitHub repository settings are ready; bot collaborator acceptance is pending' "$tmp/out" ||
    fail "missing pending-invitation summary"
if grep -q 'owner-bot has write access' "$tmp/out"; then
    fail "pending invitation falsely claimed active push access"
fi

echo "==> a failed permission lookup is unknown, never mislabeled as an invitation"
GH_PRIVATE=false GH_COLLAB_RESPONSE= GH_PERMISSION= \
    run_case --repo owner/public --bot-collaborator owner-bot
[ "$run_rc" -eq 0 ] || fail "unverified collaborator path exited $run_rc"
grep -Fq '[?] Bot collaborator - GitHub accepted the request, but permission verification failed' "$tmp/out" ||
    fail "missing unverified-permission outcome"
grep -Fq 'WARN: GitHub repository settings changed, but collaborator access needs verification' "$tmp/out" ||
    fail "missing unverified-permission summary"
if grep -q 'invitation sent' "$tmp/out"; then
    fail "permission lookup failure was mislabeled as a confirmed invitation"
fi

grep -Fq 'SUMMARY: Repository setup - succeeded=' "$tmp/out" ||
    fail "missing compact repository outcome summary"

echo "==> failures are formatted, preserve status, and never claim completion"
GH_PRIVATE=false GH_FAIL_MATCH=vulnerability-alerts GH_FAIL_RC=23 \
    run_case --repo owner/failing
[ "$run_rc" -eq 23 ] || fail "API exit 23 became $run_rc"
grep -Fq '[ ] Dependabot alerts - GitHub API request failed (exit 23)' "$tmp/out" || fail "missing formatted failure"
if grep -q 'DONE:' "$tmp/out"; then fail "failed run printed a completion summary"; fi
if grep -q 'private-vulnerability-reporting' "$stub_calls"; then
    fail "script continued mutating after the first failure"
fi

echo "PASS: setup-github outcomes and failure propagation"
