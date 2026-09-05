package com.nuntis

/**
 * Orchestrates init, device registration, token refresh, permission
 * requests, and tag/external-id/subscription mutations (design.md
 * NuntisCore). `NuntisApiClient`/`NuntisDeviceStore` are constructor-injected
 * so both can be faked in tests; `tokenProvider` and `permissionRequester`
 * abstract the platform-specific push-token fetch and OS permission prompt
 * (owned by the concrete wiring in T8/NuntisModule — e.g. the Android <13
 * auto-grant behavior from spec P2-AC4 lives in whatever concrete
 * `permissionRequester` T8 wires in, not here).
 */
class NuntisCore(
  private val deviceStore: NuntisDeviceStore,
  private val apiClientFactory: (appId: String, clientKey: String) -> NuntisApiClient,
  private val tokenProvider: () -> String?,
  private val permissionRequester: (callback: (granted: Boolean) -> Unit) -> Unit,
  private val platform: String = "android",
  private val logger: (message: String) -> Unit = {}
) {

  private var appId: String? = null
  private var clientKey: String? = null
  private var apiClient: NuntisApiClient? = null
  private val mutationLock = Any()

  fun initialize(appId: String, clientKey: String) {
    if (appId.isBlank() || clientKey.isBlank()) {
      logger("Nuntis.initialize: appId or clientKey is missing/empty - skipping registration")
      return
    }

    // Repeat call with identical args in the same session: no-op (SDK-07).
    if (appId == this.appId && clientKey == this.clientKey) {
      return
    }

    this.appId = appId
    this.clientKey = clientKey
    val client = apiClientFactory(appId, clientKey)
    this.apiClient = client

    val token = tokenProvider()
    if (token == null) {
      logger("Nuntis.initialize: no push token available - skipping registration")
      return
    }
    registerDevice(client, token)
  }

  fun onTokenRefreshed(newToken: String) {
    val client = apiClient ?: return
    registerDevice(client, newToken)
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

    permissionRequester { granted ->
      patchIfRegistered(client) { mapOf("subscribed" to granted) }?.let {
        if (it is ApiResult.Success) deviceStore.setSubscribed(granted)
      }
      callback(granted)
    }
  }

  fun login(externalUserId: String) {
    val client = apiClient ?: return
    patchIfRegistered(client) { mapOf("external_user_id" to externalUserId) }?.let {
      if (it is ApiResult.Success) deviceStore.setExternalUserId(externalUserId)
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
    patchIfRegistered(client) { mapOf("subscribed" to enabled) }?.let {
      if (it is ApiResult.Success) deviceStore.setSubscribed(enabled)
    }
  }

  fun mutateTags(add: Map<String, String>?, remove: List<String>?) {
    val client = apiClient ?: return
    synchronized(mutationLock) {
      val deviceId = deviceStore.getDeviceId() ?: return
      val token = deviceStore.getLastToken() ?: return
      val merged = NuntisDeviceStore.mergeTags(deviceStore.getTags(), add, remove)
      val result = client.patchDevice(deviceId, token, mapOf("tags" to merged))
      if (result is ApiResult.Success) {
        deviceStore.setTags(result.response.tags)
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
