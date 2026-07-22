#!/usr/bin/env bash
# test-codex-review.sh — offline unit tests for scripts/codex-review.sh's
# target selection and prompt assembly. A stub `codex` on PATH records its
# arguments, so no network, auth, or real review is involved. Guards the
# regression a real adversarial review caught: with no local main/master and
# origin/HEAD pointing at another default branch, the base fallback used to
# strip `origin/` into a nonexistent local ref and silently report nothing
# to review. Run via `task test:codex-review`.
set -euo pipefail

repo="$(git rev-parse --show-toplevel)"

fail() {
    echo "TEST FAIL: $*" >&2
    exit 1
}

test_tmp="$(mktemp -d)"
trap 'rm -rf "$test_tmp"' EXIT

# Stub codex: print the invocation so assertions can grep it.
mkdir -p "${test_tmp}/bin"
printf '%s\n' '#!/usr/bin/env bash' 'printf "STUB-ARGS:%s %s %s\n" "$1" "$2" "${3:-}"' 'if [ "${3:-}" = "-" ]; then printf "STUB-PROMPT:%s\n" "$(cat)"; fi' >"${test_tmp}/bin/codex"
chmod +x "${test_tmp}/bin/codex"
PATH="${test_tmp}/bin:${PATH}"
export PATH

git_t() {
    git -c user.email=test@test -c user.name=test "$@"
}

run_tty() {
    # Gate toggles demand a TTY on stdin; allocate a pty so fixtures can get
    # past the interactivity guard and exercise the logic behind it (macOS
    # and util-linux `script` have incompatible CLIs).
    if [ "$(uname)" = "Darwin" ]; then
        script -q /dev/null "$@" </dev/null
    else
        # printf %q keeps argv intact through script -c's shell reparse
        # (paths with spaces/metacharacters would split under a bare $*).
        script -qec "$(printf '%q ' "$@")" /dev/null </dev/null
    fi
}

# Fixture: an upstream whose default branch is `develop` (not main/master),
# and a clone with only origin/develop plus a feature branch.
git init -q -b develop "${test_tmp}/upstream"
(
    cd "${test_tmp}/upstream"
    mkdir scripts
    cp "${repo}/scripts/codex-review.sh" scripts/
    git add -A
    git_t commit -q -m base
)
git clone -q "${test_tmp}/upstream" "${test_tmp}/clone"
cd "${test_tmp}/clone"
git checkout -q -b feature
echo change >feature.txt
git add feature.txt
git_t commit -q -m work
git branch -q -D develop

run() {
    ./scripts/codex-review.sh "$@" 2>&1
}

echo "==> clean tree, no local main/master: falls back to origin/HEAD's branch"
out="$(run challenge)" || fail "challenge exited non-zero: $out"
echo "$out" | grep -q "STUB-ARGS:exec review" || fail "codex exec review not invoked: $out"
echo "$out" | grep -q "base branch 'origin/develop'" || fail "remote-qualified fallback base missing: $out"
echo "$out" | grep -q "ADVERSARIAL" || fail "challenge mode instructions missing: $out"
echo "$out" | grep -q "feature.txt" || fail "changed-file manifest missing from branch-scope prompt: $out"

echo "==> origin/HEAD outranks a stray local main"
git branch -q main "$(git rev-list --max-parents=0 HEAD)"
out="$(run challenge)" || fail "challenge with stray local main exited non-zero: $out"
echo "$out" | grep -q "base branch 'origin/develop'" || fail "stray local main hijacked base detection: $out"
git branch -q -D main

echo "==> --base with no merge base fails fast"
unrelated="$(git_t commit-tree "$(git mktree </dev/null)" -m orphan)"
if out="$(run review --base "$unrelated" 2>&1)"; then
    fail "--base with unrelated history accepted: $out"
fi
echo "$out" | grep -q "STUB-ARGS" && fail "codex invoked despite no merge base: $out"
echo "$out" | grep -q "no merge base" || fail "missing no-merge-base message: $out"

echo "==> explicit --base and focus text reach the prompt"
out="$(run review --base origin/develop watch the hooks)" || fail "review --base exited non-zero: $out"
echo "$out" | grep -q "base branch 'origin/develop'" || fail "--base not honored: $out"
echo "$out" | grep -q "VERIFICATION-CHECKPOINT" || fail "review mode instructions missing: $out"
echo "$out" | grep -q "watch the hooks" || fail "focus text missing from prompt: $out"

