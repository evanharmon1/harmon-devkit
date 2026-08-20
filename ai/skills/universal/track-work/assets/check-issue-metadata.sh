#!/usr/bin/env bash
# check-issue-metadata.sh — validate an issue draft and its proposed metadata
# before `gh issue create`. This script is deliberately read-only: it reads the
# target checkout's label registries, or one bounded live label listing when no
# manifest exists, and never calls a GitHub write endpoint.
set -euo pipefail

FORBIDDEN_RE='^(foreman:|rigor:|tier:|method:|claim:|suggest:|agent:)'
asset_dir="$(cd "$(dirname "$0")" && pwd -P)"
title_module_dir="$asset_dir/../../issue-title-support/assets"

help_text() {
    cat <<'EOF'
Usage: check-issue-metadata.sh --repo OWNER/REPO --repo-root PATH
          --owner-type personal|organization
          --title TITLE --body-file PATH [--label LABEL]...
          [--work-type-label LABEL]
          [--issue-type TYPE] (--agent-authored|--human-authored)
          [--inapplicable area|layer|domain]...

       check-issue-metadata.sh --title-only --title TITLE

Validates a proposed issue without writing to GitHub. The target checkout's
label-registry.json is authoritative when present; otherwise the checker makes
one bounded `gh label list --limit 1000` read against --repo. The checkout must
have a GitHub remote matching --repo. A proposed member of a manifest
`open_values` family also uses one bounded label read to prove that concrete
label exists; the manifest still supplies its policy.

Personal-account example:
  check-issue-metadata.sh --repo me/project --repo-root . --owner-type personal \\
    --title '(cache): Reject stale entries' --body-file issue.md \\
    --work-type-label bug --label area:build --inapplicable layer \\
    --label domain:platform --label ai-generated --agent-authored

Organization example:
  check-issue-metadata.sh --repo org/project --repo-root . --owner-type organization \\
    --issue-type Bug --title '(cache): Reject stale entries' --body-file issue.md \\
    --label area:build --inapplicable layer --label domain:platform --human-authored

Title-only example (for a proposed retitle):
  check-issue-metadata.sh --title-only --title '(cache): Reject stale entries'

Exit: 0 = verified, 1 = authoring-contract violation,
      2 = usage error or indeterminate repository/vocabulary read.
EOF
}

usage() {
    help_text >&2
    exit 2
}

die() {
    echo "check-issue-metadata: $*" >&2
    exit 2
}

violations=0
violation() {
    echo "check-issue-metadata: $*" >&2
    violations=1
}

repo=""
repo_root=""
owner_type=""
title=""
title_set=0
title_only=0
body_file=""
issue_type=""
work_type_label=""
author_type=""
labels=()
inapplicable=()

while [ "$#" -gt 0 ]; do
    case "$1" in
    -h | --help)
        help_text
        exit 0
        ;;
    --repo | --repo-root | --owner-type | --title | --body-file | --issue-type | --work-type-label | --label | --inapplicable)
        [ "$#" -ge 2 ] || usage
        case "$1" in
        --repo) repo="$2" ;;
        --repo-root) repo_root="$2" ;;
        --owner-type) owner_type="$2" ;;
        --title)
            title="$2"
            title_set=1
            ;;
        --body-file) body_file="$2" ;;
        --issue-type) issue_type="$2" ;;
        --work-type-label) work_type_label="$2" ;;
        --label) labels+=("$2") ;;
        --inapplicable) inapplicable+=("$2") ;;
        esac
        shift 2
        ;;
    --agent-authored)
        [ -z "$author_type" ] || die "choose exactly one author type"
        author_type="agent"
        shift
        ;;
    --human-authored)
        [ -z "$author_type" ] || die "choose exactly one author type"
        author_type="human"
        shift
        ;;
    --title-only)
        title_only=1
        shift
        ;;
    *) usage ;;
    esac
done

