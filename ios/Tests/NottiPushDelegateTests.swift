import ObjectiveC
import UserNotifications
import XCTest

final class NottiPushDelegateTests: XCTestCase {

  private let delegate = NottiPushDelegate.shared

  /// The delegate never reads the `center` argument, and neither
  /// `UNUserNotificationCenter.current()` (asserts in a hostless test bundle —
  /// no app `BundleProxy`) nor `init` (asserts "use +currentNotificationCenter")
  /// can produce one here. `class_createInstance` allocates without running
  /// `init`, which is exactly what a dummy center needs.
  private lazy var center: UNUserNotificationCenter = class_createInstance(
    UNUserNotificationCenter.self, 0
  ) as! UNUserNotificationCenter

  override func setUp() {
    super.setUp()
    // The shared store and buffer are process-global singletons (mirroring
    // `NottiEventBuffer.shared`); reset both so every test starts clean.
    NottiImpl.eventStore.reset()
    NottiEventBuffer.shared.reset()
  }

  // MARK: - Fixtures
  //
  // `UNNotification`/`UNNotificationResponse` expose no public initializer
  // (`init NS_UNAVAILABLE` in the SDK headers), so fixtures are allocated
  // through the ObjC runtime and populated via KVC. Only the read-only
  // properties the delegate reads are set: `request.content.userInfo`,
  // `request.identifier`, and `actionIdentifier`.

  private func makeNotification(userInfo: [AnyHashable: Any]) -> UNNotification {
    let content = UNMutableNotificationContent()
    content.userInfo = userInfo
    let request = UNNotificationRequest(identifier: "test-notification", content: content, trigger: nil)
    let notification = (UNNotification.self as NSObject.Type).init() as! UNNotification
    notification.setValue(request, forKey: "request")
    notification.setValue(Date(), forKey: "date")
    return notification
  }

  private func makeResponse(userInfo: [AnyHashable: Any], actionIdentifier: String) -> UNNotificationResponse {
    let response = (UNNotificationResponse.self as NSObject.Type).init() as! UNNotificationResponse
    response.setValue(makeNotification(userInfo: userInfo), forKey: "notification")
    response.setValue(actionIdentifier, forKey: "actionIdentifier")
    return response
  }

  private func makeRemoteUserInfo(notificationId: String?, deliveryId: String?) -> [AnyHashable: Any] {
    var userInfo: [AnyHashable: Any] = ["aps": ["alert": ["title": "Hello", "body": "World"]]]
    if let notificationId = notificationId { userInfo["notification_id"] = notificationId }
    if let deliveryId = deliveryId { userInfo["delivery_id"] = deliveryId }
    return userInfo
  }

  private func awaitWillPresent(_ notification: UNNotification) {
    let expectation = expectation(description: "willPresent completion")
    delegate.userNotificationCenter(center, willPresent: notification) { _ in
      expectation.fulfill()
    }
    wait(for: [expectation], timeout: 1)
  }

  private func awaitDidReceive(_ response: UNNotificationResponse) {
    let expectation = expectation(description: "didReceive completion")
    delegate.userNotificationCenter(center, didReceive: response) {
      expectation.fulfill()
    }
    wait(for: [expectation], timeout: 1)
  }

  // MARK: - willPresent (received)

  func test_willPresentWithNotificationAndDeliveryIdsEnqueuesAReceivedEvent() {
    awaitWillPresent(makeNotification(userInfo: makeRemoteUserInfo(notificationId: "n-1", deliveryId: "d-1")))

    let events = NottiImpl.eventStore.all()
    XCTAssertEqual(events.count, 1)
    XCTAssertEqual(events.first?.notificationId, "n-1")
    XCTAssertEqual(events.first?.deliveryId, "d-1")
    XCTAssertEqual(events.first?.type, "received")
  }

  func test_willPresentWithoutIdsSkipsEnqueue() {
    awaitWillPresent(makeNotification(userInfo: makeRemoteUserInfo(notificationId: nil, deliveryId: nil)))

    XCTAssertTrue(NottiImpl.eventStore.all().isEmpty)
  }

  func test_willPresentWithAnEmptyIdSkipsEnqueue() {
    awaitWillPresent(makeNotification(userInfo: makeRemoteUserInfo(notificationId: "", deliveryId: "d-1")))

    XCTAssertTrue(NottiImpl.eventStore.all().isEmpty)
  }

  func test_willPresentForANonRemotePushSkipsEnqueueEvenWithIds() {
    let userInfo: [AnyHashable: Any] = ["notification_id": "n-1", "delivery_id": "d-1"]
    awaitWillPresent(makeNotification(userInfo: userInfo))

    XCTAssertTrue(NottiImpl.eventStore.all().isEmpty)
  }

  // MARK: - didReceive: body tap (opened) / action button (clicked)

  func test_didReceiveDefaultActionWithIdsEnqueuesOneOpenedEventAndNoClicked() {
    // SDKOPEN-01/03: the body tap is `opened`; `clicked` is reserved for
    // action buttons.
    let response = makeResponse(
      userInfo: makeRemoteUserInfo(notificationId: "n-1", deliveryId: "d-1"),
      actionIdentifier: UNNotificationDefaultActionIdentifier
    )
    awaitDidReceive(response)

    let events = NottiImpl.eventStore.all()
    XCTAssertEqual(events.count, 1)
    XCTAssertEqual(events.first?.notificationId, "n-1")
    XCTAssertEqual(events.first?.deliveryId, "d-1")
    XCTAssertEqual(events.first?.type, "opened")
  }

