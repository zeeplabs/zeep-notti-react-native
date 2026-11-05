import XCTest

/// NSDK-02..04: every Spec method reaches the native SDK with the exact arguments. The SDK's own
/// behavior is tested in `zeep-notti-ios-sdk`; here only the adapter's forwarding is checked.
final class NottiImplAdapterTests: XCTestCase {
  private var fake: FakeNottiNativeSDK!
  private var impl: NottiImpl!

  override func setUp() {
    super.setUp()
    fake = FakeNottiNativeSDK()
    impl = NottiImpl(native: fake)
  }

  override func tearDown() {
    impl.invalidate()
    impl = nil
    fake = nil
    super.tearDown()
  }

  func testInitializeForwardsIdsBaseUrlWrapperNameAndVersion() {
    impl.initialize("app-fixture", clientKey: "key-fixture", baseUrl: "https://example.invalid", sdkVersion: "9.9.9")

    XCTAssertEqual(
      fake.calls,
      [.initialize(
        appId: "app-fixture", clientKey: "key-fixture", baseUrl: "https://example.invalid",
        sdkName: "react-native", sdkVersion: "9.9.9")])
  }

  func testInitializeForwardsAnEmptySdkVersionUntouched() {
    impl.initialize("app-fixture", clientKey: "key-fixture", baseUrl: "https://example.invalid", sdkVersion: "")

    XCTAssertEqual(
      fake.calls,
      [.initialize(
        appId: "app-fixture", clientKey: "key-fixture", baseUrl: "https://example.invalid",
        sdkName: "react-native", sdkVersion: "")])
  }

  func testLoginAndLogoutForward() {
    impl.login("user-fixture")
    impl.logout()

    XCTAssertEqual(fake.calls, [.login("user-fixture"), .logout])
  }

  func testAddTagsForwardsStringEntriesAndDropsTheRest() {
    let tags: NSDictionary = ["plan": "fixture-plan", "count": 3, "flag": true, "gone": NSNull()]

    impl.addTags(tags)

    XCTAssertEqual(fake.calls, [.addTags(["plan": "fixture-plan"])])
  }

  func testRemoveTagsForwardsStringKeysAndDropsTheRest() {
    impl.removeTags(["plan", 3, NSNull(), "tier"] as NSArray)

    XCTAssertEqual(fake.calls, [.removeTags(["plan", "tier"])])
  }

  func testSetSubscriptionForwards() {
    impl.setSubscription(false)
    impl.setSubscription(true)

    XCTAssertEqual(fake.calls, [.setSubscription(false), .setSubscription(true)])
  }

  func testSetLocationSharingEnabledForwards() {
    impl.setLocationSharingEnabled(true)
    impl.setLocationSharingEnabled(false)

    XCTAssertEqual(fake.calls, [.setLocationSharingEnabled(true), .setLocationSharingEnabled(false)])
  }

  func testEmailAndPhoneSettersAndClearersForward() {
    impl.setEmail("user@example.invalid")
    impl.clearEmail()
    impl.setPhone("+10000000000")
    impl.clearPhone()

    XCTAssertEqual(
      fake.calls,
      [.setEmail("user@example.invalid"), .clearEmail, .setPhone("+10000000000"), .clearPhone])
  }

  func testTrackEventForwardsTheNameUntouched() {
    impl.trackEvent("event-fixture")

    XCTAssertEqual(fake.calls, [.trackEvent("event-fixture")])
  }

  func testGetDeviceIdReturnsTheSdkValue() {
    XCTAssertNil(impl.getDeviceId())

    fake.deviceId = "device-fixture"

    XCTAssertEqual(impl.getDeviceId(), "device-fixture")
  }

  func testRequestPermissionResolvesWithTheSdkResult() {
    var results: [NSNumber] = []

    fake.permissionResult = true
    impl.requestPermission { results.append($0) }
    fake.permissionResult = false
    impl.requestPermission { results.append($0) }

    XCTAssertEqual(results, [NSNumber(value: true), NSNumber(value: false)])
    XCTAssertEqual(fake.calls, [.requestPermission, .requestPermission])
  }
}
