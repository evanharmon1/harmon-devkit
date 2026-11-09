#!/usr/bin/env bash
# test-git-merge-guard.sh — table-driven test for .claude/hooks/git-merge-guard.py.
#
# The guard replaces the `Bash(git merge:*)` permissions.ask rules, so a
# regression here silently removes the merge-into-main backstop. Every case
# feeds a real PreToolUse payload to the hook and checks its decision against
# throwaway repos: a feature-branch worktree, the default branch, a detached
# HEAD, a repo whose default branch is `trunk`, and one with no resolvable
# remote HEAD. A final pass runs a deliberately broken copy of the guard (one
# that never asks about the target branch) and requires the matrix to catch
# it, so the suite cannot pass vacuously.
# Run via `task test:hooks`.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
guard="${GUARD:-${repo_root}/.claude/hooks/git-merge-guard.py}"

# Fixture commits must not trip a global signing config or core.hooksPath.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS
# The matrix tests the guarded (dev) profile; the profile section sets its own.
unset FOREMAN_DEVCONTAINER
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1

# macOS ignores TMPDIR for a bare `mktemp -d` and returns a /var/folders path;
# /var is a symlink to /private/var, so the guard's physical paths would differ
# from the fixture paths the matrix feeds it (#2009). Name the parent and resolve it.
tmp="$(mktemp -d "${TMPDIR:-/tmp}/merge-guard.XXXXXX")" || exit 1
tmp="$(cd "$tmp" && pwd -P)" || exit 1
trap 'rm -rf "$tmp"' EXIT
fixture() { # dir default-branch feature-branch set-remote-head(yes|no) [remote-name]
    local rem=${5:-origin}
    git init -q -b "$2" "$1"
    git -C "$1" -c user.name=t -c user.email=t@t commit -q --allow-empty -m 'chore: fixture'
    git -C "$1" branch "$3"
    git -C "$1" remote add "$rem" "${tmp}/absent.git"
    git -C "$1" update-ref "refs/remotes/${rem}/$2" HEAD
    git -C "$1" config "branch.$2.remote" "$rem"
    git -C "$1" config "branch.$2.merge" "refs/heads/$2"
    if [[ $4 == yes ]]; then
        git -C "$1" symbolic-ref "refs/remotes/${rem}/HEAD" "refs/remotes/${rem}/$2"
    fi
}
r="${tmp}/repo"
fixture "$r" main feat yes
git -C "$r" worktree add -q "${r}/wt" feat
mkdir -p "${r}/wt/sub"
git -C "$r" remote add 'origin&cd' "${tmp}/absent.git"
git -C "$r" remote add unsafe "${tmp}/absent.git"
git -C "$r" config remote.unsafe.fetch '+refs/heads/*:refs/heads/*'
git -C "$r" worktree add -q --detach "${r}/det" main
tr="${tmp}/trunk"
fixture "$tr" trunk feat yes
git -C "$tr" worktree add -q "${tr}/wt" feat
nh="${tmp}/nohead"
fixture "$nh" trunk feat no
git -C "$nh" worktree add -q "${nh}/wt" feat
sl="${tmp}/slashed"
fixture "$sl" trunk feat yes team/origin
git -C "$sl" worktree add -q "${sl}/wt" feat
# Tags named like branches make `symbolic-ref --short` print `heads/<name>`.
am="${tmp}/ambiguous"
fixture "$am" main feat yes
git -C "$am" tag main
git -C "$am" tag feat
git -C "$am" worktree add -q "${am}/wt" feat 2>/dev/null # expected: "refname is ambiguous"
# A branch spelled `Main` in a repo whose remote default is `trunk`: only the
# casefolded main/master check can catch it (refs are case-insensitive on macOS).
cs="${tmp}/casefold"
fixture "$cs" trunk Main yes
git -C "$cs" worktree add -q "${cs}/wt" Main

# A same-named tag must never turn a protected-branch sync into a feature merge.
shadow="${tmp}/shadow"
fixture "$shadow" main feat yes
git -C "$shadow" -c user.name=t -c user.email=t@t commit -q --allow-empty -m 'chore: feature target'
git -C "$shadow" tag origin/main

amp="${tmp}/lane&git"
git -C "$shadow" worktree add -q "$amp" feat

# Dedicated push-config fixture; matrix mutations are restored before returning.
pp="${tmp}/push-proof"
fixture "$pp" main feat yes
git -C "$pp" worktree add -q "${pp}/wt" feat
git -C "$pp" config branch.feat.remote origin
git -C "$pp" config branch.feat.merge refs/heads/feat
git -C "$pp" update-ref refs/remotes/origin/feat HEAD
git -C "$pp" remote add backup "${tmp}/absent.git"
git -C "$pp" symbolic-ref refs/remotes/backup/HEAD refs/remotes/backup/main

# Isolate multivalued merge-source mutations from the ordinary sync cases.
ms="${tmp}/merge-sources"
fixture "$ms" main feat yes

# A real local remote proves --ff-only overrides pull.rebase=true: it can
# fast-forward, but must refuse divergence without rewriting the local commit.
rb_source="${tmp}/rebase-origin"
fixture "$rb_source" main feat yes
rb="${tmp}/rebase-true"
git clone -q --no-local "$rb_source" "$rb"
git -C "$rb" checkout -q -b feat --track origin/main
git -C "$rb" config pull.rebase true
git -C "$rb_source" -c user.name=t -c user.email=t@t commit -q --allow-empty -m 'chore: upstream advances'
echo "==> pull.rebase=true permits fast-forward-only pulls without rewriting"
git -C "$rb" pull --ff-only >"${tmp}/rebase-ff.log" 2>&1
if [[ $(git -C "$rb" rev-parse HEAD) != "$(git -C "$rb_source" rev-parse HEAD)" ]]; then
    echo "TEST FAIL: --ff-only did not fast-forward with pull.rebase=true" >&2
    exit 1
fi
git -C "$rb" -c user.name=t -c user.email=t@t commit -q --allow-empty -m 'chore: local divergence'
local_head="$(git -C "$rb" rev-parse HEAD)"
git -C "$rb_source" -c user.name=t -c user.email=t@t commit -q --allow-empty -m 'chore: upstream divergence'
if LC_ALL=C git -C "$rb" pull --ff-only >"${tmp}/rebase-diverged.log" 2>&1; then
    echo "TEST FAIL: --ff-only accepted divergence with pull.rebase=true" >&2
    exit 1
fi
if [[ $(git -C "$rb" rev-parse HEAD) != "$local_head" ||
$(git -C "$rb" rev-parse refs/remotes/origin/main) != "$(git -C "$rb_source" rev-parse HEAD)" ]] ||
    ! grep -q 'Not possible to fast-forward' "${tmp}/rebase-diverged.log"; then
    cat "${tmp}/rebase-diverged.log" >&2
    echo "TEST FAIL: --ff-only must fetch then refuse divergence without rewriting HEAD" >&2
    exit 1
fi

failures=0
case_count=0
decide() { # guard cwd command [reason] -> silent|ask|reason|rc<N>
    local input out rc
    if input="$(jq -nc --arg c "$3" --arg d "$2" \
        '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}')"; then
        :
    else
        rc=$?
        echo "rc${rc}"
        return
    fi
    if out="$(python3 "$1" <<<"$input")"; then
        rc=0
    else
        rc=$?
    fi
    if [[ $rc -ne 0 ]]; then
        echo "rc${rc}"
    elif [[ -z $out ]]; then
        echo silent
    elif jq -e '.hookSpecificOutput.permissionDecision == "ask"
        and (.hookSpecificOutput.permissionDecisionReason | length > 0)' <<<"$out" >/dev/null; then
        if [[ ${4:-} == reason ]]; then
            jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$out"
        else
            echo ask
        fi
    else
        echo "unexpected:${out}"
    fi
}
echo "==> merge-guard JSON transport regressions"
large_command="$(python3 -c 'print("x" * 98304, end="")')"
if jq -nc --arg c "$large_command" --arg d "$r" \
    'repeat({tool_name:"Bash",tool_input:{command:$c},cwd:$d})' |
    python3 -c 'import time; time.sleep(0.1)'; then
    old_pipeline_rc=0
else
    old_pipeline_rc=$?
fi
if [[ $old_pipeline_rc -ne 141 ]]; then
    echo "TEST FAIL: expected old early-reader pipeline to expose jq SIGPIPE 141, got ${old_pipeline_rc}" >&2
    exit 1
fi
early_guard="${tmp}/early-guard.py"
cat >"$early_guard" <<'PY'
#!/usr/bin/env python3
import time

time.sleep(0.1)
PY
chmod +x "$early_guard"
if [[ $(decide "$early_guard" "$r" "$large_command") != silent ]]; then
    echo "TEST FAIL: successful early-return consumer changed the direct decision" >&2
    exit 1
fi
mkdir -p "${tmp}/generator-fails"
cat >"${tmp}/generator-fails/jq" <<'SH'
#!/bin/sh
exit 23
SH
chmod +x "${tmp}/generator-fails/jq"
if [[ $(PATH="${tmp}/generator-fails:$PATH" decide "$early_guard" "$r" command) != rc23 ]]; then
    echo "TEST FAIL: direct JSON generator sentinel 23 was not preserved" >&2
    exit 1
fi
cat >"${tmp}/failed-guard.py" <<'PY'
#!/usr/bin/env python3
raise SystemExit(29)
PY
chmod +x "${tmp}/failed-guard.py"
if [[ $(decide "${tmp}/failed-guard.py" "$r" command) != rc29 ]]; then
    echo "TEST FAIL: direct consumer sentinel 29 was not preserved" >&2
    exit 1
