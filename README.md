# Harmon DevKit

My personal developer kit: reusable code templates and boilerplates for various stacks (Docker Compose, Ansible, shell scripts, serverless functions, etc.), standalone scripts, and AI assets (skills, prompts, agents). Also a general home for code that doesn't really fit anywhere else.

Author: Evan Harmon

[![Build & Validate](https://github.com/evanharmon1/harmon-devkit/actions/workflows/build.yml/badge.svg)](https://github.com/evanharmon1/harmon-devkit/actions/workflows/build.yml)
[![Devcontainer Build](https://github.com/evanharmon1/harmon-devkit/actions/workflows/devcontainer-build.yml/badge.svg)](https://github.com/evanharmon1/harmon-devkit/actions/workflows/devcontainer-build.yml)
[![Open in Dev Containers](https://img.shields.io/static/v1?label=Dev%20Containers&message=Open&color=blue&logo=visualstudiocode)](https://vscode.dev/redirect?url=vscode://ms-vscode-remote.remote-containers/cloneInVolume?url=https://github.com/evanharmon1/harmon-devkit)
[![Latest Release](https://img.shields.io/github/v/release/evanharmon1/harmon-devkit?sort=semver)](https://github.com/evanharmon1/harmon-devkit/releases)
[![Renovate](https://img.shields.io/badge/maintained%20with-renovate-blue?logo=renovatebot)](https://github.com/apps/renovate)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](./LICENSE)
[![Copier](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/copier-org/copier/master/img/badge/badge-grayscale-inverted-border-orange.json)](https://github.com/copier-org/copier)
[![Maintained](https://img.shields.io/badge/maintained%3F-yes-brightgreen.svg?style=flat-square)](https://github.com/evanharmon1/harmon-devkit)
[![Contributions Welcome](https://img.shields.io/badge/contributions-welcome-brightgreen.svg?style=flat-square)](https://github.com/evanharmon1/harmon-devkit)

## Part of harmon-platform

This repo is part of **harmon-platform** — my custom development platform with machine configuration, DevOps systems, homelab infrastructure, and automation repos that work together to help me develop software and manage my homelab.

| Repo | What it is |
| --- | --- |
| [harmon-init](https://github.com/evanharmon1/harmon-init) | Copier template that bootstraps & standardizes new repos (CI/CD, devcontainers, AI steering, tooling). |
| [**harmon-devkit**](https://github.com/evanharmon1/harmon-devkit) **(this repo)** | Reusable boilerplates & code templates, standalone scripts, and AI assets (skills, prompts, agents). |
| [harmon-dotfiles](https://github.com/evanharmon1/harmon-dotfiles) | Shell & app dotfiles, managed declaratively with chezmoi. |
| [harmon-ops](https://github.com/evanharmon1/harmon-ops) | Personal machine bootstrapping, package management & dev-environment setup across macOS/Windows/Linux. |
| [harmon-infra](https://github.com/harmonops/harmon-infra) | Homelab infrastructure as code — Terraform, Ansible, and Docker Compose services. |

## Repository Structure

| Directory                    | Contents                                                                                              |
| ---------------------------- | ----------------------------------------------------------------------------------------------------- |
| [`templates/`](./templates/) | Copy-paste boilerplates organized by category — see the [template index](#template-index) below       |
| [`scripts/`](./scripts/)     | Standalone scripts and utilities (AppleScript/Automator apps, command snippets)                       |
| [`ai/`](./ai/)               | AI assets — skills, prompts, agents, rules, evals, etc. — see the [AI assets index](#ai-assets) below |
| [`snippets/`](./snippets/)   | Small reusable code snippets (work in progress)                                                       |
| [`docs/`](./docs/)           | Project docs, e.g. the harmon-init [post-generation checklist](./docs/CHECKLIST.md)                   |

## Template Index

| Template                                                                                                       | Category   | Description                                                                                                                        |
| -------------------------------------------------------------------------------------------------------------- | ---------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| [`ansible.md`](./templates/ansible.md)                                                                         | Ansible    | Standard Ansible project directory structure and setup notes                                                                       |
| [`docker/genericStack`](./templates/docker/genericStack/)                                                      | Docker     | Generic multi-service Compose sandbox (Ubuntu, nginx, optional DB stack with Postgres/memcached/Adminer) plus `dc*` helper scripts |
| [`docker/n8n-compose`](./templates/docker/n8n-compose/)                                                        | Docker     | n8n workflow automation behind Traefik with automatic HTTPS (Let's Encrypt)                                                        |
| [`scriptTemplates/shellScriptTemplate.sh`](./templates/scriptTemplates/shellScriptTemplate.sh)                 | Scripts    | Shell script starter with safe defaults, traps, and arg parsing                                                                    |
| [`scriptTemplates/pythonScriptTemplate.py`](./templates/scriptTemplates/pythonScriptTemplate.py)               | Scripts    | Python CLI starter with argparse, logging, and validation                                                                          |
| [`scriptTemplates/goScriptTemplate.go`](./templates/scriptTemplates/goScriptTemplate.go)                       | Scripts    | Go CLI starter with flag parsing, logging, and validation                                                                          |
| [`serverlessFunctionTemplates/awsLambda.py`](./templates/serverlessFunctionTemplates/awsLambda.py)             | Serverless | AWS Lambda handler (Python) with input validation and error responses                                                              |
| [`serverlessFunctionTemplates/gcpFunction.py`](./templates/serverlessFunctionTemplates/gcpFunction.py)         | Serverless | Google Cloud Function (Python/Flask) with input validation and error responses                                                     |
| [`serverlessFunctionTemplates/netlifyFunction.js`](./templates/serverlessFunctionTemplates/netlifyFunction.js) | Serverless | Netlify Function (Node.js) that fetches and returns JSON from an API                                                               |
| [`webTemplates/netlifyForm.html`](./templates/webTemplates/netlifyForm.html)                                   | Web        | Netlify-ready HTML contact form with honeypot spam protection                                                                      |
| [`skills-sync`](./templates/skills-sync/)                                                                      | AI         | Pinned, pull-based vendoring of shared agent skills from harmon-devkit into a consumer repo — manifest-driven, category-selective (`task sync:skills` + CI drift check) |

See [`templates/README.md`](./templates/README.md) for conventions and per-category details.

## AI Assets

`ai/` collects reusable AI assets organized by type — `skills/`, `prompts/`, `agents/`, `rules/`, `evals/`, `tools/`, `workflows/`, `mcp/`, `knowledge/`, and `memories/`. Most are placeholders for now; the populated area is **skills**, which follow the Agent Skills convention (a `SKILL.md` with `name`/`description` frontmatter).

Skills are grouped into **category subdirectories** (`universal/`, `backend/`, `frontend/`, `infra/`, `mobile/`, `repo/`) so consumer repos can vendor a selected subset via the [`skills-sync`](./templates/skills-sync/) template. Skill directory names must be **unique across categories** (they are flattened on vendor) — [`ai/skills/README.md`](./ai/skills/README.md) documents the layout, the constraint, and how to add a skill.

| Skill                                                                         | Status      | Description                                                                                                                                                                                              |
| ----------------------------------------------------------------------------- | ----------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`frontend/explore-designs`](./ai/skills/frontend/explore-designs/)           | Draft       | Guides using Claude Design to explore design directions across your frontend stack                                                                                                                       |
| [`frontend/create-design-system`](./ai/skills/frontend/create-design-system/) | Placeholder | Design-system setup                                                                                                                                                                                      |
| [`frontend/design-handoff`](./ai/skills/frontend/design-handoff/)             | Ready       | Implements a Claude Design `.tar.gz` handoff into a real codebase — reconcile an existing design system or bootstrap a new one (tokens → shadcn/Tailwind v4 OKLCH, `/brand`, contrast + licensing gates) |
| [`repo/standardize-repo`](./ai/skills/repo/standardize-repo/)                 | Ready       | Applies the [harmon-init](https://github.com/evanharmon1/harmon-init) Copier template's conventions to a repo — scaffold a new repo, adopt the template into an existing one, or audit drift from the standards. Bundles the authoritative repo-conventions catalog.       |

## Inspired by Other Boilerplate Repos

- <https://github.com/ChristianLempa/boilerplates>
- <https://github.com/docker/awesome-compose>
- <https://github.com/Haxxnet/Compose-Examples>
- <https://awesome-docker-compose.com/>
- <https://github.com/gruntwork-io/boilerplate>
- <https://github.com/EinGuterWaran/awesome-opensource-boilerplates>
- <https://github.com/melvin0008/awesome-projects-boilerplates>
- <https://boilerplatelist.com/collection/>

## Setup & Installation

If there isn't an existing template in this repo, start with looking at the <https://github.com/ChristianLempa/boilerplates> repo for an existing boilerplate there. There is a cli tool to use boilerplates from that repo and you can integrate other repos.

### Requirements

- Homebrew (installs the toolchain via `Brewfile`)
- [Taskfile](https://taskfile.dev/) (task runner)
- Node (for npx-based tools: markdownlint-cli2, commitlint)
- [uv](https://docs.astral.sh/uv/) (runs the pinned Semgrep CE baseline)

### Bootstrap

Install required software to run other project installers and task runners
`task bootstrap`

### Install

Install required dependencies
`task install`

## Usage

Templates are meant to be copied into your project and adapted — there is no scaffolding CLI (yet). Browse the [template index](#template-index), copy the file or directory you need, and edit the placeholders (names, ports, environment variables) for your project. Each template directory has a README with specifics.

### Task Runner

[Taskfile.yml](./Taskfile.yml)

### Verify

`task check` runs the fast lint gate. `task verify` is the definition-of-done
gate (check + validation + Taskfile/hook/skills guards + tests); `task ci` adds
security.

#### Security

`task security` — Semgrep CE SAST + gitleaks secret scan + dependency audit.

#### Linting, formatting & conventions

Git hooks (managed by [lefthook](https://lefthook.dev/), `lefthook.yml`) and CI
delegate to the same Taskfile targets. Config lives in `.editorconfig`,
`.shellcheckrc`, `.yamllint`, `.markdownlint.json`, `commitlint.config.mjs`, and
`.gitleaks.toml`.
