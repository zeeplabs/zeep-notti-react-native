package com.notti

import android.app.Activity
import android.content.Context
import android.os.Looper
import android.view.KeyEvent
import android.view.View
import android.view.ViewGroup
import androidx.activity.ComponentActivity
import androidx.activity.OnBackPressedCallback
import okhttp3.OkHttpClient
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.android.controller.ActivityController
import org.robolectric.annotation.Config

/** Records presenter callbacks in order. */
private class RecordingDisplayEvents : InAppDisplayEvents {
  val calls = mutableListOf<String>()
  val visible get() = calls.count { it.startsWith("visible:") }

  override fun onDisplayAttached(displayId: String, attached: Boolean) {
    calls.add("attached:$displayId:$attached")
  }
  override fun onDisplayVisible(displayId: String) {
    calls.add("visible:$displayId")
  }
  override fun onDisplayClicked(displayId: String, buttonId: String, action: InAppAction?) {
    calls.add("click:$displayId:$buttonId")
  }
  override fun onDisplayDismissed(displayId: String, reason: String) {
    calls.add("dismiss:$displayId:$reason")
  }
  override fun onDisplayFailed(displayId: String) {
    calls.add("failed:$displayId")
  }
}

/** Main-thread executor with virtual time for the display clock checks. */
private class VirtualTimeExecutor(private val time: () -> Long, private val setTime: (Long) -> Unit) : InAppExecutor {
  private val scheduled = mutableListOf<Pair<Long, () -> Unit>>()

  // Network work is never run: these tests have no identity, so none is started.
  override fun execute(task: () -> Unit) = Unit

  override fun schedule(delayMs: Long, task: () -> Unit) {
    scheduled.add(time() + delayMs to task)
  }

