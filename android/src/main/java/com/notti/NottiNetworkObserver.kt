package com.notti

import android.net.ConnectivityManager
import android.net.Network
import android.util.Log

/**
 * Watches for the device regaining network connectivity and triggers an
 * offline-event flush the moment a usable connection appears (design.md
 * offline event queue). Events enqueued while offline ([NottiEventStore]) are
 * drained as soon as the network is back, instead of waiting for the next
 * launch, foreground, or registration - the Android mirror of iOS'
 * `NottiNetworkObserver`.
 *
 * Registered exactly once per process from [NottiInitProvider.onCreate]
 * (which runs before any Activity, on a cold start, long before the lazy
 * [NottiModule] exists), so the flush reaches the live core through the
 * [NottiModule.activeCore] static and is a safe no-op until that core exists.
 *
 * Uses [ConnectivityManager.registerDefaultNetworkCallback], which only
 * reports the default network and only while it has the INTERNET capability -
 * so [NetworkCallback.onAvailable] is a sufficient "network is usable" signal
 * and no [ConnectivityManager.NetworkCapabilities] inspection is needed.
 *
 * `onNetworkAvailable` is injectable so tests can drive the observer without a
 * real [ConnectivityManager]; the production default hands the flush to the
 * core, which dispatches it onto its own executor (this callback can fire on a
 * binder thread, and the flush is blocking HTTP - see [NottiCore.onNetworkAvailable]).
 */
class NottiNetworkObserver(
  private val connectivityManager: ConnectivityManager,
  private val onNetworkAvailable: () -> Unit = { NottiModule.activeCore?.onNetworkAvailable() }
) {

  private val callback = object : ConnectivityManager.NetworkCallback() {
    override fun onAvailable(network: Network) {
      onNetworkAvailable()
    }
  }

  /**
   * Starts monitoring. Registration is wrapped so a [ConnectivityManager] that
   * rejects the callback (missing permission, Robolectric-less stub) can never
   * take the host app down (spec SDK-03 crash safety) - the worst case is a
   * missing offline-event flush trigger, which the foreground observer already
   * covers.
   */
  fun register() {
    try {
      connectivityManager.registerDefaultNetworkCallback(callback)
    } catch (t: Throwable) {
      Log.e(NottiModule.NAME, "Notti: could not register the network observer - ${t.message}")
    }
  }
}