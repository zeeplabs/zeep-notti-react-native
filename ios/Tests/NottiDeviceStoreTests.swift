import XCTest
// Test target compiles the SDK's Swift sources directly (see NottiTests
// Xcode target: ios/*.swift + ios/Tests/*.swift, no CocoaPods module
// dependency) — no import of a "Notti" module needed or possible here.

final class NottiDeviceStoreTests: XCTestCase {

  private var suiteName: String!
  private var defaults: UserDefaults!
  private var store: NottiDeviceStore!

  override func setUp() {
    super.setUp()
    suiteName = "NottiDeviceStoreTests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
    store = NottiDeviceStore(defaults: defaults)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    super.tearDown()
  }

  func test_emptyNeverInitializedStateHasNoValues() {
    let state = store.getState()

    XCTAssertNil(state.deviceId)
    XCTAssertNil(state.lastToken)
    XCTAssertNil(state.externalUserId)
    XCTAssertFalse(state.subscribed)
    XCTAssertTrue(state.tags.isEmpty)
  }

  func test_setTagsPersistsAndGetTagsReturnsTheAddedTags() {
    store.setTags(["plan": "vip", "cohort": "beta"])

    XCTAssertEqual(store.getTags(), ["plan": "vip", "cohort": "beta"])
  }

  func test_setTagsWithAKeyRemovedFromAPriorCallIsNoLongerPresent() {
    store.setTags(["plan": "vip", "cohort": "beta"])
    store.setTags(["cohort": "beta"])

    XCTAssertEqual(store.getTags(), ["cohort": "beta"])
  }

  func test_mergeTagsAddsRemovesAndLastOperationWinsOnOverlappingAddPlusRemove() {
    let current = ["plan": "vip", "cohort": "beta"]

    let added = NottiDeviceStore.mergeTags(current, add: ["region": "br"])
    XCTAssertEqual(added, ["plan": "vip", "cohort": "beta", "region": "br"])

    let removed = NottiDeviceStore.mergeTags(current, remove: ["plan"])
    XCTAssertEqual(removed, ["cohort": "beta"])

    // Same key both added and removed in one call: add wins (documented rule).
    let overlap = NottiDeviceStore.mergeTags(current, add: ["plan": "enterprise"], remove: ["plan"])
    XCTAssertEqual(overlap, ["plan": "enterprise", "cohort": "beta"])
  }

  func test_deviceIdAndLastTokenRoundTripThroughUserDefaults() {
    store.setDeviceId("device-123")
    store.setLastToken("apns-token-abc")

    XCTAssertEqual(store.getDeviceId(), "device-123")
    XCTAssertEqual(store.getLastToken(), "apns-token-abc")
  }

  func test_externalUserIdAndSubscribedRoundTripThroughUserDefaults() {
    store.setExternalUserId("user-42")
    store.setSubscribed(true)

    let state = store.getState()
    XCTAssertEqual(state.externalUserId, "user-42")
    XCTAssertTrue(state.subscribed)
  }

  // MARK: - Segment telemetry fields (T6)

  func test_telemetryFieldsRoundTripThroughUserDefaults() {
    store.setAppVersion("1.2.3")
    store.setFirstSessionAtMs(1_000)
    store.setLastSessionAtMs(2_000)
    store.setSessionCount(3)
    store.setSessionTimeMs(45_000)
    store.setSessionStartedAtMs(5_000)
    store.setLocationSharingEnabled(true)

    XCTAssertEqual(store.getAppVersion(), "1.2.3")
    XCTAssertEqual(store.getFirstSessionAtMs(), 1_000)
    XCTAssertEqual(store.getLastSessionAtMs(), 2_000)
    XCTAssertEqual(store.getSessionCount(), 3)
    XCTAssertEqual(store.getSessionTimeMs(), 45_000)
    XCTAssertEqual(store.getSessionStartedAtMs(), 5_000)
    XCTAssertTrue(store.getLocationSharingEnabled())
  }

  func test_telemetryFieldsPersistAcrossANewStoreInstanceOverTheSameDefaults() {
    store.setAppVersion("2.0.0")
    store.setFirstSessionAtMs(1_000)
    store.setLastSessionAtMs(2_000)
    store.setSessionCount(7)
    store.setSessionTimeMs(90_000)
    store.setSessionStartedAtMs(3_000)
    store.setLocationSharingEnabled(true)

    let fresh = NottiDeviceStore(defaults: defaults)
    XCTAssertEqual(fresh.getAppVersion(), "2.0.0")
    XCTAssertEqual(fresh.getFirstSessionAtMs(), 1_000)
    XCTAssertEqual(fresh.getLastSessionAtMs(), 2_000)
    XCTAssertEqual(fresh.getSessionCount(), 7)
    XCTAssertEqual(fresh.getSessionTimeMs(), 90_000)
    XCTAssertEqual(fresh.getSessionStartedAtMs(), 3_000)
    XCTAssertTrue(fresh.getLocationSharingEnabled())
  }

  func test_telemetryFieldsDefaultToDisabledAndZeroForANeverInitializedStore() {
    XCTAssertNil(store.getAppVersion())
    XCTAssertNil(store.getFirstSessionAtMs())
    XCTAssertNil(store.getLastSessionAtMs())
    XCTAssertEqual(store.getSessionCount(), 0)
    XCTAssertEqual(store.getSessionTimeMs(), 0)
    XCTAssertNil(store.getSessionStartedAtMs())
    XCTAssertFalse(store.getLocationSharingEnabled())
  }

  func test_getStateIncludesTheNewTelemetryFields() {
    store.setAppVersion("1.2.3")
    store.setFirstSessionAtMs(1_000)
    store.setLastSessionAtMs(2_000)
    store.setSessionCount(3)
    store.setSessionTimeMs(45_000)
    store.setSessionStartedAtMs(5_000)
    store.setLocationSharingEnabled(true)

    let state = store.getState()
    XCTAssertEqual(state.appVersion, "1.2.3")
    XCTAssertEqual(state.firstSessionAtMs, 1_000)
    XCTAssertEqual(state.lastSessionAtMs, 2_000)
    XCTAssertEqual(state.sessionCount, 3)
    XCTAssertEqual(state.sessionTimeMs, 45_000)
    XCTAssertEqual(state.sessionStartedAtMs, 5_000)
    XCTAssertTrue(state.locationSharingEnabled)
  }
}
