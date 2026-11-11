#!/usr/bin/env bash
# Regression tests for delete-merged-branch.sh, the one implementation of
# § Lane teardown step 3. Every case builds real git repositories (a bare
# remote and a clone, no network); `gh` is a stub on PATH that prints fixture
# JSON, and a `git` shim on PATH fakes only `remote get-url` (so the script sees
# github.com URLs while the real remote is a local path) and the two windows
# between the script's read and its delete. Cases: ancestor and squash merges,
# a local tip behind the PR head, a local branch with extra commits (one
# touching a non-ASCII filename), invocation from a subdirectory, an unmerged
# PR, the default branch, another open PR, a cross-repository PR, fetch and
# push URLs naming another repository, a branch checked out in a worktree, a
# remote or local branch already absent, a head commit not yet local, a push
# landing before the remote delete, and a commit landing before the local
# delete; a second push or fetch URL naming another repository, a replacement ref,
# info/grafts, a symbolic local branch, GH_HOST and enterprise tokens. Six
# mutations (no lease, no ancestor check, an unconditional local delete, no
# push-URL check, only the first push URL checked, no symbolic-ref check) must
# each be caught. Bash 3.2 portable.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
script="$here/delete-merged-branch.sh"
test_tmp="$(mktemp -d -t delete-merged-branch-test-XXXXXX)"
test_tmp="$(cd "$test_tmp" && pwd -P)"
trap 'rm -rf "$test_tmp"' EXIT

real_git="$(command -v git)"
bin_dir="$test_tmp/bin"
mkdir -p "$bin_dir"

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_TERMINAL_PROMPT=0

fail() {
    echo "FAIL: $*" >&2
    exit 1
    return 0
}

# gh stub: `pr view` / `pr list` / `repo view` print the fixture files in
# DMB_STATE. `gh` is only ever read here.
cat >"$bin_dir/gh" <<'STUB'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
"pr view") cat "$DMB_STATE/pr-view.json" ;;
"pr list") cat "$DMB_STATE/pr-list.json" ;;
"repo view") cat "$DMB_STATE/repo-view.json" ;;
*) echo "unexpected gh call: $*" >&2; exit 99 ;;
esac
STUB

# git shim (the unquoted heredoc bakes in the real git's path):
#  - `remote get-url [--push] [--all] <name>` prints DMB_FETCH_URL / DMB_PUSH_URL
#    (either may hold several newline-separated URLs);
#  - the first `ls-remote` moves the remote branch to DMB_RACE_OID after it has
#    answered (a push landing between the script's read and its delete);
#  - `update-ref ... -d <ref>` first moves the ref to DMB_LOCAL_RACE_OID (a commit
#    landing between the script's read and its local delete).
cat >"$bin_dir/git" <<STUB
#!/usr/bin/env bash
if [ "\${1:-}" = remote ] && [ "\${2:-}" = get-url ]; then
    case " \$* " in
    *" --push "*) printf '%s\n' "\${DMB_PUSH_URL:-https://github.com/o/r.git}" ;;
    *) printf '%s\n' "\${DMB_FETCH_URL:-https://github.com/o/r.git}" ;;
    esac
    exit 0
fi
if [ "\${1:-}" = ls-remote ] && [ -n "\${DMB_RACE_REMOTE:-}" ] && [ ! -e "\$DMB_STATE/raced" ]; then
    out="\$("$real_git" "\$@")" || exit \$?
    printf '%s\n' "\$out"
    : >"\$DMB_STATE/raced"
    exec "$real_git" --git-dir "\$DMB_RACE_REMOTE" update-ref "refs/heads/\$DMB_RACE_BRANCH" "\$DMB_RACE_OID"
fi
if [ "\${1:-}" = update-ref ] && [ -n "\${DMB_LOCAL_RACE_OID:-}" ]; then
    prev=""
    for arg in "\$@"; do
        if [ "\$prev" = -d ]; then
            "$real_git" update-ref --no-deref "\$arg" "\$DMB_LOCAL_RACE_OID"
            break
        fi
        prev="\$arg"
    done
fi
exec "$real_git" "\$@"
STUB
chmod +x "$bin_dir/gh" "$bin_dir/git"
export PATH="$bin_dir:$PATH"

