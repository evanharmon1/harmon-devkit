#!/usr/bin/env bash
# Run the target's read-only audits and emit the fleet report's reconcile array.
set -euo pipefail
exec python3 -B - "$@" <<'PY'
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

parser = argparse.ArgumentParser(description="Probe GitHub configuration in a target checkout")
parser.add_argument("checkout", nargs="?", type=Path, default=Path("."))
parser.add_argument("--ruleset-only", action="store_true", help="emit the applied-state verifier's ruleset advisory")
args = parser.parse_args()
if not args.checkout.is_dir():
    parser.error("target checkout is not a directory")
os.chdir(args.checkout)

TASKFILES = (
    "Taskfile.yml", "Taskfile.yaml", "taskfile.yml", "taskfile.yaml",
    "Taskfile.dist.yml", "Taskfile.dist.yaml", "taskfile.dist.yml", "taskfile.dist.yaml",
)
taskfile = next((name for name in TASKFILES if Path(name).is_file()), None)
task = shutil.which("task")


def run_task(*options, merge_output=False):
    return subprocess.run(
        [task, "--taskfile", taskfile, "--color=false", *options],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT if merge_output else subprocess.PIPE,
        text=True, errors="replace", check=False,
    )


def observation(item, probe):
    return {"item": item, "probe": probe, "action": "none", "class": "observation"}


def active_checklist_entries():
    catalog = json.loads(Path("checklist-classes.json").read_text(encoding="utf-8"))
    entries = catalog["entries"]
    if catalog["schema_version"] != 1 or not isinstance(entries, list) or not entries:
        raise ValueError("unsupported or empty checklist catalog")
    by_id = {entry["id"]: entry for entry in entries}
    if len(by_id) != len(entries) or by_id.keys() & {"audit:github", "audit:ruleset"}:
        raise ValueError("duplicate or reserved catalog ID")

    # The target audit's default mode selects the rendered checklist IDs.
    checklist = Path("docs/CHECKLIST.md").read_text(encoding="utf-8")
    active_ids = set(re.findall(r"<!-- reconcile-id: ([a-z0-9-]+) -->", checklist))
    if not active_ids or active_ids - by_id.keys():
        raise ValueError("checklist IDs missing from catalog")
    return {item: by_id[item] for item in active_ids}


def checklist_rows(stdout, entries):
    rows = {}
    results = set()
    for line in stdout.splitlines():
        info = json.loads(line)
        item = info["id"]
        entry = entries[item]
        result, reason = info["result"], info["reason"]
        task_name = entry["write_task"]
        if (
            not isinstance(item, str) or not item.strip() or item in rows
            or info["class"] != entry["class"] or info["write_task"] != task_name
            or not isinstance(entry["class"], str) or not entry["class"].strip()
            or result not in ("pass", "fail", "manual", "unknown")
            or not isinstance(reason, str) or not reason.strip()
            or (task_name is not None and (not isinstance(task_name, str) or not task_name.strip()))
        ):
            raise ValueError("invalid or inconsistent checklist row")
        row = {
            "item": item, "probe": f"{result}: {reason}",
            "action": "pending" if result == "fail" and task_name else "none",
            "class": entry["class"],
        }
        if row["class"] == "human-only":
            task_text = task_name or entry["label"]
            if not isinstance(task_text, str) or not task_text.strip():
                raise ValueError("human-only item has no catalog task text")
            row["task"] = task_text
        rows[item] = row
        results.add(result)
    return rows, results


