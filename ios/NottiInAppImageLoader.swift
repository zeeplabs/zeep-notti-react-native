#if canImport(UIKit)
import ImageIO
import UIKit

/// Image port of the presenter. `done` may run on any thread; nil means "no image".
protocol InAppImageSource: AnyObject {
  func load(url: String, maxSidePx: CGFloat, done: @escaping (UIImage?) -> Void)
}

/// Downloads `image_url` (SDKIAM-57, A10). The host is chosen by the message
/// author, so the request goes through a dedicated session: no Notti header,
/// no cookies, no cache, no identifiers, no redirect to a non-`https` URL.
/// Bounded in time and size, decoded downsampled, cached in memory only. Any
/// failure is "no image", never an error of the message. Never logs the URL.
final class NottiInAppImageLoader: InAppImageSource {

  static let timeout: TimeInterval = 10
  static let maxBytes = 5 * 1024 * 1024
  static let cacheEntries = 5

  private let maxBytes: Int
  private let timeout: TimeInterval
  private let makeSession: (URLSessionConfiguration, URLSessionDelegate, OperationQueue) -> URLSession
  private let center: NotificationCenter
  private var memoryObserver: NSObjectProtocol?

  private let lock = NSLock()
  /// Oldest first; at most `cacheEntries`.
  private var cache: [(url: String, image: UIImage)] = []

  /// `makeSession` lets tests add their `URLProtocol` to the configuration.
  init(
    maxBytes: Int = NottiInAppImageLoader.maxBytes,
    timeout: TimeInterval = NottiInAppImageLoader.timeout,
    makeSession: @escaping (URLSessionConfiguration, URLSessionDelegate, OperationQueue) -> URLSession = {
      URLSession(configuration: $0, delegate: $1, delegateQueue: $2)
    },
    center: NotificationCenter = .default
  ) {
    self.maxBytes = maxBytes
    self.timeout = timeout
    self.makeSession = makeSession
    self.center = center
    memoryObserver = center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil) {
      [weak self] _ in self?.clear()
    }
  }

  deinit {
    if let observer = memoryObserver { center.removeObserver(observer) }
  }

  /// The credential-free configuration: no cookies, no cache, no credentials.
  static func configuration(timeout: TimeInterval = NottiInAppImageLoader.timeout) -> URLSessionConfiguration {
    let config = URLSessionConfiguration.ephemeral
    config.httpCookieStorage = nil
    config.httpShouldSetCookies = false
    config.httpCookieAcceptPolicy = .never
    config.urlCache = nil
    config.urlCredentialStorage = nil
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    config.timeoutIntervalForRequest = timeout
    config.timeoutIntervalForResource = timeout
    config.httpAdditionalHeaders = [:]
    return config
  }

  static func isHttps(_ url: String) -> Bool {
    guard let parsed = URL(string: url), parsed.scheme?.lowercased() == "https", parsed.host?.isEmpty == false else {
      return false
    }
    return true
  }

  func load(url: String, maxSidePx: CGFloat, done: @escaping (UIImage?) -> Void) {
    if let hit = cached(url) {
      done(hit)
      return
    }
    // Rejected before any connection.
    guard Self.isHttps(url), let target = URL(string: url) else {
      done(nil)
      return
    }
    let download = Download(maxBytes: maxBytes, timeout: timeout) { [weak self] data in
      let image = data.flatMap { Self.decode($0, maxSidePx: maxSidePx) }
      if let image = image { self?.store(url, image) }
      done(image)
    }
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 1
    let session = makeSession(Self.configuration(timeout: timeout), download, queue)
    var request = URLRequest(url: target, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
    request.httpShouldHandleCookies = false
    download.start(session.dataTask(with: request), session: session)
  }

  /// Drops the cached images (low memory).
  func clear() {
    lock.lock()
    cache.removeAll()
    lock.unlock()
  }

  private func cached(_ url: String) -> UIImage? {
    lock.lock(); defer { lock.unlock() }
    guard let index = cache.firstIndex(where: { $0.url == url }) else { return nil }
    let entry = cache.remove(at: index)
    cache.append(entry)
    return entry.image
  }

  private func store(_ url: String, _ image: UIImage) {
    lock.lock(); defer { lock.unlock() }
    cache.removeAll { $0.url == url }
    cache.append((url, image))
    while cache.count > Self.cacheEntries { cache.removeFirst() }
  }

  /// Full size when the longest side fits `maxSidePx`, else downsampled
  /// (ImageIO never inflates the whole bitmap first). Always decoded through
  /// the thumbnail path, the only one that applies the EXIF orientation: a
  /// small photo is upright too. Nil when the bytes are not an image.
  static func decode(_ data: Data, maxSidePx: CGFloat) -> UIImage? {
    let options = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let source = CGImageSourceCreateWithData(data as CFData, options),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int,
      width > 0, height > 0
    else { return nil }
    let longest = CGFloat(max(width, height))
    // Never upscaled: the longest side is the ceiling.
    let maxPixelSize = maxSidePx > 0 ? min(longest, maxSidePx) : longest
    let cgImage = CGImageSourceCreateThumbnailAtIndex(
      source,
      0,
      [
        // An embedded (smaller) thumbnail is never used: always the full image.
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
      ] as CFDictionary
    )
    return cgImage.map { UIImage(cgImage: $0) }
  }

  /// One request: bounded in size and time, `https` only, ends exactly once.
  private final class Download: NSObject, URLSessionDataDelegate {

    private let maxBytes: Int
    private let timeout: TimeInterval
    private let finish: (Data?) -> Void
    private let lock = NSLock()
    private var buffer = Data()
    private var finished = false
    private var task: URLSessionDataTask?
    private var session: URLSession?
    private var timer: DispatchWorkItem?
    private var accepted = false

    init(maxBytes: Int, timeout: TimeInterval, finish: @escaping (Data?) -> Void) {
      self.maxBytes = maxBytes
      self.timeout = timeout
      self.finish = finish
    }

    func start(_ task: URLSessionDataTask, session: URLSession) {
      self.task = task
      self.session = session
      // The whole call is bounded, not only each read.
      let timer = DispatchWorkItem { [weak self] in self?.end(nil) }
      self.timer = timer
      DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
      task.resume()
    }

    /// First outcome wins; the task and the session are released.
    private func end(_ data: Data?) {
      lock.lock()
      if finished {
        lock.unlock()
        return
      }
      finished = true
      lock.unlock()
      timer?.cancel()
      task?.cancel()
      session?.invalidateAndCancel()
      finish(data)
    }

    func urlSession(
      _ session: URLSession,
      task: URLSessionTask,
      willPerformHTTPRedirection response: HTTPURLResponse,
      newRequest request: URLRequest,
      completionHandler: @escaping (URLRequest?) -> Void
    ) {
      // https -> https is followed; https -> http is refused.
      if request.url?.scheme?.lowercased() == "https" {
        var next = request
        next.httpShouldHandleCookies = false
        completionHandler(next)
      } else {
        completionHandler(nil)
        end(nil)
      }
    }

    func urlSession(
      _ session: URLSession,
      dataTask: URLSessionDataTask,
      didReceive response: URLResponse,
      completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
      guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
        http.url?.scheme?.lowercased() == "https",
        http.expectedContentLength <= Int64(maxBytes)
      else {
        completionHandler(.cancel)
        end(nil)
        return
      }
      accepted = true
      completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
      guard accepted else { return }
      buffer.append(data)
      // Aborted as soon as the body passes the limit: the rest is never read.
      if buffer.count > maxBytes { end(nil) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
      end(error == nil && accepted ? buffer : nil)
    }
  }
}
#endif
