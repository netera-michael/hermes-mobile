import HermesKit
import os
import SwiftUI
import UIKit

/// The composer's `UITextView`: `TextField` parity (placeholder, 1–`maxLines` growth, the
/// scroll flip past the ceiling) plus the image-paste interception it was swapped in for (#54).
///
/// **Return inserts a newline; the send button is the only way to submit** (#70). The field
/// deliberately intercepts nothing about the Return key — the delegate hook that used to swallow
/// a lone `"\n"` and call `onSubmit` is gone, along with the Shift+Return key command that
/// existed only to route *around* it. A multi-line prompt is the common case here, and a
/// keyboard-triggered send was too easy to hit mid-thought.
///
/// SwiftUI's `TextField` never claims `paste(_:)` for a non-text clipboard, so for an
/// image-only clipboard iOS does not even offer the **Paste** menu item. Two UIKit hooks fix
/// that and neither has a SwiftUI equivalent:
///
/// - `canPerformAction(_:withSender:)` claims `paste(_:)` whenever the pasteboard carries an
///   image — this is what makes UIKit *enable* **Paste** in the long-press edit menu.
/// - `paste(_:)` diverts the image providers to `onPasteImages` and leaves everything else to
///   `UITextView`'s stock handling, so a text (or mixed) paste is unchanged and the text
///   buffer is never touched by the image half.
///
/// **Do not reach for `pasteConfiguration` / `canPaste(_:)` / `paste(itemProviders:)`** — that
/// design tests green and ships broken: `UITextView` builds its edit menu from
/// `canPerformAction(_:withSender:)` and never consults `canPaste(_:)`. Measured in the
/// simulator; see the plan's Task 8 notes.
///
/// The clipboard is read only from inside `paste(_:)` — the implicit grant of the user tapping
/// **Paste** — so no *"Allow Paste"* banner appears. `canPerformAction` uses only the
/// non-revealing `hasImages` probe, which does not prompt.
///
/// Not `final`: the two forwards to `UITextView`'s stock behaviour go through the overridable
/// `pasteToSuper(_:)` / `superCanPerformAction(_:withSender:)` seams, which is the only way a
/// test can observe them (a spy subclass cannot see its superclass's own `super` call, and
/// `super`'s own verdict/paste always reads `UIPasteboard.general` regardless of the injected
/// `pasteboard`).
class ComposerInputTextView: UITextView {
  /// Called with the image-bearing providers of a paste. Never called with an empty array,
  /// never for a clipboard carrying no image at all, and never while `acceptsPastedImages`
  /// is `false`.
  var onPasteImages: (([NSItemProvider]) -> Void)?

  /// The clipboard the *interception* reads. Injectable so tests can drive a
  /// `UIPasteboard.withUniqueName()` instead of mutating the device's general pasteboard.
  /// It governs this class's own decisions only — the stock behaviour behind
  /// `superCanPerformAction`/`pasteToSuper` always reads `UIPasteboard.general`.
  var pasteboard: UIPasteboard = .general

  /// Mirrors `ChatFeature.State.attachmentsUnsupported` (inverted). When the agent can't
  /// accept uploads the view stops claiming **Paste** for an image-only clipboard, so iOS
  /// doesn't offer a menu item whose only possible outcome is silence — the same reason the
  /// paperclip affordance is hidden in that mode. Image-free clipboards are unaffected (text
  /// still pastes), and the reducer keeps its own silent drop as the backstop for the async
  /// window between the paste and the loaded providers.
  var acceptsPastedImages = true

  /// Line ceiling for `clampedHeight(forWidth:)` — parity with `.lineLimit(1 ... 6)`.
  var maxLines = 6

  /// Shown while the field is empty, mirroring the `TextField`'s `"Message"` prompt.
  let placeholderLabel = UILabel()

  /// Once the field is pinned at its six-line ceiling, growing the text changes **no** bounds,
  /// so nothing else would ask for another layout pass — and `updateScrollEnabled` lives in
  /// `layoutSubviews`. Without this the seventh line is simply unreachable: the field neither
  /// grows nor scrolls. (Typed edits don't go through this setter; the coordinator's
  /// `textViewDidChange` covers those.)
  override var text: String! {
    didSet { setNeedsLayout() }
  }

