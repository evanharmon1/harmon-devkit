#!/usr/bin/env bash
# Offline behavioral test suite for track-work/assets/label-lifecycle-audit.mjs.
# Uses a stubbed read-only `gh` test double; never touches live GitHub.
set -euo pipefail

script_dir="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
audit="$script_dir/label-lifecycle-audit.mjs"
fixtures="$script_dir/fixtures/label-lifecycle-audit"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/test-label-lifecycle-audit.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

pass=0
ok() {
    pass=$((pass + 1))
    printf '  ✓ %s\n' "$*" || true
    return 0
}

die() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

stub_bin="$tmp/bin"
mkdir -p "$stub_bin"
calls_log="$tmp/gh-calls.log"
: >"$calls_log"

cat >"$stub_bin/gh" <<'PYGH'
#!/usr/bin/env python3
import json
import os
import sys

argv = sys.argv[1:]
calls_path = os.environ["MOCK_GH_CALLS"]
with open(calls_path, "a", encoding="utf-8") as fh:
    fh.write("gh " + " ".join(argv) + "\n")

if os.environ.get("MOCK_GH_FAIL") == "1":
    sys.stderr.write("simulated gh failure\n")
    sys.exit(1)

if os.environ.get("MOCK_GH_BAD_JSON") == "1":
    print("{not json")
    sys.exit(0)

# Enforce read-only contract inside the stub too so any write immediately fails.
if not argv:
    sys.exit(2)
cmd = argv[0]
sub = argv[1] if len(argv) > 1 else ""
if cmd in ("label",) or (cmd in ("issue", "pr") and sub not in ("list", "view")):
    sys.stderr.write(f"unexpected gh write invocation: {' '.join(argv)}\n")
    sys.exit(99)
if cmd == "api":
    for i, tok in enumerate(argv):
        if tok in ("-X", "--method") and i + 1 < len(argv) and argv[i + 1].upper() != "GET":
            sys.stderr.write(f"unexpected non-GET api call: {' '.join(argv)}\n")
            sys.exit(99)
        if tok in ("-f", "-F", "--field", "--raw-field", "--input"):
            sys.stderr.write(f"unexpected api body/field write: {' '.join(argv)}\n")
            sys.exit(99)

with open(os.environ["MOCK_GH_FIXTURE"], "r", encoding="utf-8") as fh:
    data = json.load(fh)


def flag_val(args, name):
    for i, tok in enumerate(args):
        if tok == name and i + 1 < len(args):
            return args[i + 1]
        if tok.startswith(name + "="):
            return tok.split("=", 1)[1]
    return None


def select_fields(obj, fields_csv):
    if not fields_csv:
        return obj
    fields = [f.strip() for f in fields_csv.split(",") if f.strip()]
    return {k: obj.get(k) for k in fields}


if cmd == "issue" and sub == "list":
    state_filter = (flag_val(argv, "--state") or "open").upper()
    fields = flag_val(argv, "--json")
    issues = []
    for item in data.get("issues", {}).values():
        if state_filter != "ALL" and item.get("state", "OPEN").upper() != state_filter:
            continue
        issues.append(select_fields(item, fields))
    print(json.dumps(issues))
    sys.exit(0)

if cmd == "issue" and sub == "view":
    num = argv[2]
    item = data.get("issues", {}).get(num)
    if not item:
        sys.stderr.write(f"issue #{num} not found\n")
        sys.exit(1)
    fields = flag_val(argv, "--json")
    print(json.dumps(select_fields(item, fields)))
    sys.exit(0)

