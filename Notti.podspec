require "json"

package = JSON.parse(File.read(File.join(__dir__, "package.json")))

Pod::Spec.new do |s|
  s.name         = "Notti"
  s.version      = package["version"]
  s.summary      = package["description"]
  s.homepage     = package["homepage"]
  s.license      = package["license"]
  s.authors      = package["author"]

  s.platforms    = { :ios => min_ios_version_supported }
  s.source       = { :git => "https://github.com/zeeplabs/zeep-notti-react-native.git", :tag => "#{s.version}" }

  s.swift_version = "5.9"
  s.default_subspec = "Core"

  # The default subspec: the Turbo Module itself, linked into the main app
  # target via autolinking exactly as before this split. Kept as its own
  # subspec (rather than the root spec) so `default_subspec` can steer plain
  # `pod 'Notti'` installs here while `NotificationServiceExtension` stays
  # opt-in — see docs/adr/002-....md.
  s.subspec "Core" do |core|
    core.source_files = "ios/**/*.{h,m,mm,swift,cpp}"
    core.exclude_files = ["ios/Tests/**/*", "ios/NotificationServiceExtension/**/*"]
    core.private_header_files = "ios/**/*.h"
    # Segment telemetry P3: `NottiImpl` reads the host app's last cached
    # location fix and reverse-geocodes it to a country code (CoreLocation).
    # The SDK never requests location permission itself; it only reads when
    # the host app has already granted it (see spec.md P3 / design.md).
    core.frameworks = "CoreLocation"
    # M6 (pre-release review round 3): a source pod gets no manifest unless
    # one ships as its own resource bundle - Xcode's privacy report only
    # aggregates `PrivacyInfo.xcprivacy` from bundles embedded in the final
    # product, not stray files pulled in alongside `.swift` sources. Without
    # this, only the example app declared the SDK's own UserDefaults
    # required-reason API usage, leaving every real integrator to add it
    # themselves or risk the ITMS-91053 warning on submission.
    core.resource_bundles = { "Notti_Privacy" => ["ios/PrivacyInfo.xcprivacy"] }
    install_modules_dependencies(core)
  end

  # Rich-push attachment helper for a consumer's own Notification Service
  # Extension target. Deliberately has NO dependency on React/TurboModule —
  # an NSE is a separate sandboxed process that never runs the RN runtime.
  # Consumers add this in its own Podfile target, never alongside the app's
  # main target. See docs/adr/002-....md.
  s.subspec "NotificationServiceExtension" do |nse|
    nse.source_files = "ios/NotificationServiceExtension/**/*.swift"
    nse.exclude_files = ["ios/NotificationServiceExtension/Tests/**/*"]
    nse.frameworks = "UserNotifications"
    # M6: the NSE target is a separate bundle from the app - it needs its own
    # manifest declaring the `FileManager.attributesOfItem` file-timestamp
    # read used to enforce the attachment size cap (A2).
    nse.resource_bundles = { "Notti_NSE_Privacy" => ["ios/NotificationServiceExtension/PrivacyInfo.xcprivacy"] }

    # Real, injectable-`URLSession` coverage for the helper (B3, found
    # missing in pre-release review). `StubURLProtocol` is compiled directly
    # into this test target from `ios/Tests/` rather than imported: it lives
    # in the Core subspec's separate module, which this subspec must never
    # depend on (see the module-note above `Core`). No app host needed - the
    # helper is a plain Swift/Foundation/UserNotifications logic unit.
    nse.test_spec "Tests" do |test|
      test.source_files = [
        "ios/NotificationServiceExtension/Tests/**/*.swift",
        "ios/Tests/StubURLProtocol.swift",
      ]
      test.requires_app_host = false
    end
  end
end
