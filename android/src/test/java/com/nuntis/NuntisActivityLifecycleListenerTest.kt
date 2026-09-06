package com.nuntis

import android.app.Activity
import android.content.Intent
import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.JavaOnlyMap
import com.facebook.react.bridge.WritableMap
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.annotation.Implementation
import org.robolectric.annotation.Implements

/**
 * Intent/Bundle are backed by android.os.Bundle - unmockable on the plain
 * JVM without Robolectric, same reason as NuntisFirebaseMessagingServiceTest.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], shadows = [ShadowArguments::class])
class NuntisActivityLifecycleListenerTest {

  @Before
  @After
  fun resetProcessWideState() {
    NuntisNotificationClickRelay.reset()
    NuntisActivityLifecycleListener.resetRegistrationForTest()
  }

  @Test
  fun `a cold-start click detected before any module exists is delivered once a module attaches`() {
    // Process start: the ContentProvider runs before any Activity, and long
    // before the lazy TurboModule is constructed (spec P3-AC7 - a tap from a
    // killed app). Nothing is attached to emit on yet.
    Robolectric.buildContentProvider(NuntisInitProvider::class.java).create()

    val intent = Intent().apply {
      putExtra("google.message_id", "msg-1")
      putExtra("gcm.n.title", "Hello")
      putExtra("plan", "vip")
    }
    Robolectric.buildActivity(Activity::class.java, intent).create().resume()

    val delivered = mutableListOf<ParsedNotification>()
    NuntisNotificationClickRelay.attach { delivered.add(it) }

    assertEquals(1, delivered.size)
    assertEquals("Hello", delivered.single().title)
    assertEquals(mapOf("plan" to "vip"), delivered.single().data)
  }

  @Test
  fun `registerOnce installs a single listener no matter how many times it runs`() {
    val application = RuntimeEnvironment.getApplication()
    repeat(3) { NuntisActivityLifecycleListener.registerOnce(application) }

    val delivered = mutableListOf<ParsedNotification>()
    NuntisNotificationClickRelay.attach { delivered.add(it) }

    val intent = Intent().apply {
      putExtra("google.message_id", "msg-1")
      putExtra("gcm.n.title", "Hello")
    }
    Robolectric.buildActivity(Activity::class.java, intent).create().resume()

    // One tap, one event - repeated registration (the RN-reload shape, where
    // the module used to add a fresh listener per instance) must not multiply
    // emissions.
    assertEquals(1, delivered.size)
    assertTrue(delivered.single().title == "Hello")
  }

  @Test
  fun `the same click intent handled twice emits once and leaves the host app's extras intact`() {
    val delivered = mutableListOf<ParsedNotification>()
    NuntisNotificationClickRelay.attach { delivered.add(it) }

    val intent = Intent().apply {
      putExtra("google.message_id", "msg-1")
      putExtra("gcm.n.title", "Hello")
      putExtra("deep_link", "app://orders/42")
    }
    val activity = Robolectric.buildActivity(Activity::class.java, intent).create().get()
    val listener = NuntisActivityLifecycleListener()

    listener.onActivityResumed(activity)
    listener.onActivityResumed(activity)

    // Exactly once per tap (spec SDK-18)...
    assertEquals(1, delivered.size)
    // ...without destroying the launching Intent the host app reads too: the
    // SDK used to wipe every extra to dedup, breaking the host's own
    // deep-link/extras handling.
    assertEquals("app://orders/42", activity.intent.getStringExtra("deep_link"))
    assertEquals("msg-1", activity.intent.getStringExtra("google.message_id"))
  }

  @Test
  fun `a second tap delivering a new intent to the same activity emits again`() {
    val delivered = mutableListOf<ParsedNotification>()
    NuntisNotificationClickRelay.attach { delivered.add(it) }

    val activity = Robolectric.buildActivity(
      Activity::class.java,
      Intent().apply {
        putExtra("google.message_id", "msg-1")
        putExtra("gcm.n.title", "First")
      }
    ).create().get()
    val listener = NuntisActivityLifecycleListener()
    listener.onActivityResumed(activity)

    // A real second tap arrives as a new Intent instance (onNewIntent /
    // setIntent) - dedup must not swallow it.
    activity.intent = Intent().apply {
      putExtra("google.message_id", "msg-2")
      putExtra("gcm.n.title", "Second")
    }
    listener.onActivityResumed(activity)

    assertEquals(listOf("First", "Second"), delivered.map { it.title })
  }

  @Test
  fun `parseClickIntentExtras extracts the payload when google message_id is present`() {
    val intent = Intent().apply {
      putExtra("google.message_id", "msg-1")
      putExtra("gcm.n.title", "Hello")
      putExtra("gcm.n.body", "World")
      putExtra("plan", "vip")
    }

    val parsed = parseClickIntentExtras(intent)

    assertEquals(ParsedNotification(title = "Hello", body = "World", data = mapOf("plan" to "vip")), parsed)
  }

  @Test
  fun `parseClickIntentExtras returns null for a null intent or one with no extras at all`() {
    assertNull(parseClickIntentExtras(null))
    assertNull(parseClickIntentExtras(Intent()))
  }

  @Test
  fun `parseClickIntentExtras returns null on an unrelated launch even with other extras present`() {
    val intent = Intent().apply {
      putExtra("some_unrelated_key", "value")
    }

    assertNull(parseClickIntentExtras(intent))
  }

  @Test
  fun `parseClickIntentExtras skips a malformed null-valued extra without crashing`() {
    val intent = Intent().apply {
      putExtra("google.message_id", "msg-1")
      putExtra("badKey", null as String?)
      putExtra("plan", "vip")
    }

    val parsed = parseClickIntentExtras(intent)

    assertEquals(mapOf("plan" to "vip"), parsed?.data)
  }
}

/**
 * `Arguments.createMap()` normally returns a JNI-backed `WritableNativeMap`,
 * which needs a real native library that isn't available on the plain JVM
 * Robolectric runs on - it would crash `handle()`'s `toWritableMap()` call
 * before ever reaching the dedup logic under test. This shadow swaps it for
 * `JavaOnlyMap`, RN's own pure-Java `WritableMap` implementation meant
 * exactly for this (unit tests with no native bridge), so the real
 * `NuntisActivityLifecycleListener.handle()` can run end to end.
 */
@Implements(Arguments::class)
class ShadowArguments {
  companion object {
    @Implementation
    @JvmStatic
    fun createMap(): WritableMap = JavaOnlyMap()
  }
}
