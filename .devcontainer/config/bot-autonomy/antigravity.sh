#!/usr/bin/env bash
set -euo pipefail

# bot-autonomy module: Google Antigravity. Dispatched by
# .devcontainer/scripts/bot-autonomy.sh, bot profile only. The `antigravity`
# harness is Copier-gated (use_antigravity_cli) but this module always
# exists and always covers it — only its effective policy is conditional, on
# the rendered containerEnv.HARMON_BOT_AUTONOMY_ANTIGRAVITY marker (never the
# Copier answer directly: this file is a verbatim template twin, shipped
# byte-identical to every generated repo, so it has no template-time
# substitution to read). See
# https://github.com/evanharmon1/harmon-init/blob/main/openspec/changes/archive/2026-09-05-bot-autonomy-bootstrap/design.md - Decisions for the full
# "~/.local/bin/agy is exactly one of three states" rationale.
#
#   marker == enabled  -> apply-antigravity-settings.sh apply (always-proceed)
#                          + install the flag-injecting wrapper at
#                          ~/.local/bin/agy (state a), overwriting whatever
#                          .devcontainer/config/ensure-antigravity-cli.sh
#                          (which runs earlier in post-create) left there.
#   marker != enabled  -> apply-antigravity-settings.sh restore; independently
#                          owned launchers are allowed, while any compatibility
#                          launcher or executable still carrying this module's
#                          ownership proof fails verification.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPLY_SETTINGS="${BOT_AUTONOMY_ANTIGRAVITY_APPLY_SCRIPT:-${SCRIPT_DIR}/../apply-antigravity-settings.sh}"
BOT_DEFAULTS="${BOT_AUTONOMY_ANTIGRAVITY_DEFAULTS:-${SCRIPT_DIR}/../antigravity-settings.json}"
SETTINGS="${BOT_AUTONOMY_ANTIGRAVITY_SETTINGS:-$HOME/.gemini/antigravity-cli/settings.json}"
AGY_LINK="${BOT_AUTONOMY_AGY_LINK:-$HOME/.local/bin/agy}"
AGY_REAL="${BOT_AUTONOMY_AGY_REAL:-$HOME/.local/bin/agy-real}"
AGY_REAL_OWNERSHIP="${BOT_AUTONOMY_AGY_OWNERSHIP:-$(dirname "$AGY_REAL")/.agy-real.harmon-init-owned}"
AGY_REAL_TRANSACTION="${BOT_AUTONOMY_AGY_TRANSACTION:-$(dirname "$AGY_REAL")/.agy-real.harmon-init-transaction}"
AGY_LINK_OWNERSHIP="${BOT_AUTONOMY_AGY_LINK_OWNERSHIP:-$(dirname "$AGY_LINK")/.agy.harmon-init-owned}"
AGY_LINK_TRANSACTION="${BOT_AUTONOMY_AGY_LINK_TRANSACTION:-$(dirname "$AGY_LINK")/.agy.harmon-init-transaction}"
AGY_LOCK="${BOT_AUTONOMY_AGY_LOCK:-$(dirname "$AGY_LINK")/.agy.harmon-init-lock}"
AGY_SYSTEM_BINARY="${HARMON_ANTIGRAVITY_SYSTEM_BINARY:-/usr/local/bin/agy}"
lock_backend=""

release_launcher_lock() {
    if [ "$lock_backend" = "shlock" ] && [ -f "$AGY_LOCK" ] && [ ! -L "$AGY_LOCK" ] &&
        [ "$(cat "$AGY_LOCK")" = "$$" ]; then
        rm -f "$AGY_LOCK"
    fi
    lock_backend=""
}

trap release_launcher_lock EXIT

