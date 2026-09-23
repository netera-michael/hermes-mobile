extension ChatFeature {
  /// Pattern matching deliberately ignores every associated payload.
  static func diagnosticSignal(for action: Action) -> DiagnosticSignal? {
    switch action {
    case let .gatewayEvent(frame):
      switch frame.event {
      case .ready: return .connectionReady
      case .error: return .connectionFailed
      case .messageStart: return .sendStarted
      default: return nil
      }
    case .sessionResult(.success), .activateResult(.success): return .sessionOpened
    case .sessionResult(.failure), .activateResult(.failure): return .sessionFailed
    case .promptSubmitFailed: return .sendFailed
    case .modelSelected: return .modelChanged
    case .configSetFailed: return .modelChangeFailed
    default: return nil
    }
  }
}
