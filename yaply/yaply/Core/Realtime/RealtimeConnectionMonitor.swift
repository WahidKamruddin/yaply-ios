import Foundation
import Network
import Realtime
import Supabase
import UIKit

// Keeps every Supabase Realtime subscription alive across network interruptions.
//
// The WebSocket carries *only* change events — every actual fetch goes over plain
// HTTPS/PostgREST. That asymmetry is what made the original bug so hard to see: on a
// network that blocks WebSocket upgrades but allows HTTPS, the app loads, sends and
// receives pushes perfectly while silently receiving nothing live. Nothing in the UI
// reflected a dead socket, and nothing ever tried to reconnect after the initial
// ~12s retry budget ran out.
//
// supabase-swift recovers the *socket* on app foreground and retries once after a
// connection error, but it never reconnects after a server-initiated close, knows
// nothing about the network path changing, and — most importantly — has no idea that
// the app missed events while it was down. That last part is this type's real job:
// resubscribing only delivers *future* events, so every reconnect must be followed by
// a refetch or the UI silently reattaches and keeps showing stale data.
//
// View models register a reconnect closure; every recovery signal runs all of them.
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
    /// Backstop re-sweep while still unhealthy — the "never give up" guarantee for a
    /// channel that reports subscribed but has stopped delivering.
    private static let unhealthyRetryInterval: Duration = .seconds(30)

    private struct Subscriber {
        let label: String
        let reconnect: () async -> Void
    }

    private var subscribers: [UUID: Subscriber] = [:]
    private var failingLabels: Set<String> = []

    private var pathMonitor: NWPathMonitor?
    private var lastPathSatisfied = true
    private var lastInterface: NWInterface.InterfaceType?
    private var foregroundObserver: NSObjectProtocol?
    private var statusSubscription: RealtimeSubscription?
    private var lastSocketConnected = true
    // Both NWPathMonitor and onStatusChange replay their current value the moment we
    // subscribe. Treating that first callback as a transition would fire a sweep during
    // launch and tear down a subscription that was still being set up, so the first one
    // only seeds state.
    private var hasSeenInitialPath = false
    private var hasEverConnected = false

    private var sweepTask: Task<Void, Never>?
    private var pendingSweepTask: Task<Void, Never>?
    private var pillTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?

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
                self?.requestSweep(reason: "foreground")
            }
        }

        // Catches a server-initiated close, which the SDK never retries on its own.
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
        pillTask?.cancel(); pillTask = nil
        retryTask?.cancel(); retryTask = nil
        failingLabels.removeAll()
        isReconnecting = false
    }

    // MARK: - Registration

    /// Registers a reconnect closure. Capture `[weak self]` in `reconnect` — the monitor
    /// outlives every view model that registers with it.
    func register(label: String, reconnect: @escaping () async -> Void) -> UUID {
        let token = UUID()
        subscribers[token] = Subscriber(label: label, reconnect: reconnect)
        return token
    }

    func unregister(_ token: UUID?) {
        guard let token else { return }
        subscribers.removeValue(forKey: token)
    }

    // MARK: - Subscribe helper

    /// `subscribeWithError()` can throw (e.g. the socket is still connecting or timed out
    /// on a slow/cold-launch network path — reproducible on a real device even when the
    /// simulator, on a fast loopback-ish connection, subscribes fast enough to mask it).
    /// Silently swallowing that failure leaves the channel permanently unsubscribed for
    /// the rest of the view's lifetime — `postgresChange` streams never deliver anything,
    /// so no message arrives live until the view is torn down and recreated.
    ///
    /// This retries forever rather than giving up after a fixed budget. Unbounded is safe
    /// because the loop only ever runs inside a `realtimeTask` that every `startRealtime`
    /// cancels on teardown.
    static func subscribe(_ channel: RealtimeChannelV2, label: String) async {
        var attempt = 0
        while !Task.isCancelled {
            attempt += 1
            do {
                try await channel.subscribeWithError()
                print("[Realtime] '\(label)' subscribed (attempt \(attempt))")
                await MainActor.run { shared.noteSubscribeSucceeded(label: label) }
                return
            } catch {
                print("[Realtime] '\(label)' subscribe failed (attempt \(attempt)): \(error)")
                await MainActor.run { shared.noteSubscribeFailed(label: label) }
                try? await Task.sleep(for: backoff(forAttempt: attempt))
            }
        }
    }

    /// 2, 4, 8, 16, then 30s forever.
    private static func backoff(forAttempt attempt: Int) -> Duration {
        let seconds = min(30, Int(pow(2.0, Double(min(attempt, 5)))))
        return .seconds(seconds)
    }

    func noteSubscribeSucceeded(label: String) {
        failingLabels.remove(label)
        if failingLabels.isEmpty { clearUnhealthy() }
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
            requestSweep(reason: "network reachable")
        } else if interface != previousInterface {
            requestSweep(reason: "interface changed")
        }
    }

    private func handleSocketStatus(_ status: RealtimeClientStatus) {
        let connected = status == .connected
        defer { lastSocketConnected = connected }

        if connected {
            // Only a connected→lost→connected cycle is a reconnect. The socket starts out
            // .disconnected and connects for the first time during normal launch; sweeping
            // on that would refetch everything the view models are already loading.
            if hasEverConnected, !lastSocketConnected {
                requestSweep(reason: "socket reconnected")
            }
            hasEverConnected = true
            // A dropped socket with no failing subscribe would otherwise leave the pill
            // up forever — nothing else clears it.
            if failingLabels.isEmpty { clearUnhealthy() }
        } else if hasEverConnected {
            // Before the first successful connect, a .disconnected socket is just the
            // pre-launch state. A genuinely unreachable server surfaces through the
            // subscribe retries instead.
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
    /// change routinely arrive together, and each one alone is enough.
    private func requestSweep(reason: String) {
        pendingSweepTask?.cancel()
        pendingSweepTask = Task { [weak self] in
            try? await Task.sleep(for: Self.sweepDebounce)
            guard !Task.isCancelled else { return }
            self?.runSweep(reason: reason)
        }
    }

    private func runSweep(reason: String) {
        guard sweepTask == nil else { return }
        let targets = Array(subscribers.values)
        guard !targets.isEmpty else { return }

        print("[Realtime] reconnect sweep (\(reason)) across \(targets.count) subscriber(s)")
        sweepTask = Task { [weak self] in
            for target in targets {
                guard !Task.isCancelled else { break }
                await target.reconnect()
            }
            self?.sweepTask = nil
        }
    }

    // MARK: - Health

    /// Unhealthy means either a channel is stuck retrying its subscribe, or the socket
    /// itself is down. Either way live events are not arriving.
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
                self.requestSweep(reason: "periodic retry")
            }
        }
    }
}
