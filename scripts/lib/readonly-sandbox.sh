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
#   1. a kernel sandbox, `bwrap`, is REQUIRED — not opportunistic. Without it
#      the only protection is the file mode on the scratch checkout, and that
#      stops nothing outside it: a linked worktree's `.git` is a POINTER into
#      the real repository, so `git update-ref` could alter or delete shared
#      refs while the scratch tree stayed byte-identical and the verification
#      below happily passed. The contract's answer to a boundary that cannot
#      be installed is to refuse, so that is what happens;
#   2. a scratch `git worktree add --detach` checkout, per run, in a temp dir,
#      with every path in it made unwritable;
#   3. the whole filesystem read-only inside the sandbox — the real `.git`
#      bound read-only EXPLICITLY as well, so the worktree pointer leads
#      somewhere unwritable rather than relying on the blanket bind alone;
#   4. HOME replaced by a tmpfs with only the finder's OWN credential path
#      bound back in read-only. A blanket read-only bind is not isolation: the
#      network stays open, `gh` falls back to ~/.config/gh/hosts.yml, and
#      ~/.aws and npm credentials are all readable, so a finder with shell
#      capability could make authenticated remote writes or exfiltrate;
#   5. the environment stripped of write credentials and of git's credential
#      helpers, so what does remain has nothing to authenticate with;
#   6. and afterwards the scratch tree is PROVEN unchanged — `git status`
#      clean, no untracked files, same file list — or the pass fails as
#      tampered.
#
# (6) is what makes this "verified" rather than "configured": whatever the CLI
# was allowed to do, a pass is only accepted if the tree it ran against is
# byte-identical to the one it was given. Network egress is deliberately NOT
# severed — the CLI has to reach its model — so this bounds writes and
# credential access, not the model call itself; a finder is given the diff
# either way, and that limit is stated rather than papered over.

# sandbox_run WORKDIR-VAR-NAME — create the scratch checkout, print its path.
# The caller runs its CLI with `sandbox_exec` and then calls `sandbox_verify`.
readonly_sandbox_dir=
readonly_sandbox_manifest=
readonly_sandbox_bwrap=
# The one credential path the finder is allowed to read, bound into an
# otherwise empty HOME. Set by the caller before sandbox_create.
readonly_sandbox_credential_dir=
# Extra paths to bind read-only. /tmp is replaced by a fresh tmpfs inside the
# sandbox, so anything the run genuinely needs from there — the finder's own
# binary, most obviously — has to be named or it simply disappears.
readonly_sandbox_extra_ro=()

