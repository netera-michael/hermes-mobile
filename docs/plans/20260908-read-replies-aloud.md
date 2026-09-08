# Read replies aloud — TTS playback of agent replies (issue #74)

## Overview

Voice on mobile is input-only today (mic → `POST /api/audio/transcribe`). Reddit feedback
(and a second request since) asks for the desktop's **"Read replies aloud"**: an auto-speak
toggle that reads every completed assistant reply, plus a per-message **Read aloud** action.
This is also the backbone for the later voice-conversation ticket.

This plan ships the desktop feature with parity wherever the phone allows it:

- **One source of truth for the toggle: the server's `voice.auto_tts`** (read via
  `GET /api/config`, written via `PUT /api/config`), exactly like the desktop. Accepted
  consequence (same as desktop): the gateway's messaging platforms use the same key as their
  voice-reply default, so flipping it on the phone flips it there too.
- **Synthesis = `POST /api/audio/speak` only** (rung 3 of the desktop ladder). The PCM
  `speak-stream` socket lands with the voice-conversation ticket; the client-direct rung
  (provider API keys shipped to the phone) is skipped on purpose.
- **Playback = one app-wide `AVAudioPlayer` clip**, `.playback` category (plays through the
  silent switch — the user explicitly asked for spoken content), **stops on backgrounding**
  (no background-audio entitlement), 15 s stall watchdog, "Reading aloud" pill with Stop,
  new submit silences playback and attaches `interrupted: true`.
- **Keep the screen awake** (`UIApplication.isIdleTimerDisabled`) during the hands-off loop:
  while a clip is preparing/playing, while a turn runs with auto-speak on, or while the mic
  records — but only while the chat is on screen.
- **Capability-gated by failure** (TTS is not advertised in `/api/status`): the first 404
  from `speak` flips `ttsSupported` off and hides both controls; a 400 carries the server's
  human-readable detail ("no TTS provider configured", …) into the error banner.

Out of scope (decided in the brainstorm, YAGNI): `speak-stream` WS, client-direct
synthesis, `tts-lease` warm-up (swallowed fire-and-forget on desktop; only matters for
local engines), a Settings → Voice mirror of the toggle, a playback waveform in the pill,
`source: voiceConversation` on the playback state, lock-screen controls / background audio.

## Context (from discovery)

Verified against upstream Hermes `upstream/main` @ `22c5684b98` (2026-09-07) — read via
`git -C /Users/eugene/Documents/Development/Personal/hermes-agent show upstream/main:<path>`.

**Server (`hermes_cli/web_routers/audio.py`, models in `hermes_cli/web_models.py`):**
- `POST /api/audio/speak?profile=` body `{"text"}` → `{ok: true, data_url:
  "data:<mime>;base64,…", mime_type, provider}`. Mime by generated extension: `.mp3`
  → `audio/mpeg` (default), `.ogg`/`.opus` → `audio/ogg`, `.wav` → `audio/wav`, `.flac` →
  `audio/flac`. Errors: **400** empty text / bad profile / provider failed-or-missing
  (`detail` = provider error text), **404** unknown profile (and, on older agents, the
  route itself), **500** synthesis raised. No 503. Blocking; desktop timeout
  `max(180 s, 35 ms × chars)` capped at 600 s (`apps/desktop/src/api/system.ts:18-28`).
- `GET /api/config` (`hermes_cli/web_routers/config_env.py:77`) → whole normalized config;
  `voice.auto_tts` is a bool (default `false`, `config_defaults.py` ~1119).
  `PUT /api/config` (`:110`) body `{config: {...}, profile?}` **deep-merges** over the
  on-disk config → `{ok: true}`; a partial `{voice: {auto_tts}}` body is therefore safe
  and equivalent to the desktop's whole-record read-modify-write.
- Auth: same `RequestAuth` as every other REST call (token header / cookie / bearer).

**Desktop rules ported (`apps/desktop/src/…`):**
- `app/chat/composer/hooks/use-auto-speak-replies.ts` — only completed replies; mark the
  current last reply spoken on toggle-on and on chat open; never overlap (wait for the idle
  edge); backlog collapses to the newest; never while a voice conversation is active.
- `lib/spoken-reply.ts` — spoken state keyed on the **assistant ordinal**, not the row id
  (the streaming→history id rewrite must not re-speak). Mobile's deterministic row ids
  make this a plain "assistant rows consumed" counter.
- `lib/speech-text.ts` `sanitizeTextForSpeech` — 12-step pipeline (Task 1 lists it).
- `lib/voice-playback.ts` — single clip, stop bumps a sequence, 15 s `timeupdate` stall
  watchdog, `markVoicePlaybackInterrupted` / `takeVoicePlaybackInterrupted` latch with a
  **120 s TTL** consumed by `prompt.submit` (`use-prompt-actions/submit.ts`).