  fun advance(ms: Long) {
    val target = time() + ms
    while (true) {
      val next = scheduled.filter { it.first <= target }.minByOrNull { it.first } ?: break
      scheduled.remove(next)
      setTime(next.first)
      next.second()
    }
    setTime(target)
  }
}

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class NottiInAppPresenterTest {

  private val app = RuntimeEnvironment.getApplication()
  private lateinit var tracker: NottiInAppActivityTracker
  private lateinit var events: RecordingDisplayEvents
  private lateinit var presenter: NottiInAppOverlayPresenter
  private val controllers = mutableListOf<ActivityController<out Activity>>()

  @Before
  fun setUp() {
    tracker = NottiInAppActivityTracker()
    app.registerActivityLifecycleCallbacks(tracker)
    events = RecordingDisplayEvents()
    presenter = NottiInAppOverlayPresenter(tracker, events)
  }

  @After
  fun tearDown() {
    app.unregisterActivityLifecycleCallbacks(tracker)
    controllers.forEach { runCatching { it.pause().stop().destroy() } }
  }

  // Helpers

  private fun message(format: String, extra: String = ""): InAppMessage {
    val raw = """{"messages":[{"id":"m","format":"$format","title":"Title","body":"Body",""" +
      """"trigger":{"type":"session_start"}$extra}]}"""
    return parseEligibleResponse(raw)!!.single()
  }

  private fun display(format: String = "center", id: String = "d1") = InAppDisplay(id, message(format), null)

  private fun <T : Activity> start(type: Class<T>): ActivityController<T> =
    Robolectric.buildActivity(type).setup().also { controllers.add(it) }

  private fun resumed(): ActivityController<ComponentActivity> = start(ComponentActivity::class.java)

  private fun idle() = shadowOf(Looper.getMainLooper()).idle()

  private fun content(activity: Activity): ViewGroup = activity.findViewById(android.R.id.content)

  private fun overlayIn(activity: Activity): View? {
    val container = content(activity)
    return (0 until container.childCount).map { container.getChildAt(it) }.firstOrNull { it is InAppOverlayLayout }
  }

  private fun hostBackCounter(activity: ComponentActivity): IntArray {
    val count = intArrayOf(0)
    activity.onBackPressedDispatcher.addCallback(object : OnBackPressedCallback(true) {
      override fun handleOnBackPressed() {
        count[0]++
      }
    })
    return count
  }

  // Attach and impression

  @Test
  fun `overlay is added to the content view and raises onVisible once after layout`() {
    val controller = resumed()
    presenter.present(display())
    idle()

    assertTrue(overlayIn(controller.get()) != null)
    assertEquals(listOf("attached:d1:true", "visible:d1"), events.calls)
  }

  @Test
  fun `without a resumed activity the display waits and is attached on the next resume`() {
    presenter.present(display())
    idle()
    assertFalse(presenter.isAttached)
    assertTrue(events.calls.isEmpty())

    val controller = resumed()
    idle()
    assertTrue(overlayIn(controller.get()) != null)
    assertEquals(1, events.visible)
  }

  @Test
  fun `pause removes the overlay and resume attaches fresh views without a second onVisible`() {
    val controller = resumed()
    presenter.present(display())
    idle()
    val first = overlayIn(controller.get())

    controller.pause()
    assertNull(overlayIn(controller.get()))
    assertFalse(presenter.isAttached)

    controller.resume()
    idle()
    val second = overlayIn(controller.get())
    assertTrue(second != null)
    assertNotSame(first, second)
    assertEquals(1, events.visible)
    assertEquals(listOf("attached:d1:true", "visible:d1", "attached:d1:false", "attached:d1:true"), events.calls)
  }

  @Test
  fun `recreation keeps the same display and raises onVisible once`() {
    val controller = resumed()
    presenter.present(display())
    idle()
    val before = controller.get()

    controller.recreate()
    idle()

    assertNotSame(before, controller.get())
    assertNull(overlayIn(before))
    assertTrue(overlayIn(controller.get()) != null)
    assertEquals(1, events.visible)
  }

  @Test
  fun `moving from activity A to B moves the overlay`() {
    val a = resumed()
    presenter.present(display())
    idle()

    a.pause()
    val b = resumed()
    idle()

    assertNull(overlayIn(a.get()))
    assertTrue(overlayIn(b.get()) != null)
    assertEquals(1, events.visible)
  }

  @Test
  fun `a resume of another activity while still attached moves the overlay`() {
    val a = resumed()
    presenter.present(display())
    idle()

    // Multi-window style: B resumes before A pauses.
    val b = resumed()
    idle()

    assertNull(overlayIn(a.get()))
    assertTrue(overlayIn(b.get()) != null)
  }

  // Close and silent teardown

  @Test
  fun `close removes the overlay and restores the host accessibility flags`() {
    val controller = resumed()
    val host = View(controller.get()).apply { importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_YES }
    content(controller.get()).addView(host)
    presenter.present(display())
    idle()
    assertEquals(View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS, host.importantForAccessibility)

    presenter.close("d1")

    assertNull(overlayIn(controller.get()))
    assertEquals(View.IMPORTANT_FOR_ACCESSIBILITY_YES, host.importantForAccessibility)
    // Closed for good: a later resume does not bring it back.
    controller.pause().resume()
    idle()
    assertNull(overlayIn(controller.get()))
  }

  @Test
  fun `bars do not hide the host from accessibility`() {
    val controller = resumed()
    val host = View(controller.get()).apply { importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_YES }
    content(controller.get()).addView(host)
    presenter.present(display("top"))
    idle()

    assertEquals(View.IMPORTANT_FOR_ACCESSIBILITY_YES, host.importantForAccessibility)
  }

  @Test
  fun `close of another display id is ignored`() {
    val controller = resumed()
    presenter.present(display())
    idle()

    presenter.close("other")

    assertTrue(overlayIn(controller.get()) != null)
  }

  @Test
  fun `silent teardown removes the overlay, restores the host and reports nothing`() {
    val controller = resumed()
    val host = View(controller.get()).apply { importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_AUTO }
    content(controller.get()).addView(host)
    val shown = display()
    presenter.present(shown)
    idle()
    val before = events.calls.toList()

    presenter.teardown(shown)
    idle()

    assertNull(overlayIn(controller.get()))
    assertEquals(View.IMPORTANT_FOR_ACCESSIBILITY_AUTO, host.importantForAccessibility)
    assertEquals(before, events.calls)
  }

  @Test
  fun `teardown of a display that is not shown is ignored`() {
    val controller = resumed()
    presenter.present(display())
    idle()

    presenter.teardown(display(id = "other"))

    assertTrue(overlayIn(controller.get()) != null)
  }

  @Test
  fun `the close control reports a close_button dismiss`() {
    val controller = resumed()
    presenter.present(display())
    idle()

    val overlay = overlayIn(controller.get()) as ViewGroup
    val close = findByDescription(overlay, NottiInAppAccessibility.closeLabel(controller.get()))!!
    close.performClick()

    assertEquals("dismiss:d1:close_button", events.calls.last())
  }

  private fun findByDescription(view: View, description: String): View? {
    if (view.contentDescription == description) return view
    if (view is ViewGroup) {
      for (i in 0 until view.childCount) findByDescription(view.getChildAt(i), description)?.let { return it }
    }
    return null
  }

  // Back (DD-10, A19)

  @Test
  fun `back on center and full is consumed and never reaches the host`() {
    for (format in listOf("center", "full")) {
      val controller = resumed()
      val host = hostBackCounter(controller.get())
      presenter.present(display(format, id = format))
      idle()

      controller.get().onBackPressedDispatcher.onBackPressed()

      assertEquals(format, 0, host[0])
      assertTrue(format, overlayIn(controller.get()) != null)
      assertFalse(format, events.calls.any { it.startsWith("dismiss") || it.startsWith("click") })
      presenter.teardownSilently()
    }
  }

  @Test
  fun `back on top and bottom reaches the host`() {
    for (format in listOf("top", "bottom")) {
      val controller = resumed()
      val host = hostBackCounter(controller.get())
      presenter.present(display(format, id = format))
      idle()

      controller.get().onBackPressedDispatcher.onBackPressed()

      assertEquals(format, 1, host[0])
      presenter.teardownSilently()
    }
  }

  @Test
  fun `the back callback is released on close, detach and silent teardown`() {
    val controller = resumed()
    val activity = controller.get()
    val host = hostBackCounter(activity)

    presenter.present(display(id = "a"))
    idle()
    presenter.close("a")
    activity.onBackPressedDispatcher.onBackPressed()
    assertEquals(1, host[0])

    presenter.present(display(id = "b"))
    idle()
    presenter.teardownSilently()
    activity.onBackPressedDispatcher.onBackPressed()
    assertEquals(2, host[0])

    presenter.present(display(id = "c"))
    idle()
    controller.pause()
    activity.onBackPressedDispatcher.onBackPressed()
    assertEquals(3, host[0])

    // Re-registered on the next attach.
    controller.resume()
    idle()
    activity.onBackPressedDispatcher.onBackPressed()
    assertEquals(3, host[0])
  }

  @Test
  fun `a plain activity consumes the back key while a center display is attached`() {
    val controller = start(Activity::class.java)
    val activity = controller.get()
    presenter.present(display())
    idle()

    backKey(activity)
    assertFalse(activity.isFinishing)
    assertTrue(overlayIn(activity) != null)

    presenter.teardownSilently()
    backKey(activity)
    assertTrue(activity.isFinishing)
  }

  private fun backKey(activity: Activity) {
    activity.dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_BACK))
    activity.dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_BACK))
  }
}

