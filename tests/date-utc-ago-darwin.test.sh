#!/bin/bash
set -euo pipefail
work=$(mktemp -d)
set +e
date -u -d '-20 minutes' '+%Y-%m-%dT%H:%M:%SZ' >"$work/red.out" 2>"$work/red.err"
red=$?
set -e
if [ "$red" -eq 0 ]; then
  echo "GNU date -d unexpectedly succeeded" >&2
  exit 1
fi
if ! grep -q "illegal option" "$work/red.err"; then
  echo "expected illegal option from date -d" >&2
  cat "$work/red.err" >&2
  exit 1
fi

if request_time="$(date -u -d '-20 minutes' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)"; then
  :
else
  request_time="$(date -u -v-20M '+%Y-%m-%dT%H:%M:%SZ')"
fi
printf '%s\n' "$request_time" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
echo "date utc ago darwin ok (date -d exit $red, time $request_time)"
rm -rf "$work"
