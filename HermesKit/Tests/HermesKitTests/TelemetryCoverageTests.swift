import ComposableArchitecture
import Foundation
import Testing
@testable import HermesKit

/// Field telemetry must (a) report replay outcomes and sustained outages, and (b) key every
/// event by the STORED session id so one chat's timeline never splits across re-minted live ids.
@MainActor
@Suite struct TelemetryCoverageTests {
  private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ConnectionTraceEntry] = []
    func append(_ entry: ConnectionTraceEntry) { lock.withLock { storage.append(entry) } }
    var entries: [ConnectionTraceEntry] { lock.withLock { storage } }
  }

  private let conn = ServerConnection(baseURL: URL(string: "http://test")!, auth: .token("t"))

  private func makeStore(
    recorder: Recorder, clock: TestClock<Duration> = TestClock(),
    send: @escaping @Sendable (String, JSONValue) async throws -> JSONValue = { _, _ in .object([:]) }
  ) -> TestStore<ChatFeature.State, ChatFeature.Action> {
    var trace = ConnectionTraceClient.testValue
    trace.append = { recorder.append($0) }
    let store = TestStore(initialState: ChatFeature.State(connection: conn, resumeStoredID: "stored1")) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = clock
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.chatSnapshot = .inMemory()
      $0.connectionTrace = trace
      $0.hermesGateway.connect = { @Sendable _, _ in AsyncStream<GatewayFrame> { _ in } }
      $0.hermesGateway.send = send
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    return store
  }

  @Test func truncatedReplayIsReportedUnderStoredID() async {
    let recorder = Recorder()
    let store = makeStore(recorder: recorder)
    await store.send(.replayResult(.success(ReplayBatch(truncated: true))))
    let failed = recorder.entries.filter { $0.kind == .replayFailed }
    #expect(failed.count == 1)
    #expect(failed.first?.reason == .truncated)
    #expect(failed.first?.sessionID == "stored1")
    await store.finish()
  }

  @Test func cleanReplayReportsSuccessWithFoldCount() async {
    let recorder = Recorder()
    let store = makeStore(recorder: recorder)
    await store.send(.replayResult(.success(ReplayBatch(events: [], latestSeq: 7))))
    let ok = recorder.entries.filter { $0.kind == .replaySucceeded }
    #expect(ok.count == 1)
    #expect(ok.first?.rowCount == 0)
    #expect(recorder.entries.allSatisfy { $0.kind != .replayFailed })
    await store.finish()
  }

  @Test func unknownMethodReplayReportsUnsupported() async {
    let recorder = Recorder()
    let store = makeStore(recorder: recorder)
    await store.send(.replayResult(.failure(.server("unknown method: session.events.since"))))
    #expect(recorder.entries.first { $0.kind == .replayFailed }?.reason == .unsupported)
    await store.finish()
  }

  @Test func sustainedOutageEmitsBannerShownWithAttempt() async {
    let recorder = Recorder()
    let clock = TestClock<Duration>()
    let store = makeStore(recorder: recorder, clock: clock)
    await store.send(.gatewayEvent(GatewayFrame(.ready)))
    await store.send(.gatewayClosed)
    #expect(recorder.entries.allSatisfy { $0.kind != .bannerShown })
    await clock.advance(by: .seconds(2))
    await store.receive(\.reconnectBannerEligible)
    let shown = recorder.entries.filter { $0.kind == .bannerShown }
    #expect(shown.count == 1)
    #expect(shown.first?.attempt == 1)
    #expect(shown.first?.sessionID == "stored1")
    await store.skipInFlightEffects()
  }

  @Test func liveIDNeverLeaksIntoTraceSessionID() async {
    let recorder = Recorder()
    let store = makeStore(recorder: recorder)
    await store.send(.gatewayClosed)
    #expect(!recorder.entries.isEmpty)
    #expect(recorder.entries.allSatisfy { $0.sessionID == "stored1" })
    await store.skipInFlightEffects()
  }

  @Test func newFieldsEncodeForTheReceiver() throws {
    let entry = ConnectionTraceEntry(timestamp: Date(), generation: 2, kind: .bannerShown,
                                     sessionID: "stored1", reason: .truncated, attempt: 3)
    let object = try #require(JSONSerialization.jsonObject(
      with: JSONEncoder().encode(entry)) as? [String: Any])
    #expect(object["kind"] as? String == "bannerShown")
    #expect(object["attempt"] as? Int == 3)
    #expect(object["reason"] as? String == "truncated")
  }
}
