import AppKit
import Foundation
import SwiftUI

/// Headless entry points that exercise the same code paths as the UI, so each layer
/// can be verified against real BMW servers before any of it is wired to a view.
enum CLIError: Error, CustomStringConvertible {
    case notificationsUnavailable(String)
    case renderFailed

    var description: String {
        switch self {
        case .notificationsUnavailable(let reason):
            return "Notifications unavailable: \(reason)"
        case .renderFailed:
            return "ImageRenderer produced no image."
        }
    }
}

public enum DebugCLI {
    public static func run(arguments: [String]) async -> Int32 {
        var args = arguments
        guard let command = args.first else {
            printUsage()
            return 2
        }
        args.removeFirst()

        do {
            switch command {
            case "auth": try await auth(args)
            case "whoami": try await whoami()
            case "signout": try signOut()
            case "setup": try await setup(args)
            case "status": try await status(args)
            case "quota": try await quota()
            case "containers": try await containers(args)
            case "stream": try await stream(args)
            case "notify-test": try await notifyTest()
            case "mood": try mood(args)
            case "render": try await render(args)
            case "-h", "--help", "help":
                printUsage()
            default:
                FileHandle.standardError.write(Data("Unknown command: \(command)\n".utf8))
                printUsage()
                return 2
            }
            return 0
        } catch {
            // Our error types implement CustomStringConvertible, so this prints the
            // helpful message; anything else falls back to the case name.
            FileHandle.standardError.write(Data("error: \(String(describing: error))\n".utf8))
            return 1
        }
    }

    // MARK: - Auth

    /// Runs the device code flow, or proves the stored refresh token still works.
    private static func auth(_ args: [String]) async throws {
        let clientID = try requireClientID(args)
        let auth = CarDataAuth(clientID: clientID)
        let store = TokenStore(auth: auth)

        // Re-authorising from scratch is the exception; default to reusing what we have.
        if !args.contains("--force"), try await store.loadPersisted() != nil {
            print("Stored credentials found — refreshing instead of re-authorising.")
            print("(pass --force to run the full device code flow again)")
            describe(try await store.forceRefresh())
            return
        }

        let pkce = PKCE()
        let grant = try await auth.requestDeviceCode(pkce: pkce)

        print("""

        Approve this device in your browser:

          URL:  \(grant.verificationURI.absoluteString)
          Code: \(grant.userCode)

        Waiting for approval (expires \(time.string(from: grant.expiresAt)))…
        """)
        NSWorkspace.shared.open(grant.verificationURI)

        let tokens = try await auth.pollForTokens(grant: grant, pkce: pkce)
        try await store.adopt(tokens)

        // Remember the client ID so later runs need no environment variable.
        var config = Config.load()
        if config.clientID != clientID {
            config.clientID = clientID
            try config.save()
        }

        print("\nAuthorised.")
        describe(tokens)
    }

    /// Reports the stored session without touching the network.
    private static func whoami() async throws {
        let session = try Session.make()
        guard let tokens = try await session.tokens.loadPersisted() else {
            throw AuthError.notAuthenticated
        }
        describe(tokens)

        let config = Config.load()
        print("""
          client id:     \(session.clientID)
          vin:           \(config.vin ?? "—")
          container:     \(config.containerID ?? "—")
          vehicle:       \(config.vehicleName ?? "—")
        """)
    }

    private static func signOut() throws {
        try FileTokenStorage().clear()
        try? KeychainTokenStorage().clear()
        print("Cleared stored credentials.")
    }

    // MARK: - Setup & data

    /// Resolves the VIN and telemetry container, caching both. Costs ~3 API calls once.
    private static func setup(_ args: [String]) async throws {
        let session = try Session.make(clientIDOverride: value(of: "--client-id", in: args))
        let setup = try await session.bootstrap(refresh: args.contains("--refresh"))

        print("""
        Vehicle:    \(setup.vehicleName ?? "—")
        VIN:        \(setup.vin)
        Container:  \(setup.containerID) (\(Descriptor.all.count) descriptors)
        Source:     \(setup.didFetch ? "fetched from BMW" : "cached, no API calls spent")
        """)
        if let capacity = setup.batteryCapacityKWh {
            print("Battery:    \(format(capacity)) kWh")
        }
        await printQuota(session)
    }

