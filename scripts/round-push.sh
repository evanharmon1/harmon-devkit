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
#      explicit path, and every one of those paths is itself verified
#      against the closure's own `git show <closure-base>:<path>` blob
#      before anything reads it, so --closure-base pins content, not just
#      the diff boundary (Codex review, confirmed — see
#      verify_closure_member's own comment);
#   3. EXECUTES the required target for that diff class (round_code or
#      round_docs) itself, from the feature worktree, rather than
#      validating a marker a caller produced — a caller-supplied
#      gate-file/gate-token pair proves nothing was actually run (Codex
#      review, confirmed: the broker's own test helper demonstrated the
#      bypass by fabricating both directly before a successful push); the
#      broker instead emits its own marker as OUTPUT, bound to the gated
#      head and diff class, purely as evidence — never as an input;
#   4. runs the secret scanner itself, unconditionally, via the closure's own
#      gitleaks-scan.sh + .gitleaks.toml (never the worktree's, so a branch
#      cannot weaken the scan that gates its own push);
#   5. then performs the same ref-safety-checked push as the older helper
#      (single writable remote, fast-forward-only, no destination rewrite,
#      no receive-pack override, explicit refspec, no follow-tags), writing
#      to the exact validated push URL rather than re-resolving the mutable
#      named remote at write time.
#
# Bootstrap note (for whatever materializes the closure, not for this script
# itself): a merge base predating this file's own introduction holds only
# the older skill-asset copy of the broker; that caller falls back to
# extracting and running THAT copy, unchanged, for a change structurally
# like this one. A merge base holding neither copy has nothing to extract
# and the round-push gate cannot run at all.
#
# Known, documented limitation (declined, not silently ignored): resolving
# policy during an ACTUAL legacy/v1 -> v2 `.devflow.toml` migration commit
# needs devflow-policy.mjs's `--merge-base-policy` historical-decode path,
# which this script does not thread through — out of scope under the
# maintainer's 2026-09-02 ruling that migration fidelity is low priority
# for this milestone (matching the #666 lane's identical disposition for
# devflow-policy.mjs's own decoder-fidelity gap). This repo has not
# migrated yet, so the gap cannot manifest today.

set -euo pipefail

