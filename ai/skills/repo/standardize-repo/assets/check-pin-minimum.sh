#!/usr/bin/env bash
# Usage: check-pin-minimum.sh <template-checkout> <verified-ref> [skills-manifest]
# stdout: one JSON verdict; exit 0=ok, 1=below-minimum, 2=unknown, 3=error (including unavailable yq).
set -u
python3 - "$@" <<'PY'
import json
import re
import subprocess
import sys


pin_info = {'pin_reason': 'read-error'}

def unknown(reason):
    print(json.dumps({'verdict': 'unknown', 'reason': reason, **pin_info}, separators=(',', ':')))
    sys.exit(2)


def yq_unavailable():
    print('yq v4 is unavailable or failed', file=sys.stderr)
    print(json.dumps({'verdict': 'error', 'reason': 'yq-unavailable', **pin_info}, separators=(',', ':')))
    sys.exit(3)


class ReadError(Exception):
    pass

def read(data, expression):
    try:
        result = subprocess.run(['yq', '-o=json', expression, '-'], input=data,
                                text=True, capture_output=True)
    except OSError:
        raise ReadError
    if result.returncode:
        raise ReadError
    try:
        return json.loads(result.stdout)
    except ValueError:
        raise ReadError


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
pattern = r'v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)'
try:
    with open(manifest, encoding='utf-8') as f:
        data = f.read()
    sources = read(data, '[. | to_entries | .[] | select(.key == "source") | .value]')
    pins = read(data, '[. | to_entries | .[] | select(.key == "source") | .value | to_entries | .[] | select(.key == "ref") | .value]')
    if len(sources) > 1 or len(pins) > 1:
        pin_info = {'pin_reason': 'duplicate-key'}
    else:
        pin = read(data, '.source.ref')
        if isinstance(pin, str) and re.fullmatch(pattern, pin):
            pin_info = {'pin': pin}
        else:
            pin_info = {'pin_reason': 'malformed-pin'}
except FileNotFoundError:
    pin_info = {'pin_reason': 'no-skills-manifest'}
except (OSError, UnicodeError, ReadError, ValueError, TypeError):
    pin_info = {'pin_reason': 'read-error'}

try:
    template = subprocess.run(['git', '-C', checkout, 'show', ref + ':copier.yml'],
                              text=True, capture_output=True, check=True)
    minimums = read(template.stdout, '[. | to_entries | .[] | select(.key == "_min_harmon_devkit_skills") | .value]')
    if len(minimums) > 1:
        unknown('duplicate-key')
    minimum = read(template.stdout, '._min_harmon_devkit_skills')
    if minimum is None:
        unknown('no-declared-minimum')
    if pin_info.get('pin_reason') not in (None, 'malformed-pin'):
        unknown(pin_info['pin_reason'])
    pin = pin_info.get('pin')
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
except (OSError, subprocess.SubprocessError, ValueError, KeyError, TypeError, ReadError):
    unknown('read-error')
PY
