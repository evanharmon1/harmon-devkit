#!/usr/bin/env python3
"""PreToolUse(Bash): approve only three complete review-trigger commands.

Active on the host and dev profile. Bot/agent profiles return no decision:
those unattended postures use their managed permissions rather than this
interactive prompt-reduction hook. Profile comes from the hook environment.
Non-github.com GH_HOST settings also return no decision.

Only literal gh pr comment calls with a positive PR number and one fixed
review body, or the installed broker's trigger (optionally via bash), qualify.
Flags may be reordered but never repeated or extended. The repository comes
from CLAUDE_PROJECT_DIR's origin, never from the command. Broker realpaths
must equal the installed broker path in that project, unresolved, so a symlink
there cannot stand in for an outside file. The in-project broker's bytes are
trusted the way the existing Bash(task:*) allow already trusts in-repo
Taskfile content. Unsupported syntax, missing metadata, and errors stay
silent so normal permissions apply. This hook never executes the submitted
command.

Use shlex for quoted words, after conservatively rejecting every shell
expansion/operator/escape/comment character, even within quotes. This small
literal subset avoids treating shell execution syntax as innocent argv.
Tests: task test:review-trigger-allow.
"""

import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys

BROKER = Path(".claude/skills/integrate/assets/gh-write-broker.sh")
BODIES = {"/gemini review", "@" + "claude" + " review"}
# ^ is a zsh EXTENDED_GLOB operator; adjacent quotes are where zsh RC_QUOTES
# reads a literal quote that shlex would drop.
UNSAFE = re.compile(r"[\x00-\x1f\x7f$`\\;&|<>(){}*?\[\]#!~^]|''|\"\"")
NUMBER = re.compile(r"[1-9][0-9]*")
# A repository name may start with a dot (an organization's .github), but is
# never . or .. alone.
REPOSITORY = re.compile(r"[A-Za-z0-9_-][A-Za-z0-9_.-]*/(?!\.\.?$)[A-Za-z0-9_.-]+")


def git(project, *args):
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    result = subprocess.run(
        ["git", "-C", str(project), *args], env=env,
        capture_output=True, text=True, timeout=5, check=True,
    )
    return result.stdout


def repository(project):
    # The configured URL, not get-url's: a url.insteadOf rewrite is transport.
    # Origin's configuration is the trust root: whoever can change it can point
    # it anywhere, so the hook adds no checks against its own configuration.
    remote = git(project, "config", "--get", "remote.origin.url").strip()
    # GitHub HTTPS and SSH transport spellings; local/file remotes and
    # ambiguous hosts/credentials do not establish a GitHub repository.
    match = re.fullmatch(
        r"(?:https://github\.com/|git@github\.com:|"
        r"ssh://git@github\.com/|ssh://git@ssh\.github\.com(?::443)?/)(.+)", remote,
    )
    if not match:
        return None
    name = match[1].removesuffix(".git")
    return name if REPOSITORY.fullmatch(name) else None


def flags(words, expected):
    if len(words) != 2 * len(expected):
        return None
    values = {}
    for key, value in zip(words[::2], words[1::2]):
        if key not in expected or key in values:
            return None
        values[key] = value
    return values if set(values) == expected else None


def broker_in_repository(word, cwd, project):
    # Bare executable names are PATH lookups, not relative file paths.
    if "/" not in word:
        return False
    path = Path(word)
    resolved = (path if path.is_absolute() else cwd / path).resolve(strict=True)
    if not resolved.is_file():
        return False
    # Compare against the un-resolved expected path: a symlink at the installed
    # broker location must not turn an outside file into the broker.
    return resolved == project / BROKER


def allows(command, cwd, project):
    if not isinstance(command, str) or UNSAFE.search(command):
        return False
    lexer = shlex.shlex(command, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    lexer.commenters = ""
    words = list(lexer)
    if words[:3] == ["gh", "pr", "comment"]:
        if len(words) < 4 or not NUMBER.fullmatch(words[3]):
            return False
        values = flags(words[4:], {"--repo", "--body"})
        return bool(values and values["--body"] in BODIES
                    and values["--repo"] == repository(project))
    if words[:1] == ["bash"]:
        words = words[1:]
    # A shell reads a NAME=value or NAME+=value word as an assignment, zsh
    # expands a leading = to a command path, and bash reads a leading -/+ word
    # as an option: none runs the path the hook resolved. A broker path that
    # contains = therefore gets no decision (the prompt applies).
    if not words or "=" in words[0] or words[0][:1] in ("-", "+"):
        return False
    if len(words) < 2 or words[1] != "trigger":
        return False
    values = flags(words[2:], {"--repo", "--pr"})
    return bool(values and NUMBER.fullmatch(values["--pr"])
                and values["--repo"] == repository(project)
                and broker_in_repository(words[0], cwd, project))


def main():
    if os.environ.get("FOREMAN_DEVCONTAINER", "").strip().lower() in {"bot", "agent"}:
        return
    host = os.environ.get("GH_HOST", "").strip().lower()
    if host and host != "github.com":
        return
    try:
        payload = json.load(sys.stdin)
        if payload.get("tool_name") != "Bash":
            return
        command = payload["tool_input"]["command"]
        # Cheap shape check first: this hook sees every Bash call.
        if not isinstance(command, str) or not (
                command.startswith("gh pr comment ") or " trigger " in command):
            return
        project = Path(os.environ["CLAUDE_PROJECT_DIR"])
        cwd = Path(payload["cwd"])
        if not project.is_absolute() or not cwd.is_absolute():
            return
        project = project.resolve(strict=True)
        # CLAUDE_PROJECT_DIR must actually identify a project root.
        if Path(git(project, "rev-parse", "--show-toplevel").strip()).resolve() != project:
            return
        if not allows(command, cwd, project):
            return
    except Exception:
        return  # no decision, never fail open
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse", "permissionDecision": "allow",
        "permissionDecisionReason": "Exact review trigger for this repository",
    }}))


if __name__ == "__main__":
    main()
