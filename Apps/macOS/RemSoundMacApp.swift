import AppKit
import RemSoundKit
import SwiftUI

/// macOS receiver app — lives in the menu bar (LSUIElement, no Dock icon), the same role the
/// tray icon plays for the Windows app. The status item is a real menu (not a popover):
/// Show RemSound (W), Enable sending (S), Enable receiving (R), Exit RemSound (X) — the
/// single-letter key equivalents work while the menu is open, which is also how VoiceOver
/// users can fire them without hunting. The full UI lives in a regular window that
/// "Show RemSound" opens; it does NOT open at launch (menu bar apps must start silent).
///
/// The Shortcuts actions and App Shortcuts live in `Apps/Shared/RemSoundIntents.swift`,
/// compiled into this target — they must NOT move into the RemSoundKit package (SPM-hosted
/// App Intents never surface on devices; see the comment in that file).
@main
struct RemSoundMacApp: App {
    /// Shared instance, not a private one: Shortcuts actions (App Intents) must drive the
    /// same receiver this UI shows.
    private let controller = ReceiverController.shared

    var body: some Scene {
        MenuBarExtra {
            StatusMenu(controller: controller)
        } label: {
            // The label is installed in the status bar at launch, so its task is our
            // app-did-launch hook: reception starts immediately, not on first menu open.
            Image(systemName: "antenna.radiowaves.left.and.right")
                .task {
                    controller.start()
                }
                .accessibilityLabel("RemSound")
        }

        Window("RemSound", id: "main") {
            ReceiverRootView(controller: controller)
                .frame(minWidth: 480, minHeight: 500)
                // An accessory (LSUIElement) app never appears in the Dock or the Cmd-Tab
                // switcher, so an open window becomes unreachable the moment the user
                // switches away. Be a regular app while the window exists, an accessory
                // again once it closes (onDisappear fires on close, not on minimize).
                .onAppear {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate()
                }
                .onDisappear {
                    NSApp.setActivationPolicy(.accessory)
                }
        }
        .defaultSize(width: 480, height: 600)
        // A Window scene would otherwise open itself on first launch — this app must
        // start as a bare menu bar item, so both launch and restoration stay silent.
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
    }
}

private struct StatusMenu: View {
    @Bindable var controller: ReceiverController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Show RemSound") {
            openWindow(id: "main")
            // An LSUIElement app is never frontmost on its own — without activation the
            // window would open behind whatever app is active.
            NSApp.activate()
        }
        .keyboardShortcut("w", modifiers: [])

        // Independent checkboxes (Windows parity): receiving gates playback only, sending
        // rides the always-bound socket — either can be on without the other.
        Toggle("Enable sending", isOn: $controller.sendEnabled)
            .keyboardShortcut("s", modifiers: [])

        Toggle("Enable receiving", isOn: $controller.receiveEnabled)
            .keyboardShortcut("r", modifiers: [])

        Divider()

        Button("Exit RemSound") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("x", modifiers: [])
    }
}
