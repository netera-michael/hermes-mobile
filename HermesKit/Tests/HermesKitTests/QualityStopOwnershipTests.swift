import ComposableArchitecture
import Foundation
import Testing
@testable import HermesKit

@MainActor
@Suite struct QualityStopOwnershipTests {
  @Test(arguments: [false, true], ["one.png", "two.png", "prompt.submit"])
  func stoppedPipelineRetainsRecoveryAndCannotResend(queued: Bool, heldStage: String) async {
    let items = ["one.png", "two.png"].map {
      ComposerAttachment(id: UUID(), kind: .image, filename: $0, mimeType: "image/png", data: Data([1]))
    }
    let entry = QueuedPrompt(id: UUID(), text: "caption", attachments: items)
    var initial = ChatFeature.State(connection: ServerConnection(baseURL: URL(string: "http://test")!, token: "t"), status: .ready)
    initial.liveSessionID = "live"
    if queued { initial.queuedPrompts = [entry] }
    else { initial.composerText = "caption"; initial.attachments = items }
    let started = AsyncStream<Void>.makeStream()
    let held = LockIsolated<CheckedContinuation<Void, Never>?>(nil)
    let calls = LockIsolated<[String]>([])
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.chatSnapshot = .inMemory()
      $0.continuousClock = ImmediateClock()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.hermesGateway.send = { method, params in
        let label = params["filename"]?.stringValue ?? method
        calls.withValue { $0.append(label) }
        if label == heldStage {
          await withCheckedContinuation { continuation in
            held.setValue(continuation)
            started.continuation.yield(())
          }
        }
        return .object(["attached": .bool(true), "status": .string("streaming")])
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    if queued { await store.send(.queuedPromptSendNow(id: entry.id)) }
    else { await store.send(.composerSubmitted) }
    for await _ in started.stream { break }
    let id = store.state.submitOperation!.id
    await store.send(.interruptTapped)
    #expect(store.state.submitOperation?.outcome == .unknown)
    #expect(store.state.legacyStagingBlocked)
    held.withValue { $0?.resume(); $0 = nil }
    started.continuation.finish()
    await store.finish()
    let submits = heldStage == "prompt.submit" ? 1 : 0
    #expect(calls.value.filter { $0 == "prompt.submit" }.count == submits)
    if heldStage == "one.png" { #expect(!calls.value.contains("two.png")) }
    // A current terminal must retain attachment recovery just like explicit idle.
    await store.send(.gatewayEvent(.messageComplete(text: "", usage: nil)))
    #expect(store.state.errorBanner?.contains("new chat") == true)
    #expect(store.state.deliveryBlocked)
    await store.send(.activateResult(.success(ActivateResponse(sessionID: "live", running: false))))
    // Simulate late actions already queued when cancellation won: none may clear recovery.
    await store.send(.submitOperationFinished(id: id, outcome: .accepted, message: nil))
    await store.send(.attachmentAttemptFailed(operationID: id, uncertain: false, message: "late"))
    #expect(store.state.submitOperation?.outcome == .unknown)
    #expect(store.state.deliveryBlocked)
    #expect(store.state.errorBanner?.contains("new chat") == true)
    if queued {
      #expect(store.state.queuedPrompts == [entry])
      await store.send(.queuedPromptSendNow(id: entry.id))
    } else {
      #expect(store.state.composerText == "caption")
      #expect(store.state.attachments.map(\.id) == items.map(\.id))
      await store.send(.composerSubmitted)
    }
    await store.finish()
    #expect(calls.value.filter { $0 == "prompt.submit" }.count == submits)
  }

  @Test(arguments: [false, true]) func stopDuringFirstUploadMustNotStartSecondUpload(cooperative: Bool) async {
    let first = ComposerAttachment(id: UUID(), kind: .image, filename: "one.png", mimeType: "image/png", data: Data([1]))
    let second = ComposerAttachment(id: UUID(), kind: .image, filename: "two.png", mimeType: "image/png", data: Data([2]))
    var initial = ChatFeature.State(connection: ServerConnection(baseURL: URL(string: "http://test")!, token: "t"), status: .ready)
    initial.liveSessionID = "live"
    initial.composerText = "caption"
    initial.attachments = [first, second]
    let started = AsyncStream<Void>.makeStream()
    let held = LockIsolated<CheckedContinuation<Void, Never>?>(nil)
    let calls = LockIsolated<[String]>([])
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.chatSnapshot = .inMemory()
      $0.continuousClock = ImmediateClock()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.hermesGateway.send = { method, params in
        if cooperative { try Task.checkCancellation() }
        let label = params["filename"]?.stringValue ?? method
        calls.withValue { $0.append(label) }
        if label == "one.png" {
          // Model a transport completion already in progress: cancellation cannot
          // recall the bytes or prevent its eventual callback.
          await withCheckedContinuation { continuation in
            held.setValue(continuation)
            started.continuation.yield(())
          }
        }
        return .object(["attached": .bool(true), "status": .string("streaming")])
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.composerSubmitted)
    for await _ in started.stream { break }
    await store.send(.interruptTapped)
    #expect(store.state.attachmentSubmitOwnership == nil)
    held.withValue { $0?.resume(); $0 = nil }
    started.continuation.finish()
    await store.finish()
    #expect(!calls.value.contains("two.png"), "Stop must prevent starting the next attachment stage")
    #expect(!calls.value.contains("prompt.submit"))
    #expect(store.state.submitOperation?.outcome != .submitting, "Stopped upload must not remain permanently submitting")
    #expect(store.state.composerText == "caption")
    #expect(store.state.attachments.count == 2)
    await store.send(.activateResult(.success(ActivateResponse(sessionID: "live", running: false))))
    #expect(store.state.interruptOperation == nil)
    #expect(store.state.submitOperation?.outcome != .submitting, "Idle reconciliation must not retain a dead upload as active")
    #expect(!store.state.deliveryBlocked || store.state.errorBanner != nil, "A retained safety block needs actionable recovery guidance")
    await store.finish()
  }
}
