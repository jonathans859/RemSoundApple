import RemSoundKit
import SwiftUI
import UIKit

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
    @Environment(\.scenePhase) private var scenePhase
    /// Home screen quick actions (long-press the icon → a saved profile) arrive through the
    /// UIKit delegates below; SwiftUI has no hook of its own for them.
    @UIApplicationDelegateAdaptor(QuickActionAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            // ReceiverRootView provides its own NavigationStack (title + About button) and
            // TabView, so it is presented directly here.
            ReceiverRootView(controller: controller)
                .task {
                    controller.start()
                }
                // Battery (finding 2): the 1 Hz refresh only needs to rebuild status strings
                // while the app is actually on screen — and this app spends most of its life
                // locked/backgrounded. .active = foreground & interactive; anything else
                // (locked, backgrounded, app switcher) gates the presentation work off. The
                // functional half of the tick (cues + their VoiceOver announcements, send
                // path, DNS retry, IO-buffer adaptation) keeps running regardless. initial:true
                // seeds the state at launch, and returning to .active runs one immediate
                // full refresh so the UI is never stale.
                .onChange(of: scenePhase, initial: true) { _, phase in
                    controller.setUIVisible(phase == .active)
                }
        }
    }
}

/// Cold launch from a home screen quick action: the chosen item comes with the scene's
/// connection options, which this sees before the scene (and so before the view's `.task`
/// that starts the receiver) exists. Applying the profile here is what makes it take the
/// place of the launch profile rather than follow it.
@MainActor
final class QuickActionAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        if let item = options.shortcutItem {
            ReceiverController.shared.handleQuickAction(item)
        }
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = QuickActionSceneDelegate.self
        return configuration
    }
}

/// The app was already running (in the background, as it usually is) when the quick action
/// was chosen.
@MainActor
final class QuickActionSceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(_ windowScene: UIWindowScene,
                     performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        completionHandler(ReceiverController.shared.handleQuickAction(shortcutItem))
    }
}
