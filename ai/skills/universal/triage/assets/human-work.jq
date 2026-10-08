# human-work.jq — shared triage scan/apply projection.
# Concatenate after issue-conformance.jq (its criteria helpers are prerequisites).
# Inline both files to avoid jq 1.8 multi-level include crashes.
  # Count every checkbox line in acceptance criteria at any indentation.
  # Leave the shared groom projection unchanged.
  # A majority is evidence for human work, not a guess from title keywords.
  def human_work($issue; $ls):
    ([criteria_lines($issue.body)[]
      | sub("^[ \\t]*"; "") | select(test(checkbox_line_re))
      | rest_tag(checkbox_rest(.))]) as $tags
    | ([$tags[] | select(. == "human")] | length) as $human
    | ($issue.title | test("^\\((HUMAN|QA)\\): ")) as $collector
    | {labelled: (($ls | index("human")) != null),
       collector: $collector, human_criteria: $human,
       total_criteria: ($tags | length),
       recommendation: (if $collector or ($human * 2 > ($tags | length))
                        then "human" else "review" end)};
