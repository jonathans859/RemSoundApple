import SwiftUI

/// The main receiver UI, shared by the iOS app and the macOS menu-bar window. Built
/// VoiceOver-first: every control carries an explicit label and value, status lines are
/// plain readable sentences, and nothing requires a pointer.
public struct ReceiverRootView: View {
    @Bindable private var controller: ReceiverController
    @State private var newPeerHost = ""
    @FocusState private var addPeerFocused: Bool
    @State private var showingAbout = false
    @State private var newProfileName = ""
    @FocusState private var profileNameFocused: Bool
    @State private var renamingProfileId: UUID?
    @State private var renameText = ""

    public init(controller: ReceiverController) {
        self.controller = controller
    }

    public var body: some View {
        // NavigationStack owns the title and the persistent About button (top-right on both
        // platforms); the TabView splits the controls into a Connectivity tab (status, peers,
        // add peer), a Send & Receive tab (receive/send toggles, microphone, password), a
        // Profiles tab (saved configuration snapshots), and an Audio tab (playback options).
        // There is no push navigation, so nesting the TabView inside the stack keeps one
        // toolbar across tabs.
        NavigationStack {
            // The Tab API (not .tabItem) so tab bar items themselves expose live state as
            // their accessibility value: Connectivity reads the traffic rates, Audio reads
            // "Muted". SwiftUI offers no way to attach a custom VoiceOver action to a
            // native tab bar item (TabContent has label/value/hint only), so quick mute is
            // the magic tap below instead — the hint on the Audio tab teaches the gesture.
            TabView {
                Tab("Connectivity", systemImage: "network") {
                    connectivityTab
                }
                .accessibilityValue(controller.trafficSummary,
                                    isEnabled: !controller.trafficSummary.isEmpty)
                Tab("Send & Receive", systemImage: "arrow.up.arrow.down") {
                    sendReceiveTab
                }
                Tab("Profiles", systemImage: "bookmark") {
                    profilesTab
                }
#if os(iOS)
                Tab("Audio", systemImage: "speaker.wave.2.fill") {
                    audioTab
                }
                .accessibilityValue("Muted", isEnabled: controller.isMuted)
                .accessibilityHint("Two-finger double tap anywhere mutes or unmutes the audio")
#else
                Tab("Audio", systemImage: "speaker.wave.2.fill") {
                    audioTab
                }
                .accessibilityValue("Muted", isEnabled: controller.isMuted)
#endif
            }
#if os(macOS)
            // The automatic macOS 15 style hoists the tabs into the window toolbar, where
            // the navigation title + About button leave too little room and the tabs
            // collapse into an overflow pulldown menu. Grouped keeps them as always-visible
            // segmented tabs above the content.
            .tabViewStyle(.grouped)
#endif
            .navigationTitle("RemSound")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAbout = true
                    } label: {
                        Label("About", systemImage: "info.circle")
                    }
                    .accessibilityLabel("About RemSound")
                    .accessibilityHint("App information and links to the RemSound source code")
                }
            }
            .sheet(isPresented: $showingAbout) {
                AboutView()
            }
        }
#if os(iOS)
        // VoiceOver magic tap = quick mute from anywhere in the app, including with focus
        // on the tab bar. Root-level so it resolves no matter which element is focused.
        // (.magicTap does not exist on macOS.)
        .accessibilityAction(.magicTap) {
            controller.toggleMute()
        }