validate_title() {
    local rc=0
    [ -r "$title_module_dir/issue-title.jq" ] ||
        die "shared issue-title predicate is missing"
    jq -e -n -L "$title_module_dir" --arg value "$title" \
        'include "issue-title"; $value | issue_title_valid' \
        >/dev/null 2>&1 || rc=$?
    case "$rc" in
    0) ;;
    1) violation "title violates the canonical '(scope): imperative outcome' contract" ;;
    *) die "could not evaluate the shared issue-title predicate" ;;
    esac
}

if [ "$title_only" -eq 1 ]; then
    [ "$title_set" -eq 1 ] || usage
    [ -z "$repo$repo_root$owner_type$body_file$issue_type$work_type_label$author_type" ] ||
        die "--title-only accepts only --title"
    [ "${#labels[@]}" -eq 0 ] && [ "${#inapplicable[@]}" -eq 0 ] ||
        die "--title-only accepts only --title"
    validate_title
    [ "$violations" -eq 0 ] || exit 1
    echo "check-issue-metadata: issue title verified"
    exit 0
fi

if [ -n "$work_type_label" ]; then
    labels+=("$work_type_label")
fi

[ -n "$repo" ] && [ -n "$repo_root" ] && [ -n "$owner_type" ] &&
    [ "$title_set" -eq 1 ] &&
    [ -n "$body_file" ] && [ -n "$author_type" ] || usage
printf '%s\n' "$repo" | grep -Eq '^[^/[:space:]]+/[^/[:space:]]+$' ||
    die "--repo must be OWNER/REPO (got '$repo')"
case "$owner_type" in
personal | organization) ;;
*) die "--owner-type must be personal or organization" ;;
esac
[ -d "$repo_root" ] || die "target repository root is not a directory: $repo_root"
repo_root="$(cd "$repo_root" && pwd -P)" || die "cannot resolve target repository root"
[ -f "$body_file" ] && [ -r "$body_file" ] || die "cannot read body draft: $body_file"

normalize_github_remote() {
    _remote="$1"
    case "$_remote" in
    https://github.com/*) _slug="${_remote#https://github.com/}" ;;
    http://github.com/*) _slug="${_remote#http://github.com/}" ;;
    git@github.com:*) _slug="${_remote#git@github.com:}" ;;
    ssh://git@github.com/*) _slug="${_remote#ssh://git@github.com/}" ;;
    ssh://git@ssh.github.com:443/*) _slug="${_remote#ssh://git@ssh.github.com:443/}" ;;
    ssh://git@ssh.github.com/*) _slug="${_remote#ssh://git@ssh.github.com/}" ;;
    *) return 1 ;;
    esac
    _slug="${_slug%.git}"
    printf '%s\n' "$_slug" | tr '[:upper:]' '[:lower:]'
}

target_repo="$(printf '%s\n' "$repo" | tr '[:upper:]' '[:lower:]')"
repo_bound=0
remote_names="$(git -C "$repo_root" remote 2>/dev/null)" ||
    die "target repository root is not a readable Git checkout"
for remote_name in $remote_names; do
    remote_url="$(git -C "$repo_root" remote get-url "$remote_name" 2>/dev/null)" || continue
    remote_repo="$(normalize_github_remote "$remote_url" || true)"
    [ "$remote_repo" = "$target_repo" ] && repo_bound=1
done
[ "$repo_bound" -eq 1 ] ||
    die "target repository root has no GitHub remote matching --repo $repo"
# Resolve the checkout's top level: `--repo-root .` from a subdirectory binds
# the same remotes but would look for the manifest beside the subdirectory,
# silently bypassing an authoritative top-level label-registry.json in favor
# of the weaker live-label fallback.
repo_root="$(git -C "$repo_root" rev-parse --show-toplevel 2>/dev/null)" ||
    die "could not resolve the target checkout's top-level directory"
[ -n "$repo_root" ] && [ -d "$repo_root" ] ||
    die "could not resolve the target checkout's top-level directory"

