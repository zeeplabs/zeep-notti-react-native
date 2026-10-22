import XCTest
// Test target compiles the SDK's Swift sources directly (see NottiTests
// Xcode target: ios/*.swift + ios/Tests/*.swift, no CocoaPods module
// dependency) — no import of a "Notti" module needed or possible here.

/// Mirror of `NottiInAppEventStoreTest.kt`. Fixtures use only synthetic
/// values (all-zero UUIDs).
final class NottiInAppEventStoreTests: XCTestCase {

  private let appId = "00000000-0000-0000-0000-0000000000a1"
  private let otherApp = "00000000-0000-0000-0000-0000000000a2"
  private let messageId = "00000000-0000-0000-0000-0000000000b1"
  private let day: Int64 = 24 * 60 * 60 * 1000
  private let key = "notti_pending_inapp_events"

  private var suiteName: String!
  private var defaults: UserDefaults!
  private var now: Int64 = 1_000_000_000_000
  private var store: NottiInAppEventStore!

  override func setUp() {
    super.setUp()
    suiteName = "NottiInAppEventStoreTests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
    now = 1_000_000_000_000
    store = makeStore()
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    super.tearDown()
  }

  private func makeStore() -> NottiInAppEventStore {
    NottiInAppEventStore(defaults: defaults, clock: { [unowned self] in self.now })
  }

  func test_enqueuePersistsTheFullRecordAndNoTokenOrDeviceId() throws {
    let event = store.enqueue(appId: appId, messageId: messageId, type: InAppEventType.click, buttonId: "btn")

    let stored = try XCTUnwrap(store.all().first)
    XCTAssertEqual(store.all().count, 1)
    XCTAssertEqual(stored, event)
    XCTAssertEqual(stored.appId, appId)
    XCTAssertEqual(stored.messageId, messageId)
    XCTAssertEqual(stored.type, "click")
    XCTAssertEqual(stored.buttonId, "btn")
    XCTAssertNil(stored.reason)
    XCTAssertEqual(stored.occurredAtMs, now)
    let raw = String(decoding: try XCTUnwrap(defaults.data(forKey: key)), as: UTF8.self)
    XCTAssertFalse(raw.contains("token"))
    XCTAssertFalse(raw.contains("device"))
  }

  func test_dismissKeepsItsReasonAndImpressionHasNeitherButtonNorReason() {
    store.enqueue(appId: appId, messageId: messageId, type: InAppEventType.dismiss, reason: "close_button")
    store.enqueue(appId: appId, messageId: messageId, type: InAppEventType.impression)

    let events = store.all()
    XCTAssertEqual(events.count, 2)
    XCTAssertEqual(events.first?.reason, "close_button")
    XCTAssertNil(events.last?.buttonId)
    XCTAssertNil(events.last?.reason)
  }

  func test_eventIdsAreUniqueUUIDsStableAcrossReadsAndAcrossANewInstance() {
    let first = makeStore().enqueue(appId: appId, messageId: messageId, type: "impression")
    let second = store.enqueue(appId: appId, messageId: messageId, type: "impression")

    XCTAssertNotEqual(first.eventId, second.eventId)
    XCTAssertNotEqual(first.id, second.id)
    XCTAssertEqual(first.eventId.count, 36)
    XCTAssertEqual(Array(first.eventId)[14], "4")
    XCTAssertEqual(first.eventId, first.eventId.lowercased())
    let reread = makeStore().all()
    XCTAssertEqual(reread.map(\.eventId), [first.eventId, second.eventId])
    XCTAssertEqual(store.all().map(\.eventId), reread.map(\.eventId))
  }

  func test_allReturnsInsertionOrderAndRemoveDeletesOnlyThatRecord() {
    let a = store.enqueue(appId: appId, messageId: "m1", type: "impression")
    let b = store.enqueue(appId: appId, messageId: "m2", type: "impression")
    let c = store.enqueue(appId: appId, messageId: "m3", type: "impression")
    XCTAssertEqual(store.all().map(\.id), [a.id, b.id, c.id])

    store.remove(id: b.id)

    XCTAssertEqual(store.all().map(\.id), [a.id, c.id])
  }

  func test_capOf100DropsTheOldestFirst() {
    let ids = (0..<101).map { store.enqueue(appId: appId, messageId: "m\($0)", type: "impression").id }

    let stored = store.all()
    XCTAssertEqual(stored.count, 100)
    XCTAssertEqual(stored.map(\.id), Array(ids.dropFirst()))
  }

