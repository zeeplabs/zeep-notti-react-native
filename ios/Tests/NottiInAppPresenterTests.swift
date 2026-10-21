import XCTest
#if canImport(UIKit)
import UIKit
#endif
// Test target compiles the SDK's Swift sources directly (see NottiTests
// Xcode target: ios/*.swift + ios/Tests/*.swift, no CocoaPods module
// dependency) — no import of a "Notti" module needed or possible here.

#if canImport(UIKit)
private final class FakeScenes: InAppSceneProviding {
  var target: InAppWindowTarget? = .screen(CGRect(x: 0, y: 0, width: 393, height: 852))
  var isAppActive = true
  func activeTarget() -> InAppWindowTarget? { target }
}

private final class FakeHost: InAppWindowHosting {
  var root: InAppOverlayView?
  var onLayout: (() -> Void)?
  var hidden = false
  var sceneKey: AnyObject?

  func show(_ root: InAppOverlayView, onLayout: @escaping () -> Void) {
    self.root = root
    self.onLayout = onLayout
  }

  func hide() { hidden = true }

  /// What the real window does on a layout pass.
  func layout() {
    root?.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
    root?.layoutIfNeeded()
    onLayout?()
  }
}

private final class ManualImages: InAppImageSource {
  var loads = 0
  private var pending: ((UIImage?) -> Void)?

  func load(url: String, maxSidePx: CGFloat, done: @escaping (UIImage?) -> Void) {
    loads += 1
    pending = done
  }

  func deliver(_ image: UIImage?) { pending?(image) }
}

private final class RecordingEvents: InAppDisplayEvents {
  var log: [String] = []
  func onDisplayAttached(_ displayId: String, attached: Bool) { log.append("attached:\(attached)") }
  func onDisplayVisible(_ displayId: String) { log.append("visible") }
  func onDisplayClicked(_ displayId: String, buttonId: String, action: InAppAction?) { log.append("click:\(buttonId)") }
  func onDisplayDismissed(_ displayId: String, reason: String) { log.append("dismiss:\(reason)") }
  func onDisplayFailed(_ displayId: String) { log.append("failed") }
}

private final class VirtualExecutor: InAppExecutor {
  private let time: () -> Int64
  private let setTime: (Int64) -> Void
  private var scheduled: [(at: Int64, seq: Int, task: () -> Void)] = []
  private var seq = 0

  init(time: @escaping () -> Int64, setTime: @escaping (Int64) -> Void) {
    self.time = time
    self.setTime = setTime
  }

  // Work runs inline; no client is reachable in these tests (no identity).
  func execute(_ task: @escaping () -> Void) { task() }

  func schedule(delayMs: Int64, _ task: @escaping () -> Void) {
    seq += 1
    scheduled.append((time() + delayMs, seq, task))
  }

  func advance(_ ms: Int64) {
    let target = time() + ms
    while let next = scheduled.filter({ $0.at <= target }).min(by: { ($0.at, $0.seq) < ($1.at, $1.seq) }) {
      scheduled.removeAll { $0.seq == next.seq }
      setTime(next.at)
      next.task()
    }
    setTime(target)
  }
}

/// Mirror of `NottiInAppPresenterTest.kt` for what is testable without a real
/// window: a fake scene provider and window host drive the lifecycle; the
/// real `UIWindow` behavior is validated on device (T30).
final class NottiInAppPresenterTests: XCTestCase {

  private var center: NotificationCenter!
  private var scenes: FakeScenes!
  private var hosts: [FakeHost] = []
  private var announced: [InAppFormat] = []
  private var images: ManualImages!
  /// Waits the presenter scheduled: delay and task, in order; cancelled ones are dropped.
  private var waits: [(id: Int, delay: TimeInterval, task: () -> Void)] = []
  private var waitId = 0
  private var events: RecordingEvents!
  private var presenter: NottiInAppWindowPresenter!

  // Real coordinator fixture for the impression and clock cases.
  private var suiteName: String!
  private var defaults: UserDefaults!
  private var store: NottiInAppEventStore!
  private var monotonic: Int64 = 0
  private var executor: VirtualExecutor!
  private var coordinator: NottiInAppCoordinator!

  override func setUp() {
    super.setUp()
    center = NotificationCenter()
    scenes = FakeScenes()
    hosts = []
    announced = []
    images = ManualImages()
    waits = []
    events = RecordingEvents()
    presenter = makePresenter(events: events)
  }

  override func tearDown() {
    if let suiteName = suiteName { defaults.removePersistentDomain(forName: suiteName) }
    NottiInApp.resetForTests()
    super.tearDown()
  }