    /// One REST snapshot of the container. Costs 1 API call.
    private static func status(_ args: [String]) async throws {
        let session = try Session.make()
        let setup = try await session.bootstrap()
        let snapshot = try await session.client.telematicData(
            vin: setup.vin,
            containerID: setup.containerID
        )

        if args.contains("--json") {
            printJSON(snapshot)
            return
        }

        let state = VehicleState()
        state.vin = setup.vin
        state.vehicleName = setup.vehicleName
        state.replaceAll(with: snapshot)

        print("\(setup.vehicleName ?? setup.vin)\n")

        if snapshot.isEmpty {
            print("""
            BMW returned no telematic data.

            That is normal right after setup: the container exists, but the car has not
            reported into it yet. Wake the car — lock or unlock it from the MyBMW app —
            and try again in a minute.
            """)
        } else {
            printSummary(state)
            print("\nAll \(snapshot.count) descriptors:")
            for key in snapshot.keys.sorted() {
                guard let value = snapshot[key] else { continue }
                let stamp = value.timestamp.map { "  (\(time.string(from: $0)))" } ?? ""
                let label = pad(Descriptor.label(for: key))
                print("  \(label) \(render(value))\(stamp)")
            }
        }
        await printQuota(session)
    }

    private static func printSummary(_ state: VehicleState) {
        var lines: [String] = []
        if let charge = state.chargePercent {
            var line = "Charge:     \(format(charge)) %"
            if let limit = state.chargeLimitPercent { line += "  (limit \(format(limit)) %)" }
            lines.append(line)
        }
        if let status = state.chargingStatus {
            var line = "Status:     \(status.displayName)"
            if let power = state.chargingPowerKW, power > 0 {
                line += "  ·  \(format(power)) kW"
            }
            if let minutes = state.chargingMinutesRemaining, minutes > 0 {
                line += "  ·  \(minutes) min remaining"
            }
            lines.append(line)
        }
        if let plugged = state.isPluggedIn {
            lines.append("Plug:       \(plugged ? "connected" : "disconnected")")
        }
        if let range = state.electricRangeKm { lines.append("Range:      \(format(range)) km") }
        if let odometer = state.odometerKm { lines.append("Odometer:   \(format(odometer)) km") }
        if let reading = state.newestReadingTimestamp {
            lines.append("Reported:   \(time.string(from: reading))")
        }
        print(lines.joined(separator: "\n"))
    }

    private static func quota() async throws {
        await printQuota(try Session.make(), heading: true)
    }

    private static func containers(_ args: [String]) async throws {
        let session = try Session.make()

        if let id = value(of: "--delete", in: args) {
            try await session.client.deleteContainer(id: id)
            print("Deleted container \(id).")
            // Drop the cached id if we just deleted the one we were using.
            var config = Config.load()
            if config.containerID == id {
                config.containerID = nil
                try config.save()
            }
            return
        }

        let list = try await session.client.listContainers()
        if list.isEmpty {
            print("No containers on this account.")
        }
        for container in list {
            print("\(container.containerId)  \(container.name ?? "—")  [\(container.state ?? "?")]")
            if let descriptors = container.technicalDescriptors {
                print("  \(descriptors.count) descriptors")
            }
        }
        await printQuota(session)
    }

    // MARK: - Stream

    /// Subscribes to the live MQTT feed and prints messages as they arrive.
    /// Costs no API quota — this is the intended way to follow the car.
    private static func stream(_ args: [String]) async throws {
        let session = try Session.make()
        let asJSON = args.contains("--json")
        let seconds = value(of: "--seconds", in: args).flatMap(Double.init)

        // No bootstrap: a cached VIN narrows the subscription, and its absence means
        // the wildcard topic, which discovers the VIN with zero API calls.
        let config = Config.load()
        let stream = CarDataStream(tokens: session.tokens, vin: config.vin)
        stream.onVINDiscovered = { vin in
            FileHandle.standardError.write(Data("[discovered VIN \(vin)]\n".utf8))
            var updated = Config.load()
            if updated.vin != vin {
                updated.vin = vin
                try? updated.save()
            }
        }
        stream.onStatusChange = { status in
            FileHandle.standardError.write(Data("[\(status.summary)]\n".utf8))
        }

        let state = VehicleState()
        state.vin = config.vin
        state.vehicleName = config.vehicleName

        print("""
        Streaming \(config.vehicleName ?? config.vin ?? "all vehicles on the account")
        Topic:  <gcid>/\(config.vin ?? "+")
        Press Ctrl-C to stop. The car only reports when it has something to say —
        locking or unlocking it from the MyBMW app usually triggers an update.
        """)

        let messages = stream.messages()
        stream.start()
        defer { stream.stop() }

        // Optional time limit, so the command can be used as a bounded check.
        let deadline = seconds.map { Date().addingTimeInterval($0) }
        if let deadline {
            Task {
                try? await Task.sleep(nanoseconds: UInt64(deadline.timeIntervalSinceNow * 1_000_000_000))
                stream.stop()
            }
        }

        for await message in messages {
            state.merge(message.data)
            if asJSON {
                printJSON(message.data)
            } else {
                let stamp = time.string(from: message.sentAt ?? Date())
                print("\n\(stamp)  \(message.data.count) descriptor(s)")
                for key in message.data.keys.sorted() {
                    guard let value = message.data[key] else { continue }
                    let label = pad(Descriptor.label(for: key))
                    print("  \(label) \(render(value))")
                }
                printSummary(state)
            }
        }
    }

