import XCTest
#if canImport(UIKit)
import UIKit
#endif
// Test target compiles the SDK's Swift sources directly (see NottiTests
// Xcode target: ios/*.swift + ios/Tests/*.swift, no CocoaPods module
// dependency) — no import of a "Notti" module needed or possible here.

#if canImport(UIKit)
/// Mirror of `NottiInAppViewFactoryTest.kt` (T8 cases): views laid out in a
/// plain `UIView` with an injected safe area, real text measurement.
final class NottiInAppViewsTests: XCTestCase {

  private let insets = InAppInsets(left: 12, top: 59, right: 20, bottom: 34)
  private let longBody = (1...200).map { "Line \($0) of a long body" }.joined(separator: "\n")
  private let largest = UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)
  private let regular = UITraitCollection(preferredContentSizeCategory: .large)

  private typealias Size = (width: CGFloat, height: CGFloat)
  private let screens: [Size] = [(393, 852), (852, 393), (1024, 1366), (1366, 1024)]

  private func quote(_ value: String) -> String {
    let data = try! JSONSerialization.data(withJSONObject: [value], options: [.fragmentsAllowed])
    let array = String(decoding: data, as: UTF8.self)
    return String(array.dropFirst().dropLast())
  }

  private func message(
    _ format: String,
    title: String = "Title",
    body: String = "Body",
    style: String? = nil,
    buttons: [(String, String)] = [],
    image: Bool = false
  ) -> InAppMessage {
    var fields = [
      #""id":"m""#,
      #""format":"\#(format)""#,
      #""title":\#(quote(title))"#,
      #""body":\#(quote(body))"#,
      #""trigger":{"type":"session_start"}"#,
    ]
    if let style = style { fields.append(#""style":\#(style)"#) }
    if image { fields.append(#""image_url":"https://img.test/a.png""#) }
    if !buttons.isEmpty {
      let list = buttons.map { #"{"id":"\#($0.0)","label":\#(quote($0.1))}"# }.joined(separator: ",")
      fields.append(#""buttons":[\#(list)]"#)
    }
    let raw = #"{"messages":[{\#(fields.joined(separator: ","))}]}"#
    return parseEligibleResponse(Data(raw.utf8))!.first!
  }

  private func build(_ message: InAppMessage, image: UIImage? = nil, traits: UITraitCollection? = nil) -> InAppMessageViews {
    NottiInAppViewFactory.build(message, image: image, traits: traits ?? regular)
  }

  private func layout(_ views: InAppMessageViews, _ size: Size, safe: InAppInsets? = nil) {
    views.root.safeAreaOverride = safe ?? insets
    views.root.frame = CGRect(x: 0, y: 0, width: size.width, height: size.height)
    views.root.layoutIfNeeded()
    views.card.layoutIfNeeded()
    views.buttonRow?.layoutIfNeeded()
  }

  /// Mac Catalyst ignores `preferredContentSizeCategory` (fonts keep their
  /// default size), so Dynamic Type assertions only run on iOS.
  private func requireDynamicType() throws {
    #if targetEnvironment(macCatalyst)
    throw XCTSkip("Dynamic Type sizes are not applied under Mac Catalyst")
    #endif
  }

  private func picture() -> UIImage {
    UIGraphicsImageRenderer(size: CGSize(width: 120, height: 80)).image { context in
      UIColor.red.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
    }
  }

  private func resolved(_ color: UIColor?, _ style: UIUserInterfaceStyle) -> UIColor? {
    color?.resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
  }

  // MARK: Bounds

  func testEveryLayoutRespectsItsBoundsAcrossSizesAndTextSizes() {
    for screen in screens {
      for traits in [regular, largest] {
        for format in ["top", "bottom", "center", "full"] {
          let views = build(message(format, body: longBody, buttons: [("a", "Accept"), ("b", "Later")]), traits: traits)
          layout(views, screen)
          let label = "\(screen) \(traits.preferredContentSizeCategory.rawValue) \(format)"
          let card = views.card.frame
          let safeHeight = screen.height - insets.top - insets.bottom
          switch format {
          case "top", "bottom":
            XCTAssertLessThanOrEqual(card.height, screen.height * 0.4 + 0.5, label)
            XCTAssertEqual(card.width, screen.width - insets.left - insets.right - 32, accuracy: 0.5, label)
          case "center":
            XCTAssertLessThanOrEqual(card.width, min(screen.width * 0.9, 560) + 0.5, label)
            XCTAssertLessThanOrEqual(card.height, safeHeight * 0.9 + 0.5, label)
          default:
            XCTAssertEqual(card.width, screen.width - insets.left - insets.right - 32, accuracy: 0.5, label)
            XCTAssertEqual(card.height, safeHeight - 32, accuracy: 0.5, label)
          }
          // Buttons and close control stay inside the card: the body scrolls instead.
          for button in views.buttons {
            let inCard = views.buttonRow!.convert(button.frame, to: views.card)
            XCTAssertGreaterThan(inCard.height, 0, label)
            XCTAssertLessThanOrEqual(inCard.maxY, views.card.bounds.height + 0.5, label)
          }
          XCTAssertGreaterThanOrEqual(views.close.frame.width, 44, label)
          XCTAssertGreaterThanOrEqual(views.close.frame.height, 44, label)
          XCTAssertFalse(views.close.isHidden, label)
          XCTAssertGreaterThan(views.card.scroll.contentSize.height, views.card.scroll.frame.height, label)
        }
      }
    }
  }

  func testBarsWithMarginSit16InsideTheSafeArea() {
    let top = build(message("top"))
    layout(top, (393, 852))
    XCTAssertEqual(top.card.frame.minX, 28, accuracy: 0.5)
    XCTAssertEqual(top.card.frame.minY, 75, accuracy: 0.5)
    XCTAssertEqual(top.card.frame.maxX, 393 - 36, accuracy: 0.5)

    let bottom = build(message("bottom"))
    layout(bottom, (393, 852))
    XCTAssertEqual(bottom.card.frame.maxY, 852 - 50, accuracy: 0.5)
  }

  func testMarginFalseTouchesTheSafeAreaEdgesOnEverySideNeverTheScreenEdge() {
    let noMargin = #"{"margin":false}"#
    let top = build(message("top", style: noMargin))
    layout(top, (852, 393))
    XCTAssertEqual(top.card.frame.minX, 12, accuracy: 0.5)
    XCTAssertEqual(top.card.frame.minY, 59, accuracy: 0.5)
    XCTAssertEqual(top.card.frame.maxX, 852 - 20, accuracy: 0.5)

    let bottom = build(message("bottom", style: noMargin))
    layout(bottom, (852, 393))
    XCTAssertEqual(bottom.card.frame.maxY, 393 - 34, accuracy: 0.5)
    XCTAssertEqual(bottom.card.frame.minX, 12, accuracy: 0.5)

    let full = build(message("full", style: noMargin))
    layout(full, (852, 393))
    let frame = full.card.frame
    XCTAssertEqual([frame.minX, frame.minY, frame.maxX, frame.maxY], [12, 59, 832, 359])
    XCTAssertEqual(full.card.layer.cornerRadius, 0)
  }

  func testFullWithMarginIsInset16OnAllFourSidesWithButtonsPinnedToTheBottom() {
    let views = build(message("full", body: "Short", buttons: [("a", "OK")]))
    layout(views, (393, 852))
    let frame = views.card.frame
    XCTAssertEqual([frame.minX, frame.minY, frame.maxX, frame.maxY], [28, 75, 357, 802])
    XCTAssertEqual(views.buttonRow!.frame.maxY, views.card.bounds.height - 16, accuracy: 0.5)
    XCTAssertGreaterThan(views.card.layer.cornerRadius, 0)
  }

  func testCenterIgnoresMarginAndIsCenteredInTheSafeArea() {
    let with = build(message("center"))
    let without = build(message("center", style: #"{"margin":false}"#))
    layout(with, (393, 852))
    layout(without, (393, 852))
    XCTAssertEqual(with.card.frame, without.card.frame)
    XCTAssertEqual(with.card.frame.midX, 12 + (393 - 32) / 2, accuracy: 1)
    XCTAssertEqual(with.card.frame.midY, 59 + (852 - 93) / 2, accuracy: 1)
  }

  func testUnknownFormatRendersAsCenter() {
    let views = build(message("sideways"))
    layout(views, (393, 852))
    XCTAssertEqual(views.root.messageFrame?.gravity, .center)
  }

  func testBarsLetTouchesThroughCenterAndFullBlockThem() {
    for format in ["top", "bottom"] {
      let views = build(message(format))
      layout(views, (393, 852))
      XCTAssertNil(views.root.hitTest(CGPoint(x: 200, y: 426), with: nil), format)
      XCTAssertNotNil(views.root.hitTest(CGPoint(x: views.card.frame.midX, y: views.card.frame.midY), with: nil), format)
      XCTAssertEqual(views.root.backgroundColor, .clear, format)
    }
    let center = build(message("center"))
    layout(center, (393, 852))
    XCTAssertTrue(center.root.hitTest(CGPoint(x: 2, y: 2), with: nil) === center.root)
    var white: CGFloat = 1, alpha: CGFloat = 0
    XCTAssertTrue(center.root.backgroundColor!.getWhite(&white, alpha: &alpha))
    XCTAssertEqual(white, 0)
    XCTAssertEqual(alpha, 0.5, accuracy: 0.001)
    let full = build(message("full"))
    layout(full, (393, 852))
    XCTAssertTrue(full.root.hitTest(CGPoint(x: 2, y: 2), with: nil) === full.root)
  }

  // MARK: Plain text

  func testTitleAndBodyRenderVerbatimWithNoLinks() {
    let html = #"<b>Hi</b> <a href="https://x.test">link</a>"#
    let markdown = "**bold** [x](https://y.test) www.z.test\nsecond line"
    let views = build(message("center", title: html, body: markdown))
    XCTAssertEqual(views.title.text, html)
    XCTAssertEqual(views.body.text, markdown)
    for label in [views.title, views.body] {
      let text = label.attributedText!
      text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, _, _ in
        XCTAssertNil(value)
      }
      XCTAssertEqual(label.numberOfLines, 0)
    }
    XCTAssertTrue(views.body.text!.contains("\n"))
  }

  func testBlankTitleOrBodyIsHidden() {
    let views = build(message("center", title: " ", body: "Only body"))
    layout(views, (393, 852))
    XCTAssertTrue(views.title.isHidden)
    XCTAssertFalse(views.body.isHidden)
    XCTAssertEqual(views.body.frame.minY, 0)
  }

  // MARK: Buttons

  func testTwoShortButtonsSitSideBySide() {
    let views = build(message("bottom", buttons: [("a", "Yes"), ("b", "No")]))
    layout(views, (393, 852))
    XCTAssertFalse(views.buttonRow!.stacked)
    XCTAssertEqual(views.buttons[0].frame.minY, views.buttons[1].frame.minY)
    XCTAssertLessThanOrEqual(views.buttons[0].frame.maxX, views.buttons[1].frame.minX)
    XCTAssertEqual(views.buttons[0].frame.height, views.buttons[1].frame.height)
  }

  func testTwoLongButtonsWrapToAColumnAlsoAtTheLargestTextSize() {
    let long = "A very long button label that cannot share a line with another one"
    for traits in [regular, largest] {
      let views = build(message("top", buttons: [("a", long), ("b", long)]), traits: traits)
      layout(views, (393, 852))
      let label = traits.preferredContentSizeCategory.rawValue
      XCTAssertTrue(views.buttonRow!.stacked, label)
      XCTAssertGreaterThanOrEqual(views.buttons[1].frame.minY, views.buttons[0].frame.maxY, label)
      XCTAssertEqual(views.buttons[0].frame.width, views.buttonRow!.bounds.width, label)
    }
  }

  func testShortButtonsStackAtTheLargestTextSizeWhenTheyNoLongerFit() throws {
    try requireDynamicType()
    let labels = [("a", "Accept now"), ("b", "Maybe later")]
    let regularViews = build(message("center", buttons: labels), traits: regular)
    layout(regularViews, (393, 852))
    XCTAssertFalse(regularViews.buttonRow!.stacked)
    let largeViews = build(message("center", buttons: labels), traits: largest)
    layout(largeViews, (393, 852))
    XCTAssertTrue(largeViews.buttonRow!.stacked)
  }

  func testButtonLabelsAreVerbatimAndButtonsAreAtLeast44Tall() {
    let views = build(message("center", buttons: [("a", "Mixed Case")]))
    layout(views, (393, 852))
    XCTAssertEqual(views.buttons[0].configuration?.title, "Mixed Case")
    XCTAssertGreaterThanOrEqual(views.buttons[0].frame.height, 44)
    XCTAssertEqual(views.buttons[0].frame.width, views.buttonRow!.bounds.width)
  }

  // MARK: Style

  func testAuthorColorsAndAlignmentAreAppliedAndFixedInBothThemes() {
    let views = build(message(
      "center",
      style: ##"{"background_color":"#112233","text_color":"#445566","button_color":"#778899","button_text_color":"#AABBCC","text_align":"center"}"##,
      buttons: [("a", "A"), ("b", "B")]
    ))
    for theme in [UIUserInterfaceStyle.light, .dark] {
      XCTAssertEqual(resolved(views.card.backgroundColor, theme), resolved(InAppColor.author(0xFF11_2233).uiColor, theme))
      XCTAssertEqual(resolved(views.title.textColor, theme), resolved(InAppColor.author(0xFF44_5566).uiColor, theme))
      XCTAssertEqual(resolved(views.body.textColor, theme), resolved(InAppColor.author(0xFF44_5566).uiColor, theme))
      for button in views.buttons {
        XCTAssertEqual(
          resolved(button.configuration?.background.backgroundColor, theme),
          resolved(InAppColor.author(0xFF77_8899).uiColor, theme)
        )
        XCTAssertEqual(
          resolved(button.configuration?.baseForegroundColor, theme),
          resolved(InAppColor.author(0xFFAA_BBCC).uiColor, theme)
        )
      }
    }
    XCTAssertEqual(views.title.textAlignment, .center)
    XCTAssertEqual(views.body.textAlignment, .center)
  }

  func testRightAlignmentIsTheAbsoluteRightSide() {
    let views = build(message("center", style: #"{"text_align":"right"}"#))
    XCTAssertEqual(views.body.textAlignment, .right)
    XCTAssertEqual(build(message("center")).body.textAlignment, .left)
  }

  func testDefaultsAreSemanticSystemColorsSecondButtonTinted() {
    let views = build(message("center", buttons: [("a", "A"), ("b", "B")]))
    XCTAssertEqual(views.card.backgroundColor, .secondarySystemBackground)
    XCTAssertEqual(views.title.textColor, .label)
    XCTAssertEqual(views.buttons[0].configuration?.background.backgroundColor, .systemBlue)
    XCTAssertEqual(views.buttons[0].configuration?.baseForegroundColor, .white)
    XCTAssertEqual(views.buttons[1].configuration?.background.backgroundColor, .tertiarySystemFill)
    XCTAssertEqual(views.buttons[1].configuration?.baseForegroundColor, .label)
    // Dynamic: light and dark resolve to different values.
    XCTAssertNotEqual(resolved(views.card.backgroundColor, .light), resolved(views.card.backgroundColor, .dark))
    XCTAssertNotEqual(resolved(views.title.textColor, .light), resolved(views.title.textColor, .dark))
  }

  func testTextUsesDynamicTypeFonts() throws {
    let regularViews = build(message("center"), traits: regular)
    XCTAssertTrue(regularViews.title.adjustsFontForContentSizeCategory)
    XCTAssertTrue(regularViews.body.adjustsFontForContentSizeCategory)
    try requireDynamicType()
    let largeViews = build(message("center"), traits: largest)
    XCTAssertGreaterThan(largeViews.body.font.pointSize, regularViews.body.font.pointSize)
  }

  // MARK: Image and close control

  func testBarImageIsA56LeadingThumbnail() {
    let views = build(message("top", image: true), image: picture())
    layout(views, (393, 852))
    let image = views.image!
    XCTAssertEqual(image.frame.width, 56, accuracy: 0.5)
    XCTAssertEqual(image.frame.height, 56, accuracy: 0.5)
    XCTAssertLessThanOrEqual(image.frame.maxX, views.card.textBlock.frame.minX)
    XCTAssertEqual(views.close.configuration?.baseForegroundColor, views.title.textColor)
    var alpha: CGFloat = 1
    views.close.configuration?.background.backgroundColor?.getWhite(nil, alpha: &alpha)
    XCTAssertEqual(alpha, 0, "no scrim on a bar")
  }

  func testCenterImageSitsAboveTheTextAndTheCloseGlyphGetsAScrim() {
    let views = build(message("center", image: true), image: picture())
    layout(views, (393, 852))
    XCTAssertLessThanOrEqual(views.image!.frame.maxY, views.card.textBlock.frame.minY)
    XCTAssertEqual(views.image!.frame.width, views.card.scroll.bounds.width)
    XCTAssertEqual(views.close.configuration?.baseForegroundColor, .white)
    XCTAssertNotNil(views.close.configuration?.background.backgroundColor)
  }

  func testNoImageMeansNoImageSlot() {
    let views = build(message("center", image: true))
    XCTAssertNil(views.image)
  }

  func testTextNeverRunsUnderTheCloseControl() {
    for format in ["top", "center"] {
      let views = build(message(format, title: String(repeating: "Wide title ", count: 20)))
      layout(views, (393, 852))
      let text = views.card.scroll.convert(views.card.textBlock.frame, to: views.card)
      XCTAssertLessThanOrEqual(text.maxX, views.close.frame.minX + 0.5, format)
    }
  }

  func testCloseControlIsPresentWhateverTheStyleAndContent() {
    for format in ["top", "bottom", "center", "full"] {
      let views = build(message(
        format,
        body: longBody,
        style: ##"{"background_color":"#FFFFFF","text_color":"#FFFFFF","margin":false}"##
      ))
      layout(views, (393, 852))
      XCTAssertTrue(views.close.superview === views.card, format)
      XCTAssertFalse(views.close.isHidden, format)
      XCTAssertGreaterThanOrEqual(views.close.frame.width, 44, format)
      XCTAssertEqual(views.close.frame.maxX, views.card.bounds.width, accuracy: 0.5, format)
      XCTAssertEqual(views.close.frame.minY, 0, format)
    }
  }
}

/// Mirror of the T9 cases of `NottiInAppViewFactoryTest.kt`: gestures and taps
/// through the handlers the recognizers call, accessibility properties.
final class NottiInAppInteractionTests: XCTestCase {

  private final class Recorder: InAppViewListener {
    var closes: [String] = []
    var actions: [(String, InAppAction?)] = []
    var total: Int { closes.count + actions.count }
    func onClose(reason: String) { closes.append(reason) }
    func onAction(buttonId: String, action: InAppAction?) { actions.append((buttonId, action)) }
  }

  private let insets = InAppInsets(left: 12, top: 59, right: 20, bottom: 34)
  private let longBody = (1...200).map { "Line \($0) of a long body" }.joined(separator: "\n")

  private func message(_ format: String, body: String = "Body", buttons: String = "", imageAction: Bool = false) -> InAppMessage {
    var fields = [
      #""id":"m""#,
      #""format":"\#(format)""#,
      #""title":"Title""#,
      #""body":"\#(body.replacingOccurrences(of: "\n", with: "\\n"))""#,
      #""trigger":{"type":"session_start"}"#,
      #""image_url":"https://img.test/a.png""#,
    ]
    if imageAction { fields.append(#""image_action":{"type":"deeplink","value":"app://promo"}"#) }
    if !buttons.isEmpty { fields.append(#""buttons":[\#(buttons)]"#) }
    let raw = #"{"messages":[{\#(fields.joined(separator: ","))}]}"#
    return parseEligibleResponse(Data(raw.utf8))!.first!
  }

  private func button(_ id: String, _ label: String) -> String { #"{"id":"\#(id)","label":"\#(label)"}"# }

  private func picture() -> UIImage {
    UIGraphicsImageRenderer(size: CGSize(width: 120, height: 80)).image { context in
      UIColor.red.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
    }
  }

  private func bound(
    _ format: String,
    body: String = "Body",
    buttons: String = "",
    image: Bool = false,
    imageAction: Bool = false
  ) -> (InAppMessageViews, InAppInteraction, Recorder) {
    let model = message(format, body: body, buttons: buttons, imageAction: imageAction)
    let views = NottiInAppViewFactory.build(model, image: image ? picture() : nil, traits: UITraitCollection(preferredContentSizeCategory: .large))
    let recorder = Recorder()
    let interaction = NottiInAppViewFactory.bind(views, message: model, listener: recorder)
    views.root.safeAreaOverride = insets
    views.root.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
    views.root.layoutIfNeeded()
    views.card.layoutIfNeeded()
    views.buttonRow?.layoutIfNeeded()
    // The interaction holds its root and listener weakly: keep both for the whole test.
    retained.append((views, recorder))
    return (views, interaction, recorder)
  }

  private var retained: [Any] = []

  private func tap(_ button: UIButton) { button.sendActions(for: .touchUpInside) }

  // MARK: Dismiss

  func testCloseControlReportsCloseButtonOnEveryLayout() {
    for format in ["top", "bottom", "center", "full"] {
      let (views, _, recorder) = bound(format, buttons: button("a", "Accept"))
      tap(views.close)
      XCTAssertEqual(recorder.closes, [InAppDismissReason.closeButton], format)
      XCTAssertTrue(recorder.actions.isEmpty, format)
    }
  }

  func testTopSwipeUpPastTheThresholdReportsSwipeAShortDragDoesNot() {
    let (views, interaction, recorder) = bound("top")
    interaction.reduceMotion = { true }
    interaction.panChanged(-12)
    XCTAssertEqual(views.card.transform.ty, -12)
    interaction.panEnded(-12)
    XCTAssertEqual(recorder.total, 0)
    XCTAssertEqual(views.card.transform, .identity)
    interaction.panEnded(-80)
    XCTAssertEqual(recorder.closes, [InAppDismissReason.swipe])
  }

  func testBottomSwipeDownPastTheThresholdReportsSwipeTheOppositeDirectionDoesNot() {
    let (views, interaction, recorder) = bound("bottom")
    interaction.reduceMotion = { true }
    interaction.panChanged(-80)
    XCTAssertEqual(views.card.transform.ty, 0)
    interaction.panEnded(-80)
    XCTAssertEqual(recorder.total, 0)
    interaction.panChanged(80)
    XCTAssertEqual(views.card.transform.ty, 80)
    interaction.panEnded(80)
    XCTAssertEqual(recorder.closes, [InAppDismissReason.swipe])
  }

  func testSwipeThresholdIsAThirdOfTheBarHeightAtMost44() {
    let (views, interaction, _) = bound("top")
    views.card.bounds = CGRect(x: 0, y: 0, width: 300, height: 60)
    XCTAssertEqual(interaction.swipeThreshold, 20, accuracy: 0.01)
    views.card.bounds = CGRect(x: 0, y: 0, width: 300, height: 300)
    XCTAssertEqual(interaction.swipeThreshold, 44, accuracy: 0.01)
  }

  func testOnlyAMostlyVerticalDragInTheDismissDirectionStartsASwipe() {
    let (_, top, _) = bound("top")
    XCTAssertTrue(top.startsSwipe(dx: 5, dy: -50))
    XCTAssertFalse(top.startsSwipe(dx: 60, dy: -50))
    XCTAssertFalse(top.startsSwipe(dx: 0, dy: 50))
    let (_, bottom, _) = bound("bottom")
    XCTAssertTrue(bottom.startsSwipe(dx: -5, dy: 50))
    XCTAssertFalse(bottom.startsSwipe(dx: 0, dy: -50))
  }

  func testABarWhoseTextCanStillScrollLetsTheDragScrollInsteadOfDismissing() {
    let (views, bottom, _) = bound("bottom", body: longBody)
    XCTAssertTrue(bottom.startsSwipe(dx: 0, dy: 50))
    views.card.scroll.contentOffset = CGPoint(x: 0, y: 40)
    XCTAssertFalse(bottom.startsSwipe(dx: 0, dy: 50))
    // `top` with more text below: a finger moving up scrolls the content first.
    let (topViews, top, _) = bound("top", body: longBody)
    XCTAssertFalse(top.startsSwipe(dx: 0, dy: -50))
    let scroll = topViews.card.scroll
    scroll.contentOffset = CGPoint(x: 0, y: scroll.contentSize.height - scroll.bounds.height)
    XCTAssertTrue(top.startsSwipe(dx: 0, dy: -50))
  }

  func testACancelledDragSnapsBackWithoutDismissing() {
    let (views, interaction, recorder) = bound("top")
    interaction.reduceMotion = { true }
    interaction.panChanged(-30)
    interaction.settle()
    XCTAssertEqual(views.card.transform, .identity)
    XCTAssertEqual(recorder.total, 0)
  }

  func testCenterBackdropTapReportsOutsideTapATapInsideTheCardDoesNothing() {
    let (views, interaction, recorder) = bound("center")
    XCTAssertNotNil(interaction.backdropTap)
    XCTAssertTrue(interaction.backdropTap?.view === views.root)
    XCTAssertFalse(interaction.backdropAccepts(CGPoint(x: views.card.frame.midX, y: views.card.frame.midY)))
    XCTAssertTrue(interaction.backdropAccepts(CGPoint(x: 4, y: 4)))
    interaction.handleBackdropTap()
    XCTAssertEqual(recorder.closes, [InAppDismissReason.outsideTap])
  }

  func testFullHasNoDismissGestureBesidesTheCloseControl() {
    let (views, interaction, _) = bound("full", buttons: button("a", "Accept"))
    XCTAssertNil(interaction.pan)
    XCTAssertNil(interaction.bodyTap)
    XCTAssertNil(interaction.backdropTap)
    XCTAssertFalse(interaction.startsSwipe(dx: 0, dy: 200))
    XCTAssertFalse(interaction.startsSwipe(dx: 0, dy: -200))
    XCTAssertTrue(views.root.gestureRecognizers?.isEmpty ?? true)
    XCTAssertTrue(views.card.gestureRecognizers?.isEmpty ?? true)
  }

  func testBarsHaveTheirSwipeOnTheCard() {
    for format in ["top", "bottom"] {
      let (views, interaction, _) = bound(format)
      XCTAssertTrue(interaction.pan?.view === views.card, format)
      XCTAssertTrue(interaction.pan?.delegate === interaction, format)
    }
  }

  // MARK: Taps

  func testButtonTapReportsItsOwnIdAndTheUntouchedAction() {
    let buttons = #"{"id":"yes","label":"Yes","action":{"type":"url","value":"https://x.test/a?b=1"}},"# + button("no", "No")
    for format in ["top", "center", "full"] {
      let (views, _, recorder) = bound(format, buttons: buttons)
      tap(views.buttons[1])
      XCTAssertEqual(recorder.actions.map { $0.0 }, ["no"], format)
      XCTAssertNil(recorder.actions.first?.1, format)
      let (other, _, otherRecorder) = bound(format, buttons: buttons)
      tap(other.buttons[0])
      XCTAssertEqual(otherRecorder.actions.map { $0.0 }, ["yes"], format)
      XCTAssertEqual(otherRecorder.actions.first?.1, InAppAction(type: "url", value: "https://x.test/a?b=1"), format)
    }
  }

  func testImageTapWithAnImageActionReportsImage() {
    for format in ["top", "center", "full"] {
      let (views, interaction, recorder) = bound(format, buttons: button("a", "Accept"), image: true, imageAction: true)
      XCTAssertTrue(interaction.imageTap?.view === views.image, format)
      XCTAssertTrue(views.image!.isUserInteractionEnabled, format)
      interaction.handleImageTap()
      XCTAssertEqual(recorder.actions.map { $0.0 }, ["image"], format)
      XCTAssertEqual(recorder.actions.first?.1, InAppAction(type: "deeplink", value: "app://promo"), format)
      XCTAssertTrue(recorder.closes.isEmpty, format)
    }
  }

  func testImageWithoutAnImageActionIsNotTappable() {
    let (views, interaction, _) = bound("center", image: true)
    XCTAssertFalse(interaction.imageTappable)
    XCTAssertNil(interaction.imageTap)
    XCTAssertFalse(views.image!.isUserInteractionEnabled)
  }

  func testBarBodyTapActsAsTheFirstButtonNoButtonsMeansNotTappable() {
    for format in ["top", "bottom"] {
      let (views, interaction, recorder) = bound(format, buttons: button("first", "One") + "," + button("second", "Two"))
      XCTAssertTrue(interaction.bodyTap?.view === views.card, format)
      XCTAssertTrue(interaction.bodyTapAccepts(views.card.scroll.convert(views.body.center, from: views.card.textBlock)), format)
      interaction.handleBodyTap()
      XCTAssertEqual(recorder.actions.map { $0.0 }, ["first"], format)
      let (_, bare, bareRecorder) = bound(format)
      XCTAssertNil(bare.bodyTap, format)
      bare.handleBodyTap()
      XCTAssertEqual(bareRecorder.total, 0, format)
    }
  }

  func testABodyTapNeverStartsOnTheControls() {
    let (views, interaction, _) = bound("top", buttons: button("a", "Accept"), image: true, imageAction: true)
    for control in [views.close, views.buttons[0], views.image!] as [UIView] {
      let point = control.convert(CGPoint(x: control.bounds.midX, y: control.bounds.midY), to: views.card)
      XCTAssertFalse(interaction.bodyTapAccepts(point), "\(type(of: control))")
    }
  }

  func testCenterAndFullBodyIsNotTappableEvenWithButtons() {
    for format in ["center", "full"] {
      let (_, interaction, recorder) = bound(format, buttons: button("a", "Accept"))
      XCTAssertNil(interaction.bodyTap, format)
      XCTAssertNil(interaction.pan, format)
      XCTAssertEqual(recorder.total, 0, format)
    }
  }

  func testTouchesOutsideABarAreNotConsumedInsideTheyAre() {
    for format in ["top", "bottom"] {
      let (views, _, _) = bound(format, buttons: button("a", "Accept"))
      let outsideY: CGFloat = format == "top" ? 842 : 10
      XCTAssertNil(views.root.hitTest(CGPoint(x: 196, y: outsideY), with: nil), format)
      XCTAssertNotNil(views.root.hitTest(CGPoint(x: views.card.frame.midX, y: views.card.frame.midY), with: nil), format)
    }
  }

  func testOnlyTheFirstOutcomeOfADisplayIsDelivered() {
    let (views, interaction, recorder) = bound("top", buttons: button("a", "Accept"))
    tap(views.buttons[0])
    tap(views.buttons[0])
    tap(views.close)
    interaction.handleBodyTap()
    interaction.panEnded(-80)
    XCTAssertEqual(recorder.actions.map { $0.0 }, ["a"])
    XCTAssertTrue(recorder.closes.isEmpty)
  }

  func testTheListenerIsHeldWeakly() {
    let model = message("center")
    let views = NottiInAppViewFactory.build(model)
    var recorder: Recorder? = Recorder()
    weak var released = recorder
    NottiInAppViewFactory.bind(views, message: model, listener: recorder!)
    recorder = nil
    XCTAssertNil(released)
    views.close.sendActions(for: .touchUpInside)
  }

  // MARK: Reduce Motion

  func testSnapBackSkipsTheAnimationUnderReduceMotion() {
    let (views, interaction, _) = bound("top")
    var animated = 0
    interaction.animate = { _, changes in
      animated += 1
      changes()
    }
    interaction.reduceMotion = { true }
    interaction.panChanged(-20)
    interaction.panEnded(-20)
    XCTAssertEqual(animated, 0)
    XCTAssertEqual(views.card.transform, .identity)
    interaction.reduceMotion = { false }
    interaction.panChanged(-20)
    interaction.panEnded(-20)
    XCTAssertEqual(animated, 1)
    XCTAssertEqual(views.card.transform, .identity)
  }

  // MARK: Accessibility

  func testCloseLabelComesFromTheInCodeTableWithAnEnglishFallback() {
    XCTAssertEqual(NottiInAppAccessibility.closeLabel(languages: ["pt-BR"]), "Fechar")
    XCTAssertEqual(NottiInAppAccessibility.closeLabel(languages: ["pt"]), "Fechar")
    XCTAssertEqual(NottiInAppAccessibility.closeLabel(languages: ["PT_br"]), "Fechar")
    XCTAssertEqual(NottiInAppAccessibility.closeLabel(languages: ["en-US", "pt-BR"]), "Close")
    XCTAssertEqual(NottiInAppAccessibility.closeLabel(languages: ["es-ES"]), "Close")
    XCTAssertEqual(NottiInAppAccessibility.closeLabel(languages: []), "Close")
  }

  func testCloseControlUsesThePreferredLanguage() {
    let (views, interaction, _) = bound("center")
    NottiInAppAccessibility.apply(views, format: .center, imageTappable: interaction.imageTappable, languages: ["pt-BR"])
    XCTAssertEqual(views.close.accessibilityLabel, "Fechar")
    NottiInAppAccessibility.apply(views, format: .center, imageTappable: interaction.imageTappable, languages: ["fr-FR"])
    XCTAssertEqual(views.close.accessibilityLabel, "Close")
    XCTAssertTrue(views.close.accessibilityTraits.contains(.button))
  }

  func testButtonsAnnounceTheirLabelAndTheButtonTraitTheTitleIsAHeader() {
    let (views, _, _) = bound("center", buttons: button("a", "Accept") + "," + button("b", "Later"))
    XCTAssertEqual(views.buttons.map { $0.accessibilityLabel }, ["Accept", "Later"])
    for b in views.buttons { XCTAssertTrue(b.accessibilityTraits.contains(.button)) }
    XCTAssertTrue(views.title.accessibilityTraits.contains(.header))
    XCTAssertFalse(views.body.accessibilityTraits.contains(.header))
  }

  func testCenterAndFullAreModalBarsAreNot() {
    for (format, modal) in [("top", false), ("bottom", false), ("center", true), ("full", true)] {
      let (views, _, _) = bound(format)
      XCTAssertEqual(views.root.accessibilityViewIsModal, modal, format)
    }
  }

  func testEscapeActsAsTheCloseControlOnCenterAndFullOnly() {
    for format in ["center", "full"] {
      let (views, _, recorder) = bound(format)
      XCTAssertTrue(views.root.accessibilityPerformEscape(), format)
      XCTAssertEqual(recorder.closes, [InAppDismissReason.closeButton], format)
    }
    for format in ["top", "bottom"] {
      let (views, _, recorder) = bound(format)
      XCTAssertFalse(views.root.accessibilityPerformEscape(), format)
      XCTAssertEqual(recorder.total, 0, format)
    }
  }

  func testBarsAreAnnouncedModalsMoveTheFocusToTheTitle() {
    var posted: [(UIAccessibility.Notification, Any?)] = []
    let record: (UIAccessibility.Notification, Any?) -> Void = { posted.append(($0, $1)) }
    let (bar, _, _) = bound("top")
    NottiInAppAccessibility.onShown(bar, format: .top, post: record)
    XCTAssertEqual(posted.count, 1)
    XCTAssertEqual(posted[0].0, .announcement)
    XCTAssertEqual(posted[0].1 as? String, "Title. Body")
    posted.removeAll()
    let (modal, _, _) = bound("center")
    NottiInAppAccessibility.onShown(modal, format: .center, post: record)
    XCTAssertEqual(posted[0].0, .screenChanged)
    XCTAssertTrue(posted[0].1 as AnyObject === modal.title)
  }

  func testTheAnnouncementSkipsABlankTitle() {
    let model = parseEligibleResponse(Data(#"{"messages":[{"id":"m","format":"top","title":" ","body":"Only body","trigger":{"type":"session_start"}}]}"#.utf8))!.first!
    let views = NottiInAppViewFactory.build(model)
    XCTAssertEqual(NottiInAppAccessibility.announcement(views), "Only body")
  }

  func testASecondCloseIsIgnored() {
    let (views, interaction, recorder) = bound("center")
    tap(views.close)
    interaction.handleBackdropTap()
    XCTAssertTrue(views.root.accessibilityPerformEscape())
    XCTAssertEqual(recorder.closes, [InAppDismissReason.closeButton])
  }

  func testTappableImageIsReachableWithTheButtonTraitAStaticOneStaysHidden() {
    let (tappable, _, _) = bound("center", image: true, imageAction: true)
    XCTAssertTrue(tappable.image!.isAccessibilityElement)
    XCTAssertTrue(tappable.image!.accessibilityTraits.contains(.button))
    XCTAssertEqual(tappable.image!.accessibilityLabel, "Title")
    let (still, _, _) = bound("center", image: true)
    XCTAssertFalse(still.image!.isAccessibilityElement)
  }
}
#endif