  private func makePresenter(events: InAppDisplayEvents) -> NottiInAppWindowPresenter {
    NottiInAppWindowPresenter(
      events: events,
      scenes: scenes,
      makeHost: { [unowned self] _ in
        let host = FakeHost()
        self.hosts.append(host)
        return host
      },
      announce: { [unowned self] _, format in self.announced.append(format) },
      images: images,
      schedule: { [unowned self] delay, task in
        self.waitId += 1
        let id = self.waitId
        self.waits.append((id, delay, task))
        return { [unowned self] in self.waits.removeAll { $0.id == id } }
      },
      center: center
    )
  }

  private func makeCoordinator() {
    suiteName = "NottiInAppPresenterTests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
    store = NottiInAppEventStore(defaults: defaults, clock: { 1_760_000_000_000 })
    monotonic = 0
    executor = VirtualExecutor(time: { [unowned self] in self.monotonic }, setTime: { [unowned self] in self.monotonic = $0 })
    coordinator = NottiInAppCoordinator(
      store: store,
      clientFactory: { config in
        NottiApiClient(session: URLSession(configuration: .ephemeral), baseUrl: config.baseUrl, appId: config.appId,
                       clientKey: config.clientKey, sleeper: { _ in })
      },
      identity: { nil },
      executor: executor,
      postToMain: { $0() },
      monotonicMs: { [unowned self] in self.monotonic }
    )
    presenter = makePresenter(events: coordinator)
    coordinator.presenter = presenter
    coordinator.onInitialized(appId: "app", clientKey: "key", baseUrl: "https://api.test")
    coordinator.onSessionStarted()
  }

  private func message(_ format: String = "center", extra: String = "") -> String {
    #"{"id":"m1","format":"\#(format)","title":"T","trigger":{"type":"session_start"}\#(extra)}"#
  }

  /// A display from a real session, the way the coordinator gets one.
  private func display(_ format: String = "center", extra: String = "") -> InAppDisplay {
    let session = coordinator?.session ?? NottiInAppSession(monotonicMs: { 0 })
    if coordinator == nil { session.onSessionStarted() }
    let generation = session.tryStartFetch()!
    let raw = #"{"messages":[\#(message(format, extra: extra))]}"#
    guard case .show(let shown) = session.onFetched(generation: generation, messages: parseEligibleResponse(Data(raw.utf8))!) else {
      fatalError("no display")
    }
    return shown
  }

  /// Presents through the coordinator's own path (impression bookkeeping included).
  private func show(_ format: String = "center", extra: String = "") -> InAppDisplay {
    let shown = display(format, extra: extra)
    presenter.present(shown)
    return shown
  }

  private func types() -> [String] {
    store.all().map { event in event.reason.map { "\(event.type):\($0)" } ?? event.type }
  }

  // MARK: Image (SDKIAM-20, SDKIAM-35, SDKIAM-57)

  private let withImage = #","image_url":"https://img.example.invalid/a.png","image_action":{"type":"deeplink","value":"app://promo"}"#

  private func picture() -> UIImage {
    UIGraphicsImageRenderer(size: CGSize(width: 40, height: 20)).image { context in
      UIColor.red.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
    }
  }

  /// Lets the presenter's `DispatchQueue.main.async` hops run.
  private func drainMain() {
    let drained = expectation(description: "main drained")
    DispatchQueue.main.async { drained.fulfill() }
    wait(for: [drained], timeout: 5)
  }

  private func fireWait() {
    let due = waits
    waits.removeAll()
    for item in due { item.task() }
  }

  func testALoadedImageIsShownAndTappable() throws {
    show(extra: withImage)
    XCTAssertTrue(hosts.isEmpty)
    XCTAssertEqual(images.loads, 1)
    images.deliver(picture())
    drainMain()
    let image = try XCTUnwrap(hosts[0].root?.card.image)
    XCTAssertTrue(image.isUserInteractionEnabled)
    hosts[0].layout()
    XCTAssertEqual(events.log, ["attached:true", "visible"])
    XCTAssertTrue(waits.isEmpty, "the wait is cancelled once the image arrived")
  }

  func testAnActivationDuringTheWaitDoesNotShowTheMessageWithoutItsImage() {
    show(extra: withImage)
    center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
    center.post(name: UIScene.didActivateNotification, object: nil)
    XCTAssertTrue(hosts.isEmpty)
    images.deliver(picture())
    drainMain()
    XCTAssertEqual(hosts.count, 1)
    XCTAssertNotNil(hosts[0].root?.card.image)
  }

