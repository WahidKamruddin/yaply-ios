import Foundation
import Network
import Realtime
import Supabase
import UIKit

// Keeps every Supabase Realtime subscription alive across network interruptions.
//
// The WebSocket carries *only* change events — every actual fetch goes over plain
// HTTPS/PostgREST. That asymmetry is what makes a dead subscription so hard to see:
// the app loads, sends and receives pushes perfectly while silently receiving nothing
// live. There is no HTTP fallback for *receiving*; the "broadcast() is automatically
// falling back to REST API" log only means a channel we tried to send on isn't joined.
//
// supabase-swift 2.46 behaviours this type exists to work around (web's supabase-js
// handles all of them itself, which is why web realtime never needed any of this):
//
// - After the socket drops and auto-reconnects, `rejoinChannels()` is a no-op for every
//   channel still marked `.subscribed` — which is all of them, since a dead socket never
//   delivers a `phx_close`. The server has no join on the new socket; nothing arrives.
// - `channel(topic)` returns the existing instance while that topic is still in the
//   client's map, and `removeChannel` / a server `phx_close` evict *by topic* with no
//   join_ref check. So a fire-and-forget removal racing a rebuild of the same topic
//   either hands back the dying instance or evicts the new one — the join reply then
//   has nowhere to go and the subscribe times out forever. `channel(_:)` / `remove(_:)`
//   below serialise the two per topic.
// - After iOS suspends the app the TCP connection dies silently; the socket keeps
//   reporting `.connected` until a heartbeat goes unanswered (~50s + a 7s reconnect
//   delay). Resubscribing onto it sends joins into the void, so recovery on foreground
//   and network changes first forces a fresh socket.
// - A channel the server closes (token expiry, errors) just goes quiet; its
//   `postgresChange` streams never finish. `watch(_:label:onDrop:)` notices.
//
// Resubscribing only delivers *future* events, so every rebuild must be followed by a
// refetch or the UI silently reattaches and keeps showing stale data.
//
// View models register a reconnect closure; recovery signals run all of them, or only
// the failing ones.
@MainActor
@Observable
final class RealtimeConnectionMonitor {
    static let shared = RealtimeConnectionMonitor()

    /// True once recovery has been failing long enough to be worth telling the user
    /// about. Drives `ReconnectingPillView`.
    private(set) var isReconnecting = false

    /// How long subscribing has to keep failing before the pill appears. An ordinary
    /// foreground re-establishes the socket in well under a second; without this delay
    /// the pill would flash on every single one.
    private static let unhealthyGrace: Duration = .seconds(4)
    /// Coalesces the foreground + path-change + socket-status signals that typically
    /// all land within the same second of a recovery.
    private static let sweepDebounce: Duration = .milliseconds(750)
    /// Backstop re-sweep while still unhealthy — the "never give up" guarantee.
    private static let unhealthyRetryInterval: Duration = .seconds(30)
    /// A socket that connected this recently is trusted rather than reset — stops the
    /// launch-time path/foreground signals from tearing down a brand-new connection.
    private static let freshSocketWindow: Duration = .seconds(5)
    /// A channel dropping again within this window gets the long delay before its
    /// rebuild, so a server that closes every join can't spin us in a tight loop.
    private static let repeatDropWindow: Duration = .seconds(60)

    private struct Subscriber {
        let label: String
        let reconnect: () async -> Void
    }

    private enum SweepScope {
        case all(resetSocket: Bool)
        case failingOnly
    }

    private var subscribers: [UUID: Subscriber] = [:]
    private var failingLabels: Set<String> = []

    private var pathMonitor: NWPathMonitor?
    private var lastPathSatisfied = true
    private var lastInterface: NWInterface.InterfaceType?
    private var foregroundObserver: NSObjectProtocol?
    private var statusSubscription: RealtimeSubscription?
    private var lastSocketConnected = true
    private var lastConnectedAt: ContinuousClock.Instant?
    /// Set around a socket reset we started ourselves, so the connected→lost→connected
    /// cycle it causes doesn't trigger a second, redundant sweep.
    private var suppressReconnectSweepUntil: ContinuousClock.Instant?
    // Both NWPathMonitor and onStatusChange replay their current value the moment we
    // subscribe. Treating that first callback as a transition would fire a sweep during
    // launch and tear down a subscription that was still being set up, so the first one
    // only seeds state.
    private var hasSeenInitialPath = false
    private var hasEverConnected = false

