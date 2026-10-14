#!/usr/bin/env bash
set -euo pipefail

# Unit tests for the AGENT posture
# (docs/decisions/2026-09-29-agent-posture-three-posture-model.md). No
# container, no real secrets: every fixture uses a scratch directory, a fake
# PATH, and stub resolvers. The live counterparts — the filter really refusing
# a host, the harnesses really refused — run in the built container
# (scripts/devcontainer-assert.sh container mode, CI's devcontainer-assert-agent).
#
# What each section guards:
#   1. single source      — the agent Claude settings and Codex config exist
#                           only under .devcontainer/config/agent/ (and its
#                           verbatim template twin), and the agent
#                           devcontainer installs from there
#   2. Claude settings    — auto mode, bypass disabled, no ask rules, the
#                           agreed deny list, and nothing allowed that bot
#                           denies or that bot does not itself allow
#   3. Codex config       — never danger-full-access; parity with the shared
#                           baseline except the agent's documented keys
#   4. harness refusal    — coverage of every registry slug; apply refuses a
#                           harness with no agent-capable configuration, and
#                           only under the agent marker
#   5. env allowlist      — init-env.sh --profile agent admits the agent PAT
#                           and fails closed on everything else
#   6. Docker             — no socket ever; Docker-in-Docker only with the
#                           documented opt-in
#   7. egress             — the list parses, resolves, refuses an
#                           allow-nothing filter and an over-broad literal
#                           or @github-meta range (0.0.0.0/x, wider than
#                           /16); apply and establish fail closed — any
#                           failure, a failed iptables install or a refused
#                           snapshot included, leaves the OUTPUT/FORWARD
#                           policy DROP and flushes a previous filter's
#                           allow rules, and claims DROP only when every
#                           step for every address family succeeded (else
#                           a CRITICAL line); the lifecycle snapshots it root-owned
#                           at create, applies it first, and applies only
#                           the snapshot at start, closing egress without it
#                           when the snapshot is missing

fail() { # shell-robustness: ok — this reporter always exits 1
    echo "FAIL: $*" >&2
    exit 1
}

# The marker is ambient (Claude Code on the web exports FOREMAN_DEVCONTAINER=agent);
# clear it once so no case depends on where it runs. Cases set it themselves.
unset FOREMAN_DEVCONTAINER
script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(git -C "$script_dir" rev-parse --show-toplevel)"
cd "$repo_root"

agent_config_dir=.devcontainer/config/agent
agent_settings="${agent_config_dir}/claude-managed-settings.json"
agent_codex="${agent_config_dir}/codex-managed-config.toml"
bot_settings=.devcontainer/config/claude-settings.json
codex_baseline=.devcontainer/config/codex-managed-config.toml
agent_dc=.devcontainer/agent/devcontainer.json
agent_autonomy=.devcontainer/agent/agent-autonomy.sh
init_env=.devcontainer/scripts/init-env.sh
egress=.devcontainer/scripts/egress-allowlist.sh
devcontainers_guide=docs/guides/devcontainers.md

for f in "$agent_settings" "$agent_codex" "${agent_config_dir}/harnesses.json" "$bot_settings" \
    "$codex_baseline" "$agent_dc" "$agent_autonomy" "$init_env" "$egress" \
    .devcontainer/agent/post-create.sh .devcontainer/agent/post-start.sh \
    .devcontainer/egress-allowlist.txt "$devcontainers_guide"; do
    [ -f "$f" ] || fail "missing ${f}"
done

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

# jsonc_to_json <file> — devcontainer.json is JSONC. Strip // and /* */
# comments outside strings, then trailing commas outside strings, so jq can
# read it. One walk copies string literals verbatim and hands everything else
# to a pass, so neither pass can touch a string's contents.
jsonc_to_json() {
    python3 - "$1" <<'PY'
import json, sys

def walk(src, outside):
    out, i, n, in_str = [], 0, len(src), False
    while i < n:
        c = src[i]
        if in_str:
            out.append(c)
            if c == "\\":
                out.append(src[i + 1]); i += 2; continue
            if c == '"':
                in_str = False
            i += 1
        elif c == '"':
            in_str = True; out.append(c); i += 1
        else:
            i = outside(src, i, out)
    return "".join(out)

def comments(src, i, out):
    if src.startswith("//", i):
        while i < len(src) and src[i] != "\n":
            i += 1
        return i
    if src.startswith("/*", i):
        return src.index("*/", i) + 2
    out.append(src[i])
    return i + 1

def trailing_commas(src, i, out):
    if src[i] == ",":
        j = i + 1
        while j < len(src) and src[j].isspace():
            j += 1
        if j < len(src) and src[j] in "}]":
            return i + 1
    out.append(src[i])
    return i + 1

src = open(sys.argv[1], encoding="utf-8").read()
json.dump(json.loads(walk(walk(src, comments), trailing_commas)), sys.stdout)
PY
}

# Fixture: comments and trailing commas go; string contents that look like
# either stay.
printf '%s\n' '{' '  // a comment' '  "a": "x,}y,]z // not a comment",' '  "b": [1, 2, /* c */],' '}' >"${work_dir}/fixture.jsonc"
jsonc_fixture="$(jsonc_to_json "${work_dir}/fixture.jsonc")" || fail "jsonc_to_json could not read a JSONC fixture"
[ "$(jq -r '.a' <<<"$jsonc_fixture")" = 'x,}y,]z // not a comment' ] ||
    fail "jsonc_to_json altered a string value that contains ',}' or ',]': ${jsonc_fixture}"
[ "$(jq -c '.b' <<<"$jsonc_fixture")" = '[1,2]' ] ||
    fail "jsonc_to_json did not strip a trailing comma: ${jsonc_fixture}"

# ── 1. Single source ────────────────────────────────────────────────────
echo "==> 1. the agent profile has exactly one source"

# find_copies <root> — print every file under <root> (tracked or not, ignoring
# .git and gitignored paths) that duplicates an agent profile file: byte-equal,
# or the same JSON document for the settings, or the same TOML once comments
# and blank lines are stripped. The profile file itself and its verbatim
# template twin are the source, not copies.
find_copies() {
    local root="$1" src canon_json canon_toml f
    canon_json="$(jq -S -c . "${root}/${agent_settings}")"
    canon_toml="$(grep -Ev '^[[:space:]]*(#|$)' "${root}/${agent_codex}")"
    while IFS= read -r f; do
        case "$f" in
        "${agent_config_dir}"/* | "template/[% if devcontainer %].devcontainer[% endif %]/config/agent/"*) continue ;;
        esac
        [ -f "${root}/${f}" ] || continue
        for src in "$agent_settings" "$agent_codex"; do
            if cmp -s "${root}/${src}" "${root}/${f}"; then
                printf '%s (byte copy of %s)\n' "$f" "$src"
            fi
        done
        case "$f" in
        *.json | *.jsonc)
            if [ "$(jq -S -c . "${root}/${f}" 2>/dev/null)" = "$canon_json" ]; then
                printf '%s (JSON copy of %s)\n' "$f" "$agent_settings"
            fi
            ;;
        *.toml)
            if [ "$(grep -Ev '^[[:space:]]*(#|$)' "${root}/${f}")" = "$canon_toml" ]; then
                printf '%s (TOML copy of %s)\n' "$f" "$agent_codex"
            fi
            ;;
        esac
    done < <(git -C "$root" ls-files --cached --others --exclude-standard)
}

copies="$(find_copies "$repo_root")"
[ -z "$copies" ] || fail "the agent profile is duplicated outside ${agent_config_dir}: ${copies}"

# The template twin (harmon-init itself; a generated repo has none) must be
# the SAME source, byte for byte, not a fork.
twin_dir="template/[% if devcontainer %].devcontainer[% endif %]/config/agent"
if [ -d "$twin_dir" ]; then
    for f in claude-managed-settings.json codex-managed-config.toml harnesses.json; do
        cmp -s "${agent_config_dir}/${f}" "${twin_dir}/${f}" || fail "${twin_dir}/${f} is not identical to ${agent_config_dir}/${f}"
    done
fi

# Fixture: a reformatted JSON copy and a re-commented TOML copy are caught.
fixture_repo="${work_dir}/single-source"
mkdir -p "${fixture_repo}/${agent_config_dir}" "${fixture_repo}/elsewhere"
cp "$agent_settings" "$agent_codex" "${fixture_repo}/${agent_config_dir}/"
git -C "$fixture_repo" init -q
[ -z "$(find_copies "$fixture_repo")" ] || fail "single-source fixture reports a copy where there is none"
jq . "$agent_settings" >"${fixture_repo}/elsewhere/settings.json"
{
    echo "# a different header comment"
    cat "$agent_codex"
} >"${fixture_repo}/elsewhere/codex.toml"
fixture_copies="$(find_copies "$fixture_repo")"
grep -q 'elsewhere/settings.json' <<<"$fixture_copies" || fail "single-source check missed a reformatted JSON copy"
grep -q 'elsewhere/codex.toml' <<<"$fixture_copies" || fail "single-source check missed a re-commented TOML copy"

# The agent devcontainer installs from the image copy of that source.
grep -qx 'BAKED_CONFIG_DIR=/usr/local/share/devcontainer-config/agent' "$agent_autonomy" ||
    fail "agent-autonomy.sh no longer installs from the image copy of ${agent_config_dir}"
grep -Eq '^bash \.devcontainer/agent/agent-autonomy\.sh apply$' .devcontainer/agent/post-create.sh ||
    fail "the agent post-create does not install the agent profile (agent-autonomy.sh apply)"
grep -Eq '^bash \.devcontainer/agent/agent-autonomy\.sh verify$' .devcontainer/agent/post-start.sh ||
    fail "the agent post-start does not verify the agent profile (agent-autonomy.sh verify)"

# ── 2. Claude settings ──────────────────────────────────────────────────
echo "==> 2. agent Claude settings: auto mode, no bypass, no ask, the agreed deny list, never looser than bot"

[ "$(jq -r '.permissions.defaultMode' "$agent_settings")" = "auto" ] ||
    fail "agent Claude settings do not set permissions.defaultMode=auto (the prompt-free mode the ADR chose)"
[ "$(jq -r '.permissions.disableBypassPermissionsMode' "$agent_settings")" = "disable" ] ||
    fail "agent Claude settings do not set permissions.disableBypassPermissionsMode=disable"
[ "$(jq -r '.permissions.disableAutoMode // "unset"' "$agent_settings")" = "unset" ] ||
    fail "agent Claude settings set disableAutoMode — that would strand an unattended run"
[ "$(jq -r '.allowManagedPermissionRulesOnly' "$agent_settings")" = "true" ] ||
    fail "agent Claude settings do not set allowManagedPermissionRulesOnly — a repository's own ask rules would stall the run"
[ "$(jq '[.. | objects | select(has("ask")) | .ask[]?] | length' "$agent_settings")" = "0" ] ||
    fail "agent Claude settings contain an ask rule — an ask prompts in every mode and stalls an unattended run"
[ "$(jq -r '.skipDangerousModePermissionPrompt // "unset"' "$agent_settings")" = "unset" ] ||
    fail "agent Claude settings carry the bot's skipDangerousModePermissionPrompt"

required_deny='Bash(gh release *)
Bash(gh repo delete *)
Bash(gh repo edit *)
Bash(gh repo rename *)
Bash(gh secret *)
Bash(gh variable set *)
Bash(gh variable delete *)
Bash(gh workflow run *)
Bash(gh workflow enable *)
Bash(gh workflow disable *)
Bash(gh api)
Bash(gh api *)
Bash(git push --force*)
Bash(git push * --force*)
Bash(git push -f*)
Bash(git push * -f*)
Bash(git push * +*)
Bash(git push * main)
Bash(git push * *:main)
Bash(task release*)
Bash(task secret*)
Bash(task codex:gate:disable*)
Bash(op)
Bash(op *)
Read(**/.env*)
Read(!**/.env.example)'
agent_deny="$(jq -r '.permissions.deny[]' "$agent_settings")"
while IFS= read -r rule; do
    grep -Fxq -- "$rule" <<<"$agent_deny" || fail "agent Claude deny list is missing the agreed rule '${rule}'"
