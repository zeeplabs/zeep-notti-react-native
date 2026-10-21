import UIKit
import XCTest
// Test target compiles the SDK's Swift sources directly (see NottiTests
// Xcode target: ios/*.swift + ios/Tests/*.swift, no CocoaPods module
// dependency) — no import of a "Notti" module needed or possible here.

private final class E2EDirectExecutor: InAppExecutor {
  func execute(_ task: @escaping () -> Void) { task() }
  func schedule(delayMs: Int64, _ task: @escaping () -> Void) {}
}

private final class E2EPresenter: InAppPresenter {
  var presented: [InAppDisplay] = []
  var closed: [String] = []
  func present(_ display: InAppDisplay) { presented.append(display) }
  func close(_ displayId: String) { closed.append(displayId) }
  func teardown(_ display: InAppDisplay) {}
}

private final class E2ELogSink {
  private let lock = NSLock()
  private var lines: [String] = []
  var messages: [String] { lock.lock(); defer { lock.unlock() }; return lines }
  func append(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
}

/// Mirror of `NottiInAppEndToEndTest.kt`: the real core, parser, stores and
/// coordinator wired through the hooks production uses (`NottiInApp.coreHooks`),
/// against a stubbed backend. The coordinator hops to main inline and runs its
/// network work on the calling thread; only the presenter is fake. The stub
/// answers in FIFO order, so each test queues the responses in request order.
final class NottiInAppEndToEndTests: XCTestCase {

  private let appId = "app-1"
  private let clientKey = "client-key-secret"
  private let token = "apns-token-secret"
  private let deviceId = "00000000-0000-0000-0000-0000000000d1"
  private let baseUrl = "https://notti.example.com"

  private var suiteName: String!
  private var defaults: UserDefaults!
  private var sessions: [URLSession] = []
  private var deviceStore: NottiDeviceStore!
  private var pushEvents: NottiEventStore!
  private var presenter: E2EPresenter!
  private var coordinator: NottiInAppCoordinator!
  private var core: NottiCore!
  private var logs: E2ELogSink!
  private var clicks: [InAppClick] = []

  override func setUp() {
    super.setUp()
    StubURLProtocol.reset()
    NottiInApp.resetForTests()
    suiteName = "NottiInAppEndToEndTests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
    deviceStore = NottiDeviceStore(defaults: defaults)
    pushEvents = NottiEventStore(defaults: defaults)
    logs = E2ELogSink()
    clicks = []
    presenter = E2EPresenter()
    coordinator = NottiInAppCoordinator(
      store: NottiInAppEventStore(defaults: defaults),
      clientFactory: { [unowned self] config in
        NottiApiClient(
          session: self.stubSession(), baseUrl: config.baseUrl, appId: config.appId, clientKey: config.clientKey,
          sleeper: { _ in })
      },
      identity: { [unowned self] in
        guard let id = self.deviceStore.getDeviceId(), let lastToken = self.deviceStore.getLastToken() else { return nil }
        return InAppIdentity(deviceId: id, token: lastToken)
      },
      executor: E2EDirectExecutor(),
      postToMain: { $0() },
      logger: { [unowned self] in self.logs.append($0) }
    )
    coordinator.presenter = presenter
    coordinator.clickSink = { [unowned self] click in
      self.clicks.append(click)
      return true
    }
    NottiInApp.install(coordinator)
    core = NottiCore(
      deviceStore: deviceStore,
      eventStore: pushEvents,
      apiClientFactory: { [unowned self] appId, clientKey, baseUrl in
        NottiApiClient(session: self.stubSession(), baseUrl: baseUrl, appId: appId, clientKey: clientKey, sleeper: { _ in })
      },
      tokenProvider: { [unowned self] callback in callback(self.token) },
      permissionRequester: { $0(true) },
      logger: { [unowned self] in self.logs.append($0) },
      inApp: NottiInApp.coreHooks
    )
  }

  override func tearDown() {
    core.invalidate()
    core.waitForPendingWork(timeout: 20)
    for session in sessions { session.invalidateAndCancel() }
    sessions.removeAll()
    NottiInApp.resetForTests()
    defaults.removePersistentDomain(forName: suiteName)
    super.tearDown()
  }

