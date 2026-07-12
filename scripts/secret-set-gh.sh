#!/usr/bin/env bash
# Set a GitHub repository secret from stdin without passing the secret in shell
# history, environment variables, or process arguments.
set -euo pipefail

fail() {
    echo "secret:set:gh: $*" >&2
    exit 1
}

usage() {
    cat >&2 <<'USAGE'
Usage:
  secret-producing-command | task secret:set:gh NAME=<secret-name> REPO=<owner/repo>

The secret value is read from stdin. NAME and REPO identify the GitHub
repository secret to create or update.
USAGE
}

name="${NAME:-}"
repo="${REPO:-}"

if [ -z "$name" ] || [ -z "$repo" ]; then
    usage
    fail "NAME and REPO are required"
fi

if [ -t 0 ]; then
    usage
    fail "secret must be piped on stdin"
fi

command -v gh >/dev/null 2>&1 || fail "gh CLI is required"
command -v python3 >/dev/null 2>&1 || fail "python3 is required"

# Read + validate stdin BEFORE gh runs: in a plain pipeline, `gh secret set`
# starts consuming stdin before the producer's empty-check can fail, so an
# empty pipe could write an empty secret and only error afterwards. python3 is
# already the scripts' one interpreter dependency (lint-hygiene.sh). The value
# stays out of argv and the environment: command substitution + the printf
# builtin never surface it in a process listing.
secret="$(python3 -c '
import sys
data = sys.stdin.buffer.read()
if data.endswith(b"\r\n"):
    data = data[:-2]
elif data.endswith(b"\n"):
    data = data[:-1]
if not data:
    sys.exit("stdin secret is empty")
sys.stdout.buffer.write(data)
')" || fail "stdin secret is empty"

printf '%s' "$secret" | gh secret set "$name" --repo "$repo" >/dev/null

echo "Updated GitHub secret '$name' in '$repo'."
