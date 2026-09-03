#!/usr/bin/env bash
# round-push.sh — repository-owned, diff-aware round-push broker for Dev flow
# v2 (specs/dev-flow-v2.md § Configuration "Gates are repository-owned
# Taskfile target slugs" / "Gate authority separates policy from branch
# implementation"; openspec/changes/dev-flow-v2/specs/config/spec.md).
#
# This is the SUCCESSOR to ai/skills/universal/gauntlet/assets/push-round.sh
# for repositories that have migrated `.devflow.toml` to schema_version = 2.
# That older helper is untouched and stays legacy-only (its own gauntlet
# procedure never resolves policy at all); this script instead:
#
#   1. re-derives the merge-base diff class (docs-only vs. code) from the
#      diff itself, never from a caller's assertion;
#   2. resolves `[gates]` and `docs_only_paths` via scripts/devflow-policy.mjs
#      against a CLOSURE the caller has already materialized outside the
#      feature worktree (git show/git archive <merge-base>:<path>) — this
#      script never resolves a worktree-resident policy, registry, or
#      scanner file itself; every closure-resident input arrives as an
#      explicit path;
#   3. requires the caller's gate marker to be bound to BOTH the exact head
#      and the required target for that diff class (round_code or
#      round_docs), refusing a weaker marker over a stronger-required diff;
#   4. runs the secret scanner itself, unconditionally, via the closure's own
#      gitleaks-scan.sh + .gitleaks.toml (never the worktree's, so a branch
#      cannot weaken the scan that gates its own push);
#   5. then performs the same ref-safety-checked push as the older helper
#      (single writable remote, fast-forward-only, no destination rewrite,
#      no receive-pack override, explicit refspec, no follow-tags).
#
# The configured ROUND gate itself (`task verify` / `task check`) is
# deliberately NOT part of the closure: the caller runs it from the feature
# worktree and this script only validates the marker it produced — that
# result is branch-attested evidence, never CI-authoritative (config spec
# "Gate authority separates policy from branch implementation").
#
# Bootstrap note (for whatever materializes the closure, not for this script
# itself): a merge base predating this file's own introduction holds only
# the older skill-asset copy of the broker; that caller falls back to
# extracting and running THAT copy, unchanged, for a change structurally
# like this one. A merge base holding neither copy has nothing to extract
# and the round-push gate cannot run at all.

set -euo pipefail

