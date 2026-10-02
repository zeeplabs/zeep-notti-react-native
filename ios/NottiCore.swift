import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Orchestrates init, device registration, token refresh, permission
/// requests, and tag/external-id/subscription mutations (design.md
/// NottiCore). `NottiApiClient`/`NottiDeviceStore`/`NottiEventStore` are
/// constructor-injected so each can be faked in tests; `tokenProvider` and `permissionRequester`
/// abstract the platform-specific push-token fetch and OS permission prompt
/// (owned by the concrete wiring in T14/T15 — e.g. the real APNs
/// registration flow lives in whatever concrete `tokenProvider` is wired in,
/// not here). `tokenProvider` is callback-based rather than a plain
/// synchronous getter, since APNs delivers the device token asynchronously
/// via `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)` —
/// there is no synchronous "get current token" API on iOS. Mirrors
/// `NottiCore.kt`'s contract exactly (design.md's Risks & Concerns
/// parallel-platform-test-matrix mitigation).
///
/// **Threading contract**: every public method returns immediately and does
/// its real work on `workQueue`, a private serial background queue.
/// `NottiApiClient` is blocking by design (semaphore-gated `URLSession`
/// call plus `Thread.sleep` retry backoff, up to 5x15s + backoff on a dead
/// network) and is therefore *only ever* invoked from `workQueue` — never
/// from the caller's thread, which on the APNs-delegate and permission-result
/// paths is the host app's main thread (a block there means a watchdog kill,
/// 0x8badf00d). `workQueue` being serial also gives the spec's P3-AC8
/// mutation serialization for free, and makes the registration tag write and
/// `mutateTags`' read-merge-write mutually exclusive (no lost tag update).
/// All mutable state below is read/written only on `workQueue`.
public class NottiCore {

  private let deviceStore: NottiDeviceStore
  private let eventStore: NottiEventStore
  private let apiClientFactory: (_ appId: String, _ clientKey: String, _ baseUrl: String) -> NottiApiClient
  private let tokenProvider: (_ callback: @escaping (String?) -> Void) -> Void
  private let permissionRequester: (_ callback: @escaping (Bool) -> Void) -> Void
  private let versionProvider: () -> String?
  /// Reads the device OS version (`UIDevice.current.systemVersion`), or nil on
  /// failure (DPF-01/04). Injected so `NottiCore` stays host-free; default
  /// `{ nil }` makes that field's sync a no-op.
  private let deviceOsProvider: () -> String?
  /// Reads the device model (`utsname.machine`), or nil on failure (DPF-01/04).
  private let deviceModelProvider: () -> String?
  /// Reads the IANA timezone id (`TimeZone.current.identifier`), or nil on
  /// failure (DPF-06/09).
  private let timezoneProvider: () -> String?
  /// Reads the OS language (`Locale.current.languageCode`), or nil on failure
  /// (DPF-06/09).
  private let languageProvider: () -> String?
  /// Best-effort, async OS push-permission state read (DPF-10): resolves with
  /// `granted`/`denied`/`notDetermined`/`provisional` (provisional auth) or
  /// nil on unknown/transitional state or read failure - nil omits the field,
  /// never fabricates (DPF edge case). Follows the async `countryProvider`
  /// callback shape (the real read, iOS
  /// `UNUserNotificationCenter.getNotificationSettings`, is callback-based).
  private let permissionStatusProvider: (@escaping (String?) -> Void) -> Void
  private let hasLocationPermission: () -> Bool
  private let countryProvider: (@escaping (String?) -> Void) -> Void
  /// Cold-start session (review item 2): reports, asynchronously, whether the
  /// app is already `.active` at construction time. The TurboModule (and so
  /// this core) is typically built *after* the launch's `didBecomeActive`
  /// already fired, so without this the cold-start session was never opened.
  /// `NottiImpl` wires the real `UIApplication.shared.applicationState` read
  /// (on the main thread); the default (`false`) keeps hostless tests inert.
  private let appStateProvider: (@escaping (_ isActive: Bool) -> Void) -> Void
  /// Begins an OS background task and returns the closure that ends it
  /// (review item 3): keeps the process alive long enough for the session-end
  /// bookkeeping + PATCH queued at `didEnterBackground` to run. Default no-op
  /// for tests; `NottiImpl` wires `UIApplication.beginBackgroundTask`.
  private let beginBackgroundTask: () -> (() -> Void)
  /// Session heartbeat period (review item 4). `<= 0` disables the timer.
  private let heartbeatInterval: TimeInterval
  private let platform: String
  private let logger: (String) -> Void
  /// "A session is open in this process" (mirrors Android's `SessionGate` /
  /// `NottiModule.processSessionGate`). A JS reload while foreground
  /// (expo-updates `reloadAsync`, CodePush, dev reload) builds a brand-new
  /// `NottiCore` whose own `hasStartedSession` is false; without a
  /// process-level flag it treated the still-open session as an orphan of a
  /// killed process, closing it (`session_count` +1, up to one heartbeat of
  /// time lost) and opening another. `NottiImpl` injects one process-wide
  /// instance; the default is a fresh gate so every test core is isolated.
  private let sessionGate: SessionGate

  /// Thread-safe process-level session flag. Opened by the first core that
  /// starts a session in this process, closed on `didEnterBackground`.
  public final class SessionGate {
    private let lock = NSLock()
    private var open = false

    public init() {}

    var isOpen: Bool {
      lock.lock()
      defer { lock.unlock() }
      return open
    }

    /// `true` only for the caller that flipped it closed -> open.
    func tryOpen() -> Bool {
      lock.lock()
      defer { lock.unlock() }
      if open { return false }
      open = true
      return true
    }

    func close() {
      lock.lock()
      open = false
      lock.unlock()
    }
  }

  private let workQueue = DispatchQueue(label: "app.notti.sdk.core", qos: .utility)
  private static let workQueueKey = DispatchSpecificKey<UInt8>()

  private var appId: String?
  private var clientKey: String?
  private var baseUrl: String?
  private var apiClient: NottiApiClient?
  /// The SDK package version, passed from JS at `initialize` (the package
  /// manifest is the single source of truth); nil when not provided or empty.
  /// Consumed by `sdkVersionProvider` (DPF-01..04).
  private var sdkVersion: String?
  /// Feeds the `sdk_version` profile field. Not a constructor-injected platform
  /// read (unlike `deviceOsProvider` etc.): `sdk_version` is core state set by
  /// `initialize`, so this reads the stored value at call time (design.md P1).
  private var sdkVersionProvider: () -> String? { { self.sdkVersion } }

