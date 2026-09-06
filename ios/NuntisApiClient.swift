import Foundation

public struct DeviceResponse {
  public let id: String
  public let tags: [String: String]
}

public enum ApiResult {
  case success(DeviceResponse)
  case failure(String)
}

private struct NuntisApiClientTimeoutError: Error, LocalizedError {
  var errorDescription: String? { "Nuntis API request timed out" }
}

/// Talks to Nuntis' `/v1/apps/{app_id}/devices` endpoints (design.md
/// NuntisApiClient). Retries a 5xx response or network failure with
/// exponential backoff (2s, 4s, 8s, 16s, 32s), capped at 5 attempts, per
/// design.md's Tech Decisions — mirrors `NuntisApiClient.kt` exactly.
/// `sleeper` is injectable so tests can skip the real delay; production
/// callers use the default (real thread sleep via `Thread.sleep`).
///
/// **Threading**: every method here blocks the calling thread — for up to
/// 5x15s of request timeouts plus 2+4+8+16s of backoff on a dead network.
/// It must therefore only ever be called from `NuntisCore`'s private serial
/// work queue, never from the main thread (see NuntisCore's threading
/// contract). Nothing in this file may be invoked directly from an
/// `AppDelegate`/TurboModule entry point.
public class NuntisApiClient {

  private static let maxAttempts = 5
  private static let baseDelayMs: UInt64 = 2000

  /// Per-attempt request timeout. Same order of magnitude as Android's
  /// `OkHttpClient()` defaults (10s connect/read/write) so a black-holing
  /// network fails fast on both platforms. Set explicitly on every request
  /// rather than inherited from `URLSession.shared`'s 60s default: this call
  /// chain is blocking and owns `NuntisCore`'s serial work queue for its whole
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
      scheme == "http" || scheme == "https",
      let host = url.host,
      !host.isEmpty
    else {
      return nil
    }

    var normalized = trimmed
    while normalized.hasSuffix("/") { normalized.removeLast() }
    return normalized.isEmpty ? nil : normalized
  }

  public func createOrUpdateDevice(token: String, platform: String) -> ApiResult {
    let body: [String: Any] = ["token": token, "platform": platform]
    guard let url = URL(string: "\(baseUrl)/v1/apps/\(appId)/devices") else {
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
    return executeWithRetry(request, parseSuccess: parseDeviceResponse)
  }

  /// PATCH always includes the cached `token` field (AD-009 ownership proof).
  public func patchDevice(deviceId: String, token: String, fields: [String: Any]) -> ApiResult {
    var json = fields
    json["token"] = token

    guard let url = URL(string: "\(baseUrl)/v1/apps/\(appId)/devices/\(deviceId)") else {
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
    return executeWithRetry(request) { [weak self] data in
      if let device = self?.parseDeviceResponse(data) { return device }
      return DeviceResponse(id: deviceId, tags: (fields["tags"] as? [String: String]) ?? [:])
    }
  }

  /// `parseSuccess` turns a 2xx body into the `DeviceResponse` to report, or
  /// nil to treat that 2xx as a retriable failure.
  private func executeWithRetry(
    _ request: URLRequest,
    parseSuccess: (Data) -> DeviceResponse?
  ) -> ApiResult {
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
          if let device = parseSuccess(data ?? Data()) {
            return .success(device)
          }
          lastError = "HTTP \(http.statusCode) with an unparseable device response body"
        } else if http.statusCode < 500 {
          // 4xx: not retried, terminal failure.
          return .failure("HTTP \(http.statusCode)")
        } else {
          lastError = "HTTP \(http.statusCode)"
        }
      }

      if attempt < Self.maxAttempts {
        sleeper(delayMs)
        delayMs *= 2
      }
    }

    return .failure(lastError)
  }

  private func syncDataTask(_ request: URLRequest) -> (Data?, URLResponse?, Error?) {
    let semaphore = DispatchSemaphore(value: 0)
    var resultData: Data?
    var resultResponse: URLResponse?
    var resultError: Error?

    session.dataTask(with: request) { data, response, error in
      resultData = data
      resultResponse = response
      resultError = error
      semaphore.signal()
    }.resume()

    // Independent bound on top of the request's own timeoutInterval - if a
    // session is ever passed in that never completes the task, this still
    // guarantees executeWithRetry's retry loop resumes instead of hanging
    // indefinitely (SDK reliability fix - see
    // .specs/features/sdk-core-v1/validation.md Fix 4).
    if semaphore.wait(timeout: .now() + Self.semaphoreTimeoutSeconds) == .timedOut {
      return (nil, nil, NuntisApiClientTimeoutError())
    }
    return (resultData, resultResponse, resultError)
  }

  /// Returns nil when the body is not a device object — no JSON, no `id`, or
  /// an empty `id`. Callers must treat nil as a failed request rather than
  /// substituting an empty `DeviceResponse`.
  private func parseDeviceResponse(_ data: Data) -> DeviceResponse? {
    guard
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let id = json["id"] as? String,
      !id.isEmpty
    else {
      return nil
    }
    let tags = (json["tags"] as? [String: String]) ?? [:]
    return DeviceResponse(id: id, tags: tags)
  }
}
