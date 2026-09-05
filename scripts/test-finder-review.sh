#!/usr/bin/env bash
# test-finder-review.sh — offline guards for scripts/finder-review.sh.
#
# Neither vendor CLI is installed here (nor on CI), so every case runs against
# a stub on PATH and the runner's own dry-run mode. What is asserted is this
# repo's side of the contract: the registry is the authority on which finders
# exist, the shared scope resolver and shared instructions are what a finder
# is driven with, and a missing binary refuses NON-ZERO rather than exiting 0
# as the clean pass a capped stage would exit on.
set -euo pipefail

repo="$(git rev-parse --show-toplevel)"
cd "$repo"

runner="scripts/finder-review.sh"
fail() {
    echo "TEST FAIL: $*" >&2
    exit 1
}
[ -x "$runner" ] || fail "missing or non-executable $runner"
command -v jq >/dev/null 2>&1 || fail "jq is required"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
stub_bin="$tmp/bin"
mkdir -p "$stub_bin"
for tool in copilot coderabbit; do
    cat >"$stub_bin/$tool" <<EOF
#!/usr/bin/env bash
echo "STUB $tool invoked with \$# argument(s)"
EOF
    chmod +x "$stub_bin/$tool"
done

# A worktree with something to review, so the shared scope resolver has a
# non-empty target: it refuses an empty scope by design, and that refusal is
# its own test in scripts/test-codex-review.sh.
work="$tmp/repo"
mkdir -p "$work"
git init -q "$work"
git -C "$work" config user.email fixture@example.invalid
git -C "$work" config user.name 'Fixture Author'
mkdir -p "$work/scripts/lib" "$work/src"
cp "$repo/$runner" "$work/scripts/"
cp "$repo/scripts/lib/review-scope.sh" "$work/scripts/lib/"
cp -R "$repo/scripts/lib/review-instructions" "$work/scripts/lib/"
cp "$repo/agent-registry.json" "$work/"
printf 'initial\n' >"$work/src/app.txt"
git -C "$work" add -A
git -C "$work" commit -qm 'test: fixture base'
printf 'changed\n' >"$work/src/app.txt"

run_in_work() {
    (cd "$work" && PATH="$stub_bin:$PATH" "$@")
}

echo "==> copilot is driven with the shared scope, mode and severity instructions"
out="$(run_in_work env FINDER_REVIEW_DRY_RUN=1 ./scripts/finder-review.sh challenge copilot --uncommitted 2>/dev/null)"
grep -Fq 'finder: copilot-adversarial' <<<"$out" ||
    fail "the dry run did not resolve the registry finder slug: $out"
grep -Fq 'Run an ADVERSARIAL review' <<<"$out" ||
    fail "the challenge mode instruction was not rendered"
grep -Fq 'Only P0 and P1 decide' <<<"$out" ||
    fail "the shared severity scale was not rendered"
grep -Fq 'Review the uncommitted work' <<<"$out" ||
    fail "the shared scope resolver did not supply the target"
grep -Fq 'src/app.txt' <<<"$out" ||
    fail "the authoritative manifest was not rendered"
grep -Fq 'The change itself:' <<<"$out" ||
    fail "the change was not embedded for a finder that is given the diff"

echo "==> the review mode renders the verification instruction, not the adversarial one"
out="$(run_in_work env FINDER_REVIEW_DRY_RUN=1 ./scripts/finder-review.sh review copilot --uncommitted 2>/dev/null)"
grep -Fq 'finder: copilot-verification' <<<"$out" || fail "review mode resolved the wrong finder: $out"
grep -Fq 'Run a VERIFICATION-CHECKPOINT review' <<<"$out" || fail "review mode instruction missing"
grep -Fq 'Run an ADVERSARIAL review' <<<"$out" && fail "review mode rendered the adversarial instruction"

echo "==> a registered finder this runner cannot drive is refused, never guessed at"
# CodeRabbit is registered as a PR-side finder only, precisely because its CLI
# takes no target from us and a local pass could not be bound to the round's
# reviewed_head. Asking for one must refuse rather than invent an invocation.
set +e
out="$(run_in_work env FINDER_REVIEW_DRY_RUN=1 ./scripts/finder-review.sh review coderabbit 2>&1)"
status=$?
set -e
[ "$status" -eq 2 ] || fail "an undrivable finder was accepted (rc $status): $out"
grep -Fq 'is not a registered finder' <<<"$out" ||
    fail "the refusal did not name the missing registry entry: $out"

echo "==> an untracked path containing a newline still reaches the prompt"
# git ls-files quotes such a path by default, and the quoted display form is
# not a path git diff can open — so the file would stay in the claimed scope
# with its contents silently absent from the review.
newline_file="$work/src/we$(printf '\n')ird.txt"
printf 'contents behind a newline in the path\n' >"$newline_file"
out="$(run_in_work env FINDER_REVIEW_DRY_RUN=1 ./scripts/finder-review.sh challenge copilot --uncommitted 2>/dev/null)"
grep -Fq 'contents behind a newline in the path' <<<"$out" ||
    fail "an untracked file whose path contains a newline was dropped from the prompt"
