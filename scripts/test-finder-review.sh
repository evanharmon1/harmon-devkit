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
cp "$repo/scripts/lib/readonly-sandbox.sh" "$work/scripts/lib/"
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

echo "==> a write from inside the pass is denied by the kernel"
# /review requires the capability split to be installed and VERIFIED. It is
# built around the CLI rather than asked of it: a bubblewrap sandbox over a
# scratch git worktree, an isolated HOME, and the tree proven unchanged
# afterwards. First defence — a write simply fails.
writer_bin="$tmp/writer-bin"
mkdir -p "$writer_bin"
cat >"$writer_bin/copilot" <<'EOF'
#!/usr/bin/env bash
printf 'tampered\n' >./TAMPERED.txt
echo "P1 src/app.txt:1 — a finding"
EOF
chmod +x "$writer_bin/copilot"
out="$( (cd "$work" && PATH="$writer_bin:$PATH" ./scripts/finder-review.sh challenge copilot --uncommitted) 2>&1)"
grep -Eq 'Read-only file system|Permission denied' <<<"$out" ||
    fail "the scratch checkout was writable from inside the pass: $out"
[ ! -e "$work/TAMPERED.txt" ] ||
    fail "a write from inside the pass reached the real worktree"

echo "==> git inside the pass cannot reach the real repository's refs"
# The specific hole a file-mode-only boundary left: a linked worktree's .git is
# a POINTER into the real repository, so update-ref could alter shared refs
# while the scratch tree stayed byte-identical and the verification passed.
refattack_bin="$tmp/refattack-bin"
mkdir -p "$refattack_bin"
cat >"$refattack_bin/copilot" <<'EOF'
#!/usr/bin/env bash
git update-ref refs/heads/attacked HEAD 2>&1 | head -1
echo "P1 src/app.txt:1 — a finding"
EOF
chmod +x "$refattack_bin/copilot"
out="$( (cd "$work" && PATH="$refattack_bin:$PATH" ./scripts/finder-review.sh challenge copilot --uncommitted) 2>&1)"
git -C "$work" rev-parse --verify --quiet refs/heads/attacked >/dev/null &&
    fail "a pass wrote a ref into the real repository: $out"

echo "==> the pass cannot read the host's other credentials"
# A blanket read-only bind is not isolation: gh falls back to
# ~/.config/gh/hosts.yml, and ~/.aws and npm credentials are readable, so a
# finder with shell capability could make authenticated remote writes.
creds_bin="$tmp/creds-bin"
mkdir -p "$creds_bin"
cat >"$creds_bin/copilot" <<'EOF'
#!/usr/bin/env bash
for p in "$HOME/.config/gh" "$HOME/.aws" "$HOME/.npmrc" "$HOME/.gitconfig"; do
    [ -e "$p" ] && echo "VISIBLE $p"
done
echo "P1 src/app.txt:1 — a finding"
EOF
chmod +x "$creds_bin/copilot"
out="$( (cd "$work" && PATH="$creds_bin:$PATH" ./scripts/finder-review.sh challenge copilot --uncommitted) 2>&1)"
! grep -q '^VISIBLE ' <<<"$out" ||
    fail "host credentials were visible inside the sandbox: $(grep '^VISIBLE ' <<<"$out")"

echo "==> the pass cannot see or signal host processes"
# The namespaces the model call does not need are unshared. Network is not,
# and that residual is documented rather than silently relied on.
psbin="$tmp/ps-bin"
mkdir -p "$psbin"
cat >"$psbin/copilot" <<'EOF'
#!/usr/bin/env bash
# In its own PID namespace this sees only itself and its children.
echo "PIDS=$(ls -d /proc/[0-9]* 2>/dev/null | wc -l)"
echo "P1 src/app.txt:1 — a finding"
EOF
chmod +x "$psbin/copilot"
out="$( (cd "$work" && PATH="$psbin:$PATH" ./scripts/finder-review.sh challenge copilot --uncommitted) 2>&1)"
pids="$(sed -n 's/^PIDS=//p' <<<"$out")"
[ -n "$pids" ] || fail "the process-visibility probe did not run: $out"
[ "$pids" -le 5 ] ||
    fail "the pass could see $pids host processes; the PID namespace was not unshared"