- `components/assistant-ui/thread/assistant-message.tsx:684` `ReadAloudButton` —
  disabled while preparing or while any other playback is active; labels "Read aloud" /
  "Preparing audio..." / "Stop reading" / "Read aloud failed".
- `app/chat/composer/voice-activity.tsx` `VoicePlaybackActivity` — pill above the composer,
  "Preparing audio" / "Reading aloud", Stop button, `aria-live="polite"`.
- `app/chat/composer/voice-menu.tsx` + `controls.tsx:326` — toggle labels "Read replies
  aloud" / "Stop reading replies aloud"; trigger lit while on.
- `store/voice-prefs.ts` — optimistic flip, GET+PUT, revert on failure.
- No focus gating on desktop (speaks unfocused); playback survives a chat switch there.
  On mobile leaving the chat tears the slot down, so playback stops — accepted.

**Mobile mount points (verified):**
- `HermesKit/Sources/HermesKit/Clients/AudioRecorderClient.swift` — the live-actor +
  `#if canImport(UIKit)` pattern to mirror; `.playAndRecord` session for the mic.
- `HermesKit/Sources/HermesKit/Clients/HermesRESTClient.swift` — `transcribe` (~:417) is the
  `postJSON` pattern; `deleteSession` (~:405) the profile-query pattern (`nil` → no query;
  callers pass `nil` for `"default"`); `validate` maps 404 → `RESTError.notFound`, other
  statuses → `.server(status:detail:)` with the server `detail`.
- `HermesKit/Sources/HermesKit/Features/ChatFeature.swift` — `.task` (~:995, first
  appearance connect), `.viewDisappeared`/`.teardown`/`.teardownSocketOnly` (~:1005-1030),
  `.foreground, .reattached` shared handler (~:1220), `.messageComplete` fold (~:2242),
  `releaseVoiceResources` (~:2474), `hasHydrated = true` (~:1108 handshake, ~:2749
  `applyActivate`), `.voiceButtonTapped` (~:1651), `prompt.submit` builders (~:3242
  upload+submit, ~:3402 plain; ~:3882 is the slash-directive path — untouched),
  `CancelID` enum (~:948), dependencies (`rest` :964, `uuid` :969, `debugLog` :973).
- `HermesKit/Sources/HermesKit/AppFeature.swift` — `.scenePhaseChanged` `.background`
  branch (~:435) forwards `.liveChat(.persistNow)`; `.active` forwards `.liveChat(.foreground)`
  (~:422); `.chatViewDisappeared` (~:611).
- `HermesMobile/Sources/Features/Chat/ComposerView.swift` — trailing `HStack` (:83-93):
  `modelChip`, usage ring, `Spacer`, `attachButton`, `voiceButton`, `sendButton`.
- `HermesMobile/Sources/Features/Chat/ChatView.swift` — `MessageActionBar` call site
  (~:244), `queuedPromptsPanel` slot above the composer (~:311).
- `HermesMobile/Sources/Features/Chat/MessageActionBar.swift` — Copy + Branch buttons.
- Tests: `HermesKit/Tests/HermesKitTests/` (`ChatReductionTests`, `ChatInteractionTests`,
  `HermesRESTClientTests`, `AudioRecorderClientTests`, `MarkdownSegmentTests` as
  patterns); `HermesMobileTests/` (`ComposerSnapshotTests`, `ChatSnapshotTests`,
  `QueuedPromptsPanelSnapshotTests` as patterns).
- `PreferencesClient` is **untouched** — the setting lives on the server.

## Development Approach

- **Testing approach**: Regular (code first, then tests within the same task) — consistent
  with every prior plan.
- Complete each task fully before moving to the next; small focused changes.
- **CRITICAL: every task MUST include new/updated tests** for the code it changes — unit tests
  for new/modified functions, success + error paths, listed as separate checklist items.
- **CRITICAL: all tests must pass before starting the next task** — `make test` (HermesKit,
  streamed) and, for view tasks, `make snapshot` (run twice when adding a new snapshot: the
  first records + fails by design, the second asserts clean).
- **CRITICAL: update this plan file when scope changes during implementation.**
- Logic in `HermesKit`, views thin. Clients are `@DependencyClient` with `liveValue` +
  `testValue`; iOS-only live values behind `#if canImport(UIKit)`, pure logic outside.
- Commit per task (capitalized verb, no conventional-commit prefix).

## Testing Strategy

- **Unit tests** (`swift test` via `make test`): pure helpers (`SpeechText`, `TTSAudio`),
  REST client calls (stubbed `URLProtocol`, following `HermesRESTClientTests`), and TCA
  reductions on `TestStore` with `@Dependency` overrides + `TestClock`.
