import Foundation
import UIKit
import UserNotifications
import CoreLocation

/// Thin TurboModule business-logic entry (Swift side of the T2-confirmed
/// Obj-C++-shim-plus-Swift-class bridging pattern): every Spec method (T4)
/// delegates one line into `NottiCore` (T13). Mirrors `NottiModule.kt`'s
/// role exactly — real push-token acquisition (APNs `registerForRemote
/// Notifications`) and the native permission prompt are wired here, matching
/// Android's real `FirebaseMessaging` token fetch rather than a stub.
///
/// `activeCore`/the emit handlers mirror `NottiModule.kt`'s
/// `activeInstance`/`activeCore` static bridge: APNs delegate callbacks
/// (T15) run outside this class (forwarded from the host app's own
/// `AppDelegate`/`UNUserNotificationCenterDelegate`, per AD-002's confirmed
/// wiring approach) and need a way to reach the live `NottiCore` instance
/// and to emit Codegen events through the live Obj-C++ `Notti` instance
/// (which owns `emitOnNotificationReceived`/`emitOnNotificationClicked` via
/// `NativeNottiSpecBase` — a Swift class can't inherit that Obj-C++ base).
@objc(NottiImpl)
public class NottiImpl: NSObject {

  @objc public static weak var activeInstance: NottiImpl?
  static var activeCore: NottiCore?

  /// Process-wide "a session is open" flag (final review A), shared by every
  /// `NottiCore` this process builds - a JS reload creates a new module/core
  /// while the foreground session is still open, and the new core must adopt
  /// it rather than close it as an orphan. Mirrors Android's
  /// `NottiModule.processSessionGate`.
  static let processSessionGate = NottiCore.SessionGate()

  /// M2 (pre-release review round 3): closes `processSessionGate`
  /// unconditionally on background, even when no `NottiCore` is alive to
  /// hear about it. `NottiCore.invalidate()` (called on JS reload) removes
  /// that core's own `didEnterBackgroundNotification` observer immediately;
  /// if the app backgrounds in the gap before the reloaded module's core
  /// exists, nothing closes the gate. The next real foreground then finds it
  /// already open, treats the new core as "adopting" a live session instead
  /// of starting one, and counts the entire background interval as session
  /// time. Mirrors Android's `NottiForegroundObserver.onStop` ->
  /// `handleProcessBackground`, which closes the gate the same
  /// unconditional way. Registered once per process; forced into existence
  /// by the `_ = ...` touch in `init` below (a `static let` only runs its
  /// initializer on first access).
  private static let processBackgroundObserver: NSObjectProtocol = {
    #if canImport(UIKit)
      return NotificationCenter.default.addObserver(
        forName: UIApplication.didEnterBackgroundNotification,
        object: nil,
        queue: nil
      ) { _ in
        NottiImpl.processSessionGate.close()
      }
    #else
      return NSObject()
    #endif
  }()

  /// Shared offline event store (T8). `NottiPushDelegate`'s `willPresent`/
  /// `didReceive` fire on cold start before `NottiImpl` exists, so the store
  /// the delegate enqueues into and the store `NottiCore.flushEventQueue`
  /// drains must be the same instance reachable without a live module — the
  /// same "buffer before module exists" pattern as `NottiEventBuffer.shared`,
  /// reached through the `activeCore`-style static. Lazily created on the
  /// first touch from either side.
  static let eventStore = NottiEventStore(defaults: UserDefaults(suiteName: "notti_prefs") ?? .standard)

  /// Set by `Notti.mm`'s `-init` to forward parsed notification payloads
  /// into the Codegen event emitters it alone has access to. Assigning them
  /// registers the emitter with `NottiEventBuffer`, which immediately
  /// replays any *received* notification that arrived before the module
  /// existed. A cold-start click is deliberately not replayed here — no JS
  /// listener exists yet at module-construction time — and is handed over by
  /// `getInitialNotificationClick()` instead.
  @objc public var emitReceivedHandler: (([String: Any]) -> Void)? {
    didSet { NottiEventBuffer.shared.setHandler(.received, emitReceivedHandler) }
  }
  @objc public var emitClickedHandler: (([String: Any]) -> Void)? {
    didSet { NottiEventBuffer.shared.setHandler(.clicked, emitClickedHandler) }
  }

