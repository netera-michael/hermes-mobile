#!/usr/bin/env bash
# Explicit personal-build upload; never run automatically in upstream/unsigned CI.
# Disable shell tracing before touching credentials, even if invoked with bash -x.
set +x
set -euo pipefail
: "${SENTRY_AUTH_TOKEN:?Set a symbol-upload token in the environment (never in Git)}"
: "${SENTRY_ORG:?Set the personal Sentry organization}"
: "${SENTRY_PROJECT:?Set the personal Sentry project}"
if [[ $# != 1 || ! -d "$1" ]]; then
  printf 'Usage: %s <archive/dSYMs or build products directory>\n' "$0" >&2
  exit 2
fi
command -v sentry-cli >/dev/null || { printf 'Install sentry-cli first.\n' >&2; exit 2; }
# Do not upload source bundles: they can contain private configuration/code.
sentry-cli debug-files upload --type dsym --wait "$1"