usage() {
    cat >&2 <<'EOF'
Usage:
  round-push.sh preflight --remote NAME --branch NAME --host HOST --repo OWNER/REPO [-c NAME=VALUE]...

  round-push.sh plan --against REF --closure-base SHA \
    --policy FILE --devflow-policy-script FILE \
    [--sha SHA] [--rigor LEVEL] [--strategy NAME] \
    [--registry FILE] [--task-targets FILE] [--taskfile-dir DIR] [--json]

  round-push.sh push --remote NAME --branch NAME --host HOST --repo OWNER/REPO \
    --sha SHA --expect absent|OID \
    --against REF --closure-base SHA \
    --policy FILE --devflow-policy-script FILE \
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

--closure-base SHA is the exact commit the caller's --policy/--registry/
--gitleaks-config closure was materialized from (the same SHA a
`git show <closure-base>:<path>` extraction used) — a FULL commit ID,
never a ref: the whole point is pinning one exact commit, not whatever a
moving name resolves to right now. plan and push both refuse unless the
merge base freshly computed from --against equals --closure-base exactly
(Codex review round 2, confirmed: --against is resolved fresh at
invocation time, so a ref that moved between closure extraction and this
run — another worktree fetching and advancing origin/main, say — would
otherwise classify the diff against a DIFFERENT commit than the one whose
policy/scanner config the closure actually holds, enforcing stale,
possibly weaker gate policy against a freshly-and-differently-computed
diff boundary; config spec "Gate authority separates policy from branch
implementation": "Merge-base resolution SHALL determine gate policy").

plan re-derives the diff class between the merge base of --against and
--sha (default HEAD) and resolves the required gate target for it, so a
caller knows which `task <target>` to run before minting a gate token. It
touches no marker, scanner, or remote and never pushes.

--registry and one of --task-targets/--taskfile-dir are not bash-enforced
as usage errors, but omitting either leaves devflow-policy.mjs's own
cross-validation indeterminate, which both plan and push treat as a hard
refusal — there is no code path that resolves policy successfully without
them.

preflight/plan/push each refuse any option that belongs only to one of the
other two modes (e.g. --json in push, --gitleaks-config in plan,
--policy in preflight) — a misplaced mode or flag is refused up front
rather than silently ignored.

push additionally requires:
  - --branch to name the worktree's own checked-out branch — never merely a
    syntactically valid one — so a stale or mistyped --branch naming some
    other branch (e.g. main) can't send the checked-out SHA there instead;
  - --policy, --devflow-policy-script, and --registry (when given) to each
    match, byte for byte, the blob at their canonical repository path in
    --closure-base (verified via `git show`) before any of them is read
    for any other purpose; devflow-policy.mjs's own transitive dependency
    scripts/lib/toml-lite.mjs (resolved the same way Node resolves it,
    relative to --devflow-policy-script's own directory) is verified the
    same way, before policy resolution ever runs;
  - the required Taskfile target for the recomputed diff class (round_code
    or round_docs) to exit 0 when this script runs it itself, from the
    feature worktree, inheriting this script's own stdout/stderr — there
    is no caller-supplied marker to validate instead; the script prints
    its own `ROUND-GREEN-<sha>-<target>-<class>` line to stdout as
    evidence once this and the scan below both pass, never as something
    it reads back;
  - --gitleaks-script, --gitleaks-config, and gitleaks-scan.sh's own
    transitive dependency scripts/summarize-gitleaks.mjs (resolved
    relative to --gitleaks-script's own directory) to each match
    --closure-base the same way, checked immediately before the scan
    below reads them — after the required target above has already run,
    since that is branch-controlled code with a real chance to tamper
    with closure-resident files living outside the worktree, where
    `git status` cannot see it; the closure's .gitleaksignore (beside
    --gitleaks-config, since there is no --gitleaksignore flag of its
    own) is checked the same way, in both directions — a merge base with
    none must mean the closure has none either;
  - the closure's secret scanner (--gitleaks-script, configured with
    --gitleaks-config) to exit clean against the current worktree;
  - the same ref-safety conditions as the older gauntlet push helper: SHA is
    the full commit ID currently checked out and the tree is clean; the
    named remote has exactly one credential-free push destination matching
    HOST and OWNER/REPO and no custom receive-pack command; the remote
    branch still equals --expect and the update is fast-forward; an explicit
    SHA refspec, lease, and --no-follow-tags update only the named branch;
  - the push destination AND the SSH transport override (core.sshCommand,
    plus any inherited GIT_SSH_COMMAND/GIT_SSH) to both still match what
    was validated BEFORE the required target ran, checked again
    immediately before the actual write — git re-applies url.*.insteadOf/
    pushInsteadOf rewriting at push time regardless of whether the
    destination came from a named remote or a literal URL, and a
    branch-controlled gate can install its own core.sshCommand override
    via a plain `git config` call that never touches a tracked file,
    silently redirecting the connection regardless of the validated
    hostname; either check can only shrink the window a change could land
    in, never make git's own resolution atomic.

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
against=
closure_base=
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
    --against)
        [ "$#" -ge 2 ] || die_usage "--against needs a value"
        against=$2
        shift 2
        ;;
    --closure-base)
        [ "$#" -ge 2 ] || die_usage "--closure-base needs a value"
        closure_base=$2
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
# caller to substitute. --against stays a named ref (e.g. `origin/main`)
# even when the caller resolved it to a SHA before extracting the
# closure — require_against_is_ref below refuses a bare commit ID here on
# purpose; that resolved SHA is what --closure-base carries instead, so
# the two flags together still pin the exact commit the closure came from
# without letting --against itself be a disconnected object ID.
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
    # The freshly computed merge base must be the EXACT commit the caller's
    # closure was materialized from — config spec "Gate authority separates
    # policy from branch implementation": "Merge-base resolution SHALL
    # determine gate policy." Codex review round 2, confirmed: without this
    # check, --against is resolved fresh at invocation time, so if the
    # named ref moved between closure extraction and this run (another
    # worktree fetched and advanced origin/main, say), the diff would be
    # classified against a DIFFERENT commit than the one whose
    # .devflow.toml/docs_only_paths actually govern the closure files this
    # run was handed — enforcing stale, possibly weaker policy against a
    # freshly (and differently) computed diff boundary.
    [ "$mb" = "$closure_base" ] ||
        refuse "the merge base computed from --against (${mb}) does not match --closure-base (${closure_base}); the closure and the diff boundary must share one authority"
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

