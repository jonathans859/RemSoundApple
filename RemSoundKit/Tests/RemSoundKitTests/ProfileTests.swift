import XCTest
@testable import RemSoundKit

/// Pins the profile snapshot's persistence: everything the Profiles tab saves must survive
/// a JSON round trip through the store, including the "system default" nil microphone.
/// (Passwords are deliberately absent here — they live in the Keychain, one item per
/// profile id, and never enter the encoded JSON.)
final class ProfileTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "ProfileTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeProfile(name: String, microphoneId: String?) -> ReceiverProfile {
        ReceiverProfile(
            name: name,
            manualPeers: [ManualPeer(host: "100.64.0.7"), ManualPeer(host: "relay.example", port: 47831)],
            selectedPeerAddresses: ["100.64.0.7", "192.168.1.20"],
            receiveEnabled: true,
            sendEnabled: true,
            selectedMicrophoneId: microphoneId,
            targetLatencyMs: 120)
    }

    func testProfilesSurviveStoreRoundTrip() {
        let store = ProfileStore(defaults: defaults)
        let saved = [makeProfile(name: "Home", microphoneId: "mic-1"),
                     makeProfile(name: "Travel", microphoneId: nil)]
        store.profiles = saved

        // A fresh store over the same defaults = a fresh app launch.
        let reloaded = ProfileStore(defaults: defaults).profiles
        XCTAssertEqual(reloaded, saved)
        XCTAssertEqual(reloaded[0].selectedMicrophoneId, "mic-1")
        XCTAssertNil(reloaded[1].selectedMicrophoneId)
        XCTAssertEqual(reloaded[0].manualPeers.map(\.port), [RemPacket.defaultPort, 47831])
    }

    func testEmptyStoreReadsAsNoProfiles() {
        XCTAssertEqual(ProfileStore(defaults: defaults).profiles, [])
    }

    func testStartupProfileChoicePersistsAllModes() {
        let settings = ReceiverSettings(defaults: defaults)
        XCTAssertEqual(settings.startupProfile, .off) // default

        settings.startupProfile = .lastApplied
        XCTAssertEqual(ReceiverSettings(defaults: defaults).startupProfile, .lastApplied)

        let id = UUID()
        settings.startupProfile = .fixed(id)
        XCTAssertEqual(ReceiverSettings(defaults: defaults).startupProfile, .fixed(id))

        settings.startupProfile = .off
        XCTAssertEqual(ReceiverSettings(defaults: defaults).startupProfile, .off)

        // Corrupted storage must read as off, never crash or misapply.
        defaults.set("not-a-uuid", forKey: "startupProfile")
        XCTAssertEqual(settings.startupProfile, .off)
    }

    func testApplyStartupProfileRewritesTheLiveSettings() {
        let store = ProfileStore(defaults: defaults)
        let settings = ReceiverSettings(defaults: defaults)
        let profile = makeProfile(name: "Home", microphoneId: "mic-1")
        store.profiles = [profile]
        settings.startupProfile = .fixed(profile.id)
        settings.receiveEnabled = false
        settings.targetLatencyMs = 45

        store.applyStartupProfile(to: settings)

        XCTAssertEqual(settings.manualPeers, profile.manualPeers)
        XCTAssertEqual(settings.selectedPeerAddresses, Set(profile.selectedPeerAddresses))
        XCTAssertTrue(settings.receiveEnabled)
        XCTAssertEqual(settings.selectedMicrophoneId, "mic-1")
        XCTAssertEqual(settings.targetLatencyMs, 120)
        // Now the active profile — feeds the .lastApplied mode.
        XCTAssertEqual(settings.lastAppliedProfileId, profile.id)
        // No send key exists to assert on: the send toggle is never persisted, which is
        // exactly why a launch-applied profile can't turn the microphone on.
    }

    func testApplyStartupProfileLastAppliedUsesTheRememberedProfile() {
        let store = ProfileStore(defaults: defaults)
        let settings = ReceiverSettings(defaults: defaults)
        let home = makeProfile(name: "Home", microphoneId: nil)
        var travel = makeProfile(name: "Travel", microphoneId: nil)
        travel.targetLatencyMs = 200
        store.profiles = [home, travel]
        settings.startupProfile = .lastApplied
        settings.lastAppliedProfileId = travel.id

        store.applyStartupProfile(to: settings)

        XCTAssertEqual(settings.targetLatencyMs, 200)
        XCTAssertEqual(settings.lastAppliedProfileId, travel.id)
    }

    func testApplyStartupProfileDoesNothingWhenOffOrMissing() {
        let store = ProfileStore(defaults: defaults)
        let settings = ReceiverSettings(defaults: defaults)
        settings.targetLatencyMs = 45

        store.applyStartupProfile(to: settings) // off (default)
        XCTAssertEqual(settings.targetLatencyMs, 45)

        settings.startupProfile = .fixed(UUID()) // references no stored profile
        store.applyStartupProfile(to: settings)
        XCTAssertEqual(settings.targetLatencyMs, 45)

        settings.startupProfile = .lastApplied // nothing applied yet
        store.applyStartupProfile(to: settings)
        XCTAssertEqual(settings.targetLatencyMs, 45)
    }

    func testEncodedProfileJsonNeverContainsAPassword() throws {
        // Belt-and-braces: the persisted JSON must not grow a password-shaped field.
        let data = try JSONEncoder().encode([makeProfile(name: "Home", microphoneId: nil)])
        let json = String(decoding: data, as: UTF8.self).lowercased()
        XCTAssertFalse(json.contains("password"))
    }
}
