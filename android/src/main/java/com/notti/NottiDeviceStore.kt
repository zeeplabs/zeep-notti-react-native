package com.notti

import android.content.SharedPreferences

/**
 * Persisted device state mirroring the Notti `Device` row this install owns
 * (design.md `DeviceState`). Backed by [SharedPreferences] since it's a
 * handful of scalar fields plus a small tag map — no query needs.
 */
data class DeviceState(
  val deviceId: String?,
  val lastToken: String?,
  val tags: Map<String, String>,
  val externalUserId: String?,
  val subscribed: Boolean,
  // --- segment telemetry (design.md `DeviceState`) ---
  val appVersion: String?, // last successfully synced app version (P1)
  val firstSessionAtMs: Long?, // set once, never overwritten (P2)
  val lastSessionAtMs: Long?, // last session end (P2)
  val sessionCount: Int, // running total (P2)
  val sessionTimeMs: Long, // cumulative foreground ms (P2)
  val sessionStartedAtMs: Long?, // in-flight session, null when idle (P2)
  val locationSharingEnabled: Boolean, // P3 opt-in flag, default false
  // --- device profile fields (device-profile-fields design.md) ---
  val lastSyncedDeviceOs: String?, // P1 last synced OS version
  val lastSyncedDeviceModel: String?, // P1 last synced device model
  val lastSyncedSdkVersion: String?, // P1 last synced SDK version
  val lastSyncedTimezoneId: String?, // P2 last synced IANA timezone
  val lastSyncedLanguage: String?, // P2 last synced ISO 639-1 language
  val lastSyncedPermissionStatus: String?, // P3 last synced OS permission state
  val lastUnsubscribedAtMs: Long?, // P3 most-recent unsubscribe transition
  val email: String?, // P4 held email (what the integrator last set)
  val phone: String?, // P4 held phone (what the integrator last set)
  val lastSyncedEmail: String?, // P4 last email the backend acknowledged
  val lastSyncedPhone: String?, // P4 last phone the backend acknowledged
  val permissionRequested: Boolean // P3 SDK has shown the POST_NOTIFICATIONS prompt
)

class NottiDeviceStore(private val prefs: SharedPreferences) {

  companion object {
    private const val KEY_DEVICE_ID = "notti_device_id"
    private const val KEY_LAST_TOKEN = "notti_last_token"
    private const val KEY_EXTERNAL_USER_ID = "notti_external_user_id"
    private const val KEY_SUBSCRIBED = "notti_subscribed"
    private const val TAG_KEY_PREFIX = "notti_tag_"

    // --- segment telemetry keys (same `notti_*` convention) ---
    private const val KEY_APP_VERSION = "notti_app_version"
    private const val KEY_FIRST_SESSION_AT = "notti_first_session_at_ms"
    private const val KEY_LAST_SESSION_AT = "notti_last_session_at_ms"
    private const val KEY_SESSION_COUNT = "notti_session_count"
    private const val KEY_SESSION_TIME_MS = "notti_session_time_ms"
    private const val KEY_SESSION_STARTED_AT = "notti_session_started_at_ms"
    private const val KEY_LOCATION_SHARING_ENABLED = "notti_location_sharing_enabled"
    private const val KEY_PENDING_COUNTRY_CLEAR = "notti_pending_country_clear"
    private const val KEY_LAST_SYNCED_COUNTRY = "notti_last_synced_country"
    private const val KEY_LAST_FOREGROUND_AT = "notti_last_foreground_at_ms"

    // --- device profile field keys (same `notti_*` convention) ---
    private const val KEY_LAST_SYNCED_DEVICE_OS = "notti_last_synced_device_os"
    private const val KEY_LAST_SYNCED_DEVICE_MODEL = "notti_last_synced_device_model"
    private const val KEY_LAST_SYNCED_SDK_VERSION = "notti_last_synced_sdk_version"
    private const val KEY_LAST_SYNCED_TIMEZONE_ID = "notti_last_synced_timezone_id"
    private const val KEY_LAST_SYNCED_LANGUAGE = "notti_last_synced_language"
    private const val KEY_LAST_SYNCED_PERMISSION_STATUS = "notti_last_synced_permission_status"
    private const val KEY_LAST_UNSUBSCRIBED_AT_MS = "notti_last_unsubscribed_at_ms"
    private const val KEY_EMAIL = "notti_email"
    private const val KEY_PHONE = "notti_phone"
    private const val KEY_LAST_SYNCED_EMAIL = "notti_last_synced_email"
    private const val KEY_LAST_SYNCED_PHONE = "notti_last_synced_phone"
    private const val KEY_PERMISSION_REQUESTED = "notti_permission_requested"
    private const val KEY_PENDING_UNSUBSCRIBE_AT_MS = "notti_pending_unsubscribe_at_ms"
    private const val KEY_PENDING_PERMISSION_UNSUBSCRIBE_AT_MS = "notti_pending_permission_unsubscribe_at_ms"

    /**
     * Pure merge of the current tag map against an add map and/or a remove
     * key list, as issued by a single tag-mutation call (spec P3-AC8).
     * Removes are applied before adds, so a key present in both `add` and
     * `remove` within the same call ends up added (add wins on overlap).
     */
    @JvmStatic
    fun mergeTags(
      current: Map<String, String>,
      add: Map<String, String>? = null,
      remove: List<String>? = null
    ): Map<String, String> {
      val result = current.toMutableMap()
      remove?.forEach { result.remove(it) }
      add?.forEach { (key, value) -> result[key] = value }
      return result
    }
  }

