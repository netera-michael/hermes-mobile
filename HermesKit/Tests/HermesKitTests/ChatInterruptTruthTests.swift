import ComposableArchitecture
import Foundation
import Testing

@testable import HermesKit

@MainActor
struct ChatInterruptTruthTests {
  private func uuid(_ n: Int) -> UUID {
    UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012x", n))")!
  }

  private func makeStore(
    calls: LockIsolated<[String]>,
    resume: (@Sendable () async throws -> JSONValue)? = nil,
    interrupt: @escaping @Sendable () async throws -> JSONValue
  ) -> TestStoreOf<ChatFeature> {
    var state = ChatFeature.State(connection: ServerConnection(baseURL: URL(string: "http://test:9119")!, token: "t"))
    state.liveSessionID = "live123"
    state.storedSessionID = "stored123"
    state.status = .ready
    state.isSending = true
    state.isQueueParked = true
    state.queuedPrompts = [QueuedPrompt(id: uuid(90), text: "first"), QueuedPrompt(id: uuid(91), text: "second")]
    let store = TestStore(initialState: state) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.chatSnapshot = .inMemory()
      $0.continuousClock = TestClock()
      $0.hermesGateway.send = { method, _ in
        calls.withValue { $0.append(method) }
        if method == "session.resume", let resume { return try await resume() }
        if method == "session.interrupt" { return try await interrupt() }
        return .object(["status": .string("streaming")])
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    return store
  }

  @Test func interruptRejectionKeepsQueueAndShowsTruth() async {
    let calls = LockIsolated<[String]>([])
    let store = makeStore(calls: calls) { throw GatewayError.server("interrupt refused") }
    await store.send(.queuedPromptSendNow(id: uuid(90)))
    await store.receive(\.sessionInterruptResult)
    #expect(store.state.interruptOperation?.outcome == .rejected)
    #expect(store.state.isSending, "rejection must restore truthful running state")
    #expect(store.state.deliveryBlocked)
    #expect(store.state.queuedPrompts.map(\.text) == ["first", "second"])
    #expect(store.state.errorBanner?.contains("try Stop again") == true)
    #expect(store.state.queueWaitsToSend)
    #expect(store.state.queueDeliveryBlocked)
    #expect(!store.state.isQueueParked)
    await store.send(.maybeDrainQueue)
    #expect(!calls.value.contains("prompt.submit"))
    await store.send(.gatewayEvent(.messageComplete(text: "", usage: nil)))
    await store.receive(\.submitOperationFinished)
    #expect(calls.value.filter { $0 == "prompt.submit" }.count == 1)
    #expect(store.state.queuedPrompts.map(\.text) == ["second"])
    await store.finish()
  }

  @Test func lostACKBlocksDeliveryUntilAuthority() async {
    let calls = LockIsolated<[String]>([])
    let store = makeStore(calls: calls) { throw GatewayError.disconnected }
    await store.send(.queuedPromptSendNow(id: uuid(90)))
    await store.receive(\.sessionInterruptResult)
    #expect(store.state.interruptOperation?.outcome == .unknown)
    #expect(store.state.deliveryBlocked)
    #expect(store.state.errorBanner?.contains("unknown") == true)
    await store.send(.maybeDrainQueue)
    #expect(store.state.queuedPrompts.count == 2)
    #expect(!calls.value.contains("prompt.submit"))
    await store.send(.gatewayEvent(.messageComplete(text: "", usage: nil)))
    await store.receive(\.submitOperationFinished)
    #expect(store.state.interruptOperation == nil)
    #expect(calls.value.filter { $0 == "prompt.submit" }.count == 1)
    #expect(store.state.queuedPrompts.map(\.text) == ["second"])
    await store.finish()
  }

  @Test func ackWhileStillRunningCannotDrain() async {
    let calls = LockIsolated<[String]>([])
    let store = makeStore(calls: calls) { .object([:]) }
    await store.send(.queuedPromptSendNow(id: uuid(90)))
    await store.receive(\.sessionInterruptResult)
    #expect(store.state.interruptOperation?.outcome == .accepted)
    #expect(store.state.deliveryBlocked, "even a silent tool-running turn must remain gated")
    await store.send(.maybeDrainQueue)
    await store.send(.gatewayEvent(.messageDelta(text: "still streaming")))
    #expect(store.state.isSending)
    #expect(store.state.queuedPrompts.count == 2)
    #expect(!calls.value.contains("prompt.submit"))
    await store.send(.gatewayEvent(.messageComplete(text: "", usage: nil)))
    await store.receive(\.submitOperationFinished)
    #expect(calls.value.filter { $0 == "prompt.submit" }.count == 1)
    await store.finish()
  }

  @Test func terminalBeforeACKDrainsOnceNotTwice() async {
    let calls = LockIsolated<[String]>([])
    let gate = AsyncStream<Void>.makeStream()
    let store = makeStore(calls: calls) {
      for await _ in gate.stream {}
      return .object([:])
    }
    await store.send(.queuedPromptSendNow(id: uuid(90)))
    #expect(store.state.errorBanner?.contains("Requesting Stop") == true)
    #expect(store.state.queueWaitsToSend)
    #expect(store.state.queueDeliveryBlocked)
    let oldID = store.state.interruptOperation!.id
    #expect(store.state.queuedPrompts.count == 2)
    await store.send(.gatewayEvent(.error(message: "interrupted")))
    await store.receive(\.submitOperationFinished)
    #expect(store.state.interruptOperation == nil)
    #expect(calls.value.filter { $0 == "prompt.submit" }.count == 1, "terminal authority must not wait for an ACK that may never arrive")
    #expect(store.state.queuedPrompts.map(\.text) == ["second"])
    gate.continuation.finish()
    await store.receive(\.sessionInterruptResult)
    await store.send(.sessionInterruptResult(operationID: oldID, outcome: .unknown, error: .disconnected))
    #expect(store.state.interruptOperation == nil)
    #expect(store.state.queuedPrompts.map(\.text) == ["second"])
    #expect(calls.value.filter { $0 == "prompt.submit" }.count == 1)
    await store.finish()
  }

  @Test func onlyExplicitIdleHydrateReleasesInterruption() async {
    let calls = LockIsolated<[String]>([])
    let store = makeStore(calls: calls) { throw GatewayError.disconnected }
    await store.send(.queuedPromptSendNow(id: uuid(90)))
    await store.receive(\.sessionInterruptResult)
    for running: Bool? in [true, nil] {
      await store.send(.activateResult(.success(
        ActivateResponse(sessionID: "live123", storedSessionID: "stored123", running: running)
      )))
      #expect(store.state.interruptOperation != nil)
      #expect(store.state.queuedPrompts.count == 2)
      #expect(!calls.value.contains("prompt.submit"))
    }
    await store.send(.activateResult(.success(
      ActivateResponse(sessionID: "live123", storedSessionID: "stored123", running: false)
    )))
    await store.receive(\.submitOperationFinished)
    #expect(store.state.interruptOperation == nil)
    #expect(store.state.queuedPrompts.map(\.text) == ["second"])
    #expect(calls.value.filter { $0 == "prompt.submit" }.count == 1)
    await store.send(.teardown)
    await store.finish()
  }

  @Test func queueRemainsEditableWhileInterruptPending() async {
    let calls = LockIsolated<[String]>([])
    let store = makeStore(calls: calls) { .object([:]) }
    await store.send(.queuedPromptSendNow(id: uuid(90)))
    await store.receive(\.sessionInterruptResult)
    await store.send(.queuedPromptDeleted(id: uuid(91)))
    await store.send(.queuedPromptEditTapped(id: uuid(90)))
    #expect(store.state.queuedPrompts.isEmpty)
    #expect(store.state.composerText == "first")
    #expect(store.state.deliveryBlocked)
    #expect(!calls.value.contains("prompt.submit"))
    await store.finish()
  }

  @Test(arguments: ["missing", "running", "failure"])
  func replayCannotSettleInterrupt(mode: String) async {
    let calls = LockIsolated<[String]>([])
    let gate = AsyncStream<Void>.makeStream()
    let store = makeStore(calls: calls, resume: {
      for await _ in gate.stream {}
      if mode == "failure" { throw GatewayError.server("resume unavailable") }
      var result: [String: JSONValue] = ["session_id": .string("live123")]
      if mode == "running" { result["running"] = .bool(true) }
      return .object(result)
    }, interrupt: { throw GatewayError.disconnected })
    await store.send(.queuedPromptSendNow(id: uuid(90)))
    await store.receive(\.sessionInterruptResult)
    let pending = store.state.interruptOperation
    await store.send(.gatewayEvent(GatewayFrame(.messageDelta(text: "working"), sessionID: "live123", seq: 1)))
    await store.send(.replayResult(.success(ReplayBatch(events: [
      GatewayFrame(.messageComplete(text: "historical", usage: nil), sessionID: "live123", seq: 2)
    ]))))
    #expect(store.state.interruptOperation == pending)
    #expect(store.state.queuedPrompts.count == 2)
    #expect(!calls.value.contains("prompt.submit"))
    gate.continuation.finish()
    await store.receive(\.activateResult)
    #expect(store.state.interruptOperation == pending)
    #expect(store.state.deliveryBlocked)
    #expect(store.state.errorBanner != nil)
    #expect(store.state.queuedPrompts.count == 2)
    #expect(!calls.value.contains("prompt.submit"))
    await store.send(.teardown)
    await store.finish()
  }

  @Test func heldIdleCannotOverrideNewLiveStartAndStop() async {
    let calls = LockIsolated<[String]>([])
    let gate = AsyncStream<Void>.makeStream()
    let freshGate = AsyncStream<Void>.makeStream()
    let resumes = LockIsolated(0)
    let store = makeStore(calls: calls, resume: {
      let attempt = resumes.withValue { $0 += 1; return $0 }
      if attempt == 1 { for await _ in gate.stream {} }
      else { for await _ in freshGate.stream {} }
      return .object(["session_id": .string("live123"), "running": .bool(attempt != 1)])
    }, interrupt: { .object([:]) })
    await store.send(.replayResult(.success(ReplayBatch())))
    await store.send(.gatewayEvent(.messageStart))
    await store.send(.interruptTapped)
    await store.receive(\.sessionInterruptResult)
    let pending = store.state.interruptOperation
    gate.continuation.finish()
    await store.receive(\.activateResult)
    #expect(store.state.interruptOperation == pending)
    #expect(store.state.deliveryBlocked)
    #expect(store.state.queuedPrompts.count == 2)
    #expect(!calls.value.contains("prompt.submit"))
    freshGate.continuation.finish()
    await store.receive(\.activateResult)
    #expect(resumes.value == 2)
    #expect(!store.state.isCatchingUp)
    #expect(store.state.isSending)
    #expect(store.state.interruptOperation == pending)
    #expect(store.state.errorBanner == store.state.interruptBanner)
    await store.send(.teardown)
    await store.finish()
  }

  @Test(arguments: [false, true])
  func foreignTerminalCannotSettleInterrupt(isError: Bool) async {
    let calls = LockIsolated<[String]>([])
    let store = makeStore(calls: calls) { .object([:]) }
    await store.send(.queuedPromptSendNow(id: uuid(90)))
    await store.receive(\.sessionInterruptResult)
    let pending = store.state.interruptOperation
    let event: GatewayEvent = isError ? .error(message: "old error") : .messageComplete(text: "old", usage: nil)
    await store.send(.gatewayEvent(GatewayFrame(event, sessionID: "old-runtime")))
    #expect(store.state.interruptOperation == pending)
    #expect(store.state.queuedPrompts.count == 2)
    #expect(!calls.value.contains("prompt.submit"))
    await store.send(.gatewayEvent(GatewayFrame(.messageComplete(text: "done", usage: nil), sessionID: "live123")))
    await store.receive(\.submitOperationFinished)
    #expect(calls.value.filter { $0 == "prompt.submit" }.count == 1)
    await store.send(.teardown)
    await store.finish()
  }

  @Test func manualStopPresentationSettlesButUnrelatedErrorsSurvive() async {
    let calls = LockIsolated<[String]>([])
    let store = makeStore(calls: calls) { .object([:]) }
    await store.send(.interruptTapped)
    await store.receive(\.sessionInterruptResult)
    #expect(store.state.errorBanner != nil)
    #expect(!store.state.queueWaitsToSend)
    #expect(store.state.queueDeliveryBlocked)
    await store.send(.gatewayEvent(.messageComplete(text: "done", usage: nil)))
    #expect(store.state.interruptOperation == nil)
    #expect(store.state.errorBanner == nil)
    #expect(store.state.isQueueParked)
    #expect(!calls.value.contains("prompt.submit"))
    await store.send(.interruptTapped)
    await store.receive(\.sessionInterruptResult)
    await store.send(.gatewayEvent(.error(message: "independent failure")))
    #expect(store.state.errorBanner == "independent failure")
    await store.finish()
  }

  @Test(arguments: [false, true])
  func heldRunningCannotOverrideTerminalOrNewTurn(newTurn: Bool) async {
    let calls = LockIsolated<[String]>([])
    let oldGate = AsyncStream<Void>.makeStream()
    let freshGate = AsyncStream<Void>.makeStream()
    let resumes = LockIsolated(0)
    let store = makeStore(calls: calls, resume: {
      let attempt = resumes.withValue { $0 += 1; return $0 }
      if attempt == 1 { for await _ in oldGate.stream {} }
      else { for await _ in freshGate.stream {} }
      return .object(["session_id": .string("live123"), "running": .bool(attempt == 1 || newTurn)])
    }, interrupt: { .object([:]) })
    await store.send(.queuedPromptSendNow(id: uuid(90)))
    await store.receive(\.sessionInterruptResult)
    await store.send(.replayResult(.success(ReplayBatch())))
    await store.send(.gatewayEvent(.messageComplete(text: "done", usage: nil)))
    if newTurn { await store.send(.gatewayEvent(.messageStart)) }
    oldGate.continuation.finish()
    await store.receive(\.activateResult)
    #expect(store.state.isSending == newTurn)
    #expect(store.state.isCatchingUp)
    #expect(store.state.queuedPrompts.count == 2)
    #expect(!calls.value.contains("prompt.submit"))
    freshGate.continuation.finish()
    await store.receive(\.activateResult)
    #expect(!store.state.isCatchingUp)
    #expect(resumes.value == 2)
    if newTurn {
      #expect(store.state.isSending)
      #expect(store.state.queuedPrompts.count == 2)
      #expect(!calls.value.contains("prompt.submit"))
      await store.send(.gatewayEvent(.messageComplete(text: "new done", usage: nil)))
    }
    await store.receive(\.submitOperationFinished)
    #expect(calls.value.filter { $0 == "prompt.submit" }.count == 1)
    await store.send(.teardown)
    await store.finish()
  }

  @Test func runtimeReplacementRejectsHeldIdleAndOldSocketTerminal() async {
    let calls = LockIsolated<[String]>([])
    let oldGate = AsyncStream<Void>.makeStream()
    let freshGate = AsyncStream<Void>.makeStream()
    let resumes = LockIsolated(0)
    let store = makeStore(calls: calls, resume: {
      let attempt = resumes.withValue { $0 += 1; return $0 }
      if attempt == 1 { for await _ in oldGate.stream {} }
      else { for await _ in freshGate.stream {} }
      return .object(["session_id": .string(attempt == 1 ? "live123" : "replacement"), "running": .bool(attempt != 1)])
    }, interrupt: { .object([:]) })
    await store.send(.replayResult(.success(ReplayBatch())))
    await store.send(.liveSessionIDRefreshed(liveSessionID: "replacement", storedSessionID: "stored123"))
    await store.send(.interruptTapped)
    await store.receive(\.sessionInterruptResult)
    let pending = store.state.interruptOperation
    let oldGeneration = store.state.subagentActivity.generation - 1
    await store.send(.checklistFrame(generation: oldGeneration,
      GatewayFrame(.messageComplete(text: "old socket", usage: nil), sessionID: "replacement")))
    oldGate.continuation.finish()
    await store.receive(\.activateResult)
    #expect(store.state.liveSessionID == "replacement")
    #expect(store.state.interruptOperation == pending)
    #expect(store.state.queuedPrompts.count == 2)
    #expect(!calls.value.contains("prompt.submit"))
    freshGate.continuation.finish()
    await store.receive(\.activateResult)
    #expect(resumes.value == 2)
    #expect(!store.state.isCatchingUp)
    #expect(store.state.isSending)
    #expect(store.state.interruptOperation == pending)
    await store.send(.teardown)
    await store.finish()
  }

  @Test func staleInterruptACKAfterAnotherRequestIsIgnored() async {
    let calls = LockIsolated<[String]>([])
    let gate = AsyncStream<Void>.makeStream()
    let store = makeStore(calls: calls) {
      for await _ in gate.stream {}
      return .object([:])
    }
    await store.send(.interruptTapped)
    let firstID = store.state.interruptOperation!.id
    await store.send(.interruptTapped)
    let secondID = store.state.interruptOperation!.id
    #expect(firstID != secondID)
    await store.send(.sessionInterruptResult(operationID: firstID, outcome: .accepted, error: nil))
    #expect(store.state.interruptOperation?.id == secondID)
    #expect(store.state.interruptOperation?.outcome == .submitting)
    #expect(store.state.deliveryBlocked)
    #expect(store.state.queuedPrompts.count == 2)
    gate.continuation.finish()
    await store.finish()
    #expect(!calls.value.contains("prompt.submit"))
  }
}