  /// Mutations issued before device registration finished, replayed in order
  /// once it does. Bounded so a never-registering device cannot grow it
  /// without limit.
  ///
  /// `coalesceKey` (review item 8) is non-nil only for telemetry (session,
  /// country, app version): a newer telemetry mutation with the same key
  /// *replaces* the queued one (each carries a full snapshot, so only the
  /// latest matters), and telemetry is always what gets evicted when the
  /// queue is full - a user-initiated mutation (login, tags, subscription)
  /// is never dropped to make room for telemetry.
  private struct PendingMutation {
    let description: String
    let coalesceKey: String?
    let work: (_ client: NottiApiClient, _ deviceId: String, _ token: String) -> Void
  }
  private enum TelemetryKey {
    static let session = "telemetry.session"
    static let country = "telemetry.country"
    static let appVersion = "telemetry.appVersion"
    static let deviceOs = "telemetry.deviceOs"
    static let deviceModel = "telemetry.deviceModel"
    static let sdkVersion = "telemetry.sdkVersion"
    static let timezoneId = "telemetry.timezoneId"
    static let language = "telemetry.language"
    static let permissionStatus = "telemetry.permissionStatus"
    static let lastUnsubscribed = "telemetry.lastUnsubscribed"
  }
  private static let maxPendingMutations = 32
  private var pendingMutations: [PendingMutation] = []

  /// Outcome of the last registration attempt (workQueue-only). Drives the
  /// app-foreground retry: the retry schedule stops after 5 attempts, and
  /// spec P1-AC5 requires it to resume on the next foreground.
  private enum RegistrationState {
    case notAttempted
    case succeeded
    case failed
  }
  private var registrationState: RegistrationState = .notAttempted
  private var lastAttemptedToken: String?

  /// Notified whenever the persisted device id actually changes (first
  /// assignment, reinstall, or a re-registration that lands a different id) -
  /// never on an idempotent re-register that returns the same id already
  /// cached. Constructor-injected (not a settable var): a settable property
  /// set post-construction from Obj-C++ left a real window where
  /// `NottiPushDelegate`/`NottiBridge` could reach a published `NottiCore`
  /// through `NottiImpl.activeCore` before the handler was wired, silently
  /// dropping the first-assignment event and racing the property's own
  /// unsynchronized read/write across threads. `NottiImpl` now defers
  /// publishing itself (`activate()`) until after the handler exists (see
  /// ADR-001, docs/adr/001-expose-device-id-getter-and-change-event.md).
  /// Always invoked on `workQueue`.
  private let onDeviceIdChanged: (String) -> Void

  /// Guards against a foreground-retry storm: `didBecomeActive` can fire
  /// repeatedly (app switcher, control centre, alerts), and only one retry may
  /// be queued at a time. Touched from the notification thread, so it needs
  /// its own lock rather than the work queue.
  private let foregroundLock = NSLock()
  private var foregroundRetryQueued = false
  /// Lifecycle truth as seen by the notification callbacks themselves
  /// (guarded by `foregroundLock`), not by the possibly-lagging work queue.
  /// The heartbeat timer only records while this is true, so time spent in
  /// background is never written as "last seen foreground".
  private var appIsForeground = false
  private var foregroundObserver: NSObjectProtocol?
  private var backgroundObserver: NSObjectProtocol?

  /// Session-transition state (workQueue-only, T8). iOS fires
  /// `didBecomeActive` repeatedly without an intervening `didEnterBackground`
  /// (app switcher peek, control centre, alert), so "becomes active" is not
  /// itself "a new foreground session". `appIsInBackground` + `hasStartedSession`
  /// distinguish a real background→foreground (or cold-start) transition — the
  /// only ones that start a session — from a repeat activation that must not
  /// falsely end+restart the current session (spec edge case: no inflated
  /// `session_count` from non-interactive wake-ups).
  private var appIsInBackground = false
  private var hasStartedSession = false

  /// Heartbeat timer (workQueue-targeted) that periodically persists the
  /// last known foreground timestamp of the open session (review item 4).
  private var heartbeatTimer: DispatchSourceTimer?
  /// Upper bound on what an orphaned (unclean-kill) session may contribute,
  /// even with a heartbeat: defense against a corrupted persisted value.
  static let maxOrphanSessionMs: Int64 = 24 * 60 * 60 * 1000

  /// Flush de-duplication (review item 6): the push delegate and the network
  /// observer may call `onNetworkAvailable` many times in a burst; only one
  /// flush may be queued at a time. Touched off-queue, hence its own lock.
  private let flushLock = NSLock()
  private var flushScheduled = false

  /// Geocoding throttle (workQueue-only): CLGeocoder is rate-limited, so at
  /// most one country read per `minCountryReadIntervalMs`, never in parallel.
  private var lastCountryReadAtMs: Int64?
  static let minCountryReadIntervalMs: Int64 = 60_000

  /// M1 (pre-release review round 3): the cold-start session read can finish
  /// before `initialize()` ever runs — `appStateProvider` fires from
  /// `init`, and the JS side usually calls `initialize` from a `useEffect`
  /// that hasn't run yet — so `apiClient` is still nil and
  /// `sendCountryIfChanged` drops the result on the floor. The 60s geocode
  /// throttle then blocks a same-session retry. Remembering the resolved
  /// value here lets `registerDevice`'s success path retry the send once a
  /// client actually exists, without triggering a second geocode.
  private var lastResolvedCountry: String?

  public init(
    deviceStore: NottiDeviceStore,
    eventStore: NottiEventStore,
    apiClientFactory: @escaping (_ appId: String, _ clientKey: String, _ baseUrl: String) -> NottiApiClient,
    tokenProvider: @escaping (_ callback: @escaping (String?) -> Void) -> Void,
    permissionRequester: @escaping (_ callback: @escaping (Bool) -> Void) -> Void,
    versionProvider: @escaping () -> String? = { nil },
    hasLocationPermission: @escaping () -> Bool = { false },
    countryProvider: @escaping (@escaping (String?) -> Void) -> Void = { $0(nil) },
    deviceOsProvider: @escaping () -> String? = { nil },
    deviceModelProvider: @escaping () -> String? = { nil },
    timezoneProvider: @escaping () -> String? = { nil },
    languageProvider: @escaping () -> String? = { nil },
    permissionStatusProvider: @escaping (@escaping (String?) -> Void) -> Void = { $0(nil) },
    appStateProvider: @escaping (@escaping (_ isActive: Bool) -> Void) -> Void = { $0(false) },
    beginBackgroundTask: @escaping () -> (() -> Void) = { {} },
    heartbeatInterval: TimeInterval = 60,
    platform: String = "ios",
    logger: @escaping (String) -> Void = { _ in },
    onDeviceIdChanged: @escaping (String) -> Void = { _ in },
    sessionGate: SessionGate = SessionGate()
  ) {
    self.deviceStore = deviceStore
    self.eventStore = eventStore
    self.apiClientFactory = apiClientFactory
    self.tokenProvider = tokenProvider
    self.permissionRequester = permissionRequester
    self.versionProvider = versionProvider
    self.hasLocationPermission = hasLocationPermission
    self.countryProvider = countryProvider
    self.deviceOsProvider = deviceOsProvider
    self.deviceModelProvider = deviceModelProvider
    self.timezoneProvider = timezoneProvider
    self.languageProvider = languageProvider
    self.permissionStatusProvider = permissionStatusProvider
    self.appStateProvider = appStateProvider
    self.beginBackgroundTask = beginBackgroundTask
    self.heartbeatInterval = heartbeatInterval
    self.platform = platform
    self.logger = logger
    self.onDeviceIdChanged = onDeviceIdChanged
    self.sessionGate = sessionGate
    workQueue.setSpecific(key: Self.workQueueKey, value: 1)
    observeAppForeground()
    observeAppBackground()
    // Review item 2: the launch's `didBecomeActive` usually fired before this
    // core existed. If the app is already active, treat it as that missed
    // activation (idempotent with a later real notification: a repeat
    // activation never restarts an open session). Timestamp captured at the
    // moment the state was observed, not when the work queue gets to it.
    appStateProvider { [weak self] isActive in
      guard isActive, let self = self else { return }
      self.handleAppDidBecomeActive(atMs: self.nowMs())
    }
  }

