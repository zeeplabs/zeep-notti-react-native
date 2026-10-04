package com.notti

import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.concurrent.Executor
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Orchestrates init, device registration, token refresh, permission
 * requests, and tag/external-id/subscription mutations (design.md
 * NottiCore). `NottiApiClient`/`NottiDeviceStore`/`NottiEventStore` are
 * constructor-injected so they can be faked in tests; `tokenProvider` and
 * `permissionRequester`
 * abstract the platform-specific push-token fetch and OS permission prompt
 * (owned by the concrete wiring in T8/NottiModule — e.g. the Android <13
 * auto-grant behavior from spec P2-AC4 lives in whatever concrete
 * `permissionRequester` T8 wires in, not here). `tokenProvider` is
 * callback-based rather than a plain synchronous getter, since the real FCM
 * token fetch (`FirebaseMessaging.getInstance().token`) is an asynchronous
 * Play Services `Task`, not a synchronous call.
 *
 * ## Threading
 *
 * Every call that can reach [NottiApiClient] (blocking OkHttp `execute()`
 * plus the retry backoff's `Thread.sleep`) is handed to [executor] and never
 * runs on the caller's thread: the TurboModule methods below are invoked from
 * the RN JS thread, and the FCM token listener can land on the main looper —
 * doing socket I/O there throws `NetworkOnMainThreadException` (an uncaught
 * `RuntimeException`, not an `IOException`) or ANRs for the full retry window.
 * The default executor is single-threaded, which additionally serializes all
 * outgoing calls (spec P3-AC8) on top of the explicit [mutationLock].
 *
 * Public methods therefore return immediately (they are `void`/callback-based
 * in the Spec, so no caller is waiting on a return value); results reach JS
 * via the injected callbacks, which is safe from any thread — TurboModule
 * `Promise` resolution is thread-agnostic (it marshals onto the JS queue
 * itself), it does not require the main/UI thread.
 */
class NottiCore(
  private val deviceStore: NottiDeviceStore,
  private val eventStore: NottiEventStore,
  private val apiClientFactory: (appId: String, clientKey: String, baseUrl: String) -> NottiApiClient,
  private val tokenProvider: (callback: (token: String?) -> Unit) -> Unit,
  private val permissionRequester: (callback: (granted: Boolean) -> Unit) -> Unit,
  private val platform: String = "android",
  private val logger: (message: String) -> Unit = {},
  private val executor: Executor = newDefaultExecutor(),
  /**
   * Returns the host app's current version string (`PackageInfo.versionName`
   * on Android, `CFBundleShortVersionString` on iOS), or `null` on failure.
   * Reads once per registration and is diffed against the last successfully
   * synced value (`deviceStore.getAppVersion()`) - a change enqueues a device
   * PATCH (SEGTEL-01/02/03). Injected so [NottiCore] stays `Context`-free and
   * unit-testable; the default `{ null }` makes the sync a no-op.
   */
  private val versionProvider: () -> String? = { null },
  /**
   * Reads the device's OS version (Android `Build.VERSION.RELEASE`, iOS
   * `UIDevice.current.systemVersion`), or `null` on failure (DPF-01/04).
   * Injected so [NottiCore] stays `Context`-free; the default `{ null }`
   * makes that field's sync a no-op.
   */
  private val deviceOsProvider: () -> String? = { null },
  /**
   * Reads the device model (Android `Build.MODEL`, iOS `utsname.machine`),
   * or `null` on failure (DPF-01/04). See [deviceOsProvider].
   */
  private val deviceModelProvider: () -> String? = { null },
  /**
   * Reads the IANA timezone id (Android `TimeZone.getDefault().id`, iOS
   * `TimeZone.current.identifier`), or `null` on failure (DPF-06/09).
   */
  private val timezoneProvider: () -> String? = { null },
  /**
   * Reads the OS language (Android: [normalizeLanguage] over
   * `Locale.getDefault().toLanguageTag()`, iOS `Locale.current.languageCode`),
   * or `null` on failure/undetermined (DPF-06/09).
   */
  private val languageProvider: () -> String? = { null },
  /**
   * Best-effort, async OS push-permission state read (DPF-10): resolves with
   * one of `granted`/`denied`/`notDetermined` (plus `provisional` on iOS) or
   * `null` on an unknown/transitional state or read failure - `null` omits the
   * field, never fabricates a value (DPF edge case). Injected so [NottiCore]
   * stays `Context`-free; the default no-op provider returns `null` (omit).
   * Follows the async `countryProvider` callback shape, since the real OS
   * read (iOS `UNUserNotificationCenter.getNotificationSettings`) is
   * callback-based.
   */
  private val permissionStatusProvider: (callback: (String?) -> Unit) -> Unit = { cb -> cb(null) },
  /**
   * Check-only OS location permission gate (SEGTEL-12/14): true only when the
   * host app has already been granted location permission. Never prompts - the
   * SDK only reads, it never requests (SEGTEL-14). Injected so [NottiCore]
   * stays `Context`-free and unit-testable; the default `{ false }` means the
   * country read is skipped unless the integrator explicitly opts in and wires
   * the real permission check.
   */
  private val hasLocationPermission: () -> Boolean = { false },
  /**
   * Best-effort, async country resolution (SEGTEL-11): reverse-geocodes the
   * device's last known fix to an ISO 3166-1 alpha-2 code, or invokes the
   * callback with `null` on any failure. Injected so [NottiCore] stays
   * `Context`-free; the default no-op provider returns `null` (omit).
   */
  private val countryProvider: (callback: (String?) -> Unit) -> Unit = { cb -> cb(null) },
  /**
   * Notified from [registerDevice] whenever the persisted device id actually
   * changes (first assignment, reinstall, or a re-registration that lands a
   * different id) - never on an idempotent re-register that returns the same
   * id already cached. See ADR-001
   * (docs/adr/001-expose-device-id-getter-and-change-event.md).
   */
  private val onDeviceIdChanged: (String) -> Unit = {},
  /**
   * Wall clock, read on the caller's thread at the lifecycle callback (never
   * later on the executor) so a busy executor cannot stretch a session.
   * Injected for deterministic tests.
   */
  private val clock: () -> Long = { System.currentTimeMillis() },
  /**
   * Whether a foreground session is open in THIS process. Production passes
   * the process-wide [NottiModule.processSessionGate] so a core re-created by
   * an RN reload (or the cold-start sync racing the lifecycle observer) never
   * opens a second session for the same foreground; tests get a fresh gate.
   */
  private val sessionGate: SessionGate = SessionGate()
) {

  /** See [sessionGate]. Thread-safe; flips on the lifecycle callback's thread. */
  class SessionGate {
    private val active = AtomicBoolean(false)
    internal val isActive: Boolean get() = active.get()
    internal fun tryOpen(): Boolean = active.compareAndSet(false, true)
    internal fun close() = active.set(false)
  }

  companion object {
    /**
     * Bound on the pending-mutation queue below: registration can legitimately
     * never complete (no push token, permanent 4xx), and an unbounded queue in
     * that state would grow for the life of the process.
     */
    private const val MAX_PENDING_MUTATIONS = 32

    /**
     * Upper bound on the time credited to a session orphaned by a kill/crash
     * (no background transition), applied on top of the heartbeat estimate
     * (SEGTEL-08). With the foreground heartbeat
     * ([NottiForegroundObserver], every [HEARTBEAT_INTERVAL_MS]) the estimate
     * is normally within one interval of the real end; this cap only guards
     * against a corrupt/clock-jumped heartbeat inflating `session_time`
     * without limit. 12h: longer than any realistic single foreground stint
     * of a mobile app, short enough to bound the damage of a bad value.
     */
    internal const val MAX_ORPHAN_SESSION_MS = 12L * 60 * 60 * 1000

    /**
     * Cadence of the foreground heartbeat that persists the "last known
     * foreground timestamp" used to close orphaned sessions (SEGTEL-08).
     * One SharedPreferences write per minute while foregrounded; max error of
     * an orphaned session's estimate is one interval.
     */
    internal const val HEARTBEAT_INTERVAL_MS = 60_000L

    private const val KEY_SESSION = "session"
    private const val KEY_COUNTRY = "country"
    private const val KEY_APP_VERSION = "appVersion"
    private const val KEY_DEVICE_OS = "deviceOs"
    private const val KEY_DEVICE_MODEL = "deviceModel"
    private const val KEY_SDK_VERSION = "sdkVersion"
    private const val KEY_TIMEZONE_ID = "timezoneId"
    private const val KEY_LANGUAGE = "language"
    private const val KEY_PERMISSION_STATUS = "permissionStatus"
    private const val KEY_EMAIL = "email"
    private const val KEY_PHONE = "phone"

    /**
     * Single-threaded so blocking HTTP work never piles up more than one
     * thread and outgoing calls stay serialized; daemon so a pending retry
     * backoff can never hold the host process alive.
     */
    @JvmStatic
    fun newDefaultExecutor(): Executor = Executors.newSingleThreadExecutor { runnable ->
      Thread(runnable, "notti-io").apply { isDaemon = true }
    }

    /** API 33 (Android 13, TIRAMISU): first level with a runtime `POST_NOTIFICATIONS` permission. */
    private const val API_TIRAMISU = 33

    /**
     * Pure mapping of the Android OS notification state to `permission_status`
     * (DPF-10), kept `Context`-free so every branch is unit-testable; the
     * platform reads live in `NottiModule.readPermissionStatus`.
     *
     * - API < 33: no runtime permission exists - enabled -> `granted`, else `denied`.
     * - API >= 33, permission granted: notifications enabled -> `granted`;
     *   disabled -> `denied` (user blocked the app in Settings after granting).
     * - API >= 33, permission not granted: [shouldShowRationale] `true` ->
     *   `denied` (the user already said no once); requested by the SDK before
     *   ([permissionRequestedBefore] true) -> `denied` (permanently denied, the
     *   OS stops offering a rationale); never requested by the SDK and
     *   rationale known `false` (an Activity was available) -> `notDetermined`;
     *   never requested and rationale unknown -> `null`.
     *
     * [shouldShowRationale] is `null` when no Activity was available to ask.
     * Without it, a never-requested permission cannot be told apart from one
     * denied through another library, so the field is omitted (`null`) rather
     * than fabricated as `notDetermined` - the next read with an Activity in
     * the foreground (session start, `requestPermission`) resolves it.
     *
     * Known limitations:
     * - [permissionRequestedBefore] only tracks prompts shown by this SDK. A
     *   permission requested through another library and then permanently
     *   denied (no rationale) reads as `notDetermined`, since the OS exposes no
     *   "was ever asked" signal.
     * - A prompt shown by the SDK's `requestPermission` and dismissed without
     *   a choice (back/outside tap) leaves the permission ungranted with no
     *   rationale and [permissionRequestedBefore] set, so it reads as `denied`
     *   although the user never answered - the OS does not distinguish the two.
     */
    @JvmStatic
    internal fun mapPermissionStatus(
      sdkInt: Int,
      notificationsEnabled: Boolean,
      permissionGranted: Boolean,
      permissionRequestedBefore: Boolean,
      shouldShowRationale: Boolean?
    ): String? {
      if (sdkInt < API_TIRAMISU) return if (notificationsEnabled) "granted" else "denied"
      if (permissionGranted) return if (notificationsEnabled) "granted" else "denied"
      return when {
        shouldShowRationale == true -> "denied"
        permissionRequestedBefore -> "denied"
        shouldShowRationale == false -> "notDetermined"
        // No Activity to ask for the rationale: can't tell - omit, never fabricate.
        else -> null
      }
    }

    /**
     * Normalizes a BCP 47 tag (`Locale.toLanguageTag()`) to the bare ISO 639-1
     * primary subtag sent as `language` (DPF-06): `pt-BR` -> `pt`. Legacy
     * Java codes are mapped to their current ones (`iw`->`he`, `in`->`id`,
     * `ji`->`yi`) so both platforms agree; an empty or undetermined (`und`)
     * tag yields `null`, which omits the field (DPF-09).
     */
    @JvmStatic
    internal fun normalizeLanguage(tag: String?): String? {
      val primary = tag?.trim()?.substringBefore('-')?.lowercase(Locale.ROOT) ?: return null
      if (primary.isEmpty() || primary == "und") return null
      return when (primary) {
        "iw" -> "he"
        "in" -> "id"
        "ji" -> "yi"
        else -> primary
      }
    }
  }

  private var appId: String? = null
  private var clientKey: String? = null
  private var baseUrl: String? = null
  @Volatile
  private var apiClient: NottiApiClient? = null

  /**
   * The SDK package version, passed from JS at `initialize` (the package
   * manifest is the single source of truth). Holds `null` when not provided
   * or empty - the field is then omitted from the payload. Consumed by
   * `sdkVersionProvider` (DPF-01..04).
   */
  @Volatile
  private var sdkVersion: String? = null

  /**
   * Feeds the `sdk_version` profile field. Not a constructor-injected
   * platform read (unlike `deviceOsProvider` etc.): `sdk_version` is core
   * state set by `initialize`, so this property reads the stored value -
   * "native stores it and treats it as a normal diffed profile field"
   * (design.md P1). Reading the field at call time (not capturing the value)
   * means a second `initialize` with a different version is picked up.
   */
  private val sdkVersionProvider: () -> String? = { sdkVersion }

  /**
   * Where the device's registration stands right now. Drives both the
   * app-foreground retry (spec SDK-05: after the 5-attempt backoff is
   * exhausted the SDK stops "until the next app foreground or the next
   * token-refresh event") and the guard that keeps repeated foregrounds from
   * stacking registration attempts.
   */
  private enum class RegistrationState { NOT_STARTED, IN_FLIGHT, REGISTERED, FAILED }

  @Volatile
  private var registrationState = RegistrationState.NOT_STARTED
  private val mutationLock = Any()

  /**
   * Mutations issued before registration completes (`Notti.initialize()`
   * immediately followed by `login`/`addTags`/`requestPermission`, which is
   * the normal app-startup shape) have no device id or token to PATCH yet.
   * Dropping them - as this used to - loses them permanently with nothing to
   * retry, so they are held here and flushed in call order once registration
   * succeeds. In-memory only, per the spec's Edge Case: a queued call is
   * dropped on process death rather than replayed later with stale state.
   * Guarded by [mutationLock].
   */
  private val pendingMutations = ArrayDeque<PendingMutation>()

  // A9 (found in pre-release review): this used to capture `apiClient` at
  // enqueue time. A queued mutation flushed after a *second* `initialize()`
  // with a different appId/baseUrl would then run against the stale client -
  // the old backend/app - instead of the one the device is actually
  // registered against now. iOS's equivalent (`NottiCore.swift`'s
  // `PendingMutation`) never captured a client at all; this now reads
  // `apiClient` at run/flush time instead, matching that.
  //
  // `coalesceKey` (telemetry only: session / country / appVersion): a queued
  // telemetry mutation is REPLACED by a newer one with the same key instead of
  // appended, so telemetry occupies at most one slot per key and never evicts
  // a queued login/tag/subscription call from the bounded queue. `null` =
  // ordinary mutation, kept in call order and subject to the cap.
  private class PendingMutation(
    val operation: String,
    val coalesceKey: String? = null,
    val work: (client: NottiApiClient, deviceId: String, token: String) -> Unit
  )

  /** Guards the session read-modify-write sequence on [deviceStore]. */
  private val sessionLock = Any()

  /** Dedupes flush scheduling: at most one flush task queued at a time. */
  private val flushScheduled = AtomicBoolean(false)

  /**
   * Dedupes country-clear retry scheduling (M5, pre-release review round 3):
   * without this, [onNetworkAvailable] (fired per received push, per
   * `onAvailable`) and every other [retryPendingCountryClear] caller queued a
   * brand-new task each time, unlike [scheduleFlush]'s dedup. A persistent
   * 4xx or a flapping connection stacked tasks on the single-thread
   * [executor], each retrying up to 5 times, pinning it behind country-clear
   * attempts instead of real work. Mirrors iOS' `flushScheduled` guard
   * around `attemptPendingCountryClear`.
   */
  private val countryClearScheduled = AtomicBoolean(false)

  fun initialize(appId: String, clientKey: String, baseUrl: String, sdkVersion: String? = null) {
    if (appId.isBlank() || clientKey.isBlank() || baseUrl.isBlank()) {
      logger("Notti.initialize: appId, clientKey, or baseUrl is missing/empty - skipping registration")
      return
    }

    // Blank/empty sdkVersion (resolution failure on the JS side) is stored as
    // null so the `sdk_version` field is omitted from the payload, never sent
    // as an empty string.
    this.sdkVersion = sdkVersion?.takeIf { it.isNotBlank() }

    // Validated and normalized exactly once, here (SDK-03 crash safety): a
    // scheme-less or otherwise malformed host would otherwise only blow up
    // later, deep inside `Request.Builder().url(...)`, as an
    // IllegalArgumentException on whatever thread the call landed on. A
    // trailing slash is also stripped here, since every path is built as
    // "$baseUrl/v1/..." and would otherwise produce a "//v1/..." request path.
    val normalizedBaseUrl = baseUrl.toHttpUrlOrNull()?.toString()?.trimEnd('/')
    if (normalizedBaseUrl == null) {
      logger(
        "Notti.initialize: baseUrl \"$baseUrl\" is not a valid http(s) URL " +
          "(expected e.g. https://push.example.com) - SDK stays disabled, no registration attempted"
      )
      return
    }

    // Repeat call with identical args in the same session: no-op (SDK-07).
    if (appId == this.appId && clientKey == this.clientKey && normalizedBaseUrl == this.baseUrl) {
      return
    }

    this.appId = appId
    this.clientKey = clientKey
    this.baseUrl = normalizedBaseUrl
    this.apiClient = apiClientFactory(appId, clientKey, normalizedBaseUrl)

    tokenProvider { token ->
      if (token == null) {
        logger("Notti.initialize: no push token available - skipping registration")
        return@tokenProvider
      }
      // L2 (pre-release review round 3): `apiClient` is read again here,
      // not captured into a local before this async hop. `tokenProvider`'s
      // callback can land well after a *second* `initialize(...)` call (a
      // different appId mid-flight) has already replaced `this.apiClient` -
      // capturing the first client would register the old app's device
      // against the new app's token. Mirrors A9's "read apiClient at
      // run/flush time" fix for the pending-mutation queue.
      val client = apiClient ?: return@tokenProvider
      // The token callback itself can be delivered on the main looper (Play
      // Services `Task` default executor), so the registration call is handed
      // off rather than run here.
      registrationState = RegistrationState.IN_FLIGHT
      dispatch("register") { registerDevice(apiClient ?: client, token) }
    }
  }

  fun onTokenRefreshed(newToken: String) {
    val client = apiClient ?: return
    registrationState = RegistrationState.IN_FLIGHT
    // L2: re-read at run time, same reasoning as `initialize` above.
    dispatch("onTokenRefreshed") { registerDevice(apiClient ?: client, newToken) }
  }

  /**
   * Resumes registration when the app comes back to the foreground, which is
   * the only recovery path the spec gives once `NottiApiClient` has burned
   * through its 5-attempt backoff (SDK-05) - otherwise a device that was
   * offline at launch stays unregistered until the process is killed.
   *
   * A no-op unless registration actually needs it: already registered, or an
   * attempt is still in flight (so repeated foregrounds cannot stack attempts
   * or start a retry storm).
   */
  fun onAppForegrounded() {
    // Session start runs first, before any flush/retry logic: an unclean kill
    // (force-quit/crash with no background transition) leaves `session_started_at`
    // set, and this closes the missed session with an estimate before a new one
    // opens (SEGTEL-08). The timestamp is captured HERE, on the lifecycle
    // callback, and the store work is serialized on [executor] together with
    // session end - so start/end can never interleave or read a late clock.
    // [sessionGate] makes a duplicate foreground signal for the same process
    // session (cold-start sync + observer, RN reload) a no-op.
    if (sessionGate.tryOpen()) {
      val now = clock()
      // Executor shut down (module invalidated): no session was started, so
      // the gate must not stay open and swallow the next real foreground.
      if (!dispatch("sessionStart") { handleSessionStart(now) }) sessionGate.close()
    }

    // Flush the event queue unconditionally, before the registration-state
    // guard below: queued event reporting is independent of whether
    // registration needs retrying (a REGISTERED device still owes event
    // reports, and there is no point waiting for registration when none is
    // in progress). Blocking HTTP, so it is handed to the executor like every
    // other network touch and runs ahead of any registration retry this
    // method goes on to trigger.
    scheduleFlush()
    retryPendingCountryClear()

    val client = apiClient ?: return
    if (registrationState == RegistrationState.REGISTERED ||
      registrationState == RegistrationState.IN_FLIGHT
    ) {
      return
    }

    // IN_FLIGHT is set only once the token is actually in hand, not before
    // the fetch. `tokenProvider` is backed by a Play Services `Task`, whose
    // listener can simply never fire (Play Services missing, disabled, or
    // wedged); marking IN_FLIGHT up front would park the state there forever
    // and the guard above would then kill every future foreground retry. The
    // cost of the looser guard is at most a duplicate token fetch plus an
    // idempotent create-or-update POST, which the single-threaded executor
    // serializes anyway.
    tokenProvider { token ->
      if (token == null) {
        registrationState = RegistrationState.FAILED
        logger("Notti.onAppForegrounded: no push token available - registration not retried")
        return@tokenProvider
      }
      registrationState = RegistrationState.IN_FLIGHT
      // L2: re-read at run time - a concurrent `initialize(...)` could have
      // replaced `apiClient` during the token fetch.
      dispatch("onAppForegrounded") { registerDevice(apiClient ?: client, token) }
    }
  }

  /**
   * Flush trigger for callers that run outside this module - the network
   * observer and the event-detection enqueue helper (T4) - and, on a cold
   * start, often before it exists at all (they no-op through the null
   * [NottiModule.activeCore] until it does). [flushEventQueue] is private and
   * performs blocking HTTP, so like [onAppForegrounded] this hands the work
   * to [executor] rather than running on the caller's thread: the
   * `ConnectivityManager` callback that reaches this can be on a binder
   * thread. Mirrors iOS' `NottiCore.onNetworkAvailable`.
   */
  internal fun onNetworkAvailable() {
    scheduleFlush()
    retryPendingCountryClear()
  }

  /**
   * Queues one [flushEventQueue] unless one is already queued and not yet
   * started: every foreground / reconnect / detection-site enqueue asks for a
   * flush, and stacking N identical flushes behind a slow one just repeats the
   * same failing work N times. The flag is reset when the task STARTS, so an
   * event enqueued mid-flush still gets a follow-up flush.
   */
  private fun scheduleFlush() {
    if (!flushScheduled.compareAndSet(false, true)) return
    val accepted = dispatch("flushEventQueue") {
      flushScheduled.set(false)
      flushEventQueue()
    }
    if (!accepted) flushScheduled.set(false)
  }

  /**
   * Background/terminate hook (SEGTEL-06): ends the current session, if any,
   * persisting the aggregate and enqueueing a snapshot PATCH. Mirrors
   * [onAppForegrounded]'s executor handoff - the store reads/writes and the
   * PATCH enqueue must not run on the caller's (main) thread. Called from
   * [NottiForegroundObserver.onStop].
   */
  fun onAppBackgrounded() {
    sessionGate.close()
    // Captured on the lifecycle callback, not when the executor gets to it: a
    // backlog (e.g. a flush in retry backoff) would otherwise add its whole
    // delay to the session's foreground time.
    val now = clock()
    dispatch("handleSessionEnd") { handleSessionEnd(now) }
  }

  /**
   * Foreground heartbeat (SEGTEL-08 "last known foreground timestamp"):
   * called periodically by [NottiForegroundObserver] while the process is
   * started. No-op when no session is open in this process.
   */
  fun recordForegroundHeartbeat() {
    if (!sessionGate.isActive) return
    val now = clock()
    dispatch("heartbeat") { recordForegroundHeartbeatAt(now) }
  }

  internal fun recordForegroundHeartbeatAt(nowMs: Long) {
    synchronized(sessionLock) {
      val startedAt = deviceStore.getSessionStartedAtMs() ?: return
      if (nowMs >= startedAt) deviceStore.setLastForegroundAtMs(nowMs)
    }
  }

  /**
   * Session start (SEGTEL-05/08). If `session_started_at` is already set, the
   * previous session never received a background transition (unclean kill:
   * force-quit/crash) - it is closed at the LAST KNOWN FOREGROUND timestamp
   * (the heartbeat, see [recordForegroundHeartbeat]), never at "now": the
   * time the process was dead is not foreground time. Without a heartbeat
   * the estimate is the session start itself (0s credited - under-count
   * rather than inflate), and it is always bounded by
   * [MAX_ORPHAN_SESSION_MS]. Then `first_session_at` is set once and the new
   * session opens. Runs on [executor] (or directly in tests), under
   * [sessionLock].
   */
  internal fun handleSessionStart(nowMs: Long) {
    synchronized(sessionLock) {
      val orphanStartedAt = deviceStore.getSessionStartedAtMs()
      if (orphanStartedAt != null) {
        val end = estimateOrphanEnd(orphanStartedAt, deviceStore.getLastForegroundAtMs(), nowMs)
        closeSession(orphanStartedAt, end)
      }
      if (deviceStore.getFirstSessionAtMs() == null) {
        deviceStore.setFirstSessionAtMs(nowMs)
      }
      deviceStore.setSessionStartedAtMs(nowMs)
      deviceStore.setLastForegroundAtMs(nowMs)
    }
    readCountryIfOptedIn()
    syncPermissionStatusIfNeeded()
  }

  private fun estimateOrphanEnd(startedAt: Long, heartbeat: Long?, nowMs: Long): Long {
    val lastSeen = heartbeat?.takeIf { it >= startedAt } ?: startedAt
    return minOf(lastSeen, startedAt + MAX_ORPHAN_SESSION_MS, maxOf(nowMs, startedAt))
  }

  /**
   * Best-effort, permission-gated country read at session start (SEGTEL-11):
   * only when the opt-in flag is on AND the host app already holds location
   * permission. A `null` country (revoked permission/read failure) is silently
   * omitted - never prompts, never errors (SEGTEL-12/14). An unchanged
   * country (same as the last value the backend acknowledged) is not re-sent.
   *
   * The opt-in flag is re-checked INSIDE the closure that actually performs
   * the PATCH, not only when the geocode result arrives: the PATCH may run
   * much later (queued until registration completes) and the user may have
   * opted out in between - sending the country after an opt-out is exactly
   * what SEGTEL-13 forbids. The mutation is keyed `country`, so a later
   * opt-out clear replaces a still-queued country set.
   */
  private fun readCountryIfOptedIn() {
    if (!deviceStore.getLocationSharingEnabled() || !hasLocationPermission()) return
    countryProvider { country ->
      if (country == null) return@countryProvider
      dispatch("country") {
        if (!shouldSendCountry(country) || apiClient == null) return@dispatch
        // Already on the executor: run/queue directly rather than through
        // [mutate], which would add a second dispatch hop.
        runOrQueue(PendingMutation("country", KEY_COUNTRY) { client, deviceId, token ->
          if (shouldSendCountry(country)) {
            when (val result = client.patchDevice(deviceId, token, mapOf("country" to country))) {
              is ApiResult.Success -> deviceStore.setLastSyncedCountry(country)
              is ApiResult.Failure -> logger("Notti.country: PATCH failed (${result.message}) - retried at the next session start")
            }
          }
        })
      }
    }
  }

  private fun shouldSendCountry(country: String): Boolean =
    deviceStore.getLocationSharingEnabled() &&
      !deviceStore.getPendingCountryClear() &&
      country != deviceStore.getLastSyncedCountry()

  /**
   * Session end (SEGTEL-06/07): no-op when no session is active (`session_started_at`
   * null - also excludes widget/extension/background-fetch invocations, which
   * never set it). [nowMs] is the timestamp captured on the lifecycle
   * callback ([onAppBackgrounded]).
   */
  internal fun handleSessionEnd(nowMs: Long) {
    synchronized(sessionLock) {
      val startedAt = deviceStore.getSessionStartedAtMs() ?: return
      closeSession(startedAt, maxOf(nowMs, startedAt))
    }
  }

  /**
   * Increments the count, adds `endMs - startedAt`, records `last_session_at`,
   * clears the in-flight session, persists the aggregate (survives process
   * death, SEGTEL-09), and enqueues a session PATCH carrying a **snapshot
   * captured at enqueue time** - so a new session starting mid-flush is never
   * double-counted or lost. Keyed `session`: a newer snapshot replaces a
   * still-queued older one (it is cumulative, so nothing is lost).
   * Caller holds [sessionLock].
   */
  private fun closeSession(startedAt: Long, endMs: Long) {
    val count = deviceStore.getSessionCount() + 1
    val timeMs = deviceStore.getSessionTimeMs() + (endMs - startedAt)
    deviceStore.setSessionCount(count)
    deviceStore.setSessionTimeMs(timeMs)
    deviceStore.setLastSessionAtMs(endMs)
    deviceStore.setSessionStartedAtMs(null)
    deviceStore.setLastForegroundAtMs(null)

    val firstAt = deviceStore.getFirstSessionAtMs()
    val snapshot = mutableMapOf<String, Any>(
      "last_session_at" to formatIsoUtc(endMs),
      "session_count" to count,
      "session_time_seconds" to timeMs / 1000
    )
    if (firstAt != null) {
      snapshot["first_session_at"] = formatIsoUtc(firstAt)
    }
    mutate("session", KEY_SESSION) { client, deviceId, token ->
      val result = client.patchDevice(deviceId, token, snapshot)
      when (result) {
        is ApiResult.Success -> Unit // backend is sink; aggregate already persisted
        is ApiResult.Failure -> logger("Notti.session: PATCH failed (${result.message}) - next session end re-sends the cumulative snapshot")
      }
    }
  }

  /**
   * Formats an epoch-ms timestamp as UTC ISO-8601 (`yyyy-MM-dd'T'HH:mm:ss.SSS'Z'`)
   * for the session PATCH payload. No `java.time` (minSdk 24, no desugaring) -
   * `SimpleDateFormat` with an explicit UTC `TimeZone`; the literal `'Z'` in the
   * pattern matches the RFC3339 shape the backend's Go parser accepts. Matches
   * the iOS helper's output.
   */
  internal fun formatIsoUtc(epochMs: Long): String =
    SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US)
      .apply { timeZone = TimeZone.getTimeZone("UTC") }
      .format(Date(epochMs))

  /**
   * Holds [mutationLock] across the whole call/response/store-write sequence,
   * for the same reason `mutateTags` does: the POST response carries the
   * device's server-side `tags`, so registration is itself a read-modify-write
   * on the cached tag map. An `onNewToken` re-registration landing (on the FCM
   * thread) mid-`addTags` would otherwise answer from the server's pre-PATCH
   * state and overwrite the tag that was just merged and persisted.
   */
  private fun registerDevice(client: NottiApiClient, token: String) {
    synchronized(mutationLock) {
      try {
        when (val result = client.createOrUpdateDevice(token, platform)) {
          is ApiResult.Success -> {
            val previousDeviceId = deviceStore.getDeviceId()
            deviceStore.setDeviceId(result.response.id)
            if (result.response.id != previousDeviceId) {
              onDeviceIdChanged(result.response.id)
            }
            deviceStore.setLastToken(token)
            deviceStore.setTags(result.response.tags)
            registrationState = RegistrationState.REGISTERED
            // Privacy obligation first (iOS parity): an opt-out issued before
            // initialize() / while offline / whose clear failed is still owed
            // to the server (SEGTEL-13, LGPD) and must not wait behind up to
            // MAX_PENDING_MUTATIONS queued calls (~62s of backoff each).
            if (deviceStore.getPendingCountryClear()) runPendingCountryClearNow()
            flushPendingMutations()
            syncProfileFieldsIfNeeded()
            syncPermissionStatusIfNeeded()
            resyncHeldEmailAndPhone()
            flushEventQueue()
          }
          is ApiResult.Failure -> {
            registrationState = RegistrationState.FAILED
            logger(
              "Notti.initialize: device registration failed: ${result.message} " +
                "- retrying on the next app foreground or token refresh"
            )
          }
        }
      } catch (t: Throwable) {
        // Anything unexpected escaping here must still land the state machine
        // in a retryable state: [onAppForegrounded] early-returns while
        // IN_FLIGHT, so a throw that skipped both branches above would
        // permanently disable the foreground retry and strand every queued
        // mutation for the life of the process.
        registrationState = RegistrationState.FAILED
        logger(
          "Notti.initialize: device registration failed unexpectedly: ${t.message} " +
            "- retrying on the next app foreground or token refresh"
        )
      }
    }
  }

  /** Cached device id, or `null` if registration hasn't assigned one yet. */
  fun getDeviceId(): String? = deviceStore.getDeviceId()

  fun requestPermission(callback: (granted: Boolean) -> Unit) {
    if (apiClient == null) {
      logger("Notti.requestPermission: called before initialize - not prompting")
      callback(false)
      return
    }

    // The OS prompt must be triggered from the caller's (UI-capable) thread -
    // only the resulting PATCH is handed to the executor.
    permissionRequester { granted ->
      // A4 (found in pre-release review): `callback(granted)` below reports
      // the OS *dialog* result, not whether the backend actually persisted
      // it - a failed PATCH here (4xx, or backoff exhausted) used to fail
      // completely silently, with nothing logged and no reconciliation path
      // (the foreground retry only covers *registration*, never mutations).
      // Changing the Promise to depend on the PATCH outcome would be a
      // breaking API change (it currently resolves as soon as the user
      // answers the OS prompt, without waiting on network); logging the
      // failure is the fix that fits this pass without that risk.
      mutate("requestPermission") { client, deviceId, token ->
        // Same reversal as setSubscription(true), regardless of the PATCH
        // outcome: an earlier opt-out whose PATCH failed was reverted by the
        // user granting, so its stale stamp must never be re-sent by a later
        // opt-out (iOS parity).
        if (granted) deviceStore.setPendingUnsubscribeAtMs(null)
        val result = client.patchDevice(deviceId, token, mapOf("subscribed" to granted))
        when (result) {
          is ApiResult.Success -> deviceStore.setSubscribed(granted)
          is ApiResult.Failure -> logger(
            "Notti.requestPermission: backend PATCH failed after the user answered the OS prompt " +
              "(${result.message}) - local state now disagrees with the server and is not retried"
          )
        }
      }
      // DPF-12: the OS permission status is re-read from the OS state (not
      // inferred from the dialog bool) and diff-and-enqueued.
      syncPermissionStatusIfNeeded()
      callback(granted)
    }
  }

  fun login(externalUserId: String) {
    mutate("login") { client, deviceId, token ->
      val result = client.patchDevice(deviceId, token, mapOf("external_user_id" to externalUserId))
      when (result) {
        is ApiResult.Success -> deviceStore.setExternalUserId(externalUserId)
        is ApiResult.Failure -> logger("Notti.login: PATCH failed (${result.message}) - not retried")
      }
    }
  }

  /**
   * The backend does not support clearing `external_user_id` server-side
   * (spec Edge Case) - only the SDK's locally-held association is cleared.
   * The user's `email`/`phone` ARE cleared server-side (LGPD: a signed-out
   * user's PII must not stay attached to the device): same durable path as
   * [clearEmail]/[clearPhone], so a failed or pre-`initialize()` logout still
   * converges at the next registration.
   *
   * Handed to [executor] like every other mutation (and like iOS' `logout`,
   * which hops onto its `workQueue`) rather than written straight from the
   * caller's thread: `login("u1")` immediately followed by `logout()` would
   * otherwise clear the id synchronously *first*, and login's PATCH - still
   * queued on the executor - would then re-persist "u1" onto a device the
   * user had already logged out of. The email/phone clears keep the same
   * guarantee: their PATCHes are dispatched to the same executor after any
   * earlier `login`/`setEmail`/`setPhone`, and the coalesce key makes the
   * clear supersede a set still queued before registration.
   */
  fun logout() {
    dispatch("logout") { deviceStore.setExternalUserId(null) }
    clearEmail()
    clearPhone()
  }

  fun setSubscription(enabled: Boolean) {
    // Captured on the caller's thread, like the session clock: the moment the
    // user opted out, not when a busy/queued executor got to it.
    val requestedAt = clock()
    mutate("setSubscription") { client, deviceId, token ->
      // Tri-state: `null` = this install never had a subscription acked. The
      // backend creates device rows with `subscribed = true`, so unknown is
      // treated as subscribed - only a known `false` makes this a non-transition.
      val wasSubscribed = deviceStore.getSubscribedOrNull()
      // DPF-14 app-driven path: a real (true|unknown)->false transition records
      // the most-recent unsubscribe timestamp and sends it in the SAME PATCH
      // as `subscribed` so the two writes are atomic - a failed PATCH leaves
      // both unsynced (subscribed stays true/unknown locally, so a retry
      // re-runs the whole transition) instead of stranding a server-side
      // `subscribed: false` with `last_unsubscribed_at` never written. The
      // timestamp is stamped ONCE, when the transition is first detected, and
      // a retry re-sends that persisted value rather than a fresh now().
      val fields = mutableMapOf<String, Any>("subscribed" to enabled)
      var stamp: Long? = null
      if (enabled) {
        // Re-subscribed before the opt-out was acked: that transition is moot.
        deviceStore.setPendingUnsubscribeAtMs(null)
      } else if (wasSubscribed != false) {
        stamp = deviceStore.getPendingUnsubscribeAtMs() ?: requestedAt.also {
          deviceStore.setPendingUnsubscribeAtMs(it)
          deviceStore.setLastUnsubscribedAtMs(it)
        }
        fields["last_unsubscribed_at"] = formatIsoUtc(stamp)
      }
      val result = client.patchDevice(deviceId, token, fields)
      when (result) {
        is ApiResult.Success -> {
          deviceStore.setSubscribed(enabled)
          if (stamp != null) deviceStore.setPendingUnsubscribeAtMs(null)
        }
        is ApiResult.Failure -> logger("Notti.setSubscription: PATCH failed (${result.message}) - not retried")
      }
    }
  }

  /**
   * First-class device email (DPF-17): persists the held value locally, then
   * enqueues a coalesced PATCH. A no-op only when the value is both held AND
   * acknowledged by the backend (DPF-20, matching `addTag` idempotence) - a
   * repeat call after a failed PATCH re-sends instead of being swallowed.
   * Travels as its own PATCH field, never merged into tags (DPF-21).
   */
  fun setEmail(email: String) = setContactField(emailField, email)

  /**
   * Explicit clear (DPF-18): persists `null` and enqueues an explicit
   * `{email: null}`, keyed like [setEmail] so it supersedes a still-queued set.
   * Durable: if the PATCH fails, never runs (before `initialize()`, process
   * death with it queued), the held/last-synced diff re-sends it at the next
   * registration (see [resyncHeldEmailAndPhone]).
   */
  fun clearEmail() = setContactField(emailField, null)

  /** First-class device phone (DPF-17); see [setEmail] for the contract. */
  fun setPhone(phone: String) = setContactField(phoneField, phone)

  /** Explicit clear (DPF-18); see [clearEmail] for the contract. */
  fun clearPhone() = setContactField(phoneField, null)

  /**
   * Held-vs-acknowledged bookkeeping for one contact field (`email`/`phone`).
   * `held` is what the integrator last asked for; `lastSynced` is what the
   * backend last acknowledged - the two differ exactly while a set/clear is
   * still owed to the server.
   */
  private class ContactField(
    val name: String,
    val coalesceKey: String,
    val getHeld: () -> String?,
    val setHeld: (String?) -> Unit,
    val getLastSynced: () -> String?,
    val setLastSynced: (String?) -> Unit
  )

  private val emailField = ContactField(
    "email", KEY_EMAIL,
    deviceStore::getEmail, deviceStore::setEmail,
    deviceStore::getLastSyncedEmail, deviceStore::setLastSyncedEmail
  )

  private val phoneField = ContactField(
    "phone", KEY_PHONE,
    deviceStore::getPhone, deviceStore::setPhone,
    deviceStore::getLastSyncedPhone, deviceStore::setLastSyncedPhone
  )

  /** `value == null` is a clear: always enqueued, never short-circuited. */
  private fun setContactField(field: ContactField, value: String?) {
    if (value != null && value == field.getHeld() && value == field.getLastSynced()) return
    field.setHeld(value)
    val operation = (if (value == null) "clear" else "set") + field.name.replaceFirstChar { it.uppercase() }
    mutate(operation, field.coalesceKey, contactFieldWork(operation, field, value))
  }

  /**
   * The PATCH for one contact-field set/clear. On a 2xx, `lastSynced` records
   * the value just acknowledged - unconditionally, NOT only when it still
   * equals the held value: every mutation runs serially on [executor] in call
   * order, so the last ack to land is always the server's current value and
   * a stale ack can never overwrite a newer one. Skipping the write when the
   * held value moved on (e.g. a set acked after a clear was issued) would
   * leave `lastSynced` behind the server: if that clear then failed, the
   * registration diff would see `held == lastSynced == null` and never re-send
   * it, stranding the PII server-side.
   */
  private fun contactFieldWork(
    operation: String,
    field: ContactField,
    value: String?
  ): (NottiApiClient, String, String) -> Unit = { client, deviceId, token ->
    // JSONObject.NULL is the raw-JSON null sentinel toJsonValue passes through
    // unchanged - the explicit {email: null} / {phone: null} clear (DPF-18).
    val payload: Any = value ?: org.json.JSONObject.NULL
    when (val result = client.patchDevice(deviceId, token, mapOf(field.name to payload))) {
      is ApiResult.Success -> field.setLastSynced(value)
      is ApiResult.Failure -> logger("Notti.$operation: PATCH failed (${result.message}) - re-sent at the next registration")
    }
  }

  /**
   * P3 opt-in toggle (SEGTEL-10/13/15): persists the flag locally (survives
   * restarts). Enabling does not read immediately - the next session start
   * attempts it (SEGTEL-11 read cadence).
   *
   * Disabling (LGPD-critical, SEGTEL-13 AC4): the server-side `country` must
   * actually be cleared, not just stop being updated. A durable
   * `pendingCountryClear` flag is persisted first and dropped ONLY when a
   * `{country: null}` PATCH returns 2xx; until then the clear is re-sent on
   * the next registration success, app foreground and network regain - so an
   * opt-out before `initialize()`, offline, on a 5xx, or killed mid-retry is
   * never lost. Only armed when a country may exist server-side (sharing was
   * on, a country was synced, or a clear is already owed) - an integrator who
   * calls `false` on every launch without ever opting in sends nothing.
   */
  fun setLocationSharingEnabled(enabled: Boolean) {
    val wasEnabled = deviceStore.getLocationSharingEnabled()
    deviceStore.setLocationSharingEnabled(enabled)
    if (enabled) {
      if (!wasEnabled) {
        // Fresh consent supersedes an unacknowledged clear (a queued clear also
        // re-checks the flag before running). Forget the synced value too, so
        // the next read is re-sent even if a clear reached the server but its
        // ack was lost (iOS parity: NottiCore.swift setLocationSharingEnabled).
        deviceStore.setPendingCountryClear(false)
        deviceStore.setLastSyncedCountry(null)
      }
      return
    }
    val mayExistServerSide = wasEnabled ||
      deviceStore.getLastSyncedCountry() != null ||
      deviceStore.getPendingCountryClear()
    if (!mayExistServerSide) return
    deviceStore.setPendingCountryClear(true)
    retryPendingCountryClear()
  }

  /**
   * Sends (or queues until registration) the owed `{country: null}` clear.
   * Without an API client yet, nothing is dispatched - the persisted flag is
   * picked up by [registerDevice] once `initialize()` registers.
   */
  private fun retryPendingCountryClear() {
    if (!deviceStore.getPendingCountryClear() || apiClient == null) return
    if (!countryClearScheduled.compareAndSet(false, true)) return
    val accepted = dispatch("countryClear") {
      countryClearScheduled.set(false)
      runOrQueue(countryClearMutation())
    }
    if (!accepted) countryClearScheduled.set(false)
  }

  /**
   * Registration-success path of [registerDevice] (caller holds
   * [mutationLock], device addressable): drops every queued `country` entry -
   * a queued copy of the clear (would be a duplicate attempt) or a country set
   * superseded by the opt-out - and runs the clear directly. A throw is
   * contained so it cannot skip the queued-mutation flush that follows.
   */
  private fun runPendingCountryClearNow() {
    pendingMutations.removeAll { it.coalesceKey == KEY_COUNTRY }
    try {
      runOrQueue(countryClearMutation())
    } catch (t: Throwable) {
      logger("Notti.setLocationSharingEnabled: clear failed unexpectedly - ${t.message}")
    }
  }

  private fun countryClearMutation() = PendingMutation("countryClear", KEY_COUNTRY) { client, deviceId, token ->
    // Re-checked at execution: re-enabled meanwhile, or already cleared by an
    // earlier copy of this mutation.
    if (!deviceStore.getLocationSharingEnabled() && deviceStore.getPendingCountryClear()) {
      // JSONObject.NULL is the raw-JSON null sentinel toJsonValue passes
      // through unchanged - the explicit {country: null} clear (SEGTEL-13).
      when (val result = client.patchDevice(deviceId, token, mapOf("country" to org.json.JSONObject.NULL))) {
        is ApiResult.Success -> {
          deviceStore.setPendingCountryClear(false)
          deviceStore.setLastSyncedCountry(null)
        }
        // Permanent 4xx (401/403/404...) gets its own line: it will keep
        // failing until credentials/device row change, which is a config
        // problem to diagnose, not a transient one. Message is only "HTTP <code>".
        is ApiResult.Failure -> if (result.terminal) {
          logger(
            "Notti.setLocationSharingEnabled: clear PATCH rejected permanently (${result.message}) - " +
              "check clientKey/appId/device registration; stays pending, re-sent on the next registration/foreground/network regain"
          )
        } else {
          logger(
            "Notti.setLocationSharingEnabled: clear PATCH failed (${result.message}) - " +
              "stays pending, re-sent on the next registration/foreground/network regain"
          )
        }
      }
    }
  }

  fun mutateTags(add: Map<String, String>?, remove: List<String>?) {
    mutate("mutateTags") { client, deviceId, token ->
      val merged = NottiDeviceStore.mergeTags(deviceStore.getTags(), add, remove)
      val result = client.patchDevice(deviceId, token, mapOf("tags" to merged))
      when (result) {
        is ApiResult.Success -> deviceStore.setTags(result.response.tags)
        is ApiResult.Failure -> logger("Notti.mutateTags: PATCH failed (${result.message}) - not retried")
      }
    }
  }

  /**
   * Single entry point for every device mutation: hands the work to
   * [executor], then either runs it (device registered) or queues it until
   * registration completes. The work body reads the cached state itself, so a
   * queued tag mutation merges against the tag map registration seeded rather
   * than against a snapshot taken at enqueue time.
   */
  private fun mutate(
    operation: String,
    coalesceKey: String? = null,
    work: (client: NottiApiClient, deviceId: String, token: String) -> Unit
  ) {
    if (apiClient == null) {
      logger("Notti.$operation: called before initialize - ignored")
      return
    }
    dispatch(operation) { runOrQueue(PendingMutation(operation, coalesceKey, work)) }
  }

  private fun runOrQueue(mutation: PendingMutation) {
    synchronized(mutationLock) {
      val deviceId = deviceStore.getDeviceId()
      val token = deviceStore.getLastToken()
      if (deviceId == null || token == null) {
        val key = mutation.coalesceKey
        if (key != null) {
          // Telemetry: replace the queued mutation with the same key (the
          // newer value supersedes it); never counts against the cap below.
          val existing = pendingMutations.indexOfFirst { it.coalesceKey == key }
          if (existing >= 0) pendingMutations[existing] = mutation else pendingMutations.addLast(mutation)
          return
        }
        if (pendingMutations.count { it.coalesceKey == null } >= MAX_PENDING_MUTATIONS) {
          val oldest = pendingMutations.indexOfFirst { it.coalesceKey == null }
          val dropped = pendingMutations.removeAt(oldest)
          logger("Notti.${dropped.operation}: pending-mutation queue full - dropped the oldest queued call")
        }
        pendingMutations.addLast(mutation)
        logger("Notti.${mutation.operation}: device not registered yet - queued until registration completes")
        return
      }
      val client = apiClient ?: return
      mutation.work(client, deviceId, token)
    }
  }

  /**
   * Reads the host app's current version once per registration (SEGTEL-01) and
   * enqueues a PATCH when it differs from the last value successfully synced
   * (SEGTEL-03 diff-and-enqueue). The value is sent as an opaque string with
   * no client-side semver parsing (SEGTEL-04). A `null` version (reader
   * failure) skips entirely - no crash, no registration block (SEGTEL edge
   * case). Called from [registerDevice]'s success branch right after
   * [flushPendingMutations].
   *
   * Generalization (device-profile-fields, DPF-01..09): every read-once
   * profile field - `app_version`, `device_os`, `device_model`,
   * `sdk_version`, `timezone_id`, `language` - is diffed against its own
   * last-synced store value and enqueued independently on change. Opaque
   * strings, no parsing; a `null` provider skips only that field (DPF-04/09).
   */
  private fun syncProfileFieldsIfNeeded() {
    fun sync(name: String, coalesceKey: String, provider: () -> String?, synced: () -> String?, setSynced: (String) -> Unit) {
      val current = provider() ?: return
      if (current == synced()) return
      mutate(name, coalesceKey) { client, deviceId, token ->
        val result = client.patchDevice(deviceId, token, mapOf(name to current))
        when (result) {
          // The echoed device is the ack: a backend that predates the field
          // answers 2xx but ignores it (additive fields are ignored
          // server-side), so a bare 2xx must not mark it synced. Unechoed or
          // different -> left unsynced and re-sent on the next registration.
          is ApiResult.Success ->
            if (result.response.profileFields[name] == current) {
              setSynced(current)
            } else {
              logger("Notti.$name: PATCH accepted but value not echoed by the backend - re-sent on next registration")
            }
          is ApiResult.Failure -> logger("Notti.$name: PATCH failed (${result.message}) - not retried")
        }
      }
    }
    sync("app_version", KEY_APP_VERSION, versionProvider, deviceStore::getAppVersion, deviceStore::setAppVersion)
    sync("device_os", KEY_DEVICE_OS, deviceOsProvider, deviceStore::getLastSyncedDeviceOs, deviceStore::setLastSyncedDeviceOs)
    sync("device_model", KEY_DEVICE_MODEL, deviceModelProvider, deviceStore::getLastSyncedDeviceModel, deviceStore::setLastSyncedDeviceModel)
    sync("sdk_version", KEY_SDK_VERSION, sdkVersionProvider, deviceStore::getLastSyncedSdkVersion, deviceStore::setLastSyncedSdkVersion)
    sync("timezone_id", KEY_TIMEZONE_ID, timezoneProvider, deviceStore::getLastSyncedTimezoneId, deviceStore::setLastSyncedTimezoneId)
    sync("language", KEY_LANGUAGE, languageProvider, deviceStore::getLastSyncedLanguage, deviceStore::setLastSyncedLanguage)
  }

  /**
   * Syncs the OS push-permission state (DPF-10..13, DPF-14 permission-driven
   * unsubscribe). Fires the async [permissionStatusProvider]; only when the
   * freshly-read status differs from the last synced one is a coalesced PATCH
   * enqueued (diff-and-enqueue, DPF-11/13). A `null`/unknown status omits the
   * field - never fabricated (DPF edge case) - and leaves every piece of
   * pending state untouched (no diff, no clear of a pending granted -> denied
   * stamp). A granted -> denied transition additionally persists
   * `last_unsubscribed_at` and carries it in the same atomic request (DPF-14).
   *
   * The pending stamp is persisted at DETECTION time (on the executor, before
   * the mutation is run or queued), not inside the mutation: pre-registration
   * reads coalesce on [KEY_PERMISSION_STATUS] and replace the queued closure,
   * so stamping inside it would record the LAST pre-registration read instead
   * of the first detection.
   *
   * Called from three triggers: [registerDevice] success, the `requestPermission`
   * result, and each session start (catches permission changed in OS Settings
   * while the app wasn't running, DPF-13).
   */
  private fun syncPermissionStatusIfNeeded() {
    permissionStatusProvider { status ->
      if (status == null) return@permissionStatusProvider
      val detectedAt = clock()
      dispatch("permissionStatus") {
        if (apiClient == null) return@dispatch
        if (status != "denied") {
          // Back to a non-denied state before a granted->denied sync was
          // acked: that transition is moot, the next one gets a fresh stamp.
          deviceStore.setPendingPermissionUnsubscribeAtMs(null)
        } else if (deviceStore.getLastSyncedPermissionStatus() == "granted" &&
          deviceStore.getPendingPermissionUnsubscribeAtMs() == null
        ) {
          // Stamped once at first detection ([detectedAt], captured when the
          // OS state was read) and persisted now, so a later coalesced read
          // or a retry at a later session start re-sends this value instead
          // of a fresh now() (F8).
          deviceStore.setPendingPermissionUnsubscribeAtMs(detectedAt)
          deviceStore.setLastUnsubscribedAtMs(detectedAt)
        }
        // Already on the executor: run/queue directly rather than through
        // [mutate], which would add a second dispatch hop.
        runOrQueue(PendingMutation("permissionStatus", KEY_PERMISSION_STATUS) { client, deviceId, token ->
          val previous = deviceStore.getLastSyncedPermissionStatus()
          if (status == previous) return@PendingMutation
          val fields = mutableMapOf<String, Any>("permission_status" to status)
          var stamp: Long? = null
          if (status == "denied" && previous == "granted") {
            // Persisted at detection above; the fallback only covers a
            // pending stamp lost between detection and this run.
            stamp = deviceStore.getPendingPermissionUnsubscribeAtMs() ?: detectedAt.also {
              deviceStore.setPendingPermissionUnsubscribeAtMs(it)
              deviceStore.setLastUnsubscribedAtMs(it)
            }
            fields["last_unsubscribed_at"] = formatIsoUtc(stamp)
          }
          when (val result = client.patchDevice(deviceId, token, fields)) {
            is ApiResult.Success -> {
              deviceStore.setLastSyncedPermissionStatus(status)
              if (stamp != null) deviceStore.setPendingPermissionUnsubscribeAtMs(null)
            }
            is ApiResult.Failure -> logger("Notti.permissionStatus: PATCH failed (${result.message}) - re-checked at the next session start")
          }
        })
      }
    }
  }

  /**
   * Registration-success re-sync of `email`/`phone` (DPF-19), per field:
   * - held non-null: send a set unconditionally - the backend row may be
   *   fresh after a reinstall/backup-restore, so the value must converge
   *   without the integrator re-calling `setEmail`/`setPhone`;
   * - held null but last-synced non-null: a clear is still owed (issued
   *   before `initialize()`, its PATCH failed, or it was dropped from the
   *   in-memory queue on process death) - send `{field: null}`;
   * - both null: nothing.
   * Called from [registerDevice]'s success branch alongside the
   * profile/permission syncs (caller holds [mutationLock]).
   */
  private fun resyncHeldEmailAndPhone() {
    for (field in listOf(emailField, phoneField)) {
      val held = field.getHeld()
      if (held == null && field.getLastSynced() == null) continue
      val operation = "resync" + field.name.replaceFirstChar { it.uppercase() }
      runOrQueue(PendingMutation(operation, field.coalesceKey, contactFieldWork(operation, field, held)))
    }
  }

  /** Called from [registerDevice] while [mutationLock] is held. */
  private fun flushPendingMutations() {
    if (pendingMutations.isEmpty()) return
    val client = apiClient ?: return
    val deviceId = deviceStore.getDeviceId() ?: return
    val token = deviceStore.getLastToken() ?: return
    val queued = pendingMutations.toList()
    pendingMutations.clear()
    queued.forEach { mutation ->
      try {
        mutation.work(client, deviceId, token)
      } catch (t: Throwable) {
        logger("Notti.${mutation.operation}: queued call failed - ${t.message}")
      }
    }
  }

  /**
   * Drains [NottiEventStore] by reporting each queued event to the backend
   * and removing it only once the backend has acknowledged it. Write-ahead
   * persistence: the event is persisted *before* any report attempt, so a
   * crash mid-flush never loses a queued event - at worst it is re-reported,
   * which the backend treats as idempotent. The remove-on-success contract is
   * what makes that safe: an event is removed from the disk queue exactly when
   * `reportEvent` returns [EventResult.Success], never before.
   *
   * On a terminal [EventResult.Failure] (`terminal == true`, a 4xx the backend
   * will never accept - e.g. a stale token 403 per spec SDKCTR-11) the event is
   * ALSO removed: re-attempting it on every future flush would fail identically
   * forever. On a transient [EventResult.Failure] (`terminal == false`, retry
   * cap exhausted on network/5xx) the event STAYS queued: `reportEvent` already
   * exhausted its own 5-attempt retry/backoff, so it is left for the next flush
   * trigger (registration success, app foreground, or network regained).
   *
   * No-op when there is no API client (never initialized) or no persisted
   * token to authenticate the report with. Performs blocking HTTP, so it must
   * be handed to [executor] via [dispatch] and never called directly.
   */
  private fun flushEventQueue() {
    val client = apiClient ?: return
    val token = deviceStore.getLastToken() ?: return
    for (event in eventStore.all()) {
      when (val result = client.reportEvent(event.notificationId, event.deliveryId, event.type, token)) {
        is EventResult.Success -> eventStore.remove(event.id)
        is EventResult.Failure ->
          if (result.terminal) {
            logger("Notti.flushEventQueue: event report terminally failed (${result.message}) - event dropped")
            eventStore.remove(event.id)
          } else {
            // Transient (network/5xx/408/429 after the full backoff): the
            // next event would almost certainly fail the same way, and each
            // costs ~1 min of backoff on the single shared executor - stop
            // here and leave the rest for the next flush trigger.
            logger("Notti.flushEventQueue: event report failed (${result.message}) - flush stopped, events stay queued")
            break
          }
      }
    }
  }

  /**
   * Hands one unit of (blocking) work to [executor], never letting a failure
   * escape: an exception thrown inside an `Executor` task is either swallowed
   * silently (`submit`) or kills the worker thread (`execute`), and either way
   * an SDK must not take the host app down (spec SDK-03/SDK-04 crash safety).
   */
  private fun dispatch(operation: String, work: () -> Unit): Boolean {
    try {
      executor.execute {
        try {
          work()
        } catch (t: Throwable) {
          logger("Notti.$operation: unexpected failure - ${t.message}")
        }
      }
      return true
    } catch (e: RejectedExecutionException) {
      // The executor is shut down: NottiModule.invalidate() tore the module
      // down (host app dropping the RN context in background, or a dev
      // reload) while a caller outside the module still held the core -
      // NottiFirebaseMessagingService.onNewToken and the process-lifecycle
      // foreground observer both read `activeCore` before it is cleared and
      // can dispatch after the shutdown. `execute` itself throws, on the FCM
      // service thread or the main thread, so the rejection has to be
      // swallowed here rather than inside the task body (spec SDK-03/SDK-04:
      // the SDK must never take the host app down). The work is dropped:
      // there is no executor left to run it on, and the next process will
      // re-register from scratch.
      logger("Notti.$operation: SDK is shut down - dropped")
      return false
    }
  }

}
