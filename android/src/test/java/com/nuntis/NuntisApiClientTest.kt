package com.nuntis

import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.SocketPolicy
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.TimeUnit

class NuntisApiClientTest {

  private lateinit var server: MockWebServer
  private lateinit var client: NuntisApiClient
  private val sleeps = mutableListOf<Long>()

  @Before
  fun setUp() {
    server = MockWebServer()
    server.start()
    client = NuntisApiClient(
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
  fun `a 2xx whose body is not JSON is a terminal failure, not a thrown exception`() {
    // Captive portal / proxy shape: HTTP 200, HTML body.
    server.enqueue(
      MockResponse().setResponseCode(200).setBody("<html><body>Sign in to the network</body></html>")
    )
    // Only consumed if the client wrongly retried a non-retryable body.
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))

    val result = client.createOrUpdateDevice(token = "t", platform = "android")

    assertTrue("expected a Failure, got $result", result is ApiResult.Failure)
    assertEquals(1, server.requestCount)
  }

  @Test
  fun `a 2xx JSON body missing the id field is a terminal failure`() {
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"device_id":"device-1"}"""))

    val result = client.createOrUpdateDevice(token = "t", platform = "android")

    assertTrue("expected a Failure, got $result", result is ApiResult.Failure)
  }

  @Test
  fun `a 2xx JSON body with an empty id is a terminal failure`() {
    // AOSP's JSONObject.getString coerces rather than validates, so this used
    // to be reported as a successful registration carrying id "". The caller
    // then persisted "" (non-null, so nothing retried it) and PATCHed
    // `/v1/apps/app-1/devices/` - the collection, not a device - forever.
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"","tags":{"plan":"vip"}}"""))

    val result = client.createOrUpdateDevice(token = "t", platform = "android")

    assertTrue("expected a Failure, got $result", result is ApiResult.Failure)
  }

  @Test
  fun `a 2xx JSON body whose id is not a string is a terminal failure`() {
    // Same coercion trap from the other side: getString(123) returns "123",
    // fabricating a device id the backend never issued.
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":123,"tags":{}}"""))

    val result = client.createOrUpdateDevice(token = "t", platform = "android")

    assertTrue("expected a Failure, got $result", result is ApiResult.Failure)
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
}