acquire_launcher_lock() {
    install -d -m 0755 "$(dirname "$AGY_LINK")"
    if command -v flock >/dev/null 2>&1; then
        exec 9<"$(dirname "$AGY_LINK")"
        flock -n 9 || {
            echo "antigravity: launcher reconciliation is already running" >&2
            return 1
        }
        lock_backend="flock"
    elif command -v shlock >/dev/null 2>&1; then
        shlock -f "$AGY_LOCK" -p "$$" || {
            echo "antigravity: launcher reconciliation is already running" >&2
            return 1
        }
        lock_backend="shlock"
    else
        echo "antigravity: launcher reconciliation requires flock or shlock" >&2
        return 1
    fi
}

metadata_exists() {
    [ -e "$1" ] || [ -L "$1" ]
}

file_sha512() {
    if command -v sha512sum >/dev/null 2>&1; then
        sha512sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 512 "$1" | awk '{print $1}'
    else
        echo "antigravity: SHA-512 verification requires sha512sum or shasum" >&2
        return 1
    fi
}

path_identity() {
    stat -c '%d:%i' "$1" 2>/dev/null || stat -f '%d:%i' "$1"
}

proof_value() {
    sed -n "s/^$2=//p" "$1" | head -1
}

launcher_proof_matches() (
    proof="$1"
    path="$2"
    [ -f "$proof" ] && [ ! -L "$proof" ] && [ -f "$path" ] && [ ! -L "$path" ] || return 1
    [ "$(proof_value "$proof" type)" = "file" ] || return 1
    expected_identity="$(proof_value "$proof" identity)"
    [ -n "$expected_identity" ] || return 1
    actual_identity="$(path_identity "$path" 2>/dev/null)" || return 1
    [ -n "$actual_identity" ] && [ "$expected_identity" = "$actual_identity" ] || return 1
    expected_digest="$(proof_value "$proof" sha512)"
    [ -n "$expected_digest" ] || return 1
    actual_digest="$(file_sha512 "$path")" || return 1
    [ -n "$actual_digest" ] && [ "$expected_digest" = "$actual_digest" ]
)

discard_launcher_transaction() {
    temp_name="$(proof_value "$AGY_LINK_TRANSACTION" temp_name 2>/dev/null || true)"
    case "$temp_name" in
    agy.tmp.*) rm -f "$(dirname "$AGY_LINK")/${temp_name}" ;;
    esac
    rm -f "$AGY_LINK_TRANSACTION"
}

recover_launcher_transaction() {
    metadata_exists "$AGY_LINK_TRANSACTION" || return 0
    if launcher_proof_matches "$AGY_LINK_TRANSACTION" "$AGY_LINK"; then
        mv -f "$AGY_LINK_TRANSACTION" "$AGY_LINK_OWNERSHIP"
    else
        discard_launcher_transaction
    fi
}

marker_enabled() {
    [ "${HARMON_BOT_AUTONOMY_ANTIGRAVITY:-}" = "enabled" ]
}

# write_wrapper <target-path>  — the wrapper's content, factored out so apply
# (install) and verify (checksum-compare) can never drift from each other.
write_wrapper() {
    cat >"$1" <<WRAPPER
#!/usr/bin/env bash
set -euo pipefail

# bot-autonomy: Antigravity autonomy wrapper. Installed by
# .devcontainer/config/bot-autonomy/antigravity.sh apply (bot profile only,
# HARMON_BOT_AUTONOMY_ANTIGRAVITY=enabled). Interactive agy already honors
# the always-proceed settings policy; headless \`agy -p ...\` ignores
# settings allow-rules and auto-denies, so this wrapper injects
# --dangerously-skip-permissions for agent/headless launches. A fixed set of
# subcommands/flags pass through unmodified — appending the flag there is
# either rejected by agy or meaningless.

real="${AGY_REAL}"
[ -x "\$real" ] || real="${AGY_SYSTEM_BINARY}"

case "\${1:-}" in
"" | agent | agents | changelog | help | install | models | plugin | plugins | update | -h | --help | --version)
    exec "\$real" "\$@"
    ;;
esac

for arg in "\$@"; do
    if [ "\$arg" = "--dangerously-skip-permissions" ]; then
        exec "\$real" "\$@"
    fi
done

exec "\$real" --dangerously-skip-permissions "\$@"
WRAPPER
}

