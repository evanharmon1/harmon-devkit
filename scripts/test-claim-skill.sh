#!/usr/bin/env bash
# Contract and fixture tests for the /claim skill's validity challenge
# (harmon-devkit#1896). Offline and deterministic; run via `task test:claim-skill`.
#
# What this can and cannot prove. It pins the SKILL.md CONTRACT — the
# explore-then-assess ordering, the closed recommendation set and what each
# one lets a claim do, the record layout the claim parsers read — and it runs
# seven scenario fixtures through a mechanical assessment validator. A
# fixture is a tiny repository tree plus the assessment a claim should
# produce for it; the validator checks that every cited fact resolves in that
# tree, that every claim the issue relies on and the tree contradicts is
# answered, that the recommendation matches the strongest finding, and that
# proceed/ask/hold behavior follows the SKILL's own table. It does NOT judge
# reasoning quality: no model runs here, so these fixtures guard the shape an
# honest assessment must have, not whether a given model reaches it.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 -I - "$repo" <<'PYTEST'
import re
import sys
from pathlib import Path

repo = Path(sys.argv[1])
skill_path = repo / "ai/skills/universal/claim/SKILL.md"
skill = skill_path.read_text()
failures = []


def check(desc, cond):
    if cond:
        print(f"  ok - {desc}")
    else:
        print(f"  FAIL - {desc}")
        failures.append(desc)


def flat(text):
    return " ".join(text.split())


# ── Part A: the SKILL.md contract ───────────────────────────────────────
print("==> claim SKILL.md validity-challenge contract")

h2 = {m.group(1): m.start() for m in re.finditer(r"^## (\d)\. ", skill, re.M)}
vc = skill.find("### Validity challenge")
check("sections 2..6 and the validity challenge exist", len(h2) >= 6 and vc > 0)
check(
    "exploration precedes the assessment, which precedes the report and the claim writes",
    h2["2"] < vc < h2["4"] < h2["5"] < h2["6"],
)

sec2 = skill[h2["2"]:h2["3"]]
check(
    "section 2 orders read-only exploration before the assessment and before writes",
    "**Exploration comes first.**" in sec2
    and "never from the issue text alone" in flat(sec2)
    and "before §4's report, §5's claim writes and any implementation" in flat(sec2),
)

body = skill[vc:h2["4"]]
fb = flat(body)
for needle, desc in [
    ("fetched default branch", "explores against the fetched default branch"),
    ("every comment", "reads the issue comments"),
    ("recent merges", "reads related changes and recent merges"),
    ("those that would have to change", "reads the code and tests that would change"),
    ("`docs/decisions/`", "reads applicable design decisions"),
    ("no fixed research quota", "scales investigation without a research quota"),
    ("**The problem**", "assesses the problem's existence and evidence"),
    ("Current behavior versus the desired outcome", "compares current behavior with the desired outcome"),
    ("assumptions", "surfaces assumptions"),
    ("likely cause", "assesses the likely cause"),
    ("duplication, obsolescence", "checks duplication and obsolescence"),
    ("**Dependencies and canonical ownership**", "checks dependencies and canonical ownership"),
    ("**Feasibility and impact**", "assesses feasibility and impact"),
    ("**verified**", "distinguishes verified facts"),
    ("**inferred**", "distinguishes inference"),
    ("**unknown**", "distinguishes unknowns"),
    ("against **doing nothing**", "challenges the approach against doing nothing"),
    ("simpler alternative", "challenges the approach against a simpler alternative"),
    ("contradict each other", "looks for contradictory requirements"),
    ("tradeoffs the maintainer would not accept", "looks for unacceptable tradeoffs"),
    ("larger than one session and one PR", "looks for oversized scope"),
    ("criteria that can pass while the intended outcome still fails", "checks criteria can prove the outcome"),
    ("strongest material objection", "records the strongest objection even when proceeding"),
    ("only about an unresolved decision that materially changes scope, value or safety", "asks only focused, material questions"),
    ("no new approval prompt", "adds no ceremonial approval for routine work"),
    ("never silently rewrites", "never silently rewrites, closes or implements"),
    ("harmon-devkit#1120", "coordinates with #1120 instead of a parallel format"),
]:
    check(f"validity challenge: {desc}", flat(needle) in fb)