echo "==> dirty tree auto-selects uncommitted scope and enumerates untracked dirs"
echo x >dirty.txt
mkdir newdir
echo y >newdir/inner.txt
out="$(run review)" || fail "dirty-tree review exited non-zero: $out"
echo "$out" | grep -q "uncommitted work" || fail "dirty tree did not select uncommitted scope: $out"
echo "$out" | grep -q "dirty.txt" || fail "untracked file missing from uncommitted manifest: $out"
echo "$out" | grep -q "newdir/inner.txt" || fail "file inside untracked dir missing from manifest (collapsed to dir entry): $out"
rm -rf dirty.txt newdir

echo "==> a >200-entry dirty tree still reviews (no SIGPIPE abort) and marks truncation"
# Top-level files: git status collapses an untracked directory into a single
# "?? dir/" entry, which would defeat the >200-entry premise.
i=1
while [ "$i" -le 250 ]; do
    : >"bulk_f${i}.txt"
    i=$((i + 1))
done
out="$(run review)" || fail "large dirty tree aborted the review (pipefail/SIGPIPE regression): $out"
echo "$out" | grep -q "STUB-ARGS:exec review" || fail "codex not invoked on large dirty tree: $out"
echo "$out" | grep -q "manifest truncated at 200 entries" || fail "truncation marker missing on >200-entry manifest: $out"
rm -f bulk_f*.txt

echo "==> clean tree at the base tip reports nothing to review"
git checkout -q -b tipcheck origin/develop
out="$(run review)" || fail "nothing-to-review case exited non-zero: $out"
echo "$out" | grep -q "Nothing to review" || fail "expected nothing-to-review message: $out"
echo "$out" | grep -q "STUB-ARGS" && fail "codex invoked despite nothing to review: $out"

echo "==> bad mode is rejected"
if out="$(run bogus 2>&1)"; then
    fail "bogus mode accepted: $out"
fi

echo "==> invalid explicit targets fail fast without invoking codex"
if out="$(run review --base no-such-ref 2>&1)"; then
    fail "--base with an unresolvable ref was accepted: $out"
fi
echo "$out" | grep -q "STUB-ARGS" && fail "codex invoked despite bad --base ref: $out"
echo "$out" | grep -q "does not resolve" || fail "missing fail-fast message for bad --base: $out"
if out="$(run challenge --commit 0000000000000000000000000000000000000000 2>&1)"; then
    fail "--commit with an unresolvable sha was accepted: $out"
fi
echo "$out" | grep -q "STUB-ARGS" && fail "codex invoked despite bad --commit sha: $out"

echo "==> conflicting target flags are rejected"
if out="$(run review --base origin/develop --uncommitted 2>&1)"; then
    fail "conflicting target flags accepted (last-wins regression): $out"
fi
echo "$out" | grep -q "mutually exclusive" || fail "missing conflicting-flags message: $out"
echo "$out" | grep -q "STUB-ARGS" && fail "codex invoked despite conflicting flags: $out"

echo "==> --commit manifests cover root and merge commits"
root_sha="$(git rev-list --max-parents=0 HEAD | tail -1)"
out="$(run review --commit "$root_sha")" || fail "root-commit review exited non-zero: $out"
echo "$out" | grep -q "codex-review.sh" || fail "root commit manifest empty (missing --root): $out"
git checkout -q -b mergetest feature
git branch -q sidebr "$root_sha"
git checkout -q sidebr
echo s >side.txt
git add side.txt
git_t commit -q -m side
git checkout -q mergetest
git_t merge -q --no-ff -m merge sidebr >/dev/null 2>&1 || fail "fixture merge failed"
merge_sha="$(git rev-parse HEAD)"
out="$(run review --commit "$merge_sha")" || fail "merge-commit review exited non-zero: $out"
echo "$out" | grep -q "side.txt" || fail "merge commit manifest missing first-parent change: $out"
echo "$out" | grep -q "feature.txt" && fail "merge manifest includes pre-merge mainline files (diff-tree -m regression): $out"

echo "==> gate: another repo's project-scoped plugin install is not accepted"
fake_claude="${test_tmp}/claude-config"
mkdir -p "${fake_claude}/plugins"
cat >"${fake_claude}/plugins/installed_plugins.json" <<'JSON'
{
  "version": 2,
  "plugins": {
    "codex@openai-codex": [
      {
        "scope": "project",
        "projectPath": "/some/other/repo",
        "installPath": "/nonexistent/plugin/root",
        "version": "1.0.6"
      }
    ]
  }
}
JSON
if out="$( (
    export CLAUDE_CONFIG_DIR="$fake_claude"
    run_tty "${repo}/scripts/codex-gate.sh" enable
) 2>&1)"; then
    fail "gate enable accepted an install scoped to another repo: $out"
