import HermesKit
import SwiftUI

/// Non-shipping host; compiles the production QueuedPromptsPanel.swift and (D1)
/// ComposerView.swift with its real subviews.
@main
struct QueueControlsProofApp: App {
  var body: some Scene {
    WindowGroup {
      if ProcessInfo.processInfo.arguments.contains("composer") {
        ComposerFixture()
      } else {
        QueueControlsFixture()
      }
    }
  }
}

/// D1 composer fixture: production ComposerView, real UITextView, real callbacks.
private struct ComposerFixture: View {
  private let arguments = ProcessInfo.processInfo.arguments
  @State private var draft = ProcessInfo.processInfo.arguments.contains("draft") ? "Keep this draft" : ""
  @State private var outcome = "No callback"

  private var running: Bool { arguments.contains("running") || arguments.contains("preparing") }
  private var attachments: [ComposerAttachment] {
    guard arguments.contains("preparing") else { return [] }
    var a = ComposerAttachment(id: UUID(), kind: .image, filename: "photo.png", mimeType: "image/png", data: Data())
    a.uploadState = .uploading
    return [a]
  }

  var body: some View {
    VStack {
      Text(outcome).font(.caption).accessibilityIdentifier("composer.callback")
      Text("draft:\(draft)").font(.caption).accessibilityIdentifier("composer.draft")
      Spacer()
      ComposerView(
        text: $draft,
        isSending: running,
        canSend: !running && !draft.isEmpty && !arguments.contains("card"),
        canQueue: running && !draft.isEmpty && !arguments.contains("card") && !arguments.contains("preparing"),
        model: arguments.contains("longModel")
          ? "anthropic/claude-opus-4-8-extended-context-preview-20261001" : "claude-opus-4-8",
        reasoningEffort: "high",
        attachmentsSupported: true,
        attachments: attachments,
        isPreparingAttachments: arguments.contains("preparing"),
        blockers: .init(hasBlockingCard: arguments.contains("card"),
                        deliveryPending: arguments.contains("preparing")),
        blockingCardToken: arguments.contains("card") ? 1 : nil,
        onModelTap: { outcome = "model" },
        onSend: { outcome = running ? "queued:\(draft)" : "sent:\(draft)"; draft = "" },
        onInterrupt: { outcome = "interrupt" },
        onVoiceTap: { outcome = "voice" }
      )
    }
    .frame(width: 320)
    .dynamicTypeSize(arguments.contains("AX5") ? .accessibility5 : .large)
  }
}

private struct QueueControlsFixture: View {
  private let arguments = ProcessInfo.processInfo.arguments
  @State private var outcome = "No callback"
  private static let firstID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

  private var entries: [QueuedPrompt] {
    let attachments: [ComposerAttachment] = arguments.contains("attachment") ? [
      ComposerAttachment(id: UUID(), kind: .image, filename: "reference.png", mimeType: "image/png", data: Data())
    ] : []
    let first = QueuedPrompt(id: Self.firstID,
      text: arguments.contains("slash") ? "/help" : "Check the reconnect behavior before making any changes to the running session.",
      attachments: attachments)
    return [first] + (arguments.contains("many") ? (2...8).map {
      QueuedPrompt(id: UUID(), text: "Queued message \($0)")
    } : [])
  }

  var body: some View {
    VStack {
      Text(outcome).font(.caption).accessibilityIdentifier("queue.callback")
      QueuedPromptsPanel(
        entries: entries, isParked: arguments.contains("parked"),
        composerHasDraft: arguments.contains("draft"), isTurnRunning: !arguments.contains("idle"),
        waitsToSend: arguments.contains("waiting"), deliveryBlocked: arguments.contains("blocked"),
        onSteer: { outcome = "steer:\($0.uuidString)" },
        onSendNow: { outcome = "send:\($0.uuidString)" },
        onEdit: { outcome = "edit:\($0.uuidString)" },
        onDelete: { outcome = "delete:\($0.uuidString)" }
      )
      Spacer()
    }
    .frame(width: 320)
    .dynamicTypeSize(arguments.contains("AX5") ? .accessibility5 : .large)
  }
}
