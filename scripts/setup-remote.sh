#!/usr/bin/env bash
# setup-remote.sh — prepare THIS checkout for the dev loop on a remote platform.
#
# A devcontainer does this in post-create/post-start; remote platforms (Claude
# Code on the web, Codex cloud, ...) run neither. A remote-only SessionStart
# hook runs this task on the web; other sessions run `task setup:remote` once. Every step is idempotent and
# a safe no-op when already done:
#
#   1. lefthook install     so the pre-commit / commit-msg / pre-push gates run
#   2. related repos        .devcontainer/related-repos.txt cloned beside this
#                           checkout (its PARENT directory), then fetched forward
#                           by the same scripts the devcontainer uses
#   3. frozen dependencies  pnpm-lock.yaml -> pnpm, uv.lock -> uv (only for a
#                           lockfile that exists; none is a no-op)
#
# Never prompts (git: GIT_TERMINAL_PROMPT=0 and, unless GIT_SSH_COMMAND is already set,
# ssh BatchMode; pnpm: CI=true). A step whose tool is missing is reported as skipped; the exit
# status is non-zero only when a step that could run failed. A related repo that
# cannot be cloned or fetched is a warning, not a failure.
set -euo pipefail

# -P: the PHYSICAL path, so a checkout entered through a symlink still clones its
# siblings beside the real checkout rather than beside the symlink.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT"

# Never prompt or hang on missing credentials or behind egress filters.
export GIT_TERMINAL_PROMPT=0
# GIT_TERMINAL_PROMPT does not govern ssh: an ssh remote (git@host:owner/repo.git)
# could otherwise prompt for an unknown host key or a passphrase. BatchMode makes
# ssh fail instead. A caller's own GIT_SSH_COMMAND is left alone.
if [ -z "${GIT_SSH_COMMAND+x}" ]; then
    export GIT_SSH_COMMAND="ssh -oBatchMode=yes"
fi
unset NODE_OPTIONS

did=""
skipped=""
failed=""
warnings=""

note_did() { did="${did}  + $1"$'\n'; }
# Routine no-op steps are listed for context without degrading preparation.
note_not_applicable() { skipped="${skipped}  - $1"$'\n'; }
note_skipped() {
    note_not_applicable "$1"
    case "$warnings" in
    *'skipped steps'*) ;;
    *) note_warning "skipped steps (see stderr details)" ;;
    esac
}
note_failed() { failed="${failed}  ! $1"$'\n'; }
note_warning() { warnings="${warnings}${warnings:+, }$1"; }

# The sibling scripts intentionally return 0 after warning. Preserve their
# details on stderr and retain a short step label for the hook's stdout summary.
run_sibling_step() {
    local label="$1" output
    shift
    if output="$("$@" 2>&1)"; then
        note_did "$label (warn-only)"
    else
        echo "==> WARNING: ${label} could not run; continuing." >&2
        note_failed "$label"
    fi
    printf '%s\n' "$output" >&2
    case "$output" in
    *WARNING:*) note_warning "${label%% ->*}" ;;
    esac
}

# run_step <label> <command...> — run it, record the outcome, never abort.
run_step() {
    local label="$1"
    shift
    echo "==> ${label}"
    if "$@"; then
        note_did "$label"
    else
        echo "==> ERROR: ${label} failed" >&2
        note_failed "$label"
    fi
}

echo "==> setup:remote in ${ROOT}"

# --- 1. git hooks ---
# Every config name lefthook itself searches for.
has_lefthook_config=false
for cfg in lefthook.yml lefthook.yaml lefthook.toml lefthook.json \
    .lefthook.yml .lefthook.yaml .lefthook.toml .lefthook.json; do
    if [ -f "$cfg" ]; then
        has_lefthook_config=true
        break
    fi
done
if [ "$has_lefthook_config" = false ]; then
    note_not_applicable "git hooks: no lefthook config in this repository"
