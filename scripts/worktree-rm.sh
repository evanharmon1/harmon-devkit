#!/usr/bin/env bash
# worktree-rm.sh — remove a linked worktree created by worktree-new.sh and clear
# the gitlink debris a bare `git worktree remove` can leave behind.
#
# Run via `task worktree:rm -- <name> [--force]`.
#
# Refuses a dirty tree by default: uncommitted work in a worktree is invisible
# from the main checkout, so removing one silently is a data-loss path.
set -euo pipefail

usage() {
    cat >&2 <<'EOF'
Usage: task worktree:rm -- <name> [--force]

Removes .worktrees/<name>, clears that path's registry record, and deletes any
leftover gitlink directory. --force discards uncommitted changes in the tree.
Refuses when another registered worktree lives inside <name>.
EOF
}

die() {
    echo "worktree:rm: $*" >&2
    exit 1
}

# Refs that would STILL reference a commit once this worktree is gone.
#
# `refs/worktree/*`, `refs/bisect/*` and `refs/rewritten/*` are PER-WORKTREE:
# they live in the worktree's own administrative directory and are destroyed
# along with it, so counting them makes the reachability guard vouch for the
# very thing it is deciding about. Everything else — branches, tags,
# remote-tracking refs, notes, replace, stash — is shared and survives.
#
# They are excluded wholesale rather than per-owner because the query cannot
# tell whose per-worktree refs it is looking at: once a record is stale, its
# `refs/worktree/*` is unreadable from here, and the main worktree's own is
# indistinguishable in the output. Excluding all of them can only make the
# guard refuse a removal that was safe, which is the survivable direction.
shared_refs_containing() {
    git for-each-ref --contains "$1" --format='%(refname)' 2>/dev/null |
        grep -Ev '^refs/(worktree|bisect|rewritten)/' || true
}

# `git sparse-checkout check-rules` (git >= 2.42) lets the hidden-edit guard
# ask whether an absent flagged path is genuinely EXCLUDED by a sparse tree's
# active rules, or was deleted by the user. The gate is an explicit version
# parse, not a capability probe: probing by running the subcommand cannot
# distinguish "this git predates check-rules" from "check-rules failed at
# runtime", and misreading the second as the first would silently widen the
# exemption on a git that could have answered. A version this parser cannot
# read is treated as < 2.42 — not provably capable — which lands on the
# DOCUMENTED old-git behavior below rather than an undefined one.
git_supports_check_rules() {
    gate_ver="$(git --version 2>/dev/null)" || return 1
    gate_ver="${gate_ver#git version }"
    gate_major="${gate_ver%%.*}"
    gate_rest="${gate_ver#*.}"
    gate_minor="${gate_rest%%.*}"
    case "$gate_major" in '' | *[!0-9]*) return 1 ;; esac
    case "$gate_minor" in '' | *[!0-9]*) return 1 ;; esac
    [ "$gate_major" -gt 2 ] || { [ "$gate_major" -eq 2 ] && [ "$gate_minor" -ge 42 ]; }
}

