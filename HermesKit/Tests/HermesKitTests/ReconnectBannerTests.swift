import Testing
import ComposableArchitecture
import Foundation
@testable import HermesKit

/// Calm reconnect: the "Reconnecting…" banner is gated behind a ~2s grace so sub-grace blips
/// (lock/unlock, app-switcher peek, Wi-Fi wobble) never show visible churn. The reducer's data
/// state (`status`) still flips to `.reconnecting` immediately — only the banner is delayed.
@MainActor
@Suite struct ReconnectBannerTests {
  private let conn = ServerConnection(baseURL: URL(string: "http://test")!, auth: .token("t"))

  private func makeStore() -> (TestStore<ChatFeature.State, ChatFeature.Action>, TestClock<Duration>) {
    let clock = TestClock<Duration>()
    let store = TestStore(initialState: ChatFeature.State(connection: conn, resumeStoredID: "s1")) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = clock
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.connect = { @Sendable _, _ in AsyncStream<GatewayFrame> { _ in } }
      $0.hermesGateway.send = { @Sendable _, _ in .object([:]) }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    return (store, clock)
  }

  @Test func blipReconnectsSilently() async {
    // Socket drops and comes back inside the 2s grace: NO banner flag is ever raised.
    let (store, clock) = makeStore()
    await store.send(.gatewayEvent(GatewayFrame(.ready)))
    await store.send(.gatewayClosed)
    #expect(store.state.status == .reconnecting)
    #expect(!store.state.showsReconnectBanner)

    // The banner timer fires late — but `.ready` already landed, so the guard neutralizes it.
    await store.send(.gatewayEvent(GatewayFrame(.ready)))
    #expect(store.state.status == .ready)
    #expect(!store.state.showsReconnectBanner)

    await clock.advance(by: .seconds(3))
    #expect(!store.state.showsReconnectBanner)
    await store.finish()
  }

  @Test func sustainedOutageRaisesBannerAfterGrace() async {
    // Socket drops and STAYS down past the grace: the banner appears.
    let (store, clock) = makeStore()
    await store.send(.gatewayEvent(GatewayFrame(.ready)))
    await store.send(.gatewayClosed)
    #expect(!store.state.showsReconnectBanner)

    await clock.advance(by: .seconds(2))
    await store.receive(\.reconnectBannerEligible) {
      $0.showsReconnectBanner = true
    }
    #expect(store.state.status == .reconnecting)

    // Recovery clears it.
    await store.send(.gatewayEvent(GatewayFrame(.ready))) {
      $0.status = .ready
      $0.showsReconnectBanner = false
    }
    await store.finish()
  }

  @Test func repeatedClosesNeverStackGraces() async {
    // Two rapid closes: cancelInFlight means only ONE banner grace runs.
    let (store, clock) = makeStore()
    await store.send(.gatewayEvent(GatewayFrame(.ready)))
    await store.send(.gatewayClosed)
    await store.send(.reconnectTick)
    await store.send(.gatewayClosed)
    #expect(!store.state.showsReconnectBanner)
    await clock.advance(by: .seconds(2))
    await store.receive(\.reconnectBannerEligible) {
      $0.showsReconnectBanner = true
    }
    await store.finish()
  }
}