  override init(frame: CGRect, textContainer: NSTextContainer?) {
    super.init(frame: frame, textContainer: textContainer)
    // `.placeholderText`, not `.secondaryLabel`: this is the colour SwiftUI's `TextField`
    // prompt renders in (white α0.3 vs α0.6 in dark mode), and the snapshot baselines caught
    // the brighter label as a parity regression.
    placeholderLabel.textColor = .placeholderText
    placeholderLabel.adjustsFontForContentSizeCategory = true
    placeholderLabel.numberOfLines = 1
    placeholderLabel.isUserInteractionEnabled = false
    // The text view itself carries the label for VoiceOver (see `ComposerTextView`), so the
    // placeholder must not be a second element.
    placeholderLabel.isAccessibilityElement = false
    addSubview(placeholderLabel)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  /// Enables the **Paste** menu item whenever the clipboard carries an image; every other
  /// action (and a clipboard with no image) keeps the text view's stock verdict, so plain-text
  /// paste, Copy, Select All and friends are unaffected.
  ///
  /// `hasImages` is a metadata probe — it reveals no content and raises no *"Allow Paste"*
  /// banner, unlike reading `itemProviders` here would.
  override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
    if action == #selector(paste(_:)), acceptsPastedImages, pasteboard.hasImages { return true }
    return superCanPerformAction(action, withSender: sender)
  }

  /// Images → `onPasteImages`; everything else → `super` (stock insertion).
  ///
  /// "Everything else" is decided **per provider**, not per pasteboard: `super` is called only
  /// when at least one provider is not an image. A single item carrying both an image and a
  /// text representation — Safari's *Copy Image*, which bundles the page/image URL — is an
  /// image paste and nothing more, while a genuinely multi-item clipboard (an image item
  /// *and* a text item) still pastes its text.
  ///
  /// Known limitation of that rule: a producer that puts *genuine* prose in the same item as
  /// an image loses the prose. Distinguishing it from Safari's URL noise would mean reading
  /// and classifying the text payload, and getting it wrong types a stray URL into the user's
  /// message — the failure that rule was written to stop. The common case wins.
  ///
  /// Runs under the implicit pasteboard grant of the user tapping **Paste**, which is the only
  /// window in which the clipboard may be read without prompting — hence the read here rather
  /// than in a reducer effect.
  override func paste(_ sender: Any?) {
    // A text-only clipboard never even materialises its providers: byte-identical to the stock
    // text view, down to not reading the pasteboard's contents at all.
    guard acceptsPastedImages, pasteboard.hasImages else {
      pasteToSuper(sender)
      return
    }
    let providers = pasteboard.itemProviders
    let images = providers.filter {
      PickedImageLoader.imageTypeIdentifier(in: $0.registeredTypeIdentifiers) != nil
    }
    guard !images.isEmpty else {
      // `hasImages` said yes but nothing carries loadable image data: stock behaviour.
      pasteToSuper(sender)
      return
    }
    onPasteImages?(images)
    if providers.count > images.count { pasteToSuper(sender) }
  }

  /// The stock `UITextView` paste, behind an overridable seam so a test can record what the
  /// override forwards. Production behaviour is exactly `super.paste(sender)`.
  func pasteToSuper(_ sender: Any?) {
    super.paste(sender)
  }