    private var sweepTask: Task<Void, Never>?
    private var pendingSweepTask: Task<Void, Never>?
    private var pendingScope: SweepScope?
    private var pillTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?

    /// In-flight removals keyed by the channel's full topic (`realtime:<topic>`).
    private var pendingRemovals: [String: (id: UUID, task: Task<Void, Never>)] = [:]
    /// Channels we are tearing down on purpose — `watch` must not treat their
    /// unsubscribe as a drop.
    private var intentionalRemovals: Set<ObjectIdentifier> = []
    private var lastDropAt: [String: ContinuousClock.Instant] = [:]

    private init() {}

    // MARK: - Lifecycle

    /// Idempotent — safe to call on every appearance of the root view.
    func start() {
        guard pathMonitor == nil else { return }

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            let satisfied = path.status == .satisfied
            let interface = Self.primaryInterface(of: path)
            Task { @MainActor [weak self] in
                self?.handlePathUpdate(satisfied: satisfied, interface: interface)
            }
        }
        monitor.start(queue: DispatchQueue(label: "yaply.realtime.path"))
        pathMonitor = monitor

        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor [weak self] in
                self?.requestSweep(.all(resetSocket: true), reason: "foreground")
            }
        }

        // Catches a server-initiated close, which the SDK never retries on its own, and
        // the SDK's own auto-reconnect, whose channel rejoin is a no-op (see top).
        statusSubscription = supabase.realtimeV2.onStatusChange { status in
            Task { @MainActor [weak self] in
                self?.handleSocketStatus(status)
            }
        }
    }

    func stop() {
        pathMonitor?.cancel()
        pathMonitor = nil
        if let observer = foregroundObserver {
            NotificationCenter.default.removeObserver(observer)
            foregroundObserver = nil
        }
        statusSubscription?.cancel()
        statusSubscription = nil
        sweepTask?.cancel(); sweepTask = nil
        pendingSweepTask?.cancel(); pendingSweepTask = nil
        pendingScope = nil
        pillTask?.cancel(); pillTask = nil
        retryTask?.cancel(); retryTask = nil
        failingLabels.removeAll()
        isReconnecting = false
    }

    // MARK: - Registration

    /// Registers a reconnect closure. Capture `[weak self]` in `reconnect` — the monitor
    /// outlives every view model that registers with it. `label` must match the label
    /// the subscriber passes to `subscribe` so a targeted sweep can find it.
    func register(label: String, reconnect: @escaping () async -> Void) -> UUID {
        let token = UUID()
        subscribers[token] = Subscriber(label: label, reconnect: reconnect)
        return token
    }

    func unregister(_ token: UUID?) {
        guard let token else { return }
        subscribers.removeValue(forKey: token)
    }

    // MARK: - Channel creation / removal

    /// Use instead of `supabase.channel(_:)`. Waits for any in-flight removal of the
    /// same topic first, so the SDK can't hand back the dying instance or evict the new
    /// one when that removal completes.
    static func channel(_ topic: String) async -> RealtimeChannelV2 {
        let fullTopic = "realtime:\(topic)"
        while let pending = shared.pendingRemovals[fullTopic] {
            await pending.task.value
        }
        return supabase.channel(topic)
    }

    /// Use instead of `Task { await supabase.removeChannel(ch) }`. Still fire-and-forget
    /// for the caller, but recorded so a later `channel(_:)` of the same topic waits.
    static func remove(_ channel: RealtimeChannelV2?) {
        guard let channel else { return }
        let monitor = shared
        let topic = channel.topic
        let key = ObjectIdentifier(channel)
        let previous = monitor.pendingRemovals[topic]?.task
        let id = UUID()
        monitor.intentionalRemovals.insert(key)
        let task = Task { @MainActor in
            await previous?.value
            await supabase.removeChannel(channel)
            monitor.intentionalRemovals.remove(key)
            if monitor.pendingRemovals[topic]?.id == id {
                monitor.pendingRemovals[topic] = nil
            }
        }
        monitor.pendingRemovals[topic] = (id, task)
    }

    // MARK: - Subscribe helper

    /// `subscribeWithError()` can throw (e.g. the socket is still connecting or timed out
    /// on a slow/cold-launch network path). Silently swallowing that failure leaves the
    /// channel permanently unsubscribed, so this retries forever rather than giving up.
    /// Unbounded is safe because the loop only ever runs inside a `realtimeTask` that
    /// every `startRealtime` cancels on teardown.
    ///
    /// Non-critical channels (typing) don't drive the pill or the periodic retry sweep:
    /// one of them failing must never cause every other channel to be torn down.
    ///
    /// Never `await` this for a secondary channel before consuming a primary channel's
    /// streams — a secondary that never subscribes would silently starve the primary.
    static func subscribe(_ channel: RealtimeChannelV2, label: String, critical: Bool = true) async {
        var attempt = 0
        while !Task.isCancelled {
            attempt += 1
            do {
                try await channel.subscribeWithError()
                print("[Realtime] '\(label)' subscribed (attempt \(attempt))")
                if critical { shared.noteSubscribeSucceeded(label: label) }
                return
            } catch {
                guard !Task.isCancelled else { return }
                print("[Realtime] '\(label)' subscribe failed (attempt \(attempt)): \(error)")
                if critical { shared.noteSubscribeFailed(label: label) }
                try? await Task.sleep(for: backoff(forAttempt: attempt))
            }
        }
    }

    /// Runs until the channel is torn down on purpose. If the channel reaches
    /// `.subscribed` and later falls back to `.unsubscribed` on its own — a server
    /// `phx_close`, token expiry, or a stale close for an older join of the same topic —
    /// calls `onDrop` (normally the owner's `startRealtime(refetchOnSubscribe: true)`)
    /// and returns. Run it alongside the stream consumers in the realtime task group.
    static func watch(
        _ channel: RealtimeChannelV2,
        label: String,
        onDrop: @escaping @MainActor () -> Void
    ) async {
        var wasSubscribed = false
        for await status in channel.statusChange {
            if status == .subscribed {
                wasSubscribed = true
                continue
            }
            guard status == .unsubscribed, wasSubscribed else { continue }
            guard !Task.isCancelled,
                  !shared.intentionalRemovals.contains(ObjectIdentifier(channel))
            else { return }

            let now = ContinuousClock.now
            let droppedRecently = shared.lastDropAt[label].map { now - $0 < repeatDropWindow } ?? false
            shared.lastDropAt[label] = now
            let delay: Duration = droppedRecently ? unhealthyRetryInterval : .seconds(1)
            print("[Realtime] '\(label)' dropped by the server — rebuilding in \(delay)")
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            onDrop()
            return
        }
    }

    /// 2, 4, 8, 16, then 30s forever.
    private static func backoff(forAttempt attempt: Int) -> Duration {
        let seconds = min(30, Int(pow(2.0, Double(min(attempt, 5)))))
        return .seconds(seconds)
    }

    func noteSubscribeSucceeded(label: String) {
        failingLabels.remove(label)
        if !isUnhealthy { clearUnhealthy() }
    }

    func noteSubscribeFailed(label: String) {
        failingLabels.insert(label)
        markUnhealthy()
    }

    // MARK: - Signals

    private func handlePathUpdate(satisfied: Bool, interface: NWInterface.InterfaceType?) {
        let wasSatisfied = lastPathSatisfied
        let previousInterface = lastInterface
        let isInitial = !hasSeenInitialPath
        hasSeenInitialPath = true
        lastPathSatisfied = satisfied
        lastInterface = interface

        guard satisfied else {
            // Offline. Nothing to do but wait — the socket is gone either way.
            markUnhealthy()
            return
        }

        guard !isInitial else { return }

        // A WiFi↔cellular switch leaves the old socket bound to an interface that no
        // longer carries traffic, so it needs the same treatment as coming back online.
        if !wasSatisfied {
            requestSweep(.all(resetSocket: true), reason: "network reachable")
        } else if interface != previousInterface {
            requestSweep(.all(resetSocket: true), reason: "interface changed")
        }
    }

    private func handleSocketStatus(_ status: RealtimeClientStatus) {
        let connected = status == .connected
        if connected {
            lastConnectedAt = .now
            // Only a connected→lost→connected cycle is a reconnect. The socket starts out
            // .disconnected and connects for the first time during normal launch; sweeping
            // on that would refetch everything the view models are already loading.
            // A cycle we caused ourselves in resetSocket is already being swept.
            let selfInflicted = suppressReconnectSweepUntil.map { .now < $0 } ?? false
            if hasEverConnected, !lastSocketConnected, !selfInflicted {
                // The SDK "rejoined" its channels, but that is a no-op for channels still
                // marked subscribed, so every channel has to be rebuilt.
                requestSweep(.all(resetSocket: false), reason: "socket reconnected")
            }
            hasEverConnected = true
            lastSocketConnected = true
            // A dropped socket with no failing subscribe would otherwise leave the pill
            // up forever — nothing else clears it.
            if !isUnhealthy { clearUnhealthy() }
        } else if hasEverConnected {
            // Before the first successful connect, a .disconnected socket is just the
            // pre-launch state. A genuinely unreachable server surfaces through the
            // subscribe retries instead.
            lastSocketConnected = false
            markUnhealthy()
        }
    }

    private nonisolated static func primaryInterface(of path: NWPath) -> NWInterface.InterfaceType? {
        for type in [NWInterface.InterfaceType.wifi, .cellular, .wiredEthernet, .other] {
            if path.usesInterfaceType(type) { return type }
        }
        return nil
    }

    // MARK: - Sweeps

    /// Debounced and single-flight: a foreground, a path change and a socket-status
    /// change routinely arrive together, and each one alone is enough. Scopes merge
    /// upwards — a pending full sweep is never downgraded to a targeted one.
    private func requestSweep(_ scope: SweepScope, reason: String) {
        pendingScope = Self.merge(pendingScope, scope)
        pendingSweepTask?.cancel()
        pendingSweepTask = Task { [weak self] in
            try? await Task.sleep(for: Self.sweepDebounce)
            guard !Task.isCancelled, let self, let scope = self.pendingScope else { return }
            self.pendingScope = nil
            self.runSweep(scope, reason: reason)
        }
    }

    private static func merge(_ a: SweepScope?, _ b: SweepScope) -> SweepScope {
        guard case .all(let resetA)? = a else { return b }
        if case .all(let resetB) = b { return .all(resetSocket: resetA || resetB) }
        return .all(resetSocket: resetA)
    }

    private func runSweep(_ scope: SweepScope, reason: String) {
        guard sweepTask == nil else {
            // Don't lose the signal — retry once the running sweep finishes.
            requestSweep(scope, reason: reason)
            return
        }

        let targets: [Subscriber]
        let resetSocket: Bool
        switch scope {
        case .all(let reset):
            targets = Array(subscribers.values)
            resetSocket = reset
        case .failingOnly:
            targets = subscribers.values.filter { failingLabels.contains($0.label) }
            resetSocket = false
        }
        guard !targets.isEmpty else { return }

        print("[Realtime] reconnect sweep (\(reason)) across \(targets.count) subscriber(s)\(resetSocket ? ", resetting socket" : "")")
        sweepTask = Task { [weak self] in
            if resetSocket { await self?.resetSocketIfStale() }
            for target in targets {
                guard !Task.isCancelled else { break }
                await target.reconnect()
            }
            self?.sweepTask = nil
        }
    }

    /// Replaces a socket that may be dead-but-reporting-connected with a fresh one, so
    /// the resubscribes that follow actually reach the server.
    private func resetSocketIfStale() async {
        let realtime = supabase.realtimeV2
        if realtime.status == .connected,
           let at = lastConnectedAt, ContinuousClock.now - at < Self.freshSocketWindow {
            return
        }
        suppressReconnectSweepUntil = .now + .seconds(5)
        realtime.disconnect()
        // disconnect() hands the close to the SDK's connection actor asynchronously;
        // connecting before it lands would just return the old connection.
        try? await Task.sleep(for: .milliseconds(300))
        await realtime.connect()
    }

    // MARK: - Health

    /// Unhealthy means either a critical channel is stuck retrying its subscribe, or the
    /// socket itself is down. Either way live events are not arriving.
    private var isUnhealthy: Bool {
        !failingLabels.isEmpty || !lastSocketConnected
    }

    private func markUnhealthy() {
        startRetryLoop()
        guard !isReconnecting, pillTask == nil else { return }
        pillTask = Task { [weak self] in
            try? await Task.sleep(for: Self.unhealthyGrace)
            guard !Task.isCancelled else { return }
            self?.isReconnecting = true
        }
    }

    private func clearUnhealthy() {
        pillTask?.cancel()
        pillTask = nil
        retryTask?.cancel()
        retryTask = nil
        isReconnecting = false
    }

    private func startRetryLoop() {
        guard retryTask == nil else { return }
        retryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.unhealthyRetryInterval)
                guard !Task.isCancelled, let self, self.isUnhealthy else { return }
                // A dead socket needs everything rebuilt on a fresh one; otherwise only
                // the channels that are actually failing get rebuilt, and healthy ones
                // are left alone.
                if self.lastSocketConnected {
                    self.requestSweep(.failingOnly, reason: "periodic retry")
                } else {
                    self.requestSweep(.all(resetSocket: true), reason: "periodic retry (socket down)")
                }
            }
        }
    }
}
