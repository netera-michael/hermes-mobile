import HermesKit
import SwiftUI

/// One row in the session list. Like the desktop sidebar: a human-readable name
/// (`Session.displayName`: title → preview → id) + relative age + an unread dot. A
/// *secondary* preview line is shown only for search results (`showsPreview`); when a
/// session has no real title the preview is promoted to the headline everywhere.
struct SessionRowView: View {
  let session: Session
  /// Reference date the timestamp is relative to (injected so it's controllable).
  var now: Date = Date()
  /// Show the preview as a *secondary* line under a real title (search results). The
  /// preview is still promoted to the headline for untitled sessions regardless of this.
  var showsPreview: Bool = false
  /// New activity since the user last opened this session.
  var isUnread: Bool = false
  /// Whether this session is pinned (shows a small pin glyph).
  var isPinned: Bool = false
  /// Whether the agent is currently working this session — replaces the timestamp
  /// with a compact status cue.
  var isActive: Bool = false

  private static let relativeFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.dateTimeStyle = .named
    return formatter
  }()

  var body: some View {
    // Never show the raw `session.id` as a name: with no real title (incl. the server's
    // "Untitled" placeholder), promote the first-message preview to the headline — in the
    // grouped list too, not just search. `displayName` is the shared rule (title → preview → id).
    let snippet = session.resolvedPreview
    let promotesSnippet = session.resolvedTitle == nil && snippet != nil
    let headline = session.displayName

    return VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        if isUnread {
          Circle().fill(Color.hermesAccent).frame(width: 8, height: 8)
            .accessibilityLabel("Unread")
        }
        Text(headline)
          .font(.headline)
          .fontWeight(isUnread ? .semibold : .regular)
          // Two lines for every headline, titled or promoted: one line truncates most real
          // titles, and the iPad sidebar is narrower than a phone's full width, so a single
          // line loses the part that distinguishes one session from the next.
          //
          // `fixedSize(vertical:)` is LOAD-BEARING, not decoration: in an `HStack` every child
          // is offered the stack's height, which is the tallest child's IDEAL height — one line
          // for a `Text`. Without it the headline is handed a one-line height, so it truncates
          // at the first line and `lineLimit(2)` never takes effect (the promoted-preview branch
          // carried a dead `lineLimit(2)` for exactly this reason until #80).
          .lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
        if isPinned {
          Image(systemName: "pin.fill")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Pinned")
        }
        Spacer()
        if isActive {
          HStack(spacing: 4) {
            ProgressView()
              .controlSize(.mini)
              .tint(Color.hermesAccent)
              .accessibilityHidden(true)
            Text("Working")
              .font(.caption)
              .fontWeight(.medium)
          }
          .foregroundStyle(Color.hermesAccent)
          .fixedSize()
          .accessibilityElement(children: .ignore)
          .accessibilityLabel("Working")
        } else if let updatedAt = session.updatedAt {
          Text(Self.relativeFormatter.localizedString(for: updatedAt, relativeTo: now))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      // Show the snippet as a secondary line only when it isn't already the headline.
      if showsPreview, !promotesSnippet, let preview = snippet {
        Text(preview)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
    }
    .padding(.vertical, 2)
  }
}
