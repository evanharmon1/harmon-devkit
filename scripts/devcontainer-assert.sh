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

# Read a scalar from the document root without depending on yq's TOML parser.
# The yq build available on GitHub's Ubuntu runner interprets TOML arrays of
# tables differently from the Homebrew build, even for an unrelated root key.
toml_root_scalar() {
    local key="$1" file="$2"
    awk -v key="$key" '
        BEGIN { in_root = 1 }
        /^[[:space:]]*\[/ { in_root = 0 }
        in_root {
            line = $0
            sub(/[[:space:]]*#.*/, "", line)
            if (line ~ "^[[:space:]]*" key "[[:space:]]*=") {
                sub("^[[:space:]]*" key "[[:space:]]*=[[:space:]]*", "", line)
                sub(/[[:space:]]*$/, "", line)
                if (line ~ /^".*"$/) {
                    sub(/^"/, "", line)
                    sub(/"$/, "", line)
                }
                print line
                exit
            }
        }
    ' "$file"
}

# renovate: datasource=npm depName=@devcontainers/cli
DEVCONTAINER_CLI_VERSION=0.89.0

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

# The ONE image for which "Copilot autonomy is enabled but there is no
# copilot binary" is a legitimate state rather than a defect: the
# pre-harness-matrix pin, which ships no copilot at all. Bounding the
# exception to this exact digest makes it EXPIRE by itself the moment the
# sync-pin PR (#1152) bumps .devcontainer/Dockerfile — after that, an
# enabled marker with no wrapper-resolving copilot is a real failure on
# every image, which is what keeps the assertion from being a permanent
# success-note.
HARMON_PRE_HARNESS_MATRIX_DIGEST="sha256:b8a305693e996ac5289bf6f18ae47dd75d9d04ed1763499ef03f52949ea5b519"

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

# pinned_image_digest <dockerfile>  — the sha256 manifest digest off the
# Dockerfile's FROM line. assert_image_pin has already proved the reference's
# shape and that the RUNNING container's manifest revision matches its source
# commit, so this is a read of an already-validated pin, not a second parser.
pinned_image_digest() {
    local ref
    ref="$(awk 'toupper($1) == "FROM" { print $2; exit }' "$1")"
    printf 'sha256:%s' "${ref##*@sha256:}"
}

# ── unit mode ─────────────────────────────────────────────────────────
assert_unit() {
    # Resolve the repo root from the script's own location BEFORE we cd away,
    # so init-env.sh's "only pull on a clean main" guard short-circuits when we
    # run it from a throwaway, non-repo working directory.
    local script_dir repo_root init_env ts_connect bash_bin codex_config
    local bot_autonomy bot_autonomy_module_dir codex_module claude_module codex_bot_config
    local codex_system_config
    script_dir="$(cd "$(dirname "$0")" && pwd -P)"
    repo_root="$(cd "$script_dir/.." && pwd -P)"
    init_env="${repo_root}/.devcontainer/scripts/init-env.sh"
    ts_connect="${repo_root}/.devcontainer/scripts/tailscale-connect.sh"
    codex_config="${repo_root}/.devcontainer/config/codex-managed-config.toml"
    codex_system_config="${repo_root}/.devcontainer/config/codex-system-config.toml"
    bot_autonomy="${repo_root}/.devcontainer/scripts/bot-autonomy.sh"
    bot_autonomy_module_dir="${repo_root}/.devcontainer/config/bot-autonomy"
    codex_module="${bot_autonomy_module_dir}/codex-cli.sh"
    claude_module="${bot_autonomy_module_dir}/claude-code.sh"
    codex_bot_config="${repo_root}/.devcontainer/config/codex-managed-config.bot.toml"
    bash_bin="$(command -v bash)"

    [ -f "$init_env" ] || fail "init-env.sh not found at ${init_env}"
    [ -f "$ts_connect" ] || fail "tailscale-connect.sh not found at ${ts_connect}"
    [ -f "$codex_config" ] || fail "Codex managed config not found at ${codex_config}"
    [ -f "$codex_system_config" ] ||
        fail "Codex system defaults config not found at ${codex_system_config}"
    [ -x "$bot_autonomy" ] || fail "bot-autonomy.sh not found or not executable at ${bot_autonomy}"
    [ -x "$codex_module" ] || fail "bot-autonomy Codex module not found at ${codex_module}"
    [ -x "$claude_module" ] || fail "bot-autonomy Claude Code module not found at ${claude_module}"
    [ -f "$codex_bot_config" ] || fail "Codex bot managed config not found at ${codex_bot_config}"
    # Registry coverage, structural parity, and per-module fixture behavior
    # are scripts/test-bot-autonomy.sh's job (wired into `task verify`
    # unconditionally); this file only asserts the surrounding wiring.

    local bot_config dev_config agent_config shell_aliases gh_browser
    bot_config="${repo_root}/.devcontainer/devcontainer.json"
    dev_config="${repo_root}/.devcontainer/dev/devcontainer.json"
    agent_config="${repo_root}/.devcontainer/agent/devcontainer.json"
    shell_aliases="${repo_root}/.devcontainer/config/shell-aliases.sh"
    gh_browser="${repo_root}/.devcontainer/config/gh-browser.sh"
    [ -f "$bot_config" ] || fail "bot devcontainer.json not found at ${bot_config}"
    [ -f "$dev_config" ] || fail "dev devcontainer.json not found at ${dev_config}"
    [ -f "$agent_config" ] || fail "agent devcontainer.json not found at ${agent_config}"
    [ -f "$shell_aliases" ] || fail "shell-aliases.sh not found at ${shell_aliases}"
    [ -x "$gh_browser" ] || fail "GitHub browser bridge is missing or not executable at ${gh_browser}"
    grep '^unset BROWSER$' "$shell_aliases" >/dev/null ||
        fail "shell-aliases.sh no longer removes generic BROWSER from interactive shells"
    grep -E '^[[:space:]]*alias([[:space:]]+-[a-zA-Z0-9]+)*[[:space:]]+pnpm-relock(=|[[:space:]]|$)' "$shell_aliases" >/dev/null ||
        fail "shell-aliases.sh does not define pnpm-relock alias"
    ! grep -E '^[[:space:]]*alias([[:space:]]+-[a-zA-Z0-9]+)*[[:space:]]+fresh(=|[[:space:]]|$)' "$shell_aliases" >/dev/null ||
        fail "shell-aliases.sh still defines fresh alias, shadowing Fresh editor"
    ! grep -E '^[[:space:]]*alias([[:space:]]+-[a-zA-Z0-9]+)*[[:space:]]+(mc|nano|ttt)(=|[[:space:]]|$)' "$shell_aliases" >/dev/null ||
        fail "shell-aliases.sh defines alias shadowing mc, nano, or ttt"

    if command -v zsh >/dev/null 2>&1; then
        for shadowed in fresh mc nano ttt; do
            if zsh -c ". '$shell_aliases' 2>/dev/null && alias '$shadowed'" >/dev/null 2>&1; then
                fail "shell-aliases.sh defines alias shadowing ${shadowed} in zsh"
            fi
        done
    fi

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
        if grep 'features/go-task' "$cfg" >/dev/null; then
            fail "${cfg} installs task via a devcontainer Feature — the pinned shared image ships it (harmon-init#427)"
        fi
    done
    assert_image_pin "$dockerfile" >/dev/null

    # Run from a non-repo temp dir so `git rev-parse --is-inside-work-tree`
    # inside init-env.sh is false and the rebuild `git pull` never fires.
    local work_dir env_file codex_fixture
    work_dir="$(mktemp -d)"
    cd "$work_dir"

    # The shared managed layer is the balanced human default. Bot post-create
    # must switch only that profile to the Docker-boundary autonomy preset.
    #
    # Model and reasoning effort are DEFAULTS, so they are asserted against the
    # /etc/codex/config.toml layer -- never the managed one. Codex treats every
    # key in managed_config.toml as an unoverridable requirement, so a pin
    # there silently downgrades any worker dispatched with `-c` (an explicit
    # `-m` still overrode a pinned model; `-c model=` did not) (harmon-init#1186). The guard below is the durable half of that fix: it
    # fails if a preference ever drifts back into the boundary layer, in either
    # profile, which is how the bug arrived in the first place.
    [ "$(toml_root_scalar model "$codex_system_config")" = "gpt-6.1-sol" ] ||
        fail "Codex devcontainer default model is not gpt-6.1-sol"
    [ "$(toml_root_scalar model_reasoning_effort "$codex_system_config")" = "medium" ] ||
        fail "Codex devcontainer default reasoning is not medium"
    [ "$(toml_root_scalar project_doc_max_bytes "$codex_system_config")" = "65536" ] ||
        fail "Codex devcontainer default project-doc budget is not 65536"
    awk '
        /^[[:space:]]*\[/ { in_tui = ($0 ~ /^[[:space:]]*\["?tui"?\]/) ; next }
        in_tui && /^[[:space:]]*"?status_line"?[[:space:]]*=/ { found = 1 }
        END { exit(found ? 0 : 1) }
    ' "$codex_system_config" ||
        fail "status_line is not inside a [tui] table in the defaults layer;" \
            "as a root key Codex does not read it as the TUI status line"
    # Presence above, separation here: deleting a moved default from the system
    # file, or moving one back into a managed file, must both fail. Checking
    # only the second would let the first pass silently.
    local codex_boundary_file codex_forbidden_key
    for codex_boundary_file in "$codex_config" "$codex_bot_config"; do
        for codex_forbidden_key in model model_reasoning_effort project_doc_max_bytes; do
            if grep -qE "^[[:space:]]*\"?${codex_forbidden_key}\"?[[:space:]]*=" "$codex_boundary_file"; then
                fail "${codex_boundary_file##*/} pins '${codex_forbidden_key}' in the" \
                    "unoverridable managed layer; overridable defaults belong in" \
                    "codex-system-config.toml (harmon-init#1186)"
            fi
        done
        if grep -qE '^[[:space:]]*\[tui\]' "$codex_boundary_file"; then
            fail "${codex_boundary_file##*/} pins a [tui] table in the unoverridable" \
                "managed layer; it belongs in codex-system-config.toml (harmon-init#1186)"
        fi
    done
    [ "$(toml_root_scalar sandbox_mode "$codex_config")" = "workspace-write" ] ||
        fail "human Codex baseline does not enable workspace-write"
    [ "$(toml_root_scalar approval_policy "$codex_config")" = "on-request" ] ||
        fail "human Codex baseline does not use on-request approvals"
    if grep -E 'session-start-context|post-edit-format|enforce-conventional-commits' "$codex_config" >/dev/null; then
        fail "system-managed Codex hooks delegate into checkout-controlled tasks"
    fi
    # Codex and Claude Code bot policy now come from bot-autonomy modules,
    # installed and verified via bot-autonomy.sh apply/verify — never called
    # directly from post-create.sh. Fixture-level apply/verify coverage for
    # both modules (checksum install, drift detection) lives in
    # scripts/test-bot-autonomy.sh; this asserts the surrounding wiring only.
    codex_fixture="${work_dir}/codex-managed.toml"
    cp "$codex_config" "$codex_fixture"
    BOT_AUTONOMY_CODEX_MANAGED="$codex_fixture" bash "$codex_module" apply >/dev/null
    [ "$(toml_root_scalar sandbox_mode "$codex_fixture")" = "danger-full-access" ] ||
        fail "bot-autonomy Codex module did not remove the nested sandbox"
    [ "$(toml_root_scalar approval_policy "$codex_fixture")" = "never" ] ||
        fail "bot-autonomy Codex module did not disable approval prompts"

    # The Agent-Deck conductor-setup block was extracted out of
    # post-create-common.sh into its own script, so bot post-create can run
    # it AFTER apply (a conductor-spawned `claude` must not run before the
    # bot's policy is written) without delaying dev's identical step.
    local conductor_script
    conductor_script="${repo_root}/.devcontainer/scripts/post-create-conductor.sh"
    [ -x "$conductor_script" ] || fail "post-create-conductor.sh not found at ${conductor_script}"
    # Match the actual invocation, not the phrase alone — a nearby comment in
    # post-create-common.sh legitimately still SAYS "agent-deck conductor
    # setup" (explaining why link-claude-json.sh must run early) without the
    # block itself having come back.
    if grep 'agent-deck conductor setup "\$REPO_NAME"' "${repo_root}/.devcontainer/scripts/post-create-common.sh" >/dev/null; then
        fail "the Agent-Deck conductor-setup block was not extracted out of post-create-common.sh"
    fi
    grep 'agent-deck conductor setup "\$REPO_NAME"' "$conductor_script" >/dev/null ||
        fail "post-create-conductor.sh does not contain the extracted conductor-setup block"

    # Each profile's step order matches the corrected ordering: shared setup
    # (with the conductor block already extracted out, checked above), then
    # ensure-antigravity-cli.sh, then the profile's own autonomy step
    # (bot-autonomy.sh apply for bot; apply-antigravity-settings.sh for dev),
    # then the conductor step LAST — never before the autonomy step.
    assert_step_order() {
        local file="$1" step_after_shared="$2"
        local order
        order="$(grep -Ev '^[[:space:]]*#' "$file" |
            grep -E 'post-create-common\.sh|ensure-antigravity-cli\.sh|post-create-conductor\.sh|bot-autonomy\.sh apply|apply-antigravity-settings\.sh')"
        case "$(printf '%s\n' "$order" | sed -n '1p')" in
        *"post-create-common.sh"*) ;;
        *) fail "${file} does not run post-create-common.sh first" ;;
        esac
        case "$(printf '%s\n' "$order" | sed -n '2p')" in
        *"ensure-antigravity-cli.sh"*) ;;
        *) fail "${file} does not run ensure-antigravity-cli.sh second" ;;
        esac
        case "$(printf '%s\n' "$order" | sed -n '3p')" in
        *"$step_after_shared"*) ;;
        *) fail "${file} does not run ${step_after_shared} third" ;;
        esac
        case "$(printf '%s\n' "$order" | tail -1)" in
        *"post-create-conductor.sh"*) ;;
        *) fail "${file} does not run post-create-conductor.sh last" ;;
        esac
    }
    assert_step_order "${repo_root}/.devcontainer/post-create.sh" "bot-autonomy.sh apply"
    assert_step_order "${repo_root}/.devcontainer/dev/post-create.sh" "apply-antigravity-settings.sh"
    # verify SHALL also run at the end of post-create (not only post-start),
    # so a divergence between what apply wrote and a harness's actual
    # effective state (e.g. an already-present workspace-level OpenCode
    # override) fails container creation rather than surfacing only later.
    case "$(grep -Ev '^[[:space:]]*#' "${repo_root}/.devcontainer/post-create.sh" | grep -E 'bot-autonomy\.sh (apply|verify)' | tail -1)" in
    *"bot-autonomy.sh verify"*) ;;
    *) fail "bot post-create does not call bot-autonomy.sh verify after apply" ;;
    esac
    # Strip comments first: dev/post-create.sh's own explanatory comment names
    # bot-autonomy.sh to say it does NOT call it, which a bare grep would
    # misread as a real invocation.
    if grep 'bot-autonomy.sh' \
        < <(grep -Ev '^[[:space:]]*#' "${repo_root}/.devcontainer/dev/post-create.sh") >/dev/null; then

        fail "human post-create calls bot-autonomy.sh (bot-only)"
    fi
    grep 'bot-autonomy.sh verify' "${repo_root}/.devcontainer/post-start.sh" >/dev/null ||
        fail "bot post-start does not call bot-autonomy.sh verify"
    # verify must run BEFORE post-start-common.sh (whose conductor-start block
    # must never launch against a drifted policy) and NODE_OPTIONS must be
    # unset before verify (so a Node-based harness CLI verify step is not
    # itself broken by an inherited VS Code debug value).
    #
    # The grep filter below deliberately sees only those three Node-relevant
    # steps, so this asserts their ORDER RELATIVE TO EACH OTHER, not that
    # nothing whatsoever precedes them. The gh-identity tripwire (10b) does
    # run first, by design — it is a bash script driving a Go binary, so the
    # unset does not apply to it, and running it ahead of the set -e verify
    # step is what makes it fire on every start.
    local post_start_order
    post_start_order="$(grep -Ev '^[[:space:]]*#' "${repo_root}/.devcontainer/post-start.sh" |
        grep -E 'unset NODE_OPTIONS|bot-autonomy\.sh verify|post-start-common\.sh')"
    [ "$(printf '%s\n' "$post_start_order" | sed -n '1p')" = "unset NODE_OPTIONS" ] ||
        fail "bot post-start does not unset NODE_OPTIONS before the Node-dependent startup steps"
    case "$(printf '%s\n' "$post_start_order" | sed -n '2p')" in
    *"bot-autonomy.sh verify") ;;
    *) fail "bot post-start does not call bot-autonomy.sh verify immediately after unsetting NODE_OPTIONS" ;;
    esac
    case "$(printf '%s\n' "$post_start_order" | sed -n '3p')" in
    *"post-start-common.sh") ;;
    *) fail "bot post-start does not call post-start-common.sh after bot-autonomy.sh verify" ;;
    esac

    # Behavioral proof of that ordering, not just textual: run the REAL,
    # unmodified post-start.sh in an isolated scratch tree (its own
    # .devcontainer/scripts/post-start-common.sh shadowed by a sentinel-only
    # stand-in, so no real side effect — sudo chown, git config writes, the
    # Agent-Deck conductor-start block — ever fires). `set -euo pipefail`
    # is what actually enforces the ordering at runtime; grepping line order
    # alone cannot prove a verify failure really aborts the script before
    # post-start-common.sh's conductor-start block would ever run.
    local ps_work ps_sentinel ps_registry ps_module_dir
    ps_work="${work_dir}/post-start-behavioral"
    mkdir -p "${ps_work}/.devcontainer/scripts" "${ps_work}/.devcontainer/config/bot-autonomy"
    cp "${repo_root}/.devcontainer/post-start.sh" "${ps_work}/.devcontainer/post-start.sh"
    cp "${repo_root}/.devcontainer/scripts/bot-autonomy.sh" "${ps_work}/.devcontainer/scripts/bot-autonomy.sh"
    cp "${repo_root}/.devcontainer/config/bot-autonomy/unsupported.json" "${ps_work}/.devcontainer/config/bot-autonomy/"
    echo '{}' >"${ps_work}/.devcontainer/config/bot-autonomy/aliases.json"
    cat >"${ps_work}/.devcontainer/scripts/post-start-common.sh" <<'SENTINEL_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
