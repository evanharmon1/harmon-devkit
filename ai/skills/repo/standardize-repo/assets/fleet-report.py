#!/usr/bin/env python3
"""Render fleet reports and update only their marked issue-body regions.

See ../references/fleet-report.md for the input and write contracts.
"""

import argparse
import hashlib
import html
import json
import re
import subprocess
import sys
from pathlib import Path


class ReportError(Exception):
    """Invalid input, refused target, or unverifiable GitHub operation."""


def require(condition, message):
    if not condition:
        raise ReportError(message)


def text(value):
    """Escape data for a single Markdown table cell or task line."""
    if not isinstance(value, str):
        value = json.dumps(value, sort_keys=True, ensure_ascii=False)
    value = html.escape(value, quote=True)
    for char in "\\`*_{}[]()|!#@":
        value = value.replace(char, "\\" + char)
    return value.replace("\r", " ").replace("\n", " ")


def string(value, name):
    require(isinstance(value, str) and value.strip(), f"{name} must be nonempty text")
    return value


def reference(value):
    require(isinstance(value, dict), "issue reference must be an object")
    repo = value.get("repo", "")
    number = value.get("number")
    require(isinstance(repo, str) and re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo),
            "issue repo must be owner/name")
    require(type(number) is int and number > 0, "issue number must be a positive integer")
    return repo.lower(), number


def issue_link(ref):
    repo, number = reference(ref)
    return f"[{repo}#{number}](https://github.com/{repo}/issues/{number})"


def markers(run, kind):
    # The epic reference, not a mutable title or a private inventory path, binds a run.
    repo, number = reference(run["epic"])
    key = f"fleet-report:{repo}#{number}:{kind}"
    return f"<!-- {key}:begin -->", f"<!-- {key}:end -->"


def region(body, run, kind, content):
    begin, end = markers(run, kind)
    # Require standalone, unique delimiters. Reject reversed/nested lookalikes.
    require(body.count(begin) == 1 and body.count(end) == 1,
            f"missing or duplicate {kind} report marker")
    start = body.index(begin)
    finish = body.index(end)
    require(start < finish, f"reversed {kind} report markers")
    for pos, marker in ((start, begin), (finish, end)):
        require((pos == 0 or body[pos - 1] == "\n")
                and (pos + len(marker) == len(body) or body[pos + len(marker)] in "\r\n"),
                "report markers must occupy standalone lines")
    return body[:start] + begin + "\n" + content.rstrip("\n") + "\n" + body[finish:]


def table(headers, rows):
    return "\n".join(["| " + " | ".join(headers) + " |",
                       "| " + " | ".join("---" for _ in headers) + " |"]
                      + ["| " + " | ".join(row) + " |" for row in rows])


def validate(data):
    require(isinstance(data, dict) and data.get("version") == 1, "expected input version 1")
    run = data.get("run")
    require(isinstance(run, dict), "run must be an object")
    string(run.get("release"), "run.release")
    epic = reference(run.get("epic"))
    repos = data.get("repositories")
    require(isinstance(repos, list) and repos, "repositories must be a nonempty array")
    seen = set()
    targets = {epic}
    for row in repos:
        require(isinstance(row, dict), "repository entry must be an object")
        name = row.get("repository", "")
        require(isinstance(name, str) and re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", name),
                "repository must be owner/name")
        require(name.lower() not in seen, "duplicate repository")
        seen.add(name.lower())
        target = reference(row.get("tracking_issue"))
        require(target[0] == name.lower(), "tracking issue must belong to its repository")
        require(target not in targets, "duplicate issue target")
        targets.add(target)
        require(row.get("state") in ("planned", "working", "draft", "needs-review", "parked",
                                    "merge-ready", "merged", "closed", "blocked", "no-change"),
                "invalid lifecycle state")
        head = row.get("head")
        require(head is None or (isinstance(head, str) and re.fullmatch(r"[0-9a-f]{40}", head)),
                "head must be null or a full lowercase commit SHA")
        pr = row.get("pr")
        require(pr is None or (type(pr) is int and pr > 0), "pr must be null or a positive integer")
        for key in ("answers_changed", "non_adoption", "reconcile", "devcontainer"):
            require(isinstance(row.get(key, []), list), f"{key} must be an array")
        for item in row.get("non_adoption", []):
            string(item, "non_adoption item")
        count = row.get("non_adoption_count", len(row.get("non_adoption", [])))
        require(type(count) is int and count == len(row.get("non_adoption", [])),
                "non_adoption_count must equal the non_adoption list length")
        for item in row.get("answers_changed", []):
            require(isinstance(item, dict), "answer change must be an object")
            string(item.get("key"), "answer key")
            require("before" in item and "after" in item, "answer change needs before/after")
        pin = row.get("skills_pin")
        require(pin is None or (isinstance(pin, dict) and isinstance(pin.get("repository"), str) and pin["repository"].lower() == name.lower()),
                "skills_pin must be null or this repository's preflight JSON")
        if pin is not None:
            require(pin.get("verdict") in ("ok", "below-minimum", "unknown"),
                    "skills_pin requires a preflight verdict")
        for key in ("reconcile", "devcontainer"):
            ids = set()
            for item in row.get(key, []):
                require(isinstance(item, dict), f"{key} row must be an object")
                identity = string(item.get("item"), f"{key}.item")
                require(identity not in ids, f"duplicate {key} item")
                ids.add(identity)
                for field in ("probe", "action", "class"):
                    string(item.get(field), f"{key}.{field}")
                if item["class"] == "human-only":
                    string(item.get("task"), "human-only task")
        if "post_merge_metadata" in row:
            string(row["post_merge_metadata"], "post_merge_metadata")
    return data


