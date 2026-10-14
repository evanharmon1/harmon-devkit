#!/usr/bin/env bash
set -euo pipefail

# Prevent VS Code's JS debug extension from breaking Node.js processes.
# The extension injects NODE_OPTIONS=--require .../bootloader.js, but the
# bootloader may not exist during lifecycle commands (extensions not installed
# yet or workspace storage path is stale). This is a non-interactive context,
# so the shell profile's `unset NODE_OPTIONS` doesn't apply.
unset NODE_OPTIONS
# Prevent a host-exported ANTHROPIC_API_KEY from silently winning over
# CLAUDE_CODE_OAUTH_TOKEN and billing the API account instead.
unset ANTHROPIC_API_KEY

if [ -z "${DEVCONTAINER_GIT_NAME:-}" ] || [ -z "${DEVCONTAINER_GIT_EMAIL:-}" ]; then
    echo "DEVCONTAINER_GIT_NAME and DEVCONTAINER_GIT_EMAIL must be set." >&2
    exit 1
fi

# Shell aliases/functions are version-controlled in .devcontainer/config/ and
# baked into the image at /usr/local/share/devcontainer-config/shell-aliases.sh
# by the Dockerfile. We only wire up the source line in the rc files below.
PROFILE_SOURCE_LINE='source /usr/local/share/devcontainer-config/shell-aliases.sh'

# All runtime git-config writes target the image's XDG environment config
# explicitly. `git config --global` picks its file at runtime — ~/.gitconfig
# when that file exists, the XDG file otherwise — and whether ~/.gitconfig
# exists here depends on whether VS Code's copyGitConfig has copied the host's
# in yet, so --global writes land in a different file per attach mode and per
# lifecycle ordering. Pinning the file makes the environment layer
# deterministic and keeps ~/.gitconfig personal-only (issue #542).
ENV_GITCONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/git/config"
mkdir -p "$(dirname "$ENV_GITCONFIG")"

