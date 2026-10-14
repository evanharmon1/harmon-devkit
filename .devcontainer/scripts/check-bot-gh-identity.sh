#!/usr/bin/env bash
set -euo pipefail

# check-bot-gh-identity.sh — the BOT profile's gh-identity tripwire
# (harmon-init#1236).
#
# The git-identity assertions in scripts/devcontainer-assert.sh prove who this
# container COMMITS as; nothing proved who `gh` WRITES as. When the bot PAT
# never arrives, `gh` comes up unauthenticated and its own output suggests
# `gh auth login` — and an operator (or an agent relaying that suggestion) can
# interactively authenticate a personal account, after which every issue, PR,
# and comment is attributed to the human and a personal credential sits inside
# a bypassPermissions agent container.
#
# The PAT is PROVISIONED, never hand-authored: on Coder it flows template
# parameter -> workspace host env -> init-env.sh -> .devcontainer/
# devcontainer.env -> the container's GH_TOKEN; on other hosts the same
# init-env.sh projection runs from whatever the host env exports. So every
# remedy below points at that chain — this check is defense-in-depth for a
# provisioning failure upstream of this repo, and the one thing it must never
# do is suggest an interactive login.
#
# Decides from `gh auth status` output ALONE — no extra API call: the
# stored-credential shapes name their account even when validation fails
# (offline or revoked). Two shapes cannot be resolved locally and are
# indeterminate, never violations: a token from the environment that gh could
# not validate (it names no account), and gh missing entirely. Like the
# sibling git checks, this asserts the RELATIONSHIP (a '-bot' login suffix),
# never a literal account name, so the script stays valid verbatim in
# generated projects.
#
# Exit codes (consumers map them; this script only reports):
#   0  every gh credential names a '-bot' account
#   1  VIOLATION — a credential names a non-bot account (loud warning)
#   2  unauthenticated — no credential at all (loud provisioning remedy)
#   3  indeterminate — gh missing, or an environment token that cannot be
#      validated right now (offline / rate-limited / expired); the ACTIVE
#      identity is then unknown even when stored bot logins are also present,
#      because gh prefers the environment token for writes
#
# Callers: .devcontainer/post-start.sh and .devcontainer/agent/post-start.sh
# (warn-only, `|| true`, into the post-start log), scripts/status.sh's creds
# section (the VISIBLE surface — the session-start hook renders it; gated
# there to the bot profile), and scripts/devcontainer-assert.sh container
# mode (fails on exit 1 only).

banner() {
    echo "=============================================================="
}

# The agent posture (FOREMAN_DEVCONTAINER=agent) is checked by the same '-bot'
# relationship — its PAT lives on the bot account — but provisions a different
# variable, so its remedy names that chain instead. Never the bot's GH_TOKEN.
is_agent_posture() {
    [ "${FOREMAN_DEVCONTAINER:-}" = "agent" ]
}

# The banners name the posture actually running: the agent posture runs Claude
# Code in auto mode with bypass disabled, so calling it a bypassPermissions
# container would misdescribe it. The bot wording is unchanged.
if is_agent_posture; then
    posture_label="AGENT CONTAINER"
    posture_article="an"
    posture_mode="auto-mode"
else
    posture_label="BOT CONTAINER"
    posture_article="a"
    posture_mode="bypassPermissions"
fi

remedy_provisioning() {
    if is_agent_posture; then
        echo "  Remedy — fix the PROVISIONING chain that supplies the AGENT PAT:"
        echo "    * export AGENT_GH_TOKEN (the agent's own fine-grained PAT on the"
        echo "      bot account — never the bot's GH_TOKEN) in the host"
        echo "      environment that .devcontainer/scripts/init-env.sh projects"
        echo "      into .devcontainer/agent/devcontainer.env;"
        echo "    * rebuild: the agent post-create logs gh in from it."
        echo "  See docs/guides/bot-account.md."
        return 0
    fi
    echo "  Remedy — fix the PROVISIONING chain that supplies the bot PAT:"
    echo "    * on Coder: set the workspace's GitHub PAT template parameter"
    echo "      (template parameter -> workspace env -> init-env.sh ->"
    echo "      .devcontainer/devcontainer.env -> container GH_TOKEN);"
    echo "    * elsewhere: export GH_TOKEN in the host environment that"
    echo "      .devcontainer/scripts/init-env.sh projects into"
    echo "      .devcontainer/devcontainer.env (or populate that env-file"
    echo "      out-of-band, e.g. 1Password Environment);"
    echo "  then rebuild the container. See docs/guides/bot-account.md."
}

