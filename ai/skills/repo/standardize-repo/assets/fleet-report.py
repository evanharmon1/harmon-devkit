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
    value = html.escape(value, quote=False)
    for char in "\\`*_{}[]()|!#@":
        value = value.replace(char, "\\" + char)
    return re.sub(r"[\r\n\x0b\x0c\x1c-\x1e\x85\u2028\u2029]", " ", value)


def code_span(value):
    """Preserve a command in a GFM table code span."""
    fence = "`" * (max((len(run) for run in re.findall(r"`+", value)), default=0) + 1)
    padded = value.startswith(("`", " ")) or value.endswith(("`", " "))
    value = value.replace("|", r"\|")
    return fence + (" " if padded else "") + value + (" " if padded else "") + fence


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
    queue = data.get("rebuild_queue", [])
    require(isinstance(queue, list), "rebuild_queue must be an array")
    workspaces = set()
    for entry in queue:
        require(isinstance(entry, dict), "rebuild queue entry must be an object")
        workspace = string(entry.get("workspace"), "workspace")
        require(workspace not in workspaces, "duplicate rebuild workspace")
        workspaces.add(workspace)
        require(type(entry.get("wave")) is int and entry["wave"] > 0, "wave must be positive")
        command = string(entry.get("command"), "rebuild command")
        require(not any(ord(char) < 0x20 or ord(char) == 0x7f for char in command),
                f"rebuild command for workspace {workspace!r} must not contain control characters")
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
    queue = sorted(data.get("rebuild_queue", []), key=lambda entry: (entry["wave"], entry["workspace"]))
    fleet += "\n\n### Rebuild queue (after each wave merges)\n\n"
    fleet += table(["After wave", "Workspace", "Rebuild command"],
                   [[str(entry["wave"]), text(entry["workspace"]), code_span(entry["command"])]
                    for entry in queue]) if queue else "none"
    return [{"issue": run["epic"], "kind": "fleet", "content": fleet}] + reports


class GitHub:
    def __init__(self, executable):
        self.executable = executable

    def call(self, *args, body=None):
        result = subprocess.run([self.executable, *map(str, args)], input=body, text=True,
                                encoding="utf-8", capture_output=True, check=False)
        if result.returncode != 0 and 'Unknown JSON field: "parent"' in result.stderr:
            raise ReportError("fleet-report requires GitHub CLI 2.94.0 or newer "
                              "for the issue parent JSON field")
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
    # A task already filed to an epic's collector stays there if the epic's
    # milestone changes. Ambiguous prior placement needs human reconciliation.
    prior = []
    for candidate in candidates:
        if (not candidate.get("title", "").startswith("(HUMAN):")
                or not (candidate.get("state") == "OPEN" or candidate.get("stateReason") == "COMPLETED")
                or not isinstance(candidate.get("body"), str)
                or not any(re.fullmatch(r"Collector scope: (?:milestone [0-9]+|[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+)",
                                        line, re.IGNORECASE) for line in candidate["body"].splitlines())):
            continue
        candidate_ref = {"repo": repo, "number": candidate["number"]}
        live = gh.issue(candidate_ref)
        parent = live.get("parent") or {}
        if parent.get("url", "").lower() != f"https://github.com/{repo.lower()}/issues/{data['run']['epic']['number']}":
            continue
        for row in data["repositories"]:
            source_repo, source_number = reference(row["tracking_issue"])
            for item in human_rows(row):
                key = task_key(f"[HUMAN] {text(item['task'])} (from {source_repo}#{source_number})", repo)
                marker = human_marker(source_repo, source_number, item["task"])
                if append_tasks(live["body"], row["repository"].split("/")[0].lower(),
                                [(f"<!-- fleet-human:{marker} -->", key)], repo) == live["body"]:
                    prior.append((candidate, live))
                    break
            else:
                continue
            break
    require(len(prior) <= 1, "tasks already filed to multiple collectors; reconcile through track-work")
    if prior:
        chosen, live = prior[0]
        scopes = [line for line in live["body"].splitlines() if line.lower().startswith("collector scope: ")]
        require(len(scopes) == 1, "collector identity/scope changed")
        scope = scopes[0]
        ref = {"repo": repo, "number": chosen["number"]}
        require(reference(ref) != reference(data["run"]["epic"]), "epic cannot be its own collector")
        require(all(reference(ref) != reference(row["tracking_issue"]) for row in data["repositories"]),
                "collector cannot be a tracking issue")
        validate_collector(live, scope, epic, data["run"]["epic"])
        return ref, scope
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
    milestone_scope = re.fullmatch(r"Collector scope: milestone ([0-9]+)", scope, re.IGNORECASE)
    if milestone_scope:
        require((issue.get("milestone") or {}).get("number") == int(milestone_scope[1]),
                "collector milestone mismatch")
    else:
        repo, number = reference(epic_ref)
        require(scope.lower() == f"collector scope: {repo}#{number}".lower(), "collector identity/scope changed")
    parent = issue.get("parent") or {}
    require(parent.get("url", "").lower() == f"https://github.com/{epic_ref['repo'].lower()}/issues/{epic_ref['number']}",
            "collector is not an epic sub-issue")


