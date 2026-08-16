#!/usr/bin/env bash
# gh-scopes.sh — the single source of truth for the GitHub token scopes this
# repository's tooling needs.
#
# SOURCED, never executed. Three consumers read it so the required list is
# stated once instead of drifting into three near-copies:
#
#   * scripts/status.sh          — warns at session start when a scope is missing
#   * scripts/setup-gh-scopes.sh — mints/refreshes a credential that has them all
#   * .devcontainer/scripts/post-create-common.sh — the gh_auth_help banner's
#     `gh auth login --scopes` line
#
# A consumer repo adds its own requirements WITHOUT editing this file by
# exporting GH_EXTRA_SCOPES before invoking any of the above (e.g. in .envrc):
#
#     export GH_EXTRA_SCOPES="delete_repo"
#
# That is ADDITIVE — the repo's own requirements keep applying, including any a
# later template update introduces. GH_REQUIRED_SCOPES also exists and REPLACES
# the computed list outright; it is the escape hatch, and it freezes today's
# defaults.
#
# Syntax: whitespace-separated requirements. A requirement is one scope name,
# or several joined by `|` meaning "any one of these satisfies it". The
# alternation exists because `project` and `read:project` are separate grants
# that GitHub reports separately, and either one proves the token was minted
# with Projects access in mind — while `gh auth refresh` is asked for BOTH, so
# that the credential this repo mints can also write the board.
#
# Why these four:
#   repo      — the PR/issue surface the Dev Loop runs on
#   workflow  — pushing branches that touch .github/workflows/
#   project   — the claim lifecycle's board writes, and ONLY in a repo that has
#               board tooling (read:project alone is read-only; status.sh
#               reports that distinction separately) — see gh_scopes_default
#
# Deliberately NOT a check of what the token can do — scopes are a server-side
# property of the credential and this file only names what to compare against.

# shellcheck shell=bash

# The repo root these helpers answer for. Resolved from this file's own
# location, not the caller's cwd, because the devcontainer banner sources it
# from a lifecycle script whose working directory is not guaranteed.
GH_SCOPES_ROOT="${GH_SCOPES_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"

# gh_target_host — the host gh will actually use for THIS repository.
#
# Lives here rather than in status.sh because scopes are a property of a
# credential ON A HOST: "which scopes" is only answerable once "whose token" is,
# and two copies of this resolution would let the check and the remedy disagree
# about which credential they mean.
#
# Narrowing to github.com would disown a valid Enterprise login (`gh auth login
# --hostname ghe.example.com`, no GH_HOST exported). So resolve it the way gh
# documents: GH_HOST is the override for when a host "cannot be determined from
# repository context", which means repository context comes first when GH_HOST
# is unset. Local and network-free — the remote URL is the context.
gh_target_host() {
    local url host=""
    if [ -n "${GH_HOST:-}" ]; then
        printf '%s' "${GH_HOST}"
        return 0
    fi
    url="$(git config --get remote.origin.url 2>/dev/null || true)"
    case "${url}" in
    *://*)                 # scheme://[user@]host[:port]/path
        host="${url#*://}" # drop the scheme
        host="${host#*@}"  # drop any userinfo
        host="${host%%/*}" # drop the path
        host="${host%%:*}" # drop any port
        ;;
    *@*:*) # scp-like: user@host:owner/repo
        host="${url#*@}"
        host="${host%%:*}"
        ;;
    esac
    printf '%s' "${host:-github.com}"
}

# gh_scopes_default — the required list for THIS repo's actual feature set.
#
# `repo` and `workflow` are unconditional: every generated repo opens PRs and
# has a .github/workflows/ a push may touch.
#
# The Projects scopes are NOT. `project_management` defaults to `none`, and a
# repo generated that way has no board to write to — demanding Projects access
# there would warn every session, in the majority profile, about a grant the
# repo never uses, and train the reader to ignore the line where it matters.
# So it is gated on the same marker the board-write check in status.sh uses:
# setup-github-project.sh is rendered only for `project_management: github`,
# which makes its presence the proxy for "this repo is configured to have a
# board". Same accepted cost, recorded there: a repo on `none` whose issues
# someone adds to a board by hand learns from the claim's own exit 2 instead.
#
# `admin:org` rides on the same rule. The template renders
# setup-github-issue-types.sh (and setup-github-issue-fields.sh) only when the
# repo belongs to an ORG rather than the author's own account, and those tasks
# state they need `admin:org` — so a generated org repo could otherwise pass
# every scope check here and still fail those setups. A personal-account repo
# renders neither script and is never asked for it.
gh_scopes_default() {
    local list="repo workflow"
    if [ -f "${GH_SCOPES_ROOT}/scripts/setup-github-project.sh" ]; then
        list="${list} project|read:project"
    fi
    if [ -f "${GH_SCOPES_ROOT}/scripts/setup-github-issue-types.sh" ] ||
        [ -f "${GH_SCOPES_ROOT}/scripts/setup-github-issue-fields.sh" ]; then
        list="${list} admin:org"
    fi
    printf '%s' "${list}"
}

