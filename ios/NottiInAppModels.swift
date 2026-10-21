import Foundation

/// Layout chosen by the server. An unknown value renders as `.center`.
enum InAppFormat: Equatable {
  case top
  case center
  case bottom
  case full
}

enum InAppTextAlign: Equatable {
  case left
  case center
  case right
}

/// A tap action. `type` is `url` or `deeplink` (a link the integrator handles;
/// the SDK never opens it, `value` is exactly what the server sent) or
/// `pushPermissionType` (button only, no value, run by the SDK itself).
struct InAppAction: Equatable {
  static let pushPermissionType = "push_permission"

  let type: String
  let value: String
}

/// Look tokens of a message. Colors are opaque `0xFFRRGGBB` values, `nil`
/// meaning "use the SDK default" (an absent or unparseable token). `style: null`
/// in the payload yields the defaults of this type.
struct InAppStyle: Equatable {
  var backgroundColor: UInt32? = nil
  var textColor: UInt32? = nil
  var buttonColor: UInt32? = nil
  var buttonTextColor: UInt32? = nil
  var textAlign: InAppTextAlign = .left
  var margin: Bool = true
}

enum InAppTrigger: Equatable {
  case sessionStart
  /// `name` is never empty and is matched byte for byte against `trackEvent`.
  case event(name: String)
  /// Unknown trigger type, or an `event` trigger without a name.
  case unsupported
}

/// `action` is `nil` when the payload had an unknown or malformed action.
struct InAppButton: Equatable {
  let id: String
  let label: String
  let action: InAppAction?
}

/// A message from the `eligible` response. `renderable` is false when the SDK
/// must skip it (no impression, no event): empty id, no title and no body, or
/// an unsupported trigger.
struct InAppMessage: Equatable {
  let id: String
  let format: InAppFormat
  let title: String
  let body: String
  let imageUrl: String?
  let imageAction: InAppAction?
  let style: InAppStyle
  let dismissAfterSeconds: Int?
  let trigger: InAppTrigger
  let buttons: [InAppButton]
  let renderable: Bool
}

private let maxButtons = 2
private let minDismissSeconds = 1.0
private let maxDismissSeconds = 300.0

/// Parses an `eligible` 200 body tolerantly. Returns `nil` (a transient
/// failure for the caller) when the body is not a JSON object or has no
/// `messages` array. Otherwise returns the parsed messages in server order:
/// unknown fields are ignored, an entry that is not an object is skipped
/// without affecting the others, and an empty array is a valid result.
/// Never traps.
func parseEligibleResponse(_ data: Data) -> [InAppMessage]? {
  guard
    let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
    let entries = root["messages"] as? [Any]
  else {
    return nil
  }
  return entries.compactMap { entry in
    guard let object = entry as? [String: Any] else { return nil }
    return parseMessage(object)
  }
}

/// `#RRGGBB` (either case) to an opaque `0xFFRRGGBB` value; anything else
/// (`#RGB`, alpha form, no `#`, non-hex, blank, `nil`) yields `nil`. Checked
/// byte by byte rather than with `UInt32(_:radix:)`, which also accepts a
/// leading `+`/`-`. Never traps.
func parseHexColor(_ value: String?) -> UInt32? {
  guard let value = value else { return nil }
  let bytes = Array(value.utf8)
  guard bytes.count == 7, bytes[0] == UInt8(ascii: "#") else { return nil }
  var rgb: UInt32 = 0
  for byte in bytes[1...] {
    guard let digit = hexDigit(byte) else { return nil }
    rgb = (rgb << 4) | digit
  }
  return 0xFF00_0000 | rgb
}

private func hexDigit(_ byte: UInt8) -> UInt32? {
  switch byte {
  case UInt8(ascii: "0")...UInt8(ascii: "9"): return UInt32(byte - UInt8(ascii: "0"))
  case UInt8(ascii: "a")...UInt8(ascii: "f"): return UInt32(byte - UInt8(ascii: "a") + 10)
  case UInt8(ascii: "A")...UInt8(ascii: "F"): return UInt32(byte - UInt8(ascii: "A") + 10)
  default: return nil
  }
}

