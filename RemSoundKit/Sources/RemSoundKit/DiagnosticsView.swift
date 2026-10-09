import SwiftUI

/// The technical panel, reached from the Diagnostics button on the Connectivity tab.
///
/// It exists so the main screen can stay short. These lines are genuinely useful — they are
/// what told us a link was jittering rather than losing packets — but there are a dozen of
/// them and they rewrite themselves every second, which makes the connection list tedious to
/// arrow through when all you wanted was "am I connected". Behind a button they cost nothing
/// until asked for. The counters run whether or not this is open, so it always shows real
/// history rather than starting from zero.
///
/// Below the measurements: the event log (`EventLog`) — what happened and why, newest first —
/// and the switch for writing it to files, with a Share button for the current one.
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
                        Text("No measurements yet.")
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
                        Text("Last minute")
                    }
                }

                Section {
                    Button(copied ? "Copied" : "Copy all details") {
                        controller.copyConnectionReport()
                        copied = true
                        copyResetTask?.cancel()
                        copyResetTask = Task {
                            try? await Task.sleep(for: .seconds(2))
                            guard !Task.isCancelled else { return }
                            copied = false
                        }
                    }
                }

                LogFilesSection(controller: controller)
                RecentEventsSection(controller: controller)
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

// Both sections below are their own structs for the reason the pickers in ReceiverRootView
// are (issue #3): the screen above re-renders every second, and the share sheet and the event
// list must not be rebuilt underneath the user. Each reads only what it shows.

private struct LogFilesSection: View {
    let controller: ReceiverController

    var body: some View {
        Section {
            Toggle("Write log files", isOn: Binding(
                get: { controller.fileLoggingEnabled },
                set: { controller.fileLoggingEnabled = $0 }
            ))
            if let file = controller.currentLogFile {
                ShareLink(item: file) {
                    Label("Share log", systemImage: "square.and.arrow.up")
                }
            }
        } header: {
            Text("Log files")
        }
    }
}

private struct RecentEventsSection: View {
    let controller: ReceiverController
    private static let shown = 100

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        Section {
            if controller.recentEvents.isEmpty {
                Text("Nothing yet.")
                    .foregroundStyle(.secondary)
            }
            // Newest first: the question is almost always "what just happened?".
            ForEach(controller.recentEvents.suffix(Self.shown).reversed()) { entry in
                Text("\(Self.clock.string(from: entry.date))  \(entry.message)")
                    .font(.callout)
            }
        } header: {
            Text("Recent events")
        }
    }
}
