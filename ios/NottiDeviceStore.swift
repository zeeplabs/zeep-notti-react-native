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
  // --- Segment telemetry (T6) ---
  public let appVersion: String?
  public let firstSessionAtMs: Int64?
  public let lastSessionAtMs: Int64?
  public let sessionCount: Int
  public let sessionTimeMs: Int64
  public let sessionStartedAtMs: Int64?
  public let locationSharingEnabled: Bool

  public init(
    deviceId: String?,
    lastToken: String?,
    tags: [String: String],
    externalUserId: String?,
    subscribed: Bool,
    appVersion: String? = nil,
    firstSessionAtMs: Int64? = nil,
    lastSessionAtMs: Int64? = nil,
    sessionCount: Int = 0,
    sessionTimeMs: Int64 = 0,
    sessionStartedAtMs: Int64? = nil,
    locationSharingEnabled: Bool = false
  ) {
    self.deviceId = deviceId
    self.lastToken = lastToken
    self.tags = tags
    self.externalUserId = externalUserId
    self.subscribed = subscribed
    self.appVersion = appVersion
    self.firstSessionAtMs = firstSessionAtMs
    self.lastSessionAtMs = lastSessionAtMs
    self.sessionCount = sessionCount
    self.sessionTimeMs = sessionTimeMs
    self.sessionStartedAtMs = sessionStartedAtMs
    self.locationSharingEnabled = locationSharingEnabled
  }
}

public class NottiDeviceStore {

  private static let keyDeviceId = "notti_device_id"
  private static let keyLastToken = "notti_last_token"
  private static let keyExternalUserId = "notti_external_user_id"
  private static let keySubscribed = "notti_subscribed"
  private static let keyTags = "notti_tags"
  private static let keyAppVersion = "notti_app_version"
  private static let keyFirstSessionAtMs = "notti_first_session_at_ms"
  private static let keyLastSessionAtMs = "notti_last_session_at_ms"
  private static let keySessionCount = "notti_session_count"
  private static let keySessionTimeMs = "notti_session_time_ms"
  private static let keySessionStartedAtMs = "notti_session_started_at_ms"
  private static let keyLocationSharingEnabled = "notti_location_sharing_enabled"

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
    // A7 (found in pre-release review): `as? [String: String]` is an
    // all-or-nothing cast on the whole dictionary - one non-string value
    // (which should never happen given `setTags`' own input type, but this
    // reads persisted `UserDefaults` state that could in principle have been
    // written by a future/older SDK version) silently wiped the entire local
    // tag cache. Per-key tolerance instead, matching every other tag-parsing
    // path in the SDK (`NottiApiClient.swift`'s `parseDeviceResponse`).
    (defaults.dictionary(forKey: Self.keyTags) ?? [:]).compactMapValues { $0 as? String }
  }

  public func setTags(_ tags: [String: String]) {
    defaults.set(tags, forKey: Self.keyTags)
  }

  // MARK: - Segment telemetry fields (T6)

  public func getAppVersion() -> String? {
    defaults.string(forKey: Self.keyAppVersion)
  }

  public func setAppVersion(_ appVersion: String?) {
    defaults.set(appVersion, forKey: Self.keyAppVersion)
  }

  public func getFirstSessionAtMs() -> Int64? {
    (defaults.object(forKey: Self.keyFirstSessionAtMs) as? NSNumber)?.int64Value
  }

  public func setFirstSessionAtMs(_ ms: Int64?) {
    defaults.set(ms.map(NSNumber.init(value:)), forKey: Self.keyFirstSessionAtMs)
  }

  public func getLastSessionAtMs() -> Int64? {
    (defaults.object(forKey: Self.keyLastSessionAtMs) as? NSNumber)?.int64Value
  }

  public func setLastSessionAtMs(_ ms: Int64?) {
    defaults.set(ms.map(NSNumber.init(value:)), forKey: Self.keyLastSessionAtMs)
  }

  public func getSessionCount() -> Int {
    defaults.integer(forKey: Self.keySessionCount)
  }

  public func setSessionCount(_ count: Int) {
    defaults.set(count, forKey: Self.keySessionCount)
  }

  public func getSessionTimeMs() -> Int64 {
    (defaults.object(forKey: Self.keySessionTimeMs) as? NSNumber)?.int64Value ?? 0
  }

  public func setSessionTimeMs(_ ms: Int64) {
    defaults.set(NSNumber(value: ms), forKey: Self.keySessionTimeMs)
  }

  public func getSessionStartedAtMs() -> Int64? {
    (defaults.object(forKey: Self.keySessionStartedAtMs) as? NSNumber)?.int64Value
  }

  public func setSessionStartedAtMs(_ ms: Int64?) {
    defaults.set(ms.map(NSNumber.init(value:)), forKey: Self.keySessionStartedAtMs)
  }

  public func getLocationSharingEnabled() -> Bool {
    defaults.bool(forKey: Self.keyLocationSharingEnabled)
  }

  public func setLocationSharingEnabled(_ enabled: Bool) {
    defaults.set(enabled, forKey: Self.keyLocationSharingEnabled)
  }

  public func getState() -> DeviceState {
    DeviceState(
      deviceId: getDeviceId(),
      lastToken: getLastToken(),
      tags: getTags(),
      externalUserId: getExternalUserId(),
      subscribed: getSubscribed(),
      appVersion: getAppVersion(),
      firstSessionAtMs: getFirstSessionAtMs(),
      lastSessionAtMs: getLastSessionAtMs(),
      sessionCount: getSessionCount(),
      sessionTimeMs: getSessionTimeMs(),
      sessionStartedAtMs: getSessionStartedAtMs(),
      locationSharingEnabled: getLocationSharingEnabled()
    )
  }
}
