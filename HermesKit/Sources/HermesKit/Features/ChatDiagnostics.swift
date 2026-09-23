extension ChatFeature {
  /// Pattern matching deliberately ignores every associated payload.
  static func diagnosticSignal(for action: Action) -> DiagnosticSignal? {
    switch action {
    case .gatewayEvent(.ready): .connectionReady
    case .gatewayEvent(.error): .connectionFailed
    case .sessionResult(.success), .activateResult(.success): .sessionOpened
    case .sessionResult(.failure), .activateResult(.failure): .sessionFailed
    case .gatewayEvent(.messageStart): .sendStarted
    case .promptSubmitFailed: .sendFailed
    case .modelSelected: .modelChanged
    case .configSetFailed: .modelChangeFailed
    default: nil
    }
  }
}
