#!/usr/bin/env bash
# Exercise the probe through go-task with offline audit and GitHub fixtures.
set -euo pipefail
asset_dir="$(cd "$(dirname "$0")" && pwd)"
python3 -B - "$asset_dir" <<'PY'
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ASSETS = Path(sys.argv.pop())
spec = importlib.util.spec_from_file_location("fleet_report", ASSETS / "fleet-report.py")
report = importlib.util.module_from_spec(spec)
spec.loader.exec_module(report)

GITHUB = r"""#!/usr/bin/env python3
import os, sys
from pathlib import Path

args = sys.argv[1:]
with Path("gh-calls").open("a") as calls:
    calls.write(repr(args) + "\n")
if (args[:2] in (["issue", "edit"], ["issue", "create"])
    or any(arg.startswith(("-f", "-F")) or arg.startswith(("--field", "--raw-field")) for arg in args)
    or any(arg in ("-X", "--method") and args[index + 1:index + 2] != ["GET"]
           for index, arg in enumerate(args))
    or any(arg.startswith(("-X", "--method=")) and arg not in ("-X", "-XGET", "--method=GET")
           for arg in args)):
    Path("write-attempt").touch()
    sys.exit(99)
if os.environ.get("TEST_NO_GH_CREDENTIAL"):
    print("gh: no credential", file=sys.stderr)
    sys.exit(1)
if args != ["api", "--method", "GET", "repos/example/repo"]:
    sys.exit(98)
print("{}")
"""

TASKFILE = """version: '3'
tasks:
  audit:github:
    interactive: true
    cmds:
      - sh ./audit-github {{.CLI_ARGS}}
"""

AUDIT = """for arg in "$@"; do
    if [ "$arg" = --issue ]; then
        touch write-attempt
        exit 99
    fi
done
gh api --method GET repos/example/repo >/dev/null || exit 2
cat audit.ndjson
exit "${TEST_AUDIT_STATUS:-0}"
"""


