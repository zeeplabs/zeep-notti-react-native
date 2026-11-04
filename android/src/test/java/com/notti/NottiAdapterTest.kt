package com.notti

import android.app.Application
import com.facebook.react.bridge.JavaOnlyArray
import com.facebook.react.bridge.JavaOnlyMap
import com.facebook.react.bridge.ReadableMap
import com.zeeplabs.notti.NottiInAppAction
import com.zeeplabs.notti.NottiOptions
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
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
 * [NottiAdapter] (android-native-sdk T3/T4): each Codegen call reaches the
 * native SDK once with 0.8.0's null handling (ANSDK-02..04), SDK events reach
 * the Codegen emitters in the 0.8.0 payload shapes (ANSDK-05), listeners go
 * away on stop (ANSDK-06) and the cold-start tap is pulled once (ANSDK-07).
 * The SDK's own behavior is tested in `zeep-notti-android-sdk` (L-001).
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], shadows = [ShadowArguments::class])
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

  @Test
  fun `start adds the four SDK listeners once and stop removes them all`() {
    adapter.start()
    adapter.start()
    assertEquals(4, native.liveSubscriptions)

    adapter.stop()
    adapter.stop()
    assertEquals(0, native.liveSubscriptions)
  }

  @Test
  fun `a received push is emitted with title, body and data`() {
    val sink = startedAdapter()

    native.fireReceived(NativeNotification("Fixture title", "Fixture body", mapOf("notification_id" to "fixture-n")))

    val payload = sink.received.single()
    assertEquals("Fixture title", payload.getString("title"))
    assertEquals("Fixture body", payload.getString("body"))
    assertEquals(mapOf<String, Any?>("notification_id" to "fixture-n"), payload.getMap("data")!!.toHashMap())
  }

  @Test
  fun `a clicked push without title or body keeps both keys with null and an empty data map`() {
    val sink = startedAdapter()

    native.fireClicked(NativeNotification(null, null, emptyMap()))

    val payload = sink.clicked.single()
    assertKeyIsNull(payload, "title")
    assertKeyIsNull(payload, "body")
    assertTrue(payload.getMap("data")!!.toHashMap().isEmpty())
    assertTrue(sink.received.isEmpty())
  }

  @Test
  fun `a device id change is emitted as the plain id`() {
    val sink = startedAdapter()

    native.fireDeviceIdChanged("fixture-device")

    assertEquals(listOf("fixture-device"), sink.deviceIds)
  }

  @Test
  fun `In-App url and deeplink clicks carry the 0_8_0 action type strings and the untouched value`() {
    val sink = startedAdapter()

    native.fireInAppClick(NativeInAppClick("fixture-msg", "b1", NottiInAppAction.Type.URL, "https://example.invalid/a?b=1"))
    native.fireInAppClick(NativeInAppClick("fixture-msg", "image", NottiInAppAction.Type.DEEPLINK, "fixture://path"))

    val (url, deeplink) = sink.inAppClicks
    assertEquals("fixture-msg", url.getString("messageId"))
    assertEquals("b1", url.getString("buttonId"))
    assertEquals("url", url.getMap("action")!!.getString("type"))
    assertEquals("https://example.invalid/a?b=1", url.getMap("action")!!.getString("value"))
    assertEquals("image", deeplink.getString("buttonId"))
    assertEquals("deeplink", deeplink.getMap("action")!!.getString("type"))
    assertEquals("fixture://path", deeplink.getMap("action")!!.getString("value"))
  }

  @Test
  fun `an In-App click without an action, as for push_permission, carries action null rather than omitting it`() {
    val sink = startedAdapter()

    native.fireInAppClick(NativeInAppClick("fixture-msg", "b2", null, null))

    val payload = sink.inAppClicks.single()
    assertEquals("fixture-msg", payload.getString("messageId"))
    assertEquals("b2", payload.getString("buttonId"))
    assertKeyIsNull(payload, "action")
  }

  @Test
  fun `every native action type has an explicit 0_8_0 string, so a new SDK value fails here first`() {
    for (type in NottiInAppAction.Type.entries) {
      assertNotNull("no JS action type for $type", type.toJsActionType())
    }
  }

  @Test
  fun `nothing is emitted after stop`() {
    val sink = startedAdapter()
    adapter.stop()

    native.fireReceived(NativeNotification("t", "b", emptyMap()))
    native.fireClicked(NativeNotification("t", "b", emptyMap()))
    native.fireDeviceIdChanged("fixture-device")
    native.fireInAppClick(NativeInAppClick("fixture-msg", "b1", null, null))

    assertTrue(sink.received.isEmpty() && sink.clicked.isEmpty() && sink.deviceIds.isEmpty() && sink.inAppClicks.isEmpty())
  }

  @Test
  fun `after a reload the new adapter receives each event once and the old one none`() {
    val oldSink = startedAdapter()
    adapter.stop()
    val newSink = CapturingEventSink()
    NottiAdapter(app, native, newSink).start()

    native.fireReceived(NativeNotification("t", "b", emptyMap()))
    native.fireClicked(NativeNotification("t", "b", emptyMap()))
    native.fireDeviceIdChanged("fixture-device")
    native.fireInAppClick(NativeInAppClick("fixture-msg", "b1", null, null))

    assertEquals(listOf(1, 1, 1, 1), listOf(newSink.received.size, newSink.clicked.size, newSink.deviceIds.size, newSink.inAppClicks.size))
    assertEquals(listOf(0, 0, 0, 0), listOf(oldSink.received.size, oldSink.clicked.size, oldSink.deviceIds.size, oldSink.inAppClicks.size))
    assertEquals(4, native.liveSubscriptions)
  }

  @Test
  fun `getInitialNotificationClick resolves the cold-start tap once, then null`() {
    native.initialClick = NativeNotification(null, "Fixture body", mapOf("delivery_id" to "fixture-d"))
    val first = SettledPromise()
    val second = SettledPromise()

    adapter.getInitialNotificationClick(first)
    adapter.getInitialNotificationClick(second)

    val payload = first.resolved.single() as ReadableMap
    assertKeyIsNull(payload, "title")
    assertEquals("Fixture body", payload.getString("body"))
    assertEquals(mapOf<String, Any?>("delivery_id" to "fixture-d"), payload.getMap("data")!!.toHashMap())
    assertEquals(listOf<Any?>(null), second.resolved)
    assertEquals(0, first.rejections + second.rejections)
  }

  @Test
  fun `getInitialNotificationClick with no tap resolves null`() {
    val promise = SettledPromise()

    adapter.getInitialNotificationClick(promise)

    assertEquals(listOf<Any?>(null), promise.resolved)
  }

  @Test
  fun `starting does not pull the cold-start tap, so getInitialNotificationClick still gets it`() {
    native.initialClick = NativeNotification("t", "b", emptyMap())
    startedAdapter()
    val promise = SettledPromise()

    adapter.getInitialNotificationClick(promise)

    assertFalse(promise.resolved.single() == null)
  }

  private fun startedAdapter(): CapturingEventSink {
    val sink = CapturingEventSink()
    adapter = NottiAdapter(app, native, sink)
    adapter.start()
    return sink
  }

  private fun assertKeyIsNull(map: ReadableMap, key: String) {
    assertTrue("missing key $key", map.hasKey(key))
    assertTrue("$key is not null", map.isNull(key))
  }

  private companion object {
    const val APP_ID = "fixture-app"
    const val CLIENT_KEY = "fixture-key"
    const val BASE_URL = "https://notti.example.invalid"
  }
}
