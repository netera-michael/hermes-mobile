import ComposableArchitecture
import Foundation
import Network
import Testing

@testable import HermesKit

// Native Foundation transport is intentional: an atomic URLProtocol reply cannot prove
// that Set-Cookie was persisted while a response body was still withheld.
private enum RotationFixtureError: Error { case timedOut(String), network(String) }

private func rotationWait(
  _ description: String,
  until predicate: @escaping @Sendable () -> Bool
) async throws {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: .seconds(5))
  while !predicate() {
    guard clock.now < deadline else { throw RotationFixtureError.timedOut(description) }
    try await Task.sleep(for: .milliseconds(10))
  }
}

/// A sticky one-shot gate: release-before-install and install-before-release both work.
/// Actions execute outside the lock (and may install another gate without deadlocking).
private final class RotationGate: @unchecked Sendable {
  private struct State {
    var released = false
    var action: (@Sendable () -> Void)?
  }
  private let state = LockIsolated(State())
  func install(_ action: @escaping @Sendable () -> Void) {
    let run = state.withValue { state in
      if state.released { return true }
      precondition(state.action == nil)
      state.action = action
      return false
    }
    if run { action() }
  }
  func release() {
    let action = state.withValue { state -> (@Sendable () -> Void)? in
      state.released = true
      defer { state.action = nil }
      return state.action
    }
    action?()
  }
}

private final class CookieRotationServer: @unchecked Sendable {
  struct Request: Sendable {
    var method: String
    var path: String
    var cookie: String
  }
  private struct State {
    var port: UInt16?
    var failure: String?
    var stopped = false
    var connections: [NWConnection] = []
    var requests: [Request] = []
    var headersSent = false
    var bodyReleased = false
  }
  private let state = LockIsolated(State())
  private let queue = DispatchQueue(label: "HermesKit.cookie-rotation-loopback")
  private let listener: NWListener
  private let truncate: Bool
  private let headers = RotationGate()
  private let body = RotationGate()

  init(holdHeaders: Bool = false, truncate: Bool = false) throws {
    self.truncate = truncate
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
    listener = try NWListener(using: parameters)
    if !holdHeaders { headers.release() }
  }

  var requests: [Request] { state.value.requests }
  var headersSent: Bool { state.value.headersSent }
  var bodyReleased: Bool { state.value.bodyReleased }

  func start() async throws -> URL {
    listener.stateUpdateHandler = { [weak self] update in
      guard let self else { return }
      switch update {
      case .ready: self.state.withValue { $0.port = self.listener.port?.rawValue }
      case let .failed(error): self.state.withValue { $0.failure = String(describing: error) }
      default: break
      }
    }
    listener.newConnectionHandler = { [weak self] connection in
      guard let self else { connection.cancel(); return }
      let accepted = self.state.withValue { state in
        guard !state.stopped else { return false }
        state.connections.append(connection)
        return true
      }
      guard accepted else { connection.cancel(); return }
      connection.start(queue: self.queue)
      self.read(connection, accumulated: Data())
    }
    listener.start(queue: queue)
    do {
      try await rotationWait("listener ready") { self.state.value.port != nil || self.state.value.failure != nil }
      if let failure = state.value.failure { throw RotationFixtureError.network(failure) }
      let port = try #require(state.value.port)
      return URL(string: "http://127.0.0.1:\(port)")!
    } catch {
      stop()
      throw error
    }
  }

  func releaseHeaders() { headers.release() }
  func releaseBody() {
    state.withValue { $0.bodyReleased = true }
    body.release()
  }
  func stop() {
    let connections = state.withValue { state in
      state.stopped = true
      defer { state.connections = [] }
      return state.connections
    }
    listener.cancel()
    connections.forEach { $0.cancel() }
    // Drop parked closures and their connection references, including on assertion failure.
    headers.release()
    body.release()
  }

  private func read(_ connection: NWConnection, accumulated: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
      guard let self else { return }
      var buffer = accumulated
      if let data { buffer.append(data) }
      if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
        let lines = String(decoding: buffer[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let length = lines.first { $0.lowercased().hasPrefix("content-length:") }
          .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
        // Drain POST/PATCH bodies before answering; avoid closing a socket with unread input.
        if buffer.count >= end.upperBound + length {
          let firstLine = (lines.first ?? "").split(separator: " ")
          guard firstLine.count >= 2 else { connection.cancel(); return }
          let request = Request(method: String(firstLine[0]),
            path: String(firstLine[1]).components(separatedBy: "?")[0],
            cookie: lines.first { $0.lowercased().hasPrefix("cookie:") }
              .map { $0.dropFirst("cookie:".count).trimmingCharacters(in: .whitespaces) } ?? "")
          let first = self.state.withValue { state in
            state.requests.append(request)
            return state.requests.count == 1
          }
          self.respond(connection, request: request, first: first)
          return
        }
      }
      guard error == nil, !complete else { connection.cancel(); return }
      self.read(connection, accumulated: buffer)
    }
  }

