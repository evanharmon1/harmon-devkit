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
  *devcontainer.json) if [ "$MODE" = markers ]; then echo '{"name":"[[ project_slug ]]"}'; else echo '{"name":"test"}'; fi ;;
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
    data = {'check_runs': [] if mode == 'missing' else [{'id': 1, 'name': 'devcontainer-verify', 'check_suite': {'id': 10}, 'status': 'completed', 'conclusion': 'failure' if mode == 'fail' else 'success'}, {'id': 2, 'name': 'build (dev)', 'check_suite': {'id': 99 if mode == 'other-workflow' else 10}, 'status': 'completed', 'conclusion': 'skipped' if mode == 'skipped' else 'success'}]}
    if mode in ('new-success', 'new-failure'):
        old, new = ('failure', 'success') if mode == 'new-success' else ('success', 'failure')
        data['check_runs'] = [{'id': check_id, 'name': name, 'check_suite': {'id': suite}, 'status': 'completed', 'conclusion': conclusion}
                              for check_id, name, suite, conclusion in [(100, 'devcontainer-verify', 10, old), (101, 'build (dev)', 10, old), (3, 'devcontainer-verify', 20, new), (4, 'build (dev)', 20, new)]]
elif '/rules/' in path:
    data = [] if mode == 'missing' else [{'type': 'required_status_checks', 'parameters': {'required_status_checks': [{'context': 'devcontainer-verify'}]}}]
elif '/workflows/' in path:
    data = {'workflow_runs': [] if mode == 'missing-run' else [{'id': 1, 'check_suite_id': 10, 'head_sha': 'a'*40, 'head_branch': 'main', 'event': 'push', 'status': 'completed', 'conclusion': mode[4:] if mode in ('run-failure', 'run-cancelled', 'run-timed_out') else 'skipped' if mode == 'skipped' else 'success'}]}
    if mode in ('new-success', 'new-failure'):
        data['workflow_runs'].append({'id': 2, 'check_suite_id': 20, 'head_sha': 'a'*40, 'status': 'completed', 'conclusion': 'success' if mode == 'new-success' else 'failure'})
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
        self.assertEqual(rows['image'], 'workflow-run conclusion: success; push: unknown: push not observable without the packages scope')

    def test_image_conclusions(self):
        for mode, conclusion in [('run-failure', 'failure'), ('run-cancelled', 'cancelled'), ('run-timed_out', 'timed_out'), ('skipped', 'skipped'), ('missing-run', 'unknown')]:
            with self.subTest(mode=mode):
                image = self.rows(mode)['image']
                self.assertEqual(image, 'workflow-run conclusion: ' + conclusion + '; push: unknown: push not observable without the packages scope')
                self.assertNotIn('pushed', image)
        self.assertNotIn('pushed', self.rows()['image'])

    def test_missing_and_unrelated_evidence(self):
        self.assertIn('unknown', self.rows('other-workflow')['build'])
        rows = self.rows('missing')
        self.assertIn('unknown', rows['devcontainer-verify'])
        self.assertIn('unknown', rows['build'])
        self.assertIn('unknown', rows['required check'])
        rows = self.rows('missing-run')
        self.assertIn('unknown', rows['devcontainer-verify'])
        self.assertIn('unknown', rows['build'])

    def test_newest_workflow_run_scopes_both_checks(self):
        rows = self.rows('new-success')
        self.assertEqual(rows['devcontainer-verify'], 'success')
        self.assertEqual(rows['build'], 'success')
        rows = self.rows('new-failure')
        self.assertIn('not successful', rows['devcontainer-verify'])
        self.assertIn('not successful', rows['build'])

    def test_markers_and_skipped_build(self):
        self.assertIn('not rendered', self.rows('markers')['definition'])
        rows = self.rows('skipped')
        self.assertIn('not run', rows['build'])
        self.assertIn('skipped', rows['image'])

    def test_unreadable_probe_is_unavailable(self):
        probe = self.root / '.devcontainer/scripts/check-image-staleness.sh'
        probe.parent.mkdir(parents=True)
        probe.write_text('#!/bin/sh\n')
        probe.chmod(0)
        (self.root / '.devcontainer/config').mkdir()
        self.assertIn('unknown', self.rows()['staleness probe'])

    def test_untraversable_checkout_config_is_unavailable(self):
        probe = self.root / '.devcontainer/scripts/check-image-staleness.sh'
        probe.parent.mkdir(parents=True)
        probe.write_text('#!/bin/sh\n')
        probe.chmod(0o755)
        config = self.root / '.devcontainer/config'
        config.mkdir()
        config.chmod(0o600)
        self.addCleanup(config.chmod, 0o700)
        if os.access(config, os.X_OK):
            self.skipTest('current user bypasses directory permissions')
        self.assertIn('unknown', self.rows()['staleness probe'])

    def test_failure_and_unknown(self):
        self.assertIn('not successful', self.rows('fail')['devcontainer-verify'])
        self.assertIn('unknown', self.rows('unreadable')['required check'])

unittest.main()
PY
