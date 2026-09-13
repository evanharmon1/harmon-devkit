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
    return 0
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
grep -Fq 'BEGIN UNTRUSTED REPOSITORY DIFF' <<<"$out" ||
    fail "the embedded repository diff lacked an explicit prompt-injection boundary"

echo "==> the review mode renders the verification instruction, not the adversarial one"
out="$(run_in_work env FINDER_REVIEW_DRY_RUN=1 ./scripts/finder-review.sh review copilot --uncommitted 2>/dev/null)"
grep -Fq 'finder: copilot-verification' <<<"$out" || fail "review mode resolved the wrong finder: $out"
grep -Fq 'Run a VERIFICATION-CHECKPOINT review' <<<"$out" || fail "review mode instruction missing"
grep -Fq 'Run an ADVERSARIAL review' <<<"$out" && fail "review mode rendered the adversarial instruction"

# The write-attempting stub is built OUTSIDE the guard below: the
# degraded-mode case further down uses it too, and that case runs exactly
# when the guard skips.
writer_bin="$tmp/writer-bin"
mkdir -p "$writer_bin"
cat >"$writer_bin/copilot" <<'EOF'
#!/usr/bin/env bash
printf 'tampered\n' >./TAMPERED.txt
echo "P1 src/app.txt:1 — a finding"
EOF
chmod +x "$writer_bin/copilot"

# The kernel-boundary cases below are meaningless — and actively wrong —
# where there is no kernel sandbox to assert. Without a discoverable bwrap
# the runner deliberately enters degraded mode, whose accepted residuals are
# precisely what the shared-ref and credential assertions would contradict;
# and as root the write is not denied by mode bits either, so sandbox_verify
# rejects instead and the first command substitution would abort the whole
# suite under `set -e`. Since these suites now run under `task verify`, that
# would fail the definition-of-done gate on supported no-bubblewrap hosts.
# The degraded-mode cases further down cover that environment and still run.
if (cd "$work" && . ./scripts/lib/readonly-sandbox.sh && sandbox_resolve_bwrap) >/dev/null 2>&1; then
    echo "==> a write from inside the pass is denied by the kernel"
    # /review requires the capability split to be installed and VERIFIED. It is
    # built around the CLI rather than asked of it: a bubblewrap sandbox over a
    # scratch git worktree, an isolated HOME, and the tree proven unchanged
    # afterwards. First defence — a write simply fails.
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
else
    echo "==> SKIPPED (no bubblewrap on this host): the kernel-boundary cases"
fi

echo "==> the verification catches a tree that changed, independently of the kernel"
# The two defences are separate on purpose: this one exercises the proof, by
# mutating the checkout from OUTSIDE the sandbox (where the kernel denial does
# not apply) and asserting the pass would be refused.
(
    cd "$work" || exit 1
    # shellcheck source=/dev/null
    . ./scripts/lib/readonly-sandbox.sh
    sandbox_create HEAD 1 >/dev/null || exit 1
    chmod u+w "$readonly_sandbox_dir"
    printf 'tampered\n' >"$readonly_sandbox_dir/TAMPERED.txt"
    if sandbox_verify 2>/dev/null; then
        sandbox_cleanup
        exit 1
    fi
    sandbox_cleanup
) || fail "the verification accepted a checkout that had been modified"

echo "==> no kernel sandbox degrades the pass and says so, rather than refusing"
# Maintainer decision: bubblewrap is the default and much the stronger
# boundary, but its absence FALLS BACK rather than refusing — with every
# non-bwrap protection still in force and the degradation disclosed, so a
# reviewer can see which boundary a pass ran under.
# `|| true` on the command substitution, deliberately. Running as ROOT, mode
# bits do not deny the write, so the stub succeeds and `sandbox_verify`
# correctly rejects the modified checkout — a nonzero exit. Under `set -e` the
# assignment itself then aborted the suite before any assertion ran, so the
# definition-of-done gate failed in every root-based container. Both outcomes
# are correct behaviour; what this case asserts is the DISCLOSURE, which is
# present either way.
out="$( (cd "$work" && PATH="$writer_bin:$PATH" READONLY_SANDBOX_BWRAP=/nonexistent/bwrap \
    ./scripts/finder-review.sh challenge copilot --uncommitted) 2>&1 || true)"
grep -Fq 'sandbox: degraded (no bubblewrap)' <<<"$out" ||
    fail "the degraded fallback did not disclose itself: $out"
