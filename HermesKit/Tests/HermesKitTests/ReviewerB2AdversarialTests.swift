import ComposableArchitecture
import Foundation
import Testing
@testable import HermesKit

@MainActor
struct ReviewerB2AdversarialTests {
  private func makeStore(_ initial: ChatFeature.State, calls: LockIsolated<[String]>, interrupt: (@Sendable () async -> Void)? = nil, resume: @escaping @Sendable () async throws -> JSONValue) -> TestStoreOf<ChatFeature> {
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.continuousClock = TestClock()
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { method, _ in
        calls.withValue { $0.append(method) }
        if method == "session.resume" { return try await resume() }
        if method == "session.interrupt", let interrupt { await interrupt() }
        return .object([:])
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    return store
  }
  private func state() -> ChatFeature.State {
    var s = ChatFeature.State(connection: ServerConnection(baseURL: URL(string: "http://test")!, token: "t"), resumeStoredID: "stored", status: .ready)
    s.liveSessionID = "live"
    s.commandsUnsupported = true
    s.queuedPrompts = [QueuedPrompt(id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!, text: "next")]
    return s
  }

  @Test(arguments: [false, true], [false, true])
  func missingRunningAfterReplayIsNotIdleAuthority(pending: Bool, idle: Bool) async {
    var s = state()
    s.isSending = true
    s.replayCursor = .init(sessionID: "live", seq: 1)
    let calls = LockIsolated<[String]>([])
    let gate = AsyncStream<Void>.makeStream()
    let store = makeStore(s, calls: calls) {
      for await _ in gate.stream {}
      return .object(["session_id": .string("live")])
    }
    if pending {
      await store.send(.queuedPromptSendNow(id: s.queuedPrompts[0].id))
      await store.receive(\.sessionInterruptResult)
    }
    await store.send(.replayResult(.success(ReplayBatch(events: [GatewayFrame(.messageComplete(text: "old", usage: nil), sessionID: "live", seq: 2)]))))
    #expect(calls.value.filter { $0 == "prompt.submit" }.isEmpty)
    gate.continuation.finish()
    await store.receive(\.activateResult)
    await store.send(.maybeDrainQueue)
    #expect(calls.value.filter { $0 == "prompt.submit" }.isEmpty, "Omitted running after historical completion must not authorize a queued submit")
    #expect(store.state.queuedPrompts.count == 1)
    if idle {
      await store.send(.activateResult(.success(ActivateResponse(sessionID: "live", running: false))))
    } else {
      await store.send(.checklistFrame(generation: store.state.subagentActivity.generation,
        GatewayFrame(.messageComplete(text: "current", usage: nil), sessionID: "live")))
    }
    await store.receive(\.submitOperationFinished)
    await store.send(.maybeDrainQueue)
    #expect(calls.value.filter { $0 == "prompt.submit" }.count == 1)
    #expect(store.state.queuedPrompts.isEmpty)
    await store.send(.teardown)
    await store.finish()
  }

  @Test(arguments: [false, true], ["submitting", "accepted", "rejected", "unknown"])
  func liveStartKeepsUnresolvedInterruptExplanation(manual: Bool, outcome: String) async {
    var s = state(); s.isSending = true
    let calls = LockIsolated<[String]>([])
    let ack = AsyncStream<Void>.makeStream()
    let store = makeStore(s, calls: calls, interrupt: {
      for await _ in ack.stream {}
    }) { .object([:]) }
    if manual { await store.send(.interruptTapped) }
    else { await store.send(.queuedPromptSendNow(id: s.queuedPrompts[0].id)) }
    // Assert submitting before consuming the real ACK.
    if outcome != "submitting" {
      ack.continuation.finish()
      await store.receive(\.sessionInterruptResult)
      let result: SubmitOperation.Outcome = outcome == "accepted" ? .accepted : outcome == "rejected" ? .rejected : .unknown
      await store.send(.sessionInterruptResult(operationID: store.state.interruptOperation!.id, outcome: result, error: .disconnected))
    }
    let pending = store.state.interruptOperation
    await store.send(.checklistFrame(generation: store.state.subagentActivity.generation, GatewayFrame(.messageStart, sessionID: "live")))
    #expect(store.state.interruptOperation == pending)
    #expect(store.state.errorBanner == store.state.interruptBanner, "A live start cannot hide unresolved Stop recovery guidance")
    #expect(store.state.errorBanner != nil)
    #expect(store.state.queueDeliveryBlocked)
    #expect(store.state.queueWaitsToSend == !manual)
    #expect(store.state.queuedPrompts.count == 1)
    #expect(!calls.value.contains("prompt.submit"))
    if outcome == "submitting" {
      ack.continuation.finish()
      await store.receive(\.sessionInterruptResult)
    }
    await store.send(.checklistFrame(generation: store.state.subagentActivity.generation,
      GatewayFrame(.messageComplete(text: "done", usage: nil), sessionID: "live")))
    if !manual { await store.receive(\.submitOperationFinished) }
    #expect(store.state.interruptOperation == nil)
    #expect(store.state.interruptBanner == nil)
    #expect(calls.value.filter { $0 == "prompt.submit" }.count == (manual ? 0 : 1))
    await store.send(.teardown)
    await store.finish()
  }

  @Test func legacyTerminalIsScopedToCurrentSocket() async {
    var s = state(); s.isSending = true
    let calls = LockIsolated<[String]>([])
    let store = makeStore(s, calls: calls) { .object([:]) }
    await store.send(.queuedPromptSendNow(id: s.queuedPrompts[0].id))
    await store.receive(\.sessionInterruptResult)
    let generation = store.state.subagentActivity.generation
    await store.send(.checklistFrame(generation: generation - 1, GatewayFrame(.messageComplete(text: "old", usage: nil))))
    #expect(store.state.interruptOperation != nil)
    #expect(!calls.value.contains("prompt.submit"))
    await store.send(.checklistFrame(generation: generation, GatewayFrame(.messageComplete(text: "done", usage: nil))))
    await store.receive(\.submitOperationFinished)
    #expect(store.state.interruptOperation == nil)
    #expect(calls.value.filter { $0 == "prompt.submit" }.count == 1)
    await store.send(.teardown)
    await store.finish()
  }
}
