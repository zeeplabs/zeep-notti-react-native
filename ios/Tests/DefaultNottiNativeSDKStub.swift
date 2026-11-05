import Foundation

/// `NottiTests` is a hostless bundle that compiles the adapter sources directly and has no `NottiSDK`
/// module to import, so the production `DefaultNottiNativeSDK.swift` stays out of it. This stub only
/// satisfies `NottiImpl`'s default initializer; no test reaches it (tests inject `FakeNottiNativeSDK`).
final class DefaultNottiNativeSDK: NottiNativeSDK {
  static let shared = DefaultNottiNativeSDK()

  var deviceId: String? { nil }

  func initialize(appId: String, clientKey: String, baseUrl: String?, sdkName: String, sdkVersion: String) {}
  func login(_ externalUserId: String) {}
  func logout() {}
  func addTags(_ tags: [String: String]) {}
  func removeTags(_ keys: [String]) {}
  func setSubscription(_ enabled: Bool) {}
  func setLocationSharingEnabled(_ enabled: Bool) {}
  func setEmail(_ email: String) {}
  func clearEmail() {}
  func setPhone(_ phone: String) {}
  func clearPhone() {}
  func trackEvent(_ name: String) {}
  func requestPermission(completion: @escaping (Bool) -> Void) { completion(false) }
  func takeInitialClick() -> NottiNativeNotification? { nil }
  func addReceivedListener(_ handler: @escaping (NottiNativeNotification) -> Void) -> NottiNativeSubscription {
    NottiNativeSubscription {}
  }
  func addClickedListener(_ handler: @escaping (NottiNativeNotification) -> Void) -> NottiNativeSubscription {
    NottiNativeSubscription {}
  }
  func addDeviceIdChangedListener(_ handler: @escaping (String) -> Void) -> NottiNativeSubscription {
    NottiNativeSubscription {}
  }
  func addInAppClickListener(_ handler: @escaping (NottiNativeInAppClick) -> Void) -> NottiNativeSubscription {
    NottiNativeSubscription {}
  }
  func didRegisterForRemoteNotifications(deviceToken: Data) {}
  func didFailToRegisterForRemoteNotifications(error: Error) {}
}
