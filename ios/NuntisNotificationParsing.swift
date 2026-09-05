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
    guard let key = key as? String, key != "aps" else { continue }
    data[key] = "\(value)"
  }

  return ParsedNotification(title: title, body: body, data: data)
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
