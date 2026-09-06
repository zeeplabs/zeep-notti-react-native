import Foundation

/// Pure, unit-testable parse of a push notification's `userInfo` dictionary
/// into the SDK's `NotificationPayload` shape (design.md) — mirrors Android's
/// `parseRemoteMessage`/`parseClickIntentExtras` pattern for the iOS side.
/// APNs delivers the payload as `{ aps: { alert: { title, body } }, ...custom
/// top-level keys }`; `alert` may also be a plain string (title-less), and a
/// silent/data-only push may have no `aps.alert` at all.
public struct ParsedNotification: Equatable {
  public let title: String?
  public let body: String?
  public let data: [String: String]

  public init(title: String?, body: String?, data: [String: String]) {
    self.title = title
    self.body = body
    self.data = data
  }
}

public func parseUserInfo(_ userInfo: [AnyHashable: Any]) -> ParsedNotification {
  var title: String?
  var body: String?

  if let aps = userInfo["aps"] as? [String: Any] {
    if let alert = aps["alert"] as? [String: Any] {
      title = alert["title"] as? String
      body = alert["body"] as? String
    } else if let alertText = aps["alert"] as? String {
      body = alertText
    }
  }

  var data: [String: String] = [:]
  for (key, value) in userInfo {
    guard let key = key as? String, !isInternalTransportKey(key) else { continue }
    guard let stringValue = stringifyPayloadValue(value) else { continue }
    data[key] = stringValue
  }

  return ParsedNotification(title: title, body: body, data: data)
}

/// Transport metadata the OS/FCM injects into the payload, which must never
/// reach `payload.data` — that dictionary is the integrator's own custom data
/// and nothing else. Same policy as Android's `parseClickIntentExtras`
/// (`NuntisActivityLifecycleListener.kt`), expressed with the key names APNs
/// and the FCM iOS SDK actually use, so the same push yields the same
/// `payload.data` on both platforms.
private let internalKeyPrefixes = ["gcm.", "google.", "aps."]
private let internalKeys: Set<String> = [
  "aps", "from", "collapse_key", "fcm_options", "content-available",
  "mutable-content", "content_available", "mutable_content",
]

private func isInternalTransportKey(_ key: String) -> Bool {
  if internalKeys.contains(key) { return true }
  return internalKeyPrefixes.contains { key.hasPrefix($0) }
}

/// Renders a non-`String` payload value the way an integrator would expect to
/// read it back in JS. Swift's default interpolation prints debug descriptions
/// (`{\n    a = 1;\n}` for a nested dictionary, `Optional("x")`, …) — nested
/// containers are re-encoded as JSON instead, and booleans as `true`/`false`
/// rather than `1`/`0`. Returns nil for values with no sensible string form
/// (`NSNull`), which are dropped.
private func stringifyPayloadValue(_ value: Any) -> String? {
  if let string = value as? String { return string }
  if value is NSNull { return nil }
  if let number = value as? NSNumber {
    if CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID() {
      return number.boolValue ? "true" : "false"
    }
    return number.stringValue
  }
  if let bool = value as? Bool { return bool ? "true" : "false" }
  if JSONSerialization.isValidJSONObject(value),
    let data = try? JSONSerialization.data(withJSONObject: value),
    let json = String(data: data, encoding: .utf8) {
    return json
  }
  return String(describing: value)
}

public extension ParsedNotification {
  /// Converts to the `[String: Any]` shape the Codegen event emitters
  /// (`emitOnNotificationReceived`/`emitOnNotificationClicked`) expect.
  func toEventPayload() -> [String: Any] {
    var payload: [String: Any] = ["data": data]
    payload["title"] = title as Any
    payload["body"] = body as Any
    return payload
  }
}
