package com.notti

import okhttp3.Interceptor
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Protocol
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.Buffer
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executor
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class NottiCoreTest {

  private lateinit var server: MockWebServer
  private lateinit var store: NottiDeviceStore
  private lateinit var prefs: FakePrefsForCore
  private lateinit var executor: ExecutorService

  @Before
  fun setUp() {
    server = MockWebServer()
    server.start()
    prefs = FakePrefsForCore()
    store = NottiDeviceStore(prefs)
    executor = Executors.newSingleThreadExecutor()
  }

  /**
   * Blocks until every task already submitted to the (single-threaded) core
   * executor has run. Needed because NottiCore's public methods return
   * immediately after handing the work off - the whole point of the
   * "no blocking I/O on the caller's thread" contract exercised below.
   */
  private fun awaitIdle() {
    executor.submit { }.get(10, TimeUnit.SECONDS)
  }

  /** The mock server's own URL - the only `baseUrl` that actually reaches it in these tests. */
  private val validBaseUrl: String
    get() = server.url("/").toString().trimEnd('/')

  @After
  fun tearDown() {
    executor.shutdownNow()
    server.shutdown()
  }

  private fun newCore(
    tokenProvider: (callback: (String?) -> Unit) -> Unit = { cb -> cb("fcm-token") },
    permissionRequester: (callback: (Boolean) -> Unit) -> Unit = { it(true) },
    logs: MutableList<String>? = null,
    interceptor: Interceptor? = null,
    coreExecutor: Executor = executor
  ) = NottiCore(
    deviceStore = store,
    apiClientFactory = { appId, clientKey, baseUrl ->
      NottiApiClient(
        httpClient = OkHttpClient.Builder()
          .apply { interceptor?.let { addInterceptor(it) } }
          .build(),
        baseUrl = baseUrl,
        appId = appId,
        clientKey = clientKey,
        sleeper = { }
      )
    },
    tokenProvider = tokenProvider,
    permissionRequester = permissionRequester,
    logger = { logs?.add(it) },
    executor = coreExecutor
  )

  @Test
  fun `initialize with blank appId logs and does not call the API client`() {
    val logs = mutableListOf<String>()
    val core = newCore(logs = logs)

    core.initialize("", "key", validBaseUrl)

    assertEquals(0, server.requestCount)
    assertTrue(logs.any { it.contains("appId, clientKey, or baseUrl") })
  }

  @Test
  fun `initialize with blank clientKey logs and does not call the API client`() {
    val logs = mutableListOf<String>()
    val core = newCore(logs = logs)

    core.initialize("app-1", "", validBaseUrl)

    assertEquals(0, server.requestCount)
    assertTrue(logs.any { it.contains("appId, clientKey, or baseUrl") })
  }

  @Test
  fun `initialize with blank baseUrl logs and does not call the API client`() {
    val logs = mutableListOf<String>()
    val core = newCore(logs = logs)

    core.initialize("app-1", "key", "")

    assertEquals(0, server.requestCount)
    assertTrue(logs.any { it.contains("appId, clientKey, or baseUrl") })
  }

  @Test
  fun `initialize with a malformed baseUrl logs, registers nothing, and leaves the SDK non-crashing`() {
    val logs = mutableListOf<String>()
    val core = newCore(logs = logs)

    // Scheme-less host: accepted by the old validation-free path, then thrown
    // as an IllegalArgumentException out of Request.Builder().url(...) - a
    // config mistake must never be able to reach a throw (spec SDK-03).
    core.initialize("app-1", "key", "push.example.com")
    awaitIdle()

    assertEquals(0, server.requestCount)
    assertTrue(logs.any { it.contains("not a valid http(s) URL") })

    // Disabled-but-alive: every other public entry point stays a safe no-op.
    core.login("user-42")
    core.setSubscription(true)
    core.mutateTags(add = mapOf("plan" to "vip"), remove = null)
    core.onTokenRefreshed("new-token")
    awaitIdle()

    assertEquals(0, server.requestCount)
    assertEquals(null, store.getDeviceId())
  }

  @Test
  fun `initialize normalizes a trailing-slash baseUrl instead of building a double-slash path`() {
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    val core = newCore()

    // server.url("/") keeps its trailing slash - the shape an integrator gets
    // from copy-pasting their Notti host out of a browser address bar.
    core.initialize("app-1", "key", server.url("/").toString())
    awaitIdle()

    val recorded = requireNotNull(server.takeRequest(5, TimeUnit.SECONDS))
    assertEquals("/v1/apps/app-1/devices", recorded.path)
  }

  @Test
  fun `initialize with no available push token logs and does not register`() {
    val logs = mutableListOf<String>()
    val core = newCore(tokenProvider = { cb -> cb(null) }, logs = logs)

    core.initialize("app-1", "key", validBaseUrl)

    assertEquals(0, server.requestCount)
    assertTrue(logs.any { it.contains("no push token") })
  }

  @Test
  fun `initialize with an async token fetch that resolves later still registers once the token arrives`() {
    server.enqueue(
      MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}""")
    )
    var deferredCallback: ((String?) -> Unit)? = null
    val core = newCore(tokenProvider = { cb -> deferredCallback = cb })

    core.initialize("app-1", "key", validBaseUrl)
    assertEquals(0, server.requestCount)

    deferredCallback?.invoke("fcm-token")
    awaitIdle()

    assertEquals(1, server.requestCount)
    assertEquals("device-1", store.getDeviceId())
    assertEquals("fcm-token", store.getLastToken())
  }

  @Test
  fun `initialize with an async token fetch that fails does not crash and does not attempt registration`() {
    val logs = mutableListOf<String>()
    var deferredCallback: ((String?) -> Unit)? = null
    val core = newCore(tokenProvider = { cb -> deferredCallback = cb }, logs = logs)

    core.initialize("app-1", "key", validBaseUrl)
    deferredCallback?.invoke(null)
    awaitIdle()

    assertEquals(0, server.requestCount)
    assertTrue(logs.any { it.contains("no push token") })
  }

  @Test
  fun `initialize happy path registers the device and persists id and tags`() {
    server.enqueue(
      MockResponse().setResponseCode(200)
        .setBody("""{"id":"device-1","tags":{"plan":"vip"}}""")
    )
    val core = newCore()

    core.initialize("app-1", "key", validBaseUrl)
    awaitIdle()

    assertEquals(1, server.requestCount)
    assertEquals("device-1", store.getDeviceId())
    assertEquals("fcm-token", store.getLastToken())
    assertEquals(mapOf("plan" to "vip"), store.getTags())
  }

  @Test
  fun `repeat initialize with identical args is a no-op`() {
    server.enqueue(
      MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}""")
    )
    val core = newCore()

    core.initialize("app-1", "key", validBaseUrl)
    core.initialize("app-1", "key", validBaseUrl)
    awaitIdle()

    assertEquals(1, server.requestCount)
  }

  @Test
  fun `onTokenRefreshed re-registers with the new token`() {
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    val core = newCore()
    core.initialize("app-1", "key", validBaseUrl)
    awaitIdle()

    core.onTokenRefreshed("new-fcm-token")
    awaitIdle()

    assertEquals(2, server.requestCount)
    server.takeRequest(5, TimeUnit.SECONDS) // the initial register
    val refreshRequest = requireNotNull(server.takeRequest(5, TimeUnit.SECONDS))
    val body = JSONObject(refreshRequest.body.readUtf8())
    assertEquals("new-fcm-token", body.getString("token"))
    assertEquals("new-fcm-token", store.getLastToken())
  }

  @Test
  fun `requestPermission grant path invokes the native prompt and PATCHes subscribed true`() {
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    var promptInvoked = false
    val core = newCore(permissionRequester = { cb -> promptInvoked = true; cb(true) })
    core.initialize("app-1", "key", validBaseUrl)
    awaitIdle()

    var callbackResult: Boolean? = null
    core.requestPermission { granted -> callbackResult = granted }
    awaitIdle()

    assertTrue(promptInvoked)
    assertEquals(true, callbackResult)
    server.takeRequest(5, TimeUnit.SECONDS) // initial register
    val patchRequest = requireNotNull(server.takeRequest(5, TimeUnit.SECONDS))
    assertEquals("PATCH", patchRequest.method)
    assertEquals(true, JSONObject(patchRequest.body.readUtf8()).getBoolean("subscribed"))
    assertTrue(store.getSubscribed())
  }

  @Test
  fun `requestPermission deny path PATCHes subscribed false`() {
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    val core = newCore(permissionRequester = { cb -> cb(false) })
    core.initialize("app-1", "key", validBaseUrl)
    awaitIdle()

    core.requestPermission { }
    awaitIdle()

    server.takeRequest(5, TimeUnit.SECONDS)
    val patchRequest = requireNotNull(server.takeRequest(5, TimeUnit.SECONDS))
    assertEquals(false, JSONObject(patchRequest.body.readUtf8()).getBoolean("subscribed"))
    assertFalse(store.getSubscribed())
  }

  @Test
  fun `requestPermission called before initialize logs and does not prompt`() {
    val logs = mutableListOf<String>()
    var promptInvoked = false
    val core = newCore(permissionRequester = { promptInvoked = true; it(true) }, logs = logs)

    var callbackResult: Boolean? = null
    core.requestPermission { granted -> callbackResult = granted }

    assertFalse(promptInvoked)
    assertEquals(false, callbackResult)
    assertTrue(logs.any { it.contains("before initialize") })
  }

  @Test
  fun `login PATCHes external_user_id and the cached token, and persists it locally on success`() {
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    val core = newCore()
    core.initialize("app-1", "key", validBaseUrl)
    awaitIdle()

    core.login("user-42")
    awaitIdle()

    assertEquals(2, server.requestCount)
    server.takeRequest(5, TimeUnit.SECONDS) // initial register
    val patchRequest = requireNotNull(server.takeRequest(5, TimeUnit.SECONDS))
    assertEquals("PATCH", patchRequest.method)
    val body = JSONObject(patchRequest.body.readUtf8())
    assertEquals("user-42", body.getString("external_user_id"))
    assertEquals("fcm-token", body.getString("token"))
    assertEquals("user-42", store.getExternalUserId())
  }

  @Test
  fun `logout clears the locally held external user id without sending any PATCH`() {
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    val core = newCore()
    core.initialize("app-1", "key", validBaseUrl)
    core.login("user-42")
    awaitIdle()
    assertEquals("user-42", store.getExternalUserId())

    core.logout()
    awaitIdle()

    // Only the initial register + login PATCH from setup above - logout()
    // itself must not issue any network call (spec SDK-15: local-only clear,
    // the backend has no support for clearing external_user_id server-side).
    assertEquals(2, server.requestCount)
    assertEquals(null, store.getExternalUserId())
  }

  @Test
  fun `logout called right after login leaves the device logged out`() {
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    // The login PATCH is slow, so its store write lands well after the
    // logout() call - the exact window in which a synchronous, off-executor
    // logout gets silently undone by the login it was meant to supersede.
    server.enqueue(
      MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}""")
        .setBodyDelay(300, TimeUnit.MILLISECONDS)
    )
    val core = newCore()
    core.initialize("app-1", "key", validBaseUrl)
    awaitIdle()

    // Both from the same (JS) thread, back to back, as an app signing a user
    // out immediately after a failed/aborted sign-in does.
    core.login("user-42")
    core.logout()
    awaitIdle()

    assertEquals(2, server.requestCount)
    assertEquals(null, store.getExternalUserId())
  }

  @Test
  fun `setSubscription PATCHes the given subscribed value and the cached token, and persists it locally on success`() {
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    val core = newCore()
    core.initialize("app-1", "key", validBaseUrl)
    awaitIdle()

    core.setSubscription(true)
    awaitIdle()

    assertEquals(2, server.requestCount)
    server.takeRequest(5, TimeUnit.SECONDS) // initial register
    val patchRequest = requireNotNull(server.takeRequest(5, TimeUnit.SECONDS))
    assertEquals("PATCH", patchRequest.method)
    val body = JSONObject(patchRequest.body.readUtf8())
    assertEquals(true, body.getBoolean("subscribed"))
    assertEquals("fcm-token", body.getString("token"))
    assertTrue(store.getSubscribed())
  }

  @Test
  fun `initialize never performs the registration HTTP call on the calling thread`() {
    val callerThread = Thread.currentThread().name
    val requestThreads = mutableListOf<String>()
    // A deliberately slow round trip: if the call ran inline on the caller's
    // thread, initialize() would not return until it finished (on a real
    // device this is exactly the ANR / NetworkOnMainThreadException path).
    val slowInterceptor = Interceptor { chain ->
      requestThreads.add(Thread.currentThread().name)
      Thread.sleep(700)
      chain.proceed(chain.request())
    }
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    val core = newCore(interceptor = slowInterceptor)

    val startedAt = System.nanoTime()
    core.initialize("app-1", "key", validBaseUrl)
    val elapsedMs = (System.nanoTime() - startedAt) / 1_000_000

    assertTrue(
      "initialize() blocked the calling thread for ${elapsedMs}ms",
      elapsedMs < 300
    )

    awaitIdle()
    assertEquals("device-1", store.getDeviceId())
    assertEquals(1, requestThreads.size)
    assertNotEquals(callerThread, requestThreads.single())
  }

  @Test
  fun `mutation calls never perform their PATCH on the calling thread`() {
    val callerThread = Thread.currentThread().name
    val patchThreads = mutableListOf<String>()
    val slowInterceptor = Interceptor { chain ->
      if (chain.request().method == "PATCH") {
        patchThreads.add(Thread.currentThread().name)
        Thread.sleep(700)
      }
      chain.proceed(chain.request())
    }
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{"plan":"vip"}}"""))
    val core = newCore(interceptor = slowInterceptor)
    core.initialize("app-1", "key", validBaseUrl)
    awaitIdle()

    val startedAt = System.nanoTime()
    core.mutateTags(add = mapOf("plan" to "vip"), remove = null)
    val elapsedMs = (System.nanoTime() - startedAt) / 1_000_000

    assertTrue("addTags() blocked the calling thread for ${elapsedMs}ms", elapsedMs < 300)

    awaitIdle()
    assertEquals(mapOf("plan" to "vip"), store.getTags())
    assertEquals(1, patchThreads.size)
    assertNotEquals(callerThread, patchThreads.single())
  }

  /**
   * In-memory stand-in for the Notti devices endpoint, as an OkHttp
   * interceptor (no socket at all), so a POST and a PATCH can be interleaved
   * deterministically with latches instead of timing: it keeps real
   * server-side tag state, a PATCH replaces it wholesale (the backend's
   * documented replace-only contract), and a POST answers with whatever the
   * server holds at the moment it is served - which is exactly how a
   * concurrent registration can hand the SDK a stale tag map.
   */
  private class FakeDeviceApi(
    private val gatePostNumber: Int,
    private val postGateReached: CountDownLatch,
    private val releasePost: CountDownLatch
  ) : Interceptor {
    private val lock = Any()
    private var serverTags: Map<String, String> = emptyMap()
    private var postCount = 0

    override fun intercept(chain: Interceptor.Chain): Response {
      val request = chain.request()
      val bodyText = request.body?.let { body ->
        Buffer().also { body.writeTo(it) }.readUtf8()
      }.orEmpty()

      val responseTags: Map<String, String> = when (request.method) {
        "PATCH" -> {
          val sent = JSONObject(bodyText).optJSONObject("tags")
          val parsed = mutableMapOf<String, String>()
          sent?.keys()?.forEach { key -> parsed[key] = sent.getString(key) }
          synchronized(lock) {
            serverTags = parsed
            serverTags
          }
        }
        else -> {
          val gated = synchronized(lock) { ++postCount == gatePostNumber }
          val snapshot = synchronized(lock) { serverTags }
          if (gated) {
            // Registration has read the server's tag map; hold the response
            // open so the tag PATCH below happens strictly in between.
            postGateReached.countDown()
            releasePost.await()
          }
          snapshot
        }
      }

      val tagsJson = JSONObject()
      responseTags.forEach { (key, value) -> tagsJson.put(key, value) }
      val json = JSONObject().put("id", "device-1").put("tags", tagsJson).toString()

      return Response.Builder()
        .request(request)
        .protocol(Protocol.HTTP_1_1)
        .code(200)
        .message("OK")
        .body(json.toResponseBody("application/json".toMediaType()))
        .build()
    }
  }

  @Test
  fun `a concurrent registration cannot clobber the tag map an in-flight addTags just merged`() {
    val postGateReached = CountDownLatch(1)
    val releasePost = CountDownLatch(1)
    // Direct executor: NottiCore runs each call inline on the thread that
    // made it, so the two threads below - a JS-thread tag mutation and an FCM
    // onNewToken re-registration - contend exactly as they do in production,
    // with the interleaving pinned by latches rather than by sleeps.
    val core = newCore(
      interceptor = FakeDeviceApi(gatePostNumber = 2, postGateReached, releasePost),
      coreExecutor = Executor { it.run() }
    )
    core.initialize("app-1", "key", "https://notti.test")
    assertEquals("device-1", store.getDeviceId())

    val registerThread = Thread { core.onTokenRefreshed("refreshed-token") }
    registerThread.start()
    assertTrue(postGateReached.await(5, TimeUnit.SECONDS))

    val tagThread = Thread { core.mutateTags(add = mapOf("plan" to "vip"), remove = null) }
    tagThread.start()
    // Long enough for the tag mutation to complete on its own if nothing
    // serializes it against the registration currently holding the gate.
    Thread.sleep(200)
    releasePost.countDown()

    tagThread.join(5000)
    registerThread.join(5000)

    // The registration response was computed from the server's pre-PATCH tag
    // state; writing it must not be able to erase the tag that was just
    // merged and persisted server-side (spec P3-AC1).
    assertEquals(mapOf("plan" to "vip"), store.getTags())
  }

  @Test
  fun `a permission grant that lands before registration is queued and sent once the token arrives`() {
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    var deferredToken: ((String?) -> Unit)? = null
    val core = newCore(
      tokenProvider = { cb -> deferredToken = cb },
      permissionRequester = { cb -> cb(true) }
    )

    // Realistic sequence: initialize() then an immediate requestPermission()
    // while the FCM token fetch is still in flight, so there is no device id
    // to PATCH yet.
    core.initialize("app-1", "key", validBaseUrl)
    var granted: Boolean? = null
    core.requestPermission { granted = it }
    awaitIdle()

    assertEquals(true, granted)
    assertEquals(0, server.requestCount)

    requireNotNull(deferredToken).invoke("fcm-token")
    awaitIdle()

    // The grant must still reach the backend - dropping it leaves the device
    // permanently ineligible for delivery with nothing to retry it (P2-AC2).
    assertEquals(2, server.requestCount)
    assertEquals("POST", requireNotNull(server.takeRequest(5, TimeUnit.SECONDS)).method)
    val patch = requireNotNull(server.takeRequest(5, TimeUnit.SECONDS))
    assertEquals("PATCH", patch.method)
    assertEquals(true, JSONObject(patch.body.readUtf8()).getBoolean("subscribed"))
    assertTrue(store.getSubscribed())
  }

  @Test
  fun `mutations queued before registration are flushed in call order and merged against the registered tags`() {
    server.enqueue(
      MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{"seeded":"yes"}}""")
    )
    server.enqueue(
      MockResponse().setResponseCode(200)
        .setBody("""{"id":"device-1","tags":{"seeded":"yes","plan":"vip"}}""")
    )
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    var deferredToken: ((String?) -> Unit)? = null
    val core = newCore(tokenProvider = { cb -> deferredToken = cb })

    core.initialize("app-1", "key", validBaseUrl)
    core.mutateTags(add = mapOf("plan" to "vip"), remove = null)
    core.login("user-42")
    awaitIdle()
    assertEquals(0, server.requestCount)

    requireNotNull(deferredToken).invoke("fcm-token")
    awaitIdle()

    assertEquals(3, server.requestCount)
    assertEquals("POST", requireNotNull(server.takeRequest(5, TimeUnit.SECONDS)).method)

    val tagPatch = requireNotNull(server.takeRequest(5, TimeUnit.SECONDS))
    val sentTags = JSONObject(tagPatch.body.readUtf8()).getJSONObject("tags")
    // Merged against the tag map registration seeded, not against an empty
    // one - the merge has to happen at flush time, not at enqueue time.
    assertEquals("vip", sentTags.getString("plan"))
    assertEquals("yes", sentTags.getString("seeded"))

    val loginPatch = requireNotNull(server.takeRequest(5, TimeUnit.SECONDS))
    assertEquals("user-42", JSONObject(loginPatch.body.readUtf8()).getString("external_user_id"))
    assertEquals("user-42", store.getExternalUserId())
  }

  @Test
  fun `registration that exhausted its retry cap is resumed on the next app foreground`() {
    // Five 5xx responses burn the whole backoff cap (NottiApiClient), leaving
    // the device unregistered with nothing left to retry it (spec SDK-05:
    // "then stop until the next app foreground or the next token-refresh").
    repeat(5) { server.enqueue(MockResponse().setResponseCode(500)) }
    val core = newCore()
    core.initialize("app-1", "key", validBaseUrl)
    awaitIdle()
    assertEquals(5, server.requestCount)
    assertEquals(null, store.getDeviceId())

    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    core.onAppForegrounded()
    awaitIdle()

    assertEquals(6, server.requestCount)
    assertEquals("device-1", store.getDeviceId())
    assertEquals("fcm-token", store.getLastToken())
  }

  @Test
  fun `app foreground does not re-register a device that is already registered`() {
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    val core = newCore()
    core.initialize("app-1", "key", validBaseUrl)
    awaitIdle()

    repeat(3) { core.onAppForegrounded() }
    awaitIdle()

    assertEquals(1, server.requestCount)
  }

  @Test
  fun `repeated foregrounds while an attempt is in flight do not stack registration attempts`() {
    val retryInFlight = CountDownLatch(1)
    val releaseRetry = CountDownLatch(1)
    var requestNumber = 0
    // Holds the foreground retry (request #2) open, so the extra foregrounds
    // below happen while it is genuinely still in flight.
    val gateSecondRequest = Interceptor { chain ->
      val current = synchronized(this) { ++requestNumber }
      if (current == 2) {
        retryInFlight.countDown()
        releaseRetry.await()
      }
      chain.proceed(chain.request())
    }
    server.enqueue(MockResponse().setResponseCode(400)) // terminal failure, no retry cap burn
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    val core = newCore(interceptor = gateSecondRequest)
    core.initialize("app-1", "key", validBaseUrl)
    awaitIdle()
    assertEquals(1, server.requestCount)

    core.onAppForegrounded()
    assertTrue(retryInFlight.await(5, TimeUnit.SECONDS))

    // Several more foregrounds (tab switching, lock/unlock) while that retry
    // is still in flight must produce no further attempts - otherwise every
    // foreground stacks another registration call.
    repeat(4) { core.onAppForegrounded() }
    releaseRetry.countDown()
    awaitIdle()

    assertEquals(2, server.requestCount)
    assertEquals("device-1", store.getDeviceId())
  }

  @Test
  fun `two rapid tag mutations serialize and converge to the correct net merged result`() {
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    val core = newCore()
    core.initialize("app-1", "key", validBaseUrl)
    awaitIdle()

    // First mutation's PATCH response is artificially slow; if mutateTags did
    // not serialize, the second (fast) mutation on another thread would race
    // ahead and read the store's tags before the first call's write landed,
    // producing a stale/incorrect merge instead of the correct net result.
    server.enqueue(
      MockResponse().setResponseCode(200)
        .setBody("""{"id":"device-1","tags":{"plan":"vip"}}""")
        .setBodyDelay(300, TimeUnit.MILLISECONDS)
    )
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{"cohort":"beta"}}"""))

    val thread1 = Thread { core.mutateTags(add = mapOf("plan" to "vip"), remove = null) }
    val thread2 = Thread { core.mutateTags(add = mapOf("cohort" to "beta"), remove = listOf("plan")) }

    thread1.start()
    Thread.sleep(50) // ensure thread1 has entered the critical section first
    thread2.start()
    thread1.join(2000)
    thread2.join(2000)
    awaitIdle()

    assertEquals(3, server.requestCount)
    assertEquals(mapOf("cohort" to "beta"), store.getTags())
  }

  @Test
  fun `a token fetch that never completes does not disable the next foreground retry`() {
    // Play Services unavailable or wedged: the Task listener behind
    // tokenProvider simply never fires. Marking the registration IN_FLIGHT
    // before the token is in hand parks the state machine there forever, and
    // the IN_FLIGHT guard then swallows every later foreground.
    var tokenRequests = 0
    val core = newCore(
      tokenProvider = { callback ->
        tokenRequests++
        // Only the third request (initialize, first foreground, second
        // foreground) ever answers.
        if (tokenRequests >= 3) callback("fcm-token")
      }
    )

    core.initialize("app-1", "key", validBaseUrl)
    awaitIdle()
    assertEquals(1, tokenRequests)
    assertEquals(0, server.requestCount)

    core.onAppForegrounded()
    awaitIdle()
    assertEquals(2, tokenRequests)
    assertEquals(0, server.requestCount)

    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    core.onAppForegrounded()
    awaitIdle()

    assertEquals(3, tokenRequests)
    assertEquals(1, server.requestCount)
    assertEquals("device-1", store.getDeviceId())
  }

  @Test
  fun `a call that lands after the executor is shut down is dropped, not thrown at the caller`() {
    // NottiModule.invalidate() shuts the executor down, but callers outside
    // the module - NottiFirebaseMessagingService.onNewToken and the
    // process-lifecycle foreground observer - read `activeCore` before it is
    // cleared and can still dispatch afterwards. `Executor.execute` throws
    // RejectedExecutionException at *that* caller (the FCM service thread or
    // the main thread), which is outside the task body's catch.
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    val ownExecutor = Executors.newSingleThreadExecutor()
    val logs = mutableListOf<String>()
    val core = newCore(logs = logs, coreExecutor = ownExecutor)
    core.initialize("app-1", "key", validBaseUrl)
    ownExecutor.submit { }.get(10, TimeUnit.SECONDS)

    ownExecutor.shutdown()
    assertTrue(ownExecutor.awaitTermination(10, TimeUnit.SECONDS))

    // Every entry point an external caller can still reach post-shutdown.
    core.onTokenRefreshed("refreshed-token")
    core.mutateTags(add = mapOf("plan" to "vip"), remove = null)
    core.login("user-42")
    core.setSubscription(true)
    var granted: Boolean? = null
    core.requestPermission { granted = it }

    // Reaching here at all is the assertion: any of the above escaping with a
    // RejectedExecutionException would crash the host app's FCM callback.
    assertEquals(true, granted)
    assertEquals(1, server.requestCount)
    assertTrue(logs.any { it.contains("SDK is shut down") })
  }

  @Test
  fun `a 2xx registration response that cannot be parsed still leaves the foreground retry armed`() {
    // A captive portal / proxy answering the registration POST with HTTP 200
    // and an HTML body. The parse failure is not an IOException, so before the
    // fix it unwound past every branch that assigns registrationState, parking
    // it at IN_FLIGHT - which onAppForegrounded early-returns on, permanently
    // disabling the only retry path and stranding queued mutations.
    // A malformed 2xx is retriable (matches iOS), so the client exhausts all
    // 5 attempts on this response before reporting the registration FAILED.
    repeat(5) {
      server.enqueue(
        MockResponse().setResponseCode(200).setBody("<html><body>Sign in to the network</body></html>")
      )
    }
    val core = newCore()

    core.initialize("app-1", "key", validBaseUrl)
    core.login("user-42")
    awaitIdle()

    assertEquals(5, server.requestCount)
    assertEquals(null, store.getDeviceId())
    assertEquals(null, store.getExternalUserId())

    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    core.onAppForegrounded()
    awaitIdle()

    // Registration recovered on the next foreground, and the mutation that was
    // queued behind it finally flushed.
    assertEquals(7, server.requestCount)
    assertEquals("device-1", store.getDeviceId())
    assertEquals("user-42", store.getExternalUserId())
  }

  @Test
  fun `a 2xx registration response with an empty id persists nothing and keeps the local tags`() {
    // Tags this install already carries from an earlier session.
    store.setTags(mapOf("plan" to "vip"))
    // A 200 that is shaped like the device object but carries no real id -
    // a renamed/emptied backend field, or a proxy replaying a stub. Treating
    // it as success persisted "" as the device id and replaced the local tags
    // with the response's empty map, with no path back: the foreground retry
    // only re-arms a FAILED registration, and this one looked registered.
    // An empty id is retriable (matches iOS), so the client exhausts all 5
    // attempts on this response before reporting the registration FAILED.
    repeat(5) {
      server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"","tags":{}}"""))
    }
    val core = newCore()

    core.initialize("app-1", "key", validBaseUrl)
    awaitIdle()

    assertEquals(5, server.requestCount)
    assertEquals(null, store.getDeviceId())
    assertEquals(mapOf("plan" to "vip"), store.getTags())

    // And it is a *failed* registration, so the next foreground retries it.
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    core.onAppForegrounded()
    awaitIdle()

    assertEquals(6, server.requestCount)
    assertEquals("device-1", store.getDeviceId())
  }

  @Test
  fun `a registration response whose tags are null completes registration and flushes queued mutations`() {
    // The backend's own "no tags on this device" shape (a nil Go map).
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":null}"""))
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    val core = newCore()

    core.initialize("app-1", "key", validBaseUrl)
    core.login("user-42")
    awaitIdle()

    // Registration completed rather than failing terminally, so the mutation
    // queued behind it went out instead of being stranded for the process' life.
    assertEquals("device-1", store.getDeviceId())
    assertEquals(emptyMap<String, String>(), store.getTags())
    assertEquals("user-42", store.getExternalUserId())
    assertEquals(2, server.requestCount)
  }
}

