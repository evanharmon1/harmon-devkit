#!/usr/bin/env bash
# readonly-sandbox.sh — run a third-party review CLI where it cannot write.
#
# Sourced, never executed.
#
# `/review`'s dispatch contract requires a confidence pass to run with shell,
# git, gh, network write and external credentials denied, and says that where
# that split "cannot be installed and verified, refuse the dispatch". A
# third-party general-agent CLI does not let us install it: its capability
# model is its own, its configuration is the operator's, and an earlier
# revision of this repo tried to stand in for that with a comment and then with
# an environment attestation. Neither is verification — a drifted config
# crosses the boundary and nothing notices.
#
# So the boundary is built OUTSIDE the CLI, where it does not depend on the
# vendor's cooperation at all:
#
#   1. a scratch `git worktree add --detach` checkout, per run, in a temp dir;
#   2. every path in it made unwritable (`chmod -R a-w`);
#   3. the environment stripped of write credentials and of git's credential
#      helpers, so a network write has nothing to authenticate with;
#   4. `bwrap --ro-bind` over the whole filesystem where bubblewrap exists, so
#      the denial is the kernel's rather than the file mode's;
#   5. and afterwards the scratch tree is PROVEN unchanged — `git status`
#      clean, no untracked files, same file list — or the pass fails as
#      tampered.
#
# (5) is what makes this "verified" rather than "configured": whatever the CLI
# was allowed to do, a pass is only accepted if the tree it ran against is
# byte-identical to the one it was given. Network egress is deliberately NOT
# severed — the CLI has to reach its model — so this bounds writes to the
# checkout and to git, not exfiltration; a finder is given the diff either way,
# and that limit is stated rather than papered over.

# sandbox_run WORKDIR-VAR-NAME — create the scratch checkout, print its path.
# The caller runs its CLI with `sandbox_exec` and then calls `sandbox_verify`.
readonly_sandbox_dir=
readonly_sandbox_manifest=

sandbox_create() {
    local head
    head="$(git rev-parse HEAD 2>/dev/null)" || {
        echo "readonly-sandbox: cannot resolve HEAD to build a scratch checkout" >&2
        return 1
    }
    readonly_sandbox_dir="$(mktemp -d -t finder-readonly-XXXXXX)" || return 1
    # The directory has to be EMPTY for `git worktree add`, and mktemp made it.
    rmdir "$readonly_sandbox_dir" || return 1
    git worktree add --detach --quiet "$readonly_sandbox_dir" "$head" || {
        echo "readonly-sandbox: could not create the scratch checkout" >&2
        return 1
    }
    # `a-w` covers the owner too, which is the point: this process runs as the
    # same user the CLI will.
    chmod -R a-w "$readonly_sandbox_dir" 2>/dev/null || true
    # The snapshot is taken AFTER the chmod, so the modes it records are the
    # ones the pass will see. Taken before, every single run would compare
    # unequal on mode alone and the tamper check would fire on clean passes —
    # which is a check that proves nothing.
    readonly_sandbox_manifest="$(mktemp)" || return 1
    sandbox_snapshot >"$readonly_sandbox_manifest" || return 1
    printf '%s' "$readonly_sandbox_dir"
}

# Every path under the scratch tree with its size and mode. Compared before
# and after: a rewritten file changes size or mode in the overwhelming
# majority of cases, and `git status` below catches content changes that keep
# both. `.git` is excluded because it is a FILE in a linked worktree (a
# pointer at the main repo's admin dir), and git touches nothing else here.
sandbox_snapshot() {
    find "$readonly_sandbox_dir" -mindepth 1 -not -path "$readonly_sandbox_dir/.git" \
        -printf '%y %m %s %P\n' 2>/dev/null | LC_ALL=C sort
}

# sandbox_exec CMD... — run a command with the scratch tree as its working
# directory and no write credentials in its environment.
sandbox_exec() {
    local -a wrapper=()
    if command -v bwrap >/dev/null 2>&1; then
        # The kernel's denial rather than the file mode's. Network is left
        # alone deliberately (the CLI must reach its model); /tmp is a fresh
        # tmpfs so a CLI that insists on scratch space has some, and nothing
        # it writes there survives or reaches the checkout.
        wrapper=(bwrap --ro-bind / / --dev /dev --proc /proc --tmpfs /tmp
            --ro-bind "$readonly_sandbox_dir" "$readonly_sandbox_dir"
            --chdir "$readonly_sandbox_dir" --die-with-parent)
    fi
    (
        cd "$readonly_sandbox_dir" || exit 1
        # Credentials a write would need, and the helpers that supply them.
        # GIT_CONFIG_* are pointed at /dev/null rather than unset: unsetting
        # leaves the user's real ~/.gitconfig, credential helper included.
        env -u GH_TOKEN -u GITHUB_TOKEN -u GH_ENTERPRISE_TOKEN \
            -u GITHUB_ENTERPRISE_TOKEN -u GH_CONFIG_DIR \
            -u GIT_ASKPASS -u SSH_ASKPASS -u SSH_AUTH_SOCK \
            -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN \
            GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
            GIT_TERMINAL_PROMPT=0 \
            "${wrapper[@]}" "$@"
    )
}

# Proves the scratch tree is exactly as it was handed over. Returns non-zero
# with a reason on stderr otherwise — the caller must fail the pass, never
# report its findings.
sandbox_verify() {
    local after status=0
    after="$(mktemp)" || return 1
    sandbox_snapshot >"$after" || status=1
    if ! diff -q "$readonly_sandbox_manifest" "$after" >/dev/null 2>&1; then
        echo "readonly-sandbox: the scratch checkout changed during the pass" >&2
        diff "$readonly_sandbox_manifest" "$after" >&2 || true
        status=1
    fi
    rm -f "$after"
    # --no-optional-locks so the check itself cannot write an index into a
    # tree it is asserting is unchanged.
    if [ -n "$(git --no-optional-locks -C "$readonly_sandbox_dir" status --porcelain --untracked-files=all 2>/dev/null)" ]; then
        echo "readonly-sandbox: the scratch checkout is dirty after the pass" >&2
        status=1
    fi
    return "$status"
}

sandbox_cleanup() {
    [ -n "$readonly_sandbox_dir" ] || return 0
    chmod -R u+w "$readonly_sandbox_dir" 2>/dev/null || true
    git worktree remove --force "$readonly_sandbox_dir" >/dev/null 2>&1 ||
        rm -rf "$readonly_sandbox_dir"
    rm -f "$readonly_sandbox_manifest"
    readonly_sandbox_dir=
    readonly_sandbox_manifest=
}
