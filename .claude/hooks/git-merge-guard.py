#!/usr/bin/env python3
"""PreToolUse(Bash) hook: gate merges and default-branch pushes locally.

Python 3 (`python3` on PATH) is a hard prerequisite for this hook. If the
interpreter is unavailable or the guard crashes, the registered command uses
the same generic fail-closed ask: "git-merge-guard failed to run".

Ask before gh pr merge, remote gh repo sync, protected pushes and git
merge/pull outside the branch-aware allowlist. gh api fails closed: only
proved reads and a short safe-write allowlist stay silent. REST safe writes
match undecoded paths; GraphQL mutations require every root field to be safe.
Unknown API writes and evaluator-fed API/sync strings ask. Presentation values
may be dynamic only inside double quotes; operation-controlling inputs must
be literal. Explicit GET/HEAD fields are read parameters. Short-option values
consume their cluster suffix. Unparseable query controls ask.
Pull-request reviews ask unless their event is proved COMMENT or REQUEST_CHANGES,
in CLI, REST and GraphQL forms. Missing, dynamic and unreadable review events
ask too: an approval can satisfy the code-owner gate and complete auto-merge.
Review argument counts require literal words or literal text with quoted command
substitutions; parameter expansions in review arguments/fields ask even when
quoted. Parameters inside a command-substitution body belong to its nested command.

Replaces the `Bash(git merge)` / `Bash(git merge:*)` permissions.ask rules,
which prompt on every merge (including routine catch-up merges of main into
a lane branch) yet miss `git -C <dir> merge` entirely, because permission
rules match literal command prefixes.

Profile scope: the guard protects interactive, human-supervised sessions --
the host and the dev devcontainer. With `FOREMAN_DEVCONTAINER` set to `bot`
or `agent` it returns no decision for any command, real merges included:
unattended lanes catch up to main with `git merge` routinely, a prompt there
is effectively a denial, and the GitHub "Protect Main" ruleset is the
boundary (no direct or force push to main; a merge into it needs code-owner
approval and green required checks). The variable is read from the hook's own
environment, which a Bash command cannot change.

Invariant: the hook returns "ask" for every command that invokes, or could
invoke, a git merge or pull, unless every merge segment is an allowlisted
shape in a verified checkout (a feature branch, or a proven fast-forward sync
of its default). The command is parsed the way bash reads it -- words, quotes,
operators, comments, heredocs, command substitutions -- and a merge is:

  * a `git` command (any path, any case, `git.exe`) whose subcommand slot,
    after git's global options (`-C <dir>`, `-c <kv>`, ...), is `merge` or
    `pull`, wherever it appears in a command's words (`command git merge`,
    `timeout 9 git pull`, `xargs git merge`, `ssh host git pull`);
  * a git call whose subcommand slot is not a literal (`git $x`, `git m*rge`,
    `git $'\\x6d...'`), could be filled in by `xargs`/`parallel` (a missing
    slot, a replacement string such as `xargs -I X git X`, `:::` arguments),
    or is a one-off alias whose expansion could merge (`git -c alias.m=merge m`,
    a `!` shell alias, or one whose `-c` value or source is not literal);
  * a command whose name is not a literal -- an expansion, substitution or
    field-split word (`$(printf 'git merge main')`, `git${IFS}merge`,
    `"$SHELL" <<< ...`, `xargs -I{} {}`) -- when the line mentions merge/pull,
    or when `merge`/`pull` follows it (`$G merge feat`);
  * the dashed `git-merge`/`git-pull` executables run as a command, after any
    depth of wrappers (`find -exec env X=1 git-merge`, `coproc`, an
    assignment whose value expands);
  * any of the above inside text that runs: `$(...)` (and `$((...))`, which
    bash also reads as one), backticks, `<(...)`, substitutions inside
    `${...}` or an unquoted heredoc, the string after a `-c` or `-Command`
    option of any program but a search tool, whose `-c` counts (`bash -c`,
    `csh -c`, `su -c`, `pwsh -Command`;
    `$'...'` strings decoded first), the arguments of `eval`, `ssh`,
    `watch`, `herdr` (`pane run`) or `env -S` (with its trailing arguments),
    `cmd /c`, a heredoc, here-string or pipe fed to a shell, `sudo -s`/`-i`
    or `parallel` (whatever their arguments); `$"..."` locale strings are not
    literal; `${...}` operators are not modelled, so a
    `${...}` that mentions merge/pull asks; a `trap` action counts too;
  * any mention of merge/pull anywhere in a command line that also runs an
    evaluator (a shell, `eval`, `ssh`, `trap`, `watch`, `herdr pane run`, `parallel`,
    `sudo -s`/`-i`, `env -S`): their option and
    input shapes (`bash -C -c`, `env -S'...'`, a pipe into `if ...; then sh`)
    are open-ended, so the word test covers what the parser does not, except
    for the closed literal mention language described below.

Everything else is data and stays silent: quoted text and heredoc bodies not
handed to an evaluator (`git commit -m "catch-up merge"`, report appends),
search patterns (`grep -n 'merge base'`), and other subcommands and flags that
merely hold the word (`git merge-base`, `merge-tree`, `mergetool`,
`--merge-base-policy`). A command the parser cannot read (an unbalanced quote)
asks if it mentions git, merge or pull at all -- bash may still run the lines
before the error -- so a parser gap costs a prompt, not a silent merge.

The silent (normal permission flow) shapes retain these fully literal,
unquoted single commands in a verified feature-branch checkout:

    git merge <ref>, with any of --no-edit --no-ff --ff --ff-only
    git merge --continue | git merge --quit, alone
    git pull [<remote> [<ref>]], with --ff-only and/or --no-rebase,
             and optionally --no-edit

Payloads with no base-test risk mention (for example, `bash -c 'task verify'`)
are already silent under the base word test. For a payload with a merge/pull
mention, the literal-read proof can suppress that ask only for the complete
bash/sh -c form with one literal quoted payload, or a heredoc with a quoted
uppercase delimiter, and only when every simple command belongs to a closed
read allowlist and every word is an inert literal. Allowed commands are echo, printf, cat,
head, tail, wc, grep, jq, sort, uniq, cut; gh is limited to pr view/list/status/
checks/diff, issue view/list/status, and repo view/list, with the existing gh
operation proof still required. Literal paths and data may contain git, merge
or pull. Semicolons, newlines and pipes connect only proved commands. No
assignments, expansions, escapes, comments, redirects, here-strings, descriptor
paths, extra shell arguments, nested evaluators or other syntax qualifies.
Sed is omitted; printf assignment formats, sort execution/output options and
uniq output operands are excluded; grep takes only fixed short flags (ugrep's
--filter/--pre run commands) and gh no --web/-w (it launches $BROWSER).
Git/gh operation checks still run. Unknown syntax fails the
complete proof, so an unlisted bash input channel cannot qualify. Payloads
failing this proof, and script-file invocations, keep the base mention
fallback: they ask only on a merge/pull word. See #1844.

Flags are a set, in any order and position. Fast-forward-only merges/pulls
also support a literal absolute `git -C <dir>` or preceding `cd <dir> &&`,
and compounds joined by &&, ||, ; or |. Every merge segment must pass; other
segments are limited to true, false, git status and a named-remote git fetch
whose configured refspecs all write under refs/remotes/<selected-remote>/.
An explicit git -C <dir> status companion remains outside this grammar.
Unknown commands, evaluators, expansions, quoting, redirects and path
traversal ask. A cd must
be absolute, exist, contain no .. component and be followed by &&. Both
-C and cd paths allow only literal path characters, never shell metacharacters.

The checkout must be on a named branch other than main/master and every
remote's resolved default; at least one remote HEAD must resolve. Otherwise
only --ff-only syncs from that branch's own configured upstream are silent:
`git merge --ff-only origin/main`, `git pull --ff-only [<remote>]`, or
`git pull --ff-only <remote> refs/heads/<current-branch>`. An explicit short
pull branch name asks: a remote tag may shadow it, and the hook cannot inspect
the remote. Detached/unreadable checkouts and unmatched refs ask. Git's
upstream must be refs/remotes/<remote>/<current-branch>, and its configured
merge source must have exactly one value, refs/heads/<current-branch>.
A merge operand must resolve unambiguously to that upstream, with no
same-named tag or local branch.
Beside any other git segment, a default-branch merge must use the full
refs/remotes/<remote>/<branch> operand; fetch may import short-name shadows.
Remote HEAD caches are local;
refresh them with `git remote set-head <remote> --auto` after a default rename.

(The decision to remove guard-process-kill,
https://github.com/evanharmon1/harmon-init/blob/main/docs/decisions/2026-09-02-remove-guard-process-kill-hook.md,
explains why an open-ended "is this safe?" classifier was rejected.)

Known limits, shared with or no worse than the rules it replaces: it does
not see through git aliases, scripts (`./merge-main.sh` and `sh ./merge-main.sh`
alike), interpreters running git through their own APIs (`python3 -c` with
`subprocess`), or shell functions and aliases from the user's profile (an
alias that checks out main and pulls, one that runs `gh pr merge --auto`, one
that pushes the current branch) -- nor through deliberate obfuscation that
hides the `git` word itself (a variable as the whole command, brace expansion
such as `{git,merge} feat`, or a glob such as `gi[t]`); it is a backstop
against mistakes, not an adversarial boundary. A `case` pattern inside `$(...)`
can end the substitution early. An unquoted `git merge` in another command's
arguments (`echo git pull`) asks. gh at a command position is classified
fail-closed. Outside command position, a gh word is data unless a following
word in the same simple command is nonliteral or literally pr, api or repo;
then it receives the full classification too. This covers unlisted wrappers
without gating ordinary data words. `echo gh pr merge 1` still asks, by design.
The hook is the primary local merge gate; `permissions.ask` rules remain a
prefix-matching backstop when hooks do not run. API classification proves a
read or an explicitly safe write; there is no dangerous-operation denylist.
Normalized REST paths remain undecoded so encoded separators cannot forge an
allowlisted route. Unknown GraphQL mutation fields and unreadable controlling
inputs ask. Append-mode API feeders and evaluated API/sync strings ask.
All push forms share one proof: the destination ref equals the current
branch's own name, and that name is not the destination repository's default.
Config-driven ref mappings and repository redirections invalidate that proof;
explicit src:dst proves only the ref, never a redirected repository. HEAD uses
the same colon-less proof as the branch name. Every configured value is read.
Compounds use the unchanged companion grammar.
`git reset --hard`, `git restore` and
`git checkout -- .` discard the same conflict resolutions `git merge --abort`
would, and this hook does not see them. Nor does it see the commands that
advance main outside the guarded entry points: `git fetch . feat:main`,
`git branch -f main feat` and
`git update-ref refs/heads/main`. Direct `git merge-recursive` and `git merge-file`
are silent too: they write the index or a file but create no commit and move
no ref, so nothing lands on main. `git pull --rebase` is not silent,
because it can rewrite already-pushed feature-branch commits; neither is a
`git pull` that names no mode, because `pull.rebase` can make it a rebase. It
trusts the local `refs/remotes/<remote>/HEAD` cache -- after a remote renames
its default branch, run `git remote set-head <remote> --auto` (main/master
stay protected regardless). A
hook "allow" cannot override a permissions.ask rule, so this hook only ever
adds prompts.

It runs only where Claude Code runs hooks. `claude --bare` and the
`disableAllHooks` setting skip it, and with the `git merge` ask rules removed
nothing prompts there; the devcontainer's settings allow every `git` command.
Nothing in this repository runs Claude that way. The enforcement that does
not depend on the client is the GitHub "Protect Main" ruleset, which refuses
the push (maintainer decision, challenge round 3).

It checks the branch before the command starts, not while it runs: another
pane that switches the same checkout in between is not seen. Lanes merge in
their own worktrees, which no other session checks out.

Tests: scripts/test-git-merge-guard.sh (run by `task test:hooks`).
Design and rationale: evanharmon1/harmon-init#1435, evanharmon1/harmon-init#1523.
"""

