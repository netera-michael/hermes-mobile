import Foundation
import Testing

@testable import HermesKit

/// D1: the composer names every action explicitly and never trades Stop for a draft.
struct ComposerControlsTests {
  @Test func idleWithDraftIsSendWithoutStop() {
    let c = ComposerControls.derive(isSending: false, hasContent: true, canSend: true, canQueue: false)
    #expect(c.primary == .send)
    #expect(c.primaryEnabled)
    #expect(c.stop == nil)
    #expect(c.primaryTitle == "Send")
    #expect(c.primaryAccessibilityLabel == "Send")
    #expect(c.blockedReason == nil)
  }

  /// The pre-D1 bug: typing mid-turn swapped Stop away, so stopping meant deleting the draft.
  @Test func runningWithQueueableDraftKeepsStopAndQueue() {
    let c = ComposerControls.derive(isSending: true, hasContent: true, canSend: false, canQueue: true)
    #expect(c.stop == .stopTurn)
    #expect(c.stopTitle == "Stop")
    #expect(c.primary == .queue)
    #expect(c.primaryEnabled)
    #expect(c.primaryTitle == "Queue")
    #expect(c.primaryAccessibilityLabel == "Queue message")
    #expect(c.primaryAccessibilityLabel != "Send")
  }

  @Test func runningWithEmptyComposerKeepsStopAndDisabledQueueWithoutReason() {
    let c = ComposerControls.derive(isSending: true, hasContent: false, canSend: false, canQueue: false)
    #expect(c.stop == .stopTurn)
    #expect(c.primary == .queue)
    #expect(!c.primaryEnabled)
    #expect(c.blockedReason == nil, "nothing typed: nothing to explain")
  }

  @Test func attachmentPreparationSaysCancelUploadNotStop() {
    let c = ComposerControls.derive(
      isSending: true, isPreparingAttachments: true, hasContent: true, canSend: false, canQueue: false,
      blockers: .init(deliveryPending: true))
    #expect(c.stop == .cancelPreparation)
    #expect(c.stopTitle == "Cancel upload")
    #expect(c.stopAccessibilityHint?.contains("server") == false)
    #expect(c.blockedReason == "Uploading attachments. Wait for it to finish, or tap Cancel upload.")
  }

  @Test func slashExecutionQueuesAndStopFollowsIsSending() {
    // The reducer sets `isSending` together with `slashExecInFlight`, so the real state
    // shows Queue AND Stop; Stop is keyed on `isSending` alone, never on the slash flag.
    let real = ComposerControls.derive(
      isSending: true, isSlashExecuting: true, hasContent: true, canSend: false, canQueue: true)
    #expect(real.primary == .queue)
    #expect(real.stop == .stopTurn)
    // Defensive: the slash flag by itself still names the primary Queue, adds no Stop.
    let flagOnly = ComposerControls.derive(
      isSending: false, isSlashExecuting: true, hasContent: true, canSend: false, canQueue: true)
    #expect(flagOnly.primary == .queue)
    #expect(flagOnly.stop == nil)
  }

  @Test func blockedDraftAlwaysExplainsItself() {
    let cases: [(ComposerControls.Blockers, Bool, String)] = [
      (.init(isPasting: true, hasBlockingCard: true), false, "Adding the pasted image…"),
      (.init(hasBlockingCard: true), false, "Answer the request above to send. Your draft is kept."),
      (.init(hasBlockingCard: true), true, "Answer the request above first. Your draft is kept."),
      (.init(isReconnecting: true), false, "Connecting. Your draft is kept."),
      (.init(deliveryPending: true), true, "Waiting for the last message or Stop to be confirmed. Your draft is kept."),
      (.init(isBranching: true), false, "Creating the branch. Your draft is kept."),
      (.init(), false, "Can't send right now. Your draft is kept."),
      (.init(), true, "Can't queue right now. Your draft is kept."),
    ]
    for (blockers, running, expected) in cases {
      let c = ComposerControls.derive(
        isSending: running, hasContent: true, canSend: false, canQueue: false, blockers: blockers)
      #expect(!c.primaryEnabled)
      #expect(c.blockedReason == expected)
      #expect(c.primaryAccessibilityHint == expected)
    }
  }

  /// Eligibility stays the reducer's: the presentation never enables what canSend/canQueue deny.
  @Test func eligibilityIsPassedThroughUnchanged() {
    for running in [false, true] {
      for slash in [false, true] {
        for canSend in [false, true] {
          for canQueue in [false, true] {
            let c = ComposerControls.derive(
              isSending: running, isSlashExecuting: slash, hasContent: true,
              canSend: canSend, canQueue: canQueue)
            #expect(c.primaryEnabled == ((running || slash) ? canQueue : canSend))
          }
        }
      }
    }
  }

  @Test func queueRowCopyNamesTheEffectOnTheRunningTurn() {
    #expect(ComposerControls.queueSendTitle(isTurnRunning: true) == "Interrupt & send")
    #expect(ComposerControls.queueSendTitle(isTurnRunning: false) == "Send now")
    #expect(ComposerControls.steerTitle == "Steer current turn")
  }

  @Test func preparationRequiresAnInFlightSubmitWithUploadingChips() {
    var uploading = ComposerAttachment(id: UUID(), kind: .image, filename: "a.png", mimeType: "image/png", data: Data())
    uploading.uploadState = .uploading
    var failed = uploading
    failed.uploadState = .failed("x")
    #expect(ComposerControls.isPreparingAttachments(attachments: [uploading], submitOutcome: .submitting))
    #expect(!ComposerControls.isPreparingAttachments(attachments: [uploading], submitOutcome: .accepted))
    #expect(!ComposerControls.isPreparingAttachments(attachments: [uploading], submitOutcome: nil))
    #expect(!ComposerControls.isPreparingAttachments(attachments: [failed], submitOutcome: .submitting))
    #expect(!ComposerControls.isPreparingAttachments(attachments: [], submitOutcome: .submitting))
  }
}