fi
echo "$out" | grep -q "not installed" || fail "missing not-installed message for foreign-scoped install: $out"

echo "==> gate: refuses to arm when the companion reports not ready"
fake_plugin="${test_tmp}/fake-plugin"
mkdir -p "${fake_plugin}/scripts" "${fake_claude}2/plugins"
cat >"${fake_plugin}/scripts/codex-companion.mjs" <<'MJS'
const args = process.argv.slice(2);
if (args.includes("--json")) {
  console.log(JSON.stringify({ ready: process.env.FAKE_READY === "true" }));
} else {
  console.log(`companion invoked: ${args.join(" ")}`);
}
MJS
cat >"${fake_claude}2/plugins/installed_plugins.json" <<JSON
{
  "version": 2,
  "plugins": {
    "codex@openai-codex": [
      { "scope": "user", "installPath": "${fake_plugin}", "version": "1.0.6" }
    ]
  }
}
JSON
if out="$( (
    export CLAUDE_CONFIG_DIR="${fake_claude}2" CLAUDE_PLUGIN_DATA="${test_tmp}/plugin-data" FAKE_READY=false
    run_tty "${repo}/scripts/codex-gate.sh" enable
) 2>&1)"; then
    fail "gate armed despite companion ready:false: $out"
fi
echo "$out" | grep -q "not ready" || fail "missing not-ready refusal message: $out"

echo "==> gate: arms when the companion reports ready"
out="$( (
    export CLAUDE_CONFIG_DIR="${fake_claude}2" CLAUDE_PLUGIN_DATA="${test_tmp}/plugin-data" FAKE_READY=true
    run_tty "${repo}/scripts/codex-gate.sh" enable
) 2>&1)" ||
    fail "gate enable failed with companion ready:true: $out"
echo "$out" | grep -q "companion invoked: setup --enable-review-gate" || fail "companion toggle not invoked after readiness pass: $out"

echo "==> gate: refuses when the plugin is explicitly disabled in settings"
ws="${test_tmp}/ws"
mkdir -p "${ws}/scripts" "${ws}/.claude"
cp "${repo}/scripts/codex-gate.sh" "${ws}/scripts/"
printf '%s\n' '{ "enabledPlugins": { "codex@openai-codex": false } }' >"${ws}/.claude/settings.local.json"
if out="$( (
    export CLAUDE_CONFIG_DIR="${fake_claude}2" CLAUDE_PLUGIN_DATA="${test_tmp}/plugin-data" FAKE_READY=true
    run_tty "${ws}/scripts/codex-gate.sh" enable
) 2>&1)"; then
    fail "gate armed despite plugin disabled in settings: $out"
fi
echo "$out" | grep -q "explicitly disabled" || fail "missing disabled-plugin refusal message: $out"

echo "==> gate: status warns that an armed flag is inert when the plugin is disabled"
out="$(
    (
        export CLAUDE_CONFIG_DIR="${fake_claude}2" CLAUDE_PLUGIN_DATA="${test_tmp}/plugin-data"
        "${ws}/scripts/codex-gate.sh" status
    ) 2>&1
)" || fail "status exited non-zero in disabled-plugin workspace: $out"
echo "$out" | grep -q "INERT" || fail "status did not flag the inert gate flag: $out"

echo "==> gate: enable refuses in a non-interactive shell"
if out="$(CLAUDE_CONFIG_DIR="${fake_claude}2" CLAUDE_PLUGIN_DATA="${test_tmp}/plugin-data" FAKE_READY=true "${repo}/scripts/codex-gate.sh" enable </dev/null 2>&1)"; then
    fail "non-interactive enable was accepted (silent arming bypass): $out"
fi
echo "$out" | grep -q "non-interactive" || fail "missing non-interactive enable refusal message: $out"

echo "==> gate: disable refuses in a non-interactive shell"
if out="$(CLAUDE_CONFIG_DIR="${fake_claude}2" CLAUDE_PLUGIN_DATA="${test_tmp}/plugin-data" "${repo}/scripts/codex-gate.sh" disable </dev/null 2>&1)"; then
    fail "non-interactive disable was accepted (agent could disarm its own gate): $out"
fi
echo "$out" | grep -q "non-interactive" || fail "missing non-interactive disable refusal message: $out"

echo "codex-review + codex-gate guards OK (18 cases)"
