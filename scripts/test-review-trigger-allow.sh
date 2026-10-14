#!/usr/bin/env bash
# Exact review-trigger hook regression matrix, including its registered command.
# Fixture git commits are isolated from global hooks/signing; submitted command
# strings are NEVER executed. Run via task test:review-trigger-allow.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile

source = Path.cwd()
env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
env.update(GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_SYSTEM="/dev/null",
           GIT_CONFIG_NOSYSTEM="1", FOREMAN_DEVCONTAINER="dev")
env.pop("GH_HOST", None)
claude_body = "@" + "claude" + " review"
suffix = Path(".claude/skills/integrate/assets/gh-write-broker.sh")
count = 0


def git(path, *args):
    return subprocess.run(["git", "-C", str(path), *args], env=env,
                          capture_output=True, text=True, check=True).stdout.strip()


def fixture(path):
    path.mkdir()
    git(path, "init", "-q", "-b", "main")
    git(path, "config", "core.hooksPath", "/dev/null")
    git(path, "-c", "user.name=t", "-c", "user.email=t@t",
        "-c", "commit.gpgsign=false", "commit", "-q", "--allow-empty", "-m", "chore: fixture")
    git(path, "remote", "add", "origin", "https://github.com/example/project.git")
    broker = path / suffix
    broker.parent.mkdir(parents=True)
    broker.write_text("#!/bin/sh\nexit 99\n")
    return broker


def expect(hook, command, allow=False, project=None, cwd=None, profile="dev", payload=None, gh_host=None):
    global count
    project = root if project is None else project
    cwd = root if cwd is None else cwd
    data = {"tool_name": "Bash", "cwd": str(cwd), "tool_input": {"command": command}}
    hook_env = dict(env, CLAUDE_PROJECT_DIR=str(project), FOREMAN_DEVCONTAINER=profile)
    if gh_host is not None:
        hook_env["GH_HOST"] = gh_host
    result = subprocess.run(["python3", str(hook)], env=hook_env, text=True,
                            input=json.dumps(data) if payload is None else payload,
                            capture_output=True, check=True, timeout=15)
    if allow:
        parsed = json.loads(result.stdout)
        assert parsed["hookSpecificOutput"]["hookEventName"] == "PreToolUse"
        assert parsed["hookSpecificOutput"]["permissionDecision"] == "allow"
    else:
        assert result.stdout == "", (hook, command, result.stdout)
    count += 1


