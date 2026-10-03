import HermesKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import XCTest

@testable import HermesMobile

/// The composer's UIKit input (#54): paste routing, the representable's wiring, and the
/// `TextField` parity the swap had to reproduce.
///
/// The gesture itself can't be unit-tested (that's the simulator pass), but the two hooks it
/// depends on can: `canPerformAction(_:withSender:)` — which is what makes iOS *enable*
/// **Paste** for an image-only clipboard — and `paste(_:)`, which must divert images to the
/// attachment callback while leaving everything else to `UITextView`'s stock handling.
///
/// Every case drives a `UIPasteboard.withUniqueName()` through the view's `pasteboard` seam.
/// Where stock behaviour matters the assertion is on **delegation** (the `pasteToSuper` /
/// `superCanPerformAction` seams), never on `super`'s answer: `super` always consults
/// `UIPasteboard.general`, so comparing verdicts would make the suite depend on whatever the
/// simulator's clipboard happens to hold.
@MainActor
final class ComposerTextViewTests: XCTestCase {
  // MARK: - Fixtures

  /// Records what the overrides hand back to `UITextView` instead of actually doing it — a
  /// subclass can't observe its superclass's own `super` call, and `super`'s behaviour is
  /// pinned to the general pasteboard, which the suite must not touch.
  private final class SpyTextView: ComposerInputTextView {
    private(set) var forwardedToSuper = 0
    private(set) var delegatedActions: [Selector] = []
    /// What the stubbed stock verdict returns; the tests only care *that* it was consulted.
    var stockVerdict = false

    override func pasteToSuper(_ sender: Any?) {
      forwardedToSuper += 1
    }

