import Supabase
import Foundation

// Shared Supabase client — mirrors src/lib/supabase.ts.
// In an Xcode project: set SUPABASE_URL and SUPABASE_ANON_KEY in Config.xcconfig,
// reference them in Info.plist, and they're read from Bundle.main here.
// Fallback to environment variables for testing/CI.
// MARK: — Credentials
// Reads from Info.plist (set via Config.xcconfig) with a direct fallback.
// To use xcconfig: add SUPABASE_URL and SUPABASE_ANON_KEY to Config.xcconfig,
// then reference them in Info.plist as $(SUPABASE_URL) / $(SUPABASE_ANON_KEY).
private let _supabaseURL    = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL")    as? String ?? ""
private let _supabaseAnonKey = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String ?? ""

let supabase: SupabaseClient = {
    let urlString = _supabaseURL.isEmpty    ? "https://YOUR_PROJECT.supabase.co"  : _supabaseURL
    let key       = _supabaseAnonKey.isEmpty ? "YOUR_ANON_KEY"                    : _supabaseAnonKey

    guard let url = URL(string: urlString), url.host != nil else {
        fatalError("Invalid Supabase URL: \(urlString). Replace the placeholder in SupabaseClient.swift.")
    }
    return SupabaseClient(supabaseURL: url, supabaseKey: key)
}()
