#!/usr/bin/env bash
# discover-label-guidance.sh — read-only label descriptions and family purpose
# for Track Work issue authoring. Policy remains exclusively in the metadata
# validator; this helper exists only to help a human or agent choose labels.
set -euo pipefail

usage() {
    echo "Usage: $0 --repo OWNER/REPO --repo-root CHECKOUT" >&2
    exit 2
}

die() {
    echo "discover-label-guidance: $*" >&2
    exit 1
}

repo=""
repo_root=""
while [ "$#" -gt 0 ]; do
    case "$1" in
    --repo)
        [ "$#" -ge 2 ] || usage
        repo="$2"
        shift 2
        ;;
    --repo-root)
        [ "$#" -ge 2 ] || usage
        repo_root="$2"
        shift 2
        ;;
    -h | --help) usage ;;
    *) usage ;;
    esac
done

[ -n "$repo" ] && [ -n "$repo_root" ] || usage
repo_root="$(git -C "$repo_root" rev-parse --show-toplevel 2>/dev/null)" ||
    die "could not resolve the target checkout's top-level directory"

asset_dir="$(cd "$(dirname "$0")" && pwd -P)"
registry_helper="$asset_dir/../../label-registry-support/assets/label-registry.sh"
[ -x "$registry_helper" ] ||
    die "shared label-registry interpreter is missing: $registry_helper"

exec "$registry_helper" guidance "$repo_root/label-registry.json" "$repo"