  func testAFailedImageShowsTheMessageWithoutAnImageAndWithoutAnImageTarget() {
    show(extra: withImage)
    images.deliver(nil)
    drainMain()
    XCTAssertEqual(hosts.count, 1)
    XCTAssertNil(hosts[0].root?.card.image)
    hosts[0].layout()
    XCTAssertEqual(events.log, ["attached:true", "visible"])
  }

  func testTheMessageWaitsAtMostThreeSecondsThenShowsWithoutTheLateImage() {
    show(extra: withImage)
    XCTAssertEqual(waits.map { $0.delay }, [NottiInAppWindowPresenter.imageWait])
    XCTAssertEqual(NottiInAppWindowPresenter.imageWait, 3)
    XCTAssertTrue(hosts.isEmpty)
    fireWait()
    XCTAssertEqual(hosts.count, 1)
    images.deliver(picture())
    drainMain()
    XCTAssertNil(hosts[0].root?.card.image)
    XCTAssertEqual(hosts.count, 1)
    // Not on the next attach either: the choice was made when the wait ended.
    let key = NSObject()
    hosts[0].sceneKey = key
    center.post(name: UIScene.didDisconnectNotification, object: key)
    XCTAssertEqual(hosts.count, 2)
    XCTAssertNil(hosts[1].root?.card.image)
    XCTAssertEqual(images.loads, 1)
  }

  func testAReattachReusesTheChosenImageWithoutANewLoad() {
    show(extra: withImage)
    images.deliver(picture())
    drainMain()
    let key = NSObject()
    hosts[0].sceneKey = key
    center.post(name: UIScene.didDisconnectNotification, object: key)
    XCTAssertEqual(hosts.count, 2)
    XCTAssertNotNil(hosts[1].root?.card.image)
    XCTAssertEqual(images.loads, 1)
  }

  func testATeardownDuringTheWaitIgnoresTheLateResult() {
    let shown = show(extra: withImage)
    presenter.teardown(shown)
    XCTAssertTrue(waits.isEmpty, "the wait is cancelled")
    images.deliver(picture())
    drainMain()
    fireWait()
    XCTAssertTrue(hosts.isEmpty)
    XCTAssertTrue(events.log.isEmpty)
  }

  func testAMessageWithoutAnImageDoesNotWait() {
    show()
    XCTAssertEqual(hosts.count, 1)
    XCTAssertEqual(images.loads, 0)
    XCTAssertTrue(waits.isEmpty)
  }

  func testAnImageUrlWithoutAnImageSourceDoesNotWait() {
    let bare = NottiInAppWindowPresenter(
      events: events, scenes: scenes, makeHost: { [unowned self] _ in
        let host = FakeHost()
        self.hosts.append(host)
        return host
      }, announce: { _, _ in }, center: center)
    bare.present(display(extra: withImage))
    XCTAssertEqual(hosts.count, 1)
  }

  func testAnImageThatArrivesWhileNoSceneIsActiveShowsOnActivation() {
    scenes.target = nil
    show(extra: withImage)
    images.deliver(picture())
    drainMain()
    XCTAssertTrue(hosts.isEmpty)
    scenes.target = .screen(CGRect(x: 0, y: 0, width: 393, height: 852))
    center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
    XCTAssertEqual(hosts.count, 1)
    XCTAssertNotNil(hosts[0].root?.card.image)
  }

  // MARK: Attach and visible

  func testPresentShowsAWindowAndRaisesOnVisibleOnceAfterLayout() {
    show()
    XCTAssertEqual(hosts.count, 1)
    XCTAssertEqual(events.log, ["attached:true"])
    hosts[0].layout()
    hosts[0].layout()
    hosts[0].layout()
    XCTAssertEqual(events.log, ["attached:true", "visible"])
    XCTAssertEqual(announced, [.center])
    XCTAssertTrue(presenter.isAttached)
  }

  func testWithoutAnActiveSceneTheDisplayWaitsAndShowsOnActivation() {
    scenes.target = nil
    let shown = show()
    XCTAssertTrue(hosts.isEmpty)
    XCTAssertEqual(shown.state, .preparing)
    XCTAssertTrue(events.log.isEmpty)
    scenes.target = .screen(CGRect(x: 0, y: 0, width: 393, height: 852))
    center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
    XCTAssertEqual(hosts.count, 1)
    hosts[0].layout()
    XCTAssertEqual(events.log, ["attached:true", "visible"])
  }

