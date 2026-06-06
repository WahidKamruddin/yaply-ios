import Supabase
import Foundation

// Shared Supabase client — mirrors src/lib/supabase.ts.
// In an Xcode project: set SUPABASE_URL and SUPABASE_ANON_KEY in Config.xcconfig,
// reference them in Info.plist, and they're read from Bundle.main here.
// Fallback to environment variables for testing/CI.
let supabase: SupabaseClient = {
    let urlString = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String
        ?? ProcessInfo.processInfo.environment["SUPABASE_URL"]
        ?? ""
    let key = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String
        ?? ProcessInfo.processInfo.environment["SUPABASE_ANON_KEY"]
        ?? ""

    // Debug: Print what we're getting
    print("🔍 DEBUG: urlString = '\(urlString)'")
    print("🔍 DEBUG: key = '\(key.prefix(10))...'")

    guard let url = URL(string: urlString), !urlString.isEmpty, !key.isEmpty else {
        fatalError(
            "Missing Supabase config. Copy Config.xcconfig.example → Config.xcconfig and fill in your keys."
        )
    }

    return SupabaseClient(supabaseURL: url, supabaseKey: key)
}()