def github_audit():
    if not taskfile:
        return [observation("audit:github", "not run: target has no Taskfile")]
    if not task:
        return [observation("audit:github", "unknown: go-task is unavailable")]
    if not Path("checklist-classes.json").is_file():
        return [observation("audit:github", "unknown: target has no checklist-classes.json")]
    try:
        entries = active_checklist_entries()
    except (OSError, ValueError, KeyError, TypeError):
        return [observation("audit:github", "unknown: unreadable or invalid target checklist or catalog")]

    try:
        summary = run_task("--summary", "audit:github", merge_output=True)
        if summary.returncode == 200:
            return [observation("audit:github", "not run: target has no audit:github task")]
        if summary.returncode:
            return [observation("audit:github", f"unknown: task discovery exited {summary.returncode}")]

        # No task arguments. In particular, --issue would write the status issue.
        audit = run_task("--silent", "--exit-code", "--output=interleaved", "audit:github")
    except OSError:
        return [observation("audit:github", "unknown: could not execute task")]
    if audit.returncode not in (0, 1, 2):
        return [observation("audit:github", f"unknown: audit exited {audit.returncode}")]
    try:
        rows, results = checklist_rows(audit.stdout, entries)
    except (ValueError, KeyError, TypeError):
        return [observation("audit:github", f"unknown: audit exited {audit.returncode} with invalid output")]

    # Exit 2 can coexist with trustworthy rows for individual items. Preserve
    # those observations and make the incomplete run visible in the report.
    if audit.returncode == 2:
        rows["audit:github"] = observation("audit:github", "unknown: audit reported unavailable evidence (exit 2)")
    else:
        expected_status = 1 if "fail" in results else 0
        if "unknown" in results or rows.keys() != entries.keys() or audit.returncode != expected_status:
            reason = f"audit exited {audit.returncode} with incomplete or inconsistent output (possible crash)"
            rows["audit:github"] = observation("audit:github", f"unknown: {reason}")
    return list(rows.values())


def ruleset_audit():
    def report(message, probe=None, output=""):
        stream = sys.stdout if args.ruleset_only and message.startswith(("OK:", "SKIP:")) else sys.stderr
        print(message, file=stream)
        if output:
            print(output.rstrip("\n"), file=sys.stdout if args.ruleset_only else sys.stderr)
        return observation("audit:ruleset", probe) if probe else None

    def unavailable(reason, output=""):
        return report(f"INFO: ruleset audit not checked — {reason}", f"unknown: {reason}", output)

    if not taskfile:
        return report("SKIP: ruleset audit — target has no Taskfile")
    if not task:
        return unavailable("task unavailable")
    try:
        listing = run_task("--list-all", merge_output=True)
        if listing.returncode:
            return unavailable("could not list target tasks", listing.stdout)
        summary = run_task("--summary", "audit:ruleset", merge_output=True)
        if summary.returncode == 200:
            return report("SKIP: ruleset audit — target has no audit:ruleset task")
        if summary.returncode:
            return unavailable(f"task --summary exited {summary.returncode}", summary.stdout)
        audit = run_task("--exit-code", "--output=interleaved", "audit:ruleset", merge_output=True)
    except OSError:
        return unavailable("could not execute task")

    lines = audit.stdout.splitlines()
    prefix = {0: "RULESET AUDIT CLEAN:", 1: "RULESET AUDIT DRIFT:", 2: "RULESET AUDIT UNAVAILABLE:"}
    expected = prefix.get(audit.returncode)
    marker = next((line for line in lines if expected and line.startswith(expected)), None)
    if marker is None:
        return unavailable(f"task exited {audit.returncode} without its result marker", audit.stdout)
    if audit.returncode == 0:
        return report("OK: ruleset audit — live ruleset matches the checked-in file", "clean: " + marker.split(":", 1)[1].strip(), audit.stdout)
    if audit.returncode == 1:
        indent = "  " if any(line.startswith("  --- ") for line in lines) else ""
        diff = [line[len(indent):] for line in lines if line.startswith(indent)]
        added = sum(line.startswith("+") and not line.startswith("+++ ") for line in diff)
        removed = sum(line.startswith("-") and not line.startswith("--- ") for line in diff)
        evidence = f"drift: {marker.split(':', 1)[1].strip()} (+{added}/-{removed} diff lines)"
        return report("WARN: ruleset audit drift (advisory) — live ruleset differs from the checked-in file", evidence, audit.stdout)
    return report(
        "INFO: ruleset audit not checked — unavailable (permission or absent ruleset)",
        "unknown: " + marker.split(":", 1)[1].strip(), audit.stdout,
    )


rows = [] if args.ruleset_only else github_audit()
ruleset = ruleset_audit()
if not args.ruleset_only:
    if ruleset:
        rows.append(ruleset)
    print(json.dumps(rows))
PY