def pin_summary(pin):
    if pin is None:
        return "not run"
    return "; ".join(f"{key}: {text(pin[key])}" for key in
                     ("pin", "minimum", "latest", "pin_lag", "verdict", "open_sync_prs", "ruling", "planned_action", "reason")
                     if key in pin)


def probe_table(rows):
    if not rows:
        return "not run"
    return table(["Item", "Probe result", "Action taken", "Class"],
                 [[text(item[key]) for key in ("item", "probe", "action", "class")] for item in rows])


def human_rows(row):
    return [item for key in ("reconcile", "devcontainer") for item in row.get(key, [])
            if item["class"] == "human-only"]


def render(data, collector=None):
    run = data["run"]
    fleet_rows = []
    reports = []
    for row in sorted(data["repositories"], key=lambda item: item["repository"].lower()):
        name = row["repository"].lower()
        pr = f"[#{row['pr']}](https://github.com/{name}/pull/{row['pr']})" if row.get("pr") else "none"
        head = row.get("head") or "not run"
        reconcile = row.get("reconcile", [])
        summary = "; ".join(f"{text(item['item'])}: {text(item['probe'])}; {text(item['action'])} ({text(item['class'])})"
                            for item in reconcile) or "not run"
        count = len(row.get("non_adoption", []))
        metadata = text(row.get("post_merge_metadata", "not run"))
        fleet_rows.append([issue_link(row["tracking_issue"]), pr, head, row["state"], str(count),
                           pin_summary(row.get("skills_pin")), summary, metadata])
        answers = row.get("answers_changed", [])
        changed = table(["Answer", "Before", "After"],
                        [[text(item[key]) for key in ("key", "before", "after")] for item in answers]) if answers else "none"
        non_adoption = "\n".join("- " + text(item) for item in row.get("non_adoption", [])) or "none"
        content = f"""## Repository report — {text(name)}

Release: {text(run['release'])}; fleet epic: {issue_link(run['epic'])}.

PR: {pr}; head: {head}; state: {row['state']}.

### Answers changed

{changed}

### Silent non-adoption ({count})

{non_adoption}

### Skills pin

{pin_summary(row.get('skills_pin'))}

### Reconcile

{probe_table(reconcile)}

### Devcontainer and image

{probe_table(row.get('devcontainer', []))}

### Post-merge metadata

{metadata}"""
        if human_rows(row):
            require(collector is not None, "human follow-ups require a resolved collector")
            followups = sorted({f"Human follow-up (tracked in {issue_link(collector)}): {text(item['task'])} "
                                f"(item: {text(item['item'])}; probe: {text(item['probe'])})."
                                for item in human_rows(row)})
            content += "\n\n### Out of scope\n\n" + "\n\n".join(followups)
        reports.append({"issue": row["tracking_issue"], "kind": "repository", "content": content})
    fleet = f"## Fleet report — {text(run['release'])}\n\n" + table(
        ["Repository / tracking issue", "PR", "Head", "State", "Silent non-adoption", "Skills pin",
         "Reconcile", "Post-merge metadata"], fleet_rows)
    return [{"issue": run["epic"], "kind": "fleet", "content": fleet}] + reports


class GitHub:
    def __init__(self, executable):
        self.executable = executable

    def call(self, *args, body=None):
        result = subprocess.run([self.executable, *map(str, args)], input=body, text=True,
                                encoding="utf-8", capture_output=True, check=False)
        require(result.returncode == 0, f"gh operation failed ({result.returncode}): {result.stderr.strip()}")
        return result.stdout

    def read(self, *args):
        try:
            return json.loads(self.call(*args))
        except json.JSONDecodeError as error:
            raise ReportError("gh returned invalid JSON") from error

    def issue(self, ref):
        repo, number = reference(ref)
        return self.read("issue", "view", number, "--repo", repo, "--json",
                         "number,title,body,state,stateReason,labels,milestone,parent")

    def edit(self, ref, body):
        repo, number = reference(ref)
        self.call("issue", "edit", number, "--repo", repo, "--body-file", "-", body=body)
        require(self.issue(ref)["body"] == body, f"write readback mismatch: {repo}#{number}")
        print(f"updated {repo}#{number}")


