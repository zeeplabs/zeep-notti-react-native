package com.notti

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.location.Geocoder
import android.location.LocationManager
import android.os.Build
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReadableArray
import com.facebook.react.bridge.ReadableMap
import com.facebook.react.bridge.WritableMap
import com.facebook.react.modules.core.PermissionAwareActivity
import com.facebook.react.modules.core.PermissionListener
import com.google.firebase.messaging.FirebaseMessaging
import com.google.firebase.messaging.RemoteMessage
import okhttp3.OkHttpClient
import java.util.Locale
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

/**
 * Thin TurboModule entry: every Spec method (T4) delegates one line into
 * [NottiCore] (T7). The only real logic kept here is Android's own runtime
 * permission plumbing (`PermissionAwareActivity`/SDK_INT check), since
 * that's platform wiring, not the retry/tag-merge/queue business logic
 * NottiCore owns.
 */
class NottiModule(reactContext: ReactApplicationContext) :
  NativeNottiSpec(reactContext) {

  /**
   * The Activity-lifecycle hook that detects notification clicks is registered
   * once per process by [NottiInitProvider], not here: this module is lazy
   * (so on a cold start it does not exist yet when the launching Activity
   * reads its intent) and is reconstructed on every RN reload. This instance
   * only attaches itself as the relay's current emitter, for clicks that land
   * while JS is alive; a click buffered before it existed is handed to JS by
   * [getInitialNotificationClick], not replayed as an event.
   */
  private val clickEmitter: (ParsedNotification) -> Unit = { parsed ->
    emitClicked(parsed.toWritableMap())
  }

  /**
   * Fetched eagerly here rather than inside [core]'s lazy initializer:
   * `SharedPreferences`' first access on a given file loads and parses its
   * backing XML on a background thread, and any call that lands before that
   * finishes blocks waiting for it - `getDeviceId()` is a synchronous
   * TurboModule method invoked from the JS thread, so a caller reading it
   * right after startup (the documented pattern) would otherwise jank on
   * that load. Fetching it here, at module construction, starts that load as
   * early as the module exists instead of only once JS first calls
   * `initialize()`/`getDeviceId()`, giving it a head start to finish during
   * the rest of app/bundle startup. Does not eliminate the block outright -
   * only a real async read (a breaking API change: `getDeviceId(): Promise`)
   * would - but meaningfully narrows the window in practice.
   */
  private val prefs = reactApplicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

  /**
   * Persisted disk queue of push-notification events waiting to be reported.
   * Same SharedPreferences file as [NottiDeviceStore] (its own key,
   * `notti_pending_events`, lives inside the store); injected into [core] so
   * the reporting task can drain it once registration succeeds, the app
   * returns to the foreground, or connectivity returns.
   *
   * This is the companion's process-wide singleton (see `getEventStore`): the
   * detection sites fire on a cold start before this instance exists, yet the
   * reporting core must drain exactly what they enqueued - so there is one
   * store per process, not one per instance.
   */
  private val eventStore = NottiModule.getEventStore(reactApplicationContext)

  /**
   * Shared with [core]: the module itself also reads/writes the
   * `permissionRequested` flag ([requestNativePermission] /
   * [readPermissionStatus]), which is platform plumbing, not core state.
   */
  private val deviceStore = NottiDeviceStore(prefs)

  /**
   * Shared by [NottiCore] (blocking HTTP + retry backoff) and the FCM-token
   * `Task` listener below, so neither ever runs on the main looper.
   */
  private val ioExecutor: ExecutorService = Executors.newSingleThreadExecutor { runnable ->
    Thread(runnable, "notti-io").apply { isDaemon = true }
  }

  /**
   * Reverse geocoding is a blocking network call: it gets its own
   * single-thread daemon executor (instead of a new `Thread` per foreground)
   * so it never stalls registration/event reporting on [ioExecutor] and
   * concurrent foregrounds cannot pile up threads.
   */
  private val geoExecutor: ExecutorService = Executors.newSingleThreadExecutor { runnable ->
    Thread(runnable, "notti-geo").apply { isDaemon = true }
  }

  private val core: NottiCore by lazy {
    NottiCore(
      deviceStore = deviceStore,
      eventStore = eventStore,
      apiClientFactory = { appId, clientKey, baseUrl ->
        NottiApiClient(OkHttpClient(), baseUrl, appId, clientKey)
      },
      tokenProvider = { callback -> fetchFcmToken(callback) },
      permissionRequester = { callback -> requestNativePermission(callback) },
      logger = { message -> Log.e(NAME, message) },
      executor = ioExecutor,
      versionProvider = { readAppVersion() },
      deviceOsProvider = { readDeviceOs() },
      deviceModelProvider = { readDeviceModel() },
      timezoneProvider = { readTimezoneId() },
      languageProvider = { readLanguage() },
      permissionStatusProvider = { callback -> readPermissionStatus(callback) },
      hasLocationPermission = { hasLocationPermission() },
      countryProvider = { callback -> resolveCountry(callback) },
      // Routed through `activeInstance` (companion object, nulled out by
      // `invalidate()`) rather than capturing `this` directly: `registerDevice`
      // runs on `ioExecutor`, whose `shutdown()` in `invalidate()` only stops
      // *new* work from being accepted - a call already in flight at that
      // moment still completes and would otherwise emit through a module RN
      // has already torn down. Mirrors `emitNotificationReceived`'s companion
      // object bridge below.
      onDeviceIdChanged = { deviceId -> activeInstance?.emitDeviceIdChanged(deviceId) },
      sessionGate = processSessionGate
    ).also {
      ownCore = it
      activeCore = it
      // The process-lifecycle onStart for this launch usually fired before
      // this lazy core existed - replay it so the cold-start session counts.
      NottiForegroundObserver.onCoreCreated(it)
    }
  }

  /**
   * Non-null only once [core] has actually been constructed (it is lazy).
   * `@Volatile`: written on whatever thread first touches [core] (JS thread
   * on a TurboModule call, or the FCM token-refresh thread), read from
   * [invalidate] which can run on RN's own teardown thread - without it, the
   * write in [core]'s lazy initializer is not guaranteed visible to
   * [invalidate]'s read, and the `activeCore === ownCore` identity check
   * could see a stale `null` and leave a live core wired into
   * [activeCore] after this module is supposed to be torn down.
   */
  @Volatile
  private var ownCore: NottiCore? = null

  // Published only once every field above is assigned (A1): this init block
  // is deliberately the LAST thing that runs in the constructor. Publishing
  // `activeInstance = this` any earlier - e.g. in a leading `init {}` block -
  // would let another thread (NottiFirebaseMessagingService, or the
  // notification-click relay, both of which can fire concurrently with
  // construction) observe a partially-constructed instance whose `prefs`
  // field is not yet assigned, an unsafe-publication race with no compiler
  // guardrail (Kotlin's non-null `val` type does not insert a runtime check
  // on field reads of a not-yet-initialized `this`).
  init {
    NottiNotificationClickRelay.attach(clickEmitter)
    synchronized(NottiModule::class.java) { activeInstance = this }
  }

  /**
   * RN tears a module down on context destruction and on every dev reload. The
   * module used to leave its process-wide references (and, previously, a fresh
   * Activity-lifecycle listener) behind, so a single notification tap emitted
   * once per past instance. Everything this instance published is released
   * here, guarded by identity so a newer instance is never unhooked.
   */
  override fun invalidate() {
    NottiNotificationClickRelay.detach(clickEmitter)
    synchronized(NottiModule::class.java) {
      if (activeInstance === this) activeInstance = null
      if (ownCore != null && activeCore === ownCore) activeCore = null
    }
    ioExecutor.shutdown()
    geoExecutor.shutdown()
    super.invalidate()
  }

  // T9 forces a Codegen event-emit bridge onto this already-wired module:
  // NottiFirebaseMessagingService (a separate Android Service, not a
  // NottiModule subclass) has no direct access to the protected
  // emitOnNotificationReceived/emitOnNotificationClicked methods Codegen
  // generates, so a static reference to the live module instance is needed.
  // Design.md's Tech Decisions rule out RCTDeviceEventEmitter as a
  // workaround, so this is the minimal necessary bridge.
  internal fun emitReceived(payload: WritableMap) = emitOnNotificationReceived(payload)

  internal fun emitClicked(payload: WritableMap) = emitOnNotificationClicked(payload)

  internal fun emitDeviceIdChanged(deviceId: String) = emitOnDeviceIdChanged(deviceId)

  override fun initialize(appId: String?, clientKey: String?, baseUrl: String?, sdkVersion: String?) {
    core.initialize(appId.orEmpty(), clientKey.orEmpty(), baseUrl.orEmpty(), sdkVersion.orEmpty())
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
    // I7 (found in pre-release review): `.mapValues { it.value.toString() }`
    // stringified a JS number/boolean/null differently than iOS's `"\(value)"`
    // interpolation (`1.0` vs `1`, `"null"` vs `"<null>"`) - the same call
    // produced a different server-side tag value per platform. The public
    // TS type (`Record<string, string>`) already promises string-only
    // values; a non-string value is now dropped instead of coerced, matching
    // iOS's identical filter in `NottiImpl.addTags`.
    val add = tags?.toHashMap()
      ?.mapNotNull { (key, value) -> (value as? String)?.let { key to it } }
      ?.toMap() ?: emptyMap()
    core.mutateTags(add = add, remove = null)
  }

  override fun removeTags(keys: ReadableArray?) {
    val remove = keys?.toArrayList()?.map { it.toString() } ?: emptyList()
    core.mutateTags(add = null, remove = remove)
  }

  override fun setSubscription(enabled: Boolean) {
    core.setSubscription(enabled)
  }

  override fun setEmail(email: String?) {
    email?.let { core.setEmail(it) }
  }

  override fun clearEmail() {
    core.clearEmail()
  }

  override fun setPhone(phone: String?) {
    phone?.let { core.setPhone(it) }
  }

  override fun clearPhone() {
    core.clearPhone()
  }

  override fun setLocationSharingEnabled(enabled: Boolean) {
    core.setLocationSharingEnabled(enabled)
  }

  override fun getDeviceId(): String? = core.getDeviceId()

  /**
   * Hands JS the notification tap that cold-launched the process, once.
   * Pull-based on purpose: the tap is detected by [NottiInitProvider]'s
   * Activity-lifecycle hook before this module exists, and this module is
   * constructed while the JS bundle is still being evaluated - both strictly
   * before any `addEventListener('notificationClicked', …)` in a `useEffect`
   * runs, so emitting it as an event would deliver it to nobody.
   */
  override fun getInitialNotificationClick(promise: Promise?) {
    val click = NottiNotificationClickRelay.takePending()
    promise?.resolve(click?.toWritableMap())
  }

  /**
   * Reads the host app's version string once per registration (SEGTEL-01).
   * `PackageInfo.versionName` can throw if the package is absent; the SDK
   * must never crash here, so any failure resolves `null` - the sync then
   * skips entirely (SEGTEL edge case).
   */
  private fun readAppVersion(): String? = try {
    reactApplicationContext.packageManager
      .getPackageInfo(reactApplicationContext.packageName, 0)
      .versionName
  } catch (t: Throwable) {
    Log.e(NAME, "Notti: failed to read app version - ${t.message}")
    null
  }

  /**
   * Reads the OS version string (device-profile-fields DPF-01). `Build` reads
   * are plain static field accesses that cannot throw in practice, but the
   * wrap keeps the "never crash on a read failure" contract (DPF-04) uniform.
   */
  private fun readDeviceOs(): String? = try {
    Build.VERSION.RELEASE
  } catch (t: Throwable) {
    Log.e(NAME, "Notti: failed to read OS version - ${t.message}")
    null
  }

  /** Reads the device model (DPF-01); see [readDeviceOs] for the failure contract. */
  private fun readDeviceModel(): String? = try {
    Build.MODEL
  } catch (t: Throwable) {
    Log.e(NAME, "Notti: failed to read device model - ${t.message}")
    null
  }

  /** Reads the IANA timezone id (DPF-06); failure resolves `null` (DPF-09). */
  private fun readTimezoneId(): String? = try {
    java.util.TimeZone.getDefault().id
  } catch (t: Throwable) {
    Log.e(NAME, "Notti: failed to read timezone - ${t.message}")
    null
  }

  /**
   * Reads the OS language ISO 639-1 code (DPF-06) via
   * [NottiCore.normalizeLanguage] (primary subtag, legacy codes mapped,
   * `und`/empty -> `null`); failure resolves `null` (DPF-09).
   */
  private fun readLanguage(): String? = try {
    NottiCore.normalizeLanguage(Locale.getDefault().toLanguageTag())
  } catch (t: Throwable) {
    Log.e(NAME, "Notti: failed to read language - ${t.message}")
    null
  }

  /**
   * Best-effort OS push-permission state read (DPF-10): gathers the raw OS
   * signals and maps them through [NottiCore.mapPermissionStatus] (the
   * branch table and its known limitation are documented there). The
   * rationale signal needs an Activity; with none in the foreground it is
   * passed as `null`, which makes a never-requested, ungranted permission
   * resolve `null` (can't tell `notDetermined` from denied elsewhere) instead
   * of a guess. Any failure resolves `null` (omit - never fabricate).
   */
  private fun readPermissionStatus(callback: (String?) -> Unit) {
    val status = try {
      val notificationsEnabled = NotificationManagerCompat
        .from(reactApplicationContext)
        .areNotificationsEnabled()
      val sdkInt = Build.VERSION.SDK_INT
      if (sdkInt < Build.VERSION_CODES.TIRAMISU) {
        NottiCore.mapPermissionStatus(sdkInt, notificationsEnabled, false, false, null)
      } else {
        val permissionGranted = ContextCompat.checkSelfPermission(
          reactApplicationContext,
          Manifest.permission.POST_NOTIFICATIONS
        ) == PackageManager.PERMISSION_GRANTED
        val shouldShowRationale = reactApplicationContext.currentActivity?.let {
          ActivityCompat.shouldShowRequestPermissionRationale(it, Manifest.permission.POST_NOTIFICATIONS)
        }
        NottiCore.mapPermissionStatus(
          sdkInt,
          notificationsEnabled,
          permissionGranted,
          deviceStore.getPermissionRequested(),
          shouldShowRationale
        )
      }
    } catch (t: Throwable) {
      Log.e(NAME, "Notti: failed to read permission status - ${t.message}")
      null
    }
    callback(status)
  }

  /**
   * Check-only location permission gate (SEGTEL-14): true only when the host
   * app has already been granted the permission. Never prompts - the SDK only
   * reads, it never requests OS location permission.
   */
  // L3 (pre-release review round 3): a host that declares only
  // `ACCESS_FINE_LOCATION` (not `ACCESS_COARSE_LOCATION`) in its manifest -
  // a legitimate, common setup - previously failed this check silently and
  // never reported country, since `checkSelfPermission` on an undeclared
  // permission returns `PERMISSION_DENIED` regardless of what the user
  // granted. Either permission is sufficient for the country-level read.
  private fun hasLocationPermission(): Boolean =
    ContextCompat.checkSelfPermission(
      reactApplicationContext,
      Manifest.permission.ACCESS_COARSE_LOCATION
    ) == PackageManager.PERMISSION_GRANTED ||
      ContextCompat.checkSelfPermission(
        reactApplicationContext,
        Manifest.permission.ACCESS_FINE_LOCATION
      ) == PackageManager.PERMISSION_GRANTED

  /**
   * Best-effort country resolution (SEGTEL-11): reads the last known location
   * (may be a stale cached fix - acceptable for country-level granularity) and
   * reverse-geocodes it to an ISO 3166-1 alpha-2 `countryCode`. Geocoding is a
   * blocking network call, so it runs on a background thread. Any failure
   * (location unavailable, services disabled, no fix, geocode error) resolves
   * `null` - treated the same as no permission: omit, no error, no prompt.
   */
  private fun resolveCountry(callback: (String?) -> Unit) {
    val context = reactApplicationContext
    val locationManager = context.getSystemService(Context.LOCATION_SERVICE) as? LocationManager
    val location = try {
      locationManager?.getLastKnownLocation(LocationManager.NETWORK_PROVIDER)
        ?: locationManager?.getLastKnownLocation(LocationManager.GPS_PROVIDER)
    } catch (t: Throwable) {
      Log.e(NAME, "Notti: failed to read last known location - ${t.message}")
      null
    }
    if (location == null) {
      callback(null)
      return
    }
    try {
      geoExecutor.execute {
        try {
          val geocoder = Geocoder(context, Locale.US)
          @Suppress("DEPRECATION")
          val addresses = geocoder.getFromLocation(location.latitude, location.longitude, 1)
          callback(addresses?.firstOrNull()?.countryCode)
        } catch (t: Throwable) {
          Log.e(NAME, "Notti: failed to reverse-geocode location - ${t.message}")
          callback(null)
        }
      }
    } catch (e: java.util.concurrent.RejectedExecutionException) {
      // Module torn down: no country this time (treated as omit, SEGTEL-14).
      callback(null)
    }
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
          Log.e(NAME, "Notti: failed to fetch FCM token - ${e.message}")
          callback(null)
        }
    } catch (e: Exception) {
      Log.e(NAME, "Notti: failed to fetch FCM token - ${e.message}")
      callback(null)
    }
  }

  /**
   * A5 (found in pre-release review): a fixed request code let two
   * concurrent `requestPermission()` calls collide - both `PermissionListener`s
   * matched the same code, so whichever fired first consumed the result and
   * silently orphaned the other's Promise forever. Each call now gets its
   * own code so listeners can never match each other's result.
   *
   * Not fixed by this: if the hosting Activity is recreated while the OS
   * permission dialog is showing (rotation, "don't keep activities"), RN's
   * `PermissionAwareActivity` listener registry is lost with it regardless
   * of request code, and the Promise still never resolves. Solving that
   * requires persisting the pending callback outside the Activity's own
   * lifecycle (e.g. a retained Fragment / `ActivityResultContracts`), which
   * is a larger change than this pass covers - documented here rather than
   * silently left unfixed.
   */
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

    // Recorded before prompting so [readPermissionStatus] can tell "never
    // asked" (notDetermined) from "denied without rationale" (denied). Only set
    // when the prompt is actually issued - no Activity means no prompt shown.
    deviceStore.setPermissionRequested(true)
    val requestCode = nextPermissionRequestCode.getAndIncrement()
    activity.requestPermissions(
      arrayOf(Manifest.permission.POST_NOTIFICATIONS),
      requestCode,
      PermissionListener { code, _, grantResults ->
        if (code != requestCode) return@PermissionListener false
        val granted = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
        callback(granted)
        true
      }
    )
  }

  companion object {
    const val NAME = NativeNottiSpec.NAME
    private const val PREFS_NAME = "notti_prefs"

    /** See the doc-comment on [requestNativePermission] (A5). */
    private val nextPermissionRequestCode = AtomicInteger(8420)

    @Volatile
    private var activeInstance: NottiModule? = null

    @Volatile
    internal var activeCore: NottiCore? = null
      private set

    /**
     * Process-wide "foreground session open" gate shared by every core this
     * process creates: an RN reload re-creates the module/core while the app
     * stays foregrounded, and that must not open (and orphan-close) a second
     * session for the same foreground.
     */
    internal val processSessionGate = NottiCore.SessionGate()

    /**
     * I3 (found in pre-release review): callers used to build the
     * [WritableMap] (a JNI allocation) unconditionally, then discard it here
     * when no module existed yet - now the null-check happens first, before
     * any parsing/allocation is even attempted.
     */
    internal fun emitNotificationReceived(remoteMessage: RemoteMessage) {
      val instance = activeInstance ?: return
      instance.emitReceived(parseRemoteMessage(remoteMessage).toWritableMap())
    }

    /**
     * Process-wide event queue shared by every detection site and the
     * reporting core. The detection sites ([NottiFirebaseMessagingService],
     * the Activity-lifecycle click hook) fire on a COLD START - before this
     * lazy module instance (and its `prefs`/`eventStore` instance fields)
     * exists - yet the [NottiCore] that flushes must drain exactly what those
     * sites enqueued. So the store lives here, on the companion: constructed
     * once, lazily on first use, backed by whichever `Context` is available at
     * that moment (the `Application` during cold start, the react context once
     * the module exists - the same `notti_prefs` file either way, since both
     * are the same process), and never re-created per call. The instance's
     * `eventStore` field is this very singleton, so core and detection sites
     * share one store.
     */
    @Volatile
    private var eventStore: NottiEventStore? = null

    /**
     * Backing context for [eventStore], seeded as early as possible
     * ([NottiInitProvider.onCreate], then module construction) so
     * [enqueueEvent] can materialize the singleton even when called before
     * any module exists.
     */
    @Volatile
    private var eventStoreContext: Context? = null

    /**
     * Returns the process-wide [eventStore], creating it on first use with
     * [context]'s `notti_prefs` [SharedPreferences]. Safe from any thread: a
     * racing pair of calls only builds two short-lived stores, of which one
     * wins and the other is discarded - both would have read/written the same
     * disk file anyway, so no event can be lost to the loser.
     */
    internal fun getEventStore(context: Context): NottiEventStore {
      // Never retain the caller's context itself: it is a
      // ReactApplicationContext on module construction, and this static
      // would keep the whole torn-down RN context alive after a reload.
      eventStoreContext = context.applicationContext ?: context
      val existing = eventStore
      if (existing != null) return existing
      synchronized(this) {
        val current = eventStore
        if (current != null) return current
        val appContext = context.applicationContext ?: context
        return NottiEventStore(appContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE))
          .also { eventStore = it }
      }
    }

    /**
     * Detection-site entry point (T4). Enqueues a received/opened/clicked event into
     * the process-wide [eventStore], then opportunistically asks the live core
     * (if one exists) to flush it - a no-op on a cold start, where the core is
     * not constructed yet and the flush is simply deferred to the next
     * network-available / foreground / registration-success trigger.
     *
     * Callers are [NottiFirebaseMessagingService] (foreground receive) and
     * [NottiActivityLifecycleListener] (click), both of which run with an
     * available `applicationContext` long before this lazy module exists;
     * [eventStoreContext] was seeded by [NottiInitProvider] at process start,
     * so the singleton is created here if a detection site somehow runs first.
     */
    internal fun enqueueEvent(notificationId: String, deliveryId: String, type: String) {
      val store = eventStore ?: getEventStore(eventStoreContext ?: return)
      store.enqueue(notificationId, deliveryId, type)
      activeCore?.onNetworkAvailable()
    }

    /** Test-only: companion statics are process-wide and outlive a single test case. */
    internal fun resetProcessWideStateForTest() {
      synchronized(NottiModule::class.java) {
        activeInstance = null
        activeCore = null
      }
      processSessionGate.close()
      eventStore = null
      eventStoreContext = null
    }

    /** Test-only: swap in a store backed by an in-memory [SharedPreferences] fake. */
    internal fun setEventStoreForTest(store: NottiEventStore) {
      eventStore = store
    }

  }
}
