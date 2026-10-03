import ComposableArchitecture
import Foundation
import Testing
@testable import HermesKit

extension RESTTransportSuite {
  @Suite(.serialized) struct CredentialRetirementTests {
    @Test func failedDeleteRejectsEveryColdLoad() throws {
      for auth: AuthSession in [
        .token("dummy-old"),
        .cookie(CookieSession(cookies: [.init(name: "session", value: "dummy-old", domain: "fixture.example", path: "/")], username: "alice", provider: "basic")),
        .bearer(BearerSession(accessToken: "dummy-at", refreshToken: "dummy-rt", expiresAt: 1_900_000_000, provider: "test", userID: "alice"))
      ] {
        let fixture = RetirementFixture(auth)
        let live = fixture.client()
        _ = live.loadSession(.shared)
        #expect(throws: KeychainError.unhandled(-25308)) { try live.deleteSession() }
        #expect(fixture.data.value != nil, "Simulated Security failure retains the credential bytes")
        let cold = fixture.client()
        #expect(cold.loadSession(.shared) == nil)
        #expect(cold.loadToken() == nil)
        if case .cookie = auth {
          let connection = ServerConnection(baseURL: URL(string: "https://fixture.example")!, auth: auth)
          #expect(throws: CancellationError.self) { _ = try CookieSessionStore.shared.lease(for: connection) }
          #expect(!(HTTPCookieStorage.shared.cookies ?? []).contains { $0.value == "dummy-old" })
        }
      }
    }

    @Test func failedFreshSaveStaysRetiredAndLateWritersCannotReopen() throws {
      let fixture = RetirementFixture(.token("old"))
      let live = fixture.client()
      let oldRotation = live.persistence(freshLogin: false)
      let oldLogin = live.persistence(freshLogin: true)
      #expect(throws: KeychainError.unhandled(-25308)) { try live.deleteSession() }
      fixture.failSave.setValue(true)
      #expect(throws: KeychainError.unhandled(-25308)) { try live.saveSession(.token("failed-new")) }
      #expect(fixture.client().loadToken() == nil)
      #expect(throws: KeychainError.retired) { try oldRotation(.token("late-old")) }
      #expect(throws: KeychainError.retired) { try oldLogin(.token("late-login")) }
      fixture.failSave.setValue(false)
      let fresh = live.persistence(freshLogin: true)
      try fresh(.token("new"))
      #expect(fixture.client().loadToken() == "new")
      #expect(throws: KeychainError.retired) { try oldRotation(.token("late-old")) }
      #expect(throws: KeychainError.retired) { try oldLogin(.token("late-login")) }
      try fresh(.token("new-rotation"))
      #expect(fixture.client().loadToken() == "new-rotation")
      #expect(throws: KeychainError.unhandled(-25308)) { try live.deleteSession() }
      #expect(throws: KeychainError.retired) { try fresh(.token("late-new")) }
      #expect(fixture.client().loadToken() == nil)
    }

    @Test func retirementIsScopedByServiceAndAccount() throws {
      let fixture = RetirementFixture(.token("old"))
      #expect(throws: KeychainError.unhandled(-25308)) { try fixture.client().deleteSession() }
      let other = KeychainClient.live(service: fixture.service, account: "different", operations: .init(
        read: { fixture.data.value }, write: { _ in }, delete: {}
      ))
      #expect(other.loadToken() == "old")
      #expect(fixture.client().loadToken() == nil)
    }

