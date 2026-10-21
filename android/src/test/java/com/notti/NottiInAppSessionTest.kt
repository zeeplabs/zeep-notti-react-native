package com.notti

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

private fun message(
  id: String,
  trigger: InAppTrigger = InAppTrigger.SessionStart,
  renderable: Boolean = true,
  dismissAfterSeconds: Int? = null
) = InAppMessage(
  id = id,
  format = InAppFormat.CENTER,
  title = "t",
  body = "b",
  imageUrl = null,
  imageAction = null,
  style = InAppStyle(),
  dismissAfterSeconds = dismissAfterSeconds,
  trigger = trigger,
  buttons = emptyList(),
  renderable = renderable
)

private fun event(id: String, name: String) = message(id, InAppTrigger.Event(name))

private val CONFIG_A = InAppConfig("app-a", "key-a", "https://a.example")
private val CONFIG_B = InAppConfig("app-b", "key-b", "https://b.example")

class NottiInAppSessionTest {

  private var now = 1_000L
  private var counter = 0
  private lateinit var session: NottiInAppSession

  @Before
  fun setUp() {
    now = 1_000L
    counter = 0
    session = NottiInAppSession(monotonicMs = { now }, uuid = { "display-${++counter}" })
  }

  private fun openWithFetch(messages: List<InAppMessage>): InAppDecision {
    session.onInitialized(CONFIG_A)
    session.onSessionStarted()
    val generation = session.tryStartFetch()!!
    return session.onFetched(generation, messages)
  }

  private fun shownId(decision: InAppDecision): String? =
    (decision as? InAppDecision.Show)?.display?.message?.id

  private fun closeCurrent() {
    val display = session.display!!
    assertTrue(session.markVisible(display.displayId))
    assertTrue(session.markClosed(display.displayId))
  }

  // Session tokens

  @Test
  fun `session token increments and stale tokens are rejected`() {
    session.onInitialized(CONFIG_A)
    session.onSessionStarted()
    val first = session.sessionToken
    assertTrue(session.isCurrentSession(first))
    session.onSessionEnded()
    assertFalse(session.isCurrentSession(first))
    session.onSessionStarted()
    assertEquals(first + 1, session.sessionToken)
    assertFalse(session.isCurrentSession(first))
    assertTrue(session.isCurrentSession(session.sessionToken))
  }

  // onFetched selection

  @Test
  fun `first renderable session_start is shown and others are not queued`() {
    val decision = openWithFetch(
      listOf(
        message("broken", renderable = false),
        message("s1"),
        message("s2")
      )
    )
    assertEquals("s1", shownId(decision))
    closeCurrent()
    assertEquals(InAppDecision.None, session.trackEvent("anything"))
    assertNull(session.display)
  }

  @Test
  fun `event messages are held in server order and not shown on fetch`() {
    val decision = openWithFetch(listOf(event("e1", "buy"), event("e2", "buy"), event("e3", "view")))
    assertEquals(InAppDecision.None, decision)
    assertEquals(listOf("e1", "e2", "e3"), session.heldMessages.map { it.id })
  }

  @Test
  fun `session_start is dropped when a display already exists`() {
    session.onInitialized(CONFIG_A)
    session.onSessionStarted()
    assertEquals("s1", shownId(session.onFetched(session.tryStartFetch()!!, listOf(message("s1")))))
    val carried = session.display!!
    assertTrue(session.markVisible(carried.displayId))
    session.onSessionEnded()
    session.onSessionStarted()
    val decision = session.onFetched(session.tryStartFetch()!!, listOf(message("s2")))
    assertEquals(InAppDecision.None, decision)
    assertSame(carried, session.display)
  }

  @Test
  fun `duplicate id in the response is shown at most once`() {
    openWithFetch(listOf(event("e1", "buy"), event("e1", "buy")))
    assertEquals("e1", shownId(session.trackEvent("buy")))
    closeCurrent()
    assertEquals(InAppDecision.None, session.trackEvent("buy"))
  }

  @Test
  fun `only one successful fetch per session`() {
    session.onInitialized(CONFIG_A)
    session.onSessionStarted()
    val generation = session.tryStartFetch()!!
    assertNull(session.tryStartFetch())
    session.onFetched(generation, emptyList())
    assertEquals(InAppFetchState.Done, session.fetch)
    assertNull(session.tryStartFetch())
  }

