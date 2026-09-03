#!/usr/bin/env bash
# Hermetic tests for round-push.sh — the diff-aware, closure-consuming
# successor to gauntlet/assets/push-round.sh (see that script's own test,
# scripts/test-gauntlet-push.sh, which stays green against the untouched
# legacy asset and is not touched by this file).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
helper="${repo_root}/scripts/round-push.sh"
devflow_policy_src="${repo_root}/scripts/devflow-policy.mjs"
toml_lite_src="${repo_root}/scripts/lib/toml-lite.mjs"
gitleaks_scan_src="${repo_root}/scripts/gitleaks-scan.sh"
summarize_gitleaks_src="${repo_root}/scripts/summarize-gitleaks.mjs"
gitleaks_config_src="${repo_root}/.gitleaks.toml"

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
# Closure template: devflow-policy.mjs + its lib, the gitleaks scanner +
# config + summarizer, a minimal valid v2 fixture policy, and a matching
# minimal fixture registry. Every fixture repo commits a COPY of these into
# its own history (see new_fixture below) rather than pointing round-push.sh
# at a standalone directory: round-push.sh now verifies every closure input
# against `git show <closure-base>:<canonical-path>`, so --closure-base must
# name a real commit that actually contains them (Codex review, confirmed —
# see round-push.sh's verify_closure_member). --task-targets is the one
# exception: it is never one of the verified inputs (devflow-policy.mjs's
# own --task-targets is a local aid, not a closure member), so it stays a
# single shared, untracked file.
# ---------------------------------------------------------------------------
closure_template="${test_tmp}/closure-template"
mkdir -p "${closure_template}/scripts/lib"
cp "$devflow_policy_src" "${closure_template}/scripts/devflow-policy.mjs"
cp "$toml_lite_src" "${closure_template}/scripts/lib/toml-lite.mjs"
cp "$gitleaks_scan_src" "${closure_template}/scripts/gitleaks-scan.sh"
chmod +x "${closure_template}/scripts/gitleaks-scan.sh"
cp "$summarize_gitleaks_src" "${closure_template}/scripts/summarize-gitleaks.mjs"
cp "$gitleaks_config_src" "${closure_template}/.gitleaks.toml"

cat >"${closure_template}/.devflow.toml" <<'EOF'
schema_version = 2
default_rigor = "standard"
default_strategy = "solo"
rigor_order = ["cursory", "light", "standard", "thorough", "deep", "forensic"]
tier_order = ["local", "economy", "standard", "frontier", "apex"]

[strategy.solo]
topology = "single-agent"
planning = "inline"
delegation = "none"

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

cat >"${closure_template}/agent-registry.json" <<'EOF'
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

task_targets_file="${test_tmp}/task-targets.json"
echo '["fixture-verify","fixture-check","fixture-secrets","fixture-pre-pr"]' \
    >"$task_targets_file"

CLOSURE_FILES=(.devflow.toml agent-registry.json scripts/devflow-policy.mjs
    scripts/lib/toml-lite.mjs scripts/gitleaks-scan.sh
    scripts/summarize-gitleaks.mjs .gitleaks.toml)

# A fresh bare remote plus a work repository with one commit on main (the
# closure template plus a Taskfile.yml whose fixture-verify/fixture-check
# targets both succeed by default — individual tests override one or the
# other to prove the broker actually runs whichever it selects), plus a
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

git_q() {
    git -C "$1" "${@:2}" >/dev/null 2>&1
}

new_fixture() {
    local name=$1 root="${test_tmp}/$1"

    mkdir -p "$root"
    git init --bare -q "${root}/origin.git"
    git -C "${root}/origin.git" symbolic-ref HEAD refs/heads/main
    git init -q "${root}/work"
    git -C "${root}/work" symbolic-ref HEAD refs/heads/main
    cp -R "${closure_template}/." "${root}/work/"
    printf 'one\n' >"${root}/work/f.md"
    cat >"${root}/work/Taskfile.yml" <<'EOF'
version: '3'
tasks:
  fixture-verify:
    cmds:
      - echo fixture-verify ok
  fixture-check:
    cmds:
      - echo fixture-check ok
EOF
    git -C "${root}/work" add -A
    git -C "${root}/work" commit -q -m "chore: base"
    git -C "${root}/work" remote add origin "${root}/origin.git"
    git -C "${root}/work" config remote.origin.pushurl ssh://git@github.com/owner/repo.git
    git -C "${root}/work" config roundpush.testBare "${root}/origin.git"
    printf '%s' "$root"
}

commit_on() {
    local repo=$1 message=$2 file=$3 content=$4

    printf '%s\n' "$content" >"${repo}/${file}"
    git_q "$repo" add "$file"
    git_q "$repo" commit -m "$message"
    git -C "$repo" rev-parse HEAD
}

# Extracts the closure files from REPO at SHA into a fresh directory via
# `git archive`, mirroring a real merge-base extraction, and returns the
# directory's path. .gitleaksignore is optional per the closure's own
# declared shape (round-push.sh's verify_closure_gitleaksignore treats "the
# merge base has none" as a valid state, not a missing-file error) — `git
# archive` hard-errors on ANY explicit pathspec absent from the tree, so
# unlike every other entry in CLOSURE_FILES this one is only added when it
# actually exists at SHA, checked first via `cat-file -e`.
extract_closure() {
    local repo=$1 sha=$2 dest paths=("${CLOSURE_FILES[@]}")
    dest="$(mktemp -d)"
    if git -C "$repo" cat-file -e "${sha}:.gitleaksignore" 2>/dev/null; then
        paths+=(.gitleaksignore)
    fi
    git -C "$repo" archive "$sha" -- "${paths[@]}" | tar -x -C "$dest"
    chmod +x "${dest}/scripts/gitleaks-scan.sh"
    printf '%s' "$dest"
}

