#!/usr/bin/env bash
# Sanctioned detached-worktree lifecycle for a vendored local finder pass.
set -euo pipefail
# These invariants are inherited by the finder and every Git child.
export GIT_NO_REPLACE_OBJECTS=1
unset GIT_CONFIG_PARAMETERS
exec node --input-type=module - "$@" <<'JS'
import { realpathSync, mkdirSync, mkdtempSync, readdirSync, lstatSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
// Preserve caller entries (for example transport rewrites), then override
// executable Git integrations for the entire tool/finder process tree.
const configCount = Number(process.env.GIT_CONFIG_COUNT ?? '0');
if (!Number.isSafeInteger(configCount) || configCount < 0) throw new Error('invalid GIT_CONFIG_COUNT');
for (const [offset, [key, value]] of [['core.hooksPath', '/dev/null'], ['core.fsmonitor', 'false']].entries()) {
  process.env[`GIT_CONFIG_KEY_${configCount + offset}`] = key;
  process.env[`GIT_CONFIG_VALUE_${configCount + offset}`] = value;
}
process.env.GIT_CONFIG_COUNT = String(configCount + 2);
const args = process.argv.slice(2);
const usage = 'usage: prepare-review-checkout.sh --repo-root DIR --head SHA [--trusted-finder-root DIR --trusted-finder-head SHA] -- <challenge|review> [finder arguments ...]';
const fail = (message) => { throw new Error(message); };
let checkout, root;
const worktrees = [];
const execute = (argv, cwd = root) => spawnSync('git', argv, { cwd, encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 });
const gitAt = (cwd, ...argv) => {
  const r = execute(argv, cwd);
  if (r.status !== 0) fail(`git ${argv[0]} failed: ${r.stderr.trim()}`);
  return r.stdout.trim();
};
const git = (...argv) => gitAt(root, ...argv);
const cleanup = () => {
  let clean = true;
  for (const entry of worktrees.reverse()) {
    // Only remove unique worktrees whose add succeeded in this run.
    const r = execute(['worktree', 'remove', '--force', entry.path], entry.owner);
    if (r.status !== 0) {
      process.stderr.write(`prepare-review-checkout: cleanup failed for ${entry.path}\n`);
      clean = false;
    }
  }
  checkout = undefined;
  return clean;
};
try {
  const o = {};
  let i = 0;
  for (; i < args.length && args[i] !== '--'; i += 2) {
    if (!['--repo-root', '--head', '--trusted-finder-root', '--trusted-finder-head'].includes(args[i]) || !args[i + 1] || o[args[i]]) fail(usage);
    o[args[i]] = args[i + 1];
  }
  const finderArgs = args.slice(i + 1);
  if (!o['--repo-root'] || !/^[0-9a-f]{40}$/.test(o['--head'] ?? '') || args[i] !== '--' || !['challenge', 'review'].includes(finderArgs[0])) fail(usage);
  if (Boolean(o['--trusted-finder-root']) !== Boolean(o['--trusted-finder-head']) ||
      (o['--trusted-finder-head'] && !/^[0-9a-f]{40}$/.test(o['--trusted-finder-head']))) fail(usage);
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
  const entries = (repo, sha) => new Map(gitAt(repo, 'ls-tree', '-r', '-z', sha, '--', finder, 'scripts/lib/').split('\0').filter(Boolean).map((entry) => {
    const tab = entry.indexOf('\t');
    return [entry.slice(tab + 1), entry.slice(0, tab)];
  }));
  const verifyTree = (repo, sha, label) => {
    if (execute(['cat-file', '-e', `${sha}:${finder}`], repo).status !== 0) fail(`${label} ships no scripts/codex-review.sh`);
    const tree = entries(repo, sha);
    const libraryRoot = gitAt(repo, 'ls-tree', sha, '--', 'scripts/lib');
    if (libraryRoot && !libraryRoot.startsWith('040000 tree ')) fail(`${label} scripts/lib must be a directory`);
    // Reject symlinks/submodules: checkout bytes must be the compared blobs,
    // never a path that resolves outside the captured tree.
    for (const [path, metadata] of tree) if (!/^100(644|755) blob /.test(metadata)) fail(`${label} finder path is not a regular blob: ${path}`);
    return tree;
  };
  let trustedRoot = root;
  let trustedHead = baseline;
  let trustedLabel = 'default branch';
  let trusted;
  let candidate;
  let external = Boolean(o['--trusted-finder-root']);
  if (external) {
    trustedRoot = realpathSync(o['--trusted-finder-root']);
    if (gitAt(trustedRoot, 'rev-parse', '--show-toplevel') !== trustedRoot) fail('trusted-finder-root must be the checkout root');
    trustedHead = o['--trusted-finder-head'];
    if (gitAt(trustedRoot, 'rev-parse', '--verify', `${trustedHead}^{commit}`) !== trustedHead) fail('trusted-finder-head is not a locally available commit');
    if (trustedRoot === root && trustedHead === head) fail('candidate head cannot be its own trusted finder');
    trustedLabel = 'operator-pinned finder';
    trusted = verifyTree(trustedRoot, trustedHead, trustedLabel);
  } else {
    trusted = verifyTree(root, baseline, trustedLabel);
    candidate = entries(root, head);
    const different = [...new Set([...trusted.keys(), ...candidate.keys()])].filter((p) => trusted.get(p) !== candidate.get(p));
    external = different.length > 0;
  }
  const parent = join(root, '.worktrees');
  mkdirSync(parent, { recursive: true });
  if (realpathSync(parent) !== parent) fail('.worktrees must not be a symlink');
  const addWorktree = (owner, sha, prefix) => {
    const path = mkdtempSync(join(parent, prefix));
    gitAt(owner, 'worktree', 'add', '--detach', path, sha);
    worktrees.push({ owner, path });
    return path;
  };
  checkout = addWorktree(root, head, `review-${head.slice(0, 12)}-`);
  const exactHead = (path, expected) => {
    const detached = execute(['symbolic-ref', '-q', 'HEAD'], path);
    if (detached.status !== 1) fail('review checkout is not detached');
    const actual = execute(['rev-parse', 'HEAD'], path);
    if (actual.status !== 0 || actual.stdout.trim() !== expected) fail('review checkout head changed');
  };
  exactHead(checkout, head);
  const clean = (path) => {
    const r = execute(['status', '--porcelain', '--untracked-files=all', '--ignored'], path);
    if (r.status !== 0 || r.stdout !== '') fail('review checkout is dirty (including ignored files)');
  };
  clean(checkout);
  // Status can hide skip-worktree/assume-unchanged paths. After
  // the object-tree proof, verify the physical file set and unfiltered bytes.
  const verifyPhysical = (path, tree, label) => {
    const flags = execute(['ls-files', '-v', '-z', '--', finder, 'scripts/lib/'], path);
    if (flags.status !== 0) fail(`could not read ${label} index flags`);
    for (const entry of flags.stdout.split('\0').filter(Boolean)) {
      if (entry[0] !== 'H') fail(`${label} has skip-worktree or assume-unchanged flag: ${entry.slice(2)}`);
    }
    const files = new Map();
    const collect = (relative) => {
      const full = join(path, relative);
      let stat;
      try { stat = lstatSync(full); }
      catch (error) { if (error.code === 'ENOENT') return; throw error; }
      if (stat.isDirectory()) {
        for (const entry of readdirSync(full)) collect(`${relative}/${entry}`);
      } else {
        if (!stat.isFile()) fail(`${label} path is not a regular file: ${relative}`);
        const r = execute(['hash-object', '--no-filters', '--', full], path);
        if (r.status !== 0) fail(`could not hash ${label} path: ${relative}`);
        files.set(relative, r.stdout.trim());
      }
    };
    collect(finder);
    collect('scripts/lib');
    const changed = [...new Set([...tree.keys(), ...files.keys()])]
      .filter((relative) => tree.get(relative)?.split(' ')[2] !== files.get(relative));
    if (changed.length) fail(`${label} bytes differ from captured commit: ${changed.join(', ')}`);
  };
  let runnerCheckout = checkout;
  let runnerArgs = finderArgs;
  if (external) {
    runnerCheckout = addWorktree(trustedRoot, trustedHead, `finder-${trustedHead.slice(0, 12)}-`);
    exactHead(runnerCheckout, trustedHead);
    clean(runnerCheckout);
    verifyPhysical(runnerCheckout, trusted, trustedLabel);
    const runnerSource = readFileSync(join(runnerCheckout, finder), 'utf8');
    if (!runnerSource.includes('--repo-root <path>') ||
        !/(?:^|\n)[ \t]*(?:--repo-root\)|if .* = --repo-root)/.test(runnerSource)) {
      fail(`${trustedLabel} does not support --repo-root`);
    }
    runnerArgs = [finderArgs[0], '--repo-root', checkout, ...finderArgs.slice(1)];
  } else {
    verifyPhysical(checkout, trusted, 'candidate finder');
  }
  const r = spawnSync('bash', [join(runnerCheckout, finder), ...runnerArgs], { cwd: checkout, stdio: 'inherit' });
  exactHead(checkout, head);
  clean(checkout);
  if (external) {
    exactHead(runnerCheckout, trustedHead);
    clean(runnerCheckout);
  }
  if (r.status === null) fail('finder did not complete');
  process.exitCode = r.status;
} catch (error) {
  process.stderr.write(`prepare-review-checkout: ${error.message}\n`);
  process.exitCode = 2;
} finally {
  if (!cleanup()) process.exitCode = 2;
}
JS
