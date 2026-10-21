package com.notti

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Fixtures use only synthetic values (`example.invalid`, all-zero UUIDs,
 * `fixture`). Pure JVM: `org.json` comes from the test artifact.
 */
class NottiInAppModelsTest {
  private val zeroId = "00000000-0000-0000-0000-000000000000"

  private fun message(
    vararg extra: String,
    title: String = "\"fixture\"",
    id: String = "\"$zeroId\""
  ): String {
    val fields = mutableListOf(
      "\"id\": $id",
      "\"title\": $title",
      "\"body\": \"fixture body\"",
      "\"trigger\": {\"type\": \"session_start\"}"
    )
    fields.addAll(extra)
    return "{" + fields.joinToString(",") + "}"
  }

  private fun parseOne(
    vararg extra: String,
    title: String = "\"fixture\"",
    id: String = "\"$zeroId\""
  ): InAppMessage {
    val body = "{\"messages\": [${message(*extra, title = title, id = id)}]}"
    val parsed = parseEligibleResponse(body)
    assertNotNull(parsed)
    assertEquals(1, parsed!!.size)
    return parsed[0]
  }

  private fun parseRaw(entry: String): InAppMessage =
    parseEligibleResponse("{\"messages\": [$entry]}")!![0]

  // --- response envelope -------------------------------------------------

  @Test
  fun `empty messages array is a valid result`() {
    assertEquals(emptyList<InAppMessage>(), parseEligibleResponse("{\"messages\": []}"))
  }

  @Test
  fun `a body that is not a JSON object is a parse failure`() {
    listOf("", "not json", "[]", "\"text\"", "null", "42").forEach {
      assertNull("body: $it", parseEligibleResponse(it))
    }
  }

  @Test
  fun `a missing or non array messages field is a parse failure`() {
    assertNull(parseEligibleResponse("{}"))
    assertNull(parseEligibleResponse("{\"messages\": null}"))
    assertNull(parseEligibleResponse("{\"messages\": {}}"))
  }

  @Test
  fun `unknown fields are ignored at every level`() {
    val parsed = parseOne(
      "\"future\": {\"a\": 1}",
      "\"style\": {\"future_token\": \"x\"}",
      "\"buttons\": [{\"id\": \"b1\", \"label\": \"Go\", \"future\": true}]"
    )
    assertEquals(zeroId, parsed.id)
    assertTrue(parsed.renderable)
    assertEquals(1, parsed.buttons.size)
  }

