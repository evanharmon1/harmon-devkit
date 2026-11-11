#!/usr/bin/env bash
# Regression tests for delete-merged-branch.sh, the one implementation of
# § Lane teardown step 3. Every case builds real git repositories (a bare
# remote and a clone, no network); `gh` is a stub on PATH that prints fixture
# JSON. The cases carry the review scenarios: a push that lands between the
# read and the delete, a local branch with extra commits, a remote the host
# already deleted, ancestor and squash containment, an unmerged PR, the default
# branch, and another open PR on the head. Two mutations (drop the lease, drop
# the local-tip check) must each be caught. Bash 3.2 portable.
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

# gh stub: `pr view` / `pr list` / `repo view` print the fixture files named by
# DMB_STATE (a directory). `gh` is only ever read here.
cat >"$bin_dir/gh" <<'STUB'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
"pr view") cat "$DMB_STATE/pr-view.json" ;;
"pr list") cat "$DMB_STATE/pr-list.json" ;;
"repo view") cat "$DMB_STATE/repo-view.json" ;;
*) echo "unexpected gh call: $*" >&2; exit 99 ;;
esac
STUB

# git shim: after a real `ls-remote` answers, a push "lands" on the remote when
# DMB_RACE_REMOTE is set, moving the branch to DMB_RACE_OID. That is the window
# between the script's read and its delete.
cat >"$bin_dir/git" <<STUB
#!/usr/bin/env bash
if [ "\${1:-}" = ls-remote ] && [ -n "\${DMB_RACE_REMOTE:-}" ] && [ ! -e "\$DMB_STATE/raced" ]; then
    out="\$("$real_git" "\$@")" || exit \$?
    printf '%s\n' "\$out"
    : >"\$DMB_STATE/raced"
    exec "$real_git" --git-dir "\$DMB_RACE_REMOTE" update-ref "refs/heads/\$DMB_RACE_BRANCH" "\$DMB_RACE_OID"
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
    )
}