  @Test
  fun `transient give-up can restart the fetch, terminal give-up cannot`() {
    session.onInitialized(CONFIG_A)
    session.onSessionStarted()
    val generation = session.tryStartFetch()!!
    session.onFetchGaveUp(generation, transient = true)
    val retry = session.tryStartFetch()
    assertNotNull(retry)
    session.onFetchGaveUp(retry!!, transient = false)
    assertNull(session.tryStartFetch())
  }

  @Test
  fun `no fetch without an open session or after a 401`() {
    session.onInitialized(CONFIG_A)
    assertNull(session.tryStartFetch())
    session.onSessionStarted()
    session.markKeyRejected()
    assertNull(session.tryStartFetch())
    session.onSessionEnded()
    session.onSessionStarted()
    assertFalse(session.keyRejected)
    assertNotNull(session.tryStartFetch())
  }

  // trackEvent

  @Test
  fun `trackEvent matches exactly and case-sensitively`() {
    openWithFetch(listOf(event("e1", "Buy")))
    assertEquals(InAppDecision.None, session.trackEvent("buy"))
    assertEquals(InAppDecision.None, session.trackEvent("Buy "))
    assertEquals("e1", shownId(session.trackEvent("Buy")))
  }

  @Test
  fun `trackEvent picks the oldest matching held message and never shows it twice`() {
    openWithFetch(listOf(event("e1", "buy"), event("e2", "buy")))
    assertEquals("e1", shownId(session.trackEvent("buy")))
    closeCurrent()
    assertEquals("e2", shownId(session.trackEvent("buy")))
    closeCurrent()
    assertEquals(InAppDecision.None, session.trackEvent("buy"))
  }

  @Test
  fun `trackEvent is ignored while a display is pending or visible and held stay untouched`() {
    openWithFetch(listOf(event("e1", "buy"), event("e2", "view")))
    assertEquals("e1", shownId(session.trackEvent("buy")))
    assertEquals(InAppDecision.None, session.trackEvent("view"))
    session.markVisible(session.display!!.displayId)
    assertEquals(InAppDecision.None, session.trackEvent("view"))
    assertEquals(listOf("e1", "e2"), session.heldMessages.map { it.id })
    assertTrue(session.markClosed(session.display!!.displayId))
    assertEquals("e2", shownId(session.trackEvent("view")))
  }

  @Test
  fun `blank names are ignored`() {
    openWithFetch(listOf(event("e1", " ")))
    assertEquals(InAppDecision.None, session.trackEvent(""))
    assertEquals(InAppDecision.None, session.trackEvent("   "))
  }

  @Test
  fun `names before the response are replayed once in order after onFetched`() {
    session.onInitialized(CONFIG_A)
    session.onSessionStarted()
    val generation = session.tryStartFetch()!!
    session.trackEvent("view")
    session.trackEvent("buy")
    session.trackEvent("view")
    assertEquals(listOf("view", "buy"), session.pending)
    val decision = session.onFetched(generation, listOf(event("e1", "buy"), event("e2", "view")))
    assertEquals("e2", shownId(decision))
    assertTrue(session.pending.isEmpty())
    closeCurrent()
    assertEquals(InAppDecision.None, session.trackEvent("other"))
    assertNull(session.display)
  }

  @Test
  fun `session_start wins over a replayed name`() {
    session.onInitialized(CONFIG_A)
    session.onSessionStarted()
    val generation = session.tryStartFetch()!!
    session.trackEvent("buy")
    val decision = session.onFetched(generation, listOf(message("s1"), event("e1", "buy")))
    assertEquals("s1", shownId(decision))
    assertTrue(session.pending.isEmpty())
  }

  @Test
  fun `pending names are capped at 32 distinct`() {
    session.onInitialized(CONFIG_A)
    session.onSessionStarted()
    repeat(40) { session.trackEvent("n$it") }
    assertEquals(NottiInAppSession.MAX_PENDING_NAMES, session.pending.size)
    assertEquals("n31", session.pending.last())
  }

  @Test
  fun `names while the fetch gave up stay pending until session end`() {
    session.onInitialized(CONFIG_A)
    session.onSessionStarted()
    session.onFetchGaveUp(session.tryStartFetch()!!, transient = true)
    session.trackEvent("buy")
    assertEquals(listOf("buy"), session.pending)
    session.onSessionEnded()
    assertTrue(session.pending.isEmpty())
  }

  // awaitingFirstSession

  @Test
  fun `trackEvent before onInitialized is ignored`() {
    session.trackEvent("buy")
    assertTrue(session.pending.isEmpty())
    session.onInitialized(CONFIG_A)
    session.onSessionStarted()
    val decision = session.onFetched(session.tryStartFetch()!!, listOf(event("e1", "buy")))
    assertEquals(InAppDecision.None, decision)
  }

