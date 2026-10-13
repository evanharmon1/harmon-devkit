#!/usr/bin/env bash
set -euo pipefail

export DEVCONTAINER_GIT_NAME="evanharmon1-bot"
export DEVCONTAINER_GIT_EMAIL="evanharmon1-bot@users.noreply.github.com"
# Which remedy post-create-common.sh prints when `gh` has no credential. This
# profile authenticates from the bot's scoped PAT, so the fix is always to
# supply GH_TOKEN. Never set this to "login": a `gh auth login` here would put
# the operator's credential inside a bypassPermissions agent container.
export DEVCONTAINER_GH_AUTH="token"

# Ordering is load-bearing (see AGENTS.md):
#   (i)   post-create-common.sh — workspace permissions and, on Coder, the
#         persistent-volume symlink setup MUST run before anything below
#         writes into those directories, or a write lands as the wrong owner
#         or into container-local storage the Coder block would later
#         disregard.
#   (ii)  ensure-antigravity-cli.sh — reconciles ~/.local/bin/agy-real and the
#         plain agy symlink from the rendered HARMON_BOT_AUTONOMY_ANTIGRAVITY
#         marker, before the bot-autonomy antigravity module acts on top of
#         whatever this leaves at ~/.local/bin/agy.
#   (iii) bot-autonomy.sh apply — every installed harness's bot policy, so a
#         fresh container's very first agent invocation already reflects it.
#   (iv)  the conductor step — spawns a `claude` process on first
#         registration, so it must not run before (iii) has succeeded.
#   (v)   bot-autonomy.sh verify — at the end of post-create, so a divergence
#         between what apply wrote and the harness's actual effective state
#         (e.g. an already-present workspace-level override) fails container
#         creation instead of surfacing only at the next post-start.
bash .devcontainer/scripts/post-create-common.sh
bash /usr/local/share/devcontainer-config/ensure-antigravity-cli.sh
bash .devcontainer/scripts/bot-autonomy.sh apply
bash .devcontainer/scripts/post-create-conductor.sh
bash .devcontainer/scripts/bot-autonomy.sh verify

# resolve_relative_to <base_dir> <maybe_relative_path> — mirrors
# post-create-common.sh's own helper of the same name (portable, cd + pwd -P,
# no GNU-only realpath). Duplicated rather than shared across the process
# boundary this script and post-create-common.sh already run in (each is
# invoked as its own `bash <script>`, so a plain shell variable or function
# defined in one is not visible in the other) — matching this codebase's
# existing convention for two separately-invoked lifecycle scripts that need
# the same check: mirror it, with a comment naming the twin, rather than
# reach across the boundary (see ensure-antigravity-cli.sh's
# discard_transaction and bot-autonomy/antigravity.sh's mirrored
# discard_launcher_transaction).
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