# --- Workspace permissions reconciliation ---
# Git 2.35+ refuses to inspect a bind-mounted repository when the host checkout
# owner differs from the in-container user. Resolve the mounted workspace from
# its .git marker without asking Git first, reclaim the Git metadata tree for
# the container user (never grant other users on the host access to it), then
# add only the workspace's exact path to the environment config. A wildcard
# safe.directory would trust unrelated repositories, so it is never used here.
resolve_workspace_root() {
    local candidate="$1"
    while [ "$candidate" != "/" ]; do
        if [ -L "$candidate/.git" ]; then
            echo "ERROR: refusing a symlinked Git marker at $candidate/.git" >&2
            return 1
        fi
        if [ -e "$candidate/.git" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
        candidate="$(dirname "$candidate")"
    done
    return 1
}

# resolve_git_dir <workspace_root> — the actual Git directory to reconcile.
# For an ordinary checkout this is "$workspace_root/.git" itself; in a linked
# worktree .git is a FILE pointing at this checkout's private admin dir inside
# the MAIN checkout's .git, and only that main .git holds the shared
# objects/refs/hooks tree this reconciliation exists to fix (issue #1241 item
# 6). Delegating the resolution to Git rather than hand-parsing the pointer
# file tracks whatever format the installed Git version actually uses.
# safe.directory is scoped to this exact invocation via -c — never persisted,
# never a wildcard — because Git's ownership check runs before the workspace
# root has been trusted anywhere durable.
# resolve_relative_to <base_dir> <maybe_relative_path> — canonicalize a path
# that may be relative to base_dir (Git's own worktree "gitdir" pointers are
# relative when the worktree was created with --relative-paths /
# worktree.useRelativePaths). Portable (cd + pwd -P), no GNU-only realpath.
resolve_relative_to() {
    local base_dir="$1" maybe_relative="$2"
    case "$maybe_relative" in
    /*) printf '%s\n' "$maybe_relative" ;;
    *)
        (
            cd "$base_dir" && cd "$(dirname "$maybe_relative")" 2>/dev/null &&
                printf '%s/%s\n' "$(pwd -P)" "$(basename "$maybe_relative")"
        )
        ;;
    esac
}

resolve_git_dir() {
    local workspace_root="$1"
    local git_marker="$workspace_root/.git"
    local git_dir admin_dir reverse_pointer reverse_pointer_resolved cr

    if [ -d "$git_marker" ]; then
        # A .git DIRECTORY containing its own "commondir" file is indirection
        # Git itself follows (the same marker a worktree admin dir uses) —
        # not an ordinary checkout, even though it is a directory. Trusting
        # it unconditionally here would reconcile $git_marker itself while
        # Git's own commands operate on wherever commondir actually points,
        # silently reconciling the wrong tree. Treat it the same as any
        # other non-worktree indirection this reconciliation cannot verify
        # (#1241 integration round 3, Codex finding 4056166565).
        if [ -e "$git_marker/commondir" ]; then
            echo "NOTE: $workspace_root's .git is non-worktree indirection (a .git directory containing its own commondir file, which Git itself follows) — skipping the privileged Git metadata reconciliation for it. This is a known, intentional non-goal: see docs/guides/devcontainers.md." >&2
            return 2
        fi
        # Ordinary checkout: no attacker-controlled indirection to validate
        # — $git_marker IS the Git directory, not a pointer to one.
        printf '%s\n' "$git_marker"
        return 0
    fi

    # Linked worktree: .git is a FILE naming the admin directory to trust,
    # and that content is checkout-controlled — safe.directory only bypasses
    # Git's ownership check; it proves nothing about whether the resolved
    # directory actually belongs to this workspace. A stale, corrupted, or
    # crafted pointer (e.g. "gitdir: /path/to/another/repo/...") would
    # otherwise redirect the privileged recursive chown/chmod below onto an
    # unrelated repository (#1241 challenge rounds 3/4/6, findings
    # F8/F11/F17; review round 1, finding F19).
    admin_dir="$(git -c safe.directory="$workspace_root" -C "$workspace_root" \
        rev-parse --path-format=absolute --git-dir 2>/dev/null)" || {
        echo "ERROR: could not resolve the Git admin directory for $workspace_root" >&2
        return 1
    }
    [ -n "$admin_dir" ] || {
        echo "ERROR: Git reported an empty admin directory for $workspace_root" >&2
        return 1
    }
    git_dir="$(git -c safe.directory="$workspace_root" -C "$workspace_root" \
        rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || {
        echo "ERROR: could not resolve the Git directory for $workspace_root" >&2
        return 1
    }
    [ -n "$git_dir" ] || {
        echo "ERROR: Git reported an empty common directory for $workspace_root" >&2
        return 1
    }

    # .git can be a FILE for shapes other than a linked worktree too — a
    # submodule, or a repository made with `git init --separate-git-dir` —
    # where --git-dir and --git-common-dir resolve to the SAME directory
    # (no admin/worktrees split to validate). Git provides no reverse-
    # pointer mechanism for this shape the way it does for worktrees
    # (verified empirically: neither sets core.worktree or an equivalent),
    # so there is no way to distinguish a legitimate submodule/separate-
    # git-dir checkout from a crafted ".git" naming an arbitrary unrelated
    # repository directly. Rather than either trusting it blindly (F17's
    # original vulnerability) or aborting post-create entirely, skip the
    # privileged reconciliation for this one shape with a clear line
    # explaining why — this reconciliation's own scope (issue #1241 item 6)
    # was always linked worktrees specifically, and a devcontainer
    # workspace pointed directly at a submodule or separate-git-dir root is
    # rare enough here that preserving the security property matters more
    # than covering it (maintainer decision, review round 2, finding F22).
    if [ "$admin_dir" = "$git_dir" ]; then
        echo "NOTE: $workspace_root's .git is non-worktree indirection (a submodule or a --separate-git-dir checkout) — skipping the privileged Git metadata reconciliation for it. This is a known, intentional non-goal: see docs/guides/devcontainers.md." >&2
        return 2
    fi

    # A round-trip check on the admin dir ALONE is not enough: a crafted
    # admin directory can carry a correct reverse pointer back to this
    # workspace while its OWN "commondir" file names a different, unrelated
    # repository, which --git-common-dir would then happily return — the
    # privileged chown/chmod would follow it there (review round 1, finding
    # F19). Require the admin directory to actually be the exact
    # "worktrees/<name>" child of the resolved common directory — the only
    # shape Git itself ever creates — before trusting either path.
    [ "$(dirname "$admin_dir")" = "$git_dir/worktrees" ] || {
        echo "ERROR: refusing an untrusted worktree admin directory at $admin_dir — it is not a direct worktrees/ child of the resolved common directory $git_dir" >&2
        return 1
    }

    # THEN require the admin directory to round-trip: every worktree admin
    # directory Git itself creates (`git worktree add`) contains its OWN
    # "gitdir" file naming the linked worktree's .git file right back —
    # verified empirically. The reverse pointer is RELATIVE (to the admin
    # dir) when the worktree was created with --relative-paths — resolved
    # before comparing, so a Git-supported relative worktree is accepted,
    # not just an absolute one (review round 1, finding F21).
    reverse_pointer="$(cat "$admin_dir/gitdir" 2>/dev/null)" || {
        echo "ERROR: refusing an untrusted worktree admin directory at $admin_dir — no reverse gitdir pointer found" >&2
        return 1
    }
    # Command substitution strips trailing newlines but not a trailing CR —
    # a "gitdir" file written with CRLF line endings (a Windows host, or a
    # host-side editor/tool that normalizes line endings) would otherwise
    # leave a literal \r on the end of the path, breaking both the
    # resolve_relative_to call below and the exact-match comparison after
    # it. cr="$(printf '\r')" + "${var%"$cr"}" (rather than the $'\r'
    # ANSI-C-quoted form) is the same strip with no shell-specific quoting
    # syntax in it (#1241 integration round 4, Gemini findings re-raising
    # this as non-POSIX after it was already declined on those grounds —
    # this repo's shebang and invocation are bash either way, but this form
    # is equally correct and stops the re-raise).
    cr="$(printf '\r')"
    reverse_pointer="${reverse_pointer%"$cr"}"
    reverse_pointer_resolved="$(resolve_relative_to "$admin_dir" "$reverse_pointer")" || {
        echo "ERROR: could not resolve the reverse gitdir pointer at $admin_dir/gitdir" >&2
        return 1
    }
    [ "$reverse_pointer_resolved" = "$git_marker" ] || {
        echo "ERROR: refusing an untrusted worktree admin directory at $admin_dir — its reverse pointer ($reverse_pointer_resolved) does not name $git_marker" >&2
        return 1
    }

    printf '%s\n' "$git_dir"
}

# Every step below (chown, chmod, setgid, core.sharedRepository) is
# individually idempotent and their combined end state does not depend on
# what order a RETRY finds them in — re-running this function always
# converges to the same fully-reconciled tree. That is deliberate: a true
# rollback would mean snapshotting every file's original owner and mode
# before touching anything, which is itself another privileged, fallible
# recursive walk. Converging on retry is the cheaper, safer answer to the
# same problem (#1241 challenge round 4, finding F12) — an interruption
# between any two steps leaves a state the NEXT post-create (or a
# container rebuild) completes, never one only a rollback could fix. One
# shared failure message names that remedy instead of repeating it.
reconcile_step_failed() {
    echo "ERROR: $1" >&2
    echo "Reconciliation is safe to retry — re-run post-create-common.sh, or rebuild the container, to complete it; every step converges to the same end state regardless of where a previous attempt stopped." >&2
    return 1
}

reconcile_workspace_permissions() {
    local env_gitconfig="$1"
    local workspace_root git_dir resolve_status
    local skip_privileged_reconciliation=false

    workspace_root="$(resolve_workspace_root "$(pwd -P)")" || {
        echo "ERROR: could not resolve the repository/workspace root from $(pwd -P)" >&2
        return 1
    }
    [ "$workspace_root" != "/" ] || {
        echo "ERROR: refusing to reconcile the filesystem root as a workspace" >&2
        return 1
    }

    # The exit status is consumed by this `if` (not a bare assignment) so
    # that `set -e` does not abort here on resolve_git_dir's deliberate
    # `return 2` — verified empirically: a bare
    # `git_dir="$(resolve_git_dir ...)"; resolve_status=$?` aborts the whole
    # function under set -e before the status is ever read.
    if git_dir="$(resolve_git_dir "$workspace_root")"; then
        skip_privileged_reconciliation=false
    else
        resolve_status=$?
        if [ "$resolve_status" -eq 2 ]; then
            # Non-worktree .git indirection (submodule / --separate-git-dir)
            # — resolve_git_dir already explained why on stderr. Skip the
            # privileged mutation but still let post-create continue, and
            # still trust the workspace for the ownership-CHECK bypass below
            # (that grants no new filesystem access on its own, unlike the
            # mutation steps this skips).
            skip_privileged_reconciliation=true
        else
            return 1
        fi
    fi

    if [ "$skip_privileged_reconciliation" != true ]; then
        reconcile_git_metadata_ownership "$git_dir" "$workspace_root" || return 1
    fi

    # This read is deliberately an exact-line match. An existing wildcard (or
    # another repository path) does not satisfy the workspace's own entry. It
    # is written only after the permission repair succeeds, so a failed
    # lifecycle never leaves a trusted-but-unusable checkout.
    safe_directories=""
    if ! safe_directories="$(git config --file "$env_gitconfig" \
        --get-all safe.directory 2>/dev/null)" ||
        ! grep -Fx "$workspace_root" <<<"$safe_directories" >/dev/null; then
        git config --file "$env_gitconfig" --add safe.directory "$workspace_root" || return 1
    fi

    RECONCILED_WORKSPACE_ROOT="$workspace_root"
}

# reconcile_git_metadata_ownership <git_dir> <workspace_root> — the
# privileged mutation steps, factored out so reconcile_workspace_permissions
# can skip them entirely for non-worktree .git indirection (review round 2,
# finding F22) without duplicating them.
reconcile_git_metadata_ownership() {
    local git_dir="$1"
    local workspace_root="$2"
    local orig_gid

    # Capture the tree's CURRENT group before reassigning ownership: the
    # host checkout's original group keeps write access afterward, instead
    # of only the container user — a bare owner reassignment would lock the
    # host side out of its own checkout the next time it commits, checks
    # out, or fetches outside the container (#1241 challenge round 1,
    # finding F1; confirmed empirically — the fix is a maintainer-ruled
    # ownership-model revision, not a mode-only change).
    orig_gid="$(stat -c '%g' "$git_dir" 2>/dev/null || stat -f '%g' "$git_dir")" || {
        reconcile_step_failed "could not determine the current group of $git_dir"
        return 1
    }

    # Reclaim the Git metadata tree for the container user's own uid, keep
    # the original gid, then set exact modes (no world-writable bits) — Git
    # and Lefthook need the tree readable, writable, and traversable for
    # BOTH the container user and the host's original group, nothing more.
    # Capital X adds execute permission to directories and files that were
    # already executable, not every file — an unmanaged hook that predates
    # this reconciliation (not one of Lefthook's own, which it (re)installs
    # with its own chmod +x after this runs) keeps its executable bit
    # instead of being silently disabled.
    #
    # Directories always get reconciled — the filesystem itself refuses
    # hard links to directories. Regular files are reconciled only when
    # their link count is exactly 1: a local `git clone` (no
    # --no-hardlinks/--dissociate) hard-links loose objects and packs to
    # the source repository by default, and a recursive chown/chmod on a
    # hard-linked file mutates the SAME inode for every path referencing
    # it — silently changing ownership and permissions on an unrelated
    # repository entirely outside $git_dir. Those objects are immutable and
    # world-readable (mode 0444) by Git's own default, so a multiply-linked
    # one never needed this reconciliation's write grant in the first
    # place; skipping it removes an out-of-scope mutation, not a needed one
    # (#1241 review round 3, finding F23 — confirmed empirically: a local
    # clone's object files share an inode, nlink=2, with the source
    # repository's, and mutating the clone's copy mutated the source's).
    sudo find "$git_dir" \( -type d -o \( -type f -a -links 1 \) \) \
        -exec chown "$(id -u):${orig_gid}" {} + || {
        reconcile_step_failed "could not reclaim ownership of the Git directory at $git_dir"
        return 1
    }
    # Privileged (sudo), like the chown pass above: the container user does
    # not yet own — and, before this exact call, may not even be able to
    # TRAVERSE into — every directory here. chown alone does not add the
    # execute/traverse bit a mismatched-ownership directory can be missing
    # entirely, so an unprivileged find attempting to enter it would
    # silently skip everything underneath, exactly like the ownership
    # mismatch this reconciliation exists to fix (#1241 integration round
    # 3, Gemini findings on the same shape as the ownership pass above).
    sudo find "$git_dir" \( -type d -o \( -type f -a -links 1 \) \) \
        -exec chmod u=rwX,g=rwX,o=rX {} + || {
        reconcile_step_failed "could not set permissions under $git_dir"
        return 1
    }

    # The pass above deliberately skips multi-linked regular files under
    # objects/ (F23) — Git's immutable, hash-addressed loose objects and
    # packs, which never need the write grant this reconciliation exists
    # to give. That exemption is scoped to objects/ specifically, not
    # "any multi-linked file anywhere": a hard link OUTSIDE objects/ means
    # shared MUTABLE metadata (a hook, a config file, anything this
    # workspace or Git itself might rewrite in place) — e.g. a
    # hard-linked .git/hooks/pre-commit left unreconciled by a blanket
    # exemption would later make install_repo_managed_hooks's own `cp`
    # fail against it. Break the hard link unconditionally for anything
    # outside objects/, and for anything inside objects/ that the
    # container user genuinely cannot read (a restrictive host-side
    # umask at clone time can leave one at mode 0440, owned by neither
    # the container's uid nor its preserved group) — never for a
    # readable objects/ file, which correctly stays untouched and still
    # shares the source repository's inode. Privileged-copy the bytes
    # (only root can read an unreadable original) into a sibling temp
    # name in the same directory, chown/chmod that copy to this
    # reconciliation's own target state, then atomically replace the
    # path with it: the original inode, and whatever else still
    # references it outside $git_dir, is never touched (#1241 integration
    # round 2, Codex finding 4056048549, scope narrowed to objects/ in
    # round 3, Codex finding 4056166568 — both verified empirically).
    while IFS= read -r linked_object; do
        [ -n "$linked_object" ] || continue
        case "$linked_object" in
        "$git_dir"/objects/*)
            [ -r "$linked_object" ] && continue
            ;;
        esac
        # Capture the inode find itself saw, unprivileged, right here — the
        # privileged block below re-checks against it immediately before
        # copying, so a same-uid process swapping a symlink in at this
        # exact path between enumeration and the privileged copy is
        # detected and refused rather than followed (#1241 integration
        # round 4, Codex finding 4056318550).
        seen_inode="$(stat -c '%i' "$linked_object" 2>/dev/null || stat -f '%i' "$linked_object" 2>/dev/null)" || continue
        sudo sh -c '
            target="$1"
            owner="$2"
            seen_inode="$3"
            # Re-verify immediately before the privileged copy: refuse if
            # the path no longer names a plain regular file, or now names a
            # DIFFERENT inode than the one just captured — either signals a
            # race since enumeration, not the file this loop meant to fix.
            [ -f "$target" ] && [ ! -L "$target" ] || exit 1
            current_inode="$(stat -c "%i" "$target" 2>/dev/null || stat -f "%i" "$target" 2>/dev/null)" || exit 1
            [ "$current_inode" = "$seen_inode" ] || exit 1
            tmp="$(mktemp "$(dirname "$target")/.harmon-init-unlink.XXXXXX")" || exit 1
            # -P (POSIX/BSD-portable spelling of --no-dereference): if
            # something raced past the checks above in the instant before
            # this runs, copy the symlink itself, never what it points to
            # — a privileged cp that DID dereference would let a same-uid
            # process read an arbitrary root-readable file into the
            # workspace. Re-checked once more right after: only a genuine
            # plain file proceeds to chown/chmod/move.
            if ! cp -Pp "$target" "$tmp"; then
                rm -f "$tmp"
                exit 1
            fi
            if [ ! -f "$tmp" ] || [ -L "$tmp" ]; then
                rm -f "$tmp"
                exit 1
            fi
            if ! chown "$owner" "$tmp" || ! chmod u=rwX,g=rwX,o=rX "$tmp" || ! mv -f "$tmp" "$target"; then
                rm -f "$tmp"
                exit 1
            fi
        ' _ "$linked_object" "$(id -u):${orig_gid}" "$seen_inode" || {
            reconcile_step_failed "could not break the hard link for a multi-linked object at $linked_object (or it changed since it was found)"
            return 1
        }
    done < <(sudo find "$git_dir" -type f -links +1 -print 2>/dev/null)

    # setgid on directories only (never files — on a FILE this bit means
    # something unrelated and security-sensitive, set-group-ID on
    # execution, which must never land on a hook script): every new file or
    # directory Git creates under here inherits the original group instead
    # of whichever process's primary group happened to create it. Privileged
    # (sudo): an unprivileged chmod silently CLEARS S_ISGID — reporting
    # success while not setting it — whenever the caller is not itself a
    # member of the target group, which is the ordinary case here (the
    # container user has no reason to belong to the host's original group)
    # (#1241 challenge round 5, finding F13).
    sudo find "$git_dir" -type d -exec chmod g+s {} + || {
        reconcile_step_failed "could not set the setgid bit under $git_dir"
        return 1
    }
    # setgid only propagates GROUP OWNERSHIP to new entries — it does not
    # make Git create them group-WRITABLE. Git's own loose-object and ref
    # creation honors the process umask by default, so the very next commit
    # made after reconciliation would otherwise create fresh object-fanout
    # directories and ref files the host's group cannot write to, breaking
    # host access again immediately (#1241 challenge round 2, finding F5).
    # core.sharedRepository is Git's own mechanism for exactly this: a
    # repository shared read-write across a Unix group. The symbolic value
    # "group" is NOT umask-independent — Git only raises the group class to
    # match the owner class, leaving "other" governed by umask, so a
    # permissive umask (this environment's default is 000) would still
    # create world-writable metadata and silently reopen the exact exposure
    # this whole change exists to close. An explicit octal pins the bits
    # Git actually applies regardless of umask.
    git -c safe.directory="$workspace_root" -C "$workspace_root" config core.sharedRepository 0664 || {
        reconcile_step_failed "could not configure shared-repository permissions for $workspace_root"
        return 1
    }
}

# --- End workspace permissions reconciliation ---
RECONCILED_WORKSPACE_ROOT=""
reconcile_workspace_permissions "$ENV_GITCONFIG"
WORKSPACE_ROOT="$RECONCILED_WORKSPACE_ROOT"
cd "$WORKSPACE_ROOT"
echo "==> Workspace permissions prepared for $(id -un):$(id -gn): $WORKSPACE_ROOT"

# Git identity for commits. Written to the environment layer, so in a bot or
# headless container DEVCONTAINER_GIT_* is the identity. When a human attaches
# via VS Code and copyGitConfig brings their personal ~/.gitconfig in, its
# user.* wins over this layer — that copy is personal-only config, and the
# attaching human's own identity taking precedence is the intended outcome.
git config --file "$ENV_GITCONFIG" user.name "${DEVCONTAINER_GIT_NAME}"
git config --file "$ENV_GITCONFIG" user.email "${DEVCONTAINER_GIT_EMAIL}"

# Loud, actionable guidance for an unauthenticated `gh`. The dev profile carries
# no GH_TOKEN and does not persist its login, so this is that profile's ordinary
# first-run state in EVERY attach mode — not just a bot misconfiguration on the
# headless path. Hence a shared helper: the VS Code branch below needs the same
# message and would otherwise say nothing at all.
#
# The REMEDY differs by profile, and printing the wrong one is a security bug
# rather than a typo: telling a bot container to `gh auth login` would put an
# operator credential — `workflow` scope and all — inside a bypassPermissions
# agent container, which is the exact escalation the bot PAT's denials exist to
# stop (docs/architecture/security.md). Each profile's own post-create.sh
# declares which remedy applies via DEVCONTAINER_GH_AUTH ("login" for dev,
# "agent-token" for the agent posture's AGENT_GH_TOKEN); anything else falls
# back to the token message, so the operator instructions can only ever appear
# where a wrapper explicitly asked for them.
#
# $1 is an extra command for the login path (the git bridge), omitted where
# VS Code already manages git's credential.
# The scope list the login line below asks for comes from scripts/gh-scopes.sh,
# the same file status.sh and setup-gh-scopes.sh read, so the banner cannot
# drift from what the session-start check demands (issue #827). Sourced
# defensively: this script also runs in trees where the workspace folder is not
# yet the repo root, and a missing helper must not fail the whole post-create.
GH_SCOPES_LIB="${GH_SCOPES_LIB:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/gh-scopes.sh}"
if [ -r "${GH_SCOPES_LIB}" ]; then
    # shellcheck source=scripts/gh-scopes.sh
    . "${GH_SCOPES_LIB}"
else
    gh_scopes_request_list() { printf '%s' "repo,workflow,project,read:project"; }
fi

gh_auth_help() {
    echo "=============================================================="
    echo "  GitHub CLI is NOT authenticated — gh pr / gh api will fail."
    echo "  Public siblings clone over HTTPS without a login, private ones"
    echo "  after 'task setup:gh-scopes', which starts the bootstrap itself."
    echo ""
    if [ "${DEVCONTAINER_GH_AUTH:-token}" = "login" ]; then
        echo "  This profile authenticates as you. Log in:"
        echo ""
        echo "    gh auth login --hostname github.com --git-protocol https \\"
        echo "      --web --scopes \"$(gh_scopes_request_list)\""
        echo ""
        echo "  Then, in the checkout, 'task setup:gh-scopes' verifies the"
        echo "  scopes landed and adds any this repo needs. (It refreshes an"
        echo "  EXISTING login — it cannot replace the command above.)"
        if [ -n "${1:-}" ]; then
            echo "    $1"
        fi
        echo ""
        echo "  See docs/guides/devcontainers.md."
    elif [ "${DEVCONTAINER_GH_AUTH:-token}" = "agent-token" ]; then
        echo "  This AGENT-posture container authenticates from AGENT_GH_TOKEN,"
        echo "  the agent's own PAT on the bot account. Do NOT run"
        echo "  'gh auth login' here, and never supply the bot's GH_TOKEN."
        echo "  Populate AGENT_GH_TOKEN in the host environment (init-env.sh"
        echo "  projects it into .devcontainer/agent/devcontainer.env) and"
        echo "  rebuild. See docs/guides/bot-account.md."
    else
        echo "  This profile authenticates from GH_TOKEN. Do NOT run"
        echo "  'gh auth login' here — that would put a human credential in an"
        echo "  agent container. Populate GH_TOKEN in the env-file this profile"
        echo "  loads (1Password Environment locally, workspace parameters on"
        echo "  Coder) and rebuild. See docs/guides/bot-account.md."
    fi
    echo "=============================================================="
}

# Let VS Code's devcontainer integration manage the in-container git credential
# helper. Installing gh's URL-specific helpers here can confuse the remote
# containers bootstrap when it replaces credential.helper on attach.
if [ -n "${REMOTE_CONTAINERS_IPC:-}" ] || [ "${REMOTE_CONTAINERS:-}" = "true" ]; then
    # Unset from both global-scope files: a prior `gh auth setup-git` may have
    # written the helpers to either one (gh uses --global, whose target file
    # varies — see ENV_GITCONFIG above).
    for cfg in "$ENV_GITCONFIG" "$HOME/.gitconfig"; do
        [ -f "$cfg" ] || continue
        git config --file "$cfg" --unset-all credential.https://github.com.helper || true
        git config --file "$cfg" --unset-all credential.https://gist.github.com.helper || true
    done
    echo "VS Code devcontainer detected; skipping gh auth setup-git."
    # VS Code's forwarded host credential covers *git* on this path, but not
    # `gh` — it reads its own config, and the dev profile supplies no GH_TOKEN.
    # Pass NO git bridge: unsetting those helpers two lines up is deliberate, so
    # telling the user to run `gh auth setup-git` would undo it.
    gh auth status >/dev/null 2>&1 || gh_auth_help
elif gh auth status >/dev/null 2>&1; then
    gh auth setup-git
else
    # Nothing manages git's credential here, so the bridge is part of the fix.
    gh_auth_help "gh auth setup-git"
fi

# The GitHub SSH→HTTPS insteadOf rewrites are baked into the image's
# environment gitconfig (.devcontainer/config/gitconfig) — static config
# belongs in the image layer, not in runtime writes.

# Effective read, not --global: the scoped read surface skips the XDG file
# once ~/.gitconfig exists, so it would print empty exactly when identity
# lives in the environment layer.
echo "Git user: $(git config user.name)"
echo "GitHub auth status:"
gh auth status || true

# push.autoSetupRemote is baked in the environment gitconfig alongside the
# other static settings.

# --- Transitional: Codex overridable-defaults layer (harmon-init#1186) ---
#
# Model, reasoning effort, the project-doc budget and the TUI status line moved
# OUT of /etc/codex/managed_config.toml, where Codex treats every key as an
# unoverridable requirement that silently beats `-c` and the user's own config,
# and INTO /etc/codex/config.toml, its system *defaults* layer. (An explicit
# `-m` still overrode a pinned `model`; it was `-c model=` that was swallowed.)
#
# The installer that writes that file lives in the shared IMAGE, but this repo
# pins an image by digest, so between this change landing and the consumer-pin
# bump the pinned image still ships the old installer -- it would create no
# /etc/codex/config.toml at all, and the defaults would simply vanish rather
# than become overridable. This step closes that window from the consumer side.
#
# It is deliberately self-retiring: once the pinned image's own installer
# writes the file, the `-f` test is true on every subsequent build and this is
# a no-op. Delete it after the pin bump has landed everywhere.
# `workspace_root` is local to reconcile_workspace_permissions, so resolve it
# here rather than reaching for a name that is unbound under `set -u`.
codex_defaults_root="$(resolve_workspace_root "$(pwd -P)" || true)"
codex_defaults_src="${codex_defaults_root:-/nonexistent}/.devcontainer/config/codex-system-config.toml"
if [ ! -f /etc/codex/config.toml ] && [ -f "$codex_defaults_src" ]; then
    echo "==> Installing Codex defaults layer (image predates the split)..."
    sudo install -d -m 0755 /etc/codex
    sudo install -m 0644 "$codex_defaults_src" /etc/codex/config.toml
fi

echo "==> Fixing ownership of persistent volume dirs..."
for dir in /home/vscode/.codex /home/vscode/.claude /home/vscode/.gemini \
    /home/vscode/.copilot /home/vscode/.pi /home/vscode/.omp \
    /home/vscode/.agent-deck /home/vscode/.shell-history \
    /home/vscode/.config /home/vscode/.config/herdr /home/vscode/.config/opencode \
    /home/vscode/.local /home/vscode/.local/share /home/vscode/.local/share/opencode \
    /home/vscode/.local/share/zoxide; do
    sudo mkdir -p "$dir"
    sudo chown vscode:vscode "$dir"
    chmod 700 "$dir"
done

# --- Coder persistent volume symlinks ---
# Coder's envbuilder does not support devcontainer volume mounts, so on Coder
# the template provides a single persistent volume at ~/.persistent/ and we
# symlink the individual directories there.
#
# ORDERING IS LOAD-BEARING: this block must run BEFORE link-claude-json.sh and
# the onboarding seed below. Until these symlinks exist, ~/.claude on Coder is
# the container-local directory the ownership loop just created — the helper
# and the seed would populate THAT, and this block's migration `cp -a` would
# then copy the fresh stub over ~/.persistent/.claude/'s real account state:
# the exact clobber this change exists to prevent, surviving on the one
# platform whose persistence is wired by symlink instead of mount.
if [ "${CODER:-}" = "true" ] && [ -d "/home/vscode/.persistent" ]; then
    echo "==> Coder detected — setting up persistent volume symlinks..."
    for dir in .claude .codex .gemini .copilot .pi .omp .agent-deck .shell-history; do
        mkdir -p "/home/vscode/.persistent/$dir"
        if [ -d "$HOME/$dir" ] && [ ! -L "$HOME/$dir" ]; then
            if cp -a "$HOME/$dir/." "/home/vscode/.persistent/$dir/"; then
                rm -rf "${HOME:?}/$dir"
                ln -sfn "/home/vscode/.persistent/$dir" "$HOME/$dir"
            else
                echo "WARN: $dir migration to ~/.persistent failed;" \
                    "leaving $HOME/$dir on the container-local filesystem" >&2
            fi
        else
            ln -sfn "/home/vscode/.persistent/$dir" "$HOME/$dir"
        fi
    done
    mkdir -p "/home/vscode/.persistent/zoxide" "$HOME/.local/share"
    if [ -d "$HOME/.local/share/zoxide" ] && [ ! -L "$HOME/.local/share/zoxide" ]; then
        cp -a "$HOME/.local/share/zoxide/." "/home/vscode/.persistent/zoxide/" 2>/dev/null || true
        rm -rf "${HOME:?}/.local/share/zoxide"
    fi
    ln -sfn "/home/vscode/.persistent/zoxide" "$HOME/.local/share/zoxide"
    mkdir -p "/home/vscode/.persistent/herdr" "$HOME/.config"
    # Unlike the agent dirs above, ~/.config/herdr can hold the only copy of
    # session snapshots — never delete the source unless the copy succeeded,
    # and fail the lifecycle rather than continue unpersisted: a
    # warn-and-continue would let Herdr write snapshots the next rebuild
    # silently discards.
    if [ -d "$HOME/.config/herdr" ] && [ ! -L "$HOME/.config/herdr" ]; then
        if ! cp -a "$HOME/.config/herdr/." "/home/vscode/.persistent/herdr/"; then
            echo "ERROR: Herdr state migration to ~/.persistent failed;" \
                "fix the persistent volume and rebuild" >&2
            exit 1
        fi
        rm -rf "${HOME:?}/.config/herdr"
    fi
    ln -sfn "/home/vscode/.persistent/herdr" "$HOME/.config/herdr"
    bash .devcontainer/scripts/persist-opencode.sh /home/vscode/.persistent
fi

# --- Persist ~/.claude.json into the ~/.claude volume ---
# MUST run before anything below that can spawn `claude` (the onboarding seed,
# the herdr integration install, and the agent-deck conductor setup all can) —
# a `claude` launched with no symlink in place writes a fresh, near-empty REAL
# file at ~/.claude.json, which post-start would then have moved OVER the
# persisted 38 KB of account state. And it must run AFTER the Coder persistence
# block above, so that on Coder ~/.claude already points into ~/.persistent
# rather than at the container-local directory. See link-claude-json.sh.
bash .devcontainer/scripts/link-claude-json.sh

# --- Claude Code onboarding seed ---
# Pre-seed ~/.claude/.claude.json so fresh containers skip the onboarding
# wizard (upstream issue: https://github.com/anthropics/claude-code/issues/8938).
# post-start-common.sh creates ~/.claude.json → ~/.claude/.claude.json so
# Claude Code finds this file on first launch. Guard: only seed on an empty
# volume — existing session data (token, settings) must never be clobbered.
# Same ordering constraint as the helper: on Coder this must see the
# persistent ~/.claude, not the pre-symlink local one.
CLAUDE_SESSION_FILE="$HOME/.claude/.claude.json"
if [ -d "$HOME/.claude" ] && [ ! -f "$CLAUDE_SESSION_FILE" ]; then
    echo '{"hasCompletedOnboarding":true}' >"$CLAUDE_SESSION_FILE"
    chmod 0600 "$CLAUDE_SESSION_FILE"
    echo "==> Seeded ~/.claude/.claude.json with hasCompletedOnboarding=true"
fi

# --- Herdr agent integrations ---
# resume_agents_on_restore only resumes agents whose Herdr integration has
# recorded a native session reference, and the integration also reports
# authoritative working/blocked state to the sidebar instead of Herdr
# screen-scraping. The installer is version-aware and file-writing only (no
# running server needed), so re-running on every create is safe. Guarded:
# the pinned shared image may predate the herdr binary, and a failed install
# only degrades resume back to fresh shells — never block the container on it.
if command -v herdr >/dev/null 2>&1; then
    for agent in claude codex opencode pi omp copilot; do
        herdr integration install "$agent" ||
            echo "WARN: herdr integration install $agent failed (non-fatal)" >&2
    done
fi

# --- Agent-Deck config seeding ---
# When a fresh volume mount shadows ~/.agent-deck, seed it from the image-baked
# config. Source lives at /usr/local/share/ rather than /tmp/ because /tmp is a
# tmpfs at runtime on Coder hosts and would shadow build-time content.
if [ -d "$HOME/.agent-deck" ] && [ ! -f "$HOME/.agent-deck/config.toml" ]; then
    echo "==> Seeding agent-deck config into persistent volume..."
    cp /usr/local/share/devcontainer-config/agent-deck.toml "$HOME/.agent-deck/config.toml"
fi

# --- Claude Code settings ---
# Two layers, both owned by the dev container (never the volume):
#
#   1. /etc/claude-code/managed-settings.json — baked by the Dockerfile.
#      Highest precedence (policySettings); enforces skipDangerousModePermissionPrompt,
#      defaultMode, and the baseline Bash(...) allow list. Users CANNOT override
#      these. Source of truth: .devcontainer/config/claude-settings.json.
#
#   2. ~/.claude/settings.json (user level) — seed-merged below from
#      claude-user-defaults.json. Provides defaults the user CAN override
#      (currently: model, plus the statusLine renderer baked at
#      /etc/claude-code/statusline.sh). Existing values in ~/.claude/
#      settings.json always win on conflict, so /model and other in-app changes
#      stick across post-create runs. On a fresh volume the defaults are
#      populated; on a volume wipe + rebuild they come back automatically.
CLAUDE_DEFAULTS_SRC=/usr/local/share/devcontainer-config/claude-user-defaults.json
CLAUDE_USER_SETTINGS="$HOME/.claude/settings.json"
if [ -d "$HOME/.claude" ] && [ -f "$CLAUDE_DEFAULTS_SRC" ]; then
    if [ ! -f "$CLAUDE_USER_SETTINGS" ]; then
        echo "==> Seeding ~/.claude/settings.json from dev container defaults..."
        install -m 0600 "$CLAUDE_DEFAULTS_SRC" "$CLAUDE_USER_SETTINGS"
    elif command -v jq >/dev/null 2>&1; then
        # Deep-merge: defaults fill in missing fields, existing user values win.
        # `.[0] * .[1]` puts existing on the right so it overrides defaults.
        tmp=$(mktemp)
        if jq -s '.[0] * .[1]' "$CLAUDE_DEFAULTS_SRC" "$CLAUDE_USER_SETTINGS" >"$tmp"; then
            if ! cmp -s "$tmp" "$CLAUDE_USER_SETTINGS"; then
                echo "==> Merging dev container defaults into ~/.claude/settings.json..."
                install -m 0600 "$tmp" "$CLAUDE_USER_SETTINGS"
            fi
            rm -f "$tmp"
        else
            echo "WARNING: jq merge of Claude user defaults failed; leaving settings.json unchanged" >&2
            rm -f "$tmp"
        fi
    fi
fi

if [ -f pyproject.toml ]; then
    echo "==> Setting up Python virtualenv and dependencies..."
    # .venv is a named volume (see devcontainer.json mounts), which docker
    # creates root-owned on first use — hand it to the container user before
    # uv sync writes into it.
    if [ -d .venv ] && [ ! -w .venv ]; then
        sudo chown "$(id -un):$(id -gn)" .venv
    fi
    uv sync
else
    echo "==> No pyproject.toml found; skipping Python setup."
fi

if [ -f ansible/requirements.yml ]; then
    echo "==> Installing Ansible Galaxy collections..."
    uv run ansible-galaxy collection install -r ansible/requirements.yml
else
    echo "==> No ansible/requirements.yml found; skipping Ansible setup."
fi

if [ -d services/harmon-lab-proxy/homepage ]; then
    echo "==> Installing Node.js dependencies for homepage..."
    (cd services/harmon-lab-proxy/homepage && npm ci)
fi

if [ -f lefthook.yml ] && command -v lefthook &>/dev/null; then
    echo "==> Setting up git hooks via lefthook..."
    lefthook install
fi

echo "==> Wiring up shell aliases/functions source line..."
# Source the image-baked shell-aliases.sh from both .bashrc and .zshrc so it
# works regardless of which shell is active (scripts still use bash).
for rcfile in ~/.bashrc ~/.zshrc; do
    touch "$rcfile"
    if ! grep -Fx "${PROFILE_SOURCE_LINE}" "$rcfile" >/dev/null; then
        {
            echo ""
            echo "# Added by devcontainer post-create"
            echo "${PROFILE_SOURCE_LINE}"
        } >>"$rcfile"
    fi
done

if [ -d terraform ]; then
    echo "==> Initializing Terraform providers..."
    (cd terraform && terraform init -backend=false) || true
fi

if command -v direnv &>/dev/null && [ -f .envrc ]; then
    echo "==> Allowing direnv .envrc..."
    direnv allow
fi

# Clone related repos into /workspaces/ (idempotent + non-destructive; reads
# .devcontainer/related-repos.txt). Runs on create so a rebuilt container
# re-populates siblings. No-op when the list is empty/absent.
bash .devcontainer/scripts/bootstrap-related-repos.sh

echo "==> Setup complete! Run 'task verify' to validate your environment."
