import XCTest

final class NuntisNotificationParsingTests: XCTestCase {

  func test_standardApsAlertPayloadExtractsTitleBodyAndCustomData() {
    let userInfo: [AnyHashable: Any] = [
      "aps": ["alert": ["title": "Hello", "body": "World"], "sound": "default"],
      "plan": "vip",
      "campaign_id": "42",
    ]

    let parsed = parseUserInfo(userInfo)

    XCTAssertEqual(parsed.title, "Hello")
    XCTAssertEqual(parsed.body, "World")
    XCTAssertEqual(parsed.data, ["plan": "vip", "campaign_id": "42"])
  }

  func test_dataOnlySilentPushWithNoApsAlertHasNilTitleAndBody() {
    let userInfo: [AnyHashable: Any] = [
      "aps": ["content-available": 1],
      "orderId": "abc-123",
    ]

    let parsed = parseUserInfo(userInfo)

    XCTAssertNil(parsed.title)
    XCTAssertNil(parsed.body)
    XCTAssertEqual(parsed.data, ["orderId": "abc-123"])
  }

  func test_malformedPayloadWithNoApsBlockAtAllStillParsesRemainingKeysAsData() {
    let userInfo: [AnyHashable: Any] = ["foo": "bar"]

    let parsed = parseUserInfo(userInfo)

    XCTAssertNil(parsed.title)
    XCTAssertNil(parsed.body)
    XCTAssertEqual(parsed.data, ["foo": "bar"])
  }

  func test_plainStringAlertIsTreatedAsBodyWithNoTitle() {
    let userInfo: [AnyHashable: Any] = ["aps": ["alert": "Just a message"]]

    let parsed = parseUserInfo(userInfo)

    XCTAssertNil(parsed.title)
    XCTAssertEqual(parsed.body, "Just a message")
    XCTAssertTrue(parsed.data.isEmpty)
  }
}
