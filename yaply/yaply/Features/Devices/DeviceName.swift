import Foundation
import UIKit

// Human-readable name for the install registering itself in the `devices`
// table. Written once, at first registration only — a later login must never
// overwrite it, or a device the user renamed would silently revert.
//
// Mirrors src/lib/deviceName.ts on web. The platform is baked into the
// generated string *and* stored separately in `devices.platform`, so a rename
// can't lose which client a row belongs to.
enum DeviceName {

    static let platform = "ios"

    // e.g. "iPhone (App)". UIDevice.name is the user's own device name
    // ("Wahid's iPhone") on older systems but is redacted to the model name on
    // iOS 16+ without an entitlement — either is a fine label, and the "(App)"
    // suffix is what distinguishes this row from the website's.
    @MainActor
    static func generate() -> String {
        let name = UIDevice.current.name
        let model = UIDevice.current.model
        let base = name.isEmpty ? model : name
        return "\(base) (App)"
    }
}
