#!/usr/bin/env bash
# Marker-scan regressions, isolated from unrelated post-apply gates.
set -euo pipefail
assets="$(cd "$(dirname "$0")" && pwd)"
python3 -B - "$assets/verify-applied.sh" <<'PY_TEST'
from pathlib import Path
import subprocess
import json
import os
import shutil
import shlex
import sys
import tempfile
import unittest

source = Path(sys.argv.pop()).read_text()
scan = source.split('# ── 4. No unrendered template markers', 1)[1]
scan = scan.split('# ── 5. No secrets', 1)[0]
scan = '# ── 4. No unrendered template markers' + scan


class Markers(unittest.TestCase):
    def test_posix_mode_parse(self):
        # POSIX mode exercises the older command-substitution parsing rules.
        result = subprocess.run(['bash', '--posix', '-n'], input=source,
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def write(self, name, text):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def run_scan(self, expected, git=False):
        if git:
            subprocess.run(['git', 'init', '-q', str(self.root)], check=True)
        result = subprocess.run(['bash', '-c', 'set -euo pipefail\nfail=0\n'
                                 'err() { echo "FAIL: $*" >&2; fail=1; }\n'
                                 + scan + '\nexit "$fail"\n'],
                                cwd=self.root, text=True, capture_output=True)
        self.assertEqual(result.returncode, int(bool(expected)), result.stderr)
        for name in expected:
            self.assertIn('    ' + name + '\n', result.stderr)
        if not expected:
            self.assertEqual(result.stderr, '')
        return result

    def test_consumer_fixture_paths_and_generator_literals(self):
        self.write('scripts/test-agent-profile.sh', '''#!/bin/bash
profile="template/[% if devcontainer %].devcontainer[% endif %]/profile"
''')
        self.write('scripts/test-devcontainer-git-ownership.sh', '''#!/bin/bash
template_common="template/[% if devcontainer %].devcontainer[% endif %]/scripts/post-create-common.sh"
''')
        self.write('scripts/test-hooks.sh', '''#!/bin/bash
for hook in "template/.claude/hooks/[% if use_codex_review %]gate[% endif %]"; do :; done
''')
        self.write('scripts/test-label-registry.sh', '''#!/bin/bash
template_doc="template/docs/[% if project_management == 'github' %]project-management.md[% endif %].jinja"
''')
        self.write('scripts/test-sync-devkit-release.sh', '''#!/bin/bash
# Template names ([% if … %]…[% endif %]) are data here.
HELPER="$SCRIPT_DIR/[% if use_skills_sync %]sync-devkit-release.sh[% endif %]"
''')
        self.write('scripts/test-skills.sh', '''#!/bin/bash
mkdir -p "$AGG_TARGET/template/[% if include_terraform %]terraform[% endif %]"
cat <<'YAML'
  when: "{{ use_codex_review }}"
YAML
''')
        self.write('scripts/label-registry-render.mjs', '''
if (openGate !== null) lines.push('[% endif %]')
if (next !== null) lines.push(`[% if ${GATE_ANSWER[next]} %]`)
''')
        self.run_scan([], git=True)
        # The same rules apply before git init.
        import shutil
        shutil.rmtree(self.root / '.git')
        self.run_scan([])

    def test_real_leaks_in_rendered_files_even_inside_quotes(self):
        for name, text in {
            'README.md': 'Name: [[ project_name ]]\n',
            'config.yml': 'name: "{{ project_name }}"\n',
            '.github/workflows/build.yml': '[% if use_codeql %]\n',
            'scripts/install.sh': 'echo "[[ project_name ]]"\n',
            'scripts/render.mjs': 'const name = "[[ project_name ]]"\n',
            'scripts/render-nested-answer.mjs': '''const block = "[% if name == '[[ project_name ]]' %]";\n''',
            'scripts/render-nested-legacy-answer.mjs': '''const block = "[% if name == '{{ project_name }}' %]";\n''',
            'scripts/render-apostrophe.mjs': "const label = 'can\\'t'; [% if use_codeql %] run('ok');\n",
            'scripts/render-comment-quote.mjs': "/* don't enable by default */ [% if use_codeql %] run('ok');\n",
            'scripts/render-regex-quote.mjs': "const regex = /'/; [% if use_codeql %] run('ok');\n",
            'scripts/test-unclosed.sh': 'echo "[% if use_codeql %]\n',
            'scripts/test-executable.sh': '[% if use_codex_review %]\n',
            'scripts/test-command.sh': 'echo `[[ project_name ]]`\n',
            'scripts/test-substitution.sh': 'echo "$([% if use_codeql %])"\n',
            'scripts/test-quoted-command.sh': 'echo "`[% if use_codeql %]`"\n',
            'scripts/test-nested-command.sh': 'echo "$(echo "x"; [% if use_codeql %])"\n',
            'scripts/render-comment-string.mjs': 'const value = `\n// [[ project_name ]]\n`;\n',
            'scripts/render-expression.mjs': 'const value = `${[% if use_codeql %]}`\n',
            'scripts/render-later-expression.mjs': 'const value = `[% if ${[% if use_codeql %]} %]`\n',
        }.items():
            with self.subTest(name=name):
                self.write(name, text)
                self.run_scan([name], git=True)
                (self.root / name).unlink()

    def test_quoted_fixture_does_not_hide_a_leak_on_the_same_line(self):
        name = 'scripts/test-mixed.sh'
        self.write(name, 'path="template/[% if use_codeql %]x[% endif %]"; [[ project_name ]]\n')
        self.run_scan([name])

    def test_ansi_c_quotes_do_not_hide_a_leak(self):
        name = 'scripts/test-ansi.sh'
        for text in [
            r"printf '%s\n' $'can\'t'; [% if use_codeql %] echo 'ok'",
            r"printf '%s\n' $'backslash\\'; [% if use_codeql %] echo 'ok'",
        ]:
            with self.subTest(text=text):
                self.write(name, text + '\n')
                self.run_scan([name])
        self.write(name, r"printf '%s\n' $'can\'t [% if use_codeql %]'" + '\n')
        self.run_scan([])

    def test_preserves_ignores_and_handles_spaces(self):
        self.write('.gitignore', 'cache/\n')
        self.write('cache/leak.txt', '[[ project_name ]]\n')
        self.write('assets/sample.jinja', '[[ project_name ]]\n')
        self.write('assets/sample.j2', '{{ project_name }}\n')
        self.write('ai/skills/example/reference.md', '[[ project_name ]]\n')
        self.write('normal.sh', '[[ true ]]\n[[ -n "$value" ]]\n')
        self.run_scan([], git=True)
        self.write('file with spaces.yml', '[%- if use_codeql %]\n')
        self.run_scan(['file with spaces.yml'])
        # A tracked ignored file must still be scanned.
        subprocess.run(['git', 'add', '-f', 'cache/leak.txt'], cwd=self.root, check=True)
        self.run_scan(['cache/leak.txt', 'file with spaces.yml'])

    def test_non_git_dependency_exclusions(self):
        for directory in ['node_modules', '.venv', '.terraform', '.task', '.worktrees', 'dist']:
            self.write(directory + '/example.txt', '[[ project_name ]]\n')
        self.run_scan([])

    def test_binary_and_symlink_are_not_followed(self):
        (self.root / 'binary').write_bytes(b'\0[[ project_name ]]')
        (self.root / 'outside').symlink_to('/nonexistent')
        self.run_scan([])

    def test_live_symlink_target_is_not_followed(self):
        with tempfile.TemporaryDirectory() as outside:
            target = Path(outside) / 'leak.txt'
            target.write_text('[[ project_name ]]\n')
            (self.root / 'linked.txt').symlink_to(target)
            self.run_scan([])
            self.run_scan([], git=True)


renovate_scan = source.split('# ── 5a. Renovate config', 1)[1]
renovate_scan = renovate_scan.split('# ── 6. Template-owned', 1)[0]
renovate_scan = '# ── 5a. Renovate config' + renovate_scan


class Renovate(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.expected = {'customManagers': [{'managerFilePatterns': ['x']}],
                         'schedule': ['before 4am'], 'enabled': True}
        (self.root / 'expected.json').write_text(json.dumps(self.expected))
        (self.root / 'renovate.json').write_text(json.dumps(self.expected))
        (self.root / '.copier-answers.yml').write_text(
            '_commit: v1.2.3\nproject_name: demo\nskill_categories: [repo, universal]\n')
        self.stub('copier', '''#!/usr/bin/env python3
import json, pathlib, sys
args = sys.argv[1:]
assert args[0] == 'copy'
assert '--vcs-ref=v1.2.3' in args
assert '--skip-tasks' in args
assert 'skill_categories' in pathlib.Path(args[args.index('--data-file')+1]).read_text()
pathlib.Path('copier-args.json').write_text(json.dumps(args))
pathlib.Path(args[2]).mkdir()
pathlib.Path(args[2], 'renovate.json').write_text(pathlib.Path('expected.json').read_text())
''')
        self.stub('renovate-config-validator', '''#!/bin/sh
[ "$*" = "--strict renovate.json" ] || exit 9
echo called >validator-called
''')

    def stub(self, name, text):
        path = self.bin / name
        path.write_text(text)
        path.chmod(0o755)

    def run_audit(self, success, validator_expected=True):
        env = dict(os.environ, PATH=str(self.bin)+os.pathsep+os.environ['PATH'])
        result = subprocess.run(['bash', '-c', 'set -euo pipefail\nfail=0\n'
                                 'have() { command -v "$1" >/dev/null 2>&1; }\n'
                                 'err() { echo "FAIL: $*" >&2; fail=1; }\n'
                                 + renovate_scan + '\nexit "$fail"'],
                                cwd=self.root, env=env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0 if success else 1, result.stderr)
        self.assertEqual((self.root / 'validator-called').exists(), validator_expected,
                         result.stderr)
        return result

    def test_clean_and_reordered_keys(self):
        (self.root / 'renovate.json').write_text(json.dumps(
            dict(reversed(list(self.expected.items()))), indent=4))
        self.run_audit(True)

    def test_stale_file_match_and_each_differing_key(self):
        stale = dict(self.expected, customManagers=[{'fileMatch': ['x']}],
                     schedule=['at any time'])
        (self.root / 'renovate.json').write_text(json.dumps(stale))
        result = self.run_audit(False)
        for key in ['renovate.json', 'fileMatch', 'managerFilePatterns', 'schedule']:
            self.assertIn(key, result.stderr)

    def test_missing_null_and_empty_values_are_drift(self):
        for value in [None, {}, []]:
            with self.subTest(value=value):
                (self.root / 'renovate.json').write_text(json.dumps(
                    dict(self.expected, extra=value)))
                self.assertIn('extra', self.run_audit(False).stderr)

    def test_container_type_and_array_order_are_significant(self):
        (self.root / 'renovate.json').write_text(json.dumps(
            dict(self.expected, customManagers='invalid')))
        self.assertIn('customManagers', self.run_audit(False).stderr)
        self.expected['schedule'] = ['a', 'b']
        (self.root / 'expected.json').write_text(json.dumps(self.expected))
        (self.root / 'renovate.json').write_text(json.dumps(
            dict(self.expected, schedule=['b', 'a'])))
        self.assertIn('schedule', self.run_audit(False).stderr)

    def test_strict_migration_fails_even_when_template_matches(self):
        self.stub('renovate-config-validator', '#!/bin/sh\necho called >validator-called\n'
                  'echo "Config migration necessary" >&2\nexit 1\n')
        result = self.run_audit(False)
        self.assertIn('migration-needed drift', result.stderr)
        self.assertIn('Config migration necessary', result.stderr)

    def test_missing_commit_is_not_replaced_by_head(self):
        (self.root / '.copier-answers.yml').write_text('project_name: demo\n')
        self.assertIn('has no _commit', self.run_audit(False).stderr)
        self.assertFalse((self.root / 'copier-args.json').exists())

    def test_present_config_requires_answers_file(self):
        (self.root / '.copier-answers.yml').unlink()
        self.assertIn('_commit is required', self.run_audit(False).stderr)
        self.assertFalse((self.root / 'copier-args.json').exists())

    def test_minimal_non_renovate_fixture_needs_no_baseline(self):
        (self.root / 'renovate.json').unlink()
        (self.root / '.copier-answers.yml').write_text('use_codeql: false\n')
        self.run_audit(True, validator_expected=False)
        self.assertFalse((self.root / 'copier-args.json').exists())

    def test_recorded_baseline_detects_missing_config(self):
        (self.root / 'renovate.json').unlink()
        self.assertIn('invalid JSON', self.run_audit(False, validator_expected=False).stderr)

    def test_npx_fallback_passes_strict_and_file(self):
        (self.bin / 'renovate-config-validator').unlink()
        self.stub('npx', '#!/bin/sh\n'
                  '[ "$*" = "--yes --package renovate -- renovate-config-validator --strict renovate.json" ] || exit 9\n'
                  'echo called >validator-called\n')
        self.run_audit(True)

    def test_real_copier_renders_recorded_version_without_tasks(self):
        copier = shutil.which('copier')
        self.assertIsNotNone(copier, 'Copier is required for this render fixture')
        template = self.root / 'template-source'
        template.mkdir()
        marker = self.root / 'template-task-ran'
        (template / 'copier.yml').write_text(json.dumps({
            'project_name': {'type': 'str'},
            'skill_categories': {'type': 'json'},
            '_tasks': ['touch ' + shlex.quote(str(marker))]}))
        (template / 'renovate.json').write_text(json.dumps(self.expected))
        def git(*args):
            subprocess.run(['git', '-C', str(template), '-c', 'user.name=Fixture',
                            '-c', 'user.email=fixture@example.test', *args],
                           check=True, capture_output=True)
        git('init', '-q')
        git('add', '.')
        git('commit', '-qm', 'baseline')
        git('tag', 'v1.2.3')
        (template / 'renovate.json').write_text('{}')
        git('commit', '-qam', 'newer template')
        self.stub('copier', '#!/bin/sh\nexec ' + shlex.quote(copier) + ' "$@"\n')
        env_template = os.environ.get('HARMON_INIT')
        os.environ['HARMON_INIT'] = str(template)
        self.addCleanup(lambda: os.environ.pop('HARMON_INIT', None) if env_template is None
                        else os.environ.__setitem__('HARMON_INIT', env_template))
        self.run_audit(True)
        self.assertFalse(marker.exists(), 'audit must not execute template tasks')

    def test_prepared_template_is_used(self):
        env_template = os.environ.get('HARMON_INIT')
        os.environ['HARMON_INIT'] = str(self.root / 'prepared-template')
        self.addCleanup(lambda: os.environ.pop('HARMON_INIT', None) if env_template is None
                        else os.environ.__setitem__('HARMON_INIT', env_template))
        self.run_audit(True)
        args = json.loads((self.root / 'copier-args.json').read_text())
        self.assertEqual(args[1], str(self.root / 'prepared-template'))

    def test_render_failure_still_runs_strict_validation(self):
        self.stub('copier', '#!/bin/sh\nexit 1\n')
        self.assertIn('template render failed', self.run_audit(False).stderr)

    def test_malformed_json_and_missing_render_fail(self):
        (self.root / 'renovate.json').write_text('{')
        self.assertIn('invalid JSON', self.run_audit(False).stderr)
        (self.root / 'renovate.json').write_text(json.dumps(self.expected))
        self.stub('copier', '#!/bin/sh\nmkdir "$3"\n')
        self.assertIn('lacks a valid config', self.run_audit(False).stderr)


unittest.main()
PY_TEST