  func testALayoutWhileInactiveRaisesOnVisibleOnlyOnceTheAppIsActive() {
    scenes.isAppActive = false
    show()
    hosts[0].layout()
    XCTAssertEqual(events.log, ["attached:true"])
    XCTAssertTrue(announced.isEmpty)
    scenes.isAppActive = true
    center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
    center.post(name: UIScene.didActivateNotification, object: nil)
    hosts[0].layout()
    XCTAssertEqual(events.log, ["attached:true", "visible"])
    XCTAssertEqual(hosts.count, 1)
  }

  func testAnActivationBeforeTheFirstLayoutDoesNotRaiseOnVisible() {
    show()
    center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
    XCTAssertEqual(events.log, ["attached:true"])
  }

  func testASceneDisconnectMovesTheDisplayWithoutASecondImpression() {
    let key = NSObject()
    show()
    hosts[0].sceneKey = key
    hosts[0].layout()
    center.post(name: UIScene.didDisconnectNotification, object: NSObject())
    XCTAssertFalse(hosts[0].hidden, "another scene's disconnect is ignored")
    center.post(name: UIScene.didDisconnectNotification, object: key)
    XCTAssertTrue(hosts[0].hidden)
    XCTAssertEqual(hosts.count, 2)
    hosts[1].layout()
    XCTAssertEqual(events.log, ["attached:true", "visible", "attached:false", "attached:true"])
  }

  func testPresentingTheSameDisplayAgainIsIgnored() {
    let shown = show()
    presenter.present(shown)
    XCTAssertEqual(hosts.count, 1)
  }

  // MARK: Close and teardown

  func testCloseHidesTheWindowAndReportsNothing() {
    let shown = show()
    hosts[0].layout()
    presenter.close(shown.displayId)
    XCTAssertTrue(hosts[0].hidden)
    XCTAssertFalse(presenter.isAttached)
    XCTAssertEqual(events.log, ["attached:true", "visible"])
    center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
    XCTAssertEqual(hosts.count, 1)
  }

  func testCloseOfAnotherDisplayIdIsIgnored() {
    show()
    presenter.close("other")
    XCTAssertFalse(hosts[0].hidden)
    XCTAssertTrue(presenter.isAttached)
  }

  func testSilentTeardownHidesTheWindowAndReportsNothing() {
    let shown = show()
    hosts[0].layout()
    presenter.teardown(shown)
    XCTAssertTrue(hosts[0].hidden)
    XCTAssertEqual(events.log, ["attached:true", "visible"])
    let stale = hosts[0]
    stale.onLayout?()
    XCTAssertEqual(events.log, ["attached:true", "visible"])
  }

  func testALayoutOfARemovedWindowRaisesNothing() {
    let shown = show()
    let removed = hosts[0]
    presenter.teardown(shown)
    removed.layout()
    XCTAssertEqual(events.log, ["attached:true"])
    XCTAssertTrue(announced.isEmpty)
  }

  func testTeardownOfADisplayThatIsNotShownIsIgnored() {
    show()
    let other = NottiInAppSession(monotonicMs: { 0 })
    other.onSessionStarted()
    let generation = other.tryStartFetch()!
    let raw = #"{"messages":[\#(message())]}"#
    guard case .show(let foreign) = other.onFetched(generation: generation, messages: parseEligibleResponse(Data(raw.utf8))!) else {
      return XCTFail("no display")
    }
    presenter.teardown(foreign)
    XCTAssertFalse(hosts[0].hidden)
  }

  func testANewDisplayReplacesTheCurrentOneSilently() {
    show()
    let session = NottiInAppSession(monotonicMs: { 0 })
    session.onSessionStarted()
    let generation = session.tryStartFetch()!
    let raw = #"{"messages":[\#(message("top"))]}"#
    guard case .show(let next) = session.onFetched(generation: generation, messages: parseEligibleResponse(Data(raw.utf8))!) else {
      return XCTFail("no display")
    }
    presenter.present(next)
    XCTAssertTrue(hosts[0].hidden)
    XCTAssertEqual(hosts.count, 2)
    XCTAssertEqual(events.log, ["attached:true", "attached:true"])
  }

