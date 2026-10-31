#!/usr/bin/env bash
# Usage: check-pin-minimum.sh <template-checkout> <verified-ref> [skills-manifest]
# stdout: one JSON verdict; exit 0=ok, 1=below-minimum, 2=unknown.
set -u
python3 - "$@" <<'PY'
import json
import re
import subprocess
import sys


def unknown():
    print(json.dumps({"verdict": "unknown"}, separators=(',', ':')))
    sys.exit(2)


def yaml_json(data):
    result = subprocess.run(['yq', '-o=json', '.', '-'], input=data,
                            text=True, capture_output=True, check=True)
    return json.loads(result.stdout)


try:
    if len(sys.argv) not in (3, 4):
        unknown()
    checkout, ref = sys.argv[1:3]
    manifest = sys.argv[3] if len(sys.argv) == 4 else '.skills-sync.yaml'
    template = subprocess.run(['git', '-C', checkout, 'show', ref + ':copier.yml'],
                              text=True, capture_output=True, check=True)
    minimum = yaml_json(template.stdout)['_min_harmon_devkit_skills']
    with open(manifest, encoding='utf-8') as f:
        pin = yaml_json(f.read())['source']['ref']
    pattern = r'v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)'
    if not isinstance(minimum, str) or not isinstance(pin, str):
        unknown()
    a, b = re.fullmatch(pattern, pin), re.fullmatch(pattern, minimum)
    if not a or not b:
        unknown()
    # Compare decimal strings without integer size limits.
    def key(match):
        return tuple((len(part), part) for part in match.groups())
    verdict = 'ok' if key(a) >= key(b) else 'below-minimum'
    print(json.dumps({'verdict': verdict, 'pin': pin, 'minimum': minimum}, separators=(',', ':')))
    sys.exit(0 if verdict == 'ok' else 1)
except (OSError, subprocess.SubprocessError, ValueError, KeyError, TypeError):
    unknown()
PY
