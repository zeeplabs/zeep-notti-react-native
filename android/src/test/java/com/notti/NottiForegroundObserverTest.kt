package com.notti

import android.content.Context
import android.os.Looper
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.time.Duration
import java.util.concurrent.Executor

/**
 * Drives the real [NottiForegroundObserver] callbacks and its main-looper
 * heartbeat ticker (Robolectric paused looper) against the process-wide
 * [NottiModule.processSessionGate], with the live core swapped in through
 * [NottiForegroundObserver.coreProvider].
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class NottiForegroundObserverTest {

  private val owner = object : LifecycleOwner {
    override val lifecycle: Lifecycle by lazy { LifecycleRegistry(this) }
  }
  private lateinit var store: NottiDeviceStore
  private var now = 0L

  @Before
  fun setUp() {
    NottiModule.resetProcessWideStateForTest()
    val prefs = RuntimeEnvironment.getApplication()
      .getSharedPreferences("notti_observer_test", Context.MODE_PRIVATE)
    prefs.edit().clear().commit()
    store = NottiDeviceStore(prefs)
    now = 1_000L
  }

  @After
  fun tearDown() {
    NottiForegroundObserver.onStop(owner) // stop any ticker left running
    NottiForegroundObserver.coreProvider = { NottiModule.activeCore }
    NottiModule.resetProcessWideStateForTest()
  }

  private fun newCore(): NottiCore {
    val prefs = RuntimeEnvironment.getApplication()
      .getSharedPreferences("notti_observer_test", Context.MODE_PRIVATE)
    return NottiCore(
      deviceStore = store,
      eventStore = NottiEventStore(prefs),
      apiClientFactory = { _, _, _ -> throw AssertionError("no network in this test") },
      tokenProvider = { it(null) },
      permissionRequester = { it(false) },
      logger = { },
      executor = Executor { it.run() },
      clock = { now },
      sessionGate = NottiModule.processSessionGate
    )
  }

  @Test
  fun `onStop with no live core still closes the process session gate`() {
    val coreA = newCore()
    NottiForegroundObserver.coreProvider = { coreA }
    NottiForegroundObserver.onStart(owner)
    assertTrue(NottiModule.processSessionGate.isActive)

    // RN reload invalidated core A; core B does not exist yet.
    NottiForegroundObserver.coreProvider = { null }
    NottiForegroundObserver.onStop(owner)

    assertFalse(NottiModule.processSessionGate.isActive)
  }

  @Test
  fun `heartbeat ticks every interval while started and stops after onStop`() {
    val core = newCore()
    NottiForegroundObserver.coreProvider = { core }
    NottiForegroundObserver.onStart(owner)
    assertEquals(1_000L, store.getSessionStartedAtMs())
    val looper = shadowOf(Looper.getMainLooper())

    now = 61_000L
    looper.idleFor(Duration.ofMillis(NottiCore.HEARTBEAT_INTERVAL_MS))
    assertEquals(61_000L, store.getLastForegroundAtMs())

    now = 121_000L
    looper.idleFor(Duration.ofMillis(NottiCore.HEARTBEAT_INTERVAL_MS))
    assertEquals(121_000L, store.getLastForegroundAtMs())

    now = 130_000L
    NottiForegroundObserver.onStop(owner)
    assertEquals(1, store.getSessionCount())
    assertEquals(129_000L, store.getSessionTimeMs())

    // No tick after background: nothing re-written.
    now = 999_000L
    looper.idleFor(Duration.ofMillis(NottiCore.HEARTBEAT_INTERVAL_MS * 3))
    assertNull(store.getLastForegroundAtMs())
    assertNull(store.getSessionStartedAtMs())
  }
}
