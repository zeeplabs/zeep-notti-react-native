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

  // MARK: - Device profile fields (T6)

  func test_deviceProfileFieldsRoundTripThroughUserDefaults() {
    store.setLastSyncedDeviceOs("15.0")
    store.setLastSyncedDeviceModel("iPhone15,2")
    store.setLastSyncedSdkVersion("0.5.0")
    store.setLastSyncedTimezoneId("America/Sao_Paulo")
    store.setLastSyncedLanguage("pt")
    store.setLastSyncedPermissionStatus("granted")
    store.setLastUnsubscribedAtMs(1_700_000_000_000)
    store.setEmail("user@example.com")
    store.setPhone("+5511999999999")

    XCTAssertEqual(store.getLastSyncedDeviceOs(), "15.0")
    XCTAssertEqual(store.getLastSyncedDeviceModel(), "iPhone15,2")
    XCTAssertEqual(store.getLastSyncedSdkVersion(), "0.5.0")
    XCTAssertEqual(store.getLastSyncedTimezoneId(), "America/Sao_Paulo")
    XCTAssertEqual(store.getLastSyncedLanguage(), "pt")
    XCTAssertEqual(store.getLastSyncedPermissionStatus(), "granted")
    XCTAssertEqual(store.getLastUnsubscribedAtMs(), 1_700_000_000_000)
    XCTAssertEqual(store.getEmail(), "user@example.com")
    XCTAssertEqual(store.getPhone(), "+5511999999999")
  }

  func test_deviceProfileFieldsPersistAcrossANewStoreInstanceOverTheSameDefaults() {
    store.setLastSyncedDeviceOs("14.0")
    store.setLastSyncedDeviceModel("iPhone14,2")
    store.setLastSyncedSdkVersion("0.4.0")
    store.setLastSyncedTimezoneId("America/New_York")
    store.setLastSyncedLanguage("en")
    store.setLastSyncedPermissionStatus("denied")
    store.setLastUnsubscribedAtMs(1_700_000_000_001)
    store.setEmail("a@b.com")
    store.setPhone("+10000000000")

    let fresh = NottiDeviceStore(defaults: defaults)
    XCTAssertEqual(fresh.getLastSyncedDeviceOs(), "14.0")
    XCTAssertEqual(fresh.getLastSyncedDeviceModel(), "iPhone14,2")
    XCTAssertEqual(fresh.getLastSyncedSdkVersion(), "0.4.0")
    XCTAssertEqual(fresh.getLastSyncedTimezoneId(), "America/New_York")
    XCTAssertEqual(fresh.getLastSyncedLanguage(), "en")
    XCTAssertEqual(fresh.getLastSyncedPermissionStatus(), "denied")
    XCTAssertEqual(fresh.getLastUnsubscribedAtMs(), 1_700_000_000_001)
    XCTAssertEqual(fresh.getEmail(), "a@b.com")
    XCTAssertEqual(fresh.getPhone(), "+10000000000")
  }

  func test_deviceProfileFieldsDefaultToNilForANeverInitializedStore() {
    XCTAssertNil(store.getLastSyncedDeviceOs())
    XCTAssertNil(store.getLastSyncedDeviceModel())
    XCTAssertNil(store.getLastSyncedSdkVersion())
    XCTAssertNil(store.getLastSyncedTimezoneId())
    XCTAssertNil(store.getLastSyncedLanguage())
    XCTAssertNil(store.getLastSyncedPermissionStatus())
    XCTAssertNil(store.getLastUnsubscribedAtMs())
    XCTAssertNil(store.getEmail())
    XCTAssertNil(store.getPhone())
  }

  func test_getStateIncludesTheNewDeviceProfileFields() {
    store.setLastSyncedDeviceOs("15.0")
    store.setLastSyncedDeviceModel("iPhone15,2")
    store.setLastSyncedSdkVersion("0.5.0")
    store.setLastSyncedTimezoneId("America/Sao_Paulo")
    store.setLastSyncedLanguage("pt")
    store.setLastSyncedPermissionStatus("granted")
    store.setLastUnsubscribedAtMs(1_700_000_000_000)
    store.setEmail("user@example.com")
    store.setPhone("+5511999999999")

    let state = store.getState()
    XCTAssertEqual(state.lastSyncedDeviceOs, "15.0")
    XCTAssertEqual(state.lastSyncedDeviceModel, "iPhone15,2")
    XCTAssertEqual(state.lastSyncedSdkVersion, "0.5.0")
    XCTAssertEqual(state.lastSyncedTimezoneId, "America/Sao_Paulo")
    XCTAssertEqual(state.lastSyncedLanguage, "pt")
    XCTAssertEqual(state.lastSyncedPermissionStatus, "granted")
    XCTAssertEqual(state.lastUnsubscribedAtMs, 1_700_000_000_000)
    XCTAssertEqual(state.email, "user@example.com")
    XCTAssertEqual(state.phone, "+5511999999999")
  }
}
