import Foundation
import os

/// Structured logging, so the running app's behaviour can be observed without a
/// debugger.
///
/// A status bar app has nowhere to print: twice during development a problem could only
/// be guessed at because the stream and the idle poll left no trace. Watch it with:
///
/// ```
/// log stream --predicate 'subsystem == "com.ohoefenstock.bmw-bar"' --style compact
/// ```
///
/// Nothing here logs a token, and vehicle data is limited to the coarse values already
/// shown on screen.
public enum Log {
    private static let subsystem = AppPaths.bundleIdentifier

    public static let stream = Logger(subsystem: subsystem, category: "stream")
    public static let polling = Logger(subsystem: subsystem, category: "polling")
    public static let api = Logger(subsystem: subsystem, category: "api")
    public static let app = Logger(subsystem: subsystem, category: "app")
}
