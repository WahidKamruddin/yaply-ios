import SwiftUI

/// Shared nav-bar chrome constants + the `.navChrome()` modifier every
/// screen's toolbar routes through, so a UI-style redesign branch can
/// restyle every nav bar app-wide by editing the two constants below.
///
/// Values tuned for ui/imessage-style: a translucent blurred background,
/// matching iMessage's blur-backed header and composer chrome.
enum NavChrome {
    static let titleDisplayMode: NavigationBarItem.TitleDisplayMode = .inline

    /// `nil` = system default background/material (today's stock behavior).
    static let toolbarBackground: Material? = .ultraThinMaterial
}

extension View {
    /// Applies `NavChrome`'s title-display-mode and (if set) a translucent
    /// toolbar background. Every screen with a nav bar should call this
    /// instead of `.navigationBarTitleDisplayMode(.inline)` directly.
    @ViewBuilder
    func navChrome() -> some View {
        if let material = NavChrome.toolbarBackground {
            self
                .navigationBarTitleDisplayMode(NavChrome.titleDisplayMode)
                .toolbarBackground(material, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
        } else {
            self.navigationBarTitleDisplayMode(NavChrome.titleDisplayMode)
        }
    }
}
