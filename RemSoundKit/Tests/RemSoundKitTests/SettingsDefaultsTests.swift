import XCTest
@testable import RemSoundKit

/// Pins the settings whose default is NOT the zero value. `defaults.bool(forKey:)` returns
/// false for an absent key, so every default-on flag needs the explicit
/// `object(forKey:) == nil` check — rewriting one as a plain `bool` read flips the shipped
/// default for every existing install and is invisible until someone notices the feature is
/// off on a fresh device.
final class SettingsDefaultsTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "SettingsDefaultsTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testDefaultOnFlagsAreOnWithNothingStored() {
        let settings = ReceiverSettings(defaults: defaults)
        XCTAssertTrue(settings.receiveEnabled)
        XCTAssertTrue(settings.cuesEnabled)
        XCTAssertTrue(settings.headsetTransportControls)
        XCTAssertTrue(settings.exclusiveAudio)
    }

    func testDefaultOnFlagsRoundTripFalse() {
        let settings = ReceiverSettings(defaults: defaults)
        settings.receiveEnabled = false
        settings.cuesEnabled = false
        settings.headsetTransportControls = false
        settings.exclusiveAudio = false

        let reloaded = ReceiverSettings(defaults: defaults)
        XCTAssertFalse(reloaded.receiveEnabled)
        XCTAssertFalse(reloaded.cuesEnabled)
        XCTAssertFalse(reloaded.headsetTransportControls)
        // Also the upgrade path: a pre-0.7 install that stored `false` under this same key
        // keeps mixing, instead of being silently pushed onto the exclusive session.
        XCTAssertFalse(reloaded.exclusiveAudio)
    }

    /// The send codec is stored as the wire raw value, and 0 (absent key) is not one of
    /// them — it must read as Opus, never as "whatever case happens to be first".
    func testSendCodecDefaultsToOpusAndRoundTrips() {
        let settings = ReceiverSettings(defaults: defaults)
        XCTAssertEqual(settings.sendCodec, .opus)

        settings.sendCodec = .pcm
        XCTAssertEqual(ReceiverSettings(defaults: defaults).sendCodec, .pcm)

        // A value from a future build is not a licence to put 288 kB/s on a mobile link.
        defaults.set(99, forKey: "sendCodec")
        XCTAssertEqual(ReceiverSettings(defaults: defaults).sendCodec, .opus)
    }

    /// Our identity on a server is picked once and kept. If it moved, every tick anybody
    /// else had made on us would be a tick on a stranger after each launch.
    /// Upstream's default is to ask, and an unknown stored value must not quietly become
    /// "tick everybody back".
    func testAcceptConnectionsDefaultsToAskingAndRoundTrips() {
        let settings = ReceiverSettings(defaults: defaults)
        XCTAssertEqual(settings.acceptPeerConnections, .prompt)

        settings.acceptPeerConnections = .automatic
        XCTAssertEqual(ReceiverSettings(defaults: defaults).acceptPeerConnections, .automatic)

        defaults.set(99, forKey: "acceptPeerConnections")
        XCTAssertEqual(ReceiverSettings(defaults: defaults).acceptPeerConnections, .prompt)
    }

    // MARK: - Server client id (this device only)

    /// Stands in for the Keychain, which CI cannot write to.
    private final class MemoryStore: DeviceOnlyStore {
        var values: [String: String] = [:]
        var failsToWrite = false
        func read(_ account: String) -> String? { values[account] }
        func write(_ value: String, _ account: String) -> Bool {
            guard !failsToWrite else { return false }
            values[account] = value
            return true
        }
    }

    private func settings(_ store: MemoryStore) -> ReceiverSettings {
        ReceiverSettings(defaults: defaults, deviceOnly: store)
    }

    func testRelayClientIdIsGeneratedOnceAndKept() {
        let store = MemoryStore()
        let first = settings(store).relayClientId()
        XCTAssertFalse(first.isZero, "all zero is the server's own id, never a client's")
        XCTAssertEqual(settings(store).relayClientId(), first)
        XCTAssertEqual(store.values[ReceiverSettings.clientIdAccount], first.hex)
        // Not in UserDefaults: those travel in backups, and a backup restored onto a second
        // device would make the two of them one person on every server (upstream issue #10).
        XCTAssertNil(defaults.string(forKey: "relayClientId"))
    }

    /// A stored id that cannot be read back — truncated, not hex, or the all-zero id the
    /// server uses for itself — is replaced rather than patched up or used as-is.
    func testUnusableStoredRelayClientIdIsReplaced() {
        for stored in ["", "zzzz", String(repeating: "0", count: 32), "abcd"] {
            let store = MemoryStore()
            store.values[ReceiverSettings.clientIdAccount] = stored
            let id = settings(store).relayClientId()
            XCTAssertFalse(id.isZero)
            XCTAssertEqual(id.hex.count, 32)
            XCTAssertEqual(store.values[ReceiverSettings.clientIdAccount], id.hex)
        }
    }

    /// An existing install keeps its id — other people's ticks on it survive the update —
    /// and it leaves UserDefaults for the device-only store.
    func testAnExistingIdMovesOutOfUserDefaultsUnchanged() {
        let existing = RelayClientId.random()
        defaults.set(existing.hex, forKey: "relayClientId")
        let store = MemoryStore()

        XCTAssertEqual(settings(store).relayClientId(), existing)
        XCTAssertEqual(store.values[ReceiverSettings.clientIdAccount], existing.hex)
        XCTAssertNil(defaults.string(forKey: "relayClientId"))
    }

    /// If the Keychain cannot be written, the id must still be the same next launch — a new
    /// id every launch would lose every tick on every restart.
    func testAnUnwritableStoreStillKeepsOneId() {
        let store = MemoryStore()
        store.failsToWrite = true
        let first = settings(store).relayClientId()
        XCTAssertEqual(settings(store).relayClientId(), first)
        XCTAssertEqual(defaults.string(forKey: "relayClientId"), first.hex)
    }

    /// A server is somewhere you go: the app must not go anywhere on a fresh install.
    func testServerDefaultsToNowhere() {
        let settings = ReceiverSettings(defaults: defaults)
        XCTAssertEqual(settings.serverHost, "")
        XCTAssertFalse(settings.serverConnected)
        XCTAssertTrue(settings.recentServers.isEmpty)
        XCTAssertFalse(settings.serverPasswordNoticeSeen)
    }

    func testRecentServersAreCappedNewestFirst() {
        let settings = ReceiverSettings(defaults: defaults)
        settings.recentServers = (1...20).map { "server\($0).example" }
        XCTAssertEqual(ReceiverSettings(defaults: defaults).recentServers.count,
                       ReceiverSettings.maxRecentServers)
        XCTAssertEqual(ReceiverSettings(defaults: defaults).recentServers.first, "server1.example")
    }
}
