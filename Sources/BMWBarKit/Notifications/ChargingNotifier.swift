import Foundation
import UserNotifications

/// Delivers charging events as macOS notifications.
///
/// `UNUserNotificationCenter` needs a real app bundle with a bundle identifier, so it
/// is unavailable when the executable runs bare (`swift run … --cli`). That is treated
/// as "not available" rather than an error: the CLI still prints events, it just can't
/// raise a banner.
@MainActor
public final class ChargingNotifier {
    public enum Availability: Equatable {
        case unavailable(String)
        case notRequested
        case authorised
        case denied

        public var canDeliver: Bool { self == .authorised }
    }

    public private(set) var availability: Availability
    private var detector = ChargingEventDetector()

    public init() {
        // Bundle.main.bundleIdentifier is nil for a bare SwiftPM executable, and
        // touching UNUserNotificationCenter in that state throws an exception that
        // cannot be caught from Swift — so check first.
        availability = Bundle.main.bundleIdentifier == nil
            ? .unavailable("notifications need the bundled app (build/BMWBar.app)")
            : .notRequested
    }

    /// Asks macOS for permission, but only when something is actually switched on.
    public func requestAuthorizationIfNeeded(for preferences: NotificationPreferences) async {
        guard preferences.wantsAnything else { return }
        guard availability == .notRequested || availability == .denied else { return }

        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
            availability = granted ? .authorised : .denied
        } catch {
            availability = .unavailable(String(describing: error))
        }
    }

    /// Feeds a new vehicle state through the detector and delivers whatever comes out.
    /// - Returns: the events detected, so callers (the CLI) can report them too.
    @discardableResult
    public func process(
        _ state: VehicleState,
        preferences: NotificationPreferences,
        now: Date = Date()
    ) -> [ChargingEvent] {
        let events = detector.update(state, preferences: preferences, now: now)
        guard availability.canDeliver else { return events }
        for event in events { deliver(event) }
        return events
    }

    private func deliver(_ event: ChargingEvent) {
        let content = UNMutableNotificationContent()
        content.title = event.title
        content.body = event.body
        content.sound = event.isProblem ? .defaultCritical : .default
        content.interruptionLevel = event.isProblem ? .timeSensitive : .active

        // nil trigger delivers immediately.
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// Posts a sample notification so delivery can be verified without waiting for a
    /// real charging session.
    public func sendTestNotification() {
        deliver(.finished(percent: 80, reachedLimit: true))
    }
}