/** Same in-memory SharedPreferences fake used by NottiDeviceStoreTest. */
private class FakePrefsForCore : android.content.SharedPreferences {
  private val values = mutableMapOf<String, Any?>()

  override fun getAll(): MutableMap<String, *> = values.toMutableMap()
  override fun getString(key: String?, defValue: String?): String? = values[key] as? String ?: defValue
  override fun getStringSet(key: String?, defValues: MutableSet<String>?) =
    throw UnsupportedOperationException()
  override fun getInt(key: String?, defValue: Int) = values[key] as? Int ?: defValue
  override fun getLong(key: String?, defValue: Long) = values[key] as? Long ?: defValue
  override fun getFloat(key: String?, defValue: Float) = values[key] as? Float ?: defValue
  override fun getBoolean(key: String?, defValue: Boolean) = values[key] as? Boolean ?: defValue
  override fun contains(key: String?) = values.containsKey(key)
  override fun edit(): android.content.SharedPreferences.Editor = FakeEditor()
  override fun registerOnSharedPreferenceChangeListener(
    listener: android.content.SharedPreferences.OnSharedPreferenceChangeListener?
  ) = Unit
  override fun unregisterOnSharedPreferenceChangeListener(
    listener: android.content.SharedPreferences.OnSharedPreferenceChangeListener?
  ) = Unit

  private inner class FakeEditor : android.content.SharedPreferences.Editor {
    private val pending = mutableMapOf<String, Any?>()
    private val removals = mutableSetOf<String>()
    private var shouldClear = false

    override fun putString(key: String?, value: String?) = apply { pending[key!!] = value }
    override fun putStringSet(key: String?, values: MutableSet<String>?) =
      throw UnsupportedOperationException()
    override fun putInt(key: String?, value: Int) = apply { pending[key!!] = value }
    override fun putLong(key: String?, value: Long) = apply { pending[key!!] = value }
    override fun putFloat(key: String?, value: Float) = apply { pending[key!!] = value }
    override fun putBoolean(key: String?, value: Boolean) = apply { pending[key!!] = value }
    override fun remove(key: String?) = apply { removals.add(key!!) }
    override fun clear() = apply { shouldClear = true }
    override fun commit(): Boolean {
      apply()
      return true
    }

    override fun apply() {
      if (shouldClear) values.clear()
      removals.forEach { values.remove(it) }
      values.putAll(pending)
    }
  }
}