# The recommendation table is the SKILL's own behavior contract; the fixtures
# below read it rather than restating it, so editing it re-tests everything.
table = {}
for m in re.finditer(r"^\| `([a-z-]+)` \| .*? \| (Routine|Held)\b", body, re.M):
    table[m.group(1)] = m.group(2).lower()
RECS = ["proceed", "proceed-with-corrections", "split-or-reframe", "defer", "do-not-do"]
check("recommendation table has exactly the five recommendations", sorted(table) == sorted(RECS))
check(
    "proceed and proceed-with-corrections are routine; the other three hold the claim",
    table.get("proceed") == "routine"
    and table.get("proceed-with-corrections") == "routine"
    and all(table.get(r) == "held" for r in ("split-or-reframe", "defer", "do-not-do")),
)

pre = skill[: skill.find("## 1. Target")]
check(
    "invocation stays the approval for routine claim writes",
    "**invoking `/claim` is the approval for them**" in flat(pre),
)
check(
    "a split/reframe/defer/do-not-do recommendation is a fourth stopping escalation",
    "Four escalations still stop and ask" in flat(pre)
    and "split, reframe, defer or not do the work" in flat(pre),
)
sec5 = skill[h2["5"]:h2["6"]]
check(
    "claim writes are gated on the recommendation",
    "only after §3's validity challenge recommended `proceed` or `proceed-with-corrections`"
    in flat(sec5),
)

front = skill.split("---", 2)[1]
allowed = next(l for l in front.splitlines() if l.startswith("allowed-tools:"))
check(
    "allowed-tools stays read-only (no issue, git or PR write)",
    not re.search(r"gh issue (edit|comment|close|create)|gh pr (edit|comment|create|merge)|git (push|merge|commit|add)", allowed),
)

# The claim comment: validity lines sit in the preflight block ABOVE the
# parsed record, and the record's own field set is unchanged.
hd = re.search(r"<<'CLAIM_BODY_9f3k'\n(.*?)\n\s*CLAIM_BODY_9f3k\n", skill, re.S)
check("claim comment heredoc is present", hd is not None)
lines = [l.strip() for l in hd.group(1).splitlines()] if hd else []
anchor = "Claim record (for `/wrap` — undo only what this claim added):"
check("record starts with 'Claiming —' and has the exact record anchor",
      bool(lines) and lines[0].startswith("Claiming —") and anchor in lines)
if anchor in lines:
    i = lines.index(anchor)
    above, record = lines[:i], lines[i + 1:]
    vlines = [l for l in above if l.startswith("- validity ") or l.startswith("- strongest objection:") or l.startswith("- decision:")]
    check(
        "validity lines (recommendation, basis, objection, decision) are above the record",
        [l.split(":")[0] for l in vlines]
        == ["- validity recommendation", "- validity basis", "- strongest objection", "- decision"],
    )
    check(
        "validity lines are inside the Preflight (§3) block, so a verbatim copy-forward carries them",
        "Preflight (§3):" in above
        and above.index("Preflight (§3):") < above.index(vlines[0]),
    )
    fields = [re.match(r"(- .*?): <", l).group(1) for l in record if l.startswith("- ")]
    check(
        "the parsed record's field set is unchanged (no assessment fields inside it)",
        fields == [
            "- harness", "- model", "- family", "- runtime environment", "- session",
            "- dispatched to", "- assignee added by this claim",
            "- `claim:` label added by this claim", "- `claim:` model label added by this claim",
            "- `claim:` label displaced by this claim", "- assignee logins owned by this claim chain",
            "- `claim:` label owned by this claim chain", "- `claim:` model label owned by this claim chain",
            "- `claim:` label displaced by this claim chain",
        ],
    )
    rec_line = next((l for l in vlines if l.startswith("- validity recommendation")), "")
    listed = re.search(r"<([^>]*)>", rec_line)
    check(
        "the comment template offers exactly the table's recommendations",
        listed is not None
        and [x.strip() for x in listed.group(1).split("|")] == RECS,
    )
    # The helper rejects a record without these anchors; mirror its check.
    helper = (repo / "ai/skills/universal/claim/assets/claim-transaction.sh").read_text()
    check(
        "claim-transaction.sh still requires the same anchors the template provides",
        "record must start with 'Claiming —'" in helper
        and "Claim record (for `/wrap` — undo only what this claim added):$" in helper,
    )

