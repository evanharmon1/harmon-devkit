#!/usr/bin/env bash
# record-implementer.sh — record which model implemented a change, as the four
# implementer values the maintainer adopted on harmon-devkit#1262 (2026-10-04):
#
#   model-family:<family>   Model family    a family slug in agent-registry.json
#   model:<line>            Model           a model line slug of that family
#   model-version:<version> Model version   a version slug of that line
#   model-effort:<effort>   Model effort    an effort the harness declares
#                                           (omitted when it declares none)
#
# Labels on the pull request on every owner type (issue fields do not exist on
# pull requests). On the issue: the same labels on a personal-account
# repository, the four single-select issue fields on an organization. Each value
# is exclusive and the LAST implementer wins on the issue; the pull request is
# the exact per-change record. The values are a record of fact, never a routing
# input: nothing reads them to choose a model, and claim release never removes
# them. This script never reads or writes a `claim:*` label.
#
# Every value is validated against the agent registry before any write, and an
# unknown value is refused, never guessed: the harness exists; a `fixed`
# harness's family is the one recorded (a `broker` harness admits any family);
# the family, its model line and the line's version exist; the version is not
# retired; and the effort is one the harness's `efforts` lists. A harness whose
# `efforts` is empty has no effort the registry has verified, so the other three
# values are recorded and `model-effort` is left unset (maintainer ruling on
# harmon-devkit#1269, 2026-10-11) — on the issue an earlier implementer's effort
# is cleared, so a stale effort never sits beside a new model.
#
# Usage:
#   record-implementer.sh validate --registry FILE [--harness SLUG] \
#       --family SLUG --model SLUG --version SLUG [--effort LEVEL]
#   record-implementer.sh apply --repo OWNER/REPO --pr N [--issue N] \
#       --registry FILE --harness SLUG --family SLUG --model SLUG \
#       --version SLUG [--effort LEVEL]
#   record-implementer.sh check --repo OWNER/REPO --pr N --registry FILE \
#       [--harness SLUG]
#
# --effort is required when --harness names a harness that declares efforts. validate prints the label names it would record; without --harness
# it checks the effort against the registry's effort_ladder (the issue-metadata
# checker's use, which knows no harness). apply validates, then writes the pull
# request labels and the issue record and re-reads both.
#
# check is read-only and existence-only (maintainer ruling, 2026-10-11): the
# pull request must carry exactly one family, line and version label and at
# most one effort label, and each value must still exist in the registry. A
# version retired since the record was written does not block; a value that no
# longer exists does. A missing effort blocks only when --harness names a
# harness that declares efforts.
#
# Pass the registry from a trusted snapshot (the fetched default branch), never
# from the branch under review, and the values from the host's attestation of
# the model that actually ran — never from issue or repository content.
#
# Exit: 0 = recorded / valid, 1 = refused or a write did not verify,
#       2 = usage error or an indeterminate read.
set -euo pipefail

GQL_FEATURES='GraphQL-Features: issue_fields'
FAMILIES='model-family model model-version model-effort'

die() {
    echo "record-implementer: $*" >&2
    exit 2
}

refuse() {
    echo "record-implementer: $*" >&2
    exit 1
}

usage() {
    sed -n '/^# Usage:/,/^# Exit:/p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 2
}

[ "$#" -ge 1 ] || usage
command="$1"
shift
case "$command" in
validate | apply | check) ;;
-h | --help) usage ;;
*) usage ;;
esac