  private func respond(_ connection: NWConnection, request: Request, first: Bool) {
    let json: String
    switch request.path {
    case "/api/sessions": json = #"{"sessions":[],"total":0}"#
    case "/api/audio/transcribe": json = #"{"ok":true,"transcript":"hello"}"#
    case "/api/auth/ws-ticket": json = #"{"ticket":"loopback-ticket"}"#
    default: json = #"{"ok":true}"#
    }
    let payload = Data(json.utf8)
    let sendHead: @Sendable () -> Void = { [weak self] in
      guard let self, !self.state.value.stopped else { return }
      let rotation = first ? "Set-Cookie: session=rotated; Path=/\r\n" : ""
      let framing = first && self.truncate ? "Transfer-Encoding: chunked" : "Content-Length: \(payload.count)"
      let head = "HTTP/1.1 200 OK\r\n\(rotation)Content-Type: application/json\r\n\(framing)\r\nConnection: close\r\n\r\n"
      // Foundation may defer header delivery until its first body byte. Send a
      // prefix, but withhold the rest so body completion is still impossible.
      let prefix = first ? (self.truncate ? Data("100\r\n{".utf8) : Data(payload.prefix(1))) : Data()
      connection.send(content: Data(head.utf8) + prefix, completion: .contentProcessed { [weak self] error in
        guard let self, error == nil else { return }
        if first { self.state.withValue { $0.headersSent = true } }
        let finish: @Sendable () -> Void = { [weak self] in
          guard let self, !self.state.value.stopped else { return }
          // Send fewer bytes than Content-Length and FIN only after the test's gate.
          if first && self.truncate {
            connection.forceCancel()
            return
          }
          let data = first ? Data(payload.dropFirst()) : payload
          connection.send(content: data, contentContext: .finalMessage, isComplete: true,
            completion: .contentProcessed { _ in connection.cancel() })
        }
        if first { self.body.install(finish) } else { finish() }
      })
    }
    if first { headers.install(sendHead) } else { sendHead() }
  }
}

extension RESTTransportSuite {
  @Suite(.timeLimit(.minutes(2)))
  struct CookieRotationPersistenceTests {
    enum Entry: String, CaseIterable, Sendable {
      case direct, get, postJSON, send, ticket

      var method: String {
        switch self {
        case .direct, .get: return "GET"
        case .postJSON, .ticket: return "POST"
        case .send: return "PATCH"
        }
      }
      var path: String {
        switch self {
        case .direct: return "/direct"
        case .get: return "/api/sessions"
        case .postJSON: return "/api/audio/transcribe"
        case .send: return "/api/sessions/example"
        case .ticket: return "/api/auth/ws-ticket"
        }
      }
      func perform(_ connection: ServerConnection, session: URLSession) async throws {
        let client = HermesRESTClient.live(session: session)
        switch self {
        case .direct:
          let store = CookieSessionStore.shared
          let (data, response) = try await store.data(
            for: URLRequest(url: connection.baseURL.appendingPathComponent("direct")),
            lease: store.lease(for: connection), source: session)
          #expect(data == Data(#"{"ok":true}"#.utf8))
          #expect((response as? HTTPURLResponse)?.statusCode == 200)
        case .get:
          let result = try await client.sessions(connection, 1, 0, .recent)
          #expect(result.isEmpty)
        case .postJSON:
          #expect(try await client.transcribe(connection, "data:audio/wav;base64,AA==", "audio/wav") == "hello")
        case .send:
          try await client.archive(connection, "example", true, nil)
        case .ticket:
          guard case let .cookie(cookie) = connection.auth else { preconditionFailure() }
          #expect(try await wsTicket(baseURL: connection.baseURL, cookieSession: cookie, session: session) == "loopback-ticket")
        }
      }
    }
    enum Ending: String, CaseIterable, Sendable { case success, cancellation, truncation }

    private func cookie(_ value: String) -> CookieSession {
      .init(cookies: [.init(name: "session", value: value, domain: "127.0.0.1", path: "/")],
        username: value, provider: "basic")
    }
    private func realSession() -> URLSession {
      let configuration = URLSessionConfiguration.ephemeral
      configuration.protocolClasses = []
      configuration.httpCookieStorage = nil
      return URLSession(configuration: configuration)
    }
    // Persistence journals below are written only by the store's actual callback.