if ! command -v gh >/dev/null 2>&1; then
    echo "==> gh-identity: gh is not on PATH — cannot check the bot login (indeterminate)."
    echo "  Remedy: restore the GitHub CLI. It ships in the devcontainer image,"
    echo "  so its absence means image or toolchain drift — rebuild the"
    echo "  container from the pinned image rather than installing gh by hand."
    exit 3
fi

# Bounded probe, bounded HERE: post-start and the container assert invoke
# this helper with no wrapper, so a stalled GitHub, DNS, or credential
# backend must not wedge container startup or a smoke assertion — `|| true`
# in a caller only handles an eventual nonzero exit, never a hang. stdin is
# closed so nothing downstream can prompt. 124/137 are timeout(1)'s
# deadline/kill codes; with no parseable output they resolve to
# indeterminate below. Where timeout(1) is unavailable the probe runs
# unbounded rather than not at all — every real caller is the Linux
# container, whose image ships coreutils.
# The kill grace is parameterized so a caller with its own outer bound
# (the status board's run_timeout) can contain deadline + grace and this
# helper's timed-out note survives to be printed — a kill-resistant gh
# under the default grace would outlive a tight outer bound and the
# caller would see empty output instead of the warning.
GH_IDENTITY_TIMEOUT="${GH_IDENTITY_TIMEOUT:-10}"
GH_IDENTITY_KILL_GRACE="${GH_IDENTITY_KILL_GRACE:-5}"
# Colour is disabled at the source AND stripped from the capture. Either alone
# is insufficient: a container inheriting CLICOLOR_FORCE=1 makes gh wrap the
# login in ANSI sequences, and the parse below requires an alphanumeric
# immediately after "account"/"as", so the login is omitted and a stored
# NON-BOT credential degrades from a violation (1) to "could not parse" (3) —
# which the container assert accepts, silently bypassing the whole check. That
# is a security bypass reachable from an environment variable, so it gets both
# a belt and braces: NO_COLOR/CLICOLOR_FORCE tell gh not to emit, and the sed
# strips anything that arrives anyway (a future gh, a wrapper, a pager).
status_rc=0
if command -v timeout >/dev/null 2>&1; then
    status_out="$(NO_COLOR=1 CLICOLOR_FORCE=0 timeout -k "$GH_IDENTITY_KILL_GRACE" "$GH_IDENTITY_TIMEOUT" gh auth status </dev/null 2>&1)" || status_rc=$?
else
    status_out="$(NO_COLOR=1 CLICOLOR_FORCE=0 gh auth status </dev/null 2>&1)" || status_rc=$?
fi
# CSI sequences: ESC [ ... final-byte. Portable across macOS/BSD and GNU sed.
status_out="$(printf '%s\n' "$status_out" | sed -e 's/'"$(printf '\033')"'\[[0-9;?]*[A-Za-z]//g')"

# Every credential gh knows about, by the account each one CLAIMS. gh has
# three per-account record shapes — healthy "Logged in to <host> account
# <login>", failed "Failed to log in to <host> account <login>", and its
# own built-in timeout "Timeout ... trying to log in to <host> account
# <login>" (which exits with the ordinary failure code, not 124/137) — and
# every non-healthy shape still names the account, so a credential is
# judged by its claimed identity regardless of whether the token
# validated. The "log in to" anchor covers the failure and timeout
# wordings alike ("Logged in to" cannot false-match it), "as <login>"
# covers older gh wording, and the anchor keeps unrelated text like
# "Active account: true" out.
# The login is captured to the next WHITESPACE, not to the end of a
# [A-Za-z0-9-] run. GitHub Enterprise Managed User logins carry an underscore
# and a shortcode — `alice-bot_acme` — and a character class that stops at the
# underscore records `alice-bot`, which passes the '-bot' test below while the
# real account does not end in '-bot' at all. That is a bypass of this
# script's own predicate, not a cosmetic parse: the suffix has to be tested
# against the WHOLE login. gh prints the source in parentheses after a space,
# so stopping at whitespace still excludes it.
logins="$(printf '%s\n' "$status_out" |
    grep -oE '(Logged in to|log in to) [^ ]+ (account|as) [A-Za-z0-9][^[:space:]]*' |
    awk '{ print $NF }' | sort -u)" || logins=""