# Locate the administrative directory backing the registry record for a
# worktree path. git exposes no porcelain for this mapping; each record's
# `gitdir` file holds the path of that worktree's `.git` file, which is the
# link back. Prints nothing and returns 1 when no record matches.
record_admin_dir() {
    admin_common="$(git rev-parse --path-format=absolute --git-common-dir)"
    [ -d "$admin_common/worktrees" ] || return 1
    for admin_candidate in "$admin_common"/worktrees/*; do
        [ -f "$admin_candidate/gitdir" ] || continue
        if [ "$(cat "$admin_candidate/gitdir" 2>/dev/null || true)" = "$1/.git" ]; then
            printf '%s\n' "$admin_candidate"
            return 0
        fi
    done
    return 1
}

# The SINGLE definition of "a name this command accepts". Two places need that
# answer — the argument validation below, and the decision about whether a
# resolved path can be advertised as a name — and they must never disagree.
# They did: the advertised remedy applied only the charset and component rules,
# so an in-cone path like `-dash/leaf` or `x..y` was offered as
# `task worktree:rm -- …` and then rejected by the very parser it was offered
# to (review r1). Echoes the problem and returns 1 when the name is not
# acceptable; silent and 0 when it is.
worktree_name_problem() {
    case "$1" in
    "") echo "must not be empty" && return 1 ;;
    /* | -*) echo "must not start with '/' or '-'" && return 1 ;;
    *..*) echo "must not contain '..'" && return 1 ;;
    *[!A-Za-z0-9._/-]*) echo "use only A-Z a-z 0-9 . _ - /" && return 1 ;;
    esac
    case "/$1/" in
    *//* | */./*) echo "path components must not be empty or '.'" && return 1 ;;
    esac
    return 0
}

name=""
force=0

while [ "$#" -gt 0 ]; do
    case "$1" in
    --force | -f)
        force=1
        shift
        ;;
    -h | --help)
        usage
        exit 0
        ;;
    -*)
        usage
        die "unknown option: $1"
        ;;
    *)
        [ -z "$name" ] || die "unexpected extra argument: $1"
        name="$1"
        shift
        ;;
    esac
done

[ -n "$name" ] || {
    usage
    die "a worktree name is required"
}

if ! name_problem="$(worktree_name_problem "$name")"; then
    die "invalid name '$name': $name_problem"
fi
# The character whitelist and the component rule that creation enforces both
# live in worktree_name_problem above. Removal used to get away without them,
# but lock entries are derived from the name, and a name carrying whitespace,
# glob characters, or the encoding characters would corrupt the lock
# bookkeeping (harmon-init#784) — and no conforming creation can have produced
# such a worktree anyway.
# The component rule matters for the same reason: every decision below compares
# `$tree` against git's CANONICAL registry paths as text. `./live` would miss
# the record for the live worktree at `live`, and the script would then classify
# a checked-out tree as debris and delete its gitlink. Equivalent spellings must
# not reach the comparisons at all.

git rev-parse --git-dir >/dev/null 2>&1 || die "not inside a git repository"

main_root="$(git worktree list --porcelain | awk '/^worktree /{print substr($0, 10); exit}')"
[ -n "$main_root" ] && [ -d "$main_root" ] || die "could not resolve the main worktree root"

tree="$main_root/.worktrees/$name"

# ── Per-path lifecycle locks ─────────────────────────────────────────
# The protocol lives in worktree-lock.sh, SHARED with the sibling command:
# both must run identical lock semantics, so there is exactly one copy to
# correct. See that file for the design and its residuals.
# shellcheck source=scripts/worktree-lock.sh
. "$(dirname "$0")/worktree-lock.sh"

# The traps are armed BEFORE the first acquisition, so a signal or failure
# landing mid-acquisition still releases whatever partial set was taken.
# Held from before the entry snapshots to script exit, so no step of the
# removal ever acts on a worktree that appeared at this path after the
# command started.
trap release_locks EXIT
trap 'exit 129' HUP INT TERM
acquire_path_locks "$name"

# Liveness comes from the worktree REGISTRY, not from running git inside the
# directory: `git -C <dir> rev-parse` walks upward and happily finds the
# enclosing main repository, so an abandoned empty reservation from an
# interrupted create would read as a live worktree and `git worktree remove`
# would fail with "not a working tree" — leaving the path unrecoverable through
# the very command worktree:new tells you to run.
registered="$(git worktree list --porcelain | awk '/^worktree /{print substr($0, 10)}')"
tree_is_registered=0
case "
$registered
" in *"
$tree
"*) tree_is_registered=1 ;; esac

# Snapshot the shape of the target ONCE, at entry, and drive every branch below
# off that snapshot. The registry cleanup at the end used to re-derive "is
# anything registered here?" at the moment it ran, which answers yes for a
# worktree a CONCURRENT `worktree:new` created at the same name in between —
# and removing it is then somebody else's tree deleted while this run reports
# success. These entrypoints exist for parallel work, so the window is real.
tree_exists=0
[ -d "$tree" ] && tree_exists=1
# The only case the final cleanup is ever allowed to act on: a record that
# outlived its directory *at entry*. Everything else either had its record
# removed by git during the removal below, or never had one.
stale_record=0
if [ "$tree_is_registered" -eq 1 ] && [ "$tree_exists" -eq 0 ]; then
    stale_record=1
fi

# ── The name must actually account for something (harmon-init#963) ──────────
#
# Everything above derives $tree by CONSTRUCTION from the argument, and never
# consults the registry to find where the named worktree actually is. git names
# an admin record from the path basename at creation and never renames it,
# while `git worktree move` rewrites the record's stored path — so record name
# and current directory name are independent BY DESIGN, and a worktree may sit
# anywhere `git worktree add` was pointed, including outside this repo's
# checkout entirely. A constructed path is therefore not a lookup, and when it
# missed, the run fell into the stale-record branch and reported a removal that
# did not happen: both output lines false, exit 0, the worktree untouched.
#
# The fix is a pre-flight, deliberately NOT a re-targeting. $tree keeps exactly
# the meaning it has always had for every run that proceeds — the locks are
# keyed on $name, and the removal, debris sweep and parent walk below are all
# written against the constructed path — so this either lets the existing flow
# run byte-for-byte as before, or refuses while naming the real path. Silently
# retargeting a deletion at a path the caller did not name is the more
# dangerous repair.
if [ "$tree_exists" -eq 0 ] && [ "$tree_is_registered" -eq 0 ] &&
    ! record_admin_dir "$tree" >/dev/null 2>&1; then
    # Nothing at the conventional path. Ask the registry what this name means
    # before claiming anything was removed.
    # A worktree path may legally contain a newline — `git worktree add` accepts
    # one even though worktree:new's charset whitelist can never produce one —
    # and the LF-delimited porcelain form truncates such a path at the newline,
    # which would resolve the wrong worktree or none at all. Read a
    # NUL-delimited stream where git provides it, and fall back to the LF form
    # rather than making an edge case impose a git version floor (challenge r1).
    # LF-delimited porcelain CANNOT represent a path containing a newline: the
    # path continues onto the next line with nothing marking it. An earlier
    # attempt detected that structurally, by treating a line that matched no
    # record key as a continuation — but a continuation may legally LOOK like a
    # key (`trap<LF>HEAD fake`), so the check could be walked straight past
    # (review r5). There is no parse that recovers the truth here.
    #
    # So this does not parse ambiguous output at all. Without `--porcelain -z`
    # (git 2.36+) registry resolution is simply unavailable, and the command
    # says so. Nothing else regresses: a worktree at the conventional path is
    # accounted for long before this block, so only the fallback lookup — the
    # thing that cannot be done correctly here — is withdrawn.
    if ! git worktree list --porcelain -z >/dev/null 2>&1; then
        die "no worktree at $tree, and this git cannot look up '$name' elsewhere in the registry: that needs \`git worktree list --porcelain -z\` (git 2.36+), because the line-delimited form cannot represent a path containing a newline and offers no way to tell one apart from a truncated prefix. Upgrade git to 2.36 or newer, or name the worktree by its path with git's own commands"
    fi

    # awk cannot do the NUL half: its strings are NUL-terminated, so an awk fed
    # a NUL-delimited stream stops at the first record — on macOS that silently
    # yielded only the main worktree. bash's `read -d ''` handles NUL correctly,
    # so the -z stream is split in the shell; awk is used only on the LF
    # fallback, where it is emitting NUL rather than consuming it, and only
    # once the check above has established no path spans lines.
    # Reached only when -z is available: the guard above refused otherwise.
    #
    # The trailing sentinel is this enumeration's success marker, mirroring
    # flagged_enum_ok and sparse_rules_ok below: bash does not propagate a
    # process-substitution failure, so without it a git error or a truncated
    # stream would fail OPEN — the consumer would treat a partial registry as
    # the whole registry and could call a name unique, or absent, on evidence
    # it never finished reading (review r6). It is unforgeable: every real
    # entry is an absolute path, and this marker contains no slash.
    registry_enum_ok_marker="__WORKTREE_RM_REGISTRY_OK__"
    emit_worktree_paths() {
        (
            git worktree list --porcelain -z || exit 1
            printf '%s\0' "$registry_enum_ok_marker"
        ) | while IFS= read -r -d '' wt_record; do
            case "$wt_record" in
            "worktree "*) printf '%s\0' "${wt_record#worktree }" ;;
            "$registry_enum_ok_marker") printf '%s\0' "$wt_record" ;;
            esac
        done
    }

    # Matches are COLLECTED rather than counted, so the ambiguity branch can
    # name the worktrees that actually collided instead of reprinting the whole
    # registry (challenge r2).
    matches=()
    registry_enum_ok=0
    while IFS= read -r -d '' candidate_tree; do
        [ -n "$candidate_tree" ] || continue
        if [ "$candidate_tree" = "$registry_enum_ok_marker" ]; then
            registry_enum_ok=1
            continue
        fi
        # The main checkout is registered but is not a linked worktree, and this
        # command removes only linked worktrees. Counting it made
        # `worktree:rm <repo-basename>` report the main checkout as an
        # out-of-cone worktree and recommend a `git worktree remove` that git
        # refuses — and made a same-basename linked worktree read as ambiguous.
        # The candidate listing below already skipped it; resolution must too.
        [ "$candidate_tree" = "$main_root" ] && continue
        candidate_name="${candidate_tree##*/}"
        candidate_record=""
        candidate_admin="$(record_admin_dir "$candidate_tree" 2>/dev/null || true)"
        [ -n "$candidate_admin" ] && candidate_record="${candidate_admin##*/}"
        # Basename and admin-record name only. A candidate's path RELATIVE to
        # .worktrees/ is deliberately NOT compared: it can equal $name only when
        # the constructed path IS this candidate's path, and that case never
        # reaches here — the conventional-path check above already accounted for
        # it. Matching on it was unreachable code (found verifying challenge r2).
        if [ "$candidate_name" = "$name" ] || [ "$candidate_record" = "$name" ]; then
            matches+=("$candidate_tree")
        fi
    done < <(emit_worktree_paths)
    [ "$registry_enum_ok" -eq 1 ] ||
        die "could not read the worktree registry completely, so '$name' cannot be resolved against it — refusing rather than acting on a partial list"
    resolved_count=${#matches[@]}

    if [ "$resolved_count" -eq 1 ]; then
        resolved="${matches[0]}"
        # $resolved is escaped everywhere it appears, not only in the remedy.
        # git sanitizes an admin-record name (a worktree at `trunc<LF>tail`
        # gets the record `trunc-tail`), so invoking that record name reaches
        # this branch with a raw newline or terminal-control byte in the path,
        # and an unescaped location clause splits the diagnostic across lines
        # or emits control sequences (review r3). $tree and $resolved_rel need
        # no escaping by construction: the first is built from $name and the
        # second has passed worktree_name_problem, so both are restricted to
        # the name charset.
        # Two different situations, two different remedies. In-cone means this
        # command CAN remove it and the caller simply used a name that no longer
        # points at it — a record keeps its creation-time name across a move.
        # Out-of-cone means no argument to this command will reach it, because
        # every path below is written against <main_root>/.worktrees/, so the
        # remedy is git's own command.
        resolved_rel=""
        case "$resolved" in
        "$main_root"/.worktrees/*) resolved_rel="${resolved#"$main_root"/.worktrees/}" ;;
        esac
        # An in-cone path is only reachable through THIS command when its
        # relative form is a name this command would accept. A hand-registered
        # `.worktrees/team space/foo` is in-cone yet unnameable here: the
        # suggested `task worktree:rm -- team space/foo` would split on the
        # space and be rejected by the charset guard anyway. Fall back to git's
        # command, shell-escaped, rather than emitting a remedy that cannot work
        # (challenge r2).
        rel_is_nameable=0
        if [ -n "$resolved_rel" ] && worktree_name_problem "$resolved_rel" >/dev/null; then
            rel_is_nameable=1
        fi
        if [ "$rel_is_nameable" -eq 1 ]; then
            die "no worktree at $tree, but '$name' names the worktree at $(printf '%q' "$resolved") — its admin record and its directory have different names (a move does that), and only its current name resolves here: task worktree:rm -- $resolved_rel"
        else
            die "no worktree at $tree, but '$name' names the worktree at $(printf '%q' "$resolved") — that path is not addressable by this command, and no removal command is suggested for it on purpose: \`git worktree remove\` performs none of the checks this task does (work hidden by skip-worktree or assume-unchanged, a merge autostash, and detached commits no branch, tag or remote-tracking ref contains — it deletes ignored files such as .env and takes an unreferenced detached HEAD without complaint), so anything removing that path has to establish those itself first"
        fi
    elif [ "$resolved_count" -gt 1 ]; then
        echo "worktree:rm: '$name' is ambiguous — it matches more than one registered worktree:" >&2
        for amb_tree in "${matches[@]}"; do
            printf '  %s\n' "$(printf '%q' "$amb_tree")" >&2
        done
        die "name the worktree unambiguously — this command removes only worktrees under $main_root/.worktrees/, and reaching any other path means establishing for yourself the guards listed above that \`git worktree remove\` does not apply"
    fi

    # Matches nothing at all. Never report a removal for it.
    echo "worktree:rm: no worktree or admin record named '$name'" >&2
    echo "worktree:rm: live worktrees (a record's name can differ from its directory after a move):" >&2
    # Same NUL-delimited source the resolution above uses: a line-parsed listing
    # truncates a newline-bearing path and prints a raw newline into the middle
    # of the candidate list. printf %q renders such a path visibly instead of
    # mangling the output, and leaves ordinary paths untouched.
    listing_enum_ok=0
    while IFS= read -r -d '' live_tree; do
        if [ "$live_tree" = "$registry_enum_ok_marker" ]; then
            listing_enum_ok=1
            continue
        fi
        # Skip the main checkout: it is registered, but this command removes
        # linked worktrees only, so offering it as a candidate is a dead end.
        [ "$live_tree" = "$main_root" ] && continue
        live_admin="$(record_admin_dir "$live_tree" 2>/dev/null || true)"
        live_rel=""
        case "$live_tree" in
        "$main_root"/.worktrees/*)
            live_rel="${live_tree#"$main_root"/.worktrees/}"
            # Same single definition the remedy and the argument check use: a
            # path is only advertised under a name when that name would
            # actually be accepted. This was a third partial copy of the rule
            # (charset only), found while fixing the second one (review r1).
            worktree_name_problem "$live_rel" >/dev/null || live_rel=""
            ;;
        esac
        if [ -n "$live_rel" ]; then
            live_label="$live_rel"
        else
            # Not addressable through this command at all. The label is a
            # STATUS, never a command: rendering `git worktree remove` here
            # re-offered exactly what the refusal above withholds, and that
            # command applies none of this script's guards (review r5).
            live_label="(not removable here)"
        fi
        if [ -n "$live_admin" ] && [ "${live_admin##*/}" != "${live_tree##*/}" ]; then
            printf '  %s  (record: %s)  %s\n' \
                "$live_label" "${live_admin##*/}" "$(printf '%q' "$live_tree")" >&2
        else
            printf '  %s  %s\n' "$live_label" "$(printf '%q' "$live_tree")" >&2
        fi
    done < <(emit_worktree_paths)
    [ "$listing_enum_ok" -eq 1 ] ||
        echo "worktree:rm: (the registry could not be read completely — this list may be partial)" >&2
    die "nothing was removed"
fi

# A worktree registered BELOW this path is a separate worktree, not this one's
# disposable contents. `git worktree remove --force` would delete its
# uncommitted work and the record cleanup below would drop its registry record,
# yet --force only ever promised to discard *this* tree's changes — so the
# refusal holds in both modes. `worktree:new` cannot create such a nesting; one
# predates this entrypoint or was made by hand, which is exactly why removal has
# to look for it rather than assume it away.
nested_found=0
while IFS= read -r registered_tree; do
    case "$registered_tree" in
    "$tree"/*) : ;;
    *) continue ;;
    esac
    if [ "$nested_found" -eq 0 ]; then
        echo "worktree:rm: $tree contains registered worktrees of its own:" >&2
        nested_found=1
    fi
    echo "  $registered_tree" >&2
done <<EOF
$registered
EOF
if [ "$nested_found" -eq 1 ]; then
    die "remove those first (task worktree:rm -- <name> for each) — they are separate worktrees, not this one's contents, and --force does not override this"
fi

if [ "$tree_exists" -eq 0 ]; then
    # A stale record is not automatically worthless. Its administrative
    # directory holds the HEAD the worktree was on, and when that HEAD is a
    # detached commit no shared ref contains, the record is the ONLY thing
    # keeping it alive — dropping it silently is the same data-loss path the
    # live branch below already refuses, just reached with the directory gone.
    # (`git worktree prune` lost it too; scoping the cleanup narrowed the blast
    # radius without giving this path the guard the live one has.)
    if [ "$force" -eq 0 ] && [ "$stale_record" -eq 1 ]; then
        stale_admin="$(record_admin_dir "$tree" || true)"
        # An interrupted `git merge --autostash` can leave the stashed work
        # referenced by the record's MERGE_AUTOSTASH file and nothing else —
        # the same marker the live-tree guard below refuses, reachable here
        # with the directory already gone. Dropping the record drops the
        # only reference.
        if [ -n "$stale_admin" ] && [ -s "$stale_admin/MERGE_AUTOSTASH" ]; then
            # printf %q escapes the WHOLE quoting class (whitespace, quotes,
            # metacharacters) rather than one corner of it; the test suite
            # executes this emitted command verbatim.
            stale_marker_q="$(printf '%q' "$stale_admin/MERGE_AUTOSTASH")"
            # Storing does not remove the marker, so a plain re-run refuses
            # again — the completing sequence is store, THEN --force (safe:
            # the work now lives in refs/stash).
            die "$tree is gone but its record still holds a merge autostash ($stale_admin/MERGE_AUTOSTASH) — keep the work with: git stash store \"\$(cat $stale_marker_q)\" — then re-run with --force to clear the record (the stored work survives in refs/stash); --force without storing discards it"
        fi
        if [ -n "$stale_admin" ] && [ -f "$stale_admin/HEAD" ]; then
            stale_head="$(cat "$stale_admin/HEAD" 2>/dev/null || true)"
            case "$stale_head" in
            ref:* | '') : ;; # attached to a branch: the branch keeps the commits
            *)
                if git rev-parse --quiet --verify "$stale_head^{commit}" >/dev/null 2>&1 &&
                    [ -z "$(shared_refs_containing "$stale_head")" ]; then
                    die "$tree is gone but its record still holds detached commit $stale_head, which no branch, tag or remote-tracking ref contains — branch or tag it ('git branch <name> $stale_head'), or re-run with --force to discard it"
                fi
                ;;
            esac
        fi
    fi
    echo "==> $tree does not exist; clearing its registry record anyway"
elif [ "$tree_is_registered" -eq 0 ]; then
    # The directory is not a registered worktree: either it outlived its record
    # (a stale gitlink) or it is an empty reservation an interrupted create left
    # behind. `git worktree remove` would only report "is not a working tree";
    # prune plus the debris sweep below is the actual fix for both.
    echo "==> $tree is not a live worktree (stale gitlink or abandoned reservation) — cleaning it up"
else
    if [ "$force" -eq 0 ] && [ -n "$(git -C "$tree" status --porcelain)" ]; then
        die "$tree has uncommitted changes — commit or push them, or re-run with --force to discard them"
    fi
    # `git status --porcelain` and `git diff-files` both OMIT entries flagged
    # skip-worktree or assume-unchanged — hiding a locally modified tracked
    # file is what the flags are for — so an edit to such a file is invisible
    # to the check above and a plain removal would delete it while reporting
    # success. The flags are visible to `git ls-files -v`: `S` marks
    # skip-worktree and a lowercase tag letter marks assume-unchanged (`h`
    # for an ordinary cached entry, `s` when both flags are set), so compare
    # each flagged entry against its index entry directly. ONE pass over the
    # NUL-delimited stream, deliberately: `core.quotePath` C-quotes
    # non-ASCII paths in line output, so a line-based read would miss the
    # file on disk (falsely refusing over a clean `café.txt`) — and a
    # `grep -q` pre-pass is not a safe short-circuit, because its early exit
    # SIGPIPEs the git writer under `pipefail` and skips this whole guard
    # precisely when a flagged entry exists in a large repo. The `case` is
    # the short-circuit: unflagged entries fall through with no process
    # spawned.
    #
    # What counts as a hidden edit is what a removal would DESTROY:
    #   - an absent skip-worktree path in a sparse-enabled tree is skipped
    #     only when the tree's ACTIVE sparse rules exclude it — sparse marks
    #     every excluded path skip-worktree with no file present, so refusing
    #     on absence alone would block the removal of every clean sparse
    #     worktree. But sparse-enabled is a per-tree fact and the flag is
    #     per-path: an IN-CONE file the user manually flagged and then
    #     deleted shows the same absent-`S` state, and skipping it discards
    #     that uncommitted deletion-intent (harmon-init#919). So absence is
    #     exempt per PATH, by asking `git sparse-checkout check-rules`
    #     (git >= 2.42) whether the rules exclude it — batched once per tree,
    #     because a sparse monorepo can hold hundreds of thousands of absent
    #     entries and a per-path spawn turned removal into minutes. On
    #     git < 2.42 the whole-tree exemption is KEPT, deliberately and
    #     documented (harmon-init#919's decided AC): the residual loss is
    #     deletion-intent on an exotic, unstable state (git recomputes
    #     sparse skip-worktree bits itself), while failing closed would
    #     refuse every clean sparse-worktree removal on e.g. macOS system
    #     git ~2.39 and teach the routine use of --force, which discards
    #     every OTHER protection here too. Without sparse, absence means the
    #     user deleted a file they had flagged — for skip-worktree and
    #     assume-unchanged alike, that uncommitted deletion is what the
    #     removal would discard, so it refuses;
    #   - content is compared against the CHECKOUT representation
    #     (`cat-file --filters` — the bytes a fresh checkout would write),
    #     so an unmodified checkout under `eol=crlf`, `core.autocrlf`, or a
    #     clean/smudge filter reads as clean, while an edit survives the
    #     comparison even when a lossy clean filter would normalize it away
    #     — and where `core.fileMode` says the filesystem tracks it, a
    #     chmod-only difference from the index mode is an edit too;
    #   - a symlink is compared by its target against the index blob
    #     (hashing it would follow the link), byte-exact via the `printf x`
    #     sentinels, which stop command substitution eating the newlines
    #     that distinguish `target` from `target\n`; under
    #     `core.symlinks=false` git legitimately checks a symlink entry out
    #     as a regular file holding the target text, so that representation
    #     is compared the same way instead of read as a type change;
    #   - anything unreadable, unhashable, or of unexpected type counts as
    #     different, which can only refuse a removal that was safe.
    if [ "$force" -eq 0 ]; then
        # Per-tree constants, resolved ONCE before the loop. A sparse
        # monorepo can hold hundreds of thousands of absent `S` entries, and
        # a per-entry `git config` spawn turned a clean removal into minutes.
        sparse_enabled="$(git -C "$tree" config --get --type=bool --default=false core.sparseCheckout 2>/dev/null || echo false)"
        filemode_enabled="$(git -C "$tree" config --get --type=bool --default=true core.fileMode 2>/dev/null || echo true)"
        symlinks_enabled="$(git -C "$tree" config --get --type=bool --default=true core.symlinks 2>/dev/null || echo true)"
        sparse_rules_checkable=0
        if [ "$sparse_enabled" = "true" ] && git_supports_check_rules; then
            sparse_rules_checkable=1
        fi
        # Absent flagged paths whose exemption depends on the sparse rules,
        # deferred to ONE batched check-rules call after the enumeration. A
        # bash array, not a delimited string: a variable cannot hold the NUL
        # this stream frames with, and any other delimiter can occur in a
        # path.
        sparse_absent_candidates=()
        hidden_paths=""
        flagged_enum_ok=0
        while IFS= read -r -d '' flagged_entry; do
            # The sentinel is appended by the producer ONLY after a
            # successful full enumeration; bash does not propagate a
            # process-substitution failure, so without it a git error or
            # truncated stream would fail OPEN and wave the removal
            # through on an incomplete scan. A tracked file of the same
            # name cannot forge it — real entries carry a tag prefix.
            if [ "$flagged_entry" = "__WORKTREE_RM_ENUM_OK__" ]; then
                flagged_enum_ok=1
                continue
            fi
            flagged_tag="${flagged_entry%% *}"
            case "$flagged_tag" in
            S | [a-z]) : ;;
            *) continue ;;
            esac
            flagged_path="${flagged_entry#? }"
            flagged_differs=1
            if [ ! -e "$tree/$flagged_path" ] && [ ! -L "$tree/$flagged_path" ]; then
                case "$flagged_tag" in
                S | s)
                    if [ "$sparse_enabled" = "true" ]; then
                        if [ "$sparse_rules_checkable" -eq 1 ]; then
                            # Excluded-or-deleted is decided by the batched
                            # check-rules call after the enumeration, not
                            # here: deferring keeps this loop spawn-free
                            # per entry.
                            sparse_absent_candidates+=("$flagged_path")
                        fi
                        # git < 2.42: the documented whole-tree exemption
                        # (see the guard comment above).
                        continue
                    fi
                    ;;
                esac
            else
                # Look the entry up with --literal-pathspecs: without it, a
                # tracked filename that LOOKS like pathspec magic
                # (`:(literal)foo`) or like a glob resolves some OTHER index
                # entry — and comparing the file against the wrong blob can
                # wave a real edit through.
                index_entry="$(git --literal-pathspecs -C "$tree" ls-files -s -z -- "$flagged_path" | tr -d '\0')"
                # Parse the fixed "mode SP sha SP stage TAB name" prefix by
                # parameter expansion, never by line-based tools: -z keeps a
                # newline INSIDE a filename verbatim, and awk would read the
                # name's remainder as more records and corrupt the sha.
                index_mode="${index_entry%% *}"
                index_rest="${index_entry#* }"
                index_sha="${index_rest%% *}"
                if [ "$index_mode" = "120000" ]; then
                    # A real symlink is the clean representation only where
                    # git is actually checking symlinks out (core.symlinks):
                    # with them disabled, git writes a regular file holding
                    # the target text, so an actual symlink there is a local
                    # type change to refuse.
                    if [ -L "$tree/$flagged_path" ] && [ "$symlinks_enabled" = "true" ]; then
                        link_target="$(readlink -n "$tree/$flagged_path" 2>/dev/null && printf x)"
                        blob_target="$(git -C "$tree" cat-file blob "$index_sha" 2>/dev/null && printf x)"
                        if [ -n "$link_target" ] && [ "$link_target" = "$blob_target" ]; then
                            flagged_differs=0
                        fi
                    elif [ ! -L "$tree/$flagged_path" ] && [ -f "$tree/$flagged_path" ] &&
                        [ "$symlinks_enabled" = "false" ]; then
                        # Byte-exact via cmp, not shell variables: command
                        # substitution strips NUL bytes, which would let a
                        # binary local file compare equal to a text target.
                        if git -C "$tree" cat-file blob "$index_sha" 2>/dev/null |
                            cmp -s - "$tree/$flagged_path" 2>/dev/null; then
                            flagged_differs=0
                        fi
                    fi
                elif [ "$index_mode" = "160000" ]; then
                    # A gitlink. Uninitialized — an empty directory with no
                    # .git — is its clean checkout representation, holding
                    # nothing local to lose. An INITIALIZED submodule never
                    # reaches the removal decision at all: git itself
                    # refuses to remove a worktree containing submodules,
                    # so leaving it "different" only puts this guard's
                    # message ahead of git's own refusal.
                    if [ -d "$tree/$flagged_path" ] && [ ! -e "$tree/$flagged_path/.git" ] &&
                        [ -z "$(find "$tree/$flagged_path" -mindepth 1 -maxdepth 1 2>/dev/null | head -n 1)" ]; then
                        flagged_differs=0
                    fi
                elif [ ! -L "$tree/$flagged_path" ] && [ -f "$tree/$flagged_path" ]; then
                    # Compare against the CHECKOUT representation —
                    # `cat-file --filters` applies smudge/eol exactly as a
                    # fresh checkout would. Hashing the CLEANED working file
                    # would instead miss any edit a non-round-tripping clean
                    # filter discards: bytes a fresh checkout could not
                    # restore, which is precisely what this guard protects.
                    if git -C "$tree" cat-file --filters --path="$flagged_path" "$index_sha" 2>/dev/null |
                        cmp -s - "$tree/$flagged_path" 2>/dev/null; then
                        flagged_differs=0
                        if [ "$filemode_enabled" = "true" ]; then
                            # The OWNER-execute bit, which is what git's
                            # filemode tracks — `test -x` asks whether THIS
                            # process may execute the file, which diverges
                            # under root (any x bit satisfies it) and ACLs.
                            owner_exec="$(find "$tree/$flagged_path" -prune -perm -u+x 2>/dev/null)"
                            case "$index_mode" in
                            100644) [ -z "$owner_exec" ] || flagged_differs=1 ;;
                            100755) [ -n "$owner_exec" ] || flagged_differs=1 ;;
                            esac
                        fi
                    fi
                fi
            fi
            if [ "$flagged_differs" -eq 1 ]; then
                hidden_paths="${hidden_paths}  ${flagged_path}
"
            fi
        done < <(git -C "$tree" ls-files -v -z && printf '__WORKTREE_RM_ENUM_OK__\0')
        if [ "$flagged_enum_ok" -ne 1 ]; then
            die "could not enumerate $tree's index entries for the hidden-edit check — this guard fails closed; fix the enumeration (or discard the tree with --force)"
        fi
        # ONE query for every deferred absent flagged path: check-rules
        # echoes back exactly the paths the tree's active sparse rules MATCH
        # (would keep present), so an echoed path is in-cone — its absence is
        # a user's deletion, refused like any hidden deletion — and a path
        # not echoed is excluded, absent because sparse removed it. `-C
        # "$tree"` is load-bearing: check-rules reads the invoking worktree's
        # own sparse-checkout state, and each linked worktree carries its own
        # (extensions.worktreeConfig).
        #
        # The trailing empty record is this pipeline's success sentinel,
        # mirroring flagged_enum_ok above: bash does not propagate a
        # process-substitution failure, so without it a check-rules error or
        # truncated stream would fail OPEN and wave the removal through. An
        # empty record is unforgeable here — check-rules only echoes paths it
        # was fed, and no index entry has an empty path.
        if [ "${#sparse_absent_candidates[@]}" -gt 0 ]; then
            sparse_rules_ok=0
            while IFS= read -r -d '' incone_path; do
                if [ -z "$incone_path" ]; then
                    sparse_rules_ok=1
                    continue
                fi
                hidden_paths="${hidden_paths}  ${incone_path}
"
            done < <(printf '%s\0' "${sparse_absent_candidates[@]}" |
                git -C "$tree" sparse-checkout check-rules -z && printf '\0')
            if [ "$sparse_rules_ok" -ne 1 ]; then
                die "could not evaluate $tree's sparse rules for the hidden-edit check — this guard fails closed; fix the sparse-checkout state (or discard the tree with --force)"
            fi
        fi
        if [ -n "$hidden_paths" ]; then
            echo "worktree:rm: $tree has local edits hidden from git status by skip-worktree / assume-unchanged:" >&2
            printf '%s' "$hidden_paths" >&2
            die "clear the flag (git update-index --no-skip-worktree / --no-assume-unchanged <path>) and commit or push the edits, or re-run with --force to discard them"
        fi
    fi
    # An in-progress rebase/merge/cherry-pick leaves a CLEAN status once it
    # stops at an edit, so the check above waves it through — while the
    # per-worktree git dir still holds the sequencer state and, after a `commit
    # --amend` at that stop, a commit reachable from nothing else. Removing the
    # tree drops that state, and gc eventually collects the commit. Likewise a
    # detached HEAD ahead of every branch: nothing else references it.
    # MERGE_AUTOSTASH is listed on its own because it can exist alone: a
    # `git merge --autostash` killed after the autostash is written but before
    # MERGE_HEAD exists leaves the user's dirty work referenced by that one
    # file and nothing else.
    if [ "$force" -eq 0 ]; then
        tree_git_dir="$(git -C "$tree" rev-parse --path-format=absolute --git-dir)"
        for op_state in rebase-merge rebase-apply MERGE_HEAD MERGE_AUTOSTASH CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG; do
            if [ -e "$tree_git_dir/$op_state" ]; then
                # "finish or abort" is impossible advice for a marker-only
                # autostash: with MERGE_HEAD absent, `git merge --continue` and
                # `--abort` both refuse, and `git merge --quit` is the command
                # that moves the referenced work to refs/stash.
                if [ "$op_state" = MERGE_AUTOSTASH ]; then
                    die "$tree has an autostash from an interrupted merge ($op_state) — run 'git merge --quit' there to move it to the stash, then recover it from 'git stash list' (the stash is repository-wide, so pop that entry, not blindly the newest), or re-run with --force to discard it"
                fi
                die "$tree has an in-progress git operation ($op_state) — finish or abort it, or re-run with --force to discard it"
            fi
        done
        # `for-each-ref`, not `branch --contains`: the latter lists the current
        # detached HEAD itself as a `(HEAD detached at ...)` pseudo-entry, so it
        # is never empty here and the guard would never fire.
        #
        # SHARED refs, which is wider than refs/heads and narrower than "all".
        # A tag or a remote-tracking ref keeps the commit just as reachable as a
        # branch does, so restricting to branches would refuse a perfectly safe
        # removal — pushing people toward --force for a tree that was never at
        # risk, which is how a guard stops being believed. But "all refs" counts
        # this worktree's own `refs/worktree/*`, which dies with it; see
        # shared_refs_containing.
        if ! git -C "$tree" symbolic-ref -q HEAD >/dev/null &&
            [ -z "$(shared_refs_containing "$(git -C "$tree" rev-parse HEAD)")" ]; then
            die "$tree is on a detached HEAD no branch contains — the commits there would become unreachable; branch or note them, or re-run with --force"
        fi
    fi
    # `git worktree remove` counts modified and untracked files, but NOT ignored
    # ones — so without this a plain remove silently deletes a `.env`, an
    # `.envrc.local`, or ignored notes, which is not what "--force to discard
    # uncommitted work" promises.
    #
    # The exemption is an ALLOWLIST of directories a tool can rebuild, not "any
    # ignored directory": a repo that gitignores `local-data/` or `fixtures/`
    # keeps its only copy there, and waving those through would be the same
    # data-loss path one level up. Everything not on the list — files and
    # directories alike — needs --force. The list is deliberately dull:
    # package-manager and build output, which `worktree:new`, `task install`, or
    # `task build` regenerate.
    #
    # Matching is per FILE, on whether any path component is a reinstallable
    # directory — `(^|/)name/` — rather than on collapsed directory entries.
    # `git ls-files --directory` collapses at the highest wholly-untracked
    # directory, so a monorepo's `packages/api/node_modules/...` arrives as
    # plain `packages/`, which no allowlist of cache names can recognise. Per
    # component it also handles depth for free: a `__pycache__` beside every
    # module, node_modules under every package.
    if [ "$force" -eq 0 ]; then
        reinstallable='(^|/)(node_modules|\.venv|venv|\.task|\.turbo|\.next|\.astro|\.nuxt|\.svelte-kit|\.parcel-cache|\.pytest_cache|\.mypy_cache|\.ruff_cache|__pycache__|dist|build|target|coverage|playwright-report|test-results|\.terraform)/'
        ignored_state="$(
            git -C "$tree" ls-files --others --ignored --exclude-standard |
                grep -Ev "$reinstallable" | head -n 20 || true
        )"
        if [ -n "$ignored_state" ]; then
            echo "worktree:rm: $tree holds ignored local state that removal would delete:" >&2
            printf '%s\n' "$ignored_state" | sed 's/^/  /' >&2
            die "move or copy it out, or re-run with --force to discard it"
        fi
    fi
    # Step out of the tree before deleting it. Finishing work inside the
    # worktree and removing it from there is the natural gesture, and it would
    # otherwise delete this process's own cwd — after which `git worktree prune`
    # below dies with "Unable to read current working directory" and the task
    # reports failure having already removed the tree.
    cd "$main_root" || die "could not change to $main_root"
    if [ "$force" -eq 1 ]; then
        git worktree remove --force "$tree"
    else
        git worktree remove "$tree"
    fi
fi

# Drop the registry record for THIS path when it outlived its directory. This is
# the #716 class: a stale record (or a leftover directory holding only a .git
# gitlink file) makes later tooling treat a dead path as a live checkout.
#
# Deliberately NOT `git worktree prune`: prune takes no path and is
# repository-WIDE, so removing one worktree would also drop every OTHER stale
# record — and such a record can be the only thing referencing a detached HEAD,
# which is precisely the metadata `worktree:new` now refuses to provision over.
# Removing one worktree must never reach into another's state.
#
# `git worktree remove` accepts a path whose directory is already gone and drops
# just that record, so it is the scoped form of the prune. It refuses a LOCKED
# record, which the check below turns into an actionable message rather than a
# false "removed".
#
# Gated on the ENTRY snapshot, not on "is anything registered here now". Only
# the stale-record branch above leaves a record for this step to clear: a live
# removal already dropped its own, and an unregistered path never had one. Re-
# deriving it here would let a concurrent `worktree:new` that claimed this name
# in the meantime have its brand-new worktree removed by this run. The
# directory is re-checked immediately before acting for the same reason — a
# recreated worktree has one, a genuinely stale record does not.
prune_err=""
if [ "$stale_record" -eq 1 ] && git worktree list --porcelain | grep -qxF "worktree $tree"; then
    if [ -d "$tree" ]; then
        die "$tree was recreated while this removal was running (another 'task worktree:new'?) — refusing to remove a worktree this run did not"
    fi
    prune_err="$(git worktree remove "$tree" 2>&1 >/dev/null)" || true
    if git worktree list --porcelain | grep -qxF "worktree $tree"; then
        # `remove --force` is NOT enough for a locked record — git answers a
        # single force with "use 'remove -f -f' to override or unlock first" —
        # so the instruction leads with the unlock, which is the path that also
        # works when the directory is already gone.
        die "$tree is still registered after cleanup (${prune_err:-git reported no reason}) — if its record is locked, run 'git worktree unlock \"$tree\"' then re-run, or force past the lock with 'git worktree remove -f -f \"$tree\"'"
    fi
fi

# `git worktree remove` leaves the directory in place when it failed or when the
# registry record was already gone. Clear it only when nothing but git's own
# gitlink remains, and only under .worktrees/ — never guess at a wider path.
#
# A `.git` DIRECTORY is not that: a linked worktree's gitlink is a FILE, so a
# directory there means a standalone repository or an interrupted clone lives at
# this path, and its `.git` holds the only copy of that repository's objects.
# Auto-cleaning the file shape is safe; the directory shape gets the same
# refusal as any other unexpected content.
if [ -d "$tree" ]; then
    leftovers="$(find "$tree" -mindepth 1 -maxdepth 1 ! -name .git | head -n 1)"
    if [ -z "$leftovers" ] && [ ! -d "$tree/.git" ]; then
        rm -rf "$tree"
        echo "==> Removed leftover gitlink directory $tree"
    elif [ -d "$tree/.git" ]; then
        die "$tree holds a .git DIRECTORY, so it is a repository of its own rather than worktree debris — inspect it and delete it by hand"
    else
        die "$tree still holds files after removal — inspect it and delete it by hand"
    fi
fi

# Empty leftovers are noise. A slash-delimited name like `feat/foo` leaves an
# empty `.worktrees/feat` behind, so walk up from the removed tree, stopping at
# .worktrees/ itself (which is also removed when it was the last tree). rmdir
# only ever removes an EMPTY directory, so this cannot take a live tree with it.
parent="$(dirname "$tree")"
while [ "$parent" != "$main_root" ] && [ "$parent" != "/" ]; do
    # Never delete a shared ancestor a live sibling operation still holds:
    # the walk yields to any foreign holder marker rather than racing the
    # sibling's own two-step path claim. An empty directory left under
    # contention is noise; a deleted one is a spurious sibling failure.
    parent_rel="${parent#"$main_root/.worktrees"}"
    parent_rel="${parent_rel#/}"
    if [ -n "$parent_rel" ]; then
        parent_enc="$(printf '%s' "$parent_rel" | tr '/' '%' | tr '[:upper:]' '[:lower:]')"
        if [ "${#parent_enc}" -gt 200 ]; then
            parent_enc="h$(printf '%s' "$parent_enc" | cksum | tr ' \t' '--')"
        fi
        ancestor_holders_quiet "$parent_enc" || break
    fi
    rmdir "$parent" 2>/dev/null || break
    parent="$(dirname "$parent")"
done

# The final line reports what actually happened, from the entry snapshot.
# `stale_record` means the registry held a record whose directory was already
# gone when this run started: nothing was removed from disk, and saying
# "Worktree removed" there contradicted the line above it and claimed the
# removal of a directory that never existed (#963 AC: the message must
# distinguish "removed a worktree" from "cleared a stale record" from "found
# nothing" — the third is the refusal branch above).
if [ "$stale_record" -eq 1 ]; then
    echo "Stale record cleared: $tree (no worktree directory existed)"
else
    echo "Worktree removed: $tree"
fi
