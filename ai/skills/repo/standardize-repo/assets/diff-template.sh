#!/usr/bin/env bash
# diff-template.sh — show how a repo's template-owned files differ from a fresh
# harmon-init render, so the agent can find missed template improvements.
#
# Renders harmon-init using the TARGET repo's own .copier-answers.yml, then
# compares the WHOLE render against the repo and reports:
#   • DRIFT    — content differences. In the curated template-owned-files.txt set
#                (mapping .yml<->.yaml) a listed file may differ because the repo
#                legitimately customized it (terraform tasks, a custom status
#                section) OR because it's missing template improvements (the
#                recurring status.sh / lint-hygiene / bootstrap class). The same
#                DRIFT is reported — tagged "uncurated" — for rendered files the
#                manifest does NOT list: the manifest is hand-maintained, covers
#                58 entries and no prose at all, so comparing content only within
#                it left most of the render unchecked. A rendered path the repo
#                HAD was skipped outright, however far it had diverged.
#   • MODE     — executable-bit differences, in the curated set and the sweep
#                alike. Copier can preserve content while a manual copy silently
#                drops `+x`, leaving a generated script present but unusable.
#                Symlinks are exempt: the bit belongs to the link target.
#                Reported INDEPENDENTLY of the content class and always gating,
#                CO-OWNED and IGNORED included — the exec bit is structural, and
#                nobody "owns" a generated script that stopped being runnable.
#   • MISSING  — template files the repo lacks ENTIRELY. This scan is
#                manifest-INDEPENDENT (it walks the whole render), because the
#                manifest is hand-maintained and lags the template — a file added
#                after the last manifest edit, or dropped by a hand-reconciled
#                `copier update`, would otherwise slip through silently. (.gitkeep
#                dir-stubs are listed as benign ABSENT, not flagged as drift.)
#                A tracked file deleted only from the working tree is compared
#                from the index, so an unstaged/transient delete is not reported
#                as drift; once the deletion is staged it is real MISSING. That
#                includes a `git rm --cached` whose working-tree copy SURVIVES:
#                present in HEAD, gone from the index, so the next commit deletes
#                a template-owned file. The surviving copy otherwise compared
#                clean — or collected the IGNORED exemption, since dropping the
#                index entry is what makes check-ignore start calling it
#                ignored — and the deletion went unreported.
#   • EQUIV    — a mature nested Terraform layout, or a renumbered/established ADR
#                log, intentionally replacing a generated seed path. Benign.
#   • CO-OWNED — the template SEEDS the file but the repo owns its PROSE
#                (AGENTS.md and its symlink aliases, README, the *.md under
#                docs/ and specs/, the devcontainer zshrc, …). The docs/ and
#                specs/ globs are filtered to Markdown deliberately: a build
#                script or generated config under a docs tree is not prose
#                anybody rewrote, and letting it inherit this exemption for its
#                directory alone is the opposite of safe-by-default. Non-prose
#                there gates as ordinary uncurated DRIFT.
#                Divergence is the expected steady state
#                there, so these are reported PRESENCE-ONLY: no diff is printed,
#                not even under --show, and their CONTENT never affects the exit
#                status (a MODE finding on one still gates — see above).
#                Their value is the INVERSE signal — a CO-OWNED line that
#                DISAPPEARS after a `copier update` means the repo's copy is now
#                byte-identical to the template's, i.e. the customizations were
#                clobbered.
#   • IGNORED  — the repo's copy is UNTRACKED and BOTH the repo and the TEMPLATE
#                ignore the path (a resolved .envrc and friends). Presence-only
#                for the same reason plus a harder one: a resolved local config
#                can hold real secrets, so its diff is never printed. Its
#                content never affects the exit status.
#                The template's declaration is what grants this, never the
#                repo's habits. A repo that adds .vscode/ to its OWN .gitignore
#                has said nothing about the artifact — every other clone still
#                renders it — so a path the repo ignores and the template TRACKS
#                is gating DRIFT, tagged "repo-ignored, but the template tracks
#                this file". Its body is still withheld: somebody marked that
#                path local-only, and being wrong about whether it is drift does
#                not make its contents safe to print.
# Ignore rules drive two INDEPENDENT axes, because "does this gate?" and "is
# this safe to print?" are different questions:
#   – CLASSIFICATION follows repo STATE and then the TEMPLATE's declaration.
#     Only an UNTRACKED file that BOTH sides ignore is the informational IGNORED
#     class; a TRACKED one gates like any other file, ignore rules or not,
#     because tracked content is template-relevant, and a repo-only ignore gates
#     too, because ignoring a file is a habit rather than a statement about the
#     artifact. `git check-ignore` answers the tracked half exactly — it
#     consults the index, so it never calls a tracked file ignored — and a
#     scratch repo built from the RENDER's .gitignore files answers the other.
#   – WITHHOLDING follows the PATH alone, under the UNION of both rule sets
#     (`check-ignore --no-index` on the repo side so the index cannot mask the
#     pattern). NO diff this script prints for a pattern-matching path is ever
#     emitted — CURATED AND SWEPT ALIKE, and not even for a finding that gates.
#     Being on the hand-maintained manifest says the template owns the path, not
#     that the repo's copy is safe to echo: the manifest lists
#     .claude/settings.json, exactly the shape whose local copy holds
#     credentials. A repo can also `git add -f` a resolved config, and tracking
#     it makes that file reviewable, not publishable — or simply FAIL to ignore
#     what the template declares local, which is the same secret in a less
#     careful repo. A one-line note replaces the body.
# CLASSIFICATION requires the target to be a repository root of its OWN. A plain
# directory nested inside somebody else's work tree gets no IGNORED class,
# because inheriting a stranger's ignore rules would silently downgrade real
# drift; everything there falls through to gating DRIFT. The render half of
# WITHHOLDING still applies there — it needs no work tree, and a
# template-declared-local body is no safer to print for having landed in a
# directory that is not a repo.
# Symlinks are compared by LINK TARGET, not by content: the template ships
# CLAUDE.md, GEMINI.md, and .github/copilot-instructions.md as symlinks to
# AGENTS.md (_preserve_symlinks), so content-diffing them would report a single
# AGENTS.md divergence four times over. A path that is a symlink on one side and
# a regular file on the other, or a link pointing somewhere else, is a
# STRUCTURAL divergence and always gates — the CO-OWNED/IGNORED exemptions cover
# content, because prose is what a repo owns; nobody "owns" an alias that stopped
# being an alias, and the finding is one line of metadata, not a diff to withhold.
# The CURATED loop enforces this too. It used a bare `diff -q`, which FOLLOWS a
# symlink, so a manifest-listed regular file swapped for a link to a
# byte-identical referent passed clean there while the sweep gated the identical
# shape; both now share one comparison routine so they cannot diverge again.
# This is a REVIEW AID for apply/update/audit, not a pass/fail gate. For each
# DRIFT/MISSING, inspect and reconcile — pull template improvements in via
# `copier update`, keep legit local customizations.
#
# Usage: diff-template.sh [-v|--show] [TARGET_DIR]   (default target: .)
#        Flags and the target dir may appear in any order.
# Env:   HARMON_INIT   explicitly prepared template checkout (advanced/test use)
#        HARMON_INIT_RECORDED_COMMIT immutable commit in that checkout
#
# Exit: 0 = no drift, 1 = drift found (for callers that want a signal), 2 = setup error.
# Portable to macOS bash 3.2 (no mapfile, no grep -P, no associative arrays).
set -euo pipefail

