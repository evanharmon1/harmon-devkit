#!/usr/bin/env bash
# setup-github-project.sh — idempotently create and sync a GitHub Project V2 for a
# repo owner (an organization OR a personal user account): the board, its
# Status pipeline (docs/project-management.md), and the Size project NUMBER
# field — the numeric estimate stays a project field for BOTH owner types,
# because only project number fields sum in view group headers (issue-field
# columns can group/filter/sort, not sum). The other metadata on an ORGANIZATION
# are org-level ISSUE fields (Priority/Effort are GitHub built-ins, left at
# their defaults; setup-github-issue-fields.sh adds Product); on a personal
# account (no org issue fields) this script creates Priority/Product as
# project fields too. Domain and Layer are deliberately NOT fields — the
# `domain:`/`layer:` labels (setup-github-labels.sh) are their only surface
# (#875).
#
# Safe to re-run and safe to run from every repo the owner controls: it looks the
# project up by title, so the first run creates it and later runs just reconcile
# fields. Reconciling is purely ADDITIVE — a single-select field that is missing a
# starter option gains it, and nothing is ever renamed, reordered, or deleted, so
# your later customizations survive every re-run.
#
# Usage:   setup-github-project.sh --owner <org-or-user-login> --title "<Project Title>"
# Needs:   gh authed with the 'project' scope (gh auth refresh -s project) + jq.
#
# NOTE: this hits the live GitHub API, so it is not exercised by `task
# test:template` (which never touches GitHub) — it is guarded by shellcheck +
# shfmt only. Test it against a scratch project when changing it.
set -euo pipefail

owner=""
title=""
while [ "$#" -gt 0 ]; do
    case "$1" in
    --owner)
        owner="${2:-}"
        shift 2
        ;;
    --title)
        title="${2:-}"
        shift 2
        ;;
    *)
        echo "Unknown argument: $1" >&2
        exit 2
        ;;
    esac
done

if [ -z "$owner" ] || [ -z "$title" ]; then
    echo "Usage: $0 --owner <org-or-user-login> --title \"<Project Title>\"" >&2
    exit 2
fi

for tool in gh jq; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Required tool not found: $tool" >&2
        exit 1
    fi
done

script_dir="$(cd "$(dirname "$0")" && pwd)"
# Task buffers stdout in grouped mode. Keep legacy progress and the visual
# outcome on one live stream so their chronology cannot be reversed.
exec 1>&2
OUTPUT_FD=2
# shellcheck source=scripts/lib/output.sh
. "$script_dir/lib/output.sh"

action_banner setup "GitHub Project" "Board, delivery pipeline, and planning fields"
kv "Owner" "$owner"
kv "Project" "$title"

# ── Scope preflight ─────────────────────────────────────────────────────────
# Every mutation below needs the 'project' scope, which `gh auth login` does not
# grant by default. Without it the run still fails — `gh api graphql` exits
# non-zero on an INSUFFICIENT_SCOPES error and `set -e` takes the script with it
# — but it fails at the first projectsV2 query with a raw GraphQL error that
# says nothing about scopes or how to fix it. Checking here converts that into
# one actionable line, before any API call. It is deliberately NOT fatal on an
# unreadable scope list: a token whose scopes cannot be parsed (a GitHub App
# installation token, a future `gh` output change) may still be perfectly able
# to do the work, and refusing to run would be a worse failure than the one
# this guard replaces.
# Narrow the report to the one credential the API calls below will use.
# `gh auth status` covers every account on every host, and the scope line cannot
# tell them apart: --active excludes a second account on this host, --hostname
# excludes an unrelated host whose scopes say nothing about this run (which
# targets GH_HOST or github.com). Older gh (pre-2.40) has no --active — fall back
# rather than read a usage error as a missing scope; multi-account per host
# arrived with 2.40, so one host there already means one account.
# The host this run will target. GH_HOST is gh's override for when a host cannot
# be determined from repository context, so context comes first when it is unset —
# forcing github.com would narrow the probe to a host the API calls below do not
# use, and reject a valid Enterprise login over it.
gh_host="${GH_HOST:-}"
if [ -z "$gh_host" ]; then
    remote_url="$(git config --get remote.origin.url 2>/dev/null || true)"
    case "$remote_url" in
    *://*)
        gh_host="${remote_url#*://}"
        gh_host="${gh_host#*@}"
        gh_host="${gh_host%%/*}"
        gh_host="${gh_host%%:*}"
        ;;
    *@*:*)
        gh_host="${remote_url#*@}"
        gh_host="${gh_host%%:*}"
        ;;
    esac
