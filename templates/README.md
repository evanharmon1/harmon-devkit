# Templates

Copy-paste boilerplates organized by category. Templates are meant to be copied into your project and adapted — copy the file or directory you need and edit the placeholders (names, ports, environment variables) for your project.

The full template index lives in the [root README](../README.md#template-index).

## Categories

| Directory | Contents |
| --- | --- |
| [`ansible.md`](./ansible.md) | Standard Ansible project directory structure and setup notes (work in progress) |
| [`docker/`](./docker/) | Docker Compose stacks |
| [`scriptTemplates/`](./scriptTemplates/) | CLI script starters for Shell, Python, and Go |
| [`serverlessFunctionTemplates/`](./serverlessFunctionTemplates/) | Serverless function handlers for AWS Lambda, Google Cloud Functions, and Netlify Functions |
| [`webTemplates/`](./webTemplates/) | Web/HTML snippets |

## Conventions

- Each category directory has a README describing its templates and any required setup (e.g. `.env` files).
- Templates carry a header comment with a description and usage notes where the format allows it.
- Linting/formatting for templates follows the repo-wide config (`.editorconfig`, `.pre-commit-config.yaml`) — see the root README.
