import SwiftUI

/// Everything RemSound knows about one peer, plus the rename box — reached from the peer
/// row's "Peer details" action (a VoiceOver rotor action and the context menu, per
/// pitfall 14: no swipe actions). Renaming has no row action of its own; it lives here.
///
/// The same split the Diagnostics button makes for the connection panel: a peer ROW stays one
/// line, because a screen-reader user arrows past every row every time they open the app, and
/// the address, paths, uptime, ping, stream format and encryption state live one action away.
/// Mirrors the Windows app's Peer details box and Rename peer dialog.
struct PeerDetailsView: View {
    /// Read-only: @Observable tracks the reads in `body`, so no @Bindable is needed here.
    let controller: ReceiverController
    let peerId: String

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
                        Text("This peer is gone.")
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
        }
    }

    /// The live lines for this peer, rebuilt by the controller's 1 Hz tick.
    private var detailLines: [String] {
        controller.peerDetails[peerId] ?? []
    }

    private var detailsSection: some View {
        Section {
            if detailLines.isEmpty {
                Text("No details while RemSound is stopped.")
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
        }
    }

    private func nameSection(_ peer: PeerListEntry) -> some View {
        Section {
            TextField("Name for this peer", text: $nameText)
                .focused($nameFocused)
                .autocorrectionDisabled()
                .onSubmit { save(peer) }
            Button("Save name") { save(peer) }
                .disabled(trimmedName == (peer.customName ?? ""))
            Button("Use original name") {
                nameText = ""
                controller.renamePeer(peer, to: nil)
            }
            .disabled(peer.customName == nil)
        } header: {
            Text("Name")
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