fi
case_() { # guard expected cwd command [reason]
    local got
    case_count=$((case_count + 1))
    got="$(decide "$1" "$3" "$4" "${5:-}")"
    if [[ $got != "$2" ]]; then
        failures=$((failures + 1))
        [[ ${QUIET:-0} == 1 ]] || echo "  FAIL expected=$2 got=${got} :: [${3#"$tmp"/}] $4" >&2
    fi
    return 0
}
nl=$'\n'
cr=$'\r'
nbsp=$'\xc2\xa0'
matrix() { # guard
    local g=$1
    # #787: GitHub merge entry points, writes versus reads, and push destinations.
    local cmd op flag
    for cmd in 'gh pr merge 1' 'gh pr merge --auto 1' 'gh pr merge --admin 1' 'gh pr merge --disable-auto 1' 'gh -R o/r pr merge 1' 'gh --repo=o/r pr merge 1' 'gh pr -R o/r merge 1' 'gh pr --repo=o/r merge 1'; do
        case_ "$g" ask "${r}/wt" "$cmd"
        for op in ';' '&&' '||' '|' '&' "$nl"; do
            case_ "$g" ask "${r}/wt" "true $op $cmd"
        done
    done
    for flag in '-X PUT' '-XPUT' '--method PUT' '--method=PUT' '-iX PUT' '-iXPUT' '-f x=y' '-F x=y'; do
        case_ "$g" ask "$r" "gh api $flag repos/o/r/pulls/1/merge"
        case_ "$g" ask "$r" "gh api /repos/{owner}/{repo}/pulls/1/merge $flag"
        case_ "$g" ask "$r" "gh api https://api.github.com/repos/o/r/pulls/1/merge $flag"
    done
    for cmd in mergePullRequest enablePullRequestAutoMerge enqueuePullRequest mergeBranch updateRef updateRefs createCommitOnBranch deleteRef; do
        case_ "$g" ask "$r" "gh api graphql -f 'query=mutation { $cmd(input: {}) { clientMutationId } }'"
    done
    for cmd in 'gh api graphql -F query=@file' 'gh api graphql --input file' 'gh api graphql' 'gh api -X "$METHOD" repos/o/r/pulls/1/merge'; do
        case_ "$g" ask "$r" "$cmd"
    done
    for cmd in 'gh pr view 1' 'gh pr list' 'gh pr ready 1' 'gh api repos/o/r/pulls/1' 'gh api -X GET repos/o/r/pulls/1/merge' 'gh api graphql -f "query={ viewer { login } }"'; do
        case_ "$g" silent "$r" "$cmd"
    done
    for cmd in 'HEAD:main' '+HEAD:main' ':main' 'refs/heads/main' 'feat:master' '--delete main' '--all' '--mirror'; do
        case_ "$g" ask "${r}/wt" "git push origin $cmd"
    done
    case_ "$g" ask "${tr}/wt" 'git push origin HEAD:trunk'
    case_ "$g" ask "${tr}/wt" 'git push origin refs/heads/trunk'
    case_ "$g" ask "${r}/wt" 'git push origin feat HEAD:master'
    case_ "$g" ask "${r}/wt" 'git push origin :feat'
    case_ "$g" ask "${r}/wt" 'git push origin --delete feat'
    case_ "$g" silent "${r}/wt" 'git push origin refs/heads/feat:refs/heads/feat'
    case_ "$g" ask "${r}/wt" "git -C ${r}/wt push origin feat"
    case_ "$g" ask "$r" 'git push'
    case_ "$g" ask "$r" 'git push origin'
    case_ "$g" ask "${nh}/wt" 'git push origin feat'
    case_ "$g" silent "${r}/wt" 'git push -u origin feat'
    case_ "$g" silent "${r}/wt" 'git push origin HEAD:feat'
    case_ "$g" ask "${r}/wt" "cd ${tr} && git push origin feat"
    case_ "$g" ask "${r}/wt" 'env -C /unknown git push origin feat'
    case_ "$g" ask "${r}/wt" 'git -c alias.p=push p origin HEAD:main'
    case_ "$g" ask "${r}/wt" 'xargs -I X gh X'
    case_ "$g" silent "${r}/wt" 'git push'
    case_ "$g" silent "${r}/wt" 'git push origin'
    case_ "$g" ask "${r}/wt" 'git -c remote.origin.push=HEAD:main push origin'
    case_ "$g" ask "${tr}/wt" "bash -c 'git push origin HEAD:trunk'"
    for cmd in 'gh pr merge 1' 'gh api -X PUT repos/o/r/pulls/1/merge' 'gh api graphql -f query=mergePullRequest' 'git push origin HEAD:main'; do
        case_ "$g" ask "$r" "bash -c '$cmd'"
        case_ "$g" ask "$r" "bash <<< '$cmd'"
        case_ "$g" ask "$r" "echo \$( $cmd )"
    done
    # R10 C1-1/3/4: one write table, independently exercised at every entry.
    for cmd in \
        '-X POST repos/o/r/merges' \
        '-X POST repos/o/r/merge-upstream' \
        '-X POST repos/o/r/git/refs' \
        '-X PATCH repos/o/r/git/refs/heads/main' \
        '-X DELETE repos/o/r/git/refs/heads/main' \
        '-X PUT repos/o/r/contents/a/b' \
        '-X DELETE repos/o/r/contents/a/b' \
        '-X POST repos/o/r/branches/{branch}/rename'; do
        case_ "$g" ask "$r" "gh api $cmd"
    done
    for cmd in \
        'repos/o/r/pulls/1/merge#ignored' \
        'repos/o/r/pulls/1/merge?x=y' \
        'https://api.github.com/repos/o/r/pulls/1/merge#ignored' \
        '//repos//o//r//pulls//1//merge' \
        '/repos/{owner}/{repo}/pulls/1/merge' \
        'repos/o/r/%70ulls/1/%6derge'; do
        case_ "$g" ask "$r" "gh api -X PUT '$cmd'"
    done
    case_ "$g" ask "$r" 'gh api -X POST "$ENDPOINT"'
    case_ "$g" silent "$r" 'gh api repos/{owner}/{repo}/pulls/1'
    case_ "$g" silent "$r" 'gh api repos/{owner}/{repo}/pulls/1/comments'
    case_ "$g" silent "$r" 'gh api -X POST repos/o/r/issues/1/comments -f body=hello'
    case_ "$g" silent "$r" 'gh api -X POST repos/o/r/pulls/1/comments/2/replies -f body=hello'
    case_ "$g" silent "$r" 'gh api graphql -f "query=mutation { resolveReviewThread(input: {}) { clientMutationId } }"'
    case_ "$g" silent "$r" 'gh api graphql -f "query=mutation { addComment(input: {}) { clientMutationId } }"'
    case_ "$g" silent "$r" 'gh api graphql -f "query=mutation { updateProjectV2ItemFieldValue(input: {}) { clientMutationId } }"'
    # C1-2: appending a method or field can turn an apparent read into a write.
    case_ "$g" ask "$r" "printf '%s\\n' '-X PUT' | xargs gh api repos/o/r/pulls/1/merge"
    case_ "$g" ask "$r" 'parallel gh api repos/o/r/merges ::: -X POST'
    case_ "$g" ask "$r" 'find . -exec gh api repos/o/r/merges {} +'
    case_ "$g" ask "$r" "env -S 'gh api repos/o/r/pulls/1/merge' -X PUT"
    case_ "$g" ask "$r" 'env -S gh api repos/o/r/pulls/1/merge -X PUT'
    case_ "$g" silent "$r" 'printf 1 | xargs gh pr view'
    # C1-6/8: lookup arguments and a bare push word are data.
    for cmd in 'command -v gh' 'command -V gh' 'command -pv gh' 'which gh' 'type gh' 'ls /usr/local/bin/gh' 'test -x /usr/local/bin/gh'; do
        case_ "$g" silent "$r" "$cmd"
    done
    case_ "$g" silent "$r" "bash -lc 'printf \"%s\\n\" push'"
    case_ "$g" ask "$r" "bash -lc 'printf push main'"
    # C1-9: the unchanged companion grammar also proves push compounds.
    for op in '&&' '||' ';' '|'; do
        case_ "$g" silent "${r}/wt" "git status $op git push origin feat"
        case_ "$g" silent "${r}/wt" "true $op git push origin feat $op false"
    done
    case_ "$g" silent "${r}/wt" 'git fetch origin && git push origin feat'
    case_ "$g" ask "${r}/wt" 'git fetch unsafe && git push origin feat'
    case_ "$g" ask "${r}/wt" 'git fetch origin feat:feat && git push origin feat'
    case_ "$g" ask "${r}/wt" 'git checkout main && git push origin feat'
    # C1-5: prove each no-refspec configuration invariant, and its failure.
    for cmd in 'git push' 'git push origin'; do
        case_ "$g" silent "${pp}/wt" "$cmd"
    done
    for flag in simple current upstream; do
        git -C "$pp" config push.default "$flag"
        case_ "$g" silent "${pp}/wt" 'git push'
        case_ "$g" silent "${pp}/wt" 'git push origin'
    done
    for flag in matching nothing; do
        git -C "$pp" config push.default "$flag"
        case_ "$g" ask "${pp}/wt" 'git push'
        case_ "$g" ask "${pp}/wt" 'git push origin'
    done
    git -C "$pp" config --unset push.default
    git -C "$pp" config remote.origin.push HEAD:main
    case_ "$g" ask "${pp}/wt" 'git push'
    case_ "$g" ask "${pp}/wt" 'git push origin'
    git -C "$pp" config --unset remote.origin.push
    for flag in branch.feat.pushRemote remote.pushDefault; do
        git -C "$pp" config "$flag" origin
        case_ "$g" silent "${pp}/wt" 'git push origin'
        git -C "$pp" config "$flag" backup
        case_ "$g" ask "${pp}/wt" 'git push origin'
        git -C "$pp" config --unset "$flag"
    done
    for flag in main other; do
        git -C "$pp" config branch.feat.merge "refs/heads/$flag"
        case_ "$g" ask "${pp}/wt" 'git push'
        case_ "$g" ask "${pp}/wt" 'git push origin'
    done
    git -C "$pp" config branch.feat.merge refs/heads/feat
    git -C "$pp" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/feat
    case_ "$g" ask "${pp}/wt" 'git push origin'
    git -C "$pp" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
    case_ "$g" ask "${pp}/detached-nonexistent" 'git push origin'
    for flag in --all --mirror --tags; do
        case_ "$g" ask "${pp}/wt" "git push origin $flag"
    done
    # R11: API writes fail closed; routine skill writes are explicitly safe.
    for cmd in \
        '-X POST repos/o/r/issues/1/comments -f body=hello' \
        '-X PATCH repos/o/r/issues/comments/2 -f body=hello' \
        '-X DELETE repos/o/r/issues/comments/2' \
        '-X POST repos/o/r/pulls/1/comments -f body=hello' \
        '-X POST repos/o/r/pulls/1/comments/2/replies -f body=hello' \
        '-X POST repos/o/r/pulls/1/reviews -f event=COMMENT' \
        '-X POST repos/o/r/pulls/1/requested_reviewers -f reviewers[]=u' \
        '-X PATCH repos/o/r/pulls/1 -f body=hello' \
        '-X PATCH repos/o/r/issues/1 -f body=hello' \
        '-X POST repos/o/r/issues/1/labels -f labels[]=bug' \
        '-X DELETE repos/o/r/issues/1/labels' \
        '-X POST repos/o/r/issues/1/assignees -f assignees[]=u' \
        '-X POST repos/o/r/issues/1/reactions -f content=eyes' \
        '-X PUT repos/o/r/pulls/1/update-branch' \
        '-X POST repos/o/r/dispatches -f event_type=review' \
        '-X POST repos/o/r/actions/workflows/review.yml/dispatches -f ref=feat'; do
        case_ "$g" silent "$r" "gh api $cmd"
    done
    for cmd in addComment addPullRequestReviewComment addPullRequestReviewThreadReply resolveReviewThread unresolveReviewThread addReaction removeReaction updateIssue updatePullRequest addLabelsToLabelable removeLabelsFromLabelable updatePullRequestBranch updateProjectV2ItemFieldValue addProjectV2ItemById markPullRequestReadyForReview convertPullRequestToDraft; do
        case_ "$g" silent "$r" "gh api graphql -f 'query=mutation { $cmd(input: {}) { clientMutationId } }'"
    done
    # #1858: every review must prove COMMENT or REQUEST_CHANGES; unknown asks.
    for cmd in \
        'gh pr review 1 --approve' \
        'gh pr review 1 -a' \
        'gh pr review 1 -ca' \
        'gh pr review 1 -ra' \
        'gh pr review 1 --request-changes --body "$BODY"' \
        'gh -R o/r pr review 1 --approve' \
        'gh pr -R o/r review 1 -a' \
        'gh pr review 1' \
        'gh pr review 1 "$MODE"' \
        'xargs gh pr review 1 --comment'; do
        case_ "$g" ask "$r" "$cmd"
    done
    for cmd in \
        'gh pr review 1 --comment' \
        'gh pr review 1 -c' \
        'gh pr review 1 --request-changes' \
        'gh pr review 1 -r' \
        'gh pr review 1 -cbapprove' \
        'gh pr review 1 -rb approve' \
        'gh pr review 1 --comment --body --approve' \
        'gh pr review 1 --comment --body-file @file'; do
        case_ "$g" silent "$r" "$cmd"
    done
    # C1-1: a skipped value must never inject approval flags by word splitting.
    for cmd in \
        'gh pr review 1 --comment --body $BODY' \
        'gh pr review 1 --comment -b $B' \
        'gh pr review 1 -cb $B' \
        'gh pr review 1 --comment --body-file $F' \
        'gh pr review 1 --comment -F $F' \
        'gh pr review 1 --comment --repo $R' \
        'gh pr review 1 --comment -R $R' \
        'gh pr review 1 --comment --body-file=$F' \
        'gh pr review 1 --comment --repo=$R' \
        'gh pr review 1 --comment -cb$B' \
        'gh pr review $PR --comment' \
        'gh -R $R pr review 1 --comment' \
        'gh pr -R $R review 1 --comment'; do
        case_ "$g" ask "$r" "$cmd"
    done
    case_ "$g" ask "$r" 'gh pr review 1 --comment --body "$BODY"'
    case_ "$g" ask "$r" 'gh pr review 1 -cb "$BODY"'
    # C2-1: double quotes do not preserve one argument for @ expansions.
    for expansion in '$@' '${@}' '${@:2}' '${a[@]}' '${a[@]:1}' '${a[@]#x}' '${!name@}' '${!name[@]}' '${body:-"$@"}'; do
        case_ "$g" ask "$r" "gh pr review 1 --comment --body \"$expansion\""
        case_ "$g" ask "$r" "gh api repos/o/r/pulls/1/reviews -f event=COMMENT -f body=\"$expansion\""
        case_ "$g" ask "$r" "gh api repos/o/r/issues/1/comments -f body=\"$expansion\""
    done
    case_ "$g" ask "$r" 'gh pr review 1 --comment --body "$*"'
    case_ "$g" ask "$r" 'gh pr review 1 --comment --body "${a[*]}"'
    # C3-1/R14b: no parameter expansion proves one review argument.
    for expansion in '${!n}' '${!n:-x}' '${a[1]}' '${a[@]}' '${x:-"$@"}' '${#a[@]}'; do
        case_ "$g" ask "$r" "gh pr review 1 --comment --body \"$expansion\""
        case_ "$g" ask "$r" "gh api repos/o/r/pulls/1/reviews -f event=COMMENT -f body=\"$expansion\""
    done
    for expansion in '$x' '${x}' '$1' '${10}' '$*' '${*}' '${a[*]}' '$#'; do
        case_ "$g" ask "$r" "gh pr review 1 --comment --body \"$expansion\""
        case_ "$g" ask "$r" "gh api repos/o/r/pulls/1/reviews -f event=COMMENT -f body=\"$expansion\""
    done
    case_ "$g" ask "$r" 'a=(t --approve); declare -n n='"'"'a[@]'"'"'; gh pr review 1 --comment --body "$n"'
    case_ "$g" ask "$r" 'a=(t --approve); declare -n n='"'"'a[@]'"'"'; gh api repos/o/r/pulls/1/reviews -f event=COMMENT -f body="$n"'
    case_ "$g" ask "$r" 'gh api repos/o/r/pulls/1/reviews -f event=COMMENT -f body="$BODY"'
    # V1-1: help is not proved when a skipped value can expand to --help=false --approve.
    case_ "$g" ask "$r" 'a=(t --help=false --approve); declare -n n='"'"'a[@]'"'"'; gh pr review 1 --help --body "$n"'
    case_ "$g" ask "$r" 'gh pr review 1 --help --body "$BODY"'
    case_ "$g" silent "$r" 'gh pr review 1 --help'
    case_ "$g" silent "$r" 'gh pr review --help'
    # V2-1: literal review modes retain the nonexecuting help exemption.
    case_ "$g" silent "$r" 'gh pr review 1 --comment --help'
    case_ "$g" silent "$r" 'gh pr review 1 --request-changes --help'
    case_ "$g" silent "$r" 'gh pr review 1 --approve --help'
    case_ "$g" silent "$r" 'gh pr review 1 -c -h'
    # V3-1: review parameters ask before read exemptions or option consumption.
    case_ "$g" ask "$r" 'a=(x -X POST -f event=APPROVE); declare -n n='"'"'a[@]'"'"'; gh api -X GET repos/o/r/pulls/1/reviews -f body="$n"'
    case_ "$g" ask "$r" 'gh api -X GET repos/o/r/pulls/1/reviews -q "$n"'
    case_ "$g" ask "$r" 'gh api -X HEAD repos/o/r/pulls/1/reviews -H "$n"'
    case_ "$g" ask "$r" 'gh api -X GET repos/o/r/pulls/1/reviews/2/events -q "$n"'
    case_ "$g" ask "$r" 'gh api graphql -X GET -f '"'"'query=mutation { submitPullRequestReview(input: {event: COMMENT}) { clientMutationId } }'"'"' -q "$n"'
    case_ "$g" ask "$r" 'a=(o/r pr review --approve); declare -n n='"'"'a[@]'"'"'; gh -R "$n" 1'
    case_ "$g" ask "$r" 'a=(o/r review 1 --approve --body); declare -n n='"'"'a[@]'"'"'; gh pr -R "$n" hi'
    # R15b: no subcommand asks only when consumed options contain parameters.
    case_ "$g" ask "$r" 'a=(o/r pr review 1 --approve); declare -n n='"'"'a[@]'"'"'; gh -R "$n"'
    case_ "$g" silent "$r" 'gh -R o/r'
    # V1-2: outside review paths, quoted parameters keep main's one-word rule.
    case_ "$g" silent "$r" 'gh api repos/o/r/issues/1/comments -f body="${BODY:-fallback}"'
    case_ "$g" silent "$r" 'gh api repos/o/r/pulls/1 --jq "${FILTER:-.id}"'
    case_ "$g" silent "$r" 'gh api repos/o/r/pulls/1/comments/2/replies -f body="${BODY:-x}"'
    # Every word on a review path counts, not only fields: a parameter in any
    # option value can split into an injected -f event=APPROVE.
    review_mutation='mutation{addPullRequestReview(input:{pullRequestId:"x",event:COMMENT}){clientMutationId}}'
    for option in '-t "$n"' '--template "$n"' '--jq "$n"' '-q"$n"' '-H "$n"' '--input "$n"'; do
        case_ "$g" ask "$r" "gh api repos/o/r/pulls/1/reviews -f event=COMMENT $option"
        case_ "$g" ask "$r" "gh api graphql -f query='$review_mutation' $option"
    done
    case_ "$g" silent "$r" "gh api graphql -f query='$review_mutation' -t literal"
    case_ "$g" silent "$r" 'gh api repos/o/r/pulls/1/comments/2/replies -f body="$BODY" -q .id'
    # Attached values use the same review proof as separated values.
    for option in --body --body-file --repo -b -F -R; do
        case_ "$g" ask "$r" "gh pr review 1 --comment $option \"\$BODY\""
        for value in literal '"$(printf x)"' '"`printf x`"'; do
            case_ "$g" silent "$r" "gh pr review 1 --comment $option $value"
        done
    done
    for option in --body= --body-file= --repo= -b -F -R; do
        case_ "$g" ask "$r" "gh pr review 1 --comment ${option}\"\$BODY\""
        for value in literal '"$(printf x)"' '"`printf x`"'; do
            case_ "$g" silent "$r" "gh pr review 1 --comment $option$value"
        done
    done
    case_ "$g" silent "$r" 'gh pr review 1 --comment --body prefix"$(printf "$x")"suffix'
    for option in '--body ' --body= -b; do
        case_ "$g" silent "$r" "gh pr review 1 --comment ${option}\"\$(cat <<'EOF'
Review body
EOF
)\""
    done
    # C3-2: the review subject can be separated from gh by printf formatting.
    for shell in bash sh; do
        case_ "$g" ask "$r" "printf '%s pr review 1 --approve\\n' gh | $shell"
    done
    # A bare review word in an evaluator line is not a review operation.
    case_ "$g" silent "$r" 'bash scripts/codex-review.sh review --base main'
    case_ "$g" silent "$r" 'bash -c "task review"'
    case_ "$g" silent "$r" 'echo please review | bash'
    # C2-2: evaluator fallback covers review operations, including pipe data.
    for shell in bash sh; do
        case_ "$g" ask "$r" "printf 'gh pr review 1 --approve\\n' | $shell"
        case_ "$g" ask "$r" "cat <<'EOF' | $shell
 gh pr review 1 --approve
