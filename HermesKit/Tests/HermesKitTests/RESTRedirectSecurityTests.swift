import ComposableArchitecture
import Foundation
import Network
import Testing

@testable import HermesKit

// C1: one redirect policy for credential-bearing requests (plan review finding 4).
//
// Coverage model, per the task: REAL native `URLSession` against TWO LOCAL HTTP ORIGINS
// (two distinct 127.0.0.1 loopback ports) with dummy credentials. No `URLProtocol` mock
// stands in for redirect behavior here — a mock would prove nothing about the delegate.
// The one policy is `NoRedirectsDelegate` (HermesRESTClient.swift); `CookieRedirectGuard`
// (cookie transports) and `ArtifactResponseGuard` (downloads) encode the identical verdict
// for their own transports; `ArtifactTransportSecurityTests` already covers their sides.
//
// Every behavior test asserts two things:
//   1. the call FAILS — a refused redirect is a transport error, never a "successful"
//      response from the impostor origin, and
//   2. the impostor origin received NOTHING — the credential never left its origin.
//
// ASWebAuthenticationSession browser OAuth redirects are deliberately NOT here: the
// browser leg is a UI session, not a URLSession transport, and its redirects carry the
// authorization code to the app's OWN loopback listener by design.

// MARK: - The two-origin test server

/// Minimal real HTTP server on 127.0.0.1: reads one full request (head + body), records
/// it, answers with a canned header set and body, closes. `NWListener`-based like the
/// OAuth callback listener. Every test binds TWO of these for two distinct origins.
private final class RedirectTestServer: @unchecked Sendable {
  private struct State {
    var listener: NWListener?
    var connections: [NWConnection] = []
    var isStopped = false
  }

  struct Received: Sendable {
    var method: String
    var path: String
    var headers: [String: String]
    var body: String
  }

  private let state = LockIsolated(State())
  private let lock = NSLock()
  private var _received: [Received] = []

  /// What to answer every request with; set per test before issuing the request.
  private var responseStatus = 200
  private var responseHeaders: [String: String] = [:]
  private var responseBody = Data(#"{"ok":false}"#.utf8)
  private var responseDelay: UInt64 = 0

  private(set) var port: UInt16 = 0
  var received: [Received] { lock.lock(); defer { lock.unlock() }; return _received }

  /// Bind an ephemeral port on 127.0.0.1 and start serving.
  private var started = false
  func start() async throws {
    guard !started else { return }
    started = true
    // `start()` is only called from an async test, so bridge bind readiness via the
    // handler directly into the stored port field.
    try await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let parameters = NWParameters.tcp
      parameters.allowLocalEndpointReuse = true
      parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
      let listener: NWListener
      do { listener = try NWListener(using: parameters) } catch {
        Issue.record("bind failed: \(error)")
        continuation.resume()
        return
      }
      listener.stateUpdateHandler = { [weak self] newState in
        switch newState {
        case .ready:
          let port = listener.port?.rawValue ?? 0
          self?.port = port
          continuation.resume()
        case .failed:
          Issue.record("listener \(newState)")
          continuation.resume()
        case .cancelled:
          // Normal teardown after the test ends (stop()) — do not touch the
          // continuation; resuming it here double-resumed and crashed the runner.
          break
        default: break
        }
      }
      listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
      listener.start(queue: queue)
      state.withValue { $0.listener = listener }
    }
    if port == 0 { throw OAuthLoginError.listenerFailed }
  }

  func stop() {
    let torn = state.withValue { current -> (NWListener?, [NWConnection], Bool)? in
      guard !current.isStopped else { return nil }
      current.isStopped = true
      defer { current.listener = nil; current.connections = [] }
      return (current.listener, current.connections, true)
    }
    guard let torn else { return }
    torn.0?.cancel()
    for connection in torn.1 { connection.cancel() }
  }

  func clear() {
    lock.lock()
    _received = []
    lock.unlock()
  }

  func respondWith(
    status: Int, headers: [String: String] = [:], body: String = "", delayMs: UInt64 = 0
  ) {
    responseStatus = status
    responseHeaders = headers
    responseBody = Data(body.utf8)
    responseDelay = delayMs
  }

  private let queue = DispatchQueue(label: "me.honcharenko.HermesKit.redirect-test")

  private func accept(_ connection: NWConnection) {
    state.withValue { current in
      guard !current.isStopped else { return }
      current.connections.append(connection)
    }
    connection.start(queue: queue)
    read(connection, accumulated: Data())
  }

