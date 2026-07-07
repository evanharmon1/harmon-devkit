# Changelog

All notable changes to Harmon DevKit are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Releases are cut manually with `task release:patch|minor|major` (never
automatically on merge).

## [0.4.0](https://github.com/evanharmon1/harmon-devkit/compare/v0.3.1...v0.4.0) (2026-07-07)


### Features

* **design-handoff:** harden the skill from a live handoff run ([#74](https://github.com/evanharmon1/harmon-devkit/issues/74)) ([b0d12d1](https://github.com/evanharmon1/harmon-devkit/commit/b0d12d1a43281fe4cf597c30e9932c00d03c4803))

## [0.3.1](https://github.com/evanharmon1/harmon-devkit/compare/v0.3.0...v0.3.1) (2026-07-07)


### Bug Fixes

* **standardize-repo:** --show shows all drift + update-mode guidance ([#71](https://github.com/evanharmon1/harmon-devkit/issues/71)) ([52a71b6](https://github.com/evanharmon1/harmon-devkit/commit/52a71b6d21c3ecd5e32f79876bf650c868d90bb8))

## [0.3.0](https://github.com/evanharmon1/harmon-devkit/compare/v0.2.0...v0.3.0) (2026-07-04)


### Features

* **design-handoff:** session-hardened gates, assets, and guidance from the ponderous-web v2 run ([#60](https://github.com/evanharmon1/harmon-devkit/issues/60)) ([c75baea](https://github.com/evanharmon1/harmon-devkit/commit/c75baeada3385a4199a30d5890bd11d10a9cc5ca))

## [0.2.0](https://github.com/evanharmon1/harmon-devkit/compare/v0.1.0...v0.2.0) (2026-07-01)


### Features

* add ai/ design skill suite and document it in CLAUDE.md + README ([#8](https://github.com/evanharmon1/harmon-devkit/issues/8)) ([c5ab996](https://github.com/evanharmon1/harmon-devkit/commit/c5ab9967de1ae77d5d46ac83654a7bb38fbb83c2))
* **skills:** add standardize-repo skill ([#13](https://github.com/evanharmon1/harmon-devkit/issues/13)) ([a35b837](https://github.com/evanharmon1/harmon-devkit/commit/a35b83748e4ea1bc39b8bbab58fbcbc1bb35f632))
* **skills:** upgrade design-handoff for greenfield + real export bundle ([#9](https://github.com/evanharmon1/harmon-devkit/issues/9)) ([5e8f9d7](https://github.com/evanharmon1/harmon-devkit/commit/5e8f9d77f4fafc57ff61412c883df7784f2f339f))
* **standardize-repo:** add update mode + template drift detection ([#28](https://github.com/evanharmon1/harmon-devkit/issues/28)) ([b942d17](https://github.com/evanharmon1/harmon-devkit/commit/b942d1737b7b230899362297e1d23d6cbd54ed60))
* **standardize-repo:** audit for status:setup + universal Taskfile targets ([#26](https://github.com/evanharmon1/harmon-devkit/issues/26)) ([da89dd9](https://github.com/evanharmon1/harmon-devkit/commit/da89dd93c8887064d2779fb0e35843f6be6f5859))
* **standardize-repo:** detect missing template files, not just drift ([#34](https://github.com/evanharmon1/harmon-devkit/issues/34)) ([b37beda](https://github.com/evanharmon1/harmon-devkit/commit/b37bedab1ea782e36d943eeeba5147d9aeccad68))
* **standardize-repo:** enforce the workflow↔Taskfile contract in verify-applied ([#35](https://github.com/evanharmon1/harmon-devkit/issues/35)) ([7203465](https://github.com/evanharmon1/harmon-devkit/commit/7203465b95243a560c29f99f33f46751a8b338c2))
* **standardize-repo:** guard against CODEOWNERS owner drops on adopt ([#43](https://github.com/evanharmon1/harmon-devkit/issues/43)) ([0a318ce](https://github.com/evanharmon1/harmon-devkit/commit/0a318ce6f4bcbf58f1f389e5c49b04543054fd1a))


### Bug Fixes

* make lint:markdown a read-only gate + codify the standard ([#44](https://github.com/evanharmon1/harmon-devkit/issues/44)) ([63b8784](https://github.com/evanharmon1/harmon-devkit/commit/63b87840fdae953f983bb693c51ac01e38c0a992))
* **standardize-repo:** adopt-doc + verify-applied fixes from v2→v3 stack work ([#41](https://github.com/evanharmon1/harmon-devkit/issues/41)) ([67b88d1](https://github.com/evanharmon1/harmon-devkit/commit/67b88d1e715f07bdf03ccc9db494483c05e01aec))
* **standardize-repo:** align org Project Status options with renamed automation ([#48](https://github.com/evanharmon1/harmon-devkit/issues/48)) ([6c59c40](https://github.com/evanharmon1/harmon-devkit/commit/6c59c4055ba1f9ab1a7e4af3bacdf728866e04b0))
* **standardize-repo:** scan only non-ignored files for template markers ([#22](https://github.com/evanharmon1/harmon-devkit/issues/22)) ([3416e67](https://github.com/evanharmon1/harmon-devkit/commit/3416e67c7b842ddc893f3c92939a75f42c3a4c7b))
* **standardize-repo:** stop two audit false positives ([#30](https://github.com/evanharmon1/harmon-devkit/issues/30)) ([137ac54](https://github.com/evanharmon1/harmon-devkit/commit/137ac5460489e95126d1f6042228d3702c22f161))

## [Unreleased]

### Added

- Initial repository scaffolding generated from [harmon-init](https://github.com/evanharmon1/harmon-init) on 2026-06-27.