    override func superCanPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
      delegatedActions.append(action)
      return stockVerdict
    }
  }

  private var pasteboard: UIPasteboard!

  override func setUp() {
    super.setUp()
    pasteboard = UIPasteboard.withUniqueName()
  }

  override func tearDown() {
    UIPasteboard.remove(withName: pasteboard.name)
    pasteboard = nil
    super.tearDown()
  }

  private static let pngBytes = Data([0x89, 0x50, 0x4E, 0x47])
  private static let jpegBytes = Data([0xFF, 0xD8, 0xFF, 0xE0])

  private func stageImage(_ type: UTType = .png, bytes: Data = pngBytes) {
    pasteboard.items = [[type.identifier: bytes]]
  }

  private func stageText(_ text: String = "hello") {
    pasteboard.items = [[UTType.utf8PlainText.identifier: Data(text.utf8)]]
  }

  /// One item carrying *both* an image and a text representation — what Safari's *Copy Image*
  /// (image plus the page/image URL) actually puts on the clipboard.
  private func stageImageAndText(_ text: String = "hello") {
    pasteboard.items = [[
      UTType.png.identifier: Self.pngBytes,
      UTType.utf8PlainText.identifier: Data(text.utf8),
    ]]
  }

  /// Two separate items: an image *and* a text item. A genuinely mixed clipboard.
  private func stageSeparateImageAndTextItems(_ text: String = "hello") {
    pasteboard.items = [
      [UTType.png.identifier: Self.pngBytes],
      [UTType.utf8PlainText.identifier: Data(text.utf8)],
    ]
  }

  /// Captures whatever the view hands to `onPasteImages`, in order.
  private func makeView() -> (SpyTextView, Recorder<[NSItemProvider]>) {
    let view = SpyTextView()
    view.pasteboard = pasteboard
    let recorder = Recorder<[NSItemProvider]>()
    view.onPasteImages = { recorder.values.append($0) }
    return (view, recorder)
  }

  /// A provider that hands back `bytes` as a PNG — what `UIPasteboard.itemProviders` yields
  /// for a copied screenshot, and what the coordinator has to turn into a `PickedItem`.
  private func pngProvider(_ bytes: Data = pngBytes) -> NSItemProvider {
    let provider = NSItemProvider()
    provider.registerDataRepresentation(for: .png, visibility: .all) { completion in
      completion(bytes, nil)
      return nil
    }
    return provider
  }

  /// A provider that advertises an image but always fails to load it — the dropped-item path.
  private func failingPNGProvider() -> NSItemProvider {
    let provider = NSItemProvider()
    provider.registerDataRepresentation(for: .png, visibility: .all) { completion in
      completion(nil, CocoaError(.fileReadUnknown))
      return nil
    }
    return provider
  }

  /// A `ComposerTextView` whose `onPasteImages` result is reported to `onItems`, with an
  /// optional hook on the synchronous "a paste has started" announcement that precedes it.
  private func makeComposer(
    attachmentsSupported: Bool = true,
    onBegan: @escaping () -> Void = {},
    onItems: @escaping (PickedBatch) -> Void
  ) -> ComposerTextView {
    ComposerTextView(
      text: .constant(""),
      attachmentsSupported: attachmentsSupported,
      onPasteBegan: onBegan,
      onPasteImages: onItems
    )
  }

  private final class Recorder<Value> {
    var values: [Value] = []
  }

  /// A bare text view configured the way `makeUIView` configures it — the only parts that
  /// affect measurement (body font, no insets, no fragment padding, growth mode). Every
  /// line-growth, scroll-flip and caret test measures against these exact metrics.
  private func makeMeasuringView() -> ComposerInputTextView {
    let view = ComposerInputTextView()
    view.font = .preferredFont(forTextStyle: .body)
    view.textContainerInset = .zero
    view.textContainer.lineFragmentPadding = 0
    view.isScrollEnabled = false
    return view
  }

  /// The width every measuring test lays out at.
  private let measuringWidth: CGFloat = 240

  private var pasteAction: Selector { #selector(UIResponderStandardEditActions.paste(_:)) }

  // MARK: - canPerformAction

  /// The load-bearing half: without this the long-press menu offers no **Paste** at all for an
  /// image-only clipboard (verified in the simulator — see the Task 8 notes). UIKit is not
  /// even consulted, so the claim can't be undone by the stock verdict.
  func testCanPerformPasteIsTrueForAnImageClipboard() {
    let (view, _) = makeView()

    stageImage()
    XCTAssertTrue(view.canPerformAction(pasteAction, withSender: nil))

    stageImage(.jpeg, bytes: Self.jpegBytes)
    XCTAssertTrue(view.canPerformAction(pasteAction, withSender: nil))

    // One image alongside text is still enough to offer Paste.
    stageImageAndText()
    XCTAssertTrue(view.canPerformAction(pasteAction, withSender: nil))

    XCTAssertTrue(view.delegatedActions.isEmpty, "an image clipboard is claimed outright")
  }

  /// A clipboard with no image is left to UIKit — claiming `paste(_:)` unconditionally would
  /// offer **Paste** on an empty clipboard, and a hard `false` would grey it out for plain
  /// text, the common case.
  func testCanPerformPasteLeavesANonImageClipboardToStockBehaviour() {
    let (view, _) = makeView()

    stageText()
    view.stockVerdict = true
    XCTAssertTrue(view.canPerformAction(pasteAction, withSender: nil))

    pasteboard.items = []
    view.stockVerdict = false
    XCTAssertFalse(view.canPerformAction(pasteAction, withSender: nil))

    XCTAssertEqual(view.delegatedActions, [pasteAction, pasteAction])
  }

  /// Only `paste(_:)` is claimed; every other edit action is still UIKit's call even while an
  /// image sits on the clipboard.
  func testOtherEditActionsAreUnaffectedByAnImageClipboard() {
    let (view, _) = makeView()
    stageImage()

    let actions = [
      #selector(UIResponderStandardEditActions.copy(_:)),
      #selector(UIResponderStandardEditActions.cut(_:)),
      #selector(UIResponderStandardEditActions.selectAll(_:)),
    ]
    for action in actions { _ = view.canPerformAction(action, withSender: nil) }

    XCTAssertEqual(view.delegatedActions, actions, "every other action must reach UIKit")
  }

  // MARK: - paste(_:)

  func testPastingAnImageDivertsItToTheCallbackAndLeavesTheTextUntouched() {
    let (view, calls) = makeView()
    view.text = "draft"
    stageImage()

    view.paste(nil)

    XCTAssertEqual(calls.values.count, 1)
    XCTAssertEqual(calls.values.first?.count, 1)
    XCTAssertTrue(
      calls.values.first?.first?.hasItemConformingToTypeIdentifier(UTType.png.identifier) == true
    )
    XCTAssertEqual(view.text, "draft", "the image must never enter the text buffer")
    XCTAssertEqual(view.forwardedToSuper, 0, "an image-only paste has nothing to forward")
  }

  /// Safari's *Copy Image* is one item carrying both the image and the page URL as text. It is
  /// an image paste and nothing more — the URL must not land in the user's message.
  func testASingleItemCarryingImageAndTextPastesOnlyTheImage() {
    let (view, calls) = makeView()
    stageImageAndText("https://example.com/cat.png")

    view.paste(nil)

    XCTAssertEqual(calls.values.count, 1)
    XCTAssertEqual(calls.values.first?.count, 1)
    XCTAssertEqual(view.forwardedToSuper, 0, "no provider is left over for stock handling")
  }

  /// A genuinely multi-item clipboard (an image item *and* a text item) still pastes its text.
  func testASeparateTextItemAlongsideAnImageStillPastes() {
    let (view, calls) = makeView()
    stageSeparateImageAndTextItems("before")

    view.paste(nil)

    XCTAssertEqual(calls.values.count, 1)
    XCTAssertEqual(calls.values.first?.count, 1)
    XCTAssertEqual(view.forwardedToSuper, 1, "the text item is left to stock handling, once")
  }

  /// The non-image half is decided per provider, not by `hasStrings`: an image beside a PDF
  /// still reaches `super` (which, for a plain-text `UITextView`, does nothing).
  func testANonImageItemWithoutTextIsStillForwardedToSuper() {
    let (view, calls) = makeView()
    pasteboard.items = [
      [UTType.png.identifier: Self.pngBytes],
      [UTType.pdf.identifier: Data([0x25, 0x50, 0x44, 0x46])],
    ]

    view.paste(nil)

    XCTAssertEqual(calls.values.first?.count, 1, "only the image is staged")
    XCTAssertEqual(view.forwardedToSuper, 1)
  }

  func testMultipleImagesReachTheCallbackInClipboardOrder() {
    let (view, calls) = makeView()
    pasteboard.items = [
      [UTType.png.identifier: Self.pngBytes],
      [UTType.jpeg.identifier: Self.jpegBytes],
    ]

    view.paste(nil)

    XCTAssertEqual(calls.values.count, 1)
    XCTAssertEqual(calls.values.first?.count, 2)
    XCTAssertTrue(
      calls.values.first?.first?.hasItemConformingToTypeIdentifier(UTType.png.identifier) == true
    )
    XCTAssertTrue(
      calls.values.first?.last?.hasItemConformingToTypeIdentifier(UTType.jpeg.identifier) == true
    )
    XCTAssertEqual(view.forwardedToSuper, 0)
  }

  func testAClipboardWithoutAnImageNeverReachesTheCallback() {
    let (view, calls) = makeView()
    stageText()

    view.paste(nil)

    XCTAssertTrue(calls.values.isEmpty, "no image on the clipboard → no attachment callback")
    XCTAssertEqual(view.forwardedToSuper, 1, "text still pastes, stock")
  }

  /// Scope is **images only** (#54): a PDF on the clipboard is not an attachment, even though
  /// `ComposerAttachment.Kind` could carry one. It stays stock text-view behaviour.
  func testAPDFClipboardIsNotStagedAsAnAttachment() {
    let (view, calls) = makeView()
    pasteboard.items = [[UTType.pdf.identifier: Data([0x25, 0x50, 0x44, 0x46])]]

    _ = view.canPerformAction(pasteAction, withSender: nil)
    view.paste(nil)

    XCTAssertEqual(view.delegatedActions, [pasteAction], "a PDF clipboard is never claimed")
    XCTAssertTrue(calls.values.isEmpty)
    XCTAssertEqual(view.forwardedToSuper, 1)
  }

  func testPastingAnEmptyClipboardIsStockBehaviour() {
    let (view, calls) = makeView()
    pasteboard.items = []

    view.paste(nil)

    XCTAssertTrue(calls.values.isEmpty)
    // Nothing to divert → the stock text view decides (and does nothing).
    XCTAssertEqual(view.forwardedToSuper, 1)
  }

  // MARK: - attachmentsUnsupported

  /// Same capability gate as the paperclip: when the agent can't accept uploads the field must
  /// not claim **Paste** for an image-only clipboard, or iOS offers a menu item whose only
  /// possible outcome is the reducer silently dropping it.
  func testAnImageClipboardKeepsTheStockVerdictWhenAttachmentsAreUnsupported() {
    let (view, _) = makeView()
    view.acceptsPastedImages = false

    stageImage()
    _ = view.canPerformAction(pasteAction, withSender: nil)
    // Text is untouched by the gate — it was never ours to claim.
    stageText()
    _ = view.canPerformAction(pasteAction, withSender: nil)

    XCTAssertEqual(view.delegatedActions, [pasteAction, pasteAction])
  }

  func testPastingAnImageStagesNothingWhenAttachmentsAreUnsupported() {
    let (view, calls) = makeView()
    view.acceptsPastedImages = false
    stageImage()

    view.paste(nil)

    XCTAssertTrue(calls.values.isEmpty, "no attach capability → no chip")
    XCTAssertEqual(view.forwardedToSuper, 1, "byte-identical to a stock text view")
  }

  func testAMixedClipboardStillPastesItsTextWhenAttachmentsAreUnsupported() {
    let (view, calls) = makeView()
    view.acceptsPastedImages = false
    stageImageAndText("still typed")

    view.paste(nil)

    XCTAssertTrue(calls.values.isEmpty)
    XCTAssertEqual(view.forwardedToSuper, 1, "the text half must not regress")
  }

  // MARK: - Providers → PickedItems

  /// The coordinator hop the reducer tests can't see: clipboard providers become `PickedItem`s
  /// named with the composer's `"pasted-image"` fallback, in order, with their original bytes.
  func testPastedProvidersBecomePickedItemsWithTheComposersNaming() async {
    let received = expectation(description: "onPasteImages")
    let box = Recorder<[PickedItem]>()
    let composer = makeComposer { batch in
      box.values.append(batch.items)
      received.fulfill()
    }
    let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D])
    let second = Data([0x89, 0x50, 0x4E, 0x47, 0x1A])

    composer.makeCoordinator().loadPastedImages([pngProvider(png), pngProvider(second)])
    await fulfillment(of: [received], timeout: 2)

    let items = box.values.first ?? []
    XCTAssertEqual(items.map(\.filename), ["pasted-image.png", "pasted-image-2.png"])
    XCTAssertEqual(items.map(\.data), [png, second])
    XCTAssertEqual(items.map(\.mimeType), ["image/png", "image/png"])
    XCTAssertEqual(items.map(\.kind), [.image, .image])
  }

  /// A provider that advertises an image but fails to load it must not reach the store: an
  /// empty `attachmentsPasted` is a no-op action, and firing one would still be a lie. The
  /// good provider alongside it is the positive control — without it, a dead load path would
  /// pass this test too.
  func testProvidersThatFailToLoadAreDroppedWithoutLosingTheGoodOnes() async {
    let received = expectation(description: "onPasteImages")
    let box = Recorder<PickedBatch>()
    let composer = makeComposer { batch in
      box.values.append(batch)
      received.fulfill()
    }
    let good = Data([0x89, 0x50, 0x4E, 0x47, 0x2B])

    composer.makeCoordinator().loadPastedImages([failingPNGProvider(), pngProvider(good)])
    await fulfillment(of: [received], timeout: 2)

    XCTAssertEqual(box.values.first?.items.map(\.data), [good])
    // No `-2` gap: the dropped provider does not consume a filename index.
    XCTAssertEqual(box.values.first?.items.map(\.filename), ["pasted-image.png"])
    // …and the loss rides along, so the reducer can say two of three never arrived rather
    // than staging a quietly incomplete set.
    XCTAssertEqual(box.values.first?.droppedCount, 1)
  }

  /// A paste that yields nothing at all still reaches the callback, empty. iOS offered
  /// **Paste** (the clipboard did carry an image) and the user tapped it; the reducer turns the
  /// empty batch into a banner, which is the only thing standing between that gesture and a
  /// completely silent dead end.
  func testAPasteThatLoadsNothingStillReportsAnEmptyBatch() async {
    let received = expectation(description: "onPasteImages")
    let box = Recorder<PickedBatch>()
    let composer = makeComposer { batch in
      box.values.append(batch)
      received.fulfill()
    }

    composer.makeCoordinator().loadPastedImages([failingPNGProvider()])
    await fulfillment(of: [received], timeout: 2)

    XCTAssertEqual(box.values.count, 1)
    XCTAssertEqual(box.values.first?.items.isEmpty, true)
    XCTAssertEqual(box.values.first?.droppedCount, 1)
  }

  /// Two pastes in quick succession stage in paste order, and the second is not held hostage
  /// by the first: every load is deadline-bounded, so a provider that never calls back can
  /// delay the next paste but never wedge it.
  func testConsecutivePastesDeliverInOrderAndTheQueueDrains() async {
    let received = expectation(description: "onPasteImages")
    received.expectedFulfillmentCount = 2
    let box = Recorder<[PickedItem]>()
    let composer = makeComposer { batch in
      box.values.append(batch.items)
      received.fulfill()
    }
    let coordinator = composer.makeCoordinator()
    let first = Data([0x89, 0x50, 0x4E, 0x47, 0x01])
    let second = Data([0x89, 0x50, 0x4E, 0x47, 0x02])

    coordinator.loadPastedImages([pngProvider(first)])
    coordinator.loadPastedImages([pngProvider(second)])
    await fulfillment(of: [received], timeout: 5)

    XCTAssertEqual(box.values.map { $0.map(\.data) }, [[first], [second]])
  }

  /// The paste announces itself **before** its first suspension point, so there is no window
  /// in which a load is under way and the reducer does not know it — that window is exactly
  /// where a Send would ship the message without the image it was pasted to carry. And it is
  /// announced once per paste, matching the one batch that always follows.
  func testAPasteAnnouncesItselfSynchronouslyBeforeTheBatchArrives() async {
    let received = expectation(description: "onPasteImages")
    let began = Recorder<Int>()
    let box = Recorder<PickedBatch>()
    let composer = makeComposer {
      began.values.append(box.values.count)
    } onItems: { batch in
      box.values.append(batch)
      received.fulfill()
    }

    composer.makeCoordinator().loadPastedImages([pngProvider()])
    // Synchronously — no awaiting, no run-loop turn.
    XCTAssertEqual(began.values, [0], "announced once, before anything was delivered")

    await fulfillment(of: [received], timeout: 2)
    XCTAssertEqual(began.values.count, 1, "one announcement per paste")
    XCTAssertEqual(box.values.count, 1, "and exactly one batch closes it")
  }

  // MARK: - Representable wiring

  /// The plumbing between the SwiftUI layer and the UIKit view. Without this the capability
  /// gate could be disconnected in `apply(to:)` and every other test would still pass — they
  /// all set `acceptsPastedImages` on the UIKit view by hand.
  func testTheRepresentableConfiguresTheTextView() {
    let composer = ComposerTextView(
      text: .constant("typed"),
      placeholder: "Message",
      maxLines: 4,
      attachmentsSupported: false
    )
    let view = ComposerInputTextView()
    view.text = "typed"

    composer.apply(to: view)

    XCTAssertFalse(view.acceptsPastedImages, "attachmentsSupported must reach the paste gate")
    XCTAssertEqual(view.maxLines, 4)
    XCTAssertEqual(view.placeholderLabel.text, "Message")
    XCTAssertTrue(view.placeholderLabel.isHidden, "a non-empty field hides the prompt")
    XCTAssertEqual(view.accessibilityLabel, "Message")
  }

  /// End to end through SwiftUI: hosting the representable must produce a text view whose
  /// paste hook actually reaches `onPasteImages`, with the defaults intact.
  func testHostingTheRepresentableWiresThePasteCallback() async {
    let received = expectation(description: "onPasteImages")
    let box = Recorder<[PickedItem]>()
    let composer = makeComposer { batch in
      box.values.append(batch.items)
      received.fulfill()
    }
    let host = UIHostingController(rootView: composer)
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
    window.rootViewController = host
    window.isHidden = false
    window.layoutIfNeeded()

    guard let field = Self.firstTextView(in: host.view) else {
      return XCTFail("the representable produced no ComposerInputTextView")
    }
    XCTAssertTrue(field.acceptsPastedImages)
    XCTAssertEqual(field.maxLines, 6, "the 1…6 default has to survive the hop")
    XCTAssertEqual(field.placeholderLabel.text, "Message")

    // Drive the hook `makeUIView` installed. (The providers are built here rather than taken
    // from a `UIPasteboard`: a named board's providers can't materialise in the test host, and
    // `paste(_:)`'s own routing is covered above.)
    XCTAssertNotNil(field.onPasteImages, "makeUIView must install the paste hook")
    field.onPasteImages?([pngProvider(Data([0x89, 0x50, 0x4E, 0x47, 0x3C]))])

    await fulfillment(of: [received], timeout: 2)
    XCTAssertEqual(box.values.first?.map(\.filename), ["pasted-image.png"])
  }

  // MARK: - Blocking cards and the keyboard

  /// The edge rule behind ``ComposerTextView/blockingCardToken`` (#65): the field gives up the
  /// keyboard once per *raised card*, never on the re-renders in between.
  ///
  /// Both halves matter. Resigning on the raise is the point — the card lives in the fixed
  /// region the keyboard shrinks, and it cannot be answered from the composer anyway. Not
  /// resigning in between is what keeps the field usable: `ChatView` re-renders on every
  /// streamed token, so an unkeyed "resign while a card stands" fires on each one and a user
  /// who taps the field is bounced out of it before they can type.
  func testTheKeyboardIsHandedBackOncePerRaisedCard() {
    let coordinator = ComposerTextView(text: .constant("")).makeCoordinator()

    XCTAssertFalse(coordinator.shouldDropFocus(for: nil), "no card, no reason to touch focus")
    XCTAssertTrue(coordinator.shouldDropFocus(for: 1), "a raised card hands the keyboard back")
    XCTAssertFalse(
      coordinator.shouldDropFocus(for: 1), "…and the re-renders under it leave focus alone")
    XCTAssertFalse(coordinator.shouldDropFocus(for: 1))
    XCTAssertTrue(
      coordinator.shouldDropFocus(for: 2),
      "a replacement card — which never passes through nil — hands it back again")
    XCTAssertFalse(coordinator.shouldDropFocus(for: nil), "answering the card is not a reason to")
    XCTAssertTrue(coordinator.shouldDropFocus(for: 3), "…and the next card is")
  }

  /// The same rule through the representable: a card standing at `makeUIView` time is consumed
  /// there, so a field the user focuses afterwards keeps focus.
  func testACardStandingWhenTheFieldIsMadeDoesNotFightALaterFocus() {
    let host = UIHostingController(
      rootView: ComposerTextView(text: .constant(""), blockingCardToken: 7))
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
    window.rootViewController = host
    window.makeKeyAndVisible()
    window.layoutIfNeeded()
    defer {
      window.isHidden = true
      window.rootViewController = nil
    }

    guard let field = Self.firstTextView(in: host.view) else {
      return XCTFail("the representable produced no ComposerInputTextView")
    }
    XCTAssertTrue(field.becomeFirstResponder(), "the field must stay focusable while a card stands")
    XCTAssertTrue(field.isEditable, "…and editable: the card blocks Send, not drafting")
    // The standing card's identity was consumed when the view was made, so nothing re-resigns.
    host.view.setNeedsLayout()
    host.view.layoutIfNeeded()
    XCTAssertTrue(field.isFirstResponder)
  }

  /// D1: an approval/clarify card blocks Send, never drafting — typing, Return-as-newline and
  /// the paste offer all keep working while the card's token stands.
  func testDraftEditingReturnAndPasteKeepWorkingWhileACardStands() {
    let writes = Recorder<String>()
    let composer = ComposerTextView(
      text: Binding(get: { writes.values.last ?? "" }, set: { writes.values.append($0) }),
      blockingCardToken: 3
    )
    let host = UIHostingController(rootView: composer)
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
    window.rootViewController = host
    window.makeKeyAndVisible()
    window.layoutIfNeeded()
    defer {
      window.isHidden = true
      window.rootViewController = nil
    }
    guard let field = Self.firstTextView(in: host.view) else {
      return XCTFail("the representable produced no ComposerInputTextView")
    }
    XCTAssertTrue(field.becomeFirstResponder())
    XCTAssertTrue(field.isEditable)
    field.insertText("fix")
    field.insertText("\n")
    field.insertText("later")
    XCTAssertEqual(field.text, "fix\nlater", "Return is a newline even with a card standing")
    XCTAssertEqual(writes.values.last, "fix\nlater", "edits reach the binding under the card")
    XCTAssertTrue(field.isFirstResponder, "re-renders under the same card don't drop focus")
    UIPasteboard.general.string = "pasted"
    XCTAssertTrue(
      field.canPerformAction(#selector(UIResponderStandardEditActions.paste(_:)), withSender: nil),
      "stock text paste stays offered while a card stands")
  }

  private static func firstTextView(in view: UIView) -> ComposerInputTextView? {
    if let hit = view as? ComposerInputTextView { return hit }
    for subview in view.subviews {
      if let hit = firstTextView(in: subview) { return hit }
    }
    return nil
  }

  // MARK: - Text binding & placeholder

  /// The composer's primary function: every keystroke writes back through the binding, and the
  /// prompt follows the text.
  func testTypingWritesBackThroughTheBindingAndHidesThePlaceholder() {
    let writes = Recorder<String>()
    let composer = ComposerTextView(
      text: Binding(get: { writes.values.last ?? "" }, set: { writes.values.append($0) })
    )
    let coordinator = composer.makeCoordinator()
    let view = ComposerInputTextView()
    composer.apply(to: view)
    XCTAssertFalse(view.placeholderLabel.isHidden, "an empty field shows the prompt")

    view.text = "h"
    coordinator.textViewDidChange(view)
    XCTAssertTrue(view.placeholderLabel.isHidden)

    view.text = ""
    coordinator.textViewDidChange(view)
    XCTAssertFalse(view.placeholderLabel.isHidden, "clearing the field brings the prompt back")

    XCTAssertEqual(writes.values, ["h", ""], "every keystroke reaches the binding")
  }

  /// A programmatic text change (the slash-suggestion tap, `/undo`'s prefill) has to leave the
  /// caret after the inserted text — `UITextView.text` does not guarantee it, and the user's
  /// next keystroke is the command's arguments.
  func testAProgrammaticTextChangeLeavesTheCaretAtTheEnd() {
    let composer = ComposerTextView(text: .constant("/branch "))
    let view = ComposerInputTextView()

    composer.apply(to: view)

    XCTAssertEqual(view.text, "/branch ")
    XCTAssertEqual(view.selectedRange, NSRange(location: 8, length: 0))

    // An update that changes nothing must not move a caret the user placed.
    view.selectedRange = NSRange(location: 2, length: 0)
    composer.apply(to: view)
    XCTAssertEqual(view.selectedRange, NSRange(location: 2, length: 0))
  }

  // MARK: - Line growth

  /// Parity with `.lineLimit(1 ... 6)`: one line minimum, six lines maximum, and internal
  /// scrolling only once the ceiling is reached.
  func testTheFieldGrowsBetweenOneAndSixLines() {
    let view = makeMeasuringView()
    let width = measuringWidth
    // What TextKit actually lays a line out at — `font.lineHeight` alone omits the leading.
    let body = UIFont.preferredFont(forTextStyle: .body)
    let lineHeight = body.lineHeight + body.leading

    view.text = ""
    XCTAssertEqual(view.clampedHeight(forWidth: width), ceil(lineHeight), accuracy: 0.5)

    view.text = "one\ntwo\nthree"
    XCTAssertEqual(view.clampedHeight(forWidth: width), ceil(lineHeight * 3), accuracy: 0.5)

    // Six full lines fit; anything longer stops there.
    view.text = Array(repeating: "line", count: 6).joined(separator: "\n")
    XCTAssertEqual(view.clampedHeight(forWidth: width), ceil(lineHeight * 6), accuracy: 0.5)
    view.text = Array(repeating: "line", count: 30).joined(separator: "\n")
    XCTAssertEqual(view.clampedHeight(forWidth: width), ceil(lineHeight * 6), accuracy: 0.5)
    XCTAssertFalse(view.isScrollEnabled, "measuring must never mutate the view")
  }

  /// The scroll flip lives in `layoutSubviews`, not the sizing pass, and settles after one
  /// extra layout rather than oscillating.
  func testScrollingTurnsOnOnlyOnceTheContentOutgrowsTheCeiling() {
    let view = makeMeasuringView()
    let width = measuringWidth

    view.text = "short"
    view.frame = CGRect(x: 0, y: 0, width: width, height: view.clampedHeight(forWidth: width))
    view.layoutIfNeeded()
    XCTAssertFalse(view.isScrollEnabled)

    view.text = Array(repeating: "line", count: 30).joined(separator: "\n")
    view.frame = CGRect(x: 0, y: 0, width: width, height: view.clampedHeight(forWidth: width))
    view.layoutIfNeeded()
    XCTAssertTrue(view.isScrollEnabled, "past six lines the field scrolls instead of growing")

    // …and back: deleting the overflow restores growth mode.
    view.text = "short again"
    view.frame = CGRect(x: 0, y: 0, width: width, height: view.clampedHeight(forWidth: width))
    view.layoutIfNeeded()
    XCTAssertFalse(view.isScrollEnabled)
  }

  /// The case the simulator pass never reached: the frame is *already* pinned at the ceiling
  /// and only the text grows (line 6 → 7). Nothing about the bounds changes, so the flip
  /// depends on the text change alone driving another `layoutSubviews`.
  func testScrollingTurnsOnWhenOnlyTheTextGrowsAtThePinnedCeiling() {
    let view = makeMeasuringView()
    let width = measuringWidth

    view.text = Array(repeating: "line", count: 6).joined(separator: "\n")
    let ceiling = view.clampedHeight(forWidth: width)
    view.frame = CGRect(x: 0, y: 0, width: width, height: ceiling)
    view.layoutIfNeeded()
    XCTAssertFalse(view.isScrollEnabled, "six lines still fit")

    // Seventh line: the frame stays exactly where it was (SwiftUI proposes the same height).
    view.text = Array(repeating: "line", count: 7).joined(separator: "\n")
    XCTAssertEqual(view.clampedHeight(forWidth: width), ceiling, accuracy: 0.5)
    view.layoutIfNeeded()

    XCTAssertTrue(view.isScrollEnabled, "the text must be reachable by scrolling")
  }

  /// The same ceiling, reached by *typing* rather than a programmatic set — the path a user
  /// actually takes, and the one the `text` observer does not see.
  func testScrollingTurnsOnWhenTheSeventhLineIsTyped() {
    let composer = ComposerTextView(text: .constant(""))
    let coordinator = composer.makeCoordinator()
    let view = makeMeasuringView()
    view.delegate = coordinator
    let width = measuringWidth

    view.text = Array(repeating: "line", count: 6).joined(separator: "\n")
    view.frame = CGRect(x: 0, y: 0, width: width, height: view.clampedHeight(forWidth: width))
    view.layoutIfNeeded()
    XCTAssertFalse(view.isScrollEnabled)

    // `insertText` is what a keystroke does: text storage changes, the delegate fires, the
    // frame does not move.
    view.selectedRange = NSRange(location: (view.text as NSString).length, length: 0)
    view.insertText("\nline")
    view.layoutIfNeeded()

    XCTAssertTrue(view.isScrollEnabled)
  }

  // MARK: - Return key

  /// Return inserts a newline and sends nothing (#70) — the composer has no keyboard submit
  /// path at all, so a Return is an ordinary edit that reaches the buffer *and* the binding.
  ///
  /// `insertText` is what the software keyboard's Return does: it consults the delegate like
  /// any other edit, so a re-introduced `shouldChangeTextIn` interception fails this outright.
  func testReturnInsertsANewlineAndNeverSubmits() {
    let writes = Recorder<String>()
    let composer = ComposerTextView(
      text: Binding(get: { writes.values.last ?? "" }, set: { writes.values.append($0) })
    )
    let coordinator = composer.makeCoordinator()
    let view = ComposerInputTextView()
    view.delegate = coordinator
    view.text = "one"
    view.selectedRange = NSRange(location: 3, length: 0)

    view.insertText("\n")
    view.insertText("two")

    XCTAssertEqual(view.text, "one\ntwo", "the newline reaches the text buffer")
    XCTAssertEqual(writes.values.last, "one\ntwo", "…and the binding, so Send would carry it")
  }

  /// Nothing claims the Return key any more: the Shift+Return key command existed only to route
  /// *around* the submit interception, and leaving it behind would make a shifted Return behave
  /// differently from a plain one for no reason.
  func testNoKeyCommandClaimsReturn() {
    let view = ComposerInputTextView()

    XCTAssertNil(view.keyCommands?.first { $0.input == "\r" })
  }

  // MARK: - Caret visibility

  /// The line that overflows the six-line ceiling has to be *visible*: scrolling switches on
  /// with `contentOffset` still at the top, which left the caret below the fold until the next
  /// keystroke nudged it.
  func testTheCaretIsScrolledIntoViewWhenScrollingTurnsOn() {
    let view = makeMeasuringView()
    let width = measuringWidth

    view.text = Array(repeating: "line", count: 6).joined(separator: "\n")
    view.frame = CGRect(x: 0, y: 0, width: width, height: view.clampedHeight(forWidth: width))
    view.layoutIfNeeded()
    XCTAssertEqual(view.contentOffset.y, 0, accuracy: 0.5)

    // Seventh line, caret at the end — the frame does not move, only the content grows.
    view.text = Array(repeating: "line", count: 7).joined(separator: "\n")
    view.selectedRange = NSRange(location: (view.text as NSString).length, length: 0)
    view.layoutIfNeeded()

    XCTAssertTrue(view.isScrollEnabled)
    XCTAssertGreaterThan(view.contentOffset.y, 0, "the caret's line must be on screen")
  }
}
