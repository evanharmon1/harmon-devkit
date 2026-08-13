#!/usr/bin/env bash
# check-image-staleness.sh — warn when the running image's baked config has
# drifted from the checkout's `.devcontainer/config/`.
#
# The Dockerfile copies `.devcontainer/config/` into the image at
# /usr/local/share/devcontainer-config/, and `install-harmon-repo-config`
# distributes copies from there (~/.config/starship.toml, the statusline, the
# shell setup, the hooks). So the baked directory IS a snapshot of what the
# checkout said when the image was built, and a recursive compare against the
# checkout answers one question exactly: is this container running config the
# repo has since moved past?
#
# Why that question is worth asking. A container can outlive its image by
# weeks — the Coder attach path reattaches to whatever container exists rather
# than building from the checkout (see docs/guides/devcontainers.md, "Attach
# paths and container managers") — and the symptoms are content-level, not
# crash-level: a prompt drawn by an older starship.toml, a statusline in a
# retired design. Those read as client-side rendering faults, and diagnosing
# them as such costs hours. One line naming the drift ends that.
#
# Warn-only, by construction:
#   * silent when the trees agree, and silent when the baked directory is
#     absent (an image built without this convention, or a run outside the
#     container) — absence is not staleness;
#   * names only file PATHS, never contents: config here references tokens,
#     hostnames, and machine paths, and a lifecycle log is not the place for
#     them;
#   * always exits 0. It runs from post-start and from the status board, both
#     of which are `set -e`, and a diagnostic that can abort the lifecycle it
#     diagnoses is worse than no diagnostic.
#
# The two roots are overridable so scripts/test-image-staleness.sh can point
# them at fixtures; unset, they are the real ones.
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

baked="${DEVCONTAINER_BAKED_CONFIG_DIR:-/usr/local/share/devcontainer-config}"
checkout="${DEVCONTAINER_REPO_CONFIG_DIR:-${script_dir}/../config}"

# Strip trailing slashes so the prefix arithmetic below has one form to handle.
while [ "${baked}" != "/" ] && [ "${baked%/}" != "${baked}" ]; do baked="${baked%/}"; done
while [ "${checkout}" != "/" ] && [ "${checkout%/}" != "${checkout}" ]; do checkout="${checkout%/}"; done

# Either side missing means there is nothing to compare, not that something is
# wrong. Outside the container the baked copy simply does not exist.
[ -d "${baked}" ] || exit 0
[ -d "${checkout}" ] || exit 0