for axis in "${inapplicable[@]+"${inapplicable[@]}"}"; do
    case "$axis" in
    area | layer | domain) ;;
    *) die "--inapplicable accepts area, layer, or domain (got '$axis')" ;;
    esac
done
for axis in area layer domain; do
    inapplicable_count=0
    for declared in "${inapplicable[@]+"${inapplicable[@]}"}"; do
        [ "$declared" = "$axis" ] && inapplicable_count=$((inapplicable_count + 1))
    done
    [ "$inapplicable_count" -le 1 ] || die "--inapplicable $axis is repeated"
done
for label in "${labels[@]+"${labels[@]}"}"; do
    [ -n "$label" ] || die "--label cannot be empty"
    case "$label" in
    *','* | *'|'* | *$'\n'* | *$'\r'*) die "invalid label value: '$label'" ;;
    esac
done

tmp="$(mktemp -d)" || die "cannot create temporary directory"
trap 'rm -rf "$tmp"' EXIT
vocab="$tmp/vocabulary"
: >"$vocab"
manifest="$repo_root/label-registry.json"
registry_helper="$asset_dir/../../label-registry-support/assets/label-registry.sh"
[ -x "$registry_helper" ] ||
    die "shared label-registry interpreter is missing: $registry_helper"

if [ -e "$manifest" ]; then
    [ -f "$manifest" ] && [ -r "$manifest" ] ||
        die "label-registry.json is present but unreadable"
    registry_records="$tmp/registry-records"
    "$registry_helper" render "$manifest" >"$registry_records" ||
        die "label-registry.json is present but invalid"

    awk -F '|' '
      $1 == "value" && $8 != "agent-registry" &&
      $10 == "false" && $11 == "false" {
        print $2 "|" $3 "|" $5 "|" $6 "|" $7
      }
    ' "$registry_records" >"$vocab"

    # Retired members of active families are excluded from the vocabulary,
    # and the open-value fallback below must not resurrect one from its live
    # label: the manifest retiring a value is an authoritative "no".
    retired_members="$tmp/retired-members"
    awk -F '|' '
      $1 == "value" && $10 == "false" && $11 == "true" { print $2 }
    ' "$registry_records" >"$retired_members"

    # Open-value families define policy in the manifest but not every concrete
    # label name. Resolve only proposed members against one bounded live read;
    # the manifest remains authoritative for family, axis, writers, and
    # exclusivity, while GitHub supplies existence for the specific value.
    open_families="$tmp/open-families"
    awk -F '|' '
      $1 == "family" && $7 != "agent-registry" && $8 == "true" &&
      $9 == "false" && $3 != "" {
        print $3 "|" $2 "|" $4 "|" $5 "|" $6
      }
    ' "$registry_records" >"$open_families"
    open_candidates="$tmp/open-candidates"
    : >"$open_candidates"
    for label in "${labels[@]+"${labels[@]}"}"; do
        label_key="$(printf '%s' "$label" | tr '[:upper:]' '[:lower:]')"
        # A label matching more than one active open family has no unique
        # authorization policy — the manifest model does not forbid two open
        # families sharing a prefix, and picking one by manifest order would
        # let a permissive sibling authorize a label a stricter family
        # governs. Ambiguity fails closed as indeterminate.
        matched_families=""
        matched_count=0
        matched_record=""
        while IFS='|' read -r prefix family axis writers exclusive; do
            [ -n "$prefix" ] || continue
            prefix_key="$(printf '%s' "$prefix" | tr '[:upper:]' '[:lower:]')"
            case "$label_key" in
            "$prefix_key":*)
                matched_count=$((matched_count + 1))
                matched_families="${matched_families}${matched_families:+, }$family"
                matched_record="$label|$family|$axis|$writers|$exclusive"
                ;;
            esac
        done <"$open_families"
        [ "$matched_count" -le 1 ] ||
            die "label '$label' matches multiple open-value families ($matched_families); the manifest gives it no unique policy"
        if [ "$matched_count" -eq 1 ] && grep -ixqF -- "$label" "$retired_members"; then
            violation "label '$label' is retired by the manifest"
            continue
        fi
        if [ "$matched_count" -eq 1 ]; then
            # The same ambiguity exists between an open family and a concrete
            # record: a different family enumerating this exact name would
            # otherwise silently supply the writers and exclusivity the open
            # family is documented to own. The one non-ambiguous overlap is
            # the open family enumerating some of its own members — a value
            # record there is that family's own per-value refinement.
            open_family="${matched_record#*|}"
            open_family="${open_family%%|*}"
            concrete_family="$(awk -F '|' -v wanted="$label_key" \
                'tolower($1) == wanted { print $2; exit }' "$vocab")"
            if [ -n "$concrete_family" ] && [ "$concrete_family" != "$open_family" ]; then
                die "label '$label' is enumerated by family '$concrete_family' and covered by open-value family '$open_family'; the manifest gives it no unique policy"
            fi
            printf '%s\n' "$matched_record" >>"$open_candidates"
        fi
    done
    if [ -s "$open_candidates" ]; then
        live="$(gh label list --repo "$repo" --limit 1000 --json name -q '.[].name')" ||
            die "could not read open-value labels from the target repository"
        while IFS='|' read -r label family axis writers exclusive; do
            label_key="$(printf '%s' "$label" | tr '[:upper:]' '[:lower:]')"
            if ! printf '%s\n' "$live" | awk -v wanted="$label_key" 'tolower($0) == wanted { found=1 } END { exit(found ? 0 : 1) }'; then
                # Open families opt into live existence: a proposed member the
                # bounded read cannot find must not validate, including one
                # the family itself enumerates for a per-value policy — the
                # ambiguity guard above guarantees any existing record for
                # this name is that same family's own, so dropping it makes
                # the absent label fail as unknown instead of passing stale.
                awk -F '|' -v wanted="$label_key" 'tolower($1) != wanted' "$vocab" >"$vocab.pruned" &&
                    mv "$vocab.pruned" "$vocab" ||
                    die "could not prune an absent open-value label from the vocabulary"
                continue
            fi
            awk -F '|' -v wanted="$label_key" 'tolower($1) == wanted { found=1 } END { exit(found ? 0 : 1) }' "$vocab" ||
                printf '%s|%s|%s|%s|%s\n' \
                    "$label" "$family" "$axis" "$writers" "$exclusive" >>"$vocab"
        done <"$open_candidates"
    fi