  @Test
  fun `onInitialized then trackEvent before the first session replays with that session`() {
    session.onInitialized(CONFIG_A)
    assertTrue(session.awaitingFirstSession)
    session.trackEvent("buy")
    session.onSessionStarted()
    assertFalse(session.awaitingFirstSession)
    assertEquals(listOf("buy"), session.pending)
    val decision = session.onFetched(session.tryStartFetch()!!, listOf(event("e1", "buy")))
    assertEquals("e1", shownId(decision))
    assertTrue(session.pending.isEmpty())
  }

  @Test
  fun `awaiting names are capped at 32`() {
    session.onInitialized(CONFIG_A)
    repeat(33) { session.trackEvent("n$it") }
    assertEquals(32, session.pending.size)
  }

  @Test
  fun `session end with no session open keeps the awaiting names`() {
    session.onInitialized(CONFIG_A)
    session.trackEvent("buy")
    session.onSessionEnded()
    assertEquals(listOf("buy"), session.pending)
    assertTrue(session.awaitingFirstSession)
  }

  @Test
  fun `trackEvent in background after a session ran is ignored`() {
    session.onInitialized(CONFIG_A)
    session.onSessionStarted()
    session.onSessionEnded()
    session.trackEvent("buy")
    assertTrue(session.pending.isEmpty())
  }

  @Test
  fun `re-initialize after a session ran does not set awaitingFirstSession`() {
    session.onInitialized(CONFIG_A)
    session.onSessionStarted()
    session.onSessionEnded()
    session.onInitialized(CONFIG_B)
    assertFalse(session.awaitingFirstSession)
  }

  // fetchGeneration and late responses

  @Test
  fun `response after session end is discarded`() {
    session.onInitialized(CONFIG_A)
    session.onSessionStarted()
    val generation = session.tryStartFetch()!!
    session.onSessionEnded()
    assertEquals(InAppDecision.None, session.onFetched(generation, listOf(message("s1"), event("e1", "buy"))))
    assertTrue(session.heldMessages.isEmpty())
  }

  @Test
  fun `response of an ended session is discarded even with a newer session open`() {
    session.onInitialized(CONFIG_A)
    session.onSessionStarted()
    val old = session.tryStartFetch()!!
    session.onSessionEnded()
    session.onSessionStarted()
    assertEquals(InAppDecision.None, session.onFetched(old, listOf(message("s1"), event("e1", "buy"))))
    assertTrue(session.heldMessages.isEmpty())
    assertEquals(InAppFetchState.Idle, session.fetch)
    assertNotNull(session.tryStartFetch())
  }

  @Test
  fun `stale give-up is ignored`() {
    session.onInitialized(CONFIG_A)
    session.onSessionStarted()
    val old = session.tryStartFetch()!!
    session.onSessionEnded()
    session.onSessionStarted()
    session.onFetchGaveUp(old, transient = false)
    assertEquals(InAppFetchState.Idle, session.fetch)
  }

  @Test
  fun `held messages are dropped at session end`() {
    openWithFetch(listOf(event("e1", "buy")))
    session.onSessionEnded()
    assertTrue(session.heldMessages.isEmpty())
    session.onSessionStarted()
    assertEquals(InAppDecision.None, session.trackEvent("buy"))
  }

  // onInitialized

  @Test
  fun `same config leaves the state untouched`() {
    openWithFetch(listOf(event("e1", "buy"), message("s1")))
    val display = session.display
    val generation = session.fetchGeneration
    session.eventsPausedUntilMs = 5_000L
    assertEquals(InAppInitOutcome.Unchanged, session.onInitialized(CONFIG_A.copy()))
    assertSame(display, session.display)
    assertEquals(generation, session.fetchGeneration)
    assertEquals(listOf("e1"), session.heldMessages.map { it.id })
    assertEquals(5_000L, session.eventsPausedUntilMs)
    assertEquals(InAppFetchState.Done, session.fetch)
  }

