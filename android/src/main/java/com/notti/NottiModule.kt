package com.notti

import android.content.Context
import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReadableArray
import com.facebook.react.bridge.ReadableMap
import com.facebook.react.bridge.WritableMap
import com.zeeplabs.notti.NottiInAppAction
import com.zeeplabs.notti.NottiOptions

/**
 * The Turbo Module (android-native-sdk, ANSDK-01): every Spec method forwards
 * to [NottiAdapter], which maps it onto `br.com.zeeplabs:notti-android`. The
 * SDK owns everything below (HTTP, queues, stores, FCM service, process-start
 * provider, click detection, permission prompt, In-App engine); this module
 * keeps no executors, preferences or process-wide statics.
 *
 * [native] is internal so tests pass a fake; [NottiPackage] uses the public
 * constructor, which reaches the real SDK.
 */
class NottiModule internal constructor(
  reactContext: ReactApplicationContext,
  native: NottiNativeApi
) : NativeNottiSpec(reactContext) {

  constructor(reactContext: ReactApplicationContext) : this(reactContext, DefaultNottiNativeApi)

  /**
   * Where the adapter's events go: the generated `emitOn*` methods. A field so
   * tests can capture payloads, since the generated emitter is backed by a
   * native callback a unit test cannot set.
   */
  @Volatile
  internal var events: NottiEventSink = object : NottiEventSink {
    override fun notificationReceived(payload: WritableMap) = emitOnNotificationReceived(payload)

    override fun notificationClicked(payload: WritableMap) = emitOnNotificationClicked(payload)

    override fun deviceIdChanged(deviceId: String) = emitOnDeviceIdChanged(deviceId)

    override fun inAppMessageClicked(payload: WritableMap) = emitOnInAppMessageClicked(payload)
  }

  /** Reads [events] per delivery, so a later swap (tests) takes effect. */
  private val adapter = NottiAdapter(
    reactContext,
    native,
    object : NottiEventSink {
      override fun notificationReceived(payload: WritableMap) = events.notificationReceived(payload)

      override fun notificationClicked(payload: WritableMap) = events.notificationClicked(payload)

      override fun deviceIdChanged(deviceId: String) = events.deviceIdChanged(deviceId)

      override fun inAppMessageClicked(payload: WritableMap) = events.inAppMessageClicked(payload)
    }
  )

  // Last constructor step (ANSDK-06): listeners are added only once every
  // field above is assigned, so a delivery never sees a partial instance.
  init {
    adapter.start()
  }

  /**
   * RN tears a module down on context destruction and on every dev reload.
   * Removing the listeners first means nothing is emitted into this instance
   * afterwards; the next instance adds its own.
   */
  override fun invalidate() {
    adapter.stop()
    super.invalidate()
  }

  override fun initialize(appId: String?, clientKey: String?, baseUrl: String?, sdkVersion: String?) =
    adapter.initialize(appId, clientKey, baseUrl, sdkVersion)

  override fun requestPermission(promise: Promise?) = adapter.requestPermission(promise)

  override fun login(externalUserId: String?) = adapter.login(externalUserId)

  override fun logout() = adapter.logout()

  override fun addTags(tags: ReadableMap?) = adapter.addTags(tags)

  override fun removeTags(keys: ReadableArray?) = adapter.removeTags(keys)

  override fun setSubscription(enabled: Boolean) = adapter.setSubscription(enabled)

  override fun setLocationSharingEnabled(enabled: Boolean) = adapter.setLocationSharingEnabled(enabled)

  override fun setEmail(email: String?) = adapter.setEmail(email)

  override fun clearEmail() = adapter.clearEmail()

  override fun setPhone(phone: String?) = adapter.setPhone(phone)

  override fun clearPhone() = adapter.clearPhone()

  override fun getDeviceId(): String? = adapter.getDeviceId()

  override fun trackEvent(name: String?) = adapter.trackEvent(name)

  override fun getInitialNotificationClick(promise: Promise?) = adapter.getInitialNotificationClick(promise)

  companion object {
    const val NAME = NativeNottiSpec.NAME
  }
}

/**
 * The Turbo Module adapter (android-native-sdk design, "NottiModule" and
 * "Staging"): maps each Codegen call to `br.com.zeeplabs:notti-android`
 * through [native] and the SDK's listeners to [events]. No business
 * logic: null handling only, with 0.8.0's rules (method mapping table).
 *
 * [context] is any context of the app; only its application context reaches
 * the SDK. Every method may run on any thread: the SDK facade is thread-safe
 * and answers callbacks on the main thread.
 */
