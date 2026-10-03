import Foundation

/// A one-shot capability with no generic request API or access to the active login.
public final class LogoutCleanup: @unchecked Sendable {
  private let lock = NSLock()
  private var operation: (@Sendable () async -> Void)?
  init(_ operation: @escaping @Sendable () async -> Void) { self.operation = operation }
  public func run() async {
    let operation = lock.withLock { let value = self.operation; self.operation = nil; return value }
    await operation?()
  }

  static func make(connection: ServerConnection, deviceToken: String?, cookie: CookieSession?,
                   bearer: String?, source: URLSession) -> LogoutCleanup {
    let deadline = Date().addingTimeInterval(5)
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = source.configuration.protocolClasses
    config.httpShouldSetCookies = false
    config.httpCookieAcceptPolicy = .never
    config.urlCredentialStorage = nil
    config.urlCache = nil
    config.timeoutIntervalForRequest = 5
    config.timeoutIntervalForResource = 5
    let transport = URLSession(configuration: config, delegate: LogoutRedirectGuard(), delegateQueue: nil)
    let cleanup = LogoutCleanup {
      let timeout = Task {
        try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
        if !Task.isCancelled { transport.invalidateAndCancel() }
      }
      defer { timeout.cancel(); transport.invalidateAndCancel() }
      var paths: [(String, Data)] = []
      if let deviceToken, let body = try? JSONSerialization.data(withJSONObject: ["device_token": deviceToken]) {
        paths.append(("api/plugins/hermes-push/unregister", body))
      }
      if case .bearer = connection.auth { paths.append(("auth/logout", Data("{}".utf8))) }
      for (path, body) in paths {
        guard !Task.isCancelled, Date() < deadline else { return }
        let url = connection.baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url, timeoutInterval: max(0.01, deadline.timeIntervalSinceNow))
        request.httpMethod = "POST"
        request.httpBody = body
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        switch connection.auth {
        case let .token(token): RequestAuth.sessionToken(token).apply(to: &request)
        case .bearer:
          guard let bearer else { return }
          RequestAuth.bearer(bearer).apply(to: &request)
        case .cookie:
          guard let cookie else { return }
          let jar = URLSessionConfiguration.ephemeral.httpCookieStorage!
          for item in cookie.cookies.compactMap(\.httpCookie) { jar.setCookie(item) }
          for (name, value) in HTTPCookie.requestHeaderFields(with: jar.cookies(for: url) ?? []) {
            request.setValue(value, forHTTPHeaderField: name)
          }
        }
        // No response cookies are consumed; there is no persistence callback.
        _ = try? await transport.data(for: request)
      }
    }
    // Release the captured credential even when the effect is never scheduled.
    Task { [weak cleanup] in
      try? await Task.sleep(for: .seconds(5))
      cleanup?.expire()
      transport.invalidateAndCancel()
    }
    return cleanup
  }

  private func expire() { lock.withLock { operation = nil } }
}

private final class LogoutRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(_ session: URLSession, task: URLSessionTask,
                  willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                  completionHandler: @escaping (URLRequest?) -> Void) {
    completionHandler(nil)
  }
}
