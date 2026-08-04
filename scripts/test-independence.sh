#!/usr/bin/env bash
# test-independence.sh — keep shipped output free of the maintainer's personal
# dotfiles repo (AGENTS.md, "Hard Rules"; harmon-devkit#263).
#
# harmon-init, harmon-devkit, and harmon-infra are independent of harmon-dotfiles.
# The permitted coupling is one-way and optional: harmon-dotfiles may pull from
# them at a pinned tag; they never point back. A consumer has no access to that
# repo, so a shipped mention of it is one of three failures — rationale they
# cannot read, a pointer that means nothing to them, or (worst) a claim that a
# personal repo is authoritative for content this repo owns.
#
# This is a written invariant made enforceable. Intent that is only remembered
# drifts back: every reference this guard replaces was added in good faith.
#
# SCOPE IS DELIBERATE. It covers what reaches a consumer — `ai/` (skills and
# agents are vendored at a pinned tag into harmon-init and into every repo it
# generates), plus the copy-paste asset trees `templates/`, `scripts/`, and
# `snippets/`. It does NOT cover the whole repo, because root-only mentions ship
# to nobody and create no dependency: `.devcontainer/related-repos.txt`, the
# sibling-repo grants in `.claude/settings.json`, the "related repos" tables in
# `README.md`/`AGENTS.md`, and the Hard Rule's own text all name harmon-dotfiles
# legitimately. A repo-wide guard would fail on the rule that motivates it.
#
# Run via `task test:independence`.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

# Case-insensitive — a capitalized "Harmon-Dotfiles" in prose ships just the
# same. No grep -P and no \b: BSD grep has neither, and these tokens need no
# anchors.
#
# The second alternative catches a hardcoded path into somebody's dotfiles
# CHECKOUT (~/.dotfiles/..., $HOME/.dotfiles/...) — the leak the equivalent
# harmon-init guard first missed: a guide named `~/.dotfiles/.functions` long
# after the repo name was gone, so the name alone reported independence while a
# pointer to the maintainer's layout still shipped.
#
# It is deliberately the PATH and not the word "dotfiles". Shipped guidance may
# legitimately discuss a consumer's own dotfiles, and banning the English word
# would fail on text that breaks no invariant. The segment boundary is written
# out rather than assumed: a leading `.dotfiles/config` (relative path, or a
# symlink target that starts at the checkout) has no slash in front of it, so
# anchoring on `/` alone would let exactly that form through.
#
# NOTE: unlike harmon-init's `test:template-independence`, `chezmoi` is NOT in
# this pattern. The `standardize-repo` skill carries substantial chezmoi
# guidance (.chezmoiignore, private_/dot_ prefixes, git.autoCommit vs lefthook)
# because one of the repos it may be pointed at *is* a chezmoi source. The
# technique is domain knowledge this repo needs; only the personal repo's name
# and offsite rationale are forbidden.
PATTERN='harmon-dotfiles|(^|[^[:alnum:]_-])\.dotfiles(/|$|[^[:alnum:]_-])'

# What a consumer receives.
TARGETS=(
    ai
    templates
    scripts
    snippets
)

# This guard lives inside a scanned target and necessarily spells out the very
# string it forbids — enforcement cannot name the thing without naming it. That
# carve-out is written into the Hard Rule itself (AGENTS.md), so this is the
# rule's own text and not an exemption from it. It is the whole exemption:
# excluding one exact path, with nothing else under the targets skipped.
SELF="scripts/test-independence.sh"

