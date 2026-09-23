import ComposableArchitecture
import DependenciesMacros
import Foundation

/// Deliberately separate from DebugLogClient: gateway summaries may contain chat content.
/// This vocabulary cannot carry a URL, message, session/profile identifier, or raw error.
public enum ConnectionTraceKind: String, CaseIterable, Sendable {
  case slotOpened, slotReplaced, slotCleared, socketDial, socketReady, socketClosed
  case socketSuspended, reconnectScheduled, hydrateStarted, hydrateSucceeded, hydrateFailed
  case sendStarted, sendAccepted, sendTimedOut, sendDisconnected, sendRejected
}

public struct ConnectionTraceEntry: Equatable, Sendable {
  public let timestamp: Date
  public let generation: Int
  public let sendID: UUID?
  public let kind: ConnectionTraceKind
  public let rowCount: Int?

  public init(timestamp: Date, generation: Int, sendID: UUID? = nil,
              kind: ConnectionTraceKind, rowCount: Int? = nil) {
    self.timestamp = timestamp
    self.generation = generation
    self.sendID = sendID
    self.kind = kind
    self.rowCount = rowCount.map { max(0, $0) }
  }

  /// Only closed enum labels and numerical values reach the clipboard.
  public var line: String {
    let stamp = timestamp.formatted(.iso8601)
    return "\(stamp) slot=\(generation) event=\(kind.rawValue)"
      + (sendID.map { " send=\($0.uuidString)" } ?? "")
      + (rowCount.map { " rows=\($0)" } ?? "")
  }
}

@DependencyClient
public struct ConnectionTraceClient: Sendable {
  public var append: @Sendable (ConnectionTraceEntry) -> Void
  public var snapshot: @Sendable () -> [ConnectionTraceEntry] = { [] }
  /// Advances on slot seating without adding trace-only state to the app reducer.
  public var nextSlot: @Sendable () -> Int = { 0 }
  public var currentSlot: @Sendable () -> Int = { 0 }
}

extension ConnectionTraceClient: DependencyKey {
  public static let liveValue: Self = .ringBuffer()
  public static var testValue: Self {
    var client = Self()
    client.append = { _ in }
    client.snapshot = { [] }
    client.nextSlot = { 0 }
    client.currentSlot = { 0 }
    return client
  }

  public static func ringBuffer(capacity: Int = 300) -> Self {
    let buffer = ConnectionTraceBuffer(capacity: capacity)
    var client = Self()
    client.append = { buffer.append($0) }
    client.snapshot = { buffer.snapshot() }
    client.nextSlot = { buffer.nextSlot() }
    client.currentSlot = { buffer.currentSlot() }
    return client
  }
}

public extension DependencyValues {
  var connectionTrace: ConnectionTraceClient {
    get { self[ConnectionTraceClient.self] }
    set { self[ConnectionTraceClient.self] = newValue }
  }
}

private final class ConnectionTraceBuffer: @unchecked Sendable {
  private let lock = NSLock()
  private let capacity: Int
  private var entries: [ConnectionTraceEntry] = []
  private var slot = 0

  init(capacity: Int) { self.capacity = max(0, capacity) }
  func nextSlot() -> Int { lock.withLock { slot &+= 1; return slot } }
  func currentSlot() -> Int { lock.withLock { slot } }
  func append(_ entry: ConnectionTraceEntry) {
    lock.withLock {
      entries.append(entry)
      if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
    }
  }
  func snapshot() -> [ConnectionTraceEntry] { lock.withLock { entries } }
}
