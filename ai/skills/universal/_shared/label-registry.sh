#!/usr/bin/env bash
# label-registry.sh — one strict label-registry.json interpreter shared by
# universal skills. It validates the complete v1 contract before rendering any
# records, so callers cannot derive policy from a partial or malformed registry.
#
# Output is pipe-delimited and safe to parse only because validation rejects
# pipes/newlines in every rendered free-form value.
#
#   family|family|prefix|axis|writers|exclusive|source|open_values|retired
#   value|label|family|prefix|axis|writers|exclusive|source|open_values|family_retired|value_retired
#
# `writers` is effective: a value override wins over its family writers.
set -euo pipefail

usage() {
    echo "Usage: $0 {validate|render} MANIFEST" >&2
    exit 2
}

die() {
    echo "label-registry: $*" >&2
    exit 1
}

[ "$#" -eq 2 ] || usage
command="$1"
manifest="$2"
case "$command" in
validate | render) ;;
*) usage ;;
esac

[ -f "$manifest" ] && [ -r "$manifest" ] ||
    die "manifest is not a readable regular file: $manifest"

validate() {
    jq -e '
      def keys_only($allowed): ((keys_unsorted - $allowed) | length) == 0;
      def nonempty($max):
        type == "string" and length > 0 and length <= $max
        and (test("[\\r\\n|]") | not);
      def slug($max): nonempty($max) and test("^[a-z0-9]+(-[a-z0-9]+)*$");
      def color: type == "string" and test("^[0-9A-F]{6}$");
      def writer:
        type == "string" and test("^(human|trusted-human|agent|tool:[a-z0-9-]+)$");
      def writers:
        type == "array" and all(.[]; writer)
        and (length == (unique | length));
      def lifecycle: IN("durable", "transient", "claim-release", "tool-managed");
      def optional_string($key; $max):
        (has($key) | not) or (.[$key] | nonempty($max));
      def optional_boolean($key):
        (has($key) | not) or (.[$key] | type == "boolean");
      def reserved_classification_prefix:
        IN("foreman", "rigor", "tier", "method", "claim", "suggest", "agent");
      def value_valid($family):
        keys_only(["value", "description", "color", "writers", "writer_note",
                   "readers", "lifecycle", "lifecycle_note", "trust_note",
                   "arming", "provision", "retired"])
        and (.value | nonempty(50))
        and (if $family.prefix == null then true else (.value | slug(50)) end)
        and optional_string("description"; 100)
        and ((has("color") | not) or (.color | color))
        and ((has("writers") | not) or (.writers | writers and length > 0))
        and optional_string("writer_note"; 10000)
        and optional_string("readers"; 10000)
        and ((has("lifecycle") | not) or (.lifecycle | lifecycle))
        and optional_string("lifecycle_note"; 10000)
        and optional_string("trust_note"; 10000)
        and optional_boolean("arming")
        and ((has("provision") | not) or .provision == false)
        and optional_boolean("retired")
        and (((if $family.prefix == null then .value
               else "\($family.prefix):\(.value)" end) | length) <= 50)
        and (if (($family.arming // false) or (.arming // false))
             then $family.prefix == "foreman" else true end)
        and (if ($family.provision and (.provision != false) and (.retired != true))
             then (has("description") and (has("color") or ($family | has("color"))))
             else true end);
      def family_valid:
        . as $family
        | keys_only(["family", "prefix", "purpose", "axis", "source",
                     "registry_set", "writers", "writer_note", "readers",
                     "lifecycle", "lifecycle_note", "trust_note", "exclusive",
                     "arming", "provision", "gate", "retired", "open_values",
                     "placeholder", "color", "values"])
        and (.family | slug(40))
        and ((.prefix == null) or (.prefix | slug(40)))
        and (.purpose | nonempty(200))
        and (.axis | IN("classification", "strategy", "model", "work-type",
                        "concern", "workflow", "provenance", "foreman",
                        "release", "meta"))
        and (.source | IN("inline", "agent-registry", "tool-owned"))
        and (.writers | writers)
        and ((.retired // false) or (.writers | length > 0))
        and optional_string("writer_note"; 10000)
        and (.readers | nonempty(10000))
        and (.lifecycle | lifecycle)
        and optional_string("lifecycle_note"; 10000)
        and optional_string("trust_note"; 10000)
        and (.exclusive | type == "boolean")
        and optional_boolean("arming")
        and (.provision | type == "boolean")
        and ((has("gate") | not) or (.gate | IN("foreman", "release-please")))
        and optional_boolean("retired")
        and optional_boolean("open_values")
        and optional_string("placeholder"; 50)
        and ((has("color") | not) or (.color | color))
        and (.values | type == "array")
        and (([.values[].value] | length) == ([.values[].value] | unique | length))
        and all(.values[]; value_valid($family))
        and (if (.axis == "classification") then
               (.prefix != null)
               and ((.open_values // false) | not)
               and ((.prefix | reserved_classification_prefix) | not)
             else true end)
        and (if (.retired // false) then (.provision | not) else true end)
        and (if .source == "agent-registry" then
               (.registry_set | IN("suggest", "claim", "foreman-adapters"))
               and (.prefix == ({suggest:"suggest", claim:"claim",
                                 "foreman-adapters":"foreman"}[.registry_set]))
               and (.values | length == 0)
               and ((.retired // false) or (.provision and has("color")))
               and has("placeholder")
             else has("registry_set") | not end)
        and (if .source == "tool-owned" then (.provision | not) else true end)
        and (if .source == "inline" and ((.open_values // false) | not)
                and ((.retired // false) | not)
             then (.values | length > 0) else true end)
        and (if (.open_values // false) then has("placeholder") else true end)
        and (if has("placeholder") and ((.open_values // false) | not)
                and .source != "agent-registry" then false else true end)
        and (if (.arming // false) then .prefix == "foreman" else true end);
      keys_only(["$schema", "schema_version", "families"])
      and .["$schema"] == "./label-registry.schema.json"
      and .schema_version == 1
      and (.families | type == "array" and length > 0)
      and (([.families[].family] | length) ==
           ([.families[].family] | unique | length))
      and all(.families[]; family_valid)
      and ([.families[] as $f | $f.values[]
            | select((($f.retired // false) | not)
                     and ((.retired // false) | not))
            | if $f.prefix == null then .value
              else "\($f.prefix):\(.value)" end]
           | length == (unique | length))
    ' "$manifest" >/dev/null 2>&1
}

validate || die "manifest is invalid or unsupported"
[ "$command" = validate ] && exit 0

jq -r '
  .families[] as $f
  | ["family", $f.family, ($f.prefix // ""), $f.axis,
     ($f.writers | join(",")), ($f.exclusive | tostring), $f.source,
     (($f.open_values // false) | tostring),
     (($f.retired // false) | tostring)]
    | join("|"),
    ($f.values[]
     | ["value",
        (if $f.prefix == null then .value else "\($f.prefix):\(.value)" end),
        $f.family, ($f.prefix // ""), $f.axis,
        ((.writers // $f.writers) | join(",")),
        ($f.exclusive | tostring), $f.source,
        (($f.open_values // false) | tostring),
        (($f.retired // false) | tostring),
        ((.retired // false) | tostring)]
       | join("|"))
' "$manifest" || die "could not render manifest records"