if cmd == "pr" and sub == "list":
    state_filter = (flag_val(argv, "--state") or "open").upper()
    head_filter = flag_val(argv, "--head")
    label_filter = flag_val(argv, "--label")
    fields = flag_val(argv, "--json")
    prs = []
    for item in data.get("prs", {}).values():
        pr_state = item.get("state", "OPEN").upper()
        if state_filter == "OPEN" and pr_state != "OPEN":
            continue
        if state_filter == "CLOSED" and pr_state not in ("CLOSED", "MERGED"):
            continue
        if head_filter is not None and item.get("headRefName") != head_filter:
            continue
        if label_filter is not None:
            names = [lbl["name"].lower() for lbl in item.get("labels", [])]
            if label_filter.lower() not in names:
                continue
        prs.append(select_fields(item, fields))
    print(json.dumps(prs))
    sys.exit(0)

if cmd == "pr" and sub == "view":
    num = argv[2]
    item = data.get("prs", {}).get(num)
    if not item:
        sys.stderr.write(f"pr #{num} not found\n")
        sys.exit(1)
    fields = flag_val(argv, "--json")
    print(json.dumps(select_fields(item, fields)))
    sys.exit(0)

if cmd == "api":
    endpoint = next((tok for tok in argv[1:] if tok.startswith("repos/")), "")
    if "/compare/" in endpoint:
        spec = endpoint.split("/compare/", 1)[1]
        comp = data.get("compares", {}).get(spec)
        if comp is None:
            sys.stderr.write(f"compare not found: {spec}\n")
            sys.exit(1)
        print(json.dumps(comp))
        sys.exit(0)

sys.stderr.write(f"unhandled gh command: {' '.join(argv)}\n")
sys.exit(2)
PYGH
chmod +x "$stub_bin/gh"

run_audit() {
    local fixture=$1
    shift
    local out="$tmp/out.json"
    local err="$tmp/err.txt"
    local rc=0
    PATH="$stub_bin:$PATH" MOCK_GH_FIXTURE="$fixture" MOCK_GH_CALLS="$calls_log" \
        node "$audit" --repo evanharmon1/harmon-devkit "$@" >"$out" 2>"$err" || rc=$?
    return "$rc"
}

echo "Running label-lifecycle-audit.mjs tests..."

# 1. Clean fixture
rc=0
run_audit "$fixtures/clean.json" || rc=$?
[ "$rc" -eq 0 ] || die "clean fixture exited $rc (stderr: $(cat "$tmp/err.txt"))"
python3 - "$tmp/out.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
assert data == [], f"expected [], got {data}"
PY
ok "clean fixture passes with exit 0 and [] (including blocked w/o PR and sibling needs-review)"

# 2. never-coexist fixture
rc=0
run_audit "$fixtures/never-coexist.json" || rc=$?
[ "$rc" -eq 1 ] || die "never-coexist fixture expected exit 1, got $rc"
python3 - "$tmp/out.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
got = {(r["repo"], r["object"]["type"], r["object"]["number"], r["class"]): r["labels"] for r in data}
assert ("evanharmon1/harmon-devkit", "issue", 20, "never-coexist") in got, got
assert ("evanharmon1/harmon-devkit", "pr", 201, "never-coexist") in got, got
assert ("evanharmon1/harmon-devkit", "pr", 201, "mirror-mismatch") in got, got
assert got[("evanharmon1/harmon-devkit", "issue", 20, "never-coexist")] == ["slated", "claim:claude", "parked"]
PY
ok "never-coexist catches issue and PR violations"

# 3. mirror-mismatch fixture (keyed strictly on claim branch PRs, ignoring unrelated PRs)
rc=0
run_audit "$fixtures/mirror-mismatch.json" || rc=$?
[ "$rc" -eq 1 ] || die "mirror-mismatch fixture expected exit 1, got $rc"
python3 - "$tmp/out.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
got = [(r["object"]["type"], r["object"]["number"], r["class"]) for r in data]
expected = [
    ("pr", 301, "mirror-mismatch"),
    ("pr", 303, "mirror-mismatch"),
    ("pr", 304, "mirror-mismatch"),
    ("pr", 305, "mirror-mismatch"),
]
assert sorted(got) == sorted(expected), f"got {got}, expected {expected}"
assert all(r["object"]["number"] != 302 for r in data), f"unrelated PR #302 must not trigger mirror-mismatch: {data}"
PY
ok "mirror-mismatch catches claim:*, needs-review, parked, blocked, merge-ready on claim branch and ignores non-claim-branch PRs"