show=0
target=""
while [ $# -gt 0 ]; do
    case "$1" in
    -v | --show) show=1 ;;
    -*)
        echo "FAIL: unknown argument '$1' (usage: diff-template.sh [-v|--show] [TARGET_DIR])" >&2
        exit 2
        ;;
    *)
        if [ -n "$target" ]; then
            echo "FAIL: more than one target dir given ('$target' and '$1')" >&2
            exit 2
        fi
        target="$1"
        ;;
    esac
    shift
done
[ -n "$target" ] || target="."
template_is_explicit=0
if [ "${HARMON_INIT+x}" = x ]; then
    template_is_explicit=1
    template="$HARMON_INIT"
else
    template="$HOME/git/harmon-init"
fi
here="$(cd "$(dirname "$0")" && pwd)"
manifest="$here/template-owned-files.txt"

have() { command -v "$1" >/dev/null 2>&1; }
for t in copier yq; do
    have "$t" || {
        echo "FAIL: required tool '$t' is not installed" >&2
        exit 2
    }
done
if [ "$template_is_explicit" -eq 1 ] ||
    [ -n "${HARMON_INIT_RECORDED_COMMIT:-}" ]; then
    [ -d "$template" ] || {
        echo "FAIL: prepared template not found at $template" >&2
        exit 2
    }
fi
[ -f "$manifest" ] || {
    echo "FAIL: manifest not found at $manifest" >&2
    exit 2
}

target="$(cd "$target" && pwd)"
answers="$target/.copier-answers.yml"
[ -f "$answers" ] || {
    echo "FAIL: $target has no .copier-answers.yml — not a template-linked repo" >&2
    exit 2
}

workdir="$(mktemp -d -t harmon-init-render-XXXXXX)"
trap 'chmod -R u+w "$workdir" 2>/dev/null || true; rm -rf "$workdir"' EXIT
render="$workdir/render"
index_root="$workdir/index-snapshot"

# Reconstruct the recorded answers as a --data-file (skip copier's _ keys and
# nulls). A YAML data file — not per-key `--data k=v` strings — is required to
# round-trip non-scalar answers: the `skill_categories` multiselect is a LIST,
# and stringifying it as `--data` emits broken `k=- item` lines that fail the
# render for every repo whose answers record it (_commit >= v3.23.0).
datafile="$workdir/answers-data.yml"
yq 'with_entries(select((.key | test("^_") | not) and (.value != null)))' "$answers" >"$datafile"

# The fleet policy treats a legacy answer file that predates use_coderabbit as
# opted out. Its recorded template baseline may still render .coderabbit.yaml
# unconditionally, so apply that effective answer when interpreting drift
# rather than telling an agent to restore the intentionally removed file.
effective_use_coderabbit="$(yq -r '.use_coderabbit // false' "$answers" 2>/dev/null || echo false)"
case "$effective_use_coderabbit" in
true | false) ;;
*)
    echo "FAIL: use_coderabbit must be true or false in $answers" >&2
    exit 2
    ;;
esac

# Force every side-effect off in the throwaway render (`--data` wins over
# `--data-file`).
data_args=(
    --data git_init=false
    --data github_remote_create=false
    --data github_release_init=false
    --data run_task_install=false
    --data bunch_add=false
    --data obsidian_project_add=false
)

# Render at the version the repo is PINNED to (_commit), not the template's HEAD.
# Drift should mean "what this repo customized relative to its own template
# baseline" — rendering at HEAD instead conflates that with template changes the
# repo simply hasn't pulled yet (which is what made early audits look huge).
# Falls back to HEAD if _commit is somehow absent.
src_ref="$(yq -r '._commit // "HEAD"' "$answers" 2>/dev/null || echo HEAD)"
[ -n "$src_ref" ] || src_ref=HEAD

# A normal audit must not trust a mutable tag in the caller's default local
# harmon-init checkout. Snapshot the canonical remote, freeze the recorded
# baseline, and render from that no-remote read-only clone. An explicit
# HARMON_INIT is reserved for callers (such as guarded update mode and hermetic
# tests) that already prepared their own trust boundary.
if [ -n "${HARMON_INIT_RECORDED_COMMIT:-}" ]; then
    case "$HARMON_INIT_RECORDED_COMMIT" in
    *[!0-9a-fA-F]*)
        echo "FAIL: HARMON_INIT_RECORDED_COMMIT must be a 40-character commit" >&2
        exit 2
        ;;
    esac
    [ "${#HARMON_INIT_RECORDED_COMMIT}" -eq 40 ] || {
        echo "FAIL: HARMON_INIT_RECORDED_COMMIT must be a 40-character commit" >&2
        exit 2
    }
    git -C "$template" cat-file -e "$HARMON_INIT_RECORDED_COMMIT^{commit}" ||
        {
            echo "FAIL: prepared template lacks HARMON_INIT_RECORDED_COMMIT" >&2
            exit 2
        }
    src_ref="$HARMON_INIT_RECORDED_COMMIT"