policy_args=()
scan_args=()
closure_args_from() {
    local dir=$1
    policy_args=(
        --policy "${dir}/.devflow.toml"
        --devflow-policy-script "${dir}/scripts/devflow-policy.mjs"
        --registry "${dir}/agent-registry.json"
        --task-targets "$task_targets_file"
    )
    scan_args=(
        --gitleaks-script "${dir}/scripts/gitleaks-scan.sh"
        --gitleaks-config "${dir}/.gitleaks.toml"
    )
}

# round-push.sh's --against refuses a bare commit ID or a revision
# expression (Codex challenge round 2 / review round 1, confirmed: either
# is equally capable of asserting an arbitrary, deliberately-too-close
# ancestor with no binding to any actual branch). Every fixture below
# therefore marks its intended base with a frozen tag — never the live
# "main" branch name, which keeps moving as later commits land on it in
# these single-branch fixtures — and passes the TAG NAME to --against.
#
# round-push.sh also requires --closure-base, the exact SHA --against must
# resolve to, and now verifies every closure-resident input against that
# commit's own git objects (Codex review rounds 2 and current-head cloud
# review, confirmed). mark_base tags AT (default HEAD, so an earlier commit
# can be named for tests that need one) with `tag -f`, so calling it twice
# with the same LABEL just moves the tag rather than failing outright,
# extracts the closure from that same commit, and sets policy_args/
# scan_args as a side effect, plus the
# tag name and sha in mark_base_tag/mark_base_sha — MUST be called directly
# (never as `x="$(mark_base ...)"`), because bash always forks a subshell
# for command substitution, which would silently discard every one of
# those global-variable side effects the instant the subshell exits,
# leaving policy_args/scan_args/mark_base_tag/mark_base_sha stuck at
# whichever earlier fixture's mark_base call last set them directly (a
# latent bug in this suite itself, not in round-push.sh: caught only
# because two fixtures happen to give DIFFERENT, mutually exclusive
# docs_only_paths results, so a stale policy from an unrelated earlier
# fixture would misclassify rather than coincidentally agree — every
# fixture before that shared byte-identical closure content, so a stale
# policy_args was undetectably wrong).
mark_base() {
    local repo=$1 label=${2:-base} at=${3:-HEAD} dir

    mark_base_sha="$(git -C "$repo" rev-parse "$at")"
    mark_base_tag="round-push-test-${label}"
    git_q "$repo" tag -f "$mark_base_tag" "$mark_base_sha"
    dir="$(extract_closure "$repo" "$mark_base_sha")"
    closure_args_from "$dir"
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

push_gated() {
    local root=$1 sha=$2 expected=$3 merge_base=$4 merge_base_sha=$5

    run push --remote origin --branch main --host github.com --repo owner/repo \
        --sha "$sha" --expect "$expected" \
        --against "$merge_base" --closure-base "$merge_base_sha" "${policy_args[@]}" "${scan_args[@]}"
}

echo "  -> usage errors are distinct"
run
assert_rc 2
run plan
assert_rc 2
run push --remote origin --branch main --sha deadbeef
assert_rc 2

echo "  -> each mode refuses another mode's options"
root="$(new_fixture mode-options)"
cd "${root}/work"
mark_base "${root}/work"
merge_base=$mark_base_tag
merge_base_sha=$mark_base_sha
run preflight --remote origin --branch main --host github.com --repo owner/repo --policy "${policy_args[1]}"
assert_rc 2
printf '%s' "$err" | grep -Fi "not valid in preflight mode" >/dev/null ||
    fail "preflight must refuse a plan/push-only option like --policy (Codex cloud review, confirmed a misplaced option looked validated while silently never used): $err"
run plan --against "$merge_base" --closure-base "$merge_base_sha" "${policy_args[@]}" --host github.com --json
assert_rc 2
printf '%s' "$err" | grep -Fi "not valid in plan mode" >/dev/null ||
    fail "plan must refuse a preflight/push-only option like --host: $err"
run push --remote origin --branch main --host github.com --repo owner/repo \
    --sha "$(git rev-parse HEAD)" --expect absent \
    --against "$merge_base" --closure-base "$merge_base_sha" "${policy_args[@]}" "${scan_args[@]}" --json
assert_rc 2
printf '%s' "$err" | grep -Fi "not valid in push mode" >/dev/null ||
    fail "push must refuse --json, a plan-only option: $err"

echo "  -> --branch must match the checked-out branch, not merely be syntactically valid"
root="$(new_fixture branch-binding)"
cd "${root}/work"
mark_base "${root}/work"
merge_base=$mark_base_tag
merge_base_sha=$mark_base_sha
code_sha="$(commit_on "${root}/work" "test: code" code.sh "code change")"
run push --remote origin --branch some-other-branch --host github.com --repo owner/repo \
    --sha "$code_sha" --expect absent \
    --against "$merge_base" --closure-base "$merge_base_sha" "${policy_args[@]}" "${scan_args[@]}"
assert_rc 3
printf '%s' "$err" | grep -Fi "does not match the checked-out branch" >/dev/null ||
    fail "a --branch naming something other than the checked-out branch should be refused by name (Codex cloud review, confirmed a stale or mistyped --branch main in a topic worktree could otherwise push the topic SHA straight to refs/heads/main): $err"
[ "$(git -C "${root}/origin.git" show-ref --heads | wc -l)" -eq 0 ] ||
    fail "a --branch not matching the checked-out branch must not push"

echo "  -> empty transport overrides stay structurally safe on Bash 3.2"
grep -F -- 'if [ "$git_arg_count" -gt 0 ]; then' "$helper" >/dev/null ||
    fail "git argument expansion must be guarded by the separate count"
[ "$(grep -F -c -- '"${git_args[@]}"' "$helper")" -eq 1 ] ||
    fail "git_args must be expanded only in its non-empty guarded branch"

echo "  -> the gate's own output is never captured to a file that could leak or leave a stray temp file"
grep -F -- 'gate_log' "$helper" >/dev/null &&
    fail "a captured gate log is exactly what let a failing gate's output — which can legitimately contain credentials — get replayed into a refusal message, and it was never registered for cleanup either (Codex cloud review, confirmed both); the gate must inherit this script's own stdout/stderr instead"
grep -F -- 'if ! task "$required_target"; then' "$helper" >/dev/null ||
    fail "the required target must run with its output inherited, not redirected to a capture file"

echo "  -> the write is bound to the validated push URL, not a fresh remote-name resolution"
grep -F -- 'git_with_args push --no-follow-tags \' "$helper" >/dev/null &&
    grep -F -- '"$push_url" "${resolved}:refs/heads/${branch}" "$lease"' "$helper" >/dev/null ||
    fail "the push write must use \$push_url, not \$remote, or a TOCTOU on the named remote's config reopens (Codex cloud review, confirmed)"
grep -F -- 'git update-ref "refs/remotes/${remote}/${branch}"' "$helper" >/dev/null ||
    fail "a raw-URL push must update the remote-tracking ref by hand (AGENTS.md's own stale-tracking-ref concern)"

# Structural, not behavioral, for the same reason as the two checks above:
# driving this race hermetically would need a config mutation landing in
# the exact window between the two resolve_push_url calls INSIDE one
# single-process run of round-push.sh, which this test harness has no way
# to inject without instrumenting the script under test.
echo "  -> the push destination is re-validated immediately before the write, not only once"
grep -F -- 'gated_push_url="$push_url"' "$helper" >/dev/null ||
    fail "the first resolve_push_url must save its result for a later comparison"
[ "$(grep -F -c -- 'resolve_push_url' "$helper")" -ge 2 ] ||
    fail "resolve_push_url must run a second time before the write"
grep -F -- '[ "$push_url" = "$gated_push_url" ]' "$helper" >/dev/null ||
    fail "a destination that changed since first validated must be refused — git re-applies url.*.insteadOf/pushInsteadOf to a literal URL argument at push time just as it would a named remote (Codex cloud review, confirmed empirically), so passing \$push_url alone does not close this"

echo "  -> a core.sshCommand configured before the gate runs, and left unchanged, does not spuriously refuse"
root="$(new_fixture sshcommand-stable)"
cd "${root}/work"
git config core.sshCommand "${test_tmp}/bin/ssh"
mark_base "${root}/work"
merge_base=$mark_base_tag
merge_base_sha=$mark_base_sha
code_sha="$(commit_on "${root}/work" "test: code" code.sh "code change")"
push_gated "$root" "$code_sha" absent "$merge_base" "$merge_base_sha"
assert_rc 0
[ "$(git -C "${root}/origin.git" rev-parse refs/heads/main)" = "$code_sha" ] ||
    fail "a stable, unchanged core.sshCommand present before the gate must not block an otherwise-valid push"

echo "  -> a gate that installs a core.sshCommand override during its own execution is refused"
root="$(new_fixture sshcommand-tamper)"
cd "${root}/work"
mark_base "${root}/work"
merge_base=$mark_base_tag
merge_base_sha=$mark_base_sha
cat >"${root}/work/Taskfile.yml" <<'EOF'
version: '3'
tasks:
  fixture-verify:
    cmds:
      - git config core.sshCommand /bin/a-malicious-ssh-override
  fixture-check:
    cmds:
      - echo fixture-check ok
EOF
git_q "${root}/work" add -A
git_q "${root}/work" commit -m "test: fixture-verify installs a core.sshCommand override"
code_sha="$(git -C "${root}/work" rev-parse HEAD)"
push_gated "$root" "$code_sha" absent "$merge_base" "$merge_base_sha"
assert_rc 3
printf '%s' "$err" | grep -Fi "SSH transport override changed" >/dev/null ||
    fail "a gate that installs core.sshCommand during its own execution must be refused before the push — git would use that override, ignoring the validated hostname entirely, regardless of \$push_url (Codex cloud review, confirmed: core.sshCommand is a repository-local config value, not a tracked file, so the worktree-cleanliness check never sees it): $err"
[ "$(git -C "${root}/origin.git" show-ref --heads | wc -l)" -eq 0 ] ||
    fail "a push whose gate installed an SSH transport override must not land"

# Structural, not behavioral, for the same reason the push-URL-binding check
# just above is structural: exercising resolve_push_url's HTTPS branch to a
# real host needs an actual reachable server (unlike the SSH branch, there is
# no local stub transport to redirect https:// traffic to the test's bare
# repo), so the same style precedent applies here.
echo "  -> an explicit default HTTPS port is normalized before the host comparison"
grep -F -- 'authority=${authority%:443}' "$helper" >/dev/null ||
    fail "the HTTPS branch of resolve_push_url must strip a trailing :443 from authority before assigning destination_host, or an explicit-default-port URL (https://github.com:443/owner/repo.git) is refused despite naming the same destination (Codex cloud review, confirmed)"

echo "  -> preflight still reports permission and the expected remote head"
root="$(new_fixture preflight)"
cd "${root}/work"
: >"$GH_STUB_LOG"
run preflight --remote origin --branch main --host github.com --repo owner/repo
assert_rc 0
[ "$out" = absent ] || fail "new remote branch should preflight as absent, got '$out'"

echo "  -> --against refuses anything that is not an actual resolvable ref"
root="$(new_fixture against-shape)"
cd "${root}/work"
bare_sha="$(git rev-parse HEAD)"
mark_base "${root}/work"
run plan --against "$bare_sha" "${policy_args[@]}" --json
assert_rc 2
printf '%s' "$err" | grep -Fi "must resolve to an actual ref" >/dev/null ||
    fail "the usage error should name the actual-ref requirement: $err"
run plan --against nonexistent-ref-xyz "${policy_args[@]}" --json
assert_rc 2
printf '%s' "$err" | grep -Fi "must resolve to an actual ref" >/dev/null ||
    fail "a nonexistent ref name should be refused at the same check, not later at merge-base computation: $err"
commit_on "${root}/work" "test: second commit" second.md "second" >/dev/null
run plan --against 'HEAD~1' "${policy_args[@]}" --json
assert_rc 2
printf '%s' "$err" | grep -Fi "revision expression" >/dev/null ||
    fail "a revision expression like HEAD~1 names no ref of its own and must be refused like a bare commit ID: $err"
mark_base "${root}/work" base 'HEAD~1'
base_ref=$mark_base_tag
base_sha=$mark_base_sha
run plan --against "$base_ref" --closure-base "$base_sha" "${policy_args[@]}" --json
assert_rc 0

echo "  -> plan re-derives docs-only from the diff, never from a caller flag"
root="$(new_fixture docs-plan)"
cd "${root}/work"
mark_base "${root}/work"
merge_base=$mark_base_tag
merge_base_sha=$mark_base_sha
docs_sha="$(commit_on "${root}/work" "test: docs" g.md "docs change")"
run plan --against "$merge_base" --closure-base "$merge_base_sha" --sha "$docs_sha" "${policy_args[@]}" --json
assert_rc 0
printf '%s' "$out" | grep -F '"diff_class": "docs"' >/dev/null ||
    fail "a docs-only diff must classify as docs: $out"
printf '%s' "$out" | grep -F '"required_target": "fixture-check"' >/dev/null ||
    fail "a docs-only diff must require gates.round_docs: $out"

echo "  -> plan re-derives code from a non-docs path, root-level .md included"
root="$(new_fixture code-plan)"
cd "${root}/work"
mark_base "${root}/work"
merge_base=$mark_base_tag
merge_base_sha=$mark_base_sha
code_sha="$(commit_on "${root}/work" "test: code" code.sh "code change")"
run plan --against "$merge_base" --closure-base "$merge_base_sha" --sha "$code_sha" "${policy_args[@]}" --json
assert_rc 0
printf '%s' "$out" | grep -F '"diff_class": "code"' >/dev/null ||
    fail "a non-docs-path diff must classify as code: $out"
printf '%s' "$out" | grep -F '"required_target": "fixture-verify"' >/dev/null ||
    fail "a code diff must require gates.round_code: $out"
mark_base "${root}/work" second
code_sha_base=$mark_base_tag
code_sha_base_sha=$mark_base_sha
root_md_sha="$(commit_on "${root}/work" "test: root md" README.md "root-level markdown")"
run plan --against "$code_sha_base" --closure-base "$code_sha_base_sha" --sha "$root_md_sha" "${policy_args[@]}" --json
assert_rc 0
printf '%s' "$out" | grep -F '"diff_class": "docs"' >/dev/null ||
    fail "a root-level .md file must still match **/*.md: $out"

echo "  -> an embedded globstar in docs_only_paths matches a zero-directory direct child"
root="$(new_fixture embedded-globstar)"
cd "${root}/work"
awk '{gsub(/docs_only_paths = .*/, "docs_only_paths = [\"docs/**/*.md\"]"); print}' \
    "${root}/work/.devflow.toml" >"${test_tmp}/embedded-globstar-devflow.toml"
mv "${test_tmp}/embedded-globstar-devflow.toml" "${root}/work/.devflow.toml"
git_q "${root}/work" add -A
git_q "${root}/work" commit -m "test: docs_only_paths uses only an embedded globstar pattern"
mark_base "${root}/work"
merge_base=$mark_base_tag
merge_base_sha=$mark_base_sha
mkdir -p "${root}/work/docs"
direct_child_sha="$(commit_on "${root}/work" "test: direct docs child" docs/readme.md "docs content")"
run plan --against "$merge_base" --closure-base "$merge_base_sha" --sha "$direct_child_sha" "${policy_args[@]}" --json
assert_rc 0
printf '%s' "$out" | grep -F '"diff_class": "docs"' >/dev/null ||
    fail "docs/**/*.md must match a direct child docs/readme.md with zero intervening directories, not only a deeper docs/sub/readme.md (Codex cloud review, confirmed): $out"

echo "  -> a pattern with two globstars matches when only ONE of them collapses to zero"
root="$(new_fixture multi-globstar)"
cd "${root}/work"
awk '{gsub(/docs_only_paths = .*/, "docs_only_paths = [\"docs/**/api/**/*.md\"]"); print}' \
    "${root}/work/.devflow.toml" >"${test_tmp}/multi-globstar-devflow.toml"
mv "${test_tmp}/multi-globstar-devflow.toml" "${root}/work/.devflow.toml"
git_q "${root}/work" add -A
git_q "${root}/work" commit -m "test: docs_only_paths uses two globstars"
mark_base "${root}/work"
merge_base=$mark_base_tag
merge_base_sha=$mark_base_sha
mkdir -p "${root}/work/docs/v1/api"
two_star_sha="$(commit_on "${root}/work" "test: nested docs child" docs/v1/api/readme.md "docs content")"
run plan --against "$merge_base" --closure-base "$merge_base_sha" --sha "$two_star_sha" "${policy_args[@]}" --json
assert_rc 0
printf '%s' "$out" | grep -F '"diff_class": "docs"' >/dev/null ||
    fail "docs/**/api/**/*.md must match docs/v1/api/readme.md — the FIRST ** consuming a real directory (v1/) while the SECOND collapses to zero, a combination a single leftmost-collapse pass never tries (Codex cloud review, confirmed): $out"

echo "  -> a code-to-docs rename classifies as code, not docs (rename detection defeated)"
root="$(new_fixture rename-plan)"
cd "${root}/work"
mkdir -p src
printf 'one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\n' >src/run.sh
git_q "${root}/work" add src/run.sh
git_q "${root}/work" commit -m "test: add code file"
mark_base "${root}/work"
premv_base=$mark_base_tag
premv_base_sha=$mark_base_sha
mkdir -p "${root}/work/docs"
git_q "${root}/work" mv src/run.sh docs/run.md
git_q "${root}/work" commit -m "test: rename code file into docs/"
rename_sha="$(git rev-parse HEAD)"
git -C "${root}/work" diff --name-status "${premv_base}..${rename_sha}" | grep -q '^R100' ||
    fail "fixture setup did not produce a 100%-similarity rename to test against"
run plan --against "$premv_base" --closure-base "$premv_base_sha" --sha "$rename_sha" "${policy_args[@]}" --json
assert_rc 0
printf '%s' "$out" | grep -F '"diff_class": "code"' >/dev/null ||
    fail "a rename from a non-docs path into a docs-shaped path must still classify as code, not docs (source path must not be invisible to the classifier): $out"

echo "  -> a --closure-base that no longer matches the recomputed merge base is refused"
root="$(new_fixture closure-base-drift)"
cd "${root}/work"
mark_base "${root}/work"
merge_base=$mark_base_tag
merge_base_sha=$mark_base_sha
code_sha="$(commit_on "${root}/work" "test: code" code.sh "code change")"
run plan --against "$merge_base" --closure-base 0000000000000000000000000000000000000000 --sha "$code_sha" "${policy_args[@]}" --json
assert_rc 3
printf '%s' "$err" | grep -Fi "does not match --closure-base" >/dev/null ||
    fail "a mismatched --closure-base should be refused by name: $err"
run plan --against "$merge_base" --closure-base "$merge_base_sha" --sha "$code_sha" "${policy_args[@]}" --json
assert_rc 0

echo "  -> a closure file that does not match --closure-base's own git object is refused"
root="$(new_fixture closure-content-mismatch)"
cd "${root}/work"
mark_base "${root}/work"
merge_base=$mark_base_tag
merge_base_sha=$mark_base_sha
code_sha="$(commit_on "${root}/work" "test: code" code.sh "code change")"
# A structurally valid but BYTE-DIFFERENT policy file — otherwise it would
# resolve cleanly, which is exactly why a shape check alone cannot catch
# this; only comparing against the closure-base's own object can.
cp "${policy_args[1]}" "${test_tmp}/tampered-policy.toml"
printf '\n# an extra comment no verifier of shape alone would notice\n' >>"${test_tmp}/tampered-policy.toml"
tampered_policy_args=("${policy_args[@]}")
tampered_policy_args[1]="${test_tmp}/tampered-policy.toml"
run push --remote origin --branch main --host github.com --repo owner/repo \
    --sha "$code_sha" --expect absent \
    --against "$merge_base" --closure-base "$merge_base_sha" \
    "${tampered_policy_args[@]}" "${scan_args[@]}"
assert_rc 3
printf '%s' "$err" | grep -Fi "does not match .devflow.toml" >/dev/null ||
    fail "a closure file whose bytes differ from --closure-base's own object should be refused by name: $err"
[ "$(git -C "${root}/origin.git" show-ref --heads | wc -l)" -eq 0 ] ||
    fail "a content-mismatched closure file must not push"

echo "  -> a tampered scripts/lib/toml-lite.mjs is refused even when devflow-policy.mjs itself verifies clean"
root="$(new_fixture toml-lite-mismatch)"
cd "${root}/work"
mark_base "${root}/work"
merge_base=$mark_base_tag
merge_base_sha=$mark_base_sha
code_sha="$(commit_on "${root}/work" "test: code" code.sh "code change")"
tampered_dir="${test_tmp}/tampered-toml-lite"
mkdir -p "${tampered_dir}/lib"
cp "${policy_args[3]}" "${tampered_dir}/devflow-policy.mjs"
printf 'export function parseToml(){ return {}; } export class TomlError extends Error {}\n' \
    >"${tampered_dir}/lib/toml-lite.mjs"
tampered_policy_args=("${policy_args[@]}")
tampered_policy_args[3]="${tampered_dir}/devflow-policy.mjs"
run push --remote origin --branch main --host github.com --repo owner/repo \
    --sha "$code_sha" --expect absent \
    --against "$merge_base" --closure-base "$merge_base_sha" \
    "${tampered_policy_args[@]}" "${scan_args[@]}"
assert_rc 3
printf '%s' "$err" | grep -Fi "does not match scripts/lib/toml-lite.mjs" >/dev/null ||
    fail "devflow-policy.mjs's own transitive dependency toml-lite.mjs must be verified even when devflow-policy.mjs itself is byte-identical to the genuine closure member (Codex cloud review, confirmed: disclosing it as unverified was not the same as closing it): $err"
[ "$(git -C "${root}/origin.git" show-ref --heads | wc -l)" -eq 0 ] ||
    fail "a tampered toml-lite.mjs must not push"

echo "  -> a gate that tampers the scanner closure during its own execution is caught before the scan"
root="$(new_fixture scanner-closure-tamper)"
cd "${root}/work"
mark_base "${root}/work"
merge_base=$mark_base_tag
merge_base_sha=$mark_base_sha
tamper_target="${scan_args[3]}"
cat >"${root}/work/Taskfile.yml" <<EOF
version: '3'
tasks:
  fixture-verify:
    cmds:
      - printf '[extend]\nuseDefault = false\n' > "${tamper_target}"
  fixture-check:
    cmds:
      - echo fixture-check ok
EOF
git_q "${root}/work" add -A
git_q "${root}/work" commit -m "test: fixture-verify tampers the extracted .gitleaks.toml"
code_sha="$(git -C "${root}/work" rev-parse HEAD)"
push_gated "$root" "$code_sha" absent "$merge_base" "$merge_base_sha"
assert_rc 3
printf '%s' "$err" | grep -Fi "does not match .gitleaks.toml" >/dev/null ||
    fail "a gate that overwrites the extracted .gitleaks.toml during its own execution must be caught by the post-gate re-verification, not silently used by the scan afterward (Codex cloud review, confirmed: verifying the scanner closure only once, before the gate, cannot detect the gate's own tampering): $err"
[ "$(git -C "${root}/origin.git" show-ref --heads | wc -l)" -eq 0 ] ||
    fail "a push whose gate tampered the scanner closure must not land"

echo "  -> a closure .gitleaksignore matching the worktree's, but not --closure-base's, is still refused"
root="$(new_fixture closure-gitleaksignore-mismatch)"
cd "${root}/work"
printf 'true-merge-base-fingerprint\n' >"${root}/work/.gitleaksignore"
git_q "${root}/work" add .gitleaksignore
git_q "${root}/work" commit -m "test: the merge base's real .gitleaksignore"
mark_base "${root}/work"
merge_base=$mark_base_tag
merge_base_sha=$mark_base_sha
# The branch changes its OWN .gitleaksignore after the merge base — proving
# gitleaks-scan.sh's own worktree-vs-closure comparison alone cannot catch a
# "closure" whose .gitleaksignore happens to match THIS (wrong) content too.
printf 'branch-forged-fingerprint\n' >"${root}/work/.gitleaksignore"
git_q "${root}/work" add .gitleaksignore
code_sha="$(commit_on "${root}/work" "test: code" code.sh "code change")"
tampered_dir="${test_tmp}/tampered-gitleaksignore"
mkdir -p "$tampered_dir"
cp "${scan_args[3]}" "${tampered_dir}/.gitleaks.toml"
cp "${root}/work/.gitleaksignore" "${tampered_dir}/.gitleaksignore"
tampered_scan_args=("${scan_args[@]}")
tampered_scan_args[3]="${tampered_dir}/.gitleaks.toml"
run push --remote origin --branch main --host github.com --repo owner/repo \
    --sha "$code_sha" --expect absent \
    --against "$merge_base" --closure-base "$merge_base_sha" \
    "${policy_args[@]}" "${tampered_scan_args[@]}"
assert_rc 3
printf '%s' "$err" | grep -Fi "closure's .gitleaksignore does not match" >/dev/null ||
    fail "a closure .gitleaksignore matching the worktree's (but not --closure-base's real object) should still be refused by round-push.sh's own check rather than relying on gitleaks-scan.sh's worktree-vs-closure comparison alone (Codex cloud review, confirmed the earlier closure-verification list omitted .gitleaksignore even after it became a declared closure member): $err"
[ "$(git -C "${root}/origin.git" show-ref --heads | wc -l)" -eq 0 ] ||
    fail "a closure with a mismatched .gitleaksignore must not push"

echo "  -> the broker executes the required target itself; a failing gate refuses the push"
root="$(new_fixture gate-execution)"
cd "${root}/work"
cat >"${root}/work/Taskfile.yml" <<'EOF'
version: '3'
tasks:
  fixture-verify:
    cmds:
      - echo "this represents a real test failure" && exit 1
  fixture-check:
    cmds:
      - echo fixture-check ok
EOF
git_q "${root}/work" add -A
git_q "${root}/work" commit -m "test: fixture-verify always fails here"
mark_base "${root}/work"
merge_base=$mark_base_tag
merge_base_sha=$mark_base_sha
code_sha="$(commit_on "${root}/work" "test: code" code.sh "code change")"
push_gated "$root" "$code_sha" absent "$merge_base" "$merge_base_sha"
assert_rc 3
printf '%s' "$err" | grep -F "fixture-verify" >/dev/null ||
    fail "the refusal should name the failed target: $err"
[ "$(git -C "${root}/origin.git" show-ref --heads | wc -l)" -eq 0 ] ||
    fail "a push whose required target fails must not land"

echo "  -> a mixed diff runs the code target, not the docs one, and a caller cannot fake it"
root="$(new_fixture mixed-refusal)"
cd "${root}/work"
cat >"${root}/work/Taskfile.yml" <<'EOF'
version: '3'
tasks:
  fixture-verify:
    cmds:
      - echo "the real code gate; this one must run for a mixed diff" && exit 1
  fixture-check:
    cmds:
      - echo "the docs gate; if this ran instead, the classifier picked the wrong target"
EOF
git_q "${root}/work" add -A
git_q "${root}/work" commit -m "test: only fixture-check would pass here"
mark_base "${root}/work"
merge_base=$mark_base_tag
merge_base_sha=$mark_base_sha
commit_on "${root}/work" "test: docs" g.md "docs change" >/dev/null
mixed_sha="$(commit_on "${root}/work" "test: code" code.sh "code change")"
push_gated "$root" "$mixed_sha" absent "$merge_base" "$merge_base_sha"
assert_rc 3
assert_reason
[ "$(git -C "${root}/origin.git" show-ref --heads | wc -l)" -eq 0 ] ||
    fail "a mixed diff must run (and be bound by) the code target, never the docs one, with no caller-supplied marker able to claim otherwise"

echo "  -> a docs-class push succeeds against the recomputed docs target"
root="$(new_fixture docs-push)"
cd "${root}/work"
mark_base "${root}/work"
merge_base=$mark_base_tag
merge_base_sha=$mark_base_sha
docs_sha="$(commit_on "${root}/work" "test: docs" g.md "docs change")"
push_gated "$root" "$docs_sha" absent "$merge_base" "$merge_base_sha"
assert_rc 0
printf '%s' "$out" | grep -F "ROUND-GREEN-${docs_sha}-fixture-check-docs" >/dev/null ||
    fail "a successful push must emit its own evidence marker naming the gated head, target, AND diff class (Codex cloud review, confirmed a policy could alias round_code/round_docs to the same target, making the target alone ambiguous): $out"
[ "$(git -C "${root}/origin.git" rev-parse refs/heads/main)" = "$docs_sha" ] ||
    fail "docs-class push did not land the gated commit"

echo "  -> a code-class push succeeds against the recomputed code target"
root="$(new_fixture code-push)"
cd "${root}/work"
mark_base "${root}/work"
merge_base=$mark_base_tag
merge_base_sha=$mark_base_sha
code_sha="$(commit_on "${root}/work" "test: code" code.sh "code change")"
push_gated "$root" "$code_sha" absent "$merge_base" "$merge_base_sha"
assert_rc 0
printf '%s' "$out" | grep -F "ROUND-GREEN-${code_sha}-fixture-verify-code" >/dev/null ||
    fail "a successful push must emit its own evidence marker naming the gated head, target, AND diff class: $out"
[ "$(git -C "${root}/origin.git" rev-parse refs/heads/main)" = "$code_sha" ] ||
    fail "code-class push did not land the gated commit"

echo "  -> a push whose local tracking-ref update fails is reported as uncertain, not silently swallowed"
root="$(new_fixture update-ref-uncertain)"
cd "${root}/work"
mark_base "${root}/work"
merge_base=$mark_base_tag
merge_base_sha=$mark_base_sha
code_sha="$(commit_on "${root}/work" "test: code" code.sh "code change")"
mkdir -p "${root}/work/.git/refs/remotes/origin"
touch "${root}/work/.git/refs/remotes/origin/main.lock"
push_gated "$root" "$code_sha" absent "$merge_base" "$merge_base_sha"
assert_rc 5
printf '%s' "$err" | grep -Fi "tracking ref may be stale" >/dev/null ||
    fail "a git update-ref failure after an already-successful push must be reported as uncertain (exit 5), not silently swallowed by the old '|| true' (Codex cloud review, confirmed: lock contention, permissions, or an invalid existing ref could all fail this update-ref while the real push had already landed): $err"
[ "$(git -C "${root}/origin.git" rev-parse refs/heads/main)" = "$code_sha" ] ||
    fail "the actual push must still have landed even though the local tracking-ref update failed"

echo "  -> the required target alone never substitutes for the secret scan"
root="$(new_fixture secret-refusal)"
cd "${root}/work"
mark_base "${root}/work"
merge_base=$mark_base_tag
merge_base_sha=$mark_base_sha
secret_sha="$(commit_on "${root}/work" "test: secret" leaked.env "$(fake_github_token)")"
push_gated "$root" "$secret_sha" absent "$merge_base" "$merge_base_sha"
assert_rc 3
printf '%s' "$err" | grep -Fi "secret scan" >/dev/null ||
    fail "the refusal should name the secret scan: $err"
[ "$(git -C "${root}/origin.git" show-ref --heads | wc -l)" -eq 0 ] ||
    fail "a push with a real secret must not land even when the required target passes"

echo "  -> a branch-committed .gitleaksignore matching its own leak is refused, not honored"
root="$(new_fixture gitleaksignore-mismatch)"
cd "${root}/work"
mark_base "${root}/work"
merge_base=$mark_base_tag
merge_base_sha=$mark_base_sha
secret_content="$(fake_github_token)"
printf '%s\n' "$secret_content" >"${root}/work/leaked.env"
git_q "${root}/work" add leaked.env
git_q "${root}/work" commit -m "test: secret"
fingerprint="$(git -C "${root}/work" rev-parse HEAD):leaked.env:github-pat:1"
printf '%s\n' "$fingerprint" >"${root}/work/.gitleaksignore"
git_q "${root}/work" add .gitleaksignore
git_q "${root}/work" commit -m "test: add a gitleaksignore matching the secret above"
ignore_sha="$(git -C "${root}/work" rev-parse HEAD)"
push_gated "$root" "$ignore_sha" absent "$merge_base" "$merge_base_sha"
assert_rc 3
printf '%s' "$err" | grep -Fi "secret scan" >/dev/null ||
    fail "the refusal should name the secret scan even though a matching .gitleaksignore exists: $err"
[ "$(git -C "${root}/origin.git" show-ref --heads | wc -l)" -eq 0 ] ||
    fail "a branch-committed .gitleaksignore must not suppress its own leaked secret's finding"

echo "  -> a .gitleaksignore committed as a symlink is refused outright"
root="$(new_fixture gitleaksignore-symlink)"
cd "${root}/work"
mark_base "${root}/work"
merge_base=$mark_base_tag
merge_base_sha=$mark_base_sha
external_target="${test_tmp}/external-ignore-target"
printf '%s\n' "not a fingerprint yet" >"$external_target"
ln -s "$external_target" "${root}/work/.gitleaksignore"
git_q "${root}/work" add .gitleaksignore
git_q "${root}/work" commit -m "test: gitleaksignore is a symlink"
symlink_sha="$(git -C "${root}/work" rev-parse HEAD)"
push_gated "$root" "$symlink_sha" absent "$merge_base" "$merge_base_sha"
assert_rc 3
printf '%s' "$err" | grep -Fi "secret scan" >/dev/null ||
    fail "the refusal should name the secret scan: $err"
[ "$(git -C "${root}/origin.git" show-ref --heads | wc -l)" -eq 0 ] ||
    fail "a symlinked .gitleaksignore must be refused, never scanned through"

echo "  -> the merge-base-materialized execution path is immune to worktree tampering"
root="$(new_fixture materialized)"
cd "${root}/work"
mark_base "${root}/work"
merge_base=$mark_base_tag
merge_base_sha=$mark_base_sha
materialized="$(extract_closure "${root}/work" "$merge_base_sha")"
cp "$helper" "${materialized}/scripts/round-push.sh"
chmod +x "${materialized}/scripts/round-push.sh"

# Mutate the WORKTREE's own copies of every closure-resident file to
# something that would behave differently (or simply break) if it were
# read instead of the extracted copy — proving the broker never resolves
# a worktree-resident path (config spec "Gate authority separates policy
# from branch implementation").
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

docs_sha="$(commit_on "${root}/work" "test: docs" g.md "docs change")"

set +e
ROUND_PUSH_TEST_BARE="$(git config --get roundpush.testBare)" \
    "${materialized}/scripts/round-push.sh" push \
    --remote origin --branch main --host github.com --repo owner/repo \
    --sha "$docs_sha" --expect absent \
    --against "$merge_base" --closure-base "$merge_base_sha" \
    --policy "${materialized}/.devflow.toml" \
    --devflow-policy-script "${materialized}/scripts/devflow-policy.mjs" \
    --gitleaks-script "${materialized}/scripts/gitleaks-scan.sh" \
    --gitleaks-config "${materialized}/.gitleaks.toml" \
    --registry "${materialized}/agent-registry.json" \
    --task-targets "$task_targets_file" \
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
cat >>"${root}/work/Taskfile.yml" <<'EOF'
  security:secrets:
    cmds:
      - echo "tampered recipe would report clean without ever scanning" && exit 0
EOF
git_q "${root}/work" add -A
git_q "${root}/work" commit -m "test: tamper the security:secrets Taskfile recipe"
mark_base "${root}/work"
merge_base=$mark_base_tag
merge_base_sha=$mark_base_sha
secret_sha="$(commit_on "${root}/work" "test: secret" leaked.env "$(fake_github_token)")"
push_gated "$root" "$secret_sha" absent "$merge_base" "$merge_base_sha"
assert_rc 3
printf '%s' "$err" | grep -Fi "secret scan" >/dev/null ||
    fail "the refusal should still name the secret scan even with a tampered Taskfile recipe: $err"
[ "$(git -C "${root}/origin.git" show-ref --heads | wc -l)" -eq 0 ] ||
    fail "a real secret must not push even when the worktree's own security:secrets recipe would report clean; round-push.sh never invokes task for the scan"

echo "  -> round-push.sh helper invocation is shell-independent"
if command -v zsh >/dev/null 2>&1; then
    root="$(new_fixture zsh-call)"
    cd "${root}/work"
    mark_base "${root}/work"
    merge_base=$mark_base_tag
    merge_base_sha=$mark_base_sha
    code_sha="$(commit_on "${root}/work" "test: code" code.sh "code change")"
    set +e
    HELPER="$helper" ROUND_PUSH_TEST_BARE="$(git config --get roundpush.testBare)" \
    SHA="$code_sha" MERGE_BASE="$merge_base" MERGE_BASE_SHA="$merge_base_sha" \
    POLICY="${policy_args[1]}" DEVFLOW_SCRIPT="${policy_args[3]}" \
    GITLEAKS_SCRIPT="${scan_args[1]}" GITLEAKS_CONFIG="${scan_args[3]}" \
    REGISTRY="${policy_args[5]}" TASK_TARGETS="${policy_args[7]}" \
        zsh -c '"$HELPER" push --remote origin --branch main --host github.com --repo owner/repo \
            --sha "$SHA" --expect absent \
            --against "$MERGE_BASE" --closure-base "$MERGE_BASE_SHA" \
            --policy "$POLICY" --devflow-policy-script "$DEVFLOW_SCRIPT" \
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
