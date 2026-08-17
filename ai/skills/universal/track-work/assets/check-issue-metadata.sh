#!/usr/bin/env bash
# check-issue-metadata.sh — validate an issue draft and its proposed metadata
# before `gh issue create`. This script is deliberately read-only: it reads the
# target checkout's label registries, or one bounded live label listing when no
# manifest exists, and never calls a GitHub write endpoint.
set -euo pipefail

TITLE_MAX=70
FORBIDDEN_RE='^(foreman:|rigor:|tier:|method:|claim:|suggest:|agent:)'

help_text() {
    cat <<'EOF'
Usage: check-issue-metadata.sh --repo OWNER/REPO --repo-root PATH
          --owner-type personal|organization
          --title TITLE --body-file PATH [--label LABEL]...
          [--work-type-label LABEL]
          [--issue-type TYPE] (--agent-authored|--human-authored)
          [--inapplicable area|layer|domain]...

Validates a proposed issue without writing to GitHub. The target checkout's
label-registry.json is authoritative when present; otherwise the checker makes
one bounded `gh label list --limit 1000` read against --repo.

Personal-account example:
  check-issue-metadata.sh --repo me/project --repo-root . --owner-type personal \\
    --title 'Reject stale cache entries' --body-file issue.md \\
    --work-type-label bug --label area:build --inapplicable layer \\
    --label domain:platform --label ai-generated --agent-authored

Organization example:
  check-issue-metadata.sh --repo org/project --repo-root . --owner-type organization \\
    --issue-type Bug --title 'Reject stale cache entries' --body-file issue.md \\
    --label area:build --inapplicable layer --label domain:platform --human-authored

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
        --title) title="$2" ;;
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
    *) usage ;;
    esac
done

if [ -n "$work_type_label" ]; then
    labels+=("$work_type_label")
fi

[ -n "$repo" ] && [ -n "$repo_root" ] && [ -n "$owner_type" ] &&
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

