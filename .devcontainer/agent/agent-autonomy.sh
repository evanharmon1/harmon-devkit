#!/usr/bin/env bash
set -euo pipefail

# AGENT PROFILE ONLY. Installs and verifies the agent posture's harness policy
# (docs/decisions/2026-09-29-agent-posture-three-posture-model.md), keyed by
# agent-registry.json's harness slugs.
#
#   agent-autonomy.sh apply     — install the agent Claude managed settings and
#                                 the agent Codex managed config, and REFUSE
#                                 every installed harness that has no
#                                 agent-capable configuration (its executable
#                                 is made non-executable). Idempotent.
#   agent-autonomy.sh verify    — fail unless both managed files match the
#                                 shipped agent profile byte for byte and no
#                                 refused harness's executable resolves on
#                                 PATH.
#   agent-autonomy.sh coverage  — static check, no container: every
#                                 agent-registry.json slug is exactly one of
#                                 supported, aliased to a supported slug, or
#                                 refused. Run by scripts/test-agent-profile.sh.
#
# apply and verify refuse to run unless FOREMAN_DEVCONTAINER is exactly
# "agent": this script must never rewrite the bot or dev profile's policy.
#
# The profile it installs lives ONLY in .devcontainer/config/agent/ (baked into
# the image at /usr/local/share/devcontainer-config/agent/ by the Dockerfile's
# COPY of .devcontainer/config/). No other file may carry a copy;
# scripts/test-agent-profile.sh enforces that.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fail() {
    echo "agent-autonomy: $*" >&2
    exit 1
}

# The profile source. Under the agent marker it is ONLY the baked, root-owned
# image copy: reading it from the writable checkout would let an edited copy
# be installed by apply and then match itself in verify. The checkout is used
# when there is no agent marker (the static coverage check on a host), or when
# AGENT_AUTONOMY_CONFIG_DIR names a directory — a seam set by the host-side
# unit test (scripts/test-agent-profile.sh) and by the remote bootstrap
# (images/devcontainer/bootstrap-remote.sh), which runs as root before any
# agent session from a checkout or tag it fetched itself.
#
# `apply --platform-vm` / `verify --platform-vm` — the remote bootstrap's
# other seam: apply and verify handle the managed files and GET wrapper only, and leave
# every harness executable's mode alone. On a platform's VM those executables
# are the platform's; refusing them there is a recorded delivery gap, not this
# script's to do. It is an ARGUMENT, never an environment variable, so nothing
# a repository can set (a devcontainer.json containerEnv entry) can switch it
# on for the agent devcontainer's own lifecycle, which never passes it. The
# seams above — AGENT_AUTONOMY_CONFIG_DIR, AGENT_AUTONOMY_CLAUDE_MANAGED and
# AGENT_AUTONOMY_CODEX_MANAGED — are still environment variables, open to the
# same containerEnv route; that residual is tracked in #1432.
PLATFORM_VM=0
BAKED_CONFIG_DIR=/usr/local/share/devcontainer-config/agent
CONFIG_DIR="${AGENT_AUTONOMY_CONFIG_DIR:-}"
if [ -z "$CONFIG_DIR" ]; then
    if [ -d "$BAKED_CONFIG_DIR" ]; then
        CONFIG_DIR="$BAKED_CONFIG_DIR"
    elif [ "${FOREMAN_DEVCONTAINER:-}" = "agent" ]; then
        fail "the baked agent profile ${BAKED_CONFIG_DIR} is missing — under the agent posture the profile is never read from the writable checkout"
    else
        CONFIG_DIR="$(cd "${SCRIPT_DIR}/../config/agent" && pwd)"
    fi
