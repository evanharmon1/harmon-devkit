#!/usr/bin/env bash
# Shared, read-only GitHub REST helpers for session scripts.
#
# These helpers deliberately avoid gh subcommands backed by GraphQL and gh
# api --paginate. Claude Code's repository proxy permits repos/{owner}/{repo}
# REST reads, but rejects GraphQL, search, and the numeric repository links gh
# follows after the first --paginate page.
#
# Every walk is bounded twice: by the caller's MAX_ITEMS, and by
# GH_REST_MAX_PAGES (default 10), a whole-operation page ceiling that stops the
# loop and returns 4 once exceeded — so no caller can reintroduce an unbounded
# whole-repository walk by passing MAX_ITEMS=0. Raise it deliberately, per
# call, when an operation genuinely needs more than 1000 items.
#
# Host handling: gh_rest_api derives the GitHub host once per call
# (gh_rest_host) and passes --hostname to gh for any host other than
# github.com, so an Enterprise remote or a host-qualified GH_REPO is read from
# the host it names. Export GH_REST_HOST to short-circuit the derivation (an
# empty value means "no --hostname").
#
# A host that carries a PORT is the one authority gh's flag cannot express: it
# is REFUSED with 5 rather than passed or quietly trimmed (see gh_rest_api),
# and every helper here propagates that 5 unchanged.

