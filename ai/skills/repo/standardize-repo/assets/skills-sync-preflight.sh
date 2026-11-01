#!/usr/bin/env bash
# Usage: skills-sync-preflight.sh <owner/repo> <template-checkout> <verified-ref> <decisions-file> <release> [manifest]
# Read-only: JSON on the first line, tracking-issue Markdown row on the second.
set -u
asset_dir="$(cd "$(dirname "$0")" && pwd)"
python3 - "$asset_dir" "$@" <<'PY'
import json
import re
import subprocess
import sys

if len(sys.argv) not in (7, 8):
    sys.exit('usage: skills-sync-preflight.sh <owner/repo> <template-checkout> <verified-ref> <decisions-file> <release> [manifest]')
assets, repo, checkout, ref, decisions, release = sys.argv[1:7]
manifest = sys.argv[7] if len(sys.argv) == 8 else '.skills-sync.yaml'


def run(args, allowed=(0,)):
    try:
        result = subprocess.run(args, text=True, capture_output=True)
    except OSError as exc:
        sys.exit(f'preflight: {exc}')
    if result.returncode not in allowed:
        sys.stderr.write(result.stderr or f'preflight: command failed ({result.returncode})\n')
        sys.exit(1)
    return result


def parse_json(text):
    try:
        return json.loads(text)
    except ValueError:
        sys.exit('preflight: invalid JSON from helper or GitHub')


# Run the decision validator first so its exact missing-key diagnostic survives.
ruling_data = parse_json(run([assets + '/fleet-decisions.py', decisions, '--release', release,
                              '--repository', repo, '--require-key', 'skills_sync']).stdout)
ruling = json.loads(ruling_data['decisions'][0]['ruling'])['answer']
check = run([assets + '/check-pin-minimum.sh', checkout, ref, manifest], (0, 1, 2, 3))
pin_result = parse_json(check.stdout)
if check.returncode == 3:
    sys.exit('preflight: pin check error: ' + str(pin_result.get('reason', 'unspecified')))
# Read independently: unknown minimum verdicts omit the pin even when it exists.
try:
    pin_read = subprocess.run(['yq', '-o=json', '.source.ref', manifest],
                              text=True, capture_output=True)
    pin = json.loads(pin_read.stdout) if pin_read.returncode == 0 else None
except (OSError, ValueError):
    pin = None
prs = parse_json(run(['gh', 'pr', 'list', '--repo', repo, '--state', 'open', '--head', 'bot/sync-harmon-devkit', '--limit', '1000',
                      '--json', 'number,title,url,headRefName,headRepository']).stdout)
latest = parse_json(run(['gh', 'release', 'view', '--repo', 'evanharmon1/harmon-devkit',
                         '--json', 'tagName']).stdout).get('tagName')
pattern = r'v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)'
if not isinstance(latest, str) or not re.fullmatch(pattern, latest):
    sys.exit('preflight: latest skills release is not a stable version tag')
if not isinstance(prs, list):
    sys.exit('preflight: invalid PR list')
if len(prs) >= 1000:
    sys.exit('preflight: sync PR list may be truncated')
matching = []
for pr in prs:
    if not isinstance(pr, dict) or not isinstance(pr.get('headRepository'), dict):
        sys.exit('preflight: invalid PR record')
    title = pr.get('title')
    if (pr.get('headRefName') == 'bot/sync-harmon-devkit'
            and pr['headRepository'].get('nameWithOwner', '').lower() == repo.lower()
            and isinstance(title, str) and re.fullmatch('fix: sync harmon-devkit skills to ' + pattern, title)):
        if not isinstance(pr.get('number'), int) or not isinstance(pr.get('url'), str):
            sys.exit('preflight: invalid sync PR record')
        matching.append({'number': pr['number'], 'title': title, 'url': pr['url']})
minimum = pin_result.get('minimum')
verdict = pin_result.get('verdict')
if verdict not in ('ok', 'below-minimum', 'unknown'):
    sys.exit('preflight: invalid pin verdict')
def version(tag):
    m = re.fullmatch(pattern, tag) if isinstance(tag, str) else None
    return tuple(map(int, m.groups())) if m else None

pv, lv = version(pin), version(latest)
lag = 'unknown' if pv is None else ('behind ' + latest if pv < lv else ('current' if pv == lv else 'ahead of ' + latest))
action = {'sync_prs': ('wait-for-merge' if ruling == 'merge-first' else 'supersede') if matching else 'none',
          'pin': 'bump-to-minimum' if verdict == 'below-minimum' else ('leave' if verdict == 'ok' else 'unknown'),
          'target': minimum if verdict == 'below-minimum' else None}
result = {'repository': repo, 'open_sync_prs': matching, 'pin': pin, 'minimum': minimum,
          'latest': latest, 'verdict': verdict, 'pin_lag': lag, 'ruling': ruling, 'planned_action': action}
if verdict == 'unknown':
    result['reason'] = pin_result.get('reason', 'unspecified')
def cell(value):
    return str(value).replace('\\', '\\\\').replace('|', '\\|').replace('\n', ' ').replace('\r', ' ')
links = ', '.join('#' + str(pr['number']) for pr in matching) or 'none'
row = [repo, links, pin or 'unknown', minimum or 'unknown', latest, lag, verdict, ruling,
       action['sync_prs'] + '; ' + action['pin'] + ((' ' + minimum) if action['target'] else '')]
print(json.dumps(result, separators=(',', ':')))
print('| ' + ' | '.join(map(cell, row)) + ' |')
PY
