#!/usr/bin/env bash
# File one authorized review follow-up. triage-apply owns Priority (AI), Tier
# and organization rating fields; personal creation supplies the three labels.
set -euo pipefail

usage() {
    cat <<'HELP'
Usage: file-review-finding.sh --repo OWNER/REPO --repo-root PATH
  --owner-type personal|organization --title TITLE --body-file PATH
  --source-pr SOURCE --reviewer SOURCE --reviewer-priority P0|P1|P2|P3|unbadged
  --adjudicated-priority P0|P1|P2|P3 --impact V --risk V --complexity V
  [--work-type-label LABEL | --issue-type TYPE] [--label LABEL]...
  [--inapplicable AXIS]... [--milestone MILESTONE]

Supply complete agent-authored classification, including ai-generated and all
required label axes. The metadata checker validates owner type and vocabulary.
SOURCE names the PR URL, or the branch when the local round precedes a PR.
Reviewer priority comes from the finding text, never integration's null record.
Priority (AI) is the lowercase adjudicated priority; unbadged + P3 is refused.
Requires workflow authorization and TRIAGE_EXECUTE=1; never sets that approval.
Stdout: created issue number, including on a post-create failure. Non-zero means
unfinished filing: retain that number and resolve the blocker, never recreate.
HELP
}

die() {
    echo "file-review-finding: $*" >&2
    exit 2
}

asset_dir="$(cd "$(dirname "$0")" && pwd -P)"
triage="$asset_dir/../../triage/assets/triage-apply.sh"
repo="" root="" owner_type="" title="" body="" source_pr="" reviewer=""
reviewer_priority="" adjudicated_priority="" impact="" risk="" complexity=""
work_type="" issue_type="" milestone=""
labels=() inapplicable=()
while [ "$#" -gt 0 ]; do
    case "$1" in
    --help)
        usage
        exit 0
        ;;
    --repo | --repo-root | --owner-type | --title | --body-file | --source-pr | --reviewer | \
        --reviewer-priority | --adjudicated-priority | --impact | --risk | --complexity | \
        --work-type-label | --issue-type | --label | --inapplicable | --milestone)
        [ "$#" -ge 2 ] && [ -n "$2" ] || die "missing value for $1"
        case "$1" in
        --repo) repo="$2" ;;
        --repo-root) root="$2" ;;
        --owner-type) owner_type="$2" ;;
        --title) title="$2" ;;
        --body-file) body="$2" ;;
        --source-pr) source_pr="$2" ;;
        --reviewer) reviewer="$2" ;;
        --reviewer-priority) reviewer_priority="$2" ;;
        --adjudicated-priority) adjudicated_priority="$2" ;;
        --impact) impact="$2" ;;
        --risk) risk="$2" ;;
        --complexity) complexity="$2" ;;
        --work-type-label) work_type="$2" ;;
        --issue-type) issue_type="$2" ;;
        --label) labels+=("$2") ;;
        --inapplicable) inapplicable+=("$2") ;;
        --milestone) milestone="$2" ;;
        esac
        shift 2
        ;;
    *) die "unknown argument: $1" ;;
    esac
done
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "expected --repo OWNER/REPO"
[ -d "$root" ] && [ -f "$body" ] || die "readable --repo-root and --body-file required"
root="$(git -C "$root" rev-parse --show-toplevel 2>/dev/null)" ||
    die "--repo-root must be inside a Git checkout"
[ -n "$title" ] && [ -n "$source_pr" ] && [ -n "$reviewer" ] &&
    [ -n "$impact" ] && [ -n "$risk" ] && [ -n "$complexity" ] || die "missing required filing inputs"
case "$source_pr$reviewer$title" in
*$'\r'* | *$'\n'*) die "--source-pr, --reviewer and --title must not contain CR or LF" ;;
esac
case "$reviewer_priority" in P0 | P1 | P2 | P3 | unbadged) ;; *) die "invalid reviewer priority" ;; esac
case "$adjudicated_priority" in
P0) priority_ai=p0 ;;
P1) priority_ai=p1 ;;
P2) priority_ai=p2 ;;
P3) priority_ai=p3 ;;
*) die "invalid adjudicated priority" ;;
esac
if [ "$reviewer_priority" = unbadged ] && [ "$priority_ai" = p3 ]; then
    die "an unbadged finding is adjudicated at least P2; unbadged + P3 is invalid"
