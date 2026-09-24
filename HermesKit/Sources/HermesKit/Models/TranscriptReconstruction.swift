import Foundation

/// Pure, server-authoritative re-hydration of a chat transcript from the `session.resume`
/// `messages` array. The gateway returns the server's **cooked** history shape (built by
/// `_history_to_messages`), NOT the raw DB rows — each entry is one of:
///   - a text row: `{role: "user" | "assistant" | "system", text, ...}` (an assistant row
///     may also carry `reasoning` / `reasoning_content` / `reasoning_details`);
///   - a tool row: `{role: "tool", name, context}` — the server has already matched the
///     tool call to its result and flattened it into a single row with a display `name` and
///     a short args/preview `context`. There are **no** `tool_calls` arrays or
///     `tool_call_id` back-matching in this payload.
///
/// Mirrors the desktop TUI's `toTranscriptMessages` (`ui-tui/src/domain/messages.ts`).
/// For each message, in order:
///   1. an assistant **reasoning** row (from `reasoningText`), emitted collapsed/complete
///      as a `.thinking` row with unknown elapsed (`0` → the view shows a bare "Thought");
///   2. an assistant / user **text** row from `displayText` (skipped when empty);
///   3. a completed **tool** row for each `role: "tool"` entry (title = `name`, the
///      `context` preview surfaced in the detail sheet).
///
private extension SessionMessage {
  /// One-line status text for an `async_delegation_complete` delivery: prefer the gateway's
  /// summary counts (`completed_count` / `failed_count` / `task_count` in `display_metadata`),
  /// falling back to the header line of the delivery text itself.
  static func delegationStatusText(_ message: SessionMessage) -> String {
    func count(_ key: String) -> Int? {
      guard case let .object(dict)? = message.displayMetadata,
            case let .number(n)? = dict[key] else { return nil }
      return Int(n)
    }
    if let tasks = count("task_count") {
      let completed = count("completed_count") ?? tasks
      let failed = count("failed_count") ?? 0
      if failed > 0 {
        return "Background delegation finished — \(completed)/\(tasks) succeeded, \(failed) failed."
      }
      return "Background delegation finished — \(completed)/\(tasks) task\(tasks == 1 ? "" : "s") succeeded."
    }
    let body = message.displayText ?? ""
    return body.split(separator: "\n").first.map(String.init) ?? "Background delegation finished."
  }
}

/// Identity is **deterministic and content-derived**: each row's `id` is a stable UUID
/// hashed from its `(sequenceIndex, role, kindDiscriminator)` — NOT a fresh random UUID per
/// call. So the same history in always yields byte-identical ids out (lets a diffing engine
/// preserve scroll / animate inserts across a hydrate), identical consecutive rows stay
/// distinct (sequence index), and a message and its reasoning row get distinct ids (distinct
/// indices + discriminators). Mutable streaming text is excluded from the id so a live
/// `message.delta` append later reconciles to the same id on the next hydrate.
public func reconstructTranscript(_ messages: [SessionMessage]) -> [ChatRow] {
  var rows: [ChatRow] = []

  // Append a row, assigning its id deterministically from its ordinal position in the output
  // transcript. Building the `Kind` first lets us read the role/discriminator the id derives
  // from before the row exists.
  func append(_ kind: ChatRow.Kind) {
    // Single source for role/discriminator: read them off the `Kind` so this never drifts from
    // `ChatRow.kindDiscriminator` / `ChatRow.rowRole`.
    let id = ChatRow.deterministicID(
      sequenceIndex: rows.count, role: kind.role, kindDiscriminator: kind.discriminator
    )
    rows.append(ChatRow(id: id, kind: kind))
  }

  for message in messages {
    switch message.role {
    case "tool":
      // The server already resolved the call → result into one cooked row.
      let toolName = message.toolDisplayName ?? "tool"
      let preview = message.context?.nonEmpty
      let detail = preview.map { ToolDetail(argsText: $0) }
      append(.tool(
        name: toolName, title: toolName, state: .complete,
        detail: detail, durationS: nil
      ))

    case "assistant":
      // 1. Reasoning row (collapsed + complete). Elapsed is unknown on re-hydration — `0`
      //    renders as a bare "Thought" disclosure (no misleading "· 0s").
      if let reasoning = message.reasoningText {
        append(.thinking(
          reasoning: reasoning, status: nil, elapsedSeconds: 0, isComplete: true
        ))
      }
      // 2. Assistant text row (the server omits empty/tool-only assistant turns, so a
      //    missing body here just means there's nothing to render for it).
      if let text = message.displayText {
        append(.message(role: .assistant, text: text, isComplete: true))
      }

    case "user":
      // Gateway display-only timeline rows (delegation deliveries, skill invocations, model
      // switches) are stored as role=user bookkeeping — desktop renders them as status cards.
      // Painting them as user bubbles misattributed the gateway's own notices to Michael.
      // Delegation deliveries render as a collapsed status row with the summary counts;
      // other display-kind rows are hidden entirely (their content is agent-facing).
      if let kind = message.displayKind, !kind.isEmpty {
        if kind == "async_delegation_complete" {
          append(.status(kind: "delegation", text: SessionMessage.delegationStatusText(message)))
        }
        continue
      }
      if let text = message.displayText {
        append(.message(role: .user, text: text, isComplete: true))
      }

    default:
      // Unknown / `system` role — mobile has no bubble for it; skip, never crash.
      continue
    }
  }

  return rows
}