/** Presenter + real coordinator: one impression, the display clock and the session end. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class NottiInAppPresenterLifecycleTest {

  private val app = RuntimeEnvironment.getApplication()
  private var monotonic = 0L
  private lateinit var executor: VirtualTimeExecutor
  private lateinit var store: NottiInAppEventStore
  private lateinit var coordinator: NottiInAppCoordinator
  private lateinit var tracker: NottiInAppActivityTracker
  private lateinit var presenter: NottiInAppOverlayPresenter
  private val controllers = mutableListOf<ActivityController<ComponentActivity>>()

  @Before
  fun setUp() {
    val prefs = app.getSharedPreferences("notti_prefs", Context.MODE_PRIVATE)
    prefs.edit().clear().commit()
    store = NottiInAppEventStore(prefs, clock = { 1_760_000_000_000L })
    executor = VirtualTimeExecutor({ monotonic }, { monotonic = it })
    coordinator = NottiInAppCoordinator(
      store = store,
      clientFactory = { NottiApiClient(OkHttpClient(), it.baseUrl, it.appId, it.clientKey) },
      identity = { null },
      executor = executor,
      postToMain = { it() },
      monotonicMs = { monotonic }
    )
    tracker = NottiInAppActivityTracker()
    app.registerActivityLifecycleCallbacks(tracker)
    presenter = NottiInAppOverlayPresenter(tracker, coordinator)
    coordinator.presenter = presenter
    coordinator.onInitialized("app", "key", "https://api.test")
    coordinator.onSessionStarted()
  }

  @After
  fun tearDown() {
    app.unregisterActivityLifecycleCallbacks(tracker)
    controllers.forEach { runCatching { it.pause().stop().destroy() } }
  }

  private fun resumed() = Robolectric.buildActivity(ComponentActivity::class.java).setup().also { controllers.add(it) }

  private fun idle() = shadowOf(Looper.getMainLooper()).idle()

  private fun overlayIn(activity: Activity): View? {
    val container = activity.findViewById<ViewGroup>(android.R.id.content)
    return (0 until container.childCount).map { container.getChildAt(it) }.firstOrNull { it is InAppOverlayLayout }
  }

  /** Feeds one `session_start` message through the session and presents the resulting display. */
  private fun show(extra: String = ""): InAppDisplay {
    val raw = """{"messages":[{"id":"m1","format":"center","title":"T","trigger":{"type":"session_start"}$extra}]}"""
    val generation = coordinator.session.tryStartFetch()!!
    val decision = coordinator.session.onFetched(generation, parseEligibleResponse(raw)!!)
    val display = (decision as InAppDecision.Show).display
    presenter.present(display)
    return display
  }

  private fun types() = store.all().map { it.type to it.reason }

  @Test
  fun `recreation and an activity change record exactly one impression`() {
    val controller = resumed()
    show()
    idle()
    controller.recreate()
    idle()
    controller.pause()
    resumed()
    idle()

    assertEquals(listOf(InAppEventType.IMPRESSION to null), types())
  }

  @Test
  fun `auto dismiss counts only attached foreground time and survives recreation`() {
    val controller = resumed()
    val display = show(""","dismiss_after_seconds":5""")
    idle()

    executor.advance(2_000)
    controller.pause()
    // Detached: time does not count.
    executor.advance(60_000)
    assertSame(display, coordinator.session.display)

    controller.resume()
    idle()
    controller.recreate()
    idle()
    executor.advance(2_999)
    assertSame(display, coordinator.session.display)
    assertTrue(overlayIn(controller.get()) != null)

    executor.advance(1)
    assertNull(coordinator.session.display)
    assertNull(overlayIn(controller.get()))
    assertEquals(listOf(InAppEventType.IMPRESSION to null, InAppEventType.DISMISS to InAppDismissReason.AUTO), types())
  }

  @Test
  fun `backgrounding pauses the clock`() {
    resumed()
    val display = show(""","dismiss_after_seconds":5""")
    idle()

    executor.advance(4_000)
    coordinator.onAppBackgrounded()
    executor.advance(60_000)
    assertSame(display, coordinator.session.display)

    coordinator.onAppForegrounded()
    executor.advance(1_000)
    assertNull(coordinator.session.display)
  }

  @Test
  fun `a manual close cancels the auto dismiss`() {
    val controller = resumed()
    val display = show(""","dismiss_after_seconds":5""")
    idle()

    coordinator.onDisplayDismissed(display.displayId, InAppDismissReason.CLOSE_BUTTON)
    executor.advance(10_000)

    assertNull(overlayIn(controller.get()))
    assertEquals(listOf(InAppEventType.IMPRESSION to null, InAppEventType.DISMISS to InAppDismissReason.CLOSE_BUTTON), types())
  }

  @Test
  fun `a session end while waiting for an activity drops the display with no event`() {
    show()
    idle()
    coordinator.onSessionEnded()

    val controller = resumed()
    idle()

    assertNull(overlayIn(controller.get()))
    assertNull(coordinator.session.display)
    assertTrue(store.all().isEmpty())
  }

  @Test
  fun `a config change tears the display down silently`() {
    val controller = resumed()
    show()
    idle()

    coordinator.onInitialized("app", "other-key", "https://api.test")

    assertNull(overlayIn(controller.get()))
    assertEquals(listOf(InAppEventType.IMPRESSION to null), types())
  }
}