echo "==> the sandbox is an allowlist: unnamed paths and variables are absent"
# `--ro-bind / /` plus a list of secrets to unset was subtract-known-secrets:
# a credential outside HOME, or in a variable nobody thought to name, stayed
# readable — and with egress open that is exfiltratable. Only named paths are
# bound and only named variables are passed.
secret_dir="$tmp/host-secrets"
mkdir -p "$secret_dir"
printf 'super-secret\n' >"$secret_dir/token"
probe_bin="$tmp/probe-bin"
mkdir -p "$probe_bin"
cat >"$probe_bin/copilot" <<'EOF'
#!/usr/bin/env bash
[ -e "$SECRET_PROBE_PATH" ] && echo "VISIBLE_PATH"
[ -n "${SECRET_PROBE_VALUE:-}" ] && echo "VISIBLE_ENV"
echo "P1 src/app.txt:1 — a finding"
EOF
chmod +x "$probe_bin/copilot"
out="$( (cd "$work" && PATH="$probe_bin:$PATH" \
    SECRET_PROBE_PATH="$secret_dir/token" SECRET_PROBE_VALUE=leaked \
    ./scripts/finder-review.sh challenge copilot --uncommitted) 2>&1)"
grep -q 'VISIBLE_PATH' <<<"$out" &&
    fail "a host path outside the allowlist was readable inside the sandbox"
grep -q 'VISIBLE_ENV' <<<"$out" &&
    fail "an environment variable outside the allowlist reached the sandbox"

echo "==> an operator can name an extra path and variable deliberately"
out="$( (cd "$work" && PATH="$probe_bin:$PATH" \
    SECRET_PROBE_PATH="$secret_dir/token" SECRET_PROBE_VALUE=allowed \
    FINDER_REVIEW_SANDBOX_EXTRA_RO="$secret_dir" \
    FINDER_REVIEW_SANDBOX_ENV="SECRET_PROBE_PATH:SECRET_PROBE_VALUE" \
    ./scripts/finder-review.sh challenge copilot --uncommitted) 2>&1)"
grep -q 'VISIBLE_PATH' <<<"$out" ||
    fail "a deliberately named path was still not readable: $out"
grep -q 'VISIBLE_ENV' <<<"$out" ||
    fail "a deliberately named variable did not reach the sandbox: $out"

echo "==> the verification catches a tree that changed, independently of the kernel"
# The two defences are separate on purpose: this one exercises the proof, by
# mutating the checkout from OUTSIDE the sandbox (where the kernel denial does
# not apply) and asserting the pass would be refused.
(
    cd "$work" || exit 1
    # shellcheck source=/dev/null
    . ./scripts/lib/readonly-sandbox.sh
    sandbox_create >/dev/null || exit 1
    chmod u+w "$readonly_sandbox_dir"
    printf 'tampered\n' >"$readonly_sandbox_dir/TAMPERED.txt"
    if sandbox_verify 2>/dev/null; then
        sandbox_cleanup
        exit 1
    fi
    sandbox_cleanup
) || fail "the verification accepted a checkout that had been modified"

echo "==> no kernel sandbox means the dispatch is refused, not downgraded"
set +e
out="$( (cd "$work" && PATH="$writer_bin:$PATH" READONLY_SANDBOX_BWRAP=/nonexistent/bwrap \
    ./scripts/finder-review.sh challenge copilot --uncommitted) 2>&1)"
status=$?
set -e
[ "$status" -eq 1 ] || fail "a pass ran without a kernel sandbox (rc $status): $out"
grep -Fq 'no bubblewrap' <<<"$out" ||
    fail "the missing-sandbox refusal did not name what is missing: $out"

echo "==> a well-behaved pass in the sandbox is accepted and its output returned"
quiet_bin="$tmp/quiet-bin"
mkdir -p "$quiet_bin"
cat >"$quiet_bin/copilot" <<'EOF'
#!/usr/bin/env bash
echo "P1 src/app.txt:1 — a finding"
EOF
chmod +x "$quiet_bin/copilot"
out="$( (cd "$work" && PATH="$quiet_bin:$PATH" ./scripts/finder-review.sh challenge copilot --uncommitted) 2>/dev/null)"
grep -Fq 'P1 src/app.txt:1' <<<"$out" ||
    fail "a clean sandboxed pass did not return its output: $out"