EOF"
        case_ "$g" ask "$r" "$shell <<'EOF'
 gh pr review 1 --approve
EOF"
        case_ "$g" ask "$r" "printf 'gh api repos/o/r/pulls/1/reviews -f event=APPROVE\\n' | $shell"
        case_ "$g" ask "$r" "printf 'addPullRequestReview\\n' | $shell"
        case_ "$g" ask "$r" "printf 'submitPullRequestReview\\n' | $shell"
    done
    for flag in -f -F --field --raw-field; do
        for event in COMMENT REQUEST_CHANGES; do
            case_ "$g" silent "$r" "gh api repos/o/r/pulls/1/reviews $flag event=$event"
        done
        for event in APPROVE UNKNOWN '@file' '@-' '"$EVENT"'; do
            case_ "$g" ask "$r" "gh api repos/o/r/pulls/1/reviews $flag event=$event"
        done
    done
    for cmd in \
        'gh api repos/o/r/pulls/1/reviews --field=event=APPROVE' \
        'gh api repos/o/r/pulls/1/reviews --raw-field=event=APPROVE' \
        'gh api repos/o/r/pulls/1/reviews -if event=APPROVE' \
        'gh api repos/o/r/pulls/1/reviews -f event=COMMENT -F event=@file' \
        'gh api repos/o/r/pulls/1/reviews -f event[]=COMMENT' \
        'gh api repos/o/r/pulls/1/reviews --input file' \
        'gh api repos/o/r/pulls/1/reviews --input -' \
        'gh api -X POST repos/o/r/pulls/1/reviews'; do
        case_ "$g" ask "$r" "$cmd"
    done
    for mutation in addPullRequestReview submitPullRequestReview; do
        for event in COMMENT REQUEST_CHANGES; do
            case_ "$g" silent "$r" "gh api graphql -f 'query=mutation { $mutation(input: {pullRequestId: \"PR\", event: $event, body: \"APPROVE\"}) { clientMutationId } }'"
        done
        # Review-only parameter checks include variable fields and short suffixes.
        for flag in -f -F --field --raw-field; do
            case_ "$g" ask "$r" "gh api graphql -f 'query=mutation { $mutation(input: {event: COMMENT}) { clientMutationId } }' $flag body=\"\$BODY\""
        done
        case_ "$g" ask "$r" "gh api graphql -f 'query=mutation { $mutation(input: {event: COMMENT}) { clientMutationId } }' -fbody=\"\$BODY\""
        case_ "$g" silent "$r" "gh api graphql -f 'query=mutation { $mutation(input: {event: COMMENT}) { clientMutationId } }' -f body=\"\$(printf x)\""
        for event in APPROVE UNKNOWN '$event'; do
            case_ "$g" ask "$r" "gh api graphql -f 'query=mutation { $mutation(input: {event: $event}) { clientMutationId } }'"
        done
        case_ "$g" ask "$r" "gh api graphql -f 'query=mutation { $mutation(input: {}) { clientMutationId } }'"
        case_ "$g" ask "$r" "gh api graphql -f 'query=mutation { $mutation(input: {event: COMMENT, event: APPROVE}) { clientMutationId } }'"
        case_ "$g" ask "$r" "gh api graphql -f 'query=mutation { $mutation(input: {event: APPROVE, comments: [{body: \"x\", event: COMMENT}]}) { clientMutationId } }'"
        for flag in -f -F --field --raw-field; do
            case_ "$g" ask "$r" "gh api graphql $flag 'query=mutation { $mutation(input: {event: APPROVE}) { clientMutationId } }'"
            case_ "$g" ask "$r" "gh api graphql -f 'query=mutation(\$event: PullRequestReviewEvent!) { $mutation(input: {event: \$event}) { clientMutationId } }' $flag event=APPROVE"
            case_ "$g" ask "$r" "gh api graphql -f 'query=mutation(\$input: SubmitPullRequestReviewInput!) { $mutation(input: \$input) { clientMutationId } }' $flag 'input[event]=APPROVE'"
            case_ "$g" ask "$r" "gh api graphql $flag query=@file"
            case_ "$g" ask "$r" "gh api graphql $flag query=@-"
        done
        case_ "$g" ask "$r" "gh api graphql --input file -f 'query=mutation { $mutation(input: {event: COMMENT}) { clientMutationId } }'"
        case_ "$g" ask "$r" "gh api graphql --input - -f 'query=mutation { $mutation(input: {event: COMMENT}) { clientMutationId } }'"
    done
    case_ "$g" silent "$r" 'gh pr update-branch 1'
    case_ "$g" ask "$r" 'gh api -X PATCH repos/o/r/unknown-write'
    case_ "$g" ask "$r" 'gh api -X POST repos/o/r/pulls/1/merge'
    case_ "$g" ask "$r" 'gh api -X DELETE repos/o/r/git/refs/heads/main/reactions'
    case_ "$g" ask "$r" 'gh api graphql -f "query=mutation { resolveReviewThread(input: {}) { thread { id } } mergePullRequest(input: {}) { clientMutationId } }"'
    case_ "$g" ask "$r" 'gh api graphql -f "query=mutation { resolveReviewThread: mergePullRequest(input: {}) { clientMutationId } }"'
    case_ "$g" silent "$r" 'gh api graphql -f "query=mutation { x: resolveReviewThread(input: {}) { clientMutationId } }"'
    case_ "$g" ask "$r" 'gh api graphql -f "query=mutation { unknownNewWrite(input: {}) { clientMutationId } }"'
    # C2-1: delegated API strings are opaque and always ask.
    case_ "$g" ask "$r" "printf 'gh api -X PATCH repos/o/r/git/refs/heads/main' | bash"
    case_ "$g" ask "$r" 'ssh host gh api -X POST repos/o/r/merges'
    case_ "$g" ask "$r" "herdr pane run lane 'gh api -X PATCH repos/o/r/git/refs/heads/main'"
    # C2-2: mirror can be configured without a CLI --mirror flag.
    for flag in true yes on 1; do
        git -C "$pp" config remote.origin.mirror "$flag"
        case_ "$g" ask "${pp}/wt" 'git push'
        case_ "$g" ask "${pp}/wt" 'git push origin'
        case_ "$g" ask "${pp}/wt" 'git push origin feat'
    done
    git -C "$pp" config remote.origin.mirror false
    case_ "$g" silent "${pp}/wt" 'git push origin'
    git -C "$pp" config --unset remote.origin.mirror
    # C2-3: only positional remote sync targets ask; update-branch is safe.
    for cmd in 'gh repo sync o/r' 'gh repo sync o/r --source upstream/r --force' 'gh repo sync --force o/r' 'xargs gh repo sync'; do
        case_ "$g" ask "$r" "$cmd"
    done
    case_ "$g" silent "$r" 'gh repo sync'
    case_ "$g" silent "$r" 'gh repo sync --source o/r --force'
    case_ "$g" ask "$r" "bash -lc 'gh repo sync'"
    # C2-5/6: GHE prefixes are recognized; percent escapes cannot forge safe paths.
    case_ "$g" silent "$r" 'gh api https://ghe.example/api/v3/repos/o/r/pulls/1'
    case_ "$g" silent "$r" 'gh api /api/v3/repos/o/r/pulls/1'
    case_ "$g" silent "$r" 'gh api -X PUT https://ghe.example/api/v3/repos/o/r/pulls/1/update-branch'
    case_ "$g" silent "$r" 'gh api https://ghe.example/api/graphql -f "query={ viewer { login } }"'
    case_ "$g" ask "$r" 'gh api -X POST https://ghe.example/api/v3/repos/o/r/merges'
    case_ "$g" ask "$r" 'gh api -X POST repos/o/r/branches/feat%2Fmain/rename'
    case_ "$g" ask "$r" 'gh api -X POST repos/o/r/issues/1%2Fcomments'
    # C2-7: deleting the lookup exemption prevents option-operand confusion.
    case_ "$g" ask "$r" 'env -u command -v gh pr merge 1'
    case_ "$g" ask "$r" 'command -v gh pr merge 1'
    # C2-8: only operation-controlling values must be literal.
    case_ "$g" silent "$r" 'gh api repos/o/r/pulls/1 --jq "$F"'
    case_ "$g" silent "$r" 'gh api repos/o/r/pulls/1 --template "$T" --cache "$TTL"'
    case_ "$g" silent "$r" 'gh api repos/o/r/pulls/1 -q "$F" -t "$T" --paginate --slurp'
    case_ "$g" ask "$r" 'gh api graphql -f "query=query($id: ID!) { node(id: $id) { id } }" -F id="$ID"'
    case_ "$g" silent "$r" 'gh api graphql -f '"'"'query=query($id: ID!) { node(id: $id) { id } }'"'"' -F id="$ID"'
    case_ "$g" silent "$r" 'gh api graphql -f '"'"'query=mutation($id: ID!) { resolveReviewThread(input: {threadId: $id}) { clientMutationId } }'"'"' -F id="$ID"'
    case_ "$g" ask "$r" 'gh api graphql -f query="$Q"'
    case_ "$g" ask "$r" 'gh api graphql -F "$KEY=value"'
    case_ "$g" ask "$r" 'gh api repos/o/r/pulls/1 -H "$HEADER"'
    case_ "$g" ask "$r" 'gh api repos/o/r/pulls/1 --input "$FILE"'
    # R12: challenge r3 P2 hardening, with the deferred catch-up case explicit.
    case_ "$g" ask "$r" 'gh api -X POST repos/o/r/merges -tXGET'
    case_ "$g" ask "$r" 'gh api -X POST repos/o/r/merges -qXGET'
    case_ "$g" silent "$r" 'gh api repos/o/r/pulls/1 -tXGET'
    case_ "$g" ask "$r" 'gh api repos/o/r/pulls/1 -t $T'
    case_ "$g" ask "$r" 'gh -R $REPO api repos/o/r/pulls/1'
    case_ "$g" silent "$r" 'gh -R "$REPO" api repos/o/r/pulls/1'
    case_ "$g" ask "$r" 'gh api repos/o/r/pulls/1 -t {1..3}'
    case_ "$g" ask "$r" 'gh api repos/o/r/pulls/1 --jq $FILTER'
    case_ "$g" ask "$r" 'gh api -X POST repos/o/r/issues/1/comments -f body=$BODY'
    case_ "$g" silent "$r" 'gh api -X POST repos/o/r/issues/1/comments -f body="$BODY"'
    # R14b: general comment/reply paths retain their quoted parameter behavior.
    case_ "$g" silent "$r" 'gh api repos/o/r/pulls/1/comments/2/replies -f body="$BODY"'
    case_ "$g" silent "$r" 'gh api repos/o/r/issues/1/comments -f body="$BODY"'
    case_ "$g" silent "$r" 'gh api repos/o/r/pulls/1 -t "$T"'
    case_ "$g" ask "$r" 'gh api repos/o/r/pulls/1 -t "$T"$OTHER'
    case_ "$g" ask "$r" "gh api graphql -f 'query=mutation { resolveReviewThread(input: {}) { clientMutationId } # comment${cr} mergePullRequest(input: {}) { clientMutationId } }'"
    case_ "$g" ask "$r" "gh api graphql -f 'query={ viewer { login } }$(printf '\001')'"
    # #1849: REST and GraphQL catch-ups are offline allowlist decisions, even
    # from a protected local checkout. Neither looks up the PR's head: these
    # stay silent for feature heads AND default-branch heads (including fork
    # main). The ADR records this deliberate limitation; no gh call runs here.
    case_ "$g" silent "$r" 'gh api -X PUT repos/o/r/pulls/1/update-branch'
    case_ "$g" silent "$r" 'gh api graphql -f '\''query=mutation { updatePullRequestBranch(input: {pullRequestId: "PR"}) { clientMutationId } }'\'''
    case_ "$g" silent "$r" 'gh api -X GET repos/o/r/pulls/1 -f state=all'
    case_ "$g" silent "$r" 'gh api -X HEAD repos/o/r/pulls/1 -f state=all'
    case_ "$g" ask "$r" 'gh api graphql -X GET -f "query=mutation { mergePullRequest(input: {}) { clientMutationId } }"'
    case_ "$g" silent "$r" 'git grep push && true'
    case_ "$g" silent "$r" 'git log --grep push; git status'
    case_ "$g" silent "$r" 'git -c color.ui=false grep push && true'
    case_ "$g" silent "$r" "git -C ${r} log --grep push; git status"
    # R13 V1-1: documented credential wrapper executes its child; inject does not.
    case_ "$g" ask "$r" 'op run -- gh pr merge 1'
    case_ "$g" ask "$r" 'op run --env-file=.env -- gh api -X PUT repos/o/r/pulls/1/merge'
    case_ "$g" silent "$r" 'op run -- gh pr view 1'
    case_ "$g" silent "$r" 'op run -- gh api repos/o/r/pulls --jq .'
    case_ "$g" ask "$r" 'op run -- git push origin main'
    case_ "$g" ask "$r" 'op --account example run -- gh pr merge 1'
    case_ "$g" ask "$r" 'op --config /tmp/config --session placeholder run --env-file .env gh pr merge 1'
    case_ "$g" silent "$r" 'op --account=example --format json run --no-masking gh pr view 1'
    case_ "$g" silent "$r" 'op run --env-file .env gh api repos/o/r/pulls/1'
    case_ "$g" ask "$r" 'op run gh pr merge 1'
    case_ "$g" ask "$r" 'op run --env-file'
    case_ "$g" ask "$r" 'op --account'
    case_ "$g" ask "$r" 'op --account "$ACCOUNT" run -- gh pr merge 1'
    case_ "$g" ask "$r" 'op run --unknown value gh pr merge 1'
    case_ "$g" ask "$r" 'op run --env-file "$FILE" gh pr merge 1'
    case_ "$g" ask "$r" 'op run -- op run -- gh pr merge 1'
    case_ "$g" ask "$r" 'env KEY=value op run -- gh pr merge 1'
    case_ "$g" ask "$r" 'op inject -- gh pr merge 1'
    case_ "$g" silent "$r" 'op inject -i template.txt -o output.txt'
    case_ "$g" ask "$r" 'echo op run -- gh pr merge 1'
    case_ "$g" ask "$r" 'op run -- echo gh pr merge 1'
    # R14 V2-1: help/version are non-executing; flag values are still data.
    for cmd in 'gh --version' 'gh -v' 'gh --help' 'gh -h' 'gh help pr merge' 'gh pr --help' 'gh pr merge --help' 'gh pr merge -h' 'gh api --help' 'gh api -h' 'gh -R o/r help api' 'gh -R o/r pr merge --admin --help'; do
        case_ "$g" silent "$r" "$cmd"
    done
    case_ "$g" ask "$r" 'gh api -X POST repos/o/r/merges --template --help'
    case_ "$g" ask "$r" 'gh api -X POST repos/o/r/merges -t--help'
    case_ "$g" ask "$r" 'gh pr merge help'
    case_ "$g" ask "$r" 'gh api -X POST repos/o/r/merges --help --help=false'
    case_ "$g" ask "$r" 'gh api -X POST repos/o/r/merges -f $FIELDS --help'
    case_ "$g" ask "$r" 'gh api -X POST repos/o/r/merges --help "$OPTIONS"'
    case_ "$g" ask "$r" 'xargs gh api -X POST repos/o/r/merges --help'
    case_ "$g" ask "$r" 'xargs -I --help gh api -X POST repos/o/r/merges --help'
    # #1860: help proof uses the active command's arities, including clusters.
    for cmd in \
        'gh pr merge 1 --help -s --help=false' \
        'gh pr merge 1 --help -ds --help=false' \
        'gh pr merge 1 --help -s--help=false' \
        'gh pr review 1 --help -s --help=false --approve' \
        'gh pr review 1 --help -a --help=false' \
        'gh pr merge 1 --body-file --help' \
        'gh pr merge 1 -F--help' \
        'gh pr review 1 -F --help' \
        'gh pr merge 1 --subject --help'; do
        case_ "$g" ask "$r" "$cmd"
    done
    for cmd in \
        'gh pr merge 1 -s --help' \
        'gh pr merge 1 -dsh' \
        'gh pr merge 1 -F message.txt --help' \
        'gh pr review 1 -F body.txt --help' \
        'gh pr review 1 -ach' \
        'gh api -iF x=y --help' \
        'gh repo sync --source o/r --help'; do
        case_ "$g" silent "$r" "$cmd"
    done
    # Sources must be literal even when quoted or attached to the option.
    for cmd in \
        'gh repo sync --source $SOURCE' \
        'gh repo sync --source=$SOURCE' \
        'gh repo sync -s $SOURCE' \
        'gh repo sync -s$SOURCE' \
        'gh repo sync --source "$SOURCE"' \
        'gh repo sync --source="$SOURCE"' \
        'gh repo sync -s"$SOURCE"' \
        'gh repo sync --source o/r --source "$SOURCE"' \
        'gh repo sync --source "$(cat source.txt)"' \
        'gh repo sync --source'; do
        case_ "$g" ask "$r" "$cmd"
    done
    for flag in '--source o/r' '--source=o/r' '-s o/r' '-so/r'; do
        case_ "$g" silent "$r" "gh repo sync $flag"
    done
    # Top-level selectors cannot discard append-mode feeder state.
    for flag in '-R o/r' '-Ro/r' '--repo o/r' '--repo=o/r' '--hostname github.com'; do
        case_ "$g" ask "$r" "printf 'pr merge 1 --squash' | xargs gh $flag"
        case_ "$g" silent "$r" "gh $flag"
    done
    # Typed query fields expand placeholders; raw fields retain literal text.
    local placeholder
    for placeholder in owner repo branch; do
        for flag in '-F ' '--field ' '-F' '--field=' '-iF ' '-iF'; do
            case_ "$g" ask "$r" "gh api graphql $flag'query={$placeholder} { mergePullRequest(input: {}) { clientMutationId } }'"
        done
        for flag in '-f ' '--raw-field='; do
            case_ "$g" silent "$r" "gh api graphql $flag'query={ viewer { login } } # {$placeholder}'"
        done
    done
    case_ "$g" silent "$r" "gh api graphql -F 'query={ viewer { login } }'"
    case_ "$g" silent "$r" "gh api graphql -f 'query={ viewer { login } }' -F owner='{owner}'"
    # Evaluator fallback sees format-string assembly of operation words.
    for cmd in \
        "printf 'git me%sge feat' r | bash" \
        "printf 'git pu%sl' l | sh" \
        "printf 'gh pr re%siew 1 --approve' v | bash" \
        "printf 'gh a%si -X PUT repos/o/r/pulls/1/merge' p | sh" \
        "printf 'gh repo sy%sc o/r' n | bash" \
        'printf -v cmd "git me%sge feat" r; eval "$cmd"' \
        'printf -v cmd "gh pr re%siew 1 --approve" v; eval "$cmd"' \
        'bash -c '\''eval "$(printf "git me%sge feat" r)"'\''' \
        'bash -lc '\''printf "git me%sge feat" r | sh'\''' \
        "printf 'git me%sge feat' r | env -S sh"; do
        case_ "$g" ask "$r" "$cmd"
    done
    case_ "$g" ask "$r" "printf 'git me%sge${nl}feat' r | bash"
    # Integration cycle 1: remote cmd executes; printf wrapper names are data.
    case_ "$g" ask "$r" 'ssh windows-host cmd.exe /c "git m^erge feat"'
    case_ "$g" silent "$r" "printf '%s\\n' 'env' 'bash'"
    for cmd in \
        "printf 'git me%sge feat' r" \
        "printf 'gh pr re%siew 1 --approve' v" \
        'printf -v cmd "git me%sge feat" r' \
        'printf -v command_text "git me%sge feat" r' \
        'bash -lc '\''printf "%s\n" push'\''' \
        'bash -lc '\''printf "git me%sge feat" r'\''' \
        'bash -c '\''printf "%s" "merge notes"'\'''; do
        case_ "$g" silent "$r" "$cmd"
    done
    # V2-2: classify tokenized operations, not strings/comment text.
    case_ "$g" silent "$r" 'gh api graphql -f '"'"'query=query { search(query: "mutation", type: ISSUE, first: 1) { issueCount } }'"'"''
    case_ "$g" silent "$r" 'gh api graphql -f '"'"'query=# leading comment
