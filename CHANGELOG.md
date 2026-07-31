# Changelog

All notable changes to Harmon DevKit are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Releases are cut manually with `task release:patch|minor|major` (never
automatically on merge).

## [0.14.0](https://github.com/evanharmon1/harmon-devkit/compare/v0.13.2...v0.14.0) (2026-07-31)


### Features

* make draft PRs the agent workbench ([#230](https://github.com/evanharmon1/harmon-devkit/issues/230)) ([bac3036](https://github.com/evanharmon1/harmon-devkit/commit/bac3036533b3be732323ac056b645308b56c0f7e))

## [0.13.2](https://github.com/evanharmon1/harmon-devkit/compare/v0.13.1...v0.13.2) (2026-07-31)


### Bug Fixes

* require current-head Codex shepherd evidence ([#220](https://github.com/evanharmon1/harmon-devkit/issues/220)) ([b4a13f7](https://github.com/evanharmon1/harmon-devkit/commit/b4a13f72a9328f23447279dbbc920c24e746d49e))

## [0.13.1](https://github.com/evanharmon1/harmon-devkit/compare/v0.13.0...v0.13.1) (2026-07-30)


### Features

* **track-work:** event-driven claim release ([#213](https://github.com/evanharmon1/harmon-devkit/issues/213)) ([c0ff86d](https://github.com/evanharmon1/harmon-devkit/commit/c0ff86d139c0fee50667085f3f8d48423af93421)) — the release cut raced this merge, so the `v0.13.1` tag ships it although the generated notes omitted it


### Bug Fixes

* **close:** release the claim on the merged path too ([#212](https://github.com/evanharmon1/harmon-devkit/issues/212)) ([c0d88e5](https://github.com/evanharmon1/harmon-devkit/commit/c0d88e5d1d5e6a2614027564ffd15d072bfc5646))
* **implement:** make the strong claim-ownership check executable ([#211](https://github.com/evanharmon1/harmon-devkit/issues/211)) ([8eb558d](https://github.com/evanharmon1/harmon-devkit/commit/8eb558dd237f7e4e3c4ac1efca6dadce17602189))

## [0.13.0](https://github.com/evanharmon1/harmon-devkit/compare/v0.12.0...v0.13.0) (2026-07-29)


### ⚠ BREAKING CHANGES

* `/start` and `/reflect` are now `/orient` and `/retro`. Consumer repos pick the rename up on their next skills-sync pin bump; the sync removes managed directories the pin no longer ships, so no manual migration is needed.

### Features

* rename /start to /orient and /reflect to /retro, add /implement ([#196](https://github.com/evanharmon1/harmon-devkit/issues/196)) ([b3211f1](https://github.com/evanharmon1/harmon-devkit/commit/b3211f1557a486bce462157d00d809479a2b6c75))


### Bug Fixes

* **codex-review:** adopt harmon-init v4.8.1's P0/P1/P2 review contract ([#195](https://github.com/evanharmon1/harmon-devkit/issues/195)) ([e1635ea](https://github.com/evanharmon1/harmon-devkit/commit/e1635ea3518bd25e6521a4a740352457719994c6)), closes [#180](https://github.com/evanharmon1/harmon-devkit/issues/180)
* **preflight:** flag Copier-template-managed targets before implementation ([#202](https://github.com/evanharmon1/harmon-devkit/issues/202)) ([0475c29](https://github.com/evanharmon1/harmon-devkit/commit/0475c2980951b9ae39da59ac3870db252576ba28))
* **track-work:** enumerate only the checkboxes GitHub renders as criteria ([#200](https://github.com/evanharmon1/harmon-devkit/issues/200)) ([ecf7bb6](https://github.com/evanharmon1/harmon-devkit/commit/ecf7bb610c6f34fce05dab6b8e40d426d6110295)), closes [#189](https://github.com/evanharmon1/harmon-devkit/issues/189)
* **track-work:** search the target repo for duplicates before filing ([#205](https://github.com/evanharmon1/harmon-devkit/issues/205)) ([7c86fef](https://github.com/evanharmon1/harmon-devkit/commit/7c86fef5d5db7c74724d78df41d26abe1cabde87))

## [0.12.0](https://github.com/evanharmon1/harmon-devkit/compare/v0.11.1...v0.12.0) (2026-07-29)


### Features

* **skills:** claim an issue on the project board when an agent starts work ([#176](https://github.com/evanharmon1/harmon-devkit/issues/176)) ([ece1e3c](https://github.com/evanharmon1/harmon-devkit/commit/ece1e3c45a30a7124b19384921bac77edbd38492))


### Bug Fixes

* **shepherd:** route agents into /shepherd and settle the round cap at 5 ([#184](https://github.com/evanharmon1/harmon-devkit/issues/184)) ([7af47ee](https://github.com/evanharmon1/harmon-devkit/commit/7af47ee9f8ae334c4264467bf760527a134b9266))
* **standardize-repo:** add starter-views and auto-add steps to the post-generation checklist ([#175](https://github.com/evanharmon1/harmon-devkit/issues/175)) ([7236d2f](https://github.com/evanharmon1/harmon-devkit/commit/7236d2fe69de16a1d42a05f46192ae8b258ebde7))
* **standardize-repo:** reconcile live GitHub metadata in update mode ([#177](https://github.com/evanharmon1/harmon-devkit/issues/177)) ([afc6451](https://github.com/evanharmon1/harmon-devkit/commit/afc6451ba83e7823848a54b57be2a8aa54b5c1e0))
* **standardize-repo:** sync the GitHub project-management reference to harmon-init v4.7.0 ([#173](https://github.com/evanharmon1/harmon-devkit/issues/173)) ([10f807e](https://github.com/evanharmon1/harmon-devkit/commit/10f807ec8667ac4051e48184ab994a50fa7880f1))
* **track-work:** tick acceptance criteria as they are verified, not at PR time ([#182](https://github.com/evanharmon1/harmon-devkit/issues/182)) ([5b8788e](https://github.com/evanharmon1/harmon-devkit/commit/5b8788efcecde2182794c2436c029edc0e99129c))

## [0.11.1](https://github.com/evanharmon1/harmon-devkit/compare/v0.11.0...v0.11.1) (2026-07-28)


### Bug Fixes

* **shepherd:** find unanswered comments by reply linkage, not timestamp ([#167](https://github.com/evanharmon1/harmon-devkit/issues/167)) ([555e28a](https://github.com/evanharmon1/harmon-devkit/commit/555e28ac56c1425f701e1e57940e220cfb5cd949))
* **shepherd:** match the head remote on its push URL, not the fetch URL ([#168](https://github.com/evanharmon1/harmon-devkit/issues/168)) ([1687336](https://github.com/evanharmon1/harmon-devkit/commit/168733668ec11e2d6718ae44672141d6b0c2f29b)), closes [#162](https://github.com/evanharmon1/harmon-devkit/issues/162)

## [0.11.0](https://github.com/evanharmon1/harmon-devkit/compare/v0.10.0...v0.11.0) (2026-07-28)


### Features

* **shepherd:** raise the cap to 5 rounds and settle deferred findings ([#164](https://github.com/evanharmon1/harmon-devkit/issues/164)) ([8fac515](https://github.com/evanharmon1/harmon-devkit/commit/8fac51564fb9aaaa3228a0efdf649a1a4515ba74))

## [0.10.0](https://github.com/evanharmon1/harmon-devkit/compare/v0.9.0...v0.10.0) (2026-07-28)


### Features

* add /shepherd skill for driving an open PR to green ([#158](https://github.com/evanharmon1/harmon-devkit/issues/158)) ([29175ba](https://github.com/evanharmon1/harmon-devkit/commit/29175ba1befa6877ff56f9753808ea210d772ecd))
* **track-work:** add the issue/PR tracking-hygiene skill and pre-merge guard ([#159](https://github.com/evanharmon1/harmon-devkit/issues/159)) ([2a28b5b](https://github.com/evanharmon1/harmon-devkit/commit/2a28b5b11f81d2ebb89700e25eb09c122f643ca3))

## [0.9.0](https://github.com/evanharmon1/harmon-devkit/compare/v0.8.7...v0.9.0) (2026-07-27)


### Features

* add dev-workflow session skills and SessionEnd transcript-archive hook template ([#152](https://github.com/evanharmon1/harmon-devkit/issues/152)) ([6a817c8](https://github.com/evanharmon1/harmon-devkit/commit/6a817c8d291536c6bff309fbb540840d6d6fa194))
* **lint-hygiene:** fail a shebanged file that is not executable in git ([#151](https://github.com/evanharmon1/harmon-devkit/issues/151)) ([7187812](https://github.com/evanharmon1/harmon-devkit/commit/7187812064541c51f1f94acf9af6cda973a902ff)), closes [#88](https://github.com/evanharmon1/harmon-devkit/issues/88)
* notify harmon-init when a release is published ([#157](https://github.com/evanharmon1/harmon-devkit/issues/157)) ([5c1c001](https://github.com/evanharmon1/harmon-devkit/commit/5c1c0011493ab4e6289958ae3aeeeb061d7cde4d))


### Bug Fixes

* **implement-design:** correct font/trademark licensing facts and fail closed on unreadable scans ([#146](https://github.com/evanharmon1/harmon-devkit/issues/146)) ([9b8a521](https://github.com/evanharmon1/harmon-devkit/commit/9b8a52157c63f87e8a4ca159b7db67464e5b1b11)), closes [#84](https://github.com/evanharmon1/harmon-devkit/issues/84)
* make copier available in the brew-less devcontainer ([#141](https://github.com/evanharmon1/harmon-devkit/issues/141)) ([7334cd5](https://github.com/evanharmon1/harmon-devkit/commit/7334cd5116b3503fb43ccfa371a7d93cda6aaf79))
* **standardize-repo:** detect required-check trigger wedges and bind the toolchain to the gate job ([#143](https://github.com/evanharmon1/harmon-devkit/issues/143)) ([8228403](https://github.com/evanharmon1/harmon-devkit/commit/8228403cefd3edc5152fd79b22152e253dbabae8))
* **standardize-repo:** persist the peeled Copier commit and scope the gh precondition ([#139](https://github.com/evanharmon1/harmon-devkit/issues/139)) ([1ba94da](https://github.com/evanharmon1/harmon-devkit/commit/1ba94da31afdfb9e8dd95eff9da5d246a17b35f1)), closes [#133](https://github.com/evanharmon1/harmon-devkit/issues/133) [#134](https://github.com/evanharmon1/harmon-devkit/issues/134)
* **standardize-repo:** scope the audit-mode local checkout exemption ([#137](https://github.com/evanharmon1/harmon-devkit/issues/137)) ([9dde60a](https://github.com/evanharmon1/harmon-devkit/commit/9dde60a487712683c18ac738fc7ee5815b7942ee)), closes [#135](https://github.com/evanharmon1/harmon-devkit/issues/135)
* **standardize-repo:** stop reading a Copier template's payload as first-party source ([#147](https://github.com/evanharmon1/harmon-devkit/issues/147)) ([f323856](https://github.com/evanharmon1/harmon-devkit/commit/f323856db3ad1eaa480a1d64c52bd30debd3ed8d))
* **standardize-repo:** sweep orphans against a rendered inventory ([#148](https://github.com/evanharmon1/harmon-devkit/issues/148)) ([095a05e](https://github.com/evanharmon1/harmon-devkit/commit/095a05e98055886520da87e3bef4a6d9f9a97558)), closes [#145](https://github.com/evanharmon1/harmon-devkit/issues/145)

## [0.8.7](https://github.com/evanharmon1/harmon-devkit/compare/v0.8.6...v0.8.7) (2026-07-25)


### Bug Fixes

* **standardize-repo:** freeze Copier update baselines ([#131](https://github.com/evanharmon1/harmon-devkit/issues/131)) ([63d3486](https://github.com/evanharmon1/harmon-devkit/commit/63d34866eeb53094b2f223b2bae009c3fb3d5238))

## [0.8.6](https://github.com/evanharmon1/harmon-devkit/compare/v0.8.5...v0.8.6) (2026-07-24)


### Bug Fixes

* **standardize-repo:** freeze verified Copier commits ([#129](https://github.com/evanharmon1/harmon-devkit/issues/129)) ([fc983e9](https://github.com/evanharmon1/harmon-devkit/commit/fc983e9be7cc1b59a521e4f57adb4500334e9113))
* **standardize-repo:** make CodeRabbit opt-in ([#128](https://github.com/evanharmon1/harmon-devkit/issues/128)) ([81aa43a](https://github.com/evanharmon1/harmon-devkit/commit/81aa43ad360148060e5528a0d01694e8119eaf0f))

## [0.8.5](https://github.com/evanharmon1/harmon-devkit/compare/v0.8.4...v0.8.5) (2026-07-23)


### Bug Fixes

* update to harmon-init v4.4.0 ([#125](https://github.com/evanharmon1/harmon-devkit/issues/125)) ([792e1a9](https://github.com/evanharmon1/harmon-devkit/commit/792e1a9240fa1836f6c555234f4e8419e3b5f0f9))

## [0.8.4](https://github.com/evanharmon1/harmon-devkit/compare/v0.8.3...v0.8.4) (2026-07-22)


### Bug Fixes

* **standardize-repo:** document script-inventory diff step + unrelated-hunk pairing ([#121](https://github.com/evanharmon1/harmon-devkit/issues/121)) ([014ff1a](https://github.com/evanharmon1/harmon-devkit/commit/014ff1a2293ccac11c780d03f153a5ddb27197be))
* **standardize-repo:** teach verify-applied split-workflow CI layouts ([#122](https://github.com/evanharmon1/harmon-devkit/issues/122)) ([4d9e2c2](https://github.com/evanharmon1/harmon-devkit/commit/4d9e2c2cc8530e81717762a7d529ae3237c58408))

## [0.8.3](https://github.com/evanharmon1/harmon-devkit/compare/v0.8.2...v0.8.3) (2026-07-22)


### Bug Fixes

* update to harmon-init v4.3.0 (adds Codex second-model review) ([#116](https://github.com/evanharmon1/harmon-devkit/issues/116)) ([2c37404](https://github.com/evanharmon1/harmon-devkit/commit/2c3740474fa3a08c38b8d98e92060abd47d56acb))

## [0.8.2](https://github.com/evanharmon1/harmon-devkit/compare/v0.8.1...v0.8.2) (2026-07-20)


### Bug Fixes

* align standardize-repo with explicit CodeQL intent ([#104](https://github.com/evanharmon1/harmon-devkit/issues/104)) ([a0e063a](https://github.com/evanharmon1/harmon-devkit/commit/a0e063aa2e0757ee7744a1d92b8c434214a28eff))
* **standardize-repo:** add focused update safeguards ([#112](https://github.com/evanharmon1/harmon-devkit/issues/112)) ([9f6a2d1](https://github.com/evanharmon1/harmon-devkit/commit/9f6a2d14d8b67bb2dc5125eace8c978abe0394f8))

## [0.8.1](https://github.com/evanharmon1/harmon-devkit/compare/v0.8.0...v0.8.1) (2026-07-19)


### Bug Fixes

* **skills:** call them design handoff bundles, not implement-design bundles ([#109](https://github.com/evanharmon1/harmon-devkit/issues/109)) ([bd667b5](https://github.com/evanharmon1/harmon-devkit/commit/bd667b5cbb3f76abbd34edab0698aa3ed4b112b6))

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
