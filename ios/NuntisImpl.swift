import Foundation

// SPEC_DEVIATION: Spike file for T2 (AD-002 research) — proves a TurboModule's
// business logic can be written in Swift and called from the Obj-C++ entry
// class (Nuntis.mm) via the auto-generated "Nuntis-Swift.h" header. Kept as
// the confirmed pattern per design.md; real v1 logic (T14) reuses this same
// bridging shape, not this exact file's placeholder body.
@objc(NuntisImpl)
public class NuntisImpl: NSObject {
  @objc public func multiply(_ a: Double, b: Double) -> NSNumber {
    return NSNumber(value: a * b)
  }
}
