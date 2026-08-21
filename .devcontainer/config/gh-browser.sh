#!/usr/bin/env bash
# Open GitHub CLI authentication links on the devcontainer host when possible.
# GH_BROWSER points here only in the human profile. Do not fall back to generic
# browser discovery: the image contains terminal browsers that trap the device
# flow inside the container.

set -u

url="${1:-}"
if [ -z "$url" ]; then
    echo "gh-browser: no URL was provided" >&2
    exit 1
fi

if command -v code >/dev/null 2>&1; then
    code_path="$(command -v code)"
    code_path="$(readlink -f "$code_path")"
    remote_browser="$(dirname "$(dirname "$code_path")")/helpers/browser.sh"

    if [ -x "$remote_browser" ]; then
        remote_output="$("$remote_browser" "$url" 2>&1)"
        remote_status=$?
        [ -z "$remote_output" ] || printf '%s\n' "$remote_output" >&2
        # The remote CLI has returned exit 0 alongside protocol errors, and
        # its error prose is not an API. Only silent success proves handoff;
        # any diagnostic falls through to the actionable URL.
        if [ "$remote_status" -eq 0 ] && [ -z "$remote_output" ]; then
            exit 0
        fi
    fi

    # Desktop CLIs expose --open-url, while the remote CLI may accept and
    # ignore it with exit 0. Check the advertised capability before using it.
    if code --help 2>&1 | grep -q -- '--open-url'; then
        if code --open-url "$url"; then
            exit 0
        fi
    fi

    echo "gh-browser: VS Code could not open the URL on the host." >&2
fi

printf 'Open this URL in your browser:\n%s\n' "$url" >&2
