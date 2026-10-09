import SwiftUI

/// The server screen: where you type a server's address, pick one you have used before, and
/// leave the one you are on. A server is somewhere you go, not a peer you add, so it gets a
/// screen of its own rather than a row in the peer list.
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
                addressSection
                if !controller.recentServers.isEmpty { recentSection }
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

    private var addressSection: some View {
        Section {
            TextField("Address or hostname", text: $host)
                .focused($hostFocused)
                .autocorrectionDisabled()
#if os(iOS)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
#endif
                .onSubmit(connect)
                .accessibilityLabel("Server address")
            Button(controller.isConnectedToServer ? "Go to this server" : "Connect", action: connect)
                .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty)
        } footer: {
            Text("You only see people using your password.")
        }
    }

    private var recentSection: some View {
        Section {
            ForEach(controller.recentServers, id: \.self) { previous in
                let current = previous.caseInsensitiveCompare(controller.serverAddress) == .orderedSame
                    && controller.isConnectedToServer
                Button {
                    host = previous
                    connect()
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
                // Same rule as the peer and profile rows (pitfall 14): the context menu is
                // not reliably reachable with VoiceOver, so the operation is also an
                // explicit action — and no swipe actions, which iOS would double up.
                .accessibilityAction(named: "Forget this server") {
                    controller.forgetServer(host: previous)
                }
                .contextMenu {
                    Button("Forget this server", role: .destructive) {
                        controller.forgetServer(host: previous)
                    }
                }
            }
        } header: {
            Text("Recent")
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

    private func connect() {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        hostFocused = false
        controller.connectToServer(host: trimmed)
        dismiss()
    }
}
