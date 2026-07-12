#!/usr/bin/env bash
# ingest-design.sh — safely extract a Claude Design handoff bundle into specs/.
#
# Called by `task ingest:design` (Taskfile.design.yml), which passes BUNDLE and
# DEST through the ENVIRONMENT — never spliced into shell source — so a path
# like "x.tar.gz; rm -rf ~" stays an (invalid) filename and paths with spaces
# survive. The design-handoff skill copies this to scripts/ (chmod +x).
#
# The archive is UNTRUSTED input: entries are listed and validated before
# extraction. Absolute paths, ../ traversal, and link entries (symlink/hardlink,
# which can redirect later writes outside DEST) are rejected — the tar/zip-slip
# class of attack. Archive type is selected by validated extension: .tar.gz/.tgz
# or .zip (see references/ingesting-the-bundle.md on telling the coding handoff
# apart from the raw-assets .zip export).
#
# USAGE: BUNDLE=<bundle> [DEST=specs] ingest-design.sh
set -euo pipefail

bundle="${BUNDLE:?ingest-design: set BUNDLE to the handoff archive path}"
dest="${DEST:-specs}"

if [ ! -f "$bundle" ]; then
    echo "ingest-design: bundle not found: $bundle" >&2
    exit 1
fi

case "$bundle" in
*.tar.gz | *.tgz) kind=tar ;;
*.zip) kind=zip ;;
*)
    echo "ingest-design: unsupported bundle type: $bundle (expected .tar.gz, .tgz, or .zip)" >&2
    exit 1
    ;;
esac

# List entries without extracting. For tar, the verbose listing also exposes
# link entries ("->"); unzip -Z1 prints bare member paths (zip links are rare
# and the path checks below still bound where they can land).
if [ "$kind" = tar ]; then
    if tar -tzvf "$bundle" | grep -E ' -> ' >/dev/null; then
        echo "ingest-design: refusing to extract — archive contains link entries:" >&2
        tar -tzvf "$bundle" | grep -E ' -> ' >&2
        exit 1
    fi
    paths=$(tar -tzf "$bundle") # non-verbose: one full path per line, spaces intact
else
    paths=$(unzip -Z1 "$bundle")
fi

# Reject absolute paths and any ../ component (zip-slip / tar-slip).
if printf '%s\n' "$paths" | grep -E '^/|(^|/)\.\.(/|$)' >/dev/null; then
    echo "ingest-design: refusing to extract — unsafe entry paths (absolute or ..):" >&2
    printf '%s\n' "$paths" | grep -E '^/|(^|/)\.\.(/|$)' >&2
    exit 1
fi

mkdir -p -- "$dest"
if [ "$kind" = tar ]; then
    tar -xzf "$bundle" -C "$dest"
else
    unzip -q -o "$bundle" -d "$dest"
fi

echo "Extracted to $dest/ — open README.md first (the 'CODING AGENTS READ THIS FIRST' file), then chats/, then the HTML."