fi
gh_host="${gh_host:-github.com}"
auth_report="$(gh auth status --active --hostname "$gh_host" 2>&1 || true)"
case "$auth_report" in
*"unknown flag"*) auth_report="$(gh auth status --hostname "$gh_host" 2>&1 || true)" ;;
esac
scopes_line="$(printf '%s\n' "$auth_report" | grep -i 'token scopes:' || true)"
case "$scopes_line" in
"")
    echo "==> Could not read token scopes from 'gh auth status' — continuing; a scope error below means: gh auth refresh -s project" >&2
    ;;
*"'project'"*) ;;
*"'"*)
    # `gh auth refresh` edits the STORED credential, which an env-provided token
    # overrides — so that remedy is unusable for anyone running on GH_TOKEN or
    # GITHUB_TOKEN. gh names the source in its report; use it.
    remedy="    gh auth refresh -s project"
    case "$auth_report" in
    *"(GH_TOKEN)"*)
        remedy="    Reissue the token in GH_TOKEN with the 'project' scope.
    (gh auth refresh cannot help: the environment token overrides the stored one.)"
        ;;
    *"(GITHUB_TOKEN)"*)
        remedy="    Reissue the token in GITHUB_TOKEN with the 'project' scope.
    (gh auth refresh cannot help: the environment token overrides the stored one.)"
        ;;
    *"(GH_ENTERPRISE_TOKEN)"*)
        remedy="    Reissue the token in GH_ENTERPRISE_TOKEN with the 'project' scope.
    (gh auth refresh cannot help: the environment token overrides the stored one.)"
        ;;
    *"(GITHUB_ENTERPRISE_TOKEN)"*)
        remedy="    Reissue the token in GITHUB_ENTERPRISE_TOKEN with the 'project' scope.
    (gh auth refresh cannot help: the environment token overrides the stored one.)"
        ;;
    esac
    printf '%s\n\n%s\n\n%s\n\n%s\n' \
        "This token cannot write GitHub Projects: 'gh auth status' reports no 'project' scope." \
        "Every write below (the board, its Status pipeline, the Size field) would fail on
the first API call. Fix it, then re-run:" \
        "$remedy" \
        "Note that read-only 'read:project' is enough to *see* a board but not to create
or reconcile one, so this script requires the full 'project' scope." >&2
    exit 1
    ;;
*)
    # A scopes line with no scopes in it: a fine-grained PAT or an App
    # installation token, whose Projects access is a permission granted where
    # the token was issued rather than an OAuth scope. Such a token may be
    # perfectly able to do this work, and `gh auth refresh` cannot change it
    # (an env-provided GH_TOKEN cannot be refreshed at all) — so refusing here
    # would block a capable credential over a naming mismatch.
    echo "==> Token reports no OAuth scopes (fine-grained or App token) — continuing; if a write below fails, grant it 'Projects: Read and write' where the token was issued" >&2
    ;;
esac

