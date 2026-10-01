package com.notti

import android.app.Application
import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.net.ConnectivityManager
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner

/**
 * Zero-integration-code process-start hook: a manifest-declared
 * [ContentProvider]'s `onCreate` runs before `Application.onCreate` finishes
 * and, crucially, before any Activity is created - which is what the
 * cold-start notification-click path (spec P3-AC7) needs, since
 * [NottiModule] is a lazy TurboModule that does not exist yet when the
 * launching Activity reads its intent. Same mechanism `androidx.startup` and
 * `react-native-firebase` use.
 *
 * It only installs the SDK's process-start hooks - the notification-click
 * detector, the app-foreground observer that resumes registration (spec
 * SDK-05), and the network-reconnect observer that flushes the offline event
 * queue (T4) - and seeds the process-wide event store these sites write to.
 * No SDK work, no network, nothing that could slow or break host app startup.
 */
class NottiInitProvider : ContentProvider() {

  override fun onCreate(): Boolean {
    val application = context?.applicationContext as? Application
    if (application == null) {
      Log.e(NottiModule.NAME, "Notti: no Application context at startup - notification clicks from a cold start will not be detected")
      return false
    }
    NottiActivityLifecycleListener.registerOnce(application)

    // Seed the process-wide event store here: the detection sites and the
    // network observer below fire before the lazy module exists, and this is
    // the earliest point a Context is available to back the store.
    NottiModule.getEventStore(application)

    // Flush the queued event store when connectivity returns - the reporting
    // path for events enqueued while offline (T4). Registered once per
    // process; the observer itself swallows any rejection (SDK-03).
    val connectivityManager =
      application.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
    if (connectivityManager != null) {
      NottiNetworkObserver(connectivityManager).register()
    }

    // ProcessLifecycleOwner is itself set up by androidx.startup's own
    // ContentProvider, whose creation order relative to this one is not
    // defined; posting to the main looper puts this after every provider and
    // after Application.onCreate, and still ahead of the first Activity start.
    Handler(Looper.getMainLooper()).post {
      try {
        ProcessLifecycleOwner.get().lifecycle.addObserver(NottiForegroundObserver)
      } catch (t: Throwable) {
        Log.e(NottiModule.NAME, "Notti: could not observe app foreground - ${t.message}")
      }
    }
    return true
  }

  override fun query(
    uri: Uri,
    projection: Array<out String>?,
    selection: String?,
    selectionArgs: Array<out String>?,
    sortOrder: String?
  ): Cursor? = null

  override fun getType(uri: Uri): String? = null

  override fun insert(uri: Uri, values: ContentValues?): Uri? = null

  override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0

  override fun update(
    uri: Uri,
    values: ContentValues?,
    selection: String?,
    selectionArgs: Array<out String>?
  ): Int = 0
}

/**
 * App-level foreground signal (whole process, not per-Activity). Registration
 * gives up after `NottiApiClient`'s 5-attempt backoff; without this the
 * device would stay unregistered until the process is killed. [NottiCore]
 * itself decides whether a retry is actually warranted. `onStop` is the
 * missing background hook (SEGTEL-06): [NottiCore.onAppBackgrounded] ends the
 * current session and enqueues its aggregate PATCH.
 *
 * While started it also ticks a foreground heartbeat every
 * [NottiCore.HEARTBEAT_INTERVAL_MS] on the main looper (SEGTEL-08: the "last
 * known foreground timestamp" used to close a session orphaned by a kill).
 * The ticker reads [NottiModule.activeCore] on every tick, so it keeps working
 * when the lazy core is only created after `onStart` (the usual cold start).
 */
internal object NottiForegroundObserver : DefaultLifecycleObserver {
  private val mainHandler by lazy { Handler(Looper.getMainLooper()) }

  /** Where the callbacks/ticker find the live core. Test seam; production never reassigns it. */
  @Volatile
  internal var coreProvider: () -> NottiCore? = { NottiModule.activeCore }

  private val heartbeat = object : Runnable {
    override fun run() {
      coreProvider()?.recordForegroundHeartbeat()
      mainHandler.postDelayed(this, NottiCore.HEARTBEAT_INTERVAL_MS)
    }
  }

  override fun onStart(owner: LifecycleOwner) {
    coreProvider()?.onAppForegrounded()
    mainHandler.removeCallbacks(heartbeat)
    mainHandler.postDelayed(heartbeat, NottiCore.HEARTBEAT_INTERVAL_MS)
  }

  override fun onStop(owner: LifecycleOwner) {
    mainHandler.removeCallbacks(heartbeat)
    handleProcessBackground(coreProvider(), NottiModule.processSessionGate)
  }

  /**
   * Closes the process-wide session gate even when no core is live: an RN
   * reload invalidates core A and the user can background before core B
   * exists. Left open, the gate would make core B's foreground a no-op (no
   * new session) and the old session would later be closed counting the
   * whole background interval. The orphaned session itself is closed by the
   * next session start at its last heartbeat (SEGTEL-08).
   */
  internal fun handleProcessBackground(core: NottiCore?, gate: NottiCore.SessionGate) {
    gate.close()
    core?.onAppBackgrounded()
  }

  /**
   * Cold-start session fix: [NottiModule]'s core is lazy, so on a normal
   * launch `onStart` above fires while [NottiModule.activeCore] is still null
   * and the launch session was never counted. Called right after a core is
   * created; if the process is already STARTED, the missed foreground is
   * replayed. Posted to the main looper (lifecycle state is main-thread
   * owned); a double signal (this + a late `onStart`) is deduped by the
   * core's session gate.
   */
  internal fun onCoreCreated(core: NottiCore) {
    try {
      mainHandler.post {
        syncWithCurrentState(core) {
          ProcessLifecycleOwner.get().lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)
        }
      }
    } catch (t: Throwable) {
      Log.e(NottiModule.NAME, "Notti: could not sync the initial foreground state - ${t.message}")
    }
  }

  internal fun syncWithCurrentState(core: NottiCore, isProcessStarted: () -> Boolean) {
    try {
      if (isProcessStarted()) core.onAppForegrounded()
    } catch (t: Throwable) {
      Log.e(NottiModule.NAME, "Notti: could not sync the initial foreground state - ${t.message}")
    }
  }
}
