import Foundation

/// Pure presentation rules for the composer's action buttons (D1).
///
/// Before D1 one icon changed meaning with state the user could not see: the send arrow
/// silently became a red Stop when the draft was empty and flipped back to an arrow (that
/// QUEUED instead of sending) as soon as anything was typed — so stopping a running turn
/// meant deleting the draft first. These rules make every action explicit:
///
/// - **Stop** is its own control and is present for the whole running turn, draft or not.
///   While the running "turn" is really the client still uploading attachments (no server
///   turn has been confirmed yet) the same control reads **Cancel upload** instead of
///   claiming it stops a server turn.
/// - The primary action is **Send** when idle and **Queue** while a turn runs, with
///   distinct visible copy and VoiceOver labels.
/// - A disabled primary action with a typed draft always carries a human reason.
///
/// Eligibility itself is NOT decided here: `canSend` / `canQueue` stay the reducer's
/// authoritative gates and are passed in unchanged. This type only names and explains.
public struct ComposerControls: Equatable, Sendable {
  public enum Primary: Equatable, Sendable {
    case send
    case queue
  }

  public enum Stop: Equatable, Sendable {
    /// Ask the server to stop the running turn (`session.interrupt`).
    case stopTurn
    /// The client is still preparing/uploading attachments for a submit; cancelling
    /// stops that preparation. Same reducer action, honest copy.
    case cancelPreparation
  }

  /// Why sending/queueing is unavailable even though the user has a draft. Ordered by
  /// what the user can act on first.
  public struct Blockers: Equatable, Sendable {
    public var isPasting = false
    public var hasBlockingCard = false
    public var isReconnecting = false
    public var deliveryPending = false
    public var isBranching = false

    public init(
      isPasting: Bool = false, hasBlockingCard: Bool = false, isReconnecting: Bool = false,
      deliveryPending: Bool = false, isBranching: Bool = false
    ) {
      self.isPasting = isPasting
      self.hasBlockingCard = hasBlockingCard
      self.isReconnecting = isReconnecting
      self.deliveryPending = deliveryPending
      self.isBranching = isBranching
    }
  }

  public var primary: Primary
  public var primaryEnabled: Bool
  public var stop: Stop?
  /// Shown (and announced) only when the user has a draft that cannot go anywhere yet.
  public var blockedReason: String?

  public static func derive(
    isSending: Bool,
    isSlashExecuting: Bool = false,
    isPreparingAttachments: Bool = false,
    hasContent: Bool,
    canSend: Bool,
    canQueue: Bool,
    blockers: Blockers = Blockers()
  ) -> ComposerControls {
    let turnRunning = isSending || isSlashExecuting
    let primary: Primary = turnRunning ? .queue : .send
    let enabled = turnRunning ? canQueue : canSend
    let stop: Stop? = isSending ? (isPreparingAttachments ? .cancelPreparation : .stopTurn) : nil
    var reason: String? = nil
    if hasContent, !enabled {
      reason = blockedReason(
        primary: primary, isPreparingAttachments: isPreparingAttachments, blockers: blockers)
    }
    return ComposerControls(primary: primary, primaryEnabled: enabled, stop: stop, blockedReason: reason)
  }

  private static func blockedReason(
    primary: Primary, isPreparingAttachments: Bool, blockers: Blockers
  ) -> String {
    if blockers.isPasting { return "Adding the pasted image…" }
    if blockers.hasBlockingCard {
      return primary == .queue
        ? "Answer the request above first. Your draft is kept."
        : "Answer the request above to send. Your draft is kept."
    }
    if blockers.isReconnecting { return "Connecting. Your draft is kept." }
    if isPreparingAttachments {
      return "Uploading attachments. Wait for it to finish, or tap Cancel upload."
    }
    if blockers.deliveryPending {
      return "\(deliveryPendingHeader). Your draft is kept."
    }
    if blockers.isBranching { return "Creating the branch. Your draft is kept." }
    return primary == .queue
      ? "Can't queue right now. Your draft is kept."
      : "Can't send right now. Your draft is kept."
  }

  // MARK: Copy (one place so visible text, VoiceOver and tests agree)

  public var primaryTitle: String { primary == .queue ? "Queue" : "Send" }
  public var primaryAccessibilityLabel: String {
    primary == .queue ? "Queue message" : "Send"
  }
  public var primaryAccessibilityHint: String {
    if let blockedReason { return blockedReason }
    return primary == .queue
      ? "Sends after the current turn finishes. Does not stop it."
      : "Sends this message now."
  }
  public var stopTitle: String? {
    switch stop {
    case .stopTurn: "Stop"
    case .cancelPreparation: "Cancel upload"
    case nil: nil
    }
  }
  public var stopAccessibilityHint: String? {
    switch stop {
    case .stopTurn: "Asks the server to stop the running turn. Your draft is kept."
    case .cancelPreparation: "Stops preparing the attachments. Your draft is kept."
    case nil: nil
    }
  }

  /// Queue-row actions (QueuedPromptsPanel), named for what they do to the running turn.
  public static func queueSendTitle(isTurnRunning: Bool) -> String {
    isTurnRunning ? "Interrupt & send" : "Send now"
  }
  public static let steerTitle = "Steer current turn"
  /// One wording for "a send/Stop is awaiting confirmation" in the composer and queue menu.
  public static let deliveryPendingHeader = "Waiting for the last message or Stop to be confirmed"

  /// True while a legacy (non-durable) attachment submit is still uploading — the client,
  /// not a confirmed server turn, owns the work Stop would cancel.
  public static func isPreparingAttachments(
    attachments: [ComposerAttachment], submitOutcome: SubmitOperation.Outcome?
  ) -> Bool {
    submitOutcome == .submitting && attachments.contains { $0.uploadState == .uploading }
  }
}
