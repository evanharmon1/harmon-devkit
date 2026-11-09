#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$ROOT" <<'PY'
import json
import re
import sys
import tempfile
from pathlib import Path

root = Path(sys.argv[1])
classes = {
    "agent-apply",
    "agent-apply-with-fleet-approval",
    "human-only",
    "unknown-when-unprivileged",
}
catalog_path = root / "checklist-classes.json"
catalog = json.loads(catalog_path.read_text())
assert catalog.get("schema_version") == 1, "unsupported checklist catalog schema"
assert set(catalog.get("classes", [])) == classes, "catalog class vocabulary differs"
entries = catalog.get("entries")
assert isinstance(entries, list) and entries, "catalog entries must be a non-empty array"
by_source = {}
ids = set()
def safe_probe(probe):
    return bool(re.match(r"^(Read|Inspect)\b", probe)) and not re.search(
        r"(?:[;`$|&<>]|\b(?:task\s+(?:setup|install|fix|sync|release|verify)\b|(?:POST|PATCH|PUT|DELETE)\b|(?:install|delete|create|modify|update|write|remove|enable|disable|execute|run|set|edit|apply|push|exec|mutate)\b|(?:curl|wget|python|python3|node|perl|touch|rm|mv|cp|chmod|chown|tee)\s|git\s+(?:add|commit|push|reset|clean|checkout|switch|merge|rebase)\b)|-X\s*(?:POST|PATCH|PUT|DELETE))",
        probe, re.I)

for entry in entries:
    required = {"id", "source", "section", "label", "class", "probe", "write_task"}
    assert required <= entry.keys(), f"catalog entry lacks fields: {entry}"
    assert isinstance(entry["id"], str) and entry["id"], "entry id must be non-empty"
    assert entry["id"] not in ids, f"duplicate catalog id: {entry['id']}"
    ids.add(entry["id"])
    assert entry["source"] in {"template", "root"}, f"invalid source for {entry['id']}"
    assert entry["class"] in classes, f"invalid class for {entry['id']}"
    probe = entry["probe"]
    if probe is None:
        assert entry["class"] == "human-only", f"missing probe for {entry['id']}"
    else:
        assert isinstance(probe, str) and probe.strip(), f"missing probe for {entry['id']}"
        assert safe_probe(probe), f"potentially mutating probe for {entry['id']}"
    assert entry["write_task"] is None or re.fullmatch(r"task [\w:-]+", entry["write_task"]), f"invalid write task for {entry['id']}"
    by_source.setdefault(entry["source"], {})[entry["id"]] = entry

def is_item(line):
    return re.match(r"^- \[[ xX]\]", line) is not None

def validate(path, source, subset=False):
    text = path.read_text()
    rows = [line for line in text.splitlines() if is_item(line)]
    assert rows, f"{path}: no checklist items found"
    expected = by_source[source]
    found = set()
    section = None
    for line_no, line in enumerate(text.splitlines(), 1):
        heading = re.match(r"^## (.+?)\s*$", line)
        if heading:
            section = heading.group(1)
        if not is_item(line):
            continue
        match = re.search(r"<!-- reconcile-id: ([a-z0-9-]+) -->", line)
        assert match, f"{path}:{line_no}: checklist item has no catalog id"
        item_id = match.group(1)
        assert item_id in expected, f"{path}:{line_no}: no matching catalog entry for {item_id}"
        assert item_id not in found, f"{path}:{line_no}: duplicate item id {item_id}"
        found.add(item_id)
        entry = expected[item_id]
        assert section == entry["section"], f"{path}:{line_no}: section differs from catalog"
        label = entry["label"]
        if subset:
            label = re.split(r"\[\[|\[%", label, maxsplit=1)[0].rstrip()
        assert label and line[match.end():].strip().startswith(label), f"{path}:{line_no}: label differs from catalog"
        item_class = re.findall(r"\[(agent-apply(?:-with-fleet-approval)?|human-only|unknown-when-unprivileged)\]", line)
        assert item_class == [entry["class"]], f"{path}:{line_no}: missing, invalid, or multiple class tags"
        probe = entry["probe"]
        expected_probe = f"Probe: {probe}" if probe is not None else "Probe: none."
        assert expected_probe in line, f"{path}:{line_no}: probe missing or differs from catalog"
        write = entry["write_task"]
        expected_write = f"Write: `{write}`." if write else "Write: none."
        assert expected_write in line, f"{path}:{line_no}: write task missing or differs from catalog"
    assert subset or found == set(expected), f"{path}: catalog/document item mismatch; missing={sorted(set(expected)-found)}, extra={sorted(found-set(expected))}"

template = root / "template/docs/CHECKLIST.md.jinja"
if template.exists():
    validate(root / "docs/CHECKLIST.md", "root")
    validate(template, "template")
    assert (root / "template/checklist-classes.json").read_bytes() == catalog_path.read_bytes(), "template catalog is not a verbatim twin"
else:
    validate(root / "docs/CHECKLIST.md", "template", subset=True)
# Exercise the same validator with realistic single-item fixtures.
source = "root" if template.exists() else "template"
original = (root / "docs/CHECKLIST.md").read_text().splitlines()
line = next(line for line in original if is_item(line))
item_id = re.search(r"<!-- reconcile-id: ([a-z0-9-]+) -->", line).group(1)
entry = by_source[source][item_id]
with tempfile.TemporaryDirectory(prefix="checklist-classes-") as tmp:
    fixture = Path(tmp) / "CHECKLIST.md"
    checked_lines = []
    for doc_line in original:
        if is_item(doc_line):
            mark = "x" if len(checked_lines) % 2 else "X"
            doc_line = re.sub(r"^- \[[ xX]\]", f"- [{mark}]", doc_line, count=1)
        checked_lines.append(doc_line)
    fixture.write_text("\n".join(checked_lines) + "\n")
    validate(fixture, source, subset=True)
    def check(test_line, section):
        fixture.write_text("## " + section + "\n\n" + test_line + "\n")
        validate(fixture, source, subset=True)
    check(line, entry["section"])
    for mark in (" ", "x", "X"):
        checked = re.sub(r"^- \[[ xX]\]", f"- [{mark}]", line, count=1)
        check(checked, entry["section"])
        try:
            check(checked.replace("[" + entry["class"] + "]", "[invalid]", 1), entry["section"])
        except AssertionError:
            pass
        else:
            raise AssertionError("checked item with invalid class passed")
    for test_line, section in [
        (line.replace("[" + entry["class"] + "]", "[invalid]", 1), entry["section"]),
        (line.replace(entry["label"].split("[%")[0].strip(), "wrong label", 1), entry["section"]),
        (line, "wrong section"),
        (line.replace(entry["probe"], "", 1), entry["section"]),
    ]:
        try:
            check(test_line, section)
        except AssertionError:
            pass
        else:
            raise AssertionError("invalid checklist fixture passed")
for probe in ("Read state; gh api -X POST /repos/x", "Read state with task setup:github", "Read state with curl -XPOST example"):
    assert not safe_probe(probe), f"mutating probe accepted: {probe}"
print("checklist classes: catalog, checklist metadata, and negative fixtures valid")
PY
