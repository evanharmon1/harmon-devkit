// Conventional Commits config — replaces conventional-pre-commit.
// Allowed types match what we used previously.
export default {
  extends: ['@commitlint/config-conventional'],
  rules: {
    'type-enum': [
      2,
      'always',
      [
        'build',
        'change',
        'chore',
        'ci',
        'docs',
        'feat',
        'fix',
        'perf',
        'refactor',
        'remove',
        'revert',
        'style',
        'test'
      ]
    ]
  }
}