  func test_expireDropsOnlyTheEventsOlderThan7DaysAndReturnsThem() {
    let old = store.enqueue(appId: appId, messageId: "old", type: "impression")
    now += day
    let recent = store.enqueue(appId: appId, messageId: "recent", type: "impression")

    let dropped = store.expire(now: old.occurredAtMs + 7 * day + 1)

    XCTAssertEqual(dropped.map(\.id), [old.id])
    XCTAssertEqual(store.all().map(\.id), [recent.id])
  }

  func test_anEventExactly7DaysOldIsKeptAndOneMillisecondOlderIsDropped() {
    let event = store.enqueue(appId: appId, messageId: messageId, type: "impression")

    XCTAssertTrue(store.expire(now: event.occurredAtMs + 7 * day).isEmpty)
    XCTAssertEqual(store.all().count, 1)
    XCTAssertEqual(store.expire(now: event.occurredAtMs + 7 * day + 1).map(\.id), [event.id])
    XCTAssertTrue(store.all().isEmpty)
  }

  func test_expireWithoutAnArgumentUsesTheClock() {
    let event = store.enqueue(appId: appId, messageId: messageId, type: "impression")
    now += 7 * day + 1

    XCTAssertEqual(store.expire().map(\.id), [event.id])
  }

  func test_enqueueDropsEventsThatAlreadyExpired() {
    store.enqueue(appId: appId, messageId: "old", type: "impression")
    now += 7 * day + 1

    let fresh = store.enqueue(appId: appId, messageId: "fresh", type: "impression")

    XCTAssertEqual(store.all().map(\.id), [fresh.id])
  }

  func test_aCorruptBlobSelfHealsToEmptyAndTheQueueWorksAgain() {
    defaults.set(Data("not json".utf8), forKey: key)
    XCTAssertTrue(store.all().isEmpty)
    XCTAssertNil(defaults.object(forKey: key))

    defaults.set(Data(#"[{"id": "x"}]"#.utf8), forKey: key)
    XCTAssertTrue(store.all().isEmpty)
    XCTAssertNil(defaults.object(forKey: key))

    // iOS-only: a value of the wrong type under the key heals the same way.
    defaults.set("not data", forKey: key)
    XCTAssertTrue(store.all().isEmpty)
    XCTAssertNil(defaults.object(forKey: key))

    store.enqueue(appId: appId, messageId: messageId, type: "impression")
    XCTAssertEqual(store.all().count, 1)
  }

  func test_purgeOtherAppsRemovesRecordsOfOtherAppsAndKeepsTheOrderOfTheRest() {
    let a1 = store.enqueue(appId: appId, messageId: "m1", type: "impression")
    store.enqueue(appId: otherApp, messageId: "m2", type: "impression")
    let a2 = store.enqueue(appId: appId, messageId: "m3", type: "click", buttonId: "b")
    store.enqueue(appId: otherApp, messageId: "m4", type: "dismiss", reason: "auto")

    store.purgeOtherApps(appId)

    XCTAssertEqual(store.all().map(\.id), [a1.id, a2.id])
  }

  func test_allForAppNeverReturnsAnotherAppsRecords() {
    let mine = store.enqueue(appId: appId, messageId: "m1", type: "impression")
    store.enqueue(appId: otherApp, messageId: "m2", type: "impression")

    XCTAssertEqual(store.all(forApp: appId).map(\.id), [mine.id])
    XCTAssertEqual(store.all(forApp: otherApp).count, 1)
    XCTAssertTrue(store.all(forApp: "unknown").isEmpty)
  }

  func test_appIdRoundTripsThroughANewInstance() {
    store.enqueue(appId: otherApp, messageId: messageId, type: "impression")

    XCTAssertEqual(makeStore().all().map(\.appId), [otherApp])
  }

  func test_fillingTheInAppQueueNeverEvictsThePushEventQueueAndViceVersa() {
    let push = NottiEventStore(defaults: defaults)
    _ = push.enqueue(notificationId: "notif", deliveryId: "delivery", type: "received")
    for i in 0..<101 { store.enqueue(appId: appId, messageId: "m\(i)", type: "impression") }
    XCTAssertEqual(push.all().count, 1)
    XCTAssertEqual(store.all().count, 100)

    for i in 0..<40 { _ = push.enqueue(notificationId: "n\(i)", deliveryId: "d\(i)", type: "received") }
    XCTAssertEqual(push.all().count, 32)
    XCTAssertEqual(store.all().count, 100)
  }
}