  /// Called by `NottiImpl.invalidate()` when the RN bridge tears the module
  /// down (JS reload). The old core can outlive that for a while (in-flight
  /// blocks, delayed dealloc); without this it kept observing lifecycle, so
  /// on the next background both it and the reloaded core ended the same
  /// session from two different work queues (double `session_count`). Stops
  /// the observers and the heartbeat; leaves the persisted open session and
  /// the process `sessionGate` alone for the new core to adopt.
  public func invalidate() {
    foregroundLock.lock()
    let observers = [foregroundObserver, backgroundObserver]
    foregroundObserver = nil
    backgroundObserver = nil
    foregroundLock.unlock()
    for case let observer? in observers {
      NotificationCenter.default.removeObserver(observer)
    }
    workQueue.async { [weak self] in
      self?.stopHeartbeatTimer()
    }
  }

  deinit {
    heartbeatTimer?.cancel()
    if let observer = foregroundObserver {
      NotificationCenter.default.removeObserver(observer)
    }
    if let observer = backgroundObserver {
      NotificationCenter.default.removeObserver(observer)
    }
  }

  /// Runs `block` on `workQueue`, executing it inline when the caller is
  /// already on that queue. Needed because `tokenProvider`/
  /// `permissionRequester` may invoke their callback synchronously (from the
  /// work queue itself) or asynchronously on an arbitrary thread, and the
  /// synchronous case must keep running as part of the *current* work item
  /// rather than being re-enqueued behind whatever landed in the meantime.
  private func onWorkQueue(_ block: @escaping () -> Void) {
    if DispatchQueue.getSpecific(key: Self.workQueueKey) != nil {
      block()
    } else {
      workQueue.async(execute: block)
    }
  }

  public func initialize(appId: String, clientKey: String, baseUrl: String, sdkVersion: String = "") {
    workQueue.async { [weak self] in
      self?.initializeOnQueue(appId: appId, clientKey: clientKey, baseUrl: baseUrl, sdkVersion: sdkVersion)
    }
  }

  public func onTokenRefreshed(_ newToken: String) {
    workQueue.async { [weak self] in
      guard let self = self, let client = self.apiClient else { return }
      self.registerDevice(client, newToken)
    }
  }

  public func requestPermission(_ callback: @escaping (Bool) -> Void) {
    workQueue.async { [weak self] in
      guard let self = self else { return }
      guard let client = self.apiClient else {
        self.logger("Notti.requestPermission: called before initialize - not prompting")
        callback(false)
        return
      }

      self.permissionRequester { granted in
        // The OS prompt result can arrive on any thread; hop back onto the
        // work queue so the PATCH below never runs on the caller's (main)
        // thread. The callback fires first so the JS Promise resolves as
        // soon as the user answered, instead of waiting out a possibly
        // minutes-long retry cycle on a dead network.
        //
        // A4 (found in pre-release review): that Promise reports the OS
        // *dialog* result, not whether the backend actually persisted it - a
        // failed PATCH here used to fail completely silently, with nothing
        // logged and no reconciliation path (the foreground retry only
        // covers registration, never mutations). Changing the Promise to
        // depend on the PATCH outcome would be a breaking API change;
        // logging the failure is the fix that fits this pass without that
        // risk.
        self.onWorkQueue {
          callback(granted)
          self.performOrQueue(client, description: "permission-result subscription update") { [weak self] client, deviceId, token in
            self?.patchSubscribed(client, deviceId: deviceId, token: token, granted, logContext: "requestPermission")
          }
          // DPF-12: the OS permission status is re-read from the OS state (not
          // inferred from the dialog bool) and diff-and-enqueued.
          self.syncPermissionStatusIfNeeded(client)
        }
      }
    }
  }

  public func login(_ externalUserId: String) {
    workQueue.async { [weak self] in
      guard let self = self, let client = self.apiClient else { return }
      self.performOrQueue(client, description: "login") { [weak self] client, deviceId, token in
        let result = client.patchDevice(
          deviceId: deviceId,
          token: token,
          fields: ["external_user_id": externalUserId]
        )
        switch result {
        case .success:
          self?.deviceStore.setExternalUserId(externalUserId)
        case .failure(let message):
          self?.logger("Notti.login: PATCH failed (\(message)) - not retried")
        }
      }
    }
  }

  /// The backend does not support clearing `external_user_id` server-side
  /// (spec Edge Case) - only the SDK's locally-held association is cleared.
  public func logout() {
    workQueue.async { [weak self] in
      self?.deviceStore.setExternalUserId(nil)
    }
  }

  public func setSubscription(_ enabled: Bool) {
    workQueue.async { [weak self] in
      guard let self = self, let client = self.apiClient else { return }
      self.performOrQueue(client, description: "setSubscription") { [weak self] client, deviceId, token in
        guard let self = self else { return }
        let wasSubscribed = self.deviceStore.getSubscribed()
        self.patchSubscribed(client, deviceId: deviceId, token: token, enabled, logContext: "setSubscription")
        // DPF-14 app-driven path: a real true->false transition records the
        // most-recent unsubscribe timestamp locally and enqueues it (coalesced
        // so a queued permission-driven write and this collapse to the latest).
        if !enabled && wasSubscribed && !self.deviceStore.getSubscribed() {
          let now = self.nowMs()
          self.deviceStore.setLastUnsubscribedAtMs(now)
          self.performOrQueue(client, description: "last unsubscribed", coalesceKey: TelemetryKey.lastUnsubscribed) {
            [weak self] client, deviceId, token in
            let result = client.patchDevice(deviceId: deviceId, token: token, fields: ["last_unsubscribed_at": Self.formatIsoUtc(now)])
            switch result {
            case .success:
              break // timestamp already persisted locally
            case .failure(let message):
              self?.logger("Notti.lastUnsubscribed: PATCH failed (\(message)) - not retried")
            }
          }
        }
      }
    }
  }

