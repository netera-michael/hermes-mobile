import ComposableArchitecture
import Foundation
import Testing
@testable import HermesKit

@MainActor
@Suite struct QualityLateStartTests {
  @Test(arguments: ["staging", "submit", "steer", "clean"], ["start", "ready", "attachment", "rename"])
  func unrelatedSuccessCannotResolveRecovery(fence: String, event: String) async {
    for banner in [String?.none, "Recovery warning", "Unrelated error"] {
      var initial = ChatFeature.State(connection: ServerConnection(baseURL: URL(string: "http://test")!, token: "t"), status: .ready)
      initial.liveSessionID = "live"
      initial.hasRequestedSession = true
      initial.errorBanner = banner
      initial.legacyStagingBlocked = fence == "staging"
      if fence == "submit" { initial.submitOperation = SubmitOperation(id: UUID(), sessionID: "live", outcome: .unknown) }
      if fence == "steer" { initial.steerOperation = SubmitOperation(id: UUID(), sessionID: "live", outcome: .unknown) }
      initial.renameDraft = "Renamed"
      let calls = LockIsolated<[String]>([])
      let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
        $0.uuid = .incrementing
        $0.date = .constant(Date(timeIntervalSince1970: 0))
        $0.chatSnapshot = .inMemory()
        $0.continuousClock = ImmediateClock()
        $0.hermesGateway.send = { method, _ in calls.withValue { $0.append(method) }; return .object([:]) }
      }
      store.exhaustivity = .off(showSkippedAssertions: false)
      switch event {
      case "start": await store.send(.checklistFrame(generation: initial.subagentActivity.generation, GatewayFrame(.messageStart, sessionID: "live")))
      case "ready": await store.send(.gatewayEvent(.ready))
      case "attachment": await store.send(.attachmentAdded(ComposerAttachment(id: UUID(), kind: .image, filename: "local.png", mimeType: "image/png", data: Data([1]))))
      default: await store.send(.confirmRename)
      }
      await store.finish()
      if fence == "clean" { #expect(store.state.errorBanner == nil) }
      else {
        #expect(store.state.deliveryBlocked)
        #expect(store.state.errorBanner != nil)
        if let banner { #expect(store.state.errorBanner == banner) }
        else { #expect(store.state.errorBanner?.contains("new chat") == true) }
      }
      #expect(!calls.value.contains("prompt.submit"))
      await store.send(.teardown)
      await store.finish()
    }
  }

  @Test(arguments: [false, true], ["one.png", "two.png", "prompt.submit"])
  func lateStartMustKeepUnknownDeliveryRecovery(queued: Bool, heldStage: String) async {
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
    let receipts = store.state.attachmentReceipts
    await store.send(.attachmentAcknowledged(operationID: id, attachmentID: items[0].id, sessionID: "live", ref: "late-ref"))
    await store.send(.attachmentSubmissionAccepted(operationID: id, text: "caption", attachmentIDs: Set(items.map(\.id)), displayText: "caption", images: [], rowID: UUID(), fromQueue: queued, submitOwnership: id))
    #expect(store.state.attachmentReceipts == receipts)
    #expect(store.state.submitOperation?.outcome == .unknown)
    #expect(store.state.attachmentSubmitOwnership == nil)
    let stopID = store.state.interruptOperation!.id
    await store.send(.activateResult(.success(ActivateResponse(sessionID: "live", running: false))))
    #expect(store.state.interruptOperation == nil)
    #expect(store.state.errorBanner?.contains("new chat") == true)
    await store.send(.sessionInterruptResult(operationID: stopID, outcome: .accepted, error: nil))
    #expect(store.state.interruptOperation == nil)
    #expect(store.state.errorBanner?.contains("new chat") == true)
    // Reverse the original terminal/idle order and deliver late accepted Stop.

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
    await store.send(.checklistFrame(generation: store.state.subagentActivity.generation,
      GatewayFrame(.messageStart, sessionID: "live")))
    #expect(store.state.deliveryBlocked)
    #expect(store.state.errorBanner != nil, "A late live start cannot hide unknown attachment recovery guidance")
    #expect(calls.value.filter { $0 == "prompt.submit" }.count == submits)
    await store.send(.teardown)
    await store.finish()
  }

}
