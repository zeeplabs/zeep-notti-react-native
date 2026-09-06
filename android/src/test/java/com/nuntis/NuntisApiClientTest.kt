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
}
