import ComposableArchitecture
import DependenciesMacros
import Foundation

/// Closed vocabulary: no gateway debug summaries or user content enter this buffer.
public enum ConnectionTraceKind: String, CaseIterable, Sendable, Codable {
  case slotOpened, slotReplaced, slotCleared, socketDial, socketReady, socketClosed
  case socketSuspended, reconnectScheduled, hydrateStarted, hydrateSucceeded, hydrateFailed
  case sendStarted, sendAccepted, sendTimedOut, sendDisconnected, sendRejected
  case pollRow, pollFailed, runningChanged
  case hydrateProvenance
}

public enum ConnectionTraceReason: String, Sendable, Codable {
  case poll, stoppedBaseline, newerActivity, staleHeuristic, delegateStart, delegateStop, missingRow
}

/// Wire schema for the optional mobile-telemetry dashboard plugin. Nil fields encode as null.
/// Session IDs are validated at construction, before either clipboard or HTTP serialization.
public struct ConnectionTraceEntry: Equatable, Sendable, Encodable {
  public let timestamp: Date
  public let generation: Int
  public let sendID: UUID?
  public let kind: ConnectionTraceKind
  public let sessionID: String?
  public let serverActive: Bool?
  public let displayActive: Bool?
  public let baseline: Bool?
  public let rowCount: Int?
  public let reason: ConnectionTraceReason?
  /// Row-provenance diagnostic: how many user-role rows came from the server's `messages`.
  public let persistedUserRows: Int?
  /// Row-provenance diagnostic: whether `inflight.user` contributed an extra user row.
  public let inflightUserRow: Bool?
  /// Row-provenance diagnostic: whether the tail-dedup suppressed a duplicate inflight user row.
  public let dedupFired: Bool?

  public init(timestamp: Date, generation: Int, sendID: UUID? = nil,
              kind: ConnectionTraceKind, sessionID: String? = nil,
              serverActive: Bool? = nil, displayActive: Bool? = nil,
              baseline: Bool? = nil, rowCount: Int? = nil,
              reason: ConnectionTraceReason? = nil,
              persistedUserRows: Int? = nil, inflightUserRow: Bool? = nil,
              dedupFired: Bool? = nil) {
    self.timestamp = timestamp
    self.generation = generation
    self.sendID = sendID
    self.kind = kind
    // Match the dashboard schema: opaque 1–128-byte ASCII session IDs only.
    self.sessionID = sessionID.flatMap { id in
      guard !id.isEmpty, id.utf8.count <= 128,
            id.unicodeScalars.enumerated().allSatisfy({ index, scalar in
              let value = scalar.value
              return (value >= 65 && value <= 90) || (value >= 97 && value <= 122)
                || (value >= 48 && value <= 57)
                || (index > 0 && (scalar == "." || scalar == "_" || scalar == ":" || scalar == "-"))
            }) else { return nil }
      return id
    }
    self.serverActive = serverActive
    self.displayActive = displayActive
    self.baseline = baseline
    self.rowCount = rowCount.map { min(1_000_000, max(0, $0)) }
    self.reason = reason
    self.persistedUserRows = persistedUserRows.map { min(10_000, max(0, $0)) }
    self.inflightUserRow = inflightUserRow
    self.dedupFired = dedupFired
  }

  enum CodingKeys: String, CodingKey {
    case timestamp = "at", kind, sessionID = "session_id", generation = "slot"
    case sendID = "send_id", serverActive = "server_active"
    case displayActive = "display_active", baseline, rowCount = "rows", reason
    case persistedUserRows = "persisted_user_rows"
    case inflightUserRow = "inflight_user_row", dedupFired = "dedup_fired"
  }

  public func encode(to encoder: Encoder) throws {
    var box = encoder.container(keyedBy: CodingKeys.self)
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    try box.encode(formatter.string(from: timestamp), forKey: .timestamp)
    try box.encode(kind, forKey: .kind)
    try box.encodeIfPresent(sessionID, forKey: .sessionID)
    try box.encode(generation, forKey: .generation)
    try box.encodeIfPresent(sendID?.uuidString, forKey: .sendID)
    try box.encodeIfPresent(serverActive, forKey: .serverActive)
    try box.encodeIfPresent(displayActive, forKey: .displayActive)
    try box.encodeIfPresent(baseline, forKey: .baseline)
    try box.encodeIfPresent(rowCount, forKey: .rowCount)
    try box.encodeIfPresent(reason, forKey: .reason)
    try box.encodeIfPresent(persistedUserRows, forKey: .persistedUserRows)
    try box.encodeIfPresent(inflightUserRow, forKey: .inflightUserRow)
    try box.encodeIfPresent(dedupFired, forKey: .dedupFired)
  }