  func test_didReceiveDefaultActionWithAURLInDataStillEnqueuesOnlyOpened() {
    // SDKOPEN-03 / D1: a URL in custom data is integrator-owned, not a backend
    // CTA field, so the tap stays an open.
    var userInfo = makeRemoteUserInfo(notificationId: "n-1", deliveryId: "d-1")
    userInfo["url"] = "https://example.com/promo"
    userInfo["deep_link"] = "app://orders/42"
    awaitDidReceive(makeResponse(userInfo: userInfo, actionIdentifier: UNNotificationDefaultActionIdentifier))

    XCTAssertEqual(NottiImpl.eventStore.all().map(\.type), ["opened"])
  }

  func test_didReceiveDefaultActionStillBuffersTheJSClickForAColdStart() {
    // SDKOPEN-02/10: no TurboModule or JS listener exists on a cold start; the
    // event is queued natively and the payload stays available to
    // getInitialNotificationClick() under the unchanged JS event name.
    let response = makeResponse(
      userInfo: makeRemoteUserInfo(notificationId: "n-1", deliveryId: "d-1"),
      actionIdentifier: UNNotificationDefaultActionIdentifier
    )
    awaitDidReceive(response)

    XCTAssertEqual(NottiImpl.eventStore.all().map(\.type), ["opened"])
    XCTAssertNotNil(NottiEventBuffer.shared.takeInitialClick())
  }

  func test_eachDefaultActionResponseEnqueuesItsOwnOpenedEvent() {
    // SDKOPEN-04: one `didReceive` per tap, one event per `didReceive`.
    awaitDidReceive(makeResponse(
      userInfo: makeRemoteUserInfo(notificationId: "n-1", deliveryId: "d-1"),
      actionIdentifier: UNNotificationDefaultActionIdentifier
    ))
    awaitDidReceive(makeResponse(
      userInfo: makeRemoteUserInfo(notificationId: "n-2", deliveryId: "d-2"),
      actionIdentifier: UNNotificationDefaultActionIdentifier
    ))

    let events = NottiImpl.eventStore.all()
    XCTAssertEqual(events.map(\.deliveryId), ["d-1", "d-2"])
    XCTAssertEqual(events.map(\.type), ["opened", "opened"])
  }

  func test_didReceiveCustomActionEnqueuesOneClickedEventAndNoOpened() {
    // SDKOPEN-05 / D2: a category action button is `clicked` only; the
    // backend already counts a clicked delivery as opened.
    let response = makeResponse(
      userInfo: makeRemoteUserInfo(notificationId: "n-1", deliveryId: "d-1"),
      actionIdentifier: "CUSTOM_ACTION"
    )
    awaitDidReceive(response)

    let events = NottiImpl.eventStore.all()
    XCTAssertEqual(events.count, 1)
    XCTAssertEqual(events.first?.notificationId, "n-1")
    XCTAssertEqual(events.first?.deliveryId, "d-1")
    XCTAssertEqual(events.first?.type, "clicked")
  }

  func test_didReceiveCustomActionDoesNotEmitTheJSClickEvent() {
    // SDKOPEN-07: the JS `notificationClicked` event stays body-tap only.
    awaitDidReceive(makeResponse(
      userInfo: makeRemoteUserInfo(notificationId: "n-1", deliveryId: "d-1"),
      actionIdentifier: "CUSTOM_ACTION"
    ))

    XCTAssertNil(NottiEventBuffer.shared.takeInitialClick())
  }

  func test_didReceiveCustomActionWithoutIdsSkipsEnqueue() {
    // SDKOPEN-08.
    awaitDidReceive(makeResponse(
      userInfo: makeRemoteUserInfo(notificationId: nil, deliveryId: nil),
      actionIdentifier: "CUSTOM_ACTION"
    ))

    XCTAssertTrue(NottiImpl.eventStore.all().isEmpty)
  }

  func test_didReceiveCustomActionForANonRemotePushSkipsEnqueueEvenWithIds() {
    // SDKOPEN-08: a local notification's action is not this SDK's event.
    awaitDidReceive(makeResponse(
      userInfo: ["notification_id": "n-1", "delivery_id": "d-1"],
      actionIdentifier: "CUSTOM_ACTION"
    ))

    XCTAssertTrue(NottiImpl.eventStore.all().isEmpty)
  }

  func test_didReceiveDismissActionSkipsEnqueueEvenWithIds() {
    // SDKOPEN-06.
    let response = makeResponse(
      userInfo: makeRemoteUserInfo(notificationId: "n-1", deliveryId: "d-1"),
      actionIdentifier: UNNotificationDismissActionIdentifier
    )
    awaitDidReceive(response)

    XCTAssertTrue(NottiImpl.eventStore.all().isEmpty)
  }

  func test_didReceiveNonRemotePushSkipsEnqueueEvenWithIds() {
    let response = makeResponse(
      userInfo: ["notification_id": "n-1", "delivery_id": "d-1"],
      actionIdentifier: UNNotificationDefaultActionIdentifier
    )
    awaitDidReceive(response)

    XCTAssertTrue(NottiImpl.eventStore.all().isEmpty)
  }
}