done <<<"$required_deny"
# gitignore negation only carves out of rules listed BEFORE it.
[ "$(jq -r '.permissions.deny | last' "$agent_settings")" = "Read(!**/.env.example)" ] ||
    fail "the .env.example carve-out must be the last deny rule (a negation only applies to rules before it)"
# The agent posture carries no merge guard: `gh pr merge` is explicitly
# allowed so auto mode never stalls a merge, and the "Protect Main" ruleset
# (code-owner approval + green checks) is the boundary.
[ "$(jq '[.permissions.deny[] | select(test("^Bash\\(gh pr merge"))] | length' "$agent_settings")" = "0" ] ||
    fail "agent Claude settings deny gh pr merge — the agent posture carries no merge guard (the ruleset is the boundary)"
# Both forms: `Bash(gh pr merge *)` needs an argument, so the bare
# `gh pr merge` on the current branch's PR needs its own rule.
jq -e '.permissions.allow | (index("Bash(gh pr merge)") != null) and (index("Bash(gh pr merge *)") != null)' "$agent_settings" >/dev/null ||
    fail "agent Claude settings do not explicitly allow both Bash(gh pr merge) and Bash(gh pr merge *) — auto mode could stall an agent merge"
# The posture marker travels with the managed settings, not only the
# devcontainer's containerEnv: a remote or platform-VM agent session sets it
# nowhere else, and git-merge-guard reads it to make no merge checks there.
jq -e '.env.FOREMAN_DEVCONTAINER == "agent"' "$agent_settings" >/dev/null ||
    fail "agent Claude settings do not set env.FOREMAN_DEVCONTAINER=agent — remote agent sessions would still get git-merge-guard prompts"

# rule_prefix <rule> — the literal command prefix a Bash(...) rule matches:
# `Bash(git:*)` (legacy) and `Bash(git status *)` both reduce to the words
# before the wildcard. Non-Bash rules print nothing.
rule_prefix() {
    local spec
    case "$1" in
    Bash\(*\)) spec="${1#Bash(}" && spec="${spec%)}" ;;
    *) return 0 ;;
    esac
    spec="${spec%%\**}"
    spec="${spec%:}"
    spec="${spec% }"
    printf '%s' "$spec"
}

# prefix_covers <broad> <narrow> — broad matches everything narrow does:
# same words, or narrow extends broad at a word boundary.
prefix_covers() {
    [ -n "$1" ] || return 1
    [ "$2" = "$1" ] && return 0
    case "$2" in "$1 "*) return 0 ;; esac
    return 1
}

# check_never_looser <agent-settings> <bot-settings> — print every agent allow
# rule that a bot deny rule covers, or that no bot allow rule covers.
check_never_looser() {
    local a b ap bp covered
    while IFS= read -r a; do
        ap="$(rule_prefix "$a")"
        # The pinned GET wrapper only performs a subset of bot's gh api grant.
        [ "$ap" != "/usr/local/bin/gh-api-read" ] || ap="gh api"
        [ -n "$ap" ] || {
            printf 'non-Bash allow rule %s (bot allows no such tool rule)\n' "$a"
            continue
        }
        while IFS= read -r b; do
            [ -n "$b" ] || continue
            bp="$(rule_prefix "$b")"
            if prefix_covers "$bp" "$ap" || prefix_covers "$ap" "$bp"; then
                printf 'agent allows %s, which bot denies (%s)\n' "$a" "$b"
            fi
        done < <(jq -r '.permissions.deny // [] | .[]' "$2")
        covered=0
        while IFS= read -r b; do
            prefix_covers "$(rule_prefix "$b")" "$ap" && covered=1 && break
        done < <(jq -r '.permissions.allow // [] | .[]' "$2")
        [ "$covered" -eq 1 ] || printf 'agent allows %s, which bot does not allow\n' "$a"
    done < <(jq -r '.permissions.allow[]' "$1")
}

# Both settings twins must refuse raw API commands, including bundled flags.
for settings in "$agent_settings" 'template/[% if devcontainer %].devcontainer[% endif %]/config/agent/claude-managed-settings.json'; do
    # Generated repositories have only their root copy.
    [ -f "$settings" ] || continue
    jq -e '.permissions.deny | (index("Bash(gh api)") != null) and (index("Bash(gh api *)") != null)' "$settings" >/dev/null ||
        fail "$settings does not blanket-deny raw gh api"
    jq -e '.permissions.allow | index("Bash(/usr/local/bin/gh-api-read *)") != null' "$settings" >/dev/null ||
        fail "$settings does not allow the installed GET wrapper"
    while IFS= read -r rule; do
        prefix="$(rule_prefix "$rule")"
        if prefix_covers "$prefix" 'gh api' || prefix_covers 'gh api' "$prefix"; then
            fail "$settings allows raw gh api through $rule"
        fi
    done < <(jq -r '.permissions.allow[]' "$settings")
done

# Run only a recording stub; no network request or real GitHub mutation.
wrapper_bin="${work_dir}/wrapper-bin"
mkdir -p "$wrapper_bin"
cat >"${wrapper_bin}/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$GH_API_READ_LOG"
STUB
chmod +x "${wrapper_bin}/gh"
wrapper_log="${work_dir}/wrapper.args"
run_wrapper() {
    local wrapper="$1"
    shift
    PATH="${wrapper_bin}:$PATH" GH_API_READ_LOG="$wrapper_log" bash "$wrapper" "$@"
}
shipped_wrapper="${agent_config_dir}/gh-api-read"
# Keep the production PATH pin in the probe; change only the API invocation
# to --version so the system gh is exercised without a request or credentials.
grep -qx 'export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' "$shipped_wrapper" ||
    fail "GET wrapper does not pin the system PATH"
# The interpreter itself must not be looked up on the caller's PATH.
[ "$(head -n 1 "$shipped_wrapper")" = '#!/bin/bash' ] ||
    fail "GET wrapper resolves its interpreter through PATH"
# The live probe needs a gh in one of the pinned directories, as the agent
# posture's images have. A host without one (no gh, or Homebrew's
# /opt/homebrew/bin on macOS) skips it; the static assertions above still run.
system_gh=
for dir in /usr/local/sbin /usr/local/bin /usr/sbin /usr/bin /sbin /bin; do
    if [ -x "${dir}/gh" ]; then
        system_gh="${dir}/gh"
        break
    fi
done
if [ -n "$system_gh" ]; then
    sed 's/exec gh api --method GET "$@" "$endpoint"/exec gh --version/' "$shipped_wrapper" >"${work_dir}/wrapper-path-probe"
    rm -f "$wrapper_log"
    run_wrapper "${work_dir}/wrapper-path-probe" repos/example/repo >"${work_dir}/wrapper-path.out" ||
        fail "system gh PATH probe failed"
    [ ! -e "$wrapper_log" ] || fail "GET wrapper ran the fake gh first on the caller PATH"
    grep -q '^gh version ' "${work_dir}/wrapper-path.out" || fail "GET wrapper did not run the system gh"
else
    echo "NOTE: no gh in the wrapper's pinned PATH on this host; skipping the live PATH probe"
fi
# Only the argument-contract fixture replaces the PATH pin with the recording
# stub's directory. No production file or system executable is changed.
wrapper="${work_dir}/wrapper-with-stub"
sed "s|^export PATH=.*|export PATH=${wrapper_bin}:$PATH|" "$shipped_wrapper" >"$wrapper"
# This contract refuses any implementation that does not pin the outgoing GET.
wrapper_contract() {
    run_wrapper "$1" 'repos/example/repo?per_page=100' --paginate --jq '.items[]' || return 1
    printf '%s\n' api --method GET --paginate --jq '.items[]' 'repos/example/repo?per_page=100' >"${work_dir}/wrapper.expected"
    cmp -s "$wrapper_log" "${work_dir}/wrapper.expected"
}
wrapper_contract "$wrapper" || fail "GET wrapper did not forward exactly the vetted arguments with GET pinned"
run_wrapper "$wrapper" repos/example/repo --slurp -i --silent -q '.id' || fail "GET wrapper refused allowed output flags"
run_wrapper "$wrapper" repos/example/repo --include --jq=.id || fail "GET wrapper refused include/jq equals flags"
refuses_wrapper() {
    rm -f "$wrapper_log"
    local status=0
    run_wrapper "$wrapper" "$@" >"${work_dir}/wrapper.out" 2>&1 || status=$?
    [ "$status" -eq 2 ] || fail "GET wrapper did not refuse: $* (exit $status)"
    [ ! -e "$wrapper_log" ] || fail "GET wrapper invoked gh for refused arguments: $*"
}
refuses_wrapper repos/example/repo -X POST
refuses_wrapper repos/example/repo -XPOST
refuses_wrapper repos/example/repo -iXPOST
refuses_wrapper repos/example/repo --method=PATCH
refuses_wrapper repos/example/repo --method GET
refuses_wrapper repos/example/repo -f a=b
refuses_wrapper repos/example/repo -if a=b
refuses_wrapper repos/example/repo -F a=b
refuses_wrapper repos/example/repo --field a=b
refuses_wrapper repos/example/repo --raw-field=a=b
refuses_wrapper repos/example/repo --input payload.json
refuses_wrapper graphql
refuses_wrapper /GraphQL?query=x
refuses_wrapper repos/example/repo -H 'X-HTTP-Method-Override: POST'
refuses_wrapper repos/example/repo --header='X-HTTP-Method-Override: POST'
refuses_wrapper repos/example/repo --unknown
refuses_wrapper repos/example/repo repos/example/other
refuses_wrapper https://example.invalid/path
refuses_wrapper repos/example/repo --jq
refuses_wrapper
# Mutation proof uses a scratch copy only: the outgoing-method contract must
# reject it. Argument refusals are independently checked above.
sed 's/exec gh api --method GET/exec gh api/' "$wrapper" >"${work_dir}/wrapper-unpinned"
if wrapper_contract "${work_dir}/wrapper-unpinned"; then
    fail "GET wrapper contract accepted the mutation with the method pin removed"
fi
echo "==> GET wrapper mutation rejected: method pin removed (scratch copy)"

