#!/usr/bin/env bash
# Render/verify a standardize review bundle. Requires Python 3, Copier and yq v4.
# HARMON_INIT selects an independently prepared template checkout; otherwise
# use canonical harmon-init. Never take a template source from bundle metadata.
set -euo pipefail
exec python3 - "$@" <<'PY'
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile


def fail(message):
    raise ValueError(message)


def run(*args, data=None):
    return subprocess.check_output(args, input=data, stderr=subprocess.PIPE)


def git(repo, *args):
    return run('git', '-C', str(repo), *args)


def yaml(data):
    return json.loads(run('yq', '-o=json', '.', '-', data=data))


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=True).encode()


def digest(root, protected):
    # lstat and no directory-link traversal: hash exact names, file bytes,
    # executable bit and link targets; no text filters or Git configuration.
    entries = []
    def visit(directory):
        for path in sorted(directory.iterdir(), key=lambda p: os.fsencode(p.name)):
            relative = path.relative_to(root).as_posix()
            mode = path.lstat().st_mode
            if stat.S_ISDIR(mode):
                visit(path)
                continue
            if relative in protected:
                continue
            if stat.S_ISLNK(mode):
                entry = [relative, '120000', os.readlink(path)]
            elif stat.S_ISREG(mode):
                entry = [relative, '100755' if mode & 0o111 else '100644',
                         hashlib.sha256(path.read_bytes()).hexdigest()]
            else:
                fail('render contains an unsupported filesystem entry')
            entries.append(entry)
    if root.is_symlink() or not root.is_dir():
        fail('render must be a real directory')
    visit(root)
    return hashlib.sha256(canonical(sorted(entries))).hexdigest()


def regular(path):
    if path.is_symlink() or not path.is_file():
        fail('bundle file is missing or not regular: ' + str(path))
    return path.read_bytes()