# Full Status pipeline (docs/project-management.md), in board order. GitHub's API
# cannot create the visual groups, so these render as a flat, ordered list.
status_pipeline='[
  {"name":"Inbox","color":"GRAY","description":"Newly landed, unsorted"},
  {"name":"Icebox","color":"GRAY","description":"Real, but not now"},
  {"name":"Next","color":"PINK","description":"Will pull in soon"},
  {"name":"Todo","color":"BLUE","description":"Committed, not started"},
  {"name":"Shaping","color":"BLUE","description":"Problem/approach being defined"},
  {"name":"Ready","color":"BLUE","description":"Shaped, ready to pick up"},
  {"name":"Agent Queue","color":"BLUE","description":"Queued for an AI agent"},
  {"name":"In Progress","color":"YELLOW","description":"Actively being worked"},
  {"name":"Verifying","color":"ORANGE","description":"CI/checks running"},
  {"name":"In Review","color":"GREEN","description":"Under human review"},
  {"name":"Ready to Merge","color":"GREEN","description":"Approved, awaiting merge"},
  {"name":"Done","color":"PURPLE","description":"Merged/shipped"},
  {"name":"Deployed","color":"PURPLE","description":"Deployed"},
  {"name":"Accepted","color":"PURPLE","description":"Smoke/QA/manual check passed"}
]'

# jq filter: a JSON array of {id?,name,color,description} -> a GraphQL options
# fragment. Names/descriptions are JSON-escaped; color is emitted as a bare enum.
#
# `id` is emitted only when present, and that is load-bearing rather than
# cosmetic. Per GitHub's own schema doc for ProjectV2SingleSelectFieldOptionInput:
# "The ID of an existing single select option. Include this to preserve the
# option's identity during updates, preventing item field values from being
# cleared." So an update that re-sends an existing option WITHOUT its id destroys
# that option and blanks the field on every item already assigned to it. Options
# read back from the project therefore carry their id; brand-new starter options
# have none (GitHub assigns it), and `if .id then` omits the key for them.
opts_to_graphql='[.[] | "{" + (if .id then "id:" + (.id|@json) + "," else "" end) + "name:" + (.name|@json) + ",color:" + .color + ",description:" + (.description|@json) + "}"] | join(",")'

# ── Resolve the owner (org or user), then find the project by title ──
# repositoryOwner + a ProjectV2Owner fragment is one code path for both User and
# Organization owners (both implement the interface).
echo "==> Resolving owner '$owner'"
owner_data=$(gh api graphql -f query='query($l:String!){repositoryOwner(login:$l){__typename id}}' \
    -f l="$owner")
owner_type=$(printf '%s' "$owner_data" | jq -r '.data.repositoryOwner.__typename')
owner_id=$(printf '%s' "$owner_data" | jq -r '.data.repositoryOwner.id')
if [ -z "$owner_id" ] || [ "$owner_id" = "null" ]; then
    echo "Could not resolve owner '$owner' — check the login and that you have the 'project' scope." >&2
    exit 1
fi

echo "==> Looking for a project titled '$title'"
project_id=""
project_number=""
cursor=""
while true; do
    if [ -n "$cursor" ]; then
        page=$(gh api graphql -f query='query($l:String!,$c:String){repositoryOwner(login:$l){... on ProjectV2Owner{projectsV2(first:100,after:$c){pageInfo{hasNextPage endCursor} nodes{id number title}}}}}' \
            -f l="$owner" -f c="$cursor")
    else
        page=$(gh api graphql -f query='query($l:String!){repositoryOwner(login:$l){... on ProjectV2Owner{projectsV2(first:100){pageInfo{hasNextPage endCursor} nodes{id number title}}}}}' \
            -f l="$owner")
    fi
    match=$(printf '%s' "$page" |
        jq -r --arg t "$title" '.data.repositoryOwner.projectsV2.nodes[] | select(.title==$t) | (.id + "\t" + (.number|tostring))' |
        head -n1)
    if [ -n "$match" ]; then
        project_id=$(printf '%s' "$match" | cut -f1)
        project_number=$(printf '%s' "$match" | cut -f2)
        break
    fi
    has_next=$(printf '%s' "$page" | jq -r '.data.repositoryOwner.projectsV2.pageInfo.hasNextPage')
    [ "$has_next" = "true" ] || break
    cursor=$(printf '%s' "$page" | jq -r '.data.repositoryOwner.projectsV2.pageInfo.endCursor')
