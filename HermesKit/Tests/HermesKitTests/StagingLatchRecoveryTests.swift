import ComposableArchitecture
import Foundation
import Testing
@testable import HermesKit

/// B4 (review finding 6): a hydrate that lands while an owned attachment submit is still
/// awaiting its acknowledgement must not permanently latch the slot. Only the matching
/// definitive acceptance resolves that ambiguity; unrelated staging stays protected.
@MainActor
@Suite struct StagingLatchRecoveryTests {
  private func makeStore(
    items: [ComposerAttachment], ackGate: AsyncStream<Void>, started: AsyncStream<Void>.Continuation,
    calls: LockIsolated<[String]>, submitError: (any Error)? = nil
  ) -> TestStoreOf<ChatFeature> {
    var initial = ChatFeature.State(connection: ServerConnection(baseURL: URL(string: "http://test")!, token: "t"), status: .ready)
    initial.liveSessionID = "live"
    initial.storedSessionID = "stored"
    initial.composerText = "caption"
    initial.attachments = items
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.chatSnapshot = .inMemory()
      $0.continuousClock = ImmediateClock()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.hermesGateway.send = { method, _ in
        calls.withValue { $0.append(method) }
        if method == "prompt.submit", calls.value.filter({ $0 == "prompt.submit" }).count == 1 {
          started.yield(())
          for await _ in ackGate { }
          if let submitError { throw submitError }
        }
        return .object(["attached": .bool(true), "status": .string("streaming")])
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    return store
  }

  private func plainStore(_ initial: ChatFeature.State) -> TestStoreOf<ChatFeature> {
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.chatSnapshot = .inMemory()
      $0.continuousClock = ImmediateClock()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.hermesGateway.send = { _, _ in .object([:]) }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    return store
  }

  private func image(_ name: String) -> ComposerAttachment {
    ComposerAttachment(id: UUID(), kind: .image, filename: name, mimeType: "image/png", data: Data([1]))
  }

  @Test func matchingAcceptanceAfterHydrateLetsTheSameChatSendAgain() async {
    let ack = AsyncStream<Void>.makeStream(), started = AsyncStream<Void>.makeStream()
    let calls = LockIsolated<[String]>([])
    let store = makeStore(items: [image("one.png")], ackGate: ack.stream, started: started.continuation, calls: calls)
    await store.send(.composerSubmitted)
    for await _ in started.stream { break } // upload acknowledged; submit ACK held
    await store.receive(\.attachmentAcknowledged)
    // Hydrate while the acknowledged staging exists and the submit is unresolved.
    await store.send(.activateResult(.success(ActivateResponse(sessionID: "live", storedSessionID: "stored", running: true))))
    #expect(store.state.deliveryBlocked, "ambiguity remains while the submit is unacknowledged")
    ack.continuation.finish()
    await store.receive(\.attachmentSubmissionAccepted)
    await store.receive(\.submitOperationFinished)
    #expect(store.state.submitOperation?.outcome == .accepted)
    await store.send(.gatewayEvent(.messageComplete(text: "done", usage: nil)))
    #expect(!store.state.legacyStagingBlocked)
    #expect(store.state.attachmentReceipts.isEmpty)
    await store.send(.binding(.set(\.composerText, "next")))
    #expect(store.state.canSend, "the same chat can send again after a matching definitive success")
    await store.send(.composerSubmitted)
    await store.finish()
    #expect(calls.value.filter { $0 == "prompt.submit" }.count == 2)
  }

  @Test func unknownSubmitAfterHydrateStaysProtected() async {
    let ack = AsyncStream<Void>.makeStream(), started = AsyncStream<Void>.makeStream()
    let calls = LockIsolated<[String]>([])
    let store = makeStore(items: [image("one.png")], ackGate: ack.stream, started: started.continuation,
                          calls: calls, submitError: GatewayError.timedOut(method: "prompt.submit"))
    await store.send(.composerSubmitted)
    for await _ in started.stream { break }
    await store.receive(\.attachmentAcknowledged)
    await store.send(.activateResult(.success(ActivateResponse(sessionID: "live", storedSessionID: "stored", running: false))))
    ack.continuation.finish()
    await store.receive(\.submitOperationFinished)
    await store.send(.gatewayEvent(.messageComplete(text: "", usage: nil)))
    #expect(store.state.legacyStagingBlocked)
    #expect(store.state.deliveryBlocked)
    #expect(!store.state.attachmentReceipts.isEmpty, "staging receipts are preserved")
    await store.finish()
  }

  @Test func acceptanceOfAnotherOperationDoesNotClearUnrelatedStaging() async {
    // A sticky staging reason (here: removal of a staged chip) is not resolved by acceptance
    // of a different, current operation, and its persisted recovery fence is kept.
    var initial = ChatFeature.State(connection: ServerConnection(baseURL: URL(string: "http://test")!, token: "t"), status: .ready)
    initial.liveSessionID = "live"
    let staged = image("old.png")
    initial.attachments = [staged]
    initial.attachmentReceipts[staged.id] = AttachmentReceipt(sessionID: "live", ref: nil)
    let removal = plainStore(initial)
    await removal.send(.removeAttachment(id: staged.id))
    #expect(removal.state.legacyStagingBlocked)
    #expect(removal.state.stagingBlockOwner == nil)

    let current = UUID()
    initial.attachments = []
    initial.legacyStagingBlocked = true
    initial.submitOperation = SubmitOperation(id: current, sessionID: "live")
    initial.submitRecoveryKeys = [initial.recoveryKey(for: "live")]
    let cleared = LockIsolated<[String]>([])
    let store = plainStore(initial)
    store.dependencies.deliveryRecovery.setBlocked = { key, blocked in if !blocked { cleared.withValue { $0.append(key) } } }
    store.dependencies.deliveryRecovery.saveOperation = { _, _ in }
    await store.send(.submitOperationFinished(id: current, outcome: .accepted, message: nil))
    #expect(cleared.value.isEmpty, "the persisted fence survives while the sticky latch remains")
    #expect(store.state.legacyStagingBlocked, "an unattributed sticky latch survives unrelated acceptance")
    #expect(store.state.attachmentReceipts[staged.id] != nil, "staging receipts are preserved")
    #expect(store.state.deliveryBlocked)
  }

  @Test func staleAcceptanceCannotClearNewerOperationsHydrateAmbiguity() async {
    var initial = ChatFeature.State(connection: ServerConnection(baseURL: URL(string: "http://test")!, token: "t"), status: .ready)
    initial.liveSessionID = "live"
    let a = UUID(), b = UUID(), item = UUID()
    initial.submitOperation = SubmitOperation(id: b, sessionID: "live")
    initial.attachmentReceipts[item] = AttachmentReceipt(sessionID: "live", ref: nil, operationID: b)
    let store = plainStore(initial)
    await store.send(.activateResult(.success(ActivateResponse(sessionID: "live", running: true))))
    #expect(store.state.legacyStagingBlocked)
    await store.send(.submitOperationFinished(id: a, outcome: .accepted, message: nil))
    #expect(store.state.legacyStagingBlocked)
    // Receipts staged by another operation make the hydrate ambiguity unattributable.
    initial.attachmentReceipts[UUID()] = AttachmentReceipt(sessionID: "live", ref: nil, operationID: a)
    let mixed = plainStore(initial)
    await mixed.send(.activateResult(.success(ActivateResponse(sessionID: "live", running: true))))
    await mixed.send(.submitOperationFinished(id: b, outcome: .accepted, message: nil))
    #expect(mixed.state.legacyStagingBlocked, "foreign staged batch stays protected")
    #expect(mixed.state.attachmentReceipts.count == 1)
  }

  @Test func hydrateOfReplacedSessionStaysProtected() async {
    var initial = ChatFeature.State(connection: ServerConnection(baseURL: URL(string: "http://test")!, token: "t"), status: .ready)
    initial.liveSessionID = "live"
    let b = UUID()
    initial.submitOperation = SubmitOperation(id: b, sessionID: "live")
    initial.attachmentReceipts[UUID()] = AttachmentReceipt(sessionID: "live", ref: nil, operationID: b)
    let store = plainStore(initial)
    await store.send(.activateResult(.success(ActivateResponse(sessionID: "replacement", running: true))))
    await store.send(.submitOperationFinished(id: b, outcome: .accepted, message: nil))
    #expect(store.state.legacyStagingBlocked, "a replaced session cannot prove the old staging was consumed")
  }

  @Test(arguments: ["socketClosed", "uncertainPDF"])
  func stickyReasonBeforeOrAfterHydrateStaysProtected(reason: String) async {
    // The current operation owns every receipt, but a sticky reason intervenes: the
    // hydrate must not adopt (socket close first) nor may acceptance lift it.
    var initial = ChatFeature.State(connection: ServerConnection(baseURL: URL(string: "http://test")!, token: "t"), status: .ready)
    initial.liveSessionID = "live"
    let op = UUID(), item = UUID()
    initial.submitOperation = SubmitOperation(id: op, sessionID: "live")
    initial.attachmentReceipts[item] = AttachmentReceipt(sessionID: "live", ref: nil, operationID: op)
    let store = plainStore(initial)
    if reason == "socketClosed" {
      await store.send(.gatewayClosed)
      await store.send(.activateResult(.success(ActivateResponse(sessionID: "live", running: true))))
      #expect(store.state.stagingBlockOwner == nil, "an already-sticky latch is never adopted")
      await store.send(.submitOperationFinished(id: op, outcome: .accepted, message: nil))
    } else {
      await store.send(.activateResult(.success(ActivateResponse(sessionID: "live", running: true))))
      #expect(store.state.stagingBlockOwner == op)
      await store.send(.attachmentAttemptFailed(operationID: op, uncertain: true, message: "partial pdf"))
      #expect(store.state.stagingBlockOwner == nil)
      await store.send(.submitOperationFinished(id: op, outcome: .accepted, message: nil))
    }
    #expect(store.state.legacyStagingBlocked)
    #expect(store.state.deliveryBlocked)
  }

  @Test func receiptFromAnotherSessionIsNotAttributed() async {
    var initial = ChatFeature.State(connection: ServerConnection(baseURL: URL(string: "http://test")!, token: "t"), status: .ready)
    initial.liveSessionID = "live"
    let op = UUID()
    initial.submitOperation = SubmitOperation(id: op, sessionID: "live")
    initial.attachmentReceipts[UUID()] = AttachmentReceipt(sessionID: "old", ref: nil, operationID: op)
    let store = plainStore(initial)
    await store.send(.activateResult(.success(ActivateResponse(sessionID: "live", running: true))))
    #expect(store.state.stagingBlockOwner == nil)
    #expect(store.state.legacyStagingBlocked)
  }
}
