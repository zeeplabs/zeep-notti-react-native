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
 * Result of the shared retry loop in [NottiApiClient.executeWithRetry]:
 * [Success] carries the value `parseSuccess` produced for a usable 2xx,
 * [Failure] the reason (last HTTP status or network error) once the retry
 * cap is exhausted or a terminal (4xx) response is received.
 */
sealed class RetryResult<out T> {
  data class Success<T>(val value: T) : RetryResult<T>()
  data class Failure(val message: String) : RetryResult<Nothing>()
}

/** Result of [NottiApiClient.reportEvent]: any 2xx is a [Success]. */
sealed class EventResult {
  object Success : EventResult()
  data class Failure(val message: String) : EventResult()
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

    // Registration is the one call that *depends* on the response body: the
    // `id` it returns is the resource every later PATCH is addressed to, so a
    // 2xx without a device object is not a usable success.
    return executeWithRetry(request) { bodyString -> parseDeviceResponse(bodyString, fallbackTags = null) }
      .toApiResult()
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

    // Unlike registration, PATCH creates nothing: the caller already knows
    // the device id it addressed and the field values it just applied. A
    // REST backend is free to acknowledge it with 204 No Content, an empty
    // body, or a bare {"ok":true}, so requiring a full device object here
    // turned a perfectly good update into five retries and dropped the
    // local persistence of external_user_id/tags. Any 2xx is accepted; the
    // body is used when it happens to carry a device object, and otherwise
    // the request itself is the source of truth. Matches iOS'
    // NottiApiClient.swift's patchDevice.
    @Suppress("UNCHECKED_CAST")
    val fallbackTags = fields["tags"] as? Map<String, String> ?: emptyMap()
    return executeWithRetry(request) { bodyString ->
      parseDeviceResponse(bodyString, fallbackTags = fallbackTags) ?: DeviceResponse(id = deviceId, tags = fallbackTags)
    }.toApiResult()
  }

  /**
   * Reports a single push-notification event (e.g. "received" or "clicked")
   * to `POST /v1/apps/{app_id}/notifications/{notification_id}/events`.
   *
   * The request body carries the event's `delivery_id`, `type` and the
   * device's `token` (snake_case - the backend contract), authenticated with
   * the client key as `Authorization: Bearer <key>`. Any 2xx acknowledges
   * the event and the response body is ignored. 5xx responses and network
   * failures are retried with exponential backoff (2s, 4s, 8s, 16s, 32s)
   * capped at 5 attempts, matching device registration; 4xx responses are
   * terminal failures and not retried.
   */
  fun reportEvent(notificationId: String, deliveryId: String, type: String, token: String): EventResult {
    val body = JSONObject()
      .put("delivery_id", deliveryId)
      .put("type", type)
      .put("token", token)
      .toString()
      .toRequestBody(jsonMediaType)

    val request = Request.Builder()
      .url("$baseUrl/v1/apps/$appId/notifications/$notificationId/events")
      .header("Authorization", "Bearer $clientKey")
      .post(body)
      .build()

    // The backend is free to acknowledge an event with 200 + a JSON payload,
    // a bare 204 No Content, or nothing at all - none of it is needed by the
    // caller (the local queue entry is removed by its own id once this
    // returns Success). So any 2xx is a success and `parseSuccess` always
    // returns a non-null dummy value, never hitting the retry-on-2xx path.
    return executeWithRetry(request) { true }
      .toEventResult()
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

  /**
   * `parseSuccess` turns a 2xx body into the value to report, or `null` to
   * treat that 2xx as a retriable failure - mirrors iOS'
   * `NottiApiClient.executeWithRetry(_:parseSuccess:)`.
   */
  private fun <T> executeWithRetry(request: Request, parseSuccess: (String) -> T?): RetryResult<T> {
    var attempt = 0
    var delayMs = BASE_DELAY_MS
    var lastError = "unknown error"

    while (attempt < MAX_ATTEMPTS) {
      attempt++
      try {
        httpClient.newCall(request).execute().use { response ->
          if (response.isSuccessful) {
            val bodyString = response.body?.string().orEmpty()
            val value = parseSuccess(bodyString)
            if (value != null) {
              return RetryResult.Success(value)
            }
            // A 2xx that parseSuccess could not turn into a usable value (a
            // captive portal/proxy answering with HTML, a renamed field, or a
            // transient proxy glitch). Treated as retriable - same as a 5xx
            // and matching iOS' NottiApiClient.executeWithRetry - instead of
            // a terminal failure, since retrying is safe (registration is
            // idempotent) and gives a genuine transient hiccup a chance to
            // resolve instead of parking registration on the first bad
            // response.
            lastError = "HTTP ${response.code} with an unparseable response body"
          } else if (response.code < 500) {
            // 4xx: not retried, terminal failure.
            return RetryResult.Failure("HTTP ${response.code}")
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

    return RetryResult.Failure(lastError)
  }

  private fun RetryResult<DeviceResponse>.toApiResult(): ApiResult = when (this) {
    is RetryResult.Success -> ApiResult.Success(value)
    is RetryResult.Failure -> ApiResult.Failure(message)
  }

  private fun RetryResult<*>.toEventResult(): EventResult = when (this) {
    is RetryResult.Success -> EventResult.Success
    is RetryResult.Failure -> EventResult.Failure(message)
  }

  /**
   * Returns `null` - reported by the caller as a retriable failure - for a
   * body that is not a device object. `id` must be present, a real JSON
   * string and non-blank: Android's `org.json` (AOSP) `getString` coerces
   * instead of validating, so `{"id":""}` yielded `""` and `{"id":123}`
   * yielded `"123"`, both reported as a successful registration. The caller
   * then persisted that id, wiped its local tags, and aimed every later PATCH
   * at `.../devices/` (or a fabricated id) with no way to recover - the
   * foreground retry only re-arms on a FAILED registration. Same rule as iOS'
   * `parseDeviceResponse` (`ios/NottiApiClient.swift`).
   *
   * `fallbackTags`, when non-null, is what the caller optimistically applied
   * to the PATCH about to be acknowledged. A PATCH ack is allowed to omit
   * `tags` entirely (a REST backend answering `204 No Content` or a bare
   * `{"id":"dev_1"}` per the comment above `patchDevice`) - treating that
   * absence the same as an explicit `"tags":{}` silently wiped the local tag
   * cache on every such ack, on a call that never touched tags at all (found
   * by pre-release review, A3). Only a `tags` key that is actually present
   * *and* a JSON object is treated as the server's authoritative answer,
   * including an explicit `{}` clearing everything; absent, `null`, or a
   * malformed value all fall back to what was just applied.
   */
  private fun parseDeviceResponse(bodyString: String, fallbackTags: Map<String, String>?): DeviceResponse? {
    val json = try {
      JSONObject(bodyString)
    } catch (e: JSONException) {
      return null
    }
    val id = json.opt("id") as? String
    if (id.isNullOrBlank()) {
      return null
    }
    // `opt(key) as? String` rather than `getString(key)`: a non-string tag
    // value (a stray number/bool/object from a misbehaving backend) used to
    // throw JSONException, which the caller above catches and turns into a
    // whole-registration failure over one bad tag. Skipping just that key
    // matches iOS' per-value tolerance (see NottiApiClient.swift's
    // parseDeviceResponse) instead of discarding the entire response.
    val rawTags = json.optJSONObject("tags")
    val tags = if (rawTags != null) {
      mutableMapOf<String, String>().also { tags ->
        rawTags.keys().forEach { key ->
          (rawTags.opt(key) as? String)?.let { value -> tags[key] = value }
        }
      }
    } else {
      fallbackTags ?: emptyMap()
    }
    return DeviceResponse(id = id, tags = tags)
  }
}
