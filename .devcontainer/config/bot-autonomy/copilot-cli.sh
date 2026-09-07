#!/usr/bin/env bash
set -euo pipefail

# bot-autonomy module: GitHub Copilot CLI. Dispatched by
# .devcontainer/scripts/bot-autonomy.sh, bot profile only. The `copilot-cli`
# harness is Copier-gated (use_copilot_cli) but this module always exists and
# always covers it — only its effective policy is conditional, on the rendered
# containerEnv.HARMON_BOT_AUTONOMY_COPILOT marker (never the Copier answer
# directly: this file is a verbatim template twin, shipped byte-identical to
# every generated repo, so it has no template-time substitution to read).
#
#   marker == enabled  -> confirm COPILOT_ALLOW_ALL is the exact literal
#                          "true" in this process's own environment, then
#                          install the flag-injecting wrapper at
#                          ~/.local/bin/copilot.
#   marker != enabled  -> remove ~/.local/bin/copilot if a prior enabled run
#                          left one behind.
#
# apply NEVER sets COPILOT_ALLOW_ALL itself. A container-wide environment
# variable is fixed by the rendered devcontainer.json `containerEnv` before
# any lifecycle script runs; a post-create script could only export one into
# its own shell, which is the login-shell-scoped anti-pattern this whole
# capability exists to retire. Both states render the variable explicitly
# ("true"/"false", never omitted): the bot profile also loads
# .devcontainer/devcontainer.env via --env-file, init-env.sh does not manage
# or evict COPILOT_ALLOW_ALL, and `containerEnv` only outranks --env-file for
# a key it actually specifies — an omitted key would let a stale out-of-band
# COPILOT_ALLOW_ALL=true survive a disabled render undisturbed.
#
# Why the wrapper is load-bearing rather than merely redundant, confirmed
# against the installed copilot 1.0.82: `copilot help environment` documents
# COPILOT_ALLOW_ALL as "allow all TOOLS to run automatically", the env
# equivalent of --allow-all-tools alone — file-path verification and URL
# access stay gated. --allow-all (and its --yolo alias) is the only switch
# equivalent to --allow-all-tools --allow-all-paths --allow-all-urls
# together, so the environment variable alone does not reach the full
# autonomy this module's enabled state promises.
#
# Residual, stated rather than papered over: this module is dispatched only
# when `copilot` resolves on PATH, like every other module here, so an
# in-container `verify` cannot see the case where the marker is `enabled` and
# no copilot binary exists at all — it is skipped, not failed. The CI
# container assertion in scripts/devcontainer-assert.sh covers that case
# instead, bounded to the one image pin for which it is legitimate.
#
# See https://github.com/evanharmon1/harmon-init/blob/main/openspec/changes/archive/2026-09-05-bot-autonomy-new-harnesses/design.md - Decisions.

COPILOT_LINK="${BOT_AUTONOMY_COPILOT_LINK:-$HOME/.local/bin/copilot}"
COPILOT_LINK_DIR="$(dirname "$COPILOT_LINK")"
# The npm global prefix for this image's apt-installed Node is system-wide,
# so the shared image's own binary lands at /usr/bin/copilot (confirmed
# against the built image). The wrapper resolves its delegate off PATH
# instead of trusting this path; it is only the documented fallback for a
# PATH that cannot resolve one, mirroring Antigravity's own
# HARMON_ANTIGRAVITY_SYSTEM_BINARY.
COPILOT_SYSTEM_BINARY="${HARMON_COPILOT_SYSTEM_BINARY:-/usr/bin/copilot}"
COPILOT_SETTINGS="${BOT_AUTONOMY_COPILOT_SETTINGS:-$HOME/.copilot/settings.json}"
# Ownership marker, carried verbatim inside every wrapper this module writes.
# NEVER reword it: it is how a LATER release recognises an EARLIER release's
# wrapper as its own. A byte-compare against write_wrapper's current output
# cannot do that job — the moment the wrapper's content changes, every
# already-installed wrapper would read as foreign and get stranded.
WRAPPER_MARKER="# harmon-init-bot-autonomy-wrapper: copilot-cli"