looser="$(check_never_looser "$agent_settings" "$bot_settings")"
[ -z "$looser" ] || fail "agent Claude settings are looser than bot: ${looser}"

# Fixtures: a bot deny that covers an agent allow, and an agent allow bot
# never grants, are both reported.
jq '.permissions.deny = ["Bash(git push:*)"]' "$bot_settings" >"${work_dir}/bot-deny.json"
grep -q 'which bot denies' <<<"$(check_never_looser "$agent_settings" "${work_dir}/bot-deny.json")" ||
    fail "never-looser check missed an agent allow rule that bot denies"
jq '.permissions.allow += ["Bash(curl *)"]' "$agent_settings" >"${work_dir}/agent-wider.json"
grep -q 'Bash(curl \*), which bot does not allow' <<<"$(check_never_looser "${work_dir}/agent-wider.json" "$bot_settings")" ||
    fail "never-looser check missed an agent allow rule bot does not grant"

# ── 3. Codex config ─────────────────────────────────────────────────────
echo "==> 3. agent Codex config: workspace-write, never danger-full-access, parity with the baseline"

! grep -q 'danger-full-access' <(grep -Ev '^[[:space:]]*#' "$agent_codex") ||
    fail "agent Codex config enables danger-full-access"
grep -Eq '^sandbox_mode = "workspace-write"$' "$agent_codex" || fail "agent Codex sandbox_mode is not workspace-write"
grep -Eq '^approval_policy = "never"$' "$agent_codex" || fail "agent Codex approval_policy is not never (an unattended run cannot answer a prompt)"

# Every line but approval_policy and the [sandbox_workspace_write] table must
# match the shared baseline — the same structural parity bot's config keeps.
strip_agent_overrides() {
    grep -Ev '^[[:space:]]*#' "$1" |
        grep -Ev '^[[:space:]]*$' |
        grep -Ev '^[[:space:]]*approval_policy[[:space:]]*=' |
        grep -Ev '^\[sandbox_workspace_write\]$' |
        grep -Ev '^[[:space:]]*network_access[[:space:]]*='
}
diff <(strip_agent_overrides "$codex_baseline") <(strip_agent_overrides "$agent_codex") >/dev/null ||
    fail "agent Codex config diverges from ${codex_baseline} beyond approval_policy and [sandbox_workspace_write]"
sed 's/^approvals_reviewer = .*/approvals_reviewer = "user"/' "$agent_codex" >"${work_dir}/codex-drift.toml"
if diff <(strip_agent_overrides "$codex_baseline") <(strip_agent_overrides "${work_dir}/codex-drift.toml") >/dev/null; then
    fail "Codex parity check failed to notice a divergent approvals_reviewer"
fi

# ── 4. Harness refusal ──────────────────────────────────────────────────
echo "==> 4. harness coverage, and refusal outside and under the agent marker"

AGENT_AUTONOMY_CONFIG_DIR="${repo_root}/${agent_config_dir}" bash "$agent_autonomy" coverage >/dev/null || fail "agent-autonomy.sh coverage failed (run it for the details)"

# The dispatcher needs only these tools; a curated PATH keeps the real
# harness binaries this environment may have installed out of the fixture.
# curated_bin <dir> <tool>... — link each tool this machine has into <dir>.
autonomy_tools="bash awk jq install chmod readlink dirname git mktemp cat sudo"
curated_bin() {
    local dir="$1" tool tool_path
    shift
    mkdir -p "$dir"
    for tool in "$@"; do
        tool_path="$(command -v "$tool" 2>/dev/null || true)"
        [ -n "$tool_path" ] || continue
        ln -s "$tool_path" "${dir}/${tool}"
    done
}
safe_bin="${work_dir}/safe-bin"
# shellcheck disable=SC2086 # the tool list is split on purpose
curated_bin "$safe_bin" $autonomy_tools sha256sum shasum
fake_bin="${work_dir}/fake-bin"
mkdir -p "$fake_bin"
for exe in claude codex opencode agy; do
    printf '#!/bin/sh\nexit 0\n' >"${fake_bin}/${exe}"
    chmod +x "${fake_bin}/${exe}"
done
fake_etc="${work_dir}/etc"
mkdir -p "${fake_etc}/claude-code" "${fake_etc}/codex"
echo '{}' >"${fake_etc}/claude-code/managed-settings.json"
# run_autonomy <subcommand> — the unit test's opt-in to the checkout's profile
# (AGENT_AUTONOMY_CONFIG_DIR) and scratch destinations; PATH is
# ${autonomy_path}, the fake harnesses plus the curated tools unless a case
# below narrows it.
autonomy_path="${fake_bin}:${safe_bin}"
run_autonomy() {
    AGENT_AUTONOMY_CONFIG_DIR="${repo_root}/${agent_config_dir}" \
        AGENT_AUTONOMY_REGISTRY="${repo_root}/agent-registry.json" \
        AGENT_AUTONOMY_CLAUDE_MANAGED="${fake_etc}/claude-code/managed-settings.json" \
        AGENT_AUTONOMY_CODEX_MANAGED="${fake_etc}/codex/managed_config.toml" \
        AGENT_AUTONOMY_GH_API_READ="${fake_etc}/gh-api-read" \
        PATH="$autonomy_path" "$BASH" "$agent_autonomy" "$@"
}

if FOREMAN_DEVCONTAINER=bot run_autonomy apply >/dev/null 2>&1; then
    fail "agent-autonomy.sh apply ran outside the agent posture (FOREMAN_DEVCONTAINER=bot)"
fi
if FOREMAN_DEVCONTAINER="" run_autonomy verify >/dev/null 2>&1; then
    fail "agent-autonomy.sh verify ran outside the agent posture (FOREMAN_DEVCONTAINER unset)"
fi
[ -x "${fake_bin}/opencode" ] || fail "agent-autonomy.sh touched a harness outside the agent posture"

FOREMAN_DEVCONTAINER=agent run_autonomy apply >/dev/null || fail "agent-autonomy.sh apply failed under the agent marker"
cmp -s "$agent_settings" "${fake_etc}/claude-code/managed-settings.json" || fail "apply did not install the agent Claude settings"
cmp -s "$agent_codex" "${fake_etc}/codex/managed_config.toml" || fail "apply did not install the agent Codex config"
cmp -s "$shipped_wrapper" "${fake_etc}/gh-api-read" && [ -x "${fake_etc}/gh-api-read" ] || fail "apply did not install the executable GET wrapper"
[ ! -x "${fake_bin}/opencode" ] || fail "apply did not refuse opencode (no agent-capable configuration)"
[ ! -x "${fake_bin}/agy" ] || fail "apply did not refuse agy (no agent-capable configuration)"
[ -x "${fake_bin}/claude" ] && [ -x "${fake_bin}/codex" ] || fail "apply refused an agent-capable harness"
FOREMAN_DEVCONTAINER=agent run_autonomy verify >/dev/null || fail "verify failed right after apply"
chmod -x "${fake_etc}/gh-api-read"
if FOREMAN_DEVCONTAINER=agent run_autonomy verify >/dev/null 2>&1; then
    fail "verify passed with a non-executable GET wrapper"
fi
FOREMAN_DEVCONTAINER=agent run_autonomy apply >/dev/null || fail "apply did not repair GET wrapper mode"
printf "# drift\n" >>"${fake_etc}/gh-api-read"
if FOREMAN_DEVCONTAINER=agent run_autonomy verify >/dev/null 2>&1; then
    fail "verify passed with a drifted GET wrapper"
fi
FOREMAN_DEVCONTAINER=agent run_autonomy apply >/dev/null || fail "apply did not repair GET wrapper bytes"

# The platform-VM seam (`--platform-vm`, passed only by the remote bootstrap) is
# an ARGUMENT: an environment variable of the same meaning — the variable this
# seam briefly was — must change nothing, because a devcontainer.json
# containerEnv entry could set it for the agent devcontainer's own lifecycle.
# Neither lifecycle hook may pass the flag.
chmod +x "${fake_bin}/opencode"
AGENT_AUTONOMY_SKIP_HARNESS_REFUSAL=1 FOREMAN_DEVCONTAINER=agent run_autonomy apply >/dev/null ||
    fail "apply failed with AGENT_AUTONOMY_SKIP_HARNESS_REFUSAL=1 in the environment"
[ ! -x "${fake_bin}/opencode" ] ||
    fail "apply skipped harness refusal because of an environment variable — only --platform-vm may skip it"
chmod +x "${fake_bin}/opencode"
if AGENT_AUTONOMY_SKIP_HARNESS_REFUSAL=1 FOREMAN_DEVCONTAINER=agent run_autonomy verify >/dev/null 2>&1; then
    fail "verify skipped the refused-harness check because of an environment variable — only --platform-vm may skip it"
fi
chmod -x "${fake_bin}/opencode"
for hook in .devcontainer/agent/post-create.sh .devcontainer/agent/post-start.sh; do
    ! grep -q -- '--platform-vm' "$hook" ||
        fail "${hook} passes --platform-vm: the agent devcontainer must always refuse harnesses"
done

chmod +x "${fake_bin}/opencode"
if FOREMAN_DEVCONTAINER=agent run_autonomy verify >/dev/null 2>&1; then
    fail "verify passed with a refused harness (opencode) executable again"
fi
chmod -x "${fake_bin}/opencode"
echo '{"permissions":{"defaultMode":"bypassPermissions"}}' >"${fake_etc}/claude-code/managed-settings.json"
if FOREMAN_DEVCONTAINER=agent run_autonomy verify >/dev/null 2>&1; then
    fail "verify passed with drifted Claude managed settings"
fi

# The digest is never empty. A PATH with shasum but no sha256sum (a stock
# macOS host) installs and verifies; a tampered installed file still fails
# there. A PATH with neither fails apply and verify loudly — never two empty
# digests comparing equal. Where this machine has no shasum, a shim over
# sha256sum stands in for it.
shasum_bin="${work_dir}/shasum-bin"
# shellcheck disable=SC2086 # the tool list is split on purpose
curated_bin "$shasum_bin" $autonomy_tools shasum
if [ ! -e "${shasum_bin}/shasum" ]; then
    printf '#!/bin/sh\n[ "$1" = -a ] && [ "$2" = 256 ] || exit 2\nshift 2\nexec %s "$@"\n' "$(command -v sha256sum)" >"${shasum_bin}/shasum"
    chmod +x "${shasum_bin}/shasum"
fi
nodigest_bin="${work_dir}/nodigest-bin"
# shellcheck disable=SC2086 # the tool list is split on purpose
curated_bin "$nodigest_bin" $autonomy_tools
chmod +x "${fake_bin}/opencode" "${fake_bin}/agy"
rm -f "${fake_etc}/codex/managed_config.toml"
echo '{}' >"${fake_etc}/claude-code/managed-settings.json"
autonomy_path="${fake_bin}:${shasum_bin}"
FOREMAN_DEVCONTAINER=agent run_autonomy apply >/dev/null || fail "apply failed with shasum but no sha256sum on PATH"
cmp -s "$agent_settings" "${fake_etc}/claude-code/managed-settings.json" ||
    fail "apply with shasum but no sha256sum did not install the agent Claude settings over a drifted file"
