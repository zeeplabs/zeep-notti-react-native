import Foundation
@_spi(Wrapper) import NottiSDK

/// A push as the adapter sees it. The SDK's own payload type cannot be built outside the SDK, so the
/// seam hands the adapter this copy and tests can build it.
struct NottiNativeNotification: Equatable {
  let title: String?
  let body: String?
  let data: [String: String]
}

/// An In-App click as the adapter sees it. `actionType` is the SDK's raw value (`url` or `deeplink`),
/// nil with `actionValue` for a button without a link (`push_permission`).
struct NottiNativeInAppClick: Equatable {
  let messageId: String
  let buttonId: String
  let actionType: String?
  let actionValue: String?
}

/// Handle returned by every `add…Listener`. Calling `remove` twice is harmless.
struct NottiNativeSubscription {
  let remove: () -> Void
}

/// Every call the adapter makes into `NottiSDK`. The SDK API is static and cannot be faked, so the
/// adapter talks to this protocol: production uses `DefaultNottiNativeSDK`, tests inject a fake and
/// check the adapter's own mapping and lifecycle (SDK behavior is tested in `zeep-notti-ios-sdk`).
protocol NottiNativeSDK: AnyObject {
  func initialize(appId: String, clientKey: String, baseUrl: String?, sdkName: String, sdkVersion: String)
  func login(_ externalUserId: String)
  func logout()
  func addTags(_ tags: [String: String])
  func removeTags(_ keys: [String])
  func setSubscription(_ enabled: Bool)
  func setLocationSharingEnabled(_ enabled: Bool)
  func setEmail(_ email: String)
  func clearEmail()
  func setPhone(_ phone: String)
  func clearPhone()
  var deviceId: String? { get }
  func trackEvent(_ name: String)
  func requestPermission(completion: @escaping (Bool) -> Void)
  func takeInitialClick() -> NottiNativeNotification?
  func addReceivedListener(_ handler: @escaping (NottiNativeNotification) -> Void) -> NottiNativeSubscription
  func addClickedListener(_ handler: @escaping (NottiNativeNotification) -> Void) -> NottiNativeSubscription
  func addDeviceIdChangedListener(_ handler: @escaping (String) -> Void) -> NottiNativeSubscription
  func addInAppClickListener(_ handler: @escaping (NottiNativeInAppClick) -> Void) -> NottiNativeSubscription
  func didRegisterForRemoteNotifications(deviceToken: Data)
  func didFailToRegisterForRemoteNotifications(error: Error)
}

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
