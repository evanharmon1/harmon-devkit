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

# renovate: datasource=npm depName=@devcontainers/cli
DEVCONTAINER_CLI_VERSION=0.88.0

devcontainer_cli() {
    if command -v devcontainer >/dev/null 2>&1; then
        devcontainer "$@"
    else
        npx --yes "@devcontainers/cli@${DEVCONTAINER_CLI_VERSION}" "$@"
    fi
}

# The shared toolchain image every consumer Dockerfile must extend. The
# package is public and identical for all generated repos, so the literal
# name stays verbatim-portable.
HARMON_IMAGE="ghcr.io/evanharmon1/harmon-devcontainer"
HARMON_IMAGE_MANIFEST="/usr/local/share/harmon-devcontainer/manifest.json"

# assert_image_pin <dockerfile>
# The Dockerfile must extend exactly one approved immutable reference —
# the public package pinned by BOTH the sha-<40-hex-source-commit> tag and
# the sha256 manifest-list digest. Floating tags (latest, main, release
# aliases) or digestless tags could silently change bytes under every
# consumer, so any other FROM shape fails (harmon-init#489).
assert_image_pin() {
    # Dockerfile instructions are case-insensitive and tolerate leading
    # whitespace, so match by uppercased first token — a lowercase `from` or
    # trailing `user root` must not slip past the pin/permission checks.
    local dockerfile="$1" from_count ref source digest last_user
    from_count="$(awk 'toupper($1) == "FROM" { n++ } END { print n + 0 }' "$dockerfile")"
    [ "$from_count" = "1" ] ||
        fail "${dockerfile} must have exactly one FROM line extending the shared image (found ${from_count})"
    ref="$(awk 'toupper($1) == "FROM" { print $2; exit }' "$dockerfile")"
    case "$ref" in
    "${HARMON_IMAGE}:sha-"*"@sha256:"*) ;;
    *) fail "${dockerfile} FROM '${ref}' is not the approved immutable '${HARMON_IMAGE}:sha-<source-commit>@sha256:<manifest-digest>' reference" ;;
    esac
    source="${ref#"${HARMON_IMAGE}:sha-"}"
    source="${source%%@*}"
    digest="${ref##*@sha256:}"
    case "$source" in
    ????????????????????????????????????????)
        case "$source" in *[!0-9a-f]*) fail "${dockerfile} image tag 'sha-${source}' is not a 40-hex source commit" ;; esac
        ;;
    *) fail "${dockerfile} image tag 'sha-${source}' is not a 40-hex source commit" ;;
    esac
    case "$digest" in
    ????????????????????????????????????????????????????????????????)
        case "$digest" in *[!0-9a-f]*) fail "${dockerfile} image digest 'sha256:${digest}' is not a 64-hex manifest digest" ;; esac
        ;;
    *) fail "${dockerfile} image digest 'sha256:${digest}' is not a 64-hex manifest digest" ;;
    esac
    awk 'toupper($1) == "RUN" && $2 == "/usr/local/sbin/install-harmon-repo-config" && NF == 2 { found = 1 }
        END { exit !found }' "$dockerfile" ||
        fail "${dockerfile} does not invoke the image's install-harmon-repo-config overlay installer"
    last_user="$(awk 'toupper($1) == "USER" { user = $2 } END { print user }' "$dockerfile")"
    [ "$last_user" = "vscode" ] ||
        fail "${dockerfile} does not finish as USER vscode (last USER is '${last_user}')"
    printf '%s\n' "$source"
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

    # `task` and the rest of the shared toolchain come from the pinned public
    # image, never a devcontainer Feature: the go-task Feature resolved
    # "latest" through the anonymous GitHub API from inside the build and
    # 403'd at random on shared runner IPs (harmon-init#427). Asserted here,
    # in unit mode, because this is the gated path — `task ci` runs it with no
    # container. The container-mode check below proves the binary actually
    # landed, but it needs a built image and so runs only from the manual
    # smoke tasks.
    local dockerfile cfg
    dockerfile="${repo_root}/.devcontainer/Dockerfile"
    [ -f "$dockerfile" ] || fail "devcontainer Dockerfile not found at ${dockerfile}"
    for cfg in "$bot_config" "$dev_config"; do
        if grep -q 'features/go-task' "$cfg"; then
            fail "${cfg} installs task via a devcontainer Feature — the pinned shared image ships it (harmon-init#427)"
        fi
    done
    assert_image_pin "$dockerfile" >/dev/null

    # Run from a non-repo temp dir so `git rev-parse --is-inside-work-tree`
    # inside init-env.sh is false and the rebuild `git pull` never fires.
    local work_dir env_file
    work_dir="$(mktemp -d)"
    cd "$work_dir"

    # has_var <var> <env-file>  → true if the file sets VAR= on its own line.
    has_var() {
        grep -q "^${1}=" "$2"
    }

    # These allow-list cases run init-env.sh with most vars unset, so its
    # missing-var warning (asserted in 6 below) fires on every one. They assert
    # on the ENV-FILE, not stderr, so the warning is discarded: a green run must
    # not print "warning:" blocks a reader has to triage. `set -e` still catches
    # a nonzero exit, and 6 is where stderr is captured and checked.
    local bot_allow=(GH_TOKEN FOREMAN_AGENT_GH_TOKEN CLAUDE_CODE_OAUTH_TOKEN AGENT_DECK_TELEGRAM_KEY)
    local dev_allow=(TS_AUTHKEY CLAUDE_CODE_OAUTH_TOKEN AGENT_DECK_TELEGRAM_KEY)

    # 1. Bot strips TS_AUTHKEY from the host env; keeps allowed vars —
    #    including the read-only agent token foreman requires for dispatch.
    env_file="${work_dir}/env-bot-strip"
    : >"$env_file"
    TS_AUTHKEY=fake GH_TOKEN=fake FOREMAN_AGENT_GH_TOKEN=fake bash "$init_env" "$env_file" "${bot_allow[@]}" 2>/dev/null
    has_var GH_TOKEN "$env_file" || fail "bot profile dropped allowed GH_TOKEN"
    has_var FOREMAN_AGENT_GH_TOKEN "$env_file" || fail "bot profile dropped allowed FOREMAN_AGENT_GH_TOKEN (foreman dispatch needs it)"
    if has_var TS_AUTHKEY "$env_file"; then
        fail "bot profile leaked TS_AUTHKEY into the env-file"
    fi

    # 2. Bot evicts a STALE TS_AUTHKEY already in the file when TS_AUTHKEY is
    #    unset in the host env.
    env_file="${work_dir}/env-bot-evict"
    printf 'TS_AUTHKEY=stale\nGH_TOKEN=old\n' >"$env_file"
    (unset TS_AUTHKEY && GH_TOKEN=new bash "$init_env" "$env_file" "${bot_allow[@]}") 2>/dev/null
    if has_var TS_AUTHKEY "$env_file"; then
        fail "bot profile failed to evict a stale TS_AUTHKEY"
    fi

    # 3. Dev keeps TS_AUTHKEY when the dev allow-list includes it — and refuses
    #    GH_TOKEN even though the host env sets it. The human profile commits as
    #    the operator, so it must authenticate as the operator (via `gh auth
    #    login`) rather than carry the bot's PAT.
    env_file="${work_dir}/env-dev-keep"
    : >"$env_file"
    TS_AUTHKEY=keep GH_TOKEN=fake FOREMAN_AGENT_GH_TOKEN=fake bash "$init_env" "$env_file" "${dev_allow[@]}" 2>/dev/null
    has_var TS_AUTHKEY "$env_file" || fail "dev profile dropped allowed TS_AUTHKEY"
    if has_var GH_TOKEN "$env_file"; then
        fail "dev profile injected GH_TOKEN — a human profile must carry no bot credential"
    fi
    if has_var FOREMAN_AGENT_GH_TOKEN "$env_file"; then
        fail "dev profile injected FOREMAN_AGENT_GH_TOKEN — agent tokens stay in the bot profile"
    fi

    # 3b. Dev evicts a STALE GH_TOKEN already in the file when GH_TOKEN is unset
    #     in the host env. This is what retires the value an earlier rebuild wrote
    #     back when the dev allow-list still included it — dropping it from the
    #     allow-list alone would leave the old token sitting in the env-file.
    env_file="${work_dir}/env-dev-evict"
    printf 'GH_TOKEN=stale\nTS_AUTHKEY=old\n' >"$env_file"
    (unset GH_TOKEN && TS_AUTHKEY=new bash "$init_env" "$env_file" "${dev_allow[@]}") 2>/dev/null
    if has_var GH_TOKEN "$env_file"; then
        fail "dev profile failed to evict a stale GH_TOKEN"
    fi

    # 4. ANTHROPIC_API_KEY is ALWAYS stripped, even if passed in the allow-list
    #    (it silently overrides CLAUDE_CODE_OAUTH_TOKEN).
    env_file="${work_dir}/env-anthropic"
    : >"$env_file"
    ANTHROPIC_API_KEY=secret GH_TOKEN=fake bash "$init_env" "$env_file" GH_TOKEN ANTHROPIC_API_KEY 2>/dev/null
    if has_var ANTHROPIC_API_KEY "$env_file"; then
        fail "ANTHROPIC_API_KEY was allowed into the env-file"
    fi

    # 5. An unknown var passed in the allow-list cannot be smuggled in.
    env_file="${work_dir}/env-smuggle"
    : >"$env_file"
    HARMON_SMUGGLE=evil bash "$init_env" "$env_file" GH_TOKEN HARMON_SMUGGLE 2>/dev/null
    if has_var HARMON_SMUGGLE "$env_file"; then
        fail "an unknown var was smuggled into the env-file via the allow-list"
    fi

    # 6. A var allow-listed for this profile but absent from BOTH the host env
    #    and the env-file must WARN on stderr. The silence this replaces is how
    #    a missing TS_AUTHKEY went unnoticed for hours in a Coder workspace
    #    (harmon-init#639): the container came up fine and only the Tailscale-
    #    dependent step failed, far from the cause.
    local warn_out warn_rc
    env_file="${work_dir}/env-warn-dev"
    : >"$env_file"
    warn_rc=0
    warn_out="$(unset TS_AUTHKEY CLAUDE_CODE_OAUTH_TOKEN AGENT_DECK_TELEGRAM_KEY &&
        bash "$init_env" "$env_file" "${dev_allow[@]}" 2>&1 >/dev/null)" || warn_rc=$?
    [ "$warn_rc" -eq 0 ] ||
        fail "init-env.sh exited ${warn_rc} on a missing allow-listed var — it runs as initializeCommand on the HOST, so a nonzero exit aborts the container build"
    case "$warn_out" in
    *TS_AUTHKEY*) ;;
    *) fail "dev profile did not warn about a TS_AUTHKEY missing from both the host env and the env-file" ;;
    esac

    #    The bot profile must stay SILENT about TS_AUTHKEY even when it is
    #    missing everywhere: it is off that allow-list by design (no tailnet
    #    path from a bypassPermissions container), so naming it would advertise
    #    a credential the profile must never hold — and train the reader to
    #    expect one. Warning from BASE_MANAGED_VARS/EVICT_VARS instead of the
    #    post-filter allow-list is the accident this pins down.
    env_file="${work_dir}/env-warn-bot"
    : >"$env_file"
    warn_rc=0
    warn_out="$(unset TS_AUTHKEY GH_TOKEN FOREMAN_AGENT_GH_TOKEN CLAUDE_CODE_OAUTH_TOKEN AGENT_DECK_TELEGRAM_KEY &&
        bash "$init_env" "$env_file" "${bot_allow[@]}" 2>&1 >/dev/null)" || warn_rc=$?
    [ "$warn_rc" -eq 0 ] || fail "init-env.sh exited ${warn_rc} warning under the bot profile"
    case "$warn_out" in
    *TS_AUTHKEY*) fail "bot profile warned about a missing TS_AUTHKEY — it is off that allow-list by design and must never be advertised there" ;;
    esac
    case "$warn_out" in
    *GH_TOKEN*) ;;
    *) fail "bot profile did not warn about a GH_TOKEN missing from both the host env and the env-file" ;;
    esac

    #    A value already in the env-file is the out-of-band case init-env.sh
    #    exists to preserve (1Password-managed, never exported to the host
    #    shell): warn about nothing, and leave the value intact.
    env_file="${work_dir}/env-warn-quiet"
    printf 'TS_AUTHKEY=fromop\nCLAUDE_CODE_OAUTH_TOKEN=tok\nAGENT_DECK_TELEGRAM_KEY=key\n' >"$env_file"
    warn_rc=0
    warn_out="$(unset TS_AUTHKEY CLAUDE_CODE_OAUTH_TOKEN AGENT_DECK_TELEGRAM_KEY &&
        bash "$init_env" "$env_file" "${dev_allow[@]}" 2>&1 >/dev/null)" || warn_rc=$?
    [ "$warn_rc" -eq 0 ] || fail "init-env.sh exited ${warn_rc} with every allow-listed var already in the env-file"
    [ -z "$warn_out" ] || fail "init-env.sh warned about vars already present in the env-file: ${warn_out}"
    grep -q '^TS_AUTHKEY=fromop$' "$env_file" ||
        fail "init-env.sh did not preserve the out-of-band TS_AUTHKEY value in the env-file"

    #    A bare "VAR=" env-file line leaves the container with no usable value,
    #    so the presence test requires at least one character after the `=`.
    env_file="${work_dir}/env-warn-blank"
    printf 'TS_AUTHKEY=\nCLAUDE_CODE_OAUTH_TOKEN=tok\nAGENT_DECK_TELEGRAM_KEY=key\n' >"$env_file"
    warn_rc=0
    warn_out="$(unset TS_AUTHKEY CLAUDE_CODE_OAUTH_TOKEN AGENT_DECK_TELEGRAM_KEY &&
        bash "$init_env" "$env_file" "${dev_allow[@]}" 2>&1 >/dev/null)" || warn_rc=$?
    [ "$warn_rc" -eq 0 ] || fail "init-env.sh exited ${warn_rc} on a blank env-file entry"
    case "$warn_out" in
    *TS_AUTHKEY*) ;;
    *) fail "init-env.sh treated a blank 'TS_AUTHKEY=' env-file line as a usable value" ;;
    esac

    #    The warning names vars, never VALUES — it lands in build logs. Asserted
    #    with a var exported EMPTY (which "${!var:-}" treats as unset, so it
    #    warns) alongside two carrying sentinel secrets that must not appear.
    env_file="${work_dir}/env-warn-novalue"
    : >"$env_file"
    warn_rc=0
    warn_out="$(TS_AUTHKEY= CLAUDE_CODE_OAUTH_TOKEN=harmon-sentinel-one \
        AGENT_DECK_TELEGRAM_KEY=harmon-sentinel-two \
        bash "$init_env" "$env_file" "${dev_allow[@]}" 2>&1 >/dev/null)" || warn_rc=$?
    [ "$warn_rc" -eq 0 ] || fail "init-env.sh exited ${warn_rc} on an allow-listed var exported empty"
    case "$warn_out" in
    *TS_AUTHKEY*) ;;
    *) fail "init-env.sh did not warn about an allow-listed var exported empty — no usable value reaches the container" ;;
    esac
    case "$warn_out" in
    *harmon-sentinel*) fail "init-env.sh printed a secret VALUE in its warning output" ;;
    esac

    # 7. tailscale-connect.sh no-ops (exit 0, prints its "unavailable" message)
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

    # 8. The shared post-create guidance must never steer a BOT container to an
    #    operator `gh auth login`. Following that advice would put a human
    #    credential — `workflow` scope included — inside a bypassPermissions
    #    agent container, which is the escalation the bot PAT's denials exist to
    #    stop. Each profile opts in via DEVCONTAINER_GH_AUTH, so the DEFAULT has
    #    to be the conservative token message: an unset or misspelled value must
    #    fail safe, not print the operator instructions.
    local post_create_common helper_src help_out
    post_create_common="${repo_root}/.devcontainer/scripts/post-create-common.sh"
    [ -f "$post_create_common" ] || fail "post-create-common.sh not found at ${post_create_common}"
    helper_src="${work_dir}/gh-auth-help.sh"
    sed -n '/^gh_auth_help()/,/^}/p' "$post_create_common" >"$helper_src"
    [ -s "$helper_src" ] || fail "could not extract gh_auth_help() from ${post_create_common}"

    # Match a pasteable COMMAND line — `gh` as the first token — not the bare
    # phrase. The token message names `gh auth login` on purpose, in a "do NOT
    # run this here" warning; a substring test would read that warning as the
    # very thing it warns against, and the check would be worse than useless.
    offers_login() {
        printf '%s\n' "$1" | grep -qE '^[[:space:]]*gh[[:space:]]+auth[[:space:]]+login'
    }

    help_out="$(unset DEVCONTAINER_GH_AUTH && "$bash_bin" -c '. "$1"; gh_auth_help "gh auth setup-git"' _ "$helper_src")"
    if offers_login "$help_out"; then
        fail "post-create gh guidance offers an operator login by default — a bot container must never be told to run one"
    fi

    help_out="$(DEVCONTAINER_GH_AUTH=login "$bash_bin" -c '. "$1"; gh_auth_help "gh auth setup-git"' _ "$helper_src")"
    if ! offers_login "$help_out"; then
        fail "post-create gh guidance omits the operator login where the profile declares one"
    fi

    # 9. Static devcontainer.json invariants via the devcontainers CLI.
    assert_config_invariants "$repo_root" "$bot_config" bot
    assert_config_invariants "$repo_root" "$dev_config" dev

    echo "==> devcontainer unit assertions passed."
}

