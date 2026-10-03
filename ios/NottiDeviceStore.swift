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
  // --- Device profile fields (device-profile-fields) ---
  public let lastSyncedDeviceOs: String?
  public let lastSyncedDeviceModel: String?
  public let lastSyncedSdkVersion: String?
  public let lastSyncedTimezoneId: String?
  public let lastSyncedLanguage: String?
  public let lastSyncedPermissionStatus: String?
  public let lastUnsubscribedAtMs: Int64?
  public let email: String?
  public let phone: String?
  public let lastSyncedEmail: String?
  public let lastSyncedPhone: String?

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
    locationSharingEnabled: Bool = false,
    lastSyncedDeviceOs: String? = nil,
    lastSyncedDeviceModel: String? = nil,
    lastSyncedSdkVersion: String? = nil,
    lastSyncedTimezoneId: String? = nil,
    lastSyncedLanguage: String? = nil,
    lastSyncedPermissionStatus: String? = nil,
    lastUnsubscribedAtMs: Int64? = nil,
    email: String? = nil,
    phone: String? = nil,
    lastSyncedEmail: String? = nil,
    lastSyncedPhone: String? = nil
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
    self.lastSyncedDeviceOs = lastSyncedDeviceOs
    self.lastSyncedDeviceModel = lastSyncedDeviceModel
    self.lastSyncedSdkVersion = lastSyncedSdkVersion
    self.lastSyncedTimezoneId = lastSyncedTimezoneId
    self.lastSyncedLanguage = lastSyncedLanguage
    self.lastSyncedPermissionStatus = lastSyncedPermissionStatus
    self.lastUnsubscribedAtMs = lastUnsubscribedAtMs
    self.email = email
    self.phone = phone
    self.lastSyncedEmail = lastSyncedEmail
    self.lastSyncedPhone = lastSyncedPhone
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
  private static let keySessionLastSeenAtMs = "notti_session_last_seen_at_ms"
  private static let keyPendingCountryClear = "notti_pending_country_clear"
  private static let keyLastSyncedCountry = "notti_last_synced_country"
  // --- Device profile field keys (device-profile-fields) ---
  private static let keyLastSyncedDeviceOs = "notti_last_synced_device_os"
  private static let keyLastSyncedDeviceModel = "notti_last_synced_device_model"
  private static let keyLastSyncedSdkVersion = "notti_last_synced_sdk_version"
  private static let keyLastSyncedTimezoneId = "notti_last_synced_timezone_id"
  private static let keyLastSyncedLanguage = "notti_last_synced_language"
  private static let keyLastSyncedPermissionStatus = "notti_last_synced_permission_status"
  private static let keyLastUnsubscribedAtMs = "notti_last_unsubscribed_at_ms"
  private static let keyPendingUnsubscribeAtMs = "notti_pending_unsubscribe_at_ms"
  private static let keyPendingPermissionUnsubscribeAtMs = "notti_pending_permission_unsubscribe_at_ms"
  private static let keyEmail = "notti_email"
  private static let keyPhone = "notti_phone"
  private static let keyLastSyncedEmail = "notti_last_synced_email"
  private static let keyLastSyncedPhone = "notti_last_synced_phone"

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

  /// Tri-state read of `subscribed`: nil when the key was never written (no
  /// subscription PATCH acknowledged yet). `getSubscribed()` collapses that
  /// to `false`, which hid the unknown state from the DPF-14 transition check
  /// - the backend registers devices subscribed by default.
  public func getSubscribedIfKnown() -> Bool? {
    (defaults.object(forKey: Self.keySubscribed) as? NSNumber)?.boolValue
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

  /// Last known foreground timestamp of the open session (heartbeat). Used
  /// to close an orphaned session (unclean kill) at its real end instead of
  /// `now - startedAt`, which counted all the time the app was dead as
  /// foreground (SEGTEL-08 "last known foreground timestamp").
  public func getSessionLastSeenAtMs() -> Int64? {
    (defaults.object(forKey: Self.keySessionLastSeenAtMs) as? NSNumber)?.int64Value
  }

  public func setSessionLastSeenAtMs(_ ms: Int64?) {
    defaults.set(ms.map(NSNumber.init(value:)), forKey: Self.keySessionLastSeenAtMs)
  }

  /// LGPD: set on location opt-out, cleared ONLY when the backend
  /// acknowledged the `{country: null}` PATCH with a 2xx. Persisted so a
  /// clear issued before `initialize`, offline, or against a 5xx survives a
  /// process death and is re-sent on the next registration/foreground/flush.
  public func getPendingCountryClear() -> Bool {
    defaults.bool(forKey: Self.keyPendingCountryClear)
  }

  public func setPendingCountryClear(_ pending: Bool) {
    defaults.set(pending, forKey: Self.keyPendingCountryClear)
  }

  /// The last country value the backend acknowledged (2xx). Drives the
  /// diff (no PATCH when unchanged) and tells the opt-out path whether there
  /// is anything server-side to clear.
  public func getLastSyncedCountry() -> String? {
    defaults.string(forKey: Self.keyLastSyncedCountry)
  }

  public func setLastSyncedCountry(_ country: String?) {
    defaults.set(country, forKey: Self.keyLastSyncedCountry)
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
      locationSharingEnabled: getLocationSharingEnabled(),
      lastSyncedDeviceOs: getLastSyncedDeviceOs(),
      lastSyncedDeviceModel: getLastSyncedDeviceModel(),
      lastSyncedSdkVersion: getLastSyncedSdkVersion(),
      lastSyncedTimezoneId: getLastSyncedTimezoneId(),
      lastSyncedLanguage: getLastSyncedLanguage(),
      lastSyncedPermissionStatus: getLastSyncedPermissionStatus(),
      lastUnsubscribedAtMs: getLastUnsubscribedAtMs(),
      email: getEmail(),
      phone: getPhone(),
      lastSyncedEmail: getLastSyncedEmail(),
      lastSyncedPhone: getLastSyncedPhone()
    )
  }

  // MARK: - Device profile field accessors (device-profile-fields)

  public func getLastSyncedDeviceOs() -> String? {
    defaults.string(forKey: Self.keyLastSyncedDeviceOs)
  }

  public func setLastSyncedDeviceOs(_ value: String?) {
    defaults.set(value, forKey: Self.keyLastSyncedDeviceOs)
  }

  public func getLastSyncedDeviceModel() -> String? {
    defaults.string(forKey: Self.keyLastSyncedDeviceModel)
  }

  public func setLastSyncedDeviceModel(_ value: String?) {
    defaults.set(value, forKey: Self.keyLastSyncedDeviceModel)
  }

  public func getLastSyncedSdkVersion() -> String? {
    defaults.string(forKey: Self.keyLastSyncedSdkVersion)
  }

  public func setLastSyncedSdkVersion(_ value: String?) {
    defaults.set(value, forKey: Self.keyLastSyncedSdkVersion)
  }

  public func getLastSyncedTimezoneId() -> String? {
    defaults.string(forKey: Self.keyLastSyncedTimezoneId)
  }

  public func setLastSyncedTimezoneId(_ value: String?) {
    defaults.set(value, forKey: Self.keyLastSyncedTimezoneId)
  }

  public func getLastSyncedLanguage() -> String? {
    defaults.string(forKey: Self.keyLastSyncedLanguage)
  }

  public func setLastSyncedLanguage(_ value: String?) {
    defaults.set(value, forKey: Self.keyLastSyncedLanguage)
  }

  public func getLastSyncedPermissionStatus() -> String? {
    defaults.string(forKey: Self.keyLastSyncedPermissionStatus)
  }

  public func setLastSyncedPermissionStatus(_ value: String?) {
    defaults.set(value, forKey: Self.keyLastSyncedPermissionStatus)
  }

  public func getLastUnsubscribedAtMs() -> Int64? {
    (defaults.object(forKey: Self.keyLastUnsubscribedAtMs) as? NSNumber)?.int64Value
  }

  public func setLastUnsubscribedAtMs(_ ms: Int64?) {
    defaults.set(ms.map(NSNumber.init(value:)), forKey: Self.keyLastUnsubscribedAtMs)
  }

  /// Stamp of an app-driven (`setSubscription(false)`) unsubscribe the
  /// backend has not acknowledged yet, nil otherwise. A retry re-sends this
  /// persisted value instead of a fresh `now` (DPF-14 records the detection
  /// time). Mirrors Android's `pendingUnsubscribeAtMs`.
  public func getPendingUnsubscribeAtMs() -> Int64? {
    (defaults.object(forKey: Self.keyPendingUnsubscribeAtMs) as? NSNumber)?.int64Value
  }

  public func setPendingUnsubscribeAtMs(_ ms: Int64?) {
    defaults.set(ms.map(NSNumber.init(value:)), forKey: Self.keyPendingUnsubscribeAtMs)
  }

  /// Same as `getPendingUnsubscribeAtMs`, for the permission-driven
  /// (granted -> denied) path.
  public func getPendingPermissionUnsubscribeAtMs() -> Int64? {
    (defaults.object(forKey: Self.keyPendingPermissionUnsubscribeAtMs) as? NSNumber)?.int64Value
  }

  public func setPendingPermissionUnsubscribeAtMs(_ ms: Int64?) {
    defaults.set(ms.map(NSNumber.init(value:)), forKey: Self.keyPendingPermissionUnsubscribeAtMs)
  }

  public func getEmail() -> String? {
    defaults.string(forKey: Self.keyEmail)
  }

  public func setEmail(_ value: String?) {
    defaults.set(value, forKey: Self.keyEmail)
  }

  public func getPhone() -> String? {
    defaults.string(forKey: Self.keyPhone)
  }

  public func setPhone(_ value: String?) {
    defaults.set(value, forKey: Self.keyPhone)
  }

  /// The last email value the backend acknowledged (2xx), nil when a clear
  /// was acknowledged or nothing was ever synced. Distinguishes "held nil and
  /// already cleared server-side" from "held nil but the clear never landed",
  /// so a failed/pre-init clear is re-sent at the next registration (DPF-18).
  public func getLastSyncedEmail() -> String? {
    defaults.string(forKey: Self.keyLastSyncedEmail)
  }

  public func setLastSyncedEmail(_ value: String?) {
    defaults.set(value, forKey: Self.keyLastSyncedEmail)
  }

  /// Phone counterpart of `getLastSyncedEmail`.
  public func getLastSyncedPhone() -> String? {
    defaults.string(forKey: Self.keyLastSyncedPhone)
  }

  public func setLastSyncedPhone(_ value: String?) {
    defaults.set(value, forKey: Self.keyLastSyncedPhone)
  }
}
