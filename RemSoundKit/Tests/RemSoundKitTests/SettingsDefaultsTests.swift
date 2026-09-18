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
}
