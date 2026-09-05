import Foundation
import UserNotifications

/// Public entry points the host app's own `AppDelegate` must call — no
/// swizzling (AD-002/T3's confirmed approach, `design.md`'s "iOS APNs
/// delegate hooks" component). Kept as a dedicated bridge type (not the
/// TurboModule's own `Nuntis` Obj-C++ class) so the integrator-facing
/// surface is a plain Swift/Obj-C API independent of Codegen internals.
@objc(NuntisBridge)
public class NuntisBridge: NSObject {

  /// Call from `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`.
  /// Converts the raw APNs device token to the hex string Nuntis expects and
  /// re-registers via `NuntisCore.onTokenRefreshed` — the same path handles
  /// both the very first registration and any later token refresh (there is
  /// no synchronous "get current token" API on iOS to distinguish them).
  @objc public static func didRegisterForRemoteNotifications(deviceToken: Data) {
    let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
    NuntisImpl.activeCore?.onTokenRefreshed(token)
  }

  /// Call from `application(_:didFailToRegisterForRemoteNotificationsWithError:)`.
  /// Mirrors SDK-04's crash-safety contract for a missing native push
  /// prerequisite (e.g. no APNs entitlement/capability): logs, never throws.
  @objc public static func didFailToRegisterForRemoteNotifications(_ error: Error) {
    NSLog("Nuntis: failed to register for remote notifications - %@", error.localizedDescription)
  }
}

/// `UNUserNotificationCenterDelegate` helper the host app must assign to
/// `UNUserNotificationCenter.current().delegate` (per T3's confirmed
/// `AppDelegate`-forwarding approach — documented as an integrator
/// prerequisite in the README, T19). Handles foreground receive (`willPresent`)
/// and any-app-state click (`didReceive response:`), parsing the raw payload
/// via the pure `parseUserInfo` function and emitting the corresponding
/// Codegen event through the live `NuntisImpl` instance.
@objc(NuntisPushDelegate)
public class NuntisPushDelegate: NSObject, UNUserNotificationCenterDelegate {

  @objc public static let shared = NuntisPushDelegate()

  private override init() {
    super.init()
  }

  public func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    let parsed = parseUserInfo(notification.request.content.userInfo)
    NuntisImpl.activeInstance?.emitReceivedHandler?(parsed.toEventPayload())
    completionHandler([.banner, .sound, .badge])
  }

  public func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let parsed = parseUserInfo(response.notification.request.content.userInfo)
    NuntisImpl.activeInstance?.emitClickedHandler?(parsed.toEventPayload())
    completionHandler()
  }
}
