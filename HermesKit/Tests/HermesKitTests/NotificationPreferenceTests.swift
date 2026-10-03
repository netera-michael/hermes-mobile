import ComposableArchitecture
import Foundation
import Testing
@testable import HermesKit

@MainActor
struct NotificationPreferenceTests {
  let connection = ServerConnection(baseURL: URL(string: "https://example.test")!, token: "first")

  @Test func persistenceSurvivesRecreationAndIdentityClearing() {
    let suite = "NotificationPreferenceTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let prefs = PreferencesClient.live(defaults: defaults)
    let scope = connection.notificationPreferenceScope
    #expect(prefs.loadNotificationsEnabled(scope) == nil)
    prefs.saveNotificationsEnabled(scope, false)
    prefs.clearIdentityScopedPrefs()
    prefs.clearServerURL()
    prefs.clearPushDeviceToken()
    prefs.clearPushPromptSnooze()
    #expect(PreferencesClient.live(defaults: defaults).loadNotificationsEnabled(scope) == false)
    #expect(prefs.loadNotificationsEnabled("another-account") == nil)
  }

  @Test func stableScopeExcludesRotatingCredentialsAndSeparatesAccounts() {
    var rotated = connection
    rotated.token = "rotated"
    rotated.baseURL = URL(string: "https://EXAMPLE.test:443/path/?x=1")!
    #expect(rotated.notificationPreferenceScope == connection.notificationPreferenceScope)
    var cookie = connection
    cookie.auth = .cookie(.init(cookies: [], username: "alice", provider: "password"))
    var other = cookie
    other.auth = .cookie(.init(cookies: [], username: "bob", provider: "password"))
    #expect(cookie.notificationPreferenceScope != other.notificationPreferenceScope)
    other = cookie
    other.baseURL = URL(string: "https://other.test")!
    #expect(cookie.notificationPreferenceScope != other.notificationPreferenceScope)
    var bearer = connection
    bearer.auth = .bearer(.init(accessToken: "a", refreshToken: "r", expiresAt: 1, provider: "oauth", userID: "alice"))
    var refreshed = bearer
    refreshed.auth = .bearer(.init(accessToken: "b", refreshToken: "s", expiresAt: 2, provider: "oauth", userID: "alice"))
    #expect(bearer.notificationPreferenceScope == refreshed.notificationPreferenceScope)
    #expect(bearer.notificationPreferenceScope != cookie.notificationPreferenceScope)
  }

  @Test func offBlocksReopenAuthorizationAndTokenRotation() async {
    let prefs = PreferencesClient.inMemory()
    prefs.saveNotificationsEnabled(connection.notificationPreferenceScope, false)
    let settings = TestStore(initialState: SettingsFeature.State(connection: connection)) {
      SettingsFeature()
    } withDependencies: { $0.preferences = prefs }
    await settings.send(.authorizationStatusLoaded(.authorized)) { $0.notificationStatus = .removalTokenMissing }
    await settings.send(.authorizationResult(true))
    await settings.send(.sendTestPushTapped)
    let list = TestStore(initialState: SessionListFeature.State(connection: connection)) {
      SessionListFeature()
    } withDependencies: { $0.preferences = prefs }
    await list.send(.requestPushAuthorization)
    await list.send(.pushTokenReceived("rotated-token"))
    await list.send(.pushPluginStatusLoaded(.ready))
    #expect(prefs.loadPushDeviceToken() == nil)
  }

