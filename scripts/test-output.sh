#!/usr/bin/env bash
# Unit-test the shared output library without requiring a terminal or gum.
set -euo pipefail
cd "$(dirname "$0")/.."

lib="$PWD/scripts/lib/output.sh"
fail() {
    echo "TEST FAIL: $*" >&2
    exit 1
}

echo "==> redirected output is stable ASCII"
plain="$(NO_COLOR=1 bash -c '. "$1"; action_banner secret "Credential" "stdin only"; checkline ok "Step" "complete"; checkline na "Optional" "skipped"; output_summary "Write"; output_done "finished"' _ "$lib")"
case "$plain" in
*$'\033'*) fail "NO_COLOR output contains ANSI escapes" ;;
esac
case "$plain" in
*'== SECRET :: Credential =='*'[x] Step - complete'*'SUMMARY: Write - succeeded=1 failed=0 attention=0 skipped=1 total=2'*'DONE: finished'*) ;;
*) fail "plain output omitted the stable heading, outcome, or summary" ;;
esac
printf '%s\n' "$plain" | LC_ALL=C od -An -tu1 -v | awk '
    { for (i = 1; i <= NF; i++) if ($i != 9 && $i != 10 && $i != 13 && ($i < 32 || $i > 126)) exit 1 }
' || fail "plain output contains non-ASCII bytes"

echo "==> a capable terminal gets ANSI color and Unicode"
color="$(env -u NO_COLOR PATH=/usr/bin:/bin LANG=C.UTF-8 TERM=xterm-256color OUTPUT_TEST_TTY=1 \
    bash -c '. "$1"; action_banner setup "Repository" "configure"; checkline ok "Step" "complete"; checkline unknown "Review" "pending"; output_summary "Setup"; output_done "ready"' _ "$lib")"
case "$color" in *$'\033['*) ;; *) fail "terminal output did not include ANSI color" ;; esac
case "$color" in *'⚙  SETUP'*'✓'*'Step — complete'*'╭─ Setup'*'Attention'*'╰─ ✨'*'ready'*) ;;
*) fail "terminal output did not include the Unicode presentation" ;;
esac

echo "==> task families have visually distinct semantic accents"
setup_color="$(env -u NO_COLOR PATH=/usr/bin:/bin LANG=C.UTF-8 TERM=xterm-256color OUTPUT_TEST_TTY=1 \
    bash -c '. "$1"; action_banner setup "One"' _ "$lib")"
secret_color="$(env -u NO_COLOR PATH=/usr/bin:/bin LANG=C.UTF-8 TERM=xterm-256color OUTPUT_TEST_TTY=1 \
    bash -c '. "$1"; action_banner secret "Two"' _ "$lib")"
[ "$setup_color" != "$secret_color" ] || fail "setup and secret banners rendered identically"
case "$setup_color" in *$'\033[1;36m'*) ;; *) fail "setup banner lost its cyan accent" ;; esac
case "$secret_color" in *$'\033[1;35m'*) ;; *) fail "secret banner lost its magenta accent" ;; esac

echo "==> a non-UTF-8 locale disables gum and Unicode presentation"
non_utf8="$(env -u NO_COLOR LC_ALL=C TERM=xterm-256color CLICOLOR_FORCE=1 OUTPUT_TEST_TTY=1 \
    bash -c '. "$1"; printf "capabilities=%s/%s\n" "$HAS_GUM" "$USE_UNICODE"; action_banner setup "Repository"' _ "$lib")"
case "$non_utf8" in *'capabilities=false/false'*'*  SETUP'*) ;; *) fail "non-UTF-8 terminal did not select the ASCII presentation" ;; esac
printf '%s\n' "$non_utf8" | LC_ALL=C od -An -tu1 -v | awk '
    { for (i = 1; i <= NF; i++) if ($i > 127) exit 1 }
' || fail "non-UTF-8 presentation contains Unicode bytes"

