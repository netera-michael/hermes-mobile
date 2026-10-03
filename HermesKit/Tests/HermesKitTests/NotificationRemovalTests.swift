import ComposableArchitecture
import Foundation
import Testing
@testable import HermesKit

@MainActor
struct NotificationRemovalTests {
  let connection = ServerConnection(baseURL: URL(string: "https://fixture.example")!, token: "dummy")

  @Test func failureReopenLogoutAndRetryWithRetainedToken() async {
    let prefs = PreferencesClient.inMemory()
    prefs.savePushDeviceToken("dummy-device")
    let first = TestStore(initialState: SettingsFeature.State(connection: connection)) { SettingsFeature() } withDependencies: {
      $0.preferences = prefs
      $0.hermesREST.unregisterPush = { _, _ in throw RESTError.offline }
    }
    first.exhaustivity = .off(showSkippedAssertions: false)
    await first.send(.notificationsToggled(false))
    #expect(prefs.loadNotificationRemoval(connection.notificationPreferenceScope)?.confirmed == false)
    await first.receive(\.notificationOperationResult)
    #expect(first.state.notificationStatus == .unregisterFailed)
    let app = TestStore(initialState: AppFeature.State(home: .init(connection: connection))) { AppFeature() } withDependencies: {
      $0.preferences = prefs
      $0.keychain = .inMemory()
      $0.push = PushClient.inMemory().client
      $0.bearerTokens = BearerTokenStore()
    }
    app.exhaustivity = .off(showSkippedAssertions: false)
    await app.send(.home(.delegate(.disconnect)))
    await app.finish()
    #expect(prefs.loadPushDeviceToken() == nil)
    #expect(prefs.loadNotificationRemoval(connection.notificationPreferenceScope)?.token == "dummy-device")
    let retried = LockIsolated(false)
    let reopened = TestStore(initialState: SettingsFeature.State(connection: connection)) { SettingsFeature() } withDependencies: {
      $0.preferences = prefs
      $0.hermesREST.unregisterPush = { conn, token in
        #expect(conn == connection)
        #expect(token == "dummy-device")
        retried.setValue(true)
      }
    }
    reopened.exhaustivity = .off(showSkippedAssertions: false)
    await reopened.send(.authorizationStatusLoaded(.authorized))
    #expect(!reopened.state.notificationsEnabled)
    #expect(reopened.state.notificationStatus == .unregisterFailed)
    await reopened.send(.notificationsToggled(false))
    await reopened.receive(\.notificationOperationResult)
    #expect(retried.value)
    #expect(reopened.state.notificationStatus == .off)
    #expect(prefs.loadNotificationRemoval(connection.notificationPreferenceScope)?.confirmed == true)
    #expect(prefs.loadNotificationRemoval(connection.notificationPreferenceScope)?.token == nil)
  }

  @Test func durableRelaunchIsolationAndStaleConfirmation() async throws {
    let suite = "NotificationRemovalTests." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let scope = connection.notificationPreferenceScope
    let prefs = PreferencesClient.live(defaults: defaults)
    prefs.savePushDeviceToken("dummy-device")
    prefs.saveNotificationsEnabled(scope, false)
    let old = try #require(prefs.loadNotificationRemoval(scope))
    prefs.clearIdentityScopedPrefs()
    prefs.clearPushDeviceToken()
    let relaunched = PreferencesClient.live(defaults: try #require(UserDefaults(suiteName: suite)))
    #expect(relaunched.loadNotificationsEnabled(scope) == false)
    #expect(relaunched.loadNotificationRemoval(scope) == old)
    #expect(relaunched.loadNotificationsEnabled("another-scope") == nil)
    #expect(relaunched.loadNotificationRemoval("another-scope") == nil)
    relaunched.saveNotificationsEnabled(scope, true)
    #expect(!prefs.confirmNotificationRemoval(scope, old.operation))
    relaunched.saveNotificationsEnabled(scope, false)
    #expect(!prefs.confirmNotificationRemoval(scope, old.operation))
    let current = try #require(relaunched.loadNotificationRemoval(scope))
    #expect(current.token == "dummy-device")
    #expect(prefs.confirmNotificationRemoval(scope, current.operation))
    let reopened = TestStore(initialState: SettingsFeature.State(connection: connection)) { SettingsFeature() } withDependencies: { $0.preferences = relaunched }
    reopened.exhaustivity = .off(showSkippedAssertions: false)
    await reopened.send(.authorizationStatusLoaded(.authorized))
    #expect(reopened.state.notificationStatus == .off)
  }

  @Test func legacyOffWithoutTokenIsHonestAndStaleResultIgnored() async throws {
    let suite = "NotificationRemovalTests." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(false, forKey: "hermes.notifications." + connection.notificationPreferenceScope)
    let prefs = PreferencesClient.live(defaults: defaults)
    let store = TestStore(initialState: SettingsFeature.State(connection: connection)) { SettingsFeature() } withDependencies: { $0.preferences = prefs }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.authorizationStatusLoaded(.authorized))
    #expect(store.state.notificationStatus == .removalTokenMissing)
    await store.send(.notificationsToggled(false))
    await store.receive(\.notificationOperationResult)
    #expect(store.state.notificationStatus == .removalTokenMissing)
    await store.send(.notificationOperationResult(0, .off))
    #expect(store.state.notificationStatus == .removalTokenMissing)
    #expect(prefs.loadNotificationRemoval(connection.notificationPreferenceScope)?.confirmed == false)
  }
}