cmp -s "$agent_codex" "${fake_etc}/codex/managed_config.toml" ||
    fail "apply with shasum but no sha256sum did not install the agent Codex config"
FOREMAN_DEVCONTAINER=agent run_autonomy verify >/dev/null || fail "verify failed with shasum but no sha256sum on PATH"
printf '\n# tampered\n' >>"${fake_etc}/codex/managed_config.toml"
if FOREMAN_DEVCONTAINER=agent run_autonomy verify >/dev/null 2>&1; then
    fail "verify passed a tampered Codex managed config with shasum but no sha256sum on PATH"
fi
autonomy_path="${fake_bin}:${nodigest_bin}"
for sub in apply verify; do
    if digest_out="$(FOREMAN_DEVCONTAINER=agent run_autonomy "$sub" 2>&1)"; then
        fail "${sub} succeeded with neither sha256sum nor shasum on PATH"
    fi
    grep -Fq 'neither sha256sum nor shasum' <<<"$digest_out" ||
        fail "${sub} with neither sha256sum nor shasum did not say why it failed: ${digest_out}"
done
autonomy_path="${fake_bin}:${safe_bin}"

# A refused harness reached through a (relative) symlink: the link's target
# is what loses its execute bit.
link_bin="${work_dir}/link-bin"
mkdir -p "$link_bin" "${work_dir}/opt/copilot"
printf '#!/bin/sh\nexit 0\n' >"${work_dir}/opt/copilot/copilot-real"
chmod +x "${work_dir}/opt/copilot/copilot-real"
ln -s ../opt/copilot/copilot-real "${link_bin}/copilot"
autonomy_path="${link_bin}:${fake_bin}:${safe_bin}"
FOREMAN_DEVCONTAINER=agent run_autonomy apply >/dev/null || fail "apply failed over a symlinked refused harness"
[ ! -x "${work_dir}/opt/copilot/copilot-real" ] || fail "apply did not refuse the target of a symlinked refused harness (copilot)"
FOREMAN_DEVCONTAINER=agent run_autonomy verify >/dev/null || fail "verify failed after refusing a symlinked harness"
autonomy_path="${fake_bin}:${safe_bin}"

# Under the agent marker the profile comes only from the baked image copy,
# never from the writable checkout beside the script. A copy of the script
# with the baked path moved into scratch shows both sides: baked copy missing
# fails (though a checkout profile sits beside it), baked copy present wins
# over an edited checkout copy, and without the marker the checkout is still
# read (the static coverage check).
baked_tree="${work_dir}/baked-tree"
mkdir -p "${baked_tree}/.devcontainer/agent" "${baked_tree}/.devcontainer/config/agent"
cp "${agent_config_dir}/"* "${baked_tree}/.devcontainer/config/agent/"
jq '.permissions.defaultMode = "bypassPermissions"' "$agent_settings" >"${baked_tree}/.devcontainer/config/agent/claude-managed-settings.json"
sed "s|/usr/local/share/devcontainer-config/agent|${work_dir}/baked-image|g" "$agent_autonomy" >"${baked_tree}/.devcontainer/agent/agent-autonomy.sh"
run_baked() {
    AGENT_AUTONOMY_REGISTRY="${repo_root}/agent-registry.json" \
        AGENT_AUTONOMY_CLAUDE_MANAGED="${fake_etc}/claude-code/managed-settings.json" \
        AGENT_AUTONOMY_CODEX_MANAGED="${fake_etc}/codex/managed_config.toml" \
        AGENT_AUTONOMY_GH_API_READ="${fake_etc}/gh-api-read" \
        PATH="${fake_bin}:${safe_bin}" "$BASH" "${baked_tree}/.devcontainer/agent/agent-autonomy.sh" "$@"
}
echo '{}' >"${fake_etc}/claude-code/managed-settings.json"
for sub in apply verify; do
    if baked_out="$(FOREMAN_DEVCONTAINER=agent run_baked "$sub" 2>&1)"; then
        fail "${sub} under the agent marker read the checkout's profile when the baked copy was missing"
    fi
    grep -Fq "the baked agent profile ${work_dir}/baked-image is missing" <<<"$baked_out" ||
        fail "${sub} under the agent marker with no baked profile did not say why it failed: ${baked_out}"
done
grep -qx '{}' "${fake_etc}/claude-code/managed-settings.json" ||
    fail "apply installed the checkout's profile when the baked copy was missing"
AGENT_AUTONOMY_REGISTRY="${repo_root}/agent-registry.json" bash "${baked_tree}/.devcontainer/agent/agent-autonomy.sh" coverage >/dev/null ||
    fail "coverage without the agent marker no longer reads the checkout's profile"
mkdir -p "${work_dir}/baked-image"
cp "${agent_config_dir}/"* "${work_dir}/baked-image/"
FOREMAN_DEVCONTAINER=agent run_baked apply >/dev/null || fail "apply under the agent marker failed with the baked profile present"
cmp -s "$agent_settings" "${fake_etc}/claude-code/managed-settings.json" ||
    fail "apply under the agent marker installed the checkout's edited profile instead of the baked one"
FOREMAN_DEVCONTAINER=agent run_baked verify >/dev/null || fail "verify under the agent marker failed against the baked profile"

# A registry slug with no bucket fails coverage.
jq '.harnesses += [{slug: "brand-new-harness"}]' agent-registry.json >"${work_dir}/registry-new.json"
if AGENT_AUTONOMY_CONFIG_DIR="${repo_root}/${agent_config_dir}" AGENT_AUTONOMY_REGISTRY="${work_dir}/registry-new.json" bash "$agent_autonomy" coverage >/dev/null 2>&1; then
    fail "coverage passed with a registry slug that is neither supported, aliased, nor refused"
fi

# ── 5. Env allowlist ────────────────────────────────────────────────────
echo "==> 5. init-env.sh --profile agent admits the agent PAT and fails closed on everything else"

env_dir="${work_dir}/env"
mkdir -p "$env_dir"
git -C "$env_dir" init -q
# Host env carries the bot's and operator's credentials too; only the agent's
# may land in the file.
(cd "$env_dir" && env -i PATH="$PATH" HOME="$env_dir" AGENT_GH_TOKEN=agent-pat \
    CLAUDE_CODE_OAUTH_TOKEN=oauth GH_TOKEN=bot-pat FOREMAN_AGENT_GH_TOKEN=foreman-pat \
    TS_AUTHKEY=ts OP_SERVICE_ACCOUNT_TOKEN=op ANTHROPIC_API_KEY=anthropic \
    bash "${repo_root}/${init_env}" --profile agent agent.env AGENT_GH_TOKEN CLAUDE_CODE_OAUTH_TOKEN) >/dev/null 2>&1 ||
    fail "init-env.sh --profile agent failed on a clean allow-list"
grep -qx 'AGENT_GH_TOKEN=agent-pat' "${env_dir}/agent.env" || fail "the agent env-file did not admit AGENT_GH_TOKEN"
for leaked in GH_TOKEN FOREMAN_AGENT_GH_TOKEN TS_AUTHKEY OP_SERVICE_ACCOUNT_TOKEN ANTHROPIC_API_KEY; do
    ! grep -q "^${leaked}=" "${env_dir}/agent.env" || fail "the agent env-file admitted ${leaked}"
done

for forbidden in GH_TOKEN FOREMAN_AGENT_GH_TOKEN TS_AUTHKEY OP_SERVICE_ACCOUNT_TOKEN ANTHROPIC_API_KEY AGENT_DECK_TELEGRAM_KEY; do
    rm -f "${env_dir}/guard.env"
    if (cd "$env_dir" && env -i PATH="$PATH" HOME="$env_dir" \
        bash "${repo_root}/${init_env}" --profile agent guard.env AGENT_GH_TOKEN "$forbidden") >/dev/null 2>&1; then
        fail "init-env.sh --profile agent accepted ${forbidden} on its allow-list"
    fi
    [ ! -e "${env_dir}/guard.env" ] || fail "init-env.sh wrote the env-file before failing closed on ${forbidden}"
    printf '%s=stale\n' "$forbidden" >"${env_dir}/stale.env"
    if (cd "$env_dir" && env -i PATH="$PATH" HOME="$env_dir" \
        bash "${repo_root}/${init_env}" --profile agent stale.env AGENT_GH_TOKEN) >/dev/null 2>&1; then
        fail "init-env.sh --profile agent accepted an env-file already holding ${forbidden}"
    fi
    grep -qx "${forbidden}=stale" "${env_dir}/stale.env" || fail "init-env.sh rewrote the env-file while failing closed on ${forbidden}"
done
# A bare NAME line makes Docker pass the host's value through.
printf 'GH_TOKEN\n' >"${env_dir}/bare.env"
if (cd "$env_dir" && env -i PATH="$PATH" HOME="$env_dir" \
    bash "${repo_root}/${init_env}" --profile agent bare.env AGENT_GH_TOKEN) >/dev/null 2>&1; then
    fail "init-env.sh --profile agent accepted a bare pass-through line"
fi
# Failure messages carry names, never values.
printf 'GH_TOKEN=super-secret-value\n' >"${env_dir}/value.env"
value_out="$(cd "$env_dir" && env -i PATH="$PATH" HOME="$env_dir" \
    bash "${repo_root}/${init_env}" --profile agent value.env AGENT_GH_TOKEN 2>&1 || true)"
! grep -q 'super-secret-value' <<<"$value_out" || fail "init-env.sh printed a secret value while failing closed"
# The agent profile needs its env-file named: it never falls back to the
# bot's .devcontainer/devcontainer.env.
mkdir -p "${env_dir}/.devcontainer"
noenv_out="$(cd "$env_dir" && env -i PATH="$PATH" HOME="$env_dir" AGENT_GH_TOKEN=agent-pat \
    bash "${repo_root}/${init_env}" --profile agent 2>&1)" &&
    fail "init-env.sh --profile agent ran with no env-file path"
grep -Fq -- '--profile agent needs the agent env-file path' <<<"$noenv_out" ||
    fail "init-env.sh --profile agent with no env-file path did not say why it failed: ${noenv_out}"
[ ! -e "${env_dir}/.devcontainer/devcontainer.env" ] ||
    fail "init-env.sh --profile agent with no env-file path wrote the bot's env-file"
# The bot and dev profiles evict the agent PAT.
printf 'AGENT_GH_TOKEN=agent-pat\nGH_TOKEN=bot\n' >"${env_dir}/bot.env"
(cd "$env_dir" && env -i PATH="$PATH" HOME="$env_dir" bash "${repo_root}/${init_env}" bot.env GH_TOKEN) >/dev/null 2>&1 ||
    fail "init-env.sh failed for the bot allow-list"
! grep -q '^AGENT_GH_TOKEN=' "${env_dir}/bot.env" || fail "the bot env-file kept AGENT_GH_TOKEN"

