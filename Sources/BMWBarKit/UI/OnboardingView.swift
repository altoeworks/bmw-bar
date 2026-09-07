import SwiftUI

/// First-run walkthrough.
///
/// The BMW portal half cannot be automated — the client ID and the streaming
/// descriptor selection are both manual — so this spells the steps out and links
/// straight to the portal.
struct OnboardingView: View {
    @Bindable var model: AppModel
    @State private var clientID = Config.load().clientID ?? ""

    private static let portalURL = URL(
        string: "https://www.bmw.de/de-de/mybmw/vehicle-overview"
    )!

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect to BMW CarData")
                .font(.headline)

            if case .awaitingApproval(let userCode, let url) = model.phase {
                approval(userCode: userCode, url: url)
            } else {
                setupSteps
            }
        }
    }

    private var setupSteps: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                step(1, "In MyBMW, open your car → **BMW CarData** and generate a Client ID. Don't press \"Authenticate device\" there.")
                step(2, "Request access to **CarData API**, wait a minute, then **CarData Stream** and wait again. Rushing this returns 403s.")
                step(3, "Open **Configure data stream** and tick the charging descriptors you want.")
                step(4, "Paste the Client ID below.")
            }

            Link("Open the MyBMW portal", destination: Self.portalURL)
                .font(.caption)

            TextField("Client ID", text: $clientID)
                .textFieldStyle(.roundedBorder)
                .font(.caption.monospaced())

            HStack {
                Button("Connect") {
                    Task { await model.authorize(clientID: clientID) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(clientID.trimmingCharacters(in: .whitespaces).isEmpty)

                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
    }

    private func approval(userCode: String, url: URL) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Approve this Mac in your browser, then come back — it connects on its own.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Text("Code")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(userCode)
                    .font(.title3.monospaced().weight(.semibold))
                    .textSelection(.enabled)
            }

            Link("Open the approval page", destination: url)
                .font(.caption)

            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waiting for approval…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { NSWorkspace.shared.open(url) }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("\(number).")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 14, alignment: .trailing)
            Text(.init(text))
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
