@testable import HermesKit

// MARK: - Test convenience

/// Backward-compatible shorthand so existing tests can keep writing
/// `.gatewayEvent(.messageDelta(...))` instead of `.gatewayEvent(GatewayFrame(.messageDelta(...)))`.
extension ChatFeature.Action {
  static func gatewayEvent(_ event: GatewayEvent) -> Self {
    .gatewayEvent(GatewayFrame(event))
  }
}

/// Let test mocks keep yielding bare `GatewayEvent` values into the frame stream.
extension AsyncStream<GatewayFrame>.Continuation {
  @discardableResult
  func yield(_ event: GatewayEvent) -> YieldResult {
    yield(GatewayFrame(event))
  }
}
