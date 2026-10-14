#!/usr/bin/env bash
set -euo pipefail

# Clone "related" repos listed in .devcontainer/related-repos.txt into
# /workspaces/ (or the directory given as the first argument), adjacent to the
# main repo. Idempotent and NON-DESTRUCTIVE: if a
# target dir already exists it is left completely untouched (no fetch, no pull,
# no checkout, no warning) — fetching is fetch-related-repos.sh's job at start.
#
# Usage: bootstrap-related-repos.sh [TARGET_DIR]
#   TARGET_DIR (optional) is the directory the siblings are cloned into; an
#   argument wins over WORKSPACES_DIR, which wins over the /workspaces default.
#   `task setup:remote` passes the checkout's parent directory so a remote
#   platform (which has no /workspaces) gets the same siblings the devcontainer
#   does, and so does `task setup:gh-scopes` (its scope-refresh trigger). The
#   devcontainer's lifecycle call sites (post-create, post-start) pass nothing
#   and still target /workspaces.
#
# Runs on devcontainer create (post-create-common.sh), on devcontainer start
# (post-start-common.sh in background), and upon scope verification in
# setup-gh-scopes.sh, so a rebuilt, persistence-lost, or newly authenticated
# container re-clones any sibling that is missing.
#
# Config format (.devcontainer/related-repos.txt):
#   owner/repo                       # default branch, cloned via gh CLI or git fallback
#   owner/repo@branch                # specific branch
#   https://github.com/owner/repo    # full URL (also supports .git suffix)
#   git@github.com:owner/repo.git    # ssh URL
#
# Lines starting with # are comments. Blank lines are ignored.
#
# Every temporary clone directory lives in ONE dedicated subdirectory of the target
# (<target>/.related-repos-bootstrap, mode 0700), and the orphan sweeps run only
# inside it. The target is a general-purpose directory when `task setup:remote`
# passes a checkout's parent ($HOME, /tmp, ...), so nothing outside that
# subdirectory is ever removed. The (empty) subdirectory is left in place: removing
# it would race a concurrent bootstrap between its mkdir and mktemp.
# Trust boundary: the ownership/mode checks on that subdirectory are pathname-based,
# so the TARGET directory must itself be private to the invoking user, or live in a
# sandbox with no other principal that can write to it (a remote platform's session
# is; the devcontainer's /workspaces is). In a shared, world-writable, non-sticky
# parent another user could rename the subdirectory away after the checks or
# pre-create a final target, which no check here can defend. The chmod 700 after the
# mkdir follows a symlink, so a swap inside that window is the same undefendable
# case (the mode check below refuses a swapped-in symlink whose own mode is
# world-writable). The script refuses only a staging directory that is not private.
#
# Failures (missing config, bad URL, network errors) log a warning and
# continue — a failure never produces a non-zero exit, so it never causes
# post-create, post-start, or scope setup to fail. A signal (INT/TERM/HUP) is
# not a failure: it terminates the script with the signal's exit status after
# cleanup, which in the foreground post-create call correctly aborts create.
#
# Environment variable overrides (for tests and host customization):
#   CONFIG_FILE                  Path to related-repos.txt (default: ../related-repos.txt)
#   WORKSPACES_DIR               Destination parent directory (default: /workspaces;
#                                the TARGET_DIR argument takes precedence)
#   RELATED_REPOS_GIT_BASE_URL   Base URL for git clone fallback (default: https://${GH_HOST}/, else the host of
#                                this repo's origin remote, else https://github.com/)
#   RELATED_REPOS_MV_ATOMIC      Force atomic publish (1 = GNU mv -T, 0 = non-GNU detect-and-undo)

# Prevent VS Code's JS debug bootloader from breaking child Node processes
# spawned by gh. See post-create-common.sh for the full explanation.
unset NODE_OPTIONS

# Never prompt or hang on missing credentials or behind egress filters.
export GIT_TERMINAL_PROMPT=0