# ── Part B: scenario fixtures and the assessment validator ──────────────
print("==> assessment validator and fixtures")

# severity of what a verified finding implies for the work, weakest first, and
# the recommendation each implies; the recommendation must equal the strongest.
IMPACT_ORDER = ["none", "correction", "reshape", "defer", "obsolete"]
IMPACT_REC = {
    "none": "proceed",
    "correction": "proceed-with-corrections",
    "reshape": "split-or-reframe",
    "defer": "defer",
    "obsolete": "do-not-do",
}
FORBIDDEN_ACTIONS = {"edit-issue", "close-issue", "comment-issue", "relabel-issue", "implement", "claim"}


def resolve(ref, fx):
    """Does an evidence reference hold in the fixture's tree/tracker?"""
    kind, _, rest = ref.partition(":")
    if kind in ("pr", "issue"):
        return ref in fx.get("tracker", {})
    path, _, needle = rest.partition("#")
    text = fx["tree"].get(path)
    if kind == "file":
        return text is not None and (needle == "" or needle in text)
    if kind == "absent":
        return text is not None and needle not in text
    return False


def validate(fx):
    """Return (errors, behavior) for one fixture's assessment."""
    errs = []
    a = fx["assessment"]
    rec = a.get("recommendation")
    if rec not in table:
        return [f"recommendation {rec!r} is outside the SKILL's set"], None

    findings = a.get("findings", [])
    by_id = {f["id"]: f for f in findings}
    for f in findings:
        label = f.get("label")
        if label not in ("verified", "inferred", "unknown"):
            errs.append(f"{f.get('id')}: conclusion is not labelled verified/inferred/unknown")
        elif label == "verified":
            if not f.get("evidence"):
                errs.append(f"{f['id']}: verified conclusion cites no evidence")
            for ref in f.get("evidence", []):
                if not resolve(ref, fx):
                    errs.append(f"{f['id']}: cited evidence does not resolve in the explored tree: {ref}")
        elif label == "inferred":
            srcs = f.get("from", [])
            if not srcs or not all(by_id.get(s, {}).get("label") == "verified" for s in srcs):
                errs.append(f"{f['id']}: inference does not rest on verified findings")
        elif label == "unknown" and not f.get("settles"):
            errs.append(f"{f['id']}: unknown does not say what would settle it")

    # Every fact the issue relies on that the tree contradicts must be
    # answered by a verified finding that covers it and moves the work.
    for claim in fx.get("claims", []):
        if resolve(claim, fx):
            continue
        covered = any(
            f.get("label") == "verified"
            and claim in f.get("covers", [])
            and IMPACT_ORDER.index(f.get("impact", "none")) >= IMPACT_ORDER.index("reshape")
            for f in findings
        )
        if not covered:
            errs.append(f"the tree contradicts the issue's claim {claim} and no verified finding answers it")

    strongest = max(
        (f.get("impact", "none") for f in findings if f.get("label") == "verified"),
        key=IMPACT_ORDER.index,
        default="none",
    )
    if IMPACT_REC[strongest] != rec:
        errs.append(f"recommendation {rec} does not match the strongest verified finding ({strongest} -> {IMPACT_REC[strongest]})")

    obj = a.get("objection") or {}
    if not obj.get("text"):
        errs.append("no strongest objection recorded")
    elif obj["text"].strip().lower().startswith("none") and not obj.get("checked"):
        errs.append("objection 'none' does not say what was checked")
    for ref in obj.get("evidence", []) + obj.get("checked", []):
        if not resolve(ref, fx):
            errs.append(f"objection evidence does not resolve: {ref}")

    held = table[rec] == "held"
    material_unknown = any(f.get("label") == "unknown" and f.get("material") for f in findings)
    questions = a.get("questions", [])
    if not held and not material_unknown and questions:
        errs.append("a routine validated issue is asked a ceremonial question")
    if (held or material_unknown) and not questions:
        errs.append("a held or materially unresolved assessment asks no focused question")
    for q in questions:
        if resolve(q.get("answerable_by", "none:"), fx):
            errs.append(f"question is answerable from the repository: {q['answerable_by']}")
    if held:
        bad = FORBIDDEN_ACTIONS & set(a.get("actions", []))
        if bad:
            errs.append(f"a held recommendation mutates or implements the issue: {sorted(bad)}")

    behavior = {"writes": "held" if held else "routine", "asks": bool(questions), "mutates_issue": bool(set(a.get("actions", [])) & FORBIDDEN_ACTIONS)}
    return errs, behavior