fi
HARNESSES="${CONFIG_DIR}/harnesses.json"
CLAUDE_SRC="${CONFIG_DIR}/claude-managed-settings.json"
CODEX_SRC="${CONFIG_DIR}/codex-managed-config.toml"
GH_API_READ_SRC="${CONFIG_DIR}/gh-api-read"
GH_API_READ="${AGENT_AUTONOMY_GH_API_READ:-/usr/local/bin/gh-api-read}"
CLAUDE_MANAGED="${AGENT_AUTONOMY_CLAUDE_MANAGED:-/etc/claude-code/managed-settings.json}"
CODEX_MANAGED="${AGENT_AUTONOMY_CODEX_MANAGED:-/etc/codex/managed_config.toml}"

require_agent_marker() {
    [ "${FOREMAN_DEVCONTAINER:-}" = "agent" ] ||
        fail "refusing to $1 outside the agent posture (FOREMAN_DEVCONTAINER='${FOREMAN_DEVCONTAINER:-}', expected 'agent')"
}

resolve_registry() {
    if [ -n "${AGENT_AUTONOMY_REGISTRY:-}" ]; then
        printf '%s' "${AGENT_AUTONOMY_REGISTRY}"
        return 0
    fi
    if [ -f "${PWD}/agent-registry.json" ]; then
        printf '%s' "${PWD}/agent-registry.json"
        return 0
    fi
    local root
    root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    if [ -n "$root" ] && [ -f "${root}/agent-registry.json" ]; then
        printf '%s' "${root}/agent-registry.json"
        return 0
    fi
    return 1
}

# require_digest_tool — pick the SHA-256 tool: GNU sha256sum, else the
# shasum a stock macOS host ships, else fail. apply and verify call it first,
# so a missing tool is a loud failure and never two empty digests comparing
# equal.
DIGEST_TOOL=""
require_digest_tool() {
    if command -v sha256sum >/dev/null 2>&1; then
        DIGEST_TOOL=sha256sum
    elif command -v shasum >/dev/null 2>&1; then
        DIGEST_TOOL=shasum
    else
        fail "neither sha256sum nor shasum is installed — cannot compare the agent profile"
    fi
}

# checksum <file> — the file's SHA-256, never an empty string: a digest that
# cannot be computed (unreadable file, failed tool) fails instead.
checksum() {
    local sum=""
    case "$DIGEST_TOOL" in
    sha256sum) sum="$(sha256sum "$1" | awk '{print $1}')" || sum="" ;;
    shasum) sum="$(shasum -a 256 "$1" | awk '{print $1}')" || sum="" ;;
    esac
    [ -n "$sum" ] || fail "could not compute the SHA-256 of $1"
    printf '%s\n' "$sum"
}

# same_digest <a> <b> — 0 when the two files have the same SHA-256, 1 when
# they differ. A digest that cannot be computed exits the script: it is an
# error, never a match and never a mismatch to act on.
same_digest() {
    local a b
    a="$(checksum "$1")" || fail "cannot compare $1 with $2"
    b="$(checksum "$2")" || fail "cannot compare $1 with $2"
    [ "$a" = "$b" ]
}

# install_as_root <src> <dest> — install with sudo only when the destination
# (or, for a new file, its directory) is not writable by the caller.
install_as_root() {
    local src="$1" dest="$2" mode="${3:-0644}"
    if [ -w "$dest" ] || { [ ! -e "$dest" ] && [ -w "$(dirname "$dest")" ]; }; then
        install -m "$mode" "$src" "$dest"
    else
        sudo -n install -d -m 0755 "$(dirname "$dest")"
        sudo -n install -m "$mode" "$src" "$dest"
    fi
}

refused_executables() {
    jq -r '.refused | to_entries[] | .value.executable // empty' "$HARNESSES"
}

# resolve_executable <name> — the first EXECUTABLE <name> on PATH. Not
# `command -v`: bash falls back to reporting a non-executable match when no
# executable one exists, so a refused binary would still "resolve".
resolve_executable() {
    local dir
    local IFS=:
    for dir in $PATH; do
        [ -n "$dir" ] || dir=.
        if [ -f "${dir}/$1" ] && [ -x "${dir}/$1" ]; then
            printf '%s\n' "${dir}/$1"
            return 0
        fi
    done
    return 1
}