marker_enabled() {
    [ "${HARMON_BOT_AUTONOMY_COPILOT:-}" = "enabled" ]
}

# resolve_delegate — the real, shared-image-installed copilot binary: the
# next `copilot` on PATH after excluding the wrapper's own directory, so a
# wrapper that is itself first on PATH never execs itself. Never a hardcoded
# install path (the caller falls back to $COPILOT_SYSTEM_BINARY).
resolve_delegate() {
    local dir oldifs
    oldifs="$IFS"
    IFS=:
    for dir in $PATH; do
        [ -n "$dir" ] || dir=.
        [ "$dir" != "$COPILOT_LINK_DIR" ] || continue
        if [ -f "${dir}/copilot" ] && [ -x "${dir}/copilot" ]; then
            IFS="$oldifs"
            printf '%s' "${dir}/copilot"
            return 0
        fi
    done
    IFS="$oldifs"
    return 1
}

# write_wrapper <target-path>  — the wrapper's content, factored out so apply
# (install) and verify (byte-compare) can never drift from each other.
write_wrapper() {
    cat >"$1" <<WRAPPER
#!/usr/bin/env bash
set -euo pipefail

${WRAPPER_MARKER}
# bot-autonomy: GitHub Copilot CLI autonomy wrapper. Installed by
# .devcontainer/config/bot-autonomy/copilot-cli.sh apply (bot profile only,
# HARMON_BOT_AUTONOMY_COPILOT=enabled). COPILOT_ALLOW_ALL grants tools only;
# --allow-all is the documented equivalent of --allow-all-tools
# --allow-all-paths --allow-all-urls together, so this wrapper injects it for
# every agent-task invocation — interactive and headless alike, both of which
# GitHub's own CLI command reference groups as agent task invocation. A fixed
# set of administrative/informational subcommands passes through unmodified.
#
# The flag is PREPENDED, not appended: copilot parses "[options] [command]",
# so a trailing flag after a \`--\` separator (or after a variadic
# --allow-tool/--deny-tool list) would be read as an operand and silently
# grant nothing. A leading boolean flag has no such failure mode.

self_dir="${COPILOT_LINK_DIR}"
system_binary="${COPILOT_SYSTEM_BINARY}"

resolve_real() {
    local dir oldifs
    oldifs="\$IFS"
    IFS=:
    for dir in \$PATH; do
        [ -n "\$dir" ] || dir=.
        [ "\$dir" != "\$self_dir" ] || continue
        if [ -f "\${dir}/copilot" ] && [ -x "\${dir}/copilot" ]; then
            IFS="\$oldifs"
            printf '%s' "\${dir}/copilot"
            return 0
        fi
    done
    IFS="\$oldifs"
    return 1
}

real="\$(resolve_real || true)"
[ -n "\$real" ] || real="\$system_binary"

case "\${1:-}" in
login | version | --version | help | -h | --help | update | completion | init | plugin | plugins | mcp | skill | app)
    exec "\$real" "\$@"
    ;;
esac

# Full coverage already present -> exec unchanged. A PARTIAL narrower flag is
# not full coverage: appending --allow-all alongside it is redundant only for
# the dimension that flag already named, and is what actually grants the two
# it did not — the sanitized-environment (env -i, no COPILOT_ALLOW_ALL
# fallback) case this wrapper exists to cover.
#
# The scan skips the value token after -p/--prompt. That option carries
# arbitrary caller text, so it is the one place a token spelled exactly
# like a flag can appear without being one, and this scan's failure
# direction is asymmetric: mistaking a VALUE for an allow-all flag
# suppresses the injection, leaving the invocation restricted — the exact
# outcome the wrapper exists to prevent. No general argv parser and no
# table of value-taking options: every other option's value is a model
# name, a directory, or a URL, none of which is plausibly the literal
# string "--allow-all". --prompt=<value> needs no handling; that is a
# single token which never equals a bare flag. The scan also stops at a
# bare "--": everything after the end-of-options separator is an operand,
# so a literal --allow-all there is definitively not an active flag.
allow_tools=0
allow_paths=0
allow_urls=0
skip_next=0
for arg in "\$@"; do
    if [ "\$skip_next" -eq 1 ]; then
        skip_next=0
        continue
    fi
    case "\$arg" in
    --) break ;;
    -p | --prompt) skip_next=1 ;;
    --allow-all | --yolo) exec "\$real" "\$@" ;;
    --allow-all-tools) allow_tools=1 ;;
    --allow-all-paths) allow_paths=1 ;;
    --allow-all-urls) allow_urls=1 ;;
    esac
