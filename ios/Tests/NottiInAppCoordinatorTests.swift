import XCTest
// Test target compiles the SDK's Swift sources directly (see NottiTests
// Xcode target: ios/*.swift + ios/Tests/*.swift, no CocoaPods module
// dependency) — no import of a "Notti" module needed or possible here.

/// Runs work on the test thread; scheduled tasks run when virtual time reaches them.
private final class FakeInAppExecutor: InAppExecutor {
  private let time: () -> Int64
  private let setTime: (Int64) -> Void
  private var immediate: [() -> Void] = []
  private var scheduled: [(at: Int64, seq: Int, task: () -> Void)] = []
  private var seq = 0
  var delays: [Int64] = []

  init(time: @escaping () -> Int64, setTime: @escaping (Int64) -> Void) {
    self.time = time
    self.setTime = setTime
  }

  func execute(_ task: @escaping () -> Void) {
    immediate.append(task)
  }

  func schedule(delayMs: Int64, _ task: @escaping () -> Void) {
    delays.append(delayMs)
    seq += 1
    scheduled.append((time() + delayMs, seq, task))
  }

  func runAll() {
    while !immediate.isEmpty { immediate.removeFirst()() }
  }

  func advance(_ ms: Int64) {
    let target = time() + ms
    runAll()
    while let next = scheduled.filter({ $0.at <= target }).min(by: { ($0.at, $0.seq) < ($1.at, $1.seq) }) {
      scheduled.removeAll { $0.seq == next.seq }
      setTime(next.at)
      next.task()
      runAll()
    }
    setTime(target)
  }
}

private final class FakePresenter: InAppPresenter {
  var presented: [InAppDisplay] = []
  var closed: [String] = []
  var tornDown: [InAppDisplay] = []

  func present(_ display: InAppDisplay) { presented.append(display) }
  func close(_ displayId: String) { closed.append(displayId) }
  func teardown(_ display: InAppDisplay) { tornDown.append(display) }
}

/// Mirror of `NottiInAppCoordinatorTest.kt`: real store and client (over
/// `StubURLProtocol`), fake presenter and executor, no real sleeps.
final class NottiInAppCoordinatorTests: XCTestCase {

  private let deviceId = "00000000-0000-0000-0000-0000000000d1"
  private let token = "apns-token-secret"
  private let clientKey = "client-key-secret"
  private let baseUrl = "https://notti.example.com"

  private var suiteName: String!
  private var defaults: UserDefaults!
  private var sessions: [URLSession] = []
  private var store: NottiInAppEventStore!
  private var executor: FakeInAppExecutor!
  private var presenter: FakePresenter!
  private var coordinator: NottiInAppCoordinator!
  private var logs: [String] = []
  private var clicks: [InAppClick] = []
  private var monotonic: Int64 = 0
  private var wall: Int64 = 1_760_000_000_000
  private var identity: InAppIdentity?
  private var consumed = 0

  override func setUp() {
    super.setUp()
    makeFixture()
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    for session in sessions { session.invalidateAndCancel() }
    sessions.removeAll()
    NottiInApp.resetForTests()
    super.tearDown()
  }

  private func makeFixture() {
    if let suiteName = suiteName { defaults?.removePersistentDomain(forName: suiteName) }
    StubURLProtocol.reset()
    consumed = 0
    logs = []
    clicks = []
    monotonic = 0
    wall = 1_760_000_000_000
    identity = InAppIdentity(deviceId: deviceId, token: token)
    suiteName = "NottiInAppCoordinatorTests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
    store = NottiInAppEventStore(defaults: defaults, clock: { [unowned self] in self.wall })
    executor = FakeInAppExecutor(time: { [unowned self] in self.monotonic }, setTime: { [unowned self] in self.monotonic = $0 })
    presenter = FakePresenter()
    coordinator = makeCoordinator()
    coordinator.presenter = presenter
    coordinator.clickSink = { [unowned self] click in
      self.clicks.append(click)
      return true
    }
  }

  private func makeCoordinator(postToMain: ((@escaping () -> Void) -> Void)? = nil) -> NottiInAppCoordinator {
    NottiInAppCoordinator(
      store: store,
      clientFactory: { [unowned self] config in
        NottiApiClient(
          session: self.stubSession(), baseUrl: config.baseUrl, appId: config.appId, clientKey: config.clientKey,
          sleeper: { _ in })
      },
      identity: { [unowned self] in self.identity },
      executor: executor,
      postToMain: postToMain ?? { $0() },
      monotonicMs: { [unowned self] in self.monotonic },
      logger: { [unowned self] in self.logs.append($0) }
    )
  }