  /// Plain reference-type cell so `init` (below) can hand `NottiCore` a
  /// closure that reads this box's `value` at call time, while
  /// `emitDeviceIdChangedHandler`'s `didSet` (running later, once `self` is
  /// fully initialized) writes into that same box. A closure created before
  /// `super.init()` runs cannot capture `self` at all - not even weakly - so
  /// the box, not `self`, is what both sides actually share.
  private final class HandlerBox {
    var value: ((String) -> Void)?
  }

  /// Set by `Notti.mm`'s `-init`, before calling [activate], to forward a
  /// device-id change into the Codegen event emitter it alone has access to.
  /// Not routed through `NottiEventBuffer` - unlike a notification tap, there
  /// is no cold-start replay concern (`getDeviceId()` covers the synchronous
  /// case; this only fires for a value already assigned or updated while JS
  /// is alive).
  @objc public var emitDeviceIdChangedHandler: ((String) -> Void)? {
    didSet { deviceIdChangedBox.value = emitDeviceIdChangedHandler }
  }

  private let deviceIdChangedBox: HandlerBox

  let core: NottiCore

  @objc public override init() {
    _ = NottiImpl.processBackgroundObserver
    let defaults = UserDefaults(suiteName: "notti_prefs") ?? .standard
    let box = HandlerBox()
    let locationReader = NottiLocationReader()
    core = NottiCore(
      deviceStore: NottiDeviceStore(defaults: defaults),
      // `NottiCore` holds the store strongly, so the shared static here is
      // enough to keep it alive; the T8 enqueue hookup reaches the same store
      // through `NottiImpl.eventStore`.
      eventStore: NottiImpl.eventStore,
      apiClientFactory: { appId, clientKey, baseUrl in
        NottiApiClient(baseUrl: baseUrl, appId: appId, clientKey: clientKey)
      },
      tokenProvider: { _ in
        // APNs delivers the device token asynchronously via
        // application(_:didRegisterForRemoteNotificationsWithDeviceToken:)
        // (T15, host AppDelegate-forwarded) — there is no synchronous
        // "get current token" API on iOS, so this never invokes the
        // callback itself; T15's forwarded callback calls
        // `NottiCore.onTokenRefreshed` once the real token arrives,
        // which performs the actual registration (both the first-time
        // and any later refresh, uniformly).
        DispatchQueue.main.async {
          UIApplication.shared.registerForRemoteNotifications()
        }
      },
      permissionRequester: { callback in
        // No main-thread hop: `NottiCore` hops the result onto its own
        // background work queue (where the blocking PATCH runs), and an
        // RCTPromiseResolveBlock may be resolved from any thread. Hopping to
        // main here would have put the blocking API-client call chain back on
        // the main thread.
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
          callback(granted)
        }
      },
      // Segment telemetry P1 (T7): reads the host app's marketing version once
      // per launch; `Bundle.main.infoDictionary` has no entry for it in an
      // odd host build, in which case this returns nil and `NottiCore` skips
      // the sync (SEGTEL edge: no crash, no registration block).
      versionProvider: {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
      },
      // Segment telemetry P3 (T9): check-only OS location permission read —
      // the SDK never calls `requestWhenInUseAuthorization` (SEGTEL-14); it
      // only reports country when the host app has already granted permission
      // for its own purposes.
      hasLocationPermission: { locationReader.hasPermission() },
      // Segment telemetry P3 (T9): best-effort, async country resolution from
      // the last cached fix reverse-geocoded to its ISO 3166-1 alpha-2 code.
      // A stale fix is acceptable at country-level granularity (SEGTEL edge
      // case); nil on any failure (services disabled, no fix, geocode error,
      // a geocode already in flight) → the field is omitted.
      countryProvider: { callback in locationReader.readCountry(callback) },
      // Review item 2: the cold-start `didBecomeActive` usually fired before
      // this module was constructed; report whether the app is already active
      // (read on the main thread, asynchronously - never `main.sync`, which
      // could deadlock a module constructed while main waits on it).
      appStateProvider: { callback in
        DispatchQueue.main.async {
          callback(UIApplication.shared.applicationState == .active)
        }
      },
      // Review item 3: keep the process alive while the session-end
      // bookkeeping + PATCH queued at `didEnterBackground` run.
      beginBackgroundTask: { NottiImpl.beginBackgroundTask() },
      // B1 (found in pre-release review): `NottiCore`'s `logger` parameter
      // defaults to a no-op, so every diagnostic it logs - including the A4
      // fix (mutation-failure logging) - was silently discarded in production
      // on iOS, exercised only by tests that inject their own logger. `NSLog`
      // mirrors Android's `Log.w("Notti", ...)` production wiring.
      logger: { message in NSLog("Notti: %@", message) },
      onDeviceIdChanged: { deviceId in box.value?(deviceId) },
      sessionGate: NottiImpl.processSessionGate
    )
    // The closure passed to `NottiCore` above cannot capture `self` (or any
    // of its properties) this early - a class's stored properties, and
    // therefore `self` itself, are not valid to reference until after
    // `super.init()` runs. `box` is a plain local instead, captured directly
    // into that closure; this line publishes the very same box as
    // `self.deviceIdChangedBox`, the only thing `emitDeviceIdChangedHandler`'s
    // `didSet` (below) needs to write into later.
    self.deviceIdChangedBox = box
    super.init()
  }

  /// Publishes this instance as `activeInstance`/`activeCore` so
  /// `NottiBridge`/`NottiPushDelegate` (and any other external caller
  /// reaching them from an arbitrary thread) can find it. Called by
  /// `Notti.mm`'s `-init` only after every emit handler - including
  /// `emitDeviceIdChangedHandler` - is wired: publishing first left a window
  /// where a device-id change landing on another thread invoked a `nil`
  /// handler, dropping the event for the case that matters most (first
  /// assignment on a fresh install).
  @objc public func activate() {
    NottiImpl.activeInstance = self
    NottiImpl.activeCore = core
  }

  /// Called by `Notti.mm`'s `-invalidate` (RCTInvalidating) when the RN
  /// bridge tears this module down (dev reload, host dropping the bridge).
  /// I1/I2 (found in pre-release review): without this, `activeCore` - a
  /// strong static, unlike the `weak activeInstance` - kept a dead module's
  /// `NottiCore` alive indefinitely (its foreground observer and work queue
  /// still registered), and `emitReceivedHandler`/`emitClickedHandler` stayed
  /// non-nil (pointing at a captured `weakSelf` that had already gone nil),
  /// so `NottiEventBuffer.emit` treated the event as "delivered" - calling a
  /// no-op handler and burning the dedupe key - instead of buffering it for
  /// the next module. Guarded by identity: a second `NottiImpl` activating
  /// before this one tears down must not have its live `core` clobbered.
  @objc public func invalidate() {
    if NottiImpl.activeInstance === self {
      NottiImpl.activeInstance = nil
    }
    if NottiImpl.activeCore === core {
      NottiImpl.activeCore = nil
    }
    emitReceivedHandler = nil
    emitClickedHandler = nil
    emitDeviceIdChangedHandler = nil
    // Final review A: stop this core observing lifecycle, so it cannot end
    // the session the reloaded core adopts (double `session_count`).
    core.invalidate()
  }

  /// Begins a UIKit background task and returns an idempotent closure that
  /// ends it; the expiration handler ends it too, so the OS never kills the
  /// app for overrunning the task.
  private static func beginBackgroundTask() -> () -> Void {
    final class TaskBox {
      let lock = NSLock()
      var id: UIBackgroundTaskIdentifier = .invalid
      var ended = false
      func end() {
        lock.lock()
        defer { lock.unlock() }
        guard !ended else { return }
        ended = true
        if id != .invalid {
          UIApplication.shared.endBackgroundTask(id)
        }
      }
    }
    let box = TaskBox()
    let id = UIApplication.shared.beginBackgroundTask(withName: "app.notti.session-end") { box.end() }
    box.lock.lock()
    box.id = id
    let alreadyEnded = box.ended
    box.lock.unlock()
    if alreadyEnded && id != .invalid {
      UIApplication.shared.endBackgroundTask(id)
    }
    return { box.end() }
  }

  @objc(initialize:clientKey:baseUrl:)
  public func initialize(_ appId: String, clientKey: String, baseUrl: String) {
    core.initialize(appId: appId, clientKey: clientKey, baseUrl: baseUrl)
  }

  @objc(requestPermission:)
  public func requestPermission(_ completion: @escaping (NSNumber) -> Void) {
    core.requestPermission { granted in
      completion(NSNumber(value: granted))
    }
  }

  @objc(login:)
  public func login(_ externalUserId: String) {
    core.login(externalUserId)
  }

  @objc public func logout() {
    core.logout()
  }

  @objc(addTags:)
  public func addTags(_ tags: NSDictionary) {
    // I7 (found in pre-release review): `"\(value)"` string interpolation
    // stringified a JS number/boolean/null differently than Android's
    // `.toString()` (`"1"` vs `"1.0"`, `"<null>"` vs `"null"`) - the same
    // call produced a different server-side tag value per platform. The
    // public TS type (`Record<string, string>`) already promises
    // string-only values; a non-string value is now dropped instead of
    // coerced, matching Android's identical filter in `NottiModule.addTags`.
    var add: [String: String] = [:]
    for (key, value) in tags {
      if let key = key as? String, let stringValue = value as? String {
        add[key] = stringValue
      }
    }
    core.mutateTags(add: add, remove: nil)
  }

  @objc(removeTags:)
  public func removeTags(_ keys: NSArray) {
    let remove = keys.compactMap { $0 as? String }
    core.mutateTags(add: nil, remove: remove)
  }

  @objc(setSubscription:)
  public func setSubscription(_ enabled: Bool) {
    core.setSubscription(enabled)
  }

  @objc(setLocationSharingEnabled:)
  public func setLocationSharingEnabled(_ enabled: Bool) {
    core.setLocationSharingEnabled(enabled)
  }

  @objc public func getDeviceId() -> String? {
    core.getDeviceId()
  }

  /// Backs the Spec's `getInitialNotificationClick()`: returns the click that
  /// launched the app from a cold start (buffered before any JS listener could
  /// exist) and consumes it, or nil when the app was not launched by a tap.
  @objc public func takeInitialNotificationClick() -> [String: Any]? {
    NottiEventBuffer.shared.takeInitialClick()
  }
}