    @Test func successfulFreshCookieLoginSurvivesLateRealCleanup() async throws {
      let old = CookieSession(cookies: [.init(name: "session", value: "old", domain: "fixture.example", path: "/")], username: "alice", provider: "basic")
      let new = CookieSession(cookies: [.init(name: "session", value: "new", domain: "fixture.example", path: "/")], username: "alice", provider: "basic")
      let fixture = RetirementFixture(.cookie(old))
      let client = fixture.client()
      _ = client.loadSession(.shared)
      let connection = ServerConnection(baseURL: URL(string: "https://fixture.example")!, auth: .cookie(old))
      let rest = HermesRESTClient.live(session: .shared, tokenStore: BearerTokenStore())
      let cleanup = rest.prepareLogout(connection, nil)
      #expect(throws: KeychainError.unhandled(-25308)) { try client.deleteSession() }
      client.activateCookieSession(new)
      try client.saveSession(.cookie(new))
      await cleanup.run()
      #expect(fixture.client().loadSession(.shared) == .cookie(new))
      #expect(throws: CancellationError.self) { _ = try CookieSessionStore.shared.lease(for: connection) }
      _ = try CookieSessionStore.shared.lease(for: .init(baseURL: connection.baseURL, auth: .cookie(new)))
    }

    @Test func failedBearerFreshPersistenceThrowsRatherThanPublishingSuccess() throws {
      let fixture = RetirementFixture(.token("old"))
      let client = fixture.client()
      #expect(throws: KeychainError.unhandled(-25308)) { try client.deleteSession() }
      fixture.failSave.setValue(true)
      let store = BearerTokenStore()
      let claim = store.claimOwnership()
      store.seed(.init(accessToken: "new", refreshToken: "new-r", expiresAt: 1_900_000_000, provider: "p", userID: "u"), baseURL: URL(string: "https://fixture.example")!, claim: claim)
      let persist = client.persistence(freshLogin: true)
      #expect(throws: KeychainError.unhandled(-25308)) {
        _ = try store.attachValidatedPersistence({ try persist(.bearer($0)) }, claim: claim)
      }
      #expect(fixture.client().loadSession(.shared) == nil)
    }

    @Test @MainActor func originalReviewerColdAppReproductionUsesLiveLifecycle() async throws {
      let auth = AuthSession.cookie(CookieSession(cookies: [.init(name: "session", value: "dummy-old", domain: "fixture.example", path: "/")], username: "alice", provider: "basic"))
      let fixture = RetirementFixture(auth)
      let connection = ServerConnection(baseURL: URL(string: "https://fixture.example")!, auth: auth)
      let keychain = fixture.client()
      _ = keychain.loadSession(.shared)
      let prefs = PreferencesClient.inMemory()
      prefs.saveServerURL(connection.baseURL.absoluteString)
      let store = TestStore(initialState: AppFeature.State(home: .init(connection: connection))) { AppFeature() } withDependencies: {
        $0.preferences = prefs; $0.keychain = keychain
        $0.hermesREST = .live(session: .shared, tokenStore: BearerTokenStore())
        $0.bearerTokens = BearerTokenStore(); $0.push = PushClient.inMemory().client
      }
      store.exhaustivity = .off(showSkippedAssertions: false)
      await store.send(.home(.delegate(.disconnect)))
      #expect(store.state.onboarding.status == .failed("Signed out. Saved credentials could not be erased; automatic sign-in is blocked until you sign in again."))
      await store.finish()
      #expect(throws: CancellationError.self) { _ = try CookieSessionStore.shared.lease(for: connection) }
      let cold = TestStore(initialState: AppFeature.State()) { AppFeature() } withDependencies: {
        $0.preferences = prefs; $0.keychain = fixture.client()
        $0.push.incomingTaps = { AsyncStream { $0.finish() } }
      }
      await cold.send(.task)
      await cold.finish()
      #expect(cold.state.home == nil)
      #expect(throws: CancellationError.self) { _ = try CookieSessionStore.shared.lease(for: connection) }
    }
  }
}

private final class RetirementFixture: @unchecked Sendable {
  let service = "test.retirement.\(UUID().uuidString)"
  let data: LockIsolated<Data?>
  let failSave = LockIsolated(false)
  init(_ auth: AuthSession) { data = LockIsolated(try! JSONEncoder().encode(auth)) }
  func client() -> KeychainClient {
    KeychainClient.live(service: service, account: "test", operations: .init(
      read: { [self] in data.value },
      write: { [self] value in
        if failSave.value { throw KeychainError.unhandled(-25308) }
        data.setValue(value)
      },
      delete: { throw KeychainError.unhandled(-25308) }
    ))
  }
}
