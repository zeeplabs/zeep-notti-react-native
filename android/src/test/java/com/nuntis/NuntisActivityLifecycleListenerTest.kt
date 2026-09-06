package com.nuntis

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.JavaOnlyMap
import com.facebook.react.bridge.WritableMap
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
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

  /**
   * Proves the "exactly once per tap" dedup property (spec SDK-18):
   * `onActivityResumed`'s `handle()` only reaches its emit call when
   * `parseClickIntentExtras` finds `google.message_id`, and it clears the
   * intent's extras (`intent.replaceExtras(Bundle())`) right after - so a
   * second `replaceExtras` call happening at all would mean the click path
   * fired again for the same tap. Counting `replaceExtras` calls on the real
   * Intent instance is a direct, non-shallow proxy for that: it only runs on
   * the branch guarded by a successful parse, immediately alongside the
   * emit call in `handle()`.
   */
  private class CountingIntent : Intent() {
    var replaceExtrasCallCount = 0
      private set

    override fun replaceExtras(extras: Bundle?): Intent {
      replaceExtrasCallCount++
      return super.replaceExtras(extras)
    }
  }

  @Test
  fun `onActivityResumed called twice with the same click intent fires the dedup clear exactly once`() {
    val intent = CountingIntent().apply {
      putExtra("google.message_id", "msg-1")
      putExtra("gcm.n.title", "Hello")
      putExtra("gcm.n.body", "World")
    }
    val activity = Robolectric.buildActivity(Activity::class.java, intent).create().get()
    val listener = NuntisActivityLifecycleListener()

    listener.onActivityResumed(activity)
    assertEquals(1, intent.replaceExtrasCallCount)

    // Same Activity/Intent instance, second resume for the same tap - the
    // extras were already cleared by the first call, so parseClickIntentExtras
    // now finds no google.message_id and handle() must return before ever
    // clearing extras (or emitting) again.
    listener.onActivityResumed(activity)
    assertEquals(1, intent.replaceExtrasCallCount)
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
