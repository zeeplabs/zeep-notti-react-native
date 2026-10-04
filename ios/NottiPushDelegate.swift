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
    // Start the network observer once per process (T8): the host app assigns
    // this delegate on every cold start (README), so `shared`'s first touch —
    // and therefore this init — is the guaranteed "start once even on cold
    // start" spot for the offline-event flush trigger.
    NottiNetworkObserver.shared.start()
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
      enqueueIfReportable(parsed, type: NottiEventType.received)
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
    guard Self.isRemotePush(userInfo) else {
      completionHandler()
      return
    }
    switch response.actionIdentifier {
    case UNNotificationDefaultActionIdentifier:
      let parsed = parseUserInfo(userInfo)
      // Cold launch from a tap fires this before the RN bridge (and therefore
      // the Codegen emitter) exists — `NottiEventBuffer` holds the payload
      // until the TurboModule attaches its emitter, then replays it once.
      NottiEventBuffer.shared.emit(
        .clicked,
        identifier: response.notification.request.identifier,
        payload: parsed.toEventPayload()
      )
      // A body tap is reported as both `opened` and `clicked` (one of each),
      // with or without a URL in `data`, so CTR keeps counting body taps
      // (opened-event-reporting D1). The JS event name stays
      // `notificationClicked` (D4).
      enqueueIfReportable(parsed, type: NottiEventType.opened)
      enqueueIfReportable(parsed, type: NottiEventType.clicked)
    case UNNotificationDismissActionIdentifier:
      // Delivered only when the category sets `customDismissAction`; a
      // dismissal is not engagement and is never reported.
      break
    default:
      // A button from a category the host app registered (`aps.category`).
      // Reported as `clicked` only: the backend already counts a clicked
      // delivery as opened (D2). No JS event, as before (A8).
      enqueueIfReportable(parseUserInfo(userInfo), type: NottiEventType.clicked)
    }
    completionHandler()
  }

  /// Queues the offline-reportable event for `parsed` when its payload carries
  /// both `notification_id` and `delivery_id` (the same detection rule as
  /// Android), then opportunistically triggers a flush through the live core.
  /// On cold start the core does not exist yet (`NottiImpl.activeCore` is nil),
  /// so the event simply stays queued until registration success, the next app
  /// foreground, or the network observer flushes it. Skipped silently
  /// otherwise.
  private func enqueueIfReportable(_ parsed: ParsedNotification, type: String) {
    guard let notificationId = parsed.data["notification_id"], !notificationId.isEmpty,
      let deliveryId = parsed.data["delivery_id"], !deliveryId.isEmpty
    else {
      return
    }
    NottiImpl.eventStore.enqueue(notificationId: notificationId, deliveryId: deliveryId, type: type)
    NottiImpl.activeCore?.onNetworkAvailable()
  }

  private static func isRemotePush(_ userInfo: [AnyHashable: Any]) -> Bool {
    userInfo["aps"] != nil
  }
}