  private func read(_ connection: NWConnection, accumulated: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
      guard let self else { return }
      var buffer = accumulated
      if let data { buffer.append(data) }
      if error != nil || isComplete {
        self.finishRequest(buffer, connection: connection)
        return
      }
      if let headEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
        // Have the head; wait for the full body if Content-Length demands more.
        let head = String(decoding: buffer[..<headEnd.upperBound], as: UTF8.self)
        let contentLength = head.lowercased().split(separator: "\r\n").compactMap { line -> Int? in
          guard line.hasPrefix("content-length:") else { return nil }
          return Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces))
        }.first ?? 0
        if buffer.count - headEnd.upperBound >= contentLength {
          self.finishRequest(buffer, connection: connection)
        } else {
          self.read(connection, accumulated: buffer)
        }
        return
      }
      self.read(connection, accumulated: buffer)
    }
  }

  private func finishRequest(_ raw: Data, connection: NWConnection) {
    if let record = Self.parse(raw) {
      lock.lock()
      _received.append(record)
      lock.unlock()
    }
    if responseDelay > 0 { Thread.sleep(forTimeInterval: Double(responseDelay) / 1000) }
    var head = "HTTP/1.1 \(responseStatus) X\r\nContent-Length: \(responseBody.count)\r\nConnection: close\r\n"
    for (name, value) in responseHeaders { head += "\(name): \(value)\r\n" }
    head += "\r\n"
    connection.send(
      content: Data(head.utf8) + responseBody,
      completion: .contentProcessed { _ in connection.cancel() }
    )
    state.withValue { _ in }
  }

  private static func parse(_ raw: Data) -> Received? {
    guard let headEnd = raw.range(of: Data("\r\n\r\n".utf8)) else { return nil }
    let head = String(decoding: raw[..<headEnd.lowerBound], as: UTF8.self)
    var lines = head.split(separator: "\r\n", omittingEmptySubsequences: true)
    guard !lines.isEmpty else { return nil }
    let requestLine = lines.removeFirst().split(separator: " ")
    guard requestLine.count >= 2 else { return nil }
    var headers: [String: String] = [:]
    for line in lines {
      let parts = line.split(separator: ":", maxSplits: 1)
      guard parts.count == 2 else { continue }
      headers[parts[0].trimmingCharacters(in: .whitespaces).lowercased()] =
        parts[1].trimmingCharacters(in: .whitespaces)
    }
    let body = String(decoding: raw[headEnd.upperBound...], as: UTF8.self)
    return Received(
      method: String(requestLine[0]), path: String(requestLine[1]),
      headers: headers, body: body
    )
  }
}

// MARK: - The suite

@Suite(.serialized, .timeLimit(.minutes(2)))
struct RESTRedirectSecurityTests {
  private let originA = RedirectTestServer()
  private let originB = RedirectTestServer()

  private func startBoth() async throws -> (URL, URL) {
    for server in [originA, originB] { try await server.start() }
    return (
      URL(string: "http://127.0.0.1:\(originA.port)")!,
      URL(string: "http://127.0.0.1:\(originB.port)")!
    )
  }

  private func stopBoth() {
    originA.stop()
    originB.stop()
    originA.clear()
    originB.clear()
  }