def fx_valid():
    return {
        "name": "valid issue",
        "tree": {"src/total.sh": "total() { echo $(( $1 + $2 - 1 )); }  # off by one\n", "tests/total.sh": "assert total 1 2 = 3\n"},
        "tracker": {},
        "claims": ["file:src/total.sh#- 1 ))"],
        "assessment": {
            "recommendation": "proceed",
            "findings": [
                {"id": "F1", "label": "verified", "impact": "none", "evidence": ["file:src/total.sh#- 1 ))", "file:tests/total.sh#assert total 1 2 = 3"]},
                {"id": "I1", "label": "inferred", "from": ["F1"]},
            ],
            "objection": {"text": "Low blast radius; the existing test already encodes the right answer.", "evidence": ["file:tests/total.sh#assert total 1 2 = 3"]},
            "questions": [],
            "actions": [],
        },
        "expect": {"recommendation": "proceed", "writes": "routine", "asks": False},
    }


def fx_false_diagnosis():
    return {
        "name": "false diagnosis",
        "tree": {"src/fetch.sh": "curl --max-time 5 \"$url\"\n", "src/queue.sh": "# workers share one lock file\nflock /tmp/q.lock\n"},
        "tracker": {},
        "claims": ["absent:src/fetch.sh#--max-time"],
        "assessment": {
            "recommendation": "split-or-reframe",
            "findings": [
                {"id": "F1", "label": "verified", "impact": "reshape", "covers": ["absent:src/fetch.sh#--max-time"], "evidence": ["file:src/fetch.sh#--max-time 5"]},
                {"id": "I1", "label": "inferred", "from": ["F1"]},
                {"id": "U1", "label": "unknown", "settles": "a reproduction of the hang against a live queue", "material": True},
            ],
            "objection": {"text": "Adding a timeout cannot fix a hang the code already bounds.", "evidence": ["file:src/fetch.sh#--max-time 5"]},
            "questions": [{"text": "Reframe around the shared lock in src/queue.sh, or close for lack of a reproduction?", "answerable_by": "none:"}],
            "actions": [],
        },
        "expect": {"recommendation": "split-or-reframe", "writes": "held", "asks": True},
    }


def fx_already_fixed():
    return {
        "name": "already fixed",
        "tree": {"src/round.sh": "round_cents() { printf '%.0f' \"$1\"; }  # fixed in #77\n"},
        "tracker": {"pr:77": "merged"},
        "claims": ["file:src/round.sh#floor("],
        "assessment": {
            "recommendation": "do-not-do",
            "findings": [
                {"id": "F1", "label": "verified", "impact": "obsolete", "covers": ["file:src/round.sh#floor("], "evidence": ["absent:src/round.sh#floor(", "pr:77"]},
            ],
            "objection": {"text": "The reporter may be on an old release; the code on the default branch is already correct.", "evidence": ["pr:77"]},
            "questions": [{"text": "Close as already fixed by #77, or keep open for the reporter's release?", "answerable_by": "none:"}],
            "actions": [],
        },
        "expect": {"recommendation": "do-not-do", "writes": "held", "asks": True},
    }