# The agent devcontainer invokes that mode, with admissible names only, and
# carries no 1Password or Tailscale.
agent_cfg="$(jsonc_to_json "$agent_dc")"
init_cmd="$(jq -r '.initializeCommand' <<<"$agent_cfg")"
case "$init_cmd" in
"bash .devcontainer/scripts/init-env.sh --profile agent .devcontainer/agent/devcontainer.env "*) ;;
*) fail "the agent initializeCommand does not run init-env.sh --profile agent on the agent env-file: ${init_cmd}" ;;
esac
admissible=" AGENT_GH_TOKEN CLAUDE_CODE_OAUTH_TOKEN KIMI_API_KEY MOONSHOT_API_KEY DEEPSEEK_API_KEY ZAI_API_KEY QWEN_API_KEY "
for name in ${init_cmd#bash .devcontainer/scripts/init-env.sh --profile agent .devcontainer/agent/devcontainer.env }; do
    case "$admissible" in
    *" ${name} "*) ;;
    *) fail "the agent initializeCommand allow-lists ${name}" ;;
    esac
done
[ "$(jq '[.features // {} | keys[] | select(test("1password|tailscale"; "i"))] | length' <<<"$agent_cfg")" = "0" ] ||
    fail "the agent devcontainer installs a 1Password or Tailscale feature"
[ "$(jq -r '.containerEnv.FOREMAN_DEVCONTAINER' <<<"$agent_cfg")" = "agent" ] ||
    fail "the agent devcontainer does not set containerEnv.FOREMAN_DEVCONTAINER=agent"
for alias_var in GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN; do
    [ "$(jq -r --arg v "$alias_var" '.containerEnv[$v] // "<absent>"' <<<"$agent_cfg")" = "" ] ||
        fail "the agent devcontainer does not blank ${alias_var} (an env token would outrank the agent login)"
done

# ── 6. Docker ───────────────────────────────────────────────────────────
echo "==> 6. no Docker socket, and Docker-in-Docker only with the documented opt-in"

# docker_violations <config-json> — print why a config breaks the Docker rule.
docker_violations() {
    local cfg="$1" dind marker
    if jq -e '[((.mounts // [])[] | tostring), (.runArgs // [])[]] | any(test("docker\\.sock"))' <<<"$cfg" >/dev/null; then
        echo "mounts the host Docker socket"
    fi
    if jq -e '[.features // {} | keys[] | select(test("docker-outside-of-docker|docker-from-docker"))] | length > 0' <<<"$cfg" >/dev/null; then
        echo "uses a docker-outside-of-docker feature (the host daemon)"
    fi
    dind="$(jq '[.features // {} | keys[] | select(test("docker-in-docker"))] | length' <<<"$cfg")"
    marker="$(jq -r '.containerEnv.HARMON_AGENT_DOCKER // ""' <<<"$cfg")"
    if [ "$dind" != "0" ] && [ "$marker" != "dind" ]; then
        echo "installs Docker-in-Docker without the HARMON_AGENT_DOCKER=dind opt-in marker"
    fi
    if [ "$dind" = "0" ] && [ -n "$marker" ]; then
        echo "sets HARMON_AGENT_DOCKER='${marker}' without the Docker-in-Docker feature"
    fi
}
violations="$(docker_violations "$agent_cfg")"
[ -z "$violations" ] || fail "the agent devcontainer ${violations}"
grep -q 'HARMON_AGENT_DOCKER' "$devcontainers_guide" ||
    fail "${devcontainers_guide} does not document the agent Docker-in-Docker opt-in (HARMON_AGENT_DOCKER)"

dind_cfg="$(jq '.features["ghcr.io/devcontainers/features/docker-in-docker:2"] = {}' <<<"$agent_cfg")"
grep -q 'without the HARMON_AGENT_DOCKER=dind opt-in' <<<"$(docker_violations "$dind_cfg")" ||
    fail "Docker check missed Docker-in-Docker without the opt-in"
[ -z "$(docker_violations "$(jq '.containerEnv.HARMON_AGENT_DOCKER = "dind"' <<<"$dind_cfg")")" ] ||
    fail "Docker check rejected the documented Docker-in-Docker opt-in"
sock_cfg="$(jq '.mounts += ["source=/var/run/docker.sock,target=/var/run/docker.sock,type=bind"] | .containerEnv.HARMON_AGENT_DOCKER = "dind"' <<<"$dind_cfg")"
grep -q 'host Docker socket' <<<"$(docker_violations "$sock_cfg")" ||
    fail "Docker check missed a host Docker socket mount (even with the opt-in)"

# ── 7. Egress ───────────────────────────────────────────────────────────
echo "==> 7. egress allowlist parses, resolves, refuses an allow-nothing filter or an over-broad literal or meta range, and is applied first from a root-owned snapshot"

bash "$egress" hosts >/dev/null || fail "the shared egress allowlist does not parse"
for required in @github-meta github.com api.github.com api.anthropic.com api.openai.com chatgpt.com registry.npmjs.org pypi.org files.pythonhosted.org; do
    grep -Fxq -- "$required" <(bash "$egress" hosts) || fail "the shared egress allowlist is missing ${required}"
done

stub_resolver="${work_dir}/resolve"
printf '#!/bin/sh\ncase "$1" in\n good.example) echo 192.0.2.10; echo 192.0.2.11 ;;\n *) exit 0 ;;\nesac\n' >"$stub_resolver"
chmod +x "$stub_resolver"
printf '{"git":["140.82.112.0/20","2a0a:a440::/29"],"web":["140.82.112.0/20"],"api":[],"packages":["185.199.108.0/22"]}\n' >"${work_dir}/meta.json"
printf '@github-meta\ngood.example # trailing comment\ndead.example\n198.51.100.0/24\n' >"${work_dir}/list.txt"
plan="$(EGRESS_ALLOWLIST_SHARED="${work_dir}/list.txt" EGRESS_ALLOWLIST_LOCAL=/nonexistent \
    EGRESS_RESOLVER="$stub_resolver" EGRESS_GITHUB_META_FILE="${work_dir}/meta.json" \
    bash "$egress" plan 2>/dev/null)" || fail "egress plan failed on a valid fixture"
expected_plan='140.82.112.0/20
185.199.108.0/22
192.0.2.10
192.0.2.11
198.51.100.0/24'
[ "$plan" = "$expected_plan" ] || fail "egress plan resolved the fixture wrong: ${plan}"

printf 'dead.example\n' >"${work_dir}/dead.txt"
if EGRESS_ALLOWLIST_SHARED="${work_dir}/dead.txt" EGRESS_ALLOWLIST_LOCAL=/nonexistent \
    EGRESS_RESOLVER="$stub_resolver" bash "$egress" plan >/dev/null 2>&1; then
    fail "egress plan accepted a list that resolves to nothing (it would deny all egress silently)"
fi
printf 'not a host!\n' >"${work_dir}/bad.txt"
if EGRESS_ALLOWLIST_SHARED="${work_dir}/bad.txt" EGRESS_ALLOWLIST_LOCAL=/nonexistent bash "$egress" hosts >/dev/null 2>&1; then
    fail "egress hosts accepted a malformed entry"
fi
printf 'extra.example\n' >"${work_dir}/local.txt"
grep -Fxq extra.example <(EGRESS_ALLOWLIST_SHARED="${work_dir}/list.txt" EGRESS_ALLOWLIST_LOCAL="${work_dir}/local.txt" bash "$egress" hosts) ||
    fail "egress hosts ignored the per-repo local list"

# An over-broad literal is one line that allows every destination: refused
# in either list, naming the line, and never reaching plan. A /16 (the
# widest allowed), a /24 and a bare address are accepted.
for broad in 0.0.0.0/0 0.0.0.0/8 0.0.0.0/32 0.0.0.0 10.0.0.0/8 128.0.0.0/1 172.16.0.0/12 192.0.0.0/15; do
    printf 'good.example\n%s\n' "$broad" >"${work_dir}/broad.txt"
    for which in shared local; do
        if [ "$which" = shared ]; then
            broad_out="$(EGRESS_ALLOWLIST_SHARED="${work_dir}/broad.txt" EGRESS_ALLOWLIST_LOCAL=/nonexistent \
                EGRESS_RESOLVER="$stub_resolver" bash "$egress" plan 2>&1)" &&
                fail "egress plan accepted the over-broad entry ${broad} in the shared list"
        else
            broad_out="$(EGRESS_ALLOWLIST_SHARED="${work_dir}/list.txt" EGRESS_ALLOWLIST_LOCAL="${work_dir}/broad.txt" \
                EGRESS_RESOLVER="$stub_resolver" EGRESS_GITHUB_META_FILE="${work_dir}/meta.json" bash "$egress" plan 2>&1)" &&
                fail "egress plan accepted the over-broad entry ${broad} in the local list"
        fi
        grep -Fq "broad.txt:2: '${broad}'" <<<"$broad_out" ||
            fail "the refusal of ${broad} (${which} list) does not name the line: ${broad_out}"
    done
done
# An octet above 255 matches the address pattern but is no address, and an
# octet with a leading zero is one a parser may read as octal — a different
# address: both refused with the file and line named, before either can reach
# iptables.
for bogus in 999.1.1.1 192.0.2.256 256.0.0.0/16 010.1.1.1 192.0.2.01 10.00.0.0/16; do
    printf 'good.example\n%s\n' "$bogus" >"${work_dir}/octet.txt"
    octet_out="$(EGRESS_ALLOWLIST_SHARED="${work_dir}/octet.txt" EGRESS_ALLOWLIST_LOCAL=/nonexistent \
        EGRESS_RESOLVER="$stub_resolver" bash "$egress" plan 2>&1)" &&
        fail "egress plan accepted the out-of-range address ${bogus}"
    grep -Fq "egress-allowlist: ${work_dir}/octet.txt:2: '${bogus}' has an octet above 255 or with a leading zero" <<<"$octet_out" ||
        fail "the refusal of the out-of-range address ${bogus} does not name the file and line: ${octet_out}"
done
printf '172.16.0.0/16\n198.51.100.0/24\n203.0.113.7/32\n203.0.113.8\n10.0.0.1\n' >"${work_dir}/narrow.txt"
[ "$(EGRESS_ALLOWLIST_SHARED="${work_dir}/narrow.txt" EGRESS_ALLOWLIST_LOCAL=/nonexistent bash "$egress" plan 2>/dev/null)" = "$(printf '10.0.0.1\n172.16.0.0/16\n198.51.100.0/24\n203.0.113.7/32\n203.0.113.8')" ] ||
    fail "egress plan refused or altered a /16, /24, /32 or bare-address entry (a lone 0 octet included)"

# A range fetched through @github-meta becomes a rule unreviewed, so it gets
# the same refusal: a meta response carrying 0.0.0.0/0 or a /8 fails the plan
# (and so apply), naming the source and the range, instead of being skipped.
printf '@github-meta\n' >"${work_dir}/meta-only.txt"
for broad in 0.0.0.0/0 10.0.0.0/8; do
    printf '{"git":["140.82.112.0/20"],"web":["%s"],"api":[],"packages":["185.199.108.0/22"]}\n' "$broad" >"${work_dir}/meta-broad.json"
    broad_out="$(EGRESS_ALLOWLIST_SHARED="${work_dir}/meta-only.txt" EGRESS_ALLOWLIST_LOCAL=/nonexistent \
        EGRESS_GITHUB_META_FILE="${work_dir}/meta-broad.json" bash "$egress" plan 2>&1)" &&
        fail "egress plan accepted the over-broad @github-meta range ${broad}"
    grep -Fq "@github-meta: '${broad}'" <<<"$broad_out" ||
        fail "the refusal of the @github-meta range ${broad} does not name its source and range: ${broad_out}"