echo "==> a broken optional gum falls back without aborting the task"
fake_bin="$(mktemp -d)"
trap 'rm -rf "$fake_bin"' EXIT
cat >"${fake_bin}/gum" <<'EOF'
#!/bin/sh
exit 42
EOF
chmod +x "${fake_bin}/gum"
gum_fallback="$(env -u NO_COLOR PATH="${fake_bin}:/usr/bin:/bin" LANG=C.UTF-8 \
    TERM=xterm-256color OUTPUT_TEST_TTY=1 bash -euo pipefail -c '
        . "$1"
        action_banner setup "Repository" "configure"
        section_header "Details"
        printf "inside\n" | section_box
        kv "State" "ready"
        printf "REACHED-END\n"
    ' _ "$lib")"
case "$gum_fallback" in
*$'\033[1;36m'*'Repository'*'Details'*'inside'*'State:'*'ready'*'REACHED-END'*) ;;
*) fail "broken gum did not fall back to the complete built-in presentation" ;;
esac

echo "==> TERM=dumb wins over forced color"
dumb="$(TERM=dumb CLICOLOR_FORCE=1 LANG=C.UTF-8 \
    bash -c '. "$1"; checkline ok "Step"' _ "$lib")"
case "$dumb" in
*$'\033'*) fail "TERM=dumb output contains ANSI escapes" ;;
esac
case "$dumb" in
*'[x] Step'*) ;;
*) fail "TERM=dumb output did not fall back to ASCII" ;;
esac

echo "==> non-terminal commands preserve status without control sequences"
set +e
non_tty="$(OUTPUT_FD=2 bash -c '. "$1"; output_run "Working" bash -c "exit 37"' _ "$lib" 2>&1)"
non_tty_rc=$?
set -e
[ "$non_tty_rc" -eq 37 ] || fail "output_run changed exit 37 to $non_tty_rc"
case "$non_tty" in
*$'\033'*) fail "non-terminal output_run emitted control sequences" ;;
esac

echo "==> spinner cleanup leaves no job and preserves command status"
set +e
spinner="$(env -u CI -u NO_COLOR OUTPUT_FD=2 OUTPUT_TEST_TTY=1 OUTPUT_TEST_SPINNER=1 OUTPUT_SPINNER_DELAY=0.01 \
    LANG=C.UTF-8 TERM=xterm-256color bash -c '
        . "$1"
        output_run "Working" bash -c "sleep 0.04; exit 23"
        rc=$?
        [ -z "$(jobs -pr)" ] || exit 91
        exit "$rc"
    ' _ "$lib" 2>&1)"
spinner_rc=$?
set -e
[ "$spinner_rc" -eq 23 ] || fail "spinner path returned $spinner_rc instead of 23"
case "$spinner" in
*$'\033[2K'*'Working'*) ;;
*) fail "forced terminal path did not animate" ;;
esac
case "$spinner" in
*$'\r\033[2K') ;;
*) fail "spinner did not erase its final frame" ;;
esac

echo "==> command diagnostics render only after the spinner is erased"
set +e
diagnostic="$(env -u CI -u NO_COLOR OUTPUT_FD=2 OUTPUT_TEST_TTY=1 OUTPUT_TEST_SPINNER=1 OUTPUT_SPINNER_DELAY=0.01 \
    LANG=C.UTF-8 TERM=xterm-256color bash -c '
        . "$1"
        output_run "Working" bash -c "sleep 0.04; echo API-failed >&2; exit 29"
    ' _ "$lib" 2>&1)"
diagnostic_rc=$?
set -e
[ "$diagnostic_rc" -eq 29 ] || fail "diagnostic spinner path returned $diagnostic_rc instead of 29"
case "$diagnostic" in
*$'\r\033[2KAPI-failed') ;;
*) fail "command diagnostic was not serialized after spinner cleanup" ;;
esac

echo "==> NO_COLOR disables animation even on a terminal"
no_color_spinner="$(env -u CI NO_COLOR=1 OUTPUT_FD=2 OUTPUT_TEST_TTY=1 OUTPUT_TEST_SPINNER=1 \
    bash -c '. "$1"; output_run "Working" true' _ "$lib" 2>&1)"
case "$no_color_spinner" in
*$'\033'*) fail "NO_COLOR spinner path emitted terminal controls" ;;
esac

echo "PASS: shared output fallbacks and spinner lifecycle"
