# issue-conformance.jq — shared issue scan projection and conformance facts.
#
# Shared by triage-scan.sh and groom-scan.sh to ensure per-issue conformance
# facts (work type, axis state, needs-triage flags, criteria counts, title validity)
# are computed with exactly one implementation and never drift.

include "issue-title";

# Acceptance criteria checkbox facts
def checkbox_line_re:
  "^([-*+]|[0-9]{1,9}[.)])[ \\t]+\\[[ \\txX]\\]([ \\t]|$)";

def checkbox_unticked_re:
  "^([-*+]|[0-9]{1,9}[.)])[ \\t]+\\[[ \\t]\\]([ \\t]|$)";

def checkbox_rest($line):
  ($line | capture(
    "^([-*+]|[0-9]{1,9}[.)])[ \\t]+\\[[ \\txX]\\]([ \\t]+(?<rest>.*))?$"
  )).rest // "";

def rest_tag($rest):
  if ($rest | test("^\\[ci\\]([ \\t]|$)"; "i")) then "ci"
  elif ($rest | test("^\\[human\\]([ \\t]|$)"; "i")) then "human"
  else "untagged" end;

def criteria_lines($body):
  (($body // "") | split("\n"))
  | reduce .[] as $raw ({in: false, fence: null, html: false, out: []};
      (($raw | capture("^[ ]{0,3}(?<f>`{3,}|~{3,})(?<info>.*)$")) // null
       | if . != null and (.f | startswith("`")) and (.info | test("`"))
         then null else . end) as $m
      | if .fence != null then
          (if $m != null and ($m.f[0:1] == .fence[0:1])
              and (($m.f | length) >= (.fence | length))
              and ($raw | test("^[ ]{0,3}(`+|~+)[ \\t]*$"))
           then .fence = null else . end)
        else
          ((if .html then
              (if ($raw | test("-->")) then {html: false, l: ($raw | sub("^.*?-->"; ""))}
               else {html: true, l: ""} end)
            else {html: false, l: $raw} end)
           | if (.html | not) and (.l | test("<!--")) then
               (.l | gsub("<!--.*?-->"; "")) as $g
               | if ($g | test("<!--")) then {html: true, l: ($g | sub("<!--.*$"; ""))}
                 else {html: false, l: $g} end
             else . end) as $c
          | .html = $c.html
          | ($c.l) as $line
          | if $m != null and ($c.l == $raw) then .fence = $m.f
            elif ($line | test("^#[ \\t]+")) then .in = false
            elif ($line | test("^##[ \\t]+")) then
              .in = ($line
                     | sub("^##[ \\t]+"; "")
                     | sub("[ \\t]+#+[ \\t]*$"; "")
                     | sub("[ \\t]+$"; "")
                     | ascii_downcase) == "acceptance criteria"
            elif .in then .out += [$line]
            else . end
        end)
  | .out;

def criteria_facts($body):
  criteria_lines($body) as $lines
  | ([$lines[] | select(test(checkbox_line_re))
      | select(rest_tag(checkbox_rest(.)) != "untagged")] | length) as $total
  | ([$lines[] | select(test(checkbox_unticked_re))]) as $unticked_lines
  | ([$unticked_lines[] | rest_tag(checkbox_rest(.))]) as $tags
  | ([$tags[] | select(. != "untagged")] | length) as $unticked
  | { total: $total,
      unticked: $unticked,
      unticked_ci: ([$tags[] | select(. == "ci")] | length),
      unticked_human: ([$tags[] | select(. == "human")] | length),
      unticked_untagged: ([$tags[] | select(. == "untagged")] | length) };

def completion_reasons($crit):
  [ (if ($crit.total >= 1 and $crit.unticked == 0
         and $crit.unticked_untagged == 0)
     then "completion-candidate:all-criteria-checked" else empty end),
    (if ($crit.total >= 1 and $crit.unticked_ci == 0
         and $crit.unticked_untagged == 0 and $crit.unticked_human >= 1)
     then "completion-candidate:human-only-remaining" else empty end) ];

def axis_labels($ls; $a): [$ls[] | select(startswith($a + ":"))];

def axis_known($ls; $a; $known):
  [axis_labels($ls; $a)[] | select(. as $l | $known | index($l) != null)];

def axis_unknown($ls; $a; $known):
  [axis_labels($ls; $a)[] | select(. as $l | $known | index($l) == null)];

def axis_state($ls; $a; $known):
  (axis_known($ls; $a; $known) | length) as $n
  | if $n > 1 then "conflict"
    elif $n == 1 then "ok"
    elif (axis_unknown($ls; $a; $known) | length) > 0 then "unknown"
    else "none" end;

def axis_optional_when_absent($a): $a == "layer";

def axis_incomplete($ls; $a; $known):
  axis_state($ls; $a; $known) as $state
  | ($state != "ok"
     and ($state != "none" or (axis_optional_when_absent($a) | not)));

# 2-arg forms when $known is in scope:
def axis_known($ls; $a): axis_known($ls; $a; $known);
def axis_unknown($ls; $a): axis_unknown($ls; $a; $known);
def axis_state($ls; $a): axis_state($ls; $a; $known);
def axis_incomplete($ls; $a): axis_incomplete($ls; $a; $known);

# Compute complete conformance block for an issue
def issue_conformance($issue; $axes; $known; $wt; $owner_type; $nts; $claim_stale; $needs_stale):
  ($issue.labels | map(if type == "object" then .name else . end)) as $ls
  | (((now - ($issue.updatedAt | fromdateiso8601)) / 86400) | floor) as $days
  | ($ls | map(select(. as $l | $wt | index($l) != null))) as $have_wt
  | ($axes | map({key: ., value: axis_state($ls; .; $known)}) | from_entries) as $ax
  | ($ls | map(select(startswith("needs-")))) as $needs
  | ($ls | map(select(startswith("claim:") or startswith("agent:")))) as $claims
  | (if $owner_type == "Organization" and $nts != "unknown"
     then ($nts == "set")
     else (($have_wt | length) > 0) end) as $typed
  | (($typed | not)
     or ([$axes[] | select(axis_incomplete($ls; .; $known))] | length > 0)
     or ([$axes[] | axis_unknown($ls; .; $known) | length] | any(. > 0))) as $incomplete
  | (([$ax[]] | any(. == "conflict"))
     or ([$axes[] | axis_unknown($ls; .; $known) | length] | any(. > 0))
     or ($owner_type == "User" and ($have_wt | length) == 0)
     or ($owner_type == "Organization" and $nts == "unset")) as $needs_triage_worthy
  | criteria_facts($issue.body // "") as $crit
  | completion_reasons($crit) as $creasons
  | ([
       (if ($have_wt | length) == 0 and ($owner_type == "User" or $nts == "unset")
        then "missing-work-type" else empty end),
       ($ax | to_entries[]
        | select(.value == "none" and (axis_optional_when_absent(.key) | not))
        | "axis-missing:\(.key)"),
       ($ax | to_entries[] | select(.value == "conflict") | "axis-conflict:\(.key)"),
       ($axes[] | . as $a
        | select((axis_unknown($ls; $a; $known) | length) > 0)
        | "axis-unknown-value:\($a)"),
       (if $needs_triage_worthy and (($ls | index("needs-triage")) == null)
        then "missing-needs-triage" else empty end),
       (if $owner_type == "Organization" and ($have_wt | length) > 0 and $nts == "unset"
        then "legacy-work-type-label" else empty end),
       (if $incomplete and (($ls | index("needs-triage")) != null)
        then "partially-classified" else empty end),
       (if (($ls | index("needs-triage")) != null) and ($incomplete | not)
        then "needs-triage-removable" else empty end),
       (if ($claims | length) > 0 and $days > $claim_stale
        then "stale-claim-candidate" else empty end),
       (if ($ls | index("blocked")) != null
        then "blocked-candidate" else empty end),
       (if ($needs | length) > 0 and $days > $needs_stale
        then "aging-needs-candidate" else empty end),
       (if ($issue.title | length) > 100
        then "title-long" else empty end),
       (if ($issue.title | issue_title_valid | not)
        then "title-malformed" else empty end),
       $creasons[]
     ]) as $flags
  | {
      title_valid: ($issue.title | issue_title_valid),
      title_warn: ($issue.title | issue_title_warn),
      work_type: $have_wt,
      axis_state: $ax,
      needs_labels: $needs,
      claim_labels: $claims,
      criteria: $crit,
      completion_reasons: $creasons,
      flags: $flags
    };
