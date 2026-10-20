package com.notti

import android.content.Context
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.WindowInsets
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import kotlin.math.max
import kotlin.math.min

/** Reads the default colors from the Activity theme; undefined attributes stay null (A13). */
fun readThemeColors(context: Context): InAppThemeColors {
  val night = (context.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) ==
    Configuration.UI_MODE_NIGHT_YES
  return InAppThemeColors(
    background = themeColor(context, android.R.attr.colorBackground),
    text = themeColor(context, android.R.attr.textColorPrimary),
    accent = themeColor(context, android.R.attr.colorAccent),
    night = night
  )
}

private fun themeColor(context: Context, attr: Int): Int? {
  val array = context.obtainStyledAttributes(intArrayOf(attr))
  return try {
    if (array.hasValue(0)) array.getColorStateList(0)?.defaultColor else null
  } catch (e: Exception) {
    null
  } finally {
    array.recycle()
  }
}

/** System bars + display cutout of [insets], in dp. */
@Suppress("DEPRECATION")
internal fun safeAreaOf(insets: WindowInsets, density: Float): InAppInsets {
  val left: Int
  val top: Int
  val right: Int
  val bottom: Int
  if (Build.VERSION.SDK_INT >= 30) {
    val bars = insets.getInsets(WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout())
    left = bars.left
    top = bars.top
    right = bars.right
    bottom = bars.bottom
  } else {
    val cutout = if (Build.VERSION.SDK_INT >= 28) insets.displayCutout else null
    left = max(insets.systemWindowInsetLeft, cutout?.safeInsetLeft ?: 0)
    top = max(insets.systemWindowInsetTop, cutout?.safeInsetTop ?: 0)
    right = max(insets.systemWindowInsetRight, cutout?.safeInsetRight ?: 0)
    bottom = max(insets.systemWindowInsetBottom, cutout?.safeInsetBottom ?: 0)
  }
  return InAppInsets(left / density, top / density, right / density, bottom / density)
}

/**
 * Full-size overlay added over the Activity content. Recomputes the message
 * frame on every measure (rotation, resize) from its own size and the last
 * safe area it received. Only `center`/`full` consume touches; for bars a
 * touch outside the card reaches the app (SDKIAM-17).
 */
class InAppOverlayLayout internal constructor(
  context: Context,
  private val format: InAppFormat,
  private val margin: Boolean
) : FrameLayout(context) {

  internal lateinit var card: FrameLayout
  internal lateinit var column: InAppColumnLayout

  var safeArea: InAppInsets = InAppInsets.ZERO
    set(value) {
      field = value
      requestLayout()
    }

  var frame: InAppFrame? = null
    private set

  override fun onApplyWindowInsets(insets: WindowInsets): WindowInsets {
    safeArea = safeAreaOf(insets, resources.displayMetrics.density)
    return insets
  }

  override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
    val density = resources.displayMetrics.density
    val width = MeasureSpec.getSize(widthMeasureSpec)
    val height = MeasureSpec.getSize(heightMeasureSpec)
    val computed = computeFrame(format, margin, width / density, height / density, safeArea)
    frame = computed
    val params = card.layoutParams as LayoutParams
    // Absolute LEFT placement: FrameLayout's CENTER_HORIZONTAL would shift the
    // card by the whole left/right margin difference on asymmetric insets.
    params.gravity = when (computed.gravity) {
      InAppGravity.TOP -> Gravity.TOP or Gravity.LEFT
      InAppGravity.BOTTOM -> Gravity.BOTTOM or Gravity.LEFT
      InAppGravity.CENTER -> Gravity.CENTER_VERTICAL or Gravity.LEFT
      InAppGravity.FILL -> Gravity.TOP or Gravity.LEFT
    }
    params.width = (computed.width * density).toInt()
    params.rightMargin = 0
    if (computed.gravity == InAppGravity.CENTER) {
      // Centered in the safe area: FrameLayout adds (top - bottom) margin to the
      // centered position, so half the inset difference goes on one side only.
      val safeWidthPx = width - ((computed.marginLeft + computed.marginRight) * density).toInt()
      params.leftMargin = (computed.marginLeft * density).toInt() + max(0, (safeWidthPx - params.width) / 2)
      val shift = ((computed.marginTop - computed.marginBottom) * density / 2).toInt()
      params.topMargin = max(0, shift)
      params.bottomMargin = max(0, -shift)
    } else {
      params.leftMargin = (computed.marginLeft * density).toInt()
      params.topMargin = (computed.marginTop * density).toInt()
      params.bottomMargin = (computed.marginBottom * density).toInt()
    }
    params.height = if (computed.gravity == InAppGravity.FILL) {
      (computed.maxHeight * density).toInt()
    } else {
      LayoutParams.WRAP_CONTENT
    }
    column.maxHeightPx = (computed.maxHeight * density).toInt()
    super.onMeasure(widthMeasureSpec, heightMeasureSpec)
  }
}