repo="" pr="" issue="" registry="" harness="" family="" model="" version="" effort=""
# rule: `write` refuses retired versions and checks the harness; `exists` (the
# promotion re-check) asks only that every value still exists.
rule="write"
record_effort=1
while [ "$#" -gt 0 ]; do
    case "$1" in
    --repo | --pr | --issue | --registry | --harness | --family | --model | --version | --effort)
        [ "$#" -ge 2 ] && [ -n "$2" ] || die "$1 requires a non-empty value"
        case "$1" in
        --repo) repo="$2" ;;
        --pr) pr="$2" ;;
        --issue) issue="$2" ;;
        --registry) registry="$2" ;;
        --harness) harness="$2" ;;
        --family) family="$2" ;;
        --model) model="$2" ;;
        --version) version="$2" ;;
        --effort) effort="$2" ;;
        esac
        shift 2
        ;;
    *) usage ;;
    esac
done

[ -n "$registry" ] || usage
[ -f "$registry" ] && [ -r "$registry" ] || die "cannot read agent registry: $registry"
jq -e 'type == "object" and (.families | type == "array") and
       (.harnesses | type == "array") and (.effort_ladder | type == "array")' \
    "$registry" >/dev/null 2>&1 ||
    die "agent registry has no families, harnesses and effort_ladder: $registry"

for n in "$pr" "$issue"; do
    case "$n" in
    '' | *[!0-9]*) [ -z "$n" ] || die "--pr and --issue take a number (got '$n')" ;;
    esac
done
if [ -n "$repo" ]; then
    grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' <<<"$repo" ||
        die "--repo must be OWNER/REPO (got '$repo')"
fi

