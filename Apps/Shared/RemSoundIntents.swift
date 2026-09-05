import AppIntents
import RemSoundKit

/// Shortcuts actions ("App Intents") controlling the receiver, plus the ready-made App
/// Shortcuts (with Siri phrases) built from them.
///
/// This file is compiled into BOTH app targets (one PBXFileReference, two PBXBuildFile
/// entries in the hand-written project.pbxproj) and the intents MUST stay in the app
/// targets, not RemSoundKit: App Intents hosted in an SPM library target extract metadata
/// cleanly at build time but are never surfaced by the on-device discovery layer (linkd) —
/// on either platform — even with the documented `AppIntentsPackage` forwarding
/// (developer.apple.com/forums/thread/759160; hit for real 2026-07-11, builds verified
/// byte-perfect yet invisible in Shortcuts). Apple supports app targets and frameworks
/// only, and the AppShortcutsProvider and the intents it lists must share one target.
///
/// All intents mutate the one shared controller the UI observes, on the main actor. When
/// the app isn't running, the system launches it in the background to run the action.
/// Dialogs are plain spoken sentences — Shortcuts and Siri read them aloud, which is the
/// feedback path for the screen-reader users this app is built for.

struct VolumeUpIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn Volume Up"
    static let description = IntentDescription("Raises RemSound's playback volume by 10 percent.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let controller = ReceiverController.shared
        controller.volume = min(1, controller.volume + 0.1)
        return .result(dialog: "Volume \(Int((controller.volume * 100).rounded())) percent")
    }
}

struct VolumeDownIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn Volume Down"
    static let description = IntentDescription("Lowers RemSound's playback volume by 10 percent.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let controller = ReceiverController.shared
        controller.volume = max(0, controller.volume - 0.1)
        return .result(dialog: "Volume \(Int((controller.volume * 100).rounded())) percent")
    }
}

/// Parameterless toggles exist alongside the Bool setters because App Shortcuts cannot
/// pre-fill a Bool parameter — invoking a setter by voice would prompt "On or off?",
/// which breaks the eyes-free flow. The setters stay for user-built shortcuts, where the
/// value is wired up in the editor.

struct ToggleMuteIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Mute"
    static let description = IntentDescription("Mutes RemSound's audio playback if it is audible, unmutes it if it is muted.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let controller = ReceiverController.shared
        controller.isMuted.toggle()
        // Two literal returns, not a ternary — a ternary of string literals infers String,
        // which does not convert to IntentDialog (only literals convert directly).
        if controller.isMuted {
            return .result(dialog: "Audio muted")
        } else {
            return .result(dialog: "Audio unmuted")
        }
    }
}

struct ToggleReceivingIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Receiving"
    static let description = IntentDescription("Stops playing audio from RemSound senders if receiving, starts if stopped.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let controller = ReceiverController.shared
        if controller.receiveEnabled {
            controller.receiveEnabled = false
            return .result(dialog: "Receiving off")
        } else {
            controller.receiveEnabled = true
            if !controller.isRunning, let error = controller.lastError {
                return .result(dialog: "Could not start receiving: \(error)")
            }
            return .result(dialog: "Receiving on")
        }
    }
}

struct SetMutedIntent: AppIntent {
    static let title: LocalizedStringResource = "Mute or Unmute"
    static let description = IntentDescription("Mutes or unmutes RemSound's audio playback.")

    @Parameter(title: "Muted")
    var muted: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Set muted to \(\.$muted)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        ReceiverController.shared.isMuted = muted
        if muted {
            return .result(dialog: "Audio muted")
        } else {
            return .result(dialog: "Audio unmuted")
        }
    }
}

struct SetReceivingIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn Receiving On or Off"
    static let description = IntentDescription("Starts or stops playing audio from RemSound senders.")

    @Parameter(title: "On")
    var on: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Turn receiving \(\.$on)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let controller = ReceiverController.shared
        controller.receiveEnabled = on
        if on {
            if !controller.isRunning, let error = controller.lastError {
                return .result(dialog: "Could not start receiving: \(error)")
            }
            return .result(dialog: "Receiving on")
        } else {
            return .result(dialog: "Receiving off")
        }
    }
}

