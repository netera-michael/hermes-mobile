import HermesKit
import SwiftUI

/// The queued-prompt panel (#66): compact rows pinned between the transcript and the
/// composer (above the slash-suggestion panel — deliberately NOT in the transcript, so
/// wholesale hydrates can never touch it). Each row is a frozen draft waiting for the
/// running turn to end; a visible ellipsis menu and long-press menu share all actions.
/// Steer delivers the text into the RUNNING turn without cancelling it, so it is
/// offered only while a turn is live and only for entries the gateway can carry
/// (text-only, non-empty, not a slash command) — see `SteerEligibility`.
///
/// Sizing: this sits in the same non-scrolling, compressible region #65 mapped out, so
/// the panel must never grow unbounded and squeeze the transcript. Up to
/// `inlineRowLimit` rows it hugs its content (a plain `VStack`); beyond that, or at
/// accessibility text sizes, it scrolls at a fixed capped height. The 240-point ceiling
/// leaves room for the transcript/composer instead of scaling the whole panel unbounded.
struct QueuedPromptsPanel: View {
  let entries: [QueuedPrompt]
  /// Parked (#66): a manual Stop or a turn error suspended auto-drain — the rows wait
  /// for an explicit Send Now. Swaps the row icon and adds the "held" header.
  let isParked: Bool
  /// Mirrors the reducer's Edit guard (`.queuedPromptEditTapped` requires an empty
  /// composer): the menu item is disabled while a draft is mid-typing so the two can't
  /// disagree — the reducer stays authoritative.
  let composerHasDraft: Bool
  /// Whether a turn is in flight. A steer only makes sense mid-turn: with no live turn
  /// there is nothing to steer into, so the affordance is withheld and the entry waits for
  /// the ordinary drain. The reducer re-checks this — the panel only mirrors it.
  let isTurnRunning: Bool
  var waitsToSend: Bool = false
  var deliveryBlocked: Bool = false
  let onSteer: (UUID) -> Void
  let onSendNow: (UUID) -> Void
  let onEdit: (UUID) -> Void
  let onDelete: (UUID) -> Void

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  /// Rows beyond which the panel stops hugging and scrolls internally.
  private static let inlineRowLimit = 3
  /// Scale ordinary text sizes, but clamp the scrolling region at accessibility sizes.
  @ScaledMetric(relativeTo: .callout) private var scrollingPanelHeight: CGFloat = 172

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if waitsToSend {
        Label("Waiting for confirmed stop — then sends next", systemImage: "clock")
          .font(.footnote)
          .foregroundStyle(.secondary)
          .padding(.horizontal, 4)
      } else if isParked {
        // Held rows look identical to queued ones at a glance — say why nothing is
        // sending. (Queued rows need no header: the turn spinner right above them
        // already explains the wait.)
        Label("Held — not sent automatically", systemImage: "pause.circle")
          .font(.footnote)
          .foregroundStyle(.secondary)
          .padding(.horizontal, 4)
      }
      if entries.count > Self.inlineRowLimit || dynamicTypeSize.isAccessibilitySize {
        ScrollView {
          rowsStack
        }
        .frame(height: min(scrollingPanelHeight, 240))
        .scrollIndicators(.visible)
      } else {
        rowsStack
      }
    }
    .padding(.horizontal)
    .padding(.top, 6)
  }

  private var rowsStack: some View {
    VStack(spacing: 6) {
      ForEach(entries) { entry in
        row(entry)
      }
    }
  }

  private func row(_ entry: QueuedPrompt) -> some View {
    HStack(spacing: 8) {
      Image(systemName: isParked ? "pause.circle" : "clock")
        .font(.footnote)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      Text(displayText(entry))
        .font(.callout)
        .lineLimit(2)
        // Without this the HStack's ideal-height pass hands the Text a one-line
        // proposal and it TRUNCATES at one line instead of wrapping to the two
        // `lineLimit` allows (verified in the first recorded baseline).
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("\(isParked ? "Held" : "Queued") message: \(displayText(entry))")
      if !entry.attachments.isEmpty {
        Label("\(entry.attachments.count)", systemImage: "paperclip")
          .font(.caption)
          .foregroundStyle(.secondary)
          .accessibilityLabel("\(entry.attachments.count) attachments")
      }
      Menu {
        actions(for: entry)
      } label: {
        Image(systemName: "ellipsis")
          .font(.body)
          .frame(width: 44, height: 44)
          .contentShape(.rect)
      }
      .accessibilityLabel("Actions for queued message")
      .accessibilityValue(displayText(entry))
      .accessibilityHint("Send, edit, or delete this message. Steer is available for eligible running turns.")
      .accessibilityIdentifier("queue.actions.\(entry.id.uuidString)")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: 14))
    .contentShape(.rect(cornerRadius: 14))
    .contextMenu { actions(for: entry) }
    // Keep the visible menu independently focusable; combining the row can swallow it.
    .accessibilityElement(children: .contain)
  }

  /// One definition keeps the visible menu and long-press eligibility/callbacks identical.
  @ViewBuilder
  private func actions(for entry: QueuedPrompt) -> some View {
    if !deliveryBlocked, SteerEligibility.canSteerNow(entry, isTurnRunning: isTurnRunning) {
      Section("Without interrupting the current turn") {
        Button { onSteer(entry.id) } label: {
          Label("Steer Now", systemImage: "arrow.turn.down.right")
        }
        .accessibilityHint("Corrects the running turn without stopping it.")
      }
    }
    Section(isTurnRunning ? "Send next (interrupts a running turn)" : "Send as a new turn") {
      Button { onSendNow(entry.id) } label: {
        Label("Send Now", systemImage: "paperplane")
      }
      .disabled(deliveryBlocked)
    }
    Section {
      Button { onEdit(entry.id) } label: {
        Label("Edit", systemImage: "pencil")
      }
      .disabled(composerHasDraft)
      Button(role: .destructive) { onDelete(entry.id) } label: {
        Label("Delete", systemImage: "trash")
      }
    } header: {
      if composerHasDraft { Text("Clear the composer to edit") }
    }
  }

  /// An attachment-only draft has no text to show — fall back to its filenames.
  private func displayText(_ entry: QueuedPrompt) -> String {
    entry.text.isEmpty
      ? entry.attachments.map(\.filename).joined(separator: ", ")
      : entry.text
  }
}
