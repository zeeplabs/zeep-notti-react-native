import XCTest
// Test target compiles the SDK's Swift sources directly (see NottiTests
// Xcode target: ios/*.swift + ios/Tests/*.swift, no CocoaPods module
// dependency) — no import of a "Notti" module needed or possible here.

/// Mirror of `NottiInAppModelsTest.kt`: same table inputs, copied rather than
/// shared, so the two platforms can be diffed for parity. Fixtures use only
/// synthetic values (`example.invalid`, all-zero UUIDs, `fixture`).
final class NottiInAppModelsTests: XCTestCase {

  private let zeroId = "00000000-0000-0000-0000-000000000000"

  private func message(_ extra: [String] = [], title: String = #""fixture""#, id: String? = nil) -> String {
    var fields = [
      #""id": \#(id ?? "\"\(zeroId)\"")"#,
      #""title": \#(title)"#,
      #""body": "fixture body""#,
      #""trigger": {"type": "session_start"}"#,
    ]
    fields.append(contentsOf: extra)
    return "{" + fields.joined(separator: ",") + "}"
  }

  private func parse(_ body: String) -> [InAppMessage]? {
    parseEligibleResponse(Data(body.utf8))
  }

  private func parseOne(
    _ extra: String...,
    title: String = #""fixture""#,
    id: String? = nil,
    file: StaticString = #filePath,
    line: UInt = #line
  ) -> InAppMessage? {
    let parsed = parse(#"{"messages": [\#(message(extra, title: title, id: id))]}"#)
    XCTAssertEqual(parsed?.count, 1, file: file, line: line)
    return parsed?.first
  }

  private func parseRaw(_ entry: String) -> InAppMessage? {
    parse(#"{"messages": [\#(entry)]}"#)?.first
  }

  // MARK: - response envelope

  func test_emptyMessagesArrayIsAValidResult() {
    XCTAssertEqual(parse(#"{"messages": []}"#), [])
  }

  func test_aBodyThatIsNotAJSONObjectIsAParseFailure() {
    for body in ["", "not json", "[]", #""text""#, "null", "42"] {
      XCTAssertNil(parse(body), "body: \(body)")
    }
  }

  func test_aMissingOrNonArrayMessagesFieldIsAParseFailure() {
    XCTAssertNil(parse("{}"))
    XCTAssertNil(parse(#"{"messages": null}"#))
    XCTAssertNil(parse(#"{"messages": {}}"#))
  }

  func test_unknownFieldsAreIgnoredAtEveryLevel() {
    let parsed = parseOne(
      #""future": {"a": 1}"#,
      #""style": {"future_token": "x"}"#,
      #""buttons": [{"id": "b1", "label": "Go", "future": true}]"#
    )
    XCTAssertEqual(parsed?.id, zeroId)
    XCTAssertEqual(parsed?.renderable, true)
    XCTAssertEqual(parsed?.buttons.count, 1)
  }

  func test_anEntryThatCannotBeParsedIsSkippedWithoutFailingTheOthers() {
    let body = #"{"messages": [42, \#(message()), "text", null, [], \#(message(id: #""b""#))]}"#
    XCTAssertEqual(parse(body)?.map(\.id), [zeroId, "b"])
  }

  func test_serverOrderIsPreserved() {
    let body = #"{"messages": [\#(message(id: #""c""#)), \#(message(id: #""a""#)), \#(message(id: #""b""#))]}"#
    XCTAssertEqual(parse(body)?.map(\.id), ["c", "a", "b"])
  }

  // MARK: - renderability (SDKIAM-14)

  func test_aCompleteMessageIsRenderableAndKeepsItsFields() throws {
    let parsed = try XCTUnwrap(parseOne(
      #""format": "top""#,
      #""image_url": "https://example.invalid/i.png""#,
      #""image_action": {"type": "url", "value": "https://example.invalid/offer"}"#,
      #""dismiss_after_seconds": 8"#
    ))
    XCTAssertTrue(parsed.renderable)
    XCTAssertEqual(parsed.format, .top)
    XCTAssertEqual(parsed.title, "fixture")
    XCTAssertEqual(parsed.body, "fixture body")
    XCTAssertEqual(parsed.imageUrl, "https://example.invalid/i.png")
    XCTAssertEqual(parsed.imageAction, InAppAction(type: "url", value: "https://example.invalid/offer"))
    XCTAssertEqual(parsed.dismissAfterSeconds, 8)
    XCTAssertEqual(parsed.trigger, .sessionStart)
  }

  func test_emptyOrMissingIdIsNotRenderable() {
    XCTAssertEqual(parseOne(id: #""""#)?.renderable, false)
    XCTAssertEqual(parseOne(id: "null")?.renderable, false)
    XCTAssertEqual(parseOne(id: "7")?.renderable, false)
  }

  func test_titleAndBodyBothBlankAfterTrimmingIsNotRenderable() {
    let trigger = #""trigger": {"type": "session_start"}"#
    XCTAssertEqual(parseRaw(#"{"id": "a", "title": "  \n", "body": "", \#(trigger)}"#)?.renderable, false)
    XCTAssertEqual(parseRaw(#"{"id": "a", "title": "", "body": "text", \#(trigger)}"#)?.renderable, true)
    XCTAssertEqual(parseRaw(#"{"id": "a", "title": "text", \#(trigger)}"#)?.renderable, true)
  }

  func test_unknownOrMissingTriggerIsNotRenderable() {
    XCTAssertEqual(parseRaw(#"{"id": "a", "title": "t", "trigger": {"type": "scroll"}}"#)?.renderable, false)
    XCTAssertEqual(parseRaw(#"{"id": "a", "title": "t"}"#)?.renderable, false)
  }

  func test_eventTriggerKeepsItsNameAndAnEmptyNameIsNotRenderable() {
    let parsed = parseRaw(#"{"id": "a", "title": "t", "trigger": {"type": "event", "name": " Checkout_Done "}}"#)
    XCTAssertEqual(parsed?.renderable, true)
    XCTAssertEqual(parsed?.trigger, .event(name: " Checkout_Done "))

    for trigger in [
      #"{"type": "event", "name": ""}"#,
      #"{"type": "event"}"#,
      #"{"type": "event", "name": 3}"#,
    ] {
      XCTAssertEqual(
        parseRaw(#"{"id": "a", "title": "t", "trigger": \#(trigger)}"#)?.renderable, false,
        "trigger: \(trigger)"
      )
    }
  }

  // MARK: - format

  func test_knownFormatsMapAndUnknownOrMissingFormatRendersCenter() {
    XCTAssertEqual(parseOne(#""format": "top""#)?.format, .top)
    XCTAssertEqual(parseOne(#""format": "bottom""#)?.format, .bottom)
    XCTAssertEqual(parseOne(#""format": "full""#)?.format, .full)
    XCTAssertEqual(parseOne(#""format": "center""#)?.format, .center)
    XCTAssertEqual(parseOne(#""format": "carousel""#)?.format, .center)
    XCTAssertEqual(parseOne(#""format": "TOP""#)?.format, .center)
    XCTAssertEqual(parseOne(#""format": 3"#)?.format, .center)
    XCTAssertEqual(parseOne()?.format, .center)
  }

  func test_unknownFormatKeepsTitleBodyButtonsAndStyleUnchangedAndRenderable() throws {
    let parsed = try XCTUnwrap(parseOne(
      #""format": "carousel""#,
      ##""style": {"background_color": "#102030", "text_align": "right"}"##,
      #""buttons": [{"id": "b1", "label": "Go", "action": {"type": "url", "value": "https://example.invalid/x"}}]"#
    ))
    XCTAssertEqual(parsed.format, .center)
    XCTAssertTrue(parsed.renderable)
    XCTAssertEqual(parsed.title, "fixture")
    XCTAssertEqual(parsed.body, "fixture body")
    XCTAssertEqual(parsed.buttons.map(\.id), ["b1"])
    XCTAssertEqual(parsed.style.backgroundColor, 0xFF10_2030)
    XCTAssertEqual(parsed.style.textAlign, .right)
  }

  // MARK: - buttons

  func test_buttonWithEmptyOrMissingIdOrLabelIsDroppedAndTheMessageStaysRenderable() {
    let parsed = parseOne(
      #""buttons": ["#
        + #"{"id": "", "label": "No id"},"#
        + #"{"label": "Missing id"},"#
        + #"{"id": "b1", "label": ""},"#
        + #"{"id": "b2"},"#
        + #"{"id": 5, "label": "Bad id type"},"#
        + #""not an object"]"#
    )
    XCTAssertEqual(parsed?.renderable, true)
    XCTAssertEqual(parsed?.buttons, [])
  }

  func test_threeButtonsWithTheFirstInvalidKeepTheNextTwoValidOnes() {
    let parsed = parseOne(
      #""buttons": ["#
        + #"{"id": "", "label": "bad"},"#
        + #"{"id": "b1", "label": "One"},"#
        + #"{"id": "b2", "label": "Two"},"#
        + #"{"id": "b3", "label": "Three"}]"#
    )
    XCTAssertEqual(parsed?.buttons.map(\.id), ["b1", "b2"])
  }

  func test_atMostTwoValidButtonsAreKeptInOrder() {
    let parsed = parseOne(
      #""buttons": [{"id": "b1", "label": "1"}, {"id": "b2", "label": "2"}, {"id": "b3", "label": "3"}]"#
    )
    XCTAssertEqual(parsed?.buttons.map(\.id), ["b1", "b2"])
  }

  func test_aMissingOrNonArrayButtonsFieldYieldsNoButtons() {
    XCTAssertEqual(parseOne()?.buttons, [])
    XCTAssertEqual(parseOne(#""buttons": null"#)?.buttons, [])
    XCTAssertEqual(parseOne(#""buttons": {}"#)?.buttons, [])
  }

  // MARK: - actions

  func test_actionValueIsKeptByteForByte() {
    let value = "exampleapp://offers/42?utm=a b&x=%20  "
    let parsed = parseOne(
      #""buttons": [{"id": "b1", "label": "Go", "action": {"type": "deeplink", "value": "\#(value)"}}]"#
    )
    XCTAssertEqual(parsed?.buttons.first?.action, InAppAction(type: "deeplink", value: value))
  }

  func test_unknownActionTypeKeepsTheMessageRenderableAndYieldsANilAction() {
    let parsed = parseOne(
      #""buttons": [{"id": "b1", "label": "Go", "action": {"type": "share", "value": "x"}}]"#
    )
    XCTAssertEqual(parsed?.renderable, true)
    XCTAssertEqual(parsed?.buttons.count, 1)
    XCTAssertNil(parsed?.buttons.first?.action)
  }

  func test_missingNullOrMalformedActionYieldsANilAction() {
    for button in [
      #"{"id": "b1", "label": "Go"}"#,
      #"{"id": "b1", "label": "Go", "action": null}"#,
      #"{"id": "b1", "label": "Go", "action": "url"}"#,
      #"{"id": "b1", "label": "Go", "action": {"type": "url"}}"#,
      #"{"id": "b1", "label": "Go", "action": {"type": "url", "value": ""}}"#,
    ] {
      let parsed = parseOne(#""buttons": [\#(button)]"#)
      XCTAssertEqual(parsed?.buttons.count, 1, "button: \(button)")
      XCTAssertNil(parsed?.buttons.first?.action, "button: \(button)")
    }
  }

  // MARK: - image

  func test_httpsImageUrlIsKept() {
    XCTAssertEqual(
      parseOne(#""image_url": "https://example.invalid/i.png""#)?.imageUrl,
      "https://example.invalid/i.png"
    )
  }

  func test_httpRelativeAndMalformedImageUrlsAreIgnoredAndTheMessageStaysRenderable() {
    for imageUrl in [
      #""http://example.invalid/i.png""#,
      #""//example.invalid/i.png""#,
      #""/i.png""#,
      #""i.png""#,
      #""https://""#,
      #""""#,
      "null",
      "5",
    ] {
      let parsed = parseOne(#""image_url": \#(imageUrl)"#)
      XCTAssertNil(parsed?.imageUrl, "image_url: \(imageUrl)")
      XCTAssertEqual(parsed?.renderable, true, "image_url: \(imageUrl)")
    }
  }

  func test_imageActionWithoutAUsableImageIsIgnored() {
    let action = #""image_action": {"type": "url", "value": "https://example.invalid/offer"}"#
    XCTAssertNil(parseOne(action)?.imageAction)
    XCTAssertNil(parseOne(#""image_url": "http://example.invalid/i.png""#, action)?.imageAction)
  }

  func test_imageActionWithAnUnknownTypeIsIgnoredButTheImageStays() {
    let parsed = parseOne(
      #""image_url": "https://example.invalid/i.png""#,
      #""image_action": {"type": "share", "value": "x"}"#
    )
    XCTAssertEqual(parsed?.imageUrl, "https://example.invalid/i.png")
    XCTAssertNil(parsed?.imageAction)
  }

  // MARK: - style

  func test_nullOrMissingStyleYieldsTheDefaults() {
    XCTAssertEqual(parseOne()?.style, InAppStyle())
    XCTAssertEqual(parseOne(#""style": null"#)?.style, InAppStyle())
    XCTAssertEqual(parseOne(#""style": {}"#)?.style, InAppStyle())
    XCTAssertEqual(parseOne(#""style": "dark""#)?.style, InAppStyle())
  }

  func test_styleTokensAreParsed() throws {
    let style = try XCTUnwrap(parseOne(
      ##""style": {"background_color": "#102030", "text_color": "#ffffff", "##
        + ##""button_color": "#E94B8B", "button_text_color": "#000000", "##
        + ##""text_align": "center", "margin": false}"##
    )?.style)
    XCTAssertEqual(style.backgroundColor, 0xFF10_2030)
    XCTAssertEqual(style.textColor, 0xFFFF_FFFF)
    XCTAssertEqual(style.buttonColor, 0xFFE9_4B8B)
    XCTAssertEqual(style.buttonTextColor, 0xFF00_0000)
    XCTAssertEqual(style.textAlign, .center)
    XCTAssertFalse(style.margin)
  }

  func test_aBadColorTokenFallsBackToTheDefaultWithoutAffectingTheOthers() throws {
    let style = try XCTUnwrap(parseOne(
      ##""style": {"background_color": "red", "text_color": "#FFFFFF", "button_color": "#12345678"}"##
    )?.style)
    XCTAssertNil(style.backgroundColor)
    XCTAssertEqual(style.textColor, 0xFFFF_FFFF)
    XCTAssertNil(style.buttonColor)
  }

  func test_textAlignAndMarginFallBackToTheirDefaults() {
    XCTAssertEqual(parseOne(#""style": {"text_align": "justify"}"#)?.style.textAlign, .left)
    XCTAssertEqual(parseOne(#""style": {"text_align": "left"}"#)?.style.textAlign, .left)
    XCTAssertEqual(parseOne(#""style": {"text_align": "right"}"#)?.style.textAlign, .right)
    XCTAssertEqual(parseOne(#""style": {"margin": "no"}"#)?.style.margin, true)
    XCTAssertEqual(parseOne(#""style": {"margin": null}"#)?.style.margin, true)
    XCTAssertEqual(parseOne(#""style": {"margin": false}"#)?.style.margin, false)
  }

  /// iOS-only trap: `JSONSerialization` returns numbers and booleans as
  /// `NSNumber`, and `as? Bool` accepts `0`. Android's `org.json` keeps them
  /// apart, so a numeric `margin` must fall back to the default.
  func test_aNumericMarginIsNotABooleanAndFallsBackToTheDefault() {
    XCTAssertEqual(parseOne(#""style": {"margin": 0}"#)?.style.margin, true)
    XCTAssertEqual(parseOne(#""style": {"margin": 1}"#)?.style.margin, true)
  }

  // MARK: - parseHexColor

  func test_parseHexColorAcceptsRRGGBBInEitherCaseAsOpaqueARGB() {
    XCTAssertEqual(parseHexColor("#102030"), 0xFF10_2030)
    XCTAssertEqual(parseHexColor("#ABCDEF"), 0xFFAB_CDEF)
    XCTAssertEqual(parseHexColor("#abcdef"), 0xFFAB_CDEF)
    XCTAssertEqual(parseHexColor("#000000"), 0xFF00_0000)
    XCTAssertEqual(parseHexColor("#FFFFFF"), 0xFFFF_FFFF)
  }

  func test_parseHexColorRejectsEveryOtherFormWithoutTrapping() {
    let values: [String?] = [
      nil, "", " ", "#", "#RGB", "#abc", "#RRGGBBAA", "#12345678", "102030", "#10203",
      "#1020301", "#GGGGGG", "#10 030", " #102030", "#102030 ", "#102030\n", "rgb(1,2,3)",
      // iOS-only: `UInt32(_:radix:)` would accept a sign, and a non-ASCII
      // character must not count as one byte.
      "#+10203", "#-10203", "#10203é",
    ]
    for value in values {
      XCTAssertNil(parseHexColor(value), "value: \(String(describing: value))")
    }
  }

  // MARK: - dismiss_after_seconds

  func test_dismissAfterSecondsInsideOneTo300IsKept() {
    XCTAssertEqual(parseOne(#""dismiss_after_seconds": 1"#)?.dismissAfterSeconds, 1)
    XCTAssertEqual(parseOne(#""dismiss_after_seconds": 8"#)?.dismissAfterSeconds, 8)
    XCTAssertEqual(parseOne(#""dismiss_after_seconds": 300"#)?.dismissAfterSeconds, 300)
  }

  func test_dismissAfterSecondsOutsideTheRangeNullAbsentOrNotAnIntegerMeansNoTimer() {
    for value in ["0", "-1", "301", "100000", "null", #""8""#, "8.5", "true", "{}"] {
      XCTAssertNil(parseOne(#""dismiss_after_seconds": \#(value)"#)?.dismissAfterSeconds, "value: \(value)")
    }
    XCTAssertNil(parseOne()?.dismissAfterSeconds)
  }

  // MARK: - title/body types

  func test_titleAndBodyThatAreNotStringsCountAsEmpty() {
    let parsed = parseRaw(#"{"id": "a", "title": 5, "body": null, "trigger": {"type": "session_start"}}"#)
    XCTAssertEqual(parsed?.title, "")
    XCTAssertEqual(parsed?.body, "")
    XCTAssertEqual(parsed?.renderable, false)
  }

  func test_titleAndBodyAreKeptAsPlainTextWithoutInterpretation() {
    let parsed = parseRaw(
      #"{"id": "a", "title": "<b>Hi</b> **x**", "body": "line1\nline2", "trigger": {"type": "session_start"}}"#
    )
    XCTAssertEqual(parsed?.title, "<b>Hi</b> **x**")
    XCTAssertEqual(parsed?.body, "line1\nline2")
  }
}
