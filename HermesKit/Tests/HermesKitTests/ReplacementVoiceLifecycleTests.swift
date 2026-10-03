import ComposableArchitecture
import Foundation
import Testing
@testable import HermesKit

/// B3 held-operation replacement regression matrix.
/// Covers: held permission / start / stop / transcription of operation A,
/// then Cancel + replacement operation B, then release A's held completion while B is
/// recording or transcribing. The recorder double models the production engine's
/// ownership semantics (start refuses while owned; stop/cancel scoped to owner) using the
/// production `AudioRecorderOwnership` authority.
@MainActor
struct ReplacementVoiceLifecycleTests {
  private let connection = ServerConnection(baseURL: URL(string: "http://voice.invalid")!, token: "test")

  @Test(arguments: ["permission", "start", "stop", "transcription"], ["bRecording", "bTranscribing"])
  func heldOldCompletionAfterReplacementCannotTouchNewOperation(stage: String, releaseWhen: String) async throws {
    let gateA = ReplacementVoiceGate()
    let gateB = ReplacementVoiceGate()
    let permissionCalls = LockIsolated(0)
    let transcribeCalls = LockIsolated(0)
    let owner = LockIsolated(AudioRecorderOwnership())
    let started = LockIsolated<[UUID]>([])
    let cancelled = LockIsolated<[UUID]>([])
    let aSettled = LockIsolated(false)
    let A = UUID(0), B = UUID(1)
    var initial = ChatFeature.State(connection: connection)
    initial.composerText = "draft"
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.setLivenessEnabled = { _ in }
      $0.audioRecorder = .testValue
      $0.audioRecorder.levels = { _ in AsyncStream { $0.finish() } }
      $0.audioRecorder.requestPermission = {
        let n = permissionCalls.withValue { $0 += 1; return $0 }
        if stage == "permission", n == 1 { await gateA.hold(); aSettled.setValue(true) }
        return true
      }
      $0.audioRecorder.startRecording = { id in
        started.withValue { $0.append(id) }
        let claimed = owner.withValue { o -> Bool in
          guard o.owner == nil else { return false }
          o.claim(id)
          return true
        }
        guard claimed else { throw AudioRecorderError.unavailable }
        if stage == "start", id == A { await gateA.hold(); aSettled.setValue(true) }
      }
      $0.audioRecorder.stopRecording = { id in
        guard owner.value.owner == id else { throw AudioRecorderError.notRecording }
        if stage == "stop", id == A { await gateA.hold(); aSettled.setValue(true) }
        _ = owner.withValue { $0.release(id) }
        return RecordedAudio(data: Data([id == A ? 0xA : 0xB]), mimeType: "audio/m4a")
      }
      $0.audioRecorder.cancel = { id in
        cancelled.withValue { $0.append(id) }
        _ = owner.withValue { $0.release(id) }
      }
      $0.hermesREST.transcribe = { _, dataURL, _ in
        let n = transcribeCalls.withValue { $0 += 1; return $0 }
        let isA = dataURL.hasSuffix(Data([0xA]).base64EncodedString())
        if stage == "transcription", isA, n == 1 { await gateA.hold(); aSettled.setValue(true); return "A text" }
        if releaseWhen == "bTranscribing", !isA { await gateB.hold() }
        return isA ? "A text" : "B text"
      }
    }
    store.exhaustivity = .off

    // Operation A reaches the held stage.
    await store.send(.voiceButtonTapped)
    if stage != "permission" { await store.receive(\.recordingPermission) }
    if stage == "stop" || stage == "transcription" {
      await store.receive(\.recordingStarted)
      await store.send(.voiceButtonTapped)
      if stage == "transcription" { await store.receive(\.recordingStopped) }
    }
    await gateA.waitUntilHeld()
    #expect(store.state.voiceOperationID == A)

    // Cancel A; wait (no sleeps) for its owner-scoped release, then start replacement B.
    await store.send(.recordingCancelled)
    var spins = 0
    while !cancelled.value.contains(A), spins < 100_000 { await Task.yield(); spins += 1 }
    try #require(cancelled.value.contains(A))
    await store.send(.voiceButtonTapped)
    await store.receive(\.recordingPermission)
    await store.receive(\.recordingStarted)
    #expect(store.state.voiceOperationID == B)
    #expect(owner.value.owner == B)

    if releaseWhen == "bTranscribing" {
      await store.send(.voiceButtonTapped)
      await store.receive(\.recordingStopped)
      await gateB.waitUntilHeld()
      #expect(store.state.recording == .transcribing)
    }

    // Release A's held completion while B is current.
    await gateA.release()
    spins = 0
    while !aSettled.value, spins < 100_000 { await Task.yield(); spins += 1 }
    try #require(aSettled.value)
    for _ in 0..<1_000 { await Task.yield() }

    let expectedStage: ChatFeature.State.RecordingState = releaseWhen == "bTranscribing" ? .transcribing : .recording
    #expect(store.state.voiceOperationID == B)
    #expect(store.state.recording == expectedStage)
    #expect(store.state.composerText == "draft")
    #expect(store.state.errorBanner == nil)
    #expect(cancelled.value.allSatisfy { $0 == A })
    #expect(started.value == (stage == "permission" ? [B] : [A, B]))
    if releaseWhen == "bRecording" { #expect(owner.value.owner == B) }

    // B completes exactly once; A's transcript never lands, no duplicate append.
    if releaseWhen == "bRecording" {
      await store.send(.voiceButtonTapped)
      await store.receive(\.recordingStopped)
    } else {
      await gateB.release()
    }
    await store.receive(\.transcriptionSucceeded)
    await store.finish()
    #expect(store.state.composerText == "draft B text")
    #expect(store.state.voiceOperationID == nil)
    #expect(store.state.recording == .idle)
    #expect(store.state.errorBanner == nil)
    #expect(owner.value.owner == nil)
    #expect(transcribeCalls.value == (stage == "transcription" ? 2 : 1))
  }
}

private actor ReplacementVoiceGate {
  private var continuation: CheckedContinuation<Void, Never>?
  private var observers: [CheckedContinuation<Void, Never>] = []
  func hold() async {
    await withCheckedContinuation { continuation in
      self.continuation = continuation
      observers.forEach { $0.resume() }
      observers = []
    }
  }
  func waitUntilHeld() async {
    if continuation != nil { return }
    await withCheckedContinuation { observers.append($0) }
  }
  func release() {
    continuation?.resume()
    continuation = nil
  }
}