    // Each real entry point must persist BEFORE the body is released, then retain the
    // rotation through success, caller cancellation, and actual truncated-wire failure.
    @Test(arguments: Entry.allCases, Ending.allCases)
    func persistsBeforeBody(entry: Entry, ending: Ending) async throws {
      let server = try CookieRotationServer(truncate: ending == .truncation)
      let base = try await server.start()
      defer { server.stop() }
      let session = realSession()
      let store = CookieSessionStore.shared
      defer { store.clear(); session.invalidateAndCancel() }
      let original = cookie("old")
      let connection = ServerConnection(baseURL: base, auth: .cookie(original))
      let journal = LockIsolated<[String]>([])
      store.activate(original, baseURL: base, persist: { value in
        let cookie = value.cookies.first { $0.name == "session" }?.value ?? "missing"
        journal.withValue { $0.append(cookie) }
      })
      let finished = LockIsolated(false)
      let pending = Task {
        defer { finished.setValue(true) }
        try await entry.perform(connection, session: session)
      }
      defer { pending.cancel() }
      try await rotationWait("first request and response headers sent") { server.headersSent }
      #expect(server.requests.map(\.cookie) == ["session=old"])
      #expect(server.requests.first?.method == entry.method)
      #expect(server.requests.first?.path == entry.path)
      // Send completion is NOT receipt. Poll the actual persistence callback until its
      // bounded deadline; leave the body gate shut throughout this assertion.
      try await rotationWait("rotation persisted BEFORE body release (\(entry.rawValue), \(ending.rawValue))") {
        journal.value == ["rotated"]
      }
      #expect(!server.bodyReleased)
      #expect(!finished.value)
      if ending == .cancellation { pending.cancel() } else { server.releaseBody() }
      try await rotationWait("request settled after \(ending.rawValue)") { finished.value }
      switch await pending.result {
      case .success:
        #expect(ending == .success, "cancelled/truncated transport must not succeed")
      case let .failure(error):
        switch ending {
        case .success: Issue.record("valid complete response failed: \(error)")
        case .cancellation:
          // URLSession may throw URLError.cancelled rather than CancellationError;
          // REST/ticket wrappers intentionally map raw transport errors to their domain.
          if entry == .direct {
            #expect(error is CancellationError || (error as? URLError)?.code == .cancelled)
          } else if entry == .ticket {
            #expect(error is CancellationError || (error as? GatewayError) == .ticketUnavailable)
          } else {
            #expect(error is CancellationError || (error as? RESTError) == .unreachable)
          }
        case .truncation:
          #expect(!(error is CancellationError))
          if entry == .direct {
            let urlError = try #require(error as? URLError)
            #expect(urlError.code != .cancelled && urlError.code != .timedOut)
          } else if entry == .ticket {
            #expect((error as? GatewayError) == .ticketUnavailable)
          } else {
            #expect((error as? RESTError) == .unreachable)
          }
        }
      }
      #expect(journal.value == ["rotated"])
      // Use the ORIGINAL connection handle, not a manufactured rotated snapshot.
      // Both downstream consumers must consult the current jar after settlement.
      try await Entry.get.perform(connection, session: session)
      try await Entry.ticket.perform(connection, session: session)
      #expect(server.requests.map(\.cookie) == ["session=old", "session=rotated", "session=rotated"])
      #expect(journal.value == ["rotated"], "non-rotating follow-ups must not persist again")
    }

    @Test(arguments: Entry.allCases, [false, true])
    func replacementRejectsOldResponse(entry: Entry, holdHeaders: Bool) async throws {
      let server = try CookieRotationServer(holdHeaders: holdHeaders)
      let base = try await server.start()
      defer { server.stop() }
      let session = realSession()
      let store = CookieSessionStore.shared
      defer { store.clear(); session.invalidateAndCancel() }
      let original = cookie("old")
      let oldConnection = ServerConnection(baseURL: base, auth: .cookie(original))
      let oldJournal = LockIsolated<[String]>([])
      let newJournal = LockIsolated<[String]>([])
      store.activate(original, baseURL: base, persist: { value in
        let cookie = value.cookies.first { $0.name == "session" }?.value ?? "missing"
        oldJournal.withValue { $0.append(cookie) }
      })
      let finished = LockIsolated(false)
      let pending = Task {
        defer { finished.setValue(true) }
        try await entry.perform(oldConnection, session: session)
      }
      defer { pending.cancel() }
      try await rotationWait("old request received") { server.requests.count == 1 }
      if holdHeaders {
        #expect(!server.headersSent)
        #expect(oldJournal.value.isEmpty)
      } else {
        try await rotationWait("old headers persisted while body held") { oldJournal.value == ["rotated"] }
      }
      #expect(!finished.value)
      #expect(!server.bodyReleased)
      let replacement = cookie("new")
      store.activate(replacement, baseURL: base, persist: { value in
        let cookie = value.cookies.first { $0.name == "session" }?.value ?? "missing"
        newJournal.withValue { $0.append(cookie) }
      })
      server.releaseHeaders()
      server.releaseBody()
      try await rotationWait("retired request settled") { finished.value }
      await #expect(throws: CancellationError.self) { try await pending.value }
      #expect(oldJournal.value == (holdHeaders ? [] : ["rotated"]))
      #expect(newJournal.value.isEmpty)
      #expect(throws: CancellationError.self) { _ = try store.lease(for: oldConnection) }
      let newConnection = ServerConnection(baseURL: base, auth: .cookie(replacement))
      try await Entry.get.perform(newConnection, session: session)
      try await Entry.ticket.perform(newConnection, session: session)
      #expect(server.requests.map(\.cookie) == ["session=old", "session=new", "session=new"])
      #expect(oldJournal.value == (holdHeaders ? [] : ["rotated"]))
      #expect(newJournal.value.isEmpty)
    }
  }
}
