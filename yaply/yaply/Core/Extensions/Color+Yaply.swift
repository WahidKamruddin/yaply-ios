import SwiftUI

// In-app Light/Dark/System appearance override, layered on top of the
// dynamic-color tokens below (which already follow system appearance for
// free). Backed by @AppStorage("appearanceMode") and applied via
// .preferredColorScheme(_:) on the root view in ContentView.swift.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

// Dynamic light/dark color, the SwiftUI-native equivalent of a CSS custom
// property with a light/dark override — lets every yaply* token below
// follow system appearance with zero per-view branching.
extension Color {
    init(light: Color, dark: Color) {
        self.init(UIColor { $0.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light) })
    }
}

// yaply color palette — mirrors the web app's Tailwind color values
// (see ../../../../../src/styles.css for the source of truth: `.light` /
// `:root` custom properties). Every token is a dynamic Color so light/dark
// mode both "just work" without call sites branching on colorScheme.
extension Color {
    // #1a2744 / #e9eefb — primary text ("ink")
    static let yaplyPrimary = Color(
        light: Color(red: 0.102, green: 0.153, blue: 0.267),
        dark: Color(red: 0.914, green: 0.933, blue: 0.984)
    )
    // #5b8def — blue accent, buttons, highlights. Same value in both
    // themes on the web (`--primary` doesn't change under `:root`) —
    // intentionally has no dark override, don't "fix" this.
    static let yaplyAccent = Color(red: 0.357, green: 0.553, blue: 0.937)
    // #4a7de4 / #3b6fe0 — gradient end-stop for own-message bubbles, FAB, avatars
    static let yaplyAccentDark = Color(
        light: Color(red: 0.290, green: 0.490, blue: 0.894),
        dark: Color(red: 0.231, green: 0.435, blue: 0.878)
    )
    // #dce7f8 / rgba(143,184,255,.14) — borders, dividers
    static let yaplyBorder = Color(
        light: Color(red: 0.863, green: 0.906, blue: 0.973),
        dark: Color(red: 0.561, green: 0.722, blue: 1.0).opacity(0.14)
    )
    // #f0f4fc / rgba(143,184,255,.10) — softer border, used on bubbles/inputs
    static let yaplyBorderSoft = Color(
        light: Color(red: 0.941, green: 0.957, blue: 0.988),
        dark: Color(red: 0.561, green: 0.722, blue: 1.0).opacity(0.10)
    )
    // #edf1fa / #070d1a — page background
    static let yaplyBackground = Color(
        light: Color(red: 0.929, green: 0.945, blue: 0.980),
        dark: Color(red: 0.027, green: 0.051, blue: 0.102)
    )
    // #ffffff / #0a1120 — elevated surface (rows, headers, sheets)
    static let yaplySurface = Color(
        light: .white,
        dark: Color(red: 0.039, green: 0.067, blue: 0.125)
    )
    // #ffffff / #0d1526 — card fill (other-message bubbles, list cards)
    static let yaplyCard = Color(
        light: .white,
        dark: Color(red: 0.051, green: 0.082, blue: 0.149)
    )
    // #f3f7ff / rgba(143,184,255,.08) — tinted fill: search bars, reply
    // quotes, system-message pills, command-feedback banners
    static let yaplyTint = Color(
        light: Color(red: 0.953, green: 0.969, blue: 1.0),
        dark: Color(red: 0.561, green: 0.722, blue: 1.0).opacity(0.08)
    )
    // #dce7f8 / rgba(143,184,255,.16) — stronger tint for active/selected rows
    static let yaplyTintStrong = Color(
        light: Color(red: 0.863, green: 0.906, blue: 0.973),
        dark: Color(red: 0.561, green: 0.722, blue: 1.0).opacity(0.16)
    )
    // #9ab0cc / #5c718f — secondary text, icons ("faint")
    static let yaplySecondary = Color(
        light: Color(red: 0.604, green: 0.690, blue: 0.800),
        dark: Color(red: 0.361, green: 0.443, blue: 0.561)
    )
    // #6b84ab / #8ba1c7 — tertiary text ("dim")
    static let yaplyTertiary = Color(
        light: Color(red: 0.420, green: 0.518, blue: 0.671),
        dark: Color(red: 0.545, green: 0.631, blue: 0.780)
    )
    // #ef4444 / #ff8080 — destructive actions
    static let yaplyDanger = Color(
        light: Color(red: 0.937, green: 0.267, blue: 0.267),
        dark: Color(red: 1.0, green: 0.502, blue: 0.502)
    )
    // #22c55e — online presence dot (same both themes)
    static let yaplyOnline = Color(red: 0.133, green: 0.773, blue: 0.369)
    // #b0c0d8 / #46587a — offline presence dot
    static let yaplyOffline = Color(
        light: Color(red: 0.690, green: 0.753, blue: 0.847),
        dark: Color(red: 0.275, green: 0.345, blue: 0.478)
    )
    // #0b9e74 / #6fe0b8 — success/confirmed accent
    static let yaplyMint = Color(
        light: Color(red: 0.043, green: 0.620, blue: 0.455),
        dark: Color(red: 0.435, green: 0.878, blue: 0.722)
    )
    // Shadow for cards — derives from the now-dynamic border token
    static let yaplyShadow = Color.yaplyBorder.opacity(0.6)
    // Confirmed/success green — shared token for "confirmed event" / "budget"
    // icon tiles. Derived from yaplyMint so it gets a correct dark variant
    // for free; kept under its original name since call sites already
    // reference it.
    static let yaplyConfirmedGreen = Color(
        light: Color.yaplyMint.opacity(0.12),
        dark: Color.yaplyMint.opacity(0.18)
    )
}
