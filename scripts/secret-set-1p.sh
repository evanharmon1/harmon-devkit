#!/usr/bin/env bash
# Update an existing 1Password item field from stdin without passing the secret
# in shell history, environment variables, or process arguments.
set -euo pipefail

fail() {
    echo "secret:set:1p: $*" >&2
    exit 1
}

usage() {
    cat >&2 <<'USAGE'
Usage:
  secret-producing-command | task secret:set:1p VAULT=<vault> ITEM=<item> FIELD=<field> [SECTION=<section>]

The secret is read from stdin. VAULT, ITEM, FIELD, and optional SECTION identify
an existing 1Password field to update; the field is not created automatically.
USAGE
}

vault="${VAULT:-}"
item="${ITEM:-}"
field="${FIELD:-}"
section="${SECTION:-}"

if [ -z "$vault" ] || [ -z "$item" ] || [ -z "$field" ]; then
    usage
    fail "VAULT, ITEM, and FIELD are required"
fi

if [ -t 0 ]; then
    usage
    fail "secret must be piped on stdin"
fi

command -v op >/dev/null 2>&1 || fail "op CLI is required"
command -v jq >/dev/null 2>&1 || fail "jq is required"

# Keep the caller's stdin available to jq as a raw file while jq reads the
# 1Password item JSON from the pipeline.
exec 3<&0

op item get "$item" --vault "$vault" --format json --reveal |
    jq \
        --arg field "$field" \
        --arg section "$section" \
        --rawfile secret /dev/fd/3 \
        '
        def secret_value:
          $secret | sub("\r?\n$"; "");

        def field_matches:
          .label == $field
          and (
            ($section | length) == 0
            or (((.section? // {}) | .label? // "") == $section)
          );

        (secret_value) as $value
        | if ($value | length) == 0 then
            error("stdin secret is empty")
          else
            .
          end
        | ([.fields[] | select(field_matches)] | length) as $match_count
        | if $match_count == 0 then
            error("no matching 1Password field")
          elif $match_count > 1 then
            error("multiple matching 1Password fields; set SECTION")
          else
            (.fields[] |= if field_matches then .value = $value else . end)
          end
        ' |
    op item edit "$item" --vault "$vault" >/dev/null

echo "Updated 1Password item '$item' field '$field'."