done
[ "$(EGRESS_ALLOWLIST_SHARED="${work_dir}/meta-only.txt" EGRESS_ALLOWLIST_LOCAL=/nonexistent \
    EGRESS_GITHUB_META_FILE="${work_dir}/meta.json" bash "$egress" plan 2>/dev/null)" = "$(printf '140.82.112.0/20\n185.199.108.0/22')" ] ||
    fail "egress plan refused or altered a normal @github-meta response"

# Apply fails closed: every exit short of a verified filter leaves the OUTPUT
# and FORWARD policies DROP. Stub `id` (so apply runs as "root" without sudo)
# and iptables/ip6tables (which record each call instead of executing it) on
# PATH; the -S answers are what a fully installed filter reports, so the
# success run reaches verify and passes.
ipt_bin="${work_dir}/ipt-bin"
ipt_log="${work_dir}/ipt.log"
mkdir -p "$ipt_bin"
printf '#!/bin/sh\necho 0\n' >"${ipt_bin}/id"
# A listing in \${ipt_listing}/<chain> replaces the stub's answer for that
# chain, and \${ipt_listing}/<chain>.absent makes the chain not exist.
ipt_listing="${work_dir}/ipt-listing"
mkdir -p "$ipt_listing"
cat >"${ipt_bin}/iptables" <<EOF
#!/bin/sh
echo "\$(basename "\$0") \$*" >>"${ipt_log}"
case "\$*" in
"-S "*)
    [ ! -e "${ipt_listing}/\${2}.absent" ] || exit 1
    if [ -f "${ipt_listing}/\${2}" ]; then cat "${ipt_listing}/\${2}"; exit 0; fi
    ;;
esac
case "\$*" in
"-S OUTPUT") printf '%s\n' '-P OUTPUT DROP' '-A OUTPUT -j HARMON_EGRESS' ;;
"-S FORWARD") printf '%s\n' '-P FORWARD DROP' '-A FORWARD -j HARMON_EGRESS' ;;
"-S DOCKER-USER") printf '%s\n' '-N DOCKER-USER' '-A DOCKER-USER -j HARMON_EGRESS' ;;
"-S HARMON_EGRESS") printf '%s\n' '-A HARMON_EGRESS -j REJECT --reject-with icmp-admin-prohibited' ;;
-C* | -D*) exit 1 ;;
esac
exit 0
EOF
cp "${ipt_bin}/iptables" "${ipt_bin}/ip6tables"
chmod +x "${ipt_bin}/id" "${ipt_bin}/iptables" "${ipt_bin}/ip6tables"
printf 'nameserver 192.0.2.53\n' >"${work_dir}/resolv.conf"
# run_apply <list> [meta-file] — apply against the stubs; the exit status is
# apply's, the recorded calls land in $ipt_log, stderr in $apply_err.
apply_err="${work_dir}/apply.err"
run_apply() {
    : >"$ipt_log"
    PATH="${ipt_bin}:${PATH}" EGRESS_ALLOWLIST_SHARED="$1" EGRESS_ALLOWLIST_LOCAL=/nonexistent \
        EGRESS_RESOLVER="$stub_resolver" EGRESS_GITHUB_META_FILE="${2:-${work_dir}/meta.json}" \
        EGRESS_RESOLV_CONF="${work_dir}/resolv.conf" bash "$egress" apply >/dev/null 2>"$apply_err"
}
printf 'good.example\n10.0.0.0/8\n' >"${work_dir}/broad-literal.txt"
printf '{"git":["140.82.112.0/20"],"web":["0.0.0.0/0"],"api":[],"packages":[]}\n' >"${work_dir}/meta-broad.json"
for failing in "broad-literal.txt:10.0.0.0/8:" "meta-only.txt:0.0.0.0/0:${work_dir}/meta-broad.json" "dead.txt::"; do
    list="${failing%%:*}"
    refused="${failing#*:}"
    meta="${refused#*:}"
    refused="${refused%%:*}"
    if run_apply "${work_dir}/${list}" "$meta"; then
        fail "egress apply succeeded on a failing plan (${list})"
    fi
    grep -Fxq -- 'iptables -P OUTPUT DROP' "$ipt_log" ||
        fail "a failing egress plan (${list}) left the OUTPUT policy open: $(cat "$apply_err")"
    grep -Fxq -- 'iptables -P FORWARD DROP' "$ipt_log" ||
        fail "a failing egress plan (${list}) left the FORWARD policy open: $(cat "$apply_err")"
    ! grep -q -- '-j ACCEPT' "$ipt_log" ||
        fail "a failing egress plan (${list}) still installed ACCEPT rules: $(cat "$ipt_log")"
    [ -z "$refused" ] || ! grep -Fq -- "-d ${refused} " "$ipt_log" ||
        fail "a failing egress plan (${list}) installed a rule for the refused range ${refused}"
done
run_apply "${work_dir}/list.txt" || fail "egress apply failed against the stubs on a valid fixture: $(cat "$apply_err")"
grep -Fxq -- 'iptables -A HARMON_EGRESS -d 198.51.100.0/24 -j ACCEPT' "$ipt_log" ||
    fail "a successful egress apply did not allow a listed destination: $(cat "$ipt_log")"
! grep -Fq 'apply did not complete' "$apply_err" ||
    fail "a successful egress apply still ran its failure path"

# verify proves the forwarded path too: FORWARD's first rule reaches the
# filter — directly, or through DOCKER-USER once a Docker-in-Docker daemon
# has put its own jump on top — and DOCKER-USER, where it exists, jumps to
# the filter first. Each case replaces one chain's listing in the stub.
# run_verify <expect: pass|fail> <case> — verify against the stub listings.
run_verify() {
    local verify_out
    if verify_out="$(PATH="${ipt_bin}:${PATH}" EGRESS_IF_INET6=/nonexistent bash "$egress" verify 2>&1)"; then
        [ "$1" = pass ] || fail "egress verify passed ${2}"
    else
        [ "$1" = fail ] || fail "egress verify failed ${2}: ${verify_out}"
    fi
}
run_verify pass "on a fully installed filter"
printf '%s\n' '-P FORWARD DROP' '-A FORWARD -j DOCKER-USER' '-A FORWARD -j DOCKER-FORWARD' '-A FORWARD -j HARMON_EGRESS' >"${ipt_listing}/FORWARD"
run_verify pass "with a Docker-in-Docker daemon's DOCKER-USER jump on top of FORWARD"
printf '%s\n' '-P FORWARD DROP' '-A FORWARD -j DOCKER-FORWARD' '-A FORWARD -j HARMON_EGRESS' >"${ipt_listing}/FORWARD"
run_verify fail "with a rule ahead of the FORWARD jump to HARMON_EGRESS"
printf '%s\n' '-P FORWARD DROP' >"${ipt_listing}/FORWARD"
run_verify fail "with no FORWARD jump to HARMON_EGRESS"
rm -f "${ipt_listing}/FORWARD"
printf '%s\n' '-N DOCKER-USER' '-A DOCKER-USER -j RETURN' >"${ipt_listing}/DOCKER-USER"
run_verify fail "with a DOCKER-USER chain that does not jump to HARMON_EGRESS"
printf '%s\n' '-N DOCKER-USER' '-A DOCKER-USER -j ACCEPT' '-A DOCKER-USER -j HARMON_EGRESS' >"${ipt_listing}/DOCKER-USER"
run_verify fail "with a rule ahead of the DOCKER-USER jump to HARMON_EGRESS"
rm -f "${ipt_listing}/DOCKER-USER"
: >"${ipt_listing}/DOCKER-USER.absent"
run_verify pass "with no DOCKER-USER chain and the FORWARD jump first"
printf '%s\n' '-P FORWARD DROP' '-A FORWARD -j DOCKER-USER' '-A FORWARD -j HARMON_EGRESS' >"${ipt_listing}/FORWARD"
run_verify fail "with FORWARD jumping first to a DOCKER-USER chain it cannot read"
rm -f "${ipt_listing}/FORWARD" "${ipt_listing}/DOCKER-USER.absent"

# The trap is armed before iptables is installed. With no iptables and a
# failing install there is nothing to set DROP with, so apply must say so
# (CRITICAL) and exit non-zero; once the install has put iptables on PATH, a
# failure later in it must still leave the policies DROP. The curated PATH
# keeps any real iptables on this machine out of both runs.
noipt_bin="${work_dir}/noipt-bin"
noipt_sbin="${work_dir}/noipt-sbin"
mkdir -p "$noipt_bin" "$noipt_sbin"
for tool in dirname basename; do
    ln -s "$(command -v "$tool")" "${noipt_bin}/${tool}"
done
cp "${ipt_bin}/id" "${noipt_bin}/id"
printf '#!/bin/sh
exit 100
' >"${noipt_bin}/apt-get"
chmod +x "${noipt_bin}/apt-get"
: >"$ipt_log"
if PATH="${noipt_bin}:${noipt_sbin}" EGRESS_ALLOWLIST_SHARED="${work_dir}/list.txt" EGRESS_ALLOWLIST_LOCAL=/nonexistent \
    "$BASH" "$egress" apply >/dev/null 2>"$apply_err"; then
    fail "egress apply succeeded although iptables could not be installed"
fi
grep -Fq 'CRITICAL: could not close egress' "$apply_err" ||
    fail "egress apply with no installable iptables did not say it could not close egress: $(cat "$apply_err")"
! grep -Fq 'did not complete — egress policy left at DROP' "$apply_err" ||
    fail "egress apply with no iptables claimed to have left egress at DROP"
cat >"${noipt_bin}/apt-get" <<EOF
#!/bin/sh
# Installs iptables, then fails (a later package step, a signal).
cp "${ipt_bin}/iptables" "${ipt_bin}/ip6tables" "${noipt_sbin}/"
exit 100
EOF
ln -s "$(command -v cp)" "${noipt_bin}/cp"
: >"$ipt_log"
if PATH="${noipt_bin}:${noipt_sbin}" EGRESS_ALLOWLIST_SHARED="${work_dir}/list.txt" EGRESS_ALLOWLIST_LOCAL=/nonexistent \
    "$BASH" "$egress" apply >/dev/null 2>"$apply_err"; then
    fail "egress apply succeeded although the iptables install failed"
fi
grep -Fxq -- 'iptables -P OUTPUT DROP' "$ipt_log" && grep -Fxq -- 'iptables -P FORWARD DROP' "$ipt_log" ||
    fail "a failed iptables install left the OUTPUT/FORWARD policy open: $(cat "$apply_err")"