# gh reads AT MOST ONE environment token per host class — the highest-
# precedence of GH_TOKEN / GITHUB_TOKEN for github.com and of
# GH_ENTERPRISE_TOKEN / GITHUB_ENTERPRISE_TOKEN for GHES (gh help
# environment) — so `gh auth status` can never enumerate a credential
# shadowed behind the winner (verified: with both github.com aliases set,
# only GH_TOKEN is reported). A shadowed alias carrying a DIFFERENT value
# is credential material this check cannot attribute — indeterminate,
# below — while the same value spelled twice is one credential and stays
# clean. Names only, never values: this lands in lifecycle logs.
# The two pairs are INDEPENDENT precedence groups targeting different
# host classes, so shadowing is judged within each pair — a bot GH_TOKEN
# beside a different GH_ENTERPRISE_TOKEN is a legitimate two-host setup,
# not a shadow. Whether the enterprise pair was actually ENUMERATED is a
# separate check below.
env_token_present=false
shadowed_aliases=""
for alias_pair in "GH_TOKEN GITHUB_TOKEN" "GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN"; do
    pair_primary=""
    for alias_var in $alias_pair; do
        alias_val="${!alias_var:-}"
        [ -n "$alias_val" ] || continue
        env_token_present=true
        if [ -z "$pair_primary" ]; then
            pair_primary="$alias_val"
        elif [ "$alias_val" != "$pair_primary" ]; then
            shadowed_aliases="${shadowed_aliases}${shadowed_aliases:+ }${alias_var}"
        fi
    done
done

# A credential that FAILED validation without naming an account — in practice
# a token from the environment (GH_TOKEN or an alias) that gh could not
# validate. gh prefers an environment token for writes, so while one is
# unverified the ACTIVE identity is unknown no matter which stored logins
# were parsed above.
# Only a record sourced from one of the four REAL aliases counts: gh also
# writes "using token (default)" when GH_HOST selects a host that has
# neither a stored login nor a token — that pseudo-source is the ordinary
# unauthenticated state, handled below, not an unverified token.
unnamed_token=false
if printf '%s\n' "$status_out" |
    grep -E 'log in to [^ ]+ using token \((GH_TOKEN|GITHUB_TOKEN|GH_ENTERPRISE_TOKEN|GITHUB_ENTERPRISE_TOKEN)\)' >/dev/null; then
    unnamed_token=true
fi

