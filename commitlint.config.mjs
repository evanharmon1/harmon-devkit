// Conventional Commits config — replaces conventional-pre-commit.
// The standard Conventional Commits type set: release-please maps feat →
// Features (minor), fix → Bug Fixes (patch), feat! / BREAKING CHANGE → major;
// the rest are non-releasing chores. See docs/conventions.md.
export default {
  extends: ['@commitlint/config-conventional'],
  rules: {
    'type-enum': [
      2,
      'always',
      ['build', 'chore', 'ci', 'docs', 'feat', 'fix', 'perf', 'refactor', 'revert', 'style', 'test']
    ]
  }
}
