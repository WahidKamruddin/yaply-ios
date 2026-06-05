// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "yaply",
    platforms: [
        .iOS(.v17)
    ],
    dependencies: [
        // Supabase — auth, database (PostgREST), realtime, storage
        .package(url: "https://github.com/supabase/supabase-swift.git", from: "2.0.0"),
        // Async image loading for avatars and media previews
        .package(url: "https://github.com/onevcat/Kingfisher.git", from: "7.0.0"),
        // Keychain wrapper — stores encryption keys and session data
        .package(url: "https://github.com/evgenyneu/keychain-swift.git", from: "20.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "yaply",
            dependencies: [
                .product(name: "Supabase", package: "supabase-swift"),
                .product(name: "Kingfisher", package: "Kingfisher"),
                .product(name: "KeychainSwift", package: "keychain-swift"),
            ],
            path: "Sources/yaply"
        )
    ]
)
