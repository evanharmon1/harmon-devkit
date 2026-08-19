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
#   guidance|label|description|family|purpose
#
# `writers` is effective: a value override wins over its family writers.
# `guidance` deliberately has no policy fields: it is the read-only, pre-
# authoring discovery view, not a second validation interface.
set -euo pipefail

usage() {
    echo "Usage: $0 {validate|render} MANIFEST" >&2
    echo "       $0 guidance MANIFEST REPOSITORY" >&2
    exit 2
}

die() {
    echo "label-registry: $*" >&2
    exit 1
}

command="$1"
case "$command" in
validate | render)
    [ "$#" -eq 2 ] || usage
    manifest="$2"
    ;;
guidance)
    [ "$#" -eq 3 ] || usage
    manifest="$2"
    repo="$3"
    ;;
*) usage ;;
esac

manifest_present=0
if [ -e "$manifest" ] || [ -L "$manifest" ]; then
    manifest_present=1
fi
if [ "$command" != guidance ] || [ "$manifest_present" -eq 1 ]; then
    [ -f "$manifest" ] && [ -r "$manifest" ] ||
        die "manifest is not a readable regular file: $manifest"
fi

validate() {
    jq -e '
      def keys_only($allowed): ((keys_unsorted - $allowed) | length) == 0;
      def nonempty($max):
        type == "string" and length > 0 and length <= $max;
      def transport_safe:
        type == "string" and (test("[\\r\\n|]") | not);
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
      def value_valid($family):
        keys_only(["value", "description", "color", "writers", "writer_note",
                   "readers", "lifecycle", "lifecycle_note", "trust_note",
                   "arming", "provision", "retired"])
        and (.value | nonempty(50) and transport_safe)
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

if [ "$command" = guidance ] && [ "$manifest_present" -eq 0 ]; then
    # A repository with no manifest has no declared family or policy to infer.
    # Preserve only the bounded, human-readable GitHub label data and omit
    # execution controls by their stable namespaces.
    gh label list --repo "$repo" --limit 1000 --json name,description \
        -q '.[] | [.name, (.description // "")] | @tsv' |
        while IFS=$'\t' read -r label description; do
            case "$label" in
            claim:* | suggest:* | agent:* | foreman:* | rigor:* | tier:* | method:*) continue ;;
            esac
            case "$label$description" in
            *'|'* | *$'\n'* | *$'\r'*) die "live label data is not safe to render" ;;
            esac
            printf 'guidance|%s|%s||\n' "$label" "$description"
        done || die "could not read live labels from $repo"
    exit 0
fi

validate || die "manifest is invalid or unsupported"
[ "$command" = validate ] && exit 0

if [ "$command" = guidance ]; then
    # The manifest owns label descriptions and family purpose. Omit values
    # whose namespaces are workflow controls, including delegated
    # agent-registry families; this is discovery for issue authoring, not a
    # route into claims, suggestions, Foreman, or execution-budget controls.
    jq -e '
      all(.families[];
        (.purpose | test("[\\r\\n|]") | not)
        and all(.values[]; ((.description // "") | test("[\\r\\n|]") | not)))
    ' "$manifest" >/dev/null ||
        die "manifest guidance fields are not safe to render"
    jq -r '
      .families[] as $f
      | select(($f.retired // false) | not)
      | select(($f.family | IN("claim", "suggest", "claim-model", "suggest-model",
                               "agent-legacy", "foreman-arming", "foreman-protocol",
                               "foreman-lifecycle", "rigor", "tier", "method")) | not)
      | $f.values[]
      | select((.retired // false) | not)
      | (if $f.prefix == null then .value else "\($f.prefix):\(.value)" end) as $label
      | ["guidance", $label, (.description // ""), $f.family, $f.purpose]
      | join("|")
    ' "$manifest" || die "could not render manifest guidance"
    exit 0
fi

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
