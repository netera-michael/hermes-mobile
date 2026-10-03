import ComposableArchitecture
import DependenciesMacros
import Foundation
import Security
import CryptoKit

/// Stores the Hermes auth session (a bare token in `.token` mode, or the cookie payload +
/// username in `.cookie` mode). Live implementation backs onto the iOS Keychain; an
/// in-memory variant is used for previews and feature tests.
///
/// The session is persisted as a JSON-encoded `AuthSession` under a single Keychain item.
/// `loadSession`/`saveSession`/`deleteSession` are the full-session API; the `…Token`
/// closures are thin token-mode shims (kept as first-class dependency endpoints so the
/// existing token-mode call sites and their test overrides stay unchanged).
@DependencyClient
public struct KeychainClient: Sendable {
  /// Load the full persisted session. For a `.cookie` session this also rehydrates the
  /// captured cookies into the supplied `HTTPCookieStorage` so the REST/WS transports pick
  /// them up on a fresh launch.
  public var loadSession: @Sendable (_ storage: HTTPCookieStorage) -> AuthSession? = { _ in nil }
  /// Deliberately persist a validated fresh login. Rotations must use a captured persistence hook.
  public var saveSession: @Sendable (_ session: AuthSession) throws -> Void
  /// Clear the persisted session. The live implementation also flushes any gated-session
  /// cookies rehydrated into `HTTPCookieStorage.shared` (used by the REST/WS transports) so
  /// no stale cookie outlives logout — call this, not `deleteToken`, on logout.
  public var deleteSession: @Sendable () throws -> Void
  /// Activate a freshly-captured `.cookie` session by rehydrating its cookies into
  /// `HTTPCookieStorage.shared` — the jar the live REST/WS transports read. Call this right
  /// after `passwordLogin` (BEFORE the first authenticated REST call): the login cookies are
  /// otherwise captured only in an isolated jar, so `.shared` stays empty and authenticated
  /// REST calls 401 until the next launch (when `loadSession` rehydrates). Flushes any prior
  /// shared cookies first so a user-switch / re-auth can't mix old and new jars.
  public var activateCookieSession: @Sendable (_ session: CookieSession) -> Void = { _ in }

  /// A generation-bound hook. Only its first deliberate login write can reopen retirement.
  public var persistenceFactory: @Sendable (_ freshLogin: Bool) -> (@Sendable (AuthSession) throws -> Void)? = { _ in nil }

  public func persistence(freshLogin: Bool) -> @Sendable (AuthSession) throws -> Void {
    persistenceFactory(freshLogin) ?? saveSession
  }

  // Token-mode shims — retained as dependency endpoints for byte-identical token behaviour.
  public var loadToken: @Sendable () -> String? = { nil }
  public var saveToken: @Sendable (_ token: String) throws -> Void
  public var deleteToken: @Sendable () throws -> Void
}

public enum KeychainError: Error, Equatable, Sendable {
  case unhandled(OSStatus)
  case retired
  case retirementStorageUnavailable
}

public extension KeychainClient {
  /// Keychain-backed implementation (generic password item).
  static func live(
    service: String = "dev.honcharenko.HermesMobile",
    account: String = "session-token"
  ) -> KeychainClient {
    live(service: service, account: account, operations: .security(service: service, account: account))
  }

  internal static func live(service: String, account: String, operations: KeychainStorageOperations) -> KeychainClient {
    let lifecycle = CredentialLifecycle(service: service, account: account, operations: operations)
    @Sendable func load(_ storage: HTTPCookieStorage) -> AuthSession? {
      CredentialLifecycle.lock.withLock {
        guard let session = lifecycle.load() else { return nil }
        if case let .cookie(cookie) = session {
          let persist = lifecycle.writer(freshLogin: false)
          CookieSessionStore.shared.activate(cookie, persist: { try persist(.cookie($0)) })
        }
        rehydrate(session, into: storage)
        return session
      }
    }
    @Sendable func save(_ session: AuthSession) throws {
      try CredentialLifecycle.lock.withLock {
        let persist = lifecycle.writer(freshLogin: true)
        if case let .cookie(cookie) = session {
          try CookieSessionStore.shared.attachPersistence(cookie, persist: { try persist(.cookie($0)) })
        } else {
          CookieSessionStore.shared.clear()
          try persist(session)
        }
      }
    }
    @Sendable func delete() throws {
      try CredentialLifecycle.lock.withLock {
        CookieSessionStore.shared.clear()
        clearSharedCookies()
        try lifecycle.retire()
      }
    }
    return KeychainClient(
      loadSession: { load($0) },
      saveSession: { try save($0) },
      deleteSession: { try delete() },
      activateCookieSession: { activateSharedCookieSession($0) },
      persistenceFactory: { lifecycle.writer(freshLogin: $0) },
      loadToken: { load(.shared)?.token },
      saveToken: { try save(.token($0)) },
      deleteToken: { try delete() }
    )
  }