done
if [ "\$allow_tools" -eq 1 ] && [ "\$allow_paths" -eq 1 ] && [ "\$allow_urls" -eq 1 ]; then
    exec "\$real" "\$@"
fi

exec "\$real" --allow-all "\$@"
WRAPPER
}

# module_owns_link — true when the file at $COPILOT_LINK is a wrapper THIS
# module wrote, of any release, identified by the stable marker above.
module_owns_link() {
    [ -f "$COPILOT_LINK" ] && [ ! -L "$COPILOT_LINK" ] &&
        grep -Fqx "$WRAPPER_MARKER" "$COPILOT_LINK"
}

# This module claims exactly one path and both of its states need it: enabled
# installs the wrapper there, disabled requires it absent (verify asserts
# each). A file there this module did not write is therefore already a broken
# state under either answer — but destroying it is not this module's call to
# make, any more than clearing an administrator's
# disableBypassPermissionsMode is. Refuse and name the conflict instead, so a
# human resolves it rather than losing a launcher silently.
assert_link_ours_or_absent() {
    { [ -e "$COPILOT_LINK" ] || [ -L "$COPILOT_LINK" ]; } || return 0
    module_owns_link && return 0
    echo "copilot-cli: apply failed — ${COPILOT_LINK} exists but this module did not write it (no '${WRAPPER_MARKER}' line); refusing to overwrite or delete a launcher it does not own. Remove or relocate that file, then re-run." >&2
    exit 1
}

install_wrapper() {
    install -d -m 0755 "$COPILOT_LINK_DIR"
    local tmp
    tmp="$(mktemp)"
    write_wrapper "$tmp"
    chmod 0755 "$tmp"
    mv -f "$tmp" "$COPILOT_LINK"
}

cmd_apply() {
    if marker_enabled; then
        # The render, not this script, produces COPILOT_ALLOW_ALL. Installing
        # a wrapper against an environment that will not actually grant
        # allow-all would hide a render defect behind a working-looking
        # wrapper, so fail loudly instead.
        [ "${COPILOT_ALLOW_ALL:-}" = "true" ] || {
            echo "copilot-cli: apply failed — HARMON_BOT_AUTONOMY_COPILOT is 'enabled' but COPILOT_ALLOW_ALL is '${COPILOT_ALLOW_ALL:-<unset>}', not the exact literal 'true' (the rendered devcontainer.json containerEnv did not reach this process)" >&2
            exit 1
        }
        assert_link_ours_or_absent
        install_wrapper
        echo "==> copilot-cli: autonomous policy applied (wrapper installed)"
    else
        if [ -e "$COPILOT_LINK" ] || [ -L "$COPILOT_LINK" ]; then
            assert_link_ours_or_absent
            rm -f "$COPILOT_LINK"
            echo "==> copilot-cli: disabled-by-option (autonomy wrapper removed)"
        else
            echo "==> copilot-cli: disabled-by-option (no autonomy wrapper installed)"
        fi
    fi
}

verify_allow_all() {
    local expected="$1"
    [ "${COPILOT_ALLOW_ALL:-}" = "$expected" ] || {
        echo "copilot-cli: verify failed — COPILOT_ALLOW_ALL is '${COPILOT_ALLOW_ALL:-<unset>}', expected the exact literal '${expected}' (Copilot's own documented contract checks for the string \"true\", not general truthiness)" >&2
        exit 1
    }
}