with tempfile.TemporaryDirectory(prefix="review-trigger-test-") as directory:
    tmp = Path(directory).resolve()
    root = tmp / "project"
    broker = fixture(root)
    eq_root = tmp / "issue=1557"
    fixture(eq_root)
    wt = tmp / "worktree with space"
    git(root, "worktree", "add", "-q", "-b", "lane", str(wt))
    wt_broker = wt / suffix
    wt_broker.parent.mkdir(parents=True)
    wt_broker.write_text("#!/bin/sh\nexit 99\n")
    foreign = tmp / "foreign"
    foreign_broker = fixture(foreign)  # same origin is insufficient: different common dir
    outside = tmp / "outside.sh"
    outside.write_text("#!/bin/sh\nexit 99\n")
    symlink = root / "outside-link.sh"
    symlink.symlink_to(outside)
    inside_link = root / "broker-link.sh"
    inside_link.symlink_to(broker)
    # Directories whose names a shell reads as an assignment or an option.
    for name in ["PATH=evil:z", "PATH+=:evil:z", "-o", "+o"]:
        (root / name).mkdir()
    comment = "gh pr comment 7 --repo example/project --body '/gemini review'"
    trigger = f"{broker} trigger --repo example/project --pr 7"
    hooks = [source / ".claude/hooks/review-trigger-allow.py",
             source / "template/.claude/hooks/review-trigger-allow.py"]
    # Consumers have only the root copy of the hook, not a template directory.
    hooks = [hook for hook in hooks if hook.exists()]
    for hook in hooks:
        for body in ["/gemini review", claude_body]:
            for quote in ["'", '"']:
                for options in [f"--repo example/project --body {quote}{body}{quote}",
                                f"--body {quote}{body}{quote} --repo 'example/project'"]:
                    expect(hook, "gh pr comment 7 " + options, True)
        for path in [str(broker), ".claude/skills/integrate/assets/gh-write-broker.sh",
                     "./.claude/skills/integrate/assets/gh-write-broker.sh", str(inside_link)]:
            for prefix in ["", "bash "]:
                for options in ["--repo example/project --pr 7", "--pr 7 --repo example/project"]:
                    expect(hook, prefix + shlex.quote(path) + " trigger " + options, True)
        expect(hook, "./.claude/skills/integrate/assets/gh-write-broker.sh trigger --pr 7 --repo example/project",
               cwd=wt)
        # A second worktree is not the active project, even with the same origin.
        expect(hook, shlex.quote(str(wt_broker)) + " trigger --repo example/project --pr 7")
        for gh_host in [None, "", "github.com", "GitHub.com"]:
            expect(hook, comment, True, gh_host=gh_host)
            expect(hook, trigger, True, gh_host=gh_host)
        expect(hook, comment, gh_host="ghe.example.com")
        expect(hook, trigger, gh_host="ghe.example.com")
        for profile in ["", "dev"]:
            expect(hook, comment, True, profile=profile)
        for profile in ["bot", "agent", "Agent"]:
            expect(hook, comment, profile=profile)
            expect(hook, trigger, profile=profile)
        attacks = [
            trigger + " --repo another/project --pr 8",
            trigger + " --repo example/project", trigger + " --pr 7",
            comment + " --repo another/project", comment + " --body '/gemini review'",
            "gh pr comment https://github.com/another/project/pull/7 --repo example/project --body '/gemini review'",
            comment.replace("example/project", "another/project"),
            trigger.replace("example/project", "another/project"),
            comment.replace("pr comment", "pr review"),
            "gh api repos/example/project/issues/7/comments -f body=x",
            "bash -c 'rm -rf x' " + trigger, "env X=1 " + comment,
            "X=1 " + trigger, "command " + comment, "timeout 1 " + comment,
            "bash " + comment, comment + " ; rm -rf x", comment + " && echo x",
            comment + " | cat", comment + " > x", comment + " # note",
            comment + "\necho x", comment + " <<EOF\nx\nEOF",
            comment.replace(" 7 ", " $(echo 7) "),
            comment.replace(" 7 ", " `echo 7` "),
            comment.replace(" 7 ", " $N "),
            comment.replace(" 7 ", " 0 "), comment.replace(" 7 ", " -1 "),
            comment.replace(" 7 ", " 7x "), trigger.replace("--pr 7", "--pr 0"),
            comment + " stray", trigger + " stray", "'" + comment,
            trigger.replace(" trigger ", " reply "),
            trigger.replace(" trigger ", " request-review "),
            trigger + " --finder gemini", trigger + " --body arbitrary",
            f"{outside} trigger --repo example/project --pr 7",
            f"{symlink} trigger --repo example/project --pr 7",
            f"{foreign_broker} trigger --repo example/project --pr 7",
            "gh-write-broker.sh trigger --repo example/project --pr 7",
            "PATH=evil:z/../" + str(suffix) + " trigger --repo example/project --pr 7",
            "bash PATH=evil:z/../" + str(suffix) + " trigger --repo example/project --pr 7",
            "bash -o/../" + str(suffix) + " trigger --repo example/project --pr 7",
            "bash +o/../" + str(suffix) + " trigger --repo example/project --pr 7",
            # zsh: RC_QUOTES reads '' as a literal quote; EXTENDED_GLOB reads ^.
            "bash '.''" + str(suffix)[1:] + "' trigger --repo example/project --pr 7",
            comment.replace("'/gemini review'", "'/gemini'' review'"),
            comment.replace("'/gemini review'", '"/gemini"" review"'),
            comment.replace("example/project", "example/proj^ect"),
            " " + comment,
            "=" + trigger,
            "PATH+=:evil:z/../" + str(suffix) + " trigger --repo example/project --pr 7",
        ]
        for body in ["/gemini review", claude_body]:
            base = "gh pr comment 7 --repo example/project --body " + shlex.quote(body)
            attacks.extend([base.replace(shlex.quote(body), "'arbitrary'"),
                            base.replace(shlex.quote(body), shlex.quote(body + " extra"))])
            for flag in ["--edit-last", "--delete-last", "--body-file x", "-F x",
                         "--editor", "--web"]:
                attacks.extend([base + " " + flag,
                                base.replace("7 --repo", "7 " + flag + " --repo")])
        for command in attacks:
            expect(hook, command)
        for remote in ["git@github.com:example/project.git", "ssh://git@github.com/example/project.git",
                       "ssh://git@ssh.github.com/example/project.git",
                       "ssh://git@ssh.github.com:443/example/project.git",
                       "https://github.com/example/project"]:
            git(root, "remote", "set-url", "origin", remote)
            expect(hook, comment, True)
        for remote in [str(tmp / "local.git"), "https://evil.example/example/project.git"]:
            git(root, "remote", "set-url", "origin", remote)
            expect(hook, comment)
        # A repository name may start with a dot, but is never . or .. alone.
        git(root, "remote", "set-url", "origin", "https://github.com/example/.github.git")
        expect(hook, comment.replace("example/project", "example/.github"), True)
        for name in [".", ".."]:
            git(root, "remote", "set-url", "origin", f"https://github.com/example/{name}.git")
            expect(hook, comment.replace("example/project", f"example/{name}"))
        git(root, "remote", "set-url", "origin", "https://github.com/example/project.git")
        # --repo must match origin exactly; another spelling falls back to the prompt.
        for command in [comment, trigger]:
            expect(hook, command.replace("example/project", "Example/Project"))
        # A broker path containing = (here the checkout path) gets no decision.
        eq_broker = eq_root / suffix
        expect(hook, f"{eq_broker} trigger --repo example/project --pr 7", project=eq_root, cwd=eq_root)
        # The configured URL counts, not an insteadOf rewrite of it.
        git(root, "remote", "set-url", "origin", "https://github.com/example/project.git")
        git(root, "config", "url.https://github.com/another/.insteadOf", "https://github.com/example/")
        expect(hook, comment, True)
        git(root, "config", "--unset", "url.https://github.com/another/.insteadOf")
        expect(hook, comment, payload="not json")
        expect(hook, comment, payload='{"tool_name":"Bash","tool_input":null}')
        expect(hook, comment, payload=json.dumps({"tool_name": "Read"}))
        expect(hook, comment, project=tmp / "missing")
        expect(hook, comment, project=broker.parent)
        # Replacing the broker at its installed location with an outside symlink
        # must not approve merely because the expected path resolves there too.
        broker.unlink()
        broker.symlink_to(outside)
        expect(hook, trigger)
        broker.unlink()
        broker.write_text("#!/bin/sh\nexit 99\n")

    # Exercise actual settings wiring and its failure fallback. Copy the tested
    # hook into the fixture so CLAUDE_PROJECT_DIR points at a real Git project.
    installed = root / ".claude/hooks/review-trigger-allow.py"
    installed.parent.mkdir(parents=True)
    installed.write_bytes(hooks[0].read_bytes())
    settings = source / ".claude/settings.json"
    entries = json.loads(settings.read_text())["hooks"]["PreToolUse"]
    commands = [item["command"] for entry in entries if entry["matcher"] == "Bash"
                for item in entry["hooks"] if "review-trigger-allow.py" in item.get("command", "")]
    assert len(commands) == 1
    registered = commands[0]
    twin = source / "template/.claude/settings.json.jinja"
    if twin.exists():
        # The command line is plain JSON within the template's jinja structure.
        lines = [line.strip().rstrip(",") for line in twin.read_text().splitlines()
                 if '"command"' in line and "review-trigger-allow.py" in line]
        assert len(lines) == 1 and json.loads("{" + lines[0] + "}")["command"] == registered
    payload = json.dumps({"tool_name": "Bash", "cwd": str(root), "tool_input": {"command": comment}})
    for broken in [False, True]:
        if broken:
            installed.write_text("raise RuntimeError('fixture failure')\n")
        result = subprocess.run(["bash", "-c", registered], input=payload, text=True,
                                env=dict(env, CLAUDE_PROJECT_DIR=str(root)), capture_output=True, check=True)
        if broken:
            assert result.stdout == ""
        else:
            assert json.loads(result.stdout)["hookSpecificOutput"]["permissionDecision"] == "allow"
        count += 1
print(f"review-trigger-allow OK: {count} exact-command, attack, profile and failure cases")
PY
