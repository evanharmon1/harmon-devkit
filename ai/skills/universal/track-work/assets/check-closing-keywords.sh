#!/usr/bin/env bash
# check-closing-keywords.sh — refuse a PR body that auto-closes an issue holding
# work the PR will not resolve.
#
# Why: GitHub closes an issue on merge when the PR body carries a closing
# keyword. If that issue still lists outstanding items, merging deletes them from
# the backlog — they survive only inside a closed issue nobody reads. This has
# already happened here: three cross-repo follow-ups were recorded in an issue,
# the PR that removed the source file said `closes #<that issue>`, and the merge
# orphaned all three (see references/closing-keywords.md).
#
# The guard is deliberately FAIL-CLOSED. It scans the whole body, including
# fenced code blocks, because missing a real closing keyword loses work while a
# false positive on a documentation example costs one edit. Likewise it treats
# `Closes#5` (no space) as a close even though GitHub would not.
#
# Usage:
#   check-closing-keywords.sh [--repo owner/repo] [--body-env VAR] [BODY_FILE]
#
# Body comes from BODY_FILE, else from the environment variable named by
# --body-env, else stdin. `--body-env PR_BODY` is how CI passes an untrusted PR
# body without it ever reaching a command line. The default repository resolves
# from --repo, then $GH_REPO, then `gh repo view`. Set $ISSUE_BODY_DIR to read
# issue bodies from fixtures instead of the API (offline tests): issue N of
# owner/repo is read from "$ISSUE_BODY_DIR/owner_repo__N.md".
#
# Exit: 0 = ok (no closing keyword, or every closed issue is fully ticked),
#       1 = violation, 2 = usage/environment error (could not verify).
set -euo pipefail

usage() {
    echo "Usage: $0 [--repo owner/repo] [--body-env VAR] [BODY_FILE]" >&2
    exit 2
}

default_repo="${GH_REPO:-}"
body_file=""
body_env=""
while [ "$#" -gt 0 ]; do
    case "$1" in
    --repo)
        [ "$#" -ge 2 ] || usage
        default_repo="$2"
        shift 2
        ;;
    --repo=*)
        default_repo="${1#--repo=}"
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
    -h | --help) usage ;;
    -*) usage ;;
    *)
        [ -z "$body_file" ] || usage
        body_file="$1"
        shift
        ;;
    esac
done

if [ -n "$body_file" ]; then
    [ -f "$body_file" ] || {
        echo "check-closing-keywords: no such file: $body_file" >&2
        exit 2
    }
    body="$(cat "$body_file")"
elif [ -n "$body_env" ]; then
    # Indirect expansion keeps the body out of any command line, and an unset
    # variable reads as an empty body rather than aborting under `set -u`.
    body="${!body_env-}"
else
    body="$(cat)"
fi

# An empty body cannot contain a closing keyword.
if [ -z "$body" ]; then
    echo "check-closing-keywords: empty body — no closing keywords, ok"
    exit 0
fi

# GitHub's closing keywords, each followed by an issue reference in one of the
# three accepted spellings. The leading group is a portable word boundary (BSD
# and GNU grep disagree on \b); it is stripped back off after matching.
KEYWORDS='(close[sd]?|fix(e[sd])?|resolve[sd]?)'
REF='(https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/issues/[0-9]+|[A-Za-z0-9._-]+/[A-Za-z0-9._-]+#[0-9]+|#[0-9]+)'
matches="$(printf '%s\n' "$body" |
    grep -noiE "(^|[^A-Za-z0-9_-])${KEYWORDS}[[:space:]]*:?[[:space:]]*${REF}" || true)"

if [ -z "$matches" ]; then
    echo "check-closing-keywords: no closing keywords in the body — ok"
    exit 0
fi

# A closing keyword is present, so a default repo is now required to resolve a
# bare `#N`.
if [ -z "$default_repo" ]; then
    default_repo="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
fi
if [ -z "$default_repo" ]; then
    echo "check-closing-keywords: the body has a closing keyword but the repository is unknown." >&2
    echo "  Pass --repo owner/repo, or set GH_REPO." >&2
    exit 2
fi

