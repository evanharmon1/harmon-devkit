# Changelog

All notable changes to Harmon DevKit are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Releases are cut manually with `task release:patch|minor|major` (never
automatically on merge).

## [0.8.0](https://github.com/evanharmon1/harmon-devkit/compare/v0.7.2...v0.8.0) (2026-07-19)


### ⚠ BREAKING CHANGES

* **skills:** the skill directory and name change from `design-handoff` to `implement-design`. Repos that vendor it via skills-sync keep a stale `design-handoff/` directory until it is removed; re-sync and delete the old directory. Invoke as `/implement-design`.

### Features

* **design-handoff:** always ship downloadable logos on /brand ([#106](https://github.com/evanharmon1/harmon-devkit/issues/106)) ([e1bd734](https://github.com/evanharmon1/harmon-devkit/commit/e1bd73483efea46312e41dea1d0a61c310c55f4b))
* **skills:** rename design-handoff to implement-design ([#108](https://github.com/evanharmon1/harmon-devkit/issues/108)) ([65edbb1](https://github.com/evanharmon1/harmon-devkit/commit/65edbb111c147e2c80029e0643234c5fd629db62))

## [0.7.2](https://github.com/evanharmon1/harmon-devkit/compare/v0.7.1...v0.7.2) (2026-07-18)


### Bug Fixes

* update to harmon-init v4.1.0 and adopt the release-content guard ([#99](https://github.com/evanharmon1/harmon-devkit/issues/99)) ([4cb937d](https://github.com/evanharmon1/harmon-devkit/commit/4cb937d3f19ee41605d0caa79c667dd8497fa4d2))

## [0.7.1](https://github.com/evanharmon1/harmon-devkit/compare/v0.7.0...v0.7.1) (2026-07-17)


### Bug Fixes

* **skills:** require safe design bundle ingestion ([#97](https://github.com/evanharmon1/harmon-devkit/issues/97)) ([1fccc29](https://github.com/evanharmon1/harmon-devkit/commit/1fccc29f850f12b43d9fc0c556e678861d1afe5b))

## [0.7.0](https://github.com/evanharmon1/harmon-devkit/compare/v0.6.2...v0.7.0) (2026-07-16)


### Features

* **security:** align standardize-repo with the tiered repository scanning policy ([#94](https://github.com/evanharmon1/harmon-devkit/issues/94)) ([e243875](https://github.com/evanharmon1/harmon-devkit/commit/e243875c33edb4aa5b2cbbae57c4dff507f3de56))
* **standardize-repo:** add bot PAT setup guidance to the post-generation checklist ([#93](https://github.com/evanharmon1/harmon-devkit/issues/93)) ([338f89b](https://github.com/evanharmon1/harmon-devkit/commit/338f89b0e6191ceb87cd422c372d0c147fe38936))

## [0.6.2](https://github.com/evanharmon1/harmon-devkit/compare/v0.6.1...v0.6.2) (2026-07-13)


### Bug Fixes

* **skills:** harden sync-skills dest against absolute/traversal paths ([#89](https://github.com/evanharmon1/harmon-devkit/issues/89)) ([a81bb40](https://github.com/evanharmon1/harmon-devkit/commit/a81bb4056b12639166a1c7970357461335354297))

## [0.6.1](https://github.com/evanharmon1/harmon-devkit/compare/v0.6.0...v0.6.1) (2026-07-13)


### Bug Fixes

* **skills:** design-handoff review-finding fixes (CodeRabbit on ponderous-site[#31](https://github.com/evanharmon1/harmon-devkit/issues/31) + lawnomator-site[#14](https://github.com/evanharmon1/harmon-devkit/issues/14)) ([#86](https://github.com/evanharmon1/harmon-devkit/issues/86)) ([61534e2](https://github.com/evanharmon1/harmon-devkit/commit/61534e29459a0bb249eff1e22f25e2ac0ae65e68))

## [0.6.0](https://github.com/evanharmon1/harmon-devkit/compare/v0.5.0...v0.6.0) (2026-07-12)


### Features

* **skills:** local-skill-safe sync engine + standardize-repo fixes ([#82](https://github.com/evanharmon1/harmon-devkit/issues/82)) ([ce46861](https://github.com/evanharmon1/harmon-devkit/commit/ce468612d90e5bc4eca8ca5de18ad677e3ad0340))

## [0.5.0](https://github.com/evanharmon1/harmon-devkit/compare/v0.4.0...v0.5.0) (2026-07-11)


### Features

* **skills-sync:** vendor & sync shared agent skills from harmon-devkit ([#76](https://github.com/evanharmon1/harmon-devkit/issues/76)) ([24ae0d0](https://github.com/evanharmon1/harmon-devkit/commit/24ae0d02ed3bbe42b616f69f6db33accc9460b32)), closes [#53](https://github.com/evanharmon1/harmon-devkit/issues/53)

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