# resolve_path <path> — <path> with every symlink followed, as an absolute
# physical path. Not `readlink -f`, which BSD readlink lacks before macOS
# 12.3: plain readlink one hop at a time, then the cd + pwd -P idiom the
# other devcontainer scripts use for the directory. Bounded against a loop.
resolve_path() {
    local path="$1" link hops=0 dir
    while [ -L "$path" ]; do
        hops=$((hops + 1))
        [ "$hops" -le 40 ] || return 1
        link="$(readlink "$path")" || return 1
        case "$link" in
        /*) path="$link" ;;
        *) path="$(dirname "$path")/${link}" ;;
        esac
    done
    dir="$(cd "$(dirname "$path")" && pwd -P)" || return 1
    printf '%s/%s\n' "$dir" "${path##*/}"
}

# refuse_executable <name> — make every copy of <name> that resolves on PATH
# non-executable. Loops because a second copy further down PATH becomes the
# resolution once the first is refused. Bounded so a PATH that keeps
# resolving (a wrapper that recreates itself) fails instead of spinning.
refuse_executable() {
    local name="$1" path target attempts=0
    while path="$(resolve_executable "$name")"; do
        attempts=$((attempts + 1))
        [ "$attempts" -le 10 ] || fail "could not refuse '${name}': it still resolves to ${path}"
        target="$(resolve_path "$path")" || fail "could not resolve ${path}"
        if [ -O "$target" ]; then
            chmod a-x "$target"
        else
            sudo -n chmod a-x "$target"
        fi
        echo "==> agent-autonomy: refused ${name} (${target} is no longer executable)"
    done
}

cmd_apply() {
    require_agent_marker apply
    command -v jq >/dev/null 2>&1 || fail "jq not found"
    [ -f "$CLAUDE_SRC" ] || fail "agent Claude settings not found at ${CLAUDE_SRC}"
    [ -f "$CODEX_SRC" ] || fail "agent Codex config not found at ${CODEX_SRC}"
    [ -f "$HARNESSES" ] || fail "harness table not found at ${HARNESSES}"
    [ -f "$GH_API_READ_SRC" ] || fail "GET wrapper not found at ${GH_API_READ_SRC}"
    require_digest_tool

    if [ -L "$GH_API_READ" ] || [ ! -x "$GH_API_READ" ] || ! same_digest "$GH_API_READ" "$GH_API_READ_SRC"; then
        install_as_root "$GH_API_READ_SRC" "$GH_API_READ" 0755
        echo "==> agent-autonomy: GET wrapper installed at ${GH_API_READ}"
    fi
    if [ ! -f "$CLAUDE_MANAGED" ] || ! same_digest "$CLAUDE_MANAGED" "$CLAUDE_SRC"; then
        install_as_root "$CLAUDE_SRC" "$CLAUDE_MANAGED"
        echo "==> agent-autonomy: agent Claude managed settings installed at ${CLAUDE_MANAGED}"
    fi
    if [ ! -f "$CODEX_MANAGED" ] || ! same_digest "$CODEX_MANAGED" "$CODEX_SRC"; then
        install_as_root "$CODEX_SRC" "$CODEX_MANAGED"
        echo "==> agent-autonomy: agent Codex managed config installed at ${CODEX_MANAGED}"
    fi

    local exe
    if [ "$PLATFORM_VM" = 1 ]; then
        echo "==> agent-autonomy: harness refusal skipped (--platform-vm); no executable was modified"
    else
        while IFS= read -r exe; do
            [ -n "$exe" ] || continue
            refuse_executable "$exe"
        done < <(refused_executables)
    fi
    echo "==> agent-autonomy: apply complete."
}

