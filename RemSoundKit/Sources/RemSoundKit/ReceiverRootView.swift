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
        // Windows parity: the people you are connected to, then the ones you could connect to
        // (on your network, then on the server), then adding one by address. Ticking moves a
        // row between lists, so one list always means one thing. The server is somewhere you
        // go rather than somebody in a list, so its button sits last (user, 2026-10-09).
        Form {
            statusSection
            connectedPeersSection
            discoveredPeersSection
            serverPeersSection
            addPeerSection
            acceptConnectionsSection
            serverSection
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
                Text("No profiles yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(controller.profiles) { profile in
                profileRow(profile)
            }
        } header: {
            HStack {
                Text("Saved profiles")
                Spacer()
                InfoButton(title: "Profiles", message: "A profile saves your peers, server, password, receive and send switches, microphone and its quality, delay, and how connections are accepted. Volume and the other audio options are not included.")
            }
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
                    Text("Applied")
                        .font(.caption)
                        .foregroundStyle(.tint)
                }
                Text(profileSummary(profile))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel("\(profile.name), \(isApplied ? "applied, " : "")\(profileSummary(profile))")
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

    /// Short row detail, doubling as the VoiceOver value — what applying the profile does.
    private func profileSummary(_ profile: ReceiverProfile) -> String {
        var parts: [String] = []
        parts.append("receive \(profile.receiveEnabled ? "on" : "off")")
        parts.append("send \(profile.sendEnabled ? "on" : "off")")
        // Only the expensive choice is worth a word here — every profile that says nothing
        // sends Opus, and the row is read out in full every time the list is arrowed past.
        if profile.sendCodec == .pcm { parts.append("PCM") }
        let peerCount = profile.manualPeers.count
        if peerCount > 0 {
            parts.append("\(peerCount) peer\(peerCount == 1 ? "" : "s")")
        }
        if let server = profile.serverHost, !server.isEmpty {
            parts.append("server \(server)")
        }
        // Only when it is not the default ask, for the same reason as the codec above.
        if profile.acceptPeerConnections != .prompt {
            parts.append("accepts \(profile.acceptPeerConnections == .automatic ? "automatically" : "manually")")
        }
        // With auto-tune on the stored delay is only where the tuner starts.
        parts.append(profile.autoTuneLatencyEnabled
                     ? "auto delay"
                     : "\(profile.targetLatencyMs) ms")
        return parts.joined(separator: ", ")
    }

    private var saveProfileSection: some View {
        Section {
            HStack {
                TextField("Profile name", text: $newProfileName)
                    .focused($profileNameFocused)
                    .onSubmit(saveProfile)
                Button("Save", action: saveProfile)
                    .disabled(newProfileName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("Save current settings")
        } footer: {
            Text("An existing name updates that profile.")
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
        }
    }

    private var syncSection: some View {
        Section {
            HStack {
                Toggle("Sync profiles through iCloud", isOn: $controller.iCloudProfileSyncEnabled)
                InfoButton(title: "iCloud sync", message: "Profiles are shared with your devices on the same iCloud account. Passwords travel through iCloud Keychain, so turn that on too, or they arrive empty. Deleting a profile deletes it everywhere.")
            }
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
                if !controller.connectionDetails.isEmpty {
                    Button("Diagnostics") { showingDiagnostics = true }
                }
            }
        } header: {
            CollapsibleHeader(title: "Status", isExpanded: $statusExpanded)
        }
    }

    private var receiveSection: some View {
        Section {
            Toggle("Receive audio", isOn: $controller.receiveEnabled)
        }
    }

    /// While connected, the button says what it now does — upstream's wording, because
    /// "connect" on a button that leaves is what made people hesitate to press it.
    private var serverSection: some View {
        Section {
            Button(controller.isConnectedToServer ? "Change or leave server" : "Connect to server") {
                showingServer = true
            }

            if !controller.serverStatus.isEmpty {
                Text(controller.serverStatus)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.updatesFrequently)
            }

            // A peer the user added by address answered with an address-proof challenge, and
            // only a server sends one. They have added a place as though it were a person.
            if let suggested = controller.serverSuggestion {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(suggested) is a server, not a peer.")
                        .font(.callout)
                    Button("Connect to it as a server") {
                        controller.connectToServer(host: suggested)
                        controller.dismissServerSuggestion()
                    }
                    Button("Not now") {
                        controller.dismissServerSuggestion()
                    }
                }
                .accessibilityElement(children: .contain)
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
                    Text("None yet. Tick a peer to connect.")
                        .foregroundStyle(.secondary)
                }
                ForEach(connectedPeers) { peer in
                    peerRow(peer)
                }
            }
        } header: {
            CollapsibleHeader(title: Self.connectedTitle, count: connectedPeers.count,
                              isExpanded: $connectedExpanded)
        }
    }

    private var discoveredPeersSection: some View {
        Section {
            if discoveredExpanded {
                if discoveredPeers.isEmpty {
                    Text("None found.")
                        .foregroundStyle(.secondary)
                }
                ForEach(discoveredPeers) { peer in
                    peerRow(peer)
                }
            }
        } header: {
            CollapsibleHeader(title: discoveredTitle, count: discoveredPeers.count,
                              isExpanded: $discoveredExpanded)
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
            }
        }
    }

    /// Why the server list is empty. Kept, however short everything else gets: the four
    /// causes look identical from the outside and only one of them is "nobody is there".
    private var serverPeersEmptyText: String {
        if controller.password.isEmpty {
            return "Set a password to join a group."
        }
        if !controller.isInServerGroup {
            return "Waiting for the member list…"
        }
        if controller.peers.contains(where: \.isOnServer) {
            return "Everyone here is connected."
        }
        return "Nobody else here uses your password."
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
                if !peer.statusText.isEmpty {
                    Text(peer.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityLabel(peer.statusText.isEmpty ? peer.name : "\(peer.name), \(peer.statusText)")

        // Details is an action on the row itself — the address, the paths, the ping, what the
        // peer is sending and its encryption state are one rotor action away instead of on
        // every row's summary line. Renaming lives inside that sheet.
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
                    Button("Add", action: addPeer)
                        .disabled(newPeerHost.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        } header: {
            CollapsibleHeader(title: "Add a peer by address", isExpanded: $addPeerExpanded)
        }
    }

    private var acceptConnectionsSection: some View {
        Section {
            AcceptConnectionsPicker(controller: controller)
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
                Text("\(controller.targetLatencyMs) ms")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    // The slider already speaks the value; a second element reading
                    // "500 ms" with no label would just be noise.
                    .accessibilityHidden(true)
            }

            Toggle("Adjust delay automatically", isOn: $controller.autoTuneLatencyEnabled)
            if controller.autoTuneLatencyEnabled, let note = controller.lastAutoTuneNote {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.updatesFrequently)
            }

            Toggle("Sound effects", isOn: $controller.cuesEnabled)

#if os(iOS)
            HStack {
                Toggle("Don't mix with other sounds", isOn: $controller.exclusiveAudio)
                InfoButton(title: "Don't mix with other sounds", message: "On: RemSound and other apps interrupt each other, and RemSound keeps playing with the screen locked. Headset buttons only work while this is on.\n\nOff: RemSound plays alongside other apps, but iOS may stop it once the screen has been locked for a while.")
            }

            HStack {
                Toggle("Headset and lock screen controls", isOn: $controller.headsetTransportControls)
                InfoButton(title: "Headset and lock screen controls", message: "Play/pause turns receiving on and off.\n\nNext track turns the microphone on and off: double-press an AirPod, or use ⏭ on the lock screen or in Control Center.")
            }
            // Not disabled, just explained: the preference is worth keeping for whenever
            // sole control goes back on, and a dimmed switch says less than the sentence.
            if controller.headsetTransportControls && !controller.exclusiveAudio {
                Text("Needs \"Don't mix with other sounds\".")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
#else
            HStack {
                Toggle("Headset and media keys", isOn: $controller.headsetTransportControls)
                InfoButton(title: "Headset and media keys", message: "Play/pause turns receiving on and off.\n\nNext track turns the microphone on and off: double-press an AirPod, or press the fast-forward key.")
            }
#endif
        }
    }

    private var sendSection: some View {
        Section {
            Toggle("Send microphone", isOn: $controller.sendEnabled)

            MicrophonePicker(controller: controller)

            HStack {
                SendCodecPicker(controller: controller)
                InfoButton(title: "Microphone quality", message: "Opus sends about 24 kilobytes a second to each peer. PCM is uncompressed: about 290 kilobytes a second, roughly a gigabyte an hour, so keep it for local networks.")
            }

            if !controller.sendStatus.isEmpty {
                Text(controller.sendStatus)
                    .font(.callout)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
    }

    private var securitySection: some View {
        Section {
            SecureField("Password", text: $controller.password)
        } footer: {
            Text("Must match the password on your other devices.")
        }
    }
}

/// A small ⓘ next to a control whose consequences are not obvious from its name — the few
/// places where an explanation earns its keep (user, 2026-10-09: "most of the stuff should
/// honestly be self explanatory"). Its own struct with its own state, so the 1 Hz re-render
/// of the root view never rebuilds the alert while it is being read.
private struct InfoButton: View {
    let title: String
    let message: String
    @State private var showing = false

    var body: some View {
        Button {
            showing = true
        } label: {
            Image(systemName: "info.circle")
        }
        // Borderless, so in a Form row it is its own tap target rather than the whole row's.
        .buttonStyle(.borderless)
        .accessibilityLabel("About \(title)")
        .alert(title, isPresented: $showing) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message)
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
        Picker("Accept connections", selection: $controller.acceptPeerConnections) {
            ForEach(PeerAcceptMode.allCases) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .pickerStyle(.menu)
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
    }
}

/// Opus or raw PCM for our own microphone stream (the Windows sender offers the same
/// choice). Two named cases rather than `CaseIterable`, so the recommended one is read first.
private struct SendCodecPicker: View {
    @Bindable var controller: ReceiverController

    var body: some View {
        Picker("Microphone quality", selection: $controller.sendCodec) {
            Text("Opus (recommended)").tag(AudioTransportCodec.opus)
            Text("PCM (uncompressed)").tag(AudioTransportCodec.pcm)
        }
        .pickerStyle(.menu)
    }
}

private struct StartupProfilePicker: View {
    @Bindable var controller: ReceiverController

    var body: some View {
        Picker("Profile at launch", selection: $controller.startupProfile) {
            Text("None")
                .tag(StartupProfileChoice.off)
            Text("Last applied")
                .tag(StartupProfileChoice.lastApplied)
            ForEach(controller.profiles) { profile in
                Text(profile.name).tag(StartupProfileChoice.fixed(profile.id))
            }
        }
        .pickerStyle(.menu)
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
                Text("Saved input (unavailable, using default)")
                    .tag(String?.some(selected))
            }
        }
        // Explicit menu style: a pop-up button (macOS) / anchored menu (iOS) reads as
        // one focusable "pop-up button" element under VoiceOver, instead of whatever
        // presentation the automatic style resolves to in this Form.
        .pickerStyle(.menu)
    }
}
