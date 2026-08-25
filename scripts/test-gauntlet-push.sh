#!/usr/bin/env bash
# Hermetic tests for gauntlet/assets/push-round.sh.
#
# The suite runs twice with opposite init.defaultBranch values. All remotes are
# local bare repositories, and the forge permission query is a PATH stub.

set -euo pipefail

if [ "${GAUNTLET_TEST_CHILD:-}" != 1 ]; then
    for default_branch in main master; do
        echo "==> gauntlet push suite with init.defaultBranch=${default_branch}"
        case "$BASH_VERSION" in
        3.2.*)
            GAUNTLET_TEST_CHILD=1 GAUNTLET_TEST_DEFAULT_BRANCH="$default_branch" \
                GAUNTLET_TEST_FORCE_BASH32=1 /bin/bash "$0"
            ;;
        *) GAUNTLET_TEST_CHILD=1 GAUNTLET_TEST_DEFAULT_BRANCH="$default_branch" "$0" ;;
        esac
    done
    case "$BASH_VERSION" in
    3.2.*) ;;
    *)
        if [ -x /bin/bash ] &&
            /bin/bash -c 'case "$BASH_VERSION" in 3.2.*) exit 0 ;; *) exit 1 ;; esac'; then
            echo "==> gauntlet push suite with macOS Bash 3.2"
            GAUNTLET_TEST_CHILD=1 GAUNTLET_TEST_DEFAULT_BRANCH=main \
                GAUNTLET_TEST_FORCE_BASH32=1 \
                /bin/bash "$0"
        fi
        ;;
    esac
    echo "gauntlet push-round helper: PASS"
    exit 0
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
helper="${repo_root}/ai/skills/universal/gauntlet/assets/push-round.sh"
skill="${repo_root}/ai/skills/universal/gauntlet/SKILL.md"
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
cat >"${test_tmp}/bin/ssh" <<'EOF'
#!/bin/sh
set -eu

remote_command=
for argument do
    remote_command=$argument
done
case "$remote_command" in
"git-upload-pack "*) exec git-upload-pack "$GAUNTLET_TEST_BARE" ;;
"git-receive-pack "*) exec git-receive-pack "$GAUNTLET_TEST_BARE" ;;
*)
    printf 'test ssh: unsupported command: %s\n' "$remote_command" >&2
    exit 1
    ;;
esac
EOF
chmod +x "${test_tmp}/bin/ssh"
export PATH="${test_tmp}/bin:${PATH}"
export GIT_SSH_COMMAND="${test_tmp}/bin/ssh"
export GIT_SSH_VARIANT=ssh
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
    local test_bare=

    test_bare="$(git config --get gauntlet.testBare 2>/dev/null || true)"
    set +e
    if [ "${GAUNTLET_TEST_FORCE_BASH32:-}" = 1 ] && [ "$#" -gt 0 ]; then
        out="$(GAUNTLET_TEST_BARE="$test_bare" /bin/bash "$helper" "$@" 2>"${test_tmp}/stderr")"
    elif [ "${GAUNTLET_TEST_FORCE_BASH32:-}" = 1 ]; then
        out="$(GAUNTLET_TEST_BARE="$test_bare" /bin/bash "$helper" 2>"${test_tmp}/stderr")"
    elif [ "$#" -gt 0 ]; then
        out="$(GAUNTLET_TEST_BARE="$test_bare" "$helper" "$@" 2>"${test_tmp}/stderr")"
    else
        out="$(GAUNTLET_TEST_BARE="$test_bare" "$helper" 2>"${test_tmp}/stderr")"
    fi
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
    git_q "${root}/work" config remote.origin.pushurl ssh://git@github.com/owner/repo.git
    git_q "${root}/work" config gauntlet.testBare "${root}/origin.git"
    git_q "${root}/work" config gauntlet.testRewrite \
        "url.ssh://git@github.com/.insteadOf=git@github.com:"
    printf '%s' "$root"
}

commit_on() {
    local repo=$1 message=$2 content=$3

    printf '%s\n' "$content" >"${repo}/f"
    git_q "$repo" add f
    git_q "$repo" commit -m "$message"
    git -C "$repo" rev-parse HEAD
}

git_push_fixture() {
    local repo=$1
    local test_bare

    shift
    test_bare="$(git -C "$repo" config --get gauntlet.testBare)"
    GAUNTLET_TEST_BARE="$test_bare" git -C "$repo" \
        push "$@" >/dev/null 2>&1
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
    run push --remote "$remote" --branch "$branch" \
        --host github.com --repo owner/repo --sha "$sha" \
        --expect "$expected" --gate-file "$gate_file" --gate-token "$gate_token"
}

echo "  -> usage errors are distinct"
run
assert_rc 2

echo "  -> empty transport overrides stay structurally safe on Bash 3.2"
grep -F -- 'if [ "$git_arg_count" -gt 0 ]; then' "$helper" >/dev/null ||
    fail "git argument expansion must be guarded by the separate count"
[ "$(grep -F -c -- '"${git_args[@]}"' "$helper")" -eq 1 ] ||
    fail "git_args must be expanded only in its non-empty guarded branch"

