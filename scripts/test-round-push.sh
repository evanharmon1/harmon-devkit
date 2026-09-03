#!/usr/bin/env bash
# Hermetic tests for round-push.sh — the diff-aware, closure-consuming
# successor to gauntlet/assets/push-round.sh (see that script's own test,
# scripts/test-gauntlet-push.sh, which stays green against the untouched
# legacy asset and is not touched by this file).
#
# scripts/devflow-policy.mjs (#636) is not yet on main at the time this test
# was written. Every test that needs it is skipped, with a clear message,
# when the script is absent from the tree — see maybe_skip_no_devflow_policy
# below. Once #636 merges, this suite un-skips on its own; no flag needed.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
helper="${repo_root}/scripts/round-push.sh"
devflow_policy_src="${repo_root}/scripts/devflow-policy.mjs"
toml_lite_src="${repo_root}/scripts/lib/toml-lite.mjs"
gitleaks_scan_src="${repo_root}/scripts/gitleaks-scan.sh"
summarize_gitleaks_src="${repo_root}/scripts/summarize-gitleaks.mjs"
gitleaks_config_src="${repo_root}/.gitleaks.toml"

if [ ! -f "$devflow_policy_src" ]; then
    echo "test-round-push: SKIP — scripts/devflow-policy.mjs is not yet on this branch (#636 not merged); nothing to test yet"
    exit 0
fi

test_tmp="$(mktemp -d -t round-push-test-XXXXXX)"
trap 'rm -rf "$test_tmp"' EXIT

export GIT_CONFIG_GLOBAL="${test_tmp}/gitconfig"
git config --global init.defaultBranch main
git config --global user.email t@example.invalid
git config --global user.name Test
git config --global commit.gpgsign false

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
"git-upload-pack "*) exec git-upload-pack "$ROUND_PUSH_TEST_BARE" ;;
"git-receive-pack "*) exec git-receive-pack "$ROUND_PUSH_TEST_BARE" ;;
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

# ---------------------------------------------------------------------------
# A standalone closure: devflow-policy.mjs + its lib, the gitleaks scanner +
# config + summarizer, a minimal valid v2 fixture policy, and a matching
# minimal fixture registry + task-target list. Every test below points
# round-push.sh at THESE paths explicitly — it never reads a policy,
# registry, or scanner file relative to its own location or cwd.
# ---------------------------------------------------------------------------
closure="${test_tmp}/closure"
mkdir -p "${closure}/scripts/lib"
cp "$devflow_policy_src" "${closure}/scripts/devflow-policy.mjs"
cp "$toml_lite_src" "${closure}/scripts/lib/toml-lite.mjs"
cp "$gitleaks_scan_src" "${closure}/scripts/gitleaks-scan.sh"
chmod +x "${closure}/scripts/gitleaks-scan.sh"
cp "$summarize_gitleaks_src" "${closure}/scripts/summarize-gitleaks.mjs"
cp "$gitleaks_config_src" "${closure}/.gitleaks.toml"

cat >"${closure}/.devflow.toml" <<'EOF'
schema_version = 2
default_rigor = "standard"
rigor_order = ["cursory", "light", "standard", "thorough", "deep", "forensic"]
tier_order = ["local", "economy", "standard", "frontier", "apex"]

[rigor.standard]
rounds = "test"
breadth = "test"

[rounds.test]
challenge = 0
review = 0
integration = 0
remediation = 0
min_rounds = 0
wall_clock_min = 60

[breadth.test]
max_agent_runs = 1
max_parallel_agents = 1

[gates]
round_code = "fixture-verify"
round_docs = "fixture-check"
secret_scan = "fixture-secrets"
pre_pr = "fixture-pre-pr"
docs_only_paths = ["**/*.md", "docs/**"]

[convergence.converged]
all = [{ predicate = "no_gating_findings" }]

[convergence.diverging]
any = [{ predicate = "repeat_after_fix" }]

[role.orchestrator]
tier = "standard"
families = ["claude"]

[role.implementer]
tier = "standard"
families = ["claude"]

[role.challenger]
tier = "standard"
families = ["claude"]

[role.reviewer]
tier = "standard"
families = ["claude"]

[role.integrator]
tier = "standard"
families = ["claude"]
EOF