# One fail-closed invariant, over a STATEFUL stub that keeps each family's
# chains in files — HARMON_EGRESS in <family>.rules, any other chain in
# <family>.chain.<name>, OUTPUT and FORWARD always present with a policy — so
# -P/-N/-F/-S/-A/-I/-D/-C act on real state, and that can be told to fail its
# -P calls: a failure removes every allow rule a previous filter left in the
# chain as well as setting DROP, and "left at DROP" is printed only when every
# step for every family the container has succeeded — with a global IPv6
# address, an ip6tables policy failure is a failure.
state_bin="${work_dir}/ipt-state-bin"
state_dir="${work_dir}/ipt-state"
mkdir -p "$state_bin"
cat >"${state_bin}/iptables" <<EOF
#!/bin/sh
fam="\$(basename "\$0")"
echo "\${fam} \$*" >>"${ipt_log}"
op="\$1" chain="\$2"
case "\$chain" in
HARMON_EGRESS) f="${state_dir}/\${fam}.rules" ;;
*) f="${state_dir}/\${fam}.chain.\${chain}" ;;
esac
case "\$chain" in
OUTPUT | FORWARD) builtin=1; [ -e "\$f" ] || : >"\$f" ;;
*) builtin=0 ;;
esac
policy="${state_dir}/\${fam}.policy.\${chain}"
case "\$op" in
-P)
    [ ! -e "${state_dir}/\${fam}.policy-fails" ] || exit 1
    echo "\$3" >"\$policy" ;;
-N) [ "\$builtin" -eq 0 ] && [ ! -e "\$f" ] || exit 1; : >"\$f" ;;
-F) [ -e "\$f" ] || exit 1; : >"\$f" ;;
-S)
    [ -e "\$f" ] || exit 1
    if [ "\$builtin" -eq 1 ]; then echo "-P \$chain \$(cat "\$policy" 2>/dev/null || echo ACCEPT)"; else echo "-N \$chain"; fi
    cat "\$f" ;;
-A) [ -e "\$f" ] || exit 1; echo "\$*" >>"\$f" ;;
-I)
    [ -e "\$f" ] && [ "\$3" = 1 ] || exit 1
    shift 3
    { echo "-A \$chain \$*"; cat "\$f"; } >"\$f.tmp" && mv "\$f.tmp" "\$f" ;;
-D | -C)
    [ -e "\$f" ] || exit 1
    shift 2
    line="-A \$chain \$*"
    grep -Fxq -- "\$line" "\$f" || exit 1
    [ "\$op" = -D ] || exit 0
    awk -v l="\$line" '!d && \$0 == l { d = 1; next } { print }' "\$f" >"\$f.tmp" && mv "\$f.tmp" "\$f" ;;
esac
exit 0
EOF
cp "${state_bin}/iptables" "${state_bin}/ip6tables"
cp "${ipt_bin}/id" "${state_bin}/id"
chmod +x "${state_bin}/iptables" "${state_bin}/ip6tables" "${state_bin}/id"
v6_global="${work_dir}/if_inet6.global"
v6_none="${work_dir}/if_inet6.none"
printf '20010db8000000000000000000000001 02 40 00 00 eth0\n' >"$v6_global"
printf '00000000000000000000000000000001 01 80 10 80 lo\n' >"$v6_none"
# seed_filter — the state a previous successful apply leaves: both families'
# chains present and holding ACCEPT rules.
seed_filter() {
    rm -rf "$state_dir"
    mkdir -p "$state_dir"
    printf '%s\n' '-A HARMON_EGRESS -o lo -j ACCEPT' '-A HARMON_EGRESS -d 198.51.100.0/24 -j ACCEPT' \
        '-A HARMON_EGRESS -j REJECT --reject-with icmp-admin-prohibited' >"${state_dir}/iptables.rules"
    printf '%s\n' '-A HARMON_EGRESS -o lo -j ACCEPT' '-A HARMON_EGRESS -j REJECT' >"${state_dir}/ip6tables.rules"
    : >"$ipt_log"
}
# run_state_apply <if_inet6-fixture> — re-apply with a failing plan over the
# seeded filter; the exit status is apply's.
run_state_apply() {
    PATH="${state_bin}:${PATH}" EGRESS_ALLOWLIST_SHARED="${work_dir}/broad-literal.txt" EGRESS_ALLOWLIST_LOCAL=/nonexistent \
        EGRESS_RESOLVER="$stub_resolver" EGRESS_RESOLV_CONF="${work_dir}/resolv.conf" EGRESS_IF_INET6="$1" \
        bash "$egress" apply >/dev/null 2>"$apply_err"
}
# (a) A failing re-apply over an existing filter leaves no allow rule behind.
seed_filter
if run_state_apply "$v6_global"; then
    fail "egress re-apply succeeded on a failing plan over an existing filter"
fi
for fam in iptables ip6tables; do
    grep -Fxq -- "${fam} -F HARMON_EGRESS" "$ipt_log" ||
        fail "a failing egress re-apply did not flush the existing ${fam} HARMON_EGRESS chain: $(cat "$ipt_log")"
    ! grep -q -- '-j ACCEPT' "${state_dir}/${fam}.rules" ||
        fail "a failing egress re-apply left the previous ${fam} allow rules in place: $(cat "${state_dir}/${fam}.rules")"
    grep -Fxq -- "${fam} -P OUTPUT DROP" "$ipt_log" && grep -Fxq -- "${fam} -P FORWARD DROP" "$ipt_log" ||
        fail "a failing egress re-apply left the ${fam} OUTPUT/FORWARD policy open: $(cat "$apply_err")"
done
grep -Fq 'apply did not complete — egress policy left at DROP' "$apply_err" ||
    fail "a failing egress re-apply whose every close step succeeded did not say egress was left at DROP: $(cat "$apply_err")"
# (b) An ip6tables policy failure with global IPv6 is a failure to close:
# CRITICAL, never the DROP claim. Without global IPv6 the same failure is the
# best-effort v6 close apply itself tolerates, and the claim stands.
seed_filter
: >"${state_dir}/ip6tables.policy-fails"
if run_state_apply "$v6_global"; then
    fail "egress apply succeeded on a failing plan with a failing ip6tables"
fi
grep -Fq 'CRITICAL: could not close egress' "$apply_err" ||
    fail "egress fail-closed with global IPv6 and a failing ip6tables policy did not print the CRITICAL line: $(cat "$apply_err")"
! grep -Fq 'egress policy left at DROP' "$apply_err" ||
    fail "egress fail-closed claimed DROP although the ip6tables policy failed with global IPv6 present"
seed_filter
: >"${state_dir}/ip6tables.policy-fails"
run_state_apply "$v6_none" && fail "egress apply succeeded on a failing plan with no global IPv6"
grep -Fq 'apply did not complete — egress policy left at DROP' "$apply_err" ||
    fail "egress fail-closed with no global IPv6 did not claim DROP after closing IPv4: $(cat "$apply_err")"
# (c) A re-apply puts every jump to the filter first, exactly once, even where
# a rule was prepended above an existing jump (and a duplicate sits below);
# verify then passes. Checking for the jump and inserting it only when absent
# would leave it second, and verify would fail.
seed_filter
for fam in iptables ip6tables; do
    printf '%s\n' '-A OUTPUT -o eth0 -j ACCEPT' '-A OUTPUT -j HARMON_EGRESS' '-A OUTPUT -j HARMON_EGRESS' >"${state_dir}/${fam}.chain.OUTPUT"
done
printf '%s\n' '-A FORWARD -j DOCKER-USER' '-A FORWARD -j HARMON_EGRESS' >"${state_dir}/iptables.chain.FORWARD"
printf '%s\n' '-A DOCKER-USER -j RETURN' '-A DOCKER-USER -j HARMON_EGRESS' '-A DOCKER-USER -j HARMON_EGRESS' >"${state_dir}/iptables.chain.DOCKER-USER"
PATH="${state_bin}:${PATH}" EGRESS_ALLOWLIST_SHARED="${work_dir}/list.txt" EGRESS_ALLOWLIST_LOCAL=/nonexistent \
    EGRESS_RESOLVER="$stub_resolver" EGRESS_GITHUB_META_FILE="${work_dir}/meta.json" \
    EGRESS_RESOLV_CONF="${work_dir}/resolv.conf" EGRESS_IF_INET6="$v6_global" \
    bash "$egress" apply >/dev/null 2>"$apply_err" ||
    fail "egress re-apply over a filter whose jumps are no longer first failed: $(cat "$apply_err")"
for jump in iptables:OUTPUT iptables:FORWARD iptables:DOCKER-USER ip6tables:OUTPUT; do
    fam="${jump%%:*}" chain="${jump#*:}"
    [ "$(head -n 1 "${state_dir}/${fam}.chain.${chain}")" = "-A ${chain} -j HARMON_EGRESS" ] ||
        fail "egress re-apply left the ${fam} ${chain} jump to HARMON_EGRESS below another rule: $(cat "${state_dir}/${fam}.chain.${chain}")"
    [ "$(grep -Fxc -- "-A ${chain} -j HARMON_EGRESS" "${state_dir}/${fam}.chain.${chain}")" -eq 1 ] ||
        fail "egress re-apply left the ${fam} ${chain} jump to HARMON_EGRESS other than exactly once: $(cat "${state_dir}/${fam}.chain.${chain}")"
done
PATH="${state_bin}:${PATH}" EGRESS_IF_INET6="$v6_global" bash "$egress" verify >/dev/null 2>"$apply_err" ||
    fail "egress verify failed after a re-apply that moved the jumps first: $(cat "$apply_err")"

# The snapshot: the applier and both lists copied out of the checkout, and a
# later edit to the checkout changes nothing the snapshot applies.
# EGRESS_SNAPSHOT_DIR stands in for the root-owned directory.
snap_checkout="${work_dir}/snap-checkout/.devcontainer"
snap_dir="${work_dir}/snap-root/harmon-egress"
mkdir -p "${snap_checkout}/scripts"
cp "$egress" "${snap_checkout}/scripts/egress-allowlist.sh"
printf 'good.example\n198.51.100.0/24\n' >"${snap_checkout}/egress-allowlist.txt"
printf '203.0.113.0/24\n' >"${snap_checkout}/egress-allowlist.local.txt"
EGRESS_SNAPSHOT_DIR="$snap_dir" bash "${snap_checkout}/scripts/egress-allowlist.sh" snapshot >/dev/null ||
    fail "egress snapshot failed on a valid checkout"
cmp -s "$egress" "${snap_dir}/scripts/egress-allowlist.sh" || fail "the snapshot does not carry the applier"
[ -x "${snap_dir}/scripts/egress-allowlist.sh" ] || fail "the snapshot applier is not executable"
snap_plan_before="$(EGRESS_RESOLVER="$stub_resolver" bash "${snap_dir}/scripts/egress-allowlist.sh" plan 2>/dev/null)"
[ "$snap_plan_before" = "$(printf '192.0.2.10\n192.0.2.11\n198.51.100.0/24\n203.0.113.0/24')" ] ||
    fail "the snapshot applier did not resolve the snapshot's own lists: ${snap_plan_before}"
printf 'good.example\n198.51.100.0/24\n192.0.2.0/24\n' >"${snap_checkout}/egress-allowlist.txt"
printf '203.0.113.0/24\n100.64.0.0/16\n' >"${snap_checkout}/egress-allowlist.local.txt"
printf '#!/bin/sh\necho 0.0.0.0/0\n' >"${snap_checkout}/scripts/egress-allowlist.sh"
[ "$(EGRESS_RESOLVER="$stub_resolver" bash "${snap_dir}/scripts/egress-allowlist.sh" plan 2>/dev/null)" = "$snap_plan_before" ] ||
    fail "editing the checkout's lists after the snapshot changed what the snapshot applies"
