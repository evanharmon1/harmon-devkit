#!/usr/bin/env bash
set -euo pipefail

# Unit tests for .devcontainer/scripts/bot-autonomy.sh and its modules — the
# registry-completeness and structural-parity gates from
# https://github.com/evanharmon1/harmon-init/tree/main/openspec/changes/archive/2026-09-05-bot-autonomy-bootstrap
# (tasks 1.3, 1.4, 2.3), plus
# behavioral fixtures for the per-harness modules not already covered by
# scripts/devcontainer-assert.sh's unit mode. No container, no real
# secrets — every fixture uses a scratch HOME/PATH/config file, never the
# repository's own /etc or ~/.gemini state.
#
# Deliberately carries NO devcontainer paths: filter in
# .github/workflows/devcontainer-build.yml: it is wired into `task verify`
# (build.yml's aggregate gate, required unconditionally), so a registry
# change that adds a harness slug with no coverage entry fails an
# already-required check regardless of which paths a PR touches. See
# design.md - Risks ("Forgetting to add oh-my-pi's unsupported entry...").

fail() {
    # shell-robustness: ok — always exits, so its status is never read
    echo "FAIL: $*" >&2
    exit 1
}

test_file_sha512() {
    if command -v sha512sum >/dev/null 2>&1; then
        sha512sum "$1" | awk '{print $1}'
    else
        shasum -a 512 "$1" | awk '{print $1}'
    fi
}

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(git -C "$script_dir" rev-parse --show-toplevel)"
bot_autonomy="${repo_root}/.devcontainer/scripts/bot-autonomy.sh"
module_dir="${repo_root}/.devcontainer/config/bot-autonomy"
registry="${repo_root}/agent-registry.json"
codex_baseline="${repo_root}/.devcontainer/config/codex-managed-config.toml"
codex_bot="${repo_root}/.devcontainer/config/codex-managed-config.bot.toml"

[ -x "$bot_autonomy" ] || fail "bot-autonomy.sh missing or not executable at ${bot_autonomy}"
[ -d "$module_dir" ] || fail "bot-autonomy module directory missing at ${module_dir}"

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

# verify/coverage now also check the REVERSE direction: every module file's
# executable, if installed, must be reachable from the current registry
# (task added in challenge round 3). A test environment that already has
# the real claude/codex/agy/opencode binaries on PATH (this repo's own bot
# devcontainer, for instance) would otherwise trip that check the moment a
# narrow, single-slug fixture registry is used below — an environment
# accident, not something under test. Directory-level exclusion cannot fix
# this: on a merged-/usr system /bin and /usr/bin are the same directory,
# so excluding it to hide claude/codex/opencode would also hide jq. Instead
# build ONE curated bin directory, symlinking only the tools bot-autonomy.sh
# and its modules actually shell out to, and use that as SAFE_PATH —
# claude/codex/agy/opencode are never among them, by construction.
safe_bin="${work_dir}/safe-bin"
mkdir -p "$safe_bin"
for tool in bash cat grep jq yq sha256sum shasum git mktemp mv chmod install mkdir basename dirname cmp rm; do
    tool_path="$(command -v "$tool" 2>/dev/null || true)"
    [ -n "$tool_path" ] && ln -sf "$tool_path" "${safe_bin}/${tool}"
done
SAFE_PATH="$safe_bin"

echo "==> 1. coverage passes against the real registry and tables"
BOT_AUTONOMY_REGISTRY="$registry" BOT_AUTONOMY_CONFIG_DIR="$module_dir" \
    bash "$bot_autonomy" coverage >/dev/null ||
    fail "bot-autonomy.sh coverage failed against the real agent-registry.json"

echo "==> 1b. apply/verify/coverage all fail loudly when the registry cannot be read"
# Regression guard: a `while read < <(cmd)` pattern silently reports success
# when `cmd` fails, because the exit status of a while loop whose body never
# runs is 0, not the substituted command's — exactly the silent-failure shape
# this whole change exists to eliminate. Each subcommand must exit non-zero
# here, not fall through to its "passed" message.
for sub in apply verify coverage; do
    if BOT_AUTONOMY_REGISTRY="${work_dir}/does-not-exist.json" BOT_AUTONOMY_CONFIG_DIR="$module_dir" \
        bash "$bot_autonomy" "$sub" >/dev/null 2>&1; then
        fail "bot-autonomy.sh ${sub} exited 0 with an unreadable agent-registry.json"
    fi
done

echo "==> 1c. an alias dispatches its target module even if the target's own slug is absent from the registry"
orphan_registry="${work_dir}/registry-orphan-target.json"
jq -n '{harnesses: [{slug: "claude-code-qwen"}]}' >"$orphan_registry"
orphan_bin="${work_dir}/orphan-bin"
mkdir -p "$orphan_bin"
printf '#!/bin/sh\nexit 0\n' >"${orphan_bin}/claude"
chmod +x "${orphan_bin}/claude"
orphan_managed="${work_dir}/orphan-claude-managed.json"
echo '{}' >"$orphan_managed"
BOT_AUTONOMY_REGISTRY="$orphan_registry" BOT_AUTONOMY_CONFIG_DIR="$module_dir" \
    BOT_AUTONOMY_CLAUDE_MANAGED="$orphan_managed" PATH="${orphan_bin}:${SAFE_PATH}" \
    bash "$bot_autonomy" apply >/dev/null
jq -e '.permissions.defaultMode == "bypassPermissions"' "$orphan_managed" >/dev/null ||
    fail "apply did not dispatch the claude-code module via an alias whose target slug is absent from the registry"

echo "==> 2. coverage fails an uncovered slug"
uncovered_registry="${work_dir}/registry-uncovered.json"
jq -n '{harnesses: [{slug: "totally-new-harness"}]}' >"$uncovered_registry"
if BOT_AUTONOMY_REGISTRY="$uncovered_registry" BOT_AUTONOMY_CONFIG_DIR="$module_dir" \
    bash "$bot_autonomy" coverage >/dev/null 2>&1; then
    fail "coverage did not fail on an uncovered registry slug"
fi

echo "==> 2b. coverage fails an alias whose target has no module"
broken_alias_dir="${work_dir}/broken-alias-config"
mkdir -p "$broken_alias_dir"
cp "${module_dir}"/*.sh "${module_dir}/unsupported.json" "$broken_alias_dir/"
jq -n '{"claude-code-broken": "totally-nonexistent-module"}' >"${broken_alias_dir}/aliases.json"
broken_alias_registry="${work_dir}/registry-broken-alias.json"
jq -n '{harnesses: [{slug: "claude-code-broken"}]}' >"$broken_alias_registry"
if BOT_AUTONOMY_REGISTRY="$broken_alias_registry" BOT_AUTONOMY_CONFIG_DIR="$broken_alias_dir" \
    bash "$bot_autonomy" coverage >/dev/null 2>&1; then
    fail "coverage did not fail when an alias's target has no module (misspelled or removed)"
fi

echo "==> 3. coverage fails a doubly-covered slug"
double_dir="${work_dir}/double-config"
mkdir -p "$double_dir"
cp "${module_dir}"/*.sh "$double_dir/"
cp "${module_dir}/unsupported.json" "$double_dir/"
jq '. + {"claude-code": "codex-cli"}' "${module_dir}/aliases.json" >"${double_dir}/aliases.json"
double_registry="${work_dir}/registry-double.json"
jq -n '{harnesses: [{slug: "claude-code"}]}' >"$double_registry"
if BOT_AUTONOMY_REGISTRY="$double_registry" BOT_AUTONOMY_CONFIG_DIR="$double_dir" \
    bash "$bot_autonomy" coverage >/dev/null 2>&1; then
    fail "coverage did not fail when a slug is both a module and an alias"
fi

echo "==> 4. coverage fails a malformed unsupported executable field"
malformed_dir="${work_dir}/malformed-config"
mkdir -p "$malformed_dir"
cp "${module_dir}"/*.sh "${module_dir}/aliases.json" "$malformed_dir/"
jq -n '{"broken-harness": {"executable": 123, "reason": "not a string or null"}}' >"${malformed_dir}/unsupported.json"
malformed_registry="${work_dir}/registry-malformed.json"
jq -n '{harnesses: [{slug: "broken-harness"}]}' >"$malformed_registry"
if BOT_AUTONOMY_REGISTRY="$malformed_registry" BOT_AUTONOMY_CONFIG_DIR="$malformed_dir" \
    bash "$bot_autonomy" coverage >/dev/null 2>&1; then
    fail "coverage did not fail on an unsupported entry whose executable is neither a string nor null"
fi

# Omitting the field entirely is distinct from an explicit `null` (a real
# "no binary at all" entry like claude-code-action) and must also fail.
omitted_dir="${work_dir}/omitted-config"
mkdir -p "$omitted_dir"
cp "${module_dir}"/*.sh "${module_dir}/aliases.json" "$omitted_dir/"
jq -n '{"broken-harness-2": {"reason": "executable field omitted entirely"}}' >"${omitted_dir}/unsupported.json"
omitted_registry="${work_dir}/registry-omitted.json"
jq -n '{harnesses: [{slug: "broken-harness-2"}]}' >"$omitted_registry"
if BOT_AUTONOMY_REGISTRY="$omitted_registry" BOT_AUTONOMY_CONFIG_DIR="$omitted_dir" \
    bash "$bot_autonomy" coverage >/dev/null 2>&1; then
    fail "coverage did not fail on an unsupported entry that omits its executable field entirely"
fi

echo "==> 5. verify fails when an unsupported harness's named executable becomes installed"
# Real registry/tables, but a scratch PATH exposing only ONE fake binary at a
# time — module executables (claude/codex/agy/opencode) are absent from this
# PATH, so the four real modules' own apply/verify are never reached; only
# the unsupported-bucket check is exercised.
assert_unsupported_fails() {
    local slug="$1" fake_exe="$2"
    local fake_bin_dir="${work_dir}/fake-bin-${fake_exe}"
    mkdir -p "$fake_bin_dir"
    printf '#!/bin/sh\nexit 0\n' >"${fake_bin_dir}/${fake_exe}"
    chmod +x "${fake_bin_dir}/${fake_exe}"
    local out rc=0
    out="$(BOT_AUTONOMY_REGISTRY="$registry" BOT_AUTONOMY_CONFIG_DIR="$module_dir" \
        PATH="${fake_bin_dir}:${SAFE_PATH}" bash "$bot_autonomy" verify 2>&1)" || rc=$?
    [ "$rc" -ne 0 ] || fail "verify did not fail with a fake '${fake_exe}' installed for unsupported slug '${slug}'"
    case "$out" in
    *"$slug"*) ;;
    *) fail "verify's failure for '${fake_exe}' did not name the harness slug '${slug}': ${out}" ;;
    esac
}
# Fixtures are named after each entry's EXECUTABLE field, not its slug —
# qwen-code's binary is "qwen", cline's published @cline/cli package's binary
# is "clite" (not "cline"). A fixture using the slug itself would never be
# found by `command -v` and would silently fail to exercise this at all.
# copilot-cli, pi and oh-my-pi are deliberately NOT in this list any more:
# bot-autonomy-new-harnesses replaced their placeholder unsupported entries
# with real modules, so their executables turning up installed is now the
# expected state, not a coverage failure. Sections 16-20 below cover them.
assert_unsupported_fails "qwen-code" "qwen"
assert_unsupported_fails "goose" "goose"
assert_unsupported_fails "cline" "clite"
# A fixture literally named "cline" must NOT trip the cline entry (its real
# executable is "clite") — confirms the check keys off `executable`, not slug.
cline_slug_bin_dir="${work_dir}/fake-bin-cline-slug"
mkdir -p "$cline_slug_bin_dir"
printf '#!/bin/sh\nexit 0\n' >"${cline_slug_bin_dir}/cline"
chmod +x "${cline_slug_bin_dir}/cline"
only_cline_registry="${work_dir}/registry-only-cline.json"
jq -n '{harnesses: [{slug: "cline"}]}' >"$only_cline_registry"
BOT_AUTONOMY_REGISTRY="$only_cline_registry" BOT_AUTONOMY_CONFIG_DIR="$module_dir" \
    PATH="${cline_slug_bin_dir}:${SAFE_PATH}" bash "$bot_autonomy" verify >/dev/null 2>&1 ||
    fail "verify failed on a binary named 'cline' — the unsupported entry's executable is 'clite', not the slug"

echo "==> 6. claude-code-action (executable: null) is never checked for installation"
null_registry="${work_dir}/registry-null.json"
jq -n '{harnesses: [{slug: "claude-code-action"}]}' >"$null_registry"
BOT_AUTONOMY_REGISTRY="$null_registry" BOT_AUTONOMY_CONFIG_DIR="$module_dir" \
    PATH="$SAFE_PATH" bash "$bot_autonomy" verify >/dev/null 2>&1 ||
    fail "verify unexpectedly failed for the executable:null claude-code-action entry"

echo "==> 6b. verify and coverage fail when a module's slug is removed from the registry entirely (not aliased, just gone) while its executable stays installed"
gone_registry="${work_dir}/registry-claude-gone.json"
jq -n '{harnesses: [{slug: "codex-cli"}]}' >"$gone_registry"
gone_bin="${work_dir}/gone-bin"
mkdir -p "$gone_bin"
printf '#!/bin/sh\nexit 0\n' >"${gone_bin}/claude"
chmod +x "${gone_bin}/claude"
if BOT_AUTONOMY_REGISTRY="$gone_registry" BOT_AUTONOMY_CONFIG_DIR="$module_dir" \
    PATH="${gone_bin}:${SAFE_PATH}" bash "$bot_autonomy" verify >/dev/null 2>&1; then
    fail "verify did not notice claude-code's executable installed with no registry slug (direct or aliased) reaching it"
fi
if BOT_AUTONOMY_REGISTRY="$gone_registry" BOT_AUTONOMY_CONFIG_DIR="$module_dir" \
    bash "$bot_autonomy" coverage >/dev/null 2>&1; then
    fail "coverage did not notice the claude-code module has no registry slug (direct or aliased) reaching it"
fi

echo "==> 7. Codex structural parity: bot config matches the shared baseline on every key but sandbox_mode/approval_policy"
[ -f "$codex_baseline" ] || fail "Codex shared baseline not found at ${codex_baseline}"
[ -f "$codex_bot" ] || fail "Codex bot config not found at ${codex_bot}"
strip_overrides() {
    # Drop the two intentionally-divergent keys and comment/blank lines so a
    # line-for-line diff isolates real structural drift.
    grep -Ev '^[[:space:]]*(sandbox_mode|approval_policy)[[:space:]]*=' "$1" |
        grep -Ev '^[[:space:]]*#' |
        grep -Ev '^[[:space:]]*$'
}
diff <(strip_overrides "$codex_baseline") <(strip_overrides "$codex_bot") >/dev/null ||
    fail "codex-managed-config.bot.toml diverges from codex-managed-config.toml on a key other than sandbox_mode/approval_policy"

echo "==> 8. Codex structural parity test actually catches drift (fixture)"
parity_baseline="${work_dir}/parity-baseline.toml"
parity_bot="${work_dir}/parity-bot.toml"
cp "$codex_baseline" "$parity_baseline"
cp "$codex_bot" "$parity_bot"
sed -i.bak 's/^model = .*/model = "a-different-model"/' "$parity_bot" && rm -f "${parity_bot}.bak"
if diff <(strip_overrides "$parity_baseline") <(strip_overrides "$parity_bot") >/dev/null; then
    fail "structural parity check failed to notice a divergent 'model' key"
fi

echo "==> 9. Antigravity wrapper: flag injection, passthrough, and agy-real preference"
agy_module="${module_dir}/antigravity.sh"
wrapper_home="${work_dir}/agy-wrapper-home"
mkdir -p "${wrapper_home}/.local/bin"
printf '#!/bin/sh\necho REAL "$@"\n' >"${wrapper_home}/.local/bin/agy-real"
chmod +x "${wrapper_home}/.local/bin/agy-real"
HOME="$wrapper_home" HARMON_BOT_AUTONOMY_ANTIGRAVITY=enabled \
    BOT_AUTONOMY_ANTIGRAVITY_SETTINGS="${wrapper_home}/.gemini/antigravity-cli/settings.json" \
    bash "$agy_module" apply >/dev/null
wrapper_out="$("${wrapper_home}/.local/bin/agy" -p "do a thing")"
case "$wrapper_out" in
"REAL --dangerously-skip-permissions -p"*) ;;
*) fail "wrapper did not inject --dangerously-skip-permissions for a headless invocation: ${wrapper_out}" ;;
esac
for passthrough in "" "--version" "agent foo" "update" "--help"; do
    # shellcheck disable=SC2086
    wrapper_out="$("${wrapper_home}/.local/bin/agy" $passthrough)"
    case "$wrapper_out" in
    "REAL --dangerously-skip-permissions"*) fail "wrapper injected the flag on a passthrough invocation '${passthrough}': ${wrapper_out}" ;;
    esac
done
wrapper_out="$("${wrapper_home}/.local/bin/agy" -p "already flagged" --dangerously-skip-permissions)"
case "$wrapper_out" in
*"--dangerously-skip-permissions --dangerously-skip-permissions"*) fail "wrapper duplicated an already-present flag: ${wrapper_out}" ;;
esac

# A stock macOS host provides shasum rather than GNU sha512sum. Exercise the
# fallback under a deliberately narrow PATH that contains only shasum.
agy9_portable_home="${work_dir}/agy-wrapper-portable-home"
agy9_portable_bin="${work_dir}/agy-wrapper-portable-bin"
agy9_apply_stub="${work_dir}/agy-wrapper-portable-apply"
mkdir -p "$agy9_portable_home" "$agy9_portable_bin"
for tool in awk bash basename cat chmod dirname flock install mkdir mktemp mv rm shasum shlock stat; do
    tool_path="$(command -v "$tool" 2>/dev/null || true)"
    [ -n "$tool_path" ] && ln -s "$tool_path" "${agy9_portable_bin}/${tool}"