  /// Deterministic in-memory store for previews and tests.
  static func inMemory() -> KeychainClient {
    let box = SessionBox()
    @Sendable func load(_ storage: HTTPCookieStorage) -> AuthSession? {
      guard let session = box.get() else { return nil }
      rehydrate(session, into: storage)
      return session
    }
    return KeychainClient(
      loadSession: { load($0) },
      saveSession: { box.set($0) },
      deleteSession: { box.set(nil) },
      // No-op for the in-memory variant: feature tests don't drive the live `.shared` jar, and
      // mutating the process-global jar here would race across parallel suites. Tests that
      // need to assert activation override this endpoint with a spy.
      activateCookieSession: { _ in },
      persistenceFactory: { _ in nil },
      loadToken: { box.get()?.token },
      saveToken: { box.set(.token($0)) },
      deleteToken: { box.set(nil) }
    )
  }
}

/// Rehydrate a freshly-captured `.cookie` session into `HTTPCookieStorage.shared` (flushing
/// any prior cookies first) so the live REST/WS transports authenticate immediately after an
/// in-app login — not just on the next launch.
func activateSharedCookieSession(_ session: CookieSession) {
  CredentialLifecycle.lock.withLock {
    CookieSessionStore.shared.activate(session)
    clearSharedCookies()
    rehydrate(.cookie(session), into: .shared)
  }
}

/// Remove every cookie from `HTTPCookieStorage.shared` — the jar the live REST/WS transports
/// read (and into which a `.cookie` session is rehydrated). Called on session deletion so a
/// gated logout leaves no cookie behind. (We own the shared jar in this app — no third-party
/// cookies share it — so clearing all of them is safe and avoids domain-matching guesswork.)
func clearSharedCookies() {
  let storage = HTTPCookieStorage.shared
  for cookie in storage.cookies ?? [] { storage.deleteCookie(cookie) }
}

/// Decode a persisted `AuthSession`. Falls back to treating a legacy raw-string payload
/// (a bare token written by older builds) as `.token` so existing installs keep working.
private func decodeSession(_ data: Data) -> AuthSession? {
  if let session = try? JSONDecoder().decode(AuthSession.self, from: data) {
    return session
  }
  if let token = String(data: data, encoding: .utf8), !token.isEmpty {
    return .token(token)
  }
  return nil
}

/// Rehydrate a `.cookie` session's cookies into the cookie storage so the transports
/// authenticate on a fresh launch. `.token` sessions need no cookie work.
private func rehydrate(_ session: AuthSession, into storage: HTTPCookieStorage) {
  guard case let .cookie(cookieSession) = session else { return }
  for cookie in cookieSession.cookies.compactMap(\.httpCookie) {
    storage.setCookie(cookie)
  }
}

extension KeychainClient: DependencyKey {
  public static var liveValue: KeychainClient { .live() }
  // Feature tests get a working in-memory store by default (deterministic, isolated).
  public static var testValue: KeychainClient { .inMemory() }
}

public extension DependencyValues {
  var keychain: KeychainClient {
    get { self[KeychainClient.self] }
    set { self[KeychainClient.self] = newValue }
  }
}

/// Lock-guarded box backing the in-memory keychain.
private final class SessionBox: @unchecked Sendable {
  private let lock = NSLock()
  private var value: AuthSession?
  func get() -> AuthSession? { lock.withLock { value } }
  func set(_ newValue: AuthSession?) { lock.withLock { value = newValue } }
}

