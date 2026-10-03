import XCTest

final class QueueControlsInteractionTests: XCTestCase {
  private let id = "11111111-1111-1111-1111-111111111111"

  @MainActor
  func testVisibleMenuCallbacksAtNarrowWidthAndAX5() {
    for arguments in [[], ["AX5"], ["parked"]] as [[String]] {
      for (title, callback) in [("Steer current turn", "steer"), ("Interrupt & send", "send"), ("Edit", "edit"), ("Delete", "delete")] {
        let app = launch(arguments)
        let menu = app.buttons["queue.actions.\(id)"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(menu.isHittable)
        // XCUI frames carry floating-point residue (43.999999999999986 for a 44pt frame);
        // snap to the device pixel grid before comparing, so 1 px short still fails.
        XCTAssertGreaterThanOrEqual(pixels(menu.frame.width), 44)
        XCTAssertGreaterThanOrEqual(pixels(menu.frame.height), 44)
        XCTAssertGreaterThanOrEqual(menu.frame.minX, 0)
        XCTAssertLessThanOrEqual(menu.frame.maxX, app.frame.maxX)
        menu.tap()
        let action = app.buttons[title]
        XCTAssertTrue(action.waitForExistence(timeout: 5), app.debugDescription)
        action.tap()
        XCTAssertTrue(app.staticTexts["\(callback):\(id)"].waitForExistence(timeout: 5), app.debugDescription)
        app.terminate()
      }
    }
  }

  @MainActor
  func testEligibilityAndDraftGuard() {
    for arguments in [["idle"], ["attachment"], ["slash"], ["draft"]] {
      let app = launch(arguments)
      app.buttons["queue.actions.\(id)"].tap()
      let send = arguments.contains("idle") ? "Send now" : "Interrupt & send"
      XCTAssertTrue(app.buttons[send].waitForExistence(timeout: 5))
      XCTAssertFalse(app.buttons[arguments.contains("idle") ? "Interrupt & send" : "Send now"].exists)
      XCTAssertEqual(app.buttons["Steer current turn"].exists, arguments.contains("draft"))
      XCTAssertEqual(app.buttons["Edit"].isEnabled, !arguments.contains("draft"))
      XCTAssertTrue(app.buttons["Delete"].isEnabled)
      app.terminate()
    }
  }

  @MainActor
  func testLongPressRetainsSameActions() {
    let app = launch([])
    app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Queued message:")).firstMatch.press(forDuration: 1)
    XCTAssertTrue(app.buttons["Steer current turn"].waitForExistence(timeout: 5), app.debugDescription)
    XCTAssertTrue(app.buttons["Interrupt & send"].exists)
    XCTAssertTrue(app.buttons["Edit"].exists)
    app.buttons["Delete"].tap()
    XCTAssertTrue(app.staticTexts["delete:\(id)"].waitForExistence(timeout: 5))
  }

  @MainActor
  func testManyEntriesReachableAtAX5() {
    let app = launch(["AX5", "many", "parked"])
    XCTAssertTrue(app.buttons["queue.actions.\(id)"].isHittable)
    let scroller = app.scrollViews.firstMatch
    XCTAssertTrue(scroller.exists)
    XCTAssertLessThanOrEqual(scroller.frame.height, 241)
    let last = app.staticTexts["Held message: Queued message 8"]
    for _ in 0..<12 {
      if last.exists && last.isHittable { break }
      scroller.swipeUp()
    }
    XCTAssertTrue(last.isHittable, app.debugDescription)
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "queue-controls-AX5-scrolled"
    screenshot.lifetime = .keepAlways
    add(screenshot)
  }

  @MainActor
  func testInterruptRecoveryPresentationAndLocalActions() {
    for size in [[], ["AX5"]] as [[String]] {
      for intent in ["waiting", "parked"] {
        for (title, callback) in [("Edit", "edit"), ("Delete", "delete")] {
          let app = launch(size + [intent, "blocked"])
          let header = intent == "waiting"
            ? "Waiting for confirmed stop — then sends next" : "Held — not sent automatically"
          XCTAssertTrue(app.staticTexts[header].exists, app.debugDescription)
          if intent == "waiting" { XCTAssertFalse(app.staticTexts["Held — not sent automatically"].exists) }
          app.buttons["queue.actions.\(id)"].tap()
          XCTAssertTrue(app.buttons["Interrupt & send"].waitForExistence(timeout: 5))
          XCTAssertFalse(app.buttons["Interrupt & send"].isEnabled)
          XCTAssertFalse(app.buttons["Steer current turn"].exists)
          XCTAssertTrue(app.buttons[title].isEnabled)
          app.buttons[title].tap()
          XCTAssertTrue(app.staticTexts["\(callback):\(id)"].waitForExistence(timeout: 5))
          app.terminate()
        }
      }
    }
  }

  // MARK: D1 composer controls (production ComposerView)

  @MainActor
  private func launchComposer(_ arguments: [String]) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["composer"] + arguments
    app.launch()
    XCTAssertTrue(app.staticTexts["composer.callback"].waitForExistence(timeout: 10), app.debugDescription)
    return app
  }

