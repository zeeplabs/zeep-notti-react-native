import CoreGraphics
#if canImport(UIKit)
import UIKit
#endif

/// A color the view applies: either an author token (opaque `0xFFRRGGBB`,
/// fixed in both themes) or a semantic system color that follows light/dark
/// on its own (A13). Never computed from another color (DD-12).
enum InAppColor: Equatable {
  case author(UInt32)
  /// `secondarySystemBackground`
  case background
  /// `label`
  case text
  /// `systemBlue`
  case accent
  /// `white`, the label of a filled button without `button_text_color`.
  case white
  /// `tertiarySystemFill`, the tinted secondary button background.
  case secondaryFill
  /// Black at 50%, behind `center`.
  case backdrop
}

#if canImport(UIKit)
extension InAppColor {
  var uiColor: UIColor {
    switch self {
    case .author(let argb):
      return UIColor(
        red: CGFloat((argb >> 16) & 0xFF) / 255,
        green: CGFloat((argb >> 8) & 0xFF) / 255,
        blue: CGFloat(argb & 0xFF) / 255,
        alpha: 1
      )
    case .background: return .secondarySystemBackground
    case .text: return .label
    case .accent: return .systemBlue
    case .white: return .white
    case .secondaryFill: return .tertiarySystemFill
    case .backdrop: return UIColor.black.withAlphaComponent(0.5)
    }
  }
}
#endif

enum InAppButtonKind: Equatable {
  case filled
  case tinted
}

struct InAppButtonLook: Equatable {
  let kind: InAppButtonKind
  let background: InAppColor
  let text: InAppColor
}

/// What the views apply. `buttons` has one entry per button, in order.
struct InAppResolvedStyle: Equatable {
  let background: InAppColor
  let text: InAppColor
  let textAlign: InAppTextAlign
  let margin: Bool
  let buttons: [InAppButtonLook]
}

/// Applies the author's tokens over the semantic defaults. Each token falls
/// back on its own (an invalid or absent one was already parsed to `nil`); no
/// color is derived from another (DD-12). A button token applies to every
/// button (SDKIAM-29).
func resolveStyle(_ style: InAppStyle, buttonCount: Int) -> InAppResolvedStyle {
  let authorButtons = style.buttonColor != nil || style.buttonTextColor != nil
  let buttons = (0..<max(0, buttonCount)).map { index -> InAppButtonLook in
    if authorButtons {
      return InAppButtonLook(
        kind: .filled,
        background: style.buttonColor.map(InAppColor.author) ?? .accent,
        text: style.buttonTextColor.map(InAppColor.author) ?? .white
      )
    }
    if index == 0 {
      return InAppButtonLook(kind: .filled, background: .accent, text: .white)
    }
    return InAppButtonLook(kind: .tinted, background: .secondaryFill, text: .text)
  }
  return InAppResolvedStyle(
    background: style.backgroundColor.map(InAppColor.author) ?? .background,
    text: style.textColor.map(InAppColor.author) ?? .text,
    textAlign: style.textAlign,
    margin: style.margin,
    buttons: buttons
  )
}

/// The window's safe-area insets (notch/Dynamic Island, home indicator,
/// landscape sides), in points.
struct InAppInsets: Equatable {
  let left: CGFloat
  let top: CGFloat
  let right: CGFloat
  let bottom: CGFloat

  static let zero = InAppInsets(left: 0, top: 0, right: 0, bottom: 0)
}

enum InAppGravity: Equatable {
  case top
  case bottom
  case center
  case fill
}

/// Where the message goes in a container, in points. The margins are
/// distances from the container edges (safe area included); a `.center` card
/// is centered inside them. Height grows with content up to `maxHeight`.
struct InAppFrame: Equatable {
  let gravity: InAppGravity
  let marginLeft: CGFloat
  let marginTop: CGFloat
  let marginRight: CGFloat
  let marginBottom: CGFloat
  let width: CGFloat
  let maxHeight: CGFloat
}

enum InAppMetrics {
  static let margin: CGFloat = 16
  static let barMaxHeightFraction: CGFloat = 0.4
  static let cardMaxWidthFraction: CGFloat = 0.9
  static let cardMaxWidth: CGFloat = 560
  static let cardMaxHeightFraction: CGFloat = 0.9
  static let closeTarget: CGFloat = 44
  static let thumbnail: CGFloat = 56
}

/// Bounds per layout (design "Layout and style"). The 16 pt margin is measured
/// from the safe-area edge; without it the message touches the safe-area edges
/// on every side and never goes under the notch, Dynamic Island or home
/// indicator (A12). `center` ignores it.
func computeFrame(
  format: InAppFormat,
  margin: Bool,
  containerWidth: CGFloat,
  containerHeight: CGFloat,
  safe: InAppInsets
) -> InAppFrame {
  let m: CGFloat = margin ? InAppMetrics.margin : 0
  let safeWidth = max(containerWidth - safe.left - safe.right, 0)
  let safeHeight = max(containerHeight - safe.top - safe.bottom, 0)
  switch format {
  case .top, .bottom:
    return InAppFrame(
      gravity: format == .top ? .top : .bottom,
      marginLeft: safe.left + m,
      marginTop: safe.top + m,
      marginRight: safe.right + m,
      marginBottom: safe.bottom + m,
      width: max(safeWidth - 2 * m, 0),
      maxHeight: min(containerHeight * InAppMetrics.barMaxHeightFraction, max(safeHeight - 2 * m, 0))
    )
  case .center:
    return InAppFrame(
      gravity: .center,
      marginLeft: safe.left,
      marginTop: safe.top,
      marginRight: safe.right,
      marginBottom: safe.bottom,
      width: min(containerWidth * InAppMetrics.cardMaxWidthFraction, InAppMetrics.cardMaxWidth, safeWidth),
      maxHeight: safeHeight * InAppMetrics.cardMaxHeightFraction
    )
  case .full:
    return InAppFrame(
      gravity: .fill,
      marginLeft: safe.left + m,
      marginTop: safe.top + m,
      marginRight: safe.right + m,
      marginBottom: safe.bottom + m,
      width: max(safeWidth - 2 * m, 0),
      maxHeight: max(safeHeight - 2 * m, 0)
    )
  }
}
