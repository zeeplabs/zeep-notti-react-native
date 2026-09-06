package com.nuntis

import android.os.Bundle
import com.google.firebase.messaging.RemoteMessage
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * [RemoteMessage] is backed by [android.os.Bundle], which throws "not
 * mocked" on the plain JVM without Robolectric - this is the one test class
 * in the module that needs it, scoped narrowly per the class-level
 * [RunWith] rather than applied repo-wide.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class NuntisFirebaseMessagingServiceTest {

  @Test
  fun `parseRemoteMessage extracts title, body, and custom data`() {
    val bundle = Bundle().apply {
      putString("gcm.n.e", "1")
      putString("gcm.n.title", "Hello")
      putString("gcm.n.body", "World")
      putString("plan", "vip")
    }

    val parsed = parseRemoteMessage(RemoteMessage(bundle))

    assertEquals("Hello", parsed.title)
    assertEquals("World", parsed.body)
    assertEquals(mapOf("plan" to "vip"), parsed.data)
  }

  @Test
  fun `parseRemoteMessage handles a data-only message with no notification block`() {
    val bundle = Bundle().apply {
      putString("plan", "vip")
      putString("cohort", "beta")
    }

    val parsed = parseRemoteMessage(RemoteMessage(bundle))

    assertNull(parsed.title)
    assertNull(parsed.body)
    assertEquals(mapOf("plan" to "vip", "cohort" to "beta"), parsed.data)
  }

  @Test
  fun `parseRemoteMessage handles an empty message with no notification and no data`() {
    val parsed = parseRemoteMessage(RemoteMessage(Bundle()))

    assertNull(parsed.title)
    assertNull(parsed.body)
    assertEquals(emptyMap<String, String>(), parsed.data)
  }
}
