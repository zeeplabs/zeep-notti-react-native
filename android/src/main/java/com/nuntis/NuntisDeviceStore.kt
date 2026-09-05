package com.nuntis

import android.content.SharedPreferences

/**
 * Persisted device state mirroring the Nuntis `Device` row this install owns
 * (design.md `DeviceState`). Backed by [SharedPreferences] since it's a
 * handful of scalar fields plus a small tag map — no query needs.
 */
data class DeviceState(
  val deviceId: String?,
  val lastToken: String?,
  val tags: Map<String, String>,
  val externalUserId: String?,
  val subscribed: Boolean
)

class NuntisDeviceStore(private val prefs: SharedPreferences) {

  companion object {
    private const val KEY_DEVICE_ID = "nuntis_device_id"
    private const val KEY_LAST_TOKEN = "nuntis_last_token"
    private const val KEY_EXTERNAL_USER_ID = "nuntis_external_user_id"
    private const val KEY_SUBSCRIBED = "nuntis_subscribed"
    private const val TAG_KEY_PREFIX = "nuntis_tag_"

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
    subscribed = getSubscribed()
  )
}