clone_tmp=""
cleanup() {
    if [ -n "${clone_tmp:-}" ] && [ -d "$clone_tmp" ]; then
        rm -rf "$clone_tmp" || true
    fi
}
# Signals must TERMINATE the script, not just run cleanup: a trap handler that
# returns swallows the signal and the clone loop would carry on. Exiting from the
# signal trap fires the EXIT trap exactly once, which does the cleanup.
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-${SCRIPT_DIR}/../related-repos.txt}"
WORKSPACES_DIR="${1:-${WORKSPACES_DIR:-/workspaces}}"
# Normalize once (one trailing slash, unless the value is exactly "/") so the staging
# directory, the clone targets and the /workspaces check all derive from one value.
case "$WORKSPACES_DIR" in
/) ;;
*/) WORKSPACES_DIR="${WORKSPACES_DIR%/}" ;;
esac

if [ -n "${RELATED_REPOS_GIT_BASE_URL:-}" ]; then
    GIT_BASE_URL="${RELATED_REPOS_GIT_BASE_URL}"
elif [ -n "${GH_HOST:-}" ]; then
    GIT_BASE_URL="https://${GH_HOST}/"
else
    # No override: an Enterprise checkout usually has no GH_HOST but its origin
    # remote names the host. This derives a CLONE base URL (local, network-free),
    # which is why it keeps the port of an http(s) origin: a server on :8443 is
    # cloned from :8443. scripts/gh-scopes.sh's gh_target_host() resolves a gh
    # HOSTNAME instead, which is portless, so this is not a copy of that function.
    # github.com is the last resort when there is no origin to read.
    origin_url="$(git -C "${SCRIPT_DIR}/.." config --get remote.origin.url 2>/dev/null || true)"
    origin_authority=""
    # git's rule (transport_get): <transport>::<address> is remote-helper syntax only
    # when what precedes the first '::' is a URL scheme: an alphanumeric first
    # character, then alphanumerics or '+', '-', '.'. Any other '::' (an scp-like
    # path such as host:owner/repo::backup, or +demo::path) is not one.
    origin_helper=""
    case "${origin_url}" in
    *::*)
        case "${origin_url%%::*}" in
        "" | [!A-Za-z0-9]* | *[!A-Za-z0-9+.-]*) ;;
        *) origin_helper=1 ;;
        esac
        ;;
    esac
    # A remote-helper origin (gitremote-helpers(7)) names no host in ANY arm below,
    # whatever it carries after the '::' (even a scheme://), so it keeps github.com.
    if [ -z "${origin_helper}" ]; then
        case "${origin_url}" in
        *://*) # scheme://[user@]host[:port]/path
            origin_authority="${origin_url#*://}"
            origin_authority="${origin_authority%%/*}" # the path first: it may contain '@'
            origin_authority="${origin_authority##*@}" # then any userinfo
            case "${origin_url}" in
            http://* | https://*) ;;                         # the port is the web port: keep it
            *) origin_authority="${origin_authority%%:*}" ;; # ssh:// etc: the port is not the https port
            esac
            ;;
        *:*) # scp-like [user@]host:path (no port; the colon starts the path) — git's rule: no '/' before the first colon
            origin_authority="${origin_url%%:*}"
            case "${origin_authority}" in
            \[* | *@\[*)                              # a bracketed (IPv6) host: the first colon is inside the brackets, so take [host] whole
                origin_authority="${origin_url%%\[*}" # '' or 'user@': the part before the bracket
                case "${origin_authority}" in
                */*) origin_authority="" ;; # a local path
                *)
                    origin_authority="${origin_url#"${origin_authority}"}"
                    case "${origin_authority}" in
                    \[?*\]:*) origin_authority="${origin_authority%%\]:*}]" ;; # the brackets stay in the HTTPS authority
                    *) origin_authority="" ;;                                  # no matching ']:' — not a usable host
                    esac
                    case "${origin_authority}" in
                    */*) origin_authority="" ;;
                    esac
                    ;;
                esac
                ;;
            */* | ?) origin_authority="" ;; # a local path, or a drive letter (C:/…)
            *) origin_authority="${origin_authority##*@}" ;;
            esac
            ;;
        esac
    fi
    GIT_BASE_URL="https://${origin_authority:-github.com}/"
fi

if [ -n "${RELATED_REPOS_MV_ATOMIC:-}" ]; then
    case "$RELATED_REPOS_MV_ATOMIC" in
    0 | 1)
        MV_ATOMIC="$RELATED_REPOS_MV_ATOMIC"
        ;;
    *)
        echo "==> WARNING: invalid RELATED_REPOS_MV_ATOMIC='${RELATED_REPOS_MV_ATOMIC}' (expected 0 or 1); ignoring override." >&2
        if mv --version >/dev/null 2>&1; then
            MV_ATOMIC=1
        else
            MV_ATOMIC=0
        fi
        ;;
    esac
elif mv --version >/dev/null 2>&1; then
    MV_ATOMIC=1
else
    MV_ATOMIC=0
fi

# --- Pre-flight checks ---

if [ ! -f "$CONFIG_FILE" ]; then
    echo "==> No related-repos.txt found at ${CONFIG_FILE}; skipping."
    exit 0
fi

if [ ! -d "$WORKSPACES_DIR" ]; then
    echo "==> WARNING: ${WORKSPACES_DIR} does not exist; skipping related-repo bootstrap." >&2
    exit 0
fi

# /workspaces is owned by root in the devcontainer image — VS Code only fixes
# ownership on the workspace folder itself, not its parent. Make it writable
# by vscode so subsequent `git clone` calls can create sibling directories.
# Idempotent: chown is a no-op if ownership already matches.
if [ "$WORKSPACES_DIR" = "/workspaces" ] && [ ! -w "$WORKSPACES_DIR" ]; then
    if command -v sudo >/dev/null 2>&1; then
        sudo chown vscode:vscode "$WORKSPACES_DIR" || true
    fi
fi

# --- Dedicated staging directory ---
# All temporary clone directories (and the sweeps below) live here and nowhere else
# under the target. A symlink, a non-directory, a directory owned by someone else or
# one that is group/world-writable is never used or replaced: skip rather than sweep
# or clone through it.
STAGE_DIR="${WORKSPACES_DIR}/.related-repos-bootstrap"
if [ -L "$STAGE_DIR" ] || { [ -e "$STAGE_DIR" ] && [ ! -d "$STAGE_DIR" ]; }; then
    echo "==> WARNING: ${STAGE_DIR} exists and is not a plain directory; skipping related-repo bootstrap." >&2
    exit 0
fi
if [ ! -d "$STAGE_DIR" ]; then
    # chmod as well as umask: a default ACL on the parent can override the umask.
    if ! (umask 077 && mkdir -p "$STAGE_DIR" && chmod 700 "$STAGE_DIR") 2>/dev/null; then
        echo "==> WARNING: could not create ${STAGE_DIR}; skipping related-repo bootstrap." >&2
        exit 0
    fi
fi
# Trust it only if it is ours and private: on a shared host with a world-writable
# parent another user could pre-create it, then swap a finished clone before the
# atomic publish. No fallback to another path: skip.
if [ ! -O "$STAGE_DIR" ]; then
    echo "==> WARNING: ${STAGE_DIR} is not owned by the current user; remove it and re-run, or run as its owner; skipping related-repo bootstrap." >&2
    exit 0
fi
if [ -n "$(find "$STAGE_DIR" -maxdepth 0 \( -perm -g+w -o -perm -o+w \) -print 2>/dev/null)" ]; then
    echo "==> WARNING: ${STAGE_DIR} is group- or world-writable; skipping related-repo bootstrap." >&2
    exit 0
fi

# --- Clean up orphaned temporary directories ---
# Unconditionally sweep temporary bootstrap directories older than 24 hours (1440 min)
# regardless of PID, protecting persisted workspaces from accumulated orphans across restarts.
# Only inside STAGE_DIR: a foreign .bootstrap-* directory in the target is not ours.
while IFS= read -r stale_dir; do
    [ -n "$stale_dir" ] || continue
    echo "==> Removing stale temporary bootstrap directory: ${stale_dir} (older than 24h)"
    rm -rf "$stale_dir" || true
done < <(find "$STAGE_DIR" -maxdepth 1 -name '.bootstrap-*' -type d -mmin +1440 2>/dev/null || true)

# Remove leftover .bootstrap-* directories older than 60 minutes from runs whose
# process is no longer alive. Directories with an active PID or unparseable name
# are left alone.
while IFS= read -r orphan_dir; do
    [ -n "$orphan_dir" ] || continue
    dir_name="${orphan_dir##*/}"
    remainder="${dir_name#.bootstrap-}"
    [ "$remainder" != "$dir_name" ] || continue
    prefix="${remainder%.*}"
    [ "$prefix" != "$remainder" ] || continue
    pid="${prefix##*.}"
    case "$pid" in
    '' | *[!0-9]*)
        continue
        ;;
    *)
        if ! kill -0 "$pid" 2>/dev/null; then
            echo "==> Removing orphaned temporary bootstrap directory: ${orphan_dir} (dead PID: ${pid})"
            rm -rf "$orphan_dir" || true
        fi
        ;;
    esac