done
printf '#!/bin/sh\nexit 0\n' >"$agy9_apply_stub"
chmod +x "$agy9_apply_stub"
HOME="$agy9_portable_home" HARMON_BOT_AUTONOMY_ANTIGRAVITY=enabled \
    BOT_AUTONOMY_ANTIGRAVITY_APPLY_SCRIPT="$agy9_apply_stub" \
    PATH="$agy9_portable_bin" bash "$agy_module" apply >/dev/null ||
    fail "Antigravity wrapper proof hashing did not fall back to shasum"
[ -x "${agy9_portable_home}/.local/bin/agy" ] &&
    [ -f "${agy9_portable_home}/.local/bin/.agy.harmon-init-owned" ] ||
    fail "shasum fallback did not publish the wrapper and ownership proof"

echo "==> 10. Antigravity: dangling symlink fails verify regardless of marker"
dangling_home="${work_dir}/agy-dangling-home"
mkdir -p "${dangling_home}/.local/bin"
ln -s "${dangling_home}/.local/bin/agy-real" "${dangling_home}/.local/bin/agy"
if env -u HARMON_BOT_AUTONOMY_ANTIGRAVITY HOME="$dangling_home" bash "$agy_module" verify >/dev/null 2>&1; then
    fail "verify did not fail on a dangling agy symlink (marker disabled)"
fi
if HOME="$dangling_home" HARMON_BOT_AUTONOMY_ANTIGRAVITY=enabled bash "$agy_module" verify >/dev/null 2>&1; then
    fail "verify did not fail on a dangling agy symlink (marker enabled)"
fi

echo "==> 10b. Antigravity: verify checks every autonomy key (including permissions), not toolPermission alone"
drift_home="${work_dir}/agy-drift-home"
mkdir -p "$drift_home"
HOME="$drift_home" HARMON_BOT_AUTONOMY_ANTIGRAVITY=enabled bash "$agy_module" apply >/dev/null
for key in artifactReviewPolicy allowNonWorkspaceAccess enableTerminalSandbox permissions; do
    drift_settings="${drift_home}/.gemini/antigravity-cli/settings.json"
    drift_backup="$(cat "$drift_settings")"
    case "$key" in
    enableTerminalSandbox) jq ".${key} = true" "$drift_settings" >"${drift_settings}.tmp" ;;
    # An explicit per-tool deny that apply-antigravity-settings.sh's own
    # merge would otherwise leave in place untouched (the bot defaults had
    # no opinion on this key before), silently defeating toolPermission.
    permissions) jq ".${key} = {\"bash\": \"deny\"}" "$drift_settings" >"${drift_settings}.tmp" ;;
    *) jq ".${key} = \"request-review\"" "$drift_settings" >"${drift_settings}.tmp" ;;
    esac
    mv "${drift_settings}.tmp" "$drift_settings"
    if HOME="$drift_home" HARMON_BOT_AUTONOMY_ANTIGRAVITY=enabled bash "$agy_module" verify >/dev/null 2>&1; then
        fail "antigravity verify did not notice ${key} drifting while toolPermission stayed correct"
    fi
    printf '%s' "$drift_backup" >"$drift_settings"
done

echo "==> 10c. Antigravity: verify passes on a genuinely correct enabled state; fails when the backend is unrunnable or the workspace-trust entry is missing"
correct_home="${work_dir}/agy-correct-home"
mkdir -p "${correct_home}/.local/bin"
printf '#!/bin/sh\necho REAL "$@"\n' >"${correct_home}/.local/bin/agy-real"
chmod +x "${correct_home}/.local/bin/agy-real"
HOME="$correct_home" HARMON_BOT_AUTONOMY_ANTIGRAVITY=enabled bash "$agy_module" apply >/dev/null
HOME="$correct_home" HARMON_BOT_AUTONOMY_ANTIGRAVITY=enabled bash "$agy_module" verify >/dev/null ||
    fail "verify failed against a genuinely correct enabled state (agy-real present, trustedWorkspaces set by the real apply-antigravity-settings.sh)"

# The wrapper's own bytes stay exactly correct (apply is not re-run) but every
# invocation would now exit 127 — content-matching alone cannot see this.
# HARMON_ANTIGRAVITY_SYSTEM_BINARY must point off this sandbox's own real
# /usr/local/bin/agy (the pinned image ships one), or the fallback the
# module is designed to have would incidentally mask the deleted agy-real.
rm -f "${correct_home}/.local/bin/agy-real"
if HOME="$correct_home" HARMON_BOT_AUTONOMY_ANTIGRAVITY=enabled \
    HARMON_ANTIGRAVITY_SYSTEM_BINARY="${work_dir}/no-such-agy" \
    bash "$agy_module" verify >/dev/null 2>&1; then
    fail "verify passed with no runnable backend (agy-real deleted, no system fallback present)"
fi
printf '#!/bin/sh\necho REAL "$@"\n' >"${correct_home}/.local/bin/agy-real"
chmod +x "${correct_home}/.local/bin/agy-real"

# Drop the workspace-trust entry the real apply-antigravity-settings.sh
# wrote, leaving every scalar key correct — a class of drift the four-key
# check above cannot see on its own.
correct_settings="${correct_home}/.gemini/antigravity-cli/settings.json"
jq 'del(.trustedWorkspaces)' "$correct_settings" >"${correct_settings}.tmp"
mv "${correct_settings}.tmp" "$correct_settings"
if HOME="$correct_home" HARMON_BOT_AUTONOMY_ANTIGRAVITY=enabled bash "$agy_module" verify >/dev/null 2>&1; then
    fail "verify passed with the current workspace missing from trustedWorkspaces"
fi

echo "==> 11. Antigravity: a clean disabled baseline is verified, not defaulted"
disabled_home="${work_dir}/agy-disabled-home"
mkdir -p "$disabled_home"
# env -u: the outer shell (or containerEnv) may export
# HARMON_BOT_AUTONOMY_ANTIGRAVITY=enabled; clear it so the script sees the
# disabled path.
env -u HARMON_BOT_AUTONOMY_ANTIGRAVITY HOME="$disabled_home" bash "$agy_module" apply >/dev/null
env -u HARMON_BOT_AUTONOMY_ANTIGRAVITY HOME="$disabled_home" bash "$agy_module" verify >/dev/null ||
    fail "verify failed against the correct disabled-by-option state"
[ ! -e "${disabled_home}/.local/bin/agy" ] || fail "apply created ~/.local/bin/agy while disabled-by-option"

echo "==> 11b. Antigravity: apply's disabled-branch restore fails loudly (not silently) into a missing or invalid settings.json, leaving the backup in place"
restore_fail_home="${work_dir}/agy-restore-fail-home"
mkdir -p "${restore_fail_home}/.local/bin"
printf '#!/bin/sh\necho REAL "$@"\n' >"${restore_fail_home}/.local/bin/agy-real"
chmod +x "${restore_fail_home}/.local/bin/agy-real"
HOME="$restore_fail_home" HARMON_BOT_AUTONOMY_ANTIGRAVITY=enabled bash "$agy_module" apply >/dev/null
restore_fail_settings="${restore_fail_home}/.gemini/antigravity-cli/settings.json"
restore_fail_backup="${restore_fail_settings}.harmon-init-autonomy-backup"
[ -f "$restore_fail_backup" ] ||
    fail "fixture setup: expected a backup after the enabled apply"

# Missing target: the disabled branch's `apply-antigravity-settings.sh
# restore` call must abort apply (set -e propagates its exit code) rather
# than reporting success while discarding evidence of the unfinished
# restore.
rm -f "$restore_fail_settings"
if env -u HARMON_BOT_AUTONOMY_ANTIGRAVITY HOME="$restore_fail_home" bash "$agy_module" apply >/dev/null 2>&1; then
    fail "antigravity apply (disabled branch) reported success while restoring into a missing settings.json"
fi
[ -f "$restore_fail_backup" ] ||
    fail "antigravity apply's disabled-branch restore discarded its backup after failing against a missing settings.json"

# Invalid (non-object) target.
printf 'not valid json' >"$restore_fail_settings"
if env -u HARMON_BOT_AUTONOMY_ANTIGRAVITY HOME="$restore_fail_home" bash "$agy_module" apply >/dev/null 2>&1; then
    fail "antigravity apply (disabled branch) reported success while restoring into an invalid settings.json"
fi
[ -f "$restore_fail_backup" ] ||
    fail "antigravity apply's disabled-branch restore discarded its backup after failing against an invalid settings.json"

echo "==> 12. OpenCode: fresh apply, override, preserve unrelated keys, workspace override, absent-key restore"
opencode_module="${module_dir}/opencode.sh"
oc_home="${work_dir}/oc-home"
oc_workdir="${work_dir}/oc-workdir"
mkdir -p "${oc_home}/.config/opencode" "$oc_workdir"

# Fresh creation.
BOT_AUTONOMY_OPENCODE_CONFIG_DIR="${oc_home}/.config/opencode" bash "$opencode_module" apply >/dev/null
jq -e '.permission["*"] == "allow"' "${oc_home}/.config/opencode/opencode.json" >/dev/null ||
    fail "opencode apply did not seed permission allow-all on a fresh config"

# Override an existing ask/deny value; preserve unrelated keys; verify via the
# real opencode CLI's fully-resolved config.
printf '{"theme":"dark","permission":{"*":"ask"}}\n' >"${oc_home}/.config/opencode/opencode.json"
rm -f "${oc_home}/.config/opencode/opencode.json.harmon-init-autonomy-backup"
BOT_AUTONOMY_OPENCODE_CONFIG_DIR="${oc_home}/.config/opencode" bash "$opencode_module" apply >/dev/null
jq -e '.theme == "dark" and .permission["*"] == "allow"' "${oc_home}/.config/opencode/opencode.json" >/dev/null ||
    fail "opencode apply did not override ask/deny while preserving unrelated keys"
if command -v opencode >/dev/null 2>&1; then
    HOME="$oc_home" BOT_AUTONOMY_OPENCODE_CONFIG_DIR="${oc_home}/.config/opencode" \
        BOT_AUTONOMY_OPENCODE_WORKDIR="$oc_workdir" bash "$opencode_module" verify >/dev/null ||
        fail "opencode verify failed against a correctly-applied allow-all config"

    # Workspace-level override is not silently missed.
    printf '{"permission":{"*":"deny"}}\n' >"${oc_workdir}/opencode.json"
    if HOME="$oc_home" BOT_AUTONOMY_OPENCODE_CONFIG_DIR="${oc_home}/.config/opencode" \
        BOT_AUTONOMY_OPENCODE_WORKDIR="$oc_workdir" bash "$opencode_module" verify >/dev/null 2>&1; then
        fail "opencode verify did not notice a workspace-level permission override"
    fi

    # A workspace override can ADD a specific-category denial ALONGSIDE the
    # global wildcard rather than replacing it — OpenCode resolves both keys
    # present at once ({"*":"allow","bash":"deny"}), so a wildcard-only check
    # would report allow-all while `bash` still prompts or fails.
    printf '{"permission":{"bash":"deny"}}\n' >"${oc_workdir}/opencode.json"
    if HOME="$oc_home" BOT_AUTONOMY_OPENCODE_CONFIG_DIR="${oc_home}/.config/opencode" \
        BOT_AUTONOMY_OPENCODE_WORKDIR="$oc_workdir" bash "$opencode_module" verify >/dev/null 2>&1; then
        fail "opencode verify did not notice a workspace-level category-specific denial alongside an allow-all wildcard"
    fi
    rm -f "${oc_workdir}/opencode.json"
else
    echo "    (opencode CLI not on PATH; skipping verify sub-checks)"
fi

# apply -> apply -> restore returns the value from BEFORE THE FIRST apply.
BOT_AUTONOMY_OPENCODE_CONFIG_DIR="${oc_home}/.config/opencode" bash "$opencode_module" apply >/dev/null
BOT_AUTONOMY_OPENCODE_CONFIG_DIR="${oc_home}/.config/opencode" bash "$opencode_module" restore >/dev/null
jq -e '.permission["*"] == "ask"' "${oc_home}/.config/opencode/opencode.json" >/dev/null ||
    fail "opencode restore after apply->apply did not return the pre-FIRST-apply value"
[ ! -f "${oc_home}/.config/opencode/opencode.json.harmon-init-autonomy-backup" ] ||
    fail "opencode restore left its backup file behind"

# Absent permission key before apply -> restore removes the key entirely.
printf '{"theme":"dark"}\n' >"${oc_home}/.config/opencode/opencode.json"
BOT_AUTONOMY_OPENCODE_CONFIG_DIR="${oc_home}/.config/opencode" bash "$opencode_module" apply >/dev/null
BOT_AUTONOMY_OPENCODE_CONFIG_DIR="${oc_home}/.config/opencode" bash "$opencode_module" restore >/dev/null
jq -e 'has("permission") | not' "${oc_home}/.config/opencode/opencode.json" >/dev/null ||
    fail "opencode restore set a default permission value instead of removing an absent key"

# Restore fails loudly (not silently) when the target config is missing —
# and leaves the backup in place rather than discarding it.
BOT_AUTONOMY_OPENCODE_CONFIG_DIR="${oc_home}/.config/opencode" bash "$opencode_module" apply >/dev/null
rm -f "${oc_home}/.config/opencode/opencode.json"
if BOT_AUTONOMY_OPENCODE_CONFIG_DIR="${oc_home}/.config/opencode" bash "$opencode_module" restore >/dev/null 2>&1; then
    fail "opencode restore reported success against a missing target config"
fi
[ -f "${oc_home}/.config/opencode/opencode.json.harmon-init-autonomy-backup" ] ||
    fail "opencode restore discarded its backup after failing against a missing target config"

# Restore fails loudly against an invalid (non-object) target config too,
# also leaving the backup in place.
printf 'not valid json\n' >"${oc_home}/.config/opencode/opencode.json"
if BOT_AUTONOMY_OPENCODE_CONFIG_DIR="${oc_home}/.config/opencode" bash "$opencode_module" restore >/dev/null 2>&1; then
    fail "opencode restore reported success against an invalid target config"
fi
[ -f "${oc_home}/.config/opencode/opencode.json.harmon-init-autonomy-backup" ] ||
    fail "opencode restore discarded its backup after failing against an invalid target config"
rm -f "${oc_home}/.config/opencode/opencode.json.harmon-init-autonomy-backup" "${oc_home}/.config/opencode/opencode.json"

echo "==> 13. Claude Code module: apply/verify round-trip and failure on drift"
claude_module="${module_dir}/claude-code.sh"
claude_fixture="${work_dir}/claude-managed-settings.json"
printf '{"skipDangerousModePermissionPrompt":true}\n' >"$claude_fixture"
BOT_AUTONOMY_CLAUDE_MANAGED="$claude_fixture" bash "$claude_module" apply >/dev/null
BOT_AUTONOMY_CLAUDE_MANAGED="$claude_fixture" bash "$claude_module" verify >/dev/null ||
    fail "claude-code verify failed immediately after a correct apply"
jq '.permissions.defaultMode = "default"' "$claude_fixture" >"${claude_fixture}.tmp" && mv "${claude_fixture}.tmp" "$claude_fixture"
if BOT_AUTONOMY_CLAUDE_MANAGED="$claude_fixture" bash "$claude_module" verify >/dev/null 2>&1; then
    fail "claude-code verify did not fail on a drifted defaultMode"
fi

echo "==> 14. Codex module: checksum verify and failure on corruption"
codex_module="${module_dir}/codex-cli.sh"
codex_fixture="${work_dir}/codex-managed.toml"
cp "$codex_baseline" "$codex_fixture"
BOT_AUTONOMY_CODEX_MANAGED="$codex_fixture" bash "$codex_module" apply >/dev/null
BOT_AUTONOMY_CODEX_MANAGED="$codex_fixture" bash "$codex_module" verify >/dev/null ||
    fail "codex-cli verify failed immediately after a correct apply"
printf '\n# corrupted\n' >>"$codex_fixture"
if BOT_AUTONOMY_CODEX_MANAGED="$codex_fixture" bash "$codex_module" verify >/dev/null 2>&1; then
    fail "codex-cli verify did not fail on a checksum mismatch"
fi

echo "==> 15. bot-autonomy.sh dispatches Antigravity's disabled-branch restore even when agy is nowhere on PATH"
no_agy_home="${work_dir}/agy-no-executable-home"
mkdir -p "${no_agy_home}/.local/bin"
# Simulate "was previously enabled": a real apply with agy-real present
# persists always-proceed settings, matching a container that had autonomy
# on before the option was toggled off.
printf '#!/bin/sh\necho REAL "$@"\n' >"${no_agy_home}/.local/bin/agy-real"
chmod +x "${no_agy_home}/.local/bin/agy-real"
HOME="$no_agy_home" HARMON_BOT_AUTONOMY_ANTIGRAVITY=enabled bash "$agy_module" apply >/dev/null
grep -q '"toolPermission": *"always-proceed"' "${no_agy_home}/.gemini/antigravity-cli/settings.json" ||
    fail "fixture setup: expected always-proceed after the enabled apply"

# Now disable the option through the compatibility cleanup, then remove the
# independently supplied agy-real so no executable remains on PATH. Dispatch
# through the TOP-LEVEL bot-autonomy.sh — not antigravity.sh directly — on
# SAFE_PATH, which by construction cannot resolve agy anywhere (this
# sandbox's own /usr/local/bin/agy must not leak in and mask the bug).
HOME="$no_agy_home" HARMON_BOT_AUTONOMY_ANTIGRAVITY=disabled \
    bash "${repo_root}/.devcontainer/config/ensure-antigravity-cli.sh" >/dev/null
