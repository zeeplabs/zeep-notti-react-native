package com.nuntis

import android.app.Activity
import android.os.Bundle
import com.facebook.react.bridge.Callback
import com.facebook.react.bridge.CatalystInstance
import com.facebook.react.bridge.JavaScriptContextHolder
import com.facebook.react.bridge.JavaScriptModule
import com.facebook.react.bridge.NativeModule
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.RuntimeExecutor
import com.facebook.react.bridge.UIManager
import com.facebook.react.turbomodule.core.interfaces.CallInvokerHolder
import com.google.firebase.messaging.RemoteMessage
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

/**
 * NuntisBridge is the manual-forwarding counterpart to the automatic path
 * NuntisModuleTest/NuntisFirebaseMessagingServiceTest already cover; this
 * only proves the public entry points reach the same active module/core
 * without throwing, since a real NuntisModule must be active either way.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], shadows = [ShadowArguments::class])
class NuntisBridgeTest {

  @Test
  fun `onMessageReceived is a safe no-op when no module is active`() {
    // Actually emitting to JS needs a real TurboModule event-emitter bridge,
    // which no fake ReactApplicationContext provides (same limitation
    // NuntisModuleTest works around via the click relay's injected emitter
    // lambda) -- this only proves onMessageReceived's own null-guard, not
    // the Codegen emit path itself (already exercised elsewhere).
    val module = NuntisModule(BridgeFakeReactApplicationContext())
    module.initialize("app-1", "key", "https://nuntis.example.com")
    module.invalidate()
    assertNull(NuntisModule.activeCore)

    val bundle = Bundle().apply {
      putString("gcm.n.title", "Hello")
      putString("gcm.n.body", "World")
    }

    NuntisBridge.onMessageReceived(RemoteMessage(bundle))
  }

  @Test
  fun `onNewToken reaches the active core without throwing`() {
    val module = NuntisModule(BridgeFakeReactApplicationContext())
    module.initialize("app-1", "key", "https://nuntis.example.com")
    assertNotNull(NuntisModule.activeCore)

    NuntisBridge.onNewToken("new-token-value")
  }
}

private class BridgeFakeReactApplicationContext :
  ReactApplicationContext(RuntimeEnvironment.getApplication()) {

  override fun getCurrentActivity(): Activity? = null

  override fun <T : JavaScriptModule> getJSModule(jsModuleInterface: Class<T>): T =
    throw UnsupportedOperationException("not used by NuntisBridgeTest")

  override fun <T : NativeModule> hasNativeModule(nativeModuleInterface: Class<T>): Boolean = false

  override fun getNativeModules(): Collection<NativeModule> = emptyList()

  override fun <T : NativeModule> getNativeModule(nativeModuleInterface: Class<T>): T? = null

  override fun getNativeModule(nativeModuleName: String): NativeModule? = null

  override fun getRuntimeExecutor(): RuntimeExecutor? = null

  override fun getCatalystInstance(): CatalystInstance =
    throw UnsupportedOperationException("not used by NuntisBridgeTest")

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
