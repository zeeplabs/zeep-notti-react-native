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

  let core: NottiCore

  @objc public override init() {
    let defaults = UserDefaults(suiteName: "notti_prefs") ?? .standard
    core = NottiCore(
      deviceStore: NottiDeviceStore(defaults: defaults),
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
      }
    )
    super.init()
    NottiImpl.activeInstance = self
    NottiImpl.activeCore = core
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
    var add: [String: String] = [:]
    for (key, value) in tags {
      if let key = key as? String {
        add[key] = "\(value)"
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

  /// Backs the Spec's `getInitialNotificationClick()`: returns the click that
  /// launched the app from a cold start (buffered before any JS listener could
  /// exist) and consumes it, or nil when the app was not launched by a tap.
  @objc public func takeInitialNotificationClick() -> [String: Any]? {
    NottiEventBuffer.shared.takeInitialClick()
  }
}