install_wrapper() (
    install -d -m 0755 "$(dirname "$AGY_LINK")"
    recover_launcher_transaction
    tmp="$(mktemp "$(dirname "$AGY_LINK")/agy.tmp.XXXXXX")"
    proof_tmp="$(mktemp "${AGY_LINK_TRANSACTION}.tmp.XXXXXX")"
    trap 'rm -f "$tmp" "$proof_tmp"' EXIT
    write_wrapper "$tmp"
    chmod 0755 "$tmp"
    identity="$(path_identity "$tmp")" || return 1
    [ -n "$identity" ] || return 1
    digest="$(file_sha512 "$tmp")" || return 1
    [ -n "$digest" ] || return 1
    printf 'type=file\nidentity=%s\nsha512=%s\ntemp_name=%s\n' \
        "$identity" \
        "$digest" \
        "$(basename "$tmp")" >"$proof_tmp"
    chmod 0600 "$proof_tmp"
    mv -f "$proof_tmp" "$AGY_LINK_TRANSACTION"
    rm -f "$AGY_LINK"
    mv -f "$tmp" "$AGY_LINK"
    mv -f "$AGY_LINK_TRANSACTION" "$AGY_LINK_OWNERSHIP"
)

cmd_apply() {
    if marker_enabled; then
        bash "$APPLY_SETTINGS" apply "$BOT_DEFAULTS" "$PWD"
        acquire_launcher_lock
        install_wrapper
        release_launcher_lock
        echo "==> antigravity: autonomous policy applied (wrapper installed)"
    else
        bash "$APPLY_SETTINGS" restore
        echo "==> antigravity: disabled-by-option (settings restored; agy left untouched)"
    fi
}

verify_no_dangling_symlink() {
    if [ -L "$AGY_LINK" ] && [ ! -e "$AGY_LINK" ]; then
        echo "antigravity: verify failed — ${AGY_LINK} is a dangling symlink" >&2
        exit 1
    fi
}

verify_settings_autonomous() {
    [ -f "$SETTINGS" ] || {
        echo "antigravity: verify failed — ${SETTINGS} not found" >&2
        exit 1
    }
    [ -f "$BOT_DEFAULTS" ] || {
        echo "antigravity: verify failed — bot defaults not found at ${BOT_DEFAULTS}" >&2
        exit 1
    }
    # Check every autonomy-relevant key against the shipped defaults, not
    # toolPermission alone: artifactReviewPolicy, allowNonWorkspaceAccess,
    # and enableTerminalSandbox can each independently reintroduce a prompt
    # or a sandboxed boundary while toolPermission stays always-proceed.
    # permissions is a per-tool allow/deny map apply-antigravity-settings.sh
    # otherwise preserves untouched (the bot defaults previously had no
    # opinion on it, so its merge left an explicit deny in place even with
    # toolPermission correct) — $BOT_DEFAULTS now pins it to {} so apply
    # clears any inherited override and verify has a concrete value to
    # check, the same as every other key here. Compared against
    # $BOT_DEFAULTS's own values (not hardcoded a second time here) so
    # apply and verify can never expect different things.
    local drifted
    drifted="$(jq -r --slurpfile defaults "$BOT_DEFAULTS" '
        ["toolPermission","artifactReviewPolicy","allowNonWorkspaceAccess","enableTerminalSandbox","permissions"] as $keys |
        . as $installed |
        [$keys[] | select($installed[.] != $defaults[0][.])] | join(", ")
    ' "$SETTINGS")" || {
        echo "antigravity: verify failed — could not evaluate ${SETTINGS} against ${BOT_DEFAULTS}" >&2
        exit 1
    }
    [ -z "$drifted" ] || {
        echo "antigravity: verify failed — drifted from the autonomous defaults on: ${drifted}" >&2
        exit 1
    }
    # The four scalar keys above are not the only gate: apply-antigravity-
    # settings.sh's own apply mode also adds $PWD to trustedWorkspaces (its
    # mechanism predates this module — docs/guides/devcontainers.md). If
    # that entry is lost after apply, interactive/headless agy can still hit
    # a workspace-trust prompt even though every scalar key reads
    # always-proceed, so verify checks the same predicate apply-antigravity-
    # settings.sh uses internally to confirm its own write.
    local workspace_trusted
    workspace_trusted="$(jq -r --arg workspace "$PWD" '
        (.trustedWorkspaces // []) | index($workspace) != null
    ' "$SETTINGS")" || {
        echo "antigravity: verify failed — could not evaluate ${SETTINGS} trustedWorkspaces" >&2
        exit 1
    }
    [ "$workspace_trusted" = "true" ] || {
        echo "antigravity: verify failed — current workspace (${PWD}) is missing from ${SETTINGS}'s trustedWorkspaces" >&2
        exit 1
    }
}