import json
import os
import re
import subprocess
import sys
from urllib.parse import urlsplit

PROFILE_VAR = "FOREMAN_DEVCONTAINER"
UNGUARDED_PROFILES = {"bot", "agent"}
PROTECTED = {"main", "master"}
MERGE_WORDS = {"merge", "pull"}
# The dashed executables under `git --exec-path`, callable by full path.
DASHED = {"git-merge", "git-pull", "git-push"}
MERGE_FLAGS = {"--no-edit", "--no-ff", "--ff", "--ff-only"}
PULL_FLAGS = {"--ff-only", "--no-edit", "--no-rebase"}
# A silent pull must name its mode: with `pull.rebase` or `branch.<name>.rebase`
# set, a bare `git pull` rebases and rewrites the branch.
# `git -c pull.rebase=true pull --ff-only` on a diverged feature branch aborts
# ("Not possible to fast-forward") and leaves the branch unchanged (verified
# 2026-09-30, git 2.55.0), so `--ff-only` is safe even with `pull.rebase` set.
PULL_NO_REWRITE = {"--ff-only", "--no-rebase"}
# `--abort` is deliberately absent: it resets the index and worktree and can
# discard in-progress conflict resolutions (same class as `git reset --hard`).
# `--quit` leaves the index and worktree alone (unlike `--abort`) and saves
# the autostash, which is why worktree-rm.sh asks for it after an interrupted
# merge.
SOLO_FLAGS = {"--continue", "--quit"}
REF = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/-]*$")
# A mention of merge/pull as a word; used only where the parser cannot say
# what runs (an unreadable command, a shell reading a pipe). `merge-base` and
# `merge-tree` are read-only plumbing; prose like `pull-requests` is not a word.
MENTION = re.compile(
    r"(?<![\w-])merge(?!-(?:base|tree)(?![\w-]))(?!\w)"
    r"|(?<![\w-])pull(?![\w-])"
    r"|(?<![\w-])git-(?:merge|pull)(?!-guard\b)(?!\w)",
    re.I,
)
GIT_MENTION = re.compile(r"(?<![\w-])git(?![\w-])", re.I)
GIT_VALUE_OPTIONS = {
    "-C",
    "-c",
    "--git-dir",
    "--work-tree",
    "--namespace",
    "--attr-source",
    "--shallow-file",
    "--config-env",
    "--super-prefix",
}
# Shells: they read a script from stdin, and their presence puts a command
# line under the word test. `busybox` is not one: it is a wrapper that runs
# the applet named next, and `busybox sh` is caught by `sh`. `.` and `source`
# run a file in the current shell (`. /dev/stdin <<< ...`), so they count.
SHELLS = {
    ".", "ash", "bash", "cmd", "csh", "dash", "elvish", "fish", "ksh", "mksh",
    "nu", "oksh", "osh", "powershell", "pwsh", "script", "sh", "su", "tcsh",
    "source", "xonsh", "yash", "zsh",
}
# An option whose next word is read as a script, for any program. Case
# matters: `-C` is noclobber in bash and zsh, not a script.
SCRIPT_OPTION = re.compile(r"^(?:-[A-Za-z]*c[A-Za-z]*|(?i:-command|--command))$")
# Programs whose remaining arguments, joined, are run as a command line.
# `trap ACTION SIGNAL...` runs ACTION later; the signal names parse as harmless words.
JOINERS = {"eval", "ssh", "trap", "watch"}
# Programs that take a command in their arguments; what follows them is at
# command position for the dashed-executable and stdin-shell checks.
WRAPPERS = {
    "builtin", "busybox", "caffeinate", "chronic", "coproc", "command", "doas", "env", "exec",
    "ionice", "nice", "nocorrect", "noglob", "nohup", "parallel", "setsid",
    "stdbuf", "sudo", "time", "timeout", "unbuffer", "xargs",
    "-exec", "-execdir", "-ok", "-okdir",
}
# Wrapper options that take a separate value, so the value is not the command.
WRAPPER_VALUE_OPTIONS = {
    "caffeinate": {"-t", "-w"},
    "doas": {"-u", "-C"},
    "env": {"-u", "-C", "-S", "--unset", "--chdir", "--split-string"},
    "exec": {"-a"},
    "ionice": {"-c", "-n", "-p", "-P", "-u", "--class", "--classdata"},
    "nice": {"-n", "--adjustment"},
    "parallel": {"-j", "-S", "-I", "-a", "-C", "--jobs", "--sshlogin", "--replace",
                 "--joblog", "--results", "--delay", "--timeout", "--arg-file", "--colsep"},
    "stdbuf": {"-i", "-o", "-e", "--input", "--output", "--error"},
    "sudo": {"-u", "-g", "-h", "-p", "-C", "-D", "-r", "-t", "-U", "-T", "-R",
             "--user", "--group", "--host", "--prompt", "--chdir", "--role",
             "--type", "--other-user", "--close-from", "--command-timeout", "--chroot"},
    "time": {"-f", "-o", "--format", "--output"},
    "timeout": {"-s", "-k", "--signal", "--kill-after"},
    "xargs": {"-I", "-J", "-L", "-n", "-P", "-s", "-d", "-E", "-a", "-R", "-S",
              "--arg-file", "--delimiter", "--max-args", "--max-procs", "--max-lines",
              "--max-chars", "--replace", "--eof", "--process-slot-var"},
}
SOURCE_BUILTINS = {".", "source"}
# Search tools whose `-c` means count: the pattern after it is data.
SEARCH_TOOLS = {"ack", "ag", "egrep", "fgrep", "grep", "rg", "zgrep"}
# Programs that feed stdin words to the command after them.
ARG_FEEDERS = {"parallel", "xargs"}
KEYWORDS = {"!", "{", "}", "if", "then", "else", "elif", "fi", "do", "done", "while", "until"}
ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*\+?=")
WRAPPER_ARG = re.compile(r"^(?:-.*|\d+(?:\.\d+)?[smhd]?|[A-Za-z_][A-Za-z0-9_]*=.*)$")
MAX_DEPTH = 8
METACHARS = set(" \t\n;&|()<>")


class ParseError(Exception):
    pass


class Word:
    """One shell word: its text with quotes removed (expansions kept as
    written, so the text can be re-parsed when a shell runs it), and whether
    it is literal (no expansion, substitution or glob)."""

    def __init__(self):
        self.value = ""
        self.literal = True
        # Dynamic values qualify only when expansion preserves one argument,
        # including inside double quotes ("$@" can still produce many words).
        self.unquoted_dynamic = False
        # Review proofs never infer a parameter's argument count, even quoted.
        self.has_param = False


class Command:
    """One simple command: its words, and the text fed to its stdin by
    heredocs and here-strings."""

    def __init__(self):
        self.words = []
        self.stdin = []