  private func stubSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: config)
    sessions.append(session)
    return session
  }

  // MARK: - Fixtures

  private func sessionStart(_ id: String, extra: String = "") -> String {
    message(id, trigger: #"{"type":"session_start"}"#, extra: extra)
  }

  private func onEvent(_ id: String, _ name: String) -> String {
    message(id, trigger: #"{"type":"event","name":"\#(name)"}"#)
  }

  private func message(_ id: String, trigger: String, extra: String = "") -> String {
    #"{"id":"\#(id)","format":"center","title":"T","body":"B","buttons":[{"id":"b1","label":"Go"}],"trigger":\#(trigger)\#(extra)}"#
  }

  private func eligible(_ entries: String...) -> StubURLProtocol.StubResponse {
    .status(200, body: #"{"messages":[\#(entries.joined(separator: ","))]}"#)
  }

  private let registered = StubURLProtocol.StubResponse.status(200, body: #"{"id":"00000000-0000-0000-0000-0000000000d1","tags":{}}"#)
  private let created = StubURLProtocol.StubResponse.status(201, body: #"{"duplicate":false}"#)

  private func activate() {
    NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
    XCTAssertTrue(core.waitForPendingWork(timeout: 20))
  }

  /// `initialize` as the module runs it: In-App first, then the core.
  private func initialize() {
    coordinator.onInitialized(appId: appId, clientKey: clientKey, baseUrl: baseUrl)
    core.initialize(appId: appId, clientKey: clientKey, baseUrl: baseUrl)
    XCTAssertTrue(core.waitForPendingWork(timeout: 20))
  }

  private func showVisible(_ display: InAppDisplay) {
    coordinator.onDisplayAttached(display.displayId, attached: true)
    coordinator.onDisplayVisible(display.displayId)
  }

  private func requestLog() -> [String] {
    StubURLProtocol.recordedRequests().map { ($0.httpMethod ?? "") + " " + ($0.url?.path ?? "") }
  }

  private func inAppEvents() -> [[String: Any]] {
    StubURLProtocol.recordedRequests()
      .filter { ($0.url?.path ?? "").contains("/in-app-messages/") && ($0.url?.path ?? "").hasSuffix("/events") }
      .compactMap { try? JSONSerialization.jsonObject(with: $0.httpBody ?? Data()) as? [String: Any] }
  }

  // MARK: - Tests

  func test_aSessionRunsRegistrationFlushOneEligibleDisplayImpressionClickAndAHeldTrigger() throws {
    _ = pushEvents.enqueue(notificationId: "n-1", deliveryId: "d-1", type: "received")
    StubURLProtocol.enqueue(registered)
    StubURLProtocol.enqueue(.status(200)) // push event report
    StubURLProtocol.enqueue(eligible(sessionStart("s1"), onEvent("e1", "promo")))

    initialize()
    activate()

    let paths = requestLog()
    let register = try XCTUnwrap(paths.firstIndex { $0.hasPrefix("POST /v1/apps/app-1/devices") }, "\(paths)")
    let pushFlush = try XCTUnwrap(paths.firstIndex { $0.contains("/notifications/") }, "\(paths)")
    let fetch = try XCTUnwrap(paths.firstIndex(of: "POST /v1/apps/app-1/in-app-messages/eligible"), "\(paths)")
    XCTAssertLessThan(register, pushFlush, "\(paths)")
    XCTAssertLessThan(pushFlush, fetch, "\(paths)")
    XCTAssertEqual(paths.filter { $0.hasSuffix("/in-app-messages/eligible") }.count, 1)

    let first = try XCTUnwrap(presenter.presented.first)
    XCTAssertEqual(presenter.presented.count, 1)
    XCTAssertEqual(first.message.id, "s1")
    StubURLProtocol.enqueue(created) // impression
    showVisible(first)
    StubURLProtocol.enqueue(created) // click
    coordinator.onDisplayClicked(first.displayId, buttonId: "b1", action: nil)
    XCTAssertEqual(presenter.closed, [first.displayId])
    XCTAssertEqual(clicks.map(\.messageId), ["s1"])

    coordinator.trackEvent("promo")
    XCTAssertEqual(presenter.presented.map { $0.message.id }, ["s1", "e1"])

    // A second registration or activation in the same session does not refetch.
    coordinator.onRegistered()
    activate()
    XCTAssertEqual(requestLog().filter { $0.hasSuffix("/in-app-messages/eligible") }.count, 1)

    let events = inAppEvents()
    XCTAssertEqual(events.compactMap { $0["type"] as? String }, ["impression", "click"])
    XCTAssertEqual(Set(events.compactMap { $0["event_id"] as? String }).count, 2, "every event has its own id")

    // In-App never touches the device record (SDKIAM-53).
    let afterFetch = Array(requestLog().dropFirst(fetch))
    XCTAssertFalse(afterFetch.contains { $0.hasPrefix("PATCH") && $0.contains("/devices") })

    // No secret, id or event name in any log line (SDKIAM-54).
    let secrets = [clientKey, token, deviceId, "s1\"", "e1\"", "promo", baseUrl]
    for line in logs.messages {
      for secret in secrets { XCTAssertFalse(line.contains(secret), "\(line) leaks \(secret)") }
    }
  }

  func test_aTrackEventRightAfterInitializeBeforeTheFirstSessionShowsTheHeldMessageOnceFetched() {
    StubURLProtocol.enqueue(registered)
    StubURLProtocol.enqueue(eligible(onEvent("e1", "promo")))

    coordinator.onInitialized(appId: appId, clientKey: clientKey, baseUrl: baseUrl)
    coordinator.trackEvent("promo")
    core.initialize(appId: appId, clientKey: clientKey, baseUrl: baseUrl)
    XCTAssertTrue(core.waitForPendingWork(timeout: 20))
    activate()

    XCTAssertEqual(presenter.presented.map { $0.message.id }, ["e1"])
  }

  func test_aTrackEventBeforeInitializeIsNotRemembered() {
    StubURLProtocol.enqueue(registered)
    StubURLProtocol.enqueue(eligible(onEvent("e1", "promo")))

    coordinator.trackEvent("promo")
    initialize()
    activate()

    XCTAssertTrue(presenter.presented.isEmpty)
  }

  func test_reinitializingWithADifferentConfigResetsInAppState() {
    StubURLProtocol.enqueue(registered)
    StubURLProtocol.enqueue(eligible(sessionStart("s1")))
    initialize()
    activate()
    XCTAssertEqual(presenter.presented.map { $0.message.id }, ["s1"])

    coordinator.onInitialized(appId: "app-2", clientKey: clientKey, baseUrl: baseUrl)

    XCTAssertEqual(coordinator.session.config?.appId, "app-2")
    XCTAssertTrue(coordinator.session.heldMessages.isEmpty, "held messages belong to the old app")
    XCTAssertNil(coordinator.session.display, "the visible display belongs to the old app")
  }

  func test_aJSReloadKeepsTheHeldMessagesAndSendsNoSecondEligible() {
    // The reloaded module builds a new core over the same process gate and the
    // same process-wide coordinator: it adopts the open session.
    core.invalidate() // the fixture's core would hear the same notifications
    let gate = NottiCore.SessionGate()
    let first = makeCore(gate: gate)
    StubURLProtocol.enqueue(registered)
    StubURLProtocol.enqueue(eligible(sessionStart("s1"), onEvent("e1", "promo")))
    coordinator.onInitialized(appId: appId, clientKey: clientKey, baseUrl: baseUrl)
    first.initialize(appId: appId, clientKey: clientKey, baseUrl: baseUrl)
    NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
    XCTAssertTrue(first.waitForPendingWork(timeout: 20))
    XCTAssertEqual(presenter.presented.map { $0.message.id }, ["s1"])
    first.invalidate()

    let second = makeCore(gate: gate)
    StubURLProtocol.enqueue(registered)
    coordinator.onInitialized(appId: appId, clientKey: clientKey, baseUrl: baseUrl)
    second.initialize(appId: appId, clientKey: clientKey, baseUrl: baseUrl)
    NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
    XCTAssertTrue(second.waitForPendingWork(timeout: 20))
    second.invalidate()

    XCTAssertEqual(requestLog().filter { $0.hasSuffix("/in-app-messages/eligible") }.count, 1)
    XCTAssertEqual(coordinator.session.heldMessages.map(\.id), ["e1"], "the held event message survives the reload")
    XCTAssertEqual(coordinator.session.shown, ["s1"])
    XCTAssertEqual(presenter.presented.map { $0.message.id }, ["s1"], "the visible display is untouched")
    coordinator.trackEvent("promo")
    // s1 is still on screen, so the held event message waits.
    XCTAssertEqual(presenter.presented.count, 1)
  }

  private func makeCore(gate: NottiCore.SessionGate) -> NottiCore {
    NottiCore(
      deviceStore: deviceStore,
      eventStore: pushEvents,
      apiClientFactory: { [unowned self] appId, clientKey, baseUrl in
        NottiApiClient(session: self.stubSession(), baseUrl: baseUrl, appId: appId, clientKey: clientKey, sleeper: { _ in })
      },
      tokenProvider: { [unowned self] callback in callback(self.token) },
      permissionRequester: { $0(true) },
      logger: { [unowned self] in self.logs.append($0) },
      sessionGate: gate,
      inApp: NottiInApp.coreHooks
    )
  }

  // MARK: - Process observers (installed by NottiImpl)

  /// Building a module registers the process-wide lifecycle observers (static,
  /// once per process). Its own core is torn down at once: only the observers
  /// are under test, and a live second core would hear every notification.
  private func installProcessObservers() {
    let module = NottiImpl()
    module.invalidate()
  }

  func test_theProcessBackgroundObserverEndsTheInAppSessionEvenWithNoLiveCore() {
    core.invalidate()
    installProcessObservers() // no module left: only the process observers remain
    coordinator.onInitialized(appId: appId, clientKey: clientKey, baseUrl: baseUrl)
    coordinator.onSessionStarted()
    XCTAssertTrue(coordinator.session.isOpen)
    XCTAssertTrue(NottiImpl.processSessionGate.tryOpen())

    NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)

    XCTAssertFalse(coordinator.session.isOpen)
    XCTAssertFalse(NottiImpl.processSessionGate.isOpen, "the process gate still closes with no core")
  }

  func test_returningFromBackgroundResumesTheDisplayClockOfTheNextMessage() throws {
    installProcessObservers()
    StubURLProtocol.enqueue(registered)
    StubURLProtocol.enqueue(eligible(sessionStart("s1", extra: #","dismiss_after_seconds":30"#)))
    initialize()

    NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
    NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
    activate()

    let display = try XCTUnwrap(presenter.presented.first)
    StubURLProtocol.enqueue(created) // impression
    showVisible(display)
    XCTAssertEqual(display.clock?.isRunning, true, "foreground signal reached the coordinator")
  }

  func test_aDisplaySelectedWhileTheAppIsInBackgroundHasItsClockPaused() throws {
    installProcessObservers()
    StubURLProtocol.enqueue(registered)
    StubURLProtocol.enqueue(eligible(sessionStart("s1", extra: #","dismiss_after_seconds":30"#)))
    initialize()

    NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
    activate() // no willEnterForeground: the coordinator still believes the app is in background

    let display = try XCTUnwrap(presenter.presented.first)
    StubURLProtocol.enqueue(created) // impression
    showVisible(display)
    XCTAssertEqual(display.clock?.isRunning, false, "the background signal reached the coordinator")
  }
}

/// `NottiImpl` is the call site of `initialize`, `trackEvent`, the lifecycle
/// observers and the core hooks; these cover the wiring itself, with a coordinator
/// that does no network work.
final class NottiInAppWiringTests: XCTestCase {

  private final class NoWorkExecutor: InAppExecutor {
    func execute(_ task: @escaping () -> Void) {}
    func schedule(delayMs: Int64, _ task: @escaping () -> Void) {}
  }

  private var suiteName: String!
  private var defaults: UserDefaults!
  private var modules: [NottiImpl] = []

  override func setUp() {
    super.setUp()
    suiteName = "NottiInAppWiringTests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
    NottiInApp.resetForTests()
    NottiImpl.processSessionGate.close()
  }

  override func tearDown() {
    for module in modules { module.invalidate() }
    modules.removeAll()
    NottiInApp.resetForTests()
    NottiImpl.processSessionGate.close()
    defaults.removePersistentDomain(forName: suiteName)
    super.tearDown()
  }

  private func installCoordinator() -> NottiInAppCoordinator {
    let coordinator = NottiInAppCoordinator(
      store: NottiInAppEventStore(defaults: defaults),
      clientFactory: { NottiApiClient(baseUrl: $0.baseUrl, appId: $0.appId, clientKey: $0.clientKey) },
      identity: { nil },
      executor: NoWorkExecutor(),
      postToMain: { $0() }
    )
    return NottiInApp.install(coordinator)
  }

  private func module() -> NottiImpl {
    let module = NottiImpl()
    modules.append(module)
    return module
  }

  func test_initializeHandsTheNormalizedConfigToInApp() {
    let coordinator = installCoordinator()

    module().initialize("app-1", clientKey: "key", baseUrl: "https://notti.example.com/", sdkVersion: "")

    XCTAssertEqual(coordinator.session.config, InAppConfig(appId: "app-1", clientKey: "key", baseUrl: "https://notti.example.com"))
  }

  func test_initializeWithAnInvalidConfigLeavesInAppWithoutOne() {
    let coordinator = installCoordinator()
    let impl = module()

    impl.initialize("app-1", clientKey: "", baseUrl: "https://notti.example.com", sdkVersion: "")
    impl.initialize("", clientKey: "key", baseUrl: "https://notti.example.com", sdkVersion: "")
    impl.initialize("app-1", clientKey: "key", baseUrl: "not a url", sdkVersion: "")

    XCTAssertNil(coordinator.session.config)
  }

  func test_trackEventForwardsTheNameToInAppSoACallRightAfterInitializeIsKept() {
    let coordinator = installCoordinator()
    let impl = module()

    impl.trackEvent("before-initialize")
    impl.initialize("app-1", clientKey: "key", baseUrl: "https://notti.example.com", sdkVersion: "")
    impl.trackEvent("promo")

    XCTAssertEqual(coordinator.session.pending, ["promo"])
  }

  func test_creatingAModuleInstallsTheInAppCoordinatorWhenNoneExists() {
    XCTAssertNil(NottiInApp.get())

    _ = module()

    XCTAssertNotNil(NottiInApp.get())
  }

  func test_invalidateLeavesTheInAppCoordinatorInstalled() {
    let coordinator = installCoordinator()

    module().invalidate()

    XCTAssertTrue(NottiInApp.get() === coordinator)
  }

  func test_theModulesCoreOpensTheInAppSessionWhenItOpensAForegroundSession() {
    let coordinator = installCoordinator()
    _ = module()

    NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
    XCTAssertTrue(NottiImpl.activeCore?.waitForPendingWork(timeout: 20) ?? true)
    modules.forEach { XCTAssertTrue($0.core.waitForPendingWork(timeout: 20)) }

    XCTAssertTrue(coordinator.session.isOpen)
  }

  func test_setupInstallsOneCoordinatorWithAPresenterAndAClickSinkToTheLiveModule() throws {
    let first = NottiInAppSetup.install(defaults: defaults)
    let second = NottiInAppSetup.install(defaults: defaults)

    XCTAssertTrue(first === second)
    XCTAssertTrue(NottiInApp.get() === first)
    XCTAssertTrue(first.presenter is NottiInAppWindowPresenter)

    var emitted: [[String: Any]] = []
    let live = module()
    live.emitInAppClickHandler = { emitted.append($0) }
    live.activate()
    let sink = try XCTUnwrap(first.clickSink)
    XCTAssertTrue(sink(InAppClick(messageId: "m1", buttonId: "b1", action: nil)))
    XCTAssertEqual(emitted.first?["messageId"] as? String, "m1")
  }
}
