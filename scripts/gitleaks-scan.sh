#!/usr/bin/env bash
# gitleaks-scan.sh — secret scan for `task security:secrets`, and (with
# --config) the scanner half of the dev-flow-v2 round-push broker's
# merge-base-extracted closure (specs/dev-flow-v2.md § Configuration "Gate
# authority separates policy from branch implementation").
#
# With --range BASE..HEAD, scan only those commits plus the working tree.
# Without --range, retain the full-history scan used by security:secrets/CI.
#
# Two output modes, picked off GITHUB_STEP_SUMMARY: interactively gitleaks just prints;
# in a job with a step summary it writes a JSON report that summarize-gitleaks
# renders into the run summary.
#
# The report path is a fresh mktemp, never a fixed /tmp/<project>-gitleaks.json:
# a constant scratch path is shared state, so two checkouts of the same repo
# scanning at once — parallel worktrees running `task security`, or two jobs on
# one self-hosted runner — would overwrite each other's report and summarize the
# wrong findings. Same class of race as issue #476.
#
# --config PATH overrides gitleaks' own auto-discovered .gitleaks.toml. It
# does NOT, however, override gitleaks' SEPARATE .gitleaksignore lookup:
# gitleaks 8.30.1's --gitleaks-ignore-path defaults to "." (--source's root)
# and, verified empirically, keeps reading that path even when
# --gitleaks-ignore-path is explicitly pointed elsewhere — the flag adds a
# location to check rather than replacing the default one. A branch could
# therefore commit a .gitleaksignore listing its own leaked secret's
# fingerprint and gitleaks would exit clean regardless of which
# .gitleaks.toml is in effect, or where --gitleaks-ignore-path points.
# There is no gitleaks flag that closes this, so this script refuses
# outright instead: when --config is given, a .gitleaksignore in the
# worktree root (--source's root) must be BYTE-IDENTICAL to the one beside
# PATH (the closure's own copy, extracted from the same merge base — absent
# there if the merge base ships none) or the scan refuses before gitleaks
# ever runs. `task security:secrets` itself never passes --config and is
# unaffected — this check only ever fires for the round-push broker's
# closure-consuming invocation.
#
# summarize-gitleaks.mjs is resolved relative to THIS script's own location,
# never cwd: the broker runs this script with cwd set to the feature worktree
# (so --source . scans the real content under review), and a cwd-relative
# `scripts/summarize-gitleaks.mjs` would then resolve to the worktree's own
# (branch-controlled) copy instead of the merge-base-extracted one beside this
# script.
set -euo pipefail

config_path=
scan_range=
have_range=0
while [ "$#" -gt 0 ]; do
    case "$1" in
    --config | --range)
        option=$1
        [ "$#" -ge 2 ] && [ -n "$2" ] || {
            echo "gitleaks-scan: ${option} requires a value" >&2
            exit 2
        }
        if [ "$option" = "--config" ]; then
            config_path=$2
        else
            [ "$have_range" -eq 0 ] || {
                echo "gitleaks-scan: --range may only be given once" >&2
                exit 2
            }
            scan_range=$2
            have_range=1
        fi
        shift 2
        ;;
    *)
        echo "gitleaks-scan: unknown argument: $1" >&2
        exit 2
        ;;
    esac
done

