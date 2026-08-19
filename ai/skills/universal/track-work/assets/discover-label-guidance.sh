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

normalize_github_remote() {
    _remote="$1"
    case "$_remote" in
    git@github.com:*) _slug="${_remote#git@github.com:}" ;;
    ssh://git@github.com/*) _slug="${_remote#ssh://git@github.com/}" ;;
    ssh://git@ssh.github.com:443/*) _slug="${_remote#ssh://git@ssh.github.com:443/}" ;;
    ssh://git@ssh.github.com/*) _slug="${_remote#ssh://git@ssh.github.com/}" ;;
    https://github.com/*) _slug="${_remote#https://github.com/}" ;;
    http://github.com/*) _slug="${_remote#http://github.com/}" ;;
    *) return 1 ;;
    esac
    _slug="${_slug%.git}"
    printf '%s\n' "$_slug" | tr '[:upper:]' '[:lower:]'
}

target_repo="$(printf '%s\n' "$repo" | tr '[:upper:]' '[:lower:]')"
repo_bound=0
remote_names="$(git -C "$repo_root" remote 2>/dev/null)" ||
    die "target repository root is not a readable Git checkout"
for remote_name in $remote_names; do
    remote_url="$(git -C "$repo_root" remote get-url "$remote_name" 2>/dev/null)" || continue
    remote_repo="$(normalize_github_remote "$remote_url" || true)"
    [ "$remote_repo" = "$target_repo" ] && repo_bound=1
done
[ "$repo_bound" -eq 1 ] ||
    die "target repository root has no GitHub remote matching --repo $repo"

asset_dir="$(cd "$(dirname "$0")" && pwd -P)"
registry_helper="$asset_dir/../../label-registry-support/assets/label-registry.sh"
[ -x "$registry_helper" ] ||
    die "shared label-registry interpreter is missing: $registry_helper"

exec "$registry_helper" guidance "$repo_root/label-registry.json" "$repo"
