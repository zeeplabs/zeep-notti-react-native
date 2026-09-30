package com.notti

import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.concurrent.Executor
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException

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
   * Notified from [registerDevice] whenever the persisted device id actually
   * changes (first assignment, reinstall, or a re-registration that lands a
   * different id) - never on an idempotent re-register that returns the same
   * id already cached. See ADR-001
   * (docs/adr/001-expose-device-id-getter-and-change-event.md).
   */
  private val onDeviceIdChanged: (String) -> Unit = {}
) {

  companion object {
    /**
     * Bound on the pending-mutation queue below: registration can legitimately
     * never complete (no push token, permanent 4xx), and an unbounded queue in
     * that state would grow for the life of the process.
     */
    private const val MAX_PENDING_MUTATIONS = 32

    /**
     * Single-threaded so blocking HTTP work never piles up more than one
     * thread and outgoing calls stay serialized; daemon so a pending retry
     * backoff can never hold the host process alive.
     */
    @JvmStatic
    fun newDefaultExecutor(): Executor = Executors.newSingleThreadExecutor { runnable ->
      Thread(runnable, "notti-io").apply { isDaemon = true }
    }
  }

  private var appId: String? = null
  private var clientKey: String? = null
  private var baseUrl: String? = null
  @Volatile
  private var apiClient: NottiApiClient? = null

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
  private class PendingMutation(
    val operation: String,
    val work: (client: NottiApiClient, deviceId: String, token: String) -> Unit
  )

  fun initialize(appId: String, clientKey: String, baseUrl: String) {
    if (appId.isBlank() || clientKey.isBlank() || baseUrl.isBlank()) {
      logger("Notti.initialize: appId, clientKey, or baseUrl is missing/empty - skipping registration")
      return
    }

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
    val client = apiClientFactory(appId, clientKey, normalizedBaseUrl)
    this.apiClient = client

    tokenProvider { token ->
      if (token == null) {
        logger("Notti.initialize: no push token available - skipping registration")
        return@tokenProvider
      }
      // The token callback itself can be delivered on the main looper (Play
      // Services `Task` default executor), so the registration call is handed
      // off rather than run here.
      registrationState = RegistrationState.IN_FLIGHT
      dispatch("register") { registerDevice(client, token) }
    }
  }

  fun onTokenRefreshed(newToken: String) {
    val client = apiClient ?: return
    registrationState = RegistrationState.IN_FLIGHT
    dispatch("onTokenRefreshed") { registerDevice(client, newToken) }
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
    // opens (SEGTEL-08). Store-only bookkeeping + possibly an enqueued session
    // PATCH; no blocking I/O on the caller's thread.
    handleSessionStart(System.currentTimeMillis())

    // Flush the event queue unconditionally, before the registration-state
    // guard below: queued event reporting is independent of whether
    // registration needs retrying (a REGISTERED device still owes event
    // reports, and there is no point waiting for registration when none is
    // in progress). Blocking HTTP, so it is handed to the executor like every
    // other network touch and runs ahead of any registration retry this
    // method goes on to trigger.
    dispatch("flushEventQueue") { flushEventQueue() }

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
      dispatch("onAppForegrounded") { registerDevice(client, token) }
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
    dispatch("flushEventQueue") { flushEventQueue() }
  }

  /**
   * Background/terminate hook (SEGTEL-06): ends the current session, if any,
   * persisting the aggregate and enqueueing a snapshot PATCH. Mirrors
   * [onAppForegrounded]'s executor handoff - the store reads/writes and the
   * PATCH enqueue must not run on the caller's (main) thread. Called from
   * [NottiForegroundObserver.onStop].
   */
  fun onAppBackgrounded() {
    dispatch("handleSessionEnd") { handleSessionEnd(System.currentTimeMillis()) }
  }

  /**
   * Session start (SEGTEL-05/08): called at the top of [onAppForegrounded]
   * before any flush/retry logic. If `session_started_at` is already set, the
   * previous session never received a background transition (unclean kill:
   * force-quit/crash) - close it with an estimate via [handleSessionEnd] using
   * the stored start and the current time (SEGTEL-08). Then set
   * `first_session_at` once (never overwritten) and open the new session.
   * Store-only, plus a possible session PATCH enqueue via [handleSessionEnd].
   */
  internal fun handleSessionStart(nowMs: Long) {
    if (deviceStore.getSessionStartedAtMs() != null) {
      handleSessionEnd(nowMs)
    }
    if (deviceStore.getFirstSessionAtMs() == null) {
      deviceStore.setFirstSessionAtMs(nowMs)
    }
    deviceStore.setSessionStartedAtMs(nowMs)
  }

  /**
   * Session end (SEGTEL-06/07): no-op when no session is active (`session_started_at`
   * null - also excludes widget/extension/background-fetch invocations, which
   * never set it). Otherwise increments the count, adds the elapsed foreground
   * time, records `last_session_at`, clears the in-flight session, persists the
   * aggregate (survives process death, SEGTEL-09), and enqueues a session PATCH
   * carrying a **snapshot captured at enqueue time** of the four aggregate fields
   * - so a new session starting mid-flush is never double-counted or lost
   * (SEGTEL edge case, same capture-at-enqueue shape as `mutateTags`).
   */
  internal fun handleSessionEnd(nowMs: Long) {
    val startedAt = deviceStore.getSessionStartedAtMs() ?: return
    val count = deviceStore.getSessionCount() + 1
    val timeMs = deviceStore.getSessionTimeMs() + (nowMs - startedAt)
    deviceStore.setSessionCount(count)
    deviceStore.setSessionTimeMs(timeMs)
    deviceStore.setLastSessionAtMs(nowMs)
    deviceStore.setSessionStartedAtMs(null)

    val firstAt = deviceStore.getFirstSessionAtMs()
    val snapshot = mutableMapOf<String, Any>(
      "last_session_at" to formatIsoUtc(nowMs),
      "session_count" to count,
      "session_time_seconds" to timeMs / 1000
    )
    if (firstAt != null) {
      snapshot["first_session_at"] = formatIsoUtc(firstAt)
    }
    mutate("session") { client, deviceId, token ->
      val result = client.patchDevice(deviceId, token, snapshot)
      when (result) {
        is ApiResult.Success -> Unit // backend is sink; aggregate already persisted
        is ApiResult.Failure -> logger("Notti.session: PATCH failed (${result.message}) - not retried")
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
            flushPendingMutations()
            syncAppVersionIfNeeded()
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
        val result = client.patchDevice(deviceId, token, mapOf("subscribed" to granted))
        when (result) {
          is ApiResult.Success -> deviceStore.setSubscribed(granted)
          is ApiResult.Failure -> logger(
            "Notti.requestPermission: backend PATCH failed after the user answered the OS prompt " +
              "(${result.message}) - local state now disagrees with the server and is not retried"
          )
        }
      }
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
   *
   * Handed to [executor] like every other mutation (and like iOS' `logout`,
   * which hops onto its `workQueue`) rather than written straight from the
   * caller's thread: `login("u1")` immediately followed by `logout()` would
   * otherwise clear the id synchronously *first*, and login's PATCH - still
   * queued on the executor - would then re-persist "u1" onto a device the
   * user had already logged out of.
   */
  fun logout() {
    dispatch("logout") { deviceStore.setExternalUserId(null) }
  }

  fun setSubscription(enabled: Boolean) {
    mutate("setSubscription") { client, deviceId, token ->
      val result = client.patchDevice(deviceId, token, mapOf("subscribed" to enabled))
      when (result) {
        is ApiResult.Success -> deviceStore.setSubscribed(enabled)
        is ApiResult.Failure -> logger("Notti.setSubscription: PATCH failed (${result.message}) - not retried")
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
    work: (client: NottiApiClient, deviceId: String, token: String) -> Unit
  ) {
    if (apiClient == null) {
      logger("Notti.$operation: called before initialize - ignored")
      return
    }
    dispatch(operation) { runOrQueue(PendingMutation(operation, work)) }
  }

  private fun runOrQueue(mutation: PendingMutation) {
    synchronized(mutationLock) {
      val deviceId = deviceStore.getDeviceId()
      val token = deviceStore.getLastToken()
      if (deviceId == null || token == null) {
        if (pendingMutations.size >= MAX_PENDING_MUTATIONS) {
          val dropped = pendingMutations.removeFirst()
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
   */
  private fun syncAppVersionIfNeeded() {
    val current = versionProvider() ?: return
    if (current == deviceStore.getAppVersion()) return
    mutate("appVersion") { client, deviceId, token ->
      val result = client.patchDevice(deviceId, token, mapOf("app_version" to current))
      when (result) {
        is ApiResult.Success -> deviceStore.setAppVersion(current)
        is ApiResult.Failure -> logger("Notti.syncAppVersion: PATCH failed (${result.message}) - not retried")
      }
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
    eventStore.all().forEach { event ->
      when (val result = client.reportEvent(event.notificationId, event.deliveryId, event.type, token)) {
        is EventResult.Success -> eventStore.remove(event.id)
        is EventResult.Failure ->
          if (result.terminal) {
            logger("Notti.flushEventQueue: event report terminally failed (${result.message}) - event dropped")
            eventStore.remove(event.id)
          } else {
            logger("Notti.flushEventQueue: event report failed (${result.message}) - event stays queued")
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
  private fun dispatch(operation: String, work: () -> Unit) {
    try {
      executor.execute {
        try {
          work()
        } catch (t: Throwable) {
          logger("Notti.$operation: unexpected failure - ${t.message}")
        }
      }
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
    }
  }

}
