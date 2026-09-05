package com.nuntis

import android.content.Intent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * Intent/Bundle are backed by android.os.Bundle - unmockable on the plain
 * JVM without Robolectric, same reason as NuntisFirebaseMessagingServiceTest.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class NuntisActivityLifecycleListenerTest {

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