  public var line: String {
    let stamp = timestamp.formatted(.iso8601)
    return "\(stamp) slot=\(generation) event=\(kind.rawValue)"
      + (sessionID.map { " session=\($0)" } ?? "")
      + (sendID.map { " send=\($0.uuidString)" } ?? "")
      + (serverActive.map { " server_active=\($0)" } ?? "")
      + (displayActive.map { " display_active=\($0)" } ?? "")
      + (baseline.map { " baseline=\($0)" } ?? "")
      + (rowCount.map { " rows=\($0)" } ?? "")
      + (reason.map { " reason=\($0.rawValue)" } ?? "")
  }
}

private struct TraceBatch: Encodable {
  let events: [ConnectionTraceEntry]
}

@DependencyClient
public struct ConnectionTraceClient: Sendable {
  public var append: @Sendable (ConnectionTraceEntry) -> Void
  public var snapshot: @Sendable () -> [ConnectionTraceEntry] = { [] }
  public var nextSlot: @Sendable () -> Int = { 0 }
  public var currentSlot: @Sendable () -> Int = { 0 }
  /// Explicit foreground/poll-triggered attempt; never schedules timers or background work.
  public var upload: @Sendable (ServerConnection) async -> Void = { _ in }
}

extension ConnectionTraceClient: DependencyKey {
  public static let liveValue: Self = .ringBuffer()
  public static var testValue: Self {
    var client = Self()
    client.append = { _ in }
    client.snapshot = { [] }
    client.nextSlot = { 0 }
    client.currentSlot = { 0 }
    client.upload = { _ in }
    return client
  }

  public static func ringBuffer(capacity: Int = 300) -> Self {
    let buffer = ConnectionTraceBuffer(capacity: capacity)
    var client = Self()
    client.append = { buffer.append($0) }
    client.snapshot = { buffer.snapshot() }
    client.nextSlot = { buffer.nextSlot() }
    client.currentSlot = { buffer.currentSlot() }
    client.upload = { connection in await buffer.upload(connection) }
    return client
  }
}

public extension DependencyValues {
  var connectionTrace: ConnectionTraceClient {
    get { self[ConnectionTraceClient.self] }
    set { self[ConnectionTraceClient.self] = newValue }
  }
}

private actor ConnectionTraceBuffer {
  // Synchronous append is needed in reducers. The lock guards only the ring, not network IO.
  nonisolated let storage: TraceStorage
  init(capacity: Int) { storage = TraceStorage(capacity: capacity) }
  nonisolated func nextSlot() -> Int { storage.nextSlot() }
  nonisolated func currentSlot() -> Int { storage.currentSlot() }
  nonisolated func append(_ entry: ConnectionTraceEntry) { storage.append(entry) }
  nonisolated func snapshot() -> [ConnectionTraceEntry] { storage.snapshot() }

  func upload(_ connection: ServerConnection) async {
    // The dashboard plugin contract currently supports the existing token mode only.
    guard let token = connection.token, !token.isEmpty else { return }
    let entries = storage.pending(limit: 50)
    guard !entries.isEmpty else { return }
    guard let url = URL(string: "/api/plugins/mobile-telemetry/events", relativeTo: connection.baseURL)?.absoluteURL,
          url.scheme == "http" || url.scheme == "https",
          url.host == connection.baseURL.host else { return }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 8
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(token, forHTTPHeaderField: "X-Hermes-Session-Token")
    guard let body = try? JSONEncoder().encode(TraceBatch(events: entries)) else { return }
    request.httpBody = body
    do {
      let (_, response) = try await URLSession.shared.data(for: request)
      guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return }
      storage.acknowledge(entries)
    } catch { /* No logging of request, credentials, response body, or events. Retry on activity. */ }
  }
}

private final class TraceStorage: @unchecked Sendable {
  private let lock = NSLock()
  private let capacity: Int
  private var entries: [ConnectionTraceEntry] = []
  private var pendingEntries: [ConnectionTraceEntry] = []
  private var slot = 0

  init(capacity: Int) { self.capacity = max(0, capacity) }
  func nextSlot() -> Int { lock.withLock { slot &+= 1; return slot } }
  func currentSlot() -> Int { lock.withLock { slot } }
  func append(_ entry: ConnectionTraceEntry) {
    lock.withLock {
      entries.append(entry)
      pendingEntries.append(entry)
      if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
      if pendingEntries.count > capacity { pendingEntries.removeFirst(pendingEntries.count - capacity) }
    }
  }
  func snapshot() -> [ConnectionTraceEntry] { lock.withLock { entries } }
  func pending(limit: Int) -> [ConnectionTraceEntry] { lock.withLock { Array(pendingEntries.prefix(limit)) } }
  func acknowledge(_ batch: [ConnectionTraceEntry]) {
    lock.withLock {
      // Concurrent appends or capacity evictions never delete newer events.
      for entry in batch {
        if let index = pendingEntries.firstIndex(of: entry) { pendingEntries.remove(at: index) }
      }
    }
  }
}
