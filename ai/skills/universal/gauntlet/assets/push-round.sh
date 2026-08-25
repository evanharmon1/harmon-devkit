#!/usr/bin/env bash
# Preflight and push one adjudicated gauntlet round, fail-closed.
#
# The gate-to-write binding follows shepherd/assets/require-marker.sh: the
# caller appends a run-unique token containing the gated SHA only after every
# required gate succeeds. This helper parses that verdict mechanically, then
# owns the ref-safety mechanics that prose repeatedly got wrong.

set -euo pipefail

usage() {
    cat >&2 <<'EOF'
Usage:
  push-round.sh preflight --remote NAME --branch NAME --host HOST --repo OWNER/REPO [-c NAME=VALUE]...
  push-round.sh push --remote NAME --branch NAME --host HOST --repo OWNER/REPO \
    --sha SHA --expect absent|OID --gate-file FILE --gate-token TOKEN \
    [-c NAME=VALUE]...

preflight is read-only. It requires the forge to report push permission and
prints the remote branch's current full object ID, or "absent", for use as the
next push's --expect value. It never runs git push --dry-run or a pre-push hook.

push exits successfully only when all of these hold:
  - GATE-FILE's last non-blank line exactly equals GATE-TOKEN;
  - GATE-TOKEN is unique to this run and names SHA;
  - SHA is the full commit ID currently checked out and the tree is clean;
  - the named remote has exactly one credential-free push destination, and it
    matches HOST and OWNER/REPO;
  - the named remote has no custom receive-pack command;
  - the remote branch still equals --expect and the update is fast-forward;
  - an explicit SHA refspec, lease, and --no-follow-tags update only the named
    branch.

Mint the token before the gate starts and append it only after every required
gate succeeds, following the shepherd marker contract:
  sha="$(git rev-parse HEAD)"
  token="GAUNTLET-GREEN-${sha}-$$"
  out="$(mktemp)"
  task verify >"$out" 2>&1 && task security:secrets >>"$out" 2>&1 \
    && printf '\n%s\n' "$token" >>"$out"

Each accepted -c NAME=VALUE is passed to destination resolution, ls-remote,
and push, so an
unprovisioned host can supply the repository's documented HTTPS transport
overrides without bypassing the named remote. The allowlist is deliberately
narrow: credential.helper, url.*.insteadOf, and protocol.*.allow. Config that
can redirect a push (including url.*.pushInsteadOf) is refused. VALUE may be
empty, as required to reset Git's credential-helper chain.

Exit status:
  0  preflight passed, or the gated commit was pushed/already current
  2  usage error
  3  refused before pushing; the reason is on stderr
  4  git push failed
  5  git reported success, but the remote could not be verified afterwards;
     reconcile before retrying because the push may have landed
EOF
}

die_usage() {
    printf 'push-round: %s\n' "$*" >&2
    usage
    exit 2
}

refuse() {
    printf 'push-round: refusing — %s\n' "$*" >&2
    exit 3
}

uncertain() {
    printf 'push-round: push may have landed — %s\n' "$*" >&2
    exit 5
}

[ "$#" -gt 0 ] || die_usage "a mode is required"
mode=$1
shift

case "$mode" in
preflight | push) ;;
-h | --help)
    usage
    exit 0
    ;;
*) die_usage "unknown mode: $mode" ;;
esac

remote=
branch=
host=
repo=
sha=
expect=
gate_file=
gate_token=
git_args=()
git_arg_count=0

# Bash 3.2 treats an empty indexed-array expansion as an unbound variable
# under `set -u`. Track the count separately so the helper never expands an
# empty array when no transport overrides are needed.
git_with_args() {
    if [ "$git_arg_count" -gt 0 ]; then
        git "${git_args[@]}" "$@"
    else
        git "$@"
    fi
}

while [ "$#" -gt 0 ]; do
    case "$1" in
    --remote)
        [ "$#" -ge 2 ] || die_usage "--remote needs a value"
        remote=$2
        shift 2
        ;;
    --branch)
        [ "$#" -ge 2 ] || die_usage "--branch needs a value"
        branch=$2
        shift 2
        ;;
    --host)
        [ "$#" -ge 2 ] || die_usage "--host needs a value"
        host=$2
        shift 2
        ;;
    --repo)
        [ "$#" -ge 2 ] || die_usage "--repo needs a value"
        repo=$2
        shift 2
        ;;
    --sha)
        [ "$#" -ge 2 ] || die_usage "--sha needs a value"
        sha=$2
        shift 2
        ;;
    --expect)
        [ "$#" -ge 2 ] || die_usage "--expect needs a value"
        expect=$2
        shift 2
        ;;
    --gate-file)
        [ "$#" -ge 2 ] || die_usage "--gate-file needs a value"
        gate_file=$2
        shift 2
        ;;
    --gate-token)
        [ "$#" -ge 2 ] || die_usage "--gate-token needs a value"
        gate_token=$2
        shift 2
        ;;
    -c)
        config_name=
        config_name_lower=
        [ "$#" -ge 2 ] || die_usage "-c needs NAME=VALUE"
        case "$2" in
        ?*=*) ;;
        *) die_usage "-c needs NAME=VALUE" ;;
        esac
        config_name=${2%%=*}
        config_name_lower="$(printf '%s' "$config_name" | tr '[:upper:]' '[:lower:]')"
        case "$config_name_lower" in
        credential.helper | url.*.insteadof | protocol.*.allow) ;;
        *) refuse "-c '$config_name' is not an approved transport-only override" ;;
        esac
        git_args+=("-c" "$2")
        git_arg_count=$((git_arg_count + 2))
        shift 2
        ;;
    -h | --help)
        usage
        exit 0
        ;;
    *) die_usage "unknown argument: $1" ;;
    esac
