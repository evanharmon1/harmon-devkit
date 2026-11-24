#!/usr/bin/env bash
# Run the target's read-only audits and emit the fleet report's reconcile array.
set -euo pipefail
exec python3 -B - "$@" <<'PY'
import argparse
import json
import os
from pathlib import Path
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


def checklist_rows(stdout):
    catalog = json.loads(Path("checklist-classes.json").read_text(encoding="utf-8"))
    entries = catalog["entries"]
    if catalog["schema_version"] != 1 or not isinstance(entries, list) or not entries:
        raise ValueError("unsupported or empty checklist catalog")
    by_id = {entry["id"]: entry for entry in entries}
    if len(by_id) != len(entries) or by_id.keys() & {"audit:github", "audit:ruleset"}:
        raise ValueError("duplicate or reserved catalog ID")

    rows = {}
    for line in stdout.splitlines():
        info = json.loads(line)
        item = info["id"]
        entry = by_id[item]
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
    return list(rows.values())


def github_audit():
    if not taskfile:
        return [observation("audit:github", "not run: target has no Taskfile")]
    if not task:
        return [observation("audit:github", "unknown: go-task is unavailable")]
    try:
        summary = run_task("--summary", "audit:github", merge_output=True)
        if summary.returncode == 200:
            return [observation("audit:github", "not run: target has no audit:github task")]
        if summary.returncode:
            return [observation("audit:github", f"unknown: task discovery exited {summary.returncode}")]

        # No task arguments. In particular, --issue would write the status issue.
        audit = run_task("--silent", "--exit-code", "--output=interleaved", "audit:github")
        if audit.returncode not in (0, 1, 2):
            return [observation("audit:github", f"unknown: audit exited {audit.returncode}")]
        rows = checklist_rows(audit.stdout)
    except (OSError, ValueError, KeyError, TypeError):
        return [observation("audit:github", "unknown: unreadable catalog or invalid audit output")]

    # Exit 2 can coexist with trustworthy rows for individual items. Preserve
    # those observations and make the incomplete run visible in the report.
    if audit.returncode == 2:
        rows.append(observation("audit:github", "unknown: audit reported unavailable evidence (exit 2)"))
    elif not rows:
        rows.append(observation("audit:github", "unknown: audit produced no checklist rows"))
    return rows


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
        added = sum(line.startswith("+") and not line.startswith("+++ ") for line in lines)
        removed = sum(line.startswith("-") and not line.startswith("--- ") for line in lines)
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
