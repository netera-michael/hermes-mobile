import Testing
import ComposableArchitecture
import Foundation
@testable import HermesKit

private typealias RC = ChatFeature.State.ReplayCursor

/// Lossless reconnect, Task 5: replay + hydrate interplay under a STILL-RUNNING turn.
///
/// The #26 preservation captures live thinking/tool rows (tracked via `toolRowIDs` /
/// `thinkingRowID`) before `applyActivate`'s wholesale replace and re-appends them when
/// `running == true`. The replay fold registers rows in the same maps, so replayed rows
/// must survive the trailing hydrate exactly like live rows — and a later replayed
/// `tool.complete` must reconcile the preserved row in place.
@MainActor
@Suite struct ReplayHydrateInterplayTests {
  private let conn = ServerConnection(baseURL: URL(string: "http://test")!, auth: .token("t"))

  /// A slot state mid-turn: a live thinking row + a live tool row (t1) folded before the
  /// socket dropped, cursor at 41.
  private func runningTurnState() -> ChatFeature.State {
    var initial = ChatFeature.State(connection: conn, resumeStoredID: "stored1", status: .reconnecting)
    initial.liveSessionID = "live1"
    initial.storedSessionID = "stored1"
    initial.hasRequestedSession = false
    initial.replayCursor = RC(sessionID: "live1", seq: 41)
    initial.replayEpoch = "e1"
    initial.replaySupported = true
    // Live rows from before the drop: a running tool (t1) and the thinking row.
    let toolRow = ChatRow(id: UUID(10), kind: .tool(name: "terminal", title: "terminal", state: .running, detail: nil, durationS: nil))
    let thinkingRow = ChatRow(id: UUID(11), kind: .thinking(reasoning: "half-done", status: nil, elapsedSeconds: 3, isComplete: false))
    initial.transcript = IdentifiedArrayOf(uniqueElements: [toolRow, thinkingRow])
    initial.toolRowIDs = ["t1": UUID(10)]
    initial.thinkingRowID = UUID(11)
    initial.isSending = true
    return initial
  }

  private nonisolated static func eventObject(
    _ type: String, seq: Int, toolID: String? = nil, payload: JSONValue = .object([:])
  ) -> JSONValue {
    var obj: [String: JSONValue] = [
      "type": .string(type),
      "session_id": .string("live1"),
      "seq": .number(Double(seq)),
      "payload": payload,
    ]
    if let toolID { obj["tool_id"] = .string(toolID) }
    return .object(obj)
  }

  private nonisolated static func inflightPayload(_ running: Bool) -> JSONValue {
    var obj: [String: JSONValue] = ["streaming": .bool(running)]
    if running { obj["assistant"] = .string("partial answer") }
    return .object(obj)
  }

  private final class RPCOrder: @unchecked Sendable {
    private let lock = NSLock()
    private var methods: [String] = []
    func record(_ method: String) { lock.lock(); methods.append(method); lock.unlock() }
    func snapshot() -> [String] { lock.lock(); defer { lock.unlock() }; return methods }
  }

  private func makeStore(
    running: Bool,
    order: RPCOrder
  ) -> TestStore<ChatFeature.State, ChatFeature.Action> {
    let store = TestStore(initialState: runningTurnState()) {
      ChatFeature()
    } withDependencies: {
      $0.hermesGateway.connect = { @Sendable _, _ in AsyncStream<GatewayFrame> { _ in } }
      $0.hermesGateway.send = { @Sendable method, _ in
        order.record(method)
        if method == "session.resume" {
          return .object([
            "session_id": .string("live1"),
            "stored_session_id": .string("stored1"),
            "messages": .array([
              .object(["id": .number(1), "role": .string("user"), "content": .string("prior")]),
            ]),
            "running": .bool(running),
            "inflight": Self.inflightPayload(running),
            "info": .object([
              "model": .string("m1"),
              "usage": .object(["context_used": .number(0), "context_max": .number(1000), "context_percent": .number(0)]),
            ]),
          ])
        }
        return .object([
          "events": .array([
            Self.eventObject("tool.start", seq: 42, toolID: "t2",
                             payload: .object(["name": .string("webfetch"), "tool_id": .string("t2")])),
          ]),
          "latest_seq": .number(42),
          "truncated": .bool(false),
          "epoch": .string("e1"),
        ])
      }
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.chatSnapshot = .inMemory()
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    return store
  }

  @Test func replayedToolRowSurvivesRunningHydrateAndReconcilesInPlace() async {
    let order = RPCOrder()
    let store = makeStore(running: true, order: order)
    await store.send(.gatewayEvent(GatewayFrame(.ready)))
    await store.receive(\.replayResult.success)
    await store.receive(\.activateResult.success)
    await store.finish()

    // Ordering held.
    #expect(order.snapshot().prefix(2) == ["session.events.since", "session.resume"])
    // Cursor advanced through the replayed frame.
    #expect(store.state.replayCursor == RC(sessionID: "live1", seq: 42))

    // The replayed tool row (t2) SURVIVED the running hydrate's wholesale replace (#26),
    // alongside the live t1 row preserved from before the drop.
    let preservedT1 = store.state.transcript[id: UUID(10)]
    #expect(preservedT1 != nil)
    #expect(store.state.toolRowIDs["t1"] == UUID(10))
    let replayedT2 = store.state.transcript.first {
      if case let .tool(name, _, _, _, _) = $0.kind { return name == "webfetch" } else { return false }
    }
    guard let t2Row = replayedT2 else {
      Issue.record("expected the replayed t2 tool row to survive the running hydrate; transcript: \(store.state.transcript)")
      return
    }
    let t2ID = t2Row.id
    #expect(store.state.toolRowIDs["t2"] == t2ID)

    // A post-replay live tool.complete(t2) reconciles the SAME row in place (no churn).
    await store.send(.gatewayEvent(GatewayFrame(
      .toolComplete(toolID: "t2", name: "webfetch", title: nil,
                    args: .object(["url": .string("http://x")]), resultText: "fetched",
                    inlineDiff: nil, durationS: 0.5),
      sessionID: "live1", seq: 43
    )))
    let reconciled = store.state.transcript[id: t2ID]
    guard case let .tool(_, _, .complete, detail, _)? = reconciled?.kind else {
      Issue.record("expected the replayed t2 row to complete in place, got \(reconciled?.kind)")
      return
    }
    #expect(detail?.resultText == "fetched")
    #expect(store.state.replayCursor == RC(sessionID: "live1", seq: 43))
  }

  @Test func idleHydrateReplacesReplayedRowsWholesale() async {
    // Contrast case: the hydrate reports running=false (the turn finished server-side while
    // we were disconnected). Strict server-wins: the replayed rows are replaced by history.
    let order = RPCOrder()
    let store = makeStore(running: false, order: order)
    await store.send(.gatewayEvent(GatewayFrame(.ready)))
    await store.receive(\.replayResult.success)
    await store.receive(\.activateResult.success)
    await store.finish()
    // Cursor still advanced — the fold happened; the transcript was then replaced.
    #expect(store.state.replayCursor == RC(sessionID: "live1", seq: 42))
    // No preserved live rows: only the rebuilt history + seeded inflight rows remain.
    #expect(store.state.transcript[id: UUID(10)] == nil)
  }
}