cat >"${closure}/agent-registry.json" <<'EOF'
{
  "schema_version": 3,
  "families": [
    { "slug": "claude", "display_name": "Claude", "models": [
      { "slug": "sonnet", "display_name": "Sonnet", "tier": "standard" }
    ] }
  ],
  "harnesses": [],
  "finders": []
}
EOF
echo '["fixture-verify","fixture-check","fixture-secrets","fixture-pre-pr"]' \
    >"${closure}/task-targets.json"

policy_args=(
    --policy "${closure}/.devflow.toml"
    --devflow-policy-script "${closure}/scripts/devflow-policy.mjs"
    --registry "${closure}/agent-registry.json"
    --task-targets "${closure}/task-targets.json"
)
scan_args=(
    --gitleaks-script "${closure}/scripts/gitleaks-scan.sh"
    --gitleaks-config "${closure}/.gitleaks.toml"
)

# A fresh bare remote plus a work repository with one commit on main, plus a
# push URL that LOOKS like GitHub SSH but is redirected to the local bare
# repo by the ssh stub above — resolve_push_url's own validation requires a
# github.com host, and the isolated GIT_CONFIG_GLOBAL above keeps the
# devcontainer's real insteadOf rewrites from intercepting it first.

# A GitHub-PAT-shaped fixture value gitleaks' default ruleset reliably
# flags (a well-known example key like AWS's AKIAIOSFODNN7EXAMPLE is
# deliberately allowlisted as documentation and would NOT trigger the
# refusal this suite tests). Built by runtime concatenation, never as one
# contiguous literal: the unsplit string previously landed in this file's
# own committed bytes and gitleaks flagged the SOURCE FILE itself, not
# just the throwaway fixture repos it is written into.
fake_github_token() {
    printf '%s%s' ghp_ wJalrXUtnFEMIK7MDENGbPxRfiCYEXAMPLEKEY
}

new_fixture() {
    local name=$1 root="${test_tmp}/$1"

    mkdir -p "$root"
    git init --bare -q "${root}/origin.git"
    git -C "${root}/origin.git" symbolic-ref HEAD refs/heads/main
    git init -q "${root}/work"
    git -C "${root}/work" symbolic-ref HEAD refs/heads/main
    printf 'one\n' >"${root}/work/f.md"
    git -C "${root}/work" add f.md
    git -C "${root}/work" commit -q -m "chore: base"
    git -C "${root}/work" remote add origin "${root}/origin.git"
    git -C "${root}/work" config remote.origin.pushurl ssh://git@github.com/owner/repo.git
    git -C "${root}/work" config roundpush.testBare "${root}/origin.git"
    printf '%s' "$root"
}

git_q() {
    git -C "$1" "${@:2}" >/dev/null 2>&1
}

commit_on() {
    local repo=$1 message=$2 file=$3 content=$4

    printf '%s\n' "$content" >"${repo}/${file}"
    git_q "$repo" add "$file"
    git_q "$repo" commit -m "$message"
    git -C "$repo" rev-parse HEAD
}

