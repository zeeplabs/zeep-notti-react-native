package com.notti

import android.app.Activity
import android.content.Context
import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.Callback
import com.facebook.react.bridge.CatalystInstance
import com.facebook.react.bridge.JavaOnlyMap
import com.facebook.react.bridge.JavaScriptContextHolder
import com.facebook.react.bridge.JavaScriptModule
import com.facebook.react.bridge.NativeModule
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.RuntimeExecutor
import com.facebook.react.bridge.UIManager
import com.facebook.react.bridge.WritableMap
import com.facebook.react.turbomodule.core.interfaces.CallInvokerHolder
import com.zeeplabs.notti.NottiOptions
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Implementation
import org.robolectric.annotation.Implements

/**
 * `Arguments.createMap()` normally returns a JNI-backed `WritableNativeMap`,
 * which needs a real native library that isn't available on the plain JVM
 * Robolectric runs on. This shadow swaps it for `JavaOnlyMap`, RN's own
 * pure-Java `WritableMap` implementation meant exactly for unit tests with no
 * native bridge, so payload-building code can run end to end.
 */
@Implements(Arguments::class)
class ShadowArguments {
  companion object {
    @Implementation
    @JvmStatic
    fun createMap(): WritableMap = JavaOnlyMap()
  }
}

/** One recorded [NottiNativeApi] call: the method name and its arguments, in order. */
internal data class NativeCall(val name: String, val args: List<Any?> = emptyList())

/**
 * In-memory [NottiNativeApi] (android-native-sdk design, "Test plan"). Records
 * every call, holds the listeners it was given so a test can fire native
 * events, and counts the subscriptions still live. Delivery is synchronous on
 * the test thread; the real SDK posts to main, which the adapter does not rely
 * on.
 */
internal class FakeNottiNativeApi : NottiNativeApi {
  val calls = mutableListOf<NativeCall>()

  /** The context the last [initializeForWrapper] received; kept out of [calls] (not a value type). */
  var initializeContext: Context? = null

  /** What [deviceId] returns. */
  var deviceIdValue: String? = null

  /** What [requestPermission] answers; null leaves the callback pending in [pendingPermission]. */
  var permissionResult: Boolean? = false
  var pendingPermission: ((Boolean) -> Unit)? = null

  /** What [takeInitialClick] returns once, then null (native relay contract). */
  var initialClick: NativeNotification? = null

  private val received = mutableListOf<Handle<NativeNotification>>()
  private val clicked = mutableListOf<Handle<NativeNotification>>()
  private val deviceIdChanged = mutableListOf<Handle<String>>()
  private val inAppClicks = mutableListOf<Handle<NativeInAppClick>>()

  /** Listeners added and not yet removed, across the four events. */
  val liveSubscriptions: Int
    get() = listOf(received, clicked, deviceIdChanged, inAppClicks).sumOf { list -> list.count { it.live } }

  fun callsNamed(name: String): List<NativeCall> = calls.filter { it.name == name }

  fun fireReceived(notification: NativeNotification) = fire(received, notification)

  fun fireClicked(notification: NativeNotification) = fire(clicked, notification)

  fun fireDeviceIdChanged(deviceId: String) = fire(deviceIdChanged, deviceId)

  fun fireInAppClick(click: NativeInAppClick) = fire(inAppClicks, click)

  override fun initializeForWrapper(
    context: Context,
    appId: String,
    clientKey: String,
    options: NottiOptions,
    sdkName: String,
    sdkVersion: String?
  ) {
    initializeContext = context
    record("initializeForWrapper", appId, clientKey, options, sdkName, sdkVersion)
  }

  override fun login(externalUserId: String) = record("login", externalUserId)

  override fun logout() = record("logout")

  override fun addTags(tags: Map<String, String>) = record("addTags", tags)

  override fun removeTags(keys: List<String>) = record("removeTags", keys)

  override fun setSubscription(enabled: Boolean) = record("setSubscription", enabled)

  override fun setLocationSharingEnabled(enabled: Boolean) = record("setLocationSharingEnabled", enabled)

  override fun setEmail(email: String) = record("setEmail", email)

  override fun clearEmail() = record("clearEmail")

  override fun setPhone(phone: String) = record("setPhone", phone)

  override fun clearPhone() = record("clearPhone")

  override fun deviceId(): String? {
    record("deviceId")
    return deviceIdValue
  }

  override fun trackEvent(name: String) = record("trackEvent", name)

  override fun requestPermission(callback: (Boolean) -> Unit) {
    record("requestPermission")
    val result = permissionResult
    if (result == null) pendingPermission = callback else callback(result)
  }

  override fun takeInitialClick(): NativeNotification? {
    record("takeInitialClick")
    return initialClick.also { initialClick = null }
  }

