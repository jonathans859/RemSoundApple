import RemSoundKit
import SwiftUI

/// iOS receiver app. The `audio` background mode in Info.plist plus the always-running
/// AVAudioEngine output keep reception alive in the background and on the lock screen.
///
/// The Shortcuts actions and App Shortcuts live in `Apps/Shared/RemSoundIntents.swift`,
/// compiled into this target — they must NOT move into the RemSoundKit package (SPM-hosted
/// App Intents never surface on devices; see the comment in that file).
@main
struct RemSoundIOSApp: App {
    /// Shared instance, not a private one: Shortcuts actions (App Intents) must drive the
    /// same receiver this UI shows.
    private let controller = ReceiverController.shared

    var body: some Scene {
        WindowGroup {
            // ReceiverRootView provides its own NavigationStack (title + About button) and
            // TabView, so it is presented directly here.
            ReceiverRootView(controller: controller)
                .task {
                    controller.start()
                }
        }
    }
}