echo "  -> skill call sites propagate failure and force untracked-file checks"
[ "$(grep -F -c -- '--gate-token "$token" || exit' "$skill")" -eq 2 ] ||
    fail "both documented helper calls must stop on failure"
grep -F -- 'git status --porcelain --untracked-files=all' "$skill" >/dev/null ||
    fail "the entry cleanliness check must force untracked-file reporting"
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
git_push_fixture "${root}/work" origin "${first}:refs/heads/main"
git init --bare -q "${root}/fetch-only.git"
git remote set-url origin "${root}/fetch-only.git"
run preflight --remote origin --branch main --host github.com --repo owner/repo
assert_rc 0
[ "$out" = "$first" ] || fail "preflight should read the push destination, not the fetch URL"

echo "  -> preflight rejects a mismatched or multi-valued push destination"
root="$(new_fixture destinations)"
cd "${root}/work"
git config --unset-all remote.origin.pushurl
git config remote.origin.pushurl https://github.com/owner/other.git
run preflight --remote origin --branch main --host github.com --repo owner/repo
assert_rc 3
assert_reason
git config --add remote.origin.pushurl https://github.com/owner/repo.git
run preflight --remote origin --branch main --host github.com --repo owner/repo
assert_rc 3

echo "  -> preflight fails closed on false, malformed, or failed permission reads"
root="$(new_fixture permissions)"
cd "${root}/work"
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
    --host github.com --repo owner/repo \
    --gate-file "$gate_file" --gate-token "$gate_token"
assert_rc 3
assert_reason
[ "$(git -C "${root}/origin.git" show-ref --heads | wc -l)" -eq 0 ] ||
    fail "failed marker must not push"
write_gate "$sha" old
new_token="GAUNTLET-GREEN-${sha}-new"
run push --remote origin --branch main --sha "$sha" --expect absent \
    --host github.com --repo owner/repo \
    --gate-file "$gate_file" --gate-token "$new_token"
assert_rc 3

echo "  -> gate tokens must bind this exact full SHA and run"
write_gate "$sha" bound
wrong_token="GAUNTLET-GREEN-0000000000000000000000000000000000000000-bound"
run push --remote origin --branch main --sha "$sha" --expect absent \
    --host github.com --repo owner/repo \
    --gate-file "$gate_file" --gate-token "$wrong_token"
assert_rc 3
short="$(git rev-parse --short HEAD)"
short_token="GAUNTLET-GREEN-${short}-short"
printf '%s\n' "$short_token" >"${test_tmp}/short-gate"
run push --remote origin --branch main --sha "$short" --expect absent \
    --host github.com --repo owner/repo \
    --gate-file "${test_tmp}/short-gate" --gate-token "$short_token"
assert_rc 3

echo "  -> a gate that dirties the tree or is followed by a new HEAD refuses"
root="$(new_fixture postgate-dirty)"
cd "${root}/work"
sha="$(git rev-parse HEAD)"
write_gate "$sha" dirty
printf 'changed after gate\n' >>f
run push --remote origin --branch main --sha "$sha" --expect absent \
    --host github.com --repo owner/repo \
    --gate-file "$gate_file" --gate-token "$gate_token"
assert_rc 3
assert_reason
root="$(new_fixture postgate-head)"
cd "${root}/work"
sha="$(git rev-parse HEAD)"
write_gate "$sha" moved
commit_on "${root}/work" two two >/dev/null
run push --remote origin --branch main --sha "$sha" --expect absent \
    --host github.com --repo owner/repo \
    --gate-file "$gate_file" --gate-token "$gate_token"
assert_rc 3

echo "  -> configured status cannot hide untracked gate inputs"
root="$(new_fixture hidden-untracked)"
cd "${root}/work"
sha="$(git rev-parse HEAD)"
write_gate "$sha" hidden-untracked
git config status.showUntrackedFiles no
printf 'gate input\n' >generated.tmp
run push --remote origin --branch main --host github.com --repo owner/repo \
    --sha "$sha" --expect absent --gate-file "$gate_file" --gate-token "$gate_token"
assert_rc 3
assert_reason

echo "  -> a failed post-gate status read is unknown, never clean"
root="$(new_fixture status-failure)"
cd "${root}/work"
sha="$(git rev-parse HEAD)"
write_gate "$sha" status-failure
printf 'broken index\n' >.git/index
run push --remote origin --branch main --host github.com --repo owner/repo \
    --sha "$sha" --expect absent --gate-file "$gate_file" --gate-token "$gate_token"
assert_rc 3
case "$err" in *status*) : ;; *) fail "status failure should be named: $err" ;; esac
[ "$(git -C "${root}/origin.git" show-ref --heads | wc -l)" -eq 0 ] ||
    fail "failed status read must not push"

