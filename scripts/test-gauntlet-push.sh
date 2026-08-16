#!/usr/bin/env bash
# Hermetic tests for gauntlet/assets/push-round.sh.
#
# The suite runs twice with opposite init.defaultBranch values. All remotes are
# local bare repositories, and the forge permission query is a PATH stub.

set -euo pipefail

if [ "${GAUNTLET_TEST_CHILD:-}" != 1 ]; then
    for default_branch in main master; do
        echo "==> gauntlet push suite with init.defaultBranch=${default_branch}"
        GAUNTLET_TEST_CHILD=1 GAUNTLET_TEST_DEFAULT_BRANCH="$default_branch" "$0"
    done
    echo "gauntlet push-round helper: PASS"
    exit 0
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
helper="${repo_root}/ai/skills/universal/gauntlet/assets/push-round.sh"
test_tmp="$(mktemp -d -t gauntlet-push-test-XXXXXX)"
trap 'rm -rf "$test_tmp"' EXIT

export GIT_CONFIG_GLOBAL="${test_tmp}/gitconfig"
git config --global init.defaultBranch "${GAUNTLET_TEST_DEFAULT_BRANCH}"

mkdir -p "${test_tmp}/bin"
cat >"${test_tmp}/bin/gh" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$GH_STUB_LOG"
[ "${GH_STUB_RC:-0}" -eq 0 ] || exit "$GH_STUB_RC"
printf '%s\n' "${GH_STUB_RESULT:-true}"
EOF
chmod +x "${test_tmp}/bin/gh"
export PATH="${test_tmp}/bin:${PATH}"
export GH_STUB_LOG="${test_tmp}/gh.log"
export GH_STUB_RESULT=true
export GH_STUB_RC=0

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
    [ "$rc" -eq "$1" ] ||
        fail "expected rc $1, got $rc: stdout='$out' stderr='$err'"
}

assert_reason() {
    [ -n "$err" ] || fail "a refusal must carry a reason on stderr"
}

git_q() {
    git -C "$1" "${@:2}" >/dev/null 2>&1
}

# Fresh bare remote plus a work repository with one commit on main. Both HEADs
# are pinned explicitly so neither inherits the test's main/master setting.
new_fixture() {
    local name=$1 root="${test_tmp}/$1"

    mkdir -p "$root"
    git init --bare -q "${root}/origin.git"
    git -C "${root}/origin.git" symbolic-ref HEAD refs/heads/main
    git init -q "${root}/work"
    git -C "${root}/work" symbolic-ref HEAD refs/heads/main
    git_q "${root}/work" config user.email t@example.invalid
    git_q "${root}/work" config user.name Test
    git_q "${root}/work" config commit.gpgsign false
    printf 'one\n' >"${root}/work/f"
    git_q "${root}/work" add f
    git_q "${root}/work" commit -m one
    git_q "${root}/work" remote add origin "${root}/origin.git"
    printf '%s' "$root"
}

commit_on() {
    local repo=$1 message=$2 content=$3

    printf '%s\n' "$content" >"${repo}/f"
    git_q "$repo" add f
    git_q "$repo" commit -m "$message"
    git -C "$repo" rev-parse HEAD
}

gate_file=
gate_token=
write_gate() {
    local sha=$1 suffix=${2:-$$}

    gate_file="${test_tmp}/gate-${suffix}"
    gate_token="GAUNTLET-GREEN-${sha}-${suffix}"
    printf 'gate output\n%s\n' "$gate_token" >"$gate_file"
}

run_push() {
    local remote=$1 branch=$2 sha=$3 expected=$4 suffix=${5:-$$}

    write_gate "$sha" "$suffix"
    run push --remote "$remote" --branch "$branch" --sha "$sha" \
        --expect "$expected" --gate-file "$gate_file" --gate-token "$gate_token"
}

echo "  -> usage errors are distinct"
run
assert_rc 2
run preflight --remote origin --branch main
assert_rc 2
run push --remote origin --branch main --sha deadbeef
assert_rc 2

echo "  -> preflight reports permission and the expected remote head"
root="$(new_fixture preflight)"
cd "${root}/work"
: >"$GH_STUB_LOG"
run preflight --remote origin --branch main --host github.com --repo owner/repo
assert_rc 0
[ "$out" = absent ] || fail "new remote branch should preflight as absent, got '$out'"
grep -F -- '--hostname github.com repos/owner/repo --jq .permissions.push' "$GH_STUB_LOG" >/dev/null ||
    fail "preflight did not query the requested forge repository"
