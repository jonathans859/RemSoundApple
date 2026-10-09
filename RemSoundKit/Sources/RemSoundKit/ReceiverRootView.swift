import SwiftUI

/// The main receiver UI, shared by the iOS app and the macOS menu-bar window. Built
/// VoiceOver-first: every control carries an explicit label and value, status lines are
/// plain readable sentences, and nothing requires a pointer.
public struct ReceiverRootView: View {
    @Bindable private var controller: ReceiverController
    @State private var newPeerHost = ""
    @FocusState private var addPeerFocused: Bool
    @State private var showingAbout = false
    @State private var showingDiagnostics = false
    @State private var showingServer = false
    @State private var newProfileName = ""
    @FocusState private var profileNameFocused: Bool
    @State private var renamingProfileId: UUID?
    @State private var renameText = ""
    /// Which peer's details sheet is open. ONE sheet at the top level rather than one per
    /// row: a sheet or alert owned by a row misfires on macOS when the row disappears
    /// underneath it — the same reason the profile rename alert lives on the tab, not on its
    /// row. (Rows move between lists when ticked, so this matters more than it used to.)
    @State private var peerDetailsRequest: PeerDetailsRequest?

    // Which Connectivity headings are open. Not persisted, so every launch reads the same:
    // Connected peers opens on its own (asked for, 2026-10-09), and so does Status, the
    // "am I connected" answer; the lists you only visit to add someone start folded away.
    @State private var statusExpanded = true
    @State private var connectedExpanded = true
    @State private var discoveredExpanded = false
    @State private var serverPeersExpanded = false
    @State private var addPeerExpanded = false

    private struct PeerDetailsRequest: Identifiable {
        let id: String
    }

    public init(controller: ReceiverController) {
        self.controller = controller
    }