/// Location reads for segment telemetry P3.
///
/// Threading (final review E): `CLLocationManager` must be created on a
/// thread with a live run loop - it delivers its delegate callbacks on the
/// creating thread's run loop - and the old lazy creation happened on
/// `NottiCore`'s work queue (a GCD thread without one). The manager is now
/// created on the main thread (inline if `init` already runs there, else via
/// `main.async`, never `main.sync`: no deadlock with a main thread that waits
/// on module construction), and every touch of it stays on main:
/// - `hasPermission()` (synchronous, called from the work queue) reads a
///   lock-guarded cache, seeded on main right after creation and refreshed by
///   `locationManagerDidChangeAuthorization` (e.g. permission changed in
///   Settings while backgrounded). `NottiImpl.init` creates this reader
///   before `NottiCore` enqueues its `appStateProvider` main block, so the
///   seed lands before the cold-start session reads it (main is FIFO).
/// - `readCountry` hops to main to read `location` and start the geocode;
///   `NottiCore` hops the callback back onto its work queue.
/// One shared `CLGeocoder`, never asked to geocode in parallel (Apple
/// rate-limits reverse geocoding; `NottiCore` additionally throttles reads).
/// The SDK never requests permission (SEGTEL-14), only reads it.
private final class NottiLocationReader: NSObject, CLLocationManagerDelegate {
  private let lock = NSLock()
  private var cachedPermission = false
  /// Main-thread-only.
  private var manager: CLLocationManager?
  /// Main-thread-only.
  private let geocoder = CLGeocoder()

  override init() {
    super.init()
    if Thread.isMainThread {
      setUpManager()
    } else {
      DispatchQueue.main.async { self.setUpManager() }
    }
  }

  /// Main thread only.
  private func setUpManager() {
    let manager = CLLocationManager()
    manager.delegate = self
    self.manager = manager
    updatePermission(manager.authorizationStatus)
  }

  private func updatePermission(_ status: CLAuthorizationStatus) {
    let granted = status == .authorizedWhenInUse || status == .authorizedAlways
    lock.lock()
    cachedPermission = granted
    lock.unlock()
  }

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    updatePermission(manager.authorizationStatus)
  }

  func hasPermission() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return cachedPermission
  }

  func readCountry(_ callback: @escaping (String?) -> Void) {
    DispatchQueue.main.async {
      guard let location = self.manager?.location, !self.geocoder.isGeocoding else {
        callback(nil)
        return
      }
      self.geocoder.reverseGeocodeLocation(location) { placemarks, _ in
        callback(placemarks?.first?.isoCountryCode)
      }
    }
  }
}
