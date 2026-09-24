import Foundation

// Every registered device per user, cached for a short TTL so a text send doesn't
// pay two `devices` round-trips before its RPC. Mirrors web's `devicesMemCache`:
// global rather than per-requester, because a user's public device list is the
// same no matter who asks.
//
// Holds *all* of a user's rows, not just active ones, so one query answers both
// questions the send path asks: "does this member have any device at all" (the
// phase-1 fallback) and "which devices get an envelope" (the 90-day window).
//
// Staleness is bounded by the TTL, the same trade web makes: a peer device that
// registered in the last minute can miss one message's envelope. Our own device is
// never subject to that — `invalidate` runs whenever this install (re)registers.
@MainActor
enum DeviceListCache {
    private static let ttl: Duration = .seconds(60)

    private struct Entry {
        let rows: [DeviceRow]
        let fetchedAt: ContinuousClock.Instant
    }

    private static var entries: [UUID: Entry] = [:]
    /// Bumped by `invalidate`. A fetch that started before an invalidation must not
    /// write its (possibly pre-registration) result back into the cache.
    private static var generation = 0

    /// Rows for every requested user, keyed by user id. A user with no devices maps
    /// to an empty array. Fetches only the users that are missing or expired.
    static func devices(for userIds: [UUID], repository: MessageRepository) async throws -> [UUID: [DeviceRow]] {
        let now = ContinuousClock.now
        var result: [UUID: [DeviceRow]] = [:]
        var missing: [UUID] = []
        for id in Set(userIds) {
            if let entry = entries[id], now - entry.fetchedAt < ttl {
                result[id] = entry.rows
            } else {
                missing.append(id)
            }
        }
        guard !missing.isEmpty else { return result }

        let startedAt = generation
        let rows = try await repository.fetchDeviceRows(userIds: missing)
        let grouped = Dictionary(grouping: rows, by: \.userId)
        let fetchedAt = ContinuousClock.now
        for id in missing {
            let userRows = grouped[id] ?? []
            result[id] = userRows
            if generation == startedAt {
                entries[id] = Entry(rows: userRows, fetchedAt: fetchedAt)
            }
        }
        return result
    }

    /// Warms the cache when a conversation opens so the first send is one round-trip.
    static func prefetch(userIds: [UUID], repository: MessageRepository) {
        guard !userIds.isEmpty else { return }
        Task { _ = try? await devices(for: userIds, repository: repository) }
    }

    static func invalidate(userId: UUID) {
        generation += 1
        entries[userId] = nil
    }
}