# As root the write is not denied by mode bits at all; the boundary that then
# holds is the post-run tamper check, which is the other correct outcome.
# Accept either — what must never happen is the write landing AND the pass
# being accepted, which the next assertion and sandbox_verify cover.
grep -Eq 'Read-only file system|Permission denied|the scratch checkout changed during the pass|read-only checkout it ran against was modified' <<<"$out" ||
    fail "the degraded fallback neither denied the write nor rejected the tampered checkout: $out"
[ ! -e "$work/TAMPERED.txt" ] ||
    fail "the degraded fallback let a write reach the real worktree"

echo "==> a launcher symlinked into an npm package tree still executes"
# The documented `npm install -g @github/copilot` — and anything under NVM or
# a user prefix — puts a symlink in .../bin pointing at a script under a
# sibling .../lib/node_modules. Binding only the launcher directory left that
# package absent inside the sandbox, so the finder resolved and then failed to
# execute.
nvm_prefix="$tmp/nvm"
mkdir -p "$nvm_prefix/bin" "$nvm_prefix/lib/node_modules/@github/copilot" \
    "$nvm_prefix/lib/node_modules/helper"
cat >"$nvm_prefix/lib/node_modules/helper/message.txt" <<'EOF'
sibling-dependency
EOF
cat >"$nvm_prefix/lib/node_modules/@github/copilot/cli.sh" <<'EOF'
#!/usr/bin/env bash
# Resolves its own real path first, the way a launcher reached through a
# symlink does, then reads a sibling package as a dependency.
# Portable symlink resolution: macOS's system readlink has no -f, so this
# follows the chain one hop at a time — the same idiom scripts/lib/
# readonly-sandbox.sh's sandbox_realpath uses. With `readlink -f` here the
# stub resolved to the scratch root, printed an empty DEP= and failed the
# assertion below on every macOS run.
src="${BASH_SOURCE[0]}"
while [ -L "$src" ]; do
    link_dir="$(cd -P "$(dirname "$src")" && pwd)"
    src="$(readlink "$src")"
    case "$src" in
    /*) ;;
    *) src="$link_dir/$src" ;;
    esac
done
here="$(cd -P "$(dirname "$src")" && pwd)"
echo "DEP=$(cat "$here/../../helper/message.txt" 2>/dev/null)"
echo "P1 src/app.txt:1 — a finding"
EOF
chmod +x "$nvm_prefix/lib/node_modules/@github/copilot/cli.sh"
ln -s "../lib/node_modules/@github/copilot/cli.sh" "$nvm_prefix/bin/copilot"
out="$( (cd "$work" && PATH="$nvm_prefix/bin:$PATH" ./scripts/finder-review.sh challenge copilot --uncommitted) 2>&1)"
grep -Fq 'DEP=sibling-dependency' <<<"$out" ||
    fail "a launcher symlinked into an npm package tree could not execute in the sandbox: $out"

echo "==> a launcher whose shebang names an interpreter outside /usr still executes"
# An NVM-installed node lives under ~/.nvm/versions/.../bin/node, which is
# outside the base allowlist. Without the interpreter bind the sandbox has the
# script but not the interpreter it names.
if (cd "$work" && . ./scripts/lib/readonly-sandbox.sh && sandbox_resolve_bwrap) >/dev/null 2>&1; then
    interp_prefix="$tmp/custom-interp"
    mkdir -p "$interp_prefix/runtime/bin" "$interp_prefix/pkg/lib/node_modules/@github/copilot"
    cat >"$interp_prefix/runtime/bin/mynode" <<'EOF'
#!/usr/bin/env bash
# A stand-in for an NVM-installed node outside /usr. The real interpreter is
# irrelevant — what matters is that the sandbox binds this executable so the
# shebang resolves.
shift  # skip the script path
echo "INTERP_EXECUTED=yes"
echo "P1 src/app.txt:1 — a finding"
EOF
    chmod +x "$interp_prefix/runtime/bin/mynode"
    cat >"$interp_prefix/pkg/lib/node_modules/@github/copilot/cli.sh" <<EOF
#!$interp_prefix/runtime/bin/mynode
echo "should not reach here without the interpreter"
EOF
    chmod +x "$interp_prefix/pkg/lib/node_modules/@github/copilot/cli.sh"
    mkdir -p "$interp_prefix/pkg/bin"
    ln -s "../lib/node_modules/@github/copilot/cli.sh" "$interp_prefix/pkg/bin/copilot"
    out="$( (cd "$work" && PATH="$interp_prefix/pkg/bin:$PATH" \
        ./scripts/finder-review.sh challenge copilot --uncommitted) 2>&1)"
    grep -Fq 'INTERP_EXECUTED=yes' <<<"$out" ||
        fail "a launcher whose interpreter is outside /usr could not execute in the sandbox: $out"

    echo "==> the interpreter binding uses env resolution for #!/usr/bin/env shebangs"
    cat >"$interp_prefix/pkg/lib/node_modules/@github/copilot/cli.sh" <<'EOF'
#!/usr/bin/env mynode
echo "should not reach here without the interpreter"
EOF
    chmod +x "$interp_prefix/pkg/lib/node_modules/@github/copilot/cli.sh"
    out="$( (cd "$work" && PATH="$interp_prefix/runtime/bin:$interp_prefix/pkg/bin:$PATH" \
        ./scripts/finder-review.sh challenge copilot --uncommitted) 2>&1)"
    grep -Fq 'INTERP_EXECUTED=yes' <<<"$out" ||
        fail "a launcher with #!/usr/bin/env <interp> outside /usr could not execute in the sandbox: $out"

    echo "==> #!/usr/bin/env -S mynode --flag strips the -S option"
    cat >"$interp_prefix/pkg/lib/node_modules/@github/copilot/cli.sh" <<'EOF'
#!/usr/bin/env -S mynode --flag
echo "should not reach here without the interpreter"
EOF
    chmod +x "$interp_prefix/pkg/lib/node_modules/@github/copilot/cli.sh"
    out="$( (cd "$work" && PATH="$interp_prefix/runtime/bin:$interp_prefix/pkg/bin:$PATH" \
        ./scripts/finder-review.sh challenge copilot --uncommitted) 2>&1)"
    grep -Fq 'INTERP_EXECUTED=yes' <<<"$out" ||
        fail "a launcher with #!/usr/bin/env -S <interp> could not execute in the sandbox: $out"

    echo "==> #!/usr/bin/env -S VAR=x mynode strips the -S and assignment"
    cat >"$interp_prefix/pkg/lib/node_modules/@github/copilot/cli.sh" <<'EOF'
#!/usr/bin/env -S VAR=x mynode
echo "should not reach here without the interpreter"
EOF
    chmod +x "$interp_prefix/pkg/lib/node_modules/@github/copilot/cli.sh"
    out="$( (cd "$work" && PATH="$interp_prefix/runtime/bin:$interp_prefix/pkg/bin:$PATH" \
        ./scripts/finder-review.sh challenge copilot --uncommitted) 2>&1)"
    grep -Fq 'INTERP_EXECUTED=yes' <<<"$out" ||
        fail "a launcher with #!/usr/bin/env -S VAR=x <interp> could not execute in the sandbox: $out"
else
    echo "==> SKIPPED (no bubblewrap on this host): interpreter-binding cases"
fi

echo "==> a same-length rewrite of an untracked file fails the pass"
# The tamper check is what the whole boundary rests on, and comparing type,
# mode, size and path let a same-length rewrite with the mode restored through
# unnoticed. It compares content now.
printf 'aaaa\n' >"$work/src/probe.txt"
(
    cd "$work" || exit 1
    # shellcheck source=/dev/null
    . ./scripts/lib/readonly-sandbox.sh
    sandbox_create HEAD 1 >/dev/null || exit 1
    chmod u+w "$readonly_sandbox_dir" "$readonly_sandbox_dir/src/probe.txt"
    printf 'bbbb\n' >"$readonly_sandbox_dir/src/probe.txt"
    chmod a-w "$readonly_sandbox_dir/src/probe.txt" "$readonly_sandbox_dir"
    if sandbox_verify 2>/dev/null; then
        sandbox_cleanup
        exit 1
    fi
    sandbox_cleanup
) || {
    rm -f "$work/src/probe.txt"
    fail "a same-length rewrite passed the tamper check"
}
rm -f "$work/src/probe.txt"

echo "==> a snapshot that cannot hash fails closed rather than baselining nothing"
# The hashes ARE the proof. A baseline carrying none would accept every
# same-size, same-mode rewrite — the exact defect they were added to close —
# so a missing hasher or a failing pipeline aborts the snapshot.
(
    cd "$work" || exit 1
    # shellcheck source=/dev/null
    . ./scripts/lib/readonly-sandbox.sh
    sandbox_create HEAD 0 >/dev/null || exit 1
    # Hide both hashers from the snapshot's own lookup.
    hash_probe_bin="$(mktemp -d)"
    for stub in sha256sum shasum; do
        printf '#!/bin/sh\nexit 127\n' >"$hash_probe_bin/$stub"
        chmod +x "$hash_probe_bin/$stub"
    done
    if PATH="$hash_probe_bin:$PATH" sandbox_snapshot >/dev/null 2>&1; then
        rm -rf "$hash_probe_bin"
        sandbox_cleanup
        exit 1
    fi
    rm -rf "$hash_probe_bin"
    sandbox_cleanup
) || fail "a snapshot with no usable hasher was accepted as a baseline"

echo "==> the degraded path does not hand over the real home directory"
# There is no mount namespace to replace HOME with a tmpfs here, so the
# allowlist alone would have passed the real $HOME through — handing over
# ~/.aws, ~/.config/gh and the rest, which is what the sandboxed path exists
# to prevent.
homeprobe_bin="$tmp/homeprobe-bin"
mkdir -p "$homeprobe_bin"
cat >"$homeprobe_bin/copilot" <<'EOF'
#!/usr/bin/env bash
echo "HOME_IS=$HOME"
[ -e "$HOME/.config/gh" ] && echo "VISIBLE_GH"
echo "P1 src/app.txt:1 — a finding"
EOF
chmod +x "$homeprobe_bin/copilot"
out="$( (cd "$work" && PATH="$homeprobe_bin:$PATH" READONLY_SANDBOX_BWRAP=/nonexistent/bwrap \
    ./scripts/finder-review.sh challenge copilot --uncommitted) 2>&1)"
grep -Fq "HOME_IS=$HOME" <<<"$out" &&
    fail "the degraded path handed the real home directory to the finder: $out"
grep -q 'VISIBLE_GH' <<<"$out" &&
    fail "host credentials were reachable through HOME in the degraded path"

echo "==> the degraded path still fails a tampered tree"
(
    cd "$work" || exit 1
    # shellcheck source=/dev/null
    . ./scripts/lib/readonly-sandbox.sh
    READONLY_SANDBOX_BWRAP=/nonexistent/bwrap sandbox_create HEAD 1 >/dev/null || exit 1
    [ "$readonly_sandbox_degraded" = 1 ] || {
        sandbox_cleanup
        exit 1
    }
    chmod u+w "$readonly_sandbox_dir"
    printf 'tampered\n' >"$readonly_sandbox_dir/TAMPERED.txt"
    if sandbox_verify 2>/dev/null; then
        sandbox_cleanup
        exit 1
    fi
    sandbox_cleanup
) || fail "the degraded path accepted a checkout that had been modified"

echo "==> the scratch tree is the scope's own snapshot, not always HEAD"
# The finder is handed the diff, but it reads the tree it sits in — so that
# tree has to be the one the diff is about. --uncommitted must show the
# uncommitted content, and --commit <older> must show that commit.
scope_bin="$tmp/scope-bin"
mkdir -p "$scope_bin"
cat >"$scope_bin/copilot" <<'EOF'
#!/usr/bin/env bash
echo "SEEN=$(cat src/app.txt 2>/dev/null)"
echo "P1 src/app.txt:1 — a finding"
EOF
chmod +x "$scope_bin/copilot"
out="$( (cd "$work" && PATH="$scope_bin:$PATH" ./scripts/finder-review.sh challenge copilot --uncommitted) 2>&1)"
grep -Fq 'SEEN=changed' <<<"$out" ||
    fail "the scratch tree did not carry the uncommitted content the diff describes: $out"
base_sha="$(git -C "$work" rev-parse HEAD)"
# The base commit carries the copied runner and its libraries, so the prompt is
# larger than the default refusal bound; the bound is exercised on its own
# elsewhere and is not what this case is about.
out="$( (cd "$work" && PATH="$scope_bin:$PATH" FINDER_REVIEW_MAX_PROMPT_BYTES=2000000 \
    ./scripts/finder-review.sh challenge copilot --commit "$base_sha") 2>&1)"
grep -Fq 'SEEN=initial' <<<"$out" ||
    fail "the scratch tree for --commit did not carry that commit's content: $out"

echo "==> an untracked file in scope is present in the scratch tree"
printf 'brand new\n' >"$work/src/added.txt"
cat >"$scope_bin/copilot" <<'EOF'
#!/usr/bin/env bash
echo "UNTRACKED=$(cat src/added.txt 2>/dev/null)"
echo "P1 src/added.txt:1 — a finding"
EOF
out="$( (cd "$work" && PATH="$scope_bin:$PATH" ./scripts/finder-review.sh challenge copilot --uncommitted) 2>&1)"
rm -f "$work/src/added.txt"
grep -Fq 'UNTRACKED=brand new' <<<"$out" ||
    fail "an untracked file in scope was missing from the scratch tree: $out"

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
# Matched by SCANNING the arguments rather than by position: the review path
# also passes --no-ext-diff, and pinning --no-index to \$2 made this stub stop
# intercepting the moment a flag was added ahead of it — the case then passed
# by not simulating the failure at all.
if [ "\$1" = diff ] && grep -Fxq -- --no-index <<<"\$(printf '%s\n' "\$@")"; then
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

echo "==> an untracked symlink is copied as a LINK, never as its target's content"
# The credential-leak case. `cp -p` dereferences a symlink named on its command
# line and copies the TARGET's bytes, so an untracked link to ~/.config/gh/
# hosts.yml used to place that credential inside the otherwise isolated
# checkout — readable by the finder, over a network the design deliberately
# leaves open. `cp -P` copies the link itself, which is also what the reviewed
# scope actually contains.
canary_dir="$tmp/outside-the-scope"
mkdir -p "$canary_dir"
printf 'CREDENTIAL-CANARY-%s\n' "$$" >"$canary_dir/token.txt"
ln -s "$canary_dir/token.txt" "$work/linked-secret"
(
    cd "$work" || exit 1
    # shellcheck source=/dev/null
    . ./scripts/lib/readonly-sandbox.sh
    sandbox_create HEAD 1 >/dev/null || exit 1
    status=0
    # The invariant is that no DEREFERENCED COPY was made: the scratch entry
    # must still be a symlink pointing at the original path. Reading through
    # it from the host would of course still find the canary — the target has
    # not moved — but inside the sandbox that path is not bound, so the link
    # simply dangles. What used to leak was `cp -p` writing the target's bytes
    # into the checkout as a regular file, which no mount namespace can undo.
    [ -L "$readonly_sandbox_dir/linked-secret" ] || status=1
    [ "$(readlink "$readonly_sandbox_dir/linked-secret" 2>/dev/null)" = "$canary_dir/token.txt" ] || status=2
    sandbox_cleanup
    exit "$status"
) || fail "an untracked symlink was dereferenced, placing its target's content in the scratch checkout"
rm -f "$work/linked-secret"

echo "==> the prompt bound refuses a value too wide for shell arithmetic"
# A digit-only value past what `test -gt` can compare overflowed the
# comparison, which then evaluated FALSE — so the bound silently stopped being
# enforced and an oversized prompt failed later with E2BIG instead.
set +e
out="$(run_in_work env FINDER_REVIEW_MAX_PROMPT_BYTES=99999999999999999999 \
    FINDER_REVIEW_DRY_RUN=1 ./scripts/finder-review.sh challenge copilot --uncommitted 2>&1)"
status=$?
set -e
[ "$status" -eq 2 ] || fail "an implausibly wide prompt bound exited $status, not 2"
grep -Fq 'implausibly large' <<<"$out" ||
    fail "the oversized bound was not refused by name: $out"

echo "==> an untracked path beginning with a dash is copied, not read as an option"
# A repository-relative path may legitimately start with `-`, and both
# `dirname` and `cp` would take it for options — which, once the untracked
# loop was made to fail closed, refused every non-dry-run review over an
# otherwise valid tree.
: >"$work/-new"
(
    cd "$work" || exit 1
    # shellcheck source=/dev/null
    . ./scripts/lib/readonly-sandbox.sh
    sandbox_create HEAD 1 >/dev/null || exit 1
    status=0
    [ -f "$readonly_sandbox_dir/-new" ] || status=1
    sandbox_cleanup
    exit "$status"
) || fail "an untracked path beginning with a dash was not reproduced in the scratch checkout"
rm -f "$work/-new"

echo "==> a failing git ls-files during sandbox_create refuses the sandbox"
# The process substitution that formerly fed the untracked-file loop hid the
# producer's exit status: a failing git ls-files silently produced no paths,
# so sandbox_create returned success with untracked files missing.
printf 'should-be-copied\n' >"$work/src/present.txt"
lsfail_bin="$tmp/lsfail-bin"
mkdir -p "$lsfail_bin"
real_git="$(command -v git)"
cat >"$lsfail_bin/git" <<LSFAILEOF
#!/usr/bin/env bash
if [ "\${1:-}" = "ls-files" ]; then
    echo "fatal: simulated ls-files failure" >&2
    exit 128
fi
exec "$real_git" "\$@"
LSFAILEOF
chmod +x "$lsfail_bin/git"
(
    cd "$work" || exit 1
    # shellcheck source=/dev/null
    . ./scripts/lib/readonly-sandbox.sh
    if PATH="$lsfail_bin:$PATH" sandbox_create HEAD 1 >/dev/null 2>&1; then
        sandbox_cleanup
        exit 1
    fi
    sandbox_cleanup 2>/dev/null
) || fail "a failing git ls-files was accepted by sandbox_create"
rm -f "$work/src/present.txt"

echo "==> the launcher's directory is NOT bound, only the launcher itself"
# A launcher commonly sits in a personal ~/bin or a shared prefix beside
# unrelated private files. Binding dirname(launcher) handed every one of them
# to a general agent with open egress.
if (cd "$work" && . ./scripts/lib/readonly-sandbox.sh && sandbox_resolve_bwrap) >/dev/null 2>&1; then
    nosib_bin="$tmp/nosib-bin"
    mkdir -p "$nosib_bin"
    printf 'PRIVATE-SIBLING-CANARY\n' >"$nosib_bin/private-notes.txt"
    cat >"$nosib_bin/copilot" <<'EOF'
#!/usr/bin/env bash
here="$(dirname "$0")"
if [ -e "$here/private-notes.txt" ]; then echo "SIBLING_VISIBLE"; fi
echo "P1 src/app.txt:1 — a finding"
EOF
    chmod +x "$nosib_bin/copilot"
    out="$( (cd "$work" && PATH="$nosib_bin:$PATH" ./scripts/finder-review.sh challenge copilot --uncommitted) 2>&1)"
    grep -q 'SIBLING_VISIBLE' <<<"$out" &&
        fail "an unrelated file beside the launcher was readable inside the sandbox: $out"
else
    echo "==> SKIPPED (no bubblewrap on this host): launcher-sibling isolation"
fi

echo "==> an external diff driver cannot empty the scratch checkout's patch"
# `diff.external` is ordinary repo/user config and git honours it: a helper
# that exits 0 with no output yields an EMPTY patch, so the scratch tree keeps
# the pre-change content while the manifest says the file is covered — a clean
# result banked for work the finder never saw.
printf 'old-content\n' >"$work/tracked.txt"
git -C "$work" add tracked.txt
git -C "$work" commit -qm 'add tracked file'
printf 'new-content\n' >"$work/tracked.txt"
cat >"$tmp/empty-diff-driver.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$tmp/empty-diff-driver.sh"
git -C "$work" config diff.external "$tmp/empty-diff-driver.sh"
(
    cd "$work" || exit 1
    # shellcheck source=/dev/null
    . ./scripts/lib/readonly-sandbox.sh
    sandbox_create HEAD 1 >/dev/null || exit 1
    status=0
    grep -q 'new-content' "$readonly_sandbox_dir/tracked.txt" || status=1
    sandbox_cleanup
    exit "$status"
) || fail "an external diff driver emptied the patch and the scratch checkout kept the old content"
git -C "$work" config --unset diff.external
git -C "$work" checkout -- tracked.txt

echo "==> envelope mode writes a receipt-validated local-finder pass atomically"
mkdir -p "$work/ai/schemas"
cp -R "$repo/ai/schemas/." "$work/ai/schemas/"
cp "$repo/scripts/validate-result-schemas.mjs" "$work/scripts/"
cp "$repo/scripts/lib/json-schema-subset.mjs" "$work/scripts/lib/"
cp "$repo/.devflow.toml" "$work/"
git -C "$work" add -A
git -C "$work" commit -qm 'test: add envelope validation support'
envelope_base="$(git -C "$work" rev-parse HEAD)"
git -C "$work" update-ref refs/remotes/origin/main "$envelope_base"
git -C "$work" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
printf 'envelope change\n' >"$work/src/app.txt"
git -C "$work" add src/app.txt
git -C "$work" commit -qm 'test: envelope review target'
record="$tmp/finder-envelope-record"
mkdir -p "$record"
printf '%s\n' '{"run_id":"run-finder-envelope","initiated_by":"human"}' >"$record/run.json"
head_sha="$(git -C "$work" rev-parse HEAD)"
producer="finder-review.sh@$(git -C "$work" hash-object scripts/finder-review.sh)"
envelope_bin="$tmp/envelope-bin"
mkdir -p "$envelope_bin"
cat >"$envelope_bin/copilot" <<EOF
#!/usr/bin/env bash
case " \$* " in
*" --model gpt-5.6-sol "*) ;;
*) exit 8 ;;
esac
prompt="\${!#}"
grep -Fq '"attack_scenarios"' <<<"\$prompt" || exit 9
printf '%s\n' '{"stage":"challenge","round":1,"reviewed_head":"$head_sha","finder":"copilot-adversarial","slot":"copilot-adversarial","findings":[{"id":"challenge-r1-copilot-adversarial-1","path":"scripts/finder-review.sh","line":1,"class":"hardening","provenance":"original","fingerprint":"new","priority":"P2","recommended_disposition":"defer","evidence":"fixture prior finding"}],"counts":{"P0":0,"P1":0,"P2":1,"P3":0},"attack_scenarios":[{"id":"as-1","description":"attempted scope and sandbox escapes","outcome":"surfaced-finding","finding_id":"challenge-r1-copilot-adversarial-1"}]}'
EOF
chmod +x "$envelope_bin/copilot"
(
    cd "$work" || exit 1
    PATH="$envelope_bin:$PATH" ./scripts/finder-review.sh challenge copilot --envelope \
        --run-id run-finder-envelope --head "$head_sha" --stage challenge --round 1 \
        --slot copilot-adversarial --producer "$producer" --record-dir "$record" \
        --policy .devflow.toml --registry agent-registry.json \
        --model gpt-5.6-sol --tier apex --base origin/main >/dev/null
) || fail "valid local-finder envelope failed"
finder_pass="$record/passes/challenge-r1-copilot-adversarial.json"
[ -f "$finder_pass" ] || fail "local-finder pass was not published"
jq -e --arg producer "$producer" '.role == "challenger" and .producer.harness == $producer and
    .producer.model == "gpt-5.6-sol" and .producer.tier == "apex"' \
    "$finder_pass" >/dev/null || fail "local-finder envelope lost role or script-derived producer"
jq -e '[.receipts[] | select(.kind == "pass" and .file == "challenge-r1-copilot-adversarial")] | length == 1' \
    "$record/run.json" >/dev/null || fail "local-finder pass was published without its receipt commit point"

echo "==> envelope model validation preserves multi-hyphen registry slugs"
(
    cd "$work" || exit 1
    PATH="$envelope_bin:$PATH" FINDER_REVIEW_DRY_RUN=1 \
        ./scripts/finder-review.sh challenge copilot --envelope \
        --run-id run-finder-envelope --head "$head_sha" --stage challenge --round 2 \
        --slot copilot-adversarial --producer "$producer" --record-dir "$record" \
        --policy .devflow.toml --registry agent-registry.json \
        --model qwen-coder-plus --tier standard --base origin/main >/dev/null
) || fail "a valid multi-hyphen model slug was rejected"

echo "==> a fallback finder preserves the configured primary slot"
cat >"$envelope_bin/copilot" <<EOF
#!/usr/bin/env bash
printf '%s\n' '{"stage":"challenge","round":1,"reviewed_head":"$head_sha","finder":"copilot-adversarial","slot":"coderabbit-adversarial","substitutes_for":"coderabbit-adversarial","findings":[],"counts":{"P0":0,"P1":0,"P2":0,"P3":0},"attack_scenarios":[{"id":"as-fallback","description":"attempted fallback binding bypasses","outcome":"held","finding_id":null}]}'
EOF
chmod +x "$envelope_bin/copilot"
(
    cd "$work" || exit 1
    PATH="$envelope_bin:$PATH" ./scripts/finder-review.sh challenge copilot --envelope \
        --run-id run-finder-envelope --head "$head_sha" --stage challenge --round 1 \
        --slot coderabbit-adversarial --producer "$producer" --record-dir "$record" \
        --policy .devflow.toml --registry agent-registry.json \
        --model gpt-5.6-sol --tier apex --base origin/main >/dev/null
) || fail "valid local-finder fallback envelope failed"
fallback_pass="$record/passes/challenge-r1-coderabbit-adversarial.json"
jq -e '.payload.finder == "copilot-adversarial" and
    .payload.slot == "coderabbit-adversarial" and
    .payload.substitutes_for == "coderabbit-adversarial"' \
    "$fallback_pass" >/dev/null || fail "fallback pass lost its primary-slot substitution binding"

echo "==> multiple local-finder payload documents publish nothing"
cat >"$envelope_bin/copilot" <<EOF
#!/usr/bin/env bash
printf '%s\n' '{"stage":"challenge","round":99,"reviewed_head":"$head_sha","finder":"copilot-adversarial","slot":"copilot-adversarial","findings":[],"counts":{"P0":0,"P1":0,"P2":0,"P3":0},"attack_scenarios":[]}'
printf '%s\n' '{"stage":"challenge","round":2,"reviewed_head":"$head_sha","finder":"copilot-adversarial","slot":"copilot-adversarial","findings":[],"counts":{"P0":0,"P1":0,"P2":0,"P3":0},"attack_scenarios":[]}'
EOF
chmod +x "$envelope_bin/copilot"
if (
    cd "$work" || exit 1
    PATH="$envelope_bin:$PATH" ./scripts/finder-review.sh challenge copilot --envelope \
        --run-id run-finder-envelope --head "$head_sha" --stage challenge --round 2 \
        --slot copilot-adversarial --producer "$producer" --record-dir "$record" \
        --policy .devflow.toml --registry agent-registry.json \
        --model gpt-5.6-sol --tier apex --base origin/main >/dev/null 2>&1
); then
    fail "multiple local-finder payload documents were accepted"
fi
[ ! -e "$record/passes/challenge-r2-copilot-adversarial.json" ] ||
    fail "multiple local-finder payload documents published a pass"

echo "==> a local-finder run-id mismatch and malformed payload publish nothing"
bad_record="$tmp/finder-envelope-bad"
mkdir -p "$bad_record"
printf '%s\n' '{"run_id":"another-run","initiated_by":"human"}' >"$bad_record/run.json"
if (
    cd "$work" || exit 1
    PATH="$envelope_bin:$PATH" ./scripts/finder-review.sh challenge copilot --envelope \
        --run-id run-finder-envelope --head "$head_sha" --stage challenge --round 1 \
        --slot copilot-adversarial --producer "$producer" --record-dir "$bad_record" \
        --policy .devflow.toml --registry agent-registry.json \
        --model gpt-5.6-sol --tier apex --base origin/main >/dev/null 2>&1
); then
    fail "local-finder run-id mismatch was accepted"
fi
[ ! -e "$bad_record/passes/challenge-r1-copilot-adversarial.json" ] || fail "run-id mismatch published a pass"
cat >"$envelope_bin/copilot" <<'EOF'
#!/usr/bin/env bash
grep -Fq 'challenge-r1-copilot-adversarial-1' <<<"${!#}" || exit 9
printf '%s\n' '{"stage":"challenge"}'
EOF
chmod +x "$envelope_bin/copilot"
if (
    cd "$work" || exit 1
    PATH="$envelope_bin:$PATH" ./scripts/finder-review.sh challenge copilot --envelope \
        --run-id run-finder-envelope --head "$head_sha" --stage challenge --round 2 \
        --slot copilot-adversarial --producer "$producer" --record-dir "$record" \
        --policy .devflow.toml --registry agent-registry.json \
        --model gpt-5.6-sol --tier apex --base origin/main >/dev/null 2>&1
); then
    fail "malformed local-finder payload was accepted"
fi
[ ! -e "$record/passes/challenge-r2-copilot-adversarial.json" ] || fail "malformed local-finder payload published a pass"
set -- "$record"/.finder-payload.*
[ ! -e "$1" ] || fail "failed local-finder envelope stranded a raw payload in the record directory"

echo "==> the review path uses no GNU-only construct macOS lacks"
# Three of these shipped in this change and each one broke every non-dry-run
# pass on macOS while looking harmless in review: `find -printf`, `sort -z`,
# `xargs -r`, `readlink -f`. docs/conventions.md requires these scripts to stay
# portable to macOS bash 3.2, and scripts/test-skills.sh already bans the same
# family for its own recipe. This is the guard that stops them coming back —
# checked against the real files rather than a copy, so it covers the library
# whichever suite runs first.
for gnu_only_file in scripts/finder-review.sh scripts/lib/readonly-sandbox.sh \
    scripts/lib/review-scope.sh; do
    while IFS= read -r pattern; do
        # Skip prose: only flag a construct that is actually invoked, not one
        # named in a comment explaining why it is banned.
        if grep -nE "^[^#]*$pattern" "$repo/$gnu_only_file" >/dev/null 2>&1; then
            fail "$gnu_only_file uses the GNU-only construct '$pattern'; it is unavailable on macOS, which docs/conventions.md lists as supported"
        fi
    done <<'PATTERNS'
find .* -printf
sort -z
xargs .*-r[ 	]
readlink -f
PATTERNS
done

echo "finder review runner OK"
