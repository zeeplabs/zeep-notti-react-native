import Foundation

/// Records every request it intercepts and serves back a queued canned
/// response (or a network error) per call, in FIFO order — the iOS
/// equivalent of Android's `MockWebServer` used by `NuntisApiClientTest.kt`.
/// Call `StubURLProtocol.reset()` between tests to clear state.
final class StubURLProtocol: URLProtocol {

  struct StubResponse {
    let statusCode: Int?
    let body: Data?
    let error: Error?
    let delayMs: Int

    static func status(_ code: Int, body: String = "", delayMs: Int = 0) -> StubResponse {
      StubResponse(statusCode: code, body: body.data(using: .utf8), error: nil, delayMs: delayMs)
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
    Self.lock.lock()
    Self.recorded.append(request)
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
    if let body = stub.body {
      client?.urlProtocol(self, didLoad: body)
    }
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}
