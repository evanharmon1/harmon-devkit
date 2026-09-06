#!/usr/bin/env bash
# test-lint-shell-robustness.sh — unit tests for lint-shell-robustness.sh, the
# guard that keeps the two status-lying shell idioms from #689 out of the tree.
#
# Why fixtures at all: run against a clean checkout the guard's only answer is
# "clean", so every detection path could be replaced with a no-op and CI would
# stay green. These fixtures are what make its findings load-bearing — and,
# just as importantly, what pin the shapes it must NOT flag: quoted text,
# comments, `||` chains and here-document bodies all contain the literal
# characters the scan looks for, and a guard that fires on those is one people
# route around instead of obeying.
#
# Run via `task test:lint-shell-robustness`.
set -euo pipefail

repo="$(git rev-parse --show-toplevel)"
GUARD="$repo/scripts/lint-shell-robustness.sh"

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

pass=0
fail=0
ok() {
    pass=$((pass + 1))
    echo "  ✓ $*" || true
    return 0
}
bad() {
    fail=$((fail + 1))
    echo "  ✗ $*" >&2 || true
    return 0
}

# fixture NAME BODY_FILE — write a fixture script and print its path. The body
# always arrives through a file so a here-doc in the fixture cannot terminate
# the one that carried it.
fixture() {
    # Separate `local` statements: bash expands every word of a single `local`
    # before running it, so `path="$TMPROOT/$name"` would read the OUTER
    # `name` — unset, and fatal under `set -u`.
    local name="$1" body="$2"
    local path="$TMPROOT/$name"
    {
        echo '#!/usr/bin/env bash'
        echo 'set -euo pipefail'
        cat "$body"
    } >"$path"
    printf '%s\n' "$path"
}

# expect_clean DESC PATH — the guard accepts the fixture.
expect_clean() {
    local desc="$1" path="$2" output
    if output="$("$GUARD" "$path" 2>&1)"; then
        ok "$desc"
    else
        bad "$desc (expected the guard to pass)"
        printf '%s\n' "$output" | sed 's/^/      /' >&2
    fi
}

# expect_flagged DESC PATH NEEDLE — the guard rejects it AND says why. A
# rejection that fires for an unrelated reason is a passing test proving
# nothing.
expect_flagged() {
    local desc="$1" path="$2" needle="$3" output
    if output="$("$GUARD" "$path" 2>&1)"; then
        bad "$desc (expected a non-zero exit)"
        printf '%s\n' "$output" | sed 's/^/      /' >&2
    elif grep -qF -- "$needle" <<<"$output"; then
        ok "$desc"
    else
        bad "$desc (rejected, but not for the expected reason: missing '$needle')"
        printf '%s\n' "$output" | sed 's/^/      /' >&2
    fi
}

body="$TMPROOT/body"

echo "==> the pipefail/SIGPIPE pipeline is rejected"

cat >"$body" <<'BODY'
out="$(printf 'hello\n')"
printf '%s\n' "$out" | grep -qF hello
BODY
expect_flagged "printf into grep -qF" "$(fixture printf-pipe.sh "$body")" '| grep -q` pipeline'

cat >"$body" <<'BODY'
if echo "$x" | grep -q needle; then :; fi
BODY
expect_flagged "echo into grep -q, inside an if" "$(fixture echo-pipe.sh "$body")" 'grep -q'

cat >"$body" <<'BODY'
git worktree list --porcelain | grep -qx "worktree $t" || exit 1
BODY
expect_flagged "a command into grep -qx" "$(fixture cmd-pipe.sh "$body")" 'grep -q'

cat >"$body" <<'BODY'
seq 1 3 | grep --quiet 2
BODY
expect_flagged "the long --quiet spelling" "$(fixture long-quiet.sh "$body")" 'grep -q'

cat >"$body" <<'BODY'
seq 1 3 | grep -F -q 2
BODY
expect_flagged "a quiet flag in a later option word" "$(fixture split-flag.sh "$body")" 'grep -q'

cat >"$body" <<'BODY'
sed 's/a/b/' file | grep -v '^#' | grep -qE 'x'
BODY
expect_flagged "the last stage of a longer pipeline" "$(fixture long-pipe.sh "$body")" 'grep -q'

