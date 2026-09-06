package com.nuntis

import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import java.util.concurrent.Executor
import java.util.concurrent.Executors

/**
 * Orchestrates init, device registration, token refresh, permission
 * requests, and tag/external-id/subscription mutations (design.md
 * NuntisCore). `NuntisApiClient`/`NuntisDeviceStore` are constructor-injected
 * so both can be faked in tests; `tokenProvider` and `permissionRequester`
 * abstract the platform-specific push-token fetch and OS permission prompt
 * (owned by the concrete wiring in T8/NuntisModule — e.g. the Android <13
 * auto-grant behavior from spec P2-AC4 lives in whatever concrete
 * `permissionRequester` T8 wires in, not here). `tokenProvider` is
 * callback-based rather than a plain synchronous getter, since the real FCM
 * token fetch (`FirebaseMessaging.getInstance().token`) is an asynchronous
 * Play Services `Task`, not a synchronous call.
 *
 * ## Threading
 *
 * Every call that can reach [NuntisApiClient] (blocking OkHttp `execute()`
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
class NuntisCore(
  private val deviceStore: NuntisDeviceStore,
  private val apiClientFactory: (appId: String, clientKey: String, baseUrl: String) -> NuntisApiClient,
  private val tokenProvider: (callback: (token: String?) -> Unit) -> Unit,
  private val permissionRequester: (callback: (granted: Boolean) -> Unit) -> Unit,
  private val platform: String = "android",
  private val logger: (message: String) -> Unit = {},
  private val executor: Executor = newDefaultExecutor()
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
      Thread(runnable, "nuntis-io").apply { isDaemon = true }
    }
  }

  private var appId: String? = null
  private var clientKey: String? = null
  private var baseUrl: String? = null
  @Volatile
  private var apiClient: NuntisApiClient? = null

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
   * Mutations issued before registration completes (`Nuntis.initialize()`
   * immediately followed by `login`/`addTags`/`requestPermission`, which is
   * the normal app-startup shape) have no device id or token to PATCH yet.
   * Dropping them - as this used to - loses them permanently with nothing to
   * retry, so they are held here and flushed in call order once registration
   * succeeds. In-memory only, per the spec's Edge Case: a queued call is
   * dropped on process death rather than replayed later with stale state.
   * Guarded by [mutationLock].
   */
  private val pendingMutations = ArrayDeque<PendingMutation>()

  private class PendingMutation(
    val operation: String,
    val client: NuntisApiClient,
    val work: (client: NuntisApiClient, deviceId: String, token: String) -> Unit
  )

  fun initialize(appId: String, clientKey: String, baseUrl: String) {
    if (appId.isBlank() || clientKey.isBlank() || baseUrl.isBlank()) {
      logger("Nuntis.initialize: appId, clientKey, or baseUrl is missing/empty - skipping registration")
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
        "Nuntis.initialize: baseUrl \"$baseUrl\" is not a valid http(s) URL " +
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
        logger("Nuntis.initialize: no push token available - skipping registration")
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
   * the only recovery path the spec gives once `NuntisApiClient` has burned
   * through its 5-attempt backoff (SDK-05) - otherwise a device that was
   * offline at launch stays unregistered until the process is killed.
   *
   * A no-op unless registration actually needs it: already registered, or an
   * attempt is still in flight (so repeated foregrounds cannot stack attempts
   * or start a retry storm).
   */
  fun onAppForegrounded() {
    val client = apiClient ?: return
    if (registrationState == RegistrationState.REGISTERED ||
      registrationState == RegistrationState.IN_FLIGHT
    ) {
      return
    }

    registrationState = RegistrationState.IN_FLIGHT
    tokenProvider { token ->
      if (token == null) {
        registrationState = RegistrationState.FAILED
        logger("Nuntis.onAppForegrounded: no push token available - registration not retried")
        return@tokenProvider
      }
      dispatch("onAppForegrounded") { registerDevice(client, token) }
    }
  }

  /**
   * Holds [mutationLock] across the whole call/response/store-write sequence,
   * for the same reason `mutateTags` does: the POST response carries the
   * device's server-side `tags`, so registration is itself a read-modify-write
   * on the cached tag map. An `onNewToken` re-registration landing (on the FCM
   * thread) mid-`addTags` would otherwise answer from the server's pre-PATCH
   * state and overwrite the tag that was just merged and persisted.
   */
  private fun registerDevice(client: NuntisApiClient, token: String) {
    synchronized(mutationLock) {
      when (val result = client.createOrUpdateDevice(token, platform)) {
        is ApiResult.Success -> {
          deviceStore.setDeviceId(result.response.id)
          deviceStore.setLastToken(token)
          deviceStore.setTags(result.response.tags)
          registrationState = RegistrationState.REGISTERED
          flushPendingMutations()
        }
        is ApiResult.Failure -> {
          registrationState = RegistrationState.FAILED
          logger(
            "Nuntis.initialize: device registration failed: ${result.message} " +
              "- retrying on the next app foreground or token refresh"
          )
        }
      }
    }
  }

  fun requestPermission(callback: (granted: Boolean) -> Unit) {
    if (apiClient == null) {
      logger("Nuntis.requestPermission: called before initialize - not prompting")
      callback(false)
      return
    }

    // The OS prompt must be triggered from the caller's (UI-capable) thread -
    // only the resulting PATCH is handed to the executor.
    permissionRequester { granted ->
      mutate("requestPermission") { client, deviceId, token ->
        val result = client.patchDevice(deviceId, token, mapOf("subscribed" to granted))
        if (result is ApiResult.Success) deviceStore.setSubscribed(granted)
      }
      callback(granted)
    }
  }

  fun login(externalUserId: String) {
    mutate("login") { client, deviceId, token ->
      val result = client.patchDevice(deviceId, token, mapOf("external_user_id" to externalUserId))
      if (result is ApiResult.Success) deviceStore.setExternalUserId(externalUserId)
    }
  }

  /**
   * The backend does not support clearing `external_user_id` server-side
   * (spec Edge Case) - only the SDK's locally-held association is cleared.
   */
  fun logout() {
    deviceStore.setExternalUserId(null)
  }

  fun setSubscription(enabled: Boolean) {
    mutate("setSubscription") { client, deviceId, token ->
      val result = client.patchDevice(deviceId, token, mapOf("subscribed" to enabled))
      if (result is ApiResult.Success) deviceStore.setSubscribed(enabled)
    }
  }

  fun mutateTags(add: Map<String, String>?, remove: List<String>?) {
    mutate("mutateTags") { client, deviceId, token ->
      val merged = NuntisDeviceStore.mergeTags(deviceStore.getTags(), add, remove)
      val result = client.patchDevice(deviceId, token, mapOf("tags" to merged))
      if (result is ApiResult.Success) {
        deviceStore.setTags(result.response.tags)
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
    work: (client: NuntisApiClient, deviceId: String, token: String) -> Unit
  ) {
    val client = apiClient
    if (client == null) {
      logger("Nuntis.$operation: called before initialize - ignored")
      return
    }
    dispatch(operation) { runOrQueue(PendingMutation(operation, client, work)) }
  }

  private fun runOrQueue(mutation: PendingMutation) {
    synchronized(mutationLock) {
      val deviceId = deviceStore.getDeviceId()
      val token = deviceStore.getLastToken()
      if (deviceId == null || token == null) {
        if (pendingMutations.size >= MAX_PENDING_MUTATIONS) {
          val dropped = pendingMutations.removeFirst()
          logger("Nuntis.${dropped.operation}: pending-mutation queue full - dropped the oldest queued call")
        }
        pendingMutations.addLast(mutation)
        logger("Nuntis.${mutation.operation}: device not registered yet - queued until registration completes")
        return
      }
      mutation.work(mutation.client, deviceId, token)
    }
  }

  /** Called from [registerDevice] while [mutationLock] is held. */
  private fun flushPendingMutations() {
    if (pendingMutations.isEmpty()) return
    val deviceId = deviceStore.getDeviceId() ?: return
    val token = deviceStore.getLastToken() ?: return
    val queued = pendingMutations.toList()
    pendingMutations.clear()
    queued.forEach { mutation ->
      try {
        mutation.work(mutation.client, deviceId, token)
      } catch (t: Throwable) {
        logger("Nuntis.${mutation.operation}: queued call failed - ${t.message}")
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
    executor.execute {
      try {
        work()
      } catch (t: Throwable) {
        logger("Nuntis.$operation: unexpected failure - ${t.message}")
      }
    }
  }

}