echo "SENTINEL: post-start-common.sh reached" >>"${SENTINEL_LOG:?SENTINEL_LOG not set}"
SENTINEL_SCRIPT
    chmod +x "${ps_work}/.devcontainer/post-start.sh" "${ps_work}/.devcontainer/scripts/bot-autonomy.sh" \
        "${ps_work}/.devcontainer/scripts/post-start-common.sh"
    # A registry resolving cleanly via the unsupported bucket alone (no real
    # harness executable required) so verify's SUCCESS path is exercised
    # without depending on claude/codex/agy/opencode being installed here.
    ps_registry="${ps_work}/registry.json"
    printf '{"harnesses": [{"slug": "qwen-code"}]}' >"$ps_registry"
    ps_module_dir="${ps_work}/.devcontainer/config/bot-autonomy"

    ps_sentinel="${ps_work}/sentinel-drifted.log"
    rm -f "$ps_sentinel"
    if (cd "$ps_work" && BOT_AUTONOMY_REGISTRY=/nonexistent-registry.json \
        SENTINEL_LOG="$ps_sentinel" bash .devcontainer/post-start.sh) >/dev/null 2>&1; then
        fail "post-start.sh exited 0 despite bot-autonomy.sh verify failing (drifted-policy fixture)"
    fi
    [ ! -f "$ps_sentinel" ] ||
        fail "post-start-common.sh's conductor-start block ran despite a drifted policy — bot-autonomy.sh verify did not abort post-start.sh first"

    ps_sentinel="${ps_work}/sentinel-clean.log"
    rm -f "$ps_sentinel"
    (cd "$ps_work" && BOT_AUTONOMY_REGISTRY="$ps_registry" BOT_AUTONOMY_CONFIG_DIR="$ps_module_dir" \
        SENTINEL_LOG="$ps_sentinel" bash .devcontainer/post-start.sh) >/dev/null 2>&1 ||
        fail "post-start.sh failed against a correctly-configured (verify-clean) fixture"
    [ -f "$ps_sentinel" ] ||
        fail "post-start-common.sh never ran even though bot-autonomy.sh verify passed"

    ps_sentinel="${ps_work}/sentinel-node-options.log"
    rm -f "$ps_sentinel"
    (cd "$ps_work" && NODE_OPTIONS="--require /nonexistent/bootloader.js" \
        BOT_AUTONOMY_REGISTRY="$ps_registry" BOT_AUTONOMY_CONFIG_DIR="$ps_module_dir" \
        SENTINEL_LOG="$ps_sentinel" bash .devcontainer/post-start.sh) >/dev/null 2>&1 ||
        fail "post-start.sh failed with an inherited NODE_OPTIONS value that would break a Node-based harness CLI, against an otherwise correctly-configured fixture"
    [ -f "$ps_sentinel" ] ||
        fail "post-start-common.sh never ran when only NODE_OPTIONS (correctly unset before verify) was hostile"

    # `docker exec` has no workspace-folder-aware default cwd — the
    # Dockerfile sets no WORKDIR, so a bare exec lands wherever the base
    # image defaults to, not the mounted workspace folder — so this
    # script's own container-mode exec of bot-autonomy.sh verify (a
    # relative path) must pin its working directory explicitly. Guard
    # against that regressing silently: the exec line and the one after it
    # must together carry either `-w` on `docker exec` or an absolute path
    # to the script.
    local exec_pair
    exec_pair="$(grep -A1 -F 'bot_autonomy_out="$(docker exec' "${repo_root}/scripts/devcontainer-assert.sh")"
    [ -n "$exec_pair" ] ||
        fail "devcontainer-assert.sh no longer execs bot-autonomy.sh verify the expected way in container mode"
    case "$exec_pair" in
    *' -w '*) ;;
    *'bash /'*) ;;
    *) fail "devcontainer-assert.sh's container-mode bot-autonomy.sh verify exec pins no working directory (-w on docker exec) and uses no absolute script path — a relative path resolves against the container's default cwd, not the workspace folder" ;;
    esac

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
    grep '^TS_AUTHKEY=fromop$' "$env_file" >/dev/null ||
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

    # 6b. A run that changes nothing must not TOUCH the env-file. init-env.sh is
    #     an initializeCommand, so it fires on every VS Code connect, not just
    #     rebuilds — and an unconditional rewrite churns the file's mtime, which
    #     is enough for Coder's devcontainer integration to read the config as
    #     dirty and recreate the container. mtime, not just content, is the
    #     assertion: a byte-identical rewrite would pass a content-only check
    #     and still cause the recreation loop.
    local mtime_before mtime_after content_before
    env_file="${work_dir}/env-idempotent"
    printf 'TS_AUTHKEY=stable\nCLAUDE_CODE_OAUTH_TOKEN=tok\nAGENT_DECK_TELEGRAM_KEY=key\n' >"$env_file"
    # First run settles the file (it may legitimately rewrite here).
    TS_AUTHKEY=stable CLAUDE_CODE_OAUTH_TOKEN=tok AGENT_DECK_TELEGRAM_KEY=key \
        bash "$init_env" "$env_file" "${dev_allow[@]}" 2>/dev/null
    content_before="$(cat "$env_file")"
    mtime_before="$(stat -c %Y "$env_file" 2>/dev/null || stat -f %m "$env_file")"
    sleep 1
    # Second run with an identical host env: nothing to inject, nothing to evict.
    TS_AUTHKEY=stable CLAUDE_CODE_OAUTH_TOKEN=tok AGENT_DECK_TELEGRAM_KEY=key \
        bash "$init_env" "$env_file" "${dev_allow[@]}" 2>/dev/null
    mtime_after="$(stat -c %Y "$env_file" 2>/dev/null || stat -f %m "$env_file")"
    [ "$mtime_before" = "$mtime_after" ] ||
        fail "init-env.sh rewrote an unchanged env-file (mtime ${mtime_before} -> ${mtime_after}) — the mtime churn makes Coder recreate the container on every connect"
    [ "$(cat "$env_file")" = "$content_before" ] ||
        fail "init-env.sh changed the contents of an already-settled env-file"

    #     A run that DOES have work to do must still write. Guards the obvious
    #     wrong fix for the above: skipping the write unconditionally.
    env_file="${work_dir}/env-idempotent-change"
    printf 'TS_AUTHKEY=old\n' >"$env_file"
    TS_AUTHKEY=new bash "$init_env" "$env_file" "${dev_allow[@]}" 2>/dev/null
    grep '^TS_AUTHKEY=new$' "$env_file" >/dev/null ||
        fail "init-env.sh skipped a write it needed to make — the changed TS_AUTHKEY never reached the env-file"

    # 6c. Permissions are enforced even when the CONTENT needs no write. A
    #     pre-existing env-file (copied from devcontainer.env.example under a
    #     permissive umask) holds secrets at 0644, and a skip-on-identical run
    #     must still tighten it — while leaving mtime alone (chmod never
    #     touches mtime, so both assertions can hold at once).
    env_file="${work_dir}/env-loose-perms"
    printf 'TS_AUTHKEY=stable\nCLAUDE_CODE_OAUTH_TOKEN=tok\nAGENT_DECK_TELEGRAM_KEY=key\n' >"$env_file"
    chmod 644 "$env_file"
    mtime_before="$(stat -c %Y "$env_file" 2>/dev/null || stat -f %m "$env_file")"
    sleep 1
    TS_AUTHKEY=stable CLAUDE_CODE_OAUTH_TOKEN=tok AGENT_DECK_TELEGRAM_KEY=key \
        bash "$init_env" "$env_file" "${dev_allow[@]}" 2>/dev/null
    mode_after="$(stat -c '%a' "$env_file" 2>/dev/null || stat -f '%Lp' "$env_file")"
    [ "$mode_after" = "600" ] ||
        fail "init-env.sh left a secret env-file at mode ${mode_after} — 0600 must be enforced on every run, not only on rewrites"
    mtime_after="$(stat -c %Y "$env_file" 2>/dev/null || stat -f %m "$env_file")"
    [ "$mtime_before" = "$mtime_after" ] ||
        fail "init-env.sh churned mtime while fixing permissions on an unchanged env-file"

    # 7. tailscale-connect.sh no-ops (exit 0, prints its "unavailable" message)
    #    when `tailscale` is not on PATH. Invoke with an absolute bash path so
    #    the unreachable PATH doesn't also hide the interpreter.
    #    `env -u DEVCONTAINER_TAILSCALE` is load-bearing: THIS SUITE RUNS INSIDE
    #    A DEVCONTAINER, and the dev profile sets that marker to true, which
    #    makes a missing CLI fatal rather than a skip. Without the strip, this
    #    assertion silently inverts depending on which profile runs it — passing
    #    on the host and on the bot profile, failing on dev.
    local ts_out
    if ! ts_out="$(env -u DEVCONTAINER_TAILSCALE -u DEVCONTAINER_TAILSCALE_REQUIRED -u DEVCONTAINER_TAILSCALE_OPTIONAL \
        PATH="/nonexistent" "$bash_bin" "$ts_connect" 2>&1)"; then
        fail "tailscale-connect.sh exited nonzero when tailscale is absent"
    fi
    case "$ts_out" in
    *"unavailable"*) ;;
    *) fail "tailscale-connect.sh did not report tailscale unavailable: ${ts_out}" ;;
    esac

    # 7b. The tailnet gate itself. A profile whose defining feature is the
    #     tailnet must FAIL ITS BUILD when it cannot join one — it must never
    #     start clean, report success, and sit there logged out. Every path in
    #     this script used to `exit 0`, which is exactly that failure.
    #
    #     Every case strips both knobs from the inherited environment for the
    #     reason above, then sets only what it is testing.
    local ts_bin ts_sock ts_sock_ready ts_up_marker ts_rc ts_case_out ts_dep ts_dep_path
    ts_bin="${work_dir}/tailscale-bin"
    mkdir -p "$ts_bin"
    ln -s "$bash_bin" "${ts_bin}/bash"
    for ts_dep in seq sleep tail cat printf hostname basename cut git; do
        ts_dep_path="$(command -v "$ts_dep" 2>/dev/null)" || continue
        ln -s "$ts_dep_path" "${ts_bin}/${ts_dep}"
    done
    # timeout is NOT optional and NOT resolvable by name alone: Homebrew
    # coreutils on macOS installs it as `gtimeout`, the same split
    # devcontainer-smoke.sh handles. tailscale-connect.sh calls bare `timeout`,
    # and the constrained PATH below is all it can see — so resolve whichever
    # exists and link it UNDER THE NAME the script calls. Skipping it silently
    # (as a `continue` in the loop above would) leaves cases (h)-(j) exiting
    # 127 on a supported dev platform, with the suite blaming tailscale.
    ts_dep_path="$(command -v timeout || command -v gtimeout)" ||
        fail "neither timeout nor gtimeout is available for the tailscale unit cases"
    ln -s "$ts_dep_path" "${ts_bin}/timeout"
    # sudo → exec "$@" and pgrep → exit 0: the connect paths below must be
    # reachable without root and without a real daemon. pgrep succeeding means
    # the script skips the start-tailscaled branch and goes straight to the
    # unconditional socket wait, which is the ordering this change introduced.
    printf '%s\n' '#!/bin/sh' 'exec "$@"' >"${ts_bin}/sudo"
    printf '%s\n' '#!/bin/sh' 'exit 0' >"${ts_bin}/pgrep"
    chmod 0755 "${ts_bin}/sudo" "${ts_bin}/pgrep"

    # The tailscale stub answers `status --json` from TS_STUB_STATE and `up`
    # from TS_STUB_UP_RC, touching TS_STUB_UP_MARKER so a case can tell whether
    # `up` ran at all — which is how case (g) proves the already-connected fast
    # path short-circuits instead of reconnecting.
    cat >"${ts_bin}/tailscale" <<'TS_STUB'
#!/bin/sh
case "$1" in
status)
    # TS_STUB_STATUS_SILENT=1 is a daemon that is NOT answering: the socket
    # inode is there (a crashed tailscaled leaves one behind) but `status`
    # returns nothing. The readiness loop must keep waiting and then bail,
    # rather than treating the stale inode as proof the daemon is up.
    [ "${TS_STUB_STATUS_SILENT:-0}" = "1" ] && exit 1
    # TS_STUB_STATUS_HANG=1 is a daemon that accepts the request and never
    # answers. It must be killed by the probe's own timeout, and the loop must
    # still finish on its wall-clock deadline rather than multiplying the hang
    # by its iteration count.
    if [ "${TS_STUB_STATUS_HANG:-0}" = "1" ]; then
        sleep 120
        exit 1
    fi
    printf '{"BackendState": "%s"}\n' "${TS_STUB_STATE:-NeedsLogin}"
    exit 0
    ;;
up)
    [ -n "${TS_STUB_UP_MARKER:-}" ] && : >"${TS_STUB_UP_MARKER}"
    [ "${TS_STUB_UP_RC:-0}" = "0" ] || echo "stub: tailscale up refused the key" >&2
    exit "${TS_STUB_UP_RC:-0}"
    ;;
esac
exit 0
TS_STUB
    chmod 0755 "${ts_bin}/tailscale"

    # Cases (g)-(m) reach the connect paths, which means getting past
    # `[ -S "${TS_SOCKET}" ]` — so they need a REAL unix socket; there is no
    # way to satisfy `-S` without binding one. Cases (a)-(f) all bail before
    # the socket wait and need none.
    #
    # Creating it is best-effort and must NEVER fail the suite, because two
    # environments legitimately cannot: a sandbox that denies AF_UNIX bind
    # (Codex's workspace-write sandbox does), and any host whose TMPDIR makes
    # the path exceed sun_path's ~104-byte limit — mktemp -d under a long
    # TMPDIR is enough, and the error there is a confusing "path too long"
    # rather than anything about tailscale. Both used to take down every
    # assertion in this file, including the ones that have nothing to do with
    # the tailnet, and this script ships verbatim to generated repos where the
    # same `task ci` is expected to run locally.
    #
    # So: bind if we can, and otherwise SKIP (g)-(l) loudly. The skip is
    # printed rather than silent — a quiet coverage hole is the failure mode
    # this whole change exists to prevent — and CI and the devcontainer, where
    # the bind succeeds, still run every case.
    ts_sock="${work_dir}/ts.sock"
    ts_sock_ready=no
    if ! command -v python3 >/dev/null 2>&1; then
        echo "==> SKIP tailscale cases (g)-(m): python3 is unavailable to create a stub socket."
    elif python3 -c 'import socket, sys