else
    live="$(gh label list --repo "$repo" --limit 1000 --json name -q '.[].name')" ||
        die "could not read the target repository's labels"
    while IFS= read -r label; do
        [ -n "$label" ] || continue
        # Proposed labels reject the record delimiter, so a live label that
        # contains it can never be selected. Ignore it instead of allowing it
        # to forge the family/writer fields of a second record.
        case "$label" in
        *'|'*) continue ;;
        esac
        label_key="$(printf '%s' "$label" | tr '[:upper:]' '[:lower:]')"
        case "$label_key" in
        area:*) printf '%s|area|classification|human,agent|true\n' "$label" ;;
        layer:*) printf '%s|layer|classification|human,agent|true\n' "$label" ;;
        domain:*) printf '%s|domain|classification|human,agent|true\n' "$label" ;;
        ai-generated) printf '%s|provenance|provenance|human,agent|false\n' "$label" ;;
        needs-triage) printf '%s|workflow|workflow|human,agent|false\n' "$label" ;;
        *)
            if [ -n "$work_type_label" ] && [ "$label_key" = "$(printf '%s' "$work_type_label" | tr '[:upper:]' '[:lower:]')" ]; then
                printf '%s|work-type|work-type|human,agent|false\n' "$label"
            else
                printf '%s|fallback-other|meta|human|false\n' "$label"
            fi
            ;;
        esac
    done >"$vocab" <<EOF
