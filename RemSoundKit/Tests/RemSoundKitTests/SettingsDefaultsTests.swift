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

    func testRelayClientIdIsGeneratedOnceAndKept() {
        let first = ReceiverSettings(defaults: defaults).relayClientId()
        XCTAssertFalse(first.isZero, "all zero is the server's own id, never a client's")
        XCTAssertEqual(ReceiverSettings(defaults: defaults).relayClientId(), first)
        XCTAssertEqual(defaults.string(forKey: "relayClientId"), first.hex)
    }

    /// A stored id that cannot be read back — truncated, not hex, or the all-zero id the
    /// server uses for itself — is replaced rather than patched up or used as-is.
    func testUnusableStoredRelayClientIdIsReplaced() {
        for stored in ["", "zzzz", String(repeating: "0", count: 32), "abcd"] {
            defaults.set(stored, forKey: "relayClientId")
            let id = ReceiverSettings(defaults: defaults).relayClientId()
            XCTAssertFalse(id.isZero)
            XCTAssertEqual(id.hex.count, 32)
            XCTAssertEqual(defaults.string(forKey: "relayClientId"), id.hex)
        }
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