# --closure-base must be the full commit ID the caller's closure was
# materialized from (the same SHA a `git show <closure-base>:<path>`
# extraction used) — a symbolic ref here would defeat its own purpose,
# since the whole point is to pin the ONE exact commit, never whatever a
# moving name currently resolves to.
require_closure_base_is_full_sha() {
    case "$closure_base" in
    '' | *[!0-9a-f]*) die_usage "--closure-base must be a full commit ID" ;;
    esac
    case "${#closure_base}" in
    40 | 64) ;;
    *) die_usage "--closure-base must be a full commit ID" ;;
    esac
}

# Matches a single repo-root-relative PATH against one docs_only_paths glob
# PATTERN. Plain case/fnmatch semantics already treat a bare `*` (and so a
# redundant `**`) as "any remainder including further slashes", which is
# exactly "one or more directories" for a `**/` segment — the case that
# needs help is "zero directories", since the LITERAL `/` immediately after
# `**` in the pattern text requires an actual `/` in the input at that
# point, which a direct-child path doesn't have (`**/*.md` must still match
# root-level `AGENTS.md`; `docs/**/*.md` must still match the direct child
# `docs/readme.md`, not only `docs/sub/readme.md`).
#
# A single left-to-right "collapse every `**/` to zero" pass (this
# function's own earlier design) cannot represent a pattern where DIFFERENT
# occurrences need DIFFERENT resolutions — Codex cloud review, confirmed:
# `docs/**/api/**/*.md` matching `docs/v1/api/readme.md` needs the FIRST
# `**/` to consume a real directory (`v1/`) while the SECOND collapses to
# zero, and collapsing either or both to zero alone never produces that.
# _docs_glob_resolve instead branches at each occurrence, trying BOTH (1)
# zero directories (drop the `**/`) and (2) one-or-more (freeze it — replace
# with a sentinel byte no real pattern contains, so the next call scans past
# it to any FURTHER occurrence instead of re-deciding this one) before
# finally restoring every frozen occurrence to a literal `**/` for one
# direct match, where bare `*`'s own slash-crossing handles "however many"
# on its own. Depth is bounded by the number of `**/` occurrences actually
# decided (one per call), so a real pattern's handful of globs costs at
# most a few branches.
docs_glob_match() {
    _docs_glob_resolve "$1" "$2" 0
}

_docs_glob_frozen=$'\x01'