s = socket.socket(socket.AF_UNIX)
s.bind(sys.argv[1])
s.listen(1)' "$ts_sock" 2>/dev/null && [ -S "$ts_sock" ]; then
        ts_sock_ready=yes
    else
        echo "==> SKIP tailscale cases (g)-(m): cannot bind a stub unix socket at ${ts_sock}"
        echo "    (sandbox denial, or TMPDIR makes the path exceed sun_path's ~104-byte limit)."
        echo "    Cases (a)-(f) still run; CI and the devcontainer run the full set."
    fi
    ts_up_marker="${work_dir}/ts-up-ran"

    # ts_connect_run <expected-rc> <label> [VAR=VAL ...]
    # Runs tailscale-connect.sh with both knobs stripped and only the named
    # variables set, then asserts the exit code. Output lands in ts_case_out.
    ts_connect_run() {
        local want_rc="$1" label="$2"
        shift 2
        ts_rc=0
        # The caller's assignments come LAST so a case can override any of the
        # defaults — case (a) overrides PATH to take the CLI away, and a fixed
        # PATH here would silently hand it back and test the wrong path.
        ts_case_out="$(env -u DEVCONTAINER_TAILSCALE -u DEVCONTAINER_TAILSCALE_REQUIRED -u DEVCONTAINER_TAILSCALE_OPTIONAL \
            -u TS_AUTHKEY -u TS_AUTH_KEY -u TS_STUB_STATE -u TS_STUB_UP_RC \
            -u TS_STUB_STATUS_SILENT -u TS_STUB_STATUS_HANG \
            TS_SOCKET_PATH="$ts_sock" TS_STUB_UP_MARKER="$ts_up_marker" \
            PATH="$ts_bin" "$@" "$bash_bin" "$ts_connect" 2>&1)" || ts_rc=$?
        [ "$ts_rc" = "$want_rc" ] ||
            fail "tailscale-connect.sh case ${label}: exited ${ts_rc}, expected ${want_rc}: ${ts_case_out}"
    }

    # (a) optional + no CLI → exit 0, and still says "unavailable" (test 7's
    #     assertion greps for that substring, so the wording is a contract).
    ts_connect_run 0 "a (optional, no CLI)" PATH="/nonexistent"
    case "$ts_case_out" in
    *"unavailable"*) ;;
    *) fail "tailscale-connect.sh case a: did not report tailscale unavailable: ${ts_case_out}" ;;
    esac

    # (b) required + no CLI → exit 1, FATAL. The missing-CLI path is the one
    #     that used to be most obviously harmless.
    ts_rc=0
    ts_case_out="$(env -u DEVCONTAINER_TAILSCALE_OPTIONAL \
        DEVCONTAINER_TAILSCALE_REQUIRED=true PATH="/nonexistent" \
        "$bash_bin" "$ts_connect" 2>&1)" || ts_rc=$?
    [ "$ts_rc" = "1" ] ||
        fail "tailscale-connect.sh case b: exited ${ts_rc} with no CLI and the tailnet required, expected 1"
    case "$ts_case_out" in
    *FATAL*) ;;
    *) fail "tailscale-connect.sh case b: required + no CLI did not report FATAL: ${ts_case_out}" ;;
    esac

    # (c) required + CLI + no key → exit 1, and names the variable to set.
    ts_connect_run 1 "c (required, no key)" DEVCONTAINER_TAILSCALE_REQUIRED=true
    case "$ts_case_out" in
    *TS_AUTHKEY*) ;;
    *) fail "tailscale-connect.sh case c: missing-key FATAL does not name TS_AUTHKEY: ${ts_case_out}" ;;
    esac

    # (d) optional + CLI + no key → exit 0. The bot profile and every plain
    #     local devcontainer live here; this is the behavior that must NOT
    #     change.
    ts_connect_run 0 "d (optional, no key)"

    # (e) required + the opt-out → exit 0. The smoke test's path.
    ts_connect_run 0 "e (required, opted out)" \
        DEVCONTAINER_TAILSCALE_REQUIRED=true DEVCONTAINER_TAILSCALE_OPTIONAL=true

    # (f) required + DEVCONTAINER_TAILSCALE_OPTIONAL=1 → exit 1. ONLY the exact
    #     string `true` demotes; a truthy-looking value must not disarm a gate.
    ts_connect_run 1 "f (required, OPTIONAL=1 is not true)" \
        DEVCONTAINER_TAILSCALE_REQUIRED=true DEVCONTAINER_TAILSCALE_OPTIONAL=1

    if [ "$ts_sock_ready" = "yes" ]; then
        # (g) required + BackendState=Running → exit 0 via the fast path, and
        #     `tailscale up` is NOT called. Proves readiness is judged by
        #     BackendState rather than by reconnecting unconditionally.
        rm -f "$ts_up_marker"
        ts_connect_run 0 "g (required, already Running)" \
            DEVCONTAINER_TAILSCALE_REQUIRED=true TS_AUTHKEY=stub-key TS_STUB_STATE=Running
        [ ! -e "$ts_up_marker" ] ||
            fail "tailscale-connect.sh case g: ran 'tailscale up' although BackendState was already Running"

        # (h) required + NeedsLogin + up succeeds → exit 0, and reports the
        #     environment-appropriate node name.
        rm -f "$ts_up_marker"
        ts_connect_run 0 "h (required, NeedsLogin, up ok)" \
            DEVCONTAINER_TAILSCALE_REQUIRED=true TS_AUTHKEY=stub-key \
            TS_STUB_STATE=NeedsLogin TS_STUB_UP_RC=0
        [ -e "$ts_up_marker" ] ||
            fail "tailscale-connect.sh case h: never ran 'tailscale up' from NeedsLogin"
        case "$ts_case_out" in
        *"Connected to tailnet as cr-"* | *"Connected to tailnet as dc-"* | *"Connected to tailnet as gh-"*) ;;
        *) fail "tailscale-connect.sh case h: did not report a prefixed node name: ${ts_case_out}" ;;
        esac

        # (i) required + NeedsLogin + up FAILS → exit 1, FATAL. THE case this whole
        #     change exists for: an expired or already-consumed auth key. Mutating
        #     the script back to its swallow-on-failure behavior makes this one
        #     return 0, which is the mutation test the issue asks for.
        ts_connect_run 1 "i (required, NeedsLogin, up failed)" \
            DEVCONTAINER_TAILSCALE_REQUIRED=true TS_AUTHKEY=stub-key \
            TS_STUB_STATE=NeedsLogin TS_STUB_UP_RC=1
        case "$ts_case_out" in
        *FATAL*) ;;
        *) fail "tailscale-connect.sh case i: failed connect did not report FATAL: ${ts_case_out}" ;;
        esac

        # (j) optional + NeedsLogin + up FAILS → exit 0. The unchanged behavior
        #     everywhere the tailnet is genuinely optional.
        ts_connect_run 0 "j (optional, NeedsLogin, up failed)" \
            TS_AUTHKEY=stub-key TS_STUB_STATE=NeedsLogin TS_STUB_UP_RC=1

        # (k) required + a STALE socket: the inode exists (this fixture binds
        #     and then exits, which is exactly what a crashed tailscaled leaves
        #     behind) but the daemon does not answer. Readiness must not be
        #     satisfied by the inode alone — it must wait, then bail. `up` must
        #     never run against a daemon that never came up.
        rm -f "$ts_up_marker"
        ts_connect_run 1 "k (required, stale socket, daemon silent)" \
            DEVCONTAINER_TAILSCALE_REQUIRED=true TS_AUTHKEY=stub-key TS_STUB_STATUS_SILENT=1
        case "$ts_case_out" in
        *"not answering"*) ;;
        *) fail "tailscale-connect.sh case k: did not report an unanswering daemon: ${ts_case_out}" ;;
        esac
        [ ! -e "$ts_up_marker" ] ||
            fail "tailscale-connect.sh case k: ran 'tailscale up' against a daemon that never answered"

        # (l) the same, optional → exit 0. A silent daemon is not fatal where
        #     the tailnet was never required.
        ts_connect_run 0 "l (optional, stale socket, daemon silent)" \
            TS_AUTHKEY=stub-key TS_STUB_STATUS_SILENT=1

        # (m) required + a daemon that HANGS rather than answering. The point
        #     is the BOUND, not just the exit code: a probe timeout multiplied
        #     by an iteration count would take minutes, and an unkilled probe
        #     would never return at all, so the failure message's deadline
        #     would be a lie precisely when it is load-bearing. Allow generous
        #     slack over the 10s deadline (CI is slow and each probe carries
        #     its own budget) while still failing decisively on a loop that
        #     multiplies instead of deadlines.
        local ts_hang_start ts_hang_elapsed
        ts_hang_start=$SECONDS
        ts_connect_run 1 "m (required, daemon hangs)" \
            DEVCONTAINER_TAILSCALE_REQUIRED=true TS_AUTHKEY=stub-key TS_STUB_STATUS_HANG=1
        ts_hang_elapsed=$((SECONDS - ts_hang_start))
        [ "$ts_hang_elapsed" -lt 60 ] ||
            fail "tailscale-connect.sh case m: took ${ts_hang_elapsed}s against a hanging daemon — the readiness wait is not bounded by its deadline"
        case "$ts_case_out" in
        *"not answering"*) ;;
        *) fail "tailscale-connect.sh case m: did not report an unanswering daemon: ${ts_case_out}" ;;
        esac
    fi

    # 8. Antigravity runs without permission prompts inside the container,
    #    which is the isolation boundary. The apply helper must enforce those
    #    keys while preserving unrelated settings in the persistent volume.
    local agy_defaults agy_apply agy_ensure agy_home agy_settings agy_backup agy_workspace agy_workspace_moved
    agy_defaults="${repo_root}/.devcontainer/config/antigravity-settings.json"
    agy_dev_defaults="${repo_root}/.devcontainer/config/antigravity-settings-dev.json"
    agy_apply="${repo_root}/.devcontainer/config/apply-antigravity-settings.sh"
    agy_ensure="${repo_root}/.devcontainer/config/ensure-antigravity-cli.sh"
    [ -f "$agy_defaults" ] || fail "Antigravity defaults not found at ${agy_defaults}"
    [ -f "$agy_apply" ] || fail "Antigravity settings helper not found at ${agy_apply}"
    [ -f "$agy_ensure" ] || fail "Antigravity compatibility installer not found at ${agy_ensure}"

    # ensure-antigravity-cli.sh now owns ~/.local/bin/agy-real (never agy
    # directly) and is gated entirely on the rendered
    # HARMON_BOT_AUTONOMY_ANTIGRAVITY marker — no unconditional download.
    local agy_roll_home agy_system_binary
    agy_roll_home="${work_dir}/agy-roll-home"
    agy_system_binary="${work_dir}/agy-system-binary"
    mkdir -p "${agy_roll_home}/.local/bin"
    printf '%s\n' '#!/bin/sh' 'printf "%s\\n" "1.1.11"' >"$agy_system_binary"
    printf '%s\n' '#!/bin/sh' 'printf "%s\\n" "1.0.0"' >"${agy_roll_home}/.local/bin/agy-real"
    chmod 0755 "$agy_system_binary" "${agy_roll_home}/.local/bin/agy-real"

    # Disabled marker (including entirely absent): no download. This models a
    # rolling update from a pre-ownership-metadata release: neither the natural
    # agy -> agy-real shape nor the markerless executable proves ownership, so
    # both paths must be preserved byte-for-byte.
    local agy_disabled_home agy_disabled_real_before
    agy_disabled_home="${work_dir}/agy-disabled-home"
    agy_disabled_real_before="${work_dir}/agy-disabled-real-before"
    mkdir -p "${agy_disabled_home}/.local/bin"
    printf '%s\n' '#!/bin/sh' 'printf "%s\\n" "1.0.0"' >"${agy_disabled_home}/.local/bin/agy-real"
    chmod 0755 "${agy_disabled_home}/.local/bin/agy-real"
    cp "${agy_disabled_home}/.local/bin/agy-real" "$agy_disabled_real_before"
    ln -s "${agy_disabled_home}/.local/bin/agy-real" "${agy_disabled_home}/.local/bin/agy"
    # env -u: the outer shell (or containerEnv) may export
    # HARMON_BOT_AUTONOMY_ANTIGRAVITY=enabled; clear it so the script sees
    # the disabled path.
    env -u HARMON_BOT_AUTONOMY_ANTIGRAVITY HOME="$agy_disabled_home" bash "$agy_ensure" >/dev/null
    cmp -s "$agy_disabled_real_before" "${agy_disabled_home}/.local/bin/agy-real" ||
        fail "disabled cleanup changed a markerless pre-metadata agy-real"
    [ -L "${agy_disabled_home}/.local/bin/agy" ] &&
        [ "$(readlink "${agy_disabled_home}/.local/bin/agy")" = "${agy_disabled_home}/.local/bin/agy-real" ] ||
        fail "disabled cleanup changed a markerless pre-metadata agy symlink"
    [ ! -e "${agy_disabled_home}/.local/bin/.agy-real.harmon-init-owned" ] ||
        fail "disabled cleanup claimed a markerless pre-metadata agy-real"
    [ ! -e "${agy_disabled_home}/.local/bin/.agy.harmon-init-owned" ] ||
        fail "disabled cleanup claimed a markerless pre-metadata agy launcher"

    # Enabled marker, current shared-image binary already sufficient, no
    # pre-existing local shadow: no shadow copy is created, and agy stays
    # absent rather than becoming a dangling symlink.
    local agy_image_home
    agy_image_home="${work_dir}/agy-image-home"
    mkdir -p "$agy_image_home"
    HOME="$agy_image_home" HARMON_BOT_AUTONOMY_ANTIGRAVITY=enabled \
        HARMON_ANTIGRAVITY_SYSTEM_BINARY="$agy_system_binary" bash "$agy_ensure" >/dev/null
    [ ! -e "${agy_image_home}/.local/bin/agy-real" ] ||
        fail "current shared-image Antigravity binary created a persistent shadow copy"
    [ ! -e "${agy_image_home}/.local/bin/agy" ] && [ ! -L "${agy_image_home}/.local/bin/agy" ] ||
        fail "agy is present (or a dangling symlink) with no agy-real to back it"

    # Enabled marker, a stale local shadow already exists: refreshed to the
    # pinned version, and agy (re)pointed at it as a plain symlink.
    HOME="$agy_roll_home" HARMON_BOT_AUTONOMY_ANTIGRAVITY=enabled \
        HARMON_ANTIGRAVITY_SYSTEM_BINARY="$agy_system_binary" bash "$agy_ensure" >/dev/null
    [ "$("${agy_roll_home}/.local/bin/agy-real" --version)" = "1.1.11" ] ||
        fail "stale user-local Antigravity binary still shadows the shared-image pin"
    [ "$(readlink -f "${agy_roll_home}/.local/bin/agy")" = "$(readlink -f "${agy_roll_home}/.local/bin/agy-real")" ] ||
        fail "ensure-antigravity-cli.sh did not point agy at agy-real as a plain symlink"
    [ -f "${agy_roll_home}/.local/bin/.agy-real.harmon-init-owned" ] &&
        [ -f "${agy_roll_home}/.local/bin/.agy.harmon-init-owned" ] ||
        fail "ensure-antigravity-cli.sh did not publish independent path ownership proofs"

    # Toggling back to disabled fully removes both — not merely skips the
    # download — reaching absence rather than a dangling link.
    # env -u: same containerEnv leak as the disabled-marker case above.
    env -u HARMON_BOT_AUTONOMY_ANTIGRAVITY HOME="$agy_roll_home" bash "$agy_ensure" >/dev/null
    [ ! -e "${agy_roll_home}/.local/bin/agy-real" ] &&
        [ ! -e "${agy_roll_home}/.local/bin/agy" ] &&
        [ ! -e "${agy_roll_home}/.local/bin/.agy-real.harmon-init-owned" ] &&
        [ ! -e "${agy_roll_home}/.local/bin/.agy.harmon-init-owned" ] ||
        fail "toggling the marker off did not fully remove agy-real/agy"

    agy_home="${work_dir}/agy-home"
    agy_settings="${agy_home}/.gemini/antigravity-cli/settings.json"
    agy_backup="${agy_settings}.harmon-init-autonomy-backup"
    agy_workspace="${work_dir}/trusted-workspace"
    agy_workspace_moved="${work_dir}/trusted-workspace-renamed"
    mkdir -p "$(dirname "$agy_settings")"
    printf '%s\n' '{"model":"Gemini test","toolPermission":"request-review","permissions":{"allow":["command(task)"],"bash":"deny"}}' >"$agy_settings"
    HOME="$agy_home" bash "$agy_apply" apply "$agy_defaults" "$agy_workspace" >/dev/null
    jq -e '
        .model == "Gemini test" and
        .permissions == {} and
        .toolPermission == "always-proceed" and
        .artifactReviewPolicy == "always-proceed" and
        .allowNonWorkspaceAccess == true and
        .enableTerminalSandbox == false and
        .statusLine.type == "command" and
        .statusLine.command == "/etc/claude-code/statusline.sh" and
        .statusLine.enabled == true and
        .statusLine.stack_with_default == true and
        .showFeedbackSurvey == false and
        .trustedWorkspaces == [$workspace]
    ' --arg workspace "$agy_workspace" "$agy_settings" >/dev/null ||
        fail "Antigravity dev container policy was not merged correctly"
    jq -e '
        .schemaVersion == 6 and
        .present == ["toolPermission","permissions"] and
        .values.toolPermission == "request-review" and
        .values.permissions == {"allow":["command(task)"],"bash":"deny"} and
        .introducedWorkspaces == [$workspace] and
        .trustedWorkspacesKeyWasPresent == false
    ' --arg workspace "$agy_workspace" "$agy_backup" >/dev/null ||
        fail "Antigravity policy rollback state was not recorded correctly"

    local agy_fresh_home agy_fresh_settings
    agy_fresh_home="${work_dir}/agy-fresh-home"
    agy_fresh_settings="${agy_fresh_home}/.gemini/antigravity-cli/settings.json"
    HOME="$agy_fresh_home" bash "$agy_apply" apply "$agy_defaults" "$agy_workspace" >/dev/null
    jq -e '
        .model == "Gemini 3.7 Flash (High)" and
        .toolPermission == "always-proceed"
    ' "$agy_fresh_settings" >/dev/null ||
        fail "fresh Antigravity settings did not seed default model Gemini 3.7 Flash (High)"

    local agy_mig_home agy_mig_settings agy_mig_backup
    agy_mig_home="${work_dir}/agy-mig-home"
    agy_mig_settings="${agy_mig_home}/.gemini/antigravity-cli/settings.json"
    agy_mig_backup="${agy_mig_home}/.gemini/antigravity-cli/settings.json.harmon-init-autonomy-backup"
    mkdir -p "${agy_mig_home}/.gemini/antigravity-cli"
    printf '%s\n' '{"schemaVersion":3,"present":["toolPermission"],"values":{"toolPermission":"request-review"},"introducedWorkspaces":["/tmp/old"],"trustedWorkspacesKeyWasPresent":false}' >"$agy_mig_backup"
    printf '%s\n' '{"statusLine":{"type":"command","command":"/custom/statusline.sh"}}' >"$agy_mig_settings"
    HOME="$agy_mig_home" bash "$agy_apply" apply "$agy_defaults" "$agy_workspace" >/dev/null
    jq -e '
        .schemaVersion == 6 and
        (.present | index("statusLine") != null) and
        .values.statusLine.command == "/custom/statusline.sh"
    ' "$agy_mig_backup" >/dev/null ||
        fail "legacy schemaVersion 3 backup was not migrated to schemaVersion 6 with custom statusLine captured"

    # Test that restore also handles legacy schemaVersion 3 rollback state and preserves user statusLine
    printf '%s\n' '{"schemaVersion":3,"present":["toolPermission"],"values":{"toolPermission":"request-review"},"introducedWorkspaces":["/tmp/old"],"trustedWorkspacesKeyWasPresent":false}' >"$agy_mig_backup"
    printf '%s\n' '{"toolPermission":"always-proceed","artifactReviewPolicy":"always-proceed","allowNonWorkspaceAccess":true,"enableTerminalSandbox":false,"statusLine":{"type":"command","command":"/custom/statusline.sh"},"trustedWorkspaces":["/tmp/old"]}' >"$agy_mig_settings"
    HOME="$agy_mig_home" bash "$agy_apply" restore >/dev/null
    jq -e '
        .toolPermission == "request-review" and
        has("artifactReviewPolicy") == false and
        has("allowNonWorkspaceAccess") == false and
        has("enableTerminalSandbox") == false and
        .statusLine.command == "/custom/statusline.sh" and
        has("trustedWorkspaces") == false
    ' "$agy_mig_settings" >/dev/null ||
        fail "Antigravity policy rollback did not handle legacy schemaVersion 3 backup on restore while preserving statusLine"

    HOME="$agy_home" bash "$agy_apply" apply "$agy_defaults" "$agy_workspace_moved" >/dev/null
    jq -e '.trustedWorkspaces == [$first, $second]' \
        --arg first "$agy_workspace" --arg second "$agy_workspace_moved" \
        "$agy_settings" >/dev/null ||
        fail "Antigravity did not trust the repository after its workspace path changed"
    jq -e '.introducedWorkspaces == [$first, $second]' \
        --arg first "$agy_workspace" --arg second "$agy_workspace_moved" \
        "$agy_backup" >/dev/null ||
        fail "Antigravity rollback state did not track every introduced workspace"

    jq '.model = "changed after opt-in"' "$agy_settings" >"${agy_settings}.new"
    mv "${agy_settings}.new" "$agy_settings"
    HOME="$agy_home" bash "$agy_apply" restore >/dev/null
    jq -e '
        .model == "changed after opt-in" and
        .toolPermission == "request-review" and
        has("artifactReviewPolicy") == false and
        has("allowNonWorkspaceAccess") == false and
        has("enableTerminalSandbox") == false and
        has("statusLine") == false and
        has("showFeedbackSurvey") == false and
        has("trustedWorkspaces") == false
    ' "$agy_settings" >/dev/null ||
        fail "Antigravity policy rollback did not restore only the managed keys"
    [ ! -e "$agy_backup" ] ||
        fail "Antigravity policy rollback state remains after a successful restore"

    local agy_before
    printf '%s\n' '{"model":"first"}' '{"model":"second"}' >"$agy_settings"
    agy_before="${work_dir}/agy-settings-before"
    cp "$agy_settings" "$agy_before"
    HOME="$agy_home" bash "$agy_apply" apply "$agy_defaults" "$agy_workspace" >/dev/null 2>&1
    cmp -s "$agy_settings" "$agy_before" ||
        fail "invalid Antigravity settings were overwritten"

    # Antigravity settings/CLI management is no longer conditionally CALLED
    # from post-create.sh based on the Copier answer — ensure-antigravity-
    # cli.sh and bot-autonomy.sh apply (which the Codex/Claude checks above
    # already require) always run; their own internal
    # HARMON_BOT_AUTONOMY_ANTIGRAVITY marker check decides what happens.
    # apply-antigravity-settings.sh itself is called directly only by
    # dev/post-create.sh (no bot-autonomy module exists for the dev profile)
    # and, internally, by the bot-autonomy antigravity module — never by bot
    # post-create.sh.
    grep 'ensure-antigravity-cli.sh' "${repo_root}/.devcontainer/post-create.sh" >/dev/null ||
        fail "bot post-create does not run ensure-antigravity-cli.sh"
    if grep 'apply-antigravity-settings.sh' "${repo_root}/.devcontainer/post-create.sh" >/dev/null; then
        fail "bot post-create calls apply-antigravity-settings.sh directly — that belongs to the bot-autonomy antigravity module now"
    fi
    grep '"HARMON_BOT_AUTONOMY_ANTIGRAVITY"' "${repo_root}/.devcontainer/devcontainer.json" >/dev/null ||
        fail "bot devcontainer.json does not set the HARMON_BOT_AUTONOMY_ANTIGRAVITY marker"
    grep '"HARMON_BOT_AUTONOMY_ANTIGRAVITY"' "${repo_root}/.devcontainer/dev/devcontainer.json" >/dev/null ||
        fail "dev devcontainer.json does not set the HARMON_BOT_AUTONOMY_ANTIGRAVITY marker"
    grep '"AGY_CLI_DISABLE_AUTO_UPDATE": *"true"' "${repo_root}/.devcontainer/devcontainer.json" >/dev/null ||
        fail "bot profile permits the compatibility Antigravity binary to auto-update"
    grep 'HARMON_BOT_AUTONOMY_ANTIGRAVITY' "${repo_root}/.devcontainer/dev/post-create.sh" >/dev/null ||
        fail "dev post-create does not branch on the HARMON_BOT_AUTONOMY_ANTIGRAVITY marker"
    grep 'apply-antigravity-settings.sh restore' "${repo_root}/.devcontainer/dev/post-create.sh" >/dev/null ||
        fail "dev post-create has no restore path for a disabled Antigravity option"
    # ── Balanced dev-profile policy (antigravity-settings-dev.json) ──
    # The human profile auto-accepts edits and an allowlist of common commands
    # but still gates unlisted ones — never the bot's blanket always-proceed.
    local agy_dev_home agy_dev_settings agy_dev_backup
    agy_dev_home="${work_dir}/agy-dev-home"
    agy_dev_settings="${agy_dev_home}/.gemini/antigravity-cli/settings.json"
    agy_dev_backup="${agy_dev_settings}.harmon-init-autonomy-backup"
    mkdir -p "$(dirname "$agy_dev_settings")"
    printf '%s\n' '{"model":"keep"}' >"$agy_dev_settings"
    HOME="$agy_dev_home" bash "$agy_apply" apply "$agy_dev_defaults" "$agy_workspace" >/dev/null
    jq -e '
        .model == "keep" and
        .toolPermission == "request-review" and
        .artifactReviewPolicy == "always-proceed" and
        (.permissions.allow | index("command(task)")) != null and
        (.permissions.deny | index("command(rm -rf /)")) != null and
        (.trustedWorkspaces | index($workspace)) != null
    ' --arg workspace "$agy_workspace" "$agy_dev_settings" >/dev/null ||
        fail "balanced Antigravity dev policy was not merged correctly"
    jq -e '.schemaVersion == 6' "$agy_dev_backup" >/dev/null ||
        fail "balanced Antigravity dev policy did not record a schemaVersion 6 rollback"

    local agy_dev_fresh_home agy_dev_fresh_settings
    agy_dev_fresh_home="${work_dir}/agy-dev-fresh-home"
    agy_dev_fresh_settings="${agy_dev_fresh_home}/.gemini/antigravity-cli/settings.json"
    HOME="$agy_dev_fresh_home" bash "$agy_apply" apply "$agy_dev_defaults" "$agy_workspace" >/dev/null
    jq -e '
        .model == "Gemini 3.7 Flash (High)" and
        .toolPermission == "request-review"
    ' "$agy_dev_fresh_settings" >/dev/null ||
        fail "fresh balanced Antigravity dev settings did not seed default model Gemini 3.7 Flash (High)"

    # ── schemaVersion 5 → 6 migration must not discard user permissions ──
    # A pre-permissions (v4) backup never owned `permissions`; migrating and
    # later restoring must leave the user's own permissions block intact.
    local agy_v4_home agy_v4_settings agy_v4_backup
    agy_v4_home="${work_dir}/agy-v4-home"
    agy_v4_settings="${agy_v4_home}/.gemini/antigravity-cli/settings.json"
    agy_v4_backup="${agy_v4_settings}.harmon-init-autonomy-backup"
    mkdir -p "$(dirname "$agy_v4_settings")"
    printf '%s\n' '{"schemaVersion":4,"present":["toolPermission"],"values":{"toolPermission":"request-review"},"introducedWorkspaces":[],"trustedWorkspacesKeyWasPresent":false}' >"$agy_v4_backup"
    printf '%s\n' '{"toolPermission":"always-proceed","permissions":{"allow":["command(mine)"]}}' >"$agy_v4_settings"
    HOME="$agy_v4_home" bash "$agy_apply" apply "$agy_dev_defaults" "$agy_workspace" >/dev/null
    jq -e '
        .schemaVersion == 6 and
        (.present | index("permissions")) != null and
        .values.permissions == {"allow":["command(mine)"]}
    ' "$agy_v4_backup" >/dev/null ||
        fail "schemaVersion 5 backup did not migrate to 6 while capturing the user permissions block"
    HOME="$agy_v4_home" bash "$agy_apply" restore >/dev/null
    jq -e '.permissions == {"allow":["command(mine)"]} and .toolPermission == "request-review"' \
        "$agy_v4_settings" >/dev/null ||
        fail "restore did not return the user permissions block after a 5 -> 6 migration"

    # The human dev profile may apply its own BALANCED policy
    # (antigravity-settings-dev.json); it must never apply the bot's blanket
    # always-proceed policy (antigravity-settings.json). Strip comment lines
    # first so an explanatory comment naming the bot file is not a false match;
    # the regex then matches the bot defaults filename but not the "-dev.json".
    if grep -E 'antigravity-settings\.json' < <(grep -Ev '^[[:space:]]*#' "${repo_root}/.devcontainer/dev/post-create.sh") >/dev/null; then
        fail "human dev profile applies the bot-only always-proceed Antigravity policy"
    fi

    # The `gh pr merge` ask drop-in (claude-settings-dev.json) is dev-only: the
    # bot and agent profiles carry no merge guard, and the "Protect Main"
    # ruleset is the boundary there. Comment lines are stripped so an
    # explanatory comment naming the file is not a false match.
    grep -Fq 'claude-settings-dev.json' < <(grep -Ev '^[[:space:]]*#' "${repo_root}/.devcontainer/dev/post-create.sh") ||
        fail "human dev profile does not install the gh pr merge ask drop-in (claude-settings-dev.json)"
    local merge_profile_script
    for merge_profile_script in .devcontainer/post-create.sh .devcontainer/agent/post-create.sh; do
        if grep -Eq 'claude-settings-dev\.json|managed-settings\.d' < <(grep -Ev '^[[:space:]]*#' "${repo_root}/${merge_profile_script}"); then
            fail "${merge_profile_script} installs the dev-only gh pr merge ask drop-in"
        fi
    done

    # 9. The GitHub CLI browser bridge must use the VS Code host opener when it
    #    works, and print the exact URL when that command is absent or fails.
    #    Remote VS Code's `code --open-url` is a false friend: it can ignore the
    #    option and exit 0, so prefer its bundled browser helper and capability-
    #    check any desktop CLI fallback.
    #    Generic discovery is intentionally forbidden: terminal browsers are
    #    installed in the image and would trap the OAuth flow in-container.
    local browser_bin browser_helpers browser_log browser_sentinel browser_out browser_url
    browser_bin="${work_dir}/browser-bin"
    browser_helpers="${work_dir}/helpers"
    browser_log="${work_dir}/browser-args"
    browser_sentinel="${work_dir}/terminal-browser-ran"
    browser_url='https://github.com/login/device?user_code=ABCD-EFGH&source=gh'
    mkdir -p "$browser_bin" "$browser_helpers"
    ln -s "$bash_bin" "${browser_bin}/bash"
    for browser_dependency in dirname grep readlink; do
        ln -s "$(command -v "$browser_dependency")" "${browser_bin}/${browser_dependency}"
    done
    printf '%s\n' '#!/bin/sh' \
        'if [ "${1:-}" = "--help" ]; then' \
        '    [ "${GH_BROWSER_TEST_OPEN_URL_SUPPORT:-0}" = "1" ] && echo "  --open-url"' \
        '    exit 0' \
        'fi' \
        'printf "%s\\n" "$@" >"$GH_BROWSER_TEST_LOG"' \
        'exit "${GH_BROWSER_TEST_CODE_RC:-0}"' >"${browser_bin}/code"
    chmod 0755 "${browser_bin}/code"
    printf '%s\n' '#!/bin/sh' \
        'printf "%s\\n" "$@" >"$GH_BROWSER_TEST_LOG"' \
        'if [ "${GH_BROWSER_TEST_HELPER_ERROR:-0}" = "1" ]; then' \
        '    echo "host handoff diagnostic with unstable wording" >&2' \
        'fi' \
        'exit "${GH_BROWSER_TEST_HELPER_RC:-0}"' >"${browser_helpers}/browser.sh"
    chmod 0755 "${browser_helpers}/browser.sh"
    for terminal_browser in w3m lynx sensible-browser xdg-open; do
        printf '%s\n' '#!/bin/sh' \
            'printf "%s\\n" "$0" >"$GH_BROWSER_TEST_SENTINEL"' \
            'exit 99' >"${browser_bin}/${terminal_browser}"
        chmod 0755 "${browser_bin}/${terminal_browser}"
    done

    GH_BROWSER_TEST_LOG="$browser_log" \
        GH_BROWSER_TEST_SENTINEL="$browser_sentinel" \
        PATH="$browser_bin" "$gh_browser" "$browser_url"
    [ "$(cat "$browser_log")" = "$browser_url" ] ||
        fail "GitHub browser bridge did not pass the exact URL to the remote helper"
    [ ! -e "$browser_sentinel" ] ||
        fail "GitHub browser bridge invoked a terminal browser after the remote helper succeeded"

    browser_out="$(GH_BROWSER_TEST_HELPER_ERROR=1 GH_BROWSER_TEST_LOG="$browser_log" \
        GH_BROWSER_TEST_SENTINEL="$browser_sentinel" \
        PATH="$browser_bin" "$gh_browser" "$browser_url" 2>&1)"
    case "$browser_out" in
    *"$browser_url"*) ;;
    *) fail "GitHub browser bridge trusted unexpected output from the remote helper: ${browser_out}" ;;
    esac

    browser_out="$(GH_BROWSER_TEST_HELPER_RC=1 GH_BROWSER_TEST_LOG="$browser_log" \
        GH_BROWSER_TEST_SENTINEL="$browser_sentinel" \
        PATH="$browser_bin" "$gh_browser" "$browser_url" 2>&1)"
    case "$browser_out" in
    *"$browser_url"*) ;;
    *) fail "GitHub browser bridge did not print the URL after the remote helper failed: ${browser_out}" ;;
    esac
    [ ! -e "$browser_sentinel" ] ||
        fail "GitHub browser bridge invoked a terminal browser after the remote helper failed"

    rm "${browser_helpers}/browser.sh"
    GH_BROWSER_TEST_OPEN_URL_SUPPORT=1 GH_BROWSER_TEST_LOG="$browser_log" \
        GH_BROWSER_TEST_SENTINEL="$browser_sentinel" \
        PATH="$browser_bin" "$gh_browser" "$browser_url"
    [ "$(sed -n '1p' "$browser_log")" = "--open-url" ] &&
        [ "$(sed -n '2p' "$browser_log")" = "$browser_url" ] &&
        [ "$(wc -l <"$browser_log" | tr -d ' ')" = "2" ] ||
        fail "GitHub browser bridge did not pass the exact URL to a supported code --open-url"

    browser_out="$(GH_BROWSER_TEST_OPEN_URL_SUPPORT=0 GH_BROWSER_TEST_LOG="$browser_log" \
        GH_BROWSER_TEST_SENTINEL="$browser_sentinel" \
        PATH="$browser_bin" "$gh_browser" "$browser_url" 2>&1)"
    case "$browser_out" in
    *"$browser_url"*) ;;
    *) fail "GitHub browser bridge trusted an unsupported code --open-url: ${browser_out}" ;;
    esac

    rm "${browser_bin}/code"
    browser_out="$(GH_BROWSER_TEST_LOG="$browser_log" \
        GH_BROWSER_TEST_SENTINEL="$browser_sentinel" \
        PATH="$browser_bin" "$gh_browser" "$browser_url" 2>&1)"
    case "$browser_out" in
    *"$browser_url"*) ;;
    *) fail "GitHub browser bridge did not print the URL when code was absent: ${browser_out}" ;;
    esac
    [ ! -e "$browser_sentinel" ] ||
        fail "GitHub browser bridge invoked a terminal browser when code was absent"

    # 10. The shared post-create guidance must never steer a BOT container to an
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

    # The banner asks scripts/gh-scopes.sh for the scope list (the single
    # source shared with status.sh and setup:gh-scopes), and the extraction
    # above takes the function body ALONE. Without the library, the call
    # resolves to nothing, the banner renders `--scopes ""`, and a check that
    # only looked for a login command would pass on a broken banner.
    local scopes_lib="${repo_root}/scripts/gh-scopes.sh"
    [ -f "$scopes_lib" ] || fail "scripts/gh-scopes.sh not found at ${scopes_lib}"

    # Match a pasteable COMMAND line — `gh` as the first token — not the bare
    # phrase. The token message names `gh auth login` on purpose, in a "do NOT
    # run this here" warning; a substring test would read that warning as the
    # very thing it warns against, and the check would be worse than useless.
    offers_login() {
        grep -E '^[[:space:]]*gh[[:space:]]+auth[[:space:]]+login' <<<"$1" >/dev/null
    }

    help_out="$(unset DEVCONTAINER_GH_AUTH && "$bash_bin" -c '. "$2"; . "$1"; gh_auth_help "gh auth setup-git"' _ "$helper_src" "$scopes_lib")"
    if offers_login "$help_out"; then
        fail "post-create gh guidance offers an operator login by default — a bot container must never be told to run one"
    fi

    help_out="$(DEVCONTAINER_GH_AUTH=login "$bash_bin" -c '. "$2"; . "$1"; gh_auth_help "gh auth setup-git"' _ "$helper_src" "$scopes_lib")"
    if ! offers_login "$help_out"; then
        fail "post-create gh guidance omits the operator login where the profile declares one"
    fi

    # The login it offers must carry the DERIVED scopes, not an empty or
    # hardcoded list — that agreement between the banner and the scope check is
    # the acceptance criterion the single source exists to satisfy (#827).
    case "$help_out" in
    *'--scopes ""'*) fail "post-create login line renders an empty scope list — gh-scopes.sh was not in scope" ;;
    esac
    for required_scope in repo workflow; do
        case "$help_out" in
        *"${required_scope}"*) ;;
        *) fail "post-create login line omits the '${required_scope}' scope: ${help_out}" ;;
        esac
    done

    # 10b. The bot profile's gh-identity tripwire (harmon-init#1236). The git-identity
    #    assertions prove who a container COMMITS as; nothing proved who `gh`
    #    WRITES as. A bot container whose gh holds a human credential
    #    attributes every issue, PR, and comment to that human — and parks a
    #    personal credential inside a bypassPermissions container. The helper
    #    decides from `gh auth status` output ALONE (the stored-credential
    #    shapes name their account even when validation fails), so these cases
    #    run against a stub gh with no network. The contract under test:
    #    unauthenticated passes-with-remedy (a fresh container before token
    #    provisioning is healthy), any credential naming a non-bot account is
    #    a violation, and an unverifiable token is indeterminate — never a
    #    failure.
    local gh_check gh_id_bin gh_id_fixture gh_id_out gh_id_rc
    gh_check="${repo_root}/.devcontainer/scripts/check-bot-gh-identity.sh"
    [ -f "$gh_check" ] || fail "check-bot-gh-identity.sh not found at ${gh_check}"

    gh_id_bin="${work_dir}/gh-identity-bin"
    gh_id_fixture="${work_dir}/gh-identity-fixture"
    mkdir -p "$gh_id_bin" "${work_dir}/empty-bin"
    ln -s "$bash_bin" "${gh_id_bin}/bash"
    # sed is on this list because the helper strips ANSI with it — the
    # constrained PATH exists to isolate `gh`, not to prove the script runs
    # without POSIX tools.
    for gh_id_dep in cat grep awk sort sleep sed; do
        ln -s "$(command -v "$gh_id_dep")" "${gh_id_bin}/${gh_id_dep}"
    done
    # timeout: Homebrew coreutils on macOS ships it as gtimeout (the same
    # split scripts/status.sh handles), so resolve whichever exists and link
    # it under the name the helper probes — the wedged-gh case below depends
    # on the bound existing, and `ln -s ""` under set -e would otherwise
    # abort the whole unit run before any identity case.
    local gh_id_timeout
    gh_id_timeout="$(command -v timeout || command -v gtimeout)" ||
        fail "neither timeout nor gtimeout is available for the gh-identity unit cases"
    ln -s "$gh_id_timeout" "${gh_id_bin}/timeout"

    gh_identity_run() {
        # $1 = stub gh exit code; the fixture file holds the stub's output.
        # The token aliases are cleared explicitly: unit mode also runs
        # inside the bot container, whose real GH_TOKEN would otherwise
        # leak into every case's environment.
        # The posture is pinned to bot for the same reason: the helper's
        # wording is posture-aware, and unit mode also runs inside the agent
        # container, whose FOREMAN_DEVCONTAINER=agent would otherwise switch
        # every bot-wording assertion below to the agent's.
        gh_id_rc=0
        gh_id_out="$(GH_IDENTITY_TEST_FIXTURE="$gh_id_fixture" \
            GH_IDENTITY_TEST_RC="$1" FOREMAN_DEVCONTAINER=bot \
            GH_TOKEN= GITHUB_TOKEN= GH_ENTERPRISE_TOKEN= GITHUB_ENTERPRISE_TOKEN= \
            PATH="$gh_id_bin" "$bash_bin" "$gh_check" 2>&1)" || gh_id_rc=$?
    }

    # $1 = posture (FOREMAN_DEVCONTAINER), $2 = stub gh exit code, $3 =
    # GH_TOKEN value (empty for none). The posture-wording cases below.
    gh_identity_posture_run() {
        gh_id_rc=0
        gh_id_out="$(GH_IDENTITY_TEST_FIXTURE="$gh_id_fixture" \
            GH_IDENTITY_TEST_RC="$2" FOREMAN_DEVCONTAINER="$1" \
            GH_TOKEN="$3" GITHUB_TOKEN= GH_ENTERPRISE_TOKEN= GITHUB_ENTERPRISE_TOKEN= \
            PATH="$gh_id_bin" "$bash_bin" "$gh_check" 2>&1)" || gh_id_rc=$?
    }

    # $1 = case label; the rest are substrings the output must NOT contain.
    gh_identity_refute() {
        local refute_label="$1" refute_text
        shift
        for refute_text in "$@"; do
            case "$gh_id_out" in
            *"$refute_text"*) fail "${refute_label} prints '${refute_text}': ${gh_id_out}" ;;
            esac
        done
    }

    # $1 = case label; the rest are substrings the output MUST contain.
    gh_identity_expect() {
        local expect_label="$1" expect_text
        shift
        for expect_text in "$@"; do
            case "$gh_id_out" in
            *"$expect_text"*) ;;
            *) fail "${expect_label} does not print '${expect_text}': ${gh_id_out}" ;;
            esac
        done
    }

    # gh ABSENT from PATH: indeterminate (3), never a violation — the image
    # toolchain checks own "gh is installed"; this check owns identity only.
    # Runs before the stub gh below is created, so the constrained PATH
    # genuinely has no gh.
    gh_id_rc=0
    PATH="$gh_id_bin" "$bash_bin" "$gh_check" >/dev/null 2>&1 || gh_id_rc=$?
    [ "$gh_id_rc" = "3" ] ||
        fail "gh-identity check exited ${gh_id_rc} with no gh on PATH — expected indeterminate (3)"

    printf '%s\n' '#!/bin/sh' 'cat "$GH_IDENTITY_TEST_FIXTURE"' \
        'exit "${GH_IDENTITY_TEST_RC:-0}"' >"${gh_id_bin}/gh"
    chmod 0755 "${gh_id_bin}/gh"

    # Fresh container, token never provisioned: PASS-WITH-REMEDY (2). The
    # remedy must name GH_TOKEN and the env-file, and must never be an
    # operator login — gh's own output suggests exactly that, which is how
    # the live violation happened.
    printf '%s\n' \
        'You are not logged into any GitHub hosts. To log in, run: gh auth login' \
        >"$gh_id_fixture"
    gh_identity_run 1
    [ "$gh_id_rc" = "2" ] ||
        fail "unauthenticated gh exited ${gh_id_rc}, expected pass-with-remedy (2)"
    case "$gh_id_out" in
    *GH_TOKEN*) ;;
    *) fail "unauthenticated gh-identity warning does not name GH_TOKEN: ${gh_id_out}" ;;
    esac
    case "$gh_id_out" in
    *.devcontainer/devcontainer.env*) ;;
    *) fail "unauthenticated gh-identity warning does not name .devcontainer/devcontainer.env: ${gh_id_out}" ;;
    esac
    # The remedy must describe the PROVISIONING chain (harmon-init#1236 scope correction):
    # on Coder the PAT arrives from the workspace's template parameter, and
    # generically from the host env init-env.sh projects — never a
    # hand-authored secret file, and never an interactive login.
    case "$gh_id_out" in
    *"template parameter"*) ;;
    *) fail "unauthenticated gh-identity warning does not name the Coder template parameter: ${gh_id_out}" ;;
    esac
    if offers_login "$gh_id_out"; then
        fail "gh-identity warning offers an operator login in a bot container"
    fi

    # Authenticated as the bot: OK. The RELATIONSHIP (a '-bot' suffix, same
    # style as the git-identity assertions) — never a literal account name.
    printf '%s\n' \
        'github.com' \
        '  ✓ Logged in to github.com account someowner-bot (GH_TOKEN)' \
        >"$gh_id_fixture"
    gh_identity_run 0
    [ "$gh_id_rc" = "0" ] ||
        fail "bot-suffixed gh login exited ${gh_id_rc}, expected pass (0)"

    # The observed violation (harmon-init#1236): an operator login in the bot container.
    printf '%s\n' \
        'github.com' \
        '  ✓ Logged in to github.com account someoperator (keyring)' \
        '  - Active account: true' \
        >"$gh_id_fixture"
    gh_identity_run 0
    [ "$gh_id_rc" = "1" ] ||
        fail "non-bot gh login exited ${gh_id_rc}, expected violation (1)"
    case "$gh_id_out" in
    *someoperator*) ;;
    *) fail "gh-identity violation warning does not name the offending login: ${gh_id_out}" ;;
    esac
    case "$gh_id_out" in
    *GH_TOKEN*) ;;
    *) fail "gh-identity violation warning does not name the GH_TOKEN remedy: ${gh_id_out}" ;;
    esac
    if offers_login "$gh_id_out"; then
        fail "gh-identity violation warning offers an operator login in a bot container"
    fi

    # Enterprise Managed Users. GitHub appends `_<enterprise-shortcode>` to
    # the IdP username, so the bot account provisioned as `someowner-bot` IS
    # `someowner-bot_acme` there — the canonical generated shape, and it must
    # PASS. An earlier round tested the raw login and rejected exactly this
    # account; the relationship belongs on the IdP component.
    printf '%s\n' \
        'github.com' \
        '  ✓ Logged in to github.com account someowner-bot_acme (GH_TOKEN)' \
        >"$gh_id_fixture"
    gh_identity_run 0
    [ "$gh_id_rc" = "0" ] ||
        fail "canonical EMU bot login 'someowner-bot_acme' exited ${gh_id_rc}, expected pass (0)"

    # ...and an EMU login whose IdP component is NOT a bot is still a
    # violation, named in full so the operator can find the real account.
    printf '%s\n' \
        'github.com' \
        '  ✓ Logged in to github.com account someoperator_acme (keyring)' \
        >"$gh_id_fixture"
    gh_identity_run 0
    [ "$gh_id_rc" = "1" ] ||
        fail "EMU non-bot login 'someoperator_acme' exited ${gh_id_rc}, expected violation (1)"
    case "$gh_id_out" in
    *someoperator_acme*) ;;
    *) fail "EMU violation warning does not name the FULL login: ${gh_id_out}" ;;
    esac

    # The ORDINARY naming pair this repo uses — `alice` beside `alice-bot` —
    # is the case a substring source-lookup gets wrong: `alice` also matches
    # the bot's (GH_TOKEN) record, which would classify the human credential
    # as environment-sourced, drop the `gh auth logout` it needs, and send the
    # operator to repair an already-correct bot token. The stored human
    # credential must still get the logout instruction.
    printf '%s\n' \
        'github.com' \
        '  ✓ Logged in to github.com account alice-bot (GH_TOKEN)' \
        '  ✓ Logged in to github.com account alice (keyring)' \
        >"$gh_id_fixture"
    gh_identity_run 0
    [ "$gh_id_rc" = "1" ] ||
        fail "human 'alice' beside bot 'alice-bot' exited ${gh_id_rc}, expected violation (1)"
    case "$gh_id_out" in
    *"gh auth logout --hostname"*) ;;
    *) fail "the stored human credential 'alice' lost its logout instruction to a substring match on 'alice-bot': ${gh_id_out}" ;;
    esac

    # Every INDETERMINATE report carries the remedy, never a bare verdict: the
    # acceptance criteria ask for indeterminate *with* the remedy, and a
    # reader told only "unverified" has nothing to act on. Timeout path:
    printf '%s\n' \
        'github.com' \
        '  ✓ Logged in to github.com account someowner-bot (GH_TOKEN)' \
        >"$gh_id_fixture"
    gh_identity_run 124
    [ "$gh_id_rc" = "3" ] ||
        fail "timed-out enumeration exited ${gh_id_rc}, expected indeterminate (3)"
    case "$gh_id_out" in
    *GH_TOKEN*) ;;
    *) fail "the timeout indeterminate report carries no provisioning remedy: ${gh_id_out}" ;;
    esac

    # ...and the unparseable-output path:
    printf '%s\n' 'something gh has never printed before' >"$gh_id_fixture"
    gh_identity_run 0
    [ "$gh_id_rc" = "3" ] ||
        fail "unparseable gh output exited ${gh_id_rc}, expected indeterminate (3)"
    case "$gh_id_out" in
    *GH_TOKEN*) ;;
    *) fail "the unparseable indeterminate report carries no provisioning remedy: ${gh_id_out}" ;;
    esac

    # The same login on two hosts with DIFFERENT credential sources —
    # `alice (GH_TOKEN)` on github.com beside `alice (keyring)` on a GHES
    # host — is one entry after `sort -u`, so an if/else source lookup records
    # only one of them and the remedy drops the `gh auth logout` the stored
    # credential needs. Both remedies must appear. Found by the integration
    # stage's cloud review.
    printf '%s\n' \
        'github.com' \
        '  ✓ Logged in to github.com account alice (GH_TOKEN)' \
        '' \
        'ghe.example.com' \
        '  ✓ Logged in to ghe.example.com account alice (keyring)' \
        >"$gh_id_fixture"
    gh_identity_run 0
    [ "$gh_id_rc" = "1" ] ||
        fail "duplicate non-bot login across hosts exited ${gh_id_rc}, expected violation (1)"
    case "$gh_id_out" in
    *"gh auth logout --hostname"*) ;;
    *) fail "a login with BOTH env and stored records lost the stored credential's logout remedy: ${gh_id_out}" ;;
    esac
    case "$gh_id_out" in
    *"cannot remove it"*) ;;
    *) fail "a login with BOTH env and stored records lost the environment remedy: ${gh_id_out}" ;;
    esac

    # An unconfigured GH_HOST reports its own `(default)` failure ALONGSIDE
    # another host's healthy bot record. Accepting the parsed login first
    # declared a clean identity while the host gh would actually write to was
    # unauthenticated. The `(default)` branch must be reached first.
    printf '%s\n' \
        'ghe.example.com' \
        '  X Failed to log in to ghe.example.com using token (default)' \
        '' \
        'github.com' \
        '  ✓ Logged in to github.com account someowner-bot (keyring)' \
        >"$gh_id_fixture"
    gh_identity_run 1
    [ "$gh_id_rc" = "2" ] ||
        fail "an unauthenticated GH_HOST target beside a stored bot login exited ${gh_id_rc}, expected unauthenticated (2)"
    case "$gh_id_out" in
    *GH_TOKEN*) ;;
    *) fail "the unauthenticated-target banner names no provisioning remedy: ${gh_id_out}" ;;
    esac

    # The violation remedy must match the credential SOURCE. `gh auth logout`
    # removes a stored record and can do nothing about a token from the
    # environment — and a misprovisioned GH_TOKEN carrying the wrong account
    # is a primary failure mode, so a remedy that cannot work there is worse
    # than none. Found by the review stage.
    printf '%s\n' \
        'github.com' \
        '  ✓ Logged in to github.com account someoperator (GH_TOKEN)' \
        >"$gh_id_fixture"
    gh_identity_run 0
    [ "$gh_id_rc" = "1" ] ||
        fail "env-sourced non-bot login exited ${gh_id_rc}, expected violation (1)"
    case "$gh_id_out" in
    *"cannot remove it"*) ;;
    *) fail "env-sourced violation remedy does not say gh auth logout cannot remove it: ${gh_id_out}" ;;
    esac
    case "$gh_id_out" in
    *"gh auth logout --hostname"*)
        fail "env-sourced violation remedy prescribes gh auth logout, which cannot remove an environment token"
        ;;
    esac

    # ...while a STORED non-bot record still gets the logout instruction.
    printf '%s\n' \
        'github.com' \
        '  ✓ Logged in to github.com account someoperator (keyring)' \
        >"$gh_id_fixture"
    gh_identity_run 0
    [ "$gh_id_rc" = "1" ] ||
        fail "stored non-bot login exited ${gh_id_rc}, expected violation (1)"
    case "$gh_id_out" in
    *"gh auth logout --hostname"*) ;;
    *) fail "stored violation remedy omits the gh auth logout instruction: ${gh_id_out}" ;;
    esac

    # Forced colour must not defeat the parse. A container inheriting
    # CLICOLOR_FORCE=1 makes gh wrap the login in ANSI, and the parse requires
    # an alphanumeric immediately after "account"/"as" — so the login was
    # omitted and a stored NON-BOT credential degraded from a violation (1) to
    # "could not parse" (3), which the CONTAINER ASSERT ACCEPTS. That is a
    # security bypass reachable from an environment variable. Found by the
    # integration stage's cloud review; reproduced before fixing.
    printf '%s\n' \
        'github.com' \
        "  $(printf '\033')[0;32m✓$(printf '\033')[0m Logged in to github.com account $(printf '\033')[1msomeoperator$(printf '\033')[0m (keyring)" \
        >"$gh_id_fixture"
    gh_identity_run 0
    [ "$gh_id_rc" = "1" ] ||
        fail "an ANSI-coloured non-bot login exited ${gh_id_rc}, expected violation (1) — colour defeated the parse and the assert accepts 3"
    case "$gh_id_out" in
    *someoperator*) ;;
    *) fail "the ANSI-coloured violation warning does not name the login: ${gh_id_out}" ;;
    esac

    # gh absent is indeterminate, and an indeterminate report owes a remedy
    # like every other one — AC3 carves out no exception for it.
    gh_id_rc=0
    gh_id_out="$(PATH="${work_dir}/empty-bin" "$bash_bin" "$gh_check" 2>&1)" || gh_id_rc=$?
    [ "$gh_id_rc" = "3" ] ||
        fail "gh absent exited ${gh_id_rc}, expected indeterminate (3)"
    case "$gh_id_out" in
    *Remedy*) ;;
    *) fail "the gh-absent indeterminate report carries no remedy: ${gh_id_out}" ;;
    esac

    # A stored login names its account even when validation fails (offline
    # or revoked): the CREDENTIAL is the violation, not the token's
    # freshness, so this must not degrade to indeterminate.
    printf '%s\n' \
        'github.com' \
        '  X Failed to log in to github.com account someoperator (/home/vscode/.config/gh/hosts.yml)' \
        '  - Active account: true' \
        '  - The token in /home/vscode/.config/gh/hosts.yml is invalid.' \
        '  - To re-authenticate, run: gh auth refresh -h github.com' \
        '  - To forget about this account, run: gh auth logout -h github.com -u someoperator' \
        >"$gh_id_fixture"
    gh_identity_run 1
    [ "$gh_id_rc" = "1" ] ||
        fail "stale non-bot gh credential exited ${gh_id_rc}, expected violation (1)"
    if offers_login "$gh_id_out"; then
        fail "stale-credential gh-identity warning offers an operator login in a bot container"
    fi

    # GH_TOKEN present but unverifiable (offline, rate-limited, expired):
    # gh names no account, so identity is INDETERMINATE (3) — a network
    # hiccup must not fail the assert or block a fresh container.
    printf '%s\n' \
        'github.com' \
        '  X Failed to log in to github.com using token (GH_TOKEN)' \
        '  - Active account: true' \
        '  - The token in GH_TOKEN is invalid.' \
        >"$gh_id_fixture"
    gh_identity_run 1
    [ "$gh_id_rc" = "3" ] ||
        fail "unverifiable GH_TOKEN exited ${gh_id_rc}, expected indeterminate (3)"

    # A human credential parked BESIDE a valid bot token is still a
    # violation: gh can switch accounts, and the personal credential is
    # inside the container either way.
    printf '%s\n' \
        'github.com' \
        '  ✓ Logged in to github.com account someowner-bot (GH_TOKEN)' \
        '  ✓ Logged in to github.com account someoperator (keyring)' \
        >"$gh_id_fixture"
    gh_identity_run 0
    [ "$gh_id_rc" = "1" ] ||
        fail "non-bot credential beside the bot token exited ${gh_id_rc}, expected violation (1)"

    # An UNNAMED failed-token entry beside a named stored bot login: gh
    # prefers an environment token for writes, so while one is unverified
    # the ACTIVE identity is unknown no matter which stored logins are also
    # present — indeterminate (3), never a clean 0 off the stored account.
    printf '%s\n' \
        'github.com' \
        '  X Failed to log in to github.com using token (GH_TOKEN)' \
        '  - Active account: true' \
        '' \
        '  ✓ Logged in to github.com account someowner-bot (keyring)' \
        '  - Active account: false' \
        >"$gh_id_fixture"
    gh_identity_run 1
    [ "$gh_id_rc" = "3" ] ||
        fail "unverifiable token beside a stored bot login exited ${gh_id_rc}, expected indeterminate (3)"

    # ...but a KNOWN non-bot credential still outranks that indeterminacy:
    # the stored human login is a violation regardless of what the unnamed
    # token would have resolved to.
    printf '%s\n' \
        'github.com' \
        '  X Failed to log in to github.com using token (GH_TOKEN)' \
        '  - Active account: true' \
        '' \
        '  ✓ Logged in to github.com account someoperator (keyring)' \
        '  - Active account: false' \
        >"$gh_id_fixture"
    gh_identity_run 1
    [ "$gh_id_rc" = "1" ] ||
        fail "non-bot stored login beside an unverifiable token exited ${gh_id_rc}, expected violation (1)"

    # A SHADOWED environment-token alias is credential material gh cannot
    # enumerate: with both GH_TOKEN and GITHUB_TOKEN set, gh auth status
    # reports only GH_TOKEN (verified live), so a valid bot token in front
    # of a different personal token must not read as "every credential is
    # a bot". Indeterminate — and the warning names the alias, never the
    # value.
    printf '%s\n' \
        'github.com' \
        '  ✓ Logged in to github.com account someowner-bot (GH_TOKEN)' \
        >"$gh_id_fixture"
    gh_id_rc=0
    gh_id_out="$(GH_IDENTITY_TEST_FIXTURE="$gh_id_fixture" GH_IDENTITY_TEST_RC=0 \
        GH_TOKEN=sentinel-primary GITHUB_TOKEN=sentinel-shadowed \
        GH_ENTERPRISE_TOKEN= GITHUB_ENTERPRISE_TOKEN= \
        PATH="$gh_id_bin" "$bash_bin" "$gh_check" 2>&1)" || gh_id_rc=$?
    [ "$gh_id_rc" = "3" ] ||
        fail "a shadowed GITHUB_TOKEN behind a bot GH_TOKEN exited ${gh_id_rc}, expected indeterminate (3)"
    case "$gh_id_out" in
    *GITHUB_TOKEN*) ;;
    *) fail "shadowed-alias warning does not name the shadowed variable: ${gh_id_out}" ;;
    esac
    case "$gh_id_out" in
    *sentinel-shadowed* | *sentinel-primary*)
        fail "shadowed-alias warning printed a token VALUE"
        ;;
    esac

    # The same value spelled through two aliases is one credential twice,
    # not a shadow: stays clean.
    gh_id_rc=0
    GH_IDENTITY_TEST_FIXTURE="$gh_id_fixture" GH_IDENTITY_TEST_RC=0 \
        GH_TOKEN=sentinel-primary GITHUB_TOKEN=sentinel-primary \
        GH_ENTERPRISE_TOKEN= GITHUB_ENTERPRISE_TOKEN= \
        PATH="$gh_id_bin" "$bash_bin" "$gh_check" >/dev/null 2>&1 || gh_id_rc=$?
    [ "$gh_id_rc" = "0" ] ||
        fail "duplicate same-value aliases exited ${gh_id_rc}, expected pass (0)"

    # A known non-bot login still outranks the shadow's indeterminacy.
    printf '%s\n' \
        'github.com' \
        '  ✓ Logged in to github.com account someoperator (keyring)' \
        >"$gh_id_fixture"
    gh_id_rc=0
    GH_IDENTITY_TEST_FIXTURE="$gh_id_fixture" GH_IDENTITY_TEST_RC=0 \
        GH_TOKEN=sentinel-primary GITHUB_TOKEN=sentinel-shadowed \
        GH_ENTERPRISE_TOKEN= GITHUB_ENTERPRISE_TOKEN= \
        PATH="$gh_id_bin" "$bash_bin" "$gh_check" >/dev/null 2>&1 || gh_id_rc=$?
    [ "$gh_id_rc" = "1" ] ||
        fail "non-bot login beside shadowed aliases exited ${gh_id_rc}, expected violation (1)"

    # An environment token gh attributes to NO host (an enterprise alias
    # with no configured GHES host) must not read as clean-unauthenticated:
    # the credential is present, just invisible to the enumeration.
    printf '%s\n' \
        'You are not logged into any GitHub hosts. To log in, run: gh auth login' \
        >"$gh_id_fixture"
    gh_id_rc=0
    GH_IDENTITY_TEST_FIXTURE="$gh_id_fixture" GH_IDENTITY_TEST_RC=1 \
        GH_TOKEN= GITHUB_TOKEN= GH_ENTERPRISE_TOKEN=sentinel-ghes GITHUB_ENTERPRISE_TOKEN= \
        PATH="$gh_id_bin" "$bash_bin" "$gh_check" >/dev/null 2>&1 || gh_id_rc=$?
    [ "$gh_id_rc" = "3" ] ||
        fail "an unattributed enterprise token with no logins exited ${gh_id_rc}, expected indeterminate (3)"

    # gh's own BUILT-IN timeout is a fourth status shape: it exits with the
    # ordinary failure code (not 124/137) and writes "Timeout ... log in to
    # <host> using token" / "... account <login>". A timed-out active token
    # beside a stored bot login must stay unverified, not clean.
    printf '%s\n' \
        'github.com' \
        '  X Timeout trying to log in to github.com using token (GH_TOKEN)' \
        '  - Active account: true' \
        '' \
        '  ✓ Logged in to github.com account someowner-bot (keyring)' \
        >"$gh_id_fixture"
    gh_identity_run 1
    [ "$gh_id_rc" = "3" ] ||
        fail "a gh-internal token timeout beside a stored bot login exited ${gh_id_rc}, expected indeterminate (3)"

    # ...and a timeout record that NAMES a non-bot account is still a
    # credential claiming a human identity: violation, whatever wording
    # variant gh used.
    printf '%s\n' \
        'github.com' \
        '  X Timeout error trying to log in to github.com account someoperator (keyring)' \
        >"$gh_id_fixture"
    gh_identity_run 1
    [ "$gh_id_rc" = "1" ] ||
        fail "a gh-internal timeout naming a non-bot account exited ${gh_id_rc}, expected violation (1)"

    # The two alias pairs are INDEPENDENT precedence groups (gh help
    # environment): a bot GH_TOKEN beside a different GH_ENTERPRISE_TOKEN,
    # both enumerated as bot accounts on their own hosts, is a legitimate
    # setup — never a shadow.
    printf '%s\n' \
        'github.com' \
        '  ✓ Logged in to github.com account someowner-bot (GH_TOKEN)' \
        '' \
        'ghe.example.com' \
        '  ✓ Logged in to ghe.example.com account someowner-bot (GH_ENTERPRISE_TOKEN)' \
        >"$gh_id_fixture"
    gh_id_rc=0
    GH_IDENTITY_TEST_FIXTURE="$gh_id_fixture" GH_IDENTITY_TEST_RC=0 \
        GH_TOKEN=sentinel-primary GITHUB_TOKEN= \
        GH_ENTERPRISE_TOKEN=sentinel-ghes GITHUB_ENTERPRISE_TOKEN= \
        PATH="$gh_id_bin" "$bash_bin" "$gh_check" >/dev/null 2>&1 || gh_id_rc=$?
    [ "$gh_id_rc" = "0" ] ||
        fail "cross-pair bot tokens on their own hosts exited ${gh_id_rc}, expected pass (0)"

    # A *.ghe.com tenant host is served by GH_TOKEN (gh help environment),
    # so its presence is NOT evidence the enterprise token was enumerated:
    # only a record explicitly sourced from the enterprise alias is.
    printf '%s\n' \
        'github.com' \
        '  ✓ Logged in to github.com account someowner-bot (GH_TOKEN)' \
        '' \
        'tenant.ghe.com' \
        '  ✓ Logged in to tenant.ghe.com account someowner-bot (GH_TOKEN)' \
        >"$gh_id_fixture"
    gh_id_rc=0
    gh_id_out="$(GH_IDENTITY_TEST_FIXTURE="$gh_id_fixture" GH_IDENTITY_TEST_RC=0 \
        GH_TOKEN=sentinel-primary GITHUB_TOKEN= \
        GH_ENTERPRISE_TOKEN=sentinel-ghes GITHUB_ENTERPRISE_TOKEN= \
        PATH="$gh_id_bin" "$bash_bin" "$gh_check" 2>&1)" || gh_id_rc=$?
    [ "$gh_id_rc" = "3" ] ||
        fail "an enterprise token with only GH_TOKEN-sourced ghe.com records exited ${gh_id_rc}, expected indeterminate (3)"
    case "$gh_id_out" in
    *"never enumerated"*) ;;
    *) fail "the ghe.com-tenant note does not say the enterprise token was never enumerated: ${gh_id_out}" ;;
    esac

    # gh's "(default)" pseudo-source — GH_HOST selecting a host with
    # neither a stored login nor a token — is the ordinary unauthenticated
    # state, not an unverified token: the banner-and-remedy exit, never a
    # false token-present indeterminate.
    printf '%s\n' \
        'github.com' \
        '  X Failed to log in to github.com using token (default)' \
        >"$gh_id_fixture"
    gh_identity_run 1
    [ "$gh_id_rc" = "2" ] ||
        fail "a (default) pseudo-source with no aliases exited ${gh_id_rc}, expected unauthenticated (2)"
    case "$gh_id_out" in
    *GH_TOKEN*) ;;
    *) fail "the (default) unauthenticated banner does not name GH_TOKEN: ${gh_id_out}" ;;
    esac
    if offers_login "$gh_id_out"; then
        fail "the (default) unauthenticated banner offers an operator login"
    fi

    # ...but an enterprise token gh attributes to NO host was never
    # enumerated: present-but-invisible credential material, indeterminate
    # even while the github.com login reads bot.
    printf '%s\n' \
        'github.com' \
        '  ✓ Logged in to github.com account someowner-bot (GH_TOKEN)' \
        >"$gh_id_fixture"
    gh_id_rc=0
    gh_id_out="$(GH_IDENTITY_TEST_FIXTURE="$gh_id_fixture" GH_IDENTITY_TEST_RC=0 \
        GH_TOKEN=sentinel-primary GITHUB_TOKEN= \
        GH_ENTERPRISE_TOKEN=sentinel-ghes GITHUB_ENTERPRISE_TOKEN= \
        PATH="$gh_id_bin" "$bash_bin" "$gh_check" 2>&1)" || gh_id_rc=$?
    [ "$gh_id_rc" = "3" ] ||
        fail "an enterprise token with no GHES host enumerated exited ${gh_id_rc}, expected indeterminate (3)"
    case "$gh_id_out" in
    *"never enumerated"*) ;;
    *) fail "the unattributed enterprise-token note does not say the token was never enumerated: ${gh_id_out}" ;;
    esac

    # A TIMED-OUT enumeration is INCOMPLETE, not clean: gh validates
    # accounts sequentially, so a probe killed after printing the bot
    # account but before a later stored human credential must not read as
    # "every credential is a bot". The stub reproduces the partial output
    # and timeout(1)'s 124.
    printf '%s\n' \
        'github.com' \
        '  ✓ Logged in to github.com account someowner-bot (GH_TOKEN)' \
        >"$gh_id_fixture"
    gh_identity_run 124
    [ "$gh_id_rc" = "3" ] ||
        fail "timed-out bot-only enumeration exited ${gh_id_rc}, expected indeterminate (3)"

    # ...while a non-bot login already parsed BEFORE the deadline is
    # evidence that stands: the violation outranks the incompleteness.
    printf '%s\n' \
        'github.com' \
        '  ✓ Logged in to github.com account someoperator (keyring)' \
        >"$gh_id_fixture"
    gh_identity_run 124
    [ "$gh_id_rc" = "1" ] ||
        fail "timed-out enumeration with a parsed non-bot login exited ${gh_id_rc}, expected violation (1)"

    # POSTURE WORDING. The agent posture (FOREMAN_DEVCONTAINER=agent) runs the
    # same tripwire from its post-start, but its PAT is AGENT_GH_TOKEN,
    # projected into .devcontainer/agent/devcontainer.env, and its harness runs
    # in auto mode with bypass disabled. Every banner and remedy there must say
    # so and must never send the operator to the bot's GH_TOKEN chain; the bot
    # wording is pinned alongside so the switch cannot drift it.
    local gh_id_posture gh_id_case
    local gh_id_bot_remedy=("template parameter" ".devcontainer/devcontainer.env")
    local gh_id_bot_banner=("BOT CONTAINER" "bypassPermissions")

    # Unauthenticated (2) and a stored NON-BOT login (1): the two banners.
    for gh_id_posture in bot agent; do
        printf '%s\n' \
            'You are not logged into any GitHub hosts. To log in, run: gh auth login' \
            >"$gh_id_fixture"
        gh_identity_posture_run "$gh_id_posture" 1 ""
        gh_id_case="${gh_id_posture}-posture unauthenticated gh-identity banner"
        [ "$gh_id_rc" = "2" ] || fail "${gh_id_case} exited ${gh_id_rc}, expected 2"
        if offers_login "$gh_id_out"; then
            fail "${gh_id_case} offers an operator login"
        fi
        if [ "$gh_id_posture" = agent ]; then
            gh_identity_expect "$gh_id_case" "AGENT CONTAINER" "auto-mode agent container" \
                "AGENT_GH_TOKEN" ".devcontainer/agent/devcontainer.env"
            gh_identity_refute "$gh_id_case" "${gh_id_bot_banner[@]}" "${gh_id_bot_remedy[@]}"
        else
            gh_identity_expect "$gh_id_case" "${gh_id_bot_banner[@]}" "${gh_id_bot_remedy[@]}"
            gh_identity_refute "$gh_id_case" "AGENT CONTAINER" "AGENT_GH_TOKEN"
        fi

        printf '%s\n' \
            'github.com' \
            '  ✓ Logged in to github.com account someoperator (keyring)' \
            >"$gh_id_fixture"
        gh_identity_posture_run "$gh_id_posture" 0 ""
        gh_id_case="${gh_id_posture}-posture non-bot gh-identity banner"
        [ "$gh_id_rc" = "1" ] || fail "${gh_id_case} exited ${gh_id_rc}, expected 1"
        if [ "$gh_id_posture" = agent ]; then
            gh_identity_expect "$gh_id_case" "AGENT CONTAINER" "auto-mode" "AGENT_GH_TOKEN"
            gh_identity_refute "$gh_id_case" "${gh_id_bot_banner[@]}" "${gh_id_bot_remedy[@]}"
        else
            gh_identity_expect "$gh_id_case" "${gh_id_bot_banner[@]}" "${gh_id_bot_remedy[@]}"
            gh_identity_refute "$gh_id_case" "AGENT CONTAINER" "AGENT_GH_TOKEN"
        fi
    done

    # The two exit-3 paths that carried a fixed bot-PAT remedy: an
    # environment token gh could not validate, and one gh attributes to no
    # host. Under agent both name AGENT_GH_TOKEN and the agent env file; under
    # bot both keep the bot's GH_TOKEN chain.
    for gh_id_posture in bot agent; do
        printf '%s\n' \
            'github.com' \
            '  X Failed to log in to github.com using token (GH_TOKEN)' \
            '  - Active account: true' \
            >"$gh_id_fixture"
        gh_identity_posture_run "$gh_id_posture" 1 sentinel-token
        gh_id_case="${gh_id_posture}-posture unverifiable-token remedy"
        [ "$gh_id_rc" = "3" ] || fail "${gh_id_case} exited ${gh_id_rc}, expected 3"
        if [ "$gh_id_posture" = agent ]; then
            gh_identity_expect "$gh_id_case" "AGENT_GH_TOKEN" ".devcontainer/agent/devcontainer.env"
            gh_identity_refute "$gh_id_case" "bot PAT" "${gh_id_bot_remedy[@]}"
        else
            gh_identity_expect "$gh_id_case" "bot PAT" "${gh_id_bot_remedy[@]}"
            gh_identity_refute "$gh_id_case" "AGENT_GH_TOKEN"
        fi

        printf '%s\n' \
            'You are not logged into any GitHub hosts. To log in, run: gh auth login' \
            >"$gh_id_fixture"
        gh_identity_posture_run "$gh_id_posture" 1 sentinel-token
        gh_id_case="${gh_id_posture}-posture unattributed-token remedy"
        [ "$gh_id_rc" = "3" ] || fail "${gh_id_case} exited ${gh_id_rc}, expected 3"
        if [ "$gh_id_posture" = agent ]; then
            gh_identity_expect "$gh_id_case" "AGENT_GH_TOKEN" ".devcontainer/agent/devcontainer.env"
            gh_identity_refute "$gh_id_case" "bot PAT as GH_TOKEN"
        else
            gh_identity_expect "$gh_id_case" "bot PAT as GH_TOKEN"
            gh_identity_refute "$gh_id_case" "AGENT_GH_TOKEN"
        fi
        gh_identity_refute "$gh_id_case" "sentinel-token"

        # A shadowed alias (GITHUB_TOKEN differing from the GH_TOKEN gh
        # enumerated) and an enterprise token gh never enumerated: the other
        # two exit-3 paths that named the bot's GH_TOKEN.
        printf '%s\n' \
            'github.com' \
            '  ✓ Logged in to github.com account someowner-bot (GH_TOKEN)' \
            >"$gh_id_fixture"
        gh_id_rc=0
        gh_id_out="$(GH_IDENTITY_TEST_FIXTURE="$gh_id_fixture" GH_IDENTITY_TEST_RC=0 \
            FOREMAN_DEVCONTAINER="$gh_id_posture" \
            GH_TOKEN=sentinel-token GITHUB_TOKEN=sentinel-shadowed \
            GH_ENTERPRISE_TOKEN= GITHUB_ENTERPRISE_TOKEN= \
            PATH="$gh_id_bin" "$bash_bin" "$gh_check" 2>&1)" || gh_id_rc=$?
        gh_id_case="${gh_id_posture}-posture shadowed-alias remedy"
        [ "$gh_id_rc" = "3" ] || fail "${gh_id_case} exited ${gh_id_rc}, expected 3"
        if [ "$gh_id_posture" = agent ]; then
            gh_identity_expect "$gh_id_case" "GITHUB_TOKEN" "AGENT_GH_TOKEN" \
                ".devcontainer/agent/devcontainer.env"
            gh_identity_refute "$gh_id_case" "provisioned bot GH_TOKEN"
        else
            gh_identity_expect "$gh_id_case" "GITHUB_TOKEN" "provisioned bot GH_TOKEN"
            gh_identity_refute "$gh_id_case" "AGENT_GH_TOKEN"
        fi
        gh_identity_refute "$gh_id_case" "sentinel-token" "sentinel-shadowed"

        gh_id_rc=0
        gh_id_out="$(GH_IDENTITY_TEST_FIXTURE="$gh_id_fixture" GH_IDENTITY_TEST_RC=0 \
            FOREMAN_DEVCONTAINER="$gh_id_posture" \
            GH_TOKEN=sentinel-token GITHUB_TOKEN= \
            GH_ENTERPRISE_TOKEN=sentinel-ghes GITHUB_ENTERPRISE_TOKEN= \
            PATH="$gh_id_bin" "$bash_bin" "$gh_check" 2>&1)" || gh_id_rc=$?
        gh_id_case="${gh_id_posture}-posture unenumerated-enterprise-token remedy"
        [ "$gh_id_rc" = "3" ] || fail "${gh_id_case} exited ${gh_id_rc}, expected 3"
        if [ "$gh_id_posture" = agent ]; then
            gh_identity_expect "$gh_id_case" "GH_ENTERPRISE_TOKEN" "AGENT_GH_TOKEN" \
                ".devcontainer/agent/devcontainer.env"
            gh_identity_refute "$gh_id_case" "bot PAT as GH_TOKEN"
        else
            gh_identity_expect "$gh_id_case" "GH_ENTERPRISE_TOKEN" "bot PAT as GH_TOKEN"
            gh_identity_refute "$gh_id_case" "AGENT_GH_TOKEN"
        fi
        gh_identity_refute "$gh_id_case" "sentinel-token" "sentinel-ghes"
    done

    # A WEDGED gh (stalled network, DNS, or credential backend) must not
    # hang the callers: post-start and the container assert invoke the
    # helper with no wrapper, so the bound has to live inside it. The stub
    # sleeps far past the 1s override; only the helper's own timeout can
    # end the run quickly, and the elapsed bound is what catches an
    # unbounded probe.
    local gh_id_start gh_id_elapsed
    printf '%s\n' '#!/bin/sh' 'sleep 45' >"${gh_id_bin}/gh"
    gh_id_start="$(date +%s)"
    gh_id_rc=0
    GH_IDENTITY_TIMEOUT=1 PATH="$gh_id_bin" "$bash_bin" "$gh_check" >/dev/null 2>&1 || gh_id_rc=$?
    gh_id_elapsed=$(($(date +%s) - gh_id_start))
    [ "$gh_id_elapsed" -lt 30 ] ||
        fail "gh-identity probe ran ${gh_id_elapsed}s against a wedged gh — the helper carries no timeout"
    [ "$gh_id_rc" = "3" ] ||
        fail "wedged gh exited ${gh_id_rc}, expected indeterminate (3) via the helper's own timeout"

    # A kill-resistant gh (TERM trapped) must still resolve inside the
    # caller's window: the kill grace is parameterized so the status
    # board's outer bound can contain deadline + grace, and the helper's
    # own timed-out note survives to be printed. Elapsed is the assertion:
    # the default 5s grace would run ~6s and lose the note to the outer
    # kill.
    printf '%s\n' '#!/bin/sh' "trap '' TERM" 'sleep 45' >"${gh_id_bin}/gh"
    gh_id_start="$(date +%s)"
    gh_id_rc=0
    gh_id_out="$(GH_IDENTITY_TIMEOUT=1 GH_IDENTITY_KILL_GRACE=1 \
        PATH="$gh_id_bin" "$bash_bin" "$gh_check" 2>&1)" || gh_id_rc=$?
    gh_id_elapsed=$(($(date +%s) - gh_id_start))
    [ "$gh_id_elapsed" -lt 5 ] ||
        fail "kill-resistant gh took ${gh_id_elapsed}s under a 1s deadline + 1s grace — the grace is not parameterized"
    [ "$gh_id_rc" = "3" ] ||
        fail "kill-resistant gh exited ${gh_id_rc}, expected indeterminate (3)"
    case "$gh_id_out" in
    *"timed out"*) ;;
    *) fail "kill-resistant gh lost the helper's own timed-out note: ${gh_id_out}" ;;
    esac

    # Wiring: the BOT post-start runs the tripwire on every start (an
    # interactive login can happen at any point in a container's life, not
    # just at create); the human profile must not — a human login is that
    # profile's correct state.
    #
    # Matched as an EXECUTION line with comments stripped, the way the
    # status-board assertion above is. A bare grep over the whole file passes
    # on any mention of the filename — today the only mention is the
    # invocation, so it does bite, but the comments right above it describe
    # the tripwire and one edit that names the file there would silently make
    # this check vacuous. Cheap to close now; invisible once it happens.
    grep -Ev '^[[:space:]]*#' "${repo_root}/.devcontainer/post-start.sh" |
        grep -E '^[[:space:]]*bash[[:space:]]+[^[:space:]|]*check-bot-gh-identity\.sh' >/dev/null ||
        fail "bot post-start does not EXECUTE the gh-identity tripwire (a mention in a comment is not a run)"
    if grep -q 'check-bot-gh-identity.sh' "${repo_root}/.devcontainer/dev/post-start.sh"; then
        fail "human post-start runs the bot-only gh-identity tripwire"
    fi

    # The status board no longer probes gh identity (see the note in
    # status.sh): that surface was descoped rather than hardened a fourth time.
    # What it still owes is the remedy WORDING below, which is checked here, and
    # the "no hardcoded remedy acting on the current login" invariant, which
    # lives in scripts/test-status.sh beside the ${GH_REMEDY} derivation guard
    # it was widened from (issue #596) — one invariant, one home.
    local status_sh
    status_sh="${repo_root}/scripts/status.sh"
    # The "no hardcoded remedy acting on the current login" invariant lives in
    # scripts/test-status.sh, beside the ${GH_REMEDY} derivation guard it was
    # widened from (issue #596) — one invariant, one home. This file keeps the
    # devcontainer WIRING assertions only.

    # The credential line's own remedy must not contradict the tripwire banner
    # on the same screen: in the bot profile an operator `gh auth login` is the
    # escalation harmon-init#1236 exists to stop.
    local remedy_out
    remedy_out="$(FOREMAN_DEVCONTAINER=bot "$bash_bin" -c \
        "$(sed -n '/^gh_login_remedy() {/,/^}/p' "$status_sh"); gh_login_remedy")"
    if offers_login "$remedy_out"; then
        fail "status board's gh remedy offers an interactive login in the bot profile: ${remedy_out}"
    fi
    case "$remedy_out" in
    *GH_TOKEN*) ;;
    *) fail "status board's bot-profile gh remedy does not name GH_TOKEN: ${remedy_out}" ;;
    esac
    # The agent posture is its own answer, never the bot's: no login, and
    # the agent's own variable rather than the bot's GH_TOKEN.
    remedy_out="$(FOREMAN_DEVCONTAINER=agent "$bash_bin" -c \
        "$(sed -n '/^gh_login_remedy() {/,/^}/p' "$status_sh"); gh_login_remedy")"
    if offers_login "$remedy_out"; then
        fail "status board's gh remedy offers an interactive login in the agent posture: ${remedy_out}"
    fi
    case "$remedy_out" in
    *AGENT_GH_TOKEN*) ;;
    *) fail "status board's agent-posture gh remedy does not name AGENT_GH_TOKEN: ${remedy_out}" ;;
    esac
    remedy_out="$(FOREMAN_DEVCONTAINER= "$bash_bin" -c \
        "$(sed -n '/^gh_login_remedy() {/,/^}/p' "$status_sh"); gh_login_remedy")"
    if ! offers_login "$remedy_out"; then
        fail "status board's gh remedy omits the operator login outside the bot profile: ${remedy_out}"
    fi

    # The SCOPE remedy gets the same behavioral treatment as the login remedy.
    # The static guard in test-status.sh exempts this helper's whole body —
    # correctly, since it is the derivation — which means reverting its bot
    # branch to `task setup:gh-scopes` would slip past a purely static check.
    # That residual is what this pair closes. Found by the review stage.
    local scope_src
    scope_src="$(sed -n '/^gh_scope_remedy_default() {/,/^}/p' "$status_sh")"
    remedy_out="$(FOREMAN_DEVCONTAINER=bot "$bash_bin" -c \
        ". \"$scopes_lib\"; $scope_src; gh_scope_remedy_default")"
    case "$remedy_out" in
    *"setup:gh-scopes"* | *"gh auth refresh"* | *"gh auth login"*)
        fail "status board's bot-profile scope remedy tells the reader to act on the current login, which the tripwire may be about to condemn: ${remedy_out}"
        ;;
    esac
    case "$remedy_out" in
    *GH_TOKEN*) ;;
    *) fail "status board's bot-profile scope remedy does not point at re-provisioning GH_TOKEN: ${remedy_out}" ;;
    esac
    remedy_out="$(FOREMAN_DEVCONTAINER=agent "$bash_bin" -c \
        ". \"$scopes_lib\"; $scope_src; gh_scope_remedy_default")"
    case "$remedy_out" in
    *"setup:gh-scopes"* | *"gh auth refresh"* | *"gh auth login"*)
        fail "status board's agent-posture scope remedy tells the reader to act on the current login: ${remedy_out}"
        ;;
    esac
    case "$remedy_out" in
    *AGENT_GH_TOKEN*) ;;
    *) fail "status board's agent-posture scope remedy does not point at re-provisioning AGENT_GH_TOKEN: ${remedy_out}" ;;
    esac
    remedy_out="$(FOREMAN_DEVCONTAINER= "$bash_bin" -c \
        ". \"$scopes_lib\"; $scope_src; gh_scope_remedy_default")"
    case "$remedy_out" in
    *"setup:gh-scopes"*) ;;
    *) fail "status board's scope remedy outside the bot profile no longer names the scopes task: ${remedy_out}" ;;
    esac

    # 11. Static devcontainer.json invariants via the devcontainers CLI.
    assert_config_invariants "$repo_root" "$bot_config" bot
    assert_config_invariants "$repo_root" "$dev_config" dev
    assert_config_invariants "$repo_root" "$agent_config" agent

    echo "==> devcontainer unit assertions passed."
}