query { viewer { login } }'"'"''
    case_ "$g" silent "$r" 'gh api graphql -f '"'"'query=query { viewer { login } } # mutation'"'"''
    case_ "$g" silent "$r" 'gh api graphql -f '"'"'query=# mutation
query { viewer { login } }'"'"''
    case_ "$g" silent "$r" 'gh api graphql -f '"'"'query=query { search(query: """mutation""", type: ISSUE, first: 1) { issueCount } }'"'"''
    case_ "$g" ask "$r" 'gh api graphql -f '"'"'query=# leading comment
mutation { mergePullRequest(input: {}) { clientMutationId } }'"'"''
    case_ "$g" silent "$r" 'gh api graphql -f '"'"'query=# leading comment
mutation { resolveReviewThread(input: {}) { clientMutationId } }'"'"''
    case_ "$g" ask "$r" 'gh api graphql -f '"'"'query=query Q { viewer { login } } mutation M { mergePullRequest(input: {}) { clientMutationId } }'"'"''
    # R15 I1-1/2/4: every push form shares destination ref/repository proof.
    local push_cmd
    git -C "$pp" config push.default upstream
    git -C "$pp" config branch.feat.merge refs/heads/main
    for push_cmd in 'git push' 'git push origin' 'git push origin feat' 'git push -u origin feat' 'git push origin refs/heads/feat' 'git push origin HEAD'; do
        case_ "$g" ask "${pp}/wt" "$push_cmd"
    done
    case_ "$g" silent "${pp}/wt" 'git push origin HEAD:feat'
    git -C "$pp" config branch.feat.merge refs/heads/feat
    git -C "$pp" config --unset push.default
    git -C "$pp" config remote.origin.push refs/heads/feat:refs/heads/main
    for push_cmd in 'git push' 'git push origin' 'git push origin feat' 'git push -u origin feat' 'git push origin HEAD'; do
        case_ "$g" ask "${pp}/wt" "$push_cmd"
    done
    case_ "$g" silent "${pp}/wt" 'git push origin HEAD:feat'
    git -C "$pp" config --unset remote.origin.push
    # Any pushurl disqualifies repository proof, including an empty first value.
    git -C "$pp" config --add remote.origin.pushurl ''
    git -C "$pp" config --add remote.origin.pushurl "${tmp}/other.git"
    for push_cmd in 'git push' 'git push origin' 'git push origin feat' 'git push -u origin feat' 'git push origin HEAD' 'git push origin HEAD:feat'; do
        case_ "$g" ask "${pp}/wt" "$push_cmd"
    done
    git -C "$pp" config --unset-all remote.origin.pushurl
    # Match the first value, not just the last pushInsteadOf rule.
    git -C "$pp" config --add "url.${tmp}/redirect.git.pushInsteadOf" "${tmp}/"
    git -C "$pp" config --add "url.${tmp}/redirect.git.pushInsteadOf" 'nonmatching-prefix'
    for push_cmd in 'git push' 'git push origin' 'git push origin feat' 'git push -u origin feat' 'git push origin HEAD' 'git push origin HEAD:feat'; do
        case_ "$g" ask "${pp}/wt" "$push_cmd"
    done
    git -C "$pp" config --unset-all "url.${tmp}/redirect.git.pushInsteadOf"
    git -C "$pp" config --add remote.origin.mirror true
    git -C "$pp" config --add remote.origin.mirror false
    case_ "$g" ask "${pp}/wt" 'git push origin HEAD:feat'
    git -C "$pp" config --unset-all remote.origin.mirror
    git -C "$pp" config --add push.default matching
    git -C "$pp" config --add push.default simple
    case_ "$g" ask "${pp}/wt" 'git push origin feat'
    git -C "$pp" config --unset-all push.default
    git -C "$pp" config branch.feat.pushRemote backup
    case_ "$g" ask "${pp}/wt" 'git push origin HEAD:feat'
    git -C "$pp" config --unset branch.feat.pushRemote
    git -C "$pp" config remote.pushDefault backup
    case_ "$g" ask "${pp}/wt" 'git push origin HEAD:feat'
    git -C "$pp" config --unset remote.pushDefault
    case_ "$g" silent "${pp}/wt" 'git push -u origin HEAD'
    case_ "$g" silent "${pp}/wt" 'git push origin refs/heads/feat'
    case_ "$g" ask "$pp" 'git push origin HEAD'
    case_ "$g" ask "${pp}/wt" 'GIT PUSH origin main'
    case_ "$g" ask "${pp}/wt" 'git-push origin main'
    case_ "$g" ask "${pp}/wt" 'git commit -m message && git push origin feat'
    # I1-3: no wrapper vocabulary can hide a literal gh word now.
    for cmd in 'flock /tmp/l gh pr merge 1' 'uv run gh pr merge 1' 'nix develop -c gh pr merge 1' 'strace -f gh api -X PUT repos/o/r/pulls/1/merge' 'dotenvx run -- gh pr merge 1' 'echo gh pr merge 1'; do
        case_ "$g" ask "$r" "$cmd"
    done
    for cmd in 'uv run gh pr view 1' 'command -v gh' 'which gh' 'ls /usr/local/bin/gh'; do
        case_ "$g" silent "$r" "$cmd"
    done
    # R16 I2-1: gh data words are silent unless following words control an operation.
    for cmd in 'grep gh -r .' 'rg gh -t sh' 'find / -name gh -type f' 'brew install gh --quiet' 'apt-get install gh -y' 'ls ~/.config/gh -la' 'gh repo view cli/gh --json name'; do
        case_ "$g" silent "$r" "$cmd"
    done
    case_ "$g" ask "$r" 'uv run gh --admin 1 pr merge'
    case_ "$g" ask "$r" 'uv run gh "$X"'
    # 2026-10-25 observed shapes: lane catch-ups and evaluator mentions.
    case_ "$g" silent "$r" "git -C ${r}/wt merge --ff-only abc123"
    case_ "$g" silent "${r}/wt" "git fetch origin && git merge --ff-only abc123"
    # R25: fetch companions accept only a configured remote with tracking-only specs.
    case_ "$g" ask "${r}/wt" "git fetch origin main:main && git merge --ff-only feat"
    case_ "$g" ask "${r}/wt" "git fetch unsafe && git merge --ff-only feat"
    case_ "$g" ask "${r}/wt" "git fetch unconfigured && git merge --ff-only feat"
    # #1849: every fetch destination must belong to the selected remote. A
    # matching final value must not hide an earlier cross-remote destination.
    git -C "$r" config --add remote.origin.fetch '+refs/heads/*:refs/remotes/origin-other/*'
    case_ "$g" ask "${r}/wt" "git fetch origin && git merge --ff-only feat"
    git -C "$r" config --add remote.origin.fetch '+refs/heads/feat:refs/remotes/origin/feat'
    case_ "$g" ask "$r" "git fetch origin && git merge --ff-only refs/remotes/origin/main"
    git -C "$r" config --unset-all remote.origin.fetch
    git -C "$r" config --add remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
    git -C "$r" config --add remote.origin.fetch 'refs/heads/feat:refs/remotes/origin/feat'
    case_ "$g" silent "$r" "git fetch origin && git merge --ff-only refs/remotes/origin/main"
    git -C "$r" config --unset-all remote.origin.fetch
    git -C "$r" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
    case_ "$g" silent "$sl" "git fetch team/origin && git merge --ff-only refs/remotes/team/origin/trunk"
    # Explicit -C status remains outside the companion grammar, even though
    # the same absolute target is accepted with fetch. Do not expand it.
    case_ "$g" ask "${r}/wt" "git -C ${r}/wt status && git merge --ff-only feat"
    case_ "$g" silent "${r}/wt" "git -C ${r}/wt fetch origin && git merge --ff-only feat"
    case_ "$g" silent "$r" "cd ${r}/wt && git merge --ff-only origin/main"
    # V3-1: Python whitespace splitting must never change the Bash target word.
    case_ "$g" ask "$r" "git -C ${r}/wt${cr} merge --ff-only feat"
    case_ "$g" ask "$r" "cd ${r}/wt${nbsp} && git merge --ff-only feat"
    for op in '&&' '||' ';' '|'; do
        case_ "$g" silent "${r}/wt" "git merge --ff-only main $op git pull --ff-only origin main"
        case_ "$g" ask "${r}/wt" "git merge --ff-only main $op git -C ${r} merge --ff-only feat"
    done
    # #1868: longer field names do not trigger the base word test; no proof is needed.
    case_ "$g" silent "$r" "bash <<'EOF'${nl}gh pr view 1 --json mergeStateStatus${nl}EOF"
    # #1868: longer field names and plural paths do not trigger the base word test.
    case_ "$g" silent "$r" "bash -c 'gh pr view 1 --json mergedAt,mergeStateStatus; echo pulls/1'"
    # #1844: one complete literal evaluator with inert output is silent.
    case_ "$g" silent "$r" "sh -c 'echo pull'"
    # #1868: the camel-cased field name has no base-risk word; no proof is needed.
    case_ "$g" silent "$r" "D=\$(bash script.sh --json closedByPullRequestsReferences)"
    # #1868: script-file form is outside the proof; the merge/pull word test asks.
    case_ "$g" ask "$r" "bash script.sh merge pull"
    case_ "$g" ask "$r" "bash -c \"echo 'git merge\""
    case_ "$g" ask "$r" "bash <<'EOF'${nl}git pull --ff-only origin feat${nl}EOF"
    case_ "$g" ask "$r" "printf 'git merge feat\\n' | bash -s merged"
    case_ "$g" ask "$r" "printf 'git merge feat\\n' | bash /dev/stdin"
    case_ "$g" ask "$r" "printf 'git pull\\n' | sh -"
    # #1844: closed literal language; no unknown input channel can qualify.
    case_ "$g" silent "$r" "bash -c 'echo merge'"
    case_ "$g" silent "$r" "bash -c 'printf merge; echo pull'"
    case_ "$g" silent "$r" "bash -c 'gh pr view 1 --json number --jq \".merge\"'"
    case_ "$g" silent "$r" "bash <<'EOF'${nl}echo merge${nl}EOF"
    case_ "$g" silent "$r" "sh <<'EOF'${nl}gh pr list --jq \".merge\"${nl}EOF${nl}"
    # #1868: blank and trailing newline segments, plus a trailing semicolon, are harmless.
    case_ "$g" silent "$r" "bash <<'EOF'${nl}echo merge${nl}${nl}echo pull${nl}EOF"
    case_ "$g" silent "$r" "bash <<'EOF'${nl}echo merge;${nl}EOF"
    case_ "$g" silent "$r" "bash <<'EOF'${nl}echo merge${nl}${nl}EOF"
    # #1868: every empty pipe segment stays outside the proof and asks.
    for payload in \
        '| echo merge' \
        'echo merge |' \
        'echo merge || echo pull' \
        'echo merge | ; echo pull' \
        'echo merge ; | echo pull'; do
        case_ "$g" ask "$r" "bash <<'EOF'${nl}${payload}${nl}EOF"
    done
    case_ "$g" ask "$r" "bash -c 'echo git merge'"
    case_ "$g" ask "$r" "bash -c 'gh pr merge 1'"
    case_ "$g" ask "$r" "bash -c 'echo merge' extra"
    case_ "$g" ask "$r" "bash -c 'echo merge'; true"
    case_ "$g" ask "$r" "bash -c 'echo merge' < /dev/null"
    case_ "$g" ask "$r" "bash -c 'echo merge' 3<&0"
    case_ "$g" ask "$r" "BASH_ENV=/dev/stdin bash -c 'echo merge'"
    case_ "$g" ask "$r" "bash -c 'exec echo merge'"
    case_ "$g" ask "$r" "bash -c 'history -r; echo merge'"
    case_ "$g" ask "$r" "bash -c 'echo merge; fc -s'"
    case_ "$g" ask "$r" "bash -c 'echo merge \$CODE'"
    case_ "$g" ask "$r" "bash -c 'echo merge \$(true)'"
    case_ "$g" ask "$r" "bash -c 'echo merge \$1'"
    case_ "$g" ask "$r" "bash -c 'echo merge > /dev/null'"
    case_ "$g" ask "$r" "bash -c 'cat /dev/fd/3; echo merge'"
    case_ "$g" ask "$r" "bash <<EOF${nl}echo merge${nl}EOF"
    case_ "$g" ask "$r" "bash <<'EOF'${nl}echo merge${nl}EOF${nl}true"
    case_ "$g" ask "$r" "bash <<'EOF' < /dev/null${nl}echo merge${nl}EOF"
    case_ "$g" ask "$r" "bash -c 'echo merge # comment'"
    # R14: git in a literal path is data; only fixed read commands may run.
    case_ "$g" silent "$r" "bash -c 'tail -5 /srv/x/git/repo/.git/log.txt'"
    case_ "$g" silent "$r" "bash -c 'tail -5 /srv/x/git/repo/.git/merge.log | grep merge'"
    case_ "$g" silent "$r" "bash -c 'cat merge.log | sort | uniq | head -5 | wc -l'"
    case_ "$g" silent "$r" "bash -c 'printf merge | cut -c 1-3'"
    case_ "$g" silent "$r" "bash -c 'gh issue view 1 --json title | jq \".merge\"'"
    case_ "$g" silent "$r" "bash -c 'echo \"git merge\"'"
    case_ "$g" ask "$r" "bash -c 'tail -5 f; git merge feat'"
    case_ "$g" ask "$r" "bash -c 'cat merge.log | bash'"
    case_ "$g" ask "$r" "bash -c 'echo merge > /tmp/x.sh'"
    case_ "$g" ask "$r" "bash -c 'gh pr checkout 1; echo merge'"
    case_ "$g" ask "$r" "bash -c 'gh repo clone o/r; echo merge'"
    case_ "$g" ask "$r" "bash -c 'gh pr close 1; echo merge'"
    case_ "$g" ask "$r" "bash -c 'X=1 tail -5 merge.log'"
    case_ "$g" ask "$r" "bash -c 'cat /dev/stdin; echo merge'"
    case_ "$g" ask "$r" "bash -c 'cat /dev/fd/3; echo merge'"
    case_ "$g" ask "$r" "bash -c 'sed -n 1p merge.log'"
    # R14's read-only property also excludes option-driven execution/writes.
    case_ "$g" ask "$r" "bash -c 'printf -v PATH /tmp; echo merge'"
    case_ "$g" ask "$r" "bash -c 'printf \"%s%n\" merge PATH'"
    case_ "$g" ask "$r" "bash -c 'sort --compress-program=sh merge.log'"
    case_ "$g" ask "$r" "bash -c 'sort -o /tmp/gh merge.log'"
    case_ "$g" ask "$r" "bash -c 'uniq merge.log /tmp/gh'"
    case_ "$g" ask "$r" "bash -c 'cat ../../dev/stdin; echo merge'"
    # C1-1 + security review: options that launch another program are not reads.
    case_ "$g" ask "$r" "bash -c 'grep --filter=txt:sh merge f.txt'"
    case_ "$g" ask "$r" "bash -c 'grep --pre=sh merge f.txt'"
    case_ "$g" ask "$r" "bash -c 'grep --save-config merge f.txt'"
    case_ "$g" silent "$r" "bash -c 'grep -n -A 2 -e merge -C3 f.txt'"
    case_ "$g" ask "$r" "bash -c 'gh pr view --web https://github.com/o/r/pull/1'"
    case_ "$g" ask "$r" "bash -c 'gh pr view 1 -w; echo merge'"
    case_ "$g" ask "$r" "bash -c 'gh issue list --web=true; echo merge'"
    case_ "$g" silent "$r" "bash -c 'gh pr view 1 --json title; echo merge'"
    # Failing the proof keeps the base fallback: no merge/pull word, no ask.
    case_ "$g" silent "$r" "bash -c 'task verify'"
    case_ "$g" silent "$r" "sh -c 'ls -la'"
    case_ "$g" silent "$r" "bash <<'EOF'${nl}ls${nl}EOF"
    # #1844 attack corpus: every probe must still ask on a default branch.
    case_ "$g" ask "$r" "CODE='git merge feat'; bash <<< \"\$CODE\""
    case_ "$g" ask "$r" "bash -c '\"\$2\" \"\$1\" \"\$3\"' _ merge git feat"
    case_ "$g" ask "$r" "printf 'git merge feat\\n' > /tmp/m.sh; bash <<< 'true' < /tmp/m.sh"
    case_ "$g" ask "$r" "bash <<< 'true' 0<&3 # git merge feat"
    case_ "$g" ask "$r" "bash <<< 'true' 0<> /tmp/m.sh # git merge feat"
    case_ "$g" ask "$r" "bash <<EOF${nl}\$CODE${nl}EOF # git merge feat"
    # #1868: here-string input is outside the proof; the merge word makes it ask.
    case_ "$g" ask "$r" "bash <<< 'echo merge'"
    case_ "$g" ask "$shadow" "git merge --ff-only origin/main"
    case_ "$g" silent "$shadow" "git merge --ff-only refs/remotes/origin/main"
    # #1844: remaining option and delegated-stdin attack shapes.
    case_ "$g" ask "$r" "bash -c -- 'git merge feat'"
    case_ "$g" ask "$r" "bash -c -x 'git merge feat'"
    case_ "$g" ask "$r" "printf 'git merge feat\\n' | bash -c 'exec sh'"
    case_ "$g" ask "$r" "printf 'git merge feat\\n' | bash -c 'xargs -I X X'"
    # #1868: here-string input is outside the proof; the merge word makes it ask.
    case_ "$g" ask "$r" "bash 0<<< 'echo merge'"
    # #1868: piped stdin is outside the proof; the producer's git merge mention asks.
    case_ "$g" ask "$r" "printf 'git merge feat\\n' | bash -c 'echo merged'"
    case_ "$g" ask "$r" "printf 'git merge feat\\n' | bash /dev/fd/3 3<&0"
    case_ "$g" ask "$r" "printf 'git merge feat\\n' | bash /dev//stdin"
    case_ "$g" ask "$r" "printf 'git merge feat\\n' | bash +x"
    case_ "$g" ask "$r" "printf 'git merge feat\\n' | BASH_ENV=/dev/stdin bash -c 'true'"
    case_ "$g" ask "$r" "printf 'git merge feat\\n' | bash ../../../../../../../../../../dev/stdin"
    case_ "$g" ask "$r" "printf 'git merge feat\\n' | bash -c 'set -o history; history -r /dev/stdin; fc -s'"
    # C3-5: the target exists on a feature branch, but & backgrounds the prefix.
    case_ "$g" ask "$r" "git -C ${amp} merge --ff-only feat"
    case_ "$g" ask "$r" "cd ${amp} && git merge --ff-only feat"
    # Pure syncs on main/trunk; every other default-branch merge asks.
    # #1849: get-all cardinality includes duplicate and empty values. Test
    # both operand forms so upstream resolution cannot conceal a second value.
    local merge_source
    for merge_source in refs/heads/main refs/heads/feat ''; do
        git -C "$ms" config --add branch.main.merge "$merge_source"
        case_ "$g" ask "$ms" "git pull --ff-only"
        case_ "$g" ask "$ms" "git merge --ff-only refs/remotes/origin/main"
        git -C "$ms" config --unset-all branch.main.merge
        git -C "$ms" config branch.main.merge refs/heads/main
    done
    git -C "$ms" config branch.main.merge ''
    git -C "$ms" config --add branch.main.merge refs/heads/main
    case_ "$g" ask "$ms" "git pull --ff-only"
    case_ "$g" ask "$ms" "git merge --ff-only refs/remotes/origin/main"
    git -C "$ms" config --unset-all branch.main.merge
    git -C "$ms" config branch.main.merge refs/heads/main
    case_ "$g" silent "$ms" "git pull --ff-only"
    case_ "$g" silent "$ms" "git merge --ff-only refs/remotes/origin/main"
    case_ "$g" silent "$r" "git pull --ff-only"
    case_ "$g" ask "$r" "git pull --ff-only origin main"
    case_ "$g" silent "$r" "git pull --ff-only origin refs/heads/main"
    case_ "$g" silent "$r" "git pull --ff-only origin"
    case_ "$g" ask "$r" "git fetch origin && git pull --ff-only origin main"
    case_ "$g" silent "$r" "git merge --ff-only origin/main"
    # V1-1: fetch may import a tag that shadows the short operand after inspection.
    case_ "$g" ask "$r" "git fetch origin && git merge --ff-only origin/main"
    case_ "$g" silent "$r" "git fetch origin && git merge --ff-only refs/remotes/origin/main"
    case_ "$g" ask "$r" "git status && git merge --ff-only origin/main"
    # V2-1: a later pipeline member can fetch concurrently and shadow a short ref.
    case_ "$g" ask "$r" "git merge --ff-only origin/main | git fetch origin"
    case_ "$g" silent "$r" "git merge --ff-only refs/remotes/origin/main | git fetch origin"
    # V2-2: this is a real configured remote, but & is shell control syntax.
    case_ "$g" ask "${r}/wt" "git fetch origin&cd ; git merge --ff-only feat"
    case_ "$g" silent "$r" "git fetch origin && git pull --ff-only"
    case_ "$g" ask "$tr" "git pull --ff-only origin trunk"
    case_ "$g" silent "$tr" "git pull --ff-only origin refs/heads/trunk"
    case_ "$g" ask "$nh" "git pull --ff-only"
    case_ "$g" ask "${r}/det" "git pull --ff-only"
    case_ "$g" ask "${nh}/wt" "git merge --ff-only origin/trunk"
    case_ "$g" ask "$r" "git merge --ff-only feat"
    case_ "$g" ask "$r" "git merge --ff-only --no-ff origin/main"
    case_ "$g" ask "$r" "git merge --ff-only --ff origin/main"
    case_ "$g" ask "$r" "git pull --ff-only origin feat"
    case_ "$g" ask "$r" "git -C ${r} pull --rebase origin main"
    case_ "$g" ask "$r" "git -C ${r} pull origin main"
    case_ "$g" ask "${r}/wt" "git checkout main && git merge --ff-only origin/main"
    case_ "$g" ask "${r}/wt" "cd ${r} || git merge --ff-only origin/main"
    case_ "$g" ask "$r" "git -C ${tmp}/missing merge --ff-only main"
    # #1849: only a completely recognised grammar earns a target diagnostic.
    # Preserve the actual -C/cd target, rather than naming the caller's cwd.
    local target_reason='git-merge-guard: merge/pull would land on main/master or a remote default branch, or the target is unverifiable:'
    case_ "$g" "$target_reason $r" "$r" "git merge feat" reason
    case_ "$g" "$target_reason $tr" "${r}/wt" "git -C ${tr} merge --ff-only feat" reason
    case_ "$g" "$target_reason $r" "${r}/wt" "cd ${r} && git merge --ff-only feat" reason
    case_ "$g" "$target_reason ${r}/det" "${r}/det" "git merge feat" reason
    case_ "$g" "$target_reason ${nh}/wt" "${nh}/wt" "git merge trunk" reason
    case_ "$g" "$target_reason ${tmp}/missing" "$r" "git -C ${tmp}/missing merge --ff-only main" reason
    case_ "$g" 'git-merge-guard: merge/pull or GitHub merge in a form this guard does not allowlist' "$r" "git merge --ff-only feat && git checkout main" reason
    # Allowlisted merges into a verified feature branch: no opinion.
    case_ "$g" silent "${r}/wt" "git merge origin/main --no-edit"
    case_ "$g" silent "${r}/wt/sub" "git merge origin/main --no-edit"
    case_ "$g" silent "${r}/wt" "git merge --no-ff main"
    case_ "$g" silent "${r}/wt" "git merge --continue"
    case_ "$g" silent "${r}/wt" "git merge --quit"
    case_ "$g" silent "${r}/wt" "git pull --ff-only"
    case_ "$g" silent "$rb" "git pull --ff-only"
    case_ "$g" ask "$rb" "git pull"
    case_ "$g" ask "$rb" "git pull --rebase"
    case_ "$g" silent "${r}/wt" "git pull --no-rebase origin main --no-edit"
    case_ "$g" silent "${tr}/wt" "git merge trunk --no-edit"
    case_ "$g" silent "${sl}/wt" "git merge trunk --no-edit"
    case_ "$g" silent "${am}/wt" "git merge main --no-edit"
    # Merges that land on main or the remote default, or an unverifiable target.
    case_ "$g" ask "$r" "git merge feat"
    case_ "$g" ask "$r" "git -C ${r} merge feat"
    case_ "$g" ask "${r}/wt" "git -C ${r} merge feat"
    case_ "$g" ask "${r}/wt" "cd ${r} && git merge feat"
    case_ "$g" ask "${r}/det" "git merge feat"
    case_ "$g" ask "$r" "git pull"
    case_ "$g" ask "$tr" "git merge feat"
    case_ "$g" ask "${nh}/wt" "git merge trunk"
    case_ "$g" ask "$sl" "git merge feat"
    case_ "$g" ask "$am" "git merge feat"
    case_ "$g" ask "${cs}/wt" "git merge trunk"
    case_ "$g" ask "$r" "cd wt && git merge main"
    case_ "$g" ask "${tmp}/missing" "git merge main"
    # Shapes the guard does not allowlist: always ask.
    # --abort discards in-progress conflict resolutions: never silent.
    case_ "$g" ask "${r}/wt" "git merge --abort"
    # pull --rebase can rewrite already-pushed feature-branch commits.
    case_ "$g" ask "${r}/wt" "git pull --rebase origin main"
    # Non-fast-forward path forms stay conservative, so a
    # symlink-then-.. or quoted-~ path can't make the guard verify a
    # different checkout than the one git uses (review round 1).
    case_ "$g" ask "$r" "cd ${r}/wt && git merge origin/main --no-edit"
    case_ "$g" ask "$r" "cd ./wt && git merge main"
    case_ "$g" ask "$r" "git -C ${r}/wt merge --no-ff main"
    case_ "$g" ask "${r}/wt" "git -C ./hop/.. merge main"
    case_ "$g" ask "${r}/wt" "git -C \"~/repo\" merge main"
    # Quote-synthesized words on a FEATURE checkout must still ask.
    case_ "$g" ask "${r}/wt" "g''it merge main"
    case_ "$g" ask "${r}/wt" "git mer''ge main"
    case_ "$g" ask "${r}/wt" "git merge 'main'"
    case_ "$g" ask "relative/wt" "git merge main"
    case_ "$g" ask "${r}/wt" "git checkout main && git merge feat"
    case_ "$g" ask "${r}/wt" "git merge main; git -C ${r} merge feat"
    case_ "$g" ask "${r}/wt" "git status; git merge main"
    case_ "$g" ask "$r" "git status${nl}git merge feat"
    case_ "$g" ask "$r" "cd wt${nl}git merge main"
    case_ "$g" ask "$r" "if git merge feat; then echo ok; fi"
    case_ "$g" ask "$r" "command git merge feat"
    case_ "$g" ask "$r" "g''it merge feat"
    case_ "$g" ask "$r" "git mer''ge feat"
    case_ "$g" ask "$r" "GIT merge feat"
    case_ "$g" ask "$r" "G=git; \$G merge feat"
    case_ "$g" ask "${r}/wt" "git merge main || true"
    case_ "$g" ask "${r}/wt" "git merge \$(echo main)"
    # A `#` inside a word is not a comment in bash; shlex must not drop the rest.
    case_ "$g" ask "$r" "echo a#b; git merge feat"
    case_ "$g" ask "$r" "git log --grep=#1 && git merge feat"
    case_ "$g" ask "$r" "git -c alias.m=merge m feat"
    case_ "$g" ask "$r" "git -c Alias.m=merge m feat"
    case_ "$g" ask "$r" "git -calias.m=merge m feat"
    case_ "$g" ask "$r" "git --config-env=alias.m=SUB m feat"
    case_ "$g" ask "$r" "git.exe merge feat"
    # A real comment holding a quote or a trailing backslash must not hide a
    # spliced subcommand on the same or the next line (bash-like reading).
    case_ "$g" ask "$r" "git mer''ge feat # don't"
    case_ "$g" ask "$r" "# don't${nl}git mer\"\"ge feat"
    case_ "$g" ask "$r" "true # don't${nl}git mer\"\"ge feat # it's ok"
    case_ "$g" ask "$r" "echo # \\${nl}git mer\"\"ge feat"
    # Line continuation, an apostrophe in a heredoc body, and `)#`.
    case_ "$g" ask "$r" "true && \\${nl}git mer\"\"ge feat"
    case_ "$g" ask "$r" "bash -c \"git mer''ge feat\" <<'EOF'${nl}don't${nl}EOF"
    case_ "$g" ask "$r" "git -c alias.m=mer\"\"ge m feat <<'EOF'${nl}don't${nl}EOF"
    case_ "$g" ask "$r" "(true)# don't${nl}bash -c \"git mer''ge feat\""
    case_ "$g" ask "$r" "(true)# \\${nl}git mer\"\"ge feat"
    case_ "$g" ask "$r" "git merge --quit"
    case_ "$g" ask "${r}/wt" "git merge main > /dev/null"
    case_ "$g" ask "${r}/wt" "FOO=1 git merge main"
    case_ "$g" ask "${r}/wt" "git -c core.hooksPath=/dev/null merge main"
    case_ "$g" ask "${r}/wt" "git merge -s ours main"
    case_ "$g" ask "${r}/wt" "git merge main feat"
    case_ "$g" ask "${r}/wt" "bash -c 'git merge main'"
    # Any interpreter handed a quoted command string, listed or not.
    case_ "$g" ask "${r}/wt" "fish -c 'git merge main'"
    case_ "$g" ask "${r}/wt" "pwsh -Command 'git pull'"
    # With pull.rebase set, a pull that names no mode rebases the branch.
    case_ "$g" ask "${r}/wt" "git pull origin main --no-edit"
    case_ "$g" ask "${r}/wt" "git pull origin main"
    case_ "$g" ask "${r}/wt" "/usr/bin/git merge main && echo ok"
    case_ "$g" ask "${r}/wt" "true; gh pr view 1; git merge main"
    case_ "$g" ask "${r}/wt" "git merge 'unbalanced"
    case_ "$g" ask "$r" "git \$'\\x6d\\x65\\x72\\x67\\x65' feat"
    case_ "$g" ask "$r" "git mer\\${nl}ge feat"
    case_ "$g" ask "$r" "git m*rge feat"
    case_ "$g" ask "$r" "git \"\$SUB\" feat"
    # An untokenizable command (a quote opening a heredoc word) is still split
    # on `;&|()`, so a spliced subcommand right after `&&` or `(` is seen.
    case_ "$g" ask "$r" "true&&git \$'\\x6d\\x65\\x72\\x67\\x65' feat <<X${nl}\"hi"
    case_ "$g" ask "$r" "(git mer\"\"ge feat) <<X${nl}\"\\"
    # Options that take a separate value shift the subcommand slot.
    case_ "$g" ask "$r" "git --attr-source HEAD \$'\\x6d\\x65\\x72\\x67\\x65' feat"
    case_ "$g" ask "$r" "git --shallow-file /dev/null \$'\\x6d\\x65\\x72\\x67\\x65' feat"
    case_ "$g" ask "$r" "git --config-env user.name=FOO \"\$SUB\" feat"
    case_ "$g" ask "$r" "git --super-prefix sub/ \$'\\x6d\\x65\\x72\\x67\\x65' feat"
    # Base behavior: evaluator merge/pull mentions stay gated (#1844).
    case_ "$g" silent "${r}/wt" "./scripts/merge-main.sh"
    case_ "$g" ask "${r}/wt" "sh ./scripts/merge-main.sh"
    case_ "$g" ask "${r}/wt" "sh ./merge-main.sh"
    # No git merge/pull: no opinion, including everyday near-misses.
    case_ "$g" silent "${r}/wt" "git merge-base main feat"
    # A quoted word with trailing whitespace is not the word `merge`.
    case_ "$g" silent "${r}/wt" "git log --grep \"Merge \""
    # The integrate skill's own read-only form: an expansion plus `merge-base`.
    case_ "$g" silent "${r}/wt" "base=\"\$(git merge-base HEAD \"\$base_ref\")\""
    case_ "$g" silent "${r}/wt" "gh pr list --json number | xargs -n1 echo pull-requests"
    case_ "$g" ask "${r}/wt" "x=\$(git merge main)"
    # The dashed executables run as commands. Behind an evaluator the index-writing
    # merge plumbing falls under the word test and asks.
    case_ "$g" ask "${r}/wt" "\$(git --exec-path)/git-merge main"
    case_ "$g" ask "${r}/wt" "git-pull origin main"
    case_ "$g" ask "$r" "eval \"git merge-ours feat\""
    case_ "$g" ask "$r" "bash -c 'git merge-recursive base -- HEAD feat'"
    case_ "$g" ask "$r" "eval \"git-merge-ours feat\""
    # An expanded subcommand inside an interpreter string, like the unwrapped form.
    case_ "$g" ask "$r" "bash -c \"git \$SUB main\""
    case_ "$g" ask "$r" "eval \"git \${sub} feat\""
    case_ "$g" silent "${r}/wt" "bash -c \"git log --oneline\""
    # Data is data: a dashed name as an argument, a comment, quoted prose, and
    # a non-merge git call inside a substitution.
    case_ "$g" silent "${r}/wt" "grep -rn git-merge docs/"
    case_ "$g" silent "${r}/wt" "git log -1 # check the merge commit"
    case_ "$g" silent "${r}/wt" "gh pr comment 1 --body \"git \$(git rev-parse HEAD) is the head\""
    case_ "$g" silent "${r}/wt" "git config --get alias.st"
    case_ "$g" silent "${r}/wt" "gh pr comment 1 --body \"run git status with \$FLAGS\""
    # Quoted prose that names both words is data, and so is the guard's own name.
    case_ "$g" silent "${r}/wt" "git commit -m 'docs: explain how git pull works'"
    case_ "$g" silent "${r}/wt" "bash scripts/test-git-merge-guard.sh"
    case_ "$g" silent "${r}/wt" "python3 .claude/hooks/git-merge-guard.py --help"
    case_ "$g" silent "${r}/wt" "git log --merges --oneline"
    case_ "$g" silent "${r}/wt" "git commit -m 'fix: catch-up merge of main'"
    case_ "$g" silent "${r}/wt" "git status && git log -1"
    case_ "$g" ask "${r}/wt" "gh pr merge 1"
    case_ "$g" silent "${r}/wt" "gh pr view \"\$N\" --json mergeStateStatus,mergedAt"
    case_ "$g" silent "${r}/wt" "grep -rn merge docs/"
    # `.sh` is a file extension, not a shell name.
    case_ "$g" silent "${r}/wt" "grep -n merge scripts/worktree-rm.sh"
    case_ "$g" silent "${r}/wt" "ls pull-requests/"
    case_ "$g" silent "${r}/wt" "git -C \"\$HOME\" status"
    case_ "$g" silent "${r}/wt" "git log -- '*.md'"
    case_ "$g" silent "${r}/wt" "git log --format='%h %s' -1"
    case_ "$g" silent "${r}/wt" "cat > body.md <<'EOF'${nl}this pull request adds a guard${nl}EOF"
    # The false prompts from one orchestrated session -- report appends,
    # search patterns, the policy reader's flags, merge-base reads, and one-off
    # scripts that mention them.
    case_ "$g" silent "$r" "cat >> report.md <<'EOF'${nl}ran a catch-up merge of main; git pull next${nl}EOF"
    case_ "$g" silent "$r" "cat >> report.md <<EOF${nl}merged \$(git rev-parse --short HEAD); then git pull${nl}EOF"
    case_ "$g" silent "$r" "grep -n 'merge base' AGENTS.md"
    case_ "$g" silent "$r" "grep -E 'commit|merge|stash' docs/conventions.md"
    case_ "$g" silent "$r" "grep -n merge-base README.md"
    case_ "$g" silent "$r" "node scripts/policy.mjs --merge-base-policy p.toml --merge-base-registry r.json"
    case_ "$g" silent "$r" "git merge-base HEAD origin/main"
    case_ "$g" silent "$r" "git diff \"\$(git merge-base HEAD origin/main)\" --stat"
    case_ "$g" silent "$r" "python3 - <<'EOF'${nl}args = ['--merge-base-policy', 'git pull']${nl}EOF"
    case_ "$g" silent "$r" "node -e \"console.log('--merge-base-policy', 'git merge')\""
    case_ "$g" silent "$r" "git mergetool --tool-help"
    case_ "$g" silent "$r" "echo 'git merge main' > notes.txt"
    # Real and possible invocations still ask, wrapped or evaluated.
    case_ "$g" ask "$r" "git pull --rebase"
    case_ "$g" ask "$r" "bash -c \"git merge main\""
    case_ "$g" ask "$r" "eval \"git pull\""
    case_ "$g" ask "$r" "git-merge main"
    case_ "$g" ask "$r" "/usr/libexec/git-core/git-pull origin main"
    case_ "$g" ask "$r" "timeout 9 git merge feat"
    case_ "$g" ask "$r" "sudo -u evan git pull"
    case_ "$g" ask "$r" "echo main | xargs git merge"
    case_ "$g" ask "$r" "echo merge | xargs git"
    case_ "$g" ask "$r" "ssh host git pull"
    case_ "$g" ask "$r" "ssh host 'cd repo && git merge main'"
    case_ "$g" ask "$r" "watch git pull"
    case_ "$g" ask "$r" "env -S 'git merge feat'"
    case_ "$g" ask "$r" "echo \"\$(git merge feat)\""
    case_ "$g" ask "$r" "echo \`git pull\`"
    case_ "$g" ask "$r" "diff <(git merge feat) /dev/null"
    case_ "$g" ask "$r" "cat <<EOF${nl}\$(git merge feat)${nl}EOF"
    case_ "$g" ask "$r" "bash <<'EOF'${nl}git merge feat${nl}EOF"
    case_ "$g" ask "$r" "sh <<< 'git pull'"
    case_ "$g" ask "$r" "echo 'git merge feat' | sh"
    case_ "$g" ask "$r" "sudo bash -lc 'git pull'"
    # Challenge round 1: substitutions inside `${...}` and `((...))`, ANSI-C
    # strings handed to an evaluator, stdin scripts with positional arguments,
    # wrapper options that take a value, feeders that fill the subcommand, and
    # unreadable commands that never spell merge.
    case_ "$g" ask "$r" "echo \"\${x:-\$(git merge feat)}\""
    case_ "$g" ask "$r" "echo \${x:-\`git pull\`}"
    case_ "$g" ask "$r" "((git merge feat) )"
    case_ "$g" ask "$r" "echo \$((git merge feat) )"
    case_ "$g" ask "$r" "bash -c \$'git merge feat'"
    case_ "$g" ask "$r" "eval \$'git \\x70ull'"
    case_ "$g" ask "$r" "bash -s foo <<'EOF'${nl}git merge feat${nl}EOF"
    case_ "$g" ask "$r" "sudo -u evan sh <<< 'git pull'"
    case_ "$g" ask "$r" "sudo -u evan /usr/libexec/git-core/git-merge feat"
    case_ "$g" ask "$r" "echo merge | xargs -I X git X feat"
    case_ "$g" ask "$r" "echo merge | xargs -I{} git {} feat"
    case_ "$g" ask "$r" "parallel git ::: merge"
    case_ "$g" ask "$r" "git \$x feat${nl}echo 'unbalanced"
    case_ "$g" ask "$r" "git m*rge feat 'x"
    case_ "$g" silent "$r" "echo \$((1 + 2))"
    case_ "$g" silent "$r" "echo \"\${x:-default}\" \"\${#arr[@]}\""
    case_ "$g" silent "$r" "git ls-files | xargs git log --oneline"
    case_ "$g" silent "$r" "sudo -u evan git status"
    # Challenge round 2: an evaluator puts the whole command line under the
    # word test, whatever its options or how its input arrives.
    case_ "$g" ask "$r" "bash -C -c 'git merge feat'"
    case_ "$g" ask "$r" "zsh -C -c 'git pull'"
    case_ "$g" ask "$r" "env -S'git merge feat'"
    case_ "$g" ask "$r" "printf 'git merge feat\\n' | if true; then sh; fi"
    case_ "$g" ask "$r" "bash -C -c \$'git \\x70ull'"
    case_ "$g" silent "$r" "bash -c 'git log --oneline' | head -5"
    case_ "$g" silent "$r" "bash scripts/test-git-merge-guard.sh"
    # Challenge round 3: the csh family ships on macOS.
    case_ "$g" ask "$r" "csh -c 'git merge feat'"
    case_ "$g" ask "$r" "/bin/tcsh -c 'git pull'"
    # A -c payload is a script whatever program takes it.
    case_ "$g" ask "$r" "rc -c 'git merge feat'"
    case_ "$g" silent "$r" "git commit -m 'docs: explain how git pull works' -c 'x'"
    # Review round 2: a search tool's -c is a count, and wrapper option values.
    case_ "$g" silent "$r" "grep -c 'git merge' README.md"
    case_ "$g" silent "$r" "rg -c 'git pull' ."
    case_ "$g" ask "$r" "/usr/bin/time -f %E /usr/lib/git-core/git-merge main"
    case_ "$g" ask "$r" "caffeinate -w 123 /usr/libexec/git-core/git-merge main"
    # Review round 3: a trap action runs later; `git grep -c` counts.
    case_ "$g" ask "$r" "trap 'git merge main' EXIT"
    case_ "$g" silent "$r" "git grep -c 'git merge' -- docs"
    # Integration cycle 1 (Codex cloud): only the invoked alias matters, and
    # busybox runs the applet named next.
    case_ "$g" silent "$r" "git -c alias.x=log status"
    case_ "$g" silent "$r" "git -c alias.lg='log --oneline' lg"
    case_ "$g" ask "$r" "git -c alias.m='!git merge' m feat"
    case_ "$g" ask "$r" "git -c alias.M=merge m feat"
    case_ "$g" ask "$r" "git -c \"\$X\" m feat"
    case_ "$g" ask "$r" "git -c alias.a=b -c alias.b=merge a feat"
    case_ "$g" ask "$r" "git -c alias.g='!git' g merge feat"
    case_ "$g" ask "$r" "git -c alias.o='-C .' o merge feat"
    case_ "$g" silent "$r" "git -c alias.a=b -c alias.b=log a --oneline"
    case_ "$g" silent "$r" "busybox grep -c 'git merge' README.md"
    case_ "$g" ask "$r" "busybox sh -c 'git pull'"
    # Integration cycle 2: the evaluator word test reads decoded words.
    case_ "$g" ask "$r" "printf \$'git \\x70ull\\n' | bash"
    # Integration cycle 3: decoded evaluator names, built-ins over aliases,
    # source builtins, and git's terminal options.
    case_ "$g" ask "$r" "printf 'git pull\\n' | \$'bash'"
    case_ "$g" ask "$r" "\$'/bin/bash' <<< 'git merge main'"
    case_ "$g" ask "$r" "git -c alias.merge=log merge feat"
    case_ "$g" ask "$r" ". /dev/stdin <<< 'git pull'"
    case_ "$g" ask "$r" "source /dev/stdin <<< 'git merge feat'"
    # Every shape below asked under the old word-matching guard.
    # A non-literal command name puts the line under the merge/pull word test.
    case_ "$g" ask "$r" "\$(printf 'git merge main')"
    case_ "$g" ask "$r" "\$(printf %s 'git merge main')"
    case_ "$g" ask "$r" "git\${IFS}merge\${IFS}main"
    case_ "$g" ask "$r" "printf 'git merge main\\n' | \"\$SHELL\""
    case_ "$g" ask "$r" "\"\$SHELL\" <<'EOF'${nl}git pull${nl}EOF"
    case_ "$g" ask "$r" "printf 'git-merge\\n' | xargs -I{} {} feat"
    # Command position: expanded assignments, nested wrappers, coproc.
    case_ "$g" ask "$r" "FOO=\$BAR /usr/lib/git-core/git-merge main"
    case_ "$g" ask "$r" "find . -exec env FOO=1 git-merge main \\;"
    case_ "$g" ask "$r" "coproc git-merge feat"
    case_ "$g" ask "$r" "coproc job /usr/libexec/git-core/git-pull origin main"
    # Runners: parallel with no command, sudo -s/-i, herdr, cmd /c.
    case_ "$g" ask "$r" "parallel 'git merge {}' ::: feat"
    case_ "$g" ask "$r" "parallel ::: 'git merge main'"
    case_ "$g" ask "$r" "printf 'git pull\\n' | parallel"
    case_ "$g" ask "$r" "echo 'git merge main' | sudo -s"
    case_ "$g" ask "$r" "sudo -i <<'EOF'${nl}git pull${nl}EOF"
    case_ "$g" ask "$r" "herdr pane run 42 'git merge main'"
    case_ "$g" ask "$r" "cmd.exe /c \"git merge main\""
    # Locale quoting and env -S trailing arguments.
    case_ "$g" ask "$r" "git \$\"merge\" feat"
    case_ "$g" ask "$r" "\$\"git\" merge feat"
    case_ "$g" ask "$r" "env -Sgit \$SUB main"
    case_ "$g" ask "$r" "env --split-string=git \$SUB main"
    # ...and the new rules leave ordinary commands alone.
    case_ "$g" silent "$r" "\"\$EDITOR\" notes.md"
    case_ "$g" silent "$r" "\$PAGER README.md"
    case_ "$g" silent "$r" "herdr pane list"
    case_ "$g" silent "$r" "sudo -u evan git status"
    case_ "$g" silent "$r" "find . -name '*.md' -exec grep -l merge-base {} +"
    case_ "$g" silent "$r" "git ls-files | parallel wc -l"
    # Challenge round 1: a literal xargs replacement token is still dynamic;
    # sudo's shell mode is read from sudo's own options; only `herdr pane run`
    # runs text.
    case_ "$g" ask "$r" "printf 'git\\n' | xargs -I X X merge feat"
    # A delegated command's own -i now matches sudo's shell flag (see the
    # cycle-2 case below): a prompt, accepted to close sudo's option grammar.
    case_ "$g" ask "$r" "sudo grep -i 'git merge' README.md"
    case_ "$g" silent "$r" "sudo grep -i 'todo' README.md"
    case_ "$g" silent "$r" "herdr pane wait-output p1 --regex 'git merge'"
    # Challenge round 2: herdr global options, cmd's attached payload, and
    # sudo option values that contain s or i.
    case_ "$g" ask "$r" "herdr --session foo pane run 42 'git merge main'"
    case_ "$g" ask "$r" "cmd.exe /cgit \$SUB main"
    case_ "$g" ask "$r" "cmd /kgit pull"
    case_ "$g" silent "$r" "sudo -uadmin grep 'git merge' README.md"
    case_ "$g" ask "$r" "echo 'git pull' | sudo -uadmin -s"
    # Challenge round 3: /c is cmd's alone, and herdr needs the `pane run` pair.
    case_ "$g" silent "$r" "echo /c 'git merge main'"
    case_ "$g" silent "$r" "herdr agent read run | grep merge"
    # Review round 1: a named coproc's brace body, and cmd's own expansions.
    case_ "$g" ask "$r" "coproc job { /usr/libexec/git-core/git-pull origin main; }"
    case_ "$g" ask "$r" "cmd /c git %SUB% main"
    case_ "$g" ask "$r" "cmd /c git m^erge main"
    case_ "$g" silent "$r" "cmd /c dir"
    # Review round 2: Git Bash's doubled and stacked cmd switches.
    case_ "$g" ask "$r" "cmd.exe //c git %SUB% main"
    case_ "$g" ask "$r" "cmd.exe //c git merge main"
    case_ "$g" ask "$r" "cmd /Q/Cgit pull"
    case_ "$g" silent "$r" "cmd //c dir"
    # Integration cycle 1: herdr dispatch words from expansions, and sudo's
    # long-option prefixes.
    case_ "$g" ask "$r" "GROUP=pane; herdr \"\$GROUP\" run 42 'git merge main'"
    case_ "$g" ask "$r" "ACTION=run; herdr pane \"\$ACTION\" 42 'git pull'"
    case_ "$g" ask "$r" "echo 'git merge main' | sudo --sh"
    case_ "$g" ask "$r" "echo 'git pull' | sudo --lo"
    case_ "$g" silent "$r" "sudo --list"
    # Integration cycle 2: a value-taking option's abbreviation before -s.
    case_ "$g" ask "$r" "echo 'git merge main' | sudo --chd /tmp -s"
    # `--` can be an option's value (`-p -- -s`), so it does not end the scan.
    case_ "$g" ask "$r" "echo 'git pull' | sudo -p -- -s"
    case_ "$g" ask "$r" "sudo -- grep -i 'git merge' README.md"
    # Integration cycle 4: wrapper and env long-option abbreviations.
    case_ "$g" ask "$r" "G=git; sudo --chd /repo \"\$G\" merge feature"
    case_ "$g" ask "$r" "env --spl='git merge feature'"
    case_ "$g" ask "$r" "env --split 'git pull'"
    case_ "$g" silent "$r" "sudo --chd /repo git status"
    case_ "$g" silent "$r" "env --unset=FOO git status"
    # Every word after a wrapper may be the command, and `--s` is the
    # shortest env split-string prefix.
    case_ "$g" ask "$r" "env --s='git merge feature'"
    case_ "$g" ask "$r" "G=/usr/bin/git; env --chd /repo -i \"\$G\" merge feature"
    case_ "$g" ask "$r" "sudo --chd /repo -u evan --pres /usr/libexec/git-core/git-pull origin main"
    case_ "$g" silent "$r" "env --chd /repo -i git status"
    case_ "$g" silent "$r" "sudo cp notes.md /tmp/notes.md"
    case_ "$g" silent "$r" "git --help merge"
    case_ "$g" silent "$r" "git --version pull"
    case_ "$g" silent "$r" "echo \"\$SHELL\""
}

