#if canImport(UIKit)
import UIKit

private enum InAppLayout {
  static let padding: CGFloat = 16
  static let spacing: CGFloat = 8
  static let imageGap: CGFloat = 12
  static let titleBodyGap: CGFloat = 4
  static let buttonTopGap: CGFloat = 12
  static let imageMaxHeight: CGFloat = 180
  static let cornerRadius: CGFloat = 12
  static let buttonCornerRadius: CGFloat = 8
  /// Room kept clear for the close control beside the text.
  static let closeReserve: CGFloat = InAppMetrics.closeTarget - padding
  static let scrimAlpha: CGFloat = 0.4
}

/// Full-size overlay placed over the app. Recomputes the message frame on
/// every layout pass (rotation, resize) from its own size and safe area. Only
/// `center`/`full` take touches; for bars a touch outside the card reaches
/// the app (SDKIAM-17).
final class InAppOverlayView: UIView {

  let format: InAppFormat
  let margin: Bool
  let card: InAppCardView

  /// Replaces the view's own `safeAreaInsets`. Tests set it: a view outside a
  /// window has no safe area.
  var safeAreaOverride: InAppInsets? {
    didSet { setNeedsLayout() }
  }

  private(set) var messageFrame: InAppFrame?

  init(format: InAppFormat, margin: Bool, card: InAppCardView) {
    self.format = format
    self.margin = margin
    self.card = card
    super.init(frame: .zero)
    addSubview(card)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { nil }

  var safeArea: InAppInsets {
    if let override = safeAreaOverride { return override }
    let insets = safeAreaInsets
    return InAppInsets(left: insets.left, top: insets.top, right: insets.right, bottom: insets.bottom)
  }

  override func safeAreaInsetsDidChange() {
    super.safeAreaInsetsDidChange()
    setNeedsLayout()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let computed = computeFrame(
      format: format,
      margin: margin,
      containerWidth: bounds.width,
      containerHeight: bounds.height,
      safe: safeArea
    )
    messageFrame = computed
    let width = computed.width
    let height = computed.gravity == .fill
      ? computed.maxHeight
      : card.fittingHeight(width: width, maxHeight: computed.maxHeight)
    var x = computed.marginLeft
    let y: CGFloat
    switch computed.gravity {
    case .top, .fill:
      y = computed.marginTop
    case .bottom:
      y = bounds.height - computed.marginBottom - height
    case .center:
      // Centered in the safe area, not in the screen: insets can be asymmetric.
      let safeWidth = max(bounds.width - computed.marginLeft - computed.marginRight, 0)
      let safeHeight = max(bounds.height - computed.marginTop - computed.marginBottom, 0)
      x += max((safeWidth - width) / 2, 0)
      y = computed.marginTop + max((safeHeight - height) / 2, 0)
    }
    card.frame = CGRect(x: x, y: y, width: width, height: height)
  }

  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    let hit = super.hitTest(point, with: event)
    if hit === self && (format == .top || format == .bottom) { return nil }
    return hit
  }
}

/// The message card: scrollable content first, buttons below it, never taller
/// than the frame allows, so the buttons stay reachable and the text scrolls
/// (SDKIAM-24). On `full` the content takes all the height and the buttons
/// are pinned to the bottom. The close control sits at the top-trailing corner.
final class InAppCardView: UIView {

  let bar: Bool
  let fill: Bool
  let scroll = UIScrollView()
  let textBlock = UIView()
  let title: UILabel
  let body: UILabel
  let image: UIImageView?
  let buttonRow: InAppButtonRow?
  let close: UIButton

