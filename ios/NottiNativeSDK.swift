import Foundation

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
