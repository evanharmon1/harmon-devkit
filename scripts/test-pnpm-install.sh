#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/pnpm-install-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/runner" "$tmp/project"
cat >"$tmp/bin/pnpm" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$PNPM_CONFIG_STORE_DIR" >> "$CALLS"
case "$SCENARIO:$(wc -l < "$CALLS" | tr -d ' ')" in
    success:1|capture-fails:1) exit 0 ;;
    malformed:1|retry-fails:1|publish-fails:1) echo '[ERR_PNPM_ERR_SQLITE_ERROR] database disk image is malformed' >&2; exit 7 ;;
    direct:1) echo '[ERR_SQLITE_ERROR] database disk image is malformed' >&2; exit 7 ;;
    malformed:2 | direct:2 | publish-fails:2) exit 0 ;;
    retry-fails:2) echo 'retry failed' >&2; exit 23 ;;
    unrelated:1|capture-and-install-fail:1) echo 'lockfile mismatch' >&2; exit 9 ;;
    streaming:1)
        echo 'live diagnostic' >&2
        for _ in {1..100}; do
            [ -f "$STREAM_RELEASE" ] && exit 9
            sleep 0.1
        done
        exit 98 ;;
    sqlite-other:1) echo '[ERR_PNPM_ERR_SQLITE_ERROR] database is locked' >&2; exit 8 ;;
    *) exit 99 ;;
esac
STUB
chmod +x "$tmp/bin/pnpm"
real_tee="$(command -v tee)"
export REAL_TEE="$(cd "$(dirname "$real_tee")" && pwd -P)/$(basename "$real_tee")"
cat >"$tmp/bin/tee" <<'STUB'
#!/usr/bin/env bash
case "$SCENARIO" in
    capture-fails|capture-and-install-fail) cat >/dev/null; exit 42 ;;
    *) exec "$REAL_TEE" "$@" ;;
esac
STUB
chmod +x "$tmp/bin/tee"
export PATH="$tmp/bin:$PATH" RUNNER_TEMP="$tmp/runner" CALLS="$tmp/calls" GITHUB_ENV="$tmp/env" GITHUB_STEP_SUMMARY="$tmp/summary"
export PNPM_CONFIG_STORE_DIR="$RUNNER_TEMP/.pnpm-store" npm_config_store_dir="$RUNNER_TEMP/.pnpm-store"
run_case() {
    local scenario="$1" expected="$2" calls="$3" rc=0
    : >"$CALLS"
    : >"$GITHUB_ENV"
    : >"$GITHUB_STEP_SUMMARY"
    if [ "$scenario" = publish-fails ]; then
        GITHUB_ENV="$tmp/env-dir"
        mkdir -p "$GITHUB_ENV"
    fi
    SCENARIO="$scenario" "$root/scripts/pnpm-install.sh" >"$tmp/output" 2>&1 || rc=$?
    [ "$rc" -eq "$expected" ] || {
        echo "$scenario: exit $rc, expected $expected" >&2
        exit 1
    }
    [ "$(wc -l <"$CALLS" | tr -d ' ')" -eq "$calls" ] || {
        echo "$scenario: wrong call count" >&2
        exit 1
    }
    [ "$(head -n 1 "$CALLS")" = "$RUNNER_TEMP/.pnpm-store" ]
    if [ "$calls" -eq 2 ]; then
        fresh="$(tail -n 1 "$CALLS")"
        case "$fresh" in "$RUNNER_TEMP"/pnpm-recovery.*) ;; *) exit 1 ;; esac
        [ -d "$fresh" ]
        grep -q 'database disk image is malformed' "$tmp/output"
        grep -qi 'dependency setup' "$GITHUB_STEP_SUMMARY"
        if [ "$expected" -eq 0 ]; then grep -Fq "$fresh" "$GITHUB_ENV"; fi
        if [ "$scenario" = publish-fails ]; then
            grep -qi "could not publish" "$GITHUB_STEP_SUMMARY"
            if grep -q "recovered on the single retry" "$GITHUB_STEP_SUMMARY"; then
                echo "publish-fails: unexpected recovery-success summary" >&2
                exit 1
            fi
            GITHUB_ENV="$tmp/env"
        fi
    elif [ "$expected" -ne 0 ]; then
        grep -qi 'dependency setup' "$GITHUB_STEP_SUMMARY"
        [ ! -s "$GITHUB_ENV" ]
    fi
}
cd "$tmp/project"
touch package.json
: >"$CALLS"
export STREAM_RELEASE="$tmp/release"
SCENARIO=streaming "$root/scripts/pnpm-install.sh" >"$tmp/stream-output" 2>&1 &
install_pid=$!
observed=0
for _ in {1..50}; do
    if grep -q 'live diagnostic' "$tmp/stream-output"; then
        observed=1
        break
    fi
    sleep 0.1
done
touch "$STREAM_RELEASE"
rc=0
wait "$install_pid" || rc=$?
[ "$observed" -eq 1 ] || {
    echo 'diagnostic was buffered until install completed' >&2
    exit 1
}
[ "$rc" -eq 9 ] || {
    echo "streaming: exit $rc, expected 9" >&2
    exit 1
}
[ "$(wc -l <"$CALLS" | tr -d ' ')" -eq 1 ]
run_case success 0 1
run_case malformed 0 2
run_case direct 0 2
run_case unrelated 9 1
run_case capture-fails 42 1
run_case capture-and-install-fail 9 1
run_case sqlite-other 8 1
run_case retry-fails 23 2
run_case publish-fails 1 2
echo 'pnpm install recovery tests passed'
