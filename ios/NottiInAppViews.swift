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
  /// Keeps the close target (and its scrim chip) fully inside the rounded card corner.
  static let closeInset: CGFloat = 8
  static let closeReserve: CGFloat = InAppMetrics.closeTarget - padding + closeInset
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

  /// Gestures and taps of the display, set by `NottiInAppViewFactory.bind`.
  var interaction: InAppInteraction?

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

  /// VoiceOver's escape gesture acts as the close control on `center`/`full`.
  override func accessibilityPerformEscape() -> Bool {
    guard format == .center || format == .full, let interaction = interaction else { return false }
    interaction.close(InAppDismissReason.closeButton)
    return true
  }
}

/// The message card: scrollable content first, buttons below it, never taller
/// than the frame allows, so the buttons stay reachable and the text scrolls
/// (SDKIAM-24). On `full` the content takes all the height and the buttons
/// are pinned to the bottom. When the buttons alone are taller than the card
/// (a bar in landscape at an accessibility text size), they move into the
/// scroll view after the text, so every one can still be scrolled to and
/// tapped. The close control sits at the top-trailing corner.
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

  /// The buttons do not fit below the scroll view: they scroll with the text.
  private(set) var buttonsScroll = false

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
    let room = max(bounds.height - 2 * padding, 0)
    placeButtons(inScroll: buttonRow != nil && fixed > room)
    let scrollHeight: CGFloat
    if buttonsScroll {
      scrollHeight = room
      scroll.contentSize = CGSize(width: inner, height: content + fixed)
    } else {
      let available = max(room - fixed, 0)
      scrollHeight = fill ? available : min(content, available)
      scroll.contentSize = CGSize(width: inner, height: fill ? max(content, scrollHeight) : content)
    }
    scroll.frame = CGRect(x: padding, y: padding, width: inner, height: scrollHeight)
    layoutContent(inner)
    if let row = buttonRow {
      // In the scroll view the row follows the content, in its coordinates.
      row.frame = CGRect(
        x: buttonsScroll ? 0 : padding,
        y: (buttonsScroll ? content : padding + scrollHeight) + InAppLayout.buttonTopGap,
        width: inner,
        height: fixed - InAppLayout.buttonTopGap
      )
    }
    let size = InAppMetrics.closeTarget
    let inset = InAppLayout.closeInset
    close.frame = CGRect(x: rightToLeft ? inset : bounds.width - size - inset, y: inset, width: size, height: size)
  }

  /// Moves the button row between the card and the scroll view (rotation,
  /// text size change); the close control stays on top.
  private func placeButtons(inScroll: Bool) {
    guard let row = buttonRow else { return }
    let changed = inScroll != buttonsScroll
    buttonsScroll = inScroll
    if inScroll, row.superview !== scroll {
      scroll.addSubview(row)
    } else if !inScroll, row.superview !== self {
      insertSubview(row, belowSubview: close)
    }
    // The content just got shorter or taller: start again from its top.
    if changed { scroll.contentOffset = .zero }
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
      var imageHeight = imageHeight(inner)
      // `full`: the image also takes the room the text leaves free (contained,
      // never cropped). Not when the buttons scroll: they follow the content.
      if fill, !buttonsScroll, image != nil, imageHeight > 0 {
        let free = scroll.bounds.height - InAppLayout.imageGap - height
        imageHeight = max(imageHeight, free)
      }
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

/// Display outcomes reported by the views; the presenter forwards them to the coordinator.
protocol InAppViewListener: AnyObject {
  func onClose(reason: String)
  /// `buttonId` is a button id or `image`; `action` is passed untouched.
  func onAction(buttonId: String, action: InAppAction?)
}

/// Gestures and taps of one display (SDKIAM-22, 33-35). Only the first outcome
/// is delivered: a second tap or a swipe on a closing display is ignored. The
/// recognizers call the handler methods below, which tests call directly.
final class InAppInteraction: NSObject, UIGestureRecognizerDelegate {

  private weak var root: InAppOverlayView?
  private weak var listener: InAppViewListener?
  private let message: InAppMessage
  /// -1 dismisses upward (`top`), 1 downward (`bottom`), 0 has no swipe.
  let dismissDirection: CGFloat
  let imageTappable: Bool

  /// Read on each transition; injected by tests.
  var reduceMotion: () -> Bool = { UIAccessibility.isReduceMotionEnabled }
  var animate: (TimeInterval, @escaping () -> Void) -> Void = { duration, changes in
    UIView.animate(withDuration: duration, animations: changes)
  }

  private(set) var done = false
  private(set) var pan: UIPanGestureRecognizer?
  private(set) var bodyTap: UITapGestureRecognizer?
  private(set) var backdropTap: UITapGestureRecognizer?
  private(set) var imageTap: UITapGestureRecognizer?

  init(root: InAppOverlayView, message: InAppMessage, listener: InAppViewListener) {
    self.root = root
    self.message = message
    self.listener = listener
    switch message.format {
    case .top: dismissDirection = -1
    case .bottom: dismissDirection = 1
    case .center, .full: dismissDirection = 0
    }
    // A failed image is never built, so a tappable image is always a loaded one.
    imageTappable = root.card.image != nil && message.imageAction != nil
    super.init()
  }

  // MARK: Outcomes

  func close(_ reason: String) {
    if done { return }
    done = true
    listener?.onClose(reason: reason)
  }

  func act(_ buttonId: String, _ action: InAppAction?) {
    if done { return }
    done = true
    listener?.onAction(buttonId: buttonId, action: action)
  }

  @objc func handleImageTap() { act(NottiInAppViewFactory.imageButtonId, message.imageAction) }

  /// A bar body tap acts as the first button.
  @objc func handleBodyTap() {
    guard let first = message.buttons.first else { return }
    act(first.id, first.action)
  }

  @objc func handleBackdropTap() { close(InAppDismissReason.outsideTap) }

  @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
    let dy = recognizer.translation(in: root).y
    switch recognizer.state {
    case .changed: panChanged(dy)
    case .ended: panEnded(dy)
    case .cancelled, .failed: settle()
    default: break
    }
  }

  // MARK: Swipe

  /// A third of the bar height, at most the close target (SDKIAM-22).
  var swipeThreshold: CGFloat {
    min((root?.card.bounds.height ?? 0) / 3, InAppMetrics.closeTarget)
  }

  func panChanged(_ dy: CGFloat) {
    guard !done, let card = root?.card else { return }
    let offset = dismissDirection < 0 ? min(0, dy) : max(0, dy)
    card.transform = CGAffineTransform(translationX: 0, y: offset)
  }

  func panEnded(_ dy: CGFloat) {
    if !done && dismissDirection != 0 && dy * dismissDirection >= swipeThreshold {
      close(InAppDismissReason.swipe)
    } else {
      settle()
    }
  }

  /// Snaps the card back, without animation under Reduce Motion.
  func settle() {
    guard let card = root?.card else { return }
    let changes = { card.transform = .identity }
    if reduceMotion() { changes() } else { animate(0.2, changes) }
  }

  /// A drag becomes a swipe when it is mostly vertical, in the dismiss
  /// direction, and the text cannot scroll that way first.
  func startsSwipe(dx: CGFloat, dy: CGFloat) -> Bool {
    guard !done, dismissDirection != 0, abs(dy) > abs(dx), dy * dismissDirection > 0, let scroll = root?.card.scroll else {
      return false
    }
    let maxOffset = max(scroll.contentSize.height - scroll.bounds.height, 0)
    // A finger moving up scrolls the content down, and the other way round.
    let canScroll = dismissDirection < 0 ? scroll.contentOffset.y < maxOffset - 0.5 : scroll.contentOffset.y > 0.5
    return !canScroll
  }

  // MARK: Tap areas

  /// `point` in card coordinates: a body tap outside the card's controls.
  func bodyTapAccepts(_ point: CGPoint) -> Bool {
    guard let card = root?.card else { return false }
    var excluded: [UIView] = [card.close] + (card.buttonRow?.buttons ?? [])
    if imageTappable, let image = card.image { excluded.append(image) }
    return !excluded.contains { view in
      !view.isHidden && view.superview != nil && view.convert(view.bounds, to: card).contains(point)
    }
  }

  /// `point` in overlay coordinates: outside the card.
  func backdropAccepts(_ point: CGPoint) -> Bool {
    guard let card = root?.card else { return false }
    return !card.frame.contains(point)
  }

  // MARK: Wiring

  func install() {
    guard let root = root else { return }
    let card = root.card
    card.close.addAction(UIAction { [weak self] _ in self?.close(InAppDismissReason.closeButton) }, for: .touchUpInside)
    for (index, button) in (card.buttonRow?.buttons ?? []).enumerated() where index < message.buttons.count {
      let model = message.buttons[index]
      button.addAction(UIAction { [weak self] _ in self?.act(model.id, model.action) }, for: .touchUpInside)
    }
    if imageTappable, let image = card.image {
      image.isUserInteractionEnabled = true
      let tap = UITapGestureRecognizer(target: self, action: #selector(handleImageTap))
      image.addGestureRecognizer(tap)
      imageTap = tap
    }
    switch message.format {
    case .top, .bottom:
      let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
      pan.delegate = self
      card.addGestureRecognizer(pan)
      // The text scrolls only once the drag is known not to be a swipe.
      card.scroll.panGestureRecognizer.require(toFail: pan)
      self.pan = pan
      if !message.buttons.isEmpty {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleBodyTap))
        tap.delegate = self
        card.addGestureRecognizer(tap)
        bodyTap = tap
      }
    case .center:
      let tap = UITapGestureRecognizer(target: self, action: #selector(handleBackdropTap))
      tap.delegate = self
      root.addGestureRecognizer(tap)
      backdropTap = tap
    case .full:
      // The close control is the only way out of `full` (A19).
      break
    }
  }

  func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
    guard recognizer === pan, let pan = pan else { return true }
    let velocity = pan.velocity(in: root)
    return startsSwipe(dx: velocity.x, dy: velocity.y)
  }

  func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
    if recognizer === bodyTap, let card = root?.card { return bodyTapAccepts(touch.location(in: card)) }
    if recognizer === backdropTap, let root = root { return backdropAccepts(touch.location(in: root)) }
    return true
  }
}