first="$(git rev-parse HEAD)"
git_q "${root}/work" push origin "${first}:refs/heads/main"
run preflight --remote origin --branch main --host github.com --repo owner/repo
assert_rc 0
[ "$out" = "$first" ] || fail "preflight should print the full remote head"

echo "  -> preflight fails closed on false, malformed, or failed permission reads"
GH_STUB_RESULT=false
run preflight --remote origin --branch main --host github.com --repo owner/repo
assert_rc 3
assert_reason
GH_STUB_RESULT=null
run preflight --remote origin --branch main --host github.com --repo owner/repo
assert_rc 3
GH_STUB_RESULT=true
GH_STUB_RC=7
run preflight --remote origin --branch main --host github.com --repo owner/repo
assert_rc 3
GH_STUB_RC=0

echo "  -> preflight never invokes the repository's pre-push hook"
root="$(new_fixture nohook)"
cd "${root}/work"
mkdir -p "${root}/hooks"
cat >"${root}/hooks/pre-push" <<EOF
#!/bin/sh
: >"${root}/hook-ran"
EOF
chmod +x "${root}/hooks/pre-push"
git config core.hooksPath "${root}/hooks"
run preflight --remote origin --branch main --host github.com --repo owner/repo
assert_rc 0
[ ! -e "${root}/hook-ran" ] || fail "read-only preflight ran pre-push"

echo "  -> a failed or stale marker refuses before any push"
root="$(new_fixture marker)"
cd "${root}/work"
sha="$(git rev-parse HEAD)"
write_gate "$sha" good
printf 'gate output\nGAUNTLET-FAILED\n' >"$gate_file"
run push --remote origin --branch main --sha "$sha" --expect absent \
    --gate-file "$gate_file" --gate-token "$gate_token"
assert_rc 3
assert_reason
[ "$(git -C "${root}/origin.git" show-ref --heads | wc -l)" -eq 0 ] ||
    fail "failed marker must not push"
write_gate "$sha" old
new_token="GAUNTLET-GREEN-${sha}-new"
run push --remote origin --branch main --sha "$sha" --expect absent \
    --gate-file "$gate_file" --gate-token "$new_token"
assert_rc 3

echo "  -> gate tokens must bind this exact full SHA and run"
write_gate "$sha" bound
wrong_token="GAUNTLET-GREEN-0000000000000000000000000000000000000000-bound"
run push --remote origin --branch main --sha "$sha" --expect absent \
    --gate-file "$gate_file" --gate-token "$wrong_token"
assert_rc 3
short="$(git rev-parse --short HEAD)"
short_token="GAUNTLET-GREEN-${short}-short"
printf '%s\n' "$short_token" >"${test_tmp}/short-gate"
run push --remote origin --branch main --sha "$short" --expect absent \
    --gate-file "${test_tmp}/short-gate" --gate-token "$short_token"
assert_rc 3

echo "  -> a gate that dirties the tree or is followed by a new HEAD refuses"
root="$(new_fixture postgate-dirty)"
cd "${root}/work"
sha="$(git rev-parse HEAD)"
write_gate "$sha" dirty
printf 'changed after gate\n' >>f
run push --remote origin --branch main --sha "$sha" --expect absent \
    --gate-file "$gate_file" --gate-token "$gate_token"
assert_rc 3
assert_reason
root="$(new_fixture postgate-head)"
cd "${root}/work"
sha="$(git rev-parse HEAD)"
write_gate "$sha" moved
commit_on "${root}/work" two two >/dev/null
run push --remote origin --branch main --sha "$sha" --expect absent \
    --gate-file "$gate_file" --gate-token "$gate_token"
assert_rc 3

echo "  -> ls-remote failures never become an absent branch"
root="$(new_fixture lsremote-failure)"
cd "${root}/work"
git remote add broken "${test_tmp}/not-a-repository"
sha="$(git rev-parse HEAD)"
run_push broken main "$sha" absent lsremote
assert_rc 3
case "$err" in *ls-remote*) : ;; *) fail "refusal should name ls-remote: $err" ;; esac

echo "  -> first and fast-forward pushes land only the gated SHA"
root="$(new_fixture forward)"
cd "${root}/work"
first="$(git rev-parse HEAD)"
run_push origin main "$first" absent first
assert_rc 0
[ "$(git -C "${root}/origin.git" rev-parse refs/heads/main)" = "$first" ] ||
    fail "first push did not land the gated SHA"
second="$(commit_on "${root}/work" two two)"
run_push origin main "$second" "$first" second
assert_rc 0
[ "$(git -C "${root}/origin.git" rev-parse refs/heads/main)" = "$second" ] ||
    fail "fast-forward push did not land the gated SHA"
