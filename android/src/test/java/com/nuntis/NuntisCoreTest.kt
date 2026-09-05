package com.nuntis

import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.util.concurrent.TimeUnit

class NuntisCoreTest {

  private lateinit var server: MockWebServer
  private lateinit var store: NuntisDeviceStore
  private lateinit var prefs: FakePrefsForCore

  @Before
  fun setUp() {
    server = MockWebServer()
    server.start()
    prefs = FakePrefsForCore()
    store = NuntisDeviceStore(prefs)
  }

  /** The mock server's own URL - the only `baseUrl` that actually reaches it in these tests. */
  private val validBaseUrl: String
    get() = server.url("/").toString().trimEnd('/')

  @After
  fun tearDown() {
    server.shutdown()
  }

  private fun newCore(
    tokenProvider: () -> String? = { "fcm-token" },
    permissionRequester: (callback: (Boolean) -> Unit) -> Unit = { it(true) },
    logs: MutableList<String>? = null
  ) = NuntisCore(
    deviceStore = store,
    apiClientFactory = { appId, clientKey, baseUrl ->
      NuntisApiClient(
        httpClient = OkHttpClient(),
        baseUrl = baseUrl,
        appId = appId,
        clientKey = clientKey,
        sleeper = { }
      )
    },
    tokenProvider = tokenProvider,
    permissionRequester = permissionRequester,
    logger = { logs?.add(it) }
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
  fun `initialize with no available push token logs and does not register`() {
    val logs = mutableListOf<String>()
    val core = newCore(tokenProvider = { null }, logs = logs)

    core.initialize("app-1", "key", validBaseUrl)

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

    assertEquals(1, server.requestCount)
  }

  @Test
  fun `onTokenRefreshed re-registers with the new token`() {
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    val core = newCore()
    core.initialize("app-1", "key", validBaseUrl)

    core.onTokenRefreshed("new-fcm-token")

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

    var callbackResult: Boolean? = null
    core.requestPermission { granted -> callbackResult = granted }

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

    core.requestPermission { }

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
  fun `two rapid tag mutations serialize and converge to the correct net merged result`() {
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":"device-1","tags":{}}"""))
    val core = newCore()
    core.initialize("app-1", "key", validBaseUrl)

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

    assertEquals(3, server.requestCount)
    assertEquals(mapOf("cohort" to "beta"), store.getTags())
  }
}

/** Same in-memory SharedPreferences fake used by NuntisDeviceStoreTest. */
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
