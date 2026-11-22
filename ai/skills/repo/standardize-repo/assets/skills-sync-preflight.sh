#!/usr/bin/env bash
# Usage: skills-sync-preflight.sh <owner/repo> <template-checkout> <verified-ref> <decisions-file> <release> [manifest]
# Usage: skills-sync-preflight.sh --lag-only [manifest] (run from target repo)
# Read-only: JSON on the first line, tracking-issue Markdown row on the second.
# --lag-only emits only the shared lag JSON; no decisions or template required.
set -u
asset_dir="$(cd "$(dirname "$0")" && pwd)"
python3 - "$asset_dir" "$@" <<'PY'
import json
import re
import subprocess
import sys

def read_lag(manifest):
    # Task owns the state machine and release lookup. --exit-code preserves its
    # semantic status codes instead of Task's generic command-failed code.
    result = {'pin': None, 'latest': 'unknown', 'pin_lag': 'unknown'}
    try:
        status = subprocess.run(['task', '--silent', '--exit-code', '--output', 'interleaved', 'skills:status', '--', manifest],
                                text=True, capture_output=True)
    except OSError:
        return result
    match = re.fullmatch(r'state=(\S+) pinned=(\S+) vendored=(\S+) latest=(\S+)\n?', status.stdout)
    if not match:
        return result
    state, pin, _, latest = match.groups()
    result.update(pin=pin, latest=latest)
    # A state without release evidence is not evidence of being current.
    stable = r'v(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)'
    if not re.fullmatch(stable, latest) or not re.fullmatch(stable, pin):
        return result
    if status.returncode == 12 and state == 'upstream-newer':
        result['pin_lag'] = 'behind ' + latest
    elif status.returncode == 0 and state == 'in-sync' and pin == latest:
        result['pin_lag'] = 'current'
    return result


if len(sys.argv) in (3, 4) and sys.argv[2] == '--lag-only':
    print(json.dumps(read_lag(sys.argv[3] if len(sys.argv) == 4 else '.skills-sync.yaml'), separators=(',', ':')))
    sys.exit(0)
if len(sys.argv) not in (7, 8):
    sys.exit('usage: skills-sync-preflight.sh <owner/repo> <template-checkout> <verified-ref> <decisions-file> <release> [manifest] OR --lag-only [manifest]')
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
pin = pin_result.get('pin')
prs = parse_json(run(['gh', 'pr', 'list', '--repo', repo, '--state', 'open', '--head', 'bot/sync-harmon-devkit', '--base', 'main', '--limit', '1000',
                      '--json', 'number,title,url,headRefName,isCrossRepository']).stdout)
if not isinstance(prs, list):
    sys.exit('preflight: invalid PR list')
if len(prs) >= 1000:
    sys.exit('preflight: sync PR list may be truncated')
matching = []
for pr in prs:
    if not isinstance(pr, dict) or not isinstance(pr.get('isCrossRepository'), bool):
        sys.exit('preflight: invalid PR record')
    title = pr.get('title')
    if (pr.get('headRefName') == 'bot/sync-harmon-devkit'
            and not pr['isCrossRepository']):
        if not isinstance(pr.get('number'), int) or not isinstance(pr.get('url'), str) or not isinstance(title, str):
            sys.exit('preflight: invalid sync PR record')
        matching.append({'number': pr['number'], 'title': title, 'url': pr['url']})
minimum = pin_result.get('minimum')
verdict = pin_result.get('verdict')
if verdict not in ('ok', 'below-minimum', 'unknown'):
    sys.exit('preflight: invalid pin verdict')
lag_result = read_lag(manifest)
latest = lag_result['latest']
lag = lag_result['pin_lag'] if pin is not None and lag_result['pin'] == pin else 'unknown'
action = {'sync_prs': ('wait-for-merge' if ruling == 'merge-first' else 'supersede') if matching else 'none',
          'pin': 'bump-to-minimum' if verdict == 'below-minimum' else ('leave' if verdict == 'ok' else 'unknown'),
          'target': minimum if verdict == 'below-minimum' else None}
result = {'repository': repo, 'open_sync_prs': matching, 'pin': pin, 'minimum': minimum,
          'latest': latest, 'verdict': verdict, 'pin_lag': lag, 'ruling': ruling, 'planned_action': action}
if 'pin_reason' in pin_result:
    result['pin_reason'] = pin_result['pin_reason']
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
