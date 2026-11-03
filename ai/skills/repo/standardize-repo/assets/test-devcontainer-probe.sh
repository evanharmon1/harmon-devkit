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
  *devcontainer-build.yml)
    echo '  build:'
    echo '    steps:'
    if [ "$MODE" = reordered ]; then echo '      - run: echo first'; fi
    cat <<'WORKFLOW'
      - name: Build ${{ matrix.name }} devcontainer
        uses: devcontainers/ci@abc
        with:
          push: ${{ github.event_name == 'push' && 'always' || 'never' }}
WORKFLOW
    if [ "$MODE" = ambiguous ]; then echo '      - uses: devcontainers/ci@other'; fi
    if [ "$MODE" = decoy ]; then echo '      - name: Build ${{ matrix.name }} devcontainer'; echo '        run: echo decoy'; fi
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
    data = {'check_runs': [] if mode == 'missing' else [{'id': 1, 'name': 'devcontainer-verify', 'status': 'completed', 'conclusion': 'failure' if mode == 'fail' else 'success'}, {'id': 2, 'name': 'build (dev)', 'check_suite': {'id': 99 if mode == 'other-workflow' else 10}, 'status': 'completed', 'conclusion': 'skipped' if mode == 'skipped' else 'success'}]}
elif '/rules/' in path:
    data = [] if mode == 'missing' else [{'type': 'required_status_checks', 'parameters': {'required_status_checks': [{'context': 'devcontainer-verify'}]}}]
elif '/workflows/' in path:
    data = {'workflow_runs': [{'id': 1, 'check_suite_id': 10, 'head_sha': 'a'*40, 'head_branch': 'main', 'event': 'push', 'status': 'completed', 'conclusion': 'success'}]}
elif '/jobs?' in path:
    data = {'jobs': [{'name': 'build (dev)', 'conclusion': 'skipped' if mode == 'skipped' else 'success', 'steps': ([{'number': 2, 'name': 'Other', 'conclusion': 'success'}] if mode == 'reordered' else []) + [{'number': 3 if mode == 'reordered' else 2, 'name': 'Build dev devcontainer', 'conclusion': 'skipped' if mode in ('no-push', 'decoy') else 'success'}] + ([{'number': 3, 'name': 'Build dev devcontainer', 'conclusion': 'success'}] if mode == 'decoy' else [])}]}
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

    def test_step_identity(self):
        self.assertIn('succeeded and pushed', self.rows('reordered')['image'])
        self.assertIn('not proven', self.rows('decoy')['image'])
        self.assertIn('not proven', self.rows('ambiguous')['image'])

    def test_missing_and_unrelated_evidence(self):
        self.assertIn('unknown', self.rows('other-workflow')['build'])
        rows = self.rows('missing')
        self.assertIn('unknown', rows['devcontainer-verify'])
        self.assertIn('unknown', rows['build'])
        self.assertIn('unknown', rows['required check'])

    def test_markers_and_skipped_build(self):
        self.assertIn('not rendered', self.rows('markers')['definition'])
        rows = self.rows('skipped')
        self.assertIn('not run', rows['build'])
        self.assertIn('not run', rows['image'])

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
        self.assertIn('not proven', self.rows('no-push')['image'])

unittest.main()
PY
