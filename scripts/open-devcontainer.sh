#!/usr/bin/env bash
# open-devcontainer.sh — reopen a repo's dev container in one command.
#
# Runs on the CLIENT (your Mac or Linux laptop), NOT inside a container. It
# reads the folder URIs VS Code already remembers and hands the matching one
# back to VS Code, so reattaching through the Dev Containers extension is one
# command instead of connect → Open Folder → Open Recent.
#
#   open-devcontainer.sh               # list the dev-container entries
#   open-devcontainer.sh harmon-init   # launch the one that matches
#
# Deliberately recents-based. A Dev Containers window is described by a folder
# URI of the shape
#     vscode-remote://dev-container+<hex>@<remote-authority>/<path>
# where <hex> is a hex-encoded JSON blob the extension owns and changes between
# versions. Composing one from scratch would be guessing at that schema; the
# recents entry is authoritative. So the FIRST attach to a repo is still the
# manual flow documented in docs/guides/devcontainers.md — that is what creates
# the entry. Every reattach after it is this script.
#
# Dependencies: python3 and the `code` CLI. python3 does BOTH jobs — reading
# VS Code's SQLite state database (stdlib `sqlite3`, opened read-only so a
# running VS Code is never disturbed) and parsing the recents JSON. That is one
# dependency instead of three: python3 ships with the macOS command line tools,
# whereas the sqlite3 CLI and jq are each absent often enough on a client to be
# worth not requiring. `code` is needed only to launch, never to list.
#
# Self-contained on purpose: no `cd` to a repo root, no sibling files, nothing
# read out of a checkout. The repo it ships from lives on the workspace HOST,
# while VS Code's recents and the `code` CLI live on the client — so this is a
# file you copy to the client once and run there, not one you run over SSH.
set -euo pipefail

# The extraction program. Given the database path, it prints one TAB-separated
# `<folderUri>\t<label>` line per dev-container entry, newest first (recents
# order). Exit codes are the failure vocabulary the shell turns into messages:
# 3 = database unreadable, 4 = no recents key, 5 = recents value is not JSON.
PY_EXTRACT=$(
    cat <<'PY'
import hashlib
import json
import sqlite3
import sys
import urllib.parse

KEY = "history.recentlyOpenedPathsList"
PREFIXES = ("vscode-remote://dev-container+", "vscode-remote://dev-container%2b")

try:
    # mode=ro never creates and never writes. quote() is what makes a path with
    # spaces ("Application Support") a legal URI.
    uri = "file:" + urllib.parse.quote(sys.argv[1])
    con = sqlite3.connect(uri + "?mode=ro", uri=True)
    row = con.execute("SELECT value FROM ItemTable WHERE key = ?", (KEY,)).fetchone()
except sqlite3.Error:
    sys.exit(3)

if row is None or row[0] is None or row[0] == "":
    sys.exit(4)

value = row[0]
if isinstance(value, (bytes, bytearray)):
    value = value.decode("utf-8", "replace")

try:
    data = json.loads(value)
except ValueError:
    sys.exit(5)


def config_tail(info):
    """The devcontainer.json this entry was built from, trimmed to its tail.

    This is what tells one PROFILE of a checkout from another: the bot config
    at `.devcontainer/devcontainer.json` and the dev config at
    `.devcontainer/dev/devcontainer.json` produce two recents entries whose
    container path, host path, and remote authority are all identical. Without
    this, they are two indistinguishable lines.
    """
    config = info.get("configFile")
    path = ""
    if isinstance(config, str):
        path = config
    elif isinstance(config, dict) and isinstance(config.get("path"), str):
        # VS Code serializes a URI as {"$mid":…,"path":…,"scheme":…}.
        path = config["path"]
    if not path:
        return ""
    path = urllib.parse.unquote(path)
    marker = "/.devcontainer/"
    at = path.find(marker)
    if at >= 0:
        return path[at + 1:]
    parts = [p for p in path.split("/") if p]
    return "/".join(parts[-2:])


def token_for(folder_uri):
    """A short, stable handle for an entry.

    The discriminator of last resort. Everything else shown on a line is
    decoded out of a blob the extension owns, so two entries CAN come back
    with identical labels — and an ambiguous listing nothing can select is a
    dead end. This is derived from the whole URI, so it always exists, always
    differs between different entries, and does not move between runs.
    """
    return hashlib.sha256(folder_uri.encode("utf-8")).hexdigest()[:8]


def label_for(folder_uri):
    """A human-readable one-liner ending in the entry's selection token."""
    decoded = urllib.parse.unquote(folder_uri)
    rest = decoded.split("://", 1)[1] if "://" in decoded else decoded
    authority, _, path = rest.partition("/")
    blob, _, remote = authority.partition("@")
    hex_blob = blob.split("+", 1)[1] if "+" in blob else ""
    info = {}
    try:
        # The blob is hex-encoded JSON. Any shape we do not recognize simply
        # costs us the extra detail, never the line itself.
        parsed = json.loads(bytes.fromhex(hex_blob).decode("utf-8"))
        if isinstance(parsed, dict):
            info = parsed
    except Exception:
        info = {}
    host_path = info.get("hostPath")
    if not isinstance(host_path, str):
        host_path = ""
    label = "/" + path if path else decoded
    extra = []
    if host_path:
        extra.append("host " + host_path)
    config = config_tail(info)
    if config:
        extra.append("config " + config)
    if remote:
        extra.append(remote)
    if extra:
        label += "  (" + ", ".join(extra) + ")"
    label += "  [" + token_for(folder_uri) + "]"
    # The output is line- and TAB-delimited; never let a label break it.
    return label.replace("\t", " ").replace("\n", " ").replace("\r", " ")


entries = data.get("entries") if isinstance(data, dict) else None
for entry in entries if isinstance(entries, list) else []:
    if not isinstance(entry, dict):
        continue
    folder_uri = entry.get("folderUri")
    if not isinstance(folder_uri, str) or not folder_uri:
        continue
    if not folder_uri.lower().startswith(PREFIXES):
        continue
    sys.stdout.write(folder_uri + "\t" + label_for(folder_uri) + "\n")
PY
)

