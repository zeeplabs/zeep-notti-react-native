#if canImport(UIKit)
import UIKit

/// Where a display window goes: the active `UIWindowScene`, or the screen for
/// a scene-less app (no scene manifest, like the example app).
enum InAppWindowTarget {
  case scene(UIWindowScene)
  case screen(CGRect)
}

/// Resolves the window target. The real one reads `UIApplication`; tests inject a fake.
protocol InAppSceneProviding: AnyObject {
  /// The first `.foregroundActive` scene, the screen for a scene-less app that
  /// is active, or nil while nothing is active (the display then waits).
  func activeTarget() -> InAppWindowTarget?
  /// True while the app is active (`UIApplication.State.active`).
  var isAppActive: Bool { get }
}

/// One shown display window. `onLayout` is called after every layout pass of
/// its content; the presenter raises `onVisible` from the first one.
protocol InAppWindowHosting: AnyObject {
  func show(_ root: InAppOverlayView, onLayout: @escaping () -> Void)
  func hide()
  /// The scene the window lives in, nil for a scene-less window.
  var sceneKey: AnyObject? { get }
}

final class NottiInAppSceneProvider: InAppSceneProviding {

  var isAppActive: Bool { UIApplication.shared.applicationState == .active }

  func activeTarget() -> InAppWindowTarget? {
    let app = UIApplication.shared
    let scenes = app.connectedScenes.compactMap { $0 as? UIWindowScene }
    if let active = scenes.first(where: { $0.activationState == .foregroundActive }) {
      return .scene(active)
    }
    // A scene-less app has no connected window scene at all.
    if scenes.isEmpty && app.applicationState == .active {
      return .screen(UIScreen.main.bounds)
    }
    return nil
  }
}

/// Window above the app (`.alert` level), never key: the host keeps its
/// keyboard and first responder. Touches outside a bar fall through to the
/// app (SDKIAM-17): the overlay returns nil there and so does the window.
final class NottiInAppWindow: UIWindow {

  override var canBecomeKey: Bool { false }

  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    let hit = super.hitTest(point, with: event)
    if hit === self || hit === rootViewController?.view { return nil }
    return hit
  }
}

/// Root of the display window: a clear view holding the overlay, which sizes
/// it to the window and reads the window's safe area.
final class NottiInAppViewController: UIViewController {

  private let overlay: InAppOverlayView
  private let onLayout: () -> Void
  /// The host's key-window controller, followed for orientation and status bar.
  private weak var host: UIViewController?

  init(overlay: InAppOverlayView, host: UIViewController?, onLayout: @escaping () -> Void) {
    self.overlay = overlay
    self.host = host
    self.onLayout = onLayout
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { nil }

  override func loadView() {
    let container = UIView()
    container.backgroundColor = .clear
    container.addSubview(overlay)
    view = container
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    overlay.frame = view.bounds
    overlay.layoutIfNeeded()
    onLayout()
  }

  // The message never changes the host's orientation or status bar. [Incerto] T30.
  override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
    host?.supportedInterfaceOrientations ?? super.supportedInterfaceOrientations
  }

  override var preferredStatusBarStyle: UIStatusBarStyle {
    host?.preferredStatusBarStyle ?? super.preferredStatusBarStyle
  }

  override var prefersStatusBarHidden: Bool {
    host?.prefersStatusBarHidden ?? super.prefersStatusBarHidden
  }
}

final class NottiInAppWindowHost: InAppWindowHosting {

  private let target: InAppWindowTarget
  private var window: NottiInAppWindow?

  init(target: InAppWindowTarget) {
    self.target = target
  }

  var sceneKey: AnyObject? { window?.windowScene }

  func show(_ root: InAppOverlayView, onLayout: @escaping () -> Void) {
    let window: NottiInAppWindow
    let host: UIViewController?
    switch target {
    case .scene(let scene):
      window = NottiInAppWindow(windowScene: scene)
      host = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController
    case .screen(let bounds):
      window = NottiInAppWindow(frame: bounds)
      host = UIApplication.shared.windows.first(where: { $0.isKeyWindow })?.rootViewController
    }
    window.windowLevel = .alert
    window.backgroundColor = .clear
    window.rootViewController = NottiInAppViewController(overlay: root, host: host, onLayout: onLayout)
    // Shown without makeKey (canBecomeKey is false as well).
    window.isHidden = false
    self.window = window
  }

  func hide() {
    window?.isHidden = true
    window?.rootViewController = nil
    window = nil
  }
}

/// Shows the current display in its own window. The views are disposable; the
/// `InAppDisplay` is not, so a re-attach (scene change) never raises a second
/// impression (DD-6). Main thread only.
final class NottiInAppWindowPresenter: InAppPresenter {

  private final class Attachment {
    let displayId: String
    let host: InAppWindowHosting
    let views: InAppMessageViews
    /// The interaction holds its listener weakly; the attachment owns it.
    let listener: InAppViewListener
    var laidOut = false
    var announced = false