class Parser:
    """A reader for the subset of bash that decides what runs. Commands found
    inside substitutions are collected too: they run as well."""

    def __init__(self, text, commands=None, uncertain=None):
        self.s = text
        self.i = 0
        self.commands = [] if commands is None else commands
        self.cur = None
        self.heredocs = []
        # Expansion text the parser does not model; asks if it mentions merge/pull.
        self.uncertain = uncertain if uncertain is not None else []

    def command(self):
        if self.cur is None:
            self.cur = Command()
        return self.cur

    def end_command(self):
        if self.cur is not None and (self.cur.words or self.cur.stdin):
            self.commands.append(self.cur)
        self.cur = None

    def run(self, stop_at_paren=False):
        s = self.s
        depth = 0
        while self.i < len(s):
            c = s[self.i]
            if c in " \t":
                self.i += 1
            elif c == "\n":
                self.end_command()
                self.i += 1
                self.read_heredocs()
            elif c == "#":
                while self.i < len(s) and s[self.i] != "\n":
                    self.i += 1
            elif s.startswith("\\\n", self.i):
                self.i += 2
            elif s.startswith(("&>>", "&>"), self.i):
                self.i += 3 if s.startswith("&>>", self.i) else 2
                self.redirect_target()
            elif s.startswith(("&&", "||", ";;", "|&"), self.i) or c in ";&|":
                op = s[self.i : self.i + 2] if s[self.i : self.i + 2] in ("&&", "||", ";;", "|&") else c
                self.end_command()
                self.i += len(op)
            elif c == "(":
                self.end_command()
                depth += 1
                self.i += 1
            elif c == ")":
                self.end_command()
                self.i += 1
                if depth == 0:
                    if stop_at_paren:
                        return self.i
                    raise ParseError("unbalanced )")
                depth -= 1
            elif c in "<>":
                self.redirection()
            else:
                start = self.i
                word = self.read_word()
                # `2>&1`: a file-descriptor number belongs to the redirection.
                if word.value.isdigit() and self.i < len(s) and s[self.i] in "<>" and self.i > start:
                    continue
                cmd = self.command()
                if not cmd.words and word.literal and word.value in KEYWORDS:
                    continue
                cmd.words.append(word)
        if stop_at_paren:
            raise ParseError("unterminated $(")
        self.end_command()
        self.read_heredocs()
        return self.i

    def redirection(self):
        s = self.s
        if s.startswith("<<<", self.i):
            self.i += 3
            self.command().stdin.append(self.redirect_target().value)
        elif s.startswith("<<", self.i):
            strip = s.startswith("<<-", self.i)
            self.i += 3 if strip else 2
            start = self.skip_blanks()
            word = self.read_word()
            quoted = any(ch in s[start : self.i] for ch in "'\"\\")
            self.heredocs.append((self.command(), word.value, quoted, strip))
        elif s.startswith(("<(", ">("), self.i):
            self.i = Parser(s, self.commands, self.uncertain).nested(self.i + 2)
        else:
            self.i += 1
            while self.i < len(s) and s[self.i] in "<>&|":
                self.i += 1
            self.redirect_target()

    def skip_blanks(self):
        while self.i < len(self.s) and self.s[self.i] in " \t":
            self.i += 1
        return self.i

    def redirect_target(self):
        self.skip_blanks()
        return self.read_word()

    def nested(self, i):
        """Parse a substitution body starting at i; return the index past `)`."""
        self.i = i
        return self.run(stop_at_paren=True)

    def read_heredocs(self):
        s = self.s
        for cmd, delim, quoted, strip in self.heredocs:
            lines = []
            while self.i < len(s):
                end = s.find("\n", self.i)
                end = len(s) if end < 0 else end
                line = s[self.i : end]
                self.i = end + 1
                if (line.lstrip("\t") if strip else line) == delim:
                    break
                lines.append(line)
            body = "\n".join(lines)
            if not quoted:
                # An unquoted heredoc expands `$(...)` and backticks: they run.
                Parser(body, self.commands, self.uncertain).read_double_quoted(Word(), closing=None)
            cmd.stdin.append(body)
        self.heredocs = []

    def read_word(self):
        s = self.s
        word = Word()
        while self.i < len(s) and s[self.i] not in METACHARS:
            c = s[self.i]
            if c == "\\":
                if s.startswith("\\\n", self.i):
                    self.i += 2
                    continue
                word.value += s[self.i + 1 : self.i + 2]
                self.i += 2
            elif c == "'":
                end = s.find("'", self.i + 1)
                if end < 0:
                    raise ParseError("unterminated '")
                word.value += s[self.i + 1 : end]
                self.i = end + 1
            elif s.startswith('$"', self.i):
                # Locale-translated quoting: the text is a translation lookup.
                self.i += 2
                self.read_double_quoted(word, closing='"')
                word.literal = False
                word.unquoted_dynamic = True
            elif s.startswith("$'", self.i):
                j = self.i + 2
                while j < len(s) and s[j] != "'":
                    j += 2 if s[j] == "\\" else 1
                if j >= len(s):
                    raise ParseError("unterminated $'")
                word.value += ansi_c(s[self.i + 2 : j])
                word.literal = False
                word.unquoted_dynamic = True
                self.i = j + 1
            elif c == '"':
                self.i += 1
                self.read_double_quoted(word, closing='"')
            elif c in "$`":
                self.read_expansion(word)
            else:
                if c in "*?[{}" and not (c in "{}" and word.value == "" and self.at_word_end(self.i + 1)):
                    word.literal = False
                if (c in "*?" or (c == "[" and s[self.i + 1:self.i + 2] != "]")
                        or (c == "{" and re.match(r"\{[^}]*(?:,|\.\.)[^}]*\}", s[self.i:]))):
                    word.unquoted_dynamic = True
                word.value += c
                self.i += 1
        return word

    def at_word_end(self, i):
        return i >= len(self.s) or self.s[i] in METACHARS

    def read_double_quoted(self, word, closing):
        s = self.s
        while self.i < len(s):
            c = s[self.i]
            if closing and c == closing:
                self.i += 1
                return
            if c == "\\" and self.i + 1 < len(s):
                nxt = s[self.i + 1]
                if nxt == "\n":
                    self.i += 2
                    continue
                word.value += nxt if nxt in '$`"\\' else c + nxt
                self.i += 2
            elif c in "$`":
                self.read_expansion(word, quoted=True)
            else:
                word.value += c
                self.i += 1
        if closing:
            raise ParseError('unterminated "')

    def read_expansion(self, word, quoted=False):
        """Read a `$...` or backtick expansion at self.i into word."""
        s = self.s
        start = self.i
        if s[self.i] == "`":
            j = self.i + 1
            while j < len(s) and s[j] != "`":
                j += 2 if s[j] == "\\" else 1
            if j >= len(s):
                raise ParseError("unterminated `")
            body = re.sub(r"\\([`$\\])", r"\1", s[self.i + 1 : j])
            Parser(body, self.commands, self.uncertain).run()
            self.i = j + 1
        elif s.startswith("$(", self.i):
            # `$((...))` arithmetic is read as a substitution too: bash runs
            # `$((git merge feat) )` as one, and arithmetic text is harmless.
            self.i = Parser(s, self.commands, self.uncertain).nested(self.i + 2)
        elif s.startswith("${", self.i):
            word.has_param = True
            self.i += 2
            inner = Word()
            self.read_double_quoted(inner, closing="}")
            if inner.unquoted_dynamic:
                word.unquoted_dynamic = True
            # Operators like `${x/merge/y}` are not modelled: the word test
            # covers anything they could spell.
            self.uncertain.append(s[start : self.i])
        elif self.i + 1 < len(s) and (s[self.i + 1].isalnum() or s[self.i + 1] in "_@*#?$!-"):
            word.has_param = True
            self.i += 2
            while self.i < len(s) and (s[self.i].isalnum() or s[self.i] == "_"):
                self.i += 1
        else:
            word.value += "$"
            self.i += 1
            return
        word.value += s[start : self.i]
        word.literal = False
        # Quoting does not make positional/array @ expansions single words.
        # Include their operators/slices and indirect name expansions; nested
        # expansions propagate the same property through the brace reader above.
        # Review proofs are stricter and read has_param (any parameter at all).
        multiple = re.match(r"\$(?:@|\{(?:@|!?[A-Za-z_]\w*\[@\]|![A-Za-z_]\w*@))",
                            s[start:self.i])
        if not quoted or multiple:
            word.unquoted_dynamic = True


def ansi_c(body):
    """Decode a `$'...'` body the way bash does, near enough to read a word."""
    try:
        return body.encode("latin-1", "backslashreplace").decode("unicode_escape")
    except UnicodeDecodeError:
        return body


def parse(text):
    parser = Parser(text)
    parser.run()
    return parser.commands, parser.uncertain


def base(word):
    """A word's program name: basename, lowercased, without `.exe`."""
    return re.sub(r"\.exe$", "", os.path.basename(word.value.strip("\n")).lower())


def command_index(words):
    """Index of the word bash runs as the command, skipping assignments and
    wrappers with their options (`sudo -u evan`, `env -C dir`, `timeout 9`)."""
    i = 0
    while i < len(words):
        w = words[i]
        if ASSIGNMENT.match(w.value):
            # `FOO=$BAR cmd`: an assignment is one whatever its value expands to.
            i += 1
        elif w.literal and base(w) in WRAPPERS:
            takes_value = WRAPPER_VALUE_OPTIONS.get(base(w), set())
            i += 1
            while i < len(words) and WRAPPER_ARG.match(words[i].value):
                i += 2 if words[i].value in takes_value else 1
        else:
            return i
    return i


def op_run_command(words, i):
    """Return op run's child position; inject/read do not execute arguments.

    Flag names and arities come from installed op --help / op run --help.
    Unknown or nonliteral options cannot establish the child slot and ask.
    """
    global_values = {"--account", "--config", "--session", "--encoding", "--format"}
    global_bools = {"--cache", "--debug", "--iso-timestamps", "--no-color"}
    j = i + 1
    running = False
    while j < len(words):
        word = words[j]
        opt = word.value
        if not word.literal:
            raise ParseError("unreadable op option or child")
        if opt == "--" and running:
            if j + 1 >= len(words):
                raise ParseError("op run has no child command")
            return j + 1
        if opt in {"-h", "--help", "-v", "--version"}:
            return None
        if opt.startswith("-"):
            name, eq, value = opt.partition("=")
            values = global_values | ({"--env-file"} if running else set())
            bools = global_bools | ({"--no-masking"} if running else set())
            if name in values:
                if eq:
                    if not value:
                        raise ParseError("empty op option value")
                    j += 1
                else:
                    if j + 1 >= len(words) or not words[j + 1].literal or words[j + 1].value == "--":
                        raise ParseError("unreadable op option value")
                    j += 2
            elif name in bools:
                if eq and value.lower() not in {"true", "false", "1", "0", "t", "f"}:
                    raise ParseError("unreadable op boolean value")
                j += 1
            else:
                raise ParseError("unknown op option")
            continue
        if not running:
            if opt != "run":
                return None
            running = True
            j += 1
        else:
            return j
    if running:
        raise ParseError("op run has no child command")
    return None


