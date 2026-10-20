package com.notti

/**
 * Theme colors read from the Activity theme (`android.R.attr.colorBackground`,
 * `textColorPrimary`, `colorAccent`), each null when the host theme does not
 * define it. [night] comes from `Configuration.uiMode` and picks the fallback.
 */
data class InAppThemeColors(
  val background: Int?,
  val text: Int?,
  val accent: Int?,
  val night: Boolean
)

/** Default colors, all resolved (A13: semantic, never derived from author colors). */
data class InAppPalette(val background: Int, val text: Int, val accent: Int)

enum class InAppButtonKind { FILLED, TINTED }

data class InAppButtonLook(val kind: InAppButtonKind, val background: Int, val text: Int)

/** What the view factory applies. [buttons] has one entry per button, in order. */
data class InAppResolvedStyle(
  val background: Int,
  val text: Int,
  val textAlign: InAppTextAlign,
  val margin: Boolean,
  val buttons: List<InAppButtonLook>
)

object InAppColors {
  const val WHITE = 0xFFFFFFFF.toInt()
  const val LIGHT_BACKGROUND = 0xFFFFFFFF.toInt()
  const val LIGHT_TEXT = 0xFF1C1C1E.toInt()
  const val DARK_BACKGROUND = 0xFF1C1C1E.toInt()
  const val DARK_TEXT = 0xFFF2F2F7.toInt()
  const val ACCENT = 0xFF0A84FF.toInt()

  /** Black at 50%, behind `center`. */
  const val BACKDROP = 0x80000000.toInt()

  /** Alpha of the tinted secondary button background (12%). */
  const val TINT_ALPHA = 0x1F

  fun withAlpha(color: Int, alpha: Int): Int = (color and 0x00FFFFFF) or (alpha shl 24)
}

/** Theme value when defined, else the documented constant for the light/dark mode. */
fun resolvePalette(theme: InAppThemeColors): InAppPalette = InAppPalette(
  background = theme.background ?: if (theme.night) InAppColors.DARK_BACKGROUND else InAppColors.LIGHT_BACKGROUND,
  text = theme.text ?: if (theme.night) InAppColors.DARK_TEXT else InAppColors.LIGHT_TEXT,
  accent = theme.accent ?: InAppColors.ACCENT
)

/**
 * Applies the author's tokens over [palette]. Each token falls back on its own
 * (an invalid or absent one was already parsed to null); no color is derived
 * from another (DD-12). A button token applies to every button (SDKIAM-29).
 */
fun resolveStyle(style: InAppStyle, palette: InAppPalette, buttonCount: Int): InAppResolvedStyle {
  val authorButtons = style.buttonColor != null || style.buttonTextColor != null
  val buttons = (0 until buttonCount).map { index ->
    when {
      authorButtons -> InAppButtonLook(
        InAppButtonKind.FILLED,
        style.buttonColor ?: palette.accent,
        style.buttonTextColor ?: InAppColors.WHITE
      )
      index == 0 -> InAppButtonLook(InAppButtonKind.FILLED, palette.accent, InAppColors.WHITE)
      else -> InAppButtonLook(
        InAppButtonKind.TINTED,
        InAppColors.withAlpha(palette.text, InAppColors.TINT_ALPHA),
        palette.text
      )
    }
  }
  return InAppResolvedStyle(
    background = style.backgroundColor ?: palette.background,
    text = style.textColor ?: palette.text,
    textAlign = style.textAlign,
    margin = style.margin,
    buttons = buttons
  )
}

/** System bars + display cutout, in dp. */
data class InAppInsets(val left: Float, val top: Float, val right: Float, val bottom: Float) {
  companion object {
    val ZERO = InAppInsets(0f, 0f, 0f, 0f)
  }
}

enum class InAppGravity { TOP, BOTTOM, CENTER, FILL }

/**
 * Where the message goes in a container, in dp. The margins are distances
 * from the container edges (safe area included); a [InAppGravity.CENTER]
 * card is centered inside them. Height grows with content up to [maxHeight].
 */
data class InAppFrame(
  val gravity: InAppGravity,
  val marginLeft: Float,
  val marginTop: Float,
  val marginRight: Float,
  val marginBottom: Float,
  val width: Float,
  val maxHeight: Float
)

object InAppMetrics {
  const val MARGIN_DP = 16f
  const val BAR_MAX_HEIGHT_FRACTION = 0.4f
  const val CARD_MAX_WIDTH_FRACTION = 0.9f
  const val CARD_MAX_WIDTH_DP = 560f
  const val CARD_MAX_HEIGHT_FRACTION = 0.9f
  const val CLOSE_TARGET_DP = 48f
  const val THUMBNAIL_DP = 56f
}

/**
 * Bounds per layout (design "Layout and style"). The 16 dp margin is measured
 * from the safe-area edge; without it the message touches the safe-area edges
 * on every side and never goes under system UI (A12). `center` ignores it.
 */
fun computeFrame(
  format: InAppFormat,
  margin: Boolean,
  containerWidth: Float,
  containerHeight: Float,
  safe: InAppInsets
): InAppFrame {
  val m = if (margin) InAppMetrics.MARGIN_DP else 0f
  val safeWidth = (containerWidth - safe.left - safe.right).coerceAtLeast(0f)
  val safeHeight = (containerHeight - safe.top - safe.bottom).coerceAtLeast(0f)
  return when (format) {
    InAppFormat.TOP, InAppFormat.BOTTOM -> InAppFrame(
      gravity = if (format == InAppFormat.TOP) InAppGravity.TOP else InAppGravity.BOTTOM,
      marginLeft = safe.left + m,
      marginTop = safe.top + m,
      marginRight = safe.right + m,
      marginBottom = safe.bottom + m,
      width = (safeWidth - 2 * m).coerceAtLeast(0f),
      maxHeight = minOf(
        containerHeight * InAppMetrics.BAR_MAX_HEIGHT_FRACTION,
        (safeHeight - 2 * m).coerceAtLeast(0f)
      )
    )
    InAppFormat.CENTER -> InAppFrame(
      gravity = InAppGravity.CENTER,
      marginLeft = safe.left,
      marginTop = safe.top,
      marginRight = safe.right,
      marginBottom = safe.bottom,
      width = minOf(containerWidth * InAppMetrics.CARD_MAX_WIDTH_FRACTION, InAppMetrics.CARD_MAX_WIDTH_DP, safeWidth),
      maxHeight = safeHeight * InAppMetrics.CARD_MAX_HEIGHT_FRACTION
    )
    InAppFormat.FULL -> InAppFrame(
      gravity = InAppGravity.FILL,
      marginLeft = safe.left + m,
      marginTop = safe.top + m,
      marginRight = safe.right + m,
      marginBottom = safe.bottom + m,
      width = (safeWidth - 2 * m).coerceAtLeast(0f),
      maxHeight = (safeHeight - 2 * m).coerceAtLeast(0f)
    )
  }
}
