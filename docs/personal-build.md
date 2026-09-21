# Personal device build (fork-only, free Apple ID friendly)

Run YOUR fork on YOUR iPhone with YOUR Apple ID — no paid developer account,
no waiting for the author's TestFlight builds. MIT-licensed (© Eugene Honcharenko).

## One-time setup on the Mac (full Xcode required — CLT alone has no `xcodebuild`)

```sh
# 1. Install Xcode from the App Store (~15 GB), open it once, accept the license.
# 2. Xcode → Settings → Accounts → "+" → add your Apple ID.
#    Your Personal Team id appears under the team name (10 chars, e.g. A1B2C3D4E5).
brew install tuist
git clone https://github.com/netera-michael/hermes-mobile.git
cd hermes-mobile && git checkout setup/personal-device-build
```

## Run on the iPhone (USB first time, WiFi after)

```sh
# Plug iPhone in via USB, Trust This Computer (both directions).
# Free Apple ID: unique bundle id + strip push (no Push capability on free teams).
DEVELOPMENT_TEAM=<team-id> \
  HERMES_BUNDLE_ID=com.<you>.HermesDev \
  HERMES_NO_PUSH=1 \
  HERMES_DEFAULT_SERVER_URL=http://100.81.155.70:9119 \
  make run-device
# On the phone: Settings → General → VPN & Device Management → trust your Apple ID.
```

Paid account (push works): same command WITHOUT `HERMES_NO_PUSH=1`:

```sh
DEVELOPMENT_TEAM=<team-id> \
  HERMES_BUNDLE_ID=com.<you>.HermesDev \
  HERMES_DEFAULT_SERVER_URL=http://100.81.155.70:9119 \
  make run-device
```

## What the env vars do

| Var | Translated to | Effect |
|---|---|---|
| `DEVELOPMENT_TEAM` | `TUIST_DEVELOPMENT_TEAM` | signs with your team (auto provisioning) |
| `HERMES_BUNDLE_ID` | `TUIST_BUNDLE_ID` | your build coexists with the author's TestFlight install (same id + different team = refused update) |
| `HERMES_NO_PUSH=1` | `TUIST_NO_PUSH` | drops the `aps-environment` entitlement (free IDs can't sign it). Push toggles hide; chat works |
| `HERMES_DEFAULT_SERVER_URL` | `TUIST_SERVER_URL` | bakes the Debug server preset (else enter it in onboarding) |
| `HERMES_TESTS_BUNDLE_ID` | `TUIST_TESTS_BUNDLE_ID` | rarely needed; defaults to `<app id>Tests` |

Unset = upstream behavior. A plain `tuist generate` / simulator `make run` builds the
author's bundle id with push intact — upstream PRs stay clean of this file entirely.

## Limits of free signing

- App stops launching after **7 days** → re-run `make run-device` (~2 min, same WiFi ok).
- Max **3 sideloaded apps** per Apple ID; one device refresh at a time.
- **No push notifications** (needs APNs + paid team): foreground chat works, but
  closed-app approval pings don't arrive. That's the $99 reason.
- Wireless debugging (Xcode → Window → Devices → connect via network) removes the cable
  after first pairing — Mac + iPhone on same WiFi still required for re-sign.

## When you're ready for TestFlight/App Store ($99/yr)

Same Apple ID covers unlimited apps. Then: register `com.<you>.HermesDev` as a new App
Store Connect record with a distinct name/icon (never ship under the author's app name
while his listing is live — Apple 4.3 copycat risk), add the distribution cert +
profile as fork CI secrets, and wire archive → export → upload (the `asc` flow in
`docs/development.md` → TestFlight distribution). Ask Hermes to scaffold it then.
