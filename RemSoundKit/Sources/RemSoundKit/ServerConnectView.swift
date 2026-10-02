import SwiftUI

/// The server screen: where you type a server's address, pick one you have used before, and
/// leave the one you are on. A server is somewhere you go, not a peer you add, so it gets a
/// screen of its own rather than a row in the peer list.
///
/// The note at the top is the one thing that surprises people, so it is said plainly and
/// every time: a server only ever shows you the people using the same password as you.
public struct ServerConnectView: View {
    @Bindable private var controller: ReceiverController
    @Environment(\.dismiss) private var dismiss
    @State private var host: String
    @FocusState private var hostFocused: Bool

    public init(controller: ReceiverController) {
        self.controller = controller
        _host = State(initialValue: controller.serverAddress)
    }

    public var body: some View {
        NavigationStack {
            Form {
                noteSection
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

    private var noteSection: some View {
        Section {
            Text("When you connect to a server, you will only see and connect to people on it who are using the same password as the one you have set.")
                .font(.callout)
        } header: {
            Text("Please note")
        }
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
                .accessibilityHint("The address of a RemSound server. The standard port is used automatically.")
            Button(controller.isConnectedToServer ? "Go to this server" : "Connect", action: connect)
                .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty)
        } header: {
            Text(controller.isConnectedToServer ? "Change server" : "Connect to a server")
        } footer: {
            Text(controller.isConnectedToServer
                 ? "You are on \(controller.serverAddress). Connecting to another one leaves this one."
                 : "Everyone on a server with the same password as yours becomes one group: you see each other by name, and you hear whoever you have each ticked.")
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
                .accessibilityHint("Double tap to connect to this server. Forget is available as an action.")
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
            Text("Servers you have used")
        }
    }

    private var leaveSection: some View {
        Section {
            Button("Leave this server", role: .destructive) {
                controller.disconnectFromServer()
                dismiss()
            }
            .accessibilityHint("Stops using the server. The people on it leave your peer list; who you had ticked is remembered for when you come back.")
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