done

created=0
if [ -n "$project_id" ]; then
    echo "    Found existing project #$project_number"
else
    echo "    Not found — creating '$title'"
    resp=$(gh api graphql -f query='mutation($o:ID!,$t:String!){createProjectV2(input:{ownerId:$o,title:$t}){projectV2{id number}}}' \
        -f o="$owner_id" -f t="$title")
    project_id=$(printf '%s' "$resp" | jq -r '.data.createProjectV2.projectV2.id')
    project_number=$(printf '%s' "$resp" | jq -r '.data.createProjectV2.projectV2.number')
    created=1
    echo "    Created project #$project_number"
fi

# For an organization, record the project id in the ORG_PROJECT_ID org variable
# that project-automation.yml + the claude-* workflows read (preferred over a
# title lookup). Personal accounts have no org-level variable scope, and their
# status automation is a separate follow-up, so skip it there.
#
# This deliberately runs BEFORE field reconciliation. The variable answers "which
# board", and by this point the board exists, so pointing at it is correct even
# if a later step cannot finish. Deferring the write until after reconciliation
# would not protect anything: a run that died in between would leave no variable
# at all, and the workflows' title-lookup fallback resolves to that same
# half-reconciled board. Reconciliation is additive and re-runnable, so the
# remedy for a partial run is to re-run this script either way.
org_variable_problem=""
if [ "$owner_type" = "Organization" ]; then
    echo "==> Recording project id in the ORG_PROJECT_ID org variable"
    if ! gh variable set ORG_PROJECT_ID --org "$owner" --visibility all --body "$project_id"; then
        org_variable_problem="ORG_PROJECT_ID was not written"
        echo "WARNING: could not set the ORG_PROJECT_ID org variable (needs org admin)." >&2
        echo "         Set it by hand: gh variable set ORG_PROJECT_ID --org \"$owner\" --body \"$project_id\"" >&2
        checkline unknown "Organization variable" "ORG_PROJECT_ID was not written; set it manually"
    else
        checkline ok "Organization variable" "ORG_PROJECT_ID points to project #$project_number"
    fi
else
    echo "==> Owner is a user account — skipping ORG_PROJECT_ID (no user-level variable scope; personal status automation is a separate follow-up)"
    checkline na "Organization variable" "not available for personal accounts"
fi

# ── Snapshot current fields (reused for existence checks; re-read immediately
#    before any option replacement — see refresh_fields) ──
refresh_fields() {
    fields_json=$(gh api graphql -f query='query($p:ID!){node(id:$p){... on ProjectV2{fields(first:50){nodes{... on ProjectV2FieldCommon{id name dataType} ... on ProjectV2SingleSelectField{options{id name color description}}}}}}}' \
        -f p="$project_id")
}
refresh_fields

field_id() {
    printf '%s' "$fields_json" |
        jq -r --arg n "$1" '.data.node.fields.nodes[] | select(.name==$n) | .id' | head -n1
}

field_type() {
    printf '%s' "$fields_json" |
        jq -r --arg n "$1" '.data.node.fields.nodes[] | select(.name==$n) | .dataType' | head -n1
}

# existing_options NAME — the single-select field's CURRENT options, as a JSON
# array of {id,name,color,description} ready to concatenate. Only meaningful for
# a field the snapshot reports as SINGLE_SELECT. The id MUST be carried through
# to the mutation — see opts_to_graphql for why dropping it is destructive.
existing_options() {
    printf '%s' "$fields_json" |
        jq -c --arg n "$1" '[.data.node.fields.nodes[] | select(.name==$n) | .options[] | {id, name, color: (.color // "GRAY" | ascii_upcase), description: (.description // "")}]'
}