def fx_wrong_owner():
    return {
        "name": "wrong canonical owner",
        "tree": {"TEMPLATE-MANAGED": "scripts/lint.sh\ntaskfiles/ci.yml\n", "scripts/lint.sh": "# rendered from the template\n"},
        "tracker": {},
        "claims": ["absent:TEMPLATE-MANAGED#scripts/lint.sh"],
        "assessment": {
            "recommendation": "split-or-reframe",
            "findings": [
                {"id": "F1", "label": "verified", "impact": "reshape", "covers": ["absent:TEMPLATE-MANAGED#scripts/lint.sh"], "evidence": ["file:TEMPLATE-MANAGED#scripts/lint.sh"]},
                {"id": "U1", "label": "unknown", "settles": "whether the upstream template repo already has this fix"},
            ],
            "objection": {"text": "A local edit is reconciled away by the next template update.", "evidence": ["file:TEMPLATE-MANAGED#scripts/lint.sh"]},
            "questions": [{"text": "Move this issue to the template repository, or keep a deliberate local override?", "answerable_by": "none:"}],
            "actions": [],
        },
        "expect": {"recommendation": "split-or-reframe", "writes": "held", "asks": True},
    }


def fx_inferior_solution():
    return {
        "name": "inferior proposed solution",
        "tree": {"lib/retry.sh": "retry() { local n=$1; shift; until \"$@\" || [ $((n--)) -le 1 ]; do :; done; }\n", "src/sync.sh": "rsync \"$src\" \"$dst\"\n"},
        "tracker": {},
        "claims": ["file:src/sync.sh#rsync"],
        "assessment": {
            "recommendation": "proceed-with-corrections",
            "findings": [
                {"id": "F1", "label": "verified", "impact": "correction", "evidence": ["file:lib/retry.sh#retry()", "file:src/sync.sh#rsync"]},
                {"id": "I1", "label": "inferred", "from": ["F1"]},
            ],
            "objection": {"text": "A new retry helper duplicates lib/retry.sh; wrapping the call in the existing one is smaller.", "evidence": ["file:lib/retry.sh#retry()"]},
            "questions": [],
            "actions": [],
        },
        "expect": {"recommendation": "proceed-with-corrections", "writes": "routine", "asks": False},
    }


def fx_scope_change():
    areas = {f"src/{n}.sh": f"# {n} module, no shared code\n" for n in ("auth", "billing", "reports", "export", "notify")}
    return {
        "name": "substantial scope change",
        "tree": areas,
        "tracker": {},
        "claims": ["file:src/auth.sh#auth module"],
        "assessment": {
            "recommendation": "split-or-reframe",
            "findings": [
                {"id": "F1", "label": "verified", "impact": "reshape", "evidence": [f"file:{p}#no shared code" for p in areas]},
                {"id": "I1", "label": "inferred", "from": ["F1"]},
            ],
            "objection": {"text": "Five independent modules cannot land as one reviewable PR.", "evidence": ["file:src/billing.sh#no shared code"]},
            "questions": [{"text": "Which module first, or split into five issues under one parent?", "answerable_by": "none:"}],
            "actions": [],
        },
        "expect": {"recommendation": "split-or-reframe", "writes": "held", "asks": True},
    }


def fx_product_decision():
    return {
        "name": "unresolved product decision",
        "tree": {"docs/decisions/report-format.md": "Status: undecided — JSON vs CSV.\n", "src/report.sh": "emit_csv\n"},
        "tracker": {},
        "claims": ["file:src/report.sh#emit_csv"],
        "assessment": {
            "recommendation": "defer",
            "findings": [
                {"id": "F1", "label": "verified", "impact": "defer", "evidence": ["file:docs/decisions/report-format.md#undecided"]},
                {"id": "U1", "label": "unknown", "settles": "the maintainer's choice between JSON and CSV", "material": True},
            ],
            "objection": {"text": "Implementing either format pre-empts a decision the record says is open.", "evidence": ["file:docs/decisions/report-format.md#undecided"]},
            "questions": [{"text": "JSON or CSV as the report format?", "answerable_by": "file:docs/decisions/report-format.md#Status: decided"}],
            "actions": [],
        },
        "expect": {"recommendation": "defer", "writes": "held", "asks": True},
    }


FIXTURES = [fx_valid, fx_false_diagnosis, fx_already_fixed, fx_wrong_owner, fx_inferior_solution, fx_scope_change, fx_product_decision]

