#!/usr/bin/env bash
set -euo pipefail

# Assert the devcontainer permission/isolation invariants.
#
# Two modes:
#   unit                       — no container, no real secrets. Exercises the
#                                real init-env.sh / tailscale-connect.sh scripts
#                                and the static devcontainer.json invariants.
#   container <cfg> <id> <prf> — runs inside an already-started container (via
#                                `docker exec`) to assert the live git identity,
#                                tailscale presence, and stripped env.
#
# Kept verbatim-portable: generated projects ship this script unchanged, so the
# git-identity assertions check RELATIONSHIPS (e.g. a "-bot" suffix), never the
# template author's literal name/email.

fail() {
    echo "ASSERT FAIL: $*" >&2
    exit 1
}

# ── unit mode ─────────────────────────────────────────────────────────
assert_unit() {
    # Resolve the repo root from the script's own location BEFORE we cd away,
    # so init-env.sh's "only pull on a clean main" guard short-circuits when we
    # run it from a throwaway, non-repo working directory.
    local script_dir repo_root init_env ts_connect bash_bin
    script_dir="$(cd "$(dirname "$0")" && pwd)"
    repo_root="$(git -C "$script_dir" rev-parse --show-toplevel)"
    init_env="${repo_root}/.devcontainer/scripts/init-env.sh"
    ts_connect="${repo_root}/.devcontainer/scripts/tailscale-connect.sh"
    bash_bin="$(command -v bash)"

    [ -f "$init_env" ] || fail "init-env.sh not found at ${init_env}"
    [ -f "$ts_connect" ] || fail "tailscale-connect.sh not found at ${ts_connect}"

    local bot_config dev_config
    bot_config="${repo_root}/.devcontainer/devcontainer.json"
    dev_config="${repo_root}/.devcontainer/dev/devcontainer.json"
    [ -f "$bot_config" ] || fail "bot devcontainer.json not found at ${bot_config}"
    [ -f "$dev_config" ] || fail "dev devcontainer.json not found at ${dev_config}"

    # Run from a non-repo temp dir so `git rev-parse --is-inside-work-tree`
    # inside init-env.sh is false and the rebuild `git pull` never fires.
    local work_dir env_file
    work_dir="$(mktemp -d)"
    cd "$work_dir"

    # has_var <var> <env-file>  → true if the file sets VAR= on its own line.
    has_var() {
        grep -q "^${1}=" "$2"
    }

    local bot_allow=(GH_TOKEN CLAUDE_CODE_OAUTH_TOKEN AGENT_DECK_TELEGRAM_KEY)
    local dev_allow=(TS_AUTHKEY GH_TOKEN CLAUDE_CODE_OAUTH_TOKEN AGENT_DECK_TELEGRAM_KEY)

    # 1. Bot strips TS_AUTHKEY from the host env; keeps an allowed var.
    env_file="${work_dir}/env-bot-strip"
    : >"$env_file"
    TS_AUTHKEY=fake GH_TOKEN=fake bash "$init_env" "$env_file" "${bot_allow[@]}"
    has_var GH_TOKEN "$env_file" || fail "bot profile dropped allowed GH_TOKEN"
    if has_var TS_AUTHKEY "$env_file"; then
        fail "bot profile leaked TS_AUTHKEY into the env-file"
    fi

    # 2. Bot evicts a STALE TS_AUTHKEY already in the file when TS_AUTHKEY is
    #    unset in the host env.
    env_file="${work_dir}/env-bot-evict"
    printf 'TS_AUTHKEY=stale\nGH_TOKEN=old\n' >"$env_file"
    (unset TS_AUTHKEY && GH_TOKEN=new bash "$init_env" "$env_file" "${bot_allow[@]}")
    if has_var TS_AUTHKEY "$env_file"; then
        fail "bot profile failed to evict a stale TS_AUTHKEY"
    fi

    # 3. Dev keeps TS_AUTHKEY when the dev allow-list includes it.
    env_file="${work_dir}/env-dev-keep"
    : >"$env_file"
    TS_AUTHKEY=keep GH_TOKEN=fake bash "$init_env" "$env_file" "${dev_allow[@]}"
    has_var TS_AUTHKEY "$env_file" || fail "dev profile dropped allowed TS_AUTHKEY"

    # 4. ANTHROPIC_API_KEY is ALWAYS stripped, even if passed in the allow-list
    #    (it silently overrides CLAUDE_CODE_OAUTH_TOKEN).
    env_file="${work_dir}/env-anthropic"
    : >"$env_file"
    ANTHROPIC_API_KEY=secret GH_TOKEN=fake bash "$init_env" "$env_file" GH_TOKEN ANTHROPIC_API_KEY
    if has_var ANTHROPIC_API_KEY "$env_file"; then
        fail "ANTHROPIC_API_KEY was allowed into the env-file"
    fi

    # 5. An unknown var passed in the allow-list cannot be smuggled in.
    env_file="${work_dir}/env-smuggle"
    : >"$env_file"
    HARMON_SMUGGLE=evil bash "$init_env" "$env_file" GH_TOKEN HARMON_SMUGGLE
    if has_var HARMON_SMUGGLE "$env_file"; then
        fail "an unknown var was smuggled into the env-file via the allow-list"
    fi

    # 6. tailscale-connect.sh no-ops (exit 0, prints its "unavailable" message)
    #    when `tailscale` is not on PATH. Invoke with an absolute bash path so
    #    the unreachable PATH doesn't also hide the interpreter.
    local ts_out
    if ! ts_out="$(PATH="/nonexistent" "$bash_bin" "$ts_connect" 2>&1)"; then
        fail "tailscale-connect.sh exited nonzero when tailscale is absent"
    fi
    case "$ts_out" in
    *"unavailable"*) ;;
    *) fail "tailscale-connect.sh did not report tailscale unavailable: ${ts_out}" ;;
    esac

    # 7. Static devcontainer.json invariants via the devcontainers CLI.
    assert_config_invariants "$repo_root" "$bot_config" bot
    assert_config_invariants "$repo_root" "$dev_config" dev

    echo "==> devcontainer unit assertions passed."
}

