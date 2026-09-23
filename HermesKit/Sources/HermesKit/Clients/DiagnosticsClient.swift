import ComposableArchitecture
import DependenciesMacros
import Foundation

/// Closed vocabulary: callers cannot pass chat text, identifiers, URLs or raw errors.
public enum DiagnosticSignal: String, CaseIterable, Sendable {
  case connectionReady, connectionFailed, sessionOpened, sessionFailed
  case sendStarted, sendFailed, modelChanged, modelChangeFailed, smokeTest

  public var isFailure: Bool {
    switch self {
    case .connectionFailed, .sessionFailed, .sendFailed, .modelChangeFailed, .smokeTest: true
    default: false
    }
  }
}

@DependencyClient
public struct DiagnosticsClient: Sendable {
  public var record: @Sendable (DiagnosticSignal) -> Void
}

extension DiagnosticsClient: DependencyKey {
  // Only the explicitly configured app composition root supplies a real sink.
  public static var liveValue: Self { testValue }
  public static var testValue: Self {
    var client = Self()
    client.record = { _ in }
    return client
  }
}

public extension DependencyValues {
  var diagnostics: DiagnosticsClient {
    get { self[DiagnosticsClient.self] }
    set { self[DiagnosticsClient.self] = newValue }
  }
}

/// Monotonic, process-local budget: at most 10 nonfatals per launch and one per
/// category per minute. Breadcrumbs share the per-category cooldown, not the budget.
public struct DiagnosticBudget: Sendable {
  private var last: [DiagnosticSignal: TimeInterval] = [:]
  private var failures = 0
  public init() {}
  public mutating func accept(_ signal: DiagnosticSignal, uptime: TimeInterval) -> Bool {
    if let previous = last[signal], uptime - previous < 60 { return false }
    if signal.isFailure && failures >= 10 { return false }
    last[signal] = uptime
    if signal.isFailure { failures += 1 }
    return true
  }
}