internal class NottiAdapter(
  private val context: Context,
  private val native: NottiNativeApi,
  private val events: NottiEventSink
) {

  /**
   * Wrapper identity (ANSDK-03, native AD-022): the backend sees
   * `sdk_name: "react-native"` and the RN package version. AD-004: the SDK
   * never opens an In-App link, so `opensInAppUrls` is always off. Blank ids or
   * an invalid URL are logged and ignored by the SDK, as 0.8.0's core did.
   */
  fun initialize(appId: String?, clientKey: String?, baseUrl: String?, sdkVersion: String?) {
    native.initializeForWrapper(
      context.applicationContext ?: context,
      appId.orEmpty(),
      clientKey.orEmpty(),
      NottiOptions(baseUrl, opensInAppUrls = false),
      SDK_NAME,
      sdkVersion
    )
  }

  /** Resolves the OS answer; never rejects (0.8.0 never did). `false` before `initialize`. */
  fun requestPermission(promise: Promise?) {
    native.requestPermission { granted -> promise?.resolve(granted) }
  }

  fun login(externalUserId: String?) {
    externalUserId?.let { native.login(it) }
  }

  fun logout() {
    native.logout()
  }

  /**
   * Non-string values are dropped, not coerced (0.8.0 I7: the TS type promises
   * strings, and iOS filters the same way). An empty or null map still reaches
   * the SDK, which sends the unchanged merge like 0.8.0.
   */
  fun addTags(tags: ReadableMap?) {
    val add = tags?.toHashMap()
      ?.mapNotNull { (key, value) -> (value as? String)?.let { key to it } }
      ?.toMap() ?: emptyMap()
    native.addTags(add)
  }

  fun removeTags(keys: ReadableArray?) {
    native.removeTags(keys?.toArrayList()?.map { it.toString() } ?: emptyList())
  }

  fun setSubscription(enabled: Boolean) {
    native.setSubscription(enabled)
  }

  fun setLocationSharingEnabled(enabled: Boolean) {
    native.setLocationSharingEnabled(enabled)
  }

  fun setEmail(email: String?) {
    email?.let { native.setEmail(it) }
  }

  fun clearEmail() {
    native.clearEmail()
  }

  fun setPhone(phone: String?) {
    phone?.let { native.setPhone(it) }
  }

  fun clearPhone() {
    native.clearPhone()
  }

  /** Synchronous on the JS thread; the SDK's provider loaded `notti_prefs` at process start. */
  fun getDeviceId(): String? = native.deviceId()

  /** Matched locally by the In-App engine; never sent or logged. */
  fun trackEvent(name: String?) {
    name?.let { native.trackEvent(it) }
  }

  /**
   * The cold-start tap, once (ANSDK-07). The SDK keeps a tap only while no
   * clicked listener exists and never replays it to a new one (its relay is
   * 0.8.0's), so a tap from before [start] is pulled here, not emitted.
   */
  fun getInitialNotificationClick(promise: Promise?) {
    promise?.resolve(native.takeInitialClick()?.toPayload())
  }

  private val subscriptions = mutableListOf<NativeSubscription>()

  /**
   * Adds the four SDK listeners (ANSDK-05). Called once per module instance,
   * as its last construction step; a second call does nothing. Listeners run
   * on the main thread.
   */
  fun start() {
    synchronized(subscriptions) {
      if (subscriptions.isNotEmpty()) return
      subscriptions += native.addReceivedListener { events.notificationReceived(it.toPayload()) }
      subscriptions += native.addClickedListener { events.notificationClicked(it.toPayload()) }
      subscriptions += native.addDeviceIdChangedListener { events.deviceIdChanged(it) }
      subscriptions += native.addInAppClickListener { events.inAppMessageClicked(it.toPayload()) }
    }
  }

  /**
   * Removes every listener [start] added (ANSDK-06), so nothing is emitted
   * into a torn-down module; the SDK drops a removed listener even for a
   * delivery already posted to main. Idempotent.
   */
  fun stop() {
    val removed = synchronized(subscriptions) { subscriptions.toList().also { subscriptions.clear() } }
    removed.forEach { it.remove() }
  }

  companion object {
    /** The `sdk_name` this package reports (backend enum, `zeep-notti` AD-044). */
    const val SDK_NAME = "react-native"
  }
}

/** `NotificationPayload`: `title`/`body` present with `null` when missing, `data` always a map (0.8.0 shape). */
internal fun NativeNotification.toPayload(): WritableMap {
  val map = Arguments.createMap()
  map.putString("title", title)
  map.putString("body", body)
  val dataMap = Arguments.createMap()
  data.forEach { (key, value) -> dataMap.putString(key, value) }
  map.putMap("data", dataMap)
  return map
}

/**
 * `InAppClickPayload`: `action` is `null`, never absent, for `push_permission`
 * (the SDK gives no action), a button without a valid action, and an action
 * type this package does not know (design OQ-3).
 */
internal fun NativeInAppClick.toPayload(): WritableMap {
  val map = Arguments.createMap()
  map.putString("messageId", messageId)
  map.putString("buttonId", buttonId)
  val type = actionType?.toJsActionType()
  val value = actionValue
  if (type == null || value == null) {
    map.putNull("action")
  } else {
    val actionMap = Arguments.createMap()
    actionMap.putString("type", type)
    actionMap.putString("value", value)
    map.putMap("action", actionMap)
  }
  return map
}

/** The 0.8.0 action type strings; null for a value a later SDK minor may add (native AD-018). */
internal fun NottiInAppAction.Type.toJsActionType(): String? = when (this) {
  NottiInAppAction.Type.URL -> "url"
  NottiInAppAction.Type.DEEPLINK -> "deeplink"
  else -> null
}