# assert_config_invariants <repo_root> <config> <profile>
# agent: everything bot forbids, plus: the containerEnv marker is exactly
#      "agent", init-env.sh runs in its fail-closed --profile agent mode and
#      never allow-lists the bot's GH_TOKEN, every env token that would outrank
#      the agent login is blanked, NET_ADMIN is granted for the egress filter,
#      the host Docker socket is never mounted, and Docker-in-Docker appears
#      only with the documented HARMON_AGENT_DOCKER=dind opt-in.
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
        jq -r '(.configuration.initializeCommand // "") | test("(^|[^A-Z_])GH_TOKEN") | if . then 1 else 0 end')"
    local foreman_marker gh_browser_config terminal_browser_config
    foreman_marker="$(printf '%s' "$cfg" |
        jq -r '.configuration.containerEnv.FOREMAN_DEVCONTAINER // ""')"
    gh_browser_config="$(printf '%s' "$cfg" |
        jq -r '.configuration.containerEnv.GH_BROWSER // ""')"
    terminal_browser_config="$(printf '%s' "$cfg" |
        jq -r '.configuration.customizations.vscode.settings["terminal.integrated.env.linux"].BROWSER // "<absent>"')"
    [ "$terminal_browser_config" = "" ] ||
        fail "${profile} config no longer blanks generic BROWSER in VS Code terminals"

    # The tailnet gate's config-level invariants, across TWO markers.
    #
    # DEVCONTAINER_TAILSCALE means "this profile HAS a tailnet".
    # post-start-common.sh gates the whole connect step on it, so losing it from
    # the dev config silently stops that profile from ever attempting a
    # connection — even with a valid TS_AUTHKEY. Unconditional, asserted per
    # profile: dev sets it, bot must not.
    #
    # DEVCONTAINER_TAILSCALE_REQUIRED is what makes a failed connect FATAL. It
    # is optional by design — arming it makes a profile unable to start without
    # a Tailscale account and a live auth key, which no generated repo may
    # depend on by default — so it is gated on the `tailscale_required` copier
    # answer and its absence is a legitimate rendering. This script is a
    # verbatim twin and runs in repos that answered either way.
    local ts_marker ts_required ts_optional_env ts_map
    ts_marker="$(printf '%s' "$cfg" |
        jq -r '.configuration.containerEnv.DEVCONTAINER_TAILSCALE // "<absent>"')"
    ts_required="$(printf '%s' "$cfg" |
        jq -r '.configuration.containerEnv.DEVCONTAINER_TAILSCALE_REQUIRED // "<absent>"')"

    # Both markers are exact-match knobs: a plausible-looking "yes" or "1" reads
    # as absent to the shell test, so a config could look armed while being
    # disarmed. Only `true` or absence is a coherent state.
    case "$ts_marker" in
    true | "<absent>") ;;
    *) fail "${profile} config sets containerEnv.DEVCONTAINER_TAILSCALE='${ts_marker}' — only the exact string 'true' counts, so this looks set and is not" ;;
    esac
    case "$ts_required" in
    true | "<absent>") ;;
    *) fail "${profile} config sets containerEnv.DEVCONTAINER_TAILSCALE_REQUIRED='${ts_required}' — only the exact string 'true' arms the gate, so this looks armed and is not" ;;
    esac

    # Requiring a tailnet a profile cannot reach is unsatisfiable by
    # construction, so the fatal marker may only appear where the profile
    # actually declares a tailnet.
    if [ "$ts_required" = "true" ] && [ "$ts_marker" != "true" ]; then
        fail "${profile} config requires the tailnet (DEVCONTAINER_TAILSCALE_REQUIRED=true) without declaring one (DEVCONTAINER_TAILSCALE) — the gate could never be satisfied"
    fi

    if [ "$profile" = "dev" ]; then
        [ "$ts_marker" = "true" ] ||
            fail "dev config does not set containerEnv.DEVCONTAINER_TAILSCALE=true — post-start would never invoke tailscale-connect.sh, so this profile would never connect even with a valid TS_AUTHKEY"
        [ "$has_ts_feature" != "0" ] ||
            fail "dev config declares a tailnet but installs no tailscale feature"
    else
        [ "$ts_marker" != "true" ] ||
            fail "${profile} config sets containerEnv.DEVCONTAINER_TAILSCALE=true — only the tailnet-bearing profile may declare one"
        [ "$ts_required" != "true" ] ||
            fail "${profile} config sets containerEnv.DEVCONTAINER_TAILSCALE_REQUIRED=true — only the tailnet-bearing profile may require one"
    fi

    # DEVCONTAINER_TAILSCALE_OPTIONAL demotes a required tailnet back to
    # optional, and is meant to arrive via `devcontainer up --remote-env` so
    # opting out is an explicit act at the CALL SITE. remoteEnv in a
    # devcontainer.json IS applied to lifecycle commands, so a profile that set
    # it either way could disable the gate from inside the very config the gate
    # exists to guard. NEITHER profile may carry it in either map.
    for ts_map in containerEnv remoteEnv; do
        ts_optional_env="$(printf '%s' "$cfg" |
            jq -r --arg m "$ts_map" '(.configuration[$m] // {}).DEVCONTAINER_TAILSCALE_OPTIONAL // "<absent>"')"
        [ "$ts_optional_env" = "<absent>" ] ||
            fail "${profile} config sets ${ts_map}.DEVCONTAINER_TAILSCALE_OPTIONAL ('${ts_optional_env}') — the tailnet opt-out belongs at the call site, not in the config it guards"
    done

    if [ "$profile" = "bot" ]; then
        [ "$has_ts_feature" = "0" ] || fail "bot config has a tailscale feature"
        [ "$has_op_feature" = "0" ] || fail "bot config has a 1Password CLI feature (no secret-store path in the bot container)"
        [ "$has_tun" = "0" ] || fail "bot config requests /dev/net/tun"
        [ "$has_ts_init" = "0" ] || fail "bot config references TS_AUTHKEY in initializeCommand"
        [ "$has_gh_init" = "1" ] || fail "bot config does not reference GH_TOKEN in initializeCommand"
        [ -z "$gh_browser_config" ] || fail "bot config sets GH_BROWSER — operator OAuth belongs only in the human profile"
        # Foreman's D2 startup tripwire: it refuses even read-only commands
        # unless FOREMAN_DEVCONTAINER=bot, so losing this marker breaks every
        # task foreman:* while verify stays green.
        [ "$foreman_marker" = "bot" ] || fail "bot config does not set containerEnv.FOREMAN_DEVCONTAINER=bot (foreman refuses to start)"
    elif [ "$profile" = "agent" ]; then
        [ "$has_ts_feature" = "0" ] || fail "agent config has a tailscale feature"
        [ "$has_op_feature" = "0" ] || fail "agent config has a 1Password CLI feature"
        [ "$has_tun" = "0" ] || fail "agent config requests /dev/net/tun"
        [ "$has_ts_init" = "0" ] || fail "agent config references TS_AUTHKEY in initializeCommand"
        [ "$has_gh_init" = "0" ] || fail "agent config references the bot's GH_TOKEN in initializeCommand (the agent posture uses AGENT_GH_TOKEN)"
        [ -z "$gh_browser_config" ] || fail "agent config sets GH_BROWSER — operator OAuth belongs only in the human profile"
        [ "$foreman_marker" = "agent" ] ||
            fail "agent config sets containerEnv.FOREMAN_DEVCONTAINER='${foreman_marker}', expected 'agent'"
        printf '%s' "$cfg" | jq -e '(.configuration.initializeCommand // "") | startswith("bash .devcontainer/scripts/init-env.sh --profile agent ")' >/dev/null ||
            fail "agent config does not run init-env.sh in its fail-closed --profile agent mode"
        printf '%s' "$cfg" | jq -e '(.configuration.runArgs // []) | index("--cap-add=NET_ADMIN")' >/dev/null ||
            fail "agent config lacks --cap-add=NET_ADMIN, so its egress filter cannot be installed"
        if printf '%s' "$cfg" | jq -e '[((.configuration.mounts // [])[] | tostring), (.configuration.runArgs // [])[]] | any(test("docker\\.sock"))' >/dev/null; then
            fail "agent config mounts the host Docker socket"
        fi
        local agent_dind agent_docker_marker alias_var blanked
        agent_dind="$(printf '%s' "$cfg" |
            jq -r '[.configuration.features // {} | keys[] | select(test("docker-in-docker|docker-outside-of-docker|docker-from-docker"))] | length')"
        agent_docker_marker="$(printf '%s' "$cfg" | jq -r '.configuration.containerEnv.HARMON_AGENT_DOCKER // ""')"
        if [ "$agent_dind" != "0" ] && [ "$agent_docker_marker" != "dind" ]; then
            fail "agent config installs Docker without the documented HARMON_AGENT_DOCKER=dind opt-in"
        fi
        for alias_var in GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN; do
            blanked="$(printf '%s' "$cfg" |
                jq -r --arg v "$alias_var" '(.configuration.containerEnv // {})[$v] // "<absent>"')"
            [ "$blanked" = "" ] ||
                fail "agent config does not blank ${alias_var} in containerEnv (gh would prefer it over the agent login); found '${blanked}'"
        done
    elif [ "$profile" = "dev" ]; then
        [ "$has_ts_feature" != "0" ] || fail "dev config is missing the tailscale feature"
        [ "$has_op_feature" != "0" ] || fail "dev config is missing the 1Password CLI feature"
        [ "$has_tun" != "0" ] || fail "dev config is missing the /dev/net/tun device"
        [ "$has_ts_init" = "1" ] || fail "dev config does not reference TS_AUTHKEY in initializeCommand"
        [ "$has_gh_init" = "0" ] || fail "dev config references GH_TOKEN in initializeCommand (a human profile must carry no bot credential)"
        [ -z "$foreman_marker" ] || fail "dev config sets FOREMAN_DEVCONTAINER — foreman must refuse to run in the human profile"
        [ "$gh_browser_config" = "/usr/local/share/devcontainer-config/gh-browser.sh" ] ||
            fail "dev config does not route GH_BROWSER through the host-browser bridge; found '${gh_browser_config}'"

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
    else
        fail "unknown devcontainer profile '${profile}' (expected bot, dev, or agent)"
    fi
}

