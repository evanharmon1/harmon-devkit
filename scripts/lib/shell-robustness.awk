# shell-robustness.awk — the scanner behind scripts/lint-shell-robustness.sh.
#
# Reports, one finding per line, `path:line: message`:
#   * a `PRODUCER | grep -q…` pipeline, whose status lies when grep's early
#     exit SIGPIPEs a still-writing producer under `set -o pipefail`
#   * a test-suite reporter helper that does not end in `return 0`, whose
#     status is then mistaken for the assertion's in `check && ok || bad`
#
# Both scans skip here-document bodies, comments, and quoted text. Here-doc
# bodies in particular carry stub and fixture payloads — including frozen
# snapshots of superseded code that exist precisely to be wrong.
#
# THE FAILURE MODE THIS FILE MUST AVOID is a false NEGATIVE. A guard that
# reports a tree clean while the defect is present is worse than no guard:
# people trust it. Three separate lexer bugs here did exactly that before this
# scanner was trusted (a herestring read as a here-doc opener, an apostrophe in
# a comment opening a string that never closed, and a multi-line command
# substitution inverting the quote state). Every one of them is pinned by a
# case in scripts/test-lint-shell-robustness.sh. Add a case before changing the
# lexer.
#
# Invoked as: awk -v FILE=<path> -f scripts/lib/shell-robustness.awk <path>

# ── lexical scan ────────────────────────────────────────────────────────────
# Fill Q[i] — 1 when index i is quoted, escaped, or is itself a quote char —
# and carry the quote and command-substitution state out in globals so the
# next line resumes exactly where this one ended.
#
# What must be carried, and why:
#   * quotes, because a multi-line `sh -c '…'` argument is quoted TEXT whose
#     inner shell has no `pipefail` of its own — reading each line fresh both
#     flags it wrongly and, in a rewriter driven by the same lexer, edits
#     bash-only redirections into a POSIX `sh` script;
#   * the command-substitution stack, because `x="$(` … `)"` spans lines and a
#     per-line reset makes the closing `"` read as an OPENING quote, blinding
#     every line that follows.
#
# Generic bracket depth is deliberately NOT tracked: `case foo)` patterns leave
# it unbalanced by design, and a depth that drifts would suppress findings. A
# substitution's own nesting is counted separately in SPAREN so `$( … ( … ) … )`
# still closes on the right paren.
function scan(s,    i, c, sq, dq, n) {
    delete Q
    sq = CARRY_SQ
    dq = CARRY_DQ
    n = length(s)
    for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        Q[i] = 1
        # A command substitution restarts quoting, INCLUDING inside a
        # double-quoted string: the code in `"$(cmd | grep -q x)"` is code, not
        # text, and it inherits `pipefail` like any other.
        if (!sq && c == "$" && substr(s, i + 1, 1) == "(") {
            SP++
            SSQ[SP] = sq
            SDQ[SP] = dq
            SPAREN[SP] = 0
            Q[i] = dq
            i++
            Q[i] = dq
            sq = 0
            dq = 0
            continue
        }
        if (sq) {
            if (c == "'") sq = 0
            continue
        }
        if (dq) {
            if (c == "\\") { i++; Q[i] = 1; continue }
            if (c == "\"") dq = 0
            continue
        }
        if (c == "\\") { i++; Q[i] = 1; continue }
        if (c == "'") { sq = 1; continue }
        if (c == "\"") { dq = 1; continue }
        if (c == "(") {
            if (SP > 0) SPAREN[SP]++
        } else if (c == ")") {
            if (SP > 0) {
                if (SPAREN[SP] == 0) {
                    sq = SSQ[SP]
                    dq = SDQ[SP]
                    SP--
                } else {
                    SPAREN[SP]--
                }
            }
        }
        Q[i] = 0
    }
    CARRY_SQ = sq
    CARRY_DQ = dq
}

# Index of the `#` that starts a comment, or length+1 when the line has none.
function comment_start(s,    i, p, n) {
    n = length(s)
    for (i = 1; i <= n; i++) {
        if (substr(s, i, 1) != "#" || Q[i]) continue
        p = (i == 1) ? " " : substr(s, i - 1, 1)
        if (p == " " || p == "\t" || p == ";" || p == "&" || p == "|" || p == "(")
            return i
    }
    return n + 1
}