  func testTheCloseControlAndAButtonReportTheirOutcome() {
    show()
    hosts[0].layout()
    hosts[0].root!.card.close.sendActions(for: .touchUpInside)
    XCTAssertEqual(events.log.last, "dismiss:close_button")

    setUp()
    show(extra: #","buttons":[{"id":"ok","label":"OK"}]"#)
    hosts[0].layout()
    hosts[0].root!.card.buttonRow!.buttons[0].sendActions(for: .touchUpInside)
    XCTAssertEqual(events.log.last, "click:ok")
  }

  func testTheAnnouncementFollowsTheFormat() {
    show("top")
    hosts[0].layout()
    XCTAssertEqual(announced, [.top])
  }

  // MARK: With the real coordinator

  func testRepeatedLayoutsAndAReattachRecordExactlyOneImpression() {
    makeCoordinator()
    show()
    for _ in 0..<5 { hosts[0].layout() }
    hosts[0].sceneKey = NSObject()
    center.post(name: UIScene.didDisconnectNotification, object: hosts[0].sceneKey)
    hosts[1].layout()
    hosts[1].layout()
    XCTAssertEqual(types(), [InAppEventType.impression])
  }

  func testAutoDismissCountsOnlyForegroundTimeAndClosesTheWindow() {
    makeCoordinator()
    let shown = show(extra: #","dismiss_after_seconds":5"#)
    hosts[0].layout()
    executor.advance(4_000)
    coordinator.onAppBackgrounded()
    executor.advance(60_000)
    XCTAssertTrue(coordinator.session.display === shown)
    XCTAssertFalse(hosts[0].hidden)
    coordinator.onAppForegrounded()
    executor.advance(999)
    XCTAssertTrue(coordinator.session.display === shown)
    executor.advance(1)
    XCTAssertNil(coordinator.session.display)
    XCTAssertTrue(hosts[0].hidden)
    XCTAssertEqual(types(), [InAppEventType.impression, "\(InAppEventType.dismiss):\(InAppDismissReason.auto)"])
  }

  func testAManualCloseCancelsTheAutoDismiss() {
    makeCoordinator()
    show(extra: #","dismiss_after_seconds":5"#)
    hosts[0].layout()
    hosts[0].root!.card.close.sendActions(for: .touchUpInside)
    executor.advance(10_000)
    XCTAssertTrue(hosts[0].hidden)
    XCTAssertEqual(types(), [InAppEventType.impression, "\(InAppEventType.dismiss):\(InAppDismissReason.closeButton)"])
  }

  func testASessionEndWhileWaitingForAnActiveSceneDropsTheDisplayWithNoEvent() {
    makeCoordinator()
    scenes.target = nil
    show()
    coordinator.onSessionEnded()
    scenes.target = .screen(CGRect(x: 0, y: 0, width: 393, height: 852))
    center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
    XCTAssertTrue(hosts.isEmpty)
    XCTAssertNil(coordinator.session.display)
    XCTAssertTrue(store.all().isEmpty)
  }

  func testAConfigChangeTearsTheDisplayDownSilently() {
    makeCoordinator()
    show()
    hosts[0].layout()
    coordinator.onInitialized(appId: "app", clientKey: "other-key", baseUrl: "https://api.test")
    XCTAssertTrue(hosts[0].hidden)
    XCTAssertFalse(presenter.isAttached)
    XCTAssertEqual(types(), [InAppEventType.impression])
  }

  func testThePresenterDoesNotKeepTheCoordinatorAlive() {
    makeCoordinator()
    weak var released = coordinator
    coordinator.presenter = nil
    let strongPresenter = presenter
    coordinator = nil
    XCTAssertNil(released)
    XCTAssertNotNil(strongPresenter)
  }

  // MARK: Window

  func testTheWindowNeverBecomesKeyAndPassesTouchesOutsideABar() throws {
    #if targetEnvironment(macCatalyst)
    // Showing a UIWindow needs a running app, which the hostless bundle lacks under Catalyst.
    throw XCTSkip("A UIWindow cannot be shown without an app under Mac Catalyst")
    #endif
    let window = NottiInAppWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
    XCTAssertFalse(window.canBecomeKey)
    let model = parseEligibleResponse(Data(#"{"messages":[\#(message("top"))]}"#.utf8))!.first!
    let views = NottiInAppViewFactory.build(model)
    views.root.safeAreaOverride = .zero
    let controller = NottiInAppViewController(overlay: views.root, host: nil, onLayout: {})
    window.rootViewController = controller
    controller.view.frame = window.bounds
    controller.view.layoutIfNeeded()
    controller.viewDidLayoutSubviews()
    window.isHidden = false
    XCTAssertNil(window.hitTest(CGPoint(x: 196, y: 800), with: nil))
    let inside = CGPoint(x: views.card.frame.midX, y: views.card.frame.midY)
    XCTAssertNotNil(window.hitTest(inside, with: nil))
    window.isHidden = true
  }
}
#endif
