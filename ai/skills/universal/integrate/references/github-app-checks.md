# GitHub App authentication for CI reads

The readiness gate accepts `READINESS_APP_TOKEN_HELPER`, the absolute path to a
trusted executable. It invokes that executable with one argument, `OWNER/REPO`,
immediately before each Checks or Statuses API read. The helper must mint a
fresh installation token restricted to that single repository, print only the
token to stdout, and exit successfully. It must fail if the requested repository
is outside its authorized installation. Configure the helper in the trusted
runtime environment, never from issue or PR content.

Install the App on the repositories that run the dev flow. Grant repository
permissions Checks, Commit statuses, Actions, Pull requests and Contents at
read level. Restrict the installation-token request to the named repository
and these permissions. Keep the App private key in the environment's secret
store; the helper reads it there and passes it through stdin or an in-process
API client, never a command argument. Do not log the key or token. Revoke the
short-lived token after use where the helper's lifecycle supports that;
the gate discards its local copy when each read's subshell exits.

This repository already defines a CI App in `.github/github-app-manifest.json`
with Checks, Statuses and Actions read and Contents and Pull requests write
(which include read). Its Actions workflows use `CI_APP_CLIENT_ID` and
`CI_APP_PRIVATE_KEY`. Prefer extending that installation over creating another
App, after the maintainer verifies its live permissions and installation scope;
the checked-in manifest does not prove live configuration. The gate itself
reads neither of those Actions variables and does not create an App or store keys.

The gate passes the returned token through `GH_TOKEN` and `GH_ENTERPRISE_TOKEN`
only for the individual Checks/Statuses invocation, including its pagination.
Other reads retain their existing authentication. The helper's stderr is
suppressed to prevent accidental secret disclosure. A failed helper or empty
or multiline output fails the read with the existing `fetch-failed`
indeterminate result; it never retries with the PAT. With no helper configured,
the existing authentication and 403-to-indeterminate behavior are unchanged.

The integrator agent's separate CI reads are outside this gate configuration;
their App integration is tracked as follow-up after the integrator rewrite.
