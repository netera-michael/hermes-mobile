import Foundation

/// Local correlation only. Legacy gateways have no durable deduplication/receipt lookup.
public struct SubmitOperation: Equatable, Sendable {
  public enum Outcome: Equatable, Sendable { case submitting, accepted, rejected, unknown, cancelled }
  public var id: UUID
  public var sessionID: String
  public var outcome: Outcome = .submitting
  public var observedServerTurn = false
  /// A locally cancelled submission (Stop during preparation). Not evidence about the
  /// server: only an explicit server refusal is `rejected`; cancellation cannot undo
  /// transmission, and a `prompt.submit` that never started never happened.
  public static func fromCancel() -> Outcome { .cancelled }

  public static func failureOutcome(_ error: any Error) -> Outcome {
    // Only an explicit server refusal is definitive; cancellation cannot undo transmission.
    if let gatewayError = error as? GatewayError, case .server = gatewayError { return .rejected }
    return .unknown
  }
}

public struct AttachmentReceipt: Equatable, Sendable {
  public var sessionID: String
  public var ref: String?
  /// The submit operation that currently owns this staged item (staged it, or adopted it
  /// for a retry of the same batch). Lets a hydrate's staging ambiguity be attributed to
  /// one operation instead of a slot-global latch. `nil` = unattributable (legacy).
  public var operationID: UUID? = nil

  public init(sessionID: String, ref: String?, operationID: UUID? = nil) {
    self.sessionID = sessionID
    self.ref = ref
    self.operationID = operationID
  }
}

extension ComposerAttachment {
  public static let maxFileBytes = 10 * 1024 * 1024
  public static let frameLimit = 16 * 1024 * 1024
  public static func canLoadFile(byteCount: Int) -> Bool {
    byteCount >= 0 && byteCount <= maxFileBytes
  }

  var uploadMethod: String {
    switch kind {
    case .image: return "image.attach_bytes"
    case .pdf: return "pdf.attach"
    case .file: return "file.attach"
    }
  }

  func uploadParams(sessionID: String) -> JSONValue {
    switch kind {
    case .image:
      return .object(["session_id": .string(sessionID), "content_base64": .string(base64), "filename": .string(filename)])
    case .pdf:
      return .object(["session_id": .string(sessionID), "content_base64": .string(base64), "name": .string(filename)])
    case .file:
      return .object(["session_id": .string(sessionID), "data_url": .string(dataURL), "name": .string(filename)])
    }
  }

  func preflight(sessionID: String, frameLimit: Int = Self.frameLimit) throws {
    guard Self.canLoadFile(byteCount: data.count) else {
      throw GatewayError.server("Attachment exceeds the 10 MiB upload limit")
    }
    let envelope = JSONValue.object([
      "jsonrpc": .string("2.0"), "id": .number(Double(Int.max)),
      "method": .string(uploadMethod), "params": uploadParams(sessionID: sessionID),
    ])
    guard try JSONRPCRequest.wireEncoder.encode(envelope).count <= frameLimit else {
      throw GatewayError.server("Encoded attachment exceeds the WebSocket frame limit")
    }
  }
}
