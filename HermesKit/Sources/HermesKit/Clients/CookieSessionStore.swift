import Foundation

private final class CookieRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(_ session: URLSession, task: URLSessionTask,
                  willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                  completionHandler: @escaping (URLRequest?) -> Void) {
    // Authenticated API endpoints do not redirect. Never forward a leased cookie to a redirect.
    completionHandler(nil)
  }
}

private actor CookieRequestGate {
  private var held = false
  private var waiters: [(UUID, CheckedContinuation<Void, Error>)] = []
  private let requestQueued: @Sendable () -> Void
  init(requestQueued: @escaping @Sendable () -> Void) { self.requestQueued = requestQueued }
  func acquire() async throws {
    try Task.checkCancellation()
    if !held { held = true; return }
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        waiters.append((id, continuation))
        requestQueued()
      }
    } onCancel: {
      Task { await self.cancel(id) }
    }
  }
  private func cancel(_ id: UUID) {
    guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return }
    waiters.remove(at: index).1.resume(throwing: CancellationError())
  }
  func release() {
    if waiters.isEmpty { held = false } else { waiters.removeFirst().1.resume() }
  }
}

/// One cookie-login generation. Requests keep an immutable lease; late responses may not
/// overwrite a newer login or resurrect the Keychain after logout. No secrets are logged.
public final class CookieSessionStore: @unchecked Sendable {
  public static let shared = CookieSessionStore(credentialsRotated: {
    CrashCredentialWithdrawal.shared.withdraw()
    ConnectionTraceClient.liveValue.setConsent(false)
  })
  private let lock = NSLock()
  private var generation = UUID()
  private var original: CookieSession?
  private var current: CookieSession?
  private var origin: URL?
  private var persist: (@Sendable (CookieSession) throws -> Void)?
  private var revoked: [CookieSession] = []

  private let credentialsRotated: @Sendable () -> Void
  private let requests: CookieRequestGate

  public init(credentialsRotated: @escaping @Sendable () -> Void = {},
              requestQueued: @escaping @Sendable () -> Void = {}) {
    self.credentialsRotated = credentialsRotated
    requests = CookieRequestGate(requestQueued: requestQueued)
  }

  public func activate(_ session: CookieSession, baseURL: URL? = nil,
                       persist: (@Sendable (CookieSession) throws -> Void)? = nil) {
    lock.withLock {
      generation = UUID()
      original = session
      current = session
      origin = baseURL
      self.persist = persist
      revoked = []
    }
  }

  public func attachPersistence(_ session: CookieSession, persist: @escaping @Sendable (CookieSession) throws -> Void) throws {
    try lock.withLock {
      guard session == original || session == current, let current else { throw CancellationError() }
      try persist(current)
      self.persist = persist
    }
  }

  public func clear() {
    lock.withLock {
      generation = UUID()
      original = nil
      current = nil
      origin = nil
      persist = nil
      revoked = []
    }
  }

  public struct Lease: Equatable, Sendable {
    fileprivate var generation: UUID
    fileprivate var connection: ServerConnection
    fileprivate var session: CookieSession
  }

  public func lease(for connection: ServerConnection) throws -> Lease {
    try lock.withLock {
      if case let .cookie(session) = connection.auth, revoked.contains(session) {
        throw RESTError.unauthorized
      }
      guard case let .cookie(session) = connection.auth,
            session == original || session == current,
            let current else { throw CancellationError() }
      if let origin, origin != connection.baseURL { throw CancellationError() }
      origin = connection.baseURL
      return Lease(generation: generation, connection: connection, session: current)
    }
  }

  /// Bounded artifact receipt shares the REST/ticket serialization domain. Commit header
  /// rotation before reading the body: cancellation/oversize must not roll back refresh.
  public func boundedData(for request: URLRequest, lease: Lease, source: URLSession,
                          maximumBytes: Int,
                          validateResponse: @Sendable (URLResponse) throws -> Void) async throws -> (Data, URLResponse) {
    try await perform(request, lease: lease, source: source,
                      maximumBytes: maximumBytes, validateResponse: validateResponse)
  }

  /// Use an isolated transport jar, never URLSession.shared's mutable automatic jar.
  /// The original connection remains a valid handle after transparent rotations.
  public func data(for request: URLRequest, lease: Lease, source: URLSession) async throws -> (Data, URLResponse) {
    try await perform(request, lease: lease, source: source, maximumBytes: nil, validateResponse: { _ in })
  }

