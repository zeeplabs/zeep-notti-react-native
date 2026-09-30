package com.notti

import android.content.Context
import android.net.ConnectivityManager
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowNetwork

/**
 * NottiNetworkObserver talks to ConnectivityManager, whose android.jar stub
 * throws on the plain JVM - Robolectric provides real framework classes, scoped
 * narrowly per the class-level [RunWith] exactly like
 * NottiFirebaseMessagingServiceTest. The observer's flush trigger is injected
 * (rather than exercising a real NottiCore), matching how NottiCoreTest drives
 * the core through injected fakes: the production default
 * `NottiModule.activeCore?.onNetworkAvailable()` is a one-line bridge covered
 * by NottiModuleTest/NottiCoreTest.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class NottiNetworkObserverTest {

  @Test
  fun `register captures a default-network callback and an available network triggers the flush`() {
    val connectivityManager = getConnectivityManager()
    var flushTriggers = 0
    val observer = NottiNetworkObserver(connectivityManager) { flushTriggers++ }

    observer.register()

    // ShadowConnectivityManager records the callback `registerDefaultNetworkCallback`
    // registered; drive the flush by invoking onAvailable on it.
    val callback = registeredCallback(connectivityManager)
    callback.onAvailable(ShadowNetwork.newInstance(0))

    assertEquals(1, flushTriggers)
  }

  @Test
  fun `onLost and onUnavailable do not trigger the flush`() {
    val connectivityManager = getConnectivityManager()
    var flushTriggers = 0
    val observer = NottiNetworkObserver(connectivityManager) { flushTriggers++ }

    observer.register()
    val callback = registeredCallback(connectivityManager)

    // Only an available default network means "connectivity is back" - losing
    // it or having none must not fire the flush (the transition out of the
    // offline state is what matters).
    callback.onLost(ShadowNetwork.newInstance(0))
    callback.onUnavailable()

    assertEquals(0, flushTriggers)
  }

  private fun getConnectivityManager(): ConnectivityManager =
    RuntimeEnvironment.getApplication()
      .getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

  private fun registeredCallback(connectivityManager: ConnectivityManager): ConnectivityManager.NetworkCallback {
    val callbacks = shadowOf(connectivityManager).getNetworkCallbacks()
    return requireNotNull(callbacks.single())
  }
}