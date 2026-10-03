import ComposableArchitecture
import Foundation
import Testing
@testable import HermesKit

@MainActor
@Suite struct SpecPostDispatchTruthTests {
  @Test(arguments: [false, true], ["one.png", "two.png", "prompt.submit"])
  func rejectedStopDoesNotClaimDispatchedPromptWasUnsent(queued: Bool, heldStage: String) async {
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
        if method == "session.interrupt" { throw GatewayError.server("Stop rejected") }
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
    await store.receive(\.sessionInterruptResult)
    #expect(store.state.interruptOperation?.outcome == .rejected)
    held.withValue { $0?.resume(); $0 = nil }
    started.continuation.finish()
    await store.finish()
    if heldStage == "prompt.submit" {
      #expect(store.state.errorBanner?.contains("Nothing was sent") != true, "Already dispatched prompt has unknown delivery; rejected Stop must not claim nothing was sent")
    }
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

}
