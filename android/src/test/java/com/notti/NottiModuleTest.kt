package com.notti

import android.app.Activity
import com.facebook.react.bridge.Callback
import com.facebook.react.bridge.CatalystInstance
import com.facebook.react.bridge.JavaScriptContextHolder
import com.facebook.react.bridge.JavaOnlyMap
import com.facebook.react.bridge.JavaScriptModule
import com.facebook.react.bridge.NativeModule
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.RuntimeExecutor
import com.facebook.react.bridge.UIManager
import com.facebook.react.bridge.WritableMap
import com.facebook.react.turbomodule.core.interfaces.CallInvokerHolder
import okhttp3.OkHttpClient
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

/**
 * NottiModule owns the real Android <13 permission auto-grant branch
 * (spec P2-AC4/SDK-11, `NottiModule.kt`'s `requestNativePermission`) -
 * `NottiCoreTest.kt` only exercises `NottiCore`'s injected fake
 * `permissionRequester`, never this concrete `Build.VERSION.SDK_INT` check.
 * Constructing a real `NottiModule` needs a `ReactApplicationContext`; RN
 * ships no test double for one, so [FakeReactApplicationContext] below
 * implements only the members `ReactContext` declares abstract - none of
 * them are reachable from the below-API-33 path this test exercises.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [32], shadows = [ShadowArguments::class])
class NottiModuleTest {

  @Test
  fun `requestPermission on Android below 13 resolves granted without ever touching the current activity`() {
    val context = FakeReactApplicationContext()
    val module = NottiModule(context)
    // requestPermission only reaches the SDK_INT auto-grant check once
    // NottiCore has an apiClient (set synchronously by initialize(), before
    // the async FCM-token fetch resolves) - mirrors NottiCoreTest.kt's own
    // "called before initialize" guard on the same method.
    module.initialize("app-1", "key", "https://notti.example.com", "")

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

  @Test
  fun `invalidate releases the process-wide hooks so a torn-down instance stops receiving clicks`() {
    NottiNotificationClickRelay.reset()
    val module = NottiModule(FakeReactApplicationContext())
    module.initialize("app-1", "key", "https://notti.example.com", "")
    assertNotNull(NottiModule.activeCore)

    // RN destroys and rebuilds modules on every dev reload; without cleanup
    // each dead instance stayed hooked up and re-emitted every later tap.
    module.invalidate()

    assertNull(NottiModule.activeCore)

    NottiNotificationClickRelay.emit(ParsedNotification("Hello", null, emptyMap()))

    // Buffered rather than pushed at the dead module: it detached itself, so
    // the relay had no emitter left to hand the click to.
    assertEquals("Hello", NottiNotificationClickRelay.takePending()?.title)
  }

  @Test
  fun `getInitialNotificationClick hands over a cold-start click buffered before the module existed`() {
    NottiNotificationClickRelay.reset()
    // The cold-start tap: detected by the Activity-lifecycle hook that
    // NottiInitProvider installs, long before this lazy TurboModule exists.
    NottiNotificationClickRelay.emit(
      ParsedNotification("Hello", "World", mapOf("plan" to "vip"))
    )

    val module = NottiModule(FakeReactApplicationContext())

    val first = RecordingPromise()
    module.getInitialNotificationClick(first)

    val payload = first.resolved as WritableMap
    assertEquals("Hello", payload.getString("title"))
    assertEquals("World", payload.getString("body"))
    assertEquals("vip", payload.getMap("data")?.getString("plan"))

    // Consumed: a second pull with no new cold start resolves null, so a
    // remounting JS component can't re-navigate off a stale tap.
    val second = RecordingPromise()
    module.getInitialNotificationClick(second)
    assertNull(second.resolved)
    assertTrue(second.didResolve)
  }

  /** Installs a coordinator running on the caller's thread; [onPost] sees each hop to main. */
  private fun installCoordinator(onPost: () -> Unit = {}): NottiInAppCoordinator {
    NottiInApp.resetForTests()
    val prefs = RuntimeEnvironment.getApplication().getSharedPreferences("notti_module_inapp", 0)
    val coordinator = NottiInAppCoordinator(
      store = NottiInAppEventStore(prefs),
      clientFactory = { config -> NottiApiClient(OkHttpClient(), config.baseUrl, config.appId, config.clientKey) },
      identity = { null },
      executor = object : InAppExecutor {
        override fun execute(task: () -> Unit) = Unit
        override fun schedule(delayMs: Long, task: () -> Unit) = Unit
      },
      postToMain = { task -> onPost(); task() }
    )
    return NottiInApp.install(coordinator)
  }

  @Test
  fun `initialize hands the normalized config to In-App before the core is created`() {
    NottiModule.resetProcessWideStateForTest()
    val coreAtPost = mutableListOf<NottiCore?>()
    val coordinator = installCoordinator { coreAtPost.add(NottiModule.activeCore) }
    try {
      val module = NottiModule(FakeReactApplicationContext())
      module.initialize("app-1", "key", "https://notti.example.com/", "")

      assertEquals(InAppConfig("app-1", "key", "https://notti.example.com"), coordinator.session.config)
      assertEquals(listOf<NottiCore?>(null), coreAtPost)
      assertNotNull(NottiModule.activeCore)
    } finally {
      NottiInApp.resetForTests()
    }
  }

  @Test
  fun `the module's core opens the In-App session when it opens a foreground session`() {
    NottiModule.resetProcessWideStateForTest()
    val coordinator = installCoordinator()
    try {
      val module = NottiModule(FakeReactApplicationContext())
      module.initialize("app-1", "key", "https://notti.example.com", "")

      requireNotNull(NottiModule.activeCore).onAppForegrounded()

      assertTrue(coordinator.session.isOpen)
    } finally {
      NottiModule.resetProcessWideStateForTest()
      NottiInApp.resetForTests()
    }
  }

  @Test
  fun `initialize installs the push permission port and invalidate removes only its own`() {
    NottiModule.resetProcessWideStateForTest()
    val coordinator = installCoordinator()
    try {
      val first = NottiModule(FakeReactApplicationContext())
      first.initialize("app-1", "key", "https://notti.example.com", "")
      val firstPort = coordinator.pushPermissionPort
      assertNotNull(firstPort)

      // An RN reload builds the next module before the old one is invalidated.
      val second = NottiModule(FakeReactApplicationContext())
      second.initialize("app-1", "key", "https://notti.example.com", "")
      val secondPort = coordinator.pushPermissionPort
      assertNotNull(secondPort)

      first.invalidate()
      assertSame(secondPort, coordinator.pushPermissionPort)

      second.invalidate()
      assertNull(coordinator.pushPermissionPort)
    } finally {
      NottiModule.resetProcessWideStateForTest()
      NottiInApp.resetForTests()
    }
  }

  @Test
  @Config(sdk = [33], shadows = [ShadowArguments::class])
  fun `the push permission action without an activity shows no prompt and leaves the asked flag unset`() {
    NottiModule.resetProcessWideStateForTest()
    val coordinator = installCoordinator()
    val prefs = RuntimeEnvironment.getApplication().getSharedPreferences(NottiModule.PREFS_NAME, 0)
    prefs.edit().clear().commit()
    try {
      val module = NottiModule(FakeReactApplicationContext(failOnActivity = false))
      module.initialize("app-1", "key", "https://notti.example.com", "")

      coordinator.pushPermissionPort?.run()

      assertFalse(NottiDeviceStore(prefs).getPermissionRequested())
    } finally {
      NottiModule.resetProcessWideStateForTest()
      NottiInApp.resetForTests()
    }
  }

  @Test
  fun `initialize with an invalid config leaves In-App without one`() {
    val coordinator = installCoordinator()
    try {
      val module = NottiModule(FakeReactApplicationContext())
      module.initialize("app-1", "", "https://notti.example.com", "")
      module.initialize("app-1", "key", "not a url", "")

      assertNull(coordinator.session.config)
    } finally {
      NottiInApp.resetForTests()
    }
  }

  @Test
  fun `trackEvent forwards the name to In-App, so a call right after initialize is kept`() {
    val coordinator = installCoordinator()
    try {
      val module = NottiModule(FakeReactApplicationContext())
      module.trackEvent("before-initialize")
      module.initialize("app-1", "key", "https://notti.example.com", "")
      module.trackEvent("promo")
      module.trackEvent(null)

      assertEquals(listOf("promo"), coordinator.session.pending)
    } finally {
      NottiInApp.resetForTests()
    }
  }

  @Test
  fun `invalidate leaves the In-App coordinator installed`() {
    val coordinator = installCoordinator()
    try {
      NottiModule(FakeReactApplicationContext()).invalidate()
      assertSame(coordinator, NottiInApp.get())
    } finally {
      NottiInApp.resetForTests()
    }
  }

  @Test
  fun `an In-App click reaches the live module with exactly messageId, buttonId and action`() {
    val module = NottiModule(FakeReactApplicationContext())
    val emitted = mutableListOf<WritableMap>()
    module.inAppClickEmitter = { emitted.add(it) }
    // Reserved characters and escapes must arrive byte for byte.
    val value = "https://shop.test/p?a=1&b=%20x#frag"

    assertTrue(NottiModule.emitInAppClick(InAppClick("msg-1", "b2", InAppAction("url", value))))

    val payload = emitted.single() as JavaOnlyMap
    assertEquals(setOf("messageId", "buttonId", "action"), payload.toHashMap().keys)
    assertEquals("msg-1", payload.getString("messageId"))
    assertEquals("b2", payload.getString("buttonId"))
    val action = payload.getMap("action") as JavaOnlyMap
    assertEquals(setOf("type", "value"), action.toHashMap().keys)
    assertEquals("url", action.getString("type"))
    assertEquals(value, action.getString("value"))
  }

  @Test
  fun `an In-App click without a usable action carries action null rather than omitting it`() {
    val module = NottiModule(FakeReactApplicationContext())
    val emitted = mutableListOf<WritableMap>()
    module.inAppClickEmitter = { emitted.add(it) }

    // The parser turns an unknown action type into no action (T2).
    val parsed = parseEligibleResponse(
      """{"messages":[{"id":"m1","format":"center","title":"t","body":"b",""" +
        """"buttons":[{"id":"b1","label":"Go","action":{"type":"sms","value":"x"}}]}]}"""
    )!!.single()
    assertTrue(NottiModule.emitInAppClick(InAppClick("m1", "b1", parsed.buttons.single().action)))

    val payload = emitted.single()
    assertTrue(payload.hasKey("action"))
    assertTrue(payload.isNull("action"))
  }

  @Test
  fun `an In-App click with no live module is not delivered and never replayed to a later module`() {
    val old = NottiModule(FakeReactApplicationContext())
    old.inAppClickEmitter = { throw AssertionError("torn-down module must not emit") }
    old.invalidate()

    assertFalse(NottiModule.emitInAppClick(InAppClick("m1", "b1", null)))

    val module = NottiModule(FakeReactApplicationContext())
    val emitted = mutableListOf<WritableMap>()
    module.inAppClickEmitter = { emitted.add(it) }
    assertTrue(emitted.isEmpty())

    NottiModule.emitInAppClick(InAppClick("m2", "b1", null))
    assertEquals(listOf("m2"), emitted.map { it.getString("messageId") })
  }

  @Test
  fun `constructing the module does not replay the buffered cold-start click as an event`() {
    NottiNotificationClickRelay.reset()
    NottiNotificationClickRelay.emit(ParsedNotification("Hello", null, emptyMap()))

    // Constructing the module attaches its emitter. If that replayed the
    // buffered click, FakeReactApplicationContext's event-emitter plumbing
    // would be hit here - and, worse in production, the event would fire
    // before any JS `addEventListener` had run and be lost.
    val module = NottiModule(FakeReactApplicationContext())

    // Still there, i.e. nothing consumed or emitted it behind JS' back.
    val promise = RecordingPromise()
    module.getInitialNotificationClick(promise)
    assertEquals("Hello", (promise.resolved as WritableMap).getString("title"))
  }

  @Test
  fun `getInitialNotificationClick resolves null when the app was not launched from a notification`() {
    NottiNotificationClickRelay.reset()
    val module = NottiModule(FakeReactApplicationContext())

    val promise = RecordingPromise()
    module.getInitialNotificationClick(promise)

    assertTrue(promise.didResolve)
    assertNull(promise.resolved)
  }

}

