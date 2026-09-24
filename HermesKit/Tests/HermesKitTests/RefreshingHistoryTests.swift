import Testing
import ComposableArchitecture
import Foundation
@testable import HermesKit

/// Refreshing-history indicator: when a fresh `session.resume` starts over an already-painted
/// transcript (instant-paint snapshot or previous hydrate), `isRefreshingHistory` rises so the
/// view can show a thin "Refreshing…" strip; it clears when the hydrate lands or fails.
@MainActor
@Suite struct RefreshingHistoryTests {
  private let conn = ServerConnection(baseURL: URL(string: "http://test")!, auth: .token("t"))

  private nonisolated static func resumePayload(sessionID: String, text: String) -> JSONValue {
    .object([
      "session_id": .string(sessionID),
      "messages": .array([
        .object(["id": .number(1), "role": .string("user"), "text": .string(text)]),
      ]),
      "running": .bool(false),
    ])
  }

  @Test func coldOpenDoesNotShowRefreshing() async {
    // Nothing painted → the initial connect/loading state already communicates loading;
    // the refreshing strip would be noise on top.
    var initial = ChatFeature.State(connection: conn, resumeStoredID: "s1")
    initial.transcript = [] // nothing painted
    let store = TestStore(initialState: initial) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.connect = { @Sendable _, _ in AsyncStream<GatewayFrame> { _ in } }
      $0.hermesGateway.send = { @Sendable _, _ in .object([:]) }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.gatewayEvent(GatewayFrame(.ready)))
    #expect(!store.state.isRefreshingHistory)
    await store.finish()
  }

  @Test func paintedTranscriptShowsRefreshingThenClearsOnLand() async {
    // Instant-paint snapshot rows exist → the re-hydrate over them raises the flag;
    // applyActivate (success) clears it.
    let snapshotClient = ChatSnapshotClient.inMemory()
    let cachedRows = [
      ChatRow(id: UUID(), kind: .message(role: .user, text: "cached", isComplete: true)),
    ]
    snapshotClient.saveSnapshot("s1", ChatSnapshot(
      model: "m", usage: Usage(contextUsed: 0, contextMax: 1000, contextPercent: 0), rows: cachedRows
    ))
    let initial = withDependencies({
      $0.chatSnapshot = snapshotClient
    }) {
      ChatFeature.State(connection: conn, resumeStoredID: "s1")
    }
    #expect(!initial.transcript.isEmpty) // instant paint present

    let freshPayload = Self.resumePayload(sessionID: "live1", text: "fresh")
    let store = TestStore(initialState: initial) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.chatSnapshot = snapshotClient
      $0.hermesGateway.connect = { @Sendable _, _ in AsyncStream<GatewayFrame> { _ in } }
      $0.hermesGateway.send = { @Sendable _, _ in freshPayload }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.gatewayEvent(GatewayFrame(.ready)))
    #expect(store.state.isRefreshingHistory)
    await store.receive(\.activateResult.success)
    #expect(!store.state.isRefreshingHistory)
    await store.finish()
  }

  @Test func failedHydrateClearsRefreshing() async {
    let snapshotClient = ChatSnapshotClient.inMemory()
    let cachedRows = [
      ChatRow(id: UUID(), kind: .message(role: .user, text: "cached", isComplete: true)),
    ]
    snapshotClient.saveSnapshot("s1", ChatSnapshot(
      model: "m", usage: Usage(contextUsed: 0, contextMax: 1000, contextPercent: 0), rows: cachedRows
    ))
    let initial = withDependencies({
      $0.chatSnapshot = snapshotClient
    }) {
      ChatFeature.State(connection: conn, resumeStoredID: "s1")
    }
    let store = TestStore(initialState: initial) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.chatSnapshot = snapshotClient
      $0.hermesGateway.connect = { @Sendable _, _ in AsyncStream<GatewayFrame> { _ in } }
      $0.hermesGateway.send = { @Sendable _, _ in throw GatewayError.disconnected }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.gatewayEvent(GatewayFrame(.ready)))
    #expect(store.state.isRefreshingHistory)
    await store.receive(\.activateResult.failure)
    #expect(!store.state.isRefreshingHistory)
    await store.finish()
  }
}