/// The launch choice as a Shortcuts value. It cannot be an `AppEnum`: two of the three
/// cases are fixed, but the rest are the user's saved profiles, which only exist at
/// runtime. So it is an entity whose query answers with the same list the Profiles tab's
/// "Apply at launch" picker shows — the two sentinels plus one row per profile. Their ids
/// ("none" / "last") can never collide with a profile's UUID string, and they stay stable
/// because Shortcuts stores the id inside the user's shortcut.
///
/// Named `noProfile`/`lastApplied` rather than the obvious `none`: a static `.none` on a
/// type is a standing trap wherever the value meets an Optional of itself.
struct StartupProfileOption: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Startup Profile")
    static let defaultQuery = StartupProfileOptionQuery()

    /// "none", "last", or a saved profile's UUID string.
    var id: String
    var name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    static let noProfileId = "none"
    static let lastAppliedId = "last"

    static let noProfile = StartupProfileOption(id: noProfileId, name: "No profile")
    static let lastApplied = StartupProfileOption(id: lastAppliedId, name: "Last applied profile")

    var choice: StartupProfileChoice {
        switch id {
        case Self.noProfileId: return .off
        case Self.lastAppliedId: return .lastApplied
        default: return UUID(uuidString: id).map { StartupProfileChoice.fixed($0) } ?? .off
        }
    }
}

extension StartupProfileOption {
    // In an extension so the memberwise initialiser above survives.
    init(profile: ReceiverProfile) {
        self.init(id: profile.id.uuidString, name: profile.name)
    }

    /// Every choice the Profiles tab offers, in the same order.
    @MainActor
    static var all: [StartupProfileOption] {
        [.noProfile, .lastApplied] + ReceiverController.shared.profiles.map(StartupProfileOption.init(profile:))
    }
}

/// `EntityStringQuery` rather than a plain `EntityQuery` so a spoken or typed profile name
/// resolves without the user picking from a list.
struct StartupProfileOptionQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [StartupProfileOption] {
        StartupProfileOption.all.filter { identifiers.contains($0.id) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [StartupProfileOption] {
        StartupProfileOption.all.filter { $0.name.localizedCaseInsensitiveContains(string) }
    }

    @MainActor
    func suggestedEntities() async throws -> [StartupProfileOption] {
        StartupProfileOption.all
    }
}

struct SetStartupProfileIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Startup Profile"
    static let description = IntentDescription("Chooses which saved profile RemSound applies each time it starts — a specific profile, whichever one was applied most recently, or none.")

    @Parameter(title: "Startup Profile")
    var profile: StartupProfileOption

    static var parameterSummary: some ParameterSummary {
        Summary("Apply \(\.$profile) at launch")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let controller = ReceiverController.shared
        let choice = profile.choice
        // A shortcut built before the profile was deleted still carries its id. Storing it
        // would leave a launch choice nothing can satisfy (and one the picker cannot show),
        // so say so instead — the dialog is the feedback path, not a thrown error.
        if case .fixed(let id) = choice, !controller.profiles.contains(where: { $0.id == id }) {
            return .result(dialog: "No profile named \(profile.name) is saved")
        }
        controller.startupProfile = choice
        switch choice {
        case .off:
            return .result(dialog: "No profile will be applied at launch")
        case .lastApplied:
            return .result(dialog: "The last applied profile will be applied at launch")
        case .fixed:
            return .result(dialog: "\(profile.name) will be applied at launch")
        }
    }
}

/// Ready-made App Shortcuts: a RemSound section in the Shortcuts app (no user setup) and
/// the Siri phrases. The phrase-training build step (AppIntentsSSUTraining) reads the
/// literal phrase strings from here. Every phrase must contain `\(.applicationName)`.
struct RemSoundAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ToggleMuteIntent(),
            phrases: [
                "Mute \(.applicationName)",
                "Unmute \(.applicationName)",
                "Toggle \(.applicationName) mute",
            ],
            shortTitle: "Toggle Mute",
            systemImageName: "speaker.slash"
        )
        AppShortcut(
            intent: VolumeUpIntent(),
            phrases: [
                "Turn up \(.applicationName)",
                "\(.applicationName) volume up",
                "Increase \(.applicationName) volume",
            ],
            shortTitle: "Volume Up",
            systemImageName: "speaker.wave.3"
        )
        AppShortcut(
            intent: VolumeDownIntent(),
            phrases: [
                "Turn down \(.applicationName)",
                "\(.applicationName) volume down",
                "Decrease \(.applicationName) volume",
            ],
            shortTitle: "Volume Down",
            systemImageName: "speaker.wave.1"
        )
        AppShortcut(
            intent: ToggleReceivingIntent(),
            phrases: [
                "Toggle \(.applicationName) receiving",
                "Toggle receiving in \(.applicationName)",
            ],
            shortTitle: "Toggle Receiving",
            systemImageName: "dot.radiowaves.left.and.right"
        )
    }
}