  /// P3 opt-in toggle (SEGTEL-10, the single deliberate AD-001 JS-visible API):
  /// persists the flag. On opt-in it sends nothing itself; the next session
  /// start attempts the best-effort read.
  ///
  /// On opt-out (SEGTEL-13, LGPD - review item 1) the server-side `country`
  /// MUST end up cleared, not merely stop being sent. The clear is therefore
  /// a persisted obligation (`pendingCountryClear`), not a fire-and-forget
  /// PATCH: it is set here, survives process death, and is only lowered on a
  /// 2xx. It is (re)attempted right away when possible and again on every
  /// registration success, app foreground and network regain - so an opt-out
  /// issued before `initialize`, offline, or against a 5xx still converges.
  /// Only raised when there may be something to clear (sharing was on, a
  /// country was synced, or a clear is already pending) so a host calling
  /// `setLocationSharingEnabled(false)` on every launch sends nothing.
  public func setLocationSharingEnabled(_ enabled: Bool) {
    // B1 (LGPD, pre-release review round 3): the flag and the pending-clear
    // obligation must be durable the instant this call returns, not after
    // `workQueue` drains. `workQueue` can be blocked for minutes by
    // `NottiApiClient`'s blocking retry backoff (up to 5x15s+backoff); if the
    // host process is killed while queued, an opt-out issued in that window
    // would never reach `UserDefaults` and the next launch would resume
    // sharing against the user's choice. `UserDefaults` is thread-safe, so
    // these writes happen synchronously on the caller's thread; only the
    // network side-effect (the PATCH attempt) is deferred to `workQueue`.
    let wasEnabled = deviceStore.getLocationSharingEnabled()
    deviceStore.setLocationSharingEnabled(enabled)
    if enabled {
      if !wasEnabled {
        // Fresh consent supersedes an unacknowledged clear; forget the
        // synced value too so the next read is re-sent even if a clear
        // reached the server but its ack was lost.
        deviceStore.setPendingCountryClear(false)
        deviceStore.setLastSyncedCountry(nil)
      }
      return
    }
    let mayHaveServerSideCountry = wasEnabled
      || deviceStore.getLastSyncedCountry() != nil
      || deviceStore.getPendingCountryClear()
    guard mayHaveServerSideCountry else { return }
    deviceStore.setPendingCountryClear(true)
    workQueue.async { [weak self] in
      self?.attemptPendingCountryClear()
    }
  }

  /// Cached device id, or `nil` if registration hasn't assigned one yet.
  public func getDeviceId() -> String? {
    deviceStore.getDeviceId()
  }

  public func mutateTags(add: [String: String]?, remove: [String]?) {
    workQueue.async { [weak self] in
      guard let self = self, let client = self.apiClient else { return }
      self.performOrQueue(client, description: "tag mutation") { [weak self] client, deviceId, token in
        guard let self = self else { return }
        // The merge deliberately reads the tag cache at *send* time, not at
        // call time: a mutation queued before registration must merge onto
        // whatever tags the registration response seeded.
        let merged = NottiDeviceStore.mergeTags(self.deviceStore.getTags(), add: add, remove: remove)
        let result = client.patchDevice(deviceId: deviceId, token: token, fields: ["tags": merged])
        switch result {
        case .success(let response):
          self.deviceStore.setTags(response.tags)
        case .failure(let message):
          self.logger("Notti.mutateTags: PATCH failed (\(message)) - not retried")
        }
      }
    }
  }

  /// Blocks the calling thread until every mutation already enqueued on
  /// `workQueue` has run, or `timeout` elapses (returns `false` on timeout).
  /// Test/diagnostic hook only — the SDK itself never calls it, and it is
  /// not reachable from the JS API surface.
  @discardableResult
  public func waitForPendingWork(timeout: TimeInterval = 5) -> Bool {
    let semaphore = DispatchSemaphore(value: 0)
    workQueue.async { semaphore.signal() }
    return semaphore.wait(timeout: .now() + timeout) == .success
  }

  /// Flush trigger for the network observer and the push delegate's
  /// opportunistic post-enqueue flush (T8): hops onto `workQueue` and drains
  /// the offline event queue. A no-op when the device is not registered yet —
  /// `flushEventQueue` guards on `apiClient`/token — and the event stays queued
  /// for the next registration success or app foreground.
  internal func onNetworkAvailable() {
    flushLock.lock()
    if flushScheduled {
      flushLock.unlock()
      return
    }
    flushScheduled = true
    flushLock.unlock()

    workQueue.async { [weak self] in
      guard let self = self else { return }
      // Cleared before draining, so an event enqueued while this flush runs
      // still gets a flush of its own.
      self.flushLock.lock()
      self.flushScheduled = false
      self.flushLock.unlock()
      self.attemptPendingCountryClear()
      self.flushEventQueue()
    }
  }

  /// Test hook (review item 4): persists a heartbeat as if the periodic timer
  /// had fired at `nowMs` while foregrounded.
  internal func recordHeartbeat(nowMs: Int64) {
    workQueue.async { [weak self] in
      self?.recordHeartbeatOnQueue(nowMs: nowMs, requireForeground: false)
    }
  }

  // MARK: - workQueue-only internals

  private func initializeOnQueue(appId: String, clientKey: String, baseUrl: String, sdkVersion: String) {
    if appId.isEmpty || clientKey.isEmpty || baseUrl.isEmpty {
      logger("Notti.initialize: appId, clientKey, or baseUrl is missing/empty - skipping registration")
      return
    }
    // Empty sdkVersion (JS resolution failure) is stored as nil so the
    // `sdk_version` field is omitted, never sent as an empty string.
    self.sdkVersion = sdkVersion.isEmpty ? nil : sdkVersion

    // A malformed-but-non-empty baseUrl (e.g. "my host.example.com", or a
    // scheme-less host) must leave the SDK disabled, not crash the host app
    // (SDK-03). Validated once here so nothing downstream ever has to
    // force-unwrap integrator-supplied config.
    guard let validatedBaseUrl = NottiApiClient.validatedBaseUrl(baseUrl) else {
      logger(
        "Notti.initialize: baseUrl is not a valid absolute http(s) URL - "
          + "skipping registration (SDK stays disabled)"
      )
      return
    }

    // Repeat call with identical args in the same session: no-op (SDK-07).
    if appId == self.appId && clientKey == self.clientKey && validatedBaseUrl == self.baseUrl {
      return
    }

    self.appId = appId
    self.clientKey = clientKey
    self.baseUrl = validatedBaseUrl
    let client = apiClientFactory(appId, clientKey, validatedBaseUrl)
    self.apiClient = client

    tokenProvider { [weak self] token in
      guard let self = self else { return }
      // The APNs token arrives asynchronously on an arbitrary thread.
      self.onWorkQueue {
        guard let token = token else {
          self.logger("Notti.initialize: no push token available - skipping registration")
          return
        }
        self.registerDevice(client, token)
      }
    }
  }

