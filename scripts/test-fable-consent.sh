#!/usr/bin/env bash
# test-fable-consent.sh — check the Fable 5 usage-credit consent hook.
# Run via `task test:fable-consent`.
#
# The hook writes a BILLING authorization (.fableOverageConsentV2 records that
# Fable 5 may draw on usage credits past plan limits) into Claude Code's shared
# state file, from an image-baked script that postStart and a `claude` shell
# wrapper both invoke for whichever account is signed in. Three properties
# therefore have to hold, and none of them is visible by reading the diff:
#
#   * the opt-in gate fails CLOSED — anything but the exact string "true"
#     writes nothing, so a checkout never grants consent for someone's account;
#   * the key matches what Claude Code actually reads (organizationUuid first,
#     "acct:<accountUuid>" only as a fallback) — seed the wrong one and Fable
#     stays locked while the file looks correct;
#   * every other byte of .claude.json survives — the file holds the OAuth
#     account, onboarding state, and settings, so clobbering it to record one
#     boolean would be a far worse bug than the one being fixed.
set -euo pipefail

repo="$(git rev-parse --show-toplevel)"
cd "$repo"

hook="$repo/.devcontainer/config/claude-hooks/seed-fable-consent.sh"
[ -x "$hook" ] || {
    echo "TEST FAIL: $hook is missing or not executable" >&2
    exit 1
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

fail() {
    echo "TEST FAIL: $*" >&2
    exit 1
}

# run GATE BODY -> writes $tmpdir/claude.json, runs the hook, echoes its exit
# code. The hook must never exit non-zero: it runs in front of every `claude`
# launch and on every container start, so a non-zero exit would break the thing
# it is trying to help.
run() {
    printf '%s' "$2" >"$tmpdir/claude.json"
    _rc=0
    env DEVCONTAINER_FABLE_CONSENT="$1" CLAUDE_JSON="$tmpdir/claude.json" \
        "$hook" --verbose >/dev/null 2>&1 || _rc=$?
    [ "$_rc" -eq 0 ] || fail "hook exited $_rc; it must always exit 0"
    echo "$_rc"
}

consent() { jq -c '.fableOverageConsentV2 // "absent"' "$tmpdir/claude.json"; }

account='{"oauthAccount":{"organizationUuid":"org-1","accountUuid":"acct-1"}}'

# --- the gate ---------------------------------------------------------------
# Fails closed on every value but the exact "true". A loose test (`[ -n ... ]`,
# a case-insensitive match, or truthiness) would let a stray "false" or "0"
# grant a billing consent nobody asked for.
echo "==> an unset gate writes nothing"
run "" "$account" >/dev/null
[ "$(consent)" = '"absent"' ] || fail "unset gate recorded consent"

for value in false FALSE True TRUE 1 yes ""; do
    echo "==> the gate rejects '${value}'"
    run "$value" "$account" >/dev/null
    [ "$(consent)" = '"absent"' ] ||
        fail "gate value '${value}' recorded consent; only exact 'true' may"
done

echo "==> the exact string true opts in"
run true "$account" >/dev/null
[ "$(consent)" = '{"org-1":true}' ] || fail "opted-in run did not record consent"

# --- key derivation ---------------------------------------------------------
echo "==> organizationUuid wins over accountUuid"
# Claude Code resolves the org UUID first and reads only that key, so seeding
# the acct: form alongside a present org would leave Fable locked.
run true "$account" >/dev/null
[ "$(consent)" = '{"org-1":true}' ] ||
    fail "expected the org key alone, got $(consent)"

echo "==> accountUuid is the fallback when there is no organizationUuid"
run true '{"oauthAccount":{"accountUuid":"acct-9"}}' >/dev/null
[ "$(consent)" = '{"acct:acct-9":true}' ] ||
    fail "expected the acct: fallback key, got $(consent)"

# --- no account yet ---------------------------------------------------------
echo "==> a fresh volume with no oauthAccount writes nothing"
# postStart runs before any login on a fresh volume. This must no-op rather
# than invent a key — the `claude` wrapper covers it once an account exists.
run true '{"hasCompletedOnboarding":true}' >/dev/null
[ "$(consent)" = '"absent"' ] || fail "recorded consent with no account present"

# --- preservation -----------------------------------------------------------
echo "==> consent already recorded is left alone"
run true '{"oauthAccount":{"organizationUuid":"org-1"},"fableOverageConsentV2":{"org-1":true}}' >/dev/null
[ "$(consent)" = '{"org-1":true}' ] || fail "idempotent run altered the record"

echo "==> another account's consent survives"
run true '{"oauthAccount":{"organizationUuid":"org-2"},"fableOverageConsentV2":{"org-1":true}}' >/dev/null
[ "$(consent)" = '{"org-1":true,"org-2":true}' ] ||
    fail "seeding org-2 dropped org-1, got $(consent)"

echo "==> every other key in .claude.json survives"
run true '{"hasCompletedOnboarding":true,"remoteControlAtStartup":true,"numStartups":23,"oauthAccount":{"organizationUuid":"org-3"}}' >/dev/null
for key in hasCompletedOnboarding remoteControlAtStartup numStartups oauthAccount; do
    jq -e --arg k "$key" 'has($k)' "$tmpdir/claude.json" >/dev/null ||
        fail "the write dropped .$key from .claude.json"
done
[ "$(jq -r '.numStartups' "$tmpdir/claude.json")" = "23" ] ||
    fail "the write altered an unrelated value"

# --- hostile / degraded input -----------------------------------------------
echo "==> malformed JSON is left untouched"
run true 'not json at all' >/dev/null
[ "$(cat "$tmpdir/claude.json")" = "not json at all" ] ||
    fail "the hook rewrote a file it could not parse"

echo "==> a missing file is not an error"
_rc=0
env DEVCONTAINER_FABLE_CONSENT=true CLAUDE_JSON="$tmpdir/does-not-exist.json" \
    "$hook" --verbose >/dev/null 2>&1 || _rc=$?
[ "$_rc" -eq 0 ] || fail "a missing state file exited $_rc, expected 0"
[ ! -f "$tmpdir/does-not-exist.json" ] || fail "the hook created a state file"

# --- quietness ---------------------------------------------------------------
echo "==> the hook is silent without --verbose"
# It runs in front of every `claude` launch, so a success message without
# --verbose would print on launches that changed nothing.
printf '%s' '{"oauthAccount":{"organizationUuid":"org-q"}}' >"$tmpdir/claude.json"
out="$(env DEVCONTAINER_FABLE_CONSENT=true CLAUDE_JSON="$tmpdir/claude.json" \
    "$hook" 2>/dev/null)"
[ -z "$out" ] || fail "quiet mode printed to stdout: $out"
[ "$(consent)" = '{"org-q":true}' ] || fail "quiet mode did not write"

# --- atomicity ---------------------------------------------------------------
echo "==> the temp file is a sibling of the target, so the rename is atomic"
# A bare mktemp lands in $TMPDIR (tmpfs) while ~/.claude is a mounted volume,
# which turns `mv` into a cross-filesystem copy — non-atomic, and an
# interrupted run would leave a truncated .claude.json.
grep -q 'mktemp "${CLAUDE_JSON}\.XXXXXX"' "$hook" ||
    fail "the hook no longer creates its temp file beside CLAUDE_JSON"

echo "==> no temp files are left behind"
leftover="$(find "$tmpdir" -name 'claude.json.??????' -print -quit)"
[ -z "$leftover" ] || fail "left a temp file behind: $leftover"

# --- the PATH wrapper ---------------------------------------------------------
# /usr/local/bin/claude shadows the real CLI for EVERY process, including
# opted-out ones and agent-deck's out-of-process launches. A bug here breaks
# Claude Code itself, so its failure modes are pinned: it must pass through,
# never recurse, and fail loudly rather than hang.
wrapper="$repo/.devcontainer/config/claude-hooks/claude-wrapper.sh"
[ -x "$wrapper" ] || fail "$wrapper is missing or not executable"

wdir="$tmpdir/wrap"
mkdir -p "$wdir/first" "$wdir/realbin" "$wdir/tools" "$wdir/dup"
# ONLY bash. The wrapper must resolve copies without grep, head, readlink or
# stat: an earlier version piped head into grep, which fails open on a minimal
# PATH and let two copies exec each other forever.
ln -sf "$(command -v bash)" "$wdir/tools/bash"
sed "s|^SEEDER=.*|SEEDER=$wdir/seed.sh|" "$wrapper" >"$wdir/first/claude"
cp "$wdir/first/claude" "$wdir/dup/claude"
chmod +x "$wdir/first/claude" "$wdir/dup/claude"
printf '#!/usr/bin/env bash\necho SEEDED >>"%s/seed.log"\n' "$wdir" >"$wdir/seed.sh"
# The stub re-invokes `claude` the way Claude Code does for subagents and -p
# runs, so nesting is exercised on every happy-path case below.
printf '#!/usr/bin/env bash\necho "REAL $*"\n[ "${1:-}" = child ] || claude child\n' \
    >"$wdir/realbin/claude"
chmod +x "$wdir/seed.sh" "$wdir/realbin/claude"

wrun() {
    _p="$1"
    shift
    _gate="$1"
    shift
    _rc=0
    _out="$(timeout 10 env PATH="$_p" DEVCONTAINER_FABLE_CONSENT="$_gate" \
        "$wdir/first/claude" "$@" 2>&1)" || _rc=$?
    printf '%s\n' "$_out"
    return "$_rc"
}

full="$wdir/first:$wdir/realbin:$wdir/tools"

echo "==> the wrapper execs the real CLI and passes arguments through"
: >"$wdir/seed.log"
out="$(wrun "$full" "" hello world)" || fail "wrapper exited non-zero on the happy path"
case "$out" in "REAL hello world"*) ;; *) fail "wrapper did not pass through: $out" ;; esac

