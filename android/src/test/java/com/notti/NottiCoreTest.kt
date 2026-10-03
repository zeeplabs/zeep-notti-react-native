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
import org.junit.Assert.assertNull
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
    coreExecutor: Executor = executor,
    onDeviceIdChanged: (String) -> Unit = {},
    eventStore: NottiEventStore = NottiEventStore(prefs),
    versionProvider: () -> String? = { null },
    hasLocationPermission: () -> Boolean = { false },
    countryProvider: (callback: (String?) -> Unit) -> Unit = { cb -> cb(null) },
    clock: () -> Long = { System.currentTimeMillis() },
    sessionGate: NottiCore.SessionGate = NottiCore.SessionGate(),
    deviceOsProvider: () -> String? = { null },
    deviceModelProvider: () -> String? = { null },
    timezoneProvider: () -> String? = { null },
    languageProvider: () -> String? = { null },
    permissionStatusProvider: (callback: (String?) -> Unit) -> Unit = { cb -> cb(null) }
  ) = NottiCore(
    deviceStore = store,
    eventStore = eventStore,
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
    executor = coreExecutor,
    onDeviceIdChanged = onDeviceIdChanged,
    versionProvider = versionProvider,
    hasLocationPermission = hasLocationPermission,
    countryProvider = countryProvider,
    clock = clock,
    sessionGate = sessionGate,
    deviceOsProvider = deviceOsProvider,
    deviceModelProvider = deviceModelProvider,
    timezoneProvider = timezoneProvider,
    languageProvider = languageProvider,
    permissionStatusProvider = permissionStatusProvider
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
  fun `initialize happy path exposes the persisted id via getDeviceId`() {
    server.enqueue(
      MockResponse().setResponseCode(200)
        .setBody("""{"id":"device-1","tags":{}}""")
    )
    val core = newCore()

    core.initialize("app-1", "key", validBaseUrl)
    awaitIdle()

    assertEquals("device-1", core.getDeviceId())
  }

  @Test
  fun `first registration notifies onDeviceIdChanged with the newly assigned id`() {
    server.enqueue(
      MockResponse().setResponseCode(200)
        .setBody("""{"id":"device-1","tags":{}}""")
    )
    val changes = mutableListOf<String>()
    val core = newCore(onDeviceIdChanged = { changes.add(it) })

    core.initialize("app-1", "key", validBaseUrl)
    awaitIdle()

    assertEquals(listOf("device-1"), changes)
  }

  @Test
  fun `a re-registration that returns the same id does not notify onDeviceIdChanged again`() {
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    val changes = mutableListOf<String>()
    val core = newCore(onDeviceIdChanged = { changes.add(it) })
    core.initialize("app-1", "key", validBaseUrl)
    awaitIdle()

    core.onTokenRefreshed("new-fcm-token")
    awaitIdle()

    assertEquals(listOf("device-1"), changes)
  }

  @Test
  fun `a re-registration that returns a different id notifies onDeviceIdChanged with the new value`() {
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-2","tags":{}}"""))
    val changes = mutableListOf<String>()
    val core = newCore(onDeviceIdChanged = { changes.add(it) })
    core.initialize("app-1", "key", validBaseUrl)
    awaitIdle()

    core.onTokenRefreshed("new-fcm-token")
    awaitIdle()

    assertEquals(listOf("device-1", "device-2"), changes)
    assertEquals("device-2", core.getDeviceId())
  }

  @Test
  fun `a first registration that fails does not notify onDeviceIdChanged and leaves getDeviceId null`() {
    repeat(5) { server.enqueue(MockResponse().setResponseCode(500)) }
    val changes = mutableListOf<String>()
    val core = newCore(onDeviceIdChanged = { changes.add(it) })

    core.initialize("app-1", "key", validBaseUrl)
    awaitIdle()

    assertEquals(emptyList<String>(), changes)
    assertEquals(null, core.getDeviceId())
  }

  @Test
  fun `a re-registration that fails does not notify onDeviceIdChanged and leaves getDeviceId at its last known value`() {
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    repeat(5) { server.enqueue(MockResponse().setResponseCode(500)) }
    val changes = mutableListOf<String>()
    val core = newCore(onDeviceIdChanged = { changes.add(it) })
    core.initialize("app-1", "key", validBaseUrl)
    awaitIdle()

    core.onTokenRefreshed("new-fcm-token")
    awaitIdle()

    assertEquals(listOf("device-1"), changes)
    assertEquals("device-1", core.getDeviceId())
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
  fun `logout clears the external user id locally and clears email and phone server-side`() {
    repeat(4) { server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}""")) }
    val core = newCore()
    core.initialize("app-1", "key", validBaseUrl)
    core.login("user-42")
    awaitIdle()
    assertEquals("user-42", store.getExternalUserId())

    core.logout()
    awaitIdle()

    // Initial register + login PATCH from setup above, then logout()'s
    // {email: null} and {phone: null} clears (LGPD: PII is cleared
    // server-side). external_user_id itself is never sent (spec SDK-15:
    // local-only clear, the backend cannot clear it server-side).
    assertEquals(4, server.requestCount)
    server.takeRequest(5, TimeUnit.SECONDS) // register
    server.takeRequest(5, TimeUnit.SECONDS) // login
    val bodies = (0 until 2).map {
      JSONObject(requireNotNull(server.takeRequest(5, TimeUnit.SECONDS)).body.readUtf8())
    }
    assertTrue(bodies.any { it.has("email") && it.isNull("email") })
    assertTrue(bodies.any { it.has("phone") && it.isNull("phone") })
    assertTrue("logout never sends external_user_id: $bodies", bodies.none { it.has("external_user_id") })
    assertEquals(null, store.getExternalUserId())
    assertNull(store.getEmail())
    assertNull(store.getPhone())
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
    // logout()'s email/phone clears.
    repeat(2) { server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}""")) }
    val core = newCore()
    core.initialize("app-1", "key", validBaseUrl)
    awaitIdle()

    // Both from the same (JS) thread, back to back, as an app signing a user
    // out immediately after a failed/aborted sign-in does.
    core.login("user-42")
    core.logout()
    awaitIdle()

    // register + login + logout's email/phone clears.
    assertEquals(4, server.requestCount)
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

  @Test
  fun `registration success with a version provider diff enqueues a PATCH with the current app version`() {
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    val core = newCore(versionProvider = { "1.2.3" })

    core.initialize("app-1", "key", validBaseUrl)
    awaitIdle()
    // The version PATCH is enqueued from inside the registration task, so it
    // only runs after that task (and this second barrier) complete.
    awaitIdle()

    assertEquals(2, server.requestCount)
    assertEquals("POST", requireNotNull(server.takeRequest(5, TimeUnit.SECONDS)).method)
    val patch = requireNotNull(server.takeRequest(5, TimeUnit.SECONDS))
    assertEquals("PATCH", patch.method)
    assertEquals("1.2.3", JSONObject(patch.body.readUtf8()).getString("app_version"))
    assertEquals("1.2.3", store.getAppVersion())
  }

  @Test
  fun `registration success with an unchanged app version does not enqueue a PATCH`() {
    store.setAppVersion("1.2.3")
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    val core = newCore(versionProvider = { "1.2.3" })

    core.initialize("app-1", "key", validBaseUrl)
    awaitIdle()

    // Only the registration POST - diff-and-enqueue is a no-op on equal values.
    assertEquals(1, server.requestCount)
    assertEquals("1.2.3", store.getAppVersion())
  }

  @Test
  fun `registration success with a null version provider enqueues nothing and does not crash`() {
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    val core = newCore(versionProvider = { null })

    core.initialize("app-1", "key", validBaseUrl)
    awaitIdle()

    assertEquals(1, server.requestCount)
    assertEquals(null, store.getAppVersion())
  }

  @Test
  fun `a bumped app version between two registrations enqueues a PATCH with the new value`() {
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    var currentVersion = "1.2.3"
    val core = newCore(versionProvider = { currentVersion })

    core.initialize("app-1", "key", validBaseUrl)
    awaitIdle()
    awaitIdle() // version PATCH enqueued inside the registration task
    assertEquals("1.2.3", store.getAppVersion())

    currentVersion = "1.2.4"
    core.onTokenRefreshed("new-fcm-token")
    awaitIdle()
    awaitIdle() // version PATCH enqueued inside the re-registration task

    // Second registration POST + a PATCH carrying the NEW version, proving
    // diff-and-enqueue rather than always-send.
    assertEquals(4, server.requestCount)
    server.takeRequest(5, TimeUnit.SECONDS) // first register
    assertEquals("1.2.3", JSONObject(requireNotNull(server.takeRequest(5, TimeUnit.SECONDS)).body.readUtf8()).getString("app_version"))
    server.takeRequest(5, TimeUnit.SECONDS) // second register
    val secondPatch = requireNotNull(server.takeRequest(5, TimeUnit.SECONDS))
    assertEquals("PATCH", secondPatch.method)
    assertEquals("1.2.4", JSONObject(secondPatch.body.readUtf8()).getString("app_version"))
    assertEquals("1.2.4", store.getAppVersion())
  }

  // ---------------------------------------------------------------------
  // Device profile fields (device-profile-fields, T3)
  // ---------------------------------------------------------------------

  @Test
  fun `registration success with profile providers enqueues a PATCH with all six fields`() {
    repeat(7) { server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}""")) }
    val core = newCore(
      versionProvider = { "1.2.3" },
      deviceOsProvider = { "15.0" },
      deviceModelProvider = { "Pixel 8" },
      timezoneProvider = { "America/Sao_Paulo" },
      languageProvider = { "pt" }
    )

    core.initialize("app-1", "key", validBaseUrl, "0.5.0")
    awaitIdle()
    awaitIdle()

    // Registration POST + six PATCHes (one per field).
    assertEquals(7, server.requestCount)
    server.takeRequest(5, TimeUnit.SECONDS) // register
    val patches = (0 until 6).map {
      val req = requireNotNull(server.takeRequest(5, TimeUnit.SECONDS))
      assertEquals("PATCH", req.method)
      JSONObject(req.body.readUtf8())
    }
    assertEquals("1.2.3", patches.first().getString("app_version"))
    assertEquals("15.0", patches.first { it.has("device_os") }.getString("device_os"))
    assertEquals("Pixel 8", patches.first { it.has("device_model") }.getString("device_model"))
    assertEquals("0.5.0", patches.first { it.has("sdk_version") }.getString("sdk_version"))
    assertEquals("America/Sao_Paulo", patches.first { it.has("timezone_id") }.getString("timezone_id"))
    assertEquals("pt", patches.first { it.has("language") }.getString("language"))
    assertEquals("1.2.3", store.getAppVersion())
    assertEquals("15.0", store.getLastSyncedDeviceOs())
    assertEquals("Pixel 8", store.getLastSyncedDeviceModel())
    assertEquals("0.5.0", store.getLastSyncedSdkVersion())
    assertEquals("America/Sao_Paulo", store.getLastSyncedTimezoneId())
    assertEquals("pt", store.getLastSyncedLanguage())
  }

  @Test
  fun `only a changed profile field is re-sent between two registrations`() {
    repeat(10) { server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}""")) }
    var deviceOs = "15.0"
    var timezone = "America/Sao_Paulo"
    val core = newCore(
      versionProvider = { "1.2.3" },
      deviceOsProvider = { deviceOs },
      deviceModelProvider = { "Pixel 8" },
      timezoneProvider = { timezone },
      languageProvider = { "pt" }
    )

    core.initialize("app-1", "key", validBaseUrl, "0.5.0")
    awaitIdle()
    awaitIdle()
    assertEquals("15.0", store.getLastSyncedDeviceOs())

    // Only the OS version and timezone change between the two registrations.
    deviceOs = "16.0"
    timezone = "America/New_York"
    core.onTokenRefreshed("new-fcm-token")
    awaitIdle()
    awaitIdle()

    // First register POST + 6 PATCHes + second register POST + 2 changed-field PATCHes.
    assertEquals(10, server.requestCount)
    server.takeRequest(5, TimeUnit.SECONDS) // first register
    repeat(6) { server.takeRequest(5, TimeUnit.SECONDS) } // first batch of six PATCHes
    server.takeRequest(5, TimeUnit.SECONDS) // second register
    val resent = (0 until 2).map {
      JSONObject(requireNotNull(server.takeRequest(5, TimeUnit.SECONDS)).body.readUtf8())
    }
    assertEquals("16.0", resent.first { it.has("device_os") }.getString("device_os"))
    assertEquals("America/New_York", resent.first { it.has("timezone_id") }.getString("timezone_id"))
    // The PATCH always carries `token` (AD-009); beyond that, only the changed
    // field is re-sent - never the whole profile set (DPF-03/08).
    assertTrue(
      "only the changed fields are re-sent: $resent",
      resent.all { it.length() == 2 && it.has("token") }
    )
    assertEquals("16.0", store.getLastSyncedDeviceOs())
    assertEquals("America/New_York", store.getLastSyncedTimezoneId())
    // The unchanged fields keep their persisted last-synced values.
    assertEquals("Pixel 8", store.getLastSyncedDeviceModel())
    assertEquals("0.5.0", store.getLastSyncedSdkVersion())
    assertEquals("pt", store.getLastSyncedLanguage())
  }

  @Test
  fun `a null profile provider omits that field without crashing`() {
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    // All providers default to null - only versionProvider set.
    val core = newCore(versionProvider = { "1.2.3" })

    core.initialize("app-1", "key", validBaseUrl)
    awaitIdle()
    awaitIdle()

    // Registration POST + only the app_version PATCH - the null providers
    // enqueue nothing and never crash (DPF-04/09).
    assertEquals(2, server.requestCount)
    server.takeRequest(5, TimeUnit.SECONDS) // register
    val patch = JSONObject(requireNotNull(server.takeRequest(5, TimeUnit.SECONDS)).body.readUtf8())
    assertEquals("1.2.3", patch.getString("app_version"))
    assertFalse(patch.has("device_os"))
    assertFalse(patch.has("device_model"))
    assertFalse(patch.has("sdk_version"))
    assertFalse(patch.has("timezone_id"))
    assertFalse(patch.has("language"))
  }

  @Test
  fun `sdk_version passed through initialize reaches the payload`() {
    repeat(4) { server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}""")) }
    val core = newCore(deviceOsProvider = { "15.0" }, timezoneProvider = { "UTC" })

    // The package version is forwarded by the JS facade as the 4th arg.
    core.initialize("app-1", "key", validBaseUrl, "0.5.0")
    awaitIdle()
    awaitIdle()

    // Registration POST + 3 PATCHes (device_os, sdk_version, timezone_id).
    assertEquals(4, server.requestCount)
    server.takeRequest(5, TimeUnit.SECONDS) // register
    val patches = (0 until 3).map {
      JSONObject(requireNotNull(server.takeRequest(5, TimeUnit.SECONDS)).body.readUtf8())
    }
    val sdk = patches.firstOrNull { it.has("sdk_version") }
    assertTrue("sdk_version must reach the payload: $patches", sdk != null)
    assertEquals("0.5.0", sdk!!.getString("sdk_version"))
    assertEquals("0.5.0", store.getLastSyncedSdkVersion())
  }

  // ---------------------------------------------------------------------
  // Permission status + last_unsubscribed_at (device-profile-fields, T4)
  // ---------------------------------------------------------------------

  @Test
  fun `registration success syncs permission status`() {
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    val core = newCore(permissionStatusProvider = { cb -> cb("granted") })

    core.initialize("app-1", "key", validBaseUrl)
    awaitIdle()
    awaitIdle()

    server.takeRequest(5, TimeUnit.SECONDS) // register
    val patch = requireNotNull(server.takeRequest(5, TimeUnit.SECONDS))
    assertEquals("PATCH", patch.method)
    assertEquals("granted", JSONObject(patch.body.readUtf8()).getString("permission_status"))
    assertEquals("granted", store.getLastSyncedPermissionStatus())
  }

  @Test
fun `requestPermission result syncs the OS permission status`() {
    // register POST + permission_status (notDetermined) + subscribed PATCH +
    // permission_status (granted) PATCH.
    repeat(4) { server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}""")) }
    // Registration saw "never asked" (notDetermined); the user then grants the
    // OS prompt, so requestPermission must read the NEW OS state.
    var permissionStatus: String? = "notDetermined"
    val core = newCore(
      permissionRequester = { cb -> permissionStatus = "granted"; cb(true) },
      permissionStatusProvider = { cb -> cb(permissionStatus) }
    )
    core.initialize("app-1", "key", validBaseUrl)
    awaitIdle()
    awaitIdle()
    server.takeRequest(5, TimeUnit.SECONDS) // register
    server.takeRequest(5, TimeUnit.SECONDS) // permission_status (notDetermined)

    core.requestPermission { }
    awaitIdle()
    awaitIdle()

    // The subscribed PATCH (from the dialog bool) plus a permission_status
    // PATCH read from the OS state, not inferred from the bool.
    val bodies = (0 until 2).map {
      JSONObject(requireNotNull(server.takeRequest(5, TimeUnit.SECONDS)).body.readUtf8())
    }
    val subscribed = bodies.first { it.has("subscribed") }
    assertEquals(true, subscribed.getBoolean("subscribed"))
    val permission = bodies.first { it.has("permission_status") }
    assertEquals("granted", permission.getString("permission_status"))
  }

  @Test
  fun `a granted to denied Settings change is caught at the next session start`() {
    repeat(4) { server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}""")) }
    store.setLastSyncedPermissionStatus("granted")
    var permissionStatus: String? = "granted"
    val core = newCore(
      permissionStatusProvider = { cb -> cb(permissionStatus) },
      clock = { 1_000L }
    )
    core.initialize("app-1", "key", validBaseUrl)
    awaitIdle()
    awaitIdle()
    drainRequests()

    // The user disables push in OS Settings while the app is backgrounded;
    // the next session start re-reads the OS state and finds granted -> denied.
    permissionStatus = "denied"
    core.onAppForegrounded()
    awaitIdle()
    awaitIdle()

    val permission = requireNotNull(server.takeRequest(5, TimeUnit.SECONDS))
    assertEquals("PATCH", permission.method)
    val body = JSONObject(permission.body.readUtf8())
    assertEquals("denied", body.getString("permission_status"))
    // The granted->denied transition also carries last_unsubscribed_at in the
    // same atomic request (DPF-14 permission-driven path).
    assertEquals("1970-01-01T00:00:01.000Z", body.getString("last_unsubscribed_at"))
    assertEquals("denied", store.getLastSyncedPermissionStatus())
    assertEquals(1_000L, store.getLastUnsubscribedAtMs())
  }

  @Test
  fun `setSubscription false on a subscribed device sets last_unsubscribed_at while permission stays granted`() {
    // register POST + permission_status PATCH (registration) + subscribed(false)+last_unsubscribed_at PATCH.
    repeat(3) { server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}""")) }
    store.setSubscribed(true)
    val core = newCore(
      permissionStatusProvider = { cb -> cb("granted") },
      clock = { 1_000L }
    )
    core.initialize("app-1", "key", validBaseUrl)
    awaitIdle()
    awaitIdle()

    core.setSubscription(false)
    awaitIdle()
    awaitIdle()

    val bodies = drainRequests().map { JSONObject(it.body.readUtf8()) }
    val transition = bodies.filter { it.has("subscribed") }.first { it.getBoolean("subscribed") == false }
    assertEquals("the timestamp must travel in the same PATCH as subscribed (atomic, DPF-14)",
      "1970-01-01T00:00:01.000Z", transition.getString("last_unsubscribed_at"))
    assertEquals(1_000L, store.getLastUnsubscribedAtMs())
    // The app opt-out does not touch the OS permission axis (DPF-16).
    val permissionPatches = bodies.filter { it.has("permission_status") }
    assertTrue("permission_status must stay granted, not flip: $bodies",
      permissionPatches.all { it.getString("permission_status") == "granted" })
    assertFalse(store.getSubscribed())
  }

  @Test
  fun `re-subscribe does not clear last_unsubscribed_at`() {
    // register POST + permission_status PATCH + subscribed(false)+last_unsubscribed_at PATCH + subscribed(true) PATCH.
    repeat(4) { server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}""")) }
    store.setSubscribed(true)
    val core = newCore(
      permissionStatusProvider = { cb -> cb("granted") },
      clock = { 1_000L }
    )
    core.initialize("app-1", "key", validBaseUrl)
    awaitIdle()
    awaitIdle()

    core.setSubscription(false)
    awaitIdle()
    awaitIdle()
    assertEquals(1_000L, store.getLastUnsubscribedAtMs())

    core.setSubscription(true)
    awaitIdle()
    awaitIdle()

    // The timestamp is history, never cleared on re-subscribe (DPF-15).
    assertEquals(1_000L, store.getLastUnsubscribedAtMs())
    assertTrue(store.getSubscribed())
    val bodies = drainRequests().map { JSONObject(it.body.readUtf8()) }
    assertTrue("no clear of last_unsubscribed_at: $bodies",
      bodies.none { it.has("last_unsubscribed_at") && it.isNull("last_unsubscribed_at") })
  }

  @Test
  fun `an unknown permission status is omitted without crashing`() {
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    val core = newCore(permissionStatusProvider = { cb -> cb(null) })

    core.initialize("app-1", "key", validBaseUrl)
    awaitIdle()
    awaitIdle()

    // Registration POST only - no permission_status fabricated (DPF edge case).
    assertEquals(1, server.requestCount)
    assertNull(store.getLastSyncedPermissionStatus())
  }

  // ---------------------------------------------------------------------
  // First-class email/phone (device-profile-fields, T5)
  // ---------------------------------------------------------------------

  @Test
  fun `setEmail enqueues a PATCH with email and never touches tags`() {
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    val core = newCore()
    core.initialize("app-1", "key", validBaseUrl)
    awaitIdle()

    core.setEmail("user@example.com")
    awaitIdle()
    awaitIdle()

    server.takeRequest(5, TimeUnit.SECONDS) // register
    val patch = requireNotNull(server.takeRequest(5, TimeUnit.SECONDS))
    assertEquals("PATCH", patch.method)
    val body = JSONObject(patch.body.readUtf8())
    assertEquals("user@example.com", body.getString("email"))
    assertFalse("email must travel as its own field, never merged into tags (DPF-21)", body.has("tags"))
    assertEquals("user@example.com", store.getEmail())
  }

  @Test
  fun `clearEmail enqueues an explicit email null clear`() {
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    val core = newCore()
    core.initialize("app-1", "key", validBaseUrl)
    awaitIdle()

    core.clearEmail()
    awaitIdle()
    awaitIdle()

    server.takeRequest(5, TimeUnit.SECONDS) // register
    val patch = requireNotNull(server.takeRequest(5, TimeUnit.SECONDS))
    assertEquals("PATCH", patch.method)
    assertTrue(JSONObject(patch.body.readUtf8()).isNull("email"))
    assertNull(store.getEmail())
  }

  @Test
  fun `setEmail twice with the same value enqueues a single mutation`() {
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    val core = newCore()
    core.initialize("app-1", "key", validBaseUrl)
    awaitIdle()

    core.setEmail("user@example.com")
    awaitIdle()
    awaitIdle()
    assertEquals("user@example.com", store.getEmail())

    core.setEmail("user@example.com")
    awaitIdle()
    awaitIdle()

    // register POST + exactly one email PATCH - the duplicate set is a no-op
    // (DPF-20 idempotence, matching addTag).
    assertEquals(2, server.requestCount)
    assertEquals("user@example.com", store.getEmail())
  }

  @Test
  fun `setPhone enqueues a PATCH with phone`() {
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    val core = newCore()
    core.initialize("app-1", "key", validBaseUrl)
    awaitIdle()

    core.setPhone("+5511999999999")
    awaitIdle()
    awaitIdle()

    server.takeRequest(5, TimeUnit.SECONDS) // register
    val patch = requireNotNull(server.takeRequest(5, TimeUnit.SECONDS))
    assertEquals("PATCH", patch.method)
    assertEquals("+5511999999999", JSONObject(patch.body.readUtf8()).getString("phone"))
    assertEquals("+5511999999999", store.getPhone())
  }

  @Test
  fun `registration success re-sends a held email and phone`() {
    store.setEmail("held@example.com")
    store.setPhone("+10000000000")
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    val core = newCore()

    core.initialize("app-1", "key", validBaseUrl)
    awaitIdle()
    awaitIdle()

    // register POST + email PATCH + phone PATCH - the held values converge
    // onto a (possibly fresh) backend row without re-calling the setters
    // (DPF-19).
    assertEquals(3, server.requestCount)
    server.takeRequest(5, TimeUnit.SECONDS) // register
    val bodies = (0 until 2).map {
      JSONObject(requireNotNull(server.takeRequest(5, TimeUnit.SECONDS)).body.readUtf8())
    }
    assertTrue(bodies.any { it.optString("email") == "held@example.com" })
    assertTrue(bodies.any { it.optString("phone") == "+10000000000" })
  }

  @Test
  fun `registration success with no held email or phone sends nothing for them`() {
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    val core = newCore()

    core.initialize("app-1", "key", validBaseUrl)
    awaitIdle()
    awaitIdle()

    // Only the registration POST - null held values are never sent (DPF-19).
    assertEquals(1, server.requestCount)
  }

  // ---------------------------------------------------------------------
  // Review fixes (device-profile-fields, PR #24)
  // ---------------------------------------------------------------------

  private fun ok() = MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}""")

  /** A non-retried 4xx: a single attempt, then ApiResult.Failure. */
  private fun rejected() = MockResponse().setResponseCode(422)

  private fun nextBody(): JSONObject =
    JSONObject(requireNotNull(server.takeRequest(5, TimeUnit.SECONDS)).body.readUtf8())

  @Test
  fun `clearEmail before initialize with a previously synced email is sent as email null at registration`() {
    // A previous launch synced the email; this launch clears it before initialize().
    store.setEmail("old@example.com")
    store.setLastSyncedEmail("old@example.com")
    val core = newCore()

    core.clearEmail()
    assertNull("the clear is held durably even before initialize", store.getEmail())

    server.enqueue(ok())
    server.enqueue(ok())
    core.initialize("app-1", "key", validBaseUrl)
    awaitIdle()
    awaitIdle()

    // register + the owed {email: null} clear.
    assertEquals(2, server.requestCount)
    server.takeRequest(5, TimeUnit.SECONDS) // register
    val clear = nextBody()
    assertTrue(clear.has("email") && clear.isNull("email"))
    assertNull(store.getLastSyncedEmail())
  }

  @Test
  fun `a clear whose PATCH failed is re-sent at the next registration`() {
    store.setEmail("old@example.com")
    store.setLastSyncedEmail("old@example.com")
    server.enqueue(ok()) // register
    server.enqueue(ok()) // resync of the held email
    server.enqueue(rejected()) // clearEmail PATCH fails
    server.enqueue(ok()) // second register
    server.enqueue(ok()) // re-sent clear
    val core = newCore()
    core.initialize("app-1", "key", validBaseUrl)
    awaitIdle()
    awaitIdle()

    core.clearEmail()
    awaitIdle()
    assertEquals("a failed clear is still owed", "old@example.com", store.getLastSyncedEmail())

    core.onTokenRefreshed("new-fcm-token")
    awaitIdle()
    awaitIdle()

    assertEquals(5, server.requestCount)
    repeat(4) { server.takeRequest(5, TimeUnit.SECONDS) }
    val resent = nextBody()
    assertTrue(resent.has("email") && resent.isNull("email"))
    assertNull(store.getEmail())
    assertNull(store.getLastSyncedEmail())
  }

  @Test
  fun `setEmail with the same value after a failed PATCH re-enqueues it`() {
    server.enqueue(ok()) // register
    server.enqueue(rejected()) // first setEmail fails
    server.enqueue(ok()) // retry with the same value
    val core = newCore()
    core.initialize("app-1", "key", validBaseUrl)
    awaitIdle()

    core.setEmail("user@example.com")
    awaitIdle()
    assertNull(store.getLastSyncedEmail())

    core.setEmail("user@example.com")
    awaitIdle()

    // Held == value but never acknowledged: not a no-op (F7).
    assertEquals(3, server.requestCount)
    server.takeRequest(5, TimeUnit.SECONDS) // register
    server.takeRequest(5, TimeUnit.SECONDS) // failed set
    assertEquals("user@example.com", nextBody().getString("email"))
    assertEquals("user@example.com", store.getLastSyncedEmail())
  }

  @Test
  fun `logout before registration supersedes a queued setEmail with the clear`() {
    var deliverToken: ((String?) -> Unit)? = null
    val core = newCore(tokenProvider = { cb -> deliverToken = cb })
    core.initialize("app-1", "key", validBaseUrl)

    core.setEmail("user@example.com")
    core.setPhone("+5511999999999")
    core.logout()
    awaitIdle()

    server.enqueue(ok()) // register
    server.enqueue(ok()) // email clear
    server.enqueue(ok()) // phone clear
    requireNotNull(deliverToken)("fcm-token")
    awaitIdle()
    awaitIdle()

    // The coalesce key makes each clear replace its queued set: the PII is
    // never sent, only the clears (and the registration resync sends nothing,
    // since held and last-synced are both null once the clears are acked).
    assertEquals(3, server.requestCount)
    server.takeRequest(5, TimeUnit.SECONDS) // register
    val bodies = (0 until 2).map { nextBody() }
    assertTrue(bodies.any { it.has("email") && it.isNull("email") })
    assertTrue(bodies.any { it.has("phone") && it.isNull("phone") })
    assertNull(store.getEmail())
    assertNull(store.getPhone())
  }

  @Test
  fun `a set acked after a newer clear still records lastSynced so a failed clear is re-sent at registration`() {
    server.enqueue(ok()) // register
    server.enqueue(ok()) // setEmail("x") - acked while the held value is already null
    server.enqueue(rejected()) // clearEmail fails
    server.enqueue(ok()) // second register
    server.enqueue(ok()) // re-sent clear
    val core = newCore()
    core.initialize("app-1", "key", validBaseUrl)
    awaitIdle()

    core.setEmail("x@example.com")
    core.clearEmail()
    awaitIdle()

    // The server now holds x (its set was acked, the clear was not): lastSynced
    // must reflect that, even though the held value had already moved to null.
    assertEquals("x@example.com", store.getLastSyncedEmail())

    core.onTokenRefreshed("new-fcm-token")
    awaitIdle()
    awaitIdle()

    assertEquals(5, server.requestCount)
    repeat(4) { server.takeRequest(5, TimeUnit.SECONDS) }
    assertTrue(nextBody().isNull("email"))
    assertNull(store.getLastSyncedEmail())
  }

  @Test
  fun `back-to-back sets converge lastSynced to the newest value`() {
    repeat(3) { server.enqueue(ok()) }
    val core = newCore()
    core.initialize("app-1", "key", validBaseUrl)
    awaitIdle()

    core.setEmail("a@example.com")
    core.setEmail("b@example.com")
    awaitIdle()

    assertEquals(3, server.requestCount)
    assertEquals("b@example.com", store.getEmail())
    assertEquals("b@example.com", store.getLastSyncedEmail())
  }

  @Test
  fun `registration resync records the acknowledged held value as synced`() {
    store.setEmail("held@example.com")
    server.enqueue(ok())
    server.enqueue(ok())
    val core = newCore()

    core.initialize("app-1", "key", validBaseUrl)
    awaitIdle()
    awaitIdle()

    assertEquals("held@example.com", store.getLastSyncedEmail())
    // Held and acked: a later identical setEmail is now a true no-op.
    core.setEmail("held@example.com")
    awaitIdle()
    assertEquals(2, server.requestCount)
  }

  @Test
  fun `setSubscription false with unknown local state records last_unsubscribed_at`() {
    server.enqueue(ok())
    server.enqueue(ok())
    // No subscription was ever acked on this install: the backend row
    // defaults to subscribed = true, so this IS a transition.
    assertNull(store.getSubscribedOrNull())
    val core = newCore(clock = { 1_000L })
    core.initialize("app-1", "key", validBaseUrl)
    awaitIdle()

    core.setSubscription(false)
    awaitIdle()

    server.takeRequest(5, TimeUnit.SECONDS) // register
    val body = nextBody()
    assertEquals(false, body.getBoolean("subscribed"))
    assertEquals("1970-01-01T00:00:01.000Z", body.getString("last_unsubscribed_at"))
    assertEquals(1_000L, store.getLastUnsubscribedAtMs())
    assertEquals(false, store.getSubscribedOrNull())
    assertNull(store.getPendingUnsubscribeAtMs())
  }

  @Test
  fun `setSubscription false on an already unsubscribed device does not record last_unsubscribed_at`() {
    server.enqueue(ok())
    server.enqueue(ok())
    store.setSubscribed(false)
    val core = newCore(clock = { 1_000L })
    core.initialize("app-1", "key", validBaseUrl)
    awaitIdle()

    core.setSubscription(false)
    awaitIdle()

    server.takeRequest(5, TimeUnit.SECONDS) // register
    val body = nextBody()
    assertEquals(false, body.getBoolean("subscribed"))
    assertFalse("false -> false is not a transition: $body", body.has("last_unsubscribed_at"))
    assertNull(store.getLastUnsubscribedAtMs())
  }

  @Test
  fun `a retried setSubscription false re-sends the timestamp of the first detection`() {
    server.enqueue(ok()) // register
    server.enqueue(rejected()) // first unsubscribe fails
    server.enqueue(ok()) // retry
    store.setSubscribed(true)
    var now = 1_000L
    val core = newCore(clock = { now })
    core.initialize("app-1", "key", validBaseUrl)
    awaitIdle()

    core.setSubscription(false)
    awaitIdle()
    assertEquals(1_000L, store.getPendingUnsubscribeAtMs())
    assertTrue("a failed PATCH leaves the local state subscribed", store.getSubscribed())

    now = 5_000L
    core.setSubscription(false)
    awaitIdle()

    server.takeRequest(5, TimeUnit.SECONDS) // register
    assertEquals("1970-01-01T00:00:01.000Z", nextBody().getString("last_unsubscribed_at"))
    assertEquals("the retry reuses the persisted detection time, not a fresh now()",
      "1970-01-01T00:00:01.000Z", nextBody().getString("last_unsubscribed_at"))
    assertEquals(1_000L, store.getLastUnsubscribedAtMs())
    assertNull(store.getPendingUnsubscribeAtMs())
    assertFalse(store.getSubscribed())
  }

  @Test
  fun `a retried granted to denied permission sync re-sends the timestamp of the first detection`() {
    server.enqueue(ok()) // register
    server.enqueue(rejected()) // permission_status=denied PATCH fails
    server.enqueue(ok()) // retried at the next session start
    store.setLastSyncedPermissionStatus("granted")
    var now = 1_000L
    val core = newCore(
      permissionStatusProvider = { cb -> cb("denied") },
      clock = { now }
    )
    core.initialize("app-1", "key", validBaseUrl)
    awaitIdle()
    awaitIdle()
    assertEquals(1_000L, store.getPendingPermissionUnsubscribeAtMs())
    assertEquals("granted", store.getLastSyncedPermissionStatus())

    now = 5_000L
    core.onAppForegrounded()
    awaitIdle()
    awaitIdle()

    server.takeRequest(5, TimeUnit.SECONDS) // register
    assertEquals("1970-01-01T00:00:01.000Z", nextBody().getString("last_unsubscribed_at"))
    val retried = nextBody()
    assertEquals("denied", retried.getString("permission_status"))
    assertEquals("1970-01-01T00:00:01.000Z", retried.getString("last_unsubscribed_at"))
    assertEquals("denied", store.getLastSyncedPermissionStatus())
    assertEquals(1_000L, store.getLastUnsubscribedAtMs())
    assertNull(store.getPendingPermissionUnsubscribeAtMs())
  }

  @Test
  fun `permission status mapping covers every branch`() {
    data class Case(
      val sdk: Int,
      val enabled: Boolean,
      val granted: Boolean,
      val requested: Boolean,
      val rationale: Boolean?,
      val expected: String
    )
    val cases = listOf(
      // API < 33: notifications-enabled alone decides.
      Case(32, enabled = true, granted = false, requested = false, rationale = null, expected = "granted"),
      Case(32, enabled = false, granted = false, requested = true, rationale = true, expected = "denied"),
      Case(26, enabled = true, granted = true, requested = true, rationale = false, expected = "granted"),
      // API >= 33, permission granted.
      Case(33, enabled = true, granted = true, requested = true, rationale = null, expected = "granted"),
      Case(34, enabled = false, granted = true, requested = true, rationale = false, expected = "denied"),
      // API >= 33, not granted: rationale wins.
      Case(33, enabled = false, granted = false, requested = false, rationale = true, expected = "denied"),
      // Never requested by the SDK, no rationale (or no Activity) -> notDetermined.
      Case(33, enabled = true, granted = false, requested = false, rationale = false, expected = "notDetermined"),
      Case(33, enabled = false, granted = false, requested = false, rationale = null, expected = "notDetermined"),
      // Requested before, no rationale -> permanently denied.
      Case(33, enabled = false, granted = false, requested = true, rationale = false, expected = "denied"),
      Case(35, enabled = false, granted = false, requested = true, rationale = null, expected = "denied")
    )
    cases.forEach { c ->
      assertEquals(
        "case $c",
        c.expected,
        NottiCore.mapPermissionStatus(c.sdk, c.enabled, c.granted, c.requested, c.rationale)
      )
    }
  }

  @Test
  fun `language normalization keeps the primary subtag and maps legacy codes`() {
    assertEquals("pt", NottiCore.normalizeLanguage("pt-BR"))
    assertEquals("en", NottiCore.normalizeLanguage("en"))
    assertEquals("zh", NottiCore.normalizeLanguage("zh-Hant-TW"))
    assertEquals("he", NottiCore.normalizeLanguage("iw-IL"))
    assertEquals("id", NottiCore.normalizeLanguage("in"))
    assertEquals("yi", NottiCore.normalizeLanguage("ji"))
    assertNull(NottiCore.normalizeLanguage(""))
    assertNull(NottiCore.normalizeLanguage("und"))
    assertNull(NottiCore.normalizeLanguage(null))
  }

  @Test
  fun `session end after a foreground start aggregates count and time and enqueues a snapshot PATCH`() {
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    val core = newCore()
    core.initialize("app-1", "key", validBaseUrl)
    awaitIdle()

    core.handleSessionStart(1_000L)
    core.handleSessionEnd(31_000L)
    awaitIdle()

    assertEquals(1, store.getSessionCount())
    assertEquals(30_000L, store.getSessionTimeMs())
    assertEquals(31_000L, store.getLastSessionAtMs())
    assertEquals(1_000L, store.getFirstSessionAtMs())
    assertNull(store.getSessionStartedAtMs())

    server.takeRequest(5, TimeUnit.SECONDS) // the initial register
    val patch = requireNotNull(server.takeRequest(5, TimeUnit.SECONDS))
    assertEquals("PATCH", patch.method)
    val body = JSONObject(patch.body.readUtf8())
    assertEquals("1970-01-01T00:00:01.000Z", body.getString("first_session_at"))
    assertEquals("1970-01-01T00:00:31.000Z", body.getString("last_session_at"))
    assertEquals(1, body.getInt("session_count"))
    assertEquals(30, body.getInt("session_time_seconds"))
  }

  @Test
  fun `a session start after an unclean kill closes the missed session at the last heartbeat, not at relaunch time`() {
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    val core = newCore()
    core.initialize("app-1", "key", validBaseUrl)
    awaitIdle()

    // Session starts, a foreground heartbeat lands 20s in, then the process is
    // killed with no background transition. The relaunch (an hour later) must
    // close the missed session at the LAST KNOWN FOREGROUND timestamp
    // (SEGTEL-08) - not at relaunch time, which would inflate session_time by
    // the whole time the app was dead.
    core.handleSessionStart(1_000L)
    core.recordForegroundHeartbeatAt(21_000L)
    core.handleSessionStart(3_601_000L)
    awaitIdle()

    assertEquals(1, store.getSessionCount())
    assertEquals(20_000L, store.getSessionTimeMs())
    assertEquals(21_000L, store.getLastSessionAtMs())
    // A new session is open for the relaunch.
    assertEquals(3_601_000L, store.getSessionStartedAtMs())
    assertEquals(1_000L, store.getFirstSessionAtMs())

    server.takeRequest(5, TimeUnit.SECONDS) // the initial register
    val patch = requireNotNull(server.takeRequest(5, TimeUnit.SECONDS))
    assertEquals("PATCH", patch.method)
    val body = JSONObject(patch.body.readUtf8())
    assertEquals(1, body.getInt("session_count"))
    assertEquals(20, body.getInt("session_time_seconds"))
  }

  @Test
  fun `an orphaned session with no heartbeat contributes zero time instead of the dead interval`() {
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    val core = newCore()
    core.initialize("app-1", "key", validBaseUrl)
    awaitIdle()

    core.handleSessionStart(1_000L)
    core.handleSessionStart(86_401_000L) // relaunch a day later
    awaitIdle()

    assertEquals(1, store.getSessionCount())
    assertEquals(0L, store.getSessionTimeMs())
  }

  @Test
  fun `an orphaned session heartbeat is bounded by the max orphan session cap`() {
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    val core = newCore()
    core.initialize("app-1", "key", validBaseUrl)
    awaitIdle()

    core.handleSessionStart(1_000L)
    // A heartbeat far beyond any plausible session (clock jump) is clamped.
    core.recordForegroundHeartbeatAt(1_000L + NottiCore.MAX_ORPHAN_SESSION_MS * 3)
    core.handleSessionStart(1_000L + NottiCore.MAX_ORPHAN_SESSION_MS * 4)
    awaitIdle()

    assertEquals(NottiCore.MAX_ORPHAN_SESSION_MS, store.getSessionTimeMs())
  }

  @Test
  fun `session end with no active session is a no-op with no PATCH`() {
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    val core = newCore()
    core.initialize("app-1", "key", validBaseUrl)
    awaitIdle()

    core.handleSessionEnd(5_000L)
    awaitIdle()

    // Only the registration POST - no session PATCH, no aggregate touched
    // (excludes widget/background-fetch wake-ups, SEGTEL edge case).
    assertEquals(1, server.requestCount)
    assertEquals(0, store.getSessionCount())
    assertEquals(0L, store.getSessionTimeMs())
    assertNull(store.getLastSessionAtMs())
    assertNull(store.getSessionStartedAtMs())
  }

  @Test
  fun `first_session_at is set on the first session start and never overwritten later`() {
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    val core = newCore()
    core.initialize("app-1", "key", validBaseUrl)
    awaitIdle()

    core.handleSessionStart(1_000L)
    core.handleSessionEnd(10_000L)
    core.handleSessionStart(20_000L)
    core.handleSessionEnd(30_000L)
    awaitIdle()

    assertEquals(1_000L, store.getFirstSessionAtMs())
    assertEquals(2, store.getSessionCount())
    assertEquals(19_000L, store.getSessionTimeMs())
    assertEquals(30_000L, store.getLastSessionAtMs())
    assertNull(store.getSessionStartedAtMs())
  }

  @Test
  fun `opt-in off with permission granted never reads or sends a country field`() {
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    var providerCalls = 0
    val core = newCore(
      hasLocationPermission = { true },
      countryProvider = { cb -> providerCalls++; cb("BR") }
    )
    core.initialize("app-1", "key", validBaseUrl)
    awaitIdle()

    // Flag is off by default (SEGTEL-10); a session start must not even invoke
    // the country provider (SEGTEL-12 gate).
    core.onAppForegrounded()
    awaitIdle()
    awaitIdle()

    assertEquals(0, providerCalls)
    assertEquals(1, server.requestCount)
    assertFalse(store.getLocationSharingEnabled())
  }

  @Test
  fun `opt-in on with permission granted enqueues a country PATCH at session start`() {
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    val core = newCore(
      hasLocationPermission = { true },
      countryProvider = { cb -> cb("BR") }
    )
    core.initialize("app-1", "key", validBaseUrl)
    awaitIdle()

    // Enabling does not read immediately (SEGTEL-11 read cadence is session start).
    core.setLocationSharingEnabled(true)
    awaitIdle()
    assertEquals(1, server.requestCount)

    core.onAppForegrounded()
    awaitIdle()
    awaitIdle() // country PATCH dispatched from the provider callback

    assertEquals(2, server.requestCount)
    server.takeRequest(5, TimeUnit.SECONDS) // register
    val patch = requireNotNull(server.takeRequest(5, TimeUnit.SECONDS))
    assertEquals("PATCH", patch.method)
    assertEquals("BR", JSONObject(patch.body.readUtf8()).getString("country"))
    assertTrue(store.getLocationSharingEnabled())
  }

  @Test
  fun `opt-in on with no OS location permission never invokes the provider`() {
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    var providerCalls = 0
    val core = newCore(
      hasLocationPermission = { false },
      countryProvider = { cb -> providerCalls++; cb("BR") }
    )
    core.initialize("app-1", "key", validBaseUrl)
    awaitIdle()

    core.setLocationSharingEnabled(true)
    awaitIdle()
    core.onAppForegrounded()
    awaitIdle()
    awaitIdle()

    // Opt-in on but permission not granted: the read is gated before the
    // provider is ever invoked, and no country field is sent (SEGTEL-12) -
    // the SDK never requests permission itself (SEGTEL-14).
    assertEquals(0, providerCalls)
    assertEquals(1, server.requestCount) // registration only
    assertTrue(store.getLocationSharingEnabled())
  }

  @Test
  fun `toggling location sharing off enqueues an explicit country null clear`() {
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    val core = newCore()
    core.initialize("app-1", "key", validBaseUrl)
    awaitIdle()

    core.setLocationSharingEnabled(true)
    awaitIdle()
    assertEquals(1, server.requestCount) // enabling reads nothing

    core.setLocationSharingEnabled(false)
    awaitIdle()

    // Disabling enqueues an immediate {country: null} clear (SEGTEL-13 AC4) -
    // never just stops sending.
    assertEquals(2, server.requestCount)
    server.takeRequest(5, TimeUnit.SECONDS) // register
    val clear = requireNotNull(server.takeRequest(5, TimeUnit.SECONDS))
    assertEquals("PATCH", clear.method)
    assertTrue(JSONObject(clear.body.readUtf8()).isNull("country"))
    assertFalse(store.getLocationSharingEnabled())
  }

  @Test
  fun `opt-in on with a failing country provider omits the field without crashing`() {
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    val core = newCore(
      hasLocationPermission = { true },
      countryProvider = { cb -> cb(null) }
    )
    core.initialize("app-1", "key", validBaseUrl)
    awaitIdle()

    core.setLocationSharingEnabled(true)
    awaitIdle()
    core.onAppForegrounded()
    awaitIdle()
    awaitIdle()

    // No country field anywhere: read failure / revoked permission is treated
    // the same as no permission - omit, no error (SEGTEL-11/14).
    assertEquals(1, server.requestCount)
    assertTrue(store.getLocationSharingEnabled())
  }

  // ---------------------------------------------------------------------
  // Pre-release review fixes (v0.3.0..HEAD)
  // ---------------------------------------------------------------------

  /** Executor whose tasks only run when the test says so - deterministic interleaving. */
  private class ManualExecutor : Executor {
    val tasks = ArrayDeque<Runnable>()
    override fun execute(command: Runnable) { tasks.addLast(command) }
    fun runNext() { tasks.removeFirst().run() }
    fun runAll() { while (tasks.isNotEmpty()) runNext() }
  }

  private fun registerOk() =
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))

  private fun drainRequests(): List<okhttp3.mockwebserver.RecordedRequest> =
    (0 until server.requestCount).map { requireNotNull(server.takeRequest(5, TimeUnit.SECONDS)) }

  @Test
  fun `opting out before initialize still clears country once registration completes`() {
    // A previous launch opted in (and may have synced a country).
    store.setLocationSharingEnabled(true)
    val core = newCore()

    // LGPD: the opt-out lands before initialize() - there is no API client yet.
    core.setLocationSharingEnabled(false)
    assertTrue(store.getPendingCountryClear())

    registerOk()
    registerOk() // the clear PATCH
    core.initialize("app-1", "key", validBaseUrl)
    awaitIdle()
    awaitIdle()

    val requests = drainRequests()
    assertEquals(2, requests.size)
    assertEquals("PATCH", requests[1].method)
    assertTrue(JSONObject(requests[1].body.readUtf8()).isNull("country"))
    assertFalse("flag is dropped only after a 2xx", store.getPendingCountryClear())
  }

  @Test
  fun `a failed country clear stays pending and is re-sent on the next foreground`() {
    registerOk()
    val core = newCore()
    core.initialize("app-1", "key", validBaseUrl)
    awaitIdle()
    core.setLocationSharingEnabled(true)

    repeat(5) { server.enqueue(MockResponse().setResponseCode(503)) } // offline/5xx
    core.setLocationSharingEnabled(false)
    awaitIdle()
    assertEquals(6, server.requestCount)
    assertTrue("a failed clear must stay pending", store.getPendingCountryClear())

    registerOk() // the retried clear PATCH
    core.onAppForegrounded()
    awaitIdle()
    awaitIdle()

    assertEquals(7, server.requestCount)
    val last = drainRequests().last()
    assertEquals("PATCH", last.method)
    assertTrue(JSONObject(last.body.readUtf8()).isNull("country"))
    assertFalse(store.getPendingCountryClear())
  }

  @Test
  fun `opting out without ever having opted in sends no clear PATCH`() {
    registerOk()
    val core = newCore()
    core.initialize("app-1", "key", validBaseUrl)
    awaitIdle()

    core.setLocationSharingEnabled(false)
    awaitIdle()
    core.onAppForegrounded()
    awaitIdle()

    assertEquals(1, server.requestCount) // registration only
    assertFalse(store.getPendingCountryClear())
  }

  @Test
  fun `a country read queued before registration is never sent if the user opts out first`() {
    val manual = ManualExecutor()
    var tokenCallback: ((String?) -> Unit)? = null
    val core = newCore(
      coreExecutor = manual,
      tokenProvider = { cb -> tokenCallback = cb },
      hasLocationPermission = { true },
      countryProvider = { cb -> cb("BR") }
    )
    core.initialize("app-1", "key", validBaseUrl)
    core.setLocationSharingEnabled(true)
    core.onAppForegrounded()
    manual.runAll() // geocode resolved -> country PATCH queued (not registered yet)

    core.setLocationSharingEnabled(false) // opt-out lands while BR is still queued
    manual.runAll()

    repeat(3) { registerOk() }
    requireNotNull(tokenCallback).invoke("fcm-token")
    manual.runAll()

    val bodies = drainRequests().drop(1).map { JSONObject(it.body.readUtf8()) }
    assertTrue("BR must never reach the server after opt-out: $bodies",
      bodies.none { it.optString("country") == "BR" })
    assertTrue(bodies.any { it.has("country") && it.isNull("country") })
  }

  @Test
  fun `an unchanged country is not re-sent on every foreground`() {
    repeat(12) { registerOk() }
    val core = newCore(hasLocationPermission = { true }, countryProvider = { cb -> cb("BR") })
    core.initialize("app-1", "key", validBaseUrl)
    awaitIdle()
    core.setLocationSharingEnabled(true)

    repeat(3) {
      core.onAppForegrounded()
      awaitIdle(); awaitIdle()
      core.onAppBackgrounded()
      awaitIdle(); awaitIdle()
    }

    val countryPatches = drainRequests().filter {
      it.method == "PATCH" && JSONObject(it.body.readUtf8()).has("country")
    }
    assertEquals(1, countryPatches.size)
  }

  @Test
  fun `a second foreground signal for the same process session does not open a second session`() {
    val core = newCore(clock = { 1_000L })

    core.onAppForegrounded()
    awaitIdle()
    // Cold start: the module-creation sync and the lifecycle observer can both
    // report the same foreground - only one session may result.
    core.onAppForegrounded()
    awaitIdle()

    assertEquals(0, store.getSessionCount())
    assertEquals(1_000L, store.getSessionStartedAtMs())
  }

  // ---------------------------------------------------------------------
  // Final review fixes (A-F)
  // ---------------------------------------------------------------------

  @Test
  fun `re-consent after a clear whose ack was lost forgets the synced country so it is re-sent`() {
    // State left by: opt-in, BR synced, opt-out whose clear reached the server
    // but whose 2xx never came back - clear still pending, lastSynced still BR.
    store.setLocationSharingEnabled(false)
    store.setPendingCountryClear(true)
    store.setLastSyncedCountry("BR")
    repeat(4) { registerOk() }
    val core = newCore(hasLocationPermission = { true }, countryProvider = { cb -> cb("BR") })

    core.setLocationSharingEnabled(true)

    assertFalse(store.getPendingCountryClear())
    assertNull("re-consent must forget the synced value (iOS parity)", store.getLastSyncedCountry())

    core.initialize("app-1", "key", validBaseUrl)
    awaitIdle()
    core.onAppForegrounded()
    awaitIdle(); awaitIdle()

    val countryBodies = drainRequests().filter { it.method == "PATCH" }
      .map { JSONObject(it.body.readUtf8()) }.filter { it.has("country") }
    assertEquals(listOf("BR"), countryBodies.map { it.optString("country") })
    assertEquals("BR", store.getLastSyncedCountry())
  }

  @Test
  fun `re-enabling while already enabled does not drop the synced country`() {
    store.setLocationSharingEnabled(true)
    store.setLastSyncedCountry("BR")
    val core = newCore()

    core.setLocationSharingEnabled(true)

    assertEquals("BR", store.getLastSyncedCountry())
  }

  @Test
  fun `a pending country clear runs before queued mutations on registration and is sent exactly once`() {
    var tokenCallback: ((String?) -> Unit)? = null
    val core = newCore(tokenProvider = { cb -> tokenCallback = cb })
    core.initialize("app-1", "key", validBaseUrl)
    core.setLocationSharingEnabled(true)
    core.login("u1")
    core.addTagsForTest()
    core.setLocationSharingEnabled(false) // clear owed, queued behind login/tags
    awaitIdle()
    assertTrue(store.getPendingCountryClear())

    registerOk()
    repeat(5) { server.enqueue(MockResponse().setResponseCode(204)) }
    requireNotNull(tokenCallback).invoke("fcm-token")
    awaitIdle()

    val bodies = drainRequests().drop(1).map { JSONObject(it.body.readUtf8()) }
    val clears = bodies.filter { it.has("country") && it.isNull("country") }
    assertEquals("clear sent exactly once: $bodies", 1, clears.size)
    assertTrue("LGPD clear must go first: $bodies", bodies.first().let { it.has("country") && it.isNull("country") })
    assertTrue(bodies.any { it.optString("external_user_id") == "u1" })
    assertFalse(store.getPendingCountryClear())
  }

  private fun NottiCore.addTagsForTest() = mutateTags(add = mapOf("k" to "v"), remove = null)

  @Test
  fun `a country clear rejected with a permanent 4xx logs distinctly and stays pending`() {
    registerOk()
    val logs = mutableListOf<String>()
    val core = newCore(logs = logs)
    core.initialize("app-1", "key", validBaseUrl)
    awaitIdle()
    core.setLocationSharingEnabled(true)

    server.enqueue(MockResponse().setResponseCode(403))
    core.setLocationSharingEnabled(false)
    awaitIdle()

    assertEquals("4xx is not retried in-call", 2, server.requestCount)
    assertTrue(store.getPendingCountryClear())
    val rejected = logs.filter { it.contains("clear PATCH rejected permanently") }
    assertEquals(logs.toString(), 1, rejected.size)
    assertTrue(rejected.single().contains("HTTP 403"))

    // Still re-sent on the next trigger.
    registerOk()
    core.onAppForegrounded()
    awaitIdle(); awaitIdle()
    assertEquals(3, server.requestCount)
    assertFalse(store.getPendingCountryClear())
  }

  @Test
  fun `a transient clear failure keeps the generic log, not the permanent-4xx one`() {
    registerOk()
    val logs = mutableListOf<String>()
    val core = newCore(logs = logs)
    core.initialize("app-1", "key", validBaseUrl)
    awaitIdle()
    core.setLocationSharingEnabled(true)

    repeat(5) { server.enqueue(MockResponse().setResponseCode(503)) }
    core.setLocationSharingEnabled(false)
    awaitIdle()

    assertTrue(logs.none { it.contains("rejected permanently") })
    assertTrue(logs.any { it.contains("clear PATCH failed") })
  }

  @Test
  fun `a session gate opened while the executor is shut down is closed again`() {
    val gate = NottiCore.SessionGate()
    val dead = Executors.newSingleThreadExecutor().apply { shutdown() }
    val core = newCore(coreExecutor = dead, sessionGate = gate)

    core.onAppForegrounded()

    assertFalse("rejected session start must not leave the gate open", gate.isActive)
  }

  @Test
  fun `RN reload - a second core sharing the process gate does not open a second session`() {
    val gate = NottiCore.SessionGate()
    val coreA = newCore(clock = { 1_000L }, sessionGate = gate)
    coreA.onAppForegrounded()
    awaitIdle()

    // Reload while foregrounded: core A is invalidated, core B is created and
    // replays the (still current) foreground.
    val coreB = newCore(clock = { 9_000L }, sessionGate = gate)
    NottiForegroundObserver.syncWithCurrentState(coreB) { true }
    awaitIdle()

    assertEquals(0, store.getSessionCount())
    assertEquals(1_000L, store.getSessionStartedAtMs())
  }

  @Test
  fun `RN reload - background with no live core closes the process gate so the next foreground opens a session`() {
    val gate = NottiCore.SessionGate()
    var now = 1_000L
    val coreA = newCore(clock = { now }, sessionGate = gate)
    coreA.onAppForegrounded()
    awaitIdle()
    coreA.recordForegroundHeartbeatAt(21_000L)

    // Core A invalidated by a reload; the user backgrounds before core B exists.
    NottiForegroundObserver.handleProcessBackground(core = null, gate = gate)
    assertFalse(gate.isActive)

    // Much later the app returns; core B is created and replays the foreground.
    now = 500_000L
    val coreB = newCore(clock = { now }, sessionGate = gate)
    NottiForegroundObserver.syncWithCurrentState(coreB) { true }
    awaitIdle()

    // The orphaned session from core A is closed at its last heartbeat (no
    // background time counted) and a new one is open.
    assertEquals(1, store.getSessionCount())
    assertEquals(20_000L, store.getSessionTimeMs())
    assertEquals(500_000L, store.getSessionStartedAtMs())
  }

  @Test
  fun `foreground sync on core creation starts the cold-start session when the process is already started`() {
    val core = newCore(clock = { 5_000L })

    NottiForegroundObserver.syncWithCurrentState(core) { true }
    awaitIdle()

    assertEquals(5_000L, store.getSessionStartedAtMs())
  }

  @Test
  fun `foreground sync on core creation does nothing when the process is not started`() {
    val core = newCore(clock = { 5_000L })

    NottiForegroundObserver.syncWithCurrentState(core) { false }
    awaitIdle()

    assertNull(store.getSessionStartedAtMs())
  }

  @Test
  fun `session start and end use the timestamp captured at the lifecycle callback, on the executor`() {
    var now = 1_000L
    val manual = ManualExecutor()
    val core = newCore(coreExecutor = manual, clock = { now })

    core.onAppForegrounded()
    assertNull("session start must not touch the store on the caller (main) thread", store.getSessionStartedAtMs())
    now = 31_000L
    core.onAppBackgrounded()
    now = 999_000L // executor runs late - must not leak into the session

    manual.runAll()

    assertEquals(1, store.getSessionCount())
    assertEquals(30_000L, store.getSessionTimeMs())
    assertEquals(31_000L, store.getLastSessionAtMs())
  }

  @Test
  fun `flush stops at the first transient failure instead of burning retries on every event`() {
    val eventStore = NottiEventStore(prefs)
    repeat(3) { eventStore.enqueue("n-$it", "d-$it", "clicked") }
    val core = newCore(eventStore = eventStore)
    registerOk()
    // Enough 503s for the old (buggy) behavior too, so it fails instead of hanging.
    repeat(15) { server.enqueue(MockResponse().setResponseCode(503)) }

    core.initialize("app-1", "key", validBaseUrl)
    awaitIdle()

    assertEquals("1 register + 5 attempts for the first event only", 6, server.requestCount)
    assertEquals(3, eventStore.all().size)
  }

  @Test
  fun `repeated flush triggers while one is pending are coalesced into a single flush`() {
    val eventStore = NottiEventStore(prefs)
    val core = newCore(eventStore = eventStore)
    registerOk()
    core.initialize("app-1", "key", validBaseUrl)
    awaitIdle()
    eventStore.enqueue("n-1", "d-1", "clicked")
    repeat(25) { server.enqueue(MockResponse().setResponseCode(503)) }

    val gate = CountDownLatch(1)
    executor.execute { gate.await(5, TimeUnit.SECONDS) }
    repeat(5) { core.onNetworkAvailable() }
    gate.countDown()
    awaitIdle()

    assertEquals("one flush (5 attempts) after the registration POST", 6, server.requestCount)
  }

  @Test
  fun `repeated country-clear retry triggers while one is pending are coalesced into a single attempt`() {
    // M5 (pre-release review round 3): without a dedup guard on
    // `retryPendingCountryClear` (unlike `scheduleFlush`'s existing one),
    // every `onNetworkAvailable()` call queued its own clear-retry task, so a
    // persistent 4xx or a flapping connection could stack N tasks on the
    // single-thread executor, each burning up to 5 attempts.
    val core = newCore()
    registerOk()
    core.initialize("app-1", "key", validBaseUrl)
    awaitIdle()
    drainRequests()

    // Arm the obligation directly on the store (not via
    // `setLocationSharingEnabled`, which would dispatch its own immediate
    // attempt ahead of the blocked-executor setup below).
    store.setPendingCountryClear(true)
    repeat(25) { server.enqueue(MockResponse().setResponseCode(503)) }

    val gate = CountDownLatch(1)
    executor.execute { gate.await(5, TimeUnit.SECONDS) }
    repeat(5) { core.onNetworkAvailable() }
    gate.countDown()
    awaitIdle()

    assertEquals(
      "1 register + one country-clear attempt (5 retries) despite 5 trigger calls while one was pending",
      6,
      server.requestCount
    )
  }

  @Test
  fun `telemetry never evicts queued login or tag mutations and is coalesced per key`() {
    var tokenCallback: ((String?) -> Unit)? = null
    val core = newCore(tokenProvider = { cb -> tokenCallback = cb })
    core.initialize("app-1", "key", validBaseUrl)

    repeat(32) { core.login("user-$it") }
    for (i in 0 until 5) {
      core.handleSessionStart(i * 10_000L)
      core.handleSessionEnd(i * 10_000L + 1_000L)
    }
    awaitIdle()

    registerOk()
    repeat(33) { server.enqueue(MockResponse().setResponseCode(204)) }
    requireNotNull(tokenCallback).invoke("fcm-token")
    awaitIdle()

    val bodies = drainRequests().drop(1).map { JSONObject(it.body.readUtf8()) }
    assertEquals((0 until 32).map { "user-$it" }, bodies.filter { it.has("external_user_id") }.map { it.getString("external_user_id") })
    val sessions = bodies.filter { it.has("session_count") }
    assertEquals("session snapshots coalesce to the latest", 1, sessions.size)
    assertEquals(5, sessions.single().getInt("session_count"))
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
    awaitIdle()

    // Exactly one registration POST (no re-registration). Repeated foreground
    // signals with no background in between are the same process session
    // (session gate), so they also produce no orphan-close session PATCHes.
    assertEquals(1, server.requestCount)
    assertEquals("POST", requireNotNull(server.takeRequest(5, TimeUnit.SECONDS)).method)
    assertEquals(0, store.getSessionCount())
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
    // is still in flight must produce no further *registration* attempts -
    // otherwise every foreground stacks another registration call. With no
    // background in between they are also the same session (session gate).
    repeat(4) { core.onAppForegrounded() }
    releaseRetry.countDown()
    awaitIdle()
    awaitIdle()

    assertEquals(2, server.requestCount)
    val methods = (0 until 2).map { requireNotNull(server.takeRequest(5, TimeUnit.SECONDS)).method }
    // Exactly two registration POSTs (first attempt + one retry) - no stacking.
    assertEquals(2, methods.count { it == "POST" })
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
    awaitIdle()

    assertEquals(3, tokenRequests)
    // One registration POST (the retry still fires despite the wedged fetch).
    // The repeated foreground is the same process session (session gate), so
    // no orphan-close session PATCH is produced.
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

  @Test
  fun `flushEventQueue with apiClient == null does not crash and makes no calls`() {
    val eventStore = NottiEventStore(prefs)
    val core = newCore(eventStore = eventStore)
    val queued = eventStore.enqueue("notification-1", "delivery-1", "received")

    // No initialize(): the API client is never built, so the flush must be a
    // safe no-op rather than a crash on the executor.
    core.onAppForegrounded()
    awaitIdle()

    assertEquals(0, server.requestCount)
    assertEquals(listOf(queued), eventStore.all())
  }

  @Test
  fun `registration success flushes a queued event and removes it`() {
    val eventStore = NottiEventStore(prefs)
    eventStore.enqueue("notification-1", "delivery-1", "received")
    val core = newCore(eventStore = eventStore)
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    server.enqueue(MockResponse().setResponseCode(200))

    core.initialize("app-1", "key", validBaseUrl)
    awaitIdle()

    val register = requireNotNull(server.takeRequest(5, TimeUnit.SECONDS))
    assertEquals("/v1/apps/app-1/devices", register.path)
    val report = requireNotNull(server.takeRequest(5, TimeUnit.SECONDS))
    assertEquals("POST", report.method)
    assertEquals("/v1/apps/app-1/notifications/notification-1/events", report.path)
    assertTrue(eventStore.all().isEmpty())
  }

  @Test
  fun `flushEventQueue keeps the event when reportEvent fails`() {
    val eventStore = NottiEventStore(prefs)
    val queued = eventStore.enqueue("notification-1", "delivery-1", "received")
    val core = newCore(eventStore = eventStore)
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    // reportEvent burns its full retry cap (5 attempts) before returning
    // Failure; the event must stay queued for a later flush, not be dropped.
    repeat(5) { server.enqueue(MockResponse().setResponseCode(500)) }

    core.initialize("app-1", "key", validBaseUrl)
    awaitIdle()

    assertEquals(listOf(queued), eventStore.all())
  }

  @Test
  fun `onAppForegrounded flushes the event queue even when already REGISTERED`() {
    val eventStore = NottiEventStore(prefs)
    val core = newCore(eventStore = eventStore)
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    core.initialize("app-1", "key", validBaseUrl)
    awaitIdle()

    // A new event lands after registration; a later foreground must still
    // flush it even though the registration-state guard would otherwise
    // early-return for an already-registered device.
    eventStore.enqueue("notification-1", "delivery-1", "clicked")
    server.enqueue(MockResponse().setResponseCode(200))

    core.onAppForegrounded()
    awaitIdle()

    val register = requireNotNull(server.takeRequest(5, TimeUnit.SECONDS))
    assertEquals("/v1/apps/app-1/devices", register.path)
    val report = requireNotNull(server.takeRequest(5, TimeUnit.SECONDS))
    assertEquals("POST", report.method)
    assertEquals("/v1/apps/app-1/notifications/notification-1/events", report.path)
    assertTrue(eventStore.all().isEmpty())
  }

  @Test
  fun `flushEventQueue drops the event on a terminal 4xx report`() {
    val eventStore = NottiEventStore(prefs)
    eventStore.enqueue("notification-1", "delivery-1", "received")
    val core = newCore(eventStore = eventStore)
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    // A 403 (e.g. stale/mismatched token per spec SDKCTR-11) is terminal: the
    // backend will never accept it, so the event must be dropped, not left to
    // re-fail forever on every flush trigger.
    server.enqueue(MockResponse().setResponseCode(403))

    core.initialize("app-1", "key", validBaseUrl)
    awaitIdle()

    assertTrue("a terminal 4xx must remove the event from the queue", eventStore.all().isEmpty())
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