# gh_rest_repo [REMOTE] — print OWNER/REPO from GH_REPO or a git remote.
# GH_REPO may carry gh's documented [HOST/]OWNER/REPO form; the host segment is
# dropped here (gh_rest_host recovers it) so endpoints stay repos/OWNER/REPO.
#
# An explicitly passed REMOTE outranks GH_REPO. An argument is the caller's
# deliberate statement about which remote to resolve; GH_REPO is ambient
# configuration that may name an unrelated repository. A caller that iterates
# remotes — audit-session-artifacts.sh does — would otherwise read its
# pull-request evidence from GH_REPO's repository while every other section of
# the same audit stayed on the remote it had selected (integration r2). With no
# argument GH_REPO keeps its precedence: every other caller relies on that, and
# this repository's workflows export it deliberately.
gh_rest_repo() {
    local remote="${1:-}" url path owner name

    if [ -z "${remote}" ] && [ -n "${GH_REPO:-}" ]; then
        path="${GH_REPO}"
        case "${path}" in */*/*) path="${path#*/}" ;; esac
        printf '%s\n' "${path}"
        return 0
    fi
    if [ -z "${remote}" ]; then
        if git remote 2>/dev/null | grep -x origin >/dev/null; then
            remote=origin
        else
            remote="$(git remote 2>/dev/null | sed -n '1p')"
        fi
    fi
    [ -n "${remote}" ] || return 1
    url="$(git remote get-url "${remote}" 2>/dev/null)" || return 1
    url="${url%.git}"
    case "${url}" in
    *://*)
        path="${url#*://}"
        # A scheme URL's AUTHORITY is everything before the first `/`, less any
        # userinfo — and a remote with no authority names no host, so it is not
        # a GitHub remote however its last two path segments read.
        # `file:///srv/mirrors/acme/widget` resolved as acme/widget, which sent
        # a local mirror's endpoint to the DEFAULT host and, worse, defeated a
        # caller's ambient fallback: a resolved-looking repository is exactly
        # what stops that fallback from running (integration r3). Rejected here
        # rather than in each caller, because every caller would need the same
        # test. `*@` is the userinfo-only case, `ssh://git@/acme/widget`.
        case "${path%%/*}" in '' | *@) return 1 ;; esac
        path="${path#*@}"
        path="${path#*/}"
        ;;
    *:*) path="${url#*:}" ;;
    *) return 1 ;;
    esac
    path="${path#/}"
    name="${path##*/}"
    path="${path%/*}"
    owner="${path##*/}"
    # The hyphen is LAST in the class deliberately: `.-/` is the RANGE
    # 0x2E-0x2F, which admits `/` and rejects every hyphenated owner or name —
    # this repository's own included (challenge r3).
    case "${owner}/${name}" in
    */ | /* | *[!A-Za-z0-9_./-]*) return 1 ;;
    esac
    printf '%s/%s\n' "${owner}" "${name}"
}

# gh_rest_host [REMOTE] — print the GitHub host the repository lives on: the
# HOST/ prefix of GH_REPO when present, else GH_HOST (gh's own override, which
# gh_target_host in gh-scopes.sh honours the same way), else the host of the
# remote URL (https://HOST[:PORT]/..., ssh://git@HOST[:PORT]/...,
# [user@]HOST:...),
# else nothing. Always exits 0: an empty result means "let gh pick", never an
# error.
#
# An explicitly passed REMOTE outranks both GH_REPO and GH_HOST, for the reason
# gh_rest_repo does and on the same argument: the two functions answer about the
# same remote, so a caller passing one must not get the argument's repository
# paired with ambient configuration's host. With no argument both keep their
# precedence, unchanged.
#
# A colon means a different thing in each form, so the port is read per form
# rather than stripped from all three (challenge r4):
#   https://HOST:PORT/...   the port is part of the API AUTHORITY — an
#                           Enterprise instance published on 8443 answers
#                           nowhere else — so it is KEPT here and REPORTED as
#                           the host. It does NOT travel on into --hostname,
#                           which gh will not parse with a colon in it:
#                           gh_rest_api refuses such a host instead
#                           (integration r4). Reporting it is still right,
#                           because the alternative — printing nothing — is
#                           this function's "let gh pick", which is the silent
#                           default-host read that trimming the port would
#                           have caused.
#   ssh://git@HOST:PORT/... an SSH TRANSPORT port (2222 through a bastion, say)
#                           says nothing about where the API listens: DROPPED.
#   [user@]HOST:OWNER/REPO  scp-like, so the colon introduces the PATH and there
#                           is no port to keep. The userinfo is OPTIONAL: git
#                           reads `ghe.example.com:acme/repo` as ssh too, and an
#                           arm that required `@` dropped that host silently
#                           while gh_rest_repo still resolved acme/repo — an
#                           Enterprise read sent to the default host (review r1).
gh_rest_host() {
    local remote="${1:-}" url="" host="" scheme="" name="" port=""

    if [ -z "${remote}" ]; then
        case "${GH_REPO:-}" in
        */*/*)
            printf '%s\n' "${GH_REPO%%/*}"
            return 0
            ;;
        esac
        if [ -n "${GH_HOST:-}" ]; then
            printf '%s\n' "${GH_HOST}"
            return 0
        fi
    fi
    if [ -z "${remote}" ]; then
        if git remote 2>/dev/null | grep -x origin >/dev/null; then
            remote=origin
        else
            remote="$(git remote 2>/dev/null | sed -n '1p')" || remote=""
        fi
    fi
    [ -n "${remote}" ] || return 0
    url="$(git remote get-url "${remote}" 2>/dev/null)" || return 0
    case "${url}" in
    *://*) # scheme://[user@]host[:port]/path
        scheme="${url%%://*}"
        host="${url#*://}" # drop the scheme
        host="${host%%/*}" # drop the path
        host="${host##*@}" # drop any userinfo
        # Keep an HTTP(S) port; drop any other scheme's transport port.
        case "${scheme}" in
        [Hh][Tt][Tt][Pp] | [Hh][Tt][Tt][Pp][Ss]) ;;
        *) host="${host%%:*}" ;;
        esac
        ;;
    *:*) # scp-like: [user@]host:owner/repo — the colon starts the path
        # Every scheme URL was taken by the arm above, so a colon surviving to
        # here is git's scp-like form by construction — which is exactly the
        # test gh_rest_repo already applies to the same URL. Matching `*:*` in
        # both is what keeps the pair from disagreeing about what a remote is.
        host="${url#*@}"   # drop any userinfo; a no-op when there is none
        host="${host%%:*}" # the first colon starts the path, so never a port
        ;;
    esac
    # Validate the name and any kept port separately. A single class over the
    # whole authority would have to admit `:`, and would then pass `ghe:8443:x`
    # and `:443`; splitting keeps the name exactly as strict as it was.
    name="${host}"
    case "${host}" in
    *:*)
        name="${host%:*}"
        port="${host##*:}"
        case "${port}" in '' | *[!0-9]*) return 0 ;; esac
        ;;
    esac
    case "${name}" in
    '' | *[!A-Za-z0-9.-]*) return 0 ;;
    esac
    printf '%s\n' "${host}"
}

# gh_rest_api ENDPOINT [gh-api options...] — one bounded REST read. Callers may
# set GH_REST_TIMEOUT; stock macOS uses gtimeout when coreutils provides it.
# The host is derived once per call (see the header) and passed as --hostname
# whenever it is neither empty nor github.com — unless it carries a port, which
# is refused with 5.
gh_rest_api() {
    local endpoint="$1" timeout_bin="" host
    shift
    host="${GH_REST_HOST-$(gh_rest_host)}"
    # ONE case decides what becomes of the derived host, and the arm that builds
    # --hostname is the LAST of the three. `case` runs the first match, so no
    # colon-bearing value can reach the flag unless the arm below it is deleted
    # first — which is why the invariant lives at this single construction site
    # rather than in each caller.
    #
    # `gh api --hostname ghe.example.com:8443` answers "error parsing
    # `--hostname`: invalid hostname" and exits BEFORE issuing the request
    # (verified on gh 2.98.0), so every read on a custom-port Enterprise
    # instance was a usage error for as long as the port travelled on. Challenge
    # r4 asked for it to travel, reasoning correctly that the port belongs to
    # the REST authority and never checking what the flag accepts; five rounds
    # missed it because the test stub accepted any hostname (integration r4).
    #
    # Refusing beats both alternatives. Trimming the port would send the read to
    # the DEFAULT port of that name, where a different server may answer for the
    # same instance — silently wrong, which is worse than not reading at all.
    # Passing it makes every read a parse error no caller can act on.
    case "${host}" in
    '' | github.com) ;;
    *:*)
        {
            printf 'gh-rest: %s: a GitHub host with a port is not addressable\n' "${host}"
            printf 'gh-rest: gh api --hostname rejects any colon-bearing value,\n'
            printf 'gh-rest: and gh auth login --hostname cannot store a\n'
            printf 'gh-rest: credential for such a host at all. To read this\n'
            printf 'gh-rest: instance, let gh resolve the host itself with\n'
            printf 'gh-rest:   GH_REST_HOST= GH_HOST=%s\n' "${host}"
            printf 'gh-rest: and GH_ENTERPRISE_TOKEN set — GH_HOST does keep a port.\n'
        } >&2
        return 5
        ;;
    *) set -- "$@" --hostname "${host}" ;;
    esac
    if [ -z "${GH_REST_TIMEOUT:-}" ]; then
        gh api "${endpoint}" "$@"
        return
    fi
    if command -v timeout >/dev/null 2>&1; then
        timeout_bin=timeout
    elif command -v gtimeout >/dev/null 2>&1; then
        timeout_bin=gtimeout
    fi
    if [ -n "${timeout_bin}" ]; then
        "${timeout_bin}" -k 1 "${GH_REST_TIMEOUT}" gh api "${endpoint}" "$@" </dev/null
    else
        gh api "${endpoint}" "$@" </dev/null
    fi
}

# gh_rest_max_pages — the validated GH_REST_MAX_PAGES ceiling (default 10).
# Prints the value; returns 2 when the export is not a positive integer. Zero
# is rejected on purpose: "no ceiling" is the unbounded walk this guards against.
gh_rest_max_pages() {
    local max_pages="${GH_REST_MAX_PAGES:-10}"
    case "${max_pages}" in '' | *[!0-9]* | 0*) return 2 ;; esac
    printf '%s\n' "${max_pages}"
}

# gh_rest_paginate_array ENDPOINT MAX_ITEMS [gh-api options...] — emit one JSON
# array document per explicit page. Consumers combine them with `jq -s add`.
# MAX_ITEMS is REQUIRED (returns 2 when missing or non-numeric — it is never
# guessed from an option that happens to follow the endpoint); 0 means "every
# page", still under the GH_REST_MAX_PAGES ceiling (returns 4 when a further
# page would exceed it). The endpoint may already contain a query string;
# per_page/page are always supplied explicitly.
#
# The requested per_page NEVER depends on how many items remain (review r1).
# These endpoints are OFFSET-paginated: page=2 means "skip one per_page window",
# not "whatever follows the items already read". Narrowing the request for a
# final short page therefore moves the window BACKWARDS — per_page=100&page=1
# then per_page=50&page=2 re-reads items 51-100 and never reads 101-150, so a
# MAX_ITEMS=150 walk returns 150 entries holding 100 distinct ones and reports
# success. The request size is fixed for the whole walk and the surplus is
# trimmed LOCALLY on the page that overshoots the bound, which leaves every
# offset coherent whatever MAX_ITEMS is.
gh_rest_paginate_array() {
    [ "$#" -ge 2 ] || return 2
    local endpoint="$1" max_items="$2" page=1 page_size=100 total=0
    local separator payload count max_pages
    shift 2
    case "${max_items}" in '' | *[!0-9]*) return 2 ;; esac
    max_pages="$(gh_rest_max_pages)" || return 2
    case "${endpoint}" in *\?*) separator='&' ;; *) separator='?' ;; esac
    # Clamped ONCE, before the walk, from the bound alone — never from the
    # remaining count — so a sub-page bound still costs one request for exactly
    # that many items. Constant, and positive, from here on.
    if [ "${max_items}" -gt 0 ] && [ "${max_items}" -lt "${page_size}" ]; then
        page_size="${max_items}"
    fi

    while :; do
        [ "${page}" -le "${max_pages}" ] || return 4
        payload="$(gh_rest_api "${endpoint}${separator}per_page=${page_size}&page=${page}" "$@")" || return
        jq -e 'type == "array"' >/dev/null 2>&1 <<<"${payload}" || return 3
        count="$(jq 'length' <<<"${payload}")" || return 3
        if [ "${max_items}" -gt 0 ] && [ "$((total + count))" -gt "${max_items}" ]; then
            # This page overshoots MAX_ITEMS: drop the surplus here, where it is
            # visible, rather than having asked for a smaller page.
            jq --argjson keep "$((max_items - total))" '.[0:$keep]' <<<"${payload}" || return 3
            return 0
        fi
        printf '%s\n' "${payload}"
        total=$((total + count))
        [ "${count}" -lt "${page_size}" ] && return 0
        [ "${max_items}" -gt 0 ] && [ "${total}" -ge "${max_items}" ] && return 0
        page=$((page + 1))
    done
}

# gh_rest_paginate_key ENDPOINT KEY [gh-api options...] — for paginated REST
# previews whose page is EITHER their array wrapped in an object under KEY (for
# example `issue_fields`) OR the bare array. Emits the array either way.
# Bounded by the same GH_REST_MAX_PAGES ceiling (returns 4 when exceeded).
#
# Both shapes are documented for the same preview, so betting on one made the
# other a failed read — and a failed read is rendered `unknown`, so a caller
# whose org really does have the fields would have been told nobody could see
# them (review r1). One selector serves every step of the walk, which is what
# keeps the validation, the count and the emitted page talking about the same
# value. Anything else selects null and still fails the read with 3: an error
# object is neither shape, and must not be walked as if it were empty.
gh_rest_paginate_key() {
    local endpoint="$1" key="$2" page=1 page_size=100 separator payload count max_pages
    local select='if type == "array" then . elif type == "object" then .[$key] else null end'
    shift 2
    max_pages="$(gh_rest_max_pages)" || return 2
    case "${endpoint}" in *\?*) separator='&' ;; *) separator='?' ;; esac
    while :; do
        [ "${page}" -le "${max_pages}" ] || return 4
        payload="$(gh_rest_api "${endpoint}${separator}per_page=${page_size}&page=${page}" "$@")" || return
        jq -e --arg key "${key}" "${select} | type == \"array\"" >/dev/null 2>&1 <<<"${payload}" || return 3
        count="$(jq --arg key "${key}" "${select} | length" <<<"${payload}")" || return 3
        jq --arg key "${key}" "${select}" <<<"${payload}"
        [ "${count}" -lt "${page_size}" ] && return 0
        page=$((page + 1))
    done
}