/// Accessibility of an in-app display (SDKIAM-63). The close label is the only
/// text the SDK owns: an in-code table, no `.strings` file (A18).
enum NottiInAppAccessibility {

  private static let closeEnglish = "Close"
  private static let closeLabels = ["pt": "Fechar"]

  /// Close label for the first preferred language: Portuguese or English, any
  /// other language falls back to English (A18).
  static func closeLabel(languages: [String] = Locale.preferredLanguages) -> String {
    guard let first = languages.first else { return closeEnglish }
    let code = first.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map { String($0).lowercased() } ?? ""
    return closeLabels[code] ?? closeEnglish
  }

  /// Static semantics of a bound display: labels, traits, heading, modality.
  static func apply(_ views: InAppMessageViews, format: InAppFormat, imageTappable: Bool, languages: [String] = Locale.preferredLanguages) {
    views.close.accessibilityLabel = closeLabel(languages: languages)
    views.close.accessibilityTraits = .button
    for button in views.buttons {
      button.accessibilityLabel = button.configuration?.title
      button.accessibilityTraits = .button
    }
    views.title.accessibilityTraits.insert(.header)
    if let image = views.image {
      image.isAccessibilityElement = imageTappable
      if imageTappable {
        // Author text only: the SDK has no string of its own for the image.
        let title = views.title.text ?? ""
        image.accessibilityLabel = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : title
        image.accessibilityTraits = [.button, .image]
      }
    }
    views.root.accessibilityViewIsModal = format == .center || format == .full
  }

