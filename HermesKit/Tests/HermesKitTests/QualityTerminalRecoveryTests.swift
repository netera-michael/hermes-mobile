import ComposableArchitecture
import Foundation
import Testing
@testable import HermesKit

@MainActor
@Suite struct QualityTerminalRecoveryTests {
  @Test
  func terminalRecoveryOwnershipMatrix() async {
    for fence in ["submit", "steer", "durable", "staging", "clean"] {
      for banner in ["owned", "missing", "unrelated"] {
        var initial = ChatFeature.State(connection: ServerConnection(baseURL: URL(string: "http://test")!, token: "t"), status: .ready)
        initial.liveSessionID = "live"
        initial.isSending = true
        initial.composerText = "retained"
        let operation = SubmitOperation(id: UUID(), sessionID: "live", outcome: .unknown)
        if fence == "submit" { initial.submitOperation = operation }
        if fence == "steer" { initial.steerOperation = operation }
        if fence == "staging" { initial.legacyStagingBlocked = true }
        if fence == "durable" { initial.durableDeliveryKey = DurableDeliveryKey(operationID: UUID(), storedSessionID: "stored", profile: "default") }
        let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
          $0.uuid = .incrementing
          $0.date = .constant(Date(timeIntervalSince1970: 0))
          $0.chatSnapshot = .inMemory()
          $0.continuousClock = ImmediateClock()
          $0.hermesGateway.send = { _, _ in .object([:]) }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        if banner != "missing" {
          await store.send(.interruptTapped)
          await store.receive(\.sessionInterruptResult)
        }
        if banner == "unrelated" {
          await store.send(.renameFailed(previousTitle: nil))
        }
        // Missing guidance is exercised on a no-Stop terminal below; owned text
        // and unrelated errors exercise retirement of a real accepted Stop.
        await store.send(.checklistFrame(generation: store.state.subagentActivity.generation,
          GatewayFrame(.messageComplete(text: "", usage: nil), sessionID: "live")))
        #expect(store.state.interruptOperation == nil)
        #expect(store.state.deliveryBlocked == (fence != "clean"))
        if banner == "unrelated" { #expect(store.state.errorBanner == "Couldn’t rename the session.") }
        else if fence == "clean" { #expect(store.state.errorBanner == nil) }
        else { #expect(store.state.errorBanner != nil) }
        #expect(store.state.composerText == "retained")
        await store.send(.teardown)
        await store.finish()
      }
    }
  }

  @Test(arguments: ["submit", "steer"], ["complete", "error"])
  func terminalSettlingStopMustNotHideOtherUnknownDelivery(operation: String, terminal: String) async {
    let entry = QueuedPrompt(id: UUID(), text: "correction", attachments: [])
    var initial = ChatFeature.State(connection: ServerConnection(baseURL: URL(string: "http://test")!, token: "t"), status: .ready)
    initial.liveSessionID = "live"
    initial.isSending = operation == "steer"
    initial.composerText = operation == "submit" ? "original prompt" : "retained draft"
    if operation == "steer" { initial.queuedPrompts = [entry] }
    let calls = LockIsolated<[String]>([])
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.chatSnapshot = .inMemory()
      $0.continuousClock = ImmediateClock()
      $0.hermesGateway.send = { method, _ in
        calls.withValue { $0.append(method) }
        if method == "prompt.submit" || method == "session.steer" { throw GatewayError.timedOut(method: method) }
        return .object([:])
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    if operation == "submit" {
      await store.send(.composerSubmitted)
      await store.receive(\.submitOperationFinished)
      #expect(store.state.submitOperation?.outcome == .unknown)
    } else {
      await store.send(.queuedPromptSteer(id: entry.id))
      await store.receive(\.queuedPromptSteerResult)
      #expect(store.state.steerOperation?.outcome == .unknown)
    }
    #expect(store.state.errorBanner != nil)
    let originalSubmits = calls.value.filter { $0 == "prompt.submit" }.count
    let retainedDraft = store.state.composerText
    await store.send(.interruptTapped)
    await store.receive(\.sessionInterruptResult)
    #expect(store.state.interruptOperation?.outcome == .accepted)
    if terminal == "complete" {
      await store.send(.checklistFrame(generation: store.state.subagentActivity.generation, GatewayFrame(.messageComplete(text: "", usage: nil), sessionID: "live")))
    } else {
      await store.send(.checklistFrame(generation: store.state.subagentActivity.generation, GatewayFrame(.error(message: "Turn stopped"), sessionID: "live")))
    }
    #expect(store.state.interruptOperation == nil)
    #expect(store.state.deliveryBlocked)
    #expect(store.state.errorBanner != nil, "Settling Stop must retain recovery guidance for the still-unknown delivery")
    await store.send(.composerSubmitted)
    await store.finish()
    #expect(calls.value.filter { $0 == "prompt.submit" }.count == originalSubmits)
    #expect(store.state.composerText == retainedDraft)
    await store.send(.teardown)
    await store.finish()
  }
}