done

[ -n "$remote" ] || die_usage "--remote is required"
[ -n "$branch" ] || die_usage "--branch is required"
case "$remote" in
-* | *[!A-Za-z0-9._-]*) die_usage "--remote is not a safe remote name" ;;
esac
git check-ref-format "refs/heads/${branch}" >/dev/null 2>&1 ||
    die_usage "--branch is not a valid branch name"

[ -n "$host" ] || die_usage "--host is required"
[ -n "$repo" ] || die_usage "--repo is required"
case "$host" in
-* | */* | *[[:space:]]*) die_usage "--host is invalid" ;;
esac
case "$repo" in
*/*)
    owner=${repo%%/*}
    name=${repo#*/}
    [ -n "$owner" ] && [ -n "$name" ] || die_usage "--repo must be OWNER/REPO"
    case "$name" in */*) die_usage "--repo must be OWNER/REPO" ;; esac
    ;;
*) die_usage "--repo must be OWNER/REPO" ;;
esac

receivepack_rc=0
git config --get-all "remote.${remote}.receivepack" >/dev/null 2>&1 || receivepack_rc=$?
case "$receivepack_rc" in
0) refuse "the named remote has a custom receive-pack command" ;;
1) ;;
*) refuse "the named remote's receive-pack configuration is unreadable" ;;
esac

push_url=
resolve_push_url() {
    local output rc rest authority path destination_host expected_host

    push_url=
    rc=0
    # Resolve with the same approved transport configuration used by ls-remote
    # and push. In particular, get-url renders an insteadOf rewrite, so the URL
    # validated below is the effective destination rather than the configured
    # spelling that transport may later redirect.
    output="$(git_with_args remote get-url --push --all "$remote" 2>/dev/null)" || rc=$?
    [ "$rc" -eq 0 ] || refuse "the named remote has no readable push destination"
    [ -n "$output" ] || refuse "the named remote has no push destination"
    case "$output" in
    *$'\n'*) refuse "the named remote has more than one push destination" ;;
    *\?* | *\#*) refuse "the push destination contains a query or fragment" ;;
    esac

    destination_host=
    path=
    case "$output" in
    https://*)
        rest=${output#https://}
        case "$rest" in
        */*) ;;
        *) refuse "the HTTPS push destination has no repository path" ;;
        esac
        authority=${rest%%/*}
        path=${rest#*/}
        case "$authority" in
        *@*) refuse "the HTTPS push destination contains userinfo" ;;
        esac
        destination_host=$authority
        ;;
    git@*:*)
        rest=${output#git@}
        destination_host=${rest%%:*}
        path=${rest#*:}
        ;;
    ssh://git@*)
        rest=${output#ssh://git@}
        case "$rest" in
        */*) ;;
        *) refuse "the SSH push destination has no repository path" ;;
        esac
        authority=${rest%%/*}
        destination_host=${authority%%:*}
        path=${rest#*/}
        ;;
    *) refuse "the push destination is not a supported HTTPS or SSH URL" ;;
    esac

    path=${path%/}
    path=${path%.git}
    destination_host="$(printf '%s' "$destination_host" | tr '[:upper:]' '[:lower:]')"
    expected_host="$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')"
    case "$expected_host:$destination_host" in
    github.com:github.com | github.com:ssh.github.com) ;;
    *)
        [ "$destination_host" = "$expected_host" ] ||
            refuse "the push destination host does not match --host"
        ;;
    esac
    [ "$(printf '%s' "$path" | tr '[:upper:]' '[:lower:]')" = \
        "$(printf '%s' "$repo" | tr '[:upper:]' '[:lower:]')" ] ||
        refuse "the push destination repository does not match --repo"

    push_url=$output
}

resolve_push_url

