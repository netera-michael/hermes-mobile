import ComposableArchitecture
import Foundation
import Testing
@testable import HermesKit

@MainActor
struct VoiceLifecycleTests {
  private let connection = ServerConnection(baseURL: URL(string: "http://voice.invalid")!, token: "test")

  // Continuations deliberately ignore cancellation, like the OS permission prompt or a
  // transport completing after its task was cancelled. No timing sleeps drive ordering.
  @Test(arguments: ["permission", "start", "stop", "transcription"],
        ["cancel", "navigation", "background", "teardown"])
  func heldCompletionCannotReviveCancelledOperation(stage: String, reason: String) async {
    let gate = VoiceGate()
    let started = LockIsolated<[UUID]>([])
    let cancelled = LockIsolated<[UUID]>([])
    let transcribed = LockIsolated(0)
    var initial = ChatFeature.State(connection: connection)
    initial.composerText = "draft"
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.setLivenessEnabled = { _ in }
      $0.audioRecorder = .testValue
      $0.audioRecorder.requestPermission = {
        if stage == "permission" { await gate.hold() }
        return true
      }
      $0.audioRecorder.startRecording = { id in
        started.withValue { $0.append(id) }
        if stage == "start" { await gate.hold() }
      }
      $0.audioRecorder.stopRecording = { _ in
        if stage == "stop" { await gate.hold() }
        return RecordedAudio(data: Data([1]), mimeType: "audio/m4a")
      }
      $0.audioRecorder.cancel = { id in cancelled.withValue { $0.append(id) } }
      $0.audioRecorder.levels = { _ in AsyncStream { $0.finish() } }
      $0.hermesREST.transcribe = { _, _, _ in
        transcribed.withValue { $0 += 1 }
        if stage == "transcription" { await gate.hold() }
        return "late"
      }
    }
    store.exhaustivity = .off
    await store.send(.voiceButtonTapped)
    if stage != "permission" { await store.receive(\.recordingPermission) }
    if stage == "stop" || stage == "transcription" {
      await store.receive(\.recordingStarted)
      await store.send(.voiceButtonTapped)
      if stage == "transcription" { await store.receive(\.recordingStopped) }
    }
    await gate.waitUntilHeld()
    let action: ChatFeature.Action = switch reason {
    case "navigation": .viewDisappeared
    case "background": .background
    case "teardown": .teardown
    default: .recordingCancelled
    }
    await store.send(action)
    await gate.release()
    await store.finish()
    #expect(store.state.recording == .idle)
    #expect(store.state.voiceOperationID == nil)
    #expect(store.state.composerText == "draft")
    #expect(store.state.errorBanner == nil)
    #expect(cancelled.value.allSatisfy { $0 == UUID(0) })
    if stage == "permission" { #expect(started.value.isEmpty) }
    if stage == "stop" { #expect(transcribed.value == 0) }
  }

  @Test(arguments: ["cancel", "navigation", "background", "teardown"])
  func invalidationRejectsEveryOldCallback(reason: String) async {
    var initial = ChatFeature.State(connection: connection)
    initial.voiceOperationID = UUID(0)
    initial.recording = .recording
    initial.composerText = "draft"
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.audioRecorder = .testValue
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.setLivenessEnabled = { _ in }
    }
    store.exhaustivity = .off
    let action: ChatFeature.Action = switch reason {
    case "navigation": .viewDisappeared
    case "background": .background
    case "teardown": .teardown
    default: .recordingCancelled
    }
    await store.send(action)
    await store.finish()
    let expected = store.state
    await store.send(.recordingPermission(UUID(0), true))
    await store.send(.recordingStarted(UUID(0)))
    await store.send(.recordingLevel(UUID(0), 0.9))
    await store.send(.recordingTick(UUID(0)))
    await store.send(.recordingStopped(UUID(0), RecordedAudio(data: Data(), mimeType: "audio/m4a")))
    await store.send(.transcriptionSucceeded(UUID(0), "late"))
    await store.send(.voiceInputFailed(UUID(0), message: "late error"))
    #expect(store.state == expected)
    await store.finish()
  }

