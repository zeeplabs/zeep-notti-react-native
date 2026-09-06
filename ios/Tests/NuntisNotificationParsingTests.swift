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

  func test_internalFcmAndApnsTransportKeysAreNotExposedInData() {
    // Android already strips these (NuntisActivityLifecycleListener.kt); iOS
    // used to copy every top-level key, so the same push produced a different
    // payload.data per platform - a broken public contract.
    let userInfo: [AnyHashable: Any] = [
      "aps": ["alert": ["title": "Hello", "body": "World"], "content-available": 1],
      "gcm.message_id": "0:1699999999",
      "gcm.n.e": "1",
      "google.c.sender.id": "1234567890",
      "google.c.a.e": "1",
      "google.ttl": 2419200,
      "from": "1234567890",
      "collapse_key": "com.example.app",
      "fcm_options": ["image": "https://example.com/i.png"],
      "content-available": 1,
      "orderId": "abc-123",
      "plan": "vip",
    ]

    let parsed = parseUserInfo(userInfo)

    XCTAssertEqual(parsed.data, ["orderId": "abc-123", "plan": "vip"])
  }

  func test_nonStringCustomValuesAreStringifiedReadablyNotAsSwiftDebugOutput() {
    let userInfo: [AnyHashable: Any] = [
      "aps": ["alert": "hi"],
      "count": 42,
      "ratio": 1.5,
      "flag": true,
      "off": false,
      "nested": ["a": 1, "b": "two"],
      "list": [1, 2, 3],
      "nothing": NSNull(),
    ]

    let parsed = parseUserInfo(userInfo)

    XCTAssertEqual(parsed.data["count"], "42")
    XCTAssertEqual(parsed.data["ratio"], "1.5")
    XCTAssertEqual(parsed.data["flag"], "true", "a boolean must not surface as 1")
    XCTAssertEqual(parsed.data["off"], "false")
    XCTAssertEqual(parsed.data["list"], "[1,2,3]")
    XCTAssertNil(parsed.data["nothing"], "a null value has no string form and is dropped")

    // A nested object round-trips as JSON rather than Swift's debug dump.
    let nested = parsed.data["nested"]!
    XCTAssertFalse(nested.contains("="), "expected JSON, got Swift debug output: \(nested)")
    let decoded = try! JSONSerialization.jsonObject(with: nested.data(using: .utf8)!) as! [String: Any]
    XCTAssertEqual(decoded["a"] as? Int, 1)
    XCTAssertEqual(decoded["b"] as? String, "two")
  }

  func test_plainStringAlertIsTreatedAsBodyWithNoTitle() {
    let userInfo: [AnyHashable: Any] = ["aps": ["alert": "Just a message"]]

    let parsed = parseUserInfo(userInfo)

    XCTAssertNil(parsed.title)
    XCTAssertEqual(parsed.body, "Just a message")
    XCTAssertTrue(parsed.data.isEmpty)
  }
}