/**
 * Scrollable content first, fixed part (buttons) below it, never taller than
 * [maxHeightPx]: the buttons stay reachable and the text scrolls
 * (SDKIAM-24). With [fill] the content takes all the height, so the buttons
 * are pinned to the bottom (`full`).
 */
class InAppColumnLayout internal constructor(context: Context, private val fill: Boolean) : ViewGroup(context) {

  var maxHeightPx: Int = Int.MAX_VALUE

  override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
    val width = MeasureSpec.getSize(widthMeasureSpec)
    var limit = maxHeightPx
    if (MeasureSpec.getMode(heightMeasureSpec) != MeasureSpec.UNSPECIFIED) {
      limit = min(limit, MeasureSpec.getSize(heightMeasureSpec))
    }
    val innerWidth = max(0, width - paddingLeft - paddingRight)
    val exactWidth = MeasureSpec.makeMeasureSpec(innerWidth, MeasureSpec.EXACTLY)
    var fixedHeight = 0
    for (i in 1 until childCount) {
      val child = getChildAt(i)
      if (child.visibility == GONE) continue
      child.measure(exactWidth, MeasureSpec.makeMeasureSpec(0, MeasureSpec.UNSPECIFIED))
      fixedHeight += child.measuredHeight
    }
    val available = max(0, limit - paddingTop - paddingBottom - fixedHeight)
    val content = getChildAt(0)
    content.measure(
      exactWidth,
      MeasureSpec.makeMeasureSpec(available, if (fill) MeasureSpec.EXACTLY else MeasureSpec.AT_MOST)
    )
    val total = paddingTop + paddingBottom + content.measuredHeight + fixedHeight
    setMeasuredDimension(width, total)
  }

  override fun onLayout(changed: Boolean, l: Int, t: Int, r: Int, b: Int) {
    var y = paddingTop
    for (i in 0 until childCount) {
      val child = getChildAt(i)
      if (child.visibility == GONE) continue
      child.layout(paddingLeft, y, paddingLeft + child.measuredWidth, y + child.measuredHeight)
      y += child.measuredHeight
    }
  }
}

/**
 * Buttons side by side when each fits half the width on one line, else one
 * per row (SDKIAM-23). Measured, never guessed.
 */
class InAppButtonRow internal constructor(context: Context, private val spacingPx: Int) : ViewGroup(context) {

  var stacked: Boolean = false
    private set

  override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
    val width = MeasureSpec.getSize(widthMeasureSpec)
    val unspecified = MeasureSpec.makeMeasureSpec(0, MeasureSpec.UNSPECIFIED)
    val half = (width - spacingPx * (childCount - 1)) / max(1, childCount)
    stacked = childCount > 1 && (0 until childCount).any {
      val child = getChildAt(it)
      child.measure(unspecified, unspecified)
      child.measuredWidth > half
    }
    var height = 0
    if (stacked || childCount == 1) {
      for (i in 0 until childCount) {
        val child = getChildAt(i)
        child.measure(MeasureSpec.makeMeasureSpec(width, MeasureSpec.EXACTLY), unspecified)
        height += child.measuredHeight + if (i > 0) spacingPx else 0
      }
    } else {
      for (i in 0 until childCount) {
        val child = getChildAt(i)
        child.measure(MeasureSpec.makeMeasureSpec(half, MeasureSpec.EXACTLY), unspecified)
        height = max(height, child.measuredHeight)
      }
      // Same height for both, so the row reads as one control group.
      for (i in 0 until childCount) {
        val child = getChildAt(i)
        child.measure(
          MeasureSpec.makeMeasureSpec(half, MeasureSpec.EXACTLY),
          MeasureSpec.makeMeasureSpec(height, MeasureSpec.EXACTLY)
        )
      }
    }
    setMeasuredDimension(width, height)
  }

  override fun onLayout(changed: Boolean, l: Int, t: Int, r: Int, b: Int) {
    var x = 0
    var y = 0
    for (i in 0 until childCount) {
      val child = getChildAt(i)
      child.layout(x, y, x + child.measuredWidth, y + child.measuredHeight)
      if (stacked || childCount == 1) y += child.measuredHeight + spacingPx else x += child.measuredWidth + spacingPx
    }
  }
}