elif ! command -v lefthook >/dev/null 2>&1; then
    note_skipped "git hooks: lefthook is not on PATH (no pre-commit/pre-push gate will run; install lefthook, then re-run)"
else
    run_step "lefthook install" lefthook install
fi

# --- 2. related repositories, beside this checkout ---
BOOTSTRAP=".devcontainer/scripts/bootstrap-related-repos.sh"
if [ ! -f .devcontainer/related-repos.txt ]; then
    note_not_applicable "related repos: no .devcontainer/related-repos.txt"
else
    PARENT="$(dirname "$ROOT")"
    # Skipping is deliberate, in preference to the bootstrap's /workspaces sudo chown
    # repair path: setup:remote never takes ownership of a directory it did not
    # create, so that branch is unreachable from here by design.
    if [ ! -f "$BOOTSTRAP" ]; then
        note_skipped "related repos: ${BOOTSTRAP} is not present in this repository"
    elif [ ! -w "$PARENT" ]; then
        echo "==> WARNING: ${PARENT} is not writable; related repos cannot be cloned there." >&2
        note_skipped "related repos: ${PARENT} is not writable"
    else
        echo "==> Related repos are cloned into ${PARENT}"
        echo "    (the target directory must be private to you, or in a sandbox with no other principal that can write"
        echo "    to it: a remote platform's session is, and so is the devcontainer's /workspaces; the bootstrap refuses"
        echo "    only a staging directory inside it that is not)"
        # The bootstrap exits 0 whatever it could not clone (it warns on stderr), so a
        # missing sibling never fails setup; only a crash of the script itself does.
        run_sibling_step "related repos -> ${PARENT}" bash "$BOOTSTRAP" "$PARENT"
    fi
    # Fetch writes to the sibling's Git storage (which may be outside a linked
    # worktree), so the clone destination parent's writability does not govern it.
    FETCH=".devcontainer/scripts/fetch-related-repos.sh"
    if [ -f "$FETCH" ]; then
        run_sibling_step "related-repo fetch -> ${PARENT}" bash "$FETCH" "$PARENT"
    else
        note_skipped "related-repo fetch: ${FETCH} is not present in this repository"
    fi
    echo "==> Sibling repos are reference context. Claude Code on the web only allows pushes to"
    echo "    the session's own repository and branch, so changes to a sibling cannot be pushed from here."
fi

# --- 3. dependencies, frozen to the lockfile ---
if [ -f pnpm-lock.yaml ]; then
    if command -v pnpm >/dev/null 2>&1; then
        # CI=true is forced, whatever was inherited (CI=false would let pnpm prompt, e.g.
        # before purging node_modules): with it pnpm fails instead of prompting.
        run_step "pnpm install --frozen-lockfile" env CI=true pnpm install --frozen-lockfile
    else
        note_skipped "dependencies: pnpm-lock.yaml present but pnpm is not on PATH"
    fi
else
    note_not_applicable "dependencies: no pnpm-lock.yaml"
fi
if [ -f uv.lock ]; then
    if command -v uv >/dev/null 2>&1; then
        run_step "uv sync --frozen" env CI=true uv sync --frozen
    else
        note_skipped "dependencies: uv.lock present but uv is not on PATH"
    fi
else
    note_not_applicable "dependencies: no uv.lock"
fi

# --- summary ---
echo
echo "==> setup:remote summary"
if [ -n "$did" ]; then
    echo "Ran:"
    printf '%s' "$did"
fi
if [ -n "$skipped" ]; then
    echo "Skipped:"
    printf '%s' "$skipped"
fi
if [ -n "$failed" ]; then
    echo "Failed:" >&2
    printf '%s' "$failed" >&2
    exit 1
fi
if [ -n "$warnings" ]; then
    echo "==> setup:remote completed with warnings: ${warnings}"
else
    echo "==> setup:remote completed."
fi
echo "Run 'task verify' to check the checkout."
