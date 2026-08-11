#!/bin/sh
# Chain an external write off a background gate's verdict, mechanically.
#
# A backgrounded gate (`task ci`, `task verify`, ...) writes its output to a
# file and appends one verdict line — a marker such as CI-GREEN or CI-FAILED —
# as its final act. The next external write (a push, a PR comment) must chain
# off that verdict, and readers cannot stand in for it: `tail -1 file &&
# git push` pushes on a FAILED marker, because tail succeeds by PRINTING the
# marker, whatever it says. This helper is the mechanical parse: exit 0 only
# when the file's marker line equals the expected token, so
# `require-marker.sh file "$token" && git push ...` chains off the gate's
# verdict and nothing else. It proves what the file SAYS, not which run said
# it — binding the verdict to the run that just finished is the caller's
# token choice; see the usage text.

set -u

usage() {
    cat >&2 <<'EOF'
Usage: require-marker.sh FILE TOKEN

Exit 0 only when FILE's marker line equals TOKEN.

The marker line is FILE's last line that is non-empty after leading and
trailing whitespace (including any carriage return) is stripped; it is
compared with TOKEN by exact string equality after that same stripping.
Everything above it is ordinary gate output and is never consulted, and a
gate that has not finished has not written its marker yet, so the
comparison fails closed.

TOKEN must be one non-empty line with no leading or trailing whitespace —
anything else could never equal a marker line and is a usage error. Make
it unique to the gate run AND the commit it gated: this parser proves what
the file says, not which run said it, so a static token (CI-GREEN) can
match a stale file an earlier run left behind, and a run-only token can
authorize a commit the gate never saw. Mint the token before the gate
starts, carrying the SHA under test — e.g.
sha="$(git rev-parse HEAD)"; token="CI-GREEN-$sha-$$" — write the gate's
output to a fresh per-run file, and have the wrapper append the token
only on success, with a LEADING newline so gate output that ends without
one cannot glue itself to the token:
  task ci >"$out" 2>&1 && printf '\n%s\n' "$token" >>"$out"
Then push the captured SHA itself, never the mutable HEAD. A stale file
can never contain this run's token, a failed or unfinished gate never
writes it, and a HEAD that moved after the gate is simply not what the
refspec pushes — comparing HEAD to the SHA first and then pushing HEAD
re-reads the ref at push time, so the comparison alone races.

Exit status:
  0  FILE's marker line equals TOKEN
  1  FILE is missing or unreadable, has no marker line (empty or all
     blank lines), or its marker line differs from TOKEN; the reason is
     on stderr
  2  usage error

Chain external writes off THIS exit status, never off a reader's exit —
tail, head, cat, and grep succeed by printing whatever the marker says:
  require-marker.sh "$out" "$token" && git push <remote> "$sha:<branch>"
EOF
    exit 2
}

refuse() {
    printf 'require-marker: %s\n' "$1" >&2
    exit 1
}

[ "$#" -eq 2 ] || usage
file=$1
token=$2

nl='
'
case "$token" in
'' | *"$nl"*) usage ;;
[[:space:]]* | *[[:space:]]) usage ;;
esac

[ -e "$file" ] || refuse "$file: no such file"
[ -f "$file" ] || refuse "$file: not a regular file"
[ -r "$file" ] || refuse "$file: not readable"

marker=$(awk '
    {
        sub(/^[[:space:]]+/, "")
        sub(/[[:space:]]+$/, "")
        if ($0 != "") last = $0
    }
    END { if (last != "") print last }
' "$file") || refuse "$file: cannot read"

[ -n "$marker" ] || refuse "$file: no marker line (file is empty or all blank)"

[ "$marker" = "$token" ] ||
    refuse "$file: marker line '$(printf '%.200s' "$marker")' does not equal '$token'"

exit 0
