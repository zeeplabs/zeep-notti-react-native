import Foundation

/// Records every request it intercepts and serves back a queued canned
/// response (or a network error) per call, in FIFO order — the iOS
/// equivalent of Android's `MockWebServer` used by `NottiApiClientTest.kt`.
/// Call `StubURLProtocol.reset()` between tests to clear state.
final class StubURLProtocol: URLProtocol {

  struct StubResponse {
    let statusCode: Int?
    let body: Data?
    let error: Error?
    let delayMs: Int
    /// Answer like the real backend's PATCH: a device whose fields echo the
    /// request body (`token` excluded). Overrides `body`.
    var echoDevice: Bool = false

    static func status(_ code: Int, body: String = "", delayMs: Int = 0) -> StubResponse {
      StubResponse(statusCode: code, body: body.data(using: .utf8), error: nil, delayMs: delayMs)
    }

    static func echoDevice() -> StubResponse {
      StubResponse(statusCode: 200, body: nil, error: nil, delayMs: 0, echoDevice: true)
    }

    static func networkError() -> StubResponse {
      StubResponse(statusCode: nil, body: nil, error: URLError(.notConnectedToInternet), delayMs: 0)
    }
  }

  private static let lock = NSLock()
  private static var queue: [StubResponse] = []
  private static var recorded: [URLRequest] = []

  static func enqueue(_ response: StubResponse) {
    lock.lock(); defer { lock.unlock() }
    queue.append(response)
  }

  static func recordedRequests() -> [URLRequest] {
    lock.lock(); defer { lock.unlock() }
    return recorded
  }

  static func reset() {
    lock.lock(); defer { lock.unlock() }
    queue.removeAll()
    recorded.removeAll()
  }

  private static func dequeue() -> StubResponse? {
    lock.lock(); defer { lock.unlock() }
    guard !queue.isEmpty else { return nil }
    return queue.removeFirst()
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    // URLSession hands the body over as a one-shot stream; materialize it so
    // both the echo below and tests reading `recordedRequests()` can see it.
    let sentBody = Self.readBody(request)
    var recordedRequest = request
    recordedRequest.httpBody = sentBody
    Self.lock.lock()
    Self.recorded.append(recordedRequest)
    Self.lock.unlock()

    guard let stub = Self.dequeue() else {
      client?.urlProtocol(self, didFailWithError: URLError(.unknown))
      return
    }

    if let error = stub.error {
      client?.urlProtocol(self, didFailWithError: error)
      return
    }

    if stub.delayMs > 0 {
      Thread.sleep(forTimeInterval: TimeInterval(stub.delayMs) / 1000.0)
    }

    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: stub.statusCode ?? 200,
      httpVersion: "HTTP/1.1",
      headerFields: nil
    )!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    if stub.echoDevice {
      var echo: [String: Any] = ["id": "device-1", "tags": [String: String]()]
      if let sent = try? JSONSerialization.jsonObject(with: sentBody) as? [String: Any] {
        for (key, value) in sent where key != "token" { echo[key] = value }
      }
      client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: echo))
    } else if let body = stub.body {
      client?.urlProtocol(self, didLoad: body)
    }
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}

  private static func readBody(_ request: URLRequest) -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 1024)
    while stream.hasBytesAvailable {
      let read = stream.read(&buffer, maxLength: buffer.count)
      if read <= 0 { break }
      data.append(buffer, count: read)
    }
    return data
  }
}