usage() {
    cat >&2 <<'EOF'
Usage:
  round-push.sh preflight --remote NAME --branch NAME --host HOST --repo OWNER/REPO [-c NAME=VALUE]...

  round-push.sh plan --against REF --policy FILE --devflow-policy-script FILE \
    [--sha SHA] [--rigor LEVEL] [--strategy NAME] \
    [--registry FILE] [--task-targets FILE] [--taskfile-dir DIR] [--json]

  round-push.sh push --remote NAME --branch NAME --host HOST --repo OWNER/REPO \
    --sha SHA --expect absent|OID --gate-file FILE --gate-token TOKEN \
    --against REF --policy FILE --devflow-policy-script FILE \
    --gitleaks-script FILE --gitleaks-config FILE \
    [--rigor LEVEL] [--strategy NAME] \
    [--registry FILE] [--task-targets FILE] [--taskfile-dir DIR] \
    [-c NAME=VALUE]...

preflight is read-only, identical to the older gauntlet helper: it requires
the forge to report push permission and prints the remote branch's current
full object ID, or "absent", for use as the next push's --expect value.

--against REF names the target branch the diff is classified against
(e.g. `origin/main`) — a SYMBOLIC REF, never a bare commit ID or a
revision expression: `git rev-parse --symbolic-full-name --verify` must
resolve it to an actual `refs/*` name. A raw 40/64-hex object ID fails
this (it names no ref at all), and so does `HEAD~1`, `HEAD^`, or any other
`~`/`^`/`@{...}` expression (Codex review round 1, confirmed: rejecting
only hex-shaped values left exactly this class unrejected — a revision
expression is just as capable of naming an arbitrary, too-close commit as
a bare SHA is, and resolves to no symbolic name of its own). plan and push
both derive the merge base themselves via
`git merge-base "$against" "$target"`, resolving --against fresh at
computation time rather than accepting a pre-computed commit ID. This is
a real but partial improvement, stated precisely rather than oversold: it
correctly handles a --against that is not an ancestor of --sha (a
diverged or unrelated ref, which the ancestor-gated design this replaced
could only refuse outright), and it closes off asserting anything with no
binding to an actual named ref. It does NOT and cannot, by itself, prove
the NAMED ref is the semantically correct target — that a caller passes
`--against origin/main` and means it is a trust boundary this script
cannot verify from inside, exactly like the closure files' own provenance
below: the caller (a future integration stage skill) is responsible for
resolving --against from the actual target branch, never from anything
the pushing branch's own content or config could steer.

plan re-derives the diff class between the merge base of --against and
--sha (default HEAD) and resolves the required gate target for it, so a
caller knows which `task <target>` to run before minting a gate token. It
touches no marker, scanner, or remote and never pushes.

--registry and one of --task-targets/--taskfile-dir are not bash-enforced
as usage errors, but omitting either leaves devflow-policy.mjs's own
cross-validation indeterminate, which both plan and push treat as a hard
refusal — there is no code path that resolves policy successfully without
them.

push additionally requires:
  - GATE-FILE's last non-blank line to exactly equal GATE-TOKEN;
  - GATE-TOKEN to be unique to this run and to name both SHA and the
    RECOMPUTED required target for the diff between --against's merge
    base and SHA — never the caller's own assertion of either;
  - the closure's secret scanner (--gitleaks-script, configured with
    --gitleaks-config) to exit clean against the current worktree;
  - the same ref-safety conditions as the older gauntlet push helper: SHA is
    the full commit ID currently checked out and the tree is clean; the
    named remote has exactly one credential-free push destination matching
    HOST and OWNER/REPO and no custom receive-pack command; the remote
    branch still equals --expect and the update is fast-forward; an explicit
    SHA refspec, lease, and --no-follow-tags update only the named branch.

Mint the gate token only after policy resolution names the required target
(round-push.sh plan, or equivalent), then run exactly that Taskfile target,
following the shepherd marker contract:
  sha="$(git rev-parse HEAD)"
  target="<round_code or round_docs, from plan's output>"
  token="ROUND-GREEN-${sha}-${target}-$$"
  out="$(mktemp)"
  task "$target" >"$out" 2>&1 && printf '\n%s\n' "$token" >>"$out"

Each accepted -c NAME=VALUE is passed to destination resolution, ls-remote,
and push, so an unprovisioned host can supply the repository's documented
HTTPS transport overrides without bypassing the named remote. The allowlist
is deliberately narrow: credential.helper, url.*.insteadOf, and
protocol.*.allow. Config that can redirect a push (including
url.*.pushInsteadOf) is refused. VALUE may be empty, as required to reset
Git's credential-helper chain.

Exit status:
  0  preflight/plan succeeded, or the gated commit was pushed/already current
  2  usage error
  3  refused before pushing; the reason is on stderr
  4  git push failed
  5  git reported success, but the remote could not be verified afterwards;
     reconcile before retrying because the push may have landed
EOF
}

die_usage() {
    printf 'round-push: %s\n' "$*" >&2
    usage
    exit 2
}

refuse() {
    printf 'round-push: refusing — %s\n' "$*" >&2
    exit 3
}

uncertain() {
    printf 'round-push: push may have landed — %s\n' "$*" >&2
    exit 5
}

[ "$#" -gt 0 ] || die_usage "a mode is required"
mode=$1
shift

