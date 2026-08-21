#!/usr/bin/env bash
# test-link-claude-json.sh — unit-test the ~/.claude.json persistence helper.
#
# The case that matters most is destructive-migration: a `claude` launched
# before the symlink exists writes a fresh, near-empty REAL file at
# ~/.claude.json, and the naive `mv` this helper replaced moved that stub OVER
# the volume's real account state — logging the user out and breaking
# subscription detection and remote-control resume. So every case here asserts
# the same invariant from a different angle: the VOLUME COPY IS NEVER LOST.
#
# No container and no network: the helpers operate on throwaway fake homes plus
# file assertions. Run via `task test:link-claude-json`.
set -euo pipefail
cd "$(dirname "$0")/.."
helper=".devcontainer/scripts/link-claude-json.sh"
opencode_helper=".devcontainer/scripts/persist-opencode.sh"

[ -r "$helper" ] || {
    echo "TEST FAIL: $helper not found" >&2
    exit 1
}
[ -r "$opencode_helper" ] || {
    echo "TEST FAIL: $opencode_helper not found" >&2
    exit 1
}
command -v jq >/dev/null 2>&1 || {
    echo "TEST FAIL: jq is required by the helper's merge path and by this suite" >&2
    exit 1
}

fail() {
    echo "TEST FAIL: $*" >&2
    exit 1
}

tmp_root="$(mktemp -d -t harmon-link-claude-XXXXXX)"
trap 'rm -rf "$tmp_root"' EXIT

# new_home <label> -> path to a fresh fake HOME (with ~/.claude/ present).
# The label is REQUIRED and must be unique per case: this runs in a command
# substitution, so a shared counter would live in a subshell and never advance,
# handing every case the same directory — and the leftover symlink from an
# earlier case would make a later case's `printf > ~/.claude.json` write
# straight through into the volume copy it was about to assert on.
new_home() {
    local h="${tmp_root}/home-${1}"
    if [ -e "$h" ]; then
        echo "TEST BUG: fixture home '${1}' reused" >&2
        exit 1
    fi
    mkdir -p "$h/.claude"
    printf '%s' "$h"
}

# run_helper <home> — invoke the helper with HOME pointed at the fixture.
run_helper() {
    HOME="$1" bash "$helper" >/dev/null 2>&1
}

# ---- 1. stray real file + populated volume copy: the destructive case ----

echo "==> stray file merges INTO the volume copy, which wins every conflict"
home="$(new_home merge)"
# The persisted state: a real account record. `hasTrustDialogAccepted` is the
# conflict key — the stray disagrees, and the volume's value must survive.
cat >"$home/.claude/.claude.json" <<'JSON'
{"oauthAccount":{"emailAddress":"real@example.com"},"hasTrustDialogAccepted":false,"remoteControl":true}
JSON
# The stub Claude Code writes when it starts with no symlink in place.
cat >"$home/.claude.json" <<'JSON'
{"hasTrustDialogAccepted":true,"firstStartTime":"2026-01-01"}
JSON
run_helper "$home"
merged="$home/.claude/.claude.json"
[ -f "$merged" ] || fail "the volume copy disappeared"
[ "$(jq -r '.oauthAccount.emailAddress' "$merged")" = "real@example.com" ] ||
    fail "the volume copy's account state was lost"
[ "$(jq -r '.remoteControl' "$merged")" = "true" ] ||
    fail "the volume copy's remote-control registration was lost"
[ "$(jq -r '.hasTrustDialogAccepted' "$merged")" = "false" ] ||
    fail "the stray file won a conflicting key — the volume copy must always win"
[ "$(jq -r '.firstStartTime' "$merged")" = "2026-01-01" ] ||
    fail "the stray file's unique keys were not merged in"
[ -L "$home/.claude.json" ] || fail "~/.claude.json is not a symlink after the merge"
[ "$(readlink "$home/.claude.json")" = "$home/.claude/.claude.json" ] ||
    fail "the symlink does not point at the volume copy"
# GNU stat first, BSD (macOS) fallback — verify must pass on both.
[ "$(stat -c '%a' "$merged" 2>/dev/null || stat -f '%Lp' "$merged")" = "600" ] ||
    fail "the merged volume copy is not mode 0600"

# ---- 2. stray real file + missing/empty volume copy: first migration ----