  private func registerDevice(_ client: NottiApiClient, _ token: String) {
    lastAttemptedToken = token
    switch client.createOrUpdateDevice(token: token, platform: platform) {
    case .success(let response):
      registrationState = .succeeded
      let previousDeviceId = deviceStore.getDeviceId()
      deviceStore.setDeviceId(response.id)
      if response.id != previousDeviceId {
        onDeviceIdChanged(response.id)
      }
      deviceStore.setLastToken(token)
      deviceStore.setTags(response.tags)
      // Privacy obligation first (review item 1), ahead of queued mutations.
      attemptPendingCountryClear()
      // M1: retry a country resolved before this client existed (cold-start
      // read racing `initialize`). Reuses the cached value so this does not
      // re-trigger CLGeocoder; `sendCountryIfChanged` still re-checks the
      // opt-in flag and dedupes against the last synced value itself.
      if let country = self.lastResolvedCountry {
        self.sendCountryIfChanged(country)
      }
      flushPendingMutations(client, deviceId: response.id, token: token)
      syncProfileFieldsIfNeeded(client)
      syncPermissionStatusIfNeeded(client)
      flushEventQueue()
    case .failure(let message):
      registrationState = .failed
      logger("Notti.initialize: device registration failed: \(message)")
    }
  }

  // MARK: - Foreground retry (spec P1-AC5)

  /// workQueue-only. Diff-and-enqueue (SEGTEL-03) generalized to every
  /// read-once profile field (device-profile-fields DPF-01..09): for each of
  /// `app_version`, `device_os`, `device_model`, `sdk_version`,
  /// `timezone_id`, `language`, reads the injected provider and only when it
  /// differs from the field's last-synced store value enqueues a coalesced
  /// PATCH, persisting on Success. A nil provider skips only that field
  /// (DPF-04/09) - no crash, no registration block. Opaque strings, no parsing.
  private func syncProfileFieldsIfNeeded(_ client: NottiApiClient) {
    func sync(
      _ name: String,
      coalesceKey: String,
      provider: () -> String?,
      synced: () -> String?,
      setSynced: @escaping (String) -> Void
    ) {
      guard let current = provider() else { return }
      guard current != synced() else { return }
      performOrQueue(client, description: name, coalesceKey: coalesceKey) {
        [weak self] client, deviceId, token in
        let result = client.patchDevice(deviceId: deviceId, token: token, fields: [name: current])
        switch result {
        case .success:
          setSynced(current)
        case .failure(let message):
          self?.logger("Notti.\(name): PATCH failed (\(message)) - not retried")
        }
      }
    }
    sync("app_version", coalesceKey: TelemetryKey.appVersion, provider: versionProvider,
      synced: { self.deviceStore.getAppVersion() }, setSynced: { self.deviceStore.setAppVersion($0) })
    sync("device_os", coalesceKey: TelemetryKey.deviceOs, provider: deviceOsProvider,
      synced: { self.deviceStore.getLastSyncedDeviceOs() }, setSynced: { self.deviceStore.setLastSyncedDeviceOs($0) })
    sync("device_model", coalesceKey: TelemetryKey.deviceModel, provider: deviceModelProvider,
      synced: { self.deviceStore.getLastSyncedDeviceModel() }, setSynced: { self.deviceStore.setLastSyncedDeviceModel($0) })
    sync("sdk_version", coalesceKey: TelemetryKey.sdkVersion, provider: sdkVersionProvider,
      synced: { self.deviceStore.getLastSyncedSdkVersion() }, setSynced: { self.deviceStore.setLastSyncedSdkVersion($0) })
    sync("timezone_id", coalesceKey: TelemetryKey.timezoneId, provider: timezoneProvider,
      synced: { self.deviceStore.getLastSyncedTimezoneId() }, setSynced: { self.deviceStore.setLastSyncedTimezoneId($0) })
    sync("language", coalesceKey: TelemetryKey.language, provider: languageProvider,
      synced: { self.deviceStore.getLastSyncedLanguage() }, setSynced: { self.deviceStore.setLastSyncedLanguage($0) })
  }

  /// workQueue-only. Syncs the OS push-permission state (DPF-10..13, DPF-14
  /// permission-driven unsubscribe): fires the async `permissionStatusProvider`;
  /// only when the freshly-read status differs from the last synced one is a
  /// coalesced PATCH enqueued (diff-and-enqueue, DPF-11/13). A nil/unknown
  /// status omits the field - never fabricated (DPF edge case). A granted ->
  /// denied transition additionally persists `last_unsubscribed_at` and carries
  /// it in the same atomic request (DPF-14).
  ///
  /// Called from three triggers: `registerDevice` success, the
  /// `requestPermission` result, and each session start (catches permission
  /// changed in OS Settings while the app wasn't running, DPF-13).
  private func syncPermissionStatusIfNeeded(_ client: NottiApiClient) {
    permissionStatusProvider { [weak self] status in
      guard let self = self, let status = status else { return }
      self.onWorkQueue {
        guard self.apiClient != nil else { return }
        let previous = self.deviceStore.getLastSyncedPermissionStatus()
        guard status != previous else { return }
        var fields: [String: Any] = ["permission_status": status]
        if status == "denied" && previous == "granted" {
          let now = self.nowMs()
          self.deviceStore.setLastUnsubscribedAtMs(now)
          fields["last_unsubscribed_at"] = Self.formatIsoUtc(now)
        }
        self.performOrQueue(client, description: "permission status", coalesceKey: TelemetryKey.permissionStatus) {
          [weak self] client, deviceId, token in
          let result = client.patchDevice(deviceId: deviceId, token: token, fields: fields)
          switch result {
          case .success:
            self?.deviceStore.setLastSyncedPermissionStatus(status)
          case .failure(let message):
            self?.logger("Notti.permissionStatus: PATCH failed (\(message)) - not retried")
          }
        }
      }
    }
  }

  /// Subscribes to `UIApplication.didBecomeActiveNotification` directly - a
  /// plain system notification, so no host-`AppDelegate` forwarding is needed
  /// (unlike the APNs callbacks). Without this, a registration that exhausted
  /// its 5 attempts never retried until the app was relaunched.
  private func observeAppForeground() {
    #if canImport(UIKit)
      foregroundObserver = NotificationCenter.default.addObserver(
        forName: UIApplication.didBecomeActiveNotification,
        object: nil,
        queue: nil
      ) { [weak self] _ in
        guard let self = self else { return }
        // Review item 3: timestamp captured in the callback, not when the
        // (possibly busy) work queue eventually runs the block.
        self.handleAppDidBecomeActive(atMs: self.nowMs())
      }
    #endif
  }

