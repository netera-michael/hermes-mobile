import Testing
@testable import HermesKit
import Foundation

@Suite struct GatewayEventDecodingTests {
  private func frame(_ json: String) throws -> InboundFrame {
    try InboundFrame(data: Data(json.utf8))
  }

  // MARK: Events

  @Test func readyEventDecodesWithoutPayload() throws {
    let f = try frame(#"{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready"}}"#)
    guard case let .event(gf) = f else { Issue.record("expected event"); return }
    #expect(gf.event == .ready)
    #expect(gf.sessionID == nil)
    #expect(gf.seq == nil)
  }

  @Test func sessionInfoWithMessages() throws {
    let f = try frame(#"{"jsonrpc":"2.0","method":"event","params":{"type":"session.info","session_id":"8680ce37","payload":{"is_active":true,"messages":[{"role":"user","content":"hi"}]}}}"#)
    guard case let .event(gf) = f, case let .sessionInfo(info) = gf.event else {
      Issue.record("expected sessionInfo event, got \(f)")
      return
    }
    #expect(gf.sessionID == "8680ce37")
    // SessionInfo decoded successfully; it carries model, running, etc. — not messages.
  }

  @Test func messageStartAndDelta() throws {
    let f = try frame(#"{"jsonrpc":"2.0","method":"event","params":{"type":"message.start","session_id":"8680ce37"}}"#)
    guard case let .event(gf) = f else { Issue.record("expected event"); return }
    #expect(gf.event == .messageStart)
    #expect(gf.sessionID == "8680ce37")

    let d = try frame(#"{"jsonrpc":"2.0","method":"event","params":{"type":"message.delta","session_id":"8680ce37","payload":{"text":"pong"}}}"#)
    guard case let .event(gf2) = d else { Issue.record("expected event"); return }
    #expect(gf2.event == .messageDelta(text: "pong"))
    #expect(gf2.sessionID == "8680ce37")
  }

  @Test func messageComplete() throws {
    let f = try frame(#"{"jsonrpc":"2.0","method":"event","params":{"type":"message.complete","session_id":"8680ce37","payload":{"text":"final"}}}"#)
    guard case let .event(gf) = f else { Issue.record("expected event"); return }
    #expect(gf.event == .messageComplete(text: "final", usage: nil))
  }

  @Test func thinkingDelta() throws {
    let f = try frame(#"{"jsonrpc":"2.0","method":"event","params":{"type":"thinking.delta","session_id":"8680ce37","payload":{"text":"(◔_◔) synthesizing..."}}}"#)
    guard case let .event(gf) = f else { Issue.record("expected event"); return }
    #expect(gf.event == .thinkingDelta(text: "(◔_◔) synthesizing..."))
    #expect(gf.sessionID == "8680ce37")
  }

  @Test func reasoningDelta() throws {
    let f = try frame(#"{"jsonrpc":"2.0","method":"event","params":{"type":"reasoning.delta","session_id":"8680ce37","payload":{"text":"weighing options"}}}"#)
    guard case let .event(gf) = f else { Issue.record("expected event"); return }
    #expect(gf.event == .thinkingDelta(text: "weighing options"))
  }

  @Test func reasoningAvailable() throws {
    let f = try frame(#"{"jsonrpc":"2.0","method":"event","params":{"type":"reasoning.available","session_id":"8680ce37","payload":{"text":"pong"}}}"#)
    guard case let .event(gf) = f else { Issue.record("expected event"); return }
    #expect(gf.event == .reasoningAvailable(text: "pong"))
  }

  @Test func statusUpdate() throws {
    let f = try frame(#"{"jsonrpc":"2.0","method":"event","params":{"type":"status.update","session_id":"8680ce37","payload":{"kind":"lifecycle","text":"raised auto-compaction"}}}"#)
    guard case let .event(gf) = f else { Issue.record("expected event"); return }
    #expect(gf.event == .statusUpdate(kind: "lifecycle", text: "raised auto-compaction"))
  }

  @Test func toolStartAndComplete() throws {
    let start = try frame(#"{"jsonrpc":"2.0","method":"event","params":{"type":"tool.start","session_id":"s","payload":{"name":"terminal","tool_id":"t1","args_text":"{\"command\":\"ls\"}"}}}"#)
    guard case let .event(gfs) = start else { Issue.record("expected event"); return }
    #expect(gfs.event == .toolStart(toolID: "t1", name: "terminal", title: nil, argsText: #"{"command":"ls"}"#))
    let done = try frame(#"{"jsonrpc":"2.0","method":"event","params":{"type":"tool.complete","session_id":"s","payload":{"name":"terminal","tool_id":"t1","args":{"path":"/x"},"result_text":"ok","duration_s":1.5}}}"#)
    guard case let .event(gfd) = done else { Issue.record("expected event"); return }
    let expectedDoneArgs: JSONValue = .object(["path": .string("/x")])
    #expect(gfd.event == .toolComplete(
      toolID: "t1", name: "terminal", title: nil,
      args: expectedDoneArgs, resultText: "ok", inlineDiff: nil, durationS: 1.5))
  }

  // MARK: Interactive requests

  @Test func approvalRequestWithRequestID() throws {
    let f = try frame(#"{"jsonrpc":"2.0","method":"event","params":{"type":"approval.request","session_id":"s","payload":{"request_id":"r1","command":"rm -rf /","tool_name":"terminal"}}}"#)
    guard case let .event(gf) = f, case let .approvalRequest(req) = gf.event else {
      Issue.record("expected approvalRequest, got \(f)")
      return
    }
    #expect(req.command == "rm -rf /")
  }

  // Regression (#approval-hang): a payload without `request_id` must still decode to
  // `.approvalRequest` — previously the required `request_id` made it fall through to
  // `.unknown`, so the approval card never appeared and the turn hung on "Thinking".
  @Test func approvalRequestWithoutRequestIDStillDecodes() throws {
    let f = try frame(#"{"jsonrpc":"2.0","method":"event","params":{"type":"approval.request","session_id":"s","payload":{"command":"rm foo"}}}"#)
    guard case let .event(gf) = f, case .approvalRequest = gf.event else {
      Issue.record("expected .approvalRequest, got \(f)")
      return
    }
  }

  @Test func clarifyRequestWithChoices() throws {
    let f = try frame(#"{"jsonrpc":"2.0","method":"event","params":{"type":"clarify.request","session_id":"s","payload":{"request_id":"r2","question":"Which file?","choices":["a.txt","b.txt"]}}}"#)
    guard case let .event(gf) = f else { Issue.record("expected event"); return }
    #expect(gf.event == .clarifyRequest(ClarifyRequest(requestID: "r2", question: "Which file?", choices: ["a.txt", "b.txt"])))
  }

  @Test func clarifyRequestWithoutChoices() throws {
    let f = try frame(#"{"jsonrpc":"2.0","method":"event","params":{"type":"clarify.request","session_id":"s","payload":{"request_id":"r3","question":"Name?"}}}"#)
    guard case let .event(gf) = f else { Issue.record("expected event"); return }
    #expect(gf.event == .clarifyRequest(ClarifyRequest(requestID: "r3", question: "Name?", choices: [])))
  }

  @Test func secretRequest() throws {
    let f = try frame(#"{"jsonrpc":"2.0","method":"event","params":{"type":"secret.request","session_id":"s","payload":{"request_id":"r4","prompt":"API key?"}}}"#)
    guard case let .event(gf) = f else { Issue.record("expected event"); return }
    #expect(gf.event == .secretRequest(SecretPrompt(requestID: "r4", prompt: "API key?")))
  }

  // MARK: Review summary

  @Test func reviewSummaryWithPayloadText() throws {
    let f = try frame(#"{"jsonrpc":"2.0","method":"event","params":{"type":"review.summary","session_id":"s","payload":{"text":"looks good"}}}"#)
    guard case let .event(gf) = f else { Issue.record("expected event"); return }
    #expect(gf.event == .reviewSummary(text: "looks good"))
  }

  @Test func reviewSummaryWithoutPayload() throws {
    let f = try frame(#"{"jsonrpc":"2.0","method":"event","params":{"type":"review.summary","session_id":"s"}}"#)
    guard case let .event(gf) = f else { Issue.record("expected event"); return }
    #expect(gf.event == .reviewSummary(text: ""))
  }

  @Test func reviewSummaryWithNonStringTextDecodesToEmptyString() throws {
    // Lenient decode: a wrong-typed `text` (`stringValue` is nil for non-strings) falls
    // back to "" — never throws, never stringifies garbage.
    let f = try frame(#"{"jsonrpc":"2.0","method":"event","params":{"type":"review.summary","session_id":"s","payload":{"text":42}}}"#)
    guard case let .event(gf) = f else { Issue.record("expected event"); return }
    #expect(gf.event == .reviewSummary(text: ""))
  }

  // MARK: Forward-compatibility

  @Test func unknownEventTypeDecodesToUnknownAndNeverThrows() throws {
    let f = try frame(#"{"jsonrpc":"2.0","method":"event","params":{"type":"tool.progress","session_id":"s","payload":{"pct":42}}}"#)
    guard case let .event(gf) = f, case let .unknown(type, raw) = gf.event else {
      Issue.record("expected unknown event, got \(f)"); return
    }
    #expect(gf.sessionID == "s")
    #expect(type == "tool.progress")
    #expect(raw == .object(["pct": .number(42)]))
  }

  @Test func unknownEventWithoutPayloadStillDecodes() throws {
    let f = try frame(#"{"jsonrpc":"2.0","method":"event","params":{"type":"made.up.event"}}"#)
    guard case let .event(gf) = f else { Issue.record("expected event"); return }
    #expect(gf.event == .unknown(type: "made.up.event", raw: .object([:])))
    #expect(gf.sessionID == nil)
  }

  // MARK: GatewayFrame seq & replayEpoch

  @Test func eventWithSeqParsesSequenceNumber() throws {
    let f = try frame(#"{"jsonrpc":"2.0","method":"event","params":{"type":"message.delta","session_id":"s","seq":7,"payload":{"text":"hi"}}}"#)
    guard case let .event(gf) = f else { Issue.record("expected event"); return }
    #expect(gf.seq == 7)
    #expect(gf.sessionID == "s")
    #expect(gf.event == .messageDelta(text: "hi"))
  }

  @Test func eventWithNegativeSeqTreatsAsNil() throws {
    let f = try frame(#"{"jsonrpc":"2.0","method":"event","params":{"type":"message.start","session_id":"s","seq":-1}}"#)
    guard case let .event(gf) = f else { Issue.record("expected event"); return }
    #expect(gf.seq == nil)
  }

  @Test func readyEventExtractsReplayEpoch() throws {
    let f = try frame(#"{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","payload":{"replay_epoch":"abc-123"}}}"#)
    guard case let .event(gf) = f else { Issue.record("expected event"); return }
    #expect(gf.event == .ready)
    #expect(gf.replayEpoch == "abc-123")
    #expect(gf.seq == nil)
  }

  // MARK: Responses

  @Test func sessionCreateResultIsResponseAndDecodesHandle() throws {
    let f = try frame(#"{"jsonrpc":"2.0","id":1,"result":{"session_id":"8680ce37","stored_session_id":"20260610_120231_afcca6","message_count":0,"messages":[]}}"#)
    guard case let .response(id, result) = f else {
      Issue.record("expected response, got \(f)"); return
    }
    #expect(id == 1)
    let handle = result.decoded(SessionHandle.self)
    #expect(handle?.sessionID == "8680ce37")
    #expect(handle?.storedSessionID == "20260610_120231_afcca6")
    #expect(handle?.messageCount == 0)
  }

  @Test func promptSubmitResult() throws {
    let f = try frame(#"{"jsonrpc":"2.0","id":2,"result":{"status":"streaming"}}"#)
    #expect(f == .response(id: 2, result: .object(["status": .string("streaming")])))
  }

  @Test func errorResponse() throws {
    let f = try frame(#"{"jsonrpc":"2.0","id":3,"error":{"message":"bad session"}}"#)
    #expect(f == .failure(id: 3, message: "bad session"))
  }

  @Test func nonEventNotificationIsIgnored() throws {
    let f = try frame(#"{"jsonrpc":"2.0","method":"something.else","params":{}}"#)
    #expect(f == .ignored)
  }

  // MARK: ReplayBatch

  @Test func replayBatchDecodesFromResult() throws {
    let json: JSONValue = .object([
      "events": .array([
        .object(["type": .string("message.start"), "session_id": .string("s"), "seq": .number(1)]),
        .object(["type": .string("message.delta"), "session_id": .string("s"), "seq": .number(2), "payload": .object(["text": .string("hi")])])
      ]),
      "latest_seq": .number(5),
      "truncated": .bool(false),
      "epoch": .string("ep-1")
    ])
    let batch = ReplayBatch(result: json)
    #expect(batch != nil)
    #expect(batch!.events.count == 2)
    #expect(batch!.events[0].seq == 1)
    #expect(batch!.events[0].event == .messageStart)
    #expect(batch!.events[1].seq == 2)
    #expect(batch!.events[1].event == .messageDelta(text: "hi"))
    #expect(batch!.latestSeq == 5)
    #expect(batch!.truncated == false)
    #expect(batch!.epoch == "ep-1")
  }

  @Test func replayBatchTruncatedDefaultsToFalse() throws {
    let json: JSONValue = .object(["events": .array([])])
    let batch = ReplayBatch(result: json)
    #expect(batch != nil)
    #expect(batch!.truncated == false)
    #expect(batch!.events.isEmpty)
  }

  @Test func replayBatchDropsUndecodableElements() throws {
    let json: JSONValue = .object([
      "events": .array([
        .object(["type": .string("message.start"), "seq": .number(1)]),
        .object(["bad": .string("no type field")]),
        .object(["type": .string("message.delta"), "seq": .number(3), "payload": .object(["text": .string("x")])])
      ]),
      "truncated": .bool(true)
    ])
    let batch = ReplayBatch(result: json)!
    #expect(batch.events.count == 2)
    #expect(batch.events[0].seq == 1)
    #expect(batch.events[1].seq == 3)
    #expect(batch.truncated == true)
  }
}
