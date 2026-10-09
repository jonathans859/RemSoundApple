import SwiftUI

/// Modal "About" panel reached from the About button in the top-right of the main view.
/// States what the app is, shows its version, and links to the two source repositories —
/// this Apple port and the official Windows app. VoiceOver-first, like the rest of the UI.
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    private let appRepoURL = URL(string: "https://github.com/jonathans859/RemSoundApple")!
    private let windowsRepoURL = URL(string: "https://github.com/Ednunp/RemSound")!

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("RemSound")
                            .font(.title2).bold()
                            .accessibilityAddTraits(.isHeader)
                        Text("Receive and send RemSound audio on your Apple devices.")
                            .foregroundStyle(.secondary)
                        if let version = versionText {
                            Text(version)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    Link(destination: appRepoURL) {
                        linkLabel(title: "RemSound for Apple",
                                  detail: "jonathans859/RemSoundApple",
                                  systemImage: "applelogo")
                    }
                    .accessibilityLabel("RemSound for Apple source code on GitHub")

                    Link(destination: windowsRepoURL) {
                        linkLabel(title: "RemSound for Windows",
                                  detail: "Ednunp/RemSound — the official app",
                                  systemImage: "pc")
                    }
                    .accessibilityLabel("Official RemSound for Windows source code on GitHub")
                } header: {
                    Text("Source code")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("About")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func linkLabel(title: String, detail: String, systemImage: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "arrow.up.right")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }

    private var versionText: String? {
        let info = Bundle.main.infoDictionary
        guard let short = info?["CFBundleShortVersionString"] as? String else { return nil }
        if let build = info?["CFBundleVersion"] as? String, build != short {
            return "Version \(short) (build \(build))"
        }
        return "Version \(short)"
    }
}