# fetch_body OWNER/REPO NUM — print the issue body. Returns 3 when the issue
# cannot be read, 4 when the number is a pull request (nothing to orphan).
fetch_body() {
    _fb_repo="$1"
    _fb_num="$2"
    if [ -n "${ISSUE_BODY_DIR:-}" ]; then
        _fb_file="${ISSUE_BODY_DIR}/$(printf '%s' "$_fb_repo" | tr '/' '_')__${_fb_num}.md"
        [ -f "$_fb_file" ] || return 3
        cat "$_fb_file"
        return 0
    fi
    if _fb_body="$(gh issue view "$_fb_num" --repo "$_fb_repo" --json body --jq '.body // ""' 2>/dev/null)"; then
        printf '%s' "$_fb_body"
        return 0
    fi
    # `gh issue view` rejects a pull-request number; a PR carries no backlog.
    if gh pr view "$_fb_num" --repo "$_fb_repo" --json number >/dev/null 2>&1; then
        return 4
    fi
    return 3
}

# unchecked_boxes BODY — count GitHub task-list items that are still open.
unchecked_boxes() {
    printf '%s\n' "$1" | grep -cE '^[[:space:]]*[-*+] \[ \]' || true
}

violations=""
unreadable=""
seen=""

while IFS= read -r match; do
    [ -n "$match" ] || continue
    lineno="${match%%:*}"
    text="${match#*:}"

    # Resolve the reference to owner/repo + number.
    case "$text" in
    *github.com/*/issues/*)
        num="${text##*/issues/}"
        rest="${text%/issues/*}"
        name="${rest##*/}"
        rest="${rest%/*}"
        owner="${rest##*/}"
        target="${owner}/${name}"
        ;;
    *#*)
        num="${text##*#}"
        prefix="${text%#*}"
        # Everything after the keyword and separators is an explicit owner/repo.
        explicit="$(printf '%s' "$prefix" | grep -oE '[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$' || true)"
        target="${explicit:-$default_repo}"
        ;;
    *) continue ;;
    esac

    key="${target}#${num}"
    case "$seen" in
    *"|${key}|"*) continue ;;
    esac
    seen="${seen}|${key}|"

    # A cross-repo closing keyword is never allowed: GitHub's auto-close
    # behaviour across repositories is not something to bet a backlog on, and the
    # intent ("track it there" vs "close it there") is ambiguous on its face.
    if [ "$target" != "$default_repo" ]; then
        violations="${violations}  line ${lineno}: ${text}
      -> ${key} is in another repository; use Refs instead of a closing keyword
"
        continue
    fi

    rc=0
    issue_body="$(fetch_body "$target" "$num")" || rc=$?
    case "$rc" in
    0) ;;
    4) continue ;; # a pull request, not an issue
    *)
        unreadable="${unreadable}  line ${lineno}: ${key} could not be read
"
        continue
        ;;
    esac

    open_boxes="$(unchecked_boxes "$issue_body")"
    if [ "$open_boxes" -gt 0 ]; then
        violations="${violations}  line ${lineno}: ${text}
      -> ${key} still has ${open_boxes} unchecked item(s)
"
    fi
done <<EOF
${matches}
EOF

if [ -n "$unreadable" ]; then
    cat >&2 <<EOF
check-closing-keywords: could not verify every closed issue, so the body is not
cleared. Check the reference is correct and that this token can read the issue.

${unreadable}
EOF
    exit 2
fi

if [ -n "$violations" ]; then
    cat >&2 <<EOF
check-closing-keywords: this body auto-closes an issue it should not.

On merge GitHub closes what these keywords point at, and anything left inside
survives only in a closed issue — off every backlog, in front of nobody.

${violations}
Fix, either way (both re-run this check):
  * tick the items this PR genuinely satisfies:  gh issue edit <n> --repo ${default_repo}
  * or link without closing:                     replace "Closes #<n>" with "Refs #<n>"

If the remaining items belong to another repository, file them there now — an
issue in the repo that owns the code is the only place that is both durable and
visible. See references/cross-repo-work.md.
EOF
    exit 1
fi

echo "check-closing-keywords: every closed issue is fully ticked — ok"