# Collected with their credential SOURCE, because the remedy differs and a
# remedy that cannot work is worse than none: `gh auth logout` removes a
# keyring/hosts.yml record and can do nothing about a token supplied through
# the environment. A misprovisioned GH_TOKEN carrying the wrong account is a
# PRIMARY failure mode here, so that is not a corner worth getting wrong.
# The '-bot' relationship is tested against the IdP component of the login,
# never the raw string. An ordinary GitHub username is alphanumerics and
# hyphens only, so the ONLY thing that can put an underscore in a login is
# Enterprise Managed Users, which appends `_<enterprise-shortcode>` to the IdP
# username: the bot account `someowner-bot` IS `someowner-bot_acme` there.
# Testing the raw login rejects every legitimate EMU bot; stripping a trailing
# `_<shortcode>` first tests the name the operator actually provisioned. The
# FULL login is what gets displayed, so a warning always names the real
# account.
#
# The source lookup matches the account's OWN record, anchored on the word gh
# prints before it. A substring search is wrong for the ordinary naming pair
# this repo uses — `alice` and `alice-bot` — because `alice` matches the bot's
# `(GH_TOKEN)` record too, which would classify the human credential as
# environment-sourced, drop the `gh auth logout` it actually needs, and send
# the operator to repair an already-correct bot token while the personal
# credential stays installed.
bad=""
bad_stored=false
bad_env=false
for login in $logins; do
    case "${login%_*}" in
    *-bot) continue ;;
    esac
    bad="${bad}${bad:+ }${login}"
    # Independent tests, never if/else: `sort -u` above collapses one login to
    # one entry, but the same login can hold DIFFERENT credentials on different
    # hosts — `alice (GH_TOKEN)` on github.com beside `alice (keyring)` on a
    # GHES host. An else-branch records only whichever was found first, and the
    # remedy then omits the `gh auth logout` the stored one actually needs,
    # leaving the personal credential installed.
    login_records="$(printf '%s\n' "$status_out" | grep -E "(account|as) ${login} \\(" || true)"
    if printf '%s\n' "$login_records" |
        grep -E '\((GH_TOKEN|GITHUB_TOKEN|GH_ENTERPRISE_TOKEN|GITHUB_ENTERPRISE_TOKEN)\)' >/dev/null; then
        bad_env=true
    fi
    if printf '%s\n' "$login_records" |
        grep -vE '\((GH_TOKEN|GITHUB_TOKEN|GH_ENTERPRISE_TOKEN|GITHUB_ENTERPRISE_TOKEN)\)' >/dev/null; then
        bad_stored=true
    fi
done

# A KNOWN non-bot credential outranks everything else, an unverifiable
# environment token included: the stored human login is a violation
# regardless of what the unnamed token would have resolved to.
if [ -n "$bad" ]; then
    banner
    echo "  ${posture_label}: gh holds a credential for a NON-BOT account:"
    echo ""
    echo "      ${bad}"
    echo ""
    echo "  GitHub writes can be attributed to that account — immediately"
    echo "  when it is the active credential, or after an account switch —"
    echo "  and a personal credential must never sit inside ${posture_article}"
    echo "  ${posture_mode} agent container."
    echo ""
    echo "  First remove the human credential (and consider rotating it):"
    if [ "$bad_stored" = true ]; then
        echo "    * a STORED login — run"
        echo "        gh auth logout --hostname <host> --user <login>"
        echo "      with the host 'gh auth status' lists it under;"
    fi
    if [ "$bad_env" = true ]; then
        echo "    * a credential from the ENVIRONMENT — 'gh auth logout'"
        echo "      cannot remove it. The wrong account was provisioned into"
        echo "      this container's token, so fix it at the source below"
        echo "      rather than in the container;"
    fi
    echo "  then:"
    echo ""
    remedy_provisioning
    banner
    exit 1
fi

# A shadowed alias holds a token gh never enumerated: whoever it belongs
# to, nothing above examined it, so "every credential is a bot" would be
# unjustified. Indeterminate rather than a violation — the value could as
# easily be a stale copy of the bot's own PAT as a personal credential.
if [ -n "$shadowed_aliases" ]; then
    if is_agent_posture; then
        echo "==> gh-identity: ${shadowed_aliases} is set with a value different from" \
            "the token gh actually uses, and gh enumerates only the highest-precedence" \
            "environment token — that credential cannot be attributed. The agent" \
            "posture blanks every environment token alias: unset them, and provision" \
            "the agent PAT as AGENT_GH_TOKEN through" \
            ".devcontainer/agent/devcontainer.env; bot login unverified until then" \
            "(indeterminate)."
        exit 3
    fi
    echo "==> gh-identity: ${shadowed_aliases} is set with a value different from" \
        "the token gh actually uses, and gh enumerates only the highest-precedence" \
        "environment token — that credential cannot be attributed. Unset the" \
        "shadowed alias (or make it identical to the provisioned bot GH_TOKEN);" \
        "bot login unverified until then (indeterminate)."
    exit 3
fi

# The enterprise pair counts as examined only on DIRECT evidence: a
# record whose parenthesised source names the winning enterprise alias.
# A non-github.com host in the enumeration is not that evidence — *.ghe.com
# subdomains are served by GH_TOKEN (gh help environment), so a tenant
# host can appear while the enterprise token stays wholly unexamined.
enterprise_winner=""
if [ -n "${GH_ENTERPRISE_TOKEN:-}" ]; then
    enterprise_winner="GH_ENTERPRISE_TOKEN"
elif [ -n "${GITHUB_ENTERPRISE_TOKEN:-}" ]; then
    enterprise_winner="GITHUB_ENTERPRISE_TOKEN"
fi
if [ -n "$enterprise_winner" ] &&
    ! printf '%s\n' "$status_out" | grep -F "(${enterprise_winner})" >/dev/null; then
    if is_agent_posture; then
        echo "==> gh-identity: ${enterprise_winner} is set but no gh auth status record is" \
            "sourced from it, so that token was never enumerated — bot login unverified" \
            "(indeterminate). The agent posture blanks every environment token alias:" \
            "unset the enterprise aliases, and provision the agent PAT as" \
            "AGENT_GH_TOKEN through .devcontainer/agent/devcontainer.env."
        exit 3
    fi
    echo "==> gh-identity: ${enterprise_winner} is set but no gh auth status record is" \
        "sourced from it, so that token was never enumerated — bot login unverified" \
        "(indeterminate). Provision the bot PAT as GH_TOKEN and unset the enterprise" \
        "aliases."
    exit 3
fi

# A timed-out probe is an INCOMPLETE enumeration, never a clean one: gh
# validates accounts sequentially, so being killed after printing the bot
# account but before a later stored human credential must not read as
# "every credential is a bot". A non-bot login parsed before the deadline
# already took precedence above — that evidence stands regardless.
if [ "$status_rc" = "124" ] || [ "$status_rc" = "137" ]; then
    echo "==> gh-identity: gh auth status timed out after ${GH_IDENTITY_TIMEOUT}s —" \
        "credential enumeration incomplete, bot login unverified (indeterminate)."
    # An indeterminate read is reported WITH the remedy, never bare: a timeout
    # is precisely the offline case the acceptance criteria call out, and a
    # reader who sees only "unverified" is left with nothing to do about it.
    remedy_provisioning
    exit 3
fi

if [ "$unnamed_token" = true ]; then
    if is_agent_posture; then
        echo "==> gh-identity: a token from the environment is present but could not be" \
            "validated (offline, rate-limited, or expired) — the ACTIVE gh identity is" \
            "unverified. The agent posture blanks every environment token alias, so" \
            "unset this one; if this persists, re-provision the agent PAT" \
            "(AGENT_GH_TOKEN in the host env that init-env.sh projects into" \
            ".devcontainer/agent/devcontainer.env) and rebuild."
        exit 3
    fi
    echo "==> gh-identity: a token from the environment is present but could not be" \
        "validated (offline, rate-limited, or expired) — the ACTIVE gh identity is" \
        "unverified. If this persists, re-provision the bot PAT (on Coder: the" \
        "workspace's GitHub PAT template parameter; elsewhere: the host env that" \
        "init-env.sh projects into .devcontainer/devcontainer.env) and rebuild."
    exit 3
fi

unauthenticated_banner() {
    banner
    echo "  ${posture_label}: GitHub CLI is NOT authenticated."
    echo ""
    echo "  Do NOT run 'gh auth login' here — that would put a human"
    echo "  credential inside ${posture_article} ${posture_mode} agent container."
    echo ""
    remedy_provisioning
    banner
}

# gh's "(default)" pseudo-source — GH_HOST selecting a host that has
# neither a stored login nor a token — is the ordinary unauthenticated
# state when no alias is set either: there is nothing present to
# attribute, so the remedy banner is the right answer, not a false
# token-present indeterminate.
if [ "$env_token_present" = false ] &&
    printf '%s\n' "$status_out" | grep -E 'log in to [^ ]+ using token \(default\)' >/dev/null; then
    unauthenticated_banner
    exit 2
fi

# Only now may parsed logins declare success. This check sits AFTER the
# `(default)` branch on purpose: when GH_HOST selects a host with no stored
# login and no token, gh reports that host's `using token (default)` failure
# ALONGSIDE another host's healthy bot record, so accepting the parsed login
# first reported a clean identity while the host gh would actually write to was
# unauthenticated.
if [ -n "$logins" ]; then
    echo "==> gh-identity: every gh credential matches the bot '-bot' relationship."
    exit 0
fi

case "$status_out" in
*"not logged into any GitHub hosts"*)
    # "Not logged in" while an environment token IS set means gh attributes
    # that token to no host it knows: present but invisible to the
    # enumeration, so identity is unverified — not a clean unauthenticated
    # state.
    if [ "$env_token_present" = true ]; then
        if is_agent_posture; then
            echo "==> gh-identity: an environment token is set but gh attributes it to no" \
                "host, so it was never enumerated — bot login unverified (indeterminate)." \
                "The agent posture blanks every environment token alias: unset them, and" \
                "provision the agent PAT as AGENT_GH_TOKEN through" \
                ".devcontainer/agent/devcontainer.env."
            exit 3
        fi
        echo "==> gh-identity: an environment token is set but gh attributes it to no" \
            "host, so it was never enumerated — bot login unverified (indeterminate)." \
            "Provision the bot PAT as GH_TOKEN and unset the other token aliases."
        exit 3
    fi
    unauthenticated_banner
    exit 2
    ;;
*)
    echo "==> gh-identity: could not parse gh auth status output — bot login unverified (indeterminate)."
    remedy_provisioning
    exit 3
    ;;
esac