# new_repo <name>: bare remote + clone on main with one commit, pushed.
new_repo() {
    local name="$1"
    git init -q --bare -b main "$test_tmp/$name.git"
    git init -q -b main "$test_tmp/$name"
    (
        cd "$test_tmp/$name"
        git remote add origin "$test_tmp/$name.git"
        echo base >base.txt
        git add base.txt
        git commit -q -m base
        git push -q origin main
        mkdir sub
    )
}

# set_state <repo> <PR state> <head oid> <merge oid> <open PRs json> [default]
# Env overrides: PR_BRANCH, PR_CROSS, PR_HEAD_REPO ("owner/name").
set_state() {
    local dir="$test_tmp/state-$1" state="$2" head="$3" merge="$4" open="$5" default="${6:-main}"
    local hr="${PR_HEAD_REPO:-o/r}"
    mkdir -p "$dir"
    rm -f "$dir/raced"
    printf '{"state":"%s","headRefName":"%s","headRefOid":"%s","mergeCommit":{"oid":"%s"},"isCrossRepository":%s,"headRepository":{"name":"%s"},"headRepositoryOwner":{"login":"%s"}}\n' \
        "$state" "${PR_BRANCH:-feat/x}" "$head" "$merge" "${PR_CROSS:-false}" "${hr#*/}" "${hr%%/*}" >"$dir/pr-view.json"
    printf '%s\n' "$open" >"$dir/pr-list.json"
    printf '{"defaultBranchRef":{"name":"%s"}}\n' "$default" >"$dir/repo-view.json"
}

# lane_branch <repo>: feat/x with one commit adding f.txt, pushed; prints oid.
lane_branch() {
    (
        cd "$test_tmp/$1"
        git checkout -q -b feat/x
        echo feature >f.txt
        git add f.txt
        git commit -q -m feature
        git push -q origin feat/x
        git checkout -q main
        git rev-parse feat/x
    )
}

# ancestor_merge <repo>: a two-parent merge commit on main (built with plumbing)
ancestor_merge() {
    (
        cd "$test_tmp/$1"
        git checkout -q main
        git checkout -q feat/x -- f.txt
        tree="$(git write-tree)"
        oid="$(git commit-tree "$tree" -p main -p feat/x -m merge)"
        git update-ref refs/heads/main "$oid"
        git reset -q --hard main
        git push -q origin main
        echo "$oid"
    )
}

# squash_merge <repo>: one single-parent commit on main with the same content
squash_merge() {
    (
        cd "$test_tmp/$1"
        git checkout -q main
        git checkout -q feat/x -- f.txt
        git commit -q -m squash
        git push -q origin main
        git rev-parse HEAD
    )
}

# merged_repo <name>: a repo whose PR (#7, branch feat/x) merged as a squash;
# sets head and merge, and writes the MERGED state.
merged_repo() {
    new_repo "$1"
    head="$(lane_branch "$1")"
    merge="$(squash_merge "$1")"
    set_state "$1" MERGED "$head" "$merge" '[]'
}

# run_script <script> <repo> <expected exit> <label> [branch]: runs from the
# clone (or from its sub/ directory when SUBDIR is set).
run_script() {
    local sh="$1" repo="$2" want="$3" label="$4" branch="${5:-feat/x}" rc=0
    (cd "$test_tmp/$repo${SUBDIR:+/$SUBDIR}" && DMB_STATE="$test_tmp/state-$repo" "$sh" o/r 7 "$branch" origin) \
        >"$test_tmp/out" 2>&1 || rc=$?
    [ "$rc" = "$want" ] || fail "$label: exit $rc, wanted $want: $(cat "$test_tmp/out")"
}

remote_has() { "$real_git" --git-dir "$test_tmp/$1.git" show-ref --verify --quiet "refs/heads/$2"; }
local_has() { "$real_git" -C "$test_tmp/$1" show-ref --verify --quiet "refs/heads/$2"; }
untouched() { # untouched <repo> <label>: both branches survived a refusal
    local_has "$1" feat/x || fail "$2: the local branch was deleted"
    remote_has "$1" feat/x || fail "$2: the remote branch was deleted"
}

export DMB_STATE=""

# ── ancestor merge: both branches deleted ─────────────────────────────
new_repo anc
head="$(lane_branch anc)"
merge="$(ancestor_merge anc)"
set_state anc MERGED "$head" "$merge" '[]'
run_script "$script" anc 0 "ancestor merge"
local_has anc feat/x && fail "ancestor merge: the local branch survived"
remote_has anc feat/x && fail "ancestor merge: the remote branch survived"

