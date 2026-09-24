package com.notti

import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import java.io.IOException

data class DeviceResponse(val id: String, val tags: Map<String, String>)

sealed class ApiResult {
  data class Success(val response: DeviceResponse) : ApiResult()
  data class Failure(val message: String) : ApiResult()
}

/**
 * Talks to Notti' `/v1/apps/{app_id}/devices` endpoints (design.md
 * NottiApiClient). Retries a 5xx response or network failure with
 * exponential backoff (2s, 4s, 8s, 16s, 32s), capped at 5 attempts, per
 * design.md's Tech Decisions. `sleeper` is injectable so tests can skip the
 * real delay; production callers use the default (real `Thread.sleep`).
 */
class NottiApiClient(
  private val httpClient: OkHttpClient,
  private val baseUrl: String,
  private val appId: String,
  private val clientKey: String,
  private val sleeper: (Long) -> Unit = { Thread.sleep(it) }
) {

  companion object {
    private const val MAX_ATTEMPTS = 5
    private const val BASE_DELAY_MS = 2000L
  }

  private val jsonMediaType = "application/json; charset=utf-8".toMediaType()

  fun createOrUpdateDevice(token: String, platform: String): ApiResult {
    val body = JSONObject()
      .put("token", token)
      .put("platform", platform)
      .toString()
      .toRequestBody(jsonMediaType)

    val request = Request.Builder()
      .url("$baseUrl/v1/apps/$appId/devices")
      .header("Authorization", "Bearer $clientKey")
      .post(body)
      .build()

    return executeWithRetry(request)
  }

  /** PATCH always includes the cached `token` field (AD-009 ownership proof). */
  fun patchDevice(deviceId: String, token: String, fields: Map<String, Any>): ApiResult {
    val json = buildPatchJson(token, fields)

    val body = json.toString().toRequestBody(jsonMediaType)

    val request = Request.Builder()
      .url("$baseUrl/v1/apps/$appId/devices/$deviceId")
      .header("Authorization", "Bearer $clientKey")
      .patch(body)
      .build()

    return executeWithRetry(request)
  }

  /**
   * Builds the PATCH payload, converting composite values (maps, lists) into
   * real `JSONObject`/`JSONArray` nodes instead of handing them to
   * `JSONObject.put(String, Any)` as-is.
   *
   * `put` only *stores* the value; the encoding happens later in
   * `JSONStringer.value(Object)`. Android's platform `org.json` (AOSP) has no
   * branch there for `Map` or `Collection` - it falls through to
   * `string(value.toString())`, so `mapOf("tags" to mapOf("plan" to "vip"))`
   * ships as `{"tags":"{plan=vip}"}` (a *string*) instead of a nested object,
   * and the backend rejects or misreads it. iOS' `JSONSerialization` encodes
   * the nested dictionary correctly, so the two platforms silently disagreed.
   *
   * This is invisible to unit tests because the JVM `org.json:json` artifact
   * used in the test source set (Crockford's implementation) *does* have a
   * `Map` branch - hence the explicit conversion here rather than relying on
   * whichever `org.json` happens to be on the classpath.
   */
  internal fun buildPatchJson(token: String, fields: Map<String, Any>): JSONObject {
    val json = JSONObject()
    fields.forEach { (key, value) -> json.put(key, toJsonValue(value)) }
    json.put("token", token)
    return json
  }

  private fun toJsonValue(value: Any?): Any = when (value) {
    null -> JSONObject.NULL
    is Map<*, *> -> JSONObject().also { nested ->
      value.forEach { (key, nestedValue) -> nested.put(key.toString(), toJsonValue(nestedValue)) }
    }
    is Collection<*> -> JSONArray().also { array ->
      value.forEach { element -> array.put(toJsonValue(element)) }
    }
    else -> value
  }

  private fun executeWithRetry(request: Request): ApiResult {
    var attempt = 0
    var delayMs = BASE_DELAY_MS
    var lastError = "unknown error"

    while (attempt < MAX_ATTEMPTS) {
      attempt++
      try {
        httpClient.newCall(request).execute().use { response ->
          if (response.isSuccessful) {
            val bodyString = response.body?.string().orEmpty()
            try {
              return ApiResult.Success(parseDeviceResponse(bodyString))
            } catch (e: JSONException) {
              // A 2xx that is not the documented device JSON: a captive
              // portal/proxy answering with HTML, a renamed field, or a
              // transient proxy glitch. Treated as retriable - same as a 5xx
              // and matching iOS' NottiApiClient.executeWithRetry - instead
              // of a terminal failure, since retrying is safe (registration
              // is idempotent) and gives a genuine transient hiccup a chance
              // to resolve instead of parking registration on the first bad
              // response.
              lastError = "malformed response body: ${e.message}"
            }
          } else if (response.code < 500) {
            // 4xx: not retried, terminal failure.
            return ApiResult.Failure("HTTP ${response.code}")
          } else {
            lastError = "HTTP ${response.code}"
          }
        }
      } catch (e: IOException) {
        lastError = e.message ?: "network error"
      }

      if (attempt < MAX_ATTEMPTS) {
        sleeper(delayMs)
        delayMs *= 2
      }
    }

    return ApiResult.Failure(lastError)
  }

  /**
   * Throws [JSONException] - reported by the caller as a terminal failure -
   * for a body that is not a device object. `id` must be present, a real
   * JSON string and non-blank: Android's `org.json` (AOSP) `getString` coerces
   * instead of validating, so `{"id":""}` yielded `""` and `{"id":123}`
   * yielded `"123"`, both reported as a successful registration. The caller
   * then persisted that id, wiped its local tags, and aimed every later PATCH
   * at `.../devices/` (or a fabricated id) with no way to recover - the
   * foreground retry only re-arms on a FAILED registration. Same rule as iOS'
   * `parseDeviceResponse` (`ios/NottiApiClient.swift`).
   */
  private fun parseDeviceResponse(bodyString: String): DeviceResponse {
    val json = JSONObject(bodyString)
    val id = json.opt("id") as? String
    if (id.isNullOrBlank()) {
      throw JSONException("response has no usable \"id\" field")
    }
    // `optJSONObject` rather than `has` + `getJSONObject`: `has("tags")` is
    // true for `"tags": null` (AOSP stores JSONObject.NULL there) and
    // `getJSONObject` then throws, which since 9c685e9 fails the whole
    // registration terminally. A nil `map[string]string` in Go serializes to
    // exactly that, so a legitimate "device has no tags" response could park
    // registration - and every queued mutation - forever. Absent, null and
    // non-object all mean "no tags", matching iOS' `as? [String: String] ?? [:]`.
    // `opt(key) as? String` rather than `getString(key)`: a non-string tag
    // value (a stray number/bool/object from a misbehaving backend) used to
    // throw JSONException, which the caller above catches and turns into a
    // whole-registration failure over one bad tag. Skipping just that key
    // matches iOS' per-value tolerance (see NottiApiClient.swift's
    // parseDeviceResponse) instead of discarding the entire response.
    val tags = mutableMapOf<String, String>()
    json.optJSONObject("tags")?.let { tagsJson ->
      tagsJson.keys().forEach { key ->
        (tagsJson.opt(key) as? String)?.let { value -> tags[key] = value }
      }
    }
    return DeviceResponse(id = id, tags = tags)
  }
}