  /// The stock `UITextView` verdict, behind an overridable seam for the same reason — and
  /// because `super`'s answer depends on `UIPasteboard.general`, which a test must not read.
  func superCanPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
    super.canPerformAction(action, withSender: sender)
  }

  /// Positioned by hand rather than with constraints: a `UITextView` is a scroll view, and
  /// edge constraints on a subview feed its content-size inference.
  override func layoutSubviews() {
    super.layoutSubviews()
    let padding = textContainer.lineFragmentPadding
    let left = textContainerInset.left + padding
    let width = max(0, bounds.width - left - textContainerInset.right - padding)
    let height = placeholderLabel.sizeThatFits(
      CGSize(width: width, height: .greatestFiniteMagnitude)
    ).height
    placeholderLabel.frame = CGRect(x: left, y: textContainerInset.top, width: width, height: height)
    updateScrollEnabled()
  }

  /// The height for `width`, clamped to one … `maxLines` lines — the
  /// `.lineLimit(1 ... 6)` growth of the `TextField` this replaced.
  ///
  /// **Pure measurement, no mutation.** It is called from SwiftUI's sizing pass, where
  /// assigning anything that invalidates layout (`isScrollEnabled` used to be assigned right
  /// here) can feed back into the very measurement being taken. Scrolling is switched on in
  /// `layoutSubviews` instead, where mutation is expected.
  func clampedHeight(forWidth width: CGFloat) -> CGFloat {
    let fitted = fittedHeight(forWidth: width)
    return ceil(min(max(fitted, lineHeight + chromeHeight), ceilingHeight))
  }

  /// The height at which the field stops growing and starts scrolling.
  var ceilingHeight: CGFloat { lineHeight * CGFloat(maxLines) + chromeHeight }

  /// One laid-out line. `font.lineHeight` alone is **not** it — TextKit adds the font's
  /// `leading` (17pt body: 20.29 + 1.71 = 22.0 exactly), and using the bare metric clamped the
  /// field at 5½ lines instead of the `.lineLimit(1 ... 6)` it is meant to match.
  private var lineHeight: CGFloat {
    let font = font ?? .preferredFont(forTextStyle: .body)
    return font.lineHeight + font.leading
  }

  private var chromeHeight: CGFloat { textContainerInset.top + textContainerInset.bottom }

  private func fittedHeight(forWidth width: CGFloat) -> CGFloat {
    sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
  }

  /// Scroll once the text outgrows the ceiling. Guarded on a real change: the setter
  /// invalidates layout, so an unconditional assignment would re-enter `layoutSubviews`
  /// forever instead of settling after one extra pass.
  private func updateScrollEnabled() {
    guard bounds.width > 0 else { return }
    let shouldScroll = fittedHeight(forWidth: bounds.width) > ceilingHeight + 0.5
    guard isScrollEnabled != shouldScroll else { return }
    isScrollEnabled = shouldScroll
    // Scrolling switches on with `contentOffset` still at the top, so the line that just
    // overflowed — the one holding the caret — sits below the visible area until the next
    // keystroke nudges it into view. Pin it here, on the flip only: the guard above makes
    // this a one-shot per transition, so a user who then scrolls up is never yanked back,
    // and the re-entrant `layoutSubviews` that `setContentOffset` triggers settles
    // immediately (the flag already matches).
    if shouldScroll { scrollRangeToVisible(selectedRange) }
  }
}

/// The composer's text input: a `UITextView`-backed replacement for
/// `TextField("Message", text:, axis: .vertical).lineLimit(1 ... 6)`, swapped in so a
/// clipboard image can be intercepted (#54). Everything else is deliberate parity — the
/// placeholder, 1–6 line growth, and the body font/clear background. The one departure is the
/// Return key, which inserts a newline rather than submitting (#70): sending is the send
/// button's job alone.
///
/// There is deliberately **no focus binding**: a representable gets no `.focused(_:)` — it
/// *is* the focusable view — so a `@FocusState` here would never latch and reading it would
/// only ever resign the keyboard (it did: the composer lost the keyboard after one
/// keystroke). The transcript dismisses the keyboard directly at the UIKit level, via
/// `CollectionTranscriptView`'s `keyboardDismissMode = .interactive`; a blocking card dismisses
/// it through ``blockingCardToken`` (below), for the same reason — UIKit is the only layer that
/// can.
struct ComposerTextView: UIViewRepresentable {
  @Binding var text: String
  var placeholder: String = "Message"
  /// Growth ceiling; the floor is always one line.
  var maxLines: Int = 6
  /// Capability gate (`!attachmentsUnsupported`): when the agent can't accept uploads, the
  /// field stops offering **Paste** for an image-only clipboard instead of accepting a
  /// gesture that could only be dropped. Text paste is unaffected.
  var attachmentsSupported: Bool = true
  /// Identity of the blocking card standing over the chat (`ChatFeature.State`'s
  /// `pendingInteractionToken` while `pendingInteraction != nil`), or `nil` when none is.
  ///
  /// Raising one drops the keyboard: the card is the focal point, `canSend` is false while it
  /// stands, and the keyboard costs it roughly half the screen — the card lives in the
  /// non-scrolling region between the transcript and this field, which is exactly what the
  /// keyboard shrinks. That is #65's own root cause: leaving and re-entering the chat "fixed"
  /// the truncated command because the keyboard was down on the way back in.
  ///
  /// **Resign, not disable.** The field stays live and editable, so a user who deliberately
  /// taps it can still draft their next message while they think about the card (the card's
  /// bounded region absorbs the keyboard coming back — that is what it is built for).
  /// *Live* means typing, not sending: Return only ever inserts a newline (#70), and Send is
  /// disabled by `canSend` (false on any `pendingInteraction`), so a draft written under a
  /// card cannot escape it. It fires
  /// once per *raised card*, keyed on the token rather than on `nil`-ness, so a replacement
  /// card drops the keyboard too and a re-focus is never fought over: `ChatView` re-renders on
  /// every streamed token, and an unkeyed "resign while blocked" would resign again on each one,
  /// making the field untappable in all but name.
  var blockingCardToken: Int?
  /// Fired **synchronously** the moment a paste is claimed, before its providers have loaded.
  ///
  /// The load is asynchronous and, unlike a picker's, has no modal sheet covering it — the user
  /// is left looking at a composer that already holds their typed text and can hit Send during
  /// the window. The reducer uses this to hold `canSend` down until the matching
  /// `onPasteImages` lands, so the message cannot go out without the image it was meant to
  /// carry (which would then reappear, orphaned, in the next draft).
  var onPasteBegan: () -> Void = {}
  /// Images pasted into the field, already loaded — with a count of any that were lost on the
  /// way, exactly as a picker reports them.
  var onPasteImages: (PickedBatch) -> Void = { _ in }

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeUIView(context: Context) -> ComposerInputTextView {
    let view = ComposerInputTextView()
    view.delegate = context.coordinator
    view.font = .preferredFont(forTextStyle: .body)
    view.adjustsFontForContentSizeCategory = true
    view.textColor = .label
    view.backgroundColor = .clear
    view.textContainerInset = .zero
    view.textContainer.lineFragmentPadding = 0
    view.isScrollEnabled = false
    view.placeholderLabel.font = .preferredFont(forTextStyle: .body)
    // Input traits (autocorrect / capitalisation / smart punctuation) are left at their
    // defaults — the same ones the `TextField` used. Parity, not a behaviour change.
    view.setContentCompressionResistancePriority(.required, for: .vertical)
    view.setContentHuggingPriority(.required, for: .vertical)
    view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    view.onPasteImages = { [coordinator = context.coordinator] providers in
      coordinator.loadPastedImages(providers)
    }
    apply(to: view)
    dropFocusIfACardWasJustRaised(on: view, context.coordinator)
    return view
  }