# ── squash merge, run from a subdirectory: both branches deleted ──────
merged_repo sq
SUBDIR=sub run_script "$script" sq 0 "squash merge from a subdirectory"
local_has sq feat/x && fail "squash merge: the local branch survived"
remote_has sq feat/x && fail "squash merge: the remote branch survived"

# ── local tip behind the PR head: allowed ─────────────────────────────
new_repo behind
first="$(lane_branch behind)"
(
    cd "$test_tmp/behind"
    git checkout -q feat/x
    echo second >second.txt
    git add second.txt
    git commit -q -m second
    git push -q origin feat/x
    git checkout -q main
)
head="$("$real_git" -C "$test_tmp/behind" rev-parse feat/x)"
"$real_git" -C "$test_tmp/behind" branch -q -f feat/x "$first"
merge="$(squash_merge behind)"
set_state behind MERGED "$head" "$merge" '[]'
run_script "$script" behind 0 "local tip behind the PR head"
remote_has behind feat/x && fail "behind: the remote branch survived"

# ── unmerged PR, default branch, another open PR, cross-repo, other repo ──
merged_repo refuse
set_state refuse OPEN "$head" "$merge" '[]'
run_script "$script" refuse 3 "unmerged PR"
set_state refuse MERGED "$head" "$merge" '[{"number":9}]'
run_script "$script" refuse 3 "another open PR on the head"
set_state refuse MERGED "$head" "$merge" '[]' feat/x
run_script "$script" refuse 3 "head branch is the default branch"
PR_CROSS=true set_state refuse MERGED "$head" "$merge" '[]'
run_script "$script" refuse 3 "cross-repository PR"
PR_HEAD_REPO=fork/r set_state refuse MERGED "$head" "$merge" '[]'
run_script "$script" refuse 3 "head repository is not the target repository"
set_state refuse MERGED "$head" "$merge" '[]'
DMB_FETCH_URL=https://github.com/other/r.git run_script "$script" refuse 3 "fetch URL names another repository"
DMB_PUSH_URL=git@github.com:other/r.git run_script "$script" refuse 3 "push URL names another repository"
DMB_PUSH_URL=https://example.com/o/r.git run_script "$script" refuse 3 "push URL is not github.com"
untouched refuse "refused cases"
"$real_git" -C "$test_tmp/refuse" worktree add -q "$test_tmp/refuse-wt" feat/x
run_script "$script" refuse 3 "branch checked out in a worktree"
untouched refuse "checked-out branch"
DMB_PUSH_URL=$'https://github.com/o/r.git\ngit@github.com:other/r.git' run_script "$script" refuse 3 "a second push URL names another repository"
DMB_FETCH_URL=$'https://github.com/o/r.git\nhttps://github.com/other/r.git' run_script "$script" refuse 3 "a second fetch URL names another repository"
GH_HOST=ghe.example.com run_script "$script" refuse 3 "GH_HOST names another host"
GITHUB_ENTERPRISE_TOKEN=x run_script "$script" refuse 3 "an enterprise token is set"
GH_ENTERPRISE_TOKEN=x run_script "$script" refuse 3 "an enterprise token is set"
untouched refuse "second URL, host and token cases"
"$real_git" -C "$test_tmp/refuse" worktree remove --force "$test_tmp/refuse-wt"
"$real_git" -C "$test_tmp/refuse" replace "$head" "$("$real_git" -C "$test_tmp/refuse" rev-parse main)"
run_script "$script" refuse 3 "a replacement ref exists"
"$real_git" -C "$test_tmp/refuse" replace -d "$head" >/dev/null
printf '%s\n' "$head" >"$test_tmp/refuse/.git/info/grafts"
run_script "$script" refuse 3 "info/grafts exists"
rm -f "$test_tmp/refuse/.git/info/grafts"
untouched refuse "replace and graft cases"
PR_BRANCH=main set_state refuse MERGED "$head" "$merge" '[]'
run_script "$script" refuse 3 "the default branch itself" main
local_has refuse main || fail "default branch: deleted locally"
remote_has refuse main || fail "default branch: deleted remotely"

# extra_case <n> <script> <want>: a local commit after the PR head, touching a
# non-ASCII filename, is not the head or an ancestor of it
extra_case() {
    local name="extra$1"
    merged_repo "$name"
    (
        cd "$test_tmp/$name"
        git checkout -q feat/x
        echo more >"é-ünï.txt"
        git add .
        git commit -q -m "after the PR head"
        git checkout -q main
    )
    SUBDIR=sub run_script "$2" "$name" "$3" "local branch with an extra commit"
    if [ "$3" = 3 ]; then untouched "$name" "extra commit"; fi
}
extra_case 1 "$script" 3