verify_wrapper_enabled() {
    [ -e "$AGY_LINK" ] || {
        echo "antigravity: verify failed — ${AGY_LINK} is missing" >&2
        exit 1
    }
    [ ! -L "$AGY_LINK" ] || {
        echo "antigravity: verify failed — ${AGY_LINK} must be the wrapper (a regular file), not a symlink" >&2
        exit 1
    }
    [ -x "$AGY_LINK" ] || {
        echo "antigravity: verify failed — ${AGY_LINK} is not executable" >&2
        exit 1
    }
    local tmp
    tmp="$(mktemp)"
    write_wrapper "$tmp"
    if ! cmp -s "$tmp" "$AGY_LINK"; then
        rm -f "$tmp"
        echo "antigravity: verify failed — ${AGY_LINK} does not match the expected autonomy wrapper content" >&2
        exit 1
    fi
    rm -f "$tmp"
    # Matching content alone does not mean the wrapper can run: it execs
    # $AGY_REAL, falling back to $AGY_SYSTEM_BINARY (see write_wrapper's own
    # `[ -x "$real" ] || real=...` line). If neither resolves to an
    # executable, the wrapper's bytes are still exactly correct but every
    # invocation exits 127 — a clean verify over an inert harness.
    [ -x "$AGY_REAL" ] || [ -x "$AGY_SYSTEM_BINARY" ] || {
        echo "antigravity: verify failed — neither ${AGY_REAL} nor ${AGY_SYSTEM_BINARY} is executable; the wrapper has no runnable backend" >&2
        exit 1
    }
}

verify_agy_unmanaged() {
    if metadata_exists "$AGY_LINK_OWNERSHIP" || metadata_exists "$AGY_LINK_TRANSACTION"; then
        echo "antigravity: verify failed — managed ownership metadata remains for ${AGY_LINK} while Antigravity autonomy is disabled-by-option" >&2
        exit 1
    fi
    if metadata_exists "$AGY_REAL_OWNERSHIP" || metadata_exists "$AGY_REAL_TRANSACTION"; then
        echo "antigravity: verify failed — managed ownership metadata remains for ${AGY_REAL} while Antigravity autonomy is disabled-by-option" >&2
        exit 1
    fi
}

cmd_verify() {
    verify_no_dangling_symlink
    if marker_enabled; then
        verify_settings_autonomous
        verify_wrapper_enabled
    else
        verify_agy_unmanaged
    fi
}

case "${1:-}" in
apply) cmd_apply ;;
verify) cmd_verify ;;
executable) echo "agy" ;;
# bot-autonomy.sh's dispatch gate normally skips a module when its
# declared executable is absent from PATH. That is wrong here: agy's
# managed state is exactly what apply/verify reconcile (ensure-antigravity-cli.sh
# removes owned remnants when disabled), so gating dispatch on presence would
# skip the disabled branch's settings restore precisely when disabling —
# the opposite of the intent. This module always runs; its own marker
# check decides what to do.
always_dispatch) echo "true" ;;
*)
    echo "Usage: $0 <apply|verify|executable|always_dispatch>" >&2
    exit 2
    ;;
esac
