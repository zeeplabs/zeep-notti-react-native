import XCTest
#if canImport(UIKit)
import UIKit
#endif
// Test target compiles the SDK's Swift sources directly (see NottiTests
// Xcode target: ios/*.swift + ios/Tests/*.swift, no CocoaPods module
// dependency) — no import of a "Notti" module needed or possible here.

#if canImport(UIKit)
/// Mirror of `NottiInAppImageLoaderTest.kt` over `StubURLProtocol`.
final class NottiInAppImageLoaderTests: XCTestCase {

  private var center: NotificationCenter!

  override func setUp() {
    super.setUp()
    StubURLProtocol.reset()
    center = NotificationCenter()
  }

  private func loader(timeout: TimeInterval = 5, maxBytes: Int = NottiInAppImageLoader.maxBytes) -> NottiInAppImageLoader {
    NottiInAppImageLoader(
      maxBytes: maxBytes,
      timeout: timeout,
      makeSession: { config, delegate, queue in
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config, delegate: delegate, delegateQueue: queue)
      },
      center: center
    )
  }

  private func png(_ width: Int = 400, _ height: Int = 200) -> Data {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).pngData { context in
      UIColor.red.setFill()
      context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }
  }

  private let imageUrl = "https://img.example.invalid/a.png"

  /// Blocks until `done` runs (the loader answers on a background queue).
  private func load(_ loader: NottiInAppImageLoader, _ url: String? = nil, maxSide: CGFloat = 2000) -> UIImage? {
    let finished = expectation(description: "loaded")
    var result: UIImage?
    loader.load(url: url ?? imageUrl, maxSidePx: maxSide) {
      result = $0
      finished.fulfill()
    }
    wait(for: [finished], timeout: 10)
    return result
  }

  private func pixels(_ image: UIImage) -> CGSize {
    CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
  }

  func testANonHttpsUrlIsRejectedBeforeAnyConnection() {
    let loader = loader()
    for url in ["http://img.example.invalid/a.png", "ftp://img.example.invalid/a.png", "file:///tmp/a.png", "https://", "not a url", ""] {
      XCTAssertNil(load(loader, url), url)
    }
    XCTAssertTrue(StubURLProtocol.recordedRequests().isEmpty)
  }

  func testTheRequestCarriesNoAuthorizationNoCookieAndNoNottiHeader() {
    StubURLProtocol.enqueue(.data(png()))
    XCTAssertNotNil(load(loader()))
    let requests = StubURLProtocol.recordedRequests()
    XCTAssertEqual(requests.count, 1)
    let headers = requests[0].allHTTPHeaderFields ?? [:]
    XCTAssertEqual(requests[0].httpMethod, "GET")
    for name in headers.keys.map({ $0.lowercased() }) {
      XCTAssertFalse(name == "authorization" || name == "cookie" || name.hasPrefix("x-notti") || name.hasPrefix("x-client"), name)
    }
    XCTAssertFalse(requests[0].httpShouldHandleCookies)
  }

  func testTheSessionConfigurationHoldsNoCookiesNoCacheNoCredentials() {
    let config = NottiInAppImageLoader.configuration()
    XCTAssertNil(config.httpCookieStorage)
    XCTAssertFalse(config.httpShouldSetCookies)
    XCTAssertEqual(config.httpCookieAcceptPolicy, .never)
    XCTAssertNil(config.urlCache)
    XCTAssertNil(config.urlCredentialStorage)
    XCTAssertEqual(config.requestCachePolicy, .reloadIgnoringLocalCacheData)
    XCTAssertEqual(config.timeoutIntervalForRequest, 10)
  }

  func testALoadedImageIsDecodedAtFullSizeWhenItFits() throws {
    StubURLProtocol.enqueue(.data(png(400, 200)))
    let image = try XCTUnwrap(load(loader()))
    XCTAssertEqual(pixels(image), CGSize(width: 400, height: 200))
  }

  func testALargeImageIsDownsampledToTheSlot() throws {
    StubURLProtocol.enqueue(.data(png(1600, 800)))
    let image = try XCTUnwrap(load(loader(), maxSide: 400))
    XCTAssertEqual(max(pixels(image).width, pixels(image).height), 400, accuracy: 1)
    XCTAssertEqual(pixels(image).width / pixels(image).height, 2, accuracy: 0.05)
  }

  func testABodyPastTheSizeLimitIsAborted() {
    // A valid image, so only the limit can make it fail.
    let data = png(400, 200)
    StubURLProtocol.enqueue(.data(data))
    XCTAssertNil(load(loader(maxBytes: data.count - 1)))
  }

  func testABodyExactlyAtTheSizeLimitIsLoaded() {
    let data = png(40, 20)
    StubURLProtocol.enqueue(.data(data))
    XCTAssertNotNil(load(loader(maxBytes: data.count)))
  }

  func testADeclaredLengthPastTheLimitIsRefused() {
    StubURLProtocol.enqueue(.data(png(40, 20), headers: ["Content-Length": "9999999"]))
    XCTAssertNil(load(loader(maxBytes: 1_000_000)))
  }

  func testAnUndecodableBodyIsNoImage() {
    StubURLProtocol.enqueue(.data(Data("not an image".utf8)))
    XCTAssertNil(load(loader()))
  }

  func testAnErrorStatusIsNoImageEvenWithAValidImageBody() {
    StubURLProtocol.enqueue(StubURLProtocol.StubResponse(
      statusCode: 404, body: png(), error: nil, delayMs: 0))
    XCTAssertNil(load(loader()))
    StubURLProtocol.enqueue(.status(404, body: "missing"))
    XCTAssertNil(load(loader()))
    StubURLProtocol.enqueue(.networkError())
    XCTAssertNil(load(loader(), "https://img.example.invalid/b.png"))
  }

  func testARedirectToHttpIsRefused() {
    StubURLProtocol.enqueue(.redirect(to: "http://img.example.invalid/b.png"))
    StubURLProtocol.enqueue(.data(png()))
    XCTAssertNil(load(loader()))
    XCTAssertEqual(StubURLProtocol.recordedRequests().count, 1)
  }

  func testARedirectToHttpsIsFollowedWithoutCredentials() {
    StubURLProtocol.enqueue(.redirect(to: "https://cdn.example.invalid/b.png"))
    StubURLProtocol.enqueue(.data(png()))
    XCTAssertNotNil(load(loader()))
    let requests = StubURLProtocol.recordedRequests()
    XCTAssertEqual(requests.count, 2)
    XCTAssertEqual(requests[1].url?.host, "cdn.example.invalid")
    XCTAssertNil(requests[1].value(forHTTPHeaderField: "Authorization"))
    XCTAssertNil(requests[1].value(forHTTPHeaderField: "Cookie"))
  }

  func testASlowServerTimesOutIntoNoImage() {
    StubURLProtocol.enqueue(.data(png(), delayMs: 1_500))
    let started = Date()
    XCTAssertNil(load(loader(timeout: 0.2)))
    XCTAssertLessThan(Date().timeIntervalSince(started), 1.2)
  }

  func testACacheHitMakesNoSecondRequest() {
    let loader = loader()
    StubURLProtocol.enqueue(.data(png()))
    let first = load(loader)
    let second = load(loader)
    XCTAssertNotNil(first)
    XCTAssertTrue(first === second)
    XCTAssertEqual(StubURLProtocol.recordedRequests().count, 1)
  }

  func testTheCacheKeepsTheFiveMostRecentImages() {
    let loader = loader()
    let urls = (1...6).map { "https://img.example.invalid/\($0).png" }
    for url in urls {
      StubURLProtocol.enqueue(.data(png(40, 20)))
      XCTAssertNotNil(load(loader, url), url)
    }
    XCTAssertEqual(StubURLProtocol.recordedRequests().count, 6)
    // 2...6 are cached; 1 was evicted.
    for url in urls.dropFirst() { XCTAssertNotNil(load(loader, url), url) }
    XCTAssertEqual(StubURLProtocol.recordedRequests().count, 6)
    StubURLProtocol.enqueue(.data(png(40, 20)))
    XCTAssertNotNil(load(loader, urls[0]))
    XCTAssertEqual(StubURLProtocol.recordedRequests().count, 7)
  }

  func testAHitRefreshesTheEntryBeforeEviction() {
    let loader = loader()
    let urls = (1...6).map { "https://img.example.invalid/\($0).png" }
    for url in urls.prefix(5) {
      StubURLProtocol.enqueue(.data(png(40, 20)))
      _ = load(loader, url)
    }
    _ = load(loader, urls[0])
    StubURLProtocol.enqueue(.data(png(40, 20)))
    _ = load(loader, urls[5])
    let before = StubURLProtocol.recordedRequests().count
    XCTAssertNotNil(load(loader, urls[0]))
    XCTAssertEqual(StubURLProtocol.recordedRequests().count, before)
  }

  func testClearAndAMemoryWarningEmptyTheCache() {
    let loader = loader()
    StubURLProtocol.enqueue(.data(png()))
    _ = load(loader)
    loader.clear()
    StubURLProtocol.enqueue(.data(png()))
    XCTAssertNotNil(load(loader))
    XCTAssertEqual(StubURLProtocol.recordedRequests().count, 2)
    center.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
    StubURLProtocol.enqueue(.data(png()))
    XCTAssertNotNil(load(loader))
    XCTAssertEqual(StubURLProtocol.recordedRequests().count, 3)
  }

  func testAFailedLoadIsNotCached() {
    let loader = loader()
    StubURLProtocol.enqueue(.status(500))
    XCTAssertNil(load(loader))
    StubURLProtocol.enqueue(.data(png()))
    XCTAssertNotNil(load(loader))
    XCTAssertEqual(StubURLProtocol.recordedRequests().count, 2)
  }

  func testHttpsDetection() {
    XCTAssertTrue(NottiInAppImageLoader.isHttps("https://img.example.invalid/a.png"))
    XCTAssertTrue(NottiInAppImageLoader.isHttps("HTTPS://img.example.invalid/a.png"))
    XCTAssertFalse(NottiInAppImageLoader.isHttps("http://img.example.invalid/a.png"))
    XCTAssertFalse(NottiInAppImageLoader.isHttps("https:///a.png"))
  }
}
#endif
