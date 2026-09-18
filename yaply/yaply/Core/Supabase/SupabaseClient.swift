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

    guard let url = URL(string: urlString), !urlString.isEmpty, !key.isEmpty else {
        fatalError(
            "Missing Supabase config. Copy Config.xcconfig.example → Config.xcconfig and fill in your keys."
        )
    }

    return SupabaseClient(supabaseURL: url, supabaseKey: key, options: .init(
        auth: .init(emitLocalSessionAsInitialSession: true),
        global: .init(logger: RealtimeConsoleLogger())
    ))
}()

// Prints supabase-swift's own Realtime log lines, prefixed `[RT]`, to the device console
// alongside our `[Realtime]` lines. Without it the SDK's state transitions (subscribe
// timeouts, server closes, heartbeat timeouts) are invisible, which is what made the
// "live messages only arrive after a refresh" bug so hard to pin down. Other SDK
// systems (Auth, PostgREST) are left out as noise.
nonisolated struct RealtimeConsoleLogger: SupabaseLogger {
    func log(message: SupabaseLogMessage) {
        guard message.system == "Realtime" else { return }
        // Fires every 25s while healthy; a heartbeat *timeout* is still printed.
        if message.message == "heartbeat received" { return }
        print("[RT] \(message.level) \(message.message)")
    }
}
