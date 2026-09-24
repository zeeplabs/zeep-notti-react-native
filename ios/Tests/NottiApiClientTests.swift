import XCTest

final class NottiApiClientTests: XCTestCase {

  private var client: NottiApiClient!
  private var sleeps: [UInt64] = []
  /// A `URLSession` is not released until it is invalidated, so one left
  /// behind per test keeps its delegate queue and CFNetwork worker threads
  /// alive for the rest of the process — including the whole of
  /// `NottiCoreTests`, which runs after this class and pays for it in
  /// per-request latency on a shared CI runner.
  private var sessions: [URLSession] = []

  override func setUp() {
    super.setUp()
    StubURLProtocol.reset()
    sleeps = []
    let session = stubSession()
    client = NottiApiClient(
      session: session,
      baseUrl: "https://notti.example.com",
      appId: "app-1",
      clientKey: "secret-key",
      sleeper: { ms in self.sleeps.append(ms) }
    )
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

  func test_validatedBaseUrlAcceptsAbsoluteHttpUrlsAndRejectsEverythingElse() {
    XCTAssertEqual(NottiApiClient.validatedBaseUrl("https://push.example.com"), "https://push.example.com")
    XCTAssertEqual(NottiApiClient.validatedBaseUrl("http://localhost:8080"), "http://localhost:8080")
    XCTAssertEqual(NottiApiClient.validatedBaseUrl(" https://push.example.com/// "), "https://push.example.com")

    XCTAssertNil(NottiApiClient.validatedBaseUrl("my host.example.com"))
    XCTAssertNil(NottiApiClient.validatedBaseUrl("push.example.com"))
    XCTAssertNil(NottiApiClient.validatedBaseUrl("https://"))
    XCTAssertNil(NottiApiClient.validatedBaseUrl("ftp://push.example.com"))
    XCTAssertNil(NottiApiClient.validatedBaseUrl("https://ex ample.com/%zz"))
    XCTAssertNil(NottiApiClient.validatedBaseUrl(""))
  }

  func test_anUnusableBaseUrlFailsTheCallInsteadOfCrashing() {
    // Defense in depth for the public API client: even handed a baseUrl that
    // cannot form a URL at all (invalid percent-escape here — current
    // Foundation percent-encodes most other garbage instead of returning nil),
    // it must return a failure rather than force-unwrap.
    let brokenClient = NottiApiClient(
      session: stubSession(),
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

  func test_aNonStringTagValueIsSkippedNotTheWholeDictionary() {
    // `json["tags"] as? [String: String]` used to fail the ENTIRE cast if even
    // one value wasn't a string, silently dropping every valid tag over one
    // bad value from the backend. Matches Android's per-key tolerance.
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{"plan":"vip","score":42}}"#))

    let result = client.createOrUpdateDevice(token: "t", platform: "ios")

    guard case .success(let response) = result else { return XCTFail("expected success") }
    XCTAssertEqual(response.id, "device-1")
    XCTAssertEqual(response.tags, ["plan": "vip"])
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

  func test_everyRequestCarriesAnExplicitShortTimeoutInsteadOfTheUrlSessionDefault() {
    // Inherited from URLSession's 60s default, a black-holing network held
    // NottiCore's serial work queue for ~5.5 minutes across the retry cap,
    // stalling every queued login/addTags/setSubscription behind it. Android
    // uses OkHttp's 10s defaults; iOS must be in the same order of magnitude.
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#))
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{}}"#))

    _ = client.createOrUpdateDevice(token: "t", platform: "ios")
    _ = client.patchDevice(deviceId: "device-1", token: "t", fields: [:])

    let recorded = StubURLProtocol.recordedRequests()
    XCTAssertEqual(recorded.count, 2)
    for request in recorded {
      XCTAssertLessThanOrEqual(
        request.timeoutInterval, 15,
        "\(request.httpMethod ?? "?") must not inherit URLSession's 60s default"
      )
      XCTAssertGreaterThan(request.timeoutInterval, 0)
    }
  }

  func test_a2xxWhoseBodyIsNotADeviceObjectIsAFailureAndIsRetried() {
    // A captive portal / proxy / gateway happily answers 200 with HTML, and a
    // backend can rename or omit `id`. Reporting that as success handed the
    // caller a device with an empty id.
    let garbageBodies = [
      "<html><body>Sign in to the WiFi</body></html>", // not JSON at all
      #"{"device_id":"device-1"}"#, // renamed field: no `id`
      #"{"id":"","tags":{}}"#, // present but empty
      #"{"id":123}"#, // wrong type
      "", // empty body
    ]

    for body in garbageBodies {
      StubURLProtocol.reset()
      sleeps = []
      for _ in 0..<5 { StubURLProtocol.enqueue(.status(200, body: body)) }

      let result = client.createOrUpdateDevice(token: "t", platform: "ios")

      guard case .failure = result else {
        return XCTFail("a 200 with body '\(body)' must not be reported as success")
      }
      XCTAssertEqual(StubURLProtocol.recordedRequests().count, 5, "body '\(body)' must be retried like a 5xx")
      XCTAssertEqual(sleeps, [2000, 4000, 8000, 16000])
    }
  }

  func test_patchAcceptsA2xxAcknowledgementWithNoDeviceObjectWithoutRetrying() {
    // PATCH updates an existing device: the id is the caller's own input, not
    // something the response has to hand back. `204 No Content`, an empty 200
    // and a bare ACK object are all normal REST answers to an update, and
    // rejecting them cost five retries plus the local persistence of
    // external_user_id/tags.
    let acknowledgements: [(Int, String)] = [
      (204, ""),
      (200, ""),
      (200, #"{"ok":true}"#),
      (202, "OK"),
    ]

    for (status, body) in acknowledgements {
      StubURLProtocol.reset()
      sleeps = []
      StubURLProtocol.enqueue(.status(status, body: body))

      let result = client.patchDevice(deviceId: "device-1", token: "t", fields: ["external_user_id": "user-42"])

      guard case .success(let response) = result else {
        return XCTFail("PATCH answered \(status) '\(body)' must be a success")
      }
      XCTAssertEqual(response.id, "device-1", "the id stays the one that was patched")
      XCTAssertEqual(
        StubURLProtocol.recordedRequests().count, 1,
        "\(status) '\(body)' must not be retried"
      )
      XCTAssertEqual(sleeps, [], "\(status) '\(body)' must not back off")
    }
  }

  func test_patchAcknowledgedWithNoBodyReportsBackTheTagsItJustSent() {
    // NottiCore writes `response.tags` into its local cache after a tag
    // mutation — an empty ACK must not read as "the device now has no tags".
    StubURLProtocol.enqueue(.status(204))

    let result = client.patchDevice(deviceId: "device-1", token: "t", fields: ["tags": ["plan": "vip"]])

    guard case .success(let response) = result else { return XCTFail("expected success") }
    XCTAssertEqual(response.tags, ["plan": "vip"])
  }

  func test_patchPrefersTheDeviceObjectWhenTheBackendDoesReturnOne() {
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{"plan":"gold"}}"#))

    let result = client.patchDevice(deviceId: "device-1", token: "t", fields: ["tags": ["plan": "vip"]])

    guard case .success(let response) = result else { return XCTFail("expected success") }
    XCTAssertEqual(response.tags, ["plan": "gold"], "the server's view of the tags wins over the sent one")
  }

  func test_patchStillTreatsA4xxAsTerminalAndA5xxAsRetriable() {
    StubURLProtocol.enqueue(.status(403))
    guard case .failure = client.patchDevice(deviceId: "device-1", token: "t", fields: [:]) else {
      return XCTFail("a 403 PATCH is still a failure")
    }
    XCTAssertEqual(StubURLProtocol.recordedRequests().count, 1)

    StubURLProtocol.reset()
    sleeps = []
    for _ in 0..<5 { StubURLProtocol.enqueue(.status(503)) }
    guard case .failure = client.patchDevice(deviceId: "device-1", token: "t", fields: [:]) else {
      return XCTFail("a 503 PATCH is still a failure")
    }
    XCTAssertEqual(StubURLProtocol.recordedRequests().count, 5)
    XCTAssertEqual(sleeps, [2000, 4000, 8000, 16000])
  }

  func test_anUnparseable2xxThatLaterTurnsIntoAValidBodySucceeds() {
    StubURLProtocol.enqueue(.status(200, body: "<html>captive portal</html>"))
    StubURLProtocol.enqueue(.status(200, body: #"{"id":"device-1","tags":{"plan":"vip"}}"#))

    let result = client.createOrUpdateDevice(token: "t", platform: "ios")

    XCTAssertEqual(StubURLProtocol.recordedRequests().count, 2)
    guard case .success(let response) = result else { return XCTFail("expected success") }
    XCTAssertEqual(response.id, "device-1")
    XCTAssertEqual(response.tags, ["plan": "vip"])
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