# symref_case <n> <script> <want>: feat/x is a symbolic ref to a branch at the
# PR head, so a deref delete would remove the target and a no-deref one the alias
symref_case() {
    local name="symref$1"
    merged_repo "$name"
    (
        cd "$test_tmp/$name"
        git branch -q target "$head"
        git branch -q -D feat/x
        git symbolic-ref refs/heads/feat/x refs/heads/target
    )
    run_script "$2" "$name" "$3" "symbolic local branch"
    if [ "$3" = 3 ]; then
        "$real_git" -C "$test_tmp/$name" symbolic-ref -q refs/heads/feat/x >/dev/null || fail "$name: the symbolic ref was deleted"
        local_has "$name" target || fail "$name: the target branch was deleted"
        remote_has "$name" feat/x || fail "$name: the remote branch was deleted"
    fi
}
symref_case 1 "$script" 3

# ── remote moved before the read: refuse ──────────────────────────────
merged_repo moved
(
    cd "$test_tmp/moved"
    git checkout -q feat/x
    echo late >late.txt
    git add late.txt
    git commit -q -m late
    git push -q origin feat/x
    git checkout -q main
    git branch -q -D feat/x
)
run_script "$script" moved 3 "remote not at the PR head"
remote_has moved feat/x || fail "moved remote: the remote branch was deleted"

# ── remote already absent / local already absent: success ──────────────
merged_repo gone
"$real_git" --git-dir "$test_tmp/gone.git" update-ref -d refs/heads/feat/x
run_script "$script" gone 0 "remote already absent"
local_has gone feat/x && fail "remote absent: the local branch survived"
merged_repo nolocal
git -C "$test_tmp/nolocal" branch -q -D feat/x
run_script "$script" nolocal 0 "local already absent"
remote_has nolocal feat/x && fail "local absent: the remote branch survived"

# ── the head commit is not local yet: fetched from the verified remote ──
merged_repo fetchsrc
"$real_git" clone -q --no-local --single-branch -b main "$test_tmp/fetchsrc.git" "$test_tmp/fetchc"
cp -R "$test_tmp/state-fetchsrc" "$test_tmp/state-fetchc"
"$real_git" -C "$test_tmp/fetchc" cat-file -e "$head^{commit}" 2>/dev/null && fail "fetch fixture: the head is already local"
(cd "$test_tmp/fetchc" && DMB_STATE="$test_tmp/state-fetchc" "$script" o/r 7 feat/x origin) >"$test_tmp/out" 2>&1 ||
    fail "head not local: $(cat "$test_tmp/out")"
"$real_git" --git-dir "$test_tmp/fetchsrc.git" show-ref --verify --quiet refs/heads/feat/x && fail "head not local: the remote branch survived"

# race_case <n> <script> <want>: a push lands after the script's read
race_case() {
    local name="race$1" sh="$2" want="$3" rc=0 newer remote_oid
    merged_repo "$name"
    (
        cd "$test_tmp/$name"
        git checkout -q -b other feat/x
        echo landed >landed.txt
        git add landed.txt
        git commit -q -m landed
        git push -q origin other
        git checkout -q main
        git branch -q -D other
    )
    newer="$("$real_git" --git-dir "$test_tmp/$name.git" rev-parse refs/heads/other)"
    (
        cd "$test_tmp/$name"
        DMB_STATE="$test_tmp/state-$name" DMB_RACE_REMOTE="$test_tmp/$name.git" \
            DMB_RACE_BRANCH=feat/x DMB_RACE_OID="$newer" "$sh" o/r 7 feat/x origin
    ) >"$test_tmp/out" 2>&1 || rc=$?
    [ "$rc" = "$want" ] || fail "$name: exit $rc, wanted $want: $(cat "$test_tmp/out")"
    remote_oid="$("$real_git" --git-dir "$test_tmp/$name.git" rev-parse --verify -q refs/heads/feat/x || true)"
    [ "$remote_oid" = "$newer" ] || fail "$name: the pushed commit was not preserved (remote at '$remote_oid')"
}
race_case 1 "$script" 4

