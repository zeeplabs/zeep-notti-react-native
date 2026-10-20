package com.notti

import android.app.Activity
import android.graphics.Bitmap
import android.graphics.drawable.GradientDrawable
import android.text.Spanned
import android.text.style.URLSpan
import android.view.Gravity
import android.graphics.Rect
import android.os.Looper
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.accessibility.AccessibilityNodeInfo
import android.widget.Button
import android.widget.FrameLayout
import java.util.Locale
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
// Real text measurement, so the button wrap and the scroll bounds are measured, not stubbed.
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class NottiInAppViewFactoryTest {

  private val insets = InAppInsets(left = 12f, top = 59f, right = 20f, bottom = 34f)
  private val longBody = (1..200).joinToString("\n") { "Line $it of a long body" }

  private data class Screen(val qualifiers: String, val widthDp: Int, val heightDp: Int)

  private val screens = listOf(
    Screen("w393dp-h852dp-port", 393, 852),
    Screen("w852dp-h393dp-land", 852, 393),
    Screen("w1024dp-h1366dp-port", 1024, 1366),
    Screen("w1366dp-h1024dp-land", 1366, 1024)
  )

  @After
  fun tearDown() {
    RuntimeEnvironment.setFontScale(1f)
  }

  private fun activity(): Activity = Robolectric.buildActivity(Activity::class.java).setup().get()

  private fun message(
    format: String,
    title: String = "Title",
    body: String = "Body",
    style: String? = null,
    buttons: String = "",
    image: Boolean = false,
    imageAction: Boolean = false
  ): InAppMessage {
    val styleJson = if (style == null) "" else ""","style":$style"""
    val imageJson = (if (image) ""","image_url":"https://img.test/a.png"""" else "") +
      (if (imageAction) ""","image_action":{"type":"deeplink","value":"app://promo"}""" else "")
    val buttonsJson = if (buttons.isEmpty()) "" else ""","buttons":[$buttons]"""
    val raw = """{"messages":[{"id":"m","format":"$format","title":${JSONString.quote(title)},"body":${JSONString.quote(body)},""" +
      """"trigger":{"type":"session_start"}$styleJson$imageJson$buttonsJson}]}"""
    return parseEligibleResponse(raw)!!.single()
  }

  private object JSONString {
    fun quote(value: String): String = org.json.JSONObject.quote(value)
  }

  private fun button(id: String, label: String) = """{"id":"$id","label":${JSONString.quote(label)}}"""

  private fun layout(views: InAppMessageViews, widthDp: Int, heightDp: Int, safe: InAppInsets = insets) {
    val density = views.root.resources.displayMetrics.density
    val w = (widthDp * density).toInt()
    val h = (heightDp * density).toInt()
    views.root.safeArea = safe
    views.root.measure(View.MeasureSpec.makeMeasureSpec(w, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(h, View.MeasureSpec.EXACTLY))
    views.root.layout(0, 0, w, h)
  }

  private fun dp(view: View, px: Int): Float = px / view.resources.displayMetrics.density

  private fun bitmap(): Bitmap = Bitmap.createBitmap(120, 80, Bitmap.Config.ARGB_8888)

  // Bounds

  @Test
  fun `every layout respects its bounds across sizes, font scales and themes`() {
    for (screen in screens) {
      for (night in listOf(false, true)) {
        for (scale in listOf(1f, 2f)) {
          RuntimeEnvironment.setQualifiers("${screen.qualifiers}-${if (night) "night" else "notnight"}")
          RuntimeEnvironment.setFontScale(scale)
          val context = activity()
          for (format in listOf("top", "bottom", "center", "full")) {
            val views = NottiInAppViewFactory.build(
              context,
              message(format, body = longBody, buttons = button("a", "Accept") + "," + button("b", "Later"))
            )
            layout(views, screen.widthDp, screen.heightDp)
            val label = "${screen.qualifiers} night=$night scale=$scale $format"
            val cardW = dp(views.card, views.card.width)
            val cardH = dp(views.card, views.card.height)
            val safeH = screen.heightDp - insets.top - insets.bottom
            when (format) {
              "top", "bottom" -> {
                assertTrue("$label height $cardH", cardH <= screen.heightDp * 0.4f + 1f)
                assertEquals(label, screen.widthDp - insets.left - insets.right - 32f, cardW, 1f)
              }
              "center" -> {
                assertTrue(label, cardW <= screen.widthDp * 0.9f + 1f && cardW <= 561f)
                assertTrue(label, cardH <= safeH * 0.9f + 1f)
              }
              "full" -> {
                assertEquals(label, screen.widthDp - insets.left - insets.right - 32f, cardW, 1f)
                assertEquals(label, safeH - 32f, cardH, 1f)
              }
            }
            // Buttons and close control stay inside the card: the body scrolls instead.
            for (b in views.buttons) {
              assertTrue(label, b.bottom > 0)
              val bottomInCard = b.bottom + views.buttonRow!!.top + (views.buttonRow.parent as View).top
              assertTrue("$label button bottom $bottomInCard > ${views.card.height}", bottomInCard <= views.card.height)
            }
            assertTrue(label, views.close.width >= dp48(views.close) && views.close.height >= dp48(views.close))
            assertEquals(View.VISIBLE, views.close.visibility)
          }
        }
      }
    }
  }

  private fun dp48(view: View): Int = (48 * view.resources.displayMetrics.density).toInt()

  @Test
  fun `bars with margin sit 16 dp inside the safe area`() {
    RuntimeEnvironment.setQualifiers("w393dp-h852dp-xxhdpi")
    val context = activity()
    val top = NottiInAppViewFactory.build(context, message("top"))
    layout(top, 393, 852)
    assertEquals(28f, dp(top.card, top.card.left), 0.5f)
    assertEquals(75f, dp(top.card, top.card.top), 0.5f)
    assertEquals(393f - 36f, dp(top.card, top.card.right), 0.5f)

    val bottom = NottiInAppViewFactory.build(context, message("bottom"))
    layout(bottom, 393, 852)
    assertEquals(852f - 50f, dp(bottom.card, bottom.card.bottom), 0.5f)
  }

  @Test
  fun `margin false touches the safe-area edges on every side, never the screen edge`() {
    RuntimeEnvironment.setQualifiers("w852dp-h393dp-land")
    val context = activity()
    val top = NottiInAppViewFactory.build(context, message("top", style = """{"margin":false}"""))
    layout(top, 852, 393)
    assertEquals(12f, dp(top.card, top.card.left), 0.5f)
    assertEquals(59f, dp(top.card, top.card.top), 0.5f)
    assertEquals(852f - 20f, dp(top.card, top.card.right), 0.5f)

    val bottom = NottiInAppViewFactory.build(context, message("bottom", style = """{"margin":false}"""))
    layout(bottom, 852, 393)
    assertEquals(393f - 34f, dp(bottom.card, bottom.card.bottom), 0.5f)
    assertEquals(12f, dp(bottom.card, bottom.card.left), 0.5f)

    val full = NottiInAppViewFactory.build(context, message("full", style = """{"margin":false}"""))
    layout(full, 852, 393)
    assertEquals(listOf(12f, 59f, 832f, 359f), listOf(full.card.left, full.card.top, full.card.right, full.card.bottom).map { dp(full.card, it) })
  }

  @Test
  fun `full with margin is inset 16 on all four sides with buttons pinned to the bottom`() {
    RuntimeEnvironment.setQualifiers("w393dp-h852dp")
    val views = NottiInAppViewFactory.build(activity(), message("full", body = "Short", buttons = button("a", "OK")))
    layout(views, 393, 852)
    assertEquals(listOf(28f, 75f, 357f, 802f), listOf(views.card.left, views.card.top, views.card.right, views.card.bottom).map { dp(views.card, it) })
    val column = views.buttonRow!!.parent as View
    assertEquals(column.height - column.paddingBottom, views.buttonRow.bottom)
  }

  @Test
  fun `center ignores margin`() {
    RuntimeEnvironment.setQualifiers("w393dp-h852dp")
    val context = activity()
    val with = NottiInAppViewFactory.build(context, message("center"))
    val without = NottiInAppViewFactory.build(context, message("center", style = """{"margin":false}"""))
    layout(with, 393, 852)
    layout(without, 393, 852)
    assertEquals(with.card.width, without.card.width)
    assertEquals(with.card.left, without.card.left)
    // Centered in the safe area (12 left, 20 right).
    val safeCenter = 12f + (393f - 32f) / 2
    assertEquals(safeCenter, dp(with.card, (with.card.left + with.card.right) / 2), 1f)
    val safeMiddle = 59f + (852f - 93f) / 2
    assertEquals(safeMiddle, dp(with.card, (with.card.top + with.card.bottom) / 2), 1f)
  }

  @Test
  fun `unknown format renders as center`() {
    RuntimeEnvironment.setQualifiers("w393dp-h852dp")
    val views = NottiInAppViewFactory.build(activity(), message("sideways"))
    layout(views, 393, 852)
    assertEquals(InAppGravity.CENTER, views.root.frame!!.gravity)
  }

  @Test
  fun `bars let touches through, center and full block them`() {
    val context = activity()
    assertFalse(NottiInAppViewFactory.build(context, message("top")).root.isClickable)
    assertFalse(NottiInAppViewFactory.build(context, message("bottom")).root.isClickable)
    val center = NottiInAppViewFactory.build(context, message("center"))
    assertTrue(center.root.isClickable)
    assertEquals(InAppColors.BACKDROP, (center.root.background as android.graphics.drawable.ColorDrawable).color)
    val full = NottiInAppViewFactory.build(context, message("full"))
    assertTrue(full.root.isClickable)
    assertNull(full.root.background)
  }

  // Plain text

  @Test
  fun `title and body render verbatim with no spans and no links`() {
    val html = "<b>Hi</b> <a href=\"https://x.test\">link</a>"
    val markdown = "**bold** [x](https://y.test) www.z.test\nsecond line"
    val views = NottiInAppViewFactory.build(activity(), message("center", title = html, body = markdown))
    assertEquals(html, views.title.text.toString())
    assertEquals(markdown, views.body.text.toString())
    for (view in listOf(views.title, views.body)) {
      assertEquals(0, view.autoLinkMask)
      assertFalse(view.linksClickable)
      val text = view.text
      if (text is Spanned) assertEquals(0, text.getSpans(0, text.length, URLSpan::class.java).size)
    }
    assertTrue(views.body.text.contains("\n"))
  }

  @Test
  fun `blank title or body is hidden`() {
    val views = NottiInAppViewFactory.build(activity(), message("center", title = " ", body = "Only body"))
    assertEquals(View.GONE, views.title.visibility)
    assertEquals(View.VISIBLE, views.body.visibility)
  }

  // Buttons

  @Test
  fun `two short buttons sit side by side`() {
    RuntimeEnvironment.setQualifiers("w393dp-h852dp")
    val views = NottiInAppViewFactory.build(activity(), message("bottom", buttons = button("a", "Yes") + "," + button("b", "No")))
    layout(views, 393, 852)
    assertFalse(views.buttonRow!!.stacked)
    assertEquals(views.buttons[0].top, views.buttons[1].top)
    assertTrue(views.buttons[0].right <= views.buttons[1].left)
  }

  @Test
  fun `two long buttons wrap to a column, also at font scale 2`() {
    for (scale in listOf(1f, 2f)) {
      RuntimeEnvironment.setQualifiers("w393dp-h852dp")
      RuntimeEnvironment.setFontScale(scale)
      val long = "A very long button label that cannot share a line with another one"
      val views = NottiInAppViewFactory.build(activity(), message("top", buttons = button("a", long) + "," + button("b", long)))
      layout(views, 393, 852)
      assertTrue("scale $scale", views.buttonRow!!.stacked)
      assertTrue(views.buttons[1].top >= views.buttons[0].bottom)
      assertEquals(views.buttonRow.width, views.buttons[0].width)
    }
  }

  @Test
  fun `button labels are not upper-cased and buttons are at least 48 dp tall`() {
    RuntimeEnvironment.setQualifiers("w393dp-h852dp")
    val views = NottiInAppViewFactory.build(activity(), message("center", buttons = button("a", "Mixed Case")))
    layout(views, 393, 852)
    assertEquals("Mixed Case", views.buttons[0].text.toString())
    assertFalse(views.buttons[0].isAllCaps)
    assertTrue(views.buttons[0].height >= dp48(views.buttons[0]))
  }

  // Style

  @Test
  fun `author colors and alignment are applied`() {
    val views = NottiInAppViewFactory.build(
      activity(),
      message(
        "center",
        style = """{"background_color":"#112233","text_color":"#445566","button_color":"#778899","button_text_color":"#AABBCC","text_align":"center"}""",
        buttons = button("a", "A") + "," + button("b", "B")
      )
    )
    assertEquals(0xFF112233.toInt(), (views.card.background as GradientDrawable).color!!.defaultColor)
    assertEquals(0xFF445566.toInt(), views.title.currentTextColor)
    assertEquals(0xFF445566.toInt(), views.body.currentTextColor)
    for (b in views.buttons) {
      assertEquals(0xFF778899.toInt(), (b.background as GradientDrawable).color!!.defaultColor)
      assertEquals(0xFFAABBCC.toInt(), b.currentTextColor)
    }
    assertEquals(Gravity.CENTER_HORIZONTAL, views.title.gravity and Gravity.HORIZONTAL_GRAVITY_MASK)
  }

  @Test
  fun `right alignment is the absolute right side`() {
    val views = NottiInAppViewFactory.build(activity(), message("center", style = """{"text_align":"right"}"""))
    assertEquals(Gravity.RIGHT, views.body.gravity and Gravity.HORIZONTAL_GRAVITY_MASK)
  }

  @Test
  fun `defaults come from the activity theme, second button tinted`() {
    val context = activity()
    val palette = resolvePalette(readThemeColors(context))
    val views = NottiInAppViewFactory.build(context, message("center", buttons = button("a", "A") + "," + button("b", "B")))
    assertEquals(palette.background, (views.card.background as GradientDrawable).color!!.defaultColor)
    assertEquals(palette.text, views.title.currentTextColor)
    assertEquals(palette.accent, (views.buttons[0].background as GradientDrawable).color!!.defaultColor)
    assertEquals(InAppColors.withAlpha(palette.text, InAppColors.TINT_ALPHA), (views.buttons[1].background as GradientDrawable).color!!.defaultColor)
  }

  @Test
  fun `night configuration is read from the activity`() {
    RuntimeEnvironment.setQualifiers("night")
    assertTrue(readThemeColors(activity()).night)
    RuntimeEnvironment.setQualifiers("notnight")
    assertFalse(readThemeColors(activity()).night)
  }

  // Image and close control

  @Test
  fun `bar image is a 56 dp leading thumbnail`() {
    RuntimeEnvironment.setQualifiers("w393dp-h852dp")
    val views = NottiInAppViewFactory.build(activity(), message("top", image = true), bitmap())
    layout(views, 393, 852)
    val image = views.image!!
    assertEquals(56f, dp(image, image.width), 0.5f)
    assertTrue(image.right <= (views.title.parent as View).left)
    assertEquals(views.title.currentTextColor, views.close.currentTextColor)
  }

  @Test
  fun `center image sits above the text and the close glyph gets a scrim`() {
    RuntimeEnvironment.setQualifiers("w393dp-h852dp")
    val views = NottiInAppViewFactory.build(activity(), message("center", image = true), bitmap())
    layout(views, 393, 852)
    assertTrue(views.image!!.bottom <= (views.title.parent as View).top)
    assertEquals(InAppColors.WHITE, views.close.currentTextColor)
    assertNotNull(views.close.background)
  }

  @Test
  fun `no bitmap means no image slot`() {
    val views = NottiInAppViewFactory.build(activity(), message("center", image = true))
    assertNull(views.image)
  }

  @Test
  fun `close control is present whatever the style and content`() {
    val context = activity()
    for (format in listOf("top", "bottom", "center", "full")) {
      val views = NottiInAppViewFactory.build(
        context,
        message(format, body = longBody, style = """{"background_color":"#FFFFFF","text_color":"#FFFFFF","margin":false}""")
      )
      assertEquals(views.card, views.close.parent)
      assertEquals(View.VISIBLE, views.close.visibility)
      assertTrue(views.close.minWidth >= dp48(views.close))
    }
  }

  @Test
  fun `title text keeps the raw string type`() {
    val views = NottiInAppViewFactory.build(activity(), message("top"))
    assertFalse(views.title.text is Spanned)
  }

  // Interactions

  private class Recorder : InAppViewListener {
    val closes = mutableListOf<String>()
    val actions = mutableListOf<Pair<String, InAppAction?>>()
    val total get() = closes.size + actions.size

    override fun onClose(reason: String) {
      closes.add(reason)
    }

    override fun onAction(buttonId: String, action: InAppAction?) {
      actions.add(buttonId to action)
    }
  }

  private fun bound(
    format: String,
    buttons: String = "",
    body: String = "Body",
    bitmap: Bitmap? = null,
    imageAction: Boolean = false
  ): Pair<InAppMessageViews, Recorder> {
    RuntimeEnvironment.setQualifiers("+w393dp-h852dp")
    val msg = message(format, body = body, buttons = buttons, image = bitmap != null, imageAction = imageAction)
    val activity = activity()
    val views = NottiInAppViewFactory.build(activity, msg, bitmap)
    val recorder = Recorder()
    NottiInAppViewFactory.bind(views, msg, recorder)
    // Attached and laid out by a real window: a View only runs its posted click when attached.
    activity.setContentView(views.root)
    shadowOf(Looper.getMainLooper()).idle()
    return views to recorder
  }

  /** Center of [view] in root (screen) pixels. */
  private fun centerOf(root: View, view: View): Pair<Float, Float> {
    val rect = Rect()
    view.getDrawingRect(rect)
    (root as ViewGroup).offsetDescendantRectToMyCoords(view, rect)
    return rect.exactCenterX() to rect.exactCenterY()
  }

  private fun dispatch(root: View, action: Int, x: Float, y: Float, time: Long = 0L): Boolean {
    val ev = MotionEvent.obtain(0L, time, action, x, y, 0)
    return try {
      root.dispatchTouchEvent(ev)
    } finally {
      ev.recycle()
    }
  }

  private fun tap(root: View, x: Float, y: Float): Boolean {
    val consumed = dispatch(root, MotionEvent.ACTION_DOWN, x, y)
    dispatch(root, MotionEvent.ACTION_UP, x, y, 50L)
    // A View posts its click on the main looper.
    shadowOf(Looper.getMainLooper()).idle()
    return consumed
  }

  private fun tap(root: View, view: View) {
    val (x, y) = centerOf(root, view)
    tap(root, x, y)
  }

  /** Vertical drag of [dyPx] in small steps from [view]'s center. */
  private fun drag(views: InAppMessageViews, dyPx: Float, from: View = views.card) {
    val (x, y) = centerOf(views.root, from)
    dispatch(views.root, MotionEvent.ACTION_DOWN, x, y)
    val steps = 10
    for (i in 1..steps) dispatch(views.root, MotionEvent.ACTION_MOVE, x, y + dyPx * i / steps, i * 10L)
    dispatch(views.root, MotionEvent.ACTION_UP, x, y + dyPx, 200L)
  }

  private fun px(view: View, dp: Float): Float = dp * view.resources.displayMetrics.density

  @Test
  fun `close control reports close_button on every layout`() {
    for (format in listOf("top", "bottom", "center", "full")) {
      val (views, recorder) = bound(format, buttons = button("a", "Accept"))
      tap(views.root, views.close)
      assertEquals(format, listOf(InAppDismissReason.CLOSE_BUTTON), recorder.closes)
      assertTrue(format, recorder.actions.isEmpty())
    }
  }

  @Test
  fun `top swipe up past the threshold reports swipe, a short drag does not`() {
    val (views, recorder) = bound("top")
    drag(views, -px(views.card, 12f))
    assertEquals(0, recorder.total)
    assertEquals(0f, views.card.translationY)
    drag(views, -px(views.card, 80f))
    assertEquals(listOf(InAppDismissReason.SWIPE), recorder.closes)
  }

  @Test
  fun `bottom swipe down past the threshold reports swipe, the opposite direction does not`() {
    val (views, recorder) = bound("bottom")
    drag(views, -px(views.card, 80f))
    assertEquals(0, recorder.total)
    assertEquals(0f, views.card.translationY)
    drag(views, px(views.card, 80f))
    assertEquals(listOf(InAppDismissReason.SWIPE), recorder.closes)
  }

  @Test
  fun `swipe threshold is a third of the bar height, at most 48 dp`() {
    assertEquals(20f, swipeThresholdPx(60, 1f), 0.01f)
    assertEquals(48f, swipeThresholdPx(300, 1f), 0.01f)
    assertEquals(144f, swipeThresholdPx(900, 3f), 0.01f)
  }

  @Test
  fun `a swipe that starts on a button dismisses without clicking it`() {
    val (views, recorder) = bound("top", buttons = button("a", "Accept"))
    drag(views, -px(views.card, 80f), from = views.buttons[0])
    assertEquals(listOf(InAppDismissReason.SWIPE), recorder.closes)
    assertTrue(recorder.actions.isEmpty())
  }

  @Test
  fun `a bar whose text can still scroll lets the drag scroll instead of dismissing`() {
    val (views, recorder) = bound("bottom", body = longBody)
    val scroll = views.card.scroll!!
    scroll.scrollTo(0, px(views.card, 40f).toInt())
    assertTrue(scroll.canScrollVertically(-1))
    drag(views, px(views.card, 80f))
    assertTrue(recorder.closes.isEmpty())
  }

  @Test
  fun `center backdrop tap reports outside_tap, a tap inside the card does nothing`() {
    val (views, recorder) = bound("center")
    tap(views.root, views.body)
    tap(views.root, views.card)
    assertEquals(0, recorder.total)
    tap(views.root, 4f, 4f)
    assertEquals(listOf(InAppDismissReason.OUTSIDE_TAP), recorder.closes)
  }

  @Test
  fun `full has no dismiss gesture besides the close control`() {
    val (views, recorder) = bound("full", buttons = button("a", "Accept"))
    tap(views.root, views.body)
    tap(views.root, 2f, 2f)
    drag(views, px(views.card, 200f), from = views.title)
    drag(views, -px(views.card, 200f), from = views.title)
    assertEquals(0, recorder.total)
    assertEquals(0f, views.card.translationY)
  }

  @Test
  fun `button tap reports its own id and the untouched action`() {
    val buttons = """{"id":"yes","label":"Yes","action":{"type":"url","value":"https://x.test/a?b=1"}},""" + button("no", "No")
    for (format in listOf("top", "center", "full")) {
      val (views, recorder) = bound(format, buttons = buttons)
      tap(views.root, views.buttons[1])
      assertEquals(format, listOf("no" to null), recorder.actions)
      val (other, otherRecorder) = bound(format, buttons = buttons)
      tap(other.root, other.buttons[0])
      assertEquals(format, listOf("yes" to InAppAction("url", "https://x.test/a?b=1")), otherRecorder.actions)
    }
  }

  @Test
  fun `image tap with an image action reports image`() {
    for (format in listOf("top", "center", "full")) {
      val (views, recorder) = bound(format, buttons = button("a", "Accept"), bitmap = bitmap(), imageAction = true)
      tap(views.root, views.image!!)
      assertEquals(format, listOf("image" to InAppAction("deeplink", "app://promo")), recorder.actions)
      assertTrue(format, recorder.closes.isEmpty())
    }
  }

  @Test
  fun `image without an image action is not tappable`() {
    val (views, recorder) = bound("center", bitmap = bitmap())
    assertFalse(views.image!!.isClickable)
    tap(views.root, views.image!!)
    assertEquals(0, recorder.total)
  }

  @Test
  fun `bar body tap acts as the first button, no buttons means not tappable`() {
    for (format in listOf("top", "bottom")) {
      val (views, recorder) = bound(format, buttons = button("first", "One") + "," + button("second", "Two"))
      tap(views.root, views.body)
      assertEquals(format, listOf("first" to null), recorder.actions)
      val (bare, bareRecorder) = bound(format)
      tap(bare.root, bare.body)
      assertEquals(format, 0, bareRecorder.total)
    }
  }

  @Test
  fun `center and full body is not tappable even with buttons`() {
    for (format in listOf("center", "full")) {
      val (views, recorder) = bound(format, buttons = button("a", "Accept"))
      tap(views.root, views.body)
      tap(views.root, views.title)
      assertEquals(format, 0, recorder.total)
    }
  }

  @Test
  fun `touches outside a bar are not consumed, inside they are`() {
    for (format in listOf("top", "bottom")) {
      val (views, _) = bound(format, buttons = button("a", "Accept"))
      val outsideY = if (format == "top") views.root.height - 10f else 10f
      assertFalse(format, dispatch(views.root, MotionEvent.ACTION_DOWN, views.root.width / 2f, outsideY))
      val (x, y) = centerOf(views.root, views.body)
      assertTrue(format, dispatch(views.root, MotionEvent.ACTION_DOWN, x, y))
    }
  }

  @Test
  fun `only the first outcome of a display is delivered`() {
    val (views, recorder) = bound("top", buttons = button("a", "Accept"))
    tap(views.root, views.buttons[0])
    tap(views.root, views.buttons[0])
    tap(views.root, views.close)
    drag(views, -px(views.card, 80f))
    assertEquals(listOf("a" to null), recorder.actions)
    assertTrue(recorder.closes.isEmpty())
  }

  // Accessibility

  @Test
  fun `close label comes from the in-code table with an English fallback`() {
    assertEquals("Close", NottiInAppAccessibility.closeLabel(Locale.forLanguageTag("en-US")))
    assertEquals("Fechar", NottiInAppAccessibility.closeLabel(Locale.forLanguageTag("pt-BR")))
    assertEquals("Close", NottiInAppAccessibility.closeLabel(Locale.forLanguageTag("fr-FR")))
    assertEquals("Close", NottiInAppAccessibility.closeLabel(Locale.forLanguageTag("ja")))
  }

  @Test
  fun `close control uses the device language`() {
    RuntimeEnvironment.setQualifiers("pt-rBR")
    val (pt, _) = bound("center")
    assertEquals("Fechar", pt.close.contentDescription)
    RuntimeEnvironment.setQualifiers("de-rDE")
    val (de, _) = bound("center")
    assertEquals("Close", de.close.contentDescription)
  }

  @Test
  fun `buttons announce their label and the Button role, the title is a heading`() {
    val (views, _) = bound("center", buttons = button("a", "Accept") + "," + button("b", "Later"))
    assertEquals("Accept", views.buttons[0].contentDescription)
    assertEquals("Later", views.buttons[1].contentDescription)
    for (view in views.buttons + views.close) {
      assertEquals(Button::class.java.name, view.createAccessibilityNodeInfo().className)
    }
    assertTrue(views.title.isAccessibilityHeading)
  }

  @Test
  fun `card is an accessibility action only when the bar body is tappable`() {
    val (center, _) = bound("center", buttons = button("a", "Accept"))
    assertFalse(center.card.createAccessibilityNodeInfo().isClickable)
    assertEquals(View.IMPORTANT_FOR_ACCESSIBILITY_NO, center.root.importantForAccessibility)
    val (bar, recorder) = bound("top", buttons = button("a", "Accept"))
    assertTrue(bar.card.performAccessibilityAction(AccessibilityNodeInfo.ACTION_CLICK, null))
    assertEquals(listOf("a" to null), recorder.actions)
  }

  @Test
  fun `bar announcement joins title and body`() {
    val (views, _) = bound("top", body = "Hello")
    assertEquals("Title. Hello", NottiInAppAccessibility.announcement(views))
  }

  @Test
  fun `modal hides the host siblings and restores their exact previous values`() {
    val context = activity()
    val container = FrameLayout(context)
    val auto = View(context)
    val yes = View(context).apply { importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_YES }
    val no = View(context).apply { importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO }
    val hidden = View(context).apply { importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS }
    val overlay = NottiInAppViewFactory.build(context, message("center")).root
    listOf(auto, yes, no, hidden, overlay).forEach { container.addView(it) }

    val restore = NottiInAppAccessibility.hideSiblings(container, overlay)
    for (view in listOf(auto, yes, no, hidden)) {
      assertEquals(View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS, view.importantForAccessibility)
    }
    assertEquals(View.IMPORTANT_FOR_ACCESSIBILITY_NO, overlay.importantForAccessibility)

    restore.restore()
    assertEquals(View.IMPORTANT_FOR_ACCESSIBILITY_AUTO, auto.importantForAccessibility)
    assertEquals(View.IMPORTANT_FOR_ACCESSIBILITY_YES, yes.importantForAccessibility)
    assertEquals(View.IMPORTANT_FOR_ACCESSIBILITY_NO, no.importantForAccessibility)
    assertEquals(View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS, hidden.importantForAccessibility)
    // Idempotent: a second restore does not clobber a later host change.
    yes.importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
    restore.restore()
    assertEquals(View.IMPORTANT_FOR_ACCESSIBILITY_NO, yes.importantForAccessibility)
  }

  @Test
  fun `tappable image is reachable with the Button role, a static one stays hidden`() {
    val (tappable, _) = bound("center", bitmap = bitmap(), imageAction = true)
    assertEquals(View.IMPORTANT_FOR_ACCESSIBILITY_YES, tappable.image!!.importantForAccessibility)
    assertEquals(Button::class.java.name, tappable.image!!.createAccessibilityNodeInfo().className)
    val (static, _) = bound("center", bitmap = bitmap())
    assertEquals(View.IMPORTANT_FOR_ACCESSIBILITY_NO, static.image!!.importantForAccessibility)
  }
}