rc=0
out=
err=
run() {
    local test_bare=

    test_bare="$(git config --get roundpush.testBare 2>/dev/null || true)"
    set +e
    out="$(ROUND_PUSH_TEST_BARE="$test_bare" "$helper" "$@" 2>"${test_tmp}/stderr")"
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

write_gate() {
    local sha=$1 target=$2 suffix=$3

    gate_file="${test_tmp}/gate-${suffix}"
    gate_token="ROUND-GREEN-${sha}-${target}-${suffix}"
    printf 'gate output\n%s\n' "$gate_token" >"$gate_file"
}
gate_file=
gate_token=

push_gated() {
    local root=$1 sha=$2 expected=$3 merge_base=$4 target=$5 suffix=$6

    write_gate "$sha" "$target" "$suffix"
    run push --remote origin --branch main --host github.com --repo owner/repo \
        --sha "$sha" --expect "$expected" --gate-file "$gate_file" --gate-token "$gate_token" \
        --merge-base "$merge_base" "${policy_args[@]}" "${scan_args[@]}"
}

echo "  -> usage errors are distinct"
run
assert_rc 2
run plan
assert_rc 2
run push --remote origin --branch main --sha deadbeef
assert_rc 2

echo "  -> empty transport overrides stay structurally safe on Bash 3.2"
grep -F -- 'if [ "$git_arg_count" -gt 0 ]; then' "$helper" >/dev/null ||
    fail "git argument expansion must be guarded by the separate count"
[ "$(grep -F -c -- '"${git_args[@]}"' "$helper")" -eq 1 ] ||
    fail "git_args must be expanded only in its non-empty guarded branch"

echo "  -> preflight still reports permission and the expected remote head"
root="$(new_fixture preflight)"
cd "${root}/work"
: >"$GH_STUB_LOG"
run preflight --remote origin --branch main --host github.com --repo owner/repo
assert_rc 0
[ "$out" = absent ] || fail "new remote branch should preflight as absent, got '$out'"

echo "  -> plan re-derives docs-only from the diff, never from a caller flag"
root="$(new_fixture docs-plan)"
cd "${root}/work"
merge_base="$(git rev-parse HEAD)"
docs_sha="$(commit_on "${root}/work" "test: docs" g.md "docs change")"
run plan --merge-base "$merge_base" --sha "$docs_sha" "${policy_args[@]}" --json
assert_rc 0
printf '%s' "$out" | grep -F '"diff_class": "docs"' >/dev/null ||
    fail "a docs-only diff must classify as docs: $out"
printf '%s' "$out" | grep -F '"required_target": "fixture-check"' >/dev/null ||
    fail "a docs-only diff must require gates.round_docs: $out"

echo "  -> plan re-derives code from a non-docs path, root-level .md included"
root="$(new_fixture code-plan)"
cd "${root}/work"
merge_base="$(git rev-parse HEAD)"
code_sha="$(commit_on "${root}/work" "test: code" code.sh "code change")"
run plan --merge-base "$merge_base" --sha "$code_sha" "${policy_args[@]}" --json
assert_rc 0
printf '%s' "$out" | grep -F '"diff_class": "code"' >/dev/null ||
    fail "a non-docs-path diff must classify as code: $out"
printf '%s' "$out" | grep -F '"required_target": "fixture-verify"' >/dev/null ||
    fail "a code diff must require gates.round_code: $out"
root_md_sha="$(commit_on "${root}/work" "test: root md" README.md "root-level markdown")"
run plan --merge-base "$code_sha" --sha "$root_md_sha" "${policy_args[@]}" --json
assert_rc 0
printf '%s' "$out" | grep -F '"diff_class": "docs"' >/dev/null ||
    fail "a root-level .md file must still match **/*.md: $out"

echo "  -> a docs-class push succeeds against the recomputed docs target"
root="$(new_fixture docs-push)"
cd "${root}/work"
merge_base="$(git rev-parse HEAD)"
docs_sha="$(commit_on "${root}/work" "test: docs" g.md "docs change")"
push_gated "$root" "$docs_sha" absent "$merge_base" fixture-check docs1
assert_rc 0
[ "$(git -C "${root}/origin.git" rev-parse refs/heads/main)" = "$docs_sha" ] ||
    fail "docs-class push did not land the gated commit"

echo "  -> a code-class push succeeds against the recomputed code target"
root="$(new_fixture code-push)"
cd "${root}/work"
merge_base="$(git rev-parse HEAD)"
code_sha="$(commit_on "${root}/work" "test: code" code.sh "code change")"
push_gated "$root" "$code_sha" absent "$merge_base" fixture-verify code1
assert_rc 0
[ "$(git -C "${root}/origin.git" rev-parse refs/heads/main)" = "$code_sha" ] ||
    fail "code-class push did not land the gated commit"

echo "  -> a docs-target marker is refused over a diff that recomputes as mixed/code"
root="$(new_fixture mixed-refusal)"
cd "${root}/work"
merge_base="$(git rev-parse HEAD)"
commit_on "${root}/work" "test: docs" g.md "docs change" >/dev/null
mixed_sha="$(commit_on "${root}/work" "test: code" code.sh "code change")"
push_gated "$root" "$mixed_sha" absent "$merge_base" fixture-check mixed1
assert_rc 3
assert_reason
[ "$(git -C "${root}/origin.git" show-ref --heads | wc -l)" -eq 0 ] ||
    fail "a docs marker over a mixed diff must not push"

echo "  -> a marker naming a target the policy did not list for this diff is refused"
root="$(new_fixture bogus-target)"
cd "${root}/work"
merge_base="$(git rev-parse HEAD)"
code_sha="$(commit_on "${root}/work" "test: code" code.sh "code change")"
push_gated "$root" "$code_sha" absent "$merge_base" not-a-real-target bogus1
assert_rc 3
assert_reason
[ "$(git -C "${root}/origin.git" show-ref --heads | wc -l)" -eq 0 ] ||
    fail "a bogus-target marker must not push"

echo "  -> the round gate marker alone never substitutes for the secret scan"
root="$(new_fixture secret-refusal)"
cd "${root}/work"
merge_base="$(git rev-parse HEAD)"
secret_sha="$(commit_on "${root}/work" "test: secret" leaked.env "$(fake_github_token)")"
push_gated "$root" "$secret_sha" absent "$merge_base" fixture-verify secret1
assert_rc 3
printf '%s' "$err" | grep -Fi "secret scan" >/dev/null ||
    fail "the refusal should name the secret scan: $err"
[ "$(git -C "${root}/origin.git" show-ref --heads | wc -l)" -eq 0 ] ||
    fail "a push with a real secret must not land even with a valid round-gate marker"

echo "  -> the merge-base-materialized execution path is immune to worktree tampering"
root="$(new_fixture materialized)"
cd "${root}/work"
# A separate, throwaway repo stands in for "the repository at the merge
# base": it holds a faithful copy of the broker plus the whole closure at
# their real relative paths, so git show/archive can extract it exactly the
# way a real merge-base extraction would.
mb_repo="${test_tmp}/materialized-mb-repo"
mkdir -p "${mb_repo}/scripts/lib"
git init -q "$mb_repo"
git -C "$mb_repo" symbolic-ref HEAD refs/heads/main
cp "$helper" "${mb_repo}/scripts/round-push.sh"
cp "${closure}/scripts/devflow-policy.mjs" "${mb_repo}/scripts/devflow-policy.mjs"
cp "${closure}/scripts/lib/toml-lite.mjs" "${mb_repo}/scripts/lib/toml-lite.mjs"
cp "${closure}/scripts/gitleaks-scan.sh" "${mb_repo}/scripts/gitleaks-scan.sh"
cp "${closure}/scripts/summarize-gitleaks.mjs" "${mb_repo}/scripts/summarize-gitleaks.mjs"
cp "${closure}/.gitleaks.toml" "${mb_repo}/.gitleaks.toml"
cp "${closure}/.devflow.toml" "${mb_repo}/.devflow.toml"
cp "${closure}/agent-registry.json" "${mb_repo}/agent-registry.json"
cp "${closure}/task-targets.json" "${mb_repo}/task-targets.json"
git_q "$mb_repo" add -A
git_q "$mb_repo" commit -m "chore: merge-base closure snapshot"
mb_commit="$(git -C "$mb_repo" rev-parse HEAD)"

materialized="${test_tmp}/materialized-extracted"
mkdir -p "$materialized"
git -C "$mb_repo" archive "$mb_commit" | tar -x -C "$materialized"
chmod +x "${materialized}/scripts/round-push.sh" "${materialized}/scripts/gitleaks-scan.sh"

# Mutate the WORKTREE's own copies of every closure-resident file to
# something that would behave differently (or simply break) if it were
# read instead of the extracted copy — proving the broker never resolves
# a worktree-resident path (config spec "Gate authority separates policy
# from branch implementation").
mkdir -p "${root}/work/scripts/lib"
printf '#!/usr/bin/env node\nprocess.exit(1)\n' >"${root}/work/scripts/devflow-policy.mjs"
printf '#!/usr/bin/env bash\nexit 1\n' >"${root}/work/scripts/gitleaks-scan.sh"
chmod +x "${root}/work/scripts/gitleaks-scan.sh"
printf 'process.exit(1)\n' >"${root}/work/scripts/summarize-gitleaks.mjs"
cat >"${root}/work/.gitleaks.toml" <<'EOF'
[extend]
useDefault = false
EOF
cat >"${root}/work/.devflow.toml" <<'EOF'
this is not valid toml at all { {{
EOF
git_q "${root}/work" add -A
git_q "${root}/work" commit -m "test: tamper worktree copies of every closure-resident path"

merge_base="$(git rev-parse HEAD)"
docs_sha="$(commit_on "${root}/work" "test: docs" g.md "docs change")"
gate_file="${test_tmp}/mat-gate"
gate_token="ROUND-GREEN-${docs_sha}-fixture-check-mat1"
printf 'gate output\n%s\n' "$gate_token" >"$gate_file"

set +e
ROUND_PUSH_TEST_BARE="$(git config --get roundpush.testBare)" \
    "${materialized}/scripts/round-push.sh" push \
    --remote origin --branch main --host github.com --repo owner/repo \
    --sha "$docs_sha" --expect absent --gate-file "$gate_file" --gate-token "$gate_token" \
    --merge-base "$merge_base" \
    --policy "${materialized}/.devflow.toml" \
    --devflow-policy-script "${materialized}/scripts/devflow-policy.mjs" \
    --gitleaks-script "${materialized}/scripts/gitleaks-scan.sh" \
    --gitleaks-config "${materialized}/.gitleaks.toml" \
    --registry "${materialized}/agent-registry.json" \
    --task-targets "${materialized}/task-targets.json" \
    >"${test_tmp}/mat-stdout" 2>"${test_tmp}/mat-stderr"
rc=$?
set -e
[ "$rc" -eq 0 ] ||
    fail "the extracted broker must succeed using only closure-resident files, got rc=$rc: $(cat "${test_tmp}/mat-stderr")"
[ "$(git -C "${root}/origin.git" rev-parse refs/heads/main)" = "$docs_sha" ] ||
    fail "the materialized execution path did not push the gated commit"

echo "  -> a branch-edited security:secrets Taskfile recipe has no effect on the gate"
root="$(new_fixture taskfile-recipe)"
cd "${root}/work"
cat >"${root}/work/Taskfile.yml" <<'EOF'
version: '3'
tasks:
  security:secrets:
    cmds:
      - echo "tampered recipe would report clean without ever scanning" && exit 0
EOF
git_q "${root}/work" add -A
git_q "${root}/work" commit -m "test: tamper the security:secrets Taskfile recipe"
merge_base="$(git rev-parse HEAD)"
secret_sha="$(commit_on "${root}/work" "test: secret" leaked.env "$(fake_github_token)")"
push_gated "$root" "$secret_sha" absent "$merge_base" fixture-verify recipe1
assert_rc 3
printf '%s' "$err" | grep -Fi "secret scan" >/dev/null ||
    fail "the refusal should still name the secret scan even with a tampered Taskfile recipe: $err"
[ "$(git -C "${root}/origin.git" show-ref --heads | wc -l)" -eq 0 ] ||
    fail "a real secret must not push even when the worktree's own security:secrets recipe would report clean; round-push.sh never invokes task for the scan"

echo "  -> round-push.sh helper invocation is shell-independent"
if command -v zsh >/dev/null 2>&1; then
    root="$(new_fixture zsh-call)"
    cd "${root}/work"
    merge_base="$(git rev-parse HEAD)"
    code_sha="$(commit_on "${root}/work" "test: code" code.sh "code change")"
    write_gate "$code_sha" fixture-verify zsh1
    set +e
    HELPER="$helper" ROUND_PUSH_TEST_BARE="$(git config --get roundpush.testBare)" \
    SHA="$code_sha" MERGE_BASE="$merge_base" GATE_FILE="$gate_file" GATE_TOKEN="$gate_token" \
    POLICY="${closure}/.devflow.toml" DEVFLOW_SCRIPT="${closure}/scripts/devflow-policy.mjs" \
    GITLEAKS_SCRIPT="${closure}/scripts/gitleaks-scan.sh" GITLEAKS_CONFIG="${closure}/.gitleaks.toml" \
    REGISTRY="${closure}/agent-registry.json" TASK_TARGETS="${closure}/task-targets.json" \
        zsh -c '"$HELPER" push --remote origin --branch main --host github.com --repo owner/repo \
            --sha "$SHA" --expect absent --gate-file "$GATE_FILE" --gate-token "$GATE_TOKEN" \
            --merge-base "$MERGE_BASE" --policy "$POLICY" --devflow-policy-script "$DEVFLOW_SCRIPT" \
            --gitleaks-script "$GITLEAKS_SCRIPT" --gitleaks-config "$GITLEAKS_CONFIG" \
            --registry "$REGISTRY" --task-targets "$TASK_TARGETS"' \
        >/dev/null 2>"${test_tmp}/zsh-stderr"
    zsh_rc=$?
    set -e
    [ "$zsh_rc" -eq 0 ] || fail "zsh invocation failed: $(cat "${test_tmp}/zsh-stderr")"
    [ "$(git -C "${root}/origin.git" rev-parse refs/heads/main)" = "$code_sha" ] ||
        fail "zsh invocation did not push the gated SHA"
fi

echo "round-push helper: PASS"