rm -f "${no_agy_home}/.local/bin/agy-real"
HOME="$no_agy_home" HARMON_BOT_AUTONOMY_ANTIGRAVITY=disabled PATH="$SAFE_PATH" \
    BOT_AUTONOMY_REGISTRY="$registry" BOT_AUTONOMY_CONFIG_DIR="$module_dir" \
    bash "$bot_autonomy" apply >/dev/null ||
    fail "bot-autonomy.sh apply failed with agy absent from PATH (disabled option)"
if grep -q '"toolPermission"' "${no_agy_home}/.gemini/antigravity-cli/settings.json"; then
    fail "Antigravity settings still carry a managed toolPermission after disabling with agy absent from PATH — the disabled branch's restore did not run"
fi
HOME="$no_agy_home" HARMON_BOT_AUTONOMY_ANTIGRAVITY=disabled PATH="$SAFE_PATH" \
    BOT_AUTONOMY_REGISTRY="$registry" BOT_AUTONOMY_CONFIG_DIR="$module_dir" \
    bash "$bot_autonomy" verify >/dev/null ||
    fail "bot-autonomy.sh verify failed against the correctly-restored disabled state with agy absent from PATH"

# ── bot-autonomy-new-harnesses: Copilot CLI, pi, oh-my-pi ─────────────────

echo "==> 16. Copilot CLI: disabled-by-option is a VERIFIED state, not a default"
copilot_module="${module_dir}/copilot-cli.sh"
cp_disabled_home="${work_dir}/copilot-disabled-home"
mkdir -p "${cp_disabled_home}/.local/bin"
cp_disabled_env=(
    HOME="$cp_disabled_home"
    BOT_AUTONOMY_COPILOT_LINK="${cp_disabled_home}/.local/bin/copilot"
    BOT_AUTONOMY_COPILOT_SETTINGS="${cp_disabled_home}/.copilot/settings.json"
    HARMON_BOT_AUTONOMY_COPILOT=disabled
    COPILOT_ALLOW_ALL=false
)
env "${cp_disabled_env[@]}" bash "$copilot_module" apply >/dev/null
env "${cp_disabled_env[@]}" bash "$copilot_module" verify >/dev/null ||
    fail "copilot-cli verify failed against the correct disabled-by-option state"
[ ! -e "${cp_disabled_home}/.local/bin/copilot" ] ||
    fail "copilot-cli apply created a wrapper while disabled-by-option"

# The kill-switch check must NOT run in the disabled state: a default-off
# consumer whose own org locks bypass mode via MDM has nothing wrong with it.
mkdir -p "${cp_disabled_home}/.copilot"
printf '{"permissions":{"disableBypassPermissionsMode":"disable"}}\n' >"${cp_disabled_home}/.copilot/settings.json"
env "${cp_disabled_env[@]}" bash "$copilot_module" verify >/dev/null ||
    fail "copilot-cli verify failed on a disabled-by-option state whose org separately locks bypass mode — that key is irrelevant when autonomy is off"

# A disabled render must still assert the literal "false": an unset (or
# truthy) COPILOT_ALLOW_ALL means the rendered containerEnv did not reach
# this process, which is exactly the stale-env-file channel the always-
# rendered literal exists to close.
for bad in "" "true" "1"; do
    if HOME="$cp_disabled_home" \
        BOT_AUTONOMY_COPILOT_LINK="${cp_disabled_home}/.local/bin/copilot" \
        BOT_AUTONOMY_COPILOT_SETTINGS="${cp_disabled_home}/.copilot/settings.json" \
        HARMON_BOT_AUTONOMY_COPILOT=disabled COPILOT_ALLOW_ALL="$bad" \
        bash "$copilot_module" verify >/dev/null 2>&1; then
        fail "copilot-cli verify passed a disabled state whose COPILOT_ALLOW_ALL is '${bad:-<empty>}', not the literal 'false'"
    fi
done

echo "==> 16b. Copilot CLI: enabled apply/verify round-trip, and the exact-literal contract"
cp_home="${work_dir}/copilot-home"
cp_real_bin="${work_dir}/copilot-real-bin"
mkdir -p "${cp_home}/.local/bin" "$cp_real_bin"
printf '#!/bin/sh\necho REAL "$@"\n' >"${cp_real_bin}/copilot"
chmod +x "${cp_real_bin}/copilot"
cp_link="${cp_home}/.local/bin/copilot"
cp_settings="${cp_home}/.copilot/settings.json"
cp_enabled_env=(
    HOME="$cp_home"
    BOT_AUTONOMY_COPILOT_LINK="$cp_link"
    BOT_AUTONOMY_COPILOT_SETTINGS="$cp_settings"
    HARMON_BOT_AUTONOMY_COPILOT=enabled
    COPILOT_ALLOW_ALL=true
    PATH="${cp_real_bin}:${SAFE_PATH}"
)
env "${cp_enabled_env[@]}" bash "$copilot_module" apply >/dev/null
[ -f "$cp_link" ] && [ -x "$cp_link" ] ||
    fail "copilot-cli apply did not install an executable wrapper in the enabled state"
env "${cp_enabled_env[@]}" bash "$copilot_module" verify >/dev/null ||
    fail "copilot-cli verify failed immediately after a correct enabled apply"

# A truthy-looking but non-literal value is NOT the autonomous state: Copilot's
# own documented contract checks for the string "true".
for bad in "1" "yes" "TRUE" ""; do
    if HOME="$cp_home" BOT_AUTONOMY_COPILOT_LINK="$cp_link" \
        BOT_AUTONOMY_COPILOT_SETTINGS="$cp_settings" \
        HARMON_BOT_AUTONOMY_COPILOT=enabled COPILOT_ALLOW_ALL="$bad" \
        PATH="${cp_real_bin}:${SAFE_PATH}" \
        bash "$copilot_module" verify >/dev/null 2>&1; then
        fail "copilot-cli verify accepted COPILOT_ALLOW_ALL='${bad:-<empty>}' as the autonomous state"
    fi
    # apply must refuse to install a wrapper against that same environment
    # rather than papering over a render defect.
    if HOME="$cp_home" BOT_AUTONOMY_COPILOT_LINK="${work_dir}/never-written-copilot" \
        BOT_AUTONOMY_COPILOT_SETTINGS="$cp_settings" \
        HARMON_BOT_AUTONOMY_COPILOT=enabled COPILOT_ALLOW_ALL="$bad" \
        PATH="${cp_real_bin}:${SAFE_PATH}" \
        bash "$copilot_module" apply >/dev/null 2>&1; then
        fail "copilot-cli apply installed a wrapper with COPILOT_ALLOW_ALL='${bad:-<empty>}' instead of failing on the marker/environment inconsistency"
    fi
done
[ ! -e "${work_dir}/never-written-copilot" ] ||
    fail "copilot-cli apply wrote a wrapper on the marker/environment-inconsistency path"

echo "==> 16c. Copilot CLI: the enterprise kill-switch fails verify when autonomy is ON"
mkdir -p "${cp_home}/.copilot"
printf '{"permissions":{"disableBypassPermissionsMode":"disable"}}\n' >"$cp_settings"
if env "${cp_enabled_env[@]}" bash "$copilot_module" verify >/dev/null 2>&1; then
    fail "copilot-cli verify passed with permissions.disableBypassPermissionsMode='disable' while autonomy is enabled"
fi
# Any other value (including the key being absent) is fine.
printf '{"permissions":{"disableBypassPermissionsMode":"allow-auto-only"}}\n' >"$cp_settings"
env "${cp_enabled_env[@]}" bash "$copilot_module" verify >/dev/null ||
    fail "copilot-cli verify failed on a settings.json that does not block bypass mode"
rm -f "$cp_settings"
env "${cp_enabled_env[@]}" bash "$copilot_module" verify >/dev/null ||
    fail "copilot-cli verify failed with no ~/.copilot/settings.json at all"

echo "==> 16d. Copilot CLI: verify needs matching wrapper CONTENT and a runnable delegate, not mere presence"
cp_corrupt="${work_dir}/copilot-corrupt"
cp "$cp_link" "$cp_corrupt"
printf '\n# corrupted\n' >>"$cp_link"
chmod +x "$cp_link"
if env "${cp_enabled_env[@]}" bash "$copilot_module" verify >/dev/null 2>&1; then
    fail "copilot-cli verify passed a wrapper whose content no longer matches write_wrapper's output"
fi
cp "$cp_corrupt" "$cp_link"
chmod +x "$cp_link"
env "${cp_enabled_env[@]}" bash "$copilot_module" verify >/dev/null ||
    fail "fixture setup: restoring the wrapper did not return verify to green"

# Correct bytes, no runnable backend: SAFE_PATH carries no copilot at all and
# the documented system-binary fallback is pointed off any real install, so
# every invocation would exit 127 while the wrapper still looks perfect.
if HOME="$cp_home" BOT_AUTONOMY_COPILOT_LINK="$cp_link" \
    BOT_AUTONOMY_COPILOT_SETTINGS="$cp_settings" \
    HARMON_BOT_AUTONOMY_COPILOT=enabled COPILOT_ALLOW_ALL=true \
    HARMON_COPILOT_SYSTEM_BINARY="${work_dir}/no-such-copilot" \
    PATH="$SAFE_PATH" \
    bash "$copilot_module" verify >/dev/null 2>&1; then
    fail "copilot-cli verify passed with no runnable delegate (no copilot on PATH, no system fallback)"
fi

# A symlink is never the wrapper, even a resolvable one.
mv "$cp_link" "${cp_home}/.local/bin/copilot-stashed"
ln -s "${cp_real_bin}/copilot" "$cp_link"
if env "${cp_enabled_env[@]}" bash "$copilot_module" verify >/dev/null 2>&1; then
    fail "copilot-cli verify accepted a symlink in place of the wrapper"
fi
rm -f "$cp_link"
mv "${cp_home}/.local/bin/copilot-stashed" "$cp_link"

echo "==> 16e. Copilot CLI: toggling the option off removes a previously-installed wrapper"
HOME="$cp_home" BOT_AUTONOMY_COPILOT_LINK="$cp_link" \
    BOT_AUTONOMY_COPILOT_SETTINGS="$cp_settings" \
    HARMON_BOT_AUTONOMY_COPILOT=disabled COPILOT_ALLOW_ALL=false \
    PATH="${cp_real_bin}:${SAFE_PATH}" \
    bash "$copilot_module" apply >/dev/null
[ ! -e "$cp_link" ] ||
    fail "copilot-cli apply left the wrapper behind after the marker flipped to disabled"
HOME="$cp_home" BOT_AUTONOMY_COPILOT_LINK="$cp_link" \
    BOT_AUTONOMY_COPILOT_SETTINGS="$cp_settings" \
    HARMON_BOT_AUTONOMY_COPILOT=disabled COPILOT_ALLOW_ALL=false \
    PATH="${cp_real_bin}:${SAFE_PATH}" \
    bash "$copilot_module" verify >/dev/null ||
    fail "copilot-cli verify failed after a toggle-off returned the container to disabled-by-option"

echo "==> 17. Copilot wrapper: flag injection, partial-flag completion, passthrough, delegate resolution"
env "${cp_enabled_env[@]}" bash "$copilot_module" apply >/dev/null
# Invoked DIRECTLY (never via a sourced shell), with the wrapper's own
# directory first on PATH — exactly how a programmatic launcher reaches it —
# so a wrapper that failed to exclude its own directory would recurse.
cp_run() {
    PATH="${cp_home}/.local/bin:${cp_real_bin}:${SAFE_PATH}" "$cp_link" "$@"
}
case "$(cp_run)" in
"REAL --allow-all") ;;
*) fail "copilot wrapper did not inject --allow-all on a bare (interactive) invocation: $(cp_run)" ;;
esac
case "$(cp_run -p "do a thing")" in
"REAL --allow-all -p do a thing") ;;
*) fail "copilot wrapper did not inject --allow-all on a headless -p invocation: $(cp_run -p "do a thing")" ;;
esac
# A PARTIAL narrower flag is not full coverage — the two dimensions it did
# not name would otherwise stay restricted in a sanitized environment.
for partial in --allow-all-tools --allow-all-paths --allow-all-urls; do
    case "$(cp_run "$partial" -p x)" in
    "REAL --allow-all ${partial} -p x") ;;
    *) fail "copilot wrapper did not add --allow-all alongside the partial flag ${partial}: $(cp_run "$partial" -p x)" ;;
    esac
done
# Already-complete coverage is never duplicated.
for complete in "--allow-all" "--yolo"; do
    out="$(cp_run "$complete" -p x)"
    case "$out" in
    "REAL ${complete} -p x") ;;
    *) fail "copilot wrapper modified an invocation that already carries ${complete}: ${out}" ;;
    esac
done
out="$(cp_run --allow-all-tools --allow-all-paths --allow-all-urls -p x)"
case "$out" in
"REAL --allow-all-tools --allow-all-paths --allow-all-urls -p x") ;;
*) fail "copilot wrapper appended --allow-all to an invocation already carrying all three narrower flags: ${out}" ;;
esac
# Administrative/informational subcommands pass through untouched. The list
# is Copilot 1.0.82's own `Commands:` block plus the help/version flag forms.
for passthrough in login version --version help -h --help update completion init plugin plugins mcp skill app; do
    out="$(cp_run "$passthrough")"
    case "$out" in
    *"--allow-all"*) fail "copilot wrapper injected --allow-all on the administrative subcommand '${passthrough}': ${out}" ;;
    esac
    case "$out" in
    "REAL ${passthrough}") ;;
    *) fail "copilot wrapper did not pass '${passthrough}' through unmodified: ${out}" ;;
    esac
done
# An option VALUE spelled exactly like an allow-all flag must not suppress
# injection: the scan's failure direction is asymmetric, and -p/--prompt is
# the one option whose value is arbitrary caller text (challenge round 1).
for prompt_flag in -p --prompt; do
    out="$(cp_run "$prompt_flag" --allow-all)"
    case "$out" in
    "REAL --allow-all ${prompt_flag} --allow-all") ;;
    *) fail "copilot wrapper treated the ${prompt_flag} VALUE '--allow-all' as an active flag and skipped injection: ${out}" ;;
    esac
    out="$(cp_run "$prompt_flag" --yolo)"
    case "$out" in
    "REAL --allow-all ${prompt_flag} --yolo") ;;
    *) fail "copilot wrapper treated the ${prompt_flag} VALUE '--yolo' as an active flag and skipped injection: ${out}" ;;
    esac
done
# Everything after a bare "--" is an operand, not an active flag (challenge
# round 2).
out="$(cp_run -- --allow-all)"
case "$out" in
"REAL --allow-all -- --allow-all") ;;
*) fail "copilot wrapper treated an operand after the end-of-options separator as an active flag: ${out}" ;;
esac
# A REAL flag after the prompt value is still detected (the skip is exactly
# one token, not "everything after -p").
out="$(cp_run -p "some prompt" --allow-all)"
case "$out" in
"REAL -p some prompt --allow-all") ;;
*) fail "copilot wrapper skipped more than the single -p value token: ${out}" ;;
esac
# --prompt=<value> is one token and never equals a bare flag.
out="$(cp_run --prompt=--allow-all)"
case "$out" in
"REAL --allow-all --prompt=--allow-all") ;;
*) fail "copilot wrapper mishandled an attached --prompt=<value> whose value looks like a flag: ${out}" ;;
esac

# With no copilot anywhere on PATH outside its own directory, the wrapper
# falls back to the documented system binary rather than execing itself.
cp_fallback="${work_dir}/copilot-fallback"
printf '#!/bin/sh\necho FALLBACK "$@"\n' >"$cp_fallback"
chmod +x "$cp_fallback"
HARMON_COPILOT_SYSTEM_BINARY="$cp_fallback" HOME="$cp_home" \
    BOT_AUTONOMY_COPILOT_LINK="$cp_link" HARMON_BOT_AUTONOMY_COPILOT=enabled \
    COPILOT_ALLOW_ALL=true PATH="${cp_real_bin}:${SAFE_PATH}" \
    bash "$copilot_module" apply >/dev/null
out="$(PATH="${cp_home}/.local/bin:${SAFE_PATH}" "$cp_link" -p x)"
case "$out" in
"FALLBACK --allow-all -p x") ;;
*) fail "copilot wrapper did not fall back to the documented system binary with no other copilot on PATH: ${out}" ;;
esac

echo "==> 17b. Copilot CLI: apply never destroys or clobbers a launcher it does not own"
# challenge round 2. This module claims ~/.local/bin/copilot in BOTH states —
# enabled installs the wrapper there, disabled requires it absent — so a
# foreign file at that path is already a broken state under either answer.
# Deleting it is still not this module's call: refuse and name the conflict.
cp_foreign_home="${work_dir}/copilot-foreign-home"
mkdir -p "${cp_foreign_home}/.local/bin"
cp_foreign_link="${cp_foreign_home}/.local/bin/copilot"
printf '#!/bin/sh\necho A CONSUMERS OWN LAUNCHER "$@"\n' >"$cp_foreign_link"
chmod +x "$cp_foreign_link"
cp_foreign_content="$(cat "$cp_foreign_link")"
for state in "disabled false" "enabled true"; do
    set -- $state
    if HOME="$cp_foreign_home" BOT_AUTONOMY_COPILOT_LINK="$cp_foreign_link" \
        BOT_AUTONOMY_COPILOT_SETTINGS="${cp_foreign_home}/.copilot/settings.json" \
        HARMON_BOT_AUTONOMY_COPILOT="$1" COPILOT_ALLOW_ALL="$2" \
        PATH="${cp_real_bin}:${SAFE_PATH}" \
        bash "$copilot_module" apply >/dev/null 2>&1; then
        fail "copilot-cli apply (marker ${1}) touched a launcher this module did not write instead of refusing"
    fi
    [ "$(cat "$cp_foreign_link")" = "$cp_foreign_content" ] ||
        fail "copilot-cli apply (marker ${1}) modified or deleted a launcher this module did not write"
done