echo "==> git-merge-guard decision matrix"
matrix "$guard"
if [[ $failures -ne 0 ]]; then
    echo "TEST FAIL: git-merge-guard: ${failures} case(s) wrong" >&2
    exit 1
fi

primary_case_count=$case_count
echo "==> git-merge-guard applies only in the dev profile"
profile_case() { # profile expected cwd command
    local got
    got="$(FOREMAN_DEVCONTAINER="$1" decide "$guard" "$3" "$4")"
    if [[ $got != "$2" ]]; then
        echo "TEST FAIL: FOREMAN_DEVCONTAINER='$1': expected=$2 got=${got} :: $4" >&2
        exit 1
    fi
}
for profile in bot agent Bot; do
    profile_case "$profile" silent "$r" "git merge feat"
    profile_case "$profile" silent "$r" "git -C ${r} pull"
    profile_case "$profile" silent "$r" "bash -c 'git merge feat'"
    profile_case "$profile" silent "$r" 'gh pr merge 1 --admin'
    profile_case "$profile" silent "$r" 'git push origin HEAD:main'
done
for profile in "" dev; do
    profile_case "$profile" ask "$r" "git merge feat"
    profile_case "$profile" silent "${r}/wt" "git merge origin/main --no-edit"
done

echo "==> git-merge-guard matrix catches a guard that never checks the target branch"
mutant="${tmp}/mutant.py"
sed 's/^        if feature_branch(target) is None:$/        if False:/' "$guard" >"$mutant"
if cmp -s "$guard" "$mutant"; then
    echo "TEST FAIL: mutation did not apply (feature_branch check line changed?)" >&2
    exit 1