    init(displayId: String, host: InAppWindowHosting, views: InAppMessageViews, listener: InAppViewListener) {
      self.displayId = displayId
      self.host = host
      self.views = views
      self.listener = listener
    }
  }

  private weak var events: InAppDisplayEvents?
  private let scenes: InAppSceneProviding
  private let makeHost: (InAppWindowTarget) -> InAppWindowHosting
  private let announce: (InAppMessageViews, InAppFormat) -> Void
  private let center: NotificationCenter
  private var observers: [NSObjectProtocol] = []

  private var display: InAppDisplay?
  private var attachment: Attachment?
  /// Display id whose `onVisible` was already raised by this presenter.
  private var visibleRaisedFor: String?

  /// `events` (the coordinator) is held weakly: the coordinator owns the presenter.
  init(
    events: InAppDisplayEvents,
    scenes: InAppSceneProviding = NottiInAppSceneProvider(),
    makeHost: @escaping (InAppWindowTarget) -> InAppWindowHosting = { NottiInAppWindowHost(target: $0) },
    announce: @escaping (InAppMessageViews, InAppFormat) -> Void = { NottiInAppAccessibility.onShown($0, format: $1) },
    center: NotificationCenter = .default
  ) {
    self.events = events
    self.scenes = scenes
    self.makeHost = makeHost
    self.announce = announce
    self.center = center
    observers = [
      center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
        self?.onActive()
      },
      center.addObserver(forName: UIScene.didActivateNotification, object: nil, queue: .main) { [weak self] _ in
        self?.onActive()
      },
      center.addObserver(forName: UIScene.didDisconnectNotification, object: nil, queue: .main) { [weak self] note in
        self?.onSceneGone(note.object as AnyObject?)
      },
    ]
  }

  deinit {
    observers.forEach(center.removeObserver)
  }

  /// True while a display window is shown.
  var isAttached: Bool { attachment != nil }

  // MARK: InAppPresenter

  func present(_ display: InAppDisplay) {
    if self.display === display { return }
    if self.display != nil { teardownSilently() }
    self.display = display
    attachIfPossible()
  }

  func close(_ displayId: String) {
    guard display?.displayId == displayId else { return }
    detach(report: false)
    display = nil
  }

  func teardown(_ display: InAppDisplay) {
    if self.display === display { teardownSilently() }
  }

  /// Hides and releases the window and reports nothing (SDKIAM-70).
  func teardownSilently() {
    detach(report: false)
    display = nil
  }

  // MARK: Lifecycle

  /// The app or a scene became active: present a waiting display, or raise
  /// the `onVisible` that a layout while inactive could not.
  func onActive() {
    if let current = attachment {
      if current.laidOut { raiseVisible(current) }
      return
    }
    attachIfPossible()
  }

  /// The display's scene went away: drop the window, keep the display for the next active scene.
  func onSceneGone(_ scene: AnyObject?) {
    guard let current = attachment, let scene = scene, current.host.sceneKey === scene else { return }
    detach(report: true)
    attachIfPossible()
  }

  private func attachIfPossible() {
    guard let target = display, let events = events, attachment == nil, target.state != .closed else { return }
    // Nothing active (cold start before activation): the display stays Preparing.
    guard let windowTarget = scenes.activeTarget() else { return }
    let displayId = target.displayId
    let views = NottiInAppViewFactory.build(target.message)
    let listener = ViewListener(events: events, displayId: displayId)
    NottiInAppViewFactory.bind(views, message: target.message, listener: listener)
    let host = makeHost(windowTarget)
    let created = Attachment(displayId: displayId, host: host, views: views, listener: listener)
    attachment = created
    events.onDisplayAttached(displayId, attached: true)
    host.show(views.root) { [weak self, weak created] in
      guard let self = self, let created = created, self.attachment === created else { return }
      created.laidOut = true
      self.raiseVisible(created)
    }
  }

  /// Once per display, after a layout pass while the app is active.
  private func raiseVisible(_ current: Attachment) {
    guard scenes.isAppActive else { return }
    if visibleRaisedFor != current.displayId {
      visibleRaisedFor = current.displayId
      events?.onDisplayVisible(current.displayId)
    }
    if !current.announced, let format = display?.message.format {
      current.announced = true
      announce(current.views, format)
    }
  }

  private func detach(report: Bool) {
    guard let current = attachment else { return }
    attachment = nil
    current.host.hide()
    if report { events?.onDisplayAttached(current.displayId, attached: false) }
  }

  private final class ViewListener: InAppViewListener {
    private weak var events: InAppDisplayEvents?
    private let displayId: String

    init(events: InAppDisplayEvents, displayId: String) {
      self.events = events
      self.displayId = displayId
    }

    func onClose(reason: String) { events?.onDisplayDismissed(displayId, reason: reason) }

    func onAction(buttonId: String, action: InAppAction?) {
      events?.onDisplayClicked(displayId, buttonId: buttonId, action: action)
    }
  }
}
#endif