# append_missing EXISTING DESIRED — EXISTING, in order, plus every DESIRED option
# whose name is not already present. Matching is by name, so an option the owner
# recoloured or re-described keeps their version.
append_missing() {
    jq -cn --argjson ex "$1" --argjson want "$2" \
        '$ex + [ $want[] | select( .name as $n | ([ $ex[].name ] | index($n)) == null ) ]'
}

# set_options FIELD_ID OPTIONS_JSON — replace a single-select field's option list.
# updateProjectV2Field REPLACES the whole singleSelectOptions array, so callers
# MUST pass the complete desired list: sending only the new options would delete
# every option the owner added. Always build the argument with append_missing().
set_options() {
    frag=$(printf '%s' "$2" | jq -r "$opts_to_graphql")
    gh api graphql -f f="$1" \
        -f query="mutation(\$f:ID!){updateProjectV2Field(input:{fieldId:\$f,singleSelectOptions:[$frag]}){projectV2Field{... on ProjectV2SingleSelectField{id}}}}" \
        >/dev/null
}

# A reused project may already carry a field with one of these names — of the
# wrong data type. GitHub cannot change a project field's data type in place, so
# its intended options are unavailable until it is renamed or deleted. Warn (and
# repeat it in the summary) rather than exit non-zero: appending options to a
# `text` field named `Domain` is impossible, and one pre-existing field is no
# reason to abort the rest.
incompatible=""

# Fields that are missing a starter option but have no room left for it.
at_capacity=""

# Fields that vanished between the discovery snapshot and their guarded write.
disappeared=""

# GitHub's cap on options in one single-select field.
max_options=50

# Set by field_exists: 1 when the existing field is of the expected data type (so
# a single-select caller may append to it), 0 when it is not.
field_matched=0

# field_exists NAME EXPECTED_DATATYPE — 0 when a field of that name is already
# there (so the caller skips creation), recording a data-type mismatch on the way.
field_exists() {
    field_matched=0
    [ -n "$(field_id "$1")" ] || return 1
    etype="$(field_type "$1")"
    if [ -n "$etype" ] && [ "$etype" != "null" ] && [ "$etype" != "$2" ]; then
        echo "    WARNING: field '$1' already exists as $etype, not $2 — its intended options are NOT available" >&2
        incompatible="${incompatible}${incompatible:+, }$1 (is $etype, wanted $2)"
    else
        field_matched=1
    fi
    return 0
}

report_incompatible() {
    if [ -n "$incompatible" ]; then
        echo "==> WARNING — these project fields already exist with a different data type: $incompatible" >&2
        echo "    GitHub cannot change a project field's data type in place. Rename or delete each one in the" >&2
        echo "    Project UI and re-run this script to get the intended options." >&2
    fi
    if [ -n "$at_capacity" ]; then
        echo "==> WARNING — these fields are missing a starter option with no room to add it — $at_capacity" >&2
        echo "    A single-select field holds at most $max_options options. Remove one you do not use in the" >&2
        echo "    Project UI and re-run, or skip the starter value." >&2
    fi
}

finish_project() {
    if [ -n "$incompatible" ] || [ -n "$at_capacity" ] || [ -n "$disappeared" ] ||
        [ -n "$org_variable_problem" ]; then
        checkline unknown "Project" "#$project_number / $title: reconciliation needs attention"
        output_summary "Project reconciliation"
        output_warning "GitHub Project needs attention; resolve the warnings above and re-run"
    else
        checkline ok "Project" "#$project_number / $title"
        output_summary "Project reconciliation"
        output_done "GitHub Project is ready"
    fi
}