elif [ "$template_is_explicit" -eq 0 ]; then
    canonical_source=https://github.com/evanharmon1/harmon-init
    recorded_source="$(yq -r '._src_path // ""' "$answers")"
    case "$recorded_source" in
    "$canonical_source" | "$canonical_source.git") ;;
    *)
        echo "FAIL: recorded _src_path is not canonical harmon-init" >&2
        exit 2
        ;;
    esac
    [ "$src_ref" != HEAD ] || {
        echo "FAIL: recorded _commit is required for a guarded audit" >&2
        exit 2
    }
    remote_tag_object=""
    if printf '%s\n' "$src_ref" | grep -Eq '^[0-9a-fA-F]{40}$'; then
        :
    elif printf '%s\n' "$src_ref" | grep -Eq '^[0-9a-fA-F]{7,39}$'; then
        echo "FAIL: abbreviated recorded commits are not accepted" >&2
        exit 2
    else
        [ "${ACCEPT_LEGACY_BASELINE:-}" = true ] || {
            echo "FAIL: tag-valued baseline needs maintainer-approved ACCEPT_LEGACY_BASELINE=true" >&2
            exit 2
        }
        remote_tag_object="$(
            git ls-remote --exit-code "$canonical_source" "refs/tags/$src_ref" |
                awk 'NR == 1 { print $1 }'
        )" || {
            echo "FAIL: recorded tag is not present on canonical harmon-init" >&2
            exit 2
        }
        [ -n "$remote_tag_object" ] || {
            echo "FAIL: canonical recorded tag resolved to no object" >&2
            exit 2
        }
    fi
    guarded_template="$workdir/guarded-template"
    git clone --no-checkout "$canonical_source" "$guarded_template" >/dev/null 2>&1 ||
        {
            echo "FAIL: cannot snapshot canonical harmon-init" >&2
            exit 2
        }
    if [ -n "$remote_tag_object" ]; then
        [ "$(git -C "$guarded_template" rev-parse "refs/tags/$src_ref")" = \
            "$remote_tag_object" ] || {
            echo "FAIL: recorded tag changed during guarded audit preparation" >&2
            exit 2
        }
    fi
    recorded_commit="$(git -C "$guarded_template" rev-parse "$src_ref^{commit}")" ||
        {
            echo "FAIL: recorded baseline is not a commit in canonical harmon-init" >&2
            exit 2
        }
    git -C "$guarded_template" merge-base --is-ancestor \
        "$recorded_commit" origin/main || {
        echo "FAIL: recorded baseline is not on canonical origin/main" >&2
        exit 2
    }
    v3_commit="$(git -C "$guarded_template" rev-parse "v3.0.0^{commit}")" ||
        {
            echo "FAIL: cannot resolve the v3 migration boundary" >&2
            exit 2
        }
    git -C "$guarded_template" merge-base --is-ancestor \
        "$v3_commit" "$recorded_commit" || {
        echo "FAIL: recorded baseline predates v3; use adoption mode" >&2
        exit 2
    }
    if git -C "$guarded_template" cat-file -e \
        "$recorded_commit:.gitmodules" 2>/dev/null; then
        echo "FAIL: guarded audits do not support template submodules" >&2
        exit 2
    fi
    git -C "$guarded_template" remote remove origin
    chmod -R a-w "$guarded_template"
    template="$guarded_template"
    src_ref="$recorded_commit"
fi

copier copy "$template" "$render" --vcs-ref="$src_ref" --trust --defaults \
    --data-file "$datafile" "${data_args[@]}" >/dev/null 2>&1 || {
    echo "FAIL: copier render failed (template ref: $src_ref)" >&2
    exit 2
}

# --- What the target actually is ---------------------------------------------
# Settled once, before anything resolves a path inside it, because three
# separate guarantees below hang off the answer: the index fallback, the IGNORED
# class, and the repo-side half of the withholding probe.
#
# The question is whether the target IS a repository root of its own, not
# whether it sits inside one. `rev-parse --is-inside-work-tree` answers the
# second and reads true for a plain directory nested in somebody else's work
# tree — the audit accepts a plain directory, and the hermetic tests point it at
# exactly that shape — so every consumer of the looser test was quietly
# answering about whatever repository happens to contain the temp dir. Compare
# the detected toplevel against the target's own path instead, normalizing both
# with `cd` + `pwd -P`: `$target` above is a LOGICAL pwd while git always
# reports a resolved one, so on macOS's symlinked /var a real repo root would
# never match otherwise (`realpath` is not portable to those hosts).
#
# When they differ the target is treated as the plain directory it is: no index
# fallback, no IGNORED class, no repo-side pattern probes — disk-only presence
# semantics, and everything falls through to gating DRIFT. A plain directory has
# neither ignore rules nor an index of its own, and borrowing a stranger's is
# worse than surfacing the drift. The RENDER-side probe is unaffected and still
# withholds bodies here: it asks what the template declared, which no property
# of the target can change.
#
# `rev-parse --show-toplevel` has THREE outcomes and the first version of this
# collapsed the last two: it succeeded, it said "this is not a repository", or
# it could not tell (dubious ownership, unreadable metadata, a malformed .git).
# Reading "could not tell" as a plain directory is fail-OPEN — it skips the repo
# half of the withholding probe, so a repo-only-ignored secret would print under
# --show precisely because git could not read the repo. LC_ALL=C pins the
# message being matched; git localizes its output otherwise.
target_owns_worktree=0
target_physical="$(cd "$target" && pwd -P)"
toplevel_rc=0
toplevel="$(LC_ALL=C git -C "$target" rev-parse --show-toplevel 2>&1)" ||
    toplevel_rc=$?
toplevel_says_no_repo=0
case "$toplevel" in
*'not a git repository'*) toplevel_says_no_repo=1 ;;
esac
if [ "$toplevel_rc" -eq 0 ]; then
    if [ -d "$toplevel" ] &&
        [ "$(cd "$toplevel" && pwd -P)" = "$target_physical" ]; then
        target_owns_worktree=1
    fi
elif [ "$toplevel_says_no_repo" -eq 1 ] &&
    [ ! -e "$target/.git" ] && [ ! -L "$target/.git" ]; then
    # Genuinely not a repository: git says so AND there is no .git of any kind
    # to have gone wrong. Both halves are needed — a .git pointing at a gitdir
    # that no longer exists reports "not a git repository" too, and that is a
    # broken repo rather than the plain directory this audit accepts.
    :
else
    echo "FAIL: cannot determine whether $target is a git work tree" >&2
    [ -z "$toplevel" ] || printf '  %s\n' "$toplevel" >&2
    echo "  refusing to continue: an unreadable repo would skip the repo-side ignore probe" >&2
    exit 2
fi

