import XCTest
// Test target compiles the SDK's Swift sources directly (see NuntisTests
// Xcode target: ios/*.swift + ios/Tests/*.swift, no CocoaPods module
// dependency) — no import of a "Nuntis" module needed or possible here.

final class NuntisDeviceStoreTests: XCTestCase {

  private var suiteName: String!
  private var defaults: UserDefaults!
  private var store: NuntisDeviceStore!

  override func setUp() {
    super.setUp()
    suiteName = "NuntisDeviceStoreTests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
    store = NuntisDeviceStore(defaults: defaults)
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

    let added = NuntisDeviceStore.mergeTags(current, add: ["region": "br"])
    XCTAssertEqual(added, ["plan": "vip", "cohort": "beta", "region": "br"])

    let removed = NuntisDeviceStore.mergeTags(current, remove: ["plan"])
    XCTAssertEqual(removed, ["cohort": "beta"])

    // Same key both added and removed in one call: add wins (documented rule).
    let overlap = NuntisDeviceStore.mergeTags(current, add: ["plan": "enterprise"], remove: ["plan"])
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
}