  /// The T8 session-end hook: mirrors `observeAppForeground` on
  /// `UIApplication.didEnterBackgroundNotification` (also plain system
  /// notifications, zero AppDelegate forwarding). Removed in `deinit` like the
  /// foreground observer.
  private func observeAppBackground() {
    #if canImport(UIKit)
      backgroundObserver = NotificationCenter.default.addObserver(
        forName: UIApplication.didEnterBackgroundNotification,
        object: nil,
        queue: nil
      ) { [weak self] _ in
        guard let self = self else { return }
        self.handleAppDidEnterBackground(atMs: self.nowMs())
      }
    #endif
  }

  private func handleAppDidBecomeActive(atMs activatedAtMs: Int64) {
    foregroundLock.lock()
    appIsForeground = true
    if foregroundRetryQueued {
      foregroundLock.unlock()
      return
    }
    foregroundRetryQueued = true
    foregroundLock.unlock()

    workQueue.async { [weak self] in
      guard let self = self else { return }
      self.foregroundLock.lock()
      self.foregroundRetryQueued = false
      self.foregroundLock.unlock()
      // Session start first (SEGTEL-05): a repeat `didBecomeActive` without an
      // intervening background must not close+reopen the current session, so
      // only a real transition (or the cold-start launch) reaches
      // `handleSessionStartOnQueue`.
      if self.appIsInBackground || !self.hasStartedSession {
        self.hasStartedSession = true
        self.appIsInBackground = false
        if self.sessionGate.tryOpen() {
          self.handleSessionStartOnQueue(nowMs: activatedAtMs)
        } else {
          // Another core of this same process (pre-reload) already opened
          // the foreground session: adopt it instead of closing it as an
          // orphan of a killed process.
          self.adoptOpenSessionOnQueue(nowMs: activatedAtMs)
        }
      } else {
        // Repeat activation of the same session: still proof of foreground.
        self.recordHeartbeatOnQueue(nowMs: activatedAtMs, requireForeground: false)
      }
      self.attemptPendingCountryClear()
      // Unconditional: a device that is already registered skips the retry
      // below but must still get its offline event queue flushed.
      self.flushEventQueue()
      self.retryRegistrationIfNeeded()
    }
  }

  /// Session end on the `didEnterBackgroundNotification` path. The end
  /// timestamp is the moment the app actually backgrounded (review item 3),
  /// and an OS background task keeps the process alive while the queued
  /// bookkeeping + PATCH run. Resetting `foregroundRetryQueued` lets the next
  /// activation enqueue its own session start even if an earlier activation
  /// block is still waiting on a busy queue (it would otherwise be dropped).
  private func handleAppDidEnterBackground(atMs backgroundedAtMs: Int64) {
    foregroundLock.lock()
    appIsForeground = false
    foregroundRetryQueued = false
    foregroundLock.unlock()

    let endBackgroundTask = beginBackgroundTask()
    workQueue.async { [weak self] in
      defer { endBackgroundTask() }
      guard let self = self else { return }
      self.appIsInBackground = true
      // Closed on the work queue so it is serialized with this core's own
      // `tryOpen` in `handleAppDidBecomeActive` (a background block queued
      // behind a still-pending activation must not leave the gate open).
      self.sessionGate.close()
      self.handleSessionEndOnQueue(nowMs: backgroundedAtMs)
    }
  }

  /// workQueue-only. Runs after any in-flight registration has finished (the
  /// queue is serial), so `registrationState` is already final here.
  private func retryRegistrationIfNeeded() {
    guard let client = apiClient else { return }
    guard registrationState != .succeeded else { return }

    logger("Notti: app foregrounded without a successful registration - retrying")

    if let token = lastAttemptedToken {
      registerDevice(client, token)
      return
    }

    // No token has been seen *this session*. The persisted `lastToken` is
    // deliberately not used as a stand-in: APNs tokens rotate (backup restore,
    // reinstall), so on a relaunch where the token simply has not been
    // delivered yet, registering with the previous session's token would both
    // bind the backend to a dead token and cause a second, duplicate
    // registration moments later when the real token does arrive. Ask the
    // platform instead (on iOS this re-triggers registerForRemoteNotifications
    // and the callback fires only once the real token is in hand) — the same
    // mechanism `initialize` uses.
    tokenProvider { [weak self] token in
      guard let self = self else { return }
      self.onWorkQueue {
        guard let token = token else {
          self.logger("Notti: foreground retry found no push token available")
          return
        }
        self.registerDevice(client, token)
      }
    }
  }

  // MARK: - Session lifecycle (T8, SEGTEL-05..09)

  /// Starts (or, on an unclean kill, first closes then re-opens) the current
  /// session. Public entry point for the lifecycle hooks; hops onto
  /// `workQueue`, where `handleSessionStartOnQueue` does the real work.
  internal func handleSessionStart(nowMs: Int64) {
    workQueue.async { [weak self] in
      self?.handleSessionStartOnQueue(nowMs: nowMs)
    }
  }

  /// Ends the current session (aggregate + snapshot PATCH). Public entry point
  /// for the background hook; hops onto `workQueue`, where
  /// `handleSessionEndOnQueue` does the real work.
  internal func handleSessionEnd(nowMs: Int64) {
    workQueue.async { [weak self] in
      self?.handleSessionEndOnQueue(nowMs: nowMs)
    }
  }

  /// workQueue-only. Session-start bookkeeping:
  /// 1. A stale `sessionStartedAtMs` means the previous process was killed
  ///    while foreground (no clean background transition) — close the missed
  ///    session at its last known foreground timestamp (SEGTEL-08, see
  ///    `closeOrphanedSessionOnQueue`) before opening the new one.
  /// 2. `firstSessionAtMs` is set once, never overwritten (SEGTEL-05 AC1).
  /// 3. Open the new session at `nowMs` and start its heartbeat.
  private func handleSessionStartOnQueue(nowMs: Int64) {
    if deviceStore.getSessionStartedAtMs() != nil {
      closeOrphanedSessionOnQueue(nowMs: nowMs)
    }
    if deviceStore.getFirstSessionAtMs() == nil {
      deviceStore.setFirstSessionAtMs(nowMs)
    }
    deviceStore.setSessionStartedAtMs(nowMs)
    deviceStore.setSessionLastSeenAtMs(nowMs)
    startHeartbeatTimer()
    readCountryIfEnabled(nowMs: nowMs)
    if let client = apiClient {
      syncPermissionStatusIfNeeded(client)
    }
  }