usage() {
    cat <<'EOF'
Usage: open-devcontainer.sh [<repo-match>]

  (no argument)  list the dev-container entries VS Code remembers
  <repo-match>   case-insensitive substring; a unique match is launched with
                 `code --folder-uri`, several are listed so you can narrow it.
                 Every listed line ends in a short [token] that is also a
                 match target — the way to pick between two entries whose
                 details are identical (the bot and dev profiles of one
                 checkout, say)

Environment:
  VSCODE_STATE_DB            path to VS Code's state.vscdb (default: per-platform)
  CODE_BIN                   the VS Code CLI to launch (default: code)
  PYTHON_BIN                 the Python 3 interpreter to use (default: python3)
  OPEN_DEVCONTAINER_DRY_RUN  1 = print the launch command instead of running it
EOF
}

die() {
    echo "open-devcontainer: $*" >&2
    exit 1
}

manual_flow_hint="open it once via the manual flow — see docs/guides/devcontainers.md (attach paths) — then this launcher can reopen it"

case "${1-}" in
-h | --help)
    usage
    exit 0
    ;;
esac
if [ "$#" -gt 1 ]; then
    usage >&2
    exit 2
fi
match="${1-}"

# ---- locate the state database -------------------------------------------

db="${VSCODE_STATE_DB-}"
if [ -z "$db" ]; then
    case "$(uname -s)" in
    Darwin) db="${HOME}/Library/Application Support/Code/User/globalStorage/state.vscdb" ;;
    # VS Code honours XDG_CONFIG_HOME on Linux, so hardcoding ~/.config would
    # miss the database on any client that sets it.
    Linux) db="${XDG_CONFIG_HOME:-${HOME}/.config}/Code/User/globalStorage/state.vscdb" ;;
    *) die "unsupported platform '$(uname -s)' — set VSCODE_STATE_DB to VS Code's state.vscdb" ;;
    esac
fi
[ -f "$db" ] || die "no VS Code state database at ${db} — run VS Code on this machine once, or set VSCODE_STATE_DB"

