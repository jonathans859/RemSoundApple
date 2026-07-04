import RemSoundKit
import SwiftUI

/// iOS receiver app. The `audio` background mode in Info.plist plus the always-running
/// AVAudioEngine output keep reception alive in the background and on the lock screen.
@main
struct RemSoundIOSApp: App {
    @State private var controller = ReceiverController()

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