if [ "$have_range" -eq 1 ]; then
    range_base=${scan_range%%..*}
    range_head=${scan_range#*..}
    # Exactly two revisions, no log options/pathspecs or extra range operators.
    # Resolve each to a commit SHA before passing anything to --log-opts, so
    # ref movement cannot change the requested endpoints during the scan.
    revision_pattern='^[[:alnum:]_][[:alnum:]_./@{}~^-]*$'
    if [ "$range_base" = "$scan_range" ] ||
        [[ "$range_base" == *..* || "$range_head" == *..* ]] ||
        [[ ! "$range_base" =~ $revision_pattern || ! "$range_head" =~ $revision_pattern ]]; then
        echo "gitleaks-scan: --range requires two commit revisions joined by .." >&2
        exit 2
    fi
    range_base_sha="$(git rev-parse --verify --quiet "${range_base}^{commit}")" || {
        echo "gitleaks-scan: --range base does not resolve to a commit" >&2
        exit 2
    }
    range_head_sha="$(git rev-parse --verify --quiet "${range_head}^{commit}")" || {
        echo "gitleaks-scan: --range head does not resolve to a commit" >&2
        exit 2
    }
    scan_range="${range_base_sha}..${range_head_sha}"
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Bash 3.2 treats an empty indexed-array expansion as an unbound variable
# under `set -u` (the same class of bug round-push.sh's own git_args/
# git_arg_count guards against) — track presence separately so this script
# never expands config_args when --config was not given.
config_args=()
have_config=0
if [ -n "$config_path" ]; then
    closure_dir="$(dirname "$config_path")"
    closure_ignore="${closure_dir}/.gitleaksignore"
    worktree_ignore=".gitleaksignore"
    # Neither path may be a symlink (or any other non-regular file): `cmp`
    # below follows symlinks, so a branch could commit .gitleaksignore as a
    # symlink to bytes outside git's own tracking entirely and swap that
    # external target's content between this comparison and gitleaks' own
    # later read of the same path — the symlink itself, and this check,
    # would never see the change (Codex review, confirmed). A regular
    # file's bytes cannot move between two reads without also dirtying the
    # worktree, which the caller's own post-gate `git status` check catches
    # separately; a symlink's TARGET is invisible to that check entirely.
    for f in "$worktree_ignore" "$closure_ignore"; do
        if [ -L "$f" ]; then
            echo "gitleaks-scan: refusing — ${f} is a symlink; .gitleaksignore must be a regular file" >&2
            exit 1
        fi
        if [ -e "$f" ] && [ ! -f "$f" ]; then
            echo "gitleaks-scan: refusing — ${f} exists but is not a regular file" >&2
            exit 1
        fi
    done
    if [ -e "$worktree_ignore" ] || [ -e "$closure_ignore" ]; then
        if ! cmp -s "$worktree_ignore" "$closure_ignore" 2>/dev/null; then
            echo "gitleaks-scan: refusing — a .gitleaksignore in the worktree does not match the closure's copy (or one exists in only one place); gitleaks' ignore-path lookup cannot be redirected away from the worktree root, so this scan cannot proceed safely" >&2
            exit 1
        fi
    fi
    config_args=(--config "$config_path")
    have_config=1
fi

scan_source=.
run_gitleaks() {
    (
        if [ -n "${scan_directory:-}" ]; then
            cd "$scan_directory" || exit $?
        fi
        if [ "$have_config" -eq 1 ]; then
            gitleaks detect --no-banner --redact --source "$scan_source" "${config_args[@]}" "$@"
        else
            gitleaks detect --no-banner --redact --source "$scan_source" "$@"
        fi
    )
}

# Preserve the interactive full-history exec path. Scoped mode needs two
# scans; CI summarizes each scan with a separate fresh report.
if [ "$have_range" -eq 0 ] && [ -z "${GITHUB_STEP_SUMMARY:-}" ]; then
    if [ "$have_config" -eq 1 ]; then
        exec gitleaks detect --no-banner --redact --source . "${config_args[@]}"
    else
        exec gitleaks detect --no-banner --redact --source .
    fi
fi

report=
working_tree_tmp=
trap 'if [ -n "$report" ]; then rm -f "$report"; fi; if [ -n "$working_tree_tmp" ]; then rm -rf "$working_tree_tmp"; fi' EXIT
trap 'exit 1' HUP INT TERM

scan_once() {
    local scan_rc=0 summary_rc=0
    if [ -z "${GITHUB_STEP_SUMMARY:-}" ]; then
        run_gitleaks "$@" || scan_rc=$?
    else
        report="$(mktemp)" || return $?
        run_gitleaks "$@" --report-format json --report-path "$report" || scan_rc=$?
        node "${script_dir}/summarize-gitleaks.mjs" "$report" || summary_rc=$?
        if [ "$scan_rc" -eq 0 ]; then
            scan_rc=$summary_rc
        fi
        rm -f "$report"
        report=
    fi
    return "$scan_rc"
}

scan_working_tree() {
    local worktree_root path scan_source scan_directory config_args
    local GITLEAKS_CONFIG="${GITLEAKS_CONFIG:-}"
    worktree_root="$(git rev-parse --show-toplevel)" || return $?
    working_tree_tmp="$(mktemp -d)" || return $?
    scan_directory="${working_tree_tmp}/tree"
    scan_source=.
    mkdir "$scan_directory" || return $?
    # A directory scan ignores .gitignore. Snapshot only Git-visible paths:
    # tracked files (including force-added ones) and non-ignored untracked
    # files. Materialize the manifest first so a git failure cannot appear
    # to be an empty, clean tree. NUL delimiters preserve every path byte.
    git -C "$worktree_root" ls-files -z --cached --others --exclude-standard \
        >"${working_tree_tmp}/paths" || return $?
    while IFS= read -r -d '' path; do
        if [ -L "${worktree_root}/${path}" ] || [ -f "${worktree_root}/${path}" ]; then
            case "$path" in
            */*) mkdir -p "${scan_directory}/${path%/*}" || return $? ;;
            esac
            # Preserve symlinks rather than importing their external targets;
            # gitleaks' default directory scan does not follow them either.
            cp -P "${worktree_root}/${path}" "${scan_directory}/${path}" || return $?
        elif [ -e "${worktree_root}/${path}" ] && [ ! -d "${worktree_root}/${path}" ]; then
            echo "gitleaks-scan: refusing — Git-visible path is not a regular file or symlink" >&2
            return 1
        fi
        # Deleted paths have no current bytes; gitlinks are directories, not
        # files, and must not import a submodule's ignored credential files.
    done <"${working_tree_tmp}/paths"
    # Scan from the snapshot with source '.', retaining relative finding
    # paths/fingerprints. Make path-valued config inputs absolute before the
    # child changes directory; reports and summaries still run in this cwd.
    if [ "$have_config" -eq 1 ]; then
        case "$config_path" in
        /*) config_args=(--config "$config_path") ;;
        *) config_args=(--config "$(pwd)/${config_path}") ;;
        esac
    fi
    if [ -n "$GITLEAKS_CONFIG" ]; then
        case "$GITLEAKS_CONFIG" in
        /*) ;;
        *) GITLEAKS_CONFIG="$(pwd)/${GITLEAKS_CONFIG}" ;;
        esac
        export GITLEAKS_CONFIG
    fi
    # Keep the original ignore lookup even when that control file is itself
    # ignored. Explicit --config/environment config keep their precedence;
    # otherwise discover the checkout config, not the snapshot's config.
    if [ "$have_config" -eq 0 ] && [ -z "${GITLEAKS_CONFIG:-}${GITLEAKS_CONFIG_TOML:-}" ] &&
        [ -f "${worktree_root}/.gitleaks.toml" ]; then
        scan_once --no-git --gitleaks-ignore-path "$worktree_root" \
            --config "${worktree_root}/.gitleaks.toml"
    else
        scan_once --no-git --gitleaks-ignore-path "$worktree_root"
    fi
}

rc=0
if [ "$have_range" -eq 1 ]; then
    scan_once "--log-opts=${scan_range}" || rc=$?
    # Still scan the checkout if history failed; success of either half must
    # never hide a failure of the other. Both share the config/ignore policy.
    working_tree_rc=0
    scan_working_tree || working_tree_rc=$?
    if [ "$rc" -eq 0 ]; then
        rc=$working_tree_rc
    fi
else
    scan_once || rc=$?
fi
exit "$rc"
