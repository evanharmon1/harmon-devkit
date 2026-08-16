#!/usr/bin/env bash
# Hermetic tests for the gauntlet round-push helper (push-round.sh).
#
# Every case below is a defect that was found in the PROSE this helper
# replaces — by adversarial review, or by running the recipe and watching it
# fail. They are pinned here so the mechanism is tested rather than described:
# a markdown snippet cannot assert that `cut` masks an exit status, that
# --force-with-lease is not fast-forward-only, or that a wildcard push refspec
# publishes unrelated branches.
#
# No network: remotes are local bare repositories.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
helper="${repo_root}/ai/skills/universal/gauntlet/assets/push-round.sh"
test_tmp="$(mktemp -d -t gauntlet-push-test-XXXXXX)"
trap 'rm -rf "$test_tmp"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

rc=0
out=
err=

run() {
    set +e
    out="$("$helper" "$@" 2>"${test_tmp}/stderr")"
    rc=$?
    set -e
    err="$(cat "${test_tmp}/stderr")"
}

assert_rc() {
    [ "$rc" -eq "$1" ] || fail "expected rc $1, got $rc: stdout='$out' stderr='$err'"
}

assert_reason() {
    [ -n "$err" ] || fail "a refusal must carry a reason on stderr (rc=$rc)"
}

git_q() { git -C "$1" "${@:2}" >/dev/null 2>&1; }

# A fresh origin+clone pair, with one commit on main.
#
# Both repositories pin HEAD to refs/heads/main rather than inheriting
# init.defaultBranch: where that is `master`, the bare repo's HEAD names a ref
# the fixture never creates, and a later `git clone` of it checks out nothing —
# `warning: remote HEAD refers to nonexistent ref` — after which commits land on
# an unrelated root branch. symbolic-ref is used instead of `init -b` so the
# fixture does not require git 2.28+.
new_fixture() {
    local name="$1" root="${test_tmp}/$1"
    mkdir -p "$root"
    git init --bare -q "${root}/origin.git"
    git -C "${root}/origin.git" symbolic-ref HEAD refs/heads/main
    git init -q "${root}/work"
    git -C "${root}/work" symbolic-ref HEAD refs/heads/main
    git_q "${root}/work" config user.email t@example.com
    git_q "${root}/work" config user.name Test
    git_q "${root}/work" config commit.gpgsign false
    echo one >"${root}/work/f"
    git_q "${root}/work" add f
    git_q "${root}/work" commit -m one
    git_q "${root}/work" remote add origin "${root}/origin.git"
    printf '%s' "$root"
}

commit_on() {
    echo "$3" >"$1/f"
    git_q "$1" add f
    git_q "$1" commit -m "$2"
    git -C "$1" rev-parse HEAD
}

echo "==> usage errors exit 2"
run --branch b --sha deadbeef
assert_rc 2
run --remote origin --branch b
assert_rc 2

echo "==> a --sha that is not a commit here is refused, not pushed"
root="$(new_fixture notacommit)"
cd "${root}/work"
run --remote origin --branch main --sha 0000000000000000000000000000000000000000
assert_rc 3
assert_reason

echo "==> an abbreviated --sha is refused — it would be re-resolved at push time"
root="$(new_fixture shortsha)"
cd "${root}/work"
short="$(git rev-parse --short HEAD)"
run --remote origin --branch main --sha "$short"
assert_rc 3
assert_reason

echo "==> an ls-remote failure refuses — the masked-exit-status defect"
# The prose used `git ls-remote … | cut -f1`; cut exits 0 whatever ls-remote
# did, so a transport failure yielded an empty oid and downgraded the push to
# an unleased one. Here the remote does not exist at all.
root="$(new_fixture lsremotefail)"
cd "${root}/work"
git remote add broken "${test_tmp}/definitely-not-a-repo"
run --remote broken --branch main --sha "$(git rev-parse HEAD)"
assert_rc 3
assert_reason
case "$err" in *ls-remote*) : ;; *) fail "refusal should name ls-remote: $err" ;; esac