  fun getDeviceId(): String? = prefs.getString(KEY_DEVICE_ID, null)

  fun setDeviceId(deviceId: String?) {
    prefs.edit().putString(KEY_DEVICE_ID, deviceId).apply()
  }

  fun getLastToken(): String? = prefs.getString(KEY_LAST_TOKEN, null)

  fun setLastToken(token: String?) {
    prefs.edit().putString(KEY_LAST_TOKEN, token).apply()
  }

  fun getExternalUserId(): String? = prefs.getString(KEY_EXTERNAL_USER_ID, null)

  fun setExternalUserId(externalUserId: String?) {
    prefs.edit().putString(KEY_EXTERNAL_USER_ID, externalUserId).apply()
  }

  fun getSubscribed(): Boolean = prefs.getBoolean(KEY_SUBSCRIBED, false)

  /**
   * Tri-state read of the locally-known subscription: `null` when this install
   * has never had a subscription PATCH acknowledged (key absent). The backend
   * creates a new device row with `subscribed = true`, so an unknown local
   * state must not be read as `false` when deciding whether an unsubscribe is
   * a real transition (DPF-14). [getSubscribed] keeps its `false` default.
   */
  fun getSubscribedOrNull(): Boolean? =
    if (prefs.contains(KEY_SUBSCRIBED)) prefs.getBoolean(KEY_SUBSCRIBED, false) else null

  fun setSubscribed(subscribed: Boolean) {
    prefs.edit().putBoolean(KEY_SUBSCRIBED, subscribed).apply()
  }

  fun getTags(): Map<String, String> {
    return prefs.all
      .filterKeys { it.startsWith(TAG_KEY_PREFIX) }
      .mapKeys { (key, _) -> key.removePrefix(TAG_KEY_PREFIX) }
      .mapValues { (_, value) -> value as String }
  }

  fun setTags(tags: Map<String, String>) {
    val editor = prefs.edit()
    getTags().keys.forEach { key -> editor.remove(TAG_KEY_PREFIX + key) }
    tags.forEach { (key, value) -> editor.putString(TAG_KEY_PREFIX + key, value) }
    editor.apply()
  }

  fun getState(): DeviceState = DeviceState(
    deviceId = getDeviceId(),
    lastToken = getLastToken(),
    tags = getTags(),
    externalUserId = getExternalUserId(),
    subscribed = getSubscribed(),
    appVersion = getAppVersion(),
    firstSessionAtMs = getFirstSessionAtMs(),
    lastSessionAtMs = getLastSessionAtMs(),
    sessionCount = getSessionCount(),
    sessionTimeMs = getSessionTimeMs(),
    sessionStartedAtMs = getSessionStartedAtMs(),
    locationSharingEnabled = getLocationSharingEnabled(),
    lastSyncedDeviceOs = getLastSyncedDeviceOs(),
    lastSyncedDeviceModel = getLastSyncedDeviceModel(),
    lastSyncedSdkVersion = getLastSyncedSdkVersion(),
    lastSyncedTimezoneId = getLastSyncedTimezoneId(),
    lastSyncedLanguage = getLastSyncedLanguage(),
    lastSyncedPermissionStatus = getLastSyncedPermissionStatus(),
    lastUnsubscribedAtMs = getLastUnsubscribedAtMs(),
    email = getEmail(),
    phone = getPhone(),
    lastSyncedEmail = getLastSyncedEmail(),
    lastSyncedPhone = getLastSyncedPhone(),
    permissionRequested = getPermissionRequested()
  )

  fun getAppVersion(): String? = prefs.getString(KEY_APP_VERSION, null)

  fun setAppVersion(appVersion: String?) {
    prefs.edit().putString(KEY_APP_VERSION, appVersion).apply()
  }