  init(bar: Bool, fill: Bool, title: UILabel, body: UILabel, image: UIImageView?, buttonRow: InAppButtonRow?, close: UIButton) {
    self.bar = bar
    self.fill = fill
    self.title = title
    self.body = body
    self.image = image
    self.buttonRow = buttonRow
    self.close = close
    super.init(frame: .zero)
    textBlock.addSubview(title)
    textBlock.addSubview(body)
    if let image = image { scroll.addSubview(image) }
    scroll.addSubview(textBlock)
    addSubview(scroll)
    if let row = buttonRow { addSubview(row) }
    addSubview(close)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { nil }

  private var rightToLeft: Bool { effectiveUserInterfaceLayoutDirection == .rightToLeft }

  /// Height for `width`, capped at `maxHeight` (the text scrolls beyond it).
  func fittingHeight(width: CGFloat, maxHeight: CGFloat) -> CGFloat {
    let inner = max(width - 2 * InAppLayout.padding, 0)
    return min(2 * InAppLayout.padding + contentHeight(inner) + fixedHeight(inner), maxHeight)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let padding = InAppLayout.padding
    let inner = max(bounds.width - 2 * padding, 0)
    let fixed = fixedHeight(inner)
    let content = contentHeight(inner)
    let available = max(bounds.height - 2 * padding - fixed, 0)
    let scrollHeight = fill ? available : min(content, available)
    scroll.frame = CGRect(x: padding, y: padding, width: inner, height: scrollHeight)
    scroll.contentSize = CGSize(width: inner, height: content)
    layoutContent(inner)
    if let row = buttonRow {
      row.frame = CGRect(
        x: padding,
        y: padding + scrollHeight + InAppLayout.buttonTopGap,
        width: inner,
        height: fixed - InAppLayout.buttonTopGap
      )
    }
    let size = InAppMetrics.closeTarget
    close.frame = CGRect(x: rightToLeft ? 0 : bounds.width - size, y: 0, width: size, height: size)
  }

  private func layoutContent(_ inner: CGFloat) {
    let width = textWidth(inner)
    let height = textHeight(width)
    if bar {
      var leading: CGFloat = 0
      if let image = image {
        let size = InAppMetrics.thumbnail
        image.frame = CGRect(x: rightToLeft ? inner - size : 0, y: 0, width: size, height: size)
        leading = size + InAppLayout.imageGap
      }
      let x = rightToLeft ? inner - leading - width : leading
      textBlock.frame = CGRect(x: x, y: 0, width: width, height: height)
    } else {
      var y: CGFloat = 0
      let imageHeight = imageHeight(inner)
      if let image = image, imageHeight > 0 {
        image.frame = CGRect(x: 0, y: 0, width: inner, height: imageHeight)
        y = imageHeight + InAppLayout.imageGap
      }
      // Without an image the title sits next to the close control: keep it clear.
      let x = rightToLeft && image == nil ? InAppLayout.closeReserve : 0
      textBlock.frame = CGRect(x: x, y: y, width: width, height: height)
    }
    let titleHeight = labelHeight(title, width)
    title.frame = CGRect(x: 0, y: 0, width: width, height: titleHeight)
    let bodyY = titleHeight > 0 && !body.isHidden ? titleHeight + InAppLayout.titleBodyGap : titleHeight
    body.frame = CGRect(x: 0, y: bodyY, width: width, height: labelHeight(body, width))
  }

  private func textWidth(_ inner: CGFloat) -> CGFloat {
    var width = inner
    if bar, image != nil { width -= InAppMetrics.thumbnail + InAppLayout.imageGap }
    if bar || image == nil { width -= InAppLayout.closeReserve }
    return max(width, 0)
  }

  private func labelHeight(_ label: UILabel, _ width: CGFloat) -> CGFloat {
    if label.isHidden { return 0 }
    return ceil(label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
  }

  private func textHeight(_ width: CGFloat) -> CGFloat {
    let titleHeight = labelHeight(title, width)
    let bodyHeight = labelHeight(body, width)
    let gap = titleHeight > 0 && bodyHeight > 0 ? InAppLayout.titleBodyGap : 0
    return titleHeight + gap + bodyHeight
  }

  private func imageHeight(_ inner: CGFloat) -> CGFloat {
    guard !bar, let size = image?.image?.size, size.width > 0 else { return 0 }
    return min(InAppLayout.imageMaxHeight, inner * size.height / size.width)
  }

  private func contentHeight(_ inner: CGFloat) -> CGFloat {
    let text = textHeight(textWidth(inner))
    if bar { return image != nil ? max(InAppMetrics.thumbnail, text) : text }
    let imageHeight = imageHeight(inner)
    return imageHeight > 0 ? imageHeight + InAppLayout.imageGap + text : text
  }

  private func fixedHeight(_ inner: CGFloat) -> CGFloat {
    guard let row = buttonRow else { return 0 }
    return InAppLayout.buttonTopGap + row.height(forWidth: inner)
  }
}

/// Buttons side by side when each fits half the width on one line, else one
/// per row (SDKIAM-23). Measured, never guessed.
final class InAppButtonRow: UIView {

  let buttons: [UIButton]
  private let spacing: CGFloat

  private(set) var stacked = false

  init(buttons: [UIButton], spacing: CGFloat) {
    self.buttons = buttons
    self.spacing = spacing
    super.init(frame: .zero)
    buttons.forEach(addSubview)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { nil }

  private func half(_ width: CGFloat) -> CGFloat {
    (width - spacing * CGFloat(buttons.count - 1)) / CGFloat(max(1, buttons.count))
  }

  private func isStacked(_ width: CGFloat) -> Bool {
    let unbounded = CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
    return buttons.count > 1 && buttons.contains { $0.sizeThatFits(unbounded).width > half(width) }
  }

  private func buttonHeight(_ button: UIButton, _ width: CGFloat) -> CGFloat {
    let fitted = button.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
    return max(InAppMetrics.closeTarget, ceil(fitted))
  }

  func height(forWidth width: CGFloat) -> CGFloat {
    if buttons.count <= 1 || isStacked(width) {
      let heights = buttons.map { buttonHeight($0, width) }
      return heights.reduce(0, +) + spacing * CGFloat(max(0, heights.count - 1))
    }
    // Same height for both, so the row reads as one control group.
    return buttons.map { buttonHeight($0, half(width)) }.max() ?? 0
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let width = bounds.width
    stacked = isStacked(width)
    if buttons.count <= 1 || stacked {
      var y: CGFloat = 0
      for button in buttons {
        let height = buttonHeight(button, width)
        button.frame = CGRect(x: 0, y: y, width: width, height: height)
        y += height + spacing
      }
    } else {
      let itemWidth = half(width)
      let height = bounds.height
      let ordered = effectiveUserInterfaceLayoutDirection == .rightToLeft ? buttons.reversed() : buttons
      for (index, button) in ordered.enumerated() {
        button.frame = CGRect(x: CGFloat(index) * (itemWidth + spacing), y: 0, width: itemWidth, height: height)
      }
    }
  }
}

/// The built tree of one display. Rebuilt on every presentation; holds no state.
struct InAppMessageViews {
  let root: InAppOverlayView
  let card: InAppCardView
  let title: UILabel
  let body: UILabel
  let image: UIImageView?
  let buttons: [UIButton]
  let buttonRow: InAppButtonRow?
  let close: UIButton
  let style: InAppResolvedStyle
}

/// Builds the UIKit views of a message. Text is always plain: the raw string
/// goes to `UILabel.text`, never an HTML or Markdown attributed string, never
/// a web view, and a label detects no links (SDKIAM-31).
enum NottiInAppViewFactory {

  /// `traits` picks the Dynamic Type size of the fonts; the labels then follow
  /// later size changes on their own.
  static func build(_ message: InAppMessage, image: UIImage? = nil, traits: UITraitCollection = .current) -> InAppMessageViews {
    let style = resolveStyle(message.style, buttonCount: message.buttons.count)
    let bar = message.format == .top || message.format == .bottom
    let full = message.format == .full

    let title = plainLabel(message.title, font: UIFont.preferredFont(forTextStyle: .headline, compatibleWith: traits), style: style)
    let body = plainLabel(message.body, font: UIFont.preferredFont(forTextStyle: .subheadline, compatibleWith: traits), style: style)

    let imageView = image.map { loaded -> UIImageView in
      let view = UIImageView(image: loaded)
      view.contentMode = bar ? .scaleAspectFill : .scaleAspectFit
      view.clipsToBounds = true
      view.isAccessibilityElement = false
      return view
    }

    let buttonFont = boldFont(.subheadline, traits)
    let buttons = message.buttons.enumerated().map { index, button in
      makeButton(button.label, look: style.buttons[index], font: buttonFont)
    }
    let buttonRow = buttons.isEmpty ? nil : InAppButtonRow(buttons: buttons, spacing: InAppLayout.spacing)

    let close = makeClose(overImage: imageView != nil && !bar, style: style)

    let card = InAppCardView(
      bar: bar,
      fill: full,
      title: title,
      body: body,
      image: imageView,
      buttonRow: buttonRow,
      close: close
    )
    card.backgroundColor = style.background.uiColor
    card.layer.cornerRadius = full && !style.margin ? 0 : InAppLayout.cornerRadius
    card.layer.cornerCurve = .continuous
    card.clipsToBounds = true

    let root = InAppOverlayView(format: message.format, margin: style.margin, card: card)
    root.backgroundColor = message.format == .center ? InAppColor.backdrop.uiColor : .clear

    return InAppMessageViews(
      root: root,
      card: card,
      title: title,
      body: body,
      image: imageView,
      buttons: buttons,
      buttonRow: buttonRow,
      close: close,
      style: style
    )
  }

  private static func plainLabel(_ value: String, font: UIFont, style: InAppResolvedStyle) -> UILabel {
    let label = UILabel()
    // A String, never an attributed one: rendered verbatim, newlines kept.
    label.text = value
    label.font = font
    label.adjustsFontForContentSizeCategory = true
    label.numberOfLines = 0
    label.lineBreakMode = .byWordWrapping
    label.textColor = style.text.uiColor
    label.textAlignment = textAlignment(style.textAlign)
    label.isHidden = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    return label
  }

  /// Absolute sides: the author picked left or right, not leading or trailing.
  static func textAlignment(_ align: InAppTextAlign) -> NSTextAlignment {
    switch align {
    case .left: return .left
    case .center: return .center
    case .right: return .right
    }
  }

  private static func boldFont(_ style: UIFont.TextStyle, _ traits: UITraitCollection) -> UIFont {
    let base = UIFont.preferredFont(forTextStyle: style, compatibleWith: traits)
    guard let bold = base.fontDescriptor.withSymbolicTraits(.traitBold) else { return base }
    return UIFont(descriptor: bold, size: 0)
  }

  private static func makeButton(_ label: String, look: InAppButtonLook, font: UIFont) -> UIButton {
    var config = UIButton.Configuration.plain()
    config.title = label
    config.titleAlignment = .center
    config.titleLineBreakMode = .byWordWrapping
    config.baseForegroundColor = look.text.uiColor
    config.background.backgroundColor = look.background.uiColor
    config.background.cornerRadius = InAppLayout.buttonCornerRadius
    config.cornerStyle = .fixed
    config.contentInsets = NSDirectionalEdgeInsets(
      top: InAppLayout.spacing,
      leading: InAppLayout.padding,
      bottom: InAppLayout.spacing,
      trailing: InAppLayout.padding
    )
    config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
      var updated = attributes
      updated.font = font
      return updated
    }
    return UIButton(configuration: config)
  }

  private static func makeClose(overImage: Bool, style: InAppResolvedStyle) -> UIButton {
    var config = UIButton.Configuration.plain()
    config.image = UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(textStyle: .subheadline))
    config.baseForegroundColor = overImage ? .white : style.text.uiColor
    if overImage {
      // Scrim chip: the glyph stays legible over any image (SDKIAM-21).
      config.background.backgroundColor = UIColor.black.withAlphaComponent(InAppLayout.scrimAlpha)
      config.cornerStyle = .capsule
    }
    return UIButton(configuration: config)
  }
}
#endif