echo "==> a first push to an absent branch leases against emptiness"
root="$(new_fixture absent)"
cd "${root}/work"
run --remote origin --branch main --sha "$(git rev-parse HEAD)" --dry-run
assert_rc 0
case "$out" in *"--force-with-lease=refs/heads/main:"*) : ;; *) fail "absent branch must still be leased: $out" ;; esac

echo "==> a fast-forward push succeeds and lands the gated sha"
root="$(new_fixture ff)"
cd "${root}/work"
first="$(git rev-parse HEAD)"
run --remote origin --branch main --sha "$first"
assert_rc 0
[ "$(git -C "${root}/origin.git" rev-parse refs/heads/main)" = "$first" ] ||
    fail "origin/main should be $first"
second="$(commit_on "${root}/work" two two)"
run --remote origin --branch main --sha "$second"
assert_rc 0
[ "$(git -C "${root}/origin.git" rev-parse refs/heads/main)" = "$second" ] ||
    fail "origin/main should have advanced to $second"

echo "==> an already-current remote is a no-op, not a push"
run --remote origin --branch main --sha "$second"
assert_rc 0

echo "==> a divergent remote head is refused — the lease is NOT fast-forward-only"
# --force-with-lease asserts the ref is what you last observed and then
# authorizes a non-fast-forward update over it. Observing another actor's
# commit and leasing against it is how the lease authorizes the clobber it
# appears to prevent. The helper adds the ancestry check the lease lacks.
root="$(new_fixture divergent)"
cd "${root}/work"
base="$(git rev-parse HEAD)"
run --remote origin --branch main --sha "$base"
assert_rc 0
# another actor pushes a commit we do not have
git clone -q "${root}/origin.git" "${root}/other"
git_q "${root}/other" config user.email o@example.com
git_q "${root}/other" config user.name Other
theirs="$(commit_on "${root}/other" theirs theirs)"
git_q "${root}/other" push origin HEAD:refs/heads/main
# our round commit descends from base, not from theirs
mine="$(commit_on "${root}/work" mine mine)"
run --remote origin --branch main --sha "$mine"
assert_rc 3
assert_reason
[ "$(git -C "${root}/origin.git" rev-parse refs/heads/main)" = "$theirs" ] ||
    fail "the other actor's commit must survive a refused push"

echo "==> only the named branch is pushed, even with a wildcard push refspec"
# With no refspec on the command line git consults remote.<name>.push, so a
# wildcard there publishes unrelated local branches. The helper always names
# the ref.
root="$(new_fixture wildcard)"
cd "${root}/work"
git config remote.origin.push 'refs/heads/*:refs/heads/*'
git_q "${root}/work" checkout -b unrelated
commit_on "${root}/work" unrelated unrelated >/dev/null
git_q "${root}/work" checkout main
run --remote origin --branch main --sha "$(git rev-parse HEAD)"
assert_rc 0
if git -C "${root}/origin.git" rev-parse --verify --quiet refs/heads/unrelated >/dev/null; then
    fail "the wildcard refspec leaked an unrelated branch to the remote"
fi

echo "==> a branch created between the read and the push is rejected"
# The absent-branch path leases against emptiness rather than omitting the
# lease, so a concurrent creation cannot be silently advanced.
root="$(new_fixture creationrace)"
cd "${root}/work"
ancestor="$(git rev-parse HEAD)"
mine="$(commit_on "${root}/work" mine mine)"
# The helper read an absent branch and built an empty lease. Between that read
# and the push, another actor creates the branch — at a commit that IS an
# ancestor of ours, which is the case an unleased push would silently advance.
git_q "${root}/work" push origin "${ancestor}:refs/heads/raced"
set +e
git push origin "${mine}:refs/heads/raced" --force-with-lease=refs/heads/raced: >/dev/null 2>&1
race_rc=$?
set -e
[ "$race_rc" -ne 0 ] ||
    fail "the empty lease must reject a branch created since the read (an unleased push would have advanced it)"
[ "$(git -C "${root}/origin.git" rev-parse refs/heads/raced)" = "$ancestor" ] ||
    fail "the concurrently created branch must be left where the other actor put it"

echo "gauntlet push-round tests OK"