  /// workQueue-only (final review A). Takes over the session a previous core
  /// of this process opened (JS reload while foreground): no orphan close, no
  /// `session_count` change, no new `first_session_at`/country read - only
  /// this core's heartbeat, so the adopted session keeps its last-seen fresh.
  /// If nothing is persisted (the open session was already ended, e.g. a
  /// background block that ran before a stale activation), a normal start is
  /// the only correct thing left to do.
  private func adoptOpenSessionOnQueue(nowMs: Int64) {
    guard deviceStore.getSessionStartedAtMs() != nil else {
      handleSessionStartOnQueue(nowMs: nowMs)
      return
    }
    recordHeartbeatOnQueue(nowMs: nowMs, requireForeground: false)
    startHeartbeatTimer()
  }

  /// workQueue-only (review item 4). Closes a session the previous process
  /// never ended. End = last persisted heartbeat (the last moment the app was
  /// *known* to be foreground), clamped to `[startedAt, nowMs]` and to
  /// `maxOrphanSessionMs`. Using `nowMs` (the old behavior) counted all the
  /// time the app was dead as foreground. A session persisted by an older
  /// SDK version has no heartbeat: it is counted with zero duration rather
  /// than guessed (under-count by one session's length beats unbounded
  /// inflation).
  private func closeOrphanedSessionOnQueue(nowMs: Int64) {
    guard let startedAt = deviceStore.getSessionStartedAtMs() else { return }
    let lastSeen = deviceStore.getSessionLastSeenAtMs() ?? startedAt
    var end = max(startedAt, min(lastSeen, nowMs))
    end = min(end, startedAt + Self.maxOrphanSessionMs)
    handleSessionEndOnQueue(nowMs: end)
  }

  private func startHeartbeatTimer() {
    stopHeartbeatTimer()
    guard heartbeatInterval > 0 else { return }
    let timer = DispatchSource.makeTimerSource(queue: workQueue)
    let leewayMs = max(1, Int(heartbeatInterval * 100))  // 10% of the period
    timer.schedule(
      deadline: .now() + heartbeatInterval,
      repeating: heartbeatInterval,
      leeway: .milliseconds(leewayMs)
    )
    timer.setEventHandler { [weak self] in
      guard let self = self else { return }
      self.recordHeartbeatOnQueue(nowMs: self.nowMs(), requireForeground: true)
    }
    timer.resume()
    heartbeatTimer = timer
  }

  private func stopHeartbeatTimer() {
    heartbeatTimer?.cancel()
    heartbeatTimer = nil
  }

  /// workQueue-only. Monotonic: never moves the heartbeat backwards.
  private func recordHeartbeatOnQueue(nowMs: Int64, requireForeground: Bool) {
    guard let startedAt = deviceStore.getSessionStartedAtMs() else { return }
    if requireForeground {
      foregroundLock.lock()
      let foreground = appIsForeground
      foregroundLock.unlock()
      guard foreground else { return }
    }
    let previous = deviceStore.getSessionLastSeenAtMs() ?? startedAt
    deviceStore.setSessionLastSeenAtMs(max(previous, nowMs))
  }

  /// workQueue-only. P3 session-start country read (SEGTEL-11): only when the
  /// opt-in flag is on AND the host app already holds OS location permission
  /// (check-only, never prompts). The async `countryProvider` result is
  /// re-gated on the flag at callback time — a toggle flipped off mid-read
  /// omits the field (SEGTEL-12), and a nil read (permission revoked, no fix,
  /// geocode failure) omits it silently with no crash or error (SEGTEL-14).
  ///
  /// Throttled to one read per `minCountryReadIntervalMs` (CLGeocoder is
  /// rate-limited and must not be called in parallel), and a PATCH is only
  /// sent when the resolved country differs from the last acknowledged one.
  private func readCountryIfEnabled(nowMs: Int64) {
    guard deviceStore.getLocationSharingEnabled(), hasLocationPermission() else { return }
    if let last = lastCountryReadAtMs, nowMs >= last, nowMs - last < Self.minCountryReadIntervalMs {
      return
    }
    lastCountryReadAtMs = nowMs
    countryProvider { [weak self] country in
      self?.onWorkQueue {
        guard let self = self, let country = country else { return }
        self.lastResolvedCountry = country
        self.sendCountryIfChanged(country)
      }
    }
  }

  /// workQueue-only. `isCountrySharingAllowed` is checked both here and again
  /// at execution time (review item 9): a country queued before registration
  /// (or racing an opt-out) must never be written after the user opted out.
  private func sendCountryIfChanged(_ country: String) {
    guard isCountrySharingAllowed() else { return }
    guard country != deviceStore.getLastSyncedCountry() else { return }
    guard let client = apiClient else { return }
    performOrQueue(client, description: "country", coalesceKey: TelemetryKey.country) {
      [weak self] client, deviceId, token in
      guard let self = self else { return }
      guard self.isCountrySharingAllowed() else {
        self.logger("Notti: location sharing disabled before the queued country was sent - dropped")
        return
      }
      switch client.patchDevice(deviceId: deviceId, token: token, fields: ["country": country]) {
      case .success:
        self.deviceStore.setLastSyncedCountry(country)
      case .failure(let message):
        self.logger("Notti.country: PATCH failed (\(message)) - retried on a later session")
      }
    }
  }

  private func isCountrySharingAllowed() -> Bool {
    deviceStore.getLocationSharingEnabled() && !deviceStore.getPendingCountryClear()
  }

  /// workQueue-only (review item 1). Sends the persisted `{country: null}`
  /// clear when one is pending and the device is addressable; lowers the
  /// flag only on a 2xx. Any failure (offline, 5xx after retries, 4xx) keeps
  /// it pending for the next registration success / foreground / flush.
  private func attemptPendingCountryClear() {
    guard deviceStore.getPendingCountryClear(), let client = apiClient,
      let deviceId = deviceStore.getDeviceId(), let token = deviceStore.getLastToken()
    else { return }
    switch client.patchDevice(deviceId: deviceId, token: token, fields: ["country": NSNull()]) {
    case .success:
      deviceStore.setPendingCountryClear(false)
      deviceStore.setLastSyncedCountry(nil)
    case .failure(let message):
      if let status = NottiApiClient.permanentClientErrorStatus(message) {
        // Final review D: 401/403/404 will not heal by retrying the same
        // request (bad credentials, or the device is gone server-side). Kept
        // pending and re-sent by trigger like any failure, but logged
        // distinctly so it is diagnosable. No identifiers in the line.
        logger(
          "Notti.setLocationSharingEnabled: country clear rejected permanently (HTTP \(status)) - "
            + "stays pending and is re-sent on the next trigger; check the client key / device registration")
      } else {
        logger("Notti.setLocationSharingEnabled: country clear failed (\(message)) - stays pending")
      }
    }
  }