- **Snapshot tests** (`make snapshot`): composer toggle on/off, the pill in both states, the
  action bar in idle/preparing/speaking. No measured `UIWindow` test — no layout floors or
  caps change.
- No e2e suite in this project.

## Progress Tracking

- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- keep plan in sync with actual work done

## Solution Overview

**Option A from the brainstorm: playback state lives per-slot in `ChatFeature`; `TTSClient`
is a dumb player.** Every existing lifecycle hook (`viewDisappeared`, `teardown`,
`teardownSocketOnly`) then stops audio through the same `releaseVoiceResources` path that
releases the mic, the pill/action-bar/composer all read one store, and the whole state
machine is `TestStore`-testable. The cost — playback dies when the chat leaves the screen —
is the natural phone behaviour (the transcript being read is no longer visible).

Rejected: an `AppFeature`-owned singleton (desktop-parity chat-switch survival, but two-way
plumbing that fights the slot model) and a status stream owned by the client actor (two
sources of truth).

### State machine (in `ChatFeature.State`)

| Field | Purpose |
|---|---|
| `autoSpeakReplies: Bool` | Mirror of server `voice.auto_tts`; loaded on the slot's first `.task`; default `false`. |
| `ttsSupported: Bool = true` | Capability gate; flips off on the first `speak` 404. |
| `ttsPlayback: TTSPlayback` | `.idle` / `.preparing(rowID)` / `.speaking(rowID)`. |
| `spokenAssistantCount: Int` | Ordinal anchor = "assistant message rows consumed". Not snapshot-persisted (every open re-arms). |
| `ttsInterruptedAt: Date?` | Barge-in latch; consumed by the next `prompt.submit` if < 120 s old. |
| `isSceneBackgrounded: Bool` | Set by the new `.sceneBackgrounded`, cleared by `.foreground`; the speak check refuses to start while set. |
| `isOnScreen: Bool` | Set on `.task` / `.reattached`, cleared on `.viewDisappeared`; gates keep-awake. |

**Arming** (`spokenAssistantCount = assistantMessageRowCount`): on toggle-on, on config load
returning `true`, and on the slot's **first** hydrate only (`hasHydrated` false → true).
Later foreground re-hydrates never re-arm, so a reply the user was waiting on is never
silently consumed.

**Speak check** (`autoSpeakIfReady`) runs at three edges — `.messageComplete`, playback →
idle (`.ttsFinished` / `.ttsFailed`), and `.foreground`. It speaks the **last** assistant row
iff `autoSpeakReplies && ttsSupported && ttsPlayback == .idle && !isSceneBackgrounded` and
the row is complete with non-empty sanitized text and `assistantCount > anchor`; then sets
`anchor = assistantCount` (backlog collapse). A turn ending in `.error` is not a
`.messageComplete` → never spoken.

**Keep-awake**: `wantsScreenAwake = isOnScreen && (ttsPlayback != .idle ||
(autoSpeakReplies && isSending) || recording.isBusy)`; a reducer `onChange` drives
`idleTimer.setDisabled`.

## Technical Details

- **`TTSClient`** — `play(data:mimeType:) async throws` writes a temp file, sets
  `AVAudioSession` `.playback` (mode `.default`, no options), activates, plays via
  `AVAudioPlayer`, suspends until the delegate's `didFinishPlaying`, a stall (15 s with
  `currentTime` not advancing → `TTSPlaybackError.stalled`), or an `AVAudioSession`
  interruption notification (treated as clip end, not an error); throws `.failed` on
  decode/`prepareToPlay`/`play()` failure. On every exit — including task cancellation via
  `withTaskCancellationHandler` — stops the player, deactivates with
  `.notifyOthersOnDeactivation`, deletes the temp file. `stop() async` is idempotent and
  makes a suspended `play` return normally. Live value in a private actor behind
  `#if canImport(UIKit)`; `testValue` returns immediately.
- **`TTSAudio.parse(dataURL:)`** — pure: `data:<mime>;base64,<payload>` → `TTSAudio(data,
  mimeType)`; throws on a missing prefix / non-base64 payload. Outside the UIKit guard.
- **`IdleTimerClient`** — `setDisabled: @Sendable (Bool) async -> Void`; live value hops to
  `MainActor` and sets `UIApplication.shared.isIdleTimerDisabled`; `testValue` no-op.
- **REST** — `speak(connection, text, profile) -> TTSAudio` (profile query only when
  non-nil; per-call `URLRequest.timeoutInterval` from `HermesRESTClient.speakTimeout(for:)`
  = `min(600, max(180, 0.035 × chars))`; response `{ok, data_url, mime_type, provider,
  error?}` → `ok == false` ⇒ `RESTError.server(status: 200, detail: error)` like
  `transcribe`), `config(connection) -> JSONValue` (whole record, lenient), and
  `updateConfig(connection, patch: JSONValue)` (PUT `{config: patch}` via `send`).