def command_positions(words):
    """Every index that may be run as a command: the command word, and every
    word after a wrapper. A wrapper's option grammar (value-taking options,
    unambiguous long-option prefixes such as `sudo --chd /repo` or
    `env --chd /repo -i`, `coproc NAME`) is open-ended, so the reader does not
    try to find where its options end. Only a non-literal word, a dashed
    `git-merge`/`git-pull` helper or an evaluator at one of these positions
    triggers anything, so ordinary arguments stay silent. op run adds only
    its parsed child position; op inject never executes an argument."""
    positions = {command_index(words)}
    for i, w in enumerate(words):
        if w.literal and base(w) in WRAPPERS:
            positions.update(range(i + 1, len(words)))
        if w.literal and base(w) == "op" and i in positions:
            child = op_run_command(words, i)
            if child is not None:
                positions.add(child)
    return positions


def feeder_tokens(words, i):
    """Replacement strings that `xargs`/`parallel` before words[i] fill in
    at run time, or None when no feeder precedes it."""
    tokens = None
    for k, w in enumerate(words[:i]):
        name = base(w) if w.literal else ""
        if name not in ARG_FEEDERS:
            continue
        tokens = tokens or set()
        if name == "parallel":
            tokens.add("{")
        for j in range(k + 1, i):
            opt = words[j].value
            if opt in ("-I", "-J", "--replace") and j + 1 < i:
                tokens.add(words[j + 1].value)
            elif opt.startswith(("-I", "-J")):
                tokens.add(opt[2:])
            elif opt.startswith("--replace="):
                tokens.add(opt.split("=", 1)[1])
            elif opt.startswith("-i"):
                # GNU xargs `-i[R]`: replace R, `{}` by default.
                tokens.add(opt[2:] or "{}")
    return tokens


def git_might_merge(words, i, depth=0):
    """True when the git call at words[i] could be a merge or pull."""
    if depth > MAX_DEPTH:
        return True
    j = i + 1
    aliases = {}  # one-off alias name -> expansion (None: set from the environment)
    while j < len(words) and words[j].value.startswith("-"):
        opt = words[j].value
        if words[j].literal and opt in ("-h", "--help", "-v", "--version"):
            # `git --help merge` shows help; `git --version pull` prints the version.
            return False
        name, eq, val = opt.partition("=")
        if opt.startswith("-c") and len(opt) > 2:
            # The attached form `-calias.m=merge` is git's own spelling too.
            name, eq, val = "-c", "=", opt[2:]
        if name in ("-c", "--config-env"):
            word = words[j] if eq else (words[j + 1] if j + 1 < len(words) else Word())
            val = val if eq else word.value
            if not word.literal:
                # `git -c "$X" m`: the setting could define any alias.
                return True
            # Git folds the section and the alias name case.
            alias = re.match(r"\s*alias\.([^=]+)=?(.*)", val, re.I | re.S)
            if alias:
                aliases[alias.group(1).lower()] = alias.group(2) if name == "-c" else None
        j += 2 if opt in GIT_VALUE_OPTIONS else 1
    tokens = feeder_tokens(words, i)
    if tokens is not None:
        # `xargs git`, `xargs -I X git X`, `parallel git ::: merge`: a feeder
        # can fill the subcommand from stdin or its own arguments.
        if j >= len(words) or any(w.value.startswith(":::") for w in words):
            return True
        if any(t and t in words[j].value for t in tokens):
            return True
    if j >= len(words):
        return False
    slot = words[j]
    sub = slot.value.strip("\n").lower()
    if not slot.literal or sub in MERGE_WORDS or (depth > 0 and sub == "push"):
        # Checked before aliases: git ignores an alias that hides a built-in.
        return True
    if sub in aliases:
        # Only the invoked alias matters (`git -c alias.x=log status` runs
        # status). Expand it the way git does, with the caller's arguments
        # appended, and check the result: a `!` alias is a shell script, any
        # other re-enters git, so chained aliases and expansions that are only
        # options (`alias.g='-c x=y'`) are followed too.
        expansion = aliases[sub]
        rest = words[j + 1 :]
        if expansion is None or MENTION.search(expansion):
            return True
        if expansion.lstrip().startswith("!"):
            script = " ".join([expansion.lstrip()[1:]] + [w.value for w in rest])
            return script_might_merge(script, depth + 1)
        try:
            expanded = parse(expansion)[0]
        except (ParseError, IndexError, RecursionError):
            return True
        if len(expanded) != 1:
            return True
        return git_might_merge(words[:j] + expanded[0].words + rest, i, depth + 1)
    return False


def sudo_shell_flag(opt):
    """True when one of sudo's own options asks for a shell (`-s`, `-i`,
    `--shell`, `--login`). Short clusters are read the way getopt reads them:
    a value-taking letter ends the cluster (`-uadmin` is `-u admin`)."""
    # sudo takes any unambiguous long-option prefix (`--sh`, `--lo`).
    if len(opt) >= 4 and ("--shell".startswith(opt) or "--login".startswith(opt)):
        return True
    if not opt.startswith("-") or opt.startswith("--"):
        return False
    for ch in opt[1:]:
        if ch in "si":
            return True
        if "-" + ch in WRAPPER_VALUE_OPTIONS["sudo"]:
            return False
    return False


def herdr_runs(words, i):
    """`herdr [global options] pane run <pane> '...'` types its text into
    another pane's shell; other herdr subcommands only read or manage panes.
    The `pane run` pair is found wherever it sits, so global options cannot
    hide it, while a lone `run` argument (`herdr agent read run`) is data."""
    # A non-literal word can be either half (`herdr "$GROUP" run`).
    rest = words[i + 1 :]
    return any(
        (a.value == "pane" or not a.literal) and (b.value == "run" or not b.literal)
        for a, b in zip(rest, rest[1:])
    )


def split_string_option(v):
    """`env -S`, `--split-string` or any unambiguous prefix: `--s` is the
    shortest, since no other env long option starts with `s`."""
    name = v.split("=", 1)[0]
    return v.startswith("-S") or (len(name) >= 3 and "--split-string".startswith(name))


def is_evaluator(words, i):
    """True when words[i] runs text it is given as a script."""
    name = base(words[i])
    if name == "herdr":
        return herdr_runs(words, i)
    if name in SOURCE_BUILTINS:
        # As an argument (`rg -c x .`) a dot is a path, not the builtin.
        return i == command_index(words)
    if name in SHELLS or name in JOINERS or name in ("parallel", "coproc"):
        # `parallel ::: 'git merge main'` runs each input as a command;
        # `coproc NAME { ...; }` runs a compound body the reader does not split.
        return True
    if name == "sudo":
        # sudo's option grammar is open-ended (unambiguous long-option prefixes,
        # including for value-taking options: `--chd /tmp -s`; even `--` can be
        # an option's value: `-p -- -s`), so a shell flag anywhere after sudo
        # counts. A delegated command's own flag (`sudo grep -i ...`) can then
        # match; that costs a prompt only when the line mentions merge/pull,
        # never a silent merge.
        return any(sudo_shell_flag(x.value) for x in words[i + 1 :])
    return name == "env" and any(
        split_string_option(w.value) for w in words[i + 1 :]
    )


def git_subcommand(words, i):
    """Locate git's literal subcommand without treating argument data as push."""
    j = i + 1
    while j < len(words) and words[j].value.startswith("-"):
        opt = words[j].value
        j += 2 if opt in GIT_VALUE_OPTIONS else 1
        if opt == "--":
            break
    return words[j].value.strip("\n").lower() if j < len(words) and words[j].literal else None


def risky_mention(text):
    push = re.search(r"\bpush\b", text, re.I)
    # Evaluated API/delegated sync strings are opaque: no second classifier.
    return bool(MENTION.search(text)
                or re.search(r"\bpr\s+review\b"
                             r"|\bpulls/[0-9]+/reviews\b"
                             r"|\b(?:addPullRequestReview|submitPullRequestReview)\b", text, re.I)
                or re.search(r"\bgh\b[^\n]*\bapi\b|\brepo\s+sync\b", text, re.I)
                or (push and (GIT_MENTION.search(text)
                              or re.search(r"\b(?:main|master)\b", text, re.I))))


def normalized_endpoint(word):
    """Literal, undecoded path: encoded slashes must never forge safe routes."""
    masked = re.sub(r"\{(?:owner|repo|branch)\}", "segment", word.value)
    literal = word.literal or not re.search(r"[\s$`*?\[\]{}\\]", masked)
    path = (urlsplit(word.value).path if re.match(r"https?://", word.value)
            else word.value.split("#", 1)[0].split("?", 1)[0])
    path = re.sub(r"/+", "/", path).strip("/")
    if path.startswith("api/v3/"):
        path = path[len("api/v3/"):]
    if path == "api/graphql":
        path = "graphql"
    return path, literal


def gh_prints_help(args):
    """Prove help/version using only the active subcommand's flag arities."""
    inherited = {"-R", "--repo", "--hostname"}
    # The same short flag takes a value in one command and is boolean in
    # another: -s is sync's source but merge's squash; -F is API's field but
    # merge/review's body-file. Unknown command/option shapes fail the proof.
    options = {
        (): (set(), set()),
        ("pr",): (set(), set()),
        ("repo",): (set(), set()),
        ("pr", "merge"): (
            {"-A", "--author-email", "-b", "--body", "-F", "--body-file",
             "--match-head-commit", "-t", "--subject"},
            {"--admin", "--auto", "-d", "--delete-branch", "--disable-auto",
             "-m", "--merge", "-r", "--rebase", "-s", "--squash"}),
        ("pr", "review"): (
            {"-b", "--body", "-F", "--body-file"},
            {"-a", "--approve", "-c", "--comment", "-r", "--request-changes"}),
        ("repo", "sync"): (
            {"-b", "--branch", "-s", "--source"}, {"--force"}),
        ("api",): (
            {"-X", "--method", "-f", "-F", "--field", "--raw-field", "-H", "--header",
             "--input", "-q", "--jq", "-t", "--template", "--cache", "-p", "--preview"},
            {"-i", "--include", "--paginate", "--slurp", "--silent", "--verbose"}),
    }
    # A skipped value holding a parameter can expand to `--help=false --approve`,
    # so help is proved only when no word's argument count is unknown.
    if any(w.unquoted_dynamic or w.has_param for w in args):
        return False
    nonexecuting = False
    command = ()
    j = 0
    while j < len(args):
        w = args[j]
        if not w.literal or w.unquoted_dynamic:
            return False
        v = w.value
        values, bools = options[command]
        values = values | inherited
        if v == "--":
            return False
        if v in {"--help", "-h"} or (not command and v in {"--version", "-v"}):
            nonexecuting = True
            j += 1
            continue
        if v in values:
            j += 2
            continue
        if v.startswith("--"):
            name, eq, _ = v.partition("=")
            if name not in bools and not (eq and name in values):
                return False
        elif v.startswith("-"):
            # A value-taking short option consumes its suffix, including h/X.
            for k, letter in enumerate(v[1:], 1):
                if "-" + letter in values:
                    if k == len(v) - 1:
                        j += 1
                    break
                if letter == "h" or (not command and letter == "v"):
                    nonexecuting = True
                    continue
                if "-" + letter not in bools:
                    return False
        elif command in {(), ("pr",), ("repo",)}:
            command += (v,)
            if command not in options:
                return False
        j += 1
    return nonexecuting


