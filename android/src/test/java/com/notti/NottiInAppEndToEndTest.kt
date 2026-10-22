package com.notti

import android.content.Context
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executor

/**
 * The real core, parser, stores and coordinator wired through the same hooks
 * production uses, against a fake backend. Everything runs on the test
 * thread (direct executors, direct main hop); only the presenter is fake.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class NottiInAppEndToEndTest {

  private val appId = "app-1"
  private val clientKey = "client-key-secret"
  private val token = "fcm-token-secret"
  private val deviceId = "00000000-0000-0000-0000-0000000000d1"

  private lateinit var server: MockWebServer
  private lateinit var baseUrl: String
  private lateinit var deviceStore: NottiDeviceStore
  private lateinit var pushEvents: NottiEventStore
  private lateinit var coordinator: NottiInAppCoordinator
  private lateinit var core: NottiCore
  private val requests = CopyOnWriteArrayList<RecordedRequest>()
  private val logs = CopyOnWriteArrayList<String>()
  private var eligibleBody = """{"messages":[]}"""

  private class Presenter : InAppPresenter {
    val presented = mutableListOf<InAppDisplay>()
    val closed = mutableListOf<String>()
    override fun present(display: InAppDisplay) {
      presented.add(display)
    }
    override fun close(displayId: String) {
      closed.add(displayId)
    }
    override fun teardown(display: InAppDisplay) = Unit
  }

  private val presenter = Presenter()

  @Before
  fun setUp() {
    server = MockWebServer()
    server.dispatcher = object : Dispatcher() {
      override fun dispatch(request: RecordedRequest): MockResponse {
        requests.add(request)
        val path = request.path.orEmpty()
        return when {
          path.endsWith("/in-app-messages/eligible") -> MockResponse().setResponseCode(200).setBody(eligibleBody)
          path.contains("/in-app-messages/") -> MockResponse().setResponseCode(201).setBody("""{"duplicate":false}""")
          path.contains("/notifications/") -> MockResponse().setResponseCode(201).setBody("{}")
          else -> MockResponse().setResponseCode(200).setBody("""{"id":"$deviceId","tags":{}}""")
        }
      }
    }
    server.start()
    baseUrl = server.url("/").toString().trimEnd('/')

    val prefs = RuntimeEnvironment.getApplication().getSharedPreferences("notti_e2e", Context.MODE_PRIVATE)
    prefs.edit().clear().commit()
    deviceStore = NottiDeviceStore(prefs)
    pushEvents = NottiEventStore(prefs)
    coordinator = NottiInAppCoordinator(
      store = NottiInAppEventStore(prefs),
      clientFactory = { config -> NottiApiClient(OkHttpClient(), config.baseUrl, config.appId, config.clientKey) },
      identity = {
        val id = deviceStore.getDeviceId()
        val lastToken = deviceStore.getLastToken()
        if (id != null && lastToken != null) InAppIdentity(id, lastToken) else null
      },
      executor = object : InAppExecutor {
        override fun execute(task: () -> Unit) = task()
        override fun schedule(delayMs: Long, task: () -> Unit) = Unit
      },
      postToMain = { it() },
      logger = { logs.add(it) }
    )
    coordinator.presenter = presenter
    coordinator.clickSink = InAppClickSink { true }
    core = NottiCore(
      deviceStore = deviceStore,
      eventStore = pushEvents,
      apiClientFactory = { id, key, url -> NottiApiClient(OkHttpClient(), url, id, key, sleeper = { }) },
      tokenProvider = { it(token) },
      permissionRequester = { it(true) },
      logger = { logs.add(it) },
      executor = Executor { it.run() },
      inApp = object : NottiInAppHooks {
        override fun onSessionStarted() = coordinator.onSessionStarted()
        override fun onRegistered() = coordinator.onRegistered()
      }
    )
  }

  @After
  fun tearDown() {
    server.shutdown()
  }

  private fun sessionStart(id: String) = """{"id":"$id","title":"T","trigger":{"type":"session_start"}}"""
  private fun onEvent(id: String, name: String) = """{"id":"$id","title":"T","trigger":{"type":"event","name":"$name"}}"""
  private fun messages(vararg entries: String) = """{"messages":[${entries.joinToString(",")}]}"""

  /** `initialize` as the module runs it: In-App first, then the core (whose creation replays the foreground). */
  private fun initializeAndForeground() {
    coordinator.onInitialized(appId, clientKey, baseUrl)
    core.initialize(appId, clientKey, baseUrl)
    core.onAppForegrounded()
  }

  private fun showVisible(display: InAppDisplay) {
    coordinator.onDisplayAttached(display.displayId, true)
    coordinator.onDisplayVisible(display.displayId)
  }

  private fun inAppEvents(): List<JSONObject> =
    requests.filter { it.path!!.contains("/in-app-messages/") && it.path!!.endsWith("/events") }
      .map { JSONObject(it.body.clone().readUtf8()) }

  @Test
  fun `a session runs registration, flush, one eligible, display, impression, click and a held trigger in order`() {
    pushEvents.enqueue("n-1", "d-1", "clicked")
    eligibleBody = messages(sessionStart("s1"), onEvent("e1", "promo"))

    initializeAndForeground()

    val paths = requests.map { it.method + " " + it.path!!.substringAfter("/v1/apps/$appId") }
    val register = paths.indexOfFirst { it.startsWith("POST /devices") }
    val pushFlush = paths.indexOfFirst { it.contains("/notifications/") }
    val eligible = paths.indexOf("POST /in-app-messages/eligible")
    assertTrue(paths.toString(), register in 0 until pushFlush)
    assertTrue(paths.toString(), pushFlush < eligible)
    assertEquals(1, paths.count { it == "POST /in-app-messages/eligible" })

    val first = presenter.presented.single()
    assertEquals("s1", first.message.id)
    showVisible(first)
    coordinator.onDisplayClicked(first.displayId, "b1", null)
    assertEquals(listOf(first.displayId), presenter.closed)

    coordinator.trackEvent("promo")
    assertEquals(listOf("s1", "e1"), presenter.presented.map { it.message.id })

    // A second registration or foreground in the same session does not refetch.
    coordinator.onRegistered()
    core.onAppForegrounded()
    assertEquals(1, requests.count { it.path!!.endsWith("/in-app-messages/eligible") })

    val events = inAppEvents()
    assertEquals(listOf("impression", "click"), events.map { it.getString("type") })
    assertEquals(2, events.map { it.getString("event_id") }.toSet().size)

    // In-App never touches the device record (SDKIAM-53).
    val afterEligible = requests.drop(requests.indexOfFirst { it.path!!.endsWith("/eligible") })
    assertFalse(afterEligible.any { it.method == "PATCH" && it.path!!.contains("/devices") })

    // No secret, id or event name in any log line (SDKIAM-54).
    val secrets = listOf(clientKey, token, deviceId, "s1\"", "e1\"", "promo", baseUrl)
    for (line in logs) for (secret in secrets) assertFalse("$line leaks $secret", line.contains(secret))
  }

  @Test
  fun `a trackEvent right after initialize, before the first session, shows the held message once fetched`() {
    eligibleBody = messages(onEvent("e1", "promo"))

    coordinator.onInitialized(appId, clientKey, baseUrl)
    coordinator.trackEvent("promo")
    core.initialize(appId, clientKey, baseUrl)
    core.onAppForegrounded()

    assertEquals(listOf("e1"), presenter.presented.map { it.message.id })
  }

  @Test
  fun `a trackEvent before initialize is not remembered`() {
    eligibleBody = messages(onEvent("e1", "promo"))

    coordinator.trackEvent("promo")
    initializeAndForeground()

    assertTrue(presenter.presented.isEmpty())
  }
}
