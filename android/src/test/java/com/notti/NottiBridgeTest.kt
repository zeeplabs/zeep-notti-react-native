@file:Suppress("DEPRECATION")

package com.notti

import android.os.Bundle
import com.google.firebase.messaging.RemoteMessage
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * The deprecated `com.notti.NottiBridge` shim (android-native-sdk T5,
 * ANSDK-11): the 0.8.0 calls still compile and reach the native bridge
 * unchanged. What the native bridge does with them is tested in
 * `zeep-notti-android-sdk` (L-001).
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class NottiBridgeTest {

  private class RecordingTarget : NottiBridge.Target {
    val messages = mutableListOf<RemoteMessage>()
    val tokens = mutableListOf<String>()

    override fun onMessageReceived(remoteMessage: RemoteMessage) {
      messages.add(remoteMessage)
    }

    override fun onNewToken(token: String) {
      tokens.add(token)
    }
  }

  @After
  fun restoreTarget() {
    NottiBridge.target = NottiBridge.NativeTarget
  }

  @Test
  fun `onMessageReceived forwards the same message to the native bridge`() {
    val target = RecordingTarget()
    NottiBridge.target = target
    val message = fixtureMessage()

    NottiBridge.onMessageReceived(message)

    assertSame(message, target.messages.single())
    assertTrue(target.tokens.isEmpty())
  }

  @Test
  fun `onNewToken forwards the same token to the native bridge`() {
    val target = RecordingTarget()
    NottiBridge.target = target

    NottiBridge.onNewToken("fixture-token")

    assertEquals(listOf("fixture-token"), target.tokens)
    assertTrue(target.messages.isEmpty())
  }

  @Test
  fun `production target is the native bridge`() {
    assertSame(NottiBridge.NativeTarget, NottiBridge.target)
  }

  @Test
  fun `with the native bridge and no native runtime both calls are safe no-ops`() {
    NottiBridge.onMessageReceived(fixtureMessage())
    NottiBridge.onNewToken("fixture-token")
  }

  @Test
  fun `the shim and both entry points are deprecated at WARNING level`() {
    val members = listOf(
      NottiBridge::class.java,
      NottiBridge::class.java.getMethod("onMessageReceived", RemoteMessage::class.java),
      NottiBridge::class.java.getMethod("onNewToken", String::class.java)
    )
    for (member in members) {
      val deprecated = member.getAnnotation(Deprecated::class.java)
      assertTrue("$member is not @Deprecated", deprecated != null)
      assertEquals(DeprecationLevel.WARNING, deprecated!!.level)
    }
  }

  private fun fixtureMessage() = RemoteMessage(
    Bundle().apply {
      putString("gcm.n.title", "Fixture title")
      putString("gcm.n.body", "Fixture body")
      putString("notification_id", "fixture-n")
      putString("delivery_id", "fixture-d")
    }
  )
}
