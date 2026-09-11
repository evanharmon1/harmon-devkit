#!/usr/bin/env bash
# readonly-sandbox.sh — add layered write protections around a third-party
# review CLI.
#
# Sourced, never executed.
#
# This optional boundary is built outside the CLI, where it does not depend on
# the vendor's cooperation:
#
#   1. a kernel sandbox, `bwrap`, when available. Without it the pass continues
#      with the remaining protections and reports the degraded boundary;
#   2. a scratch `git worktree add --detach` checkout, per run, in a temp dir,
#      with every path in it made unwritable;
#   3. with `bwrap`, the whole filesystem read-only inside the sandbox — the real `.git`
#      bound read-only EXPLICITLY as well, so the worktree pointer leads
#      somewhere unwritable rather than relying on the blanket bind alone;
#   4. HOME replaced by a tmpfs with only the finder's OWN credential path
#      bound back in read-only. A blanket read-only bind is not isolation: the
#      network stays open, `gh` falls back to ~/.config/gh/hosts.yml, and
#      ~/.aws and npm credentials are all readable, so a finder with shell
#      capability could make authenticated remote writes or exfiltrate;
#   5. the environment stripped of write credentials and of git's credential
#      helpers, so what does remain has nothing to authenticate with;
#   6. and afterwards the scratch tree is PROVEN unchanged — the same file
#      list, modes, sizes, symlink targets and CONTENT HASHES, and the same
#      `git status` — or the pass fails as tampered. It is the same STATE, not an empty one: a scope that includes
#      uncommitted work makes the tree legitimately dirty, so what must not
#      change is the dirtiness rather than its absence.
#
# (6) is what makes this "verified" rather than "configured": whatever the CLI
# was allowed to do, a pass is only accepted if the tree it ran against hashes
# the same as the one it was given — content, not just its shape. Network egress is deliberately NOT
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

# Symlinks to RECREATE inside the sandbox, as "target|linkpath" pairs. A
# `--ro-bind` of a symlink binds what it points at, at the link's path — so the
# link becomes a regular file inside, and a launcher that resolves its own real
# path (`readlink -f "$BASH_SOURCE"`, which is how an npm bin shim finds its
# package) computes the wrong directory and fails to load its own siblings.
# `--symlink` reproduces the link itself, which keeps that resolution honest
# without binding the directory the link happens to sit in.
readonly_sandbox_symlinks=()

# Resolve bwrap from PATH, else the copy Codex bundles. A lookup failure is
# reported to the caller, which decides whether to refuse or use its degraded
# fallback; it does not by itself mean a confidence pass cannot run.
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

