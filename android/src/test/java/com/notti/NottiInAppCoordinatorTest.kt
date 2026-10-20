package com.notti

import android.content.Context
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.QueueDispatcher
import okhttp3.mockwebserver.RecordedRequest
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import java.util.concurrent.TimeUnit

/** Runs work on the test thread; scheduled tasks run when virtual time reaches them. */
private class FakeInAppExecutor(private val time: () -> Long, private val setTime: (Long) -> Unit) : InAppExecutor {
  private val immediate = ArrayDeque<() -> Unit>()
  private val scheduled = mutableListOf<Pair<Long, () -> Unit>>()
  val delays = mutableListOf<Long>()

  override fun execute(task: () -> Unit) {
    immediate.addLast(task)
  }

  override fun schedule(delayMs: Long, task: () -> Unit) {
    delays.add(delayMs)
    scheduled.add(time() + delayMs to task)
  }

  fun runAll() {
    while (immediate.isNotEmpty()) immediate.removeFirst()()
  }

  fun advance(ms: Long) {
    val target = time() + ms
    runAll()
    while (true) {
      val next = scheduled.filter { it.first <= target }.minByOrNull { it.first } ?: break
      scheduled.remove(next)
      setTime(next.first)
      next.second()
      runAll()
    }
    setTime(target)
  }
}

private class FakePresenter : InAppPresenter {
  val presented = mutableListOf<InAppDisplay>()
  val closed = mutableListOf<String>()
  val tornDown = mutableListOf<InAppDisplay>()

  override fun present(display: InAppDisplay) {
    presented.add(display)
  }

  override fun close(displayId: String) {
    closed.add(displayId)
  }