  fun getFirstSessionAtMs(): Long? = prefs.getLong(KEY_FIRST_SESSION_AT, -1L).takeIf { it >= 0 }

  fun setFirstSessionAtMs(firstSessionAtMs: Long) {
    prefs.edit().putLong(KEY_FIRST_SESSION_AT, firstSessionAtMs).apply()
  }

  fun getLastSessionAtMs(): Long? = prefs.getLong(KEY_LAST_SESSION_AT, -1L).takeIf { it >= 0 }

  fun setLastSessionAtMs(lastSessionAtMs: Long) {
    prefs.edit().putLong(KEY_LAST_SESSION_AT, lastSessionAtMs).apply()
  }

  fun getSessionCount(): Int = prefs.getInt(KEY_SESSION_COUNT, 0)

  fun setSessionCount(sessionCount: Int) {
    prefs.edit().putInt(KEY_SESSION_COUNT, sessionCount).apply()
  }

  fun getSessionTimeMs(): Long = prefs.getLong(KEY_SESSION_TIME_MS, 0L)

  fun setSessionTimeMs(sessionTimeMs: Long) {
    prefs.edit().putLong(KEY_SESSION_TIME_MS, sessionTimeMs).apply()
  }

  fun getSessionStartedAtMs(): Long? = prefs.getLong(KEY_SESSION_STARTED_AT, -1L).takeIf { it >= 0 }

  fun setSessionStartedAtMs(sessionStartedAtMs: Long?) {
    prefs.edit().putLong(KEY_SESSION_STARTED_AT, sessionStartedAtMs ?: -1L).apply()
  }

  fun getLocationSharingEnabled(): Boolean = prefs.getBoolean(KEY_LOCATION_SHARING_ENABLED, false)

  fun setLocationSharingEnabled(locationSharingEnabled: Boolean) {
    // commit(), not apply(): an opt-out must survive process death. Callers are off main (RN native-modules thread / notti-io).
    prefs.edit().putBoolean(KEY_LOCATION_SHARING_ENABLED, locationSharingEnabled).commit()
  }

  /**
   * LGPD opt-out durability (SEGTEL-13): true from the moment location sharing
   * is turned off (after having been on / after a country was synced) until a
   * `{country: null}` PATCH is acknowledged with a 2xx. Persisted so an opt-out
   * issued before `initialize()`, offline, or killed mid-retry is re-sent on
   * the next registration/foreground/flush instead of being lost.
   */
  fun getPendingCountryClear(): Boolean = prefs.getBoolean(KEY_PENDING_COUNTRY_CLEAR, false)

  fun setPendingCountryClear(pending: Boolean) {
    // commit(), not apply(): the LGPD clear obligation must survive process death. Callers are off main (RN native-modules thread / notti-io).
    prefs.edit().putBoolean(KEY_PENDING_COUNTRY_CLEAR, pending).commit()
  }

  /** Last country acknowledged by the backend (diff before re-sending), or null. */
  fun getLastSyncedCountry(): String? = prefs.getString(KEY_LAST_SYNCED_COUNTRY, null)

  fun setLastSyncedCountry(country: String?) {
    prefs.edit().putString(KEY_LAST_SYNCED_COUNTRY, country).apply()
  }

  /**
   * Last known foreground timestamp of the in-flight session (SEGTEL-08
   * heartbeat): the end used to close a session orphaned by a kill/crash.
   */
  fun getLastForegroundAtMs(): Long? = prefs.getLong(KEY_LAST_FOREGROUND_AT, -1L).takeIf { it >= 0 }

  fun setLastForegroundAtMs(lastForegroundAtMs: Long?) {
    prefs.edit().putLong(KEY_LAST_FOREGROUND_AT, lastForegroundAtMs ?: -1L).apply()
  }

  // --- device profile field accessors (device-profile-fields) ---

  fun getLastSyncedDeviceOs(): String? = prefs.getString(KEY_LAST_SYNCED_DEVICE_OS, null)

  fun setLastSyncedDeviceOs(value: String?) {
    prefs.edit().putString(KEY_LAST_SYNCED_DEVICE_OS, value).apply()
  }

  fun getLastSyncedDeviceModel(): String? = prefs.getString(KEY_LAST_SYNCED_DEVICE_MODEL, null)

  fun setLastSyncedDeviceModel(value: String?) {
    prefs.edit().putString(KEY_LAST_SYNCED_DEVICE_MODEL, value).apply()
  }

  fun getLastSyncedSdkVersion(): String? = prefs.getString(KEY_LAST_SYNCED_SDK_VERSION, null)

  fun setLastSyncedSdkVersion(value: String?) {
    prefs.edit().putString(KEY_LAST_SYNCED_SDK_VERSION, value).apply()
  }

