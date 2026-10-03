import ComposableArchitecture
import Foundation
import Testing
@testable import HermesKit

@MainActor
struct NotificationRetainedTargetsTests {
  @Test func liveAndMemoryRetainAllTargetsAndFenceOldConfirmation() throws {
    let suite = "NotificationRetainedTargets." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    for prefs in [PreferencesClient.live(defaults: defaults), .inMemory()] {
      prefs.savePushDeviceToken("T1")
      prefs.saveNotificationsEnabled("alice", false)
      let old = try #require(prefs.loadNotificationRemoval("alice"))
      prefs.clearPushDeviceToken(); prefs.clearIdentityScopedPrefs()
      prefs.savePushDeviceToken("T2")
      prefs.saveNotificationsEnabled("alice", true)
      prefs.saveNotificationsEnabled("alice", false)
      prefs.saveNotificationsEnabled("alice", false)
      let next = try #require(prefs.loadNotificationRemoval("alice"))
      #expect(next.tokens == ["T1", "T2"])
      #expect(!prefs.confirmNotificationRemoval("alice", old.operation))
      #expect(prefs.loadNotificationRemoval("alice") == next)
      #expect(prefs.loadNotificationRemoval("bob") == nil)
    }
    let cold = PreferencesClient.live(defaults: try #require(UserDefaults(suiteName: suite)))
    #expect(cold.loadNotificationRemoval("alice")?.tokens == ["T1", "T2"])
    #expect(cold.loadNotificationsEnabled("alice") == false)
  }

  @Test func legacySingularMigrationPreservesToken() throws {
    let suite = "NotificationMigration." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(try JSONSerialization.data(withJSONObject: ["operation": UUID().uuidString, "token": "T1", "confirmed": false]), forKey: "hermes.notification-removal.alice")
    let prefs = PreferencesClient.live(defaults: defaults)
    #expect(prefs.loadNotificationRemoval("alice")?.tokens == ["T1"])
    prefs.savePushDeviceToken("T2"); prefs.saveNotificationsEnabled("alice", false)
    #expect(prefs.loadNotificationRemoval("alice")?.tokens == ["T1", "T2"])
  }

  @Test func livePartialFailureRetainsAllAndSuccessfulRetryRemovesAll() async throws {
    let suite = "NotificationReducer." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let prefs = PreferencesClient.live(defaults: defaults)
    let connection = ServerConnection(baseURL: URL(string: "https://fixture.example")!, token: "current-auth")
    let scope = connection.notificationPreferenceScope
    prefs.savePushDeviceToken("T1"); prefs.saveNotificationsEnabled(scope, false)
    prefs.clearPushDeviceToken(); prefs.clearIdentityScopedPrefs(); prefs.savePushDeviceToken("T2")
    let fail = LockIsolated(true), targets = LockIsolated<[String]>([])
    let store = TestStore(initialState: SettingsFeature.State(connection: connection)) { SettingsFeature() } withDependencies: {
      $0.preferences = prefs
      $0.hermesREST.unregisterPush = { conn, token in
        #expect(conn == connection)
        targets.withValue { $0.append(token) }
        if token == "T1" && fail.value { throw RESTError.offline }
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.notificationsToggled(false)); await store.receive(\.notificationOperationResult)
    #expect(targets.value == ["T1", "T2"])
    #expect(store.state.notificationStatus == .unregisterFailed)
    #expect(prefs.loadNotificationRemoval(scope)?.confirmed == false)
    #expect(prefs.loadNotificationRemoval(scope)?.tokens == ["T1", "T2"])
    fail.setValue(false); targets.setValue([])
    await store.send(.notificationsToggled(false)); await store.receive(\.notificationOperationResult)
    #expect(targets.value == ["T1", "T2"])
    #expect(store.state.notificationStatus == .off)
    #expect(prefs.loadNotificationRemoval(scope)?.confirmed == true)
    #expect(prefs.loadNotificationRemoval(scope)?.tokens == [])
  }
}