/** Captures what a Spec method resolved, since RN ships no test Promise. */
private class RecordingPromise : Promise {
  var didResolve = false
    private set
  var resolved: Any? = null
    private set

  override fun resolve(value: Any?) {
    didResolve = true
    resolved = value
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
}

/**
 * Minimal, test-only stand-in for the abstract `ReactApplicationContext` -
 * only implements what `ReactContext` requires to compile; every member is
 * either unused by the SDK<33 auto-grant path or deliberately throws to
 * prove that path never reaches it (see `getCurrentActivity` below).
 */
private class FakeReactApplicationContext(private val failOnActivity: Boolean = true) :
  ReactApplicationContext(RuntimeEnvironment.getApplication()) {

  override fun getCurrentActivity(): Activity? {
    if (!failOnActivity) return null
    throw AssertionError("requestNativePermission must resolve before reading currentActivity below API 33")
  }

  override fun <T : JavaScriptModule> getJSModule(jsModuleInterface: Class<T>): T =
    throw UnsupportedOperationException("not used by the SDK<33 auto-grant path")

  override fun <T : NativeModule> hasNativeModule(nativeModuleInterface: Class<T>): Boolean = false

  override fun getNativeModules(): Collection<NativeModule> = emptyList()

  override fun <T : NativeModule> getNativeModule(nativeModuleInterface: Class<T>): T? = null

  override fun getNativeModule(nativeModuleName: String): NativeModule? = null

  override fun getRuntimeExecutor(): RuntimeExecutor? = null

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
