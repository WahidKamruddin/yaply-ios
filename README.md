# yaply-ios

Native iOS app for yaply — E2E encrypted messaging. Built with Swift + SwiftUI, sharing the same Supabase backend as the web app.

## Requirements

- Xcode 15+
- iOS 17+ deployment target
- Swift 5.9+

## Getting Started

1. Open `Package.swift` in Xcode (File → Open → select Package.swift)
2. Xcode will resolve SPM packages automatically
3. Copy `Config.xcconfig.example` → `Config.xcconfig` and fill in your Supabase credentials
4. Build and run on simulator or device

## Dependencies

| Package | Purpose |
|---------|---------|
| [supabase-swift](https://github.com/supabase/supabase-swift) | Auth, database, realtime, storage |
| [Kingfisher](https://github.com/onevcat/Kingfisher) | Async image loading |
| [keychain-swift](https://github.com/evgenyneu/keychain-swift) | Secure key storage |

## Sister Projects

- [`../`](../) — Web app (React + TanStack + Supabase)
- `yaply-android/` — Android app (Kotlin + Jetpack Compose) — planned