- **`prompt.submit`** — the two regular submit sites gain `"interrupted": .bool(true)` when
  the reducer hands the effect `interrupted == true` (computed from `ttsInterruptedAt` with
  `@Dependency(\.date)`, then cleared). The slash-directive path is untouched.
- **Row → text** for speech: `ChatRow.Kind.message(role: .assistant, text, isComplete:
  true)` only; `SpeechText.sanitize(text)`.
- **Errors → banner**: `RESTError.notFound` ⇒ silent gate flip; anything else ⇒
  `errorBanner = error.message` (400 details verbatim), `TTSPlaybackError.stalled` ⇒
  "Playback stalled.", `.failed` ⇒ "Couldn’t play the audio."; config PUT failure ⇒
  "Couldn’t save the setting." with the optimistic value reverted.

## What Goes Where

- **Implementation Steps** (`[ ]`): everything below is achievable in this repo.
- **Post-Completion** (no checkboxes): manual device checks and the voice-conversation
  follow-ups.

## Implementation Steps

### Task 1: Port `sanitizeTextForSpeech` as `SpeechText.sanitize`

**Files:**
- Create: `HermesKit/Sources/HermesKit/Models/SpeechText.swift`
- Create: `HermesKit/Tests/HermesKitTests/SpeechTextTests.swift`

Port `apps/desktop/src/lib/speech-text.ts` step for step (Swift `Regex` literals; the emoji
class uses the same code-point ranges `\u{1F000}-\u{1FAFF}`, `\u{2600}-\u{27BF}`,
`\u{FE0F}`, `\u{200D}`, `\u{E0020}-\u{E007F}`). Do **not** reuse `MarkdownSegment` — its
table detection is looser than the desktop's and the two clients must say the same thing.

- [ ] `stripMarkdownTables`: delete whole GFM pipe tables — a table starts where line *i* is
      a delimiter row (every cell `^:?-{3,}:?$`) and line *i-1* a header row with the same
      cell count and blockquote depth; remove header + delimiter + every following line that
      parses as a row at that depth. Port `parseMarkdownTableRow` exactly (≤3-space indent,
      no tabs, `>`-depth counting, unescaped-pipe splitting, ≥2 cells unless fully piped).
- [ ] `normalizeLineBreaks`: CRLF→LF; `(\p{L})-\n(\p{L})` → `$1$2`; punctuated paragraph
      break `([.!?])([*_~\`>"'’”)}\]]*)[ \t]*\n{2,}[ \t]*` → `$1$2 `; remaining `\n{2,}` →
      `. `; single `\n` → ` `.
- [ ] Remaining pipeline in order: fenced code (incl. unterminated) → ` code block omitted `;
      leading `THINKING_PREFIX_RE` → ` `; `[label](url)` → label; inline code → contents;
      bare `https?://\S+` → ` link `; emoji runs → ` `; `^#{1,6}\s+` per line; every
      `[*_~>#]`; `^\s*[-+*]\s+` per line (ordered-list numbers stay); collapse `\s+` → ` `,
      trim.
- [ ] Write `SpeechTextTests`: one case per rule using the desktop's own fixture shapes
      (table inside a blockquote, escaped pipe, hyphen across a line break, punctuated vs
      plain paragraph break, unterminated fence, "(pause) Thinking..." prefix, link + bare
      URL, emoji with VS16/ZWJ, nested bullets, ordered list untouched).
- [ ] Write edge-case tests: empty/whitespace-only input → `""`, text that sanitizes to
      empty (only a table), a mixed real reply asserting the full expected string.
- [ ] run `make test` — must pass before Task 2

### Task 2: `TTSAudio` data-URL parsing and `TTSClient`

**Files:**
- Create: `HermesKit/Sources/HermesKit/Clients/TTSClient.swift`
- Create: `HermesKit/Tests/HermesKitTests/TTSClientTests.swift`

- [ ] Add `public struct TTSAudio: Equatable, Sendable { data, mimeType }` with pure
      `static func parse(dataURL:) throws -> TTSAudio` (outside the UIKit guard) and
      `enum TTSAudioError { malformedDataURL, invalidBase64 }`.
- [ ] Add `public enum TTSPlaybackError: Error, Equatable, Sendable { failed, stalled }` and
      the `@DependencyClient struct TTSClient { play: (Data, String) async throws -> Void;
      stop: () async -> Void }` + `DependencyValues.tts` + `testValue` (returns instantly).