    // MARK: - Notifications

    /// Posts a sample notification, to prove delivery works without waiting for a real
    /// charging session. Must be run from inside the app bundle:
    ///   build/BMWBar.app/Contents/MacOS/BMWBar --cli notify-test
    private static func notifyTest() async throws {
        let notifier = await ChargingNotifier()
        let availability = await notifier.availability

        if case .unavailable(let reason) = availability {
            throw CLIError.notificationsUnavailable(reason)
        }

        await notifier.requestAuthorizationIfNeeded(for: .default)
        let granted = await notifier.availability
        guard granted.canDeliver else {
            throw CLIError.notificationsUnavailable(
                "macOS did not grant permission (state: \(granted)). "
                    + "Check System Settings -> Notifications -> BMW Bar."
            )
        }

        await notifier.sendTestNotification()
        print("Posted a test notification.")
        // Delivery is asynchronous; give the daemon a moment before the process exits.
        try? await Task.sleep(nanoseconds: 2_000_000_000)
    }

    // MARK: - Motion

    /// Prints the accent and motion the panel would use for a given state.
    ///
    /// Charging faults and preconditioning are rare in the wild, so this makes them
    /// inspectable without waiting for the car to misbehave.
    private static func mood(_ args: [String]) throws {
        let cases: [(String, [String: TelematicValue])] = [
            ("resting", [Descriptor.chargingStatus: .init(raw: .string("NOCHARGING"))]),
            ("charging", [Descriptor.chargingStatus: .init(raw: .string("CHARGINGACTIVE"))]),
            ("preconditioning", [
                Descriptor.chargingStatus: .init(raw: .string("NOCHARGING")),
                Descriptor.preconditioningState: .init(raw: .string("AUTOMATIC_ON")),
            ]),
            ("charging+preconditioning", [
                Descriptor.chargingStatus: .init(raw: .string("CHARGINGACTIVE")),
                Descriptor.preconditioningState: .init(raw: .string("AUTOMATIC_ON")),
            ]),
            ("paused", [Descriptor.chargingStatus: .init(raw: .string("CHARGINGPAUSED"))]),
            ("error", [Descriptor.chargingStatus: .init(raw: .string("CHARGINGERROR"))]),
            ("complete", [Descriptor.chargingStatus: .init(raw: .string("FINISHED_FULLY_CHARGED"))]),
            ("limit", [Descriptor.chargingStatus: .init(raw: .string("CHARGINGENDED"))]),
        ]

        let wanted = args.first
        print("state                     tone             motion            symbol")
        for (name, values) in cases where wanted == nil || name.contains(wanted!) {
            let state = VehicleState()
            state.merge(values)
            let mood = VehicleMood.from(state)
            print("  \(name.padding(toLength: 24, withPad: " ", startingAt: 0)) "
                + "\(String(describing: mood.tone).padding(toLength: 17, withPad: " ", startingAt: 0))"
                + "\(String(describing: mood.motion).padding(toLength: 18, withPad: " ", startingAt: 0))"
                + mood.symbol)
        }
    }

    // MARK: - Rendering

