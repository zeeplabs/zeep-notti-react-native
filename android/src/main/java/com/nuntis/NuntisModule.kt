package com.nuntis

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReadableArray
import com.facebook.react.bridge.ReadableMap
import com.facebook.react.bridge.WritableMap
import com.facebook.react.modules.core.PermissionAwareActivity
import com.facebook.react.modules.core.PermissionListener
import com.google.firebase.messaging.FirebaseMessaging
import okhttp3.OkHttpClient
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Thin TurboModule entry: every Spec method (T4) delegates one line into
 * [NuntisCore] (T7). The only real logic kept here is Android's own runtime
 * permission plumbing (`PermissionAwareActivity`/SDK_INT check), since
 * that's platform wiring, not the retry/tag-merge/queue business logic
 * NuntisCore owns.
 */
class NuntisModule(reactContext: ReactApplicationContext) :
  NativeNuntisSpec(reactContext) {

  /**
   * The Activity-lifecycle hook that detects notification clicks is registered
   * once per process by [NuntisInitProvider], not here: this module is lazy
   * (so on a cold start it does not exist yet when the launching Activity
   * reads its intent) and is reconstructed on every RN reload. This instance
   * only attaches itself as the relay's current emitter, for clicks that land
   * while JS is alive; a click buffered before it existed is handed to JS by
   * [getInitialNotificationClick], not replayed as an event.
   */
  private val clickEmitter: (ParsedNotification) -> Unit = { parsed ->
    emitClicked(parsed.toWritableMap())
  }

  init {
    synchronized(NuntisModule::class.java) { activeInstance = this }
    NuntisNotificationClickRelay.attach(clickEmitter)
  }

  /**
   * Shared by [NuntisCore] (blocking HTTP + retry backoff) and the FCM-token
   * `Task` listener below, so neither ever runs on the main looper.
   */
  private val ioExecutor: ExecutorService = Executors.newSingleThreadExecutor { runnable ->
    Thread(runnable, "nuntis-io").apply { isDaemon = true }
  }

  private val core: NuntisCore by lazy {
    NuntisCore(
      deviceStore = NuntisDeviceStore(
        reactApplicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
      ),
      apiClientFactory = { appId, clientKey, baseUrl ->
        NuntisApiClient(OkHttpClient(), baseUrl, appId, clientKey)
      },
      tokenProvider = { callback -> fetchFcmToken(callback) },
      permissionRequester = { callback -> requestNativePermission(callback) },
      logger = { message -> Log.e(NAME, message) },
      executor = ioExecutor
    ).also {
      ownCore = it
      activeCore = it
    }
  }

  /** Non-null only once [core] has actually been constructed (it is lazy). */
  private var ownCore: NuntisCore? = null

  /**
   * RN tears a module down on context destruction and on every dev reload. The
   * module used to leave its process-wide references (and, previously, a fresh
   * Activity-lifecycle listener) behind, so a single notification tap emitted
   * once per past instance. Everything this instance published is released
   * here, guarded by identity so a newer instance is never unhooked.
   */
  override fun invalidate() {
    NuntisNotificationClickRelay.detach(clickEmitter)
    synchronized(NuntisModule::class.java) {
      if (activeInstance === this) activeInstance = null
      if (ownCore != null && activeCore === ownCore) activeCore = null
    }
    ioExecutor.shutdown()
    super.invalidate()
  }

  // T9 forces a Codegen event-emit bridge onto this already-wired module:
  // NuntisFirebaseMessagingService (a separate Android Service, not a
  // NuntisModule subclass) has no direct access to the protected
  // emitOnNotificationReceived/emitOnNotificationClicked methods Codegen
  // generates, so a static reference to the live module instance is needed.
  // Design.md's Tech Decisions rule out RCTDeviceEventEmitter as a
  // workaround, so this is the minimal necessary bridge.
  internal fun emitReceived(payload: WritableMap) = emitOnNotificationReceived(payload)

  internal fun emitClicked(payload: WritableMap) = emitOnNotificationClicked(payload)

  override fun initialize(appId: String?, clientKey: String?, baseUrl: String?) {
    core.initialize(appId.orEmpty(), clientKey.orEmpty(), baseUrl.orEmpty())
  }

  override fun requestPermission(promise: Promise?) {
    core.requestPermission { granted -> promise?.resolve(granted) }
  }

  override fun login(externalUserId: String?) {
    externalUserId?.let { core.login(it) }
  }

  override fun logout() {
    core.logout()
  }

  override fun addTags(tags: ReadableMap?) {
    val add = tags?.toHashMap()?.mapValues { it.value.toString() } ?: emptyMap()
    core.mutateTags(add = add, remove = null)
  }

  override fun removeTags(keys: ReadableArray?) {
    val remove = keys?.toArrayList()?.map { it.toString() } ?: emptyList()
    core.mutateTags(add = null, remove = remove)
  }

  override fun setSubscription(enabled: Boolean) {
    core.setSubscription(enabled)
  }

  /**
   * Hands JS the notification tap that cold-launched the process, once.
   * Pull-based on purpose: the tap is detected by [NuntisInitProvider]'s
   * Activity-lifecycle hook before this module exists, and this module is
   * constructed while the JS bundle is still being evaluated - both strictly
   * before any `addEventListener('notificationClicked', …)` in a `useEffect`
   * runs, so emitting it as an event would deliver it to nobody.
   */
  override fun getInitialNotificationClick(promise: Promise?) {
    val click = NuntisNotificationClickRelay.takePending()
    promise?.resolve(click?.toWritableMap())
  }

  /**
   * Fetches the current FCM token via `FirebaseMessaging.getInstance().token`
   * (Play Services Tasks API, asynchronous). Mirrors SDK-04's crash-safety
   * contract for a missing native push prerequisite (no Firebase app
   * configured / no `google-services.json`): any failure - synchronous
   * (Firebase not initialized) or asynchronous (`addOnFailureListener`) - is
   * logged and resolves the callback with `null`, never throws.
   *
   * Both listeners take [ioExecutor] explicitly: the no-executor overloads
   * run on the main looper, which would put the whole registration path
   * (blocking OkHttp call + retry backoff) on the UI thread.
   */
  private fun fetchFcmToken(callback: (String?) -> Unit) {
    try {
      FirebaseMessaging.getInstance().token
        .addOnSuccessListener(ioExecutor) { token -> callback(token) }
        .addOnFailureListener(ioExecutor) { e ->
          Log.e(NAME, "Nuntis: failed to fetch FCM token - ${e.message}")
          callback(null)
        }
    } catch (e: Exception) {
      Log.e(NAME, "Nuntis: failed to fetch FCM token - ${e.message}")
      callback(null)
    }
  }

  private fun requestNativePermission(callback: (Boolean) -> Unit) {
    // Below Android 13, no runtime permission exists to request (P2-AC4).
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
      callback(true)
      return
    }

    val activity = reactApplicationContext.currentActivity as? PermissionAwareActivity
    if (activity == null) {
      callback(false)
      return
    }

    activity.requestPermissions(
      arrayOf(Manifest.permission.POST_NOTIFICATIONS),
      PERMISSION_REQUEST_CODE,
      PermissionListener { requestCode, _, grantResults ->
        if (requestCode != PERMISSION_REQUEST_CODE) return@PermissionListener false
        val granted = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
        callback(granted)
        true
      }
    )
  }

  companion object {
    const val NAME = NativeNuntisSpec.NAME
    private const val PREFS_NAME = "nuntis_prefs"
    private const val PERMISSION_REQUEST_CODE = 8420

    @Volatile
    private var activeInstance: NuntisModule? = null

    @Volatile
    internal var activeCore: NuntisCore? = null
      private set

    internal fun emitNotificationReceived(payload: WritableMap) {
      activeInstance?.emitReceived(payload)
    }

  }
}