# Ownership is keyed on the STABLE marker line, not a byte-compare against
# the current write_wrapper output: a wrapper an EARLIER release installed
# must still be recognised as ours, or a content change would strand it.
cp_stale_home="${work_dir}/copilot-stale-home"
mkdir -p "${cp_stale_home}/.local/bin"
cp_stale_link="${cp_stale_home}/.local/bin/copilot"
HOME="$cp_stale_home" BOT_AUTONOMY_COPILOT_LINK="$cp_stale_link" \
    BOT_AUTONOMY_COPILOT_SETTINGS="${cp_stale_home}/.copilot/settings.json" \
    HARMON_BOT_AUTONOMY_COPILOT=enabled COPILOT_ALLOW_ALL=true \
    PATH="${cp_real_bin}:${SAFE_PATH}" bash "$copilot_module" apply >/dev/null
printf '\n# a line only an older release of this wrapper carried\n' >>"$cp_stale_link"
grep -Fqx '# harmon-init-bot-autonomy-wrapper: copilot-cli' "$cp_stale_link" ||
    fail "fixture setup: the installed wrapper carries no ownership marker"
HOME="$cp_stale_home" BOT_AUTONOMY_COPILOT_LINK="$cp_stale_link" \
    BOT_AUTONOMY_COPILOT_SETTINGS="${cp_stale_home}/.copilot/settings.json" \
    HARMON_BOT_AUTONOMY_COPILOT=disabled COPILOT_ALLOW_ALL=false \
    PATH="${cp_real_bin}:${SAFE_PATH}" bash "$copilot_module" apply >/dev/null ||
    fail "copilot-cli apply refused to remove a wrapper an earlier release installed (marker present, content drifted)"
[ ! -e "$cp_stale_link" ] ||
    fail "copilot-cli apply left a previous release's own wrapper in place when disabled"

echo "==> 17c. Copilot CLI stays on the ordinary executable gate, in BOTH marker states"
# Shepherd round 2 deleted round 1's always_dispatch opt-in. It made the root
# bot profile unbootable on the checked-in pre-harness-matrix pin: the marker
# is enabled, post-create runs `bot-autonomy.sh verify`, the hook dispatched
# this module, and verify failed "no runnable delegate" — aborting every
# container creation until #1152 lands. So the module is dispatched only when
# `copilot` actually resolves on PATH, exactly like every other module here.
#
# The residual that leaves — an enabled marker with no binary anywhere is
# SKIPPED in-container, not failed — is covered by the digest-bounded
# assertion in scripts/devcontainer-assert.sh instead, which is the layer that
# can tell "this pin ships no copilot" from "the packaging regressed".
cp_gate_registry="${work_dir}/registry-copilot-only.json"
jq -n '{harnesses: [{slug: "copilot-cli"}]}' >"$cp_gate_registry"
cp_gate_run() {
    # $1 marker, $2 COPILOT_ALLOW_ALL, $3 subcommand, $4 HOME
    (cd "$work_dir" && env HOME="$4" \
        BOT_AUTONOMY_REGISTRY="$cp_gate_registry" BOT_AUTONOMY_CONFIG_DIR="$module_dir" \
        BOT_AUTONOMY_COPILOT_LINK="${4}/.local/bin/copilot" \
        BOT_AUTONOMY_COPILOT_SETTINGS="${4}/.copilot/settings.json" \
        HARMON_COPILOT_SYSTEM_BINARY="${work_dir}/no-such-copilot-anywhere" \
        HARMON_BOT_AUTONOMY_COPILOT="$1" COPILOT_ALLOW_ALL="$2" PATH="$SAFE_PATH" \
        bash "$bot_autonomy" "$3" 2>&1)
}
# The module must NOT implement always_dispatch at all — re-adding it is what
# broke the pre-matrix bot container, so make its absence the assertion.
for any_marker in enabled disabled ""; do
    if HARMON_BOT_AUTONOMY_COPILOT="$any_marker" bash "$copilot_module" always_dispatch >/dev/null 2>&1; then
        fail "copilot-cli accepts an always_dispatch subcommand (marker '${any_marker:-<unset>}') — that opt-in made the pre-harness-matrix bot container unbootable and must stay deleted"
    fi
done

# Enabled marker, no copilot anywhere: bot-autonomy.sh SKIPS the module, so
# both apply and verify succeed and nothing is installed. This is the
# pre-#1152 state of this repository's own bot profile; it must stay bootable.
cp_gate_on="${work_dir}/copilot-gate-enabled-home"
mkdir -p "${cp_gate_on}/.local/bin"
cp_gate_run enabled true apply "$cp_gate_on" >/dev/null ||
    fail "bot-autonomy.sh apply failed for an enabled Copilot with no binary installed — the pre-#1152 bot container must still boot"
cp_gate_run enabled true verify "$cp_gate_on" >/dev/null ||
    fail "bot-autonomy.sh verify failed for an enabled Copilot with no binary installed — the module must be skipped, not dispatched, when its executable is absent"
[ ! -e "${cp_gate_on}/.local/bin/copilot" ] ||
    fail "a wrapper was installed for an enabled Copilot whose binary is absent — the module should not have been dispatched at all"

# The complementary half: a default-off consumer whose image happens to carry
# no copilot behaves identically.
cp_gate_off="${work_dir}/copilot-gate-disabled-home"
mkdir -p "${cp_gate_off}/.local/bin"
cp_gate_run disabled false apply "$cp_gate_off" >/dev/null ||
    fail "bot-autonomy.sh apply failed for a disabled Copilot with no binary installed"
cp_gate_run disabled false verify "$cp_gate_off" >/dev/null ||
    fail "bot-autonomy.sh verify failed for a DISABLED Copilot with no binary — the ordinary executable gate is correct there"
[ ! -e "${cp_gate_off}/.local/bin/copilot" ] ||
    fail "the disabled branch installed a wrapper while no copilot binary was present"

# With the binary present the module IS dispatched and the enabled state is
# fully checked — proving the skip above is the executable gate, not a hole.
cp_gate_bin="${work_dir}/copilot-gate-bin"
cp_gate_live="${work_dir}/copilot-gate-live-home"
mkdir -p "$cp_gate_bin" "${cp_gate_live}/.local/bin"
printf '#!/bin/sh\necho REAL "$@"\n' >"${cp_gate_bin}/copilot"
chmod +x "${cp_gate_bin}/copilot"
(cd "$work_dir" && env HOME="$cp_gate_live" \
    BOT_AUTONOMY_REGISTRY="$cp_gate_registry" BOT_AUTONOMY_CONFIG_DIR="$module_dir" \
    BOT_AUTONOMY_COPILOT_LINK="${cp_gate_live}/.local/bin/copilot" \
    BOT_AUTONOMY_COPILOT_SETTINGS="${cp_gate_live}/.copilot/settings.json" \
    HARMON_BOT_AUTONOMY_COPILOT=enabled COPILOT_ALLOW_ALL=true \
    PATH="${cp_gate_bin}:${SAFE_PATH}" bash "$bot_autonomy" apply >/dev/null) ||
    fail "bot-autonomy.sh apply failed for an enabled Copilot WITH its binary present"
[ -f "${cp_gate_live}/.local/bin/copilot" ] ||
    fail "bot-autonomy.sh did not dispatch the copilot module when its executable was on PATH"

echo "==> 18. pi: apply writes nothing; verify fails closed on BOTH trust-granting surfaces"
pi_module="${module_dir}/pi.sh"
pi_home="${work_dir}/pi-home"
pi_workspace="${work_dir}/pi-home/workspace/repo"
mkdir -p "${pi_home}/.pi/agent" "$pi_workspace"
# pi's own install leaves a settings.json behind; apply must not touch it.
printf '{"theme":"dark"}\n' >"${pi_home}/.pi/agent/settings.json"
pi_before="$(find "${pi_home}/.pi" | sort)"
pi_before_sum="$(cat "${pi_home}/.pi/agent/settings.json")"
BOT_AUTONOMY_PI_AGENT_DIR="${pi_home}/.pi/agent" bash "$pi_module" apply >/dev/null
[ "$(find "${pi_home}/.pi" | sort)" = "$pi_before" ] ||
    fail "pi apply created or removed a file under ~/.pi — this module is a no-op by design"
[ "$(cat "${pi_home}/.pi/agent/settings.json")" = "$pi_before_sum" ] ||
    fail "pi apply modified ~/.pi/agent/settings.json — this module writes nothing"
(cd "$pi_workspace" && BOT_AUTONOMY_PI_AGENT_DIR="${pi_home}/.pi/agent" bash "$pi_module" verify >/dev/null) ||
    fail "pi verify failed against a clean, untouched ~/.pi"

# There is no `restore` subcommand: a module that writes nothing has nothing
# captured to put back.
if BOT_AUTONOMY_PI_AGENT_DIR="${pi_home}/.pi/agent" bash "$pi_module" restore >/dev/null 2>&1; then
    fail "pi module accepted a 'restore' subcommand — it never overwrites anything, so it must not offer one"
fi

# Surface 1: the global fallback. Fails regardless of who wrote it — the
# fixture deliberately writes it directly, since this module never does.
printf '{"defaultProjectTrust":"always"}\n' >"${pi_home}/.pi/agent/settings.json"
if (cd "$pi_workspace" && BOT_AUTONOMY_PI_AGENT_DIR="${pi_home}/.pi/agent" bash "$pi_module" verify >/dev/null 2>&1); then
    fail "pi verify passed with defaultProjectTrust='always' in the global settings"
fi
for safe in ask never; do
    printf '{"defaultProjectTrust":"%s"}\n' "$safe" >"${pi_home}/.pi/agent/settings.json"
    (cd "$pi_workspace" && BOT_AUTONOMY_PI_AGENT_DIR="${pi_home}/.pi/agent" bash "$pi_module" verify >/dev/null) ||
        fail "pi verify failed on the safe defaultProjectTrust value '${safe}'"
done

# Surface 2: a saved decision in trust.json. Confirmed format against the
# installed pi 0.84.4: a flat object of canonical-directory -> true|false|null,
# where only `true` grants anything. Not scoped to path-applicability: an
# unrelated trusted path is still live on a volume that outlives the check.
pi_trust="${pi_home}/.pi/agent/trust.json"
for trusted_path in "$pi_workspace" "$(dirname "$pi_workspace")" "/opt/an-unrelated-workspace"; do
    jq -n --arg p "$trusted_path" '{($p): true}' >"$pi_trust"
    if (cd "$pi_workspace" && BOT_AUTONOMY_PI_AGENT_DIR="${pi_home}/.pi/agent" bash "$pi_module" verify >/dev/null 2>&1); then
        fail "pi verify passed with a trusted saved decision for '${trusted_path}'"
    fi
done
# The positive case: an explicitly DISTRUSTED (or null) decision is safe, so a
# naive "any entry at all fails" implementation would wrongly reject it.
jq -n --arg a "$pi_workspace" --arg b "$(dirname "$pi_workspace")" \
    '{($a): false, ($b): false, "/opt/an-unrelated-workspace": false, "/opt/undecided": null}' >"$pi_trust"
(cd "$pi_workspace" && BOT_AUTONOMY_PI_AGENT_DIR="${pi_home}/.pi/agent" bash "$pi_module" verify >/dev/null) ||
    fail "pi verify failed on explicitly-distrusted saved decisions — only a TRUSTED decision grants anything"
# A store pi itself refuses to read is not evidence of safety.
printf '[]\n' >"$pi_trust"
if (cd "$pi_workspace" && BOT_AUTONOMY_PI_AGENT_DIR="${pi_home}/.pi/agent" bash "$pi_module" verify >/dev/null 2>&1); then
    fail "pi verify passed over a trust.json that is not a JSON object"
fi
rm -f "$pi_trust"

echo "==> 18b. pi: bot and dev behave identically, and dispatch adds no side effect of its own"
# The module has no per-profile branch at all, so the marker every OTHER
# Copier-gated module reads must make no difference here either.
for marker in enabled disabled ""; do
    HARMON_BOT_AUTONOMY_COPILOT="$marker" HARMON_BOT_AUTONOMY_ANTIGRAVITY="$marker" \
        BOT_AUTONOMY_PI_AGENT_DIR="${pi_home}/.pi/agent" bash "$pi_module" apply >/dev/null
done
[ "$(find "${pi_home}/.pi" | sort)" = "$pi_before" ] ||
    fail "pi apply behaved differently under some profile marker — it has no per-profile branch"

# Task 2.3's stub-executable fixture: dispatching pi through the TOP-LEVEL
# entrypoint with a fake `pi` on PATH must introduce no flag, config write,
# or other side effect that could mask pi's own non-interactive handling.
# (Proving pi's real -p behavior needs the real binary and is deferred to the
# sync-pin PR's reviewer checklist — see scripts/sync-devcontainer-image.sh.)
pi_stub_bin="${work_dir}/pi-stub-bin"
pi_stub_log="${work_dir}/pi-stub.log"
mkdir -p "$pi_stub_bin"
cat >"${pi_stub_bin}/pi" <<PI_STUB
#!/bin/sh
printf '%s\n' "\$*" >>"${pi_stub_log}"
exit 0
PI_STUB
chmod +x "${pi_stub_bin}/pi"
: >"$pi_stub_log"
pi_only_registry="${work_dir}/registry-only-pi.json"
jq -n '{harnesses: [{slug: "pi"}]}' >"$pi_only_registry"
pi_dispatch_before="$(find "${pi_home}/.pi" | sort)"
(cd "$pi_workspace" && HOME="$pi_home" BOT_AUTONOMY_PI_AGENT_DIR="${pi_home}/.pi/agent" \
    BOT_AUTONOMY_REGISTRY="$pi_only_registry" BOT_AUTONOMY_CONFIG_DIR="$module_dir" \
    PATH="${pi_stub_bin}:${SAFE_PATH}" bash "$bot_autonomy" apply >/dev/null) ||
    fail "bot-autonomy.sh apply failed dispatching the pi module against a stub pi executable"
(cd "$pi_workspace" && HOME="$pi_home" BOT_AUTONOMY_PI_AGENT_DIR="${pi_home}/.pi/agent" \
    BOT_AUTONOMY_REGISTRY="$pi_only_registry" BOT_AUTONOMY_CONFIG_DIR="$module_dir" \
    PATH="${pi_stub_bin}:${SAFE_PATH}" bash "$bot_autonomy" verify >/dev/null) ||
    fail "bot-autonomy.sh verify failed dispatching the pi module against a stub pi executable"
[ "$(find "${pi_home}/.pi" | sort)" = "$pi_dispatch_before" ] ||
    fail "dispatching pi through bot-autonomy.sh changed ~/.pi — the module's no-op contract regressed"
[ ! -s "$pi_stub_log" ] ||
    fail "the pi module invoked the pi binary (args: $(cat "$pi_stub_log")) — it must add no flag or run of its own"

echo "==> 19. oh-my-pi: fresh apply, override, unrelated keys preserved, apply->apply->restore"
omp_module="${module_dir}/oh-my-pi.sh"
omp_agent_dir="${work_dir}/omp-home/.omp/agent"
omp_config="${omp_agent_dir}/config.yml"
omp_backup="${omp_config}.harmon-init-autonomy-backup"
omp_workdir="${work_dir}/omp-workdir"
mkdir -p "$omp_workdir"

# Fresh volume: no ~/.omp/agent at all.
BOT_AUTONOMY_OMP_AGENT_DIR="$omp_agent_dir" bash "$omp_module" apply >/dev/null
[ "$(yq -r '.tools.approvalMode' "$omp_config")" = "yolo" ] ||
    fail "oh-my-pi apply did not seed tools.approvalMode=yolo on a fresh volume"
jq -e '.present == [] and .tools_prior == "absent"' "$omp_backup" >/dev/null ||
    fail "oh-my-pi apply did not record the pre-apply ABSENCE of tools.approvalMode"

# Restore removes a key that was absent before the first apply, and does not
# leave behind the `tools` mapping apply itself created.
BOT_AUTONOMY_OMP_AGENT_DIR="$omp_agent_dir" bash "$omp_module" restore >/dev/null
[ "$(yq -r 'has("tools")' "$omp_config")" = "false" ] ||
    fail "oh-my-pi restore left behind the tools mapping its own apply created"
[ ! -f "$omp_backup" ] || fail "oh-my-pi restore left its backup file behind"

# Prior non-yolo value plus unrelated keys; apply -> apply -> restore must
# return the value from before the FIRST apply.
printf 'theme: dark\ntools:\n  approvalMode: always-ask\n  other: 1\n' >"$omp_config"
BOT_AUTONOMY_OMP_AGENT_DIR="$omp_agent_dir" bash "$omp_module" apply >/dev/null
BOT_AUTONOMY_OMP_AGENT_DIR="$omp_agent_dir" bash "$omp_module" apply >/dev/null
[ "$(yq -r '.tools.approvalMode' "$omp_config")" = "yolo" ] ||
    fail "oh-my-pi apply did not override a prior always-ask approval mode"
[ "$(yq -r '.theme' "$omp_config")" = "dark" ] && [ "$(yq -r '.tools.other' "$omp_config")" = "1" ] ||
    fail "oh-my-pi apply did not preserve unrelated keys"
BOT_AUTONOMY_OMP_AGENT_DIR="$omp_agent_dir" bash "$omp_module" restore >/dev/null
[ "$(yq -r '.tools.approvalMode' "$omp_config")" = "always-ask" ] ||
    fail "oh-my-pi restore after apply->apply did not return the pre-FIRST-apply value"
[ "$(yq -r '.theme' "$omp_config")" = "dark" ] && [ "$(yq -r '.tools.other' "$omp_config")" = "1" ] ||
    fail "oh-my-pi restore did not leave unrelated keys untouched"
[ ! -f "$omp_backup" ] || fail "oh-my-pi restore left its backup file behind"

