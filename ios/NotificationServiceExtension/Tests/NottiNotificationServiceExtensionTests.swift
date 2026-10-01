import XCTest
import UserNotifications
@testable import Notti

/// Real test coverage for the rich-push NSE helper (B3, found missing in
/// pre-release review: the helper hardcoded `URLSession.shared` with no
/// injection point and shipped in a subspec never wired into any test
/// target). `session`/`logger` are now constructor-injected on
/// `NottiNotificationServiceExtension.didReceive`, exactly like
/// `NottiApiClient`'s existing pattern (`ios/Tests/NottiApiClientTests.swift`)
/// - `StubURLProtocol` is compiled directly into this test target (see
/// `Notti.podspec`'s `NotificationServiceExtension` test_spec) rather than
/// imported, since it lives in the `Core` subspec's separate module.
final class NottiNotificationServiceExtensionTests: XCTestCase {

  /// Generous on purpose: the handler fires after a real (stubbed) URLSession
  /// download task plus a file move, which on a loaded simulator/CI runner
  /// occasionally took longer than the old 2s and failed spuriously. A
  /// healthy run still completes in milliseconds.
  private static let handlerTimeout: TimeInterval = 10

  /// Invalidated in `tearDown` so no session (and its delegate queue/worker
  /// threads) outlives the test that created it.
  private var sessions: [URLSession] = []

  override func setUp() {
    super.setUp()
    StubURLProtocol.reset()
  }

  override func tearDown() {
    for session in sessions { session.invalidateAndCancel() }
    sessions.removeAll()
    super.tearDown()
  }

  private func stubSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: config)
    sessions.append(session)
    return session
  }

  private func request(userInfo: [AnyHashable: Any]) -> UNNotificationRequest {
    let content = UNMutableNotificationContent()
    content.userInfo = userInfo
    return UNNotificationRequest(identifier: "id", content: content, trigger: nil)
  }

  func test_missingAttachmentKeyCallsHandlerWithOriginalContentAndNoDownload() {
    let expectation = expectation(description: "handler called")
    NottiNotificationServiceExtension.didReceive(
      request(userInfo: [:]),
      withContentHandler: { content in
        XCTAssertTrue(content.attachments.isEmpty)
        expectation.fulfill()
      },
      session: stubSession()
    )
    wait(for: [expectation], timeout: Self.handlerTimeout)
    XCTAssertEqual(StubURLProtocol.recordedRequests().count, 0)
  }

  /// I3: a non-`https` scheme (verified in pre-release review against a real
  /// `file:///etc/hosts` URL, which succeeded) must be rejected before any
  /// download is attempted.
  func test_nonHttpsSchemeIsRejectedWithoutDownloading() {
    let expectation = expectation(description: "handler called")
    NottiNotificationServiceExtension.didReceive(
      request(userInfo: ["notti_image_url": "file:///etc/hosts"]),
      withContentHandler: { content in
        XCTAssertTrue(content.attachments.isEmpty)
        expectation.fulfill()
      },
      session: stubSession()
    )
    wait(for: [expectation], timeout: Self.handlerTimeout)
    XCTAssertEqual(StubURLProtocol.recordedRequests().count, 0)
  }

  func test_plainHttpSchemeIsRejectedWithoutDownloading() {
    let expectation = expectation(description: "handler called")
    NottiNotificationServiceExtension.didReceive(
      request(userInfo: ["notti_image_url": "http://cdn.example.com/pic.jpg"]),
      withContentHandler: { content in
        XCTAssertTrue(content.attachments.isEmpty)
        expectation.fulfill()
      },
      session: stubSession()
    )
    wait(for: [expectation], timeout: Self.handlerTimeout)
    XCTAssertEqual(StubURLProtocol.recordedRequests().count, 0)
  }

  /// I2: a 2xx-less response (error page, dead CDN link) must not be treated
  /// as a successful download.
  func test_httpErrorStatusDoesNotProduceAnAttachment() {
    StubURLProtocol.enqueue(.status(404, body: "not found"))
    let expectation = expectation(description: "handler called")
    NottiNotificationServiceExtension.didReceive(
      request(userInfo: ["notti_image_url": "https://cdn.example.com/pic.jpg"]),
      withContentHandler: { content in
        XCTAssertTrue(content.attachments.isEmpty)
        expectation.fulfill()
      },
      session: stubSession()
    )
    wait(for: [expectation], timeout: Self.handlerTimeout)
  }

  func test_successfulDownloadAttachesTheImage() {
    StubURLProtocol.enqueue(.status(200, body: "fake-image-bytes"))
    let expectation = expectation(description: "handler called")
    NottiNotificationServiceExtension.didReceive(
      request(userInfo: ["notti_image_url": "https://cdn.example.com/pic.jpg"]),
      withContentHandler: { content in
        XCTAssertEqual(content.attachments.count, 1)
        expectation.fulfill()
      },
      session: stubSession()
    )
    wait(for: [expectation], timeout: Self.handlerTimeout)
  }

  func test_serviceExtensionTimeWillExpireFallsBackToGivenContent() {
    let content = UNMutableNotificationContent()
    content.body = "fallback"
    let expectation = expectation(description: "handler called")
    NottiNotificationServiceExtension.serviceExtensionTimeWillExpire(for: content) { result in
      XCTAssertEqual(result.body, "fallback")
      expectation.fulfill()
    }
    wait(for: [expectation], timeout: 1)
  }

  /// Mirrors Apple's own template contract: no `bestAttemptContent` captured
  /// yet (extension killed before `didReceive` even ran) means nothing to
  /// hand back - the handler is simply never called, exactly as it never was
  /// before this fix (B2's broken signature could never actually be called
  /// from real integrator code at all).
  func test_serviceExtensionTimeWillExpireWithNilContentNeverCallsHandler() {
    var called = false
    NottiNotificationServiceExtension.serviceExtensionTimeWillExpire(for: nil) { _ in called = true }
    XCTAssertFalse(called)
  }

  func test_fileExtensionPrefersMimeTypeOverURLExtension() {
    let response = HTTPURLResponse(
      url: URL(string: "https://cdn.example.com/x")!,
      mimeType: "image/png",
      expectedContentLength: -1,
      textEncodingName: nil
    )
    let ext = NottiNotificationServiceExtension.fileExtension(
      for: response, fallbackFrom: URL(string: "https://cdn.example.com/x.weird")!
    )
    XCTAssertEqual(ext, "png")
  }

  func test_fileExtensionFallsBackToURLExtensionWhenMimeTypeUnknown() {
    let ext = NottiNotificationServiceExtension.fileExtension(
      for: nil, fallbackFrom: URL(string: "https://cdn.example.com/x.gif")!
    )
    XCTAssertEqual(ext, "gif")
  }

  func test_fileExtensionDefaultsToJpgWhenNothingIsKnown() {
    let ext = NottiNotificationServiceExtension.fileExtension(
      for: nil, fallbackFrom: URL(string: "https://cdn.example.com/no-extension")!
    )
    XCTAssertEqual(ext, "jpg")
  }
}
