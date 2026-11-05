import Foundation
@_spi(Wrapper) import NottiSDK

/// Production seam: a pass-through to the static `Notti` API of `NottiSDK`.
final class DefaultNottiNativeSDK: NottiNativeSDK {
  static let shared = DefaultNottiNativeSDK()

  func initialize(appId: String, clientKey: String, baseUrl: String?, sdkName: String, sdkVersion: String) {
    // The host owns link handling: the SDK must not open In-App URLs on the wrapper's behalf (AD-004).
    Notti.initialize(
      appId: appId,
      clientKey: clientKey,
      options: Notti.Options(baseUrl: baseUrl, opensInAppURLs: false),
      sdkName: sdkName,
      sdkVersion: sdkVersion)
  }

  func login(_ externalUserId: String) { Notti.login(externalUserId) }
  func logout() { Notti.logout() }
  func addTags(_ tags: [String: String]) { Notti.User.addTags(tags) }
  func removeTags(_ keys: [String]) { Notti.User.removeTags(keys) }
  func setSubscription(_ enabled: Bool) { Notti.User.setSubscription(enabled) }
  func setLocationSharingEnabled(_ enabled: Bool) { Notti.setLocationSharingEnabled(enabled) }
  func setEmail(_ email: String) { Notti.User.setEmail(email) }
  func clearEmail() { Notti.User.clearEmail() }
  func setPhone(_ phone: String) { Notti.User.setPhone(phone) }
  func clearPhone() { Notti.User.clearPhone() }
  var deviceId: String? { Notti.deviceId }
  func trackEvent(_ name: String) { Notti.trackEvent(name) }

  func requestPermission(completion: @escaping (Bool) -> Void) {
    Notti.Notifications.requestPermission(completion: completion)
  }

  func takeInitialClick() -> NottiNativeNotification? {
    Notti.Notifications.takeInitialClick().map(Self.map)
  }

  func addReceivedListener(_ handler: @escaping (NottiNativeNotification) -> Void) -> NottiNativeSubscription {
    let subscription = Notti.Notifications.addReceivedListener { handler(Self.map($0)) }
    return NottiNativeSubscription { subscription.remove() }
  }

  func addClickedListener(_ handler: @escaping (NottiNativeNotification) -> Void) -> NottiNativeSubscription {
    let subscription = Notti.Notifications.addClickedListener { handler(Self.map($0)) }
    return NottiNativeSubscription { subscription.remove() }
  }

  func addDeviceIdChangedListener(_ handler: @escaping (String) -> Void) -> NottiNativeSubscription {
    let subscription = Notti.addDeviceIdChangedListener(handler)
    return NottiNativeSubscription { subscription.remove() }
  }

  func addInAppClickListener(_ handler: @escaping (NottiNativeInAppClick) -> Void) -> NottiNativeSubscription {
    let subscription = Notti.InAppMessages.addClickListener { click in
      handler(
        NottiNativeInAppClick(
          messageId: click.messageId,
          buttonId: click.buttonId,
          actionType: click.action?.type.rawValue,
          actionValue: click.action?.value))
    }
    return NottiNativeSubscription { subscription.remove() }
  }

  func didRegisterForRemoteNotifications(deviceToken: Data) {
    Notti.Notifications.didRegisterForRemoteNotifications(deviceToken: deviceToken)
  }

  func didFailToRegisterForRemoteNotifications(error: Error) {
    Notti.Notifications.didFailToRegisterForRemoteNotifications(error: error)
  }

  private static func map(_ payload: NottiNotificationPayload) -> NottiNativeNotification {
    NottiNativeNotification(title: payload.title, body: payload.body, data: payload.data)
  }
}
