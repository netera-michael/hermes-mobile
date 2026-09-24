import Testing
import ComposableArchitecture
import Foundation
@testable import HermesKit

private typealias RC = ChatFeature.State.ReplayCursor

/// Lossless reconnect, Task 4: replay-then-hydrate on `.ready`.
///
/// Acceptance cases (docs/plans/20260905-lossless-reconnect-event-replay.md):
/// reconnect with a cursor sends `session.events.since` BEFORE `session.resume`; the reply
/// folds gated events in order; `truncated` / epoch-mismatch / `-32601` degrade to a plain
/// hydrate; the cursor only ever advances forward.
///
/// Assertions use `.off` exhaustivity with bare `receive()` calls and final-state `#expect`
/// probes — the applyActivate fold mutates too much state for mutation-closure assertions.
@MainActor
@Suite struct ReplayTests {
  private let conn = ServerConnection(baseURL: URL(string: "http://test")!, auth: .token("t"))

  /// A slot state that looks like "an open chat whose socket just dropped": stored session
  /// resolved, live cursor recorded. `.ready` after reconnect must take the replay path.
  private func resumedState(
    cursor: RC? = RC(sessionID: "live1", seq: 41),
    epoch: String? = "e1"
  ) -> ChatFeature.State {
    var initial = ChatFeature.State(connection: conn, resumeStoredID: "stored1", status: .reconnecting)
    initial.liveSessionID = "live1"
    initial.storedSessionID = "stored1"
    initial.hasRequestedSession = false
    initial.replayCursor = cursor
    initial.replayEpoch = epoch
    initial.replaySupported = true
    return initial
  }

  /// Records the RPC order across `hermesGateway.send` so the tests can assert replay ran
  /// before the resume hydrate.
  private final class RPCOrder: @unchecked Sendable {
    private let lock = NSLock()
    private var methods: [String] = []
    func record(_ method: String) { lock.lock(); methods.append(method); lock.unlock() }
    func snapshot() -> [String] { lock.lock(); defer { lock.unlock() }; return methods }
  }