# A re-snapshot drops a local list the checkout no longer has, and refuses a
# list apply would refuse without touching the good snapshot.
cp "$egress" "${snap_checkout}/scripts/egress-allowlist.sh"
rm "${snap_checkout}/egress-allowlist.local.txt"
EGRESS_SNAPSHOT_DIR="$snap_dir" bash "${snap_checkout}/scripts/egress-allowlist.sh" snapshot >/dev/null ||
    fail "egress re-snapshot failed on a valid checkout"
[ ! -e "${snap_dir}/egress-allowlist.local.txt" ] || fail "a re-snapshot kept a local list the checkout no longer has"
snap_good="$(cat "${snap_dir}/egress-allowlist.txt")"
printf '0.0.0.0/0\n' >>"${snap_checkout}/egress-allowlist.txt"
if EGRESS_SNAPSHOT_DIR="$snap_dir" bash "${snap_checkout}/scripts/egress-allowlist.sh" snapshot >/dev/null 2>&1; then
    fail "egress snapshot accepted an over-broad list"
fi
[ "$(cat "${snap_dir}/egress-allowlist.txt")" = "$snap_good" ] || fail "a refused snapshot overwrote the good one"

# establish — post-create's one egress step: snapshot, then apply FROM the
# snapshot, fail-closed around both. A list the snapshot refuses leaves the
# policies DROP and exits non-zero; a valid checkout ends with the snapshot's
# filter installed.
establish_log="${work_dir}/establish.err"
run_establish() {
    : >"$ipt_log"
    PATH="${ipt_bin}:${PATH}" EGRESS_SNAPSHOT_DIR="${work_dir}/establish-root/harmon-egress" \
        EGRESS_RESOLVER="$stub_resolver" EGRESS_RESOLV_CONF="${work_dir}/resolv.conf" \
        bash "${snap_checkout}/scripts/egress-allowlist.sh" establish >/dev/null 2>"$establish_log"
}
# The checkout still carries the 0.0.0.0/0 line appended above.
if run_establish; then
    fail "egress establish succeeded on a list the snapshot refuses"
fi
grep -Fq "'0.0.0.0/0'" "$establish_log" || fail "egress establish did not fail at the snapshot's refusal: $(cat "$establish_log")"
grep -Fxq -- 'iptables -P OUTPUT DROP' "$ipt_log" && grep -Fxq -- 'iptables -P FORWARD DROP' "$ipt_log" ||
    fail "a snapshot refusal in egress establish left the OUTPUT/FORWARD policy open: $(cat "$establish_log")"
! grep -q -- '-j ACCEPT' "$ipt_log" || fail "a refused egress establish still installed ACCEPT rules: $(cat "$ipt_log")"
printf 'good.example\n198.51.100.0/24\n' >"${snap_checkout}/egress-allowlist.txt"
run_establish || fail "egress establish failed on a valid checkout: $(cat "$establish_log")"
grep -Fxq -- 'iptables -A HARMON_EGRESS -d 198.51.100.0/24 -j ACCEPT' "$ipt_log" ||
    fail "a successful egress establish did not allow a listed destination: $(cat "$ipt_log")"
! grep -Fq 'did not complete' "$establish_log" || fail "a successful egress establish still ran its failure path"
cmp -s "$egress" "${work_dir}/establish-root/harmon-egress/scripts/egress-allowlist.sh" ||
    fail "egress establish did not write the snapshot it applies"

# The lifecycle: post-create establishes egress before anything else;
# post-start applies only the snapshot, never reads the checkout's applier,
# and closes egress itself when the snapshot applier is missing.
snap_applier=/usr/local/share/harmon-egress/scripts/egress-allowlist.sh
grep -q "^SNAPSHOT_DIR=${snap_applier%/scripts/*}\$" "$egress" ||
    fail "egress-allowlist.sh does not snapshot to ${snap_applier%/scripts/*}, the path the lifecycle applies from"
[ "$(grep -Ev '^[[:space:]]*(#|$)' .devcontainer/agent/post-create.sh | grep -m 1 'bash ')" = "bash .devcontainer/scripts/egress-allowlist.sh establish" ] ||
    fail "the agent post-create does not establish egress (snapshot, then apply the snapshot) before anything else"
[ "$(grep -Ev '^[[:space:]]*(#|$)' .devcontainer/agent/post-start.sh | grep -m 1 'bash ')" = "if ! bash ${snap_applier} apply; then" ] ||
    fail "the agent post-start does not apply the egress snapshot before anything else"
# Run post-start against a snapshot path that does not exist: the start fails
# and the policies are DROP. sudo is a pass-through stub; the log path moves
# into the scratch directory.
start_bin="${work_dir}/start-bin"
mkdir -p "$start_bin"
printf '#!/bin/sh
[ "$1" = -n ] && shift
exec "$@"
' >"${start_bin}/sudo"
chmod +x "${start_bin}/sudo"
sed -e "s|/usr/local/share/harmon-egress|${work_dir}/no-snapshot|g" \
    -e "s|/tmp/devcontainer-post-start.log|${work_dir}/post-start.log|g" \
    .devcontainer/agent/post-start.sh >"${work_dir}/post-start.sh"
: >"$ipt_log"
if (cd "$work_dir" && PATH="${start_bin}:${ipt_bin}:${PATH}" bash "${work_dir}/post-start.sh") 2>"${work_dir}/post-start.stderr"; then
    fail "the agent post-start succeeded with no egress snapshot"
fi
# The failing start says so on the stderr it was started with, not only in
# its log, and names the log.
grep -Fq "post-start: egress filter not installed — failing the start; do not use this container (details: ${work_dir}/post-start.log)" "${work_dir}/post-start.stderr" ||
    fail "the agent post-start did not report its failed start on the original stderr: $(cat "${work_dir}/post-start.stderr")"
grep -Fxq -- 'iptables -P OUTPUT DROP' "$ipt_log" && grep -Fxq -- 'iptables -P FORWARD DROP' "$ipt_log" ||
    fail "the agent post-start left the OUTPUT/FORWARD policy open with no egress snapshot: $(cat "${work_dir}/post-start.log")"
! grep -Fq 'post-start: failed (exit' "${work_dir}/post-start.stderr" ||
    fail "the agent post-start repeated its egress failure through the generic exit alert: $(cat "${work_dir}/post-start.stderr")"
# Any later failure — here the profile's drift gate (agent-autonomy.sh verify)
# — also reaches the original stderr, naming the exit status and the log.
verify_fail_dir="${work_dir}/verify-fail"
mkdir -p "${verify_fail_dir}/.devcontainer/agent" "${work_dir}/ok-snapshot/scripts"
printf '#!/bin/sh\nexit 0\n' >"${work_dir}/ok-snapshot/scripts/egress-allowlist.sh"
printf '#!/bin/sh\necho "agent-autonomy: drift" >&2\nexit 3\n' >"${verify_fail_dir}/.devcontainer/agent/agent-autonomy.sh"
sed -e "s|/usr/local/share/harmon-egress|${work_dir}/ok-snapshot|g" \
    -e "s|/tmp/devcontainer-post-start.log|${work_dir}/post-start.log|g" \
    .devcontainer/agent/post-start.sh >"${work_dir}/post-start-verify.sh"
if (cd "$verify_fail_dir" && PATH="${start_bin}:${ipt_bin}:${PATH}" bash "${work_dir}/post-start-verify.sh") 2>"${work_dir}/post-start.stderr"; then
    fail "the agent post-start succeeded although agent-autonomy.sh verify failed"
fi
grep -Fxq "post-start: failed (exit 3) — do not use this container (details: ${work_dir}/post-start.log)" "${work_dir}/post-start.stderr" ||
    fail "a failed agent-autonomy.sh verify did not reach the original stderr: $(cat "${work_dir}/post-start.stderr")"
# (c) The post-start fallback follows the applier's rule: it flushes the
# chain a previous start left, and claims DROP only when every step for every
# family succeeded. /proc/net/if_inet6 moves to a fixture.
sed -e "s|/usr/local/share/harmon-egress|${work_dir}/no-snapshot|g" \
    -e "s|/tmp/devcontainer-post-start.log|${work_dir}/post-start.log|g" \
    -e "s|/proc/net/if_inet6|${work_dir}/if_inet6.start|g" \
    .devcontainer/agent/post-start.sh >"${work_dir}/post-start-state.sh"
run_state_start() {
    cp "$1" "${work_dir}/if_inet6.start"
    (cd "$work_dir" && PATH="${start_bin}:${state_bin}:${PATH}" bash "${work_dir}/post-start-state.sh") 2>"${work_dir}/post-start.stderr"
}
seed_filter
run_state_start "$v6_global" && fail "the agent post-start succeeded with no egress snapshot over an existing filter"
for fam in iptables ip6tables; do
    ! grep -q -- '-j ACCEPT' "${state_dir}/${fam}.rules" ||
        fail "the agent post-start fallback left the previous ${fam} allow rules in place: $(cat "${state_dir}/${fam}.rules")"
    grep -Fxq -- "${fam} -P OUTPUT DROP" "$ipt_log" && grep -Fxq -- "${fam} -P FORWARD DROP" "$ipt_log" ||
        fail "the agent post-start fallback left the ${fam} OUTPUT/FORWARD policy open: $(cat "${work_dir}/post-start.log")"
done
grep -Fq 'post-start: egress policy left at DROP' "${work_dir}/post-start.log" ||
    fail "the agent post-start fallback did not say egress was left at DROP after closing every family: $(cat "${work_dir}/post-start.log")"
seed_filter
: >"${state_dir}/ip6tables.policy-fails"
run_state_start "$v6_global" && fail "the agent post-start succeeded with no egress snapshot and a failing ip6tables"
grep -Fq 'post-start: CRITICAL: could not close egress' "${work_dir}/post-start.log" ||
    fail "the agent post-start fallback did not print the CRITICAL line when ip6tables failed with global IPv6: $(cat "${work_dir}/post-start.log")"
grep -Fq 'post-start: CRITICAL: could not close egress' "${work_dir}/post-start.stderr" ||
    fail "the agent post-start fallback did not print the CRITICAL line on the original stderr: $(cat "${work_dir}/post-start.stderr")"
! grep -Fq 'left at DROP' "${work_dir}/post-start.log" ||
    fail "the agent post-start fallback claimed DROP although the ip6tables policy failed with global IPv6 present"
! grep -Ev '^[[:space:]]*#' .devcontainer/agent/post-start.sh | grep -E 'egress-allowlist\.txt|\.devcontainer/scripts/egress-allowlist\.sh' >/dev/null ||
    fail "the agent post-start reads the checkout's egress applier or lists (only the root-owned snapshot may be applied at start)"
jq -e '.runArgs | index("--cap-add=NET_ADMIN")' <<<"$agent_cfg" >/dev/null ||
    fail "the agent devcontainer lacks --cap-add=NET_ADMIN, so the egress filter cannot be installed"

echo "==> agent posture unit tests passed."