# assert_config_invariants <repo_root> <config> <profile>
# bot: NO tailscale feature, NO 1Password CLI feature, NO /dev/net/tun runArg,
#      NO TS_AUTHKEY in initializeCommand — the bot container must hold no path
#      to production secrets or the tailnet. dev: all four present.
# GH_TOKEN is the one invariant that runs the OTHER way. The bot's scoped PAT
# belongs in the bot profile only; the dev profile commits as the operator and
# so must authenticate as the operator, never as the bot. Asserted statically
# because the failure is silent at runtime: `gh` prefers GH_TOKEN over a stored
# credential unconditionally, so a re-added allow-list entry would quietly put
# the bot back in charge of a human's pushes.
assert_config_invariants() {
    local repo_root="$1" config="$2" profile="$3"
    local cfg has_ts_feature has_op_feature has_tun has_ts_init has_gh_init

    # read-configuration 0.87+ probes Docker for an existing container even
    # though this assertion only needs the static JSONC. A no-op docker path
    # keeps this unit check daemon-independent as documented.
    cfg="$(devcontainer_cli read-configuration \
        --docker-path /usr/bin/true \
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
    has_gh_init="$(printf '%s' "$cfg" |
        jq -r '(.configuration.initializeCommand // "") | test("GH_TOKEN") | if . then 1 else 0 end')"
    local foreman_marker
    foreman_marker="$(printf '%s' "$cfg" |
        jq -r '.configuration.containerEnv.FOREMAN_DEVCONTAINER // ""')"

    if [ "$profile" = "bot" ]; then
        [ "$has_ts_feature" = "0" ] || fail "bot config has a tailscale feature"
        [ "$has_op_feature" = "0" ] || fail "bot config has a 1Password CLI feature (no secret-store path in the bot container)"
        [ "$has_tun" = "0" ] || fail "bot config requests /dev/net/tun"
        [ "$has_ts_init" = "0" ] || fail "bot config references TS_AUTHKEY in initializeCommand"
        [ "$has_gh_init" = "1" ] || fail "bot config does not reference GH_TOKEN in initializeCommand"
        # Foreman's D2 startup tripwire: it refuses even read-only commands
        # unless FOREMAN_DEVCONTAINER=bot, so losing this marker breaks every
        # task foreman:* while verify stays green.
        [ "$foreman_marker" = "bot" ] || fail "bot config does not set containerEnv.FOREMAN_DEVCONTAINER=bot (foreman refuses to start)"
    else
        [ "$has_ts_feature" != "0" ] || fail "dev config is missing the tailscale feature"
        [ "$has_op_feature" != "0" ] || fail "dev config is missing the 1Password CLI feature"
        [ "$has_tun" != "0" ] || fail "dev config is missing the /dev/net/tun device"
        [ "$has_ts_init" = "1" ] || fail "dev config does not reference TS_AUTHKEY in initializeCommand"
        [ "$has_gh_init" = "0" ] || fail "dev config references GH_TOKEN in initializeCommand (a human profile must carry no bot credential)"
        [ -z "$foreman_marker" ] || fail "dev config sets FOREMAN_DEVCONTAINER — foreman must refuse to run in the human profile"

        # Dropping GH_TOKEN only removes the FIRST link in gh's credential
        # chain. GITHUB_TOKEN and the enterprise aliases outrank the stored
        # `gh auth login` too, and init-env.sh does not recognize those names,
        # so an env-file carrying one would quietly own this profile's identity
        # while every check above still passed. containerEnv (docker --env,
        # which outranks --env-file) must blank each one; gh reads empty as
        # unset. A MISSING key is a failure, not a pass — that is the state
        # this assertion exists to catch.
        local alias_var blanked
        for alias_var in GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN; do
            blanked="$(printf '%s' "$cfg" |
                jq -r --arg v "$alias_var" '(.configuration.containerEnv // {})[$v] // "<absent>"')"
            [ "$blanked" = "" ] ||
                fail "dev config does not blank ${alias_var} in containerEnv (gh would prefer it over the operator's login); found '${blanked}'"
        done
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

    # `task` ships from the pinned shared image, NOT a devcontainer Feature
    # (harmon-init#427 history). The expected version comes from the image's
    # own machine-readable manifest, and the manifest's revision must match
    # the Dockerfile's pinned source commit — proving the running container
    # was really built from the approved immutable reference, not a stale or
    # floating image that happens to have the binaries.
    local script_dir repo_root pinned_source manifest manifest_revision pinned_task actual_task
    script_dir="$(cd "$(dirname "$0")" && pwd)"
    repo_root="$(git -C "$script_dir" rev-parse --show-toplevel)"
    pinned_source="$(assert_image_pin "${repo_root}/.devcontainer/Dockerfile")"
    manifest="$(docker exec -u vscode "$container_id" cat "$HARMON_IMAGE_MANIFEST" 2>/dev/null)" ||
        fail "image manifest ${HARMON_IMAGE_MANIFEST} is missing in the ${profile} container"
    manifest_revision="$(printf '%s' "$manifest" | jq -r '.image.revision // empty')" ||
        fail "image manifest in the ${profile} container is not valid JSON"
    [ "$manifest_revision" = "$pinned_source" ] ||
        fail "container image revision '${manifest_revision}' does not match the Dockerfile pin '${pinned_source}' in the ${profile} container"
    pinned_task="$(printf '%s' "$manifest" | jq -r '.tools.task // empty')"
    [ -n "$pinned_task" ] ||
        fail "image manifest lists no task version in the ${profile} container"
    actual_task="$(docker exec -u vscode "$container_id" sh -c 'task --version' 2>/dev/null)" ||
        fail "task is not runnable in the ${profile} container"
    # Compare EXACTLY, not as a substring: `*3.5.2*` also matches the output
    # "3.5.20", which would wave through a binary that is not the pinned one.
    # `task --version` prints a bare "3.52.0"; older builds printed
    # "Task version: v3.52.0" — reduce both shapes to the bare version first.
    local actual_version
    actual_version="$(printf '%s' "$actual_task" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    [ -n "$actual_version" ] ||
        fail "could not parse a version out of 'task --version' output '${actual_task}' in the ${profile} container"
    [ "$actual_version" = "$pinned_task" ] ||
        fail "task version '${actual_version}' in the ${profile} container does not match the pin '${pinned_task}'"

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

        # `command` is a shell BUILTIN, so it must run inside a shell: bare
        # `docker exec <id> command -v x` execs a binary that does not exist
        # and always fails, which silently made this check vacuous.
        if docker exec -u vscode "$container_id" sh -c 'command -v tailscale' >/dev/null 2>&1; then
            fail "tailscale CLI is present in the bot container"
        fi

        # Captured, never echoed: the failure message reports only that a key
        # is set, never its value. Do NOT run this script under `set -x` — the
        # trace would expand the real key into stderr and CI logs.
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

        # Same builtin caveat as the bot branch above — without `sh -c` this
        # never passes, regardless of whether tailscale is installed.
        if ! docker exec -u vscode "$container_id" sh -c 'command -v tailscale' >/dev/null 2>&1; then
            fail "tailscale CLI is missing from the dev container"
        fi

        # The live counterpart of the static GH_TOKEN invariant: a human profile
        # authenticates as the operator through `gh auth login`, so the bot's PAT
        # must not be in this container's environment. Captured, never echoed —
        # same discipline as the bot's TS_AUTHKEY check above.
        local gh_token
        gh_token="$(docker exec -u vscode "$container_id" printenv GH_TOKEN 2>/dev/null || true)"
        [ -z "$gh_token" ] || fail "GH_TOKEN is set in the dev container"
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