run_push origin main "$second" "$second" current
assert_rc 0

echo "  -> a concurrent branch creation or advance is refused"
root="$(new_fixture races)"
cd "${root}/work"
base="$(git rev-parse HEAD)"
mine="$(commit_on "${root}/work" mine mine)"
git_q "${root}/work" push origin "${base}:refs/heads/main"
run_push origin main "$mine" absent creation-race
assert_rc 3
[ "$(git -C "${root}/origin.git" rev-parse refs/heads/main)" = "$base" ] ||
    fail "creation race changed the remote"
git clone -q "${root}/origin.git" "${root}/other"
git_q "${root}/other" config user.email other@example.invalid
git_q "${root}/other" config user.name Other
theirs="$(commit_on "${root}/other" theirs theirs)"
git_q "${root}/other" push origin HEAD:refs/heads/main
run_push origin main "$mine" "$base" advance-race
assert_rc 3
[ "$(git -C "${root}/origin.git" rev-parse refs/heads/main)" = "$theirs" ] ||
    fail "concurrent advance must survive"

echo "  -> a remote moved backward cannot resurrect removed commits"
root="$(new_fixture backward)"
cd "${root}/work"
a="$(git rev-parse HEAD)"
run_push origin main "$a" absent back-a
assert_rc 0
b="$(commit_on "${root}/work" b b)"
run_push origin main "$b" "$a" back-b
assert_rc 0
git_q "${root}/work" push --force origin "${a}:refs/heads/main"
c="$(commit_on "${root}/work" c c)"
run_push origin main "$c" "$b" back-c
assert_rc 3
[ "$(git -C "${root}/origin.git" rev-parse refs/heads/main)" = "$a" ] ||
    fail "backward-moved remote must remain at A"

echo "  -> an explicit refspec defeats wildcard remote push configuration"
root="$(new_fixture wildcard)"
cd "${root}/work"
git config remote.origin.push 'refs/heads/*:refs/heads/*'
git_q "${root}/work" checkout -b unrelated
commit_on "${root}/work" unrelated unrelated >/dev/null
git_q "${root}/work" checkout main
sha="$(git rev-parse HEAD)"
run_push origin main "$sha" absent wildcard
assert_rc 0
if git -C "${root}/origin.git" rev-parse --verify --quiet refs/heads/unrelated >/dev/null; then
    fail "wildcard push configuration leaked an unrelated branch"
fi

echo "  -> transport overrides reach both ls-remote and push"
root="$(new_fixture transport)"
cd "${root}/work"
git remote add transport test://round-remote
rewrite="url.file://${root}/origin.git.insteadOf=test://round-remote"
run preflight --remote transport --branch main --host github.com --repo owner/repo \
    -c credential.helper= -c "$rewrite" -c protocol.file.allow=always
assert_rc 0
[ "$out" = absent ] || fail "transport preflight should see the absent branch"
sha="$(git rev-parse HEAD)"
write_gate "$sha" transport
run push --remote transport --branch main --sha "$sha" --expect absent \
    --gate-file "$gate_file" --gate-token "$gate_token" \
    -c credential.helper= -c "$rewrite" -c protocol.file.allow=always
assert_rc 0
[ "$(git -C "${root}/origin.git" rev-parse refs/heads/main)" = "$sha" ] ||
    fail "transport override did not reach git push"

echo "  -> helper invocation is shell-independent"
if command -v zsh >/dev/null 2>&1; then
    root="$(new_fixture zsh-call)"
    cd "${root}/work"
    sha="$(git rev-parse HEAD)"
    write_gate "$sha" zsh
    set +e
    HELPER="$helper" REMOTE=origin BRANCH=main SHA="$sha" EXPECT=absent \
        GATE_FILE="$gate_file" GATE_TOKEN="$gate_token" \
        zsh -c '"$HELPER" push --remote "$REMOTE" --branch "$BRANCH" --sha "$SHA" --expect "$EXPECT" --gate-file "$GATE_FILE" --gate-token "$GATE_TOKEN"' \
        >/dev/null 2>"${test_tmp}/zsh-stderr"
    zsh_rc=$?
    set -e
    [ "$zsh_rc" -eq 0 ] || fail "zsh invocation failed: $(cat "${test_tmp}/zsh-stderr")"
    [ "$(git -C "${root}/origin.git" rev-parse refs/heads/main)" = "$sha" ] ||
        fail "zsh invocation did not push the gated SHA"
fi

echo "  -> ${GAUNTLET_TEST_DEFAULT_BRANCH} suite passed"