remote_head=
remote_error=
read_remote_head() {
    local output rc oid ref extra

    remote_head=
    remote_error=
    rc=0
    output="$(git_with_args ls-remote "$push_url" "refs/heads/${branch}" 2>/dev/null)" || rc=$?
    if [ "$rc" -ne 0 ]; then
        remote_error="git ls-remote failed (exit ${rc}); the remote head is unknown"
        return 1
    fi
    if [ -z "$output" ]; then
        remote_head=absent
        return 0
    fi
    case "$output" in
    *$'\n'*)
        remote_error="git ls-remote returned more than one match for the branch"
        return 1
        ;;
    esac
    read -r oid ref extra <<<"$output"
    if [ -n "${extra:-}" ] || [ "$ref" != "refs/heads/${branch}" ]; then
        remote_error="git ls-remote returned an invalid branch record"
        return 1
    fi
    case "$oid" in
    '' | *[!0-9a-f]*)
        remote_error="git ls-remote returned an invalid object ID"
        return 1
        ;;
    esac
    case "${#oid}" in
    40 | 64) ;;
    *)
        remote_error="git ls-remote returned a non-full object ID"
        return 1
        ;;
    esac
    remote_head=$oid
}

if [ "$mode" = preflight ]; then
    [ -z "$sha$expect$gate_file$gate_token" ] ||
        die_usage "push-only arguments are not valid in preflight mode"

    permission_rc=0
    permission="$(gh api --hostname "$host" "repos/${repo}" --jq '.permissions.push' 2>/dev/null)" ||
        permission_rc=$?
    [ "$permission_rc" -eq 0 ] ||
        refuse "the forge permission query failed (exit ${permission_rc})"
    [ "$permission" = true ] ||
        refuse "the forge did not report push permission"
    read_remote_head || refuse "$remote_error"
    printf '%s\n' "$remote_head"
    exit 0
fi

[ -n "$sha" ] || die_usage "push requires --sha"
[ -n "$expect" ] || die_usage "push requires --expect"
[ -n "$gate_file" ] || die_usage "push requires --gate-file"
[ -n "$gate_token" ] || die_usage "push requires --gate-token"

resolved="$(git rev-parse --verify --quiet "${sha}^{commit}" || true)"
[ -n "$resolved" ] || refuse "--sha is not a commit in this repository"
[ "$resolved" = "$sha" ] || refuse "--sha is not a full commit ID"

case "$expect" in
absent) ;;
'' | *[!0-9a-f]*) die_usage "--expect must be absent or a full object ID" ;;
*)
    case "${#expect}" in
    40 | 64) ;;
    *) die_usage "--expect must be absent or a full object ID" ;;
    esac
    ;;
esac

nl='
'
case "$gate_token" in
'' | *"$nl"*) die_usage "--gate-token must be one non-empty line" ;;
[[:space:]]* | *[[:space:]]) die_usage "--gate-token must not have surrounding whitespace" ;;
esac
token_prefix="GAUNTLET-GREEN-${sha}-"
case "$gate_token" in
"${token_prefix}"?*) ;;
*) refuse "the gate token is not bound to this SHA and run" ;;
esac
[ -f "$gate_file" ] && [ -r "$gate_file" ] ||
    refuse "the gate output is not a readable regular file"
marker="$(awk '
    {
        sub(/^[[:space:]]+/, "")
        sub(/[[:space:]]+$/, "")
        if ($0 != "") last = $0
    }
    END { if (last != "") print last }
' "$gate_file")" || refuse "the gate output could not be read"
[ -n "$marker" ] || refuse "the gate output has no marker line"
[ "$marker" = "$gate_token" ] || refuse "the gate marker does not equal this run's token"

head_sha="$(git rev-parse HEAD)"
[ "$head_sha" = "$resolved" ] ||
    refuse "HEAD moved after the gate; gate the current commit before pushing"
status_rc=0
status_output="$(git status --porcelain --untracked-files=all 2>/dev/null)" || status_rc=$?
[ "$status_rc" -eq 0 ] ||
    refuse "git status failed after the gate; worktree cleanliness is unknown"
[ -z "$status_output" ] ||
    refuse "the worktree changed during the gate; commit and re-gate before pushing"

read_remote_head || refuse "$remote_error"
[ "$remote_head" = "$expect" ] ||
    refuse "the remote branch moved from expected '${expect}' to '${remote_head}'; reconcile before pushing"

if [ "$remote_head" = "$resolved" ]; then
    printf 'push-round: %s/%s is already at the gated commit\n' "$remote" "$branch" >&2
    exit 0
fi

if [ "$expect" != absent ]; then
    git merge-base --is-ancestor "$expect" "$resolved" 2>/dev/null ||
        refuse "the expected remote head is not an ancestor of the gated commit"
    lease="--force-with-lease=refs/heads/${branch}:${expect}"
else
    lease="--force-with-lease=refs/heads/${branch}:"
fi

if ! git_with_args push --no-follow-tags \
    "$remote" "${resolved}:refs/heads/${branch}" "$lease"; then
    exit 4
fi

read_remote_head || uncertain "$remote_error"
[ "$remote_head" = "$resolved" ] ||
    uncertain "the remote branch is '${remote_head}', not the gated commit '${resolved}'"

exit 0
