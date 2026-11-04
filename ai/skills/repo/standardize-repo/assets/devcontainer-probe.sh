#!/usr/bin/env bash
# Read-only devcontainer evidence, emitted as fleet-report devcontainer rows.
set -euo pipefail
exec python3 -B - "$@" <<'PY'
import argparse
import json
import os
import re
import subprocess
from pathlib import Path
from urllib.parse import quote

p = argparse.ArgumentParser()
p.add_argument('--repo', required=True)
p.add_argument('--checkout', required=True)
p.add_argument('--head', required=True)
p.add_argument('--base', required=True, help='default branch name')
p.add_argument('--merged-head')
p.add_argument('--gh', default='gh')
a = p.parse_args()
branch = quote(a.base, safe='')
if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', a.repo):
    p.error('repo must be owner/name')
for value in (a.head, a.merged_head):
    if value is not None and not re.fullmatch(r'[0-9a-f]{40}', value):
        p.error('heads must be full lowercase commit SHAs')

def api(path):
    try:
        result = subprocess.run([a.gh, 'api', '--paginate', '--slurp', path], capture_output=True, text=True, check=True)
        return json.loads(result.stdout)
    except (OSError, subprocess.CalledProcessError, ValueError):
        return None

def git_file(head, path):
    try:
        return subprocess.run(['git', '-C', a.checkout, 'show', head + ':' + path], capture_output=True, text=True, check=True).stdout
    except (OSError, subprocess.CalledProcessError):
        return None

rows = []
def row(item, result):
    rows.append({'item': item, 'probe': result, 'action': 'none', 'class': 'observation'})

definition = git_file(a.head, '.devcontainer/devcontainer.json')
row('definition', 'unknown: definition unreadable' if definition is None else
    ('not rendered: template markers remain' if re.search(r'\[%|%\]|\[\[|\]\]|\{\{|\}\}', definition) else 'rendered'))
checks = api(f'repos/{a.repo}/commits/{a.head}/check-runs?per_page=100')
runs = api(f'repos/{a.repo}/actions/workflows/devcontainer-build.yml/runs?head_sha={a.head}&per_page=100')
if checks is None:
    row('devcontainer-verify', 'unknown: check runs unreadable')
    row('build', 'unknown: check runs unreadable')
elif runs is None:
    row('devcontainer-verify', 'unknown: workflow runs unreadable')
    row('build', 'unknown: workflow runs unreadable')
else:
    matching = [r for page in runs for r in page.get('workflow_runs', []) if r.get('head_sha') == a.head]
    matching.sort(key=lambda r: r.get('id', 0), reverse=True)
    suite = matching[0].get('check_suite_id') if matching else None
    scoped = [c for page in checks for c in page.get('check_runs', [])
              if suite is not None and (c.get('check_suite') or {}).get('id') == suite]
    found = [c for c in scoped if c.get('name') == 'devcontainer-verify']
    found.sort(key=lambda c: c.get('id', 0), reverse=True)
    row('devcontainer-verify', 'unknown: check missing' if not found else
        ('success' if found[0].get('status') == 'completed' and found[0].get('conclusion') == 'success'
         else 'not successful: ' + str(found[0].get('conclusion') or found[0].get('status'))))
    builds = [c for c in scoped if re.match(r'^build(?:\s*\(|$)', c.get('name', ''))]
    if not builds:
        row('build', 'unknown: build checks missing')
    elif all(c.get('status') == 'completed' and c.get('conclusion') == 'skipped' for c in builds):
        row('build', 'not run: build checks skipped')
    elif all(c.get('status') == 'completed' and c.get('conclusion') in ('success', 'skipped') for c in builds):
        row('build', 'success')
    else:
        row('build', 'not successful: build checks incomplete or failed')
rules = api(f'repos/{a.repo}/rules/branches/{branch}?per_page=100')
if rules is None:
    row('required check', 'unknown: rules unreadable')
else:
    contexts = [c.get('context') for page in rules for rule in page
                if rule.get('type') == 'required_status_checks'
                for c in rule.get('parameters', {}).get('required_status_checks', [])]
    row('required check', 'unknown: ruleset missing' if not any(page for page in rules) else
        ('required' if 'devcontainer-verify' in contexts else 'not required'))
if not a.merged_head:
    row('image', 'not run: awaiting merged head')
else:
    runs = api(f'repos/{a.repo}/actions/workflows/devcontainer-build.yml/runs?branch={branch}&event=push&head_sha={a.merged_head}&per_page=100')
    found = [] if runs is None else [r for page in runs for r in page.get('workflow_runs', [])
                                    if r.get('head_sha') == a.merged_head]
    found.sort(key=lambda r: r.get('id', 0), reverse=True)
    conclusion = found[0].get('conclusion') if found and found[0].get('status') == 'completed' else None
    result = conclusion if conclusion in ('success', 'failure', 'cancelled', 'skipped', 'timed_out',
                                'action_required', 'neutral', 'stale', 'startup_failure') else 'unknown'
    row('image', 'workflow-run conclusion: ' + result + '; push: unknown: push not observable without the packages scope')
probe = Path(a.checkout) / '.devcontainer/scripts/check-image-staleness.sh'
baked = Path('/usr/local/share/devcontainer-config')
config = Path(a.checkout) / '.devcontainer/config'
row('staleness probe', 'available' if probe.is_file() and os.access(probe, os.R_OK | os.X_OK) and baked.is_dir() and os.access(baked, os.R_OK | os.X_OK) and config.is_dir() and os.access(config, os.R_OK | os.X_OK) else 'unknown: probe or comparison directories unavailable')
print(json.dumps(rows, indent=2))
PY
