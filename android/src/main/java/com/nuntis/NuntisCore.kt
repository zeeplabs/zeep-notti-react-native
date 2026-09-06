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
  private val mutationLock = Any()

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
      dispatch("register") { registerDevice(client, token) }
    }
  }

  fun onTokenRefreshed(newToken: String) {
    val client = apiClient ?: return
    dispatch("onTokenRefreshed") { registerDevice(client, newToken) }
  }

  private fun registerDevice(client: NuntisApiClient, token: String) {
    when (val result = client.createOrUpdateDevice(token, platform)) {
      is ApiResult.Success -> {
        deviceStore.setDeviceId(result.response.id)
        deviceStore.setLastToken(token)
        deviceStore.setTags(result.response.tags)
      }
      is ApiResult.Failure -> {
        logger("Nuntis.initialize: device registration failed: ${result.message}")
      }
    }
  }

  fun requestPermission(callback: (granted: Boolean) -> Unit) {
    val client = apiClient
    if (client == null) {
      logger("Nuntis.requestPermission: called before initialize - not prompting")
      callback(false)
      return
    }

    // The OS prompt must be triggered from the caller's (UI-capable) thread -
    // only the resulting PATCH is handed to the executor.
    permissionRequester { granted ->
      dispatch("requestPermission") {
        patchIfRegistered(client) { mapOf("subscribed" to granted) }?.let {
          if (it is ApiResult.Success) deviceStore.setSubscribed(granted)
        }
      }
      callback(granted)
    }
  }

  fun login(externalUserId: String) {
    val client = apiClient ?: return
    dispatch("login") {
      patchIfRegistered(client) { mapOf("external_user_id" to externalUserId) }?.let {
        if (it is ApiResult.Success) deviceStore.setExternalUserId(externalUserId)
      }
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
    val client = apiClient ?: return
    dispatch("setSubscription") {
      patchIfRegistered(client) { mapOf("subscribed" to enabled) }?.let {
        if (it is ApiResult.Success) deviceStore.setSubscribed(enabled)
      }
    }
  }

  fun mutateTags(add: Map<String, String>?, remove: List<String>?) {
    val client = apiClient ?: return
    dispatch("mutateTags") {
      synchronized(mutationLock) {
        val deviceId = deviceStore.getDeviceId() ?: return@dispatch
        val token = deviceStore.getLastToken() ?: return@dispatch
        val merged = NuntisDeviceStore.mergeTags(deviceStore.getTags(), add, remove)
        val result = client.patchDevice(deviceId, token, mapOf("tags" to merged))
        if (result is ApiResult.Success) {
          deviceStore.setTags(result.response.tags)
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
    executor.execute {
      try {
        work()
      } catch (t: Throwable) {
        logger("Nuntis.$operation: unexpected failure - ${t.message}")
      }
    }
  }

  private fun patchIfRegistered(
    client: NuntisApiClient,
    fields: () -> Map<String, Any>
  ): ApiResult? {
    synchronized(mutationLock) {
      val deviceId = deviceStore.getDeviceId() ?: return null
      val token = deviceStore.getLastToken() ?: return null
      return client.patchDevice(deviceId, token, fields())
    }
  }
}