rm -f "$newline_file"

echo "==> a failure while collecting the untracked diff refuses the pass"
# `git diff --no-index` exits 1 when files differ, which is normal here — but
# any other status is a real error, and swallowing it would send a partial
# diff under a manifest claiming to be complete.
fail_bin="$tmp/failing-git-bin"
mkdir -p "$fail_bin"
real_git="$(command -v git)"
cat >"$fail_bin/git" <<EOF
#!/usr/bin/env bash
# Fail only the untracked-file diff; every other git call is the real one.
if [ "\$1" = diff ] && [ "\$2" = --no-index ]; then
    echo "simulated git failure" >&2
    exit 128
fi
exec "$real_git" "\$@"
EOF
chmod +x "$fail_bin/git"
printf 'new file\n' >"$work/src/untracked.txt"
set +e
out="$( (cd "$work" && PATH="$fail_bin:$stub_bin:$PATH" FINDER_REVIEW_DRY_RUN=1 \
    ./scripts/finder-review.sh challenge copilot --uncommitted) 2>&1)"
status=$?
set -e
rm -f "$work/src/untracked.txt"
[ "$status" -eq 1 ] || fail "a failed untracked diff did not refuse (rc $status): $out"
grep -Fq 'Refusing rather than reviewing a partial diff' <<<"$out" ||
    fail "the partial-diff refusal did not explain itself: $out"

echo "==> the vendor invocation is overridable without editing the runner"
out="$(run_in_work env FINDER_REVIEW_DRY_RUN=1 FINDER_REVIEW_COPILOT_ARGS='--prompt --no-color' \
    ./scripts/finder-review.sh review copilot --uncommitted 2>/dev/null)"
grep -Fq 'command: copilot --prompt --no-color' <<<"$out" ||
    fail "the vendor argument override was ignored: $out"

echo "==> a diff past the prompt bound refuses rather than reviewing part of the change"
# This finder is handed the diff and granted no tools, so a truncated prompt
# is a review of part of the change reported as a review of all of it.
set +e
out="$(run_in_work env FINDER_REVIEW_DRY_RUN=1 FINDER_REVIEW_MAX_DIFF_BYTES=10 \
    ./scripts/finder-review.sh challenge copilot --uncommitted 2>&1)"
status=$?
set -e
[ "$status" -eq 1 ] || fail "an oversized diff was truncated rather than refused (rc $status): $out"
grep -Fq 'past the 10-byte prompt bound' <<<"$out" ||
    fail "the oversized-diff refusal did not name the bound: $out"
grep -Fq 'Narrow the scope' <<<"$out" ||
    fail "the oversized-diff refusal offered no way forward: $out"

echo "==> a missing binary refuses non-zero rather than reading as a clean pass"
set +e
out="$( (cd "$work" && FINDER_REVIEW_COPILOT_BIN=definitely-not-installed \
    ./scripts/finder-review.sh challenge copilot --uncommitted) 2>&1)"
status=$?
set -e
[ "$status" -eq 1 ] || fail "a missing finder binary exited $status, not 1"
grep -Fq 'reads as the clean pass' <<<"$out" ||
    fail "the refusal did not say why a skip is unsafe: $out"

echo "==> an unregistered finder/target pairing refuses before any model call"
mutated="$tmp/mutated-registry.json"
jq '(.finders[] | select(.slug == "copilot-adversarial") | .invocation.target) = "challenge:something-else"' \
    "$repo/agent-registry.json" >"$mutated"
cp "$mutated" "$work/agent-registry.json"
set +e
out="$(run_in_work env FINDER_REVIEW_DRY_RUN=1 ./scripts/finder-review.sh challenge copilot --uncommitted 2>&1)"
status=$?
set -e
cp "$repo/agent-registry.json" "$work/agent-registry.json"
[ "$status" -eq 2 ] || fail "a registry/Taskfile disagreement exited $status, not 2"
grep -Fq 'Reconcile' <<<"$out" ||
    fail "the registry/Taskfile disagreement was not reported: $out"

echo "==> every registered local-cli finder's invocation target exists in the Taskfile"
# Read from the Taskfile rather than `task --list-all`: this loop's stdin is
# already the process substitution below, and a `task` child inheriting it
# swallows the remaining targets, so the loop would silently check only the
# first one.
targets="$(jq -r '.finders[] | select(.surface == "local-cli") | .invocation.target' "$repo/agent-registry.json")"
while IFS= read -r target; do
    [ -n "$target" ] || continue
    grep -Eq "^  ${target}:\s*$" Taskfile.yml ||
        fail "registry finder invocation target '$target' has no Taskfile target"
done <<EOF
$targets
EOF

echo "finder review runner OK"
