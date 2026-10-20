import XCTest
#if canImport(UIKit)
import UIKit
#endif
// Test target compiles the SDK's Swift sources directly (see NottiTests
// Xcode target: ios/*.swift + ios/Tests/*.swift, no CocoaPods module
// dependency) — no import of a "Notti" module needed or possible here.

/// Mirror of `NottiInAppStyleTest.kt`: same tokens and container sizes. The
/// Android palette comes from theme attributes; here the defaults are the
/// semantic `UIColor`s of the design table, so the tests assert the tokens.
final class NottiInAppStyleTests: XCTestCase {

  private func styleOf(_ json: String?) -> InAppStyle {
    let style = json.map { #","style":\#($0)"# } ?? ""
    let body = ##"{"messages":[{"id":"m","title":"t","trigger":{"type":"session_start"}\##(style)}]}"##
    return parseEligibleResponse(Data(body.utf8))!.first!.style
  }

  private let defaultButtons = [
    InAppButtonLook(kind: .filled, background: .accent, text: .white),
    InAppButtonLook(kind: .tinted, background: .secondaryFill, text: .text),
  ]

  // MARK: Style tokens

  func testNullStyleGivesAllDefaults() {
    let resolved = resolveStyle(styleOf(nil), buttonCount: 2)
    XCTAssertEqual(resolved.background, .background)
    XCTAssertEqual(resolved.text, .text)
    XCTAssertEqual(resolved.textAlign, .left)
    XCTAssertTrue(resolved.margin)
    XCTAssertEqual(resolved.buttons, defaultButtons)
  }

  func testButtonCountMatchesTheButtons() {
    XCTAssertEqual(resolveStyle(styleOf(nil), buttonCount: 0).buttons, [])
    XCTAssertEqual(resolveStyle(styleOf(nil), buttonCount: 1).buttons, [defaultButtons[0]])
  }

  func testValidTokensApplyLowerCaseHexAccepted() {
    let resolved = resolveStyle(
      styleOf(##"{"background_color":"#ff0000","text_color":"#00FF00","text_align":"right","margin":false}"##),
      buttonCount: 0
    )
    XCTAssertEqual(resolved.background, .author(0xFFFF_0000))
    XCTAssertEqual(resolved.text, .author(0xFF00_FF00))
    XCTAssertEqual(resolved.textAlign, .right)
    XCTAssertFalse(resolved.margin)
  }

  func testAnInvalidTokenUsesItsDefaultAndTheOthersStillApply() {
    for bad in ["red", "#FFF", "FF0000", "#GG0000", "#80FF0000", ""] {
      let resolved = resolveStyle(
        styleOf(##"{"background_color":"\##(bad)","text_color":"#00FF00"}"##),
        buttonCount: 0
      )
      XCTAssertEqual(resolved.background, .background, "token \(bad)")
      XCTAssertEqual(resolved.text, .author(0xFF00_FF00), "token \(bad)")
    }
  }

  func testTextAlignAbsentOrUnknownIsLeftMarginAbsentIsTrue() {
    for json in ["{}", ##"{"text_align":"justify"}"##, ##"{"text_align":"CENTER"}"##] {
      let resolved = resolveStyle(styleOf(json), buttonCount: 0)
      XCTAssertEqual(resolved.textAlign, .left, json)
      XCTAssertTrue(resolved.margin, json)
    }
    XCTAssertEqual(resolveStyle(styleOf(##"{"text_align":"center"}"##), buttonCount: 0).textAlign, .center)
  }

  func testButtonColorAppliesToAllButtonsAndTheLabelKeepsItsDefault() {
    let resolved = resolveStyle(styleOf(##"{"button_color":"#123456"}"##), buttonCount: 2)
    let expected = InAppButtonLook(kind: .filled, background: .author(0xFF12_3456), text: .white)
    XCTAssertEqual(resolved.buttons, [expected, expected])
  }

  func testButtonTextColorAloneAppliesToAllButtonsOverTheDefaultBackground() {
    let resolved = resolveStyle(styleOf(##"{"button_text_color":"#000000"}"##), buttonCount: 2)
    let expected = InAppButtonLook(kind: .filled, background: .accent, text: .author(0xFF00_0000))
    XCTAssertEqual(resolved.buttons, [expected, expected])
  }

  func testOnlyBackgroundColorSetDerivesNothingElse() {
    for background in ["#FFFFFF", "#000000", "#1C1C1E"] {
      let resolved = resolveStyle(styleOf(##"{"background_color":"\##(background)"}"##), buttonCount: 2)
      XCTAssertEqual(resolved.text, .text, background)
      XCTAssertEqual(resolved.buttons, defaultButtons, background)
    }
  }

  #if canImport(UIKit)
  func testSemanticTokensMapToTheDesignTableColors() {
    XCTAssertEqual(InAppColor.background.uiColor, .secondarySystemBackground)
    XCTAssertEqual(InAppColor.text.uiColor, .label)
    XCTAssertEqual(InAppColor.accent.uiColor, .systemBlue)
    XCTAssertEqual(InAppColor.white.uiColor, .white)
    XCTAssertEqual(InAppColor.secondaryFill.uiColor, .tertiarySystemFill)
  }

  func testAuthorColorIsOpaqueAndFixedInBothThemes() {
    for style in [UIUserInterfaceStyle.light, .dark] {
      let resolved = InAppColor.author(0xFF12_3456).uiColor
        .resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
      var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
      XCTAssertTrue(resolved.getRed(&r, green: &g, blue: &b, alpha: &a))
      XCTAssertEqual(r, 0x12 / 255, accuracy: 0.001)
      XCTAssertEqual(g, 0x34 / 255, accuracy: 0.001)
      XCTAssertEqual(b, 0x56 / 255, accuracy: 0.001)
      XCTAssertEqual(a, 1)
    }
  }

  func testBackdropIsBlackAtHalfAlpha() {
    var w: CGFloat = 1, a: CGFloat = 0
    XCTAssertTrue(InAppColor.backdrop.uiColor.getWhite(&w, alpha: &a))
    XCTAssertEqual(w, 0)
    XCTAssertEqual(a, 0.5, accuracy: 0.001)
  }
  #endif

  // MARK: Frames

  private typealias Size = (width: CGFloat, height: CGFloat)
  private let phone: Size = (393, 852)
  private let smallPhone: Size = (320, 568)
  private let tablet: Size = (1024, 1366)
  private let landscape: Size = (852, 393)
  private let insets = InAppInsets(left: 12, top: 59, right: 20, bottom: 34)

  private func frame(_ format: InAppFormat, _ margin: Bool, _ size: Size, safe: InAppInsets? = nil) -> InAppFrame {
    computeFrame(
      format: format,
      margin: margin,
      containerWidth: size.width,
      containerHeight: size.height,
      safe: safe ?? insets
    )
  }

  func testBarsWithMarginAreInset16FromTheSafeAreaEdges() {
    let top = frame(.top, true, phone)
    XCTAssertEqual(top.gravity, .top)
    XCTAssertEqual(top.marginLeft, 28)
    XCTAssertEqual(top.marginTop, 75)
    XCTAssertEqual(top.marginRight, 36)
    XCTAssertEqual(top.width, 393 - 12 - 20 - 32)
    let bottom = frame(.bottom, true, phone)
    XCTAssertEqual(bottom.gravity, .bottom)
    XCTAssertEqual(bottom.marginBottom, 50)
    XCTAssertEqual(bottom.width, top.width)
  }

  func testBarsWithoutMarginTouchTheSafeAreaEdgesNeverTheScreenEdge() {
    let top = frame(.top, false, landscape)
    XCTAssertEqual(top.marginLeft, 12)
    XCTAssertEqual(top.marginTop, 59)
    XCTAssertEqual(top.marginRight, 20)
    XCTAssertEqual(top.width, 852 - 12 - 20)
    let bottom = frame(.bottom, false, landscape)
    XCTAssertEqual(bottom.marginBottom, 34)
  }

  func testBarHeightIsAtMost40PercentOfTheContainer() {
    for size in [phone, smallPhone, tablet, landscape] {
      for format in [InAppFormat.top, .bottom] {
        let bar = frame(format, true, size)
        XCTAssertLessThanOrEqual(bar.maxHeight, size.height * 0.4 + 0.001, "\(size) \(format)")
        XCTAssertGreaterThan(bar.maxHeight, 0)
      }
    }
  }

  func testBarHeightAlsoStaysInsideTheSafeAreaWhenItIsShorterThan40Percent() {
    let tallInsets = InAppInsets(left: 0, top: 150, right: 0, bottom: 150)
    for format in [InAppFormat.top, .bottom] {
      XCTAssertEqual(frame(format, true, landscape, safe: tallInsets).maxHeight, 393 - 300 - 32, "\(format)")
      XCTAssertEqual(frame(format, false, landscape, safe: tallInsets).maxHeight, 393 - 300, "\(format)")
    }
  }

  func testCenterCardIsAtMost90PercentWideCappedAt560AndIgnoresMargin() {
    let phoneCard = frame(.center, true, phone)
    XCTAssertEqual(phoneCard.gravity, .center)
    XCTAssertEqual(phoneCard.width, 393 * 0.9, accuracy: 0.001)
    XCTAssertEqual(frame(.center, false, phone), phoneCard)
    XCTAssertEqual(frame(.center, true, tablet).width, 560)
    XCTAssertEqual(frame(.center, true, landscape).width, 560)
    XCTAssertEqual(frame(.center, true, smallPhone).width, 320 * 0.9, accuracy: 0.001)
    XCTAssertEqual(phoneCard.maxHeight, (852 - 59 - 34) * 0.9, accuracy: 0.001)
    XCTAssertEqual(phoneCard.marginLeft, 12)
    XCTAssertEqual(phoneCard.marginTop, 59)
  }

  func testCenterCardNeverExceedsTheSafeWidth() {
    let narrowSafe = InAppInsets(left: 100, top: 0, right: 100, bottom: 0)
    XCTAssertEqual(frame(.center, true, (320, 568), safe: narrowSafe).width, 120)
  }

  func testFullFillsTheSafeAreaWith16OnAllFourSides() {
    let full = frame(.full, true, phone)
    XCTAssertEqual(full.gravity, .fill)
    XCTAssertEqual([full.marginLeft, full.marginTop, full.marginRight, full.marginBottom], [28, 75, 36, 50])
    XCTAssertEqual(full.width, 393 - 12 - 20 - 32)
    XCTAssertEqual(full.maxHeight, 852 - 59 - 34 - 32)
  }

  func testFullWithoutMarginTouchesTheSafeAreaEdgesOnAllSides() {
    let full = frame(.full, false, landscape)
    XCTAssertEqual([full.marginLeft, full.marginTop, full.marginRight, full.marginBottom], [12, 59, 20, 34])
    XCTAssertEqual(full.width, 852 - 32)
    XCTAssertEqual(full.maxHeight, 393 - 93)
  }

  func testZeroInsetsKeepTheFrameInsideTheContainer() {
    for size in [phone, smallPhone, tablet, landscape] {
      for format in [InAppFormat.top, .center, .bottom, .full] {
        let f = frame(format, true, size, safe: .zero)
        XCTAssertLessThanOrEqual(f.width, size.width)
        XCTAssertLessThanOrEqual(f.maxHeight, size.height)
      }
    }
  }

  func testSafeAreaLargerThanTheContainerNeverGoesNegative() {
    let huge = InAppInsets(left: 300, top: 500, right: 300, bottom: 500)
    for format in [InAppFormat.top, .center, .bottom, .full] {
      let f = frame(format, true, smallPhone, safe: huge)
      XCTAssertGreaterThanOrEqual(f.width, 0, "\(format)")
      XCTAssertGreaterThanOrEqual(f.maxHeight, 0, "\(format)")
    }
  }

  func testCloseTargetAndThumbnailSizes() {
    XCTAssertGreaterThanOrEqual(InAppMetrics.closeTarget, 44)
    XCTAssertEqual(InAppMetrics.thumbnail, 56)
  }
}