# registry_errors — print one line per reason the tuple is not valid; nothing
# when it is. An empty --harness checks the effort against the effort_ladder;
# an empty effort is checked by the caller, which knows whether one is owed.
registry_errors() {
    jq -r --arg h "$harness" --arg f "$family" --arg m "$model" \
        --arg v "$version" --arg e "$effort" --arg rule "$rule" '
      ([.harnesses[] | select(.slug == $h)] | first) as $harness
      | ([.families[] | select(.slug == $f)] | first) as $family
      | ([($family.models // [])[] | select(.slug == $m)] | first) as $line
      | ([($line.versions // [])[] | select(.slug == $v)] | first) as $version
      | [
          (if $h != "" and $harness == null then
             "harness \($h | @json) is not in the agent registry" else empty end),
          (if $rule == "write" and $harness != null
                and $harness.family_constraint.kind == "fixed"
                and $harness.family_constraint.family != $f then
             "harness \($h | @json) runs only family \($harness.family_constraint.family | @json), not \($f | @json)"
           else empty end),
          (if $family == null then
             "model family \($f | @json) is not in the agent registry"
           elif $line == null then
             "model line \($m | @json) is not a line of family \($f | @json)"
           elif $version == null then
             "model version \($v | @json) is not a version of \($f)/\($m)"
           elif $rule == "write" and ($version.retired // false) then
             "model version \($v | @json) of \($f)/\($m) is retired"
           else empty end),
          (if $e == "" then empty
           elif $rule == "exists" or $h == "" then
             (if (.effort_ladder | index($e)) == null then
                "effort \($e | @json) is not on the registry effort_ladder" else empty end)
           elif $harness == null then empty
           elif (($harness.efforts // []) | length) == 0 then empty
           elif ($harness.efforts | index($e)) == null then
             "effort \($e | @json) is not one harness \($h | @json) declares (\($harness.efforts | join(", ")))"
           else empty end)
        ] | .[]' "$registry"
}

validate_tuple() {
    local errors
    errors="$(registry_errors)" || die "could not evaluate the agent registry"
    if [ -n "$errors" ]; then
        printf '%s\n' "$errors" | sed 's/^/record-implementer: refused: /' >&2
        exit 1
    fi
}

# harness_effort_count — how many efforts --harness declares; empty when the
# harness is not in the registry (registry_errors reports that).
harness_effort_count() {
    jq -r --arg h "$harness" '[.harnesses[] | select(.slug == $h)] | first
        | if . == null then "" else ((.efforts // []) | length) end' "$registry"
}

label_names() {
    printf 'model-family:%s\nmodel:%s\nmodel-version:%s\n' "$family" "$model" "$version"
    [ "$record_effort" -eq 0 ] || printf 'model-effort:%s\n' "$effort"
}

# resolve_effort — decide whether an effort is recorded. A harness that
# declares no efforts records none; a harness that declares efforts owes one.
# Without --harness (the issue-metadata checker) an absent effort is accepted,
# because the record of an efforts-free implementer carries none.
resolve_effort() {
    if [ -n "$harness" ] && [ "$(harness_effort_count)" = 0 ]; then
        record_effort=0
        effort=""
        echo "record-implementer: model-effort not recorded: harness $harness declares no verified efforts" >&2
    elif [ -z "$effort" ]; then
        [ -z "$harness" ] || die "--effort is required (harness $harness declares efforts)"
        record_effort=0
    fi
}

# in_family FAMILY — filter stdin to the labels of one family. `model:` never
# matches `model-family:` and friends because the colon follows the prefix
# directly.
in_family() {
    awk -v p="$1:" 'index($0, p) == 1'
}

# any_family — filter stdin to the labels of any of the four families.
any_family() {
    awk 'index($0, "model-family:") == 1 || index($0, "model:") == 1 ||
         index($0, "model-version:") == 1 || index($0, "model-effort:") == 1'
}

# Every label on an issue or pull request (pull requests are issues to this
# endpoint), one per line.
read_labels() {
    gh api --paginate "repos/$repo/issues/$1/labels?per_page=100" --jq '.[].name'
}

owner_type() {
    local kind
    kind="$(gh api "repos/$repo" --jq '.owner.type')" ||
        die "could not read the owner account type of $repo"
    case "$kind" in
    User) echo personal ;;
    Organization) echo organization ;;
    *) die "$repo returned an unknown owner account type: $kind" ;;
    esac
}

# Write the four labels on one issue or pull request, replacing any earlier
# value in each family, then re-read and require exactly the four.
write_labels() {
    local n="$1" current want stale name enc payload
    current="$(read_labels "$n")" || die "could not read the labels of $repo#$n"
    want="$(label_names)"
    payload="$(printf '%s\n' "$want" | jq -Rnc '{labels: [inputs]}')"
    gh api --method POST "repos/$repo/issues/$n/labels" --input - >/dev/null <<<"$payload" ||
        refuse "write failed: could not add the implementer labels to $repo#$n"
    stale="$(printf '%s\n' "$current" | any_family |
        awk 'NR == FNR { want[$0] = 1; next } !($0 in want)' <(printf '%s\n' "$want") -)"
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        enc="$(jq -rn --arg s "$name" '$s | @uri')"
        gh api --method DELETE "repos/$repo/issues/$n/labels/$enc" >/dev/null ||
            refuse "write failed: could not remove the earlier implementer label '$name' from $repo#$n"
    done <<<"$stale"
    current="$(read_labels "$n")" ||
        die "write indeterminate: could not re-read the labels of $repo#$n"
    verify_labels "$n" "$current" || refuse "write failed: $repo#$n does not carry exactly the implementer labels"
    echo "RECORDED $(printf '%s\n' "$want" | paste -sd ' ' -) on $repo#$n"
}

# verify_labels N LABELS — exactly one label per recorded family, and it is
# the wanted one; none at all in model-effort when no effort is recorded.
# Prints each discrepancy.
verify_labels() {
    local n="$1" labels="$2" f got want_count ok=0
    for f in $FAMILIES; do
        got="$(printf '%s\n' "$labels" | in_family "$f")"
        want_count=1
        [ "$f" != model-effort ] || [ "$record_effort" -eq 1 ] || want_count=0
        if [ "$(printf '%s' "$got" | grep -c . || true)" -ne "$want_count" ] ||
            { [ "$want_count" -eq 1 ] && ! grep -qxF -- "$got" <<<"$(label_names)"; }; then
            echo "record-implementer: $repo#$n $f labels are '$(printf '%s' "$got" | paste -sd ',' -)'" >&2
            ok=1
        fi
    done
    return "$ok"
}

# Refuse before any write when a wanted label is not provisioned: adding an
# absent label through the REST API would silently create it.
require_provisioned() {
    local name enc status
    while IFS= read -r name; do
        enc="$(jq -rn --arg s "$name" '$s | @uri')"
        status=0
        gh api "repos/$repo/labels/$enc" --jq '.name' >/dev/null 2>&1 || status=$?
        [ "$status" -eq 0 ] ||
            refuse "label '$name' is not provisioned in $repo (or could not be read); run task setup:github-labels"
    done < <(label_names)
}

org_field_value_pairs() {
    printf 'Model family\t%s\nModel\t%s\nModel version\t%s\n' "$family" "$model" "$version"
    [ "$record_effort" -eq 0 ] || printf 'Model effort\t%s\n' "$effort"
}

# Organization issue: one setIssueFieldValue mutation for the recorded fields,
# then a verified re-read. Single-select values are replaced, so the last
# implementer wins; when no effort is recorded the same mutation deletes the
# Model effort value (`delete: true`), so an earlier implementer's effort is
# cleared rather than left beside the new model.
write_org_fields() {
    local n="$1" owner name catalogue issue_id fields_input clear_input values
    owner="${repo%%/*}"
    name="${repo#*/}"
    catalogue="$(gh api graphql -H "$GQL_FEATURES" \
        -f query='query($o: String!, $r: String!, $n: Int!) {
            repository(owner: $o, name: $r) {
              issue(number: $n) { id }
              issueFields(first: 100) {
                pageInfo { hasNextPage }
                nodes { ... on IssueFieldSingleSelect { id name options { id name } } }
              }
            }
          }' -f o="$owner" -f r="$name" -F n="$n" \
        --jq '.data.repository')" ||
        die "could not read the issue fields of $repo (the issue_fields preview must be enabled and readable)"
    jq -e '(.issueFields.pageInfo.hasNextPage // false) | not' <<<"$catalogue" >/dev/null ||
        die "the issue field list of $repo exceeds one page"
    issue_id="$(jq -r '.issue.id // empty' <<<"$catalogue")"
    [ -n "$issue_id" ] || die "could not resolve the node id of $repo#$n"
    fields_input="$(org_field_value_pairs | jq -Rnc --argjson c "$catalogue" '
        [inputs | split("\t") | .[0] as $f | .[1] as $v
         | ([$c.issueFields.nodes[]? | select(.name == $f)] | first) as $field
         | {field: $f, value: $v, fieldId: $field.id,
            singleSelectOptionId: ([($field.options // [])[] | select(.name == $v)] | first | .id)}]')"
    if jq -e 'any(.[]; .fieldId == null or .singleSelectOptionId == null)' <<<"$fields_input" >/dev/null; then
        jq -r --arg repo "$repo" '.[] | select(.fieldId == null) | "record-implementer: issue field \(.field | @json) is not provisioned in \($repo)"' \
            <<<"$fields_input" >&2
        jq -r '.[] | select(.fieldId != null and .singleSelectOptionId == null) | "record-implementer: issue field \(.field | @json) has no option \(.value | @json)"' \
            <<<"$fields_input" >&2
        refuse "run task setup:github-issue-fields for the organization, then retry"
    fi
    clear_input='[]'
    if [ "$record_effort" -eq 0 ]; then
        clear_input="$(jq -c '[.issueFields.nodes[]? | select(.name == "Model effort")
            | {fieldId: .id, delete: true}]' <<<"$catalogue")"
    fi
    jq -cn --arg id "$issue_id" --argjson f "$fields_input" --argjson c "$clear_input" '{
        query: "mutation($issue: ID!, $fields: [IssueFieldCreateOrUpdateInput!]!) { setIssueFieldValue(input: {issueId: $issue, issueFields: $fields}) { clientMutationId } }",
        variables: {issue: $id, fields: ([$f[] | {fieldId, singleSelectOptionId}] + $c)}}' |
        gh api graphql -H "$GQL_FEATURES" --input - >/dev/null ||
        refuse "write failed: setIssueFieldValue on $repo#$n"
    values="$(gh api graphql -H "$GQL_FEATURES" \
        -f query='query($o: String!, $r: String!, $n: Int!) {
            repository(owner: $o, name: $r) {
              issue(number: $n) {
                issueFieldValues(first: 50) {
                  nodes { ... on IssueFieldSingleSelectValue { name field { ... on IssueFieldSingleSelect { name } } } }
                }
              }
            }
          }' -f o="$owner" -f r="$name" -F n="$n" \
        --jq '[.data.repository.issue.issueFieldValues.nodes[]?
               | select(.field.name? != null) | {key: .field.name, value: .name}]
              | from_entries')" ||
        die "write indeterminate: could not re-read the issue fields of $repo#$n"
    jq -e --argjson want "$fields_input" --argjson clear "$record_effort" '
        . as $got | all($want[]; $got[.field] == .value)
        and ($clear == 1 or (has("Model effort") | not))' \
        <<<"$values" >/dev/null ||
        refuse "write failed: the issue fields of $repo#$n did not become the implementer values"
    if [ "$record_effort" -eq 1 ]; then
        echo "RECORDED Model family=$family Model=$model Model version=$version Model effort=$effort on $repo#$n"
    else
        echo "RECORDED Model family=$family Model=$model Model version=$version (Model effort cleared) on $repo#$n"
    fi
}

case "$command" in
validate)
    [ -n "$family" ] && [ -n "$model" ] && [ -n "$version" ] || usage
    [ -z "$repo$pr$issue" ] || die "validate takes no --repo, --pr or --issue"
    validate_tuple
    resolve_effort
    validate_tuple
    label_names
    ;;
apply)
    [ -n "$repo" ] && [ -n "$pr" ] && [ -n "$harness" ] && [ -n "$family" ] &&
        [ -n "$model" ] && [ -n "$version" ] || usage
    validate_tuple
    resolve_effort
    validate_tuple
    kind="$(owner_type)"
    require_provisioned
    write_labels "$pr"
    if [ -n "$issue" ]; then
        if [ "$kind" = organization ]; then
            write_org_fields "$issue"
        else
            write_labels "$issue"
        fi
    fi
    ;;
check)
    [ -n "$repo" ] && [ -n "$pr" ] || usage
    [ -z "$issue$family$model$version$effort" ] ||
        die "check reads the values from the pull request; pass only --repo, --pr, --registry and --harness"
    rule="exists"
    if [ -n "$harness" ] && [ -z "$(harness_effort_count)" ]; then
        refuse "harness \"$harness\" is not in the agent registry"
    fi
    labels="$(read_labels "$pr")" || die "could not read the labels of $repo#$pr"
    for f in $FAMILIES; do
        got="$(printf '%s\n' "$labels" | in_family "$f" | sed "s/^$f://")"
        count="$(printf '%s' "$got" | grep -c . || true)"
        if [ "$f" = model-effort ] && [ "$count" -eq 0 ]; then
            if [ -n "$harness" ] && [ "$(harness_effort_count)" != 0 ]; then
                refuse "$repo#$pr carries no model-effort label, and harness $harness declares efforts"
            fi
            record_effort=0
            continue
        fi
        [ "$count" -eq 1 ] ||
            refuse "$repo#$pr carries $count $f labels; the implementer record needs exactly one"
        case "$f" in
        model-family) family="$got" ;;
        model) model="$got" ;;
        model-version) version="$got" ;;
        model-effort) effort="$got" ;;
        esac
    done
    validate_tuple
    echo "VERIFIED $(label_names | paste -sd ' ' -) on $repo#$pr"
    ;;
esac