  private func makeStore(
    _ initial: ChatFeature.State,
    replyFor: @escaping @Sendable (String) -> JSONValue,
    order: RPCOrder? = nil
  ) -> TestStore<ChatFeature.State, ChatFeature.Action> {
    let store = TestStore(initialState: initial) {
      ChatFeature()
    } withDependencies: {
      $0.hermesGateway.connect = { @Sendable _, _ in AsyncStream<GatewayFrame> { _ in } }
      $0.hermesGateway.send = { @Sendable method, _ in
        order?.record(method)
        return replyFor(method)
      }
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.chatSnapshot = .inMemory()
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    return store
  }

  /// The eventObject for a sequenced frame — the shape `session.events.since` returns in
  /// its `events` array.
  private nonisolated static func eventObject(
    _ type: String, seq: Int, payload: JSONValue = .object([:])
  ) -> JSONValue {
    .object([
      "type": .string(type),
      "session_id": .string("live1"),
      "seq": .number(Double(seq)),
      "payload": payload,
    ])
  }

  private nonisolated static var sinceReply: JSONValue {
    .object([
      "events": .array([
        Self.eventObject("tool.start", seq: 42, payload: .object(["name": .string("terminal"), "tool_id": .string("t1")])),
        Self.eventObject("tool.complete", seq: 43, payload: .object(["name": .string("terminal"), "tool_id": .string("t1"), "result_text": .string("ok")])),
      ]),
      "latest_seq": .number(43),
      "truncated": .bool(false),
      "epoch": .string("e1"),
    ])
  }

  private nonisolated static var resumeReply: JSONValue {
    .object([
      "session_id": .string("live1"),
      "stored_session_id": .string("stored1"),
      "messages": .array([
        .object(["id": .number(1), "role": .string("user"), "content": .string("prior")]),
      ]),
      "running": .bool(false),
      "info": .object([
        "model": .string("m1"),
        "usage": .object(["context_used": .number(0), "context_max": .number(1000), "context_percent": .number(0)]),
      ]),
    ])
  }

  // MARK: - Replay-before-hydrate ordering + fold

  @Test func replaySendsSinceBeforeResumeAndFoldsToolRows() async {
    let order = RPCOrder()
    let store = makeStore(resumedState(), replyFor: { method in
      method == "session.events.since" ? Self.sinceReply : Self.resumeReply
    }, order: order)
    await store.send(.gatewayEvent(GatewayFrame(.ready)))
    await store.receive(\.replayResult.success)
    await store.receive(\.activateResult.success)
    await store.finish()
    // Ordering: replay RPC before the resume RPC.
    #expect(order.snapshot().prefix(2) == ["session.events.since", "session.resume"])
    // The fold advanced the cursor through both replayed frames; the trailing hydrate
    // (running=false here) wholesale-replaces the transcript, so row survival is asserted
    // in the live-turn case, not this idle-reconnect case.
    #expect(store.state.replayCursor == RC(sessionID: "live1", seq: 43))
    #expect(store.state.status == .ready)
  }

  @Test func alreadySeenSeqInReplyIsSkipped() async {
    // Reply contains seq 41 (already folded live — cursor is at 41) plus a new seq 42.
    // Only 42 may fold; the cursor ends at 42.
    let reply: JSONValue = .object([
      "events": .array([
        Self.eventObject("message.start", seq: 41),
        Self.eventObject("message.delta", seq: 42, payload: .object(["text": .string("new")])),
      ]),
      "latest_seq": .number(42),
      "truncated": .bool(false),
      "epoch": .string("e1"),
    ])
    let store = makeStore(resumedState(), replyFor: { method in
      method == "session.events.since" ? reply : Self.resumeReply
    })
    await store.send(.gatewayEvent(GatewayFrame(.ready)))
    await store.receive(\.replayResult.success)
    await store.receive(\.activateResult.success)
    await store.finish()
    #expect(store.state.replayCursor == RC(sessionID: "live1", seq: 42))
  }

  @Test func truncatedReplySkipsFoldAndStillHydrates() async {
    let reply: JSONValue = .object([
      "events": .array([Self.eventObject("tool.start", seq: 42)]),
      "latest_seq": .number(42),
      "truncated": .bool(true),
      "epoch": .string("e1"),
    ])
    let store = makeStore(resumedState(), replyFor: { method in
      method == "session.events.since" ? reply : Self.resumeReply
    })
    await store.send(.gatewayEvent(GatewayFrame(.ready)))
    await store.receive(\.replayResult.success)
    await store.receive(\.activateResult.success)
    await store.finish()
    // Nothing folded → cursor untouched; the hydrate's single user row is the transcript.
    #expect(store.state.replayCursor == RC(sessionID: "live1", seq: 41))
    #expect(store.state.status == .ready)
  }

  @Test func epochMismatchDropsCursorAndStillHydrates() async {
    // Server restarted (e1 → e2): all recorded seqs are void.
    let reply: JSONValue = .object([
      "events": .array([Self.eventObject("tool.start", seq: 42)]),
      "latest_seq": .number(42),
      "truncated": .bool(false),
      "epoch": .string("e2"),
    ])
    let store = makeStore(resumedState(), replyFor: { method in
      method == "session.events.since" ? reply : Self.resumeReply
    })
    await store.send(.gatewayEvent(GatewayFrame(.ready)))
    await store.receive(\.replayResult.success)
    await store.receive(\.activateResult.success)
    await store.finish()
    #expect(store.state.replayCursor == nil)
    #expect(store.state.replayEpoch == "e2")
    #expect(store.state.status == .ready)
  }

  @Test func unknownMethodLatchesReplayOffForLaterReconnects() async {
    let store = TestStore(initialState: resumedState()) {
      ChatFeature()
    } withDependencies: {
      $0.hermesGateway.connect = { @Sendable _, _ in AsyncStream<GatewayFrame> { _ in } }
      $0.hermesGateway.send = { @Sendable method, _ in
        if method == "session.events.since" {
          // The server's stable unknown-method text (InboundFrame keeps no code).
          throw GatewayError.server("unknown method: session.events.since")
        }
        return Self.resumeReply
      }
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.chatSnapshot = .inMemory()
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.gatewayEvent(GatewayFrame(.ready)))
    await store.receive(\.replayResult.failure)
    await store.receive(\.activateResult.success)
    await store.finish()
    #expect(store.state.replaySupported == false)

    // Second reconnect: no replay RPC at all — hydrate directly. Drop the socket first
    // (clears hasRequestedSession), then a fresh `.ready` replays nothing.
    await store.send(.gatewayClosed) { state in
      state.status = .reconnecting
      state.reconnectAttempt = 1
    }
    await store.send(.gatewayEvent(GatewayFrame(.ready))) { state in
      state.status = .ready
      state.reconnectAttempt = 0
    }
    await store.receive(\.activateResult.success)
    await store.finish()
    #expect(store.state.replaySupported == false)
    #expect(store.state.status == .ready)
  }

  @Test func otherFailuresStillHydrate() async {
    let store = TestStore(initialState: resumedState()) {
      ChatFeature()
    } withDependencies: {
      $0.hermesGateway.connect = { @Sendable _, _ in AsyncStream<GatewayFrame> { _ in } }
      $0.hermesGateway.send = { @Sendable method, _ in
        if method == "session.events.since" {
          throw GatewayError.server("ring unavailable")
        }
        return Self.resumeReply
      }
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.chatSnapshot = .inMemory()
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.gatewayEvent(GatewayFrame(.ready)))
    await store.receive(\.replayResult.failure)
    await store.receive(\.activateResult.success)
    await store.finish()
    // Replay stayed enabled — a transient failure must not latch it off.
    #expect(store.state.replaySupported == true)
    // Cursor untouched (fold skipped).
    #expect(store.state.replayCursor == RC(sessionID: "live1", seq: 41))
    #expect(store.state.status == .ready)
  }

  @Test func noCursorGoesStraightToHydrate() async {
    let order = RPCOrder()
    let store = makeStore(resumedState(cursor: nil), replyFor: { _ in Self.resumeReply }, order: order)
    await store.send(.gatewayEvent(GatewayFrame(.ready)))
    await store.receive(\.activateResult.success)
    await store.finish()
    #expect(order.snapshot().first == "session.resume")
    #expect(!order.snapshot().contains("session.events.since"))
    #expect(store.state.status == .ready)
  }

  @Test func cursorForAnotherSessionIsIgnored() async {
    // Cursor points at a different live id (e.g. stale after a server re-mint) — no replay.
    let order = RPCOrder()
    let store = makeStore(resumedState(cursor: RC(sessionID: "other", seq: 41)), replyFor: { _ in Self.resumeReply }, order: order)
    await store.send(.gatewayEvent(GatewayFrame(.ready)))
    await store.receive(\.activateResult.success)
    await store.finish()
    #expect(order.snapshot().first == "session.resume")
    #expect(!order.snapshot().contains("session.events.since"))
  }

  @Test func emptyBatchFoldsNothingAndStillHydrates() async {
    // An object without `events` decodes as an empty batch — fold of nothing, hydrate runs.
    // (The truly malformed non-object result can't be produced through the JSON-RPC mock;
    // ReplayBatch(result:) returning nil for it is covered by the decoding tests.)
    let order = RPCOrder()
    let store = makeStore(resumedState(), replyFor: { method in
      method == "session.events.since" ? .object(["bogus": .bool(true)]) : Self.resumeReply
    }, order: order)
    await store.send(.gatewayEvent(GatewayFrame(.ready)))
    await store.receive(\.replayResult.success)
    await store.receive(\.activateResult.success)
    await store.finish()
    #expect(order.snapshot().prefix(2) == ["session.events.since", "session.resume"])
    #expect(store.state.replayCursor == RC(sessionID: "live1", seq: 41))
    #expect(store.state.status == .ready)
  }
}