# `-L` only ever tests a path's FINAL component, so every symlink check in this
# script was blind to the directories above it. A repo whose `scripts` is a link
# to `../shared-scripts` let `-f "$target/scripts/status.sh"` succeed, and the
# comparison then read — and under --show PRINTED — a file outside the
# repository entirely, reporting clean or DRIFT on content that is not the
# repo's. Resolve the physical parent and require it to be exactly where the
# target root says it should be.
#
# The rule is ANY symlinked parent component, not just an escaping one. That is
# both simpler and more honest: the template renders real directories, so a
# repo that replaced one with a link has diverged structurally whether or not
# the link stays inside. It also keeps the inside/outside distinction off the
# security-critical path — one comparison, and nothing is ever followed out of
# the tree. Comparing the resolved parent against the EXPECTED physical parent
# catches both at once, because they can only differ when some component
# between the root and the file is a link.
repo_parent_note=""
repo_parent_diverges() {
    rpd_abs="$1"
    repo_parent_note=""
    # Index-snapshot variants are materialized by us from blob content, under
    # the workdir rather than the repo. They have no repo directories above them
    # to have been swapped for links.
    case "$rpd_abs" in
    "$target"/*) ;;
    *) return 1 ;;
    esac
    rpd_rel="${rpd_abs#"$target"/}"
    case "$rpd_rel" in
    # Nothing sits between a root-level file and the root itself.
    */*) rpd_dir_rel="${rpd_rel%/*}" ;;
    *) return 1 ;;
    esac
    # A parent has THREE states and only one of them is a divergence. The first
    # version of this collapsed the last two, because a failed `cd` cannot tell
    # "the directory was replaced by a link that goes nowhere" from "the
    # directory is not there" — so a template that grew a new nested directory
    # reported structural DRIFT for every file under it instead of MISSING, and
    # an unstaged deletion of a tracked directory reported the same instead of
    # being compared from the index. Walk the components between the root and
    # the file's directory to tell them apart:
    #   • a SYMLINK anywhere along the way is structural — the template renders
    #     real directories, so a link is a divergence whatever it points at;
    #   • a component that simply does not EXIST is not a divergence at all.
    #     Fall through and let the ordinary MISSING / index-snapshot handling
    #     decide, which is what those two cases are for;
    #   • all present and real drops out of the loop into the physical
    #     comparison below.
    rpd_walk="$target"
    rpd_rest="$rpd_dir_rel"
    while [ -n "$rpd_rest" ]; do
        case "$rpd_rest" in
        */*)
            rpd_head="${rpd_rest%%/*}"
            rpd_rest="${rpd_rest#*/}"
            ;;
        *)
            rpd_head="$rpd_rest"
            rpd_rest=""
            ;;
        esac
        rpd_walk="$rpd_walk/$rpd_head"
        # `-L` before `-e`: a dangling link exists as a link but not as a
        # target, and it is the structural case, not the absent one.
        [ ! -L "$rpd_walk" ] || break
        [ -e "$rpd_walk" ] || return 1
    done
    rpd_expected="$target_physical/$rpd_dir_rel"
    rpd_actual=""
    rpd_actual="$(cd "$target/$rpd_dir_rel" 2>/dev/null && pwd -P)" ||
        rpd_actual=""
    if [ -z "$rpd_actual" ]; then
        # Only reachable now via the `break` above: a symlinked component whose
        # destination does not exist, or does not contain the rest of the path.
        repo_parent_note="parent directory is a symlink that leads nowhere — structural divergence"
        return 0
    fi
    [ "$rpd_actual" != "$rpd_expected" ] || return 1
    case "$rpd_actual/" in
    "$target_physical"/*)
        repo_parent_note="parent directory is a symlink; the template renders real directories — structural divergence"
        ;;
    *)
        repo_parent_note="parent directory is a symlink leaving the repository — structural divergence"
        ;;
    esac
    return 0
}

# Materialize an index copy when a tracked file is absent only from the working
# tree. This makes audit output stable while an editor/tool has a transient
# unstaged deletion. A staged deletion has no index entry and remains MISSING.
index_variant() {
    p="$1"
    # The target's OWN index, never an ambient one. `--is-inside-work-tree`
    # stood here, and it is true for a plain directory nested inside another
    # repository — so a path the OUTER repo happened to track at the same
    # relative name resolved to the outer repo's blob, suppressing a real
    # MISSING or comparing (and under --show printing) content belonging to a
    # different project. A plain-directory target gets disk-only presence
    # semantics; there is no index of its own to fall back to.
    [ "$target_owns_worktree" -eq 1 ] || return 1
    git -C "$target" cat-file -e ":$p" 2>/dev/null || return 1
    out="$index_root/$p"
    mkdir -p "$(dirname "$out")"
    rm -f "$out"
    mode="$(git -C "$target" ls-files -s -- "$p" | awk 'NR == 1 { print $1 }')"
    if [ "$mode" = "120000" ]; then
        # A tracked symlink's blob content IS its link target. Re-materialize it
        # as a symlink rather than a regular file holding that text: the sweep
        # compares symlinks by link target, so a regular-file stand-in would read
        # as a type mismatch for every transiently deleted alias (CLAUDE.md,
        # GEMINI.md, .github/copilot-instructions.md).
        link="$(git -C "$target" show ":$p" 2>/dev/null)" || return 1
        [ -n "$link" ] || return 1
        ln -s "$link" "$out" || return 1
        echo "$out"
        return 0
    fi
    git -C "$target" show ":$p" >"$out" 2>/dev/null || return 1
    [ "$mode" != "100755" ] || chmod +x "$out"
    echo "$out"
}

resolve_variant() {
    p="$1"
    # `-f` follows symlinks, so a repo alias whose target is missing (a DANGLING
    # symlink) reads as absent here. Test `-L` as well: the path does exist, the
    # sweep's link-target comparison works fine on a dangling link, and falling
    # through to the index instead would compare the link TEXT as file content.
    if [ -f "$target/$p" ] || [ -L "$target/$p" ]; then
        echo "$target/$p"
        return 0
    fi
    # Absent from the work tree — but WHY decides what may happen next. If the
    # path's own directory there is a symlink, the absence is a structural
    # divergence rather than a transient deletion, and falling back to the index
    # would hide it perfectly: the snapshot lives under the workdir, so the
    # caller's physical-parent check trivially passes and a directory swapped
    # for a link to somewhere else audits clean. Hand back the WORK-TREE path so
    # that check fires on the real location instead.
    if repo_parent_diverges "$target/$p"; then
        echo "$target/$p"
        return 0
    fi
    if iv="$(index_variant "$p")"; then
        echo "$iv"
        return 0
    fi
    return 1
}

# Resolve a repo file path, honoring .yml<->.yaml (each tool's own convention).
repo_variant() {
    p="$1"
    if rv="$(resolve_variant "$p")"; then
        echo "$rv"
        return
    fi
    case "$p" in
    *.yml) rv="$(resolve_variant "${p%.yml}.yaml")" && {
        echo "$rv"
        return
    } ;;
    *.yaml) rv="$(resolve_variant "${p%.yaml}.yml")" && {
        echo "$rv"
        return
    } ;;
    esac
    echo ""
}

# Repo-relative display path for a resolved variant, which may live in the index
# snapshot instead of the work tree.
variant_display() {
    d="${1#"$target"/}"
    if [ "$d" = "$1" ]; then
        d="${1#"$index_root"/}"
    fi
    echo "$d"
}

# --- Shared comparison machinery ---------------------------------------------
# Everything from here to the curated loop is used by BOTH loops. It lived below
# the curated loop while only the sweep needed it, which is precisely how the
# curated set ended up with weaker guarantees than the uncurated one: the sweep
# gated symlink swaps and withheld ignore-matched diffs, and the manifest — the
# more curated, more load-bearing set — did neither.

# The TEMPLATE's own ignore rules, evaluated in a scratch repo built from the
# .gitignore files the RENDER ships. This is the authority on whether a rendered
# file is meant to be local-only, and the repo's rules are not: a repo that adds
# `.vscode/` to its own .gitignore was silencing real drift on a template
# artifact every other clone still gets. Ignoring something is a habit a repo
# can acquire for its own reasons; the template DECLARING a path local is a
# statement about the artifact.
#
# `git init` in the workdir is the script's existing idiom (the guarded clone
# does more), but two things have to be shut off or the evaluator answers "what
# does this MACHINE ignore" — the very question it exists to stop asking. An
# empty --template dir keeps `init.templateDir`/`~/.git-template` from seeding
# an info/exclude, and core.excludesFile=/dev/null keeps the auditor's personal
# ignore file (and the XDG default) out of the answer.
#
# Every failure here is fatal rather than a fallback. "Could not build the
# evaluator" and "the template declares nothing local" are different facts, and
# collapsing them means a broken setup silently downgrades every IGNORED path to
# a printable one — the exact direction this whole class of guarantee must not
# fail in.
render_ignore_root="$workdir/render-ignore"
render_has_ignore_rules=0
mkdir -p "$workdir/empty-git-template" || {
    echo "FAIL: cannot prepare the template ignore evaluator" >&2
    exit 2
}
git init -q --template="$workdir/empty-git-template" \
    "$render_ignore_root" >/dev/null 2>&1 || {
    echo "FAIL: cannot initialize the template ignore evaluator" >&2
    exit 2
}
# Every .gitignore in the render, at its own relative path: a nested one only
# governs its own subtree, so flattening them would change what they mean. Today
# the template ships just the root file; copying all of them costs one `find`
# and stops that from being an assumption.
while IFS= read -r render_gitignore; do
    render_gitignore_rel="${render_gitignore#"$render"/}"
    render_gitignore_dest="$render_ignore_root/$render_gitignore_rel"
    if ! mkdir -p "$(dirname "$render_gitignore_dest")" ||
        ! cp "$render_gitignore" "$render_gitignore_dest"; then
        echo "FAIL: cannot stage the render's $render_gitignore_rel for ignore evaluation" >&2
        exit 2
    fi
    render_has_ignore_rules=1
done < <(find "$render" -type f -name .gitignore | LC_ALL=C sort)

# `git check-ignore` is THREE-valued: 0 = the path matches an ignore rule, 1 =
# it does not, anything else = the probe itself failed. Every caller below folds
# those last two together unless something stops it, and that is a fail-OPEN
# guarantee: an unreadable target repo, a broken exclude file, a scratch
# evaluator that lost its git dir — each would answer "nothing is ignored" and
# hand `diff -u` the body of a file somebody marked local-only. There is no safe
# default for "I could not tell", so an errored probe stops the run with the
# script's setup-error status instead of guessing.
ignore_probe_verdict() {
    case "$1" in
    0) return 0 ;;
    1) return 1 ;;
    esac
    echo "FAIL: cannot evaluate $2 for '$3' (git check-ignore exit $1)" >&2
    [ -z "$4" ] || printf '  %s\n' "$4" >&2
    echo "  refusing to continue: an unevaluated ignore rule would print a withheld diff" >&2
    exit 2
}

is_render_ignored() {
    [ "$render_has_ignore_rules" -eq 1 ] || return 1
    ignore_probe_rc=0
    ignore_probe_err="$(
        git -C "$render_ignore_root" -c core.excludesFile=/dev/null \
            check-ignore -q --no-index -- "$1" 2>&1
    )" || ignore_probe_rc=$?
    ignore_probe_verdict "$ignore_probe_rc" "the template's ignore rules" \
        "$1" "$ignore_probe_err"
}

# Ignore rules drive two INDEPENDENT axes, because "does this gate?" and "is
# this safe to print?" are different questions with different answers.
#
# CLASSIFICATION — repo STATE, and then the TEMPLATE's declaration. Only an
# UNTRACKED pattern-matched file can be the informational IGNORED class, and
# only the template can grant it: see the caller, which requires
# is_render_ignored too. `git check-ignore` consults the index, so it never
# calls a TRACKED file ignored, and that is exactly right here — tracked content
# is template-relevant however the ignore rules read, so it must keep gating
# like any other file. Sweep-only: the curated set has no IGNORED class, because
# a manifest-listed path is template-owned by definition.
is_repo_ignored() {
    [ "$target_owns_worktree" -eq 1 ] || return 1
    ignore_probe_rc=0
    ignore_probe_err="$(git -C "$target" check-ignore -q -- "$1" 2>&1)" ||
        ignore_probe_rc=$?
    ignore_probe_verdict "$ignore_probe_rc" "the repo's ignore rules" \
        "$1" "$ignore_probe_err"
}

# WITHHOLDING — the PATH alone, under the UNION of both rule sets, with
# `--no-index` on the repo side so the index cannot mask the pattern.
# Deliberately NOT the classification test above, on either axis:
#   • a repo can `git add -f` a resolved .envrc-shaped config, and tracking it
#     makes `check-ignore` answer "not ignored", so keying the diff on repo
#     classification printed the contents of precisely the paths the repo had
#     marked local-only — tracking makes such a file reviewable, not publishable;
#   • and a repo can simply FAIL to ignore a file the template declares local,
#     which is the same secret in a repo that was less careful, so the render
#     side has to withhold on its own. That half needs no work tree of its own
#     and so applies to a plain-directory target too, where the repo side cannot.
# This covers EVERY diff this script prints, curated and swept alike: being on
# the hand-maintained manifest says the template owns the path, not that the
# repo's copy is safe to echo. The manifest lists `.claude/settings.json`,
# exactly the shape a repo ignores because its local copy holds credentials.
is_ignore_pattern_match() {
    if [ "$target_owns_worktree" -eq 1 ]; then
        ignore_probe_rc=0
        ignore_probe_err="$(
            git -C "$target" check-ignore -q --no-index -- "$1" 2>&1
        )" || ignore_probe_rc=$?
        if ignore_probe_verdict "$ignore_probe_rc" "the repo's ignore rules" \
            "$1" "$ignore_probe_err"; then
            return 0
        fi
    fi
    is_render_ignored "$2"
}

# A path can be STAGED FOR REMOVAL while its working-tree copy survives, which
# is what `git rm --cached` does. resolve_variant then hands back that surviving
# copy and the comparison passes clean — or, if the path also matches an ignore
# rule, collects the non-gating IGNORED exemption, because dropping the index
# entry is what makes `check-ignore` start calling it ignored. Either way the
# audit reports nothing while the very next commit DELETES a template-managed
# file. Detect the state directly: present in HEAD, absent from the index.
#
# Reported as MISSING, which is the contract index_variant already sets: an
# unstaged delete is compared from the index and stays quiet, a STAGED delete is
# real MISSING. `git rm --cached` is a staged delete whose worktree copy happens
# to survive — the commit removes the file just the same — so it earns that
# established class rather than a new one.
#
# Deliberately WITHOUT the non-adoption pointer the other two MISSING lines
# carry (copier-gotchas.md §9). That gotcha is about a path the repo LACKS,
# which the three-way merge reads as your own deletion and never restores. Here
# the file is in HEAD and its worktree copy is still on disk: there is nothing
# for an update to restore, and the fix is to reconcile the staged deletion, not
# to adopt a template file. The guarded update's classifier agrees by
# construction — its repo-presence test is `test -e`/`test -L`, so the surviving
# copy produces no non-adoption row at all, and pointing an operator at a report
# that deliberately omits this path would misdirect. Commit the deletion and the
# path becomes genuinely absent, at which point the ordinary MISSING lines
# report it and the §9 pointer is finally the true one.
is_staged_removal() {
    p="$1"
    [ "$target_owns_worktree" -eq 1 ] || return 1
    # An unborn HEAD (`git init` with no commit yet) has no committed state to
    # have removed anything from. Checking it explicitly keeps the intent legible
    # and the failure quiet, rather than leaning on `cat-file` to error out.
    git -C "$target" rev-parse --verify -q HEAD >/dev/null 2>&1 || return 1
    git -C "$target" cat-file -e "HEAD:$p" 2>/dev/null || return 1
    if git -C "$target" ls-files --error-unmatch -- "$p" >/dev/null 2>&1; then
        return 1 # still in the index — nothing is staged for removal
    fi
    return 0
}

# Compare one rendered path against its resolved repo counterpart. Sets
# compare_note (a human-readable reason) and compare_structural (1 when the
# difference is symlink-ness rather than content). Returns 0 when they match.
compare_note=""
compare_structural=0
same_as_render() {
    rp="$1" # path inside the render
    lp="$2" # resolved repo path
    compare_note=""
    compare_structural=0
    if [ -L "$rp" ] || [ -L "$lp" ]; then
        compare_structural=1
        if [ ! -L "$rp" ]; then
            compare_note="template ships a regular file; repo has a symlink"
            return 1
        fi
        if [ ! -L "$lp" ]; then
            compare_note="template ships a symlink; repo has a regular file"
            return 1
        fi
        # Plain `readlink`, never `readlink -f`: -f is a GNU extension absent on
        # the macOS bash 3.2 hosts this script has to stay portable to, and the
        # raw link text is what we want to compare anyway.
        if [ "$(readlink "$rp")" = "$(readlink "$lp")" ]; then
            compare_structural=0
            return 0
        fi
        compare_note="symlink target differs (template: $(readlink "$rp"))"
        return 1
    fi
    if diff -q "$rp" "$lp" >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

# Print a drifting file's body under --show, or a one-line note when the path is
# ignore-matched. Both loops call this so neither can drift from the other.
show_diff_body() {
    # $3 is the path inside the render, so the render-relative path the
    # template's own rules are written against comes straight off it — no extra
    # argument, and no chance of a caller passing the two out of step.
    if is_ignore_pattern_match "$1" "${3#"$render"/}"; then
        # The finding still GATES — the template owns this path — but somebody
        # marked it local-only and a resolved local config can hold real
        # secrets. Withholding is keyed on the path, not on the class or the
        # loop: keep the finding, drop the body.
        echo "    (diff withheld — path matches an ignore pattern; review manually)"
        return
    fi
    # `diff` exits 1 when files differ (they always do here); `|| true` keeps
    # that from aborting the caller's loop under `set -euo pipefail`, so --show
    # prints EVERY drifting file, not just the first.
    diff -u "$2" "$3" | sed 's/^/    /' || true
}

drift=0
checked=0
drift_count=0
mode_count=0
missing_count=0
while IFS= read -r f; do
    case "$f" in '' | \#*) continue ;; esac
    if [ "$f" = ".coderabbit.yaml" ] && [ "$effective_use_coderabbit" = "false" ]; then
        # Count it as examined only when the render actually ships it, so the
        # summary's "compared" total can never exceed the rendered total. The
        # finding below stands either way: a repo carrying .coderabbit.yaml
        # against a disabling answer is drift whether or not this profile
        # renders the file.
        [ -f "$render/$f" ] && checked=$((checked + 1))
        rv="$(repo_variant "$f")"
        if [ -n "$rv" ]; then
            echo "DRIFT    .coderabbit.yaml  (CodeRabbit is disabled by the effective answer)"
            drift=1
            drift_count=$((drift_count + 1))
        else
            echo "ABSENT   .coderabbit.yaml  (CodeRabbit disabled — expected)"
        fi
        continue
    fi
    [ -f "$render/$f" ] || continue # conditional file not in this profile
    checked=$((checked + 1))
    rv="$(repo_variant "$f")"
    if [ -z "$rv" ]; then
        echo "MISSING  $f  (template ships it; repo doesn't; a copier update will not restore it unless it is _skip_if_exists — copier-gotchas.md §9)"
        drift=1
        missing_count=$((missing_count + 1))
        continue
    fi
    rv_display="$(variant_display "$rv")"
    if is_staged_removal "$rv_display"; then
        echo "MISSING  $rv_display  (tracked in HEAD but staged for removal — the next commit deletes a template-owned file)"
        drift=1
        missing_count=$((missing_count + 1))
        continue
    fi
    # Before ANY read of the repo-side file: nothing below a symlinked directory
    # is this repo's content to compare, let alone to print.
    if repo_parent_diverges "$rv"; then
        echo "DRIFT    $rv_display  ($repo_parent_note)"
        drift=1
        drift_count=$((drift_count + 1))
        continue
    fi
    # Structure, mode, and content are compared exactly as the sweep does it.
    # A bare `diff -q` FOLLOWS symlinks, so a manifest-listed regular file
    # swapped for a link to a byte-identical referent read as perfectly clean
    # here while the sweep gated that same shape — the header's "a structural
    # divergence always gates" rule held for uncurated files only. `-x` follows
    # links too, hence the same exec-bit exemption the sweep uses: the bit
    # belongs to the link target, not to the alias.
    if [ ! -L "$render/$f" ] && [ ! -L "$rv" ]; then
        render_exec=0
        repo_exec=0
        [ -x "$render/$f" ] && render_exec=1
        [ -x "$rv" ] && repo_exec=1
        if [ "$render_exec" -ne "$repo_exec" ]; then
            if [ "$render_exec" -eq 1 ]; then
                mode_note="template is executable; repo is not"
            else
                mode_note="repo is executable; template is not"
            fi
            echo "MODE     $rv_display  ($mode_note)"
            drift=1
            mode_count=$((mode_count + 1))
        fi
    fi
    if ! same_as_render "$render/$f" "$rv"; then
        if [ "$compare_structural" -eq 1 ]; then
            echo "DRIFT    $rv_display  (symlink mismatch — $compare_note)"
        else
            echo "DRIFT    $rv_display"
        fi
        drift=1
        drift_count=$((drift_count + 1))
        # A structural mismatch has nothing readable to diff (and `diff -u` on a
        # dangling link just errors); the note above already says it all.
        if [ "$show" -eq 1 ] && [ "$compare_structural" -eq 0 ]; then
            show_diff_body "$rv_display" "$rv" "$render/$f"
        fi
    fi
done <"$manifest"

# --- Whole-render sweep (manifest-INDEPENDENT) -------------------------------
# Walk the ENTIRE render and reconcile every rendered path against the repo. The
# manifest loop above only compares the curated entries, so a file the repo was
# MISSING was reported here but a file the repo HAD was skipped outright,
# however far it had diverged — the manifest is hand-maintained, lists no prose,
# and lags the template. Comparing what the repo has is the point of this sweep;
# the missing-file scan is one of its outcomes, not its whole job.
# A mature repo can intentionally replace two seed shapes: flat Terraform
# starter files with nested/split Terraform roots, and the seed ADR with a
# renumbered equivalent or an already-active ADR log. Report those as benign
# EQUIV instead of false MISSING. .gitkeep dir-stubs are likewise benign.
equivalent_note=""
has_repo_equivalent() {
    g="$1"
    equivalent_note=""
    case "$g" in
    terraform/main.tf | terraform/variables.tf | terraform/outputs.tf | terraform/tfvars.env.example)
        if [ -d "$target/terraform" ] &&
            find "$target/terraform" -type f -name '*.tf' 2>/dev/null |
            awk -v root="$target/terraform/" '
                    index($0, root) == 1 {
                        rel = substr($0, length(root) + 1)
                        if (rel ~ /\//) found = 1
                    }
                    END { exit(found ? 0 : 1) }
                '; then
            equivalent_note="repo uses nested/split Terraform roots"
            return 0
        fi
        ;;
    docs/decisions/0001-record-architecture-decisions.md)
        for adr in "$target"/docs/decisions/[0-9]*.md; do
            [ -f "$adr" ] || continue
            case "${adr##*/}" in
            *-record-architecture-decisions.md)
                equivalent_note="repo carries a renumbered equivalent ADR"
                return 0
                ;;
            esac
        done
        if [ -f "$target/docs/decisions/README.md" ]; then
            for adr in "$target"/docs/decisions/[0-9]*.md; do
                [ -f "$adr" ] || continue
                equivalent_note="repo already has an active ADR log; the seed ADR is redundant"
                return 0
            done
        fi
        ;;
    esac
    return 1
}