def collector_scope(epic, ref):
    milestone = epic.get("milestone")
    if milestone:
        require(type(milestone.get("number")) is int, "epic milestone number missing")
        return f"Collector scope: milestone {milestone['number']}"
    repo, number = reference(ref)
    return f"Collector scope: {repo}#{number}"


def find_collector(gh, data, epic):
    repo, _ = reference(data["run"]["epic"])
    scope = collector_scope(epic, data["run"]["epic"])
    candidates = gh.read("issue", "list", "--repo", repo, "--state", "all", "--label", "human",
                         "--label", "umbrella", "--limit", "1000", "--json",
                         "number,title,state,stateReason,closedAt,milestone,body")
    require(isinstance(candidates, list) and len(candidates) < 1000,
            "collector lookup incomplete; narrow/provision through track-work")
    matches = [item for item in candidates if item["title"].startswith("(HUMAN):")
               and scope.lower() in [line.lower() for line in item["body"].splitlines()]]
    opened = [item for item in matches if item["state"] == "OPEN"]
    require(len(opened) <= 1, "duplicate open collectors; reconcile through track-work")
    if opened:
        chosen = opened[0]
    else:
        completed = [item for item in matches if item.get("stateReason") == "COMPLETED"]
        require(completed, "no collector: provision lazily through track-work's Human tasks go to a collector procedure, then retry")
        chosen = max(completed, key=lambda item: item.get("closedAt") or "")
    ref = {"repo": repo, "number": chosen["number"]}
    require(reference(ref) != reference(data["run"]["epic"]), "epic cannot be its own collector")
    require(all(reference(ref) != reference(row["tracking_issue"]) for row in data["repositories"]),
            "collector cannot be a tracking issue")
    validate_collector(gh.issue(ref), scope, epic, data["run"]["epic"])
    return ref, scope


def validate_collector(issue, scope, epic, epic_ref):
    labels = {item["name"] for item in issue.get("labels", [])}
    require(issue["title"].startswith("(HUMAN):") and {"human", "umbrella"} <= labels
            and scope.lower() in [line.lower() for line in issue["body"].splitlines()], "collector identity/scope changed")
    require(issue["state"] == "OPEN" or issue.get("stateReason") == "COMPLETED",
            "collector is closed for a reason other than completed")
    if epic.get("milestone"):
        require((issue.get("milestone") or {}).get("number") == epic["milestone"]["number"],
                "collector milestone mismatch")
    parent = issue.get("parent") or {}
    require(parent.get("url", "").lower() == f"https://github.com/{epic_ref['repo'].lower()}/issues/{epic_ref['number']}",
            "collector is not an epic sub-issue")


def task_key(task, collector_repo):
    """Use a reporter marker, otherwise normalised text and its trailing source."""
    marker = re.search(r"<!-- fleet-human:([^<>]+) -->", task)
    if marker:
        return ("marker", marker[1])
    task = re.sub(r"\\([!\"#$%&'()*+,\-./:;<=>?@\[\]\\^_`{|}~])", r"\1", task)
    match = re.search(r" \(from ((?:[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)?#[0-9]+)\)\s*$", task)
    if not match:
        return None
    source = match[1].lower()
    if source.startswith("#"):
        source = collector_repo.lower() + source
    return ("source", " ".join(html.unescape(task[:match.start()]).split()), source)


def append_tasks(body, owner, tasks, collector_repo):
    """Append only within unfenced Acceptance criteria, preserving existing ticks."""
    lines = body.splitlines(keepends=True)
    visible = []
    fence = None
    fence_start = None
    for index, line in enumerate(lines):
        if fence:
            if re.fullmatch(r" {0,3}" + re.escape(fence[0]) + "{" + str(len(fence)) + r",}\s*", line):
                fence = None
                fence_start = None
            continue
        opening = re.match(r" {0,3}(`{3,}|~{3,})", line)
        if opening:
            fence = opening[1]
            fence_start = index
        else:
            visible.append(index)
    starts = [index for index in visible if lines[index].rstrip("\r\n") == "## Acceptance criteria"]
    require(len(starts) == 1, "collector must have one Acceptance criteria section")
    start = starts[0]
    end = fence_start if fence_start is not None else len(lines)
    for position, index in enumerate(visible):
        if index <= start:
            continue
        if re.match(r" {0,3}#{1,2}(?:[ \t]|$)", lines[index].rstrip("\r\n")):
            end = index
            break
        if (re.fullmatch(r" {0,3}(?:=+|-+)[ \t]*", lines[index].rstrip("\r\n"))
                and visible[position - 1] == index - 1 and lines[index - 1].strip()):
            end = index - 1
            break
    section = [index for index in visible if start < index < end]
    existing = {task_key(match[1], collector_repo) for index in section
                if (match := re.match(r"- \[[ xX]\] (.*)", lines[index]))}
    existing.discard(None)
    missing = []
    for task, ordinary_key in tasks:
        key = task_key(task, collector_repo)
        if key not in existing and ordinary_key not in existing:
            missing.append(task)
            existing.add(key)
    if not missing:
        return body
    heading = "### " + owner
    matches = [index for index in section if lines[index].rstrip("\r\n").lower() == heading.lower()]
    require(len(matches) <= 1, "duplicate collector owner sections")
    addition = "\n".join("- [ ] " + task for task in missing) + "\n"
    if matches:
        end = next((index for index in section if index > matches[0] and lines[index].startswith("### ")), end)
        prefix = "\n"
    else:
        prefix = "\n\n" + heading + "\n\n"
    return "".join(lines[:end]).rstrip("\n") + prefix + addition + "\n" + "".join(lines[end:])