case "$mode" in
preflight | plan | push) ;;
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
against=
policy=
devflow_policy_script=
gitleaks_script=
gitleaks_config=
registry=
task_targets=
taskfile_dir=
rigor=
strategy=
want_json=0
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
    --against)
        [ "$#" -ge 2 ] || die_usage "--against needs a value"
        against=$2
        shift 2
        ;;
    --policy)
        [ "$#" -ge 2 ] || die_usage "--policy needs a value"
        policy=$2
        shift 2
        ;;
    --devflow-policy-script)
        [ "$#" -ge 2 ] || die_usage "--devflow-policy-script needs a value"
        devflow_policy_script=$2
        shift 2
        ;;
    --gitleaks-script)
        [ "$#" -ge 2 ] || die_usage "--gitleaks-script needs a value"
        gitleaks_script=$2
        shift 2
        ;;
    --gitleaks-config)
        [ "$#" -ge 2 ] || die_usage "--gitleaks-config needs a value"
        gitleaks_config=$2
        shift 2
        ;;
    --registry)
        [ "$#" -ge 2 ] || die_usage "--registry needs a value"
        registry=$2
        shift 2
        ;;
    --task-targets)
        [ "$#" -ge 2 ] || die_usage "--task-targets needs a value"
        task_targets=$2
        shift 2
        ;;
    --taskfile-dir)
        [ "$#" -ge 2 ] || die_usage "--taskfile-dir needs a value"
        taskfile_dir=$2
        shift 2
        ;;
    --rigor)
        [ "$#" -ge 2 ] || die_usage "--rigor needs a value"
        rigor=$2
        shift 2
        ;;
    --strategy)
        [ "$#" -ge 2 ] || die_usage "--strategy needs a value"
        strategy=$2
        shift 2
        ;;
    --json)
        want_json=1
        shift
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

# ---------------------------------------------------------------------------
# Policy resolution and diff classification — shared by `plan` and `push`.
# ---------------------------------------------------------------------------

# Prints the set of paths that changed between the TRUE merge base of
# --against and the target commit (default HEAD), one per line. Requires
# the current working directory to be a real checkout of the feature
# branch: the closure has no git history to diff, only extracted files.
#
# The merge base is derived here, never accepted as a caller-supplied
# value: Codex challenge round 2, confirmed — an earlier revision took an
# explicit --merge-base SHA and only checked it was SOME ancestor of the
# target, which a caller (or a bug) could satisfy with any earlier
# ancestor, narrowing or emptying the diff and letting a code change
# classify as docs-only. `git merge-base "$against" "$target"` computes the
# one true common ancestor deterministically, leaving no value for a
# caller to substitute. --against should be a SHA resolved before the
# closure was extracted (e.g. `git rev-parse origin/main`), not a live
# branch name, so this computation cannot race a moving branch between
# extraction and classification.
#
# --no-renames is required, not cosmetic: with rename detection on (git's
# own default), a 100%-similar rename reports ONLY the destination path —
# renaming code/foo.sh to docs/foo.md would then classify as docs-only
# with the source path outside docs_only_paths entirely invisible to the
# classifier below, accepting the weaker round_docs gate for what is still
# code content. --no-renames reports a rename as a delete of the old path
# plus an add of the new one, so both sides are checked against
# docs_only_paths.
changed_paths() {
    local target=$1 mb

    mb="$(git_with_args merge-base "$against" "$target" 2>/dev/null)" ||
        refuse "could not compute a merge base between --against (${against}) and ${target}"
    git_with_args diff --no-renames --name-only "${mb}..${target}"
}

