# Canonical issue-title predicate shared by track-work and triage.
#
# Unicode White_Space is enumerated instead of delegated to a regex engine:
# boundary semantics must include NBSP and the other non-ASCII separators on
# every jq build. Unicode control characters (General Category Cc) are the C0
# and C1 ranges and are forbidden anywhere in the title.
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

def issue_title_valid:
  . as $title
  | ($title | explode) as $all
  | ($title | issue_title_parts) as $parts
  | ($parts.scope // "" | explode) as $scope
  | ($parts.outcome // "" | explode) as $outcome
  | ($parts != null)
    and (($all | length) <= 70)
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
