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

  func test_corruptedPersistedDataReadsAsAnEmptyQueueAndIsRecoverable() {
    defaults.set(Data("not json".utf8), forKey: "notti_pending_events")

    XCTAssertEqual(store.all().count, 0, "an undecodable queue must read as [] instead of crashing")

    _ = store.enqueue(notificationId: "notif-1", deliveryId: "delivery-1", type: "received")
    XCTAssertEqual(store.all().count, 1, "the store must recover by overwriting the corrupted value")
  }

  func test_concurrentEnqueueRemoveAndReadNeverLoseOrCorruptRecords() {
    // Detection sites (main thread / notification delegate) enqueue while the
    // core's work queue reads and removes: every mutation is a
    // read-modify-write of one UserDefaults key, so without the lock records
    // would be lost. 4 writers x 8 enqueues stays at the 32-record cap.
    let writers = 4
    let perWriter = 8
    DispatchQueue.concurrentPerform(iterations: writers * 2) { index in
      if index < writers {
        for item in 0..<perWriter {
          _ = self.store.enqueue(notificationId: "n-\(index)-\(item)", deliveryId: "d", type: "received")
        }
      } else {
        for _ in 0..<perWriter {
          _ = self.store.all()
          self.store.remove(id: "does-not-exist")
        }
      }
    }

    let all = store.all()
    XCTAssertEqual(all.count, writers * perWriter, "no enqueue may be lost under concurrency")
    XCTAssertEqual(Set(all.map(\.id)).count, all.count)

    DispatchQueue.concurrentPerform(iterations: all.count) { index in
      self.store.remove(id: all[index].id)
    }
    XCTAssertTrue(store.all().isEmpty, "no remove may be lost under concurrency")
  }
}
