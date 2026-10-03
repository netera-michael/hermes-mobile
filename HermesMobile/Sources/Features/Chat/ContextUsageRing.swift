import HermesKit
import SwiftUI

/// Compact context-window gauge for the composer toolbar: a small ring filled to
/// `usage.contextFraction`, tinted by `usage.severity`, with the whole-percent label
/// centered inside. Replaces the older labeled capsule pill — on a real device three
/// labeled controls truncated, so the numbers now live in the tap popover and the toolbar
/// only carries the ring (#4 follow-up).
///
/// When the max is unknown (`contextFraction == nil`) only the faint track ring renders —
/// no fill, no percent — so we never show a misleading gauge; tapping still reveals the
/// token count. The view returns nothing when usage has no usable label.
///
/// Display values come straight from the HermesKit `Usage` helpers; this view recomputes no
/// thresholds or formatting.
struct ContextUsageRing: View {
  let usage: Usage

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  // Popover presentation is pure UI with no bearing on app/session state, so it lives in
  // local view @State rather than `ChatFeature` — keeps the reducer lean (no action/state
  // for a transient disclosure).
  @State private var showDetail = false

  private let diameter: CGFloat = 24
  private let lineWidth: CGFloat = 3

  var body: some View {
    if let label = usage.tokenLabel {
      Button {
        showDetail = true
      } label: {
        // 44pt hit area around the 24pt ring without inflating it (D1).
        ring
          .frame(minWidth: 44, minHeight: 44)
          .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .popover(isPresented: $showDetail) {
        ContextUsageDetail(usage: usage)
          .presentationCompactAdaptation(.popover)
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Context usage")
      .accessibilityValue(label)
      .accessibilityHint("Shows the context breakdown")
    }
  }

  /// A faint full track ring with a tinted arc trimmed to `fraction` (already clamped to
  /// `0...1` by `usage.contextFraction`), starting at 12 o'clock. The percent sits centered.
  /// The arc animates gently as the conversation grows, held flat under reduce-motion.
  private var ring: some View {
    ZStack {
      Circle()
        .stroke(.tertiary, lineWidth: lineWidth)

      if let fraction = usage.contextFraction {
        Circle()
          .trim(from: 0, to: fraction)
          .stroke(usage.severity.tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
          .rotationEffect(.degrees(-90))
          .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: fraction)
      }

      if let percent = usage.contextPercentLabel {
        Text(percent)
          .font(.system(size: 9, weight: .semibold).monospacedDigit())
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .minimumScaleFactor(0.7)
      }
    }
    .frame(width: diameter, height: diameter)
    .padding(.vertical, 2)
  }
}

/// Expanded breakdown shown in the ring's popover: used / max, the input vs output split,
/// the compaction count, and the running cost. Rows whose data is absent are omitted rather
/// than rendered as blanks/zeros, and a near-full nudge appears at `.critical` severity.
///
/// All display values come straight from the HermesKit `Usage` helpers/fields — this view
/// recomputes no thresholds or formatting. It's factored out (vs. an inline `.popover`
/// closure) so it can be snapshot-tested directly, since popovers don't snapshot in-place.
struct ContextUsageDetail: View {
  let usage: Usage

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Context usage")
        .font(.subheadline.weight(.semibold))

      VStack(alignment: .leading, spacing: 6) {
        if let label = usage.tokenLabel {
          row("Used", label)
        }
        if let input = usage.input {
          row("Input", Usage.formatTokens(input))
        }
        if let output = usage.output {
          row("Output", Usage.formatTokens(output))
        }
        if let compressions = usage.compressions, compressions > 0 {
          row("Compactions", "compacted \(compressions)x")
        }
        if let cost = usage.costUSD {
          row("Cost", formatCost(cost))
        }
      }
      .font(.caption.monospacedDigit())

      if usage.severity == .critical {
        Label("Context almost full — Hermes may compact soon.", systemImage: "exclamationmark.triangle.fill")
          .font(.caption2)
          .foregroundStyle(.orange)
          .labelStyle(.titleAndIcon)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding()
    .frame(minWidth: 220, alignment: .leading)
  }

  private func row(_ title: String, _ value: String) -> some View {
    HStack {
      Text(title).foregroundStyle(.secondary)
      Spacer(minLength: 16)
      Text(value).fontWeight(.medium)
    }
  }

  /// `$0.42`-style cost. Cents-scale costs keep more precision so they don't read as `$0.00`.
  private func formatCost(_ cost: Double) -> String {
    let decimals = cost < 1 ? 4 : 2
    return "$\(String(format: "%.\(decimals)f", cost))"
  }
}

extension ContextSeverity {
  /// Visual tint for the gauge fill, paired with the numeric label (no color-only meaning).
  /// Logic-free mapping; the *thresholds* are unit-tested in HermesKit, this is the
  /// *color choice* (snapshot-tested).
  var tint: Color {
    switch self {
    case .normal: .green
    case .moderate: .yellow
    case .high: .orange
    case .critical: .red
    }
  }
}