done < <(find "$STAGE_DIR" -maxdepth 1 -name '.bootstrap-*' -type d -mmin +60 2>/dev/null || true)

# --- Parse and clone ---

cloned=0
skipped=0
failed=0

while IFS= read -r raw_line || [ -n "$raw_line" ]; do
    # Strip inline comments (everything from the first # onward), then trim
    # leading and trailing whitespace.
    line="${raw_line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"

    # Skip blank lines (and lines that were comment-only).
    [ -z "$line" ] && continue

    # Split optional @branch suffix. Only split on the LAST @ so ssh URLs
    # like git@github.com:o/r.git are not mangled — those URLs always end
    # in .git, so a trailing @branch on the same line is unambiguous.
    branch=""
    target_spec="$line"
    if [[ "$line" == *"@"* ]]; then
        suffix="${line##*@}"
        # Treat the suffix as a branch only if it doesn't look like a host
        # (no dots, no colons, no slashes). This keeps `git@github.com:...`
        # intact while still splitting `owner/repo@feature/foo` correctly
        # only when the user wrote a plain branch name.
        if [[ "$suffix" != *.* && "$suffix" != *:* && "$suffix" != */* ]]; then
            branch="$suffix"
            target_spec="${line%@*}"
        fi
    fi

    # Derive the target basename.
    #   owner/repo                  -> repo
    #   https://host/owner/repo.git -> repo
    #   git@host:owner/repo.git     -> repo
    basename_raw="${target_spec##*/}"  # strip everything up to last /
    basename_raw="${basename_raw##*:}" # strip ssh "host:" prefix if any
    basename="${basename_raw%.git}"    # strip optional .git

    if [ -z "$basename" ]; then
        echo "==> WARNING: could not derive directory name for entry '${raw_line}'; skipping." >&2
        failed=$((failed + 1))
        continue
    fi

    target="${WORKSPACES_DIR}/${basename}"

    if [ -e "$target" ]; then
        echo "==> Skipping ${basename} (already present at ${target})"
        skipped=$((skipped + 1))
        continue
    fi

    # Clone into a private temporary directory first. Never clone into $target
    # directly: if a user or concurrent process creates $target in between,
    # cleaning up a failed clone must never remove the user's checkout.
    clone_tmp=""
    if ! clone_tmp="$(mktemp -d "${STAGE_DIR}/.bootstrap-${basename}.$$.XXXXXX" 2>&1)"; then
        echo "==> WARNING: failed to create temporary directory for ${target_spec}: ${clone_tmp}" >&2
        clone_tmp="" # mktemp's error text is not a path; keep the EXIT trap unarmed
        failed=$((failed + 1))
        continue
    fi

    # Decide whether to use gh (for owner/repo shorthand) or git (for URLs).
    use_gh=false
    if [[ "$target_spec" != *://* && "$target_spec" != *@*:* && "$target_spec" == */* ]]; then
        use_gh=true
    fi

    branch_label="${branch:-default branch}"
    echo "==> Cloning ${target_spec} (${branch_label}) -> ${target}"

    clone_rc=1
    if [ "$use_gh" = true ]; then
        gh_auth=false
        if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
            gh_auth=true
        fi

        if [ "$gh_auth" = true ]; then
            set +e
            if [ -n "$branch" ]; then
                gh repo clone "$target_spec" "$clone_tmp" -- --branch "$branch" --quiet
            else
                gh repo clone "$target_spec" "$clone_tmp" -- --quiet
            fi
            clone_rc=$?
            set -e

            if [ "$clone_rc" -ne 0 ]; then
                echo "==> WARNING: gh repo clone failed for ${target_spec} (exit ${clone_rc}); falling back to git clone." >&2
                rm -rf "$clone_tmp" || true
                clone_tmp=""
                if ! clone_tmp="$(mktemp -d "${STAGE_DIR}/.bootstrap-${basename}.$$.XXXXXX" 2>&1)"; then
                    echo "==> WARNING: failed to create temporary directory for ${target_spec} fallback: ${clone_tmp}" >&2
                    clone_tmp="" # mktemp's error text is not a path; keep the EXIT trap unarmed
                    failed=$((failed + 1))
                    continue
                fi
            fi
        else
            echo "==> gh is unauthenticated; falling back to git clone for ${target_spec}"
        fi

        if [ "$clone_rc" -ne 0 ]; then
            fallback_url="${GIT_BASE_URL%/}/${target_spec}.git"
            set +e
            if [ -n "$branch" ]; then
                git clone --quiet --branch "$branch" "$fallback_url" "$clone_tmp"
            else
                git clone --quiet "$fallback_url" "$clone_tmp"
            fi
            clone_rc=$?
            set -e
        fi
    else
        set +e
        if [ -n "$branch" ]; then
            git clone --quiet --branch "$branch" "$target_spec" "$clone_tmp"
        else
            git clone --quiet "$target_spec" "$clone_tmp"
        fi
        clone_rc=$?
        set -e
    fi

    if [ "$clone_rc" -eq 0 ]; then
        # Publish into the target path. Inside the Linux devcontainer GNU coreutils
        # mv -T provides an atomic rename that fails safely without nesting if $target
        # already exists as a non-empty directory or file. On platforms without GNU mv
        # (e.g. macOS during host-side testing), fall back to a guarded check and mv,
        # with detect-and-undo if a directory appeared concurrently.
        set +e
        publish_err=""
        if [ "$MV_ATOMIC" -eq 1 ]; then
            publish_err="$(mv -T "$clone_tmp" "$target" 2>&1 >/dev/null)"
            publish_rc=$?
        else
            [ ! -e "$target" ] && publish_err="$(mv "$clone_tmp" "$target" 2>&1 >/dev/null)"
            publish_rc=$?
            nested_tmp="${target}/$(basename "$clone_tmp")"
            if [ "$publish_rc" -eq 0 ] && [ -e "$nested_tmp" ]; then
                # Target was created concurrently after the [ ! -e "$target" ] check,
                # causing BSD/fallback mv to nest $clone_tmp inside $target.
                # Detect and undo: remove only our own nested temporary directory,
                # leaving everything else under $target untouched.
                rm -rf "$nested_tmp" || true
                publish_rc=1
            fi
        fi
        set -e

        if [ "$publish_rc" -eq 0 ]; then
            cloned=$((cloned + 1))
            clone_tmp=""
        elif [ -e "$target" ]; then
            echo "==> Skipping ${basename} (destination ${target} appeared concurrently or already exists)"
            skipped=$((skipped + 1))
            rm -rf "$clone_tmp" || true
            clone_tmp=""
        else
            echo "==> WARNING: failed to publish ${basename} to ${target} (exit ${publish_rc})${publish_err:+: ${publish_err}}; continuing." >&2
            failed=$((failed + 1))
            rm -rf "$clone_tmp" || true
            clone_tmp=""
        fi
    else
        echo "==> WARNING: failed to clone ${target_spec} (exit ${clone_rc}); continuing." >&2
        failed=$((failed + 1))
        rm -rf "$clone_tmp" || true
        clone_tmp=""
    fi
done <"$CONFIG_FILE"

# --- Summary ---

total=$((cloned + skipped + failed))
if [ "$total" -eq 0 ]; then
    echo "==> No repos configured in ${CONFIG_FILE}; nothing to do."
else
    echo "==> Bootstrap complete: ${cloned} cloned, ${skipped} skipped, ${failed} failed"
fi

# Failures are logged and never produce a non-zero exit, so they never block
# post-create; only a signal (trapped above) terminates with a non-zero status.
exit 0