verify_wrapper_enabled() {
    [ -e "$COPILOT_LINK" ] || {
        echo "copilot-cli: verify failed — ${COPILOT_LINK} is missing" >&2
        exit 1
    }
    [ ! -L "$COPILOT_LINK" ] || {
        echo "copilot-cli: verify failed — ${COPILOT_LINK} must be the wrapper (a regular file), not a symlink" >&2
        exit 1
    }
    [ -x "$COPILOT_LINK" ] || {
        echo "copilot-cli: verify failed — ${COPILOT_LINK} is not executable" >&2
        exit 1
    }
    local tmp
    tmp="$(mktemp)"
    write_wrapper "$tmp"
    if ! cmp -s "$tmp" "$COPILOT_LINK"; then
        rm -f "$tmp"
        echo "copilot-cli: verify failed — ${COPILOT_LINK} does not match the expected autonomy wrapper content" >&2
        exit 1
    fi
    rm -f "$tmp"
    # Matching content alone does not mean the wrapper can run: it execs the
    # delegate it resolves off PATH, falling back to $COPILOT_SYSTEM_BINARY.
    # If neither is executable the wrapper's bytes are still exactly right
    # but every invocation exits 127 — a clean verify over an inert harness.
    local delegate
    delegate="$(resolve_delegate || true)"
    [ -n "$delegate" ] || [ -x "$COPILOT_SYSTEM_BINARY" ] || {
        echo "copilot-cli: verify failed — no runnable delegate: no executable 'copilot' on PATH outside ${COPILOT_LINK_DIR}, and ${COPILOT_SYSTEM_BINARY} is not executable either" >&2
        exit 1
    }
}

# The one documented mechanism that neuters COPILOT_ALLOW_ALL and every
# --allow-all-family flag regardless of what this module wrote. Checked ONLY
# in the autonomous state: a locked-out bypass mode is irrelevant to
# disabled-by-option (prompt-enabled is already the intended outcome there),
# and checking it unconditionally would fail a default-off consumer whose own
# organization separately locks bypass mode via MDM. Never rewritten by
# apply — it is an administrator/organization control, so verify surfaces the
# contradiction to a human rather than silently overriding it.
verify_bypass_not_blocked() {
    [ -f "$COPILOT_SETTINGS" ] || return 0
    command -v jq >/dev/null 2>&1 || {
        echo "copilot-cli: jq not found" >&2
        exit 1
    }
    local blocked
    blocked="$(jq -r '.permissions.disableBypassPermissionsMode // empty' "$COPILOT_SETTINGS" 2>/dev/null)" || {
        echo "copilot-cli: verify failed — could not read ${COPILOT_SETTINGS}" >&2
        exit 1
    }
    [ "$blocked" != "disable" ] || {
        echo "copilot-cli: verify failed — ${COPILOT_SETTINGS} sets permissions.disableBypassPermissionsMode to 'disable', which blocks bypass mode regardless of COPILOT_ALLOW_ALL and every --allow-all-family flag; this repository wants Copilot autonomous but this environment's Copilot is policy-locked out of it" >&2
        exit 1
    }
}

verify_wrapper_absent() {
    if [ -e "$COPILOT_LINK" ] || [ -L "$COPILOT_LINK" ]; then
        echo "copilot-cli: verify failed — ${COPILOT_LINK} should be absent when Copilot CLI autonomy is disabled-by-option" >&2
        exit 1
    fi
}

cmd_verify() {
    if marker_enabled; then
        verify_allow_all "true"
        verify_wrapper_enabled
        verify_bypass_not_blocked
    else
        verify_allow_all "false"
        verify_wrapper_absent
    fi
}

case "${1:-}" in
apply) cmd_apply ;;
verify) cmd_verify ;;
executable) echo "copilot" ;;
*)
    echo "Usage: $0 <apply|verify|executable>" >&2
    exit 2
    ;;
esac
