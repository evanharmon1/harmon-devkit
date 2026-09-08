#!/usr/bin/env bash
# audit-ruleset.sh — compare the checked-in ruleset with GitHub's live copy.
set -euo pipefail

cd "$(dirname "$0")/.."

readonly ruleset_file="${RULESET_AUDIT_FILE:-.github/Branch Protection Ruleset - Protect Main.json}"
readonly fixture_list="${RULESET_AUDIT_LIVE_LIST:-}"
readonly fixture_detail="${RULESET_AUDIT_LIVE_DETAIL:-}"
readonly fixture_error="${RULESET_AUDIT_ERROR:-}"

die_unavailable() {
    echo "RULESET AUDIT UNAVAILABLE: $1" >&2
    exit 2
}

[ -f "$ruleset_file" ] || die_unavailable "checked-in ruleset file is missing: $ruleset_file"
command -v jq >/dev/null 2>&1 || die_unavailable "jq is required"
ruleset_name="$(jq -er '.name' "$ruleset_file" 2>/dev/null)" || die_unavailable "checked-in ruleset has no valid name"

if [ -n "${RULESET_AUDIT_REPO:-}" ]; then
    repo="$RULESET_AUDIT_REPO"
else
    remote_url="$(git remote get-url origin 2>/dev/null || true)"
    case "$remote_url" in
    https://github.com/* | http://github.com/*) repo="${remote_url#*github.com/}" ;;
    git@github.com:*) repo="${remote_url#git@github.com:}" ;;
    ssh://git@github.com/*) repo="${remote_url#ssh://git@github.com/}" ;;
    ssh://git@github.com:*/*)
        repo="${remote_url#ssh://git@github.com:}"
        repo="${repo#*/}"
        ;;
    ssh://git@ssh.github.com/*) repo="${remote_url#ssh://git@ssh.github.com/}" ;;
    ssh://git@ssh.github.com:*/*)
        repo="${remote_url#ssh://git@ssh.github.com:}"
        repo="${repo#*/}"
        ;;
    *) die_unavailable "origin is not a GitHub repository" ;;
    esac
    repo="${repo%.git}"
fi
case "$repo" in
*/?*) ;;
*) die_unavailable "could not determine owner/repository from origin" ;;
esac

tmp_dir="$(mktemp -d -t harmon-init-ruleset-XXXXXX)"
trap 'rm -rf "$tmp_dir"' EXIT
[ -z "$fixture_error" ] || die_unavailable "$fixture_error"

if [ -n "$fixture_list" ]; then
    cp "$fixture_list" "$tmp_dir/list.json" 2>/dev/null || die_unavailable "ruleset list fixture cannot be read"
else
    gh api --paginate --slurp "repos/${repo}/rulesets?includes_parents=false&per_page=100" 2>/dev/null |
        jq 'add' >"$tmp_dir/list.json" || die_unavailable "gh cannot read repository rulesets"
fi

ruleset_id="$(jq -er --arg name "$ruleset_name" '[ .[] | select(.name == $name and .source_type == "Repository") ] | if length == 1 then .[0].id else empty end' "$tmp_dir/list.json" 2>/dev/null)" || die_unavailable "live repository ruleset not found exactly once: $ruleset_name"

if [ -n "$fixture_detail" ]; then
    cp "$fixture_detail" "$tmp_dir/live.json" 2>/dev/null || die_unavailable "ruleset detail fixture cannot be read"
else
    gh api "repos/${repo}/rulesets/${ruleset_id}" >"$tmp_dir/live.json" 2>/dev/null || die_unavailable "gh cannot read live ruleset ${ruleset_id}"
fi

normalize='''
del(.id, .node_id, .created_at, .updated_at, ._links,
  .current_user_can_bypass)
| .rules |= sort_by(.type)
| .rules |= map(if .type == "required_status_checks" then
    .parameters.required_status_checks |= sort_by(.context)
  else . end)
'''

jq -S -e "$normalize" "$ruleset_file" >"$tmp_dir/file.normalized.json" 2>/dev/null || die_unavailable "checked-in ruleset is not valid JSON"
jq -S -e "$normalize" "$tmp_dir/live.json" >"$tmp_dir/live.normalized.json" 2>/dev/null || die_unavailable "live ruleset is not valid JSON"

if diff -u "$tmp_dir/file.normalized.json" "$tmp_dir/live.normalized.json" >"$tmp_dir/diff"; then
    echo "RULESET AUDIT CLEAN: ${ruleset_name} (${repo})"
    exit 0
fi
echo "RULESET AUDIT DRIFT: ${ruleset_name} (${repo})"
sed 's/^/  /' "$tmp_dir/diff"
exit 1
