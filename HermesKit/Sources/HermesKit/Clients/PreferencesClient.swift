import ComposableArchitecture
import DependenciesMacros
import Foundation
import CryptoKit

/// Stable origin + account identity, never a rotating credential. Legacy token auth has
/// no account identifier, so its preference is deliberately server-scoped.
public extension ServerConnection {
  var notificationPreferenceScope: String {
    var origin = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
    origin.scheme = origin.scheme?.lowercased()
    origin.host = origin.host?.lowercased()
    if (origin.scheme == "https" && origin.port == 443)
      || (origin.scheme == "http" && origin.port == 80) { origin.port = nil }
    origin.user = nil; origin.password = nil; origin.path = ""
    origin.query = nil; origin.fragment = nil
    let identity: [String]
    switch auth {
    case .token: identity = ["token"]
    case let .cookie(session): identity = ["cookie", session.provider, session.username]
    case let .bearer(session): identity = ["bearer", session.provider, session.userID]
    }
    let parts = [origin.string ?? ""] + identity
    let encoded = parts.map { "\($0.utf8.count):\($0)" }.joined()
    return SHA256.hash(data: Data(encoded.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}

/// Persisted reconciliation for one account/origin. The token is a routing address, not auth.
public struct NotificationRemoval: Codable, Equatable, Sendable {
  public var operation: UUID
  public var tokens: [String]
  public var confirmed: Bool
  /// Compatibility view for callers displaying whether a retry target exists.
  public var token: String? {
    get { tokens.first }
    set { tokens = newValue.map { [$0] } ?? [] }
  }

  public init(operation: UUID, token: String?, confirmed: Bool) {
    self.operation = operation
    self.tokens = token.map { [$0] } ?? []
    self.confirmed = confirmed
  }

  private enum CodingKeys: String, CodingKey { case operation, token, tokens, confirmed }
  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    operation = try values.decode(UUID.self, forKey: .operation)
    confirmed = try values.decode(Bool.self, forKey: .confirmed)
    let legacy = try values.decodeIfPresent(String.self, forKey: .token)
    let retained = try values.decodeIfPresent([String].self, forKey: .tokens) ?? []
    tokens = Array(Set(retained + (legacy.map { [$0] } ?? []))).sorted()
  }
  public func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(operation, forKey: .operation)
    try values.encode(tokens, forKey: .tokens)
    try values.encode(confirmed, forKey: .confirmed)
  }

  static func pending(prior: Self?, current: String?) -> Self {
    var next = Self(operation: UUID(), token: nil, confirmed: false)
    next.tokens = Array(Set((prior?.confirmed == false ? prior!.tokens : [])
      + (current.map { [$0] } ?? []))).sorted()
    return next
  }
}

private let notificationPreferenceLock = NSRecursiveLock()
private let ownedUpdateLock = NSLock()

/// Non-secret, persisted app preferences. Currently just the last server URL, kept so
/// the app can auto-reconnect on launch without re-running onboarding (the token lives
/// in `KeychainClient`). Live implementation backs onto `UserDefaults`; an in-memory
/// variant is used for previews and tests.
@DependencyClient
public struct PreferencesClient: Sendable {
  /// nil preserves legacy intent; explicit false survives logout and identity-pref clearing.
  public var loadNotificationsEnabled: @Sendable (_ scope: String) -> Bool? = { _ in nil }
  public var saveNotificationsEnabled: @Sendable (_ scope: String, _ enabled: Bool) -> Void
  public var loadNotificationRemoval: @Sendable (_ scope: String) -> NotificationRemoval? = { _ in nil }
  /// Compare-and-confirm only the exact Off operation after authenticated unregister succeeds.
  public var confirmNotificationRemoval: @Sendable (_ scope: String, _ operation: UUID) -> Bool = { _, _ in false }
  /// Serialize register/unregister for this client so an older register cannot land after Off.
  public var notificationOperation: @Sendable (_ scope: String, _ operation: @escaping @Sendable () async -> Void) async -> Void
  public var loadServerURL: @Sendable () -> String? = { nil }
  public var saveServerURL: @Sendable (_ url: String) -> Void
  public var clearServerURL: @Sendable () -> Void
  /// Last-seen message count per session id — used to flag unread activity.
  public var loadSeenCounts: @Sendable () -> [String: Int] = { [:] }
  public var saveSeenCounts: @Sendable (_ counts: [String: Int]) -> Void
  /// Pinned session ids, ordered = display order in the top "Pinned" section.
  public var loadPinnedIDs: @Sendable () -> [String] = { [] }
  public var savePinnedIDs: @Sendable (_ ids: [String]) -> Void
  /// How the session list groups its rows (workspace vs chronological). Device-local UI pref.
  public var loadGroupingMode: @Sendable () -> SessionGroupingMode = { .default }
  public var saveGroupingMode: @Sendable (_ mode: SessionGroupingMode) -> Void
  /// Which destructive action the session list's trailing swipe defaults to
  /// (archive vs permanent delete). Device-local UI pref; reset on logout.
  public var loadDefaultSessionSwipeAction: @Sendable () -> SessionSwipeAction = { .default }
  public var saveDefaultSessionSwipeAction: @Sendable (_ action: SessionSwipeAction) -> Void
  /// Whether the session list shows the always-on "Cron Jobs" section. Device-local UI
  /// pref; defaults to `true` (shown) so the section stays visible until the user opts out.
  public var loadShowCronSection: @Sendable () -> Bool = { true }
  public var saveShowCronSection: @Sendable (_ show: Bool) -> Void
  /// Whether the transcript renders tool/skill activity rows. The separate live
  /// thinking indicator remains visible. Defaults to `false`; an explicit saved choice wins.
  public var loadShowToolRows: @Sendable () -> Bool = { false }
  public var saveShowToolRows: @Sendable (_ show: Bool) -> Void
  /// Whether the transcript renders frozen "Thinking" disclosure rows. The live
  /// indicator remains visible. Defaults to `false`; an explicit saved choice wins.
  public var loadShowThinkingRows: @Sendable () -> Bool = { false }
  public var saveShowThinkingRows: @Sendable (_ show: Bool) -> Void
  /// Whether the transcript follows new rows to the bottom while a turn streams, i.e.
  /// whether arriving content may move the viewport. Device-local UI pref; defaults to
  /// `true` (follow) — the pre-feature behavior. Turning it off freezes the viewport
  /// where the user left it, so a long-running turn can't scroll the text away from
  /// under someone reading an earlier reply.
  public var loadAutoFollowEnabled: @Sendable () -> Bool = { true }
  public var saveAutoFollowEnabled: @Sendable (_ enabled: Bool) -> Void
  /// Currently selected Hermes profile name. Device-local — we never change the server's
  /// sticky active profile. `nil` means the default profile.
  public var loadSelectedProfileID: @Sendable () -> String? = { nil }
  public var saveSelectedProfileID: @Sendable (_ id: String) -> Void
  public var clearSelectedProfileID: @Sendable () -> Void
  /// Last APNs device token we registered with the agent (lowercase hex). Non-secret — it's
  /// just the routing address. Persisted so logout can `unregisterPush` with the right token
  /// even if the live `register()` stream isn't currently producing one. Cleared on logout.
  public var loadPushDeviceToken: @Sendable () -> String? = { nil }
  public var savePushDeviceToken: @Sendable (_ token: String) -> Void
  public var clearPushDeviceToken: @Sendable () -> Void
  /// Push info-sheet snooze: the number of "Later" taps so far (drives the Fibonacci backoff)
  /// and the Date until which the sheet stays suppressed. `nil` count/date means never snoozed.
  /// Cleared on logout (and when the plugin becomes ready, so a later uninstall re-prompts fresh).
  public var loadPushPromptSnooze: @Sendable () -> (count: Int, until: Date)? = { nil }
  public var savePushPromptSnooze: @Sendable (_ count: Int, _ until: Date) -> Void
  public var clearPushPromptSnooze: @Sendable () -> Void
  /// Non-secret identity of the backend update THIS phone started, scoped to one
  /// server/account (`notificationPreferenceScope`). One slot only: loading under a
  /// different scope clears it, so ownership never crosses servers or accounts.
  public var loadOwnedAgentUpdate: @Sendable (_ scope: String) -> String? = { _ in nil }
  public var saveOwnedAgentUpdate: @Sendable (_ scope: String, _ actionID: String) -> Void
  /// Compare-and-clear: removes the slot only if it still names this scope + action.
  public var clearOwnedAgentUpdate: @Sendable (_ scope: String, _ actionID: String) -> Void
  /// Persist the owned ID together with the non-secret time the phone sent the POST (a lower
  /// bound for the server run's `started_at`), so an older receipt can't settle a newer run.
  public var saveOwnedAgentUpdateRequested: @Sendable (_ scope: String, _ actionID: String, _ requestedAt: Date) -> Void = { _, _, _ in }
  /// The POST time saved with the owned ID, or nil (unknown/legacy) for this scope.
  public var loadOwnedAgentUpdateRequestedAt: @Sendable (_ scope: String) -> Date? = { _ in nil }
}

/// Persisted form of `PreferencesClient.loadOwnedAgentUpdate`.
struct OwnedAgentUpdate: Codable, Equatable, Sendable {
  var scope: String
  var actionID: String
  var requestedAt: Date?