# An explicit `tools:` with no value is a DIFFERENT prior shape from
# `tools: {...}` — apply turns both into a mapping, so a boolean has()
# backup would silently upgrade the null to an empty mapping on restore
# (review round 1).
printf 'theme: dark\ntools:\n' >"$omp_config"
BOT_AUTONOMY_OMP_AGENT_DIR="$omp_agent_dir" bash "$omp_module" apply >/dev/null
[ "$(yq -r '.tools.approvalMode' "$omp_config")" = "yolo" ] ||
    fail "oh-my-pi apply did not seed yolo underneath an explicitly-null tools key"
jq -e '.tools_prior == "null"' "$omp_backup" >/dev/null ||
    fail "oh-my-pi apply did not record that tools was explicitly null before the first apply"
BOT_AUTONOMY_OMP_AGENT_DIR="$omp_agent_dir" bash "$omp_module" restore >/dev/null
[ "$(yq -r 'has("tools")' "$omp_config")" = "true" ] ||
    fail "oh-my-pi restore deleted a tools key that was present (as null) before apply"
[ "$(yq -r '.tools | type' "$omp_config")" = "!!null" ] ||
    fail "oh-my-pi restore left tools as $(yq -r '.tools | type' "$omp_config"), not the null it found"
[ "$(yq -r '.theme' "$omp_config")" = "dark" ] ||
    fail "oh-my-pi restore did not preserve unrelated keys around a null tools"
rm -f "$omp_backup" "$omp_config"

# Presence must come from has(), not from the VALUE: an explicit
# `approvalMode: null` and an explicit empty string are both keys that were
# there and must come back, byte for byte (Codex cloud review, shepherd r1).
for prior_shape in 'approvalMode: null' 'approvalMode: ""' 'other: 1'; do
    printf 'theme: dark\ntools:\n  %s\n' "$prior_shape" >"$omp_config"
    omp_before="$(cat "$omp_config")"
    BOT_AUTONOMY_OMP_AGENT_DIR="$omp_agent_dir" bash "$omp_module" apply >/dev/null
    [ "$(yq -r '.tools.approvalMode' "$omp_config")" = "yolo" ] ||
        fail "oh-my-pi apply did not seed yolo over the prior shape '${prior_shape}'"
    case "$prior_shape" in
    other:*) omp_want_present=false ;;
    *) omp_want_present=true ;;
    esac
    [ "$(jq -r '(.present // []) | any(. == "tools.approvalMode")' "$omp_backup")" = "$omp_want_present" ] ||
        fail "oh-my-pi apply recorded the wrong presence for the prior shape '${prior_shape}' — presence must come from has(), not from the value"
    BOT_AUTONOMY_OMP_AGENT_DIR="$omp_agent_dir" bash "$omp_module" restore >/dev/null
    [ "$(cat "$omp_config")" = "$omp_before" ] ||
        fail "oh-my-pi apply->restore did not return '${prior_shape}' byte-for-byte; got: $(cat "$omp_config")"
    [ ! -f "$omp_backup" ] || fail "oh-my-pi restore left its backup behind for '${prior_shape}'"
done
rm -f "$omp_config"

# A SCALAR tools value cannot hold a policy: yq's assignment into it is a
# silent no-op that still exits 0, so apply must refuse rather than report
# success having written nothing.
printf 'theme: dark\ntools: 3\n' >"$omp_config"
if BOT_AUTONOMY_OMP_AGENT_DIR="$omp_agent_dir" bash "$omp_module" apply >/dev/null 2>&1; then
    fail "oh-my-pi apply reported success against a scalar tools value it cannot write a policy underneath"
fi
[ "$(yq -r '.tools' "$omp_config")" = "3" ] ||
    fail "oh-my-pi apply modified a scalar tools value instead of refusing"
[ ! -f "$omp_backup" ] ||
    fail "oh-my-pi apply wrote a backup for a config it refused to modify"
rm -f "$omp_config"

# restore must guard the CURRENT shape exactly as apply does: the file can
# change between apply and restore, and a scalar `tools` would swallow the
# write silently, leaving the operator with neither their prior value nor the
# backup that held it (Codex cloud review, shepherd r2).
printf 'theme: dark\ntools:\n  approvalMode: always-ask\n' >"$omp_config"
BOT_AUTONOMY_OMP_AGENT_DIR="$omp_agent_dir" bash "$omp_module" apply >/dev/null
[ -f "$omp_backup" ] || fail "fixture setup: expected a backup after apply"
printf 'theme: dark\ntools: 3\n' >"$omp_config"
omp_before="$(cat "$omp_config")"
if BOT_AUTONOMY_OMP_AGENT_DIR="$omp_agent_dir" bash "$omp_module" restore >/dev/null 2>&1; then
    fail "oh-my-pi restore reported success against a scalar tools node it cannot write underneath"
fi
[ -f "$omp_backup" ] ||
    fail "oh-my-pi restore discarded its backup after refusing a scalar tools node — the prior value would be lost outright"
[ "$(cat "$omp_config")" = "$omp_before" ] ||
    fail "oh-my-pi restore modified a config whose tools node it had just refused"
rm -f "$omp_backup" "$omp_config"

# A config file in a shape this module must not rewrite blindly.
printf -- '- not\n- a mapping\n' >"$omp_config"
if BOT_AUTONOMY_OMP_AGENT_DIR="$omp_agent_dir" bash "$omp_module" apply >/dev/null 2>&1; then
    fail "oh-my-pi apply rewrote a config.yml that is not a YAML mapping"
fi
# Restore fails loudly against that same file and keeps its backup.
printf 'tools:\n  approvalMode: yolo\n' >"$omp_config"
BOT_AUTONOMY_OMP_AGENT_DIR="$omp_agent_dir" bash "$omp_module" apply >/dev/null
printf -- '- not\n- a mapping\n' >"$omp_config"
if BOT_AUTONOMY_OMP_AGENT_DIR="$omp_agent_dir" bash "$omp_module" restore >/dev/null 2>&1; then
    fail "oh-my-pi restore reported success against a config.yml that is not a YAML mapping"
fi
[ -f "$omp_backup" ] ||
    fail "oh-my-pi restore discarded its backup after failing against an invalid config.yml"
rm -f "$omp_backup" "$omp_config"

# A captured value comes off disk, so restore must treat it as data, never as
# part of the yq expression — a hand-edited backup must not be able to rewrite
# keys this module does not manage.
printf 'theme: dark\n' >"$omp_config"
BOT_AUTONOMY_OMP_AGENT_DIR="$omp_agent_dir" bash "$omp_module" apply >/dev/null
jq '.present = ["tools.approvalMode"] | .values = {"tools.approvalMode": "\" | .theme = \"pwned"}' \
    "$omp_backup" >"${omp_backup}.tmp" && mv "${omp_backup}.tmp" "$omp_backup"
BOT_AUTONOMY_OMP_AGENT_DIR="$omp_agent_dir" bash "$omp_module" restore >/dev/null
[ "$(yq -r '.theme' "$omp_config")" = "dark" ] ||
    fail "oh-my-pi restore let a captured value execute as part of the yq expression (theme was rewritten)"
[ "$(yq -r '.tools.approvalMode' "$omp_config")" = '" | .theme = "pwned' ] ||
    fail "oh-my-pi restore did not put the captured value back literally"
rm -f "$omp_backup" "$omp_config"

echo "==> 19b. oh-my-pi: verify reads the harness's own RESOLVED value, not the global file"
# `omp config get tools.approvalMode --json` is the resolved-value surface
# (confirmed against the installed omp v18.1.2). A stub stands in for it here
# so the layering contract is exercised without the binary; section 19c uses
# the real CLI when the image actually ships it.
omp_stub_bin="${work_dir}/omp-stub-bin"
mkdir -p "$omp_stub_bin"
cat >"${omp_stub_bin}/omp" <<'OMP_STUB'
#!/usr/bin/env bash
# Mimics oh-my-pi's own precedence: <cwd>/.omp/config.yml over the global file.
set -euo pipefail
[ "${1:-} ${2:-} ${3:-}" = "config get tools.approvalMode" ] || exit 64
mode=""
if [ -f "./.omp/config.yml" ]; then
    mode="$(yq -r '.tools.approvalMode // ""' ./.omp/config.yml)"
fi
if [ -z "$mode" ] && [ -f "${OMP_STUB_GLOBAL:?}" ]; then
    mode="$(yq -r '.tools.approvalMode // ""' "$OMP_STUB_GLOBAL")"
fi
[ -n "$mode" ] || mode=yolo
printf '{"key":"tools.approvalMode","value":"%s","type":"enum"}\n' "$mode"
OMP_STUB
chmod +x "${omp_stub_bin}/omp"
omp_verify_env=(
    BOT_AUTONOMY_OMP_AGENT_DIR="$omp_agent_dir"
    BOT_AUTONOMY_OMP_WORKDIR="$omp_workdir"
    OMP_STUB_GLOBAL="$omp_config"
    PATH="${omp_stub_bin}:${SAFE_PATH}"
)
env "${omp_verify_env[@]}" bash "$omp_module" apply >/dev/null
env "${omp_verify_env[@]}" bash "$omp_module" verify >/dev/null ||
    fail "oh-my-pi verify failed against a correctly-applied global yolo config"
# A project-level override must not be silently missed, and must be NAMED.
mkdir -p "${omp_workdir}/.omp"
printf 'tools:\n  approvalMode: always-ask\n' >"${omp_workdir}/.omp/config.yml"
omp_out="$(env "${omp_verify_env[@]}" bash "$omp_module" verify 2>&1)" && omp_rc=0 || omp_rc=$?
[ "${omp_rc:-0}" -ne 0 ] ||
    fail "oh-my-pi verify did not notice a project-level .omp/config.yml overriding the global default"
case "$omp_out" in
*"${omp_workdir}/.omp/config.yml"*) ;;
*) fail "oh-my-pi verify's failure did not name the project-level file as the cause: ${omp_out}" ;;
esac
rm -rf "${omp_workdir}/.omp"
env "${omp_verify_env[@]}" bash "$omp_module" verify >/dev/null ||
    fail "oh-my-pi verify still failed after the project-level override was removed"
# A global file that drifted off yolo fails and names the global file.
printf 'tools:\n  approvalMode: write\n' >"$omp_config"
omp_out="$(env "${omp_verify_env[@]}" bash "$omp_module" verify 2>&1)" && omp_rc=0 || omp_rc=$?
[ "${omp_rc:-0}" -ne 0 ] ||
    fail "oh-my-pi verify passed a global approval mode of 'write'"
case "$omp_out" in
*"$omp_config"*) ;;
*) fail "oh-my-pi verify's failure did not name the global config as the cause: ${omp_out}" ;;
esac

echo "==> 19c. oh-my-pi: the real omp CLI agrees with the stub's resolution contract"
if command -v omp >/dev/null 2>&1; then
    omp_real_home="${work_dir}/omp-real-home"
    mkdir -p "${omp_real_home}/.omp/agent" "${work_dir}/omp-real-workdir"
    HOME="$omp_real_home" BOT_AUTONOMY_OMP_AGENT_DIR="${omp_real_home}/.omp/agent" \
        bash "$omp_module" apply >/dev/null
    HOME="$omp_real_home" BOT_AUTONOMY_OMP_AGENT_DIR="${omp_real_home}/.omp/agent" \
        BOT_AUTONOMY_OMP_WORKDIR="${work_dir}/omp-real-workdir" \
        bash "$omp_module" verify >/dev/null ||
        fail "oh-my-pi verify failed against the real omp CLI after a correct apply"
    mkdir -p "${work_dir}/omp-real-workdir/.omp"
    printf 'tools:\n  approvalMode: always-ask\n' >"${work_dir}/omp-real-workdir/.omp/config.yml"
    if HOME="$omp_real_home" BOT_AUTONOMY_OMP_AGENT_DIR="${omp_real_home}/.omp/agent" \
        BOT_AUTONOMY_OMP_WORKDIR="${work_dir}/omp-real-workdir" \
        bash "$omp_module" verify >/dev/null 2>&1; then
        fail "oh-my-pi verify did not notice a project-level override through the REAL omp CLI"
    fi
    rm -rf "${work_dir}/omp-real-workdir/.omp"
else
    echo "    (omp CLI not on PATH; skipping real-binary verify sub-checks)"
fi

echo "==> 20. every new slug resolves to real coverage with its executable installed"
# The reverse of section 5: with a fake executable on PATH, each of the three
# now dispatches its own module instead of failing as an uncovered harness —
# and a deliberately-reintroduced stale unsupported entry still fails.
new_harness_registry="${work_dir}/registry-new-harnesses.json"
jq -n '{harnesses: [{slug: "copilot-cli"}, {slug: "pi"}, {slug: "oh-my-pi"}]}' >"$new_harness_registry"
nh_bin="${work_dir}/new-harness-bin"
nh_home="${work_dir}/new-harness-home"
nh_workdir="${work_dir}/new-harness-workdir"
mkdir -p "$nh_bin" "${nh_home}/.local/bin" "$nh_workdir"
printf '#!/bin/sh\necho REAL "$@"\n' >"${nh_bin}/copilot"
printf '#!/bin/sh\nexit 0\n' >"${nh_bin}/pi"
cp "${omp_stub_bin}/omp" "${nh_bin}/omp"
chmod +x "${nh_bin}/copilot" "${nh_bin}/pi" "${nh_bin}/omp"
nh_env=(
    HOME="$nh_home"
    BOT_AUTONOMY_REGISTRY="$new_harness_registry"
    BOT_AUTONOMY_CONFIG_DIR="$module_dir"
    BOT_AUTONOMY_OMP_AGENT_DIR="${nh_home}/.omp/agent"
    BOT_AUTONOMY_OMP_WORKDIR="$nh_workdir"
    OMP_STUB_GLOBAL="${nh_home}/.omp/agent/config.yml"
    BOT_AUTONOMY_PI_AGENT_DIR="${nh_home}/.pi/agent"
    BOT_AUTONOMY_COPILOT_LINK="${nh_home}/.local/bin/copilot"
    BOT_AUTONOMY_COPILOT_SETTINGS="${nh_home}/.copilot/settings.json"
    HARMON_BOT_AUTONOMY_COPILOT=enabled
    COPILOT_ALLOW_ALL=true
    PATH="${nh_bin}:${SAFE_PATH}"
)
(cd "$nh_workdir" && env "${nh_env[@]}" bash "$bot_autonomy" apply >/dev/null) ||
    fail "bot-autonomy.sh apply failed with copilot/pi/omp all installed"
(cd "$nh_workdir" && env "${nh_env[@]}" bash "$bot_autonomy" verify >/dev/null) ||
    fail "bot-autonomy.sh verify failed with copilot/pi/omp all installed and their modules applied"
[ "$(yq -r '.tools.approvalMode' "${nh_home}/.omp/agent/config.yml")" = "yolo" ] ||
    fail "dispatching oh-my-pi through bot-autonomy.sh did not apply yolo"
[ -f "${nh_home}/.local/bin/copilot" ] ||
    fail "dispatching copilot-cli through bot-autonomy.sh did not install the wrapper"

