import Network
import XCTest

final class NottiNetworkObserverTests: XCTestCase {

  private final class FakePathMonitor: NottiPathMonitoring {
    var pathUpdateHandler: ((NWPath.Status) -> Void)?
    private(set) var startCount = 0
    private(set) var cancelCount = 0
    func start(queue: DispatchQueue) { startCount += 1 }
    func cancel() { cancelCount += 1 }
  }

  func test_transitionToSatisfiedTriggersAFlush() {
    let monitor = FakePathMonitor()
    var flushes = 0
    let observer = NottiNetworkObserver(monitor: monitor, onNetworkAvailable: { flushes += 1 })
    observer.start()
    XCTAssertEqual(monitor.startCount, 1)

    monitor.pathUpdateHandler?(.satisfied)
    XCTAssertEqual(flushes, 1, "the first observed satisfied path triggers a flush")

    monitor.pathUpdateHandler?(.satisfied)
    XCTAssertEqual(flushes, 1, "staying satisfied must not re-trigger")

    monitor.pathUpdateHandler?(.unsatisfied)
    monitor.pathUpdateHandler?(.satisfied)
    XCTAssertEqual(flushes, 2, "an offline -> online transition triggers again")
  }

  func test_noSatisfiedTransitionNeverFlushes() {
    let monitor = FakePathMonitor()
    var flushes = 0
    let observer = NottiNetworkObserver(monitor: monitor, onNetworkAvailable: { flushes += 1 })
    observer.start()

    monitor.pathUpdateHandler?(.unsatisfied)
    monitor.pathUpdateHandler?(.requiresConnection)

    XCTAssertEqual(flushes, 0)
  }

  func test_startIsIdempotent() {
    let monitor = FakePathMonitor()
    let observer = NottiNetworkObserver(monitor: monitor, onNetworkAvailable: {})

    observer.start()
    observer.start()

    XCTAssertEqual(monitor.startCount, 1, "a second start must be a no-op")
  }

  func test_cancelStopsTheUnderlyingMonitor() {
    let monitor = FakePathMonitor()
    let observer = NottiNetworkObserver(monitor: monitor, onNetworkAvailable: {})

    observer.start()
    observer.cancel()

    XCTAssertEqual(monitor.cancelCount, 1)
  }
}