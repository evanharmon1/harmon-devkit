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
        self.real_git = shutil.which('git')
        self.template = self.root / 'prepared-template'
        self.template.mkdir()
        (self.template / 'copier.yml').write_text('project_name: demo\n')
        (self.template / 'renovate.json').write_text('{}')
        self.git('init', '-q', '-b', 'main')
        self.git('add', '.')
        self.git('commit', '-qm', 'baseline')
        self.commit = self.git('rev-parse', 'HEAD').strip()
        self.git('tag', 'v1.2.3')
        self.git('tag', 'v3.0.0')
        (self.root / 'expected-ref').write_text(self.commit)
        self.env = {key: value for key, value in os.environ.items()
                    if key not in ('HARMON_INIT', 'HARMON_INIT_RECORDED_COMMIT',
                                   'ACCEPT_LEGACY_BASELINE')}
        self.env['HARMON_INIT'] = str(self.template)
        self.expected = {'customManagers': [{'managerFilePatterns': ['x']}],
                         'schedule': ['before 4am'], 'enabled': True}
        (self.root / 'expected.json').write_text(json.dumps(self.expected))
        (self.root / 'renovate.json').write_text(json.dumps(self.expected))
        (self.root / '.copier-answers.yml').write_text(
            '_commit: v1.2.3\nproject_name: demo\nskill_categories: [repo, universal]\n')
        self.stub('copier', '''#!/usr/bin/env python3
import json, os, pathlib, subprocess, sys
args = sys.argv[1:]
assert args[0] == 'copy'
assert '--vcs-ref=' + pathlib.Path('expected-ref').read_text() in args
assert '--skip-tasks' in args
for key in ['git_init', 'github_remote_create', 'github_release_init',
            'run_task_install', 'bunch_add', 'obsidian_project_add']:
    assert any(args[i:i+2] == ['--data', key+'=false'] for i in range(len(args)-1))
if 'HARMON_INIT' not in os.environ:
    assert not subprocess.check_output(['git', '-C', args[1], 'remote']).strip()
    assert pathlib.Path(args[1]).stat().st_mode & 0o222 == 0
    assert not pathlib.Path(args[1], '.gitmodules').exists()
    assert subprocess.check_output(['git', '-C', args[1], 'rev-parse', 'HEAD'],
                                   text=True).strip() == pathlib.Path('expected-ref').read_text()
assert 'skill_categories' in pathlib.Path(args[args.index('--data-file')+1]).read_text()
pathlib.Path('copier-args.json').write_text(json.dumps(args))
pathlib.Path(args[2]).mkdir()
pathlib.Path(args[2], 'renovate.json').write_text(pathlib.Path('expected.json').read_text())
''')
        self.stub('renovate-config-validator', '''#!/bin/sh
[ "$*" = "--strict renovate.json" ] || exit 9
echo called >validator-called
''')

    def git(self, *args):
        return subprocess.check_output([self.real_git, '-C', str(self.template),
                                        '-c', 'user.name=Fixture',
                                        '-c', 'user.email=fixture@example.test', *args],
                                       text=True, stderr=subprocess.PIPE)

    def canonical_audit(self, ref=None, source='https://github.com/evanharmon1/harmon-init'):
        self.env.pop('HARMON_INIT', None)
        (self.root / '.copier-answers.yml').write_text(
            '_commit: ' + (ref or self.commit) + '\n_src_path: ' + source +
            '\nproject_name: demo\nskill_categories: [repo, universal]\n')
        self.stub('git', '#!/usr/bin/env python3\n' +
                  'REAL = ' + repr(self.real_git) + '\n' +
                  'SOURCE = ' + repr(str(self.template)) + '\n' +
                  'LOG = ' + repr(str(self.root / 'git-calls')) + '\n' + '''
import json, os, pathlib, subprocess, sys
args = sys.argv[1:]
with pathlib.Path(LOG).open('a') as f:
    f.write(json.dumps(args)+'\\n')
canonical = 'https://github.com/evanharmon1/harmon-init'
if args[0] in ('clone', 'ls-remote') and canonical in args:
    if args[0] == 'ls-remote' and os.environ.get('TEST_TAG_OBJECT'):
        print(os.environ['TEST_TAG_OBJECT']+'\\t'+args[-1])
        sys.exit(0)
    if args[0] == 'clone' and os.environ.get('TEST_CLONE_FAIL'):
        sys.exit(1)
    args = [SOURCE if item == canonical else item for item in args]
assert not any(item.startswith(('http://', 'https://', 'ssh://', 'git@', 'gh:')) for item in args)
sys.exit(subprocess.run([REAL, *args]).returncode)
''')

    def stub(self, name, text):
        path = self.bin / name
        path.write_text(text)
        path.chmod(0o755)

    def run_audit(self, success, validator_expected=True):
        env = dict(self.env, PATH=str(self.bin)+os.pathsep+self.env['PATH'])
        result = subprocess.run(['bash', '-c', 'set -euo pipefail\nfail=0\n'
                                 'have() { command -v "$1" >/dev/null 2>&1; }\n'
                                 'err() { echo "FAIL: $*" >&2; fail=1; }\n'
                                 + renovate_scan + '\nexit "$fail"'],
                                cwd=self.root, env=env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0 if success else 1, result.stderr)
        self.assertEqual((self.root / 'validator-called').exists(), validator_expected,
                         result.stderr)
        return result

    def test_canonical_snapshot_is_frozen_checked_out_and_has_no_remote(self):
        self.canonical_audit()
        self.run_audit(True)
        calls = [json.loads(line) for line in (self.root / 'git-calls').read_text().splitlines()]
        self.assertTrue(any(call[:2] == ['clone', '--no-checkout'] for call in calls))
        self.assertTrue(any('checkout' in call and '--detach' in call for call in calls))
        self.assertTrue(any(call[-3:] == ['remote', 'remove', 'origin'] for call in calls))

    def test_real_copier_accepts_the_read_only_guarded_snapshot(self):
        copier = shutil.which('copier')
        self.assertIsNotNone(copier)
        self.stub('copier', '#!/bin/sh\nexec ' + shlex.quote(copier) + ' "$@"\n')
        (self.root / 'renovate.json').write_text('{}')
        self.canonical_audit()
        self.run_audit(True)

    def test_all_canonical_source_spellings_are_accepted(self):
        for source in ['https://github.com/evanharmon1/harmon-init',
                       'https://github.com/evanharmon1/harmon-init.git',
                       'gh:evanharmon1/harmon-init']:
            with self.subTest(source=source):
                self.canonical_audit(source=source)
                self.run_audit(True)

    def test_noncanonical_source_refuses_before_clone_or_copier(self):
        self.canonical_audit(source='https://example.test/untrusted/template')
        self.assertIn('_src_path is not canonical', self.run_audit(False).stderr)
        self.assertFalse((self.root / 'git-calls').exists())
        self.assertFalse((self.root / 'copier-args.json').exists())

    def test_legacy_tag_needs_approval_then_freezes_its_object(self):
        self.canonical_audit(ref='v1.2.3')
        self.assertIn('ACCEPT_LEGACY_BASELINE=true', self.run_audit(False).stderr)
        self.assertFalse((self.root / 'git-calls').exists())
        self.assertFalse((self.root / 'copier-args.json').exists())
        self.env['ACCEPT_LEGACY_BASELINE'] = 'true'
        self.run_audit(True)
        self.assertIn('ls-remote', (self.root / 'git-calls').read_text())

    def test_tag_move_between_lookup_and_clone_refuses(self):
        self.canonical_audit(ref='v1.2.3')
        self.env.update(ACCEPT_LEGACY_BASELINE='true', TEST_TAG_OBJECT='f'*40)
        self.assertIn('tag changed', self.run_audit(False).stderr)
        self.assertFalse((self.root / 'copier-args.json').exists())

    def test_abbreviated_and_head_baselines_are_refused(self):
        for ref, message in [(self.commit[:12], 'abbreviated'), ('HEAD', 'must not be HEAD')]:
            with self.subTest(ref=ref):
                self.canonical_audit(ref=ref)
                self.env['ACCEPT_LEGACY_BASELINE'] = 'true'
                self.assertIn(message, self.run_audit(False).stderr)
                self.assertFalse((self.root / 'copier-args.json').exists())

    def test_missing_tag_and_clone_failure_refuse(self):
        self.canonical_audit(ref='missing-tag')
        self.env['ACCEPT_LEGACY_BASELINE'] = 'true'
        self.assertIn('tag is not present', self.run_audit(False).stderr)
        self.canonical_audit()
        self.env['TEST_CLONE_FAIL'] = 'true'
        self.assertIn('cannot snapshot', self.run_audit(False).stderr)
        self.assertFalse((self.root / 'copier-args.json').exists())

    def test_missing_commit_refuses_before_copier(self):
        self.canonical_audit(ref='f'*40)
        self.assertIn('baseline is not a commit', self.run_audit(False).stderr)
        self.assertFalse((self.root / 'copier-args.json').exists())

    def test_baseline_must_be_on_main(self):
        self.git('checkout', '-q', '--orphan', 'outside-main')
        self.git('commit', '-qm', 'unrelated history')
        outside = self.git('rev-parse', 'HEAD').strip()
        self.canonical_audit(ref=outside)
        self.assertIn('not on canonical origin/main', self.run_audit(False).stderr)
        self.assertFalse((self.root / 'copier-args.json').exists())

    def test_baseline_must_not_predate_v3(self):
        (self.template / 'later.txt').write_text('v3 boundary')
        self.git('add', '.')
        self.git('commit', '-qm', 'newer boundary')
        self.git('tag', '-f', 'v3.0.0')
        self.canonical_audit()
        self.assertIn('predates v3', self.run_audit(False).stderr)
        self.assertFalse((self.root / 'copier-args.json').exists())

    def test_missing_v3_boundary_refuses(self):
        self.git('tag', '-d', 'v3.0.0')
        self.canonical_audit()
        self.assertIn('cannot resolve the v3', self.run_audit(False).stderr)
        self.assertFalse((self.root / 'copier-args.json').exists())

    def test_submodule_declaration_refuses_before_copier(self):
        (self.template / '.gitmodules').write_text('[submodule "other"]\npath = other\n')
        self.git('add', '.')
        self.git('commit', '-qm', 'submodule declaration')
        self.canonical_audit(ref=self.git('rev-parse', 'HEAD').strip())
        self.assertIn('.gitmodules', self.run_audit(False).stderr)
        self.assertFalse((self.root / 'copier-args.json').exists())

    def test_prepared_and_remote_pins_override_legacy_answer_without_approval(self):
        self.env['HARMON_INIT_RECORDED_COMMIT'] = self.commit
        answers = self.root / '.copier-answers.yml'
        answers.write_text(answers.read_text().replace('v1.2.3', 'missing-tag'))
        self.run_audit(True)
        self.canonical_audit(ref='missing-tag')
        self.run_audit(True)
        args = json.loads((self.root / 'copier-args.json').read_text())
        self.assertIn('--vcs-ref=' + self.commit, args)

    def test_invalid_or_missing_prepared_pin_refuses(self):
        for pin in ['abcd', 'g'*40, '0'*40]:
            with self.subTest(pin=pin):
                self.env['HARMON_INIT_RECORDED_COMMIT'] = pin
                result = self.run_audit(False)
                self.assertIn('commit', result.stderr)
                self.assertFalse((self.root / 'copier-args.json').exists())

    def test_symlinked_and_dangling_configs_are_structural_failures(self):
        original = (self.root / 'renovate.json').read_text()
        (self.root / 'external.json').write_text(original)
        (self.root / 'renovate.json').unlink()
        for target in ['external.json', 'nonexistent.json']:
            with self.subTest(target=target):
                config = self.root / 'renovate.json'
                config.symlink_to(target)
                self.assertIn('structural failure',
                              self.run_audit(False, validator_expected=False).stderr)
                self.assertFalse((self.root / 'copier-args.json').exists())
                config.unlink()
        self.assertEqual((self.root / 'external.json').read_text(), original)

    def test_answers_must_be_a_yaml_mapping(self):
        for text in ['null\n', 'false\n', 'a string\n', '- value\n', 'broken: [\n']:
            with self.subTest(text=text):
                (self.root / '.copier-answers.yml').write_text(text)
                self.assertIn('must parse as a YAML mapping', self.run_audit(False).stderr)
                self.assertFalse((self.root / 'copier-args.json').exists())
        (self.root / 'renovate.json').unlink()
        (self.root / 'validator-called').unlink()
        (self.root / '.copier-answers.yml').write_text('- value\n')
        self.assertIn('must parse as a YAML mapping',
                      self.run_audit(False, validator_expected=False).stderr)

    def test_render_overrides_all_side_effect_answers(self):
        with (self.root / '.copier-answers.yml').open('a') as answers:
            for key in ['git_init', 'github_remote_create', 'github_release_init',
                        'run_task_install', 'bunch_add', 'obsidian_project_add']:
                answers.write(key + ': true\n')
        self.run_audit(True)  # Copier spy asserts each --data key=false override.

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
        self.env['HARMON_INIT'] = str(template)
        self.run_audit(True)
        self.assertFalse(marker.exists(), 'audit must not execute template tasks')

    def test_prepared_template_is_used(self):
        self.env['HARMON_INIT'] = str(self.template)
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