# ── container mode ────────────────────────────────────────────────────
# assert_container <config> <container-id> <profile> <workspace-folder>
assert_container() {
    local config="$1" container_id="$2" profile="$3" workspace_folder="$4"
    [ -n "$container_id" ] || fail "container mode requires a container id"
    [ -n "$workspace_folder" ] || fail "container mode requires a workspace folder"

    local git_name git_email codex_sandbox codex_approval codex_model codex_effort
    git_name="$(docker exec -u vscode "$container_id" git config --global user.name)" ||
        fail "could not read git user.name in container"
    git_email="$(docker exec -u vscode "$container_id" git config --global user.email)" ||
        fail "could not read git user.email in container"
    codex_model="$(docker exec -u vscode "$container_id" cat /etc/codex/config.toml | toml_root_scalar model -)" ||
        fail "could not read the Codex default model"
    codex_effort="$(docker exec -u vscode "$container_id" cat /etc/codex/config.toml | toml_root_scalar model_reasoning_effort -)" ||
        fail "could not read the Codex default reasoning effort"
    codex_sandbox="$(docker exec -u vscode "$container_id" cat /etc/codex/managed_config.toml | toml_root_scalar sandbox_mode -)" ||
        fail "could not read the managed Codex sandbox mode"
    codex_approval="$(docker exec -u vscode "$container_id" cat /etc/codex/managed_config.toml | toml_root_scalar approval_policy -)" ||
        fail "could not read the managed Codex approval policy"
    [ "$codex_model" = "gpt-6.1-sol" ] || fail "Codex default model is '${codex_model}', expected gpt-6.1-sol"
    [ "$codex_effort" = "medium" ] || fail "Codex default reasoning is '${codex_effort}', expected medium"
    # The running container must keep the two layers separate, not just the
    # repo copies: a preference in the managed layer is unoverridable.
    local codex_live_key
    for codex_live_key in model model_reasoning_effort project_doc_max_bytes; do
        if docker exec -u vscode "$container_id" \
            grep -qE "^[[:space:]]*\"?${codex_live_key}\"?[[:space:]]*=" /etc/codex/managed_config.toml; then
            fail "/etc/codex/managed_config.toml pins '${codex_live_key}';" \
                "that is an overridable default and belongs in /etc/codex/config.toml" \
                "(harmon-init#1186)"
        fi
    done
    if docker exec -u vscode "$container_id" \
        grep -qE '^[[:space:]]*\[tui\]' /etc/codex/managed_config.toml; then
        fail "/etc/codex/managed_config.toml pins a [tui] table; the status line is" \
            "an overridable default and belongs in /etc/codex/config.toml (harmon-init#1186)"
    fi

    # `task` ships from the pinned shared image, NOT a devcontainer Feature
    # (harmon-init#427 history). The expected version comes from the image's
    # own machine-readable manifest, and the manifest's revision must match
    # the Dockerfile's pinned source commit — proving the running container
    # was really built from the approved immutable reference, not a stale or
    # floating image that happens to have the binaries.
    local script_dir repo_root pinned_source manifest manifest_revision pinned_task actual_task
    script_dir="$(cd "$(dirname "$0")" && pwd -P)"
    repo_root="$(cd "$script_dir/.." && pwd -P)"
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
    actual_version="$(grep -m1 -oE '[0-9]+\.[0-9]+\.[0-9]+' <<<"$actual_task")"
    [ -n "$actual_version" ] ||
        fail "could not parse a version out of 'task --version' output '${actual_task}' in the ${profile} container"
    [ "$actual_version" = "$pinned_task" ] ||
        fail "task version '${actual_version}' in the ${profile} container does not match the pin '${pinned_task}'"

    if [ "$profile" = "bot" ]; then
        [ "$codex_sandbox" = "danger-full-access" ] || fail "bot Codex sandbox is '${codex_sandbox}'"
        [ "$codex_approval" = "never" ] || fail "bot Codex approval policy is '${codex_approval}'"
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

        # Who gh WRITES as, not just who git commits as (harmon-init#1236) —
        # the live counterpart of unit check 10b. The checkout's helper runs
        # inside the container over stdin, so no workspace mount path is
        # assumed. Only exit 1 — a credential naming a non-bot account — is the
        # violation this assert exists to catch. Unauthenticated (2) passes:
        # the helper already printed the GH_TOKEN remedy, and a fresh
        # container before token provisioning is healthy. Indeterminate (3:
        # offline, rate-limited, or an unverifiable token) is not evidence
        # of a violation and must not fail a smoke run.
        local gh_identity_rc=0
        docker exec -i -u vscode "$container_id" bash -s \
            <"${repo_root}/.devcontainer/scripts/check-bot-gh-identity.sh" ||
            gh_identity_rc=$?
        case "$gh_identity_rc" in
        0 | 2 | 3) ;;
        1) fail "bot container gh credential does not match the '-bot' relationship (see warning above)" ;;
        *) fail "could not run the gh-identity check in the bot container (exit ${gh_identity_rc})" ;;
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

        # Every supported installed harness's bot policy, re-checked against
        # its live effective state — the same verifier post-create and
        # post-start already run. Reuses the one implementation rather than
        # duplicating each boundary's check a second time here (Claude Code,
        # Antigravity, and OpenCode would otherwise go completely unchecked
        # in CI despite the "every supported installed harness" claim).
        # `-w` pins the exec's cwd to the workspace folder: the Dockerfile
        # sets no WORKDIR, so `docker exec` with no `-w` defaults to `/` (or
        # whatever the base image sets), not the mounted workspace — a
        # relative script path resolves against that default, not against
        # where postCreate/postStart actually run.
        local bot_autonomy_out bot_autonomy_rc
        bot_autonomy_rc=0
        bot_autonomy_out="$(docker exec -u vscode -w "$workspace_folder" "$container_id" \
            bash .devcontainer/scripts/bot-autonomy.sh verify 2>&1)" || bot_autonomy_rc=$?
        [ "$bot_autonomy_rc" -eq 0 ] ||
            fail "bot-autonomy.sh verify failed in the bot container: ${bot_autonomy_out}"

        # The Copilot autonomy wrapper only works if it actually WINS on the
        # container-wide PATH. `bot-autonomy.sh verify` proves the wrapper
        # exists with the right bytes, but a wrong PATH order would leave
        # every real `copilot` invocation delegating straight to the system
        # binary with no --allow-all — a green verify over an ineffective
        # wrapper. Resolve the name the way a programmatic launcher does
        # (no login shell), assert WHICH file wins, and only then exercise
        # it. Gated on the marker: a default-off consumer has no wrapper to
        # win, and on a pin that predates the harness-matrix image there is
        # no `copilot` at all yet (this becomes live coverage once the
        # sync-pin PR lands).
        local copilot_marker copilot_path copilot_version
        copilot_marker="$(docker exec -u vscode "$container_id" printenv HARMON_BOT_AUTONOMY_COPILOT 2>/dev/null || true)"
        copilot_path="$(docker exec -u vscode -w "$workspace_folder" "$container_id" \
            sh -c 'command -v copilot || true' 2>/dev/null || true)"
        if [ "$copilot_marker" = "enabled" ] && [ -n "$copilot_path" ]; then
            [ "$copilot_path" = "/home/vscode/.local/bin/copilot" ] ||
                fail "copilot resolves to '${copilot_path}' in the bot container, not the autonomy wrapper at /home/vscode/.local/bin/copilot — the container-wide PATH prepend is not winning"
            copilot_version="$(docker exec -u vscode -w "$workspace_folder" "$container_id" \
                copilot --version 2>&1)" ||
                fail "the copilot autonomy wrapper could not run 'copilot --version' in the bot container: ${copilot_version}"
        elif [ "$copilot_marker" = "enabled" ] &&
            [ "$(pinned_image_digest "${repo_root}/.devcontainer/Dockerfile")" = "$HARMON_PRE_HARNESS_MATRIX_DIGEST" ]; then
            # Bounded to the one pin that genuinely ships no copilot, so this
            # cannot become a standing excuse — see the constant above.
            echo "==> note: HARMON_BOT_AUTONOMY_COPILOT=enabled on the pre-harness-matrix pin, which ships no copilot binary; wrapper PATH assertion becomes live when #1152 bumps the pin"
        elif [ "$copilot_marker" = "enabled" ]; then
            fail "HARMON_BOT_AUTONOMY_COPILOT=enabled but no copilot resolves on PATH in the bot container, and this image is not the pre-harness-matrix pin — the autonomy wrapper is missing or its binary is gone"
        fi
    elif [ "$profile" = "agent" ]; then
        # The AGENT posture, live: every static invariant above, re-checked
        # against what the running container actually does.
        [ "$codex_sandbox" = "workspace-write" ] || fail "agent Codex sandbox is '${codex_sandbox}' (never danger-full-access)"
        [ "$codex_approval" = "never" ] || fail "agent Codex approval policy is '${codex_approval}'"
        # The agent PAT lives on the bot account, so the bot relationship holds.
        case "$git_email" in
        *-bot@*) ;;
        *) fail "agent git email '${git_email}' does not contain '-bot@'" ;;
        esac
        case "$git_name" in
        *-bot) ;;
        *) fail "agent git name '${git_name}' does not end with '-bot'" ;;
        esac
        local agent_marker
        agent_marker="$(docker exec -u vscode "$container_id" printenv FOREMAN_DEVCONTAINER 2>/dev/null || true)"
        [ "$agent_marker" = "agent" ] || fail "FOREMAN_DEVCONTAINER is '${agent_marker}' in the agent container, expected 'agent'"

        local gh_identity_rc=0
        docker exec -i -u vscode "$container_id" bash -s \
            <"${repo_root}/.devcontainer/scripts/check-bot-gh-identity.sh" ||
            gh_identity_rc=$?
        case "$gh_identity_rc" in
        0 | 2 | 3) ;;
        1) fail "agent container gh credential does not match the '-bot' relationship (see warning above)" ;;
        *) fail "could not run the gh-identity check in the agent container (exit ${gh_identity_rc})" ;;
        esac

        if docker exec -u vscode "$container_id" sh -c 'command -v tailscale' >/dev/null 2>&1; then
            fail "tailscale CLI is present in the agent container"
        fi
        if docker exec -u vscode "$container_id" sh -c 'command -v op' >/dev/null 2>&1; then
            fail "the 1Password CLI is present in the agent container"
        fi
        # Captured, never echoed (same discipline as the bot's TS_AUTHKEY check).
        local forbidden_var forbidden_val
        for forbidden_var in GH_TOKEN GITHUB_TOKEN FOREMAN_AGENT_GH_TOKEN TS_AUTHKEY ANTHROPIC_API_KEY OP_SERVICE_ACCOUNT_TOKEN; do
            forbidden_val="$(docker exec -u vscode "$container_id" printenv "$forbidden_var" 2>/dev/null || true)"
            [ -z "$forbidden_val" ] || fail "${forbidden_var} is set in the agent container"
        done

        # No Docker unless the documented opt-in turned it on, and never the
        # host socket.
        if docker exec -u vscode "$container_id" sh -c 'test -S /var/run/docker.sock'; then
            if [ "$(docker exec -u vscode "$container_id" printenv HARMON_AGENT_DOCKER 2>/dev/null || true)" != "dind" ]; then
                fail "a Docker socket exists in the agent container without the HARMON_AGENT_DOCKER=dind opt-in"
            fi
        fi

        local agent_out agent_rc
        agent_rc=0
        agent_out="$(docker exec -u vscode -w "$workspace_folder" "$container_id" \
            bash .devcontainer/agent/agent-autonomy.sh verify 2>&1)" || agent_rc=$?
        [ "$agent_rc" -eq 0 ] || fail "agent-autonomy.sh verify failed in the agent container: ${agent_out}"

        # Egress: the filter is installed, a listed host is reachable, an
        # unlisted one is refused, and the refusal is recorded for the lane
        # report. example.com is the reserved documentation domain (RFC 2606)
        # and must never be on the list.
        agent_rc=0
        agent_out="$(docker exec -u root -w "$workspace_folder" "$container_id" \
            bash .devcontainer/scripts/egress-allowlist.sh verify 2>&1)" || agent_rc=$?
        [ "$agent_rc" -eq 0 ] || fail "egress-allowlist.sh verify failed in the agent container: ${agent_out}"
        # Every start applies the snapshot post-create wrote, so it must exist
        # and be root-owned and closed to writes, or an edit by the container
        # user would widen egress at the next start.
        docker exec -u vscode "$container_id" test -x /usr/local/share/harmon-egress/scripts/egress-allowlist.sh ||
            fail "the agent container has no egress snapshot for its starts to apply"
        agent_out="$(docker exec -u root "$container_id" find /usr/local/share/harmon-egress \
            \( ! -user root -o -perm -002 -o -perm -020 \) 2>&1)" ||
            fail "cannot inspect the egress snapshot in the agent container: ${agent_out}"
        [ -z "$agent_out" ] || fail "the egress snapshot is not root-owned and closed to writes: ${agent_out}"
        if grep -Eqx '[[:space:]]*example\.com[[:space:]]*' "${repo_root}/.devcontainer/egress-allowlist.txt"; then
            fail "example.com is on the egress allowlist; the refusal probe below needs it off"
        fi
        docker exec -u vscode "$container_id" curl -fsS -m 20 -o /dev/null https://api.github.com/zen ||
            fail "an allowlisted host (api.github.com) is not reachable from the agent container"
        # The record must name an address example.com resolved to, written by
        # THIS probe: resolve it in the container and drop those addresses
        # from the record first, so neither an unrelated refusal nor a stale
        # entry can satisfy the check below.
        local probe_addrs probe_addr probe_recorded=""
        probe_addrs="$(docker exec -u vscode "$container_id" getent ahostsv4 example.com 2>/dev/null |
            awk '{print $1}' | sort -u)" || true
        [ -n "$probe_addrs" ] ||
            fail "example.com does not resolve in the agent container, so its refusal cannot be attributed"
        while IFS= read -r probe_addr; do
            docker exec -u root "$container_id" sh -c \
                'printf -- "-%s\n" "$1" >/proc/net/xt_recent/harmon_egress_blocked' sh "$probe_addr" </dev/null ||
                fail "cannot clear ${probe_addr} from the agent container's blocked-destination record"
        done <<<"$probe_addrs"
        if docker exec -u vscode "$container_id" curl -sS -m 10 -o /dev/null https://example.com 2>/dev/null; then
            fail "a host outside the egress allowlist (example.com) is reachable from the agent container"
        fi
        agent_out="$(docker exec -u vscode -w "$workspace_folder" "$container_id" \
            bash .devcontainer/scripts/egress-allowlist.sh blocked 2>&1)" || true
        while IFS= read -r probe_addr; do
            if awk -v a="$probe_addr" '$1 == "blocked" && $2 == a {found = 1} END {exit found ? 0 : 1}' <<<"$agent_out"; then
                probe_recorded=1
            fi
        done <<<"$probe_addrs"
        [ -n "$probe_recorded" ] ||
            fail "the refused example.com connection ($(printf '%s' "$probe_addrs" | tr '\n' ' ')) was not recorded for the lane report: ${agent_out}"
    else
        [ "$codex_sandbox" = "workspace-write" ] || fail "human Codex sandbox is '${codex_sandbox}'"
        [ "$codex_approval" = "on-request" ] || fail "human Codex approval policy is '${codex_approval}'"
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

    # The `gh pr merge` ask is a dev-only managed-settings drop-in: installed
    # with exactly its two rules in dev, absent in bot and agent, which carry
    # no merge guard (the ruleset is the boundary).
    local dev_merge_ask
    dev_merge_ask="$(docker exec -u vscode "$container_id" cat /etc/claude-code/managed-settings.d/dev-gh-pr-merge-ask.json 2>/dev/null || true)"
    if [ "$profile" = "dev" ]; then
        jq -e '.permissions.ask == ["Bash(gh pr merge)","Bash(gh pr merge:*)"]' <<<"$dev_merge_ask" >/dev/null 2>&1 ||
            fail "the dev container's managed-settings.d drop-in does not ask on exactly Bash(gh pr merge) and Bash(gh pr merge:*)"
    elif [ -n "$dev_merge_ask" ]; then
        fail "the ${profile} container has the dev-only gh pr merge ask drop-in; ${profile} carries no merge guard"
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
    if [ "$#" -ne 4 ]; then
        echo "Usage: $0 container <config> <container-id> <profile> <workspace-folder>" >&2
        exit 1
    fi
    assert_container "$1" "$2" "$3" "$4"
    ;;
*)
    echo "Usage: $0 <unit|container> [args...]" >&2
    exit 1
    ;;
esac