  @Test
  fun `different config resets the state and tears the display down silently`() {
    session.onInitialized(CONFIG_A)
    session.onSessionStarted()
    val generation = session.tryStartFetch()!!
    session.trackEvent("buy")
    session.onFetched(generation, listOf(message("s1"), event("e1", "buy")))
    val display = session.display!!
    session.markVisible(display.displayId)
    session.eligiblePausedUntilMs = 1L
    session.eventsPausedUntilMs = 2L
    session.markKeyRejected()
    session.shouldWarnInactive(InAppRoute.EVENTS)

    val outcome = session.onInitialized(CONFIG_B)

    assertEquals(InAppInitOutcome.Changed(display), outcome)
    assertNull(session.display)
    assertEquals(InAppDisplayState.CLOSED, display.state)
    assertFalse(session.markClosed(display.displayId))
    assertTrue(session.heldMessages.isEmpty())
    assertTrue(session.pending.isEmpty())
    assertTrue(session.shown.isEmpty())
    assertEquals(InAppFetchState.Idle, session.fetch)
    assertNull(session.eligiblePausedUntilMs)
    assertNull(session.eventsPausedUntilMs)
    assertFalse(session.keyRejected)
    assertTrue(session.shouldWarnInactive(InAppRoute.EVENTS))
    assertEquals(generation + 1, session.fetchGeneration)
    assertEquals(InAppDecision.None, session.onFetched(generation, listOf(message("s2"))))
    assertEquals(CONFIG_B, session.config)
  }

  @Test
  fun `config change during an in-flight fetch lets a new fetch start`() {
    session.onInitialized(CONFIG_A)
    session.onSessionStarted()
    val old = session.tryStartFetch()!!
    session.onInitialized(CONFIG_B)
    val fresh = session.tryStartFetch()!!
    assertTrue(fresh != old)
    assertEquals("s1", shownId(session.onFetched(fresh, listOf(message("s1")))))
  }

  @Test
  fun `first onInitialized reports First`() {
    assertEquals(InAppInitOutcome.First, session.onInitialized(CONFIG_A))
  }

  @Test
  fun `config toString never prints the key`() {
    assertFalse(CONFIG_A.toString().contains("key-a"))
    assertFalse(CONFIG_A.toString().contains("app-a"))
  }

  // Display states

  @Test
  fun `markVisible is true only once`() {
    openWithFetch(listOf(message("s1")))
    val id = session.display!!.displayId
    assertTrue(session.markVisible(id))
    assertFalse(session.markVisible(id))
    assertTrue(session.display!!.impressionRecorded)
  }

  @Test
  fun `markVisible with an unknown display id is rejected`() {
    openWithFetch(listOf(message("s1")))
    assertFalse(session.markVisible("other"))
  }

  @Test
  fun `markClosed gives exactly one terminal outcome`() {
    openWithFetch(listOf(message("s1")))
    val id = session.display!!.displayId
    session.markVisible(id)
    assertTrue(session.markClosed(id))
    assertFalse(session.markClosed(id))
    assertFalse(session.markVisible(id))
  }

  @Test
  fun `no terminal outcome before visible`() {
    openWithFetch(listOf(message("s1")))
    val id = session.display!!.displayId
    assertFalse(session.markClosed(id))
    assertEquals(InAppDisplayState.PREPARING, session.display!!.state)
  }

  @Test
  fun `dropPreparing removes a display that never became visible`() {
    openWithFetch(listOf(message("s1")))
    val id = session.display!!.displayId
    assertTrue(session.dropPreparing(id))
    assertNull(session.display)
    assertFalse(session.markVisible(id))
  }

  @Test
  fun `dropPreparing does not touch a visible display`() {
    openWithFetch(listOf(message("s1")))
    val id = session.display!!.displayId
    session.markVisible(id)
    assertFalse(session.dropPreparing(id))
    assertNotNull(session.display)
  }

  // Session end carry-over (DD-8)

  @Test
  fun `visible display survives session end and its id is shown in the next session`() {
    openWithFetch(listOf(message("s1")))
    val display = session.display!!
    session.markVisible(display.displayId)
    assertNull(session.onSessionEnded())
    assertSame(display, session.display)
    session.onSessionStarted()
    assertEquals(setOf("s1"), session.shown)
    assertTrue(session.markClosed(display.displayId))
    val decision = session.onFetched(session.tryStartFetch()!!, listOf(message("s1"), message("s2")))
    assertEquals("s2", shownId(decision))
  }

  @Test
  fun `preparing display is dropped at session end`() {
    openWithFetch(listOf(message("s1")))
    val display = session.display!!
    assertSame(display, session.onSessionEnded())
    assertNull(session.display)
    assertFalse(session.markVisible(display.displayId))
  }

  @Test
  fun `shown ids do not persist across sessions`() {
    openWithFetch(listOf(message("s1")))
    closeCurrent()
    session.onSessionEnded()
    session.onSessionStarted()
    assertTrue(session.shown.isEmpty())
    val decision = session.onFetched(session.tryStartFetch()!!, listOf(message("s1")))
    assertEquals("s1", shownId(decision))
  }

  // Warnings