  @Test func replacementRejectsOldCallbacksAndOldResourceRelease() async {
    var initial = ChatFeature.State(connection: connection)
    initial.voiceOperationID = UUID(1)
    initial.recording = .transcribing
    initial.composerText = "B draft"
    let store = TestStore(initialState: initial) { ChatFeature() }
    await store.send(.recordingPermission(UUID(0), true))
    await store.send(.recordingStarted(UUID(0)))
    await store.send(.recordingLevel(UUID(0), 1))
    await store.send(.recordingTick(UUID(0)))
    await store.send(.recordingStopped(UUID(0), RecordedAudio(data: Data(), mimeType: "audio/m4a")))
    await store.send(.transcriptionSucceeded(UUID(0), "A text"))
    await store.send(.voiceInputFailed(UUID(0), message: "A error"))
    var ownership = AudioRecorderOwnership()
    ownership.claim(UUID(0))
    let releasedA = ownership.release(UUID(0))
    #expect(releasedA)
    ownership.claim(UUID(1))
    let releasedStaleA = ownership.release(UUID(0))
    #expect(!releasedStaleA)
    #expect(ownership.owner == UUID(1))
    let releasedB = ownership.release(UUID(1))
    #expect(releasedB)
  }

  @Test func lateStartCleanupCannotReleaseReplacementRecorder() async {
    let startA = VoiceGate()
    let cleanupA = VoiceGate()
    let owner = LockIsolated(AudioRecorderOwnership())
    let cancellations = LockIsolated<[UUID]>([])
    let store = TestStore(initialState: ChatFeature.State(connection: connection)) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.audioRecorder = .testValue
      $0.audioRecorder.levels = { _ in AsyncStream { $0.finish() } }
      $0.audioRecorder.startRecording = { id in
        owner.withValue { $0.claim(id) }
        if id == UUID(0) { await startA.hold() }
      }
      $0.audioRecorder.cancel = { id in
        cancellations.withValue { $0.append(id) }
        owner.withValue { _ = $0.release(id) }
        if id == UUID(0) { await cleanupA.hold() }
      }
    }
    store.exhaustivity = .off
    await store.send(.voiceButtonTapped)
    await store.receive(\.recordingPermission)
    await startA.waitUntilHeld()
    await store.send(.recordingCancelled)
    await cleanupA.waitUntilHeld()
    await cleanupA.release()
    await store.send(.voiceButtonTapped)
    await store.receive(\.recordingPermission)
    await store.receive(\.recordingStarted)
    #expect(owner.value.owner == UUID(1))
    await startA.release()
    await cleanupA.waitUntilHeld()
    #expect(owner.value.owner == UUID(1))
    #expect(store.state.voiceOperationID == UUID(1))
    #expect(store.state.recording == .recording)
    #expect(cancellations.value == [UUID(0), UUID(0)])
    await cleanupA.release()
    await store.send(.recordingCancelled)
    await store.finish()
    #expect(owner.value.owner == nil)
  }

  @Test func backgroundReleasesVoiceAndPreservesDraft() async {
    var initial = ChatFeature.State(connection: connection)
    initial.recording = .recording
    initial.voiceOperationID = UUID(0)
    initial.composerText = "keep draft"
    let cancelled = LockIsolated(false)
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.audioRecorder.cancel = { _ in cancelled.setValue(true) }
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.setLivenessEnabled = { _ in }
    }
    store.exhaustivity = .off
    await store.send(.background)
    await store.finish()
    #expect(store.state.recording == .idle)
    #expect(store.state.composerText == "keep draft")
    #expect(cancelled.value)
  }

  @Test func lateTranscriptionAfterCancelDoesNotChangeDraft() async {
    var initial = ChatFeature.State(connection: connection)
    initial.recording = .transcribing
    initial.voiceOperationID = UUID(0)
    initial.composerText = "keep draft"
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.audioRecorder = .testValue
    }
    store.exhaustivity = .off
    await store.send(.recordingCancelled)
    await store.send(.transcriptionSucceeded(UUID(0), "late words"))
    #expect(store.state.composerText == "keep draft")
    await store.finish()
  }
}

private actor VoiceGate {
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
