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
  val locationSharingEnabled: Boolean // P3 opt-in flag, default false
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
    locationSharingEnabled = getLocationSharingEnabled()
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
    prefs.edit().putBoolean(KEY_LOCATION_SHARING_ENABLED, locationSharingEnabled).apply()
  }
}