# A stale unsupported entry alongside the real module is exactly the
# double-coverage state task 4.1 forbids, transiently or otherwise.
stale_dir="${work_dir}/stale-unsupported-config"
mkdir -p "$stale_dir"
cp "${module_dir}"/*.sh "${module_dir}/aliases.json" "$stale_dir/"
jq '. + {"copilot-cli": {"executable": "copilot", "reason": "stale placeholder"}, "pi": {"executable": "pi", "reason": "stale placeholder"}, "oh-my-pi": {"executable": "omp", "reason": "stale placeholder"}}' \
    "${module_dir}/unsupported.json" >"${stale_dir}/unsupported.json"
if BOT_AUTONOMY_REGISTRY="$new_harness_registry" BOT_AUTONOMY_CONFIG_DIR="$stale_dir" \
    bash "$bot_autonomy" coverage >/dev/null 2>&1; then
    fail "coverage passed with copilot-cli/pi/oh-my-pi covered by BOTH a module and a stale unsupported entry"
fi

echo "==> 21. ensure-antigravity-cli.sh: the system-binary-sufficient early return reconciles only a leftover agy that would break a later replacement (#1171)"
ensure_script="${repo_root}/.devcontainer/config/ensure-antigravity-cli.sh"
[ -f "$ensure_script" ] || fail "ensure-antigravity-cli.sh missing at ${ensure_script}"
agy21_sys_bin="${work_dir}/agy21-system-binary"
printf '#!/bin/sh\necho 1.1.11\n' >"$agy21_sys_bin"
chmod +x "$agy21_sys_bin"
# Every fixture below leaves ~/.local/bin/agy-real absent, so `[ -x "$real_bin" ]`
# is false and the script falls through to the system-binary-sufficient early
# return being exercised here — never the "reconcile an existing local copy"
# branch above it.
agy21_run() {
    HOME="$1" HARMON_BOT_AUTONOMY_ANTIGRAVITY=enabled \
        HARMON_ANTIGRAVITY_SYSTEM_BINARY="$agy21_sys_bin" bash "$ensure_script" >/dev/null
}

# A dangling symlink (agy-real removed some other way, or never existed) is
# exactly the invariant violation #1171 exists to close.
agy21_dangling_home="${work_dir}/agy21-dangling-home"
mkdir -p "${agy21_dangling_home}/.local/bin"
ln -s "${agy21_dangling_home}/.local/bin/agy-real" "${agy21_dangling_home}/.local/bin/agy"
agy21_run "$agy21_dangling_home"
[ ! -L "${agy21_dangling_home}/.local/bin/agy" ] && [ ! -e "${agy21_dangling_home}/.local/bin/agy" ] ||
    fail "the system-binary-sufficient early return left a dangling agy symlink in place"

# Removing a dangling launcher also retires any stale ownership proof for that
# pathname. Otherwise a later independent symlink could be judged using proof
# from the removed generation.
agy21_owned_dangling_home="${work_dir}/agy21-owned-dangling-home"
mkdir -p "${agy21_owned_dangling_home}/.local/bin"
ln -s "${agy21_owned_dangling_home}/.local/bin/agy-real" \
    "${agy21_owned_dangling_home}/.local/bin/agy"
printf 'stale proof for removed launcher\n' \
    >"${agy21_owned_dangling_home}/.local/bin/.agy.harmon-init-owned"
agy21_run "$agy21_owned_dangling_home"
[ ! -L "${agy21_owned_dangling_home}/.local/bin/agy" ] &&
    [ ! -e "${agy21_owned_dangling_home}/.local/bin/.agy.harmon-init-owned" ] ||
    fail "the system-binary-sufficient early return left stale launcher ownership proof"

# A symlink to an existing DIRECTORY is not dangling, but bot-autonomy/
# antigravity.sh's install_wrapper does \`mv -f \$tmp \$AGY_LINK\`, which lands
# INSIDE an existing directory target instead of replacing the link — this
# must be reconciled here too, before install_wrapper ever runs.
agy21_dir_home="${work_dir}/agy21-dir-home"
mkdir -p "${agy21_dir_home}/.local/bin/some-directory"
ln -s "${agy21_dir_home}/.local/bin/some-directory" "${agy21_dir_home}/.local/bin/agy"
agy21_run "$agy21_dir_home"
[ ! -L "${agy21_dir_home}/.local/bin/agy" ] && [ ! -e "${agy21_dir_home}/.local/bin/agy" ] ||
    fail "the system-binary-sufficient early return left a symlink-to-directory agy in place"
[ -d "${agy21_dir_home}/.local/bin/some-directory" ] ||
    fail "removing the agy symlink also removed the directory its target named"

# A previously-installed, genuinely valid wrapper (installed by a real
# antigravity.sh apply, exactly as a container rebuild would find it in the
# persistent volume) must survive byte-for-byte: this branch installs
# nothing to replace it with, and the #1168 revert's own defect was deleting
# a still-valid wrapper before its replacement existed.
agy21_wrapper_home="${work_dir}/agy21-wrapper-home"
mkdir -p "${agy21_wrapper_home}/.local/bin"
HOME="$agy21_wrapper_home" HARMON_BOT_AUTONOMY_ANTIGRAVITY=enabled \
    BOT_AUTONOMY_ANTIGRAVITY_SETTINGS="${agy21_wrapper_home}/.gemini/antigravity-cli/settings.json" \
    bash "$agy_module" apply >/dev/null
[ -f "${agy21_wrapper_home}/.local/bin/agy" ] ||
    fail "fixture setup: expected a real wrapper installed before exercising the early return"
agy21_wrapper_before="$(cat "${agy21_wrapper_home}/.local/bin/agy")"
agy21_run "$agy21_wrapper_home"
[ -e "${agy21_wrapper_home}/.local/bin/agy" ] ||
    fail "the system-binary-sufficient early return deleted a previously-installed valid wrapper"
[ ! -L "${agy21_wrapper_home}/.local/bin/agy" ] ||
    fail "the system-binary-sufficient early return replaced a valid wrapper with a symlink"
[ "$(cat "${agy21_wrapper_home}/.local/bin/agy")" = "$agy21_wrapper_before" ] ||
    fail "the system-binary-sufficient early return modified a valid wrapper's content"

# An arbitrary regular file that is NOT the wrapper (a foreign or stale file)
# is left alone too — this branch does not distinguish a "valid" regular
# file from any other; it only ever removes a symlink.
agy21_file_home="${work_dir}/agy21-file-home"
mkdir -p "${agy21_file_home}/.local/bin"
printf 'not a wrapper, just a stray file\n' >"${agy21_file_home}/.local/bin/agy"
chmod 0644 "${agy21_file_home}/.local/bin/agy"
agy21_file_before="$(cat "${agy21_file_home}/.local/bin/agy")"
agy21_run "$agy21_file_home"
[ -f "${agy21_file_home}/.local/bin/agy" ] && [ ! -L "${agy21_file_home}/.local/bin/agy" ] ||
    fail "the system-binary-sufficient early return removed an arbitrary regular file at agy"
[ "$(cat "${agy21_file_home}/.local/bin/agy")" = "$agy21_file_before" ] ||
    fail "the system-binary-sufficient early return modified an arbitrary regular file at agy"

# A symlink whose target EXISTS (a file, not a directory) is the negative
# case the dangling/directory guards must not over-match: mutation-testing
# a guard that removed every symlink unconditionally needs this fixture to
# fail, since fixtures A and B alone cannot tell "removes only the two
# breaking shapes" apart from "removes every symlink".
agy21_symfile_home="${work_dir}/agy21-symfile-home"
mkdir -p "${agy21_symfile_home}/.local/bin"
printf '#!/bin/sh\necho REAL\n' >"${agy21_symfile_home}/.local/bin/some-other-file"
chmod +x "${agy21_symfile_home}/.local/bin/some-other-file"
ln -s "${agy21_symfile_home}/.local/bin/some-other-file" "${agy21_symfile_home}/.local/bin/agy"
agy21_run "$agy21_symfile_home"
[ -L "${agy21_symfile_home}/.local/bin/agy" ] ||
    fail "the system-binary-sufficient early return replaced a symlink to an existing file"
[ "$(readlink "${agy21_symfile_home}/.local/bin/agy")" = "${agy21_symfile_home}/.local/bin/some-other-file" ] ||
    fail "the system-binary-sufficient early return repointed a symlink to an existing file"

# A symlink whose target exists but is NOT executable is still "a symlink to
# an existing file" per the guard — it is a tamper-only shape (every write
# path in this script installs agy-real at mode 0755) that #1171's own
# acceptance criteria scope out of this fix, and PATH search itself skips a
# non-executable match and falls through to the real system binary (verified
# separately; not this script's concern) rather than being silently
# misdirected. Confirms the guard keys off dangling-or-directory, never
# executability.
agy21_symfile_noexec_home="${work_dir}/agy21-symfile-noexec-home"
mkdir -p "${agy21_symfile_noexec_home}/.local/bin"
printf '#!/bin/sh\necho REAL\n' >"${agy21_symfile_noexec_home}/.local/bin/agy-real"
chmod -x "${agy21_symfile_noexec_home}/.local/bin/agy-real"
ln -s "${agy21_symfile_noexec_home}/.local/bin/agy-real" "${agy21_symfile_noexec_home}/.local/bin/agy"
agy21_run "$agy21_symfile_noexec_home"
[ -L "${agy21_symfile_noexec_home}/.local/bin/agy" ] ||
    fail "the system-binary-sufficient early return replaced a symlink to an existing but non-executable file"
[ "$(readlink "${agy21_symfile_noexec_home}/.local/bin/agy")" = "${agy21_symfile_noexec_home}/.local/bin/agy-real" ] ||
    fail "the system-binary-sufficient early return repointed a symlink to an existing but non-executable file"

echo "==> 22. antigravity.sh: a settings-apply failure aborts BEFORE install_wrapper, so the prior valid wrapper survives"
agy22_home="${work_dir}/agy22-survive-home"
mkdir -p "${agy22_home}/.local/bin"
HOME="$agy22_home" HARMON_BOT_AUTONOMY_ANTIGRAVITY=enabled \
    BOT_AUTONOMY_ANTIGRAVITY_SETTINGS="${agy22_home}/.gemini/antigravity-cli/settings.json" \
    bash "$agy_module" apply >/dev/null
[ -f "${agy22_home}/.local/bin/agy" ] ||
    fail "fixture setup: expected a real wrapper installed before simulating a settings-apply failure"
agy22_before="$(cat "${agy22_home}/.local/bin/agy")"
agy22_failing_apply="${work_dir}/agy22-failing-apply-antigravity-settings.sh"
printf '#!/bin/sh\necho "simulated settings-apply failure" >&2\nexit 1\n' >"$agy22_failing_apply"
chmod +x "$agy22_failing_apply"
if HOME="$agy22_home" HARMON_BOT_AUTONOMY_ANTIGRAVITY=enabled \
    BOT_AUTONOMY_ANTIGRAVITY_APPLY_SCRIPT="$agy22_failing_apply" \
    BOT_AUTONOMY_ANTIGRAVITY_SETTINGS="${agy22_home}/.gemini/antigravity-cli/settings.json" \
    bash "$agy_module" apply >/dev/null 2>&1; then
    fail "antigravity apply reported success despite a failing settings-apply step"
fi
[ -e "${agy22_home}/.local/bin/agy" ] ||
    fail "a settings-apply failure deleted the prior valid wrapper before install_wrapper ever ran"
[ ! -L "${agy22_home}/.local/bin/agy" ] ||
    fail "a settings-apply failure left agy as a symlink instead of the prior wrapper"
[ "$(cat "${agy22_home}/.local/bin/agy")" = "$agy22_before" ] ||
    fail "a settings-apply failure modified the prior valid wrapper's content before aborting"

echo "==> 23. apply-antigravity-settings.sh: managed top-level keys replace nested values atomically"
agy23_home="${work_dir}/agy23-atomic-settings-home"
agy23_settings="${agy23_home}/.gemini/antigravity-cli/settings.json"
agy23_apply="${repo_root}/.devcontainer/config/apply-antigravity-settings.sh"
agy23_defaults="${repo_root}/.devcontainer/config/antigravity-settings.json"
agy23_workspace="${work_dir}/agy23-workspace"
mkdir -p "$(dirname "$agy23_settings")"
printf '%s\n' '{"model":"keep","permissions":{"bash":"deny","nested":{"stale":true}},"statusLine":{"command":"stale","nested":{"stale":true}},"unmanaged":{"nested":{"keep":true}}}' >"$agy23_settings"
HOME="$agy23_home" bash "$agy23_apply" apply "$agy23_defaults" "$agy23_workspace" >/dev/null
jq -e '
    .model == "keep" and
    .permissions == {} and
    .statusLine == {
        "type": "command",
        "command": "/etc/claude-code/statusline.sh",
        "enabled": true,
        "stack_with_default": true
    } and
    .unmanaged == {"nested":{"keep":true}}
' "$agy23_settings" >/dev/null ||
    fail "managed Antigravity settings retained stale nested values or changed an unmanaged key"
HOME="$agy23_home" bash "$agy23_apply" restore >/dev/null
jq -e '
    .permissions == {"bash":"deny","nested":{"stale":true}} and
    .statusLine == {"command":"stale","nested":{"stale":true}} and
    .unmanaged == {"nested":{"keep":true}}
' "$agy23_settings" >/dev/null ||
    fail "restoring Antigravity settings did not recover the original nested managed values"

echo "==> 24. ensure-antigravity-cli.sh: launcher and executable ownership are independent"
# The natural agy -> agy-real target is not ownership proof. An independently
# installed launcher with exactly that shape must survive cleanup and pass
# disabled verification when no launcher proof exists.
agy24_link_home="${work_dir}/agy24-independent-natural-link-home"
mkdir -p "${agy24_link_home}/.local/bin"
printf 'independent compatibility binary\n' >"${agy24_link_home}/.local/bin/agy-real"
ln -s "${agy24_link_home}/.local/bin/agy-real" "${agy24_link_home}/.local/bin/agy"
HOME="$agy24_link_home" HARMON_BOT_AUTONOMY_ANTIGRAVITY=disabled \
    bash "$agy_module" verify >/dev/null ||
    fail "disabled verify rejected an unowned natural agy -> agy-real symlink"
HOME="$agy24_link_home" HARMON_BOT_AUTONOMY_ANTIGRAVITY=disabled bash "$ensure_script" >/dev/null
[ "$(cat "${agy24_link_home}/.local/bin/agy-real")" = "independent compatibility binary" ] &&
    [ -L "${agy24_link_home}/.local/bin/agy" ] &&
    [ "$(readlink "${agy24_link_home}/.local/bin/agy")" = "${agy24_link_home}/.local/bin/agy-real" ] ||
    fail "disabled cleanup modified an unowned natural agy -> agy-real symlink"

# The bot-autonomy module's marker proves ownership of its regular wrapper.
agy24_wrapper_home="${work_dir}/agy24-managed-wrapper-home"
mkdir -p "${agy24_wrapper_home}/.local/bin"
printf '#!/bin/sh\necho REAL\n' >"${agy24_wrapper_home}/.local/bin/agy-real"
chmod +x "${agy24_wrapper_home}/.local/bin/agy-real"
HOME="$agy24_wrapper_home" HARMON_BOT_AUTONOMY_ANTIGRAVITY=enabled \
    BOT_AUTONOMY_ANTIGRAVITY_SETTINGS="${agy24_wrapper_home}/.gemini/antigravity-cli/settings.json" \
    bash "$agy_module" apply >/dev/null
[ -f "${agy24_wrapper_home}/.local/bin/.agy.harmon-init-owned" ] ||
    fail "wrapper apply did not publish independent launcher ownership proof"
if HOME="$agy24_wrapper_home" HARMON_BOT_AUTONOMY_ANTIGRAVITY=disabled \
    bash "$agy_module" verify >/dev/null 2>&1; then
    fail "disabled verify accepted an independently proven managed Antigravity wrapper"
fi
HOME="$agy24_wrapper_home" HARMON_BOT_AUTONOMY_ANTIGRAVITY=disabled bash "$ensure_script" >/dev/null
[ "$("${agy24_wrapper_home}/.local/bin/agy-real")" = "REAL" ] &&
    [ ! -e "${agy24_wrapper_home}/.local/bin/agy" ] &&
    [ ! -e "${agy24_wrapper_home}/.local/bin/.agy.harmon-init-owned" ] ||
    fail "disabled cleanup did not remove only the independently proven managed Antigravity wrapper"

# A system-binary-only enabled run installs a wrapper but no local executable
# or ownership proof. If a user later supplies agy-real, disabling may remove
# the wrapper but must preserve that independently created executable.
agy24_system_home="${work_dir}/agy24-system-only-home"
agy24_system_bin="${agy24_system_home}/system-agy"
mkdir -p "${agy24_system_home}/.local/bin"
printf '#!/bin/sh\nprintf "1.1.11\\n"\n' >"$agy24_system_bin"
chmod +x "$agy24_system_bin"
HOME="$agy24_system_home" HARMON_BOT_AUTONOMY_ANTIGRAVITY=enabled \
    HARMON_ANTIGRAVITY_SYSTEM_BINARY="$agy24_system_bin" \
    bash "$ensure_script" >/dev/null
HOME="$agy24_system_home" HARMON_BOT_AUTONOMY_ANTIGRAVITY=enabled \
    HARMON_ANTIGRAVITY_SYSTEM_BINARY="$agy24_system_bin" \
    BOT_AUTONOMY_ANTIGRAVITY_SETTINGS="${agy24_system_home}/.gemini/antigravity-cli/settings.json" \
    bash "$agy_module" apply >/dev/null
[ ! -e "${agy24_system_home}/.local/bin/.agy-real.harmon-init-owned" ] ||
    fail "system-binary-only install unexpectedly claimed a local agy-real"
[ -f "${agy24_system_home}/.local/bin/.agy.harmon-init-owned" ] ||
    fail "system-binary-only wrapper did not publish launcher ownership proof"
printf '#!/bin/sh\nprintf "independent\\n"\n' >"${agy24_system_home}/.local/bin/agy-real"
chmod +x "${agy24_system_home}/.local/bin/agy-real"
HOME="$agy24_system_home" HARMON_BOT_AUTONOMY_ANTIGRAVITY=disabled \
    bash "$ensure_script" >/dev/null
[ ! -e "${agy24_system_home}/.local/bin/agy" ] &&
    [ ! -e "${agy24_system_home}/.local/bin/.agy.harmon-init-owned" ] &&
    [ "$("${agy24_system_home}/.local/bin/agy-real")" = "independent" ] ||
    fail "disabled cleanup deleted agy-real based only on wrapper ownership"

# Independent regular files at both reserved names carry no ownership proof.
agy24_file_home="${work_dir}/agy24-independent-files-home"
mkdir -p "${agy24_file_home}/.local/bin"
printf 'independent real\n' >"${agy24_file_home}/.local/bin/agy-real"
printf 'independent launcher\n' >"${agy24_file_home}/.local/bin/agy"
HOME="$agy24_file_home" HARMON_BOT_AUTONOMY_ANTIGRAVITY=disabled bash "$ensure_script" >/dev/null
[ "$(cat "${agy24_file_home}/.local/bin/agy-real")" = "independent real" ] &&
    [ "$(cat "${agy24_file_home}/.local/bin/agy")" = "independent launcher" ] ||
    fail "disabled cleanup modified independent regular files"
HOME="$agy24_file_home" HARMON_BOT_AUTONOMY_ANTIGRAVITY=disabled \
    bash "$agy_module" verify >/dev/null ||
    fail "disabled verify rejected independent regular launcher files"

# An independent symlink and an orphan agy-real are likewise not evidence that
# this module owns either path.
agy24_symlink_home="${work_dir}/agy24-independent-symlink-home"
mkdir -p "${agy24_symlink_home}/.local/bin"
printf 'independent real\n' >"${agy24_symlink_home}/.local/bin/agy-real"
printf 'independent target\n' >"${agy24_symlink_home}/.local/bin/other-agy"
ln -s "${agy24_symlink_home}/.local/bin/other-agy" "${agy24_symlink_home}/.local/bin/agy"
HOME="$agy24_symlink_home" HARMON_BOT_AUTONOMY_ANTIGRAVITY=disabled bash "$ensure_script" >/dev/null
[ -f "${agy24_symlink_home}/.local/bin/agy-real" ] &&
    [ -L "${agy24_symlink_home}/.local/bin/agy" ] &&
    [ "$(readlink "${agy24_symlink_home}/.local/bin/agy")" = "${agy24_symlink_home}/.local/bin/other-agy" ] ||
    fail "disabled cleanup modified an independent symlink or agy-real file"
HOME="$agy24_symlink_home" HARMON_BOT_AUTONOMY_ANTIGRAVITY=disabled \
    bash "$agy_module" verify >/dev/null ||
    fail "disabled verify rejected an independent launcher symlink"

# An exact-version agy-real symlink is compatible but unowned. Enabled setup may
# point agy at it, but must not replace the symlink or publish ownership proof;
# disabled cleanup consequently removes only the managed launcher.
agy24_exact_link_home="${work_dir}/agy24-exact-version-link-home"
agy24_exact_target="${agy24_exact_link_home}/external/agy"
mkdir -p "${agy24_exact_link_home}/.local/bin" "$(dirname "$agy24_exact_target")"
printf '#!/bin/sh\nprintf "1.1.11\\n"\n' >"$agy24_exact_target"
chmod +x "$agy24_exact_target"
ln -s "$agy24_exact_target" "${agy24_exact_link_home}/.local/bin/agy-real"
HOME="$agy24_exact_link_home" HARMON_BOT_AUTONOMY_ANTIGRAVITY=enabled \
    HARMON_ANTIGRAVITY_SYSTEM_BINARY=/nonexistent bash "$ensure_script" >/dev/null
[ -L "${agy24_exact_link_home}/.local/bin/agy-real" ] &&
    [ "$(readlink "${agy24_exact_link_home}/.local/bin/agy-real")" = "$agy24_exact_target" ] &&
    [ ! -e "${agy24_exact_link_home}/.local/bin/.agy-real.harmon-init-owned" ] ||
    fail "enabled setup replaced or claimed an unowned exact-version agy-real symlink"
HOME="$agy24_exact_link_home" HARMON_BOT_AUTONOMY_ANTIGRAVITY=disabled \
    bash "$ensure_script" >/dev/null
[ -L "${agy24_exact_link_home}/.local/bin/agy-real" ] &&
    [ "$(readlink "${agy24_exact_link_home}/.local/bin/agy-real")" = "$agy24_exact_target" ] &&
    [ ! -e "${agy24_exact_link_home}/.local/bin/agy" ] ||
    fail "disabled cleanup removed an unowned exact-version agy-real symlink"

# The installer publishes identity-and-content proof for both managed paths.
# If the launcher is later lost, disabled verification still fails closed and
# cleanup removes the independently proven executable without guessing from
# its filename or version.
agy24_interrupted_home="${work_dir}/agy24-interrupted-install-home"
agy24_interrupted_system="${agy24_interrupted_home}/system-agy"
mkdir -p "${agy24_interrupted_home}/.local/bin"
printf '#!/bin/sh\nprintf "old\\n"\n' >"${agy24_interrupted_home}/.local/bin/agy-real"
chmod +x "${agy24_interrupted_home}/.local/bin/agy-real"
printf '#!/bin/sh\nprintf "1.1.11\\n"\n' >"$agy24_interrupted_system"
chmod +x "$agy24_interrupted_system"
HOME="$agy24_interrupted_home" HARMON_BOT_AUTONOMY_ANTIGRAVITY=enabled \
    HARMON_ANTIGRAVITY_SYSTEM_BINARY="$agy24_interrupted_system" \
    bash "$ensure_script" >/dev/null
[ -f "${agy24_interrupted_home}/.local/bin/.agy-real.harmon-init-owned" ] &&
    grep -q '^type=file$' "${agy24_interrupted_home}/.local/bin/.agy-real.harmon-init-owned" &&
    grep -q '^sha512=' "${agy24_interrupted_home}/.local/bin/.agy-real.harmon-init-owned" &&
    [ -f "${agy24_interrupted_home}/.local/bin/.agy.harmon-init-owned" ] ||
    fail "enabled install did not publish independent content proofs for agy-real and agy"
rm -f "${agy24_interrupted_home}/.local/bin/agy"
if HOME="$agy24_interrupted_home" HARMON_BOT_AUTONOMY_ANTIGRAVITY=disabled \
    bash "$agy_module" verify >/dev/null 2>&1; then
    fail "disabled verify accepted an owned orphan agy-real from an interrupted install"
fi
HOME="$agy24_interrupted_home" HARMON_BOT_AUTONOMY_ANTIGRAVITY=disabled \
    bash "$ensure_script" >/dev/null
[ ! -e "${agy24_interrupted_home}/.local/bin/agy-real" ] &&
    [ ! -e "${agy24_interrupted_home}/.local/bin/.agy-real.harmon-init-owned" ] &&
    [ ! -e "${agy24_interrupted_home}/.local/bin/.agy.harmon-init-owned" ] ||
    fail "disabled cleanup left an owned orphan or ownership proof behind"
HOME="$agy24_interrupted_home" HARMON_BOT_AUTONOMY_ANTIGRAVITY=disabled \
    bash "$agy_module" verify >/dev/null ||
    fail "disabled verify failed after cleaning an interrupted managed install"

# Rewriting an installed executable in place preserves its inode. The immutable
# content fingerprint must still revoke deletion authority, preserving the
# externally supplied bytes while cleaning stale module metadata and its owned
# launcher.
agy24_rewrite_home="${work_dir}/agy24-in-place-rewrite-home"
agy24_rewrite_system="${agy24_rewrite_home}/system-agy"
mkdir -p "${agy24_rewrite_home}/.local/bin"
printf '#!/bin/sh\nprintf "old\\n"\n' >"${agy24_rewrite_home}/.local/bin/agy-real"
printf '#!/bin/sh\nprintf "1.1.11\\n"\n' >"$agy24_rewrite_system"
chmod +x "${agy24_rewrite_home}/.local/bin/agy-real" "$agy24_rewrite_system"
HOME="$agy24_rewrite_home" HARMON_BOT_AUTONOMY_ANTIGRAVITY=enabled \
    HARMON_ANTIGRAVITY_SYSTEM_BINARY="$agy24_rewrite_system" \
    bash "$ensure_script" >/dev/null
agy24_rewrite_identity="$(stat -c '%d:%i' "${agy24_rewrite_home}/.local/bin/agy-real" 2>/dev/null ||
    stat -f '%d:%i' "${agy24_rewrite_home}/.local/bin/agy-real")"
printf '#!/bin/sh\nprintf "independent rewrite\\n"\n' >"${agy24_rewrite_home}/.local/bin/agy-real"
chmod +x "${agy24_rewrite_home}/.local/bin/agy-real"
[ "$(stat -c '%d:%i' "${agy24_rewrite_home}/.local/bin/agy-real" 2>/dev/null ||
    stat -f '%d:%i' "${agy24_rewrite_home}/.local/bin/agy-real")" = "$agy24_rewrite_identity" ] ||
    fail "in-place rewrite fixture unexpectedly replaced the agy-real inode"
HOME="$agy24_rewrite_home" HARMON_BOT_AUTONOMY_ANTIGRAVITY=disabled \
    bash "$ensure_script" >/dev/null
[ "$("${agy24_rewrite_home}/.local/bin/agy-real")" = "independent rewrite" ] &&
    [ ! -e "${agy24_rewrite_home}/.local/bin/agy" ] &&
    [ ! -e "${agy24_rewrite_home}/.local/bin/.agy-real.harmon-init-owned" ] &&
    [ ! -e "${agy24_rewrite_home}/.local/bin/.agy.harmon-init-owned" ] ||
    fail "disabled cleanup deleted an in-place rewrite or retained stale managed state"
HOME="$agy24_rewrite_home" HARMON_BOT_AUTONOMY_ANTIGRAVITY=disabled \
    bash "$agy_module" verify >/dev/null ||
    fail "disabled verify rejected the preserved in-place rewrite"

# Force the exact interrupted-upgrade window: transaction published, new
# executable published, final ownership promotion fails. The next disabled run
# must recover the transaction and remove the recognized managed executable.
agy24_upgrade_home="${work_dir}/agy24-interrupted-upgrade-home"
agy24_upgrade_system="${agy24_upgrade_home}/system-agy"
agy24_upgrade_fake_bin="${agy24_upgrade_home}/fake-bin"
agy24_upgrade_mv_count="${agy24_upgrade_home}/mv-count"
agy24_real_mv="$(command -v mv)"
mkdir -p "${agy24_upgrade_home}/.local/bin" "$agy24_upgrade_fake_bin"
printf '#!/bin/sh\nprintf "1.0.0\\n"\n' >"${agy24_upgrade_home}/.local/bin/agy-real"
chmod +x "${agy24_upgrade_home}/.local/bin/agy-real"
agy24_old_identity="$(stat -c '%d:%i' "${agy24_upgrade_home}/.local/bin/agy-real" 2>/dev/null ||
    stat -f '%d:%i' "${agy24_upgrade_home}/.local/bin/agy-real")"
agy24_old_sha="$(test_file_sha512 "${agy24_upgrade_home}/.local/bin/agy-real")"
printf 'type=file\nidentity=%s\nsha512=%s\ntemp_name=\n' \
    "$agy24_old_identity" "$agy24_old_sha" >"${agy24_upgrade_home}/.local/bin/.agy-real.harmon-init-owned"
printf '#!/bin/sh\nprintf "1.1.11\\n"\n' >"$agy24_upgrade_system"
chmod +x "$agy24_upgrade_system"
printf '%s\n' '#!/bin/sh' \
    'count=0' \
    '[ ! -f "$HARMON_TEST_MV_COUNT" ] || count=$(cat "$HARMON_TEST_MV_COUNT")' \
    'count=$((count + 1))' \
    'printf "%s\\n" "$count" >"$HARMON_TEST_MV_COUNT"' \
    '[ "$count" -ne 3 ] || exit 75' \
    'exec "$HARMON_TEST_REAL_MV" "$@"' >"${agy24_upgrade_fake_bin}/mv"
chmod +x "${agy24_upgrade_fake_bin}/mv"
if HOME="$agy24_upgrade_home" HARMON_BOT_AUTONOMY_ANTIGRAVITY=enabled \
    HARMON_ANTIGRAVITY_SYSTEM_BINARY="$agy24_upgrade_system" \
    HARMON_TEST_MV_COUNT="$agy24_upgrade_mv_count" HARMON_TEST_REAL_MV="$agy24_real_mv" \
    PATH="${agy24_upgrade_fake_bin}:${PATH}" bash "$ensure_script" >/dev/null 2>&1; then
    fail "interrupted-upgrade fixture did not stop before ownership promotion"
fi
[ -f "${agy24_upgrade_home}/.local/bin/.agy-real.harmon-init-transaction" ] &&
    [ "$("${agy24_upgrade_home}/.local/bin/agy-real")" = "1.1.11" ] ||
    fail "interrupted upgrade did not leave the recoverable new-generation state"
HOME="$agy24_upgrade_home" HARMON_BOT_AUTONOMY_ANTIGRAVITY=disabled \
    bash "$ensure_script" >/dev/null
[ ! -e "${agy24_upgrade_home}/.local/bin/agy-real" ] &&
    [ ! -e "${agy24_upgrade_home}/.local/bin/.agy-real.harmon-init-owned" ] &&
    [ ! -e "${agy24_upgrade_home}/.local/bin/.agy-real.harmon-init-transaction" ] ||
    fail "disabled cleanup did not recover and remove an interrupted managed upgrade"

# Dangling ownership/transaction symlinks are metadata presence, even though
# test -e reports false. Verification must reject them and ensure must clean
# them without following their targets.
agy24_dangling_meta_home="${work_dir}/agy24-dangling-metadata-home"
mkdir -p "${agy24_dangling_meta_home}/.local/bin"
ln -s "${agy24_dangling_meta_home}/missing-real-proof" \
    "${agy24_dangling_meta_home}/.local/bin/.agy-real.harmon-init-transaction"
ln -s "${agy24_dangling_meta_home}/missing-link-proof" \
    "${agy24_dangling_meta_home}/.local/bin/.agy.harmon-init-owned"
if HOME="$agy24_dangling_meta_home" HARMON_BOT_AUTONOMY_ANTIGRAVITY=disabled \
    bash "$agy_module" verify >/dev/null 2>&1; then
    fail "disabled verify accepted dangling Antigravity metadata symlinks"
fi
HOME="$agy24_dangling_meta_home" HARMON_BOT_AUTONOMY_ANTIGRAVITY=disabled \
    bash "$ensure_script" >/dev/null
[ ! -L "${agy24_dangling_meta_home}/.local/bin/.agy-real.harmon-init-transaction" ] &&
    [ ! -L "${agy24_dangling_meta_home}/.local/bin/.agy.harmon-init-owned" ] ||
    fail "disabled cleanup left dangling Antigravity metadata symlinks"
HOME="$agy24_dangling_meta_home" HARMON_BOT_AUTONOMY_ANTIGRAVITY=disabled \
    bash "$agy_module" verify >/dev/null ||
    fail "disabled verify failed after dangling metadata cleanup"

# Two concurrent reconciliation runs must not share or discard each other's
# fixed transaction names. Hold the first run inside its system-version probe
# (after lock acquisition), then prove the second fails closed on the lock.
agy24_concurrent_home="${work_dir}/agy24-concurrent-home"
agy24_concurrent_system="${agy24_concurrent_home}/system-agy"
agy24_concurrent_started="${agy24_concurrent_home}/started"
agy24_concurrent_release="${agy24_concurrent_home}/release"
mkdir -p "${agy24_concurrent_home}/.local/bin"
printf '#!/bin/sh\nprintf "1.0.0\\n"\n' >"${agy24_concurrent_home}/.local/bin/agy-real"
printf '%s\n' '#!/bin/sh' \
    'printf "started\\n" >"$HARMON_TEST_LOCK_STARTED"' \
    'count=0' \
    'while [ ! -e "$HARMON_TEST_LOCK_RELEASE" ]; do' \
    '    count=$((count + 1))' \
    '    [ "$count" -lt 200 ] || exit 70' \
    '    sleep 0.05' \
    'done' \
    'printf "1.1.11\\n"' >"$agy24_concurrent_system"
chmod +x "${agy24_concurrent_home}/.local/bin/agy-real" "$agy24_concurrent_system"
HOME="$agy24_concurrent_home" HARMON_BOT_AUTONOMY_ANTIGRAVITY=enabled \
    HARMON_ANTIGRAVITY_SYSTEM_BINARY="$agy24_concurrent_system" \
    HARMON_TEST_LOCK_STARTED="$agy24_concurrent_started" \
    HARMON_TEST_LOCK_RELEASE="$agy24_concurrent_release" \
    bash "$ensure_script" >/dev/null 2>&1 &
agy24_concurrent_pid=$!
agy24_wait=0
while [ ! -e "$agy24_concurrent_started" ] && [ "$agy24_wait" -lt 200 ]; do
    agy24_wait=$((agy24_wait + 1))
    sleep 0.05
done
if [ ! -e "$agy24_concurrent_started" ]; then
    touch "$agy24_concurrent_release"
    wait "$agy24_concurrent_pid" 2>/dev/null || true
    fail "concurrent reconciliation fixture never reached its locked probe"
fi
if HOME="$agy24_concurrent_home" HARMON_BOT_AUTONOMY_ANTIGRAVITY=enabled \
    HARMON_ANTIGRAVITY_SYSTEM_BINARY="$agy24_concurrent_system" \
    HARMON_TEST_LOCK_STARTED="$agy24_concurrent_started" \
    HARMON_TEST_LOCK_RELEASE="$agy24_concurrent_release" \
    bash "$ensure_script" >/dev/null 2>&1; then
    touch "$agy24_concurrent_release"
    wait "$agy24_concurrent_pid" 2>/dev/null || true
    fail "a concurrent reconciliation entered the shared transaction protocol"
fi
touch "$agy24_concurrent_release"
wait "$agy24_concurrent_pid" ||
    fail "the lock-owning reconciliation failed after its peer was refused"

# Reproduce replacement after the initial proof match but before cleanup's old
# unlink point. The atomic move must capture and revalidate that replacement,
# then restore it instead of deleting it under the stale proof.
agy24_quarantine_home="${work_dir}/agy24-quarantine-home"
agy24_quarantine_system="${agy24_quarantine_home}/system-agy"
agy24_quarantine_fake_bin="${agy24_quarantine_home}/fake-bin"
agy24_quarantine_target="${agy24_quarantine_home}/.local/bin/agy-real"
agy24_quarantine_real_mv="$(command -v mv)"
mkdir -p "${agy24_quarantine_home}/.local/bin" "$agy24_quarantine_fake_bin"
printf '#!/bin/sh\nprintf "1.0.0\\n"\n' >"$agy24_quarantine_target"
printf '#!/bin/sh\nprintf "1.1.11\\n"\n' >"$agy24_quarantine_system"
chmod +x "$agy24_quarantine_target" "$agy24_quarantine_system"
HOME="$agy24_quarantine_home" HARMON_BOT_AUTONOMY_ANTIGRAVITY=enabled \
    HARMON_ANTIGRAVITY_SYSTEM_BINARY="$agy24_quarantine_system" \
    bash "$ensure_script" >/dev/null
printf '%s\n' '#!/bin/sh' \
    'if [ "$#" -eq 3 ] && [ "$1" = "-f" ] && [ "$2" = "$HARMON_TEST_QUARANTINE_TARGET" ]; then' \
    '    case "$3" in' \
    '    "$HARMON_TEST_QUARANTINE_TARGET".harmon-init-quarantine.*)' \
    '        rm -f "$2"' \
    '        printf "independent replacement\\n" >"$2"' \
    '        ;;' \
    '    esac' \
    'fi' \
    'exec "$HARMON_TEST_REAL_MV" "$@"' >"${agy24_quarantine_fake_bin}/mv"
chmod +x "${agy24_quarantine_fake_bin}/mv"
HOME="$agy24_quarantine_home" HARMON_BOT_AUTONOMY_ANTIGRAVITY=disabled \
    HARMON_TEST_QUARANTINE_TARGET="$agy24_quarantine_target" \
    HARMON_TEST_REAL_MV="$agy24_quarantine_real_mv" \
    PATH="${agy24_quarantine_fake_bin}:${PATH}" bash "$ensure_script" >/dev/null
[ "$(cat "$agy24_quarantine_target")" = "independent replacement" ] &&
    [ ! -e "${agy24_quarantine_home}/.local/bin/.agy-real.harmon-init-owned" ] &&
    [ ! -e "${agy24_quarantine_home}/.local/bin/.agy.harmon-init-owned" ] ||
    fail "quarantine cleanup deleted a concurrent replacement or retained stale proof"
if ! agy24_quarantine_leftover="$(find "${agy24_quarantine_home}/.local/bin" -name 'agy-real.harmon-init-quarantine.*' -print -quit)"; then
    fail "could not inspect quarantine leftovers"
fi
if [ -n "$agy24_quarantine_leftover" ]; then
    fail "quarantine cleanup did not restore the captured independent replacement"
fi

# A failed quarantine move leaves the managed generation in place, so its
# still-matching proof must survive for a later cleanup retry.
agy24_quarantine_fail_home="${work_dir}/agy24-quarantine-fail-home"
agy24_quarantine_fail_system="${agy24_quarantine_fail_home}/system-agy"
agy24_quarantine_fail_bin="${agy24_quarantine_fail_home}/fake-bin"
agy24_quarantine_fail_target="${agy24_quarantine_fail_home}/.local/bin/agy-real"
mkdir -p "${agy24_quarantine_fail_home}/.local/bin" "$agy24_quarantine_fail_bin"
printf '#!/bin/sh\nprintf "1.0.0\\n"\n' >"$agy24_quarantine_fail_target"
printf '#!/bin/sh\nprintf "1.1.11\\n"\n' >"$agy24_quarantine_fail_system"
chmod +x "$agy24_quarantine_fail_target" "$agy24_quarantine_fail_system"
HOME="$agy24_quarantine_fail_home" HARMON_BOT_AUTONOMY_ANTIGRAVITY=enabled \
    HARMON_ANTIGRAVITY_SYSTEM_BINARY="$agy24_quarantine_fail_system" \
    bash "$ensure_script" >/dev/null
printf '%s\n' '#!/bin/sh' \
    'if [ "$#" -eq 3 ] && [ "$1" = "-f" ] && [ "$2" = "$HARMON_TEST_QUARANTINE_TARGET" ]; then' \
    '    case "$3" in' \
    '    "$HARMON_TEST_QUARANTINE_TARGET".harmon-init-quarantine.*) exit 74 ;;' \
    '    esac' \
    'fi' \
    'exec "$HARMON_TEST_REAL_MV" "$@"' >"${agy24_quarantine_fail_bin}/mv"
chmod +x "${agy24_quarantine_fail_bin}/mv"
if HOME="$agy24_quarantine_fail_home" HARMON_BOT_AUTONOMY_ANTIGRAVITY=disabled \
    HARMON_TEST_QUARANTINE_TARGET="$agy24_quarantine_fail_target" \
    HARMON_TEST_REAL_MV="$agy24_quarantine_real_mv" \
    PATH="${agy24_quarantine_fail_bin}:${PATH}" bash "$ensure_script" >/dev/null 2>&1; then
    fail "disabled cleanup accepted a failed managed-executable quarantine"
fi
[ -x "$agy24_quarantine_fail_target" ] &&
    [ -f "${agy24_quarantine_fail_home}/.local/bin/.agy-real.harmon-init-owned" ] ||
    fail "failed quarantine discarded the retryable executable or its ownership proof"

# If a concurrent actor publishes a symlink to a directory after quarantine,
# restore must not follow it and move captured bytes inside that directory.
agy24_dirlink_home="${work_dir}/agy24-dirlink-home"
agy24_dirlink_system="${agy24_dirlink_home}/system-agy"
agy24_dirlink_bin="${agy24_dirlink_home}/fake-bin"
agy24_dirlink_target="${agy24_dirlink_home}/.local/bin/agy-real"
agy24_dirlink_destination="${agy24_dirlink_home}/independent-directory"
agy24_dirlink_stderr="${agy24_dirlink_home}/cleanup.stderr"
mkdir -p "${agy24_dirlink_home}/.local/bin" "$agy24_dirlink_bin" "$agy24_dirlink_destination"
printf '#!/bin/sh\nprintf "1.0.0\\n"\n' >"$agy24_dirlink_target"
printf '#!/bin/sh\nprintf "1.1.11\\n"\n' >"$agy24_dirlink_system"
chmod +x "$agy24_dirlink_target" "$agy24_dirlink_system"
HOME="$agy24_dirlink_home" HARMON_BOT_AUTONOMY_ANTIGRAVITY=enabled \
    HARMON_ANTIGRAVITY_SYSTEM_BINARY="$agy24_dirlink_system" \
    bash "$ensure_script" >/dev/null
printf '%s\n' '#!/bin/sh' \
    'if [ "$#" -eq 3 ] && [ "$1" = "-f" ] && [ "$2" = "$HARMON_TEST_QUARANTINE_TARGET" ]; then' \
    '    case "$3" in' \
    '    "$HARMON_TEST_QUARANTINE_TARGET".harmon-init-quarantine.*)' \
    '        rm -f "$2"' \
    '        printf "captured independent bytes\\n" >"$2"' \
    '        "$HARMON_TEST_REAL_MV" -f "$2" "$3"' \
    '        ln -s "$HARMON_TEST_DIRECTORY_TARGET" "$2"' \
    '        exit 0' \
    '        ;;' \
    '    esac' \
    'fi' \
    'exec "$HARMON_TEST_REAL_MV" "$@"' >"${agy24_dirlink_bin}/mv"
chmod +x "${agy24_dirlink_bin}/mv"
if HOME="$agy24_dirlink_home" HARMON_BOT_AUTONOMY_ANTIGRAVITY=disabled \
    HARMON_TEST_QUARANTINE_TARGET="$agy24_dirlink_target" \
    HARMON_TEST_DIRECTORY_TARGET="$agy24_dirlink_destination" \
    HARMON_TEST_REAL_MV="$agy24_quarantine_real_mv" \
    PATH="${agy24_dirlink_bin}:${PATH}" bash "$ensure_script" >/dev/null 2>"$agy24_dirlink_stderr"; then
    fail "cleanup did not fail closed while retaining quarantined bytes"
fi
[ -L "$agy24_dirlink_target" ] &&
    [ "$(readlink "$agy24_dirlink_target")" = "$agy24_dirlink_destination" ] ||
    fail "cleanup replaced the concurrent directory symlink"
agy24_dirlink_recovery="$(find "${agy24_dirlink_home}/.local/bin" \
    -name 'agy-real.harmon-init-quarantine.*' -print -quit)"
[ -n "$agy24_dirlink_recovery" ] && [ -f "$agy24_dirlink_recovery" ] &&
    grep -Fq "$agy24_dirlink_recovery" "$agy24_dirlink_stderr" ||
    fail "cleanup did not retain and report the captured recovery path"
[ ! -e "${agy24_dirlink_destination}/$(basename "$agy24_dirlink_recovery")" ] &&
    [ ! -e "${agy24_dirlink_home}/.local/bin/.agy-real.harmon-init-owned" ] ||
    fail "cleanup followed a directory symlink or retained stale executable proof"

# A system-binary-only run retires an orphan proof before a later independent
# agy-real can occupy the pathname.
agy24_orphan_home="${work_dir}/agy24-orphan-proof-home"
mkdir -p "${agy24_orphan_home}/.local/bin"
printf 'type=file\nidentity=1:1\nsha512=stale\ntemp_name=\n' >"${agy24_orphan_home}/.local/bin/.agy-real.harmon-init-owned"
agy21_run "$agy24_orphan_home"
[ ! -e "${agy24_orphan_home}/.local/bin/.agy-real.harmon-init-owned" ] || fail "system-binary run retained orphan agy-real proof"
printf '#!/bin/sh\nprintf "independent\\n"\n' >"${agy24_orphan_home}/.local/bin/agy-real"
chmod +x "${agy24_orphan_home}/.local/bin/agy-real"
HOME="$agy24_orphan_home" HARMON_BOT_AUTONOMY_ANTIGRAVITY=disabled bash "$ensure_script" >/dev/null
[ "$("${agy24_orphan_home}/.local/bin/agy-real")" = independent ] || fail "cleanup deleted later independent agy-real"

# Recover a matching wrapper transaction before attempting a new publication.
agy24_wtx_home="${work_dir}/agy24-wrapper-transaction-home"
agy24_wtx_bin="${agy24_wtx_home}/fake-bin"
agy24_wtx_stub="${agy24_wtx_home}/settings-stub.sh"
agy24_wtx_recovered="${agy24_wtx_home}/recovered"
agy24_wtx_real_mv="$(command -v mv)"
mkdir -p "${agy24_wtx_home}/.local/bin" "$agy24_wtx_bin"
printf '#!/bin/sh\nexit 0\n' >"$agy24_wtx_stub"
chmod +x "$agy24_wtx_stub"
HOME="$agy24_wtx_home" HARMON_BOT_AUTONOMY_ANTIGRAVITY=enabled BOT_AUTONOMY_ANTIGRAVITY_APPLY_SCRIPT="$agy24_wtx_stub" bash "$agy_module" apply >/dev/null
mv "${agy24_wtx_home}/.local/bin/.agy.harmon-init-owned" "${agy24_wtx_home}/.local/bin/.agy.harmon-init-transaction"
printf '%s\n' '#!/bin/sh' \
    'if [ "$3" = "$HARMON_TEST_LINK_OWNERSHIP" ]; then touch "$HARMON_TEST_RECOVERED"; fi' \
    'if [ "$3" = "$HARMON_TEST_LINK_TRANSACTION" ]; then case "$2" in *.harmon-init-transaction.tmp.*) exit 75 ;; esac; fi' \
    'exec "$HARMON_TEST_REAL_MV" "$@"' >"${agy24_wtx_bin}/mv"
chmod +x "${agy24_wtx_bin}/mv"
if HOME="$agy24_wtx_home" HARMON_BOT_AUTONOMY_ANTIGRAVITY=enabled BOT_AUTONOMY_ANTIGRAVITY_APPLY_SCRIPT="$agy24_wtx_stub" \
    HARMON_TEST_LINK_OWNERSHIP="${agy24_wtx_home}/.local/bin/.agy.harmon-init-owned" \
    HARMON_TEST_LINK_TRANSACTION="${agy24_wtx_home}/.local/bin/.agy.harmon-init-transaction" \
    HARMON_TEST_RECOVERED="$agy24_wtx_recovered" HARMON_TEST_REAL_MV="$agy24_wtx_real_mv" \
    PATH="${agy24_wtx_bin}:${PATH}" bash "$agy_module" apply >/dev/null 2>&1; then
    fail "wrapper transaction fixture did not interrupt new publication"
fi
[ -e "$agy24_wtx_recovered" ] && [ -f "${agy24_wtx_home}/.local/bin/.agy.harmon-init-owned" ] &&
    [ ! -e "${agy24_wtx_home}/.local/bin/.agy.harmon-init-transaction" ] || fail "wrapper publisher overwrote prior transaction"

# Empty digests cannot prove ownership, and a failed hash cannot publish a wrapper.
agy24_hash_home="${work_dir}/agy24-hash-failure-home"
agy24_hash_bin="${agy24_hash_home}/fake-bin"
agy24_hash_stub="${agy24_hash_home}/settings-stub.sh"
mkdir -p "${agy24_hash_home}/.local/bin" "$agy24_hash_bin"
printf '#!/bin/sh\nprintf "independent\\n"\n' >"${agy24_hash_home}/.local/bin/agy-real"
chmod +x "${agy24_hash_home}/.local/bin/agy-real"
agy24_hash_identity="$(stat -c '%d:%i' "${agy24_hash_home}/.local/bin/agy-real" 2>/dev/null || stat -f '%d:%i' "${agy24_hash_home}/.local/bin/agy-real")"
printf 'type=file\nidentity=%s\nsha512=\ntemp_name=\n' "$agy24_hash_identity" >"${agy24_hash_home}/.local/bin/.agy-real.harmon-init-owned"
HOME="$agy24_hash_home" HARMON_BOT_AUTONOMY_ANTIGRAVITY=disabled bash "$ensure_script" >/dev/null
[ "$("${agy24_hash_home}/.local/bin/agy-real")" = independent ] && [ ! -e "${agy24_hash_home}/.local/bin/.agy-real.harmon-init-owned" ] || fail "empty digest authorized cleanup"
printf '#!/bin/sh\nexit 64\n' >"${agy24_hash_bin}/sha512sum"
printf '#!/bin/sh\nexit 0\n' >"$agy24_hash_stub"
chmod +x "${agy24_hash_bin}/sha512sum" "$agy24_hash_stub"
if HOME="$agy24_hash_home" HARMON_BOT_AUTONOMY_ANTIGRAVITY=enabled BOT_AUTONOMY_ANTIGRAVITY_APPLY_SCRIPT="$agy24_hash_stub" \
    PATH="${agy24_hash_bin}:${PATH}" bash "$agy_module" apply >/dev/null 2>&1; then fail "failed SHA-512 command published wrapper"; fi
[ ! -e "${agy24_hash_home}/.local/bin/agy" ] && [ ! -e "${agy24_hash_home}/.local/bin/.agy.harmon-init-owned" ] &&
    [ ! -e "${agy24_hash_home}/.local/bin/.agy.harmon-init-transaction" ] || fail "hash failure left managed wrapper state"

# Persist the quarantine name before moving, so a following run can recover a
# move that completed immediately before the process failed.
agy24_qr_home="${work_dir}/agy24-quarantine-recovery-home"
agy24_qr_system="${agy24_qr_home}/system-agy"
agy24_qr_bin="${agy24_qr_home}/fake-bin"
agy24_qr_target="${agy24_qr_home}/.local/bin/agy-real"
mkdir -p "${agy24_qr_home}/.local/bin" "$agy24_qr_bin"
printf '#!/bin/sh\nprintf "1.0.0\\n"\n' >"$agy24_qr_target"
printf '#!/bin/sh\nprintf "1.1.11\\n"\n' >"$agy24_qr_system"
chmod +x "$agy24_qr_target" "$agy24_qr_system"
HOME="$agy24_qr_home" HARMON_BOT_AUTONOMY_ANTIGRAVITY=enabled HARMON_ANTIGRAVITY_SYSTEM_BINARY="$agy24_qr_system" bash "$ensure_script" >/dev/null
printf '%s\n' '#!/bin/sh' \
    'if [ "$#" -eq 3 ] && [ "$1" = "-f" ] && [ "$2" = "$HARMON_TEST_QUARANTINE_TARGET" ]; then' \
    'case "$3" in "$HARMON_TEST_QUARANTINE_TARGET".harmon-init-quarantine.*) "$HARMON_TEST_REAL_MV" "$@"; exit 75 ;; esac; fi' \
    'exec "$HARMON_TEST_REAL_MV" "$@"' >"${agy24_qr_bin}/mv"
chmod +x "${agy24_qr_bin}/mv"
if HOME="$agy24_qr_home" HARMON_BOT_AUTONOMY_ANTIGRAVITY=disabled HARMON_TEST_QUARANTINE_TARGET="$agy24_qr_target" \
    HARMON_TEST_REAL_MV="$agy24_quarantine_real_mv" PATH="${agy24_qr_bin}:${PATH}" bash "$ensure_script" >/dev/null 2>&1; then
    fail "interrupted quarantine fixture did not fail"
fi
[ ! -e "$agy24_qr_target" ] && grep -q '^temp_name=agy-real.harmon-init-quarantine\.' "${agy24_qr_home}/.local/bin/.agy-real.harmon-init-owned" || fail "quarantine recovery name was not durable"
HOME="$agy24_qr_home" HARMON_BOT_AUTONOMY_ANTIGRAVITY=disabled bash "$ensure_script" >/dev/null
if ! agy24_qr_leftover="$(find "${agy24_qr_home}/.local/bin" -name 'agy-real.harmon-init-quarantine.*' -print -quit)"; then
    fail "could not inspect recovered quarantine leftovers"
fi
[ ! -e "${agy24_qr_home}/.local/bin/.agy-real.harmon-init-owned" ] &&
    [ -z "$agy24_qr_leftover" ] || fail "interrupted quarantine was not recovered"

# The in-flight delta is the source for this correction and is reconciled into
# the canonical requirement in the same commit. Compare the complete modified
# requirement when those root-only OpenSpec artifacts are present; generated
# repos intentionally ship neither file.
agy24_canonical_spec="${repo_root}/openspec/specs/devcontainer/bot-autonomy/spec.md"
agy24_delta_spec="${repo_root}/openspec/changes/agy-early-return/specs/devcontainer/bot-autonomy/spec.md"
if [ -e "$agy24_canonical_spec" ] || [ -e "$agy24_delta_spec" ]; then
    [ -f "$agy24_canonical_spec" ] && [ -f "$agy24_delta_spec" ] ||
        fail "Antigravity canonical/delta spec pair is incomplete"
    awk '
        found && /^### Requirement:/ { exit }
        /^### Requirement: Antigravity.*launcher/ { found = 1 }
        found { print }
    ' "$agy24_canonical_spec" >"${work_dir}/agy24-canonical-requirement"
    awk '
        found && /^### Requirement:/ { exit }
        /^### Requirement: Antigravity.*launcher/ { found = 1 }
        found { print }
    ' "$agy24_delta_spec" >"${work_dir}/agy24-delta-requirement"
    cmp -s "${work_dir}/agy24-canonical-requirement" "${work_dir}/agy24-delta-requirement" ||
        fail "Antigravity canonical and in-flight delta requirements diverged"
    grep -Fq 'independent ownership proof matches both its published filesystem identity' \
        "${work_dir}/agy24-canonical-requirement" ||
        fail "Antigravity spec does not require identity-and-content proof for managed cleanup"
fi

echo "All bot-autonomy unit tests passed."
