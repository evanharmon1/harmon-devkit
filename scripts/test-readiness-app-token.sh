#!/usr/bin/env bash
# Reuse the readiness suite's fixture builders without running its cases.
# Exercise the real gate, not a copied authentication function.
set -euo pipefail
app_test_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export APP_TEST_REPO_ROOT="$app_test_root"
# shellcheck disable=SC1090
source <(awk '
    /^echo / {exit}
    /^repo_root=/ {print "repo_root=\"$APP_TEST_REPO_ROOT\""; next}
    {print}
' "$app_test_root/scripts/test-integrate-readiness.sh")

mv "$bin_dir/gh" "$bin_dir/gh-fixture"
cat >"$bin_dir/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >>"$APP_ARGV_LOG"
case "$*" in
*'/check-runs?'* | *'/statuses?'*)
    [ "${GH_TOKEN:-}" = "$APP_TEST_TOKEN" ] || {
        echo 'gh: Resource not accessible by personal access token (HTTP 403)' >&2
        exit 1
    }
    [ "${GH_ENTERPRISE_TOKEN:-}" = "$APP_TEST_TOKEN" ] || exit 91
    printf 'app-read\n' >>"$APP_AUTH_LOG"
    ;;
*)
    [ "${GH_TOKEN:-}" != "$APP_TEST_TOKEN" ] || exit 92
    ;;
esac
exec "$(dirname "$0")/gh-fixture" "$@"
STUB
cat >"$bin_dir/app-token" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >>"$APP_ARGV_LOG"
[ "$#" -eq 1 ] && [ "$1" = example/repo ] || exit 1
printf 'mint\n' >>"$APP_AUTH_LOG"
printf '%s\n' "$APP_TEST_TOKEN"
STUB
chmod +x "$bin_dir/gh" "$bin_dir/app-token"
export APP_ARGV_LOG="$test_tmp/app-argv.log" APP_AUTH_LOG="$test_tmp/app-auth.log"
export APP_TEST_TOKEN=installation-token-fixture APP_TEST_PRIVATE_KEY=private-key-fixture
: >"$APP_ARGV_LOG"
: >"$APP_AUTH_LOG"
unset READINESS_APP_TOKEN_HELPER
write_defaults
run_gate
assert_gate 2 indeterminate fetch-failed
[[ "$gate_out" = *'cannot fetch check runs'* ]] || fail "PAT 403 must fail check-run read"

export READINESS_APP_TOKEN_HELPER="$bin_dir/app-token"
write_defaults
run_gate
assert_gate 0 pass ready
awk '
    NR % 2 == 1 && $0 != "mint" {exit 1}
    NR % 2 == 0 && $0 != "app-read" {exit 1}
    END {if (NR < 4 || NR % 2 != 0) exit 1}
' "$APP_AUTH_LOG" || fail "every CI read must immediately follow a fresh mint"

# A configured helper failure cannot fall back to the PAT.
cat >"$bin_dir/app-token" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$APP_TEST_PRIVATE_KEY" >&2
exit 1
STUB
write_defaults
run_gate
assert_gate 2 indeterminate fetch-failed
for secret in "$APP_TEST_TOKEN" "$APP_TEST_PRIVATE_KEY"; do
    ! grep -Fq "$secret" "$APP_ARGV_LOG" || fail "secret appeared in argv"
    [[ "$gate_out" != *"$secret"* ]] || fail "secret appeared in gate output"
done
echo 'PASS: readiness App authentication, PAT 403, helper failure and secret argv'
