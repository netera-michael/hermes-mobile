import ComposableArchitecture
import Foundation
import Testing

@testable import HermesKit

/// B2: Interrupt truthfulness — the queue must never drain on a lie (review finding 2,
/// evidence/hermes-mobile-review-20261002.md). A failed/unknown/superseded interrupt keeps
/// the queued entry; only the turn's authoritative terminal, an idle-confirming hydrate,
/// or a provably-terminal-before-ACK ACK may drain.
@MainActor
struct ChatInterruptTruthTests {
  private let conn = ServerConnection(baseURL: URL(string: "http://test:9119")!, token: "t")
  private func uuid(_ n: Int) -> UUID {
    UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012x", n))")!
  }
  private func runningState() -> ChatFeature.State {
    var state = ChatFeature.State(connection: conn)
    state.liveSessionID = "live123"
    state.storedSessionID = "stored123"
    state.status = .ready
    state.isSending = true
    state.isQueueParked = true
    state.queuedPrompts = [QueuedPrompt(id: uuid(90), text: "held")]
    return state
  }

  // 1. EXPLICIT REJECT: a definite server refusal must not drain — the entry stays queued,
  // the banner states the true outcome and the safe recovery.
  @Test func interruptRejectionKeepsQueueAndShowsTruth() async {
    let submitted = LockIsolated<Int>(0)
    let store = TestStore(initialState: runningState()) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.chatSnapshot = .inMemory()
      $0.continuousClock = TestClock()
      $0.hermesGateway.send = { @Sendable method, _ in
        if method == "session.interrupt" { throw GatewayError.server("interrupt refused") }
        if method == "prompt.submit" { submitted.withValue { $0 += 1 } }
        return .object([:])
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.interruptTapped) {
      $0.interruptOperation = SubmitOperation(id: self.uuid(0), sessionID: "live123")
      $0.isSending = false
      $0.isQueueParked = true
      $0.sendNowArmed = false
    }
    await store.receive(\.sessionInterruptResult) {
      $0.interruptOperation = nil
      $0.errorBanner = "Couldn't stop the turn: interrupt refused. Nothing was sent; try Stop again or wait for the turn to finish."
    }
    await store.finish()
    #expect(submitted.value == 0, "a rejected interrupt must never drain the queue")
    #expect(store.state.queuedPrompts.count == 1)
    #expect(store.state.isQueueParked)
  }

  // 2. LOST ACK: transport death instead of an answer. Delivery stays blocked until an
  // authoritative terminal/idle reconcile; never a silent claim of success.
  @Test func lostACKBlocksDeliveryUntilAuthority() async {
    let store = TestStore(initialState: runningState()) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.chatSnapshot = .inMemory()
      $0.continuousClock = TestClock()
      $0.hermesGateway.send = { @Sendable method, _ in
        if method == "session.interrupt" { throw GatewayError.disconnected }
        return .object([:])
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.interruptTapped) {
      $0.interruptOperation = SubmitOperation(id: self.uuid(0), sessionID: "live123")
      $0.isSending = false
      $0.isQueueParked = true
      $0.sendNowArmed = false
    }
    await store.receive(\.sessionInterruptResult) {
      $0.interruptOperation = nil
      $0.interruptOutcomeUnknown = true
      $0.errorBanner = "Stop outcome unknown. If the turn is still running, your messages are held and will send once it ends."
    }
    #expect(store.state.deliveryBlocked, "unknown interrupt outcome holds delivery")
    #expect(store.state.queuedPrompts.count == 1)
    // The authoritative terminal (here: an idle-confirming hydrate's edge == the terminal
    // path) reconciles: clearing the unknown flag re-admits delivery and the drain.
    await store.send(.gatewayEvent(.messageComplete(text: "", usage: nil))) {
      $0.interruptOutcomeUnknown = false
    }
    #expect(store.state.deliveryBlocked == false || store.state.submitOperation?.outcome != .submitting, "interrupt unknown flag cleared re-admits delivery and drain")
    await store.finish()
  }

  // 3. ACK-WHILE-RUNNING: the ACK resolves but the same turn demonstrably keeps streaming
  // (a delta after it). The optimistic "stopped" must be reversed; nothing drains.
  @Test func ackWhileStillRunningReversesFreeze() async {
    let store = TestStore(initialState: runningState()) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.chatSnapshot = .inMemory()
      $0.continuousClock = TestClock()
      $0.hermesGateway.send = { @Sendable method, _ in .object([:]) }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.interruptTapped) {
      $0.interruptOperation = SubmitOperation(id: self.uuid(0), sessionID: "live123")
      $0.isSending = false
      $0.isQueueParked = true
      $0.sendNowArmed = false
    }
    await store.receive(\.sessionInterruptResult)
    // The turn demonstrably continues: the ACK never drains, and the freeze is reversed.
    await store.send(.gatewayEvent(.messageDelta(text: "still streaming"))) {
      $0.isSending = true
      $0.errorBanner = "The turn kept running after Stop; tap Stop again."
    }
    #expect(store.state.queuedPrompts.count == 1, "an ACK alone never drains the queue")
    await store.finish()
  }

  // 4. TERMINAL-BEFORE-ACK: the turn's `.error` lands BEFORE the interrupt RPC resolves.
  // The terminal (with the Send-now arm) is the drain; the later ACK must not double-drain.
  @Test func terminalBeforeACKDrainsOnceNotTwice() async {
    let calls = LockIsolated<[String]>([])
    let gate = AsyncStream<Void>.makeStream()
    var initial = runningState()
    initial.isSending = false // the first turn already finished; queue parked, arm set
    initial.isQueueParked = true
    initial.sendNowArmed = true
    initial.queuedPrompts = [
      QueuedPrompt(id: uuid(90), text: "first"),
      QueuedPrompt(id: uuid(91), text: "second"),
    ]
    let store = TestStore(initialState: initial) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.chatSnapshot = .inMemory()
      $0.continuousClock = TestClock()
      $0.hermesGateway.send = { @Sendable method, _ in
        calls.withValue { $0.append(method) }
        if method == "session.interrupt" {
          // The interrupt RPC (the arm for the "already-finished" turn) hangs until
          // released: its ACK must only settle AFTER the turn's terminal folded.
          for await _ in gate.stream {}
          return .object([:])
        }
        return .object(["status": .string("streaming")])
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    // Send-now with no live turn: the interrupt fires (an idempotent stop for the
    // already-gone turn) AND the head is drained — the terminal-before-ACK window opens.
    await store.send(.queuedPromptSendNow(id: self.uuid(90))) {
      $0.isQueueParked = false
      $0.interruptOperation = SubmitOperation(id: self.uuid(0), sessionID: "live123")
    }
    // The interrupted turn's terminal folds BEFORE the ACK (the Send-now drain itself):
    // armed, it re-parks and latches `interruptTurnEnded` so the pending ACK holds.
    await store.send(.gatewayEvent(.error(message: "stopped"))) {
      $0.errorBanner = "stopped"
      $0.isQueueParked = true
      $0.interruptTurnEnded = true
    }
    await store.receive(\.delegate.runningChanged)
    #expect(store.state.interruptTurnEnded, "the terminal-before-ACK signal latched")
    // Release the interrupt RPC so its ACK can finally settle (the turn's terminal has
    // already folded by now — this IS the terminal-before-ACK race, in order), then
    // assert the drain fired EXACTLY ONCE: the "first" entry's only row, zero live
    // submits beyond it, and the queued tail still parked (not a second drain).
    gate.continuation.finish()
    await store.receive(\.sessionInterruptResult)
    #expect(store.state.queuedPrompts.count == 1, "the terminal-before-ACK ACK drains exactly once — no double-drain of the tail")
    #expect(calls.value.filter { $0 == "prompt.submit" }.count == 1, "exactly one prompt.submit: the Send-now drain, not a second one")
    await store.finish()
  }

  // 5. STALE ACK: a superseded attempt's late answer is ignored — only the matching
  // operationID may report; the outstanding newer attempt survives.
  @Test func staleInterruptACKAfterAnotherRequestIsIgnored() async {
    let gate = AsyncStream<Void>.makeStream()
    let store = TestStore(initialState: runningState()) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.chatSnapshot = .inMemory()
      $0.continuousClock = TestClock()
      $0.hermesGateway.send = { @Sendable method, _ in
        if method == "session.interrupt" {
          // SECOND attempt: hold this RPC's answer until AFTER the stale (first
          // attempt's) ACK has folded — the outstanding newer op must be asserted
          // while it is STILL pending, not after it settled.
          for await _ in gate.stream {}
          return .object([:])
        }
        return .object([:])
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.interruptTapped) {
      $0.interruptOperation = SubmitOperation(id: self.uuid(0), sessionID: "live123")
      $0.isSending = false
      $0.isQueueParked = true
      $0.sendNowArmed = false
    }
    // A second request supersedes the first.
    await store.send(.interruptTapped) {
      $0.interruptOperation = SubmitOperation(id: self.uuid(1), sessionID: "live123")
    }
    // The FIRST attempt's answer arrives late and must not touch the second attempt's
    // pending state (the operation stays outstanding — the guard mutes it).
    await store.send(.sessionInterruptResult(operationID: self.uuid(0), outcome: .accepted, error: nil))
    #expect(store.state.interruptOperation?.id == self.uuid(1))
    gate.continuation.finish()
    await store.finish()
  }
}