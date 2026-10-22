import XCTest
// Test target compiles the SDK's Swift sources directly (see NottiTests
// Xcode target: ios/*.swift + ios/Tests/*.swift, no CocoaPods module
// dependency) — no import of a "Notti" module needed or possible here.

/// Mirror of the click-bridge tests of `NottiModuleTest.kt`: the JS event
/// payload, the live-module rule and the no-buffering rule (A9, SDKIAM-68).
final class NottiInAppClickBridgeTests: XCTestCase {

  private var live: [NottiImpl] = []

  override func tearDown() {
    for impl in live { impl.invalidate() }
    live.removeAll()
    super.tearDown()
  }

  /// A module the way `Notti.mm` builds it: handler set, then published.
  private func module(_ handler: (([String: Any]) -> Void)?) -> NottiImpl {
    let impl = NottiImpl()
    impl.emitInAppClickHandler = handler
    impl.activate()
    live.append(impl)
    return impl
  }

  func testAClickReachesTheLiveModuleWithExactlyMessageIdButtonIdAndAction() {
    var emitted: [[String: Any]] = []
    _ = module { emitted.append($0) }
    // Reserved characters and escapes must arrive byte for byte.
    let value = "https://Shop.test/P?a=1&B=%20X#Frag"

    XCTAssertTrue(NottiImpl.emitInAppClick(InAppClick(messageId: "msg-1", buttonId: "b2", action: InAppAction(type: "url", value: value))))

    let payload = emitted[0]
    XCTAssertEqual(Set(payload.keys), ["messageId", "buttonId", "action"])
    XCTAssertEqual(payload["messageId"] as? String, "msg-1")
    XCTAssertEqual(payload["buttonId"] as? String, "b2")
    let action = payload["action"] as? [String: String]
    XCTAssertEqual(action.map { Set($0.keys) }, ["type", "value"])
    XCTAssertEqual(action?["type"], "url")
    XCTAssertEqual(action?["value"], value)
  }

  func testAClickWithoutAUsableActionCarriesNSNullRatherThanOmittingIt() throws {
    var emitted: [[String: Any]] = []
    _ = module { emitted.append($0) }
    // The parser turns an unknown action type into no action.
    let raw = #"{"messages":[{"id":"m1","format":"center","title":"t","body":"b","buttons":[{"id":"b1","label":"Go","action":{"type":"sms","value":"x"}}]}]}"#
    let parsed = try XCTUnwrap(parseEligibleResponse(Data(raw.utf8))?.first)

    XCTAssertTrue(NottiImpl.emitInAppClick(InAppClick(messageId: "m1", buttonId: "b1", action: parsed.buttons[0].action)))

    XCTAssertTrue(emitted[0].keys.contains("action"))
    XCTAssertTrue(emitted[0]["action"] is NSNull)
  }

  func testTheImageButtonIdAndValuesAreNeverRewritten() {
    var emitted: [[String: Any]] = []
    _ = module { emitted.append($0) }
    let value = "app://promo/ünï?x=1 2&y=\\n"
    XCTAssertTrue(NottiImpl.emitInAppClick(InAppClick(messageId: "m", buttonId: NottiInAppViewFactory.imageButtonId, action: InAppAction(type: "deeplink", value: value))))
    XCTAssertEqual(emitted[0]["buttonId"] as? String, "image")
    XCTAssertEqual((emitted[0]["action"] as? [String: String])?["value"], value)
  }

  func testAClickWithNoLiveModuleIsNotDeliveredAndNeverReplayedToALaterModule() {
    let old = module { _ in XCTFail("a torn-down module must not emit") }
    old.invalidate()

    XCTAssertFalse(NottiImpl.emitInAppClick(InAppClick(messageId: "m1", buttonId: "b1", action: nil)))

    var emitted: [[String: Any]] = []
    _ = module { emitted.append($0) }
    XCTAssertTrue(emitted.isEmpty, "nothing was buffered")
    XCTAssertTrue(NottiImpl.emitInAppClick(InAppClick(messageId: "m2", buttonId: "b1", action: nil)))
    XCTAssertEqual(emitted.map { $0["messageId"] as? String }, ["m2"])
  }

  func testAModuleWithoutAHandlerDoesNotCountAsDelivered() {
    _ = module(nil)
    XCTAssertFalse(NottiImpl.emitInAppClick(InAppClick(messageId: "m1", buttonId: "b1", action: nil)))
  }

  func testInvalidateClearsTheClickHandler() {
    let impl = module { _ in }
    impl.invalidate()
    XCTAssertNil(impl.emitInAppClickHandler)
  }

  func testTheBridgeIsTheCoordinatorsProductionClickSink() {
    let sink: InAppClickSink = NottiImpl.emitInAppClick
    XCTAssertFalse(sink(InAppClick(messageId: "m", buttonId: "b", action: nil)))
  }

  func testNoClickIsBufferedForAColdStartListener() {
    NottiEventBuffer.shared.reset()
    XCTAssertFalse(NottiImpl.emitInAppClick(InAppClick(messageId: "m1", buttonId: "b1", action: nil)))
    var received: [[String: Any]] = []
    let impl = module { received.append($0) }
    impl.emitClickedHandler = { _ in }
    impl.emitReceivedHandler = { _ in }
    XCTAssertTrue(received.isEmpty)
  }
}
