import Foundation

/// Records every call the adapter makes into the native SDK. Listener handlers are kept so a test
/// can emit through them, and `liveSubscriptions` counts the ones not yet removed.
final class FakeNottiNativeSDK: NottiNativeSDK {
  enum Call: Equatable {
    case initialize(appId: String, clientKey: String, baseUrl: String?, sdkName: String, sdkVersion: String)
    case login(String)
    case logout
    case addTags([String: String])
    case removeTags([String])
    case setSubscription(Bool)
    case setLocationSharingEnabled(Bool)
    case setEmail(String)
    case clearEmail
    case setPhone(String)
    case clearPhone
    case trackEvent(String)
    case requestPermission
    case takeInitialClick
    case addReceivedListener
    case addClickedListener
    case addDeviceIdChangedListener
    case addInAppClickListener
  }

  private(set) var calls: [Call] = []
  var deviceId: String?
  var permissionResult = true
  var initialClick: NottiNativeNotification?

  private(set) var receivedHandlers: [Int: (NottiNativeNotification) -> Void] = [:]
  private(set) var clickedHandlers: [Int: (NottiNativeNotification) -> Void] = [:]
  private(set) var deviceIdHandlers: [Int: (String) -> Void] = [:]
  private(set) var inAppClickHandlers: [Int: (NottiNativeInAppClick) -> Void] = [:]
  private var nextId = 0

  var liveSubscriptions: Int {
    receivedHandlers.count + clickedHandlers.count + deviceIdHandlers.count + inAppClickHandlers.count
  }

  func initialize(appId: String, clientKey: String, baseUrl: String?, sdkName: String, sdkVersion: String) {
    calls.append(.initialize(appId: appId, clientKey: clientKey, baseUrl: baseUrl, sdkName: sdkName, sdkVersion: sdkVersion))
  }
  func login(_ externalUserId: String) { calls.append(.login(externalUserId)) }
  func logout() { calls.append(.logout) }
  func addTags(_ tags: [String: String]) { calls.append(.addTags(tags)) }
  func removeTags(_ keys: [String]) { calls.append(.removeTags(keys)) }
  func setSubscription(_ enabled: Bool) { calls.append(.setSubscription(enabled)) }
  func setLocationSharingEnabled(_ enabled: Bool) { calls.append(.setLocationSharingEnabled(enabled)) }
  func setEmail(_ email: String) { calls.append(.setEmail(email)) }
  func clearEmail() { calls.append(.clearEmail) }
  func setPhone(_ phone: String) { calls.append(.setPhone(phone)) }
  func clearPhone() { calls.append(.clearPhone) }
  func trackEvent(_ name: String) { calls.append(.trackEvent(name)) }

  func requestPermission(completion: @escaping (Bool) -> Void) {
    calls.append(.requestPermission)
    completion(permissionResult)
  }

  func takeInitialClick() -> NottiNativeNotification? {
    calls.append(.takeInitialClick)
    defer { initialClick = nil }
    return initialClick
  }

  func addReceivedListener(_ handler: @escaping (NottiNativeNotification) -> Void) -> NottiNativeSubscription {
    calls.append(.addReceivedListener)
    return register(handler) { self.receivedHandlers[$0] = $1 } remove: { self.receivedHandlers[$0] = nil }
  }

  func addClickedListener(_ handler: @escaping (NottiNativeNotification) -> Void) -> NottiNativeSubscription {
    calls.append(.addClickedListener)
    return register(handler) { self.clickedHandlers[$0] = $1 } remove: { self.clickedHandlers[$0] = nil }
  }

  func addDeviceIdChangedListener(_ handler: @escaping (String) -> Void) -> NottiNativeSubscription {
    calls.append(.addDeviceIdChangedListener)
    return register(handler) { self.deviceIdHandlers[$0] = $1 } remove: { self.deviceIdHandlers[$0] = nil }
  }

  func addInAppClickListener(_ handler: @escaping (NottiNativeInAppClick) -> Void) -> NottiNativeSubscription {
    calls.append(.addInAppClickListener)
    return register(handler) { self.inAppClickHandlers[$0] = $1 } remove: { self.inAppClickHandlers[$0] = nil }
  }

  func didRegisterForRemoteNotifications(deviceToken: Data) {}
  func didFailToRegisterForRemoteNotifications(error: Error) {}

  private func register<H>(
    _ handler: H, store: (Int, H) -> Void, remove: @escaping (Int) -> Void
  ) -> NottiNativeSubscription {
    let id = nextId
    nextId += 1
    store(id, handler)
    return NottiNativeSubscription { remove(id) }
  }
}
