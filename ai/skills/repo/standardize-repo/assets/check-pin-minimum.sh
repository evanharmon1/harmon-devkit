#!/usr/bin/env bash
# Usage: check-pin-minimum.sh <template-checkout> <verified-ref> [skills-manifest]
# stdout: one JSON verdict; exit 0=ok, 1=below-minimum, 2=unknown, 3=error (including unavailable yq).
set -u
python3 - "$@" <<'PY'
import json
import re
import subprocess
import sys


def unknown(reason):
    print(json.dumps({'verdict': 'unknown', 'reason': reason}, separators=(',', ':')))
    sys.exit(2)


def yq_unavailable():
    print('yq v4 is unavailable or failed', file=sys.stderr)
    print('{"verdict":"error","reason":"yq-unavailable"}')
    sys.exit(3)


def entries(data, expression):
    try:
        result = subprocess.run(['yq', '-o=json', expression, '-'], input=data,
                                text=True, capture_output=True)
    except OSError:
        yq_unavailable()
    if result.returncode:
        if 'go-yaml load error' in result.stderr:
            unknown('read-error')
        yq_unavailable()
    try:
        return json.loads(result.stdout)
    except ValueError:
        yq_unavailable()


if len(sys.argv) not in (3, 4):
    print('usage: check-pin-minimum.sh <template-checkout> <verified-ref> [skills-manifest]', file=sys.stderr)
    sys.exit(3)
checkout, ref = sys.argv[1:3]
manifest = sys.argv[3] if len(sys.argv) == 4 else '.skills-sync.yaml'
try:
    version = subprocess.run(['yq', '--version'], text=True, capture_output=True)
except OSError:
    yq_unavailable()
if version.returncode or not re.search(r'yq \(https://github\.com/mikefarah/yq/\) version v4\.', version.stdout):
    yq_unavailable()
try:
    template = subprocess.run(['git', '-C', checkout, 'show', ref + ':copier.yml'],
                              text=True, capture_output=True, check=True)
    minimums = entries(template.stdout, '[. | to_entries | .[] | select(.key == "_min_harmon_devkit_skills") | .value]')
    if len(minimums) > 1:
        unknown('duplicate-key')
    if not minimums:
        unknown('no-declared-minimum')
    minimum = minimums[0]
    try:
        with open(manifest, encoding='utf-8') as f:
            data = f.read()
    except FileNotFoundError:
        unknown('no-skills-manifest')
    sources = entries(data, '[. | to_entries | .[] | select(.key == "source") | .value]')
    if len(sources) > 1:
        unknown('duplicate-key')
    pins = entries(data, '[. | to_entries | .[] | select(.key == "source") | .value | to_entries | .[] | select(.key == "ref") | .value]')
    if len(pins) > 1:
        unknown('duplicate-key')
    pin = pins[0] if pins else None
    pattern = r'v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)'
    b = re.fullmatch(pattern, minimum) if isinstance(minimum, str) else None
    if not b:
        unknown('malformed-minimum')
    a = re.fullmatch(pattern, pin) if isinstance(pin, str) else None
    if not a:
        unknown('malformed-pin')
    # Compare decimal strings without integer size limits.
    def key(match):
        return tuple((len(part), part) for part in match.groups())
    verdict = 'ok' if key(a) >= key(b) else 'below-minimum'
    print(json.dumps({'verdict': verdict, 'pin': pin, 'minimum': minimum}, separators=(',', ':')))
    sys.exit(0 if verdict == 'ok' else 1)
except (OSError, subprocess.SubprocessError, ValueError, KeyError, TypeError):
    unknown('read-error')
PY
