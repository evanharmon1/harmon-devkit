#!/usr/bin/env bash
set -euo pipefail
asset_dir="$(cd "$(dirname "$0")" && pwd)"
python3 -B - "$asset_dir/devcontainer-probe.sh" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

PROBE = sys.argv.pop()
HEAD = 'a' * 40

class ProbeTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        git = self.root / 'git'
        git.write_text(r'''#!/bin/sh
case "$4" in
  *devcontainer.json) echo '{"name":"test"}' ;;
  *devcontainer-build.yml) cat <<'WORKFLOW'
  build:
    steps:
      - name: Build dev devcontainer
        uses: devcontainers/ci@abc
        with:
          push: ${{ github.event_name == 'push' && 'always' || 'never' }}
WORKFLOW
    ;;
  *) exit 1 ;;
esac
''')
        git.chmod(0o755)
        gh = self.root / 'gh'
        gh.write_text('''#!/usr/bin/env python3
import json, os, sys
path = sys.argv[-1]
mode = os.environ.get('MODE', '')
if '/rules/' in path and mode == 'unreadable': sys.exit(1)
if '/check-runs?' in path:
    data = {'check_runs': [{'id': 1, 'name': 'devcontainer-verify', 'status': 'completed', 'conclusion': 'failure' if mode == 'fail' else 'success'}, {'id': 2, 'name': 'build (dev)', 'status': 'completed', 'conclusion': 'success'}]}
elif '/rules/' in path:
    data = [{'type': 'required_status_checks', 'parameters': {'required_status_checks': [{'context': 'devcontainer-verify'}]}}]
elif '/workflows/' in path:
    data = {'workflow_runs': [{'id': 1, 'head_sha': 'a'*40, 'head_branch': 'main', 'event': 'push', 'status': 'completed', 'conclusion': 'success'}]}
elif '/jobs?' in path:
    data = {'jobs': [{'name': 'build (dev)', 'conclusion': 'success', 'steps': [{'name': 'Build dev devcontainer', 'conclusion': 'skipped' if mode == 'no-push' else 'success'}]}]}
else: sys.exit(1)
print(json.dumps([data]))
''')
        gh.chmod(0o755)

    def rows(self, mode=''):
        env = dict(os.environ, PATH=str(self.root) + os.pathsep + os.environ['PATH'], MODE=mode)
        result = subprocess.run([PROBE, '--repo', 'example/app', '--checkout', str(self.root), '--head', HEAD,
                                 '--base', 'main', '--merged-head', HEAD, '--gh', str(self.root / 'gh')],
                                env=env, text=True, capture_output=True, check=True)
        return {row['item']: row['probe'] for row in json.loads(result.stdout)}

    def test_success(self):
        rows = self.rows()
        self.assertEqual(rows['definition'], 'rendered')
        self.assertEqual(rows['devcontainer-verify'], 'success')
        self.assertEqual(rows['build'], 'success')
        self.assertEqual(rows['required check'], 'required')
        self.assertIn('succeeded and pushed', rows['image'])

    def test_failure_and_unknown(self):
        self.assertIn('not successful', self.rows('fail')['devcontainer-verify'])
        self.assertIn('unknown', self.rows('unreadable')['required check'])
        self.assertIn('not proven', self.rows('no-push')['image'])

unittest.main()
PY