# assert_config_invariants <repo_root> <config> <profile>
# bot: NO tailscale feature, NO 1Password CLI feature, NO /dev/net/tun runArg,
#      NO TS_AUTHKEY in initializeCommand — the bot container must hold no path
#      to production secrets or the tailnet. dev: all four present.
assert_config_invariants() {
    local repo_root="$1" config="$2" profile="$3"
    local cfg has_ts_feature has_op_feature has_tun has_ts_init

    cfg="$(npx -y @devcontainers/cli read-configuration \
        --workspace-folder "$repo_root" \
        --config "$config")" ||
        fail "read-configuration failed for ${config}"

    has_ts_feature="$(printf '%s' "$cfg" |
        jq -r '[.configuration.features // {} | keys[] | select(test("tailscale";"i"))] | length')"
    has_op_feature="$(printf '%s' "$cfg" |
        jq -r '[.configuration.features // {} | keys[] | select(test("1password";"i"))] | length')"
    has_tun="$(printf '%s' "$cfg" |
        jq -r '[.configuration.runArgs // [] | .[] | select(test("/dev/net/tun"))] | length')"
    has_ts_init="$(printf '%s' "$cfg" |
        jq -r '(.configuration.initializeCommand // "") | test("TS_AUTHKEY") | if . then 1 else 0 end')"

    if [ "$profile" = "bot" ]; then
        [ "$has_ts_feature" = "0" ] || fail "bot config has a tailscale feature"
        [ "$has_op_feature" = "0" ] || fail "bot config has a 1Password CLI feature (no secret-store path in the bot container)"
        [ "$has_tun" = "0" ] || fail "bot config requests /dev/net/tun"
        [ "$has_ts_init" = "0" ] || fail "bot config references TS_AUTHKEY in initializeCommand"
    else
        [ "$has_ts_feature" != "0" ] || fail "dev config is missing the tailscale feature"
        [ "$has_op_feature" != "0" ] || fail "dev config is missing the 1Password CLI feature"
        [ "$has_tun" != "0" ] || fail "dev config is missing the /dev/net/tun device"
        [ "$has_ts_init" = "1" ] || fail "dev config does not reference TS_AUTHKEY in initializeCommand"
    fi
}

# ── container mode ────────────────────────────────────────────────────
# assert_container <config> <container-id> <profile>
assert_container() {
    local config="$1" container_id="$2" profile="$3"
    [ -n "$container_id" ] || fail "container mode requires a container id"

    local git_name git_email
    git_name="$(docker exec -u vscode "$container_id" git config --global user.name)" ||
        fail "could not read git user.name in container"
    git_email="$(docker exec -u vscode "$container_id" git config --global user.email)" ||
        fail "could not read git user.email in container"

    if [ "$profile" = "bot" ]; then
        # Assert the bot identity RELATIONSHIP, not literal values, so the
        # script stays valid verbatim in generated projects.
        case "$git_email" in
        *-bot@*) ;;
        *) fail "bot git email '${git_email}' does not contain '-bot@'" ;;
        esac
        case "$git_name" in
        *-bot) ;;
        *) fail "bot git name '${git_name}' does not end with '-bot'" ;;
        esac

        if docker exec -u vscode "$container_id" command -v tailscale >/dev/null 2>&1; then
            fail "tailscale CLI is present in the bot container"
        fi

        local ts_authkey
        ts_authkey="$(docker exec -u vscode "$container_id" printenv TS_AUTHKEY 2>/dev/null || true)"
        [ -z "$ts_authkey" ] || fail "TS_AUTHKEY is set in the bot container"
    else
        case "$git_email" in
        *-bot@*) fail "dev git email '${git_email}' unexpectedly contains '-bot@'" ;;
        esac
        case "$git_name" in
        *-bot) fail "dev git name '${git_name}' unexpectedly ends with '-bot'" ;;
        esac

        if ! docker exec -u vscode "$container_id" command -v tailscale >/dev/null 2>&1; then
            fail "tailscale CLI is missing from the dev container"
        fi
    fi

    echo "==> devcontainer container assertions passed for ${config} (${profile})."
}

# ── dispatch ──────────────────────────────────────────────────────────
mode="${1:-}"
case "$mode" in
unit)
    assert_unit
    ;;
container)
    shift
    if [ "$#" -ne 3 ]; then
        echo "Usage: $0 container <config> <container-id> <profile>" >&2
        exit 1
    fi
    assert_container "$1" "$2" "$3"
    ;;
*)
    echo "Usage: $0 <unit|container> [args...]" >&2
    exit 1
    ;;
esac