  @MainActor
  private func assertHitArea(_ element: XCUIElement, in app: XCUIApplication, _ name: String) {
    XCTAssertTrue(element.exists, "\(name) missing\n\(app.debugDescription)")
    XCTAssertTrue(element.isHittable, "\(name) not hittable")
    XCTAssertGreaterThanOrEqual(pixels(element.frame.width), 44, name)
    XCTAssertGreaterThanOrEqual(pixels(element.frame.height), 44, name)
    XCTAssertGreaterThanOrEqual(element.frame.minX, 0, name)
    XCTAssertLessThanOrEqual(element.frame.maxX, app.frame.maxX, name)
    // The composer's content width is the text view's; a control outside it is clipped
    // or overflowing the 320pt composer even when it is still on screen (spec R1).
    let field = app.textViews.firstMatch.frame
    XCTAssertGreaterThanOrEqual(element.frame.minX, field.minX - 1, "\(name) left of composer")
    XCTAssertLessThanOrEqual(element.frame.maxX, field.maxX + 1, "\(name) overflows composer")
  }

  /// No two composer controls overlap (a fixed-size label can spill over its neighbour).
  @MainActor
  private func assertNoOverlap(_ elements: [XCUIElement], _ name: String) {
    let frames = elements.filter(\.exists).map(\.frame)
    for i in frames.indices { for j in frames.indices where j > i {
      XCTAssertTrue(frames[i].intersection(frames[j]).width < 1 || frames[i].intersection(frames[j]).height < 1,
                    "\(name): \(frames[i]) overlaps \(frames[j])")
    } }
  }

  /// Stop stays visible and works while a queueable draft is typed; the draft survives.
  @MainActor
  func testStopAndQueueAreDistinctWithADraftAt320AndAX5() {
    for size in [[], ["AX5"]] as [[String]] {
      for model in [[], ["longModel"]] as [[String]] {
        let app = launchComposer(size + model + ["running", "draft"])
        let stop = app.buttons["Stop"], queue = app.buttons["Queue message"]
        assertHitArea(stop, in: app, "Stop \(size)\(model)")
        assertHitArea(queue, in: app, "Queue \(size)\(model)")
        XCTAssertFalse(app.buttons["Send"].exists, "mid-turn primary must not be called Send")
        XCTAssertTrue(queue.isEnabled)
        XCTAssertTrue(app.buttons["Voice input"].exists)
        assertHitArea(app.buttons["Voice input"], in: app, "Voice \(size)\(model)")
        assertHitArea(app.buttons["Add attachment"], in: app, "Attach \(size)\(model)")
        assertNoOverlap([stop, queue, app.buttons["Voice input"], app.buttons["Add attachment"]],
                        "running \(size)\(model)")
        stop.tap()
        XCTAssertTrue(app.staticTexts["interrupt"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["draft:Keep this draft"].exists, "Stop must not consume the draft")
        queue.tap()
        XCTAssertTrue(app.staticTexts["queued:Keep this draft"].waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "composer-running-\(size.first ?? "large")-\(model.first ?? "short")"
        shot.lifetime = .keepAlways
        add(shot)
        app.terminate()
      }
    }
  }

  @MainActor
  func testIdleSendThroughRealTextViewAndReturnIsNewline() {
    let app = launchComposer([])
    XCTAssertFalse(app.buttons["Stop"].exists, "no turn, no Stop")
    let field = app.textViews.firstMatch
    field.tap()
    field.typeText("one\ntwo")
    let send = app.buttons["Send"]
    assertHitArea(send, in: app, "Send")
    XCTAssertTrue(app.staticTexts["draft:one\ntwo"].exists, "Return inserted a newline, did not submit")
    send.tap()
    XCTAssertTrue(app.staticTexts["sent:one\ntwo"].waitForExistence(timeout: 5))
  }

  @MainActor
  func testAttachmentPreparationOffersCancelUploadAndExplainsBlockedQueue() {
    for size in [[], ["AX5"]] as [[String]] {
      let app = launchComposer(size + ["preparing", "draft"])
      XCTAssertFalse(app.buttons["Stop"].exists, "preparation must not claim a server Stop")
      let cancel = app.buttons["Cancel upload"]
      assertHitArea(cancel, in: app, "Cancel upload \(size)")
      assertHitArea(app.buttons["Queue message"], in: app, "Queue while preparing \(size)")
      assertNoOverlap([cancel, app.buttons["Queue message"], app.buttons["Voice input"],
                       app.buttons["Add attachment"]], "preparing \(size)")
      XCTAssertFalse(app.buttons["Queue message"].isEnabled)
      XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "tap Cancel upload")).firstMatch.exists,
                    app.debugDescription)
      cancel.tap()
      XCTAssertTrue(app.staticTexts["interrupt"].waitForExistence(timeout: 5))
      app.terminate()
    }
  }

  @MainActor
  func testBlockingCardExplainsDisabledSendAndKeepsDraftEditable() {
    let app = launchComposer(["card", "draft"])
    let send = app.buttons["Send"]
    XCTAssertTrue(send.exists)
    XCTAssertFalse(send.isEnabled)
    XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Answer the request above")).firstMatch.exists,
                  app.debugDescription)
    let field = app.textViews.firstMatch
    // Tap the trailing edge so the caret lands after the kept draft deterministically
    // (a centre tap's caret position depends on glyph layout, not on the product).
    field.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
    field.typeText(" more")
    XCTAssertTrue(app.staticTexts["draft:Keep this draft more"].waitForExistence(timeout: 5),
                  app.debugDescription)
  }

  private func pixels(_ value: CGFloat) -> CGFloat {
    let scale = UIScreen.main.scale
    return (value * scale).rounded() / scale
  }

  @MainActor
  private func launch(_ arguments: [String]) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = arguments
    app.launch()
    XCTAssertTrue(app.buttons["queue.actions.\(id)"].waitForExistence(timeout: 10), app.debugDescription)
    return app
  }
}