echo "==> with no persisted copy, the stray is adopted into the volume"
for variant in missing empty; do
    home="$(new_home adopt-${variant})"
    if [ "$variant" = "empty" ]; then : >"$home/.claude/.claude.json"; fi
    printf '%s' '{"oauthAccount":{"emailAddress":"first@example.com"}}' >"$home/.claude.json"
    run_helper "$home"
    [ "$(jq -r '.oauthAccount.emailAddress' "$home/.claude/.claude.json")" = "first@example.com" ] ||
        fail "${variant} volume copy: the stray was not adopted into the volume"
    [ -L "$home/.claude.json" ] || fail "${variant} volume copy: ~/.claude.json is not a symlink"
    [ "$(readlink "$home/.claude.json")" = "$home/.claude/.claude.json" ] ||
        fail "${variant} volume copy: the symlink does not point at the volume copy"
done

# ---- 3. already symlinked: a no-op, and repeated runs stay correct ----

echo "==> an existing correct symlink is left alone (and the helper is idempotent)"
home="$(new_home symlinked)"
printf '%s' '{"oauthAccount":{"emailAddress":"kept@example.com"}}' >"$home/.claude/.claude.json"
ln -sfn "$home/.claude/.claude.json" "$home/.claude.json"
before="$(cat "$home/.claude/.claude.json")"
run_helper "$home"
run_helper "$home"
[ "$(cat "$home/.claude/.claude.json")" = "$before" ] ||
    fail "the volume copy changed on an already-symlinked home"
[ -L "$home/.claude.json" ] || fail "the symlink was replaced by a real file"
[ "$(readlink "$home/.claude.json")" = "$home/.claude/.claude.json" ] ||
    fail "the symlink stopped pointing at the volume copy"
# A symlink is `-f` too, so a helper that tested -f before -L would move the
# link's own TARGET aside — emptying the volume through its own symlink.
[ -s "$home/.claude/.claude.json" ] || fail "the volume copy was emptied via its symlink"

echo "==> a symlink aimed somewhere else is re-pointed at the volume copy"
home="$(new_home misaimed)"
printf '%s' '{"a":1}' >"$home/.claude/.claude.json"
printf '%s' '{"b":2}' >"$home/elsewhere.json"
ln -sfn "$home/elsewhere.json" "$home/.claude.json"
run_helper "$home"
[ "$(readlink "$home/.claude.json")" = "$home/.claude/.claude.json" ] ||
    fail "a misaimed symlink was not re-pointed at the volume copy"

# ---- 4. unmergeable stray: park it, never overwrite the volume copy ----

echo "==> an unparseable stray is parked as .bak and the volume copy is untouched"
home="$(new_home badjson)"
printf '%s' '{"oauthAccount":{"emailAddress":"safe@example.com"}}' >"$home/.claude/.claude.json"
printf '%s' 'not json at all {{{' >"$home/.claude.json"
run_helper "$home"
[ "$(jq -r '.oauthAccount.emailAddress' "$home/.claude/.claude.json")" = "safe@example.com" ] ||
    fail "an unparseable stray damaged the volume copy"
bak_count=$(find "$home/.claude" -maxdepth 1 -name '.claude.json.stray-*.bak' | wc -l)
[ "$bak_count" -eq 1 ] || fail "expected exactly one parked .bak, found ${bak_count}"
bak=$(find "$home/.claude" -maxdepth 1 -name '.claude.json.stray-*.bak')
grep -q 'not json at all' "$bak" || fail "the parked .bak does not hold the stray's content"
[ -L "$home/.claude.json" ] || fail "~/.claude.json is not a symlink after parking the stray"

echo "==> with jq unavailable, the stray is parked rather than merged"
home="$(new_home nojq)"
printf '%s' '{"oauthAccount":{"emailAddress":"nojq@example.com"}}' >"$home/.claude/.claude.json"
printf '%s' '{"hasTrustDialogAccepted":true}' >"$home/.claude.json"
# A PATH holding only the coreutils the parking path needs. An empty PATH would
# not do: it hides `date`/`mv`/`ln` too, so the helper would fail for reasons
# unrelated to jq and the case would prove nothing.
nojq_bin="${tmp_root}/nojq-bin"
mkdir -p "$nojq_bin"
for cmd in date mv chmod ln rm mktemp install cat; do
    ln -sf "$(command -v "$cmd")" "$nojq_bin/$cmd"
done
if [ -x "$nojq_bin/jq" ]; then fail "the no-jq fixture PATH still exposes jq"; fi
HOME="$home" PATH="$nojq_bin" "$(command -v bash)" "$helper" >/dev/null 2>&1 ||
    fail "the helper exited nonzero when jq was unavailable"
[ "$(jq -r '.oauthAccount.emailAddress' "$home/.claude/.claude.json")" = "nojq@example.com" ] ||
    fail "the volume copy was overwritten when jq was unavailable"
[ "$(find "$home/.claude" -maxdepth 1 -name '.claude.json.stray-*.bak' | wc -l)" -eq 1 ] ||
    fail "the stray was not parked when jq was unavailable"

# ---- 5. no ~/.claude volume: do nothing at all ----