for make in FIXTURES:
    fx = make()
    errs, behavior = validate(fx)
    exp = fx["expect"]
    check(f"fixture '{fx['name']}': assessment is evidence-backed and consistent ({'; '.join(errs) or 'no errors'})", not errs)
    check(
        f"fixture '{fx['name']}': {exp['recommendation']} -> writes {exp['writes']}, asks={exp['asks']}, no issue mutation",
        behavior is not None
        and fx["assessment"]["recommendation"] == exp["recommendation"]
        and behavior["writes"] == exp["writes"]
        and behavior["asks"] == exp["asks"]
        and not behavior["mutates_issue"],
    )

# Autonomous progress on a valid issue vs a recommendation against unnecessary
# work: the two outcomes the issue's Verify section demands, side by side.
valid_b = validate(fx_valid())[1]
fixed_b = validate(fx_already_fixed())[1]
check("valid issue proceeds autonomously (routine writes, no question)", valid_b == {"writes": "routine", "asks": False, "mutates_issue": False})
check("already-fixed issue yields an evidence-backed hold with no issue mutation", fixed_b == {"writes": "held", "asks": True, "mutates_issue": False})

# Planted failures: every rule above must be able to fail.
print("==> planted failures (each must be rejected)")


def planted(desc, mutate, base=fx_valid, expect_fragment=None):
    fx = base()
    mutate(fx)
    errs, _ = validate(fx)
    check(f"rejects {desc}", bool(errs) and (expect_fragment is None or any(expect_fragment in e for e in errs)))


planted("evidence that does not resolve in the tree",
        lambda fx: fx["assessment"]["findings"][0]["evidence"].append("file:src/missing.sh#x"), expect_fragment="does not resolve")
planted("a verified finding with no evidence",
        lambda fx: fx["assessment"]["findings"][0].update(evidence=[]), expect_fragment="cites no evidence")
planted("an unlabelled conclusion",
        lambda fx: fx["assessment"]["findings"].append({"id": "X1", "text": "looks fine"}), expect_fragment="not labelled")
planted("an inference resting on nothing",
        lambda fx: fx["assessment"]["findings"][1].update({"from": []}), expect_fragment="does not rest on verified")
planted("an unknown with nothing to settle it",
        lambda fx: fx["assessment"]["findings"].append({"id": "U1", "label": "unknown"}), expect_fragment="what would settle")
planted("a recommendation outside the closed set",
        lambda fx: fx["assessment"].update(recommendation="maybe"), expect_fragment="outside the SKILL's set")
planted("a missing objection",
        lambda fx: fx["assessment"].update(objection={}), expect_fragment="no strongest objection")
planted("an objection of 'none' with nothing checked",
        lambda fx: fx["assessment"].update(objection={"text": "None."}), expect_fragment="what was checked")
planted("a ceremonial question on a routine issue",
        lambda fx: fx["assessment"].update(questions=[{"text": "Shall I proceed?", "answerable_by": "none:"}]), expect_fragment="ceremonial")
planted("a hold that asks nothing",
        lambda fx: fx["assessment"].update(questions=[]), base=fx_already_fixed, expect_fragment="asks no focused question")
planted("a question the repository already answers",
        lambda fx: fx["assessment"]["questions"][0].update(answerable_by="file:docs/decisions/report-format.md#undecided"),
        base=fx_product_decision, expect_fragment="answerable from the repository")
planted("proceeding past a contradicted claim",
        lambda fx: fx["assessment"].update(recommendation="proceed", questions=[]), base=fx_already_fixed, expect_fragment="strongest verified finding")
planted("a contradicted claim no finding answers",
        lambda fx: fx["assessment"]["findings"][0].update(covers=[]), base=fx_already_fixed, expect_fragment="no verified finding answers")
planted("a recommendation weaker than the strongest finding",
        lambda fx: fx["assessment"].update(recommendation="split-or-reframe"), base=fx_already_fixed, expect_fragment="strongest verified finding")
planted("a held recommendation that closes the issue",
        lambda fx: fx["assessment"].update(actions=["close-issue"]), base=fx_already_fixed, expect_fragment="mutates or implements")
planted("a held recommendation that implements anyway",
        lambda fx: fx["assessment"].update(actions=["implement"]), base=fx_scope_change, expect_fragment="mutates or implements")

if failures:
    print(f"TEST FAIL: {len(failures)} claim-skill check(s) failed", file=sys.stderr)
    sys.exit(1)
print("claim-skill tests passed")
PYTEST
