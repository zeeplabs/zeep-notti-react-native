import ObjectiveC
import UserNotifications
import XCTest

/// NSDK-11, NSDK-12: the deprecated 0.8.0 entry points still compile, `NottiBridge` forwards to the
/// SDK's manual API, and `NottiPushDelegate` only completes its callbacks.
@available(*, deprecated)
final class NottiLegacyIntegrationTests: XCTestCase {
  private var fake: FakeNottiNativeSDK!
  private var original: NottiNativeSDK!

  /// `UNNotification` and `UNNotificationResponse` have no public initializer; the delegate never reads
  /// the center, and none can be built in a hostless bundle, so fixtures come from the ObjC runtime.
  private lazy var center: UNUserNotificationCenter = class_createInstance(
    UNUserNotificationCenter.self, 0
  ) as! UNUserNotificationCenter

  override func setUp() {
    super.setUp()
    fake = FakeNottiNativeSDK()
    original = NottiBridge.native
    NottiBridge.native = fake
  }

  override func tearDown() {
    NottiBridge.native = original
    fake = nil
    super.tearDown()
  }

  private func makeNotification() -> UNNotification {
    let content = UNMutableNotificationContent()
    content.userInfo = ["aps": ["alert": ["title": "title-fixture"]]]
    let request = UNNotificationRequest(identifier: "notification-fixture", content: content, trigger: nil)
    let notification = (UNNotification.self as NSObject.Type).init() as! UNNotification
    notification.setValue(request, forKey: "request")
    notification.setValue(Date(), forKey: "date")
    return notification
  }

  private func makeResponse(actionIdentifier: String) -> UNNotificationResponse {
    let response = (UNNotificationResponse.self as NSObject.Type).init() as! UNNotificationResponse
    response.setValue(makeNotification(), forKey: "notification")
    response.setValue(actionIdentifier, forKey: "actionIdentifier")
    return response
  }

  func testBridgeForwardsTheDeviceTokenUntouched() {
    let token = Data([0x01, 0xAB, 0xFF])

    NottiBridge.didRegisterForRemoteNotifications(deviceToken: token)

    XCTAssertEqual(fake.calls, [.didRegister(token)])
  }

  func testBridgeForwardsTheRegistrationError() {
    let error = NSError(domain: "fixture.invalid", code: 7)

    NottiBridge.didFailToRegisterForRemoteNotifications(error)

    XCTAssertEqual(fake.calls, [.didFail("fixture.invalid")])
  }

  func testWillPresentCompletesWithTheDocumentedOptionsAndNeverCallsTheSdk() {
    var options: UNNotificationPresentationOptions?

    NottiPushDelegate.shared.userNotificationCenter(center, willPresent: makeNotification()) { options = $0 }

    XCTAssertEqual(options, [.banner, .list, .sound, .badge])
    XCTAssertTrue(fake.calls.isEmpty)
  }

  func testDidReceiveCompletesOnceForEveryActionAndNeverCallsTheSdk() {
    var completions = 0

    for action in [UNNotificationDefaultActionIdentifier, UNNotificationDismissActionIdentifier, "custom-fixture"] {
      NottiPushDelegate.shared.userNotificationCenter(center, didReceive: makeResponse(actionIdentifier: action)) {
        completions += 1
      }
    }

    XCTAssertEqual(completions, 3)
    XCTAssertTrue(fake.calls.isEmpty)
  }
}
