#!/usr/bin/env bash
set -euo pipefail

# Compatibility bridge: generated repos may consume a previously published
# shared image while the image change in this release is still propagating.
version="1.1.11"
build="4956531888881664"

install_dir="$HOME/.local/bin"
real_bin="${install_dir}/agy-real"
link_bin="${install_dir}/agy"

# HARMON_BOT_AUTONOMY_ANTIGRAVITY is the rendered containerEnv marker (bot
# and dev devcontainer.json twins, from the use_antigravity_cli Copier
# answer) — the only channel this verbatim, template-twinned script may read
# to learn that per-repo answer. Anything other than "enabled" (including
# absent, on an image built before this marker existed) means: no download,
# and remove agy-real/agy if either survives from a prior enabled run or a
# stale image, so a default-off render reaches plain absence, never a
# symlink with nothing to point at.
if [ "${HARMON_BOT_AUTONOMY_ANTIGRAVITY:-}" != "enabled" ]; then
    rm -f "$real_bin" "$link_bin"
    exit 0
fi

# Once the pinned image supplies this exact version, exit without touching the
# network. A stale image version falls through to the user-local compatibility
# copy, which takes precedence in the repo-managed shell PATH.
if [ -x "$real_bin" ] &&
    [ "$("$real_bin" --version | head -1)" = "$version" ]; then
    ln -sfn "$real_bin" "$link_bin"
    exit 0
fi

system_binary="${HARMON_ANTIGRAVITY_SYSTEM_BINARY:-/usr/local/bin/agy}"
if [ -x "$system_binary" ] && [ "$("$system_binary" --version | head -1)" = "$version" ]; then
    # Reconcile only a compatibility copy already left in the persistent
    # volume. Interactive shells put ~/.local/bin first, so an older executable
    # would shadow the newly pinned and smoke-tested shared-image binary. Do not
    # create a new shadow copy when the image binary is already sufficient.
    if [ -x "$real_bin" ]; then
        install -m 0755 "$system_binary" "$real_bin"
        ln -sfn "$real_bin" "$link_bin"
    elif [ -L "$link_bin" ]; then
        # No local real copy to (re)point at, so this branch installs
        # nothing — only remove a leftover $link_bin in the two shapes
        # that must not persist: a dangling symlink (its target already
        # gone, e.g. after a prior agy-real was removed by a toggle-off/on
        # cycle or a stale image) — already a broken launcher on its own —
        # or a symlink to an existing directory, which
        # bot-autonomy/antigravity.sh's install_wrapper cannot safely
        # replace: its unguarded `mv -f "$tmp" "$link_bin"` lands *inside*
        # an existing directory target instead of replacing the link (a
        # later `ln -sfn` is unaffected by that same shape). A regular
        # file, a valid wrapper, or a symlink to an existing file is left
        # exactly as found: either is safe for a later `mv -f` or
        # `ln -sfn` to replace, and removing one here — with nothing on
        # this branch to replace it with — would destroy a still-valid
        # wrapper for good in the dev profile, which has no follow-on
        # apply step to reinstall it (#1171).
        if [ ! -e "$link_bin" ] || [ -d "$link_bin" ]; then
            rm -f "$link_bin"
        fi
    fi
    exit 0
fi

case "$(uname -m)" in
x86_64)
    platform="linux-x64"
    archive="cli_linux_x64"
    sha512="32d64529cf035ab9790352069dd0df4525d7c920b42872de1775e65455e77fd983b37a6dee81a6345b060c98d5f350729bb5e2ae881bbda80f46b7487af4588d"
    ;;
aarch64 | arm64)
    platform="linux-arm"
    archive="cli_linux_arm64"
    sha512="fb1acacdbde606a60a8002b6dc0a8c9800bb84aef3add069f843f6ffa3efaafe4a52fce440505c6f16aebd6b1257cce5ecfaec2dbab21732c625943422318cdb"
    ;;
*)
    echo "Unsupported architecture for Antigravity CLI: $(uname -m)" >&2
    exit 1
    ;;
esac

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
tarball="$work_dir/${archive}.tar.gz"
url="https://storage.googleapis.com/antigravity-public/antigravity-cli/${version}-${build}/${platform}/${archive}.tar.gz"

echo "==> Installing pinned Antigravity CLI ${version} compatibility copy..."
curl -fsSL --retry 3 "$url" -o "$tarball"
printf '%s  %s\n' "$sha512" "$tarball" | sha512sum --check -
tar -xzf "$tarball" -C "$work_dir" antigravity
install -d -m 0755 "$install_dir"
install -m 0755 "$work_dir/antigravity" "$real_bin"
ln -sfn "$real_bin" "$link_bin"