  /// Text announced for a bar, which never takes focus away from the app.
  static func announcement(_ views: InAppMessageViews) -> String {
    [views.title, views.body]
      .filter { !$0.isHidden }
      .compactMap { $0.text }
      .joined(separator: ". ")
  }

  /// Called by the presenter once the display is on screen: a bar is
  /// announced, a `center`/`full` message moves the VoiceOver focus to its title.
  static func onShown(
    _ views: InAppMessageViews,
    format: InAppFormat,
    post: (UIAccessibility.Notification, Any?) -> Void = { UIAccessibility.post(notification: $0, argument: $1) }
  ) {
    switch format {
    case .top, .bottom:
      post(.announcement, announcement(views))
    case .center, .full:
      post(.screenChanged, views.title.isHidden ? views.card : views.title)
    }
  }
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
      // The card crops to its 180 pt cap; `full` shows the whole picture in the free area.
      view.contentMode = full ? .scaleAspectFit : .scaleAspectFill
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

  /// `button_id` of an image click (SDKIAM-35).
  static let imageButtonId = "image"

  /// Wires the gestures and taps of `views` to `listener` and sets the
  /// accessibility semantics. The presenter owns the window; nothing here
  /// handles presentation.
  @discardableResult
  static func bind(_ views: InAppMessageViews, message: InAppMessage, listener: InAppViewListener) -> InAppInteraction {
    let interaction = InAppInteraction(root: views.root, message: message, listener: listener)
    views.root.interaction = interaction
    interaction.install()
    NottiInAppAccessibility.apply(views, format: message.format, imageTappable: interaction.imageTappable)
    return interaction
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
