#!/usr/bin/env bash
# check-closing-keywords.sh — fail closed when a PR would close a same-repo
# issue that still has unchecked work. It reads GitHub metadata only.
#
# Usage:
#   PR_TITLE=... PR_BODY=... check-closing-keywords.sh --repo owner/repo \
#     --title-env PR_TITLE --body-env PR_BODY --commits-file commits.txt
#
# Explicit owner/repo references and issue URLs are informational: GitHub's
# cross-repository closing behaviour is not a contract this gate enforces.
# Exit: 0 clean, 1 unchecked work, 2 could not verify (fail closed).
set -euo pipefail

usage() {
    echo "Usage: $0 --repo owner/repo [--body-env VAR] [--title-env VAR] [--commits-file PATH]" >&2
    exit 2
}

repo="${GH_REPO:-}"
body_env=""
title_env=""
commits_file=""
while [ "$#" -gt 0 ]; do
    case "$1" in
    --repo)
        [ "$#" -ge 2 ] || usage
        repo="$2"
        shift 2
        ;;
    --repo=*)
        repo="${1#--repo=}"
        shift
        ;;
    --body-env)
        [ "$#" -ge 2 ] || usage
        body_env="$2"
        shift 2
        ;;
    --body-env=*)
        body_env="${1#--body-env=}"
        shift
        ;;
    --title-env)
        [ "$#" -ge 2 ] || usage
        title_env="$2"
        shift 2
        ;;
    --title-env=*)
        title_env="${1#--title-env=}"
        shift
        ;;
    --commits-file)
        [ "$#" -ge 2 ] || usage
        commits_file="$2"
        shift 2
        ;;
    --commits-file=*)
        commits_file="${1#--commits-file=}"
        shift
        ;;
    -h | --help) usage ;;
    *) usage ;;
    esac
done

[ -n "$repo" ] || usage
# GitHub treats its hostname and owner/repository names case-insensitively.
# Keep the supplied spelling for API calls, but use a canonical identity when
# deciding whether a closing reference targets this repository.
repo_identity="$(printf '%s' "$repo" | tr '[:upper:]' '[:lower:]')"
body="${body_env:+${!body_env-}}"
title="${title_env:+${!title_env-}}"
commits=""
if [ -n "$commits_file" ]; then
    [ -f "$commits_file" ] || {
        echo "check-closing-keywords: no such file: $commits_file" >&2
        exit 2
    }
    commits="$(cat "$commits_file")"
fi

# The leading group is a portable word boundary. Scan fences too: a missed
# close loses work, while prose can always split the two tokens.
keywords='(close[sd]?|fix(e[sd])?|resolve[sd]?)'
ref='(https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/issues/[0-9]+|[A-Za-z0-9._-]+/[A-Za-z0-9._-]+#[0-9]+|#[0-9]+)'
find_matches() {
    region="$1"
    [ -n "$2" ] || return 0
    printf '%s\n' "$2" | grep -noiE "(^|[^A-Za-z0-9_-])${keywords}[[:space:]]*:?[[:space:]]*${ref}" |
        sed "s/^/${region}|/" || true
}
matches="$(
    find_matches title "$title"
    find_matches body "$body"
    find_matches commit "$commits"
)"
[ -n "$matches" ] || {
    echo "check-closing-keywords: no closing keywords — ok"
    exit 0
}

unchecked_re='^[[:space:]]*(>[[:space:]]*)*([-*+]|[0-9]+[.)])[[:space:]]+\[[[:space:]]\]'
unchecked_boxes() { printf '%s\n' "$1" | grep -cE "$unchecked_re" || true; }

# fetch_issue_body NUMBER prints just the issue body. Fixture support makes the
# behavioral test offline; production uses the read-only Issues API surface.
fetch_issue_body() {
    number="$1"
    if [ -n "${ISSUE_BODY_DIR:-}" ]; then
        fixture="${ISSUE_BODY_DIR}/$(printf '%s' "$repo" | tr '/' '_')__${number}.md"
        [ -f "$fixture" ] || return 3
        cat "$fixture"
    else
        gh issue view "$number" --repo "$repo" --json body --jq '.body // ""' 2>/dev/null || return 3
    fi
}

violations=""
unreadable=""
informational=""
seen=""
while IFS= read -r match; do
    [ -n "$match" ] || continue
    region="${match%%|*}"
    rest="${match#*|}"
    line="${rest%%:*}"
    text="${rest#*:}"
    case "$region" in
    title) where="PR title" ;;
    body) where="PR body line ${line}" ;;
    *) where="commit message line ${line}" ;;
    esac

    # Resolve every form to its target. Explicit references are informational
    # only when they actually name another repository; an explicit reference
    # back to this repository is governed exactly like a bare #N.
    normalized_text="$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]')"
    case "$normalized_text" in
    *github.com/*/issues/*)
        number="${normalized_text##*/issues/}"
        target="${normalized_text%/issues/*}"
        target="${target#*github.com/}"
        ;;
    *)
        prefix="${normalized_text%#*}"
        target="$(printf '%s' "$prefix" | grep -oE '[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$' || true)"
        target="${target:-$repo_identity}"
        number="${normalized_text##*#}"
        ;;
    esac
    if [ "$target" != "$repo_identity" ]; then
        informational="${informational}  ${where}: ${text} (cross-repository reference)\n"
        continue
    fi
    key="${repo_identity}#${number}"
    case "$seen" in *"|${key}|"*) continue ;; esac
    seen="${seen}|${key}|"

    rc=0
    issue_body="$(fetch_issue_body "$number")" || rc=$?
    if [ "$rc" -ne 0 ]; then
        unreadable="${unreadable}  ${where}: ${key} could not be read\n"
        continue
    fi
    open_boxes="$(unchecked_boxes "$issue_body")"
    if [ "$open_boxes" -gt 0 ]; then
        violations="${violations}  ${where}: ${text} -> ${key} has ${open_boxes} unchecked item(s)\n"
    fi
done <<EOF
${matches}
EOF

if [ -n "$informational" ]; then
    printf 'check-closing-keywords: explicit owner/repo references are informational:\n%b' "$informational"
fi
if [ -n "$unreadable" ]; then
    printf 'check-closing-keywords: could not verify every same-repo issue; refusing to clear the gate:\n%b' "$unreadable" >&2
    exit 2
fi
if [ -n "$violations" ]; then
    printf 'check-closing-keywords: this PR would close an issue with unfinished work:\n%b\nUse Refs #N for partial work, or complete the issue checklist before closing it.\n' "$violations" >&2
    exit 1
fi
echo "check-closing-keywords: every same-repo closing reference is clear — ok"
