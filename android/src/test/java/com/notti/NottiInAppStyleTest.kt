package com.notti

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class NottiInAppStyleTest {

  private val themeBackground = 0xFF101010.toInt()
  private val themeText = 0xFFEEEEEE.toInt()
  private val themeAccent = 0xFF00AA00.toInt()
  private val theme = InAppThemeColors(themeBackground, themeText, themeAccent, night = false)
  private val palette = resolvePalette(theme)

  private fun styleOf(json: String?): InAppStyle {
    val style = if (json == null) "" else ""","style":$json"""
    val body = """{"messages":[{"id":"m","title":"t","trigger":{"type":"session_start"}$style}]}"""
    return parseEligibleResponse(body)!!.single().style
  }

  // Palette

  @Test
  fun `palette uses the theme attributes when defined`() {
    assertEquals(InAppPalette(themeBackground, themeText, themeAccent), palette)
  }

  @Test
  fun `undefined attributes fall back to the light or dark constants`() {
    val light = resolvePalette(InAppThemeColors(null, null, null, night = false))
    assertEquals(InAppPalette(0xFFFFFFFF.toInt(), 0xFF1C1C1E.toInt(), 0xFF0A84FF.toInt()), light)
    val dark = resolvePalette(InAppThemeColors(null, null, null, night = true))
    assertEquals(InAppPalette(0xFF1C1C1E.toInt(), 0xFFF2F2F7.toInt(), 0xFF0A84FF.toInt()), dark)
  }

  @Test
  fun `each attribute falls back on its own`() {
    val mixed = resolvePalette(InAppThemeColors(themeBackground, null, null, night = true))
    assertEquals(InAppPalette(themeBackground, 0xFFF2F2F7.toInt(), 0xFF0A84FF.toInt()), mixed)
  }

  // Style tokens

  @Test
  fun `null style gives all defaults`() {
    val resolved = resolveStyle(styleOf(null), palette, buttonCount = 2)
    assertEquals(themeBackground, resolved.background)
    assertEquals(themeText, resolved.text)
    assertEquals(InAppTextAlign.LEFT, resolved.textAlign)
    assertTrue(resolved.margin)
    assertEquals(
      listOf(
        InAppButtonLook(InAppButtonKind.FILLED, themeAccent, InAppColors.WHITE),
        InAppButtonLook(InAppButtonKind.TINTED, InAppColors.withAlpha(themeText, 0x1F), themeText)
      ),
      resolved.buttons
    )
  }

  @Test
  fun `valid tokens apply, lower-case hex accepted`() {
    val resolved = resolveStyle(
      styleOf("""{"background_color":"#ff0000","text_color":"#00FF00","text_align":"right","margin":false}"""),
      palette,
      buttonCount = 0
    )
    assertEquals(0xFFFF0000.toInt(), resolved.background)
    assertEquals(0xFF00FF00.toInt(), resolved.text)
    assertEquals(InAppTextAlign.RIGHT, resolved.textAlign)
    assertEquals(false, resolved.margin)
  }

  @Test
  fun `an invalid token uses its default and the others still apply`() {
    for (bad in listOf("red", "#FFF", "FF0000", "#GG0000", "#80FF0000", "")) {
      val resolved = resolveStyle(
        styleOf("""{"background_color":"$bad","text_color":"#00FF00"}"""),
        palette,
        buttonCount = 0
      )
      assertEquals("token $bad", themeBackground, resolved.background)
      assertEquals(0xFF00FF00.toInt(), resolved.text)
    }
  }

  @Test
  fun `text_align absent or unknown is left, margin absent is true`() {
    for (json in listOf("{}", """{"text_align":"justify"}""", """{"text_align":"CENTER"}""")) {
      val resolved = resolveStyle(styleOf(json), palette, 0)
      assertEquals(InAppTextAlign.LEFT, resolved.textAlign)
      assertTrue(resolved.margin)
    }
    assertEquals(InAppTextAlign.CENTER, resolveStyle(styleOf("""{"text_align":"center"}"""), palette, 0).textAlign)
  }

  @Test
  fun `button_color applies to all buttons and the label keeps its default`() {
    val resolved = resolveStyle(styleOf("""{"button_color":"#123456"}"""), palette, 2)
    val expected = InAppButtonLook(InAppButtonKind.FILLED, 0xFF123456.toInt(), InAppColors.WHITE)
    assertEquals(listOf(expected, expected), resolved.buttons)
  }

  @Test
  fun `button_text_color alone applies to all buttons over the default background`() {
    val resolved = resolveStyle(styleOf("""{"button_text_color":"#000000"}"""), palette, 2)
    val expected = InAppButtonLook(InAppButtonKind.FILLED, themeAccent, 0xFF000000.toInt())
    assertEquals(listOf(expected, expected), resolved.buttons)
  }

  @Test
  fun `only background_color set derives nothing else`() {
    for (background in listOf("#FFFFFF", "#000000", "#1C1C1E")) {
      val resolved = resolveStyle(styleOf("""{"background_color":"$background"}"""), palette, 2)
      assertEquals(themeText, resolved.text)
      assertEquals(resolveStyle(styleOf(null), palette, 2).buttons, resolved.buttons)
    }
  }

  // Frames

  private val phone = 393f to 852f
  private val smallPhone = 320f to 568f
  private val tablet = 1024f to 1366f
  private val landscape = 852f to 393f
  private val insets = InAppInsets(left = 12f, top = 59f, right = 20f, bottom = 34f)

  private fun frame(format: InAppFormat, margin: Boolean, size: Pair<Float, Float>, safe: InAppInsets = insets) =
    computeFrame(format, margin, size.first, size.second, safe)

  @Test
  fun `bars with margin are inset 16 from the safe-area edges`() {
    val top = frame(InAppFormat.TOP, true, phone)
    assertEquals(InAppGravity.TOP, top.gravity)
    assertEquals(28f, top.marginLeft)
    assertEquals(75f, top.marginTop)
    assertEquals(36f, top.marginRight)
    assertEquals(393f - 12f - 20f - 32f, top.width)
    val bottom = frame(InAppFormat.BOTTOM, true, phone)
    assertEquals(InAppGravity.BOTTOM, bottom.gravity)
    assertEquals(50f, bottom.marginBottom)
    assertEquals(top.width, bottom.width)
  }

  @Test
  fun `bars without margin touch the safe-area edges, never the screen edge`() {
    val top = frame(InAppFormat.TOP, false, landscape)
    assertEquals(12f, top.marginLeft)
    assertEquals(59f, top.marginTop)
    assertEquals(20f, top.marginRight)
    assertEquals(852f - 12f - 20f, top.width)
    val bottom = frame(InAppFormat.BOTTOM, false, landscape)
    assertEquals(34f, bottom.marginBottom)
  }

  @Test
  fun `bar height is at most 40 percent of the container`() {
    for (size in listOf(phone, smallPhone, tablet, landscape)) {
      for (format in listOf(InAppFormat.TOP, InAppFormat.BOTTOM)) {
        val bar = frame(format, true, size)
        assertTrue("$size $format", bar.maxHeight <= size.second * 0.4f + 0.001f)
        assertTrue(bar.maxHeight > 0f)
      }
    }
  }

  @Test
  fun `bar height also stays inside the safe area when it is shorter than 40 percent`() {
    val tallInsets = InAppInsets(left = 0f, top = 150f, right = 0f, bottom = 150f)
    for (format in listOf(InAppFormat.TOP, InAppFormat.BOTTOM)) {
      assertEquals("$format", 393f - 300f - 32f, frame(format, true, landscape, tallInsets).maxHeight, 0.001f)
      assertEquals("$format", 393f - 300f, frame(format, false, landscape, tallInsets).maxHeight, 0.001f)
    }
  }

  @Test
  fun `center card is at most 90 percent wide, capped at 560, and ignores margin`() {
    val phoneCard = frame(InAppFormat.CENTER, true, phone)
    assertEquals(InAppGravity.CENTER, phoneCard.gravity)
    assertEquals(393f * 0.9f, phoneCard.width, 0.001f)
    assertEquals(frame(InAppFormat.CENTER, false, phone), phoneCard)
    assertEquals(560f, frame(InAppFormat.CENTER, true, tablet).width)
    assertEquals(560f, frame(InAppFormat.CENTER, true, landscape).width)
    assertEquals(320f * 0.9f, frame(InAppFormat.CENTER, true, smallPhone).width, 0.001f)
    assertEquals((852f - 59f - 34f) * 0.9f, phoneCard.maxHeight, 0.001f)
    assertEquals(12f, phoneCard.marginLeft)
    assertEquals(59f, phoneCard.marginTop)
  }

  @Test
  fun `center card never exceeds the safe width`() {
    val narrowSafe = InAppInsets(100f, 0f, 100f, 0f)
    assertEquals(120f, frame(InAppFormat.CENTER, true, 320f to 568f, narrowSafe).width)
  }

  @Test
  fun `full fills the safe area with 16 on all four sides`() {
    val full = frame(InAppFormat.FULL, true, phone)
    assertEquals(InAppGravity.FILL, full.gravity)
    assertEquals(listOf(28f, 75f, 36f, 50f), listOf(full.marginLeft, full.marginTop, full.marginRight, full.marginBottom))
    assertEquals(393f - 12f - 20f - 32f, full.width)
    assertEquals(852f - 59f - 34f - 32f, full.maxHeight)
  }

  @Test
  fun `full without margin touches the safe-area edges on all sides`() {
    val full = frame(InAppFormat.FULL, false, landscape)
    assertEquals(listOf(12f, 59f, 20f, 34f), listOf(full.marginLeft, full.marginTop, full.marginRight, full.marginBottom))
    assertEquals(852f - 32f, full.width)
    assertEquals(393f - 93f, full.maxHeight)
  }

  @Test
  fun `zero insets keep the frame inside the container`() {
    for (size in listOf(phone, smallPhone, tablet, landscape)) {
      for (format in InAppFormat.values()) {
        val f = frame(format, true, size, InAppInsets.ZERO)
        assertTrue(f.width <= size.first)
        assertTrue(f.maxHeight <= size.second)
      }
    }
  }
}