validate_manifest() {
    jq -e '
      def nonempty: type == "string" and length > 0;
      def slug: type == "string" and test("^[a-z0-9]+(-[a-z0-9]+)*$");
      def writer: type == "string" and test("^(human|trusted-human|agent|tool:[a-z0-9-]+)$");
      .["$schema"] == "./label-registry.schema.json"
      and .schema_version == 1
      and (.families | type == "array" and length > 0)
      and (([.families[].family] | length) == ([.families[].family] | unique | length))
      and all(.families[];
        (.family | slug)
        and ((.prefix == null) or (.prefix | slug))
        and (.purpose | nonempty)
        and (.axis | IN("classification", "strategy", "model", "work-type",
                        "concern", "workflow", "provenance", "foreman",
                        "release", "meta"))
        and (.source | IN("inline", "agent-registry", "tool-owned"))
        and (.writers | type == "array" and all(.[]; writer))
        and ((.retired // false) or (.writers | length > 0))
        and (.exclusive | type == "boolean")
        and (.provision | type == "boolean")
        and (.values | type == "array")
        and (if .source == "agent-registry" then
               (.registry_set | IN("suggest", "claim", "foreman-adapters"))
               and (.values | length == 0)
             else has("registry_set") | not end)
        and (if .source == "tool-owned" then (.provision | not) else true end)
        and (if .source == "inline" and (.retired // false | not)
             then ((.open_values // false) or (.values | length > 0)) else true end)
        and all(.values[];
          (.value | nonempty and test("[\\r\\n|]") | not)
          and ((.writers // []) | type == "array" and all(.[]; writer))
          and ((.retired // false) | type == "boolean")))' "$manifest" >/dev/null 2>&1
}

validate_agent_registry() {
    jq -e '
      def nonempty: type == "string" and length > 0;
      .schema_version == 2
      and (.labels | type == "object")
      and (.families | type == "array" and length > 0)
      and all(.families[];
        (.slug | nonempty)
        and (.models | type == "array")
        and all(.models[]; .slug | nonempty))
      and (.foreman_adapters | type == "array")
      and all(.foreman_adapters[];
        (.slug | nonempty) and (.provision_label | type == "boolean"))' "$1" >/dev/null 2>&1
}

if [ -e "$manifest" ]; then
    [ -f "$manifest" ] && [ -r "$manifest" ] ||
        die "label-registry.json is present but unreadable"
    validate_manifest || die "label-registry.json is present but invalid"

    jq -r '
      .families[] as $f
      | select(($f.retired // false) | not)
      | select($f.source != "agent-registry")
      | ($f.values // [])[]
      | select((.retired // false) | not)
      | (if $f.prefix == null then .value else "\($f.prefix):\(.value)" end) as $name
      | [$name, $f.family, $f.axis,
         ((.writers // $f.writers) | join(",")), ($f.exclusive | tostring)]
      | join("|")' "$manifest" >"$vocab" ||
        die "could not render label-registry.json"

    if jq -e 'any(.families[]; .source == "agent-registry")' "$manifest" >/dev/null; then
        agent_registry="$repo_root/agent-registry.json"
        [ -f "$agent_registry" ] && [ -r "$agent_registry" ] ||
            die "label-registry.json delegates values but agent-registry.json is absent or unreadable"
        validate_agent_registry "$agent_registry" ||
            die "agent-registry.json is present but invalid"
        jq -nr --slurpfile m "$manifest" --slurpfile a "$agent_registry" '
          $m[0].families[] as $f
          | select($f.source == "agent-registry")
          | if ($f.registry_set == "suggest" or $f.registry_set == "claim") then
              ($a[0].labels[$f.registry_set].prefix // $f.prefix) as $prefix
              | if ($f.family | endswith("-model")) then
                  $a[0].families[] as $af
                  | $af.models[]
                  | ["\($prefix):\($af.slug):\(.slug)", $f.family, $f.axis,
                     ($f.writers | join(",")), ($f.exclusive | tostring)]
                else
                  $a[0].families[]
                  | ["\($prefix):\(.slug)", $f.family, $f.axis,
                     ($f.writers | join(",")), ($f.exclusive | tostring)]
                end
            elif $f.registry_set == "foreman-adapters" then
              $a[0].foreman_adapters[]
              | select(.provision_label == true)
              | ["\($f.prefix):\(.slug)", $f.family, $f.axis,
                 ($f.writers | join(",")), ($f.exclusive | tostring)]
            else empty end
          | join("|")' >>"$vocab" || die "could not render delegated label vocabulary"
    fi
else
    live="$(gh label list --repo "$repo" --limit 1000 --json name -q '.[].name')" ||
        die "could not read the target repository's labels"
    while IFS= read -r label; do
        [ -n "$label" ] || continue
        case "$label" in
        area:*) printf '%s|area|classification|human,agent|true\n' "$label" ;;
        layer:*) printf '%s|layer|classification|human,agent|true\n' "$label" ;;
        domain:*) printf '%s|domain|classification|human,agent|true\n' "$label" ;;
        ai-generated) printf '%s|provenance|provenance|human,agent|false\n' "$label" ;;
        needs-triage) printf '%s|workflow|workflow|human,agent|false\n' "$label" ;;
        *)
            if [ -n "$work_type_label" ] && [ "$label" = "$work_type_label" ]; then
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

# Preserve line numbers while removing HTML comments outside code fences.
# Comments hidden by a template are not rendered GitHub content; inside a code
# fence, the same bytes are visible literals and must remain available to the
# existing perishability checker.
visible_body="$tmp/visible-body"
awk '
  {
    line=$0; visible=""
    if (!comment && match(line, /^ ? ? ?(`{3,}|~{3,})/)) {
      seq=substr(line, RSTART, RLENGTH); sub(/^ +/, "", seq)
      ch=substr(seq, 1, 1); rest=substr(line, RSTART + RLENGTH)
      if (!fence) { fence=1; fence_ch=ch; fence_len=length(seq) }
      else if (ch == fence_ch && length(seq) >= fence_len && rest ~ /^[[:space:]]*$/) {
        fence=0; fence_ch=""; fence_len=0
      }
      print line; next
    }
    if (fence) { print line; next }
    while (1) {
      if (comment) {
        close_at=index(line, "-->")
        if (!close_at) { line=""; break }
        line=substr(line, close_at + 3); comment=0
      } else {
        open_at=index(line, "<!--")
        if (!open_at) { visible=visible line; break }
        visible=visible substr(line, 1, open_at - 1)
        line=substr(line, open_at + 4); comment=1
      }
    }
    print visible
  }
' "$body_file" >"$visible_body"

# Title syntax is mechanical. Whether the words form an imperative
# problem/outcome statement remains a semantic judgment owned by the prose.
if ! printf '%s' "$title" | grep -q '[^[:space:]]'; then
    violation "title must be nonempty"
fi
title_length="$(jq -nr --arg value "$title" '$value | explode | length')" ||
    die "could not count title code points"
if [ "$title_length" -gt "$TITLE_MAX" ]; then
    violation "title is $title_length Unicode code points; maximum is $TITLE_MAX"
fi
if printf '%s' "$title" | grep -qiE '^\[[^]]+\][[:space:]]*:?[[:space:]]*'; then
    violation "title has a forbidden bracket or issue-form prefix"
fi
if printf '%s' "$title" | grep -qiE '^(bug|feature|task|research|documentation|question|enhancement):[[:space:]]*'; then
    violation "title has a forbidden issue-form prefix"
fi
if printf '%s' "$title" | grep -qiE '^(build|chore|ci|docs|feat|fix|perf|refactor|revert|style|test)(\([^)]*\))?!?:[[:space:]]*'; then
    violation "title has a forbidden Conventional Commit prefix"
fi
if printf '%s' "$title" | grep -qiE '^P[0-9]+:[[:space:]]*'; then
    violation "title has a forbidden priority prefix"
fi

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
  match($0, /^ ? ? ?(`{3,}|~{3,})/) {
    seq = substr($0, RSTART, RLENGTH); sub(/^ +/, "", seq)
    ch = substr(seq, 1, 1); rest = substr($0, RSTART + RLENGTH)
    if (!fence) { fence = 1; fence_ch = ch; fence_len = length(seq); next }
    if (ch == fence_ch && length(seq) >= fence_len && rest ~ /^[[:space:]]*$/) {
      fence = 0; fence_ch = ""; fence_len = 0
    }
    next
  }
  !fence && match($0, /^ ? ? ?##[[:space:]]+/) {
    text = substr($0, RSTART + RLENGTH)
    sub(/[[:space:]]*#*[[:space:]]*$/, "", text)
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
    substantive="$(awk -v start="$start" -v end="$end" '
      NR > start && NR < end && $0 !~ /^[[:space:]]*$/ { print; exit }
    ' "$visible_body")"
    [ -n "$substantive" ] || violation "$required section is empty"
done

bounds="$(section_bounds acceptance || true)"
if [ -n "$bounds" ]; then
    start="${bounds%% *}"
    end="${bounds#* }"
    acceptance_result="$(awk -v start="$start" -v end="$end" '
      NR <= start || NR >= end { next }
      /^[[:space:]]*$/ { next }
      {
        line=$0
        if (line ~ /^ ? ? ?([-*+]|[0-9]+[.)])[[:space:]]+\[[ xX]\][[:space:]]+/) {
          criteria++
          sub(/^ ? ? ?([-*+]|[0-9]+[.)])[[:space:]]+\[[ xX]\][[:space:]]+/, "", line)
          lower=tolower(line)
          if (lower !~ /^\[(ci|human)\][[:space:]]+/) bad_tag++
          seen=1
          next
        }
        nested=line
        sub(/^[[:space:]]+/, "", nested)
        if (seen && nested ~ /^([-*+]|[0-9]+[.)])[[:space:]]+\[[ xX]\][[:space:]]+/) {
          criteria++
          sub(/^([-*+]|[0-9]+[.)])[[:space:]]+\[[ xX]\][[:space:]]+/, "", nested)
          lower=tolower(nested)
          if (lower !~ /^\[(ci|human)\][[:space:]]+/) bad_tag++
          next
        }
        if (seen && nested ~ /^([-*+]|[0-9]+[.)])[[:space:]]+/) { non_task++; next }
        if (line ~ /^ ? ? ?([-*+]|[0-9]+[.)])[[:space:]]+/) { non_task++; next }
        if (seen && line ~ /^[[:space:]]+/) next
        non_task++
      }
      END { printf "%d %d %d\n", criteria + 0, bad_tag + 0, non_task + 0 }
    ' "$visible_body")"
    criteria="${acceptance_result%% *}"
    rest="${acceptance_result#* }"
    bad_tag="${rest%% *}"
    non_task="${rest#* }"
    [ "$criteria" -gt 0 ] || violation "acceptance criteria section needs at least one rendered task-list item"
    [ "$bad_tag" -eq 0 ] || violation "every acceptance criterion must begin with [CI] or [HUMAN]"
    [ "$non_task" -eq 0 ] || violation "acceptance criteria must be rendered task-list items, not prose or plain lists"
fi

rot_rc=0
rot_output="$("$(cd "$(dirname "$0")" && pwd -P)/check-issue-rot.sh" "$visible_body" 2>&1)" || rot_rc=$?
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
        if (lower ~ /^ ? ? ?#+[[:space:]]+(verify|verification)[[:space:]#]*$/) print "x" $0
        else print
      }
    ' "$visible_body" >"$masked_body"
    masked_rc=0
    "$(cd "$(dirname "$0")" && pwd -P)/check-issue-rot.sh" "$masked_body" >/dev/null 2>&1 || masked_rc=$?
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
    record="$(awk -F '|' -v wanted="$label" '$1 == wanted { print; exit }' "$vocab")"
    if [ -z "$record" ]; then
        violation "label '$label' does not exist in the target vocabulary"
        continue
    fi
    IFS='|' read -r _name family axis writers exclusive <<EOF
$record
EOF
    if [ "$author_type" = agent ]; then
        case ",$writers," in
        *,agent,*) ;;
        *) violation "label '$label' is not writable by an agent" ;;
        esac
    else
        case ",$writers," in
        *,human,* | *,trusted-human,*) ;;
        *) violation "label '$label' is not writable by a human author" ;;
        esac
    fi
    [ "$label" = ai-generated ] && has_ai_generated=1
    [ "$label" = needs-triage ] && has_needs_triage=1
    [ "$axis" = work-type ] && work_type_count=$((work_type_count + 1))
    case "$family" in
    area) area_count=$((area_count + 1)) ;;
    layer) layer_count=$((layer_count + 1)) ;;
    domain) domain_count=$((domain_count + 1)) ;;
    esac
    if [ "$exclusive" = true ]; then
        family_count="$(awk -F '|' -v fam="$family" -v seen="$seen_labels" '
          BEGIN { while ((getline line < seen) > 0) selected[line]=1 }
          selected[$1] && $2 == fam { n++ }
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

if [ "$violations" -ne 0 ]; then
    exit 1
fi

echo "check-issue-metadata: issue draft and proposed metadata verified"
