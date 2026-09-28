import SwiftUI

/// Shared nav-bar chrome constants + the `.navChrome()` modifier every
/// screen's toolbar routes through, so `ChatStyle` can restyle every nav bar
/// app-wide from one place.
enum NavChrome {
    static let titleDisplayMode: NavigationBarItem.TitleDisplayMode = .inline

    /// `nil` = system default background/material (yaply/Messenger's flat
    /// stock look). iMessage gets a translucent blur, matching its header
    /// and composer chrome.
    static var toolbarBackground: Material? {
        ChatStyle.current == .imessage ? .ultraThinMaterial : nil
    }
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