# Regression: a HERESTRING is not a here-document. Reading `<<<"$var"` as one
# made the scanner treat the rest of the file as here-doc body and report a
# repository full of the idiom it hunts as clean — a silent, total false
# negative, and the worst failure a guard can have.
cat >"$body" <<'BODY'
grep -qF a <<<"$first"
printf '%s\n' "$second" | grep -qF b
BODY
expect_flagged "a herestring does not blind the rest of the file" \
    "$(fixture after-herestring.sh "$body")" 'grep -q'

cat >"$body" <<'BODY'
cat >"$f" <<'INNER'
printf '%s\n' "$x" | grep -q y
INNER
printf '%s\n' "$z" | grep -q w
BODY
expect_flagged "a real here-doc masks its body and nothing after it" \
    "$(fixture after-heredoc.sh "$body")" ':6:'

# Forms a line-oriented, depth-0-only scan lets through. Each still inherits
# `pipefail` and carries the identical defect, so a guard that calls them clean
# is not enforcing its own contract (challenge round 1, P1).
cat >"$body" <<'BODY'
( printf '%s\n' "$x" | grep -q needle )
BODY
expect_flagged "a pipeline inside a subshell" \
    "$(fixture nested-subshell.sh "$body")" ':3:'

cat >"$body" <<'BODY'
v="$(printf '%s\n' "$x" | grep -q needle && echo yes)"
BODY
expect_flagged "a pipeline inside a command substitution in double quotes" \
    "$(fixture nested-cmdsub.sh "$body")" ':3:'

cat >"$body" <<'BODY'
printf '%s\n' "$x" |
    grep -q needle
BODY
expect_flagged "a pipeline continued onto the next line" \
    "$(fixture continued-pipe.sh "$body")" ':4:'

cat >"$body" <<'BODY'
printf '%s\n' "$x" \
    | grep -q needle
BODY
expect_flagged "a continuation whose next line leads with the pipe" \
    "$(fixture continued-leading-pipe.sh "$body")" ':4:'

# A multi-line command substitution. With per-line state the closing `"` reads
# as an OPENING quote and every later line looks like text — a total silent
# bypass of the gate (challenge round 2, P1).
cat >"$body" <<'BODY'
x="$(
    printf hi
)"
printf '%s\n' "$y" | grep -q boom
BODY
expect_flagged "a multi-line command substitution does not invert the quote state" \
    "$(fixture multiline-cmdsub.sh "$body")" ':6:'

# One command can open several here-docs, and their bodies are consecutive.
# Activating only the first scans the second's first line as shell code
# (challenge round 2, P2).
cat >"$body" <<'BODY'
cat <<'A' <<'B'
printf x | grep -q x
A
printf y | grep -q y
B
printf '%s\n' "$after" | grep -q boom
BODY
expect_flagged "several here-docs opened by one command are all masked" \
    "$(fixture multi-heredoc.sh "$body")" ':8:'
if out="$("$GUARD" "$TMPROOT/multi-heredoc.sh" 2>&1)"; then
    bad "multi-heredoc fixture unexpectedly passed"
elif [ "$(grep -c 'grep -q` pipeline' <<<"$out")" -eq 1 ]; then
    ok "only the line after both here-doc bodies is flagged"
else
    bad "a here-doc body was scanned as code"
    printf '%s\n' "$out" | sed 's/^/      /' >&2
fi

# A carried quote that CLOSES mid-line leaves real code and a real comment
# behind it. Treating the whole line as quoted let an apostrophe in that
# comment reopen quoting and blind everything after — a reproducible bypass of
# this gate (challenge round 3, P1).
cat >"$body" <<'BODY'
x='a
b' # don't reopen quoting
printf '%s\n' "$y" | grep -q boom
BODY
expect_flagged "a quote closing mid-line does not blind the code after it" \
    "$(fixture quote-closes-midline.sh "$body")" ':5:'

echo "==> the fixed shapes, and lookalikes, are accepted"

cat >"$body" <<'BODY'
grep -qF hello <<<"$out"
grep -q needle < <(some-command --flag)
grep -qE '^x$' "$file"
BODY
expect_clean "herestring, process substitution and a plain file grep" \
    "$(fixture fixed.sh "$body")"

cat >"$body" <<'BODY'
# A comment mentioning `printf | grep -q needle` as prose.
value=1 # trailing note: echo "$x" | grep -q y
BODY
expect_clean "the idiom named in a comment" "$(fixture comment.sh "$body")"