  func names(_ scope: String, _ actionID: String) -> Bool { self.scope == scope && self.actionID == actionID }
}

public extension PreferencesClient {
  /// Drop the prefs that are scoped to a *specific user/account* — pins, per-session unread
  /// counts, and the selected profile. Used on a re-auth **user-switch** (different account
  /// signs in mid-session) where the prior user's device-local state must not leak across.
  /// The server URL (and grouping mode) survive — the user stays on the same server.
  func clearIdentityScopedPrefs() {
    savePinnedIDs([])
    saveSeenCounts([:])
    clearSelectedProfileID()
  }
}

public extension PreferencesClient {
  /// `UserDefaults`-backed implementation.
  static func live(defaults: UserDefaults = .standard) -> PreferencesClient {
    let key = "hermes.server-url"
    let seenKey = "hermes.seen-message-counts"
    let pinnedKey = "hermes.pinned-session-ids"
    let groupingKey = "hermes.session-grouping-mode"
    let swipeActionKey = "hermes.default-session-swipe-action"
    let showCronSectionKey = "hermes.show-cron-section"
    let showToolRowsKey = "hermes.show-tool-rows"
    let showThinkingRowsKey = "hermes.show-thinking-rows"
    let autoFollowEnabledKey = "hermes.auto-follow-enabled"
    let selectedProfileKey = "hermes.selected-profile-id"
    let pushTokenKey = "hermes.push-device-token"
    let pushSnoozeCountKey = "hermes.push-prompt-snooze-count"
    let pushSnoozeUntilKey = "hermes.push-prompt-snooze-until"
    let ownedUpdateKey = "hermes.agent-update-owned"
    // UserDefaults is documented thread-safe but not Sendable.
    nonisolated(unsafe) let store = defaults
    return PreferencesClient(
      loadNotificationsEnabled: { scope in store.object(forKey: "hermes.notifications." + scope) as? Bool },
      saveNotificationsEnabled: { scope, enabled in
        notificationPreferenceLock.withLock {
          let removalKey = "hermes.notification-removal." + scope
          let prior = store.data(forKey: removalKey).flatMap { try? JSONDecoder().decode(NotificationRemoval.self, from: $0) }
          // Write uncertainty first: interrupted writes must never falsely confirm Off.
          let removal = NotificationRemoval.pending(prior: prior, current: store.string(forKey: pushTokenKey))
          store.set(try? JSONEncoder().encode(removal), forKey: removalKey)
          store.set(enabled, forKey: "hermes.notifications." + scope)
        }
      },
      loadNotificationRemoval: { scope in
        notificationPreferenceLock.withLock {
          store.data(forKey: "hermes.notification-removal." + scope)
            .flatMap { try? JSONDecoder().decode(NotificationRemoval.self, from: $0) }
        }
      },
      confirmNotificationRemoval: { scope, operation in
        notificationPreferenceLock.withLock {
          let key = "hermes.notification-removal." + scope
          guard store.object(forKey: "hermes.notifications." + scope) as? Bool == false,
                let data = store.data(forKey: key),
                var removal = try? JSONDecoder().decode(NotificationRemoval.self, from: data),
                removal.operation == operation else { return false }
          removal.confirmed = true
          removal.token = nil
          store.set(try? JSONEncoder().encode(removal), forKey: key)
          return true
        }
      },
      notificationOperation: { scope, operation in await NotificationOperations.shared.run(scope, operation) },
      loadServerURL: { store.string(forKey: key) },
      saveServerURL: { store.set($0, forKey: key) },
      clearServerURL: { store.removeObject(forKey: key) },
      loadSeenCounts: { (store.dictionary(forKey: seenKey) as? [String: Int]) ?? [:] },
      saveSeenCounts: { store.set($0, forKey: seenKey) },
      loadPinnedIDs: { (store.array(forKey: pinnedKey) as? [String]) ?? [] },
      savePinnedIDs: { store.set($0, forKey: pinnedKey) },
      loadGroupingMode: {
        store.string(forKey: groupingKey).flatMap(SessionGroupingMode.init(rawValue:)) ?? .default
      },
      saveGroupingMode: { store.set($0.rawValue, forKey: groupingKey) },
      loadDefaultSessionSwipeAction: {
        store.string(forKey: swipeActionKey).flatMap(SessionSwipeAction.init(rawValue:)) ?? .default
      },
      saveDefaultSessionSwipeAction: { store.set($0.rawValue, forKey: swipeActionKey) },
      loadShowCronSection: {
        // Absent key (never toggled) means shown — the section is on by default.
        store.object(forKey: showCronSectionKey) == nil
          ? true
          : store.bool(forKey: showCronSectionKey)
      },
      saveShowCronSection: { store.set($0, forKey: showCronSectionKey) },
      // Absent activity keys adopt the quieter presentation. Explicit saved choices
      // continue to win; following still defaults to on.
      loadShowToolRows: { store.object(forKey: showToolRowsKey) == nil ? false : store.bool(forKey: showToolRowsKey) },
      saveShowToolRows: { store.set($0, forKey: showToolRowsKey) },
      loadShowThinkingRows: {
        store.object(forKey: showThinkingRowsKey) == nil ? false : store.bool(forKey: showThinkingRowsKey)
      },
      saveShowThinkingRows: { store.set($0, forKey: showThinkingRowsKey) },
      loadAutoFollowEnabled: {
        store.object(forKey: autoFollowEnabledKey) == nil ? true : store.bool(forKey: autoFollowEnabledKey)
      },
      saveAutoFollowEnabled: { store.set($0, forKey: autoFollowEnabledKey) },
      loadSelectedProfileID: { store.string(forKey: selectedProfileKey) },
      saveSelectedProfileID: { store.set($0, forKey: selectedProfileKey) },
      clearSelectedProfileID: { store.removeObject(forKey: selectedProfileKey) },
      loadPushDeviceToken: { store.string(forKey: pushTokenKey) },
      savePushDeviceToken: { store.set($0, forKey: pushTokenKey) },
      clearPushDeviceToken: { store.removeObject(forKey: pushTokenKey) },
      loadPushPromptSnooze: {
        // A missing `until` (never snoozed) returns nil; the count defaults to 0 otherwise.
        guard store.object(forKey: pushSnoozeUntilKey) != nil else { return nil }
        let until = Date(timeIntervalSince1970: store.double(forKey: pushSnoozeUntilKey))
        return (count: store.integer(forKey: pushSnoozeCountKey), until: until)
      },
      savePushPromptSnooze: { count, until in
        store.set(count, forKey: pushSnoozeCountKey)
        store.set(until.timeIntervalSince1970, forKey: pushSnoozeUntilKey)
      },
      clearPushPromptSnooze: {
        store.removeObject(forKey: pushSnoozeCountKey)
        store.removeObject(forKey: pushSnoozeUntilKey)
      },
      loadOwnedAgentUpdate: { scope in
        ownedUpdateLock.withLock {
          guard let data = store.data(forKey: ownedUpdateKey) else { return nil }
          guard let owned = try? JSONDecoder().decode(OwnedAgentUpdate.self, from: data),
                owned.scope == scope else {
            store.removeObject(forKey: ownedUpdateKey)
            return nil
          }
          return owned.actionID
        }
      },
      saveOwnedAgentUpdate: { scope, id in
        ownedUpdateLock.withLock {
          store.set(try? JSONEncoder().encode(OwnedAgentUpdate(scope: scope, actionID: id)), forKey: ownedUpdateKey)
        }
      },
      clearOwnedAgentUpdate: { scope, id in
        ownedUpdateLock.withLock {
          guard let data = store.data(forKey: ownedUpdateKey),
                let owned = try? JSONDecoder().decode(OwnedAgentUpdate.self, from: data),
                owned.names(scope, id) else { return }
          store.removeObject(forKey: ownedUpdateKey)
        }
      },
      saveOwnedAgentUpdateRequested: { scope, id, at in
        ownedUpdateLock.withLock {
          store.set(try? JSONEncoder().encode(OwnedAgentUpdate(scope: scope, actionID: id, requestedAt: at)), forKey: ownedUpdateKey)
        }
      },
      loadOwnedAgentUpdateRequestedAt: { scope in
        ownedUpdateLock.withLock {
          guard let data = store.data(forKey: ownedUpdateKey),
                let owned = try? JSONDecoder().decode(OwnedAgentUpdate.self, from: data),
                owned.scope == scope else { return nil }
          return owned.requestedAt
        }
      }
    )
  }

