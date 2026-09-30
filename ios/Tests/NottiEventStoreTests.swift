import XCTest
// Test target compiles the SDK's Swift sources directly (see NottiTests
// Xcode target: ios/*.swift + ios/Tests/*.swift, no CocoaPods module
// dependency) — no import of a "Notti" module needed or possible here.

final class NottiEventStoreTests: XCTestCase {

  private var suiteName: String!
  private var defaults: UserDefaults!
  private var store: NottiEventStore!

  override func setUp() {
    super.setUp()
    suiteName = "NottiEventStoreTests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
    store = NottiEventStore(defaults: defaults)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    super.tearDown()
  }

  func test_enqueueReturnsTheRecordAndAllContainsIt() {
    let event = store.enqueue(notificationId: "notif-1", deliveryId: "delivery-1", type: "received")

    XCTAssertFalse(event.id.isEmpty)
    XCTAssertEqual(store.all().count, 1)
    XCTAssertEqual(store.all().first?.id, event.id)
    XCTAssertEqual(store.all().first?.notificationId, "notif-1")
    XCTAssertEqual(store.all().first?.deliveryId, "delivery-1")
    XCTAssertEqual(store.all().first?.type, "received")
    XCTAssertGreaterThan(store.all().first?.createdAtMs ?? 0, 0)
  }

  func test_removeDropsTheRecordFromAll() {
    let event = store.enqueue(notificationId: "notif-1", deliveryId: "delivery-1", type: "clicked")
    XCTAssertEqual(store.all().count, 1)

    store.remove(id: event.id)

    XCTAssertTrue(store.all().isEmpty)
  }

  func test_enqueuePastCapDropsTheOldestRecord() {
    for index in 0..<33 {
      store.enqueue(notificationId: "notif-\(index)", deliveryId: "delivery-\(index)", type: "received")
    }

    let all = store.all()
    XCTAssertEqual(all.count, 32)
    XCTAssertFalse(all.contains { $0.notificationId == "notif-0" })
    XCTAssertTrue(all.contains { $0.notificationId == "notif-32" })
    XCTAssertEqual(all.first?.notificationId, "notif-1")
    XCTAssertEqual(all.last?.notificationId, "notif-32")
  }

  func test_freshStoreOverSameDefaultsSeesPreviouslyEnqueuedEvents() {
    store.enqueue(notificationId: "notif-1", deliveryId: "delivery-1", type: "received")
    store.enqueue(notificationId: "notif-2", deliveryId: "delivery-2", type: "clicked")

    let reloadedStore = NottiEventStore(defaults: defaults)
    let all = reloadedStore.all()

    XCTAssertEqual(all.count, 2)
    XCTAssertEqual(all.first?.notificationId, "notif-1")
    XCTAssertEqual(all.last?.notificationId, "notif-2")
  }
}