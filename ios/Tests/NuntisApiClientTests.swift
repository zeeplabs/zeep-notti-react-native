import XCTest

final class NuntisApiClientTests: XCTestCase {

  private var client: NuntisApiClient!
  private var sleeps: [UInt64] = []

  override func setUp() {
    super.setUp()
    StubURLProtocol.reset()
    sleeps = []
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: config)
    client = NuntisApiClient(
      session: session,
      baseUrl: "https://nuntis.example.com",
      appId: "app-1",
      clientKey: "secret-key",
      sleeper: { ms in self.sleeps.append(ms) }
    )
  }

  func test_validatedBaseUrlAcceptsAbsoluteHttpUrlsAndRejectsEverythingElse() {
    XCTAssertEqual(NuntisApiClient.validatedBaseUrl("https://push.example.com"), "https://push.example.com")
    XCTAssertEqual(NuntisApiClient.validatedBaseUrl("http://localhost:8080"), "http://localhost:8080")
    XCTAssertEqual(NuntisApiClient.validatedBaseUrl(" https://push.example.com/// "), "https://push.example.com")

    XCTAssertNil(NuntisApiClient.validatedBaseUrl("my host.example.com"))
    XCTAssertNil(NuntisApiClient.validatedBaseUrl("push.example.com"))
    XCTAssertNil(NuntisApiClient.validatedBaseUrl("https://"))
    XCTAssertNil(NuntisApiClient.validatedBaseUrl("ftp://push.example.com"))
    XCTAssertNil(NuntisApiClient.validatedBaseUrl("https://ex ample.com/%zz"))
    XCTAssertNil(NuntisApiClient.validatedBaseUrl(""))
  }

  func test_anUnusableBaseUrlFailsTheCallInsteadOfCrashing() {
    // Defense in depth for the public API client: even handed a baseUrl that
    // cannot form a URL at all (invalid percent-escape here — current
    // Foundation percent-encodes most other garbage instead of returning nil),
    // it must return a failure rather than force-unwrap.
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    let brokenClient = NuntisApiClient(
      session: URLSession(configuration: config),
      baseUrl: "https://ex ample.com/%zz",
      appId: "app-1",
      clientKey: "secret-key",
      sleeper: { _ in }
    )

    guard case .failure(let postError) = brokenClient.createOrUpdateDevice(token: "t", platform: "ios") else {
      return XCTFail("expected failure")
    }
    XCTAssertTrue(postError.contains("baseUrl"))

    guard case .failure(let patchError) = brokenClient.patchDevice(deviceId: "d", token: "t", fields: [:]) else {
      return XCTFail("expected failure")
    }
    XCTAssertTrue(patchError.contains("baseUrl"))
    XCTAssertEqual(StubURLProtocol.recordedRequests().count, 0)
  }

  func test_createOrUpdateDeviceSendsPostWithCorrectHeadersAndBody() {
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#))

    let result = client.createOrUpdateDevice(token: "apns-token", platform: "ios")

    let recorded = StubURLProtocol.recordedRequests()
    XCTAssertEqual(recorded.count, 1)
    XCTAssertEqual(recorded[0].httpMethod, "POST")
    XCTAssertEqual(recorded[0].url?.path, "/v1/apps/app-1/devices")
    XCTAssertEqual(recorded[0].value(forHTTPHeaderField: "Authorization"), "Bearer secret-key")

    let sentBody = try! JSONSerialization.jsonObject(with: bodyData(recorded[0])) as! [String: Any]
    XCTAssertEqual(sentBody["token"] as? String, "apns-token")
    XCTAssertEqual(sentBody["platform"] as? String, "ios")

    guard case .success(let response) = result else { return XCTFail("expected success") }
    XCTAssertEqual(response.id, "device-1")
  }

  func test_patchDeviceAlwaysIncludesTheCachedTokenField() {
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{"plan":"vip"}}"#))

    let result = client.patchDevice(deviceId: "device-1", token: "apns-token", fields: ["subscribed": true])

    let recorded = StubURLProtocol.recordedRequests()
    XCTAssertEqual(recorded[0].httpMethod, "PATCH")
    XCTAssertEqual(recorded[0].url?.path, "/v1/apps/app-1/devices/device-1")

    let sentBody = try! JSONSerialization.jsonObject(with: bodyData(recorded[0])) as! [String: Any]
    XCTAssertEqual(sentBody["token"] as? String, "apns-token")
    XCTAssertEqual(sentBody["subscribed"] as? Bool, true)

    guard case .success(let response) = result else { return XCTFail("expected success") }
    XCTAssertEqual(response.tags, ["plan": "vip"])
  }

  func test_5xxResponseRetriesThenSucceedsWithoutExhaustingTheCap() {
    StubURLProtocol.enqueue(.status(500))
    StubURLProtocol.enqueue(.status(503))
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#))

    let result = client.createOrUpdateDevice(token: "t", platform: "ios")

    XCTAssertEqual(StubURLProtocol.recordedRequests().count, 3)
    XCTAssertEqual(sleeps, [2000, 4000])
    guard case .success = result else { return XCTFail("expected success") }
  }

  func test_5xxResponsesExhaustTheRetryCapAtExactlyFiveAttempts() {
    for _ in 0..<5 { StubURLProtocol.enqueue(.status(500)) }

    let result = client.createOrUpdateDevice(token: "t", platform: "ios")

    XCTAssertEqual(StubURLProtocol.recordedRequests().count, 5)
    XCTAssertEqual(sleeps, [2000, 4000, 8000, 16000])
    guard case .failure = result else { return XCTFail("expected failure") }
  }

  func test_networkErrorIsRetriedPerTheSameBackoffSchedule() {
    for _ in 0..<5 { StubURLProtocol.enqueue(.networkError()) }

    let result = client.createOrUpdateDevice(token: "t", platform: "ios")

    XCTAssertEqual(StubURLProtocol.recordedRequests().count, 5)
    XCTAssertEqual(sleeps, [2000, 4000, 8000, 16000])
    guard case .failure = result else { return XCTFail("expected failure") }
  }

  func test_aSuccessfulResponseBeforeTheRetryCapStopsFurtherRetries() {
    StubURLProtocol.enqueue(.status(500))
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#))
    // A third enqueued response would only be consumed if the client kept retrying.
    StubURLProtocol.enqueue(.status(500))

    _ = client.createOrUpdateDevice(token: "t", platform: "ios")

    XCTAssertEqual(StubURLProtocol.recordedRequests().count, 2)
  }

  private func bodyData(_ request: URLRequest) -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open()
    defer { stream.close() }
    var data = Data()
    let bufferSize = 1024
    var buffer = [UInt8](repeating: 0, count: bufferSize)
    while stream.hasBytesAvailable {
      let read = stream.read(&buffer, maxLength: bufferSize)
      if read <= 0 { break }
      data.append(buffer, count: read)
    }
    return data
  }
}