# Approval can complete an already armed auto-merge through the code-owner gate.
NONAPPROVAL_EVENTS = {"COMMENT", "REQUEST_CHANGES"}


def cli_review_might_approve(args):
    """Prove an explicit nonapproval mode, consuming option values first."""
    # Inspect every word before skipping values. Parameters can yield several
    # arguments even when quoted (for example a nameref to an array).
    if any(w.unquoted_dynamic or w.has_param for w in args):
        return True
    mode = False
    j = 0
    while j < len(args):
        w = args[j]
        v = w.value
        if v in {"-b", "--body", "-F", "--body-file", "-R", "--repo"}:
            j += 2
            if j > len(args):
                return True
            continue
        if v in {"--comment", "--request-changes"}:
            mode = True
        elif v.startswith(("--body=", "--body-file=", "--repo=")):
            pass
        elif v.startswith("--"):
            return True  # Includes --approve and unknown mode controls.
        elif v.startswith("-"):
            for k, letter in enumerate(v[1:], 1):
                if letter in "bFR":
                    if k == len(v) - 1:
                        j += 1
                        if j >= len(args):
                            return True
                    break
                if letter not in "cr":
                    return True  # -a, including a boolean short-option cluster.
                mode = True
        elif not w.literal:
            return True
        j += 1
    return not mode


def graphql_review_is_nonapproval(ts):
    """Prove the event in a review's input object; opaque inputs never qualify.

    Only a literal input object with a literal enum event qualifies. Variables
    (including variables supplied through gh fields), file/stdin values and
    unmodelled argument shapes ask, rather than guessing their runtime value.
    """
    if ts[:3] != ["(", "input", ":"] or ts[3:4] != ["{"]:
        return False
    depth = 0
    events = []
    for k in range(3, len(ts)):
        token = ts[k]
        if token in {"{", "[", "("}:
            depth += 1
        elif token in {"}", "]", ")"}:
            depth -= 1
            if depth == 0:
                return (ts[k:] == ["}", ")"] and len(events) == 1
                        and events[0] in NONAPPROVAL_EVENTS)
        elif depth == 1 and token == "event" and ts[k + 1:k + 2] == [":"]:
            # A variable or a string is not a literal GraphQL enum event.
            events.append(ts[k + 2] if k + 2 < len(ts) else None)
    return False


def gh_touches_review(args):
    """Recognize review subjects before options or read/help exemptions."""
    values = [w.value for w in args]
    return (("pr" in values and "review" in values)
            or any(re.fullmatch(r"repos/[^/]+/[^/]+/pulls/[0-9]+/reviews(?:/.*)?",
                                normalized_endpoint(w)[0]) for w in args)
            or any(re.search(r"\b(?:addPullRequestReview|submitPullRequestReview)\b", w.value)
                   for w in args))


def gh_might_land(words, i, appended=False):
    """Ask unless a built-in, API read or explicitly safe write is proved.

    The safe-write lists describe permissions, not examples of dangerous writes.
    Unknown paths/mutations/controlling inputs cost a prompt, never a silent write.
    """
    args = words[i + 1:]
    if any(w.has_param for w in args) and gh_touches_review(args):
        return True
    tokens = feeder_tokens(words, i)
    if tokens is not None and (not args or any(
            t and t in w.value for t in tokens for w in args)):
        return True
    fed = appended or any(base(w) in ARG_FEEDERS | {"-exec", "-execdir", "-ok", "-okdir"}
                          for w in words[:i])
    # Feeders may replace a help flag or append --help=false; no exemption.
    if not fed and gh_prints_help(args):
        return False
    j = 0
    param_option = False
    while j < len(args) and args[j].value.startswith("-"):
        v = args[j].value
        if v in ("-R", "--repo", "--hostname"):
            if j + 1 >= len(args):
                return True
            param_option |= args[j].has_param or args[j + 1].has_param
            j += 2
        elif v.startswith(("--repo=", "--hostname=", "-R")):
            param_option |= args[j].has_param
            j += 1
        else:
            return True
    args = args[j:]
    if not args:
        return fed or param_option
    if args[0].value != "api" and param_option:
        return True
    if not args[0].literal:
        return True
    if args[0].value == "help":
        return False
    if args[0].value in ("pr", "repo"):
        j = 1
        while j < len(args) and args[j].value.startswith("-"):
            opt = args[j].value
            if opt in ("-R", "--repo"):
                if j + 1 >= len(args) or args[j].has_param or args[j + 1].has_param:
                    return True
                j += 2
            elif opt.startswith(("-R", "--repo=")):
                if args[j].has_param:
                    return True
                j += 1
            else:
                return True
        if j >= len(args):
            return fed
        if not args[j].literal:
            return True
        if args[0].value == "pr":
            if args[j].value == "review":
                return fed or cli_review_might_approve(words[i + 1:])
            return args[j].value == "merge"
        if args[j].value != "sync":
            return False
        if fed:
            return True
        j += 1
        while j < len(args):
            w = args[j]
            opt = w.value
            if not w.literal or w.has_param:
                return True
            if opt in ("--source", "-s"):
                if (j + 1 >= len(args) or not args[j + 1].literal
                        or args[j + 1].has_param):
                    return True
                j += 2
            elif opt in ("--force", "-f", "--help") or opt.startswith(("--source=", "-s")):
                j += 1
            else:
                # Any positional target (or unmodelled argument) may be remote.
                return True
        return False
    if args[0].value != "api":
        return False
    if fed:
        return True

    endpoint = None
    method = None
    fields = False
    queries = []
    review_events = []
    args = args[1:]
    if any(w.unquoted_dynamic for w in words[i + 1:]):
        return True
    # gh/pflag short clusters: booleans continue; the first value-taking
    # option consumes the entire suffix. Thus -tXGET is template XGET,
    # while -iXPUT is include + method PUT. Never hunt for X inside a value.
    expanded = []
    for w in args:
        v = w.value
        if len(v) > 2 and v.startswith("-") and not v.startswith("--"):
            k = 1
            while k < len(v):
                flag = Word()
                flag.value = "-" + v[k]
                expanded.append(flag)
                if v[k] in "XfFHqtp":
                    if k + 1 < len(v):
                        value = Word()
                        value.value = v[k + 1:]
                        value.literal = w.literal
                        value.has_param = w.has_param
                        expanded.append(value)
                    break
                if v[k] != "i":
                    return True
                k += 1
        else:
            expanded.append(w)
    args = expanded
    j = 0
    output_options = {"--jq", "-q", "--template", "-t", "--cache"}
    field_options = {"-f", "-F", "--field", "--raw-field"}
    while j < len(args):
        w = args[j]
        v = w.value
        name, sep, value = v.partition("=")
        if v in ("-X", "--method"):
            value = v.split("X", 1)[1] if "X" in v else ""
            if not value:
                j += 1
                if j >= len(args) or not args[j].literal:
                    return True
                value = args[j].value
            elif not w.literal:
                return True
            method = value.upper()
        elif name == "--method" and sep:
            if not w.literal:
                return True
            method = value.upper()
        elif (v in field_options or name in {"--field", "--raw-field"}
              or v.startswith(("-f", "-F"))):
            fields = True
            typed = v in {"-F", "--field"} or name == "--field" or v.startswith("-F")
            value_literal = w.literal
            if v in field_options:
                j += 1
                if j >= len(args):
                    return True
                value, value_literal = args[j].value, args[j].literal
            elif v.startswith(("-f", "-F")):
                value = v[2:]
            key, eq, body = value.partition("=")
            if not eq or not re.fullmatch(r"[A-Za-z_]\w*(?:\[\w*\])*", key):
                return True
            if key == "event" or key.startswith("event["):
                review_events.append(body if value_literal and key == "event" else None)
            if key == "query":
                if not value_literal or body.startswith("@"):
                    return True
                # gh expands typed-field placeholders before sending the query;
                # a branch named mutation can change the operation itself.
                if typed and re.search(r"\{(?:owner|repo|branch)\}", body):
                    return True
                queries.append(body)
        elif name in output_options or v.startswith(("-q", "-t")):
            if v in output_options:
                j += 1
                if j >= len(args):
                    return True
            # Presentation/cache values are not operation-controlling.
        elif v in ("-H", "--header", "--hostname") or name in {"--header", "--hostname"} or v.startswith("-H"):
            if v in ("-H", "--header", "--hostname"):
                j += 1
                if j >= len(args) or not args[j].literal:
                    return True
            elif not w.literal:
                return True
        elif name == "--input":
            return True  # Even a literal file name has an unreadable body.
        elif v.startswith("-"):
            if not w.literal or v not in {"-i", "--include", "--silent", "--paginate", "--slurp", "--verbose"}:
                return True
        elif endpoint is None:
            endpoint = w
        else:
            return True
        j += 1
    if endpoint is None:
        return True
    path, literal = normalized_endpoint(endpoint)
    if not literal:
        return True
    if path == "graphql":
        if method is not None and method not in {"GET", "HEAD", "POST"}:
            return True
        if not queries:
            return True
        safe_mutations = {
            "addComment", "addPullRequestReview", "submitPullRequestReview", "addPullRequestReviewComment",
            "addPullRequestReviewThreadReply", "resolveReviewThread", "unresolveReviewThread",
            "addReaction", "removeReaction", "updateIssue", "updatePullRequest",
            "addLabelsToLabelable", "removeLabelsFromLabelable", "updatePullRequestBranch",
            "updateProjectV2ItemFieldValue", "addProjectV2ItemById",
            "markPullRequestReadyForReview", "convertPullRequestToDraft",
        }
        for query in queries:
            if any(ord(c) < 32 and c not in "\t\r\n" or 127 <= ord(c) <= 159 for c in query):
                return True
            # Tokenize before classifying: strings and comments are data,
            # including a leading comment or the text "mutation" inside a value.
            ts = re.findall(r'"""[\s\S]*?"""|"(?:\\.|[^"\\])*"|#[^\r\n]*|[A-Za-z_]\w*|\.\.\.|[^\s,]', query)
            ts = [t for t in ts if not t.startswith("#")]
            operations = [t for t in ts if not t.startswith('"')]
            if (operations and operations[0] in {"{", "query", "subscription"}
                    and "mutation" not in operations):
                continue
            # Any actual mutation in a mixed document still owes the safe-field
            # proof. The reader below fails closed on unmodelled root forms.
            k = 0

            def skip_group(k, opening, closing):
                depth = 0
                while k < len(ts):
                    if ts[k] == opening:
                        depth += 1
                    elif ts[k] == closing:
                        depth -= 1
                        if depth == 0:
                            return k + 1
                    k += 1
                return len(ts) + 1

            while k < len(ts):
                if ts[k] != "mutation":
                    return True
                k += 1
                if k < len(ts) and re.fullmatch(r"[A-Za-z_]\w*", ts[k]):
                    k += 1  # Document operation name, not a mutation field.
                if k < len(ts) and ts[k] == "(":
                    k = skip_group(k, "(", ")")
                if k >= len(ts) or ts[k] != "{":
                    return True
                k += 1
                found = False
                while k < len(ts) and ts[k] != "}":
                    field = ts[k]
                    k += 1
                    if k < len(ts) and ts[k] == ":":
                        k += 1
                        if k >= len(ts):
                            return True
                        field = ts[k]
                        k += 1
                    if field not in safe_mutations:
                        return True
                    found = True
                    if field in {"addPullRequestReview", "submitPullRequestReview"}:
                        # Any parameter can split into extra options (-f event=...).
                        if any(w.has_param for w in words[i + 1:]):
                            return True
                        end = skip_group(k, "(", ")") if k < len(ts) and ts[k] == "(" else k
                        if not graphql_review_is_nonapproval(ts[k:end]):
                            return True
                    if k < len(ts) and ts[k] == "(":
                        k = skip_group(k, "(", ")")
                    if k < len(ts) and ts[k] == "{":
                        k = skip_group(k, "{", "}")
                if not found or k >= len(ts):
                    return True
                k += 1
        return False
    method = method or ("POST" if fields else "GET")
    if method in {"GET", "HEAD"} and not queries:
        return False
    if method == "POST" and re.fullmatch(r"repos/[^/]+/[^/]+/pulls/[0-9]+/reviews", path):
        return (any(w.has_param for w in words[i + 1:])
                or len(review_events) != 1 or review_events[0] not in NONAPPROVAL_EVENTS)
    # A short permission list; misses ask. Never decode percent escapes here.
    safe_writes = (
        ({"POST"}, r"issues/[0-9]+/comments"),
        ({"PATCH", "DELETE"}, r"issues/comments/[0-9]+"),
        ({"POST"}, r"pulls/[0-9]+/comments(?:/[0-9]+/replies)?"),
        ({"POST", "DELETE"}, r"pulls/[0-9]+/requested_reviewers"),
        ({"PATCH"}, r"(?:issues|pulls)/[0-9]+"),
        ({"POST", "PUT", "DELETE"}, r"issues/[0-9]+/labels"),
        ({"POST", "DELETE"}, r"issues/[0-9]+/assignees"),
        ({"POST"}, r".+/reactions"),
        ({"PUT"}, r"pulls/[0-9]+/update-branch"),
        ({"POST"}, r"(?:dispatches|actions/workflows/[^/]+/dispatches)"),
    )
    return not any(method in methods and re.fullmatch(r"repos/[^/]+/[^/]+/" + route, path)
                   for methods, route in safe_writes)