  @Test
  fun `inactive warning once per session per route`() {
    session.onInitialized(CONFIG_A)
    session.onSessionStarted()
    assertTrue(session.shouldWarnInactive(InAppRoute.ELIGIBLE))
    assertFalse(session.shouldWarnInactive(InAppRoute.ELIGIBLE))
    assertTrue(session.shouldWarnInactive(InAppRoute.EVENTS))
    session.onSessionEnded()
    session.onSessionStarted()
    assertTrue(session.shouldWarnInactive(InAppRoute.ELIGIBLE))
  }

  // Clock wiring

  @Test
  fun `display gets a clock only for 1 to 300 seconds`() {
    openWithFetch(listOf(event("a", "a"), message("b", InAppTrigger.Event("b"), dismissAfterSeconds = 5)))
    session.trackEvent("a")
    assertNull(session.display!!.clock)
    closeCurrent()
    session.trackEvent("b")
    assertNotNull(session.display!!.clock)
  }

  @Test
  fun `markVisible starts the clock and app background pauses it`() {
    openWithFetch(listOf(message("s1", dismissAfterSeconds = 10)))
    val display = session.display!!
    val clock = display.clock!!
    clock.setAttached(true)
    assertFalse(clock.isRunning)
    session.markVisible(display.displayId)
    assertTrue(clock.isRunning)
    now += 4_000
    session.setAppForeground(false)
    assertFalse(clock.isRunning)
    now += 60_000
    assertEquals(6_000L, clock.remainingMs())
    session.setAppForeground(true)
    now += 6_000
    assertTrue(clock.isExpired())
  }

  @Test
  fun `clock created while the app is in background starts paused`() {
    session.onInitialized(CONFIG_A)
    session.onSessionStarted()
    val generation = session.tryStartFetch()!!
    session.setAppForeground(false)
    session.onFetched(generation, listOf(message("s1", dismissAfterSeconds = 3)))
    val display = session.display!!
    display.clock!!.setAttached(true)
    session.markVisible(display.displayId)
    assertFalse(display.clock!!.isRunning)
  }
}

class NottiInAppDisplayClockTest {

  private var now = 0L
  private val time: () -> Long = { now }

  @Test
  fun `values outside 1 to 300 give no clock`() {
    assertNull(NottiInAppDisplayClock.create(null, time))
    assertNull(NottiInAppDisplayClock.create(0, time))
    assertNull(NottiInAppDisplayClock.create(-5, time))
    assertNull(NottiInAppDisplayClock.create(301, time))
    assertNotNull(NottiInAppDisplayClock.create(1, time))
    assertNotNull(NottiInAppDisplayClock.create(300, time))
  }

  @Test
  fun `clock runs only after start while attached and in foreground`() {
    val clock = NottiInAppDisplayClock.create(10, time)!!
    clock.setAttached(true)
    now += 5_000
    assertEquals(10_000L, clock.remainingMs())
    clock.start()
    assertTrue(clock.isRunning)
    now += 3_000
    assertEquals(7_000L, clock.remainingMs())
  }

  @Test
  fun `detach preserves the remaining time`() {
    val clock = NottiInAppDisplayClock.create(10, time)!!
    clock.start()
    clock.setAttached(true)
    now += 2_000
    clock.setAttached(false)
    now += 100_000
    assertEquals(8_000L, clock.remainingMs())
    clock.setAttached(true)
    now += 8_000
    assertTrue(clock.isExpired())
  }

  @Test
  fun `background pause and resume preserve remaining time`() {
    val clock = NottiInAppDisplayClock.create(5, time)!!
    clock.start()
    clock.setAttached(true)
    now += 1_000
    clock.setForeground(false)
    now += 30_000
    clock.setForeground(true)
    assertEquals(4_000L, clock.remainingMs())
    now += 3_999
    assertFalse(clock.isExpired())
    now += 1
    assertTrue(clock.isExpired())
  }

  @Test
  fun `remaining time never goes below zero`() {
    val clock = NottiInAppDisplayClock.create(1, time)!!
    clock.start()
    clock.setAttached(true)
    now += 10_000
    assertEquals(0L, clock.remainingMs())
    clock.setAttached(false)
    assertEquals(0L, clock.remainingMs())
  }

  @Test
  fun `repeated attach does not restart the countdown`() {
    val clock = NottiInAppDisplayClock.create(10, time)!!
    clock.start()
    clock.setAttached(true)
    now += 2_000
    clock.setAttached(true)
    clock.start()
    now += 1_000
    assertEquals(7_000L, clock.remainingMs())
  }
}