  private func perform(_ request: URLRequest, lease: Lease, source: URLSession,
                       maximumBytes: Int?, validateResponse: @Sendable (URLResponse) throws -> Void) async throws -> (Data, URLResponse) {
    guard let url = request.url, url.user == nil, url.password == nil,
          url.scheme == lease.connection.baseURL.scheme,
          url.host == lease.connection.baseURL.host,
          url.port == lease.connection.baseURL.port else { throw CancellationError() }
    try await requests.acquire()
    defer { Task { await requests.release() } }
    try Task.checkCancellation()
    let latest = try lock.withLock {
      guard generation == lease.generation, let current else { throw CancellationError() }
      return current
    }
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = source.configuration.protocolClasses
    config.httpShouldSetCookies = false
    config.httpCookieAcceptPolicy = .never
    config.urlCache = nil
    config.urlCredentialStorage = nil
    let transport = URLSession(configuration: config, delegate: CookieRedirectGuard(), delegateQueue: nil)
    defer { transport.invalidateAndCancel() }
    for cookie in latest.cookies.compactMap(\.httpCookie) {
      config.httpCookieStorage?.setCookie(cookie)
    }
    // Explicitly attach the current generation's eligible cookies. Automatic cookie
    // injection is not reliable for custom URLProtocol transports and must not own
    // refresh state. The isolated jar supplies Foundation's domain/path/expiry filter.
    let cookies = config.httpCookieStorage?.cookies(for: url) ?? []
    var authenticated = request
    authenticated.httpShouldHandleCookies = false
    authenticated.setValue(nil, forHTTPHeaderField: "Cookie")
    for (name, value) in HTTPCookie.requestHeaderFields(with: cookies) {
      authenticated.setValue(value, forHTTPHeaderField: name)
    }
    if let maximumBytes, maximumBytes < 0 { throw ArtifactDownloadError.tooLarge }
    // All consumers, including ordinary REST and ticket minting, persist rotation
    // at header receipt. A failed/cancelled body must not revive retired cookies.
    let (bytes, response) = try await transport.bytes(for: authenticated)
    try commit(response, lease: lease)
    try validateResponse(response)
    if let maximumBytes, response.expectedContentLength > Int64(maximumBytes) {
      throw ArtifactDownloadError.tooLarge
    }
    var data = Data()
    for try await byte in bytes {
      try Task.checkCancellation()
      try check(lease)
      if let maximumBytes, data.count >= maximumBytes { throw ArtifactDownloadError.tooLarge }
      data.append(byte)
    }
    try Task.checkCancellation()
    try check(lease)
    return (data, response)
  }

  private func check(_ lease: Lease) throws {
    try lock.withLock {
      guard generation == lease.generation else { throw CancellationError() }
    }
  }

  private func commit(_ response: URLResponse, lease: Lease) throws {
    try lock.withLock {
      guard generation == lease.generation else { throw CancellationError() }
      guard let response = response as? HTTPURLResponse,
            let url = response.url,
            url.scheme == lease.connection.baseURL.scheme,
            url.host == lease.connection.baseURL.host,
            url.port == lease.connection.baseURL.port,
            let headers = response.allHeaderFields as? [String: String] else { return }
      let updates = HTTPCookie.cookies(withResponseHeaderFields: headers, for: url)
      guard !updates.isEmpty, var next = current else { return }
      for cookie in updates {
        next.cookies.removeAll { $0.name == cookie.name && $0.domain == cookie.domain && $0.path == cookie.path }
        if cookie.expiresDate.map({ $0 > Date() }) ?? true {
          next.cookies.append(SerializedCookie(cookie))
        }
      }
      guard next != current else { return }
      do {
        try persist?(next)
      } catch {
        // Guard + invalidation share the activation lock. Old responses cannot
        // revoke a replacement login; no retired jar survives a failed write.
        revoked = [original, current].compactMap { $0 }
        generation = UUID()
        original = nil
        current = nil
        origin = nil
        persist = nil
        credentialsRotated()
        throw RESTError.unauthorized
      }
      credentialsRotated()
      current = next
    }
  }
}