# Queue every here-document this line opens, so the following lines are masked.
# The leading `(^|[^<])` is load-bearing: without it a HERESTRING `<<<"$var"`
# matches as `<<` plus a quoted word starting at its SECOND `<`, and the scan
# then treats the whole rest of the file as here-doc body — silently masking
# every real finding after the first herestring.
function queue_heredocs(code,    rest, off, m, body, dash, adj, start, len) {
    rest = code
    off = 0
    while (match(rest, /(^|[^<])<<[^<-]|(^|[^<])<<-/)) {
        # Save the outer match position IMMEDIATELY: the inner match() below
        # overwrites RSTART/RLENGTH, and reading them afterwards indexes Q[] at
        # the wrong column — which silently dropped every here-doc after the
        # first on a line that opens several (`cmd <<A <<B`).
        start = RSTART
        adj = (substr(rest, start, 1) == "<") ? 0 : 1
        m = substr(rest, start + adj)
        if (m !~ /^<<-?[ \t]*('[^']+'|"[^"]+"|[A-Za-z_][A-Za-z0-9_]*)/) {
            rest = substr(rest, start + adj + 2)
            off += start + adj + 1
            continue
        }
        match(m, /^<<-?[ \t]*('[^']+'|"[^"]+"|[A-Za-z_][A-Za-z0-9_]*)/)
        len = RLENGTH
        body = substr(m, 1, len)
        rest = substr(m, len + 1)
        if (Q[off + start + adj]) {     # the `<<` itself sits inside quotes
            off += start + adj + len - 1
            continue
        }
        off += start + adj + len - 1
        dash = (substr(body, 3, 1) == "-") ? 1 : 0
        sub(/^<<-?[ \t]*/, "", body)
        gsub(/['"]/, "", body)
        npend++
        PEND[npend] = body
        PDASH[npend] = dash
    }
}

# Move the next queued here-doc into the active slot. One command can open
# several (`cmd <<A <<B`), and their bodies are CONSECUTIVE — so B must become
# active the instant A's terminator is consumed, or B's first line is scanned
# as shell code.
function activate_heredoc(    i) {
    if (npend == 0) return
    hd = PEND[1]
    hddash = PDASH[1]
    for (i = 1; i < npend; i++) {
        PEND[i] = PEND[i + 1]
        PDASH[i] = PDASH[i + 1]
    }
    npend--
}

# 1 when REST is a `grep` invocation carrying a quiet flag.
function grep_is_quiet(rest,    n, t, i, w) {
    if (rest !~ /^grep([ \t]|$)/) return 0
    n = split(rest, t, /[ \t]+/)
    for (i = 2; i <= n; i++) {
        w = t[i]
        if (w == "--") return 0
        if (substr(w, 1, 1) != "-") return 0
        if (w == "--quiet" || w == "--silent") return 1
        if (w ~ /^-[A-Za-z]*q/) return 1
    }
    return 0
}

# Column of a real `| grep -q…` pipe on this line, or 0. A pipeline inside a
# subshell or a command substitution counts: it inherits `pipefail` from the
# parent shell and carries exactly the same defect.
function find_pipe_grep(code,    i, rest, n) {
    n = length(code)
    for (i = 1; i < n; i++) {
        if (substr(code, i, 1) != "|" || Q[i]) continue
        if (substr(code, i, 2) == "||") continue
        if (i > 1 && substr(code, i - 1, 1) == "|") continue
        rest = substr(code, i + 1)
        sub(/^[ \t]+/, "", rest)
        if (grep_is_quiet(rest)) return i
    }
    return 0
}

# 1 when CODE ends with a pipe that continues onto the next line. Bash accepts
# both `producer |` + newline and `producer \` + newline + `| grep -q …`.
function ends_open_pipe(code,    n, c) {
    n = length(code)
    while (n > 0 && (substr(code, n, 1) == " " || substr(code, n, 1) == "\t")) n--
    if (n == 0) return 0
    c = substr(code, n, 1)
    if (c != "|" || Q[n]) return 0
    if (n > 1 && substr(code, n - 1, 1) == "|") return 0
    return 1
}

function ends_backslash(code,    n) {
    n = length(code)
    while (n > 0 && (substr(code, n, 1) == " " || substr(code, n, 1) == "\t")) n--
    return (n > 0 && substr(code, n, 1) == "\\")
}

# ── reporter-helper scan (scripts/test-*.sh only) ───────────────────────────
# Bash spells a function definition four ways — `n() {`, `n () {`,
# `function n {` and `function n() {`. Recognizing only the first lets a
# reporter written any other way past this guard.
function is_fn_open(code) {
    return (code ~ /^(function[ \t]+)?[a-zA-Z_][a-zA-Z0-9_]*([ \t]*\(\))?[ \t]*\{[ \t]*$/ &&
        code ~ /(^function[ \t]|\(\))/)
}

function is_fn_oneline(code) {
    return (code ~ /^(function[ \t]+)?[a-zA-Z_][a-zA-Z0-9_]*([ \t]*\(\))?[ \t]*\{.*\}[ \t]*$/ &&
        code ~ /(^function[ \t]|\(\))/)
}

function fn_name(code,    n) {
    n = code
    sub(/^[ \t]*function[ \t]+/, "", n)
    sub(/[ \t]*\(\).*$/, "", n)
    sub(/[ \t]*\{.*$/, "", n)
    gsub(/[ \t]/, "", n)
    return n
}

function reporter_name(name) {
    return (name == "ok" || name == "bad" || name == "pass" || name == "fail" ||
        name == "failed" || name == "good" || name == "note" || name == "warn" ||
        name == "skip" || name == "skipped" || name == "report")
}

function flush_fn(    prints, counts, exits, i) {
    if (fn == "") return
    prints = counts = exits = 0
    for (i = 1; i <= nbody; i++) {
        if (BODY[i] ~ /(^|[ \t;&|(])(echo|printf)([ \t]|$)/) prints = 1
        if (BODY[i] ~ /^[ \t]*[A-Za-z_][A-Za-z0-9_]*=\$\(\([A-Za-z_]/) counts = 1
        if (BODY[i] ~ /(^|[ \t;&|(])exit([ \t]|$)/) exits = 1
    }
    if (prints && !exits && (reporter_name(fn) || counts)) {
        if (nbody == 0 || BODY[nbody] !~ /(^[ \t]*|[;&][ \t]*)return 0[ \t]*;?[ \t]*$/)
            printf "%s:%d: reporter `%s()` must end with `return 0` —" \
                " otherwise its own status is read as the assertion's\n", FILE, fnline, fn
    }
    fn = ""
    nbody = 0
}

BEGIN {
    hd = ""
    npend = 0
    CARRY_SQ = 0
    CARRY_DQ = 0
    SP = 0
    open_pipe = 0
    fn = ""
    nbody = 0
    is_bash = 1
    is_suite = (FILE ~ /(^|\/)test-[^\/]*\.sh$/)
}

# ── per line ────────────────────────────────────────────────────────────────
{
    line = $0

    # The pipeline rule is a bash rule. POSIX `sh` has no `pipefail`, so a
    # matching `grep -q` cannot be turned into a failure there — and the fixed
    # shapes this guard recommends (`<<<`, `< <( )`) are bashisms a `#!/bin/sh`
    # script could not adopt anyway. A file with NO shebang stays in scope: it
    # may be sourced into bash, and the strict answer is the safe one.
    if (FNR == 1 && line ~ /^#!/) is_bash = (line ~ /bash/)

    if (hd != "") {
        t = line
        if (hddash) sub(/^[ \t]+/, "", t)
        sub(/[ \t]+$/, "", t)
        if (t == hd) {
            hd = ""
            activate_heredoc()
        }
        next
    }

    # Two passes. The first only locates the comment; the second is
    # authoritative and sees the CODE alone, because an apostrophe in prose
    # ("# don't") would otherwise open a single-quoted string that never
    # closes and blind every line after it.
    started_quoted = (CARRY_SQ || CARRY_DQ)
    save_sq = CARRY_SQ
    save_dq = CARRY_DQ
    save_sp = SP
    scan(line)
    # comment_start() consults Q[], so a `#` still inside the carried quote is
    # already ignored. Special-casing `started_quoted` to "no comment on this
    # line" was strictly worse: a quote that CLOSES mid-line leaves real code
    # and a real comment behind it, and an apostrophe in that comment then
    # reopened quoting and blinded every line after it — a reproducible bypass
    # of this gate.
    cs = comment_start(line)
    code = substr(line, 1, cs - 1)
    CARRY_SQ = save_sq
    CARRY_DQ = save_dq
    SP = save_sp
    scan(code)

    # A pipeline continued from the previous line: `producer |` (or
    # `producer \` then a leading `|`) with grep as this line's first word.
    cont = code
    sub(/^[ \t]+/, "", cont)
    if (open_pipe) sub(/^\|[ \t]*/, "", cont)

    # No `started_quoted` guard here either: find_pipe_grep() already skips any
    # pipe whose Q[] says it is inside a string, so a multi-line `sh -c '…'`
    # body stays exempt — while code after a quote that closed mid-line is
    # correctly scanned. The extra guard only ever hid findings.
    if (is_bash &&
        (find_pipe_grep(code) > 0 || (open_pipe && grep_is_quiet(cont))))
        printf "%s:%d: `| grep -q` pipeline — grep's early exit SIGPIPEs the" \
            " producer, so `pipefail` reports a MATCH as a failure;" \
            " use `grep -q PAT <<<\"$var\"` or `grep -q PAT < <(cmd)`\n", FILE, FNR

    open_pipe = ends_open_pipe(code) || (ends_backslash(code) && open_pipe)

    if (is_suite && !started_quoted) {
        if (fn != "" && code ~ /^\}/) {
            flush_fn()
        } else if (fn != "") {
            nbody++
            BODY[nbody] = code
        } else if (is_fn_open(code)) {
            fn = fn_name(code)
            fnline = FNR
            nbody = 0
        } else if (is_fn_oneline(code)) {
            fn = fn_name(code)
            fnline = FNR
            nbody = 1
            BODY[1] = code
            sub(/^[^{]*\{/, "", BODY[1])
            sub(/\}[ \t]*$/, "", BODY[1])
            flush_fn()
        }
    }

    queue_heredocs(code)
    if (hd == "") activate_heredoc()
}

END { flush_fn() }