# set_state <state dir> <PR state> <head oid> <merge oid> <open PRs json> [default]
set_state() {
    local dir="$1" state="$2" head="$3" merge="$4" open="$5" default="${6:-main}"
    mkdir -p "$dir"
    rm -f "$dir/raced"
    printf '{"state":"%s","headRefName":"%s","headRefOid":"%s","mergeCommit":{"oid":"%s"}}\n' \
        "$state" "${PR_BRANCH:-feat/x}" "$head" "$merge" >"$dir/pr-view.json"
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

# run_script <script> <repo> <expected exit> <label> [branch]: runs from the clone
run_script() {
    local sh="$1" repo="$2" want="$3" label="$4" branch="${5:-feat/x}" rc=0
    (cd "$test_tmp/$repo" && DMB_STATE="$test_tmp/state-$repo" "$sh" o/r 7 "$branch" origin) \
        >"$test_tmp/out" 2>&1 || rc=$?
    [ "$rc" = "$want" ] || fail "$label: exit $rc, wanted $want: $(cat "$test_tmp/out")"
}

remote_has() { "$real_git" --git-dir "$test_tmp/$1.git" show-ref --verify --quiet "refs/heads/$2"; }
local_has() { "$real_git" -C "$test_tmp/$1" show-ref --verify --quiet "refs/heads/$2"; }

export DMB_STATE=""

# ── ancestor merge: both branches deleted ─────────────────────────────
new_repo anc
head="$(lane_branch anc)"
merge="$(ancestor_merge anc)"
set_state "$test_tmp/state-anc" MERGED "$head" "$merge" '[]'
run_script "$script" anc 0 "ancestor merge"
local_has anc feat/x && fail "ancestor merge: the local branch survived"
remote_has anc feat/x && fail "ancestor merge: the remote branch survived"

# ── squash merge: tree-identical on the branch's paths ────────────────
new_repo sq
head="$(lane_branch sq)"
merge="$(squash_merge sq)"
set_state "$test_tmp/state-sq" MERGED "$head" "$merge" '[]'
run_script "$script" sq 0 "squash merge"
local_has sq feat/x && fail "squash merge: the local branch survived"
remote_has sq feat/x && fail "squash merge: the remote branch survived"

# ── unmerged PR, default branch, another open PR: refuse, delete nothing ──
new_repo open
head="$(lane_branch open)"
merge="$(squash_merge open)"
set_state "$test_tmp/state-open" OPEN "$head" "$merge" '[]'
run_script "$script" open 3 "unmerged PR"
set_state "$test_tmp/state-open" MERGED "$head" "$merge" '[{"number":9}]'
run_script "$script" open 3 "another open PR on the head"
set_state "$test_tmp/state-open" MERGED "$head" "$merge" '[]' feat/x
run_script "$script" open 3 "head branch is the default branch"
local_has open feat/x || fail "refused cases: the local branch was deleted"
remote_has open feat/x || fail "refused cases: the remote branch was deleted"
PR_BRANCH=main set_state "$test_tmp/state-open" MERGED "$head" "$merge" '[]'
run_script "$script" open 3 "the default branch itself" main
local_has open main || fail "default branch: deleted locally"
remote_has open main || fail "default branch: deleted remotely"

# ── local branch with extra commits: refuse (the actual tip is checked) ──
new_repo extra
head="$(lane_branch extra)"
merge="$(squash_merge extra)"
(
    cd "$test_tmp/extra"
    git checkout -q feat/x
    echo more >extra.txt
    git add extra.txt
    git commit -q -m "after the PR head"
    git checkout -q main
)
set_state "$test_tmp/state-extra" MERGED "$head" "$merge" '[]'
run_script "$script" extra 3 "local branch with extra commits"
local_has extra feat/x || fail "extra commits: the local branch was deleted"
remote_has extra feat/x || fail "extra commits: the remote branch was deleted"

# ── remote moved before the read: refuse ──────────────────────────────
new_repo moved
head="$(lane_branch moved)"
merge="$(squash_merge moved)"
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
set_state "$test_tmp/state-moved" MERGED "$head" "$merge" '[]'
run_script "$script" moved 3 "remote not at the PR head"
remote_has moved feat/x || fail "moved remote: the remote branch was deleted"

# ── remote already deleted by the host: success, local still removed ──
new_repo gone
head="$(lane_branch gone)"
merge="$(squash_merge gone)"
"$real_git" --git-dir "$test_tmp/gone.git" update-ref -d refs/heads/feat/x
set_state "$test_tmp/state-gone" MERGED "$head" "$merge" '[]'
run_script "$script" gone 0 "remote already absent"
local_has gone feat/x && fail "remote absent: the local branch survived"

# ── local branch already absent: success, remote removed ──────────────
new_repo nolocal
head="$(lane_branch nolocal)"
merge="$(squash_merge nolocal)"
git -C "$test_tmp/nolocal" branch -q -D feat/x
set_state "$test_tmp/state-nolocal" MERGED "$head" "$merge" '[]'
run_script "$script" nolocal 0 "local already absent"
remote_has nolocal feat/x && fail "local absent: the remote branch survived"

# ── a push lands between the read and the delete: the lease must hold ──
# race_case <label> <script>: builds the scenario and returns the script's exit
race_case() {
    local name="race$1" sh="$2" want="$3" rc=0
    new_repo "$name"
    head="$(lane_branch "$name")"
    merge="$(squash_merge "$name")"
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
    set_state "$test_tmp/state-$name" MERGED "$head" "$merge" '[]'
    # the local branch keeps the PR head, so only the lease can notice the push
    (
        cd "$test_tmp/$name"
        DMB_STATE="$test_tmp/state-$name" DMB_RACE_REMOTE="$test_tmp/$name.git" \
            DMB_RACE_BRANCH=feat/x DMB_RACE_OID="$newer" "$sh" o/r 7 feat/x origin
    ) >"$test_tmp/out" 2>&1 || rc=$?
    [ "$rc" = "$want" ] || fail "$name: exit $rc, wanted $want: $(cat "$test_tmp/out")"
    remote_oid="$("$real_git" --git-dir "$test_tmp/$name.git" rev-parse --verify -q refs/heads/feat/x || true)"
    if [ "$want" = 0 ]; then
        [ -z "$remote_oid" ] || fail "$name: the remote branch survived"
    else
        [ "$remote_oid" = "$newer" ] || fail "$name: the pushed commit was not preserved (remote at '${remote_oid}')"
    fi
}
race_case 1 "$script" 4

# ── mutations: each weakened script must be caught by its case ────────
mutate() { # mutate <name> <sed expr>
    sed "$2" "$script" >"$test_tmp/mut-$1.sh"
    chmod +x "$test_tmp/mut-$1.sh"
    if cmp -s "$script" "$test_tmp/mut-$1.sh"; then
        fail "ineffective mutation: $1"
    fi
}

# 1. no lease: a plain delete discards the pushed commit
# shellcheck disable=SC2016 # the sed expression is literal text
mutate nolease 's| --force-with-lease="refs/heads/$branch:$head_oid"||'
if (race_case 2 "$test_tmp/mut-nolease.sh" 4) >/dev/null 2>&1; then
    fail "mutation not caught: remote delete without a lease"
fi

# 2. the local tip is replaced by the PR head: extra commits go unnoticed
# shellcheck disable=SC2016 # the sed expression is literal text
mutate notip 's|contained "$local_tip" |contained "$head_oid" |'
new_repo mextra
head="$(lane_branch mextra)"
merge="$(squash_merge mextra)"
(
    cd "$test_tmp/mextra"
    git checkout -q feat/x
    echo more >extra.txt
    git add extra.txt
    git commit -q -m "after the PR head"
    git checkout -q main
)
set_state "$test_tmp/state-mextra" MERGED "$head" "$merge" '[]'
if (run_script "$test_tmp/mut-notip.sh" mextra 3 "mutant without the local-tip check") >/dev/null 2>&1; then
    fail "mutation not caught: local tip check removed"
fi

echo "delete-merged-branch: ok"
