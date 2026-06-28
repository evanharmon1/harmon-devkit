#!/usr/bin/env bash
set -euo pipefail

# Redirect all output to a log file to avoid SIGPIPE when VS Code
# disconnects the pipe before the script finishes.
exec &>/tmp/devcontainer-post-start.log

bash .devcontainer/scripts/post-start-common.sh
