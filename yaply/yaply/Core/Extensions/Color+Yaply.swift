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
    // #0b93f6 — iMessage blue accent, buttons, highlights. Retinted for
    // ui/imessage-style (was #5b8def); intentionally has no dark override,
    // matching the original token's behavior.
    static let yaplyAccent = Color(red: 0.043, green: 0.576, blue: 0.965)
    // #0a7cff — gradient end-stop for own-message bubbles, FAB, avatars.
    // Retinted for ui/imessage-style (was #4a7de4 / #3b6fe0) to complete
    // iMessage's documented #0b93f6 -> #0a7cff bubble gradient; same value
    // both themes, matching real iMessage.
    static let yaplyAccentDark = Color(red: 0.039, green: 0.486, blue: 1.000)
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
    // #FFFFFF / #000000 — page background. Retinted for ui/imessage-style
    // (was #edf1fa / #070d1a) to a neutral white/true-black chat canvas,
    // matching Messages.app instead of yaply's tinted default.
    static let yaplyBackground = Color(
        light: .white,
        dark: .black
    )
    // #ffffff / #0a1120 — elevated surface (rows, headers, sheets)
    static let yaplySurface = Color(
        light: .white,
        dark: Color(red: 0.039, green: 0.067, blue: 0.125)
    )
    // #E5E5EA / #26262A — card fill (other-message bubbles, list cards).
    // Retinted for ui/imessage-style (was #ffffff / #0d1526) to iMessage's
    // exact incoming-bubble gray, both themes.
    static let yaplyCard = Color(
        light: Color(red: 0.898, green: 0.898, blue: 0.918),
        dark: Color(red: 0.149, green: 0.149, blue: 0.165)
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
    // #8299b8 / #5f7396 — secondary text, icons ("faint"). Darkened from
    // #9ab0cc / #5c718f to clear ~3:1 on small text; matches web's --faint.
    static let yaplySecondary = Color(
        light: Color(red: 0.510, green: 0.600, blue: 0.722),
        dark: Color(red: 0.373, green: 0.451, blue: 0.588)
    )
    // #5a7399 / #8ba1c7 — tertiary text ("dim"). Light darkened from #6b84ab
    // to match web's --dim.
    static let yaplyTertiary = Color(
        light: Color(red: 0.353, green: 0.451, blue: 0.600),
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
