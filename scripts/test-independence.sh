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
# would fail on text that breaks no invariant.
#
# NOTE: unlike harmon-init's `test:template-independence`, `chezmoi` is NOT in
# this pattern. The `standardize-repo` skill carries substantial chezmoi
# guidance (.chezmoiignore, private_/dot_ prefixes, git.autoCommit vs lefthook)
# because one of the repos it may be pointed at *is* a chezmoi source. The
# technique is domain knowledge this repo needs; only the personal repo's name
# and offsite rationale are forbidden.
PATTERN='harmon-dotfiles|/\.dotfiles'

# What a consumer receives.
TARGETS=(
    ai
    templates
    scripts
    snippets
)

# This guard lives inside a scanned target and necessarily spells out the very
# string it forbids. Excluding it by exact path is the whole exemption — nothing
# else under the targets is skipped.
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

    # Contents. -I skips binaries, -l prints each offending path once; the
    # follow-up grep shows the lines so the failure is actionable.
    while IFS= read -r file; do
        [ -n "$file" ] || continue
        [ "$file" != "$SELF" ] || continue
        echo "FAIL: ${file} references harmon-dotfiles or a personal dotfiles path" >&2
        grep -nEi "$PATTERN" "$file" | sed 's/^/      /' >&2
        fail=1
    done < <(grep -rlIEi "$PATTERN" "$target" 2>/dev/null || true)

    # Paths. Dotfiles machinery can be named rather than written: an empty
    # `harmon-dotfiles/` directory has no contents for the scan above to match.
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        echo "FAIL: ${path} — personal dotfiles machinery must not ship to consumers" >&2
        fail=1
    done < <(find "$target" -iname '*harmon-dotfiles*' -print)

    # Symlink TARGETS. Neither scan above sees one: `grep -r` does not read link
    # targets (that is -R, which we must not use here — it would follow a link
    # out of the tree and scan whatever it lands on), and `find -iname` matches
    # only the link's own name.
    while IFS= read -r link; do
        [ -n "$link" ] || continue
        dest=$(readlink "$link") || continue
        [ -n "$dest" ] || continue
        if printf '%s\n' "$dest" | grep -qEi "$PATTERN"; then
            echo "FAIL: ${link} is a symlink to ${dest}" >&2
            fail=1
        fi
    done < <(find "$target" -type l -print)
done

if [ "$fail" -ne 0 ]; then
    echo "independence: shipped output must not reference harmon-dotfiles or a personal dotfiles checkout" >&2
    echo "  state the rationale here rather than citing that repo, and drop the name where it is" >&2
    echo "  only a pointer (AGENTS.md, \"Hard Rules\")" >&2
    exit 1
fi
echo "independence OK: ${scanned} consumer-facing target(s) name no personal dotfiles repo or path"
