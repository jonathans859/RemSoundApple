import SwiftUI

/// The server screen, laid out like the Windows server window (2026-10-09): the servers you
/// have been on FIRST — always there, even empty, so it is obvious that they are remembered —
/// then the box to type a new one, then leaving. A server is somewhere you go, not a peer you
/// add, so it gets a screen of its own rather than a row in the peer list.
///
/// The one thing that surprises people — a server only ever shows you the people using your
/// password — is the address section's footer, and is also announced on the first connect.
struct ServerConnectView: View {
    /// Read-only: @Observable tracks the reads in `body`, so no @Bindable is needed.
    let controller: ReceiverController
    @Environment(\.dismiss) private var dismiss
    @State private var host: String
    @FocusState private var hostFocused: Bool

    init(controller: ReceiverController) {
        self.controller = controller
        _host = State(initialValue: controller.serverAddress)
    }

    var body: some View {
        NavigationStack {
            Form {
                rememberedSection
                addressSection
                if controller.isConnectedToServer { leaveSection }
            }
            .formStyle(.grouped)
            .navigationTitle("Server")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
#if os(macOS)
        .frame(minWidth: 420, minHeight: 360)
#endif
    }

    private var rememberedSection: some View {
        Section {
            if controller.recentServers.isEmpty {
                Text("None yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(controller.recentServers, id: \.self) { previous in
                rememberedRow(previous)
            }
        } header: {
            Text("Remembered servers")
        }
    }

    @ViewBuilder
    private func rememberedRow(_ previous: String) -> some View {
        let current = previous.caseInsensitiveCompare(controller.serverAddress) == .orderedSame
            && controller.isConnectedToServer
        let row = Button {
            // Already there: going "again" would only drop and rebuild the group.
            if current { dismiss() } else { go(to: previous) }
        } label: {
            VStack(alignment: .leading) {
                Text(previous)
                if current {
                    Text("Connected")
                        .font(.caption)
                        .foregroundStyle(.tint)
                }
            }
        }
        .accessibilityLabel(current ? "\(previous), connected" : previous)
        // Same rule as the peer and profile rows (pitfall 14): the context menu is not
        // reliably reachable with VoiceOver, so the operation is also an explicit action —
        // and no swipe actions, which iOS would double up.
        .accessibilityAction(named: "Forget this server") {
            controller.forgetServer(host: previous)
        }
        .contextMenu {
            Button("Forget this server", role: .destructive) {
                controller.forgetServer(host: previous)
            }
        }
#if os(macOS)
        // Windows parity: Delete on a remembered server forgets it.
        row.onDeleteCommand { controller.forgetServer(host: previous) }
#else
        row
#endif
    }

    private var addressSection: some View {
        Section {
            TextField("Address or hostname", text: $host)
                .focused($hostFocused)
                .autocorrectionDisabled()
#if os(iOS)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
#endif
                .onSubmit { go(to: host) }
                .accessibilityLabel("Server address")
            Button(controller.isConnectedToServer ? "Go to this server" : "Connect") { go(to: host) }
                .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty)
        } header: {
            Text("Another server")
        } footer: {
            Text("You only see people using your password.")
        }
    }

    private var leaveSection: some View {
        Section {
            Button("Leave this server", role: .destructive) {
                controller.disconnectFromServer()
                dismiss()
            }
        }
    }

    private func go(to address: String) {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        hostFocused = false
        controller.connectToServer(host: trimmed)
        dismiss()
    }
}