    /// Renders the panel to a PNG without a running app, using the real cached state
    /// (or a synthetic charging state with `--charging`). This is how the layout gets
    /// checked when screen recording isn't available. MapKit does not draw inside
    /// `ImageRenderer`, so the map tile comes out blank here but not in the app.
    @MainActor
    private static func render(_ args: [String]) async throws {
        let output = URL(fileURLWithPath: args.first { $0.hasSuffix(".png") } ?? "panel.png")

        var values = VehicleStateStore().load()?.values ?? [:]
        var samples = SampleLog().load()
        if args.contains("--charging") {
            values[Descriptor.chargingStatus] = TelematicValue(raw: .string("CHARGINGACTIVE"))
            values[Descriptor.chargingPower] = TelematicValue(raw: .number(11000), unit: "W")
            values[Descriptor.chargingTimeRemaining] = TelematicValue(raw: .number(95), unit: "min")
            values[Descriptor.chargingMethod] = TelematicValue(raw: .string("AC_TYPE2PLUG"))
            values[Descriptor.plugged] = TelematicValue(raw: .bool(true))
            values[Descriptor.socTarget] = TelematicValue(raw: .number(80))
            values[Descriptor.preconditioningState] = TelematicValue(raw: .string("AUTOMATIC_ON"))
        }
        if args.contains("--empty") { values = [:]; samples = [] }
        if samples.count < 2 {
            // Enough history to draw a line; a real log replaces this over time.
            let now = Date()
            samples = (0..<12).map {
                Sample(at: now.addingTimeInterval(Double($0 - 12) * 3600),
                       soc: 40 + Double($0) * 2.2, powerKW: nil, status: nil, plugged: nil)
            }
        }

        let model = AppModel(previewValues: values, samples: samples)
        let renderer = ImageRenderer(content: StatusPanel(model: model)
            .background(Color(nsColor: .windowBackgroundColor)))
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { throw CLIError.renderFailed }
        try png.write(to: output)
        print("wrote \(output.path) (\(Int(image.size.width))x\(Int(image.size.height)) pt, \(values.count) values)")
    }

    // MARK: - Output helpers

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private static func printQuota(_ session: Session, heading: Bool = false) async {
        let snapshot = await session.client.quotaSnapshot()
        let prefix = heading ? "" : "\n"
        print("""
        \(prefix)API quota:  \(snapshot.used)/\(snapshot.limit) used today, \
        \(snapshot.remaining) left (resets \(time.string(from: snapshot.resetsAt)))
        """)
    }

    private static func printJSON(_ snapshot: [String: TelematicValue]) {
        let object = snapshot.mapValues { value -> [String: Any] in
            var dict: [String: Any] = ["value": value.stringValue ?? NSNull()]
            if let unit = value.unit { dict["unit"] = unit }
            if let stamp = value.timestamp {
                dict["timestamp"] = ISO8601DateFormatter().string(from: stamp)
            }
            return dict
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        print(String(decoding: data, as: UTF8.self))
    }

    private static func describe(_ tokens: TokenSet) {
        let now = Date()
        print("""
          gcid:          \(tokens.gcid)
          access token:  valid for \(minutes(until: tokens.accessExpiresAt, from: now))
          id token:      valid for \(minutes(until: tokens.accessExpiresAt, from: now)) (MQTT password)
          refresh token: valid until \(time.string(from: tokens.refreshExpiresAt))
        """)
    }

    private static func minutes(until date: Date, from now: Date) -> String {
        let remaining = Int(date.timeIntervalSince(now) / 60)
        return remaining <= 0 ? "expired" : "\(remaining) min"
    }

    /// A descriptor BMW has no reading for still carries its unit, so print a bare
    /// dash rather than a unit with nothing in front of it.
    private static func render(_ value: TelematicValue) -> String {
        guard let text = value.stringValue else { return "—" }
        return text + (value.unit.map { " \($0)" } ?? "")
    }

    /// Pads to a column without ever truncating: an unlabelled descriptor id is long,
    /// and cutting it off hides the one thing worth reading.
    private static func pad(_ text: String, to width: Int = 26) -> String {
        text.count >= width ? text + " " : text.padding(toLength: width, withPad: " ", startingAt: 0)
    }

    private static func format(_ value: Double) -> String {
        value == value.rounded()
            ? String(Int(value))
            : String(format: "%.1f", value)
    }

    private static func requireClientID(_ args: [String]) throws -> String {
        guard let id = Config.resolvedClientID(override: value(of: "--client-id", in: args)) else {
            throw AuthError.missingClientID
        }
        return id
    }

    private static func value(of flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    private static func printUsage() {
        print("""
        BMWBar --cli <command>

        Commands:
          auth [--client-id <id>] [--force]   Authorise this Mac with BMW CarData
          whoami                              Show the stored session (offline)
          setup [--refresh]                   Resolve the VIN and telemetry container
          status [--json]                     One REST snapshot of the car (1 API call)
          stream [--json] [--seconds <n>]     Follow the live MQTT feed (no quota cost)
          notify-test                         Post a sample notification (bundled app only)
          mood [state]                        Show the colour + motion for each state
          render [--charging|--empty] out.png Render the panel to an image (no network)
          quota                               Show today's API budget (offline)
          containers [--delete <id>]          List or remove telemetry containers
          signout                             Delete stored credentials

        The client ID comes from --client-id, then $BMW_CLIENT_ID, then the saved config.
        BMW allows 50 API calls per day; live updates come from the stream instead.
        """)
    }
}
