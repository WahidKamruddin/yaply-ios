import SwiftUI

// yaply color palette — mirrors the web app's Tailwind color values
extension Color {
    // #1a2744 — dark navy, primary text
    static let yaplyPrimary = Color(red: 0.102, green: 0.153, blue: 0.267)
    // #5b8def — blue accent, buttons, highlights
    static let yaplyAccent = Color(red: 0.357, green: 0.553, blue: 0.937)
    // #dce7f8 — light blue, borders, dividers
    static let yaplyBorder = Color(red: 0.863, green: 0.906, blue: 0.973)
    // #edf1fa — very light blue, page background
    static let yaplyBackground = Color(red: 0.929, green: 0.945, blue: 0.980)
    // #9ab0cc — medium blue-gray, secondary text, icons
    static let yaplySecondary = Color(red: 0.604, green: 0.690, blue: 0.800)
    // #6b84ab — blue-gray, tertiary text
    static let yaplyTertiary = Color(red: 0.420, green: 0.518, blue: 0.671)
    // Shadow for cards
    static let yaplyShadow = Color(red: 0.863, green: 0.906, blue: 0.973).opacity(0.6)
}
