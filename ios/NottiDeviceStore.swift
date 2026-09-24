import Foundation

/// Persisted device state mirroring the Notti `Device` row this install owns
/// (design.md `DeviceState`). Backed by `UserDefaults` since it's a handful
/// of scalar fields plus a small tag map — no query needs. Mirrors
/// `NottiDeviceStore.kt` field-for-field so both platforms stay provably in
/// sync (design.md's Risks & Concerns mitigation).
public struct DeviceState {
  public let deviceId: String?
  public let lastToken: String?
  public let tags: [String: String]
  public let externalUserId: String?
  public let subscribed: Bool

  public init(deviceId: String?, lastToken: String?, tags: [String: String], externalUserId: String?, subscribed: Bool) {
    self.deviceId = deviceId
    self.lastToken = lastToken
    self.tags = tags
    self.externalUserId = externalUserId
    self.subscribed = subscribed
  }
}

public class NottiDeviceStore {

  private static let keyDeviceId = "notti_device_id"
  private static let keyLastToken = "notti_last_token"
  private static let keyExternalUserId = "notti_external_user_id"
  private static let keySubscribed = "notti_subscribed"
  private static let keyTags = "notti_tags"

  private let defaults: UserDefaults

  public init(defaults: UserDefaults) {
    self.defaults = defaults
  }

  /// Pure merge of the current tag map against an add map and/or a remove
  /// key list, as issued by a single tag-mutation call (spec P3-AC8).
  /// Removes are applied before adds, so a key present in both `add` and
  /// `remove` within the same call ends up added (add wins on overlap) —
  /// mirrors `NottiDeviceStore.kt`'s `mergeTags`.
  public static func mergeTags(
    _ current: [String: String],
    add: [String: String]? = nil,
    remove: [String]? = nil
  ) -> [String: String] {
    var result = current
    remove?.forEach { result.removeValue(forKey: $0) }
    add?.forEach { key, value in result[key] = value }
    return result
  }

  public func getDeviceId() -> String? {
    defaults.string(forKey: Self.keyDeviceId)
  }

  public func setDeviceId(_ deviceId: String?) {
    defaults.set(deviceId, forKey: Self.keyDeviceId)
  }

  public func getLastToken() -> String? {
    defaults.string(forKey: Self.keyLastToken)
  }

  public func setLastToken(_ token: String?) {
    defaults.set(token, forKey: Self.keyLastToken)
  }

  public func getExternalUserId() -> String? {
    defaults.string(forKey: Self.keyExternalUserId)
  }

  public func setExternalUserId(_ externalUserId: String?) {
    defaults.set(externalUserId, forKey: Self.keyExternalUserId)
  }

  public func getSubscribed() -> Bool {
    defaults.bool(forKey: Self.keySubscribed)
  }

  public func setSubscribed(_ subscribed: Bool) {
    defaults.set(subscribed, forKey: Self.keySubscribed)
  }

  public func getTags() -> [String: String] {
    (defaults.dictionary(forKey: Self.keyTags) as? [String: String]) ?? [:]
  }

  public func setTags(_ tags: [String: String]) {
    defaults.set(tags, forKey: Self.keyTags)
  }

  public func getState() -> DeviceState {
    DeviceState(
      deviceId: getDeviceId(),
      lastToken: getLastToken(),
      tags: getTags(),
      externalUserId: getExternalUserId(),
      subscribed: getSubscribed()
    )
  }
}
