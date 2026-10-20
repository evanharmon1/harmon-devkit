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


def pin_forbidden_terms(errors: list[str], name: str, scope: str) -> None:
    for word, expected in (("kill", 1), ("pkill", 1), ("killall", 0), ("xkill", 0)):
        count = len(
            re.findall(
                rf"(?<![A-Za-z0-9_]){word}(?![A-Za-z0-9_])", scope, re.IGNORECASE
            )
        )
        if count != expected:
            errors.append(
                f"{name}: negative pin for {word} expected {expected} mention(s), "
                f"found {count}"
            )

    for pattern, label in ((r"\bTaskStop\b", "TaskStop"), (r"\bmonitor[- ]stop\b", "monitor-stop")):
        if len(re.findall(pattern, scope, re.IGNORECASE)) != 1:
            errors.append(f"{name}: {label} must have one approval-gated mention")

    without_approval = re.compile(
        r"(?:TaskStop|monitor[- ]stop).{0,160}"
        r"(?:without|no|not\s+required|does\s+not\s+require|doesn't\s+require|"
        r"need\s+no|needs\s+no|requires\s+no|exempt)[^.]*approval|"
        r"(?:without|no|not\s+required|does\s+not\s+require|doesn't\s+require|"
        r"need\s+no|needs\s+no|requires\s+no|exempt)[^.]*approval.{0,160}"
        r"(?:TaskStop|monitor[- ]stop)",
        re.IGNORECASE,
    )
    if without_approval.search(scope):
        errors.append(f"{name}: monitor-stop exception lacks user approval")


def pin_sentinels(errors: list[str], root: Path, skill: str, template: str) -> None:
    expected = {
        "ready": "READY-<lane-label>",
        "handoff": "HANDOFF-<lane-label>",
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
    for kind in ("ready", "handoff", "blocked"):
        sentinel = f"{kind.upper()}-{lane}-{nonce}"
        if rendered.count(sentinel) != 1:
            errors.append(f"rendered template must contain {sentinel} exactly once")
        result = subprocess.run(
            ["bash", "-c", matcher, str(watcher), lane, nonce],
            input=f"previous line\n{sentinel}\n",
            text=True,
            capture_output=True,
            check=False,
        )
        if result.returncode != 0 or result.stdout.strip() != sentinel:
            errors.append(f"lane-watch.sh rejected rendered sentinel {sentinel}")


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {Path(sys.argv[0]).name} <repo-or-mutation-root>", file=sys.stderr)
        return 2
    root = Path(sys.argv[1]).resolve()
    skill = (root / "ai/skills/universal/orchestrate/SKILL.md").read_text()
    herdr = (root / "docs/guides/herdr.md").read_text()
    template = (root / "ai/skills/universal/orchestrate/assets/lane-brief.md").read_text()
    errors: list[str] = []

    skill_ranges = (
        (
            "orchestrator monitor invocation",
            "Use only `assets/lane-watch.sh` under the harness streaming monitor",
            "Never inline its loop, write a substitute, or run it as an unobserved background shell job.",
            "Use only `assets/lane-watch.sh` under the harness streaming monitor (Claude Code: `Monitor`). Invoke it as that file. The monitor is the session-lifetime persistent monitor primitive that streams its output. Never inline its loop, write a substitute, or run it as an unobserved background shell job.",
        ),
        (
            "orchestrator expiry order",
            "On every monitor expiry or exit notification before a terminal outcome",
            "If no persistent primitive is available, block instead of silently falling back to occasional manual polling.",
            "On every monitor expiry or exit notification before a terminal outcome, re-arm first, before any other tool call, with the same `--state-file`; then check lane staleness before other work. Never interpret monitor termination as human cancellation. If no persistent primitive is available, block instead of silently falling back to occasional manual polling.",
        ),
        (
            "orchestrator other wakeup",
            "On every other wakeup (a user message or monitor event)",
            "past the stall threshold before other work.",
            "On every other wakeup (a user message or monitor event), first compare the current time with each lane's last observed change; read and act on any lane silent past the stall threshold before other work.",
        ),
        (
            "orchestrator one-watcher and stop approval",
            "Keep exactly one watcher per slate.",
            "Never use `kill` or `pkill`.",
            "Keep exactly one watcher per slate. Replace a watcher by letting its monitor expire on the harness's own schedule (Claude Code: within 30 minutes) and re-arming. Early harness monitor-stop (Claude Code: `TaskStop` on that monitor's task) requires the user's explicit approval. Never use `kill` or `pkill`.",
        ),
    )
    skill_scopes = [
        pin_range(errors, name, skill, start, end, expected)
        for name, start, end, expected in skill_ranges
    ]
    herdr_rules = pin_range(
        errors,
        "Herdr whole watcher restatement",
        herdr,
        "For multi-lane Dev Loop runs, use only the orchestrate skill's",
        "Never use `kill` or `pkill`.",
        "For multi-lane Dev Loop runs, use only the orchestrate skill's `assets/lane-watch.sh` under the harness streaming monitor (Claude Code: `Monitor`), invoked as that file. The session-lifetime persistent monitor primitive streams its output. Never inline its loop, write a substitute, or run it as an unobserved background shell job. On every watcher expiry or exit notification before a terminal outcome, re-arm first, before any other tool call, with the same `<git-common-dir>/dev-flow-v2/slates/<slate>/lane-watch.state`; then check lane staleness before other work. On every other wakeup, first compare the current time with each lane's last observed change; read and act on any lane silent past the stall threshold before other work. Keep exactly one watcher per slate. Replace a watcher by letting its monitor expire on the harness's own schedule (Claude Code: within 30 minutes) and re-arming. Early harness monitor-stop (Claude Code: `TaskStop` on that monitor's task) requires the user's explicit approval. Never use `kill` or `pkill`.",
    )

    skill_supervision = norm(skill[skill.find("## Persistent supervision") :])
    for name, scope in (
        ("orchestrator", skill_supervision),
        ("Herdr", herdr_rules),
    ):
        pin_forbidden_terms(errors, name, scope)
    for name, document in (("orchestrator", skill), ("Herdr", herdr)):
        pin_absent(errors, f"{name} restart deletion", document, "Each session's monitors end with that session")
        pin_absent(errors, f"{name} live-watcher deletion", document, "While another live session's watcher runs, arm none.")

    pin_once(errors, "Herdr heartbeat recovery", herdr, "Periodic `HEARTBEAT` summaries cover all lanes; a missing heartbeat means re-arm the watcher and investigate its exit, rather than assuming the lanes are healthy.")
    pin_once(errors, "orchestrator heartbeat recovery", skill, "A missing heartbeat means re-arm the watcher and investigate its exit, rather than assuming the lanes are healthy.")
    pin_once(errors, "shared watcher-state path", skill, "- **Watcher state:** `<git-common-dir>/dev-flow-v2/slates/<slate>/lane-watch.state`.")
    if "operator confirm that the previous session, its writers, and its lane watcher have stopped" not in norm(skill):
        errors.append("slate-lock recovery: lane watcher stop confirmation is missing")

    pin_sentinels(errors, root, skill, template)
    if errors:
        print("\n".join(f"FAIL: {error}" for error in errors), file=sys.stderr)
        return 1
    print("watcher rule pins passed; all rendered sentinels matched lane-watch.sh")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
