# Architecture

How the system is built, secured, governed, and tested — plus the **subject
hubs** below.

TODO: Describe the high-level architecture of Harmon DevKit.

## Overview

TODO: Add a Mermaid diagram of the main components and data flow. Keep this
diagram in sync with reality — PRs that change components, routing, or
infrastructure should update it.

```mermaid
flowchart LR
    A[TODO: source] --> B[TODO: build] --> C[TODO: deploy]
```

## Components

TODO: List the major components and what each is responsible for.

## Data Flow

TODO: Describe how data moves through the system.

## Subject hubs

Each synthesizes what's scattered across config, settings, and state, then routes
onward (diagrams and component deep-dives also live here):

- [ci-cd.md](ci-cd.md) — the pipeline across YAML, runners, and deploy platforms; routes to the release decision and the deploy guide.
- [security.md](security.md) — the posture across config, secret state, and GitHub settings; holds the threat-model framing, not the config.
- [branch-protection.md](branch-protection.md) — in-repo (CODEOWNERS) + out-of-repo (ruleset, Actions toggles, bot model) stitched into one picture (grep can't see GitHub settings).
- [tests.md](tests.md) — the testing strategy holistically (shape, layers, what's tested where); routes to the testing decision and the guides.