echo "==> the scratch checkout leaves nothing behind"
[ -z "$(git -C "$work" worktree list --porcelain | grep -c 'finder-readonly' || true)" ] ||
    [ "$(git -C "$work" worktree list --porcelain | grep -c 'finder-readonly')" = 0 ] ||
    fail "a scratch worktree survived the pass: $(git -C "$work" worktree list)"

echo "==> the CodeRabbit local finder refuses, naming why and where it is tracked"
set +e
out="$(run_in_work env FINDER_REVIEW_DRY_RUN=1 ./scripts/finder-review.sh review coderabbit 2>&1)"
status=$?
set -e
[ "$status" -eq 2 ] || fail "the CodeRabbit local finder did not refuse (rc $status): $out"
grep -Fq 'resolves its own review scope' <<<"$out" ||
    fail "the CodeRabbit refusal did not say why: $out"
grep -Fq 'harmon-devkit#809' <<<"$out" ||
    fail "the CodeRabbit refusal did not name where it is tracked: $out"

echo "==> a finder with no registry entry at all is refused before any model call"
set +e
out="$(run_in_work env FINDER_REVIEW_DRY_RUN=1 ./scripts/finder-review.sh review nosuchtool 2>&1)"
status=$?
set -e
[ "$status" -eq 2 ] || fail "an unregistered finder was accepted (rc $status): $out"
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
    \
    ./scripts/finder-review.sh challenge copilot --uncommitted) 2>&1)"
status=$?
set -e
rm -f "$work/src/untracked.txt"
[ "$status" -eq 1 ] || fail "a failed untracked diff did not refuse (rc $status): $out"
grep -Fq 'Refusing rather than reviewing a partial diff' <<<"$out" ||
    fail "the partial-diff refusal did not explain itself: $out"

echo "==> the vendor invocation is overridable without editing the runner"
out="$(run_in_work env FINDER_REVIEW_DRY_RUN=1 \
    FINDER_REVIEW_COPILOT_ARGS='--prompt --no-color' \
    ./scripts/finder-review.sh review copilot --uncommitted 2>/dev/null)"
grep -Fq 'command: copilot --prompt --no-color' <<<"$out" ||
    fail "the vendor argument override was ignored: $out"

echo "==> a prompt past the bound refuses rather than reviewing part of the change"
# This finder is handed the diff and needs no tools, so a truncated prompt is
# a review of part of the change reported as a review of all of it.
set +e
out="$(run_in_work env FINDER_REVIEW_DRY_RUN=1 \
    FINDER_REVIEW_MAX_PROMPT_BYTES=10 \
    ./scripts/finder-review.sh challenge copilot --uncommitted 2>&1)"
status=$?
set -e
[ "$status" -eq 1 ] || fail "an oversized prompt was truncated rather than refused (rc $status): $out"
grep -Fq 'past the 10-byte bound' <<<"$out" ||
    fail "the oversized-diff refusal did not name the bound: $out"
grep -Fq 'Narrow the scope' <<<"$out" ||
    fail "the oversized-prompt refusal offered no way forward: $out"

# The bound is on the ASSEMBLED argument, not the diff alone: the manifest,
# the mode prose, the severity scale and the focus text all ride in the same
# argv element, and measuring only the diff left them unbounded.
set +e
out="$(run_in_work env FINDER_REVIEW_DRY_RUN=1 \
    FINDER_REVIEW_MAX_PROMPT_BYTES=2000 \
    ./scripts/finder-review.sh challenge copilot --uncommitted \
    "$(head -c 2500 /dev/zero | tr '\0' 'x')" 2>&1)"
status=$?
set -e
[ "$status" -eq 1 ] ||
    fail "focus text alone pushed the prompt past the bound without refusing (rc $status)"
grep -Fq 'assembled prompt' <<<"$out" ||
    fail "the refusal did not say it measured the assembled prompt: $out"

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