def push_might_land(words, i, cwd):
    """Silence requires the destination ref to be this branch's own name,
    and that name not to be the destination repository's default branch.

    Every push form shares this proof. An explicit :dst proves only the ref;
    repository redirections still invalidate the fetch-side remote HEAD proof.
    """
    j = i + 1
    if j < len(words) and words[j].value.startswith("-"):
        return True  # Alternate checkout/config inputs cannot establish cwd.
    if j >= len(words) or words[j].value.lower() != "push":
        return False
    args = words[j + 1:]
    if any(not w.literal for w in args):
        return True
    branch = feature_branch(cwd)
    remotes_text = git(cwd, "remote")
    if not branch or not remotes_text:
        return True
    remotes = remotes_text.split()
    positional = []
    for w in args:
        if w.value.startswith("-"):
            if w.value not in {"-u", "--set-upstream", "--dry-run", "-n", "--verbose", "-v"}:
                return True
        else:
            positional.append(w.value)
    catalog = git(cwd, "config", "--null", "--list")
    if catalog is None:
        return True
    keys = {entry.partition("\n")[0] for entry in catalog.split("\0") if entry}

    def values(key, boolean=False):
        if key not in keys:
            return []
        # Preserve every value exactly, including empty strings/newlines.
        flags = ["--type=bool"] if boolean else []
        out = subprocess.run(["git", "-C", cwd, "config", *flags, "--null", "--get-all", key],
                             capture_output=True, text=True, timeout=5)
        if out.returncode != 0 or not out.stdout.endswith("\0"):
            raise ParseError("unreadable push configuration")
        return out.stdout.split("\0")[:-1]

    def single(key):
        choices = values(key)
        if len(set(choices)) > 1:
            raise ParseError("ambiguous push remote")
        return choices[0] if choices else None

    push_remote = single(f"branch.{branch}.pushremote")
    push_default = single("remote.pushdefault")
    upstream_remote = single(f"branch.{branch}.remote")
    remote = (positional[0] if positional else
              push_remote or push_default or upstream_remote or
              ("origin" if "origin" in remotes else remotes[0] if len(remotes) == 1 else None))
    if remote not in remotes:
        return True
    if any(r is not None and r != remote for r in (push_remote, push_default)):
        return True
    if any(v != "false" for v in values(f"remote.{remote}.mirror", boolean=True)):
        return True
    urls = values(f"remote.{remote}.url")
    if len(urls) != 1 or not urls[0] or values(f"remote.{remote}.pushurl"):
        return True
    for key in keys:
        if key.startswith("url.") and key.endswith(".pushinsteadof"):
            if any(urls[0].startswith(prefix) for prefix in values(key)):
                return True
    prefix = f"refs/remotes/{remote}/"
    default = git(cwd, "symbolic-ref", "--quiet", prefix + "HEAD")
    if (not default or not default.startswith(prefix)
            or branch.casefold() in PROTECTED | {default[len(prefix):].casefold()}):
        return True

    refs = positional[1:]
    # Defaults and remote push mappings affect colon-less refs as well as bare
    # pushes; evaluate them before returning for any source form, including HEAD.
    implicit = not refs or any(":" not in ref for ref in refs)
    upstream = values(f"branch.{branch}.merge")
    if implicit:
        if values(f"remote.{remote}.push"):
            return True
        for mode in values("push.default"):
            mode = mode.casefold()
            if mode in {"simple", "current"}:
                continue
            if mode != "upstream" or upstream != [f"refs/heads/{branch}"]:
                return True
        # No CLI source needs the configured upstream proof too. Explicit
        # colon-less sources under simple/current already name their own ref.
        if not refs and (upstream_remote is not None or upstream):
            if not upstream_remote or upstream != [f"refs/heads/{branch}"]:
                return True
            if upstream_remote != ".":
                up_prefix = f"refs/remotes/{upstream_remote}/"
                up_default = git(cwd, "symbolic-ref", "--quiet", up_prefix + "HEAD")
                if (not up_default or not up_default.startswith(up_prefix)
                        or up_default[len(up_prefix):].casefold() == branch.casefold()):
                    return True
    for ref in refs:
        if ref.startswith(("+", ":")):
            return True
        if ":" in ref:
            if ref.count(":") != 1:
                return True
            destination = ref.split(":", 1)[1].removeprefix("refs/heads/")
        else:
            destination = branch if ref == "HEAD" else ref.removeprefix("refs/heads/")
        if destination != branch:
            return True
    return False


def push_companions_safe(command, cwd):
    """Reuse the existing companion proof without widening its accepted shapes.

    Replacing already-verified pushes with feature-only ff merge probes lets
    allowlisted_target enforce its exact true/false/status/tracking-fetch grammar.
    No probe is executed, and cwd is already proved to be a feature checkout.
    """
    parts = re.split(r"(&&|\|\||;|\|)", command)
    for i in range(0, len(parts), 2):
        tokens = parts[i].split()
        if not tokens or tokens[0] == "cd":
            return False
        if tokens[:2] == ["git", "push"]:
            # Preserve syntax restrictions before replacing words with a probe.
            if re.search(r"[\"'`$\\\n<>(){}*?\[\]~#&]", parts[i]):
                return False
            parts[i] = "git merge --ff-only HEAD"
    return feature_branch(cwd) is not None and allowlisted_target("".join(parts), cwd) is not None