  /// Deterministic in-memory store for previews and tests.
  static func inMemory() -> PreferencesClient {
    let operations = NotificationOperations()
    let notifications = LockIsolated<[String: Bool]>([:])
    let removals = LockIsolated<[String: NotificationRemoval]>([:])
    let box = LockIsolated<String?>(nil)
    let seen = LockIsolated<[String: Int]>([:])
    let pinned = LockIsolated<[String]>([])
    let grouping = LockIsolated<SessionGroupingMode>(.default)
    let swipeAction = LockIsolated<SessionSwipeAction>(.default)
    let showCronSection = LockIsolated<Bool>(true)
    let showToolRows = LockIsolated<Bool>(false)
    let showThinkingRows = LockIsolated<Bool>(false)
    let autoFollowEnabled = LockIsolated<Bool>(true)
    let selectedProfile = LockIsolated<String?>(nil)
    let pushToken = LockIsolated<String?>(nil)
    let pushSnooze = LockIsolated<(count: Int, until: Date)?>(nil)
    let ownedUpdate = LockIsolated<OwnedAgentUpdate?>(nil)
    return PreferencesClient(
      loadNotificationsEnabled: { notifications.value[$0] },
      saveNotificationsEnabled: { scope, enabled in
        notificationPreferenceLock.withLock {
          removals.withValue { values in
            values[scope] = NotificationRemoval.pending(prior: values[scope], current: pushToken.value)
          }
          notifications.withValue { $0[scope] = enabled }
        }
      },
      loadNotificationRemoval: { scope in notificationPreferenceLock.withLock { removals.value[scope] } },
      confirmNotificationRemoval: { scope, operation in
        notificationPreferenceLock.withLock {
          guard notifications.value[scope] == false else { return false }
          return removals.withValue { values in
            guard var value = values[scope], value.operation == operation else { return false }
            value.confirmed = true; value.token = nil; values[scope] = value
            return true
          }
        }
      },
      notificationOperation: { scope, operation in await operations.run(scope, operation) },
      loadServerURL: { box.value },
      saveServerURL: { url in box.setValue(url) },
      clearServerURL: { box.setValue(nil) },
      loadSeenCounts: { seen.value },
      saveSeenCounts: { seen.setValue($0) },
      loadPinnedIDs: { pinned.value },
      savePinnedIDs: { pinned.setValue($0) },
      loadGroupingMode: { grouping.value },
      saveGroupingMode: { grouping.setValue($0) },
      loadDefaultSessionSwipeAction: { swipeAction.value },
      saveDefaultSessionSwipeAction: { swipeAction.setValue($0) },
      loadShowCronSection: { showCronSection.value },
      saveShowCronSection: { showCronSection.setValue($0) },
      loadShowToolRows: { showToolRows.value },
      saveShowToolRows: { showToolRows.setValue($0) },
      loadShowThinkingRows: { showThinkingRows.value },
      saveShowThinkingRows: { showThinkingRows.setValue($0) },
      loadAutoFollowEnabled: { autoFollowEnabled.value },
      saveAutoFollowEnabled: { autoFollowEnabled.setValue($0) },
      loadSelectedProfileID: { selectedProfile.value },
      saveSelectedProfileID: { selectedProfile.setValue($0) },
      clearSelectedProfileID: { selectedProfile.setValue(nil) },
      loadPushDeviceToken: { pushToken.value },
      savePushDeviceToken: { pushToken.setValue($0) },
      clearPushDeviceToken: { pushToken.setValue(nil) },
      loadPushPromptSnooze: { pushSnooze.value },
      savePushPromptSnooze: { count, until in pushSnooze.setValue((count: count, until: until)) },
      clearPushPromptSnooze: { pushSnooze.setValue(nil) },
      loadOwnedAgentUpdate: { scope in
        ownedUpdate.withValue { value in
          guard let owned = value else { return nil }
          guard owned.scope == scope else { value = nil; return nil }
          return owned.actionID
        }
      },
      saveOwnedAgentUpdate: { scope, id in ownedUpdate.setValue(OwnedAgentUpdate(scope: scope, actionID: id)) },
      clearOwnedAgentUpdate: { scope, id in
        ownedUpdate.withValue { if $0?.names(scope, id) == true { $0 = nil } }
      },
      saveOwnedAgentUpdateRequested: { scope, id, at in
        ownedUpdate.setValue(OwnedAgentUpdate(scope: scope, actionID: id, requestedAt: at))
      },
      loadOwnedAgentUpdateRequestedAt: { scope in
        ownedUpdate.withValue { $0?.scope == scope ? $0?.requestedAt : nil }
      }
    )
  }
}

/// FIFO ownership per account/origin. Actor reentrancy alone would not serialize awaits.
private actor NotificationOperations {
  static let shared = NotificationOperations()
  private var busy: Set<String> = []
  private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

  func run(_ scope: String, _ operation: @Sendable () async -> Void) async {
    if busy.contains(scope) {
      await withCheckedContinuation { waiters[scope, default: []].append($0) }
    } else {
      busy.insert(scope)
    }
    if !Task.isCancelled { await operation() }
    if var queue = waiters[scope], !queue.isEmpty {
      let next = queue.removeFirst()
      waiters[scope] = queue
      next.resume()
    } else {
      busy.remove(scope)
      waiters.removeValue(forKey: scope)
    }
  }
}

extension PreferencesClient: DependencyKey {
  public static var liveValue: PreferencesClient { .live() }
  public static var testValue: PreferencesClient { .inMemory() }
}

public extension DependencyValues {
  var preferences: PreferencesClient {
    get { self[PreferencesClient.self] }
    set { self[PreferencesClient.self] = newValue }
  }
}
