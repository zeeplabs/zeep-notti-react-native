package com.notti

import com.facebook.react.bridge.JavaOnlyArray
import com.facebook.react.bridge.JavaOnlyMap
import com.zeeplabs.notti.NottiInAppAction
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

/**
 * Module wiring only (android-native-sdk T6): the package builds the module,
 * every Spec method reaches [NottiAdapter], the four listeners live exactly as
 * long as the module, and events reach the module's sink. The mapping itself
 * is covered by [NottiAdapterTest]; SDK behavior by the native repo (L-001).
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], shadows = [ShadowArguments::class])
class NottiModuleTest {

  private val native = FakeNottiNativeApi()

  private fun module() = NottiModule(FakeReactApplicationContext(), native)

  @Test
  fun `the package builds the module for its own name only, as a lazy Turbo Module`() {
    val pkg = NottiPackage()
    val module = pkg.getModule(NottiModule.NAME, FakeReactApplicationContext())

    assertTrue(module is NottiModule)
    assertNull(pkg.getModule("Other", FakeReactApplicationContext()))
    val info = pkg.getReactModuleInfoProvider().getReactModuleInfos().getValue(NottiModule.NAME)
    assertTrue(info.isTurboModule)
    assertEquals(false, info.needsEagerInit)

    // Built on the real SDK with no runtime: adding and removing the
    // listeners must not throw.
    (module as NottiModule).invalidate()
  }

  @Test
  fun `construction adds the four SDK listeners and invalidate removes them all, once`() {
    val module = module()
    assertEquals(4, native.liveSubscriptions)

    module.invalidate()
    assertEquals(0, native.liveSubscriptions)

    module.invalidate()
    assertEquals(0, native.liveSubscriptions)
  }

  @Test
  fun `each SDK event reaches the module's sink`() {
    val module = module()
    val sink = CapturingEventSink()
    module.events = sink

    native.fireReceived(NativeNotification("fixture title", "fixture body", mapOf("k" to "v")))
    native.fireClicked(NativeNotification(null, null, emptyMap()))
    native.fireDeviceIdChanged("device-fixture")
    native.fireInAppClick(NativeInAppClick("message-fixture", "image", NottiInAppAction.Type.URL, "https://example.invalid"))

    assertEquals("fixture title", sink.received.single().getString("title"))
    assertTrue(sink.clicked.single().hasKey("title"))
    assertEquals(listOf("device-fixture"), sink.deviceIds)
    assertEquals("url", sink.inAppClicks.single().getMap("action")?.getString("type"))
  }

  @Test
  fun `nothing is emitted after invalidate, and a new module gets each event once`() {
    val old = module()
    val oldSink = CapturingEventSink().also { old.events = it }
    old.invalidate()

    val current = module()
    val currentSink = CapturingEventSink().also { current.events = it }
    native.fireDeviceIdChanged("device-fixture")

    assertTrue(oldSink.deviceIds.isEmpty())
    assertEquals(listOf("device-fixture"), currentSink.deviceIds)
    assertEquals(4, native.liveSubscriptions)
  }

  @Test
  fun `every Spec method is forwarded to the SDK through the adapter`() {
    val module = module()
    native.deviceIdValue = "device-fixture"
    native.permissionResult = true
    native.initialClick = NativeNotification("fixture", null, emptyMap())
    native.calls.clear()

    module.initialize("app-fixture", "key-fixture", "https://example.invalid", "0.0.0-fixture")
    module.login("user-fixture")
    module.logout()
    module.addTags(JavaOnlyMap.of("plan", "fixture"))
    module.removeTags(JavaOnlyArray.of("plan"))
    module.setSubscription(true)
    module.setLocationSharingEnabled(false)
    module.setEmail("user@example.invalid")
    module.clearEmail()
    module.setPhone("+5500000000000")
    module.clearPhone()
    val deviceId = module.getDeviceId()
    module.trackEvent("fixture_event")
    val permission = SettledPromise()
    module.requestPermission(permission)
    val initialClick = SettledPromise()
    module.getInitialNotificationClick(initialClick)

    assertEquals(
      listOf(
        "initializeForWrapper", "login", "logout", "addTags", "removeTags", "setSubscription",
        "setLocationSharingEnabled", "setEmail", "clearEmail", "setPhone", "clearPhone", "deviceId",
        "trackEvent", "requestPermission", "takeInitialClick"
      ),
      native.calls.map { it.name }
    )
    assertEquals(NottiAdapter.SDK_NAME, native.callsNamed("initializeForWrapper").single().args[3])
    assertSame(RuntimeEnvironment.getApplication(), native.initializeContext)
    assertEquals("device-fixture", deviceId)
    assertEquals(listOf<Any?>(true), permission.resolved)
    assertEquals(1, initialClick.resolved.size)
  }
}
