import UserNotifications
import Notti

/// Real integration target for `docs/adr/002-...md`: this is what a Notti
/// consumer's own generated "Notification Service Extension" template
/// becomes after wiring — a one-line forwarding call into the SDK's helper,
/// same shape as OneSignal's `OneSignalExtension.didReceiveNotificationExtensionRequest`.
class NotificationService: UNNotificationServiceExtension {

  var contentHandler: ((UNNotificationContent) -> Void)?
  var bestAttemptContent: UNMutableNotificationContent?

  override func didReceive(
    _ request: UNNotificationRequest,
    withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
  ) {
    self.contentHandler = contentHandler
    bestAttemptContent = (request.content.mutableCopy() as? UNMutableNotificationContent)

    NottiNotificationServiceExtension.didReceive(request, withContentHandler: contentHandler)
  }

  override func serviceExtensionTimeWillExpire() {
    guard let contentHandler, let bestAttemptContent else { return }
    contentHandler(bestAttemptContent)
  }
}
