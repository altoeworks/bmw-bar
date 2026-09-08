import SwiftUI

/// Owns the model and starts it at launch.
///
/// The scene's content view can't do this: `MenuBarExtra(style: .window)` only builds
/// its content when the user opens the panel, so a `.task` there would leave the
/// status bar title blank and the stream disconnected until the first click.
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    public let model = AppModel()

    public func applicationDidFinishLaunching(_ notification: Notification) {
        Log.app.notice("did finish launching")
        Task { await model.start() }
    }
}

public struct BMWBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    public init() {}

    public var body: some Scene {
        MenuBarExtra {
            StatusPanel(model: delegate.model)
        } label: {
            MenuBarLabel(model: delegate.model)
        }
        .menuBarExtraStyle(.window)
    }
}