# A closed lexical language: commands are fixed reads and words are inert.
# Unrecognized syntax fails the proof rather than acquiring shell semantics.
MENTION_READS = {"echo", "printf", "cat", "head", "tail", "wc", "grep", "jq",
                 "sort", "uniq", "cut"}
MENTION_WORD = re.compile(
    r"(?:[A-Za-z0-9_./:@%+=,-]+|\"[^\"\n]*\"|'[^'\n]*')(?=[ \t\n;|]|$)"
)


def mention_read(words):
    """Require an exact command name; arguments never become executable code."""
    if words[0] == "printf":
        args = words[1:]
        if args[:1] == ["--"]:
            args = args[1:]
        # -v and %n assign shell variables, including PATH; they are not reads.
        return bool(args) and not args[0].startswith("-") and "%" not in re.sub(
            r"%%|%[sdfq]", "", args[0]
        )
    if words[0] in {"sort", "uniq"}:
        # sort can launch --compress-program or write -o; uniq's second file
        # operand is output. Only these fixed flags and input files qualify.
        flags = {"-n", "-r", "-u", "-f", "-b"} if words[0] == "sort" else {"-c", "-d", "-u", "-i"}
        files = 0
        options = True
        for arg in words[1:]:
            if options and arg == "--":
                options = False
            elif options and arg.startswith("-"):
                if arg not in flags:
                    return False
            else:
                files += 1
        return words[0] == "sort" or files <= 1
    if words[0] == "grep":
        # grep may be ugrep, whose --filter/--pre run commands and whose
        # --save-config writes. Only fixed short flags qualify; no long option.
        args = iter(words[1:])
        for arg in args:
            if arg == "--":
                break
            if re.fullmatch(r"-[ABCm][0-9]+", arg):
                continue
            if arg in {"-e", "-f", "-A", "-B", "-C", "-m"}:
                next(args, None)
            elif arg.startswith("-") and not re.fullmatch(r"-[EFHchilnoqrsvwx]+", arg):
                return False
        return True
    if words[0] in MENTION_READS:
        return True
    if words[0] != "gh" or len(words) < 3:
        return False
    # --web hands the URL to $BROWSER/$GH_BROWSER, which can be any program.
    if any(re.match(r"--web|-[A-Za-z]*w", w) for w in words[3:]):
        return False
    # gh_might_land also permits safe writes and non-merging commands such as
    # checkout: those are NOT reads. Narrow first, then reuse its operation proof.
    reads = {"pr": {"view", "list", "status", "checks", "diff"},
             "issue": {"view", "list", "status"}, "repo": {"view", "list"}}
    if words[2] not in reads.get(words[1], set()):
        return False
    parsed = []
    for value in words:
        word = Word()
        word.value = value
        parsed.append(word)
    return not gh_might_land(parsed, 0)


def literal_evaluator_mentions(text):
    """Prove a complete evaluator has only allowlisted reads and literal words.

    Unknown syntax cannot introduce an input channel: it is outside this
    language. No prefix assignments, substitutions, script files, feeders or
    nested evaluators can match. Pipes connect only commands proved here.
    """
    match = re.fullmatch(r"(?:bash|sh) -c (?:'([^']*)'|\"([^\"]*)\")", text)
    if match:
        payload = match[1] if match[1] is not None else match[2]
    else:
        match = re.fullmatch(
            r"(?:bash|sh) <<'([A-Z][A-Z0-9_]*)'\n(.*?)\n\1\n?", text, re.S
        )
        if not match:
            return False
        payload = match[2]
    if (re.search(r"[$`\\]", payload) or "BASH_ENV" in payload
            or re.search(r"[^\x20-\x7e\n\t]", payload)):
        return False
    i = 0
    words = []
    completed = False
    separator = None
    pipe_pending = False
    while i < len(payload):
        if payload[i] in " \t":
            i += 1
            continue
        if payload[i] in ";\n|":
            if words:
                if not mention_read(words):
                    return False
                words = []
                completed = True
                separator = payload[i]
                pipe_pending = separator == "|"
            elif payload[i] != "\n":
                # Empty newline segments are harmless, but empty semicolon or
                # pipe segments (including either side of a pipe) are not.
                return False
            i += 1
            continue
        match = MENTION_WORD.match(payload, i)
        if not match:
            return False
        if not words:
            separator = None
            pipe_pending = False
        value = match[0]
        value = value[1:-1] if value[:1] in {"'", '\"'} else value
        # A descriptor/stdin path never supplies an evaluator input in this
        # grammar. Reject it anyway: do not broaden the external-input contract.
        path = os.path.normpath(value)
        if (value == "-" or path.startswith(("/dev/", "/proc/")) and path != "/dev/null"
                or re.search(r"(?:^|/)dev/(?:stdin|fd)(?:/|$)", path)):
            return False
        words.append(value)
        i = match.end()
    if words:
        return mention_read(words)
    return completed and not pipe_pending and separator in {";", "\n"}


def command_might_merge(cmd, text, depth, appended=False, literal_mentions=False):
    words = cmd.words
    ci = command_index(words)
    positions = command_positions(words)
    for p in positions:
        tokens = feeder_tokens(words, p) if p < len(words) else None
        # A feeder's replacement string is filled at run time (`xargs -I X X`).
        fed = bool(tokens) and any(t and t in words[p].value for t in tokens)
        if p < len(words) and (not words[p].literal or fed):
            # The command itself comes from an expansion (`$(printf 'git merge')`,
            # `git${IFS}merge`, `"$SHELL" <<< ...`, `xargs -I X X merge`): what runs is
            # unknown, so the line goes under the merge/pull word test.
            if risky_mention(text) or any(
                w.value.lower() in MERGE_WORDS for w in words[p + 1 : p + 2]
            ):
                return True
    for i, w in enumerate(words):
        name = base(w)
        if name == "gh":
            # Outside command position, classify only when a following word
            # could name a controlled subcommand; all other gh words are data.
            controls = i in positions or any(
                not x.literal or x.value in {"pr", "api", "repo"}
                for x in words[i + 1:]
            )
            if controls and gh_might_land(words, i, appended):
                return True
        if name == "git" and depth > 0 and git_subcommand(words, i) == "push":
            return True
        if name == "git" and git_might_merge(words, i):
            return True
        at_command = i in positions
        if name in DASHED and at_command:
            return True
        # A non-literal word counts when its decoded text names an evaluator
        # (`$'bash'`); an expansion such as `$SHELL` decodes to itself and does not.
        # An evaluator's option and input shapes are open-ended (`bash -C -c`,
        # `env -S'...'`, a pipe into a compound command), so its presence puts
        # the whole script under the word test; the parse below still sees
        # what the word test cannot (`$'\x70ull'`, `git $x`).
        if (is_evaluator(words, i) and risky_mention(text)
                and not literal_mentions):
            return True
        # A `-c` / `-Command` payload is read as a script whatever program
        # takes it, so an interpreter missing from SHELLS is still seen.
        searching = ci < len(words) and (
            base(words[ci]) in SEARCH_TOOLS
            or (base(words[ci]) == "git" and any(x.value == "grep" for x in words[ci + 1 :]))
        )
        if SCRIPT_OPTION.match(w.value) and i + 1 < len(words) and not searching:
            if script_might_merge(words[i + 1].value, depth + 1):
                return True
        if name == "cmd" and not (
                ci < len(words) and base(words[ci]) == "printf"
                and i > ci and words[i - 1].value == "-v"):
            # `cmd.exe /c` and `/k` (Windows Git Bash, WSL interop) run what
            # follows. cmd's switch spellings are open-ended (`/c`, `//c` to dodge
            # MSYS path conversion, `/Q/C`, attached `/cgit pull`), and its own
            # expansions and escapes (`%SUB%`, `!SUB!`, `m^erge`) are not bash's.
            # So a cmd line that names git and uses any of them asks, and the text
            # after the first /c or /k switch is also read as a script.
            line = " ".join(x.value for x in words[i + 1 :])
            if GIT_MENTION.search(line) and re.search(r"[%!^]", line):
                return True
            switch = re.search(r"(?i)/+[ck]", line)
            if switch and script_might_merge(line[switch.end() :], depth + 1):
                return True
        if (name in SHELLS or name in ("sudo", "parallel")) and is_evaluator(words, i):
            # Without -c a shell may read its script from stdin (`bash -s x`,
            # `sudo -s`), and `parallel` runs stdin lines as commands.
            if any(script_might_merge(p, depth + 1) for p in cmd.stdin):
                return True
        elif name in JOINERS or (name == "herdr" and herdr_runs(words, i)):
            if script_might_merge(" ".join(x.value for x in words[i + 1 :]), depth + 1):
                return True
        elif name == "env":
            # The split string is followed by the remaining arguments
            # (`env -Sgit $SUB main` runs `git $SUB main`).
            for k in range(i + 1, len(words)):
                v = words[k].value
                if not split_string_option(v):
                    continue
                if "=" in v and v.startswith("--"):
                    payload, rest = v.split("=", 1)[1], words[k + 1 :]
                elif v.startswith("-S") and len(v) > 2:
                    payload, rest = v[2:], words[k + 1 :]
                elif k + 1 < len(words):
                    payload, rest = words[k + 1].value, words[k + 2 :]
                else:
                    continue
                if script_might_merge(" ".join([payload] + [x.value for x in rest]), depth + 1, appended=True):
                    return True
    return False