# append_options NAME STARTERS — reconcile one existing single-select field: add
# whatever starter option it lacks, keep everything else exactly as it is, and
# write nothing when there is nothing to add. Used for Status and the custom
# fields alike, so all of them get the same capacity guard and no-op behaviour.
append_options() {
    name="$1"
    options_json="$2"
    # Re-read immediately before building the replacement. set_options replaces
    # the ENTIRE option list, so an option added between the startup snapshot and
    # this write — by a parallel run of this script, or someone in the Project UI
    # — would otherwise be silently deleted. This narrows that lost-update window
    # to a single round-trip. It does not close it: updateProjectV2Field accepts
    # no expected-version token, so a write landing inside the window is still
    # lost. Closing it would need serialization GitHub does not offer here.
    refresh_fields
    if [ -z "$(field_id "$name")" ]; then
        echo "    WARNING: field '$name' disappeared while this script was running — skipping" >&2
        disappeared="${disappeared}${disappeared:+, }$name"
        return 0
    fi
    existing=$(existing_options "$name")
    desired=$(append_missing "$existing" "$options_json")
    added=$(jq -rn --argjson ex "$existing" --argjson de "$desired" \
        '[ $de[] | select( .name as $n | ([ $ex[].name ] | index($n)) == null ) | .name ] | join(", ")')
    if [ -z "$added" ]; then
        echo "    Field '$name' already exists with every starter option — leaving it as-is"
        return 0
    fi
    # A single-select field holds at most $max_options options. Appending past
    # that is rejected by the API, and under `set -e` that would abort the whole
    # run — possibly after earlier fields were already updated, leaving a
    # half-reconciled project. Warn and skip instead, matching how this script
    # handles every other "cannot do it, the owner must" case.
    if [ "$(printf '%s' "$desired" | jq -r 'length')" -gt "$max_options" ]; then
        echo "    WARNING: field '$name' has $(printf '%s' "$existing" | jq -r 'length') options and cannot fit $added — GitHub caps a single-select at $max_options" >&2
        at_capacity="${at_capacity}${at_capacity:+; }$name: $added"
        return 0
    fi
    echo "    Field '$name' already exists — appending missing option(s): $added"
    set_options "$(field_id "$name")" "$desired"
}

# ── Status field: full pipeline on a new project; preserve + append on an
#    existing one so items already assigned to an option are never orphaned.
#
#    Status goes through field_exists — the SAME data-type guard as the custom
#    fields below — rather than a bare name lookup. A reused board can carry a
#    field named `Status` that is not a single-select, and handing that to
#    append_options reaches existing_options, whose jq iterates a null
#    `.options` and exits 5; under `set -euo pipefail` that aborts the entire
#    run rather than warning, leaving a half-reconciled project (on an org,
#    after ORG_PROJECT_ID has already been repointed above). ──
if field_exists "Status" SINGLE_SELECT; then
    # A data-type mismatch already warned and is repeated by report_incompatible;
    # options cannot be added to such a field, so skip it and carry on.
    if [ "$field_matched" = "1" ]; then
        if [ "$created" = "1" ]; then
            # A project GitHub just created for us carries its default Status
            # options and nothing is assigned to them yet, so replacing the list
            # wholesale is safe.
            echo "==> Setting Status to the full pipeline (new project)"
            set_options "$(field_id "Status")" "$(printf '%s' "$status_pipeline" | jq -c .)"
        else
            echo "==> Syncing Status (keeping existing options, appending any missing)"
            append_options "Status" "$status_pipeline"
        fi
    fi
else
    echo "==> Creating the Status field with the full pipeline"
    frag=$(printf '%s' "$status_pipeline" | jq -r "$opts_to_graphql")
    gh api graphql -f p="$project_id" \
        -f query="mutation(\$p:ID!){createProjectV2Field(input:{projectId:\$p,dataType:SINGLE_SELECT,name:\"Status\",singleSelectOptions:[$frag]}){projectV2Field{... on ProjectV2SingleSelectField{id}}}}" \
        >/dev/null
fi

