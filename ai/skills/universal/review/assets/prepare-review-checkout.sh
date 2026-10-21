#!/usr/bin/env bash
# Sanctioned detached-worktree lifecycle for a vendored local finder pass.
set -euo pipefail
# Invariant for this tool, the finder, and every Git child they start.
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=core.hooksPath
export GIT_CONFIG_VALUE_0=/dev/null
exec node --input-type=module - "$@" <<'JS'
import { realpathSync, mkdirSync, mkdtempSync, readdirSync, lstatSync } from 'node:fs';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
const args = process.argv.slice(2);
const usage = 'usage: prepare-review-checkout.sh --repo-root DIR --head SHA -- <challenge|review> [finder arguments ...]';
const fail = (message) => { throw new Error(message); };
let checkout, root, added = false;
const execute = (argv, cwd = root) => spawnSync('git', argv, { cwd, encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 });
const git = (...argv) => {
  const r = execute(argv);
  if (r.status !== 0) fail(`git ${argv[0]} failed: ${r.stderr.trim()}`);
  return r.stdout.trim();
};
const cleanup = () => {
  if (checkout && added) {
    // Only remove the unique worktree whose add succeeded in this run.
    const r = execute(['worktree', 'remove', '--force', checkout]);
    if (r.status !== 0) {
      process.stderr.write(`prepare-review-checkout: cleanup failed for ${checkout}\n`);
      return false;
    }
  }
  checkout = undefined;
  return true;
};
try {
  const o = {};
  let i = 0;
  for (; i < args.length && args[i] !== '--'; i += 2) {
    if (!['--repo-root', '--head'].includes(args[i]) || !args[i + 1] || o[args[i]]) fail(usage);
    o[args[i]] = args[i + 1];
  }
  const finderArgs = args.slice(i + 1);
  if (!o['--repo-root'] || !/^[0-9a-f]{40}$/.test(o['--head'] ?? '') || args[i] !== '--' || !['challenge', 'review'].includes(finderArgs[0])) fail(usage);
  root = realpathSync(o['--repo-root']);
  if (git('rev-parse', '--show-toplevel') !== root) fail('repo-root must be the checkout root');
  const head = o['--head'];
  if (git('rev-parse', '--verify', `${head}^{commit}`) !== head) fail('head is not a locally available commit');
  // Explicitly fetch the remote's current symbolic HEAD, not a stale local main.
  const remote = git('ls-remote', '--symref', 'origin', 'HEAD');
  const match = /^ref: (refs\/heads\/[^\s]+)\s+HEAD$/m.exec(remote);
  if (!match) fail('origin has no resolvable default branch');
  const tracking = `refs/remotes/origin/${match[1].slice('refs/heads/'.length)}`;
  git('fetch', '--no-tags', 'origin', `+${match[1]}:${tracking}`);
  git('symbolic-ref', 'refs/remotes/origin/HEAD', tracking);
  const baseline = git('rev-parse', '--verify', 'refs/remotes/origin/HEAD^{commit}');
  const finder = 'scripts/codex-review.sh';
  if (execute(['cat-file', '-e', `${baseline}:${finder}`]).status !== 0) fail('default branch ships no scripts/codex-review.sh');
  const entries = (sha) => new Map(git('ls-tree', '-r', '-z', sha, '--', finder, 'scripts/lib/').split('\0').filter(Boolean).map((entry) => {
    const tab = entry.indexOf('\t');
    return [entry.slice(tab + 1), entry.slice(0, tab)];
  }));
  const trusted = entries(baseline), candidate = entries(head);
  const libraryRoot = git('ls-tree', baseline, '--', 'scripts/lib');
  if (libraryRoot && !libraryRoot.startsWith('040000 tree ')) fail('scripts/lib must be a directory');
  const different = [...new Set([...trusted.keys(), ...candidate.keys()])].filter((p) => trusted.get(p) !== candidate.get(p));
  if (different.length) fail(`finder differs from default branch: ${different.join(', ')}`);
  // Reject symlinks/submodules: checkout bytes must be the compared blobs,
  // never a path that resolves to outside the captured tree.
  for (const [path, metadata] of trusted) if (!/^100(644|755) blob /.test(metadata)) fail(`finder path is not a regular blob: ${path}`);
  const parent = join(root, '.worktrees');
  mkdirSync(parent, { recursive: true });
  if (realpathSync(parent) !== parent) fail('.worktrees must not be a symlink');
  checkout = mkdtempSync(join(parent, `review-${head.slice(0, 12)}-`));
  git('worktree', 'add', '--detach', checkout, head);
  added = true;
  const exactHead = () => {
    const detached = execute(['symbolic-ref', '-q', 'HEAD'], checkout);
    if (detached.status !== 1) fail('review checkout is not detached');
    const actual = execute(['rev-parse', 'HEAD'], checkout);
    if (actual.status !== 0 || actual.stdout.trim() !== head) fail('review checkout head changed');
  };
  exactHead();
  const clean = () => {
    const r = execute(['status', '--porcelain', '--untracked-files=all', '--ignored'], checkout);
    if (r.status !== 0 || r.stdout !== '') fail('review checkout is dirty (including ignored files)');
  };
  clean();
  // Status can hide skip-worktree/assume-unchanged paths. After
  // the object-tree proof, verify the physical file set and unfiltered bytes.
  const flags = execute(['ls-files', '-v', '-z', '--', finder, 'scripts/lib/'], checkout);
  if (flags.status !== 0) fail('could not read finder index flags');
  for (const entry of flags.stdout.split('\0').filter(Boolean)) {
    if (entry[0] !== 'H') fail(`finder has skip-worktree or assume-unchanged flag: ${entry.slice(2)}`);
  }
  const files = new Map();
  const collect = (path) => {
    const full = join(checkout, path);
    let stat;
    try { stat = lstatSync(full); }
    catch (error) { if (error.code === 'ENOENT') return; throw error; }
    if (stat.isDirectory()) {
      for (const entry of readdirSync(full)) collect(`${path}/${entry}`);
    } else {
      if (!stat.isFile()) fail(`finder path is not a regular file: ${path}`);
      const r = execute(['hash-object', '--no-filters', '--', full], checkout);
      if (r.status !== 0) fail(`could not hash finder path: ${path}`);
      files.set(path, r.stdout.trim());
    }
  };
  collect(finder);
  collect('scripts/lib');
  const changed = [...new Set([...trusted.keys(), ...files.keys()])]
    .filter((path) => trusted.get(path)?.split(' ')[2] !== files.get(path));
  if (changed.length) fail(`finder bytes differ from default branch: ${changed.join(', ')}`);
  const r = spawnSync('bash', [join(checkout, finder), ...finderArgs], { cwd: checkout, stdio: 'inherit' });
  exactHead();
  clean();
  if (r.status === null) fail('finder did not complete');
  process.exitCode = r.status;
} catch (error) {
  process.stderr.write(`prepare-review-checkout: ${error.message}\n`);
  process.exitCode = 2;
} finally {
  if (!cleanup()) process.exitCode = 2;
}
JS