echo "==> the real CLI can spawn a nested claude through the wrapper"
# A recursion guard exported into the environment survives exec and breaks
# every nested launch. This pins that regression.
case "$out" in *"REAL child"*) ;; *) fail "nested claude did not run: $out" ;; esac

echo "==> opted out, the wrapper does not seed"
[ ! -s "$wdir/seed.log" ] || fail "wrapper seeded while opted out"

echo "==> opted in, the wrapper seeds before exec"
out="$(wrun "$full" true go)" || fail "wrapper exited non-zero when opted in"
case "$out" in "REAL go"*) ;; *) fail "wrapper did not exec the real CLI: $out" ;; esac
grep -q SEEDED "$wdir/seed.log" || fail "wrapper did not run the seeder"

echo "==> with no real CLI reachable it fails loudly, it does not loop"
_rc=0
wrun "$wdir/first:$wdir/tools" true orphan >/dev/null 2>&1 || _rc=$?
[ "$_rc" -eq 127 ] || fail "expected 127 with no real CLI, got $_rc (124 = hung)"

echo "==> a second wrapper copy on PATH is skipped, never exec-ed into a loop"
_rc=0
out="$(wrun "$wdir/first:$wdir/dup:$wdir/realbin:$wdir/tools" true twice)" || _rc=$?
[ "$_rc" -eq 0 ] || fail "expected the real CLI to be reached, got $_rc (124 = looped)"
case "$out" in "REAL twice"*) ;; *) fail "duplicate wrapper was not skipped: $out" ;; esac

echo "==> only wrapper copies reachable: 127, still no loop"
_rc=0
wrun "$wdir/first:$wdir/dup:$wdir/tools" true nowhere >/dev/null 2>&1 || _rc=$?
[ "$_rc" -eq 127 ] || fail "expected 127 with only wrappers, got $_rc (124 = looped)"

echo "✓ fable consent hook behaves"