# `readlink -f` is GNU-only — macOS's system readlink has no -f — so this
# resolves a path to its real location the portable way: follow the link chain
# one hop at a time with bare `readlink`, then canonicalise the directory with
# `cd`/`pwd -P`. The hop limit stops a symlink cycle from spinning forever.
sandbox_realpath() {
    local path="$1" dir link hops=0
    while [ -L "$path" ] && [ "$hops" -lt 40 ]; do
        dir="$(cd -P "$(dirname "$path")" 2>/dev/null && pwd)" || break
        link="$(readlink "$path")" || break
        case "$link" in
        /*) path="$link" ;;
        *) path="$dir/$link" ;;
        esac
        hops=$((hops + 1))
    done
    dir="$(cd -P "$(dirname "$path")" 2>/dev/null && pwd)" || {
        printf '%s' "$path"
        return 0
    }
    printf '%s/%s' "$dir" "$(basename "$path")"
}

# The hasher, as a COMMAND STRING rather than a shell function: the hashing
# below runs through `xargs`, which execs a command and cannot call a function
# — an earlier revision did exactly that, so every hash silently produced
# nothing and the content check it was supposed to add never ran at all.
# The stat flavour, resolved once. GNU coreutils and BSD/macOS `stat` take
# incompatible flags, and `find -printf` — which an earlier revision used to
# build this listing in one call — does not exist on BSD at all. That made
# every non-dry-run local finder pass fail on macOS while creating this
# baseline, against docs/conventions.md's requirement that shell here stays
# portable to macOS bash 3.2. Neither flavour follows a symlink by default,
# which is what this listing wants: the link's own mode, not its target's.
sandbox_stat_cmd() {
    if stat -c '%f' . >/dev/null 2>&1; then
        printf 'gnu'
    elif stat -f '%p' . >/dev/null 2>&1; then
        printf 'bsd'
    else
        return 1
    fi
}

# One listing line per path: type, mode, size, path relative to the scratch
# root, and the symlink target (empty for everything else, so a retarget of
# the same length is still caught).
sandbox_stat_line() {
    local flavour path rel type mode size target
    flavour="$1"
    path="$2"
    rel="${path#"$readonly_sandbox_dir"/}"
    if [ -L "$path" ]; then
        type=l
        target="$(readlink "$path")" || return 1
    elif [ -d "$path" ]; then
        type=d
        target=
    elif [ -f "$path" ]; then
        type=f
        target=
    else
        type=o
        target=
    fi
    if [ "$flavour" = gnu ]; then
        mode="$(stat -c '%a' "$path")" || return 1
        size="$(stat -c '%s' "$path")" || return 1
    else
        mode="$(stat -f '%Lp' "$path")" || return 1
        size="$(stat -f '%z' "$path")" || return 1
    fi
    printf '%s %s %s %s %s\n' "$type" "$mode" "$size" "$rel" "$target"
}

sandbox_hash_cmd() {
    if command -v sha256sum >/dev/null 2>&1; then
        printf 'sha256sum'
    elif command -v shasum >/dev/null 2>&1; then
        printf 'shasum -a 256'
    else
        return 1
    fi
}

# Every path under the scratch tree with its type, mode, size, symlink target
# and CONTENT HASH, plus git's own view. Compared before and after: this is the
# proof the whole boundary rests on, so it FAILS CLOSED — a hasher that is
# missing, a hash pipeline that errors, or an empty hash list where regular
# files exist all abort the snapshot rather than returning a baseline with
# nothing in it to compare. A baseline carrying zero hashes would accept every
# same-size, same-mode rewrite, which is the exact defect the hashes were added
# to close.
#
# `.git` is excluded because it is a FILE in a linked worktree (a pointer at
# the main repo's admin dir), and git touches nothing else here.
sandbox_snapshot() {
    local -a hasher
    local listing files hashes stat_flavour path
    stat_flavour="$(sandbox_stat_cmd)" || {
        echo "readonly-sandbox: no usable stat to describe the scratch tree with" >&2
        return 1
    }
    # shellcheck disable=SC2206 # deliberate word-splitting: a command plus its
    # flags, not one argument.
    hasher=($(sandbox_hash_cmd)) || {
        echo "readonly-sandbox: no sha256sum or shasum to hash the scratch tree with" >&2
        return 1
    }

    listing="$(mktemp)" || return 1
    files="$(mktemp)" || {
        rm -f "$listing"
        return 1
    }
    hashes="$(mktemp)" || {
        rm -f "$listing" "$files"
        return 1
    }
    # shellcheck disable=SC2064 # expand the paths now, not at trap time.
    trap "rm -f '$listing' '$files' '$hashes'" RETURN

    while IFS= read -r -d '' path; do
        sandbox_stat_line "$stat_flavour" "$path" >>"$listing" || {
            echo "readonly-sandbox: could not describe $path" >&2
            return 1
        }
    done < <(find "$readonly_sandbox_dir" -mindepth 1 -not -path "$readonly_sandbox_dir/.git" -print0) || {
        echo "readonly-sandbox: could not list the scratch tree" >&2
        return 1
    }
    find "$readonly_sandbox_dir" -mindepth 1 -not -path "$readonly_sandbox_dir/.git" \
        -type f -print0 >"$files" || {
        echo "readonly-sandbox: could not enumerate the scratch tree's files" >&2
        return 1
    }
    if [ -s "$files" ]; then
        # No `sort -z` here: BSD sort has no -z, and it bought nothing — the
        # hash lines are sorted below, which is where the determinism the
        # baseline needs actually comes from.
        # No `-r`: BSD xargs does not have it, and this repo bans it outright
        # (scripts/test-skills.sh names `xargs -r`, `cp --parents` and `cp -t`
        # as GNU-only because the shipped scripts support macOS bash 3.2). The
        # `[ -s "$files" ]` guard above is what actually prevents an empty
        # invocation, so `-r` was buying nothing and costing every macOS run:
        # the hash step failed and sandbox_create refused before the finder was
        # ever invoked. Same class as the `find -printf` and `sort -z` bugs
        # already removed from this function.
        xargs -0 "${hasher[@]}" <"$files" >"$hashes" || {
            echo "readonly-sandbox: could not hash the scratch tree's contents" >&2
            return 1
        }
        [ -s "$hashes" ] || {
            echo "readonly-sandbox: the scratch tree has files but hashed to nothing" >&2
            return 1
        }
    fi

    LC_ALL=C sort <"$listing" || return 1
    printf 'content\n'
    LC_ALL=C sort <"$hashes" || return 1
    # git's own view, folded into the same baseline rather than asserted empty:
    # a scope that includes uncommitted work makes the scratch tree
    # legitimately dirty, so what must not change is the dirtiness, not its
    # absence. --no-optional-locks so the check cannot write an index into a
    # tree it is asserting is unchanged.
    printf 'git-status\n'
    git --no-optional-locks -C "$readonly_sandbox_dir" status --porcelain \
        --untracked-files=all 2>/dev/null | LC_ALL=C sort
}

# sandbox_create COMMITTISH INCLUDE_WORKTREE
# Builds the scratch checkout at the snapshot the resolved scope describes.
sandbox_create() {
    local head include_worktree patch
    head="$(git rev-parse --verify --quiet "${1:-HEAD}^{commit}" 2>/dev/null)" || head=
    include_worktree="${2:-0}"
    [ -n "$head" ] || {
        echo "readonly-sandbox: cannot resolve ${1:-HEAD} to build a scratch checkout" >&2
        return 1
    }
    # Bubblewrap is the default and by far the stronger boundary, but its
    # absence DEGRADES the pass rather than refusing it (maintainer decision,
    # superseding the earlier refuse-without-it rule). Every non-bwrap
    # protection still applies — the scope-accurate scratch tree with its write
    # bits removed, the real .git left unwritable, the `env -i` allowlist, the
    # stripped credentials and the post-run tamper check — and the caller
    # DISCLOSES the degradation so a reviewer can see which boundary a pass ran
    # under. The residual it accepts is stated plainly: without the kernel
    # sandbox a linked worktree's .git still points at the real repository, so
    # `git update-ref` could alter shared refs while the scratch tree itself
    # looked untouched.
    readonly_sandbox_degraded=0
    sandbox_resolve_bwrap || readonly_sandbox_degraded=1
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
    # The working tree's own changes, where the resolved scope includes them.
    # Applied BEFORE the read-only pass below, so what the finder can look at
    # matches the diff it was given.
    if [ "$include_worktree" = 1 ]; then
        patch="$(mktemp)" || sandbox_create_failed || return 1
        # Fail closed. `|| true` here turned a transient git failure into "no
        # patch", so a scope containing uncommitted work got a committed-only
        # checkout while the prompt and manifest claimed otherwise — the
        # finder would then be reading a tree that contradicts its own input.
        # `--no-ext-diff` is load-bearing, not tidiness. `diff.external` is
        # ordinary repository or user configuration, and git honours it here:
        # a helper that exits 0 without output yields an EMPTY patch, so the
        # scratch checkout keeps the pre-change content while the manifest
        # above the prompt says the file is covered — a finder then reviews the
        # old tree and its clean result is banked for work it never saw. Every
        # diff this review path takes passes it, for the same reason.
        git diff --no-ext-diff --binary HEAD >"$patch" || {
            rm -f "$patch"
            echo "readonly-sandbox: could not collect the working-tree changes for the scratch checkout" >&2
            sandbox_create_failed
            return 1
        }
        if [ -s "$patch" ]; then
            git -C "$readonly_sandbox_dir" apply --binary --whitespace=nowarn "$patch" 2>/dev/null || {
                rm -f "$patch"
                echo "readonly-sandbox: could not reproduce the working-tree changes in the scratch checkout" >&2
                sandbox_create_failed
                return 1
            }
        fi
        rm -f "$patch"
        # Untracked files are part of the scope the manifest claims, so they
        # are part of the tree the finder may read — which is exactly why this
        # loop FAILS CLOSED. An entry that cannot be reproduced used to be
        # skipped silently, leaving the manifest claiming coverage the scratch
        # tree did not have.
        #
        # `cp -P` is the security-relevant flag, not a style choice: `cp -p`
        # DEREFERENCES a symlink named on its command line and copies the
        # target's CONTENT. An untracked link to a readable credential — say
        # ~/.config/gh/hosts.yml — therefore landed inside the otherwise
        # isolated checkout as a regular file, where the finder could read it
        # and send it out over the deliberately-open network, defeating the
        # tmpfs HOME the rest of this boundary rests on. `-P` copies the link
        # itself, which is also what the scope actually contains.
        while IFS= read -r -d '' untracked; do
            [ -n "$untracked" ] || continue
            # Special files are refused rather than copied: a FIFO blocks the
            # copy forever waiting for a writer, and a device or socket is not
            # reviewable content in any case.
            if [ ! -L "./$untracked" ] && [ ! -f "./$untracked" ]; then
                echo "readonly-sandbox: untracked path is not a regular file or symlink, refusing the scope: $untracked" >&2
                sandbox_create_failed
                return 1
            fi
            # `./` prefix, not decoration: a repository-relative path may
            # legitimately begin with `-`, and both `dirname` and `cp` would
            # then read it as options — an untracked file named `-new` made
            # `dirname` report an invalid option and refused every non-dry-run
            # review outright, which is a valid tree this pass must handle.
            mkdir -p "$readonly_sandbox_dir/$(dirname "./$untracked")" || {
                echo "readonly-sandbox: could not create the scratch directory for $untracked" >&2
                sandbox_create_failed
                return 1
            }
            cp -Pp "./$untracked" "$readonly_sandbox_dir/./$untracked" || {
                echo "readonly-sandbox: could not reproduce the untracked path $untracked in the scratch checkout" >&2
                sandbox_create_failed
                return 1
            }
        done < <(git ls-files -z --others --exclude-standard)
    fi
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

# The filesystem the pass may see, as an ALLOWLIST. `--ro-bind / /` plus a
# list of secrets to unset was subtract-known-secrets, not deny-by-default:
# anything outside $HOME (/run/secrets, a mounted token, an agent socket) or
# any variable not on the list stayed readable, and with egress open a
# general agent processing an attacker-controlled diff could use it. Only
# these paths are bound, each read-only, and only if they exist.
# NOTE on /opt: deliberately NOT here. It is a conventional home for
# third-party application state — /opt/homebrew is an entire package prefix —
# so binding the tree wholesale contradicts the allowlist principle above,
# which is to bind what a pass needs rather than what a host happens to have.
# The finder's own binary directory, its launcher's real target directory and
# the nearest node_modules ancestor are bound individually below, so a tool
# installed under /opt still resolves; a Homebrew-installed finder whose
# runtime libraries live elsewhere under the prefix is served by naming it
# with FINDER_REVIEW_SANDBOX_EXTRA_RO, which is the operator deciding
# deliberately.
readonly_sandbox_base_paths=(
    /usr /bin /sbin /lib /lib32 /lib64 /libx32
    /etc/ssl /etc/pki /etc/ca-certificates /etc/ca-certificates.conf
    /etc/resolv.conf /etc/hosts /etc/nsswitch.conf /etc/localtime
    /etc/passwd /etc/group /etc/alternatives
)

# The environment the pass may see, as an allowlist over `env -i`. Everything
# else — every token, every helper, every socket path — is simply not passed.
# A tool that needs one of its own variables gets it through
# FINDER_REVIEW_SANDBOX_ENV, which is the operator naming it deliberately.
readonly_sandbox_env_allow=(PATH HOME USER LOGNAME TERM LANG TMPDIR)

# sandbox_exec CMD... — run a command with the scratch tree as its working
# directory and no write credentials in its environment.
sandbox_exec() {
    local -a wrapper
    local real_git_dir home_dir path extra name
    # The MAIN repository's git dir, which the scratch worktree's `.git` file
    # points at. Bound read-only by name: this is the specific path that turned
    # "the tree is unwritable" into "shared refs are still reachable".
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
    if [ "${readonly_sandbox_degraded:-0}" = 1 ]; then
        # No kernel sandbox. Everything else still applies: the tree is
        # read-only, the environment is an allowlist, and the tamper check
        # still runs. The caller discloses this.
        #
        # HOME is the one thing the allowlist alone got wrong here. With
        # bubblewrap the real home is replaced by a tmpfs, but there is no
        # mount to do that in this path — and passing the real $HOME through
        # would hand over ~/.aws, ~/.config/gh and the rest, which is exactly
        # what the sandboxed path exists to prevent. So HOME points at an
        # empty per-run directory, with the finder's own credential path
        # linked in and nothing else. It is not a mount namespace and does not
        # pretend to be: a determined process can still name an absolute path.
        # What it removes is the ambient one every tool reaches for first.
        local degraded_home
        degraded_home="$readonly_sandbox_dir.home"
        mkdir -p "$degraded_home" 2>/dev/null || true
        if [ -n "$readonly_sandbox_credential_dir" ] && [ -e "$readonly_sandbox_credential_dir" ]; then
            ln -sfn "$readonly_sandbox_credential_dir" \
                "$degraded_home/$(basename "$readonly_sandbox_credential_dir")" 2>/dev/null || true
        fi
        (
            cd "$readonly_sandbox_dir" || exit 1
            HOME="$degraded_home" sandbox_clean_env "$@"
        )
        return $?
    fi
    wrapper=("$readonly_sandbox_bwrap" --dev /dev --proc /proc --tmpfs /tmp
        --unshare-pid --unshare-ipc --unshare-uts --new-session)
    for path in "${readonly_sandbox_base_paths[@]}"; do
        [ -e "$path" ] || continue
        wrapper+=(--ro-bind "$path" "$path")
    done
    [ -z "$real_git_dir" ] || wrapper+=(--ro-bind "$real_git_dir" "$real_git_dir")
    # HOME exists but is empty, and exactly one credential path is bound back.
    wrapper+=(--tmpfs "$home_dir")
    if [ -n "$readonly_sandbox_credential_dir" ] && [ -e "$readonly_sandbox_credential_dir" ]; then
        wrapper+=(--ro-bind "$readonly_sandbox_credential_dir" "$readonly_sandbox_credential_dir")
    fi
    for extra in "${readonly_sandbox_extra_ro[@]+"${readonly_sandbox_extra_ro[@]}"}"; do
        [ -e "$extra" ] || continue
        wrapper+=(--ro-bind "$extra" "$extra")
    done
    local link_pair link_target link_path
    for link_pair in "${readonly_sandbox_symlinks[@]+"${readonly_sandbox_symlinks[@]}"}"; do
        link_target="${link_pair%%|*}"
        link_path="${link_pair#*|}"
        [ -n "$link_target" ] && [ -n "$link_path" ] || continue
        wrapper+=(--symlink "$link_target" "$link_path")
    done
    # An operator's own additions, colon-separated. Named deliberately, never
    # inherited: a path here is one somebody decided the finder needs.
    if [ -n "${FINDER_REVIEW_SANDBOX_EXTRA_RO:-}" ]; then
        while IFS= read -r path; do
            [ -n "$path" ] && [ -e "$path" ] || continue
            wrapper+=(--ro-bind "$path" "$path")
        done <<<"${FINDER_REVIEW_SANDBOX_EXTRA_RO//:/$'\n'}"
    fi
    wrapper+=(--ro-bind "$readonly_sandbox_dir" "$readonly_sandbox_dir"
        --chdir "$readonly_sandbox_dir" --die-with-parent)

    (
        cd "$readonly_sandbox_dir" || exit 1
        sandbox_clean_env "${wrapper[@]}" "$@"
    )
}

# Runs its arguments with an environment allowlist over `env -i`: the process
# starts with NOTHING and is handed back only what is named. GIT_CONFIG_* are
# SET rather than unset so that even a config reachable through the binds
# cannot supply a credential helper. Shared by the sandboxed and degraded
# paths, so the two cannot drift apart.
sandbox_clean_env() {
    local -a env_args
    local name
    env_args=(env -i
        GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
        GIT_TERMINAL_PROMPT=0)
    for name in "${readonly_sandbox_env_allow[@]}"; do
        [ -n "${!name+set}" ] || continue
        env_args+=("$name=${!name}")
    done
    if [ -n "${FINDER_REVIEW_SANDBOX_ENV:-}" ]; then
        while IFS= read -r name; do
            [ -n "$name" ] && [ -n "${!name+set}" ] || continue
            env_args+=("$name=${!name}")
        done <<<"${FINDER_REVIEW_SANDBOX_ENV//:/$'\n'}"
    fi
    "${env_args[@]}" "$@"
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
    return "$status"
}

sandbox_cleanup() {
    [ -n "$readonly_sandbox_dir" ] || return 0
    rm -rf "$readonly_sandbox_dir.home"
    chmod -R u+w "$readonly_sandbox_dir" 2>/dev/null || true
    git worktree remove --force "$readonly_sandbox_dir" >/dev/null 2>&1 ||
        rm -rf "$readonly_sandbox_dir"
    rm -f "$readonly_sandbox_manifest"
    readonly_sandbox_dir=
    readonly_sandbox_manifest=
}