# resolve_hooks_common_dir — mirrors post-create-common.sh's own
# resolve_git_dir: the same validated-common-dir resolution that script
# performs before any privileged mutation, duplicated here for the same
# reason resolve_relative_to above is. Installing repo-managed hooks into
# whatever `git rev-parse --git-common-dir` returns, unvalidated, is exactly
# the confused-deputy risk resolve_git_dir was hardened against for the
# privileged ownership reconciliation (#1241 review round 1, findings
# F17/F19/F21): a crafted .git pointer would otherwise make this function
# copy hook scripts into an unrelated repository's hooks directory (#1241
# integration round 2, Codex finding 4056048551). Returns 0 with the
# validated common dir on stdout; 2 for the same non-worktree-indirection
# shape post-create-common.sh's own reconciliation already skips without
# aborting (#1241 review round 2, finding F22) — the caller decides what to
# print for hook installation specifically, since this is a different
# operation than the privileged reconciliation that shape's NOTE line
# describes; or 1 for anything else, refusing.
resolve_hooks_common_dir() {
    local workspace_root git_marker admin_dir git_dir reverse_pointer reverse_pointer_resolved cr
    workspace_root="$(pwd -P)"
    git_marker="$workspace_root/.git"

    if [ -d "$git_marker" ]; then
        # A .git DIRECTORY containing its own "commondir" file is
        # indirection Git itself follows (the same marker a worktree admin
        # dir uses) — Git resolves hooks under whatever commondir actually
        # points to, so trusting $git_marker/hooks directly here would
        # install into the wrong location entirely. Same shape, same
        # non-worktree-indirection skip, as post-create-common.sh's own
        # resolve_git_dir (#1241 integration round 3, Codex finding
        # 4056166565; mirrored here for hook installation in integration
        # round 5, Codex finding 4056410777).
        if [ -e "$git_marker/commondir" ]; then
            return 2
        fi
        printf '%s\n' "$git_marker"
        return 0
    fi

    admin_dir="$(git -c safe.directory="$workspace_root" -C "$workspace_root" \
        rev-parse --path-format=absolute --git-dir 2>/dev/null)" || return 1
    [ -n "$admin_dir" ] || return 1
    git_dir="$(git -c safe.directory="$workspace_root" -C "$workspace_root" \
        rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
    [ -n "$git_dir" ] || return 1

    if [ "$admin_dir" = "$git_dir" ]; then
        return 2
    fi

    [ "$(dirname "$admin_dir")" = "$git_dir/worktrees" ] || return 1
    reverse_pointer="$(cat "$admin_dir/gitdir" 2>/dev/null)" || return 1
    # cr="$(printf '\r')" + "${var%"$cr"}" (rather than the $'\r' ANSI-C-
    # quoted form): the same trailing-CR strip mirrored from
    # post-create-common.sh's resolve_git_dir, with no shell-specific
    # quoting syntax in it (#1241 integration round 4, Gemini findings
    # re-raising this as non-POSIX after it was already declined on those
    # grounds).
    cr="$(printf '\r')"
    reverse_pointer="${reverse_pointer%"$cr"}"
    reverse_pointer_resolved="$(resolve_relative_to "$admin_dir" "$reverse_pointer")" || return 1
    [ "$reverse_pointer_resolved" = "$git_marker" ] || return 1

    printf '%s\n' "$git_dir"
}

# Install repo-managed git hooks (source of truth: .devcontainer/hooks/).
# This replaces the default git-lfs hooks with versions that also handle
# auto-installing node_modules in new worktrees. Only these named hooks are
# copied or chmodded; Git's sample hooks are left untouched.
install_repo_managed_hooks() {
    local hook hook_name target hooks_dir hooks_common_dir hooks_status

    [ -d .devcontainer/hooks ] || return 0
    # The exit status is consumed by this `if` (not a bare assignment) so
    # that `set -e` does not abort here on resolve_hooks_common_dir's
    # deliberate `return 2` — the same set -e gotcha fixed in
    # post-create-common.sh's reconcile_workspace_permissions for the
    # identical shape (#1241 review round 2, finding F22).
    if hooks_common_dir="$(resolve_hooks_common_dir)"; then
        hooks_status=0
    else
        hooks_status=$?
    fi
    if [ "$hooks_status" -eq 2 ]; then
        echo "NOTE: this workspace's .git is non-worktree indirection (a submodule or a --separate-git-dir checkout) — skipping repo-managed hook installation for it. This is a known, intentional non-goal: see docs/guides/devcontainers.md." >&2
        return 0
    elif [ "$hooks_status" -ne 0 ]; then
        echo "ERROR: could not validate this workspace's Git common directory — refusing to install hooks into an unverified location" >&2
        return 1
    fi
    # .git is a FILE, not a directory, in a linked worktree —
    # resolve_hooks_common_dir (which ran the same validation
    # post-create-common.sh already trusted) resolves this correctly;
    # hardcoding ".git/hooks" as a path segment would make `cp` fail ("Not a
    # directory") and abort the whole script under set -e (review round 1,
    # finding F20).
    hooks_dir="$hooks_common_dir/hooks"
    mkdir -p "$hooks_dir"
    echo "==> Installing git hooks from .devcontainer/hooks/..."
    for hook in .devcontainer/hooks/*; do
        [ -f "$hook" ] || continue
        hook_name="$(basename "$hook")"
        target="$hooks_dir/$hook_name"
        cp "$hook" "$target"
        chmod +x "$target"
    done
}
install_repo_managed_hooks