private func parseMessage(_ object: [String: Any]) -> InAppMessage {
  let id = stringOrEmpty(object["id"])
  let title = stringOrEmpty(object["title"])
  let body = stringOrEmpty(object["body"])
  let imageUrl = (object["image_url"] as? String).flatMap { isHttpsUrl($0) ? $0 : nil }
  let trigger = parseTrigger(object["trigger"] as? [String: Any])
  return InAppMessage(
    id: id,
    format: parseFormat(object["format"] as? String),
    title: title,
    body: body,
    imageUrl: imageUrl,
    imageAction: imageUrl != nil ? parseAction(object["image_action"], allowPushPermission: false) : nil,
    style: parseStyle(object["style"] as? [String: Any]),
    dismissAfterSeconds: parseDismissSeconds(object["dismiss_after_seconds"]),
    trigger: trigger,
    buttons: parseButtons(object["buttons"] as? [Any]),
    renderable: !id.isEmpty
      && (!isBlank(title) || !isBlank(body))
      && trigger != .unsupported
  )
}

private func stringOrEmpty(_ raw: Any?) -> String { raw as? String ?? "" }

private func isBlank(_ value: String) -> Bool {
  value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

private func isHttpsUrl(_ value: String) -> Bool {
  let scheme = "https://"
  return value.utf16.count > scheme.utf16.count && value.prefix(scheme.count).lowercased() == scheme
}

/// A JSON number that is not a JSON boolean. `JSONSerialization` hands both
/// back as `NSNumber`, and `as? Int` / `as? Bool` bridge across them (`true`
/// reads as `1`), which would diverge from Android's `org.json` types.
private func jsonNumber(_ raw: Any?) -> NSNumber? {
  guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
    return nil
  }
  return number
}

private func jsonBool(_ raw: Any?) -> Bool? {
  guard let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
    return nil
  }
  return number.boolValue
}

private func parseFormat(_ value: String?) -> InAppFormat {
  switch value {
  case "top": return .top
  case "bottom": return .bottom
  case "full": return .full
  default: return .center
  }
}

private func parseTrigger(_ object: [String: Any]?) -> InAppTrigger {
  guard let object = object else { return .unsupported }
  switch object["type"] as? String {
  case "session_start":
    return .sessionStart
  case "event":
    let name = stringOrEmpty(object["name"])
    return name.isEmpty ? .unsupported : .event(name: name)
  default:
    return .unsupported
  }
}

private func parseAction(_ raw: Any?, allowPushPermission: Bool = true) -> InAppAction? {
  guard
    let object = raw as? [String: Any],
    let type = object["type"] as? String
  else {
    return nil
  }
  if type == InAppAction.pushPermissionType {
    return allowPushPermission ? InAppAction(type: type, value: "") : nil
  }
  guard type == "url" || type == "deeplink" else { return nil }
  let value = stringOrEmpty(object["value"])
  return value.isEmpty ? nil : InAppAction(type: type, value: value)
}

private func parseButtons(_ entries: [Any]?) -> [InAppButton] {
  guard let entries = entries else { return [] }
  var buttons: [InAppButton] = []
  for entry in entries {
    if buttons.count == maxButtons { break }
    guard let object = entry as? [String: Any] else { continue }
    let id = stringOrEmpty(object["id"])
    let label = stringOrEmpty(object["label"])
    if id.isEmpty || label.isEmpty { continue }
    buttons.append(InAppButton(id: id, label: label, action: parseAction(object["action"])))
  }
  return buttons
}

private func parseStyle(_ object: [String: Any]?) -> InAppStyle {
  guard let object = object else { return InAppStyle() }
  let textAlign: InAppTextAlign
  switch object["text_align"] as? String {
  case "center": textAlign = .center
  case "right": textAlign = .right
  default: textAlign = .left
  }
  return InAppStyle(
    backgroundColor: parseHexColor(object["background_color"] as? String),
    textColor: parseHexColor(object["text_color"] as? String),
    buttonColor: parseHexColor(object["button_color"] as? String),
    buttonTextColor: parseHexColor(object["button_text_color"] as? String),
    textAlign: textAlign,
    margin: jsonBool(object["margin"]) ?? true
  )
}

private func parseDismissSeconds(_ raw: Any?) -> Int? {
  guard let seconds = jsonNumber(raw)?.doubleValue else { return nil }
  guard seconds == seconds.rounded(.down) else { return nil }
  guard seconds >= minDismissSeconds, seconds <= maxDismissSeconds else { return nil }
  return Int(seconds)
}
