#!/usr/bin/env bash
# label-registry.sh — one strict label-registry.json interpreter shared by
# universal skills. It validates the complete v1 contract before rendering any
# records, so callers cannot derive policy from a partial or malformed registry.
#
# `render` output is pipe-delimited; its label-derived fields are validated for
# that transport. `guidance` is JSON Lines so schema-valid human prose remains
# exact even when it contains a pipe, tab, or newline.
#
#   family|family|prefix|axis|writers|exclusive|source|open_values|retired
#   value|label|family|prefix|axis|writers|exclusive|source|open_values|family_retired|value_retired
#   {"record":"guidance","label":"…","description":"…","family":"…","purpose":"…"}
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

[ "$#" -ge 1 ] || usage
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
           | map(ascii_downcase) | length == (unique | length))
    ' "$manifest" >/dev/null 2>&1
}

if [ "$command" = guidance ] && [ "$manifest_present" -eq 0 ]; then
    # A repository with no manifest has no declared family or policy to infer.
    # Preserve only the bounded, human-readable GitHub label data and omit
    # execution controls by their stable namespaces. JSON Lines avoids the
    # lossy `@tsv` transport: a reader can recover literal backslashes, tabs,
    # and newlines from the JSON value without making record boundaries
    # ambiguous.
    gh label list --repo "$repo" --limit 1000 --json name,description |
        jq -c '
          def description:
            if (.description? == null) then "" else .description end;
          def control_namespace:
            ascii_downcase | test("^(claim|suggest|agent|foreman|rigor|tier|method|type|autorelease):");
          def authorable_label:
            test("[,|\\r\\n]") | not;
          if type != "array"
             or any(.[]; (.name | type) != "string" or (description | type) != "string")
          then error("live label data is invalid")
          else .[]
          | {label: .name, description: description}
          | select((.label | control_namespace) | not)
          | select(.label | authorable_label)
          | {record: "guidance", label, description, family: null, purpose: null}
          end
        ' || die "could not read live labels from $repo"
    exit 0
fi

validate || die "manifest is invalid or unsupported"
[ "$command" = validate ] && exit 0

if [ "$command" = guidance ]; then
    # The manifest owns label descriptions and family purpose. Omit values
    # whose namespaces are workflow controls, including delegated
    # agent-registry families; this is discovery for issue authoring, not a
    # route into claims, suggestions, Foreman, or execution-budget controls.
    # Active author-selectable open families need one bounded live-label read:
    # the live record supplies the concrete label and description, while the
    # manifest still supplies the family and purpose. Do not read live labels
    # for a manifest that has no such family, so a normal manifest remains
    # self-contained.
    open_family_count="$(jq -r '
      def control_namespace:
        ascii_downcase | test("^(claim|suggest|agent|foreman|rigor|tier|method|type|autorelease):");
      [.families[]
       | select((.retired // false) | not)
       | select(.source != "agent-registry" and .source != "tool-owned")
       | select((.arming // false) | not)
       | select((.gate // "") == "")
       | select(.axis != "strategy" and .axis != "model" and .axis != "foreman")
       | select((.open_values // false) and .prefix != null)
       | select((((.prefix + ":") | control_namespace) | not))]
      | length
    ' "$manifest")" || die "could not inspect manifest open-value families"
    # Keep the bounded GitHub response out of argv: 1,000 labels with rich
    # descriptions can exceed the platform argument limit before jq starts.
    live_labels_file="$(mktemp)"
    trap 'rm -f "$live_labels_file"' EXIT
    if [ "$open_family_count" -gt 0 ]; then
        gh label list --repo "$repo" --limit 1000 --json name,description >"$live_labels_file" ||
            die "could not read live labels for manifest guidance"
    else
        printf '[]\n' >"$live_labels_file"
    fi
    jq -c --slurpfile live "$live_labels_file" '
      def control_namespace:
        ascii_downcase | test("^(claim|suggest|agent|foreman|rigor|tier|method|type|autorelease):");
      def authorable_label:
        test("[,|\\r\\n]") | not;
      def authoring_family:
        ((.retired // false) | not)
        and (.source != "agent-registry" and .source != "tool-owned")
        and ((.arming // false) | not)
        and ((.gate // "") == "")
        and (.axis != "strategy" and .axis != "model" and .axis != "foreman");
      def live_description:
        if (.description? == null) then "" else .description end;
      ($live[0]) as $live
      | if ($live | type) != "array"
         or any($live[]; (.name | type) != "string" or (live_description | type) != "string")
      then error("live label data is invalid")
      else . as $registry
      | [$registry.families[]
         | . as $f
         | select(authoring_family)
         # Open families deliberately get their concrete members from the
         # bounded live read below when their prefix makes that match
         # unambiguous. Prefixless open families have no such live namespace,
         # so their active manifest enumeration remains the selectable set.
         | select(((.open_values // false) | not) or .prefix == null)
         | .values[]
         | select((.retired // false) | not)
         | (if $f.prefix == null then .value else "\($f.prefix):\(.value)" end) as $label
         | select(($label | control_namespace) | not)
         | select(($label | authorable_label))
         | {record: "guidance", label: $label, description: (.description // ""),
            family: $f.family, purpose: $f.purpose}] as $enumerated
      | [$registry.families[]
         | . as $f
         | select(authoring_family and ($f.open_values // false) and $f.prefix != null)] as $open_families
      | [$open_families[] as $f
         | $f.values[]
         | select((.retired // false) | not)
         | {label: "\($f.prefix):\(.value)", label_key: ("\($f.prefix):\(.value)" | ascii_downcase), family: $f.family,
            description: (.description // "")} ] as $open_enumerated
      | [$registry.families[] as $f
         | select(($f.retired // false) | not)
         | $f.values[]
         | select(.retired // false)
            | if $f.prefix == null then .value else "\($f.prefix):\(.value)" end
            | ascii_downcase] as $retired_label_keys
      | [$live[]
         | {label: .name, description: live_description}
         | . as $live_label
         | [$open_families[]
            | select(.prefix as $prefix
                     | ($live_label.label | ascii_downcase)
                     | startswith(($prefix + ":") | ascii_downcase))] as $matches
         | select($matches | length == 1)
         | select(($retired_label_keys | index($live_label.label | ascii_downcase)) | not)
         | $matches[0] as $f
         | select(($live_label.label | control_namespace) | not)
         | select($live_label.label | authorable_label)
         | [$open_enumerated[]
            | select(.family == $f.family and .label_key == ($live_label.label | ascii_downcase))] as $enumerated_match
         | {record: "guidance", label: $live_label.label,
            description: (if ($enumerated_match | length) == 1
                          then $enumerated_match[0].description
                          else $live_label.description end),
            family: $f.family, purpose: $f.purpose}] as $open
      | ($enumerated + $open | unique_by(.label)[])
      end
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
