#!/usr/bin/env bash
# Offline behavioral test suite for track-work/assets/lifecycle-labels.sh.
# Uses a stateful local `gh` test double; never touches live GitHub.
set -euo pipefail

script_dir="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
asset="$script_dir/lifecycle-labels.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/test-lifecycle-labels.XXXXXX")"
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
state_file="$tmp/state.json"
calls_log="$tmp/calls.log"
: >"$calls_log"

cat >"$stub_bin/gh" <<'PYGH'
#!/usr/bin/env python3
import json
import os
import re
import sys

state_path = os.environ["MOCK_GH_STATE"]
calls_path = os.environ["MOCK_GH_CALLS"]
no_stick = os.environ.get("MOCK_NO_STICK", "")
fail_edit = os.environ.get("MOCK_FAIL_EDIT", "")

argv = sys.argv[1:]
with open(calls_path, "a", encoding="utf-8") as fh:
    fh.write("gh " + " ".join(argv) + "\n")

with open(state_path, "r", encoding="utf-8") as fh:
    state = json.load(fh)


def save_state():
    with open(state_path, "w", encoding="utf-8") as fh:
        json.dump(state, fh, indent=2)


def flag_val(args, name):
    for i, tok in enumerate(args):
        if tok == name and i + 1 < len(args):
            return args[i + 1]
        if tok.startswith(name + "="):
            return tok.split("=", 1)[1]
    return None


def flag_vals(args, name):
    out = []
    for i, tok in enumerate(args):
        if tok == name and i + 1 < len(args):
            out.append(args[i + 1])
        elif tok.startswith(name + "="):
            out.append(tok.split("=", 1)[1])
    return out