    public var body: some View {
        // NavigationStack owns the title and the persistent About button (top-right on both
        // platforms); the TabView splits the controls into a Connectivity tab (status, peers,
        // add peer), a Send & Receive tab (receive/send toggles, microphone, password), an
        // Audio tab (playback options), and a Profiles tab (saved configuration snapshots).
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
                Tab("Profiles", systemImage: "bookmark") {
                    profilesTab
                }
                .accessibilityValue(appliedProfileTabValue, isEnabled: !appliedProfileTabValue.isEmpty)
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
            .sheet(isPresented: $showingDiagnostics) {
                DiagnosticsView(controller: controller)
            }
            .sheet(isPresented: $showingServer) {
                ServerConnectView(controller: controller)
            }
            .sheet(item: $peerDetailsRequest) { request in
                PeerDetailsView(controller: controller, peerId: request.id)
            }
        }
        // Its own view, for the same reason as the pickers at the bottom of this file: this
        // body re-renders every second, and a presented alert rebuilt underneath VoiceOver
        // can lose the button the user is on.
        .background { ConnectionRequestAlert(controller: controller) }
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
        // Windows parity (Connectivity tab): the people you are connected to, then the ones
        // you could connect to — on your network, then on the server — then adding one by
        // address. Ticking moves a row from a discovered list into Connected peers and
        // unticking moves it back, so one list always means one thing.
        Form {
            statusSection
            serverSection
            connectedPeersSection
            discoveredPeersSection
            serverPeersSection
            addPeerSection
            acceptConnectionsSection
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

    /// Spoken on the Profiles tab bar item (like Connectivity's traffic rates and Audio's
    /// "Muted"): which profile the current settings match, without opening the tab.
    private var appliedProfileTabValue: String {
        controller.appliedProfile.map { "\($0.name) applied" } ?? ""
    }

    private var profilesTab: some View {
        Form {
            profileListSection
            saveProfileSection
            startupProfileSection
            syncSection
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
            Text("Applying a profile replaces the peer list and selection, the server you are on, password, receive and send switches, microphone and its quality, and maximum delay. Volume and the other audio options are not touched. The profile your current settings match is marked as currently applied; changing any of its settings removes the mark.")
        }
    }

    @ViewBuilder
    private func profileRow(_ profile: ReceiverProfile) -> some View {
        let isApplied = controller.appliedProfile?.id == profile.id
        Button {
            controller.applyProfile(id: profile.id)
        } label: {
            VStack(alignment: .leading) {
                Text(profile.name)
                if isApplied {
                    Text("Currently applied")
                        .font(.caption)
                        .foregroundStyle(.tint)
                }
                Text(profileSummary(profile))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel("\(profile.name), \(isApplied ? "currently applied, " : "")\(profileSummary(profile))")
        .accessibilityHint("Double tap to apply this profile. Updating, renaming, and deleting are available as actions.")
        // Same VoiceOver rule as the peer rows: the context menu below is not reliably
        // reachable with VoiceOver, so each operation is a custom action — and no
        // .swipeActions, which iOS VoiceOver would expose as duplicate actions.
        .accessibilityAction(named: "Save current settings to this profile") {
            controller.updateProfile(id: profile.id)
        }
        .accessibilityAction(named: "Rename") {
            renameText = profile.name
            renamingProfileId = profile.id
        }
        .accessibilityAction(named: "Delete profile") {
            controller.deleteProfile(id: profile.id)
        }
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
    }

    /// Plain-sentence row detail, doubling as the VoiceOver value — mirrors what applying
    /// the profile will do without opening it.
    private func profileSummary(_ profile: ReceiverProfile) -> String {
        var parts: [String] = []
        parts.append("receive \(profile.receiveEnabled ? "on" : "off")")
        parts.append("send \(profile.sendEnabled ? "on" : "off")")
        // Only the expensive choice is worth a word here — every profile that says nothing
        // sends Opus, and the row is read out in full every time the list is arrowed past.
        if profile.sendCodec == .pcm { parts.append("sending uncompressed PCM") }
        let peerCount = profile.manualPeers.count
        if peerCount > 0 {
            parts.append("\(peerCount) saved peer\(peerCount == 1 ? "" : "s")")
        }
        if let server = profile.serverHost, !server.isEmpty {
            parts.append("on the server at \(server)")
        }
        // With auto-tune on the stored delay is only where the tuner starts, so say so
        // rather than promising a value the profile will not hold to.
        parts.append(profile.autoTuneLatencyEnabled
                     ? "delay adjusted automatically from \(profile.targetLatencyMs) ms"
                     : "\(profile.targetLatencyMs) ms delay")
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
            Text("Saves the peers, the server you are on, password, receive and send switches, microphone and its quality, and maximum delay as they are right now. Using an existing profile's name updates that profile.")
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
            StartupProfilePicker(controller: controller)
        } header: {
            Text("At launch")
        } footer: {
            Text("The profile is applied exactly as saved — if it was saved with microphone sending on, sending starts with the app.")
        }
    }

    /// The footer carries the caveats deliberately: sync depends on two separate iCloud
    /// switches the app cannot turn on itself, and a profile's microphone may not exist
    /// on the device it lands on. Plain sentences, because VoiceOver reads the footer as
    /// the toggle's context.
    private var syncSection: some View {
        Section {
            Toggle("Sync profiles through iCloud", isOn: $controller.iCloudProfileSyncEnabled)
                .accessibilityHint("Shares your saved profiles with your other devices signed in to the same iCloud account")
        } header: {
            Text("iCloud")
        } footer: {
            Text("""
            Saved profiles are shared with your other devices signed in to the same iCloud \
            account. Only the profiles are shared — the settings you are running right now, \
            which profile is applied, and the launch choice stay on this device.

            Profile passwords travel through iCloud Keychain, which is end-to-end encrypted, \
            so this needs iCloud Keychain switched on in Settings as well. Without it the \
            profiles still arrive, but with empty passwords you have to type once per device.

            A profile remembers a specific microphone. If that input does not exist on the \
            device the profile arrives on, that device sends from its default input instead.

            Deleting a profile deletes it everywhere. Turning this off leaves the profiles \
            already in iCloud for your other devices and keeps this device's copies.
            """)
        }
    }

    /// One heading for "am I connected": the summary, any error, the connection lines, and
    /// the Diagnostics button.
    private var statusSection: some View {
        Section {
            if statusExpanded {
                Text(controller.statusSummary)
                    .font(.headline)
                    .accessibilityLabel("Status: \(controller.statusSummary)")
                    .accessibilityAddTraits(.updatesFrequently)

                if let error = controller.lastError {
                    Text(error)
                        .foregroundStyle(.red)
                        .accessibilityLabel("Error: \(error)")
                }

                ForEach(Array(controller.connectionDetails.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.callout)
                        .accessibilityAddTraits(.updatesFrequently)
                }

                // The technical material lives behind this button rather than in the list
                // above: it is a dozen lines that rewrite every second, and a screen-reader
                // user arrowing through "am I connected" should not have to pass all of it.
                // Copying lives in the dialog, next to the numbers it copies — one button
                // rather than two that copy the same text from different places.
                if !controller.connectionDetails.isEmpty {
                    Button("Diagnostics") { showingDiagnostics = true }
                        .accessibilityHint("Opens packet timing, buffer depth and traffic measurements, and a button to copy them")
                }
            }
        } header: {
            CollapsibleHeader(title: "Status", isExpanded: $statusExpanded)
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

    /// A server is somewhere you go, so it sits above the peer lists rather than in one.
    /// While connected, the button changes to match what it now does — upstream's wording,
    /// because "connect" on a button that leaves is what made people hesitate to press it.
    private var serverSection: some View {
        Section {
            Button(controller.isConnectedToServer ? "Disconnect from or change server"
                                                  : "Connect to server") {
                showingServer = true
            }
            .accessibilityHint(controller.isConnectedToServer
                ? "Opens the server screen, where you can leave this server or go to another one"
                : "A server lets you reach people you cannot reach directly. Everyone on it using your password becomes one group.")

            if !controller.serverStatus.isEmpty {
                Text(controller.serverStatus)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Server: \(controller.serverStatus)")
                    .accessibilityAddTraits(.updatesFrequently)
            }

            // A peer the user added by address answered with an address-proof challenge, and
            // only a server sends one. They have added a place as though it were a person.
            if let suggested = controller.serverSuggestion {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(suggested) is a RemSound server, not a single peer. Connecting to it as a server shows you everyone on it who uses your password.")
                        .font(.callout)
                    Button("Connect to \(suggested) as a server") {
                        controller.connectToServer(host: suggested)
                        controller.dismissServerSuggestion()
                    }
                    Button("Not now") {
                        controller.dismissServerSuggestion()
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("\(suggested) is a RemSound server, not a single peer")
            }
        } header: {
            Text("Server")
        }
    }

    /// Everyone ticked, wherever they are reached — on the network, at a typed address, or
    /// through the server.
    private var connectedPeers: [PeerListEntry] { controller.peers.filter(\.isSelected) }
    /// Not ticked, reached directly — on the network, or at an address the user typed.
    private var discoveredPeers: [PeerListEntry] {
        controller.peers.filter { !$0.isSelected && !$0.isOnServer }
    }
    /// Not ticked, on the server — which only ever means people on our password.
    private var discoveredServerPeers: [PeerListEntry] {
        controller.peers.filter { !$0.isSelected && $0.isOnServer }
    }

    /// Upstream's names: with a server in the picture the network list says which it is.
    private var discoveredTitle: String {
        controller.isConnectedToServer ? "Discovered peers not on a server" : "Discovered peers"
    }
    private static let serverPeersTitle = "Discovered peers on the server"
    private static let connectedTitle = "Connected peers"

    private var connectedPeersSection: some View {
        Section {
            if connectedExpanded {
                if connectedPeers.isEmpty {
                    Text("No connected peers. Tick someone under \(discoveredTitle), add a peer by address, or connect to a server.")
                        .foregroundStyle(.secondary)
                }
                ForEach(connectedPeers) { peer in
                    peerRow(peer)
                }
            }
        } header: {
            CollapsibleHeader(title: Self.connectedTitle, count: connectedPeers.count,
                              isExpanded: $connectedExpanded)
        } footer: {
            if connectedExpanded {
                Text("Audio plays only from the peers ticked here, and your microphone goes to them. Untick a peer to move it back to the discovered list. Each peer's actions — peer details, and remove for peers you added — are on the row itself, in the VoiceOver rotor's Actions or the context menu.")
            }
        }
    }

    private var discoveredPeersSection: some View {
        Section {
            if discoveredExpanded {
                if discoveredPeers.isEmpty {
                    Text("No other peers found. Peers on the same network appear here automatically; add an address below for Tailscale, or connect to a server above.")
                        .foregroundStyle(.secondary)
                }
                ForEach(discoveredPeers) { peer in
                    peerRow(peer)
                }
            }
        } header: {
            CollapsibleHeader(title: discoveredTitle, count: discoveredPeers.count,
                              isExpanded: $discoveredExpanded)
        } footer: {
            if discoveredExpanded {
                Text("Tick a peer to connect to it; it moves to \(Self.connectedTitle).")
            }
        }
    }

    /// The people on the server who are not ticked, in their own list right under the
    /// network one — exactly as upstream, which found that one list mixing the two made it
    /// impossible to tell who was where.
    @ViewBuilder
    private var serverPeersSection: some View {
        if controller.isConnectedToServer {
            Section {
                if serverPeersExpanded {
                    if discoveredServerPeers.isEmpty {
                        Text(serverPeersEmptyText)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(discoveredServerPeers) { peer in
                        peerRow(peer)
                    }
                }
            } header: {
                CollapsibleHeader(title: Self.serverPeersTitle, count: discoveredServerPeers.count,
                                  isExpanded: $serverPeersExpanded)
            } footer: {
                if serverPeersExpanded {
                    Text("Only people using the same password as you ever appear here. Sound needs both ticks: tick someone and you hear each other as soon as they tick you back.")
                }
            }
        }
    }

    /// Why the server list is empty, which is never obvious and has four quite different
    /// causes — no password to be grouped by, no member list yet, nobody else, or everybody
    /// there is already in Connected peers.
    private var serverPeersEmptyText: String {
        if controller.password.isEmpty {
            return "Set a password on the Send and Receive tab. A server groups people by their password, so there is nothing to join without one."
        }
        if !controller.isInServerGroup {
            return "Waiting for the server's member list…"
        }
        if controller.peers.contains(where: \.isOnServer) {
            return "Everyone on this server using your password is already in \(Self.connectedTitle)."
        }
        return "Nobody else on this server is using your password yet."
    }

    /// Said when a tick moves a row to the other list. The row VoiceOver was on disappears
    /// from under it, so its own value change ("on") is not reliably spoken; this says where
    /// the peer went instead.
    private func announceMove(of peer: PeerListEntry, selected: Bool) {
        let destination = selected ? Self.connectedTitle
                                   : (peer.isOnServer ? Self.serverPeersTitle : discoveredTitle)
        AccessibilityNotification.Announcement("\(peer.name) moved to \(destination)").post()
    }

    @ViewBuilder
    private func peerRow(_ peer: PeerListEntry) -> some View {
        // Context menus are a pointer/touch convenience: VoiceOver cannot reliably reach
        // them (macOS especially), so every row operation is ALSO an explicit custom
        // accessibility action on the element VoiceOver focuses — the toggle.
        // Deliberately NO .swipeActions: iOS VoiceOver auto-exposes those as custom
        // actions, which doubled up with the explicit ones.
        let toggle = Toggle(isOn: Binding(
            get: { peer.isSelected },
            set: { selected in
                controller.setPeerSelected(peer, selected: selected)
                announceMove(of: peer, selected: selected)
            }
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

        // Details is an action on the row itself — the address, the paths, the ping, what the
        // peer is sending and its encryption state are one rotor action away instead of on
        // every row's summary line. Renaming lives inside that sheet, so it has no action of
        // its own (removed 2026-10-09: two actions opening the same sheet was one too many).
        let row = toggle
            .accessibilityAction(named: "Peer details") {
                peerDetailsRequest = PeerDetailsRequest(id: peer.id)
            }

        Group {
            if let manualId = peer.manualPeerId {
                row
                    .accessibilityAction(named: "Remove peer") {
                        controller.removeManualPeer(id: manualId)
                    }
            } else {
                row
            }
        }
        .contextMenu {
            Button("Peer details") {
                peerDetailsRequest = PeerDetailsRequest(id: peer.id)
            }
            if let manualId = peer.manualPeerId {
                Button("Remove peer", role: .destructive) {
                    controller.removeManualPeer(id: manualId)
                }
            }
        }
    }

    private var addPeerSection: some View {
        Section {
            if addPeerExpanded {
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
            }
        } header: {
            CollapsibleHeader(title: "Add a peer by address", isExpanded: $addPeerExpanded)
        } footer: {
            if addPeerExpanded {
                Text("A peer you add appears under \(discoveredTitle) until you tick it.")
            }
        }
    }

    private var acceptConnectionsSection: some View {
        Section {
            AcceptConnectionsPicker(controller: controller)
        } header: {
            Text("When someone ticks you")
        } footer: {
            Text("Sound only ever flows once both of you have ticked each other. This decides what happens at your end when somebody ticks you first: you are asked once per person, they are ticked back straight away, or nothing happens until you tick them yourself. Someone using a different password is never offered. Unticking somebody yourself always sticks until you tick them again or restart RemSound. Kept on this device; not part of a profile.")
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
                // Hidden from VoiceOver: the slider carries the same word as its own label,
                // and two elements saying "Volume" makes the row read it twice. Same reason
                // the trailing "ms" text below is hidden.
                Text("Volume")
                    .accessibilityHidden(true)
                Slider(value: $controller.volume, in: 0...1, step: 0.05)
                    .accessibilityLabel("Volume")
                    .accessibilityValue("\(Int(controller.volume * 100)) percent")
            }
            VolumeBoostPicker(controller: controller)
            Toggle("Mute", isOn: $controller.isMuted)

            HStack {
                Text("Maximum delay")
                    .accessibilityHidden(true)
                Slider(value: Binding(
                    get: { Double(controller.targetLatencyMs) },
                    set: { controller.targetLatencyMs = Int($0) }
                ), in: 5...500, step: 5)
                    .accessibilityLabel("Maximum delay")
                    .accessibilityValue("\(controller.targetLatencyMs) milliseconds")
                    .accessibilityHint("Lower is faster but needs a steadier network. The Windows app default is 80 milliseconds.")
                Text("\(controller.targetLatencyMs) ms")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    // The slider already speaks the value; a second element reading
                    // "500 ms" with no label would just be noise.
                    .accessibilityHidden(true)
            }

            Toggle("Adjust delay automatically", isOn: $controller.autoTuneLatencyEnabled)
                .accessibilityHint("Raises the delay when the network is unsteady and lowers it again when the network settles, instead of holding the value above")
            if controller.autoTuneLatencyEnabled, let note = controller.lastAutoTuneNote {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.updatesFrequently)
            }

            Toggle("Sound effects", isOn: $controller.cuesEnabled)
                .accessibilityHint("Plays a sound when a peer connects or disconnects, when receiving or sending is turned on or off, and when a profile is saved")

#if os(iOS)
            Toggle("Don't mix with other sounds", isOn: $controller.exclusiveAudio)
                .accessibilityHint("When on, RemSound interrupts other apps' audio and is interrupted by them, which also helps keep RemSound running while the screen is locked. When off, RemSound and other apps' sound can play at the same time.")

            Toggle("Pause with headset or lock screen", isOn: $controller.headsetTransportControls)
                .accessibilityHint("When on, pressing the stem of an AirPod, or the play and pause button on the lock screen or in Control Center, stops receiving audio; pressing it again starts receiving again.")
            // Not disabled, just explained: the preference is worth keeping for whenever
            // sole control goes back on, and a dimmed switch says less than the sentence.
            if controller.headsetTransportControls && !controller.exclusiveAudio {
                Text("These buttons need sole control of the audio, so they do nothing while \"Don't mix with other sounds\" is off — the system sends them to whichever app has the sound.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
#else
            Toggle("Pause with headset or media keys", isOn: $controller.headsetTransportControls)
                .accessibilityHint("When on, pressing the stem of an AirPod, or the play and pause key on the keyboard, stops receiving audio; pressing it again starts receiving again.")
#endif
        } header: {
            Text("Playback")
        } footer: {
#if os(iOS)
            Text("With \"Don't mix with other sounds\" on, whichever starts playing — RemSound or another app — stops the other, and that is also what keeps RemSound running while the screen is locked. With it off, RemSound plays alongside other apps, but iOS may stop it once the screen has been locked for a while.")
#else
            EmptyView()
#endif
        }
    }

    private var sendSection: some View {
        Section {
            Toggle("Send microphone", isOn: $controller.sendEnabled)
                .accessibilityHint("Streams this device's microphone, encrypted, to the peers selected on the Connectivity tab")

            MicrophonePicker(controller: controller)

            SendCodecPicker(controller: controller)

            if !controller.sendStatus.isEmpty {
                Text(controller.sendStatus)
                    .font(.callout)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        } header: {
            Text("Send")
        } footer: {
            Text("Audio goes to the peers you have ticked on the Connectivity tab; they must also allow this device in their RemSound app. Using Bluetooth headphones' microphone lowers their playback quality while sending. Opus sends about 24 kilobytes a second to each peer; uncompressed PCM sends about 290, roughly a gigabyte an hour, so it suits a local network rather than mobile data.")
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

// MARK: - Pop-up pickers
//
// Both pickers below are their OWN View structs, and must stay that way (issue #3). Written
// as computed properties of ReceiverRootView they were inlined into its body, which reads
// 1 Hz refresh state (`trafficSummary` for the Connectivity tab's accessibility value, the
// live status lines inside the tabs). Every tick therefore rebuilt the picker's content —
// and rebuilding a *presented* menu's contents destroys the accessibility element the user
// has focused, so VoiceOver and Full Keyboard Access were both thrown back onto the
// backdrop's "Dismiss context menu" once a second and could never reach an option.
//
// As separate structs storing only the controller reference, SwiftUI diffs those stored
// properties on a parent re-render, finds the same object, and skips these bodies entirely;
// Observation re-runs them only when something they actually read changes. The parent still
// re-renders every second by design (uptime and traffic rates are live) — the isolation is
// what keeps the open menu stable underneath it.

/// What happens when somebody ticks us first — upstream's "Accept connections from other
/// peers", in its own order (the default, Ask, first).
private struct AcceptConnectionsPicker: View {
    @Bindable var controller: ReceiverController

    var body: some View {
        Picker("Accept connections from other peers", selection: $controller.acceptPeerConnections) {
            ForEach(PeerAcceptMode.allCases) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .pickerStyle(.menu)
        .accessibilityHint("What happens when somebody ticks you before you have ticked them")
    }
}

/// A section heading that folds its section away. Built by hand rather than with
/// `DisclosureGroup` or `Section(isExpanded:)`: the latter only collapses in sidebar-style
/// lists, never in this grouped Form, and what VoiceOver says for a DisclosureGroup is not
/// documented anywhere. This is explicit: one element, a heading (so the rotor's Headings
/// jumps between them) that is also a button, valued "Expanded" or "Collapsed".
/// Double-tapping changes that value, which VoiceOver speaks by itself, so there is
/// deliberately no announcement on top of it.
private struct CollapsibleHeader: View {
    let title: String
    /// How many rows the section holds, said and shown even while it is folded — the reason
    /// to open a list is usually knowing there is somebody in it.
    var count: Int?
    @Binding var isExpanded: Bool

    var body: some View {
        Button {
            withAnimation { isExpanded.toggle() }
        } label: {
            HStack {
                Text(title)
                if let count {
                    Text("(\(count))")
                        .monospacedDigit()
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .textCase(nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(count.map { "\(title), \($0)" } ?? title)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityAddTraits([.isHeader, .isButton])
    }
}

/// Puts `ReceiverController.pendingConnectionRequest` up as a question. Its body reads only
/// that one property, so the 1 Hz re-render of the root view never rebuilds an alert the
/// user is in the middle of answering.
private struct ConnectionRequestAlert: View {
    let controller: ReceiverController

    var body: some View {
        Color.clear
            .alert("Connection request", isPresented: Binding(
                get: { controller.pendingConnectionRequest != nil },
                // Answered by the buttons; a dismissal is always one of them.
                set: { _ in }
            ), presenting: controller.pendingConnectionRequest) { _ in
                Button("Allow") { controller.answerConnectionRequest(allow: true) }
                Button("Don't Allow", role: .cancel) { controller.answerConnectionRequest(allow: false) }
            } message: { request in
                Text("\(request.question) Do you want to allow this?")
            }
    }
}

private struct VolumeBoostPicker: View {
    @Bindable var controller: ReceiverController

    var body: some View {
        Picker("Extra volume", selection: $controller.volumeBoost) {
            ForEach(VolumeBoost.allCases) { boost in
                Text(boost.displayName).tag(boost)
            }
        }
        .pickerStyle(.menu)
        .accessibilityHint("Makes a quiet sender louder. The limiter keeps peaks from clipping, but a large boost on already-loud audio will distort.")
    }
}

/// Opus or raw PCM for our own microphone stream (the Windows sender offers the same
/// choice). Two named cases rather than `CaseIterable`, so the recommended one is read first.
private struct SendCodecPicker: View {
    @Bindable var controller: ReceiverController

    var body: some View {
        Picker("Microphone quality", selection: $controller.sendCodec) {
            Text("Opus — compressed, recommended").tag(AudioTransportCodec.opus)
            Text("PCM — uncompressed, much more data").tag(AudioTransportCodec.pcm)
        }
        .pickerStyle(.menu)
        .accessibilityHint("Opus sends about 24 kilobytes a second to each peer. PCM sends about 290 kilobytes a second, with slightly less delay and no compression.")
    }
}

private struct StartupProfilePicker: View {
    @Bindable var controller: ReceiverController

    var body: some View {
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
    }
}

private struct MicrophonePicker: View {
    @Bindable var controller: ReceiverController

    var body: some View {
        Picker("Microphone", selection: $controller.selectedMicrophoneId) {
            Text("System default").tag(String?.none)
            ForEach(controller.availableMicrophones) { mic in
                Text(mic.name).tag(String?.some(mic.id))
            }
            // Keep a chosen input selectable while it's absent so the picker doesn't
            // silently jump selections — it's unplugged, or the profile naming it was
            // saved on another device. Capture falls back to the default input either
            // way (MicrophoneCapture.applyPreferredInputPreStart / applyPreferredDevice),
            // so the label says so rather than leaving a mystery selection.
            if let selected = controller.selectedMicrophoneId,
               !controller.availableMicrophones.contains(where: { $0.id == selected }) {
                Text("Saved input, not available here — sending from the default input")
                    .tag(String?.some(selected))
            }
        }
        // Explicit menu style: a pop-up button (macOS) / anchored menu (iOS) reads as
        // one focusable "pop-up button" element under VoiceOver, instead of whatever
        // presentation the automatic style resolves to in this Form.
        .pickerStyle(.menu)
        .accessibilityHint("Which microphone or input to send from")
    }
}