cat >"$body" <<'BODY'
sh -c 'grep -A5 -F "$2" "$1" | grep -qF "$3"' sh a b c
BODY
expect_clean "a pipeline quoted inside sh -c (no pipefail there)" \
    "$(fixture quoted.sh "$body")"

cat >"$body" <<'BODY'
if [ "$rc" -ne 0 ] || grep -qi 'unknown flag' "$file"; then :; fi
BODY
expect_clean "an || chain, which is not a pipeline" "$(fixture orchain.sh "$body")"

# The stub a suite writes for a PATH shim is data, not code this guard owns —
# and some here-doc bodies are deliberately frozen snapshots of superseded
# code, which must keep their defects to stay evidence.
cat >"$body" <<'BODY'
cat >"$bin/gh" <<'STUB'
if printf '%s' "$*" | grep -q issueType; then echo yes; fi
STUB
cat >"$bin/other" <<-'INDENTED'
	echo "$x" | grep -q y
	INDENTED
BODY
expect_clean "here-document bodies, plain and <<- indented" \
    "$(fixture heredoc.sh "$body")"

cat >"$body" <<'BODY'
printf '%s\n' "$out" | grep -c hello
printf '%s\n' "$out" | grep hello >/dev/null
BODY
expect_clean "a non-quiet grep, which reads its input to EOF" \
    "$(fixture nonquiet.sh "$body")"

# Two ways a line-based lexer can go blind. Both were real defects in this
# scanner, and both are silent — the guard reports "clean" over a tree full of
# the idiom, which is strictly worse than no guard at all.
cat >"$body" <<'BODY'
expect_ok "a multi-line sh -c script is quoted text, not code" \
    sh -c 'for n in "$2" "$3"; do
        grep -F "$n" "$1" | grep -qF marker || exit 1
    done' sh "$file" a b
printf '%s\n' "$after" | grep -qF boom
BODY
expect_flagged "a multi-line quoted sh -c body is skipped, the code after it is not" \
    "$(fixture multiline-quote.sh "$body")" ':7:'

cat >"$body" <<'BODY'
# An apostrophe in prose: don't let it open a string that never closes.
printf '%s\n' "$after" | grep -qF boom
BODY
expect_flagged "an apostrophe in a comment does not blind the next line" \
    "$(fixture comment-apostrophe.sh "$body")" ':4:'

# POSIX `sh` has no `pipefail`, so the defect cannot occur there — and `<<<`
# and `< <( )` are bashisms such a script could not adopt anyway. A file with
# NO shebang stays in scope: it may be sourced into bash (challenge round 2,
# P2).
printf '#!/bin/sh\nprintf "%%s\\n" "$x" | grep -q y\n' >"$TMPROOT/posix.sh"
expect_clean "a #!/bin/sh script is out of scope for the pipeline rule" \
    "$TMPROOT/posix.sh"
printf 'printf "%%s\\n" "$x" | grep -q y\n' >"$TMPROOT/noshebang.sh"
expect_flagged "a file with no shebang stays in scope" \
    "$TMPROOT/noshebang.sh" 'grep -q'

echo "==> reporter helpers must not be able to lie about an assertion"

# The reporter scan is scoped to suites, so the fixtures below are named
# test-*.sh to be checked at all — which is itself an assertion at the end.
# Bash spells a definition four ways. Recognizing only `name()` lets a reporter
# written any other way past the guard (challenge round 3, P2).
cat >"$body" <<'BODY'
ok () {
    pass=$((pass + 1))
    echo "  ok $*"
}
BODY
expect_flagged "a reporter declared as \`name () {\`" \
    "$(fixture test-r7.sh "$body")" 'must end with `return 0`'

cat >"$body" <<'BODY'
function ok {
    pass=$((pass + 1))
    echo "  ok $*"
}
BODY
expect_flagged "a reporter declared as \`function name {\`" \
    "$(fixture test-r8.sh "$body")" 'must end with `return 0`'

cat >"$body" <<'BODY'
function ok() {
    pass=$((pass + 1))
    echo "  ok $*" || true
    return 0
}
BODY
expect_clean "a fixed reporter declared as \`function name() {\`" \
    "$(fixture test-r9.sh "$body")"

