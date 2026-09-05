import Foundation

public struct DeviceResponse {
  public let id: String
  public let tags: [String: String]
}

public enum ApiResult {
  case success(DeviceResponse)
  case failure(String)
}

/// Talks to Nuntis' `/v1/apps/{app_id}/devices` endpoints (design.md
/// NuntisApiClient). Retries a 5xx response or network failure with
/// exponential backoff (2s, 4s, 8s, 16s, 32s), capped at 5 attempts, per
/// design.md's Tech Decisions — mirrors `NuntisApiClient.kt` exactly.
/// `sleeper` is injectable so tests can skip the real delay; production
/// callers use the default (real thread sleep via `Thread.sleep`).
public class NuntisApiClient {

  private static let maxAttempts = 5
  private static let baseDelayMs: UInt64 = 2000

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

  public func createOrUpdateDevice(token: String, platform: String) -> ApiResult {
    let body: [String: Any] = ["token": token, "platform": platform]
    var request = URLRequest(url: URL(string: "\(baseUrl)/v1/apps/\(appId)/devices")!)
    request.httpMethod = "POST"
    request.setValue("Bearer \(clientKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONSerialization.data(withJSONObject: body)

    return executeWithRetry(request)
  }

  /// PATCH always includes the cached `token` field (AD-009 ownership proof).
  public func patchDevice(deviceId: String, token: String, fields: [String: Any]) -> ApiResult {
    var json = fields
    json["token"] = token

    var request = URLRequest(url: URL(string: "\(baseUrl)/v1/apps/\(appId)/devices/\(deviceId)")!)
    request.httpMethod = "PATCH"
    request.setValue("Bearer \(clientKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONSerialization.data(withJSONObject: json)

    return executeWithRetry(request)
  }

  private func executeWithRetry(_ request: URLRequest) -> ApiResult {
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
          return .success(parseDeviceResponse(data ?? Data()))
        }
        if http.statusCode < 500 {
          // 4xx: not retried, terminal failure.
          return .failure("HTTP \(http.statusCode)")
        }
        lastError = "HTTP \(http.statusCode)"
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

    semaphore.wait()
    return (resultData, resultResponse, resultError)
  }

  private func parseDeviceResponse(_ data: Data) -> DeviceResponse {
    guard
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let id = json["id"] as? String
    else {
      return DeviceResponse(id: "", tags: [:])
    }
    let tags = (json["tags"] as? [String: String]) ?? [:]
    return DeviceResponse(id: id, tags: tags)
  }
}