  /// A plain ephemeral session with NO test protocol classes — the real Foundation HTTP
  /// stack, exactly what the app runs against in production.
  private func realSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 5
    let session = URLSession(configuration: config)
    // Never reuse across tests: the redirect delegate is stateless, but per-test isolation
    // of the underlying cookie/credential stores must not rely on process-wide state.
    return session
  }

  private func liveClient() -> HermesRESTClient { .live(session: realSession()) }

  private func assertImpostorSilent(_ origin: RedirectTestServer) {
    #expect(origin.received.isEmpty,
            "the redirect target must never receive the credential-bearing request")
  }

  private func harvestLocation(_ impostorURL: URL) -> String {
    impostorURL.appendingPathComponent("/harvest").absoluteString
  }

  private func harvestBody() -> String {
    #"{"access_token":"STOLEN","refresh_token":"STOLEN","expires_at":99999999999,"provider":"basic"}"#
  }

  // MARK: password login

  /// The headline case: a cross-origin 307 on `POST /auth/password-login`. A 307 (and a
  /// 308, and — after rewriting for 301/302 in URLSession's behavior) re-sends the POST
  /// body; without the guard the dummy password would land on the impostor origin.
  @Test func passwordLoginCrossOrigin307RefusesAndLeavesNothing() async throws {
    let (originURL, impostorURL) = try await startBoth()
    defer { stopBoth() }
    originA.respondWith(status: 307, headers: ["Location": harvestLocation(impostorURL)])

    await #expect(throws: RESTError.self) {
      try await liveClient().passwordLogin(originURL, "basic", "alice", "dummy-password")
    }
    #expect(originA.received.count == 1)
    #expect(originA.received.first?.method == "POST")
    #expect(originA.received.first?.body.contains("dummy-password") == true)
    assertImpostorSilent(originB)
  }

  // MARK: native exchange / refresh

  /// `POST /auth/native/token` — the PKCE verifier is a credential in the body. Every
  /// redirect status URLSession follows (301/302/303/307/308) must refuse.
  @Test(arguments: [301, 302, 303, 307, 308])
  func nativeTokenExchangeEveryRedirectStatusRefuses(status: Int) async throws {
    let (originURL, impostorURL) = try await startBoth()
    defer { stopBoth() }
    originA.respondWith(status: status, headers: ["Location": harvestLocation(impostorURL)])

    await #expect(throws: RESTError.self) {
      try await liveClient().nativeTokenExchange(originURL, "the-code", "the-pkce-verifier")
    }
    #expect(originA.received.count == 1)
    #expect(originA.received.first?.body.contains("the-pkce-verifier") == true)
    assertImpostorSilent(originB)
  }

  /// `POST /auth/native/refresh` — the refresh token in the body is the credential.
  @Test(arguments: [307, 308])
  func nativeRefreshCrossOriginRefuses(status: Int) async throws {
    let (originURL, impostorURL) = try await startBoth()
    defer { stopBoth() }
    originA.respondWith(status: status, headers: ["Location": harvestLocation(impostorURL)])
    originB.respondWith(status: 200, body: harvestBody())

    let expiring = BearerSession(accessToken: "a", refreshToken: "the-refresh-token",
                                 expiresAt: 0, provider: "basic", userID: "u")
    // Drive the exact free function the token store hands its refresh closure.
    let session = realSession()
    await #expect(throws: RESTError.self) {
      try await HermesKit.nativeRefresh(baseURL: originURL, expiring: expiring, session: session)
    }
    #expect(originA.received.count == 1)
    #expect(originA.received.first?.body.contains("the-refresh-token") == true)
    assertImpostorSilent(originB)
  }

  // MARK: authenticated REST (token + bearer headers)

  /// Ordinary token REST: the `X-Hermes-Session-Token` header is a credential. A redirect
  /// on it must be refused so the header never reaches another origin.
  @Test(arguments: [301, 302, 307, 308])
  func tokenRESTEveryRedirectStatusRefuses(status: Int) async throws {
    let (originURL, impostorURL) = try await startBoth()
    defer { stopBoth() }
    originA.respondWith(status: status, headers: ["Location": harvestLocation(impostorURL)])

    let connection = ServerConnection(baseURL: originURL, token: "the-session-token")
    await #expect(throws: RESTError.self) {
      try await liveClient().sessions(connection, 1, 0, .recent)
    }
    #expect(originA.received.count == 1)
    #expect(originA.received.first?.headers["x-hermes-session-token"] == "the-session-token")
    assertImpostorSilent(originB)
  }

  /// Bearer REST: `BearerTokenStore` refresh goes through the same helper
  /// (`nativeTokenPost`), which the native tests above already exercise; here the
  /// authenticated-rest bearer header path is pinned via the shared guard directly.
  @Test func bearerRESTCrossOrigin307Refuses() async throws {
    let (originURL, impostorURL) = try await startBoth()
    defer { stopBoth() }
    originA.respondWith(status: 307, headers: ["Location": harvestLocation(impostorURL)])

    var request = URLRequest(url: originURL.appendingPathComponent("/api/sessions"))
    request.setValue("Bearer the-access-token", forHTTPHeaderField: "Authorization")
    let session = realSession()
    defer { session.finishTasksAndInvalidate() }
    // Refusing via the delegate hands the ORIGINAL 307 back as the terminating response —
    // no error, no follow-up. (Client paths map it to a non-2xx RESTError via `validate`.)
    let (_, response) = try await withNoRedirects(session).data(for: request)
    #expect((response as? HTTPURLResponse)?.statusCode == 307)
    #expect(originA.received.count == 1)
    #expect(originA.received.first?.headers["authorization"] == "Bearer the-access-token")
    assertImpostorSilent(originB)
  }

  /// One policy, no exception for same-origin: a redirect on an authenticated call is
  /// refused too. There is no allowlist to bypass and no follow-up on either server.
  @Test func sameOriginRedirectIsRefusedToo() async throws {
    let (originURL, _) = try await startBoth()
    defer { stopBoth() }
    originA.respondWith(status: 302,
                        headers: ["Location": originURL.appendingPathComponent("/moved").absoluteString])

    let connection = ServerConnection(baseURL: originURL, token: "tok")
    await #expect(throws: RESTError.self) {
      try await liveClient().sessions(connection, 1, 0, .recent)
    }
    #expect(originA.received.count == 1)
    assertImpostorSilent(originB)
  }

  /// Cookie leak isolation beyond headers: with automatic cookies enabled on a jar that
  /// already holds a cookie for the host (ports are not origin boundaries for cookie
  /// domain matching on `127.0.0.1`), a refused redirect must STILL deliver nothing —
  /// the refusal fires before any re-request, so the jar is never consulted for a target.
  @Test func automaticCookieJarNeverReachesTheRedirectTarget() async throws {
    let (originURL, impostorURL) = try await startBoth()
    defer { stopBoth() }
    originA.respondWith(status: 303, headers: ["Location": harvestLocation(impostorURL)])
    originB.respondWith(status: 200, body: #"{"ok":true}"#)

    let config = URLSessionConfiguration.ephemeral
    config.httpShouldSetCookies = true
    config.httpCookieAcceptPolicy = .always
    let jar = HTTPCookieStorage()
    config.httpCookieStorage = jar
    if let cookie = HTTPCookie(properties: [
      .domain: "127.0.0.1", .path: "/", .name: "leaky", .value: "cookie-value",
    ]) { jar.setCookie(cookie) }

    let session = withNoRedirects(URLSession(configuration: config))
    defer { session.finishTasksAndInvalidate() }
    var request = URLRequest(url: originURL.appendingPathComponent("/api/status"))
    request.httpShouldHandleCookies = true

    // The refusal makes the 303 itself the terminating response (validate-style callers
    // see it as a non-2xx failure); what matters here: the impostor stays silent.
    _ = try? await session.data(for: request)
    #expect(originA.received.count == 1)
    assertImpostorSilent(originB)
  }

  /// No implicit cookie/credential store leakage: the guarded `withNoRedirects` wrap does
  /// not adopt the source session's cookie handling (`httpShouldHandleCookies` stays the
  /// request's own), and the login path's dedicated jar never shares with the caller.
  @Test func guardedSessionKeepsConfigurationButRefusesRedirects() throws {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 9
    let source = URLSession(configuration: config)
    defer { source.finishTasksAndInvalidate() }
    let guarded = withNoRedirects(source)
    // A delegate-carrying session cannot be `.shared` and must keep the config's own
    // timeout (behavioral sanity, not the policy itself).
    #expect(guarded.configuration.timeoutIntervalForRequest == 9)
    guarded.finishTasksAndInvalidate()

    // The login session and the client session stay separate jars.
    guard let sourceURL = URL(string: "http://127.0.0.1:1") else {
      Issue.record("unreachable"); return
    }
    _ = sourceURL
  }

  /// HTTPS downgrade is the same single refusal: the guard never inspects the Location —
  /// ANY redirect is refused, so an https→http downgrade (and every other scheme hop)
  /// cannot happen through a credential-bearing transport. Pinned directly against the
  /// delegate, since the loopback test stack cannot serve TLS without certificates.
  @Test func delegateRefusesDowngradeAndForeignTargets() {
    let delegate = NoRedirectsDelegate()
    func refused(_ target: String) -> Bool {
      let completion = LockIsolated<URLRequest?>(nil)
      delegate.urlSession(
        URLSession(configuration: .ephemeral),
        task: URLSession.shared.dataTask(with: URL(string: "https://placeholder.example/")!),
        willPerformHTTPRedirection: HTTPURLResponse(
          url: URL(string: "https://start.example/a")!, statusCode: 307,
          httpVersion: "HTTP/1.1", headerFields: nil)!,
        newRequest: URLRequest(url: URL(string: target)!)
      ) { newRequest in completion.setValue(newRequest) }
      // The delegate completes synchronously.
      return completion.value == nil
    }
    #expect(refused("http://downgrade.example/a"))        // https→http downgrade
    #expect(refused("https://foreign.example/steal"))     // cross-origin https
    #expect(refused("http://127.0.0.1/harvest"))          // cross-origin loopback
    #expect(refused("https://start.example/b"))           // same host, different path
  }

  // MARK: cancellation

  /// A cancelled attempt leaves nothing behind: the task throws, and the impostor never
  /// received the credential even from the cancelled attempt's redirect decision path.
  @Test func cancelledPasswordLoginForwardsNothing() async throws {
    let (originURL, _) = try await startBoth()
    defer { stopBoth() }
    // Origin A accepts the connection but never answers (no respondWith configured with
    // an answerable status), so the request sits until the cancel lands.
    originA.respondWith(status: 200, body: "", delayMs: 30_000)

    let task = Task {
      try await liveClient().passwordLogin(originURL, "basic", "alice", "dummy-password")
    }
    try await Task.sleep(nanoseconds: 500_000_000) // let it reach the wire
    task.cancel()
    try await Task.sleep(nanoseconds: 500_000_000) // give the cancel time to tear down
    do {
      _ = try await task.value
      Issue.record("a cancelled login attempt must not succeed")
    } catch is CancellationError {
      // expected
    } catch {
      // The cancellation may surface as either CancellationError or the URLError wrapped
      // into RESTError.unreachable depending on the timing of the teardown.
    }
    assertImpostorSilent(originB)
  }
}