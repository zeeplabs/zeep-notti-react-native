import Foundation
import UIKit
import UserNotifications

/// Thin TurboModule business-logic entry (Swift side of the T2-confirmed
/// Obj-C++-shim-plus-Swift-class bridging pattern): every Spec method (T4)
/// delegates one line into `NuntisCore` (T13). Mirrors `NuntisModule.kt`'s
/// role exactly — real push-token acquisition (APNs `registerForRemote
/// Notifications`) and the native permission prompt are wired here, matching
/// Android's real `FirebaseMessaging` token fetch rather than a stub.
///
/// `activeCore`/the emit handlers mirror `NuntisModule.kt`'s
/// `activeInstance`/`activeCore` static bridge: APNs delegate callbacks
/// (T15) run outside this class (forwarded from the host app's own
/// `AppDelegate`/`UNUserNotificationCenterDelegate`, per AD-002's confirmed
/// wiring approach) and need a way to reach the live `NuntisCore` instance
/// and to emit Codegen events through the live Obj-C++ `Nuntis` instance
/// (which owns `emitOnNotificationReceived`/`emitOnNotificationClicked` via
/// `NativeNuntisSpecBase` — a Swift class can't inherit that Obj-C++ base).
@objc(NuntisImpl)
public class NuntisImpl: NSObject {

  @objc public static weak var activeInstance: NuntisImpl?
  static var activeCore: NuntisCore?

  /// Set by `Nuntis.mm`'s `-init` to forward parsed notification payloads
  /// into the Codegen event emitters it alone has access to.
  @objc public var emitReceivedHandler: (([String: Any]) -> Void)?
  @objc public var emitClickedHandler: (([String: Any]) -> Void)?

  let core: NuntisCore

  @objc public override init() {
    let defaults = UserDefaults(suiteName: "nuntis_prefs") ?? .standard
    core = NuntisCore(
      deviceStore: NuntisDeviceStore(defaults: defaults),
      apiClientFactory: { appId, clientKey, baseUrl in
        NuntisApiClient(baseUrl: baseUrl, appId: appId, clientKey: clientKey)
      },
      tokenProvider: { _ in
        // APNs delivers the device token asynchronously via
        // application(_:didRegisterForRemoteNotificationsWithDeviceToken:)
        // (T15, host AppDelegate-forwarded) — there is no synchronous
        // "get current token" API on iOS, so this never invokes the
        // callback itself; T15's forwarded callback calls
        // `NuntisCore.onTokenRefreshed` once the real token arrives,
        // which performs the actual registration (both the first-time
        // and any later refresh, uniformly).
        DispatchQueue.main.async {
          UIApplication.shared.registerForRemoteNotifications()
        }
      },
      permissionRequester: { callback in
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
          DispatchQueue.main.async { callback(granted) }
        }
      }
    )
    super.init()
    NuntisImpl.activeInstance = self
    NuntisImpl.activeCore = core
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
}
