package com.notti

import android.app.Application
import com.facebook.react.bridge.JavaOnlyArray
import com.facebook.react.bridge.JavaOnlyMap
import com.zeeplabs.notti.NottiOptions
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

/**
 * Method forwarding of [NottiAdapter] (android-native-sdk T3, ANSDK-02..04):
 * each Codegen call reaches the native SDK once, with 0.8.0's null handling.
 * The SDK's own behavior is tested in `zeep-notti-android-sdk` (L-001).
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class NottiAdapterTest {

  private lateinit var app: Application
  private lateinit var native: FakeNottiNativeApi
  private lateinit var adapter: NottiAdapter

  @Before
  fun setUp() {
    app = RuntimeEnvironment.getApplication()
    native = FakeNottiNativeApi()
    adapter = NottiAdapter(app, native, CapturingEventSink())
  }

  @Test
  fun `initialize uses the wrapper entry with the react-native identity and links never opened`() {
    adapter.initialize(APP_ID, CLIENT_KEY, BASE_URL, "0.9.0")

    assertEquals(
      listOf(
        NativeCall(
          "initializeForWrapper",
          listOf(APP_ID, CLIENT_KEY, NottiOptions(BASE_URL, opensInAppUrls = false), "react-native", "0.9.0")
        )
      ),
      native.calls
    )
    assertSame(app, native.initializeContext)
  }

  @Test
  fun `initialize hands the SDK the application context, not the caller's`() {
    val wrapped = android.content.ContextWrapper(app)
    NottiAdapter(wrapped, native, CapturingEventSink()).initialize(APP_ID, CLIENT_KEY, BASE_URL, "0.9.0")

    assertSame(app, native.initializeContext)
  }

  @Test
  fun `initialize turns null ids into empty strings and leaves validation to the SDK`() {
    adapter.initialize(null, null, null, "")

    assertEquals(
      listOf(NativeCall("initializeForWrapper", listOf("", "", NottiOptions(null, opensInAppUrls = false), "react-native", ""))),
      native.calls
    )
  }

  @Test
  fun `login forwards the id once`() {
    adapter.login("fixture-user")

    assertEquals(listOf(NativeCall("login", listOf("fixture-user"))), native.calls)
  }

  @Test
  fun `login with null makes no call`() {
    adapter.login(null)

    assertTrue(native.calls.isEmpty())
  }

  @Test
  fun `logout forwards`() {
    adapter.logout()

    assertEquals(listOf(NativeCall("logout")), native.calls)
  }

  @Test
  fun `addTags forwards string entries and drops non-string values`() {
    val tags = JavaOnlyMap.of("plan", "fixture", "count", 2.0, "flag", true, "empty", "")

    adapter.addTags(tags)

    assertEquals(listOf(NativeCall("addTags", listOf(mapOf("plan" to "fixture", "empty" to "")))), native.calls)
  }

  @Test
  fun `addTags with an empty or null map still reaches the SDK with an empty map`() {
    adapter.addTags(JavaOnlyMap())
    adapter.addTags(null)

    assertEquals(
      listOf(NativeCall("addTags", listOf(emptyMap<String, String>())), NativeCall("addTags", listOf(emptyMap<String, String>()))),
      native.calls
    )
  }

  @Test
  fun `removeTags forwards the keys in order`() {
    adapter.removeTags(JavaOnlyArray.of("plan", "region"))

    assertEquals(listOf(NativeCall("removeTags", listOf(listOf("plan", "region")))), native.calls)
  }

  @Test
  fun `removeTags with an empty or null list still reaches the SDK with an empty list`() {
    adapter.removeTags(JavaOnlyArray())
    adapter.removeTags(null)

    assertEquals(
      listOf(NativeCall("removeTags", listOf(emptyList<String>())), NativeCall("removeTags", listOf(emptyList<String>()))),
      native.calls
    )
  }

  @Test
  fun `setSubscription forwards both values`() {
    adapter.setSubscription(false)
    adapter.setSubscription(true)

    assertEquals(
      listOf(NativeCall("setSubscription", listOf(false)), NativeCall("setSubscription", listOf(true))),
      native.calls
    )
  }

  @Test
  fun `setLocationSharingEnabled forwards both values`() {
    adapter.setLocationSharingEnabled(true)
    adapter.setLocationSharingEnabled(false)

    assertEquals(
      listOf(NativeCall("setLocationSharingEnabled", listOf(true)), NativeCall("setLocationSharingEnabled", listOf(false))),
      native.calls
    )
  }

  @Test
  fun `setEmail and clearEmail forward, and a null email makes no call`() {
    adapter.setEmail("user@example.invalid")
    adapter.setEmail(null)
    adapter.clearEmail()

    assertEquals(listOf(NativeCall("setEmail", listOf("user@example.invalid")), NativeCall("clearEmail")), native.calls)
  }

  @Test
  fun `setPhone and clearPhone forward, and a null phone makes no call`() {
    adapter.setPhone("+0000000000")
    adapter.setPhone(null)
    adapter.clearPhone()

    assertEquals(listOf(NativeCall("setPhone", listOf("+0000000000")), NativeCall("clearPhone")), native.calls)
  }

  @Test
  fun `getDeviceId returns the SDK value, null included`() {
    assertNull(adapter.getDeviceId())

    native.deviceIdValue = "fixture-device"

    assertEquals("fixture-device", adapter.getDeviceId())
  }

  @Test
  fun `trackEvent forwards the name untouched, and null makes no call`() {
    adapter.trackEvent(" Checkout ")
    adapter.trackEvent(null)

    assertEquals(listOf(NativeCall("trackEvent", listOf(" Checkout "))), native.calls)
  }

  @Test
  fun `requestPermission resolves the SDK answer and never rejects`() {
    val granted = SettledPromise()
    val denied = SettledPromise()

    native.permissionResult = true
    adapter.requestPermission(granted)
    native.permissionResult = false
    adapter.requestPermission(denied)

    assertEquals(listOf<Any?>(true), granted.resolved)
    assertEquals(listOf<Any?>(false), denied.resolved)
    assertEquals(0, granted.rejections + denied.rejections)
  }

  @Test
  fun `requestPermission settles only when the SDK answers`() {
    val promise = SettledPromise()
    native.permissionResult = null

    adapter.requestPermission(promise)
    assertTrue(promise.resolved.isEmpty())

    native.pendingPermission!!(true)
    assertEquals(listOf<Any?>(true), promise.resolved)
  }

  @Test
  fun `requestPermission with a null promise still asks the SDK and does not throw`() {
    native.permissionResult = true

    adapter.requestPermission(null)

    assertEquals(listOf(NativeCall("requestPermission")), native.calls)
  }

  private companion object {
    const val APP_ID = "fixture-app"
    const val CLIENT_KEY = "fixture-key"
    const val BASE_URL = "https://notti.example.invalid"
  }
}
