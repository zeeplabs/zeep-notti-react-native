package com.notti

import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.SocketPolicy
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.TimeUnit

class NottiApiClientTest {

  private lateinit var server: MockWebServer
  private lateinit var client: NottiApiClient
  private val sleeps = mutableListOf<Long>()

  @Before
  fun setUp() {
    server = MockWebServer()
    server.start()
    client = NottiApiClient(
      httpClient = OkHttpClient(),
      baseUrl = server.url("/").toString().trimEnd('/'),
      appId = "app-1",
      clientKey = "secret-key",
      sleeper = { ms -> sleeps.add(ms) }
    )
  }

  @After
  fun tearDown() {
    server.shutdown()
  }

  @Test
  fun `createOrUpdateDevice sends POST with correct headers and body`() {
    server.enqueue(
      MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}""")
    )

    val result = client.createOrUpdateDevice(token = "fcm-token", platform = "android")

    val recorded = requireNotNull(server.takeRequest(5, TimeUnit.SECONDS))
    assertEquals("POST", recorded.method)
    assertEquals("/v1/apps/app-1/devices", recorded.path)
    assertEquals("Bearer secret-key", recorded.getHeader("Authorization"))

    val sentBody = JSONObject(recorded.body.readUtf8())
    assertEquals("fcm-token", sentBody.getString("token"))
    assertEquals("android", sentBody.getString("platform"))

    assertTrue(result is ApiResult.Success)
    assertEquals("device-1", (result as ApiResult.Success).response.id)
  }

  @Test
  fun `patchDevice always includes the cached token field`() {
    server.enqueue(
      MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{"plan":"vip"}}""")
    )

    val result = client.patchDevice(
      deviceId = "device-1",
      token = "fcm-token",
      fields = mapOf("subscribed" to true)
    )

    val recorded = requireNotNull(server.takeRequest(5, TimeUnit.SECONDS))
    assertEquals("PATCH", recorded.method)
    assertEquals("/v1/apps/app-1/devices/device-1", recorded.path)

    val sentBody = JSONObject(recorded.body.readUtf8())
    assertEquals("fcm-token", sentBody.getString("token"))
    assertEquals(true, sentBody.getBoolean("subscribed"))

    assertTrue(result is ApiResult.Success)
    assertEquals(mapOf("plan" to "vip"), (result as ApiResult.Success).response.tags)
  }

  @Test
  fun `patchDevice succeeds on a 204 No Content response with no retry`() {
    server.enqueue(MockResponse().setResponseCode(204))

    val result = client.patchDevice(
      deviceId = "device-1",
      token = "fcm-token",
      fields = mapOf("subscribed" to true)
    )

    assertEquals(1, server.requestCount)
    assertTrue("expected a Success, got $result", result is ApiResult.Success)
    assertEquals("device-1", (result as ApiResult.Success).response.id)
  }

  @Test
  fun `patchDevice succeeds on a 200 with an empty body, falling back to the caller's own tags`() {
    server.enqueue(MockResponse().setResponseCode(200).setBody(""))

    val result = client.patchDevice(
      deviceId = "device-1",
      token = "fcm-token",
      fields = mapOf("tags" to mapOf("plan" to "vip"))
    )

    assertTrue("expected a Success, got $result", result is ApiResult.Success)
    val response = (result as ApiResult.Success).response
    assertEquals("device-1", response.id)
    assertEquals(mapOf("plan" to "vip"), response.tags)
  }

  @Test
  fun `patchDevice ack with an id but no tags key preserves the caller's own tags (A3)`() {
    // A real device object missing only "tags" - distinct from the
    // ok-true/empty-body cases above, which have no "id" at all and hit the
    // DeviceResponse(deviceId, fallbackTags) fallback below parseDeviceResponse
    // entirely. This body parses successfully (valid "id"), so before the A3
    // fix it reported tags = emptyMap() and the caller wiped its local cache
    // on a PATCH that never touched tags.
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1"}"""))

    val result = client.patchDevice(
      deviceId = "device-1",
      token = "fcm-token",
      fields = mapOf("subscribed" to true, "tags" to mapOf("plan" to "vip"))
    )

    assertTrue("expected a Success, got $result", result is ApiResult.Success)
    assertEquals(mapOf("plan" to "vip"), (result as ApiResult.Success).response.tags)
  }

  @Test
  fun `patchDevice ack exposes the echoed profile fields`() {
    // The backend answers PATCH with the full stored device; the six read-once
    // profile fields are the SDK's only server-side ack that a value landed.
    server.enqueue(
      MockResponse().setResponseCode(200).setBody(
        """{"id":"device-1","tags":{},"app_version":"1.2.3","device_os":"15.0","device_model":"Pixel 8",""" +
          """"sdk_version":"0.5.0","timezone_id":"America/Sao_Paulo","language":"pt","country":"BR"}"""
      )
    )

    val result = client.patchDevice(deviceId = "device-1", token = "fcm-token", fields = mapOf("app_version" to "1.2.3"))

    assertTrue("expected a Success, got $result", result is ApiResult.Success)
    assertEquals(
      mapOf(
        "app_version" to "1.2.3",
        "device_os" to "15.0",
        "device_model" to "Pixel 8",
        "sdk_version" to "0.5.0",
        "timezone_id" to "America/Sao_Paulo",
        "language" to "pt"
      ),
      (result as ApiResult.Success).response.profileFields
    )
  }

  @Test
  fun `patchDevice ack without a device body has no echoed profile fields`() {
    server.enqueue(MockResponse().setResponseCode(204))

    val result = client.patchDevice(deviceId = "device-1", token = "fcm-token", fields = mapOf("app_version" to "1.2.3"))

    assertTrue("expected a Success, got $result", result is ApiResult.Success)
    assertEquals(emptyMap<String, String>(), (result as ApiResult.Success).response.profileFields)
  }

  @Test
  fun `patchDevice ack skips non-string and blank echoed profile fields`() {
    server.enqueue(
      MockResponse().setResponseCode(200)
        .setBody("""{"id":"device-1","app_version":123,"device_os":"","language":null,"timezone_id":"UTC"}""")
    )

    val result = client.patchDevice(deviceId = "device-1", token = "fcm-token", fields = mapOf("timezone_id" to "UTC"))

    assertEquals(mapOf("timezone_id" to "UTC"), (result as ApiResult.Success).response.profileFields)
  }

  @Test
  fun `patchDevice ack with an explicit empty tags object clears the cache`() {
    // Unlike an absent "tags" key above, an explicit "{}" is the server's
    // authoritative answer and must be honored, not treated as "no info".
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))

    val result = client.patchDevice(
      deviceId = "device-1",
      token = "fcm-token",
      fields = mapOf("tags" to mapOf("plan" to "vip"))
    )

    assertTrue("expected a Success, got $result", result is ApiResult.Success)
    assertEquals(emptyMap<String, String>(), (result as ApiResult.Success).response.tags)
  }

  @Test
  fun `patchDevice succeeds on a bare ok-true body`() {
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"ok":true}"""))

    val result = client.patchDevice(
      deviceId = "device-1",
      token = "fcm-token",
      fields = mapOf("subscribed" to true)
    )

    assertTrue("expected a Success, got $result", result is ApiResult.Success)
    assertEquals("device-1", (result as ApiResult.Success).response.id)
  }

  @Test
  fun `5xx response retries then succeeds without exhausting the cap`() {
    server.enqueue(MockResponse().setResponseCode(500))
    server.enqueue(MockResponse().setResponseCode(503))
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))

    val result = client.createOrUpdateDevice(token = "t", platform = "android")

    assertEquals(3, server.requestCount)
    assertEquals(listOf(2000L, 4000L), sleeps)
    assertTrue(result is ApiResult.Success)
  }

  @Test
  fun `5xx responses exhaust the retry cap at exactly 5 attempts`() {
    repeat(5) { server.enqueue(MockResponse().setResponseCode(500)) }

    val result = client.createOrUpdateDevice(token = "t", platform = "android")

    assertEquals(5, server.requestCount)
    assertEquals(listOf(2000L, 4000L, 8000L, 16000L), sleeps)
    assertTrue(result is ApiResult.Failure)
  }

  @Test
  fun `network error is retried per the same backoff schedule`() {
    repeat(5) {
      server.enqueue(MockResponse().setSocketPolicy(SocketPolicy.DISCONNECT_AT_START))
    }

    val result = client.createOrUpdateDevice(token = "t", platform = "android")

    assertEquals(5, server.requestCount)
    assertEquals(listOf(2000L, 4000L, 8000L, 16000L), sleeps)
    assertTrue(result is ApiResult.Failure)
  }

  @Test
  fun `a successful response before the retry cap stops further retries`() {
    server.enqueue(MockResponse().setResponseCode(500))
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    // A third enqueued response would only be consumed if the client kept retrying.
    server.enqueue(MockResponse().setResponseCode(500))

    client.createOrUpdateDevice(token = "t", platform = "android")

    assertEquals(2, server.requestCount)
  }

  @Test
  fun `a 2xx whose body is not JSON is retried like a 5xx, not a terminal failure`() {
    // Captive portal / proxy shape: HTTP 200, HTML body - retriable since a
    // transient proxy glitch may clear on the next attempt, matching iOS'
    // executeWithRetry (a malformed 2xx returns nil from parseSuccess there
    // and falls into the same retry path as a 5xx).
    server.enqueue(
      MockResponse().setResponseCode(200).setBody("<html><body>Sign in to the network</body></html>")
    )
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))

    val result = client.createOrUpdateDevice(token = "t", platform = "android")

    assertEquals(2, server.requestCount)
    assertEquals(listOf(2000L), sleeps)
    assertTrue("expected a Success, got $result", result is ApiResult.Success)
  }

  @Test
  fun `malformed 2xx bodies exhaust the retry cap at exactly 5 attempts`() {
    repeat(5) {
      server.enqueue(MockResponse().setResponseCode(200).setBody("""{"device_id":"device-1"}"""))
    }

    val result = client.createOrUpdateDevice(token = "t", platform = "android")

    assertEquals(5, server.requestCount)
    assertEquals(listOf(2000L, 4000L, 8000L, 16000L), sleeps)
    assertTrue("expected a Failure, got $result", result is ApiResult.Failure)
  }

  @Test
  fun `a 2xx JSON body missing the id field is retried, not a terminal failure`() {
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"device_id":"device-1"}"""))
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))

    val result = client.createOrUpdateDevice(token = "t", platform = "android")

    assertEquals(2, server.requestCount)
    assertTrue("expected a Success, got $result", result is ApiResult.Success)
  }

  @Test
  fun `a 2xx JSON body with an empty id is retried, not a terminal failure`() {
    // AOSP's JSONObject.getString coerces rather than validates, so this used
    // to be reported as a successful registration carrying id "". The caller
    // then persisted "" (non-null, so nothing retried it) and PATCHed
    // `/v1/apps/app-1/devices/` - the collection, not a device - forever.
    // Now retriable instead of terminal: same treatment as any other
    // unusable 2xx body.
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"","tags":{"plan":"vip"}}"""))
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))

    val result = client.createOrUpdateDevice(token = "t", platform = "android")

    assertEquals(2, server.requestCount)
    assertTrue("expected a Success, got $result", result is ApiResult.Success)
  }

  @Test
  fun `a 2xx JSON body whose id is not a string is retried, not a terminal failure`() {
    // Same coercion trap from the other side: getString(123) returns "123",
    // fabricating a device id the backend never issued.
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":123,"tags":{}}"""))
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))

    val result = client.createOrUpdateDevice(token = "t", platform = "android")

    assertEquals(2, server.requestCount)
    assertTrue("expected a Success, got $result", result is ApiResult.Success)
  }

  @Test
  fun `a 2xx body with a null tags field registers successfully with no tags`() {
    // A nil map[string]string in Go serializes to `"tags": null`. has("tags")
    // is true for it and getJSONObject then threw, which since the malformed
    // -body fix meant a terminal registration failure on a perfectly
    // legitimate "this device has no tags" response.
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":null}"""))

    val result = client.createOrUpdateDevice(token = "t", platform = "android")

    assertTrue("expected a Success, got $result", result is ApiResult.Success)
    val response = (result as ApiResult.Success).response
    assertEquals("device-1", response.id)
    assertEquals(emptyMap<String, String>(), response.tags)
  }

  @Test
  fun `a non-string tag value is skipped, not a terminal failure for the whole response`() {
    // getString(key) on a non-string value used to throw JSONException,
    // which the caller wraps as a malformed-body failure - discarding a
    // perfectly good "id" and every other valid tag over one bad value.
    server.enqueue(
      MockResponse().setResponseCode(200)
        .setBody("""{"id":"device-1","tags":{"plan":"vip","score":42}}""")
    )

    val result = client.createOrUpdateDevice(token = "t", platform = "android")

    assertTrue("expected a Success, got $result", result is ApiResult.Success)
    val response = (result as ApiResult.Success).response
    assertEquals("device-1", response.id)
    assertEquals(mapOf("plan" to "vip"), response.tags)
  }

  @Test
  fun `a 2xx body with no tags field at all registers successfully with no tags`() {
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1"}"""))

    val result = client.createOrUpdateDevice(token = "t", platform = "android")

    assertTrue("expected a Success, got $result", result is ApiResult.Success)
    assertEquals(emptyMap<String, String>(), (result as ApiResult.Success).response.tags)
  }

  @Test
  fun `a map field is stored as a nested JSONObject, not as a raw Map`() {
    val json = client.buildPatchJson("fcm-token", mapOf("tags" to mapOf("plan" to "vip")))

    // The distinction that matters: `put(String, Any)` happily stores a raw
    // Map, and only the *encoder* decides what that becomes. Android's
    // platform JSONStringer has no Map branch and would emit it as a string.
    val tags = json.get("tags")
    assertTrue(
      "tags must be a JSONObject node, was ${tags.javaClass.name}",
      tags is JSONObject
    )
    assertEquals("vip", (tags as JSONObject).getString("plan"))
    assertEquals("fcm-token", json.getString("token"))
  }

  @Test
  fun `a map field survives Android's org json encoder as a nested object`() {
    val json = client.buildPatchJson("fcm-token", mapOf("tags" to mapOf("plan" to "vip")))

    // Encoded the way the AOSP JSONStringer does it (JSONObject/JSONArray/
    // primitives only, everything else stringified via toString) rather than
    // via the JVM org.json artifact on the test classpath, which has an extra
    // Map branch the device does not have. Structural comparison, since key
    // order is not guaranteed by either implementation.
    val encoded = JSONObject(aospEncode(json))
    assertEquals(setOf("tags", "token"), encoded.keys().asSequence().toSet())
    assertEquals("fcm-token", encoded.getString("token"))
    // Fails with `JSONException: Value {plan=vip} at tags of type
    // java.lang.String cannot be converted to JSONObject` if the map is put raw.
    assertEquals("vip", encoded.getJSONObject("tags").getString("plan"))
  }

  @Test
  fun `a list field survives Android's org json encoder as a nested array`() {
    val json = client.buildPatchJson("t", mapOf("topics" to listOf("a", "b")))

    val topics = JSONObject(aospEncode(json)).getJSONArray("topics")
    assertEquals(2, topics.length())
    assertEquals("a", topics.getString(0))
    assertEquals("b", topics.getString(1))
  }

  @Test
  fun `reportEvent sends POST to the events endpoint with bearer auth and snake_case body`() {
    server.enqueue(MockResponse().setResponseCode(200))

    val result = client.reportEvent(
      notificationId = "notif-1",
      deliveryId = "delivery-1",
      type = "clicked",
      token = "fcm-token"
    )

    val recorded = requireNotNull(server.takeRequest(5, TimeUnit.SECONDS))
    assertEquals("POST", recorded.method)
    assertEquals("/v1/apps/app-1/notifications/notif-1/events", recorded.path)
    assertEquals("Bearer secret-key", recorded.getHeader("Authorization"))

    val sentBody = JSONObject(recorded.body.readUtf8())
    assertEquals("delivery-1", sentBody.getString("delivery_id"))
    assertEquals("clicked", sentBody.getString("type"))
    assertEquals("fcm-token", sentBody.getString("token"))

    assertTrue("expected a Success, got $result", result is EventResult.Success)
  }

  @Test
  fun `reportEvent retries 5xx responses and exhausts the retry cap at 5 attempts`() {
    repeat(5) { server.enqueue(MockResponse().setResponseCode(503)) }

    val result = client.reportEvent(
      notificationId = "notif-1",
      deliveryId = "delivery-1",
      type = "clicked",
      token = "fcm-token"
    )

    assertEquals(5, server.requestCount)
    assertEquals(listOf(2000L, 4000L, 8000L, 16000L), sleeps)
    assertTrue("expected a Failure, got $result", result is EventResult.Failure)
  }

  @Test
  fun `reportEvent does not retry 4xx responses`() {
    // One request per code; requestCount grows by exactly one each time,
    // proving no retry after a terminal 4xx.
    for (code in listOf(403, 404, 422)) {
      val before = server.requestCount
      server.enqueue(MockResponse().setResponseCode(code))

      val result = client.reportEvent(
        notificationId = "notif-1",
        deliveryId = "delivery-1",
        type = "clicked",
        token = "fcm-token"
      )

      assertEquals("expected exactly 1 request for HTTP $code", before + 1, server.requestCount)
      assertTrue("expected a Failure for HTTP $code, got $result", result is EventResult.Failure)
      val failure = result as EventResult.Failure
      assertEquals("HTTP $code", failure.message)
      assertTrue("a 4xx must be a terminal failure (dropped from the queue), got $result", failure.terminal)
    }
  }

  @Test
  fun `reportEvent 5xx exhaustion is a non-terminal failure`() {
    repeat(5) { server.enqueue(MockResponse().setResponseCode(500)) }

    val result = client.reportEvent(
      notificationId = "notif-1",
      deliveryId = "delivery-1",
      type = "clicked",
      token = "fcm-token"
    )

    assertTrue("expected a Failure, got $result", result is EventResult.Failure)
    // Retry-cap exhaustion on transient errors is NOT terminal: the event
    // stays queued for the next flush (SDKCTR-11).
    assertFalse((result as EventResult.Failure).terminal)
  }

  @Test
  fun `reportEvent succeeds on any 2xx regardless of body`() {
    // 200 with an empty body: acknowledged, nothing to parse.
    server.enqueue(MockResponse().setResponseCode(200).setBody(""))
    // 201 with a non-JSON body: still a success - unlike device registration,
    // reportEvent never treats a 2xx body as malformed, so no retry here.
    server.enqueue(MockResponse().setResponseCode(201).setBody("<html>accepted</html>"))

    val emptyBodyResult = client.reportEvent(
      notificationId = "notif-1",
      deliveryId = "delivery-1",
      type = "clicked",
      token = "fcm-token"
    )
    assertTrue("expected Success for empty 200 body, got $emptyBodyResult", emptyBodyResult is EventResult.Success)

    val nonJsonResult = client.reportEvent(
      notificationId = "notif-1",
      deliveryId = "delivery-1",
      type = "clicked",
      token = "fcm-token"
    )
    assertTrue("expected Success for non-JSON 201 body, got $nonJsonResult", nonJsonResult is EventResult.Success)

    assertEquals(2, server.requestCount)
  }

  @Test
  fun `reportEvent treats 429 as transient - full retry schedule, then a non-terminal failure`() {
    repeat(5) { server.enqueue(MockResponse().setResponseCode(429)) }

    val result = client.reportEvent("notif-1", "delivery-1", "clicked", "fcm-token")

    assertEquals(5, server.requestCount)
    assertEquals(listOf(2000L, 4000L, 8000L, 16000L), sleeps)
    assertTrue("expected a Failure, got $result", result is EventResult.Failure)
    assertFalse("HTTP 429 is transient: the event must stay queued", (result as EventResult.Failure).terminal)
  }

  @Test
  fun `reportEvent treats 408 as transient - retried with backoff, then a non-terminal failure`() {
    // OkHttp itself silently re-sends a 408 once per call, so the raw request
    // count is not 5 - assert on the SDK's own backoff schedule instead.
    server.dispatcher = object : okhttp3.mockwebserver.Dispatcher() {
      override fun dispatch(request: okhttp3.mockwebserver.RecordedRequest) =
        MockResponse().setResponseCode(408)
    }

    val result = client.reportEvent("notif-1", "delivery-1", "clicked", "fcm-token")

    assertEquals(listOf(2000L, 4000L, 8000L, 16000L), sleeps)
    assertTrue("expected a Failure, got $result", result is EventResult.Failure)
    assertFalse("HTTP 408 is transient: the event must stay queued", (result as EventResult.Failure).terminal)
  }

  @Test
  fun `reportEvent retries a 429 and succeeds once the backend recovers`() {
    server.enqueue(MockResponse().setResponseCode(429))
    server.enqueue(MockResponse().setResponseCode(200))

    val result = client.reportEvent("notif-1", "delivery-1", "clicked", "fcm-token")

    assertEquals(2, server.requestCount)
    assertTrue("expected Success after a 429 retry, got $result", result is EventResult.Success)
  }

  @Test
  fun `reportEvent percent-encodes the notification id as a single path segment`() {
    server.enqueue(MockResponse().setResponseCode(200))

    val result = client.reportEvent("a/b?c d#e", "delivery-1", "clicked", "fcm-token")

    val recorded = requireNotNull(server.takeRequest(5, TimeUnit.SECONDS))
    assertEquals("/v1/apps/app-1/notifications/a%2Fb%3Fc%20d%23e/events", recorded.path)
    assertTrue(result is EventResult.Success)
  }

  @Test
  fun `reportEvent with an unbuildable URL is a terminal failure, never a throw`() {
    val broken = NottiApiClient(
      httpClient = OkHttpClient(),
      baseUrl = "not a url",
      appId = "app-1",
      clientKey = "secret-key",
      sleeper = { }
    )

    val result = broken.reportEvent("notif-1", "delivery-1", "clicked", "fcm-token")

    assertTrue("expected a Failure, got $result", result is EventResult.Failure)
    assertTrue(
      "an unbuildable URL can never succeed - must be terminal so the event is not a poison pill",
      (result as EventResult.Failure).terminal
    )
    assertEquals(0, server.requestCount)
  }

  /**
   * Minimal re-implementation of AOSP's `JSONStringer.value(Object)` dispatch:
   * only JSONObject/JSONArray/Boolean/Number/null are encoded structurally,
   * anything else is written as `String.valueOf(value)`. Used so these tests
   * assert against the encoder the SDK actually runs on in production instead
   * of the more forgiving JVM `org.json` artifact.
   */
  private fun aospEncode(value: Any?): String = when (value) {
    null, JSONObject.NULL -> "null"
    is JSONObject -> value.keys().asSequence().joinToString(
      prefix = "{", postfix = "}", separator = ","
    ) { key -> JSONObject.quote(key) + ":" + aospEncode(value.get(key)) }
    is JSONArray -> (0 until value.length()).joinToString(
      prefix = "[", postfix = "]", separator = ","
    ) { index -> aospEncode(value.get(index)) }
    is Boolean, is Number -> value.toString()
    else -> JSONObject.quote(value.toString())
  }

  // --- In-App endpoints (single attempt) ----------------------------------

  private val inAppDevice = "00000000-0000-0000-0000-0000000000d1"
  private val inAppMessageId = "00000000-0000-0000-0000-0000000000b1"

  private fun inAppEvent(
    type: String = InAppEventType.IMPRESSION,
    buttonId: String? = null,
    reason: String? = null
  ) = InAppPendingEvent(
    id = "local",
    eventId = "00000000-0000-4000-8000-0000000000e1",
    appId = "app-1",
    messageId = inAppMessageId,
    type = type,
    buttonId = buttonId,
    reason = reason,
    occurredAtMs = 1_792_247_405_000L
  )

  @Test
  fun `eligible sends the documented request and parses the messages`() {
    server.enqueue(
      MockResponse().setResponseCode(200).setBody(
        """{"messages":[{"id":"m1","title":"fixture","trigger":{"type":"session_start"}}]}"""
      )
    )

    val result = client.fetchEligibleInAppMessages(inAppDevice, "fcm-token")

    val recorded = requireNotNull(server.takeRequest(5, TimeUnit.SECONDS))
    assertEquals("POST", recorded.method)
    assertEquals("/v1/apps/app-1/in-app-messages/eligible", recorded.path)
    assertEquals("Bearer secret-key", recorded.getHeader("Authorization"))
    val sent = JSONObject(recorded.body.readUtf8())
    assertEquals(setOf("device_id", "token"), sent.keys().asSequence().toSet())
    assertEquals(inAppDevice, sent.getString("device_id"))
    assertEquals("fcm-token", sent.getString("token"))
    assertEquals(listOf("m1"), (result as InAppEligibleResult.Messages).messages.map { it.id })
    assertEquals(1, server.requestCount)
  }

  @Test
  fun `eligible with an empty messages array is a valid result`() {
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"messages":[]}"""))

    assertEquals(
      InAppEligibleResult.Messages(emptyList()),
      client.fetchEligibleInAppMessages(inAppDevice, "t")
    )
  }

  @Test
  fun `eligible classifies each status and never retries or sleeps`() {
    val expected = mapOf(
      401 to InAppEligibleResult.Unauthorized,
      403 to InAppEligibleResult.Forbidden,
      404 to InAppEligibleResult.Terminal(404),
      422 to InAppEligibleResult.Terminal(422),
      400 to InAppEligibleResult.Terminal(400),
      408 to InAppEligibleResult.Transient,
      500 to InAppEligibleResult.Transient,
      503 to InAppEligibleResult.Transient
    )
    expected.forEach { (status, outcome) ->
      server.enqueue(MockResponse().setResponseCode(status))
      assertEquals("status $status", outcome, client.fetchEligibleInAppMessages(inAppDevice, "t"))
    }
    // OkHttp itself replays a 408 once (RetryAndFollowUpInterceptor); the client adds no retry.
    assertEquals(expected.size + 1, server.requestCount)
    assertTrue(sleeps.isEmpty())
    assertTrue(InAppEligibleResult.Unauthorized != InAppEligibleResult.Forbidden)
  }

  @Test
  fun `eligible with an unparseable 2xx or a network error is transient`() {
    server.enqueue(MockResponse().setResponseCode(200).setBody("<html>portal</html>"))
    assertEquals(InAppEligibleResult.Transient, client.fetchEligibleInAppMessages(inAppDevice, "t"))
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"messages":"x"}"""))
    assertEquals(InAppEligibleResult.Transient, client.fetchEligibleInAppMessages(inAppDevice, "t"))
    server.enqueue(MockResponse().setSocketPolicy(SocketPolicy.DISCONNECT_AT_START))
    assertEquals(InAppEligibleResult.Transient, client.fetchEligibleInAppMessages(inAppDevice, "t"))
    assertTrue(sleeps.isEmpty())
  }

  /** A valid `eligible` body padded to exactly [size] bytes. */
  private fun eligibleBodyOfSize(size: Long): String {
    val prefix = """{"messages":[],"pad":""""
    val suffix = """"}"""
    return prefix + "x".repeat((size - prefix.length - suffix.length).toInt()) + suffix
  }

  @Test
  fun `eligible with a body exactly at the size limit is parsed`() {
    val body = eligibleBodyOfSize(NottiApiClient.MAX_IN_APP_BODY_BYTES)
    assertEquals(NottiApiClient.MAX_IN_APP_BODY_BYTES, body.length.toLong())
    server.enqueue(MockResponse().setResponseCode(200).setBody(body))

    assertEquals(
      InAppEligibleResult.Messages(emptyList()),
      client.fetchEligibleInAppMessages(inAppDevice, "t")
    )
  }

  @Test
  fun `eligible with a body past the size limit is transient, declared or chunked`() {
    val body = eligibleBodyOfSize(NottiApiClient.MAX_IN_APP_BODY_BYTES + 1)
    server.enqueue(MockResponse().setResponseCode(200).setBody(body))
    assertEquals(InAppEligibleResult.Transient, client.fetchEligibleInAppMessages(inAppDevice, "t"))
    server.enqueue(MockResponse().setResponseCode(200).setChunkedBody(body, 64 * 1024))
    assertEquals(InAppEligibleResult.Transient, client.fetchEligibleInAppMessages(inAppDevice, "t"))
    assertEquals(2, server.requestCount)
    assertTrue(sleeps.isEmpty())
  }

  @Test
  fun `an event answered 2xx with a body past the size limit is still recorded`() {
    server.enqueue(MockResponse().setResponseCode(201).setBody("x".repeat((NottiApiClient.MAX_IN_APP_BODY_BYTES + 1).toInt())))
    assertEquals(InAppEventResult.Recorded, client.reportInAppEvent(inAppEvent(), inAppDevice, "tok"))
  }

  @Test
  fun `429 carries Retry-After as integer seconds or null`() {
    fun eligibleRetryAfter(header: String?): Int? {
      val response = MockResponse().setResponseCode(429)
      if (header != null) response.setHeader("Retry-After", header)
      server.enqueue(response)
      return (client.fetchEligibleInAppMessages(inAppDevice, "t") as InAppEligibleResult.RateLimited)
        .retryAfterSeconds
    }
    assertEquals(2, eligibleRetryAfter("2"))
    assertNull(eligibleRetryAfter(null))
    assertEquals(0, eligibleRetryAfter("0"))
    assertEquals(9999, eligibleRetryAfter("9999"))
    assertNull(eligibleRetryAfter("Wed, 21 Oct 2026 07:28:00 GMT"))
    assertNull(eligibleRetryAfter("-5"))
    assertNull(eligibleRetryAfter("1.5"))
    assertEquals(Int.MAX_VALUE, eligibleRetryAfter("99999999999999999999"))
  }

  @Test
  fun `events sends the documented request for each type`() {
    server.enqueue(MockResponse().setResponseCode(201).setBody("""{"duplicate":false}"""))
    server.enqueue(MockResponse().setResponseCode(201).setBody("""{"duplicate":false}"""))
    server.enqueue(MockResponse().setResponseCode(201).setBody("""{"duplicate":false}"""))

    client.reportInAppEvent(inAppEvent(), inAppDevice, "tok")
    client.reportInAppEvent(inAppEvent(InAppEventType.CLICK, buttonId = "btn"), inAppDevice, "tok")
    client.reportInAppEvent(inAppEvent(InAppEventType.DISMISS, reason = "auto"), inAppDevice, "tok")

    val impression = requireNotNull(server.takeRequest(5, TimeUnit.SECONDS))
    assertEquals("POST", impression.method)
    assertEquals("/v1/apps/app-1/in-app-messages/$inAppMessageId/events", impression.path)
    assertEquals("Bearer secret-key", impression.getHeader("Authorization"))
    val sent = JSONObject(impression.body.readUtf8())
    assertEquals(
      setOf("device_id", "token", "event_id", "type", "occurred_at"),
      sent.keys().asSequence().toSet()
    )
    assertEquals("00000000-0000-4000-8000-0000000000e1", sent.getString("event_id"))
    assertEquals("impression", sent.getString("type"))

    val click = JSONObject(requireNotNull(server.takeRequest(5, TimeUnit.SECONDS)).body.readUtf8())
    assertEquals("btn", click.getString("button_id"))
    assertFalse(click.has("reason"))

    val dismiss = JSONObject(requireNotNull(server.takeRequest(5, TimeUnit.SECONDS)).body.readUtf8())
    assertEquals("auto", dismiss.getString("reason"))
    assertFalse(dismiss.has("button_id"))
  }

  @Test
  fun `occurred_at is RFC3339 UTC`() {
    server.enqueue(MockResponse().setResponseCode(201))

    client.reportInAppEvent(inAppEvent(), inAppDevice, "t")

    val sent = JSONObject(requireNotNull(server.takeRequest(5, TimeUnit.SECONDS)).body.readUtf8())
    assertEquals("2026-10-17T14:30:05.000Z", sent.getString("occurred_at"))
  }

  @Test
  fun `events classify each status`() {
    server.enqueue(MockResponse().setResponseCode(201))
    assertEquals(InAppEventResult.Recorded, client.reportInAppEvent(inAppEvent(), inAppDevice, "t"))
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"duplicate":true}"""))
    assertEquals(InAppEventResult.Recorded, client.reportInAppEvent(inAppEvent(), inAppDevice, "t"))
    server.enqueue(MockResponse().setResponseCode(201).setBody(""))
    assertEquals(InAppEventResult.Recorded, client.reportInAppEvent(inAppEvent(), inAppDevice, "t"))

    val expected = mapOf(
      404 to InAppEventResult.Drop,
      422 to InAppEventResult.Drop,
      400 to InAppEventResult.Drop,
      401 to InAppEventResult.Unauthorized,
      403 to InAppEventResult.Forbidden,
      408 to InAppEventResult.Transient,
      500 to InAppEventResult.Transient,
      502 to InAppEventResult.Transient
    )
    expected.forEach { (status, outcome) ->
      server.enqueue(MockResponse().setResponseCode(status))
      assertEquals("status $status", outcome, client.reportInAppEvent(inAppEvent(), inAppDevice, "t"))
    }
    server.enqueue(MockResponse().setSocketPolicy(SocketPolicy.DISCONNECT_AT_START))
    assertEquals(InAppEventResult.Transient, client.reportInAppEvent(inAppEvent(), inAppDevice, "t"))
    // +1: OkHttp itself replays a 408 once; the client adds no retry.
    assertEquals(3 + expected.size + 1 + 1, server.requestCount)
    assertTrue(sleeps.isEmpty())
  }

  @Test
  fun `events 429 carries Retry-After`() {
    server.enqueue(MockResponse().setResponseCode(429).setHeader("Retry-After", "2"))
    assertEquals(
      InAppEventResult.RateLimited(2),
      client.reportInAppEvent(inAppEvent(), inAppDevice, "t")
    )
    server.enqueue(MockResponse().setResponseCode(429))
    assertEquals(
      InAppEventResult.RateLimited(null),
      client.reportInAppEvent(inAppEvent(), inAppDevice, "t")
    )
  }

  @Test
  fun `an app id with path or query characters cannot rewrite the in-app path`() {
    val hostile = NottiApiClient(
      httpClient = OkHttpClient(),
      baseUrl = server.url("/").toString().trimEnd('/'),
      appId = "a/../b?x=1#f",
      clientKey = "secret-key",
      sleeper = { }
    )
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"messages":[]}"""))
    server.enqueue(MockResponse().setResponseCode(201))

    hostile.fetchEligibleInAppMessages(inAppDevice, "t")
    hostile.reportInAppEvent(inAppEvent().copy(messageId = "m/../x"), inAppDevice, "t")

    val eligible = requireNotNull(server.takeRequest(5, TimeUnit.SECONDS))
    assertEquals("/v1/apps/a%2F..%2Fb%3Fx=1%23f/in-app-messages/eligible", eligible.path)
    val events = requireNotNull(server.takeRequest(5, TimeUnit.SECONDS))
    assertEquals("/v1/apps/a%2F..%2Fb%3Fx=1%23f/in-app-messages/m%2F..%2Fx/events", events.path)
  }
}