# 4. Remaining violation classes
rc=0
run_audit "$fixtures/lifecycle-violations.json" || rc=$?
[ "$rc" -eq 1 ] || die "lifecycle-violations fixture expected exit 1, got $rc"
python3 - "$tmp/out.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
got = [(r["object"]["type"], r["object"]["number"], r["class"], r["labels"]) for r in data]
by_pr = {(num, cls): labels for typ, num, cls, labels in got if typ == "pr"}
assert (401, "draft-in-integration-unclaimed") in by_pr, got
assert (501, "passed-draft-unparked") in by_pr, got
assert (601, "merge-ready-draft") in by_pr, got
assert (602, "merge-ready-behind-base") in by_pr, got
assert (701, "closed-with-state-label") in by_pr, got
assert (702, "closed-with-state-label") in by_pr, got
assert len(got) == 6, f"unexpected extra violations: {got}"
PY
ok "draft-in-integration-unclaimed, passed-draft-unparked, merge-ready-draft, merge-ready-behind-base, and closed-with-state-label all reported"

# 5. --slate scoping
rc=0
run_audit "$fixtures/slate-scoping.json" --slate slate-a || rc=$?
[ "$rc" -eq 1 ] || die "slate-scoping fixture expected exit 1, got $rc"
python3 - "$tmp/out.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
assert len(data) == 1, f"expected 1 violation in slate-a, got {data}"
assert data[0]["object"] == {"type": "pr", "number": 801}
assert data[0]["class"] == "draft-in-integration-unclaimed"
PY
ok "--slate scoping includes active slate members and ignores removed/other/untrusted members"

# 6. Dynamic rules derivation from lifecycle-labels.sh --rules-json
custom_rules="$tmp/custom-rules.sh"
cat >"$custom_rules" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "--rules-json" ]; then
    cat <<'JSON'
{
  "asset": "custom",
  "labels": {
    "slated": {"managed": false, "object_scope": "issue", "add_events": [], "remove_events": [], "never_coexists_with": []},
    "claim:*": {"managed": true, "object_scope": "issue", "add_events": [], "remove_events": [], "never_coexists_with": ["blocked"]},
    "blocked": {"managed": true, "object_scope": "issue_and_pr_if_present", "add_events": [], "remove_events": [], "never_coexists_with": ["claim:*"]}
  }
}
JSON
    exit 0
fi
exit 2
SH
chmod +x "$custom_rules"
cat >"$tmp/custom-fixture.json" <<'JSON'
{
  "issues": {
    "90": {
      "number": 90,
      "state": "OPEN",
      "labels": [{"name": "slated"}, {"name": "claim:claude"}, {"name": "blocked"}],
      "assignees": [],
      "closedByPullRequestsReferences": [],
      "comments": []
    }
  },
  "prs": {},
  "compares": {}
}
JSON
rc=0
run_audit "$tmp/custom-fixture.json" --rules-asset "$custom_rules" || rc=$?
[ "$rc" -eq 1 ] || die "custom rules fixture expected exit 1, got $rc"
python3 - "$tmp/out.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
assert len(data) == 1 and data[0]["class"] == "never-coexist" and data[0]["object"]["number"] == 90, data
PY
ok "never-coexist and mirrored rules derive dynamically from --rules-json"

# 7. Env-selected gh path (LABEL_LIFECYCLE_AUDIT_GH) and JS function seam
rc=0
MOCK_GH_FIXTURE="$fixtures/clean.json" MOCK_GH_CALLS="$calls_log" \
    LABEL_LIFECYCLE_AUDIT_GH="$stub_bin/gh" \
    node "$audit" --repo evanharmon1/harmon-devkit >"$tmp/env-out.json" 2>"$tmp/err.txt" || rc=$?