# rel_to_root <dir> <name> — the path of <dir>/<name> relative to whichever
# root contains it, for `Only in` lines (which report a directory and a name).
rel_to_root() {
    local dir="$1" name="$2"
    case "${dir}" in
    "${baked}" | "${checkout}") printf '%s' "${name}" ;;
    "${baked}"/*) printf '%s/%s' "${dir#"${baked}"/}" "${name}" ;;
    "${checkout}"/*) printf '%s/%s' "${dir#"${checkout}"/}" "${name}" ;;
    *) printf '%s' "${name}" ;;
    esac
}

# `diff -q -r` is POSIX and reports both differing files and one-sided ones, so
# files ADDED to the checkout since the build and files DROPPED from it both
# count as drift — which is the point of comparing trees instead of a
# hardcoded file list that rots as the config set grows.
#
# LC_ALL=C pins the message wording the parser below matches: these strings are
# localized, and a translated `diff` would silently report zero drift forever.
# Exit 1 means "differences found" — the expected case. Exit >=2 means the
# comparison itself broke (a dangling symlink's target, an unreadable entry)
# and is handled below as INDETERMINATE, never as fresh.
diff_rc=0
diff_out="$(LC_ALL=C diff -q -r "${baked}" "${checkout}" 2>/dev/null)" || diff_rc=$?
count=0
names=""
while IFS= read -r line; do
    case "${line}" in
    "Files "*" differ")
        # Anchor the parse on the KNOWN roots rather than the bare " and "
        # separator: the line is "Files <baked>/REL and <checkout>/REL differ",
        # and a filename legally containing " and " would split early under a
        # naive "%% and *". Stripping the baked-root prefix first and then the
        # shortest suffix matching " and <checkout>/…" keeps REL intact for
        # every name that does not itself embed " and <checkout>/".
        rest="${line#Files "${baked}"/}"
        rest="${rest% differ}"
        rel="${rest% and "${checkout}"/*}"
        ;;
    "Only in "*)
        rest="${line#Only in }"
        rel="$(rel_to_root "${rest%%: *}" "${rest#*: }")"
        ;;
    "File "*" while "*)
        # A path that changed TYPE between image and checkout (regular file on
        # one side, directory on the other): GNU diff -q -r reports it as
        # "File A is a directory while file B is a regular file" — a third
        # message form, and drift like any other. Take the first path.
        rest="${line#File }"
        rel="${rest%% is a *}"
        rel="${rel#"${baked}"/}"
        rel="${rel#"${checkout}"/}"
        ;;
    *) continue ;;
    esac
    count=$((count + 1))
    names="${names}      ${rel}
"
done <<EOF_DIFF
${diff_out}
EOF_DIFF

# diff compares CONTENT line by line; the executable bit is invisible to it.
# That bit is load-bearing here — the tree bakes hook scripts that are invoked
# directly from their installed paths — so a mode-only change (chmod +x/-x)
# must count as drift too. Only the executable bit is compared: full-mode
# comparison would flag umask noise, and the x bit is the one that changes
# behavior.
#
# STORED bits, not effective access: [ -x ] asks access(X_OK), which a noexec
# mount answers "no" for a 0755 file — flagging every executable config as
# stale on such a checkout. The x characters of ls -ld's mode string reflect
# what is stored, portably (stat's flags are not portable).
xbits_of() {
    # e.g. -rwxr-xr-- -> "xxx": drop the r/w/- columns, then fold the
    # setuid/sticky spellings (s/S/t/T) into x. Config files carry none of
    # those in practice; folding S (setuid without execute) toward x errs on
    # the side of reporting drift, never hiding it.
    ls -ld "$1" 2>/dev/null | cut -c2-10 | tr -d 'rw-' | tr 'sStT' 'xxxx'
}
while IFS= read -r f; do
    rel="${f#"${baked}"/}"
    other="${checkout}/${rel}"
    [ -f "${other}" ] || continue
    # A path the diff pass already counted must not be counted again just
    # because its MODE also changed — one drifted config is one entry, or the
    # summary claims "2 baked configs" for a single file.
    if printf '%s' "${names}" | grep -qxF "      ${rel}"; then
        continue
    fi
    if [ "$(xbits_of "${f}")" != "$(xbits_of "${other}")" ]; then
        count=$((count + 1))
        names="${names}      ${rel} (executable bit)
"
    fi
done <<EOF_XBIT
$(find "${baked}" -type f)
EOF_XBIT

# diff's exit code distinguishes "differences" (1) from "trouble" (>=2 — a
# dangling symlink, an unreadable entry). Trouble means the comparison is
# INCOMPLETE, and an incomplete comparison must never read as fresh: that is
# the false negative this helper exists to prevent, one layer down. Say
# "indeterminate" loudly instead — still exit 0, still warn-only.
if [ "${diff_rc}" -ge 2 ]; then
    echo "==> image staleness indeterminate: the config comparison failed partway (diff exit ${diff_rc}) — treat as possibly stale and rebuild if in doubt"
fi

[ "${count}" -gt 0 ] || exit 0

if [ "${count}" -eq 1 ]; then
    echo "==> image is stale: 1 baked config differs from the checkout — rebuild the container"
else
    echo "==> image is stale: ${count} baked configs differ from the checkout — rebuild the container"
fi
printf '%s' "${names}"

exit 0
