import Foundation

/// Thin TurboModule business-logic entry: every Spec method forwards to the native SDK through the
/// `NottiNativeSDK` seam, and SDK events are mapped to the Codegen emitters `Notti.mm` wires in. No
/// business logic lives here (NSDK-01); the engine is `NottiSDK`.
@objc(NottiImpl)
public class NottiImpl: NSObject {

  /// The `sdk_name` the backend receives for this wrapper (NSDK-03).
  static let sdkName = "react-native"

  /// Set by `Notti.mm`'s `-init` before `activate()`. Handlers are plain closures: the SDK buffers
  /// events while no listener is attached and replays them to the first one.
  @objc public var emitReceivedHandler: (([String: Any]) -> Void)?
  @objc public var emitClickedHandler: (([String: Any]) -> Void)?
  @objc public var emitDeviceIdChangedHandler: ((String) -> Void)?
  @objc public var emitInAppClickHandler: (([String: Any]) -> Void)?

  private let native: NottiNativeSDK
  private let subscriptionsLock = NSLock()
  private var subscriptions: [NottiNativeSubscription] = []

  @objc public override convenience init() {
    self.init(native: DefaultNottiNativeSDK.shared)
  }

  init(native: NottiNativeSDK) {
    self.native = native
    super.init()
  }

  /// Attaches the SDK listeners. Called by `Notti.mm`'s `-init` once every emit handler is wired.
  @objc public func activate() {
    // Take the launch tap before any clicked listener exists: the SDK replays a buffered click to the
    // first listener, and a replay into an emitter JS has not subscribed to yet would lose it. It is
    // kept for `getInitialNotificationClick()` instead (NSDK-07).
    if let click = native.takeInitialClick() {
      NottiImpl.storeInitialClick(NottiImpl.payload(click))
    }
    let added = [
      native.addReceivedListener { [weak self] in self?.emitReceivedHandler?(NottiImpl.payload($0)) },
      native.addClickedListener { [weak self] in self?.emitClickedHandler?(NottiImpl.payload($0)) },
      native.addDeviceIdChangedListener { [weak self] in self?.emitDeviceIdChangedHandler?($0) },
      native.addInAppClickListener { [weak self] in self?.emitInAppClickHandler?(NottiImpl.payload($0)) },
    ]
    subscriptionsLock.lock()
    subscriptions.append(contentsOf: added)
    subscriptionsLock.unlock()
  }

  /// Called by `Notti.mm`'s `-invalidate` when the RN bridge tears this module down (dev reload, host
  /// dropping the bridge): removes every SDK listener so a reloaded module gets each event once.
  @objc public func invalidate() {
    subscriptionsLock.lock()
    let live = subscriptions
    subscriptions.removeAll()
    subscriptionsLock.unlock()
    live.forEach { $0.remove() }
    emitReceivedHandler = nil
    emitClickedHandler = nil
    emitDeviceIdChangedHandler = nil
    emitInAppClickHandler = nil
  }

  @objc(initialize:clientKey:baseUrl:sdkVersion:)
  public func initialize(_ appId: String, clientKey: String, baseUrl: String, sdkVersion: String) {
    native.initialize(
      appId: appId, clientKey: clientKey, baseUrl: baseUrl,
      sdkName: NottiImpl.sdkName, sdkVersion: sdkVersion)
  }

  @objc(requestPermission:)
  public func requestPermission(_ completion: @escaping (NSNumber) -> Void) {
    native.requestPermission { granted in
      completion(NSNumber(value: granted))
    }
  }

  @objc(login:)
  public func login(_ externalUserId: String) {
    native.login(externalUserId)
  }

  @objc public func logout() {
    native.logout()
  }

  @objc(addTags:)
  public func addTags(_ tags: NSDictionary) {
    // A non-string value is dropped, not coerced: the public TS type promises string values and
    // Android applies the same filter in `NottiModule.addTags` (0.8.0 review item I7).
    var add: [String: String] = [:]
    for (key, value) in tags {
      if let key = key as? String, let stringValue = value as? String {
        add[key] = stringValue
      }
    }
    native.addTags(add)
  }

  @objc(removeTags:)
  public func removeTags(_ keys: NSArray) {
    native.removeTags(keys.compactMap { $0 as? String })
  }

  @objc(setSubscription:)
  public func setSubscription(_ enabled: Bool) {
    native.setSubscription(enabled)
  }

  @objc(setEmail:)
  public func setEmail(_ email: String) {
    native.setEmail(email)
  }

  @objc public func clearEmail() {
    native.clearEmail()
  }

  @objc(setPhone:)
  public func setPhone(_ phone: String) {
    native.setPhone(phone)
  }

  @objc public func clearPhone() {
    native.clearPhone()
  }

  @objc(setLocationSharingEnabled:)
  public func setLocationSharingEnabled(_ enabled: Bool) {
    native.setLocationSharingEnabled(enabled)
  }

  @objc public func getDeviceId() -> String? {
    native.deviceId
  }

  @objc(trackEvent:)
  public func trackEvent(_ name: String) {
    native.trackEvent(name)
  }

  /// Backs the Spec's `getInitialNotificationClick()`: the click that launched the app, once, then nil.
  /// Reads the process-wide slot `activate()` filled; when empty it asks the SDK again, which covers a
  /// tap stored after a reload removed the listeners (NSDK-07).
  @objc public func takeInitialNotificationClick() -> [String: Any]? {
    if let stored = NottiImpl.takeStoredInitialClick() { return stored }
    return native.takeInitialClick().map(NottiImpl.payload)
  }

  /// Process-wide so it survives a JS reload, which builds a new module while the tap is still unread.
  private static let initialClickLock = NSLock()
  private static var initialClick: [String: Any]?

  private static func storeInitialClick(_ payload: [String: Any]) {
    initialClickLock.lock()
    initialClick = payload
    initialClickLock.unlock()
  }

  private static func takeStoredInitialClick() -> [String: Any]? {
    initialClickLock.lock()
    defer { initialClickLock.unlock() }
    let stored = initialClick
    initialClick = nil
    return stored
  }

  static func resetInitialClickForTests() {
    _ = takeStoredInitialClick()
  }

  /// The 0.8.0 `NotificationPayload` shape: `title` and `body` are null when absent.
  static func payload(_ notification: NottiNativeNotification) -> [String: Any] {
    [
      "title": notification.title ?? NSNull(),
      "body": notification.body ?? NSNull(),
      "data": notification.data,
    ]
  }

  /// The 0.8.0 `InAppClickPayload` shape: `action` is null for a button without a link.
  static func payload(_ click: NottiNativeInAppClick) -> [String: Any] {
    var action: Any = NSNull()
    if let type = click.actionType, let value = click.actionValue {
      action = ["type": type, "value": value]
    }
    return ["messageId": click.messageId, "buttonId": click.buttonId, "action": action]
  }
}
