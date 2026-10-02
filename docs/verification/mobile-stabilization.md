# Mobile stabilization — reproducible verification (plan F1)

Applies to branch `personal/michael-stabilization` and its workflow
`.github/workflows/personal-verification.yml` ("Personal verification").

## What the workflow does

Two **required** lanes (a green run means both passed):

1. `unit-and-build` — hosted `macos-15`, exact HermesKit suite and an unsigned
   Debug app build for the pushed commit. The one genuinely environment-dependent
   test (`RESTTransportSuite/KeychainClientTests/liveKeychainRoundTripsBearerSession`)
   is skipped **explicitly and solely** there, and must instead pass in lane 2.
2. `keychain-live-environment` — labeled *environment*: runs the full
   `KeychainClientTests` suite, including the live Keychain test, and asserts the
   live test actually ran and passed before the lane can be green.

Path filters (`HermesKit/**`, `HermesMobile/**`, tests, `Project.swift`, docs,
the workflow itself) and `concurrency.cancel-in-progress` keep fork CI costs
proportionate. Superseded runs on the same branch are cancelled.

## The headless Keychain gate, resolved honestly

`liveKeychainRoundTripsBearerSession` exercises `KeychainClient.live` (a real
keychain generic-password round trip). On a locked headless session it fails
with `errSecUserLoginRequired` (-25308); this was reproduced on the clean
candidate baseline (Mac log `/tmp/hms-baseline-test.log`, suite failure summary
"4 issues (including 3 known issues)"). It is **not** skipped silently anywhere:

- Lane 1 names it in the `--skip` list and prints the exact skip in the step
  summary;
- A required, separately-named environment lane runs it and fails the whole run
  if it does not run or does not pass (anti-silent-filter guard verifies it
  appears with ✔ in the log).

No broad catch-and-pass; no aggregate badge over an omitted lane.

## Hosted runner / toolchain discovery (2026-10-02, updated after run 36985304649)

- Prior fork verification lanes ran on `macos-15` + Xcode 26.3 (run
  35250366395 success); that pin was then rotated out and 26.6 was briefly
  believed default, but the first Personal-verification run proved the live
  image ships only up to Xcode **26.3** (Xcode_26.3.app is the newest
  _26.x.app in /Applications; 26.6/26.4 are absent).
- The workflow therefore pins **26.3** with a fail-loud selection step; the
  local Mac Air keeps Xcode 26.6 / Build 17F113, so parity is "Xcode 26.x on
  both hosts, exact versions recorded in each manifest". Re-discover before
  every integration freeze and re-pin only to a documented image.

## Reproduce locally (clean checkout → dependencies → tests/build)

From a fresh checkout of `netera-michael/hermes-mobile` on branch
`personal/michael-stabilization`, on macOS with Xcode 26.x:

```sh
xcode-select -s /Applications/Xcode_26.app/Contents/Developer   # or sudo;
tuist install                     # dependency resolution (pinned Package.resolved)
tuist generate --no-open          # regenerate workspace/project from Project.swift

# Lane 1: suite + unsigned build
swift test --package-path HermesKit \
  --skip liveKeychainRoundTripsBearerSession
xcodebuild build \
  -workspace HermesMobile.xcworkspace -scheme HermesMobile \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -skipMacroValidation CODE_SIGNING_ALLOWED=NO

# Lane 2: environment-dependent Keychain gate (needs an unlocked login keychain,
# i.e. a GUI session or `security unlock-keychain` on the host)
swift test --package-path HermesKit \
  --filter RESTTransportSuite/KeychainClientTests
```

## Artifacts retained per run

Each lane uploads (zip artifact): verification manifest (run/commit/ref/OS),
xcode + Swift versions, Tuist version, dependency-resolution and generate logs,
`HermesKit/Package.resolved` dump, full test log, suite summary, full app-build
log. Lane 2 adds the Keychain suite log and the resolve log.

Native probes (local Mac Air) run on the same candidate commit; baseline
environmental failures (the -25308 class) are classified separately in
`evidence/status.md`, never folded into regression counts.