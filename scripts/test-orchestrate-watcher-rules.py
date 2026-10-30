#!/usr/bin/env python3
"""Pin orchestrator watcher rules and exercise the rendered sentinel matcher."""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path


def norm(text: str) -> str:
    return re.sub(r"\s+", " ", text).strip()


def pin(errors: list[str], name: str, actual: str, expected: str) -> None:
    if norm(actual) != norm(expected):
        errors.append(f"{name}: whole text differs after whitespace normalization")


def pin_range(
    errors: list[str], name: str, document: str, start: str, end: str, expected: str
) -> str:
    text = norm(document)
    start = norm(start)
    end = norm(end)
    first = text.find(start)
    if first < 0:
        errors.append(f"{name}: start of pinned text is missing")
        return ""
    last = text.find(end, first + len(start))
    if last < 0:
        errors.append(f"{name}: end of pinned text is missing")
        return text[first:]
    actual = text[first : last + len(end)]
    pin(errors, name, actual, expected)
    return actual


def pin_once(errors: list[str], name: str, document: str, expected: str) -> None:
    count = norm(document).count(norm(expected))
    if count != 1:
        errors.append(f"{name}: expected one exact occurrence, found {count}")


def pin_absent(errors: list[str], name: str, document: str, deleted: str) -> None:
    if norm(deleted) in norm(document):
        errors.append(f"{name}: deleted round-1 wording is still present")


def pin_watcher_state_homes(errors: list[str], root: Path) -> None:
    documents = [
        root / "ai/skills/universal/orchestrate/SKILL.md",
        *sorted((root / "ai/skills/universal/orchestrate/references").glob("*.md")),
        root / "ai/skills/universal/orchestrate/assets/lane-brief.md",
        root / "docs/guides/herdr.md",
    ]
    watcher_state = re.compile(r"lane-watch\.state")
    per_slate_home = re.compile(
        r"<git-common-dir>/dev-flow-v2/slates/<slate(?:-id)?>/lane-watch\.state"
    )
    for document in documents:
        content = norm(document.read_text())
        valid_ends = {match.end() for match in per_slate_home.finditer(content)}
        for mention in watcher_state.finditer(content):
            if mention.end() not in valid_ends:
                relative = document.relative_to(root)
                errors.append(
                    f"{relative}: lane-watch.state must name the per-slate watcher home"
                )


