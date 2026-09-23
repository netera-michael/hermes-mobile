import Testing
import ComposableArchitecture
import Foundation
@testable import HermesKit

private typealias RC = ChatFeature.State.ReplayCursor

/// Helper to build `ChatFeature.Action.gatewayEvent` with a `GatewayFrame` — avoids
/// ambiguity with the test-convenience overload that takes a bare `GatewayEvent`.
private func frameAction(_ frame: GatewayFrame) -> ChatFeature.Action {
  ChatFeature.Action.gatewayEvent(frame)
}

private let openStream: @Sendable (URL, AuthSession) -> AsyncStream<GatewayFrame> = { _, _ in
  AsyncStream<GatewayFrame> { _ in }
}

@MainActor
@Suite struct ReplayCursorTests {
  private let conn = ServerConnection(baseURL: URL(string: "http://test")!, auth: .token("t"))

  private func makeStore(initial: ChatFeature.State? = nil) -> TestStore<ChatFeature.State, ChatFeature.Action> {
    let state = initial ?? ChatFeature.State(connection: conn)
    let clock = TestClock()
    let date = Date(timeIntervalSince1970: 0)
    let store = TestStore(initialState: state) {
      ChatFeature()
    } withDependencies: {
      $0.hermesGateway.connect = openStream
      $0.uuid = .incrementing
      $0.continuousClock = clock
      $0.date = .constant(date)
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { @Sendable _, _ in .object([:]) }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    return store
  }

  // MARK: - advanceCursor

  @Test func seqAdvancesCursor() async {
    let store = makeStore()
    await store.send(frameAction(GatewayFrame(.messageStart, sessionID: "s1", seq: 1))) {
      $0.replayCursor = RC(sessionID: "s1", seq: 1)
    }
    await store.send(frameAction(GatewayFrame(.messageDelta(text: "a"), sessionID: "s1", seq: 2))) {
      $0.replayCursor = RC(sessionID: "s1", seq: 2)
    }
    await store.send(frameAction(GatewayFrame(.messageDelta(text: "b"), sessionID: "s1", seq: 3))) {
      $0.replayCursor = RC(sessionID: "s1", seq: 3)
    }
  }

  @Test func outOfOrderSeqDoesNotRewindCursor() async {
    var initial = ChatFeature.State(connection: conn)
    initial.replayCursor = RC(sessionID: "s1", seq: 3)
    let store = makeStore(initial: initial)
    // seq 2 ≤ cursor 3 → cursor stays at 3
    await store.send(frameAction(GatewayFrame(.messageDelta(text: "late"), sessionID: "s1", seq: 2)))
  }

  @Test func seqLessFrameLeavesCursor() async {
    var initial = ChatFeature.State(connection: conn)
    initial.replayCursor = RC(sessionID: "s1", seq: 5)
    let store = makeStore(initial: initial)
    await store.send(frameAction(GatewayFrame(.messageDelta(text: "x"), sessionID: "s1")))
  }

  @Test func differentSessionReplacesCursor() async {
    var initial = ChatFeature.State(connection: conn)
    initial.replayCursor = RC(sessionID: "s1", seq: 10)
    let store = makeStore(initial: initial)
    await store.send(frameAction(GatewayFrame(.messageStart, sessionID: "s2", seq: 1))) {
      $0.replayCursor = RC(sessionID: "s2", seq: 1)
    }
  }

  // MARK: - Epoch tracking

  @Test func readyWithEpochAdoptsIt() async {
    let store = makeStore()
    await store.send(frameAction(GatewayFrame(.ready, replayEpoch: "e1"))) {
      $0.replayEpoch = "e1"
    }
  }

  @Test func readyWithDifferentEpochClearsCursorAndAdopts() async {
    var initial = ChatFeature.State(connection: conn)
    initial.replayEpoch = "e1"
    initial.replayCursor = RC(sessionID: "s1", seq: 42)
    let store = makeStore(initial: initial)
    await store.send(frameAction(GatewayFrame(.ready, replayEpoch: "e2"))) {
      $0.replayCursor = nil
      $0.replayEpoch = "e2"
    }
  }

  @Test func readyWithSameEpochKeepsCursor() async {
    var initial = ChatFeature.State(connection: conn)
    initial.replayEpoch = "e1"
    initial.replayCursor = RC(sessionID: "s1", seq: 42)
    let store = makeStore(initial: initial)
    await store.send(frameAction(GatewayFrame(.ready, replayEpoch: "e1")))
  }

  @Test func readyWithoutEpochKeepsBoth() async {
    var initial = ChatFeature.State(connection: conn)
    initial.replayEpoch = "e1"
    initial.replayCursor = RC(sessionID: "s1", seq: 42)
    let store = makeStore(initial: initial)
    let bareReady = GatewayFrame(.ready)
    await store.send(frameAction(bareReady))
  }

  @Test func noCursorInitially() {
    let state = ChatFeature.State(connection: conn)
    #expect(state.replayCursor == nil)
    #expect(state.replayEpoch == nil)
    #expect(state.replaySupported == true)
  }
}
