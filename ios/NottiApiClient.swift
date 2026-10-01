import Foundation

public struct DeviceResponse {
  public let id: String
  public let tags: [String: String]
}

public enum ApiResult {
  case success(DeviceResponse)
  case failure(String)
}

public enum EventResult {
  case success
  /// `terminal` is true only for a 4xx the backend will never accept (the
  /// offline queue discards the event), false when the retry cap was
  /// exhausted on transient network/5xx/408/429 errors (the event stays queued).
  case failure(String, terminal: Bool)
}

/// The endpoint-agnostic result of `executeWithRetry`: `success(T)` carries
/// whatever the caller's `parseSuccess` produced, `failure(String, terminal)`
/// a terminal 4xx status (terminal = true) or the last error after the retry
/// cap was exhausted (terminal = false).
private enum RetryResult<T> {
  case success(T)
  case failure(String, terminal: Bool)
}

private struct NottiApiClientTimeoutError: Error, LocalizedError {
  var errorDescription: String? { "Notti API request timed out" }
}

/// Talks to Notti' `/v1/apps/{app_id}/devices` endpoints (design.md
/// NottiApiClient). Retries a 5xx response or network failure with
/// exponential backoff (2s, 4s, 8s, 16s), capped at 5 attempts, per
/// design.md's Tech Decisions — mirrors `NottiApiClient.kt` exactly.
/// `sleeper` is injectable so tests can skip the real delay; production
/// callers use the default (real thread sleep via `Thread.sleep`).
///
/// **Threading**: every method here blocks the calling thread — for up to
/// 5x15s of request timeouts plus 2+4+8+16s of backoff on a dead network.
/// It must therefore only ever be called from `NottiCore`'s private serial
/// work queue, never from the main thread (see NottiCore's threading
/// contract). Nothing in this file may be invoked directly from an
/// `AppDelegate`/TurboModule entry point.
public class NottiApiClient {

  private static let maxAttempts = 5
  private static let baseDelayMs: UInt64 = 2000

  /// See `validatedBaseUrl`'s A5 doc-comment. `true` only in debug builds,
  /// so a plain-`http` `baseUrl` never silently works in a release build a
  /// real user runs.
  private static var allowsInsecureScheme: Bool {
    #if DEBUG
      return true
    #else
      return false
    #endif
  }

  /// Per-attempt request timeout. Same order of magnitude as Android's
  /// `OkHttpClient()` defaults (10s connect/read/write) so a black-holing
  /// network fails fast on both platforms. Set explicitly on every request
  /// rather than inherited from `URLSession.shared`'s 60s default: this call
  /// chain is blocking and owns `NottiCore`'s serial work queue for its whole
  /// duration, so every queued login/addTags/setSubscription waits it out.
  private static let requestTimeoutSeconds: TimeInterval = 15
  /// Backstop for the semaphore below, above `requestTimeoutSeconds` so
  /// `URLSession`'s own timeout is what normally fires. Only reached if a
  /// caller-supplied session never completes its task at all.
  private static let semaphoreTimeoutSeconds: TimeInterval = 20

  private let session: URLSession
  private let baseUrl: String
  private let appId: String
  private let clientKey: String
  private let sleeper: (UInt64) -> Void

  public init(
    session: URLSession = .shared,
    baseUrl: String,
    appId: String,
    clientKey: String,
    sleeper: @escaping (UInt64) -> Void = { ms in Thread.sleep(forTimeInterval: TimeInterval(ms) / 1000.0) }
  ) {
    self.session = session
    self.baseUrl = baseUrl
    self.appId = appId
    self.clientKey = clientKey
    self.sleeper = sleeper
  }

  /// Validates and normalizes an integrator-supplied `baseUrl` (spec SDK-03:
  /// invalid config must be non-fatal). Requires an absolute `http`/`https`
  /// URL with a host — a malformed-but-non-empty string such as
  /// `"my host.example.com"` or a scheme-less `"push.example.com"` is
  /// rejected here rather than force-unwrapped into a crash later. Returns
  /// the string with trailing slashes trimmed, or nil when unusable.
  public static func validatedBaseUrl(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      !trimmed.isEmpty,
      let url = URL(string: trimmed),
      let scheme = url.scheme?.lowercased(),
      // A5 (found in pre-release review): plain `http://` was accepted with
      // no opt-in, sending the client-key bearer token, the push token, and
      // the external_user_id over cleartext for a healthtech SDK. `https`
      // only in release builds; `http` stays available in debug builds only
      // (local dev servers, emulator-only backends).
      scheme == "https" || (scheme == "http" && Self.allowsInsecureScheme),
      let host = url.host,
      !host.isEmpty
    else {
      return nil
    }

    var normalized = trimmed
    while normalized.hasSuffix("/") { normalized.removeLast() }
    return normalized.isEmpty ? nil : normalized
  }

