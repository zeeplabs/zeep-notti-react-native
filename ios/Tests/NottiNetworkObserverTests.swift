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

  // MARK: - Process wiring (T25)

  /// Counts the work In-App hands its executor; never runs it (no network).
  private final class CountingExecutor: InAppExecutor {
    private(set) var executed = 0
    func execute(_ task: @escaping () -> Void) { executed += 1 }
    func schedule(delayMs: Int64, _ task: @escaping () -> Void) {}
  }

  private func configuredCoordinator(_ executor: CountingExecutor) -> NottiInAppCoordinator {
    let suite = "NottiNetworkObserverTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
    let coordinator = NottiInAppCoordinator(
      store: NottiInAppEventStore(defaults: defaults),
      clientFactory: { NottiApiClient(baseUrl: $0.baseUrl, appId: $0.appId, clientKey: $0.clientKey) },
      identity: { InAppIdentity(deviceId: "device-1", token: "apns-token") },
      executor: executor,
      postToMain: { $0() }
    )
    coordinator.onInitialized(appId: "app-1", clientKey: "key", baseUrl: "https://example.invalid")
    return coordinator
  }

  func test_regainedConnectivityAlsoReachesInAppWithNoCore() {
    let executor = CountingExecutor()
    let target = configuredCoordinator(executor)
    XCTAssertEqual(executor.executed, 0)

    NottiNetworkObserver.notifyProcess(core: nil, inApp: target)

    XCTAssertEqual(executor.executed, 1, "In-App flushes its own queue even with no core")
  }

  func test_regainedConnectivityWithNoCoordinatorDoesNotTrap() {
    NottiNetworkObserver.notifyProcess(core: nil, inApp: nil)
  }
}
