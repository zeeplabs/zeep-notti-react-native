package com.notti

import android.content.Context
import com.facebook.react.bridge.WritableMap
import com.zeeplabs.notti.Notti
import com.zeeplabs.notti.NottiInAppAction
import com.zeeplabs.notti.NottiInAppClick
import com.zeeplabs.notti.NottiNotification
import com.zeeplabs.notti.NottiOptions
import com.zeeplabs.notti.NottiSubscription
import com.zeeplabs.notti.NottiWrapperApi

/**
 * A push as the adapter sees it (android-native-sdk design, "Seam"). Mirrors
 * the native `NottiNotification`, whose constructor is `internal` to the SDK,
 * so tests can build one.
 */
internal data class NativeNotification(
  val title: String?,
  val body: String?,
  val data: Map<String, String>
)

/**
 * An In-App click as the adapter sees it. [actionType] and [actionValue] are
 * both null when the native click has no action (`push_permission` or no
 * valid action); the native `NottiInAppAction` constructor is `internal`, the
 * public [NottiInAppAction.Type] enum is not.
 */
internal data class NativeInAppClick(
  val messageId: String,
  val buttonId: String,
  val actionType: NottiInAppAction.Type?,
  val actionValue: String?
)

/** Stops one listener added through [NottiNativeApi]. Idempotent. */
internal fun interface NativeSubscription {
  fun remove()
}

/**
 * Every call the adapter makes into `br.com.zeeplabs:notti-android`. The
 * native facade is a static object with `internal` test hooks, so the adapter
 * depends on this interface and tests pass a fake; [DefaultNottiNativeApi] is
 * the only place that touches `com.zeeplabs.notti.Notti`.
 *
 * Null handling is the adapter's job (0.8.0 parity): every text parameter here
 * is non-null except where the native call itself takes null as a value.
 * Listeners and callbacks run on the main thread (native contract).
 */
internal interface NottiNativeApi {
  fun initializeForWrapper(
    context: Context,
    appId: String,
    clientKey: String,
    options: NottiOptions,
    sdkName: String,
    sdkVersion: String?
  )

  fun login(externalUserId: String)
  fun logout()
  fun addTags(tags: Map<String, String>)
  fun removeTags(keys: List<String>)
  fun setSubscription(enabled: Boolean)
  fun setLocationSharingEnabled(enabled: Boolean)
  fun setEmail(email: String)
  fun clearEmail()
  fun setPhone(phone: String)
  fun clearPhone()
  fun deviceId(): String?
  fun trackEvent(name: String)
  fun requestPermission(callback: (Boolean) -> Unit)
  fun takeInitialClick(): NativeNotification?

  fun addReceivedListener(listener: (NativeNotification) -> Unit): NativeSubscription
  fun addClickedListener(listener: (NativeNotification) -> Unit): NativeSubscription
  fun addDeviceIdChangedListener(listener: (String) -> Unit): NativeSubscription
  fun addInAppClickListener(listener: (NativeInAppClick) -> Unit): NativeSubscription
}

/**
 * The four Codegen events. Production emits through the generated `emitOn*`
 * methods; tests capture the payloads, since the generated emitter is backed
 * by a native callback a unit test cannot set.
 */
internal interface NottiEventSink {
  fun notificationReceived(payload: WritableMap)
  fun notificationClicked(payload: WritableMap)
  fun deviceIdChanged(deviceId: String)
  fun inAppMessageClicked(payload: WritableMap)
}

/** Production [NottiNativeApi]: one-line forwards to the native facade. */
internal object DefaultNottiNativeApi : NottiNativeApi {
  /** Wrapper identity (native AD-022, design G1): the RN package reports itself, not `android`. */
  @OptIn(NottiWrapperApi::class)
  override fun initializeForWrapper(
    context: Context,
    appId: String,
    clientKey: String,
    options: NottiOptions,
    sdkName: String,
    sdkVersion: String?
  ) = Notti.initializeForWrapper(context, appId, clientKey, options, sdkName, sdkVersion)

  override fun login(externalUserId: String) = Notti.login(externalUserId)

  override fun logout() = Notti.logout()

  override fun addTags(tags: Map<String, String>) = Notti.User.addTags(tags)

  override fun removeTags(keys: List<String>) = Notti.User.removeTags(keys)

  override fun setSubscription(enabled: Boolean) = Notti.setSubscription(enabled)

  override fun setLocationSharingEnabled(enabled: Boolean) = Notti.setLocationSharingEnabled(enabled)

  override fun setEmail(email: String) = Notti.User.setEmail(email)

  override fun clearEmail() = Notti.User.clearEmail()

  override fun setPhone(phone: String) = Notti.User.setPhone(phone)

  override fun clearPhone() = Notti.User.clearPhone()

  override fun deviceId(): String? = Notti.deviceId

  override fun trackEvent(name: String) = Notti.trackEvent(name)

  override fun requestPermission(callback: (Boolean) -> Unit) =
    Notti.Notifications.requestPermission { granted -> callback(granted) }

  override fun takeInitialClick(): NativeNotification? = Notti.Notifications.takeInitialClick()?.toNative()

  override fun addReceivedListener(listener: (NativeNotification) -> Unit): NativeSubscription =
    Notti.Notifications.addReceivedListener { listener(it.toNative()) }.toNative()

  override fun addClickedListener(listener: (NativeNotification) -> Unit): NativeSubscription =
    Notti.Notifications.addClickedListener { listener(it.toNative()) }.toNative()

  override fun addDeviceIdChangedListener(listener: (String) -> Unit): NativeSubscription =
    Notti.addDeviceIdChangedListener { listener(it) }.toNative()

  override fun addInAppClickListener(listener: (NativeInAppClick) -> Unit): NativeSubscription =
    Notti.InAppMessages.addClickListener { listener(it.toNative()) }.toNative()

  private fun NottiNotification.toNative() = NativeNotification(title, body, data)

  private fun NottiInAppClick.toNative() = NativeInAppClick(messageId, buttonId, action?.type, action?.value)

  private fun NottiSubscription.toNative() = NativeSubscription { remove() }
}
