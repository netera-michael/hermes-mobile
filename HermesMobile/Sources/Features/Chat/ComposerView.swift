import HermesKit
import SwiftUI

/// The message composer: a growing text field above a toolbar row with a model/reasoning
/// chip (tappable → picker), a voice button, a labelled Send/Queue button and — while a
/// turn runs — a separate labelled Stop / Cancel upload button (D1, `ComposerControls`). While recording (#7) the field is replaced by a live waveform, elapsed
/// time, and cancel/stop controls.
struct ComposerView: View {
  @Binding var text: String
  let isSending: Bool
  let canSend: Bool
  /// Mid-turn queueability (#66, `ChatFeature.State.canQueue`): true when the composer
  /// holds content that a mid-turn send would QUEUE. Enables the mid-turn Queue button;
  /// Stop is a separate control and no longer depends on it (D1).
  /// Defaulted so the snapshot call sites stay unchanged.
  var canQueue: Bool = false
  let model: String?
  let reasoningEffort: String?
  /// Context-window usage (#4): a compact gauge beside the model chip. Hidden when nil or
  /// when the usage has no usable label.
  var usage: Usage? = nil
  /// Voice-input state (#7): drives whether the composer shows text entry or the recorder.
  var recording: ChatFeature.State.RecordingState = .idle
  var waveformLevels: [Float] = []
  var recordingSeconds: Int = 0
  /// Attachments (#8): hide the attach control when the agent can't accept uploads.
  var attachmentsSupported: Bool = true
  var attachments: [ComposerAttachment] = []
  /// D1: a slash command is executing (locks like a turn; the primary action queues).
  var isSlashExecuting: Bool = false
  /// D1: the client is still uploading attachments for a submit — Stop reads
  /// "Cancel upload" instead of claiming a server turn stopped.
  var isPreparingAttachments: Bool = false
  /// D1: why Send/Queue is unavailable, so a disabled button is never unexplained.
  var blockers: ComposerControls.Blockers = .init()
  /// Identity of the blocking card standing over the chat, if any — raising one hands the
  /// keyboard back so the card gets the fixed region (#65). See
  /// `ComposerTextView.blockingCardToken`. The composer is **not** disabled: only Send is
  /// (`canSend` is false while a card stands), so the field stays available for a draft.
  var blockingCardToken: Int? = nil
  let onModelTap: () -> Void
  let onSend: () -> Void
  let onInterrupt: () -> Void
  var onVoiceTap: () -> Void = {}
  var onCancelRecording: () -> Void = {}
  var onAttachPhotos: () -> Void = {}
  var onAttachCamera: () -> Void = {}
  var onAttachFiles: () -> Void = {}
  var onRemoveAttachment: (ComposerAttachment.ID) -> Void = { _ in }
  /// A paste has been claimed and its providers are loading (#54) — fires before
  /// `onPasteImages` so the reducer can hold Send down for the async window.
  var onPasteBegan: () -> Void = {}
  /// Images pasted into the input itself (#54) — the fourth attachment source, already
  /// loaded by `ComposerTextView`'s coordinator. Defaulted so the snapshot call sites (which
  /// never paste) stay unchanged.
  var onPasteImages: (PickedBatch) -> Void = { _ in }

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  /// Derived, never stored: the reducer's `canSend`/`canQueue` stay authoritative.
  var controls: ComposerControls {
    ComposerControls.derive(
      isSending: isSending, isSlashExecuting: isSlashExecuting,
      isPreparingAttachments: isPreparingAttachments,
      hasContent: !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty,
      canSend: canSend, canQueue: canQueue, blockers: blockers
    )
  }

