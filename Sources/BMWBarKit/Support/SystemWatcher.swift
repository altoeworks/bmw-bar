import AppKit
import Foundation
import Network

/// Tells the app when this Mac stops and starts being able to reach BMW.
///
/// Without this the stream discovers a sleep only by noticing its socket has gone quiet,
/// then waits out an exponential backoff whose `Task.sleep` drifted through the sleep
/// anyway — so a lid opened at 08:00 could sit disconnected for another two minutes.
/// Worse, nothing recorded that the hole existed at all.
///
/// Callbacks are delivered on the main actor. Installation is deliberately cheap and
/// non-blocking: `applicationDidFinishLaunching` has been wedged by less.
@MainActor
public final class SystemWatcher {
    public var onSleep: (@MainActor () -> Void)?
    public var onWake: (@MainActor () -> Void)?
    /// `true` when a usable network path appears, `false` when it goes away.
    public var onNetworkChange: (@MainActor (Bool) -> Void)?

    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.ohoefenstock.bmw-bar.network")
    private var observers: [NSObjectProtocol] = []
    private var isSatisfied = true
    private var started = false

    public init() {}

    public func start() {
        guard !started else { return }
        started = true

        let center = NSWorkspace.shared.notificationCenter
        observers.append(
            center.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    Log.app.notice("system: sleeping")
                    self?.onSleep?()
                }
            }
        )
        observers.append(
            center.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    Log.app.notice("system: woke")
                    self?.onWake?()
                }
            }
        )

        // Fires immediately with the current path, so the first callback is a baseline
        // rather than a change; `isSatisfied` starts optimistic to swallow it.
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self, self.isSatisfied != satisfied else { return }
                self.isSatisfied = satisfied
                Log.app.notice("system: network \(satisfied ? "up" : "down", privacy: .public)")
                self.onNetworkChange?(satisfied)
            }
        }
        monitor.start(queue: monitorQueue)
    }

    public func stop() {
        guard started else { return }
        started = false
        monitor.cancel()
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach(center.removeObserver)
        observers.removeAll()
    }

    deinit { monitor.cancel() }
}
