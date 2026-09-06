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

  func test_aClickArrivingBeforeAnyListenerIsReplayedWhenTheEmitterAttaches() {
    // Cold launch from a notification tap: the delegate fires before the RN
    // bridge exists, so there is no emitter yet. The payload must survive.
    buffer.emit(.clicked, identifier: "notif-1", payload: payload("cold start"))

    var delivered: [[String: Any]] = []
    buffer.setHandler(.clicked) { delivered.append($0) }

    XCTAssertEqual(delivered.count, 1)
    XCTAssertEqual(delivered.first?["title"] as? String, "cold start")
  }

  func test_theSameNotificationIsNeverDeliveredTwice() {
    var delivered: [[String: Any]] = []
    buffer.emit(.clicked, identifier: "notif-1", payload: payload("cold start"))
    buffer.setHandler(.clicked) { delivered.append($0) }

    // The delegate path fires again for the same notification (e.g. re-entered
    // after the module attached): the replay must not be duplicated.
    buffer.emit(.clicked, identifier: "notif-1", payload: payload("cold start"))
    // And re-attaching an emitter must not re-deliver it either.
    buffer.setHandler(.clicked) { delivered.append($0) }

    XCTAssertEqual(delivered.count, 1)
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

  func test_receivedAndClickedAreBufferedAndReplayedIndependently() {
    buffer.emit(.received, identifier: "notif-1", payload: payload("foreground"))
    buffer.emit(.clicked, identifier: "notif-1", payload: payload("tapped"))

    var clicked: [String] = []
    buffer.setHandler(.clicked) { clicked.append($0["title"] as? String ?? "") }
    XCTAssertEqual(clicked, ["tapped"], "attaching the click emitter must not consume the received event")

    var received: [String] = []
    buffer.setHandler(.received) { received.append($0["title"] as? String ?? "") }
    XCTAssertEqual(received, ["foreground"])
  }

  func test_multipleBufferedEventsAreReplayedInArrivalOrder() {
    buffer.emit(.clicked, identifier: "notif-1", payload: payload("first"))
    buffer.emit(.clicked, identifier: "notif-2", payload: payload("second"))

    var delivered: [String] = []
    buffer.setHandler(.clicked) { delivered.append($0["title"] as? String ?? "") }

    XCTAssertEqual(delivered, ["first", "second"])
  }

  func test_theBufferIsBoundedSoAMissingListenerCannotGrowItForever() {
    for index in 0..<40 {
      buffer.emit(.clicked, identifier: "notif-\(index)", payload: payload("n\(index)"))
    }

    var delivered: [String] = []
    buffer.setHandler(.clicked) { delivered.append($0["title"] as? String ?? "") }

    XCTAssertEqual(delivered.count, 10, "oldest events are dropped once the cap is reached")
    XCTAssertEqual(delivered.first, "n30")
    XCTAssertEqual(delivered.last, "n39")
  }

  func test_clearingTheEmitterBuffersAgainInsteadOfDroppingEvents() {
    var delivered: [String] = []
    buffer.setHandler(.clicked) { delivered.append($0["title"] as? String ?? "") }
    buffer.setHandler(.clicked, nil)

    buffer.emit(.clicked, identifier: "notif-1", payload: payload("while detached"))
    XCTAssertTrue(delivered.isEmpty)

    buffer.setHandler(.clicked) { delivered.append($0["title"] as? String ?? "") }
    XCTAssertEqual(delivered, ["while detached"])
  }
}