#endif
    }

    private var connectivityTab: some View {
        Form {
            statusSection
            connectionSection
            peersSection
            addPeerSection
        }
        .formStyle(.grouped)
    }

    private var sendReceiveTab: some View {
        Form {
            receiveSection
            sendSection
            securitySection
        }
        .formStyle(.grouped)
    }

    private var audioTab: some View {
        Form {
            audioSection
        }
        .formStyle(.grouped)
    }

    private var profilesTab: some View {
        Form {
            profileListSection
            saveProfileSection
            startupProfileSection
        }
        .formStyle(.grouped)
        // One shared rename prompt for whichever row triggered it (alerts inside ForEach
        // rows misfire on macOS when the row disappears under an open context menu).
        .alert("Rename profile", isPresented: Binding(
            get: { renamingProfileId != nil },
            set: { if !$0 { renamingProfileId = nil } }
        )) {
            TextField("Profile name", text: $renameText)
            Button("Rename") {
                if let id = renamingProfileId {
                    controller.renameProfile(id: id, to: renameText)
                }
                renamingProfileId = nil
            }
            Button("Cancel", role: .cancel) {
                renamingProfileId = nil
            }
        }
    }

    private var profileListSection: some View {
        Section {
            if controller.profiles.isEmpty {
                Text("No profiles yet. Set up peers, password, and toggles the way you like, then save the setup below.")
                    .foregroundStyle(.secondary)
            }
            ForEach(controller.profiles) { profile in
                profileRow(profile)
            }
        } header: {
            Text("Saved profiles")
        } footer: {
            Text("Applying a profile replaces the peer list and selection, password, receive and send switches, microphone, and maximum delay. Volume and the other audio options are not touched.")
        }
    }

    @ViewBuilder
    private func profileRow(_ profile: ReceiverProfile) -> some View {
        Button {
            controller.applyProfile(id: profile.id)
        } label: {
            VStack(alignment: .leading) {
                Text(profile.name)
                Text(profileSummary(profile))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel("\(profile.name), \(profileSummary(profile))")
        .accessibilityHint("Double tap to apply this profile. Updating, renaming, and deleting are in the context menu.")
        .contextMenu {
            Button("Save current settings to this profile") {
                controller.updateProfile(id: profile.id)
            }
            Button("Rename…") {
                renameText = profile.name
                renamingProfileId = profile.id
            }
            Button("Delete profile", role: .destructive) {
                controller.deleteProfile(id: profile.id)
            }
        }
        .swipeActions(edge: .trailing) {
            Button("Delete", role: .destructive) {
                controller.deleteProfile(id: profile.id)
            }
        }
    }

    /// Plain-sentence row detail, doubling as the VoiceOver value — mirrors what applying
    /// the profile will do without opening it.
    private func profileSummary(_ profile: ReceiverProfile) -> String {
        var parts: [String] = []
        parts.append("receive \(profile.receiveEnabled ? "on" : "off")")
        parts.append("send \(profile.sendEnabled ? "on" : "off")")
        let peerCount = profile.manualPeers.count
        if peerCount > 0 {
            parts.append("\(peerCount) saved peer\(peerCount == 1 ? "" : "s")")
        }
        parts.append("\(profile.targetLatencyMs) ms delay")
        return parts.joined(separator: ", ")
    }

    private var saveProfileSection: some View {
        Section {
            HStack {
                TextField("Profile name", text: $newProfileName)
                    .focused($profileNameFocused)
                    .onSubmit(saveProfile)
                    .accessibilityHint("Name for the saved configuration. Using an existing profile's name updates that profile.")
                Button("Save", action: saveProfile)
                    .disabled(newProfileName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("Save current configuration")
        } footer: {
            Text("Saves the peers, password, receive and send switches, microphone, and maximum delay as they are right now. Using an existing profile's name updates that profile.")
        }
    }

    private func saveProfile() {
        let name = newProfileName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        controller.saveProfile(named: name)
        newProfileName = ""
        profileNameFocused = false
    }

    private var startupProfileSection: some View {
        Section {
            Picker("Apply at launch", selection: $controller.startupProfile) {
                Text("No profile — settings as you left them")
                    .tag(StartupProfileChoice.off)
                Text("Last applied profile")
                    .tag(StartupProfileChoice.lastApplied)
                ForEach(controller.profiles) { profile in
                    Text(profile.name).tag(StartupProfileChoice.fixed(profile.id))
                }
            }
            .pickerStyle(.menu)
            .accessibilityHint("Which profile the app applies each time it starts")
        } header: {
            Text("At launch")
        } footer: {
            Text("Starting up never turns on microphone sending, even if the profile has it on — the send switch always starts off.")
        }
    }

    @ViewBuilder
    private var connectionSection: some View {
        if !controller.connectionDetails.isEmpty {
            Section {
                ForEach(Array(controller.connectionDetails.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.callout)
                        .accessibilityAddTraits(.updatesFrequently)
                }
            } header: {
                Text("Connection")
            }
        }
    }

    private var statusSection: some View {
        Section {
            Text(controller.statusSummary)
                .font(.headline)
                .accessibilityLabel("Status: \(controller.statusSummary)")
                .accessibilityAddTraits(.updatesFrequently)

            if let error = controller.lastError {
                Text(error)
                    .foregroundStyle(.red)
                    .accessibilityLabel("Error: \(error)")
            }
        } header: {
            Text("Status")
        }
    }

    private var receiveSection: some View {
        Section {
            Toggle(isOn: $controller.receiveEnabled) {
                Text("Receive audio")
            }
            .accessibilityHint("Plays audio from RemSound senders. Turning this off keeps peers connected and sending available.")
        } header: {
            Text("Receive")
        } footer: {
            Text("Receiving and sending are independent — either can be on without the other.")
        }
    }

    private var peersSection: some View {
        Section {
            if controller.peers.isEmpty {
                Text("No peers yet. Peers on the same network appear automatically; add an address below for Tailscale or the relay.")
                    .foregroundStyle(.secondary)
            }
            ForEach(controller.peers) { peer in
                peerRow(peer)
            }
        } header: {
            Text("Peers")
        } footer: {
            Text("Tick a peer to hear its audio. Audio plays only from peers you have selected.")
        }
    }

    @ViewBuilder
    private func peerRow(_ peer: PeerListEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(isOn: Binding(
                get: { peer.isSelected },
                set: { controller.setPeerSelected(peer, selected: $0) }
            )) {
                VStack(alignment: .leading) {
                    Text(peer.name)
                    Text(peer.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityLabel("\(peer.name), \(peer.statusText)")
            .accessibilityHint(peer.isSelected ? "Selected. Double tap to stop receiving from this peer."
                                               : "Not selected. Double tap to receive audio from this peer.")
        }
        .contextMenu {
            if let manualId = peer.manualPeerId {
                Button("Remove peer", role: .destructive) {
                    controller.removeManualPeer(id: manualId)
                }
            }
        }
        .swipeActions(edge: .trailing) {
            if let manualId = peer.manualPeerId {
                Button("Remove", role: .destructive) {
                    controller.removeManualPeer(id: manualId)
                }
            }
        }
    }

    private var addPeerSection: some View {
        Section {
            HStack {
                TextField("Address or hostname", text: $newPeerHost)
                    .focused($addPeerFocused)
                    .autocorrectionDisabled()
#if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
#endif
                    .onSubmit(addPeer)
                    .accessibilityHint("A LAN IP, Tailscale IP, or the RemSound relay hostname. The standard port is used automatically.")
                Button("Add", action: addPeer)
                    .disabled(newPeerHost.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("Add a peer by address")
        }
    }

    private func addPeer() {
        controller.addManualPeer(host: newPeerHost)
        newPeerHost = ""
        addPeerFocused = false
    }

    private var audioSection: some View {
        Section {
            HStack {
                Text("Volume")
                Slider(value: $controller.volume, in: 0...1, step: 0.05)
                    .accessibilityLabel("Volume")
                    .accessibilityValue("\(Int(controller.volume * 100)) percent")
            }
            Toggle("Mute", isOn: $controller.isMuted)

            Stepper(value: $controller.targetLatencyMs, in: 5...500, step: 5) {
                Text("Maximum delay: \(controller.targetLatencyMs) milliseconds")
            }
            .accessibilityHint("Lower is faster but needs a steadier network. The Windows app default is 80 milliseconds.")

            Toggle("Connection sounds", isOn: $controller.cuesEnabled)
                .accessibilityHint("Plays a sound when a peer connects or disconnects")

#if os(iOS)
            Toggle("Exclusive audio", isOn: $controller.exclusiveAudio)
                .accessibilityHint("Keeps audio and the connection running while the screen is locked, by taking sole control of playback. While this is on, other apps' sound is interrupted instead of mixing in.")
#endif
        } header: {
            Text("Playback")
        } footer: {
#if os(iOS)
            Text("Exclusive audio keeps RemSound running while the screen is locked; the trade-off is that other apps' audio is interrupted while receiving.")
#else
            EmptyView()
#endif
        }
    }

    private var sendSection: some View {
        Section {
            Toggle("Send microphone", isOn: $controller.sendEnabled)
                .accessibilityHint("Streams this device's microphone, encrypted, to the peers selected on the Connectivity tab")

            Picker("Microphone", selection: $controller.selectedMicrophoneId) {
                Text("System default").tag(String?.none)
                ForEach(controller.availableMicrophones) { mic in
                    Text(mic.name).tag(String?.some(mic.id))
                }
                // Keep a previously chosen input selectable while it's unplugged so the
                // picker doesn't silently jump selections.
                if let selected = controller.selectedMicrophoneId,
                   !controller.availableMicrophones.contains(where: { $0.id == selected }) {
                    Text("Previously selected input").tag(String?.some(selected))
                }
            }
            // Explicit menu style: a pop-up button (macOS) / anchored menu (iOS) reads as
            // one focusable "pop-up button" element under VoiceOver, instead of whatever
            // presentation the automatic style resolves to in this Form.
            .pickerStyle(.menu)
            .accessibilityHint("Which microphone or input to send from")

            if !controller.sendStatus.isEmpty {
                Text(controller.sendStatus)
                    .font(.callout)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        } header: {
            Text("Send")
        } footer: {
            Text("Audio goes to the peers you have ticked on the Connectivity tab; they must also allow this device in their RemSound app. Using Bluetooth headphones' microphone lowers their playback quality while sending.")
        }
    }

    private var securitySection: some View {
        Section {
            SecureField("Password", text: $controller.password)
                .accessibilityHint("Must match the password set on the sending computer. Audio stays silent until the passwords match.")
        } header: {
            Text("Password")
        } footer: {
            Text("All audio is encrypted end to end. Use the same password as the RemSound profile on the sending computer.")
        }
    }
}