fail=0
scanned=0
for target in "${TARGETS[@]}"; do
    if [ ! -e "$target" ]; then
        echo "FAIL: expected scan target is missing: ${target}" >&2
        fail=1
        continue
    fi
    scanned=$((scanned + 1))

    # The scan universe is git's, not the filesystem's: tracked files plus
    # untracked ones git would accept. Ignored artifacts cannot ship, and
    # walking them raw is worse than wasteful — an ignored `.env` or a local
    # `node_modules/` under one of these trees would fail this guard on one
    # machine while CI, which never sees them, passed.
    while IFS= read -r -d '' file; do
        [ -n "$file" ] || continue
        [ "$file" != "$SELF" ] || continue

        # Paths. Machinery can be named rather than written: a committed
        # `ai/example/.dotfiles/config` encodes the checkout layout in its path
        # while every file under it reads clean.
        if printf '%s\n' "$file" | grep -qEi "$PATTERN"; then
            echo "FAIL: ${file} — personal dotfiles machinery must not ship to consumers" >&2
            fail=1
        fi

        # Symlink TARGETS, where the dependency actually lives. The content
        # scan cannot see one: reading through a link is `grep -R`, which must
        # not be used here — it would follow a link out of the tree and scan
        # whatever it lands on.
        if [ -L "$file" ]; then
            dest=$(readlink "$file") || continue
            [ -n "$dest" ] || continue
            if printf '%s\n' "$dest" | grep -qEi "$PATTERN"; then
                echo "FAIL: ${file} is a symlink to ${dest}" >&2
                fail=1
            fi
            continue
        fi
        [ -f "$file" ] || continue

        # Contents, read as BYTES (-a), not as text. `grep -I` would skip any
        # file with a NUL in it, and these trees ship ~100 tracked binaries
        # under scripts/appleScripts — including compiled .scpt files, which
        # embed the filesystem paths their source referenced. Skipping binaries
        # would exempt exactly the assets most likely to carry a hardcoded
        # dotfiles path, and would do it silently.
        if grep -qaEi "$PATTERN" "$file" 2>/dev/null; then
            echo "FAIL: ${file} references harmon-dotfiles or a personal dotfiles path" >&2
            # Dump matching lines for text; for a binary, say so instead of
            # spraying raw bytes at the terminal.
            if grep -Iq . "$file" 2>/dev/null; then
                grep -naEi "$PATTERN" "$file" | sed 's/^/      /' >&2
            else
                echo "      (binary file — match found in its raw bytes)" >&2
            fi
            fail=1
        fi
    done < <(git ls-files -z --cached --others --exclude-standard -- "$target")

    # The index, which is what the next commit actually records. The loop above
    # takes its PATHS from git but reads CONTENT from the worktree, so a
    # violation that was staged and then edited out without re-staging would
    # pass here and ship in the commit. `git grep --cached` reads the staged
    # blobs themselves — including a symlink's blob, which is its target path.
    #
    # Option order matters and is load-bearing: `--cached` must come BEFORE the
    # pattern, or git reads it as a revision and dies. Its exit status is
    # three-valued — 0 match, 1 no match, >1 error — so the error case is
    # handled explicitly rather than swallowed with `|| true`: a scan that
    # cannot run must fail the guard, never report independence.
    staged=$(git grep --cached -laEi "$PATTERN" -- "$target") || staged_rc=$?
    staged_rc=${staged_rc:-0}
    if [ "$staged_rc" -gt 1 ]; then
        echo "FAIL: staged-content scan of ${target} failed (git grep exit ${staged_rc})" >&2
        fail=1
    fi
    while IFS= read -r file; do
        [ -n "$file" ] || continue
        [ "$file" != "$SELF" ] || continue
        echo "FAIL: ${file} — the STAGED copy references harmon-dotfiles or a personal dotfiles path" >&2
        git grep --cached -naEi "$PATTERN" -- "$file" | sed 's/^/      /' >&2
        fail=1
    done <<EOF
$staged
EOF
    unset staged_rc

    # Index entries git grep cannot read. It skips symlinks (so a staged link
    # whose worktree copy was replaced by a regular file evades the scan above)
    # and a gitlink has no blob at all — an uninitialized submodule is an empty
    # directory locally while `--recurse-submodules` hands a consumer whatever
    # it points at. Read the modes directly.
    while IFS= read -r -d '' entry; do
        [ -n "$entry" ] || continue
        mode=${entry%% *}
        path=${entry#*$'\t'}
        [ "$path" != "$SELF" ] || continue
        case "$mode" in
        120000)
            dest=$(git cat-file blob ":${path}" 2>/dev/null) || continue
            if printf '%s\n' "$dest" | grep -qEi "$PATTERN"; then
                echo "FAIL: ${path} — the STAGED symlink points at ${dest}" >&2
                fail=1
            fi
            ;;
        160000)
            # No pattern check: the URL lives in .gitmodules, outside these
            # trees, so the gitlink itself is the only thing to judge. Shipped
            # output owns its content outright rather than pointing at another
            # repo's history.
            echo "FAIL: ${path} — submodules must not ship in consumer-facing trees" >&2
            fail=1
            ;;
        esac
    done < <(git ls-files -s -z -- "$target")
done

if [ "$fail" -ne 0 ]; then
    echo "independence: shipped output must not reference harmon-dotfiles or a personal dotfiles checkout" >&2
    echo "  state the rationale here rather than citing that repo, and drop the name where it is" >&2
    echo "  only a pointer (AGENTS.md, \"Hard Rules\")" >&2
    exit 1
fi
echo "independence OK: ${scanned} consumer-facing target(s) name no personal dotfiles repo or path"
