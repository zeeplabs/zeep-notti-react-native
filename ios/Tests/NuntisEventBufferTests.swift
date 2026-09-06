import XCTest

final class NuntisEventBufferTests: XCTestCase {

  private var buffer: NuntisEventBuffer!

  override func setUp() {
    super.setUp()
    buffer = NuntisEventBuffer()
  }

  private func payload(_ title: String) -> [String: Any] {
    ["title": title, "body": "b", "data": ["k": "v"]]
  }

  func test_aColdStartClickIsHandedOverByThePullAndNotEmittedWhenTheEmitterAttaches() {
    // Cold launch from a notification tap: the delegate fires before the RN
    // bridge exists. Attaching the emitter happens while the JS bundle is
    // still evaluating, before any addEventListener('notificationClicked')
    // runs - emitting there sends the click into the void. It must be held
    // for the pull instead.
    buffer.emit(.clicked, identifier: "notif-1", payload: payload("cold start"))

    var emitted: [[String: Any]] = []
    buffer.setHandler(.clicked) { emitted.append($0) }
    XCTAssertTrue(emitted.isEmpty, "the cold-start click must not be auto-emitted")

    let initial = buffer.takeInitialClick()
    XCTAssertEqual(initial?["title"] as? String, "cold start")
    XCTAssertTrue(emitted.isEmpty)
  }

  func test_theColdStartClickIsConsumedSoASecondPullGetsNothing() {
    buffer.emit(.clicked, identifier: "notif-1", payload: payload("cold start"))
    buffer.setHandler(.clicked) { _ in }

    XCTAssertNotNil(buffer.takeInitialClick())
    XCTAssertNil(buffer.takeInitialClick(), "a second pull with no new cold-start click is nil")
  }

  func test_pullingWithNoColdStartClickAtAllReturnsNil() {
    XCTAssertNil(buffer.takeInitialClick())

    // A click delivered live (emitter already attached) is an event, not a
    // cold-start click: it must never show up in the pull.
    var emitted: [String] = []
    buffer.setHandler(.clicked) { emitted.append($0["title"] as? String ?? "") }
    buffer.emit(.clicked, identifier: "notif-1", payload: payload("warm"))

    XCTAssertEqual(emitted, ["warm"])
    XCTAssertNil(buffer.takeInitialClick())
  }

  func test_aPulledClickIsNeverAlsoDeliveredAsAnEvent() {
    buffer.emit(.clicked, identifier: "notif-1", payload: payload("cold start"))

    var emitted: [String] = []
    buffer.setHandler(.clicked) { emitted.append($0["title"] as? String ?? "") }
    XCTAssertNotNil(buffer.takeInitialClick())

    // The delegate path fires again for the same notification after the
    // module attached: dedupe by identifier must still hold.
    buffer.emit(.clicked, identifier: "notif-1", payload: payload("cold start"))

    XCTAssertTrue(emitted.isEmpty)
  }

  func test_theMostRecentColdStartClickWins() {
    buffer.emit(.clicked, identifier: "notif-1", payload: payload("older"))
    buffer.emit(.clicked, identifier: "notif-2", payload: payload("the tap that launched the app"))

    XCTAssertEqual(buffer.takeInitialClick()?["title"] as? String, "the tap that launched the app")
    XCTAssertNil(buffer.takeInitialClick(), "the stale one is dropped, not queued up for a later pull")
  }

  func test_aDifferentNotificationIsStillDeliveredAfterAnEarlierOne() {
    var delivered: [String] = []
    buffer.setHandler(.clicked) { delivered.append($0["title"] as? String ?? "") }

    buffer.emit(.clicked, identifier: "notif-1", payload: payload("first"))
    buffer.emit(.clicked, identifier: "notif-2", payload: payload("second"))

    XCTAssertEqual(delivered, ["first", "second"])
  }

  func test_eventsEmittedWhileAnEmitterIsAttachedGoStraightThroughInOrder() {
    var delivered: [String] = []
    buffer.setHandler(.received) { delivered.append($0["title"] as? String ?? "") }

    buffer.emit(.received, identifier: "notif-1", payload: payload("one"))
    buffer.emit(.received, identifier: "notif-2", payload: payload("two"))

    XCTAssertEqual(delivered, ["one", "two"])
  }

  func test_aBufferedReceivedEventIsStillReplayedWhenItsEmitterAttaches() {
    // Only the click path moved to a pull - `received` keeps replaying, since
    // a data-only push can land before the module exists just the same.
    buffer.emit(.received, identifier: "notif-1", payload: payload("foreground"))
    buffer.emit(.clicked, identifier: "notif-1", payload: payload("tapped"))

    var clicked: [String] = []
    buffer.setHandler(.clicked) { clicked.append($0["title"] as? String ?? "") }
    XCTAssertTrue(clicked.isEmpty)

    var received: [String] = []
    buffer.setHandler(.received) { received.append($0["title"] as? String ?? "") }
    XCTAssertEqual(received, ["foreground"], "attaching the click emitter must not consume the received event")

    XCTAssertEqual(buffer.takeInitialClick()?["title"] as? String, "tapped")
  }

  func test_multipleBufferedReceivedEventsAreReplayedInArrivalOrder() {
    buffer.emit(.received, identifier: "notif-1", payload: payload("first"))
    buffer.emit(.received, identifier: "notif-2", payload: payload("second"))

    var delivered: [String] = []
    buffer.setHandler(.received) { delivered.append($0["title"] as? String ?? "") }

    XCTAssertEqual(delivered, ["first", "second"])
  }

  func test_theBufferIsBoundedSoAMissingListenerCannotGrowItForever() {
    for index in 0..<40 {
      buffer.emit(.received, identifier: "notif-\(index)", payload: payload("n\(index)"))
    }

    var delivered: [String] = []
    buffer.setHandler(.received) { delivered.append($0["title"] as? String ?? "") }

    XCTAssertEqual(delivered.count, 10, "oldest events are dropped once the cap is reached")
    XCTAssertEqual(delivered.first, "n30")
    XCTAssertEqual(delivered.last, "n39")
  }

  func test_clearingTheEmitterBuffersAgainInsteadOfDroppingEvents() {
    var delivered: [String] = []
    buffer.setHandler(.received) { delivered.append($0["title"] as? String ?? "") }
    buffer.setHandler(.received, nil)

    buffer.emit(.received, identifier: "notif-1", payload: payload("while detached"))
    XCTAssertTrue(delivered.isEmpty)

    buffer.setHandler(.received) { delivered.append($0["title"] as? String ?? "") }
    XCTAssertEqual(delivered, ["while detached"])
  }

  func test_aClickEmittedWhileTheEmitterIsDetachedFallsBackToThePull() {
    var delivered: [String] = []
    buffer.setHandler(.clicked) { delivered.append($0["title"] as? String ?? "") }
    buffer.setHandler(.clicked, nil)

    buffer.emit(.clicked, identifier: "notif-1", payload: payload("while detached"))

    buffer.setHandler(.clicked) { delivered.append($0["title"] as? String ?? "") }
    XCTAssertTrue(delivered.isEmpty, "re-attaching must not replay it")
    XCTAssertEqual(buffer.takeInitialClick()?["title"] as? String, "while detached")
  }
}
