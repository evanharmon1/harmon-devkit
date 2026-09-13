# Canonical issue-title predicate shared by track-work and triage.
#
# Unicode White_Space is enumerated instead of delegated to a regex engine:
# boundary semantics must include NBSP and the other non-ASCII separators on
# every jq build. Unicode control characters (General Category Cc) are the C0
# and C1 ranges and are forbidden anywhere in the title.
def issue_title_soft_limit: 100;
def issue_title_hard_limit: 120;

def issue_title_is_control:
  . < 32 or (. >= 127 and . <= 159);

def issue_title_is_whitespace:
  issue_title_is_control or . == 32 or . == 160 or . == 5760
  or (. >= 8192 and . <= 8202) or . == 8232 or . == 8233
  or . == 8239 or . == 8287 or . == 12288;

def issue_title_parts:
  if test("^\\([^()]*\\): .*$")
  then capture("^\\((?<scope>[^()]*)\\): (?<outcome>.*)$")
  else null
  end;

def issue_title_length:
  explode | length;

def issue_title_warn:
  . as $title
  | ($title | issue_title_length) as $len
  | ($len > issue_title_soft_limit and $len <= issue_title_hard_limit);

def issue_title_valid:
  . as $title
  | ($title | explode) as $all
  | ($title | issue_title_parts) as $parts
  | ($parts.scope // "" | explode) as $scope
  | ($parts.outcome // "" | explode) as $outcome
  | ($parts != null)
    and (($all | length) <= issue_title_hard_limit)
    and all($all[]; issue_title_is_control | not)
    and (($scope | length) > 0)
    and ((($scope[0] // -1) | issue_title_is_whitespace | not)
         and (($scope[-1] // -1) | issue_title_is_whitespace | not))
    and (($outcome | length) > 0)
    and ((($outcome[0] // -1) | issue_title_is_whitespace | not)
         and (($outcome[-1] // -1) | issue_title_is_whitespace | not))
    and (
      (($parts.outcome // "") | test(
        "^(\\[[^]]*\\]\\s*:?\\s*|(bug|feature|task|research|documentation|question|enhancement):\\s*|(build|chore|ci|docs|feat|fix|perf|refactor|revert|style|test)(\\([^)]*\\))?!?:\\s*|P[0-9]+:\\s*)";
        "i"))
      | not
    );

def issue_title_outcome:
  if test("^\\([^()]*\\): (.*)$")
  then capture("^\\([^()]*\\): (?<outcome>.*)$").outcome
  else .
  end;

def issue_title_is_prefix($cand; $target):
  ($cand | sub("([[:punct:]]|[[:space:]])+$"; "")) as $c
  | ($target | sub("([[:punct:]]|[[:space:]])+$"; "")) as $t
  | ($cand | length) as $cl
  | ($target | length) as $tl
  | ($c | length > 0) and (
      (($cl < $tl) and ($target | startswith($c)))
      or
      (($cl < $tl) and ($c == $t))
    );

def issue_title_is_truncation($prev):
  . as $prop
  | issue_title_is_prefix($prop; $prev)
    or issue_title_is_prefix($prop | issue_title_outcome; $prev | issue_title_outcome)
    or issue_title_is_prefix($prop; $prev | issue_title_outcome);

def issue_title_diagnostics:
  . as $title
  | ($title | explode) as $all
  | ($all | length) as $len
  | ($title | issue_title_parts) as $parts
  | ($parts.scope // "" | explode) as $scope
  | ($parts.outcome // "" | explode) as $outcome
  | [
      (if $len > issue_title_hard_limit
       then "title is \($len) code points; exceeds hard limit of \(issue_title_hard_limit) (ceiling is \(issue_title_hard_limit))"
       else empty end),
      (if any($all[]; issue_title_is_control)
       then "title is \($len) code points; title contains Unicode control characters"
       else empty end),
      (if (if test("^\\([^:]*\\):") then (capture("^\\((?<raw>[^:]*)\\):").raw | test("[()]")) else false end)
       then "title is \($len) code points; scope contains parentheses"
       else empty end),
      (if test("^\\s") or test("\\s$")
       then "title is \($len) code points; surrounding whitespace in title"
       else empty end),
      (if $parts == null and (test("^\\(.*\\):") | not) and ((if test("^\\([^:]*\\):") then (capture("^\\((?<raw>[^:]*)\\):").raw | test("[()]")) else false end) | not)
       then "title is \($len) code points; missing (scope): prefix"
       else empty end),
      (if $parts == null and test("^\\([^()]*\\):") and (test("^\\([^()]*\\): ") | not)
       then "title is \($len) code points; missing space after (scope): separator"
       else empty end),
      (if $parts == null and test("^\\([^()]*\\) :")
       then "title is \($len) code points; unexpected space before colon in (scope): separator"
       else empty end),
      (if $parts != null and ($scope | length) == 0
       then "title is \($len) code points; scope must not be empty"
       else empty end),
      (if $parts != null and (($scope[0] // -1 | issue_title_is_whitespace) or ($scope[-1] // -1 | issue_title_is_whitespace))
       then "title is \($len) code points; surrounding whitespace in scope"
       else empty end),
      (if $parts != null and ($outcome | length) == 0
       then "title is \($len) code points; outcome must not be empty"
       else empty end),
      (if $parts != null and (($outcome[0] // -1 | issue_title_is_whitespace) or ($outcome[-1] // -1 | issue_title_is_whitespace))
       then "title is \($len) code points; surrounding whitespace in outcome"
       else empty end),
      (if ($parts != null) and (($parts.outcome // "") | test(
        "^(\\[[^]]*\\]\\s*:?\\s*|(bug|feature|task|research|documentation|question|enhancement):\\s*|(build|chore|ci|docs|feat|fix|perf|refactor|revert|style|test)(\\([^)]*\\))?!?:\\s*|P[0-9]+:\\s*)";
        "i"))
       then "title is \($len) code points; outcome contains forbidden nested prefix"
       else empty end)
    ] as $errors
  | [
      (if $len > issue_title_soft_limit and $len <= issue_title_hard_limit
       then "title is \($len) code points; exceeds soft limit of \(issue_title_soft_limit) (rewrite to shorten; never truncate)"
       else empty end)
    ] as $warnings
  | {
      length: $len,
      soft_limit: issue_title_soft_limit,
      hard_limit: issue_title_hard_limit,
      errors: (if ($errors | length) == 0 and ($title | issue_title_valid | not)
               then ["title is \($len) code points; title violates the canonical '(scope): imperative outcome' contract"]
               else $errors end),
      warnings: $warnings,
      valid: ($title | issue_title_valid),
      warn: ($len > issue_title_soft_limit and $len <= issue_title_hard_limit)
    };
