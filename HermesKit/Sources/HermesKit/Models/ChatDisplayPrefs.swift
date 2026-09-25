import Foundation

/// Which transcript rows a chat renders, and whether arriving content may move the
/// viewport (#55). Device-local, user-controlled — the app has no server-side display
/// settings for the transcript, and the gateway's own `display.show_reasoning` governs the
/// CLI/TUI, not this client.
///
/// Activity is quiet by default: tool and completed thinking rows are hidden, but the
/// live thinking indicator remains visible while a turn runs. Existing explicit choices
/// remain persisted; following stays enabled.
///
/// Filtering happens on the ROW LIST handed to the renderer, never inside the reducer's
/// `transcript`: the reducer's rows are the source of truth for windowing, row identity,
/// and the streaming fold, and hiding a row must not disturb any of that. A hidden row is
/// simply not rendered — it is not deleted, and turning the pref back on brings it back
/// without a re-fetch.
public struct ChatDisplayPrefs: Equatable, Sendable {
  /// Show agent activity in the transcript when enabled; the live progress cue remains visible.
  public var showToolRows: Bool
  /// Keep the live thinking indicator visible; toggle frozen reasoning disclosures.
  public var showThinkingRows: Bool
  /// Follow new content to the bottom while a turn streams. When `false`, the viewport
  /// stays where the user left it and only an explicit "jump to latest" moves it.
  public var autoFollowEnabled: Bool

  public init(
    showToolRows: Bool = false,
    showThinkingRows: Bool = false,
    autoFollowEnabled: Bool = true
  ) {
    self.showToolRows = showToolRows
    self.showThinkingRows = showThinkingRows
    self.autoFollowEnabled = autoFollowEnabled
  }

  /// The default — every row kind rendered, following enabled.
  public static let `default` = ChatDisplayPrefs()

  /// True when this pref set changes nothing, i.e. the renderer can take its unmodified
  /// path. Lets the view skip filtering work (and keeps the common case allocation-free).
  public var showsEverything: Bool {
    showToolRows && showThinkingRows && autoFollowEnabled
  }

  /// Whether `row` should be rendered under these prefs. Message rows, status lines, slash
  /// output, and the user's own messages are ALWAYS kept: the prefs govern agent ACTIVITY
  /// reporting only. An answer must never be hideable by a display toggle — that would turn
  /// a readability pref into silent data loss.
  /// Activity remains inspectable on demand. Only the live thinking row stays
  /// visible with the quiet default, so the user can tell Hermes is working.
  public func shows(_ row: ChatRow) -> Bool {
    switch row.kind {
    case .tool: return showToolRows
    case let .thinking(_, _, _, isComplete): return showThinkingRows || !isComplete
    case .message, .status, .commandOutput: return true
    }
  }

  /// Apply the prefs to a row list. Returns the input unchanged when nothing is hidden.
  public func apply<C: Collection>(to rows: C) -> [ChatRow] where C.Element == ChatRow {
    guard !showsEverything else { return Array(rows) }
    return rows.filter(shows)
  }
}