def normalize_task(task):
    task = re.sub(r"\\([!\"#$%&'()*+,\-./:;<=>?@\[\]\\^_`{|}~])", r"\1", task)
    return " ".join(html.unescape(task).split())


def human_marker(source_repo, source_number, task):
    identity = json.dumps([source_repo, source_number, normalize_task(task)], ensure_ascii=False)
    return hashlib.sha256(identity.encode("utf-8")).hexdigest()


def task_key(task, collector_repo, *, ignore_marker=False):
    """Use a reporter marker, otherwise normalised text and its trailing source."""
    marker = re.search(r"<!-- fleet-human:([^<>]+) -->", task)
    if marker and not ignore_marker:
        return ("marker", marker[1])
    task = re.sub(r"\s*<!-- fleet-human:[^<>]+ -->\s*$", "", task)
    match = re.search(r"(?<!\\) \(from ((?:[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)?#[0-9]+)"
                      r"(?:; item: (?:\\.|[^\\)])*)?\)\s*$", task)
    if not match:
        return None
    source = match[1].lower()
    if source.startswith("#"):
        source = collector_repo.lower() + source
    description = task[:match.start()]
    if "; item: " in match[0]:
        description = re.split(r"\s+—\s+probe:\s*", description, maxsplit=1)[0]
    return ("source", normalize_task(description), source)


def parse_collector(body):
    """Validate the collector line language and return (lines, section, newline)."""
    require(not re.search(r"\r(?!\n)|[\x0b\x0c\x1c-\x1e\x85\u2028\u2029]", body),
            "ambiguous collector boundary line ending")
    require(not ("\r\n" in body and re.search(r"(?<!\r)\n", body)),
            "ambiguous collector boundary mixed line endings")
    newline = "\r\n" if "\r\n" in body else "\n"
    lines = body.splitlines(keepends=True)
    # Accept a small, unambiguous line language across the entire body. This
    # deliberately refuses Markdown constructs we cannot safely bound, including
    # fences, HTML blocks, indented headings, and setext/thematic-break lines.
    # Reporter task markers are the only HTML admitted.
    starts = []
    end = len(lines)
    in_section = False
    for index, line in enumerate(lines):
        value = line.rstrip("\r\n")
        if not value.strip():
            continue
        if value == "## Acceptance criteria":
            starts.append(index)
            in_section = True
            continue
        if (re.fullmatch(r"## [A-Za-z0-9][A-Za-z0-9 .,:/()_-]*", value)
                and value == value.rstrip()
                and re.sub(r"\s+", " ", value.strip()).lower() != "## acceptance criteria"):
            if in_section:
                end = min(end, index)
                in_section = False
            continue
        if re.fullmatch(r"### [A-Za-z0-9_.-]+", value):
            continue
        if re.fullmatch(r"- \[[ xX]\] (?:[^<>`\\\r\n]|\\[^\r\n<>])*(?:<!-- fleet-human:[0-9a-f]{64} -->)?", value):
            continue
        if not in_section and re.fullmatch(r"[A-Za-z0-9](?:[^<>`\\\r\n]|\\[^\r\n<>])*", value):
            continue
        raise ReportError(f"ambiguous collector boundary syntax at line {index + 1}")
    require(len(starts) == 1, "collector must have one Acceptance criteria section")
    return lines, range(starts[0] + 1, end), newline


def append_tasks(body, owner, tasks, collector_repo):
    """Append only within unfenced Acceptance criteria, preserving existing ticks."""
    lines, section, newline = parse_collector(body)
    end = section.stop
    existing = {key for index in section
                if (match := re.match(r"- \[[ xX]\] (.*)", lines[index]))
                for key in (task_key(match[1], collector_repo),
                            task_key(match[1], collector_repo, ignore_marker=True))}
    existing.discard(None)
    missing = []
    for task, ordinary_key in tasks:
        key = task_key(task, collector_repo)
        if key not in existing and ordinary_key not in existing:
            missing.append(task)
            existing.update((key, ordinary_key))
    if not missing:
        return body
    heading = "### " + owner
    matches = [index for index in section if lines[index].rstrip("\r\n").lower() == heading.lower()]
    require(len(matches) <= 1, "duplicate collector owner sections")
    addition = newline.join("- [ ] " + task for task in missing) + newline
    if matches:
        end = next((index for index in section if index > matches[0] and lines[index].startswith("### ")), end)
        prefix = newline
    else:
        prefix = newline * 2 + heading + newline * 2
    result = "".join(lines[:end]).rstrip("\r\n") + prefix + addition + newline + "".join(lines[end:])
    parse_collector(result)
    return result


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
            key = human_marker(source_repo, source_number, item["task"])
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
