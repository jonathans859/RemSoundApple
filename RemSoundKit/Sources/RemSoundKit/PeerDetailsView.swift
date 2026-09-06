import SwiftUI

/// Everything RemSound knows about one peer, plus the rename box — reached from the peer
/// row's "Peer details" / "Rename peer" actions (VoiceOver rotor actions and the context
/// menu, per pitfall 14: no swipe actions).
///
/// The same split the Diagnostics button makes for the connection panel: a peer ROW stays one
/// line, because a screen-reader user arrows past every row every time they open the app, and
/// the address, paths, uptime, ping, stream format and encryption state live one action away.
/// Mirrors the Windows app's Peer details box and Rename peer dialog.
struct PeerDetailsView: View {
    /// Read-only: @Observable tracks the reads in `body`, so no @Bindable is needed here.
    let controller: ReceiverController
    let peerId: String
    /// Opened from the row's "Rename peer" action — start with the name field focused so the
    /// action lands where it says it will.
    var focusName = false

    @Environment(\.dismiss) private var dismiss
    @State private var nameText = ""
    @State private var loadedName = false
    @State private var copied = false
    @State private var copyResetTask: Task<Void, Never>?
    @FocusState private var nameFocused: Bool

    /// Looked up live rather than captured, so the panel keeps updating with the 1 Hz tick
    /// (and reports the peer going away instead of freezing on stale text).
    private var peer: PeerListEntry? {
        controller.peers.first { $0.id == peerId }
    }

    var body: some View {
        NavigationStack {
            Form {
                if let peer {
                    detailsSection
                    nameSection(peer)
                    copySection(peer)
                } else {
                    Section {
                        Text("This peer is no longer in the list. It may have gone offline or been removed.")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(peer?.name ?? "Peer details")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                guard !loadedName else { return }
                nameText = peer?.customName ?? ""
                loadedName = true
            }
            .task {
                guard focusName else { return }
                // The field is not in the responder chain the instant the sheet appears;
                // focusing after presentation settles is what actually takes.
                try? await Task.sleep(for: .milliseconds(400))
                nameFocused = true
            }
        }
    }

    /// The live lines for this peer, rebuilt by the controller's 1 Hz tick.
    private var detailLines: [String] {
        controller.peerDetails[peerId] ?? []
    }

    private var detailsSection: some View {
        Section {
            if detailLines.isEmpty {
                Text("Details appear once RemSound is running.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(detailLines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.callout)
                        .accessibilityAddTraits(.updatesFrequently)
                }
            }
        } header: {
            Text("Details")
        } footer: {
            Text("These refresh every second while this screen is open.")
        }
    }

    private func nameSection(_ peer: PeerListEntry) -> some View {
        Section {
            TextField("Name for this peer", text: $nameText)
                .focused($nameFocused)
                .autocorrectionDisabled()
                .onSubmit { save(peer) }
                .accessibilityHint("A name of your choosing, used everywhere this peer appears in RemSound")
            Button("Save name") { save(peer) }
                .disabled(trimmedName == (peer.customName ?? ""))
            Button("Use the name this peer announces") {
                nameText = ""
                controller.renamePeer(peer, to: nil)
            }
            .disabled(peer.customName == nil)
            .accessibilityHint("Clears your own name for this peer, leaving \(peer.machineName ?? peer.addressString)")
        } header: {
            Text("Name")
        } footer: {
            Text("The name sticks to this peer, not to its address, so it survives the other computer restarting, changing address, or reaching you over a VPN. It is kept on this device only and is not part of a profile.")
        }
    }

    private func copySection(_ peer: PeerListEntry) -> some View {
        Section {
            Button(copied ? "Copied" : "Copy these details") {
                controller.copyPeerReport(for: peer)
                copied = true
                copyResetTask?.cancel()
                copyResetTask = Task {
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { return }
                    copied = false
                }
            }
            .accessibilityHint("Copies everything on this screen as text")
        }
    }

    private var trimmedName: String {
        nameText.trimmingCharacters(in: .whitespaces)
    }

    private func save(_ peer: PeerListEntry) {
        controller.renamePeer(peer, to: trimmedName)
        nameFocused = false
    }
}