# ── Custom fields: create if missing; an existing single-select is reconciled by
#    append_options above. ──
create_single_select() {
    name="$1"
    options_json="$2"
    if field_exists "$name" SINGLE_SELECT; then
        # A data-type mismatch already warned; options cannot be added to it.
        if [ "$field_matched" = "1" ]; then
            append_options "$name" "$options_json"
        fi
        return 0
    fi
    echo "    Creating single-select field '$name'"
    frag=$(printf '%s' "$options_json" | jq -r "$opts_to_graphql")
    gh api graphql -f p="$project_id" \
        -f query="mutation(\$p:ID!){createProjectV2Field(input:{projectId:\$p,dataType:SINGLE_SELECT,name:\"$name\",singleSelectOptions:[$frag]}){projectV2Field{... on ProjectV2SingleSelectField{id}}}}" \
        >/dev/null
}

create_text() {
    name="$1"
    if field_exists "$name" TEXT; then
        if [ "$field_matched" = "1" ]; then
            echo "    Field '$name' already exists — leaving it as-is"
        fi
        return 0
    fi
    echo "    Creating text field '$name'"
    gh api graphql -f p="$project_id" \
        -f query="mutation(\$p:ID!){createProjectV2Field(input:{projectId:\$p,dataType:TEXT,name:\"$name\"}){projectV2Field{... on ProjectV2FieldCommon{id}}}}" \
        >/dev/null
}

create_number() {
    name="$1"
    if field_exists "$name" NUMBER; then
        if [ "$field_matched" = "1" ]; then
            echo "    Field '$name' already exists — leaving it as-is"
        fi
        return 0
    fi
    echo "    Creating number field '$name'"
    gh api graphql -f p="$project_id" \
        -f query="mutation(\$p:ID!){createProjectV2Field(input:{projectId:\$p,dataType:NUMBER,name:\"$name\"}){projectV2Field{... on ProjectV2FieldCommon{id}}}}" \
        >/dev/null
}

# Size: a project NUMBER field for BOTH owner types — estimation points on the
# Fibonacci ladder (1/2/3/5/8/13/21; the ladder is a convention, the field takes
# free numeric entry). Project views can group/filter/sort by org ISSUE-field
# columns, but group-header SUMS only work for project NUMBER fields — and the
# per-group sum is Size's whole job (docs/project-management.md, Planning view).
# GitHub's built-in Effort ISSUE field (single-select) is left at its default;
# Size is the numeric, summable estimate.
echo "==> Size project field (number — views sum it per group)"
create_number "Size"

# Other metadata: on an ORGANIZATION these are org-level ISSUE fields (durable —
# the value is on the issue, shared across every project; see
# docs/project-management.md). Priority is a GitHub built-in;
# setup-github-issue-fields.sh adds Product. A personal account has no org
# issue fields, so fall back to creating them as project fields here.
if [ "$owner_type" = "Organization" ]; then
    echo "==> Other metadata are org issue fields (Priority/Effort built-ins, left at their defaults; run setup-github-issue-fields.sh for Product)"
    report_incompatible
    finish_project
    exit 0
fi

echo "==> Custom project fields (personal account; starters — re-runs append missing ones, never clobber yours)"
create_single_select "Priority" '[
  {"name":"Urgent","color":"RED","description":""},
  {"name":"High","color":"ORANGE","description":""},
  {"name":"Medium","color":"YELLOW","description":""},
  {"name":"Low","color":"GRAY","description":""}
]'
create_text "Product"
# There is deliberately no Agent field. Advisory agent routing is the
# `suggest:*` label family (registry-driven via setup-github-labels.sh) plus
# the `Status: Agent Queue` lane; the live claim is a `claim:*` label written
# by the agent itself. A single-select field could carry neither answer without
# duplicating the label vocabulary (docs/project-management.md, ADR 0005 D4).
# There is likewise deliberately no Domain or Layer field (#875) — same
# reasoning as Agent: the `domain:`/`layer:` labels in setup-github-labels.sh
# are the only surface now. See docs/project-management.md, "Label or field?".

report_incompatible
finish_project