# ---- read it --------------------------------------------------------------

python_bin="${PYTHON_BIN:-python3}"
# One probe covers both "not installed" and macOS's python3 shim, which exists
# on PATH but only prints an install prompt until the command line tools are.
if ! command -v "$python_bin" >/dev/null 2>&1 || ! "$python_bin" -c 'import json, sqlite3' >/dev/null 2>&1; then
    die "no working python3 (tried '${python_bin}') — install it (macOS: xcode-select --install; Debian/Ubuntu: apt-get install python3) or set PYTHON_BIN"
fi

set +e
extracted="$("$python_bin" -c "$PY_EXTRACT" "$db" 2>/dev/null)"
rc=$?
set -e
case "$rc" in
0) ;;
3) die "could not read ${db} — is it VS Code's state.vscdb?" ;;
4) die "no recently-opened list in ${db} — open a folder in VS Code first" ;;
5) die "VS Code's recently-opened list in ${db} is not valid JSON" ;;
*) die "failed to read ${db} (extractor exit ${rc})" ;;
esac

# Arrays here are written by INDEX and read by index, never with `[@]` and
# never through `${#arr[@]}`, with an ordinary integer carrying the count.
# That is not a style preference. bash 3.2 — still the /bin/bash on macOS,
# the client this script is written for — does not create a variable for
# `arr=()`, so under `set -u` EVERY expansion of a still-empty array, the
# length included, aborts with "arr: unbound variable". The empty case is
# exactly the one that must survive: "recents exist, but none of them is a
# dev container" and "nothing matched" are the two paths whose whole job is to
# print a helpful message. Counters have no such edge, on any bash.
uris=()
labels=()
count=0
while IFS=$'\t' read -r uri label; do
    [ -n "$uri" ] || continue
    uris[count]="$uri"
    labels[count]="$label"
    count=$((count + 1))
done <<<"$extracted"

if [ "$count" -eq 0 ]; then
    die "no dev-container entries in VS Code's recents — ${manual_flow_hint}"
fi

# ---- list, or match and launch --------------------------------------------

if [ -z "$match" ]; then
    echo "dev containers VS Code remembers (pass a substring or a [token] to open one):" >&2
    for ((i = 0; i < count; i++)); do
        printf '%s\n' "${labels[i]}"
    done
    exit 0
fi

needle="$(printf '%s' "$match" | tr '[:upper:]' '[:lower:]')"
hits=()
hit_count=0
for ((i = 0; i < count; i++)); do
    # Matched against the LABEL, not the raw URI: the URI's hex blob is a long
    # run of [0-9a-f] in which a short all-hex needle ("added", "cafe") would
    # match nothing meaningful. The label carries the entry's token, so a
    # token is matched by this same pass and needs no special case.
    haystack="$(printf '%s' "${labels[i]}" | tr '[:upper:]' '[:lower:]')"
    case "$haystack" in
    *"$needle"*)
        hits[hit_count]="$i"
        hit_count=$((hit_count + 1))
        ;;
    esac
done

if [ "$hit_count" -eq 0 ]; then
    die "no dev-container entry matching '${match}' — ${manual_flow_hint}"
fi

if [ "$hit_count" -gt 1 ]; then
    echo "open-devcontainer: '${match}' matches ${hit_count} entries — narrow by name, or use the [token] at the end of a line:" >&2
    for ((i = 0; i < hit_count; i++)); do
        printf '%s\n' "${labels[${hits[i]}]}" >&2
    done
    exit 1
fi

target="${uris[${hits[0]}]}"
code_bin="${CODE_BIN:-code}"

if [ "${OPEN_DEVCONTAINER_DRY_RUN-}" = "1" ]; then
    printf '%s --folder-uri %s\n' "$code_bin" "$target"
    exit 0
fi

command -v "$code_bin" >/dev/null 2>&1 ||
    die "'${code_bin}' not found on PATH — in VS Code run the command palette's \"Shell Command: Install 'code' command in PATH\" (or set CODE_BIN)"

exec "$code_bin" --folder-uri "$target"
