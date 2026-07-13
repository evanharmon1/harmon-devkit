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
The target field must be CONCEALED, and items holding a passkey or SSH key are
rejected (op's full-item edit flow would clobber them).
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
        # Fail closed on items op cannot safely round-trip via a full-item JSON
        # edit: passkeys are unsupported in the template flow (a get -> edit
        # round-trip silently overwrites/destroys them), and SSH-key items are
        # likewise not template-editable. Signals: the item category, or any
        # field carrying a structured (object) value — plain STRING/CONCEALED
        # fields are scalars, so an object value marks a passkey/SSH-key/document
        # credential we must not touch.
        | if (.category == "SSHKEY" or .category == "PASSKEY")
             or (([.fields[] | select((.value | type) == "object")] | length) > 0) then
            error("item holds a passkey or SSH key; refusing full-item edit (op would clobber it)")
          else
            .
          end
        | ([.fields[] | select(field_matches)] | length) as $match_count
        | if $match_count == 0 then
            error("no matching 1Password field")
          elif $match_count > 1 then
            error("multiple matching 1Password fields; set SECTION")
          # Require the target to be a CONCEALED field: field_matches keys only
          # on label/section, so without this a STRING (plaintext) field with the
          # same label would receive the secret in the clear.
          elif ([.fields[] | select(field_matches and .type == "CONCEALED")] | length) == 0 then
            error("matching field is not CONCEALED; refusing to write a secret to a non-concealed field")
          else
            (.fields[] |= if field_matches then .value = $value else . end)
          end
        ' |
    op item edit "$item" --vault "$vault" >/dev/null

echo "Updated 1Password item '$item' field '$field'."