# bwrap from PATH, else the copy Codex bundles — a host without either cannot
# host a confidence pass, and saying so is the contract's own instruction.
sandbox_resolve_bwrap() {
    # An explicit path wins, so a caller can pin a known-good build — and so a
    # test can point it at nothing and prove the refusal below is real.
    if [ -n "${READONLY_SANDBOX_BWRAP:-}" ]; then
        [ -x "$READONLY_SANDBOX_BWRAP" ] || return 1
        readonly_sandbox_bwrap="$READONLY_SANDBOX_BWRAP"
        return 0
    fi
    if command -v bwrap >/dev/null 2>&1; then
        readonly_sandbox_bwrap="$(command -v bwrap)"
        return 0
    fi
    local candidate
    for candidate in \
        /usr/lib/node_modules/@openai/codex/node_modules/@openai/codex-linux-x64/vendor/*/codex-resources/bwrap \
        "$HOME"/.vscode-server/extensions/openai.chatgpt-*/bin/*/codex-resources/bwrap \
        /opt/homebrew/bin/bwrap; do
        if [ -x "$candidate" ]; then
            readonly_sandbox_bwrap="$candidate"
            return 0
        fi
    done
    return 1
}

sandbox_create() {
    local head
    sandbox_resolve_bwrap || {
        echo "readonly-sandbox: no bubblewrap (bwrap) on PATH or in Codex's bundled resources." >&2
        echo "readonly-sandbox: a confidence pass may not run on file-mode protection alone —" >&2
        echo "readonly-sandbox: a linked worktree's .git points at the real repository, so" >&2
        echo "readonly-sandbox: git could still alter shared refs while the scratch tree looked" >&2
        echo "readonly-sandbox: untouched. Install bubblewrap, or run this finder on the PR side." >&2
        return 1
    }
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
    # From here on the worktree is REGISTERED, so every failure path has to
    # unregister it. The caller installs its cleanup trap only after this
    # function returns, so a failure in between would otherwise leave a linked
    # worktree behind permanently — consuming disk and tripping later worktree
    # operations.
    sandbox_create_failed() {
        sandbox_cleanup
        return 1
    }
    # `a-w` covers the owner too, which is the point: this process runs as the
    # same user the CLI will.
    chmod -R a-w "$readonly_sandbox_dir" 2>/dev/null || true
    # The snapshot is taken AFTER the chmod, so the modes it records are the
    # ones the pass will see. Taken before, every single run would compare
    # unequal on mode alone and the tamper check would fire on clean passes —
    # which is a check that proves nothing.
    readonly_sandbox_manifest="$(mktemp)" || sandbox_create_failed || return 1
    sandbox_snapshot >"$readonly_sandbox_manifest" || sandbox_create_failed || return 1
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
    local -a wrapper
    local real_git_dir home_dir
    # The MAIN repository's git dir, which the scratch worktree's `.git` file
    # points at. Bound read-only by name as well as by the blanket bind: this
    # is the specific path that turned "the tree is unwritable" into "shared
    # refs are still reachable", so it is named rather than left implicit.
    real_git_dir="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || real_git_dir=
    home_dir="${HOME:-/nonexistent}"
    # Namespaces the model call does not need are unshared: the finder has no
    # business seeing host processes, signalling same-user processes, reaching
    # host IPC endpoints, or holding the controlling terminal (--new-session
    # closes the TIOCSTI input-injection route). The NETWORK namespace is
    # deliberately kept — the CLI must reach its model, which is the whole
    # point of dispatching it — so this bounds writes, credentials, processes
    # and IPC, not the model call. That residual is stated here, in the header
    # above, and in docs/guides/codex-review.md rather than left implicit.
    wrapper=("$readonly_sandbox_bwrap" --ro-bind / / --dev /dev --proc /proc --tmpfs /tmp
        --unshare-pid --unshare-ipc --unshare-uts --new-session)
    [ -z "$real_git_dir" ] || wrapper+=(--ro-bind "$real_git_dir" "$real_git_dir")
    # HOME is replaced wholesale, then exactly one credential path is bound
    # back. Everything else a home directory holds — ~/.config/gh, ~/.aws, npm
    # and the rest — is simply not there.
    wrapper+=(--tmpfs "$home_dir")
    if [ -n "$readonly_sandbox_credential_dir" ] && [ -e "$readonly_sandbox_credential_dir" ]; then
        wrapper+=(--ro-bind "$readonly_sandbox_credential_dir" "$readonly_sandbox_credential_dir")
    fi
    local extra
    for extra in "${readonly_sandbox_extra_ro[@]+"${readonly_sandbox_extra_ro[@]}"}"; do
        [ -e "$extra" ] || continue
        wrapper+=(--ro-bind "$extra" "$extra")
    done
    wrapper+=(--ro-bind "$readonly_sandbox_dir" "$readonly_sandbox_dir"
        --chdir "$readonly_sandbox_dir" --die-with-parent)
    (
        cd "$readonly_sandbox_dir" || exit 1
        # Credentials a write would need, and the helpers that supply them.
        # GIT_CONFIG_* are pointed at /dev/null rather than unset: unsetting
        # leaves the user's real ~/.gitconfig, credential helper included.
        env -u GH_TOKEN -u GITHUB_TOKEN -u GH_ENTERPRISE_TOKEN \
            -u GITHUB_ENTERPRISE_TOKEN -u GH_CONFIG_DIR \
            -u GIT_ASKPASS -u SSH_ASKPASS -u SSH_AUTH_SOCK \
            -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN \
            -u NPM_TOKEN -u NODE_AUTH_TOKEN \
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
