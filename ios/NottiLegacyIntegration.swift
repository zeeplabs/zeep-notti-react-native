import Foundation
import UserNotifications

/// 0.8.0 `AppDelegate` entry points, kept so existing host code still compiles (NSDK-12). The native
/// SDK handles APNs by itself now, so new integrations call neither of these classes. They forward to
/// the SDK's manual API: with the SDK's delegate handling on, it ignores the calls with one warning, so
/// an event is never processed twice. Removed no earlier than 1.0.
@available(*, deprecated, message: "NottiSDK handles APNs by itself. Remove the NottiBridge calls from your AppDelegate.")
@objc(NottiBridge)
public class NottiBridge: NSObject {

  /// Test seam; production forwards to the native SDK.
  static var native: NottiNativeSDK = DefaultNottiNativeSDK.shared

  /// 0.8.0: call from `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`.
  @objc public static func didRegisterForRemoteNotifications(deviceToken: Data) {
    native.didRegisterForRemoteNotifications(deviceToken: deviceToken)
  }

  /// 0.8.0: call from `application(_:didFailToRegisterForRemoteNotificationsWithError:)`.
  @objc public static func didFailToRegisterForRemoteNotifications(_ error: Error) {
    native.didFailToRegisterForRemoteNotifications(error: error)
  }
}

/// 0.8.0 `UNUserNotificationCenterDelegate` helper. It reports nothing: the native SDK sees pushes
/// through its own delegate handling. It only completes both callbacks the way 0.8.0 did, so a host that
/// still assigns it (or forwards to it from its own delegate) keeps foreground presentation and never
/// leaves a completion handler uncalled. Removed no earlier than 1.0.
@available(*, deprecated, message: "NottiSDK handles notifications by itself. Remove NottiPushDelegate from your AppDelegate.")
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
    completionHandler([.banner, .list, .sound, .badge])
  }

  public func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    completionHandler()
  }
}