/** The built tree of one display. Rebuilt on every attach; holds no state. */
class InAppMessageViews internal constructor(
  val root: InAppOverlayLayout,
  val card: FrameLayout,
  val title: TextView,
  val body: TextView,
  val image: ImageView?,
  val buttons: List<TextView>,
  val buttonRow: InAppButtonRow?,
  val close: TextView,
  val style: InAppResolvedStyle
)

/**
 * Builds the native views of a message (static rendering only: interactions
 * and accessibility are attached by the presenter). Text is always plain:
 * the raw string goes to `setText`, no HTML, no links, no spans (SDKIAM-31).
 */
object NottiInAppViewFactory {

  private const val TITLE_SP = 17f
  private const val BODY_SP = 15f
  private const val BUTTON_SP = 15f
  private const val CORNER_DP = 12f
  private const val BUTTON_CORNER_DP = 8f
  private const val PADDING_DP = 16f
  private const val SPACING_DP = 8f
  private const val ELEVATION_DP = 6f
  private const val IMAGE_MAX_HEIGHT_DP = 180f
  private const val CLOSE_GLYPH = "✕"
  private const val SCRIM = 0x66000000

  fun build(context: Context, message: InAppMessage, image: Bitmap? = null): InAppMessageViews {
    val style = resolveStyle(message.style, resolvePalette(readThemeColors(context)), message.buttons.size)
    val density = context.resources.displayMetrics.density
    fun px(dp: Float) = (dp * density + 0.5f).toInt()
    val bar = message.format == InAppFormat.TOP || message.format == InAppFormat.BOTTOM
    val full = message.format == InAppFormat.FULL

    val root = InAppOverlayLayout(context, message.format, style.margin)
    root.layoutParams = ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
    when (message.format) {
      InAppFormat.CENTER -> {
        root.setBackgroundColor(InAppColors.BACKDROP)
        root.isClickable = true
      }
      InAppFormat.FULL -> root.isClickable = true
      else -> Unit
    }

    val card = FrameLayout(context).apply {
      background = GradientDrawable().apply {
        setColor(style.background)
        cornerRadius = if (full && !style.margin) 0f else CORNER_DP * density
      }
      elevation = ELEVATION_DP * density
      clipToOutline = true
      isClickable = true
    }
    root.addView(card, FrameLayout.LayoutParams(FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT))
    root.card = card

    val column = InAppColumnLayout(context, fill = full).apply {
      val p = px(PADDING_DP)
      setPadding(p, p, p, p)
    }
    root.column = column
    card.addView(column, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.WRAP_CONTENT))

    val title = plainText(context, message.title, TITLE_SP, style).apply {
      setTypeface(typeface, Typeface.BOLD)
      visibility = if (message.title.isBlank()) View.GONE else View.VISIBLE
    }
    val body = plainText(context, message.body, BODY_SP, style).apply {
      visibility = if (message.body.isBlank()) View.GONE else View.VISIBLE
    }
    val textBlock = LinearLayout(context).apply {
      orientation = LinearLayout.VERTICAL
      addView(title)
      addView(body)
    }

    val imageView = image?.let { bitmap ->
      ImageView(context).apply {
        setImageBitmap(bitmap)
        importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
      }
    }