  func updateUIView(_ view: ComposerInputTextView, context: Context) {
    context.coordinator.parent = self
    apply(to: view)
    dropFocusIfACardWasJustRaised(on: view, context.coordinator)
  }

  /// See ``blockingCardToken``. The edge decision lives in the coordinator (it is the only
  /// thing that survives a re-render); the responder call stays here.
  private func dropFocusIfACardWasJustRaised(
    on view: ComposerInputTextView, _ coordinator: Coordinator
  ) {
    guard coordinator.shouldDropFocus(for: blockingCardToken), view.isFirstResponder else {
      return
    }
    view.resignFirstResponder()
  }

  func sizeThatFits(
    _ proposal: ProposedViewSize,
    uiView: ComposerInputTextView,
    context: Context
  ) -> CGSize? {
    guard let width = proposal.width, width > 0, width < .greatestFiniteMagnitude else {
      return nil
    }
    return CGSize(width: width, height: uiView.clampedHeight(forWidth: width))
  }

  /// Everything the representable pushes into the UIKit view. Internal so a test can pin the
  /// wiring (the capability gate and the caret especially) without a hosting controller.
  func apply(to view: ComposerInputTextView) {
    // Follow the in-app text size: the window trait override reaches `traitCollection`, but a
    // font built from the app-wide setting would not.
    let bodyFont = UIFont.preferredFont(forTextStyle: .body, compatibleWith: view.traitCollection)
    if view.font != bodyFont {
      view.font = bodyFont
      view.placeholderLabel.font = bodyFont
      view.setNeedsLayout()
    }
    if view.text != text {
      // Only a *programmatic* change reaches here — typing arrives through the delegate, which
      // leaves the two already in sync — and every such change appends: a slash-suggestion tap
      // (`"/cmd "`), `/undo`'s prefill, the clear on submit. `UITextView.text` leaves the caret
      // wherever UIKit decides, so pin it after the inserted text: the user types arguments next.
      view.text = text
      view.selectedRange = NSRange(location: (text as NSString).length, length: 0)
    }
    view.maxLines = maxLines
    view.acceptsPastedImages = attachmentsSupported
    view.placeholderLabel.text = placeholder
    view.placeholderLabel.isHidden = !view.text.isEmpty
    // A `UITextField`-style label: VoiceOver announces the prompt and reads the typed text
    // as the element's value.
    view.accessibilityLabel = placeholder
  }