$live
EOF
fi
sort -u "$vocab" -o "$vocab"
if [ -n "${CHECK_ISSUE_METADATA_DEBUG:-}" ]; then
    {
        echo "--- vocabulary ($(wc -l <"$vocab") records) ---"
        cat "$vocab"
        echo "--- environment ---"
        echo "repo_root=$repo_root"
        jq --version
        (awk -W version 2>&1 || awk --version 2>&1) | head -1
        sort --version | head -1
    } >&2
fi

# --owner-type selects the classification interface, but it is not trusted as
# evidence about the target. Resolve the repository owner's actual account kind
# so a caller cannot make an organization repository accept a work-type label
# (or make a personal repository attempt native Issue Type validation).
actual_owner_type="$(gh api "repos/$repo" --jq '.owner.type' 2>/dev/null)" ||
    die "could not read the target repository owner's account type"
case "$actual_owner_type" in
User) actual_owner_type="personal" ;;
Organization) actual_owner_type="organization" ;;
*) die "target repository returned an unknown owner account type: $actual_owner_type" ;;
esac
if [ "$owner_type" != "$actual_owner_type" ]; then
    # Stop here: every later work-classification check would run down the
    # wrong owner branch — an Issue Type lookup against a user account fails
    # and would turn this actionable contract violation into an indeterminate
    # exit 2.
    violation "--owner-type $owner_type does not match target repository owner type $actual_owner_type"
    exit 1
fi

# Preserve source line numbers while reducing the body to Markdown structure.
# The shared parser accepts only the mechanized authoring profile: fenced
# examples are blanked, and a draft carrying raw HTML, HTML comments, or any
# other construct whose rendering a line-oriented parser cannot decide is a
# contract violation, with the parser naming each offending line.
visible_body="$tmp/visible-body"
parse_rc=0
bash "$asset_dir/parse-issue-markdown.sh" --structure "$body_file" >"$visible_body" 2>"$tmp/parse-err" || parse_rc=$?
if [ "$parse_rc" -eq 3 ]; then
    while IFS= read -r diagnostic; do
        violation "body is outside the authoring profile: ${diagnostic#parse-issue-markdown: }"
    done <"$tmp/parse-err"
    exit 1
elif [ "$parse_rc" -ne 0 ]; then
    cat "$tmp/parse-err" >&2
    die "could not parse issue body structure"
fi
rendered_tasks="$tmp/rendered-tasks"
printf '0:\n' >"$rendered_tasks"
bash "$asset_dir/parse-issue-markdown.sh" --tasks "$body_file" >>"$rendered_tasks" ||
    die "could not parse rendered issue tasks"

# Title syntax is mechanical. Whether the words form an imperative
# problem/outcome statement remains a semantic judgment owned by the prose.
validate_title