def owned_paths(scratch, configurations, paths):
    # Copier uses pathspec's gitignore dialect. Git agrees for ordinary
    # literals/globs; unsupported declarations only widen protection. Evaluate
    # each release separately so one release cannot negate the other's rules.
    protected = {'.copier-answers.yml'}
    for index, config in enumerate(configurations):
        environment = config.get('_envops') or {}
        if not isinstance(environment, dict):
            fail('invalid _envops declaration')
        delimiters = [environment.get(key, default) for key, default in (
            ('variable_start_string', '{{'), ('block_start_string', '{%'),
            ('comment_start_string', '{#'))]
        if any(not isinstance(value, str) or not value for value in delimiters):
            fail('invalid Jinja delimiter')
        patterns = config.get('_skip_if_exists', [])
        if not isinstance(patterns, list) or any(not isinstance(p, str) or not p for p in patterns):
            fail('invalid _skip_if_exists declaration')
        supported = []
        uncertain_prefixes = []
        for pattern in patterns:
            # Git's parent-directory propagation differs from pathspec for
            # negation and a final /*. Non-ASCII normalization also differs.
            # For these shapes retain all potentially affected paths.
            positions = [pattern.find(d) for d in delimiters if d in pattern]
            uncertain = bool(positions) or not pattern.isascii() or '\n' in pattern or '\r' in pattern
            uncertain |= pattern.startswith('!') or pattern.rstrip('/').endswith('/*')
            if uncertain:
                literal = pattern.lstrip('!')
                stop = min([literal.find(d) for d in delimiters if d in literal]
                           + [literal.find(c) for c in '*?[\\\n\r' if c in literal]
                           + [i for i, c in enumerate(literal) if not c.isascii()] + [len(literal)])
                prefix = literal[:stop].lstrip('/')
                # Only an anchored directory prefix can constrain an unknown
                # pattern; a basename pattern may match at any depth.
                prefix = prefix.rsplit('/', 1)[0] + '/' if '/' in prefix else ''
                uncertain_prefixes.append(prefix)
            else:
                supported.append(pattern)
        evaluator = scratch / ('skip-patterns-' + str(index))
        evaluator.mkdir()
        git(evaluator, 'init', '--quiet')
        (evaluator / '.gitignore').write_text('\n'.join(supported) + '\n')
        probe = subprocess.run(
            ['git', '-C', str(evaluator), '-c', 'core.excludesFile=/dev/null',
             'check-ignore', '--no-index', '-z', '--stdin'],
            input=b''.join(os.fsencode(path) + b'\0' for path in paths),
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
        if probe.returncode not in (0, 1):
            fail('cannot evaluate _skip_if_exists patterns')
        protected.update(os.fsdecode(path) for path in probe.stdout.split(b'\0') if path)
        protected.update(path for path in paths if any(path.startswith(prefix) for prefix in uncertain_prefixes))
    return protected


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--verify', action='store_true')
    for name in ('release', 'base', 'head'):
        parser.add_argument('--' + name, required=True)
    parser.add_argument('--previous-release')
    parser.add_argument('--output')
    parser.add_argument('--frozen-render')
    parser.add_argument('--protected-output')
    parser.add_argument('--verified-output')
    parser.add_argument('target', nargs='?', default='.')
    args = parser.parse_args()
    if args.verify:
        if not args.frozen_render or not args.protected_output or not args.verified_output:
            fail('--verify requires --frozen-render, --protected-output and --verified-output')
    elif not args.output or not args.previous_release:
        fail('producer requires --output and --previous-release')
    os.environ['GIT_NO_REPLACE_OBJECTS'] = '1'
    repo = Path(args.target).resolve()
    for oid in (args.base, args.head):
        if not re.fullmatch(r'[0-9a-f]{40}|[0-9a-f]{64}', oid):
            fail('base/head must be full lowercase commit IDs')
        if git(repo, 'rev-parse', '--verify', oid + '^{commit}').decode().strip() != oid:
            fail('base/head do not resolve to the supplied commit IDs')
    grafts = Path(git(repo, 'rev-parse', '--path-format=absolute', '--git-path', 'info/grafts').decode().strip())
    if grafts.exists():
        fail('overridden repository history (info/grafts) is unsupported')
    bundle = Path(args.frozen_render if args.verify else args.output).absolute()
    metadata = None
    if args.verify:
        def unique(pairs):
            result = {}
            for key, value in pairs:
                if key in result:
                    fail('duplicate metadata key')
                result[key] = value
            return result
        metadata = json.loads(regular(bundle / 'metadata'), object_pairs_hook=unique)
        if not isinstance(metadata, dict):
            fail('bundle metadata must be an object')
        if metadata.get('release') != args.release:
            fail('bundle release does not match --release')
        previous = metadata.get('previous-release')
    else:
        if bundle.exists() or bundle.is_symlink():
            fail('--output must not already exist')
        previous = args.previous_release
    for release in (previous, args.release):
        if not isinstance(release, str) or not re.fullmatch(r'v[0-9][0-9A-Za-z.+_-]*', release):
            fail('release must name an explicit version tag (v...)')
    with tempfile.TemporaryDirectory(prefix='harmon-render-bundle-') as temp:
        scratch = Path(temp)
        source = os.environ.get('HARMON_INIT')
        render_source = source or 'https://github.com/evanharmon1/harmon-init'
        if source is None:
            source = str(scratch / 'template')
            run('git', 'clone', '--no-checkout', '--quiet',
                'https://github.com/evanharmon1/harmon-init', source)
        source = Path(source).resolve()
        template_grafts = Path(git(source, 'rev-parse', '--path-format=absolute', '--git-path', 'info/grafts').decode().strip())
        if template_grafts.exists():
            fail('overridden template history (info/grafts) is unsupported')
        commits = [git(source, 'rev-parse', '--verify', 'refs/tags/' + tag + '^{commit}').decode().strip()
                   for tag in (previous, args.release)]
        answer_bytes = [git(repo, 'show', oid + ':.copier-answers.yml')
                        for oid in (args.base, args.head)]
        answers = [yaml(data) for data in answer_bytes]
        if any(not isinstance(answer, dict) for answer in answers):
            fail('captured Copier answers must be mappings')
        # A bundle cannot choose an unrelated previous release that happens to
        # contain a repository customization. The base's recorded baseline is
        # the independent authority for that tag.
        if answers[0].get('_commit') not in (previous, commits[0]):
            fail('previous release does not match the base Copier baseline')
        expected = {'format': 'harmon-devkit-review-frozen-render-v2',
                    'release': args.release, 'previous-release': previous,
                    'base': args.base, 'head': args.head,
                    'previous-commit': commits[0], 'current-commit': commits[1],
                    'answers-sha256': [hashlib.sha256(data).hexdigest() for data in answer_bytes]}
        configurations = []
        renders = []
        for index, (side, commit, answer) in enumerate(zip(('previous', 'current'), commits, answers)):
            names = git(source, 'ls-tree', '--name-only', '-z', commit).split(b'\0')
            configs = [name.decode() for name in names if re.fullmatch(rb'copier\.ya?ml', name, re.I)
                       and name.startswith(b'copier.')]
            if len(configs) != 1:
                fail('tag must contain exactly one Copier YAML configuration')
            config = yaml(git(source, 'show', commit + ':' + configs[0]))
            if not isinstance(config, dict):
                fail('Copier configuration must be a mapping')
            configurations.append(config)
            datafile = scratch / (side + '-answers.json')
            # Copier accepts JSON as YAML. Do not let persisted internal source
            # keys select the template or a revision instead of the pinned tag.
            datafile.write_bytes(canonical({key: value for key, value in answer.items() if not key.startswith('_')}))
            render = scratch / side
            run('copier', 'copy', render_source, str(render), '--vcs-ref=' + commit,
                '--defaults', '--trust', '--skip-tasks', '--data-file', str(datafile))
            renders.append(render)
        changed = git(repo, 'diff', '--no-ext-diff', '--no-renames', '--ignore-submodules=none',
                      '--name-only', '-z', args.base, args.head).split(b'\0')
        paths = {os.fsdecode(path) for path in changed if path}
        for root in renders + ([bundle / 'previous', bundle / 'current'] if args.verify else []):
            paths.update(path.relative_to(root).as_posix() for path in root.rglob('*'))
        protected = owned_paths(scratch, configurations, paths)
        # Only excludable leaves are bound. Directories and repo-owned files
        # never qualify for exclusions, including nondeterministic scaffolding.
        for side, render in zip(('previous', 'current'), renders):
            expected[side + '-sha256'] = digest(render, protected)
        # Binding includes every metadata field. Rebuilding a digest in a
        # crafted bundle does not help: the independent render must agree too.
        expected['binding-sha256'] = hashlib.sha256(canonical(expected)).hexdigest()
        if args.verify:
            if metadata != expected:
                fail('bundle metadata binding does not match tagged releases and captured commits')
            for side in ('previous', 'current'):
                if digest(bundle / side, protected) != expected[side + '-sha256']:
                    fail('bundle render tree binding mismatch: ' + side)
            for side, render in zip(('previous', 'current'), renders):
                shutil.copytree(render, Path(args.verified_output) / side, symlinks=True)
            Path(args.protected_output).write_bytes(b''.join(path + b'\0' for path in changed if path and os.fsdecode(path) in protected))
        else:
            # Publish only after every render and digest succeeded.
            staging = scratch / 'bundle'
            staging.mkdir()
            for side, render in zip(('previous', 'current'), renders):
                shutil.copytree(render, staging / side, symlinks=True)
            (staging / 'metadata').write_bytes(canonical(expected) + b'\n')
            for name in ('conflict-resolutions.nul', 'repo-owned.nul'):
                (staging / name).write_bytes(b'')
            shutil.copytree(staging, bundle, symlinks=True)


try:
    main()
except (ValueError, OSError, subprocess.CalledProcessError) as error:
    # Never print template subprocess output: answers or render diagnostics may
    # contain local values. A refused bundle never becomes an empty path set.
    print('FAIL: frozen-render binding: ' + str(error), file=sys.stderr)
    sys.exit(2)
PY