_docs_glob_resolve() {
    local pattern=$1 path=$2 depth=$3 before after final
    [ "$depth" -le 8 ] || return 1
    case "$pattern" in
    *'**/'*)
        before=${pattern%%'**/'*}
        after=${pattern#*'**/'}
        _docs_glob_resolve "${before}${after}" "$path" $((depth + 1)) && return 0
        _docs_glob_resolve "${before}${_docs_glob_frozen}${after}" "$path" $((depth + 1))
        return $?
        ;;
    esac
    final=${pattern//$_docs_glob_frozen/'**/'}
    # shellcheck disable=SC2254  # unquoted on purpose: glob match
    case "$path" in
    $final) return 0 ;;
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

# Verifies that CALLER_PATH's bytes are EXACTLY the blob at CANONICAL_PATH
# in --closure-base, via `git show` — never trusting that a path merely
# named on the command line actually came from that commit. Codex review,
# confirmed: --closure-base only ever constrained the DIFF boundary
# (matching the freshly computed merge base); nothing tied the CONTENT at
# --policy/--devflow-policy-script/--gitleaks-script/--gitleaks-config/
# --registry to that commit at all — a caller could pass --closure-base
# <correct-value> while pointing every other flag at files from an
# unrelated extraction (or a worktree-resident file) and this script would
# use them anyway. `git show` reads the closure_base's own git object
# directly, needing no materialized closure directory of its own.
#
# Residual, documented limitation: this verifies only the files this
# script is directly handed a path for. scripts/lib/toml-lite.mjs (an
# ES-module-relative import of devflow-policy.mjs) and scripts/
# summarize-gitleaks.mjs (a script-relative import of gitleaks-scan.sh) are
# not independently checked — tampering with those specifically is not
# closed by this script alone. .gitleaksignore (read by gitleaks itself
# from beside --gitleaks-config) is NOT in this list: see
# verify_closure_gitleaksignore below, added once it also became a
# declared closure member — Codex cloud review, confirmed the earlier
# omission left the declared closure's most recently added member as the
# one file this function never checked.
verify_closure_member() {
    local caller_path=$1 canonical_path=$2

    [ -f "$caller_path" ] ||
        refuse "${caller_path} does not exist (expected the closure's ${canonical_path})"
    git_with_args show "${closure_base}:${canonical_path}" >"$closure_verify_tmp" 2>/dev/null ||
        refuse "could not read ${canonical_path} from --closure-base (${closure_base})"
    cmp -s "$closure_verify_tmp" "$caller_path" ||
        refuse "${caller_path} does not match ${canonical_path} at --closure-base (${closure_base}) — the closure's provenance could not be verified"
}

# Verifies the closure's own .gitleaksignore — the file gitleaks-scan.sh
# reads from beside GITLEAKS_CONFIG (--gitleaks-config) and compares the
# worktree's copy against — is itself exactly what --closure-base has,
# unlike every other closure member there is no --gitleaksignore flag
# naming it directly, so this derives the same path gitleaks-scan.sh
# derives (dirname of --gitleaks-config) rather than taking one. Optional:
# the spec only requires one "if the merge base has one", so both
# directions are checked — a closure ignore file the merge base does NOT
# have is refused exactly like a mismatched one. Codex cloud review,
# confirmed: without this, a compromised or wrongly-materialized closure
# directory could carry a .gitleaksignore that byte-matches whatever the
# WORKTREE happens to commit (satisfying gitleaks-scan.sh's own
# worktree-vs-closure comparison) while neither one is the merge base's
# actual file, silently suppressing a real secret finding.
verify_closure_gitleaksignore() {
    local gitleaks_ignore_dir gitleaks_ignore_path

    gitleaks_ignore_dir="$(dirname "$gitleaks_config")"
    gitleaks_ignore_path="${gitleaks_ignore_dir}/.gitleaksignore"
    if git_with_args show "${closure_base}:.gitleaksignore" >"$closure_verify_tmp" 2>/dev/null; then
        [ -f "$gitleaks_ignore_path" ] && cmp -s "$closure_verify_tmp" "$gitleaks_ignore_path" ||
            refuse "the closure's .gitleaksignore does not match .gitleaksignore at --closure-base (${closure_base})"
    else
        [ ! -e "$gitleaks_ignore_path" ] ||
            refuse "the closure provides a .gitleaksignore that --closure-base (${closure_base}) does not have"
    fi
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
        # Strip only the HTTPS default port: an explicit-default-port URL
        # (https://github.com:443/owner/repo.git) is exactly as valid a
        # spelling of the same destination as one without it, and should
        # not be refused just because :443 was written out (Codex review,
        # confirmed). A non-default port is a genuinely different
        # destination and stays refused by the host comparison below.
        case "$authority" in
        *:443) authority=${authority%:443} ;;
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
    # Every plan/push-only option is rejected, not only the handful this
    # check previously named — a misplaced mode or flag would otherwise
    # look validated while the option it named was silently never used
    # (Codex cloud review, confirmed).
    { [ -z "$sha$expect$against$closure_base$policy$devflow_policy_script" ] &&
        [ -z "$gitleaks_script$gitleaks_config$registry$task_targets$taskfile_dir" ] &&
        [ -z "$rigor$strategy" ] && [ "$want_json" -eq 0 ]; } ||
        die_usage "plan/push-only arguments are not valid in preflight mode"
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
    # preflight/push-only options are rejected the same way preflight
    # rejects plan/push-only ones (Codex cloud review, confirmed).
    [ -z "$remote$branch$host$repo$expect$gitleaks_script$gitleaks_config" ] ||
        die_usage "preflight/push-only arguments are not valid in plan mode"
    [ -n "$against" ] || die_usage "plan requires --against"
    require_against_is_ref
    [ -n "$closure_base" ] || die_usage "plan requires --closure-base"
    require_closure_base_is_full_sha
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
# --json is plan-only (push has no JSON output); rejected the same way
# preflight/plan reject each other's arguments (Codex cloud review,
# confirmed).
[ "$want_json" -eq 0 ] || die_usage "--json is not valid in push mode"
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
[ -n "$against" ] || die_usage "push requires --against"
require_against_is_ref
[ -n "$closure_base" ] || die_usage "push requires --closure-base"
require_closure_base_is_full_sha
[ -n "$policy" ] || die_usage "push requires --policy"
[ -n "$devflow_policy_script" ] || die_usage "push requires --devflow-policy-script"
[ -n "$gitleaks_script" ] || die_usage "push requires --gitleaks-script"
[ -n "$gitleaks_config" ] || die_usage "push requires --gitleaks-config"

# --branch only shapes the destination refspec; nothing above ties it to
# what is actually checked out. A stale or mistyped --branch main in a
# topic-branch worktree would then push topic's own (validated) --sha
# straight to refs/heads/main — and since main is normally an ancestor of
# a feature branch's tip, the fast-forward check would not even catch it
# (Codex cloud review, confirmed). Refuse unless --branch names the
# worktree's own checked-out branch; a detached HEAD has no checked-out
# branch to compare against and is refused outright rather than silently
# accepted. Checked here, after every other required-argument usage error,
# so an incomplete invocation is still reported as a usage error first.
current_branch="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
[ -n "$current_branch" ] || refuse "HEAD is detached; --branch cannot be bound to a checked-out branch"
[ "$current_branch" = "$branch" ] ||
    refuse "--branch (${branch}) does not match the checked-out branch (${current_branch})"

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

# Every closure-resident input that resolve_policy (right below) needs is
# verified against --closure-base's own git object BEFORE any of it is
# read for real (Codex review, confirmed — see verify_closure_member's own
# comment). This now includes devflow-policy.mjs's own transitive
# dependency scripts/lib/toml-lite.mjs, resolved the same way Node itself
# resolves it (relative to --devflow-policy-script's own directory):
# disclosing it as an unverified residual limitation was not the same as
# closing it — it is imported by a fixed relative path, so a caller could
# point --devflow-policy-script at a verified, genuine file while pairing
# it with a substituted toml-lite.mjs beside it, and devflow-policy.mjs
# would execute that substitute during policy resolution regardless
# (Codex cloud review, confirmed).
#
# The scanner's own closure members (--gitleaks-script/--gitleaks-config/
# .gitleaksignore/summarize-gitleaks.mjs) are verified separately, much
# further below, immediately before the scan reads them rather than here —
# see the comment there for why.
closure_verify_tmp="$(mktemp)"
trap 'rm -f "$closure_verify_tmp"' EXIT
verify_closure_member "$policy" ".devflow.toml"
verify_closure_member "$devflow_policy_script" "scripts/devflow-policy.mjs"
verify_closure_member "$(dirname "$devflow_policy_script")/lib/toml-lite.mjs" "scripts/lib/toml-lite.mjs"
[ -z "$registry" ] || verify_closure_member "$registry" "agent-registry.json"
rm -f "$closure_verify_tmp"

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

# The push destination and SSH transport are snapshotted BEFORE the gate
# runs, not only afterward: `task "$required_target"` right below executes
# the feature worktree's own, branch-controlled Taskfile recipe, and a
# malicious one gets a real window to tamper with either (Codex cloud
# review, confirmed, two distinct ways). (1) core.sshCommand is a
# repository-local git config value, not a tracked file — a gate recipe
# can set it with a plain `git config` call that the later `git status`
# check never sees, and git then uses WHATEVER command core.sshCommand
# (or an inherited GIT_SSH_COMMAND/GIT_SSH — read once here too, since a
# gate's own child process cannot alter its parent's already-inherited
# environment) names to establish the connection, ignoring the validated
# hostname entirely; the test suite's own SSH stub is a working
# demonstration of exactly this class of redirect. (2) resolving
# $push_url only once, AFTER the gate (the previous round's fix),
# cannot detect a change the gate itself already made — only a change
# happening after that single resolution. Snapshotting both here, before
# any branch-controlled code has run, and comparing again immediately
# before the write (further below) closes both windows with the same
# mechanism, covering the gate's own execution as well as the narrower
# window the previous round's fix already covered.
resolve_push_url
gated_push_url="$push_url"
ssh_command_rc=0
ssh_command_before="$(git config --get core.sshCommand 2>/dev/null)" || ssh_command_rc=$?
ssh_command_before="${ssh_command_rc}:${ssh_command_before}:${GIT_SSH_COMMAND:-}:${GIT_SSH:-}"

# The broker EXECUTES the required target itself, from the feature
# worktree, rather than validating a marker a caller produced — config
# spec "Gate authority separates policy from branch implementation": "the
# merge-base broker selects [the round gate], and then executes it from
# the feature worktree." Codex review, confirmed: a caller-supplied
# --gate-file/--gate-token pair proves nothing was actually run — the
# broker's own test helper demonstrated the bypass by fabricating both
# directly. There is no cross-process handoff left to bridge with a
# marker, so there is nothing for a caller to fabricate.
#
# Output is NOT captured to a log: an earlier version redirected it to a
# temp file and replayed its tail in the refusal message on failure, but
# that file was never registered for cleanup, and a failing gate's own
# output can legitimately contain credentials or other sensitive
# environment-derived values that a refusal message is the wrong place to
# echo outward (Codex cloud review, confirmed both). Letting the gate
# inherit this script's own stdout/stderr gives the same visibility a
# caller running `task <target>` directly would already have, with
# nothing captured left to leak or to clean up.
if ! task "$required_target"; then
    refuse "required target '${required_target}' failed"
fi

# The scanner's own closure members are verified here, immediately before
# the scan reads them, rather than earlier alongside --policy/--registry
# above (Codex cloud review, confirmed): unlike those (read during
# resolve_policy, before the gate ever runs), gitleaks-script/
# gitleaks-config/.gitleaksignore/summarize-gitleaks.mjs are not read
# until the scan below, so verifying them earlier would leave exactly the
# gate-execution window described above — a malicious gate could
# overwrite them (they live outside the worktree, so `git status` never
# sees it) between an early check and their actual use. Checking
# immediately before use, against --closure-base's own immutable git
# object, closes that regardless of when the tampering happened.
# summarize-gitleaks.mjs (gitleaks-scan.sh's own transitive dependency,
# resolved the same way gitleaks-scan.sh itself resolves it — relative to
# its own directory) is now verified for the same reason toml-lite.mjs is
# above: disclosing it as unverified was not the same as closing it.
closure_verify_tmp="$(mktemp)"
trap 'rm -f "$closure_verify_tmp"' EXIT
verify_closure_member "$gitleaks_script" "scripts/gitleaks-scan.sh"
verify_closure_member "$gitleaks_config" ".gitleaks.toml"
verify_closure_member "$(dirname "$gitleaks_script")/summarize-gitleaks.mjs" "scripts/summarize-gitleaks.mjs"
verify_closure_gitleaksignore
rm -f "$closure_verify_tmp"

# Secret scan runs unconditionally, every push, via the closure's own
# extracted scanner and config — never the worktree's .gitleaks.toml (or,
# per gitleaks-scan.sh's own --config handling, a worktree-committed
# .gitleaksignore that doesn't match the closure's copy: gitleaks reads
# that file from the scanned worktree root regardless of what
# --gitleaks-ignore-path says, so the scanner refuses outright on a
# mismatch rather than silently honoring a branch-controlled suppression
# list). Config spec "Gate authority separates policy from branch
# implementation": "the orchestrator SHALL materialize outside the feature
# worktree and execute the merge-base implementations of both the secret
# scan and the round-push broker."
if ! "$gitleaks_script" --config "$gitleaks_config"; then
    refuse "the closure-extracted secret scan found findings, refused a mismatched .gitleaksignore, or failed to run"
fi

# The gate having run is now evidence this script itself produces, bound
# to the gated head and the diff class it verified — never an input a
# caller can supply. Purely informational: nothing downstream reads it
# back.
# diff_class rides along explicitly: a policy is free to configure
# round_code and round_docs to the SAME target slug (nothing in the reader
# requires them distinct), and without diff_class in the marker a code and
# a docs push at the same SHA would then print an IDENTICAL line, leaving
# the evidence unable to say which classification the broker actually
# derived (Codex cloud review, confirmed; config spec "Merge-base
# resolution SHALL determine gate policy" binds the marker to "the exact
# head and diff class", not to the target alone).
printf 'ROUND-GREEN-%s-%s-%s\n' "$resolved" "$required_target" "$diff_class"

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

# Push to the destination and SSH transport validated BEFORE the gate ran
# (captured above as $gated_push_url/$ssh_command_before), never a fresh
# re-resolution of the mutable named remote (Codex review, confirmed: the
# prior code passed $remote here, so a receive-pack, pushurl, or insteadOf
# rewrite change would silently redirect it — the checks above would have
# validated a destination this write never actually used).
#
# Passing the literal $gated_push_url string here does NOT by itself close
# the insteadOf/pushInsteadOf case, though: git re-applies that rewriting
# to ANY repository operand — a named remote or a literal URL alike — at
# the moment git push actually runs, not merely when a URL is first looked
# up (verified empirically: `git remote get-url` already reflects
# insteadOf, and a second `git push` given that same pre-rewrite literal
# string still gets rewritten again by whatever rule is configured at
# push time). round-push.sh's own -c allowlist deliberately permits a
# caller to supply url.*.insteadOf (an unprovisioned host's documented
# HTTPS override), so this can't be refused outright — but a rule change
# landing between the EARLY resolution (before the gate) and this write
# must still be caught (Codex cloud review, confirmed twice over: first
# that switching from $remote to a literal URL closed the
# remote.<name>.pushurl mutation vector but left this one open, then that
# resolving only once, after the gate, could not detect the gate's own
# tampering at all). Re-resolving immediately before the write and
# refusing on any drift shrinks the window to the smallest gap this
# script can create; it cannot make git's own resolution atomic.
resolve_push_url
[ "$push_url" = "$gated_push_url" ] ||
    refuse "the push destination changed since it was validated (was ${gated_push_url}, now ${push_url}); reconcile before pushing"
ssh_command_rc=0
ssh_command_after="$(git config --get core.sshCommand 2>/dev/null)" || ssh_command_rc=$?
ssh_command_after="${ssh_command_rc}:${ssh_command_after}:${GIT_SSH_COMMAND:-}:${GIT_SSH:-}"
[ "$ssh_command_after" = "$ssh_command_before" ] ||
    refuse "the SSH transport override changed since it was validated; reconcile before pushing"

# git_with_args still carries the caller's -c transport overrides.
# refs/remotes/<remote>/<branch> is updated by hand afterward, since a
# raw-URL push (unlike a named-remote push) does not update it itself and
# AGENTS.md's own "Git transport" guidance is explicit that leaving it
# stale is the wrong tradeoff.
if ! git_with_args push --no-follow-tags \
    "$push_url" "${resolved}:refs/heads/${branch}" "$lease"; then
    exit 4
fi
# The actual push above already succeeded; a failure here only means the
# LOCAL tracking ref could not be updated to match — an uncertain outcome
# to report, exactly like a post-push read_remote_head failure right
# below, never a silently-swallowed one (Codex cloud review, confirmed:
# lock contention, permissions, or an invalid existing ref could all fail
# this update-ref, and `|| true` reported success regardless).
git update-ref "refs/remotes/${remote}/${branch}" "$resolved" 2>/dev/null ||
    uncertain "the push landed, but refs/remotes/${remote}/${branch} could not be updated to match; the local tracking ref may be stale"

read_remote_head || uncertain "$remote_error"
[ "$remote_head" = "$resolved" ] ||
    uncertain "the remote branch is '${remote_head}', not the gated commit '${resolved}'"

exit 0