    val scrollContent = LinearLayout(context).apply { orientation = if (bar) LinearLayout.HORIZONTAL else LinearLayout.VERTICAL }
    val closeReserve = px(InAppMetrics.CLOSE_TARGET_DP - PADDING_DP)
    if (bar) {
      imageView?.let {
        it.scaleType = ImageView.ScaleType.CENTER_CROP
        scrollContent.addView(
          it,
          LinearLayout.LayoutParams(px(InAppMetrics.THUMBNAIL_DP), px(InAppMetrics.THUMBNAIL_DP)).apply { marginEnd = px(12f) }
        )
      }
      textBlock.setPaddingRelative(0, 0, closeReserve, 0)
      scrollContent.addView(textBlock, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
    } else {
      imageView?.let {
        it.adjustViewBounds = true
        it.maxHeight = px(IMAGE_MAX_HEIGHT_DP)
        it.scaleType = ImageView.ScaleType.FIT_CENTER
        scrollContent.addView(
          it,
          LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
            bottomMargin = px(12f)
          }
        )
      }
      // Without an image the title sits next to the close control: keep it clear.
      if (imageView == null) textBlock.setPaddingRelative(0, 0, closeReserve, 0)
      scrollContent.addView(textBlock, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT))
    }
    val scroll = ScrollView(context).apply {
      isFillViewport = false
      addView(scrollContent)
    }
    column.addView(scroll)

    val buttonViews = message.buttons.mapIndexed { index, button ->
      val look = style.buttons[index]
      TextView(context).apply {
        text = button.label
        setTextSize(TypedValue.COMPLEX_UNIT_SP, BUTTON_SP)
        setTypeface(typeface, Typeface.BOLD)
        setTextColor(look.text)
        gravity = Gravity.CENTER
        isAllCaps = false
        autoLinkMask = 0
        minHeight = px(InAppMetrics.CLOSE_TARGET_DP)
        setPadding(px(PADDING_DP), px(SPACING_DP), px(PADDING_DP), px(SPACING_DP))
        background = GradientDrawable().apply {
          setColor(look.background)
          cornerRadius = BUTTON_CORNER_DP * density
        }
        isClickable = true
        isFocusable = true
      }
    }
    val buttonRow = if (buttonViews.isEmpty()) null else InAppButtonRow(context, px(SPACING_DP)).apply {
      setPadding(0, px(12f), 0, 0)
      buttonViews.forEach { addView(it) }
    }
    buttonRow?.let { column.addView(it) }

    val overImage = imageView != null && !bar
    val close = TextView(context).apply {
      text = CLOSE_GLYPH
      gravity = Gravity.CENTER
      setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
      setTextColor(if (overImage) InAppColors.WHITE else style.text)
      minWidth = px(InAppMetrics.CLOSE_TARGET_DP)
      minHeight = px(InAppMetrics.CLOSE_TARGET_DP)
      if (overImage) {
        // Scrim chip: the glyph stays legible over any image (SDKIAM-21).
        background = GradientDrawable().apply {
          shape = GradientDrawable.OVAL
          setColor(SCRIM)
        }
      }
      isClickable = true
      isFocusable = true
    }
    val closeSize = px(InAppMetrics.CLOSE_TARGET_DP)
    card.addView(close, FrameLayout.LayoutParams(closeSize, closeSize, Gravity.TOP or Gravity.END))

    return InAppMessageViews(root, card, title, body, imageView, buttonViews, buttonRow, close, style)
  }

  private fun plainText(context: Context, value: String, sizeSp: Float, style: InAppResolvedStyle): TextView =
    TextView(context).apply {
      autoLinkMask = 0
      linksClickable = false
      movementMethod = null
      setTextIsSelectable(false)
      // A String, never a Spanned: rendered verbatim, newlines kept.
      text = value
      setTextSize(TypedValue.COMPLEX_UNIT_SP, sizeSp)
      setTextColor(style.text)
      gravity = when (style.textAlign) {
        // Absolute sides: the author picked left or right, not start or end.
        InAppTextAlign.LEFT -> Gravity.LEFT
        InAppTextAlign.CENTER -> Gravity.CENTER_HORIZONTAL
        InAppTextAlign.RIGHT -> Gravity.RIGHT
      }
      textAlignment = View.TEXT_ALIGNMENT_GRAVITY
    }
}
