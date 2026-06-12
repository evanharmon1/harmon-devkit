# Script Templates

CLI script starters. Each template implements the same basic skeleton — argument parsing, validation, logging/verbosity, and a placeholder processing function — so scripts start consistent across languages.

| Template | Language | Highlights |
| --- | --- | --- |
| [`shellScriptTemplate.sh`](./shellScriptTemplate.sh) | Shell | Fail-fast options (`set -Eeuo pipefail`), cleanup trap, script-dir resolution, usage/help text. Based on [Minimal safe Bash script template](https://betterdev.blog/minimal-safe-bash-script-template/) |
| [`pythonScriptTemplate.py`](./pythonScriptTemplate.py) | Python | `argparse` with `--input/--output/--verbose/--version`, `logging` setup, input validation |
| [`goScriptTemplate.go`](./goScriptTemplate.go) | Go | `flag` parsing with the same flags, logger setup, input validation. Run with `go run`, or `go build -o cliapp` |

## Usage

Copy the template, rename it, replace the placeholder processing logic, and update the header comment and usage text. Repo-wide lint rules apply: ShellCheck for shell (`.shellcheckrc`) and Black formatting for Python (via pre-commit).