def report_context(data, gh):
    epic = gh.issue(data["run"]["epic"])
    collector, scope = None, None
    if any(human_rows(row) for row in data["repositories"]):
        require("epic" in {item["name"] for item in epic.get("labels", [])}, "fleet parent must carry epic label")
        collector, scope = find_collector(gh, data, epic)
    return epic, collector, scope, render(data, collector)


def write(data, gh):
    epic, collector, scope, reports = report_context(data, gh)
    # Check every report marker before the first mutation, including collector writes.
    for report in reports:
        issue = gh.issue(report["issue"])
        region(issue["body"], data["run"], report["kind"], report["content"])
    epic_ref = data["run"]["epic"]
    tasks = {}
    for row in data["repositories"]:
        for item in human_rows(row):
            owner = row["repository"].split("/")[0].lower()
            source_repo, source_number = reference(row["tracking_issue"])
            identity = json.dumps([source_repo, source_number, item["task"]], ensure_ascii=False)
            key = hashlib.sha256(identity.encode("utf-8")).hexdigest()
            task = (f"[HUMAN] {text(item['task'])} — probe: {text(item['probe'])} "
                    f"(from {source_repo}#{source_number}; item: {text(item['item'])}) "
                    f"<!-- fleet-human:{key} -->")
            ordinary_key = task_key(f"[HUMAN] {text(item['task'])} (from {source_repo}#{source_number})",
                                    collector["repo"])
            tasks.setdefault(owner, {}).setdefault(key, (task, ordinary_key))
    if tasks:
        current = gh.issue(collector)
        proposed = current["body"]
        for owner in sorted(tasks):
            proposed = append_tasks(proposed, owner, sorted(tasks[owner].values()), collector["repo"])
        # Re-read identity and body immediately before the append/reopen.
        current = gh.issue(collector)
        validate_collector(current, scope, epic, epic_ref)
        proposed = current["body"]
        for owner in sorted(tasks):
            proposed = append_tasks(proposed, owner, sorted(tasks[owner].values()), collector["repo"])
        if current["state"] != "OPEN" and proposed != current["body"]:
            repo, number = reference(collector)
            gh.call("issue", "reopen", number, "--repo", repo)
            current = gh.issue(collector)
            validate_collector(current, scope, epic, epic_ref)
            require(current["state"] == "OPEN", "collector reopen unverified")
            proposed = current["body"]
            for owner in sorted(tasks):
                proposed = append_tasks(proposed, owner, sorted(tasks[owner].values()), collector["repo"])
        if proposed != current["body"]:
            gh.edit(collector, proposed)
    # Collector first, source lines only after its confirmed append. No rollback:
    # retry re-reads live state and recovers a partially completed publication.
    for report in reports:
        content = report["content"]
        live = gh.issue(report["issue"])
        updated = region(live["body"], data["run"], report["kind"], content)
        if updated != live["body"]:
            gh.edit(report["issue"], updated)
        else:
            repo, number = reference(report["issue"])
            print(f"unchanged {repo}#{number}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("render", "write"))
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--gh", default="gh", help="GitHub CLI executable (one path, never shell code)")
    args = parser.parse_args()
    try:
        data = validate(json.loads(args.input.read_text(encoding="utf-8")))
        if args.command == "render":
            gh = GitHub(args.gh)
            _, _, _, reports = report_context(data, gh)
            for report in reports:
                live = gh.issue(report["issue"])
                report["body"] = region(live["body"], data["run"], report["kind"], report.pop("content"))
            print(json.dumps({"reports": reports}, indent=2, ensure_ascii=False))
        else:
            write(data, GitHub(args.gh))
    except (ReportError, OSError, ValueError, KeyError, TypeError) as error:
        print(f"fleet-report: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