echo "  -> ls-remote failures never become an absent branch"
root="$(new_fixture lsremote-failure)"
cd "${root}/work"
git remote add broken "${test_tmp}/not-a-repository"
sha="$(git rev-parse HEAD)"
git config remote.broken.pushurl ssh://git@github.com/owner/broken.git
git config gauntlet.testBare "${test_tmp}/not-a-repository"
write_gate "$sha" lsremote
run push --remote broken --branch main --host github.com --repo owner/broken \
    --sha "$sha" --expect absent --gate-file "$gate_file" --gate-token "$gate_token"
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
git_push_fixture "${root}/work" origin "${base}:refs/heads/main"
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
git_push_fixture "${root}/work" --force origin "${a}:refs/heads/main"
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

echo "  -> remote receive-pack overrides are refused before transport"
root="$(new_fixture receivepack)"
cd "${root}/work"
sha="$(git rev-parse HEAD)"
git config remote.origin.receivepack /bin/false
run_push origin main "$sha" absent receivepack
assert_rc 3
assert_reason
case "$err" in *receive-pack*) : ;; *) fail "receive-pack refusal should name the override: $err" ;; esac
[ "$(git -C "${root}/origin.git" show-ref --heads | wc -l)" -eq 0 ] ||
    fail "receive-pack override must be refused before transport"

echo "  -> push.followTags cannot publish an annotated tag"
root="$(new_fixture follow-tags)"
cd "${root}/work"
sha="$(git rev-parse HEAD)"
git tag -a v-round -m round
git config push.followTags true
run_push origin main "$sha" absent follow-tags
assert_rc 0
[ "$(git -C "${root}/origin.git" rev-parse refs/heads/main)" = "$sha" ] ||
    fail "follow-tags fixture did not push the gated branch"
if git -C "${root}/origin.git" rev-parse --verify --quiet refs/tags/v-round >/dev/null; then
    fail "push.followTags leaked an annotated tag"
fi

echo "  -> transport overrides reach both ls-remote and push"
root="$(new_fixture transport)"
cd "${root}/work"
git remote add transport git@github.com:owner/repo.git
rewrite="$(git config --get gauntlet.testRewrite)"
run preflight --remote transport --branch main --host github.com --repo owner/repo \
    -c credential.helper= -c "$rewrite"
assert_rc 0
[ "$out" = absent ] || fail "transport preflight should see the absent branch"
sha="$(git rev-parse HEAD)"
write_gate "$sha" transport
run push --remote transport --branch main --sha "$sha" --expect absent \
    --host github.com --repo owner/repo \
    --gate-file "$gate_file" --gate-token "$gate_token" \
    -c credential.helper= -c "$rewrite"
assert_rc 0
[ "$(git -C "${root}/origin.git" rev-parse refs/heads/main)" = "$sha" ] ||
    fail "transport override did not reach git push"

echo "  -> push-affecting or unrelated -c overrides are refused"
root="$(new_fixture config-allowlist)"
cd "${root}/work"
run preflight --remote origin --branch main --host github.com --repo owner/repo \
    -c url.file:///tmp/elsewhere.pushInsteadOf=https://github.com/owner/repo.git
assert_rc 3
assert_reason
run preflight --remote origin --branch main --host github.com --repo owner/repo \
    -c remote.origin.pushurl=https://github.com/owner/other.git
assert_rc 3

echo "  -> insteadOf destination rewrites are resolved before validation"
root="$(new_fixture rewrite-destination)"
cd "${root}/work"
run preflight --remote origin --branch main --host github.com --repo owner/repo \
    -c url.ssh://git@github.com/owner/other.git.insteadOf=ssh://git@github.com/owner/repo.git
assert_rc 3
assert_reason
case "$err" in *repository*) : ;; *) fail "rewrite refusal should name repository mismatch: $err" ;; esac

echo "  -> helper invocation is shell-independent"
if command -v zsh >/dev/null 2>&1; then
    root="$(new_fixture zsh-call)"
    cd "${root}/work"
    sha="$(git rev-parse HEAD)"
    write_gate "$sha" zsh
    set +e
    rewrite="$(git config --get gauntlet.testRewrite)"
    HELPER="$helper" REMOTE=origin BRANCH=main HOST=github.com REPO=owner/repo \
        SHA="$sha" EXPECT=absent REWRITE="$rewrite" \
        GAUNTLET_TEST_BARE="${root}/origin.git" \
        GATE_FILE="$gate_file" GATE_TOKEN="$gate_token" \
        zsh -c '"$HELPER" push --remote "$REMOTE" --branch "$BRANCH" --host "$HOST" --repo "$REPO" --sha "$SHA" --expect "$EXPECT" --gate-file "$GATE_FILE" --gate-token "$GATE_TOKEN" -c "$REWRITE"' \
        >/dev/null 2>"${test_tmp}/zsh-stderr"
    zsh_rc=$?
    set -e
    [ "$zsh_rc" -eq 0 ] || fail "zsh invocation failed: $(cat "${test_tmp}/zsh-stderr")"
    [ "$(git -C "${root}/origin.git" rev-parse refs/heads/main)" = "$sha" ] ||
        fail "zsh invocation did not push the gated SHA"
fi

echo "  -> ${GAUNTLET_TEST_DEFAULT_BRANCH} suite passed"