def pin_sentinels(errors: list[str], root: Path, skill: str, template: str) -> None:
    expected = {
        "ready": "MERGE-READY-<lane-label>",
        "handoff": "DRAFT-PUBLISHED-<lane-label>",
        "blocked": "BLOCKED-<lane-label>",
    }
    rows = re.compile(
        r"^\| `\{\{(ready|handoff|blocked)-sentinel\}\}` \| `([^`]+)` \|",
        re.MULTILINE,
    )
    catalog = {match[1]: match[2] for match in rows.finditer(skill)}
    if catalog != expected:
        errors.append(f"sentinel catalog must contain kind/lane prefixes: {catalog!r}")

    pin_once(
        errors,
        "sentinel catalog invariant",
        skill,
        "The sentinel placeholder values are kind/lane prefixes; the lane-brief "
        "template appends `-{{attempt-nonce}}` to form the complete sentinel.",
    )
    pin_once(
        errors,
        "orchestrator sentinel form",
        skill,
        "Sentinels use the exact kind-first form `(MERGE-READY|DRAFT-PUBLISHED|BLOCKED)-<lane-label>-<nonce>`, "
        "matching `^(MERGE-READY|DRAFT-PUBLISHED|BLOCKED)-<lane-label>-<nonce>$`; labels and nonces "
        "contain only ASCII letters, digits, underscores and hyphens.",
    )
    pin_once(
        errors,
        "lane-brief sentinel form",
        template,
        "Terminal sentinels use the exact kind-first form `(MERGE-READY|DRAFT-PUBLISHED|BLOCKED)-<lane-label>-<nonce>`, "
        "matching `^(MERGE-READY|DRAFT-PUBLISHED|BLOCKED)-<lane-label>-<nonce>$`; labels and nonces "
        "contain only ASCII letters, digits, underscores and hyphens.",
    )
    lane, nonce = "L-fixture", "a1b2c3"
    rendered = template
    for kind, value in catalog.items():
        placeholder = f"{{{{{kind}-sentinel}}}}"
        use = f"{placeholder}-{{{{attempt-nonce}}}}"
        if template.count(use) != 1:
            errors.append(f"sentinel template must use {use} exactly once")
        rendered = rendered.replace(placeholder, value.replace("<lane-label>", lane))
    rendered = rendered.replace("{{attempt-nonce}}", nonce)

    watcher = root / "ai/skills/universal/orchestrate/assets/lane-watch.sh"
    matcher = (
        "source <(sed -n '/^terminal_sentinel() {/,/^}/p' \"$0\"); "
        'terminal_sentinel "$1" "$2"'
    )
    marker = re.search(r"Append exactly one of the\s+following to", rendered)
    if marker is None:
        errors.append("rendered template has no terminal-sentinel list")
        sentinel_tokens: list[str] = []
    else:
        end_marker = "The lane's own handoff sentinel"
        end_at = rendered.find(end_marker, marker.end())
        if end_at < 0:
            errors.append("rendered template has no end to the terminal-sentinel list")
            sentinel_tokens = []
        else:
            sentinel_tokens = re.findall(
                r"(?m)^[ \t]*- `([^`]+)` —", rendered[marker.end() : end_at]
            )
    expected_tokens = {
        f"MERGE-READY-{lane}-{nonce}",
        f"DRAFT-PUBLISHED-{lane}-{nonce}",
        f"BLOCKED-{lane}-{nonce}",
    }
    if set(sentinel_tokens) != expected_tokens:
        errors.append(
            "rendered template must expose exact MERGE-READY, DRAFT-PUBLISHED, and BLOCKED tokens"
        )

    for token in sentinel_tokens:
        result = subprocess.run(
            ["bash", "-c", matcher, str(watcher), lane, nonce],
            input=f"previous line\n{token}\n",
            text=True,
            capture_output=True,
            check=False,
        )
        if result.returncode != 0 or result.stdout.strip() != token:
            errors.append(f"lane-watch.sh rejected rendered sentinel {token}")


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {Path(sys.argv[0]).name} <repo-or-mutation-root>", file=sys.stderr)
        return 2
    root = Path(sys.argv[1]).resolve()
    skill = (root / "ai/skills/universal/orchestrate/SKILL.md").read_text()
    herdr = (root / "docs/guides/herdr.md").read_text()
    template = (root / "ai/skills/universal/orchestrate/assets/lane-brief.md").read_text()
    cloud_template = (
        root / "ai/skills/universal/orchestrate/assets/cloud-lane-brief.md"
    ).read_text()
    implementer = (
        root / "ai/skills/universal/implement/assets/implementer-brief.md"
    ).read_text()
    review = (root / "ai/skills/universal/review/SKILL.md").read_text()
    errors: list[str] = []

    process_convention = (
        "Before sending a signal, re-read the PID's command to confirm it is the "
        "process you intend to end; PIDs are reused. Prefer the process tree your "
        "own session or lane started. Send `TERM` before `KILL`. Never kill by "
        "name pattern (`pkill`/`killall`): a pattern can match processes you did "
        "not start. Signal only the PID you confirmed. A repository "
        "rule that still requires approval before ending a process takes precedence "
        "over this convention."
    )
    pin_once(
        errors, "orchestrator process-ending convention", skill, process_convention
    )
    pin_absent(
        errors,
        "orchestrator editor recovery restriction",
        skill,
        "terminating a process — that is the maintainer's decision",
    )
    pin_absent(
        errors,
        "orchestrator TaskStop approval requirement",
        skill,
        "(`TaskStop`) requires the user's explicit approval",
    )
    pin_absent(
        errors,
        "orchestrator legacy kill-tool prohibition",
        skill,
        "Never use `kill`, `pkill`, `killall`, or `xkill`.",
    )
    downstream = (
        ("lane brief", template, 2),
        ("cloud lane brief", cloud_template, 1),
        ("implementer brief", implementer, 1),
        ("review skill", review, 1),
        ("Herdr guide", herdr, 1),
    )
    for name, document, expected_references in downstream:
        normalized = norm(document)
        references = normalized.count(
            "orchestrate skill's process-ending convention"
        )
        if references != expected_references:
            errors.append(
                f"{name}: expected {expected_references} references to the "
                f"orchestrate process-ending convention, found {references}"
            )
        if norm(process_convention) in normalized:
            errors.append(f"{name}: repeats the orchestrate process convention")
        pin_absent(
            errors,
            f"{name} generic process prohibition",
            document,
            "Never terminate a process.",
        )
        pin_absent(
            errors,
            f"{name} legacy kill-tool prohibition",
            document,
            "Never use `kill`, `pkill`, `killall`, or `xkill`.",
        )
    pin_absent(
        errors,
        "lane brief editor recovery prohibition",
        template,
        "never recover by terminating a process",
    )
    pin_absent(
        errors,
        "review skill process-ending restriction",
        review,
        "no authority to terminate a process",
    )
    pin_absent(
        errors,
        "Herdr TaskStop approval requirement",
        herdr,
        "(`TaskStop`) requires the user's explicit approval",
    )

    skill_ranges = (
        (
            "orchestrator monitor invocation",
            "Use only `assets/lane-watch.sh`;",
            "summaries.",
            "Use only `assets/lane-watch.sh`; invoke that file rather than inlining its loop or writing a substitute. Prefer the harness streaming monitor (Claude Code: `Monitor`) when its command can reach both `gh` and `herdr`. It polls fresh lane-agent and PR state and streams transitions (`idle`, `done`, `blocked`, `unknown`, and PR deltas), approval prompts, stalls, and heartbeat summaries.",
        ),
        (
            "orchestrator expiry order",
            "If the streaming monitor is sandboxed from either `gh` or `herdr`,",
            "block instead of falling back to manual polling.",
            "If the streaming monitor is sandboxed from either `gh` or `herdr`, do not send the watcher through `Monitor` and do not block while a bounded path is available. From a shell outside that sandbox, launch a finite background Bash pass of the same watcher, for example `bash <skill-dir>/assets/lane-watch.sh --iterations <n> --state-file <same-state-file> --registry <kickoff-registry> <latest-deadline> <lane-specs...>`, and capture the pass output for review. The pass exits after `--iterations`; keep exactly one pass active per slate and reuse the same `--state-file` on each re-arm. Events surface at pass end, so the pass length bounds how long a lane can wait on an approval. On every streaming-monitor expiry or nonterminal pass exit, re-arm first, before any other tool call, with the same state file; then check lane staleness before other work. Never interpret monitor or pass termination as human cancellation. If neither the streaming monitor nor an outside-sandbox Bash pass can reach both CLIs, block instead of falling back to manual polling.",
        ),
        (
            "orchestrator other wakeup",
            "On every other wakeup (a user message or monitor event)",
            "past the stall threshold before other work.",
            "On every other wakeup (a user message or monitor event), first compare the current time with each lane's last observed change; read and act on any lane silent past the stall threshold before other work.",
        ),
        (
            "orchestrator one-watcher and process convention",
            "Keep exactly one watcher per slate.",
            "follow the process-ending convention above.",
            "Keep exactly one watcher per slate. Replace a streaming watcher by letting its monitor expire on the harness's own schedule (Claude Code: within 30 minutes) and re-arming; bounded Bash passes exit naturally after their iteration limit. For an early harness monitor-stop (Claude Code: `TaskStop` on that monitor's task), follow the process-ending convention above.",
        ),
        (
            "orchestrator watcher deadline",
            "Pass the watcher the latest `{{deadline}}`",
            "never readiness.",
            "Pass the watcher the latest `{{deadline}}` among the slate's live lanes, never the earliest: `lane-watch.sh` takes one deadline, so the earliest would stop supervising every later lane and make each re-arm exit at once. A lane past its own deadline is capped by the dispatch-time clock check below, not by the watcher, and its spec leaves the watcher at the next re-arm. A `WALLCLOCK run: deadline <deadline> reached` event ends the timed lanes only: record their capped transitions and render their blockers before re-arming timed lanes with a later deadline. PR-only specs are re-armed regardless of that deadline until `PR-MERGED`, `PR-CLOSED`, or `PR-UNREADABLE`; an exit with outstanding active PR-only specs is an expiry to re-arm. `WATCH-COMPLETE run: no active specs` confirms that none remain. PR-only polling uses `--pr-interval-seconds` (default 300 seconds); timed lanes retain the fast cadence. `RATE-LIMITED github: until=<epoch>` pauses GitHub reads for the primary reset or secondary retry interval while local supervision continues. `PR-UNREADABLE <spec>: #<number> reason=<reason>` retires only that PR-only spec after six consecutive polls return definitive identity/access failures (NOT_FOUND, HTTP 404, or Could not resolve to a PullRequest or Repository). Temporary 5xx, timeout and transport failures stay degraded and keep polling at the PR-only cadence; they never retire a PR-only spec. A timed spec whose degradation window is exhausted keeps its existing `lane-watch: <label>` diagnostic and retires for the current process only. Other active specs keep polling; if none remain active, the watcher exits 1. The next re-arm with the same state file reads that timed spec again and resumes supervision once the read heals; a still-failing read retires it again in that process. Surface stderr on exit 1 and re-arm only after the failing read is reconciled. An exhausted shared Herdr-list episode retires the affected local specs for that process; other specs continue. Reconcile a `PR-UNREADABLE` spec’s access or identity before explicitly starting a new watch state. This event is never readiness.",
        ),
    )
    for name, start, end, expected in skill_ranges:
        pin_range(errors, name, skill, start, end, expected)
    pin_range(
        errors,
        "Herdr whole watcher restatement",
        herdr,
        "For multi-lane Dev Loop runs, use only the orchestrate skill's",
        "process-ending convention.",
        "For multi-lane Dev Loop runs, use only the orchestrate skill's `assets/lane-watch.sh`, invoked as that file. Prefer the harness streaming monitor (Claude Code: `Monitor`) only when its command can reach both `gh` and `herdr`. If it is sandboxed from either CLI, run finite background Bash passes outside that sandbox with `--iterations <n>`, capture their output, and reuse the same `<git-common-dir>/dev-flow-v2/slates/<slate>/lane-watch.state` on every re-arm. Events surface at pass end, so the pass length bounds how long a lane can wait on an approval. On every watcher expiry or nonterminal pass exit, re-arm first, before any other tool call, with the same state file; then check lane staleness before other work. Never inline the watcher loop or write a substitute. On every other wakeup, first compare the current time with each lane's last observed change; read and act on any lane silent past the stall threshold before other work. Keep exactly one watcher per slate. Replace a streaming watcher by letting its monitor expire on the harness's own schedule (Claude Code: within 30 minutes) and re-arming; bounded Bash passes exit naturally after their iteration limit. For an early harness monitor-stop (Claude Code: `TaskStop` on that monitor's task), follow the orchestrate skill's process-ending convention.",
    )

    for name, document in (("orchestrator", skill), ("Herdr", herdr)):
        pin_absent(errors, f"{name} restart deletion", document, "Each session's monitors end with that session")
        pin_absent(errors, f"{name} live-watcher deletion", document, "While another live session's watcher runs, arm none.")

    pin_once(errors, "Herdr heartbeat recovery", herdr, "Periodic `HEARTBEAT` summaries cover all lanes; a missing heartbeat means re-arm the watcher and investigate its exit, rather than assuming the lanes are healthy.")
    pin_once(errors, "orchestrator heartbeat recovery", skill, "A missing heartbeat means re-arm the watcher and investigate its exit, rather than assuming the lanes are healthy.")
    pin_once(
        errors,
        "shared watcher-state declaration",
        skill,
        "- **Watcher state:** `<git-common-dir>/dev-flow-v2/slates/<slate-id>/lane-watch.state`.",
    )
    pin_watcher_state_homes(errors, root)
    if "operator confirm that the previous session, its writers, and its lane watcher have stopped" not in norm(skill):
        errors.append("slate-lock recovery: lane watcher stop confirmation is missing")

    pin_once(
        errors,
        "watcher monitor includes existing stderr diagnostics",
        skill,
        "`bash <skill-dir>/assets/lane-watch.sh --state-file <git-common-dir>/dev-flow-v2/slates/<slate>/lane-watch.state --registry "
        "<kickoff-registry-snapshot> <deadline> <agent:branch:nonce:owner/repo:report-path:lane-label>... 2>&1`",
    )
    pin_once(
        errors,
        "cloud watcher monitor includes existing stderr diagnostics",
        (root / "ai/skills/universal/orchestrate/references/cloud-lanes.md").read_text(),
        r"```sh bash <skill-dir>/assets/lane-watch.sh --state-file <git-common-dir>/dev-flow-v2/slates/<slate-id>/lane-watch.state \ "
        r"--registry <kickoff-registry-snapshot> <deadline> \ "
        "'<lane>:claude/<lane-slug>:<nonce>:<owner/repo>:cloud' 2>&1 ```",
    )

    pin_sentinels(errors, root, skill, template)
    if errors:
        print("\n".join(f"FAIL: {error}" for error in errors), file=sys.stderr)
        return 1
    print("watcher rule pins passed; all rendered sentinels matched lane-watch.sh")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
