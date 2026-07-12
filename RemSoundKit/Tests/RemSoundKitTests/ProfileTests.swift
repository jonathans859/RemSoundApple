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

    func testEncodedProfileJsonNeverContainsAPassword() throws {
        // Belt-and-braces: the persisted JSON must not grow a password-shaped field.
        let data = try JSONEncoder().encode([makeProfile(name: "Home", microphoneId: nil)])
        let json = String(decoding: data, as: UTF8.self).lowercased()
        XCTAssertFalse(json.contains("password"))
    }
}