# CO-OWNED — files the template SEEDS but whose prose the repo owns. The
# template's copy is a starting point that every repo rewrites, so byte drift is
# the expected steady state and printing the diff would be pure noise. Surfacing
# is therefore PRESENCE-ONLY: you learn THAT the repo's copy still diverges,
# never how. That inverse reading is the useful one — a CO-OWNED line that
# disappears after a `copier update` means the repo's copy went byte-identical
# to the template's, i.e. the customizations were clobbered.
#
# The `docs/`/`specs/` branch below — and ONLY that branch — is duplicated by
# the guarded update's non-adoption classifier (mode-update.md §1, the
# `nonadoption-classify` markers), as `nonadoption_is_collapsible_prose`. What
# must agree is the whole shape, not just the two globs: the Markdown-only filter
# is load-bearing there too, because a copy that kept the bare `docs/*` would
# file a missing generated asset as somebody's owned prose and collapse it out of
# the report. Change one, change the other.
#
# The rest of this list is intentionally NOT mirrored there, and the asymmetry is
# the point. Co-ownership is a CONTENT exemption — this script withholds a diff
# because the repo's prose is expected to differ — and absence is not content.
# Over there the question is whether a file the repo does not have was declined
# on purpose, which no amount of prose ownership answers: a missing AGENTS.md or
# LICENSE earns a disposition row. Only the two documentation trees collapse
# there, and only because a repo carries tens of them.
#
# Keep these globs TIGHT. Anything the template grows that is not listed here
# falls through to a visible, gating uncurated DRIFT, which is the safe default:
# a new template file nobody has classified should be seen, not silently
# tolerated. Case globs are not path-aware — `*` matches `/` — which cuts both
# ways: `docs/*` reaches `docs/architecture/README.md` at any depth as intended,
# but it also reached every NON-prose artifact under those trees, handing a
# generated script or config the presence-only exemption purely for living in a
# docs directory. The class is about PROSE the repo rewrites, so the two tree
# globs are filtered to Markdown basenames below.
is_co_owned() {
    case "$1" in
    # Agent instructions: the one real file plus the aliases copier keeps as
    # symlinks to it (_preserve_symlinks). A type or link-target mismatch on
    # these still gates — see the structural-divergence note in the header.
    AGENTS.md | CLAUDE.md | GEMINI.md | .github/copilot-instructions.md) return 0 ;;
    # Root prose and licensing.
    README.md | DESIGN.md | CONTRIBUTING.md | CODE_OF_CONDUCT.md | LICENSE) return 0 ;;
    # The template ships SECURITY.md under .github/; accept a root copy too, for
    # repos that keep GitHub's other supported location.
    SECURITY.md | .github/SECURITY.md) return 0 ;;
    # Per-repo documentation and specification trees — the PROSE in them only.
    # A nested case rather than `docs/*.md | docs/*/*.md | …`: that form is
    # depth-capped, and the first artifact one level deeper than anybody
    # enumerated silently changes class. Matching the basename is depth-free and
    # says what it means. Anything non-Markdown under these trees is a build
    # script, a config, or a generated asset — none of it prose the repo owns —
    # so it falls through to visible, gating uncurated DRIFT.
    docs/* | specs/*)
        case "${1##*/}" in
        *.md) return 0 ;;
        esac
        ;;
    # Per-repo scratch, workspace, and note-taking metadata.
    todo.md | *.code-workspace | .meta/*) return 0 ;;
    # template-owned-files.txt spells this one out in prose: the devcontainer
    # zshrc is heavily per-repo customized, so its drift is expected rather than
    # signal, which is exactly why it is deliberately absent from the manifest.
    .devcontainer/config/zshrc) return 0 ;;
    esac
    return 1
}

uncurated_drift_count=0
uncurated_mode_count=0
co_owned_count=0
ignored_count=0
swept_compared=0
rendered_total=0

# `-type l` alongside `-type f`: the template ships CLAUDE.md, GEMINI.md, and
# .github/copilot-instructions.md as symlinks, which a plain `-type f` walk never
# even visits. `LC_ALL=C sort` pins the ordering so output is byte-stable
# regardless of the caller's locale.
while IFS= read -r abs; do
    g="${abs#"$render"/}"
    case "$g" in
    .git/* | .copier-answers.yml | CHANGELOG.md) continue ;;
    esac
    rendered_total=$((rendered_total + 1))
    grep -qxF "$g" "$manifest" 2>/dev/null && continue # manifest loop owns it
    rv="$(repo_variant "$g")"
    if [ -n "$rv" ]; then
        rv_display="$(variant_display "$rv")"
        # Settled before anything can accept or exempt the surviving worktree
        # copy: `git rm --cached` leaves that copy in place, so an identical file
        # would pass silently and an ignore-matched one would collect the
        # non-gating IGNORED exemption, both while the next commit deletes it.
        # Counted as MISSING rather than compared, like every other sweep path
        # the repo does not really have.
        if is_staged_removal "$rv_display"; then
            echo "MISSING  $rv_display  (tracked in HEAD but staged for removal — the next commit deletes a template-owned file)"
            drift=1
            missing_count=$((missing_count + 1))
            continue
        fi
        # Before ANY read of the repo-side file: nothing below a symlinked
        # directory is this repo's content to compare, let alone to print.
        if repo_parent_diverges "$rv"; then
            echo "DRIFT    $rv_display  ($repo_parent_note)"
            drift=1
            uncurated_drift_count=$((uncurated_drift_count + 1))
            continue
        fi
        # The repo HAS this path and the curated manifest does not list it.
        # Compare it rather than skipping — the silent skip here is what kept
        # uncurated divergence invisible (issue 346).
        swept_compared=$((swept_compared + 1))
        # Exec bit and content are independent findings, exactly as in the
        # curated loop: a byte-identical hook script that lost +x is still
        # broken. Symlinks are exempt because the bit belongs to the target.
        mode_divergent=0
        if [ ! -L "$render/$g" ] && [ ! -L "$rv" ]; then
            render_exec=0
            repo_exec=0
            [ -x "$render/$g" ] && render_exec=1
            [ -x "$rv" ] && repo_exec=1
            [ "$render_exec" -eq "$repo_exec" ] || mode_divergent=1
        fi
        content_divergent=0
        same_as_render "$render/$g" "$rv" || content_divergent=1
        if [ "$mode_divergent" -eq 0 ] && [ "$content_divergent" -eq 0 ]; then
            continue
        fi
        # The exec bit is settled FIRST, independent of — and before — any
        # content classification. Mode is STRUCTURAL, the same reason a symlink
        # mismatch gates straight through the CO-OWNED exemption: nobody "owns"
        # a generated script that stopped being runnable, so a co-owned or
        # gitignored regular file that lost `+x` is a broken script rather than
        # the expected prose drift. Deciding it after the presence-only classes
        # let those classes `continue` past this check entirely, and such a file
        # reported nothing at all and exited 0. The finding is one line of
        # metadata, never a diff, so there is nothing here to withhold.
        if [ "$mode_divergent" -eq 1 ]; then
            if [ "$render_exec" -eq 1 ]; then
                mode_note="template is executable; repo is not"
            else
                mode_note="repo is executable; template is not"
            fi
            echo "MODE     $rv_display  ($mode_note)"
            drift=1
            uncurated_mode_count=$((uncurated_mode_count + 1))
        fi
        [ "$content_divergent" -eq 1 ] || continue
        # Content classification: a structural (symlink) mismatch always gates,
        # then the two presence-only classes, then ordinary uncurated drift.
        if [ "$compare_structural" -eq 0 ] && is_co_owned "$g"; then
            echo "CO-OWNED $rv_display  (template seeds it; repo owns the prose — diff withheld)"
            co_owned_count=$((co_owned_count + 1))
            continue
        fi
        drift_note="uncurated — not in template-owned-files.txt"
        if [ "$compare_structural" -eq 1 ]; then
            drift_note="symlink mismatch — $compare_note"
        elif is_repo_ignored "$rv_display"; then
            # Untracked and ignored by the repo. Which of the two outcomes this
            # is comes down to WHOSE rule it matched: the exemption belongs to
            # the template's declaration, never to the repo's habits.
            if is_render_ignored "$g"; then
                echo "IGNORED  $rv_display  (template ships it gitignored — diff withheld; a resolved config can hold secrets)"
                ignored_count=$((ignored_count + 1))
                continue
            fi
            # The template TRACKS this file and the repo quietly stopped
            # carrying it. Every other clone renders it, so the divergence is
            # real drift, not a local resolution — and it used to be the single
            # easiest finding in this script to silence by accident, since
            # adding one line to your own .gitignore did it.
            drift_note="repo-ignored, but the template tracks this file — other clones will not have it"
        fi
        echo "DRIFT    $rv_display  ($drift_note)"
        drift=1
        uncurated_drift_count=$((uncurated_drift_count + 1))
        # A structural mismatch has nothing readable to diff (and `diff -u` on a
        # dangling link just errors); the note above already says it all.
        if [ "$show" -eq 1 ] && [ "$compare_structural" -eq 0 ]; then
            show_diff_body "$rv_display" "$rv" "$render/$g"
        fi
        continue
    fi
    if has_repo_equivalent "$g"; then
        echo "EQUIV    $g  ($equivalent_note)"
        continue
    fi
    case "$g" in
    *.gitkeep) echo "ABSENT   $g  (template dir-stub — benign if the dir has real content)" ;;
    *)
        echo "MISSING  $g  (template ships it; repo lacks it — review; a copier update will not restore it unless it is _skip_if_exists — copier-gotchas.md §9)"
        drift=1
        missing_count=$((missing_count + 1))
        ;;
    esac
done < <(find "$render" \( -type f -o -type l \) | LC_ALL=C sort)

compared=$((checked + swept_compared))
echo ""
if [ "$drift" -ne 0 ]; then
    # The counts make truncated output self-evident: if you can't see every
    # DRIFT / MODE / MISSING line above, you cut them off.
    echo "diff-template: ${drift_count} DRIFT + ${mode_count} MODE across $checked curated files;"
    echo "  ${uncurated_drift_count} uncurated DRIFT + ${uncurated_mode_count} uncurated MODE, ${co_owned_count} CO-OWNED and ${ignored_count} IGNORED from the"
    echo "  whole-render sweep; ${missing_count} MISSING overall. ${compared} of ${rendered_total} rendered files compared."
    echo "  Findings above. For each, review the diff (\`diff-template.sh --show\`):"
    echo "  pull missed template improvements in with \`copier update\`, keep legit"
    echo "  local customizations. CO-OWNED and IGNORED are informational — their content"
    echo "  never fails this check and their diffs are withheld even under --show, though"
    echo "  a MODE finding on one still gates. A withheld-diff note under a gating DRIFT"
    echo "  means the path matches an ignore pattern; review that one locally."
    exit 1
fi
echo "diff-template: OK — $checked curated files match, no template files missing, and"
echo "  ${compared} of ${rendered_total} rendered files compared clean."
if [ "$co_owned_count" -ne 0 ] || [ "$ignored_count" -ne 0 ]; then
    echo "  (${co_owned_count} CO-OWNED and ${ignored_count} IGNORED diverge as expected — informational, not drift.)"
fi