cmd_verify() {
    require_agent_marker verify
    local failed=0 exe path
    [ -f "$CLAUDE_SRC" ] || fail "agent Claude settings not found at ${CLAUDE_SRC}"
    [ -f "$CODEX_SRC" ] || fail "agent Codex config not found at ${CODEX_SRC}"
    [ -f "$GH_API_READ_SRC" ] || fail "GET wrapper not found at ${GH_API_READ_SRC}"
    require_digest_tool
    [ -f "$CLAUDE_MANAGED" ] && same_digest "$CLAUDE_MANAGED" "$CLAUDE_SRC" || {
        echo "agent-autonomy: verify failed — ${CLAUDE_MANAGED} does not match the shipped agent settings ${CLAUDE_SRC}" >&2
        failed=1
    }
    [ -f "$CODEX_MANAGED" ] && same_digest "$CODEX_MANAGED" "$CODEX_SRC" || {
        echo "agent-autonomy: verify failed — ${CODEX_MANAGED} does not match the shipped agent config ${CODEX_SRC}" >&2
        failed=1
    }
    [ -x "$GH_API_READ" ] && same_digest "$GH_API_READ" "$GH_API_READ_SRC" || {
        echo "agent-autonomy: verify failed — ${GH_API_READ} is not the executable shipped GET wrapper" >&2
        failed=1
    }
    if [ "$PLATFORM_VM" = 1 ]; then
        echo "==> agent-autonomy: refused-harness check skipped (--platform-vm)"
    else
        while IFS= read -r exe; do
            [ -n "$exe" ] || continue
            if path="$(resolve_executable "$exe")"; then
                echo "agent-autonomy: verify failed — refused harness executable '${exe}' still resolves to ${path}" >&2
                failed=1
            fi
        done < <(refused_executables)
    fi
    [ "$failed" -eq 0 ] || fail "verify failed — see above"
    echo "==> agent-autonomy: verify passed."
}

cmd_coverage() {
    command -v jq >/dev/null 2>&1 || fail "jq not found"
    [ -f "$HARNESSES" ] || fail "harness table not found at ${HARNESSES}"
    local registry slugs slug hits failed=0 target
    registry="$(resolve_registry)" || fail "agent-registry.json not found"
    slugs="$(jq -r '.harnesses[].slug' "$registry")" || fail "could not read ${registry}"
    while IFS= read -r slug; do
        [ -n "$slug" ] || continue
        hits="$(jq --arg s "$slug" '[(.supported // {}), (.aliases // {}), (.refused // {})] | map(select(has($s))) | length' "$HARNESSES")"
        if [ "$hits" -ne 1 ]; then
            echo "agent-autonomy: coverage failed — '${slug}' is in ${hits} buckets (need exactly one of supported, aliases, refused)" >&2
            failed=1
            continue
        fi
        target="$(jq -r --arg s "$slug" '.aliases[$s] // empty' "$HARNESSES")"
        if [ -n "$target" ] && [ "$(jq -r --arg t "$target" '.supported | has($t)' "$HARNESSES")" != "true" ]; then
            echo "agent-autonomy: coverage failed — '${slug}' aliases to '${target}', which is not supported" >&2
            failed=1
        fi
    done <<<"$slugs"
    # The reverse direction: a table entry no registry slug reaches is stale.
    local entry
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        grep -Fxq -- "$entry" <<<"$slugs" || {
            echo "agent-autonomy: coverage failed — '${entry}' is in harnesses.json but not in ${registry}" >&2
            failed=1
        }
    done < <(jq -r '(.supported // {}), (.aliases // {}), (.refused // {}) | keys[]' "$HARNESSES")
    [ "$failed" -eq 0 ] || fail "coverage failed — see above"
    echo "==> agent-autonomy: coverage passed."
}

usage() {
    echo "Usage: $0 <apply|verify> [--platform-vm] | $0 coverage" >&2
    exit 2
}

subcommand="${1:-}"
[ "$#" -eq 0 ] || shift
case "$subcommand" in
apply | verify)
    while [ "$#" -gt 0 ]; do
        case "$1" in
        --platform-vm) PLATFORM_VM=1 ;;
        *) usage ;;
        esac
        shift
    done
    "cmd_${subcommand}"
    ;;
coverage)
    [ "$#" -eq 0 ] || usage
    cmd_coverage
    ;;
*) usage ;;
esac
