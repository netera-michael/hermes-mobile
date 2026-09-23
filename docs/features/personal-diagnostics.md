# Personal Sentry diagnostics (fork only)

Default: **off**. Without a valid HTTPS `TUIST_SENTRY_DSN` at Tuist generation,
`PersonalDiagnostics.start` returns a no-op and never starts Sentry. Keep this
change on `personal/*`, not an upstream PR. The DSN is a public ingestion key;
Sentry auth/upload tokens must never enter the app, Info.plist, or Git.

## Collection contract

The HermesKit dependency accepts only `DiagnosticSignal`, a closed enum. Chat
text, model/provider names, server URLs, profile/session IDs, tokens and raw
error descriptions cannot be supplied to it. Lifecycle breadcrumbs are local
to the SDK until a permitted failure/crash is submitted. Nonfatal failures are
limited to ten per process launch and one per category per minute. Model selection
records the selection action, not a confirmed server change; gateway error events
are classified broadly, not asserted to be transport-only failures.

Sentry Cocoa is pinned to 8.56.2. Automatic breadcrumbs, network capture/tracing,
performance tracing, session tracking, MetricKit, screenshots, view hierarchies,
replay and PII are disabled. `beforeSend` removes users, requests, contexts,
extras, tags, dynamic exception reasons, frame source context/locals, registers
and paths. Native addresses and image UUIDs remain for symbolication. SDK/release
metadata and event timestamps are still sent to Sentry. This is not chat logging.

## Enable and disable

Provide `TUIST_SENTRY_DSN` privately to `tuist generate --no-open` or
`make run-device`. No DSN value belongs in tracked scripts. Regenerate and rebuild
without that variable to disable. Do not regenerate a workspace open in Xcode.
The standard Apple signing rules still apply; telemetry does not change them.

## Symbols

The app emits dSYMs in Debug and Release. After building, use:

```sh
SENTRY_ORG=synvora SENTRY_PROJECT=hermes-mobile \
  bash scripts/upload-sentry-symbols.sh /path/to/archive.xcarchive/dSYMs
```

Supply `SENTRY_AUTH_TOKEN` separately through a secret manager/environment and
install `sentry-cli` first. The script disables shell tracing before reading
credentials, restricts uploads to dSYMs, and waits for processing. It does not
upload source bundles. Verify the app dSYM UUID with `dwarfdump --uuid` and
read the corresponding debug file back from Sentry before claiming symbolication
coverage. Re-upload for every new binary; a previous build's symbols do not count.

## Verification

- `swift test --package-path HermesKit --filter DiagnosticsTests`
- Unsigned simulator app build verifies Sentry API compatibility.
- Launch that configured **Debug simulator app** with `--sentry-smoke-test`.
  This sends one non-crashing, fixed `smokeTest` event via the real app SDK; the
  argument is ignored on phones and in Release builds.
- Read the exact event back from the project's API, check SDK/release and payload
  fields, and confirm no user/request/content/URL/auth data was included.
- This smoke event does not prove a physical-device crash or stack symbolication.
  Device installation and symbol upload are separate acceptance checks.

The simulator proof event and uploaded dSYMs are build-specific. The currently
installed iPhone build is not assumed to include this integration; generating
without a DSN leaves it disabled. Do not mistake a successful simulator event
for device telemetry or a successful app installation.