- [ ] Implement the live actor behind `#if canImport(UIKit)` mirroring `AudioRecorderEngine`:
      temp file (`hermes-tts-<uuid>.<ext>` by mime), `.playback` session, `AVAudioPlayer`
      + delegate bridged to a `CheckedContinuation`, 15 s stall watchdog on `currentTime`
      (`TTSPlaybackError.stalled`), `AVAudioSession.interruptionNotification` `.began` ⇒
      finish normally, `withTaskCancellationHandler` ⇒ `stop()`; every exit stops,
      deactivates with `.notifyOthersOnDeactivation`, and deletes the file. `stop()` is
      idempotent (resumes the continuation once).
- [ ] Write `TTSClientTests` for `TTSAudio.parse`: the five server mime types
      (`audio/mpeg`, `audio/ogg`, `audio/wav`, `audio/flac`, plus a default), a payload
      round-trip, missing `data:` prefix, missing `;base64,` marker, invalid base64.
- [ ] Write a test that `TTSClient.testValue.play` returns without throwing and `stop` is
      callable (guards the double's contract used by `ChatFeature` tests).
- [ ] run `make test` — must pass before Task 3

### Task 3: `IdleTimerClient`

**Files:**
- Create: `HermesKit/Sources/HermesKit/Clients/IdleTimerClient.swift`
- Create: `HermesKit/Tests/HermesKitTests/IdleTimerClientTests.swift`

- [ ] Add `@DependencyClient struct IdleTimerClient { setDisabled: @Sendable (Bool) async
      -> Void }` + `DependencyValues.idleTimer`; `testValue` no-op; live value behind
      `#if canImport(UIKit)` hops to `MainActor` and sets
      `UIApplication.shared.isIdleTimerDisabled` (non-UIKit `liveValue = testValue`).
- [ ] Write a test using a recording override (`LockIsolated<[Bool]>`) that the closure
      receives the values it is called with — the same recorder `ChatFeature` tests reuse.
- [ ] run `make test` — must pass before Task 4

### Task 4: REST — `speak`, `config`, `updateConfig`

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Clients/HermesRESTClient.swift`
- Modify: `HermesKit/Tests/HermesKitTests/HermesRESTClientTests.swift`

- [ ] Add `speak: (ServerConnection, String, String?) async throws -> TTSAudio`:
      `POST /api/audio/speak` (+ `?profile=` only when non-nil), body `{text}`, private
      `SpeakResponse {ok, data_url, mime_type, provider, error}`; `ok == false` ⇒
      `RESTError.server(status: 200, detail: error)`; success ⇒ `TTSAudio.parse(dataURL:)`
      (a parse failure maps to `RESTError.decoding`). Per-request timeout from a pure
      `static func speakTimeout(forCharacterCount:) -> TimeInterval` =
      `min(600, max(180, 0.035 × n))` — extend `postJSON` with an optional `timeout:`.
- [ ] Add `config: (ServerConnection) async throws -> JSONValue` (`GET /api/config`,
      lenient whole-record decode) and `updateConfig: (ServerConnection, JSONValue) async
      throws -> Void` (`PUT /api/config` body `{config: <patch>}` via `send`).
- [ ] Add `testValue` doubles (config returns `.object([:])`, speak returns a canned
      `TTSAudio`, updateConfig no-op).
- [ ] Write tests (stubbed `URLProtocol`, existing pattern): `speak` success decodes the
      data URL and sends `{text}` with/without `?profile=`; 404 → `.notFound`; 400 with
      `detail` → `.server(400, detail)`; `ok: false` → `.server(200, error)`; malformed
      data URL → `.decoding`; `speakTimeout` table (short text → 180, 10 000 chars → 350,
      20 000 chars → 600).
- [ ] Write tests: `config` decodes `voice.auto_tts`; `updateConfig` PUTs exactly
      `{"config":{"voice":{"auto_tts":true}}}` and surfaces a 500 as `.server`.
- [ ] run `make test` — must pass before Task 5

### Task 5: `ChatFeature` — setting load, toggle, arming

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift`
- Create: `HermesKit/Tests/HermesKitTests/ChatReadAloudTests.swift`

- [ ] Add state: `autoSpeakReplies`, `ttsSupported`, `ttsPlayback` (`public enum
      TTSPlayback: Equatable, Sendable { idle, preparing(ChatRow.ID), speaking(ChatRow.ID) }`
      + `isActive`), `spokenAssistantCount`, `ttsInterruptedAt`, `isSceneBackgrounded`,
      `isOnScreen`; pure `assistantMessageRowCount` and `lastCompletedAssistantRow`
      helpers; a private `arm(&state)` that sets the anchor.
- [ ] Actions: `autoSpeakToggled`, `autoSpeakLoaded(Bool)`, `autoSpeakSaveFailed(String)`.
      On `.task` (first appearance) add a one-shot `rest.config` effect → `.autoSpeakLoaded`
      (failure ⇒ `debugLog` only). `.autoSpeakLoaded(true)` sets the flag and arms.
- [ ] `.autoSpeakToggled`: flip optimistically, arm if now on, `rest.updateConfig` with
      `{voice: {auto_tts}}`; failure ⇒ revert + `errorBanner = "Couldn’t save the setting."`.
- [ ] Arm on the slot's first hydrate only: in `applyActivate` where `hasHydrated` goes
      false → true (and the `session.create` handshake site), when `autoSpeakReplies`.
- [ ] Write tests: config load `true` sets the flag and arms to the current assistant count;
      load `false` leaves the anchor; load failure stays `false` without a banner; toggle on
      arms + PUTs the expected patch; toggle off PUTs `false` and does not touch the anchor;
      PUT failure reverts and banners; first hydrate arms, a second (foreground) hydrate
      does not.
- [ ] run `make test` — must pass before Task 6

### Task 6: `ChatFeature` — playback flow, speak check, per-message read

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/ChatReadAloudTests.swift`

- [ ] Add `CancelID.ttsPlayback` and `@Dependency(\.tts)`. Actions: `readAloudTapped(id)`,
      `stopReadAloud`, `ttsSpeaking(id)`, `ttsFinished`, `ttsFailed(id, RESTOrPlaybackError)`.
      Private `speakRow(id, &state) -> Effect`: `ttsPlayback = .preparing(id)`; effect
      (`cancellable(id: .ttsPlayback, cancelInFlight: true)`): `SpeechText.sanitize` →
      empty ⇒ `.ttsFinished`; `rest.speak(connection, text, profileOrNil)` →
      `send(.ttsSpeaking(id))` → `tts.play` → `send(.ttsFinished)`; catch ⇒ `.ttsFailed`.
- [ ] `.ttsFailed`: `RESTError.notFound` ⇒ `ttsSupported = false` silently (and turn
      `autoSpeakReplies` handling into a no-op while unsupported); other REST errors ⇒
      `errorBanner = message`; `.stalled` ⇒ "Playback stalled."; `.failed` ⇒ "Couldn’t play
      the audio."; all ⇒ `.idle` then run the speak check.
- [ ] `.stopReadAloud`: `.idle` + `.cancel(id: .ttsPlayback)` + `tts.stop()`.
- [ ] Private `autoSpeakIfReady(&state) -> Effect` per the Solution Overview conditions;
      call it from `.messageComplete` (after the existing merge), `.ttsFinished`,
      `.ttsFailed`, and the `.foreground` branch of the shared handler.
- [ ] `.readAloudTapped(id)`: guard `ttsSupported`, `ttsPlayback == .idle`, row is a complete
      assistant message; `speakRow` and bump `spokenAssistantCount` to that row's ordinal+1
      (never lower it).
- [ ] Write tests (`TestStore`, recording `tts`/`rest` overrides): armed + idle
      `messageComplete` ⇒ preparing → speaking → finished with the sanitized text sent;
      unarmed ⇒ nothing; toggle off ⇒ nothing; a completion during playback waits and the
      idle edge speaks only the newest row; empty-after-sanitize reply is skipped and
      consumes the anchor; `.error` terminal never speaks.
- [ ] Write tests: `readAloudTapped` speaks that row and bumps the anchor so the next
      `messageComplete`-less idle edge does not re-speak; tap while another row plays is a
      no-op; `stopReadAloud` cancels and calls `tts.stop`; 404 flips `ttsSupported` and
      hides without a banner; 400 detail lands in `errorBanner`; stalled/failed banners.
- [ ] run `make test` — must pass before Task 7

### Task 7: Interruption latch and lifecycle (background, disappear, teardown)

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift`
- Modify: `HermesKit/Sources/HermesKit/AppFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/ChatReadAloudTests.swift`
- Modify: `HermesKit/Tests/HermesKitTests/AppFeatureTests.swift`

- [ ] Barge-in: in `.composerSubmitted`/`submitDraft` and `.voiceButtonTapped` (from
      `.idle`), if `ttsPlayback.isActive` ⇒ stop (cancel + `tts.stop`) and stamp
      `ttsInterruptedAt = date()` (`@Dependency(\.date)`).
- [ ] Consume: when building a regular `prompt.submit` (both the upload+submit and plain
      sites; not the slash-directive path), compute `interrupted = ttsInterruptedAt.map {
      date().timeIntervalSince($0) < 120 } ?? false`, clear the stamp, and add
      `"interrupted": .bool(true)` to the params only when true (byte-identical frames
      otherwise).
- [ ] Extend `releaseVoiceResources` to cancel `.ttsPlayback`, reset `ttsPlayback = .idle`,
      and call `tts.stop()` when it was active — covers `viewDisappeared`, `teardown`,
      `teardownSocketOnly`. `viewDisappeared` also clears `isOnScreen`; `.task` and the
      `.reattached` branch set it.
- [ ] Add `ChatFeature.Action.sceneBackgrounded` (stop playback, `isSceneBackgrounded =
      true`); `.foreground` clears it before the speak check. In `AppFeature`'s
      `.scenePhaseChanged(.background)` branch forward `.liveChat(.sceneBackgrounded)`
      alongside the existing `persistNow` (the `.inactive` branch stays untouched).
- [ ] Write tests: submit mid-playback stops and the next `prompt.submit` frame carries
      `interrupted: true` (assert the exact `JSONValue` params); a 121 s-old stamp is
      dropped; a submit with no stamp sends the byte-identical legacy frame; mic tap
      mid-playback stops + stamps, and the later composer send carries the flag.
- [ ] Write tests: `sceneBackgrounded` stops playback; a `messageComplete` while
      backgrounded does not start playback; `.foreground` clears the flag and speaks the
      pending newest row; `viewDisappeared` / `teardown` / `teardownSocketOnly` each stop
      an active clip; `AppFeature` `.background` forwards `sceneBackgrounded` only when a
      slot exists.
- [ ] run `make test` — must pass before Task 8

### Task 8: Keep-awake predicate

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/ChatReadAloudTests.swift`

- [ ] Add `public var wantsScreenAwake: Bool` on `State` (`isOnScreen && (ttsPlayback
      != .idle || (autoSpeakReplies && isSending) || recording.isBusy)`).
- [ ] Add `@Dependency(\.idleTimer)` and a `Reduce` `.onChange(of: \.wantsScreenAwake)`
      effect calling `idleTimer.setDisabled(new)`; `.teardown` additionally sends an explicit
      `setDisabled(false)`.
- [ ] Write tests with the recording `IdleTimerClient`: on/off transitions for each of the
      four triggers (playback start/finish; auto-speak on + turn start/`messageComplete`;
      recording start/stop; `viewDisappeared` while playing ⇒ false); teardown emits `false`.
- [ ] run `make test` — must pass before Task 9

### Task 9: Composer auto-speak toggle button

**Files:**
- Modify: `HermesMobile/Sources/Features/Chat/ComposerView.swift`
- Modify: `HermesMobile/Sources/Features/Chat/ChatView.swift`
- Modify: `HermesMobileTests/ComposerSnapshotTests.swift`

- [ ] Add `var autoSpeak: Bool = false`, `var showsAutoSpeak: Bool = true`,
      `var onToggleAutoSpeak: () -> Void = {}` (defaults keep existing call sites intact).
- [ ] Insert `autoSpeakButton` before `attachButton` in the trailing `HStack`:
      `speaker.wave.2.fill`, `.font(.title3)`, `Color.hermesAccent` when on / `.secondary`
      off, accessibility label "Read replies aloud" / "Stop reading replies aloud", the
      `.isSelected` trait when on; rendered only when `showsAutoSpeak` (the recording bar
      already replaces the row while recording).
- [ ] Wire in `ChatView`: `autoSpeak: store.autoSpeakReplies`, `showsAutoSpeak:
      store.ttsSupported`, `onToggleAutoSpeak: { store.send(.autoSpeakToggled) }`.
- [ ] Add snapshots: composer with the toggle on, off, and hidden (`showsAutoSpeak: false`)
      in light + dark (`make snapshot` twice).
- [ ] run `make snapshot` — must pass before Task 10

### Task 10: "Reading aloud" pill

**Files:**
- Create: `HermesMobile/Sources/Features/Chat/ReadAloudPill.swift`
- Modify: `HermesMobile/Sources/Features/Chat/ChatView.swift`
- Create: `HermesMobileTests/ReadAloudPillSnapshotTests.swift`

- [ ] `ReadAloudPill(state: ChatFeature.State.TTSPlayback, onStop:)`: preparing ⇒
      `ProgressView().controlSize(.small)` + "Preparing audio"; speaking ⇒
      `speaker.wave.2` + "Reading aloud"; trailing "Stop" button; secondary-background
      capsule matching `QueuedPromptsPanel` styling; `.accessibilityElement(children:
      .combine)` + `.accessibilityAddTraits(.updatesFrequently)`; announce state changes via
      `AccessibilityNotification.Announcement`.
- [ ] Mount in `ChatView` next to `queuedPromptsPanel` (above the suggestion panel, below
      the transcript region) with `.transition(.opacity)`, shown while `ttsPlayback != .idle`;
      `onStop: { store.send(.stopReadAloud) }`.
- [ ] Add snapshots: preparing and speaking, light + dark.
- [ ] run `make snapshot` — must pass before Task 11

### Task 11: Per-message "Read aloud" action

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift`
- Modify: `HermesMobile/Sources/Features/Chat/MessageActionBar.swift`
- Modify: `HermesMobile/Sources/Features/Chat/ChatView.swift`
- Modify: `HermesKit/Tests/HermesKitTests/ChatReadAloudTests.swift`
- Modify: `HermesMobileTests/ChatSnapshotTests.swift`

- [ ] Add `public enum ReadAloudButtonState: Equatable, Sendable { hidden, idle, disabled,
      preparing, speaking }` and pure `ChatFeature.State.readAloudState(for rowID:)`:
      `hidden` when `!ttsSupported`; `preparing`/`speaking` when `ttsPlayback` targets this
      row; `disabled` when any other playback is active; else `idle`.
- [ ] `MessageActionBar`: add `readAloud: ReadAloudButtonState`, `onReadAloud`,
      `onStopReading`; third button after Branch — `speaker.wave.2` (idle/disabled, 0.4
      opacity + `.disabled` when disabled), `ProgressView` (preparing, disabled),
      `speaker.slash` (speaking → `onStopReading`); labels "Read aloud" / "Preparing audio"
      / "Stop reading"; nothing rendered for `hidden`.
- [ ] Wire in `ChatView`'s action-bar call site: `readAloud: store.readAloudState(for:
      row.id)`, `onReadAloud: { store.send(.readAloudTapped(id: row.id)) }`,
      `onStopReading: { store.send(.stopReadAloud) }`.
- [ ] Write `readAloudState` unit tests (all five outcomes).
- [ ] Add snapshots of a completed assistant cell with the bar in idle, preparing, speaking,
      and disabled (`rowView` component render, as the existing action-bar snapshots do).
- [ ] run `make test` and `make snapshot` — must pass before Task 12

### Task 12: Verify acceptance criteria

- [ ] Toggle on → reply completes → pill "Preparing audio" → "Reading aloud" → audio plays
      through the silent switch → pill hides; the reply on screen at toggle time was not read.
- [ ] Second reply completing mid-playback waits, then only the newest is read.
- [ ] Per-message Read aloud reads that row; other rows' buttons are disabled meanwhile;
      Stop silences; auto-speak does not re-read that row.
- [ ] Typing a new message mid-playback silences it and the frame carries `interrupted`.
- [ ] Backgrounding stops audio; returning speaks a reply that completed while away.
- [ ] Screen does not autolock while a turn runs with the toggle on or while speaking; does
      autolock on the session list.
- [ ] Against an agent with no TTS provider: banner with the server's detail, controls stay.
      Against an older agent without the route: controls disappear silently.
- [ ] Token, cookie, and bearer auth regimes all reach `/api/audio/speak` and `/api/config`.
- [ ] run full test suite: `make test` and `make snapshot`
- [ ] `git checkout -- HermesKit/Package.resolved` if it drifted

### Task 13: [Final] Update documentation

**Files:**
- Create: `docs/features/read-aloud.md`
- Modify: `CLAUDE.md`
- Modify: `README.md`
- Modify: `docs/architecture.md` (REST surface list, if it enumerates endpoints)

- [ ] Write `docs/features/read-aloud.md`: the setting's server home and the gateway
      coupling, the arming rule (three arm points, never later hydrates), the speak-check
      conditions and edges, the ordinal anchor rationale, the barge-in latch (120 s TTL,
      which submit sites), the lifecycle table (disappear / teardown / socket-only /
      background / foreground / interruption), keep-awake predicate, capability gating by
      failure, and the deferred rungs (speak-stream, client-direct, lease).
- [ ] Add a 5–8 line CLAUDE.md bullet under "Composer & input" (rule + pointer only).
- [ ] Add a README feature line under the existing feature list.
- [ ] Move this plan to `docs/plans/completed/`.

## Post-Completion

**Manual verification (device, not simulator):**
- Real audio route checks: speaker, wired/Bluetooth headphones, a phone call arriving
  mid-playback (interruption ends the clip cleanly, no stall banner).
- Both a cloud agent (edge default provider → `speak` returns MP3) and a self-hosted agent
  with ElevenLabs/OpenAI configured, plus one with no provider (400 detail path).
- A long reply (> 5 000 chars) to confirm the timeout formula and the watchdog do not fire.

**Follow-ups (separate tickets):**
- Voice-conversation mode: adds `speak-stream` PCM playback via `AVAudioEngine`, the
  `source` field on `ttsPlayback`, the conversation keep-awake condition, and (maybe)
  background audio.
- `tts-lease` warm-up if local engines' first-clip latency turns out to matter.
- Settings → Voice mirror of the toggle if testers go looking there.