echo "==> with no ~/.claude directory the helper is a no-op"
home="${tmp_root}/home-novolume"
mkdir -p "$home"
printf '%s' '{"x":1}' >"$home/.claude.json"
run_helper "$home"
if [ ! -f "$home/.claude.json" ] || [ -L "$home/.claude.json" ]; then
    fail "the helper touched ~/.claude.json with no volume mounted"
fi
[ ! -e "$home/.claude" ] || fail "the helper created ~/.claude — that would strand state outside the volume"

# ---- 6. OpenCode Coder migration: preserve, link, fail closed ----

echo "==> OpenCode config and data migrate without loss and remain idempotent"
home="${tmp_root}/home-opencode"
persistent="${tmp_root}/persistent-opencode"
mkdir -p "$home/.config/opencode" "$home/.local/share/opencode"
printf '%s' '{"theme":"system"}' >"$home/.config/opencode/opencode.json"
printf '%s' '{"provider":{"type":"oauth"}}' >"$home/.local/share/opencode/auth.json"
HOME="$home" bash "$opencode_helper" "$persistent"
HOME="$home" bash "$opencode_helper" "$persistent"
[ -L "$home/.config/opencode" ] || fail "OpenCode config was not linked after migration"
[ -L "$home/.local/share/opencode" ] || fail "OpenCode data was not linked after migration"
[ "$(cat "$persistent/opencode-config/opencode.json")" = '{"theme":"system"}' ] ||
    fail "OpenCode config was lost during migration"
[ "$(cat "$persistent/opencode-data/auth.json")" = '{"provider":{"type":"oauth"}}' ] ||
    fail "OpenCode auth data was lost during migration"

echo "==> a failed OpenCode copy leaves the source state untouched"
home="${tmp_root}/home-opencode-fail"
persistent="${tmp_root}/persistent-opencode-fail"
mkdir -p "$home/.config/opencode" "$home/.local/share/opencode"
printf '%s' 'must-survive' >"$home/.config/opencode/opencode.json"
fail_bin="${tmp_root}/opencode-fail-bin"
mkdir -p "$fail_bin"
for cmd in mkdir ln rm; do
    ln -sf "$(command -v "$cmd")" "$fail_bin/$cmd"
done
cat >"$fail_bin/cp" <<'SH'
#!/bin/sh
exit 1
SH
chmod +x "$fail_bin/cp"
if HOME="$home" PATH="$fail_bin" "$(command -v bash)" "$opencode_helper" "$persistent" >/dev/null 2>&1; then
    fail "OpenCode migration succeeded despite a failed copy"
fi
[ -f "$home/.config/opencode/opencode.json" ] ||
    fail "OpenCode migration deleted the source after a failed copy"
[ "$(cat "$home/.config/opencode/opencode.json")" = 'must-survive' ] ||
    fail "OpenCode migration changed the source after a failed copy"

# ---- 7. post-create ordering: Coder persistence before helper before seed ----
# On Coder, persistence is wired by SYMLINK inside post-create itself, not by a
# mount that predates it. If the helper or the onboarding seed runs before the
# Coder block, they populate the container-local ~/.claude and the block's
# migration `cp -a` copies that stub over ~/.persistent/.claude/'s real account
# state — the clobber this helper exists to prevent, reintroduced by line
# order alone. Static assertion, since the ordering is the entire guarantee.

echo "==> post-create wires Coder persistence before the helper and the seed"
post_create=".devcontainer/scripts/post-create-common.sh"
line_of() { grep -n "$1" "$post_create" | head -1 | cut -d: -f1; }
coder_line="$(line_of 'Coder persistent volume symlinks')"
opencode_line="$(line_of 'persist-opencode\.sh')"
helper_line="$(line_of 'link-claude-json\.sh$')"
seed_line="$(line_of 'hasCompletedOnboarding')"
[ -n "$coder_line" ] && [ -n "$opencode_line" ] && [ -n "$helper_line" ] && [ -n "$seed_line" ] ||
    fail "could not locate the Coder block, persistence helpers, or onboarding seed in $post_create"
[ "$coder_line" -lt "$opencode_line" ] && [ "$opencode_line" -lt "$helper_line" ] ||
    fail "post-create does not run OpenCode persistence inside the Coder block before link-claude-json.sh"
[ "$coder_line" -lt "$helper_line" ] ||
    fail "post-create runs link-claude-json.sh (line $helper_line) before the Coder persistence symlinks (line $coder_line) — on Coder the helper would populate the container-local ~/.claude"
[ "$helper_line" -lt "$seed_line" ] ||
    fail "post-create seeds onboarding (line $seed_line) before link-claude-json.sh (line $helper_line)"

echo "link-claude-json: all cases passed"