def script_might_merge(text, depth=0, appended=False):
    if depth > MAX_DEPTH:
        return True
    try:
        commands, uncertain = parse(text)
    except (ParseError, IndexError, RecursionError):
        # Unreadable: bash may still run the lines before the error, so ask on
        # any mention of git, merge or pull.
        return bool(risky_mention(text) or GIT_MENTION.search(text) or re.search(r"\bgh\b", text))
    if any(risky_mention(t) for t in uncertain):
        return True
    # The word test reads decoded words and stdin too, so `printf $'git \x70ull'
    # | bash` shows `pull` where the raw text does not.
    decoded = "\n".join(
        [w.value for c in commands for w in c.words] + [t for c in commands for t in c.stdin]
    )
    literal_mentions = literal_evaluator_mentions(text)
    # Only an executing printf alongside an evaluator makes format assembly
    # opaque. A shell payload that merely prints text is checked recursively,
    # where its printf has no evaluator; printf -v alone only assigns a value.
    formatted_printf = False
    evaluator = False
    for c in commands:
        ci = command_index(c.words)
        positions = command_positions(c.words)
        if ci < len(c.words) and c.words[ci].literal and base(c.words[ci]) == "printf":
            formatted_printf |= any("%" in a.value or a.value.startswith("-v")
                                    for a in c.words[ci + 1:])
            # printf's format and data arguments cannot become commands.
            positions = {i for i in positions if i < ci}
        for i in positions:
            if i >= len(c.words):
                continue
            w = c.words[i]
            if w.literal and base(w) == "printf":
                formatted_printf |= any("%" in a.value or a.value.startswith("-v")
                                        for a in c.words[i + 1:])
            evaluator |= not w.literal or is_evaluator(c.words, i)
    if formatted_printf and evaluator and not literal_mentions:
        return True
    return any(command_might_merge(c, text + "\n" + decoded, depth, appended, literal_mentions)
               for c in commands)


def might_merge(command):
    """True when the command invokes, or could invoke, a guarded merge/push."""
    return script_might_merge(command)


# A target word cannot hide shell control syntax such as `/tmp/lane&git`.
TARGET_PATH = re.compile(r"^/[A-Za-z0-9_./:@%+=,-]+$")


def allowlisted_target(command, cwd, rejected_targets=None):
    """Return cwd only after every literal merge/pull segment passes its checks.

    Keep the old unquoted single-command forms. Compounds and explicit paths
    require --ff-only; companions are restricted to commands that cannot switch
    branches or alter git's target/config. If supplied, rejected_targets records
    a failed checkout proof only after the whole grammar passes, so unsupported
    shapes keep a generic reason. Unknown shell effects fail closed.
    """
    if not os.path.isabs(cwd) or re.search(r"[^\x20-\x7e]", command):
        return None
    # Split only a deliberately tiny literal grammar, never quoted shell text.
    if re.search(r"[\"'`$\\\n<>(){}*?\[\]~#]", command):
        return None
    parts = re.split(r"(&&|\|\||;|\|)", command)
    if any(not p.strip() or "&" in p for p in parts[::2]):
        return None
    compound = len(parts) > 1
    current = cwd
    merges = []
    for n, part in enumerate(parts[::2]):
        tokens = part.split()
        if tokens[0] == "cd":
            # Only && establishes that cd succeeded. Pipes and || do not.
            if n != 0 or len(tokens) != 2 or any(op != "&&" for op in parts[1::2]):
                return None
            path = tokens[1]
            if not TARGET_PATH.fullmatch(path) or ".." in path.split("/") or not os.path.isdir(path):
                return None
            current = os.path.realpath(path)
            continue
        target = current
        explicit = len(tokens) > 1 and tokens[:2] == ["git", "-C"]
        if explicit:
            if len(tokens) < 5 or not TARGET_PATH.fullmatch(tokens[2]) or ".." in tokens[2].split("/"):
                return None
            target = tokens[2]
            tokens = ["git"] + tokens[3:]
        if len(tokens) < 2 or tokens[0] != "git" or tokens[1] not in MERGE_WORDS:
            # A fetch from a named remote uses its configured refspec; reject
            # arbitrary refspecs, options, commands and state-changing siblings.
            if tokens in (["true"], ["false"], ["git", "status"]):
                continue
            if len(tokens) == 3 and tokens[:2] == ["git", "fetch"] and tokens[2] in (git(target, "remote") or "").split():
                # Every destination must belong to this remote, not merely
                # be a tracking ref: another prefix could redirect a later sync.
                specs = git(target, "config", "--null", "--get-all", f"remote.{tokens[2]}.fetch", strip=False)
                pattern = rf"\+?refs/heads/[^:]+:refs/remotes/{re.escape(tokens[2])}/[^:]+"
                if specs and all(re.fullmatch(pattern, x) for x in specs[:-1].split("\0")):
                    continue
            return None
        sub, rest = tokens[1], tokens[2:]
        refs = [a for a in rest if not a.startswith("-")]
        flags = set(a for a in rest if a.startswith("-"))
        if not all(REF.fullmatch(r) for r in refs):
            return None
        if sub == "merge":
            ok = (len(rest) == 1 and rest[0] in SOLO_FLAGS) or (len(refs) == 1 and flags <= MERGE_FLAGS)
        else:
            ok = len(refs) <= 2 and flags <= PULL_FLAGS and bool(flags & PULL_NO_REWRITE)
        if not ok or ((compound or explicit or current != cwd) and "--ff-only" not in flags):
            return None
        other_git = any(j != n and p.split()[0] == "git"
                        for j, p in enumerate(parts[::2]))
        merges.append((target, sub, refs, flags, other_git))
    if not merges:
        return None
    for target, sub, refs, flags, other_git in merges:
        if feature_branch(target) is None:
            if not pure_sync(target, sub, refs, flags, other_git):
                if rejected_targets is not None:
                    rejected_targets.append(target)
                return None
    return cwd


def pure_sync(cwd, sub, refs, flags, other_git=False):
    """Prove a protected checkout only advances from its own tracking ref."""
    if "--ff-only" not in flags or flags & {"--ff", "--no-ff"} or not os.path.isdir(cwd):
        return False
    head = git(cwd, "symbolic-ref", "--quiet", "HEAD")
    if not head or not head.startswith("refs/heads/"):
        return False
    branch = head[len("refs/heads/"):]
    defaults = [git(cwd, "symbolic-ref", "--quiet", f"refs/remotes/{r}/HEAD")
                for r in (git(cwd, "remote") or "").split()]
    if not any(defaults):
        return False
    upstream = git(cwd, "rev-parse", "--symbolic-full-name", "@{upstream}")
    remote = git(cwd, "config", "--get", f"branch.{branch}.remote")
    # Preserve delimiters: stripping get-all output hides empty values and
    # would make a multi-source pull look like one configured merge source.
    merge = git(cwd, "config", "--null", "--get-all", f"branch.{branch}.merge", strip=False)
    if not remote or remote == "." or merge != head + "\0" or upstream != f"refs/remotes/{remote}/{branch}":
        return False
    if not git(cwd, "rev-parse", "--verify", upstream):
        return False
    if sub == "merge":
        if refs not in ([f"{remote}/{branch}"], [upstream]):
            return False
        operand = refs[0]
        # Another git segment (notably a concurrent fetch) can import a shadowing tag.
        if other_git and operand != upstream:
            return False
        if git(cwd, "rev-parse", "--symbolic-full-name", operand) != upstream:
            return False
        shadows = {f"refs/tags/{operand}", f"refs/heads/{operand}", f"refs/{operand}"}
        found = git(cwd, "for-each-ref", "--format=%(refname)", *sorted(shadows))
        return found is not None and not shadows.intersection(found.splitlines())
    return refs in ([], [remote], [remote, head])


def git(cwd, *args, strip=True):
    out = subprocess.run(
        ["git", "-C", cwd, *args], capture_output=True, text=True, timeout=5
    )
    return (out.stdout.strip() if strip else out.stdout) if out.returncode == 0 else None


def feature_branch(cwd):
    """Return the branch if cwd is provably on a non-default named branch.

    Compares full ref names, never `--short` output: git abbreviates
    ambiguously named refs (a tag `main` makes `refs/heads/main` print as
    `heads/main`), which would slip past a short-name comparison.
    """
    if not os.path.isdir(cwd):
        return None
    head = git(cwd, "symbolic-ref", "--quiet", "HEAD")
    if not head or not head.startswith("refs/heads/"):
        return None
    branch = head[len("refs/heads/") :]
    # refs are files on a case-insensitive filesystem (macOS APFS), so
    # `Main` is `main`: compare casefolded names.
    if branch.casefold() in PROTECTED:
        return None
    defaults = set()
    for remote in (git(cwd, "remote") or "").split():
        prefix = f"refs/remotes/{remote}/"
        ref = git(cwd, "symbolic-ref", "--quiet", f"{prefix}HEAD")
        if ref and ref.startswith(prefix):
            defaults.add(ref[len(prefix) :])
    if not defaults or branch.casefold() in {d.casefold() for d in defaults}:
        return None
    return branch


def decide(command, cwd):
    """Return None (no opinion) or the reason to ask."""
    try:
        commands, _ = parse(command)
    except (ParseError, IndexError, RecursionError):
        return "unreadable merge/push command" if might_merge(command) else None
    if any(base(w) == "git" and git_subcommand(c.words, i) == "push"
           and (i != 0 or push_might_land(c.words, i, cwd)
                or (len(commands) != 1 and not push_companions_safe(command, cwd)))
           for c in commands for i, w in enumerate(c.words)):
        return "push to a default branch or an unresolved push destination"
    if not might_merge(command):
        return None
    rejected_targets = []
    target = allowlisted_target(command, cwd, rejected_targets)
    if target is None:
        if rejected_targets:
            return ("merge/pull would land on main/master or a remote default branch, "
                    f"or the target is unverifiable: {rejected_targets[0]}")
        return "merge/pull or GitHub merge in a form this guard does not allowlist"
    return None


def main():
    if os.environ.get(PROFILE_VAR, "").strip().lower() in UNGUARDED_PROFILES:
        return
    try:
        payload = json.load(sys.stdin)
        command = (payload.get("tool_input") or {}).get("command", "")
        if payload.get("tool_name") != "Bash" or not command:
            return
        reason = decide(command, payload.get("cwd") or os.getcwd())
    except Exception as exc:  # fail closed
        reason = f"guard could not analyse the command ({exc.__class__.__name__})"
    if reason:
        json.dump(
            {
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "ask",
                    "permissionDecisionReason": f"git-merge-guard: {reason}",
                }
            },
            sys.stdout,
        )


if __name__ == "__main__":
    main()