# --against must be a symbolic ref (e.g. origin/main), never a bare commit
# ID: a raw SHA carries no target-branch identity, so a caller (or a bug)
# could assert an arbitrary, deliberately-too-close ancestor commit
# directly, narrowing the diff with no binding to any actual branch.
# Requiring a name does not by itself prove the name is the CORRECT
# target — see the usage text's "trust boundary" note — but it does
# require the value to resolve through git's own ref namespace rather
# than being an opaque, disconnected commit ID.
require_against_is_ref() {
    local resolved rc=0

    resolved="$(git_with_args rev-parse --symbolic-full-name --verify --quiet "$against" 2>/dev/null)" || rc=$?
    case "$resolved" in
    refs/*) [ "$rc" -eq 0 ] && return 0 ;;
    esac
    die_usage "--against must resolve to an actual ref (e.g. origin/main), not a bare commit ID or a revision expression like HEAD~1"
}

# Matches a single repo-root-relative PATH against one docs_only_paths glob
# PATTERN. Plain case/fnmatch semantics already treat a trailing `/**` (or
# any repeated `*`) as "any remainder including further slashes", so
# `docs/**` needs no special handling. A LEADING `**/` is the one case that
# needs help: as a literal case pattern it requires an actual `/` before the
# rest, which would wrongly exclude a root-level file (`AGENTS.md` should
# match `**/*.md`) — so a leading `**/` is also tried with zero directories.
docs_glob_match() {
    local pattern=$1 path=$2 rest
    # shellcheck disable=SC2254  # unquoted on purpose: glob match
    case "$path" in
    $pattern) return 0 ;;
    esac
    case "$pattern" in
    '**/'*)
        rest=${pattern#'**/'}
        # shellcheck disable=SC2254  # unquoted on purpose: glob match
        case "$path" in
        $rest) return 0 ;;
        esac
        ;;
    esac
    return 1
}

# Reads docs_only_paths (one pattern per line) from FILE and echoes "docs" or
# "code" for the changed paths listed in PATHS_FILE. Empty PATHS_FILE (no
# changed paths at all) is vacuously docs: nothing changed outside the
# allowlist because nothing changed.
classify_diff() {
    local patterns_file=$1 paths_file=$2 path matched pattern

    while IFS= read -r path; do
        [ -n "$path" ] || continue
        matched=0
        while IFS= read -r pattern; do
            [ -n "$pattern" ] || continue
            if docs_glob_match "$pattern" "$path"; then
                matched=1
                break
            fi
        done <"$patterns_file"
        if [ "$matched" -ne 1 ]; then
            echo code
            return 0
        fi
    done <"$paths_file"
    echo docs
}

# Invokes the closure-extracted devflow-policy.mjs `resolve --json` and
# leaves its parsed JSON at RESOLVED_JSON. Every closure-resident input is an
# explicit path this script was handed — never inferred, never
# worktree-resident. A non-zero exit (shape refusal, hard cross-validation
# error, or indeterminate cross-validation) is treated identically: a hard
# refusal to push, never a silent fallback.
resolved_json=
resolve_policy() {
    local out rc=0 args=(resolve --policy "$policy" --json)

    [ -z "$rigor" ] || args+=(--rigor "$rigor")
    [ -z "$strategy" ] || args+=(--strategy "$strategy")
    [ -z "$registry" ] || args+=(--registry "$registry")
    [ -z "$task_targets" ] || args+=(--task-targets "$task_targets")
    [ -z "$taskfile_dir" ] || args+=(--taskfile-dir "$taskfile_dir")

    out="$(node "$devflow_policy_script" "${args[@]}" 2>&1)" || rc=$?
    if [ "$rc" -ne 0 ]; then
        refuse "policy resolution failed (exit ${rc}): ${out}"
    fi
    resolved_json=$out
}

# Prints the required Taskfile target slug for DIFF_CLASS ("docs" or "code")
# from the already-resolved policy JSON.
required_target_for() {
    local diff_class=$1
    case "$diff_class" in
    docs) jq -r '.gates.round_docs' <<<"$resolved_json" ;;
    code) jq -r '.gates.round_code' <<<"$resolved_json" ;;
    *) die_usage "unknown diff class: $diff_class" ;;
    esac
}

# ---------------------------------------------------------------------------
# Shared push-url / remote-head helpers, unchanged from the gauntlet helper.
# ---------------------------------------------------------------------------

push_url=
resolve_push_url() {
    local output rc=0 rest authority path destination_host expected_host

    push_url=
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

remote_head=
remote_error=
read_remote_head() {
    local output rc=0 oid ref extra

    remote_head=
    remote_error=
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

# ---------------------------------------------------------------------------
# Mode dispatch
# ---------------------------------------------------------------------------

if [ "$mode" = preflight ]; then
    [ -z "$sha$expect$gate_file$gate_token$against$policy" ] ||
        die_usage "push/plan-only arguments are not valid in preflight mode"
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

    resolve_push_url
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

if [ "$mode" = plan ]; then
    [ -n "$against" ] || die_usage "plan requires --against"
    require_against_is_ref
    [ -n "$policy" ] || die_usage "plan requires --policy"
    [ -n "$devflow_policy_script" ] || die_usage "plan requires --devflow-policy-script"
    target=${sha:-HEAD}

    paths_file="$(mktemp)"
    patterns_file="$(mktemp)"
    trap 'rm -f "$paths_file" "$patterns_file"' EXIT
    changed_paths "$target" >"$paths_file"

    resolve_policy
    jq -r '.gates.docs_only_paths[]' <<<"$resolved_json" >"$patterns_file"
    diff_class="$(classify_diff "$patterns_file" "$paths_file")"
    required_target="$(required_target_for "$diff_class")"
    resolved_sha="$(git rev-parse --verify --quiet "${target}^{commit}" || true)"

    if [ "$want_json" -eq 1 ]; then
        jq -n --arg sha "$resolved_sha" --arg class "$diff_class" --arg target "$required_target" \
            '{sha: $sha, diff_class: $class, required_target: $target}'
    else
        echo "sha: ${resolved_sha}"
        echo "diff class: ${diff_class}"
        echo "required target: ${required_target}"
    fi
    exit 0
fi

# mode = push
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
[ -n "$sha" ] || die_usage "push requires --sha"
[ -n "$expect" ] || die_usage "push requires --expect"
[ -n "$gate_file" ] || die_usage "push requires --gate-file"
[ -n "$gate_token" ] || die_usage "push requires --gate-token"
[ -n "$against" ] || die_usage "push requires --against"
require_against_is_ref
[ -n "$policy" ] || die_usage "push requires --policy"
[ -n "$devflow_policy_script" ] || die_usage "push requires --devflow-policy-script"
[ -n "$gitleaks_script" ] || die_usage "push requires --gitleaks-script"
[ -n "$gitleaks_config" ] || die_usage "push requires --gitleaks-config"

receivepack_rc=0
git config --get-all "remote.${remote}.receivepack" >/dev/null 2>&1 || receivepack_rc=$?
case "$receivepack_rc" in
0) refuse "the named remote has a custom receive-pack command" ;;
1) ;;
*) refuse "the named remote's receive-pack configuration is unreadable" ;;
esac

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

# Recompute the diff class and required target ourselves — never trust a
# caller-supplied target (config spec "Gates are repository-owned Taskfile
# target slugs": "The push broker SHALL recompute the diff classification
# rather than trust the caller's assertion").
paths_file="$(mktemp)"
patterns_file="$(mktemp)"
trap 'rm -f "$paths_file" "$patterns_file"' EXIT
changed_paths "$sha" >"$paths_file"
resolve_policy
jq -r '.gates.docs_only_paths[]' <<<"$resolved_json" >"$patterns_file"
diff_class="$(classify_diff "$patterns_file" "$paths_file")"
required_target="$(required_target_for "$diff_class")"

# The marker binds this exact SHA and the RECOMPUTED required target — a
# docs-class marker presented for a diff that recomputes to "code" (or any
# target the policy did not name for this diff class) fails this prefix
# match, refusing before the gate file's contents are even read.
token_prefix="ROUND-GREEN-${sha}-${required_target}-"
case "$gate_token" in
"${token_prefix}"?*) ;;
*) refuse "the gate token is not bound to this SHA and its required target (${required_target})" ;;
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

# Secret scan runs unconditionally, every push, via the closure's own
# extracted scanner and config — never the round gate's marker, and never
# the worktree's .gitleaks.toml. Config spec "Gate authority separates
# policy from branch implementation": "the orchestrator SHALL materialize
# outside the feature worktree and execute the merge-base implementations of
# both the secret scan and the round-push broker."
if ! "$gitleaks_script" --config "$gitleaks_config"; then
    refuse "the closure-extracted secret scan found findings or failed to run"
fi

head_sha="$(git rev-parse HEAD)"
[ "$head_sha" = "$resolved" ] ||
    refuse "HEAD moved after the gate; gate the current commit before pushing"
status_rc=0
status_output="$(git status --porcelain --untracked-files=all 2>/dev/null)" || status_rc=$?
[ "$status_rc" -eq 0 ] ||
    refuse "git status failed after the gate; worktree cleanliness is unknown"
[ -z "$status_output" ] ||
    refuse "the worktree changed during the gate; commit and re-gate before pushing"

resolve_push_url
read_remote_head || refuse "$remote_error"
[ "$remote_head" = "$expect" ] ||
    refuse "the remote branch moved from expected '${expect}' to '${remote_head}'; reconcile before pushing"

if [ "$remote_head" = "$resolved" ]; then
    printf 'round-push: %s/%s is already at the gated commit\n' "$remote" "$branch" >&2
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
