#!/usr/bin/env bash
# verify-independence.sh — keep shipped output free of the maintainer's personal
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
# Run via `task validate:independence`; unit-tested by scripts/test-independence.sh.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

# Bytes, not characters. This scans binaries, and BSD `tr` aborts with "Illegal
# byte sequence" on any byte that is not valid UTF-8 under a UTF-8 locale — so
# without this the NUL-stripping decode below fails on exactly the compiled
# assets it exists to read, and the guard passes while a scan errors out. The C
# locale also makes matching deterministic across machines.
export LC_ALL=C

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
#
# The trailing boundary excludes `.` deliberately: `.dotfiles.example`,
# `.dotfiles.json`, and `.dotfiles.bak` are ordinary filenames, not a personal
# checkout, and rejecting them would fail text that breaks no invariant. A real
# checkout path is followed by a separator or ends there.
PATTERN='harmon-dotfiles|(^|[^[:alnum:]_-])\.dotfiles(/|$|[^[:alnum:]_.-])'

# What a consumer receives.
TARGETS=(
    ai
    templates
    scripts
    snippets
)

# The enforcement pair — this guard and its unit test — lives inside a scanned
# target and necessarily spells out the very strings it forbids: the guard to
# match them, the test to build fixtures that must be rejected. Enforcement
# cannot name the thing without naming it, and a test that cannot write a
# violation cannot prove the guard catches one. That carve-out is written into
# the Hard Rule itself (AGENTS.md), so this is the rule's own text rather than
# an exemption from it. These two exact paths are the whole exemption; nothing
# else under the targets is skipped.
EXEMPT=(
    scripts/verify-independence.sh
    scripts/test-independence.sh
)

is_exempt() {
    local candidate="$1" path
    for path in "${EXEMPT[@]}"; do
        [ "$candidate" != "$path" ] || return 0
    done
    return 1
}

fail=0
scanned=0

# Enumeration goes through a temp file rather than straight into `while ... <
# <(git ls-files)`. A process substitution's exit status belongs to the
# substitution, not to the loop, so a `git ls-files` that dies (a corrupt index,
# say) would hand the loop zero entries and the guard would print "independence
# OK" having scanned nothing. Same fail-open class as the swallowed `|| true`
# this file already carries a warning about; here it is checked instead.
LISTING="$(mktemp)"
trap 'rm -f "$LISTING"' EXIT

# enumerate ARGS… — run git ls-files into $LISTING, failing the guard if it
# cannot enumerate. Returns non-zero so the caller can skip a doomed scan.
enumerate() {
    if git "$@" >"$LISTING" 2>/dev/null; then
        return 0
    fi
    echo "FAIL: could not enumerate files (git $*)" >&2
    fail=1
    return 1
}

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
    enumerate ls-files -z --cached --others --exclude-standard -- "$target" || continue
    while IFS= read -r -d '' file; do
        [ -n "$file" ] || continue
        ! is_exempt "$file" || continue

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
        #
        # NUL bytes are stripped before matching. `osacompile` stores strings as
        # UTF-16, so a path in a compiled .scpt is `.\0d\0o\0t\0…` and never
        # appears contiguously to an ASCII pattern. Deleting NULs is the whole
        # decode: every NUL-padded encoding of ASCII-range text — UTF-16LE,
        # UTF-16BE, UTF-32 — collapses back to ASCII, so this closes the class
        # rather than one encoding at a time. On plain text it is a no-op, which
        # is why one scan serves both and there is no separate raw pass.
        #
        # `grep` must NOT be given -q here. With -q it exits the moment it
        # matches, `tr` takes SIGPIPE on its next write, and `pipefail` reports
        # 141 for the pipeline — turning a FOUND violation into a false clean
        # whenever the file is larger than a pipe buffer. Reproduced with a
        # 20 MiB fixture: the guard printed "independence OK". Letting grep
        # drain the stream costs a full read and cannot lie.
        scan_rc=0
        tr -d '\000' <"$file" 2>/dev/null | grep -aEi "$PATTERN" >/dev/null || scan_rc=$?
        if [ "$scan_rc" -gt 1 ]; then
            echo "FAIL: could not scan ${file} (exit ${scan_rc})" >&2
            fail=1
        fi
        if [ "$scan_rc" -eq 0 ]; then
            echo "FAIL: ${file} references harmon-dotfiles or a personal dotfiles path" >&2
            # Dump matching lines for text; for a binary, say so instead of
            # spraying raw bytes at the terminal.
            if grep -Iq . "$file" 2>/dev/null; then
                grep -naEi "$PATTERN" "$file" | sed 's/^/      /' >&2
            else
                echo "      (binary file — match found in its bytes, NULs stripped)" >&2
            fi
            fail=1
        fi
    done <"$LISTING"

    # The index, which is what the next commit actually records. The loop above
    # takes its PATHS from git but reads CONTENT from the worktree, so a
    # violation that was staged and then edited out without re-staging would
    # pass here and ship in the commit.
    #
    # Read the blobs directly rather than with `git grep --cached`: that would
    # need its own NUL-stripping decode, it silently skips symlink entries, and
    # a gitlink has no blob for it to read at all. One pass over the index
    # modes covers all three kinds with the same rules as the worktree scan.
    enumerate ls-files -s -z -- "$target" || continue
    while IFS= read -r -d '' entry; do
        [ -n "$entry" ] || continue
        mode=${entry%% *}
        path=${entry#*$'\t'}
        ! is_exempt "$path" || continue
        case "$mode" in
        100644 | 100755)
            # Pipeline status is three-valued under `set -o pipefail`: 0 match,
            # 1 clean, anything else a failed read. The error case is explicit
            # — a scan that cannot run must fail the guard, never report
            # independence. (An earlier revision swallowed a fatal git error
            # with `|| true` and printed "independence OK" while its staged
            # scan had never run at all.)
            # No -q, for the same SIGPIPE reason as the worktree scan above:
            # an early-exiting grep would make a large matching blob report 141
            # here, which this branch would then call a read failure — right
            # answer, wrong reason, and only by luck.
            blob_rc=0
            git cat-file blob ":${path}" 2>/dev/null |
                tr -d '\000' |
                grep -aEi "$PATTERN" >/dev/null || blob_rc=$?
            if [ "$blob_rc" -eq 0 ]; then
                echo "FAIL: ${path} — the STAGED copy references harmon-dotfiles or a personal dotfiles path" >&2
                fail=1
            elif [ "$blob_rc" -gt 1 ]; then
                echo "FAIL: could not read the staged blob for ${path} (exit ${blob_rc})" >&2
                fail=1
            fi
            ;;
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
    done <"$LISTING"
done

if [ "$fail" -ne 0 ]; then
    echo "independence: shipped output must not reference harmon-dotfiles or a personal dotfiles checkout" >&2
    echo "  state the rationale here rather than citing that repo, and drop the name where it is" >&2
    echo "  only a pointer (AGENTS.md, \"Hard Rules\")" >&2
    exit 1
fi
echo "independence OK: ${scanned} consumer-facing target(s) name no personal dotfiles repo or path"
