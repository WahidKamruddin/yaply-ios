import Foundation
import Supabase

// Backs the Home tab — mirrors web's Dashboard.tsx / useDashboard.ts.
// Reminders and events are fetched unfiltered by conversation (RLS scopes
// rows to conversations the caller belongs to); the conversation list itself
// is supplied by the caller (ConversationListViewModel already loads it for
// the Chats tab, no need to fetch it twice).
@Observable
final class HomeViewModel {
    private(set) var reminders: [YaplyReminder] = []
    private(set) var events: [YaplyEvent] = []
    private(set) var friends: [Friend] = []
    private(set) var displayName: String = ""
    private(set) var isLoading = false

    private let reminderRepo = ReminderRepository()
    private let eventRepo = EventRepository()
    private let friendsRepo = FriendsRepository()
    private let conversationRepo = ConversationRepository()

    var upcomingEvents: [YaplyEvent] {
        events.filter { event in
            event.isPlanning || (event.startsAt.map { $0 > Date() } ?? false)
        }
        .prefix(6)
        .map { $0 }
    }

    func load(userId: UUID) async {
        isLoading = true
        defer { isLoading = false }

        async let remindersFetch = try? reminderRepo.fetchAllPending()
        async let eventsFetch = try? eventRepo.fetchAllRecent()
        async let friendsFetch = try? friendsRepo.fetchFriends(userId: userId)
        async let profileFetch: Profile? = try? await supabase
            .from("profiles")
            .select("id, username, display_name, avatar_url, bio, is_online, last_seen_at, created_at, updated_at")
            .eq("id", value: userId.uuidString)
            .single()
            .execute()
            .value

        reminders = await remindersFetch ?? []
        events = await eventsFetch ?? []
        friends = (await friendsFetch ?? []).sorted { $0.profile.name.localizedCaseInsensitiveCompare($1.profile.name) == .orderedAscending }
        displayName = await profileFetch?.name ?? ""
    }

    // Opens the existing DM with this friend, creating one if none exists yet.
    func directConversationId(for friendUserId: UUID, currentUserId: UUID, existing: [ConversationListItem]) async -> UUID? {
        if let match = existing.first(where: { !$0.isGroup && $0.otherMember(currentUserId: currentUserId)?.userId == friendUserId }) {
            return match.id
        }
        return try? await conversationRepo.createDirectConversation(userId: currentUserId, otherUserId: friendUserId)
    }

    static func greeting(name: String) -> String {
        let hour = Calendar.current.component(.hour, from: Date())
        let base = hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening"
        return name.isEmpty ? base : "\(base), \(name)"
    }

    static func relativeTime(_ date: Date) -> String {
        let diffMin = Int((date.timeIntervalSinceNow / 60).rounded())
        if abs(diffMin) < 1 { return "now" }
        if abs(diffMin) < 60 { return diffMin > 0 ? "in \(diffMin)m" : "\(-diffMin)m ago" }
        let diffHr = Int((Double(diffMin) / 60).rounded())
        if abs(diffHr) < 24 { return diffHr > 0 ? "in \(diffHr)h" : "\(-diffHr)h ago" }
        let diffDay = Int((Double(diffHr) / 24).rounded())
        return diffDay > 0 ? "in \(diffDay)d" : "\(-diffDay)d ago"
    }
}
