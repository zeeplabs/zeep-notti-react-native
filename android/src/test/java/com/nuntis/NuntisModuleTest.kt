package com.nuntis

import android.app.Activity
import com.facebook.react.bridge.Callback
import com.facebook.react.bridge.CatalystInstance
import com.facebook.react.bridge.JavaScriptContextHolder
import com.facebook.react.bridge.JavaScriptModule
import com.facebook.react.bridge.NativeModule
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.UIManager
import com.facebook.react.bridge.WritableMap
import com.facebook.react.turbomodule.core.interfaces.CallInvokerHolder
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

/**
 * NuntisModule owns the real Android <13 permission auto-grant branch
 * (spec P2-AC4/SDK-11, `NuntisModule.kt`'s `requestNativePermission`) -
 * `NuntisCoreTest.kt` only exercises `NuntisCore`'s injected fake
 * `permissionRequester`, never this concrete `Build.VERSION.SDK_INT` check.
 * Constructing a real `NuntisModule` needs a `ReactApplicationContext`; RN
 * ships no test double for one, so [FakeReactApplicationContext] below
 * implements only the members `ReactContext` declares abstract - none of
 * them are reachable from the below-API-33 path this test exercises.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [32])
class NuntisModuleTest {

  @Test
  fun `requestPermission on Android below 13 resolves granted without ever touching the current activity`() {
    val context = FakeReactApplicationContext()
    val module = NuntisModule(context)
    // requestPermission only reaches the SDK_INT auto-grant check once
    // NuntisCore has an apiClient (set synchronously by initialize(), before
    // the async FCM-token fetch resolves) - mirrors NuntisCoreTest.kt's own
    // "called before initialize" guard on the same method.
    module.initialize("app-1", "key", "https://nuntis.example.com")

    var resolvedValue: Any? = null
    module.requestPermission(object : Promise {
      override fun resolve(value: Any?) {
        resolvedValue = value
      }
      override fun reject(code: String?, message: String?) = Unit
      override fun reject(code: String?, throwable: Throwable?) = Unit
      override fun reject(code: String?, message: String?, throwable: Throwable?) = Unit
      override fun reject(throwable: Throwable) = Unit
      override fun reject(throwable: Throwable, userInfo: WritableMap) = Unit
      override fun reject(code: String?, userInfo: WritableMap) = Unit
      override fun reject(code: String?, throwable: Throwable?, userInfo: WritableMap) = Unit
      override fun reject(code: String?, message: String?, userInfo: WritableMap) = Unit
      override fun reject(code: String?, message: String?, throwable: Throwable?, userInfo: WritableMap?) = Unit
      override fun reject(message: String) = Unit
    })

    // Below API 33 there is no runtime permission to request at all - if the
    // real implementation regressed to fall through to the
    // PermissionAwareActivity/requestPermissions path, FakeReactApplicationContext's
    // getCurrentActivity() below throws, failing this test instead of
    // silently resolving something.
    assertEquals(true, resolvedValue)
  }
}

/**
 * Minimal, test-only stand-in for the abstract `ReactApplicationContext` -
 * only implements what `ReactContext` requires to compile; every member is
 * either unused by the SDK<33 auto-grant path or deliberately throws to
 * prove that path never reaches it (see `getCurrentActivity` below).
 */
private class FakeReactApplicationContext :
  ReactApplicationContext(RuntimeEnvironment.getApplication()) {

  override fun getCurrentActivity(): Activity? {
    throw AssertionError("requestNativePermission must resolve before reading currentActivity below API 33")
  }

  override fun <T : JavaScriptModule> getJSModule(jsModuleInterface: Class<T>): T =
    throw UnsupportedOperationException("not used by the SDK<33 auto-grant path")

  override fun <T : NativeModule> hasNativeModule(nativeModuleInterface: Class<T>): Boolean = false

  override fun getNativeModules(): Collection<NativeModule> = emptyList()

  override fun <T : NativeModule> getNativeModule(nativeModuleInterface: Class<T>): T? = null

  override fun getNativeModule(nativeModuleName: String): NativeModule? = null

  override fun getCatalystInstance(): CatalystInstance =
    throw UnsupportedOperationException("not used by the SDK<33 auto-grant path")

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