[ "$rc" -eq 0 ] || die "env-selected gh path exited $rc"
node - "$audit" "$fixtures/clean.json" <<'JS'
import { readFileSync } from 'node:fs'
const [,, auditPath, fixturePath] = process.argv
const { auditLifecycleLabels } = await import(auditPath)
const fixture = JSON.parse(readFileSync(fixturePath, 'utf8'))
const seen = []
const violations = await auditLifecycleLabels({ repo: 'evanharmon1/harmon-devkit' }, {
  gh(argv) {
    seen.push(argv)
    if (argv[0] === 'issue' && argv[1] === 'list') return JSON.stringify(Object.values(fixture.issues))
    if (argv[0] === 'issue' && argv[1] === 'view') return JSON.stringify(fixture.issues[argv[2]])
    if (argv[0] === 'pr' && argv[1] === 'list') {
      const stateIdx = argv.indexOf('--state')
      const st = stateIdx >= 0 ? argv[stateIdx + 1] : 'open'
      return JSON.stringify(Object.values(fixture.prs).filter((p) => st === 'open' ? p.state === 'OPEN' : p.state !== 'OPEN'))
    }
    if (argv[0] === 'pr' && argv[1] === 'view') return JSON.stringify(fixture.prs[argv[2]])
    if (argv[0] === 'api' && argv.includes('GET')) {
      const ep = argv.find((x) => x.startsWith('repos/'))
      const spec = ep.split('/compare/')[1]
      return JSON.stringify(fixture.compares[spec])
    }
    throw new Error(`unexpected argv: ${argv.join(' ')}`)
  },
})
if (!Array.isArray(violations) || violations.length !== 0 || seen.length === 0) {
  throw new Error(`unexpected seam result: ${JSON.stringify({ violations, seenCount: seen.length })}`)
}
JS
ok "LABEL_LIFECYCLE_AUDIT_GH env seam and auditLifecycleLabels() function seam work"

# 8. Error handling -> exit 2
rc=0
PATH="$stub_bin:$PATH" MOCK_GH_FIXTURE="$fixtures/clean.json" MOCK_GH_CALLS="$calls_log" MOCK_GH_FAIL=1 \
    node "$audit" --repo evanharmon1/harmon-devkit >"$tmp/err-out.json" 2>"$tmp/err.txt" || rc=$?
[ "$rc" -eq 2 ] || die "gh failure expected exit 2, got $rc"

rc=0
PATH="$stub_bin:$PATH" MOCK_GH_FIXTURE="$fixtures/clean.json" MOCK_GH_CALLS="$calls_log" MOCK_GH_BAD_JSON=1 \
    node "$audit" --repo evanharmon1/harmon-devkit >"$tmp/err-out.json" 2>"$tmp/err.txt" || rc=$?
[ "$rc" -eq 2 ] || die "malformed gh json expected exit 2, got $rc"

rc=0
node "$audit" --repo bad-repo >"$tmp/err-out.json" 2>"$tmp/err.txt" || rc=$?
[ "$rc" -eq 2 ] || die "invalid --repo expected exit 2, got $rc"
ok "usage and gh read errors exit 2"

# 9. Verify stub recorded zero write operations across the entire suite
python3 - "$calls_log" <<'PY'
import sys
lines = [line.strip() for line in open(sys.argv[1]) if line.strip()]
assert len(lines) > 0, "expected gh calls to be recorded"
for line in lines:
    toks = line.split()
    assert toks[0] == "gh", line
    assert toks[1] in ("issue", "pr", "api"), f"forbidden gh command: {line}"
    if toks[1] in ("issue", "pr"):
        assert toks[2] in ("list", "view"), f"forbidden gh write subcommand: {line}"
    else:
        assert "--method GET" in line, f"non-GET api call: {line}"
        assert not any(f in toks for f in ("-f", "-F", "--field", "--raw-field", "--input")), f"api write flag: {line}"
PY
ok "gh stub recorded zero write commands across all runs"

printf 'label-lifecycle-audit: %d checks passed\n' "$pass"