fi
QUIET=1 matrix "$mutant"
if [[ $failures -eq 0 ]]; then
    echo "TEST FAIL: matrix passed a guard that allows merges into main" >&2
    exit 1
fi

# The guard only protects anything if settings.json runs it. Exercise the
# REGISTERED command, not the file: a removed or misspelled entry, or a broken
# fail-closed fallback, must fail here.
settings="${repo_root}/.claude/settings.json"
if [[ -z ${GUARD:-} && -f $settings ]]; then
    echo "==> git-merge-guard is registered in .claude/settings.json and fails closed"
    # Match the rendered-settings contract: merge prompts belong to the hook
    # or the dev-only drop-in, while protected/force-push backstops stay here.
    if ! jq -e '[.permissions.ask[] | select(test("^Bash\\(git merge"))] | length == 0' "$settings" >/dev/null; then
        echo "TEST FAIL: project settings still ask on every git merge" >&2
        exit 1
    fi
    if ! jq -e '[.permissions.ask[] | select(test("^Bash\\(gh pr merge"))] | length == 0' "$settings" >/dev/null; then
        echo "TEST FAIL: project settings still ask on gh pr merge" >&2
        exit 1
    fi
    if ! jq -e '.permissions.ask | (index("Bash(git push origin main)") != null) and (index("Bash(git push --force:*)") != null)' "$settings" >/dev/null; then
        echo "TEST FAIL: project settings lost the push-to-main / force-push ask rules" >&2
        exit 1
    fi
    registered="$(jq -r '[.hooks.PreToolUse[]? | select(.matcher == "Bash") | .hooks[]?
        | select(.type == "command" and (.command | contains("git-merge-guard.py")))
        | .command] | first // empty' "$settings")"
    if [[ -z $registered ]]; then
        echo "TEST FAIL: no PreToolUse Bash hook in .claude/settings.json runs git-merge-guard.py" >&2
        exit 1
    fi
    registered_decision() { # project-dir cwd command [reason] -> silent|ask|reason|other
        local input out rc
        if input="$(jq -nc --arg c "$3" --arg d "$2" \
            '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}')"; then
            :
        else
            rc=$?
            echo "rc${rc}"
            return
        fi
        out="$(CLAUDE_PROJECT_DIR="$1" bash -c "$registered" 2>/dev/null <<<"$input")" || true
        if [[ -z $out ]]; then
            echo silent
        elif jq -e '.hookSpecificOutput.permissionDecision == "ask"' <<<"$out" >/dev/null 2>&1; then
            if [[ ${4:-} == reason ]]; then
                jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$out"
            else
                echo ask
            fi
        else
            echo other
        fi
    }
    expect_registered() { # expected project-dir cwd command
        local got
        got="$(registered_decision "$2" "$3" "$4")"
        if [[ $got != "$1" ]]; then
            echo "TEST FAIL: registered hook: expected=$1 got=${got} :: $4 (project dir $2)" >&2
            exit 1
        fi
    }
    actual_registered=$registered
    registered="python3 -c 'import time; time.sleep(0.1)'"
    if [[ $(registered_decision "$repo_root" "$r" "$large_command") != silent ]]; then
        echo "TEST FAIL: successful early-return consumer changed registered decision" >&2
        exit 1
    fi
    if [[ $(PATH="${tmp}/generator-fails:$PATH" registered_decision "$repo_root" "$r" command) != rc23 ]]; then
        echo "TEST FAIL: registered JSON generator sentinel 23 was not preserved" >&2
        exit 1
    fi
    registered="exit 29"
    if [[ $(registered_decision "$repo_root" "$r" command) != silent ]]; then
        echo "TEST FAIL: registered consumer fallback semantics changed" >&2
        exit 1
    fi
    registered=$actual_registered
    expect_registered ask "$repo_root" "$r" "git merge feat"
    expect_registered silent "$repo_root" "${r}/wt" "git merge origin/main --no-edit"
    # A guard that cannot be run must ask, never stay silent.
    expect_registered ask "${tmp}/no-such-project" "${r}/wt" "git merge origin/main --no-edit"
    # Remove python3 from PATH entirely; jq and bash still run the registered
    # command and inspect its existing generic fail-closed fallback.
    mkdir -p "${tmp}/no-python"
    ln -s "$(command -v jq)" "${tmp}/no-python/jq"
    ln -s "$(command -v bash)" "${tmp}/no-python/bash"
    if PATH="${tmp}/no-python" command -v python3 >/dev/null; then
        echo "TEST FAIL: missing-interpreter fixture still finds python3" >&2
        exit 1
    fi
    PATH="${tmp}/no-python" expect_registered ask "$repo_root" "${r}/wt" "git merge origin/main --no-edit"
    if [[ $(PATH="${tmp}/no-python" registered_decision "$repo_root" "${r}/wt" "git merge origin/main --no-edit" reason) != 'git-merge-guard failed to run' ]]; then
        echo "TEST FAIL: missing python3 changed the generic registered fallback reason" >&2
        exit 1
    fi
fi

echo "==> git-merge-guard OK (${primary_case_count} decision cases)"