# local_race_case <n> <script> <want>: a commit lands on the local branch after
# the script's read; the delete must fail and leave the ref where it moved to
local_race_case() {
    local name="lrace$1" sh="$2" want="$3" rc=0 newer
    merged_repo "$name"
    newer="$(cd "$test_tmp/$name" && git commit-tree -p feat/x -m late "feat/x^{tree}")"
    (
        cd "$test_tmp/$name"
        DMB_STATE="$test_tmp/state-$name" DMB_LOCAL_RACE_OID="$newer" "$sh" o/r 7 feat/x origin
    ) >"$test_tmp/out" 2>&1 || rc=$?
    [ "$rc" = "$want" ] || fail "$name: exit $rc, wanted $want: $(cat "$test_tmp/out")"
    [ "$("$real_git" -C "$test_tmp/$name" rev-parse refs/heads/feat/x)" = "$newer" ] ||
        fail "$name: the moved local ref was not preserved"
    remote_has "$name" feat/x || fail "$name: the remote branch was deleted"
}
local_race_case 1 "$script" 4

# url_case <n> <script> <want> [push URLs]: a push URL names another repository
url_case() {
    local name="url$1" rc=0
    merged_repo "$name"
    (
        cd "$test_tmp/$name"
        DMB_STATE="$test_tmp/state-$name" DMB_PUSH_URL="${4:-git@github.com:other/r.git}" "$2" o/r 7 feat/x origin
    ) >"$test_tmp/out" 2>&1 || rc=$?
    [ "$rc" = "$3" ] || fail "$name: exit $rc, wanted $3: $(cat "$test_tmp/out")"
    untouched "$name" "push URL"
}
url_case 1 "$script" 3
second_push=$'https://github.com/o/r.git\ngit@github.com:other/r.git'
url_case 3 "$script" 3 "$second_push"

# ── mutations: each weakened script must be caught by its case ────────
mutate() { # mutate <name> <sed expr>
    sed "$2" "$script" >"$test_tmp/mut-$1.sh"
    chmod +x "$test_tmp/mut-$1.sh"
    if cmp -s "$script" "$test_tmp/mut-$1.sh"; then
        fail "ineffective mutation: $1"
    fi
}

# shellcheck disable=SC2016 # the sed expressions are literal text
{
    # 1. no lease: a plain delete discards the pushed commit
    mutate nolease 's| --force-with-lease="refs/heads/$branch:$head_oid"||'
    # 2. no ancestor check: a local branch with extra commits is deleted
    mutate noancestor 's|! git merge-base --is-ancestor "$local_tip" "$head_oid"|! true|'
    # 3. unconditional local delete: a commit that landed is discarded
    mutate noexpect 's|git update-ref --no-deref -d "refs/heads/$branch" "$local_tip"|git update-ref --no-deref -d "refs/heads/$branch"|'
    # 4. no push-URL check: a delete is sent to another repository
    mutate nopushurl 's|urls_match "$push_urls" \|\| refuse|true \|\| refuse|'
    # 5. only the first push URL is checked: a second destination goes unverified
    mutate firstpushurl 's|get-url --push --all "$remote")"|get-url --push --all "$remote" \| head -n 1)"|'
    # 6. no symbolic-ref check: an alias is treated as a plain branch
    mutate nosymref 's|if git symbolic-ref -q "refs/heads/$branch" >/dev/null; then|if false; then|'
}
if (race_case 2 "$test_tmp/mut-nolease.sh" 4) >/dev/null 2>&1; then
    fail "mutation not caught: remote delete without a lease"
fi
if (extra_case 2 "$test_tmp/mut-noancestor.sh" 3) >/dev/null 2>&1; then
    fail "mutation not caught: ancestor check removed"
fi
if (local_race_case 2 "$test_tmp/mut-noexpect.sh" 4) >/dev/null 2>&1; then
    fail "mutation not caught: unconditional local delete"
fi
if (url_case 2 "$test_tmp/mut-nopushurl.sh" 3) >/dev/null 2>&1; then
    fail "mutation not caught: push URL not checked"
fi
if (url_case 4 "$test_tmp/mut-firstpushurl.sh" 3 "$second_push") >/dev/null 2>&1; then
    fail "mutation not caught: only the first push URL checked"
fi
if (symref_case 2 "$test_tmp/mut-nosymref.sh" 3) >/dev/null 2>&1; then
    fail "mutation not caught: symbolic ref not refused"
fi

echo "delete-merged-branch: ok"
