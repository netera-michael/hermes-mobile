import Foundation

/// One inbound event as delivered by the socket or replayed by `session.events.since`.
///
/// The envelope carries the event's sequence number (`seq`) and session identity alongside
/// the decoded `GatewayEvent`. Live frames from the socket carry all fields; replayed frames
/// from `events.since` share the same shape. Session-less globals (`skin.changed`,
/// `sessions.changed`) have `sessionID == nil` and `seq == nil`.
///
/// `GatewayEvent` is unchanged — `.ready` stays payload-less. The replay epoch rides on the
/// frame (populated only from `gateway.ready` payloads).
public struct GatewayFrame: Equatable, Sendable {
  public var event: GatewayEvent
  public var sessionID: String?
  /// Server per-session monotonic sequence (v2026.8.27+); nil on older agents and on
  /// session-less global events. Only non-negative integers are accepted; everything else
  /// is treated as absent.
  public var seq: Int?
  /// `gateway.ready` only: the server process's replay epoch (a uuid that changes on
  /// gateway restart, resetting all sequence counters).
  public var replayEpoch: String?

  public init(_ event: GatewayEvent, sessionID: String? = nil, seq: Int? = nil, replayEpoch: String? = nil) {
    self.event = event
    self.sessionID = sessionID
    self.seq = seq.flatMap { $0 >= 0 ? $0 : nil }
    self.replayEpoch = replayEpoch
  }

  /// Decode a bare event object `{type, session_id, seq?, payload?}` — the shape shared by a
  /// live frame's `params` and each `events.since` element. Returns nil when `type` is missing
  /// or empty.
  public init?(eventObject obj: JSONValue) {
    guard let type = obj["type"]?.stringValue, !type.isEmpty else { return nil }
    let sessionID = obj["session_id"]?.stringValue
    let payload = obj["payload"]
    let seq = obj["seq"]?.intValue.flatMap { $0 >= 0 ? $0 : nil }
    // The replay_epoch is extracted from the gateway.ready payload, not from the event object
    // itself — it lives inside `payload`, not at the params level.
    let epoch: String?
    if type == "gateway.ready" {
      epoch = payload?["replay_epoch"]?.stringValue
    } else {
      epoch = nil
    }
    self.init(GatewayEvent(type: type, payload: payload), sessionID: sessionID, seq: seq, replayEpoch: epoch)
  }
}

/// The server's response to `session.events.since {session_id, last_seen}`.
///
/// Each element in `events` is decoded via `GatewayFrame(eventObject:)` — elements that
/// fail decoding (missing `type`) are silently dropped. `truncated` defaults to `false`
/// when absent.
public struct ReplayBatch: Equatable, Sendable {
  /// The replayed events, in server order (oldest first). Undecodable elements are dropped.
  public var events: [GatewayFrame]
  /// The ring's latest sequence number for this session at the time of the read.
  public var latestSeq: Int?
  /// `true` when the gap fell off the ring (i.e. `last_seen + 1 < oldest retained seq`).
  public var truncated: Bool
  /// The server process's replay epoch at the time of the read.
  public var epoch: String?

  public init(events: [GatewayFrame] = [], latestSeq: Int? = nil, truncated: Bool = false, epoch: String? = nil) {
    self.events = events
    self.latestSeq = latestSeq
    self.truncated = truncated
    self.epoch = epoch
  }

  /// Decode from the JSON-RPC result of `session.events.since`.
  public init?(result: JSONValue) {
    guard case .object(let obj) = result else { return nil }
    let rawEvents = obj["events"]?.arrayValue ?? []
    self.events = rawEvents.compactMap { GatewayFrame(eventObject: $0) }
    self.latestSeq = obj["latest_seq"]?.intValue
    self.truncated = obj["truncated"]?.boolValue ?? false
    self.epoch = obj["epoch"]?.stringValue
  }
}