  @MainActor
  final class Coordinator: NSObject, UITextViewDelegate {
    private static let log = Logger(subsystem: "me.honcharenko.HermesMobile", category: "composer")

    var parent: ComposerTextView
    /// Chains the per-paste loads so two fast pastes stage their chips in paste order rather
    /// than in whichever order the providers happen to finish loading. Safe to wait on
    /// unconditionally because every load is deadline-bounded (`PickedImageLoader.clipboardLoadTimeout`)
    /// — a provider that never calls back can delay the next paste, never wedge it.
    private var pendingLoad: Task<Void, Never>?
    /// Identifies the newest chained load, so a finishing task only clears `pendingLoad` when
    /// nothing has queued behind it.
    private var loadGeneration = 0
    /// The blocking card this composer has already yielded the keyboard to — see
    /// ``ComposerTextView/blockingCardToken``.
    private var lastBlockingCardToken: Int?

    init(_ parent: ComposerTextView) { self.parent = parent }

    /// Should the field give up the keyboard right now? True exactly once per raised card:
    /// on the card that is standing when the view is made, and on every *later* card whose
    /// token differs — including a replacement that never passes through `nil` (a queued
    /// approval, a second secret prompt). False for every re-render in between, so a user who
    /// taps the field back into focus while a card stands keeps it. Consuming (it records the
    /// token it was asked about), so it must be called once per update pass.
    func shouldDropFocus(for token: Int?) -> Bool {
      defer { lastBlockingCardToken = token }
      guard let token else { return false }
      return token != lastBlockingCardToken
    }

    func textViewDidChange(_ textView: UITextView) {
      parent.text = textView.text
      (textView as? ComposerInputTextView)?.placeholderLabel.isHidden = !textView.text.isEmpty
      // At the six-line ceiling the frame stops changing, so a typed line 6 → 7 would leave
      // `layoutSubviews` — and with it the scroll flip — unrun, stranding the new text out of
      // view. (A programmatic set is covered by the `text` observer.)
      textView.setNeedsLayout()
    }

    /// Load the pasted providers' original bytes **asynchronously** — the loader is
    /// `@MainActor` (`NSItemProvider` is not `Sendable`) but every wait is a suspension, so the
    /// paste returns immediately and the finished `PickedItem`s are handed up later. The load
    /// happens here rather than in a reducer effect: the pasteboard grant is scoped to the
    /// paste command, and `NSItemProvider` is neither `Sendable` nor `Equatable`, so it cannot
    /// ride in a TCA action.
    func loadPastedImages(_ providers: [NSItemProvider]) {
      // Announced before the first suspension point, so there is no window in which the paste
      // is under way and the reducer does not know it.
      parent.onPasteBegan()
      let previous = pendingLoad
      loadGeneration += 1
      let generation = loadGeneration
      // Captures `self` strongly on purpose: the load has to finish (and deliver) even if
      // SwiftUI has already moved on from this coordinator. Delivery is unconditional — every
      // load is deadline-bounded — which is what lets the reducer treat `onPasteBegan` /
      // `onPasteImages` as a balanced pair rather than a flag that can leak.
      pendingLoad = Task { @MainActor in
        await previous?.value
        let batch = await PickedImageLoader.pickedItems(
          from: providers,
          fallbackName: "pasted-image",
          // Passed explicitly even though it is the default: the budget is per source (the
          // picker's is minutes, for its iCloud download), so which one this path takes
          // belongs at the call site rather than in whatever the default happens to be.
          timeout: PickedImageLoader.clipboardLoadTimeout
        )
        if generation == loadGeneration { pendingLoad = nil }
        if batch.droppedCount > 0 {
          // The menu promised a paste (the clipboard *did* carry an image) and some or all of
          // it never arrived — an expired Universal Clipboard item, an exotic type that could
          // not be re-encoded. `PickedImageLoader` logs the cause; the count is what lets the
          // reducer tell the user, instead of leaving a requested gesture silently partial.
          Self.log.error(
            "paste of \(providers.count) image provider(s) lost \(batch.droppedCount) of them"
          )
        }
        parent.onPasteImages(batch)
      }
    }
  }
}