  /// A6 (found in pre-release review): `appId`/the server-returned `deviceId`
  /// were interpolated into the request path with no percent-encoding. A
  /// `deviceId` containing a space or `/` (a misbehaving/compromised
  /// backend) made `URL(string:)` return nil forever after, permanently
  /// bricking every later PATCH for that device with no recovery path.
  private static func percentEncodedPathComponent(_ raw: String) -> String? {
    raw.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/")))
  }

  public func createOrUpdateDevice(token: String, platform: String) -> ApiResult {
    let body: [String: Any] = ["token": token, "platform": platform]
    guard
      let encodedAppId = Self.percentEncodedPathComponent(appId),
      let url = URL(string: "\(baseUrl)/v1/apps/\(encodedAppId)/devices")
    else {
      return .failure("invalid device-registration URL built from the configured baseUrl")
    }
    var request = URLRequest(url: url, timeoutInterval: Self.requestTimeoutSeconds)
    request.httpMethod = "POST"
    request.setValue("Bearer \(clientKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONSerialization.data(withJSONObject: body)

    // Registration is the one call that *depends* on the response body: the
    // `id` it returns is the resource every later PATCH is addressed to, so a
    // 2xx without a device object is not a usable success.
    return apiResult(executeWithRetry(request) { data in self.parseDeviceResponse(data, fallbackTags: nil) })
  }

  /// PATCH always includes the cached `token` field (AD-009 ownership proof).
  public func patchDevice(deviceId: String, token: String, fields: [String: Any]) -> ApiResult {
    var json = fields
    json["token"] = token
    let fallbackTags = (fields["tags"] as? [String: String]) ?? [:]

    guard
      let encodedAppId = Self.percentEncodedPathComponent(appId),
      let encodedDeviceId = Self.percentEncodedPathComponent(deviceId),
      let url = URL(string: "\(baseUrl)/v1/apps/\(encodedAppId)/devices/\(encodedDeviceId)")
    else {
      return .failure("invalid device-update URL built from the configured baseUrl")
    }
    var request = URLRequest(url: url, timeoutInterval: Self.requestTimeoutSeconds)
    request.httpMethod = "PATCH"
    request.setValue("Bearer \(clientKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONSerialization.data(withJSONObject: json)

    // Unlike registration, PATCH creates nothing: the caller already knows the
    // device id it addressed and the field values it just applied. A REST
    // backend is free to acknowledge it with `204 No Content`, an empty body
    // or a bare `{"ok":true}`, so requiring a full device object here turned
    // a perfectly good update into five retries and dropped the local
    // persistence of `external_user_id`/tags. Any 2xx is accepted; the body is
    // used when it happens to carry a device object, and otherwise the request
    // itself is the source of truth.
    return apiResult(executeWithRetry(request) { [weak self] data in
      if let device = self?.parseDeviceResponse(data, fallbackTags: fallbackTags) { return device }
      return DeviceResponse(id: deviceId, tags: fallbackTags)
    })
  }

  /// Reports a single push-notification lifecycle event (design.md offline
  /// event queue flush — `NottiEventStore`'s `PendingEvent` maps onto
  /// `notificationId`/`deliveryId`/`type`; `token` is the push token of the
  /// device that received/clicked). Fire-and-forget like `patchDevice`: a
  /// REST backend is free to acknowledge the event with `204 No Content`, an
  /// empty `200` or a bare `{"ok":true}`, so any 2xx is a success and the
  /// body is ignored. Shares `executeWithRetry`'s policy — 4xx terminal
  /// (except 408/429), network error/5xx/408/429 retried, 5-attempt cap with 2s/4s/8s/16s backoff.
  public func reportEvent(notificationId: String, deliveryId: String, type: String, token: String) -> EventResult {
    let body: [String: Any] = ["delivery_id": deliveryId, "type": type, "token": token]
    guard
      let encodedAppId = Self.percentEncodedPathComponent(appId),
      let encodedNotificationId = Self.percentEncodedPathComponent(notificationId),
      let url = URL(string: "\(baseUrl)/v1/apps/\(encodedAppId)/notifications/\(encodedNotificationId)/events")
    else {
      return .failure("invalid event-reporting URL built from the configured baseUrl", terminal: true)
    }
    var request = URLRequest(url: url, timeoutInterval: Self.requestTimeoutSeconds)
    request.httpMethod = "POST"
    request.setValue("Bearer \(clientKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONSerialization.data(withJSONObject: body)

    // Any 2xx is a usable success here, so `parseSuccess` always returns
    // non-nil and a 2xx is never retried.
    return eventResult(executeWithRetry(request) { _ in true })
  }

  /// Maps the shared retry result back to the public `ApiResult` contract.
  private func apiResult(_ result: RetryResult<DeviceResponse>) -> ApiResult {
    switch result {
    case .success(let device): return .success(device)
    case .failure(let message, _): return .failure(message)
    }
  }

  /// Maps the shared retry result back to the public `EventResult` contract.
  private func eventResult(_ result: RetryResult<Bool>) -> EventResult {
    switch result {
    case .success: return .success
    case .failure(let message, let terminal): return .failure(message, terminal: terminal)
    }
  }

  /// `parseSuccess` turns a 2xx body into the value to report, or nil to
  /// treat that 2xx as a retriable failure. Generic so every endpoint shares
  /// the same policy: device calls map `RetryResult<DeviceResponse>` to
  /// `ApiResult`, `reportEvent` maps `RetryResult<Bool>` to `EventResult`.
  private func executeWithRetry<T>(
    _ request: URLRequest,
    parseSuccess: (Data) -> T?
  ) -> RetryResult<T> {
    var attempt = 0
    var delayMs = Self.baseDelayMs
    var lastError = "unknown error"

    while attempt < Self.maxAttempts {
      attempt += 1
      let (data, response, error) = syncDataTask(request)

      if let error = error {
        lastError = error.localizedDescription
      } else if let http = response as? HTTPURLResponse {
        if (200..<300).contains(http.statusCode) {
          // What a 2xx body has to contain is per-endpoint (`parseSuccess`).
          // For registration, a body that is not a device object (captive
          // portal/proxy HTML, a renamed/missing `id` field, truncated JSON)
          // is *not* a success: reporting one made the caller persist an empty
          // deviceId and wipe its local tags, then build every later request
          // against `.../devices/` — a wrong resource. Such a 2xx is treated
          // as a retriable failure instead, exactly like a 5xx.
          if let value = parseSuccess(data ?? Data()) {
            return .success(value)
          }
          lastError = "HTTP \(http.statusCode) with an unparseable response body"
        } else if http.statusCode < 500 && !Self.isTransientClientError(http.statusCode) {
          // 4xx: not retried, terminal failure. Marked terminal so the
          // offline queue can discard the event - the backend will never
          // accept it, so keeping it would re-fail forever on every flush.
          return .failure("HTTP \(http.statusCode)", terminal: true)
        } else {
          // 5xx, 408 Request Timeout and 429 Too Many Requests: transient,
          // retried with the same backoff and non-terminal once the cap is hit.
          lastError = "HTTP \(http.statusCode)"
        }
      }

      if attempt < Self.maxAttempts {
        sleeper(delayMs)
        delayMs *= 2
      }
    }

    // Retry cap exhausted on transient (network/5xx/408/429) failures only - any other 4xx
    // would have returned above. Not terminal: the event stays queued.
    return .failure(lastError, terminal: false)
  }

  /// 408/429 are 4xx codes that describe a *temporary* condition (the
  /// request may succeed later, unchanged), so they are retried and never
  /// make an offline event terminal. Every other 4xx stays terminal. Aligned
  /// with Android (pre-release review): refines SDKCTR-11, which previously
  /// treated every 4xx as terminal.
  /// Status codes a device PATCH can fail with that retrying the same
  /// request will never fix (401/403: credentials; 404: device gone).
  static let permanentClientErrorStatuses: Set<Int> = [401, 403, 404]

  /// Recovers a permanent 4xx from an `ApiResult.failure` message. Coupled to
  /// the `"HTTP \(code)"` string `executeWithRetry` returns for a terminal 4xx
  /// (this file) - `ApiResult` is public and carries no status, so changing
  /// its shape would be a source-breaking change for this one diagnostic.
  /// 408/429 never match (retried, and not in the set).
  static func permanentClientErrorStatus(_ failureMessage: String) -> Int? {
    let prefix = "HTTP "
    guard failureMessage.hasPrefix(prefix),
      let status = Int(failureMessage.dropFirst(prefix.count)),
      permanentClientErrorStatuses.contains(status)
    else { return nil }
    return status
  }

  static func isTransientClientError(_ statusCode: Int) -> Bool {
    statusCode == 408 || statusCode == 429
  }

  private func syncDataTask(_ request: URLRequest) -> (Data?, URLResponse?, Error?) {
    let semaphore = DispatchSemaphore(value: 0)
    let lock = NSLock()
    // A4 (found in pre-release review): the timeout branch below used to
    // return while the in-flight task's completion handler could still fire
    // later (on the session's delegate queue) and write into these captured
    // boxes with no synchronization - a genuine data race. `completed`,
    // guarded by `lock`, makes the two sides mutually exclusive: whichever
    // reaches the lock first "wins" and the other's write/read is skipped.
    var completed = false
    var resultData: Data?
    var resultResponse: URLResponse?
    var resultError: Error?

    let task = session.dataTask(with: request) { data, response, error in
      lock.lock()
      defer { lock.unlock() }
      guard !completed else { return }
      completed = true
      resultData = data
      resultResponse = response
      resultError = error
      semaphore.signal()
    }
    task.resume()

    // Independent bound on top of the request's own timeoutInterval - if a
    // session is ever passed in that never completes the task, this still
    // guarantees executeWithRetry's retry loop resumes instead of hanging
    // indefinitely (SDK reliability fix - see
    // .specs/features/sdk-core-v1/validation.md Fix 4).
    if semaphore.wait(timeout: .now() + Self.semaphoreTimeoutSeconds) == .timedOut {
      lock.lock()
      let alreadyCompleted = completed
      completed = true
      lock.unlock()
      if !alreadyCompleted {
        task.cancel()
      }
      return (nil, nil, NottiApiClientTimeoutError())
    }

    lock.lock()
    defer { lock.unlock() }
    return (resultData, resultResponse, resultError)
  }

  /// Returns nil when the body is not a device object — no JSON, no `id`, or
  /// an empty `id`. Callers must treat nil as a failed request rather than
  /// substituting an empty `DeviceResponse`.
  ///
  /// `fallbackTags`, when non-nil, is what the caller optimistically applied
  /// to the PATCH about to be acknowledged. A PATCH ack is allowed to omit
  /// `tags` entirely (a REST backend answering `204 No Content` or a bare
  /// `{"id":"dev_1"}` per the comment above `patchDevice`) - treating that
  /// absence the same as an explicit `"tags":{}` silently wiped the local tag
  /// cache on every such ack, on a call that never touched tags at all (found
  /// by pre-release review, A3). Only a `tags` key that is actually present
  /// *and* a JSON object is treated as the server's authoritative answer,
  /// including an explicit `{}` clearing everything; absent, null, or a
  /// malformed value all fall back to what was just applied. Matches
  /// Android's `NottiApiClient.kt`'s `parseDeviceResponse`.
  private func parseDeviceResponse(_ data: Data, fallbackTags: [String: String]?) -> DeviceResponse? {
    guard
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let id = json["id"] as? String,
      !id.isEmpty
    else {
      return nil
    }
    // Per-key filtering rather than `json["tags"] as? [String: String]`: that
    // cast fails the ENTIRE dictionary if even one value isn't a string,
    // silently dropping every valid tag over one bad value. Matches Android's
    // per-key tolerance (see NottiApiClient.kt's parseDeviceResponse).
    let tags: [String: String]
    if let rawTags = json["tags"] as? [String: Any] {
      tags = rawTags.compactMapValues { $0 as? String }
    } else {
      tags = fallbackTags ?? [:]
    }
    return DeviceResponse(id: id, tags: tags)
  }
}