  /// workQueue-only. Session-end bookkeeping:
  /// 1. No active session → no-op (also excludes widget/extension/background-
  ///    fetch invocations, which never set `sessionStartedAtMs`).
  /// 2. Otherwise increment the aggregate, persist it (survives kill), and
  ///    enqueue a session PATCH whose fields are a **snapshot captured at
  ///    enqueue time** — a new session starting mid-flush must not be
  ///    double-counted (SEGTEL-07 AC3, same capture-at-enqueue shape as
  ///    `mutateTags`).
  private func handleSessionEndOnQueue(nowMs: Int64) {
    guard let startedAt = deviceStore.getSessionStartedAtMs() else { return }
    stopHeartbeatTimer()
    let sessionCount = deviceStore.getSessionCount() + 1
    let sessionTimeMs = deviceStore.getSessionTimeMs() + max(0, nowMs - startedAt)
    deviceStore.setSessionCount(sessionCount)
    deviceStore.setSessionTimeMs(sessionTimeMs)
    deviceStore.setLastSessionAtMs(nowMs)
    deviceStore.setSessionStartedAtMs(nil)
    deviceStore.setSessionLastSeenAtMs(nil)

    var snapshot: [String: Any] = [:]
    if let firstSessionAt = deviceStore.getFirstSessionAtMs() {
      snapshot["first_session_at"] = Self.formatIsoUtc(firstSessionAt)
    }
    snapshot["last_session_at"] = Self.formatIsoUtc(nowMs)
    snapshot["session_count"] = sessionCount
    snapshot["session_time_seconds"] = sessionTimeMs / 1000

    guard let client = apiClient else { return }
    performOrQueue(client, description: "session telemetry", coalesceKey: TelemetryKey.session) {
      client, deviceId, token in
      _ = client.patchDevice(deviceId: deviceId, token: token, fields: snapshot)
    }
  }

  private func nowMs() -> Int64 {
    Int64(Date().timeIntervalSince1970 * 1000)
  }

  /// ISO-8601 UTC with millisecond precision — the same
  /// `yyyy-MM-dd'T'HH:mm:ss.SSS'Z'` shape Android's `formatIsoUtc` produces,
  /// so the backend's Go RFC3339 parse accepts both platforms.
  private static func formatIsoUtc(_ epochMs: Int64) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: Date(timeIntervalSince1970: Double(epochMs) / 1000))
  }

  /// Runs `work` right away when the device already has an id + token, or
  /// parks it in `pendingMutations` when registration has not completed yet.
  /// Registration is inherently async on iOS (the APNs token only arrives via
  /// `didRegisterForRemoteNotificationsWithDeviceToken`), so `login`/
  /// `addTags`/`requestPermission` called right after `initialize()` would
  /// otherwise be silently and permanently dropped.
  private func performOrQueue(
    _ client: NottiApiClient,
    description: String,
    coalesceKey: String? = nil,
    _ work: @escaping (_ client: NottiApiClient, _ deviceId: String, _ token: String) -> Void
  ) {
    guard let deviceId = deviceStore.getDeviceId(), let token = deviceStore.getLastToken() else {
      let mutation = PendingMutation(description: description, coalesceKey: coalesceKey, work: work)
      if let key = coalesceKey, let index = pendingMutations.firstIndex(where: { $0.coalesceKey == key }) {
        pendingMutations[index] = mutation
        logger("Notti: device not registered yet - replaced the queued \(description) with the latest value")
        return
      }
      if pendingMutations.count >= Self.maxPendingMutations {
        if let telemetryIndex = pendingMutations.firstIndex(where: { $0.coalesceKey != nil }) {
          let dropped = pendingMutations.remove(at: telemetryIndex)
          logger("Notti: pending-mutation queue full - dropping queued telemetry (\(dropped.description))")
        } else if coalesceKey != nil {
          logger("Notti: pending-mutation queue full of user mutations - dropping telemetry (\(description))")
          return
        } else {
          let dropped = pendingMutations.removeFirst()
          logger("Notti: pending-mutation queue full - dropping the oldest queued mutation (\(dropped.description))")
        }
      }
      pendingMutations.append(mutation)
      logger("Notti: device not registered yet - queued \(description) until registration completes")
      return
    }
    work(client, deviceId, token)
  }

  /// Flushes, in call order, every mutation issued before registration
  /// completed. In-memory only: anything still queued when the process dies
  /// is dropped rather than replayed with stale state (spec Edge Case).
  private func flushPendingMutations(_ client: NottiApiClient, deviceId: String, token: String) {
    guard !pendingMutations.isEmpty else { return }
    let queued = pendingMutations
    pendingMutations.removeAll()
    logger("Notti: registration complete - flushing \(queued.count) queued mutation(s)")
    for mutation in queued {
      mutation.work(client, deviceId, token)
    }
  }

  /// workQueue-only. Drains the offline event queue (`NottiEventStore`),
  /// reporting each pending event to the backend and removing it once the
  /// backend has acknowledged it. Write-ahead persistence: the event is
  /// persisted before any report attempt, so a crash mid-flush never loses a
  /// queued event - at worst it is re-reported, which the backend treats as
  /// idempotent. A no-op until the device is registered with a push token:
  /// there is nothing to report against, and `reportEvent` needs the token to
  /// prove the event belongs to the receiving device.
  ///
  /// On a terminal `.failure` (`terminal == true`, a 4xx the backend will
  /// never accept - e.g. a stale token 403 per spec SDKCTR-11; 408/429 are
  /// NOT terminal) the event is removed too: re-attempting it on every future
  /// flush would fail identically forever. On a transient `.failure`
  /// (`terminal == false`, retry cap exhausted on network/5xx/408/429) the
  /// event STAYS queued and the flush STOPS (review item 6): the backend or
  /// network is down, so trying the remaining events would only pin the
  /// serial work queue for 5 attempts x 15s timeout + backoff *per event*
  /// (tens of minutes for a full queue) while login/tags wait behind it. The
  /// next registration success, app foreground, or network regain resumes.
  private func flushEventQueue() {
    guard let client = apiClient, let token = deviceStore.getLastToken() else { return }
    for event in eventStore.all() {
      switch client.reportEvent(
        notificationId: event.notificationId,
        deliveryId: event.deliveryId,
        type: event.type,
        token: token
      ) {
      case .success:
        eventStore.remove(id: event.id)
      case .failure(let message, let terminal):
        if terminal {
          logger("Notti.flushEventQueue: event report terminally failed (\(message)) - event dropped")
          eventStore.remove(id: event.id)
        } else {
          logger("Notti.flushEventQueue: event report failed (\(message)) - event stays queued, flush stopped")
          return
        }
      }
    }
  }

  private func patchSubscribed(
    _ client: NottiApiClient,
    deviceId: String,
    token: String,
    _ subscribed: Bool,
    logContext: String
  ) {
    let result = client.patchDevice(deviceId: deviceId, token: token, fields: ["subscribed": subscribed])
    switch result {
    case .success:
      deviceStore.setSubscribed(subscribed)
    case .failure(let message):
      logger("Notti.\(logContext): PATCH failed (\(message)) - not retried")
    }
  }
}
