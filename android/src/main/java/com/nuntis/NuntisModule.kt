package com.nuntis

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReadableArray
import com.facebook.react.bridge.ReadableMap
import com.facebook.react.modules.core.PermissionAwareActivity
import com.facebook.react.modules.core.PermissionListener
import okhttp3.OkHttpClient

/**
 * Thin TurboModule entry: every Spec method (T4) delegates one line into
 * [NuntisCore] (T7). The only real logic kept here is Android's own runtime
 * permission plumbing (`PermissionAwareActivity`/SDK_INT check), since
 * that's platform wiring, not the retry/tag-merge/queue business logic
 * NuntisCore owns.
 */
class NuntisModule(reactContext: ReactApplicationContext) :
  NativeNuntisSpec(reactContext) {

  private val core: NuntisCore by lazy {
    NuntisCore(
      deviceStore = NuntisDeviceStore(
        reactApplicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
      ),
      apiClientFactory = { appId, clientKey ->
        NuntisApiClient(OkHttpClient(), NUNTIS_API_BASE_URL, appId, clientKey)
      },
      tokenProvider = {
        // SPEC_DEVIATION: real FCM token fetch lands in T9, once
        // com.google.firebase:firebase-messaging is added as a dependency
        // (T8 depends only on T4/T7, not T9). NuntisCore already logs and
        // no-ops safely when this returns null (SDK-04, verified in T7).
        null
      },
      permissionRequester = { callback -> requestNativePermission(callback) }
    )
  }

  override fun initialize(appId: String?, clientKey: String?) {
    core.initialize(appId.orEmpty(), clientKey.orEmpty())
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

    // SPEC_DEVIATION: Nuntis' base API host is not specified in spec.md or
    // design.md (Nuntis.initialize only takes appId/clientKey, no host
    // parameter) - flagged for the orchestrator to confirm before ship.
    private const val NUNTIS_API_BASE_URL = "https://api.nuntis.io"
  }
}