  override fun addReceivedListener(listener: (NativeNotification) -> Unit) = add(received, listener)

  override fun addClickedListener(listener: (NativeNotification) -> Unit) = add(clicked, listener)

  override fun addDeviceIdChangedListener(listener: (String) -> Unit) = add(deviceIdChanged, listener)

  override fun addInAppClickListener(listener: (NativeInAppClick) -> Unit) = add(inAppClicks, listener)

  private fun record(name: String, vararg args: Any?) {
    calls.add(NativeCall(name, args.toList()))
  }

  private class Handle<T>(val listener: (T) -> Unit) {
    var live = true
  }

  private fun <T> add(list: MutableList<Handle<T>>, listener: (T) -> Unit): NativeSubscription {
    val handle = Handle(listener)
    list.add(handle)
    return NativeSubscription { handle.live = false }
  }

  private fun <T> fire(list: List<Handle<T>>, value: T) {
    list.filter { it.live }.forEach { it.listener(value) }
  }
}

/** [NottiEventSink] that keeps every emitted payload, per event, in order. */
internal class CapturingEventSink : NottiEventSink {
  val received = mutableListOf<WritableMap>()
  val clicked = mutableListOf<WritableMap>()
  val deviceIds = mutableListOf<String>()
  val inAppClicks = mutableListOf<WritableMap>()

  override fun notificationReceived(payload: WritableMap) {
    received.add(payload)
  }

  override fun notificationClicked(payload: WritableMap) {
    clicked.add(payload)
  }

  override fun deviceIdChanged(deviceId: String) {
    deviceIds.add(deviceId)
  }

  override fun inAppMessageClicked(payload: WritableMap) {
    inAppClicks.add(payload)
  }
}

/** [Promise] that records what it was settled with; every `reject` overload counts as one rejection. */
internal class SettledPromise : Promise {
  val resolved = mutableListOf<Any?>()
  var rejections = 0
    private set

  override fun resolve(value: Any?) {
    resolved.add(value)
  }

  override fun reject(code: String?, message: String?) = rejected()
  override fun reject(code: String?, throwable: Throwable?) = rejected()
  override fun reject(code: String?, message: String?, throwable: Throwable?) = rejected()
  override fun reject(throwable: Throwable) = rejected()
  override fun reject(throwable: Throwable, userInfo: WritableMap) = rejected()
  override fun reject(code: String?, userInfo: WritableMap) = rejected()
  override fun reject(code: String?, throwable: Throwable?, userInfo: WritableMap) = rejected()
  override fun reject(code: String?, message: String?, userInfo: WritableMap) = rejected()
  override fun reject(code: String?, message: String?, throwable: Throwable?, userInfo: WritableMap?) = rejected()
  override fun reject(message: String) = rejected()

  private fun rejected() {
    rejections++
  }
}

/**
 * Minimal, test-only stand-in for the abstract `ReactApplicationContext`, so a
 * real [NottiModule] can be constructed: it implements only what
 * `ReactContext` declares abstract, and no member is reachable from the
 * module, which hands the SDK the application context and nothing else.
 */
internal class FakeReactApplicationContext :
  ReactApplicationContext(RuntimeEnvironment.getApplication()) {

  override fun getCurrentActivity(): Activity? = null

  override fun <T : JavaScriptModule> getJSModule(jsModuleInterface: Class<T>): T =
    throw UnsupportedOperationException("not used by NottiModule")

  override fun <T : NativeModule> hasNativeModule(nativeModuleInterface: Class<T>): Boolean = false

  override fun getNativeModules(): Collection<NativeModule> = emptyList()

  override fun <T : NativeModule> getNativeModule(nativeModuleInterface: Class<T>): T? = null

  override fun getNativeModule(nativeModuleName: String): NativeModule? = null

  override fun getRuntimeExecutor(): RuntimeExecutor? = null

  override fun getCatalystInstance(): CatalystInstance =
    throw UnsupportedOperationException("not used by NottiModule")

  override fun hasActiveCatalystInstance(): Boolean = false

  override fun hasActiveReactInstance(): Boolean = false

  override fun hasCatalystInstance(): Boolean = false

  override fun hasReactInstance(): Boolean = false

  override fun destroy() = Unit

  override fun handleException(e: Exception) = Unit

  override fun isBridgeless(): Boolean = false

  override fun getJavaScriptContextHolder(): JavaScriptContextHolder? = null

  override fun getJSCallInvokerHolder(): CallInvokerHolder? = null

  override fun getFabricUIManager(): UIManager? = null

  override fun getSourceURL(): String = ""

  override fun registerSegment(segmentId: Int, path: String?, callback: Callback?) = Unit
}