cat >"$body" <<'BODY'
ok() {
    pass=$((pass + 1))
    echo "  ✓ $*"
}
BODY
expect_flagged "a counting reporter with no return 0" \
    "$(fixture test-r1.sh "$body")" 'must end with `return 0`'

cat >"$body" <<'BODY'
ok() {
    pass=$((pass + 1))
    echo "  ✓ $*" || true
    return 0
}
BODY
expect_clean "the same reporter, fixed" "$(fixture test-r2.sh "$body")"

cat >"$body" <<'BODY'
fail() {
    echo "TEST FAIL: $*" >&2
    exit 1
}
BODY
expect_clean "a reporter that exits — its status is never read" \
    "$(fixture test-r3.sh "$body")"

cat >"$body" <<'BODY'
note() { printf '  %s\n' "$*"; }
BODY
expect_flagged "a single-line reporter with no return 0" \
    "$(fixture test-r4.sh "$body")" 'must end with `return 0`'

cat >"$body" <<'BODY'
build_fixture() {
    mkdir -p "$1"
    echo "made $1"
}
BODY
expect_clean "an ordinary helper that happens to echo" \
    "$(fixture test-r5.sh "$body")"

cat >"$body" <<'BODY'
render() {
    cases=$((cases + 1))
    echo "==> $1"
}
BODY
expect_flagged "a counter-incrementing helper under any name" \
    "$(fixture test-r6.sh "$body")" 'must end with `return 0`'

cat >"$body" <<'BODY'
ok() {
    pass=$((pass + 1))
    echo "  ✓ $*"
}
BODY
expect_clean "the reporter scan is scoped to test-*.sh suites" \
    "$(fixture helper-lib.sh "$body")"

echo "==> the hazard the guard exists for is real, and the fixed shapes are not"
# The guard's whole premise is that `producer | grep -q` can report a MATCH as
# a failure. Assert the FIXED shapes stay correct on a payload far past the
# 64 KiB pipe buffer — that is the deterministic half. The legacy shape's
# verdict is recorded as a diagnostic rather than asserted: it is a race on
# how much is still in flight when grep exits, so pinning it would be pinning
# a probability.
big="$(seq 1 40000)"
haystack="NEEDLE
$big"

if grep -qF NEEDLE <<<"$haystack"; then
    ok "herestring: a match on a $((${#haystack} / 1024)) KiB payload reads as a match"
else
    bad "herestring: a match on a $((${#haystack} / 1024)) KiB payload read as a FAILURE"
fi

if grep -qF NEEDLE < <(printf '%s\n' "$haystack"); then
    ok "process substitution: the same match reads as a match"
else
    bad "process substitution: the same match read as a FAILURE"
fi

# The legacy shape has to live in a here-doc: it is exactly what this guard
# forbids, so writing it inline would (correctly) fail the guard's own run over
# the repository below.
cat >"$TMPROOT/legacy-probe.sh" <<'PROBE'
#!/usr/bin/env bash
set -euo pipefail
haystack="$(cat "$1")"
printf '%s\n' "$haystack" | grep -qF NEEDLE
PROBE

printf '%s\n' "$haystack" >"$TMPROOT/haystack.txt"
legacy=0
bash "$TMPROOT/legacy-probe.sh" "$TMPROOT/haystack.txt" || legacy=$?
case "$legacy" in
0) echo "  · note: the legacy pipeline happened to report the match this run" || true ;;
141) echo "  · note: the legacy pipeline reported 141 (SIGPIPE) for a MATCH" \
    "— the defect, reproduced" || true ;;
*) echo "  · note: the legacy pipeline exited $legacy (not the SIGPIPE path)" || true ;;
esac

echo "==> a path the caller named but that is not there is an error, not clean"
if out="$("$GUARD" "$TMPROOT/definitely-absent.sh" 2>&1)"; then
    bad "a missing named file was reported clean"
elif grep -qF 'no such file' <<<"$out"; then
    ok "a missing named file is refused, not silently skipped"
else
    bad "a missing named file failed, but not with 'no such file'"
    printf '%s\n' "$out" | sed 's/^/      /' >&2
fi

echo "==> the guard is wired to the real tree"
if "$GUARD" >/dev/null 2>&1; then
    ok "the repository's own shell scripts pass the guard"
else
    bad "the repository's own shell scripts do not pass the guard"
    "$GUARD" 2>&1 | sed 's/^/      /' >&2 || true
fi

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