/// Security operation seams: tests fail deletion below the real lifecycle, not in a stubbed client.
internal struct KeychainStorageOperations: Sendable {
  var read: @Sendable () -> Data?
  var write: @Sendable (Data) throws -> Void
  var delete: @Sendable () throws -> Void

  static func security(service: String, account: String) -> Self {
    @Sendable func identity() -> [String: Any] {
      [kSecClass as String: kSecClassGenericPassword,
       kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    return Self(
      read: {
        var query = identity()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
      },
      write: { data in
        let query = identity()
        // Update rather than delete/add: a failed fresh save must not destroy an existing item.
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
          var add = query
          add[kSecValueData as String] = data
          add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
          let added = SecItemAdd(add as CFDictionary, nil)
          guard added == errSecSuccess else { throw KeychainError.unhandled(added) }
        } else if status != errSecSuccess { throw KeychainError.unhandled(status) }
      },
      delete: {
        let status = SecItemDelete(identity() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.unhandled(status) }
      }
    )
  }
}

/// One synchronous domain for credential disk transitions and cookie activation/rotation.
/// Bearer hooks enter this domain while holding the bearer lock; this domain NEVER enters
/// the bearer store. Cookie uses this same recursive lock, avoiding opposite lock ordering.
internal final class CredentialLifecycle: @unchecked Sendable {
  static let lock = NSRecursiveLock()
  private let record: URL
  private let operations: KeychainStorageOperations
  private struct Record: Codable { var generation: UUID; var retired: Bool }
  // A failed record write still revokes this process. Disk errors are reported, not hidden.
  private static let failedRecords = LockIsolated<[URL: UUID]>([:])

  init(service: String, account: String, operations: KeychainStorageOperations) {
    self.operations = operations
    let identity = try! JSONEncoder().encode([service, account])
    let name = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
    record = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("HermesCredentialRetirement", isDirectory: true)
      .appendingPathComponent(name + ".json")
  }

  private func readRecord() -> Record {
    if let generation = Self.failedRecords.value[record] { return Record(generation: generation, retired: true) }
    do {
      return try JSONDecoder().decode(Record.self, from: Data(contentsOf: record))
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      // Legacy installations are active until their first retirement/fresh save.
      return Record(generation: UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)), retired: false)
    } catch {
      // Stable fail-closed identity lets a newly validated login repair storage,
      // while invalidating every writer captured before corruption was observed.
      let generation = UUID()
      Self.failedRecords.withValue { $0[record] = generation }
      return Record(generation: generation, retired: true)
    }
  }

  private func writeRecord(_ value: Record) throws {
    do {
      try FileManager.default.createDirectory(at: record.deletingLastPathComponent(), withIntermediateDirectories: true)
      try JSONEncoder().encode(value).write(to: record, options: .atomic)
      Self.failedRecords.withValue { $0.removeValue(forKey: record) }
    } catch {
      Self.failedRecords.withValue { $0[record] = UUID() }
      throw KeychainError.retirementStorageUnavailable
    }
  }

  func load() -> AuthSession? {
    Self.lock.withLock {
      guard !readRecord().retired, let data = operations.read() else { return nil }
      return decodeSession(data)
    }
  }

  func retire() throws {
    try Self.lock.withLock {
      // Durable nonsecret record BEFORE touching Security: delete failure cannot restore auth.
      try writeRecord(Record(generation: UUID(), retired: true))
      try operations.delete()
    }
  }

  func writer(freshLogin: Bool) -> @Sendable (AuthSession) throws -> Void {
    let initial = Self.lock.withLock { readRecord().generation }
    let state = LockIsolated((generation: initial, first: freshLogin))
    return { [self] session in
      try Self.lock.withLock {
        try state.withValue { state in
          let current = readRecord()
          guard !Task.isCancelled, current.generation == state.generation,
                state.first || !current.retired else { throw KeychainError.retired }
          if state.first {
            // Keep a failed save or interrupted publication retired, even when replacing
            // an active legacy item. No active record is published before Security succeeds.
            let pending = Record(generation: UUID(), retired: true)
            try writeRecord(pending)
            state.generation = pending.generation
          }
          try operations.write(JSONEncoder().encode(session))
          if state.first {
            let next = Record(generation: UUID(), retired: false)
            try writeRecord(next)
            state.generation = next.generation
            state.first = false
          }
        }
      }
    }
  }
}
