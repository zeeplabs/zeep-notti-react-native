import Foundation
import UIKit
import UserNotifications

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
    let defaults = UserDefaults(suiteName: "notti_prefs") ?? .standard
    let box = HandlerBox()
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
      // B1 (found in pre-release review): `NottiCore`'s `logger` parameter
      // defaults to a no-op, so every diagnostic it logs - including the A4
      // fix (mutation-failure logging) - was silently discarded in production
      // on iOS, exercised only by tests that inject their own logger. `NSLog`
      // mirrors Android's `Log.w("Notti", ...)` production wiring.
      logger: { message in NSLog("Notti: %@", message) },
      onDeviceIdChanged: { deviceId in box.value?(deviceId) }
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
