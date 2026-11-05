import XCTest

/// NSDK-05..07: SDK events reach the Codegen emitters with the 0.8.0 payload shapes, listeners follow
/// the module lifecycle, and the launch tap is handed over once.
final class NottiImplEventTests: XCTestCase {
  private var fake: FakeNottiNativeSDK!
  private var modules: [NottiImpl] = []

  override func setUp() {
    super.setUp()
    fake = FakeNottiNativeSDK()
    NottiImpl.resetInitialClickForTests()
  }

  override func tearDown() {
    modules.forEach { $0.invalidate() }
    modules.removeAll()
    NottiImpl.resetInitialClickForTests()
    fake = nil
    super.tearDown()
  }

  private func makeModule() -> NottiImpl {
    let module = NottiImpl(native: fake)
    modules.append(module)
    return module
  }

  private func emitReceived(_ notification: NottiNativeNotification) {
    Array(fake.receivedHandlers.values).forEach { $0(notification) }
  }

  private func emitClicked(_ notification: NottiNativeNotification) {
    Array(fake.clickedHandlers.values).forEach { $0(notification) }
  }

  func testActivateTakesTheInitialClickBeforeAddingTheClickedListener() {
    let module = makeModule()

    module.activate()

    let takeIndex = fake.calls.firstIndex(of: .takeInitialClick)
    let clickedIndex = fake.calls.firstIndex(of: .addClickedListener)
    XCTAssertNotNil(takeIndex)
    XCTAssertNotNil(clickedIndex)
    XCTAssertLessThan(takeIndex!, clickedIndex!)
    XCTAssertEqual(fake.liveSubscriptions, 4)
  }

  func testReceivedMapsTitleBodyAndData() {
    let module = makeModule()
    var received: [[String: Any]] = []
    module.emitReceivedHandler = { received.append($0) }
    module.activate()

    emitReceived(NottiNativeNotification(title: "title-fixture", body: "body-fixture", data: ["k": "v"]))

    XCTAssertEqual(received.count, 1)
    XCTAssertEqual(received[0]["title"] as? String, "title-fixture")
    XCTAssertEqual(received[0]["body"] as? String, "body-fixture")
    XCTAssertEqual(received[0]["data"] as? [String: String], ["k": "v"])
  }

  func testClickedMapsAbsentTitleAndBodyToNull() {
    let module = makeModule()
    var clicked: [[String: Any]] = []
    module.emitClickedHandler = { clicked.append($0) }
    module.activate()

    emitClicked(NottiNativeNotification(title: nil, body: nil, data: [:]))

    XCTAssertEqual(clicked.count, 1)
    XCTAssertTrue(clicked[0]["title"] is NSNull)
    XCTAssertTrue(clicked[0]["body"] is NSNull)
    XCTAssertEqual((clicked[0]["data"] as? [String: String])?.count, 0)
  }

  func testDeviceIdChangeIsForwardedUntouched() {
    let module = makeModule()
    var ids: [String] = []
    module.emitDeviceIdChangedHandler = { ids.append($0) }
    module.activate()

    Array(fake.deviceIdHandlers.values).forEach { $0("device-fixture") }

    XCTAssertEqual(ids, ["device-fixture"])
  }

  func testInAppClickMapsTheActionOrNull() {
    let module = makeModule()
    var clicks: [[String: Any]] = []
    module.emitInAppClickHandler = { clicks.append($0) }
    module.activate()

    let withAction = NottiNativeInAppClick(
      messageId: "message-fixture", buttonId: "button-fixture", actionType: "deeplink", actionValue: "app://fixture")
    let withoutAction = NottiNativeInAppClick(
      messageId: "message-fixture", buttonId: "button-fixture", actionType: nil, actionValue: nil)
    Array(fake.inAppClickHandlers.values).forEach {
      $0(withAction)
      $0(withoutAction)
    }

    XCTAssertEqual(clicks.count, 2)
    XCTAssertEqual(clicks[0]["messageId"] as? String, "message-fixture")
    XCTAssertEqual(clicks[0]["buttonId"] as? String, "button-fixture")
    XCTAssertEqual(clicks[0]["action"] as? [String: String], ["type": "deeplink", "value": "app://fixture"])
    XCTAssertTrue(clicks[1]["action"] is NSNull)
  }

  func testInvalidateRemovesEverySubscription() {
    let module = makeModule()
    var received = 0
    module.emitReceivedHandler = { _ in received += 1 }
    module.activate()
    XCTAssertEqual(fake.liveSubscriptions, 4)

    module.invalidate()

    XCTAssertEqual(fake.liveSubscriptions, 0)
    emitReceived(NottiNativeNotification(title: nil, body: nil, data: [:]))
    XCTAssertEqual(received, 0)
  }

  func testASecondModuleGetsEachEventOnceAfterAReload() {
    let first = makeModule()
    var firstReceived = 0
    first.emitReceivedHandler = { _ in firstReceived += 1 }
    first.activate()
    first.invalidate()

    let second = makeModule()
    var secondReceived = 0
    second.emitReceivedHandler = { _ in secondReceived += 1 }
    second.activate()
    emitReceived(NottiNativeNotification(title: nil, body: nil, data: [:]))

    XCTAssertEqual(firstReceived, 0)
    XCTAssertEqual(secondReceived, 1)
    XCTAssertEqual(fake.liveSubscriptions, 4)
  }

  func testInitialClickIsReturnedOnceThenNil() {
    fake.initialClick = NottiNativeNotification(title: "title-fixture", body: nil, data: ["k": "v"])
    let module = makeModule()
    module.activate()

    let first = module.takeInitialNotificationClick()

    XCTAssertEqual(first?["title"] as? String, "title-fixture")
    XCTAssertEqual(first?["data"] as? [String: String], ["k": "v"])
    XCTAssertNil(module.takeInitialNotificationClick())
  }

  func testInitialClickSurvivesAReload() {
    fake.initialClick = NottiNativeNotification(title: "title-fixture", body: nil, data: [:])
    let first = makeModule()
    first.activate()
    first.invalidate()

    let second = makeModule()
    second.activate()

    XCTAssertEqual(second.takeInitialNotificationClick()?["title"] as? String, "title-fixture")
    XCTAssertNil(second.takeInitialNotificationClick())
  }

  func testInitialClickAsksTheSdkAgainWhenTheSlotIsEmpty() {
    let module = makeModule()
    module.activate()
    XCTAssertNil(module.takeInitialNotificationClick())

    // A tap stored by the SDK after the listeners were removed by a reload.
    fake.initialClick = NottiNativeNotification(title: "late-fixture", body: nil, data: [:])

    XCTAssertEqual(module.takeInitialNotificationClick()?["title"] as? String, "late-fixture")
    XCTAssertNil(module.takeInitialNotificationClick())
  }
}