  fun getLastSyncedTimezoneId(): String? = prefs.getString(KEY_LAST_SYNCED_TIMEZONE_ID, null)

  fun setLastSyncedTimezoneId(value: String?) {
    prefs.edit().putString(KEY_LAST_SYNCED_TIMEZONE_ID, value).apply()
  }

  fun getLastSyncedLanguage(): String? = prefs.getString(KEY_LAST_SYNCED_LANGUAGE, null)

  fun setLastSyncedLanguage(value: String?) {
    prefs.edit().putString(KEY_LAST_SYNCED_LANGUAGE, value).apply()
  }

  fun getLastSyncedPermissionStatus(): String? =
    prefs.getString(KEY_LAST_SYNCED_PERMISSION_STATUS, null)

  fun setLastSyncedPermissionStatus(value: String?) {
    prefs.edit().putString(KEY_LAST_SYNCED_PERMISSION_STATUS, value).apply()
  }

  fun getLastUnsubscribedAtMs(): Long? =
    prefs.getLong(KEY_LAST_UNSUBSCRIBED_AT_MS, -1L).takeIf { it >= 0 }

  fun setLastUnsubscribedAtMs(value: Long?) {
    prefs.edit().putLong(KEY_LAST_UNSUBSCRIBED_AT_MS, value ?: -1L).apply()
  }

  fun getEmail(): String? = prefs.getString(KEY_EMAIL, null)

  fun setEmail(value: String?) {
    // commit(), not apply(): a clear (held = null) must survive process death (LGPD). Callers are off main (RN native-modules thread).
    prefs.edit().putString(KEY_EMAIL, value).commit()
  }

  fun getPhone(): String? = prefs.getString(KEY_PHONE, null)

  fun setPhone(value: String?) {
    prefs.edit().putString(KEY_PHONE, value).commit()
  }

  /**
   * Last email/phone the backend acknowledged with a 2xx (`null` = cleared or
   * never synced). Diffed against the held value so a set or clear whose PATCH
   * failed - or was issued before `initialize()`, or dropped with the
   * in-memory queue on process death - is re-sent at the next registration
   * instead of being silently lost (DPF-17..20).
   */
  fun getLastSyncedEmail(): String? = prefs.getString(KEY_LAST_SYNCED_EMAIL, null)

  fun setLastSyncedEmail(value: String?) {
    // commit(), not apply(): a clear's ack must survive process death (LGPD). Callers are on notti-io.
    prefs.edit().putString(KEY_LAST_SYNCED_EMAIL, value).commit()
  }

  fun getLastSyncedPhone(): String? = prefs.getString(KEY_LAST_SYNCED_PHONE, null)

  fun setLastSyncedPhone(value: String?) {
    prefs.edit().putString(KEY_LAST_SYNCED_PHONE, value).commit()
  }

  /**
   * True once the SDK has shown the Android 13+ `POST_NOTIFICATIONS` prompt.
   * Lets the permission-status read tell "never asked" (`notDetermined`) from
   * "denied without rationale" (`denied`), which the OS APIs alone cannot.
   */
  fun getPermissionRequested(): Boolean = prefs.getBoolean(KEY_PERMISSION_REQUESTED, false)

  fun setPermissionRequested(value: Boolean) {
    prefs.edit().putBoolean(KEY_PERMISSION_REQUESTED, value).apply()
  }

  /**
   * Detection time of an app-driven (`setSubscription(false)`) unsubscribe
   * whose PATCH has not been acknowledged yet, or `null`. Stamped once when
   * the transition is detected and re-sent as-is on every retry, so the
   * backend records when the user unsubscribed, not when the sync landed.
   */
  fun getPendingUnsubscribeAtMs(): Long? =
    prefs.getLong(KEY_PENDING_UNSUBSCRIBE_AT_MS, -1L).takeIf { it >= 0 }

  fun setPendingUnsubscribeAtMs(value: Long?) {
    prefs.edit().putLong(KEY_PENDING_UNSUBSCRIBE_AT_MS, value ?: -1L).apply()
  }

  /** Same as [getPendingUnsubscribeAtMs], for the permission-driven (granted -> denied) path. */
  fun getPendingPermissionUnsubscribeAtMs(): Long? =
    prefs.getLong(KEY_PENDING_PERMISSION_UNSUBSCRIBE_AT_MS, -1L).takeIf { it >= 0 }

  fun setPendingPermissionUnsubscribeAtMs(value: Long?) {
    prefs.edit().putLong(KEY_PENDING_PERMISSION_UNSUBSCRIBE_AT_MS, value ?: -1L).apply()
  }
}