def next_ts():
    seq = state.get("clock", 10) + 1
    state["clock"] = seq
    minute = (seq // 60) % 60
    second = seq % 60
    return f"2026-11-14T05:{minute:02d}:{second:02d}Z"


def select_fields(obj, fields_csv):
    if not fields_csv:
        return obj
    fields = [f.strip() for f in fields_csv.split(",") if f.strip()]
    return {k: obj.get(k) for k in fields}


if len(argv) >= 2 and argv[0] == "label" and argv[1] == "list":
    fields = flag_val(argv, "--json")
    labels = [{"name": n} for n in state["repo_labels"]]
    print(json.dumps([select_fields(x, fields) for x in labels]))
    sys.exit(0)

if len(argv) >= 2 and argv[0] == "issue" and argv[1] == "view":
    num = argv[2]
    issue = state["issues"].get(num)
    if not issue:
        sys.exit(1)
    fields = flag_val(argv, "--json")
    print(json.dumps(select_fields(issue, fields)))
    sys.exit(0)

if len(argv) >= 2 and argv[0] == "issue" and argv[1] == "edit":
    num = argv[2]
    issue = state["issues"].get(num)
    if not issue:
        sys.exit(1)
    for lbl in flag_vals(argv, "--add-label"):
        if fail_edit == f"add:issue:{num}:{lbl}":
            sys.exit(1)
        if no_stick == f"add:issue:{num}:{lbl}":
            continue
        if not any(x.lower() == lbl.lower() for x in state["repo_labels"]):
            sys.stderr.write(f"label '{lbl}' not found\n")
            sys.exit(1)
        if not any(x["name"].lower() == lbl.lower() for x in issue["labels"]):
            issue["labels"].append({"name": lbl})
            issue["timeline"].append(
                {"event": "labeled", "created_at": next_ts(), "label": {"name": lbl}}
            )
    for lbl in flag_vals(argv, "--remove-label"):
        if fail_edit == f"remove:issue:{num}:{lbl}":
            sys.exit(1)
        if no_stick == f"remove:issue:{num}:{lbl}":
            continue
        before = len(issue["labels"])
        issue["labels"] = [
            x for x in issue["labels"] if x["name"].lower() != lbl.lower()
        ]
        if len(issue["labels"]) != before:
            issue["timeline"].append(
                {"event": "unlabeled", "created_at": next_ts(), "label": {"name": lbl}}
            )
    for login in flag_vals(argv, "--add-assignee"):
        if not any(x["login"].lower() == login.lower() for x in issue["assignees"]):
            issue["assignees"].append({"login": login})
            issue["timeline"].append(
                {
                    "event": "assigned",
                    "created_at": next_ts(),
                    "assignee": {"login": login},
                }
            )
    for login in flag_vals(argv, "--remove-assignee"):
        before = len(issue["assignees"])
        issue["assignees"] = [
            x for x in issue["assignees"] if x["login"].lower() != login.lower()
        ]
        if len(issue["assignees"]) != before:
            issue["timeline"].append(
                {
                    "event": "unassigned",
                    "created_at": next_ts(),
                    "assignee": {"login": login},
                }
            )
    save_state()
    sys.exit(0)

if len(argv) >= 2 and argv[0] == "issue" and argv[1] == "comment":
    num = argv[2]
    issue = state["issues"].get(num)
    if not issue:
        sys.exit(1)
    body_file = flag_val(argv, "--body-file")
    body = flag_val(argv, "--body")
    if body_file == "-":
        body = sys.stdin.read()
    elif body_file:
        with open(body_file, "r", encoding="utf-8") as fh:
            body = fh.read()
    elif body is None:
        body = sys.stdin.read()
    cid = state.get("next_comment_id", 100)
    state["next_comment_id"] = cid + 1
    ts = next_ts()
    user = state["auth_login"]
    issue["comments"].append(
        {
            "id": cid,
            "created_at": ts,
            "updated_at": ts,
            "author_association": "OWNER",
            "user": {"login": user},
            "author": {"login": user},
            "body": body,
        }
    )
    save_state()
    print(f"https://github.com/evanharmon1/harmon-devkit/issues/{num}#issuecomment-{cid}")
    sys.exit(0)

if len(argv) >= 2 and argv[0] == "pr" and argv[1] == "list":
    head = flag_val(argv, "--head")
    fields = flag_val(argv, "--json")
    out = []
    for pr in state["prs"].values():
        if pr["state"] != "OPEN":
            continue
        if head and pr["headRefName"] != head:
            continue
        out.append(select_fields(pr, fields))
    print(json.dumps(out))
    sys.exit(0)

if len(argv) >= 2 and argv[0] == "pr" and argv[1] == "view":
    num = argv[2]
    pr = state["prs"].get(num)
    if not pr:
        sys.exit(1)
    fields = flag_val(argv, "--json")
    print(json.dumps(select_fields(pr, fields)))
    sys.exit(0)

if len(argv) >= 2 and argv[0] == "pr" and argv[1] == "edit":
    num = argv[2]
    pr = state["prs"].get(num)
    if not pr:
        sys.exit(1)
    for lbl in flag_vals(argv, "--add-label"):
        if fail_edit == f"add:pr:{num}:{lbl}":
            sys.exit(1)
        if no_stick == f"add:pr:{num}:{lbl}":
            continue
        if not any(x.lower() == lbl.lower() for x in state["repo_labels"]):
            sys.stderr.write(f"label '{lbl}' not found\n")
            sys.exit(1)
        if not any(x["name"].lower() == lbl.lower() for x in pr["labels"]):
            pr["labels"].append({"name": lbl})
    for lbl in flag_vals(argv, "--remove-label"):
        if fail_edit == f"remove:pr:{num}:{lbl}":
            sys.exit(1)
        if no_stick == f"remove:pr:{num}:{lbl}":
            continue
        pr["labels"] = [
            x for x in pr["labels"] if x["name"].lower() != lbl.lower()
        ]
    save_state()
    sys.exit(0)

if len(argv) >= 2 and argv[0] == "api":
    slurp = "--slurp" in argv
    jq_expr = flag_val(argv, "--jq")
    endpoint = None
    for tok in argv[1:]:
        if tok.startswith("-"):
            continue
        if tok == jq_expr:
            continue
        endpoint = tok
        break
    if endpoint == "user":
        payload = {"login": state["auth_login"], "id": 37220977}
        if jq_expr == ".login":
            print(payload["login"])
        else:
            print(json.dumps(payload))
        sys.exit(0)
    m_comments = re.match(r"^repos/[^/]+/[^/]+/issues/(\d+)/comments", endpoint or "")
    if m_comments:
        issue = state["issues"][m_comments.group(1)]
        data = [issue["comments"]] if slurp else issue["comments"]
        print(json.dumps(data))
        sys.exit(0)
    m_timeline = re.match(r"^repos/[^/]+/[^/]+/issues/(\d+)/timeline", endpoint or "")
    if m_timeline:
        issue = state["issues"][m_timeline.group(1)]
        data = [issue["timeline"]] if slurp else issue["timeline"]
        print(json.dumps(data))
        sys.exit(0)
    m_issue = re.match(r"^repos/[^/]+/[^/]+/issues/(\d+)$", endpoint or "")
    if m_issue:
        raw = state["issues"][m_issue.group(1)]
        rest_issue = {
            "state": raw["state"].lower(),
            "labels": raw["labels"],
            "assignees": raw["assignees"],
        }
        print(json.dumps(rest_issue))
        sys.exit(0)

sys.stderr.write("unexpected mock gh invocation: " + " ".join(argv) + "\n")
sys.exit(1)
PYGH
chmod +x "$stub_bin/gh"

repo="evanharmon1/harmon-devkit"
head_sha="1111111111111111111111111111111111111111"
stale_sha="2222222222222222222222222222222222222222"

registry_file="$tmp/agent-registry.json"
cat >"$registry_file" <<'EOF'
{"families":[{"slug":"claude","legacy_claim_labels":["agent:claude-code"]}]}
EOF

init_fixture() {
    python3 - "$state_file" "$head_sha" <<'PY'
import json
import sys

state_path, head_sha = sys.argv[1], sys.argv[2]
state = {
    "auth_login": "evanharmon1",
    "clock": 10,
    "next_comment_id": 100,
    "repo_labels": [
        "claim:claude",
        "slated",
        "parked",
        "merge-ready",
        "needs-review",
        "blocked",
        "feature",
    ],
    "issues": {
        "42": {
            "state": "OPEN",
            "labels": [{"name": "feature"}, {"name": "slated"}, {"name": "parked"}],
            "assignees": [],
            "comments": [],
            "timeline": [],
            "closedByPullRequestsReferences": [
                {
                    "number": 10,
                    "repository": {
                        "name": "harmon-devkit",
                        "owner": {"login": "evanharmon1"},
                    },
                },
                {
                    "number": 12,
                    "repository": {
                        "name": "harmon-devkit",
                        "owner": {"login": "evanharmon1"},
                    },
                },
                {
                    "number": 99,
                    "repository": {
                        "name": "other-repo",
                        "owner": {"login": "someone"},
                    },
                },
            ],
        }
    },
    "prs": {
        "10": {
            "number": 10,
            "state": "OPEN",
            "isDraft": True,
            "isCrossRepository": False,
            "headRefName": "42-other-closing",
            "headRefOid": head_sha,
            "labels": [{"name": "parked"}],
        },
        "11": {
            "number": 11,
            "state": "OPEN",
            "isDraft": True,
            "isCrossRepository": False,
            "headRefName": "42-feat",
            "headRefOid": head_sha,
            "labels": [{"name": "merge-ready"}],
        },
        "12": {
            "number": 12,
            "state": "CLOSED",
            "isDraft": True,
            "isCrossRepository": False,
            "headRefName": "42-old",
            "headRefOid": head_sha,
            "labels": [{"name": "blocked"}],
        },
        "13": {
            "number": 13,
            "state": "OPEN",
            "isDraft": True,
            "isCrossRepository": True,
            "headRefName": "42-feat",
            "headRefOid": head_sha,
            "labels": [{"name": "parked"}],
        },
    },
}
with open(state_path, "w", encoding="utf-8") as fh:
    json.dump(state, fh, indent=2)
PY
    : >"$calls_log"
}

write_claim_record() {
    local dest="$1" added_assignee="$2" added_label="$3"
    cat >"$dest" <<EOF
Claiming — starting implementation on branch 42-feat (session s-42).

Claim record (for \`/wrap\` — undo only what this claim added):
- harness: Claude Code
- model: claude-sonnet-5-5
- family: claude
- runtime environment: coder
- session: s-42
- assignee added by this claim: $added_assignee
- \`claim:\` label added by this claim: $added_label
- \`claim:\` model label added by this claim: n/a
- \`claim:\` label displaced by this claim: none
- assignee logins owned by this claim chain: evanharmon1
- \`claim:\` label owned by this claim chain: claim:claude
- \`claim:\` model label owned by this claim chain: n/a
- \`claim:\` label displaced by this claim chain: none
EOF
}

run_lc() {
    local rc=0
    PATH="$stub_bin:$PATH" \
        MOCK_GH_STATE="$state_file" \
        MOCK_GH_CALLS="$calls_log" \
        MOCK_NO_STICK="${MOCK_NO_STICK:-}" \
        MOCK_FAIL_EDIT="${MOCK_FAIL_EDIT:-}" \
        GH_REPO="" PR_NUMBER="" \
        "$asset" "$@" >"$tmp/stdout" 2>"$tmp/stderr" || rc=$?
    printf '%s' "$rc"
}

labels_of() {
    local kind="$1" num="$2"
    python3 - "$state_file" "$kind" "$num" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    state = json.load(fh)
bucket = "issues" if sys.argv[2] == "issue" else "prs"
names = sorted(x["name"] for x in state[bucket][sys.argv[3]]["labels"])
print(",".join(names))
PY
}

set_pr_field() {
    local num="$1" field="$2" val_json="$3"
    python3 - "$state_file" "$num" "$field" "$val_json" <<'PY'
import json
import sys

path, num, field, raw = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
with open(path, "r", encoding="utf-8") as fh:
    state = json.load(fh)
state["prs"][num][field] = json.loads(raw)
with open(path, "w", encoding="utf-8") as fh:
    json.dump(state, fh, indent=2)
PY
}

echo "==> lifecycle-labels: CLI help, rules JSON, and slated boundary"
[ "$(run_lc --help)" = "0" ] || die "--help should exit 0"
[ "$(run_lc --rules-json)" = "0" ] || die "--rules-json should exit 0"
jq -e '.labels["slated"].managed == false and (.labels["parked"].add_events == ["park"])' "$tmp/stdout" >/dev/null ||
    die "--rules-json missing expected structure"
[ "$(run_lc slated --repo "$repo" --issue 42)" = "2" ] || die "slated event must exit 2"
grep -Fq "stays outside lifecycle-labels.sh" "$tmp/stderr" || die "slated error must explain boundary"
[ "$(run_lc unknown-event --repo "$repo" --issue 42)" = "2" ] || die "unknown event must exit 2"
ok "CLI usage, --rules-json, and slated exclusion"

echo "==> lifecycle-labels: claim + multi-PR discovery + never-coexist + idempotency"
init_fixture
claim_rec="$tmp/claim-1.md"
write_claim_record "$claim_rec" "yes" "claim:claude"
[ "$(run_lc claim --repo "$repo" --issue 42 --branch 42-feat \
    --record-file "$claim_rec" --claim-label claim:claude \
    --family claude --runtime-environment coder --registry-snapshot "$registry_file")" = "0" ] ||
    die "claim failed: $(cat "$tmp/stderr")"
[ "$(labels_of issue 42)" = "claim:claude,feature,slated" ] ||
    die "claim should add claim:claude, keep slated/feature, and clear parked on issue #42 (got $(labels_of issue 42))"
[ "$(labels_of pr 10)" = "" ] || die "claim should clear conflicting parked on closing-linked PR #10"
[ "$(labels_of pr 11)" = "" ] || die "claim should clear conflicting merge-ready on --branch PR #11"
[ "$(labels_of pr 12)" = "blocked" ] || die "closed PR #12 must remain untouched during active transitions"
[ "$(labels_of pr 13)" = "parked" ] || die "cross-repository PR #13 must remain untouched"

# Repeat same claim call -> idempotent exit 0
[ "$(run_lc claim --repo "$repo" --issue 42 --branch 42-feat \
    --record-file "$claim_rec" --claim-label claim:claude \
    --family claude --runtime-environment coder --registry-snapshot "$registry_file")" = "0" ] ||
    die "repeated claim must be idempotent: $(cat "$tmp/stderr")"
ok "claim delegates to claim-transaction.sh, clears never-coexist labels, and is idempotent"

echo "==> lifecycle-labels: review-entry, sibling review-clear retention, and fix-round"
[ "$(run_lc review-entry --repo "$repo" --issue 42 --branch 42-feat)" = "0" ] ||
    die "review-entry failed: $(cat "$tmp/stderr")"
[ "$(labels_of issue 42)" = "claim:claude,feature,needs-review,slated" ] ||
    die "review-entry should add needs-review while retaining claim:claude and slated (got $(labels_of issue 42))"
[ "$(labels_of pr 10)" = "needs-review" ] || die "review-entry must label closing-linked PR #10"
[ "$(labels_of pr 11)" = "needs-review" ] || die "review-entry must label --branch Refs PR #11"

: >"$calls_log"
[ "$(run_lc review-entry --repo "$repo" --issue 42 --branch 42-feat)" = "0" ] ||
    die "repeated review-entry failed"
if grep -Eq "gh (issue|pr) edit" "$calls_log"; then
    die "idempotent review-entry repeat should not issue gh issue/pr edit"
fi

# Scoped review-clear on PR #11 retains issue needs-review while PR #10 still owes review
[ "$(run_lc review-clear --repo "$repo" --issue 42 --pr 11 --branch 42-feat)" = "0" ] ||
    die "scoped review-clear failed: $(cat "$tmp/stderr")"
grep -Fxq "NEEDS-REVIEW-RETAINED" "$tmp/stdout" ||
    die "scoped review-clear must emit NEEDS-REVIEW-RETAINED when sibling PR #10 still carries needs-review"
[ "$(labels_of pr 11)" = "" ] || die "PR #11 needs-review should be cleared"
[ "$(labels_of pr 10)" = "needs-review" ] || die "sibling PR #10 needs-review must remain"
[ "$(labels_of issue 42)" = "claim:claude,feature,needs-review,slated" ] ||
    die "issue #42 needs-review must be retained while PR #10 owes review"

# fix-round on PR #11 while sibling PR #10 still owes review must fail non-zero
[ "$(run_lc fix-round --repo "$repo" --issue 42 --pr 11 --branch 42-feat)" != "0" ] ||
    die "fix-round must fail when NEEDS-REVIEW-RETAINED applies"

# Unscoped review-clear clears all discoverable open delivery PRs and the issue
[ "$(run_lc review-clear --repo "$repo" --issue 42 --branch 42-feat)" = "0" ] ||
    die "unscoped review-clear failed: $(cat "$tmp/stderr")"
[ "$(labels_of pr 10)" = "" ] || die "PR #10 needs-review should be cleared"
[ "$(labels_of pr 11)" = "" ] || die "PR #11 needs-review should be cleared"
[ "$(labels_of issue 42)" = "claim:claude,feature,slated" ] ||
    die "issue #42 needs-review should be cleared (got $(labels_of issue 42))"
[ "$(run_lc review-clear --repo "$repo" --issue 42 --branch 42-feat)" = "0" ] ||
    die "repeated review-clear must be idempotent"

# Re-enter review and run fix-round with live claim
[ "$(run_lc review-entry --repo "$repo" --issue 42 --branch 42-feat)" = "0" ] || die "re-entry failed"
set_pr_field 10 labels '[{"name":"needs-review"}]'
set_pr_field 11 labels '[{"name":"needs-review"}]'
# Clear #10 first so branch-scoped fix-round on 42-feat has no review-owing sibling on another branch
[ "$(run_lc review-clear --repo "$repo" --issue 42 --pr 10)" = "0" ] || die "prep clear #10 failed"
[ "$(run_lc fix-round --repo "$repo" --issue 42 --branch 42-feat)" = "0" ] ||
    die "fix-round with live claim failed: $(cat "$tmp/stderr")"
[ "$(labels_of issue 42)" = "claim:claude,feature,slated" ] ||
    die "fix-round must preserve claim:claude and clear needs-review (got $(labels_of issue 42))"
[ "$(labels_of pr 11)" = "" ] || die "fix-round must clear PR #11 needs-review"
[ "$(run_lc fix-round --repo "$repo" --issue 42 --branch 42-feat)" = "0" ] ||
    die "repeated fix-round must be idempotent"
ok "review-entry, review-clear (sibling-retained and full), and fix-round"

echo "==> lifecycle-labels: park and unpark"
[ "$(run_lc review-entry --repo "$repo" --issue 42 --branch 42-feat)" = "0" ] || die "prep review-entry failed"
set_pr_field 11 isDraft 'false'
[ "$(run_lc park --repo "$repo" --issue 42 --branch 42-feat)" != "0" ] ||
    die "park must refuse non-draft PR"
set_pr_field 11 isDraft 'true'

[ "$(run_lc park --repo "$repo" --issue 42 --branch 42-feat)" = "0" ] ||
    die "park failed: $(cat "$tmp/stderr")"
[ "$(labels_of issue 42)" = "feature,parked,slated" ] ||
    die "park must release claim:claude, clear needs-review, keep slated, and add parked (got $(labels_of issue 42))"
[ "$(labels_of pr 10)" = "parked" ] || die "park must set parked on PR #10 (got $(labels_of pr 10))"
[ "$(labels_of pr 11)" = "parked" ] || die "park must set parked on PR #11 (got $(labels_of pr 11))"

[ "$(run_lc park --repo "$repo" --issue 42 --branch 42-feat)" = "0" ] ||
    die "repeated park must be idempotent: $(cat "$tmp/stderr")"
[ "$(labels_of issue 42)" = "feature,parked,slated" ] || die "park repeat drifted issue labels"

[ "$(run_lc unpark --repo "$repo" --issue 42 --branch 42-feat)" = "0" ] ||
    die "unpark failed: $(cat "$tmp/stderr")"
[ "$(labels_of issue 42)" = "feature,slated" ] || die "unpark must remove parked on issue #42"
[ "$(labels_of pr 10)" = "" ] || die "unpark must remove parked on PR #10"
[ "$(labels_of pr 11)" = "" ] || die "unpark must remove parked on PR #11"
[ "$(run_lc unpark --repo "$repo" --issue 42 --branch 42-feat)" = "0" ] ||
    die "repeated unpark must be idempotent"
ok "park releases claim via release-claim.sh, enforces coexistence, and unpark clears cleanly"

echo "==> lifecycle-labels: promote requires passing current-head live-check result"
[ "$(run_lc park --repo "$repo" --issue 42 --branch 42-feat)" = "0" ] || die "re-park failed"

# Missing --check-result
[ "$(run_lc promote --repo "$repo" --issue 42 --branch 42-feat)" = "2" ] ||
    die "promote without --check-result must exit 2"

# Failing check result
bad_gate="$tmp/gate-fail.json"
printf '{"status":"fail","condition":"ready","head":"%s","fingerprint":"fp-1"}\n' "$head_sha" >"$bad_gate"
[ "$(run_lc promote --repo "$repo" --issue 42 --branch 42-feat --check-result "$bad_gate")" = "1" ] ||
    die "promote with failing check result must exit 1"
[ "$(labels_of issue 42)" = "feature,parked,slated" ] ||
    die "refused promote must not mutate issue labels"

# Stale head check result
stale_gate="$tmp/gate-stale.json"
printf '{"status":"pass","condition":"ready","head":"%s","fingerprint":"fp-1"}\n' "$stale_sha" >"$stale_gate"
set_pr_field 10 isDraft 'false'
set_pr_field 11 isDraft 'false'
[ "$(run_lc promote --repo "$repo" --issue 42 --branch 42-feat --check-result "$stale_gate")" = "1" ] ||
    die "promote with stale-head check result must exit 1"
[ "$(labels_of pr 11)" = "parked" ] || die "stale-head promote must not mutate PR #11"

# Valid check result while PR is still draft -> refused
good_gate="$tmp/gate-pass.json"
printf '{"status":"pass","condition":"ready","head":"%s","fingerprint":"fp-1"}\n' "$head_sha" >"$good_gate"
set_pr_field 10 isDraft 'true'
[ "$(run_lc promote --repo "$repo" --issue 42 --branch 42-feat --check-result "$good_gate")" = "1" ] ||
    die "promote on draft PR must exit 1"

# Promoted non-draft PRs at current head + passing live check -> adds merge-ready
set_pr_field 10 isDraft 'false'
set_pr_field 11 isDraft 'false'
[ "$(run_lc promote --repo "$repo" --issue 42 --branch 42-feat --check-result "$good_gate" --head "$head_sha")" = "0" ] ||
    die "promote with valid current-head check failed: $(cat "$tmp/stderr")"
[ "$(labels_of issue 42)" = "feature,merge-ready,slated" ] ||
    die "promote must replace parked with merge-ready on issue #42 (got $(labels_of issue 42))"
[ "$(labels_of pr 10)" = "merge-ready" ] || die "promote must set merge-ready on PR #10"
[ "$(labels_of pr 11)" = "merge-ready" ] || die "promote must set merge-ready on PR #11"

[ "$(run_lc promote --repo "$repo" --issue 42 --branch 42-feat --check-result "$good_gate")" = "0" ] ||
    die "repeated promote must be idempotent: $(cat "$tmp/stderr")"

# unpromote removes merge-ready cleanly
[ "$(run_lc unpromote --repo "$repo" --issue 42 --branch 42-feat)" = "0" ] ||
    die "unpromote failed: $(cat "$tmp/stderr")"
[ "$(labels_of issue 42)" = "feature,slated" ] || die "unpromote must remove merge-ready on issue #42"
[ "$(labels_of pr 10)" = "" ] || die "unpromote must remove merge-ready on PR #10"
[ "$(labels_of pr 11)" = "" ] || die "unpromote must remove merge-ready on PR #11"
[ "$(run_lc unpromote --repo "$repo" --issue 42 --branch 42-feat)" = "0" ] ||
    die "repeated unpromote must be idempotent"
ok "promote enforces live-check + non-draft current head, and unpromote clears merge-ready"

echo "==> lifecycle-labels: resume, block, unblock, and terminal close"
# Resume refuses while PRs are still non-draft
claim_rec2="$tmp/claim-2.md"
write_claim_record "$claim_rec2" "yes" "claim:claude"
[ "$(run_lc resume --repo "$repo" --issue 42 --branch 42-feat \
    --record-file "$claim_rec2" --claim-label claim:claude \
    --family claude --runtime-environment coder --registry-snapshot "$registry_file")" = "1" ] ||
    die "resume must refuse non-draft PRs"

# Return PRs to draft and put stale parked/merge-ready to prove resume clears both and restores claim
set_pr_field 10 isDraft 'true'
set_pr_field 11 isDraft 'true'
set_pr_field 10 labels '[{"name":"parked"}]'
set_pr_field 11 labels '[{"name":"merge-ready"}]'
[ "$(run_lc resume --repo "$repo" --issue 42 --branch 42-feat \
    --record-file "$claim_rec2" --claim-label claim:claude \
    --family claude --runtime-environment coder --registry-snapshot "$registry_file")" = "0" ] ||
    die "resume failed: $(cat "$tmp/stderr")"
[ "$(labels_of issue 42)" = "claim:claude,feature,slated" ] ||
    die "resume must restore claim:claude on issue #42 (got $(labels_of issue 42))"
[ "$(labels_of pr 10)" = "" ] || die "resume must clear parked on PR #10"
[ "$(labels_of pr 11)" = "" ] || die "resume must clear merge-ready on PR #11"
[ "$(run_lc resume --repo "$repo" --issue 42 --branch 42-feat)" = "0" ] ||
    die "repeated resume with live claim must be idempotent"

# block and unblock across issue + open delivery PRs
[ "$(run_lc block --repo "$repo" --issue 42 --branch 42-feat)" = "0" ] ||
    die "block failed: $(cat "$tmp/stderr")"
[ "$(labels_of issue 42)" = "blocked,claim:claude,feature,slated" ] ||
    die "block must add blocked on issue #42 (got $(labels_of issue 42))"
[ "$(labels_of pr 10)" = "blocked" ] || die "block must add blocked on PR #10"
[ "$(labels_of pr 11)" = "blocked" ] || die "block must add blocked on PR #11"
[ "$(run_lc block --repo "$repo" --issue 42 --branch 42-feat)" = "0" ] ||
    die "repeated block must be idempotent"

[ "$(run_lc unblock --repo "$repo" --issue 42 --branch 42-feat)" = "0" ] ||
    die "unblock failed: $(cat "$tmp/stderr")"
[ "$(labels_of issue 42)" = "claim:claude,feature,slated" ] || die "unblock must clear blocked on issue #42"
[ "$(labels_of pr 10)" = "" ] || die "unblock must clear blocked on PR #10"
[ "$(labels_of pr 11)" = "" ] || die "unblock must clear blocked on PR #11"
[ "$(run_lc unblock --repo "$repo" --issue 42 --branch 42-feat)" = "0" ] ||
    die "repeated unblock must be idempotent"

# Terminal close also cleans stale merge-ready off a merged closing-linked PR (#1951 omator#2462 regression)
set_pr_field 10 state '"MERGED"'
set_pr_field 10 labels '[{"name":"merge-ready"}]'
set_pr_field 11 labels '[{"name":"needs-review"},{"name":"blocked"}]'
[ "$(run_lc close --repo "$repo" --issue 42 --branch 42-feat)" = "0" ] ||
    die "close failed: $(cat "$tmp/stderr")"
[ "$(labels_of issue 42)" = "feature,slated" ] ||
    die "close must clear claim and lifecycle state labels while preserving slated/feature (got $(labels_of issue 42))"
[ "$(labels_of pr 10)" = "" ] || die "close must clear stale merge-ready from merged closing-linked PR #10"
[ "$(labels_of pr 11)" = "" ] || die "close must clear lifecycle state labels from open PR #11"
[ "$(run_lc close --repo "$repo" --issue 42 --branch 42-feat)" = "0" ] ||
    die "repeated close must be idempotent: $(cat "$tmp/stderr")"
ok "resume, block, unblock, and terminal close (including merged closing-linked PR cleanup)"

echo "==> lifecycle-labels: non-sticking writes fail closed naming object and label"
init_fixture
set_pr_field 10 labels '[]'
set_pr_field 11 labels '[]'
python3 - "$state_file" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    state = json.load(fh)
state["issues"]["42"]["labels"] = [{"name": "feature"}]
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    json.dump(state, fh, indent=2)
PY

# Silently non-sticking add on PR #11
[ "$(MOCK_NO_STICK="add:pr:11:parked" run_lc park --repo "$repo" --issue 42 --branch 42-feat)" = "1" ] ||
    die "non-sticking PR add must exit 1"
grep -Fq "pr #11" "$tmp/stderr" || die "stderr must name 'pr #11' (got: $(cat "$tmp/stderr"))"
grep -Fq "parked" "$tmp/stderr" || die "stderr must name 'parked' (got: $(cat "$tmp/stderr"))"

# Silently non-sticking add on issue #42
[ "$(MOCK_NO_STICK="add:issue:42:needs-review" run_lc review-entry --repo "$repo" --issue 42 --branch 42-feat)" = "1" ] ||
    die "non-sticking issue add must exit 1"
grep -Fq "issue #42" "$tmp/stderr" || die "stderr must name 'issue #42' (got: $(cat "$tmp/stderr"))"
grep -Fq "needs-review" "$tmp/stderr" || die "stderr must name 'needs-review' (got: $(cat "$tmp/stderr"))"

# Silently non-sticking remove on PR #10
set_pr_field 10 labels '[{"name":"merge-ready"}]'
[ "$(MOCK_NO_STICK="remove:pr:10:merge-ready" run_lc unpromote --repo "$repo" --issue 42 --branch 42-feat)" = "1" ] ||
    die "non-sticking PR remove must exit 1"
grep -Fq "pr #10" "$tmp/stderr" || die "stderr must name 'pr #10' (got: $(cat "$tmp/stderr"))"
grep -Fq "merge-ready" "$tmp/stderr" || die "stderr must name 'merge-ready' (got: $(cat "$tmp/stderr"))"

# Direct gh edit failure also names object and label
[ "$(MOCK_FAIL_EDIT="add:pr:10:blocked" run_lc block --repo "$repo" --issue 42 --branch 42-feat)" = "1" ] ||
    die "direct gh edit failure must exit 1"
grep -Fq "pr #10" "$tmp/stderr" || die "stderr must name 'pr #10'"
grep -Fq "blocked" "$tmp/stderr" || die "stderr must name 'blocked'"

# Unprovisioned label fails closed naming object and label without creating labels
python3 - "$state_file" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    state = json.load(fh)
state["repo_labels"] = ["feature"]
state["issues"]["42"]["labels"] = [{"name": "feature"}]
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    json.dump(state, fh, indent=2)
PY
set_pr_field 10 labels '[]'
set_pr_field 11 labels '[]'
: >"$calls_log"
[ "$(run_lc block --repo "$repo" --issue 42 --branch 42-feat)" = "1" ] ||
    die "unprovisioned label must exit 1"
grep -Fq "issue #42" "$tmp/stderr" || die "unprovisioned stderr must name 'issue #42'"
grep -Fq "blocked" "$tmp/stderr" || die "unprovisioned stderr must name 'blocked'"
if grep -Eq "gh (issue|pr) edit" "$calls_log"; then
    die "unprovisioned label preflight must fail before any gh issue/pr edit"
fi
ok "non-sticking, failing, and unprovisioned writes exit non-zero naming object and label"

printf 'lifecycle-labels tests: %d passed\n' "$pass"