# Enumerate level-two headings outside fenced code blocks. Unknown level-two
# headings are rejected: the contract is a skeleton, not a partial ordering
# into which competing section dialects can be inserted.
headings="$tmp/headings"
awk '
  function canonical(s, lower) {
    lower = tolower(s)
    if (lower == "problem") return "problem"
    if (lower ~ /^current violation \(observed [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\)$/) return "current"
    if (lower == "acceptance criteria") return "acceptance"
    if (lower == "verify") return "verify"
    if (lower == "out of scope") return "out-of-scope"
    if (lower == "provenance") return "provenance"
    return "unknown"
  }
  # No fence tracking here: the structure pass replaces every fence delimiter
  # and interior line with a placeholder, so no heading-shaped line survives
  # from inside one.
  match($0, /^ ? ? ?##[[:space:]]+/) {
    text = substr($0, RSTART + RLENGTH)
    # A closing hash sequence counts only when whitespace precedes it —
    # CommonMark renders `## Problem#` with the hash as heading text.
    sub(/[[:space:]]+#+[[:space:]]*$/, "", text)
    sub(/[[:space:]]+$/, "", text)
    printf "%d|%s|%s\n", NR, canonical(text), text
  }
' "$visible_body" >"$headings"

if grep -q '|unknown|' "$headings"; then
    while IFS='|' read -r line kind text; do
        [ "$kind" = unknown ] && violation "body line $line has noncanonical level-two heading '$text'"
    done <"$headings"
fi

for required in problem acceptance; do
    count="$(awk -F '|' -v name="$required" '$2 == name { n++ } END { print n + 0 }' "$headings")"
    [ "$count" -eq 1 ] || violation "body requires exactly one $required heading (found $count)"
done
for optional in current verify out-of-scope provenance; do
    count="$(awk -F '|' -v name="$optional" '$2 == name { n++ } END { print n + 0 }' "$headings")"
    [ "$count" -le 1 ] || violation "body repeats the optional $optional heading"
done

order_error="$(awk -F '|' '
  BEGIN { rank["problem"]=1; rank["current"]=2; rank["acceptance"]=3;
          rank["verify"]=4; rank["out-of-scope"]=5; rank["provenance"]=6 }
  $2 != "unknown" { if (rank[$2] <= prior) { print $1; exit }; prior=rank[$2] }
' "$headings")"
[ -z "$order_error" ] || violation "canonical headings are duplicated or out of order at body line $order_error"

section_bounds() {
    _name="$1"
    _start="$(awk -F '|' -v name="$_name" '$2 == name { print $1; exit }' "$headings")"
    [ -n "$_start" ] || return 1
    _end="$(awk -F '|' -v start="$_start" '$1 > start { print $1; exit }' "$headings")"
    [ -n "$_end" ] || _end=2147483647
    printf '%s %s\n' "$_start" "$_end"
}

for required in problem acceptance; do
    bounds="$(section_bounds "$required" || true)"
    [ -n "$bounds" ] || continue
    start="${bounds%% *}"
    end="${bounds#* }"
    # Judged on the raw body, not the structure pass: a fence there is a
    # nonblank placeholder, which would let a section holding only an EMPTY
    # code block count as substantive. Delimiter-only lines are skipped, so a
    # fence's actual contents still count while its frame does not.
    substantive="$(awk -v start="$start" -v end="$end" '
      NR > start && NR < end && $0 !~ /^[[:space:]]*$/ &&
      $0 !~ /^[[:space:]]*(```|~~~)/ { print; exit }
    ' "$body_file")"
    [ -n "$substantive" ] || violation "$required section is empty"
done

bounds="$(section_bounds acceptance || true)"
if [ -n "$bounds" ]; then
    start="${bounds%% *}"
    end="${bounds#* }"
    acceptance_result="$(awk -F ':' -v start="$start" -v end="$end" '
      NR == FNR { rendered[$1] = 1; next }
      FNR <= start || FNR >= end { next }
      /^[[:space:]]*$/ { next }
      {
        line=$0
        if (rendered[FNR]) {
          criteria++
          match(line, /\[[ xX]\][[:space:]]+/)
          line=substr(line, RSTART + RLENGTH)
          lower=tolower(line)
          if (lower !~ /^\[(ci|human)\][[:space:]]+/) bad_tag++
          else {
            sub(/^\[(ci|human)\][[:space:]]+/, "", lower)
            if (lower !~ /[^[:space:]]/) empty_description++
          }
          seen=1
          next
        }
        nested=line
        sub(/^[[:space:]]+/, "", nested)
        if (nested ~ /^([-*+]|[0-9]+[.)])[[:space:]]+\[[ xX]\][[:space:]]+/) { non_task++; next }
        if (nested ~ /^([-*+]|[0-9]+[.)])[[:space:]]+/) { non_task++; next }
        if (line ~ /^ ? ? ?([-*+]|[0-9]+[.)])[[:space:]]+/) { non_task++; next }
        if (seen && line ~ /^[[:space:]]+/) next
        non_task++
      }
      END { printf "%d %d %d %d\n", criteria + 0, bad_tag + 0,
                   non_task + 0, empty_description + 0 }
    ' "$rendered_tasks" "$visible_body")"
    criteria="${acceptance_result%% *}"
    rest="${acceptance_result#* }"
    bad_tag="${rest%% *}"
    non_task="${rest#* }"
    empty_description="${non_task#* }"
    non_task="${non_task%% *}"
    [ "$criteria" -gt 0 ] || violation "acceptance criteria section needs at least one rendered task-list item"
    [ "$bad_tag" -eq 0 ] || violation "every acceptance criterion must begin with [CI] or [HUMAN]"
    [ "$non_task" -eq 0 ] || violation "acceptance criteria must be rendered task-list items, not prose or plain lists"
    [ "$empty_description" -eq 0 ] || violation "every acceptance criterion needs nonempty text after its [CI] or [HUMAN] tag"
fi

rot_rc=0
rot_output="$("$asset_dir/check-issue-rot.sh" --repo-root "$repo_root" "$body_file" 2>&1)" || rot_rc=$?
case "$rot_rc" in
0) ;;
1) violation "perishable facts require a substantive Verify section: $rot_output" ;;
*) die "perishable-fact check was indeterminate: $rot_output" ;;
esac

# check-issue-rot.sh intentionally accepts Verify at any Markdown heading level.
# The authoring skeleton is narrower: when a perishable fact exists, Verify is
# the canonical level-two section. Mask every Verify-like heading and ask the
# existing rot checker whether the remaining draft still contains perishable
# evidence; this reuses its definition instead of copying its pattern list.
verify_count="$(awk -F '|' '$2 == "verify" { n++ } END { print n + 0 }' "$headings")"
current_count="$(awk -F '|' '$2 == "current" { n++ } END { print n + 0 }' "$headings")"
if [ "$current_count" -gt 0 ] && [ "$verify_count" -eq 0 ]; then
    violation "Current violation requires the canonical level-two ## Verify section"
fi
if [ "$verify_count" -eq 0 ]; then
    masked_body="$tmp/body-without-noncanonical-verify"
    awk '
      {
        lower=tolower($0)
        if (lower ~ /^ ? ? ?#+[[:space:]]+(verify|verification)([[:space:]]+#+)?[[:space:]]*$/) print "x" $0
        else print
      }
    ' "$body_file" >"$masked_body"
    masked_rc=0
    "$asset_dir/check-issue-rot.sh" --repo-root "$repo_root" "$masked_body" >/dev/null 2>&1 || masked_rc=$?
    case "$masked_rc" in
    0) ;;
    1) violation "perishable facts require the canonical level-two ## Verify section" ;;
    *) die "canonical Verify check was indeterminate" ;;
    esac
fi

has_ai_generated=0
has_needs_triage=0
work_type_count=0
area_count=0
layer_count=0
domain_count=0
seen_labels="$tmp/seen-labels"
: >"$seen_labels"

for label in "${labels[@]+"${labels[@]}"}"; do
    if grep -qxF -- "$label" "$seen_labels"; then
        violation "label '$label' is proposed more than once"
        continue
    fi
    printf '%s\n' "$label" >>"$seen_labels"
    if printf '%s' "$label" | grep -qiE "$FORBIDDEN_RE"; then
        violation "label '$label' belongs to a forbidden authoring-time family"
        continue
    fi
    label_key="$(printf '%s' "$label" | tr '[:upper:]' '[:lower:]')"
    record="$(awk -F '|' -v wanted="$label_key" 'tolower($1) == wanted { print; exit }' "$vocab")"
    if [ -z "$record" ]; then
        violation "label '$label' does not exist in the target vocabulary"
        continue
    fi
    IFS='|' read -r _name family axis writers exclusive <<EOF
$record
EOF
    # The prefix regex above catches the well-known spellings, but the
    # manifest may declare a strategy or Foreman family under any prefix, and
    # a claim/suggest-shaped family under any axis it likes. The resolved
    # record's axis is the semantic class, so authoring-time rejection binds
    # to it as well: strategy, foreman, and model-routing labels are live
    # ownership or execution controls whatever they are named.
    case "$axis" in
    strategy | foreman | model)
        violation "label '$label' belongs to the authoring-forbidden '$axis' axis"
        continue
        ;;
    esac
    if [ "$author_type" = agent ]; then
        case ",$writers," in
        *,agent,*) ;;
        *) violation "label '$label' is not writable by an agent" ;;
        esac
    else
        case ",$writers," in
        *,human,*) ;;
        *,trusted-human,*)
            die "label '$label' requires an actor-verifying trusted-human workflow"
            ;;
        *) violation "label '$label' is not writable by a human author" ;;
        esac
    fi
    [ "$label_key" = ai-generated ] && has_ai_generated=1
    [ "$label_key" = needs-triage ] && has_needs_triage=1
    [ "$axis" = work-type ] && work_type_count=$((work_type_count + 1))
    case "$family" in
    area) area_count=$((area_count + 1)) ;;
    layer) layer_count=$((layer_count + 1)) ;;
    domain) domain_count=$((domain_count + 1)) ;;
    esac
    if [ "$exclusive" = true ]; then
        family_count="$(awk -F '|' -v fam="$family" -v seen="$seen_labels" '
          BEGIN { while ((getline line < seen) > 0) selected[tolower(line)]=1 }
          selected[tolower($1)] && $2 == fam { n++ }
          END { print n + 0 }
        ' "$vocab")"
        [ "$family_count" -le 1 ] || violation "exclusive label family '$family' has $family_count proposed values"
    fi
done

if [ "$author_type" = agent ] && [ "$has_ai_generated" -ne 1 ]; then
    violation "agent-authored issues require the ai-generated label"
fi
case "$owner_type" in
personal)
    [ -z "$issue_type" ] || violation "personal-account repositories use a work-type label, not native Issue Type"
    [ "$work_type_count" -eq 1 ] ||
        violation "personal-account repositories require exactly one work-type label (found $work_type_count)"
    ;;
organization)
    [ -z "$work_type_label" ] ||
        violation "organization repositories use native Issue Type, not --work-type-label"
    [ "$work_type_count" -eq 0 ] ||
        violation "organization repositories use native Issue Type and no work-type label"
    if printf '%s' "$issue_type" | grep -q '[^[:space:]]'; then
        repo_owner="${repo%%/*}"
        native_types="$(gh api "orgs/$repo_owner/issue-types" --jq '.[].name')" ||
            die "could not read native Issue Types for organization $repo_owner"
        if ! printf '%s\n' "$native_types" | awk -v wanted="$issue_type" '
          BEGIN { wanted=tolower(wanted) }
          tolower($0) == wanted { found=1 }
          END { exit(found ? 0 : 1) }
        '; then
            violation "native Issue Type '$issue_type' does not exist for organization $repo_owner"
        fi
    else
        violation "organization repositories require a native Issue Type"
    fi
    ;;
esac

is_inapplicable() {
    _wanted="$1"
    for _axis in "${inapplicable[@]+"${inapplicable[@]}"}"; do
        [ "$_axis" = "$_wanted" ] && return 0
    done
    return 1
}

undecided=""
for axis in area layer domain; do
    eval "count=\${${axis}_count}"
    if [ "$count" -gt 0 ] && is_inapplicable "$axis"; then
        violation "$axis cannot have both a label and an inapplicable declaration"
    elif [ "$count" -eq 0 ] && ! is_inapplicable "$axis"; then
        undecided="${undecided}${undecided:+, }$axis"
    fi
done
if [ -n "$undecided" ] && [ "$has_needs_triage" -ne 1 ]; then
    violation "classification axes remain undecided ($undecided); add needs-triage or classify/declare them inapplicable"
fi
if [ -z "$undecided" ] && [ "$has_needs_triage" -eq 1 ]; then
    violation "needs-triage records an undecided classification, but every axis is decided; drop the label"
fi

if [ "$violations" -ne 0 ]; then
    exit 1
fi

echo "check-issue-metadata: issue draft and proposed metadata verified"