  var body: some View {
    Group {
      if recording.isBusy {
        recordingBar
      } else {
        textComposer
      }
    }
    .padding(12)
    .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: 22))
    .padding(.horizontal)
    .padding(.vertical, 8)
  }

  private var textComposer: some View {
    VStack(spacing: 10) {
      if !attachments.isEmpty { attachmentChips }
      // A `UITextView`-backed field rather than `TextField(axis: .vertical)`: only UIKit
      // exposes the paste hooks an image paste needs (#54). Placeholder and 1–6 line growth are
      // parity with what it replaced (all defaulted on the type); Return inserts a newline and
      // the Send/Queue button is the only way to submit (#70).
      ComposerTextView(
        text: $text,
        // Same capability gate as the paperclip: no Paste offer for an image-only clipboard
        // when the agent can't accept uploads.
        attachmentsSupported: attachmentsSupported,
        blockingCardToken: blockingCardToken,
        onPasteBegan: onPasteBegan,
        onPasteImages: onPasteImages
      )

      if let reason = controls.blockedReason {
        // A disabled Send/Queue always says why (D1); the draft itself is untouched.
        Label(reason, systemImage: "info.circle")
          .font(.footnote)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityIdentifier("composer.blockedReason")
      }

      if dynamicTypeSize.isAccessibilitySize {
        // AX sizes: extra rows before shrinking anything — the actions get their own
        // full-width rows (wrapping, never clipped or overlapping, each ≥44pt).
        stackedToolbar(fullWidthActions: true)
      } else {
        // One row when everything fits at its ideal width (idle, short model name);
        // otherwise — e.g. Stop + Queue mid-turn on a phone — the actions move to a second
        // row instead of squeezing the model chip or overflowing the composer (D1).
        ViewThatFits(in: .horizontal) {
          inlineToolbar(.inline)
          // Same single row with text-only pills: still labelled, ~40pt narrower, so a
          // running turn on a phone keeps one row instead of costing transcript height.
          inlineToolbar(.compact)
          stackedToolbar(fullWidthActions: false)
        }
      }
    }
  }

  private func inlineToolbar(_ style: ActionStyle) -> some View {
    HStack(spacing: 8) {
      // Let the model chip claim its ideal width before the Spacer, so the model name
      // shows in full when there's room.
      modelChip
        .layoutPriority(1)
      if let usage { ContextUsageRing(usage: usage) }
      Spacer(minLength: 0)
      if attachmentsSupported { attachButton }
      voiceButton
      actionButtons(style)
    }
  }

  /// Model/usage and attach/voice on the first row, actions on their own row below.
  private func stackedToolbar(fullWidthActions: Bool) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        modelChip.layoutPriority(1)
        if let usage { ContextUsageRing(usage: usage) }
        Spacer(minLength: 0)
        if attachmentsSupported { attachButton }
        voiceButton
      }
      if fullWidthActions {
        VStack(spacing: 8) { actionButtons(.stacked) }
      } else {
        HStack(spacing: 8) {
          Spacer(minLength: 0)
          actionButtons(.inline)
        }
      }
    }
  }

  /// Stop (or Cancel upload) and the primary Send/Queue are SEPARATE controls (D1): typing
  /// a draft mid-turn no longer hides Stop, so stopping never requires deleting the draft.
  @ViewBuilder
  private func actionButtons(_ style: ActionStyle) -> some View {
    let controls = controls
    if controls.stop != nil { stopButton(controls, style: style) }
    primaryButton(controls, style: style)
  }

  /// How the Stop/Send/Queue pills are drawn. Every style keeps the visible title.
  enum ActionStyle {
    /// Icon + title, one line at its ideal width.
    case inline
    /// Title only, one line — the fallback before the toolbar takes a second row.
    case compact
    /// Icon + title at full row width, wrapping (accessibility text sizes).
    case stacked
  }

  @ViewBuilder
  private func actionLabel(_ title: String, systemImage: String, style: ActionStyle) -> some View {
    let stacked = style == .stacked
    Group {
      if style == .compact {
        Text(title)
      } else {
        Label(title, systemImage: systemImage)
      }
    }
    .font(.subheadline.weight(.semibold))
    .lineLimit(stacked ? 3 : 1)
    .multilineTextAlignment(.center)
    .fixedSize(horizontal: !stacked, vertical: true)
    .padding(.horizontal, style == .compact ? 10 : 12)
    .padding(.vertical, stacked ? 6 : 0)
    .frame(minWidth: 44, maxWidth: stacked ? .infinity : nil, minHeight: 44)
  }

  private var attachmentChips: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        ForEach(attachments) { attachment in
          AttachmentChip(attachment: attachment) { onRemoveAttachment(attachment.id) }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var attachButton: some View {
    Menu {
      Button { onAttachPhotos() } label: { Label("Photo Library", systemImage: "photo.on.rectangle") }
      Button { onAttachCamera() } label: { Label("Camera", systemImage: "camera") }
      Button { onAttachFiles() } label: { Label("Files", systemImage: "folder") }
    } label: {
      Image(systemName: "paperclip")
        .font(.title3)
        .foregroundStyle(.secondary)
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(.rect)
    }
    // Menu tints its label with the accent by default; pin it to match the mic button.
    .tint(.secondary)
    .accessibilityLabel("Add attachment")
  }

  @ViewBuilder
  private var recordingBar: some View {
    if recording == .transcribing || recording == .requestingPermission {
      HStack(spacing: 10) {
        ProgressView().controlSize(.small)
        Text(recording == .transcribing ? "Transcribing…" : "Allow microphone")
          .font(.callout).foregroundStyle(.secondary)
        Spacer()
        Button(action: onCancelRecording) {
          Text("Cancel").frame(minWidth: 44, minHeight: 44).contentShape(.rect)
        }
      }
      .frame(minHeight: 40)
    } else {
      HStack(spacing: 12) {
        Button(action: onCancelRecording) {
          Image(systemName: "xmark").font(.body.weight(.semibold))
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(.rect)
        }
        .foregroundStyle(.secondary)
        .accessibilityLabel("Cancel recording")

        Text("Recording").font(.callout)
        RecordingWaveform(levels: waveformLevels)

        Text(Self.elapsed(recordingSeconds))
          .font(.callout.monospacedDigit())
          .foregroundStyle(.secondary)

        Button(action: onVoiceTap) {
          Image(systemName: "stop.circle.fill").font(.title)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(.rect)
        }
        .foregroundStyle(Color.hermesAccent)
        .accessibilityLabel("Stop and transcribe")
      }
      .frame(minHeight: 40)
    }
  }

  /// `m:ss` elapsed-time readout for the recorder.
  static func elapsed(_ seconds: Int) -> String {
    String(format: "%d:%02d", seconds / 60, seconds % 60)
  }

  private var modelChip: some View {
    Button(action: onModelTap) {
      HStack(spacing: 5) {
        Text(modelLabel)
          .lineLimit(1)
        if let effort = reasoningEffort, !effort.isEmpty {
          Text("·").foregroundStyle(.tertiary)
          Text(effort)
        }
        Image(systemName: "chevron.up.chevron.down").font(.caption2)
      }
      .font(.footnote.weight(.medium))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(.quaternary, in: Capsule())
      // 44pt hit area without inflating the visible chip.
      .frame(minHeight: 44)
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Model: \(modelLabel)")
    .accessibilityHint("Choose the model and reasoning effort.")
  }

  private var voiceButton: some View {
    Button(action: onVoiceTap) {
      Image(systemName: "mic.fill")
        .font(.title3)
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(.rect)
    }
    .foregroundStyle(.secondary)
    .accessibilityLabel("Voice input")
  }

  private func stopButton(_ controls: ComposerControls, style: ActionStyle) -> some View {
    Button(action: onInterrupt) {
      actionLabel(controls.stopTitle ?? "Stop",
                  systemImage: controls.stop == .cancelPreparation ? "xmark.circle.fill" : "stop.fill",
                  style: style)
        .background(Color.red.opacity(0.14), in: Capsule())
        .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .foregroundStyle(.red)
    .accessibilityLabel(controls.stopTitle ?? "Stop")
    .accessibilityHint(controls.stopAccessibilityHint ?? "")
    .accessibilityIdentifier("composer.stop")
  }

  private func primaryButton(_ controls: ComposerControls, style: ActionStyle) -> some View {
    // Idle → Send; mid-turn → Queue (#66). The reducer still branches on
    // `isSending`/`slashExecInFlight` for `.composerSubmitted`; the view only names it.
    Button(action: onSend) {
      actionLabel(controls.primaryTitle,
                  systemImage: controls.primary == .queue ? "text.badge.plus" : "arrow.up",
                  style: style)
        .foregroundStyle(controls.primaryEnabled ? Color.white : Color.secondary)
        .background(
          controls.primaryEnabled ? Color.hermesAccent : Color(uiColor: .tertiarySystemFill),
          in: Capsule())
        .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .disabled(!controls.primaryEnabled)
    .accessibilityLabel(controls.primaryAccessibilityLabel)
    .accessibilityHint(controls.primaryAccessibilityHint)
    .accessibilityIdentifier("composer.primary")
  }

  private var modelLabel: String {
    if let model, !model.isEmpty { return ModelDisplayName.label(model) }
    return "Model"
  }
}

/// Live amplitude bars for the active voice recording (#7). Newest sample is on the
/// right; bars grow from the vertical center. Honors reduce-motion (no height animation).
struct RecordingWaveform: View {
  let levels: [Float]

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    GeometryReader { geo in
      HStack(alignment: .center, spacing: 2) {
        ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
          Capsule()
            .fill(Color.hermesAccent.opacity(0.85))
            .frame(width: 2.5, height: barHeight(level, in: geo.size.height))
        }
        Spacer(minLength: 0)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
      .animation(reduceMotion ? nil : .linear(duration: 0.1), value: levels)
    }
    .frame(height: 28)
    .accessibilityHidden(true)
  }

  private func barHeight(_ level: Float, in height: CGFloat) -> CGFloat {
    max(3, CGFloat(min(max(level, 0), 1)) * height)
  }
}

/// A staged attachment shown above the composer input (#8): image thumbnail or a
/// file/PDF glyph, the filename, and an upload-state indicator (spinner / error) or a
/// remove button.
struct AttachmentChip: View {
  let attachment: ComposerAttachment
  let onRemove: () -> Void

  var body: some View {
    HStack(spacing: 6) {
      thumbnail
      Text(attachment.filename)
        .font(.caption)
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(maxWidth: 120, alignment: .leading)
      trailing
    }
    .padding(.leading, 8)
    .background(.quaternary, in: .rect(cornerRadius: 10))
  }

  @ViewBuilder private var thumbnail: some View {
    switch attachment.kind {
    case .image:
      if let image = UIImage(data: attachment.data) {
        Image(uiImage: image)
          .resizable()
          .scaledToFill()
          .frame(width: 28, height: 28)
          .clipShape(.rect(cornerRadius: 5))
      } else {
        glyph("photo")
      }
    case .pdf:
      glyph("doc.richtext")
    case .file:
      glyph("doc")
    }
  }

  private func glyph(_ name: String) -> some View {
    Image(systemName: name)
      .font(.title3)
      .foregroundStyle(.secondary)
      .frame(width: 28, height: 28)
  }

  @ViewBuilder private var trailing: some View {
    switch attachment.uploadState {
    case .uploading:
      ProgressView().controlSize(.mini)
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityLabel("Uploading")
    case .failed:
      HStack(spacing: 0) {
        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
          .accessibilityLabel("Upload failed. Tap Send or Queue to retry, or remove it.")
        removeButton
      }
      .font(.caption)
    case .pending, .uploaded:
      removeButton
    }
  }

  private var removeButton: some View {
    Button(action: onRemove) {
      Image(systemName: "xmark.circle.fill").font(.caption)
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .foregroundStyle(.secondary)
    .accessibilityLabel("Remove \(attachment.filename)")
  }
}