class ReconcileProbe(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name)
        self.checkout = self.root / "checkout with spaces"
        self.checkout.mkdir()
        self.env = os.environ | {"PATH": f"{self.checkout}:{os.environ['PATH']}"}
        self.taskfile = self.write("Taskfile.yml", TASKFILE)
        self.write("audit-github", AUDIT)
        self.write("gh", GITHUB).chmod(0o755)
        self.entries = [
            dict(id="ok", label="Wait for the App", **{"class": "human-only"}, write_task=None),
            dict(id="drift", label="Reconcile labels", **{"class": "agent-apply"}, write_task="task setup:github-labels"),
            dict(id="manual", label="Check app setup", **{"class": "human-only"}, write_task=None),
            dict(id="unknown", label="Check access", **{"class": "unknown-when-unprivileged"}, write_task=None),
            dict(id="human-drift", label="Finish setup", **{"class": "human-only"}, write_task="task install"),
        ]
        self.write("checklist-classes.json", json.dumps({"schema_version": 1, "entries": self.entries}))
        (self.checkout / "docs").mkdir()
        self.write("docs/CHECKLIST.md", "".join(f"<!-- reconcile-id: {entry['id']} -->\n" for entry in self.entries))
        self.audit_rows(("pass", "fail", "manual", "unknown", "fail"))

    def write(self, name, text):
        path = self.checkout / name
        path.write_text(text)
        return path

    def audit_rows(self, results):
        rows = (entry | {"result": result, "reason": f"evidence for {entry['id']}"}
                for entry, result in zip(self.entries, results))
        self.write("audit.ndjson", "".join(json.dumps(row) + "\n" for row in rows))

    def run_probe(self, **env):
        result = subprocess.run([ASSETS / "reconcile-probe.sh", self.checkout],
                                cwd=self.root, env=self.env | env,
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        rows = json.loads(result.stdout)
        data = {
            "version": 1,
            "run": {"release": "v1.0.0", "epic": {"repo": "example/repo", "number": 1}},
            "repositories": [{
                "repository": "example/repo", "wave": 1, "state": "working",
                "tracking_issue": {"repo": "example/repo", "number": 2},
                "reconcile": rows,
            }],
        }
        report.validate(data)
        return {row["item"]: row for row in rows}, result.stderr

    def test_maps_rows_and_read_only_command(self):
        rows, _ = self.run_probe(TEST_AUDIT_STATUS="2")
        self.assertEqual(set(rows), {item["id"] for item in self.entries} | {"audit:github"})
        for entry in self.entries:
            self.assertEqual(rows[entry["id"]]["class"], entry["class"])
        for item, status, action in [
            ("ok", "pass", "none"), ("drift", "fail", "pending"),
            ("manual", "manual", "none"), ("unknown", "unknown", "none"),
            ("human-drift", "fail", "pending"),
        ]:
            with self.subTest(item=item):
                self.assertEqual(rows[item]["probe"], f"{status}: evidence for {item}")
                self.assertEqual(rows[item]["action"], action)
        self.assertEqual(rows["manual"]["task"], "Check app setup")
        self.assertEqual(rows["human-drift"]["task"], "task install")
        self.assertIn("exit 2", rows["audit:github"]["probe"])
        self.assertEqual((self.checkout / "gh-calls").read_text().splitlines(),
                         ["['api', '--method', 'GET', 'repos/example/repo']"])
        self.assertFalse((self.checkout / "write-attempt").exists())

    def test_status_with_incomplete_evidence(self):
        for env, expected in [
            ({"TEST_NO_GH_CREDENTIAL": "1"}, "unknown:"),
            ({"TEST_AUDIT_STATUS": "7"}, "unknown:"),
        ]:
            with self.subTest(env=env):
                rows, _ = self.run_probe(**env)
                self.assertEqual(set(rows), {"audit:github"})
                self.assertTrue(rows["audit:github"]["probe"].startswith(expected))
        self.audit_rows(("pass",))
        rows, _ = self.run_probe(TEST_AUDIT_STATUS="2")
        self.assertTrue(rows["audit:github"]["probe"].startswith("unknown:"))
        self.assertTrue(rows["ok"]["probe"].startswith("pass:"))
        self.write("audit.ndjson", "")
        rows, _ = self.run_probe()
        self.assertTrue(rows["audit:github"]["probe"].startswith("unknown:"))

    def test_missing_task_does_not_run_other_tasks(self):
        self.taskfile.write_text("version: '3'\ntasks:\n  default:\n    cmds: ['touch unexpected']\n")
        rows, _ = self.run_probe()
        self.assertTrue(rows["audit:github"]["probe"].startswith("not run:"))
        self.assertFalse((self.checkout / "unexpected").exists())
        self.assertFalse((self.checkout / "gh-calls").exists())

    def test_missing_catalog_does_not_run_the_audit(self):
        (self.checkout / "checklist-classes.json").unlink()
        self.write("audit-github", "touch unexpected\n")
        rows, _ = self.run_probe()
        self.assertEqual(rows["audit:github"]["probe"], "unknown: target has no checklist-classes.json")
        self.assertFalse((self.checkout / "unexpected").exists())

    def test_crash_after_some_results_is_unknown(self):
        self.write("audit-github", "cat audit.ndjson\npython3 -c 'raise IndexError(\"fixture crash\")'\n")
        for results in (("pass",), ("pass", "fail")):
            with self.subTest(results=results):
                self.audit_rows(results)
                rows, _ = self.run_probe()
                self.assertEqual(rows["ok"]["probe"], "pass: evidence for ok")
                self.assertEqual(
                    rows["audit:github"]["probe"],
                    "unknown: audit exited 1 with incomplete or inconsistent output (possible crash)",
                )

    def test_exit_one_requires_drift_and_the_complete_rendered_checklist(self):
        # The active checklist can omit catalog entries for other profiles.
        rendered = self.checkout / "docs/CHECKLIST.md"
        rendered.write_text("<!-- reconcile-id: ok -->\n<!-- reconcile-id: drift -->\n")
        self.audit_rows(("pass", "fail"))
        rows, _ = self.run_probe(TEST_AUDIT_STATUS="1")
        self.assertEqual(set(rows), {"ok", "drift"})
        self.audit_rows(("pass", "manual"))
        rows, _ = self.run_probe(TEST_AUDIT_STATUS="1")
        self.assertIn("possible crash", rows["audit:github"]["probe"])

    def test_inconsistent_input_is_unknown(self):
        for name, contents in [
            ("audit.ndjson", "{broken"),
            ("audit.ndjson", json.dumps(self.entries[0] | {"class": "agent-apply", "result": "pass", "reason": "mismatched"})),
            ("checklist-classes.json", "{}"),
        ]:
            with self.subTest(name=name, contents=contents):
                self.audit_rows(("pass",))
                self.write(name, contents)
                rows, _ = self.run_probe()
                self.assertEqual(set(rows), {"audit:github"})
                self.assertTrue(rows["audit:github"]["probe"].startswith("unknown:"))

    def test_ruleset_result_matches_status_and_marker(self):
        self.taskfile.write_text(TASKFILE + "  audit:ruleset:\n    cmds: ['sh ./audit-ruleset']\n")
        for status, marker, expected in [
            (0, "CLEAN", "clean:"), (1, "DRIFT", "drift:"),
            (2, "UNAVAILABLE", "unknown:"), (0, "UNAVAILABLE", "unknown:"),
        ]:
            with self.subTest(status=status, marker=marker):
                self.write("audit-ruleset", f"echo 'RULESET AUDIT {marker}: Protect Main'\nexit {status}\n")
                rows, stderr = self.run_probe()
                self.assertEqual(rows["audit:ruleset"]["action"], "none")
                self.assertTrue(rows["audit:ruleset"]["probe"].startswith(expected))
                self.assertIn(f"RULESET AUDIT {marker}: Protect Main", stderr)


unittest.main()
PY
