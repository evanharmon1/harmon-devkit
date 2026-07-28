#!/usr/bin/env bash
# notify-devkit-release.sh — tell harmon-init that a stable harmon-devkit
# release exists, so it can open its pin-and-sync PR.
#
# harmon-init vendors this repo's shared agent skills at a pinned tag. When a
# release-please PR merge here cuts a tag, harmon-init's root-only
# `sync-harmon-devkit.yml` does the rest: rewrite both pins, re-vendor, verify,
# and open or update ONE rolling sync PR. That workflow listens for a
# `repository_dispatch`, and this script sends it.
#
# Nothing here merges or releases anything, in either repository. The receiver
# independently re-validates the tag against this repo's GitHub releases, so a
# wrong value cannot make it vendor something that does not exist — but it is
# sent correctly in the first place, and a failure to send is loud: harmon-init's
# daily reconciliation would eventually notice the stale pin on its own, and a
# silent miss here would make that slow path look like the normal one.
#
# Usage:
#   notify-devkit-release.sh <tag>
#
# Env: GH_TOKEN — an installation token scoped to the TARGET repo with
#      contents:write (what POST /repos/{owner}/{repo}/dispatches requires).
#      TARGET_REPO — override the default receiver (tests).
# Depends on: gh. Unit-tested by scripts/test-notify-devkit-release.sh.
set -euo pipefail

TARGET_REPO="${TARGET_REPO:-evanharmon1/harmon-init}"
EVENT_TYPE="harmon-devkit-released"

die() {
    echo "notify-devkit-release: $*" >&2
    exit 1
}

command -v gh >/dev/null 2>&1 || die "gh is required"

tag="${1:-}"
[ -n "$tag" ] || die "usage: notify-devkit-release.sh <tag>"

# Shape-check before sending. The receiver validates independently and would
# reject anything malformed, but failing here names the real culprit (this
# repo's release step) instead of surfacing as a confusing rejection in another
# repository's logs. Pure shell — no pipe into grep, so an embedded newline
# cannot satisfy a per-line anchored regex.
case "$tag" in
v*) ;;
*) die "refusing tag '$tag' — a harmon-devkit release tag starts with 'v'" ;;
esac
rest="${tag#v}"
case "$rest" in
"" | *[!0-9.]* | .* | *.) die "refusing tag '$tag' — only digits and dots may follow 'v'" ;;
esac
case "$rest" in
*..*) die "refusing tag '$tag' — empty version component" ;;
esac
dots="${rest//[!.]/}"
[ "${#dots}" -eq 2 ] ||
    die "refusing tag '$tag' — expected a stable v<major>.<minor>.<patch> tag"

echo "notify-devkit-release: dispatching $EVENT_TYPE ($tag) to $TARGET_REPO"
# `-f` sends form fields as strings; the receiver reads client_payload.tag.
gh api "repos/$TARGET_REPO/dispatches" \
    -f "event_type=$EVENT_TYPE" \
    -f "client_payload[tag]=$tag" ||
    die "dispatch to $TARGET_REPO failed — harmon-init will not open its sync PR until its daily reconciliation runs, or someone re-sends this by hand:
    gh api repos/$TARGET_REPO/dispatches -f event_type=$EVENT_TYPE -f 'client_payload[tag]=$tag'"

echo "notify-devkit-release: dispatched — harmon-init opens/updates its sync PR (merging stays manual)"
