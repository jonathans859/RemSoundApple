@testable import RemSoundKit
import XCTest

/// Guards the decoding of profiles written by an OLDER build.
///
/// Both paths that read profiles — the `[ReceiverProfile]` blob in UserDefaults and each
/// per-profile iCloud key — decode with `try?` and treat a throw as "no profiles". So a
/// synthesised decoder meeting JSON that predates a newly added field does not fail loudly;
/// it silently wipes the user's profile list, and with sync on that wipe would then be
/// published. `ReceiverProfile.init(from:)` is hand-written to default every optional field,
/// and these tests are what keep it that way.
final class ProfileCompatibilityTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "ProfileCompatibilityTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// Exactly the shape written before `autoTuneLatencyEnabled` existed.
    private static let legacyJson = """
    [{
      "id": "8B7E0A2C-5F41-4E2B-9C3D-0A1B2C3D4E5F",
      "name": "Home",
      "manualPeers": [{"id":"1E2D3C4B-5A69-4788-9706-15243342516F","host":"100.64.0.7","port":47830}],
      "selectedPeerAddresses": ["100.64.0.7"],
      "receiveEnabled": true,
      "sendEnabled": false,
      "targetLatencyMs": 60
    }]
    """

    func testProfileWrittenByAnOlderBuildStillLoads() {
        defaults.set(Data(Self.legacyJson.utf8), forKey: "profiles")
        let profiles = ProfileStore(defaults: defaults).profiles

        XCTAssertEqual(profiles.count, 1, "a legacy profile must not vanish")
        XCTAssertEqual(profiles.first?.name, "Home")
        XCTAssertEqual(profiles.first?.targetLatencyMs, 60)
        XCTAssertNil(profiles.first?.selectedMicrophoneId)
        // Absent field takes the same default as a fresh install: auto-tune is opt-in.
        XCTAssertEqual(profiles.first?.autoTuneLatencyEnabled, false)
    }

    func testLegacyProfileSurvivesAReSaveAndGainsTheNewField() {
        defaults.set(Data(Self.legacyJson.utf8), forKey: "profiles")
        let store = ProfileStore(defaults: defaults)
        var profiles = store.profiles
        profiles[0].autoTuneLatencyEnabled = true
        store.profiles = profiles

        let reloaded = ProfileStore(defaults: defaults).profiles
        XCTAssertEqual(reloaded.first?.autoTuneLatencyEnabled, true)
        XCTAssertEqual(reloaded.first?.targetLatencyMs, 60, "unrelated fields must be preserved")
    }

    func testMissingLatencyFallsBackToTheDefaultRatherThanZero() throws {
        let json = """
        {"id":"8B7E0A2C-5F41-4E2B-9C3D-0A1B2C3D4E5F","name":"Bare"}
        """
        let profile = try JSONDecoder().decode(ReceiverProfile.self, from: Data(json.utf8))
        // Zero would be silently clamped to the 5 ms minimum on apply — a profile that
        // quietly reconfigures the buffer is worse than one that keeps the app's default.
        XCTAssertEqual(profile.targetLatencyMs, ReceiverSettings.defaultTargetLatencyMs)
        XCTAssertEqual(profile.receiveEnabled, true)
        XCTAssertEqual(profile.sendEnabled, false)
        XCTAssertEqual(profile.manualPeers, [])
        XCTAssertEqual(profile.selectedPeerAddresses, [])
    }

    func testAutoTuneFlagRoundTripsThroughTheEncodedJson() throws {
        let profile = ReceiverProfile(
            name: "Mobile", manualPeers: [], selectedPeerAddresses: [],
            receiveEnabled: true, sendEnabled: false, selectedMicrophoneId: nil,
            targetLatencyMs: 30, autoTuneLatencyEnabled: true)
        let data = try JSONEncoder().encode(profile)
        XCTAssertEqual(try JSONDecoder().decode(ReceiverProfile.self, from: data), profile)
    }

    func testStartupProfileAppliesTheAutoTuneFlag() {
        let settings = ReceiverSettings(defaults: defaults)
        let store = ProfileStore(defaults: defaults)
        let profile = ReceiverProfile(
            name: "Mobile", manualPeers: [], selectedPeerAddresses: [],
            receiveEnabled: true, sendEnabled: false, selectedMicrophoneId: nil,
            targetLatencyMs: 45, autoTuneLatencyEnabled: true)
        store.profiles = [profile]
        settings.startupProfile = .fixed(profile.id)
        XCTAssertFalse(settings.autoTuneLatencyEnabled)

        store.applyStartupProfile(to: settings)

        // The launch path rewrites the persisted settings directly, so it has to cover every
        // profile field — a missed one silently launches on the previous device state.
        XCTAssertTrue(settings.autoTuneLatencyEnabled)
        XCTAssertEqual(settings.targetLatencyMs, 45)
    }
}
