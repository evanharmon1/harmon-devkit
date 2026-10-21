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
    pin_once(
        errors,
        "orchestrator sentinel form",
        skill,
        "Sentinels use the exact kind-first form `(READY|HANDOFF|BLOCKED)-<lane-label>-<nonce>`, "
        "matching `^(READY|HANDOFF|BLOCKED)-<lane-label>-<nonce>$`; labels and nonces "
        "contain only ASCII letters, digits, underscores and hyphens.",
    )
    pin_once(
        errors,
        "lane-brief sentinel form",
        template,
        "Terminal sentinels use the exact kind-first form `(READY|HANDOFF|BLOCKED)-<lane-label>-<nonce>`, "
        "matching `^(READY|HANDOFF|BLOCKED)-<lane-label>-<nonce>$`; labels and nonces "
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
    expected_kinds = {"READY", "HANDOFF", "BLOCKED"}
    actual_kinds = {token.partition("-")[0] for token in sentinel_tokens}
    if len(sentinel_tokens) != 3 or actual_kinds != expected_kinds:
        errors.append(
            "rendered template must expose one backticked READY, HANDOFF, and BLOCKED token"
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
            "Never use `kill`, `pkill`, `killall`, or `xkill`.",
            "Keep exactly one watcher per slate. Replace a watcher by letting its monitor expire on the harness's own schedule (Claude Code: within 30 minutes) and re-arming. Early harness monitor-stop (Claude Code: `TaskStop` on that monitor's task) requires the user's explicit approval. Never use `kill`, `pkill`, `killall`, or `xkill`.",
        ),
        (
            "orchestrator watcher deadline",
            "Pass the watcher the latest `{{deadline}}`",
            "then re-arm only for lanes with a later deadline.",
            "Pass the watcher the latest `{{deadline}}` among the slate's live lanes, never the earliest: `lane-watch.sh` takes one deadline, so the earliest would stop supervising every later lane and make each re-arm exit at once. A lane past its own deadline is capped by the dispatch-time clock check below, not by the watcher, and its spec leaves the watcher at the next re-arm. A watcher exit reporting `WALLCLOCK run: deadline <deadline> reached` is a terminal outcome for every lane it watched, not an expiry: do not re-arm with that deadline; record each lane's capped transition and render its blocker first, then re-arm only for lanes with a later deadline.",
        ),
    )
    for name, start, end, expected in skill_ranges:
        pin_range(errors, name, skill, start, end, expected)
    pin_range(
        errors,
        "Herdr whole watcher restatement",
        herdr,
        "For multi-lane Dev Loop runs, use only the orchestrate skill's",
        "Never use `kill`, `pkill`, `killall`, or `xkill`.",
        "For multi-lane Dev Loop runs, use only the orchestrate skill's `assets/lane-watch.sh` under the harness streaming monitor (Claude Code: `Monitor`), invoked as that file. The session-lifetime persistent monitor primitive streams its output. Never inline its loop, write a substitute, or run it as an unobserved background shell job. On every watcher expiry or exit notification before a terminal outcome, re-arm first, before any other tool call, with the same `<git-common-dir>/dev-flow-v2/slates/<slate>/lane-watch.state`; then check lane staleness before other work. On every other wakeup, first compare the current time with each lane's last observed change; read and act on any lane silent past the stall threshold before other work. Keep exactly one watcher per slate. Replace a watcher by letting its monitor expire on the harness's own schedule (Claude Code: within 30 minutes) and re-arming. Early harness monitor-stop (Claude Code: `TaskStop` on that monitor's task) requires the user's explicit approval. Never use `kill`, `pkill`, `killall`, or `xkill`.",
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

    pin_sentinels(errors, root, skill, template)
    if errors:
        print("\n".join(f"FAIL: {error}" for error in errors), file=sys.stderr)
        return 1
    print("watcher rule pins passed; all rendered sentinels matched lane-watch.sh")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