fi
case "$owner_type" in
personal)
    [ -n "$work_type" ] && [ -z "$issue_type" ] || die "personal filing requires only --work-type-label"
    labels+=("$work_type" "impact:$impact" "risk:$risk" "complexity:$complexity")
    ;;
organization)
    [ -n "$issue_type" ] && [ -z "$work_type" ] || die "organization filing requires only --issue-type"
    ;;
*) die "invalid --owner-type" ;;
esac
[ "${TRIAGE_EXECUTE:-0}" = 1 ] || die "filing requires workflow-authorized TRIAGE_EXECUTE=1"

# Resolve input before changing directory; receipts and classification both use
# the validated target checkout. No command string is ever evaluated.
body="$(cd "$(dirname "$body")" && pwd -P)/$(basename "$body")"
cd "$root"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/file-review-finding.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
cat "$body" >"$tmp/body.md"
# Use the metadata checker's shared structure pass: fenced examples are blanked
# and the same bounded Markdown authoring profile governs both readers.
bash "$asset_dir/parse-issue-markdown.sh" --structure "$tmp/body.md" >"$tmp/structure"
{
    if ! awk '
      match($0, /^ ? ? ?##[[:space:]]+/) {
        text = substr($0, RSTART + RLENGTH)
        sub(/[[:space:]]+#+[[:space:]]*$/, "", text)
        sub(/[[:space:]]+$/, "", text)
        if (tolower(text) == "provenance") found = 1
      }
      END { exit !found }
    ' "$tmp/structure"; then
        printf '\n\n## Provenance\n'
    fi
    printf '\nSource PR: %s\nReviewer: %s\nReviewer badge: %s\n' \
        "$source_pr" "$reviewer" "$reviewer_priority"
    if [ "$reviewer_priority" != "$adjudicated_priority" ]; then
        printf 'Adjudicated badge: %s\n' "$adjudicated_priority"
    fi
    printf 'Priority (AI): %s\n' "$priority_ai"
} >>"$tmp/body.md"

metadata=(--repo "$repo" --repo-root . --owner-type "$owner_type"
    --title "$title" --body-file "$tmp/body.md" --agent-authored)
if [ "$owner_type" = personal ]; then
    metadata+=(--work-type-label "$work_type")
else
    metadata+=(--issue-type "$issue_type" --impact "$impact" --risk "$risk" --complexity "$complexity")
fi
for label in "${labels[@]+"${labels[@]}"}"; do
    # --work-type-label already supplies this label to the checker.
    if [ "$owner_type" = personal ] && [ "$label" = "$work_type" ]; then continue; fi
    metadata+=(--label "$label")
done
for axis in "${inapplicable[@]+"${inapplicable[@]}"}"; do metadata+=(--inapplicable "$axis"); done
"$asset_dir/check-issue-metadata.sh" "${metadata[@]}" >&2

create=(gh issue create --repo "$repo" --title "$title" --body-file "$tmp/body.md")
for label in "${labels[@]+"${labels[@]}"}"; do create+=(--label "$label"); done
[ "${#inapplicable[@]}" -eq 0 ] || create+=(--label needs-triage)
[ -z "$issue_type" ] || create+=(--type "$issue_type")
[ -z "$milestone" ] || create+=(--milestone "$milestone")
"$asset_dir/verify-issue-receipt.sh" --repo-root . -- "${create[@]}" >&2
issue_url="$("${create[@]}" </dev/null)" || exit $?
issue="${issue_url##*/}"
[[ "$issue" =~ ^[1-9][0-9]*$ ]] || die "create returned no issue number; inspect GitHub before retrying: $issue_url"
printf '%s\n' "$issue"

incomplete() {
    gh issue edit "$issue" --repo "$repo" --add-label needs-triage >&2 ||
        echo "file-review-finding: could not mark $repo#$issue needs-triage" >&2
    echo "file-review-finding: incomplete filing $repo#$issue: $*; do not recreate" >&2
    exit 1
}
"$triage" label --repo "$repo" --issue "$issue" --impact "$impact" \
    --risk "$risk" --complexity "$complexity" --priority-ai "$priority_ai" --execute >&2 ||
    incomplete "classification/Priority (AI) application failed"

# Independently read back the stored classification; a successful writer exit
# alone is not evidence that the new issue is complete.
stored="$(gh issue view "$issue" --repo "$repo" --json labels)" || incomplete "label read failed"
for label in "${labels[@]+"${labels[@]}"}" "priority-ai:$priority_ai"; do
    if [ "$owner_type" = organization ] && [ "$label" = "priority-ai:$priority_ai" ]; then continue; fi
    jq -e --arg label "$label" 'any(.labels[]; .name == $label)' <<<"$stored" >/dev/null ||
        incomplete "missing label $label"
done
# A pin is a modifier, not a Tier. Reuse the validated registry vocabulary
# when present; repositories without a manifest retain the unqualified fallback.
if [ -e label-registry.json ] || [ -L label-registry.json ]; then
    registry="$asset_dir/../../label-registry-support/assets/label-registry.sh"
    tier_records="$("$registry" render label-registry.json)" || incomplete "Tier vocabulary unavailable"
    awk -F '|' '$1 == "value" && $4 == "tier" && $10 == "false" && $11 == "false" &&
        $2 != "tier:pinned" { print $2 }' <<<"$tier_records" >"$tmp/tiers" ||
        incomplete "Tier vocabulary unavailable"
    jq -e --rawfile tiers "$tmp/tiers" '
      any(.labels[]; .name as $name | ($tiers | split("\n") | index($name)) != null)
    ' <<<"$stored" >/dev/null || incomplete "derived Tier unavailable"
else
    jq -e 'any(.labels[]; .name | test("^tier:[^:]+$") and . != "tier:pinned")' \
        <<<"$stored" >/dev/null || incomplete "derived Tier unavailable"
fi
if [ "${#inapplicable[@]}" -eq 0 ]; then
    jq -e 'all(.labels[]; .name != "needs-triage")' <<<"$stored" >/dev/null || incomplete "needs-triage remains"
fi
if [ "$owner_type" = organization ]; then
    native_type="$("$triage" native-type --repo "$repo" --issue "$issue")" || incomplete "native Type read failed"
    jq -e --arg expected "$issue_type" '.state == "set" and .name == $expected' <<<"$native_type" >/dev/null ||
        incomplete "native Type mismatch"
    fields="$(gh api graphql -H 'GraphQL-Features: issue_fields' \
        -f query='query($o: String!, $r: String!, $n: Int!) {
          repository(owner: $o, name: $r) { issue(number: $n) {
            issueFieldValues(first: 50) { pageInfo { hasNextPage } nodes {
              ... on IssueFieldSingleSelectValue { name field { ... on IssueFieldSingleSelect { name } } }
            } }
          } }
        }' -f o="${repo%%/*}" -f r="${repo#*/}" -F n="$issue")" || incomplete "field read failed"
    jq -e --arg impact "$impact" --arg risk "$risk" --arg complexity "$complexity" --arg priority "$priority_ai" '
      .data.repository.issue.issueFieldValues as $v |
      $v != null and $v.pageInfo.hasNextPage == false and
      (([$v.nodes[] | select((.field.name | type) == "string" and (.name | type) == "string") |
        {key: .field.name, value: (.name | ascii_downcase)}] | from_entries) as $f |
       ($impact == "" or $f.Impact == $impact) and
       ($risk == "" or $f.Risk == $risk) and
       ($complexity == "" or $f.Complexity == $complexity) and $f["Priority (AI)"] == $priority)
    ' <<<"$fields" >/dev/null || incomplete "stored classification/Priority (AI) mismatch"
fi
[ "${#inapplicable[@]}" -eq 0 ] || incomplete "inapplicable axes still need classification"
printf 'file-review-finding: verified %s#%s with Priority (AI) %s\n' "$repo" "$issue" "$priority_ai" >&2
