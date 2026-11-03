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
if checks is None:
    row('devcontainer-verify', 'unknown: check runs unreadable')
    row('build', 'unknown: check runs unreadable')
else:
    found = [c for page in checks for c in page.get('check_runs', []) if c.get('name') == 'devcontainer-verify']
    found.sort(key=lambda c: c.get('id', 0), reverse=True)
    row('devcontainer-verify', 'unknown: check missing' if not found else
        ('success' if found[0].get('status') == 'completed' and found[0].get('conclusion') == 'success'
         else 'not successful: ' + str(found[0].get('conclusion') or found[0].get('status'))))
    runs = api(f'repos/{a.repo}/actions/workflows/devcontainer-build.yml/runs?head_sha={a.head}&per_page=100')
    if runs is None:
        row('build', 'unknown: workflow runs unreadable')
    else:
        suites = {r.get('check_suite_id') for page in runs for r in page.get('workflow_runs', [])
                  if r.get('head_sha') == a.head and r.get('check_suite_id') is not None}
        builds = [c for page in checks for c in page.get('check_runs', [])
                  if re.match(r'^build(?:\s*\(|$)', c.get('name', ''))
                  and (c.get('check_suite') or {}).get('id') in suites]
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
    if runs is None:
        row('image', 'unknown: workflow runs unreadable')
    else:
        found = [r for page in runs for r in page.get('workflow_runs', [])
                 if r.get('head_sha') == a.merged_head and r.get('head_branch') == a.base and r.get('event') == 'push']
        found.sort(key=lambda r: r.get('id', 0), reverse=True)
        if not found:
            row('image', 'unknown: merged-head push run missing')
        elif found[0].get('status') != 'completed' or found[0].get('conclusion') != 'success':
            row('image', 'not successful: workflow run did not succeed')
        else:
            jobs = api(f'repos/{a.repo}/actions/runs/{found[0]["id"]}/jobs?per_page=100')
            workflow = git_file(a.merged_head, '.github/workflows/devcontainer-build.yml')
            build = [] if jobs is None else [j for page in jobs for j in page.get('jobs', []) if re.match(r'^build(?:\s*\(|$)', j.get('name', ''))]
            # A successful push-event run alone does not prove a build or push.
            job = re.search(r'(?ms)^  build:\s*\n(.*?)(?=^  [A-Za-z0-9_-]+:\s*$|\Z)', workflow or '')
            steps_section = re.search(r'(?ms)^    steps:\s*\n(.*?)(?=^    [A-Za-z0-9_-]+:|\Z)', job.group(1) if job else '')
            steps = re.split(r'(?m)^      - ', steps_section.group(1))[1:] if steps_section else []
            matches = [(index, step) for index, step in enumerate(steps)
                       if re.search(r'(?m)^(?:uses:|        uses:)\s*devcontainers/ci@[^\s#]+', step)]
            step_number = matches[0][0] + 2 if len(matches) == 1 else None
            # GitHub numbers the implicit "Set up job" as step 1, before workflow steps.
            push_config = bool(len(matches) == 1 and re.search(r"(?m)^          push:\s*\$\{\{\s*github\.event_name\s*==\s*'push'\s*&&\s*'always'\s*\|\|\s*'never'\s*\}\}\s*$", matches[0][1]))
            if jobs is None or workflow is None:
                row('image', 'unknown: jobs or workflow definition unreadable')
            elif build and all(j.get('conclusion') == 'skipped' for j in build):
                row('image', 'not run: nothing to build')
            elif not build or not push_config or any(j.get('conclusion') != 'success' or len([s for s in j.get('steps', []) if s.get('number') == step_number and s.get('conclusion') == 'success']) != 1 for j in build):
                row('image', 'not proven: build or push evidence missing')
            else:
                row('image', 'build succeeded and pushed on merged head ' + a.merged_head)
probe = Path(a.checkout) / '.devcontainer/scripts/check-image-staleness.sh'
baked = Path('/usr/local/share/devcontainer-config')
config = Path(a.checkout) / '.devcontainer/config'
row('staleness probe', 'available' if probe.is_file() and os.access(probe, os.R_OK | os.X_OK) and baked.is_dir() and os.access(baked, os.R_OK | os.X_OK) and config.is_dir() and os.access(config, os.R_OK | os.X_OK) else 'unknown: probe or comparison directories unavailable')
print(json.dumps(rows, indent=2))
PY