  override fun teardown(display: InAppDisplay) {
    tornDown.add(display)
  }
}

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class NottiInAppCoordinatorTest {

  private val deviceId = "00000000-0000-0000-0000-0000000000d1"
  private val token = "fcm-token-secret"
  private val clientKey = "client-key-secret"

  private lateinit var server: MockWebServer
  private lateinit var store: NottiInAppEventStore
  private lateinit var executor: FakeInAppExecutor
  private lateinit var presenter: FakePresenter
  private lateinit var coordinator: NottiInAppCoordinator
  private val logs = mutableListOf<String>()
  private val clicks = mutableListOf<InAppClick>()
  private var monotonic = 0L
  private var wall = 1_760_000_000_000L
  private var identity: InAppIdentity? = InAppIdentity(deviceId, token)
  private lateinit var baseUrl: String

  @Before
  fun setUp() {
    server = MockWebServer()
    // An unexpected request gets a 404 at once instead of hanging until the timeout.
    server.dispatcher = QueueDispatcher().apply { setFailFast(true) }
    server.start()
    consumed = 0
    baseUrl = server.url("/").toString().trimEnd('/')
    val prefs = RuntimeEnvironment.getApplication().getSharedPreferences("notti_prefs", Context.MODE_PRIVATE)
    prefs.edit().clear().commit()
    store = NottiInAppEventStore(prefs, clock = { wall })
    executor = FakeInAppExecutor({ monotonic }, { monotonic = it })
    presenter = FakePresenter()
    coordinator = NottiInAppCoordinator(
      store = store,
      clientFactory = { config -> NottiApiClient(OkHttpClient(), config.baseUrl, config.appId, config.clientKey) },
      identity = { identity },
      executor = executor,
      postToMain = { it() },
      monotonicMs = { monotonic },
      logger = { logs.add(it) }
    )
    coordinator.presenter = presenter
    coordinator.clickSink = InAppClickSink { clicks.add(it); true }
  }

  @After
  fun tearDown() {
    server.shutdown()
    NottiInApp.resetForTests()
  }

  // Helpers

  private fun sessionStart(id: String, extra: String = "") =
    """{"id":"$id","title":"T","trigger":{"type":"session_start"}$extra}"""

  private fun eventMessage(id: String, name: String) =
    """{"id":"$id","title":"T","trigger":{"type":"event","name":"$name"}}"""

  private fun messages(vararg entries: String) =
    MockResponse().setResponseCode(200).setBody("""{"messages":[${entries.joinToString(",")}]}""")

  private fun status(code: Int, retryAfter: String? = null) =
    MockResponse().setResponseCode(code).setBody("{}").apply { if (retryAfter != null) setHeader("Retry-After", retryAfter) }

  private fun take(): RecordedRequest = requireNotNull(server.takeRequest(5, TimeUnit.SECONDS))

  private fun takeAll(): List<RecordedRequest> = (0 until server.requestCount - consumed).map { take() }.also { consumed += it.size }

  private var consumed = 0

  private fun init(appId: String = "app-1") {
    coordinator.onInitialized(appId, clientKey, baseUrl)
  }

  private fun startAndRegister() {
    coordinator.onSessionStarted()
    executor.runAll()
  }

  private fun restart() {
    server.shutdown()
    setUp()
  }

  private fun paths(requests: List<RecordedRequest>) = requests.map { it.path!! }

  private fun queuedEvent(messageId: String = "old", appId: String = "app-1"): InAppPendingEvent =
    store.enqueue(appId, messageId, InAppEventType.IMPRESSION)

  private fun eligiblePath(appId: String = "app-1") = "/v1/apps/$appId/in-app-messages/eligible"
  private fun eventsPath(messageId: String, appId: String = "app-1") = "/v1/apps/$appId/in-app-messages/$messageId/events"

  private fun showVisible(): InAppDisplay {
    val display = presenter.presented.last()
    coordinator.onDisplayAttached(display.displayId, true)
    coordinator.onDisplayVisible(display.displayId)
    return display
  }

  // Fetch sequence

  @Test
  fun `queued events are flushed before eligible and the first session_start is presented`() {
    queuedEvent()
    server.enqueue(status(201))
    server.enqueue(messages(sessionStart("s1"), sessionStart("s2")))
    init()
    startAndRegister()

    assertEquals(listOf(eventsPath("old"), eligiblePath()), paths(takeAll()))
    assertEquals(listOf("s1"), presenter.presented.map { it.message.id })
    assertTrue(store.all().isEmpty())
  }

  @Test
  fun `eligible is sent once per session across registrations, reloads and track calls`() {
    server.enqueue(messages())
    init()
    startAndRegister()
    coordinator.onRegistered()
    init()
    coordinator.onRegistered()
    coordinator.trackEvent("x")
    executor.runAll()
    assertEquals(listOf(eligiblePath()), paths(takeAll()))
  }

  @Test
  fun `a new session fetches again`() {
    server.enqueue(messages())
    server.enqueue(messages())
    init()
    startAndRegister()
    coordinator.onSessionEnded()
    coordinator.onSessionStarted()
    executor.runAll()
    assertEquals(listOf(eligiblePath(), eligiblePath()), paths(takeAll()))
  }

  @Test
  fun `null identity defers the fetch to the next trigger`() {
    identity = null
    init()
    startAndRegister()
    assertEquals(0, server.requestCount)
    identity = InAppIdentity(deviceId, token)
    server.enqueue(messages())
    coordinator.onRegistered()
    executor.runAll()
    assertEquals(listOf(eligiblePath()), paths(takeAll()))
  }

  @Test
  fun `eligible is still sent when the pre-fetch flush fails with 503, 429 or 403`() {
    for (code in listOf(503, 429, 403)) {
      restart()
      queuedEvent()
      queuedEvent("second")
      server.enqueue(status(code))
      server.enqueue(messages())
      init()
      startAndRegister()
      val requests = paths(takeAll())
      assertEquals("status $code", listOf(eventsPath("old"), eligiblePath()), requests)
      assertEquals(2, store.all().size)
    }
  }

  @Test
  fun `401 in the pre-fetch flush skips eligible and stops the session`() {
    queuedEvent()
    server.enqueue(status(401))
    init()
    startAndRegister()
    assertEquals(listOf(eventsPath("old")), paths(takeAll()))
    assertTrue(coordinator.session.keyRejected)
    assertEquals(InAppFetchState.GaveUp(false), coordinator.session.fetch)
    coordinator.onNetworkAvailable()
    executor.runAll()
    assertEquals(1, server.requestCount)
    assertTrue(logs.contains("Notti.inapp: events failed (HTTP 401)"))
    assertFalse(logs.contains(NottiInAppCoordinator.INACTIVE_WARNING))
    assertEquals(1, store.all().size)
  }

  // eligible failures

  @Test
  fun `eligible 429 above 60 seconds gives up with no wait and no second request`() {
    server.enqueue(status(429, "120"))
    init()
    startAndRegister()
    executor.advance(600_000)
    assertEquals(1, server.requestCount)
    assertEquals(InAppFetchState.GaveUp(false), coordinator.session.fetch)
    assertTrue(executor.delays.isEmpty())
  }

  @Test
  fun `eligible 429 with Retry-After 2 retries after 2 seconds`() {
    server.enqueue(status(429, "2"))
    server.enqueue(messages(sessionStart("s1")))
    init()
    startAndRegister()
    executor.advance(1_999)
    assertEquals(1, server.requestCount)
    executor.advance(1)
    assertEquals(2, server.requestCount)
    assertEquals(listOf("s1"), presenter.presented.map { it.message.id })
  }

  @Test
  fun `eligible 429 without Retry-After waits 60 seconds, 0 waits 1 second`() {
    server.enqueue(status(429))
    server.enqueue(status(429, "0"))
    server.enqueue(messages())
    init()
    startAndRegister()
    executor.advance(59_999)
    assertEquals(1, server.requestCount)
    executor.advance(1)
    assertEquals(2, server.requestCount)
    executor.advance(1_000)
    assertEquals(3, server.requestCount)
    assertEquals(listOf(60_000L, 1_000L), executor.delays)
  }

  @Test
  fun `eligible 429 gives up after 3 waits`() {
    repeat(4) { server.enqueue(status(429, "1")) }
    server.enqueue(messages())
    init()
    startAndRegister()
    executor.advance(60_000)
    assertEquals(4, server.requestCount)
    assertEquals(InAppFetchState.GaveUp(false), coordinator.session.fetch)
    coordinator.onNetworkAvailable()
    executor.runAll()
    assertEquals(4, server.requestCount)
  }

  @Test
  fun `eligible transient failures back off 2 4 8 16 then give up, resumed on network`() {
    repeat(5) { server.enqueue(status(503)) }
    server.enqueue(messages(sessionStart("s1")))
    init()
    startAndRegister()
    executor.advance(60_000)
    assertEquals(5, server.requestCount)
    assertEquals(listOf(2_000L, 4_000L, 8_000L, 16_000L), executor.delays)
    assertEquals(InAppFetchState.GaveUp(true), coordinator.session.fetch)
    coordinator.onNetworkAvailable()
    executor.runAll()
    assertEquals(6, server.requestCount)
    assertEquals(listOf("s1"), presenter.presented.map { it.message.id })
  }

  @Test
  fun `eligible 401 rejects the key and logs only the generic line`() {
    server.enqueue(status(401))
    init()
    startAndRegister()
    assertTrue(coordinator.session.keyRejected)
    assertEquals(listOf("Notti.inapp: eligible failed (HTTP 401)"), logs)
    queuedEvent()
    coordinator.onAppForegrounded()
    executor.runAll()
    assertEquals(1, server.requestCount)
  }

  @Test
  fun `eligible 403 logs the inactive warning once per session and 422 the generic line`() {
    server.enqueue(status(403))
    server.enqueue(status(422))
    init()
    startAndRegister()
    coordinator.onSessionEnded()
    coordinator.onSessionStarted()
    executor.runAll()
    assertEquals(
      listOf(NottiInAppCoordinator.INACTIVE_WARNING, "Notti.inapp: eligible failed (HTTP 422)"),
      logs
    )
    coordinator.onNetworkAvailable()
    executor.runAll()
    assertEquals(2, server.requestCount)
  }

  @Test
  fun `403 warning is logged once per session per route`() {
    queuedEvent()
    server.enqueue(status(403))
    server.enqueue(status(403))
    server.enqueue(status(403))
    init()
    startAndRegister()
    coordinator.onAppForegrounded()
    executor.runAll()
    assertEquals(3, server.requestCount)
    assertEquals(2, logs.count { it == NottiInAppCoordinator.INACTIVE_WARNING })
  }

  // Late responses and config changes

  @Test
  fun `a response arriving after its session ended is discarded even with a new session open`() {
    server.enqueue(messages(sessionStart("s1"), eventMessage("e1", "buy")))
    server.enqueue(messages())
    init()
    coordinator.onSessionStarted()
    coordinator.onRegistered()
    coordinator.onSessionEnded()
    coordinator.onSessionStarted()
    executor.runAll()
    assertEquals(2, server.requestCount)
    assertTrue(presenter.presented.isEmpty())
    assertTrue(coordinator.session.heldMessages.isEmpty())
  }

  @Test
  fun `different config resets state, tears the display down silently and purges other apps`() {
    server.enqueue(messages(sessionStart("s1")))
    server.enqueue(status(201))
    init("app-1")
    startAndRegister()
    val display = showVisible()
    executor.runAll()
    assertEquals(listOf(eligiblePath(), eventsPath("s1")), paths(takeAll()))
    queuedEvent("stale", appId = "app-1")

    server.enqueue(messages())
    init("app-2")
    executor.runAll()
    assertEquals(listOf(display), presenter.tornDown)
    assertTrue(store.all().isEmpty())
    coordinator.onRegistered()
    executor.runAll()
    assertEquals(listOf(eligiblePath("app-2")), paths(takeAll()))
    assertFalse(presenter.closed.contains(display.displayId))
  }

  @Test
  fun `an in-flight eligible of the old config is discarded`() {
    server.enqueue(messages(sessionStart("s1")))
    init("app-1")
    coordinator.onSessionStarted()
    coordinator.onRegistered()
    init("app-2")
    executor.runAll()
    assertEquals(1, server.requestCount)
    assertTrue(presenter.presented.isEmpty())
  }

  @Test
  fun `same config keeps the display and the fetch state`() {
    server.enqueue(messages(sessionStart("s1")))
    init()
    startAndRegister()
    val display = presenter.presented.single()
    init()
    executor.runAll()
    assertSame(display, coordinator.session.display)
    assertTrue(presenter.tornDown.isEmpty())
    assertEquals(InAppFetchState.Done, coordinator.session.fetch)
  }

  // trackEvent

  @Test
  fun `initialize then trackEvent before the first session matches once held messages arrive`() {
    server.enqueue(messages(eventMessage("e1", "checkout")))
    init()
    coordinator.trackEvent("checkout")
    startAndRegister()
    assertEquals(listOf("e1"), presenter.presented.map { it.message.id })
  }

  @Test
  fun `trackEvent before initialize or blank is a no-op`() {
    coordinator.trackEvent("checkout")
    coordinator.trackEvent("  ")
    server.enqueue(messages(eventMessage("e1", "checkout")))
    init()
    startAndRegister()
    coordinator.trackEvent("")
    assertTrue(presenter.presented.isEmpty())
  }

  @Test
  fun `trackEvent after the response shows the oldest held match`() {
    server.enqueue(messages(eventMessage("e1", "buy"), eventMessage("e2", "buy")))
    init()
    startAndRegister()
    coordinator.trackEvent("buy")
    assertEquals(listOf("e1"), presenter.presented.map { it.message.id })
  }

  // Presenter callbacks and events

  @Test
  fun `impression then click are sent in order and the click reaches the sink`() {
    server.enqueue(messages(sessionStart("s1", ""","buttons":[{"id":"b1","label":"Go","action":{"type":"url","value":"https://x.test"}}]""")))
    server.enqueue(status(201))
    server.enqueue(status(201))
    init()
    startAndRegister()
    takeAll()
    val display = showVisible()
    executor.runAll()
    val action = display.message.buttons.single().action
    coordinator.onDisplayClicked(display.displayId, "b1", action)
    executor.runAll()

    val events = takeAll().map { JSONObject(it.body.readUtf8()) }
    assertEquals(listOf("impression", "click"), events.map { it.getString("type") })
    assertEquals("b1", events[1].getString("button_id"))
    assertFalse(events[1].has("reason"))
    assertEquals(listOf(InAppClick("s1", "b1", action)), clicks)
    assertEquals(listOf(display.displayId), presenter.closed)
  }

  @Test
  fun `second tap and a later dismiss on a closed display are ignored`() {
    server.enqueue(messages(sessionStart("s1")))
    init()
    startAndRegister()
    val display = showVisible()
    coordinator.onDisplayClicked(display.displayId, "b1", null)
    coordinator.onDisplayClicked(display.displayId, "b1", null)
    coordinator.onDisplayDismissed(display.displayId, InAppDismissReason.SWIPE)
    assertEquals(
      listOf(InAppEventType.IMPRESSION, InAppEventType.CLICK),
      store.all().map { it.type }
    )
    assertEquals(1, clicks.size)
  }

  @Test
  fun `a click is enqueued before it is delivered and delivered before the display closes`() {
    val seen = mutableListOf<String>()
    coordinator.clickSink = InAppClickSink {
      seen.add("deliver queued=${store.all().map { e -> e.type }} closed=${presenter.closed.size}")
      true
    }
    server.enqueue(messages(sessionStart("s1")))
    init()
    startAndRegister()
    val display = showVisible()
    coordinator.onDisplayClicked(display.displayId, "b1", InAppAction("url", "https://x.test"))
    assertEquals(
      listOf("deliver queued=${listOf(InAppEventType.IMPRESSION, InAppEventType.CLICK)} closed=0"),
      seen
    )
    assertEquals(listOf(display.displayId), presenter.closed)
    assertFalse(logs.contains(NottiInAppCoordinator.NO_LISTENER_WARNING))
  }

  @Test
  fun `the default click sink reports no listener when no module is live`() {
    val fresh = NottiInAppCoordinator(
      store = store,
      clientFactory = { config -> NottiApiClient(OkHttpClient(), config.baseUrl, config.appId, config.clientKey) },
      identity = { identity },
      executor = executor,
      postToMain = { it() }
    )
    assertFalse(fresh.clickSink!!.deliver(InAppClick("m1", "b1", null)))
  }

  @Test
  fun `click with no listener is still reported, closed and warned`() {
    coordinator.clickSink = null
    server.enqueue(messages(sessionStart("s1")))
    init()
    startAndRegister()
    val display = showVisible()
    coordinator.onDisplayClicked(display.displayId, "image", InAppAction("deeplink", "app://x"))
    assertEquals(InAppEventType.CLICK, store.all().last().type)
    assertEquals(listOf(display.displayId), presenter.closed)
    assertTrue(logs.contains(NottiInAppCoordinator.NO_LISTENER_WARNING))
  }

  @Test
  fun `repeated visible callbacks enqueue one impression`() {
    server.enqueue(messages(sessionStart("s1")))
    init()
    startAndRegister()
    val display = showVisible()
    coordinator.onDisplayVisible(display.displayId)
    coordinator.onDisplayAttached(display.displayId, false)
    coordinator.onDisplayAttached(display.displayId, true)
    coordinator.onDisplayVisible(display.displayId)
    assertEquals(1, store.all().count { it.type == InAppEventType.IMPRESSION })
  }

  @Test
  fun `no click or dismiss before visible`() {
    server.enqueue(messages(sessionStart("s1")))
    init()
    startAndRegister()
    val display = presenter.presented.single()
    coordinator.onDisplayClicked(display.displayId, "b1", null)
    coordinator.onDisplayDismissed(display.displayId, InAppDismissReason.CLOSE_BUTTON)
    assertTrue(store.all().isEmpty())
  }

  @Test
  fun `auto dismiss fires after the visible time and pauses in background`() {
    server.enqueue(messages(sessionStart("s1", ""","dismiss_after_seconds":5""")))
    init()
    startAndRegister()
    val display = showVisible()
    executor.advance(2_000)
    coordinator.onAppBackgrounded()
    executor.advance(60_000)
    assertTrue(presenter.closed.isEmpty())
    coordinator.onAppForegrounded()
    executor.advance(2_999)
    assertTrue(presenter.closed.isEmpty())
    executor.advance(1)
    assertEquals(listOf(display.displayId), presenter.closed)
    executor.runAll()
    val last = JSONObject(takeAll().last().body.readUtf8())
    assertEquals("dismiss", last.getString("type"))
    assertEquals(InAppDismissReason.AUTO, last.getString("reason"))
    assertFalse(last.has("button_id"))
  }

  // Event flush

  @Test
  fun `events 429 pauses the flush with the clamp and shares the deadline`() {
    for ((header, expected) in listOf("0" to 1_000L, "1000" to 300_000L, null to 60_000L, "abc" to 60_000L)) {
      restart()
      init()
      queuedEvent()
      server.enqueue(status(429, header))
      server.enqueue(status(201))
      coordinator.onRegistered()
      executor.runAll()
      assertEquals(1, server.requestCount)
      queuedEvent("new")
      coordinator.onNetworkAvailable()
      executor.runAll()
      assertEquals("header $header", 1, server.requestCount)
      executor.advance(expected - 1)
      assertEquals(1, server.requestCount)
      executor.advance(1)
      assertTrue(server.requestCount >= 2)
    }
  }

  @Test
  fun `events transient retries the same head with the same event_id`() {
    val event = queuedEvent()
    server.enqueue(status(503))
    server.enqueue(status(503))
    server.enqueue(status(201))
    init()
    coordinator.onRegistered()
    executor.advance(10_000)
    val ids = takeAll().map { JSONObject(it.body.readUtf8()).getString("event_id") }
    assertEquals(listOf(event.eventId, event.eventId, event.eventId), ids)
    assertEquals(listOf(2_000L, 4_000L), executor.delays)
    assertTrue(store.all().isEmpty())
  }

  @Test
  fun `events transient stops after 5 attempts and keeps the queue`() {
    queuedEvent()
    repeat(5) { server.enqueue(status(500)) }
    init()
    coordinator.onRegistered()
    executor.advance(120_000)
    assertEquals(5, server.requestCount)
    assertEquals(1, store.all().size)
  }

  @Test
  fun `events 408 follows the transient policy`() {
    queuedEvent()
    // OkHttp re-sends a 408 once on its own before the SDK sees it.
    server.enqueue(status(408))
    server.enqueue(status(408))
    server.enqueue(status(201))
    init()
    coordinator.onRegistered()
    executor.advance(2_000)
    assertEquals(3, server.requestCount)
    assertEquals(listOf(2_000L), executor.delays)
    assertTrue(store.all().isEmpty())
  }

  @Test
  fun `200 duplicate, 404 and 422 remove the head and continue`() {
    queuedEvent("a")
    queuedEvent("b")
    queuedEvent("c")
    server.enqueue(MockResponse().setResponseCode(200).setBody("""{"duplicate":true}"""))
    server.enqueue(status(404))
    server.enqueue(status(422))
    init()
    coordinator.onRegistered()
    executor.runAll()
    assertEquals(listOf(eventsPath("a"), eventsPath("b"), eventsPath("c")), paths(takeAll()))
    assertTrue(store.all().isEmpty())
  }

  @Test
  fun `events older than 7 days are never sent`() {
    queuedEvent("old")
    wall += 8L * 24 * 60 * 60 * 1000
    queuedEvent("fresh")
    server.enqueue(status(201))
    init()
    coordinator.onRegistered()
    executor.runAll()
    assertEquals(listOf(eventsPath("fresh")), paths(takeAll()))
  }

  @Test
  fun `events 403 stops the flush, keeps the queue and a later trigger retries`() {
    queuedEvent()
    server.enqueue(status(403))
    server.enqueue(status(201))
    init()
    coordinator.onRegistered()
    executor.runAll()
    assertEquals(1, store.all().size)
    coordinator.onNetworkAvailable()
    executor.runAll()
    assertTrue(store.all().isEmpty())
  }

  @Test
  fun `records of another app are never sent`() {
    queuedEvent("other", appId = "app-9")
    queuedEvent("mine")
    server.enqueue(status(201))
    init()
    coordinator.onRegistered()
    executor.runAll()
    assertEquals(listOf(eventsPath("mine")), paths(takeAll()))
    assertTrue(store.all().isEmpty())
  }

  @Test
  fun `a trigger during a running flush asks for one more pass`() {
    queuedEvent("a")
    server.enqueue(status(503))
    server.enqueue(status(201))
    server.enqueue(status(201))
    init()
    coordinator.onRegistered()
    executor.runAll()
    queuedEvent("b")
    coordinator.onNetworkAvailable()
    executor.runAll()
    assertEquals(1, server.requestCount)
    executor.advance(2_000)
    assertEquals(listOf(eventsPath("a"), eventsPath("a"), eventsPath("b")), paths(takeAll()))
  }

  // Privacy

  @Test
  fun `requests are only in-app POSTs and logs carry no identifiers`() {
    queuedEvent("msg-secret-id")
    server.enqueue(status(503))
    server.enqueue(messages(eventMessage("e-secret", "secret-event-name")))
    server.enqueue(status(403))
    init()
    coordinator.trackEvent("secret-event-name")
    startAndRegister()
    val display = presenter.presented.single()
    coordinator.onDisplayAttached(display.displayId, true)
    coordinator.onDisplayVisible(display.displayId)
    coordinator.clickSink = null
    coordinator.onDisplayClicked(display.displayId, "secret-button", InAppAction("url", "https://secret.test"))
    executor.advance(600_000)

    val requests = takeAll()
    assertTrue(requests.all { it.method == "POST" && it.path!!.contains("/in-app-messages/") })
    assertFalse(requests.any { it.path!!.contains("/devices") })
    val forbidden = listOf(token, deviceId, clientKey, "msg-secret-id", "e-secret", "secret-event-name", "secret-button", "https://secret.test", baseUrl)
    for (line in logs) for (value in forbidden) assertFalse("$line leaks $value", line.contains(value))
    assertTrue(logs.isNotEmpty())
  }

  @Test
  fun `identity and config never print their secrets`() {
    assertFalse(InAppIdentity(deviceId, token).toString().contains(token))
    assertFalse(InAppIdentity(deviceId, token).toString().contains(deviceId))
  }

  // Holder

  @Test
  fun `holder keeps the first coordinator`() {
    val first = NottiInApp.install(coordinator)
    val other = NottiInAppCoordinator(store, { error("unused") }, { null }, executor, { it() })
    assertSame(first, NottiInApp.install(other))
    assertSame(coordinator, NottiInApp.get())
    NottiInApp.resetForTests()
    assertNull(NottiInApp.get())
    assertNotNull(NottiInApp.install(other))
  }
}