  @Test func offPersistsBeforeAuthenticatedUnregisterAndReportsFailure() async {
    let prefs = PreferencesClient.inMemory()
    prefs.savePushDeviceToken("device")
    let scope = connection.notificationPreferenceScope
    let calls = LockIsolated(0)
    let expected = connection
    let store = TestStore(initialState: SettingsFeature.State(connection: connection, notificationsEnabled: true)) {
      SettingsFeature()
    } withDependencies: {
      $0.preferences = prefs
      $0.hermesREST.unregisterPush = { connection, token in
        #expect(prefs.loadNotificationsEnabled(scope) == false)
        #expect(connection == expected)
        #expect(token == "device")
        calls.withValue { $0 += 1 }
        throw RESTError.offline
      }
    }
    await store.send(.notificationsToggled(false)) {
      $0.notificationsEnabled = false
      $0.notificationGeneration = 1
      $0.notificationStatus = .unregistering
    }
    await store.receive(\.notificationOperationResult) { $0.notificationStatus = .unregisterFailed }
    await store.send(.notificationAuthorizationResult(0, true))
    await store.send(.notificationOperationResult(0, .idle))
    await store.send(.notificationTestResult(0, true))
    await store.send(.notificationStatusLoaded(0, .authorized))
    #expect(calls.value == 1)
    #expect(store.state.notificationsEnabled == false)
    #expect(store.state.notificationStatus == .unregisterFailed)
  }

  @Test func heldPermissionFromEarlierOnCannotOverrideOffThenOn() async {
    let prefs = PreferencesClient.inMemory()
    prefs.savePushDeviceToken("device")
    let entered = AsyncStream<Void>.makeStream()
    let release = AsyncStream<Void>.makeStream()
    let prompts = LockIsolated(0)
    let store = TestStore(initialState: SettingsFeature.State(connection: connection)) {
      SettingsFeature()
    } withDependencies: {
      $0.preferences = prefs
      $0.push.requestAuthorization = {
        let count = prompts.withValue { $0 += 1; return $0 }
        if count == 1 {
          entered.continuation.yield(())
          for await _ in release.stream { break }
          return true
        }
        return false
      }
      $0.hermesREST.unregisterPush = { _, _ in }
    }
    await store.send(.notificationsToggled(true)) {
      $0.notificationsEnabled = true
      $0.notificationGeneration = 1
    }
    for await _ in entered.stream { break }
    await store.send(.notificationsToggled(false)) {
      $0.notificationsEnabled = false
      $0.notificationGeneration = 2
      $0.notificationStatus = .unregistering
    }
    await store.receive(\.notificationOperationResult) { $0.notificationStatus = .off }
    await store.send(.notificationsToggled(true)) {
      $0.notificationsEnabled = true
      $0.notificationGeneration = 3
      $0.notificationStatus = .idle
    }
    await store.receive(\.notificationAuthorizationResult) {
      $0.notificationsEnabled = false
      $0.notificationsDenied = true
    }
    release.continuation.yield(())
    await store.receive(\.notificationAuthorizationResult)
    #expect(!store.state.notificationsEnabled)
    #expect(store.state.notificationsDenied)
  }

  @Test func unregisterWaitsForHeldRegistrationAndFinishesLast() async {
    let prefs = PreferencesClient.inMemory()
    prefs.savePushDeviceToken("device")
    let admitted = AsyncStream<Void>.makeStream()
    let release = AsyncStream<Void>.makeStream()
    let calls = LockIsolated<[String]>([])
    let list = TestStore(initialState: SessionListFeature.State(connection: connection)) {
      SessionListFeature()
    } withDependencies: {
      $0.preferences = prefs
      $0.push.appVersion = { "test" }
      $0.hermesREST.registerPush = { _, _, _, _ in
        admitted.continuation.yield(())
        for await _ in release.stream { break }
        calls.withValue { $0.append("register") }
      }
    }
    let settings = TestStore(initialState: SettingsFeature.State(connection: connection, notificationsEnabled: true)) {
      SettingsFeature()
    } withDependencies: {
      $0.preferences = prefs
      $0.hermesREST.unregisterPush = { _, _ in calls.withValue { $0.append("unregister") } }
    }
    await list.send(.pushTokenReceived("device"))
    for await _ in admitted.stream { break }
    await settings.send(.notificationsToggled(false)) {
      $0.notificationsEnabled = false
      $0.notificationGeneration = 1
      $0.notificationStatus = .unregistering
    }
    release.continuation.yield(())
    await list.receive(\.pushRegistered)
    await settings.receive(\.notificationOperationResult) { $0.notificationStatus = .off }
    #expect(calls.value == ["register", "unregister"])
  }
}
