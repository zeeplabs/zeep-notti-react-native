import Foundation
import UserNotifications

/// Public entry points the host app's own `AppDelegate` must call — no
/// swizzling (AD-002/T3's confirmed approach, `design.md`'s "iOS APNs
/// delegate hooks" component). Kept as a dedicated bridge type (not the
/// TurboModule's own `Notti` Obj-C++ class) so the integrator-facing
/// surface is a plain Swift/Obj-C API independent of Codegen internals.
@objc(NottiBridge)
public class NottiBridge: NSObject {

  /// Call from `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`.
  /// Converts the raw APNs device token to the hex string Notti expects and
  /// re-registers via `NottiCore.onTokenRefreshed` — the same path handles
  /// both the very first registration and any later token refresh (there is
  /// no synchronous "get current token" API on iOS to distinguish them).
  @objc public static func didRegisterForRemoteNotifications(deviceToken: Data) {
    let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
    NottiImpl.activeCore?.onTokenRefreshed(token)
  }

  /// Call from `application(_:didFailToRegisterForRemoteNotificationsWithError:)`.
  /// Mirrors SDK-04's crash-safety contract for a missing native push
  /// prerequisite (e.g. no APNs entitlement/capability): logs, never throws.
  @objc public static func didFailToRegisterForRemoteNotifications(_ error: Error) {
    NSLog("Notti: failed to register for remote notifications - %@", error.localizedDescription)
  }
}

/// `UNUserNotificationCenterDelegate` helper the host app must assign to
/// `UNUserNotificationCenter.current().delegate` (per T3's confirmed
/// `AppDelegate`-forwarding approach — documented as an integrator
/// prerequisite in the README, T19). Handles foreground receive (`willPresent`)
/// and any-app-state click (`didReceive response:`), parsing the raw payload
/// via the pure `parseUserInfo` function and handing the corresponding
/// Codegen event to `NottiEventBuffer` (which emits it through the live
/// `NottiImpl` instance, or buffers it until one exists).
@objc(NottiPushDelegate)
public class NottiPushDelegate: NSObject, UNUserNotificationCenterDelegate {

  @objc public static let shared = NottiPushDelegate()

  private override init() {
    super.init()
  }

  public func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    let userInfo = notification.request.content.userInfo
    // I4 (found in pre-release review): the README has the host app hand
    // over its *single* `UNUserNotificationCenter` delegate, so this method
    // also runs for local notifications and any other push SDK's remote
    // notifications sharing the same app - neither should be parsed into
    // `payload.data` or reported as this SDK's own event. `aps` is present
    // only on a real APNs remote push; a local notification's `userInfo`
    // never carries it.
    if Self.isRemotePush(userInfo) {
      let parsed = parseUserInfo(userInfo)
      NottiEventBuffer.shared.emit(
        .received,
        identifier: notification.request.identifier,
        payload: parsed.toEventPayload()
      )
    }
    // `.list` was missing: without it, a notification presented in the
    // foreground never lands in Notification Center afterwards.
    completionHandler([.banner, .list, .sound, .badge])
  }

  public func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let userInfo = response.notification.request.content.userInfo
    // A8 (found in pre-release review): a custom action button or the
    // dismiss action (`UNNotificationDismissActionIdentifier`, delivered
    // when the category sets `customDismissAction`) both reached here
    // indistinguishable from a real tap. Only the default tap-to-open action
    // is reported as `notificationClicked`.
    guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
      Self.isRemotePush(userInfo)
    else {
      completionHandler()
      return
    }
    let parsed = parseUserInfo(userInfo)
    // Cold launch from a tap fires this before the RN bridge (and therefore
    // the Codegen emitter) exists — `NottiEventBuffer` holds the payload
    // until the TurboModule attaches its emitter, then replays it once.
    NottiEventBuffer.shared.emit(
      .clicked,
      identifier: response.notification.request.identifier,
      payload: parsed.toEventPayload()
    )
    completionHandler()
  }

  private static func isRemotePush(_ userInfo: [AnyHashable: Any]) -> Bool {
    userInfo["aps"] != nil
  }
}
