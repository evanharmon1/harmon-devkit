# Deploying

How to deploy Harmon DevKit. For the shape of the CI/CD pipeline see
[../architecture/ci-cd.md](../architecture/ci-cd.md); for production operational
procedures and rollback runbooks see [../runbooks/](../runbooks/).

> TODO: no deployment is configured yet — fill in the sections below.

## Environments

TODO: list the environments (e.g. preview, staging, production) and where each
one lives.

## How to deploy

TODO: the steps or command to ship a change. Prefer a `task deploy` (or
`deploy:<target>`) task so it stays the single source of truth.

## Rollback

TODO: how to roll back a bad deploy. Capture the production procedure as a
runbook in [../runbooks/](../runbooks/).

## Configuration & secrets

TODO: deploy-time configuration and where secrets come from (1Password / CI
secrets — see [../architecture/security.md](../architecture/security.md)).