# Two knobs, because "extend" and "replace" are different intentions and only
# one of them is safe to reach for by default:
#
#   GH_EXTRA_SCOPES     — ADDED to whatever this repo's profile already
#                         requires. The one to use: a later template update
#                         that adds a requirement still reaches you.
#   GH_REQUIRED_SCOPES  — REPLACES the computed list outright. An escape
#                         hatch. Setting it freezes today's defaults, so a
#                         requirement added upstream will silently stop being
#                         checked.
GH_REQUIRED_SCOPES="${GH_REQUIRED_SCOPES:-$(gh_scopes_default)${GH_EXTRA_SCOPES:+ ${GH_EXTRA_SCOPES}}}"

# gh_scopes_request_list — the comma-separated list to hand
# `gh auth login --scopes` / `gh auth refresh -s`.
#
# Every alternative of every requirement is requested, not just one: asking for
# `project` alone would satisfy the check while leaving the vendored track-work
# skill's `read:project` hint unmet, and the two remedy strings that used to
# disagree (issue #596) are exactly what one derived list removes.
gh_scopes_request_list() {
    local req alt out=""
    for req in $(gh_scopes__words "${GH_REQUIRED_SCOPES}"); do
        for alt in $(gh_scopes__alternatives "${req}"); do
            case ",${out}," in *",${alt},"*) continue ;; esac
            out="${out:+${out},}${alt}"
        done
    done
    printf '%s' "${out}"
}

# gh_scopes_missing SCOPE_LINE — print the requirements SCOPE_LINE does not
# satisfy, whitespace-separated; print nothing when it satisfies them all.
#
# SCOPE_LINE is the `Token scopes:` line of `gh auth status`, whose scopes are
# quoted (`… 'gist', 'project', 'repo'`). Matching on the quotes is what keeps
# `project` from also matching `read:project` and vice versa — they are
# different grants, and the alternation above is how a caller says either will
# do.
#
# A line with no quoted scopes at all is a fine-grained PAT or an App
# installation token, which carries permissions rather than OAuth scopes. That
# is NOT a missing-scope condition and callers must classify it as unknown —
# this function reports every requirement as missing for such a line, so guard
# the call, as status.sh does.
gh_scopes_missing() {
    local line="$1" req alt satisfied out=""
    for req in $(gh_scopes__words "${GH_REQUIRED_SCOPES}"); do
        satisfied=false
        for alt in $(gh_scopes__alternatives "${req}"); do
            case "${line}" in
            *"'${alt}'"*)
                satisfied=true
                break
                ;;
            esac
        done
        [ "${satisfied}" = true ] || out="${out:+${out} }${req}"
    done
    printf '%s' "${out}"
}

# gh_scopes_missing_requested SCOPE_LINE — the scopes that were REQUESTED but
# are not present, whitespace-separated.
#
# Distinct from gh_scopes_missing, and both are needed. The status check asks
# "was this credential minted with the right access in mind", and there the
# `project|read:project` alternation is right — either proves it. A refresh
# cannot use that question: `gh auth refresh` was handed every alternative, so
# a grant that came back with only `read:project` satisfies the alternation
# while board WRITES still fail, and reporting "all required scopes present"
# there would leave the operator in exactly the failure the task exists to end.
#
# One implication is honoured, because GitHub's own scopes nest: `project`
# (read and write) subsumes `read:project`, so a credential reported with only
# `project` is not missing the read grant. Kept as a single named pair rather
# than a general lattice — it is the only nesting this list contains, and an
# implication table nobody can enumerate would be worse than none.
gh_scopes_missing_requested() {
    local line="$1" scope out=""
    for scope in $(gh_scopes__alternatives "$(gh_scopes_request_list | tr ',' ' ')"); do
        case "${line}" in
        *"'${scope}'"*) continue ;;
        esac
        # `project` implies `read:project`.
        if [ "${scope}" = "read:project" ]; then
            case "${line}" in
            *"'project'"*) continue ;;
            esac
        fi
        out="${out:+${out} }${scope}"
    done
    printf '%s' "${out}"
}

# gh_scopes_human "req req…" — render requirements for a human: the `|`
# alternation becomes " or ", and requirements are comma-separated.
gh_scopes_human() {
    local req out=""
    for req in $(gh_scopes__words "$1"); do
        out="${out:+${out}, }$(printf '%s' "${req}" | sed 's/|/ or /g')"
    done
    printf '%s' "${out}"
}

# Internal splitters. Word-splitting is the intent here, so it happens in one
# named place with the shellcheck waiver attached to it rather than at four
# call sites.
gh_scopes__words() {
    # shellcheck disable=SC2086 # deliberate: the list is whitespace-separated
    printf '%s\n' $1
}

gh_scopes__alternatives() {
    printf '%s' "$1" | tr '|' ' '
}
