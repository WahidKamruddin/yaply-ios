import SwiftUI

/// Landing spot for chat-screen nav bar styling. Today every screen uses the
/// stock inline nav bar (`.navigationBarTitleDisplayMode(.inline)`, no custom
/// background/material) — there is no existing seam for it. This scaffold
/// exists so a UI-style redesign branch has one place to add custom chrome
/// (e.g. a translucent blur header, or a colored/rounded nav bar) instead of
/// editing `.toolbar`/`.navigationBarTitleDisplayMode` call sites directly.
///
/// Current values reproduce today's stock SwiftUI nav bar exactly — this is
/// a scaffold only, not a visual change.
enum NavChrome {
    static let titleDisplayMode: NavigationBarItem.TitleDisplayMode = .inline

    /// `nil` = system default background/material (today's behavior).
    static let toolbarBackground: Material? = nil
}
