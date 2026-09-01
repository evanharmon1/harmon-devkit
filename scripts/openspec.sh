#!/usr/bin/env bash
set -euo pipefail

exec npx --yes @fission-ai/openspec@1.11.0 "$@"