  private func stubSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: config)
    sessions.append(session)
    return session
  }

  // MARK: - Helpers

  private func sessionStart(_ id: String, _ extra: String = "") -> String {
    #"{"id":"\#(id)","title":"T","trigger":{"type":"session_start"}\#(extra)}"#
  }

  private func eventMessage(_ id: String, _ name: String) -> String {
    #"{"id":"\#(id)","title":"T","trigger":{"type":"event","name":"\#(name)"}}"#
  }

  private func messages(_ entries: String...) -> StubURLProtocol.StubResponse {
    .status(200, body: #"{"messages":[\#(entries.joined(separator: ","))]}"#)
  }

  private func status(_ code: Int, retryAfter: String? = nil) -> StubURLProtocol.StubResponse {
    .status(code, body: "{}", headers: retryAfter.map { ["Retry-After": $0] } ?? [:])
  }

  private func enqueue(_ responses: StubURLProtocol.StubResponse...) {
    for response in responses { StubURLProtocol.enqueue(response) }
  }

  private var requestCount: Int { StubURLProtocol.recordedRequests().count }

  private func takeAll() -> [URLRequest] {
    let all = StubURLProtocol.recordedRequests()
    let fresh = Array(all.dropFirst(consumed))
    consumed = all.count
    return fresh
  }

  private func paths(_ requests: [URLRequest]) -> [String] {
    requests.map { request in
      request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedPath } ?? ""
    }
  }

  private func json(_ request: URLRequest) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]) ?? [:]
  }

  /// `registered` stands in for a registration of this process (A6) without its flush trigger.
  private func initialize(_ appId: String = "app-1", registered: Bool = true) {
    coordinator.onInitialized(appId: appId, clientKey: clientKey, baseUrl: baseUrl)
    if registered { coordinator.session.markRegistered() }
  }

  private func startAndRegister() {
    coordinator.onSessionStarted()
    executor.runAll()
  }

  @discardableResult
  private func queuedEvent(_ messageId: String = "old", appId: String = "app-1") -> InAppPendingEvent {
    store.enqueue(appId: appId, messageId: messageId, type: InAppEventType.impression)
  }

  private func eligiblePath(_ appId: String = "app-1") -> String { "/v1/apps/\(appId)/in-app-messages/eligible" }

  private func eventsPath(_ messageId: String, appId: String = "app-1") -> String {
    "/v1/apps/\(appId)/in-app-messages/\(messageId)/events"
  }

  @discardableResult
  private func showVisible(file: StaticString = #filePath, line: UInt = #line) -> InAppDisplay? {
    guard let display = presenter.presented.last else {
      XCTFail("nothing presented", file: file, line: line)
      return nil
    }
    coordinator.onDisplayAttached(display.displayId, attached: true)
    coordinator.onDisplayVisible(display.displayId)
    return display
  }

  // MARK: - Fetch sequence

  func test_queuedEventsAreFlushedBeforeEligibleAndTheFirstSessionStartIsPresented() {
    queuedEvent()
    enqueue(status(201), messages(sessionStart("s1"), sessionStart("s2")))
    initialize()
    startAndRegister()

    XCTAssertEqual(paths(takeAll()), [eventsPath("old"), eligiblePath()])
    XCTAssertEqual(presenter.presented.map(\.message.id), ["s1"])
    XCTAssertTrue(store.all().isEmpty)
  }

  func test_eligibleIsSentOncePerSessionAcrossRegistrationsReloadsAndTrackCalls() {
    enqueue(messages())
    initialize()
    startAndRegister()
    coordinator.onRegistered()
    initialize()
    coordinator.onRegistered()
    coordinator.trackEvent("x")
    executor.runAll()
    XCTAssertEqual(paths(takeAll()), [eligiblePath()])
  }

  func test_aNewSessionFetchesAgain() {
    enqueue(messages(), messages())
    initialize()
    startAndRegister()
    coordinator.onSessionEnded()
    coordinator.onSessionStarted()
    executor.runAll()
    XCTAssertEqual(paths(takeAll()), [eligiblePath(), eligiblePath()])
  }

  func test_eligibleWaitsForTheRegistrationOfThisProcess() {
    enqueue(messages(sessionStart("s1")))
    initialize(registered: false)
    coordinator.onSessionStarted()
    coordinator.onNetworkAvailable()
    executor.runAll()
    XCTAssertEqual(requestCount, 0)
    coordinator.onRegistered()
    executor.runAll()
    XCTAssertEqual(paths(takeAll()), [eligiblePath()])
    XCTAssertEqual(presenter.presented.map(\.message.id), ["s1"])
  }

  func test_theRegistrationOutlivesTheSessionButNotAConfigChange() {
    enqueue(messages(), messages())
    initialize()
    startAndRegister()
    coordinator.onSessionEnded()
    coordinator.onSessionStarted()
    executor.runAll()
    XCTAssertEqual(paths(takeAll()), [eligiblePath(), eligiblePath()])

    enqueue(messages())
    coordinator.onInitialized(appId: "app-2", clientKey: clientKey, baseUrl: baseUrl)
    coordinator.onNetworkAvailable()
    executor.runAll()
    XCTAssertEqual(paths(takeAll()), [])
    coordinator.onRegistered()
    executor.runAll()
    XCTAssertEqual(paths(takeAll()), [eligiblePath("app-2")])
  }

  /// The core reports the session from its work queue, which a retrying
  /// request can hold up: a report arriving after the app left is ignored.
  func test_aLateCoreSessionStartAfterTheAppLeftIsIgnored() {
    enqueue(messages())
    initialize()
    startAndRegister()
    coordinator.onSessionEnded()
    coordinator.onAppBackgrounded()
    coordinator.onSessionStarted()
    executor.runAll()
    XCTAssertFalse(coordinator.session.isOpen)
    XCTAssertEqual(paths(takeAll()), [eligiblePath()])
  }

  func test_returningFromBackgroundOpensTheSessionWithoutWaitingForTheCore() {
    enqueue(messages(), messages())
    initialize()
    startAndRegister()
    coordinator.onSessionEnded()
    coordinator.onAppBackgrounded()
    coordinator.onAppForegrounded()
    executor.runAll()
    XCTAssertTrue(coordinator.session.isOpen)
    XCTAssertEqual(paths(takeAll()), [eligiblePath(), eligiblePath()])
    coordinator.onSessionStarted()
    executor.runAll()
    XCTAssertEqual(requestCount, 2)
  }

  func test_aFirstSessionReportedInBackgroundOpensOnTheNextForeground() {
    enqueue(messages())
    initialize()
    coordinator.onAppBackgrounded()
    coordinator.onSessionStarted()
    executor.runAll()
    XCTAssertFalse(coordinator.session.isOpen)
    coordinator.onAppForegrounded()
    executor.runAll()
    XCTAssertTrue(coordinator.session.isOpen)
    XCTAssertEqual(paths(takeAll()), [eligiblePath()])
  }

  func test_theFirstSessionOfTheProcessStillComesFromTheCore() {
    initialize()
    coordinator.onAppForegrounded()
    executor.runAll()
    XCTAssertFalse(coordinator.session.isOpen)
    XCTAssertEqual(requestCount, 0)
  }

  func test_nilIdentityDefersTheFetchToTheNextTrigger() {
    identity = nil
    initialize()
    startAndRegister()
    XCTAssertEqual(requestCount, 0)
    identity = InAppIdentity(deviceId: deviceId, token: token)
    enqueue(messages())
    coordinator.onRegistered()
    executor.runAll()
    XCTAssertEqual(paths(takeAll()), [eligiblePath()])
  }

  func test_eligibleIsStillSentWhenThePreFetchFlushFailsWith503_429Or403() {
    for code in [503, 429, 403] {
      tearDownFixture()
      makeFixture()
      queuedEvent()
      queuedEvent("second")
      enqueue(status(code), messages())
      initialize()
      startAndRegister()
      XCTAssertEqual(paths(takeAll()), [eventsPath("old"), eligiblePath()], "status \(code)")
      XCTAssertEqual(store.all().count, 2, "status \(code)")
    }
  }

  func test_401InThePreFetchFlushSkipsEligibleAndStopsTheSession() {
    queuedEvent()
    enqueue(status(401))
    initialize()
    startAndRegister()
    XCTAssertEqual(paths(takeAll()), [eventsPath("old")])
    XCTAssertTrue(coordinator.session.keyRejected)
    XCTAssertEqual(coordinator.session.fetch, .gaveUp(transient: false))
    coordinator.onNetworkAvailable()
    executor.runAll()
    XCTAssertEqual(requestCount, 1)
    XCTAssertTrue(logs.contains("Notti.inapp: events failed (HTTP 401)"))
    XCTAssertFalse(logs.contains(NottiInAppCoordinator.inactiveWarning))
    XCTAssertEqual(store.all().count, 1)
  }

  /// The pre-fetch flush is single-attempt: a failure leaves the rest
  /// queued with no backoff retry until the next trigger.
  func test_thePreFetchFlushStillRunsWhileAFullFlushBacksOff() {
    queuedEvent()
    enqueue(status(503), status(201), messages())
    initialize()
    coordinator.onRegistered()
    executor.runAll()
    coordinator.onSessionStarted()
    executor.runAll()
    XCTAssertEqual(paths(takeAll()), [eventsPath("old"), eventsPath("old"), eligiblePath()])
    XCTAssertTrue(store.all().isEmpty)
    executor.advance(60_000)
    XCTAssertEqual(requestCount, 3)
  }

  func test_thePreFetchFlushHonorsAnEvents429Pause() {
    queuedEvent()
    enqueue(status(429, retryAfter: "30"), messages())
    initialize()
    coordinator.onRegistered()
    executor.runAll()
    coordinator.onSessionStarted()
    executor.runAll()
    XCTAssertEqual(paths(takeAll()), [eventsPath("old"), eligiblePath()])
    XCTAssertEqual(store.all().count, 1)
  }

  func test_aFailedPreFetchFlushIsNotRetriedUntilTheNextTrigger() {
    queuedEvent()
    enqueue(status(503), messages(), status(201))
    initialize()
    startAndRegister()
    executor.advance(120_000)
    XCTAssertEqual(paths(takeAll()), [eventsPath("old"), eligiblePath()])
    XCTAssertEqual(store.all().count, 1)
    coordinator.onNetworkAvailable()
    executor.runAll()
    XCTAssertEqual(paths(takeAll()), [eventsPath("old")])
    XCTAssertTrue(store.all().isEmpty)
  }

  // MARK: - eligible failures

  /// A 429 answering a session that already ended must not pause the next
  /// session's fetch (SDKIAM-15).
  func test_aLate429DoesNotPauseTheNextSession() {
    enqueue(status(429, retryAfter: "30"), messages(sessionStart("s1")))
    initialize()
    coordinator.onSessionStarted()
    coordinator.onSessionEnded()
    executor.runAll()
    XCTAssertEqual(requestCount, 1)
    XCTAssertNil(coordinator.session.eligiblePausedUntilMs)
    coordinator.onSessionStarted()
    executor.runAll()
    XCTAssertEqual(requestCount, 2)
    XCTAssertEqual(presenter.presented.map(\.message.id), ["s1"])
  }

  /// A 429 pause still running when the next session opens delays that
  /// session's fetch, never cancels it.
  func test_a429PauseCarriedIntoTheNextSessionFetchesOnceItElapses() {
    enqueue(status(429, retryAfter: "30"), messages(sessionStart("s1")))
    initialize()
    startAndRegister()
    XCTAssertEqual(requestCount, 1)
    executor.advance(10_000)
    coordinator.onSessionEnded()
    coordinator.onSessionStarted()
    executor.runAll()
    XCTAssertEqual(requestCount, 1)
    executor.advance(19_000)
    XCTAssertEqual(requestCount, 1)
    executor.advance(1_000)
    XCTAssertEqual(requestCount, 2)
    XCTAssertEqual(presenter.presented.map(\.message.id), ["s1"])
  }

  func test_eligible429Above60SecondsGivesUpWithNoWaitAndNoSecondRequest() {
    enqueue(status(429, retryAfter: "120"))
    initialize()
    startAndRegister()
    executor.advance(600_000)
    XCTAssertEqual(requestCount, 1)
    XCTAssertEqual(coordinator.session.fetch, .gaveUp(transient: false))
    XCTAssertEqual(executor.delays, [])
  }

  func test_eligible429WithRetryAfter2RetriesAfter2Seconds() {
    enqueue(status(429, retryAfter: "2"), messages(sessionStart("s1")))
    initialize()
    startAndRegister()
    executor.advance(1_999)
    XCTAssertEqual(requestCount, 1)
    executor.advance(1)
    XCTAssertEqual(requestCount, 2)
    XCTAssertEqual(presenter.presented.map(\.message.id), ["s1"])
  }

  func test_eligible429WithoutRetryAfterWaits60SecondsAnd0Waits1Second() {
    enqueue(status(429), status(429, retryAfter: "0"), messages())
    initialize()
    startAndRegister()
    executor.advance(59_999)
    XCTAssertEqual(requestCount, 1)
    executor.advance(1)
    XCTAssertEqual(requestCount, 2)
    executor.advance(1_000)
    XCTAssertEqual(requestCount, 3)
    XCTAssertEqual(executor.delays, [60_000, 1_000])
  }

  func test_eligible429GivesUpAfter3Waits() {
    for _ in 0..<4 { enqueue(status(429, retryAfter: "1")) }
    enqueue(messages())
    initialize()
    startAndRegister()
    executor.advance(60_000)
    XCTAssertEqual(requestCount, 4)
    XCTAssertEqual(coordinator.session.fetch, .gaveUp(transient: false))
    coordinator.onNetworkAvailable()
    executor.runAll()
    XCTAssertEqual(requestCount, 4)
  }

  func test_eligibleTransientFailuresBackOff2_4_8_16ThenGiveUpResumedOnNetwork() {
    for _ in 0..<5 { enqueue(status(503)) }
    enqueue(messages(sessionStart("s1")))
    initialize()
    startAndRegister()
    executor.advance(60_000)
    XCTAssertEqual(requestCount, 5)
    XCTAssertEqual(executor.delays, [2_000, 4_000, 8_000, 16_000])
    XCTAssertEqual(coordinator.session.fetch, .gaveUp(transient: true))
    coordinator.onNetworkAvailable()
    executor.runAll()
    XCTAssertEqual(requestCount, 6)
    XCTAssertEqual(presenter.presented.map(\.message.id), ["s1"])
  }

  func test_eligible401RejectsTheKeyAndLogsOnlyTheGenericLine() {
    enqueue(status(401))
    initialize()
    startAndRegister()
    XCTAssertTrue(coordinator.session.keyRejected)
    XCTAssertEqual(logs, ["Notti.inapp: eligible failed (HTTP 401)"])
    queuedEvent()
    coordinator.onAppForegrounded()
    executor.runAll()
    XCTAssertEqual(requestCount, 1)
  }

  func test_eligible403LogsTheInactiveWarningOncePerSessionAnd422TheGenericLine() {
    enqueue(status(403), status(422))
    initialize()
    startAndRegister()
    coordinator.onSessionEnded()
    coordinator.onSessionStarted()
    executor.runAll()
    XCTAssertEqual(logs, [NottiInAppCoordinator.inactiveWarning, "Notti.inapp: eligible failed (HTTP 422)"])
    coordinator.onNetworkAvailable()
    executor.runAll()
    XCTAssertEqual(requestCount, 2)
  }

  func test_403WarningIsLoggedOncePerSessionPerRoute() {
    queuedEvent()
    enqueue(status(403), status(403), status(403))
    initialize()
    startAndRegister()
    coordinator.onAppForegrounded()
    executor.runAll()
    XCTAssertEqual(requestCount, 3)
    XCTAssertEqual(logs.filter { $0 == NottiInAppCoordinator.inactiveWarning }.count, 2)
  }

  // MARK: - Late responses and config changes

  func test_aResponseArrivingAfterItsSessionEndedIsDiscardedEvenWithANewSessionOpen() {
    enqueue(messages(sessionStart("s1"), eventMessage("e1", "buy")), messages())
    initialize()
    coordinator.onSessionStarted()
    coordinator.onRegistered()
    coordinator.onSessionEnded()
    coordinator.onSessionStarted()
    executor.runAll()
    XCTAssertEqual(requestCount, 2)
    XCTAssertTrue(presenter.presented.isEmpty)
    XCTAssertTrue(coordinator.session.heldMessages.isEmpty)
  }

  func test_differentConfigResetsStateTearsTheDisplayDownSilentlyAndPurgesOtherApps() throws {
    enqueue(messages(sessionStart("s1")), status(201))
    initialize("app-1")
    startAndRegister()
    let display = try XCTUnwrap(showVisible())
    executor.runAll()
    XCTAssertEqual(paths(takeAll()), [eligiblePath(), eventsPath("s1")])
    queuedEvent("stale", appId: "app-1")

    enqueue(messages())
    initialize("app-2")
    executor.runAll()
    XCTAssertEqual(presenter.tornDown.count, 1)
    XCTAssertTrue(presenter.tornDown.first === display)
    XCTAssertTrue(store.all().isEmpty)
    coordinator.onRegistered()
    executor.runAll()
    XCTAssertEqual(paths(takeAll()), [eligiblePath("app-2")])
    XCTAssertFalse(presenter.closed.contains(display.displayId))
  }

  func test_anInFlightEligibleOfTheOldConfigIsDiscarded() {
    enqueue(messages(sessionStart("s1")))
    initialize("app-1")
    coordinator.onSessionStarted()
    coordinator.onRegistered()
    initialize("app-2")
    executor.runAll()
    XCTAssertEqual(requestCount, 1)
    XCTAssertTrue(presenter.presented.isEmpty)
  }

  func test_sameConfigKeepsTheDisplayAndTheFetchState() throws {
    enqueue(messages(sessionStart("s1")))
    initialize()
    startAndRegister()
    let display = try XCTUnwrap(presenter.presented.first)
    XCTAssertEqual(presenter.presented.count, 1)
    initialize()
    executor.runAll()
    XCTAssertTrue(coordinator.session.display === display)
    XCTAssertTrue(presenter.tornDown.isEmpty)
    XCTAssertEqual(coordinator.session.fetch, .done)
  }

  // MARK: - trackEvent

  func test_initializeThenTrackEventBeforeTheFirstSessionMatchesOnceHeldMessagesArrive() {
    enqueue(messages(eventMessage("e1", "checkout")))
    initialize()
    coordinator.trackEvent("checkout")
    startAndRegister()
    XCTAssertEqual(presenter.presented.map(\.message.id), ["e1"])
  }

  /// iOS cold start (T18): `initialize` and `trackEvent` are posted to main
  /// back to back while the app is still `.inactive`; the first session opens
  /// only at `didBecomeActive`. Entry points keep their call order through a
  /// real FIFO poster, so the name lands in the awaiting window.
  func test_coldStartInitializeAndTrackEventPostedBeforeDidBecomeActiveMatchOnce() {
    var mainQueue: [() -> Void] = []
    let drainMain = { while !mainQueue.isEmpty { mainQueue.removeFirst()() } }
    coordinator = makeCoordinator(postToMain: { mainQueue.append($0) })
    coordinator.presenter = presenter
    enqueue(messages(eventMessage("e1", "checkout"), eventMessage("e2", "checkout")))

    initialize()
    coordinator.trackEvent("checkout")
    XCTAssertEqual(mainQueue.count, 2)
    drainMain()
    XCTAssertTrue(coordinator.session.awaitingFirstSession)

    coordinator.onSessionStarted()
    drainMain()
    executor.runAll()
    drainMain()

    XCTAssertEqual(presenter.presented.map(\.message.id), ["e1"])
    XCTAssertEqual(paths(takeAll()), [eligiblePath()])
  }

  func test_aNameTrackedBeforeInitializeNeverMatchesOnColdStart() {
    var mainQueue: [() -> Void] = []
    let drainMain = { while !mainQueue.isEmpty { mainQueue.removeFirst()() } }
    coordinator = makeCoordinator(postToMain: { mainQueue.append($0) })
    coordinator.presenter = presenter
    enqueue(messages(eventMessage("e1", "checkout")))

    coordinator.trackEvent("checkout")
    initialize()
    coordinator.onSessionStarted()
    drainMain()
    executor.runAll()
    drainMain()

    XCTAssertTrue(presenter.presented.isEmpty)
  }

  func test_trackEventBeforeInitializeOrBlankIsANoOp() {
    coordinator.trackEvent("checkout")
    coordinator.trackEvent("  ")
    enqueue(messages(eventMessage("e1", "checkout")))
    initialize()
    startAndRegister()
    coordinator.trackEvent("")
    XCTAssertTrue(presenter.presented.isEmpty)
  }

  func test_trackEventAfterTheResponseShowsTheOldestHeldMatch() {
    enqueue(messages(eventMessage("e1", "buy"), eventMessage("e2", "buy")))
    initialize()
    startAndRegister()
    coordinator.trackEvent("buy")
    XCTAssertEqual(presenter.presented.map(\.message.id), ["e1"])
  }

  // MARK: - Presenter callbacks and events

  func test_impressionThenClickAreSentInOrderAndTheClickReachesTheSink() throws {
    enqueue(
      messages(sessionStart("s1", #","buttons":[{"id":"b1","label":"Go","action":{"type":"url","value":"https://x.test"}}]"#)),
      status(201),
      status(201))
    initialize()
    startAndRegister()
    _ = takeAll()
    let display = try XCTUnwrap(showVisible())
    executor.runAll()
    let action = display.message.buttons.first?.action
    coordinator.onDisplayClicked(display.displayId, buttonId: "b1", action: action)
    executor.runAll()

    let events = takeAll().map(json)
    XCTAssertEqual(events.map { $0["type"] as? String }, ["impression", "click"])
    XCTAssertEqual(events.last?["button_id"] as? String, "b1")
    XCTAssertNil(events.last?["reason"])
    XCTAssertEqual(clicks, [InAppClick(messageId: "s1", buttonId: "b1", action: action)])
    XCTAssertEqual(presenter.closed, [display.displayId])
  }

  func test_secondTapAndALaterDismissOnAClosedDisplayAreIgnored() throws {
    enqueue(messages(sessionStart("s1")))
    initialize()
    startAndRegister()
    let display = try XCTUnwrap(showVisible())
    coordinator.onDisplayClicked(display.displayId, buttonId: "b1", action: nil)
    coordinator.onDisplayClicked(display.displayId, buttonId: "b1", action: nil)
    coordinator.onDisplayDismissed(display.displayId, reason: InAppDismissReason.swipe)
    XCTAssertEqual(store.all().map(\.type), [InAppEventType.impression, InAppEventType.click])
    XCTAssertEqual(clicks.count, 1)
  }

  func test_aClickIsEnqueuedBeforeItIsDeliveredAndDeliveredBeforeTheDisplayCloses() throws {
    var seen: [String] = []
    coordinator.clickSink = { [unowned self] _ in
      seen.append("deliver queued=\(self.store.all().map(\.type)) closed=\(self.presenter.closed.count)")
      return true
    }
    enqueue(messages(sessionStart("s1")))
    initialize()
    startAndRegister()
    let display = try XCTUnwrap(showVisible())
    coordinator.onDisplayClicked(
      display.displayId, buttonId: "b1", action: InAppAction(type: "url", value: "https://x.test"))
    XCTAssertEqual(seen, ["deliver queued=\([InAppEventType.impression, InAppEventType.click]) closed=0"])
    XCTAssertEqual(presenter.closed, [display.displayId])
    XCTAssertFalse(logs.contains(NottiInAppCoordinator.noListenerWarning))
  }

  func test_aPushPermissionTapReportsOneClickClosesTellsTheListenerNilAndRunsThePortOnce() throws {
    var seen: [String] = []
    coordinator.clickSink = { [unowned self] click in
      seen.append("listener action=\(String(describing: click.action)) closed=\(self.presenter.closed.count)")
      return true
    }
    coordinator.pushPermissionPort = { [unowned self] in
      let clicks = self.store.all().filter { $0.type == InAppEventType.click }.count
      seen.append("port closed=\(self.presenter.closed.count) clicks=\(clicks)")
    }
    enqueue(messages(sessionStart("s1")))
    initialize()
    startAndRegister()
    let display = try XCTUnwrap(showVisible())
    let action = InAppAction(type: InAppAction.pushPermissionType, value: "")
    coordinator.onDisplayClicked(display.displayId, buttonId: "b1", action: action)
    coordinator.onDisplayClicked(display.displayId, buttonId: "b1", action: action)

    XCTAssertEqual(seen, ["listener action=nil closed=0", "port closed=1 clicks=1"])
    XCTAssertEqual(presenter.closed, [display.displayId])
    XCTAssertFalse(logs.contains(NottiInAppCoordinator.noListenerWarning))
  }

  func test_aPushPermissionTapStillRunsThePortWithNoListener() throws {
    coordinator.clickSink = nil
    var runs = 0
    coordinator.pushPermissionPort = { runs += 1 }
    enqueue(messages(sessionStart("s1")))
    initialize()
    startAndRegister()
    let display = try XCTUnwrap(showVisible())
    coordinator.onDisplayClicked(
      display.displayId, buttonId: "b1", action: InAppAction(type: InAppAction.pushPermissionType, value: ""))
    XCTAssertEqual(runs, 1)
    XCTAssertEqual(store.all().last?.type, InAppEventType.click)
    XCTAssertEqual(presenter.closed, [display.displayId])
  }

  func test_aLinkClickStillReachesTheListenerWithItsActionAndNeverRunsThePort() throws {
    var runs = 0
    coordinator.pushPermissionPort = { runs += 1 }
    var clicks: [InAppClick] = []
    coordinator.clickSink = { clicks.append($0); return true }
    enqueue(messages(sessionStart("s1")))
    initialize()
    startAndRegister()
    let display = try XCTUnwrap(showVisible())
    coordinator.onDisplayClicked(
      display.displayId, buttonId: "b1", action: InAppAction(type: "url", value: "https://x.test"))
    XCTAssertEqual(runs, 0)
    XCTAssertEqual(clicks.first?.action, InAppAction(type: "url", value: "https://x.test"))
  }

  /// Until the module bridge is wired (T24/T25) there is no default sink:
  /// clicks are still reported and warned (SDKIAM-68).
  func test_aFreshCoordinatorHasNoClickSink() {
    XCTAssertNil(makeCoordinator().clickSink)
  }

  func test_clickWithNoListenerIsStillReportedClosedAndWarned() throws {
    coordinator.clickSink = nil
    enqueue(messages(sessionStart("s1")))
    initialize()
    startAndRegister()
    let display = try XCTUnwrap(showVisible())
    coordinator.onDisplayClicked(display.displayId, buttonId: "image", action: InAppAction(type: "deeplink", value: "app://x"))
    XCTAssertEqual(store.all().last?.type, InAppEventType.click)
    XCTAssertEqual(presenter.closed, [display.displayId])
    XCTAssertTrue(logs.contains(NottiInAppCoordinator.noListenerWarning))
  }

  func test_repeatedVisibleCallbacksEnqueueOneImpression() throws {
    enqueue(messages(sessionStart("s1")))
    initialize()
    startAndRegister()
    let display = try XCTUnwrap(showVisible())
    coordinator.onDisplayVisible(display.displayId)
    coordinator.onDisplayAttached(display.displayId, attached: false)
    coordinator.onDisplayAttached(display.displayId, attached: true)
    coordinator.onDisplayVisible(display.displayId)
    XCTAssertEqual(store.all().filter { $0.type == InAppEventType.impression }.count, 1)
  }

  func test_noClickOrDismissBeforeVisible() throws {
    enqueue(messages(sessionStart("s1")))
    initialize()
    startAndRegister()
    let display = try XCTUnwrap(presenter.presented.first)
    coordinator.onDisplayClicked(display.displayId, buttonId: "b1", action: nil)
    coordinator.onDisplayDismissed(display.displayId, reason: InAppDismissReason.closeButton)
    XCTAssertTrue(store.all().isEmpty)
  }

  func test_autoDismissFiresAfterTheVisibleTimeAndPausesInBackground() throws {
    // Impression and dismiss answered explicitly: an unqueued stub request
    // fails as a network error here (MockWebServer answers 404 on Android).
    enqueue(messages(sessionStart("s1", #","dismiss_after_seconds":5"#)), status(201), status(201))
    initialize()
    startAndRegister()
    let display = try XCTUnwrap(showVisible())
    executor.advance(2_000)
    coordinator.onAppBackgrounded()
    executor.advance(60_000)
    XCTAssertTrue(presenter.closed.isEmpty)
    coordinator.onAppForegrounded()
    executor.advance(2_999)
    XCTAssertTrue(presenter.closed.isEmpty)
    executor.advance(1)
    XCTAssertEqual(presenter.closed, [display.displayId])
    executor.runAll()
    let last = try XCTUnwrap(takeAll().last.map(json))
    XCTAssertEqual(last["type"] as? String, "dismiss")
    XCTAssertEqual(last["reason"] as? String, InAppDismissReason.auto)
    XCTAssertNil(last["button_id"])
  }

  // MARK: - Event flush

  func test_events429PausesTheFlushWithTheClampAndSharesTheDeadline() {
    let cases: [(String?, Int64)] = [("0", 1_000), ("1000", 300_000), (nil, 60_000), ("abc", 60_000)]
    for (header, expected) in cases {
      tearDownFixture()
      makeFixture()
      initialize()
      queuedEvent()
      enqueue(status(429, retryAfter: header), status(201), status(201))
      coordinator.onRegistered()
      executor.runAll()
      XCTAssertEqual(requestCount, 1)
      queuedEvent("new")
      coordinator.onNetworkAvailable()
      executor.runAll()
      XCTAssertEqual(requestCount, 1, "header \(String(describing: header))")
      executor.advance(expected - 1)
      XCTAssertEqual(requestCount, 1, "header \(String(describing: header))")
      executor.advance(1)
      XCTAssertGreaterThanOrEqual(requestCount, 2, "header \(String(describing: header))")
    }
  }

  func test_eventsTransientRetriesTheSameHeadWithTheSameEventId() {
    let event = queuedEvent()
    enqueue(status(503), status(503), status(201))
    initialize()
    coordinator.onRegistered()
    executor.advance(10_000)
    let ids = takeAll().map { json($0)["event_id"] as? String }
    XCTAssertEqual(ids, [event.eventId, event.eventId, event.eventId])
    XCTAssertEqual(executor.delays, [2_000, 4_000])
    XCTAssertTrue(store.all().isEmpty)
  }

  func test_eventsTransientStopsAfter5AttemptsAndKeepsTheQueue() {
    queuedEvent()
    for _ in 0..<5 { enqueue(status(500)) }
    initialize()
    coordinator.onRegistered()
    executor.advance(120_000)
    XCTAssertEqual(requestCount, 5)
    XCTAssertEqual(store.all().count, 1)
  }

  /// Unlike OkHttp, URLSession never re-sends a 408 on its own.
  func test_events408FollowsTheTransientPolicy() {
    queuedEvent()
    enqueue(status(408), status(201))
    initialize()
    coordinator.onRegistered()
    executor.advance(2_000)
    XCTAssertEqual(requestCount, 2)
    XCTAssertEqual(executor.delays, [2_000])
    XCTAssertTrue(store.all().isEmpty)
  }

  func test_200Duplicate404And422RemoveTheHeadAndContinue() {
    queuedEvent("a")
    queuedEvent("b")
    queuedEvent("c")
    enqueue(.status(200, body: #"{"duplicate":true}"#), status(404), status(422))
    initialize()
    coordinator.onRegistered()
    executor.runAll()
    XCTAssertEqual(paths(takeAll()), [eventsPath("a"), eventsPath("b"), eventsPath("c")])
    XCTAssertTrue(store.all().isEmpty)
  }

  func test_eventsOlderThan7DaysAreNeverSent() {
    queuedEvent("old")
    wall += 8 * 24 * 60 * 60 * 1000
    queuedEvent("fresh")
    enqueue(status(201))
    initialize()
    coordinator.onRegistered()
    executor.runAll()
    XCTAssertEqual(paths(takeAll()), [eventsPath("fresh")])
  }

  func test_events403StopsTheFlushKeepsTheQueueAndALaterTriggerRetries() {
    queuedEvent()
    enqueue(status(403), status(201))
    initialize()
    coordinator.onRegistered()
    executor.runAll()
    XCTAssertEqual(store.all().count, 1)
    coordinator.onNetworkAvailable()
    executor.runAll()
    XCTAssertTrue(store.all().isEmpty)
  }

  func test_recordsOfAnotherAppAreNeverSent() {
    queuedEvent("other", appId: "app-9")
    queuedEvent("mine")
    enqueue(status(201))
    initialize()
    coordinator.onRegistered()
    executor.runAll()
    XCTAssertEqual(paths(takeAll()), [eventsPath("mine")])
    XCTAssertTrue(store.all().isEmpty)
  }

  func test_aTriggerDuringARunningFlushAsksForOneMorePass() {
    queuedEvent("a")
    enqueue(status(503), status(201), status(201))
    initialize()
    coordinator.onRegistered()
    executor.runAll()
    queuedEvent("b")
    coordinator.onNetworkAvailable()
    executor.runAll()
    XCTAssertEqual(requestCount, 1)
    executor.advance(2_000)
    XCTAssertEqual(paths(takeAll()), [eventsPath("a"), eventsPath("a"), eventsPath("b")])
  }

  /// A trigger while a flush is running is coalesced into one more pass
  /// that starts as soon as the running one ends, even after it failed.
  func test_aTriggerDuringAFlushThatEndsInFailureStartsOneMorePass() {
    queuedEvent("a")
    for _ in 0..<5 { enqueue(status(500)) }
    enqueue(status(201))
    initialize()
    coordinator.onRegistered()
    executor.runAll()
    coordinator.onNetworkAvailable()
    coordinator.onNetworkAvailable()
    executor.advance(30_000)
    XCTAssertEqual(requestCount, 6)
    XCTAssertTrue(store.all().isEmpty)
  }

  /// A flush in backoff when the config changes ends there, then runs the
  /// pass a trigger asked for.
  func test_aTriggerDuringAFlushCutByAConfigChangeFlushesTheNewApp() {
    queuedEvent("a")
    enqueue(status(503))
    initialize("app-1")
    coordinator.onRegistered()
    executor.runAll()
    initialize("app-2")
    executor.runAll()
    queuedEvent("b", appId: "app-2")
    enqueue(status(201))
    coordinator.onNetworkAvailable()
    executor.runAll()
    XCTAssertEqual(requestCount, 1)
    executor.advance(2_000)
    XCTAssertEqual(paths(takeAll()), [eventsPath("a"), eventsPath("b", appId: "app-2")])
    XCTAssertTrue(store.all().isEmpty)
  }

  // MARK: - Privacy

  func test_requestsAreOnlyInAppPostsAndLogsCarryNoIdentifiers() throws {
    queuedEvent("msg-secret-id")
    enqueue(status(503), messages(eventMessage("e-secret", "secret-event-name")), status(403))
    initialize()
    coordinator.trackEvent("secret-event-name")
    startAndRegister()
    let display = try XCTUnwrap(presenter.presented.first)
    coordinator.onDisplayAttached(display.displayId, attached: true)
    coordinator.onDisplayVisible(display.displayId)
    coordinator.clickSink = nil
    coordinator.onDisplayClicked(
      display.displayId, buttonId: "secret-button", action: InAppAction(type: "url", value: "https://secret.test"))
    executor.advance(600_000)

    let requests = takeAll()
    XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "POST" && ($0.url?.path.contains("/in-app-messages/") ?? false) })
    XCTAssertFalse(requests.contains { $0.url?.path.contains("/devices") ?? false })
    let forbidden = [
      token, deviceId, clientKey, "msg-secret-id", "e-secret", "secret-event-name", "secret-button",
      "https://secret.test", baseUrl,
    ]
    for line in logs {
      for value in forbidden { XCTAssertFalse(line.contains(value), "\(line) leaks \(value)") }
    }
    XCTAssertFalse(logs.isEmpty)
  }

  func test_identityNeverPrintsItsSecrets() {
    let value = InAppIdentity(deviceId: deviceId, token: token)
    for text in [String(describing: value), String(reflecting: value), "\(value)"] {
      XCTAssertFalse(text.contains(token))
      XCTAssertFalse(text.contains(deviceId))
    }
  }

  // MARK: - Holder

  func test_holderKeepsTheFirstCoordinator() {
    let first = NottiInApp.install(coordinator)
    let other = makeCoordinator()
    XCTAssertTrue(NottiInApp.install(other) === first)
    XCTAssertTrue(NottiInApp.get() === coordinator)
    NottiInApp.resetForTests()
    XCTAssertNil(NottiInApp.get())
    XCTAssertTrue(NottiInApp.install(other) === other)
  }

  func test_coreHooksForwardToTheInstalledCoordinator() {
    enqueue(messages())
    initialize()
    NottiInApp.coreHooks.onSessionStarted()
    executor.runAll()
    XCTAssertEqual(requestCount, 0)
    NottiInApp.install(coordinator)
    NottiInApp.coreHooks.onSessionStarted()
    executor.runAll()
    XCTAssertEqual(paths(takeAll()), [eligiblePath()])
  }

  private func tearDownFixture() {
    defaults.removePersistentDomain(forName: suiteName)
  }
}
