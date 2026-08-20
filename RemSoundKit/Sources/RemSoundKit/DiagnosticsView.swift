import SwiftUI

/// The technical panel, reached from the Diagnostics button on the Connectivity tab.
///
/// It exists so the main screen can stay short. These lines are genuinely useful — they are
/// what told us a link was jittering rather than losing packets — but there are a dozen of
/// them and they rewrite themselves every second, which makes the connection list tedious to
/// arrow through when all you wanted was "am I connected". Behind a button they cost nothing
/// until asked for. The counters run whether or not this is open, so it always shows real
/// history rather than starting from zero.
struct DiagnosticsView: View {
    /// Read-only: @Observable tracks the reads in `body`, so no @Bindable is needed here.
    let controller: ReceiverController
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    @State private var copyResetTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Form {
                if controller.diagnosticDetails.isEmpty {
                    Section {
                        Text("No measurements yet. These appear once audio is playing.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        ForEach(Array(controller.diagnosticDetails.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.callout)
                                .accessibilityAddTraits(.updatesFrequently)
                        }
                    } header: {
                        Text("Measurements")
                    } footer: {
                        Text("Everything here covers the last minute and refreshes every second.")
                    }
                }

                Section {
                    Button(copied ? "Copied" : "Copy diagnostics") {
                        controller.copyConnectionReport()
                        copied = true
                        copyResetTask?.cancel()
                        copyResetTask = Task {
                            try? await Task.sleep(for: .seconds(2))
                            guard !Task.isCancelled else { return }
                            copied = false
                        }
                    }
                    .accessibilityHint("Copies the connection status and all of these measurements as text")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Diagnostics")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