  @Test
  fun `an entry that cannot be parsed is skipped without failing the others`() {
    val body = "{\"messages\": [42, ${message()}, \"text\", null, [], ${message(id = "\"b\"")}]}"
    val parsed = parseEligibleResponse(body)!!
    assertEquals(listOf(zeroId, "b"), parsed.map { it.id })
  }

  @Test
  fun `server order is preserved`() {
    val body = "{\"messages\": [${message(id = "\"c\"")}, ${message(id = "\"a\"")}, ${message(id = "\"b\"")}]}"
    assertEquals(listOf("c", "a", "b"), parseEligibleResponse(body)!!.map { it.id })
  }

  // --- renderability (SDKIAM-14) -----------------------------------------

  @Test
  fun `a complete message is renderable and keeps its fields`() {
    val parsed = parseOne(
      "\"format\": \"top\"",
      "\"image_url\": \"https://example.invalid/i.png\"",
      "\"image_action\": {\"type\": \"url\", \"value\": \"https://example.invalid/offer\"}",
      "\"dismiss_after_seconds\": 8"
    )
    assertTrue(parsed.renderable)
    assertEquals(InAppFormat.TOP, parsed.format)
    assertEquals("fixture", parsed.title)
    assertEquals("fixture body", parsed.body)
    assertEquals("https://example.invalid/i.png", parsed.imageUrl)
    assertEquals(InAppAction("url", "https://example.invalid/offer"), parsed.imageAction)
    assertEquals(8, parsed.dismissAfterSeconds)
    assertEquals(InAppTrigger.SessionStart, parsed.trigger)
  }

  @Test
  fun `empty or missing id is not renderable`() {
    assertFalse(parseOne(id = "\"\"").renderable)
    assertFalse(parseOne(id = "null").renderable)
    assertFalse(parseOne(id = "7").renderable)
  }

  @Test
  fun `title and body both blank after trimming is not renderable`() {
    val trigger = "\"trigger\": {\"type\": \"session_start\"}"
    assertFalse(parseRaw("{\"id\": \"a\", \"title\": \"  \\n\", \"body\": \"\", $trigger}").renderable)
    assertTrue(parseRaw("{\"id\": \"a\", \"title\": \"\", \"body\": \"text\", $trigger}").renderable)
    assertTrue(parseRaw("{\"id\": \"a\", \"title\": \"text\", $trigger}").renderable)
  }

  @Test
  fun `unknown or missing trigger is not renderable`() {
    assertFalse(parseRaw("{\"id\": \"a\", \"title\": \"t\", \"trigger\": {\"type\": \"scroll\"}}").renderable)
    assertFalse(parseRaw("{\"id\": \"a\", \"title\": \"t\"}").renderable)
  }

  @Test
  fun `event trigger keeps its name and an empty name is not renderable`() {
    val parsed = parseRaw("{\"id\": \"a\", \"title\": \"t\", \"trigger\": {\"type\": \"event\", \"name\": \" Checkout_Done \"}}")
    assertTrue(parsed.renderable)
    assertEquals(InAppTrigger.Event(" Checkout_Done "), parsed.trigger)

    listOf(
      "{\"type\": \"event\", \"name\": \"\"}",
      "{\"type\": \"event\"}",
      "{\"type\": \"event\", \"name\": 3}"
    ).forEach {
      assertFalse("trigger: $it", parseRaw("{\"id\": \"a\", \"title\": \"t\", \"trigger\": $it}").renderable)
    }
  }

  // --- format -------------------------------------------------------------

  @Test
  fun `known formats map and unknown or missing format renders center`() {
    assertEquals(InAppFormat.TOP, parseOne("\"format\": \"top\"").format)
    assertEquals(InAppFormat.BOTTOM, parseOne("\"format\": \"bottom\"").format)
    assertEquals(InAppFormat.FULL, parseOne("\"format\": \"full\"").format)
    assertEquals(InAppFormat.CENTER, parseOne("\"format\": \"center\"").format)
    assertEquals(InAppFormat.CENTER, parseOne("\"format\": \"carousel\"").format)
    assertEquals(InAppFormat.CENTER, parseOne("\"format\": \"TOP\"").format)
    assertEquals(InAppFormat.CENTER, parseOne("\"format\": 3").format)
    assertEquals(InAppFormat.CENTER, parseOne().format)
  }

  @Test
  fun `unknown format keeps title body buttons and style unchanged and renderable`() {
    val parsed = parseOne(
      "\"format\": \"carousel\"",
      "\"style\": {\"background_color\": \"#102030\", \"text_align\": \"right\"}",
      "\"buttons\": [{\"id\": \"b1\", \"label\": \"Go\", \"action\": {\"type\": \"url\", \"value\": \"https://example.invalid/x\"}}]"
    )
    assertEquals(InAppFormat.CENTER, parsed.format)
    assertTrue(parsed.renderable)
    assertEquals("fixture", parsed.title)
    assertEquals("fixture body", parsed.body)
    assertEquals(listOf("b1"), parsed.buttons.map { it.id })
    assertEquals(0xFF102030.toInt(), parsed.style.backgroundColor)
    assertEquals(InAppTextAlign.RIGHT, parsed.style.textAlign)
  }

  // --- buttons ------------------------------------------------------------

  @Test
  fun `button with empty or missing id or label is dropped and the message stays renderable`() {
    val parsed = parseOne(
      "\"buttons\": [" +
        "{\"id\": \"\", \"label\": \"No id\"}," +
        "{\"label\": \"Missing id\"}," +
        "{\"id\": \"b1\", \"label\": \"\"}," +
        "{\"id\": \"b2\"}," +
        "{\"id\": 5, \"label\": \"Bad id type\"}," +
        "\"not an object\"]"
    )
    assertTrue(parsed.renderable)
    assertEquals(emptyList<InAppButton>(), parsed.buttons)
  }

  @Test
  fun `three buttons with the first invalid keep the next two valid ones`() {
    val parsed = parseOne(
      "\"buttons\": [" +
        "{\"id\": \"\", \"label\": \"bad\"}," +
        "{\"id\": \"b1\", \"label\": \"One\"}," +
        "{\"id\": \"b2\", \"label\": \"Two\"}," +
        "{\"id\": \"b3\", \"label\": \"Three\"}]"
    )
    assertEquals(listOf("b1", "b2"), parsed.buttons.map { it.id })
  }

  @Test
  fun `at most two valid buttons are kept in order`() {
    val parsed = parseOne(
      "\"buttons\": [{\"id\": \"b1\", \"label\": \"1\"}, {\"id\": \"b2\", \"label\": \"2\"}, {\"id\": \"b3\", \"label\": \"3\"}]"
    )
    assertEquals(listOf("b1", "b2"), parsed.buttons.map { it.id })
  }

  @Test
  fun `a missing or non array buttons field yields no buttons`() {
    assertEquals(emptyList<InAppButton>(), parseOne().buttons)
    assertEquals(emptyList<InAppButton>(), parseOne("\"buttons\": null").buttons)
    assertEquals(emptyList<InAppButton>(), parseOne("\"buttons\": {}").buttons)
  }

  // --- actions ------------------------------------------------------------

  @Test
  fun `action value is kept byte for byte`() {
    val value = "exampleapp://offers/42?utm=a b&x=%20  "
    val parsed = parseOne(
      "\"buttons\": [{\"id\": \"b1\", \"label\": \"Go\", \"action\": {\"type\": \"deeplink\", \"value\": \"$value\"}}]"
    )
    assertEquals(InAppAction("deeplink", value), parsed.buttons[0].action)
  }

  @Test
  fun `unknown action type keeps the message renderable and yields a null action`() {
    val parsed = parseOne(
      "\"buttons\": [{\"id\": \"b1\", \"label\": \"Go\", \"action\": {\"type\": \"share\", \"value\": \"x\"}}]"
    )
    assertTrue(parsed.renderable)
    assertEquals(1, parsed.buttons.size)
    assertNull(parsed.buttons[0].action)
  }

  @Test
  fun `missing null or malformed action yields a null action`() {
    listOf(
      "{\"id\": \"b1\", \"label\": \"Go\"}",
      "{\"id\": \"b1\", \"label\": \"Go\", \"action\": null}",
      "{\"id\": \"b1\", \"label\": \"Go\", \"action\": \"url\"}",
      "{\"id\": \"b1\", \"label\": \"Go\", \"action\": {\"type\": \"url\"}}",
      "{\"id\": \"b1\", \"label\": \"Go\", \"action\": {\"type\": \"url\", \"value\": \"\"}}"
    ).forEach {
      val parsed = parseOne("\"buttons\": [$it]")
      assertEquals(1, parsed.buttons.size)
      assertNull("button: $it", parsed.buttons[0].action)
    }
  }

  // --- image --------------------------------------------------------------

  @Test
  fun `https image url is kept`() {
    assertEquals(
      "https://example.invalid/i.png",
      parseOne("\"image_url\": \"https://example.invalid/i.png\"").imageUrl
    )
  }

  @Test
  fun `http relative and malformed image urls are ignored and the message stays renderable`() {
    listOf(
      "\"http://example.invalid/i.png\"",
      "\"//example.invalid/i.png\"",
      "\"/i.png\"",
      "\"i.png\"",
      "\"https://\"",
      "\"\"",
      "null",
      "5"
    ).forEach {
      val parsed = parseOne("\"image_url\": $it")
      assertNull("image_url: $it", parsed.imageUrl)
      assertTrue(parsed.renderable)
    }
  }

  @Test
  fun `image action without a usable image is ignored`() {
    val action = "\"image_action\": {\"type\": \"url\", \"value\": \"https://example.invalid/offer\"}"
    assertNull(parseOne(action).imageAction)
    assertNull(parseOne("\"image_url\": \"http://example.invalid/i.png\"", action).imageAction)
  }

  @Test
  fun `image action with an unknown type is ignored but the image stays`() {
    val parsed = parseOne(
      "\"image_url\": \"https://example.invalid/i.png\"",
      "\"image_action\": {\"type\": \"share\", \"value\": \"x\"}"
    )
    assertEquals("https://example.invalid/i.png", parsed.imageUrl)
    assertNull(parsed.imageAction)
  }

  @Test
  fun `a push permission button parses with no value`() {
    val parsed = parseOne(
      "\"buttons\": [{\"id\": \"b1\", \"label\": \"Allow\", \"action\": {\"type\": \"push_permission\"}}]"
    )
    assertEquals(InAppAction(InAppAction.PUSH_PERMISSION, ""), parsed.buttons[0].action)
    assertTrue(parsed.renderable)
  }

  @Test
  fun `a push permission image action is dropped and other unknown types still are`() {
    val parsed = parseOne(
      "\"image_url\": \"https://example.invalid/i.png\"",
      "\"image_action\": {\"type\": \"push_permission\"}"
    )
    assertEquals("https://example.invalid/i.png", parsed.imageUrl)
    assertNull(parsed.imageAction)
    val share = parseOne(
      "\"buttons\": [{\"id\": \"b1\", \"label\": \"Go\", \"action\": {\"type\": \"share\", \"value\": \"x\"}}]"
    )
    assertNull(share.buttons[0].action)
  }

  // --- style --------------------------------------------------------------

  @Test
  fun `null or missing style yields the defaults`() {
    assertEquals(InAppStyle(), parseOne().style)
    assertEquals(InAppStyle(), parseOne("\"style\": null").style)
    assertEquals(InAppStyle(), parseOne("\"style\": {}").style)
    assertEquals(InAppStyle(), parseOne("\"style\": \"dark\"").style)
  }

  @Test
  fun `style tokens are parsed`() {
    val style = parseOne(
      "\"style\": {\"background_color\": \"#102030\", \"text_color\": \"#ffffff\", " +
        "\"button_color\": \"#E94B8B\", \"button_text_color\": \"#000000\", " +
        "\"text_align\": \"center\", \"margin\": false}"
    ).style
    assertEquals(0xFF102030.toInt(), style.backgroundColor)
    assertEquals(0xFFFFFFFF.toInt(), style.textColor)
    assertEquals(0xFFE94B8B.toInt(), style.buttonColor)
    assertEquals(0xFF000000.toInt(), style.buttonTextColor)
    assertEquals(InAppTextAlign.CENTER, style.textAlign)
    assertFalse(style.margin)
  }

  @Test
  fun `a bad color token falls back to the default without affecting the others`() {
    val style = parseOne(
      "\"style\": {\"background_color\": \"red\", \"text_color\": \"#FFFFFF\", \"button_color\": \"#12345678\"}"
    ).style
    assertNull(style.backgroundColor)
    assertEquals(0xFFFFFFFF.toInt(), style.textColor)
    assertNull(style.buttonColor)
  }

  @Test
  fun `text align and margin fall back to their defaults`() {
    assertEquals(InAppTextAlign.LEFT, parseOne("\"style\": {\"text_align\": \"justify\"}").style.textAlign)
    assertEquals(InAppTextAlign.LEFT, parseOne("\"style\": {\"text_align\": \"left\"}").style.textAlign)
    assertEquals(InAppTextAlign.RIGHT, parseOne("\"style\": {\"text_align\": \"right\"}").style.textAlign)
    assertTrue(parseOne("\"style\": {\"margin\": \"no\"}").style.margin)
    assertTrue(parseOne("\"style\": {\"margin\": null}").style.margin)
    assertFalse(parseOne("\"style\": {\"margin\": false}").style.margin)
  }

  // --- parseHexColor ------------------------------------------------------

  @Test
  fun `parseHexColor accepts RRGGBB in either case as opaque ARGB`() {
    assertEquals(0xFF102030.toInt(), parseHexColor("#102030"))
    assertEquals(0xFFABCDEF.toInt(), parseHexColor("#ABCDEF"))
    assertEquals(0xFFABCDEF.toInt(), parseHexColor("#abcdef"))
    assertEquals(0xFF000000.toInt(), parseHexColor("#000000"))
    assertEquals(0xFFFFFFFF.toInt(), parseHexColor("#FFFFFF"))
  }

  @Test
  fun `parseHexColor rejects every other form without throwing`() {
    listOf(
      null, "", " ", "#", "#RGB", "#abc", "#RRGGBBAA", "#12345678", "102030", "#10203",
      "#1020301", "#GGGGGG", "#10 030", " #102030", "#102030 ", "#102030\n", "rgb(1,2,3)"
    ).forEach {
      assertNull("value: $it", parseHexColor(it))
    }
  }

  // --- dismiss_after_seconds ----------------------------------------------

  @Test
  fun `dismiss_after_seconds inside 1 to 300 is kept`() {
    assertEquals(1, parseOne("\"dismiss_after_seconds\": 1").dismissAfterSeconds)
    assertEquals(8, parseOne("\"dismiss_after_seconds\": 8").dismissAfterSeconds)
    assertEquals(300, parseOne("\"dismiss_after_seconds\": 300").dismissAfterSeconds)
  }

  @Test
  fun `dismiss_after_seconds outside the range null absent or not an integer means no timer`() {
    listOf("0", "-1", "301", "100000", "null", "\"8\"", "8.5", "true", "{}").forEach {
      assertNull("value: $it", parseOne("\"dismiss_after_seconds\": $it").dismissAfterSeconds)
    }
    assertNull(parseOne().dismissAfterSeconds)
  }

  // --- title/body types ---------------------------------------------------

  @Test
  fun `title and body that are not strings count as empty`() {
    val parsed = parseRaw("{\"id\": \"a\", \"title\": 5, \"body\": null, \"trigger\": {\"type\": \"session_start\"}}")
    assertEquals("", parsed.title)
    assertEquals("", parsed.body)
    assertFalse(parsed.renderable)
  }

  @Test
  fun `title and body are kept as plain text without interpretation`() {
    val parsed = parseRaw(
      "{\"id\": \"a\", \"title\": \"<b>Hi</b> **x**\", \"body\": \"line1\\nline2\", \"trigger\": {\"type\": \"session_start\"}}"
    )
    assertEquals("<b>Hi</b> **x**", parsed.title)
    assertEquals("line1\nline2", parsed.body)
  }
}
