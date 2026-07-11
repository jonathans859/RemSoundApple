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
    static let description = IntentDescription("Stops listening for RemSound senders if receiving, starts if stopped.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let controller = ReceiverController.shared
        if controller.isRunning {
            controller.stop()
            return .result(dialog: "Receiving off")
        } else {
            controller.start()
            if let error = controller.lastError {
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
    static let description = IntentDescription("Starts or stops listening for RemSound senders.")

    @Parameter(title: "On")
    var on: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Turn receiving \(\.$on)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let controller = ReceiverController.shared
        if on {
            controller.start()
            if let error = controller.lastError {
                return .result(dialog: "Could not start receiving: \(error)")
            }
            return .result(dialog: "Receiving on")
        } else {
            controller.stop()
            return .result(dialog: "Receiving off")
